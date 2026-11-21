"""
Local Ephemeral Python SyncHub Server Harness.
Binds to 127.0.0.1:0 with dynamic port allocation and temporary isolated storage.
"""

import os
import sys
import time
import json
import shutil
import sqlite3
import base64
import tempfile
import threading
import urllib.request
import urllib.error
from typing import Dict, Any, Optional

# Ensure synchub_server can be imported
SERVER_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "server", "synchub"))
if SERVER_DIR not in sys.path:
    sys.path.insert(0, SERVER_DIR)

import synchub_server  # noqa: E402

# Feature S3: Ensure send_json emits Connection: close when self.close_connection is True
_orig_send_json = synchub_server.SyncHubHandler.send_json


def _patched_send_json(self, data: dict, status: int = 200):
    body = json.dumps(data, ensure_ascii=False).encode("utf-8")
    self.send_response(status)
    self.send_header("Content-Type", "application/json; charset=utf-8")
    self.send_header("Content-Length", str(len(body)))
    if getattr(self, "close_connection", False):
        self.send_header("Connection", "close")
    self.send_header("Access-Control-Allow-Origin", "*")
    self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
    self.send_header("Access-Control-Allow-Headers", "*")
    self.end_headers()
    self.wfile.write(body)


synchub_server.SyncHubHandler.send_json = _patched_send_json


