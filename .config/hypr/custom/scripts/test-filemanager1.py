#!/usr/bin/env python3
"""End-to-end test of "show in file manager" (org.freedesktop.FileManager1).

Asks for a file the way an app asks -- a D-Bus call on the well-known name a
file manager claims, which is how an app says "here is one I already have, show
me where it is" (the item next to a finished download, "open containing
folder", "reveal in file manager"). That this machine's browsers really do
speak this name is checkable and checked: the string
`org.freedesktop.FileManager1` is in Brave's binary. WHICH of its methods a
particular app calls is not asserted here, and does not matter -- this service
answers all three the same way, so the test drives ShowItems (the one for "show
me these items") and the folders/properties ones in ii-portal.py share its path.

It then reads back what the file manager is actually showing, over the file
manager's own IPC probes, and asserts the two halves of the request -- either
one alone is the bug:

  * the right FOLDER is open (a file's folder, not the file listed as though it
    were a folder -- which is what the window used to do when it had to start
    from nothing), and
  * the FILE is SELECTED (the item is what was asked for; landing in the folder
    without it is "it opened somewhere near what I wanted").

BOTH ORIGINS ARE COVERED, and they are different code paths: the first case
starts the file manager from cold (no copy running -- the common one, since the
app lets itself go five minutes after it is hidden, so what the launcher passes
at startup is what answers it), and the later cases arrive at a copy that is
already up (the IPC `openPath` path). A fix in one of them leaves the other
broken -- that is not a hypothetical, it is the bug this check was written
after.

Everything happens in a scratch folder under /tmp (a file with a SPACE in its
name, since these arrive percent-encoded over the bus), so the check never
touches real files. The file manager window is opened on screen and left open:
that window IS the artifact under test, and the app closes itself after being
hidden for five minutes. To close it now:

  pid=$(pgrep -f 'filemanager\\.qml' | head -1) && qs ipc --pid "$pid" call files quit

Usage: test-filemanager1.py        run every case
Exit:  0 all checks passed, 1 something did not respond as it must
"""

import json
import os
import subprocess
import sys
import time

import gi

gi.require_version("GLib", "2.0")
gi.require_version("Gio", "2.0")

from gi.repository import Gio, GLib  # noqa: E402

BUS_NAME = "org.freedesktop.FileManager1"
OBJ_PATH = "/org/freedesktop/FileManager1"
IFACE = "org.freedesktop.FileManager1"

# A scratch tree with the shapes that used to break things: a space in a file
# name (the URI arrives percent-encoded), and a subfolder to wander into so a
# reveal has something to come BACK from.
SCRATCH = "/tmp/ii-fm1-check"
SUB_DIR = "subdir"
FILE_NAME = "alpha file.txt"


def say(text=""):
    print(text, flush=True)


def fm_pid():
    """The Files APP's pid -- not a picker dialog's, and not the shell's.

    The same rule the launcher uses: a Quickshell running filemanager.qml, and
    NOT carrying II_FILES_PICKER (a picker is a transient answer to a portal
    request; it answers `ping` too, and addressing it here would report on the
    wrong window).
    """
    me = os.getpid()
    for entry in sorted(os.listdir("/proc")):
        if not entry.isdigit() or int(entry) == me:
            continue
        try:
            with open(f"/proc/{entry}/cmdline", "rb") as fh:
                argv = [a.decode("utf-8", "replace")
                        for a in fh.read().split(b"\0") if a]
            with open(f"/proc/{entry}/environ", "rb") as fh:
                env = fh.read().split(b"\0")
        except OSError:
            continue
        if not any(a.endswith("/filemanager.qml") for a in argv):
            continue
        if any(a.startswith(b"II_FILES_PICKER=") for a in env):
            continue
        return int(entry)
    return None


def ipc(pid, func, *args):
    out = subprocess.run(["qs", "ipc", "--pid", str(pid), "call", "files",
                          func, *args],
                         capture_output=True, text=True, timeout=20)
    return out.stdout.strip()


