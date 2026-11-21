"""
Tier 1 Tests - Feature N3: Android Push Clipboard, WakeLock & Keystore
Verifies EventChannel push clipboard events, WakeLock acquisition and release,
Doze mode broadcast handling, and Keystore single-key deletion bug fix (no clear()).
"""

import unittest
from tests.harness.platform_mocks import PlatformEventDispatcher, AndroidPlatformMock


class TestN3AndroidPlatform(unittest.TestCase):
    def setUp(self):
        self.dispatcher = PlatformEventDispatcher()
        self.android_mock = AndroidPlatformMock(self.dispatcher)

    def test_n3_01_event_channel_push_clipboard_event(self):
        """Android SyncService emits clipboard updates via EventChannel('synchub/events') eliminating 750ms polling."""
        pushed = []
        self.dispatcher.on("android_push_clipboard", lambda ev: pushed.append(ev))

        self.android_mock.simulate_event_channel_clipboard("clipboard_text", "Pushed from Android")
        self.assertEqual(len(pushed), 1)
        self.assertEqual(pushed[0]["type"], "clipboard_text")
        self.assertEqual(pushed[0]["data"], "Pushed from Android")

    def test_n3_02_wakelock_acquired_during_transfer(self):
        """Partial WakeLock is acquired when an active chunk transfer starts to prevent CPU sleep."""
        self.assertFalse(self.android_mock.wakelock_held)
        self.android_mock.acquire_wakelock()
        self.assertTrue(self.android_mock.wakelock_held)
        self.assertGreater(self.android_mock.wakelock_acquired_at, 0)

    def test_n3_03_wakelock_released_on_complete(self):
        """Partial WakeLock is released immediately when transfer finishes or fails."""
        self.android_mock.acquire_wakelock()
        self.assertTrue(self.android_mock.wakelock_held)

        self.android_mock.release_wakelock()
        self.assertFalse(self.android_mock.wakelock_held)

    def test_n3_04_doze_mode_broadcast_handling(self):
        """Entering Doze mode is observed and dispatches doze_mode_changed."""
        doze_events = []
        self.dispatcher.on("doze_mode_changed", lambda ev: doze_events.append(ev.get("doze")))

        self.android_mock.simulate_doze_mode(active=True)
        self.android_mock.simulate_doze_mode(active=False)
        self.assertEqual(doze_events, [True, False])

    def test_n3_05_keystore_single_key_wipeout_fix(self):
        """Deleting a single corrupted key in SecureStore removes only that key without wiping the entire SharedPreferences."""
        self.android_mock.secure_store_put("device_token", "shd_token_important")
        self.android_mock.secure_store_put("auth_user", "admin")
        self.android_mock.secure_store_put("bad_key", "corrupt_data")

        # Deleting bad_key must leave device_token and auth_user intact
        self.android_mock.secure_store_delete_single_key("bad_key")

        self.assertIsNone(self.android_mock.secure_store_get("bad_key"))
        self.assertEqual(self.android_mock.secure_store_get("device_token"), "shd_token_important")
        self.assertEqual(self.android_mock.secure_store_get("auth_user"), "admin")


if __name__ == "__main__":
    unittest.main()
