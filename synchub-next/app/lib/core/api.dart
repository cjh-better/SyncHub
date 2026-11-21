import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;

import 'proto.dart';

class ApiException implements Exception {
  final int status;
  final String body;
  ApiException(this.status, this.body);
  @override
  String toString() => 'HTTP $status: $body';
}

bool isStatus(Object e, int code) => e is ApiException && e.status == code;

Future<Uint8List> _readAll(HttpClientResponse r, {int max = 64 << 20}) async {
  final b = BytesBuilder(copy: false);
  await for (final part in r) {
    b.add(part);
    if (b.length > max) throw ApiException(r.statusCode, 'response too large');
  }
  return b.takeBytes();
}

/// HTTP client for the gateway control plane.
class GatewayApi {
  final String base;
  String token;
  final HttpClient http;

  GatewayApi(String base, this.token)
      : base = base.replaceAll(RegExp(r'/+$'), ''),
        http = HttpClient()
          ..connectionTimeout = const Duration(seconds: 15)
          ..idleTimeout = const Duration(seconds: 60);

  Future<dynamic> _json(String method, String path, {Object? body, Map<String, String>? headers}) async {
    final req = await http.openUrl(method, Uri.parse('$base$path')).timeout(const Duration(seconds: 20));
    if (token.isNotEmpty && !(headers?.containsKey('authorization') ?? false)) {
      req.headers.set('authorization', 'Bearer $token');
    }
    headers?.forEach(req.headers.set);
    if (body != null) {
      final b = utf8.encode(jsonEncode(body));
      req.headers.contentType = ContentType.json;
      req.contentLength = b.length;
      req.add(b);
    }
    final resp = await req.close().timeout(const Duration(seconds: 30));
    final data = await _readAll(resp);
    if (resp.statusCode >= 300) throw ApiException(resp.statusCode, utf8.decode(data, allowMalformed: true));
    if (data.isEmpty) return null;
    return jsonDecode(utf8.decode(data));
  }

  static Future<Map<String, dynamic>> register(String base,
      {String user = '', String pass = '', String code = '', required String name, required String platform, required String publicKey}) async {
    final api = GatewayApi(base, '');
    final h = <String, String>{};
    if (code.isNotEmpty) {
      h['x-pairing-code'] = code;
    } else {
      h['authorization'] = 'Basic ${base64.encode(utf8.encode('$user:$pass'))}';
    }
    try {
      return (await api._json('POST', '/api/v1/devices/register',
          body: {'name': name, 'platform': platform, 'public_key': publicKey}, headers: h)) as Map<String, dynamic>;
    } finally {
      api.http.close();
    }
  }

  Future<(String, List<DeviceInfo>)> devices() async {
    final j = await _json('GET', '/api/v1/devices') as Map<String, dynamic>;
    return (
      j['self'] as String,
      ((j['devices'] ?? []) as List).map((e) => DeviceInfo.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }

  Future<(String, DateTime)> pairingCode() async {
    final j = await _json('POST', '/api/v1/pairing-codes', body: {}) as Map<String, dynamic>;
    return (j['code'] as String, DateTime.parse(j['expires_at'] as String).toLocal());
  }

  Future<void> deleteDevice(String id) => _json('DELETE', '/api/v1/devices/$id');
  Future<void> rename(String name) => _json('PATCH', '/api/v1/devices/me', body: {'name': name});

  Future<RelayGrant> openRelay(String tid, String receiver) async => RelayGrant.fromJson(
      await _json('POST', '/api/v1/relay/sessions', body: {'transfer_id': tid, 'receiver': receiver}) as Map<String, dynamic>);

  Future<RelayGrant> relayTicket(String tid) async =>
      RelayGrant.fromJson(await _json('POST', '/api/v1/relay/tickets', body: {'transfer_id': tid}) as Map<String, dynamic>);

  Uri wsUri() {
    final u = Uri.parse('$base/api/v1/ws');
    return u.replace(scheme: u.scheme == 'https' ? 'wss' : 'ws');
  }

  RelayConn relay(RelayInfo info, String ticket) => RelayConn(
        info.id,
        info.url.isEmpty ? base : info.url.replaceAll(RegExp(r'/+$'), ''),
        ticket,
        info.certSha256.isEmpty ? http : pinnedClient(info.certSha256),
      );

  void close() => http.close(force: true);
}

final _pinned = <String, HttpClient>{};

/// An HttpClient that accepts exactly one self-signed certificate (hex
/// SHA-256 of its DER encoding) and nothing else.
HttpClient pinnedClient(String fp) {
  final want = fp.toLowerCase().replaceAll(':', '');
  return _pinned.putIfAbsent(want, () {
    final c = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 60);
    c.badCertificateCallback = (cert, host, port) => hash.sha256.convert(cert.der).toString() == want;
    return c;
  });
}

abstract class ChunkPusher {
  String get name;
  Future<void> put(String tid, String session, int file, int chunk, Uint8List data);
}

const _chunkTimeout = Duration(minutes: 2);

class RelayConn implements ChunkPusher {
  final String id;
  final String base;
  final String ticket;
  final HttpClient http;
  RelayConn(this.id, this.base, this.ticket, this.http);

