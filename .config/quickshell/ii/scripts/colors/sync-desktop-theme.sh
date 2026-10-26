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
#   1. GTK3 apps ignore `color-scheme` entirely. They read `gtk-theme`, and
#      what decides there is the NAME: it used to hold `Default`, which on
#      this machine is a stub (one gtk-keys.css, no gtk.css at all), so GTK3
#      fell back to its built-in LIGHT Adwaita and every GTK3 window stayed
#      white on a dark desktop whatever the shell said. `Default` was chosen
#      because it was "a theme that exists" -- it is, and it is exactly the
#      wrong one. See the block above step 2 for the measurements that say
#      which names do work.
#   2. `gtk-application-prefer-dark-theme` is a startup hint, not a lever. It
#      cannot darken a theme that has no dark stylesheet, and a RUNNING app
#      never notices it change. It is still written, to both settings.ini
#      files, because it is what an app launched later reads -- but the
#      light/dark decision that a person actually watches happen travels in
#      `gtk-theme`, which GTK re-reads live.
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
# So the desktop theme is not one key, it is five, and only writing one of
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
# ONE name, never swapped. It used to be a dark/light pair, which meant the
# pointer could be white in one place and black in another -- and the desktop's
# own compositor, its Qt clients and its X11 clients each read it at a different
# moment, so the artwork changed under the hand. Stability is the feature here.
cursor_theme="Bibata-Modern-Ice"

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
# Stock Bibata-Modern-Ice -- white body, black rim -- which is the one name that
# is actually installed here. It does not follow the mode any more (see the note
# on cursor_theme above) -- the pointer that was there when the session started
# is the pointer for the whole session.
#
# The `-NoLine` variants this used to name are not installed (checked
# 2026-10-23: ~/.local/share/icons holds only Modern/Original Classic and Ice),
# so every toolkit that read that name silently fell back to the default X
# cursor -- a DARK arrow -- while the ones that read env.lua's `Bibata-Modern-Ice`
# drew the white one. That is why the pointer changed colour at a window edge.

# ── The GTK theme, and the two names it has to have ────────────────────────
#
# WHY THE MODE TRAVELS IN THE THEME NAME. Measured on this machine
# (2026-10-15) with a GTK3 window that reports its own resolved background
# colour, over every combination of the two levers:
#
#   prefer-dark  gtk-theme     GTK3 window        GTK4 text
#   1            Default       #f6f5f4  light  <- the bug, in dark mode
#   1            Adwaita       #353535  dark       #eeeeec  dark
#   0            Adwaita       #f6f5f4  light      #2e3436  light
#   0            Adwaita-dark  #353535  dark       #2e3436  light
#
#   * `Adwaita` is the name GTK3's own stylesheets are built in under -- both
#     the light one and a 171 KB dark one that lives inside libgtk-3. The
#     dark variant is only reachable through a theme NAME: with the flag set
#     and the name `Default` the window stayed #f6f5f4, because there was no
#     gtk-dark.css to load. That is the whole of the "apps do not switch"
#     report: the flag was right, the name it applied to was not.
#   * a RUNNING application only follows the NAME. GTK3 reads settings.ini
#     once, at startup: the probe still reported prefer-dark=True minutes
#     after the file was rewritten to 0, with the window unchanged. Changing
#     `gtk-theme` in dconf repainted that same running window within a second,
#     in both directions. So the switch a person watches happen comes from
#     this key, and the flag is written beside it to agree.
#
# AND WHY THE NAME HAS TO SETTLE THE MODE ON ITS OWN. `Adwaita` does not: it
# has both variants built in and picks between them BY THE FLAG, and the flag a
# running app holds is the one it read at startup. So dark -> light left every
# open GTK3 window dark -- the name went back to `Adwaita`, the app's stale
# flag said dark, and `Adwaita` obliged. That is a switch that only works in
# one direction, which is not a switch. Both names below therefore have to be
# unambiguous:
#
#   name           prefer-dark  GTK3 window
#   Adwaita-light  1            #f6f5f4  light
#   Adwaita-light  0            #f6f5f4  light
#   Adwaita-dark   1            #353535  dark
#   Adwaita-dark   0            #353535  dark
#
# Four real readings, taken after writing the flag in the other direction
# first: the MODE is a property of the name, and no stale flag can override it.
# `Adwaita-light` and `Adwaita-dark` are not themes GTK ships -- they are built
# below out of GTK3's own two stylesheets (gtk-contained.css and its dark
# twin), one import each, in BOTH files GTK might load. A `gtk-dark.css` that
# is light looks perverse, and it is the point: whichever of the two files a
# stale flag causes GTK to load, it gets the stylesheet this name promises.
#
# The same has to be done for GTK4, and for the same reason -- measured the
# same way, with a running GTK4 window shifted under a stale flag:
#
#   gtk-theme     the running GTK4 window went
#   Adwaita-dark  light  ->  dark        it follows this NAME live
#   Adwaita-light dark   ->  dark        it does NOT: a plain `-light` name
#                                        carries no dark/light demand, so the
#                                        stale flag decided -- the same
#                                        one-way switch, one toolkit over
#
# GTK4 has no dark/light stylesheets BUILT IN under a name of its own either:
# its three theme stubs (gtk.css, gtk-light.css, gtk-dark.css in
# /org/gtk/libgtk/theme/Default) are the same file, each a
# prefers-color-scheme media query over Default-light.css and Default-dark.css.
# So GTK4 is given its own two directories below, importing those two
# stylesheets directly, media query and all omitted: the name says the mode and
# the CSS agrees with the name. Measured after that change: dark -> light moved
# a running GTK4 window to #2e3436 with its stale flag still at True, and back
# to #eeeeec with its stale flag still at False.
#
# libadwaita apps need none of this -- they follow `color-scheme` (step 1).
gtk_theme_light="Adwaita-light"
gtk_theme_dark="Adwaita-dark"
# The stylesheets those two names publish: GTK3's, out of libgtk-3, and GTK4's,
# out of libgtk-4 -- both under the Adwaita/Default resource names those
# libraries themselves use.
gtk3_stylesheet_light="Adwaita/gtk-contained.css"
gtk3_stylesheet_dark="Adwaita/gtk-contained-dark.css"
gtk4_stylesheet_light="Default/Default-light.css"
gtk4_stylesheet_dark="Default/Default-dark.css"
if [[ "$mode" == "light" ]]; then
    gtk_theme="$gtk_theme_light"