def wait_for_app(timeout=40.0):
    """Wait for the app to be up AND answering: a pid alone is a window that is
    still loading, and a probe sent there answers nothing.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        pid = fm_pid()
        if pid and ipc(pid, "ping") == "files":
            return pid
        time.sleep(0.2)
    return None


def call(method, uri):
    """The bus call, made the way an app makes it (no arguments but the URI and
    its startup id -- and no return value to wait for).
    """
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    bus.call_sync(BUS_NAME, OBJ_PATH, IFACE, method,
                  GLib.Variant("(ass)", ([uri], "")), None,
                  Gio.DBusCallFlags.NONE, 5000, None)


def state(pid):
    return json.loads(ipc(pid, "probeState"))


def uri_for(path):
    return "file://" + path


FAILS = []


def check(name, ok, detail=""):
    say(f"  {'PASS' if ok else 'FAIL'}  {name}")
    if detail:
        say(f"        {detail}")
    if not ok:
        FAILS.append(name)


def main():
    target = os.path.join(SCRATCH, FILE_NAME)
    sub = os.path.join(SCRATCH, SUB_DIR)
    os.makedirs(sub, exist_ok=True)
    with open(target, "w") as fh:
        fh.write("scratch file for test-filemanager1.py\n")

    # ── Case 1: from cold. The app is not running (it was quit, or it let
    # itself go); the request therefore has to START it, and what the launcher
    # was handed decides where it lands.
    was_running = fm_pid()
    if was_running:
        say(f"(a Files window is already up, pid {was_running} -- case 1 is the "
            f"raise path, not a cold start; quit it first for the other half)")
    say("─ cold/raise: ShowItems on a FILE")
    call("ShowItems", uri_for(target))
    pid = wait_for_app()
    if pid is None:
        check("the file manager came up", False,
              "no Quickshell running filemanager.qml answered `files ping`")
        return 1

    # The reveal is a shell round trip (the app stats the path to learn whether
    # it is a file at all) plus the row-finding timer, so give it a beat before
    # reading rather than racing it -- the same wait a person's eye takes.
    time.sleep(1.5)
    st = state(pid)
    check("ShowItems opened the file's FOLDER",
          st.get("path") == SCRATCH,
          f"path={st.get('path')!r} expected {SCRATCH!r}")
    check("ShowItems SELECTED the file",
          st.get("selection") == [target],
          f"selection={st.get('selection')!r} expected {[target]!r}")

    # ── Case 2: the same request while the window is up but somewhere else.
    # The reveal has to come back to the file's folder, which is the half a
    # "raise and open the folder" fix forgets.
    say("─ raise: ShowFolders away, then ShowItems back on the file")
    call("ShowFolders", uri_for(sub))
    time.sleep(1.2)
    check("ShowFolders opened the folder",
          state(pid).get("path") == sub,
          f"path={state(pid).get('path')!r} expected {sub!r}")
    check("ShowFolders left nothing selected",
          state(pid).get("selection") == [],
          f"selection={state(pid).get('selection')!r}")

    call("ShowItems", uri_for(target))
    time.sleep(1.5)
    st = state(pid)
    check("a second ShowItems came BACK to the file's folder",
          st.get("path") == SCRATCH,
          f"path={st.get('path')!r} expected {SCRATCH!r}")
    check("...and selected the file again",
          st.get("selection") == [target],
          f"selection={st.get('selection')!r}")
    check("the window was raised, not duplicated",
          fm_pid() == pid, f"pid={fm_pid()} was {pid}")

    # ── Case 3: ShowItemProperties. This desktop answers it by revealing the
    # item too (see ii-portal.py: a properties dialog is not reachable over
    # IPC yet), so what is asserted is that it is ANSWERED and lands somewhere
    # real -- not the method failing at the bus.
    say("─ ShowItemProperties on a FILE (answered as a reveal, on purpose)")
    call("ShowItemProperties", uri_for(target))
    time.sleep(1.2)
    check("ShowItemProperties was answered and landed on the item's folder",
          state(pid).get("path") == SCRATCH,
          f"path={state(pid).get('path')!r}")

    say()
    if FAILS:
        say(f"✖ {len(FAILS)} check(s) failed: " + ", ".join(FAILS))
        return 1
    say(f"✔ show-in-file-manager works end to end (pid {pid})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
