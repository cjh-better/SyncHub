import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'api.dart';

/// Standard 8 SyncHub categories (matching `VALID_CATEGORIES` in `synchub_server.py`).
const List<String> kHubCategories = <String>[
  '文档',
  '视频',
  '压缩包',
  '图片',
  '安装包',
  '音频',
  '文本',
  '其他',
];

const Set<String> _windowsReservedNames = <String>{
  'CON', 'PRN', 'AUX', 'NUL',
  'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
  'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
};

/// Sanitizes an untrusted remote filename so it cannot escape the receive folder
/// or violate Windows / POSIX filename rules.
String sanitizeHubFilename(String raw, {required String fallback}) {
  var name = raw.replaceAll('\\', '/').split('/').last.trim();
  name = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]'), '_');
  name = name.replaceAll(RegExp(r'[. ]+$'), '');
  if (name.isEmpty || name == '.' || name == '..') return fallback;
  final stem = name.split('.').first.toUpperCase();
  if (_windowsReservedNames.contains(stem)) {
    name = '_$name';
  }
  return name;
}

/// One record from SyncHub (`/api/hub/items`, `/api/hub/auto-pull`, etc.),
/// mirroring `enrich_row()` in `synchub_server.py`.
class HubItem {
  final int id;
  final int type; // 0: Text, 1: File, 2: Image, 3: Group
  final String typeName;
  final String text;
  final String filename;
  final int size;
  final String hash;
  final String createTimeUtc;
  final String createTimeLocal;
  final bool starred;
  final bool pinned;
  final bool isPermanent;
  final int? remainingSeconds;
  final String fromDevice;
  final String sourceDeviceId;
  final String targetDevice;
  final String category;
  final List<String> tags;
  final bool hasFile;
  final String? downloadUrl;

  const HubItem({
    required this.id,
    required this.type,
    required this.typeName,
    required this.text,
    required this.filename,
    required this.size,
    required this.hash,
    required this.createTimeUtc,
    required this.createTimeLocal,
    required this.starred,
    required this.pinned,
    required this.isPermanent,
    required this.remainingSeconds,
    required this.fromDevice,
    required this.sourceDeviceId,
    required this.targetDevice,
    required this.category,
    required this.tags,
    required this.hasFile,
    required this.downloadUrl,
  });

  bool get isText => type == 0;
  bool get isFile => type == 1 || type == 2;
  bool get isImage => type == 2 || category == '图片';

  DateTime? get createdAt => DateTime.tryParse(createTimeUtc);

  /// Primary label for UI cards/lists.
  String get displayTitle {
    if (type != 0 && filename.isNotEmpty) return filename;
    final trimmed = text.trim();
    if (trimmed.isNotEmpty) {
      final firstLine = trimmed.split(RegExp(r'\r?\n')).first.trim();
      if (firstLine.isNotEmpty) {
        return firstLine.length > 120 ? '${firstLine.substring(0, 120)}…' : firstLine;
      }
    }
    return filename.isNotEmpty ? filename : '条目 #$id';
  }

  HubItem copyWith({
    bool? starred,
    bool? pinned,
    bool? isPermanent,
    int? remainingSeconds,
    bool clearRemaining = false,
    String? category,
    List<String>? tags,
  }) {
    final nextStarred = starred ?? this.starred;
    final nextPinned = pinned ?? this.pinned;
    final nextPerm = isPermanent ?? (nextStarred || nextPinned);
    return HubItem(
      id: id,
      type: type,
      typeName: typeName,
      text: text,
      filename: filename,
      size: size,
      hash: hash,
      createTimeUtc: createTimeUtc,
      createTimeLocal: createTimeLocal,
      starred: nextStarred,
      pinned: nextPinned,
      isPermanent: nextPerm,
      remainingSeconds: clearRemaining ? null : (nextPerm ? null : (remainingSeconds ?? this.remainingSeconds)),
      fromDevice: fromDevice,
      sourceDeviceId: sourceDeviceId,
      targetDevice: targetDevice,
      category: category ?? this.category,
      tags: tags ?? this.tags,
      hasFile: hasFile,
      downloadUrl: downloadUrl,
    );
  }

