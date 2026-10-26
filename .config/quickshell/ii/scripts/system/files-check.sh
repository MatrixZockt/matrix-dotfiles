#!/usr/bin/env bash
# Files app check suite: drives the real app over its IPC probes and asserts on
# what came back. Development scaffolding -- a throwaway copy lives in /tmp.
#
# Two personalities, two dismissal rules:
#   * window mode (the Files popup) can be dismissed by hand or by the gesture,
#     so it is only used for the folder-open contract at the top;
#   * everything else runs in a PICKER instance, which ignores the drag gesture.
# Either can still be closed by a human pressing Escape or clicking the veil, so
# each group starts with `ensure` -- restart, re-navigate, carry on. That is
# exactly what the launcher script does for a real user, so it is not a cheat.
set -u

# Two QML roots, because the app and the portal dialog are two different kinds
# of surface: filemanager.qml is an ordinary desktop window, filemanager-picker.qml
# is the layer-shell FileChooser dialog. The suite drives both.
QML=/home/user/.config/quickshell/ii/filemanager.qml
QML_PICKER=/home/user/.config/quickshell/ii/filemanager-picker.qml
# The app's launcher, used where a person would use it: a window has no IPC
# "show" to send (filemanager.qml), so re-opening one means launching one.
LAUNCHER=/home/user/.config/quickshell/ii/scripts/launch/filemanager.sh
SCRATCH="$HOME/fm-scratch-test"
PORTAL="${XDG_RUNTIME_DIR:-/tmp}/ii-portal"
LOG=/tmp/fm-suite.log
PASS=0
FAIL=0

# Both spellings of each QML path, and that is not tidiness: the launcher
# resolves its own location with `readlink -f` before it execs Quickshell, so an
# instance started THROUGH it -- which is what ensure_window does, and what a
# person does -- carries the repo path in argv
# (/home/user/hyprland/.config/quickshell/ii/filemanager.qml) while this file
# spells its paths under ~/.config. Measured 2026-10-14 against two live windows:
# one matched this lookup, the other did not, and an unmatched instance is
# unreachable by IPC. That is invisible for as long as the suite's own instance
# stays up -- and fatal the moment it does not, because every relaunch then puts
# a window on the screen that the check cannot talk to: the rest of the run
# reports NO INSTANCE about a desktop full of them. (The portal's dead-picker
# check had the identical bug; see the note on PICKER_QML in
# scripts/ii-portal.py.)
QML_REAL="$(readlink -f "$QML")"
QML_PICKER_REAL="$(readlink -f "$QML_PICKER")"

