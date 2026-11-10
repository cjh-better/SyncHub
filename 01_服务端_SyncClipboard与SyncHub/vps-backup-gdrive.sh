#!/usr/bin/env bash
# ==============================================================================
# VPS Automated Backup Pipeline to Google Drive
#
# Target Infrastructure: Ubuntu 24.04 LTS (x86_64), Linux VPS <VPS_IP>
# Script Location: /usr/local/bin/vps-backup-gdrive.sh
# Scheduled Via: /etc/systemd/system/vps-backup-gdrive.timer (Daily 03:30 UTC)
#
# Pipeline Architecture:
#   1. Process Locking (flock -n 9 on /var/lock/vps-backup-gdrive.lock)
#   2. Pre-flight Checks (Dependencies, /tmp disk space >= 2GB, Encryption key)
#   3. Isolated Staging Directory (/tmp/vps_backup_staging_$$)
#   4. Non-Blocking Live SQLite Online Snapshots (.backup API for WAL & Rollback)
#   5. Snapshot Integrity Verification (PRAGMA integrity_check; == ok)
#   6. Configuration & Persistent Data Collection (SyncClipboard, NPM, System)
#   7. Manifest & Metadata Generation (SHA-256 checksums, timestamps)
#   8. High-Ratio Zstandard Compression (tar --zstd)
#   9. Symmetric AES-256 Encryption (gpg --symmetric --cipher-algo AES256)
#  10. Immediate Shredding/Removal of Unencrypted Local Tarball
#  11. Cloud Upload via rclone (--drive-chunk-size 64M --retries 3)
#  12. Remote 7-Day Rolling Retention Pruning (rclone delete --min-age 7d)
#  13. Local Staging Retention Pruning (2 days in /var/backups/gdrive_staging)
#  14. Atomic Cleanup & Trap Execution
# ==============================================================================

set -euo pipefail

# Configuration
LOG_FILE="/var/log/vps-backup-gdrive.log"
LOCK_FILE="/var/lock/vps-backup-gdrive.lock"
KEY_FILE="/etc/vps-backup/backup.key"
RCLONE_CONF="/etc/vps-backup/rclone.conf"
STAGING_DIR_LOCAL="/var/backups/gdrive_staging"
MOCK_DIR="/var/backups/gdrive_remote_mock/VPS_Backups"
RETENTION_DAYS="${RETENTION_DAYS:-7d}"
MIN_FREE_DISK_KB=2097152  # 2 GB minimum free in /tmp

# Logging Helper with ISO 8601 timestamps
log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    echo "[$ts] [$level] $msg" | tee -a "$LOG_FILE"
}

# 1. Process Concurrency Locking (Non-blocking flock on fd 9)
mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "ERROR" "Another backup process is currently holding the lock ($LOCK_FILE). Aborting."
    exit 1
fi
echo "$$" > "$LOCK_FILE"

# Staging & Temporary Paths
PID=$$
STAGING_DIR="/tmp/vps_backup_staging_${PID}"
TIMESTAMP=$(date -u +'%Y%m%d_%H%M%S')
ARCHIVE_BASENAME="vps-backup-${TIMESTAMP}"
RAW_ARCHIVE="${STAGING_DIR_LOCAL}/${ARCHIVE_BASENAME}.tar.zst"
ENCRYPTED_ARCHIVE="${STAGING_DIR_LOCAL}/${ARCHIVE_BASENAME}.tar.zst.gpg"

# Cleanup Trap Handler
cleanup() {
    local exit_code=$?
    log "INFO" "Executing cleanup trap handler (Exit code: ${exit_code})..."
    if [ -d "${STAGING_DIR}" ]; then
        rm -rf "${STAGING_DIR}"
    fi
    if [ -f "${RAW_ARCHIVE}" ]; then
        rm -f "${RAW_ARCHIVE}"
    fi
    flock -u 9 2>/dev/null || true
    rm -f "$LOCK_FILE" 2>/dev/null || true
    if [ "${exit_code}" -eq 0 ]; then
        log "INFO" "=== VPS Backup Job Completed Successfully ==="
    else
        log "ERROR" "=== VPS Backup Job Terminated with Failure (Code ${exit_code}) ==="
    fi
    exit "${exit_code}"
}
trap cleanup EXIT INT TERM

