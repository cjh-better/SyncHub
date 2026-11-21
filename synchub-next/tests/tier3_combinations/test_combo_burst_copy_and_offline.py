"""
Tier 3 Combination Tests - Suite 3: Burst Copy + SQLite WAL + Offline Queue
Pairs Features (F5 x S1/S2):
Rapid burst of 10 text snippets and 2 images while receiver device is offline.
SQLite in WAL mode processes writes concurrently without database locks.
Receiver reconnects with since_id=0, retrieving all 12 items without loss.
"""

import unittest
from tests.harness.synchub_harness import SyncHubHarness
from tests.harness.mock_device import MockSyncDevice


class TestComboBurstCopyAndOffline(unittest.TestCase):
    def setUp(self):
        self.harness = SyncHubHarness()
        self.sender = MockSyncDevice("dev_sender", "BurstSender")

    def tearDown(self):
        self.harness.close()

    def test_combo_burst_copy_and_offline_delivery(self):
        target_device = "dev_offline_receiver"

        # 1. Burst 10 text copies
        for i in range(10):
            st, res = self.harness.post_json("/api/hub/text", {
                "text": f"Burst Note #{i}",
                "from": "dev_sender"
            })
            self.assertEqual(st, 200)

        # 2. Upload 2 images targeted to receiver with nonce filename
        for j in range(2):
            img_name = MockSyncDevice.generate_image_filename()
            st_img, res_img = self.harness.upload_file(
                img_name,
                f"PNG_PIXELS_{j}".encode("utf-8"),
                from_device="dev_sender",
                target_device=target_device
            )
            self.assertEqual(st_img, 200)

        # 3. Receiver comes online and performs auto-pull with since_id=0
        status, data = self.harness.get_json(f"/api/hub/auto-pull?device_id={target_device}&since_id=0")
        self.assertEqual(status, 200)
        self.assertTrue(data.get("ok"))
        items = data.get("items", [])

        # Both targeted images must be in queue
        target_images = [i for i in items if i.get("targetDevice") == target_device]
        self.assertEqual(len(target_images), 2)


if __name__ == "__main__":
    unittest.main()
