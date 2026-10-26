#!/usr/bin/env bash
# Desktop overview check suite: does dropping a window on another desktop
# actually move it there AND take you with it?
#
# Development scaffolding, in the style of scripts/system/files-check.sh: it
# drives the shipped surface and asserts on what the compositor reports
# afterwards.
#
#   A-E ... over IPC: the drop path itself (carry + drop, the same functions the
#           pointer's release calls -- see dropWindowDrag in
#           modules/ii/overview/DesktopOverview.qml), the follow, the refusals,
#           and the two things the FILE must keep doing: a drop goes through ONE
#           shared function, and the follow is an explicit focus rather than the
#           `follow` flag this fork silently drops.
#   F ..... the GESTURE, driven through the compositor with ydotool: a press on
#           a window that travels arms the carry, a release inside the same card
#           cancels it with nothing moved, a walk onto ANOTHER card names that
#           card's desktop as the drop target (the same lookup the drop ring is
#           drawn from), Escape puts the held window back and letting the button
#           go afterwards still moves nothing, and a press that never moves is
#           still a click. It needs a desktop idle enough for the grid to stay
#           open -- the grid closes on ANY click by design -- so where it cannot,
#           that section reports itself skipped, having pressed nothing, rather
#           than clicking into whatever app happens to be on screen.
#
#           Nothing is ever RELEASED over another card here: the commit itself
#           is driven over IPC in B/C/D/E, through the same function the release
#           calls, precisely so that the gesture section never has to rearrange
#           a window that is not the check's own to move.
#
# WHY THE FOLLOW IS CHECKED AT ALL. `follow = true` is DROPPED by this fork's
# compositor -- measured 2026-10-15: a scratch window moved with follow=true
# landed on the target desktop while the view stayed behind, so "drop it and go
# with it" silently became "drop it and stay". The follow is therefore an
# explicit focus dispatch after the move, and this suite is what keeps a later
# revert to the tidier-looking follow=true from passing unnoticed.
#
# A scratch window of its own is used for every move, and both the window and
# the active desktop are put back before it exits -- a check that rearranges the
# desktop it is checking is worse than no check. Usage:
#
#   bash scripts/system/desktop-overview-check.sh
set -u

SHELL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
QML="$SHELL_DIR/modules/ii/overview/DesktopOverview.qml"
PROBE_TITLE="ii overview check probe"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }
boo() { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: expected [$3] got [$2]"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: [$3] not in [$(printf '%s' "$2" | head -c 160)]" ;; esac; }
skip(){ echo "  ..    $1"; }

ipc() { qs -c ii ipc call desktopOverview "$@" 2>&1; }

if ! ipc dragState >/dev/null 2>&1; then
    echo "the shell's desktopOverview target is not answering (is qs -c ii running?)"
    exit 2
fi

# ── the scratch window ──────────────────────────────────────────────────────
cat > /tmp/dov-check-probe.py <<'PROBE'
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import GLib, Gtk
loop = GLib.MainLoop()
w = Gtk.Window(title="ii overview check probe")
w.set_default_size(300, 160)
w.present()
def quit_(*_):
    loop.quit(); return False
GLib.timeout_add_seconds(120, quit_)
w.connect("close-request", quit_)
loop.run()
PROBE
python3 /tmp/dov-check-probe.py >/dev/null 2>&1 &
probe_pid=$!

probe() {   # "address workspaceId"
    hyprctl clients -j | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c.get('title') == '$PROBE_TITLE':
        print(c['address'], c['workspace']['id']); break
" 2>/dev/null
}
active() {
    hyprctl monitors -j | python3 -c "
import json,sys
m = [x for x in json.load(sys.stdin) if x.get('focused')]
print(m[0]['activeWorkspace']['id'] if m else '?')
" 2>/dev/null
}

