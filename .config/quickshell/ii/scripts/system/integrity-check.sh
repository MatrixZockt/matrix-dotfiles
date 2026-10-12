#!/usr/bin/env bash
# integrity-check.sh -- is this desktop actually healthy?
#
# Written after "apps sometimes crash at random or don't open", which is two
# different faults wearing one coat. This separates them and names each cause
# rather than reporting a general "something is wrong":
#
#   * the RUNTIME      -- is the shell alive, is the compositor reachable,
#                         is the watchdog watching
#   * the CONFIG       -- do all the scripts and QML and Lua still parse
#   * the LAUNCH PATH  -- the single most common "it didn't open": a .desktop
#                         entry pointing at a binary that is not installed
#   * the STABILITY    -- what has actually been crashing, and what is
#                         leaking
#
# Every check is a fact about this machine, not a generic lint. Nothing here
# is speculative: each line corresponds to a failure that has actually happened
# on this box (session-env wiping a live IPC socket, the watchdog's cgroup
# taking Freebuff down with it, orphaned desktop entries, leaked AppImage
# FUSE mounts).
#
# Usage:
#   integrity-check.sh              check, and print the report
#   integrity-check.sh --quiet      only print problems, and the summary
#   integrity-check.sh --days 7     widen the crash window (default 3)
#
# Exit status: 0 if nothing FAILED, 1 if anything did. WARN alone is not a
# failure -- a machine with an old crash in the log is normal, and a checker
# that cries wolf gets ignored.
set -uo pipefail

DAYS=3
QUIET=0
for arg in "$@"; do
    case "$arg" in
        --quiet) QUIET=1 ;;
        --days) shift; DAYS="${1:-3}" ;;
        --days=*) DAYS="${arg#--days=}" ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    esac
done

FAILS=0
WARNS=0
declare -a FAILED_LINES=()
declare -a WARN_LINES=()

# `say` is UNCONDITIONAL. Only `ok` respects --quiet.
#
# It used to be the other way round, and --quiet was useless because of it: the
# FAIL and warn lines, and the final list of what failed, all went through say,
# so quiet mode printed the indented DETAIL of each problem and then a bare
# "1 PROBLEM(S)" -- with nothing anywhere naming the problem. --quiet is for
# seeing problems, so problems are the one thing it must never hide.
say()  { printf '%s\n' "$*"; }
ok()   { [ "$QUIET" -eq 1 ] || printf '  ok    %s\n' "$*"; }
fail() { FAILS=$((FAILS+1)); FAILED_LINES+=("$*"); printf '  FAIL  %s\n' "$*"; }
warn() { WARNS=$((WARNS+1)); WARN_LINES+=("$*"); printf '  warn  %s\n' "$*"; }
head_() { [ "$QUIET" -eq 1 ] || { printf '\n── %s ─────────────────────────────────────────\n' "$*"; }; }

# ── RUNTIME ────────────────────────────────────────────────────────────────
head_ "runtime"

QS_COUNT=$(pgrep -c -x qs 2>/dev/null || echo 0)
# Counted by PROCESS NAME, then filtered on the real command line read out of
# /proc -- NOT with `pgrep -f "qs -c ii"`.
#
# `pgrep -f` matches a substring of the whole command line, so any shell that
# merely *mentions* the string matches too: running this checker from a
# terminal whose command line contains "qs -c ii" made it report two shells
# when there was one. The bracket trick (`[q]s -c ii`) does not help, because
# the text still appears verbatim inside a longer line. Requiring the process
# NAME to be exactly `qs` first is what makes it unspoofable -- the same trap
# that shell.sh documents for its own guard.
qs_config() {   # $1 = config name; prints the pids running it
    local pid cmd
    for pid in $(pgrep -x qs 2>/dev/null); do
        cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)
        case "$cmd" in *"qs -c $1"*) printf '%s\n' "$pid" ;; esac
    done
}
II_PIDS=$(qs_config ii)
II_COUNT=$(printf '%s' "$II_PIDS" | grep -c '[0-9]' || true)
SPLASH_COUNT=$(qs_config splash | grep -c '[0-9]' || true)

if [ "$II_COUNT" -eq 1 ]; then
    ok "one desktop shell running (pid $II_PIDS)"
