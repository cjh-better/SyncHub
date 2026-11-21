import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/clipboard_sync.dart';
import '../core/engine.dart';
import '../core/hub_api.dart';
import '../core/manifest.dart';
import '../ui/theme.dart';
import 'tray_ownership.dart';
import 'win_integration.dart';

class _CliSendBatch {
  final String targetKey;
  final String? deviceId;
  final bool cloud;
  final bool star;
  final List<String> paths = <String>[];
  Timer? timer;

  _CliSendBatch({
    required this.targetKey,
    this.deviceId,
    this.cloud = false,
    this.star = false,
  });
}

/// Bridges Desktop (`synchub/desktop` on Windows & macOS) and Android
/// (`synchub/native`, `synchub/storage`, `synchub/events`) native integrations
/// with [Engine] and the Flutter UI.
class PlatformBridge {
  static const MethodChannel desktopChannel = MethodChannel('synchub/desktop');
  static const MethodChannel nativeChannel = MethodChannel('synchub/native');
  static const MethodChannel storageChannel = MethodChannel('synchub/storage');

  static PlatformBridge? instance;

  final Engine engine;
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  /// Callback provided by `HomePage` to switch tabs (`0..4`).
  void Function(int tab)? onSelectTab;

  bool launchAtLogin = false;
  Map<String, dynamic>? legacyMacInfo;

  Timer? _traySyncDebounce;
  Timer? _officialProbeTimer;
  OfficialClipboardPresence officialClipboard = const OfficialClipboardPresence.absent();
  String _lastWinExplorerSig = '';
  String _lastAndroidServiceSig = '';
  StreamSubscription<Map<String, dynamic>>? _androidEventsSub;
  final Map<String, _CliSendBatch> _cliBatches = <String, _CliSendBatch>{};
  bool _pickerDialogOpen = false;

  PlatformBridge(this.engine) {
    instance = this;
  }

  static bool get isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// Runs platform storage & legacy `last_id` migration before [Engine.start].
  Future<void> prepareBeforeStart(Engine e) async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;

    if (Platform.isWindows) {
      try {
        final stateDir = e.cfg?.stateDir ?? p.join(e.cfgFile.parent.path, 'state');
        final migrated = await WinIntegration.migrateLegacyHubLastId(
          targetStateFile: p.join(stateDir, 'hub_receiver_state.json'),
        );
        if (migrated > e.initialLegacyHubId) {
          e.initialLegacyHubId = migrated;
        }
      } catch (_) {}
      return;
    }

    if (Platform.isMacOS) {
      try {
        final raw = await desktopChannel.invokeMethod<dynamic>('migrateLegacyMacState');
        if (raw is Map) {
          final info = raw.map((k, v) => MapEntry('$k', v));
          legacyMacInfo = info;
          final lid = (info['lastId'] ?? info['last_id']);
          if (lid is num && lid.toInt() > e.initialLegacyHubId) {
            e.initialLegacyHubId = lid.toInt();
          }
        }
      } catch (_) {}
      return;
    }

