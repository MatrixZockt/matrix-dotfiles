-- What the four-finger-down close-drag actually ASKS the compositor to do.
--
--     lua5.4 ~/.config/hypr/custom/scripts/close-drag-check.lua [config.lua]
--
-- The gesture lives in custom/general.lua and reacts to a touchpad, so there is
-- no way to exercise it from a shell: hyprctl cannot synthesise a four-finger
-- swipe, and a real one closes whatever the user was looking at. This loads the
-- REAL config with a stub `hl` that records every dispatch, then plays the
-- gesture's own start/update/finish -- so the assertions are about the file the
-- compositor runs, not a copy of its logic.
--
-- The case it exists for (2026-10-24): "when dragging things on desktop apps
-- they go from fullscreen to attached windows. I dont want that". The gesture
-- used to un-fullscreen and float a fullscreen window at the START of every
-- swipe, committed or not. A SHORT swipe must now dispatch nothing at all, and
-- the tiled case -- which the gesture is for -- must still float and follow.

local CONFIG = arg[1] or "/home/user/.config/hypr/custom/general.lua"
local GESTURES = {}
local DISPATCHES = {}

local function win(over)
    -- The shape custom/general.lua reads: address, class, fullscreen, floating,
    -- size/at as {x=,y=} tables, workspace (popup.is_workspace_empty asks), and
    -- a monitor report (physical size + scale, as Hyprland gives it).
    local w = {
        address = "0xdeadbeef", class = "Freebuff", floating = false, fullscreen = 2,
        size = { x = 1707, y = 1067 }, at = { x = 0, y = 0 }, workspace = { id = 1 },
        monitor = { width = 2560, height = 1600, scale = 1.5, x = 0, y = 0 },
    }
    for k, v in pairs(over or {}) do w[k] = v end
    return w
end