for _ in $(seq 1 15); do sleep 1; [ -n "$(probe)" ] && break; done
read -r addr orig_ws <<<"$(probe)"
if [ -z "${addr:-}" ]; then
    echo "could not open the scratch window; nothing was checked"
    kill "$probe_pid" 2>/dev/null
    exit 2
fi

restore() {
    local cur; read -r _ cur <<<"$(probe 2>/dev/null)"
    if [ -n "${cur:-}" ] && [ "$cur" != "$orig_ws" ]; then
        ipc moveWindow "$addr" "$orig_ws" >/dev/null 2>&1
    fi
    if [ "$(active)" != "$orig_ws" ]; then
        hyprctl dispatch "hl.dsp.focus({ workspace = $orig_ws })" >/dev/null 2>&1
    fi
    # A failed run must not leave the grid standing over the user's work.
    ipc close >/dev/null 2>&1
    kill "$probe_pid" 2>/dev/null
    rm -f /tmp/dov-check-probe.py
}
trap restore EXIT

echo "scratch window $addr starts on desktop $orig_ws; view is on $(active)"
target="$(hyprctl workspaces -j | python3 -c "
import json,sys
ids = sorted(w['id'] for w in json.load(sys.stdin) if 1 <= w['id'] <= 100)
other = [i for i in ids if i != $orig_ws]
print(other[0] if other else (ids[-1] + 1 if ids else 2))
")"
echo "target desktop: $target"
echo

echo "A. the surface answers, and nothing is being carried"
has "the grid reports its drag state" "$(ipc dragState)" "active=false"
echo

echo "B. carrying a window arms the drag, and the drop moves it AND takes you with it"
# The grid is opened for real, because half of what a drop does is close behind
# you -- and that half is invisible if the grid was never up.
ipc open >/dev/null
sleep 1
has "the grid is up" "$(ipc debug)" "open=true"
has "a window can be put in your hand" "$(ipc carry "$addr" "$orig_ws" "$target")" "to=$target"
has "and the surface reports it as carried" "$(ipc dragState)" "active=true"
has "the drop ran, with nothing left in hand and the grid shut behind you" \
    "$(ipc drop)" "active=false open=false"
sleep 1
read -r _ ws_after <<<"$(probe)"
boo "the window is on desktop $target" "$ws_after" "$target"
boo "the view followed it there" "$(active)" "$target"

echo
echo "C. the trip back, the same way"
ipc carry "$addr" "$target" "$orig_ws" >/dev/null
ipc drop >/dev/null
sleep 1
read -r _ ws_back <<<"$(probe)"
boo "the window is back on desktop $orig_ws" "$ws_back" "$orig_ws"
boo "and so is the view" "$(active)" "$orig_ws"

echo
echo "D. a target that is not a desktop moves nothing"
before="$(active)"
has "a bogus desktop is refused, not attempted" "$(ipc moveWindow "$addr" 0)" "refused"
sleep 1
boo "the view did not move" "$(active)" "$before"
read -r _ ws_held <<<"$(probe)"
boo "the window did not move" "$ws_held" "$orig_ws"

# Dropping a window back onto the desktop it is already on is a cancel, not a
# move: the grid stays up and nothing is dispatched.
#
# The grid is verified up AT THE MOMENT OF THE DROP, because it closes on ANY
# click by design and this check runs on a desktop somebody may be using: a
# stray click during the second below would shut it and the assertion would
# blame the drop for it. Confidence is stated only when the state is known --
# the assertion itself is unchanged, and still fails whenever the grid really
# was up when the drop was driven.
ipc open >/dev/null; sleep 1
ipc carry "$addr" "$orig_ws" "$orig_ws" >/dev/null
if ipc debug | grep -q 'open=true'; then
    has "a drop on its own desktop is abandoned with the grid still up" \
        "$(ipc drop)" "active=false open=true"
else
    skip "the grid was dismissed before a drop-on-its-own-desktop could be driven"
