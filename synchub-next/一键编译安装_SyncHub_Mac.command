#!/usr/bin/env bash
# ==============================================================================
# SyncHub Next — macOS 双击一键编译、签名、迁移并安装到 /Applications
# 在 Finder 中直接双击本文件即可运行；也可在终端执行：
#   bash ./一键编译安装_SyncHub_Mac.command
# ==============================================================================
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/development/flutter/bin:$HOME/flutter/bin:$HOME/fvm/default/bin:$HOME/.pub-cache/bin:$PATH"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

echo "============================================================"
echo "  SyncHub Next — macOS 源码一键编译与安装向导"
echo "  项目目录: $ROOT_DIR"
echo "============================================================"

# 自动清理从 Windows 传输可能附带的隔离属性与 CRLF 换行符
xattr -dr com.apple.quarantine "$ROOT_DIR/scripts" 2>/dev/null || true
if [ -f "$ROOT_DIR/scripts/build_mac.sh" ]; then
  /usr/bin/perl -pi -e 's/\r\n/\n/g' "$ROOT_DIR/scripts/build_mac.sh" 2>/dev/null || true
  chmod +x "$ROOT_DIR/scripts/build_mac.sh" 2>/dev/null || true
fi

if ! bash "$ROOT_DIR/scripts/build_mac.sh" --install "$@"; then
  echo ""
  echo "✗ 编译或安装未完成，请检查上方提示（确认已安装 Flutter SDK 与 Xcode）。"
  if [ -t 0 ]; then
    read -r -p "按回车键关闭窗口..." _ || true
  fi
  exit 1
fi

echo ""
echo "============================================================"
echo "  ✓ SyncHub.app 编译、签名与本机安装已全部完成！"
echo "  • 应用位置: /Applications/SyncHub.app (或 ~/Applications/SyncHub.app)"
echo "  • 安装镜像: $ROOT_DIR/dist/SyncHub-macos.dmg"
echo "  • 压缩归档: $ROOT_DIR/dist/SyncHub-macos.zip"
echo ""
echo "  首次连接服务器提示："
echo "  1. 在已登录的 Windows 端打开「设置 → 添加设备」生成 6 位配对码；"
echo "  2. 在 Mac 端引导页输入服务器 https://020814.xyz/gw 与 6 位配对码即可互联！"
echo "============================================================"

if [ -t 0 ]; then
  read -r -p "按回车键完成并退出..." _ || true
fi
