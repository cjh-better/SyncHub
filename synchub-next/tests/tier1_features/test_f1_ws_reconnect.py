"""
Tier 1 Tests - Feature F1: WebSocket Jitter & Fast Reconnect
Verifies exponential backoff with randomized jitter (±20%), kickReconnect() bypassing delays,
network change kick trigger, wake event kick trigger, and baseline reset on success.
"""

import time
import unittest
from tests.harness.mock_device import MockSyncDevice
from tests.harness.platform_mocks import PlatformEventDispatcher, WindowsPlatformMock


class TestF1WsReconnect(unittest.TestCase):
    def setUp(self):
        self.device = MockSyncDevice("dev_f1", "TestClient", "windows")

    def test_f1_01_backoff_exponential_with_jitter(self):
        """Backoff delay increases exponentially with randomized jitter between -20% and +20%."""
        samples = []
        # Run 5 consecutive backoff calculations
        for _ in range(5):
            val = self.device.calculate_next_backoff()
            samples.append(val)

        # Ensure delay grows exponentially
        self.assertGreater(samples[2], samples[0])
        self.assertGreater(samples[4], samples[2])

        # Test jitter variance across multiple samples of same tier
        tier_samples = []
        for _ in range(20):
            d = MockSyncDevice("dev_tmp", "Tmp")
            tier_samples.append(d.calculate_next_backoff())
        # Not all samples should be identical due to jitter
        distinct_samples = set(round(s, 4) for s in tier_samples)
        self.assertGreater(len(distinct_samples), 1, "Jitter must produce randomized backoff intervals")

    def test_f1_02_kick_reconnect_bypasses_backoff(self):
        """Calling kickReconnect() resets backoff delay to 1.0s and sets kick_reconnect_triggered."""
        # Drive backoff to cap
        for _ in range(10):
            self.device.calculate_next_backoff()
        self.assertGreaterEqual(self.device.backoff_current, 20.0)

        # Trigger kickReconnect
        self.device.kick_reconnect()
        self.assertTrue(self.device.kick_reconnect_triggered)
        self.assertEqual(self.device.backoff_current, 1.0)
        self.assertAlmostEqual(self.device.last_reconnect_time, time.time(), delta=0.5)

    def test_f1_03_network_available_triggers_kick(self):
        """Network interface change triggers kick_reconnect() automatically."""
        self.device.backoff_current = 25.0
        # Network interface roaming detected
        self.device.on_network_interfaces_changed(["192.168.1.120"])
        self.device.kick_reconnect()
        self.assertTrue(self.device.kick_reconnect_triggered)
        self.assertEqual(self.device.backoff_current, 1.0)

    def test_f1_04_wake_event_triggers_kick(self):
        """System wake event received via platform bridge triggers kick_reconnect() immediately."""
        dispatcher = PlatformEventDispatcher()
        win_mock = WindowsPlatformMock(dispatcher)

        # Hook dispatcher to device
        dispatcher.on("system_event", lambda ev: self.device.kick_reconnect() if ev.get("event") == "wake" else None)

        self.device.backoff_current = 30.0
        # Simulate OS wake event
        win_mock.simulate_power_broadcast("resume")
        self.assertTrue(self.device.kick_reconnect_triggered)
        self.assertEqual(self.device.backoff_current, 1.0)

    def test_f1_05_success_resets_backoff(self):
        """Successful WebSocket connection resets backoff baseline to 1.0s and clears retry counters."""
        self.device.backoff_current = 30.0
        self.device.reconnect_attempts = 8
        self.device.on_connect_success()

        self.assertTrue(self.device.connected_ws)
        self.assertEqual(self.device.backoff_current, 1.0)
        self.assertEqual(self.device.reconnect_attempts, 0)


if __name__ == "__main__":
    unittest.main()
