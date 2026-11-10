#!/usr/bin/env bash
# SyncHub macOS 卸载：删除 App、登录项、右键菜单、后台服务与设置。
# 已接收的文件（~/Desktop/跨端传输文件）不会删除。
#   bash uninstall_mac_synchub.sh               # 全部卸载（含钥匙串中的密码）
#   bash uninstall_mac_synchub.sh --keep-settings
set -uo pipefail
KEEP=0; [ "${1:-}" = "--keep-settings" ] && KEEP=1
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
[ "$(uname -s)" = "Darwin" ] || { echo "此脚本只能在 macOS 上运行"; exit 1; }
UID_NUM="$(id -u)"

# 1. 退出 App
if pgrep -x SyncHub >/dev/null 2>&1; then
    osascript -e 'quit app "SyncHub"' >/dev/null 2>&1 || true
    sleep 1; pkill -x SyncHub >/dev/null 2>&1 || true
    ok "已退出 SyncHub"
fi

# 2. 登录项（LaunchAgent 兜底方式；SMAppService 登录项会随 App 删除自动失效）与旧版后台接收
for label in xyz.020814.synchub.app xyz.020814.synchub; do
    plist="$HOME/Library/LaunchAgents/$label.plist"
    if [ -f "$plist" ]; then
        launchctl bootout "gui/$UID_NUM" "$plist" >/dev/null 2>&1 || launchctl unload "$plist" >/dev/null 2>&1 || true
        rm -f "$plist"; ok "已移除 $label"
    fi
done
pkill -f synchub_mac_daemon >/dev/null 2>&1 || true

# 3. App
for app in "$HOME/Applications/SyncHub.app" "/Applications/SyncHub.app"; do
    [ -d "$app" ] && rm -rf "$app" && ok "已删除 $app"
done

# 4. Finder 右键快速操作（新旧名称）
for wf in "发送到跨端传输中心" "📲 发送到跨端传输 (Windows与手机)"; do
    p="$HOME/Library/Services/$wf.workflow"
    [ -d "$p" ] && rm -rf "$p" && ok "已删除快速操作「${wf}」"
done
/System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true

# 5. 设置、进度记录与钥匙串密码
if [ "$KEEP" = "0" ]; then
    rm -rf "$HOME/.synchub" "$HOME/Library/Application Support/SyncHub"
    defaults delete xyz.020814.synchub >/dev/null 2>&1 || true
    n=0; while security delete-generic-password -s xyz.020814.synchub >/dev/null 2>&1; do n=$((n+1)); done
    ok "已清除设置与进度记录（钥匙串条目 $n 个）"
else
    ok "保留设置与钥匙串密码（--keep-settings）"
fi
echo "✅ 卸载完成。已接收的文件仍在 ~/Desktop/跨端传输文件（如不需要可手动删除）。"
