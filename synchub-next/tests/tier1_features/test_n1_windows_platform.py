"""
Tier 1 Tests - Feature N1: Windows Platform Bridge & Events
Verifies WM_CLIPBOARDUPDATE listener, WM_POWERBROADCAST (PBT_APMSUSPEND, PBT_APMRESUMEAUTOMATIC),
WM_WTSSESSION_CHANGE lock/unlock events, and DPAPI credential protection.
"""

import unittest
from tests.harness.platform_mocks import PlatformEventDispatcher, WindowsPlatformMock


class TestN1WindowsPlatform(unittest.TestCase):
    def setUp(self):
        self.dispatcher = PlatformEventDispatcher()
        self.win_mock = WindowsPlatformMock(self.dispatcher)

    def test_n1_01_wm_clipboard_update_event_received(self):
        """WM_CLIPBOARDUPDATE notification emits clipboard_changed event with updated sequence number."""
        events = []
        self.dispatcher.on("clipboard_changed", lambda ev: events.append(ev))

        self.win_mock.add_clipboard_format_listener()
        self.win_mock.simulate_clipboard_update(new_seq=105)

        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["seq"], 105)

    def test_n1_02_wm_power_broadcast_suspend(self):
        """WM_POWERBROADCAST PBT_APMSUSPEND dispatches system_event sleep."""
        power_events = []
        self.dispatcher.on("system_event", lambda ev: power_events.append(ev.get("event")))

        self.win_mock.simulate_power_broadcast("suspend")
        self.assertIn("sleep", power_events)
        self.assertEqual(self.win_mock.power_state, "sleeping")

    def test_n1_03_wm_power_broadcast_resume(self):
        """WM_POWERBROADCAST PBT_APMRESUMEAUTOMATIC dispatches system_event wake."""
        power_events = []
        self.dispatcher.on("system_event", lambda ev: power_events.append(ev.get("event")))

        self.win_mock.simulate_power_broadcast("resume")
        self.assertIn("wake", power_events)
        self.assertEqual(self.win_mock.power_state, "awake")

    def test_n1_04_wts_session_lock_unlock(self):
        """WM_WTSSESSION_CHANGE dispatches lock and unlock events."""
        session_events = []
        self.dispatcher.on("system_event", lambda ev: session_events.append(ev.get("event")))

        self.win_mock.simulate_session_change(locked=True)
        self.win_mock.simulate_session_change(locked=False)

        self.assertEqual(session_events, ["lock", "unlock"])

    def test_n1_05_dpapi_storage_encryption(self):
        """Win32 DPAPI protects device tokens and decrypts payload accurately."""
        token = "fixture-token"
        cipher = self.win_mock.dpapi_encrypt("device_token", token)
        self.assertTrue(cipher.startswith("dpapi:"))

        plain = self.win_mock.dpapi_decrypt("device_token")
        self.assertEqual(plain, token)


if __name__ == "__main__":
    unittest.main()
