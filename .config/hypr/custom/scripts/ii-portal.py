#!/usr/bin/env python3
"""ii-portal -- the desktop's own xdg-desktop-portal FileChooser backend.

Answers the FileChooser part of the portal contract
(org.freedesktop.impl.portal.FileChooser) on the session bus as
org.freedesktop.impl.portal.ii, so every "pick a file / choose a download
folder" dialog in every app becomes the shell's own QML file manager instead
of a foreign GTK/KDE one. It also answers org.freedesktop.FileManager1, the
"show me this file" half of the same story -- one process, because both are
the desktop answering a foreign app's request for a file, both need the same
launcher and the same repaired environment, and two services would drift.

How a dialog happens:

  1. An app calls the portal frontend (org.freedesktop.portal.Desktop).
  2. The frontend calls THIS backend's OpenFile/SaveFile/SaveFiles and
     waits for the reply.
  3. The backend writes a job file
        $XDG_RUNTIME_DIR/ii-portal/<token>.json
     {op, title, dir, name, directory, multiple} and launches the file
     manager in picker mode (`filemanager.sh picker <token>`, a dedicated
     small Quickshell instance reading II_FILES_PICKER).

WHAT LAUNCHER MEANS HERE. The launcher is the desktop's file manager --
~/.config/quickshell/<shell>/scripts/launch/filemanager.sh, the same one
variables.lua names as `fileManager`. It used to be the retired GTK Explorer
(~/.local/bin/hypr-explorer), so every app's Open dialog still opened the OLD
file manager while the desktop entry and the keyboard shortcut already opened
the new one: two answers to one question, and the dialog was the odd one out.
  4. The picker writes <token>.result.json {"cancelled":bool,"uris":[...]}
     and quits; the backend waits for it (10 min timeout) and then replies
     with response 0 (ok, "uris") or 1 (cancelled).

The wait happens on a worker thread so the bus stays live for concurrent
requests; replies are delivered back on the GLib main loop.

THE OTHER HALF: org.freedesktop.FileManager1. "Pick one for me" is only half
of what an app asks for. The other half is "here is one I already have, show
me where it is" -- the item next to a finished download, "Open containing
folder", "Reveal in file manager". That is not a portal and has no dialog: it
is the plain well-known bus name a file manager claims so any app can hand it
a URI. Nothing on this machine claimed it, so those requests ended in "the
name is not activatable" and the app did nothing visible. This same process
claims it and answers it by handing the item to the same file manager -- see
FileManager1Backend.

Runs on the shell's own venv (PyGObject). Install as a systemd --user unit;
see ~/.config/systemd/user/ii-portal.service.
"""

import json
import os
import subprocess
import sys
import threading
import time
import urllib.parse

import gi

gi.require_version("GLib", "2.0")
gi.require_version("Gio", "2.0")

from gi.repository import GLib, Gio  # noqa: E402

XDG = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
JOB_DIR = os.path.join(XDG, "ii-portal")
BUS_NAME = "org.freedesktop.impl.portal.ii"
OBJ_PATH = "/org/freedesktop/portal/desktop"
IFACE = "org.freedesktop.impl.portal.FileChooser"
# The file manager's picker mode: reads the job file, writes the result and
# quits. The shell's own launch script is what knows how to raise the app, open
# it at a folder, and start a dedicated picker instance.
SHELL_DIR = os.path.expanduser("~/.config/quickshell/ii")
LAUNCHER = os.path.join(SHELL_DIR, "scripts/launch/filemanager.sh")
# The QML the picker instance runs, which is how its process is recognised
# below (the retired Python one had a different argv entirely).
PICKER_QML = os.path.join(SHELL_DIR, "filemanager-picker.qml")
POLL_TIMEOUT = 600.0  # give up on the picker after 10 minutes

# "Show me this file", as opposed to "pick one for me": the well-known bus
# name every app hands a URI to when it wants an item revealed. See the module
# docstring for why one process serves both.
FM1_BUS_NAME = "org.freedesktop.FileManager1"
FM1_PATH = "/org/freedesktop/FileManager1"
FM1_IFACE = "org.freedesktop.FileManager1"

# xdg-desktop-portal reads a `version` property on every impl interface as the
# backend's capabilities advertisement. A backend that does not publish one is
# treated as unavailable for the features gated on it, and the frontend then
# silently falls through to the next backend in the portals.conf chain -- which
# is exactly the "it still opens the old dialog" failure. We implement the
# FileChooser version the current frontend expects.
IFACE_VERSION = 3