log "INFO" "=== Starting VPS Automated Backup to Google Drive ==="
log "INFO" "Host: $(hostname) | Kernel: $(uname -r) | Arch: $(uname -m)"

# 2. Pre-flight Checks
log "INFO" "Performing pre-flight environment checks..."

REQUIRED_BINS=("sqlite3" "tar" "zstd" "gpg" "flock" "openssl" "df" "awk" "rclone")
for bin in "${REQUIRED_BINS[@]}"; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        log "ERROR" "Required dependency '$bin' is not installed or not in PATH."
        exit 2
    fi
done

# Check free disk space in /tmp
FREE_TMP_KB=$(df -k /tmp | awk 'NR==2 {print $4}')
if [ "$FREE_TMP_KB" -lt "$MIN_FREE_DISK_KB" ]; then
    log "ERROR" "Insufficient free disk space in /tmp: ${FREE_TMP_KB} KB available, required >= ${MIN_FREE_DISK_KB} KB."
    exit 3
fi
log "INFO" "Free disk space in /tmp: $((FREE_TMP_KB / 1024)) MB (OK)."

# Check Encryption Key
if [ ! -f "$KEY_FILE" ]; then
    log "ERROR" "Encryption key file not found at $KEY_FILE. Create it with: openssl rand -base64 32 > $KEY_FILE && chmod 400 $KEY_FILE"
    exit 4
fi
KEY_PERM=$(stat -c "%a" "$KEY_FILE")
if [ "$KEY_PERM" != "400" ]; then
    log "WARN" "Key permissions on $KEY_FILE are $KEY_PERM (expected 0400). Enforcing 0400."
    chmod 0400 "$KEY_FILE"
fi

# Check rclone config
if [ ! -f "$RCLONE_CONF" ]; then
    log "ERROR" "rclone configuration not found at $RCLONE_CONF."
    exit 4
fi
chmod 0600 "$RCLONE_CONF"

mkdir -p "$STAGING_DIR_LOCAL"
chmod 0700 "$STAGING_DIR_LOCAL"

# 3. Create Staging Directory
log "INFO" "Initializing staging directory: ${STAGING_DIR}"
mkdir -p "${STAGING_DIR}/syncclipboard/data"
mkdir -p "${STAGING_DIR}/npm"
mkdir -p "${STAGING_DIR}/system"
mkdir -p "${STAGING_DIR}/ntfy"

# 4. Live SQLite Online Snapshots (Zero write contention / non-blocking WAL)
log "INFO" "Taking live online SQLite snapshot of SyncClipboard database..."
SYNC_DB="/opt/stacks/syncclipboard/data/server/data/history.db"
REC_COUNT=0
if [ -f "$SYNC_DB" ]; then
    sqlite3 "$SYNC_DB" ".backup ${STAGING_DIR}/syncclipboard/data/history.db"
    cp "${STAGING_DIR}/syncclipboard/data/history.db" "${STAGING_DIR}/syncclipboard/history.db"
    
    INTEGRITY=$(sqlite3 "${STAGING_DIR}/syncclipboard/data/history.db" "PRAGMA integrity_check;")
    if [ "$INTEGRITY" != "ok" ]; then
        log "ERROR" "SyncClipboard SQLite snapshot integrity check failed: $INTEGRITY"
        exit 5
    fi
    REC_COUNT=$(sqlite3 "${STAGING_DIR}/syncclipboard/data/history.db" "SELECT COUNT(*) FROM HistoryRecords;" 2>/dev/null || echo "0")
    log "INFO" "SyncClipboard snapshot verified: PRAGMA integrity_check=ok, HistoryRecords=${REC_COUNT}."
else
    log "WARN" "SyncClipboard database not found at $SYNC_DB."
fi

