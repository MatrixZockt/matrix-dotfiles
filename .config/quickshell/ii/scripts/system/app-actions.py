#!/usr/bin/env python3
"""Every option an installed app offers, and the means to carry it out.

WHY THIS EXISTS. A launcher row is one click for one thing: open it. On the
desktop this shell replaces, an app also answers to "run as administrator",
"repair", "uninstall", "uninstall and delete my data" -- and which of those an
app HAS depends entirely on what installed it, which is a fact no .desktop file
records. So it is looked up here, once, and reported as a list.

The distinction that matters is the INSTALLER, and it is resolved in this order:

    flatpak   the Exec line runs `flatpak run <app id>` -- the app id is read
              off the Exec, and `flatpak info` confirms it is installed
    snap      the binary lives under /snap, or the Exec runs `snap run`
    pacman    `pacman -Qo` knows which package owns the binary -- and when it
              does not, the .desktop file itself is asked, which is how an app
              whose launcher is a shell script in /usr/bin is still identified
    appimage  a real file, executable, under $HOME, named *.AppImage
    local     a .desktop file in ~/.local/share/applications pointing at
              something in $HOME that is not an AppImage
    unknown   nothing could be established; only what is guessable is offered

"Repair" is spelled differently by each installer -- reinstalling the package,
reinstalling the flatpak, refreshing the snap -- and a source that cannot be
repaired at all (an AppImage is one file; there is nothing to repair) simply
does not offer it. The menu shows what is there, so an app never lists an
option that would do nothing.

OUTPUT. Every subcommand prints ONE JSON object on stdout. Non-zero exit is
reserved for "the question could not be answered at all"; a probe of an app
that turns out to be unknown is a successful probe with kind=unknown.

    probe --id <desktop id> [--exec-json <argv>] [--pretty]
    plan  --id <desktop id> --action <action> [--pretty]
    run   --id <desktop id> --action <action> [--json] [--dry-run]

`run` never trusts the caller's idea of what an action means: it probes again
and builds the command from what it found, so a stale menu cannot uninstall the
wrong package. `--dry-run` prints the command line instead of running it, which
is what makes the whole set checkable without root and without touching
anybody's data.
"""

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HOME = os.path.expanduser("~")
XDG_DATA_HOME = os.environ.get("XDG_DATA_HOME") or os.path.join(HOME, ".local", "share")
XDG_CONFIG_HOME = os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config")
XDG_CACHE_HOME = os.environ.get("XDG_CACHE_HOME") or os.path.join(HOME, ".cache")
XDG_STATE_HOME = os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local", "state")

# Where a .desktop file may live, in the order a lookup should prefer: the
# user's own copy wins over the system's, which is exactly how the desktop
# entry spec resolves a duplicate id -- and it is also how "the user
# overrode this app's launcher" is recognised below.
def application_dirs():
    dirs = [
        os.path.join(XDG_DATA_HOME, "applications"),
        "/usr/local/share/applications",
        "/usr/share/applications",
        os.path.join(XDG_DATA_HOME, "flatpak", "exports", "share", "applications"),
        "/var/lib/flatpak/exports/share/applications",
    ]
    for extra in (os.environ.get("XDG_DATA_DIRS") or "").split(":"):
        if extra.strip():
            dirs.append(os.path.join(extra.strip(), "applications"))
    seen = []
    for d in dirs:
        if d not in seen:
            seen.append(d)
    return seen


def desktop_file_for(app_id):
    """The .desktop file this id names, and whether the user owns it."""
    name = app_id if app_id.endswith(".desktop") else app_id + ".desktop"
    for d in application_dirs():
        candidate = os.path.join(d, name)
        if os.path.isfile(candidate):
            return candidate, d
        # Some packages file entries in a subdirectory of the applications
        # directory; the spec forbids using the subdirectory in the id, so the
        # file is still reachable by name.
        hits = glob.glob(os.path.join(d, "*", name))
        if hits:
            return hits[0], d
    return None, None


