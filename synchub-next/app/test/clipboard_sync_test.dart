import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:synchub/core/clipboard_sync.dart';
import 'package:synchub/core/hub_api.dart';
import 'package:synchub/core/secure_store.dart';
import 'package:synchub/core/webrtc_channel.dart';

/// Controllable in-memory [ClipTransport] for deterministic protocol & race tests.
class FakeClipTransport implements ClipTransport {
  ClipProfile profile = const ClipProfile(
    type: 'Text',
    hash: '',
    text: '',
    hasData: false,
    dataName: null,
    size: 0,
  );
  Map<String, dynamic> lastPutRawJson = <String, dynamic>{};
  final Map<String, Uint8List> files = <String, Uint8List>{};
  int puts = 0;
  ClipSyncException? failNext;
  Completer<void>? holdNextGet;
  Completer<void>? getStartedSignal;

  void setRemoteText(String text) {
    final utf8Bytes = utf8.encode(text);
    profile = ClipProfile(
      type: 'Text',
      hash: sha256Upper(utf8Bytes),
      text: text,
      hasData: false,
      dataName: null,
      size: utf8Bytes.length,
    );
  }

  ClipSyncException? _takeFailure() {
    final f = failNext;
    failNext = null;
    return f;
  }

  @override
  Future<ClipProfile> getProfile() async {
    final snap = profile;
    final started = getStartedSignal;
    getStartedSignal = null;
    if (started != null && !started.isCompleted) {
      started.complete();
    }
    final hold = holdNextGet;
    holdNextGet = null;
    if (hold != null) {
      await hold.future;
    }
    final err = _takeFailure();
    if (err != null) throw err;
    return snap;
  }

  @override
  Future<void> putProfile(ClipProfile next) async {
    final err = _takeFailure();
    if (err != null) throw err;
    final wireBytes = next.toJsonBytes();
    lastPutRawJson = jsonDecode(utf8.decode(wireBytes)) as Map<String, dynamic>;
    profile = ClipProfile.parse(wireBytes);
    puts++;
  }

  @override
  Future<Uint8List> getFile(String name, {required int maxBytes}) async {
    final err = _takeFailure();
    if (err != null) throw err;
    final data = files[name];
    if (data == null) throw ClipSyncException.http(404, 'not found');
    if (data.length > maxBytes) {
      throw ClipSyncException.local('exceeds maxBytes');
    }
    return Uint8List.fromList(data);
  }

  @override
  Future<void> putFile(String name, Uint8List bytes) async {
    final err = _takeFailure();
    if (err != null) throw err;
    files[name] = Uint8List.fromList(bytes);
  }

  @override
  void close() {}
}

String? _mockSyncClipboardServer() {
  const rel = '03_macOS自动接收与Finder右键套件/SyncHubMac/Tests/ClipHarness/mock_syncclipboard_server.py';
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final candidate = File(p.join(dir.path, rel));
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

Future<String> _pythonCommand() async {
  for (final name in const <String>['python3', 'python']) {
    try {
      final res = await Process.run(name, const <String>['--version']);
      if (res.exitCode == 0) return name;
    } catch (_) {}
  }
  return 'python3';
}

Future<int> _allocateEphemeralPort() async {
  final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = srv.port;
  await srv.close();
  return port;
}

Future<void> _deleteTempDirSafely(Directory dir) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

Future<Map<String, dynamic>> _httpJson(
  String method,
  Uri uri, {
  Map<String, String>? headers,
  List<int>? bodyBytes,
}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, uri);
    headers?.forEach(req.headers.set);
    if (bodyBytes != null) {
      req.contentLength = bodyBytes.length;
      req.add(bodyBytes);
    }
    final resp = await req.close();
    final bytes = await resp.fold<BytesBuilder>(
      BytesBuilder(copy: false),
      (b, chunk) => b..add(chunk),
    );
    final raw = utf8.decode(bytes.takeBytes(), allowMalformed: true);
    if (raw.trim().isEmpty) return <String, dynamic>{'_status': resp.statusCode};
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic>
        ? decoded
        : <String, dynamic>{'data': decoded};
  } finally {
    client.close(force: true);
  }
}

