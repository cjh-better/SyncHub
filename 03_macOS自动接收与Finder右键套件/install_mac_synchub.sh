#!/usr/bin/env bash
# ==============================================================================
# SyncHub macOS 一键安装（v2 · 菜单栏 App）
#
#   bash install_mac_synchub.sh            # 推荐：编译并安装菜单栏 App
#   bash install_mac_synchub.sh --legacy   # 简易模式：不编译，只装后台脚本（旧版行为）
#   bash install_mac_synchub.sh --no-launch
#
# 做的事：
#   1. 检查 Xcode 命令行工具（缺失时弹出系统安装窗口）
#   2. 编译 SyncHubMac/ → ~/Applications/SyncHub.app 并本地签名（ad-hoc）
#   3. 停用旧的 LaunchAgent 自动接收（xyz.020814.synchub），避免重复下载；沿用其进度记录
#   4. 安装 Finder 右键「快速操作 → 发送到跨端传输中心」（交给 App 显示进度窗口）
#   5. 启动 App（菜单栏图标），首次启动会打开设置窗口
#   编译失败或没有命令行工具时，自动退回简易模式（与旧脚本相同的后台接收 + 右键发送）。
#
# 不会修改服务器，也不会在脚本里写死任何账号密码（密码只保存在「钥匙串」）。
# ==============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SERVER_URL="${SYNCHUB_SERVER:-https://020814.xyz}"
APPS_DIR="$HOME/Applications"
APP="$APPS_DIR/SyncHub.app"
LEGACY_DIR="$HOME/.synchub"
OLD_PLIST="$HOME/Library/LaunchAgents/xyz.020814.synchub.plist"
SERVICES_DIR="$HOME/Library/Services"
WF_NAME="发送到跨端传输中心"
RECV_DIR="$HOME/Desktop/跨端传输文件"
KC_SERVICE="xyz.020814.synchub"

MODE="app"; LAUNCH=1
for a in "$@"; do
    case "$a" in
        --legacy) MODE="legacy" ;;
        --no-launch) LAUNCH=0 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    esac
done

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

[ "$(uname -s)" = "Darwin" ] || { echo "此脚本只能在 macOS 上运行"; exit 1; }
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"

# ------------------------------------------------------------------------------
has_clt() { xcrun --find swiftc >/dev/null 2>&1 && xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; }

ensure_clt() {
    has_clt && { ok "已检测到 Xcode 命令行工具 ($(xcode-select -p 2>/dev/null))"; return 0; }
    warn "未检测到 Xcode 命令行工具，正在打开系统安装窗口…"
    xcode-select --install >/dev/null 2>&1 || true
    if [ ! -t 0 ]; then warn "非交互环境，改用简易模式"; return 1; fi
    while true; do
        printf '  请在弹出的窗口中点「安装」，完成后按回车继续（输入 s 跳过，改用简易模式）: '
        read -r ans || return 1
        [ "$ans" = "s" ] || [ "$ans" = "S" ] && return 1
        has_clt && { ok "命令行工具已就绪"; return 0; }
        warn "还没检测到命令行工具，请等待安装完成"
    done
}

stop_old_agent() {
    if [ -f "$OLD_PLIST" ] || launchctl list 2>/dev/null | grep -q "xyz.020814.synchub$"; then
        launchctl bootout "gui/$(id -u)" "$OLD_PLIST" >/dev/null 2>&1 || launchctl unload "$OLD_PLIST" >/dev/null 2>&1 || true
        rm -f "$OLD_PLIST"
        ok "已停用旧版后台接收服务（避免重复下载）"
    fi
    pkill -f "synchub_mac_daemon" >/dev/null 2>&1 || true
}

prepare_recv_dir() {
    # 旧版把文件存到 ~/Downloads/跨端传输文件，并在桌面放了同名链接；有链接就沿用，文件不会分散两处。
    if [ -L "$RECV_DIR" ] || [ -d "$RECV_DIR" ]; then
        ok "接收文件夹: $RECV_DIR"
    else
        mkdir -p "$RECV_DIR" && ok "已创建接收文件夹: $RECV_DIR"
    fi
}

