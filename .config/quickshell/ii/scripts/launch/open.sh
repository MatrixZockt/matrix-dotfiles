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
#
#   open.sh <label> <command> [tray-allowed]
#
# The optional third word says the caller has ALREADY taken the tray permission
# (see the allow call below): a third process that exists only to save a fourth.
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
# ── The tray permission, unless the caller already took it ───────────────
#
# This call is the same code the shell itself runs, reached by starting a whole
# Qt client first. Measured on this machine: 34-43ms of wall time, on every
# single launch, serialized BEFORE the app is exec'd -- the largest single piece
# of what the launcher adds to an app's startup (spawn -> window: 186ms through
# here against 126ms for the same binary started directly).
#
# The shell knows the command when the user clicks it, so it takes the
# permission itself (microseconds, in-process) and passes `tray-allowed` as the
# third argument, which is what this test looks for. The call stays for every
# other caller -- a hand-run open.sh, a script, a notification action -- so
# nothing outside the shell changes behaviour.
if [ "${3:-}" != "tray-allowed" ]; then
    qs -c "$shell" ipc call trayapps allow "$command" >/dev/null 2>&1 || true
fi

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
#
# stderr goes to a log rather than into the shell's own:
#   * a failed launch has to be able to say WHY (the card used to read
#     "Couldn't open Freebuff (freebuff: not found)" and nothing else, because
#     the only reason anyone could see was bash's 127), and the app's own last
#     line -- a missing shared library, a QML type that would not resolve, a
#     crash trace -- is the sentence that actually explains it;
#   * it is per-launch and truncated, so the file is a few lines long and what
#     the card quotes is from THIS launch, not the one before it.
errlog="${XDG_RUNTIME_DIR:-/tmp}/ii-${shell}-launch-errors.log"
: >"$errlog" 2>/dev/null || errlog="/dev/null"

# ── An app that is being UPDATED, not an app that is broken ────────────────
#
# An updater swaps the running program's file by writing the new one over it
# (electron-updater replaces its AppImage in place; pacman rewrites a package's
# binaries). The kernel refuses to exec a file that is open for writing, so
# every launch during that window dies with ETXTBSY:
#
#     bash: line 1: /path/App.AppImage: Text file busy        (exit 126)
#
# and the card reported that as a verdict -- "Couldn't open Freebuff (…: Text
# file busy)" -- for a program that was two seconds from being perfectly
# launchable. The sentence is true and the conclusion is wrong: nothing is
# broken, the file is simply still being written.
#
# So the failure is recognised here (the kernel's own four words on the
# launcher's stderr are the signature, not the exit status, which is an
# ordinary 126) and the launch is TRIED AGAIN while the file stays busy. An
# app mid-update is a launch that has to wait, not one that has to fail.
updateRetrySecs=1.5   # between attempts
updateAttemptsMax=9   # ~12s of trying: past any AppImage swap on this box

program_is_being_updated() {
    [ "${status:-0}" -ne 0 ] || return 1
    tail -n 5 "$errlog" 2>/dev/null | grep -qi 'text file busy'
}

# ── Start the program ─────────────────────────────────────────────────────
#
# A function because a launch can have to be retried (the update loop below);
# each attempt is a fresh process, a fresh error log and its own renewal loop.
start_program() {
    # Truncated per attempt, so what the card quotes is from THIS launch.
    : >"$errlog" 2>/dev/null || true
    # The variable is set INLINE rather than through `env`: an assignment before
    # a background command is exported to it anyway, and the `env` process was
    # one more exec on the critical path (measured ~5ms) for nothing.
    II_OPENED_BY_II=1 bash -c "$command" 2>>"$errlog" &
    child=$!
    start_renewer
    announce_child
}

# ── Keep the shell's verdict honest while the app is still alive ──────────
#
# The shell judges a launch that has shown no window after ten seconds, and ten
# seconds is exactly the edge of a slow cold launch on this machine: it has said
# "Couldn't open Freebuff" for apps that were two seconds from drawing. The
# shell cannot tell "still starting" from "never coming" -- it only has the
# window list; this script is the app's PARENT and has the process. So while the
# app lives, the wait is renewed: the ten-second clock restarts, and the verdict
# is left to the one thing that knows, the exit status below.
#
# Bounded on purpose. A process that is alive and wedged for a minute is a
# launch that has to end somewhere, and "no window after a minute" is then an
# honest sentence rather than a guess.
renew_max=15          # 15 renewals x 4s = a minute of grace
renewer=""