else
    gtk_theme="$gtk_theme_dark"
fi

# Publish GTK's own stylesheets -- GTK3's out of libgtk-3, GTK4's out of
# libgtk-4 -- as two unambiguous theme names, by IMPORTING them by resource
# path. An import rather than a copy, deliberately:
# the stylesheet's own `url("assets/...")` references then resolve inside the
# resource where those assets actually live, instead of pointing at a theme
# directory that contains no assets (and copying 171 KB of GTK's CSS into the
# user's home is a worse thing to own besides).
themes_dir="$HOME/.local/share/themes"
ensure_gtk_theme() {
    local name="$1" gtk3_stylesheet="$2" gtk4_stylesheet="$3"
    local dir="$themes_dir/$name"
    local toolkit css_dir import_line file
    for toolkit in 3 4; do
        local stylesheet
        if [[ "$toolkit" == 3 ]]; then stylesheet="$gtk3_stylesheet"; else stylesheet="$gtk4_stylesheet"; fi
        css_dir="$dir/gtk-$toolkit.0"
        import_line="@import url(\"resource:///org/gtk/libgtk/theme/$stylesheet\");"
        mkdir -p "$css_dir"
        # BOTH files, because which one GTK loads depends on the flag: gtk.css
        # is the theme, gtk-dark.css is its dark variant. The SAME stylesheet
        # in both is what makes this NAME mean one thing, whatever the flag
        # happens to say when it is read -- including a settings.ini written by
        # an older version of this script, which is exactly the stale flag a
        # running app is holding when the mode changes under it.
        for file in gtk.css gtk-dark.css; do
            if [[ ! -f "$css_dir/$file" || "$(cat "$css_dir/$file")" != "$import_line" ]]; then
                printf '%s\n' "$import_line" > "$css_dir/$file"
            fi
        done
    done
    # A well-formed theme directory, for the consumers that read index.theme
    # rather than the CSS (GTK2-era tools, anything enumerating themes).
    if [[ ! -f "$dir/index.theme" || "$(sed -n 's/^Name=//p' "$dir/index.theme")" != "$name" ]]; then
        cat > "$dir/index.theme" <<THEME
[Desktop Entry]
Type=X-GNOME-Metatheme
Name=$name
Comment=GTK's own light or dark stylesheet published as a theme, so a theme NAME can select the mode
Encoding=UTF-8

[X-GNOME-Metatheme]
GtkTheme=$name
THEME
    fi
}
ensure_gtk_theme "$gtk_theme_light" "$gtk3_stylesheet_light" "$gtk4_stylesheet_light"
ensure_gtk_theme "$gtk_theme_dark" "$gtk3_stylesheet_dark" "$gtk4_stylesheet_dark"

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
   && [[ "$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null | tr -d "'")" == "$gtk_theme" ]] \
   && [[ -f "$themes_dir/$gtk_theme_light/gtk-3.0/gtk.css" && -f "$themes_dir/$gtk_theme_light/gtk-4.0/gtk.css" ]] \
   && [[ -f "$themes_dir/$gtk_theme_dark/gtk-3.0/gtk.css" && -f "$themes_dir/$gtk_theme_dark/gtk-4.0/gtk.css" ]] \
   && grep -qsE "^gtk-application-prefer-dark-theme=$dark_flag\$" "$HOME/.config/gtk-3.0/settings.ini" \
   && grep -qsE "^gtk-application-prefer-dark-theme=$dark_flag\$" "$HOME/.config/gtk-4.0/settings.ini" \
   && grep -qsE "^QT_QPA_PLATFORMTHEME=$qt_theme\$" "$HOME/.config/environment.d/90-desktop-theme.conf" \
   && grep -qsE "^XCURSOR_THEME=$cursor_theme\$" "$HOME/.config/environment.d/90-desktop-theme.conf"; then
    echo "desktop theme -> $mode (already in sync, nothing to do)"
    exit 0
fi

# 1. The modern key: libadwaita / GTK4 / anything that asks the system.
gsettings set org.gnome.desktop.interface color-scheme "$prefer" 2>/dev/null || true

# 2. Point gtk-theme at the name for THIS mode. Not "a theme that exists" --
#    a name that IS the mode, because that is the only lever that reaches a
#    running GTK3 window. Both names are directories created above, and each
#    one holds a single stylesheet so that neither the flag nor the direction
#    of travel can change what it means. A name GTK cannot find is not an
#    error it reports -- it falls back silently to light, which is how the old
#    `Default` value went unnoticed for as long as it did.
gsettings set org.gnome.desktop.interface gtk-theme "$gtk_theme" 2>/dev/null || true

# 3. The flag the apps launched from now on will read. It agrees with the
#    theme name above rather than replacing it: written to BOTH settings.ini
#    files, managed, so only the one key is rewritten and any other GTK
#    setting in those files survives.
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

echo "desktop theme -> $mode (color-scheme=$prefer, gtk-theme=$gtk_theme, gtk prefer-dark=$dark_flag, QT_QPA_PLATFORMTHEME=$qt_theme, XCURSOR_THEME=$cursor_theme)"
