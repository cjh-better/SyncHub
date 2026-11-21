// The SyncHub transfer engine: gateway connection, presence, signaling,
// outbox scheduler, sender (LAN-first, then fastest relay), receiver with
// resumable state, and the direct-LAN receiver. Port of the Go reference
// client (server/gateway/internal/client); protocol in protocol/PROTOCOL.md.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'api.dart';
import 'clipboard_sync.dart';
import 'config.dart';
import 'crypto_pool.dart';
import 'e2e.dart';
import 'hub_api.dart';
import 'manifest.dart';
import 'mdns_discovery.dart';
import 'proto.dart';
import 'secure_store.dart';
import 'webrtc_channel.dart';

const String kCloudTargetId = '__cloud__';

enum TransferState { hashing, queued, connecting, active, waiting, paused, done, failed }

class PendingOffer {
  final String transferId;
  final String session;
  final String fromId;
  final String fromName;
  final String title;
  final int totalSize;
  final int fileCount;
  final DateTime arrivedAt;
  final Completer<bool> _decision = Completer<bool>();

  PendingOffer({
    required this.transferId,
    required this.session,
    required this.fromId,
    required this.fromName,
    required this.title,
    required this.totalSize,
    required this.fileCount,
    DateTime? arrivedAt,
  }) : arrivedAt = arrivedAt ?? DateTime.now();

  bool get isDecided => _decision.isCompleted;
  Future<bool> get decision => _decision.future;

  void decide(bool accept) {
    if (!_decision.isCompleted) _decision.complete(accept);
  }
}

class TransferView {
  final String id;
  final String direction; // send | recv
  String peerId;
  String peer;
  String title;
  int done = 0;
  int total = 0;
  double speed = 0;
  String route = '';
  TransferState state;
  String error = '';
  List<String> saved = const [];
  List<String> sourcePaths = const [];
  DateTime updated = DateTime.now();
  int _lastDone = 0;

  TransferView(this.id, this.direction, this.peerId, this.peer, this.title, this.state);

  double get fraction => total == 0 ? (state == TransferState.done ? 1 : 0) : (done / total).clamp(0.0, 1.0);
  bool get finished => state == TransferState.done || state == TransferState.failed;
  bool get isPaused => state == TransferState.paused;

  Map<String, dynamic> toJson() => {
        'id': id,
        'direction': direction,
        'peer_id': peerId,
        'peer': peer,
        'title': title,
        'total': total,
        'route': route,
        'state': state.name,
        'error': error,
        'saved': saved,
        if (sourcePaths.isNotEmpty) 'sources': sourcePaths,
        'updated': updated.toIso8601String(),
      };

  factory TransferView.fromJson(Map<String, dynamic> j) {
    final stateName = (j['state'] ?? 'failed') as String;
    final parsedState = TransferState.values.asNameMap()[stateName] ?? TransferState.failed;
    final t = TransferView(
      j['id'] as String,
      j['direction'] as String,
      (j['peer_id'] ?? '') as String,
      (j['peer'] ?? '') as String,
      (j['title'] ?? '') as String,
      parsedState,
    );
    t.total = (j['total'] ?? 0) as int;
    t.done = t.state == TransferState.done ? t.total : 0;
    t.route = (j['route'] ?? '') as String;
    t.error = (j['error'] ?? '') as String;
    t.saved = ((j['saved'] ?? []) as List).cast<String>();
    t.sourcePaths = ((j['sources'] ?? []) as List).cast<String>();
    t.updated = DateTime.tryParse((j['updated'] ?? '') as String) ?? DateTime.now();
    return t;
  }
}

class _Cancelled implements Exception {
  final String reason;
  _Cancelled(this.reason);
  @override
  String toString() => reason;
}

class _Token {
  bool _c = false;
  String reason = '';
  final _done = Completer<void>();
  bool get isCancelled => _c;
  Future<void> get whenCancelled => _done.future;
  void cancel([String r = 'cancelled']) {
    if (_c) return;
    _c = true;
    reason = r;
    _done.complete();
  }

  void check() {
    if (_c) throw _Cancelled(reason);
  }
}

class _Lock {
  Future<void> _last = Future.value();
  Future<T> run<T>(Future<T> Function() f) {
    final prev = _last;
    final c = Completer<void>();
    _last = c.future;
    return prev.then((_) => f()).whenComplete(c.complete);
  }
}

class OutEntry {
  final String transferId;
  final String to;
  final String title;
  final int chunkSize;
  final List<LocalFile> files;
  final List<String> dirs;
  final DateTime createdAt;
  OutEntry(this.transferId, this.to, this.title, this.chunkSize, this.files, this.dirs, this.createdAt);

  int get total => files.fold(0, (a, f) => a + f.entry.size);

  factory OutEntry.fromJson(Map<String, dynamic> j) => OutEntry(
        j['transfer_id'] as String,
        j['to'] as String,
        (j['title'] ?? '') as String,
        (j['chunk_size'] ?? kDefaultChunkSize) as int,
        ((j['files'] ?? []) as List).map((e) => LocalFile.fromJson(e as Map<String, dynamic>)).toList(),
        ((j['dirs'] ?? []) as List).cast<String>(),
        DateTime.tryParse((j['created_at'] ?? '') as String) ?? DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
        'transfer_id': transferId,
        'to': to,
        'title': title,
        'chunk_size': chunkSize,
        'files': files.map((f) => f.toJson()).toList(),
        if (dirs.isNotEmpty) 'dirs': dirs,
        'created_at': createdAt.toUtc().toIso8601String(),
      };
}

class Engine extends ChangeNotifier {
  final File cfgFile;
  AppConfig? _cfg;
  AppConfig? get cfg => _cfg;
  set cfg(AppConfig? value) {
    _cfg = value;
    registeredNotifier.value = value?.registered ?? false;
  }
  final ValueNotifier<bool> registeredNotifier = ValueNotifier<bool>(false);
  DeviceKey? _key;
  GatewayApi? _api;
  CryptoPool? _pool;

  HubApi? _hub;
  ClipboardSync? _clipSync;
  AutoPuller? _autoPuller;
  MdnsDiscovery? _mdns;
  WebRtcCoordinator? _webrtc;

  /// Controls whether OS-level background loops (clipboard polling, AutoPuller,
  /// UDP/mDNS beacons) auto-start in [start]. Defaults to `false` inside
  /// `flutter test` so CLI tests never touch the host machine's clipboard.
  bool enableBackgroundServices = !Platform.environment.containsKey('FLUTTER_TEST');

  /// Optional legacy SyncHub `last_id` supplied by platform migration (e.g. Android Root setup).
  int initialLegacyHubId = 0;

  /// Optional override for SyncHub Cloud base URL (used in isolated integration tests).
  String? hubBaseOverride;

  /// Platform hooks for native notifications, media scanner, incoming prompt, and multi-file copy.
  void Function(TransferView view, List<String> paths)? onFilesSaved;
  void Function(PendingOffer offer)? onIncomingOfferPrompt;
  void Function(List<String> paths)? onCopiedMultipleFiles;

  String self = '';
  final devices = <String, DeviceInfo>{};
  final pendingOffers = <String, PendingOffer>{};
  bool connected = false;
  String status = '';
  final transfers = <String, TransferView>{};
  final logLines = <String>[];
  List<String> lanUrls = const [];

  bool _running = false;
  WebSocket? _ws;
  HttpServer? _lanServer;
  Timer? _ticker;
  final _waiters = <String, Completer<Signal>>{};
  Completer<void>? _reconnectKick;
  bool _connLoopRunning = false;
  bool _backoffReset = false;

  @visibleForTesting
  int get pendingWaitersCount => _waiters.length;

  @visibleForTesting
  Completer<Signal> waitForForTest(String key) => _waitFor(key);

  @visibleForTesting
  void failPendingWaitersForTest([Object? error]) => _failPendingWaiters(error);
  final _activeOut = <String, _Token>{};
  final _nextTry = <String, DateTime>{};
  final _backoff = <String, int>{};
  final _bad = <String, DateTime>{};
  final _pausedIds = <String>{};
  final _acceptedTransfers = <String>{};
  final _mdnsPeerUrls = <String, List<String>>{};
  final _incoming = <String, (_Token, Future<void>, String)>{};
  final _sinks = <String, _Sink>{};
  final _rand = Random.secure();
  int workers = 4;

  Engine(this.cfgFile);

  static Future<Engine> open(String supportDir) async {
    final e = Engine(File(p.join(supportDir, 'config.json')));
    e.cfg = await AppConfig.load(e.cfgFile);
    await e._loadHistory(supportDir);
    if (e.cfg != null) e._ensureSubservices();
    return e;
  }