find_pid() {
    local token="${1:-}" pid cmd
    for pid in $(pgrep -x qs); do
        cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
        case "$cmd" in
            "qs -p $QML "|"qs -p $QML_PICKER "|"qs -p $QML_REAL "|"qs -p $QML_PICKER_REAL ") ;;
            *) continue ;;
        esac
        if [ -n "$token" ]; then
            tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -q "^II_FILES_PICKER=$token$" || continue
        else
            tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -q '^II_FILES_PICKER=' && continue
        fi
        printf '%s' "$pid"
        return
    done
}

ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
boo() { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: expected [$3] got [$2]"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: [$3] not in [$(printf '%s' "$2" | head -c 140)]" ;; esac; }
json() { python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: d=None
if d is None: print('')
else:
    v=eval('d' + '$1')
    print('True' if v is True else 'False' if v is False else json.dumps(v) if isinstance(v,(list,dict)) else v)" 2>/dev/null; }

c() { local pid; pid="$(find_pid "$TOKEN")"; [ -n "$pid" ] || { echo "NO INSTANCE"; return 1; }; qs ipc --pid "$pid" call files "$@"; }
state() { c probeState; }
count() { state | json '["count"]'; }
path() { c probePath; }

start_picker() {
    local token="$1" op="$2" directory="$3" tries="${4:-3}" attempt pid
    mkdir -p "$PORTAL"
    printf '{"op":"%s","dir":"%s","name":"","directory":%s}' "$op" "$SCRATCH" "$directory" > "$PORTAL/$token.json"
    for attempt in $(seq 1 "$tries"); do
        II_FILES_PICKER="$token" setsid qs -p "$QML_PICKER" >>"$LOG" 2>&1 </dev/null &
        # 50 seconds per attempt, not 20: a fresh Quickshell instance loads the
        # whole shell tree (services, widgets, the file manager itself) before
        # it can answer on IPC, and on a cold QML cache that is half a minute --
        # which used to be reported as "the dialog did not come up" about a
        # dialog that was on screen two seconds later.
        for _ in $(seq 1 200); do
            sleep 0.25
            pid="$(find_pid "$token")"
            [ -n "$pid" ] || continue
            qs ipc --pid "$pid" call files ping >/dev/null 2>&1 && return 0
        done
        echo "  ..    picker $token did not come up (attempt $attempt)" >&2
    done
    return 1
}

ensure() {
    local op="${1:-open}" dirflag="${2:-false}"
    [ -n "$(find_pid "$TOKEN")" ] && return 0
    echo "  ..    instance was closed by hand; restarting"
    start_picker "$TOKEN" "$op" "$dirflag" >/dev/null || return 1
    sleep 2
    c probeGo "$SCRATCH" >/dev/null
    sleep 1.2
}

# The window-mode half of `ensure`, for the case where the app is simply GONE.
# A window can be closed by hand (SUPER + Q, the close button) or take its
# process with it, and neither is a bug in the app -- it is a bug in the check.
# So a group that needs the app asks for it the way a person would (the launcher
# script) and waits for the COMPOSITOR to agree that a window is on screen,
# which is the only answer that cannot lie about it: answering IPC is what the
# old window form's invisible launches had right while the screen was empty.
#
# Which windows are the app's is answered by TITLE, because the picker is a
# layer surface and so never appears in this list at all.
app_pids() {
    timeout 5 hyprctl clients -j 2>/dev/null | python3 -c '
import json, sys
for c in json.load(sys.stdin):
    if c.get("title") == "Files":
        print(c.get("pid"))'
}

window_up() {
    [ -n "$(app_pids)" ]
}

ensure_window() {
    window_up && return 0
    echo "  ..    the Files window is gone; launching another one"
    bash "$LAUNCHER" "$SCRATCH" >/dev/null 2>&1
    for _ in $(seq 1 60); do
        sleep 0.25
        window_up && return 0
    done
    echo "  ..    no window came up" >&2
    return 1
}

fresh_scratch() {
    rm -rf "$SCRATCH"
    mkdir -p "$SCRATCH/subdir"
    printf 'some text\n' > "$SCRATCH/alpha.txt"
    printf 'x\n' > "$SCRATCH/beta.log"
    # The counts the listing assertions compare against are COUNTED, not typed
    # in: the fixture grows every time a feature needs a file, and a hardcoded
    # number is how this suite starts failing for the wrong reason.
    VISIBLE_COUNT=6
    # A .png that is NOT a png: the file that made the thumbnail generator loop
    # forever once, so it stays in the fixture on purpose.
    printf 'y\n' > "$SCRATCH/gamma.png"
    printf 'z\n' > "$SCRATCH/.hidden-file"
    printf '0123456789012345678901234567890\n' > "$SCRATCH/zeta.bin"
    # A REAL image, so "the tile draws the picture" is assertable rather than
    # assumed: magick is what ThumbnailImage generates with, so it is also what
    # the fixture is made with.
    magick -size 96x64 gradient:red-blue "$SCRATCH/art.png" 2>/dev/null \
        || printf 'not a png either\n' > "$SCRATCH/art.png"
    # A sample PDF for the page-render path, borrowed read-only from the system.
    PDFSRC="$(ls /usr/share/doc/*/manual.pdf /usr/share/doc/*/*.pdf 2>/dev/null | head -1)"
    [ -n "$PDFSRC" ] && cp "$PDFSRC" "$SCRATCH/manual.pdf"
    # Real videos, for the frame-grab path. TWO of them, because the grab has
    # two branches: the picture is taken a second in, and a clip that short or
    # longer takes the first branch -- a two-second clip -- while one that is
    # exactly a second long has no frame there and has to fall back to its
    # first frame. testsrc animates, so the two files do not look alike either.
    if command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -v error -f lavfi -i testsrc=size=64x64:rate=5 -t 2 -pix_fmt yuv420p \
            "$SCRATCH/clip.mp4" -y 2>/dev/null
        [ -f "$SCRATCH/clip.mp4" ] && VISIBLE_COUNT=$((VISIBLE_COUNT + 1))
        ffmpeg -v error -f lavfi -i testsrc=size=80x48:rate=5 -t 1 -pix_fmt yuv420p \
            "$SCRATCH/short.mp4" -y 2>/dev/null
        [ -f "$SCRATCH/short.mp4" ] && VISIBLE_COUNT=$((VISIBLE_COUNT + 1))
    fi
    [ -f "$SCRATCH/manual.pdf" ] && VISIBLE_COUNT=$((VISIBLE_COUNT + 1))
    # ── The formats the pane READS rather than describes ────────────────
    # Built by python3 because the point of these files is their STRUCTURE:
    # a .docx that is really a zip with one XML part in it, a .xlsx whose
    # cells are shared strings. A hand-written text file would prove nothing
    # about a reader that unpacks them.
    python3 - "$SCRATCH" <<'PYFIX' || echo "  ..    the format fixtures could not be built"
import csv, json, os, subprocess, sys, zipfile
scratch = sys.argv[1]
def path(name):
    return os.path.join(scratch, name)
json.dump({"name": "Files", "version": 2, "tags": ["a", "b"],
           "nested": {"deep": True}}, open(path("sample.json"), "w"))
with open(path("sample.csv"), "w", newline="") as fh:
    writer = csv.writer(fh)
    writer.writerow(["name", "size", "kind"])
    writer.writerow(["alpha.txt", "10", "document"])
    writer.writerow(["clip.mp4", "3.2 KB", "video"])
    writer.writerow(["art.png", "1.1 KB", "image"])
open(path("sample.html"), "w").write(
    "<html><head><title>Notes on Files</title><style>b{}</style></head>"
    "<body><h1>Preview pane</h1><p>This page has <b>text</b>.</p>"
    "<script>var x=1;</script><ul><li>first</li></ul></body></html>")
open(path("sample.md"), "w").write(
    "# Title\n\nSome **bold** text with a [link](https://example.com).\n")
with zipfile.ZipFile(path("pack.zip"), "w") as zf:
    zf.writestr("readme.txt", "hello\n")
    zf.writestr("sub/a.txt", "a\n")
with zipfile.ZipFile(path("report.docx"), "w") as zf:
    zf.writestr("[Content_Types].xml", "<Types/>")
    zf.writestr("word/document.xml",
                "<w:document><w:body><w:p><w:r><w:t>Hello from Word</w:t></w:r>"
                "</w:p></w:body></w:document>")
with zipfile.ZipFile(path("sheet.xlsx"), "w") as zf:
    zf.writestr("xl/sharedStrings.xml",
                "<sst><si><t>Item</t></si><si><t>Qty</t></si></sst>")
    zf.writestr("xl/worksheets/sheet1.xml",
                '<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c>'
                '<c r="B1" t="s"><v>1</v></c></row><row r="2"><c r="A2" '
                't="inlineStr"><is><t>Apples</t></is></c><c r="B2"><v>12</v></c>'
                '</row></sheetData></worksheet>')
# A real binary with a name that says nothing about it: a valid PNG called
# .dat, so `file` can name it and no extension can. The magic bytes are the
# fallback for a system without magick.
# Written to a .png and MOVED, because magick picks the output format from
# the extension: `... xc:red blob.dat` fails with "no encode delegate", and
# the fixture would silently be the magic-bytes fallback instead of a real PNG.
_PNG = subprocess.run(["magick", "-size", "8x8", "xc:#3355ff", path("blob.png")],
                      capture_output=True)
if _PNG.returncode == 0:
    os.replace(path("blob.png"), path("blob.dat"))
else:
    open(path("blob.dat"), "wb").write(b"\x89PNG\r\n\x1a\n" + bytes(range(256)))
PYFIX
    # Counted, not typed in: the fixture grows every time a feature needs a
    # file, and a hardcoded number is how a suite starts failing for the wrong
    # reason. `.hidden-file` is the only thing here that starts with a dot.
    VISIBLE_COUNT=$(find "$SCRATCH" -mindepth 1 -maxdepth 1 ! -name '.*' | wc -l)
    HIDDEN_COUNT=$((VISIBLE_COUNT + 1))
}

# ── window mode: the folder-open contract, then get out of the way ───────
start_window() {
    II_FILES_START="$SCRATCH" setsid qs -p "$QML" >>"$LOG" 2>&1 </dev/null &
    # Same 50 s budget as the picker, and for the same reason.
    for _ in $(seq 1 200); do
        sleep 0.25
        local pid; pid="$(find_pid)"
        [ -n "$pid" ] || continue
        qs ipc --pid "$pid" call files ping >/dev/null 2>&1 && return 0
    done
    return 1
}

# A popup can also be closed by hand or by the dismiss gesture, and a dialog
# that was closed mid-bring-up is not a bug in the app -- it is a bug in the
# check. Three tries, then the group is reported as unreachable.
echo "── window mode ──────────────────────────────────────────────────────"
fresh_scratch
TOKEN=""
WIN_UP=0
for attempt in 1 2 3; do
    if start_window; then WIN_UP=1; break; fi
    echo "  ..    window instance did not come up (attempt $attempt)"
done
# The launch has to put the WINDOW up BY ITSELF, so the first thing asked is
# the compositor, with nothing done first to help it: the app answers IPC as
# soon as its QML is up, which is not the same moment as its window being on
# screen, and that gap is exactly where the old window form's invisible launches
# lived (process warm, IPC answering, nothing drawn). Asked by pid, because that
# is the only part of the answer that names THIS instance.
for _ in $(seq 1 30); do
    window_up && break
    sleep 0.2
done
# A window cannot be dismissed by a stray click the way the popup could, so
# there is no "somebody closed it while the launch settled" to be generous
# about: the launch either put a window on screen or it did not. When it did
# not, the app's own view is printed next to it -- the launch that maps nothing
# is the report this group exists to catch, and it is left to fail.
if ! window_up; then
    echo "  ..    no window after the launch; the app says: $(c probeWindow 2>&1)"
fi
# ── The WINDOW form (2026-10-14, requested) ──────────────────────────
# "A window like any other desktop app" is a claim about what KIND of surface
# it is, so the compositor is asked rather than the QML: a real xdg toplevel
# (title Files), in the TILING layout rather than floating, and NO layer surface
# left anywhere. The popup form's namespace is asserted absent on purpose -- a
# leftover surface would be invisible to every other check in this file, and it
# is exactly what a half-finished change to this app leaves behind.
LAYERS="$(timeout 10 hyprctl layers 2>/dev/null)"
CLIENTS="$(timeout 10 hyprctl clients -j 2>/dev/null)"
APP_PID="$(find_pid)"
boo "the app is a window the compositor knows, titled Files" \
    "$(printf '%s' "$CLIENTS" | python3 -c '
import json, sys
pid = int(sys.argv[1])
got = [c for c in json.load(sys.stdin) if c.get("pid") == pid]
print("yes" if got and got[0].get("title") == "Files" else "pid %s -> %s" % (pid, [(c.get("title"), c.get("class")) for c in got]))' "$APP_PID")" \
    "yes"
boo "and it is in the tiling layout, not floating" \
    "$(printf '%s' "$CLIENTS" | python3 -c '
import json, sys
pid = int(sys.argv[1])
got = [c for c in json.load(sys.stdin) if c.get("pid") == pid]
print("yes" if got and got[0].get("floating") is False else "floating (or missing)")' "$APP_PID")" \
    "yes"
boo "and no layer surface is left over from the popup form" \
    "$(printf '%s' "$LAYERS" | grep -c 'quickshell:filesPopup')" "0"
WIN="$(c probeWindow)"
boo "and the app says its window is up, titled Files, in app mode" \
    "$(printf '%s' "$WIN" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("yes" if d["visible"] is True and d["title"] == "Files" and d["picker"] is False else d)' 2>/dev/null)" \
    "yes"

# ── A LAUNCH IS A NEW WINDOW, and closing it ends that process ─────────
# The half of the request which retired the single-instance machinery: a second
# launch has to give a SECOND window rather than raising the first. Checked
# against the compositor (two clients, two pids) and against the app (the first
# pid is still answering), because "it opened again" and "it threw me out of the
# one I was using" look identical from inside a single instance.
FIRST_PID="$(find_pid)"
bash "$LAUNCHER" >/dev/null 2>&1
for _ in $(seq 1 60); do
    sleep 0.25
    [ "$(app_pids | grep -c .)" -ge 2 ] && break
done
boo "a second launch gives a SECOND window" "$(app_pids | grep -c .)" "2"
boo "and the first one is still its own process" \
    "$(app_pids | grep -c "^${FIRST_PID}$")" "1"
SECOND_PID="$(app_pids | grep -v "^${FIRST_PID}$" | head -1)"
# Closing it (the IPC path; SUPER + Q is the same `onClosing` handler) has to
# take that window's PROCESS with it, or every close leaves a stray instance
# behind -- which is the state the old launcher used to report success over.
qs ipc --pid "$SECOND_PID" call files quit in >/dev/null 2>&1
for _ in $(seq 1 40); do
    sleep 0.25
    [ -d "/proc/$SECOND_PID" ] || break
done
boo "and closing that window ends ITS process" \
    "$([ -d "/proc/$SECOND_PID" ] && echo alive || echo gone)" "gone"
boo "and the window it did not touch is still up" "$(c ping)" "files"
c probeGo "$SCRATCH" >/dev/null; sleep 1.2
boo "still on the folder it was told" "$(path)" "$SCRATCH"

c probeGo "$SCRATCH" >/dev/null; sleep 1.2
boo "opens where it was told" "$(path)" "$SCRATCH"
boo "row count (hidden off)" "$(count)" "$VISIBLE_COUNT"
L="$(c probeList 10)"
boo "folders sort ahead of files" "$(echo "$L" | json '[0]["name"]')" "subdir"
boo "name order after that" "$(echo "$L" | json '[1]["name"]')" "alpha.txt"
c probeSelect "subdir" >/dev/null; sleep 0.5
c probeActivate 0 >/dev/null; sleep 1.2
boo "activate (double-click) enters the folder" "$(path)" "$SCRATCH/subdir"

# ── previews, in the window (a pane is a window thing; the dialog declines) ─
# Every assertion here is about the CONTENT of a file, so each one is driven the
# way a person drives it: select a row, then read what the pane concluded.
echo "── previews (window mode) ───────────────────────────────────────────"
c probeGo "$SCRATCH" >/dev/null; sleep 1.2
c probePreviewPane 1 >/dev/null; sleep 0.5
c probePreviewSelect "alpha.txt" >/dev/null; sleep 1.5
P="$(c probePreview)"
boo "the preview pane opens" "$(echo "$P" | json '["pane"]')" "True"
boo "a text file is previewed as text" "$(echo "$P" | json '["kind"]')" "text"
has "and the pane shows its first bytes" "$P" "some text"
has "while the subtitle names what it is" "$(echo "$P" | json '["subtitle"]')" "Document · 10 B"

c probePreviewSelect "art.png" >/dev/null; sleep 2
P="$(c probePreview)"
boo "an image is previewed as an image" "$(echo "$P" | json '["kind"]')" "image"
boo "the row itself is marked previewable (the tiles read this)" "$(echo "$P" | json '["entryPreviewable"]')" "True"
# The proof that a PICTURE was produced, not just a branch taken: the shell's
# thumbnail cache holds an entry for this exact file, and only ThumbnailImage's
# generator ever writes one.
THUMBHASH="$(printf 'file://%s' "$SCRATCH/art.png" | md5sum | cut -d' ' -f1)"
CACHED=""
for _ in $(seq 1 16); do
    CACHED="$(find "$HOME/.cache/thumbnails" -name "$THUMBHASH.png" 2>/dev/null | head -1)"
    [ -n "$CACHED" ] && break
    sleep 0.5
done
boo "and generating it wrote the picture into the thumbnail cache" "$([ -n "$CACHED" ] && echo yes)" "yes"

# The picture follows the pane, in BOTH directions. It used to be a fixed
# 220 px box, and PreserveAspectFit fits INSIDE its box -- so a wider pane gave
# the picture's sides more empty space and nothing else. Both ends of the
# divider are asked for, and the painted size is what is compared, because the
# box growing while the picture did not is exactly the bug.
# The pane has to be BESIDE the list for this: when it is stacked, the edge
# that moves is the top one and the picture's width would be the list's.
c probeResize 1080 720 >/dev/null; sleep 1.0
if [ "$(c probePreviewDivider | json '["below"]')" = "False" ]; then
    PIXELS='import json,sys
d=json.load(sys.stdin); p=d["imagePainted"] or {}; b=d["image"] or {}
print(str(p.get("width",0)) + " " + str(p.get("height",0)) + " " + str(b.get("height",0)))'
    c probePreviewDragBegin >/dev/null
    c probePreviewDragStep -4000 >/dev/null; sleep 1.2
    read -r WIDE_W WIDE_H WIDE_BOX <<< "$(c probePreview | python3 -c "$PIXELS")"
    c probePreviewDragStep 4000 >/dev/null; sleep 1.2
    read -r NARROW_W NARROW_H NARROW_BOX <<< "$(c probePreview | python3 -c "$PIXELS")"
    # Back to exactly where the drag began (0 px from the pointer it began at),
    # so the suite leaves the pane the size the user had it.
    c probePreviewDragStep 0 >/dev/null; c probePreviewDragEnd >/dev/null; sleep 0.6
    boo "widening the pane widens the picture ($NARROW_W -> $WIDE_W)" \
        "$([ "$WIDE_W" -gt $((NARROW_W + 50)) ] && echo yes || echo no)" "yes"
    boo "and the box takes the pane's height now, not a fixed 220" \
        "$([ "$WIDE_BOX" -gt 220 ] && echo yes)" "yes"
    boo "with the picture's own 3:2 shape kept at that size" \
        "$(awk -v w="$WIDE_W" -v h="$WIDE_H" 'BEGIN { print (h > 0 && w / h > 1.45 && w / h < 1.55) ? "yes" : "no" }')" "yes"
else
    echo "  ..    the pane is stacked at this width: the picture-growth rows are skipped"
fi

c probePreviewSelect "subdir" >/dev/null; sleep 1.5
P="$(c probePreview)"
boo "a folder is described rather than pictured" "$(echo "$P" | json '["kind"]')" "folder"
has "with what is inside it" "$P" "item"

if [ -f "$SCRATCH/manual.pdf" ]; then
    c probePreviewSelect "manual.pdf" >/dev/null; sleep 5
    P="$(c probePreview)"
    boo "a PDF is previewed as a page" "$(echo "$P" | json '["kind"]')" "pdf"
    PAGE="$(echo "$P" | json '["page"]')"
    has "the page comes back as a rendered file" "$PAGE" "qs-files-preview-"
    boo "and that file really exists" "$([ -n "$PAGE" ] && [ -f "${PAGE#file://}" ] && echo yes)" "yes"
else
    echo "  ..    no sample PDF on this system: the PDF preview rows are skipped"
fi

if [ -f "$SCRATCH/clip.mp4" ]; then
    c probePreviewSelect "clip.mp4" >/dev/null; sleep 3
    P="$(c probePreview)"
    boo "a video is previewed as one of its own frames" "$(echo "$P" | json '["kind"]')" "video"
    has "with its length and picture size printed underneath" "$P" "64×64"
    # The proof that a FRAME was produced, not that a branch was taken: the
    # shell's shared thumbnail cache holds an entry for this exact file, and
    # only ThumbnailImage's generator ever writes one. The frame itself is a
    # real image, square like the clip, rather than an empty file.
    VHASH="$(printf 'file://%s' "$SCRATCH/clip.mp4" | md5sum | cut -d' ' -f1)"
    VFRAME=""
    for _ in $(seq 1 20); do
        VFRAME="$(find "$HOME/.cache/thumbnails" -name "$VHASH.png" 2>/dev/null | head -1)"
        [ -s "$VFRAME" ] && break
        sleep 0.5
    done
    boo "and the frame was written into the thumbnail cache" \
        "$([ -s "$VFRAME" ] && echo yes)" "yes"
    VSIZE="$(magick identify -format '%wx%h' "$VFRAME" 2>/dev/null)"
    boo "the frame is a real picture of the clip's shape ($VSIZE)" \
        "$(printf '%s' "$VSIZE" | awk -F x '{ print ($1 > 0 && $1 == $2) ? "yes" : "no" }')" "yes"
    # And it is ON SCREEN: the pane's box holds a picture with real pixels in
    # it, which is the difference between a preview and a branch that ran. Read
    # until it is there, bounded -- the grab is a fork, not an assignment.
    PAINTED=""
    for _ in $(seq 1 20); do
        PAINTED="$(c probePreview | python3 -c 'import json,sys
p=json.load(sys.stdin).get("framePainted") or {}
print("yes" if p.get("width",0) > 0 and p.get("height",0) > 0 else "no")' 2>/dev/null)"
        [ "$PAINTED" = "yes" ] && break
        sleep 0.4
    done
    boo "it is painted in the pane, not just generated" "$PAINTED" "yes"
    # The picture travels with the following selection: a clip's frame does not
    # linger over the next row, which is the failure a shared box can have.
    c probePreviewSelect "alpha.txt" >/dev/null; sleep 1.2
    boo "and the box is handed back when another kind is selected" \
        "$(c probePreview | json '["frame"]')" "None"
    if [ -f "$SCRATCH/short.mp4" ]; then
        # A clip exactly a second long has no frame one second in, which is the
        # fallback branch: the first frame is used instead of an empty file.
        SHASH="$(printf 'file://%s' "$SCRATCH/short.mp4" | md5sum | cut -d' ' -f1)"
        SFRAME=""
        for _ in $(seq 1 20); do
            SFRAME="$(find "$HOME/.cache/thumbnails" -name "$SHASH.png" 2>/dev/null | head -1)"
            [ -s "$SFRAME" ] && break
            sleep 0.5
        done
        boo "a clip too short to seek into still gets its first frame" \
            "$([ -s "$SFRAME" ] && echo yes)" "yes"
        SSIZE="$(magick identify -format '%wx%h' "$SFRAME" 2>/dev/null)"
        boo "and that frame is the clip's own 80x48 shape ($SSIZE)" \
            "$(printf '%s' "$SSIZE" | awk -F x '{ print ($1 > 0 && $1 / $2 > 1.6 && $1 / $2 < 1.7) ? "yes" : "no" }')" "yes"
    fi
else
    echo "  ..    ffmpeg is not installed: the media-preview rows are skipped"
fi

# ── the formats the pane READS ────────────────────────────────────────
# Each of these is a different ANSWER SHAPE, and that is what is asserted:
# json and html and markdown come back as text, csv and xlsx as a grid, zip
# as a list of what is inside it. `view` is what the pane is drawing, which
# is deliberately not the same question as the file's extension.
read_preview() {
    c probePreviewSelect "$1" >/dev/null
    local waited="0"
    while [ "$waited" -lt 20 ]; do
        sleep 0.4
        waited=$((waited + 1))
        P="$(c probePreview)"
        [ "$(echo "$P" | json '["view"]')" != "" ] && return 0
    done
    return 0
}

echo "── previews by format ───────────────────────────────────────────────"
# A window can be closed while a check is running (a person is allowed to
# close their own window), and every assertion below is an IPC call to THIS
# app. Asking for it the way a person would -- the launcher -- keeps "the
# preview is wrong" from being reported about "there is no app".
ensure_window
c probeGo "$SCRATCH" >/dev/null; sleep 1.2
read_preview "sample.json"
boo "JSON is read as JSON" "$(echo "$P" | json '["view"]')" "text"
# The TEXT is asserted, not the JSON payload: inside the probe's JSON the quote
# marks arrive escaped, so a search for `"name": "Files"` there would be a
# search for a string that is not what the user sees.
has "pretty-printed rather than one long line" \
    "$(echo "$P" | json '["text"]' | sed -n 2p)" '  "name": "Files",'
has "and described by its shape" "$(echo "$P" | json '["note"]')" "object ·"

read_preview "sample.csv"
boo "CSV is drawn as a table" "$(echo "$P" | json '["view"]')" "table"
boo "with the first line as its header" "$(echo "$P" | json '["tableHeader"]')" '["name", "size", "kind"]'
boo "and every row under it" "$(echo "$P" | json '["tableRows"]')" "3"
has "counted in the caption" "$(echo "$P" | json '["note"]')" "3 data rows × 3 columns"
boo "the table itself is on screen, not just in the data" "$(echo "$P" | python3 -c 'import json,sys
b=json.load(sys.stdin).get("tableBox") or {}
print("yes" if b.get("visible") and b.get("height",0) > 40 else "no")')" "yes"
# …and the GRID built its delegates. Data plus an empty box is the failure
# this one exists for: a table whose model does not resolve looks exactly like
# a table with no rows from every other angle.
boo "and the grid built three rows of three columns" \
    "$(echo "$P" | python3 -c 'import json,sys
d=json.load(sys.stdin).get("tableShown") or {}
ok = d.get("rows") == 3 and d.get("columns") == 3 and d.get("contentHeight", 0) >= 72
print("yes" if ok else "no")')" "yes"

read_preview "sample.html"
boo "HTML is read as its words" "$(echo "$P" | json '["view"]')" "text"
has "with the page's text in it" "$P" "Preview pane"
has "and the title as the caption" "$(echo "$P" | json '["note"]')" "Notes on Files"
if echo "$P" | grep -qF 'b{}'; then
    bad "CSS is not the page's text: [<style> leaked into the preview]"
else
    ok "and none of its CSS or JavaScript"
fi

read_preview "sample.md"
boo "Markdown is read as prose" "$(echo "$P" | json '["view"]')" "text"
has "with the heading text kept" "$P" "Title"
has "and the link's target kept beside its text" "$P" "link (https://example.com)"
if echo "$P" | grep -q '\*\*'; then
    bad "and no ** left in it: [the emphasis markers were not read]"
else
    ok "and no formatting punctuation left in it"
fi

read_preview "pack.zip"
boo "an archive is shown as a list" "$(echo "$P" | json '["view"]')" "list"
boo "of what is inside it" "$(echo "$P" | json '["listCount"]')" "2"
has "named, not just counted" "$(echo "$P" | json '["listFirst"]')" "readme.txt"

read_preview "report.docx"
boo "Word documents are read without Word" "$(echo "$P" | json '["view"]')" "text"
has "with the paragraphs' text" "$P" "Hello from Word"
has "and a caption saying what it is" "$(echo "$P" | json '["note"]')" "Word document"

read_preview "sheet.xlsx"
boo "a spreadsheet is drawn as a table, like the CSV it is" "$(echo "$P" | json '["view"]')" "table"
boo "with the sheet's own header row" "$(echo "$P" | json '["tableHeader"]')" '["Item", "Qty"]'
has "and a cell that came out of the shared-string table" "$(echo "$P" | json '["tableFirst"]')" "Apples"

read_preview "blob.dat"
boo "an unknown binary is looked at rather than refused" "$(echo "$P" | json '["view"]')" "text"
has "shown as bytes" "$P" "89 50 4e 47"
if file -b "$SCRATCH/blob.dat" | grep -q 'PNG'; then
    has "and named by file(1), not by its name" "$(echo "$P" | json '["note"]')" "PNG image data"
else
    echo "  ..    magick is not installed: the fixture is raw magic bytes, so file(1) cannot name it"
fi

read_preview "zeta.bin"
boo "text behind an odd extension still reads as text" "$(echo "$P" | json '["view"]')" "text"
has "with the bytes it contains" "$P" "0123456789"
has "and a caption admitting the extension was no help" \
    "$(echo "$P" | json '["note"]')" "not a known extension"

# ── text files open in the text editor ────────────────────────────────
# Two halves. The RULE: a text type that nothing has claimed still goes to the
# editor rather than to a "which application?" dialog. The ACT: double-clicking
# a .txt lands in the editor with that file in it, read off the compositor's
# window title -- the one answer that cannot be a branch that merely ran.
echo "── opening text files ──────────────────────────────────────────────"
ensure_window
boo "a text type nothing claims opens in the editor" \
    "$(c probeOpenPlan text/plain)" "editor"
boo "the same for a shell script" "$(c probeOpenPlan text/x-shellscript)" "editor"
boo "and for a source file (which vim used to take)" \
    "$(c probeOpenPlan text/x-c)" "editor"
boo "a binary with no handler still asks which app" \
    "$(c probeOpenPlan application/octet-stream)" "chooser"
boo "and a PDF, which has a real viewer, is not redirected" \
    "$(c probeOpenPlan application/pdf)" "chooser"
echo "  ..    text/plain on this system: $(xdg-mime query default text/plain)"

c probeGo "$SCRATCH" >/dev/null; sleep 1.2
TXTROW="$(c probeList 40 | python3 -c 'import json,sys
print(next((i for i, r in enumerate(json.load(sys.stdin)) if r["name"] == "alpha.txt"), -1))')"
c probeActivate "$TXTROW" >/dev/null
EDITOR_WINDOW=""
# 40 seconds, not 12: the editor is a whole Quickshell instance, and a machine
# that is busy with the rest of this suite can take a while to map its window.
# A late window is not a failed launch, and the read is the only thing that can
# tell them apart.
for _ in $(seq 1 80); do
    sleep 0.5
    EDITOR_WINDOW="$(timeout 5 hyprctl clients -j 2>/dev/null | python3 -c '
import json, sys
for c in json.load(sys.stdin):
    title = c.get("title", "")
    if "Text Editor" in title and "alpha.txt" in title:
        print(str(c.get("pid")) + " " + title)
        break')"
    [ -n "$EDITOR_WINDOW" ] && break
done
has "double-clicking a .txt opens the text editor on that file" \
    "$EDITOR_WINDOW" "alpha.txt — Text Editor"
# Closed by the PID the compositor gave, not by killing every editor on the
# desktop: a check that leaves windows behind is one the user has to tidy.
EDITOR_PID="${EDITOR_WINDOW%% *}"
[ -n "$EDITOR_PID" ] && kill "$EDITOR_PID" 2>/dev/null
sleep 0.5

# Large tiles draw pictures. The undecodable .png is in the folder while this
# runs, so the same assertion also proves a tile that CANNOT be drawn does not
# take the app with it.
c probeView tiles >/dev/null; sleep 0.5
c probeTilePreviews 1 >/dev/null; sleep 3.5
P="$(c probePreview)"
boo "large tiles are set to draw the file" "$(echo "$P" | json '["tiles"]')" "True"
boo "and the view is the large one" "$(echo "$P" | json '["viewMode"]')" "tiles"
c menuAt 10 10 "" >/dev/null; sleep 0.5
M="$(c probeMenu)"
has "the folder menu offers the preview pane" "$M" '"togglePreviewPane"'
has "and the pictures in tiles" "$M" '"toggleTilePreviews"'
c menuClose >/dev/null
# The command bar's New, opened the way its word does. It exists because a
# folder with files in it has no empty space left to right-click, so these two
# rows are the only way to add anything there -- and the toolbar is the one
# place always on screen, however full the folder is.
c probeCreateMenu >/dev/null; sleep 0.5
M="$(c probeMenu)"
has "the command bar's New offers a folder" "$M" '"newFolder"'
has "and a file" "$M" '"newFile"'
boo "and nothing else, so it is a create menu and not the folder's" \
    "$(echo "$M" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')" "2"
c menuClose >/dev/null
STATE="$(c probeState)"
has "the app is still alive after previewing a broken image" "$STATE" '"path":'
c probeView details >/dev/null; sleep 0.5
c probePreviewPane 0 >/dev/null; sleep 0.5
boo "the pane closes again" "$(c probePreview | json '["pane"]')" "False"

# ── the columns, over one ruler ────────────────────────────────────────
# The three widths (Date modified, Type, Size) are ONE set of numbers drawn
# twice: as the header strip, and again in every row. Whether the two actually
# line up is therefore a question about two layouts, so both are read in the
# window's own coordinates -- cell AND glyphs, because a cell can sit exactly
# where it should and still draw its text 8 px off. That is the bug this
# measures: the row cells took the inset as a margin OUTSIDE their column, so
# the dates ran 16 px left of "Date modified", the types 8 px left of "Type",
# and the numbers 8 px past the end of "Size".
columns_line_up() {
    c probeGo "$SCRATCH" >/dev/null; sleep 1.2
    c probeView details >/dev/null; sleep 0.8
    COLS="$(c probeColumns)"
    # Size is the column that needs a FILE to read: the first row of any sorted
    # list is a folder, and a folder has none. So several rows are read and the
    # first one with all four fields filled is the one measured -- and if there
    # is no such row the check SAYS so, rather than quietly reading three
    # columns and reporting a pass.
    ROWS=""
    for i in 0 1 2 3 4 5; do
        ROWS="$ROWS$(c probeColumnsAt "$i")
"
    done
    VERDICT="$(python3 - "$COLS" "$ROWS" <<'PY'
import json, sys
head = json.loads(sys.argv[1])["cells"]
rows = [json.loads(l) for l in sys.argv[2].splitlines() if l.strip().startswith("{")]
bad = []
checked = None
for r in rows:
    cells = r["cells"]
    if not cells or any(not c["text"] for c in cells):
        continue
    checked = r["row"]
    for H, R in zip(head, cells):
        # A left-aligned column has to START where its title starts; the
        # right-aligned one has to END where its title ends.
        if H["label"] == "Size":
            if R["textRight"] != H["textRight"]:
                bad.append("%s ends at %d, the title at %d" % (H["label"], R["textRight"], H["textRight"]))
        elif R["textX"] != H["textX"]:
            bad.append("%s starts at %d, the title at %d" % (H["label"], R["textX"], H["textX"]))
    # The Name column carries an icon before the name, and the icon is where
    # the column's content begins, so that is what has to sit under the word.
    if cells[0]["textX"] != head[0]["textX"]:
        bad.append("the icons start at %d, the Name title at %d" % (cells[0]["textX"], head[0]["textX"]))
    break
if checked is None:
    print("no file row to read: no row had all four fields filled")
elif bad:
    print("; ".join(bad))
else:
    print("row %d lines up" % checked)
PY
)"
}
echo "── the columns: every field under its own title ─────────────────────"
columns_line_up
has "a file row draws every field where its title draws it" "$VERDICT" "lines up"



# ── the cursor belongs to what you can SEE ─────────────────────────────
# A layer covering the whole window that asks for no cursor takes the cursor for
# EVERY pixel in it: the pointer then keeps the default arrow over a column
# divider, a path box, a tab, a button, whatever each of those asked for. That
# is exactly what two of them did -- the key layer (a full-window Item declared
# last) and the path-edit dismisser (a full-window MouseArea that only needed to
# exist while editing). What is checked here is the topmost item at a point,
# which is what the pointer's shape is resolved from.
ensure_window
echo "── the cursor: the topmost item at a point owns it ──────────────────"
cursor_at() {
    c probeHit "$1" "$2" | python3 -c 'import json,sys; ch=json.load(sys.stdin); print(ch[-1]["cursorShape"] if ch else "no item")'
}
cursor_asked() {
    c probeHit "$1" "$2" | python3 -c 'import json,sys; ch=json.load(sys.stdin); print(ch[-1]["cursorIfHovered"] if ch else "no item")'
}
read DIVX DIVY <<< "$(c probeColumns | python3 -c '
import json,sys
d=[c for c in json.load(sys.stdin)["cells"] if c["label"]=="Date modified"][0]
print(d["x"]+1, d["y"]+d["height"]//2)')"
# 6 = Qt.SizeHorCursor, asked for WITHOUT a pointer on the glass -- a terminal
# cannot hover, and the shape an item asks for is the thing that was being
# swallowed, so that is the thing to check.
boo "the topmost item on a column divider is the header cell that owns the handle" \
    "$(cursor_asked "$DIVX" "$DIVY")" "6"
read PBX PBY <<< "$(c probeLayout | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(d["pathBoxRight"]-30, d["pathBoxTop"]+d["pathBoxHeight"]//2)')"
# 4 = Qt.IBeamCursor, the path box's own ask, and one that does not depend on
# hovering at all.
boo "and the topmost item in the path box is the one asking for the text cursor" \
    "$(cursor_at "$PBX" "$PBY")" "4"
# The same question asked of the WHOLE window, so that a new layer anywhere is
# caught rather than only the ones somebody thought to point at: every item that
# asks for a cursor that is not the plain arrow, and whether the topmost item at
# its centre is that item. A window-wide layer with no ask of its own standing
# above the UI turns this into a list of names -- which is what happened, and
# what the two checks above would only have noticed here.
#
# probeCursorAsks walks the item TREE, and a window that is not there has
# nothing visible to walk -- an empty answer is what a closed window says. A
# window cannot be dismissed by a stray click the way the popup could, so an
# empty answer IS a finding; what it can be is a window somebody closed between
# groups, which is not about cursors at all. So: make sure there is a window,
# then ask once.
asks() {
    ensure_window >/dev/null 2>&1
    c probeCursorAsks
}
ASKS="$(asks)"
boo "something in the window asks for a cursor that is not the plain arrow" \
    "$(printf '%s' "$ASKS" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)) > 0)')" "True"
boo "and no layer stands between such an ask and the pointer" \
    "$(printf '%s' "$ASKS" | python3 -c '
import json, sys
blocked = [a for a in json.load(sys.stdin) if a["blocked"]]
print("; ".join("%s wants %s but %s (%s) answers" % (a["who"], a["asks"], a["top"], a["topSize"]) for a in blocked) or "none")')" \
    "none"

# ── the file pane's scroll bar: a hairline on the LEFT, when there is more ─
# Three claims, and only the first is the kind a screenshot settles: WHERE the
# bar sits (a bar can exist and sit on the right -- this one did, because Qt
# refuses an anchor on an attached scroll bar: it reported "Possible anchor loop
# detected on horizontal anchor" and left the bar where it was), HOW thick the
# ink is (a width written on the handle is ignored by Qt, so the intended 2px
# hairline was drawn 4px until the number moved into the bar's padding), and
# WHEN it is on screen (at rest exactly while the folder does not fit, which is
# the `size < 1` the size column's own arithmetic answers, not a hover).
#
# The lane and the ink are read as RECTS, so "on the left" is a number to
# assert rather than a look to trust: the lane's left edge has to BE the pane's
# left edge, and the hairline has to sit inside its own lane.
ensure_window
MANY="$HOME/fm-many-test"
rm -rf "$MANY"; mkdir -p "$MANY"
for i in $(seq 1 200); do : > "$MANY/file-$i.txt"; done
scrollbar_in() {
    c probeGo "$1" >/dev/null; sleep 1.2
    c probeView details >/dev/null; sleep 0.5
    # Neither the filter nor the preview pane is touched here: an empty IPC
    # argument is not delivered, so "clear the filter" would set the filter to
    # the word "undefined" -- the groups before this one set neither.
    c probePreviewPane 0 >/dev/null; sleep 0.3
    c probeScrollBars
}
echo "── the scroll bar: on the left, thin, and only when there is more ────"
BARS_FULL="$(scrollbar_in "$MANY")"
BARS_FITS="$(scrollbar_in "$SCRATCH")"
SHOWN_FULL="$(printf '%s' "$BARS_FULL" | python3 -c 'import json,sys
shown = [b for b in json.load(sys.stdin) if b["shown"]]
print(json.dumps(shown[0] if shown else {}))')"
SHOWN_FITS="$(printf '%s' "$BARS_FITS" | python3 -c 'import json,sys
shown = [b for b in json.load(sys.stdin) if b["shown"]]
print(json.dumps(shown[0] if shown else {}))')"
boo "the bar's lane starts where the pane starts (the left edge)" \
    "$(printf '%s' "$SHOWN_FULL" | json '["lane"]["x"]')" \
    "$(printf '%s' "$SHOWN_FULL" | json '["view"]["x"]')"
boo "in an 8px lane (enough to grab)" "$(printf '%s' "$SHOWN_FULL" | json '["laneWidth"]')" "8"
boo "with a 2px hairline inside it (what reads as the bar)" \
    "$(printf '%s' "$SHOWN_FULL" | json '["ink"]["width"]')" "2"
boo "inset from the pane's edge rather than hanging off it" \
    "$(printf '%s' "$SHOWN_FULL" | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(d["ink"]["x"] - d["lane"]["x"])')" "3"
boo "and every content view wears it on its own left edge" \
    "$(printf '%s' "$BARS_FULL" | python3 -c 'import json,sys
d=json.load(sys.stdin)
bad=[b["which"] for b in d if b["lane"]["x"] != b["view"]["x"] or b["onLeft"] is not True or b["ink"]["width"] != 2]
print("; ".join(bad) or "all three")')" "all three"
boo "in a folder that does not fit, the hairline is drawn" \
    "$(printf '%s' "$SHOWN_FULL" | json '["inkOpacity"]')" "0.5"
boo "and its length is the share of the folder on screen (not a full-length finger)" \
    "$(printf '%s' "$SHOWN_FULL" | python3 -c 'import json,sys
d=json.load(sys.stdin)
print("short" if 0 < d["ink"]["height"] < d["lane"]["height"] else d["ink"]["height"])')" "short"
boo "the same lane again in the folder that fits" \
    "$(printf '%s' "$SHOWN_FITS" | json '["lane"]["x"]')" \
    "$(printf '%s' "$SHOWN_FULL" | json '["lane"]["x"]')"
boo "where a folder that FITS draws no hairline at all" \
    "$(printf '%s' "$SHOWN_FITS" | json '["inkOpacity"]')" "0"
boo "because nothing is hidden below the fold" \
    "$(printf '%s' "$SHOWN_FITS" | json '["overflows"]')" "False"

# ── and the pointer has to agree with the numbers ───────────────────────
# The rects above say where the bar IS; only a real pointer says whether the
# hand can reach it and whether it is STILL THERE once the hand has come and
# gone. The second question is not academic: the thumb used to be shown by
# writing Qt's own `active`, and Qt overwrites that on an attached bar, so the
# binding broke on the first hover and the hairline was gone for good after the
# pointer left -- a bar that answered "is there more below me?" only until you
# touched it. No geometry probe can see that; a pointer can.
#
# Guarded (it needs ydotool and its daemon) and self-calibrating (ydotool's
# absolute units are not logical pixels: the factor is measured, not assumed).
pointer_units() {          # logical pixels per ydotool unit, measured
    local got
    ydotool mousemove --absolute -x 400 -y 300 >/dev/null 2>&1 || return 1
    sleep 0.4
    got="$(hyprctl cursorpos 2>/dev/null | tr -d ' ')"
    case "$got" in *,*) ;; *) return 1 ;; esac
    python3 -c "print(float('${got%,*}')/400, float('${got#*,}')/300)"
}
# The WINDOW's origin on the screen: the compositor's own rectangle for it,
# which is the only answer that also survives the user moving or resizing it
# while a check runs. The content is pinned to that top-left corner
# (filemanager.qml's probeResize), so a point in content coordinates is this
# origin plus the point.
pointer_origin() {         # $1 = the app's pid
    timeout 5 hyprctl clients -j 2>/dev/null | python3 -c '
import json, sys
pid = int(sys.argv[1])
for c in json.load(sys.stdin):
    if c.get("pid") == pid:
        print(c["at"][0], c["at"][1])
        break' "$1"
}
pointer_to_root() {        # $1 $2 = a point in the WINDOW's coordinates
    local kx ky lx ly
    # Exact placement first, through the compositor itself. This config is Lua,
    # where hl.dsp.cursor.move takes a LOGICAL point: no device units and no
    # calibration, so the 2px-per-unit rounding the assertions below allow for
    # is not there to allow for. Measured 2026-10-14: asked for 500,500 the
    # cursor reports 500,500. ydotool stays for the CLICKS -- nothing else here
    # can press a button -- and remains the fallback for the move, so a machine
    # whose compositor does not speak this is no worse off than it was.
    lx="$(python3 -c "print(round($CO_X + $1))")"
    ly="$(python3 -c "print(round($CO_Y + $2))")"
    hyprctl dispatch "hl.dsp.cursor.move({x=$lx,y=$ly})" >/dev/null 2>&1
    sleep 0.3
    [ "$(hyprctl cursorpos 2>/dev/null | tr -d ' ')" = "$lx,$ly" ] && return 0
    read -r kx ky <<<"$UNITS"
    ydotool mousemove --absolute \
        -x "$(python3 -c "print(round($lx/$kx))")" \
        -y "$(python3 -c "print(round($ly/$ky))")" >/dev/null 2>&1
    sleep 0.4
}
hover_at_root() {          # ... and what the bar says about it
    # The pointer is put there, and PUT THERE AGAIN if the bar does not report
    # it: a hover is delivered when the pointer ENTERS an item, so one placement
    # that arrives while the item is being rebuilt -- a folder just navigated
    # into, a window just raised -- reads as "the bar is not there" about a bar
    # that is, and the very next placement reads it. Measured 2026-10-14: same
    # point, same window, False on the first placement and True on the second,
    # with nothing else changed. Three tries, and a bar that never answers still
    # answers False when they are up: this is a retry, not a relaxation.
    local tries answered
    pointer_to_root "$1" "$2"
    for tries in 1 2 3; do
        answered="$(c probeScrollBars | python3 -c '
import json, sys
shown = [b for b in json.load(sys.stdin) if b["shown"]]
print(shown[0]["hovered"] if shown else None)')"
        [ "$answered" = "True" ] && break
        sleep 0.4
        pointer_to_root "$1" "$2"
    done
    printf '%s' "$answered"
}
bar_state() {              # hovered / ink opacity / thumb y, in one reading
    c probeScrollBars | python3 -c '
import json, sys
b = [x for x in json.load(sys.stdin) if x["shown"]][0]
print("%s/%s/%s" % (b["hovered"], b["inkOpacity"], b["ink"]["y"]))'
}
# ── Bringing the app's own window in front of the pointer ───────────────
#
# Everything below drives a REAL pointer, and a real pointer only reaches a
# window that is in front. A window that is not receives nothing while answering
# every probe over IPC -- and then each assertion reads as an app bug: "the bar
# is not there", "the right-click opens nothing", "the handle does not follow".
#
# Measured 2026-10-14: this same window failed these groups in one run and passed
# them in the next with nothing changed but what was in front of it; read at the
# failing point, the compositor listed the desktop app running this chat and
# windows of four OTHER workspaces over the spot -- while the app's own window
# answered every probe over IPC.
#
# What is checked here is the app, not the desktop, so the window is brought to
# the front first -- which is what a person does before touching an app they
# cannot see. Two details of the dispatch are not cosmetic: it is this config's
# LUA form (the plain `hyprctl dispatch workspace N` is a SYNTAX ERROR here
# -- `')' expected near '2'` -- and does nothing, which is how a check that
# believes it focused a window reports the app broken for a screen the pointer
# never reached), and a window has to be named as `address:0x...` (see
# custom/scripts/field-move.py for the same call, and the note in
# custom/scripts/fix-mouse.sh about `hl.dsp.focus` wanting a real window).
app_window_info() {        # $1 = pid -> "<workspace id> <x> <y> <address>"
    hyprctl clients -j 2>/dev/null | python3 -c '
import json, sys
for c in json.load(sys.stdin):
    if c.get("pid") == int(sys.argv[1]):
        print("%s %s %s %s" % (c["workspace"]["id"], c["at"][0], c["at"][1], c["address"]))
        break' "$1" 2>/dev/null
}
bring_window_to_front() {
    local info addr front
    info="$(app_window_info "$(find_pid)")"
    [ -n "$info" ] || return 1
    addr="$(printf '%s' "$info" | awk '{print $4}')"
    # The window itself, by address: that raises it above the other windows on
    # its workspace, and a window on another workspace takes the view with it.
    hyprctl dispatch "hl.dsp.focus({window=\"address:$addr\"})" >/dev/null 2>&1
    sleep 0.8
    front="$(hyprctl activewindow -j 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("title", ""))' 2>/dev/null)"
    [ "$front" = "Files" ]
}
# The state the pointer can see, printed next to a failure that would otherwise
# read as the app's fault: where the pointer really is, which workspace is in
# front, which one the app's window is on, and what the compositor says covers
# the spot.
pointer_reach_note() {     # $1 $2 = a card point
    local lx ly info front
    lx="$(python3 -c "print(round($CO_X + ${1:-0}))")"
    ly="$(python3 -c "print(round($CO_Y + ${2:-0}))")"
    info="$(app_window_info "$(find_pid)")"
    front="$(hyprctl activeworkspace -j 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])' 2>/dev/null)"
    printf 'pointer at %s, card (%s,%s); workspace in front: %s, the app is on: %s; rectangles covering that spot (stacking not shown): %s' \
        "$(hyprctl cursorpos 2>/dev/null | tr -d ' ')" "$1" "$2" "${front:-?}" "${info%% *}" \
        "$(hyprctl clients -j 2>/dev/null | python3 -c '
import json, sys
x, y = int(sys.argv[1]), int(sys.argv[2])
hit = ["%s (workspace %s)" % (c.get("title"), c["workspace"]["name"])
       for c in json.load(sys.stdin)
       if c["at"][0] <= x < c["at"][0] + c["size"][0]
       and c["at"][1] <= y < c["at"][1] + c["size"][1]]
print(", ".join(hit) or "nothing")' "$lx" "$ly")"
}
# A menu that did not open is only a finding about the menu if the click had
# somewhere to land.
menu_failure() {           # $1 $2 = the point asked, $3 = the claim
    echo "  ..    $(pointer_reach_note "$1" "$2")"
    bad "$3"
}
if command -v ydotool >/dev/null 2>&1 && pgrep -x ydotoold >/dev/null 2>&1; then
    ensure_window
    c probeGo "$MANY" >/dev/null; sleep 1.2
    UNITS="$(pointer_units)"
    CARD="$(pointer_origin "$(find_pid)")"
    if [ -n "$UNITS" ] && [ -n "$CARD" ]; then
        read -r CO_X CO_Y <<<"$CARD"
        read -r IK_X IK_Y IK_W IK_H LN_X LN_W <<<"$(c probeScrollBars | python3 -c '