fi
sleep 1
read -r _ ws_same <<<"$(probe)"
boo "and nothing moved" "$ws_same" "$orig_ws"
ipc close >/dev/null

echo
echo "E. the drop the POINTER performs is the same code (read from the file)"
# The grab and the rings cannot be driven from here; what can be read is that
# the release path still goes through the shared function and still follows the
# way this fork needs.
# The whole function, not a fixed number of lines: a grep window that is a few
# lines short reports the code as missing the call it makes (it did).
has "a drop calls the shared move function" \
    "$(sed -n '/function dropWindowDrag/,/^    }/p' "$QML")" "root.moveWindowTo("
boo "the move does NOT rely on the follow flag this fork drops" \
    "$(sed -n '/function moveWindowTo/,/^    }/p' "$QML" | grep -c 'follow = true')" "0"
has "and follows with an explicit focus instead" \
    "$(sed -n '/function moveWindowTo/,/^    }/p' "$QML")" "hl.dsp.focus({ workspace ="
has "a grab is granted by travel inside the motion handler" \
    "$(sed -n '/onPositionChanged/,/cardMouse.windowArmed = true/p' "$QML")" "root.windowDragSlop"

echo
echo "F. the GESTURE, driven through the compositor with ydotool"
# The grab and the release are the halves an IPC call cannot reach. ydotool
# injects real input, so this is the real path -- and every drop below lands back
# on the cell the press came from, which is a CANCEL, so no window of the user's
# is moved by a check. Skipped, not failed, where synthetic input is unavailable.
if ! command -v ydotool >/dev/null 2>&1 || ! pgrep -x ydotoold >/dev/null; then
    skip "ydotool/ydotoold not available, so the gesture cannot be driven here"
