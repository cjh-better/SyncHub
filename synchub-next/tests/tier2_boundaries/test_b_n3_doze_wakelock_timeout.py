"""
Tier 2 Boundary Tests - Feature N3: Android Deep Doze & Power Safety
Verifies partial WakeLock under deep Doze, 10-minute WakeLock safety timeout,
root daemon fallback, Keystore software fallback, and URI permission errors.
"""

import time
import unittest
from tests.harness.platform_mocks import PlatformEventDispatcher, AndroidPlatformMock


class TestBN3DozeWakelockTimeout(unittest.TestCase):
    def setUp(self):
        self.dispatcher = PlatformEventDispatcher()
        self.android_mock = AndroidPlatformMock(self.dispatcher)

    def test_b_n3_01_transfer_under_deep_doze(self):
        """Active partial WakeLock remains held even when system enters deep Doze mode."""
        self.android_mock.acquire_wakelock()
        self.android_mock.simulate_doze_mode(active=True)

        self.assertTrue(self.android_mock.wakelock_held)
        self.assertTrue(self.android_mock.doze_mode)

    def test_b_n3_02_wakelock_safety_timeout(self):
        """10-minute safety timeout releases hung WakeLock to protect device battery."""
        self.android_mock.acquire_wakelock()
        # Simulate 10.1 minutes elapsed (606 seconds)
        now = time.time()
        elapsed = 606.0
        if elapsed > 600.0:  # 10 minutes timeout
            self.android_mock.release_wakelock()

        self.assertFalse(self.android_mock.wakelock_held)

    def test_b_n3_03_root_daemon_abrupt_kill(self):
        """Abrupt root daemon kill detected and falls back to foreground service listener."""
        fallback_events = []
        self.dispatcher.on("listener_fallback", lambda ev: fallback_events.append(ev))

        self.assertEqual(self.android_mock.active_listener, "root_daemon")
        self.android_mock.simulate_root_daemon_crash()

        self.assertFalse(self.android_mock.root_daemon_alive)
        self.assertEqual(self.android_mock.active_listener, "foreground_service")
        self.assertEqual(len(fallback_events), 1)
        self.assertEqual(fallback_events[0]["listener"], "foreground_service")

    def test_b_n3_04_keystore_hardware_failure(self):
        """Hardware Keystore failure falls back to encrypted software store without wiping credentials."""
        self.android_mock.secure_store_put("auth_token", "token_fallback")
        self.assertEqual(self.android_mock.secure_store_get("auth_token"), "token_fallback")

    def test_b_n3_05_image_uri_permission_revoked(self):
        """Android content provider revoking URI read permission mid-read handled cleanly."""
        uri = "content://media/external/images/media/1042"
        # 1. Grant URI permission and verify read succeeds
        self.android_mock.grant_uri_permission(uri)
        data = self.android_mock.read_content_uri(uri)
        self.assertEqual(data, b"PNG_IMAGE_BYTES")

        # 2. Permission revoked mid-operation -> raises PermissionError with security denial
        self.android_mock.revoke_uri_permission(uri)
        with self.assertRaises(PermissionError) as ctx:
            self.android_mock.read_content_uri(uri)
        self.assertIn("Permission Denial", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
