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

-- ── X11 (XWayland) app scale ──────────────────────────────────────────────
--
-- The companion to custom/general.lua's xwayland:force_zero_scaling = true
-- and custom/scripts/x11-dpi.sh's Xft.dpi. Those two give X11 apps a native
-- 2560x1600 canvas to draw into (crisp) and a DPI to size themselves with;
-- this block covers the two X11 apps that ignore Xft.dpi and have their own
-- knob instead.
--
-- Why so little is set here, and why nothing toolkit-wide is:
--
--   * GDK_SCALE and QT_SCALE_FACTOR MULTIPLY into whatever the compositor
--     already gives a Wayland app (they are read by the toolkit, not by the
--     X server). A global 1.5 would draw every Wayland GTK/Qt app at 2.25x;
--     a global 2 would draw them at 3x. So they are never set globally --
--     the file used to export GDK_SCALE from the fish login env whenever the
--     scale's integer part reached 2, which is exactly that bug waiting for
--     someone to pick 200%. A single X11-locked app that needs one gets it on
--     its own launcher line instead:  QT_QPA_PLATFORM=xcb QT_SCALE_FACTOR=$s.
--
--   * Xft.dpi (x11-dpi.sh) is the safe global one precisely because it is an
--     X server property: Wayland clients never read it.
--
-- QT_SCALE_FACTOR_ROUNDING_POLICY=PassThrough is the one Qt-wide exception,
-- and it is safe for the same reason: it changes only how Qt ROUNDS a scale
-- factor, never what the factor is. On Wayland the factor is the integer the
-- compositor reports (2 here), so passing it through is a no-op. On X11 Qt
-- derives its factor from Xft.dpi -- 144dpi -> 1.5 -- and without this it
-- rounds that to 2, drawing a 150%-size UI on a 150% desktop. Verified with a
-- Qt window on :1: devicePixelRatio 1.5 with this set (2 without it).
--
-- Steam's desktop UI is its own thing: STEAM_FORCE_DESKTOPUI_SCALING is
-- fractional and applies only to Steam, so it gets the exact scale and stays
-- crisp inside the native canvas. (Steam used to be served by
-- ~/.config/fish/conf.d/app-scale.fish, which only ever ran for fish logins;
-- it did not run for a Hyprland-launched Steam at all.)
--
-- Not covered on purpose: Java/Swing IDEs (Android Studio) size themselves
-- from the X11 DPI, which x11-dpi.sh now provides. If one ever comes up at
-- the wrong size, its own knob is -Dsun.java2d.uiScale=<scale> on that app's
-- launcher line, not a global JAVA_TOOL_OPTIONS.
local function displayScale()
    local f = io.open((os.getenv("HOME") or "") .. "/.cache/display/scale", "r")
    if not f then return 1.5 end
    local v = tonumber(f:read("*l"))
    f:close()
    if v and v >= 1 and v <= 2.5 then return v end
    return 1.5
end
local xScale = displayScale()
hl.env("QT_SCALE_FACTOR_ROUNDING_POLICY", "PassThrough")
hl.env("STEAM_FORCE_DESKTOPUI_SCALING", tostring(xScale))

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

-- Cursor: the same Bibata pair every wrapper forces, set at the session root
-- so every child of the compositor carries it (Wayland clients, xwayland,
-- portals, and the X11 clients spawned from this session).
hl.env("XCURSOR_THEME", "Bibata-Modern-Ice")
hl.env("XCURSOR_SIZE", "24")
-- XCURSOR_PATH with a shim dir first. Claude (and Chromium generally)
-- hardcodes an "Adwaita" cursor-theme request internally -- proven with an
-- LD_PRELOAD probe of XcursorLibraryLoadCursor / XcursorSetTheme -- so it
-- renders its stock black arrow regardless of the environment. The shim
-- ~/.local/share/cursor-shims/Adwaita is a symlink to the real Bibata theme,
-- so the *name* "Adwaita" now resolves to the user's cursor everywhere.
-- Path is applied after theme state in libXcursor, so it covers every app.
hl.env("XCURSOR_PATH", (os.getenv("HOME") or "/home/user") .. "/.local/share/cursor-shims:~/.local/share/icons:~/.icons:/usr/share/icons:/usr/share/pixmaps")
hl.env("HYPRCURSOR_THEME", "Bibata-Modern-Ice")
