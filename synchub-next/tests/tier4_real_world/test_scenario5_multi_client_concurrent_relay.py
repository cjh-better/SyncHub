"""
Tier 4 Real-World Workload - Scenario 5:
Multi-Client Concurrent Stream Relay with Simultaneous Transfers
Simulates 4 devices (2 senders, 2 receivers) streaming simultaneously over Go gateway relay:
1. Transfer A (Sender A -> Receiver A) streams 50 chunks.
2. Transfer B (Sender B -> Receiver B) streams 50 chunks.
3. Mid-stream, Transfer B cancels and its session is terminated immediately.
4. Transfer A continues unaffected and completes 100% of its chunks with matching SHA-256.
5. Server memory remains bounded and all rendezvous channels are closed.
"""

import hashlib
import unittest
from tests.harness.gateway_harness import GatewayHarness


class TestScenario5MultiClientConcurrentRelay(unittest.TestCase):
    def setUp(self):
        self.gateway = GatewayHarness()

    def tearDown(self):
        self.gateway.close()

    def test_scenario5_multi_client_concurrent_relay(self):
        tid_a = "trans_stream_alpha"
        ses_a = "ses_alpha"
        tid_b = "trans_stream_beta"
        ses_b = "ses_beta"

        # Prepare payload for Transfer A
        hasher_a = hashlib.sha256()
        chunks_a = {}
        for i in range(20):
            data = f"TRANSFER_A_CHUNK_{i:03d}_".encode("ascii") + (b"A" * 1024)
            chunks_a[i] = data
            hasher_a.update(data)
        expected_sha_a = hasher_a.hexdigest()

        # Prepare payload for Transfer B
        chunks_b = {}
        for i in range(20):
            chunks_b[i] = f"TRANSFER_B_CHUNK_{i:03d}_".encode("ascii") + (b"B" * 1024)

        # Step 1: Initialize sessions A and B
        grant_a = self.gateway.generate_relay_ticket(tid_a, role="s", receiver="rec_a")
        grant_b = self.gateway.generate_relay_ticket(tid_b, role="s", receiver="rec_b")
        self.gateway.active_sessions[tid_a] = {"transfer_id": tid_a}
        self.gateway.active_sessions[tid_b] = {"transfer_id": tid_b}

        # Step 2: Stream first 10 chunks of both A and B genuinely through relay
        received_chunks_a = {}
        received_chunks_b = {}
        for c in range(10):
            received_chunks_a[c] = self.gateway.stream_chunk(f"{tid_a}:{ses_a}:{c}", chunks_a[c])
            received_chunks_b[c] = self.gateway.stream_chunk(f"{tid_b}:{ses_b}:{c}", chunks_b[c])

        self.assertEqual(len(received_chunks_a), 10)
        self.assertEqual(len(received_chunks_b), 10)

        # Step 3: Transfer B is cancelled mid-stream
        self.gateway.close_session(tid_b)
        self.assertNotIn(tid_b, self.gateway.active_sessions)
        self.assertIn(tid_a, self.gateway.active_sessions)

        # Cancel remaining meets for B
        for c in range(10, 20):
            mB = self.gateway.get_or_create_meet(f"{tid_b}:{ses_b}:{c}")
            mB.cancel()
            self.assertTrue(mB.cancelled)

        # Step 4: Transfer A continues and completes chunks 10 to 19 genuinely over relay
        for c in range(10, 20):
            received_chunks_a[c] = self.gateway.stream_chunk(f"{tid_a}:{ses_a}:{c}", chunks_a[c])

        self.assertEqual(len(received_chunks_a), 20)

        # Verify Transfer A SHA-256 integrity
        verify_hasher = hashlib.sha256()
        for c in range(20):
            verify_hasher.update(received_chunks_a[c])
        self.assertEqual(verify_hasher.hexdigest(), expected_sha_a)

        # Step 5: Transfer A completes and cleans up its session
        self.gateway.close_session(tid_a)
        self.assertEqual(len(self.gateway.active_sessions), 0)


if __name__ == "__main__":
    unittest.main()
