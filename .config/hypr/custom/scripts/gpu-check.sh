#!/bin/bash
# Is the GPU actually being used, and is nothing on the command line taking it away?
#
# WHY THIS FILE EXISTS. A theme in Claude Desktop rendered, animated, and moved
# at about two frames a second, which looked like a theme bug and was not one:
# the app was fine, and so was the GPU. What was wrong was the launch line. Three
# things had to be true at once, and each of them is cheap to check and easy to
# lose again:
#
#   1. THE DISPLAY GPU AND THE APP'S GPU MUST BE THE SAME ONE. This is a hybrid
#      laptop: Intel RPL-S drives the panel (Hyprland runs with
#      AQ_DRM_DEVICES=/dev/dri/card1) and the NVIDIA 4070 is the render-offload
#      dGPU. An app that initialises against the dGPU while the compositor draws
#      with the iGPU has its frames copied across two devices per frame, and in
#      the worst case (Brave, measured 2026-10-29, see ~/.local/bin/brave)
#      maps but never paints at all. The Vulkan loader makes this likely because
#      it enumerates every ICD; pinning VK_ICD_FILENAMES to the Intel ICD is what
#      fixed Brave. That fix is per app on purpose: games and prime-run still
#      want the NVIDIA driver.
#
#   2. `--enable-features=` COSTS HALF THE FRAME RATE HERE. Measured
#      2026-11-14 with the real night-reef SVG plus its glass layer at
#      2560x1600 on the Intel iGPU: 58.7 / 60.0 / 60.2 fps with nothing but
#      --enable-gpu-rasterization, and 24-30 fps as soon as any
#      --enable-features= is on the line -- including a harmless one
#      (GlobalShortcutsPortal) that turns nothing on. The launcher carried
#      VaapiVideoDecodeLinuxGL, VaapiVideoDecoder and CanvasOopRasterization.
#      So: a feature switch is not free, and it does not belong on a launcher
#      unless something measured says it earns its place.
#
#   3. THE APP'S OWN GPU KILL SWITCH CAN BE ON WITHOUT ANYONE KNOWING. Claude
#      Desktop writes isHardwareAccelerationDisabled into
#      ~/.config/Claude/claude_desktop_config.json by itself after three GPU
#      process deaths, and logs "Hardware acceleration disabled via ...". While
#      that is set its GPU process runs `--use-gl=disabled`, every scene still
#      renders, and every scene is a still.
#
# Run this after touching any launcher, and when something that should be
# smooth is not. Exit status 1 means something on the list is wrong.
set -u

bad=0
say() { printf '%s\n' "$*"; }
flag() { say "  !! $*"; bad=1; }

say "── display ────────────────────────────────────────────────────────────"
say "  AQ_DRM_DEVICES=${AQ_DRM_DEVICES:-<unset: the compositor picks>}"
for d in /sys/class/drm/card*/device; do
    [ -r "$d/vendor" ] || continue
    card=$(basename "$(dirname "$d")")
    drv=$(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null)
    say "  $card  vendor=$(cat "$d/vendor")  driver=${drv:-?}"
    [ "$drv" = nvidia ] && say "     (dGPU: expect it to stay idle unless prime-run or a game asks)"
done

say "── GL under XWayland ──────────────────────────────────────────────────"
xdisp=${DISPLAY:-}
if [ -z "$xdisp" ] || ! DISPLAY=$xdisp timeout 3 xrandr --current >/dev/null 2>&1; then
    for n in 1 0 2 3; do
        DISPLAY=":$n" timeout 3 xrandr --current >/dev/null 2>&1 && { xdisp=":$n"; break; }
    done
fi
if [ -z "$xdisp" ]; then
    say "  no X display answered; skipping (pure Wayland session?)"
elif ! command -v glxinfo >/dev/null; then
    say "  glxinfo is not installed (mesa-utils); skipping"
