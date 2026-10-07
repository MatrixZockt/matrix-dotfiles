#!/usr/bin/env bash
#
# Installs the "II Hyprland" login theme and makes the login screen use it.
#
# What this replaces: the boot/login screen was the stock CachyOS SDDM theme --
# a stock photo and a bare form -- while the desktop is this shell. The theme
# staged next to this script is the lock screen (SUPER + L) redrawn on SDDM's
# own QML components, so the login logic itself is untouched and only the
# picture changes.
#
# The wallpaper and the palette are NOT hard-coded in the theme. Every run of
# this script reads them out of the desktop's own state:
#
#   wallpaper  ~/.config/illogical-impulse/config.json  (background.wallpaperPath)
#   colours    ~/.local/state/quickshell/user/generated/colors.json
#
# and bakes them into the installed theme.conf, so the login screen follows the
# wallpaper and accent you actually use. Change your wallpaper or theme and run
# this again to bring the login screen with you.
#
# Run as:  sudo bash ~/.config/hypr/custom/scripts/install-sddm-theme.sh
#
# To go back to the previous login screen:
#     sudo rm /etc/sddm.conf.d/10-ii-theme.conf
#     sudo rm -r /usr/share/sddm/themes/ii
# (SDDM then falls back to its default theme, exactly as before.)
#
# It touches nothing else: no session config, no autologin, no user settings.
set -euo pipefail

# Home of the invoking user, resolved through `sudo` too (SUDO_USER), so this
# works no matter whose checkout it runs from.
USER_HOME="$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)"
SRC="$USER_HOME/.config/hypr/custom/sddm-theme"
DST=/usr/share/sddm/themes/ii

if [ ! -f "$SRC/Main.qml" ]; then
    echo "Theme sources are missing at $SRC" >&2
    exit 1
fi

install -d "$DST"
install -m 644 \
    "$SRC/Main.qml" \
    "$SRC/metadata.desktop" \
    "$SRC/angle-down.png" \
    "$DST"/

# The layout fragments: the composed active.js is what the theme reads at
# startup (choose it with set-login-layout.sh). A theme installed without it
# still works -- Main.qml falls back to the shipped arrangement.
if [ -f "$SRC/layouts/active.js" ]; then
    install -d "$DST/layouts"
    install -m 644 "$SRC/layouts/active.js" "$DST/layouts/"
    # Every fragment goes along too: the ops HUD's arrow / dot switcher
    # includes them by name at run time, so the login can change arrangement
    # live without another install.
    for frag in "$SRC"/layouts/*.js; do
        [ "$(basename "$frag")" = "active.js" ] && continue
        install -m 644 "$frag" "$DST/layouts/"
    done
fi

# ---- palette + wallpaper, read from the live desktop ------------------------
# Python does the JSON reading (small, exact); if it is missing or the shell has
# never generated a palette, the staged theme.conf is used instead, which
# carries the same values.
PALETTE=$(python3 - "$USER_HOME" <<'PY'
import json, os, sys
home = sys.argv[1]
keys = {"surface": "surface", "surface_container": "surfaceContainer",
        "on_surface": "onSurface", "on_surface_variant": "onSurfaceVariant",
        "primary": "primary", "on_primary": "onPrimary",
        "outline": "outline", "error": "error"}
try:
    colors = json.load(open(os.path.join(
        home, ".local/state/quickshell/user/generated/colors.json")))
except Exception:
    colors = {}
print("\n".join("%s=%s" % (v, colors[k]) for k, v in keys.items() if colors.get(k)))
PY
)

WALLPAPER=$(python3 - "$USER_HOME" <<'PY'
import json, os, sys
home = sys.argv[1]
try:
    bg = json.load(open(os.path.join(
        home, ".config/illogical-impulse/config.json"))).get("background", {})
except Exception:
    bg = {}
wall = (bg.get("wallpaperPathLogin") or "")
if not wall:
    wall = (bg.get("wallpaperPathDark") or "") if bg.get("separateThemeWallpaper") else ""
print(wall or bg.get("wallpaperPath") or "")
PY
)

{
    echo "[General]"
    echo "background=background.png"
    echo "host=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo localhost)"
    # Kernel for the "sheet" layout's telemetry. Baked here for the same
    # reason as host=: a greeter cannot read it for itself. It was briefly a
    # live Process{ cat /proc/version } in Main.qml, but this QtQml build does
    # not export Process, and a greeter that blocks on a subprocess is the
    # exact freeze this theme must not have.
    echo "kernel=$(uname -r 2>/dev/null || echo linux)"
    # The staged layout fragment, flattened into theme.conf.
    #
    # The theme used to read layouts/active.js at RUNTIME with Qt.include(),
    # which cannot work: Qt.include may only be called from a .js file, so
    # every call from Main.qml threw
    #     Error: Qt.include(): Can only be called from JavaScript files
    # and was swallowed by the try/catch around it. All eight layouts
    # therefore rendered as the shipped "classic" arrangement, and
    # set-login-layout.sh had no effect on the greeter at all. Reading the
    # fragment with XMLHttpRequest is no better -- QML blocks GET on local
    # files unless QML_XHR_ALLOW_FILE_READ is set, which a greeter does not
    # set. Flattening the fragment here sidesteps all of it: the values
    # arrive through `config`, the one channel a greeter genuinely supports.
    if [ -f "$SRC/layouts/active.js" ]; then
        # Only `var name = value` lines, one per key. Comments and the
        # composed header are ignored, so the fragment stays free to be
        # commented for a human reader.
        sed -n 's/^var[[:space:]]\{1,\}\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=[[:space:]]*\(.*\)$/layout_\1=\2/p' \
            "$SRC/layouts/active.js" \
            | sed -e 's/;[[:space:]]*$//' -e 's/^\(layout_[A-Za-z0-9_]*\)="\(.*\)"[[:space:]]*$/\1=\2/'
    fi
    if [ -n "$PALETTE" ]; then
        echo "$PALETTE"
        # The staged theme.conf carries its own layout keys too; without this
        # the palette branch would drop them and the layout would silently
        # revert to "classic" on any machine where the shell has generated a
        # palette -- which is every machine after first boot.
        sed -n 's/^\(layout_[A-Za-z0-9_]*\)=/\1=/p' "$SRC/theme.conf"
    else
        # No live palette to read: keep the staged defaults.
        grep -v '^\[' "$SRC/theme.conf"
    fi
} > "$DST/theme.conf"

if [ -n "$WALLPAPER" ] && [ -f "$WALLPAPER" ]; then
    install -m 644 "$WALLPAPER" "$DST/background.png"
    echo "Wallpaper: $WALLPAPER"
else
    echo "Wallpaper: could not be read, keeping the staged background.png" >&2
    install -m 644 "$SRC/background.png" "$DST/background.png"
fi

install -d /etc/sddm.conf.d
cat > /etc/sddm.conf.d/10-ii-theme.conf <<'EOF'
[Theme]
# Login screen matching the illogical-impulse desktop: the lock screen's own
# layout, on the wallpaper and accent in use. Source: ~/.config/hypr/custom/sddm-theme
# Revert with: sudo rm /etc/sddm.conf.d/10-ii-theme.conf
Current=ii
EOF

echo "Installed $DST"
echo "Selected Current=ii in /etc/sddm.conf.d/10-ii-theme.conf"
