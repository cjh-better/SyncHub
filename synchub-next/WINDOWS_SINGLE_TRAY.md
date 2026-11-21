# Windows 单托盘：安装、确认、回滚

这一步只在你自己的 Windows 电脑上做。本仓库的改动不会远程安装，也不会关掉正在运行的程序。

## 现在机器上的两个托盘

- SyncClipboard 3.3.3.0：`%LOCALAPPDATA%\Programs\SyncClipboard\SyncClipboard.exe`，计划任务 `\SyncClipboardStartup`。
- SyncHub：`%LOCALAPPDATA%\Programs\SyncHub\synchub.exe --minimized`，`HKCU\...\Run\SyncHub`。已安装文件版本是 1.1.0+6。源码现为 1.1.2+8。
- 旧 Python 接收任务 `\SyncHubAutoReceiver` 已经禁用。不要为了单托盘再去删它的文件。

官方 SyncClipboard 3.3.3 是带托盘的独立程序，没有可以和 SyncHub 共用剪贴板监视的稳定无托盘模式。只隐藏图标或直接结束进程会留下第二套监视，或者丢掉文字、图片和文件粘贴。SyncHub 自己实现了同一套 `SyncClipboard.json` 协议，所以接管后由它监视剪贴板。

两边同时运行时，SyncHub 暂停剪贴板上传和下载，文件、云端和 P2P 继续。这样不会两个程序一起观察剪贴板。

## 在 Windows 上构建

需要 Flutter（与 `app/pubspec.yaml` 的 Dart 3.8 兼容）以及 Visual Studio 的「使用 C++ 的桌面开发」。

```powershell
cd synchub-next
powershell -ExecutionPolicy Bypass -File .\scripts\build_app.ps1 -Target windows
powershell -ExecutionPolicy Bypass -File .\scripts\install_windows.ps1
```

安装器会把程序拷到 `%LOCALAPPDATA%\Programs\SyncHub`，注册「发送到 SyncHub」，并**只备份** SyncClipboard 的开机项。它不会禁用旧自启，也不会删除旧程序。

Android 发布签名的 keystore 不在源码里。构建 release 前在 `app/android/keystore.properties`（已忽略）或 `SYNCHUB_KEYSTORE_FILE` / `SYNCHUB_KEYSTORE_PASSWORD` / `SYNCHUB_KEY_ALIAS` / `SYNCHUB_KEY_PASSWORD` 提供本机密钥。不要把密钥写进仓库。

## 先临时暂停，验证通过再禁用开机项

SyncClipboard 还在运行时，SyncHub 不写剪贴板，所以这时看不了 SyncHub 的同步。不要第一步就禁用开机项。

1. 设置里点「临时暂停并验证」，或：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows_single_tray.ps1 -Trial
```

这一步只备份启动项、记下 `SyncClipboard.exe` 的路径，然后退出该进程。开机项保持原样。进程确认退出后，SyncHub 才开始同步剪贴板。两边不会同时写。

2. 试文字、截图和单个文件。文件收发本来就不依赖 SyncClipboard。

3. 验证通过后，设置里点「验证通过，禁用旧开机启动」，或：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows_single_tray.ps1 -Takeover -Confirm -BackupDir "$env:APPDATA\SyncHub\tray-handoff\<时间>"
```

这时才禁用 `\SyncClipboardStartup` 和名为 `SyncClipboard` 的登录项。若进程还在，命令会拒绝。

4. 验证失败时先停 SyncHub 的剪贴板，再打开原来的程序。设置里点「立即恢复 SyncClipboard」，或：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows_single_tray.ps1 -AbortTrial -BackupDir "$env:APPDATA\SyncHub\tray-handoff\<时间>"
```

脚本会等 SyncHub 写下「已暂停」再启动旧程序。等不到就拒绝启动，避免两边一起写。这一步不改开机项，重启后仍按原来的计划任务打开 SyncClipboard。

不会删除程序、`SyncClipboard.json`、历史或已接收文件。剪贴板密码只在本机读入 Windows 凭据管理器。

## 回滚

已经禁用开机项之后，设置里的「恢复旧开机启动」，或：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows_single_tray.ps1 -Rollback -BackupDir "$env:APPDATA\SyncHub\tray-handoff\<时间>"
```

这只把计划任务重新启用。下次登录会再出现 SyncClipboard 托盘。若现在就手动打开它，SyncHub 会再次暂停自己的剪贴板监视。回滚不删除 SyncHub，也不删备份。

## 卸载 SyncHub 时

删掉 `%LOCALAPPDATA%\Programs\SyncHub`、开始菜单和桌面快捷方式，以及 `HKCU\...\Run\SyncHub`。不要连带删除 `%APPDATA%\SyncClipboard` 或 `%APPDATA%\SyncHub\tray-handoff`，除非你明确要丢掉回滚材料。

## Linux 上验证不了的部分

剪贴板监听、`CF_HDROP` 粘贴、托盘、计划任务、凭据管理器和 `Ctrl+Shift+V` 都要在 Windows 上构建后看。协议、暂停逻辑、zip 路径校验和文件暂存有本机测试。
