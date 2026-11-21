import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'tray_ownership.dart';

/// Windows Explorer context-menu registration, legacy SyncHub state/account
/// migration, and legacy `\SyncHubAutoReceiver` detection & cleanup.
class WinIntegration {
  WinIntegration._();

  static const String _starShellKey = r'HKEY_CURRENT_USER\Software\Classes\*\shell\SyncHub';
  static const String _dirShellKey = r'HKEY_CURRENT_USER\Software\Classes\Directory\shell\SyncHub';
  static const String _subMenuRootKey = r'HKEY_CURRENT_USER\Software\Classes\SyncHub.ContextMenu';

  static Future<void> _regMutex = Future.value();

  static Future<T> _withRegLock<T>(Future<T> Function() action) {
    final prev = _regMutex;
    final completer = Completer<void>();
    _regMutex = completer.future;
    return prev.then((_) => action()).whenComplete(completer.complete);
  }

  static String? _appDataDir() {
    final env = Platform.environment;
    final appData = env['APPDATA'];
    if (appData != null && appData.isNotEmpty) return appData;
    final profile = env['USERPROFILE'];
    if (profile != null && profile.isNotEmpty) {
      return p.join(profile, 'AppData', 'Roaming');
    }
    return null;
  }

  static String _stripBom(String text) =>
      text.startsWith('\uFEFF') ? text.substring(1) : text;

  /// Reads `%APPDATA%\SyncClipboard\synchub_win_state.json` and returns
  /// `last_id` (or `0` if missing/invalid). If [targetStateFile] is provided,
  /// merges `last_id` into that JSON file when greater than any existing value.
  static Future<int> migrateLegacyHubLastId({String? targetStateFile}) async {
    if (!Platform.isWindows) return 0;
    final appData = _appDataDir();
    if (appData == null) return 0;

    final legacyFile = File(p.join(appData, 'SyncClipboard', 'synchub_win_state.json'));
    if (!await legacyFile.exists()) return 0;

    var lastId = 0;
    try {
      final raw = _stripBom(await legacyFile.readAsString());
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final v = decoded['last_id'];
        if (v is int) {
          lastId = v;
        } else if (v is num) {
          lastId = v.toInt();
        } else if (v is String) {
          lastId = int.tryParse(v) ?? 0;
        }
      }
    } catch (_) {
      return 0;
    }

    if (lastId < 0) lastId = 0;

    if (targetStateFile != null && targetStateFile.isNotEmpty && lastId > 0) {
      try {
        final dst = File(targetStateFile);
        var existingId = 0;
        if (await dst.exists()) {
          final existingRaw = _stripBom(await dst.readAsString());
          final existingJson = jsonDecode(existingRaw);
          if (existingJson is Map && existingJson['last_id'] is num) {
            existingId = (existingJson['last_id'] as num).toInt();
          }
        }
        if (lastId > existingId) {
          await dst.parent.create(recursive: true);
          final tmp = File('${dst.path}.tmp');
          await tmp.writeAsString(jsonEncode({
            'last_id': lastId,
            'updated_at': DateTime.now().millisecondsSinceEpoch / 1000.0,
          }));
          await tmp.rename(dst.path);
        }
      } catch (_) {}
    }