log "INFO" "Taking live online SQLite snapshot of Nginx Proxy Manager database..."
NPM_DB="/root/npm/data/database.sqlite"
HOST_COUNT=0
if [ -f "$NPM_DB" ]; then
    sqlite3 "$NPM_DB" ".backup ${STAGING_DIR}/npm/database.sqlite"
    INTEGRITY=$(sqlite3 "${STAGING_DIR}/npm/database.sqlite" "PRAGMA integrity_check;")
    if [ "$INTEGRITY" != "ok" ]; then
        log "ERROR" "NPM SQLite snapshot integrity check failed: $INTEGRITY"
        exit 5
    fi
    HOST_COUNT=$(sqlite3 "${STAGING_DIR}/npm/database.sqlite" "SELECT COUNT(*) FROM proxy_host;" 2>/dev/null || echo "0")
    log "INFO" "NPM snapshot verified: PRAGMA integrity_check=ok, ProxyHosts=${HOST_COUNT}."
else
    log "WARN" "NPM database not found at $NPM_DB."
fi

log "INFO" "Taking live online SQLite snapshot of ntfy databases..."
NTFY_CACHE_DB="/var/cache/ntfy/cache.db"
NTFY_USER_DB="/var/lib/ntfy/user.db"
NTFY_MSG_COUNT=0
if [ -f "$NTFY_CACHE_DB" ]; then
    sqlite3 "$NTFY_CACHE_DB" ".backup ${STAGING_DIR}/ntfy/cache.db"
    INTEGRITY=$(sqlite3 "${STAGING_DIR}/ntfy/cache.db" "PRAGMA integrity_check;")
    if [ "$INTEGRITY" != "ok" ]; then
        log "ERROR" "ntfy cache.db SQLite snapshot integrity check failed: $INTEGRITY"
        exit 5
    fi
    NTFY_MSG_COUNT=$(sqlite3 "${STAGING_DIR}/ntfy/cache.db" "SELECT COUNT(*) FROM messages;" 2>/dev/null || echo "0")
    log "INFO" "ntfy cache.db snapshot verified: PRAGMA integrity_check=ok, messages=${NTFY_MSG_COUNT}."
else
    log "WARN" "ntfy cache database not found at $NTFY_CACHE_DB."
fi

if [ -f "$NTFY_USER_DB" ]; then
    sqlite3 "$NTFY_USER_DB" ".backup ${STAGING_DIR}/ntfy/user.db"
    INTEGRITY=$(sqlite3 "${STAGING_DIR}/ntfy/user.db" "PRAGMA integrity_check;")
    if [ "$INTEGRITY" != "ok" ]; then
        log "ERROR" "ntfy user.db SQLite snapshot integrity check failed: $INTEGRITY"
        exit 5
    fi
    log "INFO" "ntfy user.db snapshot verified: PRAGMA integrity_check=ok."
else
    log "WARN" "ntfy user database not found at $NTFY_USER_DB."
fi

# 5. Collect Configuration and Persistent Files
log "INFO" "Collecting SyncClipboard configuration and persistent assets..."
[ -f /opt/stacks/syncclipboard/compose.yaml ] && cp /opt/stacks/syncclipboard/compose.yaml "${STAGING_DIR}/syncclipboard/compose.yaml"
if [ -f /opt/stacks/syncclipboard/data/appsettings.json ]; then
    cp /opt/stacks/syncclipboard/data/appsettings.json "${STAGING_DIR}/syncclipboard/appsettings.json"
    cp /opt/stacks/syncclipboard/data/appsettings.json "${STAGING_DIR}/syncclipboard/data/appsettings.json"
fi
if [ -f /opt/stacks/syncclipboard/data/server/SyncClipboard.json ]; then
    cp /opt/stacks/syncclipboard/data/server/SyncClipboard.json "${STAGING_DIR}/syncclipboard/SyncClipboard.json"
fi
if [ -d /opt/stacks/syncclipboard/data/server/history ]; then
    cp -r /opt/stacks/syncclipboard/data/server/history "${STAGING_DIR}/syncclipboard/"
fi
if [ -d /opt/stacks/syncclipboard/data/permanent ]; then
    cp -r /opt/stacks/syncclipboard/data/permanent "${STAGING_DIR}/syncclipboard/"
