#!/usr/bin/env bash
# The idle screen -- what idling shows.
#
# Not "display off". The point of idle is to stop burning watts for hours while
# still being able to glance over and see whether a build or download finished.
# So idling never blanks the panel and never suspends the machine: it drops the
# picture into one of the modes below, and the FIRST input restores everything
# exactly as it was.
#
# Modes (Settings > General > Power & idle, or `battery.idleMode` in
# ~/.config/illogical-impulse/config.json -- read live, no restart needed):
#
#   dim   backlight to its floor. The cheapest thing that can possibly be done,
#         and all it does is stop the panel from being the brightest object in
#         the room. The picture is untouched.
#   veil  dim + a compositor screen shader (custom/shaders/idle-veil.glsl) that
#         mutes and darkens the finished frame. Reads as "asleep" at a glance
#         without hiding anything: text, shapes and layout all stay.
#   eco   dim + the GPU-heavy compositor effects switched off (blur, shadows,
#         animations) and variable frame rate on. This is the one that actually
#         saves battery: at 1% backlight the backlight is no longer the load,
#         the compositor is -- blur is a full-screen multi-pass effect that runs
#         every frame, idle or not. Content stays perfectly visible.
#   deep  veil + eco: mutes the picture AND stops the compositor redrawing hard.
#         The quietest this machine can look while still showing you its screen.
#
# Everything that changes a live compositor setting is captured first and put
# back on wake, so a mode never "leaks" into the running session: if you had
# blur on, blur comes back; if you had a screen shader of your own (the
# shell's anti-flashbang, say), yours is the one restored.
#
# Usage:
#   screensaver.sh                    the idle sequence, configured mode
#   screensaver.sh --restore          wake path: put everything back
#   screensaver.sh --test [mode]      run a mode and immediately restore, for
#                                     previewing one without leaving it on.
#                                     The mode is optional and defaults to the
#                                     configured one, so the settings app can
#                                     offer a "try it" button per mode.
#   screensaver.sh --test [mode] SEC  the same, held for SEC seconds (default
#                                     3) before restoring.
#
# The backlight capture lives in /tmp as a PERCENTAGE: a second dim never
# stacks a restore on top of a restore, and the value is re-applied with the
# `%` suffix (without it brightnessctl reads the number as a raw value, which
# once left the panel near-dark after wake).

set -u

STATE_BRIGHTNESS=/tmp/ii-idle-brightness
VIDEO_CANCEL=/tmp/ii-idle-cancel
DEV=${BRIGHTNESS_DEVICE:-intel_backlight}
FALLBACK=1   # percentage used if brightnessctl is missing entirely

# The compositor half of a mode lives in its own program: this Hyprland runs the
# Lua config parser, where settings are applied by evaluating `hl.config({...})`
# rather than by `hyprctl keyword`, and building that Lua out of nested option
# names is not something to do with string concatenation in bash. It also owns
# the capture/restore of each option it borrows.
HYPR_OPTIONS="$(dirname "$0")/hypr-idle-options.py"
hypr_options() { python3 "$HYPR_OPTIONS" "$@" >/dev/null 2>&1 || true; }

# ── reading the user's settings ─────────────────────────────────────────────
# Both values are read out of the shell's own config file, live, so changing
# them in Settings applies to the very next idle instead of the next login.
cfg() {
    python3 - "$1" <<'PY' 2>/dev/null || printf '%s\n' "$2"
import json, os, sys
key, fallback = sys.argv[1], sys.argv[2]
try:
    value = json.load(open(os.path.expanduser("~/.config/illogical-impulse/config.json")))["battery"].get(key, fallback)
except Exception:
    value = fallback
if isinstance(value, bool):
    value = "true" if value else "false"
print(value)
PY
}

# Fallback matches the shell's own default (Config.qml: battery.idleMode),
# so a config file written before this option existed still idles eco.
#
# II_IDLE_MODE_OVERRIDE is how `--test <mode>` previews a mode that is not the
# chosen one: the sequence itself is unchanged, only its mode is.
idle_mode() {
    if [ -n "${II_IDLE_MODE_OVERRIDE:-}" ]; then
        printf '%s\n' "$II_IDLE_MODE_OVERRIDE"
        return
    fi
    cfg idleMode eco
}
dim_pct() {
    local pct
    pct=$(cfg idleDimPercent 1)
    case "$pct" in ''|*[!0-9]*) pct=1 ;; esac
    echo "$pct"
}

