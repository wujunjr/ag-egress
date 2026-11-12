#!/usr/bin/env python3
"""A1 / Qoder CN daily 100 credits claim - v9 (2026-11-12).

Two bugs fixed on top of v7/v8:

1. v7 (2026-11-12 10:05): the Rewards Center OOPIF iframe stays open for
   days. v7 only checked that the CDP target exists and read a STALE card
   showing yesterday's "Claimed" -> SKIP, silently missing the day's credits
   while exiting 0. v8 added a forced iframe reload on every run.
2. v8 (2026-11-12 22:58): the DOM contains TWO elements whose innerText is
   exactly "Claim":
       <div class="h_DSyS"><button class="KTdEo7">Claim</button></div>
   `els.find()` over 'button,[role=button],a,div' hit the OUTER DIV first
   (document order), whose .click() has no handler -> "CLICKED" in the log
   but nothing was claimed. v9 targets BUTTON elements only.

v9 also VERIFIES the outcome: after clicking, the card must show "Claimed"
or the Claim button must disappear. If not, it retries with a real CDP
Input.dispatchMouseEvent, and returns non-zero if still unconfirmed, so a
silent miss can never again look like a successful systemd run.

Architecture:
  * Playwright only clicks the official UI entry; /json/list confirms target.
  * Direct DevTools WebSocket to the OOPIF target (stdlib-only client),
    because Playwright's frame mapping for this iframe is unreliable.
  * NEVER call /json/close on the rewards target (kills the main window).

Safety rules unchanged:
  * Refuse unless ~/.qoder-cn/.qoder-app-status.json says logged_in=true.
  * Only click when the fresh card shows "100 Credits" AND an enabled BUTTON
    whose exact text is "Claim" exists.
  * Anything else -> SKIP / ERROR, no blind coordinate clicking.
"""
import base64
import json
import os
import re
import socket
import struct
import sys
import time
import urllib.request
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright

CDP = "http://127.0.0.1:9227"
HOME = Path.home()
LOG = HOME / "checkin-qoder-cn.log"
STATUS = HOME / ".qoder-cn" / ".qoder-app-status.json"


