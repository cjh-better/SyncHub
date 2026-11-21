import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'clip_group_zip.dart';
import 'hub_api.dart';
import 'manifest.dart';

// ---------------------------------------------------------------------------
// Exact SyncClipboard SHA-256 & URL Encoding Helpers
// ---------------------------------------------------------------------------

const String _hexUpperDigits = '0123456789ABCDEF';

/// 64-character UPPERCASE hex SHA-256 digest of [bytes].
String sha256Upper(List<int> bytes) {
  final digest = crypto.sha256.convert(bytes).bytes;
  final out = StringBuffer();
  for (final b in digest) {
    out
      ..write(_hexUpperDigits[(b >> 4) & 0x0f])
      ..write(_hexUpperDigits[b & 0x0f]);
  }
  return out.toString();
}

/// 64-character UPPERCASE hex SHA-256 of UTF-8 encoded [text].
String sha256TextUpper(String text) => sha256Upper(utf8.encode(text));

/// SyncClipboard v3.1.1 / v3.3.3 profile hash for `Image` and `File` entries:
/// `SHA256_UPPER(UTF8("$fileName|$contentHashUpper"))`.
String fileProfileHash(String fileName, String contentHash) =>
    sha256TextUpper('$fileName|${contentHash.toUpperCase()}');

/// Strict RFC 3986 percent-encoding for `/file/<name>` segments:
/// only ASCII unreserved `[A-Za-z0-9-._~]` stay literal; spaces become `%20`
/// (never `+`), `+` becomes `%2B`, `#` becomes `%23`, and UTF-8 multibyte
/// characters become `%XX`.
String encodeSyncClipboardFileName(String name) {
  final bytes = utf8.encode(name);
  final sb = StringBuffer();
  for (final b in bytes) {
    final isUnreserved = (b >= 0x41 && b <= 0x5A) || // A-Z
        (b >= 0x61 && b <= 0x7A) || // a-z
        (b >= 0x30 && b <= 0x39) || // 0-9
        b == 0x2D || // -
        b == 0x2E || // .
        b == 0x5F || // _
        b == 0x7E; // ~
    if (isUnreserved) {
      sb.writeCharCode(b);
    } else {
      sb
        ..write('%')
        ..write(_hexUpperDigits[(b >> 4) & 0x0f])
        ..write(_hexUpperDigits[b & 0x0f]);
    }
  }
  return sb.toString();
}

String _defaultStamp() {
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final rng = Random.secure();
  final hex8 = List<int>.generate(4, (_) => rng.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${now.year}-${two(now.month)}-${two(now.day)}_'
      '${two(now.hour)}-${two(now.minute)}-${two(now.second)}_$hex8';
}

// ---------------------------------------------------------------------------
// Errors & Backoff
// ---------------------------------------------------------------------------

enum ClipErrorKind { network, http, decoding, local, cancelled }

class ClipSyncException implements Exception {
  final ClipErrorKind kind;
  final int? statusCode;
  final String message;

  const ClipSyncException._(this.kind, this.message, {this.statusCode});

  factory ClipSyncException.network(String message) =>
      ClipSyncException._(ClipErrorKind.network, message);
  factory ClipSyncException.http(int statusCode, String body) =>
      ClipSyncException._(ClipErrorKind.http, body, statusCode: statusCode);
  factory ClipSyncException.decoding(String message) =>
      ClipSyncException._(ClipErrorKind.decoding, message);
  factory ClipSyncException.local(String message) =>
      ClipSyncException._(ClipErrorKind.local, message);
  factory ClipSyncException.cancelled() =>
      const ClipSyncException._(ClipErrorKind.cancelled, '已取消');

  bool get isNetwork => kind == ClipErrorKind.network;
  bool get isCancelled => kind == ClipErrorKind.cancelled;

  @override
  String toString() => switch (kind) {
        ClipErrorKind.network => '网络错误：$message',
        ClipErrorKind.http => switch (statusCode) {
            401 || 403 => '认证失败 (HTTP $statusCode)',
            404 => '远端文件不存在 (HTTP 404)',
            _ => 'HTTP $statusCode${message.trim().isEmpty ? '' : ': ${message.trim()}'}',
          },
        ClipErrorKind.decoding => '解析错误：$message',
        ClipErrorKind.local => message,
        ClipErrorKind.cancelled => '已取消',
      };
}

/// Adaptive polling backoff: `1.5s` steady -> `2s, 4s, 8s, 16s, 30s` on error ->
/// instant reset to `1.5s` on success, with optional 4x multiplier when screen is off.
class ClipBackoff {
  final double baseSeconds;
  final double capSeconds;
  int _failures = 0;

  ClipBackoff({this.baseSeconds = 1.5, this.capSeconds = 15.0});

  int get failures => _failures;

  void success() => _failures = 0;

  void failure() {
    if (_failures < 10) _failures++;
  }

  double get delaySeconds => _failures == 0
      ? baseSeconds
      : min(capSeconds, max(baseSeconds, 2.0) * pow(2.0, _failures - 1));

  Duration delay({bool screenOff = false}) {
    final secs = screenOff ? min(30.0, delaySeconds * 4.0) : delaySeconds;
    return Duration(milliseconds: (secs * 1000).round());
  }
}

// ---------------------------------------------------------------------------
// ClipProfile (SyncClipboard.json Wire Model)
// ---------------------------------------------------------------------------

class ClipProfile {
  final String type; // Text | Image | File | Group
  final String hash;
  final String text;
  final bool hasData;
  final String? dataName;
  final String? transferDataHash;
  final int? size;

  const ClipProfile({
    required this.type,
    required this.hash,
    required this.text,
    required this.hasData,
    this.dataName,
    this.transferDataHash,
    this.size,
  });

  /// Enforces `hasDataFile = hasData && (dataName != null && dataName!.isNotEmpty)`.
  bool get hasDataFile => hasData && dataName != null && dataName!.isNotEmpty;

  /// Canonical uppercase identity key of this profile.
  String get key =>
      (hash.isEmpty ? sha256TextUpper('$type|$text|${dataName ?? ''}') : hash).toUpperCase();

  /// Tolerantly parses SyncClipboard v3.3.3 camelCase, SyncHub `/api/hub/text`
  /// PascalCase, and legacy v2 (`File` / `Clipboard`) JSON payloads.
  static ClipProfile parse(Object source) {
    final Map<String, dynamic> o;
    try {
      if (source is Map<String, dynamic>) {
        o = source;
      } else if (source is String) {
        final decoded = jsonDecode(source);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('not a JSON object');
        }
        o = decoded;
      } else if (source is List<int>) {
        final decoded = jsonDecode(utf8.decode(source));
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('not a JSON object');
        }
        o = decoded;
      } else {
        throw const FormatException('unsupported ClipProfile input');
      }
    } catch (e) {
      throw ClipSyncException.decoding('SyncClipboard.json 不是有效的 JSON ($e)');
    }

    dynamic val(String camel) {
      final pascal = '${camel[0].toUpperCase()}${camel.substring(1)}';
      if (o.containsKey(camel) && o[camel] != null) return o[camel];
      if (o.containsKey(pascal) && o[pascal] != null) return o[pascal];
      return null;
    }

    String? str(String name) {
      final v = val(name);
      if (v == null) return null;
      if (v is String) return v;
      if (v is num || v is bool) return '$v';
      return null;
    }

    bool flag(String name) {
      final v = val(name);
      if (v is bool) return v;
      if (v is num) return v != 0;
      if (v is String) return v.toLowerCase() == 'true' || v == '1';
      return false;
    }

    int? integer(String name) {
      final v = val(name);
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v);
      return null;
    }

    final type = str('type') ?? 'Text';
    final text = str('text') ?? str('clipboard') ?? '';
    var dataName = str('dataName');
    if (dataName == null) {
      final legacyFile = str('file');
      if (legacyFile != null && legacyFile.isNotEmpty) {
        dataName = legacyFile;
      }
    }
    final hasData = flag('hasData') ||
        (dataName != null && dataName.isNotEmpty && type != 'Text');
    final tdHash = str('transferDataHash');

    return ClipProfile(
      type: type,
      hash: str('hash') ?? '',
      text: text,
      hasData: hasData,
      dataName: dataName,
      transferDataHash: (tdHash == null || tdHash.isEmpty) ? null : tdHash,
      size: integer('size'),
    );
  }

  /// Exact SyncClipboard v3.3.3 JSON serialization.
  ///
  /// **Critical invariant**: `transferDataHash` is NEVER included when
  /// `hasData == false`.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type,
        'hash': hash,
        'text': text,
        'hasData': hasData,
        'dataName': hasData ? dataName : null,
        if (hasData && transferDataHash != null && transferDataHash!.isNotEmpty)
          'transferDataHash': transferDataHash,
        if (size != null) 'size': size,
      };

  Uint8List toJsonBytes() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  @override
  bool operator ==(Object other) =>
      other is ClipProfile &&
      other.type == type &&
      other.hash == hash &&
      other.text == text &&
      other.hasData == hasData &&
      other.dataName == dataName &&
      other.transferDataHash == transferDataHash &&
      other.size == size;

  @override
  int get hashCode =>
      Object.hash(type, hash, text, hasData, dataName, transferDataHash, size);
}

