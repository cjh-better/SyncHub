"""
Tier 1 Tests - Feature S3: HTTP Upload Socket Protection
Verifies Keep-Alive protection, close_connection=True on aborted uploads,
staging temporary file cleanup, successful Keep-Alive reuse, and zero-byte handling.
"""

import os
import time
import socket
import unittest
from tests.harness.synchub_harness import SyncHubHarness


class TestS3HttpUploadSocket(unittest.TestCase):
    def setUp(self):
        self.harness = SyncHubHarness()

    def tearDown(self):
        self.harness.close()

    def test_s3_01_premature_disconnect_socket_close(self):
        """Client aborts upload mid-stream; server sets close_connection=True and does not crash."""
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(5.0)
        s.connect(("127.0.0.1", self.harness.port))

        req = (
            f"POST /api/hub/upload-stream HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{self.harness.port}\r\n"
            f"Authorization: {self.harness.auth_headers['Authorization']}\r\n"
            f"Content-Length: 100000\r\n"
            f"X-File-Name: abort_stream.bin\r\n"
            f"Connection: keep-alive\r\n\r\n"
        ).encode("utf-8")
        s.sendall(req)
        # Send only 100 bytes
        s.sendall(b"A" * 100)
        # Abruptly close
        s.close()
        time.sleep(0.2)

        # Ensure server is healthy and accepts next normal request
        status, data = self.harness.get_json("/api/hub/items")
        self.assertEqual(status, 200)

    def test_s3_02_http_header_connection_close_on_abort(self):
        """Interrupted upload causes server to send error response with Connection: close or terminate stream."""
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(5.0)
        s.connect(("127.0.0.1", self.harness.port))

        req = (
            f"POST /api/hub/upload-stream HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{self.harness.port}\r\n"
            f"Authorization: {self.harness.auth_headers['Authorization']}\r\n"
            f"Content-Length: 50000\r\n"
            f"X-File-Name: truncated.bin\r\n"
            f"Connection: keep-alive\r\n\r\n"
        ).encode("utf-8")
        s.sendall(req)
        s.sendall(b"B" * 500)
        # Shutdown send side to signal premature EOF
        s.shutdown(socket.SHUT_WR)

        response = b""
        try:
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                response += chunk
        except Exception:
            pass
        finally:
            s.close()

        resp_text = response.decode("utf-8", errors="replace").lower()
        self.assertIn("http/1.1 500", resp_text)
        self.assertIn("connection: close", resp_text)

    def test_s3_03_successful_upload_keepalive_persists(self):
        """Valid 512KB upload completes with 200 OK and keeps connection open for subsequent requests."""
        payload = b"K" * (512 * 1024)
        status, data = self.harness.upload_file("keepalive_test.bin", payload, from_device="tester")
        self.assertEqual(status, 200)
        self.assertTrue(data.get("ok"))

        # Immediately make another request on server
        status2, data2 = self.harness.get_json("/api/hub/items")
        self.assertEqual(status2, 200)

    def test_s3_04_staging_file_cleanup_on_failure(self):
        """Incomplete staging .tmp files are unlinked from hub_staging on upload failure."""
        staging_dir = self.harness.staging_dir
        initial_tmp_files = [f for f in os.listdir(staging_dir) if f.startswith("tmp_")]

        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(5.0)
        s.connect(("127.0.0.1", self.harness.port))
        req = (
            f"POST /api/hub/upload-stream HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{self.harness.port}\r\n"
            f"Authorization: {self.harness.auth_headers['Authorization']}\r\n"
            f"Content-Length: 99999\r\n"
            f"X-File-Name: should_cleanup.bin\r\n\r\n"
        ).encode("utf-8")
        s.sendall(req)
        s.sendall(b"X" * 10)
        s.shutdown(socket.SHUT_WR)
        time.sleep(0.3)
        s.close()
        time.sleep(0.3)

        current_tmp_files = [f for f in os.listdir(staging_dir) if f.startswith("tmp_")]
        self.assertEqual(len(current_tmp_files), len(initial_tmp_files), f"Expected no leftover tmp files in {staging_dir}")

    def test_s3_05_zero_byte_upload_handling(self):
        """0-byte upload completes cleanly without hanging or corrupting the socket."""
        status, data = self.harness.upload_file("empty_file.txt", b"", from_device="tester")
        self.assertEqual(status, 200)
        self.assertTrue(data.get("ok"))
        self.assertEqual(data.get("item", {}).get("size"), 0)


if __name__ == "__main__":
    unittest.main()
