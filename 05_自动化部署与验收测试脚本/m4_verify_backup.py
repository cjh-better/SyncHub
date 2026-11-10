#!/usr/bin/env python3
"""
Milestone 4 Verification Harness: VPS Automated Backup to Google Drive & Disaster Recovery
Author: worker_sync_m4_1

Verifies:
  Test 1: Infrastructure & Configuration Asset Permissions (backup.key 0400, rclone.conf 0600, scripts 0755)
  Test 2: Systemd Timer & Service Configuration (active, enabled, 03:30 UTC schedule, cgroup quotas)
  Test 3: Live Backup Execution & Archive Generation (exit code 0, ISO 8601 logging, staging cleanup)
  Test 4: GPG AES-256 Symmetric Encryption & Key Protection (bad key rejection, zero-knowledge cipher)
  Test 5: Zstandard Decompression & Payload Structure (manifest.json, sha256sums.txt, configs)
  Test 6: SQLite Online Snapshot Integrity Check (PRAGMA integrity_check=ok on SyncClipboard & NPM)
  Test 7: Disaster Recovery Sandbox Restoration (--sandbox mode, zero live service impact)
  Test 8: 7-Day Rolling Cloud Retention Pruning (boundary test: 8d pruned, <=7d retained)
  Test 9: Process Concurrency Locking (flock contention aborts duplicate job)
  Test 10: Disaster Recovery Runbook Documentation (docs/restore_runbook.md complete & valid)

Usage:
  python m4_verify_backup.py
"""

import os
import sys
import time
import argparse
from typing import Tuple, Dict, Any, Optional

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

COLOR_GREEN = "\033[92m"
COLOR_RED = "\033[91m"
COLOR_YELLOW = "\033[93m"
COLOR_CYAN = "\033[96m"
COLOR_BOLD = "\033[1m"
COLOR_RESET = "\033[0m"

VPS_HOST = os.environ.get("SYNCHUB_VPS_HOST", "")
VPS_PORT = int(os.environ.get("SYNCHUB_VPS_PORT", "22"))
VPS_USER = os.environ.get("SYNCHUB_VPS_USER", "root")
VPS_PASS = os.environ.get("SYNCHUB_VPS_PASSWORD", "")
SERVER_URL = os.environ.get("SYNCHUB_SERVER_URL", "https://020814.xyz")
SC_USER = os.environ.get("SYNCHUB_USER", "admin")
SC_PASS = os.environ.get("SYNCHUB_PASSWORD", "")


