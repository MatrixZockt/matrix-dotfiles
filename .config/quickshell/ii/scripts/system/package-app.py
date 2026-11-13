#!/usr/bin/env python3
"""Which APP is this package? One JSON line:

    {"name":"Google Chrome","icon":"google-chrome","desktop":"google-chrome.desktop"}

    {} when the package owns no desktop entry (a library, a daemon, a hook).

Called by services/PackageUpdate.qml when the package being updated changes --
not per second, because this asks pacman for the package's file list and that
is the expensive part.

The whole point is that the bar says "Updating Google Chrome" with Chrome's own
logo, not "Updating google-chrome" with a generic glyph: a package name is an
implementation detail of the package manager, and the person watching the bar
knows the app.
"""

import json
import os
import subprocess
import sys

# A .desktop that is only a protocol handler ("New Private Window",
# "open a magnet link") is not the app's face. The main entry is the one with
# the ordinary name and no url-handler in its filename.
SKIP = ("url-handler", "uri-handler")


def desktop_paths(package):
    try:
        done = subprocess.run(["pacman", "-Ql", package], capture_output=True,
                              text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return []
    paths = []
    for line in done.stdout.splitlines():
        # "pkg /usr/share/applications/foo.desktop"
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        path = parts[1].strip()
        if path.endswith(".desktop") and "/applications/" in path:
            paths.append(path)
    return paths


def read_entry(path):
    name = ""
    icon = ""
    no_display = False
    in_main = True
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.rstrip("\n")
                if line.startswith("["):
                    # Only the [Desktop Entry] group describes the app itself.
                    in_main = line.strip() == "[Desktop Entry]"
                    continue
                if not in_main:
                    continue
                if line.startswith("Name=") and not name:
                    name = line[len("Name="):].strip()
                elif line.startswith("Icon=") and not icon:
                    icon = line[len("Icon="):].strip()
                elif line.startswith("NoDisplay=") and line[len("NoDisplay="):].strip().lower() == "true":
                    no_display = True
    except OSError:
        return None
    if not name:
        return None
    return {"name": name, "icon": icon, "noDisplay": no_display}


def main():
    package = sys.argv[1] if len(sys.argv) > 1 else ""
    if not package:
        print("{}")
        return

    best = None
    for path in desktop_paths(package):
        base = os.path.basename(path).lower()
        if any(skip in base for skip in SKIP):
            continue
        entry = read_entry(path)
        if not entry or entry["noDisplay"]:
            continue
        # A desktop entry under the user's own directory is a launcher somebody
        # wrote, not the app; the packaged one is the real face.
        if path.startswith("/usr/share/applications/"):
            best = entry
            best["desktop"] = os.path.basename(path)
            break
        if best is None:
            best = entry
            best["desktop"] = os.path.basename(path)

    if best is not None:
        # Echo the package back: the caller ignores an answer that arrives
        # after the transaction has already moved on.
        best["package"] = package
    print(json.dumps(best or {}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("{}")
