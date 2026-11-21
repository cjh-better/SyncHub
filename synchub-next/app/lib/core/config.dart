import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'secure_store.dart';

/// Persisted identity + preferences of this device.
class AppConfig {
  String server;
  String deviceId;
  String token;
  String name;
  String platform;
  String privateKey; // base64 X25519
  String recvDir;
  String stateDir;
  bool autoAccept;
  int lanPort;
  bool clipSync;
  bool clipImages;
  String customClipUrl;
  String customClipUser;
  String customClipPass;
  bool offlineFallback;
  bool explorerMenu;
  bool launchAtLogin;
  bool startOnBoot;
  bool useRootClipboard;

  AppConfig({
    required this.server,
    required this.deviceId,
    required this.token,
    required this.name,
    required this.platform,
    required this.privateKey,
    required this.recvDir,
    required this.stateDir,
    this.autoAccept = true,
    this.lanPort = 53318,
    this.clipSync = true,
    this.clipImages = true,
    this.customClipUrl = '',
    this.customClipUser = '',
    this.customClipPass = '',
    this.offlineFallback = true,
    this.explorerMenu = true,
    this.launchAtLogin = false,
    this.startOnBoot = true,
    this.useRootClipboard = true,
  });

  bool get registered => token.isNotEmpty && deviceId.isNotEmpty;

  factory AppConfig.fromJson(Map<String, dynamic> j) => AppConfig(
        server: (j['server'] ?? '') as String,
        deviceId: (j['device_id'] ?? '') as String,
        token: (j['token'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        platform: (j['platform'] ?? '') as String,
        privateKey: (j['private_key'] ?? '') as String,
        recvDir: (j['recv_dir'] ?? '') as String,
        stateDir: (j['state_dir'] ?? '') as String,
        autoAccept: (j['auto_accept'] ?? true) as bool,
        lanPort: (j['lan_port'] ?? 53318) as int,
        clipSync: (j['clip_sync'] ?? true) as bool,
        clipImages: (j['clip_images'] ?? true) as bool,
        customClipUrl: (j['custom_clip_url'] ?? '') as String,
        customClipUser: (j['custom_clip_user'] ?? '') as String,
        customClipPass: (j['custom_clip_pass'] ?? '') as String,
        offlineFallback: (j['offline_fallback'] ?? true) as bool,
        explorerMenu: (j['explorer_menu'] ?? true) as bool,
        launchAtLogin: (j['launch_at_login'] ?? false) as bool,
        startOnBoot: (j['start_on_boot'] ?? true) as bool,
        useRootClipboard: (j['use_root_clipboard'] ?? true) as bool,
      );

  Map<String, dynamic> toJson() => {
        'server': server,
        'device_id': deviceId,
        'token': token,
        'name': name,
        'platform': platform,
        'private_key': privateKey,
        'recv_dir': recvDir,
        'state_dir': stateDir,
        'auto_accept': autoAccept,
        'lan_port': lanPort,
        'clip_sync': clipSync,
        'clip_images': clipImages,
        'custom_clip_url': customClipUrl,
        'custom_clip_user': customClipUser,
        'custom_clip_pass': customClipPass,
        'offline_fallback': offlineFallback,
        'explorer_menu': explorerMenu,
        'launch_at_login': launchAtLogin,
        'start_on_boot': startOnBoot,
        'use_root_clipboard': useRootClipboard,
      };

  static Future<AppConfig?> load(File f) async {
    if (!await f.exists()) return null;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      var canScrub = await SecureStore.hydrateConfigJson(j);
      final diskClipPass = (j['custom_clip_pass'] as String?) ?? '';
      if (diskClipPass.isEmpty) {
        final storedClipPass = await SecureStore.read(SecureStore.keyClipPassword);
        if (storedClipPass != null && storedClipPass.isNotEmpty) {
          j['custom_clip_pass'] = storedClipPass;
        }
      } else if (await SecureStore.write(SecureStore.keyClipPassword, diskClipPass)) {
        canScrub = true;
      }
      final cfg = AppConfig.fromJson(j);
      if (canScrub) {
        await cfg.save(f);
      }
      return cfg;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(File f) async {
    await f.parent.create(recursive: true);
    final scrubbed = await SecureStore.scrubConfigJson(toJson());
    if (customClipPass.isNotEmpty) {
      if (await SecureStore.write(SecureStore.keyClipPassword, customClipPass)) {
        scrubbed['custom_clip_pass'] = '';
      }
    } else {
      await SecureStore.delete(SecureStore.keyClipPassword);
    }
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(scrubbed));
    await tmp.rename(f.path);
  }

  String get outboxDir => p.join(stateDir, 'outbox');
  String get partialDir => p.join(recvDir, '.synchub-partial');

  /// Same defaults as the existing SyncHub auto-receive folders.
  static String defaultRecvDir() {
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
    if (Platform.isWindows) {
      if (Directory(r'K:\').existsSync()) return r'K:\跨端传输文件';
      return p.join(home, 'Downloads', '跨端传输文件');
    }
    if (Platform.isMacOS) return p.join(home, 'Desktop', '跨端传输文件');
    if (Platform.isAndroid) return '/storage/emulated/0/Download/跨端传输';
    return p.join(home, '跨端传输文件');
  }

  static String platformLabel() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return Platform.operatingSystem;
  }
}
