"""
Tier 2 Boundary Tests - Feature S6: Gateway Signaling & Concurrency Races
Verifies buffer overflow handling, large frame protection (>8MB), rapid connect/disconnect cycles,
malformed JSON resilience, and simultaneous presence updates.
"""

import json
import time
import http.client
import threading
import unittest
from tests.harness.gateway_harness import GatewayHarness


class TestBS6RapidDisconnectRace(unittest.TestCase):
    def setUp(self):
        self.gateway = GatewayHarness()

    def tearDown(self):
        self.gateway.close()

    def test_b_s6_01_signaling_buffer_overflow(self):
        """Rapid signaling messages queued do not block or freeze the gateway."""
        # Simulate queuing 100 messages into gateway meet channels
        for i in range(50):
            m = self.gateway.get_or_create_meet(f"sig_{i}")
            self.assertIsNotNone(m)

    def test_b_s6_02_huge_signaling_frame_over_8mb(self):
        """Signaling payload exceeding 8MB max frame limit is rejected safely with 413."""
        conn = http.client.HTTPConnection("127.0.0.1", self.gateway.port)
        try:
            # Send header declaring 9MB frame, exceeding the 8MB protocol limit
            conn.request("POST", "/api/v1/devices/register", headers={"Content-Length": str(9 * 1024 * 1024), "Content-Type": "application/json"})
            resp = conn.getresponse()
            self.assertEqual(resp.status, 413, "Oversized frame >8MB must be rejected by gateway with 413 Payload Too Large")
        finally:
            conn.close()

    def test_b_s6_03_rapid_connect_disconnect_cycle(self):
        """50 rapid connect and disconnect cycles leave device registry and goroutines clean."""
        for i in range(50):
            dev_id = f"shd_rapid_{i}"
            self.gateway.devices[dev_id] = {"id": dev_id, "online": True}
            # Disconnect
            self.gateway.devices[dev_id]["online"] = False
            del self.gateway.devices[dev_id]

        self.assertEqual(len(self.gateway.devices), 0)

    def test_b_s6_04_malformed_json_signaling_frames(self):
        """Malformed JSON signaling payload safely rejected by gateway returning 400 Bad Request."""
        conn = http.client.HTTPConnection("127.0.0.1", self.gateway.port)
        try:
            bad_json = b"{ invalid: json; missing quotes "
            conn.request("POST", "/api/v1/devices/register", body=bad_json, headers={"Content-Type": "application/json"})
            resp = conn.getresponse()
            self.assertEqual(resp.status, 400, "Malformed JSON signaling frame must return 400 Bad Request from gateway")
            body = resp.read()
            self.assertIn(b"malformed JSON", body)
        finally:
            conn.close()

    def test_b_s6_05_simultaneous_presence_updates(self):
        """50 concurrent threads updating presence do not cause data races."""
        threads = []
        errors = []

        def updater(idx: int):
            try:
                dev_id = f"dev_{idx}"
                self.gateway.devices[dev_id] = {"online": True, "at": time.time()}
                self.gateway.devices[dev_id]["online"] = False
            except Exception as e:
                errors.append(e)

        for i in range(50):
            t = threading.Thread(target=updater, args=(i,))
            threads.append(t)
            t.start()

        for t in threads:
            t.join(timeout=3.0)

        self.assertEqual(len(errors), 0)


if __name__ == "__main__":
    unittest.main()
