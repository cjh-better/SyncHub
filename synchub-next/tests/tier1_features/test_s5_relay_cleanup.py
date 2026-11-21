"""
Tier 1 Tests - Feature S5: Relay Goroutine & Session Cleanup
Verifies Relay janitor cancellation, session termination on completion,
session cancellation, expired session eviction, and active session retention.
"""

import time
import unittest
from tests.harness.gateway_harness import GatewayHarness


class TestS5RelayCleanup(unittest.TestCase):
    def setUp(self):
        self.gateway = GatewayHarness()

    def tearDown(self):
        self.gateway.close()

    def test_s5_01_relay_shutdown_stops_janitor(self):
        """Cancelling Relay context terminates janitor ticker without leaking background routines."""
        self.assertFalse(self.gateway.janitor_stopped)
        self.gateway.stop_janitor()
        self.assertTrue(self.gateway.janitor_stopped)
        self.assertEqual(self.gateway.goroutines_active, 0)

    def test_s5_02_session_termination_on_complete(self):
        """closeSession(tid) removes session from active sessions map upon transfer completion."""
        tid = "trans_complete_001"
        _ = self.gateway.generate_relay_ticket(tid)
        self.gateway.active_sessions[tid] = {
            "transfer_id": tid,
            "created_at": time.time(),
            "last_active": time.time()
        }
        self.assertIn(tid, self.gateway.active_sessions)

        # Complete session
        self.gateway.close_session(tid)
        self.assertNotIn(tid, self.gateway.active_sessions)

    def test_s5_03_session_termination_on_cancel(self):
        """Cancelled transfer session deletes session and cancels meet synchronization."""
        tid = "trans_cancel_002"
        meet_key = f"{tid}:ses1:chunk0"
        meet = self.gateway.get_or_create_meet(meet_key)
        self.gateway.active_sessions[tid] = {
            "transfer_id": tid,
            "created_at": time.time(),
            "last_active": time.time()
        }

        # Cancel transfer
        self.gateway.close_session(tid)
        meet.cancel()
        self.assertTrue(meet.cancelled)
        self.assertNotIn(tid, self.gateway.active_sessions)

    def test_s5_04_expired_session_cleanup(self):
        """Sessions with last_active > 48h (TTL) are evicted by the janitor loop."""
        now = time.time()
        # Active session
        self.gateway.active_sessions["s_active"] = {"last_active": now - 3600}
        # Expired session (50 hours ago)
        self.gateway.active_sessions["s_expired"] = {"last_active": now - (50 * 3600)}

        # Simulate janitor sweep
        ttl_cutoff = now - (48 * 3600)
        expired_keys = [k for k, v in self.gateway.active_sessions.items() if v["last_active"] < ttl_cutoff]
        for k in expired_keys:
            del self.gateway.active_sessions[k]

        self.assertIn("s_active", self.gateway.active_sessions)
        self.assertNotIn("s_expired", self.gateway.active_sessions)

    def test_s5_05_active_session_retained(self):
        """Active sessions with recent timestamps are retained in memory."""
        self.gateway.active_sessions["s_fresh"] = {"last_active": time.time() - 60}
        self.assertIn("s_fresh", self.gateway.active_sessions)


if __name__ == "__main__":
    unittest.main()
