#!/usr/bin/env bash
# ── Stopping a shell without orphaning its helpers ───────────────────────────
#
# WHY THIS EXISTS.
#
# The shell starts long-lived helpers -- `nmcli monitor` behind a wrapper,
# `udevadm monitor`, `wl-paste --watch`, a python input watcher. They are its
# CHILDREN, and killing the shell does not signal them: `qs kill` ends one
# process, and the kernel reparents the rest to init without ever telling them
# their owner is gone. Each restart therefore left a new set behind, holding
# memory and a D-Bus connection to nobody. Measured 2026-10-16 on this machine:
# sixteen `nmcli monitor` processes alive at once, one per shell restart in the
# preceding forty minutes, ~11 MB each, growing without bound.
#
# The wrapper each of them sits behind tries to prevent this -- it polls its
# owner and kills its child when the owner dies -- but that wrapper is itself a
# direct child of `qs`, so when the shell is killed the wrapper dies with it and
# its poll never runs again.
#
# WHY NOT KILL THE PROCESS GROUP.
#
# The obvious mechanism is `kill -- -PGID`. It cannot be used here: this session
# runs EVERYTHING in one process group (`pgrp` = `sid` = start-hyprland's pid --
# verified, not assumed), so a group signal would take the compositor, the
# session and every application down with the shell.
#
# WHY NOT A PER-TYPE SWEEP.
#
# shell-watchdog.sh sweeps strays by pattern (`nmcli monitor`, `udevadm
# monitor`), and those sweeps stay -- but they only know the types someone
# already met, and they only run on the watchdog's own 15 s tick. A new watcher
# type leaks until someone notices and writes another sweep. This walks the
# process tree instead, so ANY helper the shell attached is covered, and it runs
# at the moment of the restart rather than up to 15 s later.
#
# WHAT IS SPARED, AND WHY THAT IS THE RIGHT LINE.
#
# An application launched from the shell must survive a reload -- the reload
# reloads the desktop, it does not close what the user was working in. Every
# application path here detaches itself with `setsid` (verified: `open.sh` runs
# in its own session, `filemanager.sh` and `splash.sh` both use `setsid qs`), so
# the rule is:
#
#     kill a descendant only if it is still in the shell's SESSION and is not
#     the leader of its own process group
#
# A detached application is its own session leader (`pgrp == pid`), so it is
# spared twice over. A helper that stayed attached (`pgrp` = the shell's) is
# exactly the thing that would otherwise be orphaned. Nothing here reads a
# command name, so no helper is missed for being new.
#
# TWO TRAPS THIS FILE HAS ALREADY FALLEN INTO, both now covered by the self-test
# at the bottom -- run it after any edit to the awk.
#
#   1. THE PAREN. `comm` is free-form and can contain parentheses and spaces:
#      `(sd-pam)` and `(kworker/R-rcu_gp)` are processes on this machine. Cutting
#      the line at the FIRST `)` then reads ppid/pgrp/sid one field off.
#   2. THE `in` TRAP. `if (!want[p] && (p_ppid[p] in want))` looks like a
#      membership test and is not one: READING `want[p]` CREATES the element, so
#      after the first pass every pid is a key, every parent "is in want", and
#      the closure swallows the whole machine -- measured, it returned 558 of
#      561 processes including the compositor the caller must never touch. This
#      is why the walk below is a queue of explicit additions and why every
#      test is `== 1` against a value that was SET, never `in`.
#
# Costs one pass over /proc plus one `cat` -- no per-process forks, which is
# what keeps it off the critical path of a reload (shell.sh notes that shelling
# out once per process costs 2.1 s on this machine; this is a few ms).

