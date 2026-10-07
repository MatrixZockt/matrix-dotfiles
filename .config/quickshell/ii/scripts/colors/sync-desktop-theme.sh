#!/usr/bin/env bash
# Push the shell's light/dark decision onto every other toolkit on the
# desktop. Called by services/MaterialThemeLoader.qml (applySystemTheme),
# which is the one place the shell's palette becomes the live theme, so the
# quick toggle, the settings toggle, the global shortcut, the template picker
# and plain startup all funnel through here.
#
# Usage: sync-desktop-theme.sh dark|light
#        sync-desktop-theme.sh        read the mode the shell last recorded
#                                     (~/.local/state/quickshell/theme-mode),
#                                     so a login-time caller can never disagree
#                                     with the shell that is about to start
#
# WHY THIS EXISTS, and why it is not just `gsettings set color-scheme`:
#
# `color-scheme` is the modern key and it does work -- libadwaita and GTK4
# read it. But it is the ONLY thing the shell was setting, and the desktop
# has three more opinions:
#
#   1. GTK3 apps ignore `color-scheme` entirely. They read `gtk-theme`, which
#      was pointing at `adw-gtk3` -- a theme that is not installed here (there
#      are exactly two themes on this machine: Default and Emacs). GTK fell
#      back silently to its built-in light Adwaita, so GTK3 windows stayed
#      white on a dark desktop no matter what the shell said.
#   2. GTK3 and GTK4 both need `gtk-application-prefer-dark-theme` to darken
#      WITHOUT a dark theme installed. That is the whole point of the flag,
#      and with no themes present it is the only lever that exists.
#   3. Qt has no equivalent key and no qt5ct/qt6ct here. The installed lever is
#      a Qt platform theme plugin (`libqgtk3.so` and `libqxdgdesktopportal.so`
#      are both present for Qt5 and Qt6). Which one you point at matters, and
#      it was measured rather than assumed, with a probe that builds a
#      QApplication and prints styleHints()->colorScheme() next to the
#      resolved widget palette:
#
#          kde              -> colorScheme=Unknown  widgetPalette=LIGHT
#          gtk3             -> colorScheme=Light    widgetPalette=LIGHT
#          xdgdesktopportal -> colorScheme=Dark     widgetPalette=DARK
#
#      So gtk3 -- which is what this script used to write -- does NOT report
#      dark on this machine: QGtk3Theme never folds the GTK dark flag into
#      colorScheme, so Qt apps stayed light even with everything above set
#      correctly. xdgdesktopportal reads color-scheme through the desktop
#      portal and does report dark, and it re-reads it, so a Qt app follows a
#      live theme switch too. That is the value used here and in
#      hyprland/env.lua.
#
# So the desktop theme is not one key, it is four, and only writing one of
# them is what makes a dark desktop look like it is still half light.
#
# WHY IT IS ALSO CALLED AT LOGIN (custom/execs.lua), before the shell:
#
# Everything below is written to disk or to dconf, and every toolkit on this
# desktop reads it ONCE, at startup. That makes the desktop's light/dark
# answer depend on WHEN an app was launched, not on what the desktop is
# currently themed like -- the report this fixes was: open an app in the gap
# between Hyprland coming up and the shell loading (it takes ~14s on this
# machine), and it comes up light; ten seconds later the shell applies the dark
# palette and the app is still light, because nothing tells a running GTK3 or
# Qt process to re-read the file it already parsed. No later fix is possible
# from inside the app.
#
# So the decision has to be on disk BEFORE anything can be launched, which is
# why this is also called from the compositor's own startup. The mode file is
# the same one custom/theme.lua reads for the compositor's chrome, so the
# window borders and the applications start out agreeing, and the shell's own
# call a few seconds later is then a no-op rather than a correction.
set -euo pipefail

mode_file="$HOME/.local/state/quickshell/theme-mode"
mode="${1:-}"
if [[ -z "$mode" ]]; then
    # No argument = "whatever the shell last decided". Defaults to dark, which
    # is the mode every config file on this machine still assumes, so a
    # missing or corrupt mode file degrades to old behaviour rather than to a
    # light desktop.
    mode="$(cat "$mode_file" 2>/dev/null || true)"
    [[ "$mode" == "light" ]] || mode="dark"
fi
case "$mode" in
    dark)  prefer="prefer-dark";  dark_flag=1 ;;
    light) prefer="prefer-light"; dark_flag=0 ;;
    *) echo "usage: $0 [dark|light]" >&2; exit 2 ;;
esac

# The Qt platform theme. Same for both modes -- it is a *source* of the
# light/dark signal (the desktop portal), not a consequence of it.
qt_theme="xdgdesktopportal"

# The cursor theme, published here for the same reason QT_QPA_PLATFORMTHEME is:
# systemd-launched applications get their environment from environment.d, not
# from Hyprland, so a key set only in hyprland/env.lua would reach the shell but
# not a user unit. Qt drops every cursorShape request when it has no theme
# loaded, which is why this is not cosmetic.
cursor_theme="capitaine-cursors"