// ---------------------------------------------------------------------------
// Endpoint Configuration & HTTP Transport
// ---------------------------------------------------------------------------

class ClipEndpointConfig {
  final bool useCustomServer;
  final String gatewayServerUrl;
  final String bearerToken;
  final String customServerUrl;
  final String customUsername;
  final String customPassword;

  const ClipEndpointConfig({
    this.useCustomServer = false,
    this.gatewayServerUrl = '',
    this.bearerToken = '',
    this.customServerUrl = '',
    this.customUsername = '',
    this.customPassword = '',
  });

  factory ClipEndpointConfig.gateway({
    required String serverUrl,
    required String token,
  }) =>
      ClipEndpointConfig(
        useCustomServer: false,
        gatewayServerUrl: serverUrl,
        bearerToken: token,
      );

  factory ClipEndpointConfig.custom({
    required String serverUrl,
    String username = '',
    String password = '',
  }) =>
      ClipEndpointConfig(
        useCustomServer: true,
        customServerUrl: serverUrl,
        customUsername: username,
        customPassword: password,
      );

  String get baseUrl {
    if (useCustomServer) {
      var u = customServerUrl.trim().replaceAll(RegExp(r'/+$'), '');
      if (u.isNotEmpty && !u.contains('://')) u = 'https://$u';
      return u;
    }
    final origin = HubApi.deriveOrigin(gatewayServerUrl);
    return origin.isEmpty ? '' : '$origin/api/hub/sc';
  }

  String get authHeader {
    if (useCustomServer) {
      if (customUsername.isEmpty && customPassword.isEmpty) return '';
      return 'Basic ${base64.encode(utf8.encode('$customUsername:$customPassword'))}';
    }
    return bearerToken.isEmpty ? '' : 'Bearer $bearerToken';
  }

  /// Per-endpoint key used to namespace persisted `clip_state.json` entries.
  String get endpointKey {
    if (useCustomServer) {
      return 'custom|${baseUrl.toLowerCase()}|$customUsername';
    }
    return 'gw|${HubApi.deriveOrigin(gatewayServerUrl).toLowerCase()}';
  }

  bool get isConfigured => baseUrl.isNotEmpty;

  ClipEndpointConfig copyWith({
    bool? useCustomServer,
    String? gatewayServerUrl,
    String? bearerToken,
    String? customServerUrl,
    String? customUsername,
    String? customPassword,
  }) =>
      ClipEndpointConfig(
        useCustomServer: useCustomServer ?? this.useCustomServer,
        gatewayServerUrl: gatewayServerUrl ?? this.gatewayServerUrl,
        bearerToken: bearerToken ?? this.bearerToken,
        customServerUrl: customServerUrl ?? this.customServerUrl,
        customUsername: customUsername ?? this.customUsername,
        customPassword: customPassword ?? this.customPassword,
      );
}

abstract class ClipTransport {
  Future<ClipProfile> getProfile();
  Future<void> putProfile(ClipProfile profile);
  Future<Uint8List> getFile(String name, {required int maxBytes});
  Future<void> putFile(String name, Uint8List bytes);
  void close();
}

class SyncClipboardHttpTransport implements ClipTransport {
  ClipEndpointConfig config;
  final HttpClient _http;

  SyncClipboardHttpTransport(this.config, {HttpClient? httpClient})
      : _http = httpClient ??
            (HttpClient()
              ..connectionTimeout = const Duration(seconds: 15)
              ..idleTimeout = const Duration(seconds: 60));

  Uri _uri(String path) {
    final base = config.baseUrl;
    if (base.isEmpty) {
      throw ClipSyncException.local('尚未配置剪贴板服务器地址');
    }
    return Uri.parse('$base$path');
  }

  Uri _fileUri(String name) => _uri('/file/${encodeSyncClipboardFileName(name)}');

  void _applyHeaders(HttpClientRequest req) {
    final auth = config.authHeader;
    if (auth.isNotEmpty) {
      req.headers.set('authorization', auth);
    }
    req.headers.set('cache-control', 'no-cache');
  }

  static ClipSyncException _wrapIoError(Object err) {
    if (err is ClipSyncException) return err;
    if (err is SocketException ||
        err is HandshakeException ||
        err is TlsException ||
        err is TimeoutException ||
        err is HttpException) {
      return ClipSyncException.network('$err');
    }
    return ClipSyncException.local('$err');
  }

  Future<Uint8List> _readBytes(HttpClientResponse resp, {required int maxBytes}) async {
    final b = BytesBuilder(copy: false);
    await for (final chunk in resp.timeout(const Duration(seconds: 60))) {
      b.add(chunk);
      if (b.length > maxBytes) {
        throw ClipSyncException.local('远端文件超过大小上限 (${humanBytes(b.length)})');
      }
    }
    return b.takeBytes();
  }

  @override
  Future<ClipProfile> getProfile() async {
    try {
      final req = await _http.getUrl(_uri('/SyncClipboard.json')).timeout(const Duration(seconds: 15));
      _applyHeaders(req);
      final resp = await req.close().timeout(const Duration(seconds: 20));
      final body = await _readBytes(resp, maxBytes: 4 << 20);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw ClipSyncException.http(
          resp.statusCode,
          utf8.decode(body.take(256).toList(), allowMalformed: true),
        );
      }
      return ClipProfile.parse(body);
    } catch (e) {
      throw _wrapIoError(e);
    }
  }

  @override
  Future<void> putProfile(ClipProfile profile) async {
    try {
      final payload = profile.toJsonBytes();
      final req = await _http.openUrl('PUT', _uri('/SyncClipboard.json')).timeout(const Duration(seconds: 15));
      _applyHeaders(req);
      req.headers.set('content-type', 'application/json; charset=utf-8');
      req.contentLength = payload.length;
      req.add(payload);
      final resp = await req.close().timeout(const Duration(seconds: 20));
      final body = await _readBytes(resp, maxBytes: 64 << 10);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw ClipSyncException.http(
          resp.statusCode,
          utf8.decode(body.take(256).toList(), allowMalformed: true),
        );
      }
    } catch (e) {
      throw _wrapIoError(e);
    }
  }

  @override
  Future<Uint8List> getFile(String name, {required int maxBytes}) async {
    try {
      final req = await _http.getUrl(_fileUri(name)).timeout(const Duration(seconds: 20));
      _applyHeaders(req);
      final resp = await req.close().timeout(const Duration(seconds: 60));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final errBytes = await _readBytes(resp, maxBytes: 64 << 10);
        throw ClipSyncException.http(
          resp.statusCode,
          utf8.decode(errBytes.take(256).toList(), allowMalformed: true),
        );
      }
      if (resp.contentLength > maxBytes) {
        await resp.drain<void>();
        throw ClipSyncException.local('文件过大 (${humanBytes(resp.contentLength)})');
      }
      return await _readBytes(resp, maxBytes: maxBytes);
    } catch (e) {
      throw _wrapIoError(e);
    }
  }

  @override
  Future<void> putFile(String name, Uint8List bytes) async {
    try {
      final req = await _http.openUrl('PUT', _fileUri(name)).timeout(const Duration(seconds: 30));
      _applyHeaders(req);
      req.headers.set('content-type', 'application/octet-stream');
      req.contentLength = bytes.length;
      req.add(bytes);
      final resp = await req.close().timeout(const Duration(minutes: 5));
      final body = await _readBytes(resp, maxBytes: 64 << 10);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw ClipSyncException.http(
          resp.statusCode,
          utf8.decode(body.take(256).toList(), allowMalformed: true),
        );
      }
    } catch (e) {
      throw _wrapIoError(e);
    }
  }

  @override
  void close() => _http.close(force: true);
}

// ---------------------------------------------------------------------------
// Persisted ClipStateStore (<supportDir>/clip_state.json)
// ---------------------------------------------------------------------------

abstract class ClipStateStore {
  String? get lastRemoteKey;
  set lastRemoteKey(String? value);

  String? get lastRemoteContent;
  set lastRemoteContent(String? value);

  Future<void> flush();
}

class MemoryClipStateStore implements ClipStateStore {
  @override
  String? lastRemoteKey;

  @override
  String? lastRemoteContent;

  MemoryClipStateStore({this.lastRemoteKey, this.lastRemoteContent});

  @override
  Future<void> flush() async {}
}

class FileClipStateStore implements ClipStateStore {
  final File file;
  String _endpointKey;
  final Map<String, Map<String, String?>> _endpoints;
  Future<void> _writeChain = Future<void>.value();

