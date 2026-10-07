#!/usr/bin/env python3
"""ii-portal -- the desktop's own xdg-desktop-portal FileChooser backend.

Answers the FileChooser part of the portal contract
(org.freedesktop.impl.portal.FileChooser) on the session bus as
org.freedesktop.impl.portal.ii, so every "pick a file / choose a download
folder" dialog in every app becomes the shell's own QML file manager instead
of a foreign GTK/KDE one.

How a dialog happens:

  1. An app calls the portal frontend (org.freedesktop.portal.Desktop).
  2. The frontend calls THIS backend's OpenFile/SaveFile/SaveFiles and
     waits for the reply.
  3. The backend writes a job file
        $XDG_RUNTIME_DIR/ii-portal/<token>.json
     {op, title, dir, name, directory, multiple} and launches the file
     manager in picker mode (`filemanager.sh picker <token>`, a dedicated
     small Quickshell instance reading II_FILES_PICKER).
  4. The picker writes <token>.result.json {"cancelled":bool,"uris":[...]}
     and quits; the backend waits for it (10 min timeout) and then replies
     with response 0 (ok, "uris") or 1 (cancelled).

The wait happens on a worker thread so the bus stays live for concurrent
requests; replies are delivered back on the GLib main loop.

Runs on the shell's own venv (PyGObject). Install as a systemd --user unit;
see ~/.config/systemd/user/ii-portal.service.
"""

import json
import os
import subprocess
import sys
import threading
import time

import gi

gi.require_version("GLib", "2.0")
gi.require_version("Gio", "2.0")

from gi.repository import GLib, Gio  # noqa: E402

XDG = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
JOB_DIR = os.path.join(XDG, "ii-portal")
BUS_NAME = "org.freedesktop.impl.portal.ii"
OBJ_PATH = "/org/freedesktop/portal/desktop"
IFACE = "org.freedesktop.impl.portal.FileChooser"
# The Explorer app's picker mode: reads the job file, writes the result and
# quits. Same job/result contract the QML picker used to honour.
LAUNCHER = os.path.expanduser("~/.local/bin/hypr-explorer")
POLL_TIMEOUT = 600.0  # give up on the picker after 10 minutes

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
                "XDG_CURRENT_DESKTOP", "XAUTHORITY")


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


def spawn_picker(job):
    os.makedirs(JOB_DIR, exist_ok=True)
    with open(job_path(job["token"]), "w") as fh:
        json.dump(job, fh)
    env = session_env_fixups(dict(os.environ, II_FILES_PICKER=job["token"]))
    # stderr goes to a real file: a picker that dies before it maps must be
    # diagnosable from the corpse (the /dev/null era turned every such death
    # into an unexplainable ten-minute hang).
    try:
        errfh = open(os.path.join(JOB_DIR, "picker-stderr.log"), "ab")
    except OSError:
        errfh = subprocess.DEVNULL
    subprocess.Popen(["setsid", "bash", LAUNCHER, "picker", job["token"]],
                     env=env, start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=errfh)


def picker_alive(token):
    """Is a picker for this token still running?

    /proc scan with EXACT argv matching: the real picker's argv is
    [python3, …explorer.py, "--picker", token]. pgrep -f would regex-match
    this backend's own --user command lines (any shell whose argv mentions
    the token, e.g. an operator's test pipeline) and report a live picker
    that does not exist -- the classic pkill/pgrep self-match trap.
    """
    me = os.getpid()
    for pid_dir in os.listdir("/proc"):
        if not pid_dir.isdigit() or int(pid_dir) == me:
            continue
        try:
            with open(f"/proc/{pid_dir}/cmdline", "rb") as fh:
                argv = fh.read().split(b"\0")
        except OSError:
            continue
        argv = [a.decode("utf-8", "replace") for a in argv if a]
        if (len(argv) >= 4 and argv[-1] == token
                and argv[-2] == "--picker"
                and argv[1].endswith("explorer.py")):
            return True
    return False


def wait_result(token):
    """Worker-thread: poll for the picker's result file.

    A parse failure while the file exists means the writer was caught
    mid-write (open/append is not atomic) -- poll again instead of
    reporting a cancellation that never happened.

    DEAD-PICKER DETECTION: if the result never arrives AND no picker process
    exists any more, reply cancelled immediately. Waiting out the full
    timeout here is what froze the calling app (Brave) for ten minutes
    whenever the picker failed to start -- one dead GTK process must never
    hang a browser."""
    deadline = time.time() + POLL_TIMEOUT
    p = result_path(token)
    alive_unknown = 0  # pgrep failures must not end the wait early
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
        if not picker_alive(token):
            alive_unknown += 1
            # Two consecutive misses ~0.3s apart: not a startup race.
            if alive_unknown >= 2:
                return {"cancelled": True, "picker_died": True}
        else:
            alive_unknown = 0
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


def main():
    backend = FileChooserBackend()
    Gio.bus_own_name(Gio.BusType.SESSION, BUS_NAME, Gio.BusNameOwnerFlags.NONE,
                     lambda c, n: on_bus_acquired(c, n, backend),
                     None, on_name_lost)
    loop = GLib.MainLoop()
    print("[ii-portal] running", file=sys.stderr)
    loop.run()


if __name__ == "__main__":
    sys.exit(main())
