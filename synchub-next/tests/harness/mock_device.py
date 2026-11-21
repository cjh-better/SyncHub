"""
Mock Device Model for SyncHub-Next E2E Testing.
Implements Client Core contracts:
- F1: Backoff exponential doubling with randomized jitter (±20%) and kickReconnect()
- F2: Waiter completer registry with instant fast-fail on disconnect
- F3: WebRTC 12s state machine with seamless relay fallback
- F4: Dynamic UDP socket re-binding on interface roaming and 15s bad penalty
- F5: Clipboard error backoff capping (15s on / 30s off), 404 retries (up to 3), and image filename nonce
"""

import time
import math
import random
import hashlib
from typing import Dict, Any, Optional, List, Callable, Tuple


class MockWaiter:
    def __init__(self, key: str):
        self.key = key
        self.completed = False
        self.result: Optional[Any] = None
        self.error: Optional[Exception] = None

    def complete(self, value: Any):
        if not self.completed:
            self.completed = True
            self.result = value

    def complete_error(self, err: Exception):
        if not self.completed:
            self.completed = True
            self.error = err


class MockSyncDevice:
    # F3 Flow control boundaries
    DATACHANNEL_BUFFER_MAX = 16 * 1024 * 1024  # 16 MiB ceiling
    DATACHANNEL_BUFFER_LOW_WATERMARK = 4 * 1024 * 1024  # 4 MiB low watermark

    # F5 Protocol boundaries
    MAX_IMAGE_PAYLOAD_BYTES = 20 * 1024 * 1024  # 20 MiB = 20971520 bytes
    _image_nonce = 1000

    def __init__(self, device_id: str, name: str, platform: str = "windows"):
        self.device_id = device_id
        self.name = name
        self.platform = platform
        self.token: Optional[str] = None
        self.online = False
        self.connected_ws = False

        # F1 State
        self.backoff_base = 1.0
        self.backoff_current = 1.0
        self.backoff_cap = 30.0
        self.reconnect_attempts = 0
        self.last_reconnect_time = 0.0
        self.kick_reconnect_triggered = False

        # F2 State
        self.waiters: Dict[str, MockWaiter] = {}
        self.failed_waiters_count = 0

        # F3 State
        self.webrtc_timeout_seconds = 12.0
        self.webrtc_connected = False
        self.fallback_to_relay_called = False
        self.last_fallback_session: Optional[Dict[str, Any]] = None
        self.datachannel_buffered_amount = 0
        self.datachannel_paused = False

        # F4 State
        self.bad_routes: Dict[str, float] = {}  # route_key -> expiration_timestamp
        self.bad_penalty_seconds = 15.0
        self.bound_udp_port = 53319
        self.current_interfaces: List[str] = ["192.168.1.50"]
        self.lan_urls: List[str] = ["https://192.168.1.50:53397"]
        self.udp_rebind_count = 0

        # F5 State
        self.screen_off = False
        self.clip_backoff_cap_screen_on = 15.0
        self.clip_backoff_cap_screen_off = 30.0
        self.clipboard_history_hashes: List[str] = []
        self.clipboard_404_retries: Dict[str, int] = {}
        self.clipboard_debounce_window = 0.5  # 500ms
        self._pending_clipboard_text: Optional[str] = None
        self._last_clipboard_time = 0.0
        self.synced_clipboard_history: List[str] = []

        # N4 Transfer lifecycle & handle tracking
        self.active_transfers: Dict[str, Dict[str, Any]] = {}
        self.open_file_descriptors: Dict[str, Any] = {}

    # ---------------------------------------------------- F1: Reconnect & Jitter
    def calculate_next_backoff(self) -> float:
        """
        Calculates exponential backoff with ±20% randomized jitter, capped at 30.0s.
        """
        raw = min(self.backoff_current * 2.0, self.backoff_cap)
        jitter = random.uniform(-0.2, 0.2) * raw
        val = max(1.0, min(self.backoff_cap, raw + jitter))
        self.backoff_current = raw
        self.reconnect_attempts += 1
        return val

    def kick_reconnect(self):
        """
        Bypasses any active backoff sleep and triggers immediate reconnection.
        """
        self.kick_reconnect_triggered = True
        self.backoff_current = self.backoff_base
        self.last_reconnect_time = time.time()

    def on_connect_success(self):
        self.connected_ws = True
        self.online = True
        self.backoff_current = self.backoff_base
        self.reconnect_attempts = 0
        self.kick_reconnect_triggered = False

    def on_disconnect(self):
        self.connected_ws = False
        self.online = False
        # Trigger F2 fast-fail
        self.fast_fail_waiters(ConnectionResetError("WebSocket disconnected abruptly"))

    # ---------------------------------------------------- F2: Fast-Fail Waiters
    def register_waiter(self, key: str) -> MockWaiter:
        if not self.connected_ws:
            raise ConnectionError("Cannot register waiter while offline")
        waiter = MockWaiter(key)
        self.waiters[key] = waiter
        return waiter

    def fast_fail_waiters(self, error: Exception):
        count = len(self.waiters)
        for waiter in list(self.waiters.values()):
            waiter.complete_error(error)
        self.waiters.clear()
        self.failed_waiters_count += count

    # ---------------------------------------------------- F3: WebRTC & Relay Fallback
    def start_webrtc_handshake(self, transfer_id: str, session_data: Dict[str, Any], simulate_timeout: bool = False) -> bool:
        if simulate_timeout:
            # Simulate 12s timeout expiration
            self.webrtc_connected = False
            self.fallback_to_relay(transfer_id, session_data)
            return False
        self.webrtc_connected = True
        return True

    def fallback_to_relay(self, transfer_id: str, session_data: Dict[str, Any]):
        self.fallback_to_relay_called = True
        self.last_fallback_session = {
            "transfer_id": transfer_id,
            "route": f"relay:{transfer_id}",
            "session_data": session_data,
            "timestamp": time.time()
        }

    def datachannel_send_chunk(self, chunk_len: int) -> bool:
        if self.datachannel_buffered_amount + chunk_len > self.DATACHANNEL_BUFFER_MAX:
            self.datachannel_paused = True
            return False
        self.datachannel_buffered_amount += chunk_len
        if self.datachannel_buffered_amount >= self.DATACHANNEL_BUFFER_MAX:
            self.datachannel_paused = True
        return True

    def datachannel_on_buffer_drained(self, drained_bytes: int):
        self.datachannel_buffered_amount = max(0, self.datachannel_buffered_amount - drained_bytes)
        if self.datachannel_buffered_amount <= self.DATACHANNEL_BUFFER_LOW_WATERMARK:
            self.datachannel_paused = False

    # ---------------------------------------------------- F4: Dynamic UDP & Bad Route
    def mark_route_bad(self, route_key: str):
        self.bad_routes[route_key] = time.time() + self.bad_penalty_seconds

    def is_route_bad(self, route_key: str) -> bool:
        exp = self.bad_routes.get(route_key)
        if exp is None:
            return False
        if time.time() >= exp:
            del self.bad_routes[route_key]
            return False
        return True

    def on_network_interfaces_changed(self, new_ips: List[str]):
        """
        Dynamically closes existing UDP socket and rebinds to new interfaces.
        """
        self.current_interfaces = list(new_ips)
        self.lan_urls = [f"https://{ip}:53397" for ip in new_ips]
        self.udp_rebind_count += 1

    @staticmethod
    def calculate_broadcast_ip(ip_str: str, netmask_str: str) -> str:
        """
        Calculates directed broadcast address for IPv4 interface.
        Falls back to global LAN broadcast '255.255.255.255' on invalid netmask/IP or mismatch.
        """
        try:
            ip_parts = [int(p) for p in ip_str.split(".")]
            mask_parts = [int(p) for p in netmask_str.split(".")]
            if len(ip_parts) != 4 or len(mask_parts) != 4:
                return "255.255.255.255"
            for p, m in zip(ip_parts, mask_parts):
                if not (0 <= p <= 255 and 0 <= m <= 255):
                    return "255.255.255.255"
            bcast_parts = [(p | (~m & 0xFF)) for p, m in zip(ip_parts, mask_parts)]
            return ".".join(str(p) for p in bcast_parts)
        except Exception:
            return "255.255.255.255"

    # ---------------------------------------------------- F5: Clipboard Throttling & Nonce
    def get_clipboard_error_delay(self, failure_count: int) -> float:
        base_delay = 1.5 * math.pow(1.5, failure_count)
        cap = self.clip_backoff_cap_screen_off if self.screen_off else self.clip_backoff_cap_screen_on
        return min(base_delay, cap)

    def fetch_clipboard_large_text(self, item_id: str, fetch_func: Callable[[], Optional[str]]) -> Optional[str]:
        retries = self.clipboard_404_retries.get(item_id, 0)
        while retries < 3:
            res = fetch_func()
            if res is not None:
                self.clipboard_404_retries.pop(item_id, None)
                return res
            retries += 1
            self.clipboard_404_retries[item_id] = retries
        return None  # Fallback to inline preview after 3 failed retries

    @staticmethod
    def generate_image_filename(timestamp: Optional[float] = None) -> str:
        """Match client names: millisecond stamp plus a counter that does not wrap."""
        t = timestamp if timestamp is not None else time.time()
        dt_struct = time.localtime(t)
        millis = int(round((t % 1) * 1000)) % 1000
        MockSyncDevice._image_nonce += 1
        nonce = f"{MockSyncDevice._image_nonce:04d}"
        date_str = time.strftime("%Y%m%d_%H%M%S", dt_struct)
        return f"IMG_{date_str}_{millis:03d}_{nonce}.png"

    def record_clipboard_echo(self, text: str) -> bool:
        h = hashlib.sha256(text.encode("utf-8")).hexdigest()
        if h in self.clipboard_history_hashes:
            return True  # Is Echo
        self.clipboard_history_hashes.append(h)
        if len(self.clipboard_history_hashes) > 100:
            self.clipboard_history_hashes.pop(0)
        return False

    def enqueue_clipboard_change(self, text: str, timestamp: Optional[float] = None):
        t = timestamp if timestamp is not None else time.time()
        self._pending_clipboard_text = text
        self._last_clipboard_time = t

    def flush_debounced_clipboard(self, timestamp: Optional[float] = None) -> Optional[str]:
        t = timestamp if timestamp is not None else time.time()
        if self._pending_clipboard_text is not None:
            text = self._pending_clipboard_text
            self.synced_clipboard_history.append(text)
            self._last_clipboard_time = t
            self._pending_clipboard_text = None
            return text
        return None

    @classmethod
    def validate_image_payload(cls, payload_len: int) -> Tuple[bool, Optional[str]]:
        if payload_len <= 0:
            return False, "Payload empty"
        if payload_len > cls.MAX_IMAGE_PAYLOAD_BYTES:
            return False, f"Payload {payload_len} bytes exceeds max 20MB limit ({cls.MAX_IMAGE_PAYLOAD_BYTES} bytes)"
        return True, None

    # ---------------------------------------------------- N4: Transfer lifecycle & leak tracking
    def begin_transfer(self, transfer_id: str, total_bytes: int):
        self.active_transfers[transfer_id] = {
            "id": transfer_id,
            "bytes_total": total_bytes,
            "bytes_transferred": 0,
            "state": "transferring"
        }
        self.open_file_descriptors[transfer_id] = f"fd_{transfer_id}"

    def complete_transfer(self, transfer_id: str):
        self.open_file_descriptors.pop(transfer_id, None)
        self.active_transfers.pop(transfer_id, None)