# ── backlight ───────────────────────────────────────────────────────────────
current_pct() {
    brightnessctl -d "$DEV" info 2>/dev/null \
        | sed -n 's/.*Current brightness: [0-9]* (\([0-9]*\)%).*/\1/p'
}

restore_brightness() {
    if [ -f "$STATE_BRIGHTNESS" ]; then
        brightnessctl -d "$DEV" set "$(cat "$STATE_BRIGHTNESS")%" >/dev/null 2>&1
        rm -f "$STATE_BRIGHTNESS"
    fi
}

dim_to_floor() {
    if command -v brightnessctl >/dev/null 2>&1; then
        # Capture once: the brightness we are dimming FROM. If a state file is
        # already there, an earlier dim is still in effect -- keep the ORIGINAL
        # value instead of overwriting it with the dimmed one, so two dims
        # still restore to full brightness once.
        if [ ! -f "$STATE_BRIGHTNESS" ]; then
            cur=$(current_pct)
            [ -n "$cur" ] && echo "$cur" > "$STATE_BRIGHTNESS"
        fi
        brightnessctl -d "$DEV" set "$(dim_pct)%" >/dev/null 2>&1
    elif [ -w "/sys/class/backlight/$DEV/brightness" ]; then
        # No brightnessctl: a very low fixed brightness through sysfs, keeping
        # the picture visible. Never turn the display off -- visible-but-dim
        # is the whole point.
        if [ ! -f "$STATE_BRIGHTNESS" ]; then
            cur_raw=$(cat "/sys/class/backlight/$DEV/brightness" 2>/dev/null || echo 0)
            max=$(cat "/sys/class/backlight/$DEV/max_brightness" 2>/dev/null || echo 100)
            # Store a percentage (restore_brightness re-applies it as one).
            echo $(( cur_raw * 100 / (max > 0 ? max : 1) )) > "$STATE_BRIGHTNESS" 2>/dev/null || true
        fi
        max=$(cat "/sys/class/backlight/$DEV/max_brightness" 2>/dev/null || echo 100)
        echo $(( max * $(dim_pct) / 100 )) > "/sys/class/backlight/$DEV/brightness" 2>/dev/null || true
    else
        : "$FALLBACK"
    fi
}

# ── compositor knobs ────────────────────────────────────────────────────────
# A session without a compositor (or without hyprctl) is not an error: the
# backlight half of the sequence still works, which is exactly the old
# behaviour.
hypr_ready() {
    command -v hyprctl >/dev/null 2>&1 && hyprctl version >/dev/null 2>&1
}

# Panel power for the long-idle tier. wlopm (wlr-output-power-management) is
# the primary because this Hyprland is the Lua-era build: hyprctl evals its
# dispatch arguments as Lua, so EVERY classic spelling of `dpms off` -- plain,
# comma and quoted -- is rejected. wlopm speaks the Wayland protocol directly
# and works on any wlroots-descendant compositor; the hyprctl fallback is for
# a session where it is missing but a classic build is running.
panel_off() {
    if command -v wlopm >/dev/null 2>&1 && [ -n "${WAYLAND_DISPLAY:-}" ]; then
        wlopm --off '*' >/dev/null 2>&1 && return 0
    fi
    hyprctl dispatch dpms off >/dev/null 2>&1 || true
}

panel_on() {
    if command -v wlopm >/dev/null 2>&1 && [ -n "${WAYLAND_DISPLAY:-}" ]; then
        wlopm --on '*' >/dev/null 2>&1 && return 0
    fi
    hyprctl dispatch dpms on >/dev/null 2>&1 || true
}

