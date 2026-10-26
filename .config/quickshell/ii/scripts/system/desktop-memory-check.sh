#!/usr/bin/env bash
# Does each desktop card bill the memory its desktop actually costs?
#
# Development scaffolding, in the style of scripts/system/files-check.sh: it
# asks the shipped surface for its numbers over IPC and puts them beside an
# independent walk of /proc and hyprctl.
#
# WHY THIS EXISTS. The first version of the card summed the resident memory of
# the pids hyprctl reports for a desktop's windows -- which is the process that
# OWNS each window, and almost never the process holding the memory. Measured
# on this machine (2026-10-15): Brave's window is one pid at 359 MB while its
# twenty processes total 2.84 GB, so a desktop running a browser read "RAM 1%"
# while the browser was costing 9% of the machine, and a desktop under half a
# percent rounded to "0%". Nothing about that is visible in the code: it is
# honest arithmetic on the wrong set of processes, which is why it needs a check
# rather than a careful reading.
#
# The assertions are chosen to be true of the SHIPPED behaviour and false of the
# pid-only one, without depending on a sample being fresh:
#
#   * for an app whose process tree is meaningfully bigger than its window's own
#     pid, the card must bill MORE than that pid -- the regression, exactly;
#   * no card may bill more than the whole tree it is drawn from (a card that
#     double counts, e.g. by billing every app's helpers to every desktop, is
#     the other way to get this wrong);
#   * the "+" slot bills nothing (it is not a desktop);
#   * the cards TOGETHER land in the same universe as the machine's used
#     memory. This is the user-facing claim: the sum used to be ~0.2% of a
#     machine that was 50% full. The band is wide because RSS double counts
#     shared pages, and the cards never claim to account for daemons that
#     belong to no desktop at all.
#
# The desktop is left as it was found (the grid is closed again if the check
# opened it), and nothing is moved, killed or rearranged.
#
#   bash scripts/system/desktop-memory-check.sh
set -u

# Deliberately C: this shell is a decimal-comma locale (de_DE), where `printf
# '%9.2f' "0.9"` is not a number and prints NOTHING -- the table below silently
# lost every figure and section 4 then summed zeroes and failed. Numbers here
# are parsed and printed, never shown to a person, so one locale it is.
export LC_ALL=C

SHELL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }
skip(){ echo "  ..    $1"; }

ipc() { qs -c ii ipc call desktopOverview "$@" 2>&1; }

if ! ipc ramState >/dev/null 2>&1; then
    echo "the shell's desktopOverview target is not answering (is qs -c ii running?)"
    exit 2
fi

# The sampler only runs while the grid is on screen, so the grid has to be
# open for the cards to have anything to say -- and the check must not leave it
# standing over whatever the user was doing.
was_open=false
if ipc debug | grep -q 'open=true'; then
    was_open=true
else
    ipc open >/dev/null
fi
cleanup() {
    [ "$was_open" = false ] && ipc close >/dev/null 2>&1
    rm -f /tmp/dmc-clients.json
}
trap cleanup EXIT
sleep 2.5   # first sample on the way in, then the ~2 s resources tick

echo "=== what the cards bill (from the shell) ==="
state="$(ipc ramState)"
echo "  $state"
echo

hyprctl clients -j > /tmp/dmc-clients.json
truth="$(python3 - <<'PY'
import json, os

def read(pid, where, key):
    """Bytes of `key` (VmRSS in status, Pss in smaps_rollup) for one pid."""
    try:
        with open(f"/proc/{pid}/{where}") as handle:
            for line in handle:
                if line.startswith(key):
                    return int(line.split()[1]) * 1024
    except OSError:
        return 0
    return 0

procs = {}
for entry in os.listdir("/proc"):
    if not entry.isdigit():
        continue
    pid = int(entry)
    try:
        with open(f"/proc/{pid}/stat") as handle:
            line = handle.read()
        ppid = int(line[line.rindex(")") + 2:].split()[1])
    except (OSError, ValueError, IndexError):
        continue
    procs[pid] = ppid

children = {}
for pid, ppid in procs.items():
    children.setdefault(ppid, []).append(pid)

def tree(pid):
    found, stack = {pid}, [pid]
    while stack:
        for child in children.get(stack.pop(), []):
            if child not in found:
                found.add(child)
                stack.append(child)
    return found

with open("/proc/meminfo") as handle:
    meminfo = {}
    for line in handle:
        if ":" in line:
            key, _, value = line.partition(":")
            meminfo[key.strip()] = int(value.strip().split()[0])

total = meminfo["MemTotal"] * 1024
used = (meminfo["MemTotal"] - meminfo["MemAvailable"]) * 1024

by_desktop = {}
for client in json.load(open("/tmp/dmc-clients.json")):
    by_desktop.setdefault(client["workspace"]["id"], []).append(client)

for desktop in sorted(by_desktop):
    own = 0
    whole = set()
    for client in by_desktop[desktop]:
        pid = client.get("pid", 0)
        own += read(pid, "status", "VmRSS:")
        whole |= tree(pid)
    print(f"{desktop} {own} {sum(read(p, 'status', 'VmRSS:') for p in whole)} {len(whole)}")
