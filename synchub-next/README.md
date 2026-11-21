# SyncHub Next（SyncHub × Blip 风格三端互联系统）

基于 **Flutter + 原生平台增强层（Win32 C++ / macOS Swift / Android Kotlin + LSPosed + Root）** 与 **Go 控制面 + 双 VPS 无盘流式中继** 构建的 **Android · macOS · Windows** 跨端文件互传与剪贴板同步系统。

- **UI 与交互逻辑**：全面借鉴 Blip（设备卡片即拖即传、边发边收、不限大小保留目录结构、实时进度环、接收确认、断点续传），保持类 macOS 浅色扁平风格（单一强调色 `#007AFF`）。
- **100% 自建双服务器架构**：完全不依赖任何第三方商业服务器；原交付包 `SyncClipboard_SyncHub_完整交付包/` 原封不动保留。
- **只增不减**：在完整实现 Blip 核心直传体验（`B1–B9, B11`）的同时，100% 保留并原生融合 SyncClipboard 双向剪贴板同步、SyncHub 云端收藏中心（8 大分类 / 置顶 / 收藏 / 72 小时自动清理 / 撤销删除）、离线云端投递、三端右键菜单与系统级快捷入口、Android Root / LSPosed 后台静默剪贴板守护（`S1–S11`）。

---

## 1. 全阶段完成状态

| 阶段 | 状态 | 核心交付内容 |
|---|---|---|
| **P0 协议与双 VPS 服务端** | ✅ 已上线 | Go `synchub-gateway`（设备注册、6 位一次性配对码、设备吊销、WebSocket 在线状态与信令、X25519 + AES-256-GCM 端到端加密、4 MB 分块断点续传）。主服务器与中继的地址、TURN 密钥只从部署环境变量读取，不写入仓库。 |
| **P1 Flutter 核心与局域网直连** | ✅ 已完成 | 5 栏响应式导航（设备 / 传输 / 云端 / 剪贴板 / 设置）、`:53318` 局域网 HTTP P2P 直连、mDNS `_synchub._tcp` + UDP `:53319` 广播自动发现、目录树无损还原、接收确认弹窗与暂停/继续/重发 |
| **P2 跨网络 P2P / 中继 / 离线投递 / macOS** | ✅ 已完成 | WebRTC DataChannel 跨网 P2P 打洞（6 秒超时自动无感降级最优 VPS 中继 `la` → `main`）、目标离线自动转 SyncHub 云端投递（`S3`）与 `AutoPuller` 自动拉取、macOS 原生菜单栏拖拽/Finder 快速操作/系统服务/打包脚本 |
| **P3 剪贴板同步与原生云端中心** | ✅ 已完成 | 100% 兼容 SyncClipboard v3.1.1 / v3.3.3 协议（文字、图片、>10KB 长文本文件化、≤20MB 单文件、防回环与密码管理器隐私剪贴板跳过、支持网关 Bearer 代理 `/api/hub/sc/*` 与直连 BasicAuth）；原生 `CloudPage` 云端收藏中心 |
| **P4 三端深度系统集成** | ✅ 已完成 | Windows 单实例 `WM_COPYDATA`、托盘菜单、资源管理器级联右键菜单（「发送到 SyncHub → 设备名 / 云端收藏」）、DPAPI 凭据存储；Android 前台保活服务、系统分享/选中文本菜单、快捷设置磁贴、LSPosed 系统框架 Hook 与 Root `app_process` 守护进程 |
| **P5 打包、平滑迁移与验收** | ✅ 已完成 | 自动继承旧版 `last_id` 进度避免重复下载、一键检测并停用旧版 Python 后台脚本。1.1.2 起可在确认后把 Windows 剪贴板交给 SyncHub，只留一个托盘，见 [WINDOWS_SINGLE_TRAY.md](WINDOWS_SINGLE_TRAY.md) |
| **P6 全链路代码审计、偶发失效根治与后台常驻优化** | ✅ 已完成 | 服务端 SQLite WAL + 1800s 容量缓存 + 72h 离线队列精确游标 + Go Relay 生命周期与优雅退出；客户端指数抖动重连 + 断线孤立 Completer 瞬时 Fast-Fail + WebRTC 12s 平滑降级 + 网卡漫游动态重绑 + 10 万次并发防碰撞；三端原生纯事件驱动（消除 750ms 盲轮询）+ 系统休眠唤醒秒级自愈 + `CryptoPool` 空闲 60s 自动销毁 Isolate 回收物理内存（空闲后台 CPU 趋近 0%）；落地 161 项分层黑盒 E2E 自动化测试套件 |

---

## 2. 线上双服务器拓扑（均已部署运行）

1. **主服务器（地址由环境变量提供；现有部署文档里的域名见仓库根目录说明）**
   - `https://020814.xyz/gw/`：Go 控制面网关 `synchub-gateway`（`:5040`）+ 兜底流式中继节点 `main`
   - `https://020814.xyz/hub/` & `/api/hub/*`：SyncHub 云端收藏中心与离线投递服务（已支持设备 Bearer 令牌内省鉴权、定向离线投递 `to` 过滤、以及 `/api/hub/sc/*` 流式剪贴板代理）
   - `https://020814.xyz/`：官方 `syncclipboard-server` 容器（与官方桌面端 100% 混用互通）
2. **高速中继与打洞服务器（公网地址用 `RELAY_PUBLIC_URL` / `PUBLIC_IP` / `GATEWAY_STUN_URLS` / `GATEWAY_TURN_URLS` 提供）**
   - 独立无状态流式中继节点 `la`（零落盘内存转发，TLS SHA-256 证书指纹钉扎校验）
   - `coturn` STUN/TURN（HMAC 短期动态凭据，供跨网 WebRTC DataChannel P2P 打洞）

