# -*- coding: utf-8 -*-
"""
SyncClipboard + SyncHub 全链路端到端健康检查脚本
"""
import base64
import os
import json
import urllib.request

BASE_URL = os.environ.get("SYNCHUB_SERVER_URL", "https://020814.xyz").rstrip("/")
HUB_URL = BASE_URL + "/hub/"
API_LIST_URL = BASE_URL + "/api/hub/items"
SC_PROFILE_URL = BASE_URL + "/SyncClipboard.json"
USER = os.environ.get("SYNCHUB_USER", "admin")
PASS = os.environ.get("SYNCHUB_PASSWORD", "")

def get_auth_header():
    token = base64.b64encode(f"{USER}:{PASS}".encode()).decode()
    return {"Authorization": f"Basic {token}", "User-Agent": "SyncHub-Verifier/2.0"}

def check(name, url):
    req = urllib.request.Request(url, headers=get_auth_header())
    with urllib.request.urlopen(req, timeout=15) as resp:
        body = resp.read()
        print(f"[PASS] {name}: HTTP {resp.status} ({len(body)} bytes)")
        return body

def main():
    print("=== 开始验证 SyncClipboard + SyncHub 线上服务 ===")
    html = check("SyncHub Spatial Glass Web UI (/hub/)", HUB_URL).decode("utf-8", errors="replace")
    assert "SyncHub" in html and "跨端" in html, "Web UI 标题校验失败"

    raw_list = check("SyncHub 元数据与列表接口 (/api/hub/list)", API_LIST_URL).decode("utf-8")
    data = json.loads(raw_list)
    assert data.get("ok") is True, "API 返回状态异常"
    print(f"       当前云端条目数: {len(data.get('items', []))} 条")

    check("SyncClipboard 原生同步端点 (/SyncClipboard.json)", SC_PROFILE_URL)
    print("=== 全部端点验证通过！ ===")

if __name__ == "__main__":
    main()
