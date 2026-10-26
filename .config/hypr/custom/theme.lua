-- Light/dark chrome for HYPRLAND ITSELF, following the shell's theme.
--
-- Everything the compositor draws on its own -- window borders, the desktop
-- background colour, window shadows, the inactive-window dim, the blur
-- tuning -- used to be hardcoded, in two places, for a dark desktop. The shell
-- (bar, sidebars, icons) had its own theme system and the two never met, so
-- the desktop could be light while the compositor was still drawing dark
-- chrome, or the other way round.
--
-- The shell now drives this: MaterialThemeLoader calls
--
--     hyprctl eval 'require("custom.theme").apply("light")'
--
-- whenever the palette changes, and writes the mode to MODE_FILE so a fresh
-- config load starts in the right mode without waiting for the shell. This
-- file is required LAST in hyprland.lua so it wins over hyprland/colors.lua
-- and hyprland/general.lua, which still set their own values.
--
-- `hyprctl keyword` cannot be used for any of this: the Lua config is a
-- non-legacy parser and the command refuses with "keyword can't work with
-- non-legacy parsers. Use eval." So everything goes through hl.config().

local M = {}

-- Where the shell records the current mode, so a reload starts correct even
-- if the shell is not running yet.
M.MODE_FILE = (os.getenv("HOME") or "") .. "/.local/state/quickshell/theme-mode"

--- The mode most recently applied, so `restore` knows what to put back.
M.current = nil

-- `dark` is exactly what was hardcoded before this file existed, so switching
-- back to dark is a no-op rather than a surprise. `light` is derived from the
-- shell's light template (ash-light: background #F9F9F9, onBackground #1B1B1B,
-- primary #5F5F5F, outline #747474).
M.THEMES = {
    dark = {
        active_border    = "rgba(4b454d77)",
        inactive_border  = "rgba(1e1a2033)",
        background_color = "rgba(151217FF)",
        shadow           = "rgba(00000020)",
        dim_strength     = 0.05,
        dim_special      = 0.2,
        -- Blur: vibrancy_darkness 0.5 pulls bright backdrops down. That is
        -- what a dark theme wants and exactly wrong for a light one, where the
        -- same value muddies every frosted surface.
        blur_brightness  = 1.0,
        blur_vibrancy    = 0.5,
        pin              = "rgba(dcb9f8AA) rgba(dcb9f877)",
    },
    light = {
        active_border    = "rgba(5F5F5F77)",
        inactive_border  = "rgba(6B6B6B33)",
        background_color = "rgba(F9F9F9FF)",
        -- A shadow on a light desktop reads far more strongly than the same
        -- alpha on a dark one, so it is both lighter and slightly warmer than
        -- the black used for dark mode.
        shadow           = "rgba(1B1B1B1F)",
        dim_strength     = 0.06,
        dim_special      = 0.18,
        blur_brightness  = 1.05,
        blur_vibrancy    = 0.0,
        pin              = "rgba(5F5F5FAA) rgba(5F5F5F77)",
    },
}

-- The pointer, following the same rule as the chrome above.
--
-- Bibata ships the SAME artwork in two colourways, which is what makes this
-- cheap and exact rather than a recolouring job:
--
--   Bibata-Modern-Ice     white pointer  -> for the DARK shell
--   Bibata-Modern-Classic black pointer  -> for the LIGHT shell
--
-- "Ice" is the light one and it is the one that wants a dark desktop, which is
-- the opposite of what the name suggests -- hence the explicit table instead of
-- composing the name from the mode. Both are installed under
-- ~/.local/share/icons/ by the Bibata v2.0.7 release tarballs.
--
-- Size: 24, the classic X11 default.
--
-- This started at 32. The argument for 32 was that the panel is 2560x1600 at
-- scale 1.5, so 24pt lands at only 36 physical pixels, and 32 is the largest
-- size the theme ships a NATIVE bitmap for (40 is already an upscale of 32).
-- That reasoning was sound and the measurement behind it is still true -- it
-- just was not the answer. On the real screen 32 read as too big, so it was
-- dropped to 24 on request.
--
-- 24 is not a compromise between the two: the theme ships a real 24px bitmap
-- (its native sizes are 16, 20, 22, 24, 28, 32, then 40+ which are upscales),
-- so nothing is being resampled. If it still reads large, 22 and 20 are also
-- native and need no redraw; below 16 the artwork stops being legible and
-- should not be forced.
M.CURSOR_SIZE = 24