  factory HubItem.fromJson(Map<String, dynamic> j) {
    final typeVal = (j['type'] as num?)?.toInt() ?? 0;
    final starredVal = j['starred'] == true || j['starred'] == 1;
    final pinnedVal = j['pinned'] == true || j['pinned'] == 1;
    final permVal = j['isPermanent'] == true || starredVal || pinnedVal;
    final remRaw = j['remainingSeconds'];
    final remSec = remRaw is num ? remRaw.toInt() : null;
    final dl = j['downloadUrl'] as String?;
    return HubItem(
      id: (j['id'] as num?)?.toInt() ?? 0,
      type: typeVal,
      typeName: (j['typeName'] as String?) ??
          switch (typeVal) { 0 => 'Text', 1 => 'File', 2 => 'Image', 3 => 'Group', _ => 'File' },
      text: (j['text'] as String?) ?? '',
      filename: (j['filename'] as String?) ?? '',
      size: (j['size'] as num?)?.toInt() ?? 0,
      hash: (j['hash'] as String?) ?? '',
      createTimeUtc: (j['createTimeUtc'] as String?) ?? '',
      createTimeLocal: (j['createTimeLocal'] as String?) ?? '',
      starred: starredVal,
      pinned: pinnedVal,
      isPermanent: permVal,
      remainingSeconds: permVal ? null : remSec,
      fromDevice: (j['fromDevice'] as String?) ?? '',
      sourceDeviceId: (j['sourceDeviceId'] as String?) ?? '',
      targetDevice: (j['targetDevice'] as String?) ?? '',
      category: (j['category'] as String?) ?? '其他',
      tags: ((j['tags'] as List?) ?? const <dynamic>[]).map((e) => '$e').toList(),
      hasFile: j['hasFile'] == true,
      downloadUrl: (dl == null || dl.isEmpty) ? null : dl,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'type': type,
        'typeName': typeName,
        'text': text,
        'filename': filename,
        'size': size,
        'hash': hash,
        'createTimeUtc': createTimeUtc,
        'createTimeLocal': createTimeLocal,
        'starred': starred,
        'pinned': pinned,
        'isPermanent': isPermanent,
        'remainingSeconds': remainingSeconds,
        'fromDevice': fromDevice,
        'sourceDeviceId': sourceDeviceId,
        'targetDevice': targetDevice,
        'category': category,
        'tags': tags,
        'hasFile': hasFile,
        'downloadUrl': downloadUrl,
      };
}

class HubListResult {
  final int retentionHours;
  final Map<String, int> counts;
  final List<HubItem> items;

  const HubListResult({
    required this.retentionHours,
    required this.counts,
    required this.items,
  });

  factory HubListResult.fromJson(Map<String, dynamic> j) {
    final rawCounts = j['counts'];
    final countsMap = <String, int>{};
    if (rawCounts is Map) {
      rawCounts.forEach((k, v) {
        if (v is num) countsMap['$k'] = v.toInt();
      });
    }
    final parsedItems = ((j['items'] as List?) ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(HubItem.fromJson)
        .toList()
      ..sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        if (a.starred != b.starred) return a.starred ? -1 : 1;
        return b.id.compareTo(a.id);
      });
    return HubListResult(
      retentionHours: (j['retentionHours'] as num?)?.toInt() ?? 72,
      counts: countsMap,
      items: parsedItems,
    );
  }
}

class HubStorageInfo {
  final int total;
  final int used;
  final int free;
  final int? hubBytes;

  const HubStorageInfo({
    required this.total,
    required this.used,
    required this.free,
    this.hubBytes,
  });

  double get usedFraction => total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;

  factory HubStorageInfo.fromJson(Map<String, dynamic> j) {
    final m = j['storage'] is Map<String, dynamic> ? j['storage'] as Map<String, dynamic> : j;
    final total = (m['total'] as num?)?.toInt() ?? 0;
    final used = (m['used'] as num?)?.toInt() ?? 0;
    final free = (m['free'] as num?)?.toInt() ?? max(0, total - used);
    final hub = (m['hubBytes'] as num?)?.toInt();
    return HubStorageInfo(total: total, used: used, free: free, hubBytes: hub);
  }
}

