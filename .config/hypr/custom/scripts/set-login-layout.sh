#!/usr/bin/env bash
# Choose the login screen's layout.
#
# The login screen is SDDM with this desktop's own theme (sources in
# ~/.config/hypr/custom/sddm-theme, installed by install-sddm-theme.sh). The
# layout of that theme -- what sits where -- is one of the fragments in
# layouts/*.js: the theme's Main.qml includes the active one and reads three
# variables from it.
#
# Layout switching needs no root because the fragments are STAGED user-side
# and only read by the theme at install time; the installed copy is refreshed
# by install-sddm-theme.sh (which needs root, and is what the Settings page's
# "Reinstall" button runs via pkexec). Until it is re-installed, the login
# screen keeps the previously installed layout.
#
#   set-login-layout.sh             ... print the current layout
#   set-login-layout.sh list        ... list the available layouts
#   set-login-layout.sh <layout>    ... switch layout
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
THEME_DIR="$CONFIG_DIR/hypr/custom/sddm-theme"
LAYOUT_DIR="$THEME_DIR/layouts"
ACTIVE="$LAYOUT_DIR/active.js"
default_layout="classic"

usage() {
    echo "usage: $(basename "$0") [list | <layout>]" >&2
    exit 2
}

available_layouts() {
    find "$LAYOUT_DIR" -maxdepth 1 -name '*.js' ! -name 'active.js' -printf '%f\n' 2>/dev/null \
        | sed 's/\.js$//' | sort
}

validate_layout() {
    local name="$1"
    [[ -f "$LAYOUT_DIR/$name.js" ]] || {
        echo "Unknown layout: $name" >&2
        echo "Available: $(available_layouts | tr '\n' ' ')" >&2
        exit 1
    }
}

# Each fragment carries its name as a comment on the first line:
#     // login-layout: <name>
layout_name() {
    sed -n "s|^// login-layout:[[:space:]]*||p" "$1" | head -n 1
}

case "${1:-}" in
    "")
        if [[ -f "$ACTIVE" ]]; then
            layout_name "$ACTIVE"
        else
            echo "$default_layout"
        fi
        ;;
    "list")
        available_layouts
        ;;    *)
        validate_layout "$1"
        {
            echo "// login-layout: $1"
            echo "// COMPOSED FILE -- written by scripts/set-login-layout.sh, included by"
            echo "// the SDDM theme's Main.qml. Change the layout with:"
            echo "//   set-login-layout.sh <$(available_layouts | tr '\n' '|' | sed 's/|$//')>"
            cat "$LAYOUT_DIR/$1.js" | grep -v '^// login-layout:'
        } > "$ACTIVE"
        # The composed fragment also carries the active slug so the theme's
        # HUD switcher (arrows / dots) can include the others by name.
        echo "var activeLayout = \"$1\"" >> "$ACTIVE"
        echo "Login screen layout: $1"
        ;;
esac
