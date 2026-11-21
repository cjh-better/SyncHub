"""
Platform Bridge and OS Event Mock Infrastructure for SyncHub-Next.
Simulates:
- N1: Windows WM_CLIPBOARDUPDATE, WM_POWERBROADCAST (PBT_APMSUSPEND, PBT_APMRESUMEAUTOMATIC), WM_WTSSESSION_CHANGE, DPAPI
- N2: macOS NSWorkspace.willSleepNotification, didWakeNotification, App Nap, Keychain
- N3: Android EventChannel push clipboard, WakeLock, Doze mode, Keystore non-destructive deletion
- N4: Lazy crypto isolates (60s idle termination) and Engine ticker pause/resume
"""

import time
import base64
from typing import Dict, Any, Optional, List, Callable


class PlatformEventDispatcher:
    def __init__(self):
        self.handlers: Dict[str, List[Callable[[Dict[str, Any]], None]]] = {}

    def on(self, event_name: str, handler: Callable[[Dict[str, Any]], None]):
        if event_name not in self.handlers:
            self.handlers[event_name] = []
        self.handlers[event_name].append(handler)

    def emit(self, event_name: str, payload: Dict[str, Any]):
        for handler in self.handlers.get(event_name, []):
            handler(payload)


class WindowsPlatformMock:
    def __init__(self, dispatcher: PlatformEventDispatcher):
        self.dispatcher = dispatcher
        self.clipboard_listener_active = False
        self.clipboard_seq = 100
        self.power_state = "awake"
        self.session_locked = False
        self.dpapi_store: Dict[str, bytes] = {}
        self.uipi_filters: Dict[int, bool] = {}
        self.integrity_level = "medium"

    def set_integrity_level(self, level: str):
        self.integrity_level = level

    def change_window_message_filter_ex(self, message_id: int, allow: bool = True):
        self.uipi_filters[message_id] = allow

    def can_receive_window_message(self, message_id: int, sender_integrity: str = "medium") -> bool:
        if self.integrity_level == "high" and sender_integrity == "medium":
            return self.uipi_filters.get(message_id, False)
        return True

    def dispatch_uipi_message(self, message_id: int, payload: Dict[str, Any], sender_integrity: str = "medium") -> bool:
        if not self.can_receive_window_message(message_id, sender_integrity=sender_integrity):
            return False
        self.dispatcher.emit("uipi_message_received", {"message": message_id, "payload": payload})
        return True

    def add_clipboard_format_listener(self):
        self.clipboard_listener_active = True

    def simulate_clipboard_update(self, new_seq: Optional[int] = None):
        if not self.clipboard_listener_active:
            return
        if new_seq is not None:
            self.clipboard_seq = new_seq
        else:
            self.clipboard_seq += 1
        self.dispatcher.emit("clipboard_changed", {"seq": self.clipboard_seq})

    def simulate_power_broadcast(self, event_type: str):
        # event_type: 'suspend' (PBT_APMSUSPEND) or 'resume' (PBT_APMRESUMEAUTOMATIC)
        if event_type == "suspend":
            self.power_state = "sleeping"
            self.dispatcher.emit("system_event", {"event": "sleep"})
        elif event_type == "resume":
            self.power_state = "awake"
            self.dispatcher.emit("system_event", {"event": "wake"})

    def simulate_session_change(self, locked: bool):
        self.session_locked = locked
        self.dispatcher.emit("system_event", {"event": "lock" if locked else "unlock"})

    def dpapi_encrypt(self, key: str, plaintext: str) -> str:
        # Mock DPAPI CryptProtectData
        encoded = base64.b64encode(plaintext.encode("utf-8")).decode("ascii")
        self.dpapi_store[key] = f"dpapi:{encoded}".encode("utf-8")
        return f"dpapi:{encoded}"

    def dpapi_decrypt(self, key: str) -> Optional[str]:
        val = self.dpapi_store.get(key)
        if not val or not val.startswith(b"dpapi:"):
            return None
        body = val[6:]
        return base64.b64decode(body).decode("utf-8")


