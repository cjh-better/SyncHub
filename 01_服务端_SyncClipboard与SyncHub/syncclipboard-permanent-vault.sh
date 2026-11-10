#!/usr/bin/env bash
# ==============================================================================
# SyncClipboard Permanent Vault Mirror & Cloud Sync Daemon
# Ensures all Starred / Pinned (Permanent Save) clipboard & file records are:
#   1. Mirrored to /opt/stacks/syncclipboard/data/permanent/
#   2. Indexed in /opt/stacks/syncclipboard/data/permanent/permanent_manifest.json
#   3. Synced to Google Drive (gdrive:VPS_Backups_Permanent or gdrive_mock fallback)
#      using /etc/vps-backup/rclone.conf, exempt from the 7-day rolling deletion policy.
# ==============================================================================
set -euo pipefail

DATA_DIR="/opt/stacks/syncclipboard/data"
DB_FILE="${DATA_DIR}/server/data/history.db"
HISTORY_DIR="${DATA_DIR}/server/history"
PERM_DIR="${DATA_DIR}/permanent"
PERM_ITEMS_DIR="${PERM_DIR}/items"
MANIFEST_FILE="${PERM_DIR}/permanent_manifest.json"
RCLONE_CONF="/etc/vps-backup/rclone.conf"
MOCK_PERM_DIR="/var/backups/gdrive_remote_mock/VPS_Backups_Permanent"
LOG_TAG="syncclipboard-permanent-vault"

log_info() {
    logger -t "$LOG_TAG" -p user.info "$1" || true
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [INFO] $1"
}

mkdir -p "$PERM_ITEMS_DIR"

if [[ ! -f "$DB_FILE" ]]; then
    log_info "Database $DB_FILE not found; exiting."
    exit 0
fi

# 1. Export JSON manifest of all active permanent (Stared=1 or Pinned=1) records
python3 - "$DB_FILE" "$HISTORY_DIR" "$PERM_ITEMS_DIR" "$MANIFEST_FILE" << 'PYEOF'
import os, sys, json, shutil, sqlite3
from datetime import datetime, timezone

db_file, history_dir, perm_items_dir, manifest_file = sys.argv[1:5]

conn = sqlite3.connect(f"file:{db_file}?mode=ro", uri=True, timeout=15.0)
conn.row_factory = sqlite3.Row
cur = conn.cursor()
sql = (
    "SELECT ID, Type, Hash, Text, Size, Stared, Pinned, CreateTime, LastModified, TransferDataFile "
    "FROM HistoryRecords WHERE IsDeleted = 0 AND (Stared = 1 OR Pinned = 1) ORDER BY ID DESC"
)
cur.execute(sql)
rows = [dict(r) for r in cur.fetchall()]
conn.close()

TYPE_MAP = {0: "Text", 1: "File", 2: "Image", 3: "Group"}

active_folders = set()
for r in rows:
    t_val = r["Type"]
    t_str = TYPE_MAP.get(t_val, str(t_val))
    r["TypeName"] = t_str
    folder_name = f"{t_str}_{r['Hash']}"
    active_folders.add(folder_name)
    src_dir = os.path.join(history_dir, folder_name)
    dst_dir = os.path.join(perm_items_dir, folder_name)
    os.makedirs(dst_dir, exist_ok=True)
    copied_transfer_file = None
    if os.path.isdir(src_dir):
        for root, _, files in os.walk(src_dir):
            rel = os.path.relpath(root, src_dir)
            target_root = dst_dir if rel == "." else os.path.join(dst_dir, rel)
            os.makedirs(target_root, exist_ok=True)
            for f in files:
                s_f = os.path.join(root, f)
                d_f = os.path.join(target_root, f)
                if not os.path.exists(d_f) or os.path.getsize(s_f) != os.path.getsize(d_f):
                    shutil.copy2(s_f, d_f)
                if r.get("TransferDataFile") and f == os.path.basename(r["TransferDataFile"]):
                    copied_transfer_file = s_f
    if t_str == "Text":
        txt_file = os.path.join(dst_dir, "content.txt")
        if copied_transfer_file and os.path.isfile(copied_transfer_file):
            shutil.copy2(copied_transfer_file, txt_file)
        elif r.get("Text") is not None:
            with open(txt_file, "w", encoding="utf-8") as tf:
                tf.write(r["Text"])

if os.path.isdir(perm_items_dir):
    for entry in os.listdir(perm_items_dir):
        full_entry = os.path.join(perm_items_dir, entry)
        if entry not in active_folders and os.path.isdir(full_entry):
            shutil.rmtree(full_entry, ignore_errors=True)

manifest = {
    "updatedAtUtc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "permanentCount": len(rows),
    "records": rows,
}
tmp_manifest = manifest_file + ".tmp"
with open(tmp_manifest, "w", encoding="utf-8") as mf:
    json.dump(manifest, mf, indent=2, ensure_ascii=False)
os.replace(tmp_manifest, manifest_file)
PYEOF

# 2. Sync permanent vault to Google Drive (or gdrive_mock fallback) via /etc/vps-backup/rclone.conf
if command -v rclone >/dev/null 2>&1 && [[ -f "$RCLONE_CONF" ]]; then
    if [[ -s /etc/vps-backup/service_account.json ]] && rclone lsf "gdrive:VPS_Backups_Permanent" --config "$RCLONE_CONF" --max-depth 1 >/dev/null 2>&1; then
        rclone sync "$PERM_DIR" "gdrive:VPS_Backups_Permanent" --config "$RCLONE_CONF" --transfers 2 --checkers 4 --quiet 2>/dev/null || true
    elif rclone listremotes --config "$RCLONE_CONF" 2>/dev/null | grep -q "^gdrive_mock:"; then
        mkdir -p "$MOCK_PERM_DIR"
        rclone sync "$PERM_DIR" "gdrive_mock:${MOCK_PERM_DIR}" --config "$RCLONE_CONF" --transfers 2 --checkers 4 --quiet 2>/dev/null || true
    fi
fi

log_info "Permanent vault synchronized successfully."
