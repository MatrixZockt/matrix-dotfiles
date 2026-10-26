#!/usr/bin/env bash
# Desktop theme check suite: does the light/dark switch actually reach the apps?
#
# Development scaffolding, in the style of scripts/system/files-check.sh: it
# drives the shipped path -- scripts/colors/sync-desktop-theme.sh, the one lever
# the shell's toggle, the settings toggle, the shortcut and login all pull --
# and asserts on what real toolkit windows then report about themselves.
#
# WHY THIS EXISTS. "The desktop apps still don't switch" was true twice, for two
# different reasons, and both of them were invisible to every check that only
# looked at the keys the script writes:
#
#   * the keys were right and the GTK theme NAME was `Default`, a stub with no
#     gtk.css, so GTK3 fell back to its built-in light Adwaita in both modes;
#   * then the name was dark in dark mode and `Adwaita` in light mode -- and
#     `Adwaita` picks its variant BY THE FLAG, which a RUNNING app read at
#     startup. So dark -> light left every open GTK3 window dark: a switch that
#     only worked in one direction.
#
# Both are things you can only see from inside a running toolkit, so that is
# what this builds. Four questions:
#
#   A. in a given mode, does a FRESH app come up in that mode?
#   B. does it still, when the stale prefer-dark flag on disk says the opposite
#      (which is what a running app is holding when the mode changes under it)?
#   C. does an ALREADY RUNNING GTK3 app follow the switch, both directions?
#   D. and a running GTK4 app with no libadwaita (pavucontrol's case, which
#      reads the flag and not `color-scheme`)?
#   E. and a running Qt app, which has no key of its own at all here and can
#      only follow the desktop portal?
#
# The desktop is left in the mode it was found in, and the probes are removed,
# even when an assertion fails (see the trap). Run it from anywhere:
#
#   bash scripts/colors/theme-check.sh
set -u

