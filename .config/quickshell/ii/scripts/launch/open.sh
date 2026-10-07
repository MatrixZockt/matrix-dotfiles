#!/usr/bin/env bash
# Launch a program and stay with it, so a program that never arrives can say so.
#
#   open.sh "System Monitor" "missioncenter"
#   open.sh "Terminal" "kitty -1"
#
# The shell's "something is starting" card has two honest endings: the program's
# window appears (the shell notices) or the program dies without one (this
# script notices). There is no third "it has been fifteen seconds, give up"
# ending, because that one is a guess -- and it guesses wrong in both directions,
# calling slow programs broken and broken programs slow.
#
# So the shell runs this instead of exec'ing the app itself:
#
#   * this process is NOT a child of the shell (the shell starts it detached),
#     so a shell reload -- which happens every time a QML file is saved -- cannot
#     kill the app that is running inside it;
#   * when the command exits non-zero, that is a launch that failed, and the
#     card is told. The shell ignores the report if the app's window did turn up
#     earlier: an app that closes badly an hour later is an app closing.
#
# Arguments are two separate strings, never one shell line, so neither the label
# nor the command needs quoting by the caller -- which is the whole reason this
# is a script and not a `bash -c` built inside the shell's QML.
set -u

label="${1:-}"
command="${2:-}"

if [ -z "$command" ]; then
    echo "open.sh: nothing to run" >&2
    exit 2
fi

shell="${II_SHELL_NAME:-ii}"

# Close-to-tray apps (TrayApps.enforceTray) read a window appearing where
# there was none as the app dragging itself out of the tray, and put it
# straight back. A launch from THIS launcher is the user letting it out, so
# say so before the window exists -- `allow` matches this command against
# the registry's own launch string and is a no-op for every other app.
qs -c "$shell" ipc call trayapps allow "$command" >/dev/null 2>&1 || true

# The command is a shell line on purpose: entries in the launcher are shell
# lines (`kitty -1 --hold=yes fish -i -c 'passwd'`), and re-splitting them here
# would break the ones that quote their own arguments.
#
# GPU mode: if the session's GPU switch is on, hand the app to gpu-run, which
# puts the NVIDIA dGPU in its environment.
#
# This is the ONE place every app in the launcher goes through -- the shell
# calls it from GlobalStates.qml, one call per click -- so honouring the switch
# here covers every application without a single .desktop file being edited.
# That is the whole point: the policy is one switch, not one setting per app.
#
# `gpu-run` is exec'd, not sourced, so the app's own environment is built by
# it rather than patched afterwards, and an app that re-executes itself
# (Chromium, Electron, Freebuff's updater) keeps the variables because it
# inherited them the normal way.
gpu_state="${XDG_CONFIG_HOME:-$HOME/.config}/gpu-mode/state"
if [ -f "$gpu_state" ] && [ "$(cat "$gpu_state" 2>/dev/null)" = on ]; then
    command="gpu-run $command"
fi

# The stamp is the guard for the shell's own error report. Everything this
# script starts carries II_OPENED_BY_II in its environment, inherited by the
# app and everything it later spawns -- which matters because modern apps
# RE-EXEC themselves: Freebuff's updater swaps the binary and starts the new
# copy, Chromium-based apps respawn their renderer host. Those children run
# shell lines too, and one of them landing back here (a wrapper, a .desktop
# helper, an AppImage that shells out) used to be able to fail for its own
# reasons -- and report "Couldn't open Freebuff" for a launch that had
# succeeded long ago. The stamp says: this process tree came from the shell's
# launcher, so an inner exit is not the launch's verdict.
#
# Backgrounded so that `$!` exists to be recorded, then waited on below so
# this script still reports the app's real exit status to the shell's
# "something is starting" card. Running it in the foreground, as this used
# to, reported the status correctly but left no pid to announce.
env II_OPENED_BY_II=1 bash -c "$command" &
child=$!

