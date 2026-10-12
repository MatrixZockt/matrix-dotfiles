#!/usr/bin/env bash
# shell-pids.sh -- print the pids of REAL desktop shells. Nothing else.
#
# WHY THIS FILE EXISTS
# --------------------
# Every launcher on this desktop used to answer "is a shell running?" with
#
#     pgrep -f "qs -c ii"
#
# and that question has a fatal flaw: `-f` matches the FULL COMMAND LINE, not
# the process name. So it matches every process whose arguments merely CONTAIN
# the string "qs -c ii" -- and on a machine where the user runs agent sessions,
# greps, editors and test harnesses against these very scripts, that is a
# steady supply of them.
#
# The character class in "[q]s -c ii" only stops the pattern matching the
# LAUNCHER'S OWN command line. It does nothing about anyone else's. Measured on
# this machine while fixing the SUPER+CTRL+B failsafe:
#
#   $ pgrep -f "[q]s -c ii"
#   355915            <- the real shell
#   361188            <- bash -c '... qs -c ii ipc call desktopPill state ...'
#
# pid 361188 was a wrapper from another session whose script text happened to
# contain the string. It is not a shell. It cannot draw a bar.
#
# WHY THAT BREAKS THE FAILSAFE. shell.sh's guard is not just "is any process
# matching"; it is "is any matching process on the LIVE WAYLAND_DISPLAY":
#
#     for pid in $(pgrep -f "[q]s -c ii"); do
#         wd=$(... /proc/$pid/environ ...)
#         [ "$wd" = "$LIVE_WD" ] && exit 0        # "shell already up"
#     done
#
# A decoy does not need to be a shell to have a WAYLAND_DISPLAY -- it inherits
# one from whatever started it, which is the live one. So the guard saw the
# decoy, concluded "this session's shell is already up", and exited 0 without
# starting anything. From the user's side: press the key, nothing happens,
# desktop stays bare.
#
# That is exactly the reported symptom, and it is why the bug looked
# unreproducible: it depends on what ELSE happens to be running. With no
# decoy the same key works, which is why a manual retry often "fixes" it.
#
# THE FIX. Match the process NAME (`pgrep -x qs` -- `-x` is exact, so no
# wrapper, no editor, no grep can match), and only then confirm from
# /proc/<pid>/cmdline that this particular `qs` really is our config. Both
# halves matter: the name check rules out the decoys, and the cmdline check
# rules out a `qs` belonging to some other config on the same machine.
#
# Usage:
#   . shell-pids.sh                 # define shell_pids()
#   shell_pids                      # all real `qs -c <config>` pids
#   shell_pids "$config"            # ...for one config
#   shell_pid_on "$wd" "$config"    # first one whose WAYLAND_DISPLAY is $wd
#
# Sourced, not executed: it defines functions and prints nothing.

# The config to look for. Defaults to `ii`; callers that support overrides
# (`qsConfig=...`) pass their own.
: "${qsConfig:=ii}"

# Every real shell process for a config, one per line.
#
# WHY THIS NO LONGER USES `pgrep -x qs`. It did, and it was the whole point of
# the file: `-x` is an exact match on the process NAME, so unlike `pgrep -f` it
# cannot be fooled by a wrapper, a grep or a test harness. But it also MISSES
# the shell.
#
# Measured on this machine, with a shell definitely running:
#
#   $ pgrep -ax qs        -> 1492294 qs -c ii     (found)
#   $ pgrep -x  qs       -> (empty)               (MISSED)
#   $ pgrep -x  quickshell -> (empty)
#
# `qs` is a symlink to /usr/bin/quickshell, so the kernel's comm for the
# process is not reliably "qs", and whether `-x qs` matches appears to depend on
# how the process was started. That is a dangerous failure in a liveness check:
# a MISS means "no shell is running", which is exactly the wrong answer, and
# it is what made the SUPER+CTRL+B failsafe cold-restart the shell instead of
# reloading Quickshell in place -- silently, and intermittently.
#
# So the name match is gone and the cmdline match, which is what actually
# identifies the shell, is done directly over /proc. That is strictly safer
# than what it replaces as well as strictly more reliable: a decoy cannot have
# a cmdline of exactly "qs -c ii" without BEING that process. The full cmdline
# must match, not merely contain the string.
# THE COST OF THE WALK WAS ON THE LOGIN CRITICAL PATH. It forked `tr` once per
# entry in /proc to read each cmdline: measured on this machine at 1.98 s per
# call, and the login path calls it up to four times -- twice in shell.sh
# before Quickshell is even exec'd, once in splash.sh, and once per watchdog
# tick. Four seconds of the desktop's startup was this function.
#
# `pgrep -f -x` is one process and gives the same answer exactly: `-f` matches
# the whole command line rather than the untrustworthy comm name (see above),
# and `-x` requires the ENTIRE line to match, which is the property the walk
# was written for -- a decoy whose arguments merely mention the string (a bash
# running this very script, an `ipc call`) cannot match. Verified against the
# old implementation on a live shell: identical output, and the decoy excluded.
#
# 0.038 s instead of 1.98 s, so the shell is launched ~4 s sooner.
#
# BOTH SPELLINGS OF argv[0], and the second one is not hypothetical: shell.sh
# execs `qs` (a PATH lookup, argv[0] = "qs"), but anything that starts the
# binary by absolute path -- a wrapper, a hand-run /usr/bin/qs -- has
# "/usr/bin/qs" in that position instead, and a walk that only knows the short
# form cannot see that shell. Measured 2026-10-11: a shell running as
# `/usr/bin/qs -c ii` was invisible to the reap loop, so the watchdog judged
# the session shell-less and started a SECOND one -- two bars, two sets of
# layers, on one screen. (The old /proc walk had the same blind spot: it
# compared the joined argv against the literal "qs -c ii" -- so this is a
# latent bug found while replacing it, not one the replacement introduced.)
#
# `[^ ]*/qs` still requires the ENTIRE line to match, so the exactness above
# holds: "bash -c qs -c ii" and a "bash -c /usr/bin/qs -c ii" decoy (spaces
# before the path) both fail it.
shell_pids() {
    local config="${1:-$qsConfig}"
    pgrep -f -x -- "qs -c $config" 2>/dev/null
    pgrep -f -x -- "[^ ]*/qs -c $config" 2>/dev/null
    pgrep -f -x -- "qs --config $config" 2>/dev/null
    pgrep -f -x -- "[^ ]*/qs --config $config" 2>/dev/null
}

# The first real shell whose WAYLAND_DISPLAY is the one given. This is the
# "does THIS session have a shell" question, answered without ever reading a
# non-shell process's environment.
shell_pid_on() {
    local want_wd="${1:-}" config="${2:-$qsConfig}" pid
    [ -n "$want_wd" ] || return 1
    for pid in $(shell_pids "$config"); do
        if [ "$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
                | sed -n 's/^WAYLAND_DISPLAY=//p')" = "$want_wd" ]; then
            printf '%s\n' "$pid"
            return 0
        fi
    done
    return 1
}

# True when a real shell for this config is up on the live display.
shell_is_up() {
    local config="${1:-$qsConfig}" wd="${2:-}"
    if [ -z "$wd" ]; then
        wd="$(echo "$PROBED" 2>/dev/null \
              | sed -n 's/^WAYLAND_DISPLAY=//p')"
    fi
    [ -n "$wd" ] || return 1
    shell_pid_on "$wd" "$config" >/dev/null 2>&1
}