# SyncHub Next — macOS 编译、安装与二次开发指南

本源码包包含 **SyncHub Next（Android + macOS + Windows 三端客户端 + Go Gateway/Relay 双机信令中继 + Python SyncHub 云端存储与剪贴板服务 + 161 项黑盒测试套件）** 的完整源码，无任何删减，支持在 macOS 上直接二次修改、热重载调试与一键打包安装。

---

## 一、macOS 端已内置的原生能力一览

macOS 端除了拥有与 Windows / Android 完全一致的 **Blip 风格极简近场/远程直传 + 云端收藏空间 + 剪贴板跨端秒同步** 外，还在 `app/macos/Runner/` 中用原生 Swift 深度集成了 macOS 专属体验：

1. **顶部菜单栏常驻图标 + 拖拽即传（Menu Bar Drop Target）**：
   - 关闭主窗口后自动退居菜单栏，零 Dock 干扰；
   - 直接从 Finder 或桌面把**文件/文件夹拖拽到顶部菜单栏的 SyncHub 图标上**，即刻弹出设备选择面板直发 Windows / 手机或存入云端。
2. **Finder 右键快捷操作（Quick Action）与系统服务（Services）**：
   - 安装脚本自动注册 Finder 右键菜单 **`快速操作 → 发送到跨端传输中心`**（支持多文件与整个文件夹一键免压直传）；
   - 在任意 App 中选中文字或文件右键 **`服务 → 发送到 SyncHub`** 即可跨端推送。
3. **全局快捷键 `⇧⌘V`**：在任意桌面界面一键呼出主面板或触发剪贴板同步。
4. **macOS Keychain 钥匙串安全存储**：账号密码、设备私钥与同步口令加密保存在系统钥匙串（`xyz.synchub.secure`），磁盘明文配置自动脱敏。
5. **App Nap 零功耗后台常驻 + 合盖唤醒秒重连**：
   - 采用 macOS 原生合并定时器（`Timer` + `tolerance: 0.6s`）仅对比内存整数 `NSPasteboard.general.changeCount`，剪贴板未变化时 **0 次跨层通信、后台空闲 CPU 趋近 0%**，同时支持密码管理器隐私剪贴板过滤（`org.nspasteboard.ConcealedType`）；
   - 监听 `NSWorkspace` 合盖睡眠/熄屏通知自动暂停后台唤醒，开盖亮屏毫秒级重连 WebSocket 信令网关。
6. **旧版 Mac SyncHub 无感平滑迁移**：
   - 一键安装时自动读取旧版 `~/Library/Application Support/SyncHub/receiver_state.json`、`~/.synchub/config` 与旧钥匙串配置，继承历史 `last_id` 避免重复拉取旧文件，并自动清理旧版 LaunchAgent 守护进程。

---

## 二、Mac 编译环境准备（仅首次需要）

在你的 Mac 终端（Terminal）检查以下两项基础工具：

### 1. Xcode（macOS 原生编译工具链）
确保已从 App Store 安装 **Xcode**，并在终端执行一次命令行指向与许可确认：
```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
```

### 2. Flutter SDK（推荐最新 Stable 3.47+）
如果本机尚未安装 Flutter，推荐通过 Homebrew 一键安装（Apple Silicon 与 Intel 均适用）：
```bash
brew install --cask flutter
flutter config --enable-macos-desktop
```
> 若处于国内网络环境无需手动配置代理，`scripts/build_mac.sh` 会在检测到 `pub.dev` 超时后自动切换至 `pub.flutter-io.cn` 国内官方镜像（也可显式传 `--cn-mirror`）。若后续在 `macos/` 引入依赖 CocoaPods 的第三方插件，可补充安装 `brew install cocoapods`。

---

## 三、在 Mac 上一键编译并安装到本机

推荐在终端使用 `tar -xzf` 解压源码包（会自动保留所有脚本的可执行权限与 Unix `LF` 换行符）：

```bash
tar -xzf SyncHub-Next-全量源码包_含Mac一键编译.tar.gz
cd synchub-next
```

### 方式 A：Finder 双击一键编译安装
直接在 Finder 打开解压后的 `synchub-next` 文件夹，双击 **`一键编译安装_SyncHub_Mac.command`**（若首次双击提示权限，可在终端运行 `bash ./一键编译安装_SyncHub_Mac.command`）。

### 方式 B：命令行编译（支持更多参数）
```bash
# 编译 Release 版 + 签名 + 生成 .dmg/.zip + 迁移旧配置并安装启动 /Applications/SyncHub.app
bash scripts/build_mac.sh --install

# 仅编译打包 dist/SyncHub-macos.dmg 与 dist/SyncHub-macos.zip，不覆盖本机 /Applications
bash scripts/build_mac.sh

# 强制使用国内 Flutter 镜像编译并安装
bash scripts/build_mac.sh --cn-mirror --install

# 如你有 Apple Developer ID 证书，可指定正式签名身份：
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" bash scripts/build_mac.sh --install
```