/// HTTP client for the SyncHub Cloud Center (`synchub_server.py`).
class HubApi {
  String base;
  String token;
  String basicUser;
  String basicPass;
  final HttpClient http;

  HubApi({
    required String gatewayServerUrl,
    this.token = '',
    String? hubBaseOverride,
    this.basicUser = '',
    this.basicPass = '',
    HttpClient? httpClient,
  })  : base = deriveOrigin(gatewayServerUrl, override: hubBaseOverride),
        http = httpClient ??
            (HttpClient()
              ..connectionTimeout = const Duration(seconds: 20)
              ..idleTimeout = const Duration(seconds: 90));

  /// Derives the SyncHub origin from `gatewayServerUrl` (e.g. strips trailing
  /// `/gw` from `https://020814.xyz/gw` -> `https://020814.xyz`), or uses
  /// [override] if explicitly provided.
  static String deriveOrigin(String gatewayServerUrl, {String? override}) {
    var raw = (override != null && override.trim().isNotEmpty) ? override.trim() : gatewayServerUrl.trim();
    if (raw.isEmpty) return '';
    if (!raw.contains('://')) raw = 'https://$raw';
    raw = raw.replaceAll(RegExp(r'/+$'), '');
    if (raw.endsWith('/gw')) {
      raw = raw.substring(0, raw.length - 3);
    } else if (raw.endsWith('/hub')) {
      raw = raw.substring(0, raw.length - 4);
    }
    return raw.replaceAll(RegExp(r'/+$'), '');
  }

  String get _authHeader {
    if (basicUser.isNotEmpty) {
      return 'Basic ${base64.encode(utf8.encode('$basicUser:$basicPass'))}';
    }
    if (token.isNotEmpty) {
      return 'Bearer $token';
    }
    return '';
  }

  void _applyAuth(HttpClientRequest req) {
    final auth = _authHeader;
    if (auth.isNotEmpty) {
      req.headers.set('authorization', auth);
    }
  }

  Uri _resolve(String pathAndQuery) {
    if (base.isEmpty) throw ApiException(0, 'SyncHub server URL not configured');
    if (pathAndQuery.startsWith('http://') || pathAndQuery.startsWith('https://')) {
      return Uri.parse(pathAndQuery);
    }
    final sep = pathAndQuery.startsWith('/') ? '' : '/';
    return Uri.parse('$base$sep$pathAndQuery');
  }

