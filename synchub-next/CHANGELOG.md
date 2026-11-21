# 变更说明

## 1.1.2+8

Windows 只保留 SyncHub 托盘。

- 已安装的 `synchub.exe` 是 **1.1.0+6**。本机未发布源码的 `pubspec.yaml` 已是 **1.1.1+7**（2026-11-14 至 11-15 的剪贴板、Windows 原生、传输、P2P 和测试改动）。那些改动都保留在 `synchub-next/`，没有用仓库里更早的 Python 接收器覆盖。
- 1.1.2+8 先临时退出 SyncClipboard（不改开机项），确认进程退出后 SyncHub 才监视剪贴板。验证失败会先停 SyncHub 的剪贴板，再打开原来的程序。验证通过后才禁用 `\SyncClipboardStartup`。
- 图片文件名改为毫秒时间加进程内递增序号。Mac 和 Android 原先只有到秒的名字，同一秒会撞名；随机 4 位后缀也会撞。序号不截断。
- 不删除 SyncClipboard 程序、`SyncClipboard.json`、历史或已接收文件。凭据只在本机读入系统安全存储。
- 接收 SyncClipboard `File` 后写入系统剪贴板，便于资源管理器粘贴。`Group` zip 在校验路径后解出再粘贴；单文件以外的本机多选仍走 SyncHub 传输，避免和自动收发打成两份。
- Windows 全局快捷键 `Ctrl+Shift+V` 发送当前剪贴板，对应 macOS 的 `⇧⌘V`。
- 官方 SyncClipboard 是 MIT 许可，没有可与 SyncHub 共用的稳定无托盘模式。因此没有把它藏进后台，也没有把上游源码并进本仓库。

## 仍未在此版本改变

- 不部署服务器，不改 Mac / Android 协议。
- 安装程序默认只备份启动项。禁用旧自启要在本机确认功能正常之后再做。