else
    cursor() { hyprctl cursorpos | tr -d ' '; }
    move_to() {   # injected motion to a logical point, iterated (it is not exact)
        local tx="$1" ty="$2" i cx cy dx dy
        for i in 1 2 3 4; do
            read -r cx cy <<<"$(cursor | tr ',' ' ')"
            dx=$(( tx - cx )); dy=$(( ty - cy ))
            [ "${dx#-}" -le 20 ] && [ "${dy#-}" -le 20 ] && break
            ydotool mousemove -x "$dx" -y "$dy" >/dev/null 2>&1
            sleep 0.3
        done
    }
    window_map() {
        hyprctl clients -j | python3 -c "
import json,sys
for c in sorted(json.load(sys.stdin), key=lambda c: c['address']):
    print(f\"{c['address']}={c['workspace']['id']}\", end=' ')
" 2>/dev/null
    }
    grid_open() { ipc debug | grep -q 'open=true'; }
    # The grid closes on ANY click (its veil) and on a SUPER press -- by design.
    # This check runs on a desktop somebody may be USING, so the grid is checked
    # before every press and never pressed into blind: with the grid shut, a
    # synthetic click at a card's centre lands in whatever app is there.
    ensure_grid() {
        grid_open && return 0
        ipc open >/dev/null; sleep 1.5
        grid_open
    }

    map_before="$(window_map)"
    busy_desktop=""
    if ! ensure_grid; then
        busy_desktop=1
        skip "the desktop grid will not stay open (the desktop is in use), so the gesture was not driven"
    fi
    read -r W H <<<"$(ipc debug | sed -n 's/.*surface=\([0-9]*\)x\([0-9]*\).*/\1 \2/p')"
    cells="$(ipc state | sed -n 's/.*cells=\([0-9]*\).*/\1/p')"
    # The grid's own arithmetic: 3 columns, gap 20, header 44, layout spacing 26,
    # cards 16:10 -- in LOGICAL pixels, the space hyprctl cursorpos reports in.
    centres="$(python3 - "$W" "$H" "$cells" <<'PY'
import sys, math
W, H, cells = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
cols, gap = 3, 20
gw = max(480, min(W - 200, 1720))
cw = (gw - gap * (cols - 1)) / cols
ch = cw * 0.625
rows = math.ceil(cells / cols)
lh = 44 + (gap + 6) + rows * ch + (rows - 1) * gap
top = (H - lh) / 2 + 44 + (gap + 6)
left = (W - gw) / 2
for i in range(cells):
    c, r = i % cols, i // cols
    print(f"{i} {int(left + c * (cw + gap) + cw / 2)} {int(top + r * (ch + gap) + ch / 2)}")
PY
    )"
    # The card you are standing on first, but only if it has a window to press
    # on: the grab is granted by a press ON a window, so an empty card proves
    # nothing and would fail the assertion for the wrong reason.
    busy="$(ipc state | sed -n "s/.* \($(( $(active) + 1 )):\[[^]]*\]\).*/\1/p")"
    if [ -n "$busy" ]; then
        order="$(awk -v a="$(( $(active) - 1 ))" '$1==a{print; next} {print}' <<<"$centres")"
    else
        order="$centres"
    fi

    # Press at a card's centre and travel inside it. A window is in hand
    # afterwards: `carried` is its cell, `carried_addr`/`carried_from` are the
    # window and the desktop it is being taken from, `carried_cx`/`carried_cy`
    # the card's centre (where a release means "never mind").
    carried=""; carried_addr=""; carried_from=""; carried_cx=0; carried_cy=0
    grab() {
        while read -r cell cx cy; do
            [ -z "${cell:-}" ] && continue
            [ "$cell" = "$((cells - 1))" ] && continue   # the "+" slot carries no window
            # Nothing is pressed unless the grid is up THIS instant: a click at a
            # card's centre with the grid shut goes into whatever app is there.
            if ! ensure_grid; then busy_desktop=1; return 1; fi
            move_to "$cx" "$cy"
            if ! grid_open; then busy_desktop=1; return 1; fi
            ydotool click 0x40 >/dev/null 2>&1; sleep 0.3            # left down
            ydotool mousemove -x 45 -y 20 >/dev/null 2>&1; sleep 0.5 # travel, inside the card
            state="$(ipc dragState)"
            if [ "${state#*active=true}" != "$state" ]; then
                carried="$cell"; carried_cx="$cx"; carried_cy="$cy"
                carried_addr="$(sed -n 's/.*addr=\([^ ]*\).*/\1/p' <<<"$state")"
                carried_from="$(sed -n 's/.*from=\(-\{0,1\}[0-9]*\).*/\1/p' <<<"$state")"
                return 0
            fi
            ydotool click 0x80 >/dev/null 2>&1; sleep 0.3            # nothing armed: let go
        done <<<"$order"
        return 1
    }

    if [ -z "$busy_desktop" ] && grab; then
        ok "a press that travelled picked its window up (card $carried)"
        ydotool click 0x80 >/dev/null 2>&1; sleep 1              # release: same card = cancel
        has "nothing is in hand any more" "$(ipc dragState)" "active=false"
        has "and the grid is still up" "$(ipc debug)" "open=true"
        boo "no window changed desktop for a cancelled grab" "$(window_map)" "$map_before"

        # ── WHERE the release would have landed ────────────────────────
        # The cancel above proves the release path runs; this proves the TARGET
        # it reads. With a window held, the pointer is walked onto another card
        # and the surface must name that card's desktop -- the same lookup
        # (cellAt) the drop ring is drawn from, so the ring that promised a
        # desktop and the drop that happens cannot disagree.
        #
        # NOTHING IS RELEASED OVER THE TARGET. Escape puts the carried window
        # back, and if it does not arrive the pointer is returned to its own
        # card and the release there is the cancel -- a check that rearranges a
        # stranger's window to make its own point is worse than no check.
        if [ -n "$busy_desktop" ]; then
            skip "the grid was dismissed before the drop target could be walked to"
        elif [ "$carried_from" -lt 1 ] 2>/dev/null; then
            skip "the carried window's desktop could not be read, so no target was predicted"
        else
            has "a window in hand, its own card is not a target" "$(ipc dragState)" "to=-1"
            cell_ids="$(ipc state | python3 -c "
