#!/usr/bin/env bash
# Start the desktop shell exactly once.
#
# Called from Hyprland's autostart (custom/execs.lua). The guard makes it safe
# to call again (reload, re-login, a stray double hook): if a live `qs -c ii`
# process already exists, this exits without starting a duplicate -- the
# duplicate-bar and duplicate-popup problem, prevented at the source.
#
# Note the match style: `pgrep -f "[q]s -c ii"` uses a character class so the
# pattern never matches this very script's own command line (a plain pattern
# does, and a launcher that kills itself looks exactly like "the shell keeps
# dying").
set -u

# The shared, CORRECT way to ask "is a shell running?" -- see shell-pids.sh for
# why `pgrep -f "qs -c ii"` cannot be used for this and what it costs when it
# is. Sourced once, here, so every check below is exact by construction.
. "$HOME/.config/quickshell/ii/scripts/launch/shell-pids.sh"

# The config this script launches. Set here rather than relying on the
# sourced default, because `set -u` is on: an unset `qsConfig` would abort the
# script at the first check instead of launching a shell. Callers that support
# an override still export it before invoking this file.
: "${qsConfig:=ii}"

# ═══ THE SINGLE-INSTANCE GUARD (atomic, 2026-09-30)══════════════════════
#
# This used to be a bare `pgrep -f "[q]s -c ii"`, and it sat BELOW the
# wallpaper prune. That was check-then-act with a slow gap in the middle, and
# THREE callers can arrive within the same second: Hyprland's autostart
# (hyprland/execs.lua), custom/execs.lua on a config reload, and the systemd
# watchdog (shell-watchdog.sh polls every 5s). Two of them can both see "no
# process yet", both pass, and both `exec qs -c ii`.
#
# Not theoretical -- observed live on 2026-09-30: pids 33427 and 33450 both
# running `qs -c ii`, each owning its own bar, edgeReveal, screenCorners and
# desktopIndicator layers. Everything drawn twice looks fine (identical
# surfaces stacked), but a SECOND instance registers its OWN global shortcuts,
# so one SUPER tap toggles appSearchOverlayOpen in BOTH. That is the "sometimes
# two menu guides" report: it was two shells, not two toggles.
#
# `flock` makes claim-and-check atomic. Whoever takes the lock owns the
# decision; the other callers block, then find the live process and exit.
#
# The lock is taken AFTER the session probe and the reap below, NOT before
# them. That order is the whole fix, and getting it wrong is what produced
# the black screen this file's comments kept describing.
#
# The descriptor is held across the exec, so the lock lives as long as the
# shell it starts -- the `qs` process itself is the lock holder. A lock taken
# FIRST therefore turns into a self-inflicted deadlock: the first login's
# shell grabs it and never lets go, and every later `shell.sh` (each login,
# each config reload, every 5s watchdog tick) dies at `flock -n` before it
# ever reaches the code that notices the running shell belongs to a different
# session and reaps it. The stale shell could never be replaced, and the
# new session never got a bar -- a bare compositor showing
# misc:background_color, which is near-black. `hyprctl configerrors` is
# empty the whole time, so there was nothing to debug from the inside.
#
# With the lock taken last, the order is: work out which session is live,
# exit if that session already has a shell, kill the ones that do not, and
# only then contend for the lock. Reaping first is what makes the lock
# reachable again -- killing a lock holder is what releases it.

# Which session are we ACTUALLY in? Probed before the guard, because the
# guard is about to compare against it. The probe further down this file
# cannot serve that purpose: it runs after the decision has already been made.
#
# ── WAIT FOR THE COMPOSITOR (2026-10-04) ──────────────────────────────────
# The probe is retried for a bounded time instead of being taken once.
#
# Hyprland runs this script from its autostart, which fires while the config
# is being parsed -- BEFORE the Wayland socket has a listener. session-env
# requires a connectable wayland-N and at least one monitor, so at that
# instant it legitimately reports "no compositor". The old code took that
# single answer at face value, fell through the `else` branch below (no live
# session, but also no running shell, so nothing to exit on), took the lock
# and `exec qs` into a socket with no server behind it. qs died in 11 ms with
#
#     Failed to create wl_display (Connection refused)
#     FATAL: no Qt platform plugin could be initialized
#
# and took a 60 MB coredump with it. Nothing relaunched it until the systemd
# watchdog's next 5 s tick, so every login showed ~10 s of bare compositor
# (no bar, no wallpaper, no panels) before the desktop appeared. Measured on
# 2026-10-04: Hyprland up at 14.0 s, first qs died at 18.17 s, real shell at
# 28 s.
#
# Hyprland IS ready a moment later, so the fix is to wait for it rather than
# launch into nothing. The bound matters as much as the wait: on a real tty
# (no compositor, ever) this must still give up quickly and let the caller
# retry, so it is ~20 s, not infinite. 0.25 s apart, because the whole point
# is to shave the dead window down rather than replace 10 s with a different
# number.
LIVE_WD=""
probe_wd() {
    PROBE_WD="$("$HOME/.local/bin/session-env" 2>/dev/null)" || return 1
    LIVE_WD="$(echo "$PROBE_WD" | sed -n 's/^WAYLAND_DISPLAY=//p')"
    [ -n "$LIVE_WD" ]
}
if ! probe_wd; then
    waited=0
    while [ "$waited" -lt 80 ]; do          # 80 x 0.25 s = 20 s
        sleep 0.25
        waited=$((waited + 1))
        probe_wd && break
    done
    if [ -z "$LIVE_WD" ]; then
        # Still nothing. A headless tty, or a compositor that never came up:
        # leave the decision to the caller (the watchdog retries every 5 s)
        # rather than exec'ing a shell that cannot possibly draw.
        exit 0
    fi
