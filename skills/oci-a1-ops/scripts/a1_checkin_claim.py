#!/usr/bin/env python3
"""Daily WorkBuddy check-in - v2 (2026-11-14).

v1 used a hardcoded button box (65,693)-(163,721). On 2026-11-13 06:18 an
unattended-upgrade reexeced systemd and restarted Xvfb :99; the WorkBuddy
Electron main process survived (so Restart=always never fired) but its X
window was destroyed. After a manual restart the sidebar layout came back
different and the button sat at ~(177,684)-(275,712), so v1 logged
`white_ratio=0.009 -> SKIP` on both 11-13 and 11-14.

v2:
  * SELF-HEAL: if the WorkBuddy window is missing, restart workbuddy.service,
    wait for the window to reappear, then retry.
  * DYNAMIC LOCATION: scan the bottom-left region for a white button-sized
    rectangle instead of assuming coordinates.
  * GUARDS UNCHANGED: only click when a white rectangle is actually found;
    only report DONE when that rectangle disappears afterwards.

Coordinate basis: Xvfb :99 at 1280x800. Never blind-click a fixed point.
"""
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

from PIL import Image

ENV = {**os.environ, "DISPLAY": ":99"}
HOME = Path.home()
CAP = HOME / "checkin-captures"
LOG = HOME / "checkin-claim.log"
PROBE = Path("/tmp/checkin-claim-probe.png")

# Search region for the "Claim Now" white button (bottom-left sidebar).
REGION = (30, 620, 340, 770)
BTN_W, BTN_H = 98, 28
WHITE_THRESHOLD = 225
MIN_RATIO = 0.35          # v2: dynamic scan is noisier than an exact box


def log(msg):
    line = "%s %s" % (datetime.now().strftime("%F %T"), msg)
    print(line, flush=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


def run(args, check=True):
    return subprocess.run(args, env=ENV, capture_output=True, text=True,
                          timeout=30, check=check)


def window_ids(pattern):
    r = run(["xdotool", "search", "--name", pattern], check=False)
    return [x for x in r.stdout.split() if x.strip()]


def raise_workbuddy():
    for name in ("Trae CN", "^Qoder CN$", "^Agent$"):
        for wid in window_ids(name):
            run(["xdotool", "windowminimize", wid], check=False)
    ids = window_ids("^WorkBuddy$")
    if not ids:
        log("window missing - restarting workbuddy.service (Xvfb restart?)")
        run(["systemctl", "--user", "restart", "workbuddy.service"], check=False)
        for _ in range(10):
            time.sleep(2)
            ids = window_ids("^WorkBuddy$")
            if ids:
                log("window reappeared after restart")
                break
    if not ids:
        log("ERROR - WorkBuddy window not visible after restart; refusing to click")
        return False
    for wid in ids:
        run(["xdotool", "windowmap", wid], check=False)
        run(["xdotool", "windowraise", wid], check=False)
    run(["xdotool", "windowactivate", "--sync", ids[0]], check=False)
    time.sleep(2)
    return True


def scan_button(path):
    im = Image.open(path).convert("RGB")
    if im.size != (1280, 800):
        log("WARN - unexpected screen size %s" % (im.size,))
        return 0, None
    px = im.load()
    best = (0, None)
    x0, y0, x1, y1 = REGION
    for y in range(y0, min(y1 - BTN_H, 800 - BTN_H), 3):
        for x in range(x0, min(x1 - BTN_W, 1280 - BTN_W), 3):
            n = tot = 0
            for j in range(y, y + BTN_H, 3):
                for i in range(x, x + BTN_W, 3):
                    tot += 1
                    if min(px[i, j]) > WHITE_THRESHOLD:
                        n += 1
            r = n / tot if tot else 0
            if r > best[0]:
                best = (r, (x, y, x + BTN_W, y + BTN_H))
    return best


def ratio_at(path, box):
    im = Image.open(path).convert("RGB")
    px = im.load()
    x0, y0, x1, y1 = box
    n = tot = 0
    for j in range(y0, y1, 2):
        for i in range(x0, x1, 2):
            tot += 1
            if min(px[i, j]) > WHITE_THRESHOLD:
                n += 1
    return n / tot if tot else 0


def main():
    CAP.mkdir(exist_ok=True)
    stamp = datetime.now().strftime("%F")
    if not raise_workbuddy():
        return 2

    run(["scrot", "-o", str(PROBE)])
    before, box = scan_button(PROBE)
    (CAP / ("%s-claim-before.png" % stamp)).write_bytes(PROBE.read_bytes())
    log("button_ratio=%.3f box=%s" % (before, box))
    if before < MIN_RATIO or not box:
        log("SKIP - Claim Now button not found (already claimed or UI changed). No click made.")
        return 0

    cx, cy = (box[0] + box[2]) // 2, (box[1] + box[3]) // 2
    log("clicking Claim Now at (%d,%d)" % (cx, cy))
    run(["xdotool", "mousemove", str(cx), str(cy), "click", "1"])
    time.sleep(4)
    run(["scrot", "-o", str(PROBE)])
    after = ratio_at(PROBE, box)
    (CAP / ("%s-claim-after.png" % stamp)).write_bytes(PROBE.read_bytes())
    log("after_ratio=%.3f" % after)
    if after < before * 0.5:
        log("DONE - button disappeared, claim succeeded")
    else:
        log("WARN - button still present; verify %s-claim-after.png manually" % stamp)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        log("ERROR %s: %s" % (type(exc).__name__, exc))
        sys.exit(1)
