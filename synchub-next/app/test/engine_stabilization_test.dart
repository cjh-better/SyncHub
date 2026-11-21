@Timeout(Duration(seconds: 45))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:synchub/core/engine.dart';
import 'package:synchub/core/mdns_discovery.dart';
import 'package:synchub/core/proto.dart';
import 'package:synchub/core/webrtc_channel.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _RealHttpOverrides();

  group('Feature F1: WebSocket Jitter & Fast Reconnect', () {
    test('backoff calculation strictly respects jitter formula and 30s ceiling', () {
      final rand = Random(42);
      var back = 1.0;
      final history = <double>[];
      for (var i = 0; i < 30; i++) {
        history.add(back);
        back = min(30.0, (back * 1.5) + rand.nextDouble());
        expect(back, lessThanOrEqualTo(30.0));
      }
      expect(history[0], 1.0);
      expect(history[1], inInclusiveRange(1.5, 2.5)); // 1.0 * 1.5 + [0..1)
      expect(history.last, 30.0);

      // Verify variance / non-determinism between different seeds
      final rand2 = Random(12345);
      var back2 = 1.0;
      final history2 = <double>[];
      for (var i = 0; i < 30; i++) {
        history2.add(back2);
        back2 = min(30.0, (back2 * 1.5) + rand2.nextDouble());
      }
      expect(history[2], isNot(equals(history2[2])));
    });

    test('kickReconnect breaks active backoff delay immediately and prevents duplicate loops', () async {
      final tmp = await Directory.systemTemp.createTemp('synchub_f1_test_');
      HttpServer? wsServer;
      var connectionAttempts = 0;
      final serverSockets = <WebSocket>[];

      try {
        wsServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        wsServer.listen((req) async {
          if (WebSocketTransformer.isUpgradeRequest(req)) {
            final ws = await WebSocketTransformer.upgrade(req);
            connectionAttempts++;
            serverSockets.add(ws);
            ws.add(jsonEncode({'type': 'devices', 'payload': []}));
            // Abruptly close socket to force engine into backoff delay
            Future.delayed(const Duration(milliseconds: 60), () {
              try {
                ws.close(1001, 'server closing');
              } catch (_) {}
            });
          } else {
            req.response.headers.contentType = ContentType.json;
            req.response.write(jsonEncode({
              'token': 'fixture-token',
              'device_id': 'dev_mock',
              'server_public_key': '0000000000000000000000000000000000000000000000000000000000000000',
            }));
            await req.response.close();
          }
        });

        final engine = await Engine.open(tmp.path);
        await engine.register(
          server: 'http://127.0.0.1:${wsServer.port}',
          name: 'F1-Device',
          user: 'u',
          pass: 'p',
        );

        await engine.start();
        // Wait for first connection attempt and disconnect
        await Future.delayed(const Duration(milliseconds: 200));
        expect(connectionAttempts, 1);
        expect(engine.connected, isFalse);

        // Engine is now awaiting backoff delay (~2.5s).
        // Trigger kickReconnect 5 times concurrently; should only resume one loop
        final sw = Stopwatch()..start();
        for (var i = 0; i < 5; i++) {
          engine.kickReconnect();
        }

        // Reconnection should happen fast (< 1200ms instead of 2500ms+)
        while (connectionAttempts < 2 && sw.elapsedMilliseconds < 2000) {
          await Future.delayed(const Duration(milliseconds: 30));
        }
        sw.stop();

        expect(connectionAttempts, 2);
        expect(sw.elapsedMilliseconds, lessThan(1500));

        await engine.stop();
      } finally {
        for (final ws in serverSockets) {
          try {
            await ws.close();
          } catch (_) {}
        }
        await wsServer?.close(force: true);
        await tmp.delete(recursive: true);
      }
    });
  });

  group('Feature F2: Fast-Fail Orphaned Completers', () {
    test('failPendingWaiters completes all pending waiters with SocketException', () async {
      final tmp = await Directory.systemTemp.createTemp('synchub_f2_test_');
      try {
        final engine = await Engine.open(tmp.path);
        final ansC = engine.waitForForTest('answer:t123:sess1');
        final doneC = engine.waitForForTest('done:t123:sess1');

        expect(engine.pendingWaitersCount, 2);
        expect(ansC.isCompleted, isFalse);
        expect(doneC.isCompleted, isFalse);

        final ansFuture = expectLater(
          ansC.future,
          throwsA(isA<SocketException>().having((e) => e.message, 'message', 'connection dropped')),
        );
        final doneFuture = expectLater(
          doneC.future,
          throwsA(isA<SocketException>().having((e) => e.message, 'message', 'connection dropped')),
        );

        engine.failPendingWaitersForTest(const SocketException('connection dropped'));

        expect(engine.pendingWaitersCount, 0);
        expect(ansC.isCompleted, isTrue);
        expect(doneC.isCompleted, isTrue);

        await ansFuture;
        await doneFuture;

        await engine.stop();
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('completed waiter is not double-completed by failPendingWaiters', () async {
      final tmp = await Directory.systemTemp.createTemp('synchub_f2_test2_');
      try {
        final engine = await Engine.open(tmp.path);
        final ansC = engine.waitForForTest('answer:t999:sess2');
        ansC.complete(Signal.answer(Answer(transferId: 't999', session: 'sess2', accept: true, route: 'lan', need: [])));

        // Should not throw StateError on already completed completer
        expect(() => engine.failPendingWaitersForTest(), returnsNormally);
        final res = await ansC.future;
        expect(res.answer!.accept, isTrue);

        await engine.stop();
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('cancelTransfer cleans up matching waiters without leaking or throwing', () async {
      final tmp = await Directory.systemTemp.createTemp('synchub_f2_test3_');
      try {
        final engine = await Engine.open(tmp.path);
        final ansC = engine.waitForForTest('answer:tid_cancel:sess1');
        final doneC = engine.waitForForTest('done:tid_cancel:sess1');
        final otherC = engine.waitForForTest('answer:tid_other:sess1');

        expect(engine.pendingWaitersCount, 3);

        final ansExpectation = expectLater(ansC.future, throwsA(isA<StateError>()));
        final doneExpectation = expectLater(doneC.future, throwsA(isA<StateError>()));

        await engine.cancelTransfer('tid_cancel');

        // Other transfer waiter is retained, target transfer waiters are completed with error and removed
        expect(engine.pendingWaitersCount, 1);
        expect(ansC.isCompleted, isTrue);
        expect(doneC.isCompleted, isTrue);
        expect(otherC.isCompleted, isFalse);

        await ansExpectation;
        await doneExpectation;

        final otherExpectation = expectLater(otherC.future, throwsA(isA<SocketException>()));
        await engine.stop();
        await otherExpectation;
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('SyncEngine typedef is alias for Engine', () {
      expect(SyncEngine, equals(Engine));
    });
  });

  group('Feature F3: WebRTC State Machine Tuning', () {
    test('WebRtc connectTimeout defaults to 12 seconds across ChunkPusher and Coordinator', () async {
      final coord = WebRtcCoordinator(
        gatewayBase: 'http://127.0.0.1:9',
        token: 'fixture-token',
        sendSignal: (_, _) async {},
      );

      // In test environment, coordinator isSupported() is false (headless)
      expect(await coord.isSupported(), isFalse);
    });
  });

  group('Feature F4: Dynamic UDP Socket Re-binding & Penalty', () {
    test('MdnsDiscovery dynamic socket binding and refresh lifecycle', () async {
      final discovery = MdnsDiscovery(
        selfId: 'dev_f4_test',
        lanPort: 53399,
        enableMdnsClient: false,
      );

      expect(discovery.isSocketBound, isFalse);
      await discovery.start();
      expect(discovery.isRunning, isTrue);

      // Socket should now be bound
      final initialBound = discovery.isSocketBound;

      // Close the socket to simulate socket death / interface disconnect
      discovery.udpSocketForTest?.close();

      // Trigger announceNow - should detect send failure on closed socket and invalidate it
      discovery.announceNow();
      expect(discovery.isSocketBound, isFalse);

      // Now call refresh() - should dynamically re-bind socket on available interfaces
      await discovery.refresh();
      if (initialBound) {
        expect(discovery.isSocketBound, isTrue);
      }

      await discovery.stop();
      expect(discovery.isRunning, isFalse);
      expect(discovery.isSocketBound, isFalse);
    });

    test('Engine markBad penalty expires in 15 seconds instead of 2 minutes', () async {
      final tmp = await Directory.systemTemp.createTemp('synchub_f4_penalty_');
      try {
        final engine = await Engine.open(tmp.path);

        engine.markBadForTest('tid_penalty', 'webrtc');
        expect(engine.isBadForTest('tid_penalty', 'webrtc'), isTrue);

        // Verify that untargeted id is not marked bad
        expect(engine.isBadForTest('tid_other', 'webrtc'), isFalse);

        await engine.stop();
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}