### 首次配对接入你的双服务器集群
应用启动后：
1. 在你已配置好的 **Windows 端 SyncHub** 打开 **`设置 → 添加设备（生成配对码）`** 获取 6 位数字配对码；
2. 在 Mac 端引导界面选择 **「配对码加入已有账号」**，服务器地址填 `https://020814.xyz/gw`，输入 6 位配对码（或直接使用账号登录）；
3. 配对完成后，Mac、Windows 与 Android 即刻处于同一设备列表，自动择优走 **局域网 TCP 直连 → STUN/WebRTC 跨网打洞 → 自建双机保底中继**。

---

## 四、如何在 Mac 上修改源码与实时调试（二次开发指南）

### 1. 日常热重载调试（修改 Dart UI 与核心传输逻辑）
用 VS Code / Cursor 打开 `synchub-next/app` 目录，或在终端执行：
```bash
cd app
flutter pub get
flutter run -d macos
```
运行期间修改 `app/lib/` 下的任意 Dart 代码，在终端按 **`r` 即可毫秒级热重载（Hot Reload）** UI，按 **`R` 热重启（Hot Restart）**。

### 2. 修改 macOS 原生层代码（Xcode）
如果你想调整菜单栏图标交互、快捷键、Finder 服务或系统 API，直接用 Xcode 打开工作区：
```bash
open app/macos/Runner.xcworkspace
```
- **核心原生桥接与菜单栏实现**：`app/macos/Runner/AppDelegate.swift`
  - 菜单栏图标与拖拽弹窗：`setUpStatusItem()` / `ensureStatusBarDragRegistration()` / `presentDropTargetPicker(...)`
  - 剪贴板低功耗监听与隐私过滤：`startPasteboardObserver()` / `checkPasteboardChangeCount()`
  - 全局快捷键（默认 `⇧⌘V`）：`registerGlobalHotKey()`
  - Keychain 钥匙串读写：`SyncHubKeychain.write(...)` / `SyncHubKeychain.read(...)`
  - 开机自启（`SMAppService` + LaunchAgent 兜底）：`SyncHubLoginItem.setEnabled(...)`
- **窗口激活策略与常驻隐藏控制**：`app/macos/Runner/MainFlutterWindow.swift`
- **权限与局域网发现声明**：`app/macos/Runner/Info.plist`（含 macOS 15/16 `NSLocalNetworkUsageDescription` 与 `_synchub._tcp` Bonjour 声明）及 `app/macos/Runner/Release.entitlements`

### 3. 全栈源码目录速查表
```text
synchub-next/
├── 一键编译安装_SyncHub_Mac.command   # macOS Finder 双击一键编译+签名+安装入口
├── scripts/
│   ├── build_mac.sh                   # macOS 编译、Inside-Out 签名、DMG 打包与旧版迁移脚本
│   ├── build_windows.ps1              # Windows Release 编译打包脚本
│   └── install_windows.ps1            # Windows 本机一键安装与注册表右键菜单配置脚本
├── app/                               # Flutter 三端统一工程 (macOS + Windows + Android)
│   ├── lib/
│   │   ├── main.dart                  # 应用入口与全局状态组装
│   │   ├── ui/                        # Blip 风格三大主页面 (home.dart / cloud_page.dart / clipboard_page.dart / settings.dart)
│   │   ├── core/                      # P2P 直连引擎、局域网 mDNS/UDP 发现、断点续传、云端收藏与剪贴板状态机
│   │   └── platform/                  # 跨平台 MethodChannel 统一抽象层 (platform_bridge.dart)
│   ├── macos/                         # macOS Swift 原生工程 (菜单栏拖拽、Keychain、Finder Quick Action、App Nap)
│   ├── windows/                       # Windows C++ Win32 原生工程 (系统托盘、DPAPI、WM_CLIPBOARDUPDATE、Explorer 右键)
│   └── android/                       # Android Kotlin 原生工程 (前台常驻服务、系统分享接收、LSPosed Hook + Root 后台剪贴板同步)
├── server/
│   ├── gateway/                       # Go 语言编写的 WebSocket 信令网关、P2P 协调器与双机流式中继 (Server 1 + Server 2)
│   ├── synchub/                       # Python 云端中转存储、SyncClipboard WebDAV 兼容接口与 SQLite WAL 历史库
│   └── deploy/                        # 双服务器 systemd 服务配置、Caddy 反代、coturn TURN 配置与部署脚本
├── protocol/                          # Wire v1 跨端帧格式规范与共享 JSON 测试向量
└── tests/                             # 161 项全链路黑盒集成测试套件 (pytest)
```

### 4. 在 Mac 上顺便编译 Android APK 与运行全量自测
因为你的 Mac 同时具备 Unix 环境，你也可以直接在 Mac 上修改并编译 Android 安装包或服务端二进制：
```bash
# 运行 Dart 静态分析与 40 项客户端单元测试
cd app && flutter analyze && flutter test

# 在 Mac 上一键交叉编译 Android 双架构安装包 (arm64-v8a / armeabi-v7a)
cd app && flutter build apk --release --split-per-abi

# 在 Mac 上交叉编译 Linux x64 服务端网关二进制（用于热更新你的两台 VPS）
cd server/gateway && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o dist/linux-amd64/synchub-gateway ./cmd/gateway
```
