#!/usr/bin/env python3
"""One snapshot of the running processes, as JSON on stdout.

This is what makes the hardware card an actual task manager rather than a moving
graph: a list you can sort, read and act on.

Why it reads /proc itself instead of shelling out to `ps`:

  * **CPU has to be a rate, not an average.** `ps` reports the average since the
    process started, so a browser that has been open for six hours shows 2% no
    matter how hard it is working right now, which is the opposite of useful.
    Two samples of /proc/<pid>/stat a fraction of a second apart, compared
    against the same two samples of /proc/stat, give the percentage of the
    machine being used *at this moment* -- what every other task manager shows.
  * **One source, one tick.** Listing from `ps` and timing from `top` would mean
    joining two snapshots taken at different moments by pid, and processes that
    appear or vanish in between simply fall out of the list.

Output is a JSON array, sorted by CPU descending, one object per process:

    {"pid": 123, "ppid": 1, "name": "kitty", "app": "kitty", "command": "kitty -1",
     "user": "matrix", "state": "S", "cpu": 4.2, "memory": 81234560, "started": 1757}

`memory` is resident bytes. `cpu` is percent of the whole machine (so a process
pinning four cores reads 400). `started` is a Unix timestamp.

`--kill PID [PID...]` instead ends those processes and prints what happened:

    {"killed": [123], "forceKilled": [456], "failed": [{"pid": 9, "error": "Operation not permitted"}]}

`killed` is what was signalled, `forceKilled` the subset that needed the
SIGKILL follow-up because SIGTERM alone did not take it (see
KILL_GRACE_SECONDS), and `failed` every refusal with its reason.

Killing lives here, next to the listing, so the shell never has to assemble a
`kill` command line of its own, and so the reason a kill failed comes back as
text a person can read -- "Operation not permitted" is what the card shows as
"Access is denied", which is what every other task manager calls it.
"""

import json
import os
import pwd
import signal
import sys
import time

SAMPLE_SECONDS = float(os.environ.get("II_PROCESS_SAMPLE_SECONDS", "0.35"))
TOP = int(os.environ.get("II_PROCESS_TOP", "0") or 0)
# How long a polite SIGTERM gets before the same call comes back and finishes
# the job with SIGKILL. End task must END the task: the other task manager's
# button is not a suggestion, and "it did nothing" is the one report this path
# exists to make impossible. One second: long enough for an app that quits on
# SIGTERM to do it cleanly (they answer in a few hundred ms), short enough that
# a frozen app -- the case where End task is being pressed at all -- or an app
# sitting on an "are you sure" dialog is gone while the click is still in the
# user's mind. Tunable for anyone whose workflow needs a slower fallback.
KILL_GRACE_SECONDS = float(os.environ.get("II_PROCESS_KILL_GRACE", "1.0"))


def total_jiffies():
    with open("/proc/stat") as handle:
        fields = handle.readline().split()[1:]
    return sum(int(f) for f in fields)


def clock_ticks():
    """Jiffies per second, for turning starttime into seconds."""
    return os.sysconf("SC_CLK_TCK") or 100


def boot_time():
    """Boot timestamp, so a process start time can be an absolute time."""
    try:
        with open("/proc/stat") as handle:
            for line in handle:
                if line.startswith("btime"):
                    return int(line.split()[1])
    except OSError:
        pass
    return int(time.time())


def process_stat_fields(stat_line):
    """(utime+stime, ppid, starttime) from one /proc/<pid>/stat line.

    The second field of /proc/<pid>/stat is the command name in parentheses, and
    it may itself contain spaces and parentheses, so the split has to start from
    the LAST ')' rather than from the first space -- splitting naively is what
    turns a process called "foo (bar)" into a parse error.
    """
    end = stat_line.rfind(")")
    if end < 0:
        return None
    rest = stat_line[end + 2:].split()
    if len(rest) < 20:
        return None
    return int(rest[11]) + int(rest[12]), int(rest[1]), int(rest[19])


def process_cpu_jiffies(stat_line):
    """utime + stime (fields 14 and 15) from one /proc/<pid>/stat line."""
    fields = process_stat_fields(stat_line)
    return None if fields is None else fields[0]


def snapshot():
    """{pid: cpu jiffies} for everything in /proc."""
    out = {}
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        pid = int(entry)
        try:
            with open(f"/proc/{pid}/stat") as handle:
                line = handle.read()
        except OSError:
            continue
        jiffies = process_cpu_jiffies(line)
        if jiffies is not None:
            out[pid] = jiffies
    return out


def username(uid):
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:
        return str(uid)


def app_name(argv0, fallback):
    """A name worth showing in a list, from the first word of the command line.

    `/proc/<pid>/comm` is capped at 15 characters by the kernel, which turned
    every Electron helper on this machine into "@codebufffreebu". The real
    program name is in argv[0]; taking its basename gives the whole thing, and
    it is the same word the window title and the launcher use.
    """
    if not argv0:
        return fallback
    # argv[0] is normally the program's PATH, and the name is its last
    # component -- spaces and all: "/home/user/My Projects/.../esbuild" is
    # ONE argument whose basename is "esbuild". Splitting that on whitespace
    # is what named a whole folder of the machine "My".
    #
    # But a re-exec'd child -- Chromium's zygote, and anything that rewrites the
    # cmdline into a process title -- has its WHOLE command line in argv[0]: one
    # NUL-terminated string, arguments after the program separated by spaces.
    # There the first space IS the boundary. Without this every Electron helper
    # comes back as "Claude --standard-schemes=…" or "Freebuff --shared-files=…"
    # instead of the program's name.
    name = os.path.basename(argv0.rstrip("/")) or fallback
    if any(ch.isspace() for ch in name):
        name = os.path.basename(argv0.split()[0].rstrip("/")) or fallback
    # AppImages mount under /tmp/.mount_*, and interpreters run scripts by path;
    # what matters is the last component either way, which basename already gave
    # us. A ".exe" suffix is the one decoration worth removing.
    if name.lower().endswith(".exe"):
        name = name[:-4]
    return name