-- Anything the config asks of `hl` that is not named below answers a callable
-- proxy, so an API this check does not model cannot take the whole load down.
local function proxy(name)
    return setmetatable({}, {
        __tostring = function() return "<" .. name .. ">" end,
        __index = function(t, k)
            local v = proxy(name .. "." .. tostring(k))
            rawset(t, k, v)
            return v
        end,
        __call = function(_, ...)
            local interesting = name:find("window%.move") or name:find("window%.resize")
                or name:find("window%.float") or name:find("window%.fullscreen")
                or name:find("window%.close") or name == "dispatch"
            if interesting then
                local parts = {}
                for _, a in ipairs({ ... }) do
                    if type(a) == "table" then
                        local kv = {}
                        for k, v in pairs(a) do kv[#kv + 1] = tostring(k) .. "=" .. tostring(v) end
                        table.sort(kv)
                        parts[#parts + 1] = "{" .. table.concat(kv, " ") .. "}"
                    else
                        parts[#parts + 1] = tostring(a)
                    end
                end
                DISPATCHES[#DISPATCHES + 1] = name .. " " .. table.concat(parts, " ")
            end
            return proxy(name .. "()")
        end,
    })
end

local ACTIVE = win()
hl = proxy("hl")
hl.get_active_window = function() return ACTIVE end
hl.get_active_workspace = function() return { id = 1 } end
hl.get_windows = function() return { ACTIVE } end
hl.get_window = function() return ACTIVE end
hl.gesture = function(g) GESTURES[#GESTURES + 1] = g end
hl.dispatch = function(d) DISPATCHES[#DISPATCHES + 1] = "dispatch " .. tostring(d) end
-- One-shot timers never fire here: every assertion is about the immediate path
-- (start, the follow, and finish), which is where the state change lives.
hl.timer = function() return {} end
for _, noop in ipairs({ "animation", "exec_cmd", "env", "monitor", "bind", "unbind",
                         "config", "curve", "workspace_rule", "window_rule", "layer_rule" }) do
    hl[noop] = function() end
end

-- `require("custom.popup")` is resolved from the config root, exactly as the
-- compositor does it.
package.path = "/home/user/.config/hypr/?.lua;/home/user/.config/hypr/?/init.lua;" .. package.path
local ok, err = pcall(dofile, CONFIG)
if not ok then
    io.stderr:write("config load failed: " .. tostring(err) .. "\n")
    os.exit(1)
end

local down
for _, g in ipairs(GESTURES) do
    if g.fingers == 4 and g.direction == "down" then down = g end
end
assert(down, "four-finger-down gesture was not registered by " .. CONFIG)

local FAILED = 0
local function fail(msg)
    FAILED = FAILED + 1
    print("  FAIL " .. msg)
end

local function play(travel)
    DISPATCHES = {}
    down.action.start({ phase = "start", type = "swipe", fingers = 4,
                        direction = "DOWN", cancelled = false, delta = { x = 0, y = 0 } })
    local left = travel
    while left > 0 do
        local step = math.min(40, left)
        down.action.update({ phase = "update", type = "swipe", fingers = 4, direction = "DOWN",
                             cancelled = false, delta = { x = 0, y = step } })
        left = left - step
    end
    if down.action.finish then
        down.action.finish({ phase = "end", type = "swipe", fingers = 4, direction = "DOWN",
                             cancelled = false, delta = { x = 0, y = 0 } })
    end
    return DISPATCHES
end

local function check(label, fn)
    print("── " .. label)
    fn()
end

-- The screen is 2560x1600 at 1.5, so the commit rule (a quarter of the LOGICAL
-- screen) is 235 logical px, and this pad's dead travel is 6% of 1600 = 96.
local function report(list)
    if #list == 0 then print("   (no dispatches)") end
    for _, d in ipairs(list) do print("   " .. d) end
end

-- 1. The report: a fullscreen window must not be touched by a drag.
check("SHORT swipe on a FULLSCREEN window (160px, under the quarter)", function()
    ACTIVE = win({ fullscreen = 2, floating = false })
    local list = play(160)
    report(list)
    for _, d in ipairs(list) do
        if d:find("fullscreen") then fail("fullscreen toggled: " .. d) end
        if d:find("window.float") then fail("floated: " .. d) end
        if d:find("window.move") then fail("moved: " .. d) end
        if d:find("window.resize") then fail("resized: " .. d) end
        if d:find("window.close") then fail("closed by a short swipe: " .. d) end
    end
    print("   window left fullscreen: " .. tostring(ACTIVE.fullscreen ~= 0))
end)

-- 2. A committing swipe still closes it -- and still does not detach it first.
check("LONG swipe on a FULLSCREEN window (600px, over the quarter)", function()
    ACTIVE = win({ fullscreen = 2, floating = false })
    local list = play(600)
    report(list)
    local closed = false
    for _, d in ipairs(list) do
        if d:find("window.close") then closed = true end
        if d:find("fullscreen") then fail("fullscreen toggled on the way: " .. d) end
        if d:find("window.float") then fail("floated on the way: " .. d) end
    end
    if not closed then fail("a quarter-screen swipe did not close anything") end
    print("   closed: " .. tostring(closed))
end)

-- 3. The tiled case is what the gesture is FOR: it must still float, pin its
--    geometry and follow the fingers, or the fix would have broken the gesture.
check("SHORT swipe on a TILED window (160px)", function()
    ACTIVE = win({ fullscreen = 0, floating = false })
    local list = play(160)
    report(list)
    local floated, followed, refull = false, false, false
    for _, d in ipairs(list) do
        if d:find("window.float") then floated = true end
        if d:find("window.move") then followed = true end
        if d == "window.fullscreen" or d:find("window.fullscreen") then refull = true end
    end
    if not floated then fail("tiled window was not floated for the drag") end
    if not followed then fail("tiled window did not follow the fingers") end
end)

-- 4. A window that is already floating follows without a float toggle.
check("SHORT swipe on a FLOATING window (160px)", function()
    ACTIVE = win({ fullscreen = 0, floating = true })
    local list = play(160)
    report(list)
    for _, d in ipairs(list) do
        if d:find("window.fullscreen") then fail("fullscreen toggled: " .. d) end
    end
end)

print("")
if FAILED == 0 then
    print("PASS: fullscreen windows are never detached by the close-drag")
    os.exit(0)
end
io.stderr:write(("FAILED: %d assertion(s)\n"):format(FAILED))
os.exit(1)
