#!/usr/bin/env bash
# fix-mouse.sh -- give the mouse back.
# Bound to SUPER + CTRL + M (see custom/keybinds.lua).
#
# ── THE FAILURES THIS UNDOES ────────────────────────────────────────────────
#
# "I can move the pointer but I cannot CLICK anything" has three causes on this
# desktop and they are indistinguishable from the chair -- so this key clears
# all three rather than the one it used to, which is why it so often logged
# success ("shell is up; grab released") while the pointer was still dead.
#
#   1. A BUTTON OR KEY LEFT HELD ON ydotoold's VIRTUAL DEVICE.       [step 1]
#
#      The shell's own features type through that device -- clipboard paste
#      (Ctrl+V), the on-screen keyboard, the notification and search overlays --
#      and so do the failsafe scripts. Its button and key state belongs to the
#      SESSION, not to the program that sent it, so a press whose release never
#      went out (a script killed halfway, a shell that reloaded or died
#      mid-keystroke) leaves the button DOWN. From that moment the press has
#      already happened and no new one ever lands: the pointer moves, nothing
#      clicks. THIS is the shape reset-shell.sh has always cleared and this key
#      never did, and it goes first because it is the cheapest and the most
#      likely.
#
#   2. A COMPOSITOR-LEVEL GRAB HELD BY A LIVE SHELL.                 [step 2]
#
#      While one is active Hyprland routes every pointer and keyboard event to
#      the grabbing window. That is by design -- it is how a bar popup or a
#      sidebar swallows the click that lands outside it. The failure is a grab
#      that stays active with nothing on screen to explain it: the desktop looks
#      completely normal, the pointer still moves, and no click lands on any
#      application. The bar and the other shell surfaces keep answering, because
#      THEY are the ones holding the grab -- the "I can click the desktop but
#      not my apps" report.
#
#      GlobalFocusGrab arbitrates this on its own (it prunes entries whose window
#      is gone and releases the grab once nothing visible is left) and exposes
#      `focusGrab release` for everything its timer cannot catch.
#
#   3. A SHELL THAT IS UP BUT NOT ANSWERING.                         [step 4]
#
#      Its surfaces are still mapped, so every cheap liveness test says "alive",
#      and every IPC call is swallowed -- including the release above. The old
#      script read that as success. Now it is the escalation: the shell has had
#      its chance to answer, so the reload takes over.
#
#   4. THE KEYBOARD HELD SOMEWHERE ELSE.                             [step 2b]
#
#      The three above are all about the POINTER; this one is about the
#      KEYBOARD, and from the chair it looks different: the pointer is fine and
#      clicks land everywhere, but a text field never takes input, so the click
#      that should put a caret in it appears to do nothing. A stuck Hyprland
#      SUBMAP is the case here -- every key goes to the submap, so nothing can
#      be typed anywhere -- and it is also the one case where this key never
#      ran at all, because ordinary binds do not fire while a submap is
#      entered. The bind is submap_universal for that reason.
#
# What it deliberately does NOT do: restart the shell for cause 1 or 2. That is
# SUPER+CTRL+B's job (reload-shell.sh), it is slower, and it disturbs every
# surface -- so it is reserved for cause 3 and for no shell at all, the two cases
# where the shell is itself the problem and a release has nothing to talk to.
set -u

qs_config="${qsConfig:-ii}"
runtime="${XDG_RUNTIME_DIR:-/tmp}"
log_file="/tmp/fix-mouse.log"

log() { printf '[fix-mouse] %s %s\n' "$(date '+%H:%M:%S')" "$*" >>"$log_file" 2>/dev/null || true; }

# The compositor's own view of whether a shell is drawing. Cheaper and more
# reliable than probing the IPC socket (a `qs` poll spawns a whole binary).
shell_alive() { hyprctl layers -j 2>/dev/null | grep -q '"quickshell:bar"'; }

# One IPC call, bounded, never a hard failure: a shell that is not there answers
# "No running instances ..." (non-empty, and a value we log verbatim), while a
# shell that is there but STUCK answers nothing at all -- which is exactly the
# distinction step 4 needs.
ipc() { timeout 2 qs -c "$qs_config" ipc call "$@" 2>/dev/null || true; }

# Was this stamp touched within N seconds?
recent() { [ -f "$1" ] && [ $(( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || echo 0) )) -lt "$2" ]; }

# ── 1. Let go of every button and key ───────────────────────────────────────
#
# The masks matter. `ydotool click 0x80` is "left button UP" -- up only -- where
# a plain `ydotool click 0x00` would press AND release, i.e. fire a real click
# into whatever happens to be under the pointer. A key for a dead pointer must
# not click on things, so every button is released with the up mask: 0x80..0x87
# is LEFT, RIGHT, MIDDLE, SIDE, EXTRA, FORWARD, BACK, TASK.
#
# Then every keycode up, so no modifier is left down either (a stuck Ctrl turns
# the user's next click into Ctrl+click; a stuck Super hands it to Hyprland's
# own Super+mouse binds). 249 keycodes is the range reset-shell.sh releases and
# covers every modifier there is.
#
# Guarded on the daemon, because `ydotool` without a live ydotoold is a hard
# error and this script is also the one that must never fail loudly.
if command -v ydotool >/dev/null 2>&1 && [ -S "$runtime/.ydotool_socket" ]; then
    ydotool click --next-delay 0 0x80 0x81 0x82 0x83 0x84 0x85 0x86 0x87 >/dev/null 2>&1 || true
    ydotool key --key-delay 0 $(seq 0 248 | sed 's/$/:0/') >/dev/null 2>&1 || true
    log "released held buttons and keys on the virtual device"
