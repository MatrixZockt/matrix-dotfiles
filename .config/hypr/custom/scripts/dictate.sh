#!/usr/bin/env bash
#
# Push-to-talk dictation: hold a key, speak, let go -- the words are typed at
# the cursor of whatever has focus.
#
# The Linux stand-in for Wispr Flow. Nothing leaves the machine, there is no
# account and no API key: audio is recorded with PipeWire, transcribed by
# whisper.cpp built locally (see ~/.local/share/ii-dictate), and pasted at the
# cursor in one piece. The Ctrl+V itself is synthesised on a uinput device
# (ydotool), so EVERY client sees it -- native Wayland and XWayland alike;
# typing text still goes through wtype's virtual keyboard, which follows the
# keyboard layout (ydotool's `type` sends raw keycodes and writes QWERTZ as
# QWERTY). See the note above paste_shortcut for why the two are split.
#
#   dictate.sh start      begin recording (ignored if already recording)
#   dictate.sh stop       stop, transcribe, type the text
#   dictate.sh toggle     one key, press to start / press again to stop
#   dictate.sh status     what it thinks it is doing
#   dictate.sh finish RAW.pcm
#                         transcribe and type an already-captured raw stream
#                         (this is what the SUPER watcher calls)
#   dictate.sh transcribe FILE
#                         skip the microphone: transcribe a WAV and PRINT it
#                         (nothing is typed) -- this is the test path
#
# The gesture is HOLD SUPER ALONE, and it is not a Hyprland bind: binds on
# SUPER fire for chords too (ignore_mods matches SUPER+Q) and this build's Lua
# bind ignores `long_press`, so a bind would record through every SUPER
# shortcut. custom/scripts/dictate-daemon.py watches the keyboards itself and
# arms only for SUPER held alone -- any other key cancels. Fn cannot be used at
# all: no input device in /proc/bus/input/devices advertises KEY_FN.
#
# These subcommands remain for manual use and for the test harness; nothing
# binds them.
#
# Settings live in ~/.config/ii-dictate.conf, all optional:
#
#   MODEL=ggml-small.bin       model file inside ~/.local/share/ii-dictate/models
#   LANGUAGE=auto              whisper language code, or "auto" to detect it
#                              (German and English both work out of the box: the
#                              multilingual model is the default now, because an
#                              .en model CANNOT speak any other language --
#                              whisper-server overrides `-l auto` back to English
#                              on those, so "auto" silently did nothing)
#   THREADS=16                 transcription threads
#   MIN_SECONDS=0.4            shorter holds are treated as a mis-tap and dropped
#   MIC=                       PipeWire source name; empty = the default source
#   TYPE_CMD=auto              how the text reaches the cursor: "paste" (clipboard
#                              + Ctrl+V, appears all at once), "wtype" (types it
#                              character by character), "wl-copy" (only copy)
#   KEEP_AUDIO=0               keep the last recording next to the log
#   SAVE_HISTORY=0             append every transcript to the history file
#   SHOW_TRANSCRIPT=1          hand the sentence to the shell's transcript card,
#                              which shows it with a Copy button for ~20s and
#                              then deletes it (the only rescue for a dictation
#                              that never reached a text box)
#   SAVE_AUDIO=0               keep a copy of the audio each transcript came from
#                              (both off = nothing is kept: the audio lives only
#                              in the runtime dir for the length of a dictation,
#                              and any older history is purged at the next one)
#
set -uo pipefail

DATA="$HOME/.local/share/ii-dictate"
STATE="${XDG_RUNTIME_DIR:-/tmp}/ii-dictate"
LOG="$STATE/dictate.log"
RAW="$STATE/last.pcm"
WAV="$STATE/last.wav"
PIDFILE="$STATE/recording.pid"
# What whisper said the audio was, for the bar to show while it works. Written
# by transcribe() below, read by dictate-daemon.py (which folds it into
# status.json), and deleted when the next hold begins.
LANG_FILE="$STATE/language.json"

MODEL="${MODEL:-ggml-small.bin}"
LANGUAGE="${LANGUAGE:-auto}"
# whisper reports the detected language by NAME ("german"), the bar wants the
# tag ("DE"). This is whisper.cpp's own table (src/whisper.cpp, g_lang), copied
# once so the script does not depend on that source tree still being there.
LANG_CODES="english:en chinese:zh german:de spanish:es russian:ru korean:ko french:fr japanese:ja portuguese:pt turkish:tr polish:pl catalan:ca dutch:nl arabic:ar swedish:sv italian:it indonesian:id hindi:hi finnish:fi vietnamese:vi hebrew:he ukrainian:uk greek:el malay:ms czech:cs romanian:ro danish:da hungarian:hu tamil:ta norwegian:no thai:th urdu:ur croatian:hr bulgarian:bg lithuanian:lt latin:la maori:mi malayalam:ml welsh:cy slovak:sk telugu:te persian:fa latvian:lv bengali:bn serbian:sr azerbaijani:az slovenian:sl kannada:kn estonian:et macedonian:mk breton:br basque:eu icelandic:is armenian:hy nepali:ne mongolian:mn bosnian:bs kazakh:kk albanian:sq swahili:sw galician:gl marathi:mr punjabi:pa sinhala:si khmer:km shona:sn yoruba:yo somali:so afrikaans:af occitan:oc georgian:ka belarusian:be tajik:tg sindhi:sd gujarati:gu amharic:am yiddish:yi lao:lo uzbek:uz faroese:fo haitian:ht pashto:ps turkmen:tk nynorsk:nn maltese:mt sanskrit:sa luxembourgish:lb myanmar:my tibetan:bo tagalog:tl malagasy:mg assamese:as tatar:tt hawaiian:haw lingala:ln hausa:ha bashkir:ba javanese:jw sundanese:su cantonese:yue"
THREADS="${THREADS:-16}"
MIN_SECONDS="${MIN_SECONDS:-0.4}"
MIC="${MIC:-}"
DICTATE_PORT="${DICTATE_PORT:-8917}"
TYPE_CMD="${TYPE_CMD:-auto}"
KEEP_AUDIO="${KEEP_AUDIO:-0}"
SAVE_HISTORY="${SAVE_HISTORY:-0}"
SAVE_AUDIO="${SAVE_AUDIO:-0}"
SHOW_TRANSCRIPT="${SHOW_TRANSCRIPT:-1}"
# Where a transcript WOULD be kept. History is off by default now: a dictation
# is typed at the cursor and then gone. Both files below are only written when
# SAVE_HISTORY=1 / SAVE_AUDIO=1 is set explicitly in ~/.config/ii-dictate.conf.
#
#   ~/.local/share/ii-dictate/history/transcripts.md
#   ~/.local/share/ii-dictate/history/audio/<date>_<time>.wav
HISTORY="$DATA/history"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/ii-dictate.conf"
[ -r "$CONFIG" ] && . "$CONFIG"

