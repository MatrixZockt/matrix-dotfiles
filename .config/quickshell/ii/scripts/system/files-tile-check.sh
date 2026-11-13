#!/usr/bin/env bash
# Fluid-tiles check: the grid must choose cols = ceil(avail/260) and
# cellW = floor(avail/cols), with cellH keeping the 132:112 proportion, so the
# tiles use the pane's spare width instead of staying 132x112. Drives a real
# picker instance over IPC (same recipe as files-check.sh) and asserts the
# numbers the grid reports through probeTileCell.
set -u
QML_PICKER="${HOME}/.config/quickshell/ii/filemanager-picker.qml"
SCRATCH="$HOME/fm-scratch-tile"
PORTAL="${XDG_RUNTIME_DIR:-/tmp}/ii-portal"
TOKEN="fmtileck$$"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

mkdir -p "$PORTAL"
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
printf 'x\n' > "$SCRATCH/alpha.txt"
printf '{"op":"open","dir":"%s","name":"","directory":false}' "$SCRATCH" > "$PORTAL/$TOKEN.json"
: > /tmp/fm-tile-check.log

II_FILES_PICKER="$TOKEN" setsid qs -p "$QML_PICKER" >>/tmp/fm-tile-check.log 2>&1 </dev/null &
MAINPID=$!
cleanup() {
    [ -n "${PID:-}" ] && qs ipc --pid "$PID" call files quit done >/dev/null 2>&1
    sleep 1
    kill "$MAINPID" 2>/dev/null; pkill -P "$MAINPID" 2>/dev/null
    [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null
    rm -f "$PORTAL/$TOKEN.json"
    rm -rf "$SCRATCH"
}
trap cleanup EXIT

PID=""
for _ in $(seq 1 240); do
    sleep 0.25
    PID="$(for p in $(pgrep -x qs); do
        tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -q "^II_FILES_PICKER=$TOKEN$" && { echo "$p"; break; }
    done)"
    [ -n "$PID" ] && qs ipc --pid "$PID" call files ping >/dev/null 2>&1 && break
    PID=""
done
if [ -z "$PID" ]; then
    echo "  FAIL  no instance came up -- the QML does not load"
    tail -20 /tmp/fm-tile-check.log; exit 1
fi

qs ipc --pid "$PID" call files probeGo "$SCRATCH" >/dev/null; sleep 1.2
qs ipc --pid "$PID" call files probeView tiles >/dev/null; sleep 0.6
R="$(qs ipc --pid "$PID" call files probeTileCell 2>/dev/null)"
echo "  cell: $R"
if echo "$R" | python3 -c '
import json, sys
d = json.load(sys.stdin)
av, cols, w, h = d["avail"], d["cols"], d["cellW"], d["cellH"]
ec = max(1, -(-av // 260))          # ceil(avail / 260)
ew = max(80, av // ec)              # floor(avail / cols)
eh = round(ew * 112 / 132)          # the cell proportion (132:112)
assert cols == ec, f"cols {cols} != {ec}"
assert w == ew, f"cellW {w} != {ew}"
assert h == eh, f"cellH {h} != {eh}"
assert w * cols <= av, "columns overflow the pane"
print("ok")' >/dev/null 2>&1; then
    ok "the cell follows the fluid formula and fits the pane ($R)"
else
    bad "the cell contradicts the fluid formula ($R)"
fi

# The growth claim itself: cells must exceed the old fixed 132 whenever the
# pane is wide enough to hold a bigger one at the 260 cap.
CW="$(echo "$R" | python3 -c 'import json,sys;print(json.load(sys.stdin)["cellW"])' 2>/dev/null || echo 0)"
AV="$(echo "$R" | python3 -c 'import json,sys;print(json.load(sys.stdin)["avail"])' 2>/dev/null || echo 0)"
if [ "$AV" -ge 392 ] && [ "$CW" -gt 132 ]; then
    ok "tiles grew past the old 132 px on a pane with room ($CW px)"
elif [ "$AV" -lt 392 ]; then
    echo "  ..    pane too narrow to expect growth (avail $AV); formula still asserted"
else
    bad "pane had room but tiles stayed at $CW px"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = "0" ]