#!/usr/bin/env bash
# ── Reload the desktop shell, fast ───────────────────────────────────────────
# Bound to  SUPER + CTRL + B  (see custom/keybinds.lua).
#
# Steps:
#   1. rebuild the shell binary   (cargo build --release -p quickshell, when a
#                                  source tree is present)
#   2. kill the running shell     (qs -c ii kill)
#   3. start it again IMMEDIATELY
#
# WHY STEP 3 LAUNCHES HERE INSTEAD OF WAITING FOR THE WATCHDOG.
#
# shell-watchdog.service only notices a dead shell on its next tick -- it is a
# 5 s poll -- so "kill it and let the watchdog bring it back" always spent
# somewhere between 0 and 5 seconds doing nothing at all before the shell even
# began to load. That dead time is pure latency on the one command whose whole
# point is to get the desktop back, and it is the difference between a reload
# that feels like a flicker and one that feels like a hang.
#
# So the launch happens right here, the moment the old process is gone, using
# the SAME launcher every other path uses (scripts/launch/shell.sh) -- the one
# that reaps dead-session shells, takes an flock so two launchers cannot both
# win, re-probes WAYLAND_DISPLAY and pins PATH. The watchdog is still kicked
# afterwards, but only as a safety net: if this launch somehow does not take,
# the 5 s poll catches it.
#
# There is deliberately NO verification here: no splash raised for it, no
# IPC readiness loop, no retry, no success card. The bar coming back is the
# confirmation. (That loop is what made the old failsafe -- reset-shell.sh,
# still on disk, still runnable by hand -- take tens of seconds.)
#
# Nothing on disk is changed by the reload: no settings, no wallpaper, no window
# layout, no open applications. hyprlock is not touched either -- a locked
# session must stay locked.

set -u

qs_config="${qsConfig:-ii}"
runtime="${XDG_RUNTIME_DIR:-/tmp}"
log_file="$runtime/qs-reload.log"

# The source tree the rebuild step builds. Defaults to the path this was
# written against; override with QUICKSHELL_SRC if the checkout lives elsewhere.
src="${QUICKSHELL_SRC:-$HOME/.config/quickshell/ii}"

log() { echo "[reload] $(date '+%H:%M:%S') $*" >>"$log_file" 2>/dev/null || true; }

# The session environment, probed ONCE here and reused by every card below.
# `session-env` connect-probes the Wayland sockets (~88 ms) and is what makes a
# card launched from a keybind land on the right display.
PROBED="$("$HOME/.local/bin/session-env" 2>/dev/null)" || PROBED=""

# Show one of the shell's small card configs. Detached, so it outlives this
# script.
show_card() {
    if [ -n "$PROBED" ]; then
        setsid env $PROBED qs -c "$1" >/dev/null 2>&1 </dev/null &
    else
        setsid qs -c "$1" >/dev/null 2>&1 </dev/null &
    fi
}

# ── 0. Say what is happening, before anything else ────────────────────────────
#
# FIRST -- ahead of the rebuild, the kill and the launch -- so the keypress has
# an answer in well under a second. Everything below adds up to a long silent
# stretch otherwise (the shell's own load alone is ~10 s).
#
# This was the splash spinner's job, but the splash reliably refuses on THIS
# path: shell.sh backgrounds it after its guards, and by the time it checks
# (after a 2.1 s /proc sweep) the replacement shell is already loading, so it
# logs "shell already running, not showing splash" and exits. /tmp/ii_splash.log
# shows exactly that on every reload -- which is why a reload had no feedback at
# either end.
show_card reloading-shell
log "reloading-shell card shown"

# ── 1. Rebuild ───────────────────────────────────────────────────────────────
#
# Conditioned rather than assumed: on a machine where quickshell is a PACKAGE
# (this one -- `qs` is /usr/bin/quickshell, no cargo on PATH, no Cargo.toml)
# an unconditional `cargo build` would fail with "command not found" on every
# press. So: build when the tree and the toolchain are both there, log it when
# they are not, and go on to the restart either way.
if [ -f "$src/Cargo.toml" ] && command -v cargo >/dev/null 2>&1; then
    log "rebuilding quickshell in $src"
    if (cd "$src" && cargo build --release -p quickshell) >>"$log_file" 2>&1; then
        log "rebuild ok"
    else
        log "rebuild FAILED -- restarting with the existing binary (see $log_file)"
    fi
else
    log "no cargo source at $src -- skipping the rebuild"
fi

# ── 2. Keep the watchdog out of this window ──────────────────────────────────
#
# The flag is read by shell-watchdog.sh, which stands its shell guard down
# while it exists and ignores a flag older than 120s. Written BEFORE the kill
# and removed on every exit path, so a reload that dies cannot leave the
# watchdog permanently disabled. Without it the poll can land between the kill
# below and the launch, and both launchers go for the shell at once.
reset_flag="$runtime/ii-shell-reset.active"
: >"$reset_flag" 2>/dev/null || true
trap 'rm -f "$reset_flag" 2>/dev/null || true' EXIT INT TERM

