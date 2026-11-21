// A small pool of long-lived isolates for CPU-heavy work (AES-GCM, SHA-256),
// so transfers use several cores and never block the UI isolate.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;

import 'e2e.dart';

class CryptoPool {
  final int targetSize;
  final Duration idleTimeout;
  List<_Worker> _workers = <_Worker>[];
  int _next = 0;
  int _activeJobs = 0;
  Timer? _idleTimer;
  Future<void>? _spawning;
  bool _closed = false;

  CryptoPool({
    int? targetSize,
    this.idleTimeout = const Duration(seconds: 60),
  }) : targetSize = targetSize ?? max(1, min(6, Platform.numberOfProcessors - 1));

  static Future<CryptoPool> start([int? n]) async {
    return CryptoPool(targetSize: n);
  }

  int get size => _workers.length;
  bool get isIdle => _workers.isEmpty;

  Future<List<_Worker>> _ensureWorkers() async {
    if (_closed) throw StateError('CryptoPool is closed');
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_workers.isNotEmpty) return _workers;
    if (_spawning != null) {
      await _spawning;
      return _workers;
    }
    final c = Completer<void>();
    _spawning = c.future;
    try {
      final ws = await Future.wait(List.generate(targetSize, (_) => _Worker.spawn()));
      if (_closed) {
        for (final w in ws) {
          w.kill();
        }
        throw StateError('CryptoPool closed while spawning');
      }
      _workers = ws;
      c.complete();
      return _workers;
    } catch (e, st) {
      c.completeError(e, st);
      rethrow;
    } finally {
      _spawning = null;
    }
  }

  Future<_Worker> _pick() async {
    final ws = await _ensureWorkers();
    return ws[_next++ % ws.length];
  }

  Future<T> _runJob<T>(Future<T> Function(_Worker w) action) async {
    _idleTimer?.cancel();
    _idleTimer = null;
    _activeJobs++;
    try {
      final w = await _pick();
      return await action(w);
    } finally {
      _activeJobs--;
      if (_activeJobs <= 0) {
        _activeJobs = 0;
        _scheduleIdleShutdown();
      }
    }
  }

  void _scheduleIdleShutdown() {
    _idleTimer?.cancel();
    if (_workers.isEmpty || _closed) return;
    _idleTimer = Timer(idleTimeout, () {
      if (_activeJobs == 0 && !_closed) {
        closeWorkers();
      }
    });
  }

  void closeWorkers() {
    _idleTimer?.cancel();
    _idleTimer = null;
    for (final w in _workers) {
      w.kill();
    }
    _workers = <_Worker>[];
  }

  Future<Uint8List> seal(SessionCipher c, int file, int chunk, Uint8List plain) =>
      _runJob((w) => w.call(['seal', c.keyBytes, c.transferId, c.session, file, chunk, TransferableTypedData.fromList([plain])]));

  /// Throws [ChunkAuthException] when authentication fails.
  Future<Uint8List> open(SessionCipher c, int file, int chunk, Uint8List sealed) =>
      _runJob((w) => w.call(['open', c.keyBytes, c.transferId, c.session, file, chunk, TransferableTypedData.fromList([sealed])]));

  /// SHA-256 (hex) of a whole file, computed off the UI isolate.
  Future<String> sha256File(String path) =>
      _runJob((w) async {
        final r = await w.call(['sha256', path]);
        return String.fromCharCodes(r);
      });

  void close() {
    _closed = true;
    closeWorkers();
  }
}

class _Worker {
  final Isolate _iso;
  final SendPort _send;
  final ReceivePort _recv;
  final Map<int, Completer<Uint8List>> _pending;
  int _seq = 0;

  _Worker._(this._iso, this._send, this._recv, this._pending);

  static Future<_Worker> spawn() async {
    final recv = ReceivePort();
    final pending = <int, Completer<Uint8List>>{};
    final ready = Completer<SendPort>();
    recv.listen((msg) {
      if (msg is SendPort) {
        if (!ready.isCompleted) ready.complete(msg);
        return;
      }
      final m = msg as List;
      final c = pending.remove(m[0] as int);
      if (c == null) return;
      if (m[1] == 'ok') {
        c.complete((m[2] as TransferableTypedData).materialize().asUint8List());
      } else if (m[1] == 'auth') {
        c.completeError(const ChunkAuthException());
      } else {
        c.completeError(Exception(m[2] as String));
      }
    });
    final iso = await Isolate.spawn(_main, recv.sendPort);
    return _Worker._(iso, await ready.future, recv, pending);
  }

  Future<Uint8List> call(List args) {
    final id = _seq++;
    final c = Completer<Uint8List>();
    _pending[id] = c;
    _send.send([id, ...args]);
    return c.future;
  }

  void kill() {
    _recv.close();
    _iso.kill(priority: Isolate.immediate);
  }

  static Future<void> _main(SendPort out) async {
    final inbox = ReceivePort();
    out.send(inbox.sendPort);
    await for (final msg in inbox) {
      final m = msg as List;
      final id = m[0] as int;
      final op = m[1] as String;
      try {
        if (op == 'sha256') {
          final digest = await hash.sha256.bind(File(m[2] as String).openRead()).first;
          out.send([id, 'ok', TransferableTypedData.fromList([Uint8List.fromList(digest.toString().codeUnits)])]);
          continue;
        }
        final c = SessionCipher.fromKey(m[2] as Uint8List, m[3] as String, m[4] as String);
        final data = (m[7] as TransferableTypedData).materialize().asUint8List();
        final res = op == 'seal' ? await c.seal(m[5] as int, m[6] as int, data) : await c.open(m[5] as int, m[6] as int, data);
        out.send([id, 'ok', TransferableTypedData.fromList([res])]);
      } on ChunkAuthException {
        out.send([id, 'auth', '']);
      } catch (e) {
        out.send([id, 'err', e.toString()]);
      }
    }
  }
}
