#!/usr/bin/env bash
# x11-dpi.sh -- tell X11 apps how large to draw themselves.
#
# The problem this closes. custom/general.lua sets
# xwayland:force_zero_scaling = true, so X11 apps draw 1:1 into the panel's
# 2560x1600 pixels instead of being upscaled (that upscale is what made every
# X11 app pixelated -- 1px glyph stems arriving 2px, separators wobbling
# between 1px and 2px; measured, see the comment in custom/general.lua). 1:1
# on a ~198 DPI panel means an X11 app's default "96 DPI" UI is drawn at
# roughly two-thirds size next to the 1.5x Wayland desktop -- the exact
# complaint that got force_zero_scaling switched off before.
#
# Xft.dpi is the instruction that fixes it, and it is the RIGHT lever because
# it is X11-only: X11 GTK, Qt, Firefox, Thunderbird and JetBrains all read it
# from the X resource database at startup, while Wayland clients -- which
# already get 1.5 from the compositor -- never look at it. So there is no way
# for this to double-scale a Wayland app, which is exactly why the global
# toolkit variables (GDK_SCALE, QT_SCALE_FACTOR) are not used here.
#
# xrdb is NOT installed on this machine. It is not needed: xrdb's whole job
# for this one value is to set the RESOURCE_MANAGER property on the root
# window, and xprop does that directly. Verified on this box -- a GTK3 window
# on :1 reported resolution 96.0 before the property was set and 144.0 after,
# and a Qt window on :1 reported devicePixelRatio 1.5 (not the integer 2 it
# rounds to when it has to guess).
#
# The value follows ~/.cache/display/scale -- the same file the compositor
# scale is read from in custom/general.lua -- so one scale change moves both
# halves together. 96 * scale is the definition of the scale factor, so
# 1.5 -> 144, 2.0 -> 192.
#
# Called from custom/execs.lua (every config parse, i.e. login and reload) and
# from apply-display.sh right after it writes a new scale.
set -u

# ── 0. Wait mode: XWayland is not necessarily up yet ───────────────────────
# This script is run from custom/execs.lua while the config is being parsed,
# which on this desk is seconds after login -- and there may be no X server at
# all yet, because XWayland is started on demand in some session shapes. The
# original behaviour was to print "no X server found, nothing to set" and give
# up, which is how EVERY X11 app in the session came up drawing at 96 DPI
# while the Wayland side was at 1.5x: measured after one such login, the root
# window had no RESOURCE_MANAGER at all (`xprop -root RESOURCE_MANAGER` -> not
# found), and running this script by hand fixed it in one go. That is the
# "apps open at the wrong scale and I have to fix them by hand" report.
#
# So the no-server branch below leaves this mode running instead: it waits for
# a server, applies the DPI the moment one answers, and exits as soon as the
# property is really readable on it -- not merely as soon as it tried.
if [ "${1:-}" = "--wait" ]; then
    for _ in $(seq 1 120); do          # up to ten minutes
        sleep 5
        # X11_DPI_RETRY stops the child from leaving a second waiter behind.
        X11_DPI_RETRY=1 "$0" >/dev/null 2>&1
        for sock in /tmp/.X11-unix/X*; do
            [ -S "$sock" ] || continue
            if DISPLAY=":${sock##*/X}" xprop -root RESOURCE_MANAGER 2>/dev/null \
                    | grep -q "Xft.dpi"; then
                exit 0
            fi
        done
    done
    exit 1
fi

SCALE_FILE="$HOME/.cache/display/scale"
FALLBACK_SCALE=1.5

# ── 1. The scale, normalised ───────────────────────────────────────────────
# Refuse anything that is not a plausible scale, in the same spirit as
# custom/general.lua's ALLOWED_SCALES: a bogus DPI is a worse failure than the
# default one, because it pushes every X11 app to the wrong size instead of
# merely leaving it where it was.
scale="$(head -1 "$SCALE_FILE" 2>/dev/null)"
scale="$(awk -v v="${scale:-}" \
    'BEGIN { print (v ~ /^[0-9]+(\.[0-9]+)?$/ && v >= 1 && v <= 2.5) ? v : "0" }')"
if [ "$scale" = "0" ]; then
    scale="$FALLBACK_SCALE"
fi

# 96 * scale, rounded to the nearest integer (144 at 1.5, 192 at 2.0).
DPI="$(awk -v s="$scale" 'BEGIN { printf "%d", 96 * s + 0.5 }')"
if [ -z "$DPI" ] || [ "$DPI" -lt 96 ]; then
    scale="$FALLBACK_SCALE"
    DPI=144
