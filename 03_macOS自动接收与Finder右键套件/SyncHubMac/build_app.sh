#!/usr/bin/env bash
# 编译 SyncHub.app（只需 Xcode 命令行工具）。用法: ./build_app.sh [安装目录，默认 ~/Applications]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:-$HOME/Applications}"
NAME="SyncHub"
WORK="$(mktemp -d /tmp/synchub-build.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/$NAME.app"

command -v xcrun >/dev/null 2>&1 || { echo "✗ 未找到 xcrun，请先执行: xcode-select --install" >&2; exit 2; }
SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)" || { echo "✗ 未找到 macOS SDK（命令行工具未装好）" >&2; exit 2; }

ARCH="$(uname -m)"
# Terminal running under Rosetta reports x86_64 on Apple silicon; build native arm64 anyway.
if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = "1" ]; then ARCH="arm64"; fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
echo "→ 正在编译 SyncHub（${ARCH}，$(basename "$SDK")）… 首次约需 1 分钟"
xcrun --sdk macosx swiftc -O -swift-version 5 \
    -target "$ARCH-apple-macos12.0" -sdk "$SDK" -module-name "$NAME" \
    -o "$APP/Contents/MacOS/$NAME" "$HERE"/Sources/SyncHub/*.swift

cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
cp "$HERE/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "→ 本地签名（ad-hoc）"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=1 "$APP"

# Replace an installed copy (quit it first so the binary isn't busy).
if pgrep -x "$NAME" >/dev/null 2>&1; then
    osascript -e "quit app \"$NAME\"" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do pgrep -x "$NAME" >/dev/null 2>&1 || break; sleep 1; done
    pkill -x "$NAME" 2>/dev/null || true
fi
mkdir -p "$DEST"
rm -rf "$DEST/$NAME.app"
ditto "$APP" "$DEST/$NAME.app"
xattr -dr com.apple.quarantine "$DEST/$NAME.app" 2>/dev/null || true
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -f "$DEST/$NAME.app" >/dev/null 2>&1 || true
echo "✓ 已生成 $DEST/$NAME.app"
