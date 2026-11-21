#!/usr/bin/env bash
# ==============================================================================
# SyncHub Next — One-Command macOS Build, Sign, Package & Migrate Script
#
# Usage:
#   bash scripts/build_mac.sh                      # Build + sign + zip + dmg
#   bash scripts/build_mac.sh --install            # Also migrate legacy state & install SyncHub.app
#   bash scripts/build_mac.sh --install --no-launch
#   bash scripts/build_mac.sh --cn-mirror --install # Force China Flutter mirror
#   bash scripts/build_mac.sh --skip-dmg           # Skip DMG creation (still builds .app + .zip)
#   CODESIGN_IDENTITY="Developer ID Application: ..." bash scripts/build_mac.sh
# ==============================================================================
set -euo pipefail

# Ensure Homebrew / standard Flutter / CocoaPods paths are visible when launched from Finder (.command)
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/development/flutter/bin:$HOME/flutter/bin:$HOME/fvm/default/bin:$HOME/.pub-cache/bin:$PATH"

[ "$(uname -s)" = "Darwin" ] || {
  echo "✗ scripts/build_mac.sh must be run on macOS (Darwin)." >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$ROOT_DIR/app"
DIST_DIR="$ROOT_DIR/dist"
ENTITLEMENTS="$APP_DIR/macos/Runner/Release.entitlements"

DO_INSTALL=0
DO_LAUNCH=1
DO_PACKAGE=1
DO_DMG=1
FORCE_CN_MIRROR=0
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
INSTALL_DIR="${SYNCHUB_INSTALL_DIR:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --install)
      DO_INSTALL=1
      ;;
    --no-launch)
      DO_LAUNCH=0
      ;;
    --skip-package)
      DO_PACKAGE=0
      ;;
    --skip-dmg)
      DO_DMG=0
      ;;
    --dmg)
      DO_DMG=1
      ;;
    --cn-mirror)
      FORCE_CN_MIRROR=1
      ;;
    --install-dir)
      shift
      INSTALL_DIR="${1:-}"
      ;;
    --sign-identity)
      shift
      SIGN_IDENTITY="${1:--}"
      ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

