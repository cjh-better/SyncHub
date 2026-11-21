#!/usr/bin/env bash
# Server 2 (relay node + TURN). Usage:
#   RELAY_SECRET=<hex> TURN_SECRET=<hex> PUBLIC_IP=<public-ip> bash setup_relay_node.sh
# Expects /tmp/synchub-gateway uploaded beforehand.
set -euo pipefail
: "${RELAY_SECRET:?}" "${TURN_SECRET:?}" "${PUBLIC_IP:?}"
RELAY_PORT="${RELAY_PORT:-8443}"

install -m 0755 /tmp/synchub-gateway /usr/local/bin/synchub-gateway
install -d -m 0700 /etc/synchub
umask 077
cat > /etc/synchub/relay.env <<EOF
GATEWAY_MODE=relay
GATEWAY_ADDR=0.0.0.0:${RELAY_PORT}
GATEWAY_RELAY_SECRET=${RELAY_SECRET}
GATEWAY_TLS_DIR=/var/lib/synchub-relay/tls
GATEWAY_TLS_IPS=${PUBLIC_IP}
EOF

cat > /etc/systemd/system/synchub-relay.service <<'EOF'
[Unit]
Description=SyncHub relay node (ticket-authorized streaming relay)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
DynamicUser=yes
StateDirectory=synchub-relay
EnvironmentFile=/etc/synchub/relay.env
ExecStart=/usr/local/bin/synchub-gateway
Restart=always
RestartSec=3
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
RestrictAddressFamilies=AF_INET AF_INET6
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# --- coturn -----------------------------------------------------------------
if ! command -v turnserver >/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq coturn >/dev/null
fi
[ -f /etc/turnserver.conf.orig ] || cp /etc/turnserver.conf /etc/turnserver.conf.orig 2>/dev/null || true
cat > /etc/turnserver.conf <<EOF
listening-port=3478
external-ip=${PUBLIC_IP}
min-port=51000
max-port=51200
realm=020814.xyz
use-auth-secret
static-auth-secret=${TURN_SECRET}
fingerprint
no-cli
no-multicast-peers
no-tlsv1
no-tlsv1_1
total-quota=50
user-quota=10
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=100.64.0.0-100.127.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
log-file=syslog
simple-log
EOF
sed -i 's/^#\?TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn 2>/dev/null || true

# --- firewall ---------------------------------------------------------------
ufw allow ${RELAY_PORT}/tcp comment 'synchub relay' >/dev/null
ufw allow 3478/tcp comment 'synchub turn' >/dev/null
ufw allow 3478/udp comment 'synchub turn' >/dev/null
ufw allow 51000:51200/udp comment 'synchub turn relay' >/dev/null

systemctl daemon-reload
systemctl enable --now synchub-relay.service >/dev/null
systemctl enable coturn >/dev/null 2>&1 || true
systemctl restart coturn
sleep 2
echo "relay: $(systemctl is-active synchub-relay) turn: $(systemctl is-active coturn)"
echo "PIN=$(GATEWAY_RELAY_SECRET=${RELAY_SECRET} /usr/local/bin/synchub-gateway -mode relay -tls-self-signed /var/lib/private/synchub-relay/tls -print-pin 2>/dev/null || true)"
curl -sk https://127.0.0.1:${RELAY_PORT}/healthz; echo