  bool get registered => cfg?.registered ?? false;
  GatewayApi get api => _api!;
  HubApi get hub => _ensureSubservices().$1;
  ClipboardSync get clipSync => _ensureSubservices().$2;
  AutoPuller get autoPuller => _ensureSubservices().$3;
  MdnsDiscovery? get mdns => _mdns;
  WebRtcCoordinator? get webrtc => _webrtc;

  ClipEndpointConfig _buildClipEndpoint(AppConfig c) {
    if (c.customClipUrl.trim().isNotEmpty) {
      return ClipEndpointConfig.custom(
        serverUrl: c.customClipUrl.trim(),
        username: c.customClipUser.trim(),
        password: c.customClipPass,
      );
    }
    return ClipEndpointConfig.gateway(serverUrl: c.server, token: c.token);
  }

  (HubApi, ClipboardSync, AutoPuller) _ensureSubservices() {
    final c = cfg;
    final supportDir = cfgFile.parent.path;
    final h = _hub ??= HubApi(
      gatewayServerUrl: c?.server ?? '',
      token: c?.token ?? '',
    );
    if (c != null) {
      h.base = hubBaseOverride ?? HubApi.deriveOrigin(c.server);
      h.token = c.token;
    } else if (hubBaseOverride != null) {
      h.base = hubBaseOverride!;
    }
    final cs = _clipSync ??= ClipboardSync(
      supportDir: supportDir,
      endpoint: c != null ? _buildClipEndpoint(c) : const ClipEndpointConfig(),
      enabled: c?.clipSync ?? true,
      syncImages: c?.clipImages ?? true,
      onLog: log,
      onCopiedMultipleFiles: (paths) => onCopiedMultipleFiles?.call(paths),
    );
    final ap = _autoPuller ??= AutoPuller(
      hub: h,
      supportDir: supportDir,
      platform: c?.platform ?? AppConfig.platformLabel(),
      deviceId: c?.deviceId ?? '',
      recvDir: c?.recvDir ?? AppConfig.defaultRecvDir(),
      recvDirProvider: () => cfg?.recvDir ?? AppConfig.defaultRecvDir(),
      isKnownHash: cs.isKnownHash,
      lastHubId: initialLegacyHubId,
      legacyPathsOverride:
          Platform.environment.containsKey('FLUTTER_TEST') ? const <String>[] : null,
      onLog: log,
      onReceived: (item, savedPath) {
        final tid = 'hub_${item.id}';
        final peerLabel = item.fromDevice.isNotEmpty ? item.fromDevice : '云端中转';
        final v = TransferView(tid, 'recv', item.sourceDeviceId, peerLabel, item.displayTitle, TransferState.done)
          ..total = item.size
          ..done = item.size
          ..route = 'cloud'
          ..saved = <String>[savedPath]
          ..updated = DateTime.now();
        transfers[tid] = v;
        notifyListeners();
        unawaited(_saveHistory());
        onFilesSaved?.call(v, <String>[savedPath]);
      },
    );
    if (c != null) {
      ap
        ..platform = c.platform
        ..deviceId = c.deviceId
        ..recvDir = c.recvDir;
    }
    return (h, cs, ap);
  }

  void log(String s) {
    final line = '${DateTime.now().toIso8601String().substring(11, 19)} $s';
    logLines.add(line);
    if (logLines.length > 500) logLines.removeAt(0);
    debugPrint(line);
  }

  // ------------------------------------------------------------- lifecycle

  Future<void> register({
    required String server,
    required String name,
    String user = '',
    String pass = '',
    String code = '',
    String? recvDir,
  }) async {
    final key = await DeviceKey.generate();
    final platform = AppConfig.platformLabel();
    final r = await GatewayApi.register(server,
        user: user, pass: pass, code: code, name: name, platform: platform, publicKey: key.publicB64);
    final dir = cfgFile.parent.path;
    cfg = AppConfig(
      server: server.replaceAll(RegExp(r'/+$'), ''),
      deviceId: r['device_id'] as String,
      token: r['token'] as String,
      name: name,
      platform: platform,
      privateKey: key.privateB64,
      recvDir: recvDir ?? AppConfig.defaultRecvDir(),
      stateDir: p.join(dir, 'state'),
    );
    await cfg!.save(cfgFile);
    _ensureSubservices();
    log('registered as ${cfg!.deviceId}');
  }

  Future<void> updateConfig(void Function(AppConfig c) f) async {
    final prev = cfg!;
    final prevClipSync = prev.clipSync;
    final prevClipImages = prev.clipImages;
    final prevEndpoint = _buildClipEndpoint(prev);
    f(prev);
    await prev.save(cfgFile);
    final (h, cs, ap) = _ensureSubservices();
    h.base = hubBaseOverride ?? HubApi.deriveOrigin(prev.server);
    h.token = prev.token;
    ap.recvDir = prev.recvDir;
    cs.setSyncImages(prev.clipImages);
    final nextEndpoint = _buildClipEndpoint(prev);
    if (nextEndpoint.endpointKey != prevEndpoint.endpointKey ||
        nextEndpoint.customPassword != prevEndpoint.customPassword ||
        nextEndpoint.bearerToken != prevEndpoint.bearerToken) {
      await cs.configure(nextEndpoint);
    }
    if (prev.clipSync != prevClipSync && enableBackgroundServices && _running) {
      await cs.setEnabled(prev.clipSync);
    } else if (prev.clipImages != prevClipImages) {
      cs.setSyncImages(prev.clipImages);
    }
    notifyListeners();
  }

  Future<void> configureClipboardEndpoint(ClipEndpointConfig next) async {
    await updateConfig((c) {
      if (next.useCustomServer) {
        c.customClipUrl = next.customServerUrl.trim();
        c.customClipUser = next.customUsername.trim();
        c.customClipPass = next.customPassword;
      } else {
        c.customClipUrl = '';
        c.customClipUser = '';
        c.customClipPass = '';
      }
    });
  }

  /// Platform hook run before the engine starts (e.g. Android storage
  /// permission / fallback receive dir). Set by main.dart.
  static Future<void> Function(Engine e)? beforeStart;

  Future<void> start() async {
    if (_running || !registered) return;
    _running = true;
    await beforeStart?.call(this);
    final c = cfg!;
    _key = await DeviceKey.fromPrivateB64(c.privateKey);
    _api = GatewayApi(c.server, c.token);
    _pool ??= await CryptoPool.start();
    workers = max(4, _pool!.targetSize);
    self = c.deviceId;

    final (_, cs, ap) = _ensureSubservices();
    await cs.configure(_buildClipEndpoint(c));
    cs.setSyncImages(c.clipImages);

    _webrtc?.updateCredentials(gatewayBase: c.server, token: c.token);
    _webrtc ??= WebRtcCoordinator(
      gatewayBase: c.server,
      token: c.token,
      sendSignal: (to, pl) {
        try {
          _signal(to, Signal.webrtc(pl));
        } catch (_) {}
      },
      onLog: log,
    );

    await _startLan();
    if (enableBackgroundServices) {
      _mdns = MdnsDiscovery(
        selfId: self,
        lanPort: _lanServer?.port ?? c.lanPort,
        initialLanUrls: lanUrls,
        onLog: log,
        onPeerDiscovered: _onMdnsPeer,
        onLocalUrlsChanged: (urls) {
          lanUrls = urls;
          _sendHello();
          notifyListeners();
        },
      );
      unawaited(_mdns!.start());
      if (c.clipSync) {
        unawaited(cs.start());
      }
      ap.start();
    }

    unawaited(_connLoop());
    _ensureTicker();
  }

  Future<void> stop() async {
    _running = false;
    final kick = _reconnectKick;
    if (kick != null && !kick.isCompleted) {
      kick.complete();
    }
    _failPendingWaiters(const SocketException('engine stopped'));
    _ticker?.cancel();
    _ticker = null;
    _nextTryTimer?.cancel();
    _nextTryTimer = null;
    await _mdns?.stop();
    _mdns = null;
    _autoPuller?.stop();
    await _clipSync?.stop();
    await _webrtc?.closeAll();
    _webrtc = null;
    for (final po in pendingOffers.values) {
      po.decide(false);
    }
    pendingOffers.clear();
    await _ws?.close();
    await _lanServer?.close(force: true);
    for (final t in _activeOut.values) {
      t.cancel('stopped');
    }
    for (final s in _incoming.values) {
      s.$1.cancel('stopped');
    }
    _api?.close();
    _hub?.close();
    _hub = null;
    _autoPuller = null;
  }

  Future<void> signOut() async {
    try {
      await _api?.deleteDevice(self);
    } catch (_) {}
    await stop();
    await SecureStore.clearAll();
    if (await cfgFile.exists()) await cfgFile.delete();
    cfg = null;
    devices.clear();
    notifyListeners();
  }