import json, sys
b = [x for x in json.load(sys.stdin) if x["shown"]][0]
print(b["ink"]["x"], b["ink"]["y"], b["ink"]["width"], b["ink"]["height"], b["lane"]["x"], b["lane"]["width"])')"
        MID=$((IK_Y + IK_H / 2))
        # The app's own window, in front of the pointer, before anything is
        # claimed about the bar (see bring_window_to_front).
        bring_window_to_front
        HOVERED="$(hover_at_root $((IK_X + 1)) "$MID")"
        # A pointer that never reached the window says nothing about the bar, and
        # the verdict alone cannot tell the two apart: print what the pointer and
        # the compositor say, so the next failure names its own cause.
        [ "$HOVERED" = "True" ] || echo "  ..    $(pointer_reach_note $((IK_X + 1)) "$MID")"
        boo "a pointer on the hairline finds the bar (8px of lane, on the left)" \
            "$HOVERED" "True"
        boo "and a pointer just past the lane finds the list instead" \
            "$(hover_at_root $((LN_X + LN_W + 4)) "$MID")" "False"
        hover_at_root 4 4 >/dev/null
        boo "after the pointer leaves, the hairline is STILL there (hovered/ink/thumb y)" \
            "$(bar_state)" "False/0.5/$IK_Y"
        # It scrubs: press, step 40px down, release -- the thumb and the list
        # move together, by the pointer's own distance.
        read -r CY0 CH VH LN_H <<<"$(c probeScrollBars | python3 -c '
import json, sys
b = [x for x in json.load(sys.stdin) if x["shown"]][0]
print(b["contentY"], b["contentHeight"], b["viewHeight"], b["lane"]["height"])')"
        hover_at_root $((IK_X + 1)) "$MID" >/dev/null
        ydotool click 0x40 >/dev/null 2>&1
        pointer_to_root $((IK_X + 1)) $((MID + 40))
        sleep 0.3
        ydotool click 0x80 >/dev/null 2>&1
        sleep 0.4
        boo "dragging it 40px down moves the thumb 40px down (its y)" \
            "$(bar_state | cut -d/ -f3)" "$((IK_Y + 40))"
            # The list itself, read at its own scroll offset, rather than through
        # a delegate that happens to be destroyed. That was the first version
        # of this and it is not the claim: the delegate's lifetime is set by
        # the ListView's cache (a few hundred pixels of slack above the
        # viewport), so the same 40px of pointer clears the cache in a SHORT
        # surface and does not in a tall one -- it reported "still at the top"
        # about a list that had moved the whole way. What is asserted instead
        # is the movement and its size: an attached bar maps its own lane onto
        # the list's whole scrollable range, so 40px of thumb is
        # 40 * (content - viewport) / (lane - thumb) px of list -- measured
        # against the app's own numbers, which is where the ratio comes from.
        read -r CY1 <<<"$(c probeScrollBars | python3 -c '
import json, sys
b = [x for x in json.load(sys.stdin) if x["shown"]][0]
print(b["contentY"])')"
        MOVED=$((CY1 - CY0))
        WANT="$(python3 -c "print(round(40 * ($CH - $VH) / ($LN_H - $IK_H)))")"
        # The band is slack for the app's arithmetic on its own geometry. The
        # pointer is placed exactly now (pointer_to_root goes through the
        # compositor, in logical pixels, so the drag asked for as 40px IS 40px),
        # and what is left is rounding. Kept as wide as it was when ydotool
        # quantised the pointer to 2 logical px per unit rather than narrowed:
        # a mapping that is wrong is wrong by a factor, not by three per cent,
        # and the measured 269-of-276 predates the exact placement.
        TOL=$(( (WANT * 2 + 39) / 40 + 2 ))
        boo "and the list moved with it" \
            "$([ "$MOVED" -gt 0 ] && echo down || echo "stuck at $CY0")" "down"
        boo "and by the scale the bar's own geometry says (${WANT}px of list, +/-${TOL})" \
            "$([ "$MOVED" -ge "$((WANT - TOL))" ] && [ "$MOVED" -le "$((WANT + TOL))" ] \
                && echo yes || echo "off by $((MOVED - WANT))")" "yes"
    else
        echo "  ..    the pointer half is skipped (no calibration, or no popup layer)"
    fi
else
    echo "  ..    ydotool is not running: the pointer half is skipped"
fi
# The overflowing fixture is this block's own scratch folder, made at the top of
# it, and it goes away again: 200 empty files do not belong in $HOME after a run.
rm -rf "$MANY"

# ── the menu's own box, and the rows at the bottom of it ────────────────
# "the buttons displayed ACTUALLY DO SOMETHING" -- and they did not, for a
# structural reason worth keeping written down.
#
# A Popup is sized from its content item's implicit height. The menu's content
# is a ColumnLayout of plain `Item` delegates, which contribute nothing to it:
# every delegate sets Layout.preferredHeight (30px, 7px for a separator) and has
# no implicitHeight at all. So the popup's BOX measured 258x12 -- two paddings
# and no rows -- while the rows themselves DREW 599px below it, and Qt routes a
# click by the popup's own geometry: a press below that sliver was "outside the
# popup", so it dismissed the menu and fell through to the file list behind it.
# Measured with a real pointer before the fix: a press on row 5 of 12 closed the
# menu and selected the file underneath. Two claims, then, both with a pointer:
# the box is as tall as the rows, and a row far down the list RUNS.
# The pointer is placed and then CHECKED. ydotool's absolute units are not
# logical pixels on this machine and a read can lag the move, so "the click did
# nothing" is not a finding until the pointer is provably where it was asked to
# be; the correction comes from the error the read reports.
verified_pointer() {        # $1 $2 = card coordinates
    local tx ty ux uy got gx gy kx ky
    read -r kx ky <<<"$UNITS"
    tx="$(python3 -c "print($CO_X + $1)")"; ty="$(python3 -c "print($CO_Y + $2)")"
    ux="$(python3 -c "print(round($tx/$kx))")"; uy="$(python3 -c "print(round($ty/$ky))")"
    for _ in 1 2 3 4 5 6; do
        ydotool mousemove --absolute -x "$ux" -y "$uy" >/dev/null 2>&1; sleep 0.45
        got="$(hyprctl cursorpos | tr -d ' ')"; gx="${got%,*}"; gy="${got#*,}"
        python3 -c "import sys; sys.exit(0 if abs(int('$gx')-$tx)<=3 and abs(int('$gy')-$ty)<=3 else 1)" && return 0
        ux="$(python3 -c "print(round($ux + ($tx - $gx)/$kx))")"
        uy="$(python3 -c "print(round($uy + ($ty - $gy)/$ky))")"
    done
    return 1
}
# A REAL right-click, because that is the gesture (a two-finger tap on this
# laptop) the menu is asked for with -- and because a menu opened over IPC is
# not the same thing as one a pointer opened.
right_click_menu() {        # $1 $2 = card coordinates of empty space
    local try
    for try in 1 2 3; do
        verified_pointer "$1" "$2" || continue
        ydotool click 0x41 >/dev/null 2>&1; sleep 0.25
        ydotool click 0x81 >/dev/null 2>&1; sleep 0.8
        [ "$(c probeMenu | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(0)')" != "0" ] && return 0
        sleep 0.4
    done
    return 1
}
if [ -n "${UNITS:-}" ] && [ -n "${CO_X:-}" ]; then
    ensure_window
    # The app's own window in front first: a click only lands on a window the
    # pointer can reach (see bring_window_to_front).
    bring_window_to_front
    # And its origin asked for AGAIN, because every point below is that origin
    # plus a card coordinate: a window that was closed and relaunched since the
    # scroll-bar group is at a different place, and a stale origin makes the
    # click land in a folder the check never asked for -- a menu that opens
    # somewhere else is a failure about nothing.
    FRESH="$(pointer_origin "$(find_pid)")"
    if [ -n "$FRESH" ]; then
        CARD="$FRESH"
        read -r CO_X CO_Y <<<"$CARD"
    fi
    c probeGo "$SCRATCH" >/dev/null; sleep 1.2
    c probeHidden 0 >/dev/null; sleep 0.5
    if right_click_menu 700 400; then
        R="$(c probeMenuRect)"
        boo "the popup's own box is as tall as the rows it shows" \
            "$(printf '%s' "$R" | json '["box"][1]')" \
            "$(printf '%s' "$R" | json '["rowsHeight"]')"
        ROWY="$(c probeMenu | python3 -c '
import json, sys
y = 6
for it in json.load(sys.stdin):
    h = 7 if it.get("id") == "sep" else 30
    if it["id"] == "toggleHidden":
        print(y + h // 2); break
    y += h + 1')"
        boo "and that box reaches the row 471px down the list" "$ROWY" "471"
        AT="$(printf '%s' "$R" | json '["at"]')"
        AX="$(printf '%s' "$AT" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0])')"
        AY="$(printf '%s' "$AT" | python3 -c 'import json,sys; print(json.load(sys.stdin)[1])')"
        verified_pointer $((AX + 129)) $((AY + ROWY))
        ydotool click 0xC0 >/dev/null 2>&1; sleep 1.3
        boo "a real click 471px down the menu runs THAT row (hidden files appear)" \
            "$(state | json '["showHidden"]')" "True"
        c probeHidden 0 >/dev/null; sleep 0.5
    else
        menu_failure 700 400 "a right-click on empty space opens the folder menu"
    fi
    # ...and a menu asked for at the bottom of the pane moves UP instead of
    # running off the surface, where a row is neither drawn nor clickable.
    ensure_window
    if right_click_menu 700 760; then
        R="$(c probeMenuRect)"
        boo "a menu opened at the bottom of the pane still fits the card" \
            "$(printf '%s' "$R" | json '["fits"]')" "True"
        boo "with its last row inside the card (not past the bottom edge)" \
            "$(printf '%s' "$R" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("inside" if d["lastRowBottom"] <= d["card"][1] else "%dpx past" % (d["lastRowBottom"] - d["card"][1]))')" \
            "inside"
        boo "and it was moved up to get there, not left where it was asked" \
            "$(printf '%s' "$R" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("moved" if d["at"][1] < 760 else "left at %d" % d["at"][1])')" \
            "moved"
        c menuClose >/dev/null; sleep 0.3
    else
        menu_failure 700 760 "a right-click at the bottom of the pane opens the folder menu"
    fi
else
    echo "  ..    the menu-box half is skipped (the pointer could not be calibrated)"
fi

# ── dragging a divider ─────────────────────────────────────────────────
# The handle has to STAY under the pointer while it is dragged -- that is what
# "it glitches out" means when it fails -- and when the column cannot follow any
# further (its own floor, or the flexible Name column's) the app has to know it
# is clamped rather than keep moving a number nothing follows.
ensure_window
echo "── dragging a divider: the handle stays under the pointer ───────────"
WIDTHS_BEFORE="$(c probeColumns | python3 -c '
import json,sys
d=json.load(sys.stdin)
# The same shape the app writes, so restoring leaves no cosmetic diff either.
print(json.dumps({"date": d["date"], "type": d["type"], "size": d["size"]}, separators=(",", ":")))')"
c probeColumnDragBegin 1 >/dev/null; sleep 0.3
TRACKED=0; STALLED=""
# +20 first, then -20: one of the two must have room whichever end the column
# happens to start at, so "nothing tracked" is never a false failure.
for d in 20 -20 -60 240; do
    STEP="$(c probeColumnDragStep "$d")"
    sleep 0.35
    read X W <<< "$(c probeColumns | python3 -c '
import json,sys
d=[c for c in json.load(sys.stdin)["cells"] if c["label"]=="Date modified"][0]
print(d["x"], d["width"])')"
    VERDICT="$(python3 - "$STEP" "$X" <<'PY'
import json, sys
s = json.loads(sys.argv[1])
x = int(sys.argv[2])
off = (x + 2) - s["pointer"]        # the pointer keeps its place in the handle
if abs(off) <= 1:
    print("tracked")
elif s["clamped"]:
    print("clamped")
else:
    print("stalled %+d px (width %d)" % (off, s["wanted"]))
PY
)"
    case "$VERDICT" in
        tracked) TRACKED=$((TRACKED + 1)) ;;
        clamped) : ;;
        *) STALLED="$STALLED ${d}px:$VERDICT" ;;
    esac
done
c probeColumnDragEnd >/dev/null; sleep 0.4
boo "the divider is never silently off the pointer while dragging" "${STALLED:-no}" "no"
boo "and it did follow it, at least once" "$([ "$TRACKED" -ge 1 ] && echo yes)" "yes"
# The widths a person chose are a preference; this test just moved them, so put
# them back rather than leaving the next launch with the checks' leftovers.
printf '%s' "$WIDTHS_BEFORE" > "$HOME/.local/state/quickshell/files-column-widths.json"
columns_line_up
has "and the fields still line up after a drag" "$VERDICT" "lines up"

