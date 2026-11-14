#!/usr/bin/env bash
# Heal the three GUI coding-agent clients after an Xvfb restart.
#
# Why: on 2026-11-13 06:18 unattended-upgrade (libc6) reexeced systemd and
# restarted xvfb.service. All X windows were destroyed. The WorkBuddy Electron
# main process survived (so Restart=always never fired) and kept running with
# NO window; Qoder CN lost its login state. Two days of check-ins were missed.
#
# Runs as a systemd USER unit every 30 min. Only restarts a client when its
# window is genuinely gone (search WITHOUT --onlyvisible: check-in scripts
# legitimately minimize other clients' windows).
set -u
export DISPLAY=:99
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
LOGFILE="$HOME/gui-watchdog.log"

log() { echo "$(date '+%F %T') $*" | tee -a "$LOGFILE"; }

has_window() {
  xdotool search --name "$1" 2>/dev/null | head -1 | grep -qE '^[0-9]+$'
}

heal() {
  unit=$1
  pattern=$2
  if has_window "$pattern"; then
    return 0
  fi
  log "RESTART $unit (window '$pattern' missing - Xvfb restart?)"
  systemctl --user restart "$unit.service" || log "WARN restart $unit failed"
  for _ in 1 2 3 4 5 6 7 8; do
    sleep 2
    if has_window "$pattern"; then
      log "RECOVERED $unit"
      return 0
    fi
  done
  log "WARN $unit window still missing after restart"
}

if ! xdpyinfo -display :99 >/dev/null 2>&1; then
  log "WARN Xvfb :99 unreachable"
fi

# Strongest signal: Xvfb restarted but the client process did not.
# On 11-13 the WorkBuddy Electron main process survived the X server swap,
# so Restart=always never fired and its window stayed gone for two days.
TSFILE="$HOME/.gui-watchdog-xvfb-ts"
xvfb_ts=$(systemctl show xvfb.service -p ActiveEnterTimestamp --value 2>/dev/null)
if [ -n "$xvfb_ts" ]; then
  prev=$(cat "$TSFILE" 2>/dev/null || true)
  if [ -n "$prev" ] && [ "$xvfb_ts" != "$prev" ]; then
    log "Xvfb restarted since last check ($prev -> $xvfb_ts) - restarting all GUI clients"
    for u in workbuddy trae qoder-cn; do
      systemctl --user restart "$u.service" || log "WARN restart $u failed"
    done
    sleep 10
  fi
  echo "$xvfb_ts" > "$TSFILE"
fi

heal workbuddy '^WorkBuddy$'
heal trae '^Agent$'
heal qoder-cn '^Qoder CN$'

st=$(python3 -c 'import json; print(json.load(open("/home/ubuntu/.qoder-cn/.qoder-app-status.json")).get("logged_in"))' 2>/dev/null)
if [ "$st" != "True" ]; then
  log "WARN qoder-cn logged_in=$st - needs manual device-code sign-in link"
fi