mkdir -p "$STATE"

# The daemon is a systemd user service now, so it can come up before the
# compositor has exported WAYLAND_DISPLAY into the manager environment -- and
# every dictation inherits whatever environment the daemon was born with.
# Without the socket name wl-copy and wtype have nowhere to connect and the
# words are transcribed but silently never typed, which is the worst way for
# this to fail. If the inherited name is missing or dead, take a live socket.
if [ -z "${WAYLAND_DISPLAY:-}" ] || { [ "${WAYLAND_DISPLAY#/}" = "$WAYLAND_DISPLAY" ] && [ ! -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$WAYLAND_DISPLAY" ]; }; then
    for sock in "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/wayland-[0-9]; do
        [ -S "$sock" ] || continue
        export WAYLAND_DISPLAY="${sock##*/}"
        break
    done
fi

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >> "$LOG"; }

# Publish the language a piece of audio was recognised in. Atomic, like every
# other file the shell reads (write a temp file, rename over it): the bar polls
# this four times a second while a dictation is live, and a half-written file
# would be a parse error rather than a language.
write_language() {
    local code="${1:-}"
    [ -n "$code" ] || return 0
    printf '{"lang": "%s", "ts": %s}\n' "$code" "$(date +%s)" > "$LANG_FILE.tmp" \
        && mv -f "$LANG_FILE.tmp" "$LANG_FILE"
}

# Paste, don't type.
#
# wtype sends one key event per character. That is fine for a word and wrong for
# a sentence: 90 characters land over ~0.5s, and the receiving app redraws as it
# goes, so the text visibly "arrives in pieces" -- a bit, then a bit more. A
# dictation should appear the way a pasted line appears: whole.
#
# The clipboard is borrowed, not taken: whatever was there is put back after the
# paste lands. Terminals are the exception the shortcut table needs -- they paste
# with Ctrl+Shift+V -- and they are recognised by the class Hyprland reports for
# the focused window, because the script has no other way to know where the
# cursor is.
# The class of the window with the keyboard focus, lowercased. Used only to
# decide HOW to deliver the text: a terminal does not paste on Ctrl+V.
focused_class() {
    hyprctl activewindow -j 2>/dev/null \
        | tr ',' '\n' | sed -n 's/.*"class": *"\([^"]*\)".*/\1/p' | head -1 | tr '[:upper:]' '[:lower:]'
}

# ── The paste shortcut ───────────────────────────────────────────────────────
# Two ways to press Ctrl+V exist on this desktop and only one of them works
# everywhere:
#
#   ydotool  writes to a uinput device, so the compositor sees a real keyboard
#            and forwards the keys to whatever has focus -- Wayland AND XWayland
#            clients alike. Measured in a forced-X11 test window: the paste
#            landed, and so did a plain uinput click-through of the shortcut.
#   wtype    speaks zwp_virtual_keyboard, which Hyprland does not forward to
#            XWayland. Measured in the same window: Ctrl+V and typed characters
#            both vanished without an error, because wtype exits 0 whether or
#            not anybody listened. That is the "it goes to null" report: an
#            X11 (XWayland) desktop app -- TradingView is one on this machine --
#            never received a single key from dictation, while native Wayland
#            apps did.
#
# So ydotool goes first and wtype is the fallback (a desktop without ydotoold,
# or a daemon that died). Typing CHARACTERS still goes through wtype: ydotool
# sends raw keycodes and this keyboard is "de", so its `type` writes QWERTZ as
# QWERTY -- but a fixed keycode shortcut like Ctrl+V is layout-independent.
KEY_CTRL=29
KEY_SHIFT=42   # KEY_LEFTSHIFT
KEY_V=47       # KEY_V

# A live daemon, not just a binary: ydotool without ydotoold fails, and the
# socket is the only cheap proof that the device is still there.
ydotool_ready() {
    command -v ydotool >/dev/null 2>&1 || return 1
    local sock="${YDOTOOL_SOCKET:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/.ydotool_socket}"
    [ -S "$sock" ]
}

# ── Waiting for SUPER ───────────────────────────────────────────────────────
# The sentence goes in as a chord (Ctrl+V) or as typed characters, and this
# desktop binds CTRL + SUPER + V to the volume mixer. Deliver while SUPER is
# already down for the NEXT sentence and the mixer opens instead of pasting, and
# the daemon used to stop the new recording over it -- "it leaves the button as
# if I had stopped pressing it". So nothing is injected while SUPER is held.
# Bounded: a last look at dictating.sh's clock is never worth losing a sentence,
# so after ten seconds it delivers anyway.
wait_for_super() {
    local file="$STATE/super" waited=0
    [ -e "$file" ] || return 0          # older daemon, nothing to wait for
    while [ "$(cat "$file" 2>/dev/null)" = "down" ]; do
        [ "$waited" -ge 200 ] && break  # 200 x 50ms
        sleep 0.05
        waited=$((waited + 1))
    done
    [ "$waited" -ge 200 ] && say "SUPER still held after 10s, delivering anyway"
    return 0
}

# $1 = "shift" for Ctrl+Shift+V (terminals paste with that, not Ctrl+V).
paste_shortcut() {
    local mod="${1:-}"
    if ydotool_ready; then
        if [ "$mod" = shift ]; then
            ydotool key "$KEY_CTRL:1" "$KEY_SHIFT:1" "$KEY_V:1" "$KEY_V:0" \
                "$KEY_SHIFT:0" "$KEY_CTRL:0" 2>/dev/null && return 0
        elif ydotool key "$KEY_CTRL:1" "$KEY_V:1" "$KEY_V:0" "$KEY_CTRL:0" 2>/dev/null; then
            return 0
        fi
    fi
    if [ "$mod" = shift ]; then
        wtype -M ctrl -M shift -k v -m shift -m ctrl 2>/dev/null
    else
        wtype -M ctrl -k v -m ctrl 2>/dev/null
    fi
}

# True when the focused window is an X11 client (XWayland). One hyprctl call,
# shared by the delivery decision below.
focused_is_xwayland() {
    hyprctl activewindow -j 2>/dev/null | tr ',' '\n' \
        | grep -q '"xwayland":[[:space:]]*true'
}

paste_text() {
    PASTE_FAIL=""
    command -v wl-copy >/dev/null && command -v wl-paste >/dev/null \
        || { PASTE_FAIL="wl-copy/wl-paste missing"; return 1; }
    # Whatever is on the clipboard is saved and put back, whether it is text, an
    # image or a copied file: only the first advertised type is kept, which is
    # the one an app pasting it would read, and it goes to a private file in the
    # runtime dir that is deleted again below.
    #
    # Refusing a clipboard that was not text used to be the rule here, and every
    # dictation made right after copying a screenshot went down the typing path
    # instead -- the sentence arriving as individual key presses in whatever
    # window had focus. In a browser with no input box those letters are
    # shortcuts (d, f, t ...), so a dictation aimed at the wrong window opened
    # menus and fired keybinds instead of typing. Ctrl+V into that same window
    # does nothing at all, and an image is no longer a reason to type.
    #
    # The password-manager hint is not a content type and is filtered out first:
    # the dictation clipboard deliberately carries it (see the --sensitive copy
    # below) and counting it as "not text" made the NEXT dictation give up too.
    #
    # ONLY TEXT IS BORROWED. A non-text clipboard -- the screenshot Print puts
    # there, a copied file -- is left alone in both directions: it is not saved
    # and, crucially, NOT PUT BACK. Restoring it was the bug: `wl-copy` of the
    # old image ran 0.35s after Ctrl+V, so an app that had not read the selection
    # yet pasted the IMAGE instead of the sentence, and even when the paste was
    # fine the restore copied the image over the transcription, leaving the
    # thing that had just been dictated nowhere on the clipboard at all.
    # The sentence stays there instead (advertised secret, so cliphist skips it),
    # which is also the one copy a rescued dictation may need.
    local types prev_type prev_file want_restore=0
    types="$(wl-paste --list-types 2>/dev/null | grep -vi 'x-kde-passwordManagerHint')"
    prev_type="$(printf '%s' "$types" | head -n1)"
    prev_file="$STATE/clipboard-backup"
    rm -f "$prev_file"
    case "${prev_type%%;*}" in
        text/*|UTF8_STRING|TEXT|STRING) want_restore=1 ;;
    esac
    if [ "$want_restore" = 1 ] && command -v wl-paste >/dev/null && [ -n "$prev_type" ]; then
        # -n, or the backup grows a newline wl-paste appends that was never in
        # the copy: the restored text came back with a blank line after it, and
        # a restored image carried a stray 0x0A on the end.
        wl-paste -n -t "$prev_type" > "$prev_file" 2>/dev/null || rm -f "$prev_file"
    fi
    # Ask the shell not to announce this clipboard change (nor the restore). It
    # watches the selection to show its little "Copied" card, and two of those
    # for a sentence nobody copied is noise. Best effort: no shell, no matter.
    # Bounded on purpose. `qs ipc call` waits for a socket that a wedged
    # shell never answers; unbounded, this one call held the whole finish
    # (and the pill) open for 120 s until the daemon killed it, on
    # 2026-11-14. Three seconds is the same order as the call's own work,
    # and losing the quiet window only costs a "Copied" card.
    timeout 3 qs -c ii ipc call cliphistService quietFor 2500 >/dev/null 2>&1 || true
    # --sensitive makes the copy advertise x-kde-passwordManagerHint=secret, which
    # cliphist honours by NOT storing it. Without this a dictation is typed into
    # the cursor and then quietly kept forever in the clipboard history database.
    # The types are unchanged for anyone pasting it, so Ctrl+V still sees text.
    # -t text/plain is not decoration: without it wl-copy sniffs the data and
    # can advertise application/octet-stream, and the next dictation then saw a
    # "non-text" clipboard and gave up on pasting.
    printf '%s' "$1" | wl-copy --sensitive -t text/plain 2>/dev/null \
        || { PASTE_FAIL="wl-copy refused the text"; return 1; }
    sleep 0.05
    paste_shortcut "${2:-}" || { PASTE_FAIL="no Ctrl+V (ydotoold down and wtype missing?)"; return 1; }
    # Long enough for the paste to be read by the app -- Electron apps take a
    # tick longer than a plain GTK one -- but short enough that the clipboard is
    # not visibly ours.
    sleep 0.35
    # Put a borrowed TEXT clipboard back with the type it came with. Anything
    # that was not text was never borrowed, so nothing is written here and the
    # sentence survives on the clipboard (see the note above).
    if [ "$want_restore" = 1 ] && [ -s "$prev_file" ]; then
        wl-copy -t "$prev_type" < "$prev_file" 2>/dev/null
    fi
    rm -f "$prev_file"
    return 0
}

# Where the focused window is, for the before/after screenshots below.
window_geometry() {
    hyprctl activewindow -j 2>/dev/null | python3 -c '
import json, sys
try:
    w = json.load(sys.stdin)
    x, y = w["at"]
    ww, hh = w["size"]
except Exception:
    raise SystemExit(1)
if ww < 200 or hh < 120:
    raise SystemExit(1)
print("%d,%d %dx%d" % (x, y, ww, hh))
' 2>/dev/null
}

# Only the BOTTOM of the window is ever compared -- that is where a prompt box
# lives -- so only the bottom is captured. This is not a detail: a grim of the
# whole 1695x1010 window costs ~400ms, a grim of its bottom fifth ~75ms, and two
# of them happen before the sentence is pasted. Capturing the whole window was
# most of the delay between letting go of SUPER and the words appearing.
# The band is the prompt box itself, not the strip above it: chat apps draw
# banners, ads and "new message" pills there, and a banner arriving looks like a
# wide band of text -- which is what the check is looking for. 16% of the window
# is the composer on every app on this desktop.
WINDOW_BAND_PERCENT=16
# The WHOLE window, not just its bottom band. The band is where a chat composer
# lives and is checked first (see paste-landed.py), but a dictation can land in
# an address bar or a search field high up, and a frame that only holds the band
# can never show that -- which is how a landed sentence ended up raising a card.
# PPM on purpose: a full window compresses to PNG in ~350ms, while PPM is written
# in ~60ms and these frames are read once and deleted.
grab_window() {   # $1 = ppm path, $2 = geometry (optional, looked up if absent)
    local geo="${2:-}"
    [ -n "$geo" ] || geo="$(window_geometry)" || return 1
    grim -t ppm -g "$geo" "$1" 2>/dev/null || return 1
    [ -s "$1" ]
}

# How much of the window's height is the band, as a fraction, so the detector
# and this script cannot disagree about where the composer is meant to be.
band_fraction() {   # $1 = geometry (x,y wxh)
    local gh="${1##*x}" band
    case "$gh" in ''|*[!0-9]*) echo "0.16"; return 0 ;; esac
    band=$(( gh * WINDOW_BAND_PERCENT / 100 ))
    [ "$band" -ge 120 ] || band=120
    [ "$band" -gt "$gh" ] && band=$gh
    awk -v b="$band" -v h="$gh" 'BEGIN { printf "%.4f", b / h }'
}

# Take a dictation back out of the clipboard history.
#
# `wl-copy --sensitive` sets x-kde-passwordManagerHint=secret and cliphist is
# supposed to honour it -- most of the time it does, but this was measured
# storing one anyway: it read the selection in the instant before the hint was
# advertised. The promise is that a dictation never ends up in the history, not
# that one flag asked nicely, so the entry is removed by value afterwards. Runs
# in the background, after cliphist has had time to write.
forget_cliphist() {
    local text="${1:-}"
    [ -n "${text//[[:space:]]/}" ] || return 0
    command -v cliphist >/dev/null 2>&1 || return 0
    TEXT="$text" python3 -c '
import os, subprocess

want = os.environ.get("TEXT", "").strip()
if not want:
    raise SystemExit(0)
# errors="replace": the history also holds images, and their bytes are not UTF-8
rows = subprocess.run(["cliphist", "list"], capture_output=True,
                      text=True, errors="replace").stdout.splitlines()
ids = [row.split("\t", 1)[0] for row in rows
       if "\t" in row and row.split("\t", 1)[1].strip() == want]
if ids:
    subprocess.run(["cliphist", "delete"], input="\n".join(ids) + "\n",
                   text=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
' >/dev/null 2>&1
    return 0
}

# Hand the sentence to the shell's transcript card.
#
# The card shows it for a few seconds with a Copy button, then deletes the file:
# a dictation still is not saved, it is merely reachable for long enough to
# rescue one that never landed in a text box. Atomic (write, then rename) because
# the shell reads the path four times a second, and 0600 because a runtime
# directory is shared with every other process of this user.
show_transcript() {
    [ "$SHOW_TRANSCRIPT" = "1" ] || return 0
    mkdir -p "$STATE" 2>/dev/null || return 0
    printf '%s' "$1" | python3 -c '
import json, os, sys, time

text = sys.stdin.read()
path = sys.argv[1]
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump({"text": text, "ts": time.time()}, f)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
' "$STATE/transcript.json" 2>/dev/null || true
    return 0
}

# One line per dictation, plus the audio it came from. Written AFTER the text is
# typed, because a sentence that never reached the cursor is not a dictation --
# and the audio is saved even then, so a miss can be listened back instead of
# guessed at.
save_history() {
    local text="$1" wav="$2" stamp
    # Nothing is kept unless asked for. When both switches are off this also
    # wipes anything an earlier version or an old config left behind, so the
    # promise "my dictations are not saved" stays true on disk, not just for
    # future dictations.
    if [ "$SAVE_HISTORY" != "1" ] && [ "$SAVE_AUDIO" != "1" ]; then
        [ -e "$HISTORY" ] && rm -rf "$HISTORY" 2>/dev/null
        return 0
    fi
    stamp="$(date +%Y-%m-%d_%H-%M-%S)"
    mkdir -p "$HISTORY/audio" 2>/dev/null || { say "no history dir $HISTORY"; return 0; }
    if [ "$SAVE_AUDIO" = "1" ] && [ -s "$wav" ]; then
        cp -f "$wav" "$HISTORY/audio/$stamp.wav" 2>/dev/null || say "could not save audio"
        # 200 clips is months of dictation at a few dozen a day, and it keeps a
        # runaway session from filling the disk while the user is asleep.
        ls -1t "$HISTORY/audio" 2>/dev/null | tail -n +201 | while read -r f; do
            rm -f "$HISTORY/audio/$f"
        done
    fi
    if [ "$SAVE_HISTORY" = "1" ]; then
        # An empty transcript is still a dictation that happened, and saying so
        # beats a silent gap in the file: with the audio beside it the user can
        # hear what whisper heard.
        local line="${text:-(nothing recognised)}"
        printf -- '- %s — %s\n' "$stamp" "$(printf '%s' "$line" | tr '\n' ' ')" \
            >> "$HISTORY/transcripts.md" || say "could not save transcript"
    fi
}

recorder_pid() {
    [ -f "$PIDFILE" ] || return 1
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
    printf '%s' "$pid"
}

start_recording() {
    # Holding the key repeats it, so "start" arrives many times per hold. Being
    # already recording is the normal state, not an error.
    if recorder_pid >/dev/null; then
        return 0
    fi
    rm -f "$WAV" "$RAW"
    # A card left over from a shell that was not running would otherwise be
    # shown as if it belonged to this dictation.
    rm -f "$STATE/transcript.json" 2>/dev/null
    # RAW PCM, not a WAV: the recorder is stopped with a signal, and a WAV
    # header written at the start then not patched describes less audio than
    # was actually captured -- whisper transcribes only what the header says.
    # Raw has no header to be wrong, and ffmpeg fixes that up below (20 ms).
    #
    # pw-record, not parec. parec is on PATH and appears to work -- it exits
    # quietly, writes nothing, and stderr stays empty -- which had dictation
    # transcribing silence. Measured here 2026-11-09: `parec --raw` from the
    # default source, from a named source and even from a null-sink monitor all
    # produced 0 bytes, while the same capture through pw-record produced
    # ~30 kB/s. pw-record also honours `--target <node name>` (checked with
    # `pactl list source-outputs`: target.object was the node asked for).
    #
    # `-` writes the stream to stdout, and with the output redirected to a file
    # there is no WAV header to go stale when the recorder is signalled.
    # ...and the name has to be resolved to a node id first: `--target <name>`
    # is accepted and ignored (see above), so a configured MIC would silently
    # record the default source. `pactl list short sources` gives the id.
    local args=(--rate 16000 --channels 1 --format s16 -) mic_id=""
    if [ -n "$MIC" ]; then
        if [[ "$MIC" =~ ^[0-9]+$ ]]; then
            mic_id="$MIC"
        else
            mic_id="$(pactl list short sources 2>/dev/null | awk -F'\t' -v n="$MIC" '$2 == n { print $1; exit }')"
            [ -n "$mic_id" ] || say "mic $MIC not found, using the default source"
        fi
    fi
    [ -n "$mic_id" ] && args+=(--target "$mic_id")
    say "record -> $RAW (mic ${MIC:-default})"
    setsid pw-record "${args[@]}" > "$RAW" 2>>"$LOG" &
    echo $! > "$PIDFILE"
}

# whisper is chatty on stderr and prints timestamps/brackets we do not want in
# a text field. This filters the transcript down to the one line that goes in.
clean_transcript() {
    tr '\n' ' ' \
        | sed -e 's/\[[^]]*\]//g' -e 's/([^)]*)//g' \
        | sed -e 's/  */ /g' -e 's/^ *//' -e 's/ *$//'
}

transcribe() { # transcribe <wav> -> prints the text
    local wav="$1" model="$DATA/models/$MODEL"
    # Warm server first: it already holds the model, so the words come back in
    # ~0.2s instead of the second or two a fresh whisper-cli spends loading the
    # weights -- see dictate-server.sh. It is loopback only. If it is not up
    # (still loading after login, crashed, no CUDA build) the one-shot CLI below
    # answers instead: slower, same words.
    # A file per call, not one shared transcript.txt: with chunked dictation a
    # piece being transcribed while the user is still talking can overlap the
    # tail of the NEXT dictation, and one would overwrite the other mid-read.
    local out reply
    out="$(mktemp "$STATE/transcript.XXXXXX")" || out="$STATE/transcript.txt"
    reply="$(mktemp "$STATE/reply.XXXXXX")" || reply="$STATE/reply.json"
    # The language goes WITH THE REQUEST, not only on the server's command line.
    # A server started before a language change (or by a hand-run `dictate-server.sh
    # start` with an older config) would otherwise keep answering in whatever
    # language it was born with -- and a stale `-l en` against the new multilingual
    # model means German is not "detected as English", it is FORCED to English and
    # comes back as nonsense no amount of retrying fixes. "auto" is a valid field
    # value (the server accepts it exactly like `-l auto`).
    #
    # verbose_json, not text: the same response also carries the language it
    # decided the audio was in, which is what the bar shows while it works.
    # response_format=text has the words and nothing else.
    if curl -s --max-time 300 -F "file=@$wav" -F response_format=verbose_json \
            -F temperature=0 -F "language=$LANGUAGE" \
            "http://127.0.0.1:${DICTATE_PORT}/inference" \
            -o "$reply" 2>/dev/null && [ -s "$reply" ]; then
        if TF_TEXT="$out" TF_LANG="$LANG_FILE" LANG_CODES="$LANG_CODES" \
                python3 - "$reply" <<'PY'
import json, os, sys, time

try:
    data = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(1)
if not isinstance(data, dict):
    raise SystemExit(1)
with open(os.environ["TF_TEXT"], "w") as f:
    f.write(data.get("text") or "")
# whisper names the language ("german"); the bar wants the tag ("de").
name = (data.get("detected_language") or "").strip().lower()
if name:
    codes = dict(p.split(":", 1) for p in os.environ.get("LANG_CODES", "").split() if ":" in p)
    lang = codes.get(name) or name[:2]
    path = os.environ["TF_LANG"]
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"lang": lang, "ts": round(time.time(), 3)}, f)
    os.replace(tmp, path)
