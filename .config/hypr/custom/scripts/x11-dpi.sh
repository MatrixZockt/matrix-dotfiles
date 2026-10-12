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
    # No X server at all: nothing to do. Not an error -- a session with no
    # X11 apps never needs a DPI -- so it must not look like a failure in the
    # login logs.
    echo "x11-dpi: no X server found, nothing to set"
    exit 0
fi

# ── 3. Set it ──────────────────────────────────────────────────────────────
# xprop writes the property the way xrdb would: format 8, type STRING, with
# the value being one or more "Xft.dpi: <n>" lines. No comparison against the
# current value first: xprop escapes the tab in its readable output, so a
# string compare against what we wrote would never match and would just make
# this report a change on every run. Setting an identical property is free.
WANT="$(printf 'Xft.dpi:\t%s\n' "$DPI")"

if DISPLAY="$xdisp" xprop -root -f RESOURCE_MANAGER 8s \
        -set RESOURCE_MANAGER "$WANT" >/dev/null 2>&1; then
    got="$(DISPLAY="$xdisp" xprop -root RESOURCE_MANAGER 2>/dev/null)"
    if printf '%s' "$got" | grep -q "Xft.dpi" && printf '%s' "$got" | grep -q -- "$DPI"; then
        echo "x11-dpi: Xft.dpi=$DPI on $xdisp (scale=$scale)"
        exit 0
    fi
    echo "x11-dpi: set, but could not read Xft.dpi back: $got" >&2
    exit 1
fi

echo "x11-dpi: FAILED to set Xft.dpi on $xdisp" >&2
exit 1