# ── video guard ─────────────────────────────────────────────────────────────
# A video answers "is someone watching?" with two facts, and both are needed:
#
#   1. SOMETHING IS FULLSCREEN. Watching video is a fullscreen activity: the
#      user asked for the desktop to be the video.
#   2. AUDIO IS ACTUALLY FLOWING. A sink-input that exists but is corked
#      (paused) or muted is not a video being watched.
#
# Together this is exactly the contract: a fullscreen YouTube film holds the
# screen, background YouTube music (no fullscreen window) does not -- however
# loud -- and a paused video stops holding the moment it pauses.
#
# The old check here read `media.role="video"` from PipeWire, which browsers do
# not set -- so YouTube in Brave always read as "not watching" and the idle
# mode dimmed the panel over a playing film. The fullscreen+audio pair needs no
# cooperation from the application at all.
watching_video() {
    command -v hyprctl >/dev/null 2>&1 || return 1
    command -v pactl   >/dev/null 2>&1 || return 1

    # 1) A fullscreen window somewhere. All monitors: a film on the external
    #    screen must hold the laptop panel too (idle dimming is per-machine,
    #    not per-monitor).
    if ! hyprctl -j workspaces 2>/dev/null | grep -q '"hasfullscreen": *true'; then
        return 1
    fi

    # 2) Audio actually flowing: any sink-input that is neither corked (paused)
    #    nor muted. This is the "paused video = no hold" half, and the
    #    "muted fullscreen = no hold" half too. awk paragraph mode (RS="")
    #    treats each "Sink Input #n" entry as its own record -- pactl separates
    #    entries with a blank line -- so one muted stream cannot bless another
    #    flowing one: both conditions must hold inside the SAME stream.
    pactl list sink-inputs 2>/dev/null | awk -v RS='' '
        /Corked: no/ && /Mute: no/ { found = 1 }
        END { exit !found }'
}

# The idle watcher loop below calls video_playing each cycle; same predicate.
video_playing() { watching_video "$@"; }

# ── long idle (the tier after this one) ─────────────────────────────────────
# Armed and tuned by the Power app (extras/bin/power-profiles-app); see the
# listener in hypridle.conf. Everything here is a no-op unless the user asked
# for it: the force marker is what makes the tier exist at all. The markers
# live in /tmp, so a reboot always starts with the tier disarmed.

# The tier's settings live in the shell config (battery.longIdle*), so they
# survive reboots and are edited live by Razer Control Center. No /tmp
# markers: a reboot can never "disarm" what the user chose to keep on.
long_idle_cfg() {
    python3 - "$1" "$2" <<'PY' 2>/dev/null
import json, os, sys
key, fallback = sys.argv[1], sys.argv[2]
try:
    v = json.load(open(os.path.expanduser("~/.config/illogical-impulse/config.json")))["battery"][key]
except Exception:
    v = fallback
print(("true" if v else "false") if isinstance(v, bool) else v)
PY
}
long_idle_armed() { [ "$(long_idle_cfg longIdleEnabled false)" = "true" ]; }
long_idle_want_suspend() { [ "$(long_idle_cfg longIdleSuspend false)" = "true" ]; }
long_idle_delay_min() {
    local n
    n=$(long_idle_cfg longIdleMinutes 10)
    case "$n" in ''|*[!0-9]*) echo 10 ;; *) echo "$n" ;; esac
}

long_idle_now() {
    # Someone may have come back between scheduling and firing.
    [ -f "$VIDEO_CANCEL" ] && exit 0
    long_idle_armed || exit 0
    # Never darken a watched video (see the video guard above for why).
    if video_playing; then
        # Same shape as the hold in idle_now: re-fire in 30 s until the video
        # stops, so the tier still lands after it -- just later.
        (
            for _ in $(seq 1 720); do
                [ -f "$VIDEO_CANCEL" ] && exit 0
                sleep 30
                [ -f "$VIDEO_CANCEL" ] && exit 0
                video_playing || break
            done
            [ -f "$VIDEO_CANCEL" ] || exec "$0" --long-idle
        ) >/dev/null 2>&1 </dev/null &
        disown 2>/dev/null || true
        exit 0
    fi

    # Panel off. The compositor stops driving scanout entirely, which is the
    # deepest a live picture can get while staying wakeable. The wake path
    # (wake_now, via hypridle's on-resume) is what turns it back on.
    panel_off

    # Optional suspend, delayed so a quick peek is only a screen-off. A due
    # marker survives the poke-and-peek, so if the machine gets touched in
    # those seconds the suspend is silently dropped -- and hypridle's
    # after_sleep_cmd (--restore) has already re-lit the panel.
    if long_idle_want_suspend; then
        if [ -f /tmp/ii-idle-long-suspend-due ]; then
            rm -f /tmp/ii-idle-long-suspend-due
            exit 0
        fi
        touch /tmp/ii-idle-long-suspend-due
        (
            sleep 30
            [ -f "$VIDEO_CANCEL" ] && exit 0
            [ -f /tmp/ii-idle-long-suspend-due ] || exit 0
            systemctl suspend
        ) >/dev/null 2>&1 </dev/null &
        disown 2>/dev/null || true
    fi
}

