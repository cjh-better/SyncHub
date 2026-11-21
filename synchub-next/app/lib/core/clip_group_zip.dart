import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// One file inside a SyncClipboard Group zip. Directory entries are omitted.
class ClipZipEntry {
  final String name;
  final Uint8List bytes;
  const ClipZipEntry(this.name, this.bytes);
}

class ClipZipException implements Exception {
  final String message;
  const ClipZipException(this.message);
  @override
  String toString() => message;
}

/// Reads a SyncClipboard Group zip (stored or raw deflate) from the central
/// directory. Rejects encryption, absolute paths, and `..` segments.
List<ClipZipEntry> readSafeZip(
  Uint8List data, {
  int maxEntries = 64,
  int maxTotalUncompressed = 100 * 1024 * 1024,
}) {
  if (data.length < 22) {
    throw const ClipZipException('不是有效的 zip');
  }
  final view = ByteData.sublistView(data);
  final eocd = _findEocd(data, view);
  final count = view.getUint16(eocd + 10, Endian.little);
  final cdSize = view.getUint32(eocd + 12, Endian.little);
  final cdOff = view.getUint32(eocd + 16, Endian.little);
  if (count > maxEntries) {
    throw const ClipZipException('压缩包内文件过多');
  }
  if (cdOff > data.length || cdSize > data.length - cdOff) {
    throw const ClipZipException('zip 目录越界');
  }

  var off = cdOff;
  var total = 0;
  final out = <ClipZipEntry>[];
  for (var i = 0; i < count; i++) {
    if (off + 46 > data.length || view.getUint32(off, Endian.little) != 0x02014b50) {
      throw const ClipZipException('zip 目录损坏');
    }
    final flags = view.getUint16(off + 8, Endian.little);
    final method = view.getUint16(off + 10, Endian.little);
    final compSize = view.getUint32(off + 20, Endian.little);
    final uncompSize = view.getUint32(off + 24, Endian.little);
    final nameLen = view.getUint16(off + 28, Endian.little);
    final extraLen = view.getUint16(off + 30, Endian.little);
    final commentLen = view.getUint16(off + 32, Endian.little);
    final localOff = view.getUint32(off + 42, Endian.little);
    final nameStart = off + 46;
    final nameEnd = nameStart + nameLen;
    if (nameEnd > data.length) {
      throw const ClipZipException('zip 文件名越界');
    }
    final String name;
    try {
      name = utf8.decode(data.sublist(nameStart, nameEnd));
    } on FormatException {
      throw const ClipZipException('文件名不是 UTF-8');
    }
    off = nameEnd + extraLen + commentLen;
    if (name.endsWith('/') || name.endsWith(r'\')) continue;
    _checkRelativeName(name);
    if ((flags & 0x1) != 0) {
      throw const ClipZipException('不支持加密压缩包');
    }
    if (method != 0 && method != 8) {
      throw ClipZipException('不支持的压缩方法 $method');
    }
    if (uncompSize > maxTotalUncompressed || total > maxTotalUncompressed - uncompSize) {
      throw const ClipZipException('解压后超过大小上限');
    }
    total += uncompSize;
    final bytes = _readLocal(
      data,
      view,
      localOff,
      method: method,
      compSize: compSize,
      uncompSize: uncompSize,
    );
    out.add(ClipZipEntry(name.replaceAll('\\', '/'), bytes));
  }
  return out;
}

void _checkRelativeName(String name) {
  final normalized = name.replaceAll('\\', '/');
  if (normalized.startsWith('/') || normalized.contains(':')) {
    throw const ClipZipException('拒绝绝对路径');
  }
  for (final part in normalized.split('/')) {
    if (part == '..') {
      throw const ClipZipException('拒绝路径穿越');
    }
  }
}

Uint8List _readLocal(
  Uint8List data,
  ByteData view,
  int localOff, {
  required int method,
  required int compSize,
  required int uncompSize,
}) {
  if (localOff < 0 || localOff + 30 > data.length) {
    throw const ClipZipException('本地文件头越界');
  }
  if (view.getUint32(localOff, Endian.little) != 0x04034b50) {
    throw const ClipZipException('本地文件头损坏');
  }
  final nameLen = view.getUint16(localOff + 26, Endian.little);
  final extraLen = view.getUint16(localOff + 28, Endian.little);
  final dataOff = localOff + 30 + nameLen + extraLen;
  if (dataOff < 0 || compSize > data.length - dataOff) {
    throw const ClipZipException('压缩数据越界');
  }
  final comp = data.sublist(dataOff, dataOff + compSize);
  if (method == 0) return Uint8List.fromList(comp);
  try {
    final decoded = Uint8List.fromList(ZLibDecoder(raw: true).convert(comp));
    if (uncompSize != 0 && decoded.length != uncompSize) {
      throw const ClipZipException('解压长度与目录不一致');
    }
    return decoded;
  } catch (e) {
    if (e is ClipZipException) rethrow;
    throw const ClipZipException('解压失败');
  }
}

int _findEocd(Uint8List data, ByteData view) {
  final start = data.length < 22 + 65535 ? 0 : data.length - 22 - 65535;
  for (var i = data.length - 22; i >= start; i--) {
    if (view.getUint32(i, Endian.little) == 0x06054b50) return i;
  }
  throw const ClipZipException('找不到 zip 目录结尾');
}

String safeClipboardBaseName(String name) {
  var base = p.basename(name.replaceAll('\\', '/')).trim();
  base = base.replaceAll(RegExp(r'[<>:"|?*\x00-\x1F]'), '_');
  if (base.isEmpty || base == '.' || base == '..') return 'clipboard.bin';
  return base;
}

/// Writes an incoming File or Group payload under [supportDir]/clip_inbox.
///
/// The inbox is created by SyncHub for clipboard paste. This never deletes the
/// receive folder, cloud history, or anything outside that inbox subdirectory.
Future<List<String>> stageClipboardPayload({
  required String supportDir,
  required String key,
  required String name,
  required Uint8List bytes,
  required bool groupArchive,
}) async {
  final slug = key.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  final trimmed = slug.isEmpty ? 'clip' : (slug.length > 16 ? slug.substring(0, 16) : slug);
  final folder = trimmed.padRight(8, '0');
  final dir = Directory(p.join(supportDir, 'clip_inbox', folder));
  if (await dir.exists()) {
    await dir.delete(recursive: true);
  }
  await dir.create(recursive: true);

  Future<List<String>> saveSingle() async {
    final file = File(p.join(dir.path, safeClipboardBaseName(name.isEmpty ? 'clipboard.bin' : name)));
    await file.writeAsBytes(bytes, flush: true);
    return <String>[file.path];
  }

  if (!groupArchive) return saveSingle();

  List<ClipZipEntry> entries;
  try {
    entries = readSafeZip(bytes);
  } on ClipZipException {
    return saveSingle();
  }
  if (entries.isEmpty) return saveSingle();

  final paths = <String>[];
  for (final entry in entries) {
    final parts = entry.name
        .split('/')
        .where((s) => s.isNotEmpty && s != '.' && s != '..')
        .map(safeClipboardBaseName)
        .toList();
    if (parts.isEmpty) continue;
    final file = File(p.joinAll(<String>[dir.path, ...parts]));
    final resolved = p.normalize(file.path);
    if (!p.isWithin(p.normalize(dir.path), resolved)) continue;
    await file.parent.create(recursive: true);
    await file.writeAsBytes(entry.bytes, flush: true);
    paths.add(file.path);
  }
  if (paths.isEmpty) return saveSingle();
  return paths;
}