INTROSPECTION_XML = f"""
<node>
  <interface name="{IFACE}">
    <property name="version" type="u" access="read"/>
    <method name="OpenFile">
      <arg type="o" direction="in" name="handle"/>
      <arg type="s" direction="in" name="app_id"/>
      <arg type="s" direction="in" name="parent_window"/>
      <arg type="s" direction="in" name="title"/>
      <arg type="a{{sv}}" direction="in" name="options"/>
      <arg type="u" direction="out" name="response"/>
      <arg type="a{{sv}}" direction="out" name="results"/>
    </method>
    <method name="SaveFile">
      <arg type="o" direction="in" name="handle"/>
      <arg type="s" direction="in" name="app_id"/>
      <arg type="s" direction="in" name="parent_window"/>
      <arg type="s" direction="in" name="title"/>
      <arg type="a{{sv}}" direction="in" name="options"/>
      <arg type="u" direction="out" name="response"/>
      <arg type="a{{sv}}" direction="out" name="results"/>
    </method>
    <method name="SaveFiles">
      <arg type="o" direction="in" name="handle"/>
      <arg type="s" direction="in" name="app_id"/>
      <arg type="s" direction="in" name="parent_window"/>
      <arg type="s" direction="in" name="title"/>
      <arg type="a{{sv}}" direction="in" name="options"/>
      <arg type="u" direction="out" name="response"/>
      <arg type="a{{sv}}" direction="out" name="results"/>
    </method>
  </interface>
</node>
"""

# The same three methods, as the file manager interface defines them. The
# signatures are part of the contract (an app calls a name, not our opinion),
# so they are written here exactly as the spec has them -- `as uris` plus the
# caller's startup id, and no return value: this is an instruction, not a
# question, and the app has already moved on by the time the window appears.
FM1_INTROSPECTION_XML = f"""
<node>
  <interface name="{FM1_IFACE}">
    <method name="ShowItems">
      <arg type="as" direction="in" name="uris"/>
      <arg type="s" direction="in" name="startup_id"/>
    </method>
    <method name="ShowItemProperties">
      <arg type="as" direction="in" name="uris"/>
      <arg type="s" direction="in" name="startup_id"/>
    </method>
    <method name="ShowFolders">
      <arg type="as" direction="in" name="uris"/>
      <arg type="s" direction="in" name="startup_id"/>
    </method>
  </interface>
</node>
"""


def job_path(token):
    return os.path.join(JOB_DIR, f"{token}.json")


def result_path(token):
    return os.path.join(JOB_DIR, f"{token}.result.json")


# Environment keys a GUI child needs. This service starts at login
# (default.target) -- BEFORE the compositor has published WAYLAND_DISPLAY --
# so the process env captured a display-less world. Every picker spawned with
# that env died instantly (GTK4: "assertion 'GDK_IS_DISPLAY (display)'
# failed"), stderr went to /dev/null, and the calling app modal-waited out
# the whole 10-minute timeout -- observed as Brave freezing on every
# download "Save as". The user manager's ACTIVATION environment is updated
# by the compositor (dbus-update-activation-environment in hyprland/execs.lua),
# so show-environment always knows the live display: pull it per-spawn.
GUI_ENV_KEYS = ("WAYLAND_DISPLAY", "DISPLAY", "XDG_SESSION_TYPE",
                "XDG_CURRENT_DESKTOP", "XAUTHORITY",
                "HYPRLAND_INSTANCE_SIGNATURE", "HYPRLAND_CMD")


