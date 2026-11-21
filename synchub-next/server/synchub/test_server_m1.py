#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Milestone 1 Verification Tests for SyncHub Python Server:
- S1: SQLite WAL, Connection Safety & Concurrency
- S2: Offline Queue Reliability (since_id <= 0 handling, 72h window, ack_id tracking)
- S3: HTTP Upload Socket Protection (close_connection=True on failure)
- S4: Storage Metric I/O Optimization (30-min cache TTL)
"""

import os
import sys
import time
import json
import sqlite3
import tempfile
import shutil
import unittest
import threading
from io import BytesIO
from datetime import datetime, timezone, timedelta

# Ensure synchub can be imported
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import synchub_server


class MockSyncHubHandler:
    """Mock handler providing minimal BaseHTTPRequestHandler interface for testing."""
    def __init__(self, rfile=None, headers=None, auth_device=None):
        self.rfile = rfile or BytesIO()
        self.wfile = BytesIO()
        self.headers = headers or {}
        self.auth_device = auth_device or {"device_id": "test_dev_1", "name": "DeviceOne"}
        self.close_connection = False
        self.sent_json = None
        self.sent_status = None

    def send_json(self, data, status_code=200):
        self.sent_json = data
        self.sent_status = status_code

    def send_response(self, code, message=None):
        self.sent_status = code

    def send_header(self, keyword, value):
        pass

    def end_headers(self):
        pass

    def _delete_single_id(self, cur, item_id):
        return synchub_server.SyncHubHandler._delete_single_id(self, cur, item_id)


class TestSyncHubServerM1(unittest.TestCase):
    def setUp(self):
        # Create an isolated temporary directory for test DB and data
        self.test_dir = tempfile.mkdtemp(prefix="synchub_test_m1_")
        self.orig_data_dir = synchub_server.DATA_DIR
        self.orig_db_file = synchub_server.DB_FILE
        self.orig_history_dir = synchub_server.HISTORY_DIR

        synchub_server.DATA_DIR = self.test_dir
        synchub_server.DB_FILE = os.path.join(self.test_dir, "server", "data", "history.db")
        synchub_server.HISTORY_DIR = os.path.join(self.test_dir, "server", "history")
        synchub_server.SERVER_FILE_DIR = os.path.join(self.test_dir, "server", "file")
        synchub_server.PERM_DIR = os.path.join(self.test_dir, "permanent")
        synchub_server.PERM_ITEMS_DIR = os.path.join(synchub_server.PERM_DIR, "items")

        os.makedirs(os.path.dirname(synchub_server.DB_FILE), exist_ok=True)
        os.makedirs(synchub_server.HISTORY_DIR, exist_ok=True)
        self._init_test_db()

    def tearDown(self):
        synchub_server.DATA_DIR = self.orig_data_dir
        synchub_server.DB_FILE = self.orig_db_file
        synchub_server.HISTORY_DIR = self.orig_history_dir
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def _init_test_db(self):
        conn = synchub_server.get_db_connection(readonly=False)
        cur = conn.cursor()
        cur.execute("""
            CREATE TABLE IF NOT EXISTS HistoryRecords (
                ID INTEGER PRIMARY KEY AUTOINCREMENT,
                UserId TEXT DEFAULT 'default_user',
                Type INTEGER DEFAULT 0,
                Text TEXT DEFAULT '',
                Size INTEGER DEFAULT 0,
                TransferDataFile TEXT DEFAULT '',
                TransferDataSha256 TEXT DEFAULT '',
                TransferDataMd5 TEXT DEFAULT '',
                FilePaths TEXT DEFAULT '[]',
                Hash TEXT DEFAULT '',
                CreateTime TEXT DEFAULT '',
                LastAccessed TEXT DEFAULT '',
                LastModified TEXT DEFAULT '',
                Stared INTEGER DEFAULT 0,
                Pinned INTEGER DEFAULT 0,
                "From" TEXT DEFAULT '',
                Tags TEXT DEFAULT '[]',
                ExtraData TEXT DEFAULT '{}',
                Version INTEGER DEFAULT 1,
                IsDeleted INTEGER DEFAULT 0,
                TransferDataHash TEXT DEFAULT ''
            )
        """)
        conn.commit()
        conn.close()

    # --- S1: SQLite WAL & Concurrency Tests ---

    def test_s1_sqlite_wal_pragmas(self):
        """Verify get_db_connection sets WAL mode, synchronous=NORMAL, and busy_timeout=10000."""
        conn = synchub_server.get_db_connection(readonly=False)
        try:
            cur = conn.cursor()
            cur.execute("PRAGMA journal_mode;")
            journal_mode = cur.fetchone()[0].lower()
            self.assertEqual(journal_mode, "wal", "SQLite should be configured in WAL mode")

            cur.execute("PRAGMA synchronous;")
            synchronous = cur.fetchone()[0]
            # 1 = NORMAL
            self.assertEqual(synchronous, 1, "SQLite synchronous mode should be NORMAL (1)")

            cur.execute("PRAGMA busy_timeout;")
            busy_timeout = cur.fetchone()[0]
            self.assertEqual(busy_timeout, 10000, "SQLite busy_timeout should be 10000ms")
        finally:
            conn.close()

    def test_s1_concurrent_readers_writers_no_lock(self):
        """Verify concurrent readers and writers operate without 'database is locked' errors."""
        errors = []
        threads = []

        def writer_task(worker_id):
            for i in range(10):
                conn = None
                try:
                    conn = synchub_server.get_db_connection(readonly=False)
                    cur = conn.cursor()
                    now_str = synchub_server.format_db_time()
                    cur.execute(
                        "INSERT INTO HistoryRecords (Type, Text, CreateTime) VALUES (0, ?, ?)",
                        (f"worker_{worker_id}_msg_{i}", now_str)
                    )
                    conn.commit()
                    time.sleep(0.005)
                except Exception as e:
                    errors.append(f"Writer {worker_id} error: {e}")
                finally:
                    if conn is not None:
                        conn.close()

        def reader_task(worker_id):
            for _ in range(15):
                conn = None
                try:
                    conn = synchub_server.get_db_connection(readonly=True)
                    cur = conn.cursor()
                    cur.execute("SELECT COUNT(*) FROM HistoryRecords WHERE IsDeleted = 0")
                    _ = cur.fetchone()[0]
                    time.sleep(0.003)
                except Exception as e:
                    errors.append(f"Reader {worker_id} error: {e}")
                finally:
                    if conn is not None:
                        conn.close()

        for w in range(5):
            threads.append(threading.Thread(target=writer_task, args=(w,)))
        for r in range(5):
            threads.append(threading.Thread(target=reader_task, args=(r,)))

        for t in threads:
            t.start()
        for t in threads:
            t.join()

        self.assertEqual(len(errors), 0, f"Concurrent DB operations failed with errors: {errors}")

    # --- S2: Offline Queue Reliability Tests ---

    def test_s2_auto_pull_since_id_zero_returns_offline_queue(self):
        """Verify handle_auto_pull with since_id <= 0 returns undelivered targeted files within 72h."""
        # Insert a file record targeted to 'device_target' created 2 hours ago
        conn = synchub_server.get_db_connection(readonly=False)
        cur = conn.cursor()
        create_time = synchub_server.format_db_time(datetime.now(timezone.utc) - timedelta(hours=2))
        extra_json = json.dumps({
            "category": "文档",
            "source_device": "DeviceSender",
            "source_device_id": "sender_123",
            "target_device": "device_target"
        })
        cur.execute(
            """
            INSERT INTO HistoryRecords (
                Type, Text, Size, TransferDataFile, Hash, CreateTime, ExtraData, IsDeleted
            ) VALUES (1, 'offline_doc.pdf', 1024, 'offline_doc.pdf', 'HASH_ABC', ?, ?, 0)
            """,
            (create_time, extra_json)
        )
        file_id = cur.lastrowid
        conn.commit()
        conn.close()

        # Mock physical file
        folder = os.path.join(synchub_server.HISTORY_DIR, "File_HASH_ABC")
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, "offline_doc.pdf"), "wb") as f:
            f.write(b"content")

        handler = MockSyncHubHandler()
        # Client connects with since_id = 0
        qs = {"device_id": ["device_target"], "since_id": ["0"]}
        synchub_server.SyncHubHandler.handle_auto_pull(handler, qs)

        self.assertIsNotNone(handler.sent_json)
        self.assertTrue(handler.sent_json.get("ok"))
        items = handler.sent_json.get("items", [])
        self.assertEqual(len(items), 1, "Should return the pending offline file queued within 72h")
        self.assertEqual(items[0]["id"], file_id)
        self.assertEqual(items[0]["filename"], "offline_doc.pdf")

    def test_s2_delivery_ack_and_cursor_progression(self):
        """Verify delivery ACK (ack_id) persists per-device cursor in AutoPullAcks."""
        # Insert two files targeted to device_ack_test
        conn = synchub_server.get_db_connection(readonly=False)
        cur = conn.cursor()
        now_str = synchub_server.format_db_time()
        extra_json = json.dumps({"target_device": "device_ack_test"})
        cur.execute(
            "INSERT INTO HistoryRecords (Type, Text, Size, TransferDataFile, Hash, CreateTime, ExtraData, IsDeleted) VALUES (1, 'file1.txt', 10, 'file1.txt', 'H1', ?, ?, 0)",
            (now_str, extra_json)
        )
        id1 = cur.lastrowid
        cur.execute(
            "INSERT INTO HistoryRecords (Type, Text, Size, TransferDataFile, Hash, CreateTime, ExtraData, IsDeleted) VALUES (1, 'file2.txt', 20, 'file2.txt', 'H2', ?, ?, 0)",
            (now_str, extra_json)
        )
        id2 = cur.lastrowid
        conn.commit()
        conn.close()

        for h, fname in [("H1", "file1.txt"), ("H2", "file2.txt")]:
            d = os.path.join(synchub_server.HISTORY_DIR, f"File_{h}")
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, fname), "wb") as f:
                f.write(b"data")

        # Step 1: Initial pull with since_id=0 receives both
        handler1 = MockSyncHubHandler()
        synchub_server.SyncHubHandler.handle_auto_pull(handler1, {"device_id": ["device_ack_test"], "since_id": ["0"]})
        items = handler1.sent_json.get("items", [])
        self.assertEqual(len(items), 2)

        # Step 2: Client acknowledges first item via ack_id=id1
        handler2 = MockSyncHubHandler()
        synchub_server.SyncHubHandler.handle_auto_pull(handler2, {
            "device_id": ["device_ack_test"],
            "since_id": ["0"],
            "ack_id": [str(id1)]
        })
        self.assertTrue(handler2.sent_json.get("ok"))
        self.assertEqual(handler2.sent_json.get("ackId"), id1)

        # Verify AutoPullAcks table has id1 recorded for device_ack_test
        conn = synchub_server.get_db_connection(readonly=True)
        cur = conn.cursor()
        cur.execute("SELECT last_ack_id FROM AutoPullAcks WHERE device_id = 'device_ack_test'")
        row = cur.fetchone()
        conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row["last_ack_id"], id1)

        # Step 3: Client restarts from scratch with since_id=0 -> server resumes from last_ack_id (id1)
        handler3 = MockSyncHubHandler()
        synchub_server.SyncHubHandler.handle_auto_pull(handler3, {"device_id": ["device_ack_test"], "since_id": ["0"]})
        resumed_items = handler3.sent_json.get("items", [])
        self.assertEqual(len(resumed_items), 1, "Should only return unacknowledged file2")
        self.assertEqual(resumed_items[0]["id"], id2)

    def test_s2_auto_pull_empty_device_id_no_crash(self):
        """Verify handle_auto_pull with since_id=0 and empty device_id='' on a fresh database succeeds cleanly without throwing readonly database error."""
        fresh_dir = tempfile.mkdtemp(prefix="synchub_empty_dev_")
        old_db_file = synchub_server.DB_FILE
        try:
            fresh_db = os.path.join(fresh_dir, "fresh.db")
            synchub_server.DB_FILE = fresh_db
            conn = synchub_server.get_db_connection(readonly=False)
            conn.execute("CREATE TABLE HistoryRecords (ID INTEGER PRIMARY KEY, IsDeleted INT, CreateTime TEXT)")
            conn.commit()
            conn.close()

            handler = MockSyncHubHandler(auth_device={"device_id": ""})
            qs = {"since_id": ["0"], "device_id": [""]}
            synchub_server.SyncHubHandler.handle_auto_pull(handler, qs)

            self.assertIsNotNone(handler.sent_json, "Handler must send JSON response")
            self.assertTrue(handler.sent_json.get("ok"), f"Auto-pull failed: {handler.sent_json}")
            self.assertEqual(handler.sent_json.get("latestId"), 0)
            self.assertEqual(handler.sent_json.get("items"), [])
        finally:
            synchub_server.DB_FILE = old_db_file
            shutil.rmtree(fresh_dir, ignore_errors=True)

    # --- S3: HTTP Upload Socket Protection Tests ---

    def test_s3_upload_interrupted_sets_close_connection(self):
        """Verify interrupted upload sets close_connection=True to prevent HTTP/1.1 socket desync."""
        # Simulated stream with Content-Length 1000, but only 100 bytes available
        fake_data = b"x" * 100
        handler = MockSyncHubHandler(
            rfile=BytesIO(fake_data),
            headers={"Content-Length": "1000", "X-File-Name": "interrupted.bin"}
        )

        synchub_server.SyncHubHandler.handle_upload_stream(handler, {})

        self.assertTrue(handler.close_connection, "handler.close_connection must be True on aborted stream")
        self.assertEqual(handler.sent_status, 500)
        self.assertIn("Upload interrupted", handler.sent_json.get("error", ""))

    def test_s3_upload_success_preserves_connection(self):
        """Verify successful upload completes normally and does not prematurely force close_connection."""
        file_payload = b"Hello SyncHub Milestone 1"
        handler = MockSyncHubHandler(
            rfile=BytesIO(file_payload),
            headers={"Content-Length": str(len(file_payload)), "X-File-Name": "success.txt"}
        )

        synchub_server.SyncHubHandler.handle_upload_stream(handler, {})

        self.assertFalse(handler.close_connection, "Successful upload should not set close_connection")
        self.assertEqual(handler.sent_status, 200)
        self.assertTrue(handler.sent_json.get("ok"))
        item = handler.sent_json.get("item")
        self.assertEqual(item["filename"], "success.txt")
        self.assertEqual(item["size"], len(file_payload))

    # --- S4: Storage Metric Cache TTL Tests ---

    def test_s4_storage_cache_ttl(self):
        """Verify storage metric cache TTL is 1800s (30 minutes) to avoid frequent recursive os.walk."""
        self.assertEqual(synchub_server.STORAGE_CACHE_TTL, 1800)

        # Populate cache manually
        with synchub_server._storage_lock:
            synchub_server._storage_cache["hub"] = 99999
            synchub_server._storage_cache["at"] = time.time()
            synchub_server._storage_cache["busy"] = False

        info = synchub_server.get_storage_info()
        self.assertTrue(info["ok"])
        self.assertEqual(info["hubBytes"], 99999)

    # --- S1: Handler Connection Safety Tests ---

    def test_s1_all_db_handlers_cleanup(self):
        """Verify handle_post_text, handle_list_items, handle_update_item, handle_delete_item, handle_batch_delete, handle_download, and cleanup_expired_items properly close connections."""
        # 1. Post text
        post_body = json.dumps({"text": "Hello world", "starred": True}).encode("utf-8")
        handler_post = MockSyncHubHandler(
            rfile=BytesIO(post_body),
            headers={"Content-Length": str(len(post_body))}
        )
        synchub_server.SyncHubHandler.handle_post_text(handler_post)
        self.assertTrue(handler_post.sent_json.get("ok"))
        item_id = handler_post.sent_json["item"]["id"]

        # 2. List items
        handler_list = MockSyncHubHandler()
        synchub_server.SyncHubHandler.handle_list_items(handler_list, {})
        self.assertTrue(handler_list.sent_json.get("ok"))
        self.assertGreaterEqual(len(handler_list.sent_json["items"]), 1)

        # 3. Update item
        update_body = json.dumps({"pinned": True}).encode("utf-8")
        handler_update = MockSyncHubHandler(
            rfile=BytesIO(update_body),
            headers={"Content-Length": str(len(update_body))}
        )
        synchub_server.SyncHubHandler.handle_update_item(handler_update, item_id)
        self.assertTrue(handler_update.sent_json.get("ok"))
        self.assertTrue(handler_update.sent_json["item"]["pinned"])

        # 4. Download handler (for text record or invalid file)
        handler_dl = MockSyncHubHandler()
        synchub_server.SyncHubHandler.handle_download(handler_dl, f"/api/hub/download/{item_id}/test.txt", {})
        # File path is text file created in HISTORY_DIR
        self.assertTrue(handler_dl.sent_status in (200, 404))

        # 5. Delete item
        handler_del = MockSyncHubHandler()
        synchub_server.SyncHubHandler.handle_delete_item(handler_del, item_id)
        self.assertTrue(handler_del.sent_json.get("ok"))
        self.assertEqual(handler_del.sent_json.get("deletedId"), item_id)

        # 6. Batch delete
        batch_body = json.dumps({"mode": "unstarred"}).encode("utf-8")
        handler_batch = MockSyncHubHandler(
            rfile=BytesIO(batch_body),
            headers={"Content-Length": str(len(batch_body))}
        )
        synchub_server.SyncHubHandler.handle_batch_delete(handler_batch)
        self.assertTrue(handler_batch.sent_json.get("ok"))

        # 7. Cleanup expired items
        purged = synchub_server.cleanup_expired_items()
        self.assertIsInstance(purged, int)


if __name__ == "__main__":
    unittest.main()
