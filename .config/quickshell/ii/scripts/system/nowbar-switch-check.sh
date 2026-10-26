#!/usr/bin/env bash
# Does the island's card leave the screen the moment a desktop switch arrives?
#
# Development scaffolding, in the style of scripts/system/files-check.sh: it
# drives the shipped surface and asserts on what the compositor and the card
# itself report afterwards.
#
# WHY THIS EXISTS. The card's surface is the WHOLE OUTPUT on the Overlay layer
# (`exclusiveZone: -1`, all four anchors) and the compositor blurs it, so any
# frame in which it is still on screen during a desktop switch is a full-screen
# frozen blur of the desktop being left, laid over the one sliding in. Three
# separate bugs lived there, and all three looked fine in the source:
#
#   * it ANIMATED out -- 120ms of exactly the blur above, for a card nobody can
#     read while the desktop underneath is moving;
#   * it WAITED to learn about the switch -- closing off
#     `HyprlandData.activeWorkspace`, which costs a forked
#     `hyprctl activeworkspace -j` plus a JSON parse first. Measured: 52-67ms of
#     extra life, 3-4 frames of the same blur;
#   * and the desktop swipe, which is the way the desktops actually change on
#     this machine, was announced by the compositor only when the gesture was
#     OVER -- see the gesture section below, where the card is now taken at the
#     gesture's start instead.
#
# HOW IT IS MEASURED. The witness is the compositor's own event stream
# (`$XDG_RUNTIME_DIR/hypr/$SIG/.socket2.sock`), not a poll. `workspace>>N` is
# the switch landing and `closelayer>>quickshell:barPanel` is the card's surface
# leaving the screen; the gap between them is what the eye sees, on the
# compositor's clock.
#
# That replaced a loop of `hyprctl layers -j`: one FORK per sample, 10-30ms
# each, so a number reported as `gone` included up to a whole round trip of the
# instrument. Against a 50ms ceiling it failed rounds on its own cost while the
# card was behaving -- 56-131ms reported where the truth was 3-6ms. Event to
# event has no such quantization: it is the compositor saying both things.
#
# THE SWIPE gets its own section, because it cannot be driven by a hand from a
# script: `swipeProbe` feeds the card's SHIPPED predicate and its SHIPPED exit
# the four numbers the shell's own touchpad tracker reports, and reports the
# instant it decided. The assertion is then the same shape as the switch one --
# the surface must be gone within a frame of that instant -- plus the negative
# half, which matters just as much: the gestures that only LOOK like a desktop
# swipe (two and three fingers, and a four-finger VERTICAL drag, which is the
# card's own dismiss drag) must leave the card alone.
#
# The desktop the run starts on is restored, and the card is left as found.
#
# LEAVE THE POINTER ALONE while it runs. Any press on the veil closes the card
# BY DESIGN, and a round whose card was closed by a hand instead of by the
# switch is skipped rather than judged -- but a press landing between a probe
# and the compositor's closelayer is indistinguishable in time from the exit
# being measured, so it reads as the wrong close reason.
#
#   bash scripts/system/nowbar-switch-check.sh
set -u
export LC_ALL=C

IPC="qs -c ii ipc call"
# The ceiling sits BETWEEN the behaviours, not near either: measured on this
# machine, the compositor's own event gets the card off screen in 3-6ms, a
# forked read in 79-109ms, and an exit animation in 200-340ms. 50ms is many
# times the good case and well under the bad ones, so load has room without the
# check losing its teeth.
SURFACE_CEILING_MS=50
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }
skip(){ echo "  ..    $1"; }

if ! $IPC nowbarPanel state >/dev/null 2>&1; then
    echo "the shell's nowbarPanel target is not answering (is qs -c ii running?)"
    exit 2
fi

start="$(hyprctl activeworkspace -j | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
other=$(( start == 1 ? 2 : 1 ))
card_was_open=false
$IPC nowbarPanel state | grep -q '"open":true' && card_was_open=true
cleanup() {
    hyprctl dispatch "hl.dsp.focus({ workspace = $start })" >/dev/null 2>&1
    [ "$card_was_open" = false ] && $IPC nowbarPanel close >/dev/null 2>&1
    rm -f /tmp/nsc-measure.out
}
trap cleanup EXIT

python3 - "$start" "$other" > /tmp/nsc-measure.out <<'PY'
import os, json, socket, subprocess, sys, threading, time

start, other = int(sys.argv[1]), int(sys.argv[2])

base = f"{os.environ['XDG_RUNTIME_DIR']}/hypr/{os.environ['HYPRLAND_INSTANCE_SIGNATURE']}"
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(f"{base}/.socket2.sock")
sock.settimeout(0.2)
events = []          # (perf_counter, wall_ms, line)
stop = threading.Event()