fi

# ── 2. Find the X server ───────────────────────────────────────────────────
# XWayland may not exist yet when the config is first parsed at login, and it
# also disappears briefly if it is restarted, so wait for it rather than
# failing. Candidates: whatever DISPLAY says, then the usual :N sockets.
candidates=()
[ -n "${DISPLAY:-}" ] && candidates+=("$DISPLAY")
for sock in /tmp/.X11-unix/X*; do
    [ -S "$sock" ] || continue
    candidates+=(":${sock##*/X}")
done
if [ "${#candidates[@]}" -eq 0 ]; then
    candidates=(":0" ":1")
fi

xdisp=""
for _ in $(seq 1 40); do          # up to ~20s
    for d in "${candidates[@]}"; do
        if DISPLAY="$d" timeout 2 xprop -root -len 1 >/dev/null 2>&1; then
            xdisp="$d"
            break
        fi
    done
    [ -n "$xdisp" ] && break
    sleep 0.5
done

if [ -z "$xdisp" ]; then
    # No X server yet. Not an error -- a session with no X11 apps never needs a
    # DPI -- so it must not look like a failure in the login logs, but it must
    # not be the end of the story either: leave the waiter from section 0
    # behind so the DPI lands whenever XWayland actually appears, instead of
    # leaving the whole session's X11 apps at 96 DPI (see the header there).
    echo "x11-dpi: no X server found yet, nothing to set (waiting in the background)"
    if [ -z "${X11_DPI_RETRY:-}" ]; then
        setsid "$0" --wait >/dev/null 2>&1 &
    fi
    exit 0
fi

# ── 3. Set it ──────────────────────────────────────────────────────────────
# xprop writes the property the way xrdb would: format 8, type STRING, with
# the value being one or more "Xft.dpi: <n>" lines. No comparison against the
# current value first: xprop escapes the tab in its readable output, so a
# string compare against what we wrote would never match and would just make
# this report a change on every run. Setting an identical property is free.
# ── The pointer, for X11 clients (added 2026-10-20) ────────────────────────
#
# Xft.dpi is not the only thing an X11 app reads from this property. Its
# POINTER comes from here too: X11 apps resolve their cursors through
# XCURSOR_THEME, or through the Xcursor.theme/size resources when that variable
# is unset. Hyprland's own `hl.env("XCURSOR_THEME", ...)` in
# hyprland/env.lua only reaches processes Hyprland itself spawns -- an X11 app
# started from the shell or from a launcher inherits nothing, falls back to the
# stock X cursor, and the pointer visibly changes shape and artwork the moment
# it crosses into that window ("the cursor is being overwritten inside the
# app"). The desktop's pointer is Bibata in the mode's colourway
# (custom/theme.lua), so state the same thing to X11.
# One name, always. This used to follow the light/dark mode file and hand X11 a
# white pointer on dark and a black one on light; X11 clients read it once, so
# the effect was that the pointer changed artwork the moment it crossed into an
# X11 window ("the cursor is being overwritten inside the app"). It is the SAME
# name hyprland/env.lua gives XCURSOR_THEME -- that is the whole point.
CURSOR_THEME=Bibata-Modern-Ice
# Same number as custom/theme.lua's M.CURSOR_SIZE: a native 24px bitmap in that
# theme, so nothing is resampled.
CURSOR_SIZE=24

WANT="$(printf 'Xft.dpi:\t%s\nXcursor.theme:\t%s\nXcursor.size:\t%d\n' \
    "$DPI" "$CURSOR_THEME" "$CURSOR_SIZE")"

if DISPLAY="$xdisp" xprop -root -f RESOURCE_MANAGER 8s \
        -set RESOURCE_MANAGER "$WANT" >/dev/null 2>&1; then
    got="$(DISPLAY="$xdisp" xprop -root RESOURCE_MANAGER 2>/dev/null)"
    if printf '%s' "$got" | grep -q "Xft.dpi" && printf '%s' "$got" | grep -q -- "$DPI" \
            && printf '%s' "$got" | grep -q -- "$CURSOR_THEME"; then
        echo "x11-dpi: Xft.dpi=$DPI on $xdisp (scale=$scale), cursor=$CURSOR_THEME $CURSOR_SIZE"
        exit 0
    fi
    echo "x11-dpi: set, but could not read Xft.dpi back: $got" >&2
    exit 1
fi

echo "x11-dpi: FAILED to set Xft.dpi on $xdisp" >&2
exit 1