print(f"# {total} {used}")
PY
)"

# ── the numbers, side by side ──────────────────────────────────────────────
declare -A card_of own_of tree_of
while read -r line; do
    case "$line" in
    '# '*) read -r _ total used <<<"$line" ;;
    '') ;;
    *)
        read -r id own whole count <<<"$line"
        own_of[$id]="$own"; tree_of[$id]="$whole"; tree_count[$id]="$count"
        ;;
    esac
done <<<"$truth"

for pair in $state; do
    case "$pair" in
    total=*|used=*) continue ;;
    esac
    id="${pair%%:*}"
    rest="${pair#*:}"
    card_of[$id]="$(python3 -c "print(int(float('${rest%%/*}'.rstrip('GB'))*1073741824))")"
done

echo "=== per desktop: card vs the window's own pid vs its whole tree ==="
printf '  %-9s %10s %12s %12s %6s\n' desktop card pid-only tree procs
for id in $(printf '%s\n' "${!own_of[@]}" | sort -n); do
    card="${card_of[$id]:-0}"
    printf '  %-9s %9.2fG %11.2fG %11.2fG %6s\n' \
        "$id" \
        "$(python3 -c "print($card/1073741824)")" \
        "$(python3 -c "print(${own_of[$id]}/1073741824)")" \
        "$(python3 -c "print(${tree_of[$id]}/1073741824)")" \
        "${tree_count[$id]}"
done
echo

echo "1. a desktop bills its apps' whole process trees, not just the window that owns them"
for id in $(printf '%s\n' "${!own_of[@]}" | sort -n); do
    card="${card_of[$id]:-0}"
    own="${own_of[$id]}"
    whole="${tree_of[$id]}"
    # Only meaningful where the app really is multi-process: a single small
    # window is its own whole tree, and requiring more of it would be asking
    # the card to invent memory.
    if [ "$whole" -lt $(( own * 3 / 2 )) ]; then
        skip "desktop $id is one process ($(python3 -c "print(round($own/1048576))") MB); nothing to spread"
        continue
    fi
    if [ "$card" -gt $(( own * 12 / 10 )) ]; then
        ok "desktop $id bills $(python3 -c "print(f'{$card/1073741824:.2f}')") GB, not the $(python3 -c "print(f'{$own/1073741824:.2f}')") GB of its window's own pid"
    else
        bad "desktop $id bills $(python3 -c "print(f'{$card/1073741824:.2f}')") GB, which is the window's own pid ($(python3 -c "print(f'{$own/1073741824:.2f}')") GB) and not its tree ($(python3 -c "print(f'{$whole/1073741824:.2f}')") GB)"
    fi
done
echo

echo "2. and nothing MORE than that tree: no process is billed twice"
for id in $(printf '%s\n' "${!own_of[@]}" | sort -n); do
    card="${card_of[$id]:-0}"
    whole="${tree_of[$id]}"
    # Slack for the sample being up to ~2 s old, in which a tree can grow.
    if [ "$card" -le $(( whole + 536870912 )) ]; then
        ok "desktop $id stays inside its own tree"
    else
        bad "desktop $id bills $(python3 -c "print(f'{$card/1073741824:.2f}')") GB for a $(python3 -c "print(f'{$whole/1073741824:.2f}')") GB tree: something is counted more than once"
    fi
done
echo

echo "3. the \"+\" slot is not a desktop"
last="$(printf '%s' "$state" | grep -o '[0-9]*:[0-9.]*GB/[0-9.]*%' | tail -1)"
slot="${last%%:*}"
boo() { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: expected [$3] got [$2]"; }
# The slot is the highest cell, one past the highest desktop with a card.
highest="$(printf '%s\n' "${!card_of[@]}" | sort -n | tail -1)"
if [ -n "${card_of[$highest]:-}" ] && [ "${card_of[$highest]}" = "0" ] \
    && [ -z "${own_of[$highest]:-}" ]; then
    ok "the empty slot (cell $highest) bills nothing"
else
    bad "cell $highest is not an empty slot (card=${card_of[$highest]:-unset})"
fi
echo

echo "4. the cards together are in the same universe as the machine"
# `${card_of[$id]}`, not `card_of[id]`: inside $(( )) the subscript is an
# arithmetic expression, so the bare word `id` is a variable that does not
# exist and every term is 0 -- a sum that quietly means nothing.
sum=0
for id in "${!card_of[@]}"; do sum=$(( sum + ${card_of[$id]} )); done
share="$(python3 -c "print(f'{$sum*100/$used:.0f}')")"
if [ "$sum" -ge $(( used / 5 )) ] && [ "$sum" -le $(( used * 13 / 10 )) ]; then
    ok "cards sum to ${share}% of used memory ($(python3 -c "print(f'{$sum/1073741824:.1f}')") GB of $(python3 -c "print(f'{$used/1073741824:.1f}')") GB used of $(python3 -c "print(f'{$total/1073741824:.0f}')") GB)"
else
    bad "cards sum to ${share}% of used memory: $(python3 -c "print(f'{$sum/1073741824:.2f}')") GB of $(python3 -c "print(f'{$used/1073741824:.2f}')") GB used"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
