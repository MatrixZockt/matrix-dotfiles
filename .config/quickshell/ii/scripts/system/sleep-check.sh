#!/usr/bin/env bash
# Sleep/wake check suite: the post-resume sleep guard, the lid watcher, and the
# panel net. Development scaffolding, in the same spirit as files-check.sh --
# the things it asserts are the things that were wrong on 2026-10-14.
#
# WHAT FAILURE IT IS THERE TO CATCH.
#
# On the morning of 2026-10-14 this laptop woke from its overnight S3 and went
# straight back to sleep 27 seconds later. The requester was the lid (logind's
# post-resume holdoff re-running a lid action against a state the firmware
# never updates), the guard that was supposed to stop it could not (the lid
# ignores `sleep` blockers), the sleep that followed stalled on a FUSE lookup
# and aborted, the machine landed in an s2idle sleep nobody asked for, and the
# panel was left dark -- a laptop that looked dead and had to be force-powered
# off. after-resume.sh and lid-guard.sh are the fix; this file is the proof
# that the fix is still doing what it says.
#
# NOTHING HERE SLEEPS THE MACHINE. Every test that reaches the decision point
# points lid-guard.sh at a recorder instead of `systemctl suspend`
# (--suspend-cmd), and every test that touches the panel or the lock runs
# against stubs on PATH, never against the compositor.
#
# Each watcher test takes its OWN --why. Two guards alive at once is exactly
# what the release path has to survive, and giving every test the same string
# would let one test's leftover guard stand in for another's.
set -u

HYPR="$HOME/.config/hypr/custom/scripts"
AFTER="$HYPR/after-resume.sh"
BEFORE="$HYPR/before-sleep.sh"
SCREENSAVER="$HYPR/screensaver.sh"
LID_GUARD="$HYPR/lid-guard.sh"
WHY="ii: post-resume grace period"   # what after-resume.sh arms
PREFIX="ii: sleep-check"             # the per-test guards

TMP="$(mktemp -d /tmp/sleep-check.XXXXXX)"
BIN="$TMP/bin"
SUSPEND_LOG="$TMP/suspends.txt"
WLOPM_LOG="$TMP/wlopm.txt"
NET_MARKER="$TMP/panel-net"
FAKE_LID="$TMP/lid"
# The kernel parameter lid-guard.sh gates on, written in the exact shape
# param_get_lid_init_state() prints: the selected value in brackets. `open`
# selected is what lid-init-state.service installs; the tests below that assert
# the gate itself write their own.
FAKE_PARAM="$TMP/lid_param"
printf 'ignore [open] method disabled\n' > "$FAKE_PARAM"
# Two stubs for logind's answer to "is the lid shut". These are the two halves
# of the 2026-10-16 bug: the truth the sleep ACTION is taken against, and the
# lie a raw _LID read produced. II_LID_BUSCTL is how lid-guard.sh is pointed at
# them instead of the real bus.
BUSCTL_CLOSED="$TMP/busctl-closed.sh"
BUSCTL_OPEN="$TMP/busctl-open.sh"
printf '#!/usr/bin/env bash\nprintf "b true\\n"\n' > "$BUSCTL_CLOSED"
printf '#!/usr/bin/env bash\nprintf "b false\\n"\n' > "$BUSCTL_OPEN"
chmod +x "$BUSCTL_CLOSED" "$BUSCTL_OPEN"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
chk() { # <what> <expected> <actual>
    if [ "$2" = "$3" ]; then
        ok "$1"
    else
        bad "$1 (expected '$2', got '$3')"
    fi
}
section() { printf '\n── %s\n' "$1"; }
# `grep -c` prints 0 when nothing matched but EXITS 1, so a plain `|| echo 0`
# after it appends a second 0 and every comparison below would be a string
# mismatch. Count through one place instead.
count() { local n; n="$(grep -c . "$1" 2>/dev/null)"; printf '%s' "${n:-0}"; }
count_of() { local n; n="$(grep -c -- "$1" "$2" 2>/dev/null)"; printf '%s' "${n:-0}"; }

