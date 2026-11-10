#!/usr/bin/env python3
"""本地测试用的迷你“nginx”：/api/hub/* 与 /hub/* → SyncHub(:HUB)，其余 → SyncClipboard 官方服务器(:SC)。
与生产 nginx_020814.xyz.conf 的路由规则一致。仅用于本机集成测试。"""
import http.client, sys
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

PORT, SC, HUB = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def _fwd(self):
        port = HUB if self.path.startswith(("/api/hub/", "/hub")) else SC
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=600)
        n = int(self.headers.get("Content-Length") or 0)
        c.putrequest(self.command, self.path, skip_host=True, skip_accept_encoding=True)
        for k, v in self.headers.items():
            if k.lower() not in ("connection", "transfer-encoding"):
                c.putheader(k, v)
        c.endheaders()
        left = n
        while left > 0:
            chunk = self.rfile.read(min(1 << 20, left))
            if not chunk: break
            c.send(chunk); left -= len(chunk)
        r = c.getresponse()
        body = r.read()
        self.send_response(r.status)
        for k, v in r.getheaders():
            if k.lower() not in ("transfer-encoding", "connection", "content-length"):
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD": self.wfile.write(body)
        c.close()
    do_GET = do_PUT = do_POST = do_DELETE = do_HEAD = do_OPTIONS = _fwd

ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