def log(msg):
    line = "%s %s" % (datetime.now().strftime("%F %T"), msg)
    print(line, flush=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


class WS:
    """Minimal stdlib WebSocket client for CDP text frames."""

    def __init__(self, url):
        u = urlparse(url)
        self.sock = socket.create_connection((u.hostname, u.port or 80), timeout=10)
        self.sock.settimeout(15)
        key = base64.b64encode(os.urandom(16)).decode()
        path = u.path + (("?" + u.query) if u.query else "")
        req = ("GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n"
               "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
               "Sec-WebSocket-Version: 13\r\n\r\n"
               % (path, u.hostname, u.port or 80, key))
        self.sock.sendall(req.encode("ascii"))
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise IOError("handshake closed")
            buf += chunk
        head, self.buf = buf.split(b"\r\n\r\n", 1)
        if b" 101 " not in head.split(b"\r\n")[0]:
            raise IOError("handshake failed: " + head[:160].decode("latin1"))

    def _exact(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise IOError("socket closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _frame(self, opcode, data):
        n = len(data)
        if n < 126:
            hdr = bytes([0x80 | opcode, 0x80 | n])
        elif n < 65536:
            hdr = bytes([0x80 | opcode, 0x80 | 126]) + struct.pack(">H", n)
        else:
            hdr = bytes([0x80 | opcode, 0x80 | 127]) + struct.pack(">Q", n)
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        self.sock.sendall(hdr + mask + masked)

    def send(self, obj):
        self._frame(0x1, json.dumps(obj).encode("utf-8"))

    def recv(self):
        parts = b""
        while True:
            b1, b2 = self._exact(2)
            fin, opcode = b1 & 0x80, b1 & 0x0F
            ln = b2 & 0x7F
            if ln == 126:
                ln = struct.unpack(">H", self._exact(2))[0]
            elif ln == 127:
                ln = struct.unpack(">Q", self._exact(8))[0]
            mask = self._exact(4) if (b2 & 0x80) else None
            data = self._exact(ln)
            if mask:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            if opcode == 0x9:
                self._frame(0xA, data)
                continue
            if opcode == 0x8:
                raise IOError("closed by peer")
            parts += data
            if fin:
                break
        try:
            return json.loads(parts.decode("utf-8"))
        except Exception:
            return None

    def call(self, ident, method, params=None):
        self.send({"id": ident, "method": method, "params": params or {}})
        while True:
            msg = self.recv()
            if msg and msg.get("id") == ident:
                return msg

    def evaluate(self, ident, expr):
        r = self.call(ident, "Runtime.evaluate",
                      {"expression": expr, "returnByValue": True,
                       "awaitPromise": True})
        if "error" in r:
            raise IOError(str(r["error"])[:200])
        return r.get("result", {}).get("result", {}).get("value")

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


def targets():
    with urllib.request.urlopen(CDP + "/json/list", timeout=5) as r:
        return json.load(r)


def rewards_target():
    for t in targets():
        if "growth-page" in (t.get("url") or ""):
            return t
    return None


def phase_open():
    if rewards_target():
        log("rewards target already open")
        return 0
    with sync_playwright() as p:
        b = p.chromium.connect_over_cdp(CDP)
        pg = None
        for _ in range(6):
            try:
                for ctx in b.contexts:
                    for page in ctx.pages:
                        if "qoder-cn-app://" in (page.url or ""):
                            pg = page
                            break
                if pg:
                    break
            except Exception:
                pass
            time.sleep(2)
            try:
                b = p.chromium.connect_over_cdp(CDP)
            except Exception:
                pass
        if pg is None:
            log("SKIP - Qoder CN main window not reachable; no click made")
            return 3
        pg.set_default_timeout(8000)
        for attempt in range(2):
            try:
                menus = pg.get_by_role("button", name="Open user menu")
                if menus.count():
                    menus.first.click(timeout=5000)
                time.sleep(1.2)
                items = pg.get_by_role("menuitem")
                for i in range(min(items.count(), 40)):
                    t = (items.nth(i).inner_text() or "").strip()
                    if re.search(r"rewards|权益", t, re.I):
                        items.nth(i).click(timeout=5000)
                        log("clicked rewards menuitem (attempt %d)" % (attempt + 1))
                        break
            except Exception as e:
                log("WARN menu: %s" % type(e).__name__)
            for _ in range(8):
                time.sleep(1)
                if rewards_target():
                    log("rewards target created, confirmed via /json/list")
                    return 0
    log("SKIP - could not open rewards center; no click made")
    return 3


def fresh_card(timeout=25):
    """Reload iframe content so we never read yesterday's Claimed state."""
    t = rewards_target()
    if not t or not t.get("webSocketDebuggerUrl"):
        return None, None
    try:
        w = WS(t["webSocketDebuggerUrl"])
        try:
            w.evaluate(90, "location.reload(); 'reload-requested'")
        except Exception:
            pass  # execution context destroyed by reload is expected
        finally:
            w.close()
        log("requested rewards iframe reload")
    except Exception as e:
        log("WARN reload request: %s" % type(e).__name__)

    for i in range(timeout):
        time.sleep(1)
        t2 = rewards_target()
        if not t2 or not t2.get("webSocketDebuggerUrl"):
            continue
        conn = None
        try:
            conn = WS(t2["webSocketDebuggerUrl"])
            conn.call(1, "Runtime.enable")
            txt = conn.evaluate(100 + i, "document.body.innerText")
            if txt and "100 Credits" in txt:
                log("card fresh after %ds" % (i + 1))
                return conn, txt
        except Exception:
            pass
        if conn:
            conn.close()
    return None, None


# ONLY real buttons / role=button. Never let an outer wrapper DIV win.
STATE_JS = """(() => {
  const b = Array.from(document.querySelectorAll('button,[role="button"]'))
    .find(x => (x.innerText || '').trim() === 'Claim');
  if (!b) return 'NO_BUTTON';
  if (b.disabled || b.getAttribute('aria-disabled') === 'true') return 'DISABLED';
  return 'ENABLED';
})()"""

CLAIM_JS = """(() => {
  const b = Array.from(document.querySelectorAll('button,[role="button"]'))
    .find(x => (x.innerText || '').trim() === 'Claim'
      && !x.disabled && x.getAttribute('aria-disabled') !== 'true');
  if (!b) return 'NO_BUTTON';
  b.click();
  return 'CLICKED';
})()"""


def wait_claimed(ws, rounds=8):
    """A click only counts when the card confirms it."""
    txt = ""
    for i in range(rounds):
        time.sleep(1)
        try:
            txt = ws.evaluate(300 + i, "document.body.innerText") or ""
            st = ws.evaluate(400 + i, STATE_JS)
        except Exception:
            continue
        if "Claimed" in txt or st == "NO_BUTTON":
            return True, txt
    return False, txt


def real_mouse_click(ws):
    """Fallback: dispatch a real mouse press/release at the button centre."""
    try:
        pt = ws.evaluate(500, """(() => {
          const b = Array.from(document.querySelectorAll('button'))
            .find(x => (x.innerText || '').trim() === 'Claim');
          if (!b) return null;
          const r = b.getBoundingClientRect();
          return {x: r.x + r.width / 2, y: r.y + r.height / 2};
        })()""")
        if not pt:
            return False
        ws.call(501, "Input.dispatchMouseEvent",
                {"type": "mousePressed", "x": pt["x"], "y": pt["y"],
                 "button": "left", "clickCount": 1})
        ws.call(502, "Input.dispatchMouseEvent",
                {"type": "mouseReleased", "x": pt["x"], "y": pt["y"],
                 "button": "left", "clickCount": 1})
        return True
    except Exception as e:
        log("WARN mouse fallback: %s" % type(e).__name__)
        return False


def phase_claim():
    ws, text = fresh_card()
    if ws is None:
        log("ERROR - rewards card unreadable after reload; no click made")
        return 3
    try:
        log("card=%s" % text.replace("\n", " | ")[:260])
        state = ws.evaluate(200, STATE_JS)
        log("claim_button=%s" % state)
        if state != "ENABLED":
            log("SKIP - Claim button absent/disabled (already claimed?); no click made")
            return 0

        result = ws.evaluate(201, CLAIM_JS)
        log("CLICKED Claim (%s)" % result)
        ok, after = wait_claimed(ws)
        if not ok and real_mouse_click(ws):
            log("button.click had no effect; retried with real mouse event")
            ok, after = wait_claimed(ws)
        if not ok:
            log("ERROR - claim NOT confirmed on card; no false success. after=%s"
                % after.replace("\n", " | ")[:220])
            return 4
        log("CONFIRMED card=%s" % after.replace("\n", " | ")[:220])
        log("DONE")
        return 0
    finally:
        ws.close()


def main():
    try:
        st = json.loads(STATUS.read_text(encoding="utf-8"))
    except Exception as e:
        log("SKIP - cannot read login status: %s" % e)
        return 2
    if not st.get("logged_in"):
        log("SKIP - Qoder CN not logged in; no click made")
        return 2
    rc = phase_open()
    if rc != 0:
        return rc
    return phase_claim()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        log("ERROR %s: %s" % (type(exc).__name__, exc))
        sys.exit(1)