say()  { printf '\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

# ------------------------------------------------------------------------------
# 1. Locate Flutter, Verify Xcode & Build Release macOS App
# ------------------------------------------------------------------------------
find_flutter() {
  if [ -n "${FLUTTER_BIN:-}" ] && [ -x "${FLUTTER_BIN}" ]; then
    printf '%s\n' "$FLUTTER_BIN"
    return 0
  fi
  if command -v flutter >/dev/null 2>&1; then
    command -v flutter
    return 0
  fi
  for candidate in \
    "$HOME/development/flutter/bin/flutter" \
    "$HOME/flutter/bin/flutter" \
    "$HOME/fvm/default/bin/flutter" \
    "/opt/homebrew/bin/flutter" \
    "/usr/local/bin/flutter" \
    "/Applications/flutter/bin/flutter"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

FLUTTER="$(find_flutter)" || {
  echo "✗ 未找到 Flutter SDK。请先安装 Flutter（例如: brew install --cask flutter）或设置 FLUTTER_BIN=/path/to/flutter" >&2
  exit 2
}

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "✗ 未检测到完整可用的 Xcode 命令行环境。请确认已安装 Xcode.app 并执行：" >&2
  echo "    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  echo "    sudo xcodebuild -runFirstLaunch" >&2
  exit 2
fi

if [ -f "$APP_DIR/macos/Podfile" ] && ! command -v pod >/dev/null 2>&1; then
  warn "检测到 macos/Podfile 但未安装 CocoaPods，建议执行: brew install cocoapods"
fi

[ -f "$ENTITLEMENTS" ] || {
  echo "✗ Missing entitlements file: $ENTITLEMENTS" >&2
  exit 2
}

if [ "$FORCE_CN_MIRROR" -eq 1 ]; then
  export PUB_HOSTED_URL="https://pub.flutter-io.cn"
  export FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
  ok "Using China Flutter mirror ($PUB_HOSTED_URL)"
elif [ -z "${PUB_HOSTED_URL:-}" ]; then
  if ! curl -fsSI --connect-timeout 3 https://pub.dev >/dev/null 2>&1; then
    export PUB_HOSTED_URL="https://pub.flutter-io.cn"
    export FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
    warn "pub.dev 连接超时，已自动切换至国内镜像 ($PUB_HOSTED_URL)"
  fi
fi

say "Building SyncHub.app (Flutter macOS release)"
(
  cd "$APP_DIR"
  "$FLUTTER" config --enable-macos-desktop >/dev/null 2>&1 || true

  # Auto-clean stale Windows / cross-host ephemeral caches if copied directly
  if grep -Eq '([A-Za-z]:\\|file:///[A-Za-z]:)' \
      "$APP_DIR/.dart_tool/package_config.json" \
      "$APP_DIR/macos/Flutter/ephemeral/Flutter-Generated.xcconfig" 2>/dev/null; then
    warn "检测到跨平台残留缓存路径，正在执行 flutter clean..."
    "$FLUTTER" clean
  fi

  if ! "$FLUTTER" pub get; then
    warn "pubspec.lock 与当前 Flutter SDK 版本存在差异，正在重新解析依赖..."
    rm -f "$APP_DIR/pubspec.lock"
    "$FLUTTER" pub get
  fi

  "$FLUTTER" build macos --release
)

BUILT_APP="$APP_DIR/build/macos/Build/Products/Release/SyncHub.app"
if [ ! -d "$BUILT_APP" ] && [ -d "$APP_DIR/build/macos/Build/Products/Release/synchub.app" ]; then
  BUILT_APP="$APP_DIR/build/macos/Build/Products/Release/synchub.app"
fi
[ -d "$BUILT_APP" ] || {
  echo "✗ Expected app bundle not found at $BUILT_APP" >&2
  exit 3
}
ok "Built bundle: $BUILT_APP"

WORK_DIR="$(mktemp -d /tmp/synchub-mac-pkg.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT
STAGE_APP="$WORK_DIR/SyncHub.app"
ditto "$BUILT_APP" "$STAGE_APP"
xattr -cr "$STAGE_APP" 2>/dev/null || true

# ------------------------------------------------------------------------------
# 2. Inside-Out Code Signing (Preserving Release.entitlements)
# ------------------------------------------------------------------------------
say "Signing SyncHub.app (identity: $SIGN_IDENTITY)"

SIGN_EXTRA_ARGS=()
if [ "$SIGN_IDENTITY" != "-" ]; then
  SIGN_EXTRA_ARGS+=(--options runtime --timestamp)
fi

sign_item() {
  local target="$1"
  if [ "${#SIGN_EXTRA_ARGS[@]}" -gt 0 ]; then
    codesign --force --sign "$SIGN_IDENTITY" "${SIGN_EXTRA_ARGS[@]}" "$target"
  else
    codesign --force --sign "$SIGN_IDENTITY" "$target"
  fi
}

if [ -d "$STAGE_APP/Contents/Frameworks" ]; then
  # Sign standalone dynamic libraries first
  while IFS= read -r -d '' dylib; do
    sign_item "$dylib"
  done < <(find "$STAGE_APP/Contents/Frameworks" -type f \( -name "*.dylib" -o -name "*.so" \) -print0)

  # Sign nested frameworks deepest-first (e.g., WebRTC.framework inside plugin frameworks)
  while IFS= read -r fw; do
    [ -n "$fw" ] || continue
    sign_item "$fw"
  done < <(find "$STAGE_APP/Contents/Frameworks" -type d -name "*.framework" | awk '{ print length, $0 }' | sort -rn | cut -d" " -f2-)
fi

# Sign outer SyncHub.app with Release.entitlements (unsandboxed + network client/server)
if [ "${#SIGN_EXTRA_ARGS[@]}" -gt 0 ]; then
  codesign --force --sign "$SIGN_IDENTITY" "${SIGN_EXTRA_ARGS[@]}" --entitlements "$ENTITLEMENTS" "$STAGE_APP"
else
  codesign --force --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$STAGE_APP"
fi

codesign --verify --deep --strict --verbose=2 "$STAGE_APP"
if ! codesign -d --entitlements :- "$STAGE_APP" 2>/dev/null | grep -q "com.apple.security.network.server"; then
  echo "✗ Entitlements verification failed on $STAGE_APP" >&2
  exit 4
fi
ok "Code signature & Release.entitlements verified (--deep --strict)"

# ------------------------------------------------------------------------------
# 3. Package dist/SyncHub-macos.zip & dist/SyncHub-macos.dmg
# ------------------------------------------------------------------------------
if [ "$DO_PACKAGE" -eq 1 ]; then
  mkdir -p "$DIST_DIR"
  ZIP_OUT="$DIST_DIR/SyncHub-macos.zip"
  rm -f "$ZIP_OUT"
  say "Packaging $ZIP_OUT"
  ditto -c -k --sequesterRsrc --keepParent "$STAGE_APP" "$ZIP_OUT"
  ok "Created ZIP: $ZIP_OUT"

  if [ "$DO_DMG" -eq 1 ]; then
    DMG_OUT="$DIST_DIR/SyncHub-macos.dmg"
    DMG_ROOT="$WORK_DIR/dmg-root"
    mkdir -p "$DMG_ROOT"
    ditto "$STAGE_APP" "$DMG_ROOT/SyncHub.app"
    ln -s /Applications "$DMG_ROOT/Applications"
    rm -f "$DMG_OUT"
    hdiutil detach "/Volumes/SyncHub" -quiet 2>/dev/null || true
    say "Packaging $DMG_OUT"
    hdiutil create \
      -volname "SyncHub" \
      -srcfolder "$DMG_ROOT" \
      -ov \
      -format UDZO \
      "$DMG_OUT" >/dev/null
    ok "Created DMG: $DMG_OUT"
  fi
fi

# ------------------------------------------------------------------------------
# 4. Optional --install: Migrate Legacy State, Clean Old Daemons, Install & Launch
# ------------------------------------------------------------------------------
install_quick_action() {
  local services_dir="$HOME/Library/Services"
  local wf_name="发送到跨端传输中心"
  local legacy_wf_name="📲 发送到跨端传输 (Windows与手机)"
  mkdir -p "$services_dir"
  rm -rf "$services_dir/$legacy_wf_name.workflow"

  local wf_contents="$services_dir/$wf_name.workflow/Contents"
  rm -rf "$services_dir/$wf_name.workflow"
  mkdir -p "$wf_contents"

  cat > "$wf_contents/Info.plist" <<EOF
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
				<string>$wf_name</string>
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
EOF

  cat > "$wf_contents/document.wflow" <<'EOF'
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
					<key>COMMAND_STRING</key><string>if [ -d "/Applications/SyncHub.app" ]; then
  open -a "/Applications/SyncHub.app" "$@"
elif [ -d "$HOME/Applications/SyncHub.app" ]; then
  open -a "$HOME/Applications/SyncHub.app" "$@"
else
  open -b xyz.synchub.synchub "$@"
fi</string>
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
EOF
  plutil -lint "$wf_contents/Info.plist" "$wf_contents/document.wflow" >/dev/null
  /System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true
  /System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
  ok "Installed Finder Quick Action: $wf_name.workflow"
}

migrate_and_clean_legacy() {
  local uid_num
  uid_num="$(id -u)"

  # Quit running SyncHub (v2 or v3)
  if pgrep -x "SyncHub" >/dev/null 2>&1; then
    osascript -e 'quit app "SyncHub"' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
      pgrep -x "SyncHub" >/dev/null 2>&1 || break
      sleep 1
    done
    pkill -x "SyncHub" >/dev/null 2>&1 || true
    ok "Stopped running SyncHub instance"
  fi

  # Unload & remove legacy xyz.020814.synchub*.plist LaunchAgents & daemon
  shopt -s nullglob
  for plist in "$HOME/Library/LaunchAgents"/xyz.020814.synchub*.plist; do
    launchctl bootout "gui/$uid_num" "$plist" >/dev/null 2>&1 || launchctl unload "$plist" >/dev/null 2>&1 || true
    rm -f "$plist"
    ok "Removed legacy LaunchAgent: $(basename "$plist")"
  done
  shopt -u nullglob
  launchctl remove "xyz.020814.synchub" >/dev/null 2>&1 || true
  launchctl remove "xyz.020814.synchub.app" >/dev/null 2>&1 || true
  pkill -f "synchub_mac_daemon" >/dev/null 2>&1 || true

  # Consolidate legacy receiver_state.json, ~/.synchub/last_id.txt, and xyz.020814.synchub defaults
  /usr/bin/osascript -l JavaScript <<'JSEOF' >/dev/null 2>&1 || true
ObjC.import('Foundation');
const fm = $.NSFileManager.defaultManager;
const home = ObjC.unwrap($.NSHomeDirectory());
function readUTF8(path) {
  if (!fm.fileExistsAtPath(path)) return null;
  const s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  return s.isNil() ? null : ObjC.unwrap(s);
}
function writeAtomically(path, content) {
  const dir = $(path).stringByDeletingLastPathComponent;
  fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(dir, true, null, null);
  $(content).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
}
let lastId = 0;
const statePath = home + '/Library/Application Support/SyncHub/receiver_state.json';
const rawState = readUTF8(statePath);
if (rawState) {
  try { const j = JSON.parse(rawState); if (j.last_id > lastId) lastId = j.last_id | 0; } catch (_) {}
}
const dotLast = readUTF8(home + '/.synchub/last_id.txt');
if (dotLast) {
  const n = parseInt(dotLast.trim(), 10);
  if (n > lastId) lastId = n;
}
let cfgServer = '', cfgUser = '', cfgDir = '';
const dotCfg = readUTF8(home + '/.synchub/config');
if (dotCfg) {
  for (const line of dotCfg.split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*"?([^"]*)"?\s*$/);
    if (!m) continue;
    if (m[1] === 'SYNCHUB_SERVER') cfgServer = m[2];
    if (m[1] === 'SYNCHUB_USER') cfgUser = m[2];
    if (m[1] === 'SYNCHUB_RECV_DIR') cfgDir = m[2];
  }
}
const defs = $.NSUserDefaults.alloc.initWithSuiteName('xyz.020814.synchub');
function defStr(k) { const v = defs.stringForKey(k); return v.isNil() ? '' : ObjC.unwrap(v); }
const serverUrl = defStr('serverURL') || cfgServer;
const username = defStr('username') || cfgUser;
const recvDir = defStr('receiveDir') || cfgDir || (home + '/Desktop/跨端传输文件');

if (lastId > 0 || serverUrl || username) {
  const now = Date.now() / 1000;
  if (lastId > 0) {
    writeAtomically(statePath, JSON.stringify({ last_id: lastId, updated_at: now }));
    const nextHubStatePath = home + '/Library/Application Support/xyz.synchub.synchub/hub_receiver_state.json';
    let existingHubId = 0;
    const rawHubState = readUTF8(nextHubStatePath);
    if (rawHubState) {
      try { const hj = JSON.parse(rawHubState); if (hj.last_id > existingHubId) existingHubId = hj.last_id | 0; } catch (_) {}
    }
    if (lastId > existingHubId) {
      writeAtomically(nextHubStatePath, JSON.stringify({ last_id: lastId, updated_at: now }));
    }
  }
  const snapPath = home + '/Library/Application Support/xyz.synchub.synchub/legacy_migration.json';
  writeAtomically(snapPath, JSON.stringify({
    last_id: lastId,
    server_url: serverUrl,
    username: username,
    recv_dir: recvDir,
    migrated_at: new Date().toISOString()
  }, null, 2));
}
JSEOF
  ok "Migrated legacy state (receiver_state.json / ~/.synchub/last_id.txt / defaults)"

  # Ensure default receive directory exists (preserving existing symlink if any)
  local recv_dir="$HOME/Desktop/跨端传输文件"
  if [ ! -L "$recv_dir" ] && [ ! -d "$recv_dir" ]; then
    mkdir -p "$recv_dir"
  fi
}

