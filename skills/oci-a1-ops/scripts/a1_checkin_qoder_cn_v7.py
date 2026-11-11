#!/usr/bin/env python3
"""A1 / Qoder CN daily 100 credits claim - FINAL (v7, 2026-11-11).

Why v7: the Rewards Center is an out-of-process iframe (OOPIF) that appears in
CDP /json/list as type="iframe". Playwright's connect_over_cdp maps it to a
frame only intermittently (v3 worked once at 12:34, v4/v5/v6 all failed), so
v7 talks to that target DIRECTLY over its own DevTools WebSocket using a tiny
stdlib-only WebSocket client. No pip install, no Playwright frame mapping.

Flow:
  1. Playwright is used ONLY to click the official UI entry (user menu ->
     "Rewards center" menuitem). Presence of the target is confirmed via
     /json/list, which is authoritative and independent of Playwright.
  2. Connect to that target's webSocketDebuggerUrl, Runtime.evaluate the DOM,
     apply the guards, click "Claim", verify the resulting text.

Safety rules unchanged:
  * Refuse unless ~/.qoder-cn/.qoder-app-status.json says logged_in=true.
  * Only click when the card shows "100 Credits" AND an enabled element whose
    exact text is "Claim" exists.
  * Anything else -> log SKIP, take no action. Never click by coordinates.
  * DO NOT call /json/close on the rewards target: that killed the Qoder main
    window at 12:39 and lost the login state.
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


# ---------- minimal stdlib WebSocket client (CDP uses text frames) ----------
class WS:
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
            if opcode == 0x9:              # ping -> pong
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


# ---------- CDP target discovery ----------
def targets():
    with urllib.request.urlopen(CDP + "/json/list", timeout=5) as r:
        return json.load(r)


def rewards_target():
    for t in targets():
        if "growth-page" in (t.get("url") or ""):
            return t
    return None


# ---------- phase 1: official UI click ----------
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


# ---------- phase 2: direct CDP DOM claim ----------
CLAIM_JS = """(() => {
  const els = Array.from(document.querySelectorAll('button,[role="button"],a,div'));
  const b = els.find(x => (x.innerText || '').trim() === 'Claim'
    && !x.disabled && x.getAttribute('aria-disabled') !== 'true');
  if (!b) return 'NO_BUTTON';
  b.click();
  return 'CLICKED';
})()"""


def phase_claim():
    t = rewards_target()
    if not t:
        log("SKIP - rewards target absent; no click made")
        return 3
    ws_url = t.get("webSocketDebuggerUrl")
    if not ws_url:
        log("SKIP - no debugger url for rewards target; no click made")
        return 3
    ws = WS(ws_url)
    try:
        ws.call(1, "Runtime.enable")
        text = ws.evaluate(2, "document.body.innerText") or ""
        log("card=%s" % text.replace("\n", " | ")[:240])
        if "100 Credits" not in text:
            log("SKIP - daily 100 credits card not visible; no click made")
            return 0
        state = ws.evaluate(3, """(() => {
          const els = Array.from(document.querySelectorAll('button,[role="button"],a,div'));
          const b = els.find(x => (x.innerText || '').trim() === 'Claim');
          if (!b) return 'NO_BUTTON';
          if (b.disabled || b.getAttribute('aria-disabled') === 'true') return 'DISABLED';
          return 'ENABLED';
        })()""")
        log("claim_button=%s" % state)
        if state != "ENABLED":
            log("SKIP - Claim button absent/disabled (already claimed?); no click made")
            return 0
        result = ws.evaluate(4, CLAIM_JS)
        log("CLICKED Claim (%s)" % result)
        time.sleep(4)
        after = ws.evaluate(5, "document.body.innerText") or ""
        log("after=%s" % after.replace("\n", " | ")[:220])
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
