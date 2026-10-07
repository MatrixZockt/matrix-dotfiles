-- This file sources other files in `hyprland` and `custom` folders
-- You wanna add your stuff in files in `custom`

-- Internal stuff --
require("hyprland.lib")
require("hyprland.services")

-- Environment variables --
require("hyprland.env")
if is_file_exists(HOME .. "/.config/hypr/custom/env.lua") then
    require("custom.env")
end

-- Default configurations --
require("hyprland.execs")
require("hyprland.general")
require("hyprland.rules")
require("hyprland.colors")
require("hyprland.keybinds")

-- Custom configurations --
if is_file_exists(HOME .. "/.config/hypr/custom/execs.lua") then
    require("custom.execs")
end
if is_file_exists(HOME .. "/.config/hypr/custom/general.lua") then
    require("custom.general")
end
-- Generated from the shell config (Settings > Keyboard). Loaded after
-- custom.general so its input settings win.
if is_file_exists(HOME .. "/.config/hypr/custom/keyboard.lua") then
    require("custom.keyboard")
end
if is_file_exists(HOME .. "/.config/hypr/custom/rules.lua") then
    require("custom.rules")
end
if is_file_exists(HOME .. "/.config/hypr/custom/keybinds.lua") then
    require("custom.keybinds")
end
-- Generated from the shell config (Performance mode). Loaded after every other
-- custom file so its animation switch wins over the leaves they set.
if is_file_exists(HOME .. "/.config/hypr/custom/performance.lua") then
    require("custom.performance")
end
-- Generated from the Razer Command Center app / Settings > Display (render
-- quality). Required after performance.lua so the user's chosen look wins
-- unless a performance mode actively overrides it this session.
if is_file_exists(HOME .. "/.config/hypr/custom/quality.lua") then
    require("custom.quality")
end

-- nwg-displays support --
if is_file_exists(HOME .. "/.config/hypr/workspaces.lua") then
    require("workspaces")
end
if is_file_exists(HOME .. "/.config/hypr/monitors.lua") then
    require("monitors")
end

-- Shell overrides --
require("hyprland.shellOverrides.main")

-- Light/dark chrome for Hyprland itself. Required LAST on purpose: it sets the
-- same window borders, background colour and shadow that hyprland/colors.lua
-- and hyprland/general.lua set, so it has to be the last word.
if is_file_exists(HOME .. "/.config/hypr/custom/theme.lua") then
    require("custom.theme")
end