def parse_desktop(path):
    """Name, Icon, Exec, and the file's own actions, from a .desktop file.

    Hand-rolled rather than configparser: a desktop entry is a UTF-8 INI whose
    keys may repeat across groups and whose values routinely contain `%f`
    field codes, `=` signs and semicolons, and losing any of that would lose
    the app's own arguments. Only the [Desktop Entry] group is read, plus each
    [Desktop Action <id>] group for the app's own extra options.
    """
    info = {"name": "", "icon": "", "exec": "", "tryExec": "",
            "categories": [], "actions": [], "flatpak": "", "startupWMClass": ""}
    group = ""
    action = None
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            for raw in handle:
                line = raw.rstrip("\n")
                if line.startswith("[") and line.endswith("]"):
                    group = line[1:-1].strip()
                    if group.startswith("Desktop Action "):
                        action = {"id": group[len("Desktop Action "):].strip(),
                                  "name": "", "icon": "", "exec": ""}
                        info["actions"].append(action)
                    else:
                        action = None
                    continue
                if "=" not in line or line.lstrip().startswith("#"):
                    continue
                key, _, value = line.partition("=")
                key = key.strip()
                value = value.strip()
                if group == "Desktop Entry":
                    if key == "Name" and not info["name"]:
                        info["name"] = value
                    elif key == "Icon":
                        info["icon"] = value
                    elif key == "Exec":
                        info["exec"] = value
                    elif key == "TryExec":
                        info["tryExec"] = value
                    elif key == "Categories":
                        info["categories"] = [c for c in value.split(";") if c]
                    elif key == "X-Flatpak":
                        info["flatpak"] = value
                    elif key == "StartupWMClass":
                        info["startupWMClass"] = value
                    elif key == "Actions" and not info["actions"]:
                        # The declared order, kept: this list is what the app
                        # itself says it offers, and the groups below fill it.
                        info["actions"] = [{"id": a, "name": "", "icon": "", "exec": ""}
                                           for a in (value.split(";") if value else []) if a]
                elif action is not None:
                    if key == "Name" and not action["name"]:
                        action["name"] = value
                    elif key == "Icon":
                        action["icon"] = value
                    elif key == "Exec":
                        action["exec"] = value
    except OSError:
        pass
    # A group with no Exec is not an option; drop it rather than show a row
    # that does nothing.
    info["actions"] = [a for a in info["actions"] if a.get("exec")]
    return info


FIELD_CODE = re.compile(r"%[fFuUdDnNickvm]")


def split_exec(exec_line):
    """Exec= into argv, without a shell.

    The spec's quoting rules are not sh's -- inside double quotes, backslash
    escapes only `"`, backtick, `$` and `\\` -- but the one thing that must not
    happen is a value being split in half, so the reduced rule is implemented
    rather than trusting a naive `.split()`.
    """
    argv = []
    word = ""
    quoted = False
    escaped = False
    have = False
    for ch in exec_line:
        if escaped:
            word += ch
            escaped = False
            have = True
            continue
        if ch == "\\" and quoted:
            escaped = True
            continue
        if ch == '"':
            quoted = not quoted
            have = True
            continue
        if ch in " \t" and not quoted:
            if have:
                argv.append(word)
                word = ""
                have = False
            continue
        word += ch
        have = True
    if have:
        argv.append(word)
    out = []
    for word in argv:
        word = FIELD_CODE.sub("", word)
        # `%%` is a literal percent sign, and it is the only field code that
        # can survive the substitution above.
        word = word.replace("%%", "%")
        if word:
            out.append(word)
    return out


def run_capture(argv, timeout=6):
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None, ""
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def have(tool):
    return shutil.which(tool) is not None


# ── Which installer owns this app? ──────────────────────────────────────────

