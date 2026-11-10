# SyncHub for macOS（菜单栏 App）

和 Windows 端、Android 端、网页版配合使用的 Mac 客户端：常驻菜单栏，自动接收其他设备发来的文件，可以从 Finder 右键、菜单栏图标、剪贴板或「服务」菜单发送。界面跟网页版一样，是浅色扁平风格，强调色为 macOS 蓝。

> 服务器和接口都没改，用的是现有的 `/api/hub/*` 接口。脚本和代码里没有写死任何账号密码，密码只保存在 Mac 的「钥匙串」中。

## 功能

| 功能 | 说明 |
|---|---|
| 菜单栏图标 ⇅ | 第一行显示连接状态（绿点表示已连接）、上次同步时间和自动接收开关。发送文件时图标旁会显示总进度百分比 |
| 最近项目 | 列出云端最新 8 条，显示来源设备、大小、多久之前发送，快到期的会提示剩余时间。**点文字**复制到剪贴板，**点文件**下载到接收文件夹并打开；按住 **⌥** 时，文件改为「在 Finder 中显示」，文字改为「在网页中查看」 |
| 发送文件… (⌘O) | 可多选，文件夹会自动压缩成 zip 再发 |
| 拖到图标上发送 | 把文件直接拖到菜单栏图标上松开即可 |
| 发送剪贴板 (⇧⌘V) | 剪贴板里是文件就上传文件；是截图或图片就转成 PNG 上传；是文字就发送文字，同时更新各设备共享的剪贴板 |
| 发送进度窗口 | 白底窗口，每个文件一行，显示进度条、速度和剩余时间，可以取消或重试。全部成功后 1.5 秒自动关闭（鼠标停在窗口上时不关），点「后台发送」可以先把窗口收起来 |
| 自动接收 | 逻辑和 Windows 端一样：每 3 秒检查一次，记住上次处理到的编号，不会重复下载；同名同大小的文件跳过，同名不同大小的存成 `名称 (1).扩展名`；下载时先写 `.downloading` 临时文件，完成后再改名。收到文件会弹出系统通知，点通知会在 Finder 中定位到这个文件 |
| Finder 右键 | 快速操作 →「发送到跨端传输中心」，文件会交给 App 并显示进度窗口 |
| 服务菜单 | 在任意 App 里选中文字，右键或应用菜单 → 服务 →「发送到 SyncHub」 |
| 设置 (⌘,) | 服务器地址（默认 `https://020814.xyz`）、用户名、密码（存在钥匙串里）、接收文件夹（默认 `~/Desktop/跨端传输文件`）、登录时启动、通知开关，还有「测试连接」按钮 |
| 登录时启动 | macOS 13 及以上用系统登录项（SMAppService）；macOS 12 用 LaunchAgent 代替 |
| URL Scheme | `synchub://send?path=/文件路径`、`synchub://clipboard`、`synchub://settings`、`synchub://web`，可以接到快捷指令或脚本里 |

## 安装

需要 **macOS 12 或更高版本**，以及 Xcode 命令行工具（约 1 GB，不需要装完整的 Xcode）。

1. 把整个 `03_macOS自动接收与Finder右键套件` 文件夹拷到 Mac 上，比如放到「下载」里。
2. 打开「终端」，执行：
   ```bash
   cd ~/Downloads/03_macOS自动接收与Finder右键套件
   bash install_mac_synchub.sh
   ```
3. 如果还没装命令行工具，会弹出系统安装窗口。点「安装」，装完回到终端按回车继续。
4. 脚本会自动编译出 `~/Applications/SyncHub.app`（大约 1 分钟），停掉旧版后台接收，装好 Finder 右键菜单，然后启动 App。
5. 第一次启动会打开设置窗口。确认服务器地址，服务器要求登录时再填用户名和密码，点「测试连接」→「保存」。系统询问是否允许通知时，点「允许」。
6. 「服务」菜单里的「发送到 SyncHub」如果没有出现，到「系统设置 → 键盘 → 键盘快捷键 → 服务 → 文本」里勾上。