# One renewer per running program, and it watches the CURRENT one: a retried
# launch has a new pid, and a renewer still following the dead attempt would
# give up on its next tick -- dropping the slow-launch protection at exactly
# the moment the program that finally started needs it.
start_renewer() {
    [ -z "$renewer" ] || kill "$renewer" 2>/dev/null || true
    (
        renews=0
        while [ "$renews" -lt "$renew_max" ]; do
            sleep 4
            kill -0 "$child" 2>/dev/null || break
            renews=$((renews + 1))
            qs -c "$shell" ipc call loading renew "${label:-}" >/dev/null 2>&1 || true
        done
    ) </dev/null >/dev/null 2>&1 &
    renewer=$!
}

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
# Rewritten on every attempt: the pid that matters is the one that ended up
# running, and the earlier attempts died before any window could exist.
announce_child() {
    local registry="${XDG_RUNTIME_DIR:-/tmp}/ii-super-launched"
    local now
    now=$(date +%s)
    {
        local tmp="${registry}.$$"
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
}

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
wait_for_program() {
    status=0
    local retries=0
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
}

start_program
wait_for_program

# ── Try again while the file is still being written ───────────────────────
#
# The wait is kept alive (`loading renew`) through the retries on purpose: a
# busy file cannot have opened a window, so without this the shell's own "no
# window after ten seconds" verdict would call the launch a failure while it is
# still demonstrably an update in progress.
#
# On the first retry the card is told what is actually happening, which is the
# thing that was missing: "Freebuff is updating…" instead of an error. The text
# is set BEFORE the attempt that may succeed, so the window that arrives next is
# still new to the shell's window watcher and dismisses the card as usual.
update_waits=0
while [ "$update_waits" -lt "$updateAttemptsMax" ] && program_is_being_updated; do
    update_waits=$((update_waits + 1))
    if [ "$update_waits" -eq 1 ]; then
        qs -c "$shell" ipc call loading display "${label:-The app} is updating…" >/dev/null 2>&1 || true
    fi
    sleep "$updateRetrySecs"
    qs -c "$shell" ipc call loading renew "${label:-}" >/dev/null 2>&1 || true
    start_program
    wait_for_program
    # A launch that worked ends the loop; so does a failure that is anything
    # other than the file still being written (the condition above decides
    # that, from the status and stderr of this attempt).
    [ "$status" -eq 0 ] && break
done

# The renewal loop has done its job (or the app is gone); it must not outlive
# this script, or a closed app would keep re-arming a wait that is over.
kill "$renewer" 2>/dev/null || true

if [ "$status" -ne 0 ]; then
    # ── Out of patience, not out of luck ─────────────────────────────────
    #
    # Every attempt was refused because the program's file is still being
    # written. That is not "couldn't open X": X is fine, it is being replaced,
    # and the honest sentence says so and says what to do about it.
    if [ "$update_waits" -ge "$updateAttemptsMax" ] && program_is_being_updated; then
        qs -c "$shell" ipc call loading error \
            "${label:-That app} is still updating — try again in a moment" >/dev/null 2>&1
        exit "$status"
    fi

    # ── Why it failed, in the card itself ────────────────────────────────
    #
    # The card used to carry the bare sentence "Couldn't open X" for every
    # failure except the one bash makes cheap to name (126/127 -- a desktop
    # entry pointing at a path that is not there). The other cases were silent:
    # an app that dies of a missing library, one that aborts, one whose config
    # it cannot read, one that exits non-zero on purpose. So the reason is built
    # here, cheapest first:
    #
    #   126        cannot execute (not a program, or no permission)
    #   127        not found -- name the TARGET, which is the useful half
    #   > 128      killed by signal N (bash reports 128+N for that)
    #   anything   exit N
    #
    # and then, if the app left anything on stderr, its last real line -- the
    # sentence that says what actually went wrong -- is appended.
    head="${command%%[[:space:]]*}"
    # The app's own last word, if it had one. Carriage returns and leading
    # blanks are stripped (progress bars and TUI spinners leave them), bash's
    # own `line 1:` frame is dropped, and the line is capped so a runaway trace
    # cannot turn the card into a paragraph.
    detail="$(tail -n 5 "$errlog" 2>/dev/null | tr -d '\r' \
        | grep -v '^[[:space:]]*$' | tail -n 1 \
        | sed 's/^bash: line [0-9]*: //' | cut -c1-140)"

    case "$status" in
        126|127)
            # "Not there" or "not runnable", and the app's own line says which
            # target -- it names the right word even when the command is a shell
            # line (`cd somewhere && the-app`), where `head` would name `cd`.
            kind="not found"
            [ "$status" -eq 126 ] && kind="cannot execute"
            if [ -n "$detail" ]; then reason=" (${detail})"
            else reason=" (${head}: ${kind})"; fi
            ;;
        *)
            if [ "$status" -gt 128 ]; then
                sig=$((status - 128))
                sig_name="$(kill -l "$sig" 2>/dev/null || echo "signal $sig")"
                why="killed by $sig_name"
            else
                why="exit $status"
            fi
            reason=" (${why}${detail:+: ${detail}})"
            ;;
    esac

    qs -c "$shell" ipc call loading error "Couldn't open ${label:-that}${reason}" >/dev/null 2>&1
fi

exit "$status"
