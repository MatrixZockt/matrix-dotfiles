#!/usr/bin/env bash
# Print the absolute path of the picture the LOGIN SCREEN is showing.
#
# The lock screen (SUPER+L) draws the login screen's background so the two are
# the same screen: same picture, same crop, same scrim. The picture belongs to
# the SDDM theme, not to the shell, so it is resolved the way SDDM itself
# resolves it rather than hardcoded --
#
#   1. which theme is the greeter using? SDDM reads /etc/sddm.conf, then
#      /etc/sddm.conf.d/*.conf in order, then the user's own file, and the
#      LAST `Current=` wins (that is how 10-ii-theme.conf beats the default);
#   2. that theme's directory, and the file its [General] background= names;
#   3. the shipped `ii` theme as the fallback, so a missing or renamed theme
#      degrades to the desktop's own login picture instead of to no picture.
#
# One line of output, or nothing at all (exit 1) when there is genuinely no
# picture to be had -- the caller treats that as "keep the old flat scrim".
set -u

# ── 1. the theme ────────────────────────────────────────────────────────────
theme=""
for conf in /etc/sddm.conf /etc/sddm.conf.d/*.conf "$HOME/.config/sddm.conf"; do
    [ -r "$conf" ] || continue
    found=$(sed -n 's/^[[:space:]]*[Cc]urrent[[:space:]]*=[[:space:]]*//p' "$conf" | tail -1)
    if [ -n "$found" ]; then
        theme="$found"
    fi
done

# ── 2. that theme's picture ─────────────────────────────────────────────────
# The two roots SDDM itself searches, system first. `bg` is whatever the theme
# says, defaulting to the name SDDM's own theme.conf API defaults to.
for dir in "/usr/share/sddm/themes/$theme" "$HOME/.local/share/sddm/themes/$theme"; do
    [ -d "$dir" ] || continue
    bg=$(sed -n 's/^[[:space:]]*background[[:space:]]*=[[:space:]]*//p' "$dir/theme.conf" 2>/dev/null | tail -1)
    [ -n "$bg" ] || bg="background.png"
    if [ -f "$dir/$bg" ]; then
        printf '%s\n' "$dir/$bg"
        exit 0
    fi
done

# ── 3. the shipped ii theme ─────────────────────────────────────────────────
for dir in /usr/share/sddm/themes/ii "$HOME/.local/share/sddm/themes/ii"; do
    if [ -f "$dir/background.png" ]; then
        printf '%s\n' "$dir/background.png"
        exit 0
    fi
done

exit 1