else
    info=$(DISPLAY="$xdisp" timeout 20 glxinfo -B 2>/dev/null)
    renderer=$(printf '%s\n' "$info" | sed -n 's/^ *OpenGL renderer string: //p')
    direct=$(printf '%s\n' "$info" | sed -n 's/^direct rendering: //p')
    accel=$(printf '%s\n' "$info" | sed -n 's/^ *Accelerated: //p')
    say "  display $xdisp  renderer=${renderer:-?}  direct=${direct:-?}  accelerated=${accel:-?}"
    [ "${direct:-}" = "Yes" ] || flag "GL is not direct rendering on $xdisp (software or indirect path)"
    [ "${accel:-yes}" = "yes" ] || flag "GL reports no acceleration on $xdisp"
    case "$renderer" in
        *llvmpipe*|*softpipe*|*swrast*) flag "GL renderer is software ($renderer)";;
    esac
fi

say "── Vulkan default device ──────────────────────────────────────────────"
if [ -n "${VK_ICD_FILENAMES:-}" ]; then
    say "  pinned: VK_ICD_FILENAMES=$VK_ICD_FILENAMES"
else
    say "  not pinned in this shell (Brave pins the Intel ICD itself; games want both)"
fi
if command -v vulkaninfo >/dev/null; then
    dev=$(timeout 15 vulkaninfo --summary 2>/dev/null | sed -n 's/^[[:space:]]*deviceName[[:space:]]*=[[:space:]]*//p' | head -1)
    [ -n "$dev" ] && say "  first device: $dev"
fi

say "── running Chromium/Electron apps ─────────────────────────────────────"
found=0
for pid in $(pgrep -f 'type=gpu-process' 2>/dev/null); do
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    [ -n "$cmd" ] || continue
    name=$(printf '%s' "$cmd" | cut -d' ' -f1)
    name=${name##*/}
    # A process that has just died still lists here for a moment, with an empty
    # command line. It is not a finding.
    [ -n "$name" ] || continue
    found=1
    say "  $name (gpu pid $pid)"

    # What the GPU process is actually allowed to do. Chromium appends switches
    # of its own here, so features are reported, never judged: the flags a
    # launcher passes are what this desk can control, and the measurement above
    # is the reason to keep that list short.
    dri=$(ls -l "/proc/$pid/fd" 2>/dev/null | grep -c '/dev/dri/render')
    if [ "$dri" -eq 0 ]; then
        flag "$name's GPU process holds no /dev/dri/render node (not touching the GPU)"
    else
        say "     $dri render-node handles"
    fi
    case "$cmd" in
        *--use-gl=disabled*) flag "$name draws with --use-gl=disabled (software compositing)";;
    esac
    case "$cmd" in
        *--disable-gpu\ *|*--disable-gpu-compositing*) flag "$name has GPU compositing switched off";;
    esac
    feats=$(printf '%s' "$cmd" | tr ' ' '\n' | sed -n 's/^--enable-features=//p' | head -1)
    [ -n "$feats" ] && say "     features: $(printf '%s' "$feats" | cut -c1-90)"
    say ""
done
[ "$found" = 1 ] || say "  none running"

say "── app-level kill switches worth knowing ──────────────────────────────"
cfg="$HOME/.config/Claude/claude_desktop_config.json"
if [ -r "$cfg" ]; then
    if grep -q '"isHardwareAccelerationDisabled": *true' "$cfg" 2>/dev/null; then
        flag "Claude Desktop has hardware acceleration disabled in $cfg (its own gpu-recovery wrote that)"
    else
        say "  Claude Desktop: acceleration on"
    fi
fi

say "───────────────────────────────────────────────────────────────────────"
if [ "$bad" = 0 ]; then
    say "no red flags: the display GPU is the one apps are using, and nothing on a"
    say "command line is taking the frames away."
else
    say "something above is worth fixing before blaming the app."
fi
exit "$bad"