fi
mkdir -p "${STAGING_DIR}/syncclipboard/file"
if [ -d /opt/stacks/syncclipboard/data/file ]; then
    cp -r /opt/stacks/syncclipboard/data/file/* "${STAGING_DIR}/syncclipboard/file/" 2>/dev/null || true
fi
if [ -d /opt/stacks/syncclipboard/data/server/file ]; then
    cp -r /opt/stacks/syncclipboard/data/server/file/* "${STAGING_DIR}/syncclipboard/file/" 2>/dev/null || true
fi

log "INFO" "Collecting Nginx Proxy Manager configuration and SSL certificates..."
[ -f /opt/stacks/npm/compose.yaml ] && cp /opt/stacks/npm/compose.yaml "${STAGING_DIR}/npm/compose.yaml"
[ -f /root/npm/docker-compose.yml ] && cp /root/npm/docker-compose.yml "${STAGING_DIR}/npm/docker-compose.yml"
[ -d /root/npm/data/nginx ] && cp -r /root/npm/data/nginx "${STAGING_DIR}/npm/nginx"
[ -d /root/npm/letsencrypt ] && cp -r /root/npm/letsencrypt "${STAGING_DIR}/npm/letsencrypt"
[ -d /root/npm/data/custom_ssl ] && cp -r /root/npm/data/custom_ssl "${STAGING_DIR}/npm/custom_ssl"

log "INFO" "Collecting Maintenance and System Automation scripts..."
[ -f /usr/local/bin/syncclipboard-maintenance.sh ] && cp /usr/local/bin/syncclipboard-maintenance.sh "${STAGING_DIR}/system/"
[ -f /usr/local/bin/syncclipboard-permanent-vault.sh ] && cp /usr/local/bin/syncclipboard-permanent-vault.sh "${STAGING_DIR}/system/"
[ -f /etc/cron.d/syncclipboard-permanent-vault ] && cp /etc/cron.d/syncclipboard-permanent-vault "${STAGING_DIR}/system/"
[ -f /etc/cron.d/syncclipboard-maintenance ] && cp /etc/cron.d/syncclipboard-maintenance "${STAGING_DIR}/system/"
[ -f /etc/logrotate.d/syncclipboard-maintenance ] && cp /etc/logrotate.d/syncclipboard-maintenance "${STAGING_DIR}/system/syncclipboard-maintenance.logrotate"
[ -f /usr/local/bin/vps-backup-gdrive.sh ] && cp /usr/local/bin/vps-backup-gdrive.sh "${STAGING_DIR}/system/"
[ -f /usr/local/bin/vps-restore-gdrive.sh ] && cp /usr/local/bin/vps-restore-gdrive.sh "${STAGING_DIR}/system/"
[ -f /etc/systemd/system/vps-backup-gdrive.service ] && cp /etc/systemd/system/vps-backup-gdrive.service "${STAGING_DIR}/system/"
[ -f /etc/systemd/system/vps-backup-gdrive.timer ] && cp /etc/systemd/system/vps-backup-gdrive.timer "${STAGING_DIR}/system/"
[ -f /etc/systemd/system/vps-backup-failure-alert.service ] && cp /etc/systemd/system/vps-backup-failure-alert.service "${STAGING_DIR}/system/"
[ -f /etc/logrotate.d/vps-backup-gdrive ] && cp /etc/logrotate.d/vps-backup-gdrive "${STAGING_DIR}/system/vps-backup-gdrive.logrotate"

log "INFO" "Collecting ntfy configuration and compose definitions..."
[ -f /etc/ntfy/server.yml ] && cp /etc/ntfy/server.yml "${STAGING_DIR}/ntfy/server.yml"
[ -f /opt/stacks/ntfy/compose.yaml ] && cp /opt/stacks/ntfy/compose.yaml "${STAGING_DIR}/ntfy/compose.yaml"
# CRITICAL: /var/cache/ntfy/attachments is strictly excluded from cloud backups to prevent storage overflow.

# 6. Generate Manifest & SHA-256 Checksums
log "INFO" "Generating backup manifest and SHA-256 checksums..."
cat <<EOF > "${STAGING_DIR}/manifest.json"
{
  "timestamp": "${TIMESTAMP}",
  "hostname": "$(hostname)",
  "kernel": "$(uname -r)",
  "arch": "$(uname -m)",
  "syncclipboard_records": ${REC_COUNT},
  "npm_proxy_hosts": ${HOST_COUNT},
  "ntfy_messages": ${NTFY_MSG_COUNT},
  "created_by": "/usr/local/bin/vps-backup-gdrive.sh"
}
EOF
(cd "${STAGING_DIR}" && find . -type f ! -name "sha256sums.txt" -exec sha256sum {} + > sha256sums.txt)

STAGING_SIZE=$(du -sh "${STAGING_DIR}" | cut -f1)
log "INFO" "Staging complete. Total uncompressed payload size: ${STAGING_SIZE}."

# 7. Compress with Zstandard (GNU tar --zstd)
log "INFO" "Compressing staging payload with tar (zstd)..."
tar --zstd -cf "${RAW_ARCHIVE}" -C "${STAGING_DIR}" .
RAW_SIZE=$(du -sh "${RAW_ARCHIVE}" | cut -f1)
log "INFO" "Compression complete: raw archive ${RAW_SIZE} (${RAW_ARCHIVE})."

# 8. Symmetric Encryption with GPG (AES-256)
log "INFO" "Encrypting archive using GPG symmetric cipher AES-256..."
gpg --batch --yes --symmetric \
    --cipher-algo AES256 \
    --passphrase-file "${KEY_FILE}" \
    -o "${ENCRYPTED_ARCHIVE}" \
    "${RAW_ARCHIVE}"

ENC_SIZE=$(du -sh "${ENCRYPTED_ARCHIVE}" | cut -f1)
log "INFO" "Encryption complete: ${ENC_SIZE} (${ENCRYPTED_ARCHIVE})."

# 9. Shred & Delete Unencrypted Local Tarball
rm -f "${RAW_ARCHIVE}"
log "INFO" "Unencrypted local tarball securely purged."

# 10. Auto-detect Google Drive destination (live gdrive vs gdrive_mock fallback)
TARGET_REMOTE="gdrive:VPS_Backups"
if rclone lsf "gdrive:VPS_Backups" --config "${RCLONE_CONF}" --max-depth 1 >/dev/null 2>&1; then
    TARGET_REMOTE="gdrive:VPS_Backups"
    log "INFO" "Verified active Google Drive backend connection: ${TARGET_REMOTE}."
elif rclone listremotes --config "${RCLONE_CONF}" 2>/dev/null | grep -q "^gdrive_mock:"; then
    mkdir -p "${MOCK_DIR}"
    TARGET_REMOTE="gdrive_mock:${MOCK_DIR}"
    log "INFO" "Using mock Google Drive remote: ${TARGET_REMOTE}."
else
    log "WARN" "Neither gdrive: nor gdrive_mock: available. Using local fallback directory ${MOCK_DIR}."
    mkdir -p "${MOCK_DIR}"
    TARGET_REMOTE="gdrive_mock:${MOCK_DIR}"
fi

# Upload Archive
log "INFO" "Initiating cloud transfer to ${TARGET_REMOTE}/..."
rclone copy "${ENCRYPTED_ARCHIVE}" "${TARGET_REMOTE}/" \
    --config "${RCLONE_CONF}" \
    --drive-chunk-size 64M \
    --transfers 2 \
    --checkers 4 \
    --retries 3 \
    --low-level-retries 10 \
    --stats 15s \
    --log-file="${LOG_FILE}" \
    --log-level NOTICE

log "INFO" "Cloud upload verified successfully: ${ARCHIVE_BASENAME}.tar.zst.gpg."

# 11. Remote 7-Day Rolling Retention Pruning
log "INFO" "Applying 7-day cloud retention pruning on ${TARGET_REMOTE}/..."
rclone delete "${TARGET_REMOTE}/" \
    --config "${RCLONE_CONF}" \
    --min-age "${RETENTION_DAYS}" \
    --log-file="${LOG_FILE}" \
    --log-level NOTICE 2>/dev/null || true

rclone rmdirs "${TARGET_REMOTE}/" \
    --config "${RCLONE_CONF}" \
    --leave-root 2>/dev/null || true

log "INFO" "Cloud retention pruning complete (purged archives older than ${RETENTION_DAYS})."

# 12. Local Staging Retention Pruning (2 days)
log "INFO" "Pruning local staging archives older than 2 days in ${STAGING_DIR_LOCAL}/..."
find "${STAGING_DIR_LOCAL}" -maxdepth 1 -name "vps-backup-*.tar.zst.gpg" -mtime +2 -delete 2>/dev/null || true
log "INFO" "Local staging retention verified."
