#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SyncHub Cross-Platform File & Clipboard Transfer Center
Integrates directly with SyncClipboard's SQLite database (history.db) and file storage.
Features:
- Streaming upload/download up to 1GB+ (e.g. 500MB files) with minimal RAM footprint
- Auto-classification (文档, 视频, 压缩包, 图片, 安装包, 音频, 文本, 其他) + manual category override
- 3-day (72-hour) auto-expiration for normal items; Permanent retention for Starred (收藏) or Pinned (置顶) items
- Instant single/batch delete
- Three-platform auto-receive polling endpoint (Windows K:\跨端传输文件, Android /sdcard/Download/跨端传输, Mac ~/Downloads/跨端传输文件)
- Modern responsive WebApp / PWA (/hub/), protected by HTTP Basic auth (same account as SyncClipboard)
"""

import os
import sys
import json
import time
import shutil
import sqlite3
import hashlib
import hmac
import base64
import binascii
import urllib.parse
import mimetypes
import threading
from datetime import datetime, timezone, timedelta
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

DATA_DIR = "/opt/stacks/syncclipboard/data"
DB_FILE = os.path.join(DATA_DIR, "server", "data", "history.db")
HISTORY_DIR = os.path.join(DATA_DIR, "server", "history")
SERVER_FILE_DIR = os.path.join(DATA_DIR, "server", "file")
PROFILE_JSON = os.path.join(DATA_DIR, "server", "SyncClipboard.json")
PERM_DIR = os.path.join(DATA_DIR, "permanent")
PERM_ITEMS_DIR = os.path.join(PERM_DIR, "items")

RETENTION_HOURS = 72  # 3 days (72 hours) for normal (unstarred & unpinned) items
PORT = 5034

TYPE_MAP = {0: "Text", 1: "File", 2: "Image", 3: "Group"}

CATEGORY_RULES = [
    ("文档", {
        ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".txt", ".md",
        ".csv", ".rtf", ".epub", ".odt", ".ods", ".odp", ".pages", ".numbers", ".key",
        ".json", ".xml", ".yaml", ".yml", ".sql", ".log", ".ini", ".conf", ".py",
        ".js", ".ts", ".html", ".css", ".sh", ".ps1", ".bat", ".c", ".cpp", ".h",
        ".java", ".go", ".rs", ".php", ".rb", ".tex", ".bib"
    }),
    ("视频", {
        ".mp4", ".mkv", ".mov", ".avi", ".webm", ".flv", ".wmv", ".m4v", ".ts",
        ".rmvb", ".3gp", ".mpg", ".mpeg", ".vob", ".ogv"
    }),
    ("压缩包", {
        ".zip", ".rar", ".7z", ".tar", ".gz", ".tgz", ".bz2", ".xz", ".iso",
        ".cab", ".zst", ".lz4", ".ace", ".jar", ".war"
    }),
    ("图片", {
        ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".bmp", ".ico",
        ".heic", ".heif", ".tiff", ".tif", ".psd", ".ai", ".raw", ".cr2", ".nef"
    }),
    ("安装包", {
        ".apk", ".ipa", ".exe", ".msi", ".dmg", ".pkg", ".deb", ".rpm",
        ".appimage", ".hap", ".xapk", ".apks"
    }),
    ("音频", {
        ".mp3", ".wav", ".flac", ".aac", ".ogg", ".m4a", ".wma", ".opus", ".ape", ".mid"
    }),
]

VALID_CATEGORIES = ["文档", "视频", "压缩包", "图片", "安装包", "音频", "文本", "其他"]


def detect_category(item_type: int, filename_or_text: str) -> str:
    if item_type == 0:
        return "文本"
    if item_type == 2:
        return "图片"
    ext = os.path.splitext(filename_or_text or "")[1].lower()
    for cat, exts in CATEGORY_RULES:
        if ext in exts:
            return cat
    return "其他"


def parse_tags(tags_str: str):
    if not tags_str:
        return []
    try:
        val = json.loads(tags_str)
        if isinstance(val, list):
            return [str(x) for x in val if x]
    except Exception:
        pass
    return []


def parse_extra(extra_str: str):
    if not extra_str:
        return {}
    try:
        val = json.loads(extra_str)
        if isinstance(val, dict):
            return val
    except Exception:
        pass
    return {}


def get_db_connection(readonly=False):
    os.makedirs(os.path.dirname(DB_FILE), exist_ok=True)
    if readonly and os.path.exists(DB_FILE):
        conn = sqlite3.connect(f"file:{DB_FILE}?mode=ro", uri=True, timeout=15.0)
    else:
        conn = sqlite3.connect(DB_FILE, timeout=15.0)
    conn.row_factory = sqlite3.Row
    return conn


def parse_create_time(ts_str: str) -> datetime:
    if not ts_str:
        return datetime.now(timezone.utc)
    s = ts_str.strip().replace("T", " ").rstrip("Z")
    if "+" in s:
        s = s.split("+")[0].strip()
    if "." in s:
        main_part, frac = s.split(".", 1)
        frac = (frac + "000000")[:6]
        s = f"{main_part}.{frac}"
        fmt = "%Y-%m-%d %H:%M:%S.%f"
    else:
        fmt = "%Y-%m-%d %H:%M:%S"
    try:
        dt = datetime.strptime(s, fmt)
        return dt.replace(tzinfo=timezone.utc)
    except Exception:
        return datetime.now(timezone.utc)


def format_db_time(dt: datetime = None) -> str:
    if dt is None:
        dt = datetime.now(timezone.utc)
    return dt.strftime("%Y-%m-%d %H:%M:%S.%f") + "0"


def resolve_record_file_path(row_dict: dict):
    """Find the physical file on disk for a File/Image/Text record."""
    item_type = row_dict.get("Type", 0)
    type_str = TYPE_MAP.get(item_type, "File")
    h = row_dict.get("Hash", "")
    fname = row_dict.get("TransferDataFile") or row_dict.get("Text") or ""
    fname_base = os.path.basename(fname)

    candidates = []
    if h and fname_base:
        candidates.append(os.path.join(HISTORY_DIR, f"{type_str}_{h}", fname_base))
        candidates.append(os.path.join(PERM_ITEMS_DIR, f"{type_str}_{h}", fname_base))
    if fname and os.path.isabs(fname):
        candidates.append(fname)
    if fname_base:
        candidates.append(os.path.join(SERVER_FILE_DIR, fname_base))
        candidates.append(os.path.join(DATA_DIR, "file", fname_base))

    for c in candidates:
        if os.path.isfile(c):
            return c

    # Fallback: scan folder <type_str>_<h> for any file
    for base_dir in (HISTORY_DIR, PERM_ITEMS_DIR):
        folder = os.path.join(base_dir, f"{type_str}_{h}")
        if os.path.isdir(folder):
            for entry in os.listdir(folder):
                full_p = os.path.join(folder, entry)
                if os.path.isfile(full_p):
                    return full_p
    return None


def enrich_row(r: sqlite3.Row) -> dict:
    d = dict(r)
    item_type = d.get("Type", 0)
    fname_or_text = d.get("TransferDataFile") or d.get("Text") or ""
    tags = parse_tags(d.get("Tags", "[]"))
    extra = parse_extra(d.get("ExtraData", ""))

    cat = extra.get("category")
    if not cat:
        for t in tags:
            if t in VALID_CATEGORIES:
                cat = t
                break
    if not cat:
        cat = detect_category(item_type, fname_or_text)

    dt_created = parse_create_time(d.get("CreateTime", ""))
    dt_local = dt_created.astimezone(timezone(timedelta(hours=8)))
    now_utc = datetime.now(timezone.utc)

    is_permanent = bool(d.get("Stared", 0) or d.get("Pinned", 0))
    expires_at = dt_created + timedelta(hours=RETENTION_HOURS)
    remaining_sec = max(0, int((expires_at - now_utc).total_seconds()))

    file_path = resolve_record_file_path(d) if item_type in (1, 2) else None
    has_file = file_path is not None and os.path.isfile(file_path)
    actual_size = d.get("Size", 0)
    if has_file and actual_size <= 0:
        try:
            actual_size = os.path.getsize(file_path)
        except Exception:
            pass

    filename = os.path.basename(d.get("TransferDataFile") or d.get("Text") or f"item_{d['ID']}")
    return {
        "id": d["ID"],
        "type": item_type,
        "typeName": TYPE_MAP.get(item_type, "File"),
        "text": d.get("Text", ""),
        "filename": filename if item_type in (1, 2) else "",
        "size": actual_size,
        "hash": d.get("Hash", ""),
        "createTimeUtc": dt_created.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "createTimeLocal": dt_local.strftime("%Y-%m-%d %H:%M:%S"),
        "starred": bool(d.get("Stared", 0)),
        "pinned": bool(d.get("Pinned", 0)),
        "isPermanent": is_permanent,
        "remainingSeconds": None if is_permanent else remaining_sec,
        "fromDevice": d.get("From") or extra.get("source_device") or "Clipboard",
        "category": cat,
        "tags": tags,
        "hasFile": has_file,
        "downloadUrl": f"/api/hub/download/{d['ID']}/{urllib.parse.quote(filename)}" if item_type in (1, 2) else None,
    }


def trigger_permanent_sync():
    try:
        os.system("/usr/local/bin/syncclipboard-permanent-vault.sh >/dev/null 2>&1 &")
    except Exception:
        pass


def cleanup_expired_items():
    """Purge unstarred & unpinned items older than RETENTION_HOURS (72h = 3 days)."""
    if not os.path.exists(DB_FILE):
        return 0
    cutoff_dt = datetime.now(timezone.utc) - timedelta(hours=RETENTION_HOURS)
    cutoff_str = format_db_time(cutoff_dt)
    purged = 0
    try:
        conn = get_db_connection(readonly=False)
        cur = conn.cursor()
        cur.execute(
            "SELECT ID, Type, Hash FROM HistoryRecords "
            "WHERE IsDeleted = 0 AND Stared = 0 AND Pinned = 0 AND CreateTime < ?",
            (cutoff_str,)
        )
        expired_rows = cur.fetchall()
        for r in expired_rows:
            t_str = TYPE_MAP.get(r["Type"], "File")
            folder = os.path.join(HISTORY_DIR, f"{t_str}_{r['Hash']}")
            if os.path.isdir(folder):
                shutil.rmtree(folder, ignore_errors=True)
            cur.execute("UPDATE HistoryRecords SET IsDeleted = 1 WHERE ID = ?", (r["ID"],))
            purged += 1
        if purged > 0:
            conn.commit()
        conn.close()
    except Exception as e:
        print(f"[Cleanup Error] {e}", file=sys.stderr)
    return purged


def background_cleaner_loop():
    while True:
        try:
            cleanup_expired_items()
        except Exception:
            pass
        time.sleep(600)


# ---------------------------------------------------------------------------
# 访问认证：/hub/ 网页与全部 /api/hub/* 接口要求 HTTP Basic 认证，
# 账号密码与 SyncClipboard 服务端一致。读取顺序：
#   1) 环境变量 SYNCHUB_USER / SYNCHUB_PASSWORD（例如写在 systemd EnvironmentFile 里）
#   2) SyncClipboard 的 docker compose 文件里的 SYNCCLIPBOARD_USERNAME / SYNCCLIPBOARD_PASSWORD
#      （按修改时间缓存；在 compose 里改了密码并重建容器后，这里会自动跟着生效）
# 读不到账号时一律拒绝访问（fail closed）。
# SYNCHUB_AUTH_MODE=log 时只记录未认证请求而不拦截，仅用于排查客户端。
# ---------------------------------------------------------------------------
AUTH_REALM = "SyncHub"
AUTH_MODE = os.environ.get("SYNCHUB_AUTH_MODE", "enforce").strip().lower()
SYNCCLIPBOARD_COMPOSE_FILES = [
    p for p in [
        os.environ.get("SYNCHUB_COMPOSE_FILE", ""),
        os.path.join(os.path.dirname(DATA_DIR), "compose.yaml"),
        os.path.join(os.path.dirname(DATA_DIR), "compose.yml"),
        os.path.join(os.path.dirname(DATA_DIR), "docker-compose.yml"),
        os.path.join(os.path.dirname(DATA_DIR), "docker-compose.yaml"),
    ] if p
]
# 无需登录的路径：只有 CORS 预检和不含任何数据的 PWA manifest
PUBLIC_PATHS = {"/hub/manifest.json"}

_cred_lock = threading.Lock()
_cred_cache = {"key": None, "value": None}
_auth_log_seen = {}


def _parse_compose_credentials(text: str):
    vals = {}
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("#"):
            continue
        if line.startswith("- "):
            line = line[2:].strip()
        m = None
        for key in ("SYNCCLIPBOARD_USERNAME", "SYNCCLIPBOARD_PASSWORD"):
            for sep in ("=", ":"):
                prefix = key + sep
                if line.startswith(prefix) or line.startswith('"' + prefix) or line.startswith("'" + prefix):
                    m = (key, line.split(sep, 1)[1].strip())
                    break
            if m:
                break
        if not m:
            continue
        key, val = m
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
            val = val[1:-1]
        elif val and val[-1] in "\"'":
            val = val[:-1]
        vals[key] = val
    u, p = vals.get("SYNCCLIPBOARD_USERNAME"), vals.get("SYNCCLIPBOARD_PASSWORD")
    return (u, p) if u and p else None


def get_hub_credentials():
    """Return (username, password) or None. Never log the result."""
    env_u, env_p = os.environ.get("SYNCHUB_USER", ""), os.environ.get("SYNCHUB_PASSWORD", "")
    if env_u and env_p:
        return env_u, env_p
    for path in SYNCCLIPBOARD_COMPOSE_FILES:
        try:
            st = os.stat(path)
        except OSError:
            continue
        key = (path, st.st_mtime_ns, st.st_size)
        with _cred_lock:
            if _cred_cache["key"] == key:
                if _cred_cache["value"]:
                    return _cred_cache["value"]
                continue
        try:
            with open(path, "r", encoding="utf-8") as f:
                val = _parse_compose_credentials(f.read())
        except Exception:
            val = None
        with _cred_lock:
            _cred_cache["key"], _cred_cache["value"] = key, val
        if val:
            return val
    return None


def check_basic_auth(header_value) -> bool:
    creds = get_hub_credentials()
    if not creds or not header_value:
        return False
    parts = header_value.strip().split(None, 1)
    if len(parts) != 2 or parts[0].lower() != "basic":
        return False
    try:
        decoded = base64.b64decode(parts[1].strip(), validate=True)
    except (binascii.Error, ValueError):
        return False
    expected = ("%s:%s" % creds).encode("utf-8")
    return hmac.compare_digest(decoded, expected)


class SyncHubHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        pass

    def send_json(self, data: dict, status: int = 200):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.end_headers()
        self.wfile.write(body)

    def require_auth(self) -> bool:
        """True if the request may proceed; otherwise a 401 has been sent."""
        path = urllib.parse.urlparse(self.path).path
        if path in PUBLIC_PATHS:
            return True
        if check_basic_auth(self.headers.get("Authorization")):
            return True
        if AUTH_MODE == "log":
            sys.stderr.write("[auth-log] unauthenticated %s %s ua=%r ip=%s\n" % (
                self.command, path, self.headers.get("User-Agent", ""),
                self.headers.get("X-Real-IP") or self.client_address[0]))
            sys.stderr.flush()
            return True
        ip = self.headers.get("X-Real-IP") or self.client_address[0]
        ua = (self.headers.get("User-Agent", "") or "")[:80]
        now = time.time()
        with _cred_lock:
            last = _auth_log_seen.get((ip, ua), 0)
            if now - last > 600:
                _auth_log_seen[(ip, ua)] = now
                if len(_auth_log_seen) > 1000:
                    _auth_log_seen.clear()
                sys.stderr.write("[auth] 401 %s %s ua=%r ip=%s (同一来源 10 分钟内只记一次)\n" % (
                    self.command, path, ua, ip))
                sys.stderr.flush()
        body = json.dumps({"ok": False, "error": "Unauthorized"}).encode("utf-8")
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="%s", charset="UTF-8"' % AUTH_REALM)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        # 请求体（比如上传的文件）不再读取，直接关闭连接
        self.send_header("Connection", "close")
        self.close_connection = True
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        return False

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if not self.require_auth():
            return
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        qs = urllib.parse.parse_qs(parsed.query)

        if path in ("/hub", "/hub/", "/hub/index.html"):
            self.serve_webapp()
            return

        if path == "/hub/manifest.json":
            manifest = {
                "name": "跨端传输与收藏中心 (SyncHub)",
                "short_name": "跨端传输",
                "start_url": "/hub/",
                "display": "standalone",
                "background_color": "#F5F5F7",
                "theme_color": "#F5F5F7",
                "icons": [{
                    "src": "data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><rect width='100' height='100' rx='22' fill='%23007AFF'/><text y='.88em' font-size='64' x='16'>🚀</text></svg>",
                    "sizes": "192x192",
                    "type": "image/svg+xml"
                }]
            }
            self.send_json(manifest)
            return

        if path == "/api/hub/items":
            self.handle_list_items(qs)
            return

        if path == "/api/hub/auto-pull":
            self.handle_auto_pull(qs)
            return

        if path.startswith("/api/hub/download/"):
            self.handle_download(path, qs)
            return

        if path == "/api/hub/client/mac.sh":
            self.serve_script(MAC_INSTALLER_SCRIPT, "install_mac_synchub.sh")
            return

        if path == "/api/hub/client/android_root.sh":
            self.serve_script(ANDROID_ROOT_SCRIPT, "install_android_synchub.sh")
            return

        self.send_json({"error": "Not found", "path": path}, 404)

    def do_POST(self):
        if not self.require_auth():
            return
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        qs = urllib.parse.parse_qs(parsed.query)

        if path in ("/api/hub/upload", "/api/hub/upload-stream"):
            self.handle_upload_stream(qs)
            return

        if path == "/api/hub/text":
            self.handle_post_text()
            return

        if path.startswith("/api/hub/item/") and path.endswith("/update"):
            parts = path.strip("/").split("/")
            if len(parts) >= 4 and parts[3].isdigit():
                self.handle_update_item(int(parts[3]))
                return

        if path.startswith("/api/hub/item/") and path.endswith("/delete"):
            parts = path.strip("/").split("/")
            if len(parts) >= 4 and parts[3].isdigit():
                self.handle_delete_item(int(parts[3]))
                return

        if path == "/api/hub/batch-delete":
            self.handle_batch_delete()
            return

        self.send_json({"error": "Not found"}, 404)

    def do_PUT(self):
        if not self.require_auth():
            return
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path in ("/api/hub/upload", "/api/hub/upload-stream"):
            qs = urllib.parse.parse_qs(parsed.query)
            self.handle_upload_stream(qs)
            return
        self.send_json({"error": "Not found"}, 404)

    def do_DELETE(self):
        if not self.require_auth():
            return
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        if path.startswith("/api/hub/item/"):
            parts = path.strip("/").split("/")
            if len(parts) >= 4 and parts[3].isdigit():
                self.handle_delete_item(int(parts[3]))
                return
        self.send_json({"error": "Not found"}, 404)

    def handle_list_items(self, qs):
        cat_filter = qs.get("category", [""])[0].strip()
        search_q = qs.get("q", [""])[0].strip().lower()
        only_starred = qs.get("starred", [""])[0] == "1"
        only_pinned = qs.get("pinned", [""])[0] == "1"
        limit = min(500, int(qs.get("limit", ["200"])[0] or 200))

        conn = get_db_connection(readonly=True)
        cur = conn.cursor()
        cur.execute(
            "SELECT * FROM HistoryRecords WHERE IsDeleted = 0 "
            "ORDER BY Pinned DESC, ID DESC LIMIT ?",
            (limit,)
        )
        rows = cur.fetchall()
        conn.close()

        items = []
        counts = {c: 0 for c in VALID_CATEGORIES}
        counts["全部"] = 0
        counts["收藏"] = 0
        counts["置顶"] = 0

        for r in rows:
            item = enrich_row(r)
            counts["全部"] += 1
            if item["starred"]:
                counts["收藏"] += 1
            if item["pinned"]:
                counts["置顶"] += 1
            c_name = item["category"]
            counts[c_name] = counts.get(c_name, 0) + 1

            if only_starred and not item["starred"]:
                continue
            if only_pinned and not item["pinned"]:
                continue
            if cat_filter and cat_filter not in ("全部", "all") and item["category"] != cat_filter:
                continue
            if search_q:
                haystack = f"{item['filename']} {item['text']} {item['category']} {item['fromDevice']}".lower()
                if search_q not in haystack:
                    continue
            items.append(item)

        self.send_json({
            "ok": True,
            "retentionHours": RETENTION_HOURS,
            "counts": counts,
            "items": items
        })

    def handle_auto_pull(self, qs):
        device = (qs.get("device", [""])[0] or "").strip().lower()
        since_id = int(qs.get("since_id", ["0"])[0] or 0)

        conn = get_db_connection(readonly=True)
        cur = conn.cursor()
        if since_id <= 0:
            cur.execute("SELECT COALESCE(MAX(ID), 0) AS max_id FROM HistoryRecords")
            max_id = cur.fetchone()["max_id"]
            conn.close()
            self.send_json({"ok": True, "latestId": max_id, "items": []})
            return

        cur.execute(
            "SELECT * FROM HistoryRecords WHERE IsDeleted = 0 AND ID > ? ORDER BY ID ASC LIMIT 50",
            (since_id,)
        )
        rows = cur.fetchall()
        conn.close()

        latest_id = since_id
        pull_items = []
        for r in rows:
            item = enrich_row(r)
            if item["id"] > latest_id:
                latest_id = item["id"]
            if item["type"] in (1, 2) and item["hasFile"]:
                sender = (item["fromDevice"] or "").strip().lower()
                if not device or sender != device:
                    pull_items.append(item)

        self.send_json({
            "ok": True,
            "latestId": latest_id,
            "items": pull_items
        })

    def handle_upload_stream(self, qs):
        raw_filename = (
            qs.get("filename", [""])[0]
            or self.headers.get("X-File-Name", "")
            or f"upload_{int(time.time())}.bin"
        )
        filename = os.path.basename(urllib.parse.unquote(raw_filename)).strip()
        if not filename:
            filename = f"upload_{int(time.time())}.bin"

        from_device = (
            qs.get("from", [""])[0]
            or self.headers.get("X-From-Device", "")
            or "Web"
        ).strip()
        starred = 1 if (qs.get("starred", ["0"])[0] == "1" or self.headers.get("X-Starred") == "1") else 0
        pinned = 1 if (qs.get("pinned", ["0"])[0] == "1" or self.headers.get("X-Pinned") == "1") else 0
        custom_cat = (qs.get("category", [""])[0] or self.headers.get("X-Category", "")).strip()

        content_length = int(self.headers.get("Content-Length", "0") or 0)
        ext = os.path.splitext(filename)[1].lower()
        is_image = ext in {".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg", ".ico", ".heic"}
        item_type = 2 if is_image else 1
        type_str = TYPE_MAP[item_type]

        category = custom_cat if custom_cat in VALID_CATEGORIES else detect_category(item_type, filename)

        staging_dir = os.path.join(DATA_DIR, "hub_staging")
        os.makedirs(staging_dir, exist_ok=True)
        temp_path = os.path.join(staging_dir, f"tmp_{int(time.time()*1000)}_{os.getpid()}_{filename}")

        sha256_hasher = hashlib.sha256()
        md5_hasher = hashlib.md5()
        bytes_written = 0

        try:
            with open(temp_path, "wb") as out_f:
                remaining = content_length
                while remaining > 0:
                    chunk_size = min(1024 * 1024, remaining)
                    chunk = self.rfile.read(chunk_size)
                    if not chunk:
                        break
                    out_f.write(chunk)
                    sha256_hasher.update(chunk)
                    md5_hasher.update(chunk)
                    bytes_written += len(chunk)
                    remaining -= len(chunk)
        except Exception as e:
            if os.path.exists(temp_path):
                os.remove(temp_path)
            self.send_json({"ok": False, "error": f"Upload interrupted: {e}"}, 500)
            return

        file_sha256 = sha256_hasher.hexdigest().upper()
        file_md5 = md5_hasher.hexdigest().upper()
        # Unique record hash combining file hash + timestamp if needed, or file_sha256
        record_hash = hashlib.sha256(f"{file_sha256}:{filename}:{int(time.time())}".encode("utf-8")).hexdigest().upper()

        dest_folder = os.path.join(HISTORY_DIR, f"{type_str}_{record_hash}")
        os.makedirs(dest_folder, exist_ok=True)
        dest_path = os.path.join(dest_folder, filename)
        shutil.move(temp_path, dest_path)

        now_str = format_db_time()
        tags_json = json.dumps([category], ensure_ascii=False)
        extra_json = json.dumps({
            "category": category,
            "source_device": from_device,
            "auto_push": True
        }, ensure_ascii=False)
        file_paths_json = json.dumps([filename], ensure_ascii=False)

        conn = get_db_connection(readonly=False)
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO HistoryRecords (
                UserId, Type, Text, Size, TransferDataFile,
                TransferDataSha256, TransferDataMd5, FilePaths, Hash,
                CreateTime, LastAccessed, LastModified,
                Stared, Pinned, "From", Tags, ExtraData, Version, IsDeleted, TransferDataHash
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 0, ?)
            """,
            (
                "default_user", item_type, filename, bytes_written, filename,
                file_sha256, file_md5, file_paths_json, record_hash,
                now_str, now_str, now_str,
                starred, pinned, from_device, tags_json, extra_json, file_sha256
            )
        )
        new_id = cur.lastrowid
        conn.commit()
        cur.execute("SELECT * FROM HistoryRecords WHERE ID = ?", (new_id,))
        row = cur.fetchone()
        conn.close()

        if starred or pinned:
            trigger_permanent_sync()

        self.send_json({"ok": True, "item": enrich_row(row)})

    def handle_post_text(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(length).decode("utf-8", errors="replace") if length > 0 else "{}"
        try:
            body = json.loads(raw)
        except Exception:
            self.send_json({"ok": False, "error": "Invalid JSON"}, 400)
            return

        text = (body.get("text") or "").strip()
        if not text:
            self.send_json({"ok": False, "error": "Empty text"}, 400)
            return

        from_device = (body.get("from") or "Web").strip()
        starred = 1 if body.get("starred") else 0
        pinned = 1 if body.get("pinned") else 0
        category = body.get("category") if body.get("category") in VALID_CATEGORIES else "文本"
        sync_clipboard = body.get("syncClipboard", True)

        text_bytes = text.encode("utf-8")
        text_sha256 = hashlib.sha256(text_bytes).hexdigest().upper()
        text_md5 = hashlib.md5(text_bytes).hexdigest().upper()
        now_str = format_db_time()

        dest_folder = os.path.join(HISTORY_DIR, f"Text_{text_sha256}")
        os.makedirs(dest_folder, exist_ok=True)
        txt_filename = f"Text_{text_sha256[:16]}.txt"
        with open(os.path.join(dest_folder, txt_filename), "w", encoding="utf-8") as f:
            f.write(text)

        tags_json = json.dumps([category], ensure_ascii=False)
        extra_json = json.dumps({
            "category": category,
            "source_device": from_device
        }, ensure_ascii=False)

        conn = get_db_connection(readonly=False)
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO HistoryRecords (
                UserId, Type, Text, Size, TransferDataFile,
                TransferDataSha256, TransferDataMd5, FilePaths, Hash,
                CreateTime, LastAccessed, LastModified,
                Stared, Pinned, "From", Tags, ExtraData, Version, IsDeleted, TransferDataHash
            ) VALUES (?, 0, ?, ?, ?, ?, ?, '[]', ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 0, '')
            """,
            (
                "default_user", text, len(text_bytes), txt_filename,
                text_sha256, text_md5, text_sha256,
                now_str, now_str, now_str,
                starred, pinned, from_device, tags_json, extra_json
            )
        )
        new_id = cur.lastrowid
        conn.commit()
        cur.execute("SELECT * FROM HistoryRecords WHERE ID = ?", (new_id,))
        row = cur.fetchone()
        conn.close()

        # Also update SyncClipboard.json so all devices' clipboards sync this text immediately
        if sync_clipboard:
            try:
                profile_data = {
                    "Type": "Text",
                    "Hash": text_sha256,
                    "Text": text,
                    "HasData": False,
                    "DataName": "",
                    "TransferDataHash": "",
                    "Size": len(text_bytes),
                    "SyncedAt": datetime.now(timezone.utc).isoformat()
                }
                with open(PROFILE_JSON, "w", encoding="utf-8") as pf:
                    json.dump(profile_data, pf, ensure_ascii=False)
            except Exception:
                pass

        if starred or pinned:
            trigger_permanent_sync()

        self.send_json({"ok": True, "item": enrich_row(row)})

    def handle_update_item(self, item_id: int):
        length = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(length).decode("utf-8", errors="replace") if length > 0 else "{}"
        try:
            body = json.loads(raw)
        except Exception:
            self.send_json({"ok": False, "error": "Invalid JSON"}, 400)
            return

        conn = get_db_connection(readonly=False)
        cur = conn.cursor()
        cur.execute("SELECT * FROM HistoryRecords WHERE ID = ? AND IsDeleted = 0", (item_id,))
        row = cur.fetchone()
        if not row:
            conn.close()
            self.send_json({"ok": False, "error": "Item not found"}, 404)
            return

        d = dict(row)
        starred = int(bool(body["starred"])) if "starred" in body else d["Stared"]
        pinned = int(bool(body["pinned"])) if "pinned" in body else d["Pinned"]
        tags = parse_tags(d.get("Tags", "[]"))
        extra = parse_extra(d.get("ExtraData", ""))

        if "category" in body and body["category"] in VALID_CATEGORIES:
            cat = body["category"]
            extra["category"] = cat
            tags = [cat] + [t for t in tags if t not in VALID_CATEGORIES]

        now_str = format_db_time()
        cur.execute(
            """
            UPDATE HistoryRecords
            SET Stared = ?, Pinned = ?, Tags = ?, ExtraData = ?, LastModified = ?
            WHERE ID = ?
            """,
            (
                starred,
                pinned,
                json.dumps(tags, ensure_ascii=False),
                json.dumps(extra, ensure_ascii=False),
                now_str,
                item_id,
            )
        )
        conn.commit()
        cur.execute("SELECT * FROM HistoryRecords WHERE ID = ?", (item_id,))
        updated_row = cur.fetchone()
        conn.close()

        trigger_permanent_sync()
        self.send_json({"ok": True, "item": enrich_row(updated_row)})

    def _delete_single_id(self, cur, item_id: int):
        cur.execute("SELECT ID, Type, Hash FROM HistoryRecords WHERE ID = ?", (item_id,))
        row = cur.fetchone()
        if not row:
            return False
        t_str = TYPE_MAP.get(row["Type"], "File")
        h = row["Hash"]
        for base in (HISTORY_DIR, PERM_ITEMS_DIR):
            folder = os.path.join(base, f"{t_str}_{h}")
            if os.path.isdir(folder):
                shutil.rmtree(folder, ignore_errors=True)
        cur.execute("UPDATE HistoryRecords SET IsDeleted = 1, Stared = 0, Pinned = 0 WHERE ID = ?", (item_id,))
        return True

    def handle_delete_item(self, item_id: int):
        conn = get_db_connection(readonly=False)
        cur = conn.cursor()
        self._delete_single_id(cur, item_id)
        conn.commit()
        conn.close()
        trigger_permanent_sync()
        self.send_json({"ok": True, "deletedId": item_id})

    def handle_batch_delete(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(length).decode("utf-8", errors="replace") if length > 0 else "{}"
        try:
            body = json.loads(raw)
        except Exception:
            self.send_json({"ok": False, "error": "Invalid JSON"}, 400)
            return

        ids = body.get("ids") or []
        mode = body.get("mode") or ""
        conn = get_db_connection(readonly=False)
        cur = conn.cursor()
        deleted_count = 0

        if mode == "unstarred":
            cur.execute("SELECT ID FROM HistoryRecords WHERE IsDeleted = 0 AND Stared = 0 AND Pinned = 0")
            ids = [r["ID"] for r in cur.fetchall()]

        for i in ids:
            if isinstance(i, int) or (isinstance(i, str) and i.isdigit()):
                if self._delete_single_id(cur, int(i)):
                    deleted_count += 1
        conn.commit()
        conn.close()
        trigger_permanent_sync()
        self.send_json({"ok": True, "deletedCount": deleted_count})

    def handle_download(self, path: str, qs: dict):
        parts = path.strip("/").split("/")
        if len(parts) < 4 or not parts[3].isdigit():
            self.send_json({"error": "Invalid item ID"}, 400)
            return
        item_id = int(parts[3])
        conn = get_db_connection(readonly=True)
        cur = conn.cursor()
        cur.execute("SELECT * FROM HistoryRecords WHERE ID = ? AND IsDeleted = 0", (item_id,))
        row = cur.fetchone()
        conn.close()
        if not row:
            self.send_json({"error": "Item not found"}, 404)
            return

        d = dict(row)
        file_path = resolve_record_file_path(d)
        if not file_path or not os.path.isfile(file_path):
            self.send_json({"error": "Physical file not found on server"}, 404)
            return

        filename = os.path.basename(file_path)
        file_size = os.path.getsize(file_path)
        mime_type, _ = mimetypes.guess_type(filename)
        if not mime_type:
            mime_type = "application/octet-stream"

        inline = qs.get("inline", ["0"])[0] == "1"
        disp_type = "inline" if inline else "attachment"
        encoded_fname = urllib.parse.quote(filename)

        range_header = self.headers.get("Range")
        start_byte = 0
        end_byte = file_size - 1
        status_code = 200

        if range_header and range_header.startswith("bytes="):
            try:
                r_part = range_header.split("=", 1)[1].split(",")[0].strip()
                s_str, e_str = r_part.split("-", 1)
                if s_str:
                    start_byte = int(s_str)
                if e_str:
                    end_byte = min(file_size - 1, int(e_str))
                if 0 <= start_byte <= end_byte < file_size:
                    status_code = 206
            except Exception:
                pass

        content_len = end_byte - start_byte + 1
        self.send_response(status_code)
        self.send_header("Content-Type", mime_type)
        self.send_header("Content-Length", str(content_len))
        self.send_header("Accept-Ranges", "bytes")
        if status_code == 206:
            self.send_header("Content-Range", f"bytes {start_byte}-{end_byte}/{file_size}")
        self.send_header("Content-Disposition", f"{disp_type}; filename*=UTF-8''{encoded_fname}")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()

        with open(file_path, "rb") as f:
            f.seek(start_byte)
            rem = content_len
            while rem > 0:
                chunk = f.read(min(1024 * 1024, rem))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    break
                rem -= len(chunk)

    def serve_script(self, content: str, filename: str):
        # 下发给客户端的脚本里的账号密码来自环境变量，源码中不保存真实凭据
        creds = get_hub_credentials() or ("", "")
        content = (content.replace("__SYNCHUB_USER__", creds[0])
                          .replace("__SYNCHUB_PASSWORD__", creds[1]))
        body = content.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/x-shellscript; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Disposition", f"attachment; filename=\"{filename}\"")
        self.end_headers()
        self.wfile.write(body)

    def serve_webapp(self):
        body = WEBAPP_HTML.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)


MAC_INSTALLER_SCRIPT = r"""#!/usr/bin/env bash
# ==============================================================================
# SyncHub macOS One-Click Installer (Windows <-> Mac <-> Android Three-Way Sync)
# Sets up:
#   1. ~/Downloads/跨端传输文件 (and Desktop shortcut alias)
#   2. Background Auto-Receiver Daemon (LaunchAgent) -> saves incoming files automatically
#   3. Finder Right-Click Quick Action ("发送到跨端传输 (Windows/手机)")
# ==============================================================================
set -e

SERVER_URL="https://020814.xyz"
AUTH_USER="__SYNCHUB_USER__"
AUTH_PASS="__SYNCHUB_PASSWORD__"
RECV_DIR="$HOME/Downloads/跨端传输文件"
APP_DIR="$HOME/.synchub"

mkdir -p "$RECV_DIR" "$APP_DIR"
ln -sfn "$RECV_DIR" "$HOME/Desktop/跨端传输文件"

cat > "$APP_DIR/synchub_mac_daemon.py" << 'PYEOF'
#!/usr/bin/env python3
import os, sys, time, json, urllib.request, urllib.parse, base64, subprocess

SERVER_URL = "https://020814.xyz"
AUTH = base64.b64encode(b"__SYNCHUB_USER__:__SYNCHUB_PASSWORD__").decode("ascii")
RECV_DIR = os.path.expanduser("~/Downloads/跨端传输文件")
STATE_FILE = os.path.expanduser("~/.synchub/last_id.txt")

os.makedirs(RECV_DIR, exist_ok=True)

def notify(title, msg):
    try:
         subprocess.run(["osascript", "-e", f'display notification "{msg}" with title "{title}"'], check=False)
    except Exception:
        pass

def get_last_id():
    if os.path.exists(STATE_FILE):
        try:
            return int(open(STATE_FILE).read().strip())
        except Exception:
            pass
    return 0

def set_last_id(val):
    with open(STATE_FILE, "w") as f:
        f.write(str(val))

def poll_once():
    last_id = get_last_id()
    url = f"{SERVER_URL}/api/hub/auto-pull?device=mac&since_id={last_id}"
    req = urllib.request.Request(url, headers={"Authorization": f"Basic {AUTH}"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    if not data.get("ok"):
        return
    for item in data.get("items", []):
        dl_url = SERVER_URL + item["downloadUrl"]
        fname = item["filename"] or f"file_{item['id']}"
        dest = os.path.join(RECV_DIR, fname)
        if os.path.exists(dest) and os.path.getsize(dest) == item.get("size", -1):
            continue
        dl_req = urllib.request.Request(dl_url, headers={"Authorization": f"Basic {AUTH}"})
        with urllib.request.urlopen(dl_req, timeout=600) as r, open(dest + ".part", "wb") as out:
            while True:
                chunk = r.read(1024 * 1024)
                if not chunk:
                    break
                out.write(chunk)
        os.replace(dest + ".part", dest)
        notify("📥 跨端传输已自动保存", f"来自 {item.get('fromDevice','其他设备')}: {fname}")
    if data.get("latestId", 0) > last_id:
        set_last_id(data["latestId"])

if __name__ == "__main__":
    while True:
        try:
            poll_once()
        except Exception:
            pass
        time.sleep(3)
PYEOF
chmod +x "$APP_DIR/synchub_mac_daemon.py"

cat > "$APP_DIR/synchub_send.sh" << 'SHEOF'
#!/usr/bin/env bash
for f in "$@"; do
    [ -f "$f" ] || continue
    fname=$(python3 -c 'import os,sys,urllib.parse; print(urllib.parse.quote(os.path.basename(sys.argv[1])))' "$f")
    osascript -e "display notification \"正在上传: $(basename "$f")\" with title \"🚀 跨端传输\""
    curl -sS -u "__SYNCHUB_USER__:__SYNCHUB_PASSWORD__" -X POST \
        --data-binary @"$f" \
        "https://020814.xyz/api/hub/upload?filename=${fname}&from=Mac" >/dev/null
    osascript -e "display notification \"已发送至 Windows 与手机: $(basename "$f")\" with title \"✅ 跨端传输完成\""
done
SHEOF
chmod +x "$APP_DIR/synchub_send.sh"

PLIST="$HOME/Library/LaunchAgents/xyz.020814.synchub.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>xyz.020814.synchub</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$APP_DIR/synchub_mac_daemon.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

# Create macOS Finder Quick Action (Right-Click -> 快速操作 -> 📲 发送到跨端传输)
WF_DIR="$HOME/Library/Services/📲 发送到跨端传输 (Windows与手机).workflow/Contents"
mkdir -p "$WF_DIR"
cat > "$WF_DIR/Info.plist" << 'WFI'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSServices</key>
	<array>
		<dict>
			<key>NSMenuItem</key>
			<dict>
				<key>default</key>
				<string>📲 发送到跨端传输 (Windows与手机)</string>
			</dict>
			<key>NSMessage</key>
			<string>runWorkflowAsService</string>
			<key>NSSendFileTypes</key>
			<array>
				<string>public.item</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
WFI

cat > "$WF_DIR/document.wflow" << 'WFD'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AMApplicationBuild</key>
	<string>523</string>
	<key>AMApplicationVersion</key>
	<string>2.10</string>
	<key>AMDocumentVersion</key>
	<string>2</string>
	<key>actions</key>
	<array>
		<dict>
			<key>action</key>
			<dict>
				<key>AMAccepts</key>
				<dict>
					<key>Container</key>
					<string>List</string>
					<key>Optional</key>
					<true/>
					<key>Types</key>
					<array>
						<string>com.apple.cocoa.string</string>
					</array>
				</dict>
				<key>AMActionVersion</key>
				<string>2.0.3</string>
				<key>AMApplication</key>
				<array>
					<string>Automator</string>
				</array>
				<key>AMParameterProperties</key>
				<dict>
					<key>COMMAND_STRING</key>
					<dict/>
					<key>CheckedForUserDefaultShell</key>
					<dict/>
					<key>inputMethod</key>
					<dict/>
					<key>shell</key>
					<dict/>
					<key>source</key>
					<dict/>
				</dict>
				<key>AMProvides</key>
				<dict>
					<key>Container</key>
					<string>List</string>
					<key>Types</key>
					<array>
						<string>com.apple.cocoa.string</string>
					</array>
				</dict>
				<key>ActionBundlePath</key>
				<string>/System/Library/Automator/Run Shell Script.action</string>
				<key>ActionName</key>
				<string>Run Shell Script</string>
				<key>ActionParameters</key>
				<dict>
					<key>COMMAND_STRING</key>
					<string>"$HOME/.synchub/synchub_send.sh" "$@"</string>
					<key>CheckedForUserDefaultShell</key>
					<true/>
					<key>inputMethod</key>
					<integer>1</integer>
					<key>shell</key>
					<string>/bin/bash</string>
					<key>source</key>
					<string></string>
				</dict>
			</dict>
		</dict>
	</array>
	<key>connectors</key>
	<dict/>
	<key>workflowMetaData</key>
	<dict>
		<key>applicationBundleIDsByPath</key>
		<dict/>
		<key>applicationPaths</key>
		<array/>
		<key>inputTypeIdentifier</key>
		<string>com.apple.Automator.fileSystemObject</string>
		<key>outputTypeIdentifier</key>
		<string>com.apple.Automator.nothing</string>
		<key>presentationMode</key>
		<integer>15</integer>
		<key>processesInput</key>
		<integer>0</integer>
		<key>serviceInputTypeIdentifier</key>
		<string>com.apple.Automator.fileSystemObject</string>
		<key>serviceOutputTypeIdentifier</key>
		<string>com.apple.Automator.nothing</string>
		<key>serviceProcessesInput</key>
		<integer>0</integer>
		<key>systemImageName</key>
		<string>NSActionTemplate</string>
		<key>useAutomaticInputType</key>
		<integer>0</integer>
		<key>workflowTypeIdentifier</key>
		<string>com.apple.Automator.servicesMenu</string>
	</dict>
</dict>
</plist>
WFD
/System/Library/CoreServices/pbs -update 2>/dev/null || true

echo "✅ Mac 跨端传输自动接收服务与 Finder 右键菜单已全部安装完成！"
echo "📂 自动接收目录: $RECV_DIR (已在 Mac 桌面创建【跨端传输文件】快捷方式)"
echo "🖱️ 发送方式: 在 Finder 右键任意文件 -> 快速操作 -> 【📲 发送到跨端传输 (Windows与手机)】"
"""


ANDROID_ROOT_SCRIPT = r"""#!/system/bin/sh
# ==============================================================================
# SyncHub Android Root Auto-Receiver Daemon (Magisk / KernelSU / APatch service.d)
# Automatically saves files sent from Windows PC or Mac directly into:
#   /sdcard/Download/跨端传输/
# Installation on Rooted Android:
#   su -c "curl -sSL -u 用户名:密码 https://020814.xyz/api/hub/client/android_root.sh -o /data/adb/service.d/synchub_android.sh && chmod 755 /data/adb/service.d/synchub_android.sh && /data/adb/service.d/synchub_android.sh &"
# ==============================================================================

SERVER_URL="https://020814.xyz"
AUTH="__SYNCHUB_USER__:__SYNCHUB_PASSWORD__"
SAVE_DIR="/sdcard/Download/跨端传输"
STATE_FILE="/data/adb/synchub_last_id"

while [ ! -d "/sdcard/Download" ]; do
    sleep 3
done

mkdir -p "$SAVE_DIR"

LAST_ID=0
if [ -f "$STATE_FILE" ]; then
    LAST_ID=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
fi

while true; do
    RESP=$(curl -sS -m 15 -u "$AUTH" "${SERVER_URL}/api/hub/auto-pull?device=android&since_id=${LAST_ID}" 2>/dev/null)
    if echo "$RESP" | grep -q '"ok": true'; then
        NEW_ID=$(echo "$RESP" | sed -n 's/.*"latestId": *\([0-9]*\).*/\1/p')
        # Parse downloadUrl entries if any
        echo "$RESP" | tr '{' '\n' | grep '"downloadUrl":' | while read -r line; do
            DL_PATH=$(echo "$line" | sed -n 's/.*"downloadUrl": *"\([^"]*\)".*/\1/p')
            FNAME=$(echo "$line" | sed -n 's/.*"filename": *"\([^"]*\)".*/\1/p')
            if [ -n "$DL_PATH" ] && [ -n "$FNAME" ]; then
                TARGET="${SAVE_DIR}/${FNAME}"
                if [ ! -f "$TARGET" ]; then
                    curl -sS -L -u "$AUTH" "${SERVER_URL}${DL_PATH}" -o "${TARGET}.part" && mv "${TARGET}.part" "$TARGET"
                    am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://${TARGET}" >/dev/null 2>&1
                    cmd notification post -S bigtext -t "📥 跨端传输已保存至 Download" "SyncHub" "文件已自动存入: Download/跨端传输/${FNAME}" >/dev/null 2>&1 || true
                fi
            fi
        done
        if [ -n "$NEW_ID" ] && [ "$NEW_ID" -gt "$LAST_ID" ] 2>/dev/null; then
            LAST_ID="$NEW_ID"
            echo "$LAST_ID" > "$STATE_FILE"
        fi
    fi
    sleep 4
done
"""


WEBAPP_HTML = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
<title>SyncHub · 跨端传输与收藏</title>
<link rel="manifest" href="/hub/manifest.json">
<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><rect width='100' height='100' rx='24' fill='%23007AFF'/><path d='M30 56l20-22 20 22M50 36v34' stroke='white' stroke-width='9' fill='none' stroke-linecap='round' stroke-linejoin='round'/></svg>">
<meta name="theme-color" content="#F5F5F7">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="default">
<style>
:root {
  --bg: #FFFFFF;
  --sidebar: #F5F5F7;
  --fill: #F2F2F7;
  --fill-2: #E9E9EE;
  --hover: rgba(0, 0, 0, 0.04);
  --hair: rgba(0, 0, 0, 0.09);
  --hair-strong: rgba(0, 0, 0, 0.14);
  --text: #1D1D1F;
  --text-2: #6E6E73;
  --text-3: #8E8E93;
  --accent: #007AFF;
  --accent-hover: #0068DA;
  --accent-soft: rgba(0, 122, 255, 0.10);
  --star: #FF9F0A;
  --warn: #C76A00;
  --warn-soft: rgba(255, 149, 0, 0.12);
  --danger: #FF3B30;
  --danger-soft: rgba(255, 59, 48, 0.10);
  --radius: 10px;
  --radius-lg: 14px;
  --sidebar-w: 236px;
  --font: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
  --mono: "SF Mono", ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
}
* { box-sizing: border-box; margin: 0; padding: 0; -webkit-tap-highlight-color: transparent; }
html, body { height: 100%; }
body {
  font-family: var(--font); font-size: 13px; line-height: 1.45; color: var(--text);
  background: var(--bg); -webkit-font-smoothing: antialiased; -moz-osx-font-smoothing: grayscale;
}
button, input, select, textarea { font: inherit; color: inherit; }
button { cursor: pointer; background: none; border: none; }
svg.i { width: 16px; height: 16px; flex-shrink: 0; fill: none; stroke: currentColor; stroke-width: 1.7; stroke-linecap: round; stroke-linejoin: round; }
.tabular { font-variant-numeric: tabular-nums; }
.hidden { display: none !important; }
:focus-visible { outline: 2px solid rgba(0, 122, 255, 0.55); outline-offset: 1px; }

/* ---------- Layout ---------- */
.app { display: flex; height: 100vh; height: 100dvh; }
.sidebar {
  width: var(--sidebar-w); flex-shrink: 0; background: var(--sidebar);
  border-right: 1px solid var(--hair); display: flex; flex-direction: column;
  padding: 18px 10px 12px; overflow-y: auto;
}
.brand { display: flex; align-items: center; gap: 9px; padding: 2px 8px 14px; }
.brand-mark { width: 26px; height: 26px; border-radius: 7px; background: var(--accent); color: #fff; display: grid; place-items: center; }
.brand-mark svg { width: 15px; height: 15px; stroke-width: 2.2; }
.brand-name { font-size: 14px; font-weight: 600; letter-spacing: -0.01em; }
.brand-sub { font-size: 11px; color: var(--text-3); }
.search {
  position: relative; margin: 0 4px 14px;
}
.search svg { position: absolute; left: 9px; top: 50%; transform: translateY(-50%); width: 14px; height: 14px; color: var(--text-3); pointer-events: none; }
.search input {
  width: 100%; height: 30px; border-radius: 8px; border: 1px solid transparent;
  background: rgba(0, 0, 0, 0.055); padding: 0 28px 0 29px; font-size: 13px; outline: none;
}
.search input::placeholder { color: var(--text-3); }
.search input:focus { background: #fff; border-color: var(--accent); box-shadow: 0 0 0 3px var(--accent-soft); }
.search .clear { position: absolute; right: 6px; top: 50%; transform: translateY(-50%); width: 18px; height: 18px; border-radius: 50%; display: none; place-items: center; color: var(--text-3); }
.search .clear svg { position: static; transform: none; width: 12px; height: 12px; }
.search.has-q .clear { display: grid; }
.search .kbd { position: absolute; right: 8px; top: 50%; transform: translateY(-50%); font-size: 10.5px; color: var(--text-3); border: 1px solid var(--hair-strong); border-radius: 4px; padding: 0 4px; line-height: 15px; }
.search.has-q .kbd, .search input:focus ~ .kbd { display: none; }

.nav-section { font-size: 11px; font-weight: 600; color: var(--text-3); padding: 10px 10px 4px; letter-spacing: 0.02em; }
.nav-item {
  width: 100%; display: flex; align-items: center; gap: 9px; height: 30px; padding: 0 10px;
  border-radius: 7px; font-size: 13px; color: var(--text); text-align: left;
}
.nav-item:hover { background: var(--hover); }
.nav-item.active { background: rgba(0, 0, 0, 0.075); font-weight: 500; }
.nav-item svg { color: var(--accent); width: 16px; height: 16px; }
.nav-item .count { margin-left: auto; font-size: 12px; color: var(--text-3); font-variant-numeric: tabular-nums; }
.nav-item.dim { color: var(--text-3); }
.nav-item.warn-item svg { color: #FF9500; }
.sidebar-foot { margin-top: auto; padding-top: 14px; border-top: 1px solid var(--hair); display: flex; flex-direction: column; gap: 2px; }
.sidebar-foot .nav-item { color: var(--text-2); font-size: 12.5px; height: 28px; }
.sidebar-foot .nav-item svg { color: var(--text-2); }
.sidebar-foot .nav-item.danger:hover { color: var(--danger); background: var(--danger-soft); }
.sidebar-foot .nav-item.danger:hover svg { color: var(--danger); }
.conn { display: flex; align-items: center; gap: 7px; font-size: 11.5px; color: var(--text-3); padding: 8px 10px 0; }
.conn .dot { width: 7px; height: 7px; border-radius: 50%; background: #34C759; }
.conn.off .dot { background: var(--danger); }
.retention-note { font-size: 11.5px; color: var(--text-3); padding: 4px 10px 6px; line-height: 1.5; }

.main { flex: 1; min-width: 0; display: flex; flex-direction: column; overflow-y: auto; }
.main-inner { width: 100%; max-width: 1040px; margin: 0 auto; padding: 22px 32px 120px; }

/* ---------- Mobile top bar ---------- */
.mbar { display: none; }

/* ---------- Composer ---------- */
.composer {
  border: 1px solid var(--hair-strong); border-radius: var(--radius-lg); background: #fff;
  transition: border-color .15s, box-shadow .15s;
}
.composer:focus-within { border-color: var(--accent); box-shadow: 0 0 0 3px var(--accent-soft); }
.composer textarea {
  display: block; width: 100%; border: none; outline: none; resize: none; background: transparent;
  padding: 13px 15px 6px; font-size: 14px; line-height: 1.55; min-height: 50px; max-height: 240px;
}
.composer textarea::placeholder { color: var(--text-3); }
.composer-bar { display: flex; align-items: center; gap: 6px; padding: 6px 8px 8px 10px; flex-wrap: wrap; }
.composer-bar .spacer { flex: 1; }
.hint { font-size: 11.5px; color: var(--text-3); }

.btn {
  display: inline-flex; align-items: center; justify-content: center; gap: 6px; height: 28px; padding: 0 11px;
  border-radius: 7px; font-size: 13px; font-weight: 500; color: var(--text); background: #fff;
  border: 1px solid var(--hair-strong); white-space: nowrap; text-decoration: none; user-select: none;
  transition: background .12s, border-color .12s, color .12s;
}
.btn:hover { background: var(--fill); }
.btn:active { background: var(--fill-2); }
.btn[disabled] { opacity: .45; pointer-events: none; }
.btn.primary { background: var(--accent); border-color: var(--accent); color: #fff; }
.btn.primary:hover { background: var(--accent-hover); border-color: var(--accent-hover); }
.btn.plain { border-color: transparent; background: transparent; color: var(--text-2); }
.btn.plain:hover { background: var(--hover); color: var(--text); }
.btn.danger { color: var(--danger); }
.btn.danger-fill { background: var(--danger); border-color: var(--danger); color: #fff; }
.btn.danger-fill:hover { background: #E0352B; }
.btn svg.i { width: 15px; height: 15px; }

.opt {
  display: inline-flex; align-items: center; gap: 5px; height: 26px; padding: 0 9px; border-radius: 999px;
  font-size: 12px; color: var(--text-2); border: 1px solid var(--hair); background: #fff; user-select: none;
}
.opt:hover { background: var(--fill); }
.opt svg.i { width: 13px; height: 13px; }
.opt[aria-pressed="true"] { color: var(--accent); background: var(--accent-soft); border-color: transparent; }
.opt.star[aria-pressed="true"] { color: var(--warn); background: var(--warn-soft); }
.opt select { border: none; background: transparent; outline: none; font-size: 12px; color: var(--text-2); cursor: pointer; padding-right: 2px; }

/* ---------- Toolbar ---------- */
.toolbar { display: flex; align-items: flex-end; justify-content: space-between; gap: 12px; margin: 26px 0 10px; flex-wrap: wrap; }
.view-title { font-size: 20px; font-weight: 600; letter-spacing: -0.02em; }
.view-sub { font-size: 12px; color: var(--text-3); margin-top: 2px; }
.toolbar-right { display: flex; align-items: center; gap: 6px; }
.seg { display: inline-flex; background: var(--fill); border-radius: 7px; padding: 2px; }
.seg button { width: 30px; height: 24px; border-radius: 5px; display: grid; place-items: center; color: var(--text-2); }
.seg button.on { background: #fff; color: var(--text); box-shadow: 0 0 0 1px var(--hair); }
.seg svg.i { width: 15px; height: 15px; }
.bulkbar { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
.bulkbar .n { font-size: 13px; color: var(--text-2); margin-right: 4px; }

/* ---------- List ---------- */
.list { border-top: 1px solid var(--hair); }
.row {
  display: flex; align-items: center; gap: 12px; padding: 10px 8px; border-bottom: 1px solid var(--hair);
  position: relative; outline: none; cursor: default; border-radius: 0;
}
.row:hover { background: #FAFAFB; }
.row:focus-visible { background: var(--accent-soft); outline: none; }
.row.sel { background: var(--accent-soft); }
.chk { width: 18px; height: 18px; border-radius: 50%; border: 1.5px solid var(--hair-strong); flex-shrink: 0; display: grid; place-items: center; background: #fff; }
.row.sel .chk, .card.sel .chk { background: var(--accent); border-color: var(--accent); color: #fff; }
.chk svg { width: 11px; height: 11px; stroke-width: 2.6; opacity: 0; }
.row.sel .chk svg, .card.sel .chk svg { opacity: 1; }

.ficon {
  width: 38px; height: 38px; border-radius: 9px; flex-shrink: 0; display: flex; flex-direction: column;
  align-items: center; justify-content: center; gap: 1px; background: var(--fill); color: var(--text-2); cursor: pointer;
}
.ficon svg.i { width: 17px; height: 17px; }
.ficon .ext { font-size: 8.5px; font-weight: 600; letter-spacing: .03em; line-height: 1; }
.ficon.c-doc { background: #E8F1FE; color: #0A64D8; }
.ficon.c-vid { background: #F2EAFB; color: #8944C6; }
.ficon.c-zip { background: #FFF2E0; color: #C26A00; }
.ficon.c-img { background: #FDEBEE; color: #D2334F; }
.ficon.c-app { background: #E7F6EA; color: #23883A; }
.ficon.c-aud { background: #EDEDFC; color: #5452C9; }
.ficon.c-txt { background: #E6F5F4; color: #0D8A82; }
.thumb { width: 38px; height: 38px; border-radius: 9px; object-fit: cover; flex-shrink: 0; border: 1px solid var(--hair); background: var(--fill); cursor: zoom-in; }

.rmain { flex: 1; min-width: 0; cursor: pointer; }
.rtitle { font-size: 13.5px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; display: flex; align-items: center; gap: 6px; }
.rtitle .t { overflow: hidden; text-overflow: ellipsis; }
.rtitle .flag { flex-shrink: 0; display: inline-flex; }
.rtitle .flag svg { width: 12px; height: 12px; }
.flag.pin { color: var(--accent); }
.flag.star { color: var(--star); }
.flag.star svg { fill: var(--star); stroke: var(--star); }
.rsnip { font-size: 12.5px; color: var(--text-2); margin-top: 2px; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; white-space: pre-wrap; word-break: break-word; }
.rmeta { font-size: 11.5px; color: var(--text-3); margin-top: 3px; display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
.rmeta .sep { opacity: .6; margin: 0 6px; }
.rmeta { gap: 0; }
.rmeta .mp + .mp::before { content: "·"; margin: 0 6px; opacity: .6; }
.exp { display: inline-flex; align-items: center; gap: 3px; }
.exp svg { width: 11px; height: 11px; }
.exp.soon { color: var(--warn); font-weight: 500; }
.exp.urgent { color: var(--danger); font-weight: 500; }
.exp.perm { color: var(--text-3); }
mark { background: rgba(255, 204, 0, 0.35); color: inherit; border-radius: 2px; }

.ractions { display: flex; align-items: center; gap: 2px; flex-shrink: 0; }
.ib {
  width: 30px; height: 30px; border-radius: 7px; display: grid; place-items: center; color: var(--text-2);
}
.ib:hover { background: var(--fill-2); color: var(--text); }
.ib svg.i { width: 16px; height: 16px; }
.ib.on-star { color: var(--star); }
.ib.on-star svg { fill: var(--star); }
.ib.on-pin { color: var(--accent); }
.ib.on-pin svg { fill: var(--accent); }
.ib.del:hover { color: var(--danger); background: var(--danger-soft); }
.row .ractions .ib.quiet { opacity: 0; }
.row:hover .ractions .ib.quiet, .row:focus-within .ractions .ib.quiet { opacity: 1; }
.pbtn { height: 28px; padding: 0 10px; border-radius: 7px; font-size: 12.5px; font-weight: 500; color: var(--accent); display: inline-flex; align-items: center; gap: 5px; text-decoration: none; margin-right: 4px; }
.pbtn:hover { background: var(--accent-soft); }
.pbtn svg.i { width: 15px; height: 15px; }

/* ---------- Grid ---------- */
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 14px; }
.card { border: 1px solid var(--hair); border-radius: 12px; overflow: hidden; background: #fff; display: flex; flex-direction: column; position: relative; outline: none; }
.card:hover { border-color: var(--hair-strong); }
.card:focus-visible { border-color: var(--accent); }
.card.sel { border-color: var(--accent); box-shadow: 0 0 0 1px var(--accent); }
.card .chk { position: absolute; top: 8px; left: 8px; z-index: 1; }
.card-prev { height: 118px; background: var(--sidebar); display: grid; place-items: center; cursor: pointer; overflow: hidden; border-bottom: 1px solid var(--hair); }
.card-prev img { width: 100%; height: 100%; object-fit: cover; }
.card-prev .ficon { width: 52px; height: 52px; border-radius: 12px; }
.card-prev .ficon svg.i { width: 22px; height: 22px; }
.card-prev .txt { padding: 12px 14px; font-size: 12px; color: var(--text-2); white-space: pre-wrap; word-break: break-word; overflow: hidden; height: 100%; width: 100%; text-align: left; }
.card-body { padding: 9px 11px 4px; }
.card-body .rtitle { font-size: 13px; }
.card-acts { display: flex; align-items: center; padding: 2px 5px 6px; }
.card-acts .spacer { flex: 1; }

/* ---------- Empty ---------- */
.empty { text-align: center; padding: 70px 20px; color: var(--text-3); }
.empty .em-ic { width: 48px; height: 48px; margin: 0 auto 12px; border-radius: 12px; background: var(--fill); display: grid; place-items: center; color: var(--text-3); }
.empty .em-ic svg.i { width: 24px; height: 24px; }
.empty h3 { font-size: 15px; font-weight: 600; color: var(--text); margin-bottom: 4px; }
.empty p { font-size: 13px; margin-bottom: 14px; }

/* ---------- Transfers panel ---------- */
.transfers {
  position: fixed; right: 20px; bottom: 20px; width: 340px; max-height: 50vh; background: #fff;
  border: 1px solid var(--hair-strong); border-radius: 12px; box-shadow: 0 8px 28px rgba(0,0,0,.08);
  display: flex; flex-direction: column; z-index: 60; overflow: hidden;
}
.tf-head { display: flex; align-items: center; gap: 8px; padding: 10px 10px 10px 14px; border-bottom: 1px solid var(--hair); }
.tf-head .ttl { font-size: 13px; font-weight: 600; flex: 1; }
.tf-list { overflow-y: auto; }
.tf-item { padding: 10px 12px 10px 14px; border-bottom: 1px solid var(--hair); }
.tf-item:last-child { border-bottom: none; }
.tf-top { display: flex; align-items: center; gap: 8px; }
.tf-name { flex: 1; min-width: 0; font-size: 12.5px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.tf-stat { font-size: 11.5px; color: var(--text-3); margin-top: 5px; display: flex; justify-content: space-between; gap: 8px; }
.tf-item.error .tf-stat { color: var(--danger); }
.tf-item.done .tf-stat { color: #248A3D; }
.bar { height: 4px; border-radius: 2px; background: var(--fill); margin-top: 7px; overflow: hidden; }
.bar > i { display: block; height: 100%; width: 0; background: var(--accent); border-radius: 2px; transition: width .15s linear; }
.tf-item.done .bar > i { background: #34C759; }
.tf-item.error .bar > i { background: var(--danger); }
.tf-item .ib { width: 24px; height: 24px; }
.tf-item .ib svg.i { width: 14px; height: 14px; }

/* ---------- Toast ---------- */
.toasts { position: fixed; left: 50%; bottom: 24px; transform: translateX(-50%); z-index: 90; display: flex; flex-direction: column; gap: 8px; align-items: center; pointer-events: none; }
.toast {
  pointer-events: auto; display: flex; align-items: center; gap: 12px; background: #1D1D1F; color: #fff;
  padding: 9px 10px 9px 14px; border-radius: 10px; font-size: 13px; min-height: 38px; max-width: 92vw;
  animation: tin .18s ease-out;
}
.toast.err { background: #C9302C; }
.toast .act { color: #64B5FF; font-weight: 600; padding: 3px 6px; border-radius: 5px; }
.toast .act:hover { background: rgba(255,255,255,.1); }
@keyframes tin { from { opacity: 0; transform: translateY(6px); } to { opacity: 1; transform: none; } }

/* ---------- Menu ---------- */
.menu {
  position: fixed; z-index: 80; min-width: 190px; background: #fff; border: 1px solid var(--hair-strong);
  border-radius: 9px; padding: 5px; box-shadow: 0 8px 24px rgba(0,0,0,.10); font-size: 13px;
}
.menu button, .menu a { display: flex; align-items: center; gap: 8px; width: 100%; height: 28px; padding: 0 9px; border-radius: 5px; text-align: left; color: var(--text); text-decoration: none; }
.menu button:hover, .menu a:hover { background: var(--accent); color: #fff; }
.menu button.danger { color: var(--danger); }
.menu button.danger:hover { background: var(--danger); color: #fff; }
.menu .lbl { font-size: 11px; color: var(--text-3); padding: 6px 9px 3px; }
.menu hr { border: none; border-top: 1px solid var(--hair); margin: 4px 2px; }
.menu .check { width: 14px; display: inline-grid; place-items: center; }
.menu .check svg { width: 12px; height: 12px; stroke-width: 2.4; }

/* ---------- Modal / Quick Look ---------- */
.scrim { position: fixed; inset: 0; background: rgba(0,0,0,.28); z-index: 70; display: none; align-items: center; justify-content: center; padding: 24px; }
.scrim.open { display: flex; }
.dialog { background: #fff; border-radius: 12px; border: 1px solid var(--hair-strong); width: min(380px, 100%); padding: 20px; box-shadow: 0 16px 40px rgba(0,0,0,.14); }
.dialog h3 { font-size: 15px; font-weight: 600; margin-bottom: 6px; }
.dialog p { font-size: 13px; color: var(--text-2); margin-bottom: 18px; line-height: 1.55; }
.dialog .acts { display: flex; justify-content: flex-end; gap: 8px; }
.ql { background: #fff; border-radius: 12px; border: 1px solid var(--hair-strong); width: min(860px, 100%); max-height: 90vh; display: flex; flex-direction: column; overflow: hidden; box-shadow: 0 16px 40px rgba(0,0,0,.16); }
.ql-head { display: flex; align-items: center; gap: 10px; padding: 10px 10px 10px 16px; border-bottom: 1px solid var(--hair); }
.ql-title { flex: 1; min-width: 0; }
.ql-title b { display: block; font-size: 13.5px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ql-title span { font-size: 11.5px; color: var(--text-3); }
.ql-body { overflow: auto; background: var(--sidebar); display: flex; align-items: center; justify-content: center; min-height: 220px; }
.ql-body img, .ql-body video { max-width: 100%; max-height: 74vh; display: block; }
.ql-body audio { width: 90%; margin: 40px 0; }
.ql-body pre { align-self: stretch; width: 100%; background: #fff; margin: 0; padding: 18px 20px; font-family: var(--mono); font-size: 12.5px; line-height: 1.6; white-space: pre-wrap; word-break: break-word; }
.ql-body .ql-file { text-align: center; padding: 40px 20px; color: var(--text-2); }
.ql-body .ql-file .ficon { width: 64px; height: 64px; border-radius: 14px; margin: 0 auto 12px; }
.ql-body .ql-file .ficon svg.i { width: 28px; height: 28px; }

/* ---------- Drop overlay ---------- */
.drop {
  position: fixed; inset: 12px; z-index: 95; border: 2px dashed var(--accent); border-radius: 16px;
  background: rgba(255,255,255,.94); display: none; flex-direction: column; align-items: center; justify-content: center; gap: 8px; pointer-events: none;
}
.drop.show { display: flex; }
.drop .em-ic { width: 56px; height: 56px; border-radius: 14px; background: var(--accent-soft); color: var(--accent); display: grid; place-items: center; }
.drop .em-ic svg.i { width: 28px; height: 28px; }
.drop b { font-size: 17px; font-weight: 600; }
.drop span { font-size: 13px; color: var(--text-2); }

/* ---------- Mobile ---------- */
@media (max-width: 820px) {
  .sidebar { display: none; }
  .main-inner { padding: 0 16px 140px; }
  .mbar { display: block; position: sticky; top: 0; z-index: 50; background: rgba(255,255,255,.97); border-bottom: 1px solid var(--hair); padding: calc(env(safe-area-inset-top) + 10px) 16px 0; margin: 0 -16px 14px; }
  .mbar-top { display: flex; align-items: center; gap: 8px; margin-bottom: 10px; }
  .mbar-top .brand-name { font-size: 17px; flex: 1; }
  .mbar .search { margin: 0 0 10px; }
  .mbar .search input { height: 34px; font-size: 15px; }
  .mbar .search .kbd { display: none; }
  .chips { display: flex; gap: 6px; overflow-x: auto; scrollbar-width: none; padding-bottom: 10px; }
  .chips::-webkit-scrollbar { display: none; }
  .chip { flex-shrink: 0; height: 30px; padding: 0 12px; border-radius: 999px; background: var(--fill); font-size: 13px; color: var(--text); display: inline-flex; align-items: center; gap: 5px; }
  .chip .c { font-size: 11.5px; color: var(--text-3); }
  .chip.active { background: var(--text); color: #fff; }
  .chip.active .c { color: rgba(255,255,255,.7); }
  .toolbar { margin-top: 20px; }
  .composer textarea { font-size: 16px; }
  .hint.kb { display: none; }
  .row { padding: 11px 2px; gap: 10px; }
  .row .ractions .ib.quiet { opacity: 1; }
  .row .ractions .ib.hide-m, .row .ractions .ib.quiet[data-act="pin"] { display: none; }
  .rmeta .m-hide { display: none; }
  .rmeta .mp.xp { flex-basis: 100%; margin-top: 1px; }
  .rmeta .mp.xp::before { content: none; }
  .pbtn .lbl { display: none; }
  .pbtn { padding: 0 7px; margin-right: 0; }
  .grid { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
  .transfers { left: 12px; right: 12px; width: auto; bottom: calc(env(safe-area-inset-bottom) + 12px); }
  .toasts { bottom: calc(env(safe-area-inset-bottom) + 20px); }
  .ql-body img, .ql-body video { max-height: 64vh; }
  .scrim { padding: 12px; }
  .ql-head { flex-wrap: wrap; padding: 10px 8px 8px 14px; }
  .ql-title { flex-basis: 100%; order: -1; margin-bottom: 4px; }
}
@media (prefers-reduced-motion: reduce) { * { animation: none !important; transition: none !important; } }
</style>
</head>
<body>
<div class="app">
  <aside class="sidebar" aria-label="分类导航">
    <div class="brand">
      <div class="brand-mark"><i data-ic="upload"></i></div>
      <div><div class="brand-name">SyncHub</div><div class="brand-sub">跨端传输与收藏</div></div>
    </div>
    <div class="search" data-search>
      <i data-ic="search"></i>
      <input type="search" placeholder="搜索" autocomplete="off" aria-label="搜索文件名、文字、来源设备">
      <button class="clear" data-act="clearq" title="清除搜索" aria-label="清除搜索"><i data-ic="x"></i></button>
      <span class="kbd">/</span>
    </div>
    <div class="nav-section">资料库</div>
    <nav id="navLib"></nav>
    <div class="nav-section">分类</div>
    <nav id="navCat"></nav>
    <div class="sidebar-foot">
      <a class="nav-item" href="/api/hub/client/mac.sh" download title="下载 macOS 自动接收与 Finder 右键套件"><i data-ic="laptop"></i>Mac 自动接收套件</a>
      <a class="nav-item" href="/api/hub/client/android_root.sh" download title="下载 Android Root 自动接收脚本"><i data-ic="phone"></i>安卓 Root 自动接收</a>
      <button class="nav-item danger" data-act="cleanup" title="删除所有未收藏且未置顶的项目"><i data-ic="trash"></i>清理临时项…</button>
      <div class="retention-note" id="retentionNote">普通项目 72 小时后自动清理，收藏或置顶的项目永久保留。</div>
      <div class="conn" id="conn"><span class="dot"></span><span id="connText">正在连接…</span></div>
    </div>
  </aside>

  <main class="main" id="main">
    <div class="main-inner">
      <div class="mbar">
        <div class="mbar-top">
          <div class="brand-mark"><i data-ic="upload"></i></div>
          <div class="brand-name">SyncHub</div>
          <button class="ib" data-act="mmore" title="更多" aria-label="更多"><i data-ic="more"></i></button>
        </div>
        <div class="search" data-search>
          <i data-ic="search"></i>
          <input type="search" placeholder="搜索文件名、文字、设备" autocomplete="off" aria-label="搜索">
          <button class="clear" data-act="clearq" aria-label="清除搜索"><i data-ic="x"></i></button>
        </div>
        <div class="chips" id="chips"></div>
      </div>

      <section class="composer" id="composer">
        <textarea id="txt" rows="1" placeholder="输入或粘贴文字，发送后同步到所有设备的剪贴板；也可以直接拖入文件或粘贴截图"></textarea>
        <div class="composer-bar">
          <button class="btn plain" data-act="pick" title="选择文件上传 (Ctrl/⌘ + O)"><i data-ic="clip"></i>添加文件</button>
          <button class="opt star" id="optStar" aria-pressed="false" title="本次发送的内容加入收藏，永久保留"><i data-ic="star"></i>收藏</button>
          <button class="opt" id="optPin" aria-pressed="false" title="本次发送的内容置顶，永久保留"><i data-ic="pin"></i>置顶</button>
          <label class="opt" title="文件归类（默认按扩展名自动识别）"><i data-ic="tag"></i>
            <select id="optCat" aria-label="文件分类">
              <option value="">自动分类</option>
              <option>文档</option><option>视频</option><option>压缩包</option><option>图片</option>
              <option>安装包</option><option>音频</option><option>其他</option>
            </select>
          </label>
          <span class="spacer"></span>
          <span class="hint kb tabular" id="charCount">⌘/Ctrl + ↵ 发送</span>
          <button class="btn plain" data-act="pastesend" title="读取剪贴板文字并直接发送"><i data-ic="clipboard"></i></button>
          <button class="btn primary" id="btnSend" data-act="send" disabled><i data-ic="send"></i>发送</button>
        </div>
        <input type="file" id="fileInput" multiple hidden>
      </section>

      <div class="toolbar" id="toolbar">
        <div>
          <div class="view-title" id="viewTitle">全部</div>
          <div class="view-sub tabular" id="viewSub">&nbsp;</div>
        </div>
        <div class="toolbar-right" id="tbNormal">
          <button class="btn" data-act="select" title="多选后批量收藏或删除"><i data-ic="checkc"></i>选择</button>
          <div class="seg" role="group" aria-label="视图">
            <button id="segList" data-act="layout" data-v="list" title="列表"><i data-ic="list"></i></button>
            <button id="segGrid" data-act="layout" data-v="grid" title="图标"><i data-ic="grid"></i></button>
          </div>
        </div>
        <div class="bulkbar hidden" id="tbBulk">
          <span class="n tabular" id="selN">已选 0 项</span>
          <button class="btn" data-act="selall">全选</button>
          <button class="btn" data-act="bstar"><i data-ic="star"></i><span id="bstarLbl">收藏</span></button>
          <button class="btn danger" data-act="bdel"><i data-ic="trash"></i>删除</button>
          <button class="btn primary" data-act="selectdone">完成</button>
        </div>
      </div>

      <section id="content" aria-live="polite"></section>
    </div>
  </main>
</div>

<div class="transfers hidden" id="tf"></div>
<div class="toasts" id="toasts"></div>
<div class="drop" id="drop"><div class="em-ic"><i data-ic="upload"></i></div><b>松开即可上传</b><span>其他设备会自动接收并保存</span></div>
<div class="scrim" id="qlScrim"><div class="ql" id="ql" role="dialog" aria-modal="true"></div></div>
<div class="scrim" id="dlgScrim"><div class="dialog" id="dlg" role="alertdialog" aria-modal="true"></div></div>

<script>
"use strict";
const P = {
  upload: '<path d="M12 16V4M7 9l5-5 5 5M4 16v3a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-3"/>',
  search: '<circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/>',
  x: '<path d="M6 6l12 12M18 6L6 18"/>',
  tray: '<path d="M3 13h5l2 3h4l2-3h5"/><path d="M5.5 5h13l2.5 8v6a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1v-6z"/>',
  star: '<path d="M12 3.5l2.6 5.3 5.9.9-4.3 4.1 1 5.8L12 16.9l-5.2 2.7 1-5.8-4.3-4.1 5.9-.9z"/>',
  pin: '<path d="M9 3.5h6l-1 6.2 3.2 3.3H6.8L10 9.7z"/><path d="M12 13v7.5"/>',
  clock: '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>',
  doc: '<path d="M7 3h7l5 5v12a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z"/><path d="M14 3v5h5M9 13h6M9 17h6"/>',
  video: '<rect x="3" y="6" width="13" height="12" rx="2"/><path d="M16 10.5l5-3v9l-5-3"/>',
  zip: '<rect x="3" y="4" width="18" height="4" rx="1"/><path d="M5 8v11a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V8M10 12h4"/>',
  image: '<rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="8.5" cy="9.5" r="1.5"/><path d="M21 16l-5-5-9 9"/>',
  app: '<path d="M12 3l8 4.5v9L12 21l-8-4.5v-9z"/><path d="M4 7.5l8 4.5 8-4.5M12 12v9"/>',
  audio: '<path d="M9 18V5l11-2v13"/><circle cx="6.5" cy="18" r="2.5"/><circle cx="17.5" cy="16" r="2.5"/>',
  text: '<path d="M5 6h14M5 11h14M5 16h9"/>',
  other: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
  download: '<path d="M12 4v12M7 11l5 5 5-5M5 20h14"/>',
  copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/>',
  trash: '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12M9 7V4h6v3"/>',
  more: '<circle cx="5" cy="12" r="1.3" fill="currentColor"/><circle cx="12" cy="12" r="1.3" fill="currentColor"/><circle cx="19" cy="12" r="1.3" fill="currentColor"/>',
  list: '<path d="M8 6h13M8 12h13M8 18h13M3.5 6h.01M3.5 12h.01M3.5 18h.01"/>',
  grid: '<rect x="3.5" y="3.5" width="7" height="7" rx="1.5"/><rect x="13.5" y="3.5" width="7" height="7" rx="1.5"/><rect x="3.5" y="13.5" width="7" height="7" rx="1.5"/><rect x="13.5" y="13.5" width="7" height="7" rx="1.5"/>',
  clip: '<path d="M20.5 11.5l-8.2 8.2a5 5 0 0 1-7.1-7.1l8.6-8.6a3.3 3.3 0 0 1 4.7 4.7l-8.6 8.6a1.7 1.7 0 0 1-2.4-2.4l7.9-7.9"/>',
  send: '<path d="M12 19V5M6 11l6-6 6 6"/>',
  clipboard: '<rect x="5.5" y="4.5" width="13" height="16.5" rx="2"/><path d="M9 4.5V3h6v1.5M9 10h6M9 14h4"/>',
  check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
  checkc: '<circle cx="12" cy="12" r="8.5"/><path d="M8.5 12.2l2.5 2.5 4.5-5"/>',
  eye: '<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="3"/>',
  laptop: '<rect x="4" y="5" width="16" height="11" rx="1.5"/><path d="M2 19h20"/>',
  phone: '<rect x="7" y="2.5" width="10" height="19" rx="2"/><path d="M11 18h2"/>',
  tag: '<path d="M3.5 12.5V4.5a1 1 0 0 1 1-1h8l8 8-9 9z"/><circle cx="8" cy="8" r="1.3"/>',
  refresh: '<path d="M19.5 11A7.5 7.5 0 0 0 6 6.5L4 8.5M4 4v4.5h4.5M4.5 13A7.5 7.5 0 0 0 18 17.5l2-2M20 20v-4.5h-4.5"/>',
  link: '<path d="M10 14a4 4 0 0 0 5.7 0l3-3A4 4 0 0 0 13 5.3l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>',
  open: '<path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>',
  chevL: '<path d="M15 5l-7 7 7 7"/>',
  chevR: '<path d="M9 5l7 7-7 7"/>',
  minus: '<path d="M6 12h12"/>'
};
const ic = (n) => `<svg class="i" viewBox="0 0 24 24" aria-hidden="true">${P[n] || ""}</svg>`;
document.querySelectorAll("i[data-ic]").forEach(el => { el.outerHTML = ic(el.dataset.ic); });

const CATS = ["文档", "视频", "压缩包", "图片", "安装包", "音频", "文本", "其他"];
const CAT_META = { "文档": ["doc", "c-doc"], "视频": ["video", "c-vid"], "压缩包": ["zip", "c-zip"], "图片": ["image", "c-img"], "安装包": ["app", "c-app"], "音频": ["audio", "c-aud"], "文本": ["text", "c-txt"], "其他": ["other", ""] };
const LIB = [
  { key: "all", label: "全部", icon: "tray" },
  { key: "pinned", label: "置顶", icon: "pin" },
  { key: "starred", label: "收藏", icon: "star" },
  { key: "expiring", label: "即将清理", icon: "clock" }
];
const SOON = 12 * 3600, URGENT = 2 * 3600;
const store = { get(k, d) { try { return localStorage.getItem(k) || d; } catch (e) { return d; } }, set(k, v) { try { localStorage.setItem(k, v); } catch (e) {} } };

const S = {
  items: [], loaded: false, online: true, lastSync: 0, retention: 72, sig: "",
  view: "all", q: "", layout: store.get("hub.layout", "list"),
  selecting: false, sel: new Set(), pending: new Set(),
  opts: { star: false, pin: false }
};
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, m => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[m]));
const isMac = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
const MOD = isMac ? "⌘" : "Ctrl";

function detectMyDevice() {
  const ua = navigator.userAgent || "";
  if (/Android/i.test(ua)) return "Android";
  if (/iPhone|iPad|iPod/i.test(ua)) return "iPhone";
  if (/Macintosh|Mac OS X/i.test(ua)) return "Mac";
  if (/Windows/i.test(ua)) return "Windows";
  return "Web";
}
function formatBytes(b) {
  if (!b || b <= 0) return "0 B";
  const u = ["B", "KB", "MB", "GB", "TB"]; let i = 0, v = b;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return (i === 0 ? v : v.toFixed(v < 10 ? 1 : 0)) + " " + u[i];
}
function fmtDuration(sec) {
  sec = Math.max(0, Math.round(sec));
  if (sec < 60) return sec + " 秒";
  if (sec < 3600) return Math.round(sec / 60) + " 分钟";
  return Math.floor(sec / 3600) + " 小时 " + Math.round((sec % 3600) / 60) + " 分";
}

/* ---------------- API ---------------- */
async function api(url, opts) {
  const res = await fetch(url, opts);
  let data = null;
  try { data = await res.json(); } catch (e) {}
  if (!res.ok || (data && data.ok === false)) throw new Error((data && data.error) || ("HTTP " + res.status));
  return data || {};
}
const postJSON = (url, body) => api(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });

function stamp(it) { it._t = Date.now(); return it; }
function sortItems() { S.items.sort((a, b) => (b.pinned - a.pinned) || (b.id - a.id)); }
function upsert(it) {
  stamp(it);
  const i = S.items.findIndex(x => x.id === it.id);
  if (i >= 0) S.items[i] = it; else S.items.push(it);
  sortItems();
}
const byId = (id) => S.items.find(x => x.id === id);

async function load(force) {
  try {
    const data = await api("/api/hub/items?limit=500");
    S.items = (data.items || []).map(stamp);
    sortItems();
    S.retention = data.retentionHours || 72;
    S.loaded = true; setOnline(true);
    const sig = JSON.stringify(S.items.map(x => [x.id, x.starred, x.pinned, x.category, x.hasFile]));
    if (force || sig !== S.sig) { S.sig = sig; render(); } else { renderNav(); tick(); }
  } catch (e) {
    setOnline(false);
    if (force) toast("无法连接服务器：" + e.message, { err: true });
    if (!S.loaded) { S.loaded = true; render(); }
  }
}
function setOnline(ok) {
  S.online = ok; if (ok) S.lastSync = Date.now();
  $("conn").classList.toggle("off", !ok);
  updateConn();
}
function updateConn() {
  if (!S.online) { $("connText").textContent = "连接中断，正在重试…"; return; }
  const s = Math.round((Date.now() - S.lastSync) / 1000);
  $("connText").textContent = "已连接 · " + (s < 5 ? "刚刚同步" : (s < 60 ? s + " 秒前同步" : Math.round(s / 60) + " 分钟前同步"));
}

/* ---------------- Derived ---------------- */
function remain(it) { return it.isPermanent ? null : Math.max(0, (it.remainingSeconds || 0) - (Date.now() - (it._t || Date.now())) / 1000); }
const live = () => S.items.filter(it => !S.pending.has(it.id));
function inView(it, v) {
  if (v === "all") return true;
  if (v === "pinned") return it.pinned;
  if (v === "starred") return it.starred;
  if (v === "expiring") { const r = remain(it); return r !== null && r < SOON; }
  return it.category === v;
}
function matchQ(it) {
  const q = S.q.trim().toLowerCase(); if (!q) return true;
  return `${it.filename} ${it.text} ${it.category} ${it.fromDevice}`.toLowerCase().includes(q);
}
const visible = () => live().filter(it => inView(it, S.view) && matchQ(it));
function counts() {
  const c = {}; const L = live();
  LIB.forEach(l => c[l.key] = L.filter(it => inView(it, l.key)).length);
  CATS.forEach(k => c[k] = L.filter(it => it.category === k).length);
  return c;
}
const viewLabel = (v) => (LIB.find(l => l.key === v) || {}).label || v;
const isText = (it) => it.type === 0;
const extOf = (it) => { const f = it.filename || ""; return f.includes(".") ? f.split(".").pop().toLowerCase() : ""; };
const canThumb = (it) => it.hasFile && it.downloadUrl && /^(png|jpe?g|gif|webp|bmp|svg|ico|avif)$/.test(extOf(it));
const isVideo = (it) => it.hasFile && /^(mp4|webm|mov|m4v|ogv)$/.test(extOf(it));
const isAudio = (it) => it.hasFile && /^(mp3|wav|m4a|aac|ogg|opus|flac)$/.test(extOf(it));
const inlineUrl = (it) => it.downloadUrl + "?inline=1";
function titleOf(it) {
  if (!isText(it)) return it.filename || "未命名文件";
  const first = (it.text || "").split(/\r?\n/).find(l => l.trim()) || "";
  return first.trim().slice(0, 120) || "（空白文字）";
}
function restOf(it) {
  if (!isText(it)) return "";
  const t = (it.text || "").trim(); const f = titleOf(it);
  return t.length > f.length ? t.slice(t.indexOf(f) + f.length).trim() : "";
}
function hl(s) {
  s = String(s || ""); const q = S.q.trim(); if (!q) return esc(s);
  const lo = s.toLowerCase(), ql = q.toLowerCase(); let out = "", i = 0, j;
  while ((j = lo.indexOf(ql, i)) !== -1) { out += esc(s.slice(i, j)) + "<mark>" + esc(s.slice(j, j + q.length)) + "</mark>"; i = j + q.length; }
  return out + esc(s.slice(i));
}
function relTime(it) {
  const t = Date.parse(it.createTimeUtc); if (isNaN(t)) return it.createTimeLocal || "";
  const d = new Date(t), now = new Date(), diff = (now - d) / 1000;
  const hm = d.toTimeString().slice(0, 5);
  if (diff < 60) return "刚刚";
  if (diff < 3600) return Math.floor(diff / 60) + " 分钟前";
  const y = new Date(now); y.setDate(now.getDate() - 1);
  if (d.toDateString() === now.toDateString()) return "今天 " + hm;
  if (d.toDateString() === y.toDateString()) return "昨天 " + hm;
  return (d.getMonth() + 1) + "月" + d.getDate() + "日 " + hm;
}
function expInfo(it) {
  const r = remain(it);
  if (r === null) return { cls: "perm", txt: "永久保留" };
  if (r <= 0) return { cls: "urgent", txt: "即将清理" };
  const d = Math.floor(r / 86400), h = Math.floor((r % 86400) / 3600), m = Math.max(1, Math.floor((r % 3600) / 60));
  const txt = d > 0 ? `${d} 天 ${h} 小时后清理` : (h > 0 ? `${h} 小时 ${m} 分后清理` : `${m} 分钟后清理`);
  return { cls: r < URGENT ? "urgent" : (r < SOON ? "soon" : ""), txt };
}
function expHtml(it) {
  const e = expInfo(it);
  return `<span class="exp ${e.cls}" data-exp="${it.id}" title="${it.isPermanent ? "已收藏或置顶，不会被自动清理" : "普通项目上传 " + S.retention + " 小时后自动清理；收藏或置顶可永久保留"}">${e.cls === "perm" ? "" : ic("clock")}${e.txt}</span>`;
}

/* ---------------- Rendering ---------------- */
function render() { renderNav(); renderHeader(); renderContent(); }

function renderNav() {
  const c = counts();
  const navBtn = (key, label, icon, extra) => `<button class="nav-item ${S.view === key ? "active" : ""} ${extra || ""}" data-act="view" data-v="${esc(key)}">${ic(icon)}<span>${esc(label)}</span><span class="count">${c[key] || ""}</span></button>`;
  $("navLib").innerHTML = LIB.map(l => navBtn(l.key, l.label, l.icon, l.key === "expiring" && c.expiring ? "warn-item" : "")).join("");
  $("navCat").innerHTML = CATS.map(k => navBtn(k, k, CAT_META[k][0], c[k] ? "" : "dim")).join("");
  const chips = LIB.concat(CATS.filter(k => c[k]).map(k => ({ key: k, label: k })));
  $("chips").innerHTML = chips.map(l => `<button class="chip ${S.view === l.key ? "active" : ""}" data-act="view" data-v="${esc(l.key)}">${esc(l.label)}<span class="c tabular">${c[l.key] || 0}</span></button>`).join("");
  $("retentionNote").textContent = `普通项目 ${S.retention} 小时后自动清理，收藏或置顶的项目永久保留。`;
}

function renderHeader() {
  const n = visible().length;
  $("viewTitle").textContent = viewLabel(S.view);
  let sub = `${n} 项`;
  if (S.q.trim()) sub += ` · 搜索“${S.q.trim()}”`;
  else if (S.view === "all") sub += ` · 普通项目 ${S.retention} 小时后自动清理`;
  else if (S.view === "expiring") sub += " · 12 小时内到期，收藏或置顶即可保留";
  else if (S.view === "starred" || S.view === "pinned") sub += " · 永久保留";
  $("viewSub").textContent = sub;
  $("segList").classList.toggle("on", S.layout === "list");
  $("segGrid").classList.toggle("on", S.layout === "grid");
  $("tbNormal").classList.toggle("hidden", S.selecting);
  $("tbBulk").classList.toggle("hidden", !S.selecting);
  if (S.selecting) {
    $("selN").textContent = `已选 ${S.sel.size} 项`;
    const sel = [...S.sel].map(byId).filter(Boolean);
    $("bstarLbl").textContent = sel.length && sel.every(x => x.starred) ? "取消收藏" : "收藏";
  }
}

function emptyHtml() {
  const box = (icon, h, p, btn) => `<div class="empty"><div class="em-ic">${ic(icon)}</div><h3>${h}</h3><p>${p}</p>${btn || ""}</div>`;
  if (!S.loaded) return box("refresh", "正在加载…", "");
  if (!S.online && !S.items.length) return box("refresh", "无法连接服务器", "请检查网络后重试。", `<button class="btn" data-act="retry">重试</button>`);
  if (S.q.trim()) return box("search", `没有找到“${esc(S.q.trim())}”`, "试试其他关键词，或在“全部”中搜索。", `<button class="btn" data-act="clearq">清除搜索</button>`);
  if (S.view === "pinned") return box("pin", "还没有置顶项目", "置顶的项目固定在列表最上方，并永久保留。");
  if (S.view === "starred") return box("star", "还没有收藏", `收藏的项目不会被 ${S.retention} 小时自动清理。`);
  if (S.view === "expiring") return box("clock", "没有即将清理的项目", "12 小时内到期的普通项目会显示在这里，方便你及时收藏。");
  if (S.view !== "all") return box(CAT_META[S.view] ? CAT_META[S.view][0] : "other", `“${esc(S.view)}”中暂无内容`, "上传后会按扩展名自动归类，也可以在项目菜单中手动更改分类。");
  return box("upload", "把文件拖到这里", `也可以按 ${MOD} + V 粘贴截图或文字，或在电脑上右键文件“发送到跨端传输”。`, `<button class="btn primary" data-act="pick">${ic("clip")}选择文件</button>`);
}

function iconHtml(it, big) {
  if (!big && canThumb(it)) return `<img class="thumb" data-act="open" loading="lazy" src="${esc(inlineUrl(it))}" alt="">`;
  const m = CAT_META[it.category] || CAT_META["其他"];
  const ext = isText(it) ? "" : extOf(it).slice(0, 4).toUpperCase();
  return `<div class="ficon ${m[1]}" data-act="open">${ic(m[0])}${ext ? `<span class="ext">${esc(ext)}</span>` : ""}</div>`;
}
function metaHtml(it) {
  const parts = [isText(it) ? `${(it.text || "").length} 字` : formatBytes(it.size)];
  if (!isText(it) && !it.hasFile) parts.push(`<span style="color:var(--danger)">文件缺失</span>`);
  parts.push(`<span class="dev">${hl(it.fromDevice)}</span>`);
  parts.push(`<span data-rt="${it.id}" title="${esc(it.createTimeLocal)} (UTC+8)">${relTime(it)}</span>`);
  parts.push(expHtml(it));
  return parts.map((p, i) => `<span class="mp${p.indexOf('class="dev"') > 0 ? " m-hide" : ""}${i === parts.length - 1 ? " xp" : ""}">${p}</span>`).join("");
}
function primaryBtn(it) {
  if (isText(it)) return `<button class="pbtn" data-act="copy" title="复制文字">${ic("copy")}<span class="lbl">复制</span></button>`;
  if (it.downloadUrl && it.hasFile) return `<a class="pbtn" href="${esc(it.downloadUrl)}" download title="下载">${ic("download")}<span class="lbl">下载</span></a>`;
  return "";
}
function toggleBtns(it) {
  return `<button class="ib ${it.starred ? "on-star" : "quiet"}" data-act="star" aria-pressed="${it.starred}" title="${it.starred ? "取消收藏" : "收藏（永久保留）"}">${ic("star")}</button>` +
         `<button class="ib ${it.pinned ? "on-pin" : "quiet"}" data-act="pin" aria-pressed="${it.pinned}" title="${it.pinned ? "取消置顶" : "置顶（永久保留）"}">${ic("pin")}</button>`;
}
const chk = () => `<span class="chk">${ic("check")}</span>`;
function flags(it) {
  return (it.pinned ? `<span class="flag pin" title="置顶">${ic("pin")}</span>` : "") + (it.starred ? `<span class="flag star" title="已收藏">${ic("star")}</span>` : "");
}

function rowHtml(it) {
  const rest = restOf(it);
  return `<div class="row ${S.sel.has(it.id) ? "sel" : ""}" data-id="${it.id}" tabindex="0">
    ${S.selecting ? chk() : ""}
    ${iconHtml(it)}
    <div class="rmain" data-act="open">
      <div class="rtitle"><span class="t">${hl(titleOf(it))}</span>${flags(it)}</div>
      ${rest ? `<div class="rsnip">${hl(rest)}</div>` : ""}
      <div class="rmeta tabular">${metaHtml(it)}</div>
    </div>
    ${S.selecting ? "" : `<div class="ractions">${primaryBtn(it)}${toggleBtns(it)}
      <button class="ib quiet del hide-m" data-act="del" title="删除 (Delete)">${ic("trash")}</button>
      <button class="ib" data-act="more" title="更多操作">${ic("more")}</button></div>`}
  </div>`;
}
function cardHtml(it) {
  let prev;
  if (canThumb(it)) prev = `<img loading="lazy" src="${esc(inlineUrl(it))}" alt="">`;
  else if (isText(it)) prev = `<div class="txt">${hl(it.text)}</div>`;
  else prev = iconHtml(it, true);
  return `<div class="card ${S.sel.has(it.id) ? "sel" : ""}" data-id="${it.id}" tabindex="0">
    ${S.selecting ? chk() : ""}
    <div class="card-prev" data-act="open">${prev}</div>
    <div class="card-body"><div class="rtitle"><span class="t">${hl(titleOf(it))}</span>${flags(it)}</div>
      <div class="rmeta tabular">${isText(it) ? (it.text || "").length + " 字" : formatBytes(it.size)}<span class="sep">·</span>${expHtml(it)}</div></div>
    ${S.selecting ? "" : `<div class="card-acts">${primaryBtn(it)}<span class="spacer"></span>${toggleBtns(it)}<button class="ib" data-act="more" title="更多操作">${ic("more")}</button></div>`}
  </div>`;
}

function renderContent() {
  const items = visible();
  const el = $("content");
  if (!items.length) { el.innerHTML = emptyHtml(); return; }
  el.innerHTML = S.layout === "grid"
    ? `<div class="grid">${items.map(cardHtml).join("")}</div>`
    : `<div class="list">${items.map(rowHtml).join("")}</div>`;
}

function tick() {
  document.querySelectorAll("[data-exp]").forEach(el => {
    const it = byId(+el.dataset.exp); if (!it) return;
    const e = expInfo(it);
    el.className = "exp " + e.cls;
    el.innerHTML = (e.cls === "perm" ? "" : ic("clock")) + e.txt;
  });
  document.querySelectorAll("[data-rt]").forEach(el => { const it = byId(+el.dataset.rt); if (it) el.textContent = relTime(it); });
  updateConn();
}

/* ---------------- Toast & dialog ---------------- */
function toast(msg, o) {
  o = o || {};
  const t = document.createElement("div");
  t.className = "toast" + (o.err ? " err" : "");
  t.innerHTML = `<span>${esc(msg)}</span>`;
  let timer;
  const close = () => { clearTimeout(timer); t.remove(); };
  if (o.action) {
    const b = document.createElement("button"); b.className = "act"; b.textContent = o.action;
    b.onclick = () => { close(); o.onAction && o.onAction(); };
    t.appendChild(b);
  }
  const box = $("toasts");
  while (box.children.length >= 3) box.firstChild.remove();
  box.appendChild(t);
  timer = setTimeout(close, o.duration || (o.err ? 4500 : 2400));
  return close;
}
function confirmDlg(title, body, okText, danger) {
  return new Promise(resolve => {
    const scrim = $("dlgScrim");
    $("dlg").innerHTML = `<h3>${esc(title)}</h3><p>${esc(body)}</p><div class="acts"><button class="btn" data-r="0">取消</button><button class="btn ${danger ? "danger-fill" : "primary"}" data-r="1">${esc(okText)}</button></div>`;
    scrim.classList.add("open");
    const done = (v) => { scrim.classList.remove("open"); scrim.onclick = null; resolve(v); };
    scrim.onclick = (e) => { const b = e.target.closest("[data-r]"); if (b) done(b.dataset.r === "1"); else if (e.target === scrim) done(false); };
    S.dlgClose = () => done(false);
    setTimeout(() => $("dlg").querySelector('[data-r="1"]').focus(), 0);
  });
}

/* ---------------- Clipboard ---------------- */
async function copyToClipboard(text) {
  try { await navigator.clipboard.writeText(text); return true; } catch (e) {}
  const ta = document.createElement("textarea"); ta.value = text; ta.setAttribute("readonly", "");
  ta.style.position = "fixed"; ta.style.opacity = "0"; document.body.appendChild(ta); ta.select();
  let ok = false; try { ok = document.execCommand("copy"); } catch (e) {}
  ta.remove(); return ok;
}
async function copyItem(it) {
  const ok = await copyToClipboard(it.text || "");
  toast(ok ? "已复制到剪贴板" : "复制失败，请长按文字手动复制", { err: !ok });
}

/* ---------------- Item actions ---------------- */
async function setFlag(it, field, val, silent) {
  const prev = { starred: it.starred, pinned: it.pinned };
  it[field] = val; it.isPermanent = it.starred || it.pinned; render();
  try {
    const d = await postJSON(`/api/hub/item/${it.id}/update`, { [field]: val });
    if (d.item) upsert(d.item);
    render();
    if (silent) return;
    const name = field === "starred" ? "收藏" : "置顶";
    const now = d.item || it;
    if (val) toast(field === "starred" ? "已收藏 · 将永久保留" : "已置顶 · 将永久保留");
    else if (!now.isPermanent && now.remainingSeconds === 0)
      toast(`已取消${name}，该项目已超过 ${S.retention} 小时，下次清理时会被删除`, { action: "撤销", duration: 6000, onAction: () => setFlag(byId(it.id) || it, field, true, true) });
    else toast(`已取消${name}` + (now.isPermanent ? "" : " · " + expInfo(now).txt));
  } catch (e) {
    Object.assign(it, prev); it.isPermanent = it.starred || it.pinned; render();
    toast("操作失败：" + e.message, { err: true });
  }
}
async function setCategory(it, cat) {
  try {
    const d = await postJSON(`/api/hub/item/${it.id}/update`, { category: cat });
    if (d.item) upsert(d.item); render();
    toast(`已移到“${cat}”`);
  } catch (e) { toast("更改分类失败：" + e.message, { err: true }); }
}

const pendingBatches = [];
function removeItems(ids) {
  ids = ids.filter(id => !S.pending.has(id));
  if (!ids.length) return;
  ids.forEach(id => S.pending.add(id));
  S.sel.clear(); render();
  const batch = { ids };
  batch.timer = setTimeout(() => commitDelete(batch), 5000);
  pendingBatches.push(batch);
  const first = byId(ids[0]);
  const label = ids.length === 1 && first ? `已删除“${titleOf(first).slice(0, 24)}”` : `已删除 ${ids.length} 项`;
  toast(label, { action: "撤销", duration: 5000, onAction: () => {
    clearTimeout(batch.timer); pendingBatches.splice(pendingBatches.indexOf(batch), 1);
    ids.forEach(id => S.pending.delete(id)); render();
  } });
}
async function commitDelete(batch) {
  const i = pendingBatches.indexOf(batch); if (i < 0) return;
  pendingBatches.splice(i, 1);
  try {
    if (batch.ids.length === 1) await api(`/api/hub/item/${batch.ids[0]}/delete`, { method: "POST" });
    else await postJSON("/api/hub/batch-delete", { ids: batch.ids });
    S.items = S.items.filter(x => !batch.ids.includes(x.id));
    batch.ids.forEach(id => S.pending.delete(id));
  } catch (e) {
    batch.ids.forEach(id => S.pending.delete(id));
    toast("删除失败：" + e.message, { err: true });
  }
  render();
}
function flushDeletes() {
  while (pendingBatches.length) {
    const b = pendingBatches.shift(); clearTimeout(b.timer);
    try {
      if (b.ids.length === 1) navigator.sendBeacon(`/api/hub/item/${b.ids[0]}/delete`);
      else navigator.sendBeacon("/api/hub/batch-delete", new Blob([JSON.stringify({ ids: b.ids })], { type: "application/json" }));
    } catch (e) {}
  }
}
async function cleanup() {
  const n = live().filter(it => !it.isPermanent).length;
  if (!n) { toast("没有需要清理的临时项目"); return; }
  const ok = await confirmDlg(`清理 ${n} 个临时项目？`, "所有未收藏且未置顶的文件和文字将立即从服务器删除，此操作无法撤销。收藏和置顶的项目不受影响。", "清理", true);
  if (!ok) return;
  try {
    const d = await postJSON("/api/hub/batch-delete", { mode: "unstarred" });
    toast(`已清理 ${d.deletedCount || 0} 项`);
  } catch (e) { toast("清理失败：" + e.message, { err: true }); }
  load(true);
}

/* ---------------- Menu ---------------- */
let menuEl = null;
function closeMenu() { if (menuEl) { menuEl.remove(); menuEl = null; } }
function openMenuAt(html, x, y, onPick) {
  closeMenu();
  menuEl = document.createElement("div"); menuEl.className = "menu"; menuEl.innerHTML = html;
  document.body.appendChild(menuEl);
  const r = menuEl.getBoundingClientRect();
  menuEl.style.left = Math.max(8, Math.min(x, innerWidth - r.width - 8)) + "px";
  menuEl.style.top = Math.max(8, (y + r.height > innerHeight - 8 ? y - r.height : y)) + "px";
  menuEl.addEventListener("click", (e) => { const b = e.target.closest("[data-m]"); if (!b) return; if (b.tagName !== "A") e.preventDefault(); closeMenu(); onPick(b.dataset.m, b); });
}
function itemMenu(it, x, y) {
  const text = isText(it);
  const check = (on) => `<span class="check">${on ? ic("check") : ""}</span>`;
  let h = `<button data-m="open">${ic("eye")}快速预览</button>`;
  if (text) h += `<button data-m="copy">${ic("copy")}复制文字</button>`;
  else if (it.hasFile) h += `<a data-m="dl" href="${esc(it.downloadUrl)}" download>${ic("download")}下载</a><button data-m="link">${ic("link")}复制下载链接</button>`;
  h += `<hr><button data-m="star">${ic("star")}${it.starred ? "取消收藏" : "收藏（永久保留）"}</button>`;
  h += `<button data-m="pin">${ic("pin")}${it.pinned ? "取消置顶" : "置顶（永久保留）"}</button>`;
  h += `<hr><div class="lbl">分类</div>` + CATS.map(c => `<button data-m="cat" data-c="${c}">${check(it.category === c)}${c}</button>`).join("");
  h += `<hr><button class="danger" data-m="del">${ic("trash")}删除</button>`;
  openMenuAt(h, x, y, (m, b) => {
    if (m === "open") openQL(it);
    else if (m === "copy") copyItem(it);
    else if (m === "link") copyToClipboard(location.origin + it.downloadUrl).then(ok => toast(ok ? "下载链接已复制" : "复制失败", { err: !ok }));
    else if (m === "star") setFlag(it, "starred", !it.starred);
    else if (m === "pin") setFlag(it, "pinned", !it.pinned);
    else if (m === "cat" && b.dataset.c !== it.category) setCategory(it, b.dataset.c);
    else if (m === "del") removeItems([it.id]);
  });
}
function mobileMenu(x, y) {
  const h = `<a data-m="mac" href="/api/hub/client/mac.sh" download>${ic("laptop")}Mac 自动接收套件</a>
    <a data-m="and" href="/api/hub/client/android_root.sh" download>${ic("phone")}安卓 Root 自动接收</a>
    <button data-m="refresh">${ic("refresh")}刷新</button><button data-m="select">${ic("checkc")}多选</button>
    <hr><button class="danger" data-m="cleanup">${ic("trash")}清理临时项…</button>`;
  openMenuAt(h, x, y, (m) => {
    if (m === "refresh") load(true).then(() => S.online && toast("已刷新"));
    else if (m === "select") setSelecting(true);
    else if (m === "cleanup") cleanup();
  });
}

/* ---------------- Quick Look ---------------- */
let qlItem = null;
function openQL(it) {
  qlItem = it;
  const text = isText(it);
  let body;
  if (text) body = `<pre>${esc(it.text)}</pre>`;
  else if (!it.hasFile) body = `<div class="ql-file">${iconHtml(it, true)}<div>服务器上找不到该文件</div></div>`;
  else if (canThumb(it)) body = `<img src="${esc(inlineUrl(it))}" alt="">`;
  else if (isVideo(it)) body = `<video controls playsinline src="${esc(inlineUrl(it))}"></video>`;
  else if (isAudio(it)) body = `<audio controls src="${esc(inlineUrl(it))}"></audio>`;
  else body = `<div class="ql-file">${iconHtml(it, true)}<div style="font-weight:500;color:var(--text)">${esc(it.filename)}</div><div style="margin:4px 0 14px">${formatBytes(it.size)} · ${esc(it.category)}</div><a class="btn primary" href="${esc(it.downloadUrl)}" download>${ic("download")}下载</a></div>`;
  const acts = text
    ? `<button class="btn" data-q="copy">${ic("copy")}复制</button>`
    : (it.hasFile ? `<a class="btn plain" href="${esc(inlineUrl(it))}" target="_blank" rel="noopener" title="在新标签页打开">${ic("open")}</a><a class="btn" href="${esc(it.downloadUrl)}" download>${ic("download")}下载</a>` : "");
  $("ql").innerHTML = `<div class="ql-head">
      <div class="ql-title"><b>${esc(titleOf(it))}</b><span class="tabular">${isText(it) ? (it.text || "").length + " 字" : formatBytes(it.size)} · ${esc(it.fromDevice)} · ${esc(relTime(it))} · ${esc(expInfo(it).txt)}</span></div>
      <button class="ib" data-q="prev" title="上一项 (←)">${ic("chevL")}</button><button class="ib" data-q="next" title="下一项 (→)">${ic("chevR")}</button>
      ${acts}<button class="ib" data-q="close" title="关闭 (Esc)">${ic("x")}</button></div>
    <div class="ql-body">${body}</div>`;
  $("qlScrim").classList.add("open");
}
function closeQL() { $("qlScrim").classList.remove("open"); $("ql").innerHTML = ""; const id = qlItem && qlItem.id; qlItem = null; focusRow(id); }
function stepQL(d) {
  if (!qlItem) return; const v = visible(); const i = v.findIndex(x => x.id === qlItem.id);
  const n = v[i + d]; if (n) openQL(n);
}
$("qlScrim").addEventListener("click", (e) => {
  const b = e.target.closest("[data-q]");
  if (e.target.id === "qlScrim" || (b && b.dataset.q === "close")) return closeQL();
  if (!b) return;
  if (b.dataset.q === "copy") copyItem(qlItem);
  if (b.dataset.q === "prev") stepQL(-1);
  if (b.dataset.q === "next") stepQL(1);
});
function focusRow(id) { if (id == null) return; const el = document.querySelector(`[data-id="${id}"]`); if (el) el.focus({ preventScroll: false }); }

/* ---------------- Selection ---------------- */
function setSelecting(on) { S.selecting = on; S.sel.clear(); render(); }
function toggleSel(id) { S.sel.has(id) ? S.sel.delete(id) : S.sel.add(id); render(); }

/* ---------------- Upload queue ---------------- */
const Q = []; let qBusy = false, qSeq = 0, tfHideTimer = null, tfCollapsed = false;
function takeOpts() {
  const o = { star: S.opts.star, pin: S.opts.pin, cat: $("optCat").value };
  S.opts.star = S.opts.pin = false; $("optCat").value = ""; syncOpts();
  return o;
}
function syncOpts() { $("optStar").setAttribute("aria-pressed", S.opts.star); $("optPin").setAttribute("aria-pressed", S.opts.pin); }
function niceName(f) {
  let n = f.name || "";
  if (!n || /^image\.(png|jpe?g|gif|webp)$/i.test(n)) {
    const d = new Date(), p = (x) => String(x).padStart(2, "0");
    const ext = (n.split(".").pop() || (f.type.split("/")[1] || "png")).toLowerCase();
    n = `截图_${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}_${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}.${ext}`;
  }
  return n;
}
function enqueue(files) {
  files = Array.from(files || []).filter(f => f && f.size >= 0);
  if (!files.length) return;
  const opts = takeOpts();
  files.forEach(f => Q.push({ id: ++qSeq, file: f, name: niceName(f), size: f.size, loaded: 0, speed: 0, status: "queued", opts }));
  tfCollapsed = false; renderTf(); runQ();
}
async function runQ() {
  if (qBusy) return; qBusy = true;
  let t;
  while ((t = Q.find(x => x.status === "queued"))) await uploadOne(t);
  qBusy = false; renderTf();
  if (Q.length && Q.every(x => x.status === "done" || x.status === "canceled")) {
    clearTimeout(tfHideTimer);
    tfHideTimer = setTimeout(() => { if (!qBusy && Q.every(x => x.status !== "error" && x.status !== "queued")) { Q.length = 0; renderTf(); } }, 4000);
  }
}
function uploadOne(t) {
  return new Promise(resolve => {
    t.status = "uploading"; t.loaded = 0; t.err = ""; renderTf();
    const xhr = new XMLHttpRequest(); t.xhr = xhr;
    const qs = `filename=${encodeURIComponent(encodeURIComponent(t.name))}&from=${encodeURIComponent(detectMyDevice())}&starred=${t.opts.star ? "1" : "0"}&pinned=${t.opts.pin ? "1" : "0"}&category=${encodeURIComponent(t.opts.cat || "")}`;
    xhr.open("POST", `/api/hub/upload?${qs}`, true);
    let lastT = Date.now(), lastL = 0;
    xhr.upload.onprogress = (e) => {
      if (!e.lengthComputable) return;
      const now = Date.now(), dt = (now - lastT) / 1000;
      if (dt >= 0.4) { const inst = (e.loaded - lastL) / dt; t.speed = t.speed ? t.speed * 0.6 + inst * 0.4 : inst; lastT = now; lastL = e.loaded; }
      t.loaded = e.loaded; updateTfItem(t);
    };
    xhr.onload = () => {
      let d = null; try { d = JSON.parse(xhr.responseText); } catch (e) {}
      if (xhr.status === 200 && d && d.ok) {
        t.status = "done"; t.loaded = t.size;
        if (d.item) { upsert(d.item); render(); }
      } else { t.status = "error"; t.err = (d && d.error) || ("HTTP " + xhr.status); }
      t.xhr = null; renderTf(); resolve();
    };
    xhr.onerror = () => { t.status = "error"; t.err = "网络错误"; t.xhr = null; renderTf(); resolve(); };
    xhr.onabort = () => { t.status = "canceled"; t.xhr = null; renderTf(); resolve(); };
    xhr.send(t.file);
  });
}
function tfStat(t) {
  const pct = t.size ? Math.min(100, Math.round(t.loaded / t.size * 100)) : (t.status === "done" ? 100 : 0);
  if (t.status === "queued") return ["等待中", formatBytes(t.size)];
  if (t.status === "done") return ["已完成 · 其他设备会自动接收", formatBytes(t.size)];
  if (t.status === "canceled") return ["已取消", ""];
  if (t.status === "error") return ["失败：" + t.err, ""];
  const eta = t.speed > 0 ? " · 剩余 " + fmtDuration((t.size - t.loaded) / t.speed) : "";
  return [`${pct}% · ${formatBytes(t.loaded)} / ${formatBytes(t.size)}`, (t.speed ? formatBytes(t.speed) + "/s" : "") + eta];
}
function updateTfItem(t) {
  const el = document.getElementById("tf-" + t.id); if (!el) return;
  const pct = t.size ? Math.min(100, t.loaded / t.size * 100) : 0;
  el.querySelector(".bar > i").style.width = pct + "%";
  const [a, b] = tfStat(t);
  el.querySelector(".a").textContent = a; el.querySelector(".b").textContent = b;
  updateTfHead();
}
function updateTfHead() {
  const h = $("tf").querySelector(".ttl"); if (!h) return;
  const done = Q.filter(x => x.status === "done").length, err = Q.filter(x => x.status === "error").length;
  const active = Q.filter(x => x.status === "uploading" || x.status === "queued").length;
  h.textContent = active ? `正在上传 ${done + 1}/${Q.filter(x => x.status !== "canceled").length}` : (err ? `${err} 个文件上传失败` : `上传完成 · ${done} 个文件`);
}
function renderTf() {
  const box = $("tf");
  if (!Q.length) { box.classList.add("hidden"); box.innerHTML = ""; return; }
  box.classList.remove("hidden");
  const busy = Q.some(x => x.status === "uploading" || x.status === "queued");
  box.innerHTML = `<div class="tf-head"><span class="ttl"></span>
      ${busy ? "" : `<button class="btn plain" data-tf="clear">清除</button>`}
      <button class="ib" data-tf="collapse" title="${tfCollapsed ? "展开" : "收起"}">${ic(tfCollapsed ? "chevL" : "minus")}</button></div>
    <div class="tf-list ${tfCollapsed ? "hidden" : ""}">${Q.map(t => {
      const pct = t.size ? Math.min(100, t.loaded / t.size * 100) : (t.status === "done" ? 100 : 0);
      const [a, b] = tfStat(t);
      const btn = (t.status === "uploading" || t.status === "queued") ? `<button class="ib" data-tf="cancel" data-t="${t.id}" title="取消">${ic("x")}</button>`
        : (t.status === "error" || t.status === "canceled") ? `<button class="ib" data-tf="retry" data-t="${t.id}" title="重试">${ic("refresh")}</button>` : `<span style="color:#34C759;display:inline-flex">${ic("check")}</span>`;
      return `<div class="tf-item ${t.status}" id="tf-${t.id}"><div class="tf-top"><span class="tf-name" title="${esc(t.name)}">${esc(t.name)}</span>${btn}</div>
        <div class="bar"><i style="width:${pct}%"></i></div><div class="tf-stat tabular"><span class="a">${esc(a)}</span><span class="b">${esc(b)}</span></div></div>`;
    }).join("")}</div>`;
  updateTfHead();
}
$("tf").addEventListener("click", (e) => {
  const b = e.target.closest("[data-tf]"); if (!b) return;
  const t = Q.find(x => x.id === +b.dataset.t);
  const a = b.dataset.tf;
  if (a === "cancel" && t) { if (t.xhr) t.xhr.abort(); else { t.status = "canceled"; renderTf(); } }
  else if (a === "retry" && t) { t.status = "queued"; t.loaded = 0; t.speed = 0; renderTf(); runQ(); }
  else if (a === "clear") { for (let i = Q.length - 1; i >= 0; i--) if (Q[i].status !== "uploading" && Q[i].status !== "queued") Q.splice(i, 1); renderTf(); }
  else if (a === "collapse") { tfCollapsed = !tfCollapsed; renderTf(); }
});

/* ---------------- Text send ---------------- */
const txt = $("txt");
function autoGrow() { txt.style.height = "auto"; txt.style.height = Math.min(240, txt.scrollHeight) + "px"; }
function updateComposer() {
  const n = txt.value.length;
  $("btnSend").disabled = !txt.value.trim();
  $("charCount").textContent = n ? `${n} 字 · ${MOD} + ↵ 发送` : `${MOD} + ↵ 发送`;
  autoGrow();
}
let sending = false;
async function sendText() {
  const text = txt.value.trim(); if (!text || sending) return;
  sending = true; $("btnSend").disabled = true;
  const o = takeOpts();
  try {
    const d = await postJSON("/api/hub/text", { text, from: detectMyDevice(), starred: o.star, pinned: o.pin });
    txt.value = ""; updateComposer();
    if (d.item) { upsert(d.item); render(); }
    toast("已发送 · 已同步到各设备剪贴板");
  } catch (e) {
    S.opts.star = o.star; S.opts.pin = o.pin; syncOpts();
    toast("发送失败：" + e.message, { err: true });
  } finally { sending = false; updateComposer(); }
}
async function pasteAndSend() {
  try {
    const t = await navigator.clipboard.readText();
    if (!t || !t.trim()) { toast("剪贴板里没有文字"); return; }
    txt.value = t; updateComposer(); await sendText();
  } catch (e) { txt.focus(); toast(`浏览器不允许直接读取剪贴板，请按 ${MOD} + V 粘贴后发送`); }
}
txt.addEventListener("input", updateComposer);
txt.addEventListener("keydown", (e) => { if ((e.ctrlKey || e.metaKey) && e.key === "Enter") { e.preventDefault(); sendText(); } });
txt.addEventListener("paste", (e) => {
  const cd = e.clipboardData; if (!cd) return;
  if (cd.files && cd.files.length && !cd.getData("text/plain")) { e.preventDefault(); enqueue(cd.files); }
});
$("optStar").onclick = () => { S.opts.star = !S.opts.star; syncOpts(); };
$("optPin").onclick = () => { S.opts.pin = !S.opts.pin; syncOpts(); };
$("fileInput").addEventListener("change", (e) => { enqueue(e.target.files); e.target.value = ""; });

/* ---------------- Search ---------------- */
const searchInputs = [...document.querySelectorAll("[data-search] input")];
function setQ(q) {
  S.q = q;
  searchInputs.forEach(i => { if (i.value !== q) i.value = q; i.parentElement.classList.toggle("has-q", !!q); });
  renderHeader(); renderContent();
}
searchInputs.forEach(i => {
  i.addEventListener("input", () => setQ(i.value));
  i.addEventListener("keydown", (e) => {
    if (e.key === "Escape") { e.stopPropagation(); if (i.value) setQ(""); else i.blur(); }
    if (e.key === "Enter" || e.key === "ArrowDown") { e.preventDefault(); const f = document.querySelector("#content [data-id]"); if (f) f.focus(); }
  });
});
function focusSearch() { const i = searchInputs.find(x => x.offsetParent !== null) || searchInputs[0]; i.focus(); i.select(); }

/* ---------------- Global events ---------------- */
document.addEventListener("click", (e) => {
  if (menuEl && !menuEl.contains(e.target)) closeMenu();
  const a = e.target.closest("[data-act]");
  const host = e.target.closest("[data-id]");
  const it = host ? byId(+host.dataset.id) : null;
  if (S.selecting && host && it) { e.preventDefault(); toggleSel(it.id); return; }
  if (!a) return;
  const act = a.dataset.act;
  switch (act) {
    case "view": S.view = a.dataset.v; S.sel.clear(); render(); $("main").scrollTop = 0; break;
    case "layout": S.layout = a.dataset.v; store.set("hub.layout", S.layout); render(); break;
    case "clearq": setQ(""); break;
    case "retry": load(true); break;
    case "pick": $("fileInput").click(); break;
    case "send": sendText(); break;
    case "pastesend": pasteAndSend(); break;
    case "cleanup": cleanup(); break;
    case "select": setSelecting(true); break;
    case "selectdone": setSelecting(false); break;
    case "selall": { const v = visible(); if (S.sel.size === v.length) S.sel.clear(); else v.forEach(x => S.sel.add(x.id)); render(); break; }
    case "bstar": {
      const sel = [...S.sel].map(byId).filter(Boolean); if (!sel.length) return toast("请先选择项目");
      const val = !sel.every(x => x.starred);
      Promise.all(sel.map(x => setFlag(x, "starred", val, true))).then(() => toast(val ? `已收藏 ${sel.length} 项` : `已取消收藏 ${sel.length} 项`));
      break;
    }
    case "bdel": { if (!S.sel.size) return toast("请先选择项目"); removeItems([...S.sel]); setSelecting(false); break; }
    case "mmore": { const r = a.getBoundingClientRect(); mobileMenu(r.right - 200, r.bottom + 6); break; }
    case "open": if (it) openQL(it); break;
    case "copy": if (it) copyItem(it); break;
    case "star": if (it) setFlag(it, "starred", !it.starred); break;
    case "pin": if (it) setFlag(it, "pinned", !it.pinned); break;
    case "del": if (it) removeItems([it.id]); break;
    case "more": if (it) { const r = a.getBoundingClientRect(); itemMenu(it, r.right - 200, r.bottom + 4); } break;
  }
});
$("content").addEventListener("contextmenu", (e) => {
  const host = e.target.closest("[data-id]"); if (!host || S.selecting) return;
  const it = byId(+host.dataset.id); if (!it) return;
  e.preventDefault(); itemMenu(it, e.clientX, e.clientY);
});
$("content").addEventListener("keydown", (e) => {
  const host = e.target.closest("[data-id]"); if (!host || e.target !== host) return;
  const it = byId(+host.dataset.id); if (!it) return;
  if (e.key === " " || e.key === "Enter") { e.preventDefault(); S.selecting ? toggleSel(it.id) : openQL(it); }
  else if (e.key === "Delete" || e.key === "Backspace") { e.preventDefault(); const next = host.nextElementSibling || host.previousElementSibling; removeItems([it.id]); if (next) focusRow(next.dataset.id); }
  else if (e.key === "ArrowDown" || e.key === "ArrowRight" && S.layout === "grid") { e.preventDefault(); const n = host.nextElementSibling; if (n) n.focus(); }
  else if (e.key === "ArrowUp" || e.key === "ArrowLeft" && S.layout === "grid") { e.preventDefault(); const p = host.previousElementSibling; if (p) p.focus(); else focusSearch(); }
  else if ((e.key === "c" || e.key === "C") && (e.metaKey || e.ctrlKey) && isText(it) && !window.getSelection().toString()) { e.preventDefault(); copyItem(it); }
});
window.addEventListener("keydown", (e) => {
  const tag = (document.activeElement && document.activeElement.tagName) || "";
  const typing = tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT";
  if (e.key === "Escape") {
    if (menuEl) return closeMenu();
    if ($("dlgScrim").classList.contains("open")) return S.dlgClose && S.dlgClose();
    if (qlItem) return closeQL();
    if (S.selecting) return setSelecting(false);
    if (typing) return document.activeElement.blur();
    if (S.q) return setQ("");
    return;
  }
  if (qlItem) {
    if (e.key === "ArrowLeft" || e.key === "ArrowUp") { e.preventDefault(); stepQL(-1); }
    else if (e.key === "ArrowRight" || e.key === "ArrowDown") { e.preventDefault(); stepQL(1); }
    else if (e.key === " " && !(e.target.closest && e.target.closest("video,audio"))) { e.preventDefault(); closeQL(); }
    return;
  }
  if ((e.metaKey || e.ctrlKey) && (e.key === "k" || e.key === "K" || e.key === "f" || e.key === "F")) { e.preventDefault(); focusSearch(); return; }
  if ((e.metaKey || e.ctrlKey) && (e.key === "o" || e.key === "O")) { e.preventDefault(); $("fileInput").click(); return; }
  if (typing || e.metaKey || e.ctrlKey || e.altKey) return;
  if (e.key === "/") { e.preventDefault(); focusSearch(); }
  else if (e.key === "n" || e.key === "N") { e.preventDefault(); txt.focus(); }
});
window.addEventListener("paste", (e) => {
  const tag = (document.activeElement && document.activeElement.tagName) || "";
  if (tag === "TEXTAREA" || tag === "INPUT") return;
  const cd = e.clipboardData; if (!cd) return;
  if (cd.files && cd.files.length) { e.preventDefault(); enqueue(cd.files); return; }
  const t = cd.getData("text/plain");
  if (t && t.trim()) { e.preventDefault(); txt.value = txt.value ? txt.value + "\n" + t : t; updateComposer(); txt.focus(); toast(`已放入输入框，按 ${MOD} + ↵ 发送`); }
});
let dragDepth = 0;
const hasFiles = (e) => e.dataTransfer && Array.from(e.dataTransfer.types || []).includes("Files");
window.addEventListener("dragenter", (e) => { if (!hasFiles(e)) return; e.preventDefault(); dragDepth++; $("drop").classList.add("show"); });
window.addEventListener("dragover", (e) => { if (hasFiles(e)) e.preventDefault(); });
window.addEventListener("dragleave", (e) => { if (!hasFiles(e)) return; dragDepth = Math.max(0, dragDepth - 1); if (!dragDepth) $("drop").classList.remove("show"); });
window.addEventListener("drop", (e) => {
  if (!hasFiles(e)) return; e.preventDefault(); dragDepth = 0; $("drop").classList.remove("show");
  enqueue(e.dataTransfer.files);
});
document.addEventListener("error", (e) => {
  const t = e.target;
  if (t && t.tagName === "IMG" && t.closest("#content")) t.outerHTML = `<div class="ficon c-img" data-act="open">${ic("image")}</div>`;
}, true);
window.addEventListener("resize", closeMenu);
$("main").addEventListener("scroll", closeMenu, { passive: true });
window.addEventListener("beforeunload", (e) => {
  if (Q.some(x => x.status === "uploading" || x.status === "queued")) { e.preventDefault(); e.returnValue = ""; }
});
window.addEventListener("pagehide", flushDeletes);
document.addEventListener("visibilitychange", () => { if (!document.hidden) load(false); });

/* ---------------- Boot ---------------- */
syncOpts(); updateComposer(); render();
load(true);
setInterval(() => { if (!document.hidden && !menuEl && !qlItem && !S.selecting) load(false); }, 8000);
setInterval(tick, 30000);
</script>
</body>
</html>
"""


if __name__ == "__main__":
    os.makedirs(HISTORY_DIR, exist_ok=True)
    os.makedirs(PERM_ITEMS_DIR, exist_ok=True)
    cleaner_thread = threading.Thread(target=background_cleaner_loop, daemon=True)
    cleaner_thread.start()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), SyncHubHandler)
    print(f"[SyncHub] Listening on 0.0.0.0:{PORT} (Retention: {RETENTION_HOURS}h)...", flush=True)
    print("[SyncHub] Auth: mode=%s, credentials %s" % (AUTH_MODE, "loaded" if get_hub_credentials() else "NOT FOUND - all requests will be rejected"), flush=True)
    server.serve_forever()
