"""
Tier 1 Tests - Feature S2: Offline Queue Reliability
Verifies auto-pull with since_id<=0 delivery, negative since_id normalization,
device target filtering, delivery ACK progression, and 72-hour retention cutoff.
"""

import unittest
from datetime import datetime, timezone, timedelta
from tests.harness.synchub_harness import SyncHubHarness


class TestS2OfflineQueue(unittest.TestCase):
    def setUp(self):
        self.harness = SyncHubHarness()

    def tearDown(self):
        self.harness.close()

    def test_s2_01_since_id_zero_returns_queued_items(self):
        """since_id=0 returns undelivered items within last 72 hours instead of jumping to max ID with empty list."""
        status, up_res = self.harness.upload_file("offline_doc.pdf", b"%PDF-1.4 test content", from_device="device_a", target_device="device_b")
        self.assertEqual(status, 200)

        status, data = self.harness.get_json("/api/hub/auto-pull?device_id=device_b&since_id=0")
        self.assertEqual(status, 200)
        self.assertTrue(data.get("ok"))
        items = data.get("items", [])
        self.assertGreaterEqual(len(items), 1, "Expected queued item to be delivered on since_id=0")
        self.assertEqual(items[0]["filename"], "offline_doc.pdf")

    def test_s2_02_negative_since_id_normalized(self):
        """Negative since_id (e.g. -1, -100) is normalized to 0 and returns pending items."""
        self.harness.upload_file("neg_test.txt", b"Hello Negative Cursor", from_device="dev1", target_device="dev_neg")

        status, data = self.harness.get_json("/api/hub/auto-pull?device_id=dev_neg&since_id=-5")
        self.assertEqual(status, 200)
        self.assertTrue(data.get("ok"))
        items = data.get("items", [])
        self.assertGreaterEqual(len(items), 1)

    def test_s2_03_device_target_filtering(self):
        """Items targeted to device_b are only returned to device_b, and excluded for device_c."""
        self.harness.upload_file("for_b_only.dat", b"Secret for B", from_device="dev_a", target_device="dev_b")

        # Pull as dev_c
        s_c, d_c = self.harness.get_json("/api/hub/auto-pull?device_id=dev_c&since_id=0")
        self.assertEqual(s_c, 200)
        items_c = [i for i in d_c.get("items", []) if i.get("filename") == "for_b_only.dat"]
        self.assertEqual(len(items_c), 0, "dev_c should not receive item targeted to dev_b")

        # Pull as dev_b
        s_b, d_b = self.harness.get_json("/api/hub/auto-pull?device_id=dev_b&since_id=0")
        self.assertEqual(s_b, 200)
        items_b = [i for i in d_b.get("items", []) if i.get("filename") == "for_b_only.dat"]
        self.assertEqual(len(items_b), 1, "dev_b should receive item targeted to dev_b")

    def test_s2_04_delivery_ack_progression(self):
        """Providing ack_id=N records delivery checkpoint; subsequent pull with since_id=0 omits delivered records."""
        self.harness.upload_file("ack_item.bin", b"Data bytes", from_device="dev_a", target_device="dev_ack")

        # First pull
        s1, d1 = self.harness.get_json("/api/hub/auto-pull?device_id=dev_ack&since_id=0")
        self.assertEqual(s1, 200)
        items1 = d1.get("items", [])
        self.assertEqual(len(items1), 1)
        item_id = items1[0]["id"]

        # Send ACK
        s_ack, d_ack = self.harness.get_json(f"/api/hub/auto-pull?device_id=dev_ack&ack_id={item_id}")
        self.assertEqual(s_ack, 200)

        # Subsequent pull with since_id=0 should use saved checkpoint and return 0 items
        s2, d2 = self.harness.get_json("/api/hub/auto-pull?device_id=dev_ack&since_id=0")
        self.assertEqual(s2, 200)
        items2 = [i for i in d2.get("items", []) if i.get("id") == item_id]
        self.assertEqual(len(items2), 0, "Delivered and ACKed item should not be repeated")

    def test_s2_05_seventy_two_hour_retention_cutoff(self):
        """Records older than 72 hours are excluded from auto-pull queue; recent items are included."""
        # 1. Upload recent item via upload_file (creates file and record)
        self.harness.upload_file("fresh_item.txt", b"Fresh content", from_device="dev_a", target_device="dev_retention")

        # 2. Upload older item and backdate its CreateTime in database to 74 hours ago
        self.harness.upload_file("old_expired.txt", b"Expired content", from_device="dev_a", target_device="dev_retention")

        old_time = (datetime.now(timezone.utc) - timedelta(hours=74)).strftime("%Y-%m-%d %H:%M:%S")
        conn = self.harness.get_db_connection()
        try:
            conn.execute("UPDATE HistoryRecords SET CreateTime = ? WHERE Text = 'old_expired.txt';", (old_time,))
            conn.commit()
        finally:
            conn.close()

        status, data = self.harness.get_json("/api/hub/auto-pull?device_id=dev_retention&since_id=0")
        self.assertEqual(status, 200)
        items = data.get("items", [])
        names = [i.get("filename") for i in items]
        self.assertNotIn("old_expired.txt", names, "Item > 72h must be excluded from auto-pull")
        self.assertIn("fresh_item.txt", names, "Item < 72h must be included in auto-pull")


if __name__ == "__main__":
    unittest.main()
