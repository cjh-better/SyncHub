import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:synchub/core/clip_group_zip.dart';
import 'package:synchub/core/clipboard_sync.dart';
import 'package:synchub/platform/tray_ownership.dart';
import 'package:synchub/platform/win_integration.dart';

void main() {
  test('trial lets SyncHub watch only after SyncClipboard stops, and abort pauses SyncHub first', () {
    final sim = ClipboardOwnerSim(officialRunning: true, syncHubWatching: false);
    final trial = HandoffPlan.beginTrial(officialRunning: true);
    expect(trial.actions, isNot(contains(HandoffAction.disableOfficialStartup)));
    expect(trial.deletesUserData, isFalse);
    for (final action in trial.actions) {
      sim.apply(action);
    }
    expect(sim.officialRunning, isFalse);
    expect(sim.syncHubWatching, isTrue);
    expect(sim.startupEnabled, isTrue);
    expect(sim.bothWriting, isFalse);

    final abort = HandoffPlan.abortTrial();
    expect(abort.actions.indexOf(HandoffAction.pauseSyncHubClipboard),
        lessThan(abort.actions.indexOf(HandoffAction.startOfficialProcess)));
    for (final action in abort.actions) {
      sim.apply(action);
    }
    expect(sim.officialRunning, isTrue);
    expect(sim.syncHubWatching, isFalse);
    expect(sim.startupEnabled, isTrue);
    expect(sim.deletedUserData, isFalse);
  });

  test('commit is refused while SyncClipboard is still running', () {
    final early = HandoffPlan.commit(phase: HandoffPhase.idle, officialRunning: false);
    expect(early.refused, isTrue);
    expect(early.actions, isEmpty);
    final busy = HandoffPlan.commit(phase: HandoffPhase.trial, officialRunning: true);
    expect(busy.refused, isTrue);

    final sim = ClipboardOwnerSim(officialRunning: false, syncHubWatching: true);
    final commit = HandoffPlan.commit(phase: HandoffPhase.trial, officialRunning: false);
    expect(commit.refused, isFalse);
    for (final action in commit.actions) {
      sim.apply(action);
    }
    expect(sim.startupEnabled, isFalse);
    expect(sim.officialRunning, isFalse);
    expect(sim.syncHubWatching, isTrue);
    expect(sim.bothWriting, isFalse);
    expect(sim.deletedUserData, isFalse);
  });

  test('task command parser keeps the executable path and drops arguments', () {
    const xml = '<Exec><Command>"C:\\Apps\\SyncClipboard\\SyncClipboard.exe"</Command>'
        '<Arguments>--minimized</Arguments></Exec>';
    expect(commandFromTaskXml(xml), r'C:\Apps\SyncClipboard\SyncClipboard.exe');
  });

  test('abort command is visible before the official process starts', () {
    final cmd = HandoffCommand.parse('{"op":"abort","paused":false,"exe":"C:\\\\Apps\\\\SyncClipboard.exe"}');
    expect(cmd, isNotNull);
    expect(cmd!.requestsAbort, isTrue);
    expect(cmd.paused, isFalse);
  });

  test('official process yields clipboard duty; a stopped process does not', () {
    const running = OfficialClipboardPresence(
      processRunning: true,
      startupTaskPresent: true,
      startupTaskEnabled: true,
      runValuePresent: false,
    );
    const stopped = OfficialClipboardPresence(
      processRunning: false,
      startupTaskPresent: true,
      startupTaskEnabled: true,
      runValuePresent: true,
    );
    expect(decideClipboardDuty(running), ClipboardDuty.yieldToOfficial);
    expect(decideClipboardDuty(stopped), ClipboardDuty.synchub);
    expect(decideClipboardDuty(const OfficialClipboardPresence.absent()), ClipboardDuty.synchub);
  });

  test('confirmed takeover disables startup and never deletes user data', () {
    const plan = TrayTakeoverPlan.confirmed();
    expect(plan.backupFirst, isTrue);
    expect(plan.disableStartupTask, isTrue);
    expect(plan.removeOfficialRunValue, isTrue);
    expect(plan.stopOfficialProcess, isTrue);
    expect(plan.keepsUserData, isTrue);
    expect(plan.deleteProgramFiles, isFalse);
    expect(plan.deleteUserConfig, isFalse);
    expect(plan.deleteHistory, isFalse);
    expect(plan.taskName, isNot(TrayTakeoverPlan.synchubRunValue));
    expect(TrayTakeoverPlan.officialTask, r'\SyncClipboardStartup');
    expect(const TrayTakeoverPlan.backupOnly().disableStartupTask, isFalse);
  });

  test('task XML treats missing Enabled as enabled and false as disabled', () {
    expect(taskXmlEnabled('<Task><Settings></Settings></Task>'), isTrue);
    expect(taskXmlEnabled('<Enabled>true</Enabled>'), isTrue);
    expect(taskXmlEnabled('<Enabled>false</Enabled>'), isFalse);
    expect(taskXmlEnabled('<Enabled> FALSE </Enabled>'), isFalse);
  });

  test('account parser reads the active profile and describe hides the password', () {
    final parsed = WinIntegration.parseSyncClipboardAccountMap(<String, dynamic>{
      'Account': <String, dynamic>{'AccountId': 'home'},
      'SavedAccounts': <String, dynamic>{
        'SyncClipboard': <String, dynamic>{
          'home': <String, dynamic>{
            'RemoteURL': 'https://clipboard.example/',
            'UserName': 'fixture-user',
            'Password': 'fixture-password',
          },
          'other': <String, dynamic>{
            'RemoteURL': 'https://other.example',
            'UserName': 'other',
            'Password': 'other-secret',
          },
        },
      },
    });
    expect(parsed, isNotNull);
    expect(parsed!.serverUrl, 'https://clipboard.example');
    expect(parsed.username, 'fixture-user');
    expect(parsed.password, 'fixture-password');
    final described = WinIntegration.describeLogin(parsed);
    expect(described, contains('fixture-user'));
    expect(described, isNot(contains('fixture-password')));
    expect(described, isNot(contains('other-secret')));
  });

  test('SyncHub pauses clipboard upload while yielding and resumes without pushing the baseline', () async {
    final transport = FakeClipTransport()..setRemoteText('server-init');
    final clip = MemoryClipboardAdapter(initialPayload: const ClipboardTextPayload('local'));
    final tmp = await Directory.systemTemp.createTemp('synchub_yield_');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    final svc = ClipboardSync(
      supportDir: tmp.path,
      endpoint: ClipEndpointConfig.custom(serverUrl: 'http://127.0.0.1:9', username: 'u', password: 'fixture-pass'),
      adapter: clip,
      transport: transport,
      localWatchInterval: const Duration(hours: 1),
    );
    addTearDown(svc.dispose);
    await svc.start();
    await svc.setYieldToOfficialClient(true);
    expect(svc.yieldsToOfficialClient, isTrue);
    expect(svc.isRunning, isFalse);
    clip.copyText('while-official-owns-clipboard');
    expect(await svc.pollLocalOnce(), isNull);
    expect(transport.puts, 0);
    await svc.setYieldToOfficialClient(false);
    expect(svc.isRunning, isTrue);
    expect(await svc.pollLocalOnce(), isNull);
    expect(transport.puts, 0);
    clip.copyText('after-takeover');
    await svc.pollLocalOnce();
    expect(transport.puts, greaterThan(0));
    expect(transport.profile.text, 'after-takeover');
  });

  test('remote File is staged inside clip_inbox and placed on the clipboard', () async {
    final transport = FakeClipTransport()..setRemoteText('base');
    final clip = MemoryClipboardAdapter();
    final tmp = await Directory.systemTemp.createTemp('synchub_fileclip_');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    final bytes = Uint8List.fromList('hello-fixture'.codeUnits);
    const name = 'note.txt';
    final contentHash = sha256Upper(bytes);
    transport.files[name] = bytes;
    final svc = ClipboardSync(
      supportDir: tmp.path,
      endpoint: const ClipEndpointConfig(),
      adapter: clip,
      transport: transport,
      stateStore: MemoryClipStateStore(),
      localWatchInterval: const Duration(hours: 1),
    );
    addTearDown(svc.dispose);
    expect(await svc.pollRemoteOnce(), isNull);
    transport.profile = ClipProfile(
      type: 'File',
      hash: fileProfileHash(name, contentHash),
      text: name,
      hasData: true,
      dataName: name,
      transferDataHash: contentHash,
      size: bytes.length,
    );
    final change = await svc.pollRemoteOnce();
    expect(change, isA<ClipRemoteFile>());
    final paths = clip.currentFilePaths;
    expect(paths, isNotNull);
    expect(paths, hasLength(1));
    expect(p.isWithin(p.join(tmp.path, 'clip_inbox'), paths!.single), isTrue);
    expect(await File(paths.single).readAsBytes(), bytes);
    expect(File(p.join(tmp.path, 'note.txt')).existsSync(), isFalse);
  });

  test('group zip extracts safe names and rejects traversal', () async {
    final good = _storedZip(<String, List<int>>{
      'a.txt': 'alpha'.codeUnits,
      'dir/b.txt': 'beta'.codeUnits,
    });
    final entries = readSafeZip(good);
    expect(entries.map((e) => e.name), ['a.txt', 'dir/b.txt']);
    expect(() => readSafeZip(_storedZip(<String, List<int>>{'../outside.txt': 'no'.codeUnits})),
        throwsA(isA<ClipZipException>()));

    final tmp = await Directory.systemTemp.createTemp('synchub_zip_');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    final badPaths = await stageClipboardPayload(
      supportDir: tmp.path,
      key: 'GROUPBAD',
      name: 'group.zip',
      bytes: _storedZip(<String, List<int>>{'../outside.txt': 'no'.codeUnits}),
      groupArchive: true,
    );
    expect(badPaths, hasLength(1));
    expect(p.basename(badPaths.single), 'group.zip');
    expect(File(p.join(tmp.path, 'outside.txt')).existsSync(), isFalse);

    final goodPaths = await stageClipboardPayload(
      supportDir: tmp.path,
      key: 'GROUPGOOD',
      name: 'group.zip',
      bytes: good,
      groupArchive: true,
    );
    expect(goodPaths, hasLength(2));
    for (final path in goodPaths) {
      expect(p.isWithin(p.join(tmp.path, 'clip_inbox'), path), isTrue);
    }
  });
}