elif [ "$II_COUNT" -eq 0 ]; then
    fail "no desktop shell running -- the bar and every shell keybind are dead"
else
    fail "$II_COUNT desktop shells running (pids: $(echo "$II_PIDS" | tr '\n' ' ')) -- duplicate bar, one SUPER tap toggles twice"
fi

if [ "$SPLASH_COUNT" -gt 0 ]; then
    warn "$SPLASH_COUNT splash instance(s) still alive -- a startup splash outlived its shell"
else
    ok "no orphaned splash process"
fi

WD_STATE=$(systemctl --user is-active shell-watchdog.service 2>/dev/null || echo unknown)
case "$WD_STATE" in
    active) ok "watchdog active (the shell's safety net)" ;;
    failed) fail "watchdog FAILED -- nothing will restart the shell if it dies" ;;
    *)      fail "watchdog is '$WD_STATE', not active" ;;
esac

# Surfaces actually mapped. A shell process that is up but drawing nothing
# looks alive in ps and is invisible on screen.
SURF=$(hyprctl layers -j 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print(0); raise SystemExit
print(sum(1 for m in d.values() for lv in (m.get("levels") or {}).values() for s in lv or []
          if (s.get("namespace") or "").startswith("quickshell:")))
' 2>/dev/null || echo 0)
: "${SURF:=0}"
if [ "${SURF:-0}" -ge 1 ]; then
    ok "$SURF shell surfaces mapped on screen"
else
    fail "no shell surfaces mapped -- the process is up but the desktop is not being drawn"
fi

# ── COMPOSITOR ─────────────────────────────────────────────────────────────
head_ "compositor"

if hyprctl version >/dev/null 2>&1; then
    ok "hyprctl reaches Hyprland"
else
    fail "hyprctl CANNOT reach Hyprland -- the IPC socket is gone; every dispatcher, keybind and workspace script is silently dead"
fi

ERRS=$(hyprctl configerrors 2>/dev/null | head -40)
if [ -z "${ERRS// /}" ]; then
    ok "hyprctl configerrors: empty"
else
    fail "Hyprland config errors:
$(printf '%s\n' "$ERRS" | sed 's/^/          /')"
fi

# The compositor has to be discoverable without inheriting the right
# environment, or nothing can autostart.
if "$HOME/.local/bin/session-env" --check >/dev/null 2>&1; then
    ok "session-env resolves the live compositor"
else
    fail "session-env finds NO compositor -- the shell launcher will refuse to start a shell"
fi

# The live display comes from session-env, NOT from `hyprctl getenv` -- this
# Lua-configured Hyprland answers that with "unknown request", which the first
# version of this check happily turned into the path ".../unknown request" and
# then reported as a missing socket.
LIVE_WD=$("$HOME/.local/bin/session-env" 2>/dev/null | sed -n 's/^WAYLAND_DISPLAY=//p' | head -1)
if [ -n "$LIVE_WD" ]; then
    WD_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$LIVE_WD"
    if [ -S "$WD_SOCK" ]; then
        ok "wayland socket present and connectable ($LIVE_WD)"
    else
        fail "wayland socket $WD_SOCK is gone -- nothing can open a window"
    fi
else
    warn "could not determine the live WAYLAND_DISPLAY"
fi

# ── CONFIG ─────────────────────────────────────────────────────────────────
head_ "config integrity"

# ── Where the config REALLY lives ──────────────────────────────────────────
#
# BOTH roots here are symlinks on this machine:
#
#     ~/.config/quickshell/ii -> ~/hyprland/.config/quickshell/ii
#     ~/.config/hypr          -> ~/hyprland/.config/hypr
#
# and `find` does NOT descend into a symlink that is given as a starting point.
# The first version of this check used them as-is and found ZERO QML and ZERO
# Lua files -- then reported "all 0 QML files have balanced braces" as a PASS.
# A check that cannot fail is worse than no check: it looks like health. So the
# roots are resolved to their real paths first, and the roots are de-duplicated
# because they are two doors into the same tree.
mapfile -t CFG_ROOTS < <(
    for p in "$HOME/.config/quickshell" "$HOME/.config/hypr"; do
        readlink -f "$p" 2>/dev/null
    done | sort -u
)
cfg_find() {
    local pat="$1"; shift
    local r
    for r in "${CFG_ROOTS[@]}"; do
        find "$r" "$@" -name "$pat" 2>/dev/null
    done
}

SH_N=$(cfg_find '*.sh' | wc -l)
SH_BAD=0
SH_SKIP=0
while IFS= read -r f; do
    # A script may carry a DATA BLOCK that it reads out of ITSELF at runtime
    # (`sed '1,/^### DATA ###$/d' "$0"`). `bash -n` parses the whole file, so
    # it reports a syntax error on data that is never executed -- a false
    # positive. fuzzel-emoji.sh is exactly this shape and does run. So for
    # such files only the lines BEFORE the marker are checked, which is the
    # part that is actually shell.
    if grep -qE 'sed .*"\$0"|tail -n .*"\$0"' "$f" 2>/dev/null; then
        SH_SKIP=$((SH_SKIP+1))
        exec_part=$(sed '/^### DATA ###$/,$d' "$f")
        if ! printf '%s\n' "$exec_part" | bash -n 2>/dev/null; then
            SH_BAD=$((SH_BAD+1))
            fail "shell script does not parse: $f (before its data block)"
        fi
        continue
    fi
    bash -n "$f" 2>/dev/null || { SH_BAD=$((SH_BAD+1)); fail "shell script does not parse: $f"; }
done < <(cfg_find '*.sh')
[ "$SH_BAD" -eq 0 ] && ok "all $SH_N shell scripts parse ($SH_SKIP carry a runtime-read data block)"

# QML integrity, checked the only way that means anything: does the shell that
# is ACTUALLY RUNNING log any QML errors?
#
# This deliberately does NOT count braces. A brace counter was tried first and
# reported nine files as "unbalanced" -- while the very same config was drawing
# twelve surfaces with no complaint. QML puts braces inside strings, template
# literals and JS blocks all over this tree, so brace counting is structurally
# incapable of being right here, and a check that is wrong 100% of the time on
# healthy files trains you to ignore it. The runtime log is ground truth.
QSLOG_DIR=$(ls -td /run/user/$(id -u)/quickshell/by-id/*/ 2>/dev/null | head -1)
QML_ERR=$(strings "$QSLOG_DIR/log.qslog" 2>/dev/null \
    | grep -oE '@?[A-Za-z0-9_/.-]+\.qml\[[0-9]+:[0-9]+\]: (TypeError|ReferenceError|Error|Unable to assign|Cannot assign)[^|]*' \
    | sed 's/^@*//' | sort -u)
QML_ERR_N=$(printf '%s' "$QML_ERR" | grep -c . || true)
if [ "${QML_ERR_N:-0}" -eq 0 ]; then
    ok "the running shell logs no QML errors"
else
    fail "$QML_ERR_N QML error(s) in the running shell's log:"
    printf '%s\n' "$QML_ERR" | head -12 | sed 's/^/          /'
fi

# The "sheet" arrangement is drawn TWICE -- by the SDDM greeter
# (hypr/custom/sddm-theme/Main.qml) and by the in-session lock
# (modules/ii/lock/LockSurface.qml). LockSurface's own header says its geometry
# is "copied from the SDDM theme's Main.qml", and NOTHING notices when the copy
# stops matching: no error, no config, just two screens that no longer look
# alike. That is the same shape as the LoginLayouts bug (the lock asked for a
# template the SDDM fragments had and the shell's hand-written list did not), so
# it gets the same treatment -- one fact, checked instead of assumed.
#
# The failure this exists for, exactly: both columns are anchored by their
# vertical CENTRE, so walking the column's BOTTOM up to the 8.5% margin moves
# the centre by the margin plus HALF the column, the half-height being the
# centre-to-bottom distance. Subtracting the FULL height instead (the state
# before 2026-10-11) parked the whole form -- account tile, password line,
# return key -- 107 px above the bottom-left corner it is drawn for, while the
# clock above kept its own 8.5% from the top. The two-corner rhythm this
# arrangement is built around came out one-sided, and the input line was the
# most visible part of it. One factor of two, in two files.
SHEET_GEOM=$(python3 - <<'PY'
import os, re
home = os.path.expanduser("~")
files = {
    "the login screen": f"{home}/.config/hypr/custom/sddm-theme/Main.qml",
    "the lock":         f"{home}/.config/quickshell/ii/modules/ii/lock/LockSurface.qml",
}
# The margin plus the centre-to-bottom distance, and nothing else.
want = "parent.height / 2 - height / 2"
seen, problems = {}, []
for label, path in files.items():
    try:
        txt = open(path, encoding="utf-8", errors="replace").read()
    except OSError as e:
        problems.append(f"cannot read {label} ({path}): {e}")
        continue
    # The sheet column is the only thing in either file that offsets the
    # CENTRE by a slice of parent.height, so this finds exactly one expression
    # and does not need to know the margin's value -- that is the design's, and
    # pinning it here would fail on a deliberate change made in both files.
    found = [re.sub(r"\s+", " ", m)
             for m in re.findall(r"Math\.round\(parent\.height[^)]*\)", txt)]
    if len(found) != 1:
        problems.append(f"{label} has {len(found)} centre offsets on parent.height, expected exactly 1")
    elif want not in found[0]:
        problems.append(f"{label} offsets its sheet column by something other than "
                        f"the margin plus half the column: {found[0]}")
    else:
        seen[label] = found[0]
if len(seen) == 2 and len(set(seen.values())) != 1:
    problems.append("the login screen and the lock disagree: " + " vs ".join(seen.values()))
print("\n".join(problems) if problems else "OK")
PY
)
if [ "$SHEET_GEOM" = "OK" ]; then
    ok "the login screen and the lock agree on the sheet column's offset (margin + half the column)"
else
    fail "the sheet column's offset is wrong or has drifted apart:"
    printf '%s\n' "$SHEET_GEOM" | sed 's/^/          /'
fi

LUA_N=0
LUA_BAD=0
while IFS= read -r f; do
    LUA_N=$((LUA_N+1))
    luac -p "$f" 2>/dev/null || { LUA_BAD=$((LUA_BAD+1)); fail "Lua does not parse: $f"; }
done < <(cfg_find '*.lua' -not -name '*.bak*')
[ "$LUA_BAD" -eq 0 ] && ok "all $LUA_N Hyprland Lua files parse"
[ "$LUA_N" -gt 5 ] || fail "only $LUA_N Lua files found -- the config roots have probably moved"

# Scripts the launcher calls must exist, or an autostart silently vanishes.
MISSING_REF=0
while IFS= read -r p; do
    real="${p/#\$HOME/$HOME}"
    [ -e "$real" ] || { MISSING_REF=$((MISSING_REF+1)); fail "referenced script does not exist: $p"; }
done < <(grep -rhoE '\$HOME/\.config/quickshell/ii/scripts/[a-zA-Z0-9_/.-]+\.(sh|py)' \
             "$HOME/.config/quickshell/ii/scripts/launch" "$HOME/.config/hypr" 2>/dev/null | sort -u)
[ "$MISSING_REF" -eq 0 ] && ok "every script the launcher references exists"

# ── LAUNCH PATH ────────────────────────────────────────────────────────────
head_ "app launch path"

# THE commonest "it didn't open": an entry whose Exec names a program that is
# not installed. Nothing errors; the menu item just does nothing.
ENTRY_OUT=$(python3 - <<'PY'
import os, glob, shlex, re
bad = 0
for d in (os.path.expanduser("~/.local/share/applications"), "/usr/share/applications"):
    for f in sorted(glob.glob(os.path.join(d, "*.desktop"))):
        try:
            txt = open(f, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        if re.search(r"^NoDisplay=true", txt, re.M):
            continue
        for m in re.finditer(r"^Exec=(.*)$", txt, re.M):
            parts = shlex.split(m.group(1), posix=True)
            if parts and parts[0] in ("env", "/usr/bin/env"):
                parts = parts[1:]
            if not parts:
                continue
            exe = parts[0]
            if exe.startswith("/"):
                if not os.path.exists(exe):
                    print(f"{os.path.basename(f)} -> {exe}")
                    bad += 1
            elif not any(os.access(os.path.join(p, exe), os.X_OK)
                         for p in os.environ.get("PATH", "").split(":") if p):
                print(f"{os.path.basename(f)} -> {exe}")
                bad += 1
print(f"__COUNT__ {bad}")
PY
)
ENTRY_BAD=$(printf '%s\n' "$ENTRY_OUT" | sed -n 's/^__COUNT__ //p')
while IFS= read -r line; do
    [ -n "$line" ] && fail "desktop entry points at a missing program: $line"
done <<< "$(printf '%s\n' "$ENTRY_OUT" | grep -v '^__COUNT__')"
[ "${ENTRY_BAD:-0}" -eq 0 ] && ok "every desktop entry resolves to an installed program"

# Apps are launched by open.sh, which inherits the SHELL's PATH. If that PATH
# lost ~/.local/bin, every user-installed launcher entry silently disappears.
SHELL_PATH=$(tr '\0' '\n' < "/proc/${II_PIDS:-0}/environ" 2>/dev/null \
             | sed -n 's/^PATH=//p')
if [ -n "$SHELL_PATH" ]; then
    if [[ ":$SHELL_PATH:" == *":$HOME/.local/bin:"* ]]; then
        ok "the shell's PATH contains ~/.local/bin"
    else
        fail "the shell's PATH is missing ~/.local/bin -- apps installed there will not launch from the menu"
    fi
else
    warn "could not read the shell's PATH"
fi

# ── STABILITY ──────────────────────────────────────────────────────────────
head_ "stability (last $DAYS day(s))"

CRASH=$(coredumpctl list --since "$DAYS days ago" --no-pager --json=short 2>/dev/null | python3 -c '
import json,sys,collections
try: d=json.load(sys.stdin)
except Exception: d=[]
c=collections.Counter()
for x in d:
    c[(x.get("exe") or "?").split("/")[-1]] += 1
print(sum(c.values()))
for k,v in c.most_common(8):
    print(f"  {v:3d}x {k}")
' 2>/dev/null)
CRASH_N=$(printf '%s\n' "$CRASH" | head -1)
CRASH_N=${CRASH_N:-0}
if [ "$CRASH_N" -eq 0 ]; then
    ok "no crashes recorded"
else
    warn "$CRASH_N crash(es) in the last $DAYS day(s):"
    printf '%s\n' "$CRASH" | tail -n +2 | sed 's/^/        /'
fi

# Leaked AppImage FUSE mounts. Every crashed AppImage run leaves one behind,
# and they accumulate; a burst is both a symptom and a cause of later weirdness.
#
# Only counted while they are STILL MOUNTED. An unmounted leftover directory is
# inert -- the AppImage runtime leaves the empty dir behind after a clean exit
# -- and flagging it would be noise.
STALE=0
for m in /tmp/.mount_*; do
    [ -d "$m" ] || continue
    mountpoint -q "$m" 2>/dev/null || continue
    [ -z "$(fuser -m "$m" 2>/dev/null)" ] && STALE=$((STALE+1))
done
if [ "$STALE" -eq 0 ]; then
    ok "no leaked AppImage mounts"
else
    warn "$STALE leaked AppImage FUSE mount(s) still mounted with no process using them"
fi

FAILED_UNITS=$(systemctl --user list-units --state=failed --no-legend --plain 2>/dev/null | wc -l)
if [ "$FAILED_UNITS" -eq 0 ]; then
    ok "no failed user units"
else
    warn "$FAILED_UNITS failed user unit(s):"
    systemctl --user list-units --state=failed --no-legend --plain 2>/dev/null \
        | awk '{print "        " $1}'
fi

CORE_MB=$(du -sm /var/lib/systemd/coredump 2>/dev/null | cut -f1)
if [ -n "${CORE_MB:-}" ] && [ "${CORE_MB:-0}" -gt 500 ]; then
    warn "coredumps occupy ${CORE_MB}MB -- coredumpctl delete is safe and reclaims it"
elif [ -n "${CORE_MB:-}" ]; then
    ok "coredumps occupy ${CORE_MB}MB"
fi

# ── VERDICT ────────────────────────────────────────────────────────────────
say ""
say "═══════════════════════════════════════════════"
if [ "$FAILS" -eq 0 ]; then
    printf '  HEALTHY — %d warning(s), nothing broken\n' "$WARNS"
    say "═══════════════════════════════════════════════"
    exit 0
fi
printf '  %d PROBLEM(S) — %d warning(s)\n' "$FAILS" "$WARNS"
for l in "${FAILED_LINES[@]}"; do say "    ✗ $l"; done
say "═══════════════════════════════════════════════"
exit 1
