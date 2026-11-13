#!/usr/bin/env python3
# Which tabs of a Chromium-family browser are making sound, by title.
#
# WHY THIS EXISTS
#
# The bar has to name the thing you are hearing, and a browser tells nobody:
# its MPRIS bus publishes ONE media session, and PipeWire labels every tab's
# stream "Playback" with the app name "Brave". Measured on this machine: two
# tabs playing at once, the bar named the FOCUSED tab while a different tab
# was the one making sound.
#
# HOW IT ASKS
#
# Every tab is a target. There is an `audible` flag in older Chrome builds, and
# this one (155) has dropped it -- it is absent from /json/list AND from
# Target.getTargets, so a list-based answer is silently "nothing is playing"
# forever. What cannot be faked is the page itself: a tab is making sound when
# it has a <video>/<audio> element that is not paused, not muted, has volume,
# and has buffered enough to play. So each tab is asked that question directly.
#
# ONE SOCKET PER TAB, ALL ASKED AT ONCE, and this is a latency fix, not
# tidiness (measured 2026-11-08). This used to attach every tab to ONE
# flattened socket and ask them one after another. A single tab that does not
# answer -- a hung renderer, a page stuck in a recaptcha iframe -- then blocked
# that socket for the full 0.6s read timeout, in front of every tab behind it,
# and the whole gesture paid it BEFORE a single pause was sent: the
# three-finger tap stopped the music a second or more after the fingers left
# the pad, and the next tap took as long to start it again. Now every tab gets
# its own connection with a short timeout and they are all asked together, so
# the wait is the slowest tab rather than the sum, and a tab that will not
# answer cannot hold up the one that is playing.
#
# USAGE
#
#   brave-audible-tab.py [list|pause|play|toggle] [port]
#
#   list   (default) JSON array of the audible tabs' titles.
#   pause  stop every tab that is playing sound; remember which one.
#   play   start the tab `pause` remembered.
#   toggle pause if anything is playing, otherwise play.
#
# Prints JSON: a list of titles for `list`, an object for the actions. Prints
# [] / {"ok": false} (exit 0) when the browser is not reachable -- the normal
# state without a debugging port, where the caller keeps the MPRIS answer.
#
# No dependencies: python3 stdlib only, including a minimal WebSocket client,
# because this machine has neither websocat nor a python websocket module.

import base64
import concurrent.futures
import json
import os
import socket
import struct
import sys
import time
import urllib.request

# Hard cap on a whole action. `list` runs behind the bar's 1.2s timer while a
# browser is making sound, so this has to stay well under that with twenty tabs
# open -- and it does now: the concurrent pass means the wait is the slowest
# tab, not the sum of them.
DEADLINE = 1.6
# One tab that will not answer. An evaluate on a healthy tab here measures
# 2-6ms -- the tabs play video, they are not idle -- so this is a 20x margin,
# and it is only ever paid by a page that is hung (measured here: an open PDF,
# 100ms+ every time). It is the slowest tab, not the sum, that the gesture
# waits for now, so it also sets the worst case.
PAGE_TIMEOUT = 0.12

# A tab that is playing, regardless of how loud: mute and pause are the only
# things the user can do that make a tab silent without it being "stopped".
PROBE = """(() => {
  const els = Array.from(document.querySelectorAll('video,audio'));
  const live = els.filter(e => !e.paused && !e.muted && e.volume > 0);
  return live.length ? live.length : 0;
})()"""

PAUSE = """(() => {
  let n = 0;
  document.querySelectorAll('video,audio').forEach(e => {
    if (!e.paused) { e.pause(); n += 1; }
  });
  return n;
})()"""

PLAY = """(() => {
  const els = Array.from(document.querySelectorAll('video,audio'));
  if (!els.length) return 0;
  // Prefer the element that held the position, so a page with ads or more
  // than one player resumes the thing that was actually stopped.
  const target = els.filter(e => !e.muted).sort((a, b) => b.currentTime - a.currentTime)[0] || els[0];
  target.play();
  return 1;
})()"""

# What `pause` stopped, so `play` can bring back the same tab -- a browser has
# no way to say "the last thing I played", and starting every tab that has a
# video element would be a disaster.
STATE = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "ii-brave-last-tab.json")

# How many tabs are asked at once. Every tab is a separate connection, so this
# is what keeps the gesture fast: the wait is the SLOWEST tab, not the sum of
# all of them, and one hung page cannot hold the others up.
WORKERS = 16


