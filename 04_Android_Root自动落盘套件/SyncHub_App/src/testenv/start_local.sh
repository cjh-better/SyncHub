#!/usr/bin/env bash
# 启动本地测试环境（不连接生产服务器）：
#   SyncClipboard 官方服务器 v3.3.3 (:15033) + synchub_server.py (:15034，共用同一个 history.db) + 路由代理 (:15080)
set -e
D=${1:-/tmp/synchub-it}
rm -rf "$D"; mkdir -p "$D"
SC_DIR=$HOME/scserver
export DOTNET_ROOT=$HOME/dotnet PATH=$HOME/dotnet:$PATH
export SYNCCLIPBOARD_USERNAME=testuser SYNCCLIPBOARD_PASSWORD=testpass Kestrel__Endpoints__http__Url=http://127.0.0.1:15033
cp "$SC_DIR/appsettings.json" "$D/"
(cd "$D" && setsid nohup dotnet "$SC_DIR/SyncClipboard.Server.dll" --contentRoot "$D" > "$D/sc.log" 2>&1 < /dev/null &)
for i in $(seq 1 60); do curl -s -o /dev/null -u testuser:testpass http://127.0.0.1:15033/SyncClipboard.json && break; sleep 0.5; done
# 让 SyncClipboard 建库后再启动 SyncHub（与生产一致：两者共用 server/data/history.db）
curl -s -u testuser:testpass -X PUT -H 'Content-Type: application/json' \
  -d '{"type":"Text","hash":"","text":"init","hasData":false}' http://127.0.0.1:15033/SyncClipboard.json >/dev/null || true
setsid nohup python3 /workspace/synchub/test/run_local.py /workspace/synchub/work/01_服务端_SyncClipboard与SyncHub/synchub_server.py "$D" 15034 > "$D/hub.log" 2>&1 < /dev/null &
setsid nohup python3 "$(dirname "$0")/proxy.py" 15080 15033 15034 > "$D/proxy.log" 2>&1 < /dev/null &
sleep 1.5
echo "SC:  $(curl -s -u testuser:testpass http://127.0.0.1:15080/SyncClipboard.json)"
echo "HUB: $(curl -s http://127.0.0.1:15080/api/hub/items?limit=2 | head -c 200)"
