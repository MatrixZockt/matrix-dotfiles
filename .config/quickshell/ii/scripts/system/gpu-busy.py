#!/usr/bin/env python3
"""i915 render-engine busy fraction, in percent, over the gap between calls.

WHY THIS EXISTS
    The island's GPU tile read nvidia-smi's utilization.gpu. On this laptop the
    desktop is rendered by the Intel iGPU and the dGPU only scans the panel out,
    so that number is a hard 0% while the machine is plainly drawing -- the
    complaint this answers ("GPU shows 0% while the graphics card is working",
    2026-11-07). The iGPU has no busy counter of its own: i915 exposes no
    rc6_residency_ms on this kernel (checked), and unlike amdgpu there is no
    gpu_busy_percent. DRM's per-process fdinfo is the only source that says how
    much engine time was actually used.

THE UNIT, WHICH IS THE WHOLE TRICK
    One process can hold SEVERAL render-node fds -- Hyprland holds six -- and
    every one of those fdinfo files reports the SAME accumulated engine time for
    its context. Summing per fd therefore multiplies it: measured 187% for a
    compositor that cannot be more than 100% busy, which is exactly the sort of
    number that gets a feature reverted. Taking the MAX per process and summing
    across processes is what adds up: measured 31% (Hyprland) + 37% (Freebuff)
    + 25% (Xwayland) on a machine that was visibly busy. The result is capped at
    100, because parallel engines are not what a single "GPU %" gauge means.

WHY IT CACHES THE PROCESS LIST AND ITS FDS
    A full scan means walking every fdinfo file on the box, and measured 490 ms
    -- half a core, every sample, for a gauge. The processes holding a render
    node change about never, and neither do their fd numbers, so both are
    remembered in the state file: a sample then reads a handful of files instead
    of a thousand. A full rediscovery happens every --rescan seconds, and also
    whenever nothing in the cached set reports engine time (which is what
    happens right after the GPU clients are replaced). Each remembered fd is
    re-checked against its /dev/dri target before it is read, so a recycled fd
    number is skipped rather than misread.

STATE AND FIRST CALL
    State lives in $XDG_RUNTIME_DIR. A gap longer than --max-gap starts over
    instead of averaging across an idle night, and the FIRST call prints -1
    (unknown) rather than 0: a reading the caller has not earned is worse than
    no reading.

Prints one number: the percentage, or -1.
"""

import json
import os
import sys
import time

MAX_GAP_DEFAULT = 10.0
RESCAN_DEFAULT = 10.0


def engine_in(fdinfo):
    """Accumulated render-engine time in one fdinfo file, in ns."""
    try:
        with open(fdinfo, errors="ignore") as fh:
            text = fh.read()
    except OSError:
        return 0
    for line in text.splitlines():
        if not line.startswith("drm-engine-render:"):
            continue
        try:
            return int(line.split(":", 1)[1].split()[0])
        except (IndexError, ValueError):
            return 0
    return 0


def drm_fds(pid):
    """The fds of this process that point at a DRM render node."""
    fds = []
    try:
        entries = os.scandir(f"/proc/{pid}/fd")
    except OSError:
        return fds
    with entries:
        for entry in entries:
            if not entry.name.isdigit():
                continue
            try:
                if os.readlink(entry.path).startswith("/dev/dri"):
                    fds.append(int(entry.name))
            except OSError:
                continue
    return fds


def engine_for_pid(proc, fds):
    """Max accumulated render-engine time over this process's DRM contexts."""
    best = 0
    for fd in fds:
        try:
            if not os.readlink(f"{proc}/fd/{fd}").startswith("/dev/dri"):
                continue
        except OSError:
            continue
        best = max(best, engine_in(f"{proc}/fdinfo/{fd}"))
    return best


def discover():
    """Full walk: every PID that reports render-engine time, with its fds."""
    found = {}
    try:
        procs = os.scandir("/proc")
    except OSError:
        return found
    with procs:
        for entry in procs:
            if not entry.name.isdigit():
                continue
            pid = int(entry.name)
            fds = drm_fds(pid)
            if fds and engine_for_pid(f"/proc/{pid}", fds) > 0:
                found[pid] = fds
    return found


def read_engines(cached):
    return {int(pid): engine_for_pid(f"/proc/{pid}", fds)
            for pid, fds in cached.items()}


def state_path():
    runtime = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
    return os.path.join(runtime, f"qs-gpu-busy-{os.getuid()}.json")


def arg_value(name, default):
    if name not in sys.argv:
        return default
    try:
        return float(sys.argv[sys.argv.index(name) + 1])
    except (IndexError, ValueError):
        return default


def sample(max_gap, rescan):
    """One reading, as an int percentage, or -1."""
    now = time.time()

    previous = None
    try:
        with open(state_path()) as fh:
            previous = json.load(fh)
    except (OSError, ValueError):
        previous = None
    if not isinstance(previous, dict):
        previous = {}

    cached = previous.get("clients") or {}
    scanned_at = float(previous.get("scanned") or 0)
    rediscover = not cached or (now - scanned_at) > rescan

    if rediscover:
        cached = discover()
        scanned_at = now

    engines = read_engines(cached)
    # Nothing in the cached set is using the GPU: the clients were probably
    # replaced (a browser restarted, the compositor relaunched), so the cached
    # list is stale. Find the real ones next call rather than reporting 0%.
    if not rediscover and not any(engines.values()):
        rediscover = True

    total = sum(engines.values())

    try:
        with open(state_path(), "w") as fh:
            json.dump({"t": now, "ns": total, "clients": cached,
                       "scanned": scanned_at}, fh)
    except OSError:
        pass

    try:
        dt = now - float(previous["t"])
        before = int(previous["ns"])
    except (KeyError, TypeError, ValueError):
        return -1

    if dt <= 0 or dt > max_gap or total < before:
        return -1

    pct = (total - before) / (dt * 1e9) * 100.0
    return int(round(max(0.0, min(100.0, pct))))


def main():
    max_gap = arg_value("--max-gap", MAX_GAP_DEFAULT)
    rescan = arg_value("--rescan", RESCAN_DEFAULT)
    # --loop N keeps one interpreter alive and prints a line every N seconds.
    # The caller uses this because a fresh python costs ~30 ms of start-up:
    # four of those a second, on the shell's 250 ms tick, would spend a seventh
    # of a core on a gauge. With the loop that cost is paid once.
    loop = arg_value("--loop", 0)

    if loop <= 0:
        print(sample(max_gap, rescan))
        return
    while True:
        print(sample(max_gap, rescan), flush=True)
        time.sleep(loop)


if __name__ == "__main__":
    main()