  FileClipStateStore._(this.file, this._endpointKey, this._endpoints);

  static Future<FileClipStateStore> load(File file, String endpointKey) async {
    final map = <String, Map<String, String?>>{};
    if (await file.exists()) {
      try {
        final raw = jsonDecode(await file.readAsString());
        if (raw is Map && raw['endpoints'] is Map) {
          (raw['endpoints'] as Map).forEach((k, v) {
            if (v is Map) {
              map['$k'] = <String, String?>{
                'lastRemoteKey': v['lastRemoteKey'] as String?,
                'lastRemoteContent': v['lastRemoteContent'] as String?,
              };
            }
          });
        }
      } catch (_) {}
    }
    return FileClipStateStore._(file, endpointKey, map);
  }

  String get endpointKey => _endpointKey;

  void switchEndpoint(String newEndpointKey) {
    _endpointKey = newEndpointKey;
  }

  @override
  String? get lastRemoteKey => _endpoints[_endpointKey]?['lastRemoteKey'];

  @override
  set lastRemoteKey(String? value) {
    final slot = _endpoints.putIfAbsent(_endpointKey, () => <String, String?>{});
    if (slot['lastRemoteKey'] == value) return;
    slot['lastRemoteKey'] = value;
    unawaited(flush());
  }

  @override
  String? get lastRemoteContent => _endpoints[_endpointKey]?['lastRemoteContent'];

  @override
  set lastRemoteContent(String? value) {
    final slot = _endpoints.putIfAbsent(_endpointKey, () => <String, String?>{});
    if (slot['lastRemoteContent'] == value) return;
    slot['lastRemoteContent'] = value;
    unawaited(flush());
  }

  @override
  Future<void> flush() {
    final snapshot = <String, dynamic>{
      'endpoints': _endpoints.map(
        (k, v) => MapEntry<String, dynamic>(k, <String, dynamic>{
          'lastRemoteKey': v['lastRemoteKey'],
          'lastRemoteContent': v['lastRemoteContent'],
        }),
      ),
    };
    _writeChain = _writeChain.then((_) async {
      try {
        await file.parent.create(recursive: true);
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(jsonEncode(snapshot));
        await tmp.rename(file.path);
      } catch (_) {}
    });
    return _writeChain;
  }
}

// ---------------------------------------------------------------------------
// ClipSyncEngine (Pure State Machine & Anti-Loop Core)
// ---------------------------------------------------------------------------

sealed class ClipLocalResult {
  const ClipLocalResult();
}

class ClipLocalPushed extends ClipLocalResult {
  final String hash;
  const ClipLocalPushed(this.hash);
}

class ClipLocalSkipped extends ClipLocalResult {
  final String reason;
  const ClipLocalSkipped(this.reason);
}

sealed class ClipRemoteChange {
  const ClipRemoteChange();
}

class ClipRemoteText extends ClipRemoteChange {
  final String text;
  final String hash;
  final bool isTruncated;
  const ClipRemoteText(this.text, {required this.hash, this.isTruncated = false});
}

class ClipRemoteImage extends ClipRemoteChange {
  final String name;
  final Uint8List bytes;
  final String key; // "IMG:<contentHash>"
  final String profileHash;
  const ClipRemoteImage({
    required this.name,
    required this.bytes,
    required this.key,
    required this.profileHash,
  });
}

class ClipRemoteFile extends ClipRemoteChange {
  final String name;
  final Uint8List bytes;
  final String key;
  final String profileHash;
  final bool groupArchive;
  const ClipRemoteFile({
    required this.name,
    required this.bytes,
    required this.key,
    required this.profileHash,
    this.groupArchive = false,
  });
}

/// Protocol-exact SyncClipboard v3.1.1 / v3.3.3 state machine.
class ClipSyncEngine {
  static const int textThreshold = 10240; // UTF-16 code units
  static const int defaultMaxTextBytes = 500 * 1024; // 500 KiB UTF-8
  static const int defaultMaxImageBytes = 20 * 1024 * 1024; // 20 MiB
  static const int defaultMaxFileBytes = 100 * 1024 * 1024; // 100 MiB
  static const int maxRecentHashes = 32;
  static const int maxPoisonFailures = 3;

  ClipTransport transport;
  final ClipStateStore state;
  int maxTextBytes;
  int maxImageBytes;
  int maxFileBytes;
  bool Function() pullImages;
  bool Function() pullFiles;
  void Function(String message)? onLog;
  String Function() nameStamp;

  String? _current;
  int _pushing = 0;
  int _pushGeneration = 0;
  bool _polling = false;
  String? _failKey;
  int _failCount = 0;

  /// 32-entry bounded LRU ring of uppercase profile hashes, `"IMG:<hash>"`,
  /// and `"FILE:<hash>"` for cross-channel `AutoPuller` deduplication.
  final LinkedHashSet<String> _recent = LinkedHashSet<String>();

  ClipSyncEngine({
    required this.transport,
    required this.state,
    this.maxTextBytes = defaultMaxTextBytes,
    this.maxImageBytes = defaultMaxImageBytes,
    this.maxFileBytes = defaultMaxFileBytes,
    bool Function()? pullImages,
    bool Function()? pullFiles,
    this.onLog,
    String Function()? nameStamp,
  })  : pullImages = pullImages ?? (() => true),
        pullFiles = pullFiles ?? (() => true),
        nameStamp = nameStamp ?? _defaultStamp;

  String? get current => _current;
  int get pushGeneration => _pushGeneration;
  List<String> get recentHashes => List<String>.unmodifiable(_recent);

  void _log(String s) => onLog?.call(s);

  void _rememberRecent(String key) {
    final u = key.trim().toUpperCase();
    if (u.isEmpty) return;
    _recent.remove(u);
    _recent.add(u);
    while (_recent.length > maxRecentHashes) {
      _recent.remove(_recent.first);
    }
  }

  /// Cross-channel deduplication query used by `AutoPuller` so clipboard
  /// images/files pushed or pulled here are not redundantly downloaded again.
  /// Touching a hit promotes it to most-recently-used in the 32-entry LRU set.
  bool isKnownHash(String h) {
    if (h.isEmpty) return false;
    final u = h.trim().toUpperCase();
    for (final candidate in <String>[u, 'IMG:$u', 'FILE:$u']) {
      if (_recent.remove(candidate)) {
        _recent.add(candidate);
        return true;
      }
    }
    return false;
  }

  /// Rolls back `current` when an OS clipboard write fails so a subsequent
  /// local copy of the same content is not suppressed as a self-echo.
  void release(String key) {
    if (_current == key.toUpperCase()) {
      _current = null;
    }
  }

  /// Records a value written locally by the app UI itself so the local watcher
  /// treats the resulting OS clipboard event as already known.
  void noteLocal({required String key}) {
    final u = key.toUpperCase();
    _current = u;
    _rememberRecent(u);
  }

  /// Clears echo guards so an explicit manual `"发送当前剪贴板"` action always pushes.
  void clearEchoGuardForManualPush() {
    _current = null;
    state.lastRemoteContent = null;
  }

  static String _safeUtf16Prefix(String text, int maxUnits) {
    if (text.length <= maxUnits) return text;
    var end = maxUnits;
    final lastUnit = text.codeUnitAt(end - 1);
    if (lastUnit >= 0xD800 && lastUnit <= 0xDBFF) {
      end -= 1; // avoid splitting a UTF-16 surrogate pair
    }
    return text.substring(0, end);
  }

  // ----------------------------------------------------------- local -> remote

  Future<ClipLocalResult> onLocalText(String text) async {
    if (text.trim().isEmpty) {
      return const ClipLocalSkipped('空白文字');
    }
    final bytes = Uint8List.fromList(utf8.encode(text));
    if (bytes.length > maxTextBytes) {
      _log('本地文字 ${humanBytes(bytes.length)} 超过上限，跳过');
      return ClipLocalSkipped('文字超过 ${maxTextBytes ~/ 1024} KB，未同步');
    }
    final hash = sha256Upper(bytes);
    if (_current == hash) {
      return const ClipLocalSkipped('与已同步内容相同');
    }
    if (state.lastRemoteContent?.toUpperCase() == hash) {
      _current = hash;
      _rememberRecent(hash);
      return const ClipLocalSkipped('与服务器内容相同');
    }

    _current = hash;
    _pushing++;
    _pushGeneration++;
    try {
      if (text.length > textThreshold) {
        final fileName = 'Text_${nameStamp()}.txt';
        final prefix = _safeUtf16Prefix(text, textThreshold);
        final profile = ClipProfile(
          type: 'Text',
          hash: hash,
          text: prefix,
          hasData: true,
          dataName: fileName,
          transferDataHash: hash,
          size: bytes.length,
        );
        await transport.putFile(fileName, bytes);
        await transport.putProfile(profile);
      } else {
        final profile = ClipProfile(
          type: 'Text',
          hash: hash,
          text: text,
          hasData: false,
          dataName: null,
          size: bytes.length,
        );
        await transport.putProfile(profile);
      }
      state.lastRemoteKey = hash;
      state.lastRemoteContent = hash;
      _rememberRecent(hash);
      _log('已推送文字 (${text.length} 字, #${hash.substring(0, 8)})');
      return ClipLocalPushed(hash);
    } catch (_) {
      if (_current == hash) _current = null;
      rethrow;
    } finally {
      _pushing--;
    }
  }