# 兜底发送脚本：App 不存在时 Finder 右键会用它（curl 流式上传，无进度窗口）。
write_send_script() {
    mkdir -p "$LEGACY_DIR"
    [ -f "$LEGACY_DIR/config" ] || printf 'SYNCHUB_SERVER="%s"\nSYNCHUB_USER=""\nSYNCHUB_RECV_DIR="%s"\n' "$SERVER_URL" "$RECV_DIR" > "$LEGACY_DIR/config"
    cat > "$LEGACY_DIR/synchub_send.sh" <<'SHEOF'
#!/usr/bin/env bash
# SyncHub 简易发送（无需 App）：curl 流式上传，密码从「钥匙串」读取，不写在脚本里。
. "$HOME/.synchub/config" 2>/dev/null
SERVER="${SYNCHUB_SERVER:-https://020814.xyz}"
USER_NAME="${SYNCHUB_USER:-$(defaults read xyz.020814.synchub username 2>/dev/null)}"
auth_cfg() {   # curl -K - ：密码经管道传给 curl，不出现在进程参数里
    [ -n "$USER_NAME" ] || return 0
    local pw; pw="$(security find-generic-password -s xyz.020814.synchub -a "$USER_NAME" -w 2>/dev/null)"
    pw="${pw//\\/\\\\}"; pw="${pw//\"/\\\"}"
    printf 'user = "%s:%s"\n' "$USER_NAME" "$pw"
}
enc2() { osascript -l JavaScript -e 'function run(a){return encodeURIComponent(encodeURIComponent(a[0]))}' "$1"; }
notify() { osascript -e "display notification \"${2//\"/\\\"}\" with title \"${1//\"/\\\"}\"" >/dev/null 2>&1; }
for f in "$@"; do
    tmpzip=""
    if [ -d "$f" ]; then
        tmpzip="$(mktemp -d)/$(basename "$f").zip"; ditto -c -k --sequesterRsrc --keepParent "$f" "$tmpzip" || continue; f="$tmpzip"
    fi
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    notify "🚀 跨端传输" "正在上传: $name"
    if auth_cfg | curl -sS -f -K - -T "$f" -H "Content-Type: application/octet-stream" \
        "$SERVER/api/hub/upload?filename=$(enc2 "$name")&from=Mac" >/dev/null; then
        notify "✅ 跨端传输完成" "已发送至 Windows 与手机: $name"
    else
        notify "❌ 跨端传输失败" "$name 上传失败，请检查网络或账号"
    fi
    [ -n "$tmpzip" ] && rm -rf "$(dirname "$tmpzip")"
done
SHEOF
    chmod +x "$LEGACY_DIR/synchub_send.sh"
}