fi

# Is a shell already running FOR THIS SESSION?
#
# The old test was a bare `pgrep -f "qs -c ii"`, which answers "is a shell
# running ANYWHERE?", and a `qs` belonging to a session that has since died
# kept that answer "yes" indefinitely. The reason it can outlive its session
# at all: the shell watchdog is a systemd *user* service (WantedBy=default.
# target), and the user manager is started once per boot and survives every
# logout -- so an orphaned `qs` stayed bound to a socket with no server.
#
# The next login then started a real compositor that never got a shell: no
# bar, no wallpaper, no panels, no shell-integrated keybinds. That is a black
# screen, and it is not a config error -- hyprctl reports 0 errors and all
# 195 binds while the desktop is invisible.
#
# So the check is per-session. Each running shell's WAYLAND_DISPLAY is read
# from /proc and compared with the display that is live right now:
#   match    -> this session's shell is already up, nothing to do
#   mismatch -> it belongs to a dead session, and it MUST be reaped, because
#               left alone it blocks this session's shell forever
if [ -n "$LIVE_WD" ]; then
    STALE=""
    for pid in $(shell_pids "$qsConfig"); do
        wd="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
              | sed -n 's/^WAYLAND_DISPLAY=//p')"
        if [ "$wd" = "$LIVE_WD" ]; then
            exit 0
        fi
        STALE="$STALE $pid"
    done
    for pid in $STALE; do
        if kill "$pid" 2>/dev/null; then
            echo "[shell] reaped stale shell $pid (not on $LIVE_WD)" \
                >> /tmp/ii_shell.log
        fi
    done
    # Give the reaped shell a moment to release its layers and its lock
    # before this one claims them, so the two cannot overlap on screen.
    [ -n "$STALE" ] && sleep 1
else
    # No live compositor to attach to (the wait above timed out). Keep the old
    # conservative answer and let the caller retry; launching here would bind
    # to nothing.
    exit 0
fi

# Contend for the lock only now that the reap has run, so the lock is
# reachable. Bounded wait rather than -n: a concurrent launcher that is
# mid-exec holds it for a moment, and failing instantly there would just
# defer to the next tick for no reason.
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/ii-shell.lock"
flock -w 15 9 || exit 0

# Re-check under the lock. Another launcher may have won the race between
# the reap above and here, and two `qs -c ii` processes is the duplicate-bar
# bug this file exists to prevent.
if [ -n "$LIVE_WD" ]; then
    for pid in $(shell_pids "$qsConfig"); do
        wd="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
              | sed -n 's/^WAYLAND_DISPLAY=//p')"
        [ "$wd" = "$LIVE_WD" ] && exit 0
    done
fi

# A launcher that just released the lock and exec'd qs is not visible to
# pgrep yet, so the loop above cannot see it. The stamp closes that window:
# if a shell was started within the last few seconds, this is a duplicate
# caller, not a missing shell.
STAMP="${XDG_RUNTIME_DIR:-/tmp}/ii-shell.started"
if [ -f "$STAMP" ] && [ $(( $(date +%s) - $(stat -c %Y "$STAMP" 2>/dev/null || echo 0) )) -lt 10 ]; then
    exit 0
fi