# The stubs. `PATH` is what before-sleep.sh and screensaver.sh consult
# (`command -v wlopm`), so a fake wlopm means the real panel is never touched
# while the code under test still takes its real branch.
fake() { printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$1"; chmod +x "$BIN/$1"; }
mkdir -p "$BIN"
for cmd in hyprctl brightnessctl python3 qs; do fake "$cmd"; done
cat > "$BIN/wlopm" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WLOPM_LOG"
exit 0
EOF
chmod +x "$BIN/wlopm"
export PATH="$BIN:$PATH"

# The stand-in for `systemctl suspend`: it records the moment it ran AND
# whether the test's own guard was still listed at that moment, because
# "released before asking" is half of what lid-guard.sh promises -- an
# inhibitor owner that asks logind to sleep while holding the inhibitor is
# refused, silently. The why comes from the environment, so one recorder serves
# every test.
export CHECK_SUSPEND_LOG="$SUSPEND_LOG"
cat > "$TMP/suspend.sh" <<'EOF'
#!/usr/bin/env bash
if systemd-inhibit --list --no-legend 2>/dev/null | grep -qF "$CHECK_WHY"; then held=yes; else held=no; fi
printf '%s guard_listed=%s\n' "$(date +%T)" "$held" >> "$CHECK_SUSPEND_LOG"
EOF
chmod +x "$TMP/suspend.sh"

logind_says() {
    busctl call org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager CanSuspend 2>/dev/null \
        | sed -n 's/^s "\(.*\)"$/\1/p'
}
why_listed() { systemd-inhibit --list --no-legend 2>/dev/null | grep -qF "$1"; }

# A guard exactly like the one after-resume.sh arms -- a real systemd-inhibit
# process holding a real block inhibitor for both what= values -- because
# lid-guard.sh releases it by killing that process.
start_holder() { # <why> <seconds> -> pid on stdout
    setsid systemd-inhibit --what=sleep:handle-lid-switch --mode=block \
        --why="$1" sleep "$2" >/dev/null 2>&1 </dev/null &
    printf '%s' "$!"
}

# Drop the previous test's guard and wait for logind to stop counting it, so
# the next test's release wait measures its own guard and not the last one's.
sweep() {
    for p in $(pgrep -f "[s]ystemd-inhibit.*$PREFIX" 2>/dev/null); do kill "$p" 2>/dev/null || true; done
    for _ in $(seq 1 40); do
        case "$(logind_says)" in
        inhibited|no|challenge) sleep 0.2 ;;
        *) return 0 ;;
        esac
    done
    return 0
}
wait_unlisted() { # <why> [seconds]
    local n="${2:-8}"
    for _ in $(seq 1 "$((n * 5))"); do
        why_listed "$1" || return 0
        sleep 0.2
    done
    return 1
}
run_watcher() { # <inhibitor-pid> <why> [lid-guard args...]
    local pid="$1" why="$2"
    shift 2
    # --lid-source file: these tests drive a fake lid they can write to, so the
    # real logind's answer must not be consulted. The two tests that DO exercise
    # the logind path call lid-guard.sh directly with II_LID_BUSCTL set.
    CHECK_WHY="$why" "$LID_GUARD" --inhibitor-pid "$pid" --why "$why" \
        --lid "$FAKE_LID" --lid-source file --lid-param "$FAKE_PARAM" \
        --suspend-cmd "$TMP/suspend.sh" "$@"
}

