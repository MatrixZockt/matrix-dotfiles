#!/usr/bin/env bash
# apply-display.sh -- apply the display scale and render quality, and persist
# both. The single writer of ~/.cache/display/{scale,quality}; called by the
# Razer Command Center app and by the shell's Settings > Display page so both
# front-ends change exactly one thing the same way.
#
#   apply-display.sh --scale 1.5 --quality quality
#   apply-display.sh --quality performance --quiet
#
# SCALE is validated against the list of scales the UI offers (1.0, 1.25, 1.5,
# 1.6, 2.0). Not a coincidence that the list is short: a scale Hyprland will
# not accept means the panel falls back to the base config's scale 1 -- the
# "everything is way smaller" failure -- so anything outside the list is
# refused rather than passed through. QUALITY is one of:
#
#   performance   blur/shadows/dimming off, animations snappy
#   balanced      light blur, small shadows (default)
#   quality       full blur stack, full shadows -- the richest look
#
# Quality lives in ~/.config/hypr/custom/quality.lua, which hyprland.lua
# requires after every other custom file (same pattern as performance.lua), so
# writing the file + `hyprctl reload` is the whole application. Scale is read
# at reload by custom/general.lua from ~/.cache/display/scale; the X11-app
# half (Steam etc.) reads the same file in the fish login env at next login.
#
# --quiet skips the desktop notification (for use during login).

set -u
SCALE_FILE="$HOME/.cache/display/scale"
QUALITY_FILE="$HOME/.cache/display/quality"
QUALITY_LUA="$HOME/.config/hypr/custom/quality.lua"
NOTIFY_QUIET=0
NEW_SCALE=""
NEW_QUALITY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scale) NEW_SCALE="$2"; shift 2 ;;
        --quality) NEW_QUALITY="$2"; shift 2 ;;
        --quiet) NOTIFY_QUIET=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

valid_scale() {
    # One of the scales the UI offers, and nothing else.
    #
    # This used to be a rule rather than a list: accept a float 1.0-3.0 only if
    # it divides BOTH panel dimensions into whole logical pixels, justified as
    # "Hyprland rejects fractional scales that do not divide into whole logical
    # pixels". That is not true of Hyprland -- `scale` is a plain float
    # multiplier -- and this config demonstrates it: custom/env.lua sets
    # `debug.disable_scale_checks = true`, switching off the very check the
    # comment claimed Hyprland enforced. So the rule's only real effect was to
    # make 150% impossible to pick (2560/1.5 = 1706.67), while looking like a
    # safety guard.
    #
    # The allowlist keeps what was genuinely protective. A value that is not
    # one of these must never reach the monitor rule: a rule Hyprland will not
    # accept leaves the panel on the base config's scale 1, which is the
    # "everything tiny" failure this guard exists to prevent. So garbage in is
    # refused -- but 1.5 is not garbage.
    #
    # The integer spellings are here because that is what the Settings page
    # actually sends. DisplayConfig.qml's scaleChoices carry the JS numbers
    # 1.0 and 2.0, and JS has one numeric type: 1.0 stringifies to "1" and 2.0
    # to "2". So clicking 100% or 200% ran `--scale 1` / `--scale 2`, which
    # this list used to refuse -- and execDetached discards the exit code, so
    # the click looked dead while 125/150/160 worked. Matching on a normalised
    # form instead means the guard cares about the VALUE, not how it was
    # spelled.
    local v
    v=$(awk '{ printf "%g", $1 }' <<< "$1" 2>/dev/null) || return 1
    case "$v" in
        1|1.25|1.5|1.6|2) return 0 ;;
        *) return 1 ;;
    esac
}

# The canonical spelling of a scale, as the file and the notification should
# read: 1 stays "1.0" and 2 stays "2.0", matching the UI's labels and the
# ALLOWED_SCALES keys in custom/general.lua. Kept separate from valid_scale so
# the guard stays a predicate and this stays a formatter.
canonical_scale() {
    case "$(awk '{ printf "%g", $1 }' <<< "$1" 2>/dev/null)" in
        1)   printf '1.0\n' ;;
        1.25) printf '1.25\n' ;;
        1.5)  printf '1.5\n' ;;
        1.6)  printf '1.6\n' ;;
        2)    printf '2.0\n' ;;
        *)    printf '%s\n' "$1" ;;
    esac
}

valid_quality() {
    case "$1" in performance|balanced|quality) return 0 ;; *) return 1 ;; esac
}

mkdir -p "$(dirname "$SCALE_FILE")"