SHELL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYNC="$SHELL_DIR/scripts/colors/sync-desktop-theme.sh"
MODE_FILE="$HOME/.local/state/quickshell/theme-mode"
PROBES="$(mktemp -d /tmp/theme-check.XXXXXX)"
export QT_ASSUME_STDERR_HAS_CONSOLE=1   # or a Qt probe's print() goes nowhere
export QT_QPA_PLATFORMTHEME=xdgdesktopportal

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }
boo() { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: expected [$3] got [$2]"; }
skip(){ echo "  ..    $1"; }

# What the toolkits report when they are in each mode. GTK3 says it with a
# window background, GTK4 and Qt with their resolved text/scheme.
gtk3_dark="#353535"; gtk3_light="#f6f5f4"
gtk4_dark="#eeeeec"; gtk4_light="#2e3436"
# Qt::ColorScheme: Unknown 0, Light 1, Dark 2.
qt_dark=2; qt_light=1

orig_mode="$(cat "$MODE_FILE" 2>/dev/null || true)"
[[ "$orig_mode" == "light" ]] || orig_mode="dark"

probe_pids=""
cleanup() {
    local pid
    for pid in $probe_pids; do kill "$pid" 2>/dev/null; done
    "$SYNC" "$orig_mode" >/dev/null 2>&1   # leave the desktop as it was found
    rm -rf "$PROBES"
}
trap cleanup EXIT

# ── the probes: running toolkit windows that report what they resolved ──────
# GTK3, once and briefly, to answer "what does a fresh app look like".
cat > "$PROBES/gtk3-fresh.py" <<'PROBE'
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk
s = Gtk.Settings.get_default()
w = Gtk.Window(); w.realize()
c = w.get_style_context().get_background_color(Gtk.StateFlags.NORMAL)
print(f"bg=#{round(c.red*255):02x}{round(c.green*255):02x}{round(c.blue*255):02x} "
      f"theme={s.get_property('gtk-theme-name')} "
      f"prefer-dark={s.get_property('gtk-application-prefer-dark-theme')}")
PROBE

# GTK3 kept open, so a live switch can be watched from inside a running app.
cat > "$PROBES/gtk3-live.py" <<'PROBE'
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk
window = Gtk.Window(title="ii theme check")
window.set_default_size(300, 120)
window.show_all()
def report():
    c = window.get_style_context().get_background_color(Gtk.StateFlags.NORMAL)
    s = Gtk.Settings.get_default()
    print(f"bg=#{round(c.red*255):02x}{round(c.green*255):02x}{round(c.blue*255):02x} "
          f"theme={s.get_property('gtk-theme-name')} "
          f"prefer-dark={s.get_property('gtk-application-prefer-dark-theme')}", flush=True)
    return True
GLib.timeout_add_seconds(1, report)
window.connect("destroy", Gtk.main_quit)
GLib.timeout_add_seconds(90, Gtk.main_quit)
Gtk.main()
PROBE

# GTK4, kept open. GTK4 has no Gtk.main() any more, and no libadwaita here, so
# this one answers "does a GTK4 app that never reads color-scheme follow?".
cat > "$PROBES/gtk4-live.py" <<'PROBE'
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import GLib, Gtk
loop = GLib.MainLoop()
window = Gtk.Window(title="ii theme check")
window.set_default_size(320, 120)
window.present()
def hexof(color):
    return "#{:02x}{:02x}{:02x}".format(
        round(color.red * 255), round(color.green * 255), round(color.blue * 255))
def report():
    s = Gtk.Settings.get_default()
    print(f"text={hexof(window.get_color())} theme={s.get_property('gtk-theme-name')} "
          f"prefer-dark={s.get_property('gtk-application-prefer-dark-theme')}", flush=True)
    return True
def quit_(*_):
    loop.quit(); return False
GLib.timeout_add_seconds(1, report)
GLib.timeout_add_seconds(90, quit_)
window.connect("close-request", quit_)
loop.run()
PROBE

# Qt, kept open, under the platform theme the session gives real Qt apps.
cat > "$PROBES/qt-live.qml" <<'PROBE'
import QtQuick
import QtQuick.Window
Window {
    id: root
    width: 320; height: 120; visible: true; title: "ii theme check"
    function report(tag) { print(tag, "colorScheme=", Qt.styleHints.colorScheme) }
    Timer { interval: 1000; running: true; repeat: true; onTriggered: root.report("tick") }
    Component.onCompleted: root.report("start")
}
PROBE

# One toolkit's live story: start it inside `start`, switch the desktop to
# `target`, and see whether the same window followed. The flag on disk is
# deliberately left saying `start` -- that is the state a real switch leaves a
# running app in, and the state the one-way switch used to fail in.
live_run() {   # toolkit, start, target, want-before, want-after, reported-value
    local toolkit="$1" start="$2" target="$3" want_before="$4" want_after="$5" field="$6"
    local log="$PROBES/$toolkit.log" cmd
    case "$toolkit" in
        gtk3) cmd=(python3 "$PROBES/gtk3-live.py") ;;
        gtk4) cmd=(python3 "$PROBES/gtk4-live.py") ;;
        qt)   command -v qml6 >/dev/null || { skip "no qml6, so no Qt probe"; return; }
              cmd=(qml6 "$PROBES/qt-live.qml") ;;
    esac
    local stale=0; [ "$start" = dark ] && stale=1
    local f
    for f in "$HOME/.config/gtk-3.0/settings.ini" "$HOME/.config/gtk-4.0/settings.ini"; do
        sed -i'' "s/^gtk-application-prefer-dark-theme=.*/gtk-application-prefer-dark-theme=$stale/" "$f"
    done
    "$SYNC" "$start" >/dev/null
    : > "$log"
    "${cmd[@]}" >"$log" 2>&1 &
    local pid=$!
    probe_pids="$probe_pids $pid"
    sleep 3
    local before; before="$(tail -1 "$log")"
    "$SYNC" "$target" >/dev/null
    sleep 3
    local after; after="$(tail -1 "$log")"
    kill "$pid" 2>/dev/null
    local b a
    # The space after `=` is not decoration: QML's print() separates its
    # arguments with one, so a Qt reading arrives as "colorScheme= 2".
    b="$(printf '%s' "$before" | sed -n "s/.*$field=[ ]*\([^ ][^ ]*\).*/\1/p")"
    a="$(printf '%s' "$after"  | sed -n "s/.*$field=[ ]*\([^ ][^ ]*\).*/\1/p")"
    echo "    $toolkit, $start -> $target:  $before   ==>   $after"
    if [ -z "$b" ]; then
        bad "$toolkit never reported (see $log)"
        return
    fi
    boo "$toolkit window is $start while the desktop is" "$b" "$want_before"
    boo "$toolkit window followed the switch live" "$a" "$want_after"
}

