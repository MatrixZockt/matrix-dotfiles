-- Your own environment variables.
-- Loaded AFTER the base env (hyprland/env.lua), so anything you set here wins.
--
-- Example:
-- hl.env("EDITOR", "nvim")
-- hl.env("BROWSER", "firefox")

-- Display scaling switches.
--
-- These two switches are what make an arbitrary fractional scale safe on this
-- machine, and they are why the "the scale must divide the panel into whole
-- logical pixels" rule that used to live in general.lua and apply-display.sh
-- was never true rather than merely cautious: `disable_scale_checks` turns OFF
-- Hyprland's own scale check -- the one that warns about (and can snap) a
-- scale which does not land on whole pixels. With it off, 1.5 is an ordinary
-- value, which is what the default is now.
--
-- They also keep Hyprland from popping up the "scale adjusted" notification on
-- every login.
--
-- They live here (not in general.lua) because this file is evaluated before the
-- monitor rules, so the checks are disabled before the scale is applied.
hl.config({
    debug = {
        -- Accept the configured fractional scale instead of snapping it.
        disable_scale_checks = true,
    },
    misc = {
        -- Never show the "scale adjusted" popup on login.
        disable_scale_notification = true,
    },
})

-- GPU selection: left to Hyprland's own detection. Do NOT set AQ_DRM_DEVICES
-- here to pin the Intel iGPU.
--
-- TWO reasons, both learned the hard way on 2026-09-28:
--
-- 1. IT DOES NOT WORK FROM HERE. AQ_DRM_DEVICES is read by Aquamarine when
--    the DRM backend initialises, which happens BEFORE this config is
--    evaluated. hl.env() therefore arrives too late: verified by
--    restarting Hyprland with a correct, colon-free value set below, and
--    the compositor still opened /dev/nvidia0 and held all 5 NVIDIA fds
--    exactly as before. An earlier attempt to do this (with a /dev/dri/
--    by-path value) crashed Hyprland 7 times and was rolled back.
--
-- 2. IF IT EVER IS SET HERE IT MUST NOT CONTAIN A COLON. AQ_DRM_DEVICES is
--    a COLON-separated list, and every /dev/dri/by-path symlink is named
--    after a PCI address, which itself contains colons. A by-path value is
--    split mid-path, every fragment fails to resolve, Aquamarine reports
--    "Found no gpus to use", and the compositor aborts into safe mode.
--
-- To actually let the dGPU idle, the variable has to be in the environment
-- BEFORE Hyprland is exec'd -- i.e. in the login environment
-- (~/.config/environment.d/ or "systemctl --user import-environment"), not
-- in this file. That needs a logout/login to take effect. Until then the
-- RTX 4070 sits in P8 drawing a few watts because the compositor holds an
-- FD on it; the internal panel is already driven by the Intel iGPU, so this
-- costs idle power, not correctness.

-- Video decode: VA-API on the Intel iGPU ONLY.
--
-- Which render node libva picks as "default" depends on boot order (renderD128
-- was NVIDIA this boot, Intel on others), and the installed libva-nvidia-driver
-- (NVDEC shim) then hands Chromium decoded frames it cannot composite on the
-- Intel GL stack -- video surfaces come out as RGB static while the UI is fine
-- (diagnosed 2026-09-27 via vainfo: default node -> "VA-API NVDEC driver
-- [direct backend]", iHD on the Intel node decodes cleanly). Pinning the
-- driver to Intel's iHD makes every session app decode on the same GPU the
-- compositor renders on. Read once at Hyprland start -- lands on next login.
hl.env("LIBVA_DRIVER_NAME", "iHD")
