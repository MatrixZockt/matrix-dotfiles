#!/usr/bin/env python3
"""Anamorphic desktop-switch driver.

Arms the compositor's screen-wide GLSL pass (decoration:screen_shader) with
the anamorphic-illusion shader around a workspace switch, then removes it.

IMPORTANT: this fork's screen-shader pipeline does NOT feed a `time` uniform
to user shaders (proven live: time stays 0 forever, even with forced damage).
So the shader renders at CONSTANT full strength and the ANIMATION CLOCK IS
THIS DRIVER: arm -> dispatch the switch -> hold past the ~300 ms switch
animation -> clear. The driver is the sole clearer.

Safety contract:
  * The driver ALWAYS clears -- finally-block, atexit, and SIGINT/SIGTERM
    handlers. A second invocation re-arms/re-clears idempotently.
  * The option is not persisted, so the next reload/login also clears it.

Usage:
  anamorphic.py focus N     switch to workspace N with the illusion
  anamorphic.py rel +1/-1   relative switch (the widget's scroll wheel)
  anamorphic.py clear       remove the shader immediately
"""

import atexit
import json
import os
import signal
import subprocess
import sys
import time

HIS = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") or next(
    os.listdir(f"/run/user/{os.getuid()}/hypr"))
XDG = f"/run/user/{os.getuid()}"
SHADER = os.path.expanduser("~/.config/hypr/custom/shaders/anamorphic.glsl")
DUR = 0.55  # seconds armed: covers the ~300 ms switch animation + margin


def hyprctl_eval(expr: str) -> None:
    subprocess.run(["hyprctl", "--instance", HIS, "eval", expr],
                   env=dict(os.environ, XDG_RUNTIME_DIR=XDG,
                            HYPRLAND_INSTANCE_SIGNATURE=HIS),
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   timeout=5)


def set_shader(path: str) -> None:
    q = path.replace('"', '\\"')
    hyprctl_eval(f'hl.config({{decoration={{screen_shader="{q}"}}}})')


def dispatch_ws(target: int) -> None:
    hyprctl_eval(f"hl.dispatch(hl.dsp.focus({{workspace={target}}}))")


def workspace_exists(n: int) -> bool:
    # The dispatcher silently CREATES a nonexistent workspace while focusing it
    # (fork behaviour, verified live: focus({workspace=9}) on [1,2] -> [1,2,9]).
    # Over a brand-new empty desktop the anamorphic pass has no motion to mask
    # -- just a static wallpaper -- so the time-based distortion reads as pure
    # glitch. The compositor's own switch animation is the right look there.
    try:
        out = subprocess.run(
            ["hyprctl", "--instance", HIS, "-j", "workspaces"],
            capture_output=True, text=True, timeout=5).stdout
        return any(int(w["id"]) == n for w in json.loads(out))
    except Exception:
        return True  # unknown -> keep the old behaviour rather than skip


def active_workspace() -> int:
    try:
        out = subprocess.run(
            ["hyprctl", "--instance", HIS, "-j", "activeworkspace"],
            capture_output=True, text=True, timeout=5).stdout
        return int(json.loads(out)["id"])
    except Exception:
        return 1


def clear(*_) -> None:
    set_shader("")


atexit.register(clear)
signal.signal(signal.SIGINT, clear)
signal.signal(signal.SIGTERM, clear)


def performance_mode_on() -> bool:
    # Performance mode owns the motion budget (services/PerformanceMode.qml ->
    # scripts/performance/apply.sh, the only writer of custom/performance.lua;
    # its ON state always carries the popup.setPerformance(true) hook). When it
    # is on, the whole illusion is skipped: an armed screen shader forces
    # full-frame redraws every frame -- the exact cost performance mode exists
    # to avoid.
    try:
        perf = os.path.expanduser("~/.config/hypr/custom/performance.lua")
        with open(perf, "r", encoding="utf-8", errors="replace") as fh:
            return "setPerformance(true)" in fh.read()
    except OSError:
        return False


def focus(n: int) -> None:
    if performance_mode_on():
        dispatch_ws(n)
        return
    # The screen-wide distortion pass is DISABLED for desktop switches. On
    # this machine it tore/glitched on every entry point -- new-desktop
    # clicks, same-desktop clicks, and normal switches alike (owner
    # screenshots show the shader frozen mid-hold). The compositor's own
    # switch animation is clean, so that is what plays now. The env flag
    # brings the effect back if it is ever wanted for debugging.
    if not os.environ.get("II_ANAMORPHIC_ON"):
        dispatch_ws(n)
        return
    if n == active_workspace():
        # Already there (e.g. the bar's last slot IS the empty "+" desktop you
        # are standing on). Arming the shader over a "switch" that goes
        # nowhere just tears a static screen for half a second.
        return
    if not workspace_exists(n):
        # New-desktop click (the bar's "+"): no window motion to sell the
        # illusion, so skip the shader entirely.
        dispatch_ws(n)
        return
    set_shader(SHADER)
    time.sleep(0.04)  # let the compositor compile/apply before the swap
    try:
        dispatch_ws(n)
    finally:
        # Hold armed until the switch animation has fully landed, then clear.
        time.sleep(DUR)
        clear()


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "focus":
        focus(int(sys.argv[2]))
    elif cmd == "rel":
        # Relative switch for the widget's scroll wheel: rel +1 / rel -1.
        focus(max(1, active_workspace() + int(sys.argv[2])))
    elif cmd == "clear":
        clear()
        print("cleared")
    else:
        print(__doc__)
