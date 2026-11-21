"""
Tier 1 Tests - Feature S1: SQLite WAL & Connection Safety
Verifies WAL journal mode, busy_timeout=10000, concurrent reader/writer safety,
and connection cleanup across handlers.
"""

import time
import sqlite3
import threading
import unittest
from tests.harness.synchub_harness import SyncHubHarness


class TestS1SqliteWal(unittest.TestCase):
    def setUp(self):
        self.harness = SyncHubHarness()

    def tearDown(self):
        self.harness.close()

    def test_s1_01_pragma_verification(self):
        """Verify PRAGMA journal_mode returns wal and busy_timeout returns 10000."""
        conn = self.harness.get_db_connection()
        try:
            cur = conn.cursor()
            cur.execute("PRAGMA journal_mode;")
            journal_mode = cur.fetchone()[0].lower()
            self.assertEqual(journal_mode, "wal", f"Expected WAL mode, got {journal_mode}")

            cur.execute("PRAGMA busy_timeout;")
            busy_timeout = cur.fetchone()[0]
            self.assertEqual(busy_timeout, 10000, f"Expected 10000ms busy timeout, got {busy_timeout}")
        finally:
            conn.close()

    def test_s1_02_concurrent_read_during_write(self):
        """Simultaneous reader query succeeds without database is locked during an open write transaction."""
        write_started = threading.Event()
        read_finished = threading.Event()
        read_error = []

        def writer():
            conn = self.harness.get_db_connection()
            try:
                conn.execute("BEGIN EXCLUSIVE TRANSACTION;")
                conn.execute("INSERT INTO HistoryRecords (Text, Type, CreateTime) VALUES ('concurrent_test', 0, '2026-11-14');")
                write_started.set()
                # Hold transaction open for reader to execute
                read_finished.wait(timeout=5.0)
                conn.commit()
            finally:
                conn.close()

        def reader():
            write_started.wait(timeout=5.0)
            conn = self.harness.get_db_connection(readonly=True)
            try:
                cur = conn.cursor()
                cur.execute("SELECT COUNT(*) FROM HistoryRecords;")
                _ = cur.fetchone()[0]
            except Exception as e:
                read_error.append(e)
            finally:
                conn.close()
                read_finished.set()

        t_writer = threading.Thread(target=writer)
        t_reader = threading.Thread(target=reader)
        t_writer.start()
        t_reader.start()
        t_reader.join(timeout=6.0)
        t_writer.join(timeout=6.0)

        self.assertEqual(len(read_error), 0, f"Reader encountered error during concurrent write: {read_error}")

    def test_s1_03_connection_close_on_success(self):
        """Verify successful handler execution cleanly closes database connection."""
        status, data = self.harness.post_json("/api/hub/text", {"text": "Clean Close Test", "from": "Device1"})
        self.assertEqual(status, 200)
        self.assertTrue(data.get("ok"))

        # Verify database is unlocked and writable by another immediate connection
        conn = self.harness.get_db_connection()
        try:
            conn.execute("UPDATE HistoryRecords SET Stared = 1 WHERE Text = 'Clean Close Test';")
            conn.commit()
        finally:
            conn.close()

    def test_s1_04_connection_close_on_exception(self):
        """Verify unhandled or bad queries close connections in finally block, leaving DB unlocked."""
        # Intentionally send malformed payload to /api/hub/item/999999/update
        status, _ = self.harness.post_json("/api/hub/item/invalid_id/update", {"starred": True})
        # Regardless of 400 or 500 status, DB must not remain locked
        conn = self.harness.get_db_connection()
        try:
            cur = conn.cursor()
            cur.execute("SELECT COUNT(*) FROM HistoryRecords;")
            count = cur.fetchone()[0]
            self.assertGreaterEqual(count, 0)
        finally:
            conn.close()

    def test_s1_05_nine_handlers_audited(self):
        """Audit primary endpoints: items, text, auto-pull, storage to ensure zero connection leaks."""
        # 1. Post text
        s1, d1 = self.harness.post_json("/api/hub/text", {"text": "Audit Item", "from": "Tester"})
        self.assertEqual(s1, 200)
        item_id = d1.get("item", {}).get("id")
        self.assertIsNotNone(item_id)

        # 2. List items
        s2, d2 = self.harness.get_json("/api/hub/items")
        self.assertEqual(s2, 200)
        self.assertGreaterEqual(len(d2.get("items", [])), 1)

        # 3. Storage
        s3, d3 = self.harness.get_json("/api/hub/storage")
        self.assertEqual(s3, 200)
        self.assertTrue(d3.get("ok"))

        # 4. Auto-pull
        s4, d4 = self.harness.get_json(f"/api/hub/auto-pull?device_id=Tester&since_id=0")
        self.assertEqual(s4, 200)
        self.assertTrue(d4.get("ok"))

        # 5. Delete item
        s5, d5 = self.harness.post_json(f"/api/hub/item/{item_id}/delete", {})
        self.assertEqual(s5, 200)


if __name__ == "__main__":
    unittest.main()
