import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:synchub/platform/official_exit.dart';

void main() {
  test('ipc exit during the first wait lets the trial watch', () {
    final outcome = OfficialExitPolicy.simulate(runningAtStart: true, goneAtPoll: 2);
    expect(outcome, OfficialExitOutcome.stoppedByIpc);
    expect(OfficialExitPolicy.trialMayWatch(outcome), isTrue);
  });

  test('a process that leaves during the tray wait still continues the same trial', () {
    final outcome = OfficialExitPolicy.simulate(
      runningAtStart: true,
      goneAtPoll: OfficialExitPolicy.ipcPolls + 2,
    );
    expect(outcome, OfficialExitOutcome.stoppedAfterTray);
    expect(OfficialExitPolicy.trialMayWatch(outcome), isTrue);
  });

  test('a process that never leaves does not enable SyncHub clipboard', () {
    final outcome = OfficialExitPolicy.simulate(runningAtStart: true);
    expect(outcome, OfficialExitOutcome.stillRunning);
    expect(OfficialExitPolicy.trialMayWatch(outcome), isFalse);
  });

  test('an already stopped official client can be verified without another stop', () {
    final outcome = OfficialExitPolicy.simulate(runningAtStart: false, goneAtPoll: null);
    expect(outcome, OfficialExitOutcome.alreadyStopped);
    expect(OfficialExitPolicy.trialMayWatch(outcome), isTrue);
  });

  test('the helper uses the official Shutdown pipe and does not force-kill', () {
    final script = _helperScript();
    final text = script.readAsStringSync();
    expect(text, contains(OfficialExitPolicy.pipeNamePrefix));
    expect(text, contains("WriteLine('Shutdown')"));
    expect(text, contains('退出'));
    expect(text, contains('-Seconds 45'));
    expect(text, contains('-Seconds 180'));
    expect(text, contains('-StopOfficial'));
    expect(text.toLowerCase(), isNot(contains('taskkill')));
    expect(text, isNot(contains('--shutdown-previous')));
    expect(text, isNot(contains('Start-Sleep -Milliseconds 800')));
    final stop = text.indexOf('function Request-OfficialExit');
    final trialWrite = text.indexOf('op = "trial"');
    expect(stop, greaterThan(0));
    expect(trialWrite, greaterThan(stop));
    expect(script.readAsBytesSync().take(3).toList(), [0xEF, 0xBB, 0xBF]);
  });
}

File _helperScript() {
  var dir = Directory.current;
  for (var i = 0; i < 5; i++) {
    final candidate = File(p.join(dir.path, 'scripts', 'windows_single_tray.ps1'));
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('windows_single_tray.ps1 was not found from ${Directory.current.path}');
}