echo "Checking the switch with real toolkit windows; the desktop is put back in $(echo "$orig_mode") at the end."
echo

echo "A. a freshly started GTK3 app, in each mode"
for mode in dark light; do
    "$SYNC" "$mode" >/dev/null
    out="$(python3 "$PROBES/gtk3-fresh.py" 2>/dev/null)"
    bg="$(printf '%s' "$out" | sed -n 's/.*bg=\([^ ]*\).*/\1/p')"
    theme="$(printf '%s' "$out" | sed -n 's/.*theme=\([^ ]*\).*/\1/p')"
    if [ "$mode" = dark ]; then boo "a fresh app is dark (theme $theme)" "$bg" "$gtk3_dark"
    else boo "a fresh app is light (theme $theme)" "$bg" "$gtk3_light"; fi
done
echo

echo "B. a fresh app started with the flag left over from the OTHER mode"
for mode in dark light; do
    if [ "$mode" = dark ]; then stale=0; want="$gtk3_dark"; else stale=1; want="$gtk3_light"; fi
    for f in "$HOME/.config/gtk-3.0/settings.ini" "$HOME/.config/gtk-4.0/settings.ini"; do
        sed -i'' "s/^gtk-application-prefer-dark-theme=.*/gtk-application-prefer-dark-theme=$stale/" "$f"
    done
    "$SYNC" "$mode" >/dev/null
    bg="$(python3 "$PROBES/gtk3-fresh.py" 2>/dev/null | sed -n 's/.*bg=\([^ ]*\).*/\1/p')"
    boo "the $mode mode wins over a stale prefer-dark=$stale" "$bg" "$want"
done
echo

echo "C. an already running GTK3 app, switched both directions"
live_run gtk3 dark  light "$gtk3_dark"  "$gtk3_light" bg
live_run gtk3 light dark  "$gtk3_light" "$gtk3_dark"  bg
echo

echo "D. an already running GTK4 app (no libadwaita, so it never reads color-scheme)"
live_run gtk4 dark  light "$gtk4_dark"  "$gtk4_light" text
live_run gtk4 light dark  "$gtk4_light" "$gtk4_dark"  text
echo

echo "E. an already running Qt app (no key of its own; it has only the portal)"
live_run qt dark  light "$qt_dark"  "$qt_light" colorScheme
live_run qt light dark  "$qt_light" "$qt_dark"  colorScheme
echo

echo "F. the keys the script owns, after a switch to light"
"$SYNC" light >/dev/null
boo "color-scheme"  "$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null | tr -d "'")" "prefer-light"
boo "gtk-theme"     "$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null | tr -d "'")" "Adwaita-light"
boo "gtk3 prefer-dark flag" "$(sed -n 's/^gtk-application-prefer-dark-theme=//p' "$HOME/.config/gtk-3.0/settings.ini")" "0"
boo "gtk4 prefer-dark flag" "$(sed -n 's/^gtk-application-prefer-dark-theme=//p' "$HOME/.config/gtk-4.0/settings.ini")" "0"

"$SYNC" "$orig_mode" >/dev/null
echo
echo "$PASS passed, $FAIL failed (desktop left in $orig_mode)"
[ "$FAIL" -eq 0 ]
