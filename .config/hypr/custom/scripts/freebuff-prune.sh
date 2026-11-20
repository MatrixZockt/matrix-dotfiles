#!/usr/bin/env bash
# Trim Freebuff Desktop's operation-receipt directory.
#
# WHAT THIS IS FOR
# ----------------
# Freebuff keeps one tiny file per device operation in
#     ~/.config/freebuff-desktop/state.json.device-operations/
# (64 bytes each, named <sha>.started). Nothing ever deletes them, so on this
# box the directory had grown to 40 047 files / 164 MB allocated -- measured
# 2026-11-20 -- at roughly +3 400 files per day. Allocation is 4 KB per file
# because each one is smaller than a block, so 40 k files cost 160 MB of disk
# to store 2.5 MB of data.
#
# WHAT IT DOES AND DOES NOT DO
# ----------------------------
# It deletes only regular files older than --days in that one directory. It
# does not touch state.json, the projects, chats, cookies, runtimes or any
# cache the app itself manages -- those either matter or are already bounded.
#
# Deleting receipts is safe because a receipt records an operation that has
# already finished: the app writes <sha>.started when it starts an operation
# and nothing in the file is read again once the operation is done. Anything
# aged past the window cannot be in flight, which is why the default age is a
# week rather than "everything but today".
#
# HONEST EXPECTATION
# ------------------
# This does NOT make Freebuff faster in any way a person can feel. Measured
# before/after on this machine: reading the whole directory costs ~12 ms for
# 40 k entries and ~6 ms for 25 k, and the app only stats the handful of
# receipts it is actively waiting on. The win is 60 MB of disk and 15 k inodes
# back, and keeping the directory from doubling every fortnight. Startup time
# is dominated by Electron + the bundled runtime + project restore, not by
# this directory. If Freebuff feels slow, the cause is elsewhere.
#
# USAGE
#   freebuff-prune.sh                 prune receipts older than 7 days
#   freebuff-prune.sh --days 3        keep a shorter window
#   freebuff-prune.sh --dry-run       report, delete nothing
#   freebuff-prune.sh --state PATH    use another state.json path
#                                     (matches FREEBUFF_DESKTOP_STATE_PATH)
#
# Installed as a daily systemd user timer: freebuff-prune.timer.
# Runs even when Freebuff is open: it only removes files old enough that no
# live operation can refer to them.
set -uo pipefail

DAYS=7
DRY=0
STATE="$HOME/.config/freebuff-desktop/state.json"

while (( $# )); do
    case "$1" in
        --days) DAYS="${2:-}"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        --state) STATE="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
        *) echo "freebuff-prune: unknown argument: $1" >&2; exit 2 ;;
    esac
done

if ! [[ "$DAYS" =~ ^[0-9]+$ ]] || (( DAYS < 1 )); then
    echo "freebuff-prune: --days must be a positive integer" >&2
    exit 2
fi

DIR="${STATE}.device-operations"

# Not an error: Freebuff may not be installed, or may be using another
# profile (the launcher sets FREEBUFF_DESKTOP_STATE_PATH). A timer must not
# fail every night over that.
if [[ ! -d "$DIR" ]]; then
    exit 0
fi

MIN=$(( DAYS * 1440 ))

count_all() { find "$DIR" -maxdepth 1 -type f | wc -l; }
kb_alloc() { du -sk "$DIR" 2>/dev/null | cut -f1; }

before_n=$(count_all)
before_kb=$(kb_alloc)

# -mmin +N means "modified more than N minutes ago", so the boundary is
# inclusive of the window rather than off by one day the way -mtime rounds.
old_n=$(find "$DIR" -maxdepth 1 -type f -mmin "+$MIN" | wc -l)

if (( DRY )); then
    echo "freebuff-prune: would delete $old_n of $before_n files older than ${DAYS}d ($(du -sm "$DIR" 2>/dev/null | cut -f1) MB dir)"
    exit 0
fi

start_ms=$(date +%s%3N)
find "$DIR" -maxdepth 1 -type f -mmin "+$MIN" -delete
end_ms=$(date +%s%3N)

after_n=$(count_all)
after_kb=$(kb_alloc)

echo "freebuff-prune: ${DAYS}d window — deleted $(( before_n - after_n )) of $before_n receipts in $(( end_ms - start_ms )) ms; dir $(( after_kb / 1024 )) MB, $after_n files left (was $(( before_kb / 1024 )) MB)"
exit 0