PY
        then
            clean_transcript < "$out"
            rm -f "$out" "$reply"
            return 0
        fi
    fi
    rm -f "$out" "$reply"
    if [ ! -x "$DATA/whisper.cpp/build/bin/whisper-cli" ]; then
        say "no whisper-cli at $DATA/whisper.cpp/build/bin -- run the installer"
        return 1
    fi
    if [ ! -f "$model" ]; then
        say "no model at $model"
        return 1
    fi
    # No language for the bar on this path. whisper-cli only prints what it
    # detected when it is verbose, and the verbose output is exactly what -np
    # (below) keeps out of the log -- so the fallback types the words and says
    # nothing about which language they were in. It is the degraded path: it
    # only runs when the warm server is down.
    local lang_args=(-l "$LANGUAGE")
    [ "$LANGUAGE" = "auto" ] && lang_args=(-l auto)
    # -mc 0: no text context carried between segments. Each dictation is a
    # standalone recording, and a context window is what lets whisper continue a
    # sentence it never heard -- measured here, an empty hold came back as
    # "Thanks for being here.", borrowed from whatever it had decoded before.
    "$DATA/whisper.cpp/build/bin/whisper-cli" \
        -m "$model" -f "$wav" -nt -np -t "$THREADS" -mc 0 "${lang_args[@]}" 2>>"$LOG" \
        | clean_transcript
}

