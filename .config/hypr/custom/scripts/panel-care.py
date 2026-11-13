#!/usr/bin/env python3
"""Panel care for the OLED panel.

Written for an OLED panel (the one this desk has is an eDP panel at 2560x1600;
on an LCD the shader is harmless but pointless). An OLED does not
burn a backlight through a mask like an LCD: every pixel is its own light, and
every pixel ages in proportion to how hard and how long it has been driven. A
large bright field held in the same place -- a document page, a light-mode app,
a white web page -- is therefore not free, and the faint ghost left behind
afterwards is image retention, the early form of it.

The compositor already does two things about this and this script does not
duplicate either:

  * the backlight drops to a few percent after five idle minutes
    (custom/scripts/screensaver.sh), so time spent away is not exposure;
  * the panel is never blanked on idle, by explicit request -- a machine you
    cannot glance at is not saving power, it is off.

What is left is the exposure that happens while the user is actually working,
and the marks that are already there. That is all this script touches, and it
touches it through Hyprland's screen shader, because that is the one place
software can change the picture without owning a surface, moving a window or
fighting the brightness dial:

    panel-care.glsl   a peak ceiling -- highlights are compressed into 0.90, so
                      no app can drive a large white field at full tilt. Dark
                      and mid tones are untouched, so nothing about the desk
                      looks different except the brightest thing on it.

    panel-wash.glsl   one flat tone over the whole panel, for a few minutes, to
                      even out retention that has already appeared.

    panel-care.py on|off|toggle|status
    panel-care.py wash [minutes]     a timed wash, cancellable
    panel-care.py cancel             stop a running wash now
    panel-care.py heal               put the shader back if a wash was interrupted

The state file is what makes an interrupted wash recoverable: the wash is
recorded BEFORE the shader changes, so a kill -9 leaves behind the answer to
"which shader belongs here" rather than a grey screen. `execs.lua` runs `on` at
login, which heals that same case from the other end.

The wash defaults to four minutes, deliberately under the five-minute idle
threshold in hypridle.conf: past it the screensaver would dim the panel to a
few percent, and a wash at that brightness is not a wash.
"""

import json
import os
import shutil
import signal
import subprocess
import sys
import time

SHADER_DIR = os.path.expanduser("~/.config/hypr/custom/shaders")
CEILING_SHADER = os.path.join(SHADER_DIR, "panel-care.glsl")
WASH_SHADER = os.path.join(SHADER_DIR, "panel-wash.glsl")

STATE = os.environ.get("II_PANEL_CARE_STATE", "/tmp/ii-panel-care.json")

# The idle sequence's own record of "which shader to put back on wake" -- see
# forget_idle_capture_of_wash(). Not written by this script except for that one
# correction.
IDLE_STATE = os.environ.get("II_IDLE_STATE", "/tmp/ii-idle-options.json")

# Just under hypridle.conf's five-minute idle listener. See the module docstring.
DEFAULT_WASH_MINUTES = 4