  void _onMdnsPeer(String peerId, List<String> discoveredUrls) {
    if (peerId.isEmpty || peerId == self) return;
    final merged = <String>[
      ...discoveredUrls,
      ...?_mdnsPeerUrls[peerId],
    ];
    final dedup = <String>[];
    for (final u in merged) {
      if (!dedup.contains(u)) dedup.add(u);
    }
    _mdnsPeerUrls[peerId] = dedup.take(8).toList();
    final existing = devices[peerId];
    if (existing != null) {
      final combined = <String>[...dedup, ...existing.lan];
      final unique = <String>[];
      for (final u in combined) {
        if (!unique.contains(u)) unique.add(u);
      }
      if (unique.length != existing.lan.length || !unique.every(existing.lan.contains)) {
        devices[peerId] = existing.copyWith(online: true, lan: unique.take(8).toList());
        notifyListeners();
      }
    }
  }

  List<String> _candidateLanUrls(DeviceInfo dev) {
    final out = <String>[];
    for (final u in <String>[...?_mdnsPeerUrls[dev.id], ...dev.lan]) {
      if (!out.contains(u)) out.add(u);
    }
    return out;
  }

  bool isSystemSleeping = false;
  bool _outboxDirty = true;
  Timer? _nextTryTimer;

  void onSystemSleep() {
    isSystemSleeping = true;
    _ticker?.cancel();
    _ticker = null;
    _nextTryTimer?.cancel();
    _nextTryTimer = null;
    _pool?.closeWorkers();
    unawaited(flushState());
    try {
      _ws?.close(1000, 'system sleep');
    } catch (_) {}
  }

  void onSystemWake() {
    isSystemSleeping = false;
    _outboxDirty = true;
    _ensureTicker();
    kickReconnect(force: true);
    mdns?.announceNow();
    autoPuller.kick();
    unawaited(clipSync.kick());
    unawaited(clipSync.pollLocalOnce());
  }

  Future<void> flushState() async {
    try {
      await _saveHistory();
    } catch (_) {}
  }

  void _ensureTicker() {
    if (_ticker != null || isSystemSleeping || !_running) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  bool _hasPendingRetries() => _nextTry.values.any((dt) => DateTime.now().isBefore(dt));

  void _scheduleNextTryTimer() {
    _nextTryTimer?.cancel();
    _nextTryTimer = null;
    if (_nextTry.isEmpty) return;
    DateTime? earliest;
    for (final dt in _nextTry.values) {
      if (earliest == null || dt.isBefore(earliest)) earliest = dt;
    }
    if (earliest != null) {
      final delay = earliest.difference(DateTime.now());
      final d = delay.isNegative ? Duration.zero : delay;
      _nextTryTimer = Timer(d + const Duration(milliseconds: 50), () {
        _outboxDirty = true;
        _ensureTicker();
        unawaited(_schedule());
      });
    }
  }

  void kickSchedule() {
    _nextTry.clear();
    _outboxDirty = true;
    _ensureTicker();
    _schedule();
  }

  int _tickCount = 0;
  void _tick() {
    var changed = false;
    var hasActive = false;
    for (final t in transfers.values) {
      if (t.state == TransferState.active) {
        hasActive = true;
        t.speed = max(0, (t.done - t._lastDone).toDouble());
        t._lastDone = t.done;
        changed = true;
      }
    }
    if (++_tickCount % 3 == 0) {
      if (_outboxDirty || hasActive || _hasPendingRetries()) {
        _schedule();
      }
    }
    if (!hasActive && !_outboxDirty && !_hasPendingRetries() && _activeOut.isEmpty && _incoming.isEmpty) {
      _ticker?.cancel();
      _ticker = null;
    }
    if (changed) notifyListeners();
  }

  // ------------------------------------------------------------ websocket

  Future<void> _connLoop() async {
    if (_connLoopRunning) return;
    _connLoopRunning = true;
    var back = 1.0;
    try {
      while (_running) {
        if (_backoffReset) {
          back = 1.0;
          _backoffReset = false;
        }
        try {
          status = '连接中…';
          notifyListeners();
          final ws = await WebSocket.connect(api.wsUri().toString(), headers: {'authorization': 'Bearer ${cfg!.token}'})
              .timeout(const Duration(seconds: 20));
          ws.pingInterval = const Duration(seconds: 25);
          _ws = ws;
          connected = true;
          status = '已连接';
          back = 1.0;
          log('connected to gateway');
          _sendHello();
          notifyListeners();
          await for (final msg in ws) {
            if (msg is String) _dispatch(jsonDecode(msg) as Map<String, dynamic>);
          }
          if (ws.closeCode == 4401 || ws.closeCode == 1008) status = '设备已被吊销';
        } catch (e) {
          if (e is WebSocketException && e.message.contains('401')) {
            status = '设备令牌无效（可能已被吊销），请重新登录';
          } else {
            status = '连接失败：$e';
          }
          log('gateway: $e');
        }
        _ws = null;
        connected = false;
        _failPendingWaiters(const SocketException('connection dropped'));
        notifyListeners();
        if (!_running) return;

        final kick = Completer<void>();
        _reconnectKick = kick;
        try {
          final delayMs = (back * 1000).round();
          await Future.any<void>([
            Future<void>.delayed(Duration(milliseconds: delayMs)),
            kick.future,
          ]);
        } finally {
          _reconnectKick = null;
        }
        if (!_running) return;
        back = min(30.0, (back * 1.5) + _rand.nextDouble());
      }
    } finally {
      _connLoopRunning = false;
    }
  }

  /// Immediately wakes up connection loop from backoff delay and attempts reconnect.
  /// Safe to call concurrently from network listeners and sleep/wake events.
  void kickReconnect({bool force = false}) {
    if (!_running) return;
    _backoffReset = true;
    final kick = _reconnectKick;
    if (kick != null && !kick.isCompleted) {
      kick.complete();
      return;
    }
    if (!_connLoopRunning) {
      unawaited(_connLoop());
      return;
    }
    if (force && _ws != null) {
      try {
        _ws?.close();
      } catch (_) {}
    }
  }

  void _sendRaw(Map<String, dynamic> env) {
    final ws = _ws;
    if (ws == null) throw StateError('not connected to gateway');
    ws.add(jsonEncode(env));
  }

  void _sendHello() {
    if (lanUrls.isEmpty) return;
    try {
      _sendRaw({
        'type': 'hello',
        'payload': {'lan': lanUrls}
      });
    } catch (_) {}
  }

  void _signal(String to, Signal s) => _sendRaw({'type': 'signal', 'to': to, 'id': _token(6), 'payload': s.toJson()});

  void _dispatch(Map<String, dynamic> env) {
    switch (env['type']) {
      case 'devices':
        devices.clear();
        for (final d in (env['payload'] as List? ?? [])) {
          var di = DeviceInfo.fromJson(d as Map<String, dynamic>);
          final extraLan = _mdnsPeerUrls[di.id];
          if (extraLan != null && extraLan.isNotEmpty && di.online) {
            final merged = <String>[...extraLan, ...di.lan];
            final unique = <String>[];
            for (final u in merged) {
              if (!unique.contains(u)) unique.add(u);
            }
            di = di.copyWith(lan: unique.take(8).toList());
          }
          devices[di.id] = di;
        }
        notifyListeners();
        _schedule();
      case 'presence':
        final pl = env['payload'] as Map<String, dynamic>;
        final id = pl['device_id'] as String;
        final online = pl['online'] as bool;
        if (!online) _mdnsPeerUrls.remove(id);
        final d = devices[id];
        if (d != null) devices[id] = d.copyWith(online: online);
        if (online) {
          _nextTry.removeWhere((tid, _) => _outPeer[tid] == id);
          _backoff.removeWhere((tid, _) => _outPeer[tid] == id);
          _schedule();
        } else {
          _activeOut.forEach((tid, tok) {
            if (_outPeer[tid] == id) tok.cancel('peer went offline');
          });
          for (final s in _incoming.values) {
            if (s.$3 == id) s.$1.cancel('peer went offline');
          }
        }
        notifyListeners();
      case 'signal':
        final from = env['from'] as String? ?? '';
        final sig = Signal.fromJson(env['payload'] as Map<String, dynamic>);
        _onSignal(from, sig);
      case 'error':
        final pl = env['payload'] as Map<String, dynamic>? ?? {};
        if (pl['code'] != 'offline') log('gateway error: ${pl['code']} ${pl['message'] ?? ''}');
    }
  }

  void _onSignal(String from, Signal sig) {
    switch (sig.kind) {
      case 'offer':
        if (sig.offer != null) unawaited(_handleOffer(from, sig.offer!));
      case 'answer':
        if (sig.answer != null) _deliver('answer:${sig.answer!.transferId}:${sig.answer!.session}', sig);
      case 'done':
        if (sig.done != null) _deliver('done:${sig.done!.transferId}:${sig.done!.session}', sig);
      case 'cancel':
        if (sig.cancel != null) _onCancel(from, sig.cancel!);
      case 'webrtc':
        if (sig.webrtc != null) unawaited(_webrtc?.onSignal(from, sig.webrtc!));
    }
  }

  void _deliver(String key, Signal s) {
    final c = _waiters.remove(key);
    if (c != null && !c.isCompleted) c.complete(s);
  }

  Completer<Signal> _waitFor(String key) => _waiters[key] = Completer<Signal>();

  void _failPendingWaiters([Object? error]) {
    final err = error ?? const SocketException('connection dropped');
    final pending = Map<String, Completer<Signal>>.from(_waiters);
    _waiters.clear();
    for (final c in pending.values) {
      if (!c.isCompleted) {
        c.completeError(err);
      }
    }
  }

  String _token(int n) {
    final b = List<int>.generate(n, (_) => _rand.nextInt(256));
    return base64Url.encode(b).replaceAll('=', '');
  }

  void respondOffer(String transferId, bool accept) {
    final po = pendingOffers.remove(transferId);
    if (po != null) {
      po.decide(accept);
      notifyListeners();
    }
  }

  // --------------------------------------------------------------- outbox

  final _outPeer = <String, String>{};

  Future<String> sendPaths(String deviceId, List<String> paths, {bool star = false, bool pin = false}) async {
    final tid = 't${_token(15).replaceAll('-', 'x')}';
    final isCloudTarget = deviceId == kCloudTargetId;
    final dev = isCloudTarget ? null : devices[deviceId];
    final peerLabel = isCloudTarget ? '云端收藏' : (dev?.name ?? deviceId);
    final title = paths.length == 1 ? p.basename(paths.first) : '${p.basename(paths.first)} 等 ${paths.length} 项';
    final view = TransferView(tid, 'send', deviceId, peerLabel, title, TransferState.hashing)
      ..sourcePaths = List<String>.from(paths);
    transfers[tid] = view;
    notifyListeners();
    try {
      _pool ??= await CryptoPool.start();
      final (files, dirs) = await buildManifest(paths, _pool!, onProgress: (d, t) {
        view.total = t;
        view.done = d;
        notifyListeners();
      });
      if (files.isEmpty && dirs.isEmpty) throw const FileSystemException('nothing to send');

      final shouldCloudDeliver = isCloudTarget ||
          (dev != null && !dev.online && (cfg?.offlineFallback ?? true) && files.isNotEmpty && dirs.isEmpty);

      if (shouldCloudDeliver) {
        view
          ..total = files.fold<int>(0, (a, f) => a + f.entry.size)
          ..done = 0
          .._lastDone = 0
          ..route = 'cloud'
          ..state = TransferState.active;
        notifyListeners();
        final tok = _Token();
        _activeOut[tid] = tok;
        unawaited(_runCloudUpload(
          tid: tid,
          deviceId: deviceId,
          title: title,
          files: files,
          dirs: dirs,
          view: view,
          tok: tok,
          star: star || isCloudTarget,
          pin: pin,
        ));
        return tid;
      }

      final e = OutEntry(tid, deviceId, title, kDefaultChunkSize, files, dirs, DateTime.now());
      final f = File(p.join(cfg!.outboxDir, '$tid.json'));
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(e.toJson()));
      view
        ..total = e.total
        ..done = 0
        ..state = (dev?.online ?? false) ? TransferState.queued : TransferState.waiting;
      notifyListeners();
      _outboxDirty = true;
      _ensureTicker();
      _schedule();
    } catch (err) {
      _finish(view, ok: false, error: '$err');
    }
    return tid;
  }