Uint8List _storedZip(Map<String, List<int>> files) {
  final locals = BytesBuilder();
  final central = BytesBuilder();
  var offset = 0;
  for (final entry in files.entries) {
    final name = entry.key.codeUnits;
    final data = entry.value;
    final local = BytesBuilder();
    _u32(local, 0x04034b50);
    _u16(local, 20);
    _u16(local, 0);
    _u16(local, 0);
    _u16(local, 0);
    _u16(local, 0);
    _u32(local, 0);
    _u32(local, data.length);
    _u32(local, data.length);
    _u16(local, name.length);
    _u16(local, 0);
    local.add(name);
    local.add(data);
    final localBytes = local.toBytes();
    locals.add(localBytes);

    _u32(central, 0x02014b50);
    _u16(central, 20);
    _u16(central, 20);
    _u16(central, 0);
    _u16(central, 0);
    _u16(central, 0);
    _u16(central, 0);
    _u32(central, 0);
    _u32(central, data.length);
    _u32(central, data.length);
    _u16(central, name.length);
    _u16(central, 0);
    _u16(central, 0);
    _u16(central, 0);
    _u16(central, 0);
    _u32(central, 0);
    _u32(central, offset);
    central.add(name);
    offset += localBytes.length;
  }
  final centralBytes = central.toBytes();
  final localBytes = locals.toBytes();
  final out = BytesBuilder();
  out.add(localBytes);
  out.add(centralBytes);
  _u32(out, 0x06054b50);
  _u16(out, 0);
  _u16(out, 0);
  _u16(out, files.length);
  _u16(out, files.length);
  _u32(out, centralBytes.length);
  _u32(out, localBytes.length);
  _u16(out, 0);
  return out.toBytes();
}

class FakeClipTransport implements ClipTransport {
  ClipProfile profile = const ClipProfile(
    type: 'Text',
    hash: '',
    text: '',
    hasData: false,
    dataName: null,
    size: 0,
  );
  final Map<String, Uint8List> files = <String, Uint8List>{};
  int puts = 0;

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

  @override
  Future<ClipProfile> getProfile() async => profile;

  @override
  Future<void> putProfile(ClipProfile next) async {
    profile = ClipProfile.parse(next.toJsonBytes());
    puts++;
  }

  @override
  Future<Uint8List> getFile(String name, {required int maxBytes}) async {
    final data = files[name];
    if (data == null) throw ClipSyncException.http(404, 'not found');
    return Uint8List.fromList(data);
  }

  @override
  Future<void> putFile(String name, Uint8List bytes) async {
    files[name] = Uint8List.fromList(bytes);
  }

  @override
  void close() {}
}

void _u16(BytesBuilder b, int v) {
  b.add(<int>[v & 0xff, (v >> 8) & 0xff]);
}

void _u32(BytesBuilder b, int v) {
  b.add(<int>[v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
}
