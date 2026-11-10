#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SyncHub Windows Client:
1. --send <file_path> [--star] [--pin]
   Streams any file (including 500MB - 1GB large files) in 1MB chunks to https://020814.xyz/api/hub/upload
   with a flat, light macOS-style Tkinter progress window.
2. --daemon
   Runs silently in the background, polling https://020814.xyz/api/hub/auto-pull?device=windows
   and automatically saving files sent from Phone (Android/iOS/Web) or Mac directly into:
   K:\跨端传输文件
"""

import os
import sys
import time
import json
import ssl
import urllib.parse
import urllib.request
import http.client
import subprocess
import threading

SERVER_HOST = os.environ.get("SYNCHUB_SERVER_HOST", "020814.xyz")
SERVER_URL = f"https://{SERVER_HOST}"
RECV_DIR = r"K:\跨端传输文件"
STATE_DIR = os.path.join(os.environ.get("APPDATA", r"C:\Users\Administrator\AppData\Roaming"), "SyncClipboard")
STATE_FILE = os.path.join(STATE_DIR, "synchub_win_state.json")
LOG_FILE = os.path.join(STATE_DIR, "synchub_win.log")


def log_msg(msg: str):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(f"[{ts}] {msg}\n")
    except Exception:
        pass


def format_bytes(b: int) -> str:
    if b <= 0:
        return "0 B"
    units = ["B", "KB", "MB", "GB"]
    i = 0
    val = float(b)
    while val >= 1024 and i < len(units) - 1:
        val /= 1024.0
        i += 1
    return f"{val:.2f} {units[i]}" if i > 1 else f"{int(val)} {units[i]}"


def win_notify(title: str, message: str):
    try:
        ps_script = f"""
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
$template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
$textNodes = $template.GetElementsByTagName("text")
$textNodes.Item(0).AppendChild($template.CreateTextNode({json.dumps(title)})) > $null
$textNodes.Item(1).AppendChild($template.CreateTextNode({json.dumps(message)})) > $null
$toast = [Windows.UI.Notifications.ToastNotification]::new($template)
$notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("跨端传输助手")
$notifier.Show($toast)
"""
        subprocess.Popen(
            ["powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command", ps_script],
            creationflags=0x08000000
        )
    except Exception as e:
        log_msg(f"Notify error: {e}")


def load_last_id() -> int:
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                return int(data.get("last_id", 0))
        except Exception:
            pass
    return 0


def save_last_id(last_id: int):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(STATE_FILE, "w", encoding="utf-8") as f:
            json.dump({"last_id": last_id, "updated_at": time.time()}, f)
    except Exception as e:
        log_msg(f"Save state error: {e}")


def get_unique_dest_path(folder: str, filename: str) -> str:
    os.makedirs(folder, exist_ok=True)
    base, ext = os.path.splitext(filename)
    candidate = os.path.join(folder, filename)
    if not os.path.exists(candidate):
        return candidate
    idx = 1
    while True:
        cand = os.path.join(folder, f"{base} ({idx}){ext}")
        if not os.path.exists(cand):
            return cand
        idx += 1


def poll_once():
    last_id = load_last_id()
    ctx = ssl.create_default_context()
    url = f"{SERVER_URL}/api/hub/auto-pull?device=windows&since_id={last_id}"
    req = urllib.request.Request(url, headers={"User-Agent": "SyncHub-Windows/1.0"})
    with urllib.request.urlopen(req, timeout=15, context=ctx) as resp:
        data = json.loads(resp.read().decode("utf-8"))

    if not data.get("ok"):
        return

    items = data.get("items") or []
    latest_id = int(data.get("latestId") or last_id)

    for item in items:
        dl_path = item.get("downloadUrl")
        fname = item.get("filename") or f"file_{item.get('id')}"
        expected_size = int(item.get("size") or 0)
        from_dev = item.get("fromDevice") or "手机/其他设备"
        cat = item.get("category") or "其他"

        if not dl_path:
            continue

        os.makedirs(RECV_DIR, exist_ok=True)
        dest_file = os.path.join(RECV_DIR, fname)
        if os.path.exists(dest_file) and expected_size > 0 and os.path.getsize(dest_file) == expected_size:
            log_msg(f"Skipped already downloaded file: {fname}")
            continue
        if os.path.exists(dest_file):
            dest_file = get_unique_dest_path(RECV_DIR, fname)

        part_file = dest_file + ".downloading"
        dl_url = f"{SERVER_URL}{dl_path}"
        log_msg(f"Downloading incoming file from {from_dev}: {fname} ({expected_size} bytes) -> {dest_file}")

        dl_req = urllib.request.Request(dl_url, headers={"User-Agent": "SyncHub-Windows/1.0"})
        with urllib.request.urlopen(dl_req, timeout=1800, context=ctx) as r, open(part_file, "wb") as out_f:
            while True:
                chunk = r.read(1024 * 1024)
                if not chunk:
                    break
                out_f.write(chunk)

        os.replace(part_file, dest_file)
        log_msg(f"Saved incoming file to {dest_file}")
        win_notify(
            f"📥 已自动接收文件 ({cat})",
            f"来自 [{from_dev}]: {fname} ({format_bytes(os.path.getsize(dest_file))})\n已存入桌面【跨端传输文件】(K盘)"
        )

    if latest_id > last_id:
        save_last_id(latest_id)


def run_daemon():
    os.makedirs(RECV_DIR, exist_ok=True)
    log_msg(f"SyncHub Windows Auto-Receiver Daemon started. Watching -> {RECV_DIR}")
    while True:
        try:
            poll_once()
        except Exception as e:
            log_msg(f"Poll warning: {e}")
        time.sleep(3)


def send_file_with_gui(file_path: str, starred: bool = False, pinned: bool = False):
    if not os.path.isfile(file_path):
        return

    filename = os.path.basename(file_path)
    file_size = os.path.getsize(file_path)

    import tkinter as tk
    from tkinter import ttk

    # ---- Flat light macOS-style palette (UI only; upload protocol unchanged) ----
    BG = "#FFFFFF"
    TEXT = "#1D1D1F"
    TEXT_2 = "#6E6E73"
    ACCENT = "#007AFF"
    TRACK = "#EDEDF0"
    OK = "#248A3D"
    ERR = "#D70015"
    FONT = "Microsoft YaHei UI"

    W, H = 440, 150
    root = tk.Tk()
    root.title("跨端传输 · 发送文件")
    root.resizable(False, False)
    root.configure(bg=BG)
    root.attributes("-topmost", True)

    # Center on screen
    sw = root.winfo_screenwidth()
    sh = root.winfo_screenheight()
    root.geometry(f"{W}x{H}+{(sw-W)//2}+{(sh-H)//2}")

    card = tk.Frame(root, bg=BG, bd=0, highlightthickness=0)
    card.pack(fill="both", expand=True, padx=20, pady=(18, 16))

    # Header: flat file badge + title / file line
    head = tk.Frame(card, bg=BG)
    head.pack(fill="x")
    ext = (os.path.splitext(filename)[1][1:5] or "FILE").upper()
    badge = tk.Label(
        head, text=ext, width=5, height=2,
        fg=ACCENT, bg="#E8F1FE", font=(FONT, 8, "bold"), bd=0
    )
    badge.pack(side="left", padx=(0, 12))
    head_text = tk.Frame(head, bg=BG)
    head_text.pack(side="left", fill="x", expand=True)

    mode_str = "发送到其他设备 · 收藏并永久保留" if starred else "发送到其他设备 · 手机与 Mac 自动接收"
    lbl_title = tk.Label(
        head_text, text=f"{mode_str}", anchor="w",
        fg=TEXT_2, bg=BG, font=(FONT, 9)
    )
    lbl_title.pack(fill="x")

    short_name = filename if len(filename) <= 40 else filename[:24] + "…" + filename[-14:]
    lbl_file = tk.Label(
        head_text, text=f"{short_name}  ·  {format_bytes(file_size)}", anchor="w",
        fg=TEXT, bg=BG, font=(FONT, 10, "bold")
    )
    lbl_file.pack(fill="x")

    style = ttk.Style()
    style.theme_use("default")
    style.configure(
        "Apple.Horizontal.TProgressbar",
        troughcolor=TRACK, background=ACCENT, bordercolor=TRACK,
        lightcolor=ACCENT, darkcolor=ACCENT, thickness=6, borderwidth=0
    )
    pbar = ttk.Progressbar(
        card, style="Apple.Horizontal.TProgressbar",
        orient="horizontal", length=W - 40, mode="determinate", maximum=100
    )
    pbar.pack(fill="x", pady=(16, 8))

    lbl_stat = tk.Label(
        card, text="正在连接 020814.xyz …", anchor="w",
        fg=TEXT_2, bg=BG, font=(FONT, 9)
    )
    lbl_stat.pack(fill="x")

    def upload_worker():
        start_t = time.time()
        try:
            ctx = ssl.create_default_context()
            conn = http.client.HTTPSConnection(SERVER_HOST, 443, timeout=1800, context=ctx)
            qs = urllib.parse.urlencode({
                # 服务端会对 filename 解码两次（parse_qs + unquote），先 quote 一次，"%" 等字符才能原样保留
                "filename": urllib.parse.quote(filename, safe=""),
                "from": "Windows",
                "starred": "1" if starred else "0",
                "pinned": "1" if pinned else "0"
            })
            conn.putrequest("POST", f"/api/hub/upload?{qs}")
            conn.putheader("Content-Type", "application/octet-stream")
            conn.putheader("Content-Length", str(file_size))
            conn.endheaders()

            sent = 0
            with open(file_path, "rb") as f:
                while True:
                    chunk = f.read(1024 * 1024)
                    if not chunk:
                        break
                    conn.send(chunk)
                    sent += len(chunk)
                    pct = (sent / file_size * 100.0) if file_size > 0 else 100.0
                    elapsed = max(0.1, time.time() - start_t)
                    speed = (sent / (1024 * 1024)) / elapsed
                    root.after(0, lambda p=pct, s=sent, sp=speed: (
                        pbar.configure(value=p),
                        lbl_stat.configure(text=f"{p:.0f}%  ·  {format_bytes(s)} / {format_bytes(file_size)}  ·  {sp:.1f} MB/s")
                    ))

            resp = conn.getresponse()
            resp_body = resp.read().decode("utf-8", errors="replace")
            conn.close()

            if resp.status == 200:
                root.after(0, lambda: (
                    pbar.configure(value=100),
                    lbl_title.configure(text="已发送 · 手机与 Mac 将自动接收", fg=OK),
                    lbl_stat.configure(text="100%  ·  上传完成，窗口即将自动关闭…", fg=TEXT_2)
                ))
                win_notify("✅ 跨端传输发送成功", f"{filename} ({format_bytes(file_size)}) 已发送至手机与 Mac")
                time.sleep(1.2)
                root.after(0, root.destroy)
            else:
                root.after(0, lambda: lbl_stat.configure(text=f"上传失败 (HTTP {resp.status})：{resp_body[:80]}", fg=ERR))
        except Exception as e:
            root.after(0, lambda err=str(e): lbl_stat.configure(text=f"上传出错：{err}", fg=ERR))

    t = threading.Thread(target=upload_worker, daemon=True)
    t.start()
    root.mainloop()


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args or "--daemon" in args:
        run_daemon()
    elif "--send" in args:
        idx = args.index("--send")
        target = args[idx + 1] if idx + 1 < len(args) else ""
        is_star = "--star" in args
        is_pin = "--pin" in args
        send_file_with_gui(target, starred=is_star, pinned=is_pin)
