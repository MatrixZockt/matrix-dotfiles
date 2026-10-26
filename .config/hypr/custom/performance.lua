-- ═══ Performance mode — GENERATED, do not edit by hand ═══════════════════
--
-- Rewritten by ~/.config/quickshell/ii/scripts/performance/apply.sh every time
-- you flip "Performance mode" (the settings app, or the right-sidebar button /
-- its top-bar icon). That script is the only writer, so there is one source of
-- truth: the shell config's `performanceMode`.
--
-- With it ON the interface keeps its look, its layout and every feature -- the
-- same theme, the same windows, the same gestures. Only the motion budget goes
-- away: the compositor's animations are switched off below, and the two things
-- custom/general.lua animates by hand (the fullscreen -> anchored glide and the
-- finger-following close-drag) cut straight to the end instead of issuing a
-- dispatch per frame. See custom/performance.lua (`performance`) for that half.

local M = {}

-- Read at RUN time by the gesture and keybind code (custom/general.lua), so
-- the same config works whether the flag is on or off -- and so the toggle
-- takes effect on the next gesture, not on the next login.
M.performance = false
function M.setPerformance(on)
    M.performance = on and true or false
end

M.setPerformance(true)
hl.animation({ leaf = "global", enabled = false, speed = 1 })
hl.animation({ leaf = "border", enabled = false, speed = 1 })
hl.animation({ leaf = "borderangle", enabled = false, speed = 1 })
hl.animation({ leaf = "windows", enabled = false, speed = 1 })
hl.animation({ leaf = "windowsIn", enabled = false, speed = 1 })
hl.animation({ leaf = "windowsOut", enabled = false, speed = 1 })
hl.animation({ leaf = "windowsMove", enabled = false, speed = 1 })
hl.animation({ leaf = "fade", enabled = false, speed = 1 })
hl.animation({ leaf = "fadeIn", enabled = false, speed = 1 })
hl.animation({ leaf = "fadeOut", enabled = false, speed = 1 })
hl.animation({ leaf = "layers", enabled = false, speed = 1 })
hl.animation({ leaf = "layersIn", enabled = false, speed = 1 })
hl.animation({ leaf = "layersOut", enabled = false, speed = 1 })
hl.animation({ leaf = "fadeLayersIn", enabled = false, speed = 1 })
hl.animation({ leaf = "fadeLayersOut", enabled = false, speed = 1 })
hl.animation({ leaf = "zoomFactor", enabled = false, speed = 1 })

return M
