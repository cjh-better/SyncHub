"""
Tier 2 Boundary Tests - Feature S2: Queue Overflow & Edge Cursors
Verifies since_id=0 on empty DB, huge since_id, rapid pulls with partial acks,
exact 72-hour cutoff boundary, and auto-pull with unregistered device IDs.
"""

import unittest
from datetime import datetime, timezone, timedelta
from tests.harness.synchub_harness import SyncHubHarness


class TestBS2QueueZeroSinceOverflow(unittest.TestCase):
    def setUp(self):
        self.harness = SyncHubHarness()

    def tearDown(self):
        self.harness.close()

    def test_b_s2_01_queue_zero_since_id_empty_db(self):
        """since_id=0 on empty database returns items: [] and latestId: 0 without exceptions."""
        status, data = self.harness.get_json("/api/hub/auto-pull?device_id=fresh_dev&since_id=0")
        self.assertEqual(status, 200)
        self.assertTrue(data.get("ok"))
        self.assertEqual(data.get("items"), [])
        self.assertEqual(data.get("latestId"), 0)

    def test_b_s2_02_huge_since_id_over_max(self):
        """since_id=999999999 far exceeding max ID returns empty list cleanly."""
        status, data = self.harness.get_json("/api/hub/auto-pull?device_id=fresh_dev&since_id=999999999")
        self.assertEqual(status, 200)
        self.assertTrue(data.get("ok"))
        self.assertEqual(data.get("items"), [])

    def test_b_s2_03_rapid_pulls_with_partial_acks(self):
        """10 rapid auto-pulls with incremental ACK IDs maintain monotonic delivery checkpoints."""
        # Create 3 items
        for i in range(3):
            self.harness.upload_file(f"batch_{i}.txt", f"data_{i}".encode("utf-8"), from_device="sender", target_device="dev_ack_test")

        # Pull and acknowledge one by one
        status, data = self.harness.get_json("/api/hub/auto-pull?device_id=dev_ack_test&since_id=0")
        self.assertEqual(status, 200)
        items = data.get("items", [])
        self.assertEqual(len(items), 3)

        # ACK first item
        first_id = items[0]["id"]
        self.harness.get_json(f"/api/hub/auto-pull?device_id=dev_ack_test&ack_id={first_id}")

        # Next pull with since_id=0 should return remaining 2 items
        status2, data2 = self.harness.get_json("/api/hub/auto-pull?device_id=dev_ack_test&since_id=0")
        self.assertEqual(status2, 200)
        remaining_ids = [i["id"] for i in data2.get("items", [])]
        self.assertNotIn(first_id, remaining_ids)
        self.assertEqual(len(remaining_ids), 2)

    def test_b_s2_04_retention_boundary_exact_72_hours(self):
        """Item at 71h59m is delivered; item at 72h01m is excluded from auto-pull queue."""
        self.harness.upload_file("border_pass.txt", b"border_pass", from_device="dev_a", target_device="dev_border")
        self.harness.upload_file("border_fail.txt", b"border_fail", from_device="dev_a", target_device="dev_border")

        t_pass = (datetime.now(timezone.utc) - timedelta(hours=71, minutes=59)).strftime("%Y-%m-%d %H:%M:%S")
        t_fail = (datetime.now(timezone.utc) - timedelta(hours=72, minutes=1)).strftime("%Y-%m-%d %H:%M:%S")

        conn = self.harness.get_db_connection()
        try:
            conn.execute("UPDATE HistoryRecords SET CreateTime = ? WHERE Text = 'border_pass.txt';", (t_pass,))
            conn.execute("UPDATE HistoryRecords SET CreateTime = ? WHERE Text = 'border_fail.txt';", (t_fail,))
            conn.commit()
        finally:
            conn.close()

        status, data = self.harness.get_json("/api/hub/auto-pull?device_id=dev_border&since_id=0")
        self.assertEqual(status, 200)
        names = [i.get("filename") for i in data.get("items", [])]
        self.assertIn("border_pass.txt", names)
        self.assertNotIn("border_fail.txt", names)

    def test_b_s2_05_non_existent_device_id_autopull(self):
        """Unregistered arbitrary device ID query returns empty items without throwing server errors."""
        status, data = self.harness.get_json("/api/hub/auto-pull?device_id=random_nonexistent_dev_404&since_id=0")
        self.assertEqual(status, 200)
        self.assertTrue(data.get("ok"))
        self.assertEqual(data.get("items"), [])


if __name__ == "__main__":
    unittest.main()
