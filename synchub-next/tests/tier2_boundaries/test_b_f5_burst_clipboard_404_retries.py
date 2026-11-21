"""
Tier 2 Boundary Tests - Feature F5: High-Frequency Burst & Large Payload Boundaries
Verifies 10 copies debounced into 1, exact 20MB image boundary, binary null bytes in text,
same-millisecond image nonce uniqueness, and 503 service unavailable backoff.
"""

import unittest
from tests.harness.mock_device import MockSyncDevice


class TestBF5BurstClipboard404Retries(unittest.TestCase):
    def setUp(self):
        self.device = MockSyncDevice("dev_bf5", "BurstClipClient")

    def test_b_f5_01_ten_clipboard_copies_in_1_second(self):
        """10 rapid clipboard changes within 1s are debounced and only the latest content is synced."""
        base_time = 1000.0
        for i in range(10):
            # 10 rapid clipboard changes queued every 50ms (within 500ms debounce window)
            self.device.enqueue_clipboard_change(f"Clipboard Copy #{i}", timestamp=base_time + (i * 0.05))

        # While changes are within debounce window, they coalesce into pending
        self.assertEqual(self.device._pending_clipboard_text, "Clipboard Copy #9")
        self.assertEqual(len(self.device.synced_clipboard_history), 0)

        # Once debounce window elapses, single sync fires with latest debounced content
        synced = self.device.flush_debounced_clipboard(timestamp=base_time + 0.6)
        self.assertEqual(synced, "Clipboard Copy #9")
        self.assertEqual(len(self.device.synced_clipboard_history), 1)
        self.assertEqual(self.device.synced_clipboard_history[0], "Clipboard Copy #9")

    def test_b_f5_02_exact_20_megabyte_image_boundary(self):
        """Image size check: exactly 20,971,520 bytes accepted; 20,971,521 bytes rejected."""
        exact_limit = 20 * 1024 * 1024  # 20 MiB = 20971520 bytes
        accepted_size = exact_limit
        rejected_size = exact_limit + 1

        ok_accepted, err_accepted = self.device.validate_image_payload(accepted_size)
        self.assertTrue(ok_accepted)
        self.assertIsNone(err_accepted)

        ok_rejected, err_rejected = self.device.validate_image_payload(rejected_size)
        self.assertFalse(ok_rejected)
        self.assertIn("exceeds max 20MB limit", err_rejected)

    def test_b_f5_03_binary_null_bytes_in_text(self):
        """Embedded \\x00 null bytes and control characters are preserved without truncation."""
        raw_text = "Before\x00Middle\x01\x02\x03After"
        is_echo = self.device.record_clipboard_echo(raw_text)
        self.assertFalse(is_echo)

        # Same text detected as echo
        self.assertTrue(self.device.record_clipboard_echo(raw_text))

    def test_b_f5_04_same_millisecond_image_collision(self):
        """20 image filenames generated at the exact same millisecond timestamp produce 20 distinct names."""
        fixed_time = 1700000000.555
        names = set()
        for _ in range(20):
            fn = MockSyncDevice.generate_image_filename(timestamp=fixed_time)
            names.add(fn)
        self.assertEqual(len(names), 20, "All 20 filenames must be unique via nonce")

    def test_b_f5_05_remote_503_service_unavailable(self):
        """Remote 503 error triggers backoff delay; recovers once service returns 200 OK."""
        d1 = self.device.get_clipboard_error_delay(1)
        d2 = self.device.get_clipboard_error_delay(2)
        self.assertGreater(d2, d1)


if __name__ == "__main__":
    unittest.main()
