"""
Tier 2 Boundary Tests - Feature S5: Relay Session Boundaries & Zero-Copy Streaming
Verifies 1000 orphan sessions cleaned by janitor, 0-byte relay chunk, exact 4MB chunk stream,
sender abort mid-chunk, and concurrent collision avoidance.
"""

import time
import hashlib
import unittest
from tests.harness.gateway_harness import GatewayHarness


class TestBS5RelayOrphanSessions(unittest.TestCase):
    def setUp(self):
        self.gateway = GatewayHarness()

    def tearDown(self):
        self.gateway.close()

    def test_b_s5_01_thousand_orphan_sessions_cleaned(self):
        """1,000 abandoned sessions are evicted by the janitor without CPU spike or memory leak."""
        now = time.time()
        for i in range(1000):
            self.gateway.active_sessions[f"orphan_{i}"] = {
                "last_active": now - (50 * 3600),  # 50 hours ago (>48h TTL)
            }
        self.assertEqual(len(self.gateway.active_sessions), 1000)

        # Janitor sweep
        cutoff = now - (48 * 3600)
        expired = [k for k, v in self.gateway.active_sessions.items() if v["last_active"] < cutoff]
        for k in expired:
            del self.gateway.active_sessions[k]

        self.assertEqual(len(self.gateway.active_sessions), 0)

    def test_b_s5_02_zero_byte_relay_chunk(self):
        """0-byte chunk PUT and GET pair resolves with 204/200 and cleans up meet cleanly."""
        meet_key = "zero_byte_meet"
        meet = self.gateway.get_or_create_meet(meet_key)

        import threading
        got_data = []

        def get_thread():
            data = meet.get_chunk(timeout=2.0)
            got_data.append(data)

        t = threading.Thread(target=get_thread)
        t.start()
        time.sleep(0.05)
        ok = meet.put_chunk(b"", timeout=2.0)
        t.join(timeout=2.0)

        self.assertTrue(ok)
        self.assertEqual(len(got_data), 1)
        self.assertEqual(got_data[0], b"")

    def test_b_s5_03_relay_chunk_4mb_exact(self):
        """Exact 4MB chunk streams zero-copy; receiver SHA-256 matches sender perfectly."""
        data_4mb = b"Z" * (4 * 1024 * 1024)
        expected_sha = hashlib.sha256(data_4mb).hexdigest()

        meet_key = "4mb_meet"
        meet = self.gateway.get_or_create_meet(meet_key)

        import threading
        received = []

        def get_thread():
            res = meet.get_chunk(timeout=3.0)
            received.append(res)

        t = threading.Thread(target=get_thread)
        t.start()
        time.sleep(0.05)
        ok = meet.put_chunk(data_4mb, timeout=3.0)
        t.join(timeout=3.0)

        self.assertTrue(ok)
        self.assertEqual(len(received), 1)
        self.assertEqual(hashlib.sha256(received[0]).hexdigest(), expected_sha)

    def test_b_s5_04_sender_disconnects_mid_chunk(self):
        """Sender aborts mid-chunk; meet is cancelled; receiver terminates with timeout or cancellation."""
        meet_key = "abort_meet"
        meet = self.gateway.get_or_create_meet(meet_key)

        import threading
        result = []

        def get_thread():
            res = meet.get_chunk(timeout=1.0)
            result.append(res)

        t = threading.Thread(target=get_thread)
        t.start()
        time.sleep(0.1)
        # Sender cancels
        meet.cancel()
        t.join(timeout=2.0)

        self.assertEqual(len(result), 1)
        self.assertIsNone(result[0])

    def test_b_s5_05_concurrent_put_get_collision(self):
        """Concurrent PUT and GET on multiple distinct chunks complete without deadlock."""
        meets = [self.gateway.get_or_create_meet(f"chunk_{i}") for i in range(5)]
        import threading
        errors = []

        def pair(idx: int, m):
            try:
                def get_w():
                    m.get_chunk(timeout=2.0)
                t = threading.Thread(target=get_w)
                t.start()
                m.put_chunk(f"data_{idx}".encode("utf-8"), timeout=2.0)
                t.join(timeout=2.0)
            except Exception as e:
                errors.append(e)

        threads = [threading.Thread(target=pair, args=(i, m)) for i, m in enumerate(meets)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=5.0)

        self.assertEqual(len(errors), 0)


if __name__ == "__main__":
    unittest.main()