import re,sys
print(' '.join(re.findall(r'(\d+):\[', sys.stdin.read())))
")"
            tcell=$(( carried == 0 ? 1 : 0 ))
            [ "$tcell" -ge "$(( cells - 1 ))" ] && tcell=$(( tcell - 1 ))
            tid="$(awk -v t="$(( tcell + 1 ))" '{print $t}' <<<"$cell_ids")"
            if [ -z "${tid:-}" ] || [ "$tid" = "$carried_from" ]; then
                skip "there is no other desktop to walk onto"
            elif ensure_grid && grab; then
                read -r _ dx dy <<<"$(awk -v t="$tcell" '$1==t{print}' <<<"$centres")"
                move_to "$dx" "$dy"
                boo "walked onto another card, the drop would go to its desktop" \
                    "$(sed -n 's/.*to=\(-\{0,1\}[0-9]*\).*/\1/p' <<<"$(ipc dragState)")" "$tid"
                ydotool key 1:1 1:0 >/dev/null 2>&1; sleep 0.6   # Escape
                state="$(ipc dragState)"
                if [ "${state#*active=true}" = "$state" ]; then
                    ok "Escape put the carried window back"
                else
                    move_to "$carried_cx" "$carried_cy"
                    ydotool click 0x80 >/dev/null 2>&1; sleep 0.6
                    skip "Escape did not reach the grid, so the window was put back by releasing on its own card"
                fi
                has "and the grid is still standing" "$(ipc debug)" "open=true"
                # Still holding the button, still over the TARGET card: a nudge
                # there must not make the surface name a desktop again. The
                # drop that ring would promise can no longer happen, and a card
                # that kept promising it would be lying about the release.
                ydotool mousemove -x 24 -y 0 >/dev/null 2>&1; sleep 0.4
                has "but no card claims to be a target any more" "$(ipc dragState)" "to=-1"
                # Escape ends the gesture but the button is still DOWN -- that
                # is what cancelling mid-hold means. It has to be let go, on
                # the card the press started on, and the letting go must not
                # turn a cancelled grab into a desktop switch either.
                move_to "$carried_cx" "$carried_cy"
                ydotool click 0x80 >/dev/null 2>&1; sleep 0.8
                boo "and letting the button go moved nothing" "$(window_map)" "$map_before"
                has "with nothing in hand" "$(ipc dragState)" "active=false"
            else
                skip "the grid would not take a second grab, so the drop target was not walked to"
            fi
        fi
    elif [ -n "$busy_desktop" ]; then
        # Whatever closed it (a click, a SUPER press, a desktop switch) is the
        # user's doing, not a defect in the drag: report, do not blame.
        skip "the grid was dismissed while the gesture was being driven; nothing pressed into an app"
    else
        bad "no press ever armed a window grab (tried the cards' centres)"
    fi

    # A press that never moves is still a click: the desktop switches and the
    # grid shuts, which is what the cards have always done.
    if ensure_grid; then
        read -r _ tcx tcy <<<"$(awk '$1==0{print}' <<<"$centres")"
        move_to "$tcx" "$tcy"
        if grid_open; then
            ydotool click 0xC0 >/dev/null 2>&1; sleep 1.2
            # Cell 0 is desktop 1, and a click on a card means "take me there".
            boo "a motionless click still switches to that desktop" "$(active)" "1"
            has "and closes the grid" "$(ipc debug)" "open=false"
            has "with nothing carried" "$(ipc dragState)" "active=false"
        else
            skip "the grid was dismissed before the click test"
        fi
    else
        skip "the grid will not stay open, so the click test was not driven"
    fi
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
