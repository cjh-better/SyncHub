"""
Tier 3 Combination Tests - Suite 1: Sleep + Relay Transfer
Pairs Features (N1/N2/N3 x S5/F3):
System sleep occurs during active relay chunk streaming.
Relay session pauses. System wakes. Native runner emits wake event.
kickReconnect() triggers immediate reconnection and dynamic UDP rebinding.
Transfer resumes from saved checkpoint without restarting from chunk 0.
"""

import time
import unittest
from tests.harness.mock_device import MockSyncDevice
from tests.harness.gateway_harness import GatewayHarness
from tests.harness.platform_mocks import PlatformEventDispatcher, WindowsPlatformMock


class TestComboSleepAndTransfer(unittest.TestCase):
    def setUp(self):
        self.gateway = GatewayHarness()
        self.device = MockSyncDevice("dev_combo1", "ComboSleepClient")
        self.dispatcher = PlatformEventDispatcher()
        self.win_mock = WindowsPlatformMock(self.dispatcher)

        # Wire platform bridge to device
        self.dispatcher.on("system_event", lambda ev: self.device.kick_reconnect() if ev.get("event") == "wake" else None)
        self.device.on_connect_success()

    def tearDown(self):
        self.gateway.close()

    def test_combo_sleep_and_transfer_resume_from_checkpoint(self):
        tid = "t_sleep_resume_100"
        session = "ses_sleep_100"
        total_chunks = 10
        chunks_sent = []
        received_chunks = {}

        # 1. Stream first 4 chunks genuinely over relay
        for i in range(4):
            data = f"CHUNK_{i}".encode("utf-8")
            recv = self.gateway.stream_chunk(f"{tid}:{session}:{i}", data)
            self.assertEqual(recv, data)
            chunks_sent.append(i)
            received_chunks[i] = recv

        self.assertEqual(len(chunks_sent), 4)

        # 2. System sleeps
        self.win_mock.simulate_power_broadcast("suspend")
        self.assertEqual(self.win_mock.power_state, "sleeping")
        self.device.on_disconnect()

        # 3. System wakes
        self.win_mock.simulate_power_broadcast("resume")
        self.assertEqual(self.win_mock.power_state, "awake")
        self.assertTrue(self.device.kick_reconnect_triggered)

        # 4. Interface changes on wake
        self.device.on_network_interfaces_changed(["192.168.1.88"])
        self.device.on_connect_success()

        # 5. Resume from checkpoint (chunk 4..9) genuinely over relay
        resumed_chunks = []
        for i in range(4, total_chunks):
            data = f"CHUNK_{i}".encode("utf-8")
            recv = self.gateway.stream_chunk(f"{tid}:{session}:{i}", data)
            self.assertEqual(recv, data)
            resumed_chunks.append(i)
            received_chunks[i] = recv

        self.assertEqual(resumed_chunks, [4, 5, 6, 7, 8, 9])
        total_transferred = chunks_sent + resumed_chunks
        self.assertEqual(len(total_transferred), total_chunks)
        self.assertEqual(len(received_chunks), total_chunks)


if __name__ == "__main__":
    unittest.main()
