# SyncHub Android（App + LSPosed 模块 二合一）

一个 APK 同时是：
- **SyncHub 手机客户端**：剪贴板双向同步（与 Windows / macOS 上的官方 SyncClipboard 客户端互通）、自动接收电脑发来的文件到 `/sdcard/Download`、系统分享菜单 / 文字选择菜单 / 快捷设置磁贴一键发送；
- **LSPosed 模块**：在系统框架里放开本应用的后台剪贴板读取（Android 10 起系统禁止后台应用读剪贴板），并去掉 Android 12+ 的“已粘贴自剪贴板”提示。

设计目标：**像电脑端一样**——打开 App，填一次账号，授予 Root，之后全部自动。

---

## 一、安装步骤

1. 安装 `SyncHub.apk`（自签名包，见文末“签名”）。
2. 打开 SyncHub：
   - 服务器地址已预填 `https://020814.xyz`，填写 **用户名 / 密码**（即 SyncClipboard 服务端账号，加密保存在本机，代码里没有任何内置账号）；
   - 点 **「连接并一键配置」** → Magisk / KernelSU / APatch 弹出授权时选 **允许（永久）**。
3. 一键配置会自动完成（每一步在界面上显示 完成 / 失败）：
   | 步骤 | 实际执行（root） |
   |---|---|
   | 通知权限 (Android 13+) | `pm grant xyz.synchub.android android.permission.POST_NOTIFICATIONS` |
   | 写入 /sdcard/Download | Android 11+：`appops set … MANAGE_EXTERNAL_STORAGE allow`；Android 10：`pm grant … WRITE/READ_EXTERNAL_STORAGE` |
   | 剪贴板 AppOp | `appops set … READ_CLIPBOARD allow` |
   | 后台运行 | `appops set … RUN_IN_BACKGROUND allow` / `RUN_ANY_IN_BACKGROUND allow` |
   | 电池优化白名单 | `dumpsys deviceidle whitelist +xyz.synchub.android` |
   | 待机分组 (Android 12+) | `am set-standby-bucket … active` |
   | 隐藏系统剪贴板读取提示（可选，默认勾选；Android 12+） | `settings put secure clipboard_show_access_notifications 0`（等同于 设置→隐私→“显示剪贴板访问通知” 关闭，可随时改回；已启用 LSPosed 模块时不会执行） |
   | 开启剪贴板上传/接收、自动接收、开机自启，并启动同步服务 | — |
   | 检测旧版 Root 脚本 | 若发现 `/data/adb/service.d/synchub_android.sh`（原 `04_Android_Root自动落盘套件`），**弹窗询问**是否停止并移除（会备份为 `/data/adb/synchub_android.sh.bak`，并沿用它记录的接收进度 `/data/adb/synchub_last_id`，避免重复下载）。选“保留”则不动。 |
4. 完成后进入主页：一页看到 **服务器已连接 / 剪贴板同步模式 / 自动接收已开启 / LSPosed 模块 / Root**，下面是 SyncHub 最近条目（点文字=复制，点文件=下载）。
5. （可选，推荐）启用 LSPosed 模块：LSPosed 管理器 → 模块 → 启用 **SyncHub** → 作用域勾选 **系统框架（android）** 和 **SyncHub** → **重启手机**。重启后主页“LSPosed 模块”显示“已激活”，剪贴板来源自动切换为“LSPosed 模块”。
6. 可选：下拉快捷设置 → 编辑 → 把 **「发送剪贴板」** 磁贴拖进来。

> 没有 Root 也能用：一键配置会改为弹系统授权（通知、电池优化）。此时“上传本机剪贴板”只在打开 App 时进行（系统限制），接收电脑剪贴板、自动接收文件、分享/选择文字发送都正常。

## 二、功能

