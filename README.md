# SyncHub

SyncHub 是在 [SyncClipboard](https://github.com/Jeric-X/SyncClipboard) 基础上扩展的跨端剪贴板与文件传输方案：

- **服务端**：官方 SyncClipboard 服务器（Docker）+ `synchub_server.py`，共用同一个 `history.db`，提供兼容 SyncClipboard v3 协议的剪贴板同步，以及「跨端传输中心」Web 界面（类 macOS 浅色扁平风格，`/hub/`）：大文件流式上传、分类、收藏、置顶、批量删除、3 天自动清理。
- **Windows 客户端**：SyncClipboard 官方客户端 + 右键「发送到跨端传输」与后台自动接收。
- **macOS 客户端**：Swift 菜单栏 App，剪贴板自动双向同步、Finder 右键发送、文件自动落盘到桌面 `跨端传输文件`。
- **Android 客户端**：Kotlin + Compose，需 Root；同时是 LSPosed 模块（Hook 不可用时回退到 Root 模式），剪贴板双向同步与文件自动接收。

## 目录结构

| 目录 | 内容 |
| :--- | :--- |
| `00_交付说明与使用手册/` | 详细说明：[README](00_交付说明与使用手册/README.md)、[使用手册](00_交付说明与使用手册/USER_MANUAL.md)、[部署与运维](00_交付说明与使用手册/DEPLOYMENT_AND_OPS_GUIDE.md) |
| `01_服务端_SyncClipboard与SyncHub/` | `synchub_server.py`、docker-compose、nginx、systemd、备份脚本 |
| `02_Windows客户端与右键套件/` | `synchub_client.py`、一键安装 bat、`SyncClipboard.json.example` |
| `03_macOS自动接收与Finder右键套件/` | Mac App 源码（`SyncHubMac/`）与安装 / 卸载脚本 |
| `04_Android_Root自动落盘套件/` | Android App 源码（`SyncHub_App/src/`）与 Root 守护脚本 |
| `05_自动化部署与验收测试脚本/` | 部署到 VPS、端到端验收脚本 |

## 快速开始

1. **配置**：`cp .env.example .env`，填写自己的密码、服务器地址等。
2. **服务端**：`cd 01_服务端_SyncClipboard与SyncHub && docker compose --env-file ../.env -f docker-compose.syncclipboard.yml up -d`；再用 `synchub.service` 运行 `synchub_server.py`（需设置 `SYNCHUB_USER` / `SYNCHUB_PASSWORD` 环境变量），按 `nginx_020814.xyz.conf` 配置反代。
3. **Windows**：安装 SyncClipboard 官方客户端，参考 `SyncClipboard.json.example` 填写服务器与账号，再运行 `一键安装_Windows右键与自动接收.bat`。
4. **macOS**：在 `03_macOS自动接收与Finder右键套件/` 中运行 `bash install_mac_synchub.sh`（会在本机编译 App）。
5. **Android**：到 [Releases](../../releases) 下载 APK 安装，或在 `04_Android_Root自动落盘套件/SyncHub_App/src/` 用 `./gradlew assembleRelease` 自行构建（签名见下）。

## 配置（环境变量）

所有账号、密码、VPS 地址都通过环境变量读取，示例见 [`.env.example`](.env.example)。服务器地址默认为 `https://020814.xyz`，可用 `SYNCHUB_SERVER_URL` / `SYNCHUB_SERVER_HOST` 覆盖。

Android 签名：复制 `04_Android_Root自动落盘套件/SyncHub_App/src/keystore.properties.example` 为 `keystore.properties`（不会被提交），或设置 `SYNCHUB_KEYSTORE_*` 环境变量。

## 安全说明

- 仓库中不包含任何真实密码、SSH 凭据、keystore 或 `.env`；请勿把它们提交上来（`.gitignore` 已排除）。
- 请为 SyncClipboard / SyncHub 设置强密码，并只通过 HTTPS 访问。
- `/hub/` 网页和全部 `/api/hub/*` 接口都要求 HTTP Basic 认证，账号密码与 SyncClipboard 服务端相同。`synchub_server.py` 先读环境变量 `SYNCHUB_USER` / `SYNCHUB_PASSWORD`，没有就读 SyncClipboard 的 docker compose 文件（`SYNCCLIPBOARD_USERNAME` / `SYNCCLIPBOARD_PASSWORD`）；都读不到时拒绝所有请求。Windows 客户端自动使用本机 SyncClipboard 客户端里登录的账号。
- 编译好的 APK、Mac 安装包等二进制文件不放在仓库里，APK 通过 GitHub Releases 发布。