def strip_wrappers(argv):
    """argv with the launchers that stand in front of the real program removed.

    `env FOO=1 /usr/bin/bar`, `sh -c "/usr/bin/bar"` and friends all name the
    real binary somewhere after the wrapper, and every ownership question below
    is about that binary -- asking `pacman -Qo /usr/bin/env` answers a question
    nobody asked.
    """
    argv = list(argv)
    for _ in range(4):
        if not argv:
            return argv
        head = os.path.basename(argv[0])
        if head == "env":
            # `env VAR=1 /usr/bin/app` is how a great many Electron apps and
            # Steam games are launched, and the assignment must go: left in,
            # it becomes argv[0] and every ownership question below is asked
            # about a string that is not a program at all -- which silently
            # turned those apps into "source unknown" with a short menu.
            rest = argv[1:]
            words = []
            skip_next = False
            for item in rest:
                if skip_next:
                    # `env -u NAME ...`: the option's own argument is skipped
                    # with it, or NAME would be taken for the program.
                    skip_next = False
                    continue
                if item in ("-u", "--unset"):
                    skip_next = True
                    continue
                if item.startswith("-"):
                    continue
                if "=" in item:
                    continue
                words.append(item)
            argv = words
            continue
        if head in ("sh", "bash", "dash", "zsh") and len(argv) >= 3 and argv[1] == "-c":
            inner = split_exec(argv[2])
            if inner:
                argv = inner
                continue
            return argv
        return argv
    return argv


def pacman_owner(path):
    if not path or not os.path.exists(path) or not have("pacman"):
        return None
    code, out = run_capture(["pacman", "-Qo", path])
    if code != 0:
        return None
    match = re.search(r"is owned by (\S+) ([^\s]+)", out)
    if not match:
        return None
    return match.group(1), match.group(2)


def pacman_info(pkg):
    code, out = run_capture(["pacman", "-Qi", pkg])
    if code != 0:
        return {}
    info = {}
    for line in out.splitlines():
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        info[key.strip()] = value.strip()
    return info


# Where an app keeps its data when it does not keep it under its own name.
#
# The general rule is the scan in `user_data_paths`: a directory named after the
# app. Browser and editor profiles are the exception that rule cannot reach --
# Firefox's lives in ~/.mozilla, Brave's in ~/.config/BraveSoftware -- and they
# are exactly the things a user means by "delete all of it", so they are named
# here. Rows are only a HINT: each path is checked before it is offered, so a
# row for an app that is not installed, or a directory that is not there, adds
# nothing to the menu. Kept short on purpose -- the scan is the mechanism, this
# only covers what the scan structurally cannot find.
KNOWN_DATA = {
    "firefox": ["~/.mozilla"],
    "thunderbird": ["~/.thunderbird"],
    "brave-bin": ["~/.config/BraveSoftware"],
    "brave-browser": ["~/.config/BraveSoftware"],
    "brave": ["~/.config/BraveSoftware"],
    "google-chrome": ["~/.config/google-chrome"],
    "chromium": ["~/.config/chromium"],
    "vivaldi": ["~/.config/vivaldi"],
    "code": ["~/.config/Code", "~/.vscode"],
    "visual-studio-code-bin": ["~/.config/Code", "~/.vscode"],
    "android-studio": ["~/.android", "~/.config/Google"],
    "android-studio-for-platform": ["~/.android", "~/.config/Google"],
}

# A program under your home directory that is not just one file is an
# installation directory sitting inside a conventional parent: Android Studio
# unpacks to ~/.local/opt/android-studio and its launcher is one file inside
# that. Removing only the launcher would leave every byte of the app behind, so
# the directory the binary belongs to is offered as well -- and only below one
# of these parents, because one level further up is where OTHER apps live.
INSTALL_PARENTS = [
    os.path.join(HOME, ".local", "opt"),
    os.path.join(HOME, "opt"),
    os.path.join(HOME, "Applications"),
    os.path.join(HOME, "AppImages"),
    os.path.join(HOME, "apps"),
    os.path.join(HOME, ".local", "lib"),
    os.path.join(HOME, ".local", "share"),
]


def flatpak_app_id(exec_argv, desktop_actions, declared):
    if declared:
        return declared
    if "flatpak" not in " ".join(os.path.basename(a) for a in exec_argv[:1]):
        return ""
    argv = list(exec_argv)
    if argv and os.path.basename(argv[0]) == "flatpak":
        argv = argv[1:]
    if argv and argv[0] == "run":
        argv = argv[1:]
    for item in argv:
        if item == "--":
            continue
        if item.startswith("-"):
            continue
        if item.startswith("--"):
            continue
        if re.fullmatch(r"[A-Za-z0-9_]+(\.[A-Za-z0-9_]+){1,}", item):
            return item
    return ""