### 1. 剪贴板后台双向同步（SyncClipboard 官方协议，v3.1.1+）
- 轮询 `GET /SyncClipboard.json`（默认 3 秒，可设 1–30 秒）；熄屏时放慢 4 倍（最长 30 秒），失败指数退避（最长 60 秒），网络恢复/亮屏立即唤醒。
- 推送：文本 `PUT /SyncClipboard.json`（`type/hash/text/hasData/dataName/size`，hash = SHA256(UTF-8) 大写十六进制）；**超过 10240 字符**与官方客户端一致改为先 `PUT /file/Text_….txt` 再提交 `hasData=true`；图片 `PUT /file/<名>` + `type=Image`，hash = SHA256(`文件名|内容SHA256`)。
- 拉取：Text（含长文本附件）写入手机剪贴板；Image（≤20 MB）通过 FileProvider 写入剪贴板；File/Group 交给“自动接收”。
- 防回环：最近 32 个已推送/已写入的 hash 去重；首次启动只记录远端基线，不覆盖手机当前剪贴板。
- 读取 JSON 时兼容 camelCase（官方服务器）与 PascalCase（`synchub_server.py` 的 `/api/hub/text` 直接写的格式）以及旧版 `Clipboard/File` 字段。
- 本机剪贴板来源（自动选择）：
  1. **LSPosed 模块**（已激活时）：系统允许本应用后台读取 → 用标准 `OnPrimaryClipChangedListener`，支持文字和图片；
  2. **Root 兼容模式**（未启用模块但有 Root）：用 `su` 启动 `app_process` 子进程并降权为 shell（uid 2000），以 `com.android.shell` 身份监听剪贴板（AOSP 中 Shell 持有 `READ_CLIPBOARD_IN_BACKGROUND`，Android 10–15 均有此放行分支）。只支持文字；
  3. **仅前台**：都没有时，只在 App 获得焦点时上传一次。
- 自己发出的文本/图片不会被“自动接收”再下载回来。

### 2. 系统菜单发送
- **分享菜单「发送到 SyncHub」**：文字、单个/多个文件或图片（`ACTION_SEND` / `ACTION_SEND_MULTIPLE`），流式上传到 `POST /api/hub/upload?filename=&from=Android`（与 Windows 右键同协议），每个文件一个进度通知，完成/失败都有通知。
- **文字选择浮动菜单「发送到 SyncHub」**（`ACTION_PROCESS_TEXT`）。
- **快捷设置磁贴「发送剪贴板」**：打开一个透明窗口取得焦点后读取剪贴板（因此无需 Root），文字直接发送，图片/文件 URI 作为文件上传。
- 文字发送走 SyncClipboard 协议（会同时出现在 SyncHub 列表并同步到电脑剪贴板）；失败时退回 `POST /api/hub/text`。

### 3. 自动接收（替代原 root shell 脚本）
- 与 Windows 客户端 / 原脚本相同逻辑：`GET /api/hub/auto-pull?device=android&since_id=<上次>`；首次只记录位置不回补历史；已存在且大小一致跳过；同名不同大小另存 `名称 (1).ext`；先写 `.downloading` 再改名；全部成功才推进进度（单个文件连续失败 3 次后跳过，不会卡死）。
- 保存到 `/sdcard/Download/跨端传输/`（子目录可在设置里改，留空 = Download 根目录）。有“所有文件访问”权限时直接写文件并触发媒体扫描；没有时退回 MediaStore.Downloads（无需权限）。
- 收到文件弹通知，点通知直接打开。

### 4. 其它
- 账号密码存放在 EncryptedSharedPreferences（Android Keystore AES-256），不参与云备份。
- 开机自启（`BOOT_COMPLETED`，Android 14+ 使用 `specialUse` 前台服务类型，不受 Android 15 dataSync 6 小时限制）。
- 设置页：服务器/账号/本机名称、轮询间隔、各开关、重新运行 Root 一键配置、电池白名单、通知权限、所有文件访问、检测并移除旧脚本、查看日志。
- 界面与 Web 端改版一致：浅灰底 + 白卡片、0.5dp 发丝分隔线、唯一的系统蓝 `#007AFF` 强调色、系统字体。

## 三、LSPosed 钩子说明

| 作用域 | 钩子 | 作用 | 预期适用 |
|---|---|---|---|
| 系统框架 `android` | `com.android.server.clipboard.ClipboardService#clipboardAccessAllowed`（**全部重载**，第 2 个参数恒为 callingPackage） | 调用方为本应用且原结果为 false 时改为 true：放开后台 `getPrimaryClip` / `hasPrimaryClip` / 剪贴板变化回调分发 | AOSP Android 10、11、12/12L、13、14、15（已对照各版本 AOSP 源码确认签名） |
| 系统框架 `android` | `ClipboardService#showAccessNotificationLocked` | 本应用读取时不弹“已粘贴自剪贴板”提示 | Android 12–15 |
| 本应用 | `ModuleStatus.isActive()` → true | 主页显示“模块已激活” | 所有版本 |

每个钩子单独 try/catch，失败只写 LSPosed 日志（`[SyncHub] … failed`），不影响其他钩子和系统。主页会根据实际读取结果显示“系统框架钩子未生效”提醒。

