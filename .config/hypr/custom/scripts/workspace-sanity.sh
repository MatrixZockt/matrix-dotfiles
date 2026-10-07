#!/usr/bin/env bash
# Workspace sanity sweep.
#
# The login/lock path parks the session on a SENTINEL workspace
# (`2147483647 - N`, see modules/ii/lock/Lock.qml) so the lock surface has an
# empty desktop to paint over. Every consumer of workspace ids filters those
# out -- except a window that is still sitting on one after an interrupted
# lock, a shell restart while locked, or a restore that silently failed. Such
# a window is invisible from every desktop the bar can show, which is exactly
# the "my window jumped to a desktop that does not exist" report.
#
# This sweeps any window found outside the sane id range back to the first
# sane workspace. Idempotent and safe to run at boot and after every unlock:
# when nothing is stranded it does nothing at all.
#
#   workspace-sanity.sh          sweep
#   workspace-sanity.sh --dry    list what would move, change nothing
set -euo pipefail

DRY=0
[[ "${1:-}" == "--dry" ]] && DRY=1

# Same rule as services/HyprlandData.qml: 1..100 is the sane range.
python3 - "$DRY" <<'PY'
import json, subprocess, sys

dry = sys.argv[1] == "1"

def hyprctl_json(*args):
    return json.loads(subprocess.run(["hyprctl", *args, "-j"],
                                     capture_output=True, text=True).stdout or "[]")

try:
    clients = hyprctl_json("clients")
except Exception:
    sys.exit(0)

stranded = [c for c in clients
            if not (1 <= (c.get("workspace") or {}).get("id", 0) <= 100)]

if not stranded:
    sys.exit(0)

for c in stranded:
    addr = c.get("address")
    cls = c.get("class", "?")
    bad = (c.get("workspace") or {}).get("id")
    if dry:
        print(f"would move {cls} ({addr}) from workspace {bad} -> 1")
        continue
    subprocess.run(["hyprctl", "dispatch",
                    f'hl.dsp.window.move({{workspace=1, window="address:{addr}"}})'],
                   capture_output=True, text=True)
    print(f"moved {cls} ({addr}) from stranded workspace {bad} -> 1")
PY
