#!/system/bin/sh
# ==============================================================================
# SyncHub Android Root Auto-Receiver Daemon (Magisk / KernelSU / APatch service.d)
# Automatically saves files sent from Windows PC or Mac directly into:
#   /sdcard/Download/跨端传输/
# Installation on Rooted Android:
#   su -c "curl -sSL -u 用户名:密码 https://020814.xyz/api/hub/client/android_root.sh -o /data/adb/service.d/synchub_android.sh && chmod 755 /data/adb/service.d/synchub_android.sh && /data/adb/service.d/synchub_android.sh &"
# ==============================================================================

SERVER_URL="https://020814.xyz"
AUTH="${SYNCHUB_AUTH:-用户名:密码}"   # 运行前 export SYNCHUB_AUTH=用户名:密码
SAVE_DIR="/sdcard/Download/跨端传输"
STATE_FILE="/data/adb/synchub_last_id"

while [ ! -d "/sdcard/Download" ]; do
    sleep 3
done

mkdir -p "$SAVE_DIR"

LAST_ID=0
if [ -f "$STATE_FILE" ]; then
    LAST_ID=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
fi

while true; do
    RESP=$(curl -sS -m 15 -u "$AUTH" "${SERVER_URL}/api/hub/auto-pull?device=android&since_id=${LAST_ID}" 2>/dev/null)
    if echo "$RESP" | grep -q '"ok": true'; then
        NEW_ID=$(echo "$RESP" | sed -n 's/.*"latestId": *\([0-9]*\).*/\1/p')
        # Parse downloadUrl entries if any
        echo "$RESP" | tr '{' '\n' | grep '"downloadUrl":' | while read -r line; do
            DL_PATH=$(echo "$line" | sed -n 's/.*"downloadUrl": *"\([^"]*\)".*/\1/p')
            FNAME=$(echo "$line" | sed -n 's/.*"filename": *"\([^"]*\)".*/\1/p')
            if [ -n "$DL_PATH" ] && [ -n "$FNAME" ]; then
                TARGET="${SAVE_DIR}/${FNAME}"
                if [ ! -f "$TARGET" ]; then
                    curl -sS -L -u "$AUTH" "${SERVER_URL}${DL_PATH}" -o "${TARGET}.part" && mv "${TARGET}.part" "$TARGET"
                    am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://${TARGET}" >/dev/null 2>&1
                    cmd notification post -S bigtext -t "📥 跨端传输已保存至 Download" "SyncHub" "文件已自动存入: Download/跨端传输/${FNAME}" >/dev/null 2>&1 || true
                fi
            fi
        done
        if [ -n "$NEW_ID" ] && [ "$NEW_ID" -gt "$LAST_ID" ] 2>/dev/null; then
            LAST_ID="$NEW_ID"
            echo "$LAST_ID" > "$STATE_FILE"
        fi
    fi
    sleep 4
done