void main() {
  // =========================================================================
  // 1. Exact SHA-256 Uppercase Vectors & SyncClipboard URL Encoding
  // =========================================================================
  group('SHA-256 uppercase vectors & filename encoding', () {
    test('matches NIST, Python hashlib, and SyncClipboard v3.3.3 vectors', () {
      expect(
        sha256Upper(const <int>[]),
        'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855',
      );
      expect(
        sha256TextUpper('abc'),
        'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD',
      );
      expect(
        sha256TextUpper('init'),
        'BB54068AEA85FAA7E487530083366BE9962390AF822E4C71EF1ACA7033C83E66',
      );
      expect(
        sha256TextUpper(
          'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
        ),
        '248D6A61D20638B8E5C026930C3E6039A33CE45964FF2167F6ECEDD419DB06C1',
      );
      expect(
        sha256Upper(Uint8List(1000000)..fillRange(0, 1000000, 0x61)),
        'CDC76E5C9914FB9281A1C7E284D73E67F1809A48A497200E046D39CCC7112CD0',
      );

      const zhEmoji = '你好 world 😀\n第二行';
      final zhHash = sha256TextUpper(zhEmoji);
      expect(
        zhHash,
        'D046DC0D76D34FE8F73CFE738A380F8D3010CBFED50D6560D1C96799D247DC11',
      );
      expect(zhHash.length, 64);
      expect(RegExp(r'^[0-9A-F]{64}$').hasMatch(zhHash), isTrue);

      final helloContentHash = sha256TextUpper('hello');
      expect(
        fileProfileHash('a.png', helloContentHash.toLowerCase()),
        sha256TextUpper('a.png|$helloContentHash'),
      );
    });

    test('encodeSyncClipboardFileName encodes space as %20, + as %2B, # as %23', () {
      final encoded = encodeSyncClipboardFileName('IMG_手机 截图 #1+2.png');
      expect(encoded.contains('+'), isFalse);
      expect(encoded.contains(' '), isFalse);
      expect(encoded.contains('#'), isFalse);
      expect(encoded, contains('%20'));
      expect(encoded, contains('%23'));
      expect(encoded, contains('%2B'));
      expect(Uri.decodeComponent(encoded), 'IMG_手机 截图 #1+2.png');
    });
  });

  // =========================================================================
  // 2. ClipProfile Parsing & Wire Serialization Invariants
  // =========================================================================
  group('ClipProfile.parse & toJson wire compatibility', () {
    test('parses v3.3.3 camelCase, SyncHub PascalCase, and legacy v2 schemas', () {
      final camel = ClipProfile.parse(
        utf8.encode(
          '{"type":"Text","hash":"abc","text":"你好","hasData":false,"dataName":"","size":6,"syncedAt":"2026-11-10T01:02:37Z"}',
        ),
      );
      expect(camel.type, 'Text');
      expect(camel.text, '你好');
      expect(camel.hasData, isFalse);
      expect(camel.dataName, '');
      expect(camel.hasDataFile, isFalse);
      expect(camel.key, 'ABC');

      final pascal = ClipProfile.parse(
        utf8.encode(
          '{"Type":"Text","Hash":"H2","Text":"x","HasData":false,"DataName":"","TransferDataHash":"","Size":1}',
        ),
      );
      expect(pascal.type, 'Text');
      expect(pascal.hash, 'H2');
      expect(pascal.text, 'x');
      expect(pascal.hasData, isFalse);
      expect(pascal.hasDataFile, isFalse);
      expect(pascal.transferDataHash, isNull);

      final v2 = ClipProfile.parse(
        utf8.encode('{"Type":"Image","Clipboard":"old","File":"p.png"}'),
      );
      expect(v2.type, 'Image');
      expect(v2.text, 'old');
      expect(v2.dataName, 'p.png');
      expect(v2.hasData, isTrue);
      expect(v2.hasDataFile, isTrue);

      expect(
        () => ClipProfile.parse(utf8.encode('<html>bad gateway</html>')),
        throwsA(isA<ClipSyncException>()),
      );
    });

    test('NEVER emits transferDataHash when hasData == false', () {
      const shortText = ClipProfile(
        type: 'Text',
        hash: 'ABCDEF',
        text: 'hello',
        hasData: false,
        dataName: 'stale.txt',
        transferDataHash: 'SHOULD_BE_STRIPPED',
        size: 5,
      );
      final jsonMap = shortText.toJson();
      expect(jsonMap.containsKey('transferDataHash'), isFalse);
      expect(jsonMap['hasData'], isFalse);
      expect(jsonMap['dataName'], isNull);

      const withData = ClipProfile(
        type: 'Image',
        hash: 'PROF',
        text: 'a.png',
        hasData: true,
        dataName: 'a.png',
        transferDataHash: 'CONTENT_SHA',
        size: 42,
      );
      final dataMap = withData.toJson();
      expect(dataMap['transferDataHash'], 'CONTENT_SHA');
      expect(dataMap['dataName'], 'a.png');
      expect(dataMap['hasData'], isTrue);
    });
  });

  // =========================================================================
  // 3. Anti-Loop State Machine, Long Text, LRU Dedup, Poison Cap & Backoff
  // =========================================================================
  group('ClipSyncEngine & ClipboardSync state machine', () {
    test('startup baseline does not overwrite local clipboard; A -> B -> A pushes A', () async {
      final transport = FakeClipTransport()..setRemoteText('old-server-text');
      final state = MemoryClipStateStore();
      final engine = ClipSyncEngine(
        transport: transport,
        state: state,
        nameStamp: () => '2026-11-14_20-00-00_deadbeef',
      );

      // 1. First poll records baseline and returns null without touching local clipboard.
      expect(await engine.pollRemote(), isNull);
      expect(state.lastRemoteKey, sha256TextUpper('old-server-text'));
      expect(state.lastRemoteContent, sha256TextUpper('old-server-text'));
      expect(await engine.pollRemote(), isNull);

      // 2. Local copy A -> pushed.
      final pushA1 = await engine.onLocalText('A');
      expect(pushA1, isA<ClipLocalPushed>());
      expect(transport.profile.text, 'A');
      expect(transport.lastPutRawJson.containsKey('transferDataHash'), isFalse);
      final putsAfterA1 = transport.puts;

      // Own push is not echoed on subsequent remote poll or duplicate local poll.
      expect(await engine.pollRemote(), isNull);
      expect(await engine.onLocalText('A'), isA<ClipLocalSkipped>());
      expect(transport.puts, putsAfterA1);

      // 3. Remote device sets B -> pulled and written locally; OS echo of B is suppressed!
      transport.setRemoteText('B');
      final pullB = await engine.pollRemote();
      expect(pullB, isA<ClipRemoteText>());
      expect((pullB as ClipRemoteText).text, 'B');
      expect(await engine.onLocalText('B'), isA<ClipLocalSkipped>());
      expect(transport.puts, putsAfterA1);

      // 4. User copies A again (A -> B -> A) -> MUST push A!
      final pushA2 = await engine.onLocalText('A');
      expect(pushA2, isA<ClipLocalPushed>());
      expect(transport.profile.text, 'A');
      expect(transport.puts, putsAfterA1 + 1);
    });

    test('mid-poll pushGeneration race discards stale GET response', () async {
      final transport = FakeClipTransport()..setRemoteText('BASE');
      final engine = ClipSyncEngine(
        transport: transport,
        state: MemoryClipStateStore(),
      );
      await engine.pollRemote(); // baseline

      transport.setRemoteText('STALE_REMOTE');
      final getStarted = Completer<void>();
      final releaseGet = Completer<void>();
      transport.getStartedSignal = getStarted;
      transport.holdNextGet = releaseGet;

      final pollFuture = engine.pollRemote();
      await getStarted.future;

      // While GET /SyncClipboard.json is in flight, user copies fresh text locally.
      final localRes = await engine.onLocalText('FRESH_LOCAL_COPY');
      expect(localRes, isA<ClipLocalPushed>());
      expect(transport.profile.text, 'FRESH_LOCAL_COPY');

      releaseGet.complete();
      // Stale GET response must be discarded!
      expect(await pollFuture, isNull);
      expect(transport.profile.text, 'FRESH_LOCAL_COPY');
    });

    test('release() rollback avoids echo against unchanged server and allows push after remote change', () async {
      final transport = FakeClipTransport()..setRemoteText('BASE');
      final engine = ClipSyncEngine(
        transport: transport,
        state: MemoryClipStateStore(),
      );
      await engine.pollRemote();

      transport.setRemoteText('E');
      final pulledE = await engine.pollRemote() as ClipRemoteText;
      // Simulate OS clipboard write failure:
      engine.release(pulledE.hash);

      final putsBefore = transport.puts;
      // Server still holds E -> lastRemoteContent suppresses redundant re-PUT.
      expect(await engine.onLocalText('E'), isA<ClipLocalSkipped>());
      expect(transport.puts, putsBefore);

      // Remote moves to F -> now copying E locally pushes E!
      transport.setRemoteText('F');
      expect((await engine.pollRemote() as ClipRemoteText).text, 'F');
      expect(await engine.onLocalText('E'), isA<ClipLocalPushed>());
      expect(transport.profile.text, 'E');
    });

    test('long text (> 10,240 UTF-16 units) uploads /file/Text_*.txt and pulls full text', () async {
      final transport = FakeClipTransport()..setRemoteText('init');
      final engine = ClipSyncEngine(
        transport: transport,
        state: MemoryClipStateStore(),
        nameStamp: () => '2026-11-14_20-30-00_abcd1234',
      );
      await engine.pollRemote();

      final longText = List<String>.filled(1500, '0123456789').join(); // 15,000 chars
      final res = await engine.onLocalText(longText);
      expect(res, isA<ClipLocalPushed>());
      const expectedFile = 'Text_2026-11-14_20-30-00_abcd1234.txt';
      expect(transport.files.containsKey(expectedFile), isTrue);
      expect(utf8.decode(transport.files[expectedFile]!), longText);
      expect(transport.profile.hasData, isTrue);
      expect(transport.profile.dataName, expectedFile);
      expect(transport.profile.text.length, 10240);
      expect(transport.profile.hash, sha256TextUpper(longText));
      expect(transport.profile.transferDataHash, sha256TextUpper(longText));

      // Second engine pulls full 15,000-char text from /file/Text_*.txt
      final receiver = ClipSyncEngine(
        transport: transport,
        state: MemoryClipStateStore(lastRemoteKey: 'DIFFERENT_BASELINE'),
      );
      final pulled = await receiver.pollRemote();
      expect(pulled, isA<ClipRemoteText>());
      expect((pulled as ClipRemoteText).text, longText);
    });

    test('image push/pull & 32-entry bounded LRU isKnownHash ring buffer', () async {
      final transport = FakeClipTransport()..setRemoteText('init');
      final engine = ClipSyncEngine(
        transport: transport,
        state: MemoryClipStateStore(),
      );
      await engine.pollRemote();

      final pngBytes = Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);
      final contentSha = sha256Upper(pngBytes);
      final expectedProfileSha = fileProfileHash('shot.png', contentSha);

      final pushed = await engine.onLocalImage('shot.png', pngBytes);
      expect((pushed as ClipLocalPushed).hash, expectedProfileSha);
      expect(transport.profile.type, 'Image');
      expect(transport.profile.transferDataHash, contentSha);
      // Both raw content SHA and profile SHA are recognized for AutoPuller dedup!
      expect(engine.isKnownHash(contentSha), isTrue);
      expect(engine.isKnownHash(expectedProfileSha), isTrue);

      // Fill 32 additional hashes while touching contentSha so LRU promotes it:
      for (var i = 0; i < 20; i++) {
        await engine.onLocalText('entry_$i');
      }
      // Promote contentSha to MRU:
      expect(engine.isKnownHash(contentSha), isTrue);
      for (var i = 20; i < 40; i++) {
        await engine.onLocalText('entry_$i');
      }
      expect(engine.recentHashes.length, 32);
      // Oldest untouched entries were evicted, while promoted contentSha survived:
      expect(engine.isKnownHash(sha256TextUpper('entry_0')), isFalse);
      expect(engine.isKnownHash(contentSha), isTrue);
    });

    test('poison 404 item skips after 3 non-network failures; network errors never increment failCount', () async {
      final transport = FakeClipTransport()..setRemoteText('init');
      final state = MemoryClipStateStore();
      final engine = ClipSyncEngine(transport: transport, state: state);
      await engine.pollRemote();

      // 1. Transient network errors never skip a remote record, even after 5 failures:
      transport.setRemoteText('NET_RECOVER_ME');
      for (var i = 0; i < 5; i++) {
        transport.failNext = ClipSyncException.network('socket reset #$i');
        await expectLater(engine.pollRemote(), throwsA(isA<ClipSyncException>()));
        expect(state.lastRemoteKey, isNot(sha256TextUpper('NET_RECOVER_ME')));
      }
      final recovered = await engine.pollRemote();
      expect((recovered as ClipRemoteText).text, 'NET_RECOVER_ME');

      // 2. Missing 404 data file skips after 3 non-network failures:
      transport.profile = const ClipProfile(
        type: 'Image',
        hash: 'POISON_404_HASH',
        text: 'missing.png',
        hasData: true,
        dataName: 'missing.png',
        size: 128,
      );
      for (var i = 0; i < 2; i++) {
        await expectLater(engine.pollRemote(), throwsA(isA<ClipSyncException>()));
        expect(state.lastRemoteKey, isNot('POISON_404_HASH'));
      }
      // 3rd non-network failure advances cursor so polling is unstuck:
      await expectLater(engine.pollRemote(), throwsA(isA<ClipSyncException>()));
      expect(state.lastRemoteKey, 'POISON_404_HASH');
      expect(await engine.pollRemote(), isNull);
    });

    test('ClipBackoff grows 1.5s -> 2, 4, 8, 15, 15s (cap 15s) and limits screenOff to max 30s', () {
      final bo = ClipBackoff(baseSeconds: 1.5);
      expect(bo.delaySeconds, 1.5);
      expect(bo.delay(screenOff: true), const Duration(seconds: 6));

      final sequence = <double>[];
      for (var i = 0; i < 6; i++) {
        bo.failure();
        sequence.add(bo.delaySeconds);
      }
      expect(sequence, <double>[2.0, 4.0, 8.0, 15.0, 15.0, 15.0]);
      expect(bo.delay(screenOff: true), const Duration(seconds: 30));

      bo.success();
      expect(bo.delaySeconds, 1.5);
    });

    test('large text 404 retries up to 3 times before fallback, recovers if file ready, and flags isError if truncated', () async {
      final transport = FakeClipTransport()..setRemoteText('init');
      final state = MemoryClipStateStore();
      final engine = ClipSyncEngine(transport: transport, state: state);
      await engine.pollRemote();

      const fullText = 'Long text content exceeding threshold that is stored in external file.';
      const truncatedSummary = 'Long text content...';
      const fileName = 'Text_20261114_missing.txt';
      const profileHash = 'LARGE_TEXT_HASH_1234';

      transport.profile = const ClipProfile(
        type: 'Text',
        hash: profileHash,
        text: truncatedSummary,
        hasData: true,
        dataName: fileName,
        size: 50000,
      );

      // Attempt 1: 404 throws, does NOT settle profile in state store
      await expectLater(engine.pollRemote(), throwsA(isA<ClipSyncException>()));
      expect(state.lastRemoteKey, isNot(profileHash));

      // Attempt 2: still 404, does NOT settle
      await expectLater(engine.pollRemote(), throwsA(isA<ClipSyncException>()));
      expect(state.lastRemoteKey, isNot(profileHash));

      // Scenario A: file finishes uploading before 3rd attempt
      transport.files[fileName] = utf8.encode(fullText);
      final recovered = await engine.pollRemote();
      expect(recovered, isA<ClipRemoteText>());
      final textChange = recovered as ClipRemoteText;
      expect(textChange.text, fullText);
      expect(textChange.isTruncated, isFalse);
      expect(state.lastRemoteKey, profileHash);
    });

    test('large text 404 exhausting 3 retries falls back with isTruncated=true and marks status isError=true', () async {
      final transport = FakeClipTransport()..setRemoteText('init');
      final state = MemoryClipStateStore();
      final engine = ClipSyncEngine(transport: transport, state: state);
      await engine.pollRemote();

      const truncatedSummary = 'Long text prefix...';
      const fileName = 'Text_never_arrives.txt';
      const profileHash = 'POISON_TEXT_HASH';

      transport.profile = const ClipProfile(
        type: 'Text',
        hash: profileHash,
        text: truncatedSummary,
        hasData: true,
        dataName: fileName,
        size: 50000,
      );

      // Attempts 1 and 2 throw 404 without settling:
      await expectLater(engine.pollRemote(), throwsA(isA<ClipSyncException>()));
      expect(state.lastRemoteKey, isNot(profileHash));
      await expectLater(engine.pollRemote(), throwsA(isA<ClipSyncException>()));
      expect(state.lastRemoteKey, isNot(profileHash));

      // Attempt 3 reaches maxPoisonFailures: falls back with isTruncated = true
      final fallbackChange = await engine.pollRemote();
      expect(fallbackChange, isA<ClipRemoteText>());
      final textChange = fallbackChange as ClipRemoteText;
      expect(textChange.text, truncatedSummary);
      expect(textChange.isTruncated, isTrue);
      expect(state.lastRemoteKey, profileHash);
    });

    test('defaultImageFileName matches IMG_YYYYMMDD_HHMMSS_mmm_seq.png and stays unique in one millisecond', () {
      final pattern = RegExp(r'^IMG_\d{8}_\d{6}_\d{3}_\d{4,}\.png$');
      final name = PlatformClipboardAdapter.defaultImageFileName();
      expect(pattern.hasMatch(name), isTrue);

      final fixedDate = DateTime(2026, 11, 14, 22, 45, 30, 42);
      final deterministicName = PlatformClipboardAdapter.defaultImageFileName(
        now: fixedDate,
        seq: 7,
      );
      expect(deterministicName, 'IMG_20261114_224530_042_0007.png');

      final generated = <String>{};
      for (var i = 0; i < 10000; i++) {
        generated.add(PlatformClipboardAdapter.defaultImageFileName(now: fixedDate));
      }
      expect(generated, hasLength(10000));
    });

    test('defaultImageFileName guarantees zero collisions across 10,000 generations', () async {
      const workerCount = 10;
      const iterationsPerWorker = 1000;
      final pattern = RegExp(r'^IMG_\d{8}_\d{6}_\d{3}_\d{4,}\.png$');

      final futures = List.generate(workerCount, (workerId) async {
        final list = <String>[];
        for (var i = 0; i < iterationsPerWorker; i++) {
          list.add(PlatformClipboardAdapter.defaultImageFileName());
        }
        return list;
      });

      final results = await Future.wait(futures);
      final allNames = <String>[];
      for (final r in results) {
        allNames.addAll(r);
      }

      expect(allNames.length, equals(10000));
      for (final name in allNames) {
        expect(pattern.hasMatch(name), isTrue);
      }

      final uniqueSet = allNames.toSet();
      expect(
        uniqueSet.length,
        equals(10000),
        reason: 'Collision detected! Expected 0 collisions out of 10000 filenames, but found ${10000 - uniqueSet.length} collisions.',
      );
    });

    test('ClipboardSync startup records local clipboard baseline without pushing', () async {
      final transport = FakeClipTransport()..setRemoteText('server-init');
      final clip = MemoryClipboardAdapter(
        initialPayload: const ClipboardTextPayload('preexisting-local'),
      );
      final tmpDir = await Directory.systemTemp.createTemp('synchub_clip_svc_');
      addTearDown(() => _deleteTempDirSafely(tmpDir));

      final svc = ClipboardSync(
        supportDir: tmpDir.path,
        endpoint: ClipEndpointConfig.custom(
          serverUrl: 'http://127.0.0.1:9',
          username: 'u',
          password: 'wrong-password',
        ),
        adapter: clip,
        transport: transport,
        localWatchInterval: const Duration(hours: 1),
      );
      addTearDown(svc.dispose);

      await svc.start();
      // Polling local immediately after start must NOT push pre-existing clipboard:
      expect(await svc.pollLocalOnce(), isNull);
      expect(transport.puts, 0);

      // Explicit manual pushCurrentClipboard DOES push:
      final manual = await svc.pushCurrentClipboard();
      expect(manual, isA<ClipLocalPushed>());
      expect(transport.profile.text, 'preexisting-local');
      await svc.stop();
    });
  });

  // =========================================================================
  // 4. Live HTTP Round-Trip: mock_syncclipboard_server.py + Gateway Bearer Mode
  // =========================================================================
  group('Live HTTP round-trip (Python mock_syncclipboard_server.py & Gateway Bearer)', () {
    test('BasicAuth 401, short text, PascalCase, Chinese # image, and 15,000-char long text against mock_syncclipboard_server.py', () async {
      final scriptPath = _mockSyncClipboardServer();
      expect(scriptPath, isNotNull, reason: 'mock_syncclipboard_server.py not found from ${Directory.current.path}');
      expect(File(scriptPath!).existsSync(), isTrue);

      final port = await _allocateEphemeralPort();
      const user = 'sync_tester';
      const pass = 'fixture-pass';
      final baseUrl = 'http://127.0.0.1:$port';

      final proc = await Process.start(
        await _pythonCommand(),
        <String>[scriptPath, '$port', user, pass],
      );
      addTearDown(() {
        proc.kill();
      });

      // Wait until Python HTTP server accepts TCP connections.
      var ready = false;
      for (var i = 0; i < 40; i++) {
        try {
          final s = await Socket.connect('127.0.0.1', port, timeout: const Duration(milliseconds: 100));
          s.destroy();
          ready = true;
          break;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 75));
        }
      }
      expect(ready, isTrue, reason: 'mock_syncclipboard_server.py did not start on :$port');

      // 1. Wrong password -> HTTP 401
      final badTransport = SyncClipboardHttpTransport(
        ClipEndpointConfig.custom(
          serverUrl: baseUrl,
          username: user,
          password: 'wrong-password',
        ),
      );
      addTearDown(badTransport.close);
      await expectLater(
        badTransport.getProfile(),
        throwsA(
          predicate<ClipSyncException>(
            (e) => e.kind == ClipErrorKind.http && e.statusCode == 401,
          ),
        ),
      );

      // Set up Device A & Device B against the live Python server
      final tmpDir = await Directory.systemTemp.createTemp('synchub_live_py_');
      addTearDown(() => _deleteTempDirSafely(tmpDir));

      final endpoint = ClipEndpointConfig.custom(
        serverUrl: baseUrl,
        username: user,
        password: pass,
      );
      final clipA = MemoryClipboardAdapter();
      final clipB = MemoryClipboardAdapter();
      final syncA = ClipboardSync(
        supportDir: p.join(tmpDir.path, 'a'),
        endpoint: endpoint,
        adapter: clipA,
      );
      final syncB = ClipboardSync(
        supportDir: p.join(tmpDir.path, 'b'),
        endpoint: endpoint,
        adapter: clipB,
      );
      addTearDown(() async {
        await syncA.stop();
        syncA.dispose();
        await syncB.stop();
        syncB.dispose();
      });

      // Baseline poll on both clients
      expect(await syncA.pollRemoteOnce(), isNull);
      expect(await syncB.pollRemoteOnce(), isNull);

      // 2. Short text push from A -> raw wire check -> pull on B
      clipA.copyText('跨平台剪贴板直连 🚀');
      await syncA.pushCurrentClipboard();

      final basicHeader = <String, String>{
        'authorization': 'Basic ${base64.encode(utf8.encode('$user:$pass'))}',
      };
      final dbg1 = await _httpJson(
        'GET',
        Uri.parse('$baseUrl/_debug/state'),
        headers: basicHeader,
      );
      final rawProf1 = dbg1['profile'] as Map<String, dynamic>;
      expect(rawProf1['hasData'], isFalse);
      expect(rawProf1.containsKey('transferDataHash'), isFalse);

      final pulledText = await syncB.pollRemoteOnce();
      expect((pulledText as ClipRemoteText).text, '跨平台剪贴板直连 🚀');
      expect(clipB.currentText, '跨平台剪贴板直连 🚀');

      // 3. PascalCase profile from SyncHub /api/hub/text via POST /_debug/set
      const pascalMsg = '来自 SyncHub Web 面板的 PascalCase 文本';
      final pascalPayload = jsonEncode(<String, dynamic>{
        'Type': 'Text',
        'Hash': sha256TextUpper(pascalMsg),
        'Text': pascalMsg,
        'HasData': false,
        'DataName': '',
        'Size': utf8.encode(pascalMsg).length,
      });
      await _httpJson(
        'POST',
        Uri.parse('$baseUrl/_debug/set'),
        bodyBytes: utf8.encode(pascalPayload),
      );
      final pulledPascal = await syncB.pollRemoteOnce();
      expect((pulledPascal as ClipRemoteText).text, pascalMsg);

      // 4. URL-encoded Chinese + '#' + '+' + space image filename
      final imgBytes = Uint8List.fromList(
        <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 10, 20, 30, 40],
      );
      const trickyImgName = 'IMG_手机 截图 #1+2.png';
      clipA.copyImage(trickyImgName, imgBytes);
      await syncA.pushCurrentClipboard();

      final dbgImg = await _httpJson(
        'GET',
        Uri.parse('$baseUrl/_debug/state'),
        headers: basicHeader,
      );
      expect((dbgImg['files'] as List).cast<String>(), contains(trickyImgName));

      final pulledImg = await syncB.pollRemoteOnce();
      expect(pulledImg, isA<ClipRemoteImage>());
      expect((pulledImg as ClipRemoteImage).name, trickyImgName);
      expect(pulledImg.bytes, imgBytes);
      expect(syncB.isKnownHash(sha256Upper(imgBytes)), isTrue);

      // 5. 15,000-char long text (> 10,240 threshold) over HTTP
      final long15k = List<String>.generate(1500, (i) => '段${i.toString().padLeft(4, '0')}_ABCD').join();
      expect(long15k.length, 15000);
      clipA.copyText(long15k);
      await syncA.pushCurrentClipboard();

      final pulledLong = await syncB.pollRemoteOnce();
      expect(pulledLong, isA<ClipRemoteText>());
      expect((pulledLong as ClipRemoteText).text, long15k);
    });

    test('Default Gateway Bearer mode (/api/hub/sc) pushes & pulls with Bearer token', () async {
      const expectedToken = 'fixture-token';
      Uint8List serverProfile = utf8.encode(
        '{"type":"Text","hash":"","text":"","hasData":false,"dataName":null,"size":0}',
      );
      final serverFiles = <String, Uint8List>{};

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((HttpRequest req) async {
        if (req.headers.value('authorization') != 'Bearer $expectedToken') {
          req.response.statusCode = 401;
          await req.response.close();
          return;
        }
        final path = req.uri.path;
        if (path == '/api/hub/sc/SyncClipboard.json') {
          if (req.method == 'GET') {
            req.response.headers.contentType = ContentType.json;
            req.response.add(serverProfile);
          } else if (req.method == 'PUT') {
            final b = await req.fold<BytesBuilder>(
              BytesBuilder(copy: false),
              (acc, c) => acc..add(c),
            );
            serverProfile = b.takeBytes();
          }
          await req.response.close();
          return;
        }
        if (path.startsWith('/api/hub/sc/file/')) {
          final name = Uri.decodeComponent(path.substring('/api/hub/sc/file/'.length));
          if (req.method == 'PUT') {
            final b = await req.fold<BytesBuilder>(
              BytesBuilder(copy: false),
              (acc, c) => acc..add(c),
            );
            serverFiles[name] = b.takeBytes();
          } else if (req.method == 'GET') {
            final f = serverFiles[name];
            if (f == null) {
              req.response.statusCode = 404;
            } else {
              req.response.add(f);
            }
          }
          await req.response.close();
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });

      // Gateway URL includes trailing `/gw` — ClipEndpointConfig.gateway strips `/gw`
      // and targets `<origin>/api/hub/sc` automatically!
      final gwCfg = ClipEndpointConfig.gateway(
        serverUrl: 'http://127.0.0.1:${server.port}/gw',
        token: expectedToken,
      );
      expect(gwCfg.baseUrl, 'http://127.0.0.1:${server.port}/api/hub/sc');

      final transport = SyncClipboardHttpTransport(gwCfg);
      addTearDown(transport.close);

      final eng1 = ClipSyncEngine(transport: transport, state: MemoryClipStateStore());
      final eng2 = ClipSyncEngine(transport: transport, state: MemoryClipStateStore());
      await eng1.pollRemote();
      await eng2.pollRemote();

      await eng1.onLocalText('免密网关 Bearer 剪贴板测试');
      final got = await eng2.pollRemote();
      expect((got as ClipRemoteText).text, '免密网关 Bearer 剪贴板测试');
    });
  });

  // =========================================================================
  // 5. HubApi, AutoPuller, WebRtcChannel Framing & SecureStore Unit Coverage
  // =========================================================================
  group('HubApi, AutoPuller, WebRtcChannel & SecureStore', () {
    test('HubApi double-encodes upload filenames, downloads via .downloading, and AutoPuller migrates/dedups/caps poison items', () async {
      expect(HubApi.deriveOrigin('https://020814.xyz/gw'), 'https://020814.xyz');
      expect(HubApi.deriveOrigin('https://020814.xyz/gw/'), 'https://020814.xyz');

      String? capturedRawUploadQuery;
      var poisonHits = 0;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      final filePayloads = <int, List<int>>{
        12: utf8.encode('known-clipboard-bytes'),
        13: utf8.encode('fresh-offline-document'),
      };
      final knownClipSha = sha256Upper(filePayloads[12]!);

      server.listen((HttpRequest req) async {
        final path = req.uri.path;
        if (path == '/api/hub/upload' && req.method == 'PUT') {
          capturedRawUploadQuery = req.uri.query;
          final body = await req.fold<BytesBuilder>(
            BytesBuilder(copy: false),
            (b, c) => b..add(c),
          );
          final bytes = body.takeBytes();
          // Simulate synchub_server.py: parse_qs (1st decode) + unquote (2nd decode)
          final singleDecoded = req.uri.queryParameters['filename'] ?? '';
          final doubleDecoded = Uri.decodeComponent(singleDecoded);
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'item': <String, dynamic>{
                'id': 99,
                'type': 1,
                'typeName': 'File',
                'filename': doubleDecoded,
                'size': bytes.length,
                'hash': sha256Upper(bytes),
                'hasFile': true,
                'downloadUrl': '/api/hub/file/99',
              },
            }),
          );
          await req.response.close();
          return;
        }
        if (path == '/api/hub/auto-pull') {
          final since = int.parse(req.uri.queryParameters['since_id'] ?? '0');
          final allItems = <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 11,
              'type': 1,
              'filename': 'deleted_404.bin',
              'size': 10,
              'hash': 'H11',
              'hasFile': true,
              'downloadUrl': '/api/hub/file/11',
            },
            <String, dynamic>{
              'id': 12,
              'type': 2,
              'filename': 'clip_echo.png',
              'size': filePayloads[12]!.length,
              'hash': knownClipSha,
              'hasFile': true,
              'downloadUrl': '/api/hub/file/12',
            },
            <String, dynamic>{
              'id': 13,
              'type': 1,
              'filename': 'report.txt',
              'size': filePayloads[13]!.length,
              'hash': sha256Upper(filePayloads[13]!),
              'hasFile': true,
              'downloadUrl': '/api/hub/file/13',
            },
            <String, dynamic>{
              'id': 14,
              'type': 1,
              'filename': 'broken_500.bin',
              'size': 20,
              'hash': 'H14',
              'hasFile': true,
              'downloadUrl': '/api/hub/file/14',
            },
          ].where((m) => (m['id'] as int) > since).toList();
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'latestId': 14,
              'items': allItems,
            }),
          );
          await req.response.close();
          return;
        }
        if (path.startsWith('/api/hub/file/')) {
          final id = int.parse(path.split('/').last);
          if (id == 11) {
            req.response.statusCode = 404;
          } else if (id == 14) {
            poisonHits++;
            req.response.statusCode = 500;
          } else {
            final data = filePayloads[id]!;
            req.response.contentLength = data.length;
            req.response.add(data);
          }
          await req.response.close();
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });

      final tmp = await Directory.systemTemp.createTemp('synchub_hub_test_');
      addTearDown(() => _deleteTempDirSafely(tmp));

      final hub = HubApi(
        gatewayServerUrl: 'http://127.0.0.1:${server.port}/gw',
        token: 'fixture-token',
      );
      addTearDown(hub.close);

      // Verify double-percent-encoded filename upload (`100% 计划 #1.txt`)
      final srcFile = File(p.join(tmp.path, 'upload_src.txt'));
      await srcFile.writeAsString('hello hub upload');
      final uploaded = await hub.uploadFile(
        srcFile,
        filename: '100% 计划 #1.txt',
      );
      expect(uploaded.filename, '100% 计划 #1.txt');
      expect(capturedRawUploadQuery, contains('%2525')); // double-encoded '%'

      // Verify baseline initialization when no legacy cursor exists (since_id=0 -> records 14 without downloading)
      final recvDir1 = p.join(tmp.path, 'recv_baseline');
      final baselinePuller = AutoPuller(
        hub: hub,
        supportDir: p.join(tmp.path, 'state_baseline'),
        platform: 'windows',
        deviceId: 'd1',
        recvDir: recvDir1,
        legacyPathsOverride: const <String>[],
      );
      expect(await baselinePuller.pollOnce(), 0);
      expect(baselinePuller.lastId, 14);
      expect(Directory(recvDir1).existsSync(), isFalse);

      // Verify legacy cursor migration + 404 skip + clipboard hash dedup + collision rename + 3-retry poison cap
      final legacyFile = File(p.join(tmp.path, 'legacy_last_id.txt'))
        ..writeAsStringSync('10');
      final recvDir2 = p.join(tmp.path, 'recv_active')
        ..let((d) => Directory(d).createSync(recursive: true));
      // Pre-create a different-sized `report.txt` so download renames to `report (1).txt`!
      File(p.join(recvDir2, 'report.txt')).writeAsStringSync('different-size');

      final receivedPaths = <String>[];
      final puller = AutoPuller(
        hub: hub,
        supportDir: p.join(tmp.path, 'state_active'),
        platform: 'windows',
        deviceId: 'd1',
        recvDir: recvDir2,
        legacyPathsOverride: <String>[legacyFile.path],
        isKnownHash: (h) => h == knownClipSha,
        onReceived: (_, savedPath) => receivedPaths.add(savedPath),
      );

      // Poll 1: skips #11 (404), skips #12 (known clipboard hash), saves #13 as `report (1).txt`, fails #14 (1/3)
      await puller.pollOnce();
      expect(receivedPaths.length, 1);
      expect(p.basename(receivedPaths.single), 'report (1).txt');
      expect(File(receivedPaths.single).readAsStringSync(), 'fresh-offline-document');
      expect(puller.lastId, 13);

      // Polls 2 & 3 hit #14 until 3-retry poison cap advances cursor to 14:
      await puller.pollOnce();
      expect(puller.lastId, 13);
      await puller.pollOnce();
      expect(puller.lastId, 14);
      expect(poisonHits, 3);
    });

    test('WebRtcChannel 16-byte big-endian chunk framing/reassembly & 8-byte ACK/NACK codec', () {
      // Zero-length chunk
      final emptyFrames = encodeWebRtcChunkFrames(2, 0, Uint8List(0));
      expect(emptyFrames.length, 1);
      expect(emptyFrames.single.length, kWebRtcFrameHeaderBytes);
      final reassembler = WebRtcFrameReassembler();
      final zeroOut = reassembler.addFrame(emptyFrames.single)!;
      expect(zeroOut.fileIdx, 2);
      expect(zeroOut.chunkIdx, 0);
      expect(zeroOut.sealed, isEmpty);

      // Multi-slice 200 KiB chunk (> 3 frames of <= 64 KiB each)
      final payload = Uint8List.fromList(
        List<int>.generate(200 * 1024 + 37, (i) => (i * 31 + 7) & 0xff),
      );
      final frames = encodeWebRtcChunkFrames(5, 19, payload);
      expect(frames.length, 4);
      for (final f in frames) {
        expect(f.length, lessThanOrEqualTo(kWebRtcMaxFrameBytes));
      }

      // Out-of-order / partial arrival reassembles cleanly on final slice:
      expect(reassembler.addFrame(frames[0]), isNull);
      expect(reassembler.addFrame(frames[2]), isNull);
      expect(reassembler.addFrame(frames[1]), isNull);
      final assembled = reassembler.addFrame(frames[3]);
      expect(assembled, isNotNull);
      expect(assembled!.fileIdx, 5);
      expect(assembled.chunkIdx, 19);
      expect(assembled.sealed, payload);
      expect(reassembler.pendingCount, 0);

      // 8-byte ACK / NACK codec
      final ack = decodeWebRtcAck(encodeWebRtcAck(7, 42))!;
      expect(ack.fileIdx, 7);
      expect(ack.chunkIdx, 42);
      expect(ack.isNack, isFalse);

      final nack = decodeWebRtcAck(encodeWebRtcAck(7, 42, nack: true))!;
      expect(nack.fileIdx, 7);
      expect(nack.chunkIdx, 42);
      expect(nack.isNack, isTrue);
    });

    test('SecureStore gracefully returns false/null in headless CLI tests without losing plaintext fallback', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      expect(await SecureStore.read('token'), isNull);
      expect(await SecureStore.write('token', 'secret-tok'), isFalse);

      final cfgJson = <String, dynamic>{
        'server': 'https://020814.xyz/gw',
        'token': 'keep-in-headless-test',
        'private_key': 'keep-priv-key',
      };
      final scrubbed = await SecureStore.scrubConfigJson(cfgJson);
      expect(scrubbed['token'], 'keep-in-headless-test');
      expect(scrubbed['private_key'], 'keep-priv-key');
    });
  });
}

extension _LetExt<T> on T {
  void let(void Function(T value) fn) => fn(this);
}
