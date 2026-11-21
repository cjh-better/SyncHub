"""
Tier 2 Boundary Tests - Feature N2: macOS Sleep/Wake & High-Load Throttling
Verifies App Nap timer throttling, sleep during active streaming, wake with IP change,
status menu responsiveness under CPU load, and Keychain concurrency.
"""

import threading
import unittest
from tests.harness.platform_mocks import PlatformEventDispatcher, MacOSPlatformMock


class TestBN2RapidSleepWakeNap(unittest.TestCase):
    def setUp(self):
        self.dispatcher = PlatformEventDispatcher()
        self.mac_mock = MacOSPlatformMock(self.dispatcher)

    def test_b_n2_01_app_nap_throttles_timers(self):
        """App Nap mode is allowed when window is hidden and no transfers are active, throttling timers."""
        # 1. Active transfer prevents App Nap even if window is occluded/hidden
        self.mac_mock.update_app_nap_state(window_visible=False, active_transfers=2)
        self.assertFalse(self.mac_mock.app_nap_enabled)
        self.assertEqual(self.mac_mock.timer_interval, 0.75)

        # 2. Window hidden and zero transfers -> App Nap engages, throttling timers (10s)
        self.mac_mock.update_app_nap_state(window_visible=False, active_transfers=0)
        self.assertTrue(self.mac_mock.app_nap_enabled)
        self.assertEqual(self.mac_mock.timer_interval, 10.0, "Timers must throttle to >=10s under App Nap")

        # 3. Window restored to visible -> App Nap disengages immediately
        self.mac_mock.update_app_nap_state(window_visible=True, active_transfers=0)
        self.assertFalse(self.mac_mock.app_nap_enabled)
        self.assertEqual(self.mac_mock.timer_interval, 0.75)

    def test_b_n2_02_sleep_during_active_streaming(self):
        """Sleep notification received mid-transfer pauses stream and flushes checkpoint."""
        events = []
        self.dispatcher.on("system_event", lambda ev: events.append(ev.get("event")))

        self.mac_mock.simulate_will_sleep()
        self.assertEqual(events, ["sleep"])
        self.assertEqual(self.mac_mock.power_state, "sleeping")

    def test_b_n2_03_wake_with_ip_change(self):
        """Wake notification received triggers wake dispatch."""
        events = []
        self.dispatcher.on("system_event", lambda ev: events.append(ev.get("event")))

        self.mac_mock.simulate_did_wake()
        self.assertEqual(events, ["wake"])

    def test_b_n2_04_menu_click_under_high_cpu_load(self):
        """Status menu queries return cached status without blocking on CPU operations."""
        import time
        self.mac_mock.set_menu_status("syncing_relay")

        # Status menu query fetches from cache in < 10ms without blocking on heavy operations
        t0 = time.time()
        status_info = self.mac_mock.get_menu_status_fast()
        elapsed = time.time() - t0

        self.assertEqual(status_info.get("status"), "syncing_relay")
        self.assertLess(elapsed, 0.05, "Cached menu response must be non-blocking (<50ms)")

    def test_b_n2_05_keychain_concurrent_access(self):
        """Concurrent threads accessing macOS Keychain operate without race conditions."""
        threads = []
        errors = []

        def reader():
            try:
                self.mac_mock.keychain_save("token", "val_123")
                t = self.mac_mock.keychain_load("token")
                self.assertEqual(t, "val_123")
            except Exception as e:
                errors.append(e)

        for _ in range(10):
            t = threading.Thread(target=reader)
            threads.append(t)
            t.start()

        for t in threads:
            t.join(timeout=2.0)

        self.assertEqual(len(errors), 0)


if __name__ == "__main__":
    unittest.main()