if [ "$DO_INSTALL" -eq 1 ]; then
  say "Migrating legacy SyncHub installation & installing SyncHub.app"
  migrate_and_clean_legacy

  if [ -z "$INSTALL_DIR" ]; then
    if [ -w "/Applications" ]; then
      INSTALL_DIR="/Applications"
    else
      INSTALL_DIR="$HOME/Applications"
    fi
  fi
  mkdir -p "$INSTALL_DIR"

  # Remove stale v2 SyncHub.app (xyz.020814.synchub) from alternate Applications directory
  for alt_app in "$HOME/Applications/SyncHub.app" "/Applications/SyncHub.app"; do
    if [ -d "$alt_app" ] && [ "$alt_app" != "$INSTALL_DIR/SyncHub.app" ]; then
      alt_bid="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$alt_app/Contents/Info.plist" 2>/dev/null || true)"
      if [ "$alt_bid" = "xyz.020814.synchub" ]; then
        rm -rf "$alt_app" 2>/dev/null || true
        ok "Removed legacy bundle at $alt_app"
      fi
    fi
  done

  DEST_APP="$INSTALL_DIR/SyncHub.app"
  rm -rf "$DEST_APP"
  ditto "$STAGE_APP" "$DEST_APP"
  xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true

  LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [ -x "$LSREG" ]; then
    "$LSREG" -f "$DEST_APP" >/dev/null 2>&1 || true
  fi
  ok "Installed SyncHub.app -> $DEST_APP"

  install_quick_action

  if [ "$DO_LAUNCH" -eq 1 ]; then
    open "$DEST_APP"
    ok "Launched $DEST_APP"
  fi
fi

say "Done!"
