# Windows 单托盘：安装、确认、回滚

这一步只在你自己的 Windows 电脑上做。本仓库的改动不会远程安装，也不会关掉正在运行的程序。

## 现在机器上的两个托盘

- SyncClipboard 3.3.3.0：`%LOCALAPPDATA%\Programs\SyncClipboard\SyncClipboard.exe`，计划任务 `\SyncClipboardStartup`。
- SyncHub：`%LOCALAPPDATA%\Programs\SyncHub\synchub.exe --minimized`，`HKCU\...\Run\SyncHub`。已安装过 1.1.2+8。源码现为 1.1.3+9。1.1.2+8 的程序在试用恢复后不会把暂停期间的剪贴板外发，需要整包重装，不能只换脚本。
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

这一步只备份启动项、记下 `SyncClipboard.exe` 的路径，然后请官方进程退出。开机项保持原样。进程确认退出后，SyncHub 才开始同步剪贴板。两边不会同时写。

退出用的是 SyncClipboard 3.3.3 自己的命名管道 `Global\SyncClipboard-Pipe-<用户名>-`，写入一行 `Shutdown`。上游 `AppInstance` 收到后调用 `ExitAsync`：先停内部服务，再 `Application.Exit`，进程结束。这和托盘菜单「退出」是同一条路，不是把窗口藏起来。不要用会再启动一个新进程的重启参数，也不要 `taskkill /F`。

脚本先等最多 45 秒。若进程还在，窗口会写出托盘步骤，并再等 3 分钟：右键通知区域的 SyncClipboard 图标，点「退出」。在这段等待里点退出后，同一次 `-Trial` 会继续，不必先失败再重跑。若 3 分钟后进程仍在，命令失败退出，开机项不变，SyncHub 继续暂停剪贴板。进程已经退出后再运行 `-Trial` 会直接进入验证。

进程退出后，SyncHub 看到 `command.json` 的 `op=trial` 会清掉 Abort 留下的暂停，改用官方账号的 `SyncClipboard.json`（不是网关的 `/api/hub/sc`），并上传暂停期间已经变化的剪贴板。设置里的按钮运行的是同一个 `-Trial`，没有另一套短等待。

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

## JNI

Windows 包不附带 `dartjni.dll` 或 `jvm.dll`。这两个文件来自 Android 插件的 JNI 依赖。Windows 上的路径、偏好和文件选择不走 JNI。打包步骤会删掉该 DLL，并从 `native_assets.json` / `NativeAssetsManifest.json` 里去掉对应条目；删不干净则构建失败。

新包本身没有这两个文件。覆盖安装不会自动删掉上一个版本留在安装目录里的同名文件，所以升级后目录可能仍有旧的 `dartjni.dll`。程序不因为这个旧文件还在就无法运行。安装器会只把安装目录根下的 `dartjni.dll` 和 `jvm.dll` 移到 `%LOCALAPPDATA%\Programs\SyncHub-upgrade\<时间>`，并写下 `install-manifest.json`。符号链接只移动链接本身，不打开、不删除链接目标。其他 DLL 不动。已经装好、只想补做这一步时：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install_windows.ps1 -QuarantineJniOnly
```

需要放回时：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install_windows.ps1 -RestoreJni
```

目标位置已经有同名文件时，恢复会拒绝覆盖。

## 图片和文件的 profile 哈希

`Image` 和 `File` 的 `Hash` 是 `SHA256(文件名|内容 SHA-256)`，大写十六进制。内容哈希放在 `transferDataHash`。把内容哈希写进 `Hash` 会得到 HTTP 400，这是对端拒绝了错误的 profile，不是客户端没有收到文件。本地夹具用 `syntheticBinaryProfile`。已核对的外发例子：`SyncHub-test-a1475258-6702-441d-b8ee-f4ee1a0dc346-png-out.png` 的内容哈希 `83F10DFA…1D63` 对应 profile `B1BA9D22…4B59`。

## 图标

仓库和历史提交里没有原来的 Windows `app_icon.ico`。macOS 目录里的蓝色箭头图标是脚本生成的另一份图，不能当作这份 Windows 图标。窗口和托盘只加载编进程序的 `IDI_APP_ICON`，缺少时构建失败，不再换成系统图标。

Windows 构建需要本机那份原文件：33772 字节，SHA256 `C098D3FC85CACFF98B8E69811B48E9F0D852FCEE278132D794411D978869CBF8`。

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_app.ps1 -Target windows -AppIcon <原 app_icon.ico 的路径>
```

也可以设置 `SYNCHUB_APP_ICON`。路径必须是普通文件。大小或哈希不符会停止，不会继续打包。

## Linux 上验证不了的部分

剪贴板监听、`CF_HDROP` 粘贴、托盘、计划任务、凭据管理器和 `Ctrl+Shift+V` 都要在 Windows 上构建后看。协议、暂停逻辑、zip 路径校验和文件暂存有本机测试。