  Future<ClipLocalResult> onLocalImage(String fileName, Uint8List bytes) async {
    if (bytes.length > maxImageBytes) {
      return ClipLocalSkipped('图片超过 ${humanBytes(maxImageBytes)}，未同步');
    }
    final contentHash = sha256Upper(bytes);
    final ckey = 'IMG:$contentHash';
    if (_current == ckey) {
      return const ClipLocalSkipped('与已同步图片相同');
    }
    if (state.lastRemoteContent?.toUpperCase() == ckey) {
      _current = ckey;
      _rememberRecent(ckey);
      return const ClipLocalSkipped('与服务器图片相同');
    }

    _current = ckey;
    _pushing++;
    _pushGeneration++;
    final profileHash = fileProfileHash(fileName, contentHash);
    final profile = ClipProfile(
      type: 'Image',
      hash: profileHash,
      text: fileName,
      hasData: true,
      dataName: fileName,
      transferDataHash: contentHash,
      size: bytes.length,
    );
    try {
      await transport.putFile(fileName, bytes);
      await transport.putProfile(profile);
      state.lastRemoteKey = profileHash;
      state.lastRemoteContent = ckey;
      _rememberRecent(ckey);
      _rememberRecent(profileHash);
      _log('已推送图片 $fileName (${humanBytes(bytes.length)})');
      return ClipLocalPushed(profileHash);
    } catch (_) {
      if (_current == ckey) _current = null;
      rethrow;
    } finally {
      _pushing--;
    }
  }

  Future<ClipLocalResult> onLocalFile(String fileName, Uint8List bytes) async {
    if (bytes.length > maxFileBytes) {
      return ClipLocalSkipped('文件超过 ${humanBytes(maxFileBytes)}，未同步');
    }
    final contentHash = sha256Upper(bytes);
    final ckey = 'FILE:$contentHash';
    if (_current == ckey) {
      return const ClipLocalSkipped('与已同步文件相同');
    }
    if (state.lastRemoteContent?.toUpperCase() == ckey) {
      _current = ckey;
      _rememberRecent(ckey);
      return const ClipLocalSkipped('与服务器文件相同');
    }

    _current = ckey;
    _pushing++;
    _pushGeneration++;
    final profileHash = fileProfileHash(fileName, contentHash);
    final profile = ClipProfile(
      type: 'File',
      hash: profileHash,
      text: fileName,
      hasData: true,
      dataName: fileName,
      transferDataHash: contentHash,
      size: bytes.length,
    );
    try {
      await transport.putFile(fileName, bytes);
      await transport.putProfile(profile);
      state.lastRemoteKey = profileHash;
      state.lastRemoteContent = ckey;
      _rememberRecent(ckey);
      _rememberRecent(profileHash);
      _log('已推送文件 $fileName (${humanBytes(bytes.length)})');
      return ClipLocalPushed(profileHash);
    } catch (_) {
      if (_current == ckey) _current = null;
      rethrow;
    } finally {
      _pushing--;
    }
  }

  // ----------------------------------------------------------- remote -> local

  /// Polls `GET /SyncClipboard.json` once. Returns `null` when nothing should
  /// be written to the local clipboard.
  Future<ClipRemoteChange?> pollRemote() async {
    if (_polling || _pushing > 0) return null;
    _polling = true;
    final gen = _pushGeneration;
    try {
      final p = await transport.getProfile();
      if (gen != _pushGeneration || _pushing > 0) {
        return null;
      }
      return await _handleRemoteProfile(p, gen);
    } finally {
      _polling = false;
    }
  }

  ClipRemoteChange? _settle(String key, ClipRemoteChange? change, String? content) {
    state.lastRemoteKey = key;
    state.lastRemoteContent = content;
    _failKey = null;
    _failCount = 0;
    return change;
  }

  Never _failRemote(String key, Object rawErr) {
    final err = rawErr is ClipSyncException
        ? rawErr
        : SyncClipboardHttpTransport._wrapIoError(rawErr);
    if (!err.isNetwork) {
      if (_failKey == key) {
        _failCount++;
      } else {
        _failKey = key;
        _failCount = 1;
      }
      if (_failCount >= maxPoisonFailures) {
        _log('远端 #${key.substring(0, min(8, key.length))} 连续 $_failCount 次失败，跳过毒丸记录');
        state.lastRemoteKey = key;
        state.lastRemoteContent = null;
        _failKey = null;
        _failCount = 0;
      }
    }
    throw err;
  }

  Future<ClipRemoteChange?> _handleRemoteProfile(ClipProfile p, int gen) async {
    final key = p.key;
    final last = state.lastRemoteKey;
    if (last == null) {
      state.lastRemoteKey = key;
      if (p.type == 'Text' && !p.hasDataFile && p.text.isNotEmpty) {
        final h = sha256TextUpper(p.text);
        state.lastRemoteContent = h;
        _rememberRecent(h);
      } else {
        state.lastRemoteContent = null;
      }
      _log('首次同步：记录远端基线 ${p.type} #${key.substring(0, min(8, key.length))}，不覆盖本机剪贴板');
      return null;
    }

    if (key == last.toUpperCase()) return null;
    if (_pushing > 0 || gen != _pushGeneration) return null;

    switch (p.type) {
      case 'Text':
        var fullText = p.text;
        var isTruncated = false;
        if (p.hasDataFile && p.dataName != null) {
          if (p.size != null && p.size! > maxTextBytes) {
            _log('远端长文字超过上限，跳过');
            return _settle(key, null, null);
          }
          try {
            final data = await transport.getFile(p.dataName!, maxBytes: maxTextBytes);
            fullText = utf8.decode(data, allowMalformed: true);
            if (_failKey == key) {
              _failKey = null;
              _failCount = 0;
            }
          } on ClipSyncException catch (e) {
            if (e.kind == ClipErrorKind.http && e.statusCode == 404) {
              if (_failKey == key) {
                _failCount++;
              } else {
                _failKey = key;
                _failCount = 1;
              }
              if (_failCount < maxPoisonFailures) {
                _log('远端长文字文件未就绪 (404)，第 $_failCount/$maxPoisonFailures 次重试…');
                rethrow;
              }
              _log('远端长文字文件连续 $_failCount 次 404，降级使用内联摘要并标记错误');
              fullText = p.text;
              isTruncated = true;
              _failKey = null;
              _failCount = 0;
            } else {
              _failRemote(key, e);
            }
          } catch (e) {
            _failRemote(key, e);
          }
        }
        if (gen != _pushGeneration || _pushing > 0) return null;
        if (fullText.isEmpty) {
          return _settle(key, null, null);
        }
        final fullBytes = utf8.encode(fullText);
        final h = sha256Upper(fullBytes);
        if (fullBytes.length > maxTextBytes) {
          return _settle(key, null, h);
        }
        _rememberRecent(h);
        if (key != h) _rememberRecent(key);
        if (_current == h) {
          return _settle(key, null, h);
        }
        _current = h;
        return _settle(
          key,
          ClipRemoteText(fullText, hash: h, isTruncated: isTruncated),
          h,
        );

      case 'Image':
        if (!pullImages()) {
          return _settle(key, null, null);
        }
        if (!p.hasDataFile || p.dataName == null) {
          return _settle(key, null, null);
        }
        if (p.size != null && p.size! > maxImageBytes) {
          return _settle(key, null, null);
        }
        final Uint8List imgBytes;
        try {
          imgBytes = await transport.getFile(p.dataName!, maxBytes: maxImageBytes);
        } catch (e) {
          _failRemote(key, e);
        }
        if (gen != _pushGeneration || _pushing > 0) return null;
        final contentHash = sha256Upper(imgBytes);
        final ckey = 'IMG:$contentHash';
        _rememberRecent(ckey);
        _rememberRecent(key);
        if (_current == ckey) {
          return _settle(key, null, ckey);
        }
        _current = ckey;
        return _settle(
          key,
          ClipRemoteImage(
            name: p.dataName!,
            bytes: imgBytes,
            key: ckey,
            profileHash: key,
          ),
          ckey,
        );

      case 'File':
      case 'Group':
        return _pullRemoteFile(p, gen, key, group: p.type == 'Group');
      default:
        _rememberRecent(key);
        return _settle(key, null, null);
    }
  }

