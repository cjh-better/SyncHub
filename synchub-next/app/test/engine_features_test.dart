@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:synchub/core/engine.dart';

final _bin = p.normalize(p.absolute('../server/gateway/bin'));
String _exe(String n) => p.join(_bin, Platform.isWindows ? '$n.exe' : n);

Future<String> _sha(String path) async =>
    (await hash.sha256.bind(File(path).openRead()).first).toString();

Future<void> _writeBytes(String path, int len, int seed) async {
  final r = Random(seed);
  await File(path).parent.create(recursive: true);
  await File(path).writeAsBytes(List<int>.generate(len, (_) => r.nextInt(256)));
}

Future<void> _waitFor(bool Function() cond, String desc, {int seconds = 30}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('timeout waiting for: $desc');
    }
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
}

void main() {
  late Directory tmp;
  late Process gw;
  late HttpServer hubSrv;
  const gwPort = 5949;
  const gwBase = 'http://127.0.0.1:$gwPort';
  late String hubBase;

  var nextHubId = 1;
  final hubItems = <Map<String, dynamic>>[];
  final hubBlobs = <String, Uint8List>{};
  final uploadAuthHeaders = <String>[];

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('synchub_features_test_');
    gw = await Process.start(
      _exe('gateway'),
      ['-addr', '127.0.0.1:$gwPort', '-data', p.join(tmp.path, 'gw.json')],
      environment: {'SYNCHUB_USER': 'u', 'SYNCHUB_PASSWORD': 'p'},
    );
    gw.stderr.drain<void>();

    // Seed baseline item #1 so AutoPuller baseline starts at 1
    hubItems.add(<String, dynamic>{
      'id': nextHubId++,
      'type': 0,
      'typeName': 'Text',
      'category': '文本',
      'text': 'seed',
      'filename': '',
      'size': 4,
      'hasFile': false,
      'fromDevice': 'seed',
      'createTimeUtc': DateTime.now().toUtc().toIso8601String(),
    });

    hubSrv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    hubBase = 'http://127.0.0.1:${hubSrv.port}';
    hubSrv.listen((HttpRequest req) async {
      final path = req.uri.path;
      if (req.method == 'PUT' && path == '/api/hub/upload') {
        uploadAuthHeaders.add(req.headers.value('authorization') ?? '');
        final qp = req.uri.queryParameters;
        final fn = Uri.decodeComponent(qp['filename'] ?? 'blob.bin');
        final chunks = await req.fold<BytesBuilder>(
          BytesBuilder(copy: false),
          (b, d) => b..add(d),
        );
        final fileBytes = chunks.takeBytes();
        final id = nextHubId++;
        final stored = '${id}_$fn';
        hubBlobs[stored] = fileBytes;
        final digest = hash.sha256.convert(fileBytes).toString().toUpperCase();
        final item = <String, dynamic>{
          'id': id,
          'type': 1,
          'typeName': 'File',
          'category': '文档',
          'text': '',
          'filename': fn,
          'size': fileBytes.length,
          'hash': digest,
          'starred': qp['starred'] == '1' || qp['starred'] == 'true',
          'pinned': qp['pinned'] == '1' || qp['pinned'] == 'true',
          'fromDevice': qp['from'] ?? '',
          'sourceDeviceId': qp['from_id'] ?? '',
          'targetDevice': qp['to'] ?? '',
          'hasFile': true,
          'downloadUrl': '/api/hub/files/$stored',
          'createTimeUtc': DateTime.now().toUtc().toIso8601String(),
        };
        hubItems.add(item);
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'ok': true, 'item': item}));
        await req.response.close();
        return;
      }

      if (req.method == 'GET' && path == '/api/hub/auto-pull') {
        final since = int.tryParse(req.uri.queryParameters['since_id'] ?? '0') ?? 0;
        final devId = req.uri.queryParameters['device_id'] ?? '';
        final latest = hubItems.isEmpty ? 0 : (hubItems.last['id'] as int);
        final matched = hubItems.where((it) {
          final id = it['id'] as int;
          if (id <= since) return false;
          if (it['hasFile'] != true) return false;
          final target = (it['targetDevice'] as String? ?? '');
          if (target.isNotEmpty && devId.isNotEmpty && target != devId) return false;
          final srcId = (it['sourceDeviceId'] as String? ?? '');
          if (srcId.isNotEmpty && devId.isNotEmpty && srcId == devId) return false;
          return true;
        }).toList();
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'ok': true, 'latestId': latest, 'items': matched}));
        await req.response.close();
        return;
      }

      if (req.method == 'GET' && path.startsWith('/api/hub/files/')) {
        final stored = Uri.decodeComponent(path.substring('/api/hub/files/'.length));
        final blob = hubBlobs[stored];
        if (blob == null) {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        req.response
          ..statusCode = 200
          ..contentLength = blob.length
          ..add(blob);
        await req.response.close();
        return;
      }

      req.response.statusCode = 404;
      await req.response.close();
    });

    await Future<void>.delayed(const Duration(milliseconds: 700));
  });

  tearDownAll(() async {
    await hubSrv.close(force: true);
    gw.kill();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('B8 incoming offer prompt (decline & accept) + B9 pause/resume/resend + S3/S4/S9 cloud delivery', () async {
    final senderDir = p.join(tmp.path, 'sender');
    final receiverDir = p.join(tmp.path, 'receiver');
    final senderRecv = p.join(tmp.path, 'sender-recv');
    final receiverRecv = p.join(tmp.path, 'receiver-recv');

    final sender = await Engine.open(senderDir);
    await sender.register(
      server: gwBase,
      name: 'Win-Sender',
      user: 'u',
      pass: 'p',
      recvDir: senderRecv,
    );
    await sender.updateConfig((c) => c.lanPort = 53411);

    final receiver = await Engine.open(receiverDir);
    await receiver.register(
      server: gwBase,
      name: 'Android-Receiver',
      user: 'u',
      pass: 'p',
      recvDir: receiverRecv,
    );
    await receiver.updateConfig((c) {
      c.lanPort = 53412;
      c.autoAccept = false;
    });

    await sender.start();
    await receiver.start();
    await _waitFor(
      () => sender.connected && receiver.connected && (sender.devices[receiver.self]?.online ?? false),
      'both engines connected and seeing each other',
    );

    // --- 1. B8: Incoming offer confirmation — Decline ---
    final fDecline = p.join(tmp.path, 'src', 'decline_me.bin');
    await _writeBytes(fDecline, 64 * 1024, 101);
    PendingOffer? prompted;
    receiver.onIncomingOfferPrompt = (po) => prompted = po;

    final tidDecline = await sender.sendPaths(receiver.self, [fDecline]);
    await _waitFor(() => receiver.pendingOffers.containsKey(tidDecline), 'pending offer arrived');
    expect(prompted, isNotNull);
    expect(prompted!.fromName, 'Win-Sender');
    expect(prompted!.title, 'decline_me.bin');
    expect(prompted!.totalSize, 64 * 1024);

    receiver.respondOffer(tidDecline, false);
    await _waitFor(() => sender.transfers[tidDecline]!.finished, 'sender sees declined offer');
    expect(sender.transfers[tidDecline]!.state, TransferState.failed);
    expect(receiver.pendingOffers, isEmpty);

    // --- 2. B8: Incoming offer confirmation — Accept ---
    final fAccept = p.join(tmp.path, 'src', 'accept_me.bin');
    await _writeBytes(fAccept, 256 * 1024 + 13, 202);
    final tidAccept = await sender.sendPaths(receiver.self, [fAccept]);
    await _waitFor(() => receiver.pendingOffers.containsKey(tidAccept), 'second pending offer arrived');
    receiver.respondOffer(tidAccept, true);
    await _waitFor(() => sender.transfers[tidAccept]!.finished, 'accepted transfer done');
    expect(sender.transfers[tidAccept]!.state, TransferState.done);
    expect(await _sha(p.join(receiverRecv, 'accept_me.bin')), await _sha(fAccept));

    // Re-enable autoAccept for B9 tests
    await receiver.updateConfig((c) => c.autoAccept = true);

    // --- 3. B9: Pause while offline, stay paused on reconnect, resume, and retryOrResend ---
    await receiver.stop();
    await _waitFor(() => !(sender.devices[receiver.self]?.online ?? true), 'receiver offline');
    await sender.updateConfig((c) => c.offlineFallback = false);

    final fPause = p.join(tmp.path, 'src', 'pause_resume.bin');
    await _writeBytes(fPause, 128 * 1024 + 7, 303);
    final tidPause = await sender.sendPaths(receiver.self, [fPause]);
    expect(sender.transfers[tidPause]!.state, isNot(TransferState.done));

    await sender.pauseTransfer(tidPause);
    expect(sender.transfers[tidPause]!.state, TransferState.paused);

    // Bring receiver back online; paused transfer must NOT start until resumed
    await receiver.start();
    await _waitFor(() => sender.devices[receiver.self]?.online ?? false, 'receiver back online');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(sender.transfers[tidPause]!.state, TransferState.paused);

    await sender.resumeTransfer(tidPause);
    await _waitFor(() => sender.transfers[tidPause]!.finished, 'resumed transfer completed');
    expect(sender.transfers[tidPause]!.state, TransferState.done);
    expect(await _sha(p.join(receiverRecv, 'pause_resume.bin')), await _sha(fPause));

    // Resend completed transfer via retryOrResend
    final tidResend = await sender.retryOrResend(tidPause);
    expect(tidResend, isNotNull);
    expect(tidResend, isNot(equals(tidPause)));
    await _waitFor(() => sender.transfers[tidResend!]!.finished, 'resend transfer completed');
    expect(sender.transfers[tidResend!]!.state, TransferState.done);

    // --- 4. S3 + S4 + S9: Offline Cloud Fallback & Explicit Cloud Star + AutoPuller ---
    sender.hubBaseOverride = hubBase;
    receiver.hubBaseOverride = hubBase;
    sender.hub.base = hubBase;
    receiver.hub.base = hubBase;

    // Initialize receiver AutoPuller baseline at seed item #1
    expect(await receiver.autoPuller.pollOnce(), 0);

    await receiver.stop();
    await _waitFor(() => !(sender.devices[receiver.self]?.online ?? true), 'receiver offline for cloud fallback');
    await sender.updateConfig((c) => c.offlineFallback = true);

    final fOffline = p.join(tmp.path, 'src', 'offline_cloud.pdf');
    await _writeBytes(fOffline, 90 * 1024 + 5, 404);
    final tidCloud = await sender.sendPaths(receiver.self, [fOffline]);
    await _waitFor(() => sender.transfers[tidCloud]!.finished, 'offline cloud upload finished');
    expect(sender.transfers[tidCloud]!.state, TransferState.done);
    expect(sender.transfers[tidCloud]!.route, 'cloud');
    expect(uploadAuthHeaders.last, startsWith('Bearer '));

    // Explicit Cloud Star card upload (S9)
    final fStar = p.join(tmp.path, 'src', 'starred_note.txt');
    await File(fStar).writeAsString('Important cross-device note!');
    final tidStar = await sender.sendPaths(kCloudTargetId, [fStar], star: true);
    await _waitFor(() => sender.transfers[tidStar]!.finished, 'explicit cloud star upload finished');
    expect(sender.transfers[tidStar]!.state, TransferState.done);
    expect(sender.transfers[tidStar]!.route, 'cloud');
    expect(hubItems.last['starred'], isTrue);

    // Receiver wakes up and AutoPuller pulls both files!
    final pulledPaths = <String>[];
    receiver.onFilesSaved = (_, paths) => pulledPaths.addAll(paths);
    final pulledCount = await receiver.autoPuller.pollOnce();
    expect(pulledCount, 2);
    expect(await _sha(p.join(receiverRecv, 'offline_cloud.pdf')), await _sha(fOffline));
    expect(await File(p.join(receiverRecv, 'starred_note.txt')).readAsString(), 'Important cross-device note!');
    expect(pulledPaths.length, 2);

    await sender.stop();
  });
}