else
    log "no ydotoold socket -- held input cannot be cleared from here"
fi

# ── 2. Release the compositor-level grab ────────────────────────────────────
#
# Kept because the only way to tell a real misfire from "nothing was wrong" is
# to read this line afterwards: if `before` names a panel that was not on
# screen, that is the bug, on the record.
state_before="$(ipc focusGrab state)"
names_before="$(ipc focusGrab liveNames)"
log "before: state=${state_before:-<no answer>} names=${names_before:-<none>}"

# `release` clears every DISMISSABLE claimant (GlobalFocusGrab.dismiss()).
# PERSISTENT claimants -- the bar, the on-screen keyboard -- are left alone on
# purpose: they are supposed to hold input, and dropping them would be a
# different bug.
ipc focusGrab release >/dev/null 2>&1 || true

# ── 2b. Keyboard focus: clicks land, a field never takes input ───────────────
#
# WHY THIS IS A CAUSE OF ITS OWN. Everything above is about the POINTER: those
# end with clicks landing again. This one is about the KEYBOARD, and it reads
# differently from the chair -- the pointer is fine, clicks land everywhere, and
# a text field still never takes input, so the click that should put a caret in
# it looks like it did nothing. What can hold the keyboard:
#
#   * A STUCK SUBMAP. Every key goes to the submap, so nothing can be typed
#     anywhere -- and a field that IS focused still looks dead. Only one submap
#     exists on this desktop (virtual-machine, SUPER+ALT+F1), and while it is
#     entered this key would not run at all, which is why the bind is
#     submap_universal. Reset only when one is actually entered, so a deliberate
#     one is not thrown away on a stray press.
#   * THE SESSION LOCK. With GlobalStates.screenLocked set, the lock screen holds
#     the keyboard exclusively. `lock backdrop` reports it while UNLOCKED on
#     purpose, so it is read here -- and only REPORTED: unlocking from a keybind
#     would be a bug of its own, not a fix.
#   * THE APP, having missed a focus/enter event. Nothing can clear that from
#     here: this build rejects focusing by address from outside the config
#     (`hl.dsp.focus` wants a real window OBJECT -- see custom/general.lua), so
#     for that case this step contributes the log and nothing else.
#
# AND THE READ THAT NAMES A CULPRIT. `hyprctl layers` lists every mapped surface
# with its namespace and geometry, and it is the only place a PERSISTENT claimant
# shows up at all -- `focusGrab liveNames` names dismissable windows only, and
# the bar and the on-screen keyboard are persistent. A shell surface sitting
# full-screen over the field (the sleep notice and the search overlay both map
# full-panel here) is then in the log rather than guessed at afterwards.
submap_now="$(hyprctl submap 2>/dev/null | head -1)"
log "keyboard: submap=${submap_now:-<no answer>}"
if [ -n "${submap_now:-}" ] && [ "$submap_now" != "default" ]; then
    if hyprctl dispatch 'hl.dsp.submap("reset")' >/dev/null 2>&1; then
        log "keyboard: cleared submap '${submap_now}' -- every key was going to it"
    else
        log "keyboard: could NOT clear submap '${submap_now}'"
    fi
fi

locked="$(ipc lock backdrop | sed -n 's/.*locked=\([a-z]*\).*/\1/p')"
log "keyboard: session locked=${locked:-<no answer>}"

surfaces="$(hyprctl layers 2>/dev/null \
    | sed -n 's/.*namespace: \(quickshell:[A-Za-z0-9:-]*\).*/\1/p' | sort -u | tr '\n' ' ')"
log "keyboard: mapped shell surfaces: ${surfaces:-<none>}"

# ── 3. Clear the transient full-screen notice ───────────────────────────────
# The "going to sleep" wash is the one overlay surface mapped for the whole
# session, so it is the one that could sit under the pointer with nothing else
# visibly wrong. Asking it to clear guarantees it is idle.
ipc sleepNotice clear >/dev/null 2>&1 || true

# ── 4. Confirm -- and escalate only when the shell itself is the problem ────
sleep 0.3
state_after="$(ipc focusGrab state)"
log "after:  state=${state_after:-<no answer>}"

if ! shell_alive; then
    # No bar means the shell is not running or not drawing, so there is no grab
    # to release -- and no bar to click either. The honest fix is the same
    # failsafe SUPER+CTRL+B runs; hand over to it rather than growing a second
    # restart path.
    log "no bar surface -- falling back to a full shell reload"
    exec "$HOME/.config/hypr/custom/scripts/reload-shell.sh"
fi

if [ -n "$state_after" ]; then
    log "shell is up and answering -- held input cleared, grab released"
    exit 0
fi

# Mapped but MUTE. Cause 3, and the case this script used to call success. Two
# guards keep "mute" from meaning "busy", because a reload is the expensive
# answer and a wrong one costs the user every surface on the desktop:
#
#   * a reload already in flight -- reload-shell.sh writes that flag before it
#     kills anything and removes it on the way out;
#   * a shell that started moments ago and is still loading -- the same start
#     stamp shell.sh writes to refuse a duplicate launch. A cold load has
#     measured 9.4 s idle and past 50 s under load.
if recent "$runtime/ii-shell-reset.active" 120; then
    log "shell not answering, but a reload is already in flight -- leaving it alone"
    exit 0
fi

if recent "$runtime/ii-shell.started" 15; then
    log "shell not answering, but it started <15s ago (still loading) -- leaving it alone"
    exit 0
fi

log "shell is mapped but mute -- falling back to a full shell reload"
exec "$HOME/.config/hypr/custom/scripts/reload-shell.sh"
