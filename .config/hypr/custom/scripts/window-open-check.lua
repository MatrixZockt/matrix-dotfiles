-- What a window.open actually demotes, for a drag ghost vs a real app.
--
--     lua5.4 ~/.config/hypr/custom/scripts/window-open-check.lua [config.lua]
--
-- The "a fullscreen neighbour steps aside" hook lives in custom/general.lua and
-- answers to window.open, so there is no way to exercise it from a shell: a
-- real drag cannot be synthesised, and the thing it would demote is the window
-- the user is working in. This loads the REAL config with a stub `hl` that
-- records every dispatch, then calls the registered window.open handlers with
-- the two kinds of window that map during a drag.
--
-- The case it exists for (2026-10-24, reported twice): "drag and dropping
-- things of an app still closes the fullscreen". Dragging anything out of an
-- app makes its toolkit map a drag image -- no class, no title, no input --
-- and the hook demoted the fullscreen app for it. The trace had it five times:
--
--     fullscreen: stepped aside for Freebuff so  is visible
--
-- A drag ghost must dispatch NOTHING. A real app opening over a fullscreen one
-- must still demote it, which is what the hook is for, so that is checked in
-- the same run: a "fix" that stopped demoting would pass half of this and
-- break the feature.

local CONFIG = arg[1] or "/home/user/.config/hypr/custom/general.lua"
local OPEN_HANDLERS = {}
local DISPATCHES = {}

local function win(over)
    local w = {
        address = "0xfeed0000", class = "Freebuff", initial_class = "Freebuff",
        title = "Freebuff Desktop", initial_title = "Freebuff",
        floating = false, fullscreen = 2, fullscreen_client = 0,
        mapped = true, hidden = false, visible = true, accepts_input = true,
        size = { x = 1707, y = 1067 }, at = { x = 0, y = 0 },
        workspace = { id = 1 },
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
                or name:find("window%.close") or name:find("window%.fullscreen_state")
                or name == "hl.dsp.focus" or name == "dispatch"
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

local WINDOWS = {}
hl = proxy("hl")
hl.get_windows = function() return WINDOWS end
hl.get_window = function() return WINDOWS[1] end
hl.get_active_window = function() return WINDOWS[1] end
hl.get_active_workspace = function() return { id = 1 } end
hl.on = function(event, fn)
    if event == "window.open" then OPEN_HANDLERS[#OPEN_HANDLERS + 1] = fn end
end
hl.dispatch = function(d) DISPATCHES[#DISPATCHES + 1] = "dispatch " .. tostring(d) end
-- One-shot timers never fire here: every assertion is about the first tick,
-- which is the tick that had to work for the reported bug to happen at all.
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
assert(#OPEN_HANDLERS > 0, "no window.open handler was registered by " .. CONFIG)

local FAILED = 0
local function fail(msg)
    FAILED = FAILED + 1
    print("  FAIL " .. msg)
end

local function run(newcomerOver)
    local incumbent = win({ address = "0xfeed0000" })
    -- A DIFFERENT address, always: the hook skips members of the incumbent loop
    -- whose address matches the newcomer, so two windows sharing one address
    -- would make every scenario look "nothing to demote" -- including the ones
    -- that must demote, which is how a test like this passes while proving
    -- nothing at all.
    local merge = { address = "0xfeed0001" }
    for k, v in pairs(newcomerOver or {}) do merge[k] = v end
    local newcomer = win(merge)
    WINDOWS = { incumbent, newcomer }
    DISPATCHES = {}
    for _, fn in ipairs(OPEN_HANDLERS) do pcall(fn, newcomer) end
    return DISPATCHES
end

local function report(list)
    if #list == 0 then print("   (no dispatches)") end
    for _, d in ipairs(list) do print("   " .. d) end
end

local function touchedFullscreen(list)
    for _, d in ipairs(list) do
        if d:find("fullscreen") or d:find("window%.float") then return d end
    end
    return nil
end

local function check(label, fn)
    print("── " .. label)
    fn()
end

-- 1. THE REPORT: a drag image mapping over a fullscreen app must not demote it.
check("DRAG GHOST (no class, no title, no input) over a fullscreen app", function()
    local list = run({
        class = "", initial_class = "", title = "", initial_title = "",
        accepts_input = false, floating = true, fullscreen = 0,
    })
    report(list)
    local bad = touchedFullscreen(list)
    if bad then fail("the ghost demoted the fullscreen app: " .. bad) end
end)

-- 2. Same drag, but the toolkit put its own class on the ghost. A window that
--    takes no input is still not something to clear the screen for.
check("DRAG GHOST that kept the app's class (no input) over a fullscreen app", function()
    local list = run({
        class = "brave-browser", initial_class = "brave-browser",
        title = "", initial_title = "", accepts_input = false,
        floating = true, fullscreen = 0,
    })
    report(list)
    local bad = touchedFullscreen(list)
    if bad then fail("the classed ghost demoted the fullscreen app: " .. bad) end
end)

-- 3. The feature the hook exists for: a real app opening over a fullscreen one
--    still takes the screen back. Without this the "fix" would be a deletion.
check("REAL APP over a fullscreen app (must still demote)", function()
    local list = run({
        address = "0xfeed0001", class = "kitty", initial_class = "kitty",
        title = "Freebuff: drag test", initial_title = "kitty",
        accepts_input = true, floating = false, fullscreen = 0,
        size = { x = 845, y = 1010 }, at = { x = 6, y = 51 },
    })
    report(list)
    local demoted = nil
    for _, d in ipairs(list) do
        if d:find("window%.fullscreen") and d:find("unset") then demoted = d end
    end
    if not demoted then fail("a real app did not take the screen back") end
    print("   demoted by: " .. tostring(demoted))
end)

print("")
if FAILED == 0 then
    print("PASS: drag ghosts are ignored and real apps still step the desktop aside")
    os.exit(0)
end
io.stderr:write(("FAILED: %d assertion(s)\n"):format(FAILED))
os.exit(1)
