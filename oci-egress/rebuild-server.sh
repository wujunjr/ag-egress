#!/usr/bin/env bash
# rebuild-server.sh
# One-shot server-side rebuild for the "ag-egress" OCI instance
# (sing-box + shadowsocks-2022 on TCP 443).
#
# Usage:
#   sudo bash rebuild-server.sh '<SS2022_PASSWORD>'
#
# Notes:
#   * ASCII-only comments on purpose: this file is copied from a Windows host,
#     non-ASCII text can be mangled by encoding conversions.
#   * The password is a secret. Pass it as an argument, do not commit it anywhere.
#   * Idempotent: safe to re-run (it rewrites the config and restarts the service).
#
# See ../oci-egress/REBUILD-CHECKLIST.md for the full rebuild runbook.

set -euo pipefail

PORT=443
KEY="${1:-}"

if [ -z "$KEY" ]; then
  echo "ERROR: missing the shadowsocks-2022 password."
  echo "Usage: sudo bash rebuild-server.sh '<SS2022_PASSWORD>'"
  echo "Hint : the value is the 'password' field of the ag-oci node in mihomo/config-proxy.yaml"
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run this with sudo (apt/systemctl/iptables need root)."
  exit 1
fi

if [ "${#KEY}" -ne 44 ]; then
  echo "WARNING: a ss2022 256-bit key is usually 44 chars of base64 (32 bytes)."
  echo "         Got ${#KEY} chars. Continuing anyway."
fi

echo "== 1/5 install sing-box =="
if ! command -v sing-box >/dev/null 2>&1; then
  if ! curl -fsSL https://sing-box.app/install.sh | sh; then
    cat <<'EOM'
ERROR: the official installer failed.
Fallback (manual):
  1) open https://github.com/SagerNet/sing-box/releases and download the
     linux-amd64 tar.gz matching this machine (uname -m)
  2) tar -xzf sing-box-*-linux-amd64.tar.gz
  3) sudo install -m 755 sing-box-*/sing-box /usr/local/bin/sing-box
  4) re-run this script
EOM
    exit 1
  fi
fi
sing-box version | head -n 1

echo "== 2/5 write /etc/sing-box/config.json =="
mkdir -p /etc/sing-box
cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": ${PORT},
      "method": "2022-blake3-aes-256-gcm",
      "password": "${KEY}"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
chmod 600 /etc/sing-box/config.json
sing-box check -c /etc/sing-box/config.json && echo "config check: OK"

echo "== 3/5 enable and start the service =="
systemctl enable sing-box >/dev/null 2>&1 || true
systemctl restart sing-box
sleep 2
echo -n "service state: "
systemctl is-active sing-box

echo "== 4/5 open TCP ${PORT} in the local firewall =="
if command -v firewall-cmd >/dev/null 2>&1; then
  echo "detected firewalld (Oracle Linux style)"
  firewall-cmd --zone=public --permanent --add-port=${PORT}/tcp
  firewall-cmd --reload
else
  echo "detected iptables (Ubuntu style)"
  # insert at the top: the OCI image ends with a blanket REJECT rule
  iptables -I INPUT 1 -p tcp --dport ${PORT} -j ACCEPT
  if systemctl is-enabled netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save
    echo "persisted via netfilter-persistent"
  else
    sh -c "iptables-save > /etc/iptables/rules.v4"
    echo "persisted via /etc/iptables/rules.v4"
    echo "note: install iptables-persistent to make this survive reboots automatically"
  fi
fi
echo "--- current INPUT chain ---"
iptables -L INPUT -n --line-numbers | head -n 10

echo "== 5/5 self check =="
echo -n "listening on ${PORT}: "
if ss -lntp | grep -qw "${PORT}"; then echo "yes"; else echo "NO - check: journalctl -u sing-box -n 30"; fi

echo "exit country (must NOT be CN):"
curl -s --max-time 10 https://ipinfo.io/json || echo "(ipinfo unreachable - try again or use ip-api.com)"

cat <<EOM

DONE. Remaining steps (cannot be done from inside the server):
  1) OCI console -> VCN -> Security List -> add ingress rule:
     Source 0.0.0.0/0 / TCP / Destination Port ${PORT}   (outer layer, must be done too)
  2) On the Windows host: edit mihomo/config-proxy.yaml, set the ag-oci node's
     "server" to this instance's NEW public IP (only that one line changes).
  3) On the Windows host: stop-ag-proxy.bat, then start-ag-proxy.bat (in this order),
     then run ag-proxy-check.ps1 and confirm section [E] country = US.
  4) Final and only real verdict: start Antigravity and send one real message.
EOM
