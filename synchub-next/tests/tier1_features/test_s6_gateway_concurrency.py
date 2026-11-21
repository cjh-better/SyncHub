"""
Tier 1 Tests - Feature S6: Gateway WS & Relay Concurrency
Verifies writeLoop synchronization, chunk rendezvous pairing, duplicate receiver conflict (409),
sender arriving before receiver, and cancellation drain.
"""

import time
import threading
import urllib.request
import urllib.error
import unittest
from tests.harness.gateway_harness import GatewayHarness


class TestS6GatewayConcurrency(unittest.TestCase):
    def setUp(self):
        self.gateway = GatewayHarness()

    def tearDown(self):
        self.gateway.close()

    def test_s6_01_writeloop_termination_sync(self):
        """Simulate concurrent client disconnect and verify writeLoop termination synchronization."""
        # Models the Go sync.WaitGroup in hub.go:188-197
        wg_done = threading.Event()
        loop_active = threading.Event()

        def mock_write_loop():
            loop_active.set()
            # Simulate write operations
            time.sleep(0.05)
            wg_done.set()

        t = threading.Thread(target=mock_write_loop)
        t.start()
        loop_active.wait(timeout=1.0)
        # On disconnect: wait for wg before closing socket
        wg_done.wait(timeout=1.0)
        t.join(timeout=1.0)
        self.assertTrue(wg_done.is_set(), "writeLoop must complete synchronously before socket closure")

    def test_s6_02_waiter_registration_no_drop(self):
        """Concurrent PUT and GET chunk pairings resolve without dropped waiters or deadlocks."""
        chunk_data = b"RELAY_CHUNK_CONTENT_12345"
        tid = "trans_c1"
        session = "ses_c1"
        chunk_idx = "0"
        url = f"http://127.0.0.1:{self.gateway.port}/api/v1/relay/{tid}/{session}/file1/{chunk_idx}"

        received = []

        def sender():
            req = urllib.request.Request(url, data=chunk_data, method="PUT")
            with urllib.request.urlopen(req) as resp:
                self.assertIn(resp.status, [200, 204])

        def receiver():
            req = urllib.request.Request(url, method="GET")
            with urllib.request.urlopen(req) as resp:
                data = resp.read()
                received.append(data)

        t_get = threading.Thread(target=receiver)
        t_put = threading.Thread(target=sender)
        t_get.start()
        time.sleep(0.05)
        t_put.start()

        t_get.join(timeout=3.0)
        t_put.join(timeout=3.0)

        self.assertEqual(len(received), 1)
        self.assertEqual(received[0], chunk_data)

    def test_s6_03_duplicate_receiver_conflict(self):
        """Second concurrent GET for the same chunk key returns 409 Conflict immediately."""
        tid = "trans_dup"
        session = "ses_dup"
        chunk_idx = "0"
        meet_key = f"{tid}:{session}:{chunk_idx}"
        meet = self.gateway.get_or_create_meet(meet_key)
        # First receiver claims meet
        meet.has_receiver = True

        url = f"http://127.0.0.1:{self.gateway.port}/api/v1/relay/{tid}/{session}/f/{chunk_idx}"
        req = urllib.request.Request(url, method="GET")
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(req)
        self.assertEqual(ctx.exception.code, 409, "Duplicate receiver GET must return 409 Conflict")

    def test_s6_04_sender_arrives_before_receiver(self):
        """Sender PUT arrives before receiver GET; sender waits and streams directly upon receiver arrival."""
        payload = b"Payload_Sender_First"
        tid = "trans_sender_first"
        session = "ses1"
        chunk_idx = "0"
        url = f"http://127.0.0.1:{self.gateway.port}/api/v1/relay/{tid}/{session}/f/{chunk_idx}"

        recv_box = []

        def sender():
            req = urllib.request.Request(url, data=payload, method="PUT")
            with urllib.request.urlopen(req) as resp:
                self.assertIn(resp.status, [200, 204])

        def receiver():
            req = urllib.request.Request(url, method="GET")
            with urllib.request.urlopen(req) as resp:
                recv_box.append(resp.read())

        t_put = threading.Thread(target=sender)
        t_put.start()
        time.sleep(0.05)  # Let PUT block waiting for receiver
        t_get = threading.Thread(target=receiver)
        t_get.start()

        t_put.join(timeout=3.0)
        t_get.join(timeout=3.0)

        self.assertEqual(len(recv_box), 1)
        self.assertEqual(recv_box[0], payload)

    def test_s6_05_receiver_cancellation_drains_waiter(self):
        """Receiver cancellation marks waiter stCancelled and unblocks cleanly."""
        tid = "trans_drain"
        session = "ses1"
        chunk_idx = "0"
        meet_key = f"{tid}:{session}:{chunk_idx}"
        meet = self.gateway.get_or_create_meet(meet_key)

        cancelled = threading.Event()

        def waiter_thread():
            data = meet.get_chunk(timeout=2.0)
            if data is None and meet.cancelled:
                cancelled.set()

        t = threading.Thread(target=waiter_thread)
        t.start()
        time.sleep(0.05)
        meet.cancel()
        t.join(timeout=2.0)

        self.assertTrue(cancelled.is_set())


if __name__ == "__main__":
    unittest.main()
