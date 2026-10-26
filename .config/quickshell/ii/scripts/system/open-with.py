#!/usr/bin/env python3
"""Answer "what can open this file?" -- and then open it with one of them.

Two questions, one script, because they share everything: the XDG data
directories, the .desktop parser, and the field-code rules.

    open-with.py list PATH
        {"path": "...", "mime": "text/plain", "default": "micro.desktop",
         "apps": [{"id": "vim.desktop", "name": "Vim", "icon": "vim",
                   "generic": "Text editor", "terminal": false}, ...]}

    open-with.py run PATH DESKTOP_ID
        Launch that application on that file. Exit status is the answer.

WHY NOT `gio mime` AND `gtk-launch`
-----------------------------------
`gio mime` prints a human sentence in the user's locale ("Default application
for 'text/plain': micro.desktop"), which is a small parsing project per locale
and tells you nothing about the apps that are NOT the default. The Files window
has to SHOW the list -- an "Open with" menu that cannot say what is in it is a
menu with nothing to pick. So the list is built from the .desktop files
themselves, and `gio mime` is only asked one thing: which id is the default.

WHY THE LIST IS FILTERED, AND THEN ISN'T
----------------------------------------
An app that declares the file's MIME type is a candidate. If NOTHING declares
it -- which is exactly the "this file has no default app" case this exists for
-- the alternative to showing every installed application is showing an empty
dialog, so every application is offered instead. The matching ones come first
either way, because the first row is the one that gets clicked.

Exec lines are a mini-language, not a command line: the field codes (%f, %F,
%u, %U, %i, %c, %k, %%, and the deprecated ones that mean "ignore") are
substituted per argument, an app that needs a terminal is given one, and the
process is started detached so the file manager is not its parent.
"""

import json
import os
import shlex
import subprocess
import sys
import urllib.parse