    if (Platform.isAndroid) {
      await _prepareAndroidStorageAndMigration(e);
    }
  }

  Future<void> _prepareAndroidStorageAndMigration(Engine e) async {
    try {
      final caps = await getAndroidCapabilities();
      final mig1 = caps['migratedLastHubId'];
      final mig2 = caps['oldRootScriptLastId'];
      var best = e.initialLegacyHubId;
      if (mig1 is num && mig1.toInt() > best) best = mig1.toInt();
      if (mig2 is num && mig2.toInt() > best) best = mig2.toInt();
      e.initialLegacyHubId = best;
    } catch (_) {}

    final c = e.cfg;
    if (c == null) return;

    var hasAllFiles = false;
    try {
      hasAllFiles = await storageChannel.invokeMethod<bool>('hasAllFilesAccess') ?? false;
    } catch (_) {}

    if (hasAllFiles) {
      if (!c.recvDir.startsWith('/storage/emulated/0/')) {
        c.recvDir = '/storage/emulated/0/Download/跨端传输';
      }
      try {
        await Directory(c.recvDir).create(recursive: true);
        await c.save(e.cfgFile);
        return;
      } catch (_) {}
    }

    // Without MANAGE_EXTERNAL_STORAGE yet, ensure receive directory is writable
    // by falling back to app external storage until granted in Settings.
    try {
      await Directory(c.recvDir).create(recursive: true);
      return;
    } catch (_) {}

    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        final fallback = p.join(ext.path, '跨端传输');
        await Directory(fallback).create(recursive: true);
        if (c.recvDir != fallback) {
          c.recvDir = fallback;
          await c.save(e.cfgFile);
        }
      }
    } catch (_) {}
  }

  /// Attaches engine callbacks, desktop tray/CLI handlers, and Android service/events.
  Future<void> attach() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;

    engine.onFilesSaved = _onFilesSaved;
    engine.onIncomingOfferPrompt = _onIncomingOfferPrompt;
    engine.onCopiedMultipleFiles = _onCopiedMultipleFiles;

    engine.addListener(_onStateChanged);
    engine.clipSync.addListener(_onStateChanged);

    if (isDesktop) {
      desktopChannel.setMethodCallHandler(_handleDesktopCall);
      try {
        launchAtLogin = await desktopChannel.invokeMethod<bool>('getLaunchAtLogin') ?? false;
      } catch (_) {}

      try {
        final readyArg = Platform.isMacOS
            ? <String, dynamic>{'migrateLegacy': true}
            : null;
        final readyRes = await desktopChannel.invokeMethod<dynamic>('ready', readyArg);
        _processDesktopReadyResult(readyRes);
      } catch (_) {}

      _scheduleTraySync();
      if (Platform.isWindows) {
        unawaited(_syncWindowsExplorerMenuIfNeeded());
        unawaited(refreshClipboardDuty());
        _officialProbeTimer?.cancel();
        _officialProbeTimer = Timer.periodic(const Duration(seconds: 20), (_) {
          unawaited(refreshClipboardDuty());
        });
      }
    } else if (Platform.isAndroid) {
      _androidEventsSub?.cancel();
      _androidEventsSub = PlatformClipboardAdapter.sharedEvents?.listen(_onAndroidEvent);
      unawaited(syncAndroidService(forceStart: engine.registered));
    }
  }

  void dispose() {
    _officialProbeTimer?.cancel();
    _traySyncDebounce?.cancel();
    for (final b in _cliBatches.values) {
      b.timer?.cancel();
    }
    _cliBatches.clear();
    _androidEventsSub?.cancel();
    engine.removeListener(_onStateChanged);
    try {
      engine.clipSync.removeListener(_onStateChanged);
    } catch (_) {}
  }

  void _onStateChanged() {
    if (isDesktop) {
      _scheduleTraySync();
      if (Platform.isWindows) {
        unawaited(_syncWindowsExplorerMenuIfNeeded());
      }
    } else if (Platform.isAndroid) {
      unawaited(syncAndroidService());
    }
  }

  // ------------------------------------------------------------------ Desktop

  void _processDesktopReadyResult(dynamic res) {
    if (res is List) {
      for (final item in res) {
        _processStartupEvent(item);
      }
      return;
    }
    if (res is Map) {
      final map = res.map((k, v) => MapEntry('$k', v));
      if (map['launchAtLogin'] is bool) {
        launchAtLogin = map['launchAtLogin'] as bool;
      }
      final leg = map['legacy'];
      if (leg is Map) {
        final info = leg.map((k, v) => MapEntry('$k', v));
        legacyMacInfo = info;
        final lid = info['lastId'] ?? info['last_id'];
        if (lid is num && lid.toInt() > engine.initialLegacyHubId) {
          engine.initialLegacyHubId = lid.toInt();
        }
      }
      final events = map['events'];
      if (events is List) {
        for (final item in events) {
          _processStartupEvent(item);
        }
      }
    }
  }

  void _processStartupEvent(dynamic raw) {
    if (raw is! Map) return;
    final kind = (raw['kind'] as String? ?? '').toLowerCase();
    if (kind == 'cli') {
      final args = ((raw['args'] as List?) ?? const <dynamic>[])
          .whereType<String>()
          .toList();
      if (args.isNotEmpty) _ingestCliArgs(args);
    } else if (kind == 'files') {
      final paths = ((raw['paths'] as List?) ?? const <dynamic>[])
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .toList();
      if (paths.isNotEmpty) {
        _enqueueCliBatch(paths: paths);
      }
    }
  }

  Future<dynamic> _handleDesktopCall(MethodCall call) async {
    switch (call.method) {
      case 'onCliArgs':
        final a = call.arguments;
        if (a is List) {
          _ingestCliArgs(a.whereType<String>().toList());
        } else if (a is Map && a['args'] is List) {
          _ingestCliArgs((a['args'] as List).whereType<String>().toList());
        }
        return true;

      case 'onTrayAction':
        if (call.arguments is Map) {
          final map = (call.arguments as Map).map((k, v) => MapEntry('$k', v));
          await _handleTrayAction(map);
        }
        return true;

      case 'onDroppedFiles':
        if (call.arguments is Map) {
          final map = (call.arguments as Map).map((k, v) => MapEntry('$k', v));
          final paths = ((map['paths'] as List?) ?? const <dynamic>[])
              .whereType<String>()
              .where((s) => s.isNotEmpty)
              .toList();
          final devId = map['deviceId'] as String?;
          final cloud = map['cloud'] == true;
          if (paths.isNotEmpty) {
            if (cloud) {
              final star = map['star'] is bool ? map['star'] as bool : true;
              await _dispatchSend(paths, cloud: true, star: star);
            } else if (devId != null && devId.isNotEmpty) {
              await _dispatchSend(paths, deviceId: devId);
            } else {
              await promptAndSendPaths(paths);
            }
          }
        }
        return true;

      case 'onServiceText':
        final text = call.arguments is Map
            ? (call.arguments['text'] as String? ?? '')
            : (call.arguments is String ? call.arguments as String : '');
        if (text.trim().isNotEmpty && engine.registered) {
          await engine.clipSync.pushExplicitText(text);
          try {
            await engine.hub.postText(
              text,
              from: engine.cfg?.name ?? 'macOS',
              syncClipboard: false,
            );
          } catch (_) {}
          await showDesktopNotification(
            title: '已发送到 SyncHub',
            body: text.length > 48 ? '${text.substring(0, 48)}…' : text,
          );
        }
        return true;

      case 'onNotificationClick':
        final path = call.arguments is Map
            ? (call.arguments['path'] as String? ?? '')
            : (call.arguments is String ? call.arguments as String : '');
        if (path.isNotEmpty) {
          await revealInFolder(path);
        } else {
          await showMainWindow();
        }
        return true;

      case 'system_event':
        final event = call.arguments is Map
            ? (call.arguments['event'] as String? ?? '')
            : (call.arguments is String ? call.arguments as String : '');
        await _handleSystemEvent(event.toLowerCase());
        return true;

      case 'clipboard_changed':
      case 'onClipboardChanged':
        final map = call.arguments is Map
            ? (call.arguments as Map).map((k, v) => MapEntry('$k', v))
            : null;
        PlatformClipboardAdapter.notifyClipboardChanged(map);
        return true;
    }
    return null;
  }

  Future<void> refreshClipboardDuty() async {
    if (!Platform.isWindows) return;
    try {
      officialClipboard = await WinIntegration.inspectOfficialClipboard();
      await engine.clipSync.setYieldToOfficialClient(
        decideClipboardDuty(officialClipboard) == ClipboardDuty.yieldToOfficial,
      );
    } catch (_) {}
  }

  Future<void> _handleSystemEvent(String event) async {
    switch (event) {
      case 'sleep':
        engine.onSystemSleep();
        engine.clipSync.setScreenOff(true);
        engine.autoPuller.screenOff = true;
      case 'wake':
        engine.onSystemWake();
        engine.clipSync.setScreenOff(false);
        engine.autoPuller.screenOff = false;
        engine.kickReconnect(force: true);
        engine.mdns?.announceNow();
        engine.autoPuller.kick();
        if (Platform.isWindows) {
          unawaited(refreshClipboardDuty());
        }
        unawaited(engine.clipSync.kick());
        unawaited(engine.clipSync.pollLocalOnce());
      case 'lock':
      case 'session_lock':
        engine.clipSync.setScreenOff(true);
        unawaited(engine.flushState());
      case 'unlock':
      case 'session_unlock':
        engine.clipSync.setScreenOff(false);
        unawaited(engine.clipSync.pollLocalOnce());
    }
  }

  void _ingestCliArgs(List<String> args) {
    if (args.isEmpty) return;

    var hasSendFlag = false;
    var cloud = false;
    var star = false;
    String? targetDeviceId;
    final paths = <String>[];
    var passthrough = false;

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (!passthrough && arg == '--') {
        passthrough = true;
        continue;
      }
      if (!passthrough && arg.startsWith('-')) {
        if (arg == '--minimized' || arg == '--background') {
          continue;
        } else if (arg == '--send') {
          hasSendFlag = true;
        } else if (arg == '--cloud') {
          cloud = true;
          hasSendFlag = true;
        } else if (arg == '--star') {
          star = true;
        } else if (arg == '--to' && i + 1 < args.length) {
          targetDeviceId = args[++i];
          hasSendFlag = true;
        } else if (arg.startsWith('--to=')) {
          targetDeviceId = arg.substring(5);
          hasSendFlag = true;
        }
        continue;
      }
      if (arg.trim().isNotEmpty) {
        paths.add(arg);
      }
    }

    if (paths.isEmpty) {
      if (hasSendFlag) {
        unawaited(showMainWindow());
      }
      return;
    }

    _enqueueCliBatch(
      paths: paths,
      deviceId: targetDeviceId,
      cloud: cloud,
      star: star,
    );
  }

  void _enqueueCliBatch({
    required List<String> paths,
    String? deviceId,
    bool cloud = false,
    bool star = false,
  }) {
    final key = cloud
        ? (star ? 'cloud:star' : 'cloud:temp')
        : (deviceId != null && deviceId.isNotEmpty ? 'dev:$deviceId' : 'pick');

    final batch = _cliBatches.putIfAbsent(
      key,
      () => _CliSendBatch(
        targetKey: key,
        deviceId: deviceId,
        cloud: cloud,
        star: star,
      ),
    );
    for (final path in paths) {
      if (!batch.paths.contains(path)) {
        batch.paths.add(path);
      }
    }
    batch.timer?.cancel();
    batch.timer = Timer(const Duration(milliseconds: 200), () {
      final done = _cliBatches.remove(key);
      if (done == null || done.paths.isEmpty) return;
      if (done.cloud) {
        unawaited(_dispatchSend(done.paths, cloud: true, star: done.star));
      } else if (done.deviceId != null && done.deviceId!.isNotEmpty) {
        unawaited(_dispatchSend(done.paths, deviceId: done.deviceId));
      } else {
        unawaited(promptAndSendPaths(done.paths));
      }
    });
  }

  Future<void> _dispatchSend(
    List<String> paths, {
    String? deviceId,
    bool cloud = false,
    bool star = false,
  }) async {
    if (!engine.registered) {
      await showMainWindow();
      _showSnack('请先登录 SyncHub 设备后再发送文件');
      return;
    }
    final target = cloud ? kCloudTargetId : (deviceId ?? kCloudTargetId);
    try {
      await engine.sendPaths(target, paths, star: star);
      onSelectTab?.call(1);
      if (isDesktop) {
        final peerName = cloud
            ? (star ? '云端收藏' : '云端中转')
            : (engine.devices[target]?.name ?? target);
        final label = paths.length == 1
            ? p.basename(paths.first)
            : '${p.basename(paths.first)} 等 ${paths.length} 项';
        await showDesktopNotification(
          title: '正在发送到 $peerName',
          body: label,
        );
      }
    } catch (e) {
      _showSnack('发送失败：$e');
    }
  }

  Future<void> _handleTrayAction(Map<String, dynamic> map) async {
    final action = (map['action'] as String? ?? '').trim();
    switch (action) {
      case 'openWindow':
        await showMainWindow();
      case 'openSettings':
        await showMainWindow();
        onSelectTab?.call(4);
      case 'sendFiles':
        await showMainWindow();
        if (!engine.registered) return;
        final picked = await FilePicker.pickFiles(dialogTitle: '选择要通过 SyncHub 发送的文件');
        final paths = picked.map((f) => f.path).whereType<String>().toList();
        if (paths.isNotEmpty) {
          await promptAndSendPaths(paths);
        }
      case 'sendToDevice':
        final devId = (map['deviceId'] as String? ?? '').trim();
        if (devId.isEmpty || !engine.registered) return;
        await showMainWindow();
        final devName = engine.devices[devId]?.name ?? devId;
        final picked = await FilePicker.pickFiles(dialogTitle: '选择要发送给 $devName 的文件');
        final paths = picked.map((f) => f.path).whereType<String>().toList();
        if (paths.isNotEmpty) {
          await _dispatchSend(paths, deviceId: devId);
        }
      case 'sendClipboard':
        if (!engine.registered) {
          await showMainWindow();
          return;
        }
        final res = await engine.clipSync.pushCurrentClipboard();
        final msg = switch (res) {
          ClipLocalPushed() => '当前剪贴板已同步到云端与其他设备',
          ClipLocalSkipped(:final reason) => reason,
        };
        if (isDesktop) {
          await showDesktopNotification(title: 'SyncHub 剪贴板', body: msg);
        }
        _showSnack(msg);
      case 'openRecent':
        final id = '${map['itemId'] ?? ''}'.trim();
        final modifier = (map['modifier'] as String? ?? 'none').toLowerCase();
        final tv = engine.transfers[id];
        final firstPath = (tv != null && tv.saved.isNotEmpty)
            ? tv.saved.first
            : (tv != null && tv.sourcePaths.isNotEmpty ? tv.sourcePaths.first : '');
        if (firstPath.isEmpty) {
          await showMainWindow();
          onSelectTab?.call(1);
          return;
        }
        if (modifier == 'cmd') {
          await Clipboard.setData(ClipboardData(text: firstPath));
          _showSnack('已复制路径：$firstPath');
        } else if (modifier == 'alt') {
          await revealInFolder(firstPath);
        } else {
          await openFile(firstPath);
        }
      case 'openRecvDir':
        final dir = engine.cfg?.recvDir ?? '';
        if (dir.isNotEmpty) {
          await Directory(dir).create(recursive: true);
          await openFile(dir);
        }
      case 'openWebHub':
        final base = HubApi.deriveOrigin(engine.cfg?.server ?? 'https://020814.xyz/gw');
        await openUrl('$base/hub/');
      case 'toggleAutoAccept':
        if (engine.registered) {
          final next = map['enabled'] is bool
              ? map['enabled'] as bool
              : !(engine.cfg!.autoAccept);
          await engine.updateConfig((c) => c.autoAccept = next);
        }
      case 'toggleClipSync':
        if (engine.registered) {
          final next = map['enabled'] is bool
              ? map['enabled'] as bool
              : !(engine.cfg!.clipSync);
          await engine.updateConfig((c) => c.clipSync = next);
        }
      case 'toggleLaunchAtLogin':
        final target = map['enabled'] is bool ? map['enabled'] as bool : !launchAtLogin;
        await setLaunchAtLogin(target);
      case 'quit':
        await engine.stop();
        try {
          await desktopChannel.invokeMethod<void>('quit');
        } catch (_) {
          exit(0);
        }
    }
  }

  void _scheduleTraySync() {
    if (!isDesktop) return;
    _traySyncDebounce?.cancel();
    _traySyncDebounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_pushTrayStateNow());
    });
  }

  Future<void> _pushTrayStateNow() async {
    if (!isDesktop) return;
    final c = engine.cfg;
    final peers = engine.devices.values
        .where((d) => d.id != engine.self)
        .toList()
      ..sort((a, b) => a.online == b.online
          ? a.name.compareTo(b.name)
          : (a.online ? -1 : 1));
    final onlineCount = peers.where((d) => d.online).length;

    final activeList = engine.transfers.values.where((t) => !t.finished).toList();
    final uploading = activeList.any((t) => t.direction == 'send');
    final downloading = activeList.any((t) => t.direction == 'recv');
    final totalBytes = activeList.fold<int>(0, (s, t) => s + max(0, t.total));
    final doneBytes = activeList.fold<int>(0, (s, t) => s + max(0, t.done));
    final progress = totalBytes > 0 ? (doneBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

    String statusLine;
    if (!engine.registered) {
      statusLine = 'SyncHub · 未登录';
    } else if (activeList.isNotEmpty) {
      final pct = (progress * 100).toStringAsFixed(0);
      statusLine = '${uploading ? '正在发送' : '正在接收'} · $pct%';
    } else if (engine.clipSync.yieldsToOfficialClient) {
      statusLine = 'SyncHub · 剪贴板暂由 SyncClipboard 负责';
    } else if (engine.connected) {
      statusLine = '已连接 · $onlineCount 台设备在线';
    } else {
      statusLine = '状态：${engine.status}';
    }

    final clipText = engine.clipSync.status.text;
    final recentTransfers = engine.transfers.values.toList()
      ..sort((a, b) => b.updated.compareTo(a.updated));
    final recentItems = <Map<String, dynamic>>[];
    for (final t in recentTransfers) {
      if (recentItems.length >= 8) break;
      final path = t.saved.isNotEmpty
          ? t.saved.first
          : (t.sourcePaths.isNotEmpty ? t.sourcePaths.first : '');
      recentItems.add(<String, dynamic>{
        'id': t.id,
        'title': '${t.direction == 'send' ? '↑' : '↓'} ${t.title}',
        'subtitle': '${t.peer} · ${humanBytes(t.total)}',
        'path': path,
      });
    }

    try {
      await desktopChannel.invokeMethod<void>('updateTrayState', <String, dynamic>{
        'connected': engine.connected,
        'onlineCount': onlineCount,
        'status': statusLine,
        'statusText': statusLine,
        'detailText': clipText == '就绪' ? '' : clipText,
        'tooltip': 'SyncHub — $statusLine',
        'uploading': uploading,
        'downloading': downloading,
        'progress': progress,
        'autoAccept': c?.autoAccept ?? true,
        'autoReceive': c?.autoAccept ?? true,
        'clipSync': c?.clipSync ?? true,
        'launchAtLogin': launchAtLogin,
        'devices': [
          for (final d in peers)
            <String, dynamic>{
              'id': d.id,
              'name': d.name,
              'platform': d.platform,
              'online': d.online,
            },
        ],
        'recentItems': recentItems,
      });
    } catch (_) {}
  }

  Future<void> _syncWindowsExplorerMenuIfNeeded() async {
    if (!Platform.isWindows || !engine.registered) return;
    final c = engine.cfg!;
    if (!c.explorerMenu) {
      if (_lastWinExplorerSig != '__off__') {
        _lastWinExplorerSig = '__off__';
        await WinIntegration.unregisterContextMenu();
      }
      return;
    }
    final peers = engine.devices.values
        .where((d) => d.id != engine.self)
        .toList()
      ..sort((a, b) => a.online == b.online
          ? a.name.compareTo(b.name)
          : (a.online ? -1 : 1));
    final sig = peers.map((d) => '${d.id}:${d.name}:${d.online ? 1 : 0}').join('|');
    final fullSig = 'on|$sig';
    if (fullSig == _lastWinExplorerSig) return;
    _lastWinExplorerSig = fullSig;

    await WinIntegration.registerContextMenu(
      exePath: Platform.resolvedExecutable,
      devices: [
        for (final d in peers) (id: d.id, name: d.name, online: d.online),
      ],
    );
  }

  Future<bool> setLaunchAtLogin(bool enabled) async {
    if (!isDesktop) return false;
    try {
      final ok = await desktopChannel.invokeMethod<bool>(
            'setLaunchAtLogin',
            <String, dynamic>{'enabled': enabled},
          ) ??
          false;
      launchAtLogin = await desktopChannel.invokeMethod<bool>('getLaunchAtLogin') ??
          (ok ? enabled : launchAtLogin);
      if (engine.registered) {
        await engine.updateConfig((c) => c.launchAtLogin = launchAtLogin);
      } else {
        _scheduleTraySync();
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------------------------------ Android

  Future<Map<String, dynamic>> getAndroidCapabilities() async {
    if (!Platform.isAndroid) return const <String, dynamic>{};
    try {
      final raw = await nativeChannel.invokeMethod<dynamic>('getCapabilities');
      if (raw is Map) {
        return raw.map((k, v) => MapEntry('$k', v));
      }
    } catch (_) {}
    return const <String, dynamic>{};
  }

  Future<void> syncAndroidService({bool forceStart = false}) async {
    if (!Platform.isAndroid) return;
    final c = engine.cfg;
    final configured = engine.registered && c != null;
    final sig = configured
        ? '1|${c.startOnBoot}|${c.clipSync}|${c.clipImages}|${c.useRootClipboard}|${c.autoAccept}|${c.recvDir}'
        : '0';
    if (!forceStart && sig == _lastAndroidServiceSig) return;
    _lastAndroidServiceSig = sig;
    try {
      await nativeChannel.invokeMethod<void>('configureService', <String, dynamic>{
        'configured': configured,
        'serviceEnabled': configured,
        'startOnBoot': c?.startOnBoot ?? true,
        'clipPush': c?.clipSync ?? true,
        'clipPull': c?.clipSync ?? true,
        'clipImages': c?.clipImages ?? true,
        'useRootClipboard': c?.useRootClipboard ?? true,
        'autoReceive': c?.autoAccept ?? true,
        'recvDir': c?.recvDir ?? '/storage/emulated/0/Download/跨端传输',
      });
      if (configured && forceStart) {
        await nativeChannel.invokeMethod<void>('startService');
      } else if (!configured) {
        await nativeChannel.invokeMethod<void>('stopService');
      }
    } catch (_) {}
  }

  void _onAndroidEvent(Map<String, dynamic> event) {
    final type = (event['type'] as String? ?? '').toLowerCase();
    switch (type) {
      case 'network_available':
        engine.mdns?.announceNow();
        engine.autoPuller.kick();

      case 'doze_mode_changed':
        final isDoze = event['doze'] == true;
        if (isDoze) {
          engine.onSystemSleep();
          engine.clipSync.setScreenOff(true);
          engine.autoPuller.screenOff = true;
        } else {
          engine.onSystemWake();
          engine.clipSync.setScreenOff(false);
          engine.autoPuller.screenOff = false;
          engine.kickReconnect(force: true);
          engine.mdns?.announceNow();
          engine.autoPuller.kick();
          unawaited(engine.clipSync.pollLocalOnce());
        }

      case 'screen_state':
        final isOn = event['screenOn'] == true;
        engine.clipSync.setScreenOff(!isOn);
        engine.autoPuller.screenOff = !isOn;
        if (isOn) {
          engine.kickReconnect(force: false);
          engine.autoPuller.kick();
          unawaited(engine.clipSync.pollLocalOnce());
        }

      case 'share_files':
        final paths = ((event['paths'] as List?) ?? const <dynamic>[])
            .whereType<String>()
            .where((s) => s.isNotEmpty)
            .toList();
        final source = (event['source'] as String? ?? 'share').toLowerCase();
        if (paths.isEmpty) return;
        if (!engine.registered) {
          _showSnack('请先登录 SyncHub 设备后再分享文件');
          return;
        }
        if (source == 'tile') {
          unawaited(_handleAndroidTileFiles(paths));
        } else {
          unawaited(promptAndSendPaths(paths));
        }

      case 'share_text':
        final text = (event['text'] as String? ?? '');
        final source = (event['source'] as String? ?? 'share').toLowerCase();
        if (text.trim().isEmpty || !engine.registered) return;
        unawaited(_handleAndroidSharedText(text, source));
    }
  }

  Future<void> _handleAndroidTileFiles(List<String> paths) async {
    if (paths.length == 1) {
      final f = File(paths.first);
      if (await f.exists() && await f.length() <= 20 * 1024 * 1024) {
        final res = await engine.clipSync.pushExplicitFile(paths.first);
        if (res is ClipLocalPushed) {
          _showSnack('已通过磁贴同步剪贴板文件：${p.basename(paths.first)}');
          return;
        }
      }
    }
    await _dispatchSend(paths, cloud: true, star: false);
    _showSnack('已上传到云端中转');
  }

  Future<void> _handleAndroidSharedText(String text, String source) async {
    await engine.clipSync.pushExplicitText(text);
    try {
      await engine.hub.postText(
        text,
        from: engine.cfg?.name ?? 'Android',
        syncClipboard: false,
      );
    } catch (_) {}
    final tag = source == 'process_text' ? '选中文本' : '文本';
    _showSnack('$tag已同步到剪贴板与云端收藏');
  }

  // ------------------------------------------------------ Shared UI Callbacks

  void _onFilesSaved(TransferView view, List<String> paths) {
    if (paths.isEmpty) return;
    if (isDesktop) {
      unawaited(showDesktopNotification(
        title: '已收到来自 ${view.peer} 的文件',
        body: view.title,
        path: paths.first,
      ));
    } else if (Platform.isAndroid) {
      unawaited(() async {
        try {
          await nativeChannel.invokeMethod<void>('onFilesReceived', <String, dynamic>{
            'paths': paths,
            'title': view.title,
            'from': view.peer,
          });
        } catch (_) {}
      }());
    }
  }

  void _onIncomingOfferPrompt(PendingOffer offer) {
    if (isDesktop) {
      unawaited(showMainWindow());
      unawaited(showDesktopNotification(
        title: '收到文件传输请求',
        body: '${offer.fromName} 想要发送「${offer.title}」(${humanBytes(offer.totalSize)})',
      ));
    }
  }

  void _onCopiedMultipleFiles(List<String> paths) {
    if (paths.isEmpty || !engine.registered) return;
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;
    ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
      SnackBar(
        content: Text('检测到复制了 ${paths.length} 个文件/文件夹，是否一键发送？'),
        action: SnackBarAction(
          label: '选择目标发送',
          onPressed: () => unawaited(promptAndSendPaths(paths)),
        ),
      ),
    );
  }

  /// Brings window to front (desktop) and opens a clean target picker dialog
  /// listing all peer devices + `"云端收藏"` + `"云端中转 (72小时)"`.
  Future<void> promptAndSendPaths(List<String> paths) async {
    if (paths.isEmpty) return;
    if (isDesktop) await showMainWindow();
    if (!engine.registered) {
      _showSnack('请先登录 SyncHub 设备');
      return;
    }
    final ctx = navigatorKey.currentState?.overlay?.context ?? navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted || _pickerDialogOpen) return;

    final peers = engine.devices.values
        .where((d) => d.id != engine.self)
        .toList()
      ..sort((a, b) => a.online == b.online
          ? a.name.compareTo(b.name)
          : (a.online ? -1 : 1));

    final summary = paths.length == 1
        ? p.basename(paths.first)
        : '${p.basename(paths.first)} 等 ${paths.length} 个项目';

    _pickerDialogOpen = true;
    String? chosen;
    try {
      chosen = await showDialog<String>(
        context: ctx,
        builder: (dctx) => AlertDialog(
          title: Text('发送「$summary」'),
          content: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final d in peers)
                    ListTile(
                      leading: Icon(
                        platformIcon(d.platform),
                        color: d.online ? kAccent : kText2,
                      ),
                      title: Text(d.name),
                      subtitle: Text(
                        d.online
                            ? (d.lan.isNotEmpty ? '在线 · 局域网直连' : '在线')
                            : (engine.cfg?.offlineFallback == true
                                ? '离线 · 自动转为云端离线投递'
                                : '离线 · 上线后自动发送'),
                        style: const TextStyle(fontSize: 12),
                      ),
                      onTap: () => Navigator.pop(dctx, 'dev:${d.id}'),
                    ),
                  if (peers.isNotEmpty) const Divider(),
                  ListTile(
                    leading: const Icon(Icons.star_rounded, color: kOrange),
                    title: const Text('存到云端收藏（永久保留）'),
                    subtitle: const Text('所有设备可随时在「云端」页查看与下载', style: TextStyle(fontSize: 12)),
                    onTap: () => Navigator.pop(dctx, 'cloud:star'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.cloud_upload_outlined, color: kAccent),
                    title: const Text('发送到云端中转（72 小时自动清理）'),
                    subtitle: const Text('在线/离线设备自动后台拉取到接收目录', style: TextStyle(fontSize: 12)),
                    onTap: () => Navigator.pop(dctx, 'cloud:temp'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx),
              child: const Text('取消'),
            ),
          ],
        ),
      );
    } finally {
      _pickerDialogOpen = false;
    }

    if (chosen == null) return;
    if (chosen == 'cloud:star') {
      await _dispatchSend(paths, cloud: true, star: true);
    } else if (chosen == 'cloud:temp') {
      await _dispatchSend(paths, cloud: true, star: false);
    } else if (chosen.startsWith('dev:')) {
      await _dispatchSend(paths, deviceId: chosen.substring(4));
    }
  }

  void _showSnack(String message) {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;
    ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // --------------------------------------------------------- Static Utilities

  static Future<void> showMainWindow() async {
    if (!isDesktop) return;
    try {
      await desktopChannel.invokeMethod<void>('showWindow');
    } catch (_) {}
  }

  static Future<void> showDesktopNotification({
    required String title,
    required String body,
    String? path,
  }) async {
    if (!isDesktop) return;
    try {
      await desktopChannel.invokeMethod<void>('notify', <String, dynamic>{
        'title': title,
        'body': body,
        if (path != null && path.isNotEmpty) 'path': path,
      });
    } catch (_) {}
  }

  static Future<void> openFile(String path) async {
    if (path.isEmpty) return;
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', <String>[path]);
      } else if (Platform.isMacOS) {
        final ok = await desktopChannel.invokeMethod<bool>(
              'openFile',
              <String, dynamic>{'path': path},
            ) ??
            false;
        if (!ok) await Process.run('open', <String>[path]);
      } else if (Platform.isAndroid) {
        await nativeChannel.invokeMethod<void>(
          'openFile',
          <String, dynamic>{'path': path},
        );
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', <String>[path]);
      }
    } catch (_) {}
  }

  static Future<void> revealInFolder(String path) async {
    if (path.isEmpty) return;
    try {
      if (Platform.isWindows) {
        final type = await FileSystemEntity.type(path, followLinks: false);
        if (type == FileSystemEntityType.directory) {
          await Process.run('explorer.exe', <String>[path]);
        } else {
          await Process.run('explorer.exe', <String>['/select,', path]);
        }
      } else if (Platform.isMacOS) {
        final ok = await desktopChannel.invokeMethod<bool>(
              'revealInFinder',
              <String, dynamic>{'path': path},
            ) ??
            false;
        if (!ok) await Process.run('open', <String>['-R', path]);
      } else {
        await openFile(p.dirname(path));
      }
    } catch (_) {}
  }

  static Future<void> openUrl(String url) async {
    if (url.isEmpty) return;
    try {
      if (Platform.isWindows) {
        await Process.run('rundll32.exe', <String>['url.dll,FileProtocolHandler', url]);
      } else if (Platform.isMacOS) {
        final ok = await desktopChannel.invokeMethod<bool>(
              'openUrl',
              <String, dynamic>{'url': url},
            ) ??
            false;
        if (!ok) await Process.run('open', <String>[url]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', <String>[url]);
      }
    } catch (_) {}
  }
}