def reader():
    buf = b""
    while not stop.is_set():
        try:
            data = sock.recv(65536)
        except socket.timeout:
            continue
        except OSError:
            break
        if not data:
            break
        buf += data
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            events.append((time.perf_counter(), time.time() * 1000,
                           line.decode("utf8", "replace")))


threading.Thread(target=reader, daemon=True).start()
time.sleep(0.3)

# Lists, never `shell=True`: going through /bin/sh put a process inside every
# call, and the IPC calls are already the expensive ones.
PANEL = ["qs", "-c", "ii", "ipc", "call", "nowbarPanel"]


def sh(argv):
    return subprocess.run(argv, capture_output=True, text=True).stdout


def state():
    try:
        return json.loads(sh(PANEL + ["state"]))
    except Exception:
        return {}


def open_card():
    sh(PANEL + ["open"])
    time.sleep(0.6)


def switch(to):
    sh(["hyprctl", "dispatch", f"hl.dsp.focus({{ workspace = {to} }})"])


def after(mark, prefix):
    """The first event with this prefix after `mark`, or None."""
    for perf, wall, line in events[mark:]:
        if line.startswith(prefix):
            return perf, wall, line
    return None


# ── Pass 1: the desktop switch ──────────────────────────────────────────────
# One throwaway switch with the card open, before anything is measured: a shell
# that has just reloaded still warms up (first IPC calls, the first frames of
# this surface), and measuring that pass charged the card for it.
open_card()
switch(other)
time.sleep(0.6)
switch(start)
time.sleep(0.6)

for r in range(1, 4):
    open_card()
    was_open = state().get("open") is True
    mark = len(events)
    switch(other)
    ws = after(mark, "workspace>>")
    cl = None
    deadline = time.perf_counter() + 1.0
    while time.perf_counter() < deadline:
        cl = after(mark, "closelayer>>quickshell:barPanel")
        if cl:
            break
        time.sleep(0.02)
    reason = state().get("lastClose", "")
    gone = "none" if (ws is None or cl is None) else f"{(cl[0] - ws[0]) * 1000:.1f}"
    print(f"switch {r} open={was_open} mapped={cl is not None} gone={gone} reason={reason}")
    switch(start)
    time.sleep(0.6)

# ── Pass 2: the desktop swipe, at the gesture's own start ───────────────────
# The first three are real gestures off this pad's log (`[swipe] 4-finger
# horizontal travel=...`, which is what the tracker wrote when a hand did it):
# note `start=2` on two of them -- three fingers land first, which is why the
# count test accepts either. The fourth is the DIAGONAL case: Hyprland
# axis-locks a swipe after 10 units of travel, so a 60/40 gesture still drags
# the desktops, and it is caught by the tracker's own horizontal threshold
# rather than by the 3:1 dominance test.
TAKING = [(4, 2, 0.12, 0.01), (4, 4, 0.078, 0.004), (4, 2, -0.073, 0.003),
          (4, 4, 0.06, 0.05)]
# And the ones that must NOT take it: the card's own two- and three-finger tab
# swipe, and the four-finger VERTICAL drag (the dismiss drag: sideways travel
# stays tiny -- 0.017 measured on this pad -- while the vertical travel grows),
# including the diagonal-looking version of that drag, which sits just under
# the tracker's own 0.05 threshold.
DECLINING = [(2, 2, 0.03, 0.001), (3, 3, 0.12, 0.01), (4, 4, 0.02, 0.15),
             (4, 4, 0.03, 0.12)]

for i, (fingers, begin, htotal, total) in enumerate(TAKING, 1):
    open_card()
    was_open = state().get("open") is True
    mark = len(events)
    out = sh(PANEL + ["swipeProbe", str(fingers), str(begin),
                      str(htotal), str(total)]).strip()
    at = None
    for token in out.split():
        if token.startswith("at="):
            at = float(token[3:])
    cl = None
    deadline = time.perf_counter() + 1.0
    while time.perf_counter() < deadline:
        cl = after(mark, "closelayer>>quickshell:barPanel")
        if cl:
            break
        time.sleep(0.02)
    reason = state().get("lastClose", "")
    gone = "none" if (at is None or cl is None) else f"{cl[1] - at:.1f}"
    print(f"swipe {i} open={was_open} mapped={cl is not None} gone={gone}"
          + f" take={out.split()[0].split('=')[1] if out else '?'} reason={reason}")
    time.sleep(0.4)

