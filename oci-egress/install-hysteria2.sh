#!/usr/bin/env bash
# ============================================================
#  install-hysteria2.sh  --  add Hysteria2 alongside existing sing-box
#
#  Design: COEXIST, do not replace.
#    - sing-box (ss2022) keeps TCP 443   -> Antigravity chain untouched
#    - hysteria2 takes UDP 8443          -> phone / bulk download
#
#  Why: measured 2026-09-20
#    RTT China -> Ashburn = 580-650 ms
#    single TCP flow ceiling ~= 64KB window / 0.6s ~= 107 KB/s
#    measured phone 104 KB/s  -> hit that ceiling exactly
#    => RTT+window bound, not loss bound. Hysteria2 (QUIC, loss-tolerant CC)
#       is the only thing that breaks both limits.
#
#  DO NOT set `bandwidth:` in the config below.
#    Setting it switches Hysteria2 from adaptive BBR to "brutal" congestion
#    control, which IGNORES real link capacity and floods at the configured
#    rate. Measured 2026-09-20: 30 mbps configured into a ~1 Mbps real link
#    => ~97% loss => every client stream aborted ("Application error 0x0").
#    Leave it out and Hysteria2 measures the link itself.
#    Only add it back AFTER measuring real throughput, and start well below it.
#
#  AND -- the part that actually bit us:
#    Editing the config is NOT enough. The server reads it ONLY at startup, and
#    `systemctl enable --now` is a NO-OP on an already-running unit. So re-running
#    this script (or hand-editing /etc/hysteria/config.yaml) leaves the OLD config
#    live with no error and no log line.
#    On 2026-09-20 the bandwidth block was removed from the file at 14:00 but the
#    process had been started at 12:48 -> the brutal config kept serving for
#    2h20m, the phone sat at ~1 Mbps, and the only visible symptom was
#    "Application error 0x0 (remote)" in the journal.
#    This script now does `systemctl restart` and then ASSERTS that the running
#    process is newer than the config file.
#
#  Also: the password is now REUSED on re-runs. Rolling a new one silently
#  invalidates every client already configured (phone, PC) and the new value
#  just scrolls past in the output. Set FORCE_NEW_PASSWORD=1 to roll one.
#
#  ASCII-only on purpose.
#  Usage:  sudo bash install-hysteria2.sh
# ============================================================
set -euo pipefail

PORT=8443
SNI="www.bing.com"
MASQ="https://www.bing.com/"
BIN=/usr/local/bin/hysteria
CONF_DIR=/etc/hysteria
CONF=$CONF_DIR/config.yaml

echo "=== [1/6] download hysteria2 ==="
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  PKG=hysteria-linux-amd64 ;;
  aarch64) PKG=hysteria-linux-arm64 ;;
  *) echo "unsupported arch: $ARCH"; exit 1 ;;
esac
curl -fsSL -o "$BIN" "https://download.hysteria.network/app/latest/$PKG"
chmod +x "$BIN"
"$BIN" version || { echo "binary check failed"; exit 1; }

echo "=== [2/6] self-signed cert (SNI=$SNI) ==="
mkdir -p "$CONF_DIR"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$CONF_DIR/key.pem" -out "$CONF_DIR/cert.pem" \
  -days 3650 -subj "/CN=$SNI" \
  -addext "subjectAltName=DNS:$SNI" 2>/dev/null
chmod 600 "$CONF_DIR/key.pem"
echo "  cert: $CONF_DIR/cert.pem"

echo "=== [3/6] password ==="
# Reuse the existing password on re-runs. Rolling a new one silently breaks every
# already-configured client (phone, PC) and the new value just scrolls past in
# this script's output -- you would not notice until things stopped working.
if [[ "${FORCE_NEW_PASSWORD:-0}" != "1" ]] && sudo grep -q '^  password:' "$CONF" 2>/dev/null; then
  PW=$(sudo sed -n 's/^  password: "\(.*\)"$/\1/p' "$CONF" | head -1)
  echo "  reusing the existing password  (FORCE_NEW_PASSWORD=1 to roll a new one)"
else
  PW=$(head -c 32 /dev/urandom | base64 | tr -d '=/+' | head -c 40)
  echo "  password generated (shown again at the end)"
fi

echo "=== [4/6] write config ==="
cat > "$CONF" <<EOF
listen: :$PORT
tls:
  cert: $CONF_DIR/cert.pem
  key: $CONF_DIR/key.pem
auth:
  type: password
  password: "$PW"
masquerade:
  type: proxy
  proxy:
    url: $MASQ
    rewriteHost: true
EOF
chmod 600 "$CONF"

echo "=== [5/6] systemd unit ==="
cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
Type=simple
ExecStart=$BIN server -c $CONF
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable hysteria-server >/dev/null

# RESTART, not `enable --now`.
# `enable --now` is a NO-OP on an already-running unit, so a config change would
# sit on disk while the OLD config kept serving. That is exactly what happened on
# 2026-09-20: the file was fixed at 14:00, the process had started at 12:48, and a
# `bandwidth: 30 mbps` (brutal CC) config stayed live for 2h20m -- the phone was
# pinned at ~1 Mbps with no error anywhere except "Application error 0x0" in the log.
systemctl restart hysteria-server
sleep 2
systemctl is-active hysteria-server

echo "=== [5b/6] assert the RUNNING process is newer than the config file ==="
# A stale process is silent: the config on disk looks perfect and the service
# reports "active". Start-time ordering is the only reliable check.
PID=$(systemctl show -p MainPID --value hysteria-server)
PROC_START=$(stat -c %Y "/proc/$PID" 2>/dev/null || echo 0)
CONF_MTIME=$(stat -c %Y "$CONF" 2>/dev/null || echo 0)
if [[ "$PROC_START" -ge "$CONF_MTIME" ]]; then
  echo "  OK: process (pid $PID) started after the config was written"
else
  echo "  !! STALE CONFIG: process started at $PROC_START, config written at $CONF_MTIME"
  echo "     the running server did NOT load the config on disk."
  exit 1
fi

echo "=== [6/6] iptables: allow UDP $PORT ==="
iptables -I INPUT 1 -p udp --dport "$PORT" -j ACCEPT
netfilter-persistent save >/dev/null 2>&1 || true
echo "  iptables rules saved"

echo
echo "==================== RESULT ===================="
echo "  port      : UDP $PORT"
echo "  sni       : $SNI   (client MUST enable allowInsecure / skip cert verify)"
echo "  password  : $PW"
echo
echo "  share URI :"
echo "  hysteria2://$PW@$(curl -s4 --max-time 5 ifconfig.me || echo '<SERVER_IP>'):$PORT/?insecure=1&sni=$SNI#$SNI"
echo
echo "  listeners on UDP $PORT :"
ss -lnup 2>/dev/null | grep "$PORT" || echo "  (none - check: journalctl -u hysteria-server -n 30)"
echo
echo "  !!! STILL REQUIRED (cannot be done from here) !!!"
echo "  OCI Console -> Security List -> add Ingress:"
echo "     Source CIDR 0.0.0.0/0 / IP Protocol UDP / Destination Port $PORT"
echo "================================================"
