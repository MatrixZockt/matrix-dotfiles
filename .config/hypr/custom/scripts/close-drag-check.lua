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
-- The cases it exists for:
--
--   2026-10-24 "when dragging things on desktop apps they go from fullscreen to
--   attached windows. I dont want that" -- the gesture un-fullscreened and
--   floated a fullscreen window at the START of every swipe, committed or not.
--   So a swipe under the dead travel must dispatch NOTHING (case 1).
--
--   2026-10-27 "4finger swipe down animation doesnt move the desktop app down
--   depending on the finger movement, when in fullscreen" -- after that fix the
--   gesture moved a fullscreen window not at all, so the fingers moved and the
--   app did not. It now detaches at the moment the drag is DELIBERATE, follows
--   1:1, and puts the fullscreen back when the swipe does not commit
--   (cases 2 and 3).
--
-- The tiled case -- which the gesture is for -- must still float and follow.

local CONFIG = arg[1] or (os.getenv("HOME") or "") .. "/.config/hypr/custom/general.lua"
local GESTURES = {}
local DISPATCHES = {}
-- Declared HERE, above `proxy`, because the proxy's call handler sets it: a
-- `local` declared after the function that writes it is a different variable,
-- so the write would land in a global and `get_windows` (closing over the real
-- local) would never see it -- the closed window kept being found and the
-- harness "caught" the gesture restoring a window that no longer existed.
local CLOSED = false

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
    -- Printed by NAME in a recorded dispatch (`hl.dsp.focus {window=MediaPopup}`),
    -- which is how a case can say WHICH window the gesture aimed at: the focus
    -- dispatcher ignores `address` on this build, so an address alone proves
    -- nothing about what got focused.
    setmetatable(w, { __tostring = function(t) return tostring(t.class) end })
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
        __call = function(_, ...)                local interesting = name:find("window%.move") or name:find("window%.resize")
                or name:find("window%.float") or name:find("window%.fullscreen")
                or name:find("window%.close") or name == "dispatch"
                or name == "hl.dsp.focus" or name == "hl.dsp.global"
            if interesting then
                if name:find("window%.close") then CLOSED = true end
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

-- ── What is on screen, and where the pointer is (2026-10-27) ────────────
-- The close-drag now dismisses the window under the POINTER rather than the
-- focused one, so a check has to be able to put the pointer somewhere and to
-- have more than one window on the workspace. Both default to "unknown":
-- no window list beyond the focused one, and no pointer reading -- which is
-- exactly the old focused-window behaviour, so cases 1-6 assert it unchanged.
local WINDOWS = nil -- nil = just the focused window, as before
local CURSOR = nil  -- nil = pointer unreadable, as before
-- A window that has been CLOSED is gone (see CLOSED above), and the check has
-- to model that: the gesture's post-close path ("a close that asks for
-- confirmation did not close it") reads the window back, and with a stub that
-- always answers, a window that closed would still be found -- so the harness
-- saw a closed app restored to fullscreen and called the gesture wrong.
-- Reset for every case.
hl.get_cursor_pos = function() return CURSOR end
hl.get_monitor_at_cursor = function()
    return { id = 0, active_workspace = { id = 1 }, active_special_workspace = nil }
end
hl.get_windows = function()
    if CLOSED then return {} end
    return WINDOWS or { ACTIVE }