--- The pointer is NOT themed per mode, and it is NOT the borderless artwork.
---
--- It used to be: a white borderless Bibata on dark and a black one on light,
--- re-issued through `hyprctl setcursor` on every theme apply -- plus a second,
--- disagreeing name in hyprland/execs.lua at startup and a third in the X11
--- resource manager. Three answers to one question meant the artwork could
--- change under the hand (an outlined arrow over one window, a borderless one
--- over the next), which is the reported "border turns from black to white".
---
--- The borderless themes and the swapping are gone (removed 2026-10-22). The
--- pointer is the STOCK Bibata-Modern-Ice artwork -- white body, black rim --
--- the same in both modes and the same in every window.
---
--- The single answer lives in hyprland/env.lua as XCURSOR_THEME, which is what
--- actually resolves a cursor on this build (see the measurement note there:
--- `setcursor` accepts any name and changes nothing). Nothing here swaps it, and
--- nothing swaps it per mode.
local function applyCursor(_mode)
    return
end

--- Read the mode the shell last recorded. Anything unrecognised is "dark",
--- which is the safe default: it is the theme every other file in this config
--- still assumes, so a typo degrades to "old behaviour" rather than to a light
--- desktop full of unreadable chrome.
function M.readMode()
    local handle = io.open(M.MODE_FILE, "r")
    if not handle then return "dark" end
    local value = handle:read("*l")
    handle:close()
    if value == "light" or value == "dark" then return value end
    return "dark"
end

--- Apply a mode by name. Unknown names are ignored rather than thrown, so a
--- bad call from the shell cannot leave the compositor with no chrome at all.
function M.apply(mode)
    local theme = M.THEMES[mode]
    if not theme then return false end
    M.current = mode

    hl.config({
        general = {
            col = {
                active_border   = theme.active_border,
                inactive_border = theme.inactive_border,
            },
        },
        decoration = {
            shadow = { color = theme.shadow },
            dim_strength = theme.dim_strength,
            dim_special = theme.dim_special,
            blur = {
                brightness = theme.blur_brightness,
                vibrancy = theme.blur_vibrancy,
                vibrancy_darkness = theme.blur_vibrancy,
            },
        },
        misc = {
            background_color = theme.background_color,
        },
    })

    -- The pinned-window ring. It is a rule rather than a global, so it is
    -- re-declared on every switch; hl.window_rule keys on the match, so this
    -- replaces the ring rather than stacking a second one per switch.
    hl.window_rule({
        match        = { pin = 1 },
        border_color = theme.pin,
    })

    -- The pointer used to be re-issued here on every switch; it is a single
    -- static theme now (see applyCursor above), so there is nothing to do.
    applyCursor(mode)

    return true
end

--- Re-apply the mode that is currently in force.
---
--- This was written for custom/scripts/window-border-hint.py, which painted an
--- opaque black border while the pointer rested on a window's resize edge and
--- had to put something back when it left. That script is DISABLED as of
--- 2026-10-16 -- the edge grab it advertised is off (see the dated note in
--- custom/general.lua) -- so nothing calls this today. It stays anyway: it is
--- the "put the current mode back" entry point, and reviving the hint should not
--- also mean re-deriving its colours.
---
--- The reason it exists at all, kept from that work: the script used to hold its
--- own copies of the two resting colours, copied from hyprland/colors.lua, and
--- pushed those verbatim -- so a light theme was undone the first time the
--- pointer left an edge, and the border flipped back to dark while the rest of
--- the desktop stayed light. Asking here instead means the resting colours live
--- in exactly one place and cannot drift from what the desktop is wearing.
---
--- The script only calls this on a transition (entering or leaving the band),
--- never per tick, so the extra require is not a cost worth worrying about.
function M.restore()
    return M.apply(M.current or M.readMode())
end

-- Apply whatever the shell last recorded. Runs at config load, before the
-- shell has had any chance to talk to us, so a restart never flashes the wrong
-- chrome.
M.apply(M.readMode())

return M
