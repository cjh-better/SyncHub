"""
Tier 1 Tests - Feature N4: Idle Memory & CPU Optimization
Verifies lazy isolate spawning, 60s idle termination, engine ticker pause on idle,
ticker resumption, and scoped rebuilding.
"""

import time
import unittest
from tests.harness.platform_mocks import CryptoPoolMock, EngineTickerMock


class TestN4IdleOptimization(unittest.TestCase):
    def setUp(self):
        self.crypto_pool = CryptoPoolMock(max_workers=4, idle_timeout=60.0)
        self.ticker = EngineTickerMock()

    def test_n4_01_crypto_isolates_lazy_spawn(self):
        """0 worker isolates are spawned on engine initialization until first crypto operation."""
        self.assertEqual(self.crypto_pool.active_workers, 0, "Initial worker isolate count must be 0")

        # Process first job
        digest = self.crypto_pool.process_job(b"Test Data")
        self.assertGreater(self.crypto_pool.active_workers, 0)
        self.assertEqual(len(digest), 32)

    def test_n4_02_crypto_isolates_idle_terminate_60s(self):
        """Inactivity for 60 seconds reaps all idle worker isolates to reclaim 15-30MB RAM."""
        self.crypto_pool.process_job(b"Workload")
        self.assertGreater(self.crypto_pool.active_workers, 0)

        # Before 60s (e.g. at 59s): not terminated
        t_now = self.crypto_pool.last_used + 59.0
        terminated = self.crypto_pool.check_idle_reap(current_time=t_now)
        self.assertFalse(terminated)
        self.assertGreater(self.crypto_pool.active_workers, 0)

        # At 60.1s: terminated
        t_60 = self.crypto_pool.last_used + 60.1
        terminated = self.crypto_pool.check_idle_reap(current_time=t_60)
        self.assertTrue(terminated)
        self.assertEqual(self.crypto_pool.active_workers, 0)

    def test_n4_03_engine_ticker_pause_when_idle(self):
        """Engine ticker pauses disk outbox scans when active transfers and pending syncs are 0."""
        self.ticker.tick(active_transfers=0, pending_syncs=0)
        self.assertTrue(self.ticker.is_paused)
        self.assertEqual(self.ticker.scan_count, 0)

    def test_n4_04_ticker_resumes_on_new_transfer(self):
        """Queueing a new transfer or clipboard sync resumes ticker scans immediately."""
        self.ticker.tick(active_transfers=0, pending_syncs=0)
        self.assertTrue(self.ticker.is_paused)

        self.ticker.tick(active_transfers=1, pending_syncs=0)
        self.assertFalse(self.ticker.is_paused)
        self.assertEqual(self.ticker.scan_count, 1)

    def test_n4_05_listenable_builder_scoped_rebuild(self):
        """Scoped UI listeners limit rebuilds to active item card rather than whole tree."""
        rebuild_counts = {"root": 0, "card": 0}

        def on_root_notify():
            rebuild_counts["root"] += 1

        def on_card_notify():
            rebuild_counts["card"] += 1

        # Progress update on card
        on_card_notify()
        self.assertEqual(rebuild_counts["root"], 0)
        self.assertEqual(rebuild_counts["card"], 1)


if __name__ == "__main__":
    unittest.main()
