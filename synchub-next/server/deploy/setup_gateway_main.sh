#!/usr/bin/env bash
# Main VPS (gateway control plane + fallback relay). Usage:
#   RELAY_SECRET=<hex> TURN_SECRET=<hex> RELAY_PIN=<hex> RELAY_PUBLIC_URL=https://relay.example:8443 \
#   GATEWAY_STUN_URLS=stun:relay.example:3478 GATEWAY_TURN_URLS=turn:relay.example:3478 bash setup_gateway_main.sh
# Expects in /tmp: synchub-gateway, hubctl, synchub_server.py, nginx_gateway_location.conf
set -euo pipefail
: "${RELAY_SECRET:?}" "${TURN_SECRET:?}" "${RELAY_PIN:?}" "${RELAY_PUBLIC_URL:?}" "${GATEWAY_STUN_URLS:?}" "${GATEWAY_TURN_URLS:?}"
TS=$(date +%Y%m%d-%H%M%S)
NPM_CONF=/root/npm/data/nginx/proxy_host/1.conf

install -m 0755 /tmp/synchub-gateway /usr/local/bin/synchub-gateway
install -m 0755 /tmp/hubctl /usr/local/bin/hubctl
install -d -m 0700 /etc/synchub

# Account = the SyncClipboard account synchub_server.py already uses; only its SHA-256 is stored.
PASS_SHA=$(python3 - <<'PY'
import glob, hashlib, re
user = pw = None
for p in glob.glob("/opt/stacks/syncclipboard/*compose*.y*ml"):
    for line in open(p, encoding="utf-8"):
        line = line.strip().lstrip("- ").strip("'\"")
        m = re.match(r"(SYNCCLIPBOARD_USERNAME|SYNCCLIPBOARD_PASSWORD)\s*[=:]\s*(.*)$", line)
        if m:
            v = m.group(2).strip().strip("'\"")
            if m.group(1).endswith("USERNAME"): user = v
            else: pw = v
    if user and pw: break
print(f"{user}\t{hashlib.sha256(pw.encode()).hexdigest()}" if user and pw else "")
PY
)
[ -n "$PASS_SHA" ] || { echo "could not read SyncClipboard credentials"; exit 1; }
ACC_USER=${PASS_SHA%%$'\t'*}; ACC_SHA=${PASS_SHA#*$'\t'}

umask 077
cat > /etc/synchub/gateway.env <<EOF
SYNCHUB_USER=${ACC_USER}
SYNCHUB_PASSWORD_SHA256=${ACC_SHA}
GATEWAY_ADDR=172.18.0.1:5040
GATEWAY_DATA=/var/lib/synchub-gateway/devices.json
GATEWAY_TRUST_PROXY=1
GATEWAY_RELAY_SECRET=${RELAY_SECRET}
GATEWAY_RELAYS=[{"id":"la","url":"${RELAY_PUBLIC_URL}","cert_sha256":"${RELAY_PIN}","region":"relay"},{"id":"main","url":"","region":"main"}]
GATEWAY_STUN_URLS=${GATEWAY_STUN_URLS}
GATEWAY_TURN_URLS=${GATEWAY_TURN_URLS}
GATEWAY_TURN_SECRET=${TURN_SECRET}
EOF
umask 022

cat > /etc/systemd/system/synchub-gateway.service <<'EOF'
[Unit]
Description=SyncHub Gateway (device registry, presence, signaling, streaming relay)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
DynamicUser=yes
StateDirectory=synchub-gateway
EnvironmentFile=/etc/synchub/gateway.env
ExecStart=/usr/local/bin/synchub-gateway
Restart=always
RestartSec=3
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable synchub-gateway >/dev/null 2>&1
systemctl restart synchub-gateway
sleep 1
curl -sf http://172.18.0.1:5040/healthz >/dev/null && echo "gateway: up" || { journalctl -u synchub-gateway -n 20 --no-pager; exit 1; }

# --- Nginx Proxy Manager: /gw/ location (same approach as the existing /hub/ blocks) ---
if ! grep -q "location /gw/" "$NPM_CONF"; then
  cp -a "$NPM_CONF" "$NPM_CONF.bak-gw-$TS"
  python3 - "$NPM_CONF" /tmp/nginx_gateway_location.conf <<'PY'
import sys
conf, snip = sys.argv[1], open(sys.argv[2], encoding="utf-8").read()
snip = "\n".join(l for l in snip.splitlines() if not l.lstrip().startswith("#")).strip()
text = open(conf, encoding="utf-8").read()
anchor = "  location / {"
assert anchor in text, "anchor not found"
text = text.replace(anchor, "  # synchub-next gateway\n  " + snip.replace("\n", "\n  ") + "\n\n" + anchor, 1)
open(conf, "w", encoding="utf-8").write(text)
PY
  if docker exec npm-app-1 nginx -t >/dev/null 2>&1; then
    docker exec npm-app-1 nginx -s reload && echo "nginx: /gw/ added and reloaded"
  else
    docker exec npm-app-1 nginx -t || true
    cp -a "$NPM_CONF.bak-gw-$TS" "$NPM_CONF"; echo "nginx test failed - restored"; exit 1
  fi
else
  echo "nginx: /gw/ already present"
fi

# --- synchub_server.py: add device-token (Bearer) support ---
cp -a /usr/local/bin/synchub-server.py "/usr/local/bin/synchub-server.py.bak-$TS"
install -m 0755 /tmp/synchub_server.py /usr/local/bin/synchub-server.py
mkdir -p /etc/systemd/system/synchub.service.d
cat > /etc/systemd/system/synchub.service.d/gateway.conf <<'EOF'
[Service]
Environment=SYNCHUB_GATEWAY_URL=http://172.18.0.1:5040
EOF
systemctl daemon-reload
systemctl restart synchub.service
sleep 2
if [ "$(systemctl is-active synchub.service)" != active ]; then
  cp -a "/usr/local/bin/synchub-server.py.bak-$TS" /usr/local/bin/synchub-server.py
  systemctl restart synchub.service; echo "synchub failed to start - restored backup"; exit 1
fi
echo "synchub: active (backup /usr/local/bin/synchub-server.py.bak-$TS)"
