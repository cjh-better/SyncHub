import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:synchub/core/e2e.dart';

void main() {
  test('AES-GCM throughput (informational)', () async {
    final a = await DeviceKey.generate();
    final b = await DeviceKey.generate();
    final (_, c) = await SessionCipher.sender(a, b.publicB64, 'tBenchmark0001', 'sess');
    final buf = Uint8List(4 << 20);
    final r = Random(1);
    for (var i = 0; i < buf.length; i++) {
      buf[i] = r.nextInt(256);
    }
    await c.seal(0, 0, buf); // warm-up
    final sw = Stopwatch()..start();
    const n = 8;
    for (var i = 1; i <= n; i++) {
      await c.seal(0, i, buf);
    }
    sw.stop();
    final mbps = n * 4 / (sw.elapsedMilliseconds / 1000);
    // ignore: avoid_print
    print('AES-256-GCM seal: ${mbps.toStringAsFixed(1)} MiB/s (JIT)');
  });
}
