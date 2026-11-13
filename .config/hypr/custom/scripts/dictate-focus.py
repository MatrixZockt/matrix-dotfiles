#!/usr/bin/env python3
"""Focus the text field of the focused window, so dictation has a caret to paste into.

Why this exists: holding SUPER records and then pastes Ctrl+V at whatever has the
keyboard focus. If the window is focused but no input box is selected -- the usual
state of a chat app you just clicked on the sidebar of -- the paste goes nowhere
and the sentence is silently lost. There is no Wayland API to ask "where is the
text field", so this asks the accessibility tree instead, which is the one
interface that exposes widgets to the outside world.

AT-SPI only knows about apps that publish an accessibility tree. GTK4 needs
GTK_A11Y=atspi (or a running AT), Chromium/Electron need
--force-renderer-accessibility. An app that publishes nothing exits as
"no-a11y" and the caller falls back to its old behaviour.

Output, one line, for the shell script:
    already    a text field already has the focus -- nothing to do
    focused    an unfocused text field was found and given the focus
    no-entry   the app is in the tree but has no editable field
    no-a11y    the app publishes no accessibility tree at all
"""
import json
import subprocess
import sys

try:
    import gi

    gi.require_version("Atspi", "2.0")
    from gi.repository import Atspi
except Exception:
    print("no-a11y")
    raise SystemExit(0)


def active_window():
    try:
        raw = subprocess.run(["hyprctl", "activewindow", "-j"],
                             capture_output=True, text=True, timeout=2).stdout
        return json.loads(raw)
    except Exception:
        return {}


def editable_nodes(node, depth=0, out=None, budget=None):
    """Every editable widget under `node`, with the states that matter here."""
    if out is None:
        out = []
    if budget is None:
        budget = [1500]                     # a pathological tree must not hang a hold
    if budget[0] <= 0 or depth > 40:
        return out
    budget[0] -= 1
    try:
        state = node.get_state_set()
        if state.contains(Atspi.StateType.EDITABLE):
            showing = state.contains(Atspi.StateType.SHOWING)
            focused = state.contains(Atspi.StateType.FOCUSED)
            area = 0
            try:
                comp = node.get_component_iface()
                if comp is not None:
                    ext = comp.get_extents(Atspi.CoordType.SCREEN)
                    area = max(0, ext.width) * max(0, ext.height)
            except Exception:
                pass
            out.append({"node": node, "focused": focused, "showing": showing,
                        "area": area, "role": node.get_role_name()})
    except Exception:
        return out
    try:
        count = node.get_child_count()
    except Exception:
        count = 0
    for i in range(count):
        try:
            editable_nodes(node.get_child_at_index(i), depth + 1, out, budget)
        except Exception:
            continue
    return out


def grab_focus(node):
    """Give `node` the caret. Returns True when the toolkit accepted it."""
    # An editable widget also implements Atspi.EditableText, which lets the text
    # be set directly -- that is the path that works when the widget refuses to
    # take focus (some textareas only focus on a real click).
    for attempt in (
        lambda: Atspi.Component.grab_focus(node),
        lambda: node.get_component_iface().grab_focus(),
        lambda: node.grab_focus(),
    ):
        try:
            if attempt():
                return True
        except Exception:
            continue
    return False


def main():
    win = active_window()
    pid = win.get("pid")
    if not pid:
        print("no-a11y")
        return 0

    Atspi.init()
    desktop = Atspi.get_desktop(0)
    app = None
    for i in range(desktop.get_child_count()):
        candidate = desktop.get_child_at_index(i)
        try:
            if candidate.get_process_id() == pid:
                app = candidate
                break
        except Exception:
            continue
    if app is None:
        print("no-a11y")
        return 0

    nodes = [n for n in editable_nodes(app) if n["showing"] or n["focused"]]
    if not nodes:
        print("no-entry")
        return 0
    if any(n["focused"] for n in nodes):
        print("already")
        return 0

    # The biggest visible editable widget is the main input: a search box is a
    # strip, a chat prompt is a box. Ties keep tree order, which is top-down.
    best = max(nodes, key=lambda n: n["area"])
    if grab_focus(best["node"]):
        print("focused")
    else:
        print("no-entry")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # Never let this helper be the reason a dictation fails.
        print("no-a11y")