def describe(pid, previous, current, delta_total, boot):
    """Everything we can say about one pid, or None if it is gone."""
    base = f"/proc/{pid}"
    try:
        status = {}
        with open(f"{base}/status") as handle:
            for line in handle:
                if ":" in line:
                    key, _, value = line.partition(":")
                    status[key.strip()] = value.strip()
        with open(f"{base}/cmdline", "rb") as handle:
            raw = handle.read()
        with open(f"{base}/stat") as handle:
            stat_line = handle.read()
    except OSError:
        return None

    name = status.get("Name", "?")
    uid_field = status.get("Uid", "0").split()
    uid = int(uid_field[0]) if uid_field else 0
    state = status.get("State", "?").split()[0]
    memory = int(status.get("VmRSS", "0 kB").split()[0]) * 1024

    # /proc/<pid>/cmdline is NUL-separated: one NUL per argv boundary. This
    # used to turn every NUL into a space and then split on whitespace, which
    # splits an ARGUMENT that contains a space -- and argv[0] very often does,
    # because a program installed under "~/My Projects" has a space in its own
    # path. Every such process was then named after the first path segment:
    # /home/user/My Projects/.../esbuild came back as "My", so the task
    # manager listed one 36-row application called "My" and the name column
    # said nothing about what was running. Split on the NULs instead: those are
    # the argv boundaries, and a space inside an argument stays inside it.
    words = [part.decode("utf-8", "replace") for part in raw.split(b"\x00") if part]
    command = " ".join(words) or name

    fields = process_stat_fields(stat_line)
    ppid = fields[1] if fields else 0
    started = boot + (fields[2] / clock_ticks()) if fields else 0

    cpu = 0.0
    if delta_total > 0 and pid in previous and pid in current:
        cpu = 100.0 * (current[pid] - previous[pid]) / delta_total
    elif pid in current and pid not in previous and delta_total > 0:
        # New process: its whole lifetime is this interval.
        cpu = 100.0 * current[pid] / delta_total

    return {
        "pid": pid,
        "ppid": ppid,
        "name": name,
        "app": app_name(words[0] if words else "", name),
        "command": command,
        "user": username(uid),
        "state": state,
        "cpu": round(max(0.0, cpu), 1),
        "memory": memory,
        "started": int(started),
    }


def alive(pid):
    """True if the pid still exists (signal 0 is a existence probe, not a kill)."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # someone else's, but it is there
    return True


def kill(pid_strings, sig=signal.SIGTERM):
    """End processes, and say exactly why when it does not work.

    SIGTERM by default: the polite ask, which lets an app clean up or offer to
    save its work -- and then, if the process is still there when the grace
    period is up, SIGKILL, because the caller asked for the task to END. A
    process that shows an "are you sure" dialog instead of exiting is exactly
    the case that used to read as a broken button.

    `--force` skips the politeness and sends SIGKILL on the first pass.
    """
    killed = []
    force_killed = []
    failed = []
    sent = []
    for entry in pid_strings:
        try:
            pid = int(entry)
        except ValueError:
            continue
        # pid 1 is init: refusing it is not a limitation, it is the difference
        # between ending a task and ending the session.
        if pid <= 1:
            failed.append({"pid": pid, "error": "Not permitted"})
            continue
        try:
            os.kill(pid, sig)
            killed.append(pid)
            sent.append(pid)
        except ProcessLookupError:
            # Already gone: the outcome the caller wanted, so not a failure.
            killed.append(pid)
        except PermissionError:
            failed.append({"pid": pid, "error": "Operation not permitted"})
        except (OSError, ValueError, OverflowError) as error:
            # OverflowError is a pid too large for the C int the kernel takes;
            # reported like any other refusal rather than crashing the card.
            failed.append({"pid": pid, "error": getattr(error, "strerror", None) or str(error)})

    # Escalate. Only on the polite path: `--force` has already sent SIGKILL,
    # and waiting there would just delay the answer.
    if sent and sig != signal.SIGKILL:
        deadline = time.monotonic() + KILL_GRACE_SECONDS
        while True:
            survivors = [pid for pid in sent if alive(pid)]
            if not survivors:
                break
            if time.monotonic() >= deadline:
                break
            time.sleep(0.05)
        for pid in survivors:
            try:
                os.kill(pid, signal.SIGKILL)
                force_killed.append(pid)
            except ProcessLookupError:
                force_killed.append(pid)
            except PermissionError:
                failed.append({"pid": pid, "error": "Operation not permitted"})
            except OSError as error:
                failed.append({"pid": pid, "error": getattr(error, "strerror", None) or str(error)})

    json.dump({"killed": killed, "forceKilled": force_killed, "failed": failed}, sys.stdout)
    sys.stdout.write("\n")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--kill":
        rest = sys.argv[2:]
        sig = signal.SIGKILL if "--force" in rest else signal.SIGTERM
        kill([entry for entry in rest if entry != "--force"], sig)
        return

    boot = boot_time()
    first_total = total_jiffies()
    first = snapshot()
    time.sleep(SAMPLE_SECONDS)
    second_total = total_jiffies()
    second = snapshot()
    delta_total = max(1, second_total - first_total)

    processes = []
    for pid in second:
        info = describe(pid, first, second, delta_total, boot)
        if info is not None:
            processes.append(info)

    processes.sort(key=lambda p: (-p["cpu"], -p["memory"]))
    if TOP > 0:
        processes = processes[:TOP]

    json.dump(processes, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
