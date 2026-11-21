/// Decides which Windows process may watch the clipboard.
///
/// Official SyncClipboard 3.3.3 is a separate MIT-licensed tray app. It has no
/// supported headless mode that can share one clipboard watcher with SyncHub.
/// Hiding its icon would keep a second watcher. SyncHub therefore pauses its
/// own clipboard sync while that process is running, and only disables the
/// official startup entry after an explicit confirmed handover.
enum ClipboardDuty { synchub, yieldToOfficial }

enum HandoffPhase { idle, trial, committed }

/// Ordered steps for a handover. The list is the only legal order.
enum HandoffAction {
  backupStartup,
  rememberOfficialExecutable,
  stopOfficialProcess,
  requireOfficialStopped,
  allowSyncHubClipboard,
  pauseSyncHubClipboard,
  startOfficialProcess,
  requireOfficialRunning,
  disableOfficialStartup,
}

class HandoffPlan {
  final HandoffPhase nextPhase;
  final List<HandoffAction> actions;
  final bool refused;
  final String reason;

  const HandoffPlan({
    required this.nextPhase,
    required this.actions,
    this.refused = false,
    this.reason = '',
  });

  /// Stop SyncClipboard, then let SyncHub watch. Does not disable startup.
  static HandoffPlan beginTrial({required bool officialRunning}) {
    return HandoffPlan(
      nextPhase: HandoffPhase.trial,
      actions: <HandoffAction>[
        HandoffAction.backupStartup,
        HandoffAction.rememberOfficialExecutable,
        if (officialRunning) HandoffAction.stopOfficialProcess,
        HandoffAction.requireOfficialStopped,
        HandoffAction.allowSyncHubClipboard,
      ],
    );
  }

  /// Pause SyncHub before the official process is started again.
  static HandoffPlan abortTrial() {
    return const HandoffPlan(
      nextPhase: HandoffPhase.idle,
      actions: <HandoffAction>[
        HandoffAction.pauseSyncHubClipboard,
        HandoffAction.startOfficialProcess,
        HandoffAction.requireOfficialRunning,
      ],
    );
  }

  /// Disable startup only after a trial where SyncClipboard is already stopped.
  static HandoffPlan commit({
    required HandoffPhase phase,
    required bool officialRunning,
  }) {
    if (phase != HandoffPhase.trial || officialRunning) {
      return const HandoffPlan(
        nextPhase: HandoffPhase.trial,
        actions: <HandoffAction>[],
        refused: true,
        reason: '只有临时暂停成功、并且 SyncClipboard 已经退出之后，才能禁用旧开机启动',
      );
    }
    return const HandoffPlan(
      nextPhase: HandoffPhase.committed,
      actions: <HandoffAction>[HandoffAction.disableOfficialStartup],
    );
  }

  bool get deletesUserData => false;
}

class HandoffCommand {
  final String op;
  final bool paused;
  final String exe;

  const HandoffCommand({required this.op, this.paused = false, this.exe = ''});

  static HandoffCommand? parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final op = _jsonString(text, 'op');
    if (op == null || op.isEmpty) return null;
    return HandoffCommand(
      op: op,
      paused: RegExp(r'"paused"\s*:\s*true').hasMatch(text),
      exe: _jsonString(text, 'exe') ?? '',
    );
  }

  bool get requestsAbort => op == 'abort';

  bool get requestsTrial => op == 'trial';
}

/// What one clipboard-duty probe is allowed to do.
///
/// A previous abort latches an explicit pause. Trial clears that latch when
/// SyncClipboard.exe is gone, even if the latch was never cleared by seeing
/// the official process running again.
class ClipboardProbe {
  final bool pauseSyncHub;
  final bool acknowledgeAbort;
  final bool clearExplicitHold;
  final bool adoptOfficialAccount;

  const ClipboardProbe({
    required this.pauseSyncHub,
    required this.acknowledgeAbort,
    required this.clearExplicitHold,
    required this.adoptOfficialAccount,
  });
}

ClipboardProbe decideClipboardProbe({
  required bool explicitHold,
  required bool officialRunning,
  required HandoffCommand? command,
}) {
  if (command != null && command.requestsAbort && !command.paused) {
    return const ClipboardProbe(
      pauseSyncHub: true,
      acknowledgeAbort: true,
      clearExplicitHold: false,
      adoptOfficialAccount: false,
    );
  }
  if (command != null && command.requestsTrial && !officialRunning) {
    return const ClipboardProbe(
      pauseSyncHub: false,
      acknowledgeAbort: false,
      clearExplicitHold: true,
      adoptOfficialAccount: true,
    );
  }
  final abortLatch = command?.requestsAbort ?? false;
  final pause = explicitHold || officialRunning || abortLatch;
  return ClipboardProbe(
    pauseSyncHub: pause,
    acknowledgeAbort: false,
    clearExplicitHold: explicitHold && officialRunning,
    adoptOfficialAccount: false,
  );
}

String? _jsonString(String json, String key) {
  final match = RegExp('"$key"\\s*:\\s*"((?:\\\\.|[^"\\\\])*)"').firstMatch(json);
  if (match == null) return null;
  return match.group(1)!.replaceAll(r'\"', '"').replaceAll(r'\\', r'\');
}

/// Applies [actions] in order and rejects any state where both sides watch.
class ClipboardOwnerSim {
  bool officialRunning;
  bool syncHubWatching;
  bool startupEnabled;
  bool deletedUserData = false;

  ClipboardOwnerSim({
    this.officialRunning = true,
    this.syncHubWatching = false,
    this.startupEnabled = true,
  });

  bool get bothWriting => officialRunning && syncHubWatching;

  void apply(HandoffAction action) {
    switch (action) {
      case HandoffAction.backupStartup:
      case HandoffAction.rememberOfficialExecutable:
        break;
      case HandoffAction.stopOfficialProcess:
        officialRunning = false;
      case HandoffAction.requireOfficialStopped:
        if (officialRunning) {
          throw StateError('SyncClipboard 仍在运行，不能打开 SyncHub 剪贴板');
        }
      case HandoffAction.allowSyncHubClipboard:
        if (officialRunning) {
          throw StateError('两边会同时写剪贴板');
        }
        syncHubWatching = true;
      case HandoffAction.pauseSyncHubClipboard:
        syncHubWatching = false;
      case HandoffAction.startOfficialProcess:
        if (syncHubWatching) {
          throw StateError('SyncHub 还在监视，不能启动 SyncClipboard');
        }
        officialRunning = true;
      case HandoffAction.requireOfficialRunning:
        if (!officialRunning) {
          throw StateError('SyncClipboard 没有恢复');
        }
      case HandoffAction.disableOfficialStartup:
        startupEnabled = false;
    }
    if (bothWriting) {
      throw StateError('两边同时写剪贴板');
    }
  }
}

String? commandFromTaskXml(String xml) {
  final match = RegExp(r'<Command>([^<]+)</Command>', caseSensitive: false).firstMatch(xml);
  if (match == null) return null;
  var cmd = match.group(1)!.trim();
  if (cmd.startsWith('"')) {
    final end = cmd.indexOf('"', 1);
    cmd = end > 1 ? cmd.substring(1, end) : cmd.substring(1);
  }
  cmd = cmd.trim();
  return cmd.isEmpty ? null : cmd;
}

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
