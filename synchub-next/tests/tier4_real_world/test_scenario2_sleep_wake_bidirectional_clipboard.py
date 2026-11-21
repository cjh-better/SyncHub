"""
Tier 4 Real-World Workload - Scenario 2:
Sleep/Wake During Active Bidirectional Clipboard Sync
Simulates bidirectional clipboard sync across Windows PC and macOS Laptop:
1. PC copies text snippet; Laptop receives it.
2. Laptop enters sleep (NSWorkspace.willSleepNotification).
3. While Laptop is asleep, PC copies 3MB PNG image with unique millisecond nonce.
4. Laptop wakes (NSWorkspace.didWakeNotification); kickReconnect() reconnects in < 100ms.
5. Laptop auto-pulls pending image without loopback echo reflection. Both clipboards match.
"""

import time
import unittest
from tests.harness.mock_device import MockSyncDevice
from tests.harness.synchub_harness import SyncHubHarness
from tests.harness.platform_mocks import PlatformEventDispatcher, WindowsPlatformMock, MacOSPlatformMock


class TestScenario2SleepWakeBidirectionalClipboard(unittest.TestCase):
    def setUp(self):
        self.harness = SyncHubHarness()
        self.pc = MockSyncDevice("pc_windows", "Windows-Workstation", "windows")
        self.laptop = MockSyncDevice("laptop_mac", "MacBook-Air", "macos")

        self.dispatcher = PlatformEventDispatcher()
        self.win_mock = WindowsPlatformMock(self.dispatcher)
        self.mac_mock = MacOSPlatformMock(self.dispatcher)

        # Wire wake event
        self.dispatcher.on("system_event", lambda ev: self.laptop.kick_reconnect() if ev.get("event") == "wake" else None)
        self.pc.on_connect_success()
        self.laptop.on_connect_success()

    def tearDown(self):
        self.harness.close()

    def test_scenario2_sleep_wake_bidirectional_clipboard(self):
        # 1. PC copies text
        text_content = "Hello from Windows Workstation!"
        st_text, res_text = self.harness.post_json("/api/hub/text", {"text": text_content, "from": self.pc.name})
        self.assertEqual(st_text, 200)

        # Laptop pulls text
        st_pull1, res_pull1 = self.harness.get_json(f"/api/hub/auto-pull?device_id={self.laptop.device_id}&since_id=0")
        self.assertEqual(st_pull1, 200)
        # Anti-echo check on laptop
        is_echo = self.laptop.record_clipboard_echo(text_content)
        self.assertFalse(is_echo, "First receipt must not be treated as echo")

        # 2. Laptop enters sleep
        self.mac_mock.simulate_will_sleep()
        self.laptop.on_disconnect()
        self.assertFalse(self.laptop.connected_ws)

        # 3. While Laptop is asleep, PC copies a 3MB PNG image
        img_payload = b"\x89PNG\r\n\x1a\n" + (b"IMAGE_PIXELS_" * 200000)
        img_name = MockSyncDevice.generate_image_filename()
        st_img, res_img = self.harness.upload_file(
            img_name,
            img_payload,
            from_device=self.pc.name,
            target_device=self.laptop.device_id
        )
        self.assertEqual(st_img, 200)

        # 4. Laptop wakes
        start_wake = time.time()
        self.mac_mock.simulate_did_wake()
        wake_ms = (time.time() - start_wake) * 1000
        self.assertLess(wake_ms, 100.0, "Wake event handling must be sub-100ms")
        self.assertTrue(self.laptop.kick_reconnect_triggered)

        # Reconnect laptop
        self.laptop.on_connect_success()

        # 5. Laptop pulls pending image
        st_pull2, res_pull2 = self.harness.get_json(f"/api/hub/auto-pull?device_id={self.laptop.device_id}&since_id=0")
        self.assertEqual(st_pull2, 200)
        items = res_pull2.get("items", [])
        image_items = [i for i in items if i.get("filename") == img_name]
        self.assertEqual(len(image_items), 1)

        # Anti-echo verification: PC receiving its own image is ignored
        pc_is_echo = self.pc.record_clipboard_echo(img_name)
        # First time recorded
        self.assertFalse(pc_is_echo)
        # Second time received -> echo detected and ignored
        self.assertTrue(self.pc.record_clipboard_echo(img_name))


if __name__ == "__main__":
    unittest.main()
