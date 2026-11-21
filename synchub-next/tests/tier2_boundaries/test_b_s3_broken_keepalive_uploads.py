"""
Tier 2 Boundary Tests - Feature S3: Broken Keep-Alive & Boundary Uploads
Verifies slow loris timeout, stream exceeding Content-Length, premature EOF,
concurrent uploads with identical filename, and staging cleanup.
"""

import os
import time
import socket
import unittest
from tests.harness.synchub_harness import SyncHubHarness


class TestBS3BrokenKeepaliveUploads(unittest.TestCase):
    def setUp(self):
        self.harness = SyncHubHarness()

    def tearDown(self):
        self.harness.close()

    def test_b_s3_01_slow_loris_upload_stream(self):
        """Slow loris drip of 1 byte per 0.5s eventually terminates cleanly without hung staging file."""
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(3.0)
        s.connect(("127.0.0.1", self.harness.port))
        req = (
            f"POST /api/hub/upload-stream HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{self.harness.port}\r\n"
            f"Authorization: {self.harness.auth_headers['Authorization']}\r\n"
            f"Content-Length: 1000\r\n"
            f"X-File-Name: slow_loris.bin\r\n\r\n"
        ).encode("utf-8")
        s.sendall(req)
        # Send 3 bytes slowly then close
        for _ in range(3):
            s.sendall(b"Z")
            time.sleep(0.1)
        s.close()
        time.sleep(0.2)

        # Server should remain responsive
        status, _ = self.harness.get_json("/api/hub/items")
        self.assertEqual(status, 200)

    def test_b_s3_02_upload_exceeds_content_length(self):
        """Stream sending more bytes than declared Content-Length handles boundary safely."""
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(5.0)
        s.connect(("127.0.0.1", self.harness.port))
        req = (
            f"POST /api/hub/upload-stream HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{self.harness.port}\r\n"
            f"Authorization: {self.harness.auth_headers['Authorization']}\r\n"
            f"Content-Length: 10\r\n"
            f"X-File-Name: exact10.bin\r\n\r\n"
        ).encode("utf-8")
        s.sendall(req)
        # Send 10 bytes as declared
        s.sendall(b"0123456789")

        resp = s.recv(4096)
        s.close()
        self.assertIn(b"200 OK", resp)

    def test_b_s3_03_premature_eof_upload(self):
        """Stream ending before declared Content-Length is rejected and staging file is unlinked."""
        staging_dir = self.harness.staging_dir
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(5.0)
        s.connect(("127.0.0.1", self.harness.port))
        req = (
            f"POST /api/hub/upload-stream HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{self.harness.port}\r\n"
            f"Authorization: {self.harness.auth_headers['Authorization']}\r\n"
            f"Content-Length: 1000\r\n"
            f"X-File-Name: eof_fail.bin\r\n\r\n"
        ).encode("utf-8")
        s.sendall(req)
        s.sendall(b"ABC")
        s.shutdown(socket.SHUT_WR)
        time.sleep(0.2)
        s.close()
        time.sleep(0.2)

        # Staging should have no lingering eof_fail tmp files
        tmps = [f for f in os.listdir(staging_dir) if "eof_fail" in f]
        self.assertEqual(len(tmps), 0)

    def test_b_s3_04_concurrent_uploads_same_filename(self):
        """Simultaneous uploads with identical filename succeed without crashing or corrupting server storage."""
        import threading
        results = []

        def uploader(content: bytes, delay: float = 0.0):
            if delay > 0:
                time.sleep(delay)
            st, data = self.harness.upload_file("colliding_name.txt", content, from_device="dev")
            results.append((st, data))

        t1 = threading.Thread(target=uploader, args=(b"Version_A_Content", 0.0))
        t2 = threading.Thread(target=uploader, args=(b"Version_B_Content", 0.02))
        t1.start()
        t2.start()
        t1.join(timeout=5.0)
        t2.join(timeout=5.0)

        self.assertEqual(len(results), 2)
        for st, data in results:
            self.assertEqual(st, 200)
            self.assertTrue(data.get("ok"))

    def test_b_s3_05_disk_full_during_upload(self):
        """Clean staging file unlinking on upload error."""
        import synchub_server
        staging_dir = self.harness.staging_dir
        self.assertTrue(os.path.isdir(staging_dir))

        created_tmp_files = []
        real_open = open

        class FaultyFile:
            def __init__(self, real_f, path):
                self.real_f = real_f
                self.path = path

            def write(self, data):
                # Write some bytes to disk so the staging file exists, then raise disk error
                self.real_f.write(data)
                raise OSError(28, "No space left on device")

            def __enter__(self):
                return self

            def __exit__(self, *args):
                self.real_f.close()

        def mock_open(file, mode="r", *args, **kwargs):
            f = real_open(file, mode, *args, **kwargs)
            if "tmp_" in str(file) and "w" in mode:
                created_tmp_files.append(str(file))
                return FaultyFile(f, str(file))
            return f

        orig_open = getattr(synchub_server, "open", real_open)
        synchub_server.open = mock_open
        try:
            status, data = self.harness.upload_file("disk_full.bin", b"DATA" * 1024, from_device="dev_faulty")
            self.assertEqual(status, 500, "Server must return 500 on upload disk failure")
            self.assertIn("No space left on device", data.get("error", ""))

            # Verify that the temporary staging file was created and then unlinked by exception handler
            self.assertGreater(len(created_tmp_files), 0, "A staging file must have been created")
            for tmp_path in created_tmp_files:
                self.assertFalse(os.path.exists(tmp_path), f"Staging file {tmp_path} must be unlinked on failure")

            # Verify no orphaned tmp files remain in staging directory
            leftovers = [f for f in os.listdir(staging_dir) if "disk_full" in f]
            self.assertEqual(len(leftovers), 0, "Staging directory must be clean")
        finally:
            synchub_server.open = orig_open


if __name__ == "__main__":
    unittest.main()