def resolve(app_id, exec_override):
    """Everything the menu needs to describe the app and offer its options."""
    path, directory = desktop_file_for(app_id)
    desk = parse_desktop(path) if path else {"name": "", "icon": "", "exec": "",
                                             "actions": [], "categories": [],
                                             "flatpak": "", "tryExec": "",
                                             "startupWMClass": ""}
    # A user copy of a system app's launcher is a real thing (a pinned
    # override, an AppImage, a wrapper someone wrote); noting it is what lets
    # "remove the launcher" be offered without also claiming the app is
    # uninstalled.
    user_copy = bool(directory) and directory.startswith(HOME)

    argv = exec_override or split_exec(desk["exec"])
    real = strip_wrappers(argv)
    binary = ""
    if real:
        first = real[0]
        binary = first if os.path.isabs(first) else (shutil.which(first) or "")

    result = {
        "id": app_id,
        "name": desk["name"] or app_id,
        "icon": desk["icon"],
        "desktopFile": path or "",
        "userLauncher": user_copy,
        "exec": argv,
        "binary": binary,
        "kind": "unknown",
        "manager": "",
        "package": "",
        "version": "",
        "repo": "",
        "detail": "",
        "dataPaths": [],
        "actions": [],
        "appActions": desk["actions"],
        "canElevate": have("pkexec"),
        "elevator": "pkexec" if have("pkexec") else "",
        "logPath": "/tmp/quickshell/app-actions.log",
    }

    # ── flatpak ─────────────────────────────────────────────────────────────
    fid = flatpak_app_id(argv, desk["actions"], desk["flatpak"])
    if fid and have("flatpak"):
        code, out = run_capture(["flatpak", "info", fid, "--show-ref"])
        if code == 0:
            result["kind"] = "flatpak"
            result["manager"] = "flatpak"
            result["package"] = fid
            lines = [l.split("\t") for l in out.strip().splitlines()]
            # --show-ref prints: <ref> <name> <version> <arch> <branch>
            for parts in lines:
                if len(parts) >= 3:
                    result["version"] = parts[2]
                    result["repo"] = "flatpak"
                    break
            var = os.path.join(HOME, ".var", "app", fid)
            if os.path.isdir(var):
                result["dataPaths"].append(var)

    # ── snap ────────────────────────────────────────────────────────────────
    if result["kind"] == "unknown" and have("snap"):
        snap_name = ""
        if binary.startswith("/snap/"):
            snap_name = binary.split("/")[2]
        if snap_name:
            code, out = run_capture(["snap", "list", snap_name])
            if code == 0:
                result["kind"] = "snap"
                result["manager"] = "snap"
                result["package"] = snap_name
                parts = out.strip().splitlines()
                if len(parts) >= 2:
                    fields = parts[1].split()
                    if len(fields) >= 2:
                        result["version"] = fields[1]

    # ── pacman ──────────────────────────────────────────────────────────────
    if result["kind"] == "unknown" and have("pacman"):
        owner = pacman_owner(binary) or pacman_owner(path)
        if owner:
            pkg, version = owner
            info = pacman_info(pkg)
            result["kind"] = "pacman"
            result["manager"] = "pacman"
            result["package"] = pkg
            result["version"] = version
            # pacman spells the source of an installed package "Repository" in
            # most of its output and "Installed From" in `-Qi` on this build,
            # so both are read rather than one being assumed.
            result["repo"] = info.get("Repository") or info.get("Installed From", "")
            result["detail"] = info.get("Description", "")

    # ── AppImage and other user-local programs ──────────────────────────────
    if result["kind"] == "unknown" and binary:
        if binary.startswith(HOME + os.sep) and os.path.isfile(binary):
            result["kind"] = "appimage" if binary.endswith(".AppImage") else "local"

    if not result["detail"]:
        if result["kind"] == "pacman":
            result["detail"] = pacman_info(result["package"]).get("Description", "")
        elif result["kind"] == "flatpak":
            result["detail"] = "Flatpak application"
        elif result["kind"] == "appimage":
            result["detail"] = "AppImage — a single self-contained file"
        elif result["kind"] == "local":
            result["detail"] = "Installed for this user only"

    # The launcher itself, and the app's own store of settings, are what an
    # uninstall leaves behind when it only removes the package.
    for path in leftovers(result):
        if path not in result["dataPaths"]:
            result["dataPaths"].append(path)
    result["actions"] = build_actions(result)
    return result


