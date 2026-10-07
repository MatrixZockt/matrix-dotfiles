#!/bin/bash
# Applies the Freebuff black/graphite theme to the Limine boot menu.
#
# This machine boots with Limine 12.x (not GRUB), so the boot menu is themed in
# limine.conf directly. Two assets go onto the ESP next to it -- a wallpaper and
# a bitmap font (Limine has no font fallback; `term_font` takes a raw 256-glyph
# 8x16 file, which is exactly what a Linux console font is behind its header) --
# and then one managed option block is merged into limine.conf.
#
# Idempotent: re-running replaces the managed block instead of appending a
# second copy, so `python3 build-limine-theme.py && sudo bash <this>` is the
# whole edit loop. Revert any time with: sudo bash <this> revert
#
# Usage: sudo bash install-limine-theme.sh [revert]
set -euo pipefail

THEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/theme"
WALLPAPER_SRC="$THEME_DIR/limine-background.png"
FONT_SRC="$THEME_DIR/limine-font.f16"
OPTIONS_SRC="$THEME_DIR/limine-theme.conf"
WALLPAPER_NAME="freebuff-bg.png"
FONT_NAME="freebuff-f16.font"

# ── Locate limine.conf (the ESP is mounted at /boot here; both common layouts
# are handled) ──────────────────────────────────────────────────────────────
CONF=""
for c in /boot/limine/limine.conf /boot/limine.conf /boot/EFI/limine/limine.conf /boot/EFI/LIMINE/limine.conf /boot/EFI/BOOT/limine.conf; do
    [ -f "$c" ] && CONF="$c" && break
done
if [ -z "$CONF" ]; then
    echo "ERROR: limine.conf not found under /boot. Is Limine installed there?" >&2
    exit 1
fi
echo "limine.conf: $CONF"

CONF_DIR="$(dirname "$CONF")"

# ── Revert ──────────────────────────────────────────────────────────────────
if [ "${1:-}" = "revert" ]; then
    BAK="$(ls -t "$CONF".bak-* 2>/dev/null | head -1 || true)"
    if [ -n "$BAK" ]; then
        cp "$BAK" "$CONF"
        echo "reverted $CONF to $BAK"
    else
        echo "no backup found next to $CONF, nothing to revert" >&2
        exit 1
    fi
    exit 0
fi

for f in "$WALLPAPER_SRC" "$FONT_SRC" "$OPTIONS_SRC"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: $f is missing -- run: python3 $(dirname "$THEME_DIR")/build-limine-theme.py" >&2
        exit 1
    fi
done

# ── Backup once per apply ───────────────────────────────────────────────────
BAK="$CONF.bak-$(date +%Y%m%d-%H%M%S)"
cp "$CONF" "$BAK"
echo "backup: $BAK"

# ── Assets onto the ESP. Limine URIs are relative to the ESP root, so the name
# is prefixed with the config's own directory when that directory is not the
# ESP root itself. ──────────────────────────────────────────────────────────
install -m 0644 "$WALLPAPER_SRC" "$CONF_DIR/$WALLPAPER_NAME"
install -m 0644 "$FONT_SRC" "$CONF_DIR/$FONT_NAME"
REL="$WALLPAPER_NAME"
FONT_REL="$FONT_NAME"
if [ "$CONF_DIR" = "/boot/limine" ]; then
    REL="limine/$WALLPAPER_NAME"
    FONT_REL="limine/$FONT_NAME"
fi
echo "wallpaper: $CONF_DIR/$WALLPAPER_NAME"
echo "font:      $CONF_DIR/$FONT_NAME"

# ── Merge: drop every line this theme (and the previous version of it) owns,
# then append the freshly generated block. ──────────────────────────────────
TMP="$(mktemp)"
grep -vE '^[[:space:]]*(wallpaper|wallpaper_style|backdrop|interface_branding|interface_branding_colour|interface_branding_color|interface_help_colour|interface_help_color|interface_help_colour_bright|interface_help_color_bright|term_font|term_font_size|term_font_scale|term_font_spacing|term_background|term_background_bright|term_foreground|term_foreground_bright|term_palette|term_palette_bright):' "$CONF" \
    | grep -vE '^[[:space:]]*#[[:space:]]*─*[[:space:]]*Freebuff (graphite )?theme' > "$TMP" || true
sed -e "s|@REL@|$REL|" -e "s|@FONT@|$FONT_REL|" "$OPTIONS_SRC" >> "$TMP"
# A single trailing newline, nothing else.
printf '\n' >> "$TMP"
cat "$TMP" > "$CONF"
rm -f "$TMP"

echo "applied: wallpaper + font + black/grey palette + branding"
echo "Reboot to see it; preview without rebooting with assets/grub-theme/preview.html."
echo "Revert with: sudo bash $0 revert"
