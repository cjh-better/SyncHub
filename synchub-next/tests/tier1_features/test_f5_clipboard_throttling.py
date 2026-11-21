"""
Tier 1 Tests - Feature F5: Clipboard Sync Throttling & Safety
Verifies error backoff capping (15s on / 30s off), 404 retry counter (up to 3 times),
fallback to inline text on 3 failures, and image filename millisecond nonce format.
"""

import time
import unittest
from tests.harness.mock_device import MockSyncDevice


class TestF5ClipboardThrottling(unittest.TestCase):
    def setUp(self):
        self.device = MockSyncDevice("dev_f5", "ClipboardClient")

    def test_f5_01_remote_error_backoff_cap_15s_screen_on(self):
        """Consecutive remote errors cap backoff delay at 15.0s when screen is on."""
        self.device.screen_off = False
        delays = [self.device.get_clipboard_error_delay(i) for i in range(1, 10)]
        self.assertLessEqual(max(delays), 15.0, "Error backoff must be capped at 15.0s when screen is on")
        self.assertAlmostEqual(delays[-1], 15.0, delta=0.1)

    def test_f5_02_remote_error_backoff_cap_30s_screen_off(self):
        """Screen-off mode caps backoff delay at 30.0s."""
        self.device.screen_off = True
        delays = [self.device.get_clipboard_error_delay(i) for i in range(1, 10)]
        self.assertLessEqual(max(delays), 30.0, "Error backoff must be capped at 30.0s when screen is off")
        self.assertAlmostEqual(delays[-1], 30.0, delta=0.1)

    def test_f5_03_large_text_404_retried_3_times(self):
        """Remote large text 404 is retried up to 3 times before fallback."""
        attempt_count = 0

        def flaky_fetch():
            nonlocal attempt_count
            attempt_count += 1
            if attempt_count < 3:
                return None  # 404 simulation
            return "Full Resolved Large Text Content"

        result = self.device.fetch_clipboard_large_text("item_404_retry", flaky_fetch)
        self.assertEqual(attempt_count, 3)
        self.assertEqual(result, "Full Resolved Large Text Content")

    def test_f5_04_large_text_404_fallback_after_3_failures(self):
        """3 consecutive 404 errors trigger graceful fallback to None / inline text snippet."""
        attempt_count = 0

        def always_404():
            nonlocal attempt_count
            attempt_count += 1
            return None

        result = self.device.fetch_clipboard_large_text("item_permanent_404", always_404)
        self.assertEqual(attempt_count, 3)
        self.assertIsNone(result, "Must return None to signal fallback to inline summary")

    def test_f5_05_image_filename_millisecond_nonce(self):
        """Image names use a millisecond stamp and a counter, so one timestamp stays unique."""
        t = 1700000000.123
        fn1 = MockSyncDevice.generate_image_filename(timestamp=t)
        fn2 = MockSyncDevice.generate_image_filename(timestamp=t)

        self.assertTrue(fn1.startswith("IMG_"))
        self.assertTrue(fn1.endswith(".png"))
        self.assertIn("_123_", fn1, "Filename must include millisecond token")
        # Nonce ensures even identical timestamp generates distinct filenames
        self.assertNotEqual(fn1, fn2, "Filenames generated at same millisecond must not collide")


if __name__ == "__main__":
    unittest.main()