# ── 3. Kill the running shell ────────────────────────────────────────────────
#
# `qs kill` by config, not `pkill`: it is the same instance selection the IPC
# uses, so it cannot take down a `qs -p` helper window or a shell belonging to
# another config.
#
# The PIDs are read FIRST, from the same IPC (`qs list` prints them and costs
# ~65 ms). That is what makes the wait below cheap, and the cost of getting it
# wrong is worth spelling out: the obvious alternative -- the shared
# `shell_pids` helper -- sweeps all of /proc and shells out a `tr` per entry,
# measured at 2.1 s per call on this machine. A wait loop built on THAT pays
# 2.1 s for every 50 ms tick it takes, so a shell that lingered added seconds
# of dead time to every reload (measured: one run spent 8 s between `kill` and
# the launch). `kill -0` on a known pid costs microseconds.
pids="$(timeout 3 qs -c "$qs_config" list 2>/dev/null | sed -n 's/^ *Process ID: *//p')"

# ── 3b. Take the shell's ATTACHED helpers down with it ───────────────────────
#
# `qs kill` ends one process. Everything the shell spawned that is still
# attached to it -- the `nmcli monitor` wrapper, `udevadm monitor`, the
# `wl-paste` watchers, the python input watcher -- is left to the kernel, which
# reparents each one to init without telling it that its owner is gone. Until
# 2026-10-16 every reload therefore leaked a fresh set: sixteen `nmcli monitor`
# processes were alive at once, one per reload in forty minutes, ~11 MB each,
# and the sweeps in shell-watchdog.sh only reached them on their own 15 s tick.
#
# BEFORE THE KILL, deliberately: the parent link is what identifies a helper as
# the shell's, and the instant the shell dies that link is gone. Stopping them
# here is also why a reload no longer depends on the watchdog to clean up after
# it.
#
# Applications are NOT touched: they detach themselves with `setsid` and the
# helper only takes processes still in the shell's session that do not lead
# their own process group (see scripts/launch/shell-tree.sh for the reasoning,
# and `bash shell-tree.sh --self-test` for the synthetic case that proves it).
tree_helper="$HOME/.config/quickshell/ii/scripts/launch/shell-tree.sh"
if [ -r "$tree_helper" ]; then
    # The pid source is the same IPC as above; if it answered nothing, fall back
    # to the process name so the helpers are still taken down rather than left.
    [ -z "${pids// /}" ] && pids=$(pgrep -f '[q]s -c ii' 2>/dev/null | tr '\n' ' ')
    # shellcheck source=/dev/null
    . "$tree_helper"
    stopped=$(shell_tree_stop $pids)
    log "stopped $stopped attached helper process(es) alongside the shell"
else
    log "WARNING: $tree_helper not readable -- helpers will be left to the watchdog sweep"
fi

# Bounded: against a wedged shell this call waits for a socket that never
# answers (measured at 36 s on 2026-11-14), and the escalation below is what
# actually ends it.
timeout 5 qs -c "$qs_config" kill >>"$log_file" 2>&1 || true

# ── 4. Start it again, immediately ───────────────────────────────────────────
#
# The wait is not verification -- it is required. A new shell must not claim
# the layer surfaces and the global-shortcut registration while the old one is
# still letting go of them (two shells at once is the duplicate-bar bug), and
# shell.sh would decline to launch against a shell it still sees alive, leaving
# the desktop bare. So: wait for the exact pids to disappear, 50 ms ticks,
# 5 s bound.
alive_pids() {
    local p
    for p in $pids; do
        kill -0 "$p" 2>/dev/null && return 0
    done
    return 1
}
for _ in $(seq 1 100); do
    alive_pids || break
    sleep 0.05
done

# The list answered with nothing to wait on (an older/odd build, or a shell
# that had already gone). Fall back to the exact detector rather than assuming
# the process table is clean -- a shell that survived the kill would otherwise
# be "no shell" to this script and "already running" to shell.sh, which is the
# one combination that ends with nothing on screen.
if [ -z "${pids// /}" ]; then
    . "$HOME/.config/quickshell/ii/scripts/launch/shell-pids.sh"
    for _ in $(seq 1 40); do
        [ -n "$(shell_pids "$qs_config")" ] || break
        sleep 0.25
    done
fi

# shell.sh declines to launch if a start-stamp from the last 10 s exists. After
# we have just killed the shell that stamp is stale by definition, and leaving
# it would make shell.sh report "already running" while the desktop sat bare.
# ── 3c. A shell that answers nothing must still die ──────────────────────────
#
# WHY THIS EXISTS. `qs kill` is itself an IPC call. Against a shell whose main
# thread is wedged it waits for a socket that never answers, kills nothing, and
# this script then reports a launch that cannot take: the old shell keeps the
# layer surfaces and the global shortcuts, the new one cannot paint, and the
# desktop stays exactly as frozen as before the reload. Measured 2026-11-14: a
# wedged shell survived a full reload and had to be killed by hand.
#
# So the pids come from the process table rather than from IPC, and the
# escalation is TERM first (a shell that is merely busy gets to close its
# sockets), KILL after four seconds, then a moment for the kernel to release the
# surfaces before the launch below claims them.
. "$HOME/.config/quickshell/ii/scripts/launch/shell-pids.sh"
leftover="$(shell_pids "$qs_config")"
if [ -n "${leftover// /}" ]; then
    log "shell did not exit on its own (pids: $(echo $leftover)) -- escalating"
    kill -TERM $leftover 2>/dev/null || true
    for _ in $(seq 1 40); do
        still=0
        for p in $leftover; do kill -0 "$p" 2>/dev/null && still=1; done
        [ "$still" -eq 0 ] && break
        sleep 0.1
    done
    for p in $leftover; do
        if kill -0 "$p" 2>/dev/null; then
            log "pid $p ignored TERM -- sending KILL"
            kill -KILL "$p" 2>/dev/null || true
        fi
    done
    sleep 0.3