end
hl.get_window = function() return ACTIVE end
hl.gesture = function(g) GESTURES[#GESTURES + 1] = g end
hl.dispatch = function(d) DISPATCHES[#DISPATCHES + 1] = "dispatch " .. tostring(d) end
-- One-shot timers never fire here: every assertion is about the immediate path
-- (start, the follow, and finish), which is where the state change lives.
-- Timers are RECORDED, not fired: cases 1-9 assert about the immediate path
-- (start, the follow, finish), and firing a 350ms restore in the middle of a
-- case would change what those are looking at. A case that needs the deferred
-- half (the fullscreen restore after a spring-back) calls flush() and gets
-- exactly that: the callbacks the gesture queued, run on demand.
local TIMERS = {}
hl.timer = function(cb)
    TIMERS[#TIMERS + 1] = cb
    return {}
end
local function flush()
    local ran = 0
    for _ = 1, 6 do
        local batch = TIMERS
        TIMERS = {}
        if #batch == 0 then break end
        for _, cb in ipairs(batch) do
            ran = ran + 1
            cb()
        end
    end
    return ran
end
for _, noop in ipairs({ "animation", "exec_cmd", "env", "monitor", "bind", "unbind",
                         "config", "curve", "workspace_rule", "window_rule", "layer_rule" }) do
    hl[noop] = function() end
end

-- `require("custom.popup")` is resolved from the config root, exactly as the
-- compositor does it.
package.path = (os.getenv("HOME") or "") .. "/.config/hypr/?.lua;"
    .. (os.getenv("HOME") or "") .. "/.config/hypr/?/init.lua;" .. package.path
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

local function play(travel, atY, follows)
    DISPATCHES = {}
    CLOSED = false
    TIMERS = {}
    down.action.start({ phase = "start", type = "swipe", fingers = 4,
                        direction = "DOWN", cancelled = false, delta = { x = 0, y = 0 } })
    local left = travel
    while left > 0 do
        local step = math.min(40, left)
        down.action.update({ phase = "update", type = "swipe", fingers = 4, direction = "DOWN",
                             cancelled = false, delta = { x = 0, y = step } })
        left = left - step
    end
    -- A committing TILED swipe reads `moved` off the window's own position
    -- (finish: "the distance is the window's own"), and the stub window's
    -- at.y never changes because the recorded dispatches are not applied to
    -- it -- without this, moved stays 0, commit never fires, and every
    -- tiled-commit case springs back instead of reaching the close/park code
    -- it is supposed to assert about. atY simulates "the window followed the
    -- fingers this far"; old cases pass no atY and are untouched.
    if atY then (follows or ACTIVE).at.y = atY end
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

-- 1. UNDER the dead travel (96px on this panel) a fullscreen window must not
--    be touched at all: this is the phantom/palm case, and converting a
--    fullscreen app on noise is what the 2026-10-24 report was about.
check("swipe UNDER the dead travel on a FULLSCREEN window (60px)", function()
    ACTIVE = win({ fullscreen = 2, floating = false })
    local list = play(60)
    report(list)
    for _, d in ipairs(list) do
        if d:find("fullscreen") then fail("fullscreen toggled: " .. d) end
        if d:find("window.float") then fail("floated: " .. d) end
        if d:find("window.move") then fail("moved: " .. d) end
        if d:find("window.resize") then fail("resized: " .. d) end
        if d:find("window.close") then fail("closed by a short swipe: " .. d) end
    end
    print("   dispatches: " .. #list .. " (must be 0)")
end)

-- 2. PAST the dead travel (but under the quarter) a fullscreen window must
--    FOLLOW THE FINGERS -- the 2026-10-27 report "4finger swipe down animation
--    doesnt move the desktop app down depending on the finger movement, when
--    in fullscreen" -- and must be put back fullscreen when the swipe does not
--    commit.
check("drag past the dead travel on a FULLSCREEN window (160px) -- follows, then comes back", function()
    ACTIVE = win({ fullscreen = 2, floating = false })
    local list = play(160)
    report(list)
    local unset, floated, moved, closed = false, false, false, false
    for _, d in ipairs(list) do
        if d:find("window%.fullscreen") then unset = true end
        if d:find("window%.float") then floated = true end
        if d:find("window%.move") then moved = true end
        if d:find("window%.close") then closed = true end
    end
    if not unset then fail("the fullscreen window was never detached for the drag") end
    if not floated then fail("the detached window was not floated") end
    if not moved then fail("the window did not follow the fingers") end
    if closed then fail("a swipe under the quarter closed the window") end
    -- The deferred half: the spring-back's restore is queued on a timer.
    -- EXACTLY ONE, not "at least one": the belt at the end of finish() used
    -- to fire an extra fullscreen toggle on the immediate path while the
    -- spring-back's 350ms timer held another -- ON, then OFF -- leaving the
    -- window floating mid-tween after a cancelled swipe (2026-10-27
    -- "canceling it remains weirdly suspended"). An odd count means the
    -- window ends fullscreen; two toggles cancel out to floating.
    local ran = flush()
    local toggles = 0
    for _, d in ipairs(DISPATCHES) do
        if d:find("window%.fullscreen") and d:find("toggle") then toggles = toggles + 1 end
    end
    if toggles == 0 then fail("the window was left out of fullscreen after a spring-back") end
    if toggles > 1 then
        fail("fullscreen was toggled " .. toggles .. " times by one cancelled swipe"
            .. " (the belt and the spring-back both restored it)")
    end
    print("   timers run: " .. ran .. ", fullscreen restores: " .. toggles .. " (must be 1)")
end)

-- 3. A committing swipe closes it -- after detaching, since a fullscreen window
--    cannot be dragged while it is fullscreen -- and must NOT restore it.
check("LONG swipe on a FULLSCREEN window (600px, over the quarter)", function()
    ACTIVE = win({ fullscreen = 2, floating = false })
    -- atY simulates the window following the fingers (the stub does not apply
    -- recorded dispatches): since a fullscreen window now DETACHES and follows,
    -- `moved` is read off the window's own position, so it has to move.
    local list = play(600, 300)
    report(list)
    local closed, detached = false, false
    for _, d in ipairs(list) do
        if d:find("window%.close") then closed = true end
        if d:find("window%.fullscreen") and d:find("unset") then detached = true end
    end
    if not closed then fail("a quarter-screen swipe did not close anything") end
    -- Anything queued must not put the closed window back into fullscreen.
    flush()
    for _, d in ipairs(DISPATCHES) do
        if d:find("window%.fullscreen") and d:find("toggle") then
            fail("a committing swipe restored fullscreen: " .. d)
        end
    end
    print("   closed: " .. tostring(closed) .. ", detached first: " .. tostring(detached))
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

-- 5. The restored tray branch (2026-10-27): a committing swipe on a class
--    opted in through config.json's tray.closeToTray (WhatsApp Desktop) must
--    PARK it on special:tray and must NOT close it -- closing is a quit for
--    an Electron client, and the shell's tray icon is window-backed, so a
--    close takes the icon away with the window.
check("LONG swipe on a TILED WhatsApp Desktop (600px)", function()
    ACTIVE = win({ fullscreen = 0, floating = false, class = "WhatsApp Desktop" })
    local list = play(600, 300) -- window followed to y=300 (> 235 = the quarter)
    report(list)
    local parked, closed, unfloated = false, false, false
    for _, d in ipairs(list) do
        if d:find("special:tray") then parked = true end
        if d:find("window.close") then closed = true end
        if d:find("window.float") and d:find("unset") then unfloated = true end
    end
    if not parked then fail("tray app was not parked on special:tray") end
    if closed then fail("tray app was closed instead of parked") end
    if not unfloated then fail("tray app was not un-floated before the park") end
end)

-- 6. The branch is opt-in and nothing else changed: a non-tray class closes.
check("LONG swipe on a TILED non-tray window (600px)", function()
    ACTIVE = win({ fullscreen = 0, floating = false, class = "Freebuff" })
    local list = play(600, 300)
    report(list)
    local closed, parked = false, false
    for _, d in ipairs(list) do
        if d:find("window.close") then closed = true end
        if d:find("special:tray") then parked = true end
    end
    if not closed then fail("non-tray window did not close") end
    if parked then fail("non-tray window was parked") end
end)

-- 7. WHICH window the swipe belongs to (2026-10-27): THE ONE UNDER THE
--    POINTER. A popup -- floated, centred, drawn above the window behind it --
--    can be up while focus still sits on that window, and the swipe used to
--    close the window BEHIND the popup. Required: the popup is focused first
--    (every dispatcher is focus-scoped on this build), then dragged, then
--    closed -- and the window behind is never touched.
check("LONG swipe with the pointer on a FLOATING popup, focus on the window behind", function()
    local behind = win({ address = "0xbehind", class = "Brave", fullscreen = 0,
                         floating = false, workspace = { id = 1 } })
    local popup = win({ address = "0xpopup", class = "MediaPopup", fullscreen = 0,
                        floating = true, workspace = { id = 1 },
                        at = { x = 1000, y = 300 }, size = { x = 600, y = 400 } })
    WINDOWS = { behind, popup }
    ACTIVE = behind             -- focus is on the window BEHIND the popup
    CURSOR = { x = 1200, y = 400 } -- ...while the pointer is on the popup
    local list = play(600, 700, popup) -- popup followed to y=700 (> a quarter)
    report(list)
    local focusAt, closeAt, moveAt
    for i, d in ipairs(list) do
        if not focusAt and d:find("window=MediaPopup") then focusAt = i end
        if not moveAt and d:find("window%.move") then moveAt = i end
        if d:find("window%.close") then closeAt = closeAt or i end
        if d:find("window=Brave") then fail("the window BEHIND was aimed at: " .. d) end
    end
    if not focusAt then fail("the popup under the pointer was never focused") end
    if not closeAt then fail("nothing was closed by a quarter-screen swipe") end
    if focusAt and moveAt and moveAt < focusAt then
        fail("the drag started on the window BEHIND the popup")
    end
    if focusAt and closeAt and closeAt < focusAt then
        fail("closed before the pointer's window was focused")
    end
    print("   targeted: " .. tostring(focusAt ~= nil) .. ", closed the popup: "
        .. tostring(closeAt ~= nil))
    WINDOWS, CURSOR = nil, nil
end)

-- 8. FAIL OPEN: an unreadable pointer leaves the gesture exactly as it was --
--    the FOCUSED window is dismissed. A pointer read that cannot be made is
--    not allowed to turn the swipe into a no-op or to grab something else.
check("LONG swipe with NO pointer reading (falls back to the focused window)", function()
    ACTIVE = win({ address = "0xfocus", class = "Freebuff", fullscreen = 0,
                   floating = false, workspace = { id = 1 } })
    WINDOWS, CURSOR = nil, nil
    local list = play(600, 300)
    report(list)
    local closed = false
    for _, d in ipairs(list) do
        if d:find("window%.close") then closed = true end
    end
    if not closed then fail("an unreadable pointer stopped the close") end
end)

-- 9. A window on ANOTHER workspace is never the target, however neatly its
--    old rect contains the point: hidden workspaces keep their geometry, and a
--    swipe must never reach through the desktop to a window that is not on
--    screen. With nothing of the current workspace under the pointer, the
--    gesture falls back to the focused window -- as it always did.
check("LONG swipe with the pointer over a window that lives on ANOTHER workspace", function()
    ACTIVE = win({ address = "0xhere", class = "Freebuff", fullscreen = 0,
                   floating = false, workspace = { id = 1 } })
    local elsewhere = win({ address = "0xthere", class = "TradingView", fullscreen = 0,
                            floating = true, workspace = { id = 5 },
                            at = { x = 0, y = 0 }, size = { x = 1200, y = 900 } })
    WINDOWS = { ACTIVE, elsewhere }
    CURSOR = { x = 400, y = 300 } -- inside BOTH rects
    local list = play(600, 300)
    report(list)
    local closed = false
    for _, d in ipairs(list) do
        if d:find("window=TradingView") then fail("reached a window on another workspace: " .. d) end
        if d:find("window%.close") then closed = true end
    end
    if not closed then fail("the focused window was not dismissed") end
    WINDOWS, CURSOR = nil, nil
end)

-- 10. A SHELL POPUP is in front (2026-10-27): the four-finger swipe DOWN must
--     ask the SHELL to close it (`quickshell:popupDismiss`) and must touch no
--     window at all. This is the reported case -- "popup windows like
--     taskmanager etc are still not being closed when having them open in the
--     front": the popup is a layer surface, and grabbing the window behind it
--     is what the gesture used to do instead.
--
--     The popup state is a file the shell writes; the check writes the same
--     file. Run this with a scratch XDG_RUNTIME_DIR so it cannot disturb a live
--     session (the compositor reads the very same path).
check("LONG swipe while a shell popup is up", function()
    ACTIVE = win({ address = "0xbehind2", class = "Brave", fullscreen = 0,
                   floating = false, workspace = { id = 1 } })
    local path = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/ii-popup-open.json"
    local f = assert(io.open(path, "w"))
    f:write('{"open":true,"ts":' .. tostring(os.time()) .. '}')
    f:close()
    local list = play(600)
    os.remove(path)
    report(list)
    local asked, touched = false, false
    for _, d in ipairs(list) do
        if d:find("popupDismiss") then asked = true end
        if d:find("window%.") then touched = true end
    end
    if not asked then fail("the shell was never asked to close its popup") end
    if touched then fail("a window was grabbed while a popup was in front: " .. tostring(touched)) end
end)

-- 11. ...and a STALE popup file must not take the gesture away from windows:
--     a crashed shell leaves a file behind, and the close-drag has to keep
--     working. Same 10s staleness rule as every other handshake here.
check("LONG swipe with a STALE popup state file", function()
    ACTIVE = win({ address = "0xstale", class = "Freebuff", fullscreen = 0,
                   floating = false, workspace = { id = 1 } })
    local path = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/ii-popup-open.json"
    local f = assert(io.open(path, "w"))
    f:write('{"open":true,"ts":' .. tostring(os.time() - 60) .. '}')
    f:close()
    local list = play(600, 300)
    os.remove(path)
    report(list)
    local asked, closed = false, false
    for _, d in ipairs(list) do
        if d:find("popupDismiss") then asked = true end
        if d:find("window%.close") then closed = true end
    end
    if asked then fail("a stale popup file still stole the swipe") end
    if not closed then fail("a stale popup file stopped the window close") end
end)

print("")
if FAILED == 0 then
    print("PASS: fullscreen drags follow the fingers and come back; short swipes touch nothing")
    os.exit(0)
end
io.stderr:write(("FAILED: %d assertion(s)\n"):format(FAILED))
os.exit(1)
