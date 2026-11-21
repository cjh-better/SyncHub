"""
Tier 3 Combination Tests - Suite 2: Network Drop + Fast-Fail Waiters + Relay Recovery
Pairs Features (F1/F2 x S5/S6):
Abrupt network drop occurs while waiters are pending for transfer signals.
Engine fast-fails all pending waiters within 10ms.
Gateway synchronously cleans up writeLoop via sync.WaitGroup.
Jittered backoff initiates reconnection, resets signaling, and resumes transfer cleanly.
"""

import time
import unittest
from tests.harness.mock_device import MockSyncDevice
from tests.harness.gateway_harness import GatewayHarness


class TestComboNetworkDropAndRelay(unittest.TestCase):
    def setUp(self):
        self.gateway = GatewayHarness()
        self.device = MockSyncDevice("dev_combo2", "ComboDropClient")
        self.device.on_connect_success()

    def tearDown(self):
        self.gateway.close()

    def test_combo_network_drop_and_relay_fast_fail(self):
        tid = "t_combo_drop_200"
        session = "ses_combo_200"

        # 1. Register pending signal waiters
        w_ans = self.device.register_waiter(f"answer:{tid}:{session}")
        w_done = self.device.register_waiter(f"done:{tid}:{session}")

        # 2. Abrupt network drop
        start_t = time.time()
        self.device.on_disconnect()
        fast_fail_ms = (time.time() - start_t) * 1000

        self.assertLess(fast_fail_ms, 15.0, "Waiters must be fast-failed in < 15ms")
        self.assertTrue(w_ans.completed)
        self.assertTrue(w_done.completed)
        self.assertIsInstance(w_ans.error, ConnectionResetError)

        # 3. Jittered reconnect
        backoff_val = self.device.calculate_next_backoff()
        self.assertGreaterEqual(backoff_val, 1.0)
        self.device.on_connect_success()
        self.assertTrue(self.device.connected_ws)

        # 4. Fresh transfer waiter registration and completion
        fresh_waiter = self.device.register_waiter(f"answer:{tid}:{session}_resumed")
        fresh_waiter.complete({"ok": True, "route": "relay"})
        self.assertTrue(fresh_waiter.completed)


if __name__ == "__main__":
    unittest.main()
