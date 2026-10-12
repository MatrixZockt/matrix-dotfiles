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
SCRATCH="$HOME/fm-scratch-test"
PORTAL="${XDG_RUNTIME_DIR:-/tmp}/ii-portal"
LOG=/tmp/fm-suite.log
PASS=0
FAIL=0

find_pid() {
    local token="${1:-}"
    for pid in $(pgrep -x qs); do
        tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -Eq "^qs -p ($QML|$QML_PICKER) $" || continue
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
    # A real one-second video, for the media-facts path (no frame grabbing --
    # there is no video thumbnailer on this desktop, and the pane says so by
    # showing facts instead of a picture).
    if command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -v error -f lavfi -i testsrc=size=64x64:rate=5 -t 1 -pix_fmt yuv420p \
            "$SCRATCH/clip.mp4" -y 2>/dev/null
        [ -f "$SCRATCH/clip.mp4" ] && VISIBLE_COUNT=$((VISIBLE_COUNT + 1))
    fi
    [ -f "$SCRATCH/manual.pdf" ] && VISIBLE_COUNT=$((VISIBLE_COUNT + 1))
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
sleep 1.5
# ── The window form ────────────────────────────────────────────────────
# "Always opens attached instead of fullscreen" is a claim about what kind of
# surface it is: the compositor can only tile, focus, fullscreen and close a
# real toplevel. So the compositor itself is asked, not the QML.
CLIENTS="$(timeout 10 hyprctl clients -j 2>/dev/null)"
has "Files is a real desktop window the compositor knows" "$CLIENTS" '"title": "Files"'
boo "and it is attached (tiled), not floating" \
    "$(printf '%s' "$CLIENTS" | python3 -c 'import json,sys;d=json.load(sys.stdin);w=[c for c in d if c.get("title")=="Files"];print("yes" if w and not w[0].get("floating") else "no")' 2>/dev/null)" "yes"
boo "and no files layer surface is left behind" \
    "$(timeout 10 hyprctl layers 2>/dev/null | grep -a -c 'quickshell:files')" "0"

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
    c probePreviewSelect "clip.mp4" >/dev/null; sleep 2.5
    P="$(c probePreview)"
    boo "a video is previewed as its facts, not a fake frame" "$(echo "$P" | json '["kind"]')" "video"
    has "and the facts include the picture size" "$P" "64×64"
else
    echo "  ..    ffmpeg is not installed: the media-preview rows are skipped"
fi

c probePreviewSelect "zeta.bin" >/dev/null; sleep 1.5
P="$(c probePreview)"
boo "an unknown file gets no invented preview" "$(echo "$P" | json '["kind"]')" ""
has "it is told in words instead" "$P" "No preview for this kind of file"

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
STATE="$(c probeState)"
has "the app is still alive after previewing a broken image" "$STATE" '"path":'
c probeView details >/dev/null; sleep 0.5
c probePreviewPane 0 >/dev/null; sleep 0.5
boo "the pane closes again" "$(c probePreview | json '["pane"]')" "False"

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
c menuAt 10 10 "" >/dev/null; sleep 0.5
c menuRun 0 >/dev/null; sleep 2
boo "new folder exists on disk" "$([ -d "$SCRATCH/New folder" ] && echo yes)" "yes"
ensure
boo "it is selected" "$(state | json '["selection"][0]')" "$SCRATCH/New folder"
boo "and the rename dialog opened on it" "$(state | json '["renaming"]')" "True"
c probeRenameCommit "renamed-folder" >/dev/null; sleep 1.5
boo "rename landed on disk" "$([ -d "$SCRATCH/renamed-folder" ] && echo yes)" "yes"
boo "and the listing shows it" "$(c probeList 6 | json '[0]["name"]')" "renamed-folder"

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
has "the USB stick is listed" "$V" "USBSTICK"
has "the Windows SSD is listed" "$V" "SSD-475GB"
has "its filesystem is reported" "$V" '"fstype":"exfat"'
has "partitions are listed, not just disks" "$V" '"name":"sda1"'
has "a mounted volume carries its free space" "$V" '"avail"'

# ── what KIND of drive each row is ──────────────────────────────────────
# The row's icon is picked from how the device is attached (usb / mmc / nvme)
# and whether the medium spins (rota), not from its name. The assertions below
# are the ones a name-based guess would fail.
has "the stick is typed as USB" "$V" '"kind":"usb"'
has "with the USB icon" "$V" '"icon":"usb"'
has "the system disk is typed as an SSD" "$V" '"kind":"ssd"'
has "with the SSD icon" "$V" '"icon":"hard_drive"'
has "rows name the disk they belong to" "$V" '"disk":"/dev/sda"'
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
cw probePreviewPane 0 >/dev/null; cw probeResize 1080 720 >/dev/null; sleep 0.5

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

echo "── picker contract: save mode returns the typed name ────────────────"
TOKEN="fmsuite3"
start_picker "$TOKEN" save false || exit 1
sleep 2.5
c probeGo "$SCRATCH" >/dev/null; sleep 1.2
c probePickerName "written-here.txt" >/dev/null; sleep 0.5
c probePickerConfirm >/dev/null; sleep 1.2
RES="$(cat "$PORTAL/$TOKEN.result.json" 2>/dev/null)"
has "Save answered with the folder + the name" "$RES" "file://$SCRATCH/written-here.txt"

echo "── permanent delete (on a file this suite created) ──────────────────"
TOKEN="fmsuite4"
printf 'delete me\n' > "$SCRATCH/bye.txt"
start_picker "$TOKEN" open false || exit 1
sleep 2.5
c probeGo "$SCRATCH" >/dev/null; sleep 1.2
c probeHardDelete "bye.txt" >/dev/null; sleep 1.5
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
#                   for the resampler and reads over the music and the chimes
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
line = ''
for l in open('$QSLOG', errors='replace'):
    if '[mixer] preview playing' in l:
        line = l
m = re.search(r'at ([0-9.]+) .row ([0-9.]+), sink applies its own.', line)
if not m:
    print('no level line with a factor in the log')
else:
    level, row = float(m.group(1)), float(m.group(2))
    ok = abs(level - round(row, 3)) < 0.0015
    print('level=%.3f row=%.3f matches=%s'
          % (level, row, 'yes' if ok else 'no'))
" 2>/dev/null)"
    boo "the log shows the level and the row that made it" \
        "$(printf '%s' "$LEVEL" | grep -c 'level=')" "1"
    boo "and the level IS the row, the sink applying its own volume as it does for music" \
        "$(printf '%s' "$LEVEL" | grep -c 'matches=yes')" "1"
fi


for t in fmsuite1 fmsuite2 fmsuite3 fmsuite4 fmwatch1 fmwatch2; do
    P="$(find_pid "$t")"; [ -n "$P" ] && kill "$P" 2>/dev/null
done

echo "─────────────────────────────────────────────────────────────────────"
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