# 简易模式的后台接收：JavaScript for Automation，不依赖 Python / Xcode。
write_legacy_receiver() {
    cat > "$LEGACY_DIR/synchub_mac_daemon.js" <<'JSEOF'
// SyncHub 简易自动接收（与 Windows 端逻辑一致：记录 last_id、同名同大小不重复下载、先写 .downloading 再改名）
ObjC.import('Foundation');
const app = Application.currentApplication(); app.includeStandardAdditions = true;
const HOME = ObjC.unwrap($.NSHomeDirectory());
const STATE = HOME + '/.synchub/last_id.txt';
function sh(c) { return app.doShellScript(c); }
function q(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }
function cfg(k, d) { try { const v = sh('. ~/.synchub/config >/dev/null 2>&1; printf %s "$' + k + '"'); return v || d; } catch (e) { return d; } }
const SERVER = cfg('SYNCHUB_SERVER', 'https://020814.xyz').replace(/\/+$/, '');
const DIR = cfg('SYNCHUB_RECV_DIR', HOME + '/Desktop/跨端传输文件');
const USER = cfg('SYNCHUB_USER', '');
const AUTH = USER ? '{ pw="$(security find-generic-password -s xyz.020814.synchub -a ' + q(USER) + ' -w 2>/dev/null)"; ' +
    'pw="${pw//\\\\/\\\\\\\\}"; pw="${pw//\\"/\\\\\\"}"; printf \'user = "%s:%s"\\n\' ' + q(USER) + ' "$pw"; } | ' : 'true | ';
function curl(args) { return sh('/bin/bash -c ' + q(AUTH + 'curl -sS -f -K - ' + args)); }
function readLast() { try { return parseInt(sh('cat ' + q(STATE)), 10) || 0; } catch (e) { return 0; } }
function writeLast(v) { sh('mkdir -p ~/.synchub && printf %s ' + v + ' > ' + q(STATE)); }
function size(p) { try { return parseInt(sh('stat -f %z ' + q(p)), 10); } catch (e) { return -1; } }
function exists(p) { try { sh('test -e ' + q(p)); return true; } catch (e) { return false; } }
function variant(name, i) { if (!i) return name; const d = name.lastIndexOf('.'); return d > 0 ? name.slice(0, d) + ' (' + i + ')' + name.slice(d) : name + ' (' + i + ')'; }
function pollOnce() {
    const last = readLast();
    const data = JSON.parse(curl('--max-time 15 ' + q(SERVER + '/api/hub/auto-pull?device=mac&since_id=' + last)));
    if (!data.ok) return;
    if (last <= 0) { writeLast(data.latestId || 0); return; }
    sh('mkdir -p ' + q(DIR));
    for (const it of (data.items || [])) {
        let name = String(it.filename || ('file_' + it.id)).split('/').pop().replace(/:/g, '_').trim();
        if (!name || name === '.' || name === '..') name = 'file_' + it.id;
        let i = 0, have = false;
        while (exists(DIR + '/' + variant(name, i))) { if (it.size > 0 && size(DIR + '/' + variant(name, i)) === it.size) { have = true; break; } i++; }
        if (!have) {
            const dest = DIR + '/' + variant(name, i), part = dest + '.downloading';
            try { curl('--max-time 7200 -o ' + q(part) + ' ' + q(SERVER + it.downloadUrl)); sh('mv ' + q(part) + ' ' + q(dest)); }
            catch (e) { try { sh('rm -f ' + q(part)); } catch (_) {} if (it.id - 1 > readLast()) writeLast(it.id - 1); return; }
            app.displayNotification('来自 ' + (it.fromDevice || '其他设备') + ': ' + variant(name, i), { withTitle: '📥 跨端传输已自动保存' });
        }
        if (it.id > readLast()) writeLast(it.id);
    }
    if ((data.latestId || 0) > readLast()) writeLast(data.latestId);
}
while (true) { try { pollOnce(); } catch (e) {} delay(3); }
JSEOF
    cat > "$OLD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>xyz.020814.synchub</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/osascript</string>
        <string>-l</string><string>JavaScript</string>
        <string>$LEGACY_DIR/synchub_mac_daemon.js</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict>
</plist>
EOF
    mkdir -p "$HOME/Library/LaunchAgents"
    launchctl bootout "gui/$(id -u)" "$OLD_PLIST" >/dev/null 2>&1 || launchctl unload "$OLD_PLIST" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$OLD_PLIST" >/dev/null 2>&1 || launchctl load "$OLD_PLIST"
    ok "已启动简易后台接收（LaunchAgent xyz.020814.synchub）"
}

ask_legacy_credentials() {
    [ -t 0 ] || return 0
    printf '  服务器若开启了账号认证，请输入用户名（没有就直接回车）: '
    read -r u || return 0
    [ -n "$u" ] || return 0
    /usr/bin/sed -i '' "s/^SYNCHUB_USER=.*/SYNCHUB_USER=\"${u//\"/}\"/" "$LEGACY_DIR/config"
    echo "  请输入密码（保存到「钥匙串」，输入时不显示）:"
    security add-generic-password -U -s "$KC_SERVICE" -a "$u" -l "SyncHub 跨端传输 ($u)" -w && ok "密码已保存到钥匙串"
}