def slug_candidates(res):
    """The names an app's own directories plausibly use.

    Only the honest spellings: the entry's id, the id without its vendor
    prefix or its `.desktop` suffix, and the display name lowercased. Nothing
    is guessed from a fuzzy match -- a wrong guess here would delete somebody
    else's directory, so a name that is not one of these is not offered.
    """
    names = []
    ident = res["id"]
    if ident.endswith(".desktop"):
        ident = ident[: -len(".desktop")]
    tail = ident.split(".")[-1] if "." in ident else ident
    for candidate in (ident, tail, res["name"]):
        slug = re.sub(r"[^a-z0-9]+", "-", candidate.lower()).strip("-")
        for form in (candidate, candidate.lower(), slug):
            if form and form not in names:
                names.append(form)
    return names[:8]


def install_root(binary):
    """The app's own directory when it is an unpacked installation.

    Returns "" for a binary that is simply a file in a shared bin directory --
    deleting ~/.local/bin would be a catastrophe and deleting the file is
    already covered.
    """
    if not binary or not binary.startswith(HOME + os.sep):
        return ""
    parent = os.path.dirname(binary)
    for root in INSTALL_PARENTS:
        if parent == root or not parent.startswith(root + os.sep):
            continue
        relative = parent[len(root) + 1:]
        top = relative.split(os.sep)[0]
        candidate = os.path.join(root, top)
        if candidate != parent or os.path.isdir(candidate):
            return candidate
    return ""


def leftovers(res):
    """Everything that is not the package: settings, cache and the file itself.

    Flatpak keeps its data in ~/.var/app/<app id> -- a different tree entirely
    -- and that path is added at probe time rather than looked for here.
    """
    if res["kind"] == "flatpak":
        return []
    found = []
    for name in slug_candidates(res):
        for root in (XDG_CONFIG_HOME, XDG_CACHE_HOME, XDG_STATE_HOME,
                     os.path.join(HOME, ".local", "share")):
            path = os.path.join(root, name)
            if os.path.isdir(path) and path not in found:
                found.append(path)
        # A launch-from-here copy inside the config dir (Electron apps keep
        # their caches one level down) is not listed: it is inside a directory
        # already listed, and two rows saying the same thing read as two
        # separate deletions.
    for path in KNOWN_DATA.get(res["package"], []):
        expanded = os.path.expanduser(path)
        if os.path.exists(expanded) and expanded not in found:
            found.append(expanded)
    # The installation directory, for an app that is more than one file.
    root = install_root(res["binary"])
    if root and root not in found:
        found.append(root)
    return found