## 四、已知限制（按版本 / ROM）
- **Android 10–15（AOSP / 类原生）**：LSPosed 模式与 Root 兼容模式均按 AOSP 源码实现，**但未在真机上验证**。
- **Root 兼容模式**：只同步文字（图片上传需 LSPosed 模式）；Android 12+ 系统会以“Shell”名义弹读取提示，所以一键配置默认关闭该系统提示（全局开关，影响所有应用的提示，可在系统隐私设置里改回）。
- **MIUI / HyperOS、ColorOS、OriginOS、One UI** 等对剪贴板有额外管控（如 MIUI 的“读取剪贴板”权限、三星自有剪贴板服务）：LSPosed 钩子可能不完全生效；请在系统权限里再允许 SyncHub 读取剪贴板，或使用 Root 兼容模式。
- **Android 13+** 写入剪贴板时系统可能显示剪贴板预览浮层（已标记为“来自其他设备”的内容）。
- **Android 14+** 快捷设置磁贴需要通过 PendingIntent 打开透明窗口，部分 ROM 上会先收起通知栏再读取。
- 后台常驻依赖前台服务 + 电池白名单；国产 ROM 仍可能需要在“自启动 / 后台高耗电”里手动放行。
- 文件类剪贴板（电脑上复制文件）不写入手机剪贴板，而是通过“自动接收”保存到 Download。
- SyncHub 列表只显示最近 60 条。

## 五、构建与测试
- 源码：本目录 `src/`（Kotlin + Jetpack Compose，minSdk 29 / targetSdk 35，AGP 8.7.3，Gradle 8.11.1，JDK 17）。
- 构建：`./gradlew assembleRelease`（R8 已开启，Xposed / app_process 入口有 keep 规则）。
- 签名：仓库不含 keystore。复制 `keystore.properties.example` 为 `keystore.properties`（已 gitignore）并填写自己的 keystore 路径与密码，或设置环境变量 `SYNCHUB_KEYSTORE_FILE` / `SYNCHUB_KEYSTORE_PASSWORD` / `SYNCHUB_KEY_ALIAS` / `SYNCHUB_KEY_PASSWORD`。未配置时 release 包不签名。升级已安装的 App 必须使用同一个 keystore，否则需要先卸载。
- 测试：`testenv/start_local.sh` 在本机启动 **SyncClipboard 官方服务器 v3.3.3** + `synchub_server.py`（共用同一个 `history.db`，与生产布局一致）+ 一个按生产 nginx 规则路由的小代理，然后：
  `SYNCHUB_IT_URL=http://127.0.0.1:15080 SYNCHUB_IT_USER=testuser SYNCHUB_IT_PASS=testpass ./gradlew testDebugUnitTest`
  测试代码拒绝指向生产域名。

### 测试情况（如实说明）
- ✅ 已通过：16 个 JVM 测试——Hash 规则与官方服务器一致、JSON 兼容解析、短文本/超长文本/图片与 **SyncClipboard 官方服务器 v3.3.3** 往返、手机↔电脑双向且不回环、模拟 Windows 客户端推送被手机拉取、SyncHub 流式上传（3 MB，带进度）、自动接收（基线、不重复、跳过自己发的、同名另存）、收藏/删除/下载、错误密码 401；以及 2 张 Robolectric 界面截图（`out/screenshots/`）。
- ✅ `lintRelease` 0 错误；APK 已用 apksigner 校验签名。
- ❌ **未在真机或模拟器上运行**：本机无法启动 Android 模拟器（KVM 不可用），因此 LSPosed 钩子、Root 兼容模式进程、Root 一键配置命令、前台服务/开机自启、分享菜单、磁贴、通知等 Android 端行为**均未实测**，是按 AOSP 10–15 源码编写的。首次安装请留意主页状态和“设置 → 查看日志”，LSPosed 日志里搜 `[SyncHub]`。

## 六、同步不工作时怎么查（1.0.2 起）

打开 App →「设置 → 查看日志」，右上角「分享」可把日志连同版本 / 状态一起发出来。日志会写到文件里，进程被杀、应用更新后仍然保留。重点看这些行：

