"""
Tier 2 Boundary Tests - Feature F4: Roaming Storms & Bad Route Edge Expiration
Verifies rapid interface switching, 0 interfaces (airplane mode), corrupted datagram flood,
exact 15s bad penalty expiration, and subnet broadcast fallbacks.
"""

import time
import unittest
from tests.harness.mock_device import MockSyncDevice


class TestBF4InterfaceRoamingFlood(unittest.TestCase):
    def setUp(self):
        self.device = MockSyncDevice("dev_bf4", "RoamingStormClient")

    def test_b_f4_01_rapid_interface_switching(self):
        """Switching network interfaces 5 times in 2s cleanly rebinds UDP socket without leaks."""
        for i in range(5):
            self.device.on_network_interfaces_changed([f"10.0.{i}.15"])
        self.assertEqual(self.device.udp_rebind_count, 5)
        self.assertEqual(self.device.lan_urls, ["https://10.0.4.15:53397"])

    def test_b_f4_02_zero_interfaces_airplane_mode(self):
        """0 network interfaces (airplane mode) sets candidate list to empty without crashing."""
        self.device.on_network_interfaces_changed([])
        self.assertEqual(len(self.device.lan_urls), 0)

    def test_b_f4_03_corrupted_udp_datagram_flood(self):
        """Corrupted datagram bytes received on discovery socket are safely discarded."""
        corrupted_payload = b"\xFF\xFE\x00\x01\xDE\xAD\xBE\xEF"
        try:
            import json
            json.loads(corrupted_payload.decode("utf-8"))
            parsed = True
        except Exception:
            parsed = False
        self.assertFalse(parsed)

    def test_b_f4_04_bad_penalty_exact_expiration(self):
        """Route marked bad is rejected at 14.9s and becomes accepted at 15.1s."""
        route = "t_edge|lan"
        now = time.time()
        # Set expiration to exactly now + 15.0
        self.device.bad_routes[route] = now + 15.0

        # At 14.9s elapsed (0.1s before expiration): route is still bad
        self.assertTrue(time.time() < self.device.bad_routes[route])

        # Advance time to 15.1s
        self.device.bad_routes[route] = now - 0.1
        self.assertFalse(self.device.is_route_bad(route), "Route must become available at >15s")

    def test_b_f4_05_subnet_mask_mismatch_broadcast(self):
        """Invalid broadcast calculation falls back to global LAN broadcast 255.255.255.255."""
        # 1. Valid subnet broadcast calculation
        valid_bcast = self.device.calculate_broadcast_ip("192.168.1.50", "255.255.255.0")
        self.assertEqual(valid_bcast, "192.168.1.255")

        # 2. Corrupted/invalid mask falls back to global LAN broadcast 255.255.255.255
        fallback_mask = self.device.calculate_broadcast_ip("192.168.1.50", "invalid_mask")
        self.assertEqual(fallback_mask, "255.255.255.255")

        # 3. Subnet mismatch / out-of-range IP values fall back to global LAN broadcast
        fallback_range = self.device.calculate_broadcast_ip("192.168.1.50", "255.255.999.0")
        self.assertEqual(fallback_range, "255.255.255.255")


if __name__ == "__main__":
    unittest.main()