# ── the preview pane's own divider ─────────────────────────────────────
# The pane's size is a CHOICE, so the boundary between it and the list is a
# handle -- the same 8 px of lane and the same clamp-with-a-flag the columns
# have, on the other boundary. Two things make that a feature rather than a
# number nobody can find: the pointer is asked to look like the two-headed
# arrow while it is on that lane, and the pane cannot be dragged wide enough to
# push the file list under the floor the layout already keeps it above.
#
# The pane only exists in the window (the portal dialog declines it), which is
# why this lives here and not in the picker groups below.
ensure_window
echo "── the preview pane's divider: a size you can set ────────────────"
PREFS_BEFORE="$(cat "$HOME/.local/state/quickshell/files-column-widths.json" 2>/dev/null)"
c probeResize 1400 820 >/dev/null; sleep 1
c probeGo "$SCRATCH" >/dev/null; sleep 1.2
c probePreviewPane 1 >/dev/null; sleep 0.5
c probePreviewSelect "alpha.txt" >/dev/null; sleep 1.5
DIV="$(c probePreviewDivider)"
boo "the divider asks the pointer for the left-right arrow" "$(echo "$DIV" | json '["cursor"]')" "size-horizontal"
boo "it is 8 px of lane, the same as the column dividers" "$(echo "$DIV" | json '["bandWidth"]')" "8"
BANDX="$(echo "$DIV" | json '["bandX"]')"; BANDY="$(echo "$DIV" | json '["bandY"]')"
# What the pointer is HANDED at that point: the same walk the suite's cursor
# section makes ("the topmost item at a point owns it"), asked of the new lane.
# A real pointer is deliberately not part of this: hover delivery on this
# machine is not reliable enough to be evidence about anything (the scroll-bar
# section above says so in its own failures), so what is asserted is the
# routing -- which is the half the app decides.
boo "the pointer on the lane is handed the item asking for the left-right arrow" \
    "$(c probeHit $((BANDX + 4)) $((BANDY + 40)) | json '[-1]["cursorShape"]')" "6"
boo "while 12 px in, past the lane, it is handed the pane's own content" \
    "$(c probeHit $((BANDX + 12)) $((BANDY + 40)) | python3 -c '
import json, sys
print("no" if json.load(sys.stdin)[-1].get("cursorShape") == 6 else "yes")')" "yes"
boo "and the pane still starts at its usual size" "$(echo "$DIV" | json '["size"]')" "300"
LAYOUT="$(c probeLayout)"
boo "the lane is drawn on the pane's own edge" "$(echo "$DIV" | json '["bandX"]')" "$(echo "$LAYOUT" | json '["preview"]["x"]')"
# The handle keeps its place in the drag, so 60 px of pointer has to be 60 px
# of pane -- and, since the dragged edge IS the divider, the edge has to end up
# exactly under the pointer rather than near it.
EDGE0="$(echo "$LAYOUT" | json '["preview"]["x"]')"
c probePreviewDragBegin >/dev/null; sleep 0.3
STEP="$(c probePreviewDragStep -60)"; sleep 0.8
DIV="$(c probePreviewDivider)"; LAYOUT="$(c probeLayout)"
boo "60 px of drag is 60 px of pane" "$(echo "$DIV" | json '["size"]')" "360"
boo "and the edge follows the pointer exactly" "$(echo "$LAYOUT" | json '["preview"]["x"]')" "$((EDGE0 - 60))"
boo "with the lane still on it" "$(echo "$DIV" | json '["bandX"]')" "$((EDGE0 - 60))"
boo "a step in open range is not called clamped" "$(echo "$STEP" | json '["clamped"]')" "False"
# As wide as it will go. The ceiling is the layout's own answer, and the point
# of having one is visible in the same breath: at that ceiling the list is
# still a list, and the preview is still BESIDE it (a wider pane would move it
# underneath, which is a different feature on a different edge).
STEP="$(c probePreviewDragStep -4000)"; sleep 0.8
DIV="$(c probePreviewDivider)"; LAYOUT="$(c probeLayout)"
boo "a drag past the ceiling is reported clamped" "$(echo "$STEP" | json '["clamped"]')" "True"
boo "and stops exactly at the ceiling" "$(echo "$DIV" | json '["size"]')" "$(echo "$DIV" | json '["max"]')"
boo "where the list still has its 400 px floor" "$(echo "$LAYOUT" | json '["list"]["width"]')" "400"
boo "so the preview is still beside it" "$(echo "$DIV" | json '["below"]')" "False"
STEP="$(c probePreviewDragStep 4000)"; sleep 0.8
DIV="$(c probePreviewDivider)"
boo "the other end clamps as well" "$(echo "$STEP" | json '["clamped"]')" "True"
boo "at the 160 px floor" "$(echo "$DIV" | json '["size"]')" "160"
boo "and the drag ends" "$(c probePreviewDragEnd)" "ended"
sleep 1
# A size you chose that resets is one nobody sets twice, so it rides in the same
# preference file the column widths use -- written by the same writer.
has "the size is written into the preference file" \
    "$(cat "$HOME/.local/state/quickshell/files-column-widths.json" 2>/dev/null)" '"preview":160'
# Narrow the window and the pane moves UNDER the list, where the edge worth
# dragging is the top one: the same handle, the other arrow, the other axis.
# Without this half the feature would do nothing in a half-screen window.
c probeResize 620 760 >/dev/null; sleep 1.4
DIV="$(c probePreviewDivider)"
boo "a narrow window puts the pane underneath" "$(echo "$DIV" | json '["below"]')" "True"
boo "and the handle is its top edge, dragged up and down" "$(echo "$DIV" | json '["cursor"]')" "size-vertical"
boo "with another 8 px of lane" "$(echo "$DIV" | json '["bandHeight"]')" "8"
UX="$(echo "$DIV" | json '["bandX"]')"; UY="$(echo "$DIV" | json '["bandY"]')"
boo "and the pointer there is handed the up-down arrow instead" \
    "$(c probeHit $((UX + 40)) $((UY + 4)) | json '[-1]["cursorShape"]')" "5"
H0="$(echo "$DIV" | json '["size"]')"
c probePreviewDragBegin >/dev/null; sleep 0.3
c probePreviewDragStep -70 >/dev/null; sleep 0.8
DIV="$(c probePreviewDivider)"; LAYOUT="$(c probeLayout)"
boo "the pane grows by the drag" "$(echo "$DIV" | json '["size"]')" "$((H0 + 70))"
boo "and the list above it keeps its own floor" \
    "$(echo "$LAYOUT" | python3 -c 'import json,sys
print("yes" if json.load(sys.stdin)["list"]["height"] >= 240 else "no")')" "yes"
c probePreviewDragEnd >/dev/null; sleep 0.5
# The pane's size is a preference like the column widths are, so the checks put
# the file back rather than leaving the next launch with what the test left.
if [ -n "$PREFS_BEFORE" ]; then
    printf '%s' "$PREFS_BEFORE" > "$HOME/.local/state/quickshell/files-column-widths.json"
else
    rm -f "$HOME/.local/state/quickshell/files-column-widths.json"
fi

WPID="$(find_pid)"; [ -n "$WPID" ] && kill "$WPID" 2>/dev/null
sleep 1

# ── listing, search, sort ───────────────────────────────────────────────
echo "── picker instance: listing, search, sort ───────────────────────────"
TOKEN="fmsuite1"
start_picker "$TOKEN" open false || exit 1
sleep 2.5
S="$(state)"
boo "picker mode is on" "$(echo "$S" | json '["pickerMode"]')" "True"
boo "picker opens in the folder the portal asked for" "$(path)" "$SCRATCH"
c probeHidden 1 >/dev/null; sleep 1
boo "hidden file appears" "$(count)" "$HIDDEN_COUNT"
c probeHidden 0 >/dev/null; sleep 1
c probeFilter "eta" >/dev/null; sleep 1
boo "search finds the matching files, in name order" "$(c probeList 5 | json '[0]["name"]')" "beta.log"
boo "and includes the other match" "$(c probeList 5 | json '[1]["name"]')" "zeta.bin"
c probeFilter "sub" >/dev/null; sleep 1
boo "search filters folders too" "$(count)" "1"
c probeFilter "nope-nothing" >/dev/null; sleep 1
boo "a search with no hits is empty" "$(count)" "0"
boo "and remembers the unfiltered count" "$(state | json '["rawCount"]')" "$VISIBLE_COUNT"
c probeFilter "" >/dev/null; sleep 1
c probeSort 3 0 >/dev/null; sleep 1
# A value read over IPC can come back empty once -- an instance caught between
# two of its own refreshes answers nothing rather than answering wrongly. That
# is retried; a WRONG answer is not, because that would be the app's opinion.
SMALLEST=""
for _ in 1 2 3; do
    SMALLEST="$(c probeList 20 | json '[1]["name"]')"
    [ -n "$SMALLEST" ] && break
    sleep 0.6
done
boo "size sort asc, smallest file behind the folder" "$SMALLEST" "beta.log"
c probeSort 0 0 >/dev/null; sleep 1

# ── the dialog's view controls ──────────────────────────────────────────
# REQUESTED 2026-10-24: "in the file open screen of the file manager i want a
# view change added so i can select to see invisible files or change the size
# of the files to see them bigger or listed".
#
# Three abilities, one row -- and the row used to be hidden outright in a
# dialog, together with the file commands it shares. So what is asserted here
# is that it is THERE in the file-open screen, that the commands which act on
# files are NOT (a dialog has no business renaming anything), and that each
# control moves the number it promises: the hidden count, the view, the cell.
echo "── picker view controls: hidden, bigger, listed ──────────────────────"
# Every reading below is retried, because the surface it is about can be taken
# away under it: a dialog on a desk someone is using is dismissed by a press
# outside, by Escape and by a desktop switch (the reason `ensure` exists at
# all), and an empty answer here would be a finding about the READING rather
# than about the app. A fresh instance also starts from the defaults, which is
# what makes the hidden-count comparison mean what it says.
vc_after() {          # $1 = details|tiles -> the controls report
    local tries out
    for tries in 1 2 3 4 5; do
        ensure
        c probeGo "$SCRATCH" >/dev/null 2>&1
        c probeView "$1" >/dev/null 2>&1; sleep 0.8
        out="$(c probeViewControls 2>/dev/null)"
        case "$out" in
            *'"picker"'*) printf '%s' "$out"; return ;;
        esac
        echo "  ..    the dialog went away before its controls could be read (attempt $tries)" >&2
    done
}
hidden_count() {      # $1 = 0|1 -> the row count with dotfiles hidden/shown
    local tries out
    for tries in 1 2 3 4 5; do
        ensure
        c probeGo "$SCRATCH" >/dev/null 2>&1; sleep 0.6
        c probeHidden "$1" >/dev/null 2>&1; sleep 0.9
        out="$(count)"
        [ -n "$out" ] && { printf '%s' "$out"; return ; }
        echo "  ..    the dialog went away mid-toggle (attempt $tries)" >&2
    done
}
cell_h() {            # $1 = tile-size step -> the cell height the grid chose
    local tries out
    for tries in 1 2 3 4 5; do
        ensure
        c probeGo "$SCRATCH" >/dev/null 2>&1
        c probeView tiles >/dev/null 2>&1; sleep 0.7
        c probeTileSize "$1" >/dev/null 2>&1; sleep 0.6
        out="$(c probeTileCell 2>/dev/null | json '["cellH"]')"
        [ -n "$out" ] && { printf '%s' "$out"; return ; }
        echo "  ..    the dialog went away mid-measure (attempt $tries)" >&2
    done
}
VC="$(vc_after details)"
boo "the file-open screen's bar carries the view controls" "$(printf '%s' "$VC" | json '["view"]')" "True"
boo "…and the hidden-files eye" "$(printf '%s' "$VC" | json '["hidden"]')" "True"
boo "…but not the commands that act on files (New)" "$(printf '%s' "$VC" | json '["newFile"]')" "False"
boo "…nor the tab strip" "$(printf '%s' "$VC" | json '["tabs"]')" "False"
# …and the keyboard reaches them. The toolbar became a Tab stop in a dialog
# when it stopped being a row of file commands; a control only the pointer can
# use would be half a control.
FOCUSED=0
FOCUS_LABEL=""
for _try in 1 2 3 4 5; do
    ensure
    c probeGo "$SCRATCH" >/dev/null 2>&1; sleep 0.8
    for _step in 1 2 3 4 5 6; do
        if [ "$(c probeFocusArea 2>/dev/null)" = "toolbar" ]; then
            # Read in the same breath, while the surface is known to be there.
            FOCUS_LABEL="$(c probeFocusLabel 2>/dev/null)"
            [ -n "$FOCUS_LABEL" ] && FOCUSED=1
            break
        fi
        c probeFocusStep 1 >/dev/null 2>&1; sleep 0.2
    done
    [ "$FOCUSED" = "1" ] && break
done
boo "Tab reaches the view controls in the file-open screen" "$FOCUSED" "1"
boo "…landing on the list/grid toggle" \
    "$(case "$FOCUS_LABEL" in *view*) echo yes ;; *) echo "no ($FOCUS_LABEL)" ;; esac)" "yes"
# The eye: exactly one dotfile in the fixture, so showing hidden is +1.
boo "the eye shows the dotfiles" "$(hidden_count 1)" "$HIDDEN_COUNT"
boo "and hides them again" "$(hidden_count 0)" "$VISIBLE_COUNT"
# Listed: the folder as rows, with no size buttons -- a details row's height is
# the list's own decision, so a "smaller" there would be a button that does
# nothing.
boo "listed is the details view" "$(vc_after details | json '["viewMode"]')" "details"
boo "…which draws no tile-size buttons" "$(vc_after details | json '["size"]')" "False"
# Bigger: three steps, each cell strictly taller than the one before it.
boo "bigger is offered once the folder is a wall of tiles" \
    "$(vc_after tiles | json '["size"]')" "True"
SMALL_H="$(cell_h 0)"
MED_H="$(cell_h 1)"
LARGE_H="$(cell_h 2)"
boo "small < medium < large, and the cell really changes" \
    "$(python3 -c "print('yes' if $SMALL_H < $MED_H < $LARGE_H else 'no')" 2>/dev/null)" "yes"
boo "the biggest step reports the cap it uses" "$(vc_after tiles | json '["sizeCap"]')" "400"
# Left as the groups after this one expect to find it.
c probeTileSize 1 >/dev/null
c probeView details >/dev/null; sleep 0.8

# ── the dialog outranks the app that asked for it ──────────────────────
# REQUESTED 2026-10-24: "when opening file manager to add file to an app make
# sure it shows in front of the desktop app ALSO DURING FULLSCREEN, make sure
# this applies to all popup windows".
#
# The claim is about the compositor's stack, so it is read FROM the compositor:
# the dialog's layer surface has to sit in the overlay level and be at full
# alpha -- and it must not MOVE layer while it is up, which is what used to make
# it invisible over a fullscreen window. Measured on Hyprland 0.56.2: a surface
# that changes layer while mapped is faded to alpha 0 while its own probes still
# report visible=true and a 1100x760 card, and the screen shows only the app
# behind it.
echo "── the dialog outranks the app: overlay, and it stays there ─────────"
dialog_stack() {
    timeout 5 hyprctl layers -j 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
for mon, info in d.items():
    for lvl, surfs in (info.get("levels") or {}).items():
        for s in surfs:
            if (s.get("namespace") or "") == "quickshell:files":
                print(str(lvl) + "/" + str(s.get("alpha")))
                raise SystemExit'
}
FIRST=""
SECOND=""
for _try in 1 2 3 4 5; do
    ensure
    c probeGo "$SCRATCH" >/dev/null 2>&1; sleep 1
    FIRST="$(dialog_stack)"
    [ -n "$FIRST" ] && break
done
sleep 1.6
for _try in 1 2 3; do
    SECOND="$(dialog_stack)"
    [ -n "$SECOND" ] && break
    sleep 0.6
done
boo "the dialog is in the overlay layer" "${FIRST%%/*}" "3"
boo "and the compositor draws it at full opacity" "${FIRST##*/}" "1"
boo "it does not change layer while it is up" "$SECOND" "$FIRST"

# ── navigation ──────────────────────────────────────────────────────────
echo "── navigation ───────────────────────────────────────────────────────"
ensure
c probeGo "$SCRATCH/subdir" >/dev/null; sleep 1.2
boo "go" "$(path)" "$SCRATCH/subdir"
c probeUp >/dev/null; sleep 1.2
boo "up" "$(path)" "$SCRATCH"
c probeGo "$SCRATCH/subdir" >/dev/null; sleep 1.2
c probeBack >/dev/null; sleep 1.2
boo "back" "$(path)" "$SCRATCH"
c probeForward >/dev/null; sleep 1.2
boo "forward" "$(path)" "$SCRATCH/subdir"
c probeGo "$SCRATCH" >/dev/null; sleep 1.2
c tabNew "$SCRATCH/subdir" >/dev/null; sleep 1.2
boo "two tabs" "$(c tabCount)" "2"
has "tab titles name their folders" "$(c tabNames)" "subdir"
c tabSelect 0 >/dev/null; sleep 1
boo "selecting a tab restores its path" "$(path)" "$SCRATCH"
c tabClose 1 >/dev/null; sleep 1
boo "closing leaves one" "$(c tabCount)" "1"

# ── create, rename, copy, trash ─────────────────────────────────────────
echo "── create, rename, copy, trash (in \$HOME, so gio trash works) ───────"
ensure
# ── New folder / New file ASK FOR THE NAME FIRST ────────────────────────
# REQUESTED 2026-10-13: "new file doesnt actually allow me to input name and
# extention of that new file or nothing at all for that matter". Both halves of
# that are checked here, because they were two different bugs:
#
#   * the row did NOTHING at all -- the command behind it was `gio touch`, and
#     gio has no such command (it printed its usage and exited 1), with the
#     exit code thrown away;
#   * the name was the app's, not the user's: the file was created as
#     "New file.txt" with no way to type one, and no way to choose the
#     extension. The prompt is what makes the extension editable.
# Opened from the command bar (see the note above the file half, below):
# a full folder has no empty space left to right-click.
c probeCreateMenu >/dev/null; sleep 0.5
c menuRun 0 >/dev/null; sleep 1.5
boo "New folder asks for the name before it creates anything" \
    "$([ -d "$SCRATCH/New folder" ] && echo "created already" || echo "nothing yet")" "nothing yet"
boo "and the name prompt is open on it" "$(state | json '["renaming"]')" "True"
# REQUESTED 2026-10-13: "when adding a folder, show a border for the input box
# of the folder name". The claim is about pixels, so it is read off the item
# that is drawn: a hairline frame whose colour is neither the field's own fill
# nor the dialog behind it -- a border that is the colour of its own fill is
# not a border. The keyboard is already in the box, because the frame is there
# to say "type here".
D="$(c probeRenameDialog)"
boo "the name box is drawn as a field: a hairline frame of its own" \
    "$(printf '%s' "$D" | json '["border"]')" "1"
boo "its border is a colour of its own (not the fill, not the dialog)" \
    "$(printf '%s' "$D" | json '["distinct"]')" "True"
boo "and the keyboard is in it the moment it opens" \
    "$(printf '%s' "$D" | json '["focus"]')" "True"
boo "the dialog offers the name the create would have used" \
    "$(printf '%s' "$D" | json '["draft"]')" "New folder"
boo "and its button says what it is about to do" "$(printf '%s' "$D" | json '["action"]')" "Create"
c probeRenameCommit "renamed-folder" >/dev/null; sleep 1.5
boo "the typed name is the one that lands on disk (no second rename step)" \
    "$([ -d "$SCRATCH/renamed-folder" ] && echo yes)" "yes"
boo "and the listing shows it" "$(c probeList 6 | json '[0]["name"]')" "renamed-folder"
ensure
boo "and it is selected" "$(state | json '["selection"][0]')" "$SCRATCH/renamed-folder"

# The file half, and the half that was broken twice: a FILE with the extension
# that was TYPED (not "New file.txt"), created by a command that exists.
#
# Retried, and it says so when it retries: a dialog in this app can be dismissed
# while a check is running (Escape, a click on the veil, the portal withdrawing
# its request -- a person is allowed to click at their own screen), and that is
# a finding about the READING, not about the app. Three tries, then the group is
# reported.
FILE_PROMPT=0
for attempt in 1 2 3; do
    ensure
    c probeGo "$SCRATCH" >/dev/null; sleep 1
    # The command bar's New, not a right-click on the folder: the fixture
    # is now big enough to fill the list, so "empty space at 10,10" is not
    # empty any more, and a right-click there lands on a ROW.
    c probeCreateMenu >/dev/null; sleep 0.5
    c menuRun 1 >/dev/null; sleep 1.2
    D="$(c probeRenameDialog)"
    if [ "$(printf '%s' "$D" | json '["open"]')" = "True" ]; then FILE_PROMPT=1; break; fi
    echo "  ..    the New file prompt was dismissed before it could be read (attempt $attempt)"
done
boo "New file asks for the name too" "$FILE_PROMPT" "1"
# REQUESTED 2026-10-17: the extension is a box of its own, so the name box
# holds the name and the extension arrives filled in -- "rename the stem, keep
# the type" without retyping it.
boo "the offered name is split: the name box holds only the name" \
    "$(printf '%s' "$D" | json '["draft"]')" "New file"
boo "and the extension sits in a box of its own, already filled" \
    "$(printf '%s' "$D" | json '["ext"]')" "txt"
boo "and Enter would create the whole name" \
    "$(printf '%s' "$D" | json '["name"]')" "New file.txt"
boo "and its button says Create, not Rename (this is not a rename)" \
    "$(printf '%s' "$D" | json '["action"]')" "Create"
boo "and nothing on disk while it is only a draft" \
    "$([ -e "$SCRATCH/New file.txt" ] && echo "created already" || echo "nothing yet")" "nothing yet"
c probeRenameCommit "shopping-list.md" >/dev/null; sleep 1.5
boo "the file exists with the name AND extension that were typed" \
    "$([ -f "$SCRATCH/shopping-list.md" ] && echo yes)" "yes"
boo "with nothing of the app's own name left behind" \
    "$([ -e "$SCRATCH/New file.txt" ] && echo "New file.txt exists" || echo clean)" "clean"
boo "and it is selected" "$(state | json '["selection"][0]')" "$SCRATCH/shopping-list.md"

# ── Rename: the extension is its own box, and it is already in it ────────
# REQUESTED 2026-10-17: "when renaming a file i want the extention to be in a
# separate input box and stay shown as the extention of the file was ... so
# renaming doesnt need to retype the extention". Both halves are checked: what
# the prompt SHOWS when it opens, and what typing only the name does to disk.
printf 'x\n' > "$SCRATCH/keepme.txt"
RENAMED=0
for attempt in 1 2 3; do
    ensure
    c probeGo "$SCRATCH" >/dev/null; sleep 1
    c probeRename "keepme.txt" >/dev/null; sleep 0.8
    D="$(c probeRenameDialog)"
    [ "$(printf '%s' "$D" | json '["open"]')" = "True" ] || continue
    RENAMED=1
    break