### 自动选路优先级
1. **局域网直连（`局域网直连`）**：mDNS + UDP 发现同网段地址，`:53318` 端到端加密直传，跑满本地网卡/Wi-Fi 带宽。
2. **跨网 WebRTC P2P（`直连 (WebRTC)`）**：经 `coturn` STUN/TURN 建立 `synchub-chunks` 有序 DataChannel 点对点传输。
3. **双 VPS 最优流式中继（`中继 · 洛杉矶` / `中继 · 主服务器`）**：并发测速自动优选 RTT 最低节点，服务端纯内存管道转发密文分块，零磁盘写入。
4. **离线云端投递（`云端投递`）**：目标设备离线时自动上传至自建 SyncHub 云端，对方上线后 `AutoPuller` 自动静默拉取到默认接收目录。

---

## 3. 安装包与构建产物（`dist/`）

| 平台 | 产物路径 | 安装与使用说明 |
|---|---|---|
| **Windows x64** | `dist/SyncHub-windows-x64.zip`<br>`dist/一键安装_SyncHub_Windows.bat` | 双击运行 `一键安装_SyncHub_Windows.bat`（无需管理员权限即可安装到 `%LOCALAPPDATA%\Programs\SyncHub`，自动创建桌面/开始菜单快捷方式、注册资源管理器右键菜单「发送到 SyncHub」、迁移旧版 `last_id` 进度，并可选停用旧版 `SyncHubAutoReceiver` 脚本） |
| **Android (64 位主流机型)** | `dist/SyncHub-android-arm64-v8a.apk` | 直接安装；在「设置 → Android 后台保活与静默剪贴板」可一键执行 **Root 自动授权全部权限**，或在 **LSPosed** 中勾选 `系统框架 (android)` 启用免无障碍毫秒级后台剪贴板同步 |
| **Android (32 位旧机型)** | `dist/SyncHub-android-armeabi-v7a.apk` | 适用于 32 位 ARM 设备，功能与 64 位版完全一致 |
| **macOS (Apple Silicon / Intel)** | `一键编译安装_SyncHub_Mac.command`<br>`scripts/build_mac.sh` | 在 Mac 上双击 `一键编译安装_SyncHub_Mac.command` 或执行 `bash scripts/build_mac.sh --install` 一键编译生成 `dist/SyncHub-macos.dmg` 并安装到 `/Applications/SyncHub.app`（自动配置菜单栏图标拖拽、Finder 右键快速操作「发送到跨端传输中心」与系统文本服务） |
| **全量源码交付包（含三端+双服务端）** | `dist/SyncHub-Next-全量源码包_含Mac一键编译.tar.gz`<br>`dist/SyncHub-Next-全量源码包_含Mac一键编译.zip` | 纯净无缓存全栈源码包（已统一 `LF` 换行符并预设 `0755` 可执行权限），详见 [macOS_编译与二次开发指南.md](macOS_编译与二次开发指南.md) |

### 默认接收目录（沿用既有习惯，可在「设置」随时更改）
- **Windows**：`K:\跨端传输文件`（若无 `K:` 盘自动回退至 `%USERPROFILE%\Downloads\跨端传输文件`）
- **macOS**：`~/Desktop/跨端传输文件`
- **Android**：`/storage/emulated/0/Download/跨端传输`

---

## 4. 目录结构

```text
synchub-next/
├── protocol/PROTOCOL.md            # P0 传输、信令、端到端加密与断点续传协议规范
├── server/
│   ├── gateway/                    # Go 控制面网关、独立流式中继节点与 hubctl CLI
│   ├── synchub/synchub_server.py   # 支持网关 Bearer 令牌、定向离线投递与 /api/hub/sc 代理的云端服务
│   └── deploy/                     # 双 VPS systemd 单元、Nginx 配置与 coturn 部署清单
├── app/                            # 三端统一 Flutter 客户端
│   ├── lib/core/                   # 传输引擎、AES-256-GCM 隔离池、mDNS/UDP、WebRTC、SyncClipboard 引擎、HubApi
│   ├── lib/platform/               # 三端系统桥接（托盘、CLI 200ms 防抖聚合、右键菜单注册、旧版平滑迁移）
│   ├── lib/ui/                     # 设备、传输、云端收藏中心、剪贴板历史、设置与配对引导页
│   ├── windows/                    # Win32 C++ 单实例锁、WM_COPYDATA、托盘菜单、DPAPI、GDI+ 剪贴板图像与 CF_HDROP
│   ├── macos/                      # AppKit Swift 菜单栏拖拽、NSPasteboard 隐私检测、Keychain、Finder 快速操作自安装
│   └── android/                    # Kotlin 前台服务、分享/选中文本/磁贴、EncryptedSharedPreferences、LSPosed Hook 与 Root 守护
├── scripts/                        # Windows / Android 构建脚本、Windows 一键安装器、macOS DMG 打包脚本与验收脚本
└── dist/                           # 打包完成的 Windows 发行版与 Android 签名 APK
```

---

## 5. 开发与自动化测试命令

```powershell
# 在 synchub-next 目录中执行。测试只绑定 127.0.0.1，不访问线上服务器。
# 1. 分层黑盒 E2E（Tiers 1–4）
$env:PYTHONPATH="."
python tests/run_all_e2e.py

# 2. Go 网关
cd server\gateway
go test -count=1 ./...
cd ..\..

# 3. Python SyncHub 服务端
cd server\synchub
pytest test_server_m1.py -v
cd ..\..

# 4. Flutter
cd app
flutter analyze
flutter test --concurrency=1
cd ..

# 5. Windows / Android 构建（Android 签名密钥只放本机）
powershell -ExecutionPolicy Bypass -File scripts\build_app.ps1 -Target all
```
