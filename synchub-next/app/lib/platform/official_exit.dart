/// How SyncHub asks SyncClipboard 3.3.3 to leave, without hiding its window.
///
/// Upstream `AppInstance` listens on the named pipe
/// `Global\SyncClipboard-Pipe-{UserName}-`. The line `Shutdown` calls
/// `ExitAsync`, which stops services and then `Application.Exit`.
/// Closing the settings window does not take that path.
/// Relaunching with the official restart switch also starts a new process,
/// so this policy never does that and never force-kills the process.
enum OfficialExitOutcome { alreadyStopped, stoppedByIpc, stoppedAfterTray, stillRunning }

class OfficialExitPolicy {
  static const pipeCommand = 'Shutdown';
  static const pipeNamePrefix = r'Global\SyncClipboard-Pipe-';
  static const ipcWait = Duration(seconds: 45);
  static const manualWait = Duration(seconds: 180);
  static const poll = Duration(milliseconds: 500);

  static int get ipcPolls => ipcWait.inMilliseconds ~/ poll.inMilliseconds;
  static int get manualPolls => manualWait.inMilliseconds ~/ poll.inMilliseconds;

  static const traySteps = '在通知区域右键 SyncClipboard 图标，点击「退出」。只关闭窗口不会结束进程。';

  /// [goneAtPoll] is the first poll, starting at 1, on which the process is gone.
  /// Null means it never exits during the IPC wait or the later tray wait.
  static OfficialExitOutcome simulate({required bool runningAtStart, int? goneAtPoll}) {
    if (!runningAtStart) return OfficialExitOutcome.alreadyStopped;
    if (goneAtPoll == null || goneAtPoll < 1) return OfficialExitOutcome.stillRunning;
    if (goneAtPoll <= ipcPolls) return OfficialExitOutcome.stoppedByIpc;
    if (goneAtPoll <= ipcPolls + manualPolls) return OfficialExitOutcome.stoppedAfterTray;
    return OfficialExitOutcome.stillRunning;
  }

  /// SyncHub may watch the clipboard only after the official process is gone.
  static bool trialMayWatch(OfficialExitOutcome outcome) {
    return outcome != OfficialExitOutcome.stillRunning;
  }
}