# Everything after the microphone: wrap, measure, transcribe, type. Shared by
# the key path (stop_recording) and by the SUPER watcher (dictate-daemon.py,
# which captures its own audio and calls `dictate.sh finish <raw>` -- one
# implementation of "turn a recording into words at the cursor", not two.
# finish_raw RAW [PARTS] [FULLRAW]
#
#   RAW       what is left to transcribe: the tail after the last chunk cut
#             (with the old one-shot path, the whole recording)
#   PARTS     optional file of words already transcribed WHILE the user was
#             talking -- one chunk per line, see dictate-daemon.py
#   FULLRAW   optional full capture, so the history's audio file is the whole
#             dictation and not just the tail
#
# The point of the split is the wait: whisper used to be handed the entire clip
# only after the key came up, so a long dictation took seconds (measured: 0.7s
# for 15s of audio, 2.9s for 240s). With the parts already done, the release
# only has a few seconds of tail left -- the wait no longer grows with length.
finish_raw() {
    local raw="$1" prefix="${2:-}" full="${3:-}" elapsed="" text="" pre="" dur method wav="$WAV"
    [ -s "$raw" ] || [ -s "$prefix" ] || { say "nothing to finish"; return 0; }

    if [ -s "$prefix" ]; then
        pre="$(tr '\n' ' ' <"$prefix" | sed -e 's/  */ /g' -e 's/^ *//' -e 's/ *$//')"
        say "reused $(wc -w <"$prefix") word(s) transcribed while recording"
    fi

    if [ -s "$raw" ]; then
        ffmpeg -hide_banner -loglevel error -y -f s16le -ar 16000 -ac 1 \
            -i "$raw" "$wav" >>"$LOG" 2>&1
    fi
    if [ ! -s "$wav" ] && [ -z "$pre" ]; then
        say "could not wrap the audio"
        return 0
    fi

    # A tap on the key records a few milliseconds of nothing. Transcribing that
    # gives whisper silence to hallucinate on ("Thank you."), so it is dropped.
    # LC_ALL=C on BOTH: this machine's numeric locale uses a comma, so `printf
    # '%.2f' 0.959063` is "invalid number", prints 0,00, and the `|| echo 0`
    # appends a second zero -- giving 0,000, i.e. every dictation shorter than a
    # second was measured as empty and dropped as "too short" while the audio
    # was perfectly fine. Two decimals of an English decimal, on purpose.
    if [ -s "$wav" ]; then
        dur="$(LC_ALL=C ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$wav" 2>/dev/null)"
        elapsed="$(LC_ALL=C printf '%.2f' "${dur:-0}" 2>/dev/null || echo 0)"
        say "recorded ${elapsed}s (tail)"
    fi

    local short_tail=0
    if [ -n "$elapsed" ] && awk -v d="$elapsed" -v m="$MIN_SECONDS" 'BEGIN { exit !(d + 0 < m + 0) }'; then
        short_tail=1
    fi
    if [ "$short_tail" = "1" ] && [ -z "$pre" ]; then
        say "too short, dropped"
        return 0
    fi

    # First picture of the landed check, taken NOW, in the background. Two
    # "before" pictures are needed (see paste-landed.py), and taking both after
    # the words came back put a visible pause between letting go of the key and
    # the sentence arriving. While whisper is working is free time.
    SHOT_BEFORE="$STATE/frame1.ppm"
    SHOT_PAIR="$STATE/frame2.ppm"
    SHOT_AFTER="$STATE/frame3.ppm"
    rm -f "$SHOT_BEFORE" "$SHOT_PAIR" "$SHOT_AFTER"
    WINDOW_GEO="$(window_geometry)" || WINDOW_GEO=""
    local shot_pid=""
    if [ -n "$WINDOW_GEO" ]; then
        grab_window "$SHOT_BEFORE" "$WINDOW_GEO" &
        shot_pid=$!
    fi

    if [ "$short_tail" = "0" ] && [ -s "$wav" ]; then
        local t0 t1
        t0="$(date +%s%N)"
        text="$(transcribe "$wav")"
        t1="$(date +%s%N)"
        # The words themselves are deliberately NOT logged: the log is the last
        # place a dictation could linger, and with history off this makes the
        # whole thing leave nothing behind anywhere.
        say "tail transcribed in $(( (t1 - t0) / 1000000 )) ms: ${#text} char(s)"
    fi
    if [ -n "$shot_pid" ]; then
        wait "$shot_pid" 2>/dev/null
        shot_pid=""
    fi

    # One transcript, in order: the chunks that were done while talking, then
    # whatever the tail had left.
    if [ -n "$pre" ] && [ -n "$text" ]; then
        text="$pre $text"
    elif [ -n "$pre" ]; then
        text="$pre"
    fi

    # Nothing came back. Two very different cases wear the same face here, and
    # the log has to tell them apart: the room was quiet (normal -- nothing is
    # typed, nothing is broken), or the INPUT is dead (a muted source, or the
    # wrong one -- this machine's default source was a digital mic array that
    # records nothing at all, and dictation looked simply broken). Measuring the
    # recording is the only way to know which.
    if [ -z "$text" ]; then
        local mean
        mean="$(ffmpeg -hide_banner -nostats -i "$wav" -af volumedetect -f null - 2>&1 \
            | sed -n 's/.*mean_volume: \([-0-9.]*\) dB.*/\1/p' | head -1)"
        say "no text; recording mean level ${mean:-?} dB"
        if [ -n "$mean" ] && awk -v m="$mean" 'BEGIN { exit !(m < -50) }'; then
            say "the microphone is recording SILENCE -- check the default input source"
        fi
        rm -f "$SHOT_BEFORE" "$SHOT_PAIR" "$SHOT_AFTER"
        save_history "" "$wav"
        # Same deal as the normal path further down: a dictation that produced
        # no words still leaves no audio behind.
        if [ "$KEEP_AUDIO" = "1" ]; then rm -f "$raw" "$full"; else rm -f "$wav" "$raw" "$full"; fi
        return 0
    fi

    # Trailing space so two dictations in a row do not run together.
    local out="$text "
    method="$TYPE_CMD"

    # The window can be focused with its prompt box NOT selected (a chat app you
    # just clicked on in the sidebar looks focused, but the caret is nowhere).
    # Nothing can be pasted there and the sentence would vanish. There is no
    # Wayland call that says "where is this app's text field", so ask the
    # accessibility tree, which does expose widgets, and give the app's main
    # input the caret when it does not have it. Apps that publish no tree say so
    # and leave the old behaviour alone; never let this block a dictation.
    local focus_hint
    focus_hint="$(timeout 2s python3 "$(dirname "$0")/dictate-focus.py" 2>/dev/null)"
    case "$focus_hint" in
        focused)
            say "focus: gave the app's input box the caret"
            sleep 0.15          # let the toolkit move the caret before typing
            ;;
        already)   say "focus: input box already selected" ;;
        no-entry)  say "focus: the app exposes no input box" ;;
        *)         say "focus: the app publishes no accessibility tree" ;;
    esac
    if [ "$method" = "auto" ]; then
        if command -v wl-copy >/dev/null && command -v wtype >/dev/null; then
            method=paste
        elif command -v wtype >/dev/null; then
            method=wtype
        elif command -v ydotool >/dev/null; then
            method=ydotool
        else
            method=wl-copy
        fi
    fi

    # Where is the caret? The class decides the terminal case; the xwayland flag
    # decides whether wtype can reach it at all (it cannot: see paste_shortcut).
    local cls term=0 xw=0
    cls="$(focused_class)"
    focused_is_xwayland && xw=1
    case "$cls" in
        *foot*|*kitty*|*alacritty*|*wezterm*|*ghostty*|*term*) term=1 ;;
    esac

    # Terminals paste with Ctrl+Shift+V and only some accept Ctrl+V, so a Wayland
    # terminal gets the typed route: character by character is slower, but it is
    # the one that works everywhere, and a silently missing sentence in a
    # terminal prompt is worse than one that takes half a second to appear. An
    # XWayland terminal is the exception -- wtype reaches nothing there, so it
    # gets the Ctrl+Shift+V paste instead.
    if [ "$method" = "paste" ] && [ "$term" = 1 ] && [ "$xw" = 0 ]; then
        method=wtype
    fi
    # Any other XWayland window: typed characters would vanish, so paste is the
    # only route that lands.
    if [ "$method" = "wtype" ] && [ "$xw" = 1 ]; then
        method=paste
    fi

    # What the delivery is aimed at, in one line. A report of "it typed into the
    # browser" needs to say WHICH window and WHICH route were picked, and neither
    # is visible anywhere afterwards. Class name only -- never the words.
    say "target: class='${cls:-?}' xwayland=$xw terminal=$term method=$method"

    # Terminals take Ctrl+Shift+V; every other window takes Ctrl+V.
    local paste_mod=""
    [ "$term" = 1 ] && paste_mod=shift

    # Two pictures of the window BEFORE the sentence is delivered, a moment
    # apart, and one after. Whatever differs inside the pair is the app moving
    # on its own (a streaming reply, a spinner, a blinking caret) and is ignored
    # by paste-landed.py; only a change that is present in neither of the two is
    # the text arriving. The wl-copy route pastes nothing, so there is nothing
    # to compare and the card is always shown then.
    # The second "before" picture, this one right before the text goes in: it is
    # what separates "the app is moving" from "the app got our sentence". Only
    # this one is on the critical path between the words being ready and the
    # words being typed -- the earlier one is already taken during transcription
    # -- and it is a crop of the window's bottom, which grim reads in ~80ms
    # instead of the ~400ms a full-window shot costs.

    # Nothing may be injected while SUPER is down (see wait_for_super). Before
    # the second picture, not after: the pair has to be taken moments before the
    # text, or the landed check compares against a window that has moved on.
    wait_for_super

    if [ "$method" != "wl-copy" ] && [ -s "$SHOT_BEFORE" ]; then
        [ -n "$WINDOW_GEO" ] || WINDOW_GEO="$(window_geometry)" || WINDOW_GEO=""
        grab_window "$SHOT_PAIR" "$WINDOW_GEO" || rm -f "$SHOT_BEFORE"
    fi

    case "$method" in
        paste)
            # A PASTE IS ONE CHORD. In a window with no text box it does nothing
            # at all, which is exactly what a dictation aimed at the wrong
            # window should do. Typing characters is not that: in a browser --
            # or any Electron app -- with no input focused, every letter is a
            # shortcut ('f' find, '/' quick-find, 't' new tab), so a sentence
            # that missed the prompt box fired keybinds across the page instead
            # of landing anywhere. The old fallback did that whenever the paste
            # failed, which is intermittent by nature (a clipboard owner going
            # away at the wrong moment, ydotoold restarting) and therefore
            # impossible to predict. There is no typing fallback here any more:
            # if the paste cannot be made, the sentence goes to the clipboard
            # (sensitive, so cliphist skips it) and to the transcript card,
            # which is the one path that cannot touch the keyboard at all.
            #
            # Tried twice first, because the usual failure is transient and a
            # second attempt is cheaper than a lost sentence.
            if ! paste_text "$out" "$paste_mod"; then
                sleep 0.15
                if ! paste_text "$out" "$paste_mod"; then
                    printf '%s' "$out" | wl-copy --sensitive -t text/plain 2>/dev/null
                    method="wl-copy (paste failed: ${PASTE_FAIL:-unknown})"
                fi
            fi ;;
        wtype)   printf '%s' "$out" | wtype - ;;
        ydotool) ydotool type -- "$out" ;;
        wl-copy) printf '%s' "$out" | wl-copy --sensitive -t text/plain ;;
        *)       "$method" "$out" ;;
    esac
    # Did it land? A wide band of *new* pixels in the bottom of the window -- the
    # shape of a line of text in a prompt box -- counts as delivered. See
    # paste-landed.py for why that is the shape, and what it ignores.
    local landed=0
    if [ -s "$SHOT_BEFORE" ] && [ -s "$SHOT_PAIR" ]; then
        local attempt=1 verdict=""
        while [ "$attempt" -le 3 ]; do
            sleep 0.2
            grab_window "$SHOT_AFTER" "$WINDOW_GEO" || break
            verdict="$(python3 "$(dirname "$0")/paste-landed.py" \
                "$SHOT_BEFORE" "$SHOT_PAIR" "$SHOT_AFTER" \
                "$(band_fraction "$WINDOW_GEO")" 2>/dev/null)"
            say "landed check (try $attempt): ${verdict:-no answer}"
            case "$verdict" in landed*) landed=1 ; break ;; esac
            # A grab can outrun the app's own paint, especially with a big
            # Electron window: the sentence is in the box but not on screen yet,
            # so a single early look reads as a miss and raises a card over a
            # sentence that is right there. Look again, up to three tries (~0.6s
            # of extra waiting in the case where it really did not land, which is
            # the cheap side of this trade).
            attempt=$(( attempt + 1 ))
        done
    fi
    rm -f "$SHOT_BEFORE" "$SHOT_PAIR" "$SHOT_AFTER"
    if [ "$landed" = "1" ]; then
        say "delivery landed in the focused window"
    else
        say "delivery did not land -- showing the transcript card"
        # The only copy of this sentence that exists: hand it to the card, which
        # keeps it reachable (and copyable) for a few seconds.
        show_transcript "$out"
    fi

    # The sentence went through the clipboard in these two routes; cliphist is
    # asked to skip sensitive copies, but is not trusted to (forget_cliphist).
    case "$method" in
        paste*|wl-copy*) ( sleep 0.9; forget_cliphist "$out" ) >/dev/null 2>&1 & ;;
    esac
    say "delivered with $method"
    # The audio kept beside the transcript is the WHOLE dictation: with chunking
    # on, `$wav` is only the tail, and a history clip of the last few seconds is
    # not what the transcript above it says.
    local hist_wav="$wav"
    if [ -s "$full" ]; then
        ffmpeg -hide_banner -loglevel error -y -f s16le -ar 16000 -ac 1 \
            -i "$full" "$STATE/history.wav" >>"$LOG" 2>&1
        [ -s "$STATE/history.wav" ] && hist_wav="$STATE/history.wav"
    fi
    save_history "$text" "$hist_wav"
    rm -f "$STATE/history.wav"
    if [ "$KEEP_AUDIO" = "1" ]; then rm -f "$raw" "$full"; else rm -f "$wav" "$raw" "$full"; fi
}