  Future<void> _runCloudUpload({
    required String tid,
    required String deviceId,
    required String title,
    required List<LocalFile> files,
    required List<String> dirs,
    required TransferView view,
    required _Token tok,
    required bool star,
    required bool pin,
  }) async {
    final isExplicitCloud = deviceId == kCloudTargetId;
    try {
      var completedBytes = 0;
      final savedIds = <String>[];
      for (final lf in files) {
        tok.check();
        final item = await hub.uploadFile(
          File(lf.abs),
          filename: p.basename(lf.abs),
          from: cfg?.name ?? '',
          fromId: self,
          to: isExplicitCloud ? '' : deviceId,
          starred: star,
          pinned: pin,
          onProgress: (sent, _) {
            view.done = completedBytes + sent;
          },
        );
        completedBytes += lf.entry.size;
        view.done = completedBytes;
        savedIds.add(lf.abs);
        log('[cloud $tid] uploaded #${item.id} (${item.filename}) -> ${isExplicitCloud ? "hub" : deviceId}');
      }
      _finish(view, ok: true, saved: savedIds);
    } catch (err) {
      if (tok.isCancelled) {
        if (_pausedIds.contains(tid)) {
          view
            ..state = TransferState.paused
            ..speed = 0
            ..error = '已手动暂停';
          notifyListeners();
          return;
        }
        return;
      }
      if (!isExplicitCloud && cfg != null) {
        // Fallback cleanly to outbox P2P/Relay queue if SyncHub /api/hub/upload is unavailable.
        log('[cloud $tid] cloud offline upload failed ($err), queuing for P2P delivery when peer is online');
        final e = OutEntry(tid, deviceId, title, kDefaultChunkSize, files, dirs, DateTime.now());
        final f = File(p.join(cfg!.outboxDir, '$tid.json'));
        await f.parent.create(recursive: true);
        await f.writeAsString(jsonEncode(e.toJson()));
        view
          ..done = 0
          .._lastDone = 0
          ..speed = 0
          ..route = ''
          ..error = ''
          ..state = TransferState.waiting;
        notifyListeners();
        _schedule();
      } else {
        _finish(view, ok: false, error: '$err');
      }
    } finally {
      _activeOut.remove(tid);
    }
  }