  Future<ClipRemoteChange?> _pullRemoteFile(
    ClipProfile p,
    int gen,
    String key, {
    required bool group,
  }) async {
    if (!pullFiles()) {
      return _settle(key, null, null);
    }
    if (!p.hasDataFile || p.dataName == null || p.dataName!.isEmpty) {
      return _settle(key, null, null);
    }
    if (p.size != null && p.size! > maxFileBytes) {
      _log('远端${group ? '文件组' : '文件'}超过上限，跳过');
      return _settle(key, null, null);
    }
    final Uint8List bytes;
    try {
      bytes = await transport.getFile(p.dataName!, maxBytes: maxFileBytes);
    } catch (e) {
      _failRemote(key, e);
    }
    if (gen != _pushGeneration || _pushing > 0) return null;
    final contentHash = sha256Upper(bytes);
    final expected = p.transferDataHash?.trim().toUpperCase() ?? '';
    if (expected.isNotEmpty && expected != contentHash) {
      _failRemote(key, ClipSyncException.decoding('文件内容与 transferDataHash 不一致'));
    }
    final ckey = group ? 'GROUP:$contentHash' : 'FILE:$contentHash';
    _rememberRecent(ckey);
    _rememberRecent(key);
    if (_current == ckey) {
      return _settle(key, null, ckey);
    }
    _current = ckey;
    return _settle(
      key,
      ClipRemoteFile(
        name: p.dataName!,
        bytes: bytes,
        key: ckey,
        profileHash: key,
        groupArchive: group,
      ),
      ckey,
    );
  }
}

// ---------------------------------------------------------------------------
// Pluggable ClipboardAdapter (Mockable in Tests + Multi-Platform Runtime)
// ---------------------------------------------------------------------------

sealed class ClipboardPayload {
  const ClipboardPayload();
}

class ClipboardTextPayload extends ClipboardPayload {
  final String text;
  const ClipboardTextPayload(this.text);
}

class ClipboardImagePayload extends ClipboardPayload {
  final String fileName;
  final Uint8List bytes;
  const ClipboardImagePayload(this.fileName, this.bytes);
}

class ClipboardFilePayload extends ClipboardPayload {
  final List<String> paths;
  const ClipboardFilePayload(this.paths);
}

abstract class ClipboardAdapter {
  /// Optional event stream notifying of clipboard or screen-state changes.
  Stream<Map<String, dynamic>>? get events => null;

  /// Monotonic OS clipboard sequence / change count, or `null` if unsupported.
  Future<int?> getChangeCount();

  /// Returns `true` when the current clipboard holds concealed / password-manager data.
  Future<bool> isPrivateContent() async => false;

  /// Reads current clipboard payload (File -> Image -> Text priority).
  Future<ClipboardPayload?> read();

  /// Writes UTF-8 plain text to the OS clipboard.
  Future<bool> writeText(String text);

  /// Writes PNG/image bytes to the OS clipboard.
  Future<bool> writeImage(Uint8List bytes, {String? fileName});

  /// Places existing files on the clipboard so Explorer or Finder can paste them.
  Future<bool> writeFiles(List<String> paths);
}

/// In-memory [ClipboardAdapter] for deterministic unit testing.
class MemoryClipboardAdapter implements ClipboardAdapter {
  int _changeCount = 0;
  ClipboardPayload? _payload;
  bool privateFlag = false;
  bool failNextWrite = false;
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();

  MemoryClipboardAdapter({ClipboardPayload? initialPayload}) : _payload = initialPayload {
    if (initialPayload != null) _changeCount = 1;
  }

  int get changeCountSync => _changeCount;
  ClipboardPayload? get currentPayload => _payload;

  String? get currentText =>
      _payload is ClipboardTextPayload ? (_payload as ClipboardTextPayload).text : null;

  Uint8List? get currentImageBytes =>
      _payload is ClipboardImagePayload ? (_payload as ClipboardImagePayload).bytes : null;

  List<String>? get currentFilePaths =>
      _payload is ClipboardFilePayload ? (_payload as ClipboardFilePayload).paths : null;

  void copyText(String text, {bool privateContent = false}) {
    privateFlag = privateContent;
    _payload = ClipboardTextPayload(text);
    _changeCount++;
    if (!_events.isClosed) _events.add(const <String, dynamic>{'type': 'clipboard'});
  }

  void copyImage(String fileName, List<int> bytes) {
    privateFlag = false;
    _payload = ClipboardImagePayload(fileName, Uint8List.fromList(bytes));
    _changeCount++;
    if (!_events.isClosed) _events.add(const <String, dynamic>{'type': 'clipboard'});
  }

  void copyFiles(List<String> paths) {
    privateFlag = false;
    _payload = ClipboardFilePayload(paths);
    _changeCount++;
    if (!_events.isClosed) _events.add(const <String, dynamic>{'type': 'clipboard'});
  }

  void emitScreenState({required bool screenOff}) {
    if (!_events.isClosed) {
      _events.add(<String, dynamic>{'type': screenOff ? 'screen_off' : 'screen_on'});
    }
  }

  @override
  Stream<Map<String, dynamic>>? get events => _events.stream;

  @override
  Future<int?> getChangeCount() async => _changeCount;

  @override
  Future<bool> isPrivateContent() async => privateFlag;

  @override
  Future<ClipboardPayload?> read() async => _payload;

  @override
  Future<bool> writeText(String text) async {
    if (failNextWrite) {
      failNextWrite = false;
      return false;
    }
    privateFlag = false;
    _payload = ClipboardTextPayload(text);
    _changeCount++;
    if (!_events.isClosed) _events.add(const <String, dynamic>{'type': 'clipboard'});
    return true;
  }

  @override
  Future<bool> writeImage(Uint8List bytes, {String? fileName}) async {
    if (failNextWrite) {
      failNextWrite = false;
      return false;
    }
    privateFlag = false;
    _payload = ClipboardImagePayload(fileName ?? 'clipboard.png', Uint8List.fromList(bytes));
    _changeCount++;
    if (!_events.isClosed) _events.add(const <String, dynamic>{'type': 'clipboard'});
    return true;
  }

  @override
  Future<bool> writeFiles(List<String> paths) async {
    if (failNextWrite) {
      failNextWrite = false;
      return false;
    }
    if (paths.isEmpty) return false;
    privateFlag = false;
    _payload = ClipboardFilePayload(List<String>.from(paths));
    _changeCount++;
    if (!_events.isClosed) _events.add(const <String, dynamic>{'type': 'clipboard'});
    return true;
  }

  Future<void> dispose() => _events.close();
}

/// Production [ClipboardAdapter] bridging Desktop (`synchub/desktop`), Android
/// (`synchub/native` + `synchub/events`), and Flutter `Clipboard`.
class PlatformClipboardAdapter implements ClipboardAdapter {
  static const MethodChannel _desktopChannel = MethodChannel('synchub/desktop');
  static const MethodChannel _nativeChannel = MethodChannel('synchub/native');
  static const EventChannel _eventsChannel = EventChannel('synchub/events');

  static Stream<Map<String, dynamic>>? _sharedEvents;
  static final StreamController<Map<String, dynamic>> _desktopEvents =
      StreamController<Map<String, dynamic>>.broadcast();

  static void notifyClipboardChanged([Map<String, dynamic>? data]) {
    if (!_desktopEvents.isClosed) {
      _desktopEvents.add(data ?? const <String, dynamic>{'type': 'clipboard'});
    }
  }

  /// Shared broadcast stream for `EventChannel('synchub/events')` on Android/iOS
  /// and `_desktopEvents` on desktop runners so multiple listeners share a single
  /// push stream.
  static Stream<Map<String, dynamic>>? get sharedEvents {
    if (Platform.isAndroid || Platform.isIOS) {
      return _sharedEvents ??= _eventsChannel
          .receiveBroadcastStream()
          .map((dynamic e) {
            if (e is Map) return e.map((k, v) => MapEntry('$k', v));
            if (e is String) return <String, dynamic>{'type': e};
            return const <String, dynamic>{};
          })
          .handleError((Object _) {})
          .asBroadcastStream();
    }
    return _desktopEvents.stream;
  }

  bool get _isDesktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  MethodChannel get _primaryChannel => _isDesktop ? _desktopChannel : _nativeChannel;

  @override
  Stream<Map<String, dynamic>>? get events => sharedEvents;

