#!/usr/bin/env bash
# Trims Freebuff Desktop's per-project chat history so switching a session does
# not have to hydrate years of transcript.
#
# WHY THIS EXISTS
# ---------------
# Switching sessions in the desktop app takes 6-30 seconds on this machine. The
# measured cause is the transcript itself, not the disk or the process:
#
#   project                          messages   text      biggest thread
#   grafizum-dashboard  (426 MB)        2922    179 MB    1873 msgs / 122 MB
#   matrix-4b5e         (310 MB)           6      1 MB    (301 MB of dead pages)
#   mt5-bot             (125 MB)         777     41 MB    777 msgs / 40 MB
#   matrix-7a01         (118 MB)         969     52 MB    969 msgs / 52 MB
#
# A full read+parse of the grafizum store takes ~2.9 s in Python before any
# rendering; in the app it is followed by markdown, highlighting and layout for
# every message. Trimming the oldest messages per thread to a recent window was
# measured on a COPY of that database:
#
#   before  2922 msgs  read 2098 ms  parse 834 ms  file 426 MB
#   after   1024 msgs  read   55 ms  parse 205 ms  file  66 MB
#
# integrity_check: ok.  Full-text search still answered (321 hits).
#
# WHAT IT COSTS
# -------------
# The deleted messages are gone from the app, from its search index and from any
# context an agent would send with a new turn. They are archived first (see
# --archive), so this is recoverable by hand, but the app will not show them.
#
# WHAT IS SAFE ABOUT IT
# ---------------------
# The messages table has DELETE triggers that remove the matching full-text rows
# (freebuff_conversation_search_delete), so the search index stays consistent;
# this is verified, not assumed. A VACUUM afterwards returns the freed pages --
# the two biggest stores were carrying 223 MB and 301 MB of freelist, which the
# app never gives back on its own.
#
# Usage:
#   freebuff-trim-history.sh                 # dry run: report only
#   freebuff-trim-history.sh --apply         # archive, trim, vacuum
#   freebuff-trim-history.sh --apply --keep 500
#   freebuff-trim-history.sh --apply --min-messages 200   # skip small stores
#
# The app must be CLOSED: it holds these databases open in WAL mode, and
# rewriting one underneath a running app is how a store gets corrupted.

set -euo pipefail

PROJ="${HOME}/.config/freebuff-desktop/projects"
ARCHIVE="${HOME}/.cache/freebuff-history-archive"
APPLY=0
KEEP=300
MIN_MESSAGES=200

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --keep) KEEP="${2:?--keep needs a number}"; shift ;;
    --min-messages) MIN_MESSAGES="${2:?--min-messages needs a number}"; shift ;;
    --archive) ARCHIVE="${2:?--archive needs a path}"; shift ;;
    -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# A dry run only reads, so the app may stay open for it. --apply must not.
if [ "$APPLY" = 1 ] && { pgrep -x freebuff >/dev/null 2>&1 || pgrep -f "freebuff-desktop/orchestrator.js" >/dev/null 2>&1; }; then
  echo "Freebuff Desktop is RUNNING. Close it first -- it keeps these stores open" >&2
  echo "in WAL mode, and trimming one underneath it can corrupt it." >&2
  exit 1
fi

if [ "$APPLY" = 1 ]; then
  mkdir -p "$ARCHIVE"
fi

python3 - "$PROJ" "$KEEP" "$MIN_MESSAGES" "$APPLY" "$ARCHIVE" <<'PY'
import gzip, json, os, sqlite3, sys, time

proj, keep, min_messages, apply, archive = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4] == "1", sys.argv[5]
stamp = time.strftime("%Y%m%d-%H%M%S")

stores = []
for name in sorted(os.listdir(proj)):
    db = os.path.join(proj, name, "desktop-v2.db")
    if os.path.exists(db):
        stores.append((name, db))
stores.sort(key=lambda s: os.path.getsize(s[1]), reverse=True)

print(f"{'project':34} {'msgs':>6} {'keep':>5} {'text':>8} {'file':>8} {'dead':>8}")
total_before = total_after = 0
for name, db in stores:
    c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        n, byt = c.execute("select count(*), coalesce(sum(length(parts_json)),0) from messages").fetchone()
        pages = c.execute("pragma page_count").fetchone()[0]
        free = c.execute("pragma freelist_count").fetchone()[0]
    except sqlite3.DatabaseError:
        c.close(); continue
    c.close()
    dead = free * 4096
    if n < min_messages:
        continue
    kept = min(n, keep * max(1, 1))
    total_before += os.path.getsize(db)
    print(f"{name[:34]:34} {n:6} {keep:5} {byt/1048576:7.0f}M {os.path.getsize(db)/1048576:7.0f}M {dead/1048576:7.0f}M")
    if not apply:
        continue

    c = sqlite3.connect(db)
    c.execute("pragma journal_mode=wal")
    c.execute("pragma foreign_keys=on")
    threads = [r[0] for r in c.execute("select id from threads")]
    victims = []
    for tid in threads:
        cnt = c.execute("select count(*) from messages where thread_id=?", (tid,)).fetchone()[0]
        if cnt <= keep:
            continue
        cut = c.execute("select seq from messages where thread_id=? order by seq desc limit 1 offset ?",
                        (tid, keep)).fetchone()[0]
        for row in c.execute("""select seq, thread_id, role, ts, parts_json, attachments_json, metrics_json
                                from messages where thread_id=? and seq<=? order by seq""", (tid, cut)):
            victims.append(row)
    if not victims:
        c.close()
        continue

    # Archive first, in a stream: the deleted rows are the only copy.
    apath = os.path.join(archive, f"{name[:40]}-{stamp}.jsonl.gz")
    with gzip.open(apath, "wt", encoding="utf-8") as fh:
        for seq, tid, role, ts, parts, atts, metrics in victims:
            fh.write(json.dumps({"seq": seq, "thread_id": tid, "role": role, "ts": ts,
                                 "parts_json": parts, "attachments_json": atts,
                                 "metrics_json": metrics}) + "\n")

    c.executemany("delete from messages where seq=?", [(v[0],) for v in victims])
    c.commit()
    c.execute("vacuum")
    c.close()
    total_after += os.path.getsize(db)
    print(f"   -> archived {len(victims)} rows to {apath}")
    print(f"   -> now {os.path.getsize(db)/1048576:.0f} MB  "
          f"(integrity: {sqlite3.connect(db).execute('pragma integrity_check').fetchone()[0]})")

if apply:
    print(f"\ntotal {total_before/1048576:.0f} MB -> {total_after/1048576:.0f} MB")
else:
    print("\ndry run: nothing was written. Re-run with --apply to archive, trim and vacuum.")
PY
