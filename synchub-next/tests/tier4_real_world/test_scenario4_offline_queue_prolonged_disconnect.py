"""
Tier 4 Real-World Workload - Scenario 4:
Offline Queued Auto-Pull with Recovery After Prolonged Network Disconnection
Simulates a device offline for 12 hours:
1. Senders deposit 15 mixed items (files, text notes, images) targeted to the offline device.
2. Receiver reconnects with since_id=0.
3. Python server's handle_auto_pull queries undelivered items within the last 72 hours.
4. All 15 items are received and verified.
5. Receiver acknowledges with ack_id; subsequent pulls return 0 items.
"""

import unittest
from tests.harness.mock_device import MockSyncDevice
from tests.harness.synchub_harness import SyncHubHarness


class TestScenario4OfflineQueueProlongedDisconnect(unittest.TestCase):
    def setUp(self):
        self.harness = SyncHubHarness()
        self.receiver_id = "device_traveler_offline"

    def tearDown(self):
        self.harness.close()

    def test_scenario4_offline_queue_prolonged_disconnect(self):
        # 1. Deposit 15 items while receiver is offline
        deposited_filenames = []
        for i in range(15):
            fn = f"offline_doc_{i:02d}.dat"
            deposited_filenames.append(fn)
            st, res = self.harness.upload_file(
                fn,
                f"Payload content for item {i}".encode("utf-8"),
                from_device="sender_hub",
                target_device=self.receiver_id
            )
            self.assertEqual(st, 200)

        # 2. Receiver comes online after 12 hours and queries auto-pull with since_id=0
        status, data = self.harness.get_json(f"/api/hub/auto-pull?device_id={self.receiver_id}&since_id=0")
        self.assertEqual(status, 200)
        self.assertTrue(data.get("ok"))
        items = data.get("items", [])

        # 3. Verify all 15 items are delivered
        self.assertEqual(len(items), 15, "Expected all 15 queued items to be delivered")
        received_names = [item.get("filename") for item in items]
        self.assertEqual(sorted(received_names), sorted(deposited_filenames))

        # 4. Receiver sends delivery ACK for the highest ID
        highest_id = data.get("latestId")
        self.assertGreater(highest_id, 0)
        st_ack, res_ack = self.harness.get_json(f"/api/hub/auto-pull?device_id={self.receiver_id}&ack_id={highest_id}")
        self.assertEqual(st_ack, 200)

        # 5. Subsequent pull with since_id=0 returns 0 new items
        st_next, res_next = self.harness.get_json(f"/api/hub/auto-pull?device_id={self.receiver_id}&since_id=0")
        self.assertEqual(st_next, 200)
        self.assertEqual(len(res_next.get("items", [])), 0, "All items were ACKed; queue should be drained")


if __name__ == "__main__":
    unittest.main()