# ── Show something while this takes its 2.5 seconds ───────────────────────
#
# Every guard above has passed, so a shell IS about to be started and the
# screen is about to be Hyprland's bare background colour for a couple of
# seconds. That is the "black screen on login" this puts an end to.
#
# Launched detached and in the background because this file ends in `exec`:
# the splash has to outlive the hand-off, and splash.sh spends its time
# watching for the shell it is waiting on rather than returning immediately.
#
# It is placed AFTER every guard on purpose. Showing it earlier would mean
# flashing a loading indicator on the many paths that correctly exit above --
# a shell already running, a lost race, a duplicate caller -- and a splash
# that appears and vanishes for no reason is worse than no splash.
#
# ── CLEAR THE LAST SESSION'S "THE BAR IS UP" CLAIM FIRST ──────────────────
#
# Reaching this line means a shell is about to be started and none is running
# for this session, so any ii-bar-visible.json on disk was written by a shell
# that is gone. And it is FRESH, not stale: Bar.qml refreshes it every 2 s
# while a bar is up, so logging out leaves {"visible":true,"ts":<seconds
# ago>} waiting for the next login.
#
# Anything that reads it then believes a desktop is already on screen.
# Measured on 2026-10-11 (the login sequence replayed): the login cover read
# that freshly-written corpse marker, decided the desktop was up, and refused
# to appear -- the black screen this whole block exists to prevent, with the
# indicator disabled by the very session that had just ended. The compositor's
# gesture gate (readBarVisible in custom/general.lua) would likewise arm bar
# gestures against a bar that is not there.
#
# Deleting it costs nothing: that reader treats a MISSING file as "cannot
# know" (nil), not as an error, and the new shell republishes the file within
# a second of its bar appearing.
rm -f "${XDG_RUNTIME_DIR:-/tmp}/ii-bar-visible.json" 2>/dev/null || true

setsid bash "$HOME/.config/quickshell/ii/scripts/launch/splash.sh" \
    >/dev/null 2>&1 </dev/null &

# Wallpaper-carousel maintenance BEFORE the shell starts: drop history
# entries whose image file is gone, so no blank ghost card can ever render.
# Done here (not in QML) because it must complete before quickshell reads the
# history file -- a QML-side prune races the shell's own startup writes.
#
# It runs AFTER the guard now. It used to run before, which was the worst
# possible order: a python3 startup (tens of ms, and it touches the disk) sat
# in exactly the window where a racing second launcher saw no process and
# sailed past the check. Guard first, work second.
python3 "$HOME/.config/quickshell/ii/scripts/prune-wallpaper-history.py" \
    "$HOME/.local/state/quickshell/wallpaper-history.json" >> /tmp/ii_shell.log 2>&1 || true

# Re-derive the session environment before exec'ing.
#
# Whichever way we were invoked, a wrong WAYLAND_DISPLAY means `qs` exits
# instantly with "Failed to create wl_display (Connection refused)" and the
# bar never appears -- which is exactly the "shell did not load" symptom. The
# inherited value is not always right: a relaunch from a systemd user unit
# inherits a snapshot taken when the user manager started (once per boot),
# while the display number is allocated per login, so it drifts a session or
# two behind. session-env connect-probes the sockets and reports the
# compositor that is actually listening, which cannot go stale.
#
# Only adopted when the probe succeeds, so a headless tty keeps its own
# (empty) environment and the failure stays visible in the log instead of
# becoming a wrong-display launch.
if PROBED="$("$HOME/.local/bin/session-env" 2>/dev/null)"; then
    if [ "${WAYLAND_DISPLAY:-}" != "$(echo "$PROBED" | sed -n 's/^WAYLAND_DISPLAY=//p')" ]; then
        echo "[shell] WAYLAND_DISPLAY ${WAYLAND_DISPLAY:-unset} -> live session" \
            >> /tmp/ii_shell.log
    fi
    eval "export $PROBED"
fi

