import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:synchub/tools/windows_bundle.dart';

void main() {
  test('strips dartjni.dll and jvm.dll and drops JNI manifest entries', () async {
    final root = await Directory.systemTemp.createTemp('synchub_bundle_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    await File(p.join(root.path, 'dartjni.dll')).writeAsBytes(const <int>[1, 2, 3]);
    await Directory(p.join(root.path, 'data')).create();
    await File(p.join(root.path, 'data', 'jvm.dll')).writeAsBytes(const <int>[4]);
    await File(p.join(root.path, 'native_assets.json')).writeAsString(jsonEncode(<String, Object?>{
      'format-version': <int>[1, 0, 0],
      'native-assets': <String, Object?>{
        'windows_x64': <String, Object?>{
          'package:jni/src/jni.dart': <String>['absolute', 'dartjni.dll'],
          'package:objective_c/objective_c.dylib': <String>['absolute', 'objective_c.dll'],
        },
      },
    }));
    final manifestDir = Directory(p.join(root.path, 'data', 'flutter_assets'));
    await manifestDir.create(recursive: true);
    await File(p.join(manifestDir.path, 'NativeAssetsManifest.json')).writeAsString(
      jsonEncode(<String, Object?>{
        'format-version': <int>[1, 0, 0],
        'native-assets': <String, Object?>{
          'windows_x64': <String, Object?>{
            'package:jni/jni.dart': <String>['absolute', 'dartjni.dll'],
          },
        },
      }),
    );

    await stripWindowsJniBundle(root);

    expect(await File(p.join(root.path, 'dartjni.dll')).exists(), isFalse);
    expect(await File(p.join(root.path, 'data', 'jvm.dll')).exists(), isFalse);
    final native = jsonDecode(await File(p.join(root.path, 'native_assets.json')).readAsString())
        as Map<String, Object?>;
    final assets = ((native['native-assets'] as Map)['windows_x64'] as Map).cast<String, Object?>();
    expect(assets.keys, ['package:objective_c/objective_c.dylib']);
    final manifest = jsonDecode(
      await File(p.join(manifestDir.path, 'NativeAssetsManifest.json')).readAsString(),
    ) as Map<String, Object?>;
    expect(((manifest['native-assets'] as Map)['windows_x64'] as Map).isEmpty, isTrue);
  });

  test('upgrade quarantines stale JNI program files and can restore them', () async {
    final install = await Directory.systemTemp.createTemp('synchub_install_');
    final outside = await Directory.systemTemp.createTemp('synchub_outside_');
    final backup = Directory(p.join(install.parent.path, 'jni-backup'));
    addTearDown(() async {
      if (await install.exists()) await install.delete(recursive: true);
      if (await outside.exists()) await outside.delete(recursive: true);
      if (await backup.exists()) await backup.delete(recursive: true);
    });
    await File(p.join(install.path, 'flutter_windows.dll')).writeAsBytes(const <int>[9, 9]);
    await File(p.join(install.path, 'dartjni.dll')).writeAsBytes(const <int>[1, 2, 3, 4]);
    await Directory(p.join(install.path, 'data')).create();
    await File(p.join(install.path, 'data', 'jvm.dll')).writeAsBytes(const <int>[5]);
    final secret = File(p.join(outside.path, 'secret.bin'));
    await secret.writeAsBytes(const <int>[7, 7, 7]);
    Link(p.join(install.path, 'jvm.dll')).createSync(secret.path);

    final result = await quarantineStaleJniAssets(installDir: install, backupDir: backup);

    expect(result.movedNames, containsAll(<String>['dartjni.dll', 'jvm.dll']));
    expect(await File(p.join(install.path, 'dartjni.dll')).exists(), isFalse);
    expect(await File(p.join(install.path, 'flutter_windows.dll')).readAsBytes(), <int>[9, 9]);
    expect(await File(p.join(install.path, 'data', 'jvm.dll')).readAsBytes(), <int>[5]);
    expect(await secret.readAsBytes(), <int>[7, 7, 7]);
    expect(
      FileSystemEntity.typeSync(p.join(backup.path, 'jvm.dll'), followLinks: false),
      FileSystemEntityType.link,
    );
    expect(await File(p.join(backup.path, 'dartjni.dll')).readAsBytes(), <int>[1, 2, 3, 4]);
    final manifest = jsonDecode(await File(p.join(install.path, 'install-manifest.json')).readAsString())
        as Map<String, Object?>;
    expect(manifest['liveJniFiles'], isEmpty);
    expect(manifest['preservedOtherDlls'], isTrue);

    await restoreStaleJniAssets(installDir: install, backupDir: backup);
    expect(await File(p.join(install.path, 'dartjni.dll')).readAsBytes(), <int>[1, 2, 3, 4]);
    expect(
      FileSystemEntity.typeSync(p.join(install.path, 'jvm.dll'), followLinks: false),
      FileSystemEntityType.link,
    );
    expect(await secret.readAsBytes(), <int>[7, 7, 7]);
    expect(await File(p.join(install.path, 'flutter_windows.dll')).readAsBytes(), <int>[9, 9]);
  });

  test('a symlinked install directory is not used as a quarantine root', () async {
    final real = await Directory.systemTemp.createTemp('synchub_real_');
    final linkPath = p.join(real.parent.path, 'synchub_link_${real.path.hashCode}');
    Link(linkPath).createSync(real.path);
    addTearDown(() async {
      final link = Link(linkPath);
      if (await link.exists()) await link.delete();
      if (await real.exists()) await real.delete(recursive: true);
    });
    await File(p.join(real.path, 'dartjni.dll')).writeAsBytes(const <int>[1]);
    expect(
      () => quarantineStaleJniAssets(
        installDir: Directory(linkPath),
        backupDir: Directory(p.join(real.parent.path, 'unused-backup')),
      ),
      throwsA(isA<JniBoundaryException>()),
    );
    expect(await File(p.join(real.path, 'dartjni.dll')).exists(), isTrue);
  });

  test('a bundle without JNI stays valid', () async {
    final root = await Directory.systemTemp.createTemp('synchub_bundle_ok_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    await File(p.join(root.path, 'synchub.exe')).writeAsBytes(const <int>[0]);
    await stripWindowsJniBundle(root);
    expect(await File(p.join(root.path, 'synchub.exe')).exists(), isTrue);
  });
}
