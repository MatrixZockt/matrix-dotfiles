#!/usr/bin/env python3
"""Is a package transaction running right now, and how far along is it?

ONE JSON line on stdout, called once per second by services/PackageUpdate.qml:

    {"active":true,"manager":"pacman","phase":"transaction","count":7,"package":"gtk4"}

    active    a package manager is changing packages right now
    manager   pacman | paru | yay | flatpak
    phase     "transaction" -- packages are being written
              "prepare"     -- a helper is resolving/downloading/building
              ""            -- nothing running
    count     packages changed so far in THIS transaction
    package   the package changed most recently (the one being worked on)

Why pacman.log: it is the only progress source that exists without root and
without parsing someone's terminal. Every ALPM transaction writes
`transaction started`, then one line per package, then `transaction completed`,
so counting the package lines after the newest `transaction started` is the
real number of packages that have landed -- the same number pacman prints.

Phase matters for the feedback: `paru -Syu` spends most of its life as paru
(downloading, building) before pacman ever starts, and that is exactly the
stretch where the desktop used to say nothing at all.
"""

import json
import os
import re
import sys

# Managers that take over the package database. `pacman` is trusted on sight:
# it only runs when a transaction (or a query, which is over in milliseconds
# and is filtered by the caller's debounce) is happening.
MANAGERS = {"pacman", "paru", "yay", "flatpak"}

# Helpers are always running (paru -Qu, yay -Ss...) so they only count when the
# command line is asking for packages to be changed.
CHANGE_ARGS = re.compile(
    r"(^|\s)(-S\S*|-U\S*|-R\S*|--sync|--upgrade|--install|--remove|upgrade|install)(\s|=|$)"
)

# The lines ALPM writes when a package has been changed.
ALPM_PACKAGE = re.compile(
    r"\[ALPM\] (?:upgraded|installed|reinstalled|downgraded|removed) (\S+)"
)

LOG = os.environ.get("PACKAGE_ACTIVITY_LOG", "/var/log/pacman.log")
# Enough tail for a big system upgrade (thousands of lines), small enough that
# reading it every second costs nothing.
LOG_TAIL_BYTES = 400_000


def processes():
    """(comm, args) for every live process we care about."""
    found = []
    try:
        pids = [p for p in os.listdir("/proc") if p.isdigit()]
    except OSError:
        return found
    for pid in pids:
        try:
            with open("/proc/%s/comm" % pid) as handle:
                comm = handle.read().strip()
            if comm not in MANAGERS:
                continue
            with open("/proc/%s/cmdline" % pid, "rb") as handle:
                args = handle.read().replace(b"\0", b" ").decode("utf-8", "replace")
        except OSError:
            continue
        found.append((comm, args))
    return found


def transaction_progress():
    """(count, last package) changed in the newest ALPM transaction."""
    try:
        with open(LOG, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - LOG_TAIL_BYTES))
            text = handle.read().decode("utf-8", "replace")
    except OSError:
        return 0, ""
    # Backwards: the newest transaction, not the whole history.
    lines = text.splitlines()
    count = 0
    last = ""
    for line in reversed(lines):
        if "transaction started" in line:
            break
        match = ALPM_PACKAGE.search(line)
        if match:
            count += 1
            if not last:
                last = match.group(1)
    return count, last


def main():
    running = processes()
    pacman = [p for p in running if p[0] == "pacman"]
    helpers = [p for p in running if p[0] in ("paru", "yay") and CHANGE_ARGS.search(p[1])]
    flatpak = [p for p in running if p[0] == "flatpak" and CHANGE_ARGS.search(p[1])]

    if pacman or flatpak:
        count, last = transaction_progress()
        manager = "flatpak" if (flatpak and not pacman) else "pacman"
        print(json.dumps({"active": True, "manager": manager,
                          "phase": "transaction", "count": count, "package": last}))
        return

    if helpers:
        count, last = transaction_progress()
        print(json.dumps({"active": True, "manager": helpers[0][0],
                          "phase": "prepare", "count": count, "package": last}))
        return

    print(json.dumps({"active": False, "manager": "", "phase": "",
                      "count": 0, "package": ""}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # A watcher that throws is a watcher that reports a false "no update".
        # The caller treats a parse failure the same way, but say it quietly.
        print(json.dumps({"active": False, "manager": "", "phase": "",
                          "count": 0, "package": ""}))
        sys.exit(0)