# Where .desktop files live, in the order the spec says to search them. The
# FIRST file for an id wins, which is what makes a user's own override in
# ~/.local/share/applications beat the distribution's copy.
def data_dirs():
    home = os.environ.get("HOME", "/")
    dirs = [os.environ.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share")]
    for d in (os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":"):
        if d:
            dirs.append(d)
    return [os.path.join(d, "applications") for d in dirs]


def parse_desktop(path):
    """The [Desktop Entry] group as a dict, or None if there is nothing usable.

    Values are raw: a localized `Name[de]=...` is skipped rather than guessed
    at, and an old-style `[Desktop Action ...]` group ends the parse -- keys
    after it belong to the action, not to the application.
    """
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return None

    entry = {}
    inside = False
    for line in lines:
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith("[") and s.endswith("]"):
            inside = s == "[Desktop Entry]"
            continue
        if not inside or "=" not in s:
            continue
        key, value = s.split("=", 1)
        key = key.strip()
        if "[" in key:      # Name[de] -- not the base key
            continue
        entry[key] = value.strip()

    if entry.get("Type", "Application") != "Application":
        return None
    if entry.get("NoDisplay", "false").lower() == "true":
        return None
    if entry.get("Hidden", "false").lower() == "true":
        return None
    if not entry.get("Exec") or not entry.get("Name"):
        return None
    # TryExec is the "is it actually installed" switch. An app whose binary is
    # gone is a row that does nothing when clicked.
    try_exec = entry.get("TryExec", "")
    if try_exec and not any(
            os.access(os.path.join(d, try_exec), os.X_OK)
            for d in os.environ.get("PATH", "").split(":")):
        return None
    return entry


def installed():
    """{desktop-id: entry} over the whole search path, first one wins."""
    found = {}
    for d in data_dirs():
        if not os.path.isdir(d):
            continue
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for name in names:
            if not name.endswith(".desktop"):
                continue
            # A subdirectory becomes part of the id (`kde4/foo.desktop` ->
            # `kde4-foo.desktop`), which is how two apps with the same file
            # name in different folders stay distinct.
            did = os.path.relpath(os.path.join(d, name), d).replace("/", "-")
            if did in found:
                continue
            entry = parse_desktop(os.path.join(d, name))
            if entry:
                found[did] = entry
    return found


def split_mimes(value):
    return [m.strip() for m in (value or "").split(";") if m.strip()]


def matches(entry_mimes, mime):
    for declared in entry_mimes:
        if declared == mime:
            return True
        if declared.endswith("/*") and mime.startswith(declared[:-1]):
            return True
    return False


def default_for(mime):
    """The default app's desktop id, straight out of gio -- the same answer the
    desktop itself would use, so the chooser cannot disagree with a plain
    double-click."""
    try:
        out = subprocess.run(["gio", "mime", mime], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return ""
    for line in out.stdout.splitlines():
        low = line.lower()
        # Only the FIRST line names the default; "Registered applications:"
        # and the indented ids that follow are the candidate list.
        for marker in ("default application for", "default application of"):
            if low.startswith(marker):
                return line.split(":", 1)[1].strip() if ":" in line else ""
        if low.startswith("no default application"):
            return ""
    return ""


def uri_for(path):
    return "file://" + urllib.parse.quote(os.path.abspath(path), safe="/")


def cmd_list(path):
    mime = ""
    try:
        out = subprocess.run(["xdg-mime", "query", "filetype", path],
                             capture_output=True, text=True, timeout=5)
        mime = out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    if not mime:
        mime = "application/octet-stream"

    default_id = default_for(mime)
    apps = installed()
    matching = [did for did, e in apps.items() if matches(split_mimes(e.get("MimeType")), mime)]
    if not matching:
        matching = list(apps.keys())

    rows = []
    for did in matching:
        entry = apps[did]
        rows.append({
            "id": did,
            "name": entry.get("Name", did),
            "generic": entry.get("GenericName", ""),
            "icon": entry.get("Icon", ""),
            "terminal": entry.get("Terminal", "false").lower() == "true",
            "default": did == default_id,
        })
    # Default first, then by name -- the row under the pointer when the menu
    # opens is the one the desktop would have used anyway.
    rows.sort(key=lambda r: (not r["default"], r["name"].lower()))

    print(json.dumps({
        "path": os.path.abspath(path),
        "mime": mime,
        "default": default_id,
        "apps": rows,
    }))
    return 0


def substitute(token, path, entry):
    """One Exec argument with its field codes expanded."""
    uri = uri_for(path)
    name = entry.get("Name", "")
    icon = entry.get("Icon", "")
    out = token
    out = out.replace("%%", "\x00")
    out = out.replace("%f", path).replace("%u", uri)
    out = out.replace("%F", path).replace("%U", uri)
    out = out.replace("%i", ("--icon " + icon) if icon else "")
    out = out.replace("%c", name).replace("%k", path)
    # Deprecated codes: %d %D %n %N %v %m. They stand for nothing a modern app
    # can use, and leaving them in hands the app a literal "%d".
    for dead in ("%d", "%D", "%n", "%N", "%v", "%m"):
        out = out.replace(dead, "")
    return out.replace("\x00", "%")


def cmd_run(path, desktop_id):
    entry = installed().get(desktop_id)
    if entry is None:
        sys.stderr.write("no such application: %s\n" % desktop_id)
        return 2
    try:
        argv = [substitute(tok, path, entry) for tok in shlex.split(entry["Exec"])]
    except ValueError:
        sys.stderr.write("could not parse this app's command line\n")
        return 2
    argv = [a for a in argv if a]
    if entry.get("Terminal", "false").lower() == "true":
        # A terminal app (vim, micro, ranger) started with no terminal is the
        # "gio: Unable to find terminal required for application" failure. The
        # editor's own terminal is the one this desktop uses everywhere else.
        term = next((t for t in ("kitty", "foot", "alacritty", "wezterm", "xterm")
                     if any(os.access(os.path.join(d, t), os.X_OK)
                            for d in os.environ.get("PATH", "").split(":"))), "")
        if term:
            argv = [term] + (["-e"] if term in ("kitty", "alacritty") else ["-e"]) + argv
    try:
        # Detached: the file manager must not be this app's parent, or closing
        # the window would take the document with it.
        subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True,
                         cwd=os.path.expanduser("~"))
    except OSError as exc:
        sys.stderr.write("%s\n" % exc)
        return 1
    return 0


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__.split("usage:")[0].strip() + "\n")
        return 2
    verb = argv[1]
    if verb == "list":
        return cmd_list(argv[2])
    if verb == "run" and len(argv) >= 4:
        return cmd_run(argv[2], argv[3])
    sys.stderr.write("unknown request: %s\n" % verb)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
