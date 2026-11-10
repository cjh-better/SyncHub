#!/usr/bin/env python3
"""Tiny local mock of the official SyncClipboard server (v3 WebDAV-style API) for ClipHarness.
GET/PUT /SyncClipboard.json, GET/PUT /file/<name>, Basic auth. Local test use only.
Usage: python3 mock_syncclipboard_server.py PORT USER PASS"""
import base64, json, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, USER, PASS = int(sys.argv[1]), sys.argv[2], sys.argv[3]
STATE = {"profile": json.dumps({"type": "Text", "hash": "", "text": "", "hasData": False, "dataName": None, "size": 0}).encode(),
         "files": {}, "puts": 0}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def auth_ok(self):
        want = "Basic " + base64.b64encode(f"{USER}:{PASS}".encode()).decode()
        if self.headers.get("Authorization") != want:
            self.send_response(401); self.send_header("Content-Length", "0"); self.end_headers(); return False
        return True
    def body(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        return self.rfile.read(n) if n else b""
    def reply(self, code, data=b"", ctype="application/json"):
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        if not self.auth_ok(): return
        p = urllib.parse.urlparse(self.path).path
        if p == "/SyncClipboard.json": return self.reply(200, STATE["profile"])
        if p.startswith("/file/"):
            name = urllib.parse.unquote(p[6:])
            if name in STATE["files"]: return self.reply(200, STATE["files"][name], "application/octet-stream")
            return self.reply(404)
        if p == "/_debug/state":
            return self.reply(200, json.dumps({"profile": json.loads(STATE["profile"]), "files": sorted(STATE["files"]), "puts": STATE["puts"]}, ensure_ascii=False).encode())
        self.reply(404)
    def do_PUT(self):
        if not self.auth_ok(): return
        p = urllib.parse.urlparse(self.path).path
        data = self.body()
        if p == "/SyncClipboard.json":
            json.loads(data)  # must be valid JSON
            STATE["profile"] = data; STATE["puts"] += 1; return self.reply(200)
        if p.startswith("/file/"):
            STATE["files"][urllib.parse.unquote(p[6:])] = data; return self.reply(200)
        self.reply(404)
    def do_POST(self):  # /_debug/set : replace the profile as another device would (raw JSON body)
        p = urllib.parse.urlparse(self.path).path
        data = self.body()
        if p == "/_debug/set": STATE["profile"] = data; return self.reply(200)
        if p.startswith("/_debug/file/"): STATE["files"][urllib.parse.unquote(p[13:])] = data; return self.reply(200)
        self.reply(404)

ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