install_quick_action() {
    mkdir -p "$SERVICES_DIR"
    rm -rf "$SERVICES_DIR/📲 发送到跨端传输 (Windows与手机).workflow"     # 旧版名称，避免菜单重复
    local WF="$SERVICES_DIR/$WF_NAME.workflow/Contents"
    rm -rf "$SERVICES_DIR/$WF_NAME.workflow"; mkdir -p "$WF"
    cat > "$WF/Info.plist" <<WFI
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSServices</key>
	<array>
		<dict>
			<key>NSIconName</key>
			<string>NSActionTemplate</string>
			<key>NSMenuItem</key>
			<dict>
				<key>default</key>
				<string>$WF_NAME</string>
			</dict>
			<key>NSMessage</key>
			<string>runWorkflowAsService</string>
			<key>NSRequiredContext</key>
			<dict>
				<key>NSApplicationIdentifier</key>
				<string>com.apple.finder</string>
			</dict>
			<key>NSSendFileTypes</key>
			<array>
				<string>public.item</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
WFI
    # 有 App：交给 App（显示进度窗口，可取消/重试）；没有 App：用 curl 兜底脚本。
    local CMD='APP="$HOME/Applications/SyncHub.app"
if [ -d "$APP" ]; then open -a "$APP" "$@"; else "$HOME/.synchub/synchub_send.sh" "$@"; fi'
    CMD="${CMD//&/&amp;}"; CMD="${CMD//</&lt;}"; CMD="${CMD//>/&gt;}"
    cat > "$WF/document.wflow" <<WFD
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AMApplicationBuild</key><string>523</string>
	<key>AMApplicationVersion</key><string>2.10</string>
	<key>AMDocumentVersion</key><string>2</string>
	<key>actions</key>
	<array>
		<dict>
			<key>action</key>
			<dict>
				<key>AMAccepts</key>
				<dict>
					<key>Container</key><string>List</string>
					<key>Optional</key><true/>
					<key>Types</key><array><string>com.apple.cocoa.string</string></array>
				</dict>
				<key>AMActionVersion</key><string>2.0.3</string>
				<key>AMApplication</key><array><string>Automator</string></array>
				<key>AMParameterProperties</key>
				<dict>
					<key>COMMAND_STRING</key><dict/>
					<key>CheckedForUserDefaultShell</key><dict/>
					<key>inputMethod</key><dict/>
					<key>shell</key><dict/>
					<key>source</key><dict/>
				</dict>
				<key>AMProvides</key>
				<dict>
					<key>Container</key><string>List</string>
					<key>Types</key><array><string>com.apple.cocoa.string</string></array>
				</dict>
				<key>ActionBundlePath</key><string>/System/Library/Automator/Run Shell Script.action</string>
				<key>ActionName</key><string>Run Shell Script</string>
				<key>ActionParameters</key>
				<dict>
					<key>COMMAND_STRING</key><string>$CMD</string>
					<key>CheckedForUserDefaultShell</key><true/>
					<key>inputMethod</key><integer>1</integer>
					<key>shell</key><string>/bin/bash</string>
					<key>source</key><string></string>
				</dict>
				<key>BundleIdentifier</key><string>com.apple.RunShellScript</string>
				<key>CFBundleVersion</key><string>2.0.3</string>
				<key>CanShowSelectedItemsWhenRun</key><false/>
				<key>CanShowWhenRun</key><true/>
				<key>Class Name</key><string>RunShellScriptAction</string>
				<key>InputUUID</key><string>5B0E6C1E-3D5A-4C1F-9C7E-0A1B2C3D4E01</string>
				<key>OutputUUID</key><string>5B0E6C1E-3D5A-4C1F-9C7E-0A1B2C3D4E02</string>
				<key>UUID</key><string>5B0E6C1E-3D5A-4C1F-9C7E-0A1B2C3D4E03</string>
				<key>isViewVisible</key><integer>1</integer>
			</dict>
		</dict>
	</array>
	<key>connectors</key><dict/>
	<key>workflowMetaData</key>
	<dict>
		<key>applicationBundleIDsByPath</key><dict/>
		<key>applicationPaths</key><array/>
		<key>inputTypeIdentifier</key><string>com.apple.Automator.fileSystemObject</string>
		<key>outputTypeIdentifier</key><string>com.apple.Automator.nothing</string>
		<key>presentationMode</key><integer>15</integer>
		<key>processesInput</key><integer>0</integer>
		<key>serviceInputTypeIdentifier</key><string>com.apple.Automator.fileSystemObject</string>
		<key>serviceOutputTypeIdentifier</key><string>com.apple.Automator.nothing</string>
		<key>serviceProcessesInput</key><integer>0</integer>
		<key>systemImageName</key><string>NSActionTemplate</string>
		<key>useAutomaticInputType</key><integer>0</integer>
		<key>workflowTypeIdentifier</key><string>com.apple.Automator.servicesMenu</string>
	</dict>
</dict>
</plist>
WFD
    plutil -lint "$WF/Info.plist" "$WF/document.wflow" >/dev/null && ok "已安装 Finder 右键「快速操作 → ${WF_NAME}」"
    /System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true
    /System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------
say "SyncHub for macOS 安装程序（macOS $(sw_vers -productVersion)）"
[ "$MACOS_MAJOR" -ge 12 ] || { warn "菜单栏 App 需要 macOS 12 或更高，改用简易模式"; MODE="legacy"; }

prepare_recv_dir
write_send_script

if [ "$MODE" = "app" ]; then
    say "1/4 检查 Xcode 命令行工具"
    if ensure_clt; then
        say "2/4 编译 SyncHub.app"
        if bash "$HERE/SyncHubMac/build_app.sh" "$APPS_DIR" && [ -x "$APP/Contents/MacOS/SyncHub" ]; then
            ok "已安装到 $APP"
        else
            warn "编译失败，改用简易模式（功能与旧版脚本相同）。可把上面的报错发给我。"
            MODE="legacy"
        fi
    else
        MODE="legacy"
    fi
fi

if [ "$MODE" = "app" ]; then
    say "3/4 迁移旧版自动接收"
    stop_old_agent
    [ "$SERVER_URL" != "https://020814.xyz" ] && defaults write xyz.020814.synchub serverURL "$SERVER_URL"
    say "4/4 安装 Finder 右键菜单并启动"
    install_quick_action
    if [ "$LAUNCH" = "1" ]; then open "$APP" && ok "SyncHub 已启动（看屏幕右上角菜单栏的 ⇅ 图标）"; fi
    echo
    say "✅ 安装完成"
    echo "  • 菜单栏图标：最近项目、发送文件、发送剪贴板、设置；把文件拖到图标上即可发送"
    echo "  • Finder 右键 → 快速操作 → $WF_NAME"
    echo "  • 任意 App 选中文字 → 右键 / 应用菜单 → 服务 → 发送到 SyncHub"
    echo "  • 收到的文件保存在: $RECV_DIR"
    echo "  • 首次启动会弹出设置窗口；服务器开启了账号认证时在那里填写（密码存入钥匙串）"
else
    say "简易模式安装（后台脚本 + Finder 右键）"
    ask_legacy_credentials
    write_legacy_receiver
    install_quick_action
    echo
    say "✅ 简易模式安装完成"
    echo "  • 收到的文件保存在: $RECV_DIR"
    echo "  • Finder 右键 → 快速操作 → $WF_NAME"
    echo "  • 以后装好 Xcode 命令行工具后，重新运行本脚本即可升级为菜单栏 App"
fi
