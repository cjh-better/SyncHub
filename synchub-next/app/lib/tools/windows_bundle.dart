import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
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

/// Program files left behind by an older Windows build. Not user data.
const staleJniProgramFiles = <String>{'dartjni.dll', 'jvm.dll'};

class JniBoundaryException implements Exception {
  final String message;
  const JniBoundaryException(this.message);
  @override
  String toString() => message;
}

class JniQuarantineResult {
  final Directory backupDir;
  final List<String> movedNames;
  const JniQuarantineResult({required this.backupDir, required this.movedNames});
}

/// Moves leftover `dartjni.dll` / `jvm.dll` out of [installDir].
///
/// Only those two direct children are eligible. Other DLLs stay. A symlink is
/// moved as a link and its target is not opened or deleted. The install
/// directory itself must be a real directory.
Future<JniQuarantineResult> quarantineStaleJniAssets({
  required Directory installDir,
  required Directory backupDir,
}) async {
  _requireRealDirectory(installDir);
  final before = _directDllNames(installDir);
  final moved = <Map<String, Object?>>[];
  for (final name in staleJniProgramFiles) {
    final path = p.join(installDir.path, name);
    if (!_isDirectChild(installDir.path, path, name)) {
      throw JniBoundaryException('$name is outside the install directory');
    }
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) continue;
    if (type != FileSystemEntityType.file && type != FileSystemEntityType.link) {
      throw JniBoundaryException('$name is not a program file');
    }
    if (type == FileSystemEntityType.file) {
      final rootReal = await installDir.resolveSymbolicLinks();
      final fileReal = await File(path).resolveSymbolicLinks();
      if (!_isInside(rootReal, fileReal)) {
        throw JniBoundaryException('$name resolves outside the install directory');
      }
    }
    await backupDir.create(recursive: true);
    final dest = p.join(backupDir.path, name);
    String? sha256;
    int? bytes;
    if (type == FileSystemEntityType.file) {
      final data = await File(path).readAsBytes();
      bytes = data.length;
      sha256 = crypto.sha256.convert(data).toString().toUpperCase();
      await File(path).rename(dest);
    } else {
      await Link(path).rename(dest);
    }
    moved.add(<String, Object?>{
      'name': name,
      'symlink': type == FileSystemEntityType.link,
      'sha256': sha256,
      'bytes': bytes,
    });
  }
  final after = _directDllNames(installDir);
  final removed = before.difference(after);
  if (removed.any((name) => !staleJniProgramFiles.contains(name))) {
    throw JniBoundaryException('quarantine removed a DLL that is not a known JNI file');
  }
  if (!after.containsAll(before.difference(staleJniProgramFiles))) {
    throw JniBoundaryException('quarantine changed a DLL that should have stayed');
  }
  final record = <String, Object?>{
    'kind': 'stale-jni-program-files',
    'files': moved,
  };
  if (moved.isNotEmpty) {
    await File(p.join(backupDir.path, 'quarantine-manifest.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert(record),
    );
  }
  await File(p.join(installDir.path, 'install-manifest.json')).writeAsString(
    const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'kind': 'synchub-install',
      'liveJniFiles': after.intersection(staleJniProgramFiles).toList()..sort(),
      'quarantinedProgramFiles': moved,
      'preservedOtherDlls': true,
      'quarantineDir': moved.isEmpty ? '' : backupDir.path,
    }),
  );
  if (moved.isNotEmpty) {
    await File(p.join(installDir.path, 'jni-quarantine.txt')).writeAsString('${backupDir.path}\n');
  }
  return JniQuarantineResult(
    backupDir: backupDir,
    movedNames: moved.map((entry) => entry['name']! as String).toList(),
  );
}

/// Puts a previous quarantine back. Refuses to overwrite a file already there
/// and refuses any name other than the two known JNI program files.
Future<void> restoreStaleJniAssets({
  required Directory installDir,
  required Directory backupDir,
}) async {
  _requireRealDirectory(installDir);
  final manifestFile = File(p.join(backupDir.path, 'quarantine-manifest.json'));
  if (!await manifestFile.exists()) {
    throw JniBoundaryException('quarantine manifest is missing');
  }
  final decoded = jsonDecode(await manifestFile.readAsString());
  if (decoded is! Map || decoded['files'] is! List) {
    throw JniBoundaryException('quarantine manifest is invalid');
  }
  for (final raw in decoded['files'] as List) {
    if (raw is! Map) throw const JniBoundaryException('quarantine entry is invalid');
    final name = '${raw['name'] ?? ''}';
    if (!staleJniProgramFiles.contains(name)) {
      throw JniBoundaryException('refusing to restore $name');
    }
    final src = p.join(backupDir.path, name);
    final dest = p.join(installDir.path, name);
    if (!_isDirectChild(installDir.path, dest, name)) {
      throw JniBoundaryException('$name is outside the install directory');
    }
    final destType = FileSystemEntity.typeSync(dest, followLinks: false);
    if (destType != FileSystemEntityType.notFound) {
      throw JniBoundaryException('refusing to overwrite $name');
    }
    final srcType = FileSystemEntity.typeSync(src, followLinks: false);
    if (srcType == FileSystemEntityType.link) {
      await Link(src).rename(dest);
    } else if (srcType == FileSystemEntityType.file) {
      await File(src).rename(dest);
    } else {
      throw JniBoundaryException('backup for $name is missing');
    }
  }
}

void _requireRealDirectory(Directory dir) {
  final type = FileSystemEntity.typeSync(dir.path, followLinks: false);
  if (type == FileSystemEntityType.link) {
    throw JniBoundaryException('install directory is a symlink');
  }
  if (type != FileSystemEntityType.directory) {
    throw JniBoundaryException('install directory is missing');
  }
}

bool _isDirectChild(String root, String candidate, String name) {
  if (name.contains('\\') || name.contains('/') || name.contains('..')) return false;
  return p.equals(p.normalize(p.dirname(candidate)), p.normalize(root)) &&
      p.basename(candidate).toLowerCase() == name;
}

bool _isInside(String root, String candidate) {
  final nRoot = p.normalize(root);
  final nCandidate = p.normalize(candidate);
  return nCandidate == nRoot || p.isWithin(nRoot, nCandidate);
}

Set<String> _directDllNames(Directory root) {
  final names = <String>{};
  for (final entity in root.listSync(followLinks: false)) {
    final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
    if (type != FileSystemEntityType.file && type != FileSystemEntityType.link) continue;
    final base = p.basename(entity.path).toLowerCase();
    if (base.endsWith('.dll')) names.add(base);
  }
  return names;
}

bool _isJniAsset(String id, Object? pathInfo) {
  final lowerId = id.toLowerCase();
  if (lowerId.contains('package:jni/') || lowerId.contains('dartjni')) return true;
  return jsonEncode(pathInfo).toLowerCase().contains('dartjni');
}