# PIN THE PATH. Whatever starts this script, its PATH is what the shell and
# every app it launches will see -- and the two launchers disagree:
# Hyprland's autostart inherits the login PATH (has ~/.local/bin), while a
# systemd user unit gets the manager's compiled-in default
# (/usr/local/bin:/usr/bin -- no ~/.local/bin). The visible symptom of the
# bad case: the shell's app-search probes each desktop entry's executable
# against ITS OWN PATH and hides entries whose binary it cannot find, so
# anything installed in ~/.local/bin (the vendor app) vanished from
# the SUPER menu whenever the watchdog had (re)started the shell, and came
# back when Hyprland had. Setting it here makes both paths identical.
# PIN THE CURSOR THEME.
#
# Same reasoning as the PATH pinning below, and the same trap: the two launchers
# disagree. Hyprland's autostart inherits the login environment (env.lua sets
# XCURSOR_THEME there), but the systemd watchdog gets the user manager's, which
# only sees environment.d. Without setting it here, which launcher happened to
# start the shell decided whether the desktop could draw a hand cursor at all.
#
# Qt renders no cursor image of its own on Wayland -- it asks the compositor for
# a SHAPE and needs a loaded theme to turn that shape into a name. With no
# theme loaded, Qt silently drops every cursorShape request and the default
# arrow is all that ever appears.
#
# WHICH theme, though: the pin used to name `capitaine-cursors`, which is not a
# theme this desktop otherwise uses (env.lua and environment.d both name
# Bibata-Modern-Ice) and which cannot draw every shape the shell asks
# for: it ships `sb_h_double_arrow` and `sb_v_double_arrow` but not
# `bd_double_arrow` or `fd_double_arrow`, the names Qt looks up for the two
# diagonal resizes (`ls /usr/share/icons/capitaine-cursors/cursors`). A shape a
# theme cannot name is a cursorShape that silently does not happen, which is
# exactly the class of bug this pin exists to prevent.
#
# FORCED, not merely "set if nothing named one" (2026-10-23). The shell used to
# inherit whatever its launcher had -- and an inherited name can be one that is
# no longer installed. That is exactly what happened: this session still carried
# `XCURSOR_THEME=Bibata-Modern-Ice-NoLine` from before those borderless themes
# were removed, so the shell exported a theme that does not exist, and EVERY app
# it launched inherited it. A toolkit cannot report that: libXcursor finds no
# images, and the app draws its built-in fallback instead -- the plain white
# pointer with no rim that was showing up inside TradingView, the browser and
# the rest of the shell-launched apps while the compositor (which has the real
# name) drew the Bibata one. That is the "cursor is full white in some apps"
# report, and it is not a theme choice: it is a name that resolves to nothing.
# The installed name is the only thing this desktop ever wants, so it is stated
# here unconditionally -- the same thing the app launchers do for the same
# reason (see the XCURSOR_THEME block in ~/.local/bin/freebuff-desktop).
export XCURSOR_THEME=Bibata-Modern-Ice
# Nothing ever swaps it per mode or per app: the pointer is one artwork for the
# whole session, so hovering a light or a dark window cannot change it.

case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;                      # already present
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

cd "$HOME/.config/quickshell/ii"

# RELEASE THE LOCK BEFORE EXEC. This is the second half of the deadlock fix.
#
# fd 9 is inherited across `exec`, so `qs` starts life holding the lock --
# and so does EVERY process `qs` spawns (hyprsunset, mpv, notification
# daemons, anything the bar launches). The lock therefore outlives the shell
# by however long the longest-lived child lives, which on this machine is
# "forever": hyprsunset sat on fd 9 and the lock was still taken long after
# the `qs` that caused it was gone. Any launcher reaching the lock then
# waited out `flock -w 15` and exited, so the shell could never be restarted
# again -- not by the next login, not by a config reload, not by the
# watchdog. The desktop stayed a bare compositor: no bar, no wallpaper, no
# panels, just misc:background_color, which is near-black. That is the black
# screen, and `hyprctl configerrors` stayed empty throughout.
#
# Closing the descriptor here is safe because the claim-and-check that the
# lock protects is already finished: the probe ran, the stale shells were
# reaped, and the re-check above confirmed no shell owns this session. The
# remaining race -- another launcher arriving in the microseconds between
# this close and `qs` becoming visible to pgrep -- is covered by the stamp
# file below, and costs a duplicate bar in a window far shorter than the
# watchdog's 5s tick anyway.
exec 9>&-
: > "${XDG_RUNTIME_DIR:-/tmp}/ii-shell.started" 2>/dev/null || true

# ── THE SHELL RENDERS ON THE CHIP THE SCREEN IS PLUGGED INTO (2026-11-01) ──
#
# On a hybrid laptop two chips exist: the integrated one drives the panel, the
# discrete card is used only when asked. The session used to
# export __NV_PRIME_RENDER_OFFLOAD/__GLX_VENDOR_LIBRARY_NAME/__VK_LAYER_NV_optimus
# globally, which told EVERY program -- this shell included -- to render on the
# discrete card. Every frame was then rendered on one chip and copied to the
# other for display: both stayed awake, the discrete card could never reach its
# low-power state, and the desktop paid a copy per frame for nothing.
#
# Measured on 2026-11-01 with the variables in effect: the card sat at 31-41%
# utilisation in 80 of 80 samples over 20 s, P5, ~10 W, with the desktop idle
# and nothing open but a browser and this shell. That is the "why is my GPU at
# 40% when nothing is running" report, and the shell was the client.
#
# The variables are gone from environment.d and the fish profile; this unset is
# what makes the change reach the shell TODAY, because the systemd watchdog that
# relaunches it holds the login environment from before the edit. `nvidia-run`
# in the fish profile is the per-program opt-in for anything that wants the
# discrete card on purpose.
unset __NV_PRIME_RENDER_OFFLOAD __GLX_VENDOR_LIBRARY_NAME __VK_LAYER_NV_optimus

exec qs -c ii >> /tmp/ii_shell.log 2>&1
