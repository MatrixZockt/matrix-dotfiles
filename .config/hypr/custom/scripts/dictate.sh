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
# Where the audio is SENT: the local whisper.cpp server, and nothing else. The
# Groq bridge that used to answer on a second port was removed on 2026-11-18,
# together with its key, so there is no cloud address left to send audio to even
# by mistake.
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

# Give the borrowed clipboard back, whatever it was before the dictation, and
# take the sentence off it. Called by the delivery step once the paste has
# landed, by the guard that outlives a delivery that died before it could, and
# by the manual `paste` subcommand.
#
# SAFE TO RUN TWICE. Two callers can reach this at the same moment (the
# delivery and its guard), and a second pass that found the backup already
# taken used to fall through to `wl-copy --clear` and EMPTY the clipboard it had
# just correctly restored. So the type file is written for every borrow --
# `empty` when there was nothing on the clipboard -- and only whoever finds it
# still there does the work and removes it. The lock makes the check atomic.
# Which advertised type is the PAYLOAD, i.e. the one an app pastes.
#
# Not "the first one", which is what this used to save. A clipboard is a list
# of flavours and several apps put a marker first: a file copy in Dolphin
# advertises `application/x-kde-cutselection` (a one-byte "0"/"1" saying
# whether it was a cut) BEFORE `text/uri-list`, and a browser copy can put
# `text/html` before `text/plain`. Saving the first type then put back the
# marker without the file list -- a copied video came back as nothing at all,
# which is exactly the report "my copied file is gone after a dictation".
#
# So: the picture, else the file list, else TEXT, and only then whatever is
# first that X11 is not using for protocol bookkeeping. One type is all wl-copy
# can own with one payload, and these are the ones that paste.
#
# THE PSEUDO-TARGETS ARE THE BUG (2026-11-19). An XWayland selection -- Discord,
# WhatsApp, any Electron app -- advertises TARGETS, MULTIPLE, TIMESTAMP and
# SAVE_TARGETS BEFORE the content. They are not content: TARGETS is the list of
# formats the owner supports. Saving it stored an atom list, putting it back put
# that atom list back, and the verify below compared TARGETS with TARGETS and
# called it a success -- so the clipboard was "restored" to something no app can
# paste. Reported as: copy text, dictate, then Ctrl+V pastes nothing and the text
# has to be pulled out of the clipboard history by hand.
clipboard_payload_type() {
    local types="${1:-}" t first=""
    local pseudo=" TARGETS MULTIPLE TIMESTAMP SAVE_TARGETS DELETE INSERT_SELECTION LOST_SELECTION "
    for t in image/png image/jpeg text/uri-list \
             text/plain 'text/plain;charset=utf-8' UTF8_STRING TEXT STRING text/html; do
        printf '%s\n' "$types" | grep -qxF -- "$t" && { printf '%s' "$t"; return 0; }
    done
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        case "$pseudo" in *" $t "*) continue ;; esac
        first="$t"
        break
    done <<< "$types"
    printf '%s' "$first"
}

# Is the payload that was borrowed actually back on the selection, byte for byte?
#
# The check used to compare the FIRST advertised type with the saved one, which
# says nothing about the data and is wrong in both directions: a restore of a
# pseudo-target looked successful while holding an atom list, and a clipboard
# manager or XWayland that advertises something else first made a correct restore
# look failed -- which then CLEARED the clipboard, the other way a copied sentence
# disappeared. Reading the payload back and comparing it is the question that
# matters: does Ctrl+V get the user's own text again?
clipboard_payload_intact() {   # $1 = type, $2 = backup file
    local type="$1" file="$2" probe="$STATE/clipboard-probe"
    rm -f "$probe"
    if wl-paste -n -t "$type" >"$probe" 2>/dev/null && cmp -s "$file" "$probe"; then
        rm -f "$probe"
        return 0
    fi
    rm -f "$probe"
    return 1
}

restore_clipboard() {
    local prev_file prev_type type_file borrowed=""
    prev_file="$STATE/clipboard-backup"
    type_file="$STATE/clipboard-backup.type"
    # What was said out loud, so a restore that fails can tell "the sentence is
    # still on the selection" (clear it) from "something else is on it" (leave
    # it alone -- clearing there destroys the user's own copy).
    [ -r "$STATE/clipboard-borrowed" ] && borrowed="$(cat "$STATE/clipboard-borrowed" 2>/dev/null)"
    if command -v flock >/dev/null 2>&1; then
        exec 8>"$STATE/restore.lock" 2>/dev/null || true
        flock -w 3 8 2>/dev/null || true
    fi
    prev_type="$(cat "$type_file" 2>/dev/null)"
    # Nothing recorded: no borrow in flight, or somebody else already put it
    # back. Leave the selection alone -- clearing here is how a race turned a
    # correct restore into an empty clipboard.
    [ -n "$prev_type" ] || { exec 8>&- 2>/dev/null; return 0; }
    rm -f "$type_file"
    if [ "$prev_type" = empty ] || [ ! -s "$prev_file" ]; then
        # `8>&-`: wl-copy forks a process that keeps owning the selection, and
        # a child holding this lock would make every later restore wait out its
        # full flock timeout before giving the clipboard back.
        wl-copy --clear 8>&- 9>&- 2>/dev/null || true
        say "clipboard restored (it was empty)"
    else
        wl-copy -t "$prev_type" < "$prev_file" 8>&- 9>&- 2>/dev/null
        # READ IT BACK. A restore that quietly fails leaves the SENTENCE on the
        # selection, and the next Ctrl+V anywhere pastes a dictation nobody
        # copied -- the one thing this whole borrow exists to prevent. wl-copy
        # can lose the selection to a competing owner or a display hiccup, so
        # the type it owns afterwards is checked, retried once, and if it still
        # will not take, the clipboard is CLEARED: an empty clipboard is a
        # missing paste, a stale sentence is a wrong one.
        local attempt=1 ok=0 on_clip=""
        while [ "$attempt" -le 2 ]; do
            sleep 0.05
            clipboard_payload_intact "$prev_type" "$prev_file" && { ok=1; break; }
            wl-copy -t "$prev_type" < "$prev_file" 8>&- 9>&- 2>/dev/null
            attempt=$(( attempt + 1 ))
        done
        if [ "$ok" = 1 ]; then
            say "clipboard restored ($prev_type, $(wc -c < "$prev_file") bytes)"
        else
            # Clearing is only right when the thing left behind is the SENTENCE.
            # Deciding that from the first advertised type is how a good restore
            # became an empty clipboard; ask what the text actually is.
            on_clip="$(wl-paste -n -t text/plain 2>/dev/null || true)"
            if [ -n "$borrowed" ] && [ "$on_clip" = "$borrowed" ]; then
                say "clipboard restore could not be verified for $prev_type and the sentence is still on the selection; clearing it"
                wl-copy --clear 8>&- 9>&- 2>/dev/null || true
            else
                say "clipboard restore could not be verified for $prev_type; leaving the selection alone"
            fi
        fi
    fi
    rm -f "$prev_file" "$STATE/clipboard-borrowed"
    PASTE_STAGED=0
    exec 8>&- 2>/dev/null
    return 0
}