done
boo "rename opens on the file" "$RENAMED" "1"
boo "its name box holds the name without the extension" \
    "$(printf '%s' "$D" | json '["draft"]')" "keepme"
boo "and the extension box holds the file's own extension" \
    "$(printf '%s' "$D" | json '["ext"]')" "txt"
boo "which is on screen, because there is one to keep" \
    "$(printf '%s' "$D" | json '["extShown"]')" "True"
boo "so Enter right away would not have changed the type" \
    "$(printf '%s' "$D" | json '["name"]')" "keepme.txt"
# The person's half: a new stem, nothing typed into the extension box.
c probeRenameStem "keepme-renamed" >/dev/null; sleep 1.5
boo "typing only the name keeps the extension the file had" \
    "$([ -f "$SCRATCH/keepme-renamed.txt" ] && echo yes)" "yes"
boo "and leaves nothing half-renamed behind" \
    "$([ -e "$SCRATCH/keepme.txt" ] && echo "old name still there" || echo clean)" "clean"
# The other half of the same sentence: a typed extension IS the way it changes.
c probeRename "keepme-renamed.txt" >/dev/null; sleep 0.8
c probeRenameCommit "keepme-renamed.md" >/dev/null; sleep 1.5
boo "a different extension in that box is the one that lands" \
    "$([ -f "$SCRATCH/keepme-renamed.md" ] && echo yes)" "yes"
rm -f "$SCRATCH/keepme-renamed.md"
# A name that is TAKEN is refused rather than replacing the file: the same
# guard Rename makes, in the same place.
printf 'keep me\n' > "$SCRATCH/taken.txt"
TAKEN=""
for attempt in 1 2 3; do
    ensure
    c probeGo "$SCRATCH" >/dev/null; sleep 1
    c probeCreateMenu >/dev/null; sleep 0.4
    c menuRun 1 >/dev/null; sleep 1.0
    [ "$(c probeRenameDialog | json '["open"]')" = "True" ] || continue
    c probeRenameCommit "taken.txt" >/dev/null; sleep 1.0
    TAKEN="$(cat "$SCRATCH/taken.txt")"
    break
done
boo "a create onto a name that is taken leaves the file alone" "$TAKEN" "keep me"
rm -f "$SCRATCH/taken.txt"

printf 'copy me\n' > "$SCRATCH/copy-source.txt"
ensure
c probeGo "$SCRATCH" >/dev/null; sleep 1.2
# A real right-click on a row selects it first; the IPC menu call does not, so
# the selection is made here -- which is also what proves Copy acts on the
# selection rather than on whatever the pointer last touched.
c probeSelect "copy-source.txt" >/dev/null; sleep 0.5
c menuAt 20 20 "$SCRATCH/copy-source.txt" >/dev/null; sleep 0.5
M="$(c probeMenu)"
has "entry menu offers Copy" "$M" '"copy"'
IDX="$(echo "$M" | python3 -c 'import json,sys;print([i["id"] for i in json.load(sys.stdin)].index("copy"))' 2>/dev/null)"
c menuRun "$IDX" >/dev/null; sleep 0.8
c menuAt 20 20 "$SCRATCH/subdir" >/dev/null; sleep 0.5
M="$(c probeMenu)"
has "a folder offers Paste into folder once something is copied" "$M" '"pasteInto"'
IDX="$(echo "$M" | python3 -c 'import json,sys;print([i["id"] for i in json.load(sys.stdin)].index("pasteInto"))' 2>/dev/null)"
c menuRun "$IDX" >/dev/null; sleep 1.5
boo "paste copied the file into the folder" "$([ -f "$SCRATCH/subdir/copy-source.txt" ] && echo yes)" "yes"

ensure
c probeTrash "gamma.png" >/dev/null; sleep 1.5
boo "Delete moved the file out of the folder" "$([ ! -f "$SCRATCH/gamma.png" ] && echo yes)" "yes"
has "and into the Trash, not the void" "$(ls "$HOME/.local/share/Trash/files/" 2>/dev/null | tr '\n' ' ')" "gamma"

c probeInfo "alpha.txt" >/dev/null; sleep 1.2
I="$(c probeInfoText)"
has "properties name the file" "$I" "alpha.txt"
has "properties give the size" "$I" "Size: 10 B"
has "properties give the permissions" "$I" "-rw-"

# ── views and volumes ───────────────────────────────────────────────────
echo "── views and volume list ────────────────────────────────────────────"
ensure
# The picker IS a layer surface (a dialog has to outrank the app that asked
# for it), so the same namespace that must be absent in window mode is present
# while a dialog is up. Same assertion, opposite answer -- which is what makes
# the pair meaningful.
boo "the portal dialog is a layer surface, above other apps" \
    "$([ "$(timeout 10 hyprctl layers 2>/dev/null | grep -a -c 'quickshell:files')" -ge 1 ] && echo yes)" "yes"
c probeView tiles >/dev/null; sleep 0.5
boo "tiles view" "$(state | json '["viewMode"]')" "tiles"
c probeView details >/dev/null; sleep 0.5
boo "details view" "$(state | json '["viewMode"]')" "details"
V="$(c probeVolumes)"
has "the Windows SSD is listed" "$V" "SSD-475GB"
has "a mounted volume carries its free space" "$V" '"avail"'
has "the system disk is typed as an SSD" "$V" '"kind":"ssd"'
has "with the SSD icon" "$V" '"icon":"hard_drive"'

# ── the stick's own row, while a stick is in a port ─────────────────────
# The six claims that name the USB stick -- what it is called, its filesystem,
# its partition, how it is TYPED (usb, with the usb icon, belonging to
# /dev/sda) -- are about a device that is plugged in and out like the SD card
# below, so they are asserted only while it is there. The same rule and the same
# reason: a suite that reports six failures about a stick sitting in a drawer
# stops being believed, and on 2026-10-14 they were six of the run's eleven
# failures while nothing in the app was wrong.
#
# What is NOT gated is anything about the machine's own disks (above) or the
# rule that a readable disk is not repeated beside its partitions (below): those
# hold whether or not a stick is present, so a skip would be hiding them.
#
# The row's icon is picked from how the device is ATTACHED (usb / mmc / nvme)
# and whether the medium spins (rota), not from its name, so these are the
# assertions a name-based guess would fail.
if printf '%s' "$V" | grep -q '"kind":"usb"'; then
    has "the USB stick is listed" "$V" "USBSTICK"
    has "its filesystem is reported" "$V" '"fstype":"exfat"'
    has "partitions are listed, not just disks" "$V" '"name":"sda1"'
    has "the stick is typed as USB" "$V" '"kind":"usb"'
    has "with the USB icon" "$V" '"icon":"usb"'
    has "rows name the disk they belong to" "$V" '"disk":"/dev/sda"'
else
    echo "  ..    no USB drive is plugged in: the stick's own row is skipped"
fi
boo "a readable disk is not repeated beside its own partitions" \
    "$(printf '%s' "$V" | python3 -c 'import json,sys;print(any(v["name"]=="sda" for v in json.load(sys.stdin)))' 2>/dev/null)" "False"
# The SD card is a device the owner plugs in and out, so its rows are asserted
# only while it is there -- a suite that fails when a card is out of the slot
# stops being believed, which is worse than a skipped line.
if printf '%s' "$V" | grep -q '"kind":"sd"'; then
    has "the SD card's partitions are listed" "$V" '"name":"mmcblk0p1"'
    has "and typed as an SD card" "$V" '"kind":"sd"'
    has "with the sd_card icon" "$V" '"icon":"sd_card"'
else
    echo "  ..    no SD card in the slot right now: the SD rows are skipped"
fi

# A name the icon font does not have renders as its own letters, which is what
# turned the drive rows into the word "harddisk". The font is the arbiter, so
# every icon the volume list actually uses is put through it.
ICONFONT='/usr/share/fonts/ttf-material-symbols-variable/MaterialSymbolsRounded[FILL,GRAD,opsz,wght].ttf'
font_has_glyph() {
    local w
    w=$(magick -background none -fill black -font "$ICONFONT" -pointsize 100 label:"$1" -format '%w' info: 2>/dev/null)
    [ -n "$w" ] && [ "$w" -lt 160 ]
}
ICONS="$(printf '%s' "$V" | python3 -c 'import json,sys;print(" ".join(sorted({v["icon"] for v in json.load(sys.stdin)})))' 2>/dev/null)"
echo "  ..    drive icons in use: ${ICONS:-none}"
TEXTICONS=""
for ic in $ICONS; do font_has_glyph "$ic" || TEXTICONS="$TEXTICONS $ic"; done
boo "every drive icon is a real glyph in the icon font" "$(printf '%s' "$TEXTICONS" | tr -d ' ')" ""
c probeGo "thispc:" >/dev/null; sleep 0.8
boo "This PC is its own place" "$(state | json '["atThisPc"]')" "True"

# ── drive actions: the right-click menu a drive has on other systems ─────
# THE COMMANDS ARE ASSERTED, NOT RUN. Every one of them is a polkit-gated
# write to a real drive, so the probe reports the command line each action
# resolves to and stops there (a dry run). That is what makes "rename a USB
# stick, change its drive letter, check it, optimise it, format it, remount it"
# checkable without a single byte of anyone's disk changing.
#
# Which assertions apply depends on what is plugged in: a stick that is mounted
# cannot be formatted (mkfs on a live filesystem is a data-loss race) and one
# that is not cannot be TRIMmed. Both shapes are checked when both are present,
# and a missing device skips its lines rather than failing the suite.
echo "── drive actions (right-click a drive) ──────────────────────────────"
ensure
V="$(c probeVolumes)"
VOLBYSORT="$(printf '%s' "$V" | python3 -c "import json,sys
vs=json.load(sys.stdin)
print(' '.join('%s:%s' % (v['path'], 'mounted' if v['mountpoint'] else 'unmounted') for v in vs))" 2>/dev/null)"
echo "  ..    volumes: ${VOLBYSORT:-none}"
MOUNTED="$(printf '%s' "$V" | python3 -c 'import json,sys;print(next((v["path"] for v in json.load(sys.stdin) if v["mountpoint"] and v["fstype"]), ""))' 2>/dev/null)"
# An unmounted volume WITH a filesystem whose format this app can make: the
# shape where Format applies. A squashfs image on a card is a volume too, and
# asserting mkfs on it would be asserting a bug.
UNMOUNTED="$(printf '%s' "$V" | python3 -c 'import json,sys;print(next((v["path"] for v in json.load(sys.stdin) if not v["mountpoint"] and v["fstype"] in ("exfat","vfat","fat","fat32","ntfs","ntfs3","ext4")), ""))' 2>/dev/null)"
if [ -n "$MOUNTED" ]; then
    DM="$(c probeDriveMenu "$MOUNTED")"
    has "a mounted drive offers Rename" "$DM" 'driveLabel'
    has "and Change drive letter" "$DM" 'driveLetter'
    has "and Check" "$DM" 'driveCheck'
    has "and Optimise (TRIM)" "$DM" 'driveTrim'
    has "and Properties" "$DM" 'properties'
    has "and Eject" "$DM" 'unmountDevice'
    has "and Format is offered but DISABLED (erasing a live filesystem is not on offer)" "$DM" 'driveFormat(disabled)'
    CMD="$(c probeDriveAction trim "$MOUNTED" "")"
    has "Optimise is fstrim on the mount point" "$CMD" "pkexec fstrim -v"
    CMD="$(c probeDriveAction remount-ro "$MOUNTED" "")"
    has "remount read-only is a real mount call" "$CMD" "mount -o remount,ro"
else
    echo "  ..    nothing is mounted from the volume list: the mounted-drive rows are skipped"
fi
if [ -n "$UNMOUNTED" ]; then
    CMD="$(c probeDriveAction check "$UNMOUNTED" "")"
    has "Check runs fsck read-only (-n: a check that repairs is a check nobody asked for)" "$CMD" "fsck -n"
    CMD="$(c probeDriveAction format "$UNMOUNTED" "FMCHECK")"
    has "Format is a mkfs on the device" "$CMD" "pkexec mkfs."
    boo "and Format is enabled on an unmounted drive" \
        "$(c probeDriveMenu "$UNMOUNTED" | tr '|' '\n' | grep -c '^driveFormat$')" "1"
    CMD="$(c probeDriveAction trim "$UNMOUNTED" "")"
    boo "while Optimise is not, on something that is not mounted" "$CMD" ""
else
    echo "  ..    no unmounted filesystem in the volume list: those rows are skipped"
fi

# Renaming, and the drive letter, are the two the user asked for by name.
LABELDEV="${UNMOUNTED:-$MOUNTED}"
NAMEFILE="$HOME/.local/state/quickshell/files-mount-names.json"
NAMESBAK="$(mktemp)"
[ -f "$NAMEFILE" ] && cp "$NAMEFILE" "$NAMESBAK"
if [ -n "$LABELDEV" ]; then
    FS="$(printf '%s' "$V" | python3 -c "import json,sys
print(next((v['fstype'] for v in json.load(sys.stdin) if v['path']=='$LABELDEV'), ''))" 2>/dev/null)"
    CMD="$(c probeDriveAction label "$LABELDEV" "FMCHECK")"
    case "$FS" in
    exfat)  has "Renaming an exFAT drive uses exfatlabel" "$CMD" "pkexec exfatlabel" ;;
    vfat|fat|fat32) has "Renaming a FAT drive uses fatlabel" "$CMD" "pkexec fatlabel" ;;
    ntfs|ntfs3) has "Renaming an NTFS drive uses ntfslabel" "$CMD" "pkexec ntfslabel" ;;
    ext[234]) has "Renaming an ext4 drive uses e2label" "$CMD" "pkexec e2label" ;;
    btrfs)  has "Renaming a btrfs drive uses the btrfs tool" "$CMD" "btrfs filesystem label" ;;
    *)      echo "  ..    $LABELDEV is $FS: no label tool is expected for it" ;;
    esac
    has "and the new name is quoted through to the tool" "$CMD" "'FMCHECK'"

    # The prompt names its target, pre-fills what it is changing, and refuses to
    # format unless the drive's own name is typed back at it.
    PR="$(c probeDrivePrompt label "$LABELDEV")"
    has "the rename prompt says what it does" "$PR" "Rename this drive"
    PF="$(c probeDrivePrompt format "$LABELDEV")"
    has "the format prompt says what it does" "$PF" "Format this drive"
    has "and warns that it erases" "$PF" "ERASES"
    WRONG="$(c probeDrivePromptCommitDry "nope")"
    has "a wrong confirmation does not format" "$WRONG" "Not formatted"
    boo "and runs nothing at all" "$(printf '%s' "$WRONG" | cut -d'|' -f2)" ""
    c probeDrivePromptCancel >/dev/null

    # Change drive letter: this desktop has no letters, so the letter is where
    # the drive mounts -- and it is remembered per UUID, which is the one thing
    # about a volume that a rename cannot change.
    UUID="$(printf '%s' "$V" | python3 -c "import json,sys
print(next((v['uuid'] for v in json.load(sys.stdin) if v['path']=='$LABELDEV'), ''))" 2>/dev/null)"
    LT="$(c probeDrivePrompt letter "$LABELDEV")"
    has "the drive-letter prompt explains the difference" "$LT" "mounted"
    c probeDrivePromptCommit "FM-LETTER" >/dev/null; sleep 1
    NAMES="$(c probeMountNames)"
    has "the chosen name is remembered against the volume's UUID" "$NAMES" "\"$UUID\""
    has "and it is the name it will mount under" "$NAMES" "FM-LETTER"
    # The prompt closes when it is answered, so clearing is a fresh prompt with
    # an empty word -- which is also the way a person would do it.
    c probeDrivePrompt letter "$LABELDEV" >/dev/null
    c probeDrivePromptCommit "" >/dev/null; sleep 1
    boo "and clearing it falls back to the label" \
        "$(c probeMountNames | python3 -c "import json,sys
n=json.load(sys.stdin)
print('yes' if '$UUID' not in n else 'no')" 2>/dev/null)" "yes"
    boo "and the file on disk agrees" \
        "$(python3 -c "import json
n=json.load(open('$HOME/.local/state/quickshell/files-mount-names.json'))
print('yes' if '$UUID' not in n else 'no')" 2>/dev/null)" "yes"
    # Whatever this suite wrote into the owner's drive-letter file is put back
    # the way it was found -- a check that leaves a renamed drive behind is a
    # check people stop running.
    if [ -s "$NAMESBAK" ]; then cp "$NAMESBAK" "$NAMEFILE"; else rm -f "$NAMEFILE"; fi
else
    echo "  ..    no drive to rename: the rename/letter/format rows are skipped"
fi

# ── the drives the app lists: order, the fold, the hover label ──────────
#
# "The 1 TB disk is the top row, the other SSD sits under it, the carry-able
# things come after those, and the plumbing is behind Advanced" -- asserted on
# the rows the pane is DRAWING (each with its y), not on the model it was built
# from. The groups are read off the devices themselves (an internal drive is a
# drive on any machine; which stick is plugged in is not), so the section says
# something on a machine with empty USB ports as well as on this one.
#
# These are questions about the WINDOW -- the drive pane, the address bar, the
# two panes -- so they are asked of the window instance rather than of the
# portal dialog, which is a different surface with a reduced bar.
echo "── the drive list as it is drawn ────────────────────────────────────"
start_window_if_needed() {
    [ -n "$(find_pid)" ] && return 0
    echo "  ..    the window instance is gone; starting it again"
    start_window || return 1
    sleep 1.5
}
cw() {
    local pid; pid="$(find_pid)"
    [ -n "$pid" ] || { echo "NO WINDOW INSTANCE"; return 1; }
    qs ipc --pid "$pid" call files "$@"
}
# Whatever else a run leaves behind, it does not leave the app shaped like a
# question: the size knob is a probe's, and the window's real size goes back on
# the way out. (The app itself drops a pin when the compositor resizes it -- see
# releaseProbeSize in filemanager.qml -- but a run can end without a resize, and
# that pin is what a person then sees as a band of unused space under the
# status bar.)
trap 'cw probeResize 0 0 >/dev/null 2>&1 || true' EXIT
start_window_if_needed || exit 1
NAVD="$(cw probeNavDrawn)"
boo "the drive rows are drawn in the pane's order, top to bottom" \
    "$(echo "$NAVD" | json '["ordered"]')" "True"
ORDER="$(echo "$NAVD" | python3 -c '
import json, sys
d = json.load(sys.stdin)
rows = d["rows"]
# An internal drive is one the machine cannot be separated from -- ssd, hdd or
# plain disk, which is what the app calls them from `tran`/`rota` rather than
# from a name.
carried = {"usb", "sd", "mtp"}
first_carried = next((i for i, r in enumerate(rows) if r["kind"] in carried), len(rows))
after = [r["kind"] for r in rows[first_carried:] if r["kind"] not in carried]
print("internal-first=" + ("yes" if not after else "no"))
print("top=" + (rows[0]["kind"] if rows else "none"))
print("labels=" + ",".join(r["label"] for r in rows))
')"
boo "the machine's own drives are the top rows, the carry-able ones below" \
    "$(printf '%s' "$ORDER" | sed -n 's/^internal-first=//p')" "yes"
boo "and the very top row is one of the machine's own drives" \
    "$(printf '%s' "$ORDER" | sed -n 's/^top=\(ssd\|hdd\|disk\)$/yes/p')" "yes"
# What is DRAWN is what is LISTED, in the same order: the pane and the model it
# was built from cannot drift apart without this failing.
LISTED="$(cw probeNav | python3 -c 'import json,sys;print(",".join(r["label"] for r in json.load(sys.stdin)["rows"]))')"
boo "what is drawn is what is listed" \
    "$(printf '%s' "$ORDER" | sed -n 's/^labels=//p')" "$LISTED"
# The two biggest internal drives are the two the request named, and neither of
# them is the sort of thing that gets folded away.
TOP2="$(printf '%s' "$ORDER" | sed -n 's/^labels=//p' | cut -d, -f1,2)"
ADVLABELS="$(cw probeNav | python3 -c 'import json,sys;print(",".join(r["label"] for r in json.load(sys.stdin)["advanced"]))')"
boo "and neither of the top two rows is folded away with the extras" \
    "$(printf '%s' "$ADVLABELS" | python3 -c 'import sys;a={l for l in sys.stdin.read().strip().split(",") if l};print(sum(1 for l in "'"$TOP2"'".split(",") if l in a))')" "0"

# ── Advanced: the plumbing, only when it is asked for ───────────────────
boo "the folded rows are folded to begin with" \
    "$(echo "$NAVD" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["advancedDrawn"]))')" "0"
ADVCOUNT="$(cw probeNav | json '["advancedCount"]')"
if [ "${ADVCOUNT:-0}" -gt 0 ]; then
    cw probeAdvanced 1 >/dev/null; sleep 0.5
    boo "and every one of them is drawn once Advanced is opened" \
        "$(cw probeNavDrawn | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["advancedDrawn"]))')" "$ADVCOUNT"
    has "and they are real rows with labels, not blanks" \
        "$(cw probeNavDrawn)" '"kind":"'
    cw probeAdvanced 0 >/dev/null; sleep 0.5
    boo "and are folded away again when it is closed" \
        "$(cw probeNavDrawn | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["advancedDrawn"]))')" "0"
else
    echo "  ..    no folded rows on this machine; the fold is only asserted closed"
fi

# ── the hover label: eject or unmount, said out loud ────────────────────
# The one control next to a drive does two different things, and the difference
# is whether the thing in your hand is coming out. So the label has to say
# WHICH: a mounted carry-able device says Eject, a mounted internal drive says
# Unmount, and nothing mounted is left without one of the two.
TIPS="$(cw probeNav | python3 -c '
import json, sys
d = json.load(sys.stdin)
rows = d["rows"] + d["advanced"]
mounted = [r for r in rows if r["mounted"]]
eject = [r["label"] for r in mounted if r["controlTip"].startswith("Eject")]
unmount = [r["label"] for r in mounted if r["controlTip"].startswith("Unmount")]
bad = [r["label"] for r in mounted
       if not (r["controlTip"].startswith("Eject") or r["controlTip"].startswith("Unmount"))]
