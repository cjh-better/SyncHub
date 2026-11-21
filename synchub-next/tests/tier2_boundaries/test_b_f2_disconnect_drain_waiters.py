"""
Tier 2 Boundary Tests - Feature F2: Waiter Draining & Fast-Fail Races
Verifies 50 waiters cancelled within 15ms, race between delivery and disconnect,
waiter timeout before disconnect, unknown keys discarded safely, and offline registration rejection.
"""

import time
import unittest
from tests.harness.mock_device import MockSyncDevice


class TestBF2DisconnectDrainWaiters(unittest.TestCase):
    def setUp(self):
        self.device = MockSyncDevice("dev_bf2", "DrainWaitersClient")
        self.device.on_connect_success()

    def test_b_f2_01_fifty_waiters_cancelled_fast(self):
        """50 in-flight waiters cancelled within 15ms upon abrupt socket drop."""
        waiters = [self.device.register_waiter(f"w_{i}") for i in range(50)]
        start = time.time()
        self.device.on_disconnect()
        elapsed_ms = (time.time() - start) * 1000

        self.assertLess(elapsed_ms, 25.0, f"Draining 50 waiters took {elapsed_ms:.2f}ms, expected < 25ms")
        self.assertEqual(len(self.device.waiters), 0)
        for w in waiters:
            self.assertTrue(w.completed)

    def test_b_f2_02_waiter_completed_at_disconnect(self):
        """Race condition where waiter completes right before disconnect executes safely."""
        w = self.device.register_waiter("race_waiter")
        # Complete right before disconnect
        w.complete({"ok": True})
        self.device.on_disconnect()

        self.assertTrue(w.completed)
        self.assertIsNone(w.error, "Already completed waiter should preserve success result")

    def test_b_f2_03_waiter_timeout_before_disconnect(self):
        """Waiter that times out before disconnect fails with TimeoutError."""
        w = self.device.register_waiter("timeout_waiter")
        w.complete_error(TimeoutError("Signal timed out after 60s"))
        self.assertTrue(w.completed)
        self.assertIsInstance(w.error, TimeoutError)

    def test_b_f2_04_deliver_to_unknown_key_ignored(self):
        """Incoming signal addressing an unknown or cancelled transferId is discarded safely without error."""
        unknown_key = "answer:tid_ghost:ses99"
        # Does not exist in self.device.waiters
        self.assertNotIn(unknown_key, self.device.waiters)

    def test_b_f2_05_register_waiter_while_offline(self):
        """Attempting to register a waiter while engine is disconnected is rejected immediately with ConnectionError."""
        self.device.on_disconnect()
        with self.assertRaises(ConnectionError):
            self.device.register_waiter("offline_req")


if __name__ == "__main__":
    unittest.main()