# THE BORROW ALWAYS ENDS.
#
# The restore normally happens in the delivery's own housekeeping, a beat after
# the chord. That is also the one thing a crashed delivery, a hung screenshot,
# a killed process group or an unexpected early return can skip -- and then the
# sentence stays on the selection, so the next Ctrl+V anywhere pastes the last
# thing said out loud instead of what the user copied (reported 2026-11-18).
#
# So the borrow arms a guard the moment the chord goes out: a detached sleep
# that puts the clipboard back if, and only if, the same borrow is still there
# when it wakes. Both conditions matter -- a newer dictation's sentence, or a
# copy the user made in between, means this borrow is already over and the
# guard must do nothing. The guard is cheap (one wl-paste, one stat) and it is
# the difference between "the clipboard comes back" and "it usually does".
RESTORE_GUARD_SECONDS="${RESTORE_GUARD_SECONDS:-6}"
arm_restore_guard() {   # $1 = the sentence just put on the clipboard
    local backup="$STATE/clipboard-backup" type_file="$STATE/clipboard-backup.type"\
          ino sentence="${1:-}"
    [ "$RESTORE_GUARD_SECONDS" != "0" ] || return 0
    [ -f "$type_file" ] || return 0
    ino="$(stat -c %i "$backup" 2>/dev/null)"
    (   exec 9>&- 2>/dev/null
        sleep "$RESTORE_GUARD_SECONDS"
        [ -f "$type_file" ] || exit 0
        [ "$(stat -c %i "$backup" 2>/dev/null)" = "$ino" ] || exit 0
        [ "$(wl-paste -n -t text/plain 2>/dev/null)" = "$sentence" ] || exit 0
        restore_clipboard
    ) >/dev/null 2>&1 &
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
    # EVERY TYPE IS BORROWED AND PUT BACK, and nothing of ours is left behind.
    #
    # The dictation is pasted with Ctrl+V, which means the sentence has to sit
    # on the clipboard for a tick. What must NOT happen is that it stays there:
    # a dictation is not a copy, so the desktop's clipboard must read exactly
    # as it did before -- otherwise the next Ctrl+V anywhere pastes the last
    # thing said out loud, and cliphist (or a password manager's secret hint)
    # is handed text nobody copied. Reported 2026-11-14: "the transcription
    # copies itself; it should only copy when Copy is pressed on the card."
    #
    # The rule here used to be "only text is borrowed, a screenshot is left
    # alone", which is why the sentence survived on the clipboard after every
    # dictation made while an image was copied: nothing restored it because
    # nothing had been saved. That is the behaviour this replaces. The old
    # objection -- that writing the image back 0.35 s after Ctrl+V could make
    # an app paste the IMAGE instead of the sentence -- is answered by doing
    # the restore only after the paste has had its full window, and by
    # restoring the SAME type that was read, byte for byte, including the
    # `-n` that keeps wl-paste from appending a newline that was never there.
    #
    # An empty clipboard before means an empty clipboard after: `wl-copy
    # --clear`, rather than leaving the sentence as a "rescue copy". Rescuing
    # is the card's job, and the card has its own Copy button for exactly that.
    # The borrow is made ONCE per delivery. `paste_text` is retried by the
    # caller when the chord does not go out, and a second borrow would save our
    # own sentence over the user's clipboard -- the restore would then put the
    # sentence BACK instead of taking it off.
    local types prev_type prev_file
    prev_file="$STATE/clipboard-backup"
    if [ "${PASTE_STAGED:-0}" != 1 ]; then
        rm -f "$prev_file" "$STATE/clipboard-backup.type" "$STATE/clipboard-borrowed"
        types="$(wl-paste --list-types 2>/dev/null | grep -vi 'x-kde-passwordManagerHint')"
        prev_type="$(clipboard_payload_type "$types")"
        if command -v wl-paste >/dev/null && [ -n "$prev_type" ] \
                && wl-paste -n -t "$prev_type" > "$prev_file" 2>/dev/null; then
            printf '%s' "$prev_type" > "$STATE/clipboard-backup.type"
            printf '%s' "$1" > "$STATE/clipboard-borrowed" 2>/dev/null || true
            say "clipboard borrowed ($prev_type, $(wc -c < "$prev_file") bytes)"
        else
            # An empty clipboard is recorded too (`empty`), not left as "no
            # type file": the difference between "there was nothing to put
            # back" and "already put back" has to be readable, or a second
            # restore pass cannot tell them apart.
            rm -f "$prev_file"
            printf '%s' empty > "$STATE/clipboard-backup.type"
        fi
    fi
    # Ask the shell not to announce this clipboard change (nor the restore). It
    # watches the selection to show its little "Copied" card, and two of those
    # for a sentence nobody copied is noise. Best effort: no shell, no matter.
    # Bounded on purpose. `qs ipc call` waits for a socket that a wedged
    # shell never answers; unbounded, this one call held the whole finish
    # (and the pill) open for 120 s until the daemon killed it, on
    # 2026-11-14. Three seconds is the same order as the call's own work,
    # and losing the quiet window only costs a "Copied" card.
    # 4000, not 2500: the restore below happens after the paste window, and a
    # window that ends first lets the shell announce the user's own picture as
    # "Image copied" again -- a copy nobody made (reported 2026-11-15: a
    # dictation sometimes re-copied the screenshot that was already there).
    # 8000, not 4000: the borrowed sentence goes down and is put back a second or
    # more later, and BOTH changes are announced as "Copied" if the window has
    # run out by then -- which is how a dictation showed a "Copied" card for
    # text nobody copied.
    timeout 3 qs -c ii ipc call cliphistService quietFor 8000 >/dev/null 2>&1 || true
    # --sensitive makes the copy advertise x-kde-passwordManagerHint=secret, which
    # cliphist honours by NOT storing it. Without this a dictation is typed into
    # the cursor and then quietly kept forever in the clipboard history database.
    # The types are unchanged for anyone pasting it, so Ctrl+V still sees text.
    # -t text/plain is not decoration: without it wl-copy sniffs the data and
    # can advertise application/octet-stream, and the next dictation then saw a
    # "non-text" clipboard and gave up on pasting.
    # `9>&-` is not decoration: wl-copy does not exit, it forks a process that
    # keeps owning the selection, and that process inherits every fd of this
    # shell -- including the delivery lock (fd 9). Measured 2026-11-18: a
    # wl-copy left over from one dictation held the lock, so the NEXT one sat
    # out its full 10s flock timeout before pasting ("delivery lock timed out"
    # in the log). Closing 9 for the child keeps the lock scoped to the
    # delivery it was taken for.
    printf '%s' "$1" | wl-copy --sensitive -t text/plain 9>&- 2>/dev/null \
        || { PASTE_FAIL="wl-copy refused the text"; restore_clipboard; return 1; }
    sleep 0.05
    # READ IT BACK BEFORE PRESSING ANYTHING.
    #
    # Reported 2026-11-16: a dictation typed an EARLIER copied thing instead of
    # what was just said. The chord does not carry text -- Ctrl+V pastes
    # whatever the selection holds at the moment the APP reads it -- so "the
    # paste sent our text" is only true if the copy actually took. Two ways it
    # did not, and both end with the old clipboard being pasted:
    #
    #   * wl-copy can fail or lose the selection (a competing owner, a
    #     disconnected display) while still exiting 0 in some paths, and the
    #     chord then pastes the previous contents;
    #   * the restore below used to run 350ms after the chord, and an app that
    #     reads the selection later than that -- a big Electron window, an app
    #     under load -- got the OLD clipboard back, i.e. exactly "it inputted an
    #     earlier copied thing".
    #
    # So: the clipboard must read back as the sentence before the chord goes
    # out, and the restore no longer happens here at all -- it happens in the
    # delivery step once the paste has been seen to land (see the caller).
    local back
    back="$(wl-paste -n -t text/plain 2>/dev/null)"
    if [ "$back" != "$1" ]; then
        sleep 0.08
        back="$(wl-paste -n -t text/plain 2>/dev/null)"
    fi
    if [ "$back" != "$1" ]; then
        PASTE_FAIL="clipboard did not take the sentence -- refusing to paste stale text"
        restore_clipboard
        return 1
    fi
    PASTE_STAGED=1
    paste_shortcut "${2:-}" || { PASTE_FAIL="no Ctrl+V (ydotoold down and wtype missing?)"; restore_clipboard; return 1; }
    # From here the sentence is on the selection and the chord is out: the
    # borrow now has an owner that ends it even if this delivery does not.
    arm_restore_guard "$1"
    # The chord is out; does the selection still hold the sentence? A competing
    # owner between the copy and the app's read -- another copy, or a clipboard
    # manager re-serving an entry -- is the other way a dictation pastes
    # something else, and it deserves a line in the log when it happens. Only
    # the fact is logged, never the words.
    sleep 0.12
    if [ "$(wl-paste -n -t text/plain 2>/dev/null)" != "$1" ]; then
        say "clipboard changed under the paste -- another owner took the selection"
    fi
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

# ── The names whisper spells its own way ─────────────────────────────────
#
# words.txt is a HINT, not a command. The decoder follows the prompt when the
# audio is ambiguous and ignores it when it is not -- which is why "Higgsfield"
# came back as "a pig's field" and "ChatGPT" as "chat gbt" no matter how often
# they were added to the list. Measured 2026-11-18: the prompt really was being
# applied (whisper's timings show the prompt work, and no truncation warning)
# and the names still came out wrong. A prompt cannot promise a spelling.
#
# So the finished sentence is corrected instead -- one pass, no model, no GPU,
# no extra request, audio untouched, and a term that does not match is left
# exactly as it was written. dictate-vocab.py reads BOTH files:
#
#   fixes.txt   `<what whisper writes> => <what was meant>`, applied first and
#               taken literally, so it can correct an ordinary word too;
#   words.txt   every term in the list, matched by SOUND, which is what makes a
#               name added there work without also guessing its manglings in
#               fixes.txt ("Higsfield", "Higgs Field", "Hicks field" ->
#               "Higgsfield").
#
# Whole words, any case, and the file is read on every dictation: an edit takes
# effect on the next hold of SUPER, with no restart of anything.
#
# Applied ONCE to the joined sentence (see finish_raw), not per chunk: fewer
# processes on a long dictation, and a two-word term split across a chunk seam
# is still seen.
spell_fix() {
    local text fixed fixer
    text="$(cat)"
    [ -n "${text//[[:space:]]/}" ] || { printf '%s' "$text"; return 0; }
    fixer="$(dirname "$0")/dictate-vocab.py"
    [ -r "$fixer" ] || { printf '%s' "$text"; return 0; }
    fixed="$(printf '%s' "$text" | python3 "$fixer" 2>>"$LOG")"
    # A corrector that fails, or comes back with nothing, must never cost a
    # sentence: the words whisper found are typed instead. (The old sed version
    # could do exactly that -- one malformed line in fixes.txt aborted the
    # whole program and produced empty text.)
    [ -n "${fixed//[[:space:]]/}" ] || fixed="$text"
    printf '%s' "$fixed"
}

# ── The vocabulary, per request ──────────────────────────────────────────
#
# The warm server is started with words.txt as its prompt, but a prompt that
# lives in the SERVER cannot follow an edit: changing a word used to restart the
# whole server (dictate-vocab-reload), and that restart was the worst latency
# this feature ever had -- the restart at 09:57:00 made the dictation three
# seconds later miss the server, fall back to whisper-cli, and take 39s.
#
# So the list is sent WITH the request. An edit is live on the next hold of
# SUPER, no restart, no warm-up, no lost dictation; the server's own copy stays
# for anything else that talks to it (WhisperFlow).
#
# CUT AT 560 CHARS, because whisper keeps only half of the model's text context
# for a prompt (448/2 = 224 tokens here, and this list measures ~2.7 chars per
# token): past that the decoder drops from the FRONT, which is why the last
# lines of the file are the ones that matter -- see the note in words.txt.
dictate_prompt() {
    local file="${XDG_CONFIG_HOME:-$HOME/.config}/ii-dictate/words.txt"
    [ -r "$file" ] || return 0
    # No sed per line: this runs on the release path, and 60 fork+exec pairs
    # for whitespace trimming measured ~250ms of the wait after the key.
    # Bash can trim a string itself.
    local line out="" used=0 add i
    local -a lines=()
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] || continue
        lines+=("$line")
    done < "$file"
    [ "${#lines[@]}" -gt 0 ] || return 0
    # BUILT FROM THE END. Whisper keeps the LAST tokens of a prompt and drops
    # the front, so the end of this file is the part that must always survive
    # the budget -- and the file's own note says the names that get mangled go
    # last. Filling forwards dropped exactly those names as soon as the list
    # grew past the cap, which is why adding a word could silently do nothing.
    i=$(( ${#lines[@]} - 1 ))
    while [ "$i" -ge 0 ]; do
        add=${#lines[$i]}
        [ -n "$out" ] && add=$(( add + 2 ))
        [ $(( used + add )) -gt 560 ] && break
        used=$(( used + add ))
        out="${lines[$i]}${out:+, $out}"
        i=$(( i - 1 ))
    done
    printf '%s' "$out"
}

# Is the server accepting connections at all? Cheap, bounded, no model work.
server_listening() {
    curl -s --max-time 0.4 -o /dev/null "http://127.0.0.1:${DICTATE_PORT:-8917}/" 2>/dev/null
}

# One request to the warm server. 0 = a non-empty reply is sitting in $2.
ask_server() { # ask_server <wav> <reply-file> <prompt>
    local -a prompt_arg=()
    [ -n "${3:-}" ] && prompt_arg=(-F "prompt=$3")
    # carry_initial_prompt=true, so a server started without the flag still
    # carries the list into every window instead of only the first.
    curl -s --max-time 300 -F "file=@$1" -F response_format=verbose_json \
        -F temperature=0 -F "language=$LANGUAGE" \
        -F carry_initial_prompt=true "${prompt_arg[@]}" \
        "http://127.0.0.1:${DICTATE_PORT:-8917}/inference" -o "$2" 2>/dev/null \
        && [ -s "$2" ]
}

transcribe() { # transcribe <wav> -> prints the text
    local wav="$1" model="$DATA/models/$MODEL"
    # Silence is the other half of the bad-text problem, and the model cannot
    # see it: handed four seconds of digital silence, whisper answers
    # " Thank you." with no_speech_prob 1e-10 and avg_logprob -0.28 -- certain,
    # wrong, and it reaches the text field. Neither field in the reply is
    # evidence of anything here; the recording itself is, so it is measured
    # before a single byte is sent. -50 dB mean sits well under a soft whisper
    # and well over room tone (this machine's silent take measured -91 dB).
    # The level is handed over by the caller that already knows it (II_AUDIO_DB,
    # measured in dictate-daemon.py from the bytes it captured); the ffmpeg pass
    # below is only for a caller that hands in a bare file. Measuring it with
    # ffmpeg cost 74-266ms per dictation -- on the release path, for a number
    # the daemon has had since the first block arrived.
    local level="${II_AUDIO_DB:-}"
    if [ -z "$level" ] && [ -s "$wav" ]; then
        level="$(ffmpeg -hide_banner -nostats -i "$wav" -af volumedetect -f null - 2>&1 \
            | sed -n 's/.*mean_volume: \([-0-9.]*\) dB.*/\1/p' | head -1)"
    fi
    if [ -n "$level" ] && awk -v l="$level" 'BEGIN { exit !(l + 0 < -50) }'; then
        say "input is silent (${level} dB), nothing to transcribe"
        return 0
    fi
    # ── Cut the silence off both ends before anybody hears it ─────────────
    #
    # THIS IS THE "thank you" FIX, and it is about the audio, not the words.
    # whisper was trained on broadcast recordings, so it expects the recording
    # to end the way a broadcast does: with the speaker signing off. Handed a
    # take that ends in a second of room tone it invents the sign-off --
    # "Thank you.", "Thank you. I'll see you next time.", "Vielen Dank." --
    # and it does it with no_speech_prob near 0 and a perfectly healthy
    # avg_logprob, so no amount of confidence checking can tell it from speech.
    # The trigger is the trailing silence, and the answer is to not send it.
    #
    # It matters per REQUEST, not only per dictation: a chunk is cut after
    # QUIET_BLOCKS of quiet (dictate-daemon.py), so every chunk ends in
    # silence too, and a long dictation used to collect one invented sign-off
    # per chunk, in the middle of the sentence.
    #
    # -50 dB is the same line the level gate above draws; 0.1s is kept at each
    # end so the first and last syllable are not clipped into a click, and the
    # areverse pair is how silenceremove is made to work from the END (it only
    # trims from the front). A take that is silence all the way through comes
    # back empty, and empty is the honest answer: nothing to transcribe.
    local wav_trim=""
    if [ -s "$wav" ]; then
        wav_trim="$(mktemp "$STATE/trim-XXXXXX.wav")"
        if [ -n "$wav_trim" ] && ffmpeg -hide_banner -loglevel error -nostdin -y -i "$wav" \
                -af "silenceremove=start_periods=1:start_duration=0:start_threshold=-50dB:start_silence=0.1,areverse,silenceremove=start_periods=1:start_duration=0:start_threshold=-50dB:start_silence=0.1,areverse" \
                "$wav_trim" >>"$LOG" 2>&1 && [ "$(stat -c %s "$wav_trim" 2>/dev/null || echo 0)" -gt 2000 ]; then
            # Bytes, not seconds: no ffprobe on the release path. 32 kB is a
            # second of 16 kHz mono, so a whole-second difference is readable
            # in the log without costing anything. (ffmpeg's own padding can
            # make the copy a few bytes LONGER while the audio is shorter, so
            # the number is only worth a line when it is positive.)
            local saved=$(( $(stat -c %s "$wav") - $(stat -c %s "$wav_trim") ))
            [ "$saved" -gt 0 ] && say "trimmed $saved bytes of silence off the ends"
            wav="$wav_trim"
        else
            rm -f "$wav_trim"
            wav_trim=""
            say "the take is silence end to end, nothing to transcribe"
            return 0
        fi
    fi
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
    #
    # AND THE SERVER MAY BE STARTING, NOT GONE. This is the whole of the
    # "sometimes it takes ages" report: on 2026-11-18 at 09:57:01 a dictation
    # landed on a server restart, the request got a connection error, and the
    # code below jumped straight to whisper-cli -- which loads the model from
    # disk and initialises CUDA, and took 39s for 2.6s of audio. A warm server
    # answers in 0.3-0.9s, and one that is coming up is listening within ~4s, so
    # the cold path must never win by default. Waiting is always the better
    # trade; the fallback is kept for a server that is really not coming back.
    local prompt got=0
    prompt="$(dictate_prompt)"
    if ask_server "$wav" "$reply" "$prompt"; then
        got=1
    elif ! server_listening; then
        say "the warm server is not answering -- waiting for it instead of loading the model cold"
        local waited=0
        while [ "$waited" -lt 50 ] && ! server_listening; do
            sleep 0.5
            waited=$(( waited + 1 ))
        done
        if [ "$waited" -lt 50 ]; then
            say "server answered after $(( waited * 500 )) ms -- asking it again"
            ask_server "$wav" "$reply" "$prompt" && got=1
        fi
    fi
    if [ "$got" = "1" ]; then
        if TF_TEXT="$out" TF_LANG="$LANG_FILE" LANG_CODES="$LANG_CODES" TF_WAV="$wav" \
                python3 - "$reply" <<'PY'
import json, math, os, re, sys, time

# WHAT THIS IS FOR: whisper does not return nothing on silence, it returns
# something. Room tone between two sentences becomes "Thank you.", a breath
# under music becomes "*Pewds*", and a chunk cut mid-word can loop ("you you
# you you"). Those words land in whatever the user is typing, which is worse
# than no words at all. So the reply is judged before it is typed:
#
#   * the model's own certainty, per segment: `no_speech_prob` (how sure it is
#     that this was NOT speech) and `avg_logprob` (how sure it is of the words
#     it did pick). whisper.cpp reports both in verbose_json.
#   * the handful of phrases whisper hallucinates on quiet audio, which only
#     get dropped when the certainty also says "probably not speech" -- a real
#     "thank you" is still typed.
#   * loops: the same sentence three times in a row is a decoding failure, not
#     someone repeating themselves.
#
# Anything unreadable in the reply keeps the old behaviour (type the text), so
# a change in the server's JSON cannot silently swallow a dictation.

HALLUCINATIONS = {
    "", ".", "you", "bye", "okay", "thank you", "thanks", "thank you very much",
    "thank you for watching", "thanks for watching", "thank you so much",
    "please subscribe", "like and subscribe", "subscribe to my channel",
    "subtitles by", "transcribed by", "amara.org", "thanks for being here",
    "thank you for watching the video", "see you next time", "see you later",
    "vielen dank fürs zuschauen", "danke fürs zuschauen", "untertitel",
    "untertitel der amara.org-community", "untertitel von stephanie bentley",
    "das war's", "bis zum nächsten mal", "musik", "applaus",
}


def normalise(text):
    text = text.lower().replace("’", "'")
    text = re.sub(r"[^0-9a-zà-ÿ' ]+", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def certainty(segments):
    """0..1 from the model: how much of that was actually speech."""
    best = None
    for segment in segments:
        if not isinstance(segment, dict):
            continue
        value = None
        no_speech = segment.get("no_speech_prob")
        if isinstance(no_speech, (int, float)):
            value = 1.0 - float(no_speech)
        logprob = segment.get("avg_logprob")
        if isinstance(logprob, (int, float)):
            # -1.0 is "barely a guess", 0.0 is "certain"; below that it is noise.
            value = max(value or 0.0, max(0.0, min(1.0, float(logprob) + 1.0)))
        if value is not None:
            best = value if best is None else max(best, value)
    return best


def collapse_loops(text):
    """'you you you you' and repeated sentences, down to one."""
    words = text.split()
    if len(words) >= 6:
        for size in range(1, len(words) // 3 + 1):
            unit = words[:size]
            repeats = 0
            while words[repeats * size:(repeats + 1) * size] == unit:
                repeats += 1
            if repeats >= 3 and repeats * size >= len(words) - size:
                return " ".join(unit)
    # The last two sentences identical and the one before them too.
    sentences = [s.strip() for s in re.split(r"(?<=[.!?])\s+", text) if s.strip()]
    if len(sentences) >= 3 and len(set(normalise(s) for s in sentences[-3:])) == 1:
        return " ".join(sentences[:-2])
    return text


# ── The sign-off at the END of the sentence ──────────────────────────────
#
# The list above only helps while the whole reply is one of those phrases. The
# reported case is the other shape: real words, then the invented sign-off
# glued onto the end of them -- "move the button down a bit. Thank you. Thank
# you. I'll see you next time." The reply as a whole is not in the list, so
# nothing above touches it, and the tail arrives in whatever the user is
# typing. Dictate.sh now trims the trailing silence that causes it; these are
# the backstop for the takes where the model signs off anyway.
#
# A sentence can only be cut if every word in it belongs to a sign-off -- the
# whole trailing run, one sentence at a time, so "Thank you. Thank you. I'll
# see you next time." goes completely and "Thanks, that's the last one." is
# left alone.
SIGN_WORDS = {
    "thank", "thanks", "thankyou", "you", "very", "much", "so", "a", "lot",
    "many", "for", "watching", "listening", "being", "here", "please",
    "subscribe", "like", "and", "to", "my", "channel", "subtitles", "subtitle",
    "transcribed", "by", "amara", "org", "community", "the",
    "danke", "dank", "vielen", "vielmals", "schön", "sehr", "fürs", "zuschauen",
    "zuschauer", "bis", "zum", "nächsten", "naechsten", "mal", "bald",
    "tschüss", "tschuess", "auf", "wiedersehen", "wiederhören", "das", "war's",
    "wars", "merci", "ciao", "bye", "goodbye", "see", "later", "next", "time",
}
# At least one of these has to be in it: "for the next time" is a sentence
# about scheduling, "thanks for the next time" is not a sentence anybody says.
SIGN_CORE = {
    "thank", "thanks", "thankyou", "danke", "vielen", "tschüss", "tschuess",
    "merci", "ciao", "bye", "goodbye",
}
# Phrases that are only ever spoken to a recording, never into a text box.
SIGN_ALWAYS = (
    "for watching", "for listening", "subscribe", "subtitles by",
    "transcribed by", "amara", "see you next time", "see you later",
    "for being here", "bis zum nächsten", "bis zum naechsten", "bis bald",
    "auf wiedersehen", "fürs zuschauen", "das war's", "tschüss", "bye bye",
)


def sign_off(sentence):
    """True when the sentence is nothing but a sign-off.

    Two ways in: a broadcast phrase anywhere in it ("I'll see you next time"
    is a sign-off even though "I'll" is not a sign-off word), or every single
    word from the sign-off vocabulary with one of the core words among them
    ("Thanks for watching the video", "Vielen Dank", "thank you thank you").
    "Thanks, that's the last one" has words that are not in it and stays.
    """
    key = normalise(sentence)
    if any(phrase in key for phrase in SIGN_ALWAYS):
        return True
    words = key.split()
    if not words:
        return False
    return all(w in SIGN_WORDS for w in words) and any(w in SIGN_CORE for w in words)


def strip_sign_off(text):
    """Take the invented sign-off off the end, leaving the real words.

    The whole trailing run goes, sentence by sentence, however many there are,
    because that is the shape of the bug: whisper does not add one sign-off, it
    runs on -- "Thank you. Thank you. I'll see you next time."

    The trade is deliberate: a dictation that genuinely ends in a bare "Thank
    you." loses it (the words before it are untouched, and anything with one
    more word in the sentence -- "Thank you, John" -- is kept). Whisper writes
    those words far more often than a person dictates them, and a sign-off
    nobody said is silently wrong text in the middle of a message.
    """
    sentences = [s for s in re.split(r"(?<=[.!?])\s+", text) if s.strip()]
    if not sentences:
        return text
    cut = 0
    while sentences and sign_off(sentences[-1]):
        sentences.pop()
        cut += 1
    if not cut:
        return text
    return " ".join(s.strip() for s in sentences).strip()


# ── Did anybody actually say that? ───────────────────────────────────────
#
# The list below and the sign-off stripper are both guesses about WORDS, and
# whisper's inventions are not a fixed set: reported 2026-11-18, a dictated
# sentence ended with "and the next one" -- never said, just decoded off the
# room tone after the last word. No list can keep up with that.
#
# So the audio is asked instead. Every reply carries per-segment start/end
# times, and the audio those times refer to is the file we just sent, so a
# segment that sits on silence is a segment nobody spoke, whatever it says.
# The measurement is one ffmpeg pass over the take (66 ms for 4 s) and it only
# runs when the reply has the SHAPE of the bug: several segments and a short
# tail (a real sentence is many words; an invented sign-off is a few).

def rms_frames(path):
    """Every 0.1 s of the take: how loud it was, in dB.

    Read from the WAV itself, not from ffmpeg: `astats` reports a RUNNING RMS
    (measured: 40 frames of a take that is half tone, half digital silence all
    drifted from -30 to -34 dB, and the silence never showed up), which answers
    "how loud has this been" when the question is "how loud is THIS". Sixteen
    thousand samples a second is also cheaper to parse here than to pipe
    through another process on the release path.
    """
    if not path:
        return []
    try:
        import array
        import wave
        with wave.open(path, "rb") as f:
            rate = f.getframerate() or 16000
            if f.getsampwidth() != 2 or f.getnchannels() != 1:
                return []
            raw = f.readframes(f.getnframes())
    except Exception:
        return []
    samples = array.array("h")
    samples.frombytes(raw[:len(raw) - (len(raw) % 2)])
    step = max(1, rate // 10)          # one number per 0.1 s
    frames = []
    for at in range(0, len(samples), step):
        block = samples[at:at + step]
        if not block:
            break
        energy = sum(float(s) * s for s in block) / len(block)
        frames.append((at / float(rate),
                       10.0 * math.log10(energy / (32768.0 ** 2)) if energy > 0 else -120.0))
    return frames


def heard_anything(frames, start, end, reference, margin=14.0):
    """Was there a voice in this segment's window, or only room tone?

    Two lines, and both are needed. -50 dB is the same silence line the level
    gate draws: under it this is not a recording of anything. The relative one
    is what makes a noisy room work -- `margin` dB under the loudness of the
    rest of the take is room tone, not somebody talking (speech stays within a
    few dB of itself, a fan or a breath does not). No measurement means no
    opinion.

    `margin` is a parameter because a whole invented SENTENCE and a single WORD
    are not the same measurement; see the word-level caller for why the second
    one needs a wider margin.
    """
    if not frames:
        return True
    window = [level for at, level in frames if start - 0.06 <= at < end + 0.06]
    if not window:
        return True
    floor = max(-50.0, reference - margin)
    return (sum(window) / len(window)) >= floor


def speech_level(frames, before=None, after=None):
    """How loud this take is where it was actually speaking.

    The median of the frames on the far side of the segment under test, not the
    maximum: one door slam must not become the yardstick, and the median of a
    sentence is the body of it. Falls back to the whole take when there is
    nothing on that side.
    """
    spared = [(at, level) for at, level in frames
              if (before is None or at < before) and (after is None or at > after)]
    levels = sorted(level for _, level in spared) or sorted(level for _, level in frames)
    if not levels:
        return -50.0
    return levels[len(levels) // 2]


def trim_silent_words(kept, frames):
    """Cut words the reply says were spoken in silence, inside the last segment.

    The sign-off does not always arrive as its own segment: "Send him the
    invoice and the next one" can come back as ONE segment, and then no
    per-segment test can separate the two halves. The reply carries a time for
    every WORD, though, so the tail of that last segment is measured word by
    word and anything that happened in silence is cut -- text and all, by
    rebuilding the segment from the words that were actually heard.

    Only the LAST segment, and only from its end: this is for the sign-off that
    runs on after the sentence, not a way to rewrite what somebody said.
    """
    if not kept or not frames:
        return kept
    last = kept[-1]
    if not isinstance(last, dict):
        return kept
    words = last.get("words")
    if not isinstance(words, list) or len(words) < 2:
        return kept
    reference = speech_level(frames, before=float(last.get("start") or 0.0))
    # A WORD is allowed to be much quieter than the take before it counts as
    # room tone. The 14 dB margin above is right for a whole invented sentence
    # and wrong for the last word of a real one: a sentence trails off, a
    # microphone's gain rides down with it, and this cut deletes everything
    # from the first word it disbelieves to the end of the segment -- the
    # report "my last words are cut off". Measured on this machine (the last
    # two words of a take attenuated by a fixed amount): at 18 dB under the
    # rest of the take they survived, at 22 dB they were deleted, so 14 dB was
    # eating ordinary speech. 24 dB still takes room tone, which sits 30-50 dB
    # down, and the model's own confidence is the second gate below.
    word_margin = 24.0
    spoken = 0
    for index, word in enumerate(words):
        if not isinstance(word, dict):
            return kept
        start, end = word.get("start"), word.get("end")
        if not isinstance(start, (int, float)) or not isinstance(end, (int, float)):
            return kept
        heard = heard_anything(frames, float(start), float(end), reference, word_margin)
        if not heard:
            # Level alone must not overrule the model. whisper puts a
            # probability on every word, and an invention is what a low one
            # looks like (the "Wow!" it appends to a clip ends on 0.5-0.7);
            # a word it decoded at 0.99 is speech it heard, however softly it
            # was spoken. Cutting on level alone is what took the last word.
            probability = word.get("probability")
            if isinstance(probability, (int, float)) and probability >= 0.6:
                heard = True
        if heard:
            spoken = index + 1
    if spoken == 0 or spoken == len(words):
        return kept
    rebuilt = "".join(str(w.get("word") or "") for w in words[:spoken]).strip()
    if not rebuilt:
        return kept
    trimmed = dict(last)
    trimmed["text"] = " " + rebuilt
    trimmed["end"] = words[spoken - 1].get("end")
    return kept[:-1] + [trimmed]


def drop_unheard(segments, wav):
    """Take the segments nobody spoke off both ENDS of the reply.

    Only the ends: a pause in the middle of a sentence is a pause, and dropping
    a middle segment would cut a real sentence in two. The ends are where this
    bug lives -- whisper starts and finishes a take the way a broadcast does.
    """
    timed = [s for s in segments if isinstance(s, dict)]
    if not timed or not wav:
        return segments
    frames = rms_frames(wav)
    if not frames:
        return segments
    kept = list(segments)

    def silent(seg):
        start, end = seg.get("start"), seg.get("end")
        if not isinstance(start, (int, float)) or not isinstance(end, (int, float)):
            return False
        # Judge the segment against the take MINUS itself, or a take that is
        # all room tone would only ever agree with itself.
        if kept and seg is kept[0]:
            reference = speech_level(frames, after=float(end))
        else:
            reference = speech_level(frames, before=float(start))
        return not heard_anything(frames, float(start), float(end), reference)

    while len(kept) > 1 and isinstance(kept[-1], dict) and silent(kept[-1]):
        kept.pop()
    while len(kept) > 1 and isinstance(kept[0], dict) and silent(kept[0]):
        kept.pop(0)
    kept = trim_silent_words(kept, frames)
    # One segment, and nothing was said in it: that is a reply made entirely of
    # room tone ("www.hans.com.br" off four seconds of silence), not a sentence.
    if len(kept) == 1 and isinstance(kept[0], dict) and silent(kept[0]):
        return []
    return kept


def judge(text, segments):
    text = (text or "").strip()
    if not text:
        return ""
    sure = certainty(segments)
    if sure is not None and sure < 0.35:
        return ""                      # the model itself says this was not speech
    if not re.search(r"[0-9A-Za-zÀ-ÿ]", text):
        return ""                      # punctuation, musical notes, markup only
    if (sure is None or sure < 0.8) and re.match(r"^\s*[*\[(].*[*\])]\s*$", text):
        return ""                      # a sound event: *Pewds*, (coughs), [music]
    key = normalise(text)
    if key in HALLUCINATIONS and (sure is None or sure < 0.7):
        return ""
    collapsed = collapse_loops(text).strip()
    # A loop that collapses to a filler ("you you you you" -> "you") is still
    # not words someone said.
    if collapsed != text and normalise(collapsed) in HALLUCINATIONS:
        return ""
    collapsed = strip_sign_off(collapsed)
    if not re.search(r"[0-9A-Za-zÀ-ÿ]", collapsed):
        return ""                      # only a sign-off was there: nothing said
    return collapsed


try:
    data = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(1)
if not isinstance(data, dict):
    raise SystemExit(1)
said = data.get("segments") or []
kept = drop_unheard(said, os.environ.get("TF_WAV", ""))
if said and not kept:
    # Every segment measured as room tone: the reply was an invention end to end,
    # so there is nothing to type (and nothing to fall through to the word
    # filters with).
    text = ""
else:
    words = data.get("text") or ""
    if kept:
        # The segments are the truth now, whether one was dropped or one was CUT
        # short: the reply's whole-sentence string still carries the invented
        # words.
        joined = " ".join(str(s.get("text") or "").strip() for s in kept).strip()
        if joined:
            words = joined
    text = judge(words, kept)
with open(os.environ["TF_TEXT"], "w") as f:
    f.write(text)
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
            # The words are corrected once, on the joined sentence (finish_raw):
            # a chunk on its own must not be rewritten before it is joined.
            clean_transcript < "$out"
            rm -f "$out" "$reply" "$wav_trim"
            return 0
        fi
    fi
    rm -f "$out" "$reply"
    if [ ! -x "$DATA/whisper.cpp/build/bin/whisper-cli" ]; then
        say "no whisper-cli at $DATA/whisper.cpp/build/bin -- run the installer"
        rm -f "$wav_trim"
        return 1
    fi
    if [ ! -f "$model" ]; then
        say "no model at $model"
        rm -f "$wav_trim"
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
    rm -f "$wav_trim"
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
        case "$raw" in
            *.wav) # The daemon hands over a finished WAV -- header plus the same
                   # PCM -- so there is nothing to wrap and no ffmpeg start
                   # (~70-90ms) between the release and the words.
                   wav="$raw" ;;
            *) ffmpeg -hide_banner -loglevel error -y -f s16le -ar 16000 -ac 1 \
                   -i "$raw" "$wav" >>"$LOG" 2>&1 ;;
        esac
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
    if [ -n "${II_AUDIO_SECONDS:-}" ]; then
        # Same story as the level: the daemon counted the samples (len/32000),
        # and ffprobe spent ~70ms of the release re-reading the file to find out.
        elapsed="$(LC_ALL=C printf '%.2f' "$II_AUDIO_SECONDS" 2>/dev/null || echo 0)"
        say "recorded ${elapsed}s (tail)"
    elif [ -s "$wav" ]; then
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

    # The caret probe, started HERE instead of after the words come back. It
    # walks the accessibility tree -- 140-180ms measured on this machine, up to
    # its 2s cap on a big app -- and nothing it looks at changes while whisper is
    # decoding, so that wait was pure addition to the release. Its answer is only
    # needed one line before the text is typed.
    FOCUS_HINT_FILE=""
    local focus_pid=""
    if [ "${TYPE_CMD:-auto}" != "wl-copy" ]; then
        FOCUS_HINT_FILE="$(mktemp "$STATE/focus.XXXXXX")" && {
            ( timeout 2s python3 "$(dirname "$0")/dictate-focus.py" >"$FOCUS_HINT_FILE" 2>/dev/null ) &
            focus_pid=$!
        }
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

    # The names, once, over the whole sentence: the chunks were left as whisper
    # wrote them so a term that landed on a chunk boundary is still corrected
    # here (see spell_fix).
    if [ -n "$text" ]; then
        text="$(printf '%s' "$text" | spell_fix)"
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
    local focus_hint=""
    if [ -n "$focus_pid" ]; then
        wait "$focus_pid" 2>/dev/null
        focus_hint="$(cat "$FOCUS_HINT_FILE" 2>/dev/null)"
        rm -f "$FOCUS_HINT_FILE"
    fi
    if [ -n "$focus_pid" ]; then
        case "$focus_hint" in
            focused)
                say "focus: gave the app's input box the caret"
                sleep 0.15      # let the toolkit move the caret before typing
                ;;
            already)   say "focus: input box already selected" ;;
            no-entry)  say "focus: the app exposes no input box" ;;
            *)         say "focus: the app publishes no accessibility tree" ;;
        esac
    fi
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

    # ONE delivery at a time. Two dictations in flight -- a quick second hold
    # while the first is still pasting -- fight over the selection: the second
    # one's copy can land between the first one's copy and its chord, and the
    # first then pastes the SECOND sentence. A lock costs nothing and takes that
    # whole class of "it pasted something else" out.
    local delivery_lock="$STATE/delivery.lock"
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$delivery_lock" || true
        flock -w 10 9 || say "delivery lock timed out -- pasting anyway"
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
                    # NO clipboard rescue. This used to leave the sentence on
                    # the selection when the paste could not be made, which is
                    # how a dictation ended up "copying itself" -- reported
                    # 2026-11-15: nothing is copied unless Copy is pressed. The
                    # card raised below is the rescue, and it is the only place
                    # the words can be picked up from.
                    method="failed (${PASTE_FAIL:-unknown})"
                fi
            fi ;;
        wtype)   printf '%s' "$out" | wtype - ;;
        ydotool) ydotool type -- "$out" ;;
        wl-copy) printf '%s' "$out" | wl-copy --sensitive -t text/plain 9>&- ;;
        *)       "$method" "$out" ;;
    esac
    # When the chord went out. The clipboard may not be put back until the app
    # has had time to READ the selection (see the restore below).
    local paste_sent_ms=""
    case "$method" in paste*) paste_sent_ms="$(date +%s%3N)" ;; esac
    say "delivered with $method"

    # ── THE WORDS ARE AT THE CARET. EVERYTHING BELOW IS HOUSEKEEPING ─────────
    #
    # Three screenshots to judge whether the app took the sentence, the second
    # the clipboard has to stay put, the history write -- none of it is time the
    # user is waiting for anything, because the text is already in front of
    # them. Running it inline kept the pill on "Transcribing…" for another
    # 1-1.6 s AFTER the sentence appeared (dictate.log, 2026-11-18: "tail
    # transcribed in 960 ms" followed by ~1.6 s of checks), and that afterglow
    # is what made a fully local dictation feel slower than the old cloud one.
    # Detached, this script returns as soon as the text is delivered, which is
    # what clears the pill. The block below keeps the indentation it had as
    # inline code on purpose: it is a move, not a rewrite.
    (
        # The delivery lock (fd 9) is this delivery's. A subshell that outlives
        # the script must not keep holding it, or the next dictation waits.
        exec 9>&- 2>/dev/null || true

    # Did it land? A wide band of *new* pixels in the bottom of the window -- the
    # shape of a line of text in a prompt box -- counts as delivered. See
    # paste-landed.py for why that is the shape, and what it ignores.
    local landed=0
    if [ -s "$SHOT_BEFORE" ] && [ -s "$SHOT_PAIR" ]; then
        local attempt=1 verdict=""
        while [ "$attempt" -le 2 ]; do
            sleep 0.15
            grab_window "$SHOT_AFTER" "$WINDOW_GEO" || break
            verdict="$(python3 "$(dirname "$0")/paste-landed.py" \
                "$SHOT_BEFORE" "$SHOT_PAIR" "$SHOT_AFTER" \
                "$(band_fraction "$WINDOW_GEO")" 2>/dev/null)"
            say "landed check (try $attempt): ${verdict:-no answer}"
            case "$verdict" in landed*) landed=1 ; break ;; esac
            # A grab can outrun the app's own paint, especially with a big
            # Electron window: the sentence is in the box but not on screen yet,
            # so a single early look reads as a miss. Look again -- TWO looks,
            # not three: each one is a full-window grim read (~0.4s) plus the
            # comparison, and a third bought a verdict nobody was waiting for
            # any more while it held the clipboard and the transcript card
            # back. Measured on the desktop app: three tries took 4.0s.
            attempt=$(( attempt + 1 ))
        done
    fi
    rm -f "$SHOT_BEFORE" "$SHOT_PAIR" "$SHOT_AFTER"
    # NOW the borrowed clipboard goes back -- but only after the app has had a
    # real chance to READ the selection.
    #
    # The chord carries no text: Ctrl+V pastes whatever the selection holds at
    # the instant the APP reads it, not when the key is pressed. A big Electron
    # window, an app under load, or a window that only handles the key on its
    # next frame reads it late -- and restoring the moment the chord went out
    # handed it the user's PREVIOUS clipboard instead. Reported: "it pastes
    # something completely different, a random other thing I copied". The
    # landed-check above usually buys 0.2-0.6s, which is not enough on its own,
    # and when the screenshots were unavailable it bought nothing at all. So the
    # sentence stays put for a minimum dwell measured from the chord itself,
    # whatever the landed check concluded.
    case "$method" in
        paste*)
            # How long the sentence must stay on the selection AFTER the chord.
            #
            # The chord carries no text: Ctrl+V pastes whatever the selection
            # holds when the APP reads it, so a restore that runs too early
            # hands a slow app the user's previous clipboard. That is why this
            # used to be a flat second.
            #
            # But when the landed check says the sentence is already DRAWN in
            # the window, the app has read the selection by definition and the
            # extra second buys nothing -- it only widens the window in which a
            # Ctrl+V somewhere else returns the transcript instead of what the
            # user copied. So: a short beat for the paint, and the full second
            # only when the check had no verdict to give.
            local dwell_ms=1000 elapsed_ms=0 pad
            [ "$landed" = "1" ] && dwell_ms=250
            if [ -n "$paste_sent_ms" ]; then
                elapsed_ms=$(( $(date +%s%3N) - paste_sent_ms ))
            fi
            if [ "$elapsed_ms" -lt "$dwell_ms" ]; then
                pad="$(awk -v d="$dwell_ms" -v e="$elapsed_ms" \
                    'BEGIN { printf "%.2f", (d - e) / 1000 }')"
                sleep "$pad"
                say "clipboard kept ${dwell_ms}ms so the app could read the sentence (waited ${pad}s more)"
            fi
            restore_clipboard
            ;;
    esac
    if [ "$landed" = "1" ]; then
        say "delivery landed in the focused window"
    else
        say "delivery did not land -- the transcript card is the way to copy it"
    fi
    # ── THE CARD GOES UP NOW, whatever the verdict was ────────────────────
    #
    # The words are in front of the user and the borrowed clipboard has just
    # been handed back (above), so Copy on the card cannot race the borrow.
    #
    # It used to be shown only on a MISS, and only after the landed check had
    # finished -- up to four seconds of screen grabs after the sentence had
    # already landed. That is the "the copy button appears way too late"
    # report: the card is a copy affordance, and an affordance that shows up
    # after the moment has passed is not one. It appears as soon as the
    # sentence exists and the clipboard is the user's again, which is under a
    # second after the text -- sooner, and still not on top of the paste.

    show_transcript "$out"

    # The sentence went through the clipboard in these two routes; cliphist is
    # asked to skip sensitive copies, but is not trusted to (forget_cliphist).
    case "$method" in
        paste*|wl-copy*) ( sleep 0.9; forget_cliphist "$out" ) >/dev/null 2>&1 & ;;
    esac
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
    ) >/dev/null 2>&1 &
    # The lock was taken for the copy + chord + nothing else; the next dictation
    # must not inherit a wait from this one's housekeeping.
    exec 9>&- 2>/dev/null || true
    return 0
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
        # The test path shows what a dictation would actually type, so the
        # vocabulary correction is part of it.
        transcribe "$2" | spell_fix
        echo
        ;;
    paste) # manual: deliver TEXT the way a finished dictation would, for testing
           # the delivery path without speaking into the microphone.
        [ -n "${2:-}" ] || { echo "usage: dictate.sh paste TEXT" >&2; exit 2; }
        if paste_text "$2"; then
            # Same rule as a real dictation: the sentence is borrowed for the
            # chord, not left behind for the next Ctrl+V.
            sleep 0.35
            restore_clipboard
            say "manual paste ok"
        else
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
        case "$2" in
            *.wav) tmp="$2" ;;   # already a WAV: the daemon writes the header
            *)
                tmp="$(mktemp "$STATE/chunk-XXXXXX.wav")" || exit 1
                ffmpeg -hide_banner -loglevel error -y -f s16le -ar 16000 -ac 1 \
                    -i "$2" "$tmp" >>"$LOG" 2>&1
                ;;
        esac
        rc=0
        if [ -s "$tmp" ]; then transcribe "$tmp"; rc=$?; fi
        [ "$tmp" = "$2" ] || rm -f "$tmp"
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