# ── Announce that pid to the compositor ───────────────────────────────────
#
# The compositor wants one thing from this script that it cannot work out on
# its own: whether a given window came from here or from somewhere else. That
# matters because the same app launched two ways wants two different things --
# Bitwarden from the Brave extension is a small utility panel that must float,
# while Bitwarden from the SUPER menu is an app you will sit and use, and must
# attach to the layout. Class, title and geometry are identical either way, so
# launch origin is the only signal that can tell them apart, and it is the one
# signal only the launcher has.
#
# It is a pid, not a class, for a measured reason. The obvious channel is the
# environment stamp above, but Chromium and Electron clear their own dumpable
# flag at startup, so /proc/<pid>/environ of the process that owns the window
# is Permission denied -- verified on this machine, window pid 1375421,
# comm=electron. The intermediates that carried the variable were exec'd away,
# so the pid that had the stamp and the pid that cannot be read are the SAME
# process. ppid comes from /proc/<pid>/stat and is readable whatever that flag
# says, so the compositor walks up from the window's pid and matches the pid
# recorded here instead.
#
# `$child` is the pid of the process this script starts. `bash -c` with a
# single command execs rather than forks, so that pid survives all the way
# down through any wrapper scripts and lands on, or above, the window's own
# process.
#
# The file is rewritten on every launch and pruned to the last five minutes,
# so it stays a few lines long and a stale entry cannot claim a window the
# user opened by hand much later. The compositor only honours the last 45
# seconds, which is the window in which a slow app can still be mapping.
registry="${XDG_RUNTIME_DIR:-/tmp}/ii-super-launched"
now=$(date +%s)
{
    tmp="${registry}.$$"
    : >"$tmp"
    if [ -f "$registry" ]; then
        while read -r _pid _ts; do
            [ -n "${_pid:-}" ] || continue
            if [ "$((now - ${_ts:-0}))" -le 300 ]; then
                printf '%s %s\n' "$_pid" "$_ts" >>"$tmp"
            fi
        done <"$registry"
    fi
    printf '%s %s\n' "$child" "$now" >>"$tmp"
    mv -f "$tmp" "$registry" 2>/dev/null || rm -f "$tmp" 2>/dev/null
} 2>/dev/null || true

# `wait` returning early because this shell was signalled must not be
# reported as the app's failure, which would turn an interrupted wait into a
# false "couldn't open <label>" toast.
#
# The retry therefore has to be bounded AND has to check that there is
# anything left to wait for. `[ "$status" -gt 128 ] && continue` on its own
# was neither: bash reports 128+N for a wait interrupted by a trapped signal
# just as it does for a child killed by signal N, so once this script's own
# shell went away (a shell reload, a closed terminal, anything that SIGHUPs
# it) every `wait` answered 129 and the loop spun forever.
#
# Measured, not theorised: two of these were found in state R -- running, not
# waiting -- one for 4h53m and one for 2h59m, each with no child left to wait
# for, each burning a core. So the two conditions are both required: the
# status must still look like an interruption, AND the child must still
# exist. `kill -0` is the honest test for the second (it costs nothing, needs
# no privilege, and cannot be fooled by a recycled pid because the wait below
# is on the same pid), and the counter is the backstop for a signal storm
# that somehow keeps satisfying it.
status=0
retries=0
while :; do
    wait "$child"
    status=$?
    # Only an interrupted wait, and only while there is still a process to
    # interrupt. Once the child is gone, `wait` keeps answering with the
    # stale status forever -- which is the spin this replaces.
    if [ "$status" -gt 128 ] && kill -0 "$child" 2>/dev/null && [ "$retries" -lt 64 ]; then
        retries=$((retries + 1))
        continue
    fi
    break
done

if [ "$status" -ne 0 ]; then
    # A precise verdict where one is cheap: the single most common dead launch
    # is a desktop entry pointing at a path that is not there (an app moved or
    # an updater replaced it) -- bash answers that with 127 before the program
    # is even attempted. Name the target, not the mechanism.
    head="${command%%[[:space:]]*}"
    reason=""
    if [ "$status" -eq 126 ] || [ "$status" -eq 127 ]; then
        reason=" (${head}: not found)"
    fi
    qs -c "$shell" ipc call loading error "Couldn't open ${label:-that}${reason}" >/dev/null 2>&1
fi

exit "$status"