  Future<Uint8List> _readResponseBytes(HttpClientResponse resp, {int maxBytes = 64 << 20}) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp.timeout(const Duration(seconds: 60))) {
      builder.add(chunk);
      if (builder.length > maxBytes) {
        throw ApiException(resp.statusCode, 'response exceeded $maxBytes bytes');
      }
    }
    return builder.takeBytes();
  }

  Future<Map<String, dynamic>> _jsonRequest(
    String method,
    String pathAndQuery, {
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final req = await http.openUrl(method, _resolve(pathAndQuery)).timeout(const Duration(seconds: 20));
    _applyAuth(req);
    if (body != null) {
      final encoded = utf8.encode(jsonEncode(body));
      req.headers.contentType = ContentType.json;
      req.contentLength = encoded.length;
      req.add(encoded);
    }
    final resp = await req.close().timeout(timeout);
    final bytes = await _readResponseBytes(resp);
    final text = utf8.decode(bytes, allowMalformed: true);
    if (resp.statusCode >= 300) {
      throw ApiException(resp.statusCode, text);
    }
    if (text.trim().isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{'data': decoded};
  }

  /// `GET /api/hub/items`
  Future<HubListResult> listItems({
    String category = '',
    String q = '',
    bool starred = false,
    bool pinned = false,
    int limit = 300,
  }) async {
    final params = <String>[
      'limit=$limit',
      if (category.isNotEmpty && category != '全部') 'category=${Uri.encodeComponent(category)}',
      if (q.trim().isNotEmpty) 'q=${Uri.encodeComponent(q.trim())}',
      if (starred) 'starred=1',
      if (pinned) 'pinned=1',
    ].join('&');
    final j = await _jsonRequest('GET', '/api/hub/items?$params');
    return HubListResult.fromJson(j);
  }

  /// `PUT /api/hub/upload` — streams [file] directly from disk with explicit
  /// `Content-Length` and double-percent-encoded `filename` query parameter
  /// (`synchub_server.py` executes `parse_qs` followed by `urllib.parse.unquote`).
  Future<HubItem> uploadFile(
    File file, {
    String? filename,
    String from = '',
    String fromId = '',
    String to = '',
    bool starred = false,
    bool pinned = false,
    String category = '',
    void Function(int sent, int total)? onProgress,
  }) async {
    final rawName = (filename != null && filename.trim().isNotEmpty) ? filename.trim() : p.basename(file.path);
    final total = await file.length();
    final doubleEncodedName = Uri.encodeComponent(Uri.encodeComponent(rawName));
    final qp = <String>[
      'filename=$doubleEncodedName',
      if (from.isNotEmpty) 'from=${Uri.encodeComponent(from)}',
      if (fromId.isNotEmpty) 'from_id=${Uri.encodeComponent(fromId)}',
      if (to.isNotEmpty) 'to=${Uri.encodeComponent(to)}',
      'starred=${starred ? '1' : '0'}',
      'pinned=${pinned ? '1' : '0'}',
      if (category.isNotEmpty) 'category=${Uri.encodeComponent(category)}',
    ].join('&');

    final req = await http.openUrl('PUT', _resolve('/api/hub/upload?$qp')).timeout(const Duration(seconds: 30));
    _applyAuth(req);
    req.headers.contentType = ContentType.binary;
    req.contentLength = total;

    var sent = 0;
    onProgress?.call(0, total);
    final stream = file.openRead().map((chunk) {
      sent += chunk.length;
      onProgress?.call(sent, total);
      return chunk;
    }).timeout(const Duration(seconds: 120));
    await req.addStream(stream);

    final resp = await req.close().timeout(const Duration(seconds: 120));
    final bytes = await _readResponseBytes(resp);
    final text = utf8.decode(bytes, allowMalformed: true);
    if (resp.statusCode >= 300) {
      throw ApiException(resp.statusCode, text);
    }
    final j = jsonDecode(text) as Map<String, dynamic>;
    if (j['ok'] == false) {
      throw ApiException(resp.statusCode, (j['error'] as String?) ?? 'upload rejected');
    }
    return HubItem.fromJson((j['item'] as Map<String, dynamic>?) ?? const <String, dynamic>{});
  }

  /// `POST /api/hub/text`
  Future<HubItem> postText(
    String text, {
    String from = '',
    bool starred = false,
    bool pinned = false,
    String category = '文本',
    bool syncClipboard = true,
  }) async {
    final j = await _jsonRequest(
      'POST',
      '/api/hub/text',
      body: <String, dynamic>{
        'text': text,
        if (from.isNotEmpty) 'from': from,
        'starred': starred,
        'pinned': pinned,
        'category': category,
        'syncClipboard': syncClipboard,
      },
    );
    if (j['ok'] == false) {
      throw ApiException(400, (j['error'] as String?) ?? 'postText failed');
    }
    return HubItem.fromJson((j['item'] as Map<String, dynamic>?) ?? const <String, dynamic>{});
  }

  /// `POST /api/hub/item/$id/update`
  Future<HubItem> updateItem(
    int id, {
    bool? starred,
    bool? pinned,
    String? category,
  }) async {
    final body = <String, dynamic>{
      'starred': ?starred,
      'pinned': ?pinned,
      if (category != null && category.isNotEmpty) 'category': category,
    };
    final j = await _jsonRequest('POST', '/api/hub/item/$id/update', body: body);
    if (j['ok'] == false) {
      throw ApiException(400, (j['error'] as String?) ?? 'updateItem failed');
    }
    return HubItem.fromJson((j['item'] as Map<String, dynamic>?) ?? const <String, dynamic>{});
  }

  /// `POST /api/hub/item/$id/delete`
  Future<void> deleteItem(int id) async {
    await _jsonRequest('POST', '/api/hub/item/$id/delete', body: const <String, dynamic>{});
  }

  /// `POST /api/hub/batch-delete` with explicit IDs.
  Future<int> batchDelete(List<int> ids) async {
    if (ids.isEmpty) return 0;
    final j = await _jsonRequest('POST', '/api/hub/batch-delete', body: <String, dynamic>{'ids': ids});
    return (j['deletedCount'] as num?)?.toInt() ?? 0;
  }

  /// `POST /api/hub/batch-delete` (`{"mode": "unstarred"}`) — deletes all
  /// non-starred and non-pinned temporary items.
  Future<int> cleanupUnstarred() async {
    final j = await _jsonRequest(
      'POST',
      '/api/hub/batch-delete',
      body: const <String, dynamic>{'mode': 'unstarred'},
    );
    return (j['deletedCount'] as num?)?.toInt() ?? 0;
  }

  /// `GET /api/hub/storage`
  Future<HubStorageInfo> storageInfo() async {
    final j = await _jsonRequest('GET', '/api/hub/storage');
    return HubStorageInfo.fromJson(j);
  }

  /// `GET /api/hub/auto-pull`
  Future<(int latestId, List<HubItem> items)> autoPull({
    required int sinceId,
    required String device,
    String deviceId = '',
  }) async {
    final qp = <String>[
      'since_id=$sinceId',
      'device=${Uri.encodeComponent(device.toLowerCase())}',
      if (deviceId.isNotEmpty) 'device_id=${Uri.encodeComponent(deviceId)}',
    ].join('&');
    final j = await _jsonRequest('GET', '/api/hub/auto-pull?$qp');
    final latestId = (j['latestId'] as num?)?.toInt() ?? sinceId;
    final items = ((j['items'] as List?) ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(HubItem.fromJson)
        .toList();
    return (latestId, items);
  }

  /// `GET ${item.downloadUrl}?inline=1` into memory (bounded by [maxBytes]).
  Future<Uint8List> downloadBytes(HubItem item, {int maxBytes = 20 << 20}) async {
    final dl = item.downloadUrl;
    if (dl == null || dl.isEmpty) {
      throw ApiException(404, 'item ${item.id} has no downloadable file');
    }
    final sep = dl.contains('?') ? '&' : '?';
    final req = await http.getUrl(_resolve('$dl${sep}inline=1')).timeout(const Duration(seconds: 30));
    _applyAuth(req);
    final resp = await req.close().timeout(const Duration(seconds: 60));
    if (resp.statusCode >= 300) {
      final errBody = await _readResponseBytes(resp, maxBytes: 8192);
      throw ApiException(resp.statusCode, utf8.decode(errBody, allowMalformed: true));
    }
    if (resp.contentLength > maxBytes) {
      await resp.drain<void>();
      throw ApiException(413, 'file exceeds preview limit (${resp.contentLength} > $maxBytes)');
    }
    return _readResponseBytes(resp, maxBytes: maxBytes);
  }

  /// Finds an existing local copy in [recvDir] (`safeName` or `base (n).ext`)
  /// whose byte size matches [expectedSize] (`> 0`).
  static Future<String?> _findSameSizeCopy(String recvDir, String safeName, int expectedSize) async {
    if (expectedSize <= 0) return null;
    final stem = p.basenameWithoutExtension(safeName);
    final ext = p.extension(safeName);
    for (var i = 0; i < 1000; i++) {
      final candidateName = i == 0 ? safeName : '$stem ($i)$ext';
      final candidatePath = p.join(recvDir, candidateName);
      final st = await File(candidatePath).stat();
      if (st.type == FileSystemEntityType.notFound) {
        if (i == 0) continue; // original may have been moved while `base (1).ext` remains
        return null;
      }
      if (st.type == FileSystemEntityType.file && st.size == expectedSize) {
        return candidatePath;
      }
    }
    return null;
  }

  static Future<String> _uniqueCollisionPath(String recvDir, String safeName) async {
    final first = p.join(recvDir, safeName);
    if (await FileSystemEntity.type(first, followLinks: false) == FileSystemEntityType.notFound &&
        await FileSystemEntity.type('$first.downloading', followLinks: false) == FileSystemEntityType.notFound) {
      return first;
    }
    final stem = p.basenameWithoutExtension(safeName);
    final ext = p.extension(safeName);
    for (var i = 1;; i++) {
      final cand = p.join(recvDir, '$stem ($i)$ext');
      if (await FileSystemEntity.type(cand, followLinks: false) == FileSystemEntityType.notFound &&
          await FileSystemEntity.type('$cand.downloading', followLinks: false) == FileSystemEntityType.notFound) {
        return cand;
      }
    }
  }

  /// Downloads [item] into [recvDir] via `<dest>.downloading`:
  /// - Skips network transfer if an existing file (`name.ext` or `name (n).ext`)
  ///   already has identical byte size (`item.size > 0`), returning its path.
  /// - Otherwise streams to `<dest>.downloading` and atomically renames to
  ///   `dest` (using `base (1).ext` when a different-sized file exists).
  Future<String> downloadToDir(
    HubItem item,
    String recvDir, {
    void Function(int got, int total)? onProgress,
  }) async {
    final (_, path) = await _downloadToDirInternal(item, recvDir, onProgress: onProgress);
    return path;
  }

  Future<(bool skippedExisting, String path)> _downloadToDirInternal(
    HubItem item,
    String recvDir, {
    void Function(int got, int total)? onProgress,
  }) async {
    final dl = item.downloadUrl;
    if (dl == null || dl.isEmpty) {
      throw ApiException(404, 'item ${item.id} has no downloadUrl');
    }
    await Directory(recvDir).create(recursive: true);
    final safeName = sanitizeHubFilename(
      item.filename,
      fallback: 'file_${item.id}',
    );

    final existingSameSize = await _findSameSizeCopy(recvDir, safeName, item.size);
    if (existingSameSize != null) {
      onProgress?.call(item.size, item.size);
      return (true, existingSameSize);
    }

    var destPath = await _uniqueCollisionPath(recvDir, safeName);
    final tempFile = File('$destPath.downloading');
    IOSink? sink;
    try {
      final req = await http.getUrl(_resolve(dl)).timeout(const Duration(seconds: 30));
      _applyAuth(req);
      final resp = await req.close().timeout(const Duration(seconds: 60));
      if (resp.statusCode >= 300) {
        final errBody = await _readResponseBytes(resp, maxBytes: 8192);
        throw ApiException(resp.statusCode, utf8.decode(errBody, allowMalformed: true));
      }

      final expectedLen = resp.contentLength >= 0 ? resp.contentLength : item.size;
      if (await tempFile.exists()) await tempFile.delete();
      sink = tempFile.openWrite();
      var got = 0;
      onProgress?.call(0, expectedLen);
      await for (final chunk in resp.timeout(const Duration(seconds: 120))) {
        sink.add(chunk);
        got += chunk.length;
        onProgress?.call(got, expectedLen);
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (resp.contentLength >= 0 && got != resp.contentLength) {
        throw ApiException(502, 'incomplete download ($got / ${resp.contentLength})');
      }

      // Guard against concurrent arrival of the same filename while streaming.
      if (await FileSystemEntity.type(destPath, followLinks: false) != FileSystemEntityType.notFound) {
        final st = await File(destPath).stat();
        if (st.type == FileSystemEntityType.file && got > 0 && st.size == got) {
          if (await tempFile.exists()) await tempFile.delete();
          return (true, destPath);
        }
        destPath = await _uniqueCollisionPath(recvDir, safeName);
      }

      await tempFile.rename(destPath);
      return (false, destPath);
    } catch (_) {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}
      rethrow;
    }
  }

  void close() => http.close(force: true);
}

/// Background auto-receive loop (`S4`) polling `/api/hub/auto-pull` for newly
/// uploaded or targeted offline files while suppressing clipboard self-echoes.
class AutoPuller {
  static const int maxPoisonRetries = 3;

  final HubApi hub;
  final String supportDir;
  String platform;
  String deviceId;
  String recvDir;
  final String Function()? recvDirProvider;
  final bool Function(String hash)? isKnownHash;
  final FutureOr<void> Function(HubItem item, String savedPath)? onReceived;
  final void Function(String message)? onLog;
  final Duration baseInterval;
  final int initialLegacyLastId;

  /// Optional legacy paths override for isolated unit testing.
  final List<String>? legacyPathsOverride;

  int _lastId = 0;
  bool _initialized = false;
  bool _running = false;
  bool _busy = false;
  bool screenOff = false;
  int _consecutivePollErrors = 0;
  Timer? _timer;
  final Map<int, int> _itemFailures = <int, int>{};

  AutoPuller({
    required this.hub,
    required this.supportDir,
    required this.platform,
    required this.deviceId,
    required this.recvDir,
    this.recvDirProvider,
    this.isKnownHash,
    this.onReceived,
    this.onLog,
    this.baseInterval = const Duration(seconds: 6),
    int? lastHubId,
    this.legacyPathsOverride,
  }) : initialLegacyLastId = lastHubId ?? 0;

  File get stateFile => File(p.join(supportDir, 'hub_receiver_state.json'));
  int get lastId => _lastId;
  bool get isRunning => _running;

  void _log(String msg) => onLog?.call('[auto-pull] $msg');

  String get _effectiveRecvDir => recvDirProvider != null ? recvDirProvider!() : recvDir;

  /// Initializes cursor state from `<supportDir>/hub_receiver_state.json`, or
  /// migrates the maximum `last_id` from legacy Windows / macOS / Android state
  /// files on first launch.
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;

    final sf = stateFile;
    if (await sf.exists()) {
      final v = await _parseStateFile(sf);
      if (v > 0) {
        _lastId = v;
        return;
      }
    }

    var best = max(0, initialLegacyLastId);
    final candidates = legacyPathsOverride ?? _defaultLegacyStatePaths();
    for (final rawPath in candidates) {
      if (rawPath.isEmpty) continue;
      final f = File(rawPath);
      if (!await f.exists()) continue;
      final parsed = await _parseStateFile(f);
      if (parsed > best) best = parsed;
    }

    if (best > 0) {
      _lastId = best;
      await _persistLastId(best);
      _log('migrated legacy last_id=$best');
    }
  }

  static List<String> _defaultLegacyStatePaths() {
    final paths = <String>[];
    final appData = Platform.environment['APPDATA'] ?? '';
    if (appData.isNotEmpty) {
      paths.add(p.join(appData, 'SyncClipboard', 'synchub_win_state.json'));
    }
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
    if (home.isNotEmpty) {
      paths.add(p.join(home, 'Library', 'Application Support', 'SyncHub', 'receiver_state.json'));
      paths.add(p.join(home, '.synchub', 'last_id.txt'));
    }
    return paths;
  }

  static Future<int> _parseStateFile(File f) async {
    try {
      final raw = (await f.readAsString()).trim();
      if (raw.isEmpty) return 0;
      final directInt = int.tryParse(raw);
      if (directInt != null) return max(0, directInt);
      final j = jsonDecode(raw);
      if (j is Map) {
        final v = j['last_id'];
        if (v is num) return max(0, v.toInt());
        if (v is String) return max(0, int.tryParse(v) ?? 0);
      }
    } catch (_) {}
    return 0;
  }

  Future<void> _persistLastId(int id) async {
    _lastId = id;
    try {
      final sf = stateFile;
      await sf.parent.create(recursive: true);
      final tmp = File('${sf.path}.tmp');
      final payload = jsonEncode(<String, dynamic>{
        'last_id': id,
        'updated_at': DateTime.now().millisecondsSinceEpoch / 1000.0,
      });
      await tmp.writeAsString(payload);
      await tmp.rename(sf.path);
    } catch (e) {
      _log('save state failed: $e');
    }
  }

  static bool _isTransientNetworkError(Object err) =>
      err is SocketException ||
      err is HandshakeException ||
      err is TlsException ||
      err is TimeoutException ||
      err is HttpException;

  Duration get _nextDelay {
    var secs = baseInterval.inMilliseconds / 1000.0;
    if (_consecutivePollErrors > 0) {
      secs = min(30.0, max(secs, 2.0) * pow(2, min(_consecutivePollErrors - 1, 5)));
    }
    if (screenOff) {
      secs = min(120.0, secs * 4.0);
    }
    return Duration(milliseconds: (secs * 1000).round());
  }

  void start() {
    if (_running) return;
    _running = true;
    _consecutivePollErrors = 0;
    _scheduleNext(const Duration(milliseconds: 500));
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  void kick() {
    if (!_running) return;
    _timer?.cancel();
    _scheduleNext(Duration.zero);
  }

  void _scheduleNext(Duration delay) {
    _timer?.cancel();
    if (!_running) return;
    _timer = Timer(delay, () async {
      await pollOnce();
      if (_running) _scheduleNext(_nextDelay);
    });
  }

  /// Runs a single auto-pull cycle. Returns the number of newly saved files.
  Future<int> pollOnce() async {
    if (_busy) return 0;
    _busy = true;
    try {
      await ensureInitialized();
      final since = _lastId;
      final (latestId, items) = await hub.autoPull(
        sinceId: since,
        device: platform,
        deviceId: deviceId,
      );
      _consecutivePollErrors = 0;

      // Baseline initialization: record server latestId without downloading historical items.
      if (since <= 0) {
        if (latestId > 0) {
          await _persistLastId(latestId);
          _log('baseline initialized at last_id=$latestId');
        }
        return 0;
      }

      var savedCount = 0;
      for (final item in items) {
        // Cross-channel dedup: skip clipboard images/files we already pushed or pulled.
        if (item.hash.isNotEmpty && (isKnownHash?.call(item.hash) ?? false)) {
          _log('skipping known clipboard item #${item.id} (${item.filename})');
          if (item.id > _lastId) await _persistLastId(item.id);
          continue;
        }
        if (!item.hasFile || item.downloadUrl == null || item.downloadUrl!.isEmpty) {
          if (item.id > _lastId) await _persistLastId(item.id);
          continue;
        }

        try {
          final (skippedExisting, savedPath) = await hub._downloadToDirInternal(
            item,
            _effectiveRecvDir,
          );
          _itemFailures.remove(item.id);
          if (item.id > _lastId) await _persistLastId(item.id);
          if (!skippedExisting) {
            savedCount++;
            await onReceived?.call(item, savedPath);
          }
        } catch (err) {
          if (isStatus(err, 404)) {
            _log('item #${item.id} returned 404 (deleted on server), advancing cursor');
            _itemFailures.remove(item.id);
            if (item.id > _lastId) await _persistLastId(item.id);
            continue;
          }

          if (_isTransientNetworkError(err)) {
            if (item.id - 1 > _lastId) await _persistLastId(item.id - 1);
            _consecutivePollErrors++;
            _log('network error downloading #${item.id}: $err');
            return savedCount;
          }

          final count = (_itemFailures[item.id] ?? 0) + 1;
          if (count >= maxPoisonRetries) {
            _itemFailures.remove(item.id);
            _log('item #${item.id} failed $count times ($err); skipping poison record');
            if (item.id > _lastId) await _persistLastId(item.id);
            continue;
          } else {
            _itemFailures[item.id] = count;
            if (item.id - 1 > _lastId) await _persistLastId(item.id - 1);
            _consecutivePollErrors++;
            _log('item #${item.id} failed ($count/$maxPoisonRetries): $err');
            return savedCount;
          }
        }
      }

      if (latestId > _lastId) {
        await _persistLastId(latestId);
      }
      return savedCount;
    } catch (err) {
      _consecutivePollErrors++;
      _log('poll failed: $err');
      return 0;
    } finally {
      _busy = false;
    }
  }
}
