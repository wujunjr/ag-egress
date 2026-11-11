#!/usr/bin/env python3
"""Daily TRAE CN check-in via the official account menu.

Flow (all guards, no blind clicking):
  0. Dismiss modal promos (2026-11-11: the "11.11 sale" popup covers the
     bottom-left account area, so the click at (101,766) silently does nothing).
  1. Raise the TRAE main window. NOTE: TRAE's real main window is titled
     "Agent" (1279x799); "Trae CN" is only the 105x105 floating pet widget.
  2. Close the persistent "Start with an idea" onboarding modal if present.
  3. Open the account menu (bottom-left avatar).
  4. Only click "Check in" when its button is BLACK (unclaimed). Once claimed
     it turns light gray, so we skip -- never touch "Upgrade Plan" (y~327)
     or "Log Out" (y~719).

Measured on 2026-11-09, Xvfb :99 @ 1280x800, TRAE CN 2.3.100185:
  * onboarding X        : (960,214), dark bbox (956,210)-(965,219)
  * account area        : (101,766)
  * Check in button     : box (211,361)-(281,390), center (245,377)
      dark_ratio unclaimed = 0.677, claimed = 0.000  -> threshold 0.40
  * credits went 3,100 -> 3,200 on a real click.
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
LOG = HOME / "checkin-trae.log"
PROBE = Path("/tmp/checkin-trae-probe.png")

MODAL_X_BOX = (950, 204, 972, 226)
MODAL_X_CLICK = (960, 214)
ACCOUNT_CLICK = (101, 766)
CHECKIN_BOX = (211, 361, 281, 390)
CHECKIN_CLICK = (245, 377)
DARK_THRESHOLD = 90
MIN_DARK_RATIO = 0.40

# The 11.11 sale modal: black banner with gold text, covering x418-858 y178-615.
PROMO_BOX = (430, 185, 850, 360)
PROMO_X_CLICK = (847, 202)
PROMO_DARK_RATIO = 0.50


def log(msg):
    line = "%s %s" % (datetime.now().strftime("%F %T"), msg)
    print(line, flush=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


def run(args, check=True):
    return subprocess.run(args, env=ENV, capture_output=True, text=True,
                          timeout=20, check=check)


def ids(name):
    r = run(["xdotool", "search", "--name", name], check=False)
    return [x for x in r.stdout.split() if x.strip()]


def raise_trae():
    for name in ("^WorkBuddy$", "^Qoder$", "Trae CN"):
        for wid in ids(name):
            run(["xdotool", "windowminimize", wid], check=False)
    main = ids("^Agent$") or ids("Trae")
    if not main:
        log("ERROR - TRAE main window not found; refusing to click")
        return False
    for wid in main:
        run(["xdotool", "windowmap", wid], check=False)
        run(["xdotool", "windowraise", wid], check=False)
    run(["xdotool", "windowactivate", "--sync", main[0]], check=False)
    time.sleep(1.5)
    return True


def dark_ratio(path, box, threshold=DARK_THRESHOLD):
    im = Image.open(path).convert("RGB")
    if im.size != (1280, 800):
        return -1
    px = im.load()
    x0, y0, x1, y1 = box
    dark = sum(1 for y in range(y0, y1) for x in range(x0, x1)
               if max(px[x, y]) < threshold)
    return dark / ((x1 - x0) * (y1 - y0))


def shot():
    run(["scrot", "-o", str(PROBE)])
    return PROBE.read_bytes()


def dismiss_promos():
    """Escape first, then close the dark 11.11 banner by its X if still there."""
    run(["xdotool", "key", "Escape"], check=False)
    time.sleep(1)
    shot()
    ratio = dark_ratio(PROBE, PROMO_BOX, threshold=60)
    log("promo_dark=%.3f" % ratio)
    if ratio > PROMO_DARK_RATIO:
        log("closing promo modal")
        run(["xdotool", "mousemove", str(PROMO_X_CLICK[0]),
             str(PROMO_X_CLICK[1]), "click", "1"], check=False)
        time.sleep(1.5)
        shot()


def main():
    CAP.mkdir(exist_ok=True)
    stamp = datetime.now().strftime("%F")
    if not raise_trae():
        return 2

    dismiss_promos()

    # 1. legacy onboarding modal
    before_png = shot()
    modal = dark_ratio(PROBE, MODAL_X_BOX)
    log("onboarding_X_dark=%.3f" % modal)
    if modal > 0.02:
        log("closing onboarding modal")
        run(["xdotool", "mousemove", str(MODAL_X_CLICK[0]),
             str(MODAL_X_CLICK[1]), "click", "1"])
        time.sleep(2)
        shot()

    # 2. is the account menu already open with a claimable button?
    ratio = dark_ratio(PROBE, CHECKIN_BOX)
    log("checkin_before=%.3f" % ratio)
    if ratio < MIN_DARK_RATIO:
        log("opening account menu")
        run(["xdotool", "mousemove", str(ACCOUNT_CLICK[0]),
             str(ACCOUNT_CLICK[1]), "click", "1"])
        time.sleep(2)
        shot()
        ratio = dark_ratio(PROBE, CHECKIN_BOX)
        log("checkin_after_menu=%.3f" % ratio)

    if ratio < MIN_DARK_RATIO:
        # Late-appearing modal: one guarded retry, then give up without clicking.
        log("retry - dismissing possible late modal")
        run(["xdotool", "key", "Escape"], check=False)
        time.sleep(1)
        run(["xdotool", "mousemove", str(ACCOUNT_CLICK[0]),
             str(ACCOUNT_CLICK[1]), "click", "1"])
        time.sleep(2)
        shot()
        ratio = dark_ratio(PROBE, CHECKIN_BOX)
        log("checkin_after_retry=%.3f" % ratio)

    (CAP / ("%s-trae-before.png" % stamp)).write_bytes(before_png)
    if ratio < MIN_DARK_RATIO:
        (CAP / ("%s-trae-skip.png" % stamp)).write_bytes(PROBE.read_bytes())
        log("SKIP - no black Check in button (already claimed or UI changed). No click.")
        return 0

    log("clicking TRAE Check in at (245,377)")
    run(["xdotool", "mousemove", str(CHECKIN_CLICK[0]),
         str(CHECKIN_CLICK[1]), "click", "1"])
    time.sleep(3)
    after_png = shot()
    after = dark_ratio(PROBE, CHECKIN_BOX)
    (CAP / ("%s-trae-after.png" % stamp)).write_bytes(after_png)
    log("checkin_after=%.3f" % after)
    if after < ratio * 0.5:
        log("DONE - Check in button turned gray, claim succeeded")
    else:
        log("WARN - button still dark; verify %s-trae-after.png manually" % stamp)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        log("ERROR %s: %s" % (type(exc).__name__, exc))
        sys.exit(1)
