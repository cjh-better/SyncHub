import 'dart:io';

import 'package:path/path.dart' as p;

import 'crypto_pool.dart';
import 'proto.dart';

/// Manifest entry plus the sender-side absolute path.
class LocalFile {
  final FileEntry entry;
  final String abs;
  const LocalFile(this.entry, this.abs);

  factory LocalFile.fromJson(Map<String, dynamic> j) => LocalFile(FileEntry.fromJson(j), j['abs'] as String);
  Map<String, dynamic> toJson() => {...entry.toJson(), 'abs': abs};
}

/// Walks files/folders (a folder keeps its own name as top-level component,
/// like dragging it onto a device in Blip) and hashes every file.
Future<(List<LocalFile>, List<String>)> buildManifest(List<String> paths, CryptoPool pool,
    {void Function(int done, int total)? onProgress}) async {
  final raw = <(String rel, String abs, int size, int mtime)>[];
  final dirs = <String>[];
  for (final path in paths) {
    final abs = p.absolute(path);
    final type = await FileSystemEntity.type(abs, followLinks: false);
    final base = p.basename(abs);
    if (type == FileSystemEntityType.file) {
      final st = await File(abs).stat();
      raw.add((base, abs, st.size, st.modified.millisecondsSinceEpoch));
    } else if (type == FileSystemEntityType.directory) {
      await for (final e in Directory(abs).list(recursive: true, followLinks: false)) {
        final rel = '$base/${p.split(p.relative(e.path, from: abs)).join('/')}';
        if (e is File) {
          final st = await e.stat();
          raw.add((rel, e.path, st.size, st.modified.millisecondsSinceEpoch));
        } else if (e is Directory) {
          if (await e.list().isEmpty) dirs.add(rel);
        }
      }
      if (await Directory(abs).list().isEmpty) dirs.add(base);
    } else {
      throw FileSystemException('not found', abs);
    }
  }
  final seen = <String>{};
  for (final r in raw) {
    if (!seen.add(r.$1.toLowerCase())) throw FileSystemException('duplicate path in selection', r.$1);
  }
  final total = raw.fold<int>(0, (a, r) => a + r.$3);
  var done = 0;
  final files = <LocalFile>[];
  // hash in parallel across the pool, keep order
  final hashes = await Future.wait(raw.map((r) async {
    final h = await pool.sha256File(r.$2);
    done += r.$3;
    onProgress?.call(done, total);
    return h;
  }));
  for (var i = 0; i < raw.length; i++) {
    final r = raw[i];
    files.add(LocalFile(FileEntry(index: i, path: r.$1, size: r.$3, mtime: r.$4, sha256: hashes[i]), r.$2));
  }
  return (files, dirs);
}

const _reserved = {
  'CON', 'PRN', 'AUX', 'NUL', //
  'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
  'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
};

/// Untrusted manifest path -> safe components (same rules as the Go client).
List<String> sanitizeRelPath(String path) {
  if (path.isEmpty || path.startsWith('/') || path.contains('\\') || path.contains('\x00')) {
    throw const FormatException('invalid path');
  }
  final parts = path.split('/');
  if (parts.length > 64) throw const FormatException('path too deep');
  final out = <String>[];
  for (var i = 0; i < parts.length; i++) {
    var c = parts[i];
    if (c.isEmpty || c == '.' || c == '..') throw const FormatException('invalid path component');
    if (i == 0 && c.length == 2 && c[1] == ':') throw const FormatException('drive letter');
    c = c.replaceAllMapped(RegExp(r'[<>:"|?*\x00-\x1f]'), (_) => '_');
    c = c.replaceAll(RegExp(r'[. ]+$'), '');
    if (c.isEmpty) c = '_';
    if (_reserved.contains(c.split('.').first.toUpperCase())) c = '_$c';
    out.add(c);
  }
  return out;
}

/// path, or "name (n).ext" if it already exists.
Future<String> uniquePath(String path) async {
  if (await FileSystemEntity.type(path, followLinks: false) == FileSystemEntityType.notFound) return path;
  final dir = p.dirname(path);
  final ext = p.extension(path);
  final stem = p.basenameWithoutExtension(path);
  for (var i = 1;; i++) {
    final c = p.join(dir, '$stem ($i)$ext');
    if (await FileSystemEntity.type(c, followLinks: false) == FileSystemEntityType.notFound) return c;
  }
}

String humanBytes(num n) {
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  var i = 0;
  var v = n.toDouble();
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return i == 0 ? '${v.toInt()} B' : '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${u[i]}';
}