  Future<List<OutEntry>> _loadOutbox() async {
    final d = Directory(cfg!.outboxDir);
    if (!await d.exists()) return [];
    final out = <OutEntry>[];
    await for (final f in d.list()) {
      if (f is File && f.path.endsWith('.json')) {
        try {
          out.add(OutEntry.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>));
        } catch (_) {}
      }
    }
    return out;
  }

  Future<void> _removeOutbox(String tid) async {
    final f = File(p.join(cfg!.outboxDir, '$tid.json'));
    if (await f.exists()) await f.delete();
  }

  bool _scheduling = false;
  Future<void> _schedule() async {
    if (!_running || !connected || _scheduling) return;
    _scheduling = true;
    try {
      final outboxEntries = await _loadOutbox();
      _outboxDirty = outboxEntries.isNotEmpty;
      for (final e in outboxEntries) {
        final tid = e.transferId;
        _outPeer[tid] = e.to;
        final view = transfers.putIfAbsent(
            tid,
            () => TransferView(tid, 'send', e.to, devices[e.to]?.name ?? e.to, e.title, TransferState.queued)
              ..total = e.total
              ..sourcePaths = e.files.map((f) => f.abs).toList());
        if (_pausedIds.contains(tid)) {
          view.state = TransferState.paused;
          continue;
        }
        if (_activeOut.containsKey(tid)) continue;
        final next = _nextTry[tid];
        if (next != null && DateTime.now().isBefore(next)) continue;
        final dev = devices[e.to];
        if (dev != null && !dev.online) {
          view.state = TransferState.waiting;
          continue;
        }
        final tok = _Token();
        _activeOut[tid] = tok;
        unawaited(() async {
          Object? err;
          try {
            await _runOutgoing(e, tok, view);
          } catch (x) {
            err = x;
          }
          _activeOut.remove(tid);
          if (_pausedIds.contains(tid)) {
            view
              ..state = TransferState.paused
              ..speed = 0
              ..error = '已手动暂停';
            notifyListeners();
            return;
          }
          if (err != null) {
            final prevBack = _backoff[tid];
            final b = prevBack == 0 ? 0 : min((prevBack ?? 1) * 2, 60);
            _backoff[tid] = b == 0 ? 1 : b;
            _nextTry[tid] = DateTime.now().add(b == 0 ? const Duration(milliseconds: 150) : Duration(seconds: b));
            if (!view.finished) {
              view
                ..state = TransferState.waiting
                ..error = '$err';
            }
            log('[send $tid] session ended: $err (retry in ${b}s)');
            if (b == 0) {
              Future<void>.delayed(const Duration(milliseconds: 160), _schedule);
            }
          } else {
            _backoff.remove(tid);
            _nextTry.remove(tid);
          }
          notifyListeners();
        }());
      }
    } finally {
      _scheduling = false;
      _scheduleNextTryTimer();
    }
  }

  Future<void> pauseTransfer(String tid) async {
    final v = transfers[tid];
    if (v == null || v.finished) return;
    _pausedIds.add(tid);
    if (v.direction == 'send') {
      _activeOut[tid]?.cancel('paused');
    } else {
      _incoming[tid]?.$1.cancel('paused');
    }
    v
      ..state = TransferState.paused
      ..speed = 0
      ..error = '已手动暂停';
    notifyListeners();
  }

  Future<void> resumeTransfer(String tid) async {
    final v = transfers[tid];
    if (v == null || v.finished) return;
    _pausedIds.remove(tid);
    _nextTry.remove(tid);
    _backoff.remove(tid);
    if (v.route == 'cloud' && v.direction == 'send' && v.sourcePaths.isNotEmpty) {
      transfers.remove(tid);
      await sendPaths(v.peerId, v.sourcePaths, star: v.peerId == kCloudTargetId);
      return;
    }
    v
      ..state = v.direction == 'send' ? TransferState.queued : TransferState.waiting
      ..error = '';
    notifyListeners();
    _outboxDirty = true;
    _ensureTicker();
    _schedule();
  }

  Future<String?> retryOrResend(String tid) async {
    final v = transfers[tid];
    if (v == null) return null;
    _pausedIds.remove(tid);
    if (!v.finished && v.direction == 'send') {
      _nextTry.remove(tid);
      _backoff.remove(tid);
      _bad.removeWhere((k, _) => k.startsWith('$tid|'));
      v
        ..state = TransferState.queued
        ..error = '';
      notifyListeners();
      _outboxDirty = true;
      _ensureTicker();
      _schedule();
      return tid;
    }
    if (v.sourcePaths.isNotEmpty) {
      return sendPaths(v.peerId, v.sourcePaths, star: v.peerId == kCloudTargetId);
    }
    return null;
  }

  Future<void> cancelTransfer(String tid) async {
    _pausedIds.remove(tid);
    _acceptedTransfers.remove(tid);
    final po = pendingOffers.remove(tid);
    po?.decide(false);
    for (final entry in _waiters.entries.toList()) {
      if (entry.key.startsWith('answer:$tid:') || entry.key.startsWith('done:$tid:')) {
        _waiters.remove(entry.key);
        if (!entry.value.isCompleted) {
          entry.value.completeError(StateError('transfer cancelled'));
        }
      }
    }
    final v = transfers[tid];
    if (v == null) return;
    if (v.direction == 'send') {
      _activeOut[tid]?.cancel('cancelled');
      await _removeOutbox(tid);
      final peer = _outPeer[tid];
      if (peer != null && peer != kCloudTargetId) {
        try {
          _signal(peer, Signal.cancel(Cancel(tid, 'user')));
        } catch (_) {}
      }
    } else {
      final s = _incoming[tid];
      if (s != null) {
        s.$1.cancel('cancelled');
        try {
          _signal(s.$3, Signal.cancel(Cancel(tid, 'user')));
        } catch (_) {}
      }
      final d = Directory(p.join(cfg!.partialDir, tid));
      if (await d.exists()) await d.delete(recursive: true);
    }
    _finish(v, ok: false, error: '已取消');
  }

  void _onCancel(String from, Cancel c) {
    _pausedIds.remove(c.transferId);
    final po = pendingOffers.remove(c.transferId);
    po?.decide(false);
    final s = _incoming[c.transferId];
    if (s != null && s.$3 == from) {
      s.$1.cancel('cancelled by sender');
      unawaited(Directory(p.join(cfg!.partialDir, c.transferId)).delete(recursive: true).catchError((_) => Directory('')));
      final v = transfers[c.transferId];
      if (v != null) _finish(v, ok: false, error: '对方已取消');
    }
    if (_outPeer[c.transferId] == from) {
      _activeOut[c.transferId]?.cancel('cancelled by receiver');
      unawaited(_removeOutbox(c.transferId));
      final v = transfers[c.transferId];
      if (v != null) _finish(v, ok: false, error: '对方已取消');
    }
  }

  // --------------------------------------------------------------- sender

  bool _isBad(String tid, String id) => DateTime.now().isBefore(_bad['$tid|$id'] ?? DateTime(0));
  void _markBad(String tid, String id) => _bad['$tid|$id'] = DateTime.now().add(const Duration(seconds: 15));

  @visibleForTesting
  void markBadForTest(String tid, String id) => _markBad(tid, id);

  @visibleForTesting
  bool isBadForTest(String tid, String id) => _isBad(tid, id);

  Future<RelayConn> _pickRelay(String tid, RelayGrant g) async {
    if (g.relays.isEmpty) throw StateError('gateway advertised no relays');
    final results = await Future.wait(g.relays.map((info) async {
      final rc = api.relay(info, g.ticket);
      try {
        await rc.ping();
        return (rc, await rc.ping()); // warm round trip
      } catch (e) {
        log('[send $tid] relay ${info.id} unreachable: $e');
        return (rc, null);
      }
    }));
    RelayConn? best;
    RelayConn? fallback;
    Duration? bestRtt;
    for (final (rc, rtt) in results) {
      if (rtt == null) continue;
      log('[send $tid] relay ${rc.id} rtt ${rtt.inMilliseconds}ms');
      if (_isBad(tid, rc.id)) {
        fallback = rc;
        continue;
      }
      if (bestRtt == null || rtt < bestRtt) {
        best = rc;
        bestRtt = rtt;
      }
    }
    final r = best ?? fallback;
    if (r == null) throw StateError('no relay reachable');
    return r;
  }

  Future<void> _runOutgoing(OutEntry e, _Token tok, TransferView view) async {
    final tid = e.transferId;
    var dev = devices[e.to];
    if (dev == null) {
      final (_, list) = await api.devices();
      for (final d in list) {
        devices[d.id] = d;
      }
      dev = devices[e.to];
      if (dev == null) {
        await _removeOutbox(tid);
        _finish(view, ok: false, error: '接收设备已不存在');
        return;
      }
    }
    for (final f in e.files) {
      final st = await File(f.abs).stat();
      if (st.type == FileSystemEntityType.notFound || st.size != f.entry.size || st.modified.millisecondsSinceEpoch != f.entry.mtime) {
        await _removeOutbox(tid);
        _finish(view, ok: false, error: '源文件已改动或不存在：${f.entry.path}');
        return;
      }
    }
    view.state = TransferState.connecting;
    notifyListeners();

    ChunkPusher? pusher;
    RelayConn? preOpenedRelay;
    var relayId = '';
    var route = 'relay';
    final lanCandidates = _candidateLanUrls(dev);
    if (!_isBad(tid, 'lan') && lanCandidates.isNotEmpty) {
      pusher = await LanConn.probe(dev, lanCandidates);
      if (pusher != null) route = 'lan';
    }
    if (pusher == null) {
      final grant = await api.openRelay(tid, e.to);
      final rc = await _pickRelay(tid, grant);
      preOpenedRelay = rc;
      pusher = rc;
      relayId = rc.id;
      if (!_isBad(tid, 'webrtc') && _webrtc != null && await _webrtc!.isSupported()) {
        route = 'webrtc';
      }
    }
    tok.check();
    final session = _token(9);
    final (eph, cipher) = await SessionCipher.sender(_key!, dev.publicKey, tid, session);
    final ansC = _waitFor('answer:$tid:$session');
    final doneC = _waitFor('done:$tid:$session');
    final offer = Offer(
      transferId: tid,
      session: session,
      title: e.title,
      chunkSize: e.chunkSize,
      totalSize: e.total,
      files: e.files.map((f) => f.entry).toList(),
      dirs: e.dirs,
      ephemeralKey: eph,
      routes: const ['lan', 'webrtc', 'relay'],
      relay: relayId,
      route: route,
      createdAt: e.createdAt,
    );
    try {
      _signal(e.to, Signal.offer(offer));
      final ans = (await Future.any<Signal>([ansC.future, tok.whenCancelled.then<Signal>((_) => throw _Cancelled(tok.reason))])
              .timeout(const Duration(seconds: 60), onTimeout: () => throw TimeoutException('no answer from receiver')))
          .answer!;
      if (!ans.accept) {
        if (ans.reason == 'declined' || ans.reason == 'invalid') {
          await _removeOutbox(tid);
          _finish(view, ok: false, error: '对方${ans.reason == 'declined' ? '拒绝了' : '认为无效'}');
          return;
        }
        throw StateError('receiver busy: ${ans.reason}');
      }

      if (ans.route == 'webrtc' && _webrtc != null) {
        final rtcPusher = await _webrtc!.connectSender(
          peerId: e.to,
          transferId: tid,
          session: session,
          connectTimeout: const Duration(seconds: 12),
        );
        if (rtcPusher == null) {
          _markBad(tid, 'webrtc');
          log('[send $tid] WebRTC connect timed out (12s); seamlessly continuing via pre-opened relay');
          if (preOpenedRelay != null) {
            pusher = preOpenedRelay;
            route = 'relay';
          } else {
            _backoff[tid] = 0;
            throw StateError('WebRTC 直连超时且无可用中继');
          }
        } else {
          pusher = rtcPusher;
          route = 'webrtc';
        }
      } else if (route == 'webrtc' && preOpenedRelay != null) {
        // Receiver (e.g. Go hubctl) chose the pre-opened relay directly.
        pusher = preOpenedRelay;
        route = 'relay';
      }

      // expand need
      final chunks = <(int, int)>[];
      var needBytes = 0;
      for (final n in ans.need) {
        if (n.file < 0 || n.file >= e.files.length) throw StateError('bad need');
        final cc = chunkCount(e.files[n.file].entry.size, e.chunkSize);
        if (n.from < 0 || n.to > cc || n.from >= n.to) throw StateError('bad need range');
        for (var c = n.from; c < n.to; c++) {
          chunks.add((n.file, c));
          needBytes += chunkLen(e.files[n.file].entry.size, e.chunkSize, c);
        }
      }
      view
        ..state = TransferState.active
        ..route = pusher.name
        ..total = e.total
        ..done = e.total - needBytes
        .._lastDone = e.total - needBytes
        ..error = '';
      notifyListeners();
      log('[send $tid] → ${dev.name}: ${chunks.length} chunks via ${pusher.name}, resuming at ${(100 * view.fraction).toStringAsFixed(1)}%');

      Done? early;
      unawaited(doneC.future.then((s) {
        early = s.done;
        if (!s.done!.ok) tok.cancel('receiver: ${s.done!.reason}');
      }, onError: (err) {
        tok.cancel('connection dropped: $err');
      }));
      try {
        await _push(pusher, e, cipher, session, chunks, tok, view);
      } catch (err) {
        if (early == null && !_pausedIds.contains(tid)) {
          _markBad(tid, route == 'lan' ? 'lan' : (route == 'webrtc' ? 'webrtc' : relayId));
          rethrow;
        }
        if (_pausedIds.contains(tid)) rethrow;
      }
      final done = early ??
          (await doneC.future.timeout(const Duration(minutes: 10), onTimeout: () => throw TimeoutException('no confirmation')))
              .done!;
      if (!done.ok) throw StateError('receiver reported: ${done.reason}');
      await _removeOutbox(tid);
      _finish(view, ok: true, saved: done.saved);
    } finally {
      _waiters.remove('answer:$tid:$session');
      _waiters.remove('done:$tid:$session');
      await _webrtc?.closeSession(tid, session);
    }
  }

  Future<void> _push(ChunkPusher pusher, OutEntry e, SessionCipher cipher, String session, List<(int, int)> chunks, _Token tok,
      TransferView view) async {
    var next = 0;
    Object? failure;
    Future<void> worker() async {
      final open = <int, RandomAccessFile>{};
      try {
        while (failure == null && !tok.isCancelled) {
          if (next >= chunks.length) return;
          final (fi, ci) = chunks[next++];
          final lf = e.files[fi];
          final raf = open[fi] ??= await File(lf.abs).open();
          final n = chunkLen(lf.entry.size, e.chunkSize, ci);
          await raf.setPosition(ci * e.chunkSize);
          final plain = await raf.read(n);
          if (plain.length != n) throw const FileSystemException('short read');
          final sealed = await _pool!.seal(cipher, fi, ci, plain);
          await _putWithRetry(pusher, e.transferId, session, fi, ci, sealed, tok);
          view.done += n;
        }
      } catch (err) {
        failure ??= err;
      } finally {
        for (final r in open.values) {
          await r.close();
        }
      }
    }

    await Future.wait(List.generate(workers, (_) => worker()));
    if (failure != null) throw failure!;
    tok.check();
  }

  Future<void> _putWithRetry(ChunkPusher pusher, String tid, String session, int f, int c, Uint8List data, _Token tok) async {
    var timeouts = 0, fails = 0;
    while (true) {
      tok.check();
      try {
        await pusher.put(tid, session, f, c, data);
        return;
      } catch (err) {
        tok.check();
        if (isStatus(err, 504)) {
          if (++timeouts > 8) rethrow;
          continue;
        }
        if (err is ApiException && const {400, 401, 403, 404, 409, 500}.contains(err.status)) rethrow;
        if (++fails > 6) rethrow;
        await Future.delayed(Duration(seconds: min(fails * fails, 10)));
      }
    }
  }

  // ------------------------------------------------------------- receiver

  Future<void> _handleOffer(String from, Offer o) async {
    void reject(String reason) {
      try {
        _signal(from, Signal.answer(Answer(transferId: o.transferId, session: o.session, accept: false, reason: reason)));
      } catch (_) {}
    }

    if (_pausedIds.contains(o.transferId)) {
      return reject('busy');
    }

    final problem = _validateOffer(o);
    if (problem != null) {
      log('[recv] invalid offer from $from: $problem');
      return reject('invalid');
    }
    var dev = devices[from];
    if (dev == null) {
      try {
        final (_, list) = await api.devices();
        for (final d in list) {
          devices[d.id] = d;
        }
      } catch (_) {}
      dev = devices[from];
    }
    if (dev == null) return reject('invalid');
    final SessionCipher cipher;
    try {
      cipher = await SessionCipher.receiver(_key!, o.ephemeralKey, dev.publicKey, o.transferId, o.session);
    } catch (_) {
      return reject('invalid');
    }

    // supersede a running session of the same transfer
    final prev = _incoming[o.transferId];
    final tok = _Token();
    final finished = Completer<void>();
    _incoming[o.transferId] = (tok, finished.future, from);
    if (prev != null) {
      prev.$1.cancel('superseded');
      await prev.$2;
    }

    _Sink? sink;
    try {
      // B8: Prompt for confirmation when autoAccept is disabled (unless resuming an already-accepted transfer).
      final alreadyAccepted = _acceptedTransfers.contains(o.transferId) ||
          await File(p.join(cfg!.partialDir, o.transferId, 'state.json')).exists();
      if (!alreadyAccepted && !(cfg?.autoAccept ?? true)) {
        final po = PendingOffer(
          transferId: o.transferId,
          session: o.session,
          fromId: from,
          fromName: dev.name,
          title: o.title,
          totalSize: o.totalSize,
          fileCount: o.files.length,
        );
        pendingOffers[o.transferId] = po;
        onIncomingOfferPrompt?.call(po);
        notifyListeners();
        final accepted = await Future.any<bool>([
          po.decision,
          tok.whenCancelled.then((_) => false),
        ]).timeout(const Duration(seconds: 55), onTimeout: () => false);
        pendingOffers.remove(o.transferId);
        notifyListeners();
        if (!accepted) {
          if (!tok.isCancelled) {
            log('[recv ${o.transferId}] declined incoming offer "${o.title}" from ${dev.name}');
            reject('declined');
          }
          return;
        }
      }
      _acceptedTransfers.add(o.transferId);

      final view = transfers.putIfAbsent(
          o.transferId, () => TransferView(o.transferId, 'recv', from, dev!.name, o.title, TransferState.connecting));
      final st = await _RecvState.loadOrInit(cfg!.partialDir, o, from, ManifestDigest.of(o));
      final (need, needBytes) = st.need();
      sink = _Sink(this, st, cipher, o.session, need, view, tok);
      _sinks['${o.transferId}|${o.session}'] = sink;

      var route = 'lan';
      RelayConn? rc;
      if (o.route == 'lan') {
        if (_lanServer == null) return reject('busy');
        route = 'lan';
      } else {
        WebRtcReceiverSession? rtcRecv;
        if (o.route == 'webrtc' && _webrtc != null) {
          rtcRecv = await _webrtc!.registerReceiver(
            peerId: from,
            transferId: o.transferId,
            session: o.session,
            onChunk: (f, c, sealed) async {
              try {
                await sink!.accept(f, c, sealed);
              } on _Unexpected {
                // duplicate frame delivery is benign
              }
            },
          );
        }
        if (rtcRecv != null) {
          route = 'webrtc';
        }
        // Always prepare relay fallback if sender provided a relay candidate
        if (o.relay.isNotEmpty) {
          try {
            final grant = await api.relayTicket(o.transferId);
            for (final info in grant.relays) {
              if (info.id == o.relay || (o.relay.isEmpty && rc == null)) {
                rc = api.relay(info, grant.ticket);
              }
            }
          } catch (_) {}
        }
        if (rtcRecv == null) {
          if (rc == null) return reject('busy');
          route = rc.name;
        }
      }

      view
        ..title = o.title
        ..peer = dev.name
        ..total = o.totalSize
        ..done = o.totalSize - needBytes
        .._lastDone = o.totalSize - needBytes
        ..route = route
        ..state = TransferState.active
        ..error = '';
      notifyListeners();
      _signal(from, Signal.answer(Answer(transferId: o.transferId, session: o.session, accept: true, route: route, need: need)));
      log('[recv ${o.transferId}] ← ${dev.name}: "${o.title}" ${humanBytes(o.totalSize)}, need ${humanBytes(needBytes)} via $route');
      if (rc != null) {
        final activeSink = sink;
        if (route == 'webrtc') {
          // If WebRTC was negotiated, schedule relay fetch fallback if WebRTC does not deliver
          unawaited(Future.delayed(const Duration(seconds: 12), () {
            if (!activeSink.isComplete && !tok.isCancelled) {
              _fetchFromRelay(activeSink, rc!);
            }
          }));
        } else {
          unawaited(_fetchFromRelay(activeSink, rc));
        }
      }
      await sink.wait();
      await st.save();
      final saved = await st.finalizeAll(cfg!.recvDir);
      _signal(from, Signal.done(Done(transferId: o.transferId, session: o.session, ok: true, saved: saved)));
      await Directory(st.dir).delete(recursive: true);
      _acceptedTransfers.remove(o.transferId);
      log('[recv ${o.transferId}] complete: ${saved.length} item(s)');
      _finish(view, ok: true, saved: saved);
      onFilesSaved?.call(view, saved);
    } catch (err) {
      final view = transfers[o.transferId];
      if (!tok.isCancelled) {
        log('[recv ${o.transferId}] session failed: $err');
        try {
          _signal(from, Signal.done(Done(transferId: o.transferId, session: o.session, ok: false, reason: '$err')));
        } catch (_) {}
        if (view != null && !view.finished) {
          view
            ..state = TransferState.waiting
            ..error = '$err';
        }
      } else if (view != null && !view.finished) {
        view.state = _pausedIds.contains(o.transferId) ? TransferState.paused : TransferState.waiting;
      }
      notifyListeners();
    } finally {
      await _webrtc?.closeSession(o.transferId, o.session);
      if (sink != null) {
        _sinks.remove('${o.transferId}|${o.session}');
        await sink.close();
      }
      if (identical(_incoming[o.transferId]?.$1, tok)) _incoming.remove(o.transferId);
      finished.complete();
    }
  }

  String? _validateOffer(Offer o) {
    final idOk = RegExp(r'^[A-Za-z0-9_-]{8,64}$');
    if (!idOk.hasMatch(o.transferId) || o.session.isEmpty || o.session.length > 64) return 'bad ids';
    if (o.chunkSize < 64 << 10 || o.chunkSize > kMaxChunkSize) return 'bad chunk size';
    if (o.files.length > 200000) return 'too many files';
    var total = 0;
    final seen = <String>{};
    for (var i = 0; i < o.files.length; i++) {
      final f = o.files[i];
      if (f.index != i || f.size < 0 || !RegExp(r'^[0-9a-f]{64}$').hasMatch(f.sha256)) return 'bad file entry';
      try {
        sanitizeRelPath(f.path);
      } catch (_) {
        return 'unsafe path ${f.path}';
      }
      if (!seen.add(f.path)) return 'duplicate path';
      total += f.size;
    }
    for (final d in o.dirs) {
      try {
        sanitizeRelPath(d);
      } catch (_) {
        return 'unsafe dir';
      }
    }
    if (total != o.totalSize) return 'total size mismatch';
    return null;
  }

  Future<void> _fetchFromRelay(_Sink s, RelayConn rc) async {
    var next = 0;
    Future<void> worker() async {
      while (!s.tok.isCancelled && !s.isComplete) {
        if (next >= s.order.length) return;
        final (f, c) = s.order[next++];
        final want = chunkLen(s.st.files[f].entry.size, s.st.chunkSize, c);
        try {
          final sealed = await _getWithRetry(rc, s.st.transferId, s.session, f, c, want + kAeadOverhead, s.tok);
          await s.accept(f, c, sealed);
        } on _Unexpected {
          // already delivered
        } catch (err) {
          s.fail(err);
          return;
        }
      }
    }

    await Future.wait(List.generate(workers, (_) => worker()));
  }

  Future<Uint8List> _getWithRetry(RelayConn rc, String tid, String session, int f, int c, int max, _Token tok) async {
    var timeouts = 0, fails = 0;
    while (true) {
      tok.check();
      try {
        return await rc.get(tid, session, f, c, max);
      } catch (err) {
        tok.check();
        if (isStatus(err, 504)) {
          if (++timeouts > 8) rethrow;
          continue;
        }
        if (err is ApiException && const {400, 401, 403}.contains(err.status)) rethrow;
        if (++fails > 6) rethrow;
        await Future.delayed(Duration(seconds: min(fails * fails, 10)));
      }
    }
  }

  // ------------------------------------------------------------ LAN server

  Future<void> _startLan() async {
    final port = cfg!.lanPort;
    try {
      _lanServer = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: false);
    } catch (e) {
      try {
        _lanServer = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      } catch (e2) {
        log('LAN receiver disabled: $e2');
        return;
      }
    }
    _lanServer!.listen(_handleLan, onError: (_) {});
    lanUrls = await _localUrls(_lanServer!.port);
    log('LAN receiver on :${_lanServer!.port} ${lanUrls.join(', ')}');
  }

  static Future<List<String>> _localUrls(int port) async {
    final out = <String>[];
    try {
      for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in ni.addresses) {
          final b = a.rawAddress;
          final private = b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] < 32) || (b[0] == 192 && b[1] == 168);
          if (private && !a.isLoopback) out.add('http://${a.address}:$port');
        }
      }
    } catch (_) {}
    return out.take(8).toList();
  }

  Future<void> _handleLan(HttpRequest req) async {
    final res = req.response;
    try {
      final seg = req.uri.pathSegments;
      if (req.method == 'GET' && req.uri.path == '/synchub/v1/ping') {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'device_id': self, 'version': 1}));
      } else if (req.method == 'PUT' && seg.length == 7 && seg[0] == 'synchub' && seg[2] == 'chunk') {
        final s = _sinks['${seg[3]}|${seg[4]}'];
        final f = int.tryParse(seg[5]), c = int.tryParse(seg[6]);
        final len = req.contentLength;
        if (s == null) {
          res.statusCode = 404;
        } else if (f == null || c == null || len <= 0 || len > kMaxChunkSize + kAeadOverhead) {
          res.statusCode = 400;
        } else {
          final b = BytesBuilder(copy: false);
          await for (final part in req) {
            b.add(part);
            if (b.length > len) break;
          }
          if (b.length != len) {
            res.statusCode = 400;
          } else {
            try {
              await s.accept(f, c, b.takeBytes());
              res.statusCode = 204;
            } on _Unexpected {
              res.statusCode = 409;
            } on ChunkAuthException {
              res.statusCode = 400;
            } catch (e) {
              res.statusCode = 500;
            }
          }
        }
      } else {
        res.statusCode = 404;
      }
    } catch (_) {
      res.statusCode = 500;
    }
    await res.close();
  }

  // --------------------------------------------------------------- history

  File? _historyFile;

  Future<void> _loadHistory(String dir) async {
    _historyFile = File(p.join(dir, 'history.json'));
    try {
      final l = jsonDecode(await _historyFile!.readAsString()) as List;
      for (final j in l) {
        final t = TransferView.fromJson(j as Map<String, dynamic>);
        transfers[t.id] = t;
      }
    } catch (_) {}
  }

  Future<void> _saveHistory() async {
    final f = _historyFile;
    if (f == null) return;
    final done = transfers.values.where((t) => t.finished).toList()..sort((a, b) => b.updated.compareTo(a.updated));
    try {
      await f.writeAsString(jsonEncode(done.take(200).map((t) => t.toJson()).toList()));
    } catch (_) {}
  }

  void _finish(TransferView v, {required bool ok, String error = '', List<String> saved = const []}) {
    v
      ..state = ok ? TransferState.done : TransferState.failed
      ..error = error
      ..saved = saved
      ..speed = 0
      ..updated = DateTime.now();
    if (ok) v.done = v.total;
    notifyListeners();
    unawaited(_saveHistory());
  }

  void clearHistory() {
    transfers.removeWhere((_, t) => t.finished);
    notifyListeners();
    unawaited(_saveHistory());
  }

  Future<(String, DateTime)> pairingCode() => api.pairingCode();
  Future<void> revoke(String id) => api.deleteDevice(id);
}

