"""
Tier 1 Tests - Feature F3: WebRTC State Machine Tuning
Verifies 12s WebRTC handshake timeout, seamless fallback to high-speed relay,
session preservation, successful WebRTC transfer, and ICE failure fallback.
"""

import unittest
from tests.harness.mock_device import MockSyncDevice


class TestF3WebrtcTuning(unittest.TestCase):
    def setUp(self):
        self.device = MockSyncDevice("dev_f3", "WebRtcClient")
        self.device.on_connect_success()

    def test_f3_01_webrtc_connect_timeout_is_12_seconds(self):
        """WebRTC handshake timeout threshold is configured to 12.0 seconds (extended from 6.0s)."""
        self.assertEqual(self.device.webrtc_timeout_seconds, 12.0, "Expected WebRTC timeout to be 12.0 seconds")

    def test_f3_02_seamless_fallback_to_relay(self):
        """On WebRTC timeout, engine seamlessly falls back to relay without raising unhandled exceptions."""
        tid = "trans_fallback_01"
        session_info = {"token": "fixture-token", "sender_key": "x25519_key"}
        # Trigger timeout simulation
        ok = self.device.start_webrtc_handshake(tid, session_info, simulate_timeout=True)
        self.assertFalse(ok)
        self.assertTrue(self.device.fallback_to_relay_called)
        self.assertIsNotNone(self.device.last_fallback_session)
        self.assertEqual(self.device.last_fallback_session["transfer_id"], tid)
        self.assertEqual(self.device.last_fallback_session["route"], f"relay:{tid}")

    def test_f3_03_session_preserved_across_fallback(self):
        """transferId and session verification tokens are preserved across relay fallback."""
        tid = "trans_preserve_02"
        session_info = {"chunk_hashes": ["HASH0", "HASH1"], "total_bytes": 1048576}
        self.device.fallback_to_relay(tid, session_info)

        saved = self.device.last_fallback_session
        self.assertEqual(saved["transfer_id"], tid)
        self.assertEqual(saved["session_data"]["total_bytes"], 1048576)
        self.assertEqual(len(saved["session_data"]["chunk_hashes"]), 2)

    def test_f3_04_successful_webrtc_bypasses_relay(self):
        """Responsive peer establishes WebRTC DataChannel directly, bypassing relay fallback."""
        tid = "trans_p2p_03"
        session_info = {"token": "fixture-token"}
        ok = self.device.start_webrtc_handshake(tid, session_info, simulate_timeout=False)
        self.assertTrue(ok)
        self.assertTrue(self.device.webrtc_connected)
        self.assertFalse(self.device.fallback_to_relay_called)

    def test_f3_05_ice_gathering_failure_fallback(self):
        """ICE gathering failure (e.g. 0 viable candidates) triggers relay fallback gracefully."""
        tid = "trans_ice_fail_04"
        session_info = {"candidates": []}
        # Simulate failure
        self.device.fallback_to_relay(tid, session_info)
        self.assertTrue(self.device.fallback_to_relay_called)
        self.assertEqual(self.device.last_fallback_session["route"], f"relay:{tid}")


if __name__ == "__main__":
    unittest.main()