def build_actions(res):
    """Every option this app actually offers, in the order a menu wants them.

    The list is built from what was FOUND, never from what might exist: an
    option a source cannot carry out is left out, so nothing in the menu is a
    row that would do nothing when clicked.
    """
    actions = []
    seen = set()

    def add(entry):
        # One row per option. The same option is reachable from more than one
        # branch below -- a user launcher on an installed app, and the same
        # thing said again for a program that is not packaged at all -- and two
        # identical rows read as two separate actions.
        if entry["id"] in seen:
            return
        seen.add(entry["id"])
        actions.append(entry)

    if res["binary"] or res["exec"]:
        add({"id": "open", "group": "run",
             "label": "Open", "icon": "play_arrow",
             "detail": "", "destructive": False, "needsRoot": False})
    if res["canElevate"] and res["binary"]:
        add({
            "id": "run-admin", "group": "run",
            "label": "Run as administrator", "icon": "admin_panel_settings",
            "detail": "Launch " + (res["name"] or "the app")
                      + " as root, through the password prompt",
            "destructive": False, "needsRoot": True})

    kind = res["kind"]
    pkg = res["package"]
    if kind == "pacman":
        add({
            "id": "reinstall", "group": "maintain",
            "label": "Repair (reinstall " + pkg + ")", "icon": "build",
            "detail": "Downloads and reinstalls the package, replacing every file it owns",
            "destructive": False, "needsRoot": True})
        add({
            "id": "uninstall", "group": "remove",
            "label": "Uninstall", "icon": "delete",
            "detail": "Removes the " + pkg + " package and leaves your settings alone",
            "destructive": True, "needsRoot": True})
        add({
            "id": "uninstall-purge", "group": "remove",
            "label": "Uninstall and delete all data", "icon": "delete_forever",
            "detail": "Removes the package, the dependencies nothing else needs, its"
                      " configuration files and the app data listed above",
            "destructive": True, "needsRoot": True})
    elif kind == "flatpak":
        add({
            "id": "reinstall", "group": "maintain",
            "label": "Repair (reinstall " + pkg + ")", "icon": "build",
            "detail": "Reinstalls the flatpak from its remote",
            "destructive": False, "needsRoot": False})
        add({
            "id": "uninstall", "group": "remove",
            "label": "Uninstall", "icon": "delete",
            "detail": "Removes the app; its data in ~/.var/app stays",
            "destructive": True, "needsRoot": False})
        add({
            "id": "uninstall-purge", "group": "remove",
            "label": "Uninstall and delete all data", "icon": "delete_forever",
            "detail": "Removes the app and its ~/.var/app data",
            "destructive": True, "needsRoot": False})
    elif kind == "snap":
        add({
            "id": "reinstall", "group": "maintain",
            "label": "Repair (refresh " + pkg + ")", "icon": "build",
            "detail": "Updates the snap to the current revision in its channel",
            "destructive": False, "needsRoot": True})
        add({
            "id": "uninstall", "group": "remove",
            "label": "Uninstall", "icon": "delete",
            "detail": "Removes the snap, keeping its user data snapshot",
            "destructive": True, "needsRoot": True})
        add({
            "id": "uninstall-purge", "group": "remove",
            "label": "Uninstall and delete all data", "icon": "delete_forever",
            "detail": "Removes the snap and takes its saved data with it",
            "destructive": True, "needsRoot": True})
    else:
        # Nothing owns this file: the honest options are to open it and to
        # remove what is left of it -- the launcher, the installation
        # directory, and the settings the app wrote into your home directory.
        delete_targets = []
        if res["binary"] and res["binary"].startswith(HOME + os.sep) and os.path.isfile(res["binary"]):
            delete_targets.append(res["binary"])
        if res["userLauncher"] and res["desktopFile"]:
            delete_targets.append(res["desktopFile"])
        if delete_targets or res["dataPaths"]:
            add({
                "id": "uninstall-purge", "group": "remove",
                "label": "Delete the app and all of its data", "icon": "delete_forever",
                "detail": "Deletes everything listed above: the program"
                          + (", its launcher" if res["userLauncher"] else "")
                          + " and the settings it wrote",
                "destructive": True, "needsRoot": False})
    if res["userLauncher"] and res["desktopFile"]:
        add({
            "id": "remove-entry", "group": "remove",
            "label": "Remove this launcher entry", "icon": "remove_circle",
            "detail": "Deletes your own copy at " + res["desktopFile"]
                      + " and leaves the installed app in place",
            "destructive": True, "needsRoot": False})
    return actions


# ── Carrying it out ─────────────────────────────────────────────────────────

def elevate(argv):
    """argv run as root through the session's polkit prompt.

    pkexec is used rather than a terminal with sudo in it because this desktop
    already has a polkit agent: the shell puts the prompt on screen, and the
    command runs only if a human approves it.
    """
    return ["pkexec"] + argv