// ------------------------------------------------------------------ receive

class _Unexpected implements Exception {}

class ManifestDigest {
  /// Same digest as the Go client: sha256(json{c,f,d}).
  static String of(Offer o) {
    final j = jsonEncode({
      'c': o.chunkSize,
      'f': o.files.map((f) => f.toJson()).toList(),
      'd': o.dirs.isEmpty ? null : o.dirs,
    });
    return _sha(utf8.encode(j));
  }
}

String _sha(List<int> b) => hash.sha256.convert(b).toString();

class _RecvFile {
  final FileEntry entry;
  Uint8List done;
  bool finalized;
  String finalPath;
  _RecvFile(this.entry, this.done, this.finalized, this.finalPath);
  bool has(int c) => done[c >> 3] & (1 << (c & 7)) != 0;
  void set(int c) => done[c >> 3] |= 1 << (c & 7);
}

class _RecvState {
  final String transferId;
  final String from;
  final String digest;
  final String title;
  final int chunkSize;
  final List<_RecvFile> files;
  final List<String> dirs;
  final Map<String, String> topMap;
  final String createdAt;
  final String dir;
  bool dirty = false;

  _RecvState(this.transferId, this.from, this.digest, this.title, this.chunkSize, this.files, this.dirs, this.topMap,
      this.createdAt, this.dir);

