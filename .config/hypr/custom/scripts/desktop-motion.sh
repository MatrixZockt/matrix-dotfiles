#!/usr/bin/env bash
# desktop-motion.sh -- keep every toolkit on "animations are on".
#
# WHY THIS EXISTS. An Electron app does not read a motion setting of its own:
# Chromium derives `prefers-reduced-motion` from the desktop's GTK settings
# (`gtk-enable-animations`), which in turn follows
# `org.gnome.desktop.interface enable-animations`. Claude Desktop's animated
# theme backdrops honour that media query, and a scene told "reduce motion"
# does not stop animating -- it renders one composed still frame on purpose.
# That reads as "the theme is not animated", which is the report this file
# answers (2026-11-14).
#
# On this desktop nothing intentionally turns motion off: the shell's own
# "Reduce motion" switch is the Performance power mode, which touches the
# platform profile and the shell's motion scale only (custom/PowerMode.qml),
# and Hyprland's animations are configuration rather than a mode. So the
# switches here are pinned to "on" rather than toggled: a login that inherits a
# stray `false` from a GTK/GNOME tool, a settings.ini written by some installer,
# or a session started before this file existed still comes up animated.
#
# Safe to run on every config load: it writes only when a value is wrong, so a
# reload is a no-op and cannot fight the user's own settings.
set -u

changed=0

# 1. gsettings: what GTK (and therefore Chromium) reads first when a session is
#    alive. Reading it back costs one call and keeps this a no-op when correct.
if command -v gsettings >/dev/null 2>&1; then
    current="$(gsettings get org.gnome.desktop.interface enable-animations 2>/dev/null || true)"
    if [ "$current" != "true" ]; then
        if gsettings set org.gnome.desktop.interface enable-animations true 2>/dev/null; then
            changed=1
        fi
    fi
fi

# 2. settings.ini, for both GTK 3 and GTK 4. GTK reads this file before it has
#    a settings daemon to ask, which is the state a session is in for the first
#    seconds after login -- and that is exactly when the desktop app starts and
#    decides whether to animate. The key goes under [Settings]; a file without
#    that section gets one, and an existing line is rewritten in place so the
#    file keeps every other key and comment the user put there.
pin_ini() {
    local file="$1"
    [ -e "$file" ] || return 0
    if grep -qE '^[[:space:]]*gtk-enable-animations[[:space:]]*=' "$file"; then
        grep -qE '^[[:space:]]*gtk-enable-animations[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$file" && return 0
        sed -i -E 's/^[[:space:]]*gtk-enable-animations[[:space:]]*=.*/gtk-enable-animations=true/' "$file"
        changed=1
    elif grep -qE '^\[Settings\]' "$file"; then
        sed -i '/^\[Settings\]/a gtk-enable-animations=true' "$file"
        changed=1
    else
        printf '[Settings]\ngtk-enable-animations=true\n' >>"$file"
        changed=1
    fi
}

pin_ini "$HOME/.config/gtk-3.0/settings.ini"
pin_ini "$HOME/.config/gtk-4.0/settings.ini"

# A record, so "is motion actually on?" is answerable from the log instead of
# from a guess. Silence when nothing needed changing keeps reloads quiet.
if [ "$changed" -eq 1 ]; then
    echo "desktop-motion: animations pinned on (gsettings and/or settings.ini)"
fi

exit 0