def session_env_fixups(env):
    """Overlay the live graphical session's env onto `env` (in place)."""
    try:
        out = subprocess.run(["systemctl", "--user", "show-environment"],
                             capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return env
    for line in out.splitlines():
        key, _, value = line.partition("=")
        if key in GUI_ENV_KEYS and value:
            env[key] = value
    return env


def app_stderr(name):
    """A file for a spawned app's stderr -- never /dev/null.

    A file manager or a dialog that dies before it maps must be diagnosable
    from the corpse; the /dev/null era turned every such death into an
    unexplainable hang of whatever had asked for it.
    """
    try:
        return open(os.path.join(JOB_DIR, name), "ab")
    except OSError:
        return subprocess.DEVNULL


def spawn_picker(job):
    os.makedirs(JOB_DIR, exist_ok=True)
    with open(job_path(job["token"]), "w") as fh:
        json.dump(job, fh)
    env = session_env_fixups(dict(os.environ, II_FILES_PICKER=job["token"]))
    subprocess.Popen(["setsid", "bash", LAUNCHER, "picker", job["token"]],
                     env=env, start_new_session=True,
                     stdout=subprocess.DEVNULL,
                     stderr=app_stderr("picker-stderr.log"))


def uri_to_path(uri):
    """A file:// URI as the local path the file manager speaks (spaces, umlauts
    and all -- apps percent-encode, the launcher and the shell do not).

    A non-URI is passed through as it stands, which is also what the launcher
    accepts, so a caller that hands over a plain path is not punished for it.
    """
    text = str(uri or "")
    if not text.startswith("file://"):
        return text
    return urllib.parse.unquote(urllib.parse.urlparse(text).path)


def spawn_file_manager(path):
    """Hand `path` to the desktop's file manager: a folder is entered, a file
    is revealed -- its folder opened with the row selected.

    The same launcher the desktop entry, SUPER+E and the Open dialogs use, so
    every way of asking for a folder ends in the same window: raised if one is
    already up, started if not (the launcher owns that decision, lock and all,
    which is why nothing about single-instance is repeated here).

    Env, like the picker's: this service starts at login, before the compositor
    has published WAYLAND_DISPLAY.
    """
    env = session_env_fixups(dict(os.environ))
    subprocess.Popen(["setsid", "bash", LAUNCHER, path], env=env,
                     start_new_session=True, stdout=subprocess.DEVNULL,
                     stderr=app_stderr("files-stderr.log"))


def picker_alive(token):
    """Is a picker for this token still running?

    /proc, matched on two things a stranger cannot fake together: the argv of a
    Quickshell running filemanager-picker.qml, and THAT process's environment
    carrying this token. pgrep -f would regex-match this backend's own command
    lines (any shell whose argv mentions the token) and report a live picker
    that does not exist -- the classic pkill/pgrep self-match trap.

    The environment is what names the dialog: several pickers can be up at once
    (a browser saving a download while a mail client picks an attachment), and
    each one carries its own token. A dead picker for THIS token must not be
    confused with a live picker for another.
    """
    me = os.getpid()
    want_env = f"II_FILES_PICKER={token}".encode()
    for pid_dir in os.listdir("/proc"):
        if not pid_dir.isdigit() or int(pid_dir) == me:
            continue
        try:
            with open(f"/proc/{pid_dir}/cmdline", "rb") as fh:
                argv = [a.decode("utf-8", "replace")
                        for a in fh.read().split(b"\0") if a]
        except OSError:
            continue
        if PICKER_QML not in argv:
            continue
        try:
            with open(f"/proc/{pid_dir}/environ", "rb") as fh:
                env = fh.read().split(b"\0")
        except OSError:
            continue
        if want_env in env:
            return True
    return False


def wait_result(token):
    """Worker-thread: poll for the picker's result file.

    A parse failure while the file exists means the writer was caught
    mid-write (open/append is not atomic) -- poll again instead of
    reporting a cancellation that never happened.

    DEAD-PICKER DETECTION: if the result never arrives AND there is no picker
    process any more, reply cancelled instead of waiting out ten minutes.
    Waiting out the full timeout is what froze the calling app (Brave) for ten
    minutes whenever the picker failed to start -- a dialog that never comes up
    must never hang a browser.

    THE STARTUP WINDOW IS NOT A DEATH. This used to decide after two misses
    ~0.3 s apart, which was calibrated on the retired Python picker (a GTK
    window, up in a tenth of a second) and is simply wrong for a Quickshell
    one: the dialog has to start, load the theme and lay itself out first. So
    "not in /proc yet" was answered with a cancellation within a third of a
    second, the job file was then deleted with the reply, and the picker that
    DID come up found nothing to answer and cancelled itself -- every app's
    Open dialog closing instantly. Hence two states, not one:

      * never seen alive  -- allow STARTUP_GRACE before believing it;
      * seen alive, gone  -- a real death (it crashed), so cancel at once.
    """
    STARTUP_GRACE = 30.0
    deadline = time.time() + POLL_TIMEOUT
    spawned = time.time()
    p = result_path(token)
    seen_alive = False
    while time.time() < deadline:
        if os.path.exists(p):
            try:
                with open(p) as fh:
                    data = json.load(fh)
                os.unlink(p)
                return data
            except (OSError, ValueError):
                time.sleep(0.05)
                continue
        if picker_alive(token):
            seen_alive = True
        elif seen_alive or (time.time() - spawned) > STARTUP_GRACE:
            return {"cancelled": True, "picker_died": True}
        time.sleep(0.15)
    return {"cancelled": True}


class FileChooserBackend:
    def __init__(self):
        self.node = Gio.DBusNodeInfo.new_for_xml(INTROSPECTION_XML)

    def handle_call(self, connection, sender, object_path, interface_name,
                    method_name, parameters, invocation):
        try:
            handle, _app_id, _parent, title, options = parameters.unpack()
        except (ValueError, TypeError):
            invocation.return_error_literal(
                "org.freedesktop.DBus.Error.InvalidArgs", "bad arguments")
            return

        opts = options if isinstance(options, dict) else {}

        def opt(key, default=None):
            v = opts.get(key, default)
            # GLib gives maybe-variants as plain values after unpack()
            return v

        token = handle.rstrip("/").split("/")[-1].replace(".", "_") or "dlg"

        # Apps pass current_folder as a byte string ('ay'); PyGObject may hand
        # it over as bytes or as a list of ints depending on the variant.
        current_dir = ""
        cf = opts.get("current_folder")
        if isinstance(cf, (bytes, bytearray)):
            current_dir = bytes(cf).rstrip(b"\0").decode("utf-8", "replace")
        elif isinstance(cf, (list, tuple)) and all(isinstance(b, int) for b in cf):
            current_dir = bytes(cf).rstrip(b"\0").decode("utf-8", "replace")
        elif isinstance(cf, str):
            current_dir = cf

        job = {
            "token": token,
            "op": {"OpenFile": "open", "SaveFile": "save",
                   "SaveFiles": "save"}[method_name],
            "title": title or "Files",
            "dir": current_dir,
            "name": str(opt("current_name") or ""),
            "directory": bool(opt("directory", False)),
            "multiple": bool(opt("multiple", False)),
        }
        # The QML side only knows 'open' (single pick / folder pick) and
        # 'save' (pick folder + type a name); SaveFiles maps to save.
        print(f"[ii-portal] {method_name} token={token} -> spawn picker",
              file=sys.stderr)
        spawn_picker(job)

        def worker():
            result = wait_result(token)
            GLib.idle_add(self._deliver, invocation, token, result)
            return False

        threading.Thread(target=worker, daemon=True).start()

    def _deliver(self, invocation, token, result):
        try:
            # The job file has served its purpose whatever the outcome.
            for path in (job_path(token), result_path(token)):
                try:
                    os.unlink(path)
                except OSError:
                    pass
            print(f"[ii-portal] reply token={token} "
                  f"cancelled={result.get('cancelled')} "
                  f"uris={len(result.get('uris', []))}", file=sys.stderr)
            if result.get("picker_died"):
                # The diagnostic that used to be missing entirely.
                print(f"[ii-portal] picker died before answering -- replied "
                      f"cancelled early. Its stderr: "
                      f"{JOB_DIR}/picker-stderr.log", file=sys.stderr)
            if result.get("cancelled"):
                invocation.return_value(GLib.Variant("(ua{sv})", (1, {})))
            else:
                uris = [str(u) for u in result.get("uris", []) if u]
                results = {"uris": GLib.Variant("as", uris)}
                invocation.return_value(GLib.Variant("(ua{sv})", (0, results)))
        except Exception as exc:  # noqa: BLE001 -- never die on a reply
            print(f"[ii-portal] reply failed: {exc}", file=sys.stderr)
        return GLib.SOURCE_REMOVE

class FileManager1Backend:
    """Serves org.freedesktop.FileManager1 -- "show me this file".

    ALL THREE METHODS ANSWER THE SAME WAY, and that is a decision, not a
    shortcut. The desktop has one file manager and one window; "show the item"
    is what the caller means in every case, and the shell's own
    FileManagerContent.openPath already answers it exactly (the `open-path`
    branch: a folder is entered, a file's folder is opened with the row
    selected). ShowItemProperties would ideally raise a properties dialog --
    the manager has an info panel for that, but only behind its own UI; until
    an IPC names it, revealing the item is the honest stand-in, and it beats
    the alternative the app used to get, which was a failed bus call.

    SEVERAL URIS AT ONCE: the window has one location, so it lands on the
    first. The rest are named in the log rather than dropped in silence.
    """

    def __init__(self):
        self.node = Gio.DBusNodeInfo.new_for_xml(FM1_INTROSPECTION_XML)

    def handle_call(self, _connection, _sender, _object_path, _interface_name,
                    method_name, parameters, invocation):
        try:
            uris, _startup_id = parameters.unpack()
        except (ValueError, TypeError):
            invocation.return_error_literal(
                "org.freedesktop.DBus.Error.InvalidArgs", "bad arguments")
            return

        paths = [uri_to_path(u) for u in (uris or [])]
        paths = [p for p in paths if p]
        print(f"[ii-portal] {method_name} uris={len(uris or [])} "
              f"-> {paths[0] if paths else '(empty -- nothing to show)'}",
              file=sys.stderr)

        # Answer FIRST, launch second: the caller is an app on its way back to
        # its own business, and a file manager that takes a second to come up
        # (or a launcher waiting on an instance that is loading) must not hold
        # that call open -- a bus call that blocks is what froze a browser in
        # the incident this service's startup grace already documents.
        invocation.return_value(GLib.Variant("()", ()))
        if paths:
            spawn_file_manager(paths[0])


def on_bus_acquired(conn, _name, backend):
    # PyGObject's register_object takes the three callables directly: the
    # method-call closure, then the get/set-property ones. `version` MUST be
    # answerable, so a get-property handler is required.
    def on_method_call(connection, sender, object_path, interface_name,
                       method_name, parameters, invocation):
        backend.handle_call(connection, sender, object_path, interface_name,
                            method_name, parameters, invocation)

    def on_get_property(_connection, _sender, _object_path, _interface_name,
                        property_name):
        if property_name == "version":
            return GLib.Variant("u", IFACE_VERSION)
        return None

    try:
        conn.register_object(
            OBJ_PATH, backend.node.interfaces[0], on_method_call,
            on_get_property, None)
        print("[ii-portal] FileChooser backend registered", file=sys.stderr)
    except Exception as exc:  # noqa: BLE001
        print(f"[ii-portal] register failed: {exc}", file=sys.stderr)


def on_name_lost(_conn, _name):
    print("[ii-portal] bus name lost -- another backend owns it", file=sys.stderr)
    raise SystemExit(1)


def on_fm1_bus_acquired(conn, _name, backend):
    def on_method_call(connection, sender, object_path, interface_name,
                       method_name, parameters, invocation):
        backend.handle_call(connection, sender, object_path, interface_name,
                            method_name, parameters, invocation)

    def on_get_property(_connection, _sender, _object_path, _interface_name,
                        property_name):
        # FileManager1 has no properties at all; the handler is what
        # register_object wants, not what the interface has.
        return None

    try:
        conn.register_object(FM1_PATH, backend.node.interfaces[0],
                             on_method_call, on_get_property, None)
        print("[ii-portal] FileManager1 backend registered", file=sys.stderr)
    except Exception as exc:  # noqa: BLE001
        print(f"[ii-portal] FileManager1 register failed: {exc}", file=sys.stderr)


def on_fm1_name_lost(_conn, _name):
    # DELIBERATELY NOT FATAL, unlike losing the FileChooser name above. A real
    # file manager answering this name only takes "show me this file" away from
    # us -- that is a legitimate state on a machine with one installed -- while
    # the Open dialogs, which is the other half of this service, keep working.
    # Exiting here would kill those dialogs over a name we merely lend.
    print("[ii-portal] FileManager1 name lost -- another file manager answers "
          "it now; Open/Save dialogs are unaffected", file=sys.stderr)


def main():
    backend = FileChooserBackend()
    fm1 = FileManager1Backend()
    Gio.bus_own_name(Gio.BusType.SESSION, BUS_NAME, Gio.BusNameOwnerFlags.NONE,
                     lambda c, n: on_bus_acquired(c, n, backend),
                     None, on_name_lost)
    Gio.bus_own_name(Gio.BusType.SESSION, FM1_BUS_NAME,
                     Gio.BusNameOwnerFlags.NONE,
                     lambda c, n: on_fm1_bus_acquired(c, n, fm1),
                     None, on_fm1_name_lost)
    loop = GLib.MainLoop()
    print("[ii-portal] running", file=sys.stderr)
    loop.run()


if __name__ == "__main__":
    sys.exit(main())
