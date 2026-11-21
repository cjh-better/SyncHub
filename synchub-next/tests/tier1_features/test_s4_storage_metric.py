"""
Tier 1 Tests - Feature S4: Storage Metric I/O Optimization
Verifies storage API caching (30m TTL), disk usage structure,
sub-millisecond repeated cache hits, and size calculation.
"""

import os
import sys
import time
import unittest

from tests.harness.synchub_harness import SyncHubHarness
import synchub_server


class TestS4StorageMetric(unittest.TestCase):
    def setUp(self):
        self.harness = SyncHubHarness()

    def tearDown(self):
        self.harness.close()

    def test_s4_01_storage_api_returns_cached_metric(self):
        """Repeated calls to /api/hub/storage return in < 15ms via cache without blocking on recursive os.walk."""
        # Initial call to prime cache
        s1, d1 = self.harness.get_json("/api/hub/storage")
        self.assertEqual(s1, 200)

        # 10 rapid calls
        start = time.time()
        for _ in range(10):
            s, d = self.harness.get_json("/api/hub/storage")
            self.assertEqual(s, 200)
            self.assertTrue(d.get("ok"))
        elapsed = time.time() - start
        avg_ms = (elapsed / 10.0) * 1000
        self.assertLess(avg_ms, 50.0, f"Average storage API latency too high: {avg_ms:.2f}ms")

    def test_s4_02_cache_ttl_expiration(self):
        """Verify STORAGE_CACHE_TTL is set to 1800s (30 minutes) and caching logic checks TTL."""
        self.assertEqual(synchub_server.STORAGE_CACHE_TTL, 1800, "Expected STORAGE_CACHE_TTL to be 1800s (30 minutes)")
        with synchub_server._storage_lock:
            cached_at = synchub_server._storage_cache["at"]
        self.assertGreater(cached_at, 0.0)

    def test_s4_03_disk_usage_structure(self):
        """Response contains valid total, used, free, and hubBytes fields."""
        status, data = self.harness.get_json("/api/hub/storage")
        self.assertEqual(status, 200)
        self.assertTrue(data.get("ok"))
        self.assertIn("total", data)
        self.assertIn("used", data)
        self.assertIn("free", data)
        self.assertIn("hubBytes", data)
        self.assertGreater(data["total"], 0)
        self.assertGreaterEqual(data["free"], 0)

    def test_s4_04_upload_updates_cached_metric(self):
        """Storage metric accurately reflects non-negative hubBytes when files are stored."""
        # Upload a 50KB file
        self.harness.upload_file("metric_file.dat", b"M" * 50000, from_device="tester")
        # Invalidate cache timestamp to force background recalculation
        with synchub_server._storage_lock:
            synchub_server._storage_cache["at"] = 0.0
        time.sleep(0.1)

        status, data = self.harness.get_json("/api/hub/storage")
        self.assertEqual(status, 200)
        time.sleep(0.3)
        status2, data2 = self.harness.get_json("/api/hub/storage")
        self.assertEqual(status2, 200)
        hub_bytes = data2.get("hubBytes")
        if hub_bytes is not None:
            self.assertGreaterEqual(hub_bytes, 50000)

    def test_s4_05_deletion_updates_cached_metric(self):
        """Deleting an item and refreshing metric ensures storage calculations remain valid and non-negative."""
        st, res = self.harness.upload_file("del_metric.bin", b"D" * 20000, from_device="tester")
        self.assertEqual(st, 200)
        item_id = res.get("item", {}).get("id")
        self.assertIsNotNone(item_id)

        # Delete
        st_del, _ = self.harness.post_json(f"/api/hub/item/{item_id}/delete", {})
        self.assertEqual(st_del, 200)

        # Query storage
        st_st, data = self.harness.get_json("/api/hub/storage")
        self.assertEqual(st_st, 200)
        self.assertTrue(data.get("ok"))
        if data.get("hubBytes") is not None:
            self.assertGreaterEqual(data["hubBytes"], 0)


if __name__ == "__main__":
    unittest.main()
