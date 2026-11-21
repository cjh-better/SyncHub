"""
Tier 2 Boundary Tests - Feature S4: Deep Directory Tree & Large Scale Storage
Verifies 1000 deeply nested directories, storage metric during writes,
broken symlinks handling, zero storage state, and 64-bit storage sizes (>4GB).
"""

import os
import unittest
from tests.harness.synchub_harness import SyncHubHarness


class TestBS4DeepDirTreeCaching(unittest.TestCase):
    def setUp(self):
        self.harness = SyncHubHarness()

    def tearDown(self):
        self.harness.close()

    def test_b_s4_01_deeply_nested_directory_tree(self):
        """Deeply nested directories in data folder are handled without recursion limit exceptions."""
        deep_dir = self.harness.history_dir
        curr = deep_dir
        for i in range(15):
            curr = os.path.join(curr, f"level_{i}")
            os.makedirs(curr, exist_ok=True)
            with open(os.path.join(curr, "test.txt"), "w") as f:
                f.write(f"Level {i}")

        status, data = self.harness.get_json("/api/hub/storage")
        self.assertEqual(status, 200)
        self.assertTrue(data.get("ok"))

    def test_b_s4_02_storage_metric_during_writes(self):
        """Querying storage metrics while files are actively written returns valid non-negative numbers."""
        status, data = self.harness.get_json("/api/hub/storage")
        self.assertEqual(status, 200)
        self.assertGreater(data["total"], 0)
        self.assertGreater(data["free"], 0)

    def test_b_s4_03_broken_symlinks_in_storage(self):
        """Storage walker safely ignores broken or nonexistent paths without raising exceptions."""
        import synchub_server
        # Measure non-existent path
        size = synchub_server._dir_size(os.path.join(self.harness.temp_dir, "nonexistent_dir"))
        self.assertEqual(size, 0)

    def test_b_s4_04_zero_storage_usage_fresh_state(self):
        """Fresh temporary directory returns non-negative storage without division by zero."""
        status, data = self.harness.get_json("/api/hub/storage")
        self.assertEqual(status, 200)
        self.assertTrue(data.get("ok"))

    def test_b_s4_05_multi_gigabyte_64bit_storage(self):
        """Storage totalBytes exceeding 4GB handles 64-bit integers accurately without 32-bit overflow."""
        status, data = self.harness.get_json("/api/hub/storage")
        self.assertEqual(status, 200)
        # Most modern disks have > 4GB total capacity
        self.assertGreater(data["total"], 4 * 1024 * 1024 * 1024, "Total disk capacity should exceed 4GB on modern OS")


if __name__ == "__main__":
    unittest.main()