def admin_env():
    """The session variables a GUI program needs, kept for the root process.

    pkexec starts from a stripped environment, which is why an elevated GUI app
    normally comes up unable to find the display. These are the ones that decide
    where the display IS; everything else is left to the system defaults.
    """
    keep = {}
    for key in ("WAYLAND_DISPLAY", "DISPLAY", "XAUTHORITY", "XDG_RUNTIME_DIR",
                "XDG_SESSION_TYPE", "QT_QPA_PLATFORM", "QT_QPA_PLATFORMTHEME",
                "QT_SCALE_FACTOR", "GDK_SCALE", "LANG", "LC_ALL"):
        value = os.environ.get(key, "")
        if value:
            keep[key] = value
    return keep


def command_for(res, action):
    """The command line for an action, as argv, or None when it does not apply.

    Built from the probe rather than from the menu, so what runs is always what
    was found -- and returned to the caller so a confirmation can show it.
    """
    kind = res["kind"]
    pkg = res["package"]
    if action == "open":
        return list(res["exec"]) or ([res["binary"]] if res["binary"] else None)
    if action == "run-admin":
        argv = list(res["exec"]) or ([res["binary"]] if res["binary"] else [])
        if not argv:
            return None
        keep = admin_env()
        env_prefix = ["env"] + ["%s=%s" % (k, v) for k, v in keep.items()]
        return elevate(env_prefix + argv)
    if kind == "pacman":
        if action == "reinstall":
            # --needed is deliberately absent: reinstalling an up-to-date
            # package is the entire point of a repair, and --needed would
            # refuse to touch it.
            return elevate(["pacman", "-S", "--noconfirm", pkg])
        if action == "uninstall":
            return elevate(["pacman", "-R", "--noconfirm", pkg])
        if action == "uninstall-purge":
            # -s removes the dependencies this package dragged in and that
            # nothing else wants; -n removes the configuration files it shipped
            # instead of saving them as .pacsave. Together they are the whole
            # app, which is the only thing "uninstall" should mean.
            return elevate(["pacman", "-Rns", "--noconfirm", pkg])
    if kind == "flatpak":
        if action == "reinstall":
            return ["flatpak", "install", "--reinstall", "--noninteractive", pkg]
        if action == "uninstall":
            return ["flatpak", "uninstall", "--noninteractive", pkg]
        if action == "uninstall-purge":
            return ["flatpak", "uninstall", "--delete-data", "--noninteractive", pkg]
    if kind == "snap":
        if action == "reinstall":
            return elevate(["snap", "refresh", pkg])
        if action == "uninstall":
            return elevate(["snap", "remove", pkg])
        if action == "uninstall-purge":
            return elevate(["snap", "remove", "--purge", pkg])
    if action == "remove-entry":
        if res["userLauncher"] and res["desktopFile"]:
            return ["rm", "-f", res["desktopFile"]]
    if action == "uninstall-purge" and res["kind"] in ("appimage", "local", "unknown"):
        # Nothing owns the file, so the file is the app. The launcher and the
        # settings are part of "all of it", which is what the label promises --
        # and the settings are removed by the leftover pass below, so this is
        # only the program itself.
        targets = []
        if res["binary"] and res["binary"].startswith(HOME + os.sep):
            targets.append(res["binary"])
        if res["userLauncher"] and res["desktopFile"]:
            targets.append(res["desktopFile"])
        targets = [t for t in targets if t and os.path.exists(t)]
        if not targets:
            # Nothing of the program is left; the settings pass alone is the
            # whole action rather than a command that would fail on an empty
            # argument list.
            return ["/usr/bin/true"]
        return ["/usr/bin/rm", "-rf", "--"] + targets
    return None


def purge_targets(res):
    """Everything a purge deletes that is NOT the package: the leftovers."""
    return [p for p in res["dataPaths"] if p.startswith(HOME + os.sep)]


