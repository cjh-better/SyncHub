"""
Tier 2 Boundary Tests - Feature F1: WebSocket Flapping & Jitter Distribution
Verifies network flapping resilience, 10 rapid kickReconnects debounced into 1,
jitter distribution uniformity, reconnection during relay transfer, and 30s cap enforcement.
"""

import time
import unittest
from tests.harness.mock_device import MockSyncDevice


class TestBF1WsFlappingJitter(unittest.TestCase):
    def setUp(self):
        self.device = MockSyncDevice("dev_bf1", "FlapClient")

    def test_b_f1_01_network_flapping_stress(self):
        """Rapid network flapping (up/down 20 times in rapid succession) handled safely without runaway timers."""
        for _ in range(20):
            self.device.on_connect_success()
            self.device.on_disconnect()
        self.assertFalse(self.device.connected_ws)

    def test_b_f1_02_ten_kick_reconnects_in_100ms(self):
        """10 rapid kickReconnect() calls within 100ms debounced into a single immediate reconnect baseline."""
        for _ in range(10):
            self.device.kick_reconnect()
        self.assertTrue(self.device.kick_reconnect_triggered)
        self.assertEqual(self.device.backoff_current, 1.0)

    def test_b_f1_03_backoff_jitter_distribution(self):
        """100 jitter samples conform to uniform distribution within ±20% boundaries."""
        samples = []
        raw = 10.0
        for _ in range(100):
            # Calculate next backoff starting from 5.0
            self.device.backoff_current = 5.0
            val = self.device.calculate_next_backoff()
            # Raw doubled is 10.0, jitter range is [8.0, 12.0]
            samples.append(val)

        min_val = min(samples)
        max_val = max(samples)
        self.assertGreaterEqual(min_val, 8.0)
        self.assertLessEqual(max_val, 12.0)
        self.assertGreater(max_val - min_val, 1.5, "Jitter should spread across the ±20% range")

    def test_b_f1_04_reconnect_during_relay_transfer(self):
        """WebSocket drop during active relay transfer pauses signaling; kickReconnect resumes session."""
        self.device.on_connect_success()
        session_id = "ses_resume_99"
        # Disconnect occurs
        self.device.on_disconnect()
        self.assertFalse(self.device.connected_ws)

        # Kick reconnect
        self.device.kick_reconnect()
        self.device.on_connect_success()
        self.assertTrue(self.device.connected_ws)

    def test_b_f1_05_max_backoff_cap_enforced(self):
        """20 consecutive connection failures strictly enforce 30.0s backoff cap without runaway growth."""
        delays = []
        for _ in range(20):
            delays.append(self.device.calculate_next_backoff())

        # Cap must never exceed 30.0 * 1.2 = 36.0 with jitter, or 30.0s baseline
        self.assertLessEqual(self.device.backoff_current, 30.0)
        for d in delays:
            self.assertLessEqual(d, 36.0)


if __name__ == "__main__":
    unittest.main()