# ── the sequence ────────────────────────────────────────────────────────────
idle_now() {
    local mode
    mode=$(idle_mode)

    # Watching something: hold the picture. Nothing is dimmed and no mode is
    # applied, so there is nothing to restore when the video stops.
    #
    # But a hold that just exits has a hole: hypridle's timeout has now fired
    # and will not fire again until input resets idleness -- so a film watched
    # hands-off for two hours would keep the panel bright forever after it
    # ended. Instead the watcher stays alive in the background and dims the
    # moment the video stops. Any input cancels it (the wake path touches the
    # cancel marker -- someone is clearly present), and a six-hour cap keeps a
    # stuck player from pinning the backlight for a week.
    if video_playing; then
        (
            for _ in $(seq 1 720); do
                [ -f "$VIDEO_CANCEL" ] && exit 0
                sleep 30
                [ -f "$VIDEO_CANCEL" ] && exit 0
                video_playing || break
            done
            [ -f "$VIDEO_CANCEL" ] || idle_now
        ) >/dev/null 2>&1 </dev/null &
        disown 2>/dev/null || true
        exit 0
    fi

    # A fresh dim clears any stale cancel marker, so the next video hold is
    # judged on its own merit.
    rm -f "$VIDEO_CANCEL" 2>/dev/null || true

    dim_to_floor

    if hypr_ready; then
        case "$mode" in
        veil)
            hypr_options veil-on
            ;;
        eco)
            hypr_options eco-on
            ;;
        deep)
            hypr_options veil-on
            hypr_options eco-on
            ;;
        dim|*)
            ;;
        esac
    fi

    # The long-idle tier is scheduled from HERE, inside the idle sequence:
    # hypridle's timeout has now fired for the last time and will not fire
    # again until input resets idleness -- so a one-shot timer is the only
    # thing that can still fire later. Until it does (or input cancels it) the
    # panel keeps showing the idle mode, which is exactly the glanceable
    # behavior this file promises. A fire re-checks the markers and the video
    # guard, so a stale timer can never darken a session someone came back to.
    if long_idle_armed; then
        (
            sleep "$(( $(long_idle_delay_min) * 60 ))" 2>/dev/null || sleep 600
            [ -f "$VIDEO_CANCEL" ] && exit 0
            exec "$0" --long-idle
        ) >/dev/null 2>&1 </dev/null &
        disown 2>/dev/null || true
    fi
}

wake_now() {
    # A wake is input by definition, and input cancels a pending video watch
    # (see idle_now): someone is present, so the follow-up dim must not fire.
    touch "$VIDEO_CANCEL" 2>/dev/null || true

    # Same for the long-idle tier: its timer checks this marker right after
    # its sleep, so touching it here is what cancels a pending panel-off (and
    # the pending suspend below it).
    rm -f /tmp/ii-idle-long-suspend-due 2>/dev/null || true

    # If the long-idle tier turned the panel off, this is what turns it back
    # on -- nothing else will: an output that is off stays off until something
    # asks for it. Before everything else, for the same reason the brightness
    # restore comes first: a dark panel is the one failure this file cannot
    # walk back on its own. When the panel was never off, this is a no-op.
    panel_on

    # The backlight comes back FIRST, before anything is asked of the
    # compositor. A dark panel is the failure this whole file has to avoid, and
    # the compositor half is the half that can be slow: every option it restores
    # is a round trip to hyprctl, each with its own timeout. Doing the brightness
    # last meant a lock-up there left the screen at 1% with everything else
    # already back -- which looks exactly like "the dim never wore off".
    restore_brightness

    if hypr_ready; then
        hypr_options veil-off
        hypr_options eco-off
    else
        # No compositor to talk to: clear any leftovers so a stale marker does
        # not make the next dim skip its capture.
        hypr_options clear
    fi
}

case "${1:-}" in
--restore)
    wake_now
    ;;
--long-idle)
    long_idle_now
    ;;
--test)
    # Preview: the whole sequence and immediately back, nothing stays changed.
    # An explicit mode in $2 previews that one instead of the configured one;
    # an explicit number of seconds in $3 holds it longer (a two-second dim is
    # long enough to see, but not to compare).
    II_IDLE_MODE_OVERRIDE="${2:-}"
    export II_IDLE_MODE_OVERRIDE
    hold="${3:-3}"
    case "$hold" in ''|*[!0-9]*) hold=3 ;; esac
    idle_now
    sleep "$hold"
    wake_now
    ;;
*)
    idle_now
    ;;
esac

exit 0