def run_action(res, action, dry_run):
    argv = command_for(res, action)
    if not argv:
        return {"ok": False, "code": -1, "cmd": "",
                "output": "This app does not offer that option."}
    shown = " ".join(argv)
    if dry_run:
        # The leftovers are part of what a purge does, so a dry run that named
        # only the package manager's command would understate it -- and this is
        # the text a confirmation is read from.
        extra = ""
        if action == "uninstall-purge":
            already = set(argv)
            rest = [p for p in purge_targets(res) if p not in already]
            if rest:
                extra = "\nand delete: " + ", ".join(rest)
        return {"ok": True, "dryRun": True, "cmd": shown,
                "output": "Would run: " + shown + extra, "code": 0,
                "targets": purge_targets(res) if action == "uninstall-purge" else []}

    # A GUI program is started and left alone: waiting for it would hold the
    # prompt open for as long as the app runs. It is waited on for a moment
    # anyway, because the two ways it fails -- polkit refusing, and the binary
    # not being startable -- both fail within that moment, and reporting them
    # is the difference between "nothing happened" and knowing why.
    detached = action in ("open", "run-admin")
    log = res["logPath"]
    try:
        os.makedirs(os.path.dirname(log), exist_ok=True)
    except OSError:
        pass
    try:
        handle = open(log, "ab", buffering=0)
    except OSError:
        handle = subprocess.DEVNULL

    try:
        proc = subprocess.Popen(
            argv,
            stdout=handle,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            cwd=HOME,
            start_new_session=True,
        )
    except OSError as error:
        return {"ok": False, "code": -1, "cmd": shown, "output": str(error)}

    # A purge is a removal PLUS the leftovers: the package manager takes the
    # package, and nothing but this can take the app's own settings, which is
    # exactly the half an uninstall normally leaves behind. Whatever the main
    # command already named is skipped, so a file is never deleted twice by
    # two different mechanisms in the same action.
    extra = ""
    if action == "uninstall-purge":
        already = set(argv)
        leftovers = [p for p in purge_targets(res) if p not in already]
        leftovers = [p for p in leftovers if not any(p.startswith(a + os.sep) for a in already)]
        if leftovers:
            code, extra = run_capture(["/usr/bin/rm", "-rf", "--"] + leftovers)
            extra = ("Deleted settings, cache and app data:\n  " + "\n  ".join(leftovers)
                     + ("" if code == 0 else "\n(some paths could not be removed)"))
        elif res["dataPaths"]:
            extra = "App data deleted with the program."

    if detached:
        try:
            code = proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            return {"ok": True, "code": 0, "cmd": shown, "log": log,
                    "output": "Started. Any output is written to " + log, "detached": True}
        text = read_tail(log)
        return {"ok": code == 0, "code": code, "cmd": shown, "detached": True,
                "output": text or ("Exited with status %d" % code)}

    code = proc.wait()
    text = read_tail(log)
    if extra:
        text = (text + "\n" + extra).strip()
    message = {
        0: "Done.",
        126: "Cancelled at the password prompt.",
        127: "Not authorised.",
    }.get(code, "Failed (status %d)." % code)
    return {"ok": code == 0, "code": code, "cmd": shown,
            "output": (message + ("\n" + text if text else "")).strip()}


def read_tail(path, limit=1400):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError:
        return ""
    text = text.strip()
    if len(text) > limit:
        text = "…" + text[-limit:]
    return text


def truncate_log(path):
    try:
        with open(path, "w", encoding="utf-8"):
            pass
    except OSError:
        pass


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("command", choices=["probe", "plan", "run"])
    parser.add_argument("--id", required=True)
    parser.add_argument("--action", default="")
    parser.add_argument("--exec-json", default="")
    parser.add_argument("--pretty", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    override = []
    if args.exec_json:
        try:
            override = [str(a) for a in json.loads(args.exec_json)]
        except (ValueError, TypeError):
            override = []

    res = resolve(args.id, override)
    if args.command == "probe":
        out = res
    elif args.command == "plan":
        argv = command_for(res, args.action)
        out = {"ok": argv is not None, "id": args.id, "action": args.action,
               "cmd": " ".join(argv) if argv else "", "kind": res["kind"],
               "package": res["package"]}
    else:
        # The log is per-run, so yesterday's uninstall cannot be reported as
        # today's result.
        truncate_log(res["logPath"])
        out = run_action(res, args.action, args.dry_run)
        out["id"] = args.id
        out["action"] = args.action

    json.dump(out, sys.stdout, indent=2 if args.pretty else None)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
