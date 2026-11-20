#!/usr/bin/env bash
# Probes what Freebuff Desktop does during a session switch.
# Samples once per second while the user switches threads:
#   - the main renderer: user CPU, RSS, swap, bytes read from disk
#   - the orchestrator: CPU and child processes (does a runtime get spawned?)
#   - WAL size of every project DB (which DB is being touched)
# Read-only: it only reads /proc and stat()s files.
#
# Usage: freebuff-switch-probe.sh [seconds] [outfile]

set -u
DURATION="${1:-240}"
OUT="${2:-/tmp/freebuff-switch-probe.tsv}"
PROJ="${HOME}/.config/freebuff-desktop/projects"

find_pid() { pgrep -f "$1" | head -1; }

R=$(pgrep -f "type=renderer.*/tmp/.mount_Freebu" | while read -r p; do
      awk '/VmRSS/{print $2, FILENAME}' "/proc/$p/status" 2>/dev/null
    done | sort -nr | head -1 | awk '{print $2}' | sed 's#/proc/##; s#/status##')
O=$(pgrep -f "orchestrator.js" | head -1)

[ -z "${R:-}" ] && { echo "no renderer found" >&2; exit 1; }
[ -z "${O:-}" ] && { echo "no orchestrator found" >&2; exit 1; }

echo "renderer=$R orchestrator=$O duration=${DURATION}s -> $OUT" >&2

printf 't\tr_user_s\tr_rss_mb\tr_swap_mb\tr_read_mb\to_cpu_s\tn_child\tnew_pids\twal_total_mb\n' > "$OUT"

prev_u=$(awk '{print $14+$15}' "/proc/$R/stat")
prev_o=$(awk '{print $14+$15}' "/proc/$O/stat")
prev_rd=$(awk '/read_bytes/{print $2}' "/proc/$R/io")
prev_children=$(pgrep -P "$O" | sort | tr '\n' ',')

i=0
while [ "$i" -lt "$DURATION" ]; do
  sleep 1
  i=$((i+1))

  u=$(awk '{print $14+$15}' "/proc/$R/stat" 2>/dev/null) || break
  o=$(awk '{print $14+$15}' "/proc/$O/stat" 2>/dev/null) || break
  rd=$(awk '/read_bytes/{print $2}' "/proc/$R/io" 2>/dev/null) || rd=$prev_rd

  rss=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$R/status")
  swp=$(awk '/VmSwap/{print int($2/1024)}' "/proc/$R/status")

  kids=$(pgrep -P "$O" | sort)
  nchild=$(echo "$kids" | grep -c . )
  newp=$(comm -13 <(echo "$prev_children" | tr ',' '\n' | sort) <(echo "$kids" | sort) | tr '\n' ',' )

  wal=$(find "$PROJ" -name 'desktop-v2.db-wal' -newermt '-3 seconds' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{printf "%.1f", s/1048576}')

  awk -v t="$i" -v rss="$rss" -v swp="$swp" -v nc="$nchild" \
      -v np="${newp:-}" -v wal="${wal:-0}" \
      -v rc="$((u-prev_u))" -v rdm="$((rd-prev_rd))" -v oc="$((o-prev_o))" \
      'BEGIN { printf "%d\t%.2f\t%d\t%d\t%.1f\t%.2f\t%d\t%s\t%s\n", t, rc/100, rss, swp, rdm/1048576, oc/100, nc, np, wal }' >> "$OUT"

  prev_u=$u; prev_o=$o; prev_rd=$rd
  prev_children=$(echo "$kids" | sort | tr '\n' ',')
done

echo "done, $i samples in $OUT" >&2