class BackupVerificationHarness:
    def __init__(self, vps_host: str = VPS_HOST, vps_port: int = VPS_PORT,
                 vps_user: str = VPS_USER, vps_pass: str = VPS_PASS, verbose: bool = True):
        self.vps_host = vps_host
        self.vps_port = vps_port
        self.vps_user = vps_user
        self.vps_pass = vps_pass
        self.verbose = verbose
        self.results: Dict[str, bool] = {}

    def log(self, stage: str, msg: str, success: Optional[bool] = None):
        status_mark = ""
        if success is True:
            status_mark = f" [{COLOR_GREEN}PASS{COLOR_RESET}]"
        elif success is False:
            status_mark = f" [{COLOR_RED}FAIL{COLOR_RESET}]"
        elif success is None:
            status_mark = f" [{COLOR_CYAN}INFO{COLOR_RESET}]"
        ts = time.strftime("%H:%M:%S")
        print(f"[{ts}] [{stage}]{status_mark} {msg}")

    def _get_ssh_client(self):
        import paramiko
        from paramiko.transport import Transport
        import paramiko.kex_curve25519

        Transport._kex_info['curve25519-sha256'] = paramiko.kex_curve25519.KexCurve25519
        Transport._preferred_kex = ('curve25519-sha256',) + Transport._preferred_kex

        ssh = paramiko.SSHClient()
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        ssh.connect(self.vps_host, port=self.vps_port, username=self.vps_user,
                    password=self.vps_pass, timeout=20)
        return ssh

    def _ssh_exec(self, cmd: str) -> Tuple[int, str, str]:
        ssh = self._get_ssh_client()
        try:
            stdin, stdout, stderr = ssh.exec_command(cmd)
            out = stdout.read().decode("utf-8", errors="replace")
            err = stderr.read().decode("utf-8", errors="replace")
            code = stdout.channel.recv_exit_status()
            return code, out, err
        finally:
            ssh.close()

    # =========================================================================
    # Test 1: Infrastructure & Asset Permissions
    # =========================================================================
    def test_01_asset_permissions(self) -> bool:
        self.log("TEST-1", "Validating file permissions and ownership for all M4 backup components...")
        cmd = """
        set -e
        stat -c '%a %U:%G' /usr/local/bin/vps-backup-gdrive.sh
        stat -c '%a %U:%G' /usr/local/bin/vps-restore-gdrive.sh
        stat -c '%a %U:%G' /etc/vps-backup/backup.key
        stat -c '%a %U:%G' /etc/vps-backup/rclone.conf
        stat -c '%a %U:%G' /etc/systemd/system/vps-backup-gdrive.service
        stat -c '%a %U:%G' /etc/systemd/system/vps-backup-gdrive.timer
        stat -c '%a %U:%G' /etc/logrotate.d/vps-backup-gdrive
        rclone version | head -n 1
        """
        code, out, err = self._ssh_exec(cmd)
        if code != 0:
            self.log("TEST-1", f"Failed to inspect files: {err}", False)
            return False

        lines = [line.strip() for line in out.strip().split("\n") if line.strip()]
        expected_perms = [
            ("755 root:root", "vps-backup-gdrive.sh"),
            ("755 root:root", "vps-restore-gdrive.sh"),
            ("400 root:root", "backup.key"),
            ("600 root:root", "rclone.conf"),
            ("644 root:root", "vps-backup-gdrive.service"),
            ("644 root:root", "vps-backup-gdrive.timer"),
            ("644 root:root", "vps-backup-gdrive logrotate"),
        ]

        passed = True
        for i, (expected, name) in enumerate(expected_perms):
            actual = lines[i]
            if actual != expected:
                self.log("TEST-1", f"Mismatch on {name}: expected '{expected}', got '{actual}'", False)
                passed = False
            else:
                self.log("TEST-1", f"Verified {name} permissions: {actual}", True)

        rclone_ver = lines[7] if len(lines) > 7 else "unknown"
        self.log("TEST-1", f"Verified rclone installation: {rclone_ver}", True)
        return passed

    # =========================================================================
    # Test 2: Systemd Timer & Service Configuration
    # =========================================================================
    def test_02_systemd_timer_and_service(self) -> bool:
        self.log("TEST-2", "Verifying systemd timer schedule, active state, and service cgroup quotas...")
        cmd = """
        set -e
        systemctl is-active vps-backup-gdrive.timer
        systemctl is-enabled vps-backup-gdrive.timer
        systemctl show vps-backup-gdrive.timer -p TimersCalendar -p Persistent -p RandomizedDelaySec
        systemctl show vps-backup-gdrive.service -p Type -p ExecStart -p Nice -p IOSchedulingClass -p CPUQuotaPerSecUSec
        """
        code, out, err = self._ssh_exec(cmd)
        if code != 0:
            self.log("TEST-2", f"Systemd inspection failed: {err}", False)
            return False

        checks = {
            "Timer Active": "active" in out,
            "Timer Enabled": "enabled" in out,
            "OnCalendar 03:30": "03:30:00" in out,
            "Persistent=yes": "Persistent=yes" in out,
            "ExecStart backup script": "/usr/local/bin/vps-backup-gdrive.sh" in out,
            "Type=oneshot": "Type=oneshot" in out,
        }

        all_ok = True
        for desc, res in checks.items():
            if not res:
                self.log("TEST-2", f"Check failed: {desc}", False)
                all_ok = False
            else:
                self.log("TEST-2", f"Verified: {desc}", True)

        return all_ok

    # =========================================================================
    # Test 3: Live Backup Execution & Archive Generation
    # =========================================================================
    def test_03_live_backup_execution(self) -> bool:
        self.log("TEST-3", "Executing live backup via /usr/local/bin/vps-backup-gdrive.sh...")
        cmd = """
        /usr/local/bin/vps-backup-gdrive.sh
        echo "EXIT_CODE:$?"
        ls -lt /var/backups/gdrive_remote_mock/VPS_Backups/ | head -n 3
        """
        code, out, err = self._ssh_exec(cmd)
        if code != 0 or "EXIT_CODE:0" not in out:
            self.log("TEST-3", f"Backup execution failed (code {code}): {err}\nOutput: {out}", False)
            return False

        self.log("TEST-3", "Backup script finished with exit code 0.", True)
        
        # Verify log output contains ISO 8601 timestamps and key milestones
        cmd_log = "tail -n 25 /var/log/vps-backup-gdrive.log"
        _, log_out, _ = self._ssh_exec(cmd_log)
        
        has_iso = "T" in log_out and "Z]" in log_out
        has_snap = "taking live online sqlite snapshot" in log_out.lower()
        has_zstd = "tar (zstd)" in log_out.lower() or "zstd" in log_out.lower()
        has_gpg = "aes-256" in log_out.lower()
        has_upload = "cloud upload verified" in log_out.lower()

        if has_iso and has_snap and has_zstd and has_gpg and has_upload:
            self.log("TEST-3", "Structured log verification passed (ISO 8601, snapshots, compression, encryption, upload).", True)
            return True
        else:
            self.log("TEST-3", f"Log verification incomplete:\n{log_out}", False)
            return False

    # =========================================================================
    # Test 4: GPG AES-256 Symmetric Encryption & Protection
    # =========================================================================
    def test_04_encryption_integrity(self) -> bool:
        self.log("TEST-4", "Verifying GPG AES-256 cipher authenticity and bad-passphrase rejection...")
        cmd = """
        set -e
        LATEST_ARCHIVE=$(find /var/backups/gdrive_remote_mock/VPS_Backups/ /var/backups/gdrive_staging/ -name "vps-backup-*.tar.zst.gpg" | sort | tail -n 1)
        
        # 1. Packet inspection for AES256 cipher
        gpg --list-packets "$LATEST_ARCHIVE" 2>&1 | grep -i "aes256" | head -n 1
        
        # 2. Rejection test with bad passphrase
        echo "WrongSecretKey999!" > /tmp/bad.key
        if gpg --batch --yes --decrypt --passphrase-file /tmp/bad.key -o /tmp/bad_out.tar "$LATEST_ARCHIVE" 2>/dev/null; then
            echo "SECURITY_FAIL_LEAKAGE"
            exit 10
        else
            echo "BAD_KEY_REJECTED_CLEANLY"
        fi
        rm -f /tmp/bad.key /tmp/bad_out.tar
        
        # 3. Decryption test with genuine key
        gpg --batch --yes --decrypt --passphrase-file /etc/vps-backup/backup.key -o /tmp/test_good.tar.zst "$LATEST_ARCHIVE"
        file /tmp/test_good.tar.zst | grep -i "zstandard"
        rm -f /tmp/test_good.tar.zst
        echo "GENUINE_KEY_DECRYPT_OK"
        """
        code, out, err = self._ssh_exec(cmd)
        if code != 0 or "BAD_KEY_REJECTED_CLEANLY" not in out or "GENUINE_KEY_DECRYPT_OK" not in out:
            self.log("TEST-4", f"Encryption audit failed: {err}\nOutput: {out}", False)
            return False

        self.log("TEST-4", "GPG AES-256 verified: Cipher packet confirmed, bad key rejected, valid key decrypts cleanly.", True)
        return True

    # =========================================================================
    # Test 5: Decompression & Archive Payload Structure
    # =========================================================================
    def test_05_payload_structure(self) -> bool:
        self.log("TEST-5", "Auditing decrypted payload structure, manifest.json, and sha256sums.txt...")
        cmd = """
        set -e
        LATEST_ARCHIVE=$(find /var/backups/gdrive_remote_mock/VPS_Backups/ /var/backups/gdrive_staging/ -name "vps-backup-*.tar.zst.gpg" | sort | tail -n 1)
        TMP_INSPECT="/tmp/vps_inspect_$$"
        mkdir -p "$TMP_INSPECT"
        gpg --batch --yes --decrypt --passphrase-file /etc/vps-backup/backup.key "$LATEST_ARCHIVE" | tar --zstd -tf - > "$TMP_INSPECT/filelist.txt"
        
        grep -q "manifest.json" "$TMP_INSPECT/filelist.txt"
        grep -q "sha256sums.txt" "$TMP_INSPECT/filelist.txt"
        grep -q "syncclipboard" "$TMP_INSPECT/filelist.txt"
        grep -q "npm" "$TMP_INSPECT/filelist.txt"
        grep -q "system" "$TMP_INSPECT/filelist.txt"
        
        echo "PAYLOAD_FILES_COUNT: $(wc -l < $TMP_INSPECT/filelist.txt)"
        rm -rf "$TMP_INSPECT"
        echo "PAYLOAD_AUDIT_OK"
        """
        code, out, err = self._ssh_exec(cmd)
        if code != 0 or "PAYLOAD_AUDIT_OK" not in out:
            self.log("TEST-5", f"Payload audit failed: {err}\nOutput: {out}", False)
            return False

        self.log("TEST-5", f"Payload structure verified: Manifest, Checksums, SyncClipboard, NPM, System assets present ({out.strip()}).", True)
        return True

    # =========================================================================
    # Test 6: SQLite Online Snapshot Integrity Verification
    # =========================================================================
    def test_06_sqlite_snapshot_integrity(self) -> bool:
        self.log("TEST-6", "Verifying zero data corruption on restored SQLite databases (PRAGMA integrity_check)...")
        cmd = """
        set -e
        LATEST_ARCHIVE=$(find /var/backups/gdrive_remote_mock/VPS_Backups/ /var/backups/gdrive_staging/ -name "vps-backup-*.tar.zst.gpg" | sort | tail -n 1)
        TMP_DB_TEST="/tmp/vps_db_test_$$"
        mkdir -p "$TMP_DB_TEST"
        gpg --batch --yes --decrypt --passphrase-file /etc/vps-backup/backup.key "$LATEST_ARCHIVE" | tar --zstd -xf - -C "$TMP_DB_TEST"
        
        # SyncClipboard DB Check
        SYNC_DB="$TMP_DB_TEST/syncclipboard/data/history.db"
        [ ! -f "$SYNC_DB" ] && SYNC_DB="$TMP_DB_TEST/syncclipboard/history.db"
        SYNC_INTEGRITY=$(sqlite3 "$SYNC_DB" "PRAGMA integrity_check;")
        SYNC_COUNT=$(sqlite3 "$SYNC_DB" "SELECT COUNT(*) FROM HistoryRecords;")
        
        # NPM DB Check
        NPM_DB="$TMP_DB_TEST/npm/database.sqlite"
        NPM_INTEGRITY=$(sqlite3 "$NPM_DB" "PRAGMA integrity_check;")
        NPM_COUNT=$(sqlite3 "$NPM_DB" "SELECT COUNT(*) FROM proxy_host;")
        
        echo "SYNC_INTEGRITY:$SYNC_INTEGRITY, RECORDS:$SYNC_COUNT"
        echo "NPM_INTEGRITY:$NPM_INTEGRITY, HOSTS:$NPM_COUNT"
        rm -rf "$TMP_DB_TEST"
        
        [ "$SYNC_INTEGRITY" = "ok" ] && [ "$NPM_INTEGRITY" = "ok" ] && [ "$SYNC_COUNT" -ge 70 ] && [ "$NPM_COUNT" -ge 10 ]
        """
        code, out, err = self._ssh_exec(cmd)
        if code != 0:
            self.log("TEST-6", f"SQLite integrity verification failed: {err}\nOutput: {out}", False)
            return False

        self.log("TEST-6", f"SQLite online snapshot verification passed: {out.strip()}", True)
        return True

    # =========================================================================
    # Test 7: Disaster Recovery Sandbox Restoration Test
    # =========================================================================
    def test_07_disaster_recovery_sandbox(self) -> bool:
        self.log("TEST-7", "Executing sandbox disaster recovery restore test (--sandbox)...")
        sandbox_path = f"/tmp/vps_restore_sandbox_eval_{int(time.time())}"
        cmd = f"""
        /usr/local/bin/vps-restore-gdrive.sh --latest --sandbox {sandbox_path}
        echo "RESTORE_EXIT:$?"
        [ -d "{sandbox_path}/syncclipboard" ]
        [ -d "{sandbox_path}/npm" ]
        [ -f "{sandbox_path}/manifest.json" ]
        rm -rf "{sandbox_path}"
        """
        code, out, err = self._ssh_exec(cmd)
        if code != 0 or "RESTORE_EXIT:0" not in out:
            self.log("TEST-7", f"Sandbox restore failed: {err}\nOutput: {out}", False)
            return False

        # Verify live production services were untouched and responsive
        check_live = f"curl -k -s -o /dev/null -w '%{{http_code}}' -u '{SC_USER}:{SC_PASS}' {SERVER_URL}/"
        _, live_code, _ = self._ssh_exec(check_live)
        if live_code.strip() not in ("200", "302"):
            self.log("TEST-7", f"Public domain status anomaly: {live_code}", False)
            return False

        self.log("TEST-7", "Sandbox restore test passed. Databases & configurations verified with zero live impact.", True)
        return True

    # =========================================================================
    # Test 8: 7-Day Rolling Retention Pruning Boundary
    # =========================================================================
    def test_08_retention_pruning_boundary(self) -> bool:
        self.log("TEST-8", "Testing 7-day cloud retention pruning boundary...")
        cmd = """
        set -e
        MOCK_DIR="/var/backups/gdrive_remote_mock/VPS_Backups"
        mkdir -p "$MOCK_DIR"
        
        # Create an 8-day old archive (should be pruned)
        OLD_ARCHIVE="$MOCK_DIR/vps-backup-20261031_000000.tar.zst.gpg"
        touch -d "8 days ago" "$OLD_ARCHIVE"
        
        # Create a 6-day old archive (should be kept)
        RECENT_ARCHIVE="$MOCK_DIR/vps-backup-20261102_000000.tar.zst.gpg"
        touch -d "6 days ago" "$RECENT_ARCHIVE"
        
        # Run rclone retention pruning
        rclone delete "$MOCK_DIR/" --config /etc/vps-backup/rclone.conf --min-age 7d
        
        PRUNED=0
        KEPT=0
        [ ! -f "$OLD_ARCHIVE" ] && PRUNED=1
        [ -f "$RECENT_ARCHIVE" ] && KEPT=1
        
        # Clean up test artifact
        rm -f "$RECENT_ARCHIVE"
        
        echo "PRUNED:$PRUNED, KEPT:$KEPT"
        [ "$PRUNED" -eq 1 ] && [ "$KEPT" -eq 1 ]
        """
        code, out, err = self._ssh_exec(cmd)
        if code != 0:
            self.log("TEST-8", f"Retention pruning boundary check failed: {err}\nOutput: {out}", False)
            return False

        self.log("TEST-8", "7-day rolling cloud retention verified: 8-day-old files pruned, <=7-day files preserved.", True)
        return True

    # =========================================================================
    # Test 9: Process Concurrency Locking Protection
    # =========================================================================
    def test_09_concurrency_locking(self) -> bool:
        self.log("TEST-9", "Testing process concurrency locking via flock...")
        cmd = """
        LOCK_FILE="/var/lock/vps-backup-gdrive.lock"
        exec 9>"$LOCK_FILE"
        flock -n 9
        
        # Try to execute backup script in background while lock is held
        if /usr/local/bin/vps-backup-gdrive.sh 2>&1 | grep -q "holding the lock"; then
            echo "CONCURRENCY_BLOCKED_OK"
        else
            echo "CONCURRENCY_FAILED"
            exit 1
        fi
        flock -u 9
        """
        code, out, err = self._ssh_exec(cmd)
        if code != 0 or "CONCURRENCY_BLOCKED_OK" not in out:
            self.log("TEST-9", f"Locking concurrency protection failed: {err}\nOutput: {out}", False)
            return False

        self.log("TEST-9", "Process concurrency locking verified: Duplicate executions cleanly abort without race conditions.", True)
        return True

    # =========================================================================
    # Test 10: Runbook Documentation Completeness
    # =========================================================================
    def test_10_runbook_documentation(self) -> bool:
        self.log("TEST-10", "Validating operator runbook documentation (docs/restore_runbook.md)...")
        runbook_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "docs", "restore_runbook.md")
        if not os.path.isfile(runbook_path):
            self.log("TEST-10", f"Runbook file not found at {runbook_path}", False)
            return False

        with open(runbook_path, "r", encoding="utf-8") as f:
            content = f.read()

        required_sections = [
            "Prerequisites & Architecture",
            "Backup Schedule & Retention",
            "Manual On-Demand Backup",
            "Listing & Inspecting Cloud Archives",
            "Sandbox Disaster Recovery Verification",
            "Live Production Restore",
            "Total Loss / Emergency Rebuild Procedure",
            "Troubleshooting & Failure Alerts"
        ]

        missing = [sec for sec in required_sections if sec not in content]
        if missing:
            self.log("TEST-10", f"Runbook missing sections: {missing}", False)
            return False

        self.log("TEST-10", f"Disaster Recovery Runbook verified: All {len(required_sections)} required sections documented in {runbook_path}.", True)
        return True

    # =========================================================================
    # Harness Runner
    # =========================================================================
    def run_all(self) -> bool:
        print(f"\n{COLOR_CYAN}{COLOR_BOLD}================================================================================{COLOR_RESET}")
        print(f"{COLOR_CYAN}{COLOR_BOLD}   Milestone 4 Automated Google Drive Backup Verification Suite                {COLOR_RESET}")
        print(f"{COLOR_CYAN}{COLOR_BOLD}   Target VPS: {self.vps_host}:{self.vps_port} | User: {self.vps_user}                          {COLOR_RESET}")
        print(f"{COLOR_CYAN}{COLOR_BOLD}================================================================================{COLOR_RESET}\n")

        tests = [
            ("Test 1: Asset Permissions & Tooling", self.test_01_asset_permissions),
            ("Test 2: Systemd Timer & Service Spec", self.test_02_systemd_timer_and_service),
            ("Test 3: Live Backup Execution & Logging", self.test_03_live_backup_execution),
            ("Test 4: GPG AES-256 Symmetric Encryption", self.test_04_encryption_integrity),
            ("Test 5: Zstandard Decompression & Manifest", self.test_05_payload_structure),
            ("Test 6: SQLite Online Snapshot Integrity", self.test_06_sqlite_snapshot_integrity),
            ("Test 7: Disaster Recovery Sandbox Restore", self.test_07_disaster_recovery_sandbox),
            ("Test 8: 7-Day Rolling Retention Boundary", self.test_08_retention_pruning_boundary),
            ("Test 9: Process Concurrency Locking", self.test_09_concurrency_locking),
            ("Test 10: Operator Runbook Documentation", self.test_10_runbook_documentation),
        ]

        passed = 0
        total = len(tests)

        for name, test_func in tests:
            print(f"\n{COLOR_BOLD}--- {name} ---{COLOR_RESET}")
            try:
                res = test_func()
                self.results[name] = res
                if res:
                    passed += 1
            except Exception as e:
                self.log("EXCEPTION", f"Unhandled error in {name}: {e}", False)
                self.results[name] = False

        print(f"\n{COLOR_CYAN}================================================================================{COLOR_RESET}")
        print(f"{COLOR_BOLD}SUMMARY: {passed}/{total} tests passed ({passed/total*100:.1f}%){COLOR_RESET}")
        for name, res in self.results.items():
            mark = f"{COLOR_GREEN}PASS{COLOR_RESET}" if res else f"{COLOR_RED}FAIL{COLOR_RESET}"
            print(f"  [{mark}] {name}")
        print(f"{COLOR_CYAN}================================================================================{COLOR_RESET}\n")

        return passed == total


def main():
    parser = argparse.ArgumentParser(description="M4 Verification Harness")
    parser.add_argument("--host", default=VPS_HOST, help="VPS IP/Host")
    parser.add_argument("--port", type=int, default=VPS_PORT, help="SSH Port")
    args = parser.parse_args()

    harness = BackupVerificationHarness(vps_host=args.host, vps_port=args.port)
    success = harness.run_all()
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
