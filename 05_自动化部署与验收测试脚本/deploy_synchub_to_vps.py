# -*- coding: utf-8 -*-
"""
一键将本地修改后的 synchub_server.py 部署至 VPS 并重启 synchub.service
"""
import os
import time
import paramiko

VPS_HOST = os.environ.get("SYNCHUB_VPS_HOST", "")
VPS_PORT = int(os.environ.get("SYNCHUB_VPS_PORT", "22"))
VPS_USER = os.environ.get("SYNCHUB_VPS_USER", "root")
VPS_PASS = os.environ.get("SYNCHUB_VPS_PASSWORD", "")

LOCAL_SERVER_PY = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "01_服务端_SyncClipboard与SyncHub", "synchub_server.py"))
REMOTE_SERVER_PY = "/usr/local/bin/synchub-server.py"

def main():
    if not VPS_HOST or not VPS_PASS:
        raise SystemExit("请先设置环境变量 SYNCHUB_VPS_HOST / SYNCHUB_VPS_PASSWORD（参考 .env.example）")
    from paramiko.transport import Transport
    import paramiko.kex_curve25519
    Transport._kex_info["curve25519-sha256"] = paramiko.kex_curve25519.KexCurve25519
    if "curve25519-sha256" not in Transport._preferred_kex:
        Transport._preferred_kex = ("curve25519-sha256",) + tuple(Transport._preferred_kex)

    print(f"[1/3] 正在连接 VPS {VPS_HOST} ...")
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    for attempt in range(4):
        try:
            ssh.connect(VPS_HOST, port=VPS_PORT, username=VPS_USER, password=VPS_PASS, timeout=20, banner_timeout=30)
            break
        except Exception:
            if attempt == 3:
                raise
            time.sleep(2)

    print(f"[2/3] 正在上传 {LOCAL_SERVER_PY} -> {REMOTE_SERVER_PY} ...")
    sftp = ssh.open_sftp()
    sftp.put(LOCAL_SERVER_PY, REMOTE_SERVER_PY)
    sftp.chmod(REMOTE_SERVER_PY, 0o755)
    sftp.close()

    print("[3/3] 正在重启 synchub.service 并检查运行状态 ...")
    _, stdout, stderr = ssh.exec_command("systemctl restart synchub.service && sleep 1 && systemctl is-active synchub.service")
    status = stdout.read().decode().strip()
    print(f"synchub.service 状态: {status}")
    ssh.close()
    assert status == "active", f"服务未正常启动: {stderr.read().decode()}"
    print("✅ 部署与重启成功！")

if __name__ == "__main__":
    main()
