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

## 确认正常之后再接管

先看文件是否还能收发，文字和截图是否还会同步到其他已经在用 SyncHub 的设备。然后任选一种：

1. 打开 SyncHub → 设置 →「确认接管」。
2. 或者：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows_single_tray.ps1 -Takeover -Confirm
```

接管会：

1. 把计划任务 XML 和 `HKCU\...\Run` 备份到 `%APPDATA%\SyncHub\tray-handoff\<时间>\`。
2. 若剪贴板服务器地址还是空的，从本机 `SyncClipboard.json` 读入地址、用户名和密码。密码只进 Windows 凭据管理器，不进日志，也不进 git。
3. 禁用 `\SyncClipboardStartup`，删掉名为 `SyncClipboard` 的登录启动项。
4. 退出 `SyncClipboard.exe`。

不会删除：

- `SyncClipboard.exe` 和它的安装目录
- `%APPDATA%\SyncClipboard\SyncClipboard.json`
- 剪贴板历史、云端收藏、已经收到的文件

## 回滚

设置里的「恢复旧自启」，或：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows_single_tray.ps1 -Rollback -BackupDir "$env:APPDATA\SyncHub\tray-handoff\<时间>"
```

这只把计划任务重新启用。下次登录会再出现 SyncClipboard 托盘。若现在就手动打开它，SyncHub 会再次暂停自己的剪贴板监视。回滚不删除 SyncHub，也不删备份。

## 卸载 SyncHub 时

删掉 `%LOCALAPPDATA%\Programs\SyncHub`、开始菜单和桌面快捷方式，以及 `HKCU\...\Run\SyncHub`。不要连带删除 `%APPDATA%\SyncClipboard` 或 `%APPDATA%\SyncHub\tray-handoff`，除非你明确要丢掉回滚材料。

## Linux 上验证不了的部分

剪贴板监听、`CF_HDROP` 粘贴、托盘、计划任务、凭据管理器和 `Ctrl+Shift+V` 都要在 Windows 上构建后看。协议、暂停逻辑、zip 路径校验和文件暂存有本机测试。