从旧版升级时，安装程序会：
- 停用并删除旧的 LaunchAgent `xyz.020814.synchub`，这样不会出现两个程序同时下载。App 会接着读取旧版的 `~/.synchub/last_id.txt`，已经收过的文件不会再下载一遍。
- 删除旧的「📲 发送到跨端传输 (Windows与手机)」快速操作，换成「发送到跨端传输中心」，右键菜单里不会出现两个。
- 如果桌面上的「跨端传输文件」是旧版建的链接（指向 `~/Downloads/跨端传输文件`），会继续沿用，文件仍然存在原来的位置。

### 简易模式（兜底）

编译失败、不想装命令行工具，或者系统低于 macOS 12 时，会自动改用简易模式，也可以手动运行 `bash install_mac_synchub.sh --legacy`：
- 后台接收用的是系统自带的 JavaScript for Automation（`osascript`），不需要 Python 或 Xcode。逻辑和 App 一样，也会弹通知。
- Finder 右键发送用 `curl` 流式上传，没有进度窗口，只在开始和结束时各弹一次通知。
- 账号密码可以在安装时输入，密码存进钥匙串。
- 之后装好命令行工具，再运行一次 `bash install_mac_synchub.sh` 就会升级成菜单栏 App，并自动停掉简易模式的后台服务。

## 卸载

```bash
bash uninstall_mac_synchub.sh                  # 全部移除，包括钥匙串里的密码
bash uninstall_mac_synchub.sh --keep-settings  # 保留设置和密码
```
已经收到的文件不会被删除。

## 常见问题

- **重新安装后，系统提示「SyncHub 想要使用钥匙串中的机密信息」**：App 是本机签名（ad-hoc）的，每次重新编译签名都会变，点「始终允许」就行。
- **菜单栏里看不到图标**：菜单栏图标太多时会被刘海或其他图标挡住，可以按住 ⌘ 拖动调整位置，或者先退出几个菜单栏 App。
- **收不到文件**：打开菜单看第一行的状态。红点表示连接失败，后面会写原因，比如用户名或密码不对、网络错误。到「设置 → 测试连接」检查一下。
- **想换接收文件夹**：在「设置 → 保存到 → 更改…」里选新的位置。

## 文件结构

```
03_macOS自动接收与Finder右键套件/
├── install_mac_synchub.sh      # 一键安装（App 模式，失败时自动改用简易模式）
├── uninstall_mac_synchub.sh    # 卸载
├── README_zh.md
└── SyncHubMac/
    ├── build_app.sh            # 只用 swiftc 编译并打包 SyncHub.app，然后本地签名
    ├── Package.swift           # 可选：swift build / 用 Xcode 打开
    ├── Info.plist              # LSUIElement、synchub:// URL Scheme、服务菜单、文件类型
    ├── Resources/AppIcon.icns  # 图标（make_icon.py 生成）
    ├── Sources/SyncHub/
    │   ├── HubCore.swift       # 只依赖 Foundation：接口客户端和自动接收逻辑
    │   ├── AppDelegate.swift   # 菜单栏、菜单、拖放、URL Scheme、服务菜单
    │   ├── UploadManager.swift # 上传队列：从磁盘流式上传、取消、重试、文件夹压缩
    │   ├── UploadWindow.swift  # 进度窗口（SwiftUI）
    │   ├── SettingsWindow.swift
    │   ├── AppSettings.swift / Keychain.swift / LoginItem.swift / Notifier.swift
    │   └── main.swift
    └── Tests/LinuxHarness/main.swift   # HubCore 的接口测试（连本地 synchub_server.py 运行）
```

## 开发者备注

- 手动编译：`bash SyncHubMac/build_app.sh ~/Applications`。也可以在 `SyncHubMac/` 里执行 `swift build -c release`，或者直接用 Xcode 打开 `Package.swift`。
- 接口层测试（不连生产服务器）：先用 `test/run_local.py` 在本机起一个 `synchub_server.py`，然后执行：
  ```bash
  swiftc SyncHubMac/Sources/SyncHub/HubCore.swift SyncHubMac/Tests/LinuxHarness/main.swift -o harness
  ./harness http://127.0.0.1:<端口> /tmp/harness_work
  ```
- 网页侧边栏里「Mac 自动接收套件」下载的仍然是服务端内置的旧版脚本，因为服务端没有改动。要装菜单栏 App，请用这个文件夹里的安装脚本。