fi

rm -f "$runtime/ii-shell.started" 2>/dev/null || true

if [ -n "$PROBED" ]; then
    # setsid + redirected stdin so the launcher survives this script exiting;
    # shell.sh ends in `exec qs`, so it would otherwise run in our foreground.
    setsid env $PROBED bash "$HOME/.config/quickshell/ii/scripts/launch/shell.sh" \
        >>"$log_file" 2>&1 </dev/null &
    log "launched shell.sh (probed session) at $(date '+%H:%M:%S.%N')"
else
    # No live compositor to probe. Launch anyway -- on a bare background the
    # watchdog's next tick is the only other thing that would try, and it
    # would find the same environment.
    setsid qs -c "$qs_config" >>"$log_file" 2>&1 </dev/null &
    log "launched qs -c $qs_config directly (no session probe)"
fi

# ── 5. Hand the shell back to the watchdog ───────────────────────────────────
#
# The stand-down flag has done its job (nothing raced us into the kill/launch
# gap), so it comes off NOW rather than at exit. It is what suppresses the
# watchdog's shell guard, and the card below can keep this script alive for a
# minute or more -- a launch that failed must not be hidden from the watchdog
# for that long. The 10 s start-stamp shell.sh just wrote covers what remains.
rm -f "$reset_flag" 2>/dev/null || true

# A no-op when the service is already active (the normal case) and a real
# rescue when it is not: without it, a failed launcher would leave the desktop
# bare until someone noticed. After the launch, so its cost is off the critical
# path.
systemctl --user start shell-watchdog.service >>"$log_file" 2>&1 || true

# ── 6. The green "Quickshell reloaded" card ─────────────────────────────────
#
# The success signal, and the reason this is not a notification: there is no
# notification daemon on this desktop -- the shell IS the daemon -- so the only
# thing that can draw a confirmation is another qs process. `green-reloaded` is
# a tiny separate config: a green card bottom-left that quits itself after
# 3.5 s.
#
# Shown when the shell is actually ANSWERING, not on a timer. A card on a fixed
# delay is a lie whenever the load outruns the delay -- the shell has measured
# 9.4 s idle and past 50 s under load -- and this desktop's history is full of
# messages claiming success while the screen was still empty.
#
# This is a WAIT, not the old verification loop: no retry, no escalation, no
# second launch, nothing to fail on. If the shell never answers, the card
# simply never appears -- silence, which is the honest answer -- and the
# watchdog owns the recovery. Bounded so the script always exits.
# The gate is the COMPOSITOR's view, not the shell's: `hyprctl layers -j` costs
# ~13 ms and needs no qs process at all.
#
# Polling the IPC directly was both expensive and wrong. Expensive, because
# every poll spawns a whole quickshell binary -- on the CPU and GPU that are
# busy loading the real one. Wrong, because `qs ipc call` EXITS 0 while
# printing "No running instances", so a text match had to do the job an exit
# status cannot, and a loop that breaks on the text then re-checks with a
# second call can break early and disagree with itself (measured: it gave up
# after 6 s of a 90 s budget and reported no shell). One flag, one decision.
#
# A config whose QML has evaluated owns `quickshell:bar`; one that has not owns
# nothing. The quoted pattern keeps `quickshell:barPanel` out of the match.
shell_surfaces_up() {
    hyprctl layers -j 2>/dev/null | grep -q '"quickshell:bar"'
}
ready=0
for _ in $(seq 1 240); do
    if shell_surfaces_up \
       && [ -n "$(timeout 1 qs -c "$qs_config" ipc call bar gapState 2>/dev/null)" ]; then
        ready=1
        break
    fi
    sleep 0.25
done
if [ "$ready" -eq 1 ]; then
    # The load is over, so the "Reloading…" card goes and the success card takes
    # its place -- two cards at once read as two different outcomes.
    for _p in $(pgrep -f "[q]s -c reloading-shell" 2>/dev/null); do
        kill "$_p" 2>/dev/null || true
    done
    show_card green-reloaded
    log "shell answering IPC; Quickshell-reloaded card launched"
else
    # No card for a reload that never landed. The bar is the confirmation, and
    # a card here would be claiming something that is not true.
    log "shell did not answer IPC (~90s bound); no card shown"
fi

log "reload finished"