def ws_connect(url, timeout=PAGE_TIMEOUT):
    if not url.startswith("ws://"):
        raise IOError("not a ws url")
    hostport, path = url[5:].split("/", 1)
    host, _, port = hostport.rpartition(":")
    sock = socket.create_connection((host or "127.0.0.1", int(port or 80)), timeout=timeout)
    key = base64.b64encode(os.urandom(16)).decode()
    request = (
        "GET /%s HTTP/1.1\r\n"
        "Host: %s\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: %s\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    ) % (path, hostport, key)
    sock.sendall(request.encode())
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(4096)
        if not chunk:
            raise IOError("handshake closed")
        head += chunk
    if b" 101 " not in head.split(b"\r\n")[0]:
        raise IOError("handshake refused")
    return sock


def send_text(sock, text):
    data = text.encode()
    header = b"\x81"
    size = len(data)
    if size < 126:
        header += bytes([0x80 | size])
    elif size < 65536:
        header += bytes([0x80 | 126]) + struct.pack(">H", size)
    else:
        header += bytes([0x80 | 127]) + struct.pack(">Q", size)
    mask = os.urandom(4)
    sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def recv_text(sock):
    def read(n):
        out = b""
        while len(out) < n:
            chunk = sock.recv(n - len(out))
            if not chunk:
                raise IOError("closed")
            out += chunk
        return out

    while True:
        first, second = read(2)
        opcode = first & 0x0F
        size = second & 0x7F
        if size == 126:
            size = struct.unpack(">H", read(2))[0]
        elif size == 127:
            size = struct.unpack(">Q", read(8))[0]
        if second & 0x80:
            read(4)
        payload = read(size) if size else b""
        if opcode == 1:
            return payload.decode("utf-8", "replace")
        if opcode == 8:
            raise IOError("closed")


def page_socket(port, target_id):
    """A tab's own devtools endpoint, built from its id.

    Built rather than read out of the listing on purpose: this is the path that
    still works when the listing is empty or the tab is missing from it, which
    is exactly the state a burst of taps used to leave the action in -- the
    remembered tab could not be found, so starting the music did nothing.
    """
    return "ws://127.0.0.1:%s/devtools/page/%s" % (port, target_id)


def remembered_page(port):
    remembered = load_state()
    target_id = str(remembered.get("targetId") or "")
    if target_id == "":
        return None
    return {"targetId": target_id,
            "title": remembered.get("title", ""),
            "webSocketDebuggerUrl": page_socket(port, target_id)}


def page_list(port, attempts=3):
    """Every tab, with the id `pause` remembers and its own socket URL.

    Retried, because the devtools HTTP endpoint is served by the browser and a
    request made while it is busy can fail or answer nothing. Giving up on the
    first answer is what turned a busy moment into "the tap does nothing".
    """
    error = None
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(
                    "http://127.0.0.1:%s/json/list" % port, timeout=1.0) as res:
                entries = json.load(res)
            if isinstance(entries, list) and entries:
                break
        except Exception as failure:
            error = failure
        time.sleep(0.04)
    else:
        if error is not None:
            raise error
        return []

    pages = [p for p in entries
             if p.get("type") == "page" and p.get("webSocketDebuggerUrl")]
    for page in pages:
        # `/json/list` calls the tab id `id`; the action code and the state
        # file both speak `targetId`, and the value is the same string.
        page["targetId"] = page.get("id", "")
    return pages


def evaluate(page, expression, timeout=PAGE_TIMEOUT):
    """Run one expression in one tab, on a connection of its own.

    Own connection = own timeout. A tab that never answers costs `timeout` and
    cannot desynchronise the socket another tab is read from.
    """
    sock = ws_connect(page["webSocketDebuggerUrl"], timeout=timeout)
    try:
        send_text(sock, json.dumps({
            "id": 1,
            "method": "Runtime.evaluate",
            "params": {"expression": expression, "returnByValue": True},
        }))
        while True:
            reply = json.loads(recv_text(sock))
            if reply.get("id") == 1:
                return ((reply.get("result") or {}).get("result") or {}).get("value")
    finally:
        try:
            sock.close()
        except Exception:
            pass


def load_state():
    try:
        with open(STATE) as handle:
            return json.load(handle)
    except Exception:
        return {}


def ask_all(pages, expression, timeout=PAGE_TIMEOUT):
    """Ask every tab at once: [(page, value-or-None)], in page order.

    Concurrent, and that is the whole point. Sequentially, one tab that will
    not answer costs PAGE_TIMEOUT *in front of* the tabs behind it in the
    list; in parallel it costs one PAGE_TIMEOUT in total and the tab that is
    actually playing is answered while the hung one is still being waited on.

    Nothing is remembered here on purpose. An earlier version cached a tab as
    "unresponsive" for 45s and skipped it -- and the tab it had learned to skip
    was the one playing the video, so the bar reported no sound while music was
    audible and the island's play button showed the wrong glyph and did
    nothing.
    """
    if not pages:
        return []

    def job(page):
        try:
            return evaluate(page, expression, timeout=timeout)
        except Exception:
            return None

    with concurrent.futures.ThreadPoolExecutor(
            max_workers=min(WORKERS, len(pages))) as pool:
        values = list(pool.map(job, pages))
    return list(zip(pages, values))


def remember(page):
    try:
        with open(STATE, "w") as handle:
            json.dump({"targetId": page.get("targetId", ""),
                       "title": page.get("title", "")}, handle)
    except Exception:
        pass


def play_remembered(pages, end):
    """Start the tab `pause` stopped: by id first (a tab keeps its id for its
    whole life), by title if the browser was restarted.

    No scan happens before this. The old code probed EVERY tab, and only then
    looked the remembered one up, so starting the music waited behind a tab
    that had nothing to do with it.
    """
    remembered = load_state()
    page = next((p for p in pages if p["targetId"] == remembered.get("targetId")), None)
    if page is None and remembered.get("title"):
        page = next((p for p in pages if p.get("title") == remembered["title"]), None)
    if page is None:
        return {"ok": False, "action": "play", "titles": []}
    try:
        timeout = max(0.05, min(PAGE_TIMEOUT, end - time.time()))
        value = evaluate(page, PLAY, timeout=timeout)
        return {"ok": bool(value), "action": "play",
                "titles": [page.get("title", "")]}
    except Exception:
        return {"ok": False, "action": "play", "titles": []}


def main():
    args = sys.argv[1:]
    action = "list"
    if args and args[0] in ("list", "pause", "play", "toggle"):
        action = args.pop(0)
    port = args[0] if args else "9222"
    started = time.time()
    end = started + DEADLINE
    try:
        pages = page_list(port)
    except Exception:
        # The listing is the only thing that failed. The remembered tab can
        # still be reached by id, so a press is not lost to it -- an empty
        # answer here is what used to make the tap do nothing at all.
        pages = []
    known = remembered_page(port)
    if known is not None and not any(p.get("targetId") == known["targetId"]
                                     for p in pages):
        pages.append(known)
    if not pages:
        print("[]" if action == "list" else json.dumps({"ok": False}))
        return

    if action == "list":
        titles = [page.get("title", "")
                  for page, value in ask_all(pages, PROBE)
                  if isinstance(value, (int, float)) and value > 0
                  and page.get("title")]
        print(json.dumps(titles))
        return

    if action == "play":
        print(json.dumps(play_remembered(pages, end)))
        return

    # pause / toggle: ONE pass that asks and stops in the same call. Asking
    # every tab first and stopping afterwards meant the sound kept playing
    # until the whole scan had finished, which is what the gesture was
    # reporting as "a few seconds late". The pass is concurrent, so the tab
    # that is playing is silenced within a round trip instead of waiting its
    # turn behind every tab opened before it.
    stopped = [page for page, value in ask_all(pages, PAUSE)
               if isinstance(value, (int, float)) and value > 0]
    if not stopped and time.time() + PAGE_TIMEOUT < end:
        # One more pass. A single empty answer is a busy browser -- a tab that
        # was reloading, an evaluate that timed out -- and reporting "nothing
        # was playing" for it is how a press could silence nothing at all.
        time.sleep(0.05)
        stopped = [page for page, value in ask_all(pages, PAUSE)
                   if isinstance(value, (int, float)) and value > 0]
    if stopped:
        remember(stopped[0])
        print(json.dumps({"ok": True, "action": "pause",
                          "titles": [p.get("title", "") for p in stopped]}))
        return
    # Nothing was playing, twice. A `toggle` press is then a request to start
    # the thing the last press stopped; a plain `pause` is already satisfied.
    if action == "toggle":
        print(json.dumps(play_remembered(pages, end)))
        return
    print(json.dumps({"ok": True, "action": "pause", "titles": []}))


if __name__ == "__main__":
    main()