for i, (fingers, begin, htotal, total) in enumerate(DECLINING, 1):
    open_card()
    was_open = state().get("open") is True
    mark = len(events)
    out = sh(PANEL + ["swipeProbe", str(fingers), str(begin),
                      str(htotal), str(total)]).strip()
    time.sleep(0.4)
    took = out.split()[0].split("=")[1] if out else "?"
    closed = after(mark, "closelayer>>quickshell:barPanel") is not None
    print(f"decline {i} fingers={fingers} htotal={htotal} total={total}"
          + f" was={was_open} take={took} closed={closed} open={state().get('open')}")
    sh(PANEL + ["close"])
    time.sleep(0.4)

stop.set()
PY

echo "desktop $start <-> $other"
echo "witness: the compositor's own event stream -- workspace>>N to closelayer>>quickshell:barPanel"
echo "         (the swipe rows measure that closelayer against the instant the card decided)"
echo
# Exact key lookup, not `sed 's/.*key=\(...\)/'`: with several `key=value` pairs
# on one line, a greedy `.*` finds the LAST match of the key, so a count was
# once read out of a longer name and the assertion judged a value it never
# looked at.
tok() { awk -v want="$2" '{ for (i = 1; i <= NF; i++) { split($i, kv, "="); if (kv[1] == want) print kv[2] } }' <<<"$1"; }

while read -r line; do
    case "$line" in
    switch*)
        read -r _ rno rest <<<"$line"
        if [ "$(tok "$line" open)" != "True" ]; then
            skip "switch $rno: the card never opened, so its exit was not measured"
            continue
        fi
        if [ "$(tok "$line" mapped)" != "True" ]; then
            bad "switch $rno: the card's surface never left the screen"
            continue
        fi
        gone="$(tok "$line" gone)"
        if [ "$gone" = "none" ]; then
            bad "switch $rno: no closelayer and no workspace event to measure against"
        elif python3 -c "import sys; sys.exit(0 if float('$gone') <= $SURFACE_CEILING_MS else 1)"; then
            ok "switch $rno: surface gone ${gone}ms after the compositor announced the switch (ceiling ${SURFACE_CEILING_MS}ms)"
        else
            bad "switch $rno: surface still mapped ${gone}ms after the switch (ceiling ${SURFACE_CEILING_MS}ms)"
        fi
        reason="$(sed -n 's/.*reason=\(.*\)$/\1/p' <<<"$line")"
        [ "$reason" = "desktop switch" ] \
            && ok "switch $rno: and it was the switch that closed it" \
            || bad "switch $rno: closed for the wrong reason: [$reason]"
        ;;
    swipe*)
        read -r _ rno rest <<<"$line"
        if [ "$(tok "$line" open)" != "True" ]; then
            skip "swipe $rno: the card never opened, so its exit was not measured"
            continue
        fi
        if [ "$(tok "$line" take)" != "true" ]; then
            bad "swipe $rno: the four-finger horizontal swipe did not take the card"
            continue
        fi
        if [ "$(tok "$line" mapped)" != "True" ]; then
            bad "swipe $rno: the card's surface never left the screen"
            continue
        fi
        gone="$(tok "$line" gone)"
        if [ "$gone" = "none" ]; then
            bad "swipe $rno: no closelayer and no decision instant to measure against"
        elif python3 -c "import sys; sys.exit(0 if float('$gone') <= $SURFACE_CEILING_MS else 1)"; then
            ok "swipe $rno: surface gone ${gone}ms after the card decided (ceiling ${SURFACE_CEILING_MS}ms)"
        else
            bad "swipe $rno: surface still mapped ${gone}ms after the card decided (ceiling ${SURFACE_CEILING_MS}ms)"
        fi
        reason="$(sed -n 's/.*reason=\(.*\)$/\1/p' <<<"$line")"
        [ "$reason" = "desktop switch" ] \
            && ok "swipe $rno: and it was the swipe that closed it" \
            || bad "swipe $rno: closed for the wrong reason: [$reason]"
        ;;
    decline*)
        read -r _ rno rest <<<"$line"
        # A card that was not up when the gesture was fed measured nothing:
        # a hand on the veil closes it, and the check must not judge that.
        if [ "$(tok "$line" was)" != "True" ]; then
            skip "decline $rno: the card was not open, so the gesture was fed to nothing"
            continue
        fi
        if [ "$(tok "$line" take)" = "false" ] && [ "$(tok "$line" closed)" = "False" ] \
            && [ "$(tok "$line" open)" = "True" ]; then
            ok "decline $rno: $(sed -n 's/^decline [0-9]* //; s/ take=.*//p' <<<"$line") leaves the card alone"
        else
            bad "decline $rno: a gesture that is not the desktop swipe took the card: [$line]"
        fi
        ;;
    esac
done < /tmp/nsc-measure.out

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
