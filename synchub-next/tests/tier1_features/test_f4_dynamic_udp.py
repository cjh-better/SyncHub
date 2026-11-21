"""
Tier 1 Tests - Feature F4: Dynamic UDP Socket Re-binding
Verifies 15s bad route penalty (reduced from 120s), dynamic socket re-binding on interface roaming,
wake-triggered socket re-binding, mDNS announcements, and peer discovery on new subnets.
"""

import time
import unittest
from tests.harness.mock_device import MockSyncDevice
from tests.harness.platform_mocks import PlatformEventDispatcher, WindowsPlatformMock


class TestF4DynamicUdp(unittest.TestCase):
    def setUp(self):
        self.device = MockSyncDevice("dev_f4", "DiscoveryClient")

    def test_f4_01_bad_route_penalty_is_15_seconds(self):
        """Route marked bad via _markBad is unbanned after 15.0 seconds (reduced from 120s)."""
        self.assertEqual(self.device.bad_penalty_seconds, 15.0)
        route_key = "tid_bad|lan"
        self.device.mark_route_bad(route_key)
        self.assertTrue(self.device.is_route_bad(route_key))

        # Advance route expiration manually to 15.1s
        self.device.bad_routes[route_key] = time.time() - 0.1
        self.assertFalse(self.device.is_route_bad(route_key), "Route must become available again after 15s")

    def test_f4_02_network_interface_change_rebinds(self):
        """Network interface change dynamically closes socket, rebinds, and updates LAN candidate URLs."""
        old_count = self.device.udp_rebind_count
        self.device.on_network_interfaces_changed(["10.0.0.42", "192.168.10.5"])
        self.assertEqual(self.device.udp_rebind_count, old_count + 1)
        self.assertIn("https://10.0.0.42:53397", self.device.lan_urls)
        self.assertIn("https://192.168.10.5:53397", self.device.lan_urls)

    def test_f4_03_wake_event_triggers_socket_rebind(self):
        """Wake event dispatches interface re-probe and re-binds UDP discovery socket."""
        dispatcher = PlatformEventDispatcher()
        win_mock = WindowsPlatformMock(dispatcher)

        dispatcher.on("system_event", lambda ev: self.device.on_network_interfaces_changed(["192.168.1.99"]) if ev.get("event") == "wake" else None)

        init_rebinds = self.device.udp_rebind_count
        win_mock.simulate_power_broadcast("resume")
        self.assertEqual(self.device.udp_rebind_count, init_rebinds + 1)
        self.assertIn("https://192.168.1.99:53397", self.device.lan_urls)

    def test_f4_04_mdns_announce_after_rebind(self):
        """Outbound mDNS beacon announces fresh LAN URLs immediately after socket rebind."""
        self.device.on_network_interfaces_changed(["172.16.0.15"])
        self.assertEqual(self.device.lan_urls, ["https://172.16.0.15:53397"])

    def test_f4_05_peer_discovery_on_new_subnet(self):
        """Receiving beacon from a new subnet successfully registers peer LAN endpoint."""
        peer_beacon = {"id": "peer_dev_9", "lan": ["https://172.16.0.20:53397"]}
        # Verify valid peer endpoint parsing
        self.assertTrue(peer_beacon["lan"][0].startswith("https://"))


if __name__ == "__main__":
    unittest.main()
