/// Decides which Windows process may watch the clipboard.
///
/// Official SyncClipboard 3.3.3 is a separate MIT-licensed tray app. It has no
/// supported headless mode that can share one clipboard watcher with SyncHub.
/// Hiding its icon would keep a second watcher. SyncHub therefore pauses its
/// own clipboard sync while that process is running, and only disables the
/// official startup entry after an explicit confirmed handover.
enum ClipboardDuty { synchub, yieldToOfficial }

class OfficialClipboardPresence {
  final bool processRunning;
  final bool startupTaskPresent;
  final bool startupTaskEnabled;
  final bool runValuePresent;

  const OfficialClipboardPresence({
    required this.processRunning,
    required this.startupTaskPresent,
    required this.startupTaskEnabled,
    required this.runValuePresent,
  });

  const OfficialClipboardPresence.absent()
      : processRunning = false,
        startupTaskPresent = false,
        startupTaskEnabled = false,
        runValuePresent = false;

  bool get shouldYield => processRunning;
}

ClipboardDuty decideClipboardDuty(OfficialClipboardPresence presence) =>
    presence.shouldYield ? ClipboardDuty.yieldToOfficial : ClipboardDuty.synchub;

/// What a confirmed handover is allowed to change.
///
/// Program files, SyncClipboard.json, and clipboard history are never deleted.
class TrayTakeoverPlan {
  static const String officialTask = r'\SyncClipboardStartup';
  static const String officialImage = 'SyncClipboard.exe';
  static const String officialRunValue = 'SyncClipboard';
  static const String synchubRunValue = 'SyncHub';

  final bool backupFirst;
  final bool disableStartupTask;
  final bool removeOfficialRunValue;
  final bool stopOfficialProcess;
  final bool deleteProgramFiles;
  final bool deleteUserConfig;
  final bool deleteHistory;

  const TrayTakeoverPlan._({
    required this.backupFirst,
    required this.disableStartupTask,
    required this.removeOfficialRunValue,
    required this.stopOfficialProcess,
    required this.deleteProgramFiles,
    required this.deleteUserConfig,
    required this.deleteHistory,
  });

  const TrayTakeoverPlan.backupOnly()
      : this._(
          backupFirst: true,
          disableStartupTask: false,
          removeOfficialRunValue: false,
          stopOfficialProcess: false,
          deleteProgramFiles: false,
          deleteUserConfig: false,
          deleteHistory: false,
        );

  const TrayTakeoverPlan.confirmed()
      : this._(
          backupFirst: true,
          disableStartupTask: true,
          removeOfficialRunValue: true,
          stopOfficialProcess: true,
          deleteProgramFiles: false,
          deleteUserConfig: false,
          deleteHistory: false,
        );

  bool get keepsUserData => !deleteProgramFiles && !deleteUserConfig && !deleteHistory;
  String get taskName => officialTask;
}

/// True when a scheduled-task XML document says the task is enabled.
/// A missing `<Enabled>` element means enabled, matching schtasks.
bool taskXmlEnabled(String xml) {
  final disabled = RegExp(r'<Enabled>\s*false\s*</Enabled>', caseSensitive: false);
  return !disabled.hasMatch(xml);
}

String clipboardDutyStatus(ClipboardDuty duty) => switch (duty) {
      ClipboardDuty.yieldToOfficial =>
        '检测到 SyncClipboard 正在运行，已暂停剪贴板监视，避免重复上传。文件收发仍由 SyncHub 继续。',
      ClipboardDuty.synchub => '剪贴板由 SyncHub 负责',
    };
