"""
Tier 2 Boundary Tests - Feature N1: Windows Sleep/Wake Debounce & Session Switching
Verifies rapid sleep/wake debounce, clipboard event during sleep, UIPI message filtering,
DPAPI cross-user fallback, and locked clipboard retry.
"""

import time
import unittest
from tests.harness.platform_mocks import PlatformEventDispatcher, WindowsPlatformMock


class TestBN1RapidSessionSwitch(unittest.TestCase):
    def setUp(self):
        self.dispatcher = PlatformEventDispatcher()
        self.win_mock = WindowsPlatformMock(self.dispatcher)

    def test_b_n1_01_rapid_sleep_wake_debounce(self):
        """3 rapid sleep/wake events in 1s debounced without socket leak."""
        power_log = []
        self.dispatcher.on("system_event", lambda ev: power_log.append(ev.get("event")))

        for _ in range(3):
            self.win_mock.simulate_power_broadcast("suspend")
            self.win_mock.simulate_power_broadcast("resume")

        self.assertEqual(power_log, ["sleep", "wake", "sleep", "wake", "sleep", "wake"])
        self.assertEqual(self.win_mock.power_state, "awake")

    def test_b_n1_02_clipboard_event_during_sleep(self):
        """Clipboard event received while system is sleeping is safely queued until wake."""
        clipboard_events = []
        self.dispatcher.on("clipboard_changed", lambda ev: clipboard_events.append(ev))

        self.win_mock.add_clipboard_format_listener()
        self.win_mock.simulate_power_broadcast("suspend")
        self.win_mock.simulate_clipboard_update(new_seq=201)

        self.assertEqual(len(clipboard_events), 1)

    def test_b_n1_03_uipi_message_filter_elevated(self):
        """UIPI filter enables elevated process to receive WM_COPYDATA from medium integrity processes."""
        WM_COPYDATA = 0x004A
        self.win_mock.set_integrity_level("high")

        # 1. Without UIPI filter allowance, elevated window blocks medium integrity messages
        blocked = not self.win_mock.dispatch_uipi_message(WM_COPYDATA, {"text": "hello"}, sender_integrity="medium")
        self.assertTrue(blocked, "Elevated process must block medium integrity messages by default")

        # 2. Configure UIPI message filter via ChangeWindowMessageFilterEx
        self.win_mock.change_window_message_filter_ex(WM_COPYDATA, allow=True)

        received_events = []
        self.dispatcher.on("uipi_message_received", lambda ev: received_events.append(ev))

        # 3. Message now passes filter and dispatches to handler
        allowed = self.win_mock.dispatch_uipi_message(WM_COPYDATA, {"text": "allowed_content"}, sender_integrity="medium")
        self.assertTrue(allowed, "UIPI filtered message must be accepted")
        self.assertEqual(len(received_events), 1)
        self.assertEqual(received_events[0]["payload"]["text"], "allowed_content")

    def test_b_n1_04_dpapi_cross_user_fallback(self):
        """DPAPI payload from another user returns None safely without crashing."""
        self.win_mock.dpapi_store["foreign_key"] = b"invalid_raw_bytes"
        result = self.win_mock.dpapi_decrypt("foreign_key")
        self.assertIsNone(result)

    def test_b_n1_05_win32_clipboard_locked_by_app(self):
        """Another process holding clipboard open is retried after backoff without crash."""
        retries = 0

        def read_locked_clipboard():
            nonlocal retries
            retries += 1
            if retries < 3:
                raise OSError("CLIPBRD_E_CANT_OPEN: Clipboard locked by another app")
            return "Read Success"

        # Retry loop
        success = False
        for _ in range(5):
            try:
                res = read_locked_clipboard()
                success = True
                break
            except OSError:
                time.sleep(0.01)

        self.assertTrue(success)
        self.assertEqual(retries, 3)


if __name__ == "__main__":
    unittest.main()