cleanup() {
    rm -f "$NET_MARKER" 2>/dev/null || true
    for p in $(pgrep -f "[l]id-guard.sh" 2>/dev/null); do kill "$p" 2>/dev/null || true; done
    sweep
    rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

printf 'sleep/wake check suite  (scratch: %s)\n' "$TMP"

# ── 1. the guard: it exists, it is a block, and it is named the lid -----------
section "the post-resume guard holds the lid off (the fix for 2026-10-14)"
printf 'state:      open\n' > "$FAKE_LID"
II_RESUME_GUARD_SEC=10 II_LID_STATE="$FAKE_LID" "$AFTER" --guard-only >/dev/null 2>&1

armed=""
for _ in $(seq 1 20); do
    armed="$(systemd-inhibit --list --no-legend 2>/dev/null | grep -F "$WHY" || true)"
    [ -n "$armed" ] && break
    sleep 0.2
done
chk "the guard is registered with logind at all" "yes" "$([ -n "$armed" ] && echo yes || echo no)"
chk "it blocks (not delays)" "yes" "$(printf '%s' "$armed" | grep -q "block" && echo yes || echo no)"
chk "and it names handle-lid-switch, the lock the lid respects" "yes" \
    "$(printf '%s' "$armed" | grep -q "handle-lid-switch" && echo yes || echo no)"
chk "the lid watcher was started alongside it" "yes" \
    "$(pgrep -f "[l]id-guard.sh" >/dev/null 2>&1 && echo yes || echo no)"

can="$(logind_says)"
chk "logind agrees a sleep would be refused right now" "inhibited" "$can"

# The grace is 10s; wait it out and make sure the guard cleans up after itself
# rather than squatting on the machine's ability to sleep.
sleep 11
chk "the guard lets go when the grace is over" "yes" "$(why_listed "$WHY" && echo no || echo yes)"
chk "...and logind is willing to sleep again" "yes" "$([ "$(logind_says)" = "inhibited" ] && echo no || echo yes)"

# ── 2. the lid watcher's decisions -------------------------------------------
section "the watcher reads the lid logind acts on, not a raw _LID read"

# 2a. THE MORNING ITSELF: the lid is physically open, so nothing may sleep --
# however long this runs, whatever logind thinks.
sweep
: > "$SUSPEND_LOG"
printf 'state:      open\n' > "$FAKE_LID"
w="$PREFIX a-open"
h="$(start_holder "$w" 12)"
run_watcher "$h" "$w" --grace 4 >/dev/null 2>&1
chk "an open lid never sleeps the machine" "0" "$(count "$SUSPEND_LOG")"

# 2b. A real close: closed the whole time, past the holdoff window, confirmed
# -- then the guard must be released BEFORE the sleep is asked for.
sweep
: > "$SUSPEND_LOG"
printf 'state:      closed\n' > "$FAKE_LID"
w="$PREFIX b-closed"
h="$(start_holder "$w" 25)"
run_watcher "$h" "$w" --grace 12 --confirm 2 --min-age 0 >/dev/null 2>&1
chk "a genuinely closed lid does sleep the machine" "1" "$(count "$SUSPEND_LOG")"
chk "and the guard was already released when it asked" "1" \
    "$(count_of "guard_listed=no" "$SUSPEND_LOG")"
chk "the guard is gone afterwards" "yes" "$(wait_unlisted "$w" && echo yes || echo no)"

# 2c. A flap: closed, then open again a few seconds later. Inside the window it
# must NOT act -- with --min-age it does not, and the control case below proves
# the difference is the min-age and not the timing.
#
# NOTE this is NOT the 2026-10-16 case, whatever it used to say here. That
# reading never corrected itself -- it said "closed" nineteen times in a row for
# a lid that was open -- and it is covered by 2e/2f below, on the source that
# actually distinguishes the two: logind's LidClosed, which the sleep ACTION is
# taken against, against the raw _LID read that produced the lie.
sweep
: > "$SUSPEND_LOG"
printf 'state:      closed\n' > "$FAKE_LID"
w="$PREFIX c-stale"
h="$(start_holder "$w" 20)"
( sleep 5; printf 'state:      open\n' > "$FAKE_LID" ) &
run_watcher "$h" "$w" --grace 10 --confirm 2 --min-age 6 >/dev/null 2>&1
chk "a closed reading that corrects itself does NOT sleep the machine" "0" "$(count "$SUSPEND_LOG")"

# 2c-control: the same shape and the same timing, but allowed to act at once --
# and it does, which is what makes the line above a measurement of the min-age
# rule rather than of the flip landing in the right place. The lid flips 5s in
# and the decision is made at ~2s in both cases, so neither test is a race
# between the flip and a poll.
sweep
: > "$SUSPEND_LOG"
printf 'state:      closed\n' > "$FAKE_LID"
w="$PREFIX c-control"
h="$(start_holder "$w" 20)"
( sleep 5; printf 'state:      open\n' > "$FAKE_LID" ) &
run_watcher "$h" "$w" --grace 10 --confirm 2 --min-age 0 >/dev/null 2>&1
chk "...and would have, without the min-age rule" "1" "$(count "$SUSPEND_LOG")"

# 2d. No sensor at all must never read as "shut".
sweep
: > "$SUSPEND_LOG"
w="$PREFIX d-nolid"
h="$(start_holder "$w" 12)"
CHECK_WHY="$w" "$LID_GUARD" --inhibitor-pid "$h" --why "$w" \
    --lid "$TMP/there-is-no-lid" --lid-source file --lid-param "$FAKE_PARAM" \
    --grace 4 --min-age 0 --confirm 1 \
    --suspend-cmd "$TMP/suspend.sh" >/dev/null 2>&1
chk "a missing lid sensor is not read as 'shut'" "0" "$(count "$SUSPEND_LOG")"
sweep

# 2e. THE 2026-10-16 MORNING, as a test. The file -- a live _LID read -- says the
# lid is shut (that is the lie this firmware tells after a resume) while logind,
# the signal the sleep ACTION is taken against, says it is open. The file must
# lose and nothing may sleep. This is the case that slept a machine whose user
# was logged in with the lid up.
sweep
: > "$SUSPEND_LOG"
printf 'state:      closed\n' > "$FAKE_LID"
w="$PREFIX e-firmware-lies"
h="$(start_holder "$w" 20)"
CHECK_WHY="$w" II_LID_BUSCTL="$BUSCTL_OPEN" "$LID_GUARD" \
    --inhibitor-pid "$h" --why "$w" --lid "$FAKE_LID" --lid-source auto \
    --lid-param "$FAKE_PARAM" --grace 8 --confirm 2 --min-age 0 \
    --suspend-cmd "$TMP/suspend.sh" >/dev/null 2>&1
chk "a firmware-lied 'closed' does not sleep the machine" "0" "$(count "$SUSPEND_LOG")"

# 2f. ...and the logind source still performs a real close. Without this the
# test above would pass for the wrong reason -- a watcher that never acts at all.
sweep
: > "$SUSPEND_LOG"
printf 'state:      open\n' > "$FAKE_LID"
w="$PREFIX f-logind-shut"
h="$(start_holder "$w" 20)"
CHECK_WHY="$w" II_LID_BUSCTL="$BUSCTL_CLOSED" "$LID_GUARD" \
    --inhibitor-pid "$h" --why "$w" --lid "$FAKE_LID" --lid-source auto \
    --lid-param "$FAKE_PARAM" --grace 10 --confirm 2 --min-age 0 \
    --suspend-cmd "$TMP/suspend.sh" >/dev/null 2>&1
chk "a lid logind reports as shut does sleep the machine" "1" "$(count "$SUSPEND_LOG")"

# 2g. The gate. With the kernel still trusting _LID (the parameter selecting
# `method`, i.e. lid-init-state.service not installed) the value is not one to
# sleep a machine on, and the watcher refuses -- exit 1, and no sleep -- rather
# than betting on the same lie a second time. Asserting the exit status is what
# separates this from 2e: there, the watcher simply never decided.
sweep
: > "$SUSPEND_LOG"
printf 'ignore [method] open disabled\n' > "$TMP/lid_param_method"
printf 'state:      closed\n' > "$FAKE_LID"
w="$PREFIX g-kernel-trusts-lid"
h="$(start_holder "$w" 20)"
rc=0
CHECK_WHY="$w" II_LID_BUSCTL="$BUSCTL_CLOSED" "$LID_GUARD" \
    --inhibitor-pid "$h" --why "$w" --lid "$FAKE_LID" --lid-source auto \
    --lid-param "$TMP/lid_param_method" --grace 8 --confirm 2 --min-age 0 \
    --suspend-cmd "$TMP/suspend.sh" >/dev/null 2>&1 || rc=$?
chk "the watcher refuses when the kernel still trusts _LID" "1" "$rc"
chk "...and nothing was slept" "0" "$(count "$SUSPEND_LOG")"
sweep

# ── 3. the panel net ---------------------------------------------------------
section "a sleep that does not return cannot leave the panel dark"

# 3a. The net's action, when there is something to undo.
: > "$WLOPM_LOG"
: > "$NET_MARKER"
II_PANEL_NET="$NET_MARKER" "$BEFORE" --panel-back-on >/dev/null 2>&1
chk "the net turns the panel back on" "1" "$(count_of "--on" "$WLOPM_LOG")"
chk "and clears the marker it fired on" "no" "$([ -f "$NET_MARKER" ] && echo yes || echo no)"

# 3b. ...and when there is not: a panel that was never taken down.
: > "$WLOPM_LOG"
rm -f "$NET_MARKER"
II_PANEL_NET="$NET_MARKER" "$BEFORE" --panel-back-on >/dev/null 2>&1
chk "with no marker it touches nothing" "0" "$(count "$WLOPM_LOG")"

# 3c. The whole hook, on stubs: the panel goes down, the marker is written, and
# the net brings the panel back on its own when the sleep never happens.
: > "$WLOPM_LOG"
rm -f "$NET_MARKER"
II_PANEL_NET="$NET_MARKER" II_PANEL_NET_DELAY=2 "$BEFORE" >/dev/null 2>&1
chk "the hook takes the panel down" "1" "$(count_of "--off" "$WLOPM_LOG")"
chk "and leaves the marker standing for a sleep that may not return" "yes" \
    "$([ -f "$NET_MARKER" ] && echo yes || echo no)"
sleep 3
chk "the net then puts the panel back" "1" "$(count_of "--on" "$WLOPM_LOG")"
chk "and stands down" "no" "$([ -f "$NET_MARKER" ] && echo yes || echo no)"

# 3d. A real wake cancels the net, so a normal resume never fires it twice.
: > "$WLOPM_LOG"
: > "$NET_MARKER"
II_PANEL_NET="$NET_MARKER" "$SCREENSAVER" --restore >/dev/null 2>&1
chk "the wake path lights the panel itself" "1" "$(count_of "--on" "$WLOPM_LOG")"
chk "and disarms the net it made unnecessary" "no" "$([ -f "$NET_MARKER" ] && echo yes || echo no)"

printf '\n─────────────────────────────────────────────────────────────────────\n'
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
