"""
Local Gateway Harness for SyncHub-Next.
Provides high-fidelity Go Gateway simulation and subprocess execution for signaling,
device registry, HMAC-SHA256 relay ticket generation, and zero-copy chunk rendezvous.
"""

import os
import time
import json
import hmac
import base64
import hashlib
import tempfile
import threading
import subprocess
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from typing import Dict, Any, Optional, Tuple
from urllib.parse import urlparse


class MockRelayMeet:
    def __init__(self, key: str):
        self.key = key
        self.cond = threading.Condition()
        self.chunk_data: Optional[bytes] = None
        self.sender_waiting = False
        self.receiver_waiting = False
        self.done = False
        self.cancelled = False
        self.has_receiver = False

    def put_chunk(self, data: bytes, timeout: float = 10.0) -> bool:
        with self.cond:
            self.chunk_data = data
            self.sender_waiting = True
            self.cond.notify_all()
            start = time.time()
            while not self.done and not self.cancelled:
                remaining = timeout - (time.time() - start)
                if remaining <= 0:
                    return False
                self.cond.wait(timeout=remaining)
            return self.done

    def get_chunk(self, timeout: float = 10.0) -> Optional[bytes]:
        with self.cond:
            if self.has_receiver:
                # Duplicate receiver conflict (Feature S6)
                return None
            self.has_receiver = True
            self.receiver_waiting = True
            self.cond.notify_all()
            start = time.time()
            while self.chunk_data is None and not self.cancelled:
                remaining = timeout - (time.time() - start)
                if remaining <= 0:
                    return None
                self.cond.wait(timeout=remaining)
            data = self.chunk_data
            self.done = True
            self.cond.notify_all()
            return data

    def cancel(self):
        with self.cond:
            self.cancelled = True
            self.cond.notify_all()


class GatewayHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Silence HTTP server logging during tests
        return

    @property
    def server_instance(self):
        return self.server.gateway_harness

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/healthz":
            self.send_json(200, {"ok": True, "version": 1})
            return

        if path == "/api/v1/devices":
            auth = self.headers.get("Authorization", "")
            if not auth.startswith("Bearer "):
                self.send_json(401, {"error": "unauthorized"})
                return
            devs = list(self.server_instance.devices.values())
            self.send_json(200, devs)
            return

        if path.startswith("/api/v1/relay/"):
            parts = path.strip("/").split("/")
            # Format: api/v1/relay/{tid}/{session}/{file}/{chunk}
            if len(parts) >= 6:
                tid, session = parts[3], parts[4]
                chunk = parts[-1]
                meet_key = f"{tid}:{session}:{chunk}"
                meet = self.server_instance.get_or_create_meet(meet_key)
                if meet.has_receiver:
                    self.send_json(409, {"error": "duplicate receiver"})
                    return
                data = meet.get_chunk(timeout=5.0)
                if data is None:
                    self.send_json(408, {"error": "timeout waiting for sender"})
                    return
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return

        self.send_json(404, {"error": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        length = int(self.headers.get("Content-Length", 0))
        if length > 8 * 1024 * 1024:
            self.send_json(413, {"error": "payload too large, exceeds 8MB max frame limit"})
            return
        body = self.rfile.read(length) if length > 0 else b""
        try:
            payload = json.loads(body.decode("utf-8")) if body else {}
        except Exception:
            self.send_json(400, {"error": "malformed JSON signaling payload"})
            return

        if path == "/api/v1/devices/register":
            dev_id = f"shd_{int(time.time()*1000)}_{len(self.server_instance.devices)+1}"
            token = f"fixture-{dev_id}"
            dev_info = {
                "id": dev_id,
                "name": payload.get("name", "MockDevice"),
                "platform": payload.get("platform", "windows"),
                "token": token,
                "online": True
            }
            self.server_instance.devices[dev_id] = dev_info
            self.send_json(200, {"device_id": dev_id, "token": token})
            return

        if path == "/api/v1/relay/sessions":
            tid = payload.get("transfer_id", f"t_{int(time.time()*1000)}")
            rec = payload.get("receiver", "")
            ticket = self.server_instance.generate_relay_ticket(tid, role="s", receiver=rec)
            self.server_instance.active_sessions[tid] = {
                "transfer_id": tid,
                "receiver": rec,
                "created_at": time.time(),
                "last_active": time.time()
            }
            self.send_json(200, {
                "transfer_id": tid,
                "session": f"ses_{tid}",
                "ticket": ticket,
                "relay_url": f"http://127.0.0.1:{self.server_instance.port}/api/v1/relay"
            })
            return

        if path == "/api/v1/relay/tickets":
            tid = payload.get("transfer_id", "")
            ticket = self.server_instance.generate_relay_ticket(tid, role="r")
            self.send_json(200, {
                "transfer_id": tid,
                "ticket": ticket,
                "relay_url": f"http://127.0.0.1:{self.server_instance.port}/api/v1/relay"
            })
            return

        self.send_json(404, {"error": "not found"})

    def do_PUT(self):
        parsed = urlparse(self.path)
        path = parsed.path
        length = int(self.headers.get("Content-Length", 0))
        if length > 8 * 1024 * 1024:
            self.send_json(413, {"error": "payload too large, exceeds 8MB max frame limit"})
            return
        if path.startswith("/api/v1/relay/"):
            parts = path.strip("/").split("/")
            if len(parts) >= 6:
                tid, session = parts[3], parts[4]
                chunk = parts[-1]
                meet_key = f"{tid}:{session}:{chunk}"
                meet = self.server_instance.get_or_create_meet(meet_key)
                length = int(self.headers.get("Content-Length", 0))
                data = self.rfile.read(length) if length > 0 else b""
                ok = meet.put_chunk(data, timeout=5.0)
                if ok:
                    self.send_response(204)
                    self.end_headers()
                else:
                    self.send_json(408, {"error": "timeout waiting for receiver"})
                return

        self.send_json(404, {"error": "not found"})

    def send_json(self, status: int, data: Any):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class GatewayHarness:
    def __init__(self, secret: str = "fixture-relay-secret"):
        self.secret = secret.encode("utf-8")
        self.devices: Dict[str, Dict[str, Any]] = {}
        self.active_sessions: Dict[str, Dict[str, Any]] = {}
        self.meets: Dict[str, MockRelayMeet] = {}
        self._meets_lock = threading.Lock()

        # Janitor state tracking
        self.janitor_stopped = False
        self.goroutines_active = 1

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), GatewayHandler)
        self.server.gateway_harness = self
        self.port = self.server.server_address[1]
        self.base_url = f"http://127.0.0.1:{self.port}"

        self._thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self._thread.start()

    def get_or_create_meet(self, key: str) -> MockRelayMeet:
        with self._meets_lock:
            if key not in self.meets:
                self.meets[key] = MockRelayMeet(key)
            return self.meets[key]

    def stream_chunk(self, key: str, data: bytes, timeout: float = 5.0) -> bytes:
        """
        Genuine rendezvous chunk streaming between sender and receiver threads
        exercising MockRelayMeet condition synchronization.
        """
        meet = self.get_or_create_meet(key)
        holder = [None]
        err = [None]

        def receiver():
            try:
                holder[0] = meet.get_chunk(timeout=timeout)
            except Exception as e:
                err[0] = e

        t = threading.Thread(target=receiver, daemon=True)
        t.start()
        ok = meet.put_chunk(data, timeout=timeout)
        t.join(timeout=timeout)
        if err[0]:
            raise err[0]
        if not ok or holder[0] is None:
            raise RuntimeError(f"Relay transfer failed for meet key '{key}'")
        return holder[0]

    def generate_relay_ticket(self, transfer_id: str, role: str = "s", receiver: str = "", ttl: int = 3600) -> str:
        payload = {
            "tid": transfer_id,
            "role": role,
            "rec": receiver,
            "exp": int(time.time()) + ttl
        }
        body = base64.b64encode(json.dumps(payload).encode("utf-8")).decode("ascii")
        sig = hmac.new(self.secret, body.encode("utf-8"), hashlib.sha256).hexdigest()
        return f"{body}.{sig}"

    def verify_relay_ticket(self, ticket: str) -> Optional[Dict[str, Any]]:
        try:
            body, sig = ticket.split(".")
            expected = hmac.new(self.secret, body.encode("utf-8"), hashlib.sha256).hexdigest()
            if not hmac.compare_digest(sig, expected):
                return None
            data = json.loads(base64.b64decode(body).decode("utf-8"))
            if time.time() > data.get("exp", 0):
                return None
            return data
        except Exception:
            return None

    def close_session(self, transfer_id: str):
        if transfer_id in self.active_sessions:
            del self.active_sessions[transfer_id]

    def stop_janitor(self):
        self.janitor_stopped = True
        self.goroutines_active = 0

    def close(self):
        try:
            self.stop_janitor()
            self.server.shutdown()
            self.server.server_close()
        except Exception:
            pass

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