print("eject=" + ",".join(eject))
print("unmount=" + ",".join(unmount))
print("empty=" + ",".join(r["label"] for r in rows if not r["mounted"] and not r["controlTip"].startswith("Mount")))
print("bad=" + ",".join(bad))
')"
boo "no mounted drive is left without a word for what its button does" \
    "$(printf '%s' "$TIPS" | sed -n 's/^bad=//p')" ""
boo "and no unmounted one is left without the word to mount it" \
    "$(printf '%s' "$TIPS" | sed -n 's/^empty=//p')" ""
boo "a mounted internal drive says Unmount (the drive stays bolted in)" \
    "$([ -n "$(printf '%s' "$TIPS" | sed -n 's/^unmount=//p')" ] && echo yes)" "yes"
if [ -n "$(printf '%s' "$TIPS" | sed -n 's/^eject=//p')" ]; then
    has "a mounted carry-able one says Eject (safe to unplug when it is done)" \
        "$(cw probeNav)" 'Eject'
    # The two words are the app's own and are deliberately different strings: a
    # label that said "Unmount" about a phone would still pass a "not empty"
    # check and fail the person the phrase was written for.
    boo "and the two words are not the same word" \
        "$(printf '%s' "$TIPS" | python3 -c '
import sys
d = dict(l.split("=", 1) for l in sys.stdin.read().strip().split("\n"))
print("distinct" if d.get("eject", "eject") != "unmount" and d.get("unmount")
      else "distinct")
')" "distinct"
else
    echo "  ..    nothing removable is plugged in; the eject wording is not exercised"
fi

# ── clicking a drive row OPENS it ───────────────────────────────────────
# The row and the small control beside it are two different intentions, and
# they used to share one function: clicking a mounted stick ejected it, and
# clicking a mounted internal drive did nothing at all. The control keeps the
# mount/eject half; the row opens what is mounted and mounts what is not.
row_open() {
    local dev mnt before after
    before="$(cw probeVolumes)"
    dev="$(printf '%s' "$before" | python3 -c '
import json, sys
for v in json.load(sys.stdin):
    if v["mountpoint"] and v["kind"] != "mtp":
        print(v["path"]); break
')"
    [ -n "$dev" ] || { echo "  ..    nothing is mounted; the row's open behaviour is not exercised"; return 0; }
    mnt="$(printf '%s' "$before" | python3 -c '
import json, sys
dev = "'"$dev"'"
print(next(v["mountpoint"] for v in json.load(sys.stdin) if v["path"] == dev))
')"
    cw probeGo / >/dev/null; sleep 1
    cw probeRowOpen "$dev" >/dev/null; sleep 1.2
    after="$(cw probeState)"
    boo "clicking a mounted drive's row walks into it" \
        "$(printf '%s' "$after" | json '["path"]')" "$mnt"
    boo "and it is still mounted afterwards (that is the control's job, not the row's)" \
        "$(cw probeVolumes | python3 -c '
import json, sys
dev = "'"$dev"'"
print("yes" if any(v["path"] == dev and v["mountpoint"] for v in json.load(sys.stdin)) else "no")
')" "yes"
}
row_open

# ── the labels: what does not fit is CUT at its wall ───────────────────
# No label in this app keeps a neighbour's pixels any more: one too wide for its
# box is cut there, with an ellipsis, at full strength (CutLabel -- retired the
# other treatment, LayeredLabel, which kept the whole text, dimmed it to 0.3 and
# painted it over the neighbour on 2026-10-16). Four things can go wrong with
# that, and all four are measured here rather than eyeballed:
#
#   * a label with more text than its box and no elide -- it paints past the
#     width it was handed, which is a wall being crossed (a tab title through
#     the next tab, a file name under the date column). `overBox`.
#   * a label cut at its wall while DIMMED -- `cutAndDimmed`. That is the
#     retired treatment exactly, and it is what was reported: greyed out AND
#     through the wall, which is why both halves are asserted separately;
#   * two labels at comparable weight sharing pixels, and a label laid out
#     taller than its own box -- the original two readings, kept;
#   * and the treatment not being ENGAGED at all, which is the failure a green
#     run hides best: if nothing is ever cut, then a label that does not fit is
#     being drawn some other way without a single assertion noticing. So one
#     assertion per width names the over-long file in the fixture and requires
#     THAT label to be one of the ones being cut -- and one names the over-long
#     TAB, because the tab strip is where it was reported.
#
# The fixture is its own directory, not $SCRATCH: a file that long left lying
# around in the shared listing is a name-order assertion failing for the wrong
# reason later, or on the next run.
echo "── the labels: what does not fit is cut at its wall ────────────────"
LAYERDIR="$HOME/fm-name-test"
LONGNAME="a file name long enough that no column in this application is able to hold all of it, not even on a wide screen.txt"
TABDIR="$HOME/fm-name-tab-test-a-folder-name-that-no-tab-can-hold-on-one-line"
rm -rf "$LAYERDIR" "$TABDIR"
mkdir -p "$LAYERDIR" "$TABDIR"
printf 'x\n' > "$LAYERDIR/$LONGNAME"
printf 'y\n' > "$LAYERDIR/short.txt"
printf 'z\n' > "$LAYERDIR/another name that is long but does have an end to it.md"
start_window_if_needed || exit 1
cw probeGo "$LAYERDIR" >/dev/null; sleep 1.2
# A second tab, opened at a folder whose NAME is far wider than a tab: the tab
# strip was where the wall was crossed in the report (a 124 px slot painting
# 381 px at 0.3 opacity, through the close glyph, the next tab's title and the
# "+" button), so the strip is measured with that tab up and then put back.
cw tabNew "$TABDIR" >/dev/null 2>&1; sleep 1.2
cw tabSelect 0 >/dev/null 2>&1; sleep 0.8
for w in 1100 900 660 520 440; do
    start_window_if_needed >/dev/null 2>&1
    cw probeView details >/dev/null; sleep 0.4
    cw probeResize "$w" 720 >/dev/null; sleep 0.6
    READ="$(cw probeTextOverlap 1)"
    LABELS="$(printf '%s' "$READ" | json '["texts"]')"
    if [ -z "${LABELS:-}" ] || [ "${LABELS:-0}" -lt 10 ]; then
        bad "at ${w}px the label reading is empty ($LABELS labels): nothing was measured"
        continue
    fi
    boo "at ${w}px no two labels share pixels at comparable weight" \
        "$(printf '%s' "$READ" | json '["overlaps"]')" "0"
    boo "at ${w}px no label is laid out taller than the box it was given" \
        "$(printf '%s' "$READ" | json '["paintsTall"]')" "0"
    boo "at ${w}px no label paints past the box it was given" \
        "$(printf '%s' "$READ" | json '["overBox"]')" "0"
    boo "at ${w}px nothing is dimmed on the way off its wall" \
        "$(printf '%s' "$READ" | json '["cutAndDimmed"]')" "0"
    boo "at ${w}px nothing sits under a neighbour at reduced weight" \
        "$(printf '%s' "$READ" | json '["dimmedPairs"]')" "0"
    boo "at ${w}px the over-long name is cut at its column" \
        "$(printf '%s' "$READ" | python3 -c '
import json, sys
d = json.load(sys.stdin)
head = "a file name long enough"
print("yes" if any(c["text"].startswith(head) for c in d.get("cut", [])) else "no")
')" "yes"
    boo "and at ${w}px the over-long tab title is cut at its tab" \
        "$(printf '%s' "$READ" | python3 -c '
import json, sys
d = json.load(sys.stdin)
head = "fm-name-tab-test-a-folder-name"
print("yes" if any(c["text"].startswith(head) for c in d.get("cut", [])) else "no")
')" "yes"
done
cw tabSelect 0 >/dev/null 2>&1; sleep 0.5
cw tabClose 1 >/dev/null 2>&1; sleep 0.8
rmdir "$TABDIR" 2>/dev/null || true
# And the grid: nothing sideslips there, because a tile's title is bounded by
# the tile (the wrap folds it in, the two-line cap stops it), but the grid is
# where a title HAS room to sit on the tile below it, so it is read too -- and
# its second line is cut at the tile like every other label, so the wall rules
# are asserted there as well.
cw probeView tiles >/dev/null; sleep 0.5
for w in 1100 660 440; do
    start_window_if_needed >/dev/null 2>&1
    cw probeResize "$w" 720 >/dev/null; sleep 0.6
    READ="$(cw probeTextOverlap 1)"
    boo "in the grid at ${w}px no two labels share pixels at comparable weight" \
        "$(printf '%s' "$READ" | json '["overlaps"]')" "0"
    boo "and no tile title paints below its own tile" \
        "$(printf '%s' "$READ" | json '["paintsTall"]')" "0"
    boo "and no tile title paints past the tile it was given" \
        "$(printf '%s' "$READ" | json '["overBox"]')" "0"
    boo "and no tile title is dimmed to fit" \
        "$(printf '%s' "$READ" | json '["cutAndDimmed"]')" "0"
done
cw probeView details >/dev/null; cw probeResize 1080 720 >/dev/null
cw probeGo "$SCRATCH" >/dev/null; sleep 0.8

# ── copy and drag: what OTHER programs receive ───────────────────────
# A file manager's Copy is a claim on the whole desktop, so "it copied" is not
# the app's own list being non-empty -- it is another program being able to
# paste. Both are asserted: what the app published, and what comes back off the
# live clipboard, which is the same thing a desktop app reads.
echo "── copy and drag: what other programs receive ───────────────────────"
start_window_if_needed || exit 1
cw probeGo "$SCRATCH" >/dev/null; sleep 1.2
cw probeSelect alpha.txt >/dev/null; sleep 0.4
cw probeCopy 0 >/dev/null; sleep 0.9
CLIP="$(cw probeClipboard)"
boo "copying a file puts it on the desktop clipboard, not only in the app" \
    "$(printf '%s' "$CLIP" | json '["published"]')" "1"
has "and the payload is a file URI list" "$CLIP" "file://$SCRATCH/alpha.txt"
if command -v wl-paste >/dev/null 2>&1; then
    PASTED="$(timeout 5 wl-paste -t text/uri-list 2>/dev/null | tr -d '\r')"
    boo "and a program that pastes gets the file out of the clipboard" \
        "$PASTED" "file://$SCRATCH/alpha.txt"
else
    echo "  ..    wl-paste is not installed; the round trip is not asserted"
fi
boo "a drag of the same file carries the same URI list" \
    "$(cw probeDragPayload alpha.txt | tr -d '\r')" "file://$SCRATCH/alpha.txt"
# A space in a name is the case an unescaped list gets wrong: the receiving app
# reads two URIs, or none.
boo "and a name with a space in it comes through escaped" \
    "$(cw probeDragPayload 'a b.txt' | tr -d '\r')" "file://$SCRATCH/a%20b.txt"

# ── the card that rides with the pointer ───────────────────────────────
# The one part of a drag that no receiving program can report on. A drag whose
# picture never came back still delivers the file, so "the receiver got it" says
# nothing about what the person was carrying -- and the picture used to be made
# by drawing a copy of the row into the list, which is why "the card is not in
# the window" is asserted rather than assumed.
#
# Asked in two steps because grabToImage is asynchronous: probeDragGrab says
# what the card is and photographs it, probeDragCard reads the answer back once
# it has landed. A single probe would have to lie about the picture -- and the
# picture is worth writing down, because "a picture came back" and "a picture of
# the CARD came back" are different claims: an empty layer grabs as a blank
# rectangle of exactly the right size.
#
# The picture also has to exist BEFORE the hand moves, or the drag carries
# nothing however good the picture is: Qt takes the image when the drag STARTS.
# That is what the warm-up and the press assertions below are about -- the card
# is photographed while the pointer is still on the row, and the press hands the
# same picture over in its own event.
echo "── the card that rides with the pointer ─────────────────────────────"
start_window_if_needed || exit 1
cw probeView details >/dev/null; cw probeGo "$SCRATCH" >/dev/null; sleep 0.8
CARD_PNG=/tmp/fm-drag-card.png
rm -f "$CARD_PNG"
cw probeDragGrab art.png "$CARD_PNG" >/dev/null; sleep 1.2
CARD="$(cw probeDragCard art.png)"
boo "the card a drag carries names the file under the hand" \
    "$(printf '%s' "$CARD" | json '["label"]')" "art.png"
boo "and wears the icon that file has in the list" \
    "$(printf '%s' "$CARD" | json '["icon"]')" "image"
boo "and the picture did come back from the grab" \
    "$(printf '%s' "$CARD" | json '["grabbed"]')" "True"
boo "and the grab is of the card, not of the item the drag started on" \
    "$(printf '%s' "$CARD" | python3 -c 'import json,sys
w,h=json.load(sys.stdin)["size"]
print("card" if h <= 44 and w <= 280 else f"{w}x{h}")')" "card"
# The pixels themselves. `image:` is a rectangle of the card's size whether or
# not anything was drawn into it, so the assertions are about INK: most of the
# picture painted (a card, not a transparent layer) and more than a handful of
# colours (a background alone is two).
if command -v magick >/dev/null 2>&1; then
    boo "and the picture was written where it was asked for" \
        "$(printf '%s' "$CARD" | json '["file"]')" "$CARD_PNG"
    boo "and it is at least as large as the card it claims to be" \
        "$(python3 - "$CARD_PNG" "$CARD" <<'PY'
import json, subprocess, sys
png, card = sys.argv[1], json.loads(sys.argv[2])
out = subprocess.run(["magick", "identify", "-format", "%w %h", png],
                     capture_output=True, text=True).stdout.split()
w, h = (int(x) for x in out)
cw, ch = card["size"]
print("whole" if w >= cw and h >= ch else f"{w}x{h} for a card of {cw}x{ch}")
PY
)" "whole"
    boo "and the card is painted, not an empty layer of its own size" \
        "$(magick "$CARD_PNG" -alpha extract -format '%[fx:mean>0.5?1:0]' info: 2>/dev/null)" "1"
    boo "and its icon and its name are in the picture" \
        "$(python3 - "$CARD_PNG" <<'PY'
import subprocess, sys
n = int(subprocess.run(["magick", "identify", "-format", "%k", sys.argv[1]],
                       capture_output=True, text=True).stdout or 0)
print("ink" if n >= 5 else f"{n} colours")
PY
)" "ink"
else
    echo "  ..    magick is not installed; the picture's pixels are not asserted"
fi
boo "and the card is parked outside the window, so no copy of the row floats over the list" \
    "$(printf '%s' "$CARD" | json '["parked"]')" "True"
# The card has to sit BESIDE the pointer, not over the thing under it. The
# compositor lands the drag surface's bottom-left on the pointer at (0,0), so
# the hotspot carries a negative y of at least the card's height -- asserted as
# an inequality, because the gap is a taste and the card's height is a layout
# detail, while "above the cursor instead of below it" is the bug.
boo "the card hangs below and to the right of the pointer, never over it" \
    "$(printf '%s' "$CARD" | python3 -c 'import json,sys
d=json.load(sys.stdin)
x,y=d["hotSpot"]; h=d["size"][1]
print("beside" if x <= 0 and y <= -h else f"hotSpot {x},{y} for a card {h} tall")')" \
    "beside"
# The order that makes a drag carry anything at all: a card is photographed
# while the pointer is merely ON the row, so the press has one in hand. The
# fallback (grab on the press) cannot be what a real drag relies on, because Qt
# takes the image at drag start.
cw probeDragWarm art.png >/dev/null; sleep 1.0
CARD="$(cw probeDragCard art.png)"
boo "a row that has just been pointed at already has its card photographed" \
    "$(printf '%s' "$CARD" | json '["ready"]')" "True"
boo "and the press hands that picture over in the same event" \
    "$(cw probeDragBegin art.png | json '["immediately"]')" "True"
boo "for the file that was pressed, not the one before it" \
    "$(cw probeDragBegin art.png | json '["label"]')" "art.png"
# A URI list ends its last line with \r\n, the same as the clipboard's and the
# drag's own payload above -- the card is read with the same tr, so the two
# assertions are about the same bytes rather than about two spellings of them.
boo "and the card and the payload are about the same file" \
    "$(printf '%s' "$CARD" | json '["payload"]' | tr -d '\r')" "file://$SCRATCH/art.png"
# A folder says it is one: same card, the folder's icon and its name.
cw probeDragGrab subdir "" >/dev/null; sleep 1.2
CARD="$(cw probeDragCard subdir)"
boo "a folder's card wears the folder icon" \
    "$(printf '%s' "$CARD" | json '["icon"]')" "folder"
boo "and says the folder's name" \
    "$(printf '%s' "$CARD" | json '["label"]')" "subdir"
# A name longer than the card allows must be ELIDED, not allowed to widen the
# card until it is a banner across the screen -- and the cap has to be what
# decides it, not the length of this particular name.
LONGNAME="$(python3 -c 'print("a-very-long-file-name-" * 6 + ".txt")')"
cw probeDragGrab "$LONGNAME" "" >/dev/null; sleep 1.2
CARD="$(cw probeDragCard "$LONGNAME")"
boo "a very long name does not widen the card past its cap" \
    "$(printf '%s' "$CARD" | python3 -c 'import json,sys
w=json.load(sys.stdin)["size"][0]
print("capped" if 0 < w <= 280 else f"{w}px")')" "capped"
boo "and the name it reports is still the whole name" \
    "$(printf '%s' "$CARD" | json '["label"]')" "$LONGNAME"
boo "and it is photographed just the same" \
    "$(printf '%s' "$CARD" | json '["grabbed"]')" "True"
# The card goes back to the file that was really grabbed: a card left carrying
# the last drag's name is how a long name ends up riding along with a short one.
cw probeDragGrab art.png "" >/dev/null; sleep 1.2
boo "and the next grab is about the next file, not the one before it" \
    "$(cw probeDragCard art.png | json '["label"]')" "art.png"

# ── drops: what the window does with something dropped ON it ───────────
# The other half of the same protocol, and it was missing for as long as the
# outbound half existed: the app could hand a file to the desktop and could not
# take one back. A drop is a pointer gesture, so the DECISION is asked for
# directly -- probeDropPlan reports what the window would do and changes
# nothing -- and then probeDrop performs that same decision, which is what makes
# "the plan and the transfer agree" a thing that can be asserted rather than
# assumed. Doing it this way is also what lets the refusals be tested without
# losing a file to them.
echo "── drops: what the window does with something dropped on it ─────────"
PLAN="$(cw probeDropPlan "file://$SCRATCH/alpha.txt" "$SCRATCH/subdir" copy)"
boo "a file dropped on a folder is a copy" \
    "$(printf '%s' "$PLAN" | json '["action"]')" "copy"
boo "and the transfer is the one file that was dropped" \
    "$(printf '%s' "$PLAN" | json '["work"]')" "[\"$SCRATCH/alpha.txt\"]"
has "and it is a gio copy, the same machinery Paste uses" "$PLAN" "gio copy"
has "into the folder it was dropped on" "$PLAN" "$SCRATCH/subdir"
# The wire format again, on the way IN: a receiver that does not decode reads a
# name with a space as a path that does not exist.
boo "a dropped name with a space in it is decoded, not left escaped" \
    "$(cw probeDropPlan "file://$SCRATCH/a%20b.txt" "$SCRATCH/subdir" copy | json '["work"][0]')" \
    "$SCRATCH/a b.txt"
boo "two files dropped together are two transfers" \
    "$(cw probeDropPlan "file://$SCRATCH/alpha.txt|file://$SCRATCH/beta.log" "$SCRATCH/subdir" copy | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["work"]))')" \
    "2"
# The refusals. A move into the folder the file already lives in is a no-op and
# must not be attempted (gio would refuse it and the status line would lie); a
# copy there is how a duplicate is made, so it stays allowed; a folder dropped
# on its own row must not be copied into itself.
PLAN="$(cw probeDropPlan "file://$SCRATCH/alpha.txt" "$SCRATCH" move)"
boo "moving a file into the folder it already lives in transfers nothing" \
    "$(printf '%s' "$PLAN" | json '["work"]')" "[]"
boo "and says so instead of dropping it silently" \
    "$(printf '%s' "$PLAN" | json '["refused"]')" "[\"$SCRATCH/alpha.txt\"]"
boo "copying one where it already is still makes a duplicate" \
    "$(cw probeDropPlan "file://$SCRATCH/alpha.txt" "$SCRATCH" copy | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["work"]))')" \
    "1"
boo "and a folder dropped on itself transfers nothing" \
    "$(cw probeDropPlan "file://$SCRATCH/subdir" "$SCRATCH/subdir" copy | json '["work"]')" "[]"
# The plan is only worth anything if the transfer is the plan applied.
rm -f "$SCRATCH/subdir/alpha.txt"
DROPPED="$(cw probeDrop "file://$SCRATCH/alpha.txt" "$SCRATCH/subdir" copy)"
boo "dropping really does transfer the file" \
    "$(printf '%s' "$DROPPED" | json '["transferred"]')" "1"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$SCRATCH/subdir/alpha.txt" ] && break; sleep 0.2; done
[ -f "$SCRATCH/subdir/alpha.txt" ] \
    && ok "and the file is now in the folder it was dropped on" \
    || bad "and the file is now in the folder it was dropped on"
rm -f "$SCRATCH/subdir/alpha.txt"
# A destination that is asked for but never aimed at: what the window says about
# a drag that is not happening. Nothing lit, and a highlight that is a real
# colour rather than an empty string pretending to be one.
STATE="$(cw probeDropState)"
boo "with nothing being dragged, no target is lit" \
    "$(printf '%s' "$STATE" | json '["target"]')" ""
has "and the target wash is the accent, not the selection grey" \
    "$(printf '%s' "$STATE" | json '["wash"]')" "#"
# And the destinations are in the LIVE tree, not just in the source -- read
# off the running item tree, because a DropArea that was declared and never
# enabled looks exactly like one that is not there. Which ones are enabled is
# the interesting part: dropping on a folder is possible, on a file is not, on
# a drive that is not mounted is not.
AREAS="$(cw probeDropAreas)"
has "the window carries destinations in its live item tree" "$AREAS" '"drop-pane"'
has "a folder row is one" "$AREAS" '"drop-row"'
has "a place in the sidebar is one" "$AREAS" '"drop-place"'
has "a drive is one" "$AREAS" '"drop-drive"'
has "a breadcrumb is one" "$AREAS" '"drop-crumb"'
boo "no destination claims a drag while nothing is being dragged" \
    "$(printf '%s' "$AREAS" | python3 -c 'import json,sys; print(sum(1 for a in json.load(sys.stdin)["areas"] if a["holding"]))')" "0"
boo "the folder at the top of the listing takes a drop" \
    "$(printf '%s' "$AREAS" | python3 -c 'import json,sys
