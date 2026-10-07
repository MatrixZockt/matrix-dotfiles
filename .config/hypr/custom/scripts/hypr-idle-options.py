#!/usr/bin/env python3
"""Borrow and return live compositor settings while the screen is idle.

Why this exists as a separate program: Hyprland 0.56 here runs the Lua config
parser, so `hyprctl keyword` refuses to do anything ("keyword can't work with
non-legacy parsers. Use eval."). Options are set with `hyprctl eval
'hl.config({...})'` instead, which means building nested Lua tables -- and doing
that in bash is where a typo turns into a black screen.

Every option this touches is READ FIRST and written into a state file, and the
`off` verbs put the captured value back. That is the whole safety story: the
idle screen never mutates a setting it cannot restore, so
`decoration:blur:enabled=false` can never outlive the dim, and a screen shader
you had yourself (the shell's anti-flashbang, say) comes back rather than being
silently replaced by nothing.

Usage:
    hypr-idle-options.py eco-on | eco-off | veil-on | veil-off | status
    hypr-idle-options.py clear      # forget the state (no compositor around)

The state file lives in /tmp: it is about this session's current dim, not about
the machine's configuration.
"""

import json
import os
import subprocess
import sys

STATE = os.environ.get("II_IDLE_STATE", "/tmp/ii-idle-options.json")
VEIL_SHADER = os.path.expanduser("~/.config/hypr/custom/shaders/idle-veil.glsl")

# The compositor work the idle screen stops doing. All of these are options that
# cost GPU time on every frame, idle or not -- blur is the expensive one.
ECO_OPTIONS = [
    ("decoration:blur:enabled", False),
    ("decoration:shadow:enabled", False),
    ("animations:enabled", False),
    ("debug:vfr", True),
]


def hyprctl(*args, timeout=2):
    """Run hyprctl, or return None when there is no compositor to talk to.

    The timeout is deliberately short. Every call here happens either on the way
    into the idle screen or on the way back out of it, and the wake path is the
    one that matters: a hyprctl that hangs must not hold the screen dark while
    it waits. Two seconds is far longer than any of these calls takes normally
    (they are local socket round trips) and short enough that a stuck one is
    given up on rather than waited for.
    """
    try:
        proc = subprocess.run(["hyprctl", *args], capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None
    return proc.stdout if proc.returncode == 0 else None


def get_option(option):
    """Read one option as (kind, value), or None when it does not exist."""
    out = hyprctl("getoption", "-j", option)
    if not out:
        return None
    try:
        data = json.loads(out)
    except Exception:
        return None
    for kind in ("bool", "int", "float", "str"):
        if kind in data:
            value = data[kind]
            if kind == "str":
                # Hyprland spells "empty string" as [[EMPTY]] in this output.
                if value.strip() in ("", "[[EMPTY]]"):
                    value = ""
            return kind, value
    return None


def lua_literal(kind, value):
    if kind == "bool":
        return "true" if value else "false"
    if kind == "str":
        return '"%s"' % str(value).replace("\\", "\\\\").replace('"', '\\"')
    return str(value)


def lua_config(pairs):
    """Turn [("decoration:blur:enabled", "false")] into one hl.config({...}) call."""
    root = {}
    for path, literal in pairs:
        node = root
        parts = path.replace(":", ".").split(".")
        for part in parts[:-1]:
            node = node.setdefault(part, {})
        node[parts[-1]] = literal

    def render(node):
        return "{ " + ", ".join(
            "%s = %s" % (key, render(value) if isinstance(value, dict) else value)
            for key, value in node.items()
        ) + " }"

    return "hl.config(%s)" % render(root)


def eval_lua(code):
    hyprctl("eval", code)


def load_state():
    try:
        with open(STATE) as handle:
            return json.load(handle)
    except Exception:
        return {}


def save_state(state):
    try:
        if state:
            with open(STATE, "w") as handle:
                json.dump(state, handle)
        elif os.path.exists(STATE):
            os.remove(STATE)
    except Exception:
        pass


def popup_live():
    """True while the files app (the last layer-shell popup) is up.

    Same contract as before: <pid> in $XDG_RUNTIME_DIR/quickshell-popup-<name>,
    and the pid's cmdline must still name the app's own qml. A stale file must
    not hold blur hostage. (The settings app and the task manager used to be
    checked here too; they are ordinary desktop windows now, so eco may dim
    them like anything else.)
    """
    runtime = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
    for name in ("files",):
        path = os.path.join(runtime, f"quickshell-popup-{name}")
        try:
            pid = open(path).read().strip().split()[0]
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                if f"{name}.qml".encode() in f.read():
                    return True
        except (OSError, IndexError):
            continue
    return False


def eco_on(state):
    # An earlier dim already owns these values: keep them, so a second dim
    # still restores the ORIGINAL settings rather than the borrowed ones.
    if "eco" in state:
        return
    captured, pairs = {}, []
    for option, target in ECO_OPTIONS:
        # Blur is what draws the files app's frosted veil. With it open,
        # killing blur turns the veil into a flat transparent sheet -- the app
        # looks broken mid-dim, and the user is by definition still at the
        # machine (something is open on top). Shadows/animations/vfr still
        # idle; the frost stays.
        if option == "decoration:blur:enabled" and popup_live():
            continue
        current = get_option(option)
        if current is None:
            continue
        kind, value = current
        captured[option] = [kind, value]
        pairs.append((option, lua_literal(kind, target)))
    if not pairs:
        return
    state["eco"] = captured
    save_state(state)
    eval_lua(lua_config(pairs))


def eco_off(state):
    captured = state.pop("eco", None)
    if not captured:
        return
    save_state(state)
    eval_lua(lua_config([(option, lua_literal(kind, value))
                         for option, (kind, value) in captured.items()]))


def veil_on(state):
    if "shader" in state:
        return
    current = get_option("decoration:screen_shader")
    if current is None or not os.path.exists(VEIL_SHADER):
        return
    state["shader"] = current[1]
    save_state(state)
    eval_lua(lua_config([("decoration:screen_shader", lua_literal("str", VEIL_SHADER))]))


def veil_off(state):
    if "shader" not in state:
        return
    previous = state.pop("shader")
    save_state(state)
    # An empty string is Hyprland's "no shader"; a captured path means the user
    # had one of their own and it goes back exactly as it was.
    eval_lua(lua_config([("decoration:screen_shader", lua_literal("str", previous))]))


def main(argv):
    verb = argv[1] if len(argv) > 1 else "status"
    state = load_state()

    if verb == "eco-on":
        eco_on(state)
    elif verb == "eco-off":
        eco_off(state)
    elif verb == "popup-blur-on":
        # The files app opened AFTER the dim: eco has already switched blur off and
        # captured it. Bring the frost back for the veil's sake (eco_off will
        # later restore the captured ORIGINAL, which is true anyway -- so no
        # bookkeeping is needed here; this is a one-way correction).
        if "eco" in state and "decoration:blur:enabled" in state["eco"]:
            eval_lua(lua_config([("decoration:blur:enabled", lua_literal("bool", True))]))
    elif verb == "veil-on":
        veil_on(state)
    elif verb == "veil-off":
        veil_off(state)
    elif verb == "clear":
        save_state({})
    elif verb == "status":
        print(json.dumps(state, indent=2))
    else:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