  static Future<_RecvState> loadOrInit(String partialDir, Offer o, String from, String digest) async {
    final dir = p.join(partialDir, o.transferId);
    final f = File(p.join(dir, 'state.json'));
    if (await f.exists()) {
      try {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        if (j['digest'] == digest && j['from'] == from) {
          return _RecvState(
            o.transferId,
            from,
            digest,
            (j['title'] ?? '') as String,
            j['chunk_size'] as int,
            (j['files'] as List).map((x) {
              final m = x as Map<String, dynamic>;
              return _RecvFile(FileEntry.fromJson(m), base64.decode((m['done'] ?? '') as String), (m['finalized'] ?? false) as bool,
                  (m['final'] ?? '') as String);
            }).toList(),
            ((j['dirs'] ?? []) as List).cast<String>(),
            ((j['top_map'] ?? {}) as Map).cast<String, String>(),
            (j['created_at'] ?? '') as String,
            dir,
          );
        }
      } catch (_) {}
      await Directory(dir).delete(recursive: true);
    }
    await Directory(dir).create(recursive: true);
    final st = _RecvState(
      o.transferId,
      from,
      digest,
      o.title,
      o.chunkSize,
      o.files.map((e) => _RecvFile(e, Uint8List((chunkCount(e.size, o.chunkSize) + 7) >> 3), false, '')).toList(),
      o.dirs,
      {},
      DateTime.now().toUtc().toIso8601String(),
      dir,
    );
    await st.save();
    return st;
  }