# The cursor theme itself, and it is the ONLY thing that decides what the
# pointer looks like on this machine.
#
# This took an embarrassingly long time to find, so the reasoning is worth
# keeping. `hyprctl setcursor` appears to work here -- it returns "ok", it
# accepts any name at all, including names that do not exist -- and it
# changes NOTHING. Proved by capturing the composited pointer with `grim -c`
# and diffing it against a capture without the pointer: three completely
# different themes (solid, rounded, bordered) produced byte-identical
# silhouettes. `hyprctl getcursor` does not exist on this build either, and
# `hl.config({cursor = {theme = ...}})` refuses with "unknown config key",
# while `hl.config({cursor = {no_hardware_cursors = ...}})` is accepted -- so
# the cursor section exists in the schema with the theme keys missing from it.
#
# What does work is XCURSOR_THEME. It is set in three places that all have to
# agree, which is why it is written here as well as in hyprland/env.lua:
# environment.d for systemd-launched units, and the compositor env for
# everything Hyprland starts itself.
#
# Bibata in the borderless variants, so the pointer has no keyline unless it
# needs one -- cursor-adapt.py adds the rim back only when the pointer is over
# something close to its own colour. White on dark, black on light.
if [[ "$mode" == "light" ]]; then
    cursor_theme="Bibata-Modern-Classic-NoLine"
else
    cursor_theme="Bibata-Modern-Ice-NoLine"
fi

# Already in this mode? Then there is nothing to do, and saying so lets this
# run unattended on every login and every compositor config reload without
# touching dconf (which would emit a change signal) or rewriting files whose
# mtime other things watch. Everything below is idempotent, but "idempotent"
# is not the same as "free": the gsettings write alone is a dbus round trip.
#
# The Qt platform theme is part of the check, not just the mode: it is
# mode-independent, so a check that only looked at the mode would report
# "already in sync" forever and never repair a wrong value left behind by an
# older version of this script. That is exactly what happened to the
# environment.d file when the value moved from gtk3 to xdgdesktopportal.
if [[ "$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null | tr -d "'")" == "$prefer" ]] \
   && [[ "$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null | tr -d "'")" == "Default" ]] \
   && grep -qsE "^gtk-application-prefer-dark-theme=$dark_flag\$" "$HOME/.config/gtk-3.0/settings.ini" \
   && grep -qsE "^gtk-application-prefer-dark-theme=$dark_flag\$" "$HOME/.config/gtk-4.0/settings.ini" \
   && grep -qsE "^QT_QPA_PLATFORMTHEME=$qt_theme\$" "$HOME/.config/environment.d/90-desktop-theme.conf" \
   && grep -qsE "^XCURSOR_THEME=$cursor_theme\$" "$HOME/.config/environment.d/90-desktop-theme.conf"; then
    echo "desktop theme -> $mode (already in sync, nothing to do)"
    exit 0
fi

# 1. The modern key: libadwaita / GTK4 / anything that asks the system.
gsettings set org.gnome.desktop.interface color-scheme "$prefer" 2>/dev/null || true

# 2. Point gtk-theme at a theme that EXISTS. `adw-gtk3` is not installed, and
#    a missing theme is not an error GTK reports -- it just falls back, which
#    is why this went unnoticed. `Default` is present on this machine.
gsettings set org.gnome.desktop.interface gtk-theme "Default" 2>/dev/null || true

# 3. The flag that actually darkens GTK3, and that GTK4 honours as well.
#    Written to BOTH settings.ini files, managed: only the one key is
#    rewritten, so any other GTK setting in those files survives.
write_gtk_preference() {
    local ini="$1"
    local dir; dir="$(dirname "$ini")"
    mkdir -p "$dir"
    if [[ ! -f "$ini" ]]; then
        printf '[Settings]\ngtk-application-prefer-dark-theme=%s\n' "$dark_flag" > "$ini"
        return
    fi
    if grep -qE '^gtk-application-prefer-dark-theme=' "$ini"; then
        # BSD sed (the in-place form takes no suffix), because this is the
        # sed that ships on this machine.
        sed -i'' "s/^gtk-application-prefer-dark-theme=.*/gtk-application-prefer-dark-theme=$dark_flag/" "$ini"
    else
        printf '\n[Settings]\ngtk-application-prefer-dark-theme=%s\n' "$dark_flag" >> "$ini"
    fi
}
write_gtk_preference "$HOME/.config/gtk-3.0/settings.ini"
write_gtk_preference "$HOME/.config/gtk-4.0/settings.ini"

# 4. Qt has no preference key of its own here, but it does have a platform
#    theme plugin that reads the GTK settings. This only reaches apps started
#    from now on, which is inherent to any environment variable and is the
#    same trade the cursor theme already makes in applyHyprlandTheme.
#
#    The compositor ALSO sets this for everything it spawns
#    (hyprland/env.lua), which is the half that matters for "the app I opened
#    during login": Hyprland's environment is what an app launched from a
#    keybind or an autostart inherits, and it did not used to agree with the
#    value written here.
mkdir -p "$HOME/.config/environment.d"
cat > "$HOME/.config/environment.d/90-desktop-theme.conf" <<EOF
# Written by the shell's theme toggle (scripts/colors/sync-desktop-theme.sh).
# Makes Qt applications follow the desktop color-scheme, so one light/dark
# decision covers every toolkit on the desktop instead of three drifting
# apart. xdgdesktopportal is the platform theme that actually reports dark on
# this machine; gtk3 does not (see the comment at the top of the script).
QT_QPA_PLATFORMTHEME=$qt_theme
# Qt renders no cursor of its own on Wayland; it asks the compositor for a
# shape and needs a loaded theme to resolve that shape to a name. Without
# this, every cursorShape in every Qt app falls back to the default arrow.
XCURSOR_THEME=$cursor_theme
EOF

echo "desktop theme -> $mode (color-scheme=$prefer, gtk prefer-dark=$dark_flag, QT_QPA_PLATFORMTHEME=$qt_theme, XCURSOR_THEME=$cursor_theme)"
