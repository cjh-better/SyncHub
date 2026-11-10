# 服务端部署与日常运维指南 (DEPLOYMENT & OPS GUIDE)

## 一、 服务端组件分布 (`<VPS_IP>`)

1. **SyncClipboard 容器服务 (`127.0.0.1:5033`)**
   - 目录：`/opt/stacks/syncclipboard`
   - 数据卷：`/opt/stacks/syncclipboard/data/server`
   - 核心数据库：`/opt/stacks/syncclipboard/data/server/data/history.db`
   - 物理文件池：`/opt/stacks/syncclipboard/data/server/file/` 与 `/opt/stacks/syncclipboard/data/server/data/`

2. **SyncHub 大文件流式与收藏中心服务 (`127.0.0.1:5034`)**
   - 源码路径：`/usr/local/bin/synchub-server.py`
   - 服务单元：`/etc/systemd/system/synchub.service`
   - 核心特性：
     - 采用 Python 原生流式分块读写（64KB/1MB 缓冲区），上传 500MB~1GB 大文件时内存占用恒定低于 30MB。
     - 自动在 SQLite `HistoryGenericData` 表基础上扩展 `SyncHubMeta` 元数据表（记录 `pinned` 置顶、`starred` 收藏、`category` 8 大分类、`expire_at` 过期时间戳、`size_bytes` 文件大小），与原版 SyncClipboard 完全兼容。
     - 后台清理线程每 10 分钟巡检一次：自动清理超过 **72 小时（3 天）** 且 **未收藏 (`starred=0`)、未置顶 (`pinned=0`)** 的普通临时文件；点击了收藏或置顶的条目将**永久保留**。

3. **Nginx Proxy Manager 流式反向代理 (`https://020814.xyz`)**
   - 配置文件：`/root/npm/data/nginx/proxy_host/1.conf`
   - 关键大文件流式参数（防止 Nginx 缓存 500MB 文件导致超时或磁盘写满）：
     ```nginx
     client_max_body_size 2048m;
     proxy_request_buffering off;
     proxy_buffering off;
     proxy_read_timeout 3600s;
     proxy_send_timeout 3600s;
     ```
   - 路由规则：
     - `/hub`、`/hub/`、`/api/hub/*` -> 转发至 `http://172.17.0.1:5034` (`synchub.service`)
     - `/` 其余路径 -> 转发至 `http://172.17.0.1:5033` (`syncclipboard-server`)

---

## 二、 常用运维命令速查

### 1. 查看与重启 SyncHub 服务
```bash
# 查看运行状态与实时日志
systemctl status synchub.service
journalctl -u synchub.service -f -n 50

# 重启服务
systemctl restart synchub.service
```

### 2. 一键从本地电脑热更新代码到 VPS
在本地 Windows 终端运行交付包中的自动化部署脚本：
```powershell
python "m:\gemini\SyncClipboard_SyncHub_完整交付包\05_自动化部署与验收测试脚本\deploy_synchub_to_vps.py"
```

### 3. 查看与管理 SyncClipboard Docker 容器
```bash
cd /opt/stacks/syncclipboard
docker compose ps
docker compose logs -f --tail=50
docker compose restart
```

### 4. 异地加密备份 (`vps-backup-gdrive`) 与 Memos 7 天自动清理
- **备份状态检查**：
  ```bash
  systemctl status vps-backup-gdrive.timer
  systemctl start vps-backup-gdrive.service   # 手动立即触发一次加密备份至 Google Drive
  ```
- **Memos (`msg.020814.xyz`) 7 天自动清理定时任务**：
  - 位于 `/etc/cron.daily/memos-cleanup-7d`，每日凌晨自动清理 7 天以前的 Memo 记录、附件资源并执行 SQLite `VACUUM` 释放磁盘空间。
