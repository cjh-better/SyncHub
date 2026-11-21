import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/e2e.dart';
import '../core/engine.dart';
import '../core/hub_api.dart';
import '../platform/platform_bridge.dart';
import '../platform/tray_ownership.dart';
import '../platform/win_integration.dart';
import 'theme.dart';

class SettingsPage extends StatefulWidget {
  final Engine engine;
  const SettingsPage({super.key, required this.engine});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _launchAtLogin = PlatformBridge.instance?.launchAtLogin ?? false;
  bool _legacyWinReceiverActive = false;
  bool _disablingLegacyWin = false;
  bool _trayBusy = false;
  OfficialClipboardPresence _official = const OfficialClipboardPresence.absent();
  String? _handoffBackup;
  Map<String, dynamic> _androidCaps = const <String, dynamic>{};
  bool _loadingAndroidCaps = false;

  Engine get engine => widget.engine;

  @override
  void initState() {
    super.initState();
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      unawaited(_refreshPlatformStates());
    }
  }

  Future<void> _refreshPlatformStates() async {
    if (PlatformBridge.isDesktop) {
      try {
        final v = await PlatformBridge.desktopChannel.invokeMethod<bool>('getLaunchAtLogin');
        if (mounted && v != null) setState(() => _launchAtLogin = v);
      } catch (_) {}
      if (Platform.isWindows) {
        final legacy = await WinIntegration.detectLegacyAutoReceiver();
        final official = await WinIntegration.inspectOfficialClipboard();
        if (mounted) {
          setState(() {
            _legacyWinReceiverActive = legacy;
            _official = official;
          });
        }
      }
    } else if (Platform.isAndroid) {
      if (mounted) setState(() => _loadingAndroidCaps = true);
      final caps = await (PlatformBridge.instance?.getAndroidCapabilities() ??
          Future.value(const <String, dynamic>{}));
      if (mounted) {
        setState(() {
          _androidCaps = caps;
          _loadingAndroidCaps = false;
        });
      }
    }
  }

  Future<void> _backupTrayStartup() async {
    setState(() => _trayBusy = true);
    final dir = await WinIntegration.backupOfficialStartup();
    if (!mounted) return;
    setState(() {
      _trayBusy = false;
      if (dir != null) _handoffBackup = dir;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(dir == null ? '备份失败，未改动启动项' : '已备份启动项到 $dir')),
    );
  }

  Future<void> _confirmTrayTakeover() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('只保留 SyncHub 托盘'),
        content: const Text(
          '会先备份开机启动项，再禁用 SyncClipboard 的计划任务和登录启动项，并退出 SyncClipboard。\n\n'
          '不删除 SyncClipboard 程序、配置、历史或已接收的文件。凭据只写入本机系统安全存储。\n'
          '若剪贴板不正常，可以用「恢复旧自启」把开机项改回去。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认接管')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _trayBusy = true);
    final backup = _handoffBackup ?? await WinIntegration.backupOfficialStartup();
    if (backup == null) {
      if (!mounted) return;
      setState(() => _trayBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('备份失败，未改动启动项')));
      return;
    }
    final login = await WinIntegration.readLegacySyncClipboardLogin();
    if (login != null) {
      await engine.updateConfig((c) {
        if (c.customClipUrl.trim().isEmpty) {
          c.customClipUrl = login.serverUrl;
          c.customClipUser = login.username;
          if (login.password.isNotEmpty) c.customClipPass = login.password;
        } else if (c.customClipPass.isEmpty && login.password.isNotEmpty) {
          c.customClipPass = login.password;
        }
      });
    }
    final msg = await WinIntegration.disableOfficialStartup(backupDir: backup, stopProcess: true);
    await PlatformBridge.instance?.refreshClipboardDuty();
    await _refreshPlatformStates();
    if (!mounted) return;
    setState(() {
      _trayBusy = false;
      _handoffBackup = backup;
    });
    final note = login == null ? msg : '$msg\n${WinIntegration.describeLogin(login)}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(note)));
  }

  Future<void> _rollbackTrayStartup() async {
    final dir = _handoffBackup;
    if (dir == null) return;
    setState(() => _trayBusy = true);
    final msg = await WinIntegration.rollbackOfficialStartup(dir);
    await PlatformBridge.instance?.refreshClipboardDuty();
    await _refreshPlatformStates();
    if (!mounted) return;
    setState(() => _trayBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _showPairing(BuildContext context) async {
    try {
      final (code, exp) = await engine.pairingCode();
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('添加设备'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('在新设备上选择「配对码」登录，输入：'),
            const SizedBox(height: 16),
            SelectableText(
              code,
              style: const TextStyle(
                fontSize: 40,
                letterSpacing: 8,
                fontWeight: FontWeight.w600,
                color: kAccent,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${TimeOfDay.fromDateTime(exp).format(context)} 前有效，仅可使用一次',
              style: const TextStyle(color: kText2),
            ),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('完成'))],
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('获取配对码失败：$e')));
      }
    }
  }

  Future<void> _rename(BuildContext context) async {
    final ctl = TextEditingController(text: engine.cfg!.name);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('设备名称'),
        content: TextField(controller: ctl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await engine.api.rename(name);
      await engine.updateConfig((c) => c.name = name);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _pickRecvDir() async {
    final d = await FilePicker.getDirectoryPath(dialogTitle: '选择接收文件夹');
    if (d != null) await engine.updateConfig((c) => c.recvDir = d);
  }

  Future<void> _revoke(BuildContext context, String id, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('移除「$name」？'),
        content: const Text('该设备将立即断开，需要重新登录才能再次使用。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kRed),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok == true) await engine.revoke(id);
  }

  Future<void> _runAndroidRootSetup() async {
    try {
      final raw = await PlatformBridge.nativeChannel.invokeMethod<dynamic>(
        'runRootSetup',
        <String, dynamic>{'hideClipboardToast': true},
      );
      await _refreshPlatformStates();
      if (_androidCaps['hasAllFilesAccess'] == true &&
          !(engine.cfg!.recvDir.startsWith('/storage/emulated/0/'))) {
        await engine.updateConfig(
          (c) => c.recvDir = '/storage/emulated/0/Download/跨端传输',
        );
      }
      if (!mounted) return;
      final String steps;
      if (raw is Map && raw['rootGranted'] == false) {
        steps = '未获取到 Root 授权。\n请先在 KernelSU / APatch / Magisk 的「超级用户」列表中为 SyncHub 开启 Root 权限，再返回点击配置。';
      } else if (raw is Map && raw['steps'] is List && (raw['steps'] as List).isNotEmpty) {
        steps = (raw['steps'] as List)
            .whereType<Map>()
            .map((m) => '${m['ok'] == true ? '✓' : '✗'} ${m['name'] ?? m['title'] ?? m['step'] ?? ''}${m['detail'] != null && '${m['detail']}'.isNotEmpty ? ' — ${m['detail']}' : ''}')
            .join('\n');
      } else {
        steps = '已完成 Root 权限与后台静默剪贴板配置。';
      }
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Root 一键配置结果'),
          content: SingleChildScrollView(child: SelectableText(steps)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('完成')),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Root 配置失败：$e')));
      }
    }
  }

  Future<void> _removeOldAndroidRootScript() async {
    try {
      await PlatformBridge.nativeChannel.invokeMethod<dynamic>('removeOldRootScript');
      await _refreshPlatformStates();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已清理旧版 Magisk 脚本并停止旧守护进程')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('清理失败：$e')));
      }
    }
  }

  Future<void> _showLogsDialog(BuildContext context) async {
    var combined = engine.logLines.join('\n');
    if (Platform.isAndroid) {
      try {
        final nativeLogs = await PlatformBridge.nativeChannel.invokeMethod<dynamic>('getLogs');
        if (nativeLogs is List && nativeLogs.isNotEmpty) {
          combined = '$combined\n\n--- Android Native Service Logs ---\n${nativeLogs.join('\n')}';
        } else if (nativeLogs is String && nativeLogs.isNotEmpty) {
          combined = '$combined\n\n--- Android Native Service Logs ---\n$nativeLogs';
        }
      } catch (_) {}
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('运行日志'),
        content: SizedBox(
          width: 640,
          height: 420,
          child: SingleChildScrollView(
            child: SelectableText(
              combined.isEmpty ? '（暂无日志）' : combined,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: combined)),
            child: const Text('复制'),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = engine.cfg!;
    final me = engine.devices[engine.self];

    Widget section(String title, List<Widget> children) => Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Text(title, style: const TextStyle(color: kText2, fontSize: 13)),
            ),
            Card(
              child: Column(children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const Divider(indent: 16),
                  children[i],
                ],
              ]),
            ),
          ]),
        );

    final compact = MediaQuery.sizeOf(context).width < 560;
    return ListView(padding: EdgeInsets.all(compact ? 16 : 24), children: [
      Text(
        '设置',
        style: Theme.of(context)
            .textTheme
            .headlineSmall
            ?.copyWith(fontWeight: FontWeight.w600, fontSize: compact ? 22 : null),
      ),
      const SizedBox(height: 16),
      section('本机', [
        ListTile(
          title: const Text('设备名称'),
          subtitle: Text(c.name),
          trailing: const Icon(Icons.edit_outlined),
          onTap: () => _rename(context),
        ),
        ListTile(
          title: const Text('接收文件夹'),
          subtitle: Text(c.recvDir),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (PlatformBridge.isDesktop)
                IconButton(
                  tooltip: '打开接收文件夹',
                  icon: const Icon(Icons.open_in_new_rounded),
                  onPressed: () => PlatformBridge.openFile(c.recvDir),
                ),
              const Icon(Icons.folder_outlined),
            ],
          ),
          onTap: _pickRecvDir,
        ),
        ListTile(
          title: const Text('密钥指纹'),
          subtitle: Text(me != null ? fingerprint(me.publicKey) : '—'),
          trailing: const Icon(Icons.verified_user_outlined),
        ),
        ListTile(
          title: const Text('局域网直连'),
          subtitle: Text(engine.lanUrls.isEmpty ? '未启用' : engine.lanUrls.join('\n')),
        ),
      ]),
      section('传输与剪贴板', [
        SwitchListTile(
          title: const Text('自动接收我的设备文件'),
          subtitle: const Text('关闭后每次收到文件前会在顶部与系统通知中弹窗确认'),
          value: c.autoAccept,
          onChanged: (v) => engine.updateConfig((cfg) => cfg.autoAccept = v),
        ),
        SwitchListTile(
          title: const Text('对方离线时自动转为云端投递'),
          subtitle: const Text('当目标设备不在线时上传至自建 SyncHub 云端，对方上线后自动后台拉取'),
          value: c.offlineFallback,
          onChanged: (v) => engine.updateConfig((cfg) => cfg.offlineFallback = v),
        ),
        SwitchListTile(
          title: const Text('剪贴板双向自动同步'),
          subtitle: const Text('兼容 SyncClipboard 协议，自动跳过密码管理器隐私内容'),
          value: c.clipSync,
          onChanged: (v) => engine.updateConfig((cfg) => cfg.clipSync = v),
        ),
        SwitchListTile(
          title: const Text('同步剪贴板图片与复制的小文件'),
          subtitle: const Text('支持截图、图片与 ≤20MB 单文件跨端同步'),
          value: c.clipImages,
          onChanged: c.clipSync
              ? (v) => engine.updateConfig((cfg) => cfg.clipImages = v)
              : null,
        ),
      ]),
      if (PlatformBridge.isDesktop)
        section('系统集成', [
          SwitchListTile(
            title: const Text('开机自动启动'),
            subtitle: const Text('登录系统后静默驻留托盘 / 菜单栏，随时接收文件与剪贴板'),
            value: _launchAtLogin,
            onChanged: (v) async {
              await PlatformBridge.instance?.setLaunchAtLogin(v);
              if (mounted) {
                setState(() => _launchAtLogin = PlatformBridge.instance?.launchAtLogin ?? v);
              }
            },
          ),
          if (Platform.isWindows)
            SwitchListTile(
              title: const Text('资源管理器右键菜单（「发送到 SyncHub」）'),
              subtitle: const Text('在任意文件或文件夹右键一键发送到指定设备或云端收藏'),
              value: c.explorerMenu,
              onChanged: (v) => engine.updateConfig((cfg) => cfg.explorerMenu = v),
            ),
          if (Platform.isWindows && _legacyWinReceiverActive)
            ListTile(
              leading: const Icon(Icons.warning_amber_rounded, color: kOrange),
              title: const Text('检测到旧版 SyncHubAutoReceiver 脚本正在运行'),
              subtitle: const Text('建议一键停用旧脚本，避免重复拉取文件。这只停用 Python 接收器，不会改 SyncClipboard。'),
              trailing: FilledButton.tonal(
                onPressed: _disablingLegacyWin
                    ? null
                    : () async {
                        setState(() => _disablingLegacyWin = true);
                        final ok = await WinIntegration.disableLegacyAutoReceiver();
                        await _refreshPlatformStates();
                        if (context.mounted) {
                          setState(() => _disablingLegacyWin = false);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(ok ? '已停用旧版后台脚本并清理旧右键菜单' : '停用未完成，请确认 UAC 授权'),
                            ),
                          );
                        }
                      },
                child: Text(_disablingLegacyWin ? '处理中…' : '一键停用'),
              ),
            ),
          if (Platform.isWindows)
            ListTile(
              leading: Icon(
                _official.processRunning ? Icons.pause_circle_outline : Icons.check_circle_outline,
                color: _official.processRunning ? kOrange : kGreen,
              ),
              title: Text(_official.processRunning ? '当前有两个托盘' : '剪贴板由 SyncHub 负责'),
              subtitle: Text(
                _official.processRunning
                    ? 'SyncClipboard 正在运行，SyncHub 已暂停剪贴板监视，避免重复上传。文件收发不受影响。确认接管后只保留 SyncHub 托盘，不删除原程序、配置或历史。'
                    : '未发现正在运行的 SyncClipboard。开机项${_official.startupTaskEnabled ? '仍会启动它' : '未启用'}。快捷键 Ctrl+Shift+V 发送当前剪贴板。',
              ),
            ),
          if (Platform.isWindows)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _trayBusy ? null : _backupTrayStartup,
                    child: const Text('只备份启动项'),
                  ),
                  FilledButton(
                    onPressed: _trayBusy ? null : _confirmTrayTakeover,
                    child: Text(_trayBusy ? '处理中…' : '确认接管'),
                  ),
                  TextButton(
                    onPressed: _trayBusy || _handoffBackup == null ? null : _rollbackTrayStartup,
                    child: const Text('恢复旧自启'),
                  ),
                ],
              ),
            ),
          if (Platform.isMacOS)
            const ListTile(
              leading: Icon(Icons.auto_awesome_outlined, color: kAccent),
              title: Text('Finder 快速操作与系统服务'),
              subtitle: Text('已自动安装「发送到跨端传输中心」右键菜单及选中文本服务'),
            ),
          ListTile(
            leading: const Icon(Icons.open_in_browser_rounded, color: kAccent),
            title: const Text('在浏览器打开云端收藏网页 (/hub/)'),
            subtitle: Text('${HubApi.deriveOrigin(c.server)}/hub/'),
            onTap: () => PlatformBridge.openUrl('${HubApi.deriveOrigin(c.server)}/hub/'),
          ),
        ]),
      if (Platform.isAndroid)
        section('Android 后台保活与静默剪贴板', [
          ListTile(
            leading: const Icon(Icons.shield_outlined, color: kAccent),
            title: Text('当前剪贴板模式：${_androidCaps['clipModeLabel'] ?? '检测中…'}'),
            subtitle: Text(
              (_androidCaps['clipHint'] as String?)?.isNotEmpty == true
                  ? '${_androidCaps['clipHint']}'
                  : '支持 LSPosed 系统级 Hook / Root 守护进程 / 前台通知与磁贴三合一降级',
            ),
            trailing: IconButton(
              tooltip: '刷新状态',
              icon: _loadingAndroidCaps
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh_rounded),
              onPressed: _refreshPlatformStates,
            ),
          ),
          ListTile(
            leading: Icon(
              _androidCaps['lsposedActive'] == true ? Icons.check_circle_rounded : Icons.extension_outlined,
              color: _androidCaps['lsposedActive'] == true ? kGreen : kText2,
            ),
            title: Text(
              'LSPosed 模块：${_androidCaps['lsposedActive'] == true ? (_androidCaps['systemHookLabel'] ?? '已激活') : '未激活（可选）'}',
            ),
            subtitle: Text(
              _androidCaps['lsposedActive'] == true
                  ? ((_androidCaps['systemHookDetail'] as String?) ?? '已在应用进程激活')
                  : '在 LSPosed 管理器中启用 SyncHub 并勾选「系统框架 (android)」重启即可免无障碍后台同步剪贴板',
            ),
          ),
          ListTile(
            leading: Icon(
              _androidCaps['rootGranted'] == true ? Icons.verified_rounded : Icons.admin_panel_settings_outlined,
              color: _androidCaps['rootGranted'] == true ? kGreen : kText2,
            ),
            title: Text(
              'Root 超级用户授权：${_androidCaps['rootGranted'] == true ? '已识别 (uid=0)' : '未授权（可选）'}',
            ),
            subtitle: Text(
              _androidCaps['rootGranted'] == true
                  ? (_androidCaps['rootHelperAlive'] == true
                      ? 'Root 守护进程运行中，支持后台静默读取与免拦截写入手机剪贴板'
                      : '已识别 Root 权限，可在 LSPosed 未重启生效时自动无缝接管后台剪贴板')
                  : '若使用 KernelSU / APatch / Magisk，在管理器开启 SyncHub 权限后点右上角刷新即可自动识别',
            ),
          ),
          SwitchListTile(
            title: const Text('开机自动启动后台同步服务'),
            subtitle: const Text('重启或更新应用后自动恢复收发与剪贴板守护'),
            value: c.startOnBoot,
            onChanged: (v) => engine.updateConfig((cfg) => cfg.startOnBoot = v),
          ),
          SwitchListTile(
            title: const Text('启用 Root 静默剪贴板守护'),
            subtitle: Text(
              _androidCaps['rootHelperAlive'] == true
                  ? 'Root app_process 守护进程运行中'
                  : '未启用 LSPosed 时可通过 Root 静默读写后台剪贴板',
            ),
            value: c.useRootClipboard,
            onChanged: (v) => engine.updateConfig((cfg) => cfg.useRootClipboard = v),
          ),
          ListTile(
            leading: const Icon(Icons.bolt_rounded, color: kOrange),
            title: const Text('Root 一键授权全部权限与静默剪贴板'),
            subtitle: const Text('自动授予文件访问、通知、电池白名单、READ_LOGS 并隐藏剪贴板吐司'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _runAndroidRootSetup,
          ),
          if (_androidCaps['oldRootScriptPresent'] == true)
            ListTile(
              leading: const Icon(Icons.cleaning_services_outlined, color: kOrange),
              title: const Text('清理旧版 Magisk 脚本 (/data/adb/service.d)'),
              subtitle: const Text('检测到旧版 Root 同步脚本，点击一键移除避免重复运行'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _removeOldAndroidRootScript,
            ),
          ListTile(
            leading: Icon(
              _androidCaps['hasAllFilesAccess'] == true ? Icons.check_circle_rounded : Icons.folder_special_outlined,
              color: _androidCaps['hasAllFilesAccess'] == true ? kGreen : kOrange,
            ),
            title: const Text('所有文件访问权限 (/Download/跨端传输)'),
            subtitle: Text(_androidCaps['hasAllFilesAccess'] == true ? '已授权' : '点击前往授权，使接收文件直接落盘到 Download/跨端传输'),
            onTap: () async {
              try {
                await PlatformBridge.nativeChannel.invokeMethod<void>('requestAllFilesAccess');
                await Future<void>.delayed(const Duration(seconds: 1));
                await _refreshPlatformStates();
                if (_androidCaps['hasAllFilesAccess'] == true) {
                  await engine.updateConfig(
                    (cfg) => cfg.recvDir = '/storage/emulated/0/Download/跨端传输',
                  );
                }
              } catch (_) {}
            },
          ),
          ListTile(
            leading: Icon(
              _androidCaps['isIgnoringBatteryOptimizations'] == true
                  ? Icons.check_circle_rounded
                  : Icons.battery_saver_outlined,
              color: _androidCaps['isIgnoringBatteryOptimizations'] == true ? kGreen : kOrange,
            ),
            title: const Text('忽略电池优化（后台保活白名单）'),
            subtitle: Text(_androidCaps['isIgnoringBatteryOptimizations'] == true ? '已加入白名单' : '点击申请加入后台省电白名单'),
            onTap: () async {
              try {
                await PlatformBridge.nativeChannel.invokeMethod<void>('requestIgnoreBatteryOptimizations');
                await Future<void>.delayed(const Duration(seconds: 1));
                await _refreshPlatformStates();
              } catch (_) {}
            },
          ),
          ListTile(
            leading: Icon(
              _androidCaps['hasNotificationPermission'] == true
                  ? Icons.check_circle_rounded
                  : Icons.notifications_outlined,
              color: _androidCaps['hasNotificationPermission'] == true ? kGreen : kOrange,
            ),
            title: const Text('通知权限'),
            subtitle: Text(_androidCaps['hasNotificationPermission'] == true ? '已授权' : '点击授予通知权限以显示传输进度与完成提醒'),
            onTap: () async {
              try {
                await PlatformBridge.nativeChannel.invokeMethod<void>('requestNotificationPermission');
                await Future<void>.delayed(const Duration(seconds: 1));
                await _refreshPlatformStates();
              } catch (_) {}
            },
          ),
        ]),
      section('设备', [
        ListTile(
          leading: const Icon(Icons.add_circle_outline, color: kAccent),
          title: const Text('添加设备（获取配对码）'),
          onTap: () => _showPairing(context),
        ),
        for (final d in engine.devices.values)
          ListTile(
            leading: Icon(platformIcon(d.platform)),
            title: Text(d.id == engine.self ? '${d.name}（本机）' : d.name),
            subtitle: Text('${d.online ? '在线' : '离线'} · 指纹 ${fingerprint(d.publicKey)}'),
            trailing: d.id == engine.self
                ? null
                : IconButton(
                    tooltip: '移除',
                    icon: const Icon(Icons.remove_circle_outline, color: kRed),
                    onPressed: () => _revoke(context, d.id, d.name),
                  ),
          ),
      ]),
      section('服务器', [
        ListTile(title: const Text('网关'), subtitle: Text(c.server)),
        ListTile(title: const Text('状态'), subtitle: Text(engine.status)),
        ListTile(
          title: const Text('运行日志'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showLogsDialog(context),
        ),
        ListTile(
          title: const Text('退出登录并移除本机', style: TextStyle(color: kRed)),
          onTap: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('退出登录？'),
                content: const Text('本机会从设备列表中移除，未完成的发送任务会保留在本地。'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                  FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('退出')),
                ],
              ),
            );
            if (ok == true) await engine.signOut();
          },
        ),
      ]),
    ]);
  }
}