stop_recording() {
    local pid
    pid="$(recorder_pid)" || { say "stop with nothing recording"; return 0; }

    # SIGINT is what pw-record finalises on (it writes the WAV trailer), so the
    # recording is given a moment rather than being killed outright.
    kill -INT "$pid" 2>/dev/null
    for _ in $(seq 1 40); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.025
    done
    kill -9 "$pid" 2>/dev/null
    rm -f "$PIDFILE"
    sleep 0.03          # let PipeWire flush the last block

    finish_raw "$RAW"
}

case "${1:-}" in
    start)   start_recording ;;
    stop)    stop_recording ;;
    forget)  forget_cliphist "$(cat)" ;;
    toggle)
        if recorder_pid >/dev/null; then stop_recording; else start_recording; fi
        ;;
    status)
        if pid="$(recorder_pid)"; then
            echo "recording (pid $pid) -> $WAV"
        else
            echo "idle"
        fi
        ;;
    finish)
        [ -n "${2:-}" ] || { echo "usage: dictate.sh finish RAW.pcm [PARTS.txt] [FULL.pcm]" >&2; exit 2; }
        finish_raw "$2" "${3:-}" "${4:-}"
        ;;
    transcribe)
        [ -n "${2:-}" ] || { echo "usage: dictate.sh transcribe FILE.wav" >&2; exit 2; }
        transcribe "$2"
        ;;
    paste) # manual: deliver TEXT the way a finished dictation would, for testing
           # the delivery path without speaking into the microphone.
        [ -n "${2:-}" ] || { echo "usage: dictate.sh paste TEXT" >&2; exit 2; }
        if paste_text "$2"; then say "manual paste ok"; else
            say "manual paste failed: ${PASTE_FAIL:-unknown}"
            printf '%s' "$2" | wtype -
        fi
        ;;
    chunk) # one already-cut piece of a live dictation: words on stdout, nothing
           # else -- no paste, no history, no status. Called by the daemon while
           # the user is still speaking (see its chunking notes), which is why
           # it must stay silent: its stdout IS the answer.
        [ -n "${2:-}" ] || { echo "usage: dictate.sh chunk RAW.pcm" >&2; exit 2; }
        # The suffix has to be `.wav`: ffmpeg picks the container from the file
        # NAME, and `chunk.wav.12345` made it fail with "invalid argument" and
        # write nothing -- silently, since the failure went to the log. mktemp
        # gives a unique name (concurrent dictations) with the right extension.
        tmp="$(mktemp "$STATE/chunk-XXXXXX.wav")" || exit 1
        ffmpeg -hide_banner -loglevel error -y -f s16le -ar 16000 -ac 1 \
            -i "$2" "$tmp" >>"$LOG" 2>&1
        rc=0
        if [ -s "$tmp" ]; then transcribe "$tmp"; rc=$?; fi
        rm -f "$tmp"
        # The EXIT CODE is the daemon's signal, and it has to mean "no words
        # came back" rather than "there were no words to come back": a piece cut
        # between two sentences can legitimately transcribe to nothing, and
        # treating that as a failure would throw away every other piece and make
        # the release re-do the whole dictation. Only a request that FAILED is a
        # failure (see the daemon's `_work`).
        exit $rc
        ;;
    *)
        sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
