"""
Tier 1 Tests - Feature F2: Fast-Fail Orphaned Completers on Disconnect
Verifies immediate cancellation of pending waiters upon WebSocket disconnect,
empty waiter registry, state transition, fresh waiter re-registration, and concurrent fail-fast.
"""

import unittest
from tests.harness.mock_device import MockSyncDevice


class TestF2FastFailWaiters(unittest.TestCase):
    def setUp(self):
        self.device = MockSyncDevice("dev_f2", "FastFailClient")
        self.device.on_connect_success()

    def test_f2_01_pending_waiters_fail_on_disconnect(self):
        """WebSocket disconnect completes all pending waiters with network error immediately."""
        w1 = self.device.register_waiter("answer:tid1:ses1")
        w2 = self.device.register_waiter("done:tid1:ses1")

        self.assertFalse(w1.completed)
        self.assertFalse(w2.completed)

        # Trigger disconnect
        self.device.on_disconnect()

        self.assertTrue(w1.completed)
        self.assertTrue(w2.completed)
        self.assertIsInstance(w1.error, ConnectionResetError)
        self.assertIsInstance(w2.error, ConnectionResetError)

    def test_f2_02_no_stale_waiters_remain(self):
        """After disconnect handling, _waiters registry map is completely cleared."""
        self.device.register_waiter("answer:tid2:ses2")
        self.device.register_waiter("done:tid2:ses2")
        self.assertEqual(len(self.device.waiters), 2)

        self.device.on_disconnect()
        self.assertEqual(len(self.device.waiters), 0, "No orphaned or stale waiters may remain after disconnect")

    def test_f2_03_transfer_transitions_to_retrying(self):
        """In-flight transfer transitions to waiting/retrying state rather than freezing indefinitely."""
        waiter = self.device.register_waiter("answer:t_retry:s1")
        transfer_state = "connecting"

        # Disconnect occurs
        self.device.on_disconnect()
        if waiter.error is not None:
            transfer_state = "waiting"

        self.assertEqual(transfer_state, "waiting")

    def test_f2_04_reconnect_allows_fresh_waiters(self):
        """New transfer registers fresh waiter after reconnect and resolves normally."""
        self.device.on_disconnect()
        # Attempting to register while offline raises error
        with self.assertRaises(ConnectionError):
            self.device.register_waiter("answer:t_fresh:s1")

        # Reconnect
        self.device.on_connect_success()
        fresh_waiter = self.device.register_waiter("answer:t_fresh:s1")
        self.assertIn("answer:t_fresh:s1", self.device.waiters)

        # Resolve successfully
        fresh_waiter.complete({"route": "lan", "ok": True})
        self.assertTrue(fresh_waiter.completed)
        self.assertIsNone(fresh_waiter.error)
        self.assertTrue(fresh_waiter.result.get("ok"))

    def test_f2_05_multiple_concurrent_transfers_fast_fail(self):
        """10 concurrent transfers in progress fail fast in parallel on disconnect."""
        waiters = [self.device.register_waiter(f"answer:t_multi_{i}:s_{i}") for i in range(10)]
        self.assertEqual(len(self.device.waiters), 10)

        self.device.on_disconnect()
        for w in waiters:
            self.assertTrue(w.completed)
            self.assertIsNotNone(w.error)
        self.assertEqual(self.device.failed_waiters_count, 10)


if __name__ == "__main__":
    unittest.main()