  int chunks(int i) => chunkCount(files[i].entry.size, chunkSize);
  bool complete(int i) {
    final cc = chunks(i);
    for (var c = 0; c < cc; c++) {
      if (!files[i].has(c)) return false;
    }
    return true;
  }

  (List<NeedRange>, int) need() {
    final out = <NeedRange>[];
    var bytes = 0;
    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      if (f.finalized) continue;
      final cc = chunks(i);
      var c = 0;
      while (c < cc) {
        if (f.has(c)) {
          c++;
          continue;
        }
        final start = c;
        while (c < cc && !f.has(c)) {
          bytes += chunkLen(f.entry.size, chunkSize, c);
          c++;
        }
        out.add(NeedRange(i, start, c));
      }
    }
    return (out, bytes);
  }

  String partPath(int i) => p.join(dir, 'f$i.part');

  final _saveLock = _Lock();
  Future<void> save() => _saveLock.run(() async {
        dirty = false;
        final j = {
          'transfer_id': transferId,
          'from': from,
          'digest': digest,
          'title': title,
          'chunk_size': chunkSize,
          'files': files
              .map((f) => {
                    ...f.entry.toJson(),
                    'done': base64.encode(f.done),
                    'finalized': f.finalized,
                    if (f.finalPath.isNotEmpty) 'final': f.finalPath,
                  })
              .toList(),
          if (dirs.isNotEmpty) 'dirs': dirs,
          'top_map': topMap,
          'created_at': createdAt,
        };
        final tmp = File(p.join(dir, 'state.json.tmp'));
        await tmp.writeAsString(jsonEncode(j));
        await tmp.rename(p.join(dir, 'state.json'));
      });

  Future<List<String>> finalizeAll(String recvDir) async {
    await Directory(recvDir).create(recursive: true);
    final saved = <String>[];
    void add(String s) {
      if (!saved.contains(s)) saved.add(s);
    }

    Future<String> topDest(String top) async {
      final v = topMap[top];
      if (v != null) return v;
      final u = await uniquePath(p.join(recvDir, top));
      topMap[top] = p.basename(u);
      return topMap[top]!;
    }

    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      if (f.finalized) {
        add(f.finalPath);
        continue;
      }
      if (!complete(i)) throw StateError('incomplete file ${f.entry.path}');
      final comps = sanitizeRelPath(f.entry.path);
      final part = partPath(i);
      if (f.entry.size == 0) await File(part).writeAsBytes(const []);
      String dest;
      if (comps.length == 1) {
        dest = p.join(recvDir, comps[0]);
        final existing = File(dest);
        if (await existing.exists() && await existing.length() == f.entry.size && await _shaFile(dest) == f.entry.sha256) {
          await File(part).delete();
          f
            ..finalized = true
            ..finalPath = dest;
          add(dest);
          continue;
        }
        dest = await uniquePath(dest);
      } else {
        final top = await topDest(comps[0]);
        dest = p.joinAll([recvDir, top, ...comps.skip(1)]);
        await Directory(p.dirname(dest)).create(recursive: true);
        dest = await uniquePath(dest);
        add(p.join(recvDir, top));
      }
      await File(part).rename(dest);
      try {
        await File(dest).setLastModified(DateTime.fromMillisecondsSinceEpoch(f.entry.mtime));
      } catch (_) {}
      f
        ..finalized = true
        ..finalPath = dest;
      if (comps.length == 1) add(dest);
      await save();
    }
    for (final d in dirs) {
      final comps = sanitizeRelPath(d);
      final top = await topDest(comps[0]);
      await Directory(p.joinAll([recvDir, top, ...comps.skip(1)])).create(recursive: true);
      add(p.join(recvDir, top));
    }
    await save();
    return saved;
  }
}

Future<String> _shaFile(String path) async => (await hash.sha256.bind(File(path).openRead()).first).toString();

class _Sink {
  final Engine e;
  final _RecvState st;
  final SessionCipher cipher;
  final String session;
  final TransferView view;
  final _Token tok;
  final pending = <int>{};
  final order = <(int, int)>[];
  final _handles = <int, RandomAccessFile>{};
  final _locks = <int, _Lock>{};
  final _done = Completer<void>();
  int left = 0;
  DateTime last = DateTime.now();
  Timer? _flush;

  _Sink(this.e, this.st, this.cipher, this.session, List<NeedRange> need, this.view, this.tok) {
    for (final n in need) {
      for (var c = n.from; c < n.to; c++) {
        pending.add(_k(n.file, c));
        order.add((n.file, c));
      }
    }
    left = order.length;
    if (left == 0) _done.complete();
    _flush = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (st.dirty) unawaited(st.save());
    });
    tok.whenCancelled.then((_) {
      if (!_done.isCompleted) _done.completeError(_Cancelled(tok.reason));
    });
  }

  static int _k(int f, int c) => f * 0x100000000 + c;
  bool get isComplete => _done.isCompleted;

  void fail(Object err) {
    if (!_done.isCompleted) _done.completeError(err);
  }

  Future<void> wait() async {
    final watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      if (DateTime.now().difference(last) > const Duration(seconds: 90)) fail(TimeoutException('no data received for 90s'));
    });
    try {
      await _done.future;
    } finally {
      watchdog.cancel();
    }
  }

  Future<void> accept(int f, int c, Uint8List sealed) async {
    if (!pending.contains(_k(f, c)) || f < 0 || f >= st.files.length) throw _Unexpected();
    final want = chunkLen(st.files[f].entry.size, st.chunkSize, c);
    final plain = await e._pool!.open(cipher, f, c, sealed);
    if (plain.length != want) throw const ChunkAuthException();
    final lock = _locks.putIfAbsent(f, _Lock.new);
    try {
      await lock.run(() async {
        final raf = _handles[f] ??= await File(st.partPath(f)).open(mode: FileMode.append);
        await raf.setPosition(c * st.chunkSize);
        await raf.writeFrom(plain);
      });
    } catch (err) {
      fail(err); // e.g. disk full: session fails, progress kept
      rethrow;
    }
    if (!pending.remove(_k(f, c))) return;
    left--;
    last = DateTime.now();
    view.done += want;
    st.files[f].set(c);
    st.dirty = true;
    if (st.complete(f)) {
      await lock.run(() async {
        await _handles.remove(f)?.close();
      });
      final h = await e._pool!.sha256File(st.partPath(f));
      if (h != st.files[f].entry.sha256) {
        st.files[f].done = Uint8List(st.files[f].done.length);
        await st.save();
        await File(st.partPath(f)).delete();
        final err = StateError('file hash mismatch: ${st.files[f].entry.path}');
        fail(err);
        throw err;
      }
    }
    if (left == 0 && !_done.isCompleted) _done.complete();
  }

  Future<void> close() async {
    _flush?.cancel();
    for (final r in _handles.values) {
      await r.close();
    }
    _handles.clear();
    if (st.dirty) await st.save();
  }
}

typedef SyncEngine = Engine;
