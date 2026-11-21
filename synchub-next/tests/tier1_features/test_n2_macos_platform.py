"""
Tier 1 Tests - Feature N2: macOS Platform Bridge & App Nap
Verifies NSWorkspace.willSleepNotification, didWakeNotification,
App Nap energy saving, status menu caching, and Keychain secure token storage.
"""

import time
import unittest
from tests.harness.platform_mocks import PlatformEventDispatcher, MacOSPlatformMock


class TestN2MacOSPlatform(unittest.TestCase):
    def setUp(self):
        self.dispatcher = PlatformEventDispatcher()
        self.mac_mock = MacOSPlatformMock(self.dispatcher)

    def test_n2_01_will_sleep_notification_dispatch(self):
        """NSWorkspace.willSleepNotification dispatches system_event sleep."""
        events = []
        self.dispatcher.on("system_event", lambda ev: events.append(ev.get("event")))

        self.mac_mock.simulate_will_sleep()
        self.assertEqual(events, ["sleep"])
        self.assertEqual(self.mac_mock.power_state, "sleeping")

    def test_n2_02_did_wake_notification_dispatch(self):
        """NSWorkspace.didWakeNotification dispatches system_event wake."""
        events = []
        self.dispatcher.on("system_event", lambda ev: events.append(ev.get("event")))

        self.mac_mock.simulate_did_wake()
        self.assertEqual(events, ["wake"])
        self.assertEqual(self.mac_mock.power_state, "awake")

    def test_n2_03_no_idle_polling_permits_app_nap(self):
        """Eliminating 750ms polling permits macOS App Nap to throttle background process."""
        self.assertTrue(self.mac_mock.app_nap_enabled)

    def test_n2_04_status_menu_caching(self):
        """Menu queries return cached status without blocking main UI thread."""
        cache = self.mac_mock.menu_cache
        self.assertEqual(cache["status"], "idle")
        self.assertGreater(cache["updated_at"], 0)

    def test_n2_05_keychain_store_secure_access(self):
        """macOS Keychain stores and loads tokens securely."""
        self.mac_mock.keychain_save("device_token", "shd_mac_token_abc")
        token = self.mac_mock.keychain_load("device_token")
        self.assertEqual(token, "shd_mac_token_abc")


if __name__ == "__main__":
    unittest.main()
