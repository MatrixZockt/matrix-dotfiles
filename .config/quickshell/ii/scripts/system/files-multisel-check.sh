#!/usr/bin/env bash
# Multi-selection menu check: a menu opened over several selected items must act
# on ALL of them, not only on the right-clicked row (the reported bug: Delete /
# Copy / Open moved one file while three were selected). Related to
# files-check.sh but its own script: that suite has no multi-select case, and
# this one starts and stops its OWN picker instance, so the two can be run in
# either order. It drives the same IPC probes (menuAt/probeMenu/menuRun) the
# app's pointer gesture reaches -- openMenu + runMenu -- so what it proves is
# what a right-click runs.
set -u
QML_PICKER="${HOME}/.config/quickshell/ii/filemanager-picker.qml"
SCRATCH="$HOME/fm-scratch-multisel"
PORTAL="${XDG_RUNTIME_DIR:-/tmp}/ii-portal"
LOG=/tmp/fm-multisel.log
TOKEN="fmsel$$"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
boo() { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: expected [$3] got [$2]"; }

get_pid() {
    local pid
    for pid in $(pgrep -x qs); do
        tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -q "^II_FILES_PICKER=$TOKEN$" || continue
        printf '%s' "$pid"; return 0
    done
    return 1
}

mkdir -p "$PORTAL"
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH/subdir"
printf 'a\n' > "$SCRATCH/a.txt"; printf 'b\n' > "$SCRATCH/b.txt"; printf 'c\n' > "$SCRATCH/c.txt"
printf '{"op":"open","dir":"%s","name":"","directory":false}' "$SCRATCH" > "$PORTAL/$TOKEN.json"

: > "$LOG"
II_FILES_PICKER="$TOKEN" setsid qs -p "$QML_PICKER" >>"$LOG" 2>&1 </dev/null &
MAINPID=$!
cleanup() {
    [ -n "${PID:-}" ] && qs ipc --pid "$PID" call files quit test >/dev/null 2>&1
    sleep 1
    kill "$MAINPID" 2>/dev/null
    pkill -P "$MAINPID" 2>/dev/null
    [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null
    rm -f "$PORTAL/$TOKEN.json"
}
trap cleanup EXIT

PID=""
for _ in $(seq 1 240); do
    sleep 0.25
    PID="$(get_pid)" || continue
    qs ipc --pid "$PID" call files ping >/dev/null 2>&1 && break
    PID=""
done
if [ -z "$PID" ]; then
    echo "  FAIL  no instance came up -- the QML does not load"
    tail -40 "$LOG"; exit 1
fi
echo "  ..    instance up, edited QML loads cleanly (pid $PID)"

c() { qs ipc --pid "$PID" call files "$@"; }
idx_of() {
    python3 -c 'import json,sys
try: items=json.loads(sys.argv[1])
except Exception: items=[]
for i,m in enumerate(items):
    if m.get("id")==sys.argv[2]: print(i); break' "$1" "$2"
}
enabled_of() {
    python3 -c 'import json,sys
try: items=json.loads(sys.argv[1])
except Exception: items=[]
for m in items:
    if m.get("id")==sys.argv[2]: print(m.get("enabled")); break' "$1" "$2"
}

c probeGo "$SCRATCH" >/dev/null; sleep 1.5

# Select every item through the folder menu, the way the keyboard's Ctrl+A does.
c menuAt 10 10 "" >/dev/null; sleep 0.4
M="$(c probeMenu)"
I="$(idx_of "$M" selectAll)"
if [ -z "$I" ]; then bad "folder menu offers Select all (menu: $M)"; exit 1; fi
c menuRun "$I" >/dev/null; sleep 0.4
N="$(c probeState | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("selection",[])))')"
boo "Select all selected every item (3 files + subdir)" "$N" "4"

# The entry menu from a right-click on a.txt while all four stay selected.
c menuAt 20 20 "$SCRATCH/a.txt" >/dev/null; sleep 0.4
M="$(c probeMenu)"
boo "Rename greyed out over a multi-selection" "$(enabled_of "$M" rename)" "False"
IT="$(idx_of "$M" trash)"
IC="$(idx_of "$M" copy)"
if [ -z "$IT" ] || [ -z "$IC" ]; then bad "entry menu has Copy and Delete rows (menu: $M)"; exit 1; fi

# Copy must carry every selected path onto the DESKTOP clipboard (read back
# with wl-paste, because "it says it copied" is not "another app can paste").
c menuRun "$IC" >/dev/null; sleep 1.0
URIS="$(timeout 5 wl-paste --type text/uri-list --no-newline 2>/dev/null | grep -c 'fm-scratch-multisel')"
boo "Copy put every selected item on the desktop clipboard" "$URIS" "4"

# Delete must move all four to Trash -- the whole bug in one line.
ls -A "$HOME/.local/share/Trash/files" 2>/dev/null | sort > /tmp/fm-multisel-trash-before
c menuAt 20 20 "$SCRATCH/a.txt" >/dev/null; sleep 0.4
c menuRun "$IT" >/dev/null; sleep 2.0
LEFT="$(ls -A "$SCRATCH" | sort | tr '\n' ',')"
boo "Delete removed EVERY selected item, not just the right-clicked one" "$LEFT" ""
ls -A "$HOME/.local/share/Trash/files" 2>/dev/null | sort > /tmp/fm-multisel-trash-after
ADDED="$(comm -13 /tmp/fm-multisel-trash-before /tmp/fm-multisel-trash-after | grep -cE '^((a|b|c)(\.[0-9]+)?\.txt|subdir(\.[0-9]+)?)$')"
boo "all four moved to Trash, none hard-deleted" "$ADDED" "4"

# Open over a multi-selection must walk into the CLICKED folder (the others
# get tabs where the form has tabs). Folder-only selection on purpose: a file
# here would really be launched by gio open. The path is suffix-matched
# because probePath may answer with either spelling.
mkdir -p "$SCRATCH/opentest/d1" "$SCRATCH/opentest/d2"
c probeGo "$SCRATCH/opentest" >/dev/null; sleep 1.2
c menuAt 10 10 "" >/dev/null; sleep 0.4
M="$(c probeMenu)"; I="$(idx_of "$M" selectAll)"
if [ -n "$I" ]; then c menuRun "$I" >/dev/null; sleep 0.4; fi
NO="$(c probeState | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("selection",[])))')"
boo "both folders selected" "$NO" "2"
c menuAt 20 20 "$SCRATCH/opentest/d1" >/dev/null; sleep 0.4
M="$(c probeMenu)"; IO="$(idx_of "$M" open)"
if [ -z "$IO" ]; then bad "entry menu has an Open row (menu: $M)"
else
    c menuRun "$IO" >/dev/null; sleep 1.2
    P="$(c probePath)"
    case "$P" in
        *opentest/d1) ok "Open over a multi-selection enters the folder you clicked ($P)" ;;
        *) bad "Open over a multi-selection should enter d1, got [$P]" ;;
    esac
fi

rm -rf "$SCRATCH"
echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = "0" ]