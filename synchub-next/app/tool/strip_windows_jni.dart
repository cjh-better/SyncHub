import 'dart:io';

import 'package:synchub/tools/windows_bundle.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1 || args.single.isEmpty) {
    stderr.writeln('usage: dart run tool/strip_windows_jni.dart <bundle-dir>');
    exit(64);
  }
  try {
    await stripWindowsJniBundle(Directory(args.single));
  } on BundleDependencyException catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }
}