  @override
  Future<int?> getChangeCount() async {
    try {
      return await _primaryChannel.invokeMethod<int>('getClipboardChangeCount');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> isPrivateContent() async {
    try {
      final res = await _primaryChannel.invokeMethod<bool>('isClipboardPrivate');
      return res == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<ClipboardPayload?> read() async {
    // 1. Unified readClipboard (macOS NSPasteboard: concealed, files, text, PNG/TIFF)
    if (_isDesktop) {
      var unifiedHandled = false;
      try {
        final raw = await _desktopChannel.invokeMethod<dynamic>('readClipboard');
        unifiedHandled = true;
        if (raw is Map) {
          final kind = ((raw['type'] ?? raw['kind']) as String? ?? '').toLowerCase();
          if (kind == 'private') return null;
          if (kind == 'files') {
            final paths = ((raw['paths'] as List?) ?? const <dynamic>[])
                .whereType<String>()
                .where((s) => s.isNotEmpty)
                .toList();
            if (paths.isNotEmpty) return ClipboardFilePayload(paths);
          }
          if (kind == 'image') {
            final bytes = raw['bytes'];
            if (bytes is Uint8List && bytes.isNotEmpty) {
              final name = (raw['fileName'] as String?) ?? _defaultImageFileName();
              return ClipboardImagePayload(name, bytes);
            }
          }
          if (kind == 'text') {
            final text = raw['text'] as String?;
            if (text != null && text.isNotEmpty) return ClipboardTextPayload(text);
          }
        }
        if (unifiedHandled && raw == null) return null;
      } on MissingPluginException {
        // Windows runner exposes granular readClipboardFiles / readClipboardImage.
      } on PlatformException {
        // Fall through below.
      } catch (_) {}

      // 2. Windows runner granular CF_HDROP -> Plain Text -> GDI+ PNG/DIB
      try {
        final rawFiles = await _desktopChannel.invokeMethod<List<dynamic>>('readClipboardFiles');
        if (rawFiles != null && rawFiles.isNotEmpty) {
          final paths = rawFiles.whereType<String>().where((s) => s.isNotEmpty).toList();
          if (paths.isNotEmpty) return ClipboardFilePayload(paths);
        }
      } catch (_) {}

      try {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        final t = data?.text;
        if (t != null && t.isNotEmpty) return ClipboardTextPayload(t);
      } catch (_) {}

      try {
        final imgBytes = await _desktopChannel.invokeMethod<Uint8List>('readClipboardImage');
        if (imgBytes != null && imgBytes.isNotEmpty) {
          return ClipboardImagePayload(_defaultImageFileName(), imgBytes);
        }
      } catch (_) {}
      return null;
    }

    // 3. Android native snapshot (image URI / primaryClip text / Root helper text)
    try {
      final raw = await _nativeChannel.invokeMethod<dynamic>('readClipboardSnapshot');
      if (raw is Map) {
        final kind = ((raw['kind'] ?? raw['type']) as String? ?? '').toLowerCase();
        if (kind == 'image') {
          final bytes = raw['bytes'];
          if (bytes is Uint8List && bytes.isNotEmpty) {
            final name = (raw['fileName'] as String?) ?? _defaultImageFileName();
            return ClipboardImagePayload(name, bytes);
          }
        }
        if (kind == 'text') {
          final text = raw['text'] as String?;
          if (text != null && text.isNotEmpty) return ClipboardTextPayload(text);
        }
      }
    } catch (_) {}

    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final t = data?.text;
      if (t != null && t.isNotEmpty) return ClipboardTextPayload(t);
    } catch (_) {}
    return null;
  }

  @override
  Future<bool> writeText(String text) async {
    try {
      final ok = await _primaryChannel.invokeMethod<bool>(
        'writeClipboardText',
        <String, dynamic>{'text': text},
      );
      if (ok != null) return ok;
    } on MissingPluginException {
      // Fallback below.
    } catch (_) {}

    try {
      await Clipboard.setData(ClipboardData(text: text));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> writeImage(Uint8List bytes, {String? fileName}) async {
    try {
      final ok = await _primaryChannel.invokeMethod<bool>(
        'writeClipboardImage',
        <String, dynamic>{
          'bytes': bytes,
          'fileName': ?fileName,
        },
      );
      return ok == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> writeFiles(List<String> paths) async {
    if (!_isDesktop || paths.isEmpty) return false;
    try {
      final ok = await _desktopChannel.invokeMethod<bool>(
        'writeClipboardFiles',
        <String, dynamic>{'paths': paths},
      );
      return ok == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static int _imgSeq = 0;

  /// `IMG_yyyyMMdd_HHmmss_SSS_<seq>.png`.
  ///
  /// [seq] is a process-wide counter and is not truncated. Two calls in the
  /// same millisecond still get different names. A random 16-bit suffix can
  /// collide, so production does not use one.
  static String defaultImageFileName({DateTime? now, int? seq}) {
    final dt = now ?? DateTime.now();
    final n = seq ?? ++_imgSeq;
    String two(int v) => v.toString().padLeft(2, '0');
    final mmm = dt.millisecond.toString().padLeft(3, '0');
    final suffix = n.toString().padLeft(4, '0');
    return 'IMG_${dt.year}${two(dt.month)}${two(dt.day)}_'
        '${two(dt.hour)}${two(dt.minute)}${two(dt.second)}_${mmm}_$suffix.png';
  }

  static String _defaultImageFileName({DateTime? now}) => defaultImageFileName(now: now);
}

// ---------------------------------------------------------------------------
// High-Level ClipboardSync Service (Timers + Backoff + UI ChangeNotifier)
// ---------------------------------------------------------------------------

enum ClipDirection { none, up, down }

class ClipStatus {
  final ClipDirection direction;
  final DateTime? time;
  final String text;
  final bool isError;

  const ClipStatus({
    this.direction = ClipDirection.none,
    this.time,
    this.text = '等待剪贴板变化…',
    this.isError = false,
  });
}

class ClipboardSync extends ChangeNotifier {
  static const Duration defaultLocalInterval = Duration(milliseconds: 750);
  static const double defaultRemoteBaseSeconds = 1.5;

  final String supportDir;
  final ClipboardAdapter adapter;
  final Duration localWatchInterval;
  final void Function(String message)? onLog;
  final void Function(List<String> paths)? onCopiedMultipleFiles;

  ClipEndpointConfig _endpoint;
  ClipTransport _transport;
  final bool _ownsTransport;
  late ClipStateStore _stateStore;
  late ClipSyncEngine _engine;

  bool _enabled;
  bool _syncImages;
  bool _syncFiles;
  bool _yieldToOfficial = false;
  bool _screenOff = false;
  bool _running = false;
  int _lifecycleGen = 0;

  int? _lastChangeCount;
  int? _ownChangeCount;
  String? _lastFallbackSig;
  DateTime? _pushRetryAt;

  final ClipBackoff _remoteBackoff = ClipBackoff(baseSeconds: defaultRemoteBaseSeconds);
  final ClipBackoff _pushBackoff = ClipBackoff(baseSeconds: 2.0);
  Timer? _localTimer;
  Timer? _remoteTimer;
  StreamSubscription<Map<String, dynamic>>? _eventSub;

  ClipStatus _status = const ClipStatus();
  DateTime? _lastSyncedAt;
  bool _stateLoaded = false;

  ClipboardSync({
    required this.supportDir,
    required ClipEndpointConfig endpoint,
    ClipboardAdapter? adapter,
    ClipTransport? transport,
    ClipStateStore? stateStore,
    bool enabled = true,
    bool syncImages = true,
    bool syncFiles = true,
    this.localWatchInterval = defaultLocalInterval,
    this.onLog,
    this.onCopiedMultipleFiles,
  })  : _endpoint = endpoint,
        _enabled = enabled,
        _syncImages = syncImages,
        _syncFiles = syncFiles,
        adapter = adapter ?? PlatformClipboardAdapter(),
        _transport = transport ?? SyncClipboardHttpTransport(endpoint),
        _ownsTransport = transport == null {
    _stateStore = stateStore ?? MemoryClipStateStore();
    _stateLoaded = stateStore != null;
    _engine = _buildEngine();
  }

  ClipSyncEngine _buildEngine() => ClipSyncEngine(
        transport: _transport,
        state: _stateStore,
        pullImages: () => _syncImages,
        pullFiles: () => _syncFiles,
        onLog: (m) => onLog?.call('[clip] $m'),
      );

  ClipSyncEngine get engine => _engine;
  ClipEndpointConfig get endpoint => _endpoint;
  ClipStatus get status => _status;
  DateTime? get lastSyncedAt => _lastSyncedAt;
  bool get enabled => _enabled;
  bool get syncImages => _syncImages;
  bool get syncFiles => _syncFiles;
  bool get screenOff => _screenOff;
  bool get isRunning => _running;
  bool get yieldsToOfficialClient => _yieldToOfficial;
  bool get isCustomServer => _endpoint.useCustomServer;

  bool isKnownHash(String h) => _engine.isKnownHash(h);

  void _setStatus(ClipStatus next) {
    _status = next;
    if (!next.isError && next.time != null && next.direction != ClipDirection.none) {
      _lastSyncedAt = next.time;
    }
    notifyListeners();
  }

  Future<void> _ensureStateStoreLoaded() async {
    if (_stateLoaded) return;
    _stateLoaded = true;
    if (supportDir.isNotEmpty) {
      final store = await FileClipStateStore.load(
        File(p.join(supportDir, 'clip_state.json')),
        _endpoint.endpointKey,
      );
      _stateStore = store;
      _engine = _buildEngine();
    }
  }

  /// While official SyncClipboard.exe is running, do not also poll or upload.
  Future<void> setYieldToOfficialClient(bool pause) async {
    if (_yieldToOfficial == pause) return;
    _yieldToOfficial = pause;
    if (pause) {
      if (_running) await stop();
      _setStatus(const ClipStatus(
        text: '检测到 SyncClipboard 正在运行，已暂停剪贴板监视，避免重复上传。文件收发仍由 SyncHub 继续。',
      ));
      return;
    }
    if (_enabled) {
      await start();
    } else {
      _setStatus(const ClipStatus(text: '剪贴板同步：已关闭'));
    }
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    if (_enabled) {
      await start();
    } else {
      await stop();
      _setStatus(const ClipStatus(text: '剪贴板同步：已关闭'));
    }
    notifyListeners();
  }

  void setSyncImages(bool value) {
    if (_syncImages == value) return;
    _syncImages = value;
    notifyListeners();
  }

  void setSyncFiles(bool value) {
    if (_syncFiles == value) return;
    _syncFiles = value;
    notifyListeners();
  }

  void setScreenOff(bool off) {
    if (_screenOff == off) return;
    _screenOff = off;
    if (!off && _running) {
      unawaited(kick());
    }
  }

  /// Reconfigures the server endpoint (Gateway Bearer vs Custom Basic Auth)
  /// and restarts polling with that endpoint's baseline state.
  Future<void> configure(ClipEndpointConfig nextEndpoint) async {
    final wasRunning = _running;
    await stop();
    _endpoint = nextEndpoint;
    if (_ownsTransport) {
      _transport.close();
      _transport = SyncClipboardHttpTransport(nextEndpoint);
    }
    await _ensureStateStoreLoaded();
    if (_stateStore is FileClipStateStore) {
      (_stateStore as FileClipStateStore).switchEndpoint(nextEndpoint.endpointKey);
    } else {
      _stateStore = MemoryClipStateStore();
    }
    _engine = _buildEngine();
    notifyListeners();
    if (wasRunning && _enabled) {
      await start();
    }
  }

  /// Starts bidirectional clipboard sync, recording the current local clipboard
  /// as baseline so pre-existing clipboard contents are not pushed on launch.
  Future<void> start() async {
    if (_yieldToOfficial) {
      _setStatus(const ClipStatus(
        text: '检测到 SyncClipboard 正在运行，已暂停剪贴板监视，避免重复上传。文件收发仍由 SyncHub 继续。',
      ));
      return;
    }
    if (_running) return;
    if (!_enabled) {
      _setStatus(const ClipStatus(text: '剪贴板同步：已关闭'));
      return;
    }
    if (!_endpoint.isConfigured) {
      _setStatus(const ClipStatus(text: '尚未设置剪贴板服务器', isError: true));
      return;
    }

    await _ensureStateStoreLoaded();
    _lifecycleGen++;
    final gen = _lifecycleGen;
    _running = true;
    _remoteBackoff.success();
    _pushBackoff.success();
    _pushRetryAt = null;

    // Record local baseline without pushing startup clipboard contents.
    _lastChangeCount = await adapter.getChangeCount();
    if (_lastChangeCount == null) {
      final initial = await adapter.read();
      _lastFallbackSig = _payloadSignature(initial);
    }

    _setStatus(const ClipStatus(text: '剪贴板同步：已开启，等待变化…'));

    _eventSub?.cancel();
    _eventSub = adapter.events?.listen((evt) {
      if (!_running || gen != _lifecycleGen) return;
      final type = evt['type'] as String? ?? '';
      if (type == 'screen_off') {
        setScreenOff(true);
      } else if (type == 'screen_on') {
        setScreenOff(false);
      } else if (type == 'screen_state') {
        final on = evt['screenOn'] != false && evt['on'] != false && evt['state'] != 'off';
        setScreenOff(!on);
      } else if (type == 'clipboard_text') {
        final text = evt['text'] as String?;
        if (_enabled && text != null && text.isNotEmpty) {
          unawaited(_pushPayload(ClipboardTextPayload(text)).catchError((Object _) => null));
        }
      } else if (type == 'clipboard_image') {
        final bytes = evt['bytes'];
        if (_enabled && _syncImages && bytes is Uint8List && bytes.isNotEmpty) {
          final name = (evt['fileName'] as String?) ?? PlatformClipboardAdapter._defaultImageFileName();
          unawaited(_pushPayload(ClipboardImagePayload(name, bytes)).catchError((Object _) => null));
        }
      } else if (type == 'clipboard' || type == 'clipboard_changed') {
        unawaited(pollLocalOnce());
      }
    });

    if (adapter.events == null) {
      _localTimer?.cancel();
      _localTimer = Timer.periodic(localWatchInterval, (_) {
        if (_running && gen == _lifecycleGen) {
          unawaited(pollLocalOnce());
        }
      });
    }

    _scheduleRemote(const Duration(milliseconds: 200), gen);
  }

  Future<void> stop() async {
    _lifecycleGen++;
    _running = false;
    _localTimer?.cancel();
    _localTimer = null;
    _remoteTimer?.cancel();
    _remoteTimer = null;
    await _eventSub?.cancel();
    _eventSub = null;
    await _stateStore.flush();
  }

  @override
  void dispose() {
    _lifecycleGen++;
    _running = false;
    _localTimer?.cancel();
    _remoteTimer?.cancel();
    _eventSub?.cancel();
    if (_ownsTransport) _transport.close();
    super.dispose();
  }

  static String? _payloadSignature(ClipboardPayload? payload) => switch (payload) {
        null => null,
        ClipboardTextPayload(:final text) => 'T:${sha256TextUpper(text)}',
        ClipboardImagePayload(:final bytes) => 'I:${sha256Upper(bytes)}',
        ClipboardFilePayload(:final paths) => 'F:${paths.join('|')}',
      };

  /// Checks the local clipboard once and pushes if changed since last check.
  Future<ClipLocalResult?> pollLocalOnce() async {
    if (!_running || !_enabled) return null;

    final cc = await adapter.getChangeCount();
    final retryDue = _pushRetryAt != null && !DateTime.now().isBefore(_pushRetryAt!);

    if (cc != null) {
      if (cc == _lastChangeCount && !retryDue) return null;
      _lastChangeCount = cc;
      _pushRetryAt = null;
      if (cc == _ownChangeCount) return null;
    }

    if (await adapter.isPrivateContent()) {
      _setStatus(ClipStatus(time: DateTime.now(), text: '已跳过密码等隐私内容'));
      return const ClipLocalSkipped('隐私内容');
    }

    final payload = await adapter.read();
    if (payload == null) return null;

    if (cc == null) {
      final sig = _payloadSignature(payload);
      if (sig == _lastFallbackSig && !retryDue) return null;
      _lastFallbackSig = sig;
      _pushRetryAt = null;
    }

    return _pushPayload(payload);
  }

  /// Manual action (`"发送当前剪贴板"`): reads the OS clipboard right now and
  /// pushes it to the server regardless of change count.
  Future<ClipLocalResult> pushCurrentClipboard({bool force = true}) async {
    await _ensureStateStoreLoaded();
    if (await adapter.isPrivateContent()) {
      const res = ClipLocalSkipped('剪贴板当前为密码等隐私内容，未发送');
      _setStatus(ClipStatus(time: DateTime.now(), text: res.reason));
      return res;
    }
    final payload = await adapter.read();
    if (payload == null) {
      const res = ClipLocalSkipped('当前剪贴板为空');
      _setStatus(ClipStatus(time: DateTime.now(), text: res.reason));
      return res;
    }
    if (force) {
      _engine.clearEchoGuardForManualPush();
    }
    final res = await _pushPayload(payload);
    return res ?? const ClipLocalSkipped('未发送');
  }

  /// Directly pushes an explicit text string (e.g. macOS NSServices / Android
  /// `ACTION_PROCESS_TEXT` / Quick Settings tile) to the SyncClipboard server.
  Future<ClipLocalResult> pushExplicitText(String text, {bool force = true}) async {
    await _ensureStateStoreLoaded();
    if (text.isEmpty) return const ClipLocalSkipped('文本为空');
    if (force) _engine.clearEchoGuardForManualPush();
    final res = await _pushPayload(ClipboardTextPayload(text));
    return res ?? const ClipLocalSkipped('未发送');
  }

  /// Directly pushes a single file or image path (e.g. Android Quick Settings
  /// clipboard tile URI staging) to the SyncClipboard server.
  Future<ClipLocalResult> pushExplicitFile(String filePath, {bool force = true}) async {
    await _ensureStateStoreLoaded();
    final f = File(filePath);
    if (!await f.exists()) return const ClipLocalSkipped('文件不存在');
    if (force) _engine.clearEchoGuardForManualPush();
    final lower = p.extension(filePath).toLowerCase();
    final isImg = const {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'}.contains(lower);
    if (isImg) {
      final bytes = await f.readAsBytes();
      final res = await _pushPayload(ClipboardImagePayload(p.basename(filePath), bytes));
      return res ?? const ClipLocalSkipped('未发送');
    }
    final res = await _pushPayload(ClipboardFilePayload(<String>[filePath]));
    return res ?? const ClipLocalSkipped('未发送');
  }

  Future<ClipLocalResult?> _pushPayload(ClipboardPayload payload) async {
    try {
      ClipLocalResult res;
      String label;
      switch (payload) {
        case ClipboardTextPayload(:final text):
          label = '文字（${text.length} 字）';
          res = await _engine.onLocalText(text);
        case ClipboardImagePayload(:final fileName, :final bytes):
          if (!_syncImages) return const ClipLocalSkipped('已关闭图片同步');
          label = '图片（${humanBytes(bytes.length)}）';
          res = await _engine.onLocalImage(fileName, bytes);
        case ClipboardFilePayload(:final paths):
          if (!_syncFiles || paths.isEmpty) return const ClipLocalSkipped('未启用文件剪贴板同步');
          if (paths.length > 1 || FileSystemEntity.isDirectorySync(paths.first)) {
            onCopiedMultipleFiles?.call(paths);
            _setStatus(ClipStatus(
              direction: ClipDirection.up,
              time: DateTime.now(),
              text: '已转交传输复制的 ${paths.length} 项',
            ));
            return const ClipLocalSkipped('多项文件已转交传输');
          }
          final file = File(paths.first);
          final len = await file.length();
          if (len > _engine.maxFileBytes) {
            final msg = '复制的文件超过 ${humanBytes(_engine.maxFileBytes)}，未同步';
            _setStatus(ClipStatus(time: DateTime.now(), text: msg));
            return ClipLocalSkipped(msg);
          }
          final bytes = await file.readAsBytes();
          final name = p.basename(file.path);
          label = '文件 $name（${humanBytes(bytes.length)}）';
          res = await _engine.onLocalFile(name, bytes);
      }

      switch (res) {
        case ClipLocalPushed():
          _pushBackoff.success();
          _setStatus(ClipStatus(
            direction: ClipDirection.up,
            time: DateTime.now(),
            text: '已发送$label',
          ));
        case ClipLocalSkipped(:final reason):
          if (reason.contains('超过')) {
            _setStatus(ClipStatus(time: DateTime.now(), text: reason));
          }
      }
      return res;
    } catch (err) {
      _pushBackoff.failure();
      _pushRetryAt = DateTime.now().add(_pushBackoff.delay(screenOff: _screenOff));
      _setStatus(ClipStatus(
        direction: ClipDirection.up,
        time: DateTime.now(),
        text: '发送失败：$err',
        isError: true,
      ));
      rethrow;
    }
  }

  /// Writes [text] to the local OS clipboard and records its hash so the
  /// watcher does not echo-upload it unnecessarily.
  Future<bool> copyToLocalClipboard(String text) async {
    final h = sha256TextUpper(text);
    _engine.noteLocal(key: h);
    final ok = await adapter.writeText(text);
    if (ok) {
      final cc = await adapter.getChangeCount();
      _ownChangeCount = cc;
      _lastChangeCount = cc;
      _lastFallbackSig = 'T:$h';
    } else {
      _engine.release(h);
    }
    return ok;
  }

  /// Writes [bytes] (PNG image) to the local OS clipboard and marks its hash.
  Future<bool> copyImageToLocalClipboard(Uint8List bytes, {String? fileName}) async {
    final ckey = 'IMG:${sha256Upper(bytes)}';
    _engine.noteLocal(key: ckey);
    final ok = await adapter.writeImage(bytes, fileName: fileName);
    if (ok) {
      final cc = await adapter.getChangeCount();
      _ownChangeCount = cc;
      _lastChangeCount = cc;
      _lastFallbackSig = 'I:${sha256Upper(bytes)}';
    } else {
      _engine.release(ckey);
    }
    return ok;
  }

  void _scheduleRemote(Duration delay, int gen) {
    _remoteTimer?.cancel();
    if (!_running || gen != _lifecycleGen) return;
    _remoteTimer = Timer(delay, () async {
      if (!_running || gen != _lifecycleGen) return;
      try {
        await pollRemoteOnce();
      } catch (_) {}
      if (_running && gen == _lifecycleGen) {
        _scheduleRemote(_remoteBackoff.delay(screenOff: _screenOff), gen);
      }
    });
  }

  /// Instant manual/wakeup poll (`"立即同步"`).
  Future<ClipRemoteChange?> kick() async {
    if (_yieldToOfficial || !_enabled) return null;
    _remoteTimer?.cancel();
    await _ensureStateStoreLoaded();
    try {
      final change = await pollRemoteOnce();
      if (_running) {
        _scheduleRemote(_remoteBackoff.delay(screenOff: _screenOff), _lifecycleGen);
      }
      return change;
    } catch (_) {
      if (_running) {
        _scheduleRemote(_remoteBackoff.delay(screenOff: _screenOff), _lifecycleGen);
      }
      rethrow;
    }
  }

  /// Executes one remote poll and applies any incoming change to [adapter].
  Future<ClipRemoteChange?> pollRemoteOnce() async {
    await _ensureStateStoreLoaded();
    try {
      final change = await _engine.pollRemote();
      _remoteBackoff.success();
      if (change != null) {
        await _applyRemoteChange(change);
      } else if (_status.isError && _pushRetryAt == null) {
        _setStatus(const ClipStatus(text: '剪贴板同步：已恢复连接'));
      }
      return change;
    } catch (err) {
      if (err is ClipSyncException && err.isCancelled) return null;
      _remoteBackoff.failure();
      final waitSecs = _remoteBackoff.delay(screenOff: _screenOff).inSeconds;
      _setStatus(ClipStatus(
        direction: ClipDirection.down,
        time: DateTime.now(),
        text: '接收失败：$err（${waitSecs}s 后重试）',
        isError: true,
      ));
      rethrow;
    }
  }

  Future<void> _applyRemoteChange(ClipRemoteChange change) async {
    switch (change) {
      case ClipRemoteText(:final text, :final hash, :final isTruncated):
        final ok = await adapter.writeText(text);
        if (ok) {
          final cc = await adapter.getChangeCount();
          _ownChangeCount = cc;
          _lastChangeCount = cc;
          _lastFallbackSig = 'T:$hash';
          _setStatus(ClipStatus(
            direction: ClipDirection.down,
            time: DateTime.now(),
            text: isTruncated
                ? '已收到截断文字（${text.length} 字，长文本下载失败 404）'
                : '已收到文字（${text.length} 字）',
            isError: isTruncated,
          ));
        } else {
          _engine.release(hash);
          _setStatus(ClipStatus(
            direction: ClipDirection.down,
            time: DateTime.now(),
            text: '写入系统剪贴板失败',
            isError: true,
          ));
        }
      case ClipRemoteFile(:final name, :final bytes, :final key, :final groupArchive):
        final paths = await stageClipboardPayload(
          supportDir: supportDir,
          key: key,
          name: name,
          bytes: bytes,
          groupArchive: groupArchive,
        );
        final ok = paths.isNotEmpty && await adapter.writeFiles(paths);
        if (ok) {
          final cc = await adapter.getChangeCount();
          _ownChangeCount = cc;
          _lastChangeCount = cc;
          _lastFallbackSig = 'F:${paths.join('|')}';
          _setStatus(ClipStatus(
            direction: ClipDirection.down,
            time: DateTime.now(),
            text: paths.length == 1
                ? '已收到文件，可直接粘贴'
                : '已收到 ${paths.length} 个文件，可直接粘贴',
          ));
        } else {
          _engine.release(key);
          _setStatus(ClipStatus(
            direction: ClipDirection.down,
            time: DateTime.now(),
            text: paths.isEmpty ? '保存接收的文件失败' : '文件已暂存，但未能放入系统剪贴板',
            isError: true,
          ));
        }
      case ClipRemoteImage(:final name, :final bytes, :final key):
        final ok = await adapter.writeImage(bytes, fileName: name);
        if (ok) {
          final cc = await adapter.getChangeCount();
          _ownChangeCount = cc;
          _lastChangeCount = cc;
          _lastFallbackSig = 'I:${sha256Upper(bytes)}';
          _setStatus(ClipStatus(
            direction: ClipDirection.down,
            time: DateTime.now(),
            text: '已收到图片（${humanBytes(bytes.length)}）',
          ));
        } else {
          _engine.release(key);
          _setStatus(ClipStatus(
            direction: ClipDirection.down,
            time: DateTime.now(),
            text: '写入系统图片剪贴板失败',
            isError: true,
          ));
        }
    }
  }
}