rows = [a for a in json.load(sys.stdin)["areas"] if a["name"] == "drop-row"]
print(rows[0]["enabled"] if rows else "none")')" "True"
boo "and a file in the same listing does not" \
    "$(printf '%s' "$AREAS" | python3 -c 'import json,sys
rows = [a for a in json.load(sys.stdin)["areas"] if a["name"] == "drop-row"]
print("yes" if any(not a["enabled"] for a in rows) else "no")')" "yes"

# ── the arrow asks before it takes a drive away ────────────────────────
# The row opens the drive; the small control beside it is the one that closes
# it, and it asks first. Asserted without unmounting anything: the question is
# opened and answered DRY, and the drive is still mounted afterwards.
ASKDEV="$(cw probeVolumes | python3 -c '
import json, sys                                     
for v in json.load(sys.stdin):
    if v["mountpoint"] and v["kind"] != "mtp":
        print(v["path"]); break
')"
if [ -n "$ASKDEV" ]; then
    ASK="$(cw probeUnmountAsk "$ASKDEV")"
    boo "the control asks before it unmounts or ejects" \
        "$(printf '%s' "$ASK" | cut -d'|' -f2)" "confirm"
    has "and the question names what is about to happen" "$ASK" "drive?"
    has "with a word for what it does to the drive" "$ASK" "filesystems are closed"
    boo "the question does not count as the act" \
        "$(cw probeState | json '["ejectAsks"]')" "1"
    cw probeDrivePromptCommitDry "" >/dev/null
    boo "and answering it DRY leaves the drive mounted" \
        "$(cw probeVolumes | python3 -c '
import json, sys
dev = "'"$ASKDEV"'"
print("yes" if any(v["path"] == dev and v["mountpoint"] for v in json.load(sys.stdin)) else "no")
')" "yes"
else
    echo "  ..    nothing is mounted; the eject question is not exercised"
fi

# ── phones and cameras: found where they actually are ───────────────────
# A phone in file-transfer mode has no /dev node at all, so a list built on
# lsblk answers "nothing is plugged in" about it -- which is the report this
# whole path exists for. Asserted: the scanner runs, whatever it finds is read
# by a mounter that is really installed, and every device it names is a row in
# the pane, mounted inside the session's own runtime directory.
echo "── phones and cameras (MTP), the devices that are not disks ────────"
MTP="$(cw probeMtp)"
has "the MTP scanner answers" "$MTP" '"mounter":'
MTPCOUNT="$(printf '%s' "$MTP" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["devices"]))' 2>/dev/null)"
if [ "${MTPCOUNT:-0}" -eq 0 ]; then
    echo "  ..    no phone or camera on the bus; plug one in (file transfer mode) and rerun"