# Print the pids of the given roots' attached descendants, children before
# parents. Roots themselves are never printed.
#
# SHELL_TREE_STAT_SOURCE (optional) points at a single file in /proc/<pid>/stat
# format instead of the real /proc. It exists so the walk can be tested against
# a synthetic tree -- see the self-test below.
shell_tree_pids() {
    local roots="$*" sid_list="" s src="${SHELL_TREE_STAT_SOURCE:-}"
    for p in $roots; do
        # Strip to the LAST paren: comm is free-form (trap 1 above).
        #
        # The root's session comes from the SAME source as the tree. Reading it
        # from live /proc while the tree came from a file made the self-test
        # depend on a real process that happens to exist: it passed while the
        # shell was pid 3371 and failed the moment a reload replaced that pid,
        # with an empty list and a green live system -- a test that only tells
        # you about the machine, not about the code.
        if [ -n "$src" ]; then
            s=$(awk -v want="$p" '$1 == want { sub(/^.*\) /, ""); print $4; exit }' "$src" 2>/dev/null)
        else
            s=$(awk '{ sub(/^.*\) /, ""); print $4 }' "/proc/$p/stat" 2>/dev/null)
        fi
        [ -n "$s" ] && sid_list="$sid_list $s"
    done
    # Nothing readable -- an empty list is the honest answer, never a guess.
    [ -z "${sid_list// /}" ] && return 0

    {
        # ONE cat for every stat file, piped in -- NOT the files as awk
        # arguments. Handing a glob to awk is a race on a moving /proc: a pid
        # that exits between the shell expanding the glob and awk opening the
        # file makes awk treat the run as fatal (exit 2) and SKIP THE END BLOCK
        # entirely, so the function returns an empty list -- intermittently, and
        # silently, because the caller then sees "nothing to stop". Measured:
        # three identical runs, the third aborted. cat reports the vanished file
        # and carries on, and one cat is still one process by fork count.
        if [ -n "$src" ]; then
            cat "$src" 2>/dev/null || true
        else
            cat /proc/[0-9]*/stat 2>/dev/null || true
        fi
    } | awk -v roots="$roots" -v sids="$sid_list" '
        {
            pid = $1
            line = $0
            sub(/^.*\) /, "", line)      # strip to the LAST paren, never the first
            split(line, f, " ")
            # A row whose fields did not parse as numbers is skipped rather than
            # trusted: a bogus parent link is what turns a one-shell walk into
            # every process on the machine.
            if (f[2] !~ /^[0-9]+$/ || f[3] !~ /^[0-9]+$/ || f[4] !~ /^[0-9]+$/) next
            p_ppid[pid] = f[2]
            p_pgrp[pid] = f[3]
            p_sid[pid]  = f[4]
            kids[f[2]] = kids[f[2]] " " pid      # parent -> children, as one string
        }
        END {
            n = split(roots, r, " ")
            for (i = 1; i <= n; i++) { depth[r[i]] = 0; isroot[r[i]] = 1 }

            # Breadth-first from the roots. Membership is NOT tested -- a pid is
            # in the walk because it was APPENDED to the queue, which is the
            # trap-2-proof way to do it.
            queue = roots
            while (queue != "") {
                nextq = ""
                m = split(queue, cur, " ")
                for (i = 1; i <= m; i++) {
                    if (kids[cur[i]] == "") continue
                    k = split(kids[cur[i]], ch, " ")
                    for (j = 1; j <= k; j++) {
                        if (isroot[ch[j]] == 1) continue
                        nextq = nextq " " ch[j]
                        depth[ch[j]] = depth[cur[i]] + 1
                    }
                }
                if (nextq == "") break
                queue = nextq
            }

            # Children first: a wrapper is stopped after the child it spawned,
            # so nothing is left behind by the wrapper exiting first.
            maxd = 0
            for (p in depth) if (depth[p] > maxd) maxd = depth[p]
            m = split(sids, s, " ")
            for (d = maxd; d >= 1; d--) {
                for (p in depth) {
                    if (depth[p] != d) continue
                    if (p_pgrp[p] == p) continue          # detached: owns its group
                    for (i = 1; i <= m; i++)
                        if (p_sid[p] == s[i]) { print p; break }
                }
            }
        }
    '
}

# Stop those descendants: TERM first (a wrapper own trap then cleans up its
# child), then KILL whatever ignored it. Prints the number stopped.
shell_tree_stop() {
    local p list stopped=0 killed=0
    list=$(shell_tree_pids "$@")
    [ -z "${list// /}" ] && { echo 0; return 0; }

    for p in $list; do
        kill -TERM "$p" 2>/dev/null && stopped=$((stopped + 1))
    done
    # Only worth a pause if something actually took the TERM.
    [ "$stopped" -gt 0 ] && sleep 0.15
    for p in $list; do
        if kill -0 "$p" 2>/dev/null; then
            kill -KILL "$p" 2>/dev/null && killed=$((killed + 1))
        fi
    done
    echo "$((stopped + killed))"
}

# ── Self-test ────────────────────────────────────────────────────────────────
# Synthetic process table, both traps included, run only when asked for:
#
#     bash shell-tree.sh --self-test
#
# It asserts the walk returns EXACTLY the attached helpers -- and in particular
# that it never returns the compositor (a sibling of the shell's parent, which
# the buggy `in` version did return), a detached application, or a `(sd-pam)`
# style comm that used to shift every field by one.
if [ "${1:-}" = "--self-test" ]; then
    tmp=$(mktemp) || exit 1
    # pid (comm) state ppid pgrp sid ...
    cat >"$tmp" <<'STAT'
1 (systemd) S 0 1 1 0 -1
2 (kthreadd) S 0 2 0 0 -1
2308 (systemd) S 1 2308 2308 0 -1
2334 ((sd-pam)) S 2308 2308 2308 0 -1
3329 (start-hyprland) S 3282 3329 3329 0 -1
3367 (Hyprland) S 3329 3329 3329 0 -1
3371 (qs) S 3367 3329 3329 0 -1
3377 (window-border) S 1 3329 3329 0 -1
437577 (bash) S 3371 3329 3329 0 -1
437582 (python3) S 437577 3329 3329 0 -1
437809 (bash) S 3371 3329 3329 0 -1
437818 (nmcli) S 437809 3329 3329 0 -1
437618 (udevadm) S 3371 3329 3329 0 -1
4514 (wl-paste) S 3367 3329 3329 0 -1
32600 (app) S 32579 32578 32578 0 -1
33670 (child-of-app) S 32600 32578 32578 0 -1
999999 (gone) S 2 0 0 0 -1
STAT
    SHELL_TREE_STAT_SOURCE="$tmp"
    export SHELL_TREE_STAT_SOURCE
    got=$(shell_tree_pids 3371 | sort -n | tr '\n' ' ')
    want="437577 437582 437618 437809 437818 "
    rm -f "$tmp"
    if [ "$got" = "$want" ]; then
        echo "shell-tree self-test: PASS"
        echo "  stopped (children first): $got"
        exit 0
    fi
    echo "shell-tree self-test: FAIL"
    echo "  want: [$want]"
    echo "  got:  [$got]"
    exit 1
fi