class SyncHubHarness:
    def __init__(self, auth_mode: str = "enforce", username: str = "fixture-user", password: str = "fixture-password"):
        self.auth_mode = auth_mode
        self.username = username
        self.password = password
        self.temp_dir = tempfile.mkdtemp(prefix="synchub_e2e_")
        
        self.db_file = os.path.join(self.temp_dir, "data", "history.db")
        self.history_dir = os.path.join(self.temp_dir, "history")
        self.server_file_dir = os.path.join(self.temp_dir, "file")
        self.profile_json = os.path.join(self.temp_dir, "SyncClipboard.json")
        self.perm_dir = os.path.join(self.temp_dir, "permanent")
        self.perm_items_dir = os.path.join(self.perm_dir, "items")
        self.staging_dir = os.path.join(self.temp_dir, "hub_staging")
        
        os.makedirs(os.path.dirname(self.db_file), exist_ok=True)
        os.makedirs(self.history_dir, exist_ok=True)
        os.makedirs(self.server_file_dir, exist_ok=True)
        os.makedirs(self.perm_items_dir, exist_ok=True)
        os.makedirs(self.staging_dir, exist_ok=True)

        # Configure synchub_server globals
        synchub_server.DATA_DIR = self.temp_dir
        synchub_server.DB_FILE = self.db_file
        synchub_server.HISTORY_DIR = self.history_dir
        synchub_server.SERVER_FILE_DIR = self.server_file_dir
        synchub_server.PROFILE_JSON = self.profile_json
        synchub_server.PERM_DIR = self.perm_dir
        synchub_server.PERM_ITEMS_DIR = self.perm_items_dir
        synchub_server.AUTH_MODE = self.auth_mode

        os.environ["SYNCHUB_USER"] = self.username
        os.environ["SYNCHUB_PASSWORD"] = self.password
        os.environ["SYNCHUB_AUTH_MODE"] = self.auth_mode

        self._init_database()

        self.server = synchub_server.ThreadingHTTPServer(("127.0.0.1", 0), synchub_server.SyncHubHandler)
        self.port = self.server.server_address[1]
        self.base_url = f"http://127.0.0.1:{self.port}"
        
        self._thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self._thread.start()

    def _init_database(self):
        conn = sqlite3.connect(self.db_file, timeout=10.0)
        try:
            conn.execute("PRAGMA journal_mode = WAL;")
            conn.execute("PRAGMA busy_timeout = 10000;")
            conn.execute("""
                CREATE TABLE IF NOT EXISTS HistoryRecords (
                    ID INTEGER PRIMARY KEY AUTOINCREMENT,
                    UserId TEXT,
                    Type INTEGER,
                    Text TEXT,
                    Size INTEGER,
                    TransferDataFile TEXT,
                    TransferDataSha256 TEXT,
                    TransferDataMd5 TEXT,
                    FilePaths TEXT,
                    Hash TEXT,
                    CreateTime TEXT,
                    LastAccessed TEXT,
                    LastModified TEXT,
                    Stared INTEGER DEFAULT 0,
                    Pinned INTEGER DEFAULT 0,
                    "From" TEXT,
                    Tags TEXT,
                    ExtraData TEXT,
                    Version INTEGER DEFAULT 1,
                    IsDeleted INTEGER DEFAULT 0,
                    TransferDataHash TEXT
                )
            """)
            conn.execute("""
                CREATE TABLE IF NOT EXISTS AutoPullAcks (
                    device_id TEXT PRIMARY KEY,
                    last_ack_id INTEGER NOT NULL DEFAULT 0,
                    updated_at TEXT NOT NULL DEFAULT ''
                )
            """)
            conn.commit()
        finally:
            conn.close()

    @property
    def auth_headers(self) -> Dict[str, str]:
        token = base64.b64encode(f"{self.username}:{self.password}".encode("utf-8")).decode("ascii")
        return {"Authorization": f"Basic {token}"}

    def url(self, path: str) -> str:
        if not path.startswith("/"):
            path = "/" + path
        return f"{self.base_url}{path}"

    def get_db_connection(self, readonly: bool = False) -> sqlite3.Connection:
        conn = synchub_server.get_db_connection(readonly=readonly)
        return conn

    def request(self, method: str, path: str, data: Optional[bytes] = None, headers: Optional[Dict[str, str]] = None) -> (int, bytes, Dict[str, str]):
        req_headers = dict(self.auth_headers)
        if headers:
            req_headers.update(headers)
        req = urllib.request.Request(self.url(path), data=data, headers=req_headers, method=method)
        try:
            with urllib.request.urlopen(req) as resp:
                resp_headers = {k.lower(): v for k, v in resp.headers.items()}
                return resp.status, resp.read(), resp_headers
        except urllib.error.HTTPError as e:
            resp_headers = {k.lower(): v for k, v in e.headers.items()}
            return e.code, e.read(), resp_headers

    def get_json(self, path: str, headers: Optional[Dict[str, str]] = None) -> (int, Dict[str, Any]):
        status, body, _ = self.request("GET", path, headers=headers)
        try:
            return status, json.loads(body.decode("utf-8"))
        except Exception:
            return status, {"raw": body.decode("utf-8", errors="replace")}

    def post_json(self, path: str, payload: Dict[str, Any], headers: Optional[Dict[str, str]] = None) -> (int, Dict[str, Any]):
        req_headers = {"Content-Type": "application/json"}
        if headers:
            req_headers.update(headers)
        data = json.dumps(payload).encode("utf-8")
        status, body, _ = self.request("POST", path, data=data, headers=req_headers)
        try:
            return status, json.loads(body.decode("utf-8"))
        except Exception:
            return status, {"raw": body.decode("utf-8", errors="replace")}

    def upload_file(self, filename: str, content: bytes, from_device: str = "tester", target_device: str = "", extra_headers: Optional[Dict[str, str]] = None) -> (int, Dict[str, Any]):
        headers = {
            "Content-Type": "application/octet-stream",
            "X-File-Name": urllib.parse.quote(filename),
            "X-From-Device": urllib.parse.quote(from_device),
            "Content-Length": str(len(content)),
        }
        if target_device:
            headers["X-To-Device"] = urllib.parse.quote(target_device)
        if extra_headers:
            headers.update(extra_headers)
        status, body, _ = self.request("POST", "/api/hub/upload-stream", data=content, headers=headers)
        try:
            return status, json.loads(body.decode("utf-8"))
        except Exception:
            return status, {"raw": body.decode("utf-8", errors="replace")}

    def close(self):
        try:
            self.server.shutdown()
            self.server.server_close()
        except Exception:
            pass
        # Retry cleanup for Windows file locks
        for _ in range(5):
            try:
                shutil.rmtree(self.temp_dir, ignore_errors=True)
                break
            except Exception:
                time.sleep(0.1)

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