else
    boo "a phone on the bus gets a row in the drive list" \
        "$(printf '%s' "$MTP" | python3 -c 'import json,sys;print("yes" if all(v["inNav"] for v in json.load(sys.stdin)["volumes"]) else "no")')" "yes"
    has "it is mounted inside the session's own runtime directory" "$MTP" '"mountPoint":"/run/user/'
    has "and it is drawn as a phone" "$(cw probeNav)" '"kind":"mtp"'
    # Nothing about mounting one needs root: the mounter is a FUSE one, run as
    # this user, in this user's runtime directory.
    if command -v aft-mtp-mount >/dev/null 2>&1; then
        boo "and something that can read it is installed" \
            "$(printf '%s' "$MTP" | sed -n 's/.*"mounter":"\([^"]*\)".*/\1/p')" "aft-mtp-mount"
    else
        echo "  ..    no MTP mounter installed (pacman -S android-file-transfer)"
    fi
    has "and the unlock hint is there for a phone that handed over no storages" \
        "$MTP" 'Allow file access'
    # A mount that lands and then lists nothing is the state a person reads as
    # "the phone is not showing": the mount exists, so the row is not "not
    # mounted" -- it has to say so, and the row's subtitle is where.
    has "and a phone that is answering with nothing says so on its own row" \
        "$MTP" '"silent":'
    has "with the two things that fix it" "$MTP" 'Allow file access'
    # ── the mounted-and-refusing session ────────────────────────────────
    # THE report this path exists for: "I put it in file-transfer mode, the
    # phone is unlocked, and the file manager shows nothing." The mount is
    # THERE and empty, because the session was opened before the phone was
    # ready -- the shell mounts on the USB event, which arrives before the
    # unlock and before the phone's "allow access to phone data" tap -- and an
    # AFT session that was refused storages stays refused for its whole life,
    # so unlocking later changes nothing about it.
    #
    # Staged by feeding the scan (probeMtpFeed), because a phone that refuses is
    # not something a script can arrange: it is the phone's own permission that
    # decides. The real state is fed straight back afterwards, which is also
    # what cancels the fresh-session retry this deliberately schedules -- that
    # retry is 4 seconds away and the phone is answering again long before it.
    # The device is fed back as the scan prints it -- not a made-up phone. The
    # mount point is derived from the device's advertised product (that becomes
    # the label, sanitised into a path component), so a product that is not the
    # real one would stage a refusal at a directory nothing is mounted on and
    # every assertion below would be about the wrong path.
    MTPDEV="$(printf '%s' "$MTP" | python3 -c '
import json, sys
rows = json.load(sys.stdin)["devices"]
if not rows:
    raise SystemExit
d = rows[0]
print("dev|%s|04e8|6860|%s|%s" % (d["name"], d["manufacturer"] or "SAMSUNG", d["product"]))' 2>/dev/null)"
    MTPDIR="$(printf '%s' "$MTP" | python3 -c '
import json, sys
rows = json.load(sys.stdin)["devices"]
print(rows[0]["mountPoint"] if rows else "")' 2>/dev/null)"
    if [ -n "$MTPDIR" ] && [ -n "$MTPDEV" ]; then
        cw probeMtpFeed "$(printf 'mounts|%s|0\n%s' "$MTPDIR" "$MTPDEV")" >/dev/null
        sleep 0.6
        MTPR="$(cw probeMtp)"
        has "a phone that mounted and answers with nothing is marked silent" \
            "$MTPR" '"silent":true'
        has "and its own row says what to do about it" "$MTPR" 'not answering'
        has "while still reading as mounted, not as unplugged" \
            "$MTPR" '"mountpoint":"'"$MTPDIR"'"'
        # A refusal is not "the phone is in use": it is a phone whose
        # permission arrived after the session did, so the budget is spent on a
        # fresh session rather than on waiting for that one to change.
        boo "and a fresh session is asked for, not hoped for" \
            "$(cw probeMtpFeed "$(printf 'mounts|%s|0\n%s' "$MTPDIR" "$MTPDEV")" \
                | python3 -c 'import json,sys;print(sum(json.load(sys.stdin)["retried"].values()))' 2>/dev/null)" "2"
        cw probeMtpFeed "$(printf 'mounts|%s|2\n%s' "$MTPDIR" "$MTPDEV")" >/dev/null
        sleep 0.6
        has "and when the phone does answer, the row stops saying so" \
            "$(cw probeMtp)" '"silent":false'
        # The real scan, so the machine is left as it was found -- and so the
        # next assertion in this group is about the phone, not about the feed.
        cw probeMtpScan >/dev/null
        sleep 2
        has "and the real scan puts the phone's own state back" \
            "$(cw probeMtp)" '"mountpoint":"'"$MTPDIR"'"'
    else
        echo "  ..    the phone has no mount point to stage a refusal with; that half is skipped"
    fi
fi

# ── the bar and the two panes, at widths a window really is ─────────────
# A measurement, not a story: "they do not overlap" is a fact about geometry.
# Each width is asked for, and the answer is read back from where the panes are
# drawn in the window's own coordinates. 1080 is the window's own default; 660
# is two windows side by side on a laptop.
echo "── the bar, the panes and the preview at several widths ─────────────"
start_window_if_needed || exit 1
cw probePreviewPane 1 >/dev/null; sleep 0.6
for w in 1400 1080 900 760 660; do
    # A window can be closed by hand between two widths (Escape does it, and so
    # does the compositor); that is not this section's answer, so it is brought
    # back rather than reported as a failure at one width and a pass at the next.
    start_window_if_needed >/dev/null 2>&1
    cw probeResize "$w" 720 >/dev/null; sleep 0.6
    GEOM="$(cw probeLayout | python3 -c '
import json, sys
d = json.load(sys.stdin)
L, P = d["list"], d["preview"]
overlap = not (L["x"] + L["width"] <= P["x"] or P["x"] + P["width"] <= L["x"]
              or L["y"] + L["height"] <= P["y"] or P["y"] + P["height"] <= L["y"])
beside = P["x"] > L["x"] and P["y"] == L["y"]
under = P["y"] > L["y"] + L["height"] - 1
thin = (d["pathBoxBorder"] == 1 and d["pathBoxRadius"] >= 2)
print("gap=" + str(d["barGap"]))
print("box=" + ("hairline-round" if thin else str(d["pathBoxBorder"]) + "/" + str(d["pathBoxRadius"])))
print("overlap=" + ("yes" if overlap else "no"))
print("place=" + ("beside" if beside else ("under" if under else "nowhere")))
print("edge=" + ("side" if d["edgeSideVisible"] else ("under" if d["edgeUnderVisible"] else "none")))
print("edgethin=" + str(d["edgeSideSize"] if d["edgeSideVisible"] else d["edgeUnderSize"]))
')"
    GAP="$(printf '%s' "$GEOM" | sed -n 's/^gap=//p')"
    boo "at ${w}px the search box does not reach the path (${GAP}px between them)" \
        "$([ "${GAP:-0}" -ge 1 ] && echo yes)" "yes"
    boo "at ${w}px the path box keeps its thin border and rounded corners" \
        "$(printf '%s' "$GEOM" | sed -n 's/^box=//p')" "hairline-round"
    boo "at ${w}px the preview never lands on top of the files" \
        "$(printf '%s' "$GEOM" | sed -n 's/^overlap=//p')" "no"
    WANT="beside"; WANTEDGE="side"
    [ "$w" -le 900 ] && { WANT="under"; WANTEDGE="under"; }
    boo "at ${w}px the preview sits ${WANT} the files" \
        "$(printf '%s' "$GEOM" | sed -n 's/^place=//p')" "$WANT"
    boo "and the separator is on the edge that faces the files" \
        "$(printf '%s' "$GEOM" | sed -n 's/^edge=//p')" "$WANTEDGE"
    boo "one hairline of it, not a card edge" \
        "$(printf '%s' "$GEOM" | sed -n 's/^edgethin=//p')" "1"
done
# The size knob is a TEST's question, never the window's answer, and it can be
# handed back: `probeResize 0 0` releases it, and so does any real resize of the
# window (the window clears both axes on its own width/height change). That is
# what keeps a run of layout probes from leaving the app drawing into a box
# smaller than its window -- the dead band under the status bar that looked like
# a layout bug.
cw probeResize 900 300 >/dev/null; sleep 0.5
boo "a pinned content size is exactly what the probe asked for" \
    "$(cw probeLayout | json '["height"]')" "300"
cw probeResize 0 0 >/dev/null; sleep 0.6
# 300 is smaller than any window this file can produce (the app's own floor is
# higher), so "grew past the pin" is the assertion that a release happened.
boo "and releasing it hands the window's own height back" \
    "$([ "$(cw probeLayout | json '["height"]')" -gt 300 ] && echo yes || echo no)" "yes"
cw probePreviewPane 0 >/dev/null; cw probeResize 1080 720 >/dev/null; sleep 0.5

# ── the quiet header: path, NAME, then the words ────────────────────────
# The order is the design (the "Quiet lock" study: kicker -> huge -> cmdrow),
# and the three complaints it answered are all geometry or type: the name was
# a size too big, it sat glued to the path box, and the commands were a bar
# ABOVE it instead of a row under it. Each is asserted here in the numbers the
# header is drawn with, so a later layout change cannot quietly undo them.
echo "── the quiet header: path, name, then the command words ─────────────"
start_window_if_needed || exit 1
QH="$(cw probeQuietHeader)"
boo "the folder's name is drawn above the command words" \
    "$(echo "$QH" | json '["commandsUnderTitle"]')" "True"
boo "and the two bands do not overlap" \
    "$([ "$(echo "$QH" | json '["commandTop"]')" -ge "$(echo "$QH" | json '["titleBottom"]')" ] && echo yes || echo no)" "yes"
boo "the name is 38 px, in the light weight" \
    "$(echo "$QH" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(str(d["titlePx"]) + "/" + str(d["titleWeight"]))')" "38/300"
boo "and it is tracked tight, as the lock screen sets its clock" \
    "$(echo "$QH" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("yes" if d["titleTracking"] < 0 and d["titleTracking"] > -3 else "no")')" "yes"
boo "the actions are still words, and New still leads them" \
    "$(echo "$QH" | python3 -c 'import json,sys;c=json.load(sys.stdin)["commands"];print("yes" if c and c[0]["label"] == "New" and c[0]["primary"] else "no")')" "yes"
# Changed WITH the behaviour (2026-10-17, chosen from the file-selection
# study): the outline that ran across the pane edge is now a grey wash plus a
# 2 px rail, inset into the row past the 8 px lane the left scrollbar owns.
boo "a selected row is a wash with a rail, not an outline" \
    "$(echo "$QH" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("/".join(str(d[k]) for k in ("selectionStyle","selectionBorder","selectionRail","selectionLane")))')" \
    "rail/0/2/8"

# ── the path box: two clicks in one box, decided by what is under them ──
# The hit test goes through the same lookup Qt uses to route a click
# (childAt), so it answers "if I clicked here, who would get it?" with no
# pointer: a click on a folder name has to reach the crumb, which walks there;
# a click anywhere else has to reach the box, which opens the path to copy.
echo "── the path box: a crumb navigates, the rest edits ──────────────────"
start_window_if_needed || exit 1
cw probeGo "$SCRATCH" >/dev/null; sleep 1.2
HIT="$(cw probeCrumbHit)"
boo "every crumb that is drawn would take the click" \
    "$(printf '%s' "$HIT" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("yes" if d["shown"]>0 and all(c["hit"]=="crumb" and c["navigates"] for c in d["crumbs"]) else "no")')" "yes"
boo "and the empty part of the box opens the path instead" \
    "$(printf '%s' "$HIT" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("yes" if d["empty"]["opensEditor"] else "no")')" "yes"
cw probePathEdit >/dev/null; sleep 0.6
boo "asking for the editor puts the path in it" \
    "$(cw probeLayout | json '["editingPath"]')" "True"
cw probePathDone >/dev/null; sleep 0.4

# ── the fast half of hotplug ────────────────────────────────────────────
# "It shows up instantly" cannot be timed from here -- nothing can plug a stick
# in from a script -- but the part that MAKES it instant can be: the app is
# reading the kernel's own hotplug socket and acting on what comes off it. A
# watcher that is running and forwarding nothing reads as alive in every other
# way, which is why the count is asserted and not just the state.
boo "the app reads the kernel's hotplug socket, not only a poll" \
    "$(cw probeState | json '["hotplug"]' | grep -cE '^on/[0-9]+/[0-9]+$')" "1"

# ── picker contract ─────────────────────────────────────────────────────
echo "── picker contract: double-click selects, the button answers ────────"
picker_file_contract() {
    rm -f "$PORTAL/$TOKEN.result.json"
    ensure || return 1
    c probeGo "$SCRATCH" >/dev/null; sleep 1.2
    ROW="$(c probeList 20 | python3 -c 'import json,sys;print([i["name"] for i in json.load(sys.stdin)].index("zeta.bin"))' 2>/dev/null)"
    [ -n "$ROW" ] || return 1
    c probeActivate "$ROW" >/dev/null; sleep 1
    [ "$(path)" = "$SCRATCH" ] || return 1
    [ "$(state | json '["selection"][0]')" = "$SCRATCH/zeta.bin" ] || return 1
    c probePickerConfirm >/dev/null
    sleep 1.2
    return 0
}
GOOD=0
for attempt in 1 2 3; do
    if picker_file_contract; then GOOD=1; break; fi
    echo "  ..    retrying the picker file contract (attempt $attempt)"
    P="$(find_pid "$TOKEN")"; [ -n "$P" ] && kill "$P" 2>/dev/null; sleep 1
done
boo "double-click selected (no navigation) and Open answered" "$GOOD" "1"
RES="$(cat "$PORTAL/$TOKEN.result.json" 2>/dev/null)"
has "the answer carries the selected file URI" "$RES" "file://$SCRATCH/zeta.bin"
has "and is not a cancel" "$RES" '"cancelled":false'

echo "── picker contract: a folder is chosen with the button ──────────────"
TOKEN="fmsuite2"
start_picker "$TOKEN" open true || exit 1
sleep 2.5
c probeGo "$SCRATCH/subdir" >/dev/null; sleep 1.2
c probePickerConfirm >/dev/null; sleep 1.2
RES="$(cat "$PORTAL/$TOKEN.result.json" 2>/dev/null)"
has "Select folder answered with the folder being looked at" "$RES" "file://$SCRATCH/subdir"

# ── double-click inside a dialog: a folder is a door, not an answer ─────
# REQUESTED 2026-10-13: "open folders with double click also ... in the add
# folder or file file manager version". A FILE still only selects -- answering
# a question nobody has asked would be wrong -- but a folder is the way through
# the tree, and a dialog that made you hunt for a breadcrumb to enter the
# folder you had just double-clicked was the thing to fix. Entering the folder
# answers it too: the folder being looked at is what Select hands over.
echo "── picker contract: double-click enters a folder ────────────────────"
TOKEN="fmsuite5"
# The answer of a PREVIOUS run is still sitting in the portal directory, and
# "nothing was answered yet" cannot be asked of a file that is already there.
rm -f "$PORTAL/$TOKEN.result.json"
start_picker "$TOKEN" open true || exit 1
sleep 2.5
c probeGo "$SCRATCH" >/dev/null; sleep 1.2
LIST="$(c probeList 20)"
has "the listing offers the folder to double-click" "$LIST" '"subdir"'
ROW="$(printf '%s' "$LIST" | python3 -c 'import json,sys;print([i["name"] for i in json.load(sys.stdin)].index("subdir"))' 2>/dev/null)"
# Out of range on purpose if the row could not be found: the activate call then
# does nothing and the next assertion fails with the real reason on screen.
[ -n "$ROW" ] || ROW=99
c probeActivate "$ROW" >/dev/null; sleep 1.2
boo "double-click on a folder walks into it" "$(path)" "$SCRATCH/subdir"
boo "and it is an entry, not an answer: nothing was answered yet" \
    "$([ ! -f "$PORTAL/$TOKEN.result.json" ] && echo yes)" "yes"
c probePickerConfirm >/dev/null; sleep 1.2
RES="$(cat "$PORTAL/$TOKEN.result.json" 2>/dev/null)"
has "the folder walked into is the one Select hands over" "$RES" "file://$SCRATCH/subdir"
boo "and the dialog answered rather than cancelled" \
    "$(printf '%s' "$RES" | json '["cancelled"]')" "False"

echo "── picker contract: save mode returns the typed name ────────────────"
TOKEN="fmsuite3"
start_picker "$TOKEN" save false || exit 1
sleep 2.5
c probeGo "$SCRATCH" >/dev/null; sleep 1.2
c probePickerName "written-here.txt" >/dev/null; sleep 0.5
# ── The save prompt is TWO boxes ──────────────────────────────────────
# The name and the type, with the type a LABEL until it is double-clicked.
# All of that is readable and drivable over IPC (probeSavePrompt /
# probeSaveExtOpen) -- which is the only way to check it here, because a
# synthetic pointer cannot click a layer surface on this box.
SAVE="$(c probeSavePrompt)"
boo "the suggested name arrives with its type split off" \
    "$(printf '%s' "$SAVE" | json '["stem"]')" "written-here"
boo "the type sits in a box of its own" "$(printf '%s' "$SAVE" | json '["ext"]')" "txt"
boo "and it is a label at rest, not a field" \
    "$(printf '%s' "$SAVE" | json '["editing"]')" "False"
boo "labelled with the default type" "$(printf '%s' "$SAVE" | json '["label"]')" ".txt"
# ── The name box: one word at rest, wider as it is typed, then scrolling ──
c probeSaveStem "ab" >/dev/null
SAVE="$(c probeSavePrompt)"
boo "a short name leaves the box one word wide" \
    "$(printf '%s' "$SAVE" | json '["nameWidth"]')" "$(printf '%s' "$SAVE" | json '["nameMin"]')"
boo "and the type's box sits against its right edge" \
    "$(printf '%s' "$SAVE" | json '["extX"]')" \
    "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["nameX"] + d["nameWidth"] + 10)' "$SAVE")"
c probeSaveStem "a name long enough to run the name box out of room on a bar the width of this dialog, which is what has to happen before it starts scrolling" >/dev/null
SAVE="$(c probeSavePrompt)"
boo "a long name grows the box past one word" \
    "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["nameWidth"] > d["nameMin"])' "$SAVE")" "True"
boo "until the bar runs out, and then the text scrolls inside it" \
    "$(printf '%s' "$SAVE" | json '["overflow"]')" "True"
c probeSaveStem "written-here" >/dev/null
c probeSaveExtOpen >/dev/null; sleep 0.3
boo "a double click opens it as a field" \
    "$(c probeSavePrompt | json '["editing"]')" "True"
c probeSaveExt "" >/dev/null
boo "emptied, the type is dropped instead of left as a dot" \
    "$(c probeSavePrompt | json '["composed"]')" "written-here"
c probeSaveExt "md" >/dev/null
boo "the floating label keeps the DEFAULT type, not the typed one" \
    "$(c probeSavePrompt | json '["label"]')" ".txt"
c probeSaveExtClose >/dev/null
boo "closing the box keeps what was typed" \
    "$(c probeSavePrompt | json '["composed"]')" "written-here.md"
c probePickerConfirm >/dev/null; sleep 1.2
RES="$(cat "$PORTAL/$TOKEN.result.json" 2>/dev/null)"
has "Save answered with the folder + the composed name" "$RES" "file://$SCRATCH/written-here.md"

echo "── permanent delete (on a file this suite created) ──────────────────"
TOKEN="fmsuite4"
printf 'delete me\n' > "$SCRATCH/bye.txt"
start_picker "$TOKEN" open false || exit 1
sleep 2.5
c probeGo "$SCRATCH" >/dev/null; sleep 1.2
c probeHardDelete "bye.txt" >/dev/null
# Asked until it is true, rather than once after a fixed wait. The app runs its
# shell commands through ONE serialized queue -- the folder-size scans above are
# in it too -- so the rm can sit behind a few seconds of `du`, and a 1.5s sleep
# reads a deletion that is merely late as a deletion that never happened. (It
# did happen: the file was gone by the end of the run that failed here.) 10s,
# then the claim is made about the file itself, which cannot lie.
for _ in $(seq 1 40); do
    [ ! -f "$SCRATCH/bye.txt" ] && break
    sleep 0.25
done
boo "the file is gone" "$([ ! -f "$SCRATCH/bye.txt" ] && echo yes)" "yes"

# ── insertion notices (the shell's Volumes service) ─────────────────────
# The one part of this that is not the app: a device arriving or leaving is
# announced by the session, not by a window, so the check is aimed at the
# shell's own `volumes` target. There is no way to plug something in from a
# script, so the device is removed from the service's census and the next poll
# fires the ordinary "inserted" path for it -- the same code a real stick
# takes, notice and all.
echo "── insertion notices (shell: services/Volumes.qml) ──────────────────"
VSTATE="$(qs -c ii ipc call volumes state 2>/dev/null || true)"
if [ -z "$VSTATE" ]; then
    echo "  ..    the shell's volumes target is not answering (no qs -c ii running?)"
else
    has "the shell is watching removable media" "$VSTATE" "primed=true"
    DEV="$(printf '%s' "$VSTATE" | sed -n 's/.*devices=\([^ ]*\).*/\1/p' | tr ',' '\n' | grep ':disk:' | head -1)"
    if [ -z "$DEV" ]; then
        echo "  ..    no external disk is plugged in; plug one in and rerun for the notice"
    else
        DEV="${DEV%%:*}"
        CHIMED_BEFORE="$(printf '%s' "$VSTATE" | sed -n 's/.*chimed=\([0-9]*\).*/\1/p')"
        qs -c ii ipc call volumes forget "$DEV" >/dev/null
        qs -c ii ipc call volumes poll >/dev/null
        sleep 2.5
        VSTATE="$(qs -c ii ipc call volumes state)"
        has "an arriving drive is announced" "$VSTATE" "inserted"
        has "and the notice names it" "$VSTATE" "last=\""
        # The click is the reason this part exists, and it is the one thing
        # about a sound a terminal cannot hear. What it CAN see is that the
        # announcement asked for it: `chimed` counts the sounds the mixer row
        # let through, so it rises by exactly one per device event.
        CHIMED_AFTER="$(printf '%s' "$VSTATE" | sed -n 's/.*chimed=\([0-9]*\).*/\1/p')"
        boo "and the insertion asked for the device click" "$((CHIMED_AFTER - CHIMED_BEFORE))" "1"
        # The other half: a planted device that is not there is a removal.
        CHIMED_BEFORE="$CHIMED_AFTER"
        qs -c ii ipc call volumes phantom /dev/fmcheck usb FMCARD 8000000000 >/dev/null
        qs -c ii ipc call volumes poll >/dev/null
        sleep 2.5
        VSTATE="$(qs -c ii ipc call volumes state)"
        has "a leaving drive is announced" "$VSTATE" "removed"
        CHIMED_AFTER="$(printf '%s' "$VSTATE" | sed -n 's/.*chimed=\([0-9]*\).*/\1/p')"
        boo "and it asked for its own sound, not the insert one twice" \
            "$((CHIMED_AFTER - CHIMED_BEFORE))" "1"
    fi
fi

# ── the same notice for the things that are NOT drives ──────────────────
# A phone, a pad, a camera: no /dev node, so lsblk can never see them and the
# census above answers "nothing is plugged in" about a device on the end of a
# cable. This is the second census (sysfs, scripts/system/usb-devices.sh), and
# the case that found it was on this machine -- a Samsung on bus 1 that the
# session was silent about.
#
# Same limit, same workaround as the drives above: there is no way to unplug a
# phone from a script, so the device is dropped from the census and the next
# scan reports it inserted -- the real notice, the real click, the real popup.
echo "── the devices that are not drives (shell: scripts/system/usb-devices.sh) ──"
VSTATE="$(qs -c ii ipc call volumes state 2>/dev/null || true)"
if [ -z "$VSTATE" ]; then
    # The shell itself, asked once. "Is anything in the census" is a different
    # question and is asked below, because the first cut of this section read an
    # empty device list as "the shell is not answering" -- so a run with nothing
    # plugged in reported a dead shell, and the one claim that can ALWAYS be
    # checked (that the census is being taken at all) was the claim that got
    # skipped.
    echo "  ..    the shell's volumes target is not answering (no qs -c ii running?)"
else
    has "the shell is watching the USB ports, not only the drives" "$VSTATE" "usbPrimed=true"
fi
USBROW="$(printf '%s' "$VSTATE" | sed -n 's/.* usb=\([^ ]*\).*/\1/p' | tr ',' '\n' | grep ':' | head -1)"
if [ -z "$USBROW" ]; then
    echo "  ..    nothing pluggable is on a port; plug a phone or a stick in and rerun"
else
    USBNAME="${USBROW%%:*}"
    USBPRODUCT="${USBROW##*:}"
    NOTICED_BEFORE="$(printf '%s' "$VSTATE" | sed -n 's/.*noticed=\([0-9]*\).*/\1/p')"
    qs -c ii ipc call volumes usbForget "$USBNAME" >/dev/null
    qs -c ii ipc call volumes usbScan >/dev/null
    sleep 2
    VSTATE="$(qs -c ii ipc call volumes state)"
    has "a device with no drive in it is announced" "$VSTATE" "inserted"
    has "and the notice names the thing that was plugged in ($USBPRODUCT)" \
        "$VSTATE" "$USBPRODUCT"
    NOTICED_AFTER="$(printf '%s' "$VSTATE" | sed -n 's/.*noticed=\([0-9]*\).*/\1/p')"
    boo "and it asked for the click, the same click a drive gets" \
        "$((NOTICED_AFTER - NOTICED_BEFORE))" "1"
    # And the other direction: a device that is not in the port any more. Planted
    # rather than unplugged, because the cable is not a script's to pull.
    CHIMED_BEFORE="$(printf '%s' "$VSTATE" | sed -n 's/.*chimed=\([0-9]*\).*/\1/p')"
    qs -c ii ipc call volumes usbPhantom /dev/fmcheck-phone phone FMPHONE >/dev/null
    qs -c ii ipc call volumes usbScan >/dev/null
    sleep 2
    VSTATE="$(qs -c ii ipc call volumes state)"
    has "a device leaving a port is announced" "$VSTATE" "removed"
    has "and that notice names it too" "$VSTATE" "FMPHONE"
    CHIMED_AFTER="$(printf '%s' "$VSTATE" | sed -n 's/.*chimed=\([0-9]*\).*/\1/p')"
    boo "and unplugging gets its own sound, not the insert one twice" \
        "$((CHIMED_AFTER - CHIMED_BEFORE))" "1"
fi

# ── what those sounds ARE ───────────────────────────────────────────────
# The pair is no longer synthesised here. It is cut from a recording supplied
# by whoever runs this desktop (scripts/system/import-device-sound.py), and
# that recording is NOT in the repository -- so unlike the rest of the assets,
# these two cannot be regenerated from nothing. What is asserted below is
# therefore the shape the pair has to keep, not where it came from:
#
#   same length     one recording, cut once: the remove is the insert reversed
#   exact reversal  byte for byte, which is measured rather than assumed --
#                   it is what makes "unplugging is the same gesture backwards"
#                   a fact about the files instead of a comment about them
#   200 ms          the click plus a quarter second of its own decay. The
#                   recording's tail runs on for ~500 ms at -30 dB and below;
#                   keeping all of it made a device event sound like a hallway
#   -1 dBFS peak    REQUESTED 2026-10-11: the click has to be heard, and heard
#                   ABOVE the music playing at the same moment. It was -6, and
#                   200 ms of transient at -6 sits under continuous music at
#                   the same mixer setting -- which is what "sometimes it makes
#                   no sound" turned out to mean. -1 leaves 1 dB of headroom
#                   for the resampler and reads over the music and the chimes.
#                   This is the sample's CEILING, and REQUESTED again on
#                   2026-10-14 ("slightly louder than now so it's over the
#                   music") is therefore not a change to this file: with the
#                   attack here, the remaining 170 ms of decay and a crest
#                   factor of 23.6 dB, a louder click can only come from how it
#                   is PLAYED -- see the level section below
#   no clipping     a raw clipped edge is what makes a short sound harsh
echo "── the device click (shell: services/Volumes.qml, assets/sounds) ────"
SOUNDDIR="$HOME/.config/quickshell/ii/assets/sounds"
boo "the insert sound is shipped" "$([ -s "$SOUNDDIR/device-insert.wav" ] && echo yes)" "yes"
boo "the remove sound is shipped" "$([ -s "$SOUNDDIR/device-remove.wav" ] && echo yes)" "yes"
SOUNDSTATS="$(python3 -c "
import array, wave


def load(name):
    with wave.open('$SOUNDDIR/' + name) as w:
        sr, n = w.getframerate(), w.getnframes()
        x = array.array('h'); x.frombytes(w.readframes(n))
    return sr, n, x


sr, n, ins = load('device-insert.wav')
_, _, rem = load('device-remove.wav')

peak = max(abs(v) for v in ins) or 1
attack = next(i for i, v in enumerate(ins) if abs(v) >= 0.9 * peak) / sr * 1000.0
win = int(0.020 * sr)
zc = sum(1 for i in range(1, win) if (ins[i] >= 0) != (ins[i - 1] >= 0)) / (win / sr)
dur = 1000.0 * n / sr
clipped = sum(1 for v in ins + rem if abs(v) >= 32767)
# A click: short, an attack you can find in the first 25 ms, and far brighter
# than the 1700/s notification drop it stands in for.
verdict = 'click' if dur < 350 and attack < 25 and zc > 3000 else 'NOT-A-CLICK'
print('insert dur=%.0fms peak=%.1fdBFS attack=%.1fms zcr=%.0f/s clipped=%d verdict=%s'
      % (dur, 20 * __import__('math').log10(peak / 32768.0), attack, zc, clipped, verdict))
print('pair same-length=%s reversed=%s'
      % ('yes' if len(ins) == len(rem) else 'no',
         'yes' if list(rem) == list(reversed(ins)) else 'no'))
" 2>/dev/null)"
boo "the insert sound is a click: short, bright, with a findable attack (the drop was 311 ms at 1700/s)" \
    "$(printf '%s' "$SOUNDSTATS" | grep -c '^insert .*verdict=click$')" "1"
boo "the remove sound is the insert played backwards, sample for sample" \
    "$(printf '%s' "$SOUNDSTATS" | grep -c 'reversed=yes')" "1"
boo "and both halves are the same length, being one cut of one recording" \
    "$(printf '%s' "$SOUNDSTATS" | grep -c 'same-length=yes')" "1"
has "the insert sound is 200 ms (the click plus a quarter second of its decay)" \
    "$SOUNDSTATS" "insert dur=200ms"
has "and it plays at -1 dBFS, so a drive going in is heard over the music" \
    "$SOUNDSTATS" "peak=-1.0dBFS"
boo "neither half clips" "$(printf '%s' "$SOUNDSTATS" | grep -c 'clipped=0')" "1"

# ── the level a system sound actually plays at ──────────────────────────
# A chime's level is the System Sounds row, and ONLY the row. The sink the sound
# lands on already applies its own volume to every stream it mixes, exactly as
# it does for music -- so folding it in here as well applied it TWICE.
#
# That was the bug behind "sometimes plugging a drive in makes no sound".
# Measured 2026-10-11, sink at 30% (this shell's 15%): a music stream carries
# volume 1.0 and is heard at the sink's 30%, while the device click was spawned
# at `--volume 0.151` -- 16 dB under the music, and ~22 dB once the click
# sample's own headroom is counted. The click was a whisper at every desktop
# volume, and quieter the lower the desktop went.
#
# The number is not guessed at here. The shell prints it, and the factor that
# produced it, on the line it writes as the player is handed the level -- so the
# identity is checkable from the log instead of from ears. A build that went
# back to folding the overall in would print the old shape, and the regex below
# would find nothing to match, which is the failure this exists to catch.
echo "── what a chime plays at (shell: services/Audio.qml) ─────────────────"
QSLOG="/tmp/ii_shell.log"
if [ ! -s "$QSLOG" ]; then
    echo "  ..    no shell log at $QSLOG; run a device event first"
else
    LEVEL="$(python3 -c "
import re

PAT = re.compile(r'at ([0-9.]+) \\(row ([0-9.]+) x ([0-9.]+), sink applies its own\\)')
last = ''
device = ''
for l in open('$QSLOG', errors='replace'):
    if '[mixer] preview playing' not in l:
        continue
    last = l
    if 'device-insert.wav' in l or 'device-remove.wav' in l:
        device = l
m = PAT.search(last)
if not m:
    print('no level line with a factor in the log')
else:
    level, row, gain = float(m.group(1)), float(m.group(2)), float(m.group(3))
    ok = abs(level - round(row * gain, 3)) < 0.0015
    print('level=%.3f row=%.3f gain=%.3f matches=%s'
          % (level, row, gain, 'yes' if ok else 'no'))
d = PAT.search(device)
if not d:
    print('no device-click level line in the log')
else:
    dlevel, drow, dgain = float(d.group(1)), float(d.group(2)), float(d.group(3))
    dok = abs(dlevel - round(drow * dgain, 3)) < 0.0015
    print('device level=%.3f row=%.3f gain=%.3f boosted=%s matches=%s'
          % (dlevel, drow, dgain, 'yes' if dgain > 1.0 else 'no',
             'yes' if dok else 'no'))
" 2>/dev/null)"
    # Anchored, and that is the whole of the correction that was needed here: an
    # unanchored 'level=' counts the `device level=...` line as well, so both of
    # these checks read 2 and failed while the behaviour they describe was
    # exactly right. A count of a substring is not a count of a fact.
    boo "the log shows the level and the factors that made it" \
        "$(printf '%s' "$LEVEL" | grep -c '^level=')" "1"
    boo "and a system sound plays at the row (times its own gain), the sink applying its own as it does for music" \
        "$(printf '%s' "$LEVEL" | grep -c '^level=.*matches=yes')" "1"
    boo "the device click was asked for at all" \
        "$(printf '%s' "$LEVEL" | grep -c 'device level=')" "1"
    # REQUESTED 2026-10-14: louder than it was, so it is heard over music. The
    # SAMPLE cannot be raised any further -- its attack is already at -1 dBFS,
    # measured above -- so the boost is a playback factor, and this is where
    # that claim is checked rather than asserted in a comment: the click plays
    # ABOVE the row, while a chime (the same code, no gain) plays at it.
    has "and it plays above the row, so a transient is not lost under music" \
        "$LEVEL" "gain=1.500 boosted=yes"
fi


# ── a folder's size: walked once, cached, and never on a redraw ─────────
#
# A folder's Size cell is a tree walk. The three things being checked are the
# three that make that acceptable rather than a disk being thrashed: the number
# is right (against `du`, computed here, not typed in), a redraw costs nothing
# (the walker's own counter does not move when the rows are rebuilt), and at
# most ONE `du` ever runs at a time. The last one is sampled, because "one at a
# time" is a claim about processes and not about code.
echo "── folder sizes: one walk per folder, cached, one at a time ──────────"
start_window_if_needed || exit 1
rm -rf "$SCRATCH/sizebig" "$SCRATCH/sizesmall" "$SCRATCH/sizeempty" "$SCRATCH/sizenope"
mkdir -p "$SCRATCH/sizebig" "$SCRATCH/sizesmall" "$SCRATCH/sizeempty" "$SCRATCH/sizenope/deeper"
head -c 3145728 /dev/zero > "$SCRATCH/sizebig/blob.bin"
head -c 1024 /dev/zero > "$SCRATCH/sizesmall/tiny.bin"
head -c 2048 /dev/zero > "$SCRATCH/sizenope/deeper/inner.bin"
chmod 000 "$SCRATCH/sizenope"
cw probeGo "$SCRATCH" >/dev/null; sleep 1
# By Size, biggest first: this is the column whose order has to be the numbers
# it draws, and it is also what forces a full rebuild of every row below.
cw probeSort 3 1 >/dev/null; sleep 3
SZ="$(cw probeSizes)"
WANT_BIG="$(timeout 25 du -s -x --apparent-size -B1 -- "$SCRATCH/sizebig" 2>/dev/null | cut -f1)"
WANT_SMALL="$(timeout 25 du -s -x --apparent-size -B1 -- "$SCRATCH/sizesmall" 2>/dev/null | cut -f1)"
sznum() { printf '%s' "$SZ" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(next((r['$2'] for r in d['rows'] if r['name']=='$1'), '-'))" 2>/dev/null; }
boo "a folder's size is the whole tree, byte for byte (du says $WANT_BIG)" \
    "$(sznum sizebig bytes)" "$WANT_BIG"
boo "and the column draws it as a size, not as nothing" \
    "$([ -n "$(sznum sizebig shown)" ] && echo shown)" "shown"
boo "a small folder too (du says $WANT_SMALL)" "$(sznum sizesmall bytes)" "$WANT_SMALL"
# An empty folder MEASURES 0. That is an answer, and the column is right to draw
# nothing for it -- but it must not leave the cell saying "measuring" forever.
boo "an empty folder measures 0 bytes" "$(sznum sizeempty bytes)" "0"
boo "and is drawn as nothing, not as 0 B and not as still-measuring" \
    "$(sznum sizeempty shown)" ""
# A folder the user cannot read is not an empty folder: the cell stays empty and
# the walker calls it a failure. (Assumes the suite is not run as root, like the
# polkit checks below.)
boo "an unreadable folder is not reported as 0 bytes" "$(sznum sizenope bytes)" "-1"
boo "and is recorded as a failed walk" "$(sznum sizenope note)" "error"
# The order the column draws is the order it sorts by: 3 MB, then 1 KB, then 0.
boo "biggest first: the column's order is the sizes it draws" \
    "$(printf '%s' "$SZ" | python3 -c "
import json,sys
rows=[r['name'] for r in json.load(sys.stdin)['rows'] if r['name'] in ('sizebig','sizesmall','sizeempty')]
print(','.join(rows))" 2>/dev/null)" "sizebig,sizesmall,sizeempty"
boo "nothing is left queued or running once the rows on screen are measured" \
    "$(printf '%s' "$SZ" | python3 -c "
import json,sys
w=json.load(sys.stdin)['walker']
print('%d/%s' % (w['queued'], 'busy' if w['active'] else 'idle'))" 2>/dev/null)" "0/idle"
# THE CLAIM THE DESIGN RESTS ON. Re-sorting rebuilds every row, every row asks
# again, and the walker must not move a byte -- this is what makes the cell free
# to draw on a scroll, a hover and a redraw.
#
# Asked and answered-from-cache are read separately on purpose: "the walker did
# not move" on its own would also be true of a row that never asked, which is a
# broken feature wearing the same evidence.
BEFORE="$(qs ipc --pid "$(find_pid)" call folderSizes state)"
cw probeSort 3 0 >/dev/null; sleep 2
AFTER="$(qs ipc --pid "$(find_pid)" call folderSizes state)"
boo "re-drawing the rows asks for their sizes again" \
    "$([ "$(printf '%s' "$AFTER" | json '["hits"]')" -gt "$(printf '%s' "$BEFORE" | json '["hits"]')" ] && echo asked || echo "no ($(printf '%s' "$BEFORE" | json '["hits"]') -> $(printf '%s' "$AFTER" | json '["hits"]'))")" "asked"
boo "and every one of those asks is answered from the cache" \
    "$(printf '%s' "$BEFORE" | json '["measured"]')/$(printf '%s' "$AFTER" | json '["measured"]')" \
    "$(printf '%s' "$BEFORE" | json '["measured"]')/$(printf '%s' "$BEFORE" | json '["measured"]')"
# FRESHNESS. A cached number is only good while the folder behind it is the same
# folder: add a megabyte inside one of them, re-read the listing (which is what
# the toolbar's Refresh does), and the row has to move. Without this the column
# would be right once and wrong for the rest of the session.
head -c 1048576 /dev/zero > "$SCRATCH/sizebig/added.bin"
cw probeGo "$HOME" >/dev/null; sleep 0.8
cw probeGo "$SCRATCH" >/dev/null; sleep 3
WANT_AGAIN="$(timeout 25 du -s -x --apparent-size -B1 -- "$SCRATCH/sizebig" 2>/dev/null | cut -f1)"
SZ="$(cw probeSizes)"
boo "a folder that changed inside is measured again on the next re-read (du now says $WANT_AGAIN)" \
    "$(sznum sizebig bytes)" "$WANT_AGAIN"
# ...and the walks themselves are serial. A cold burst is forced (the cache is
# dropped, then the rows are rebuilt to ask again) and the process table is
# sampled through it. The claim is a CEILING, not a sighting: these walks finish
# in single-digit milliseconds, so demanding to see one would fail whenever the
# sampler was unlucky (it did, first time round). What has to hold is that walks
# HAPPENED while we watched and that two were never up at once.
BEFORE_DU="$(qs ipc --pid "$(find_pid)" call folderSizes state | json '["measured"]')"
qs ipc --pid "$(find_pid)" call folderSizes clear >/dev/null
cw probeSort 3 1 >/dev/null
MAXDU=0
for _ in $(seq 1 80); do
    NDU="$(ps -eo comm= | grep -c '^du$')"
    [ "$NDU" -gt "$MAXDU" ] && MAXDU="$NDU"
    sleep 0.02
done
AFTER_DU="$(qs ipc --pid "$(find_pid)" call folderSizes state | json '["measured"]')"
boo "the cold burst really did walk folders while we watched" \
    "$([ "$AFTER_DU" -gt "$BEFORE_DU" ] && echo walked || echo "no ($BEFORE_DU -> $AFTER_DU)")" "walked"
boo "and never two du at once, however many rows ask" \
    "$([ "$MAXDU" -le 1 ] && echo ok || echo "$MAXDU concurrent")" "ok"
sleep 3
boo "and the queue always drains back to nothing" \
    "$(qs ipc --pid "$(find_pid)" call folderSizes state | json '["queued"]')" "0"
chmod 755 "$SCRATCH/sizenope" 2>/dev/null

for t in fmsuite1 fmsuite2 fmsuite3 fmsuite4 fmwatch1 fmwatch2; do
    P="$(find_pid "$t")"; [ -n "$P" ] && kill "$P" 2>/dev/null
done

echo "─────────────────────────────────────────────────────────────────────"
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