class MacOSPlatformMock:
    def __init__(self, dispatcher: PlatformEventDispatcher):
        self.dispatcher = dispatcher
        self.power_state = "awake"
        self.app_nap_enabled = True
        self.keychain_store: Dict[str, str] = {}
        self.menu_cache: Dict[str, Any] = {"status": "idle", "updated_at": time.time()}
        self.window_visible = True
        self.active_transfers_count = 0
        self.timer_interval = 0.75

    def update_app_nap_state(self, window_visible: bool, active_transfers: int):
        self.window_visible = window_visible
        self.active_transfers_count = active_transfers
        if not window_visible and active_transfers == 0:
            self.app_nap_enabled = True
            self.timer_interval = 10.0
        else:
            self.app_nap_enabled = False
            self.timer_interval = 0.75

    def set_menu_status(self, status: str):
        self.menu_cache = {"status": status, "updated_at": time.time()}

    def get_menu_status_fast(self) -> Dict[str, Any]:
        return dict(self.menu_cache)

    def simulate_will_sleep(self):
        self.power_state = "sleeping"
        self.dispatcher.emit("system_event", {"event": "sleep"})

    def simulate_did_wake(self):
        self.power_state = "awake"
        self.dispatcher.emit("system_event", {"event": "wake"})

    def keychain_save(self, key: str, value: str):
        self.keychain_store[key] = value

    def keychain_load(self, key: str) -> Optional[str]:
        return self.keychain_store.get(key)


class AndroidPlatformMock:
    def __init__(self, dispatcher: PlatformEventDispatcher):
        self.dispatcher = dispatcher
        self.wakelock_held = False
        self.wakelock_acquired_at = 0.0
        self.doze_mode = False
        self.secure_store: Dict[str, str] = {}
        self.root_daemon_alive = True
        self.active_listener = "root_daemon"
        self.permission_grants: Dict[str, bool] = {}

    def simulate_root_daemon_crash(self):
        self.root_daemon_alive = False
        self.active_listener = "foreground_service"
        self.dispatcher.emit("listener_fallback", {"listener": "foreground_service"})

    def grant_uri_permission(self, uri: str):
        self.permission_grants[uri] = True

    def revoke_uri_permission(self, uri: str):
        self.permission_grants[uri] = False

    def read_content_uri(self, uri: str) -> bytes:
        if not self.permission_grants.get(uri, False):
            raise PermissionError(f"SecurityException: Permission Denial: reading {uri}")
        return b"PNG_IMAGE_BYTES"

    def simulate_event_channel_clipboard(self, item_type: str, payload: Any):
        # item_type: 'clipboard_text' or 'clipboard_image'
        self.dispatcher.emit("android_push_clipboard", {
            "type": item_type,
            "data": payload,
            "timestamp": time.time()
        })

    def acquire_wakelock(self):
        self.wakelock_held = True
        self.wakelock_acquired_at = time.time()

    def release_wakelock(self):
        self.wakelock_held = False
        self.wakelock_acquired_at = 0.0

    def simulate_doze_mode(self, active: bool):
        self.doze_mode = active
        self.dispatcher.emit("doze_mode_changed", {"doze": active})

    def secure_store_put(self, key: str, value: str):
        self.secure_store[key] = value

    def secure_store_delete_single_key(self, key: str):
        # Feature N3 Bug Fix: delete only single key, never wipe the whole store (clear())
        self.secure_store.pop(key, None)

    def secure_store_get(self, key: str) -> Optional[str]:
        return self.secure_store.get(key)


class CryptoPoolMock:
    def __init__(self, max_workers: int = 4, idle_timeout: float = 60.0):
        self.max_workers = max_workers
        self.idle_timeout = idle_timeout
        self.active_workers = 0
        self.last_used = time.time()

    def process_job(self, data: bytes) -> bytes:
        if self.active_workers == 0:
            # Lazy spawn
            self.active_workers = min(self.max_workers, 2)
        self.last_used = time.time()
        import hashlib
        return hashlib.sha256(data).digest()

    def check_idle_reap(self, current_time: Optional[float] = None) -> bool:
        t = current_time if current_time is not None else time.time()
        if self.active_workers > 0 and (t - self.last_used) >= self.idle_timeout:
            self.active_workers = 0
            return True
        return False


class EngineTickerMock:
    def __init__(self):
        self.is_paused = False
        self.scan_count = 0

    def tick(self, active_transfers: int, pending_syncs: int):
        if active_transfers == 0 and pending_syncs == 0:
            self.is_paused = True
            return
        self.is_paused = False
        self.scan_count += 1