| 日志 | 含义 / 处理 |
|---|---|
| `写入剪贴板没有生效：系统剪贴板仍是写入前的内容…` （同时弹通知） | 系统拦截了后台写剪贴板。**realme / OPPO / OnePlus（ColorOS / realme UI）**：设置 → 应用 → SyncHub → 权限 → 剪贴板 → 改为「始终允许」（「仅在使用中允许」会让两个方向都失效） |
| `同步服务启动 v1.0.2 … 已配置=false` 或 `账号存储=不可用` | 读不到账号，同步不会进行 → 设置里重新填写账号并保存 |
| `LSPosed 系统框架钩子检测: 本次开机未加载…` + `改用 Root 兼容模式` | LSPosed 模块刚启用 / 刚更新后没重启，或作用域没勾「系统框架」。已自动改用 Root 模式继续同步；想用 LSPosed 模式就勾好作用域并重启手机 |
| `剪贴板来源: …` | 当前使用的读取方式（LSPosed / Root 兼容 / 仅前台） |
| `Root 剪贴板进程就绪` / `Root 剪贴板进程退出` / `clip-helper: ERR …` | Root 读取进程的状态；`read-null` 表示系统拒绝了 Shell 读取剪贴板 |
| `剪贴板变化了，但读到的内容为空` | 系统拒绝了后台读取剪贴板（LSPosed 钩子没生效） |
| `本地剪贴板[root/system]: 已推送 …` / `… 跳过` | 手机 → 服务器的每次决定和原因 |
| `远端: …` / `已写入远端文本到手机剪贴板` | 服务器 → 手机的每次决定和原因 |
| `拉取剪贴板失败 (#n) — …` | 网络 / 账号问题，后面是具体错误（HTTP 401 = 密码错，超时 = 网络或省电限制） |
| `心跳：30 分钟内拉取 N 次 …` | 服务还活着；长时间没有心跳说明服务被杀 |
| `看门狗：同步服务未运行…` / `服务被系统重新拉起` | 服务曾被系统或厂商省电策略杀掉 |
| `无法进入前台服务` | 系统不允许后台启动服务 → 系统设置里把 SyncHub 电池设为「不限制」、允许自启动 / 后台运行 |

### 1.0.4 更新
- **可以直接查看文件了**：首页点文件条目，本机已有（`Download/跨端传输/` 里同名同大小）就用系统应用打开；没有就先带登录信息下载（显示进度，可「后台下载」或取消），下载完自动打开。找不到对应类型的应用时弹「打开方式」，确实没有应用时提示「没有可以打开此文件的应用」。
- 点文字条目查看全文（可选择、可复制）；长按条目：打开 / 分享 / 在文件夹中显示 / 仅下载到本机 / 复制。
- 新增「已接收文件」页面（首页入口）：列出接收文件夹里的文件，点一下打开，长按分享；右上角「文件管理」尝试用系统文件管理打开该文件夹。
- 收到 APK 可直接点「安装」（例如 SyncHub 自更新）：首次会跳到「安装未知应用」授权页，允许后返回再点一次。
- **通知点了没反应的问题已修复**：「已接收 / 已下载」通知现在先打开 SyncHub 内的 OpenFileActivity（PendingIntent.getActivity，没有跳板），由它检查文件和权限后再调起查看器或安装器，任何失败都会提示；其它通知点开进入 App。
- 修复：传输服务的前台通知 id 与「剪贴板权限」提示相同，传输结束时会把该提示一起清掉。

### 1.0.3 更新
- 首页「最近条目」排序与网页版、Mac 一致：置顶 → 收藏 → 其余按时间从新到旧。
- 去掉条目前面的类型图标，条目更简洁；文件在说明行开头用扩展名标注（如 `PDF · Windows · …`），置顶 / 收藏也写在说明行里。
- 首页新增「存储空间」卡片：已用 / 总容量与百分比、细进度条（用量 ≥85% 变橙、≥95% 变红），以及剩余空间和 SyncHub 自身占用。数据来自 `GET /api/hub/storage`（需登录），读取失败不影响其它功能。

### 1.0.2 更新
- LSPosed 模式只在「系统框架」钩子本次开机确实生效时使用（模块在 `/data/system/synchub_lsposed` 写入标记，App 用 Root 读取校验）；否则自动改用 Root 兼容模式。之前启用了模块但没重启时，App 一到后台剪贴板上传就会静默失效。
- 轮询协程任何异常都不会再静默停止：捕获全部异常、指数退避、意外退出 5 秒后自动重启。
- 新增看门狗（每 15 分钟）：服务被杀自动拉起，轮询卡住超过 3 分钟自动重启；打开 App 时发现服务没在运行也会自动恢复；应用更新后总是恢复服务。
- 系统拒绝前台服务时不再让应用崩溃（之前可能崩溃循环导致服务长时间不运行）。
- 远端长文本下载失败不再丢失这次变化，下次轮询重试（同一条连续 3 次失败才放弃）。
- 写入手机剪贴板后回读确认；被系统拦截时记 W 日志并弹通知，提示把剪贴板权限改为「始终允许」（ColorOS / realme UI 的「仅在使用中允许」就是 1.0.1 实测两个方向都不同步的原因）。realme / OPPO / OnePlus 机型在首次配置页和设置页显示该提示和跳转入口。
- 写入手机剪贴板失败时撤销防回环标记。
- 每次推送 / 拉取决定都写日志（只记长度和 hash 前缀，不记正文、不记密码）；日志持久化到文件并可一键分享。
