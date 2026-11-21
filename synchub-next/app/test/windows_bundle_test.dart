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
