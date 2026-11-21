import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Thrown when a Windows bundle still contains a JNI/JVM dependency.
class BundleDependencyException implements Exception {
  final String message;
  const BundleDependencyException(this.message);
  @override
  String toString() => message;
}

const forbiddenWindowsDlls = <String>{'dartjni.dll', 'jvm.dll'};

const _manifestNames = <String>{
  'native_assets.json',
  'nativeassetsmanifest.json',
};

/// Removes Windows JNI binaries and manifest entries from a release bundle.
///
/// `package:jni` is only used by the Android implementations of
/// `path_provider` and `shared_preferences`. Windows uses
/// `path_provider_windows`, `shared_preferences_windows`, and
/// `windows_file_picker`. This app never touches `Jni`, whose library load
/// is a static field that runs only when that class is first used.
/// `dartjni.dll` delay-loads `jvm.dll`, so shipping it makes a PC without a
/// JDK look like it cannot start the app.
Future<void> stripWindowsJniBundle(Directory bundle) async {
  if (!await bundle.exists()) {
    throw BundleDependencyException('bundle directory does not exist: ${bundle.path}');
  }
  await for (final entity in bundle.list(recursive: true)) {
    if (entity is! File) continue;
    if (forbiddenWindowsDlls.contains(p.basename(entity.path).toLowerCase())) {
      await entity.delete();
    }
  }
  await for (final entity in bundle.list(recursive: true)) {
    if (entity is! File) continue;
    if (_manifestNames.contains(p.basename(entity.path).toLowerCase())) {
      await _stripManifest(entity);
    }
  }
  final leftovers = <String>[];
  await for (final entity in bundle.list(recursive: true)) {
    if (entity is! File) continue;
    final name = p.basename(entity.path).toLowerCase();
    if (forbiddenWindowsDlls.contains(name)) {
      leftovers.add(entity.path);
      continue;
    }
    if (_manifestNames.contains(name)) {
      final text = (await entity.readAsString()).toLowerCase();
      if (text.contains('dartjni') || text.contains('package:jni/')) {
        leftovers.add('${entity.path} still references JNI');
      }
    }
  }
  if (leftovers.isNotEmpty) {
    throw BundleDependencyException(
      'Windows bundle still has a JNI/JVM dependency:\n${leftovers.join('\n')}',
    );
  }
}

Future<void> _stripManifest(File file) async {
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map) {
    throw BundleDependencyException('${file.path} is not a JSON object');
  }
  final manifest = Map<String, Object?>.from(decoded);
  final native = manifest['native-assets'];
  if (native is Map) {
    final targets = <String, Object?>{};
    for (final target in native.entries) {
      final assets = target.value;
      if (assets is! Map) {
        targets['${target.key}'] = assets;
        continue;
      }
      final kept = <String, Object?>{};
      for (final asset in assets.entries) {
        if (_isJniAsset('${asset.key}', asset.value)) continue;
        kept['${asset.key}'] = asset.value;
      }
      targets['${target.key}'] = kept;
    }
    manifest['native-assets'] = targets;
  }
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));
}

bool _isJniAsset(String id, Object? pathInfo) {
  final lowerId = id.toLowerCase();
  if (lowerId.contains('package:jni/') || lowerId.contains('dartjni')) return true;
  return jsonEncode(pathInfo).toLowerCase().contains('dartjni');
}
