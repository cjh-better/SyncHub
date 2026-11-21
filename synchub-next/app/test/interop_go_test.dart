// Interop: the Flutter engine against the real Go gateway + hubctl.
// Requires server/gateway/bin/{gateway,hubctl}.exe (go build -o bin/ ./cmd/...).
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as hash;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:synchub/core/engine.dart';

final bin = p.normalize(p.absolute('../server/gateway/bin'));
String exe(String n) => p.join(bin, Platform.isWindows ? '$n.exe' : n);

Future<String> sha(String path) async => (await hash.sha256.bind(File(path).openRead()).first).toString();

Future<void> writeRandom(String path, int n) async {
  final r = Random(n);
  await File(path).parent.create(recursive: true);
  await File(path).writeAsBytes(List.generate(n, (_) => r.nextInt(256)));
}

Future<void> waitFor(bool Function() cond, String what, {int seconds = 60}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('timeout: $what');
    await Future.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  late Directory tmp;
  late Process gw;
  final procs = <Process>[];
  const port = 5947;
  const base = 'http://127.0.0.1:$port';

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('synchub_interop');
    gw = await Process.start(exe('gateway'), ['-addr', '127.0.0.1:$port', '-data', p.join(tmp.path, 'd.json')],
        environment: {'SYNCHUB_USER': 'u', 'SYNCHUB_PASSWORD': 'p'});
    gw.stderr.drain<void>();
    await waitFor(() => false, 'noop', seconds: 0).catchError((_) {});
    await Future.delayed(const Duration(milliseconds: 800));
  });

  tearDownAll(() async {
    for (final pr in procs) {
      pr.kill();
    }
    gw.kill();
    await Future.delayed(const Duration(milliseconds: 300));
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<Process> hubctl(List<String> args, StringBuffer log) async {
    final pr = await Process.start(exe('hubctl'), args);
    pr.stdout.transform(utf8.decoder).listen(log.write);
    pr.stderr.transform(utf8.decoder).listen(log.write);
    procs.add(pr);
    return pr;
  }

  test('Flutter engine <-> Go hubctl over LAN and relay', () async {
    // Go device
    final goCfg = p.join(tmp.path, 'go.json');
    final goRecv = p.join(tmp.path, 'go-recv');
    final r = await Process.run(exe('hubctl'),
        ['-config', goCfg, 'register', '-server', base, '-name', 'Go-PC', '-user', 'u', '-pass', 'p', '-recv', goRecv]);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    final goId = (jsonDecode(await File(goCfg).readAsString()) as Map)['device_id'] as String;

    // Flutter engine device
    final supp = p.join(tmp.path, 'flutter');
    final eng = await Engine.open(supp);
    await eng.register(server: base, name: 'Flutter-Phone', user: 'u', pass: 'p', recvDir: p.join(tmp.path, 'fl-recv'));
    await eng.updateConfig((c) => c.lanPort = 53397);
    await eng.start();
    await waitFor(() => eng.connected, 'engine connected');

    // 1) Flutter -> Go with the Go LAN receiver on all interfaces => expect lan
    final glog = StringBuffer();
    final daemon = await hubctl(['-config', goCfg, 'daemon', '-lan', ':53396'], glog);
    await waitFor(() => (eng.devices[goId]?.online ?? false) && eng.devices[goId]!.lan.isNotEmpty, 'go online with lan');
    final src = p.join(tmp.path, 'src', '项目');
    await writeRandom(p.join(src, 'a.bin'), 5 * 1024 * 1024 + 7);
    await writeRandom(p.join(src, 'sub', 'b.txt'), 1234);
    await File(p.join(src, 'empty.txt')).writeAsBytes(const []);
    final tid1 = await eng.sendPaths(goId, [src]);
    await waitFor(() => eng.transfers[tid1]!.finished, 'flutter->go', seconds: 90);
    expect(eng.transfers[tid1]!.state, TransferState.done, reason: '${eng.transfers[tid1]!.error}\n$glog\n${eng.logLines.join('\n')}');
    expect(await sha(p.join(goRecv, '项目', 'a.bin')), await sha(p.join(src, 'a.bin')));
    expect(await sha(p.join(goRecv, '项目', 'sub', 'b.txt')), await sha(p.join(src, 'sub', 'b.txt')));
    expect(await File(p.join(goRecv, '项目', 'empty.txt')).length(), 0);
    expect(eng.transfers[tid1]!.route, 'lan', reason: eng.logLines.join('\n'));

    // 1b) same direction with the Go LAN receiver disabled => relay
    daemon.kill();
    await waitFor(() => !(eng.devices[goId]?.online ?? true), 'go offline');
    final daemon2 = await hubctl(['-config', goCfg, 'daemon', '-lan', ''], glog);
    await waitFor(() => eng.devices[goId]?.online ?? false, 'go online again');
    final one = p.join(tmp.path, 'src', 'relay.bin');
    await writeRandom(one, 4 * 1024 * 1024 + 99);
    final tid2 = await eng.sendPaths(goId, [one]);
    await waitFor(() => eng.transfers[tid2]!.finished, 'flutter->go relay', seconds: 90);
    expect(eng.transfers[tid2]!.state, TransferState.done, reason: eng.logLines.join('\n'));
    expect(eng.transfers[tid2]!.route, startsWith('relay:'));
    expect(await sha(p.join(goRecv, 'relay.bin')), await sha(one));
    daemon2.kill();

    // 2) Go -> Flutter: Flutter advertises its private-IP LAN urls => lan if reachable, else relay
    final big = p.join(tmp.path, 'src', 'video.mp4');
    await writeRandom(big, 9 * 1024 * 1024);
    final slog = StringBuffer();
    final send = await hubctl(['-config', goCfg, 'send', '-to', 'Flutter-Phone', big], slog);
    final code = await send.exitCode.timeout(const Duration(seconds: 90));
    expect(code, 0, reason: '$slog\n${eng.logLines.join('\n')}');
    final got = p.join(tmp.path, 'fl-recv', 'video.mp4');
    expect(await sha(got), await sha(big));
    final viaLan = slog.toString().contains('via lan');
    // ignore: avoid_print
    print('go->flutter route: ${viaLan ? 'lan' : 'relay'}  (flutter lan urls: ${eng.lanUrls})');
    if (eng.lanUrls.isNotEmpty) expect(viaLan, isTrue, reason: slog.toString());

    await eng.stop();
  });
}