  @override
  String get name => 'relay:$id';

  Uri _u(String tid, String session, int file, int chunk) => Uri.parse('$base/api/v1/relay/$tid/$session/$file/$chunk');

  Future<Duration> ping() async {
    final sw = Stopwatch()..start();
    final req = await http.getUrl(Uri.parse('$base/healthz')).timeout(const Duration(seconds: 4));
    final resp = await req.close().timeout(const Duration(seconds: 4));
    await resp.drain<void>();
    if (resp.statusCode != 200) throw ApiException(resp.statusCode, 'healthz');
    return sw.elapsed;
  }

  @override
  Future<void> put(String tid, String session, int file, int chunk, Uint8List data) async {
    Future<void> run() async {
      final req = await http.openUrl('PUT', _u(tid, session, file, chunk));
      req.headers.set('authorization', 'Ticket $ticket');
      req.headers.contentType = ContentType.binary;
      req.contentLength = data.length;
      req.add(data);
      final resp = await req.close();
      final body = await _readAll(resp, max: 4096);
      if (resp.statusCode >= 300) throw ApiException(resp.statusCode, utf8.decode(body, allowMalformed: true));
    }

    await run().timeout(_chunkTimeout);
  }

  Future<Uint8List> get(String tid, String session, int file, int chunk, int max) async {
    Future<Uint8List> run() async {
      final req = await http.getUrl(_u(tid, session, file, chunk));
      req.headers.set('authorization', 'Ticket $ticket');
      final resp = await req.close();
      final body = await _readAll(resp, max: max + 1);
      if (resp.statusCode != 200) throw ApiException(resp.statusCode, utf8.decode(body, allowMalformed: true));
      if (resp.contentLength >= 0 && body.length != resp.contentLength) throw ApiException(502, 'short body');
      return body;
    }

    return run().timeout(_chunkTimeout);
  }
}

final _lanHttp = HttpClient()
  ..connectionTimeout = const Duration(seconds: 2)
  ..idleTimeout = const Duration(seconds: 30)
  ..findProxy = (_) => 'DIRECT';

class LanConn implements ChunkPusher {
  final String base;
  LanConn(this.base);

  @override
  String get name => 'lan';

  @override
  Future<void> put(String tid, String session, int file, int chunk, Uint8List data) async {
    Future<void> run() async {
      final req = await _lanHttp.openUrl('PUT', Uri.parse('$base/synchub/v1/chunk/$tid/$session/$file/$chunk'));
      req.contentLength = data.length;
      req.add(data);
      final resp = await req.close();
      final body = await _readAll(resp, max: 4096);
      if (resp.statusCode != 204) throw ApiException(resp.statusCode, utf8.decode(body, allowMalformed: true));
    }

    await run().timeout(const Duration(seconds: 60));
  }

  /// First LAN endpoint of [dev] answering with the right device id.
  static Future<LanConn?> probe(DeviceInfo dev, List<String> urls) async {
    if (urls.isEmpty) return null;
    final c = Completer<LanConn?>();
    var left = urls.length;
    for (final u in urls) {
      () async {
        try {
          final req = await _lanHttp.getUrl(Uri.parse('$u/synchub/v1/ping')).timeout(const Duration(milliseconds: 1500));
          final resp = await req.close().timeout(const Duration(milliseconds: 1500));
          final j = jsonDecode(utf8.decode(await _readAll(resp, max: 1024))) as Map<String, dynamic>;
          if (j['device_id'] == dev.id && !c.isCompleted) c.complete(LanConn(u));
        } catch (_) {
          // unreachable
        } finally {
          if (--left == 0 && !c.isCompleted) c.complete(null);
        }
      }();
    }
    return c.future.timeout(const Duration(seconds: 2), onTimeout: () => null);
  }
}