    return lastId;
  }

  /// Reads `%APPDATA%\SyncClipboard\SyncClipboard.json` (stripping UTF-8 BOM)
  /// to extract `(serverUrl, username)` for onboarding convenience.
  static Future<({String serverUrl, String username})?> readLegacySyncClipboardAccount() async {
    if (!Platform.isWindows) return null;
    final appData = _appDataDir();
    if (appData == null) return null;

    final cfgFile = File(p.join(appData, 'SyncClipboard', 'SyncClipboard.json'));
    if (!await cfgFile.exists()) return null;

    try {
      final raw = _stripBom(await cfgFile.readAsString());
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;

      String serverUrl = '';
      String username = '';

      final savedAccounts = decoded['SavedAccounts'];
      if (savedAccounts is Map) {
        final scAccounts = savedAccounts['SyncClipboard'];
        if (scAccounts is Map && scAccounts.isNotEmpty) {
          final accountMeta = decoded['Account'];
          final activeId = accountMeta is Map ? (accountMeta['AccountId']?.toString() ?? '') : '';
          Object? chosen = activeId.isNotEmpty ? scAccounts[activeId] : null;
          chosen ??= scAccounts.values.first;
          if (chosen is Map) {
            serverUrl = (chosen['RemoteURL'] ?? chosen['Url'] ?? '').toString().trim();
            username = (chosen['UserName'] ?? '').toString().trim();
          }
        }
      }

      if (serverUrl.isEmpty) {
        final syncService = decoded['SyncService'];
        if (syncService is Map) {
          serverUrl = (syncService['RemoteURL'] ?? syncService['Url'] ?? '').toString().trim();
          username = (syncService['UserName'] ?? username).toString().trim();
        }
      }

      serverUrl = serverUrl.replaceAll(RegExp(r'/+$'), '');
      if (serverUrl.isEmpty) return null;
      return (serverUrl: serverUrl, username: username);
    } catch (_) {
      return null;
    }
  }

  /// Escapes `&` -> `&&` for Win32 Explorer `MUIVerb` labels and strips newlines.
  static String _escapeMuiVerb(String name) =>
      name.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim().replaceAll('&', '&&');

  /// Escapes backslashes and quotes for `.reg` string literals.
  static String _escapeRegString(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

  static String _sanitizeKeySegment(String id) {
    final cleaned = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    if (cleaned.isEmpty) return 'dev';
    return cleaned.length > 32 ? cleaned.substring(0, 32) : cleaned;
  }

  static Uint8List _encodeUtf16LeWithBom(String content) {
    final units = content.codeUnits;
    final data = ByteData((units.length + 1) * 2);
    data.setUint16(0, 0xFEFF, Endian.little);
    for (var i = 0; i < units.length; i++) {
      data.setUint16((i + 1) * 2, units[i], Endian.little);
    }
    return data.buffer.asUint8List();
  }

  static Uint8List _encodeUtf16LeNoBom(String content) {
    final units = content.codeUnits;
    final data = ByteData(units.length * 2);
    for (var i = 0; i < units.length; i++) {
      data.setUint16(i * 2, units[i], Endian.little);
    }
    return data.buffer.asUint8List();
  }

  static Future<bool> _importRegContent(String regBody) async {
    final tempDir = await Directory.systemTemp.createTemp('synchub_reg_');
    final regFile = File(p.join(tempDir.path, 'context_menu.reg'));
    try {
      await regFile.writeAsBytes(_encodeUtf16LeWithBom(regBody), flush: true);
      final res = await Process.run('reg.exe', ['import', regFile.path]);
      return res.exitCode == 0;
    } catch (_) {
      return false;
    } finally {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Registers the cascading `发送到 SyncHub` context menu on files (`*`) and
  /// folders (`Directory`) under `HKCU\Software\Classes` (no admin needed).
  static Future<bool> registerContextMenu({
    required String exePath,
    required List<({String id, String name, bool online})> devices,
  }) {
    if (!Platform.isWindows || exePath.isEmpty) return Future.value(false);

    return _withRegLock(() async {
      final cleanExe = exePath.replaceAll('"', '');
      final iconVal = _escapeRegString('"$cleanExe",0');
      final buf = StringBuffer()
        ..write('Windows Registry Editor Version 5.00\r\n\r\n')
        ..write('[-$_subMenuRootKey]\r\n\r\n');

      for (final rootKey in [_starShellKey, _dirShellKey]) {
        buf
          ..write('[$rootKey]\r\n')
          ..write('"MUIVerb"="${_escapeRegString('发送到 SyncHub')}"\r\n')
          ..write('"Icon"="$iconVal"\r\n')
          ..write('"MultiSelectModel"="Player"\r\n')
          ..write('"ExtendedSubCommandsKey"="SyncHub.ContextMenu"\r\n\r\n');
      }

      if (devices.isEmpty) {
        final pickKey = '$_subMenuRootKey\\shell\\01_pick';
        final pickCmd = _escapeRegString('"$cleanExe" --send "%1"');
        buf
          ..write('[$pickKey]\r\n')
          ..write('"MUIVerb"="${_escapeRegString('选择设备发送…')}"\r\n\r\n')
          ..write('[$pickKey\\command]\r\n')
          ..write('@="$pickCmd"\r\n\r\n');
      } else {
        for (var idx = 0; idx < devices.length; idx++) {
          final d = devices[idx];
          final safeId = d.id.replaceAll('"', '');
          if (safeId.isEmpty) continue;
          final idxStr = idx.toString().padLeft(2, '0');
          final subKey = '$_subMenuRootKey\\shell\\01_dev_${idxStr}_${_sanitizeKeySegment(safeId)}';
          final baseLabel = _escapeMuiVerb(d.name.isNotEmpty ? d.name : safeId);
          final verbLabel = '$baseLabel (${d.online ? '在线' : '离线'})';
          final devCmd = _escapeRegString('"$cleanExe" --send --to "$safeId" "%1"');
          buf
            ..write('[$subKey]\r\n')
            ..write('"MUIVerb"="${_escapeRegString(verbLabel)}"\r\n\r\n')
            ..write('[$subKey\\command]\r\n')
            ..write('@="$devCmd"\r\n\r\n');
        }
      }

      final cloudStarKey = '$_subMenuRootKey\\shell\\90_cloud';
      final cloudStarCmd = _escapeRegString('"$cleanExe" --send --cloud --star "%1"');
      buf
        ..write('[$cloudStarKey]\r\n')
        ..write('"MUIVerb"="${_escapeRegString('存到云端收藏')}"\r\n')
        ..write('"CommandFlags"=dword:00000020\r\n\r\n')
        ..write('[$cloudStarKey\\command]\r\n')
        ..write('@="$cloudStarCmd"\r\n\r\n');

      final cloudTempKey = '$_subMenuRootKey\\shell\\91_cloud_temp';
      final cloudTempCmd = _escapeRegString('"$cleanExe" --send --cloud "%1"');
      buf
        ..write('[$cloudTempKey]\r\n')
        ..write('"MUIVerb"="${_escapeRegString('发送到云端中转 (72小时)')}"\r\n\r\n')
        ..write('[$cloudTempKey\\command]\r\n')
        ..write('@="$cloudTempCmd"\r\n\r\n');

      return _importRegContent(buf.toString());
    });
  }

  /// Removes `SyncHub` Explorer context-menu keys cleanly under `HKCU`.
  static Future<bool> unregisterContextMenu() {
    if (!Platform.isWindows) return Future.value(false);

    return _withRegLock(() async {
      final regBody = [
        'Windows Registry Editor Version 5.00',
        '',
        '[-$_starShellKey]',
        '[-$_dirShellKey]',
        '[-$_subMenuRootKey]',
        '',
      ].join('\r\n');
      return _importRegContent(regBody);
    });
  }

  /// Checks whether the `发送到 SyncHub` Explorer context menu is registered.
  static Future<bool> isContextMenuRegistered() async {
    if (!Platform.isWindows) return false;
    try {
      final res = await Process.run('reg.exe', [
        'query',
        r'HKCU\Software\Classes\*\shell\SyncHub',
        '/v',
        'ExtendedSubCommandsKey',
      ]);
      return res.exitCode == 0 &&
          res.stdout.toString().contains('SyncHub.ContextMenu');
    } catch (_) {
      return false;
    }
  }

  /// Checks whether the legacy `\SyncHubAutoReceiver` scheduled task is active
  /// or any `synchub_client.py` background daemon process is running.
  /// Never matches plain `pythonw.exe` without `synchub_client.py` in CommandLine.
  static Future<bool> detectLegacyAutoReceiver() async {
    if (!Platform.isWindows) return false;

    try {
      final csvRes = await Process.run(
        'schtasks.exe',
        ['/Query', '/TN', r'\SyncHubAutoReceiver', '/FO', 'CSV', '/NH'],
      );
      if (csvRes.exitCode == 0) {
        final csvOut = csvRes.stdout.toString().trim();
        if (csvOut.isNotEmpty) {
          final xmlRes = await Process.run(
            'schtasks.exe',
            ['/Query', '/TN', r'\SyncHubAutoReceiver', '/XML'],
          );
          if (xmlRes.exitCode == 0) {
            final xml = xmlRes.stdout.toString();
            final explicitlyDisabled = RegExp(
              r'<Enabled>\s*false\s*</Enabled>',
              caseSensitive: false,
            ).hasMatch(xml);
            if (!explicitlyDisabled) return true;
          } else {
            final lower = csvOut.toLowerCase();
            if (!lower.contains('disabled') && !csvOut.contains('已禁用')) {
              return true;
            }
          }
        }
      }
    } catch (_) {}

    try {
      const psQuery =
          r"@(Get-CimInstance Win32_Process -Filter ""Name = 'python.exe' OR Name = 'pythonw.exe'"" "
          r"-ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*synchub_client.py*' }).Count";
      final encoded = base64Encode(_encodeUtf16LeNoBom(psQuery));
      final procRes = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-EncodedCommand',
        encoded,
      ]);
      if (procRes.exitCode == 0) {
        final count = int.tryParse(procRes.stdout.toString().trim()) ?? 0;
        if (count > 0) return true;
      }
    } catch (_) {}

    return false;
  }

  /// Removes legacy `SyncHubSend` / `SyncHubSendStar` Explorer verbs under HKCU
  /// and runs an elevated PowerShell (`-Verb RunAs`) to disable
  /// `\SyncHubAutoReceiver` and stop only `synchub_client.py` processes
  /// (leaving `\SyncClipboardStartup` completely untouched).
  static Future<bool> disableLegacyAutoReceiver() async {
    if (!Platform.isWindows) return false;

    // 1. Delete legacy HKCU context-menu verbs immediately (no admin needed).
    await _withRegLock(() async {
      final legacyCleanupReg = [
        'Windows Registry Editor Version 5.00',
        '',
        r'[-HKEY_CURRENT_USER\Software\Classes\*\shell\SyncHubSend]',
        r'[-HKEY_CURRENT_USER\Software\Classes\*\shell\SyncHubSendStar]',
        r'[-HKEY_CURRENT_USER\Software\Classes\Directory\shell\SyncHubSend]',
        r'[-HKEY_CURRENT_USER\Software\Classes\Directory\shell\SyncHubSendStar]',
        '',
      ].join('\r\n');
      await _importRegContent(legacyCleanupReg);
    });

    if (!await detectLegacyAutoReceiver()) {
      return true;
    }

    // 2. Run elevated PowerShell to disable \SyncHubAutoReceiver and terminate
    // only python/pythonw processes running synchub_client.py.
    const innerElevatedScript = r'''
$ErrorActionPreference = 'SilentlyContinue'
& schtasks.exe /End /TN "\SyncHubAutoReceiver" *> $null
& schtasks.exe /Change /TN "\SyncHubAutoReceiver" /Disable *> $null
Get-CimInstance Win32_Process -Filter "Name = 'python.exe' OR Name = 'pythonw.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*synchub_client.py*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
''';

    final innerEncoded = base64Encode(_encodeUtf16LeNoBom(innerElevatedScript));
    final outerScript =
        "Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -Wait "
        "-ArgumentList @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-EncodedCommand', '$innerEncoded')";
    final outerEncoded = base64Encode(_encodeUtf16LeNoBom(outerScript));

    try {
      await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-EncodedCommand',
        outerEncoded,
      ]);
    } catch (_) {
      return false;
    }

    return !(await detectLegacyAutoReceiver());
  }

  static ({String serverUrl, String username, String password})? parseSyncClipboardAccountMap(Object? decoded) {
    if (decoded is! Map) return null;
    var serverUrl = '';
    var username = '';
    var password = '';

    void take(Map chosen) {
      final url = (chosen['RemoteURL'] ?? chosen['Url'] ?? '').toString().trim();
      if (url.isNotEmpty) serverUrl = url;
      final user = (chosen['UserName'] ?? chosen['Username'] ?? '').toString().trim();
      if (user.isNotEmpty) username = user;
      final pw = (chosen['Password'] ?? chosen['password'] ?? '').toString();
      if (pw.isNotEmpty) password = pw;
    }

    final savedAccounts = decoded['SavedAccounts'];
    if (savedAccounts is Map) {
      final scAccounts = savedAccounts['SyncClipboard'];
      if (scAccounts is Map && scAccounts.isNotEmpty) {
        final accountMeta = decoded['Account'];
        final activeId = accountMeta is Map ? (accountMeta['AccountId']?.toString() ?? '') : '';
        Object? chosen = activeId.isNotEmpty ? scAccounts[activeId] : null;
        chosen ??= scAccounts.values.first;
        if (chosen is Map) take(chosen);
      }
    }
    if (serverUrl.isEmpty) {
      final syncService = decoded['SyncService'];
      if (syncService is Map) take(syncService);
    }
    serverUrl = serverUrl.replaceAll(RegExp(r'/+$'), '');
    if (serverUrl.isEmpty) return null;
    return (serverUrl: serverUrl, username: username, password: password);
  }

  /// Describes a migrated login without echoing the password.
  static String describeLogin(({String serverUrl, String username, String password}) login) {
    final pw = login.password.isEmpty ? '未保存密码' : '密码已读取，将写入系统安全存储';
    final user = login.username.isEmpty ? '（未填用户名）' : login.username;
    return '${login.serverUrl} · $user · $pw';
  }

  static Future<({String serverUrl, String username, String password})?> readLegacySyncClipboardLogin() async {
    if (!Platform.isWindows) return null;
    final appData = _appDataDir();
    if (appData == null) return null;
    final cfgFile = File(p.join(appData, 'SyncClipboard', 'SyncClipboard.json'));
    if (!await cfgFile.exists()) return null;
    try {
      final decoded = jsonDecode(_stripBom(await cfgFile.readAsString()));
      return parseSyncClipboardAccountMap(decoded);
    } catch (_) {
      return null;
    }
  }

  static Future<OfficialClipboardPresence> inspectOfficialClipboard() async {
    if (!Platform.isWindows) return const OfficialClipboardPresence.absent();
    final processRunning = await _imageRunning(TrayTakeoverPlan.officialImage);
    final task = await _queryTask(TrayTakeoverPlan.officialTask);
    final runValue = await _runValuePresent(TrayTakeoverPlan.officialRunValue);
    return OfficialClipboardPresence(
      processRunning: processRunning,
      startupTaskPresent: task.present,
      startupTaskEnabled: task.enabled,
      runValuePresent: runValue,
    );
  }

  static String? handoffRoot() {
    final appData = _appDataDir();
    if (appData == null) return null;
    return p.join(appData, 'SyncHub', 'tray-handoff');
  }

  /// Copies startup metadata. Does not modify tasks, processes, or user files.
  static Future<String?> backupOfficialStartup() async {
    if (!Platform.isWindows) return null;
    final root = handoffRoot();
    if (root == null) return null;
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '').replaceAll('.', '');
    final dir = Directory(p.join(root, stamp));
    await dir.create(recursive: true);
    final task = await _queryTask(TrayTakeoverPlan.officialTask);
    await File(p.join(dir.path, 'task-state.txt')).writeAsString(
      'name=${TrayTakeoverPlan.officialTask}\npresent=${task.present}\nenabled=${task.enabled}\n',
    );
    if (task.xml.isNotEmpty) {
      await File(p.join(dir.path, 'SyncClipboardStartup.xml')).writeAsString(task.xml);
    }
    final runDump = await _regQuery(r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run');
    await File(p.join(dir.path, 'hkcu-run.txt')).writeAsString(runDump);
    await File(p.join(dir.path, 'BACKUP_OK')).writeAsString('synchub-tray-handoff\n');
    final manifest = <String, Object>{
      'version': 1,
      'task': TrayTakeoverPlan.officialTask,
      'deletesProgramFiles': false,
      'deletesUserConfig': false,
      'deletesHistory': false,
    };
    await File(p.join(dir.path, 'manifest.json')).writeAsString(jsonEncode(manifest));
    return dir.path;
  }

  /// Disables official startup only after [backupDir] contains BACKUP_OK.
  /// Never deletes SyncClipboard.exe, SyncClipboard.json, or history.
  static Future<String> disableOfficialStartup({
    required String backupDir,
    bool stopProcess = false,
  }) async {
    if (!Platform.isWindows) return '当前不是 Windows';
    final marker = File(p.join(backupDir, 'BACKUP_OK'));
    if (!await marker.exists()) return '没有备份标记，已拒绝修改启动项';
    final plan = const TrayTakeoverPlan.confirmed();
    if (!plan.keepsUserData || plan.deleteProgramFiles || plan.deleteUserConfig || plan.deleteHistory) {
      return '接管计划包含删除，已拒绝执行';
    }
    final stateText = await File(p.join(backupDir, 'task-state.txt')).readAsString();
    final hadTask = RegExp(r'present\s*=\s*true', caseSensitive: false).hasMatch(stateText);
    var taskOk = true;
    if (hadTask) {
      final taskRes = await Process.run('schtasks.exe', [
        '/Change',
        '/TN',
        TrayTakeoverPlan.officialTask,
        '/Disable',
      ]);
      taskOk = taskRes.exitCode == 0;
    }
    await Process.run('reg.exe', [
      'delete',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
      '/v',
      TrayTakeoverPlan.officialRunValue,
      '/f',
    ]);
    var stopped = !stopProcess;
    if (stopProcess) {
      final kill = await Process.run('taskkill.exe', ['/IM', TrayTakeoverPlan.officialImage]);
      stopped = kill.exitCode == 0 || '${kill.stdout}${kill.stderr}'.toLowerCase().contains('not found');
    }
    if (!taskOk) return '已备份到 $backupDir，但禁用计划任务未成功';
    if (!stopped) return '已禁用开机启动。退出 SyncClipboard 进程未成功，托盘可能仍在，直到手动退出';
    return stopProcess ? '已禁用 SyncClipboard 开机启动并退出其进程。程序、配置和历史都还在。' : '已禁用 SyncClipboard 开机启动。程序、配置和历史都还在。';
  }

  static Future<String> rollbackOfficialStartup(String backupDir) async {
    if (!Platform.isWindows) return '当前不是 Windows';
    final stateFile = File(p.join(backupDir, 'task-state.txt'));
    if (!await stateFile.exists()) return '找不到备份，未改动启动项';
    final state = await stateFile.readAsString();
    if (RegExp(r'enabled\s*=\s*true', caseSensitive: false).hasMatch(state)) {
      await Process.run('schtasks.exe', [
        '/Change',
        '/TN',
        TrayTakeoverPlan.officialTask,
        '/Enable',
      ]);
    }
    return '已按备份恢复 SyncClipboard 开机启动。未删除任何文件。下次登录会再次出现它的托盘；现在手动打开它时，SyncHub 会暂停自己的剪贴板监视。';
  }

  static Future<bool> _imageRunning(String image) async {
    try {
      final res = await Process.run('tasklist.exe', ['/FI', 'IMAGENAME eq $image', '/NH']);
      return res.stdout.toString().toLowerCase().contains(image.toLowerCase());
    } catch (_) {
      return false;
    }
  }

  static Future<({bool present, bool enabled, String xml})> _queryTask(String name) async {
    try {
      final res = await Process.run('schtasks.exe', ['/Query', '/TN', name, '/XML']);
      if (res.exitCode != 0) return (present: false, enabled: false, xml: '');
      final xml = res.stdout.toString();
      return (present: xml.isNotEmpty, enabled: taskXmlEnabled(xml), xml: xml);
    } catch (_) {
      return (present: false, enabled: false, xml: '');
    }
  }

  static Future<bool> _runValuePresent(String valueName) async {
    try {
      final res = await Process.run('reg.exe', [
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
        '/v',
        valueName,
      ]);
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<String> _regQuery(String key) async {
    try {
      final res = await Process.run('reg.exe', ['query', key]);
      return res.stdout.toString();
    } catch (_) {
      return '';
    }
  }
}
