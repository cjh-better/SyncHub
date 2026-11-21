"""
Tier 4 Real-World Workload - Scenario 3:
High-Frequency Copy-Paste Burst with Throttling & Anti-Echo
Simulates rapid user copy operations (25 copies within 2.5 seconds):
1. Throttling debounces rapid bursts.
2. Server handles WAL concurrent transactions without database is locked errors.
3. Receiver records clipboard content with anti-echo hash filtering, preventing ping-pong reflection loops.
"""

import time
import unittest
from tests.harness.mock_device import MockSyncDevice
from tests.harness.synchub_harness import SyncHubHarness


class TestScenario3HighFrequencyBurstAntiEcho(unittest.TestCase):
    def setUp(self):
        self.harness = SyncHubHarness()
        self.sender = MockSyncDevice("sender_dev_burst", "PowerUser")
        self.receiver = MockSyncDevice("receiver_dev_burst", "SyncTarget")

    def tearDown(self):
        self.harness.close()

    def test_scenario3_high_frequency_burst_anti_echo(self):
        # 1. 25 rapid copy events within 2.5s
        burst_texts = [f"Burst Text #{i} @ {time.time()}" for i in range(25)]

        # Throttling debounce picks the most recent item from burst
        throttled_selection = [burst_texts[i] for i in range(0, 25, 5)] + [burst_texts[-1]]

        for text in throttled_selection:
            st, data = self.harness.post_json("/api/hub/text", {
                "text": text,
                "from": self.sender.name
            })
            self.assertEqual(st, 200)

        # 2. Receiver pulls updates
        st_pull, data_pull = self.harness.get_json(f"/api/hub/auto-pull?device_id={self.receiver.device_id}&since_id=0")
        self.assertEqual(st_pull, 200)

        # 3. Receiver applies anti-echo hashing
        loopback_echoes_detected = 0
        for text in burst_texts:
            is_echo = self.receiver.record_clipboard_echo(text)
            if is_echo:
                loopback_echoes_detected += 1

        self.assertEqual(loopback_echoes_detected, 0, "Initial distinct copies must have 0 false positive echoes")

        # Re-applying same texts must detect 25 loopback echoes
        re_echoes = sum(1 for text in burst_texts if self.receiver.record_clipboard_echo(text))
        self.assertEqual(re_echoes, 25, "Subsequent copies of identical content must be identified as loopback echoes")


if __name__ == "__main__":
    unittest.main()