def hyprctl(*args, timeout=2):
    """Run hyprctl, or return None when there is no compositor to talk to.

    Short timeout for the same reason hypr-idle-options.py uses one: every call
    here sits on a path the user is waiting on, and a stuck hyprctl must be
    given up on rather than waited for.
    """
    try:
        proc = subprocess.run(["hyprctl", *args], capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None
    return proc.stdout if proc.returncode == 0 else None


def current_shader():
    """The compositor's current screen shader path, or '' when there is none."""
    out = hyprctl("getoption", "-j", "decoration:screen_shader")
    if not out:
        return ""
    try:
        data = json.loads(out)
    except Exception:
        return ""
    value = data.get("str", "")
    # Hyprland spells "empty string" as [[EMPTY]] in this output.
    if value.strip() in ("", "[[EMPTY]]"):
        return ""
    return value.strip()


def set_shader(path):
    """Point decoration:screen_shader at `path` ('' clears it).

    This config is Lua, so an option is set with an hl.config() call rather than
    `hyprctl keyword`. Same call shape as hypr-idle-options.py's veil path.
    """
    literal = str(path).replace("\\", "\\\\").replace('"', '\\"')
    hyprctl("eval", 'hl.config({ decoration = { screen_shader = "%s" } })' % literal)


def forget_idle_capture_of_wash(base):
    """Correct the idle veil's record if it captured the WASH as its restore value.

    screensaver.sh's veil path records the shader that is currently set and puts
    it back on wake (hypr-idle-options.py:veil_on/veil_off). If the veil fires
    while a wash is up, that recorded value IS the flat wash -- and waking would
    repaint the screen grey with no timer left to take it away. That is a screen
    the user cannot explain and a shortcut away from working again.

    A wash outlives no other state, so the record is rewritten to whatever the
    screen is supposed to be showing now. Only that exact case is touched: a
    capture of any other shader is left alone, because it belongs to the user.
    """
    try:
        with open(IDLE_STATE) as handle:
            state = json.load(handle)
    except Exception:
        return
    if not isinstance(state, dict) or "shader" not in state:
        return
    captured = state.get("shader") or ""
    if os.path.realpath(captured or "/nonexistent") != os.path.realpath(WASH_SHADER):
        return
    state["shader"] = base
    try:
        with open(IDLE_STATE, "w") as handle:
            json.dump(state, handle)
    except Exception:
        pass


def load_state():
    try:
        with open(STATE) as handle:
            return json.load(handle)
    except Exception:
        return {}


def save_state(state):
    try:
        with open(STATE, "w") as handle:
            json.dump(state, handle)
    except Exception:
        pass


def notify(summary, body=""):
    """Post a desktop notification, best effort.

    Through D-Bus directly, NOT notify-send: on this machine the notify-send
    binary dies with `undefined symbol:
    notify_notification_get_activation_app_launch_context` (a libnotify the
    installed client was not built against), so every notify-send call is a
    silent failure. gdbus only speaks the protocol, so it does not care which
    libnotify is installed. notify-send is kept as a fallback for the case of a
    machine with no gdbus.
    """
    if shutil.which("gdbus"):
        try:
            subprocess.run(
                [
                    "gdbus", "call", "--session",
                    "--dest", "org.freedesktop.Notifications",
                    "--object-path", "/org/freedesktop/Notifications",
                    "--method", "org.freedesktop.Notifications.Notify",
                    "Panel care", "0", "", summary, body, "[]", "{}", "4000",
                ],
                capture_output=True, timeout=3,
            )
            return
        except Exception:
            pass
    if not shutil.which("notify-send"):
        return
    try:
        subprocess.run(["notify-send", "-a", "Panel care", summary, body],
                       capture_output=True, timeout=3)
    except Exception:
        pass


def pid_alive(pid):
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def ceiling_owned():
    """True when the ceiling shader is the one the compositor is using."""
    return os.path.realpath(current_shader() or "/nonexistent") == os.path.realpath(CEILING_SHADER)


def base_shader(state):
    """What the screen should show when no wash is running."""
    if state.get("ceiling"):
        return CEILING_SHADER
    return state.get("prior", "")


def cmd_heal():
    """Recover from a wash that was interrupted, without applying anything new.

    A kill -9 during a wash leaves the flat shader set with no timer to remove
    it. The state file knows a wash was in flight; if its process is gone, the
    wash is over as far as the screen is concerned.
    """
    state = load_state()
    if "wash_pid" not in state:
        return False
    if pid_alive(state.get("wash_pid")):
        return False
    state.pop("wash_pid", None)
    state.pop("wash_until", None)
    base = base_shader(state)
    set_shader(base)
    forget_idle_capture_of_wash(base)
    save_state(state)
    return True


def cmd_on(argv):
    state = load_state()
    if cmd_heal():
        state = load_state()
    if not state.get("ceiling"):
        # Remember what to go back to. Captured once, so toggling on and off
        # repeatedly cannot overwrite the real previous value with our own.
        state["prior"] = current_shader()
        state["ceiling"] = True
        save_state(state)
    set_shader(CEILING_SHADER)
    print("panel care: peak ceiling on (highlights capped at 90%)")
    return 0


def cmd_off(argv):
    state = load_state()
    if cmd_heal():
        state = load_state()
    state["ceiling"] = False
    set_shader(state.get("prior", ""))
    state.pop("prior", None)
    save_state(state)
    print("panel care: peak ceiling off")
    return 0


def cmd_toggle(argv):
    state = load_state()
    return cmd_off(argv) if state.get("ceiling") else cmd_on(argv)


def cmd_status(argv):
    state = load_state()
    shader = current_shader()
    print("ceiling:     %s" % ("on" if state.get("ceiling") else "off"))
    print("shader:      %s" % (shader or "(none)"))
    until = state.get("wash_until")
    if until:
        left = max(0, int(until - time.time()))
        print("wash:        running, %ds left (pid %s)" % (left, state.get("wash_pid")))
    else:
        print("wash:        idle")
    return 0


def cmd_cancel(argv):
    state = load_state()
    pid = state.get("wash_pid")
    if not pid_alive(pid):
        if cmd_heal():
            print("panel care: wash was already over, shader restored")
        else:
            print("panel care: no wash running")
        return 0
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass
    print("panel care: wash cancelled")
    return 0


def cmd_wash(argv):
    """Hold a flat field for N minutes, then put the screen back."""
    state = load_state()
    if cmd_heal():
        state = load_state()

    # A second invocation during a wash is the cancel gesture, not a restart.
    if pid_alive(state.get("wash_pid")):
        return cmd_cancel(argv)

    minutes = DEFAULT_WASH_MINUTES
    if len(argv) > 2:
        try:
            minutes = max(1, int(float(argv[2])))
        except ValueError:
            print("usage: panel-care.py wash [minutes]", file=sys.stderr)
            return 2

    base = base_shader(state)
    state["wash_pid"] = os.getpid()
    state["wash_until"] = time.time() + minutes * 60
    # Written BEFORE the shader changes, so an interrupted wash still knows
    # which shader the screen belongs to.
    save_state(state)

    def restore(*_args):
        st = load_state()
        st.pop("wash_pid", None)
        st.pop("wash_until", None)
        restore_to = base_shader(st)
        set_shader(restore_to)
        forget_idle_capture_of_wash(restore_to)
        save_state(st)
        notify("Wash finished", "Screen restored.")
        sys.exit(0)

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        try:
            signal.signal(sig, restore)
        except Exception:
            pass

    set_shader(WASH_SHADER)
    notify("Evening out retention", "%d minutes. Press the wash shortcut again to stop." % minutes)
    print("panel care: washing for %d minute(s); press the shortcut again (or run cancel) to stop" % minutes)

    deadline = state["wash_until"]
    while time.time() < deadline:
        time.sleep(1)
    restore()
    return 0


COMMANDS = {
    "on": cmd_on,
    "off": cmd_off,
    "toggle": cmd_toggle,
    "status": cmd_status,
    "wash": cmd_wash,
    "cancel": cmd_cancel,
    "heal": lambda argv: (cmd_heal(), 0)[1],
}


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help", "help"):
        print(__doc__.strip())
        return 0 if len(argv) >= 2 else 2
    command = COMMANDS.get(argv[1])
    if command is None:
        print("unknown command: %s" % argv[1], file=sys.stderr)
        return 2
    return command(argv) or 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
