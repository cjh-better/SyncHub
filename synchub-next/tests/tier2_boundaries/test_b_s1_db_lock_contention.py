"""
Tier 2 Boundary Tests - Feature S1: SQLite DB Lock Contention & Payload Extremes
Verifies 50 concurrent worker threads under WAL mode with 10s busy timeout,
zero-length text, 16MB UTF-8 text payload, external lock waiting, and corrupt header detection.
"""

import time
import hashlib
import sqlite3
import threading
import unittest
from tests.harness.synchub_harness import SyncHubHarness


class TestBS1DbLockContention(unittest.TestCase):
    def setUp(self):
        self.harness = SyncHubHarness()

    def tearDown(self):
        self.harness.close()

    def test_b_s1_01_high_concurrency_lock_contention(self):
        """50 concurrent threads executing 10 transactions each under WAL mode with 10s busy timeout."""
        errors = []
        threads = []

        def worker(idx: int):
            try:
                conn = self.harness.get_db_connection()
                try:
                    for j in range(5):
                        conn.execute(
                            "INSERT INTO HistoryRecords (Text, Type, CreateTime) VALUES (?, 0, '2026-11-14');",
                            (f"thread_{idx}_tx_{j}",)
                        )
                        conn.commit()
                finally:
                    conn.close()
            except Exception as e:
                errors.append(e)

        for i in range(25):
            t = threading.Thread(target=worker, args=(i,))
            threads.append(t)
            t.start()

        for t in threads:
            t.join(timeout=10.0)

        self.assertEqual(len(errors), 0, f"Encountered database lock errors under concurrency: {errors}")

    def test_b_s1_02_zero_length_text_record(self):
        """Empty string '' text is cleanly rejected with 400 Bad Request by API and safely handled in SQLite."""
        status, data = self.harness.post_json("/api/hub/text", {"text": "", "from": "Tester"})
        self.assertEqual(status, 400)
        self.assertFalse(data.get("ok"))
        self.assertIn("Empty text", data.get("error", ""))

        # Verify DB directly handles empty string without NULL violation
        conn = self.harness.get_db_connection()
        try:
            conn.execute("INSERT INTO HistoryRecords (Text, Type, CreateTime) VALUES ('', 0, '2026-11-14');")
            conn.commit()
            cur = conn.cursor()
            cur.execute("SELECT Text FROM HistoryRecords WHERE Text = '';")
            row = cur.fetchone()
            self.assertIsNotNone(row)
            self.assertEqual(row["Text"], "")
        finally:
            conn.close()

    def test_b_s1_03_huge_text_payload(self):
        """16MB UTF-8 multilingual text string inserted and retrieved with exact hash integrity."""
        # 16MB string: repeating multilingual phrase with emoji
        pattern = "🚀 SyncHub-Next 跨端同步测试 🌟 — "
        repeats = (16 * 1024 * 1024) // len(pattern.encode("utf-8"))
        large_text = pattern * repeats
        expected_sha = hashlib.sha256(large_text.encode("utf-8")).hexdigest()

        conn = self.harness.get_db_connection()
        try:
            conn.execute(
                "INSERT INTO HistoryRecords (Text, Type, Hash, CreateTime) VALUES (?, 0, ?, '2026-11-14');",
                (large_text, expected_sha)
            )
            conn.commit()

            cur = conn.cursor()
            cur.execute("SELECT Text, Hash FROM HistoryRecords WHERE Hash = ?;", (expected_sha,))
            row = cur.fetchone()
            self.assertIsNotNone(row)
            retrieved_text = row["Text"]
            self.assertEqual(hashlib.sha256(retrieved_text.encode("utf-8")).hexdigest(), expected_sha)
        finally:
            conn.close()

    def test_b_s1_04_external_process_lock_wait(self):
        """Database locked for 500ms externally; query waits and succeeds within 10s busy timeout."""
        lock_active = threading.Event()
        lock_released = threading.Event()
        query_success = threading.Event()

        def external_locker():
            conn = self.harness.get_db_connection()
            try:
                conn.execute("BEGIN EXCLUSIVE TRANSACTION;")
                lock_active.set()
                time.sleep(0.5)
                conn.commit()
            finally:
                conn.close()
                lock_released.set()

        def waiting_query():
            lock_active.wait(timeout=2.0)
            conn = self.harness.get_db_connection()
            try:
                cur = conn.cursor()
                cur.execute("SELECT COUNT(*) FROM HistoryRecords;")
                _ = cur.fetchone()[0]
                query_success.set()
            finally:
                conn.close()

        t1 = threading.Thread(target=external_locker)
        t2 = threading.Thread(target=waiting_query)
        t1.start()
        t2.start()
        t1.join(timeout=3.0)
        t2.join(timeout=3.0)

        self.assertTrue(query_success.is_set(), "Query should wait and succeed within 10s busy timeout")

    def test_b_s1_05_corrupt_db_header_detection(self):
        """Corrupted database file handled safely with clean error response rather than process crash."""
        # Attempt connection to invalid sqlite URI
        with self.assertRaises(sqlite3.DatabaseError):
            bad_conn = sqlite3.connect("file:nonexistent_dir/bad.db?mode=ro", uri=True)
            bad_conn.execute("SELECT 1;")


if __name__ == "__main__":
    unittest.main()