if [[ -n "$NEW_SCALE" ]]; then
    if ! valid_scale "$NEW_SCALE"; then
        echo "invalid scale '$NEW_SCALE' (choose one of: 1.0 1.25 1.5 1.6 2.0)" >&2
        exit 1
    fi
    # Write the canonical spelling, not whatever arrived. `--scale 1` from the
    # settings page has to land as "1.0" on disk, because that is what
    # custom/general.lua's ALLOWED_SCALES lookup compares against, and the file
    # is also read by eye.
    NEW_SCALE="$(canonical_scale "$NEW_SCALE")"
    printf '%s\n' "$NEW_SCALE" > "$SCALE_FILE"
fi

if [[ -n "$NEW_QUALITY" ]]; then
    if ! valid_quality "$NEW_QUALITY"; then
        echo "invalid quality '$NEW_QUALITY' (performance|balanced|quality)" >&2
        exit 1
    fi
    printf '%s\n' "$NEW_QUALITY" > "$QUALITY_FILE"
fi

# Nothing asked: report current values and exit (used by front-ends at open).
if [[ -z "$NEW_SCALE" && -z "$NEW_QUALITY" ]]; then
    echo "scale=$(cat "$SCALE_FILE" 2>/dev/null || echo 1.5)"
    echo "quality=$(cat "$QUALITY_FILE" 2>/dev/null || echo balanced)"
    exit 0
fi

changed=()
# Regenerate the quality overlay from the current value, if any quality is
# recorded. (Scale needs no file written -- general.lua reads the value file.)
if [[ -f "$QUALITY_FILE" ]]; then
    q=$(cat "$QUALITY_FILE" 2>/dev/null || echo balanced)
    # NOTE: the animation speed/pop pair used to be emitted here as
    # `animations = { speed = $anims }`. That was wrong twice over, and both
    # halves had to go:
    #
    #   * `anims` was a TWO-VALUE string ("0.8 0.9") substituted into a
    #     single-value field, so the generated file literally contained
    #     `speed = 0.8 0.9,` -- a Lua syntax error. Any run of this script
    #     therefore wrote a custom/quality.lua that Hyprland could not parse,
    #     and because hyprland.lua requires that file, everything loaded after
    #     it (including the theme) was silently dropped.
    #   * `animations.speed` / `animations.pop` are not config keys in
    #     Hyprland 0.56 either -- animation speed is per-leaf now, via
    #     hl.animation({ leaf = ... , speed = ... }), which custom/general.lua
    #     already handles for the leaves it animates. The top-level
    #     animations block only takes `enabled`.
    #
    # So quality now controls blur, shadow and dimming only, and the global
    # animations switch is left at the base config's value. Performance mode
    # owns turning animations off entirely (custom/performance.lua).
    case "$q" in
        performance)
            blur_enabled=false; blur_size=1;   blur_passes=1
            shadow_enabled=false; dim=false
            ;;
        balanced)
            blur_enabled=true;  blur_size=4;   blur_passes=1
            shadow_enabled=true; dim=true
            ;;
        quality)
            blur_enabled=true;  blur_size=8;   blur_passes=2
            shadow_enabled=true; dim=true
            ;;
        *) q=balanced; blur_enabled=true; blur_size=4; blur_passes=1
           shadow_enabled=true; dim=true ;;
    esac
    cat > "$QUALITY_LUA" <<EOF
-- GENERATED by custom/scripts/apply-display.sh -- do not edit by hand.
-- Render quality: "$q" (chosen in the Razer Command Center app or in
-- Settings > Display). Required by hyprland.lua after every other custom
-- file, so these values win over the base config and custom/general.lua.

hl.config({
    decoration = {
        blur = {
            enabled = $blur_enabled,
            size = $blur_size,
            passes = $blur_passes,
        },
        shadow = {
            enabled = $shadow_enabled,
        },
        dim_inactive = $dim,
    },
})
EOF
    changed+=("quality:$q")
fi

if [[ -n "$NEW_SCALE" ]]; then
    changed+=("scale:$NEW_SCALE")
fi

# One reload applies whatever changed (quality needs it for sure; scale only
# takes effect on reload or re-output too, so one shared reload covers both).
if hyprctl reload >/dev/null 2>&1; then
    sleep 2
else
    echo "hyprctl reload failed" >&2
    exit 1
fi

msg=""
for c in "${changed[@]}"; do
    key="${c%%:*}"; val="${c#*:}"
    case "$key" in
        scale) msg+=$'\n'"Scale: $val" ;;
        quality) msg+=$'\n'"Render quality: $val" ;;
    esac
done
if [[ "$NOTIFY_QUIET" != 1 ]]; then
    notify-send -a "Display" -i video-display "Display updated" "${msg#\n}" 2>/dev/null || true
fi
echo "applied: ${changed[*]}"
