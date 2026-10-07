-- "Fills the screen" -- the window covers the whole monitor edge to edge
-- WITHOUT the app being told it is fullscreen, so a browser keeps its tabs.
--
-- Why this is a module and not a line in each caller: it is wanted by two
-- different entry points (SUPER+F in custom/keybinds.lua and the four-finger
-- swipe up in custom/general.lua), and the whole point of the fix is that the
-- bar's half and the window's half are ONE action. Split across two files they
-- would be two toggles that could disagree.
--
-- ══ How the window half works, and why it changed ═══════════════════════
--
-- It used to be `mode = "maximized"`. Measured on this build, a maximized
-- window is laid out inside the workarea WITH general:gaps_out applied to all
-- four sides: on the 1600x1000 logical panel it landed at [5,5] 1590x990 (with
-- the bar's strip returned, [5,50] 1590x945). Those five logical pixels on
-- every side are the "small border showing the background" report -- and
-- move/resize dispatches are ignored on a tiled-maximized window, so the gaps
-- cannot be closed by shifting it afterwards.
--
-- The working mechanism (proven live on this machine, [0,0] 1600x1000):
--
--   1. float the window (action = "set", so an already-floating window is
--      untouched rather than toggled back to tiled);
--   2. move it to the monitor's logical origin and resize it to the monitor's
--      full LOGICAL size (monitor.width/height are PHYSICAL on this build --
--      divide by scale, see the closeDrag code in custom/general.lua);
--   3. remember what the window was BEFORE floating (tiled or floating, and
--      the floating geometry), so exit can put every pixel back.
--
-- Floating is what makes the compositor respect exact pixel geometry. The
-- window is never given the fullscreen state: fs stays 0, Chromium keeps its
-- tab strip, and the shell's barCover flag is what hides the bar.
--
-- The catch-all `float = false` rule in custom/rules.lua re-asserts itself on
-- state changes for RULE-MATCHED windows, but empirically a window floated by
-- dispatch STAYS floating (verified: float -> move -> resize all landed and
-- held), so no rule interaction needs handling here.
--
-- Exit reverses: unfloat first (restore happens inside that toggle -- a
-- floating->tiled toggle re-tiles into the split), then re-assert the
-- remembered floating state if the window was floating before, and only then
-- give the bar's strip back -- and ONLY then if no OTHER window is still
-- covering: two windows can be covered at once (cover one, switch workspace,
-- cover another), and handing the strip back under the second would push a
-- covered window out of its edge-to-edge geometry.

local M = {}

-- Per-window pre-cover state, keyed by address -- NOT one shared slot.
-- A single M.remember meant cover A, then cover B, then exit A restored A's
-- pixels with B's memory (or nothing at all): exactly the 'exit leaves the
-- window wrong' reported when covering several windows in a row.
-- The table itself MUST exist here: when this was refactored from the single
-- slot, the initialisation was dropped with it, and enter() then wrote into a
-- nil table -- throwing AFTER the bar had been told to hide and BEFORE the
-- window was floated. Covering died silently and the bar strip leaked.
M.remember = M.remember or {}

local shellConfig = os.getenv("qsConfig") or "ii"

local function trace(msg)
    local f = io.open("/tmp/hypr-cover.log", "a")
    if f then f:write(os.date("%H:%M:%S ") .. msg .. "\n"); f:close() end
end

-- Ask the shell to release (or take back) the bar's strip, naming the window
-- it is acting on so the bar can spot it disappearing underneath it.
--
-- The handler is called by its FULL name, `onCover`. This build's IPC does not
-- strip the `on` prefix the way the docs describe -- `ipc call barCover cover`
-- answers "Function not found" and only `... onCover` lands -- and a bar that
-- silently never yields its strip is the exact bug this module exists to fix,
-- so the call is spelled the way that provably works here.
local function barCover(on, address)
    hl.dispatch(hl.dsp.exec_cmd(
        "qs -c " .. shellConfig .. " ipc call barCover onCover "
            .. (on and "true" or "false") .. " " .. tostring(address or "")))
end

-- Yield (or take back) the bar's strip for a window WITHOUT changing that
-- window's own state. Kept as the module's public half so the four-finger-up
-- swipe in custom/general.lua can release the strip for its own flow -- see
-- its comments for why that gesture asks for the strip alone.
function M.barStrip(address, on)
    barCover(on, address)
end

-- The window's monitor, in LOGICAL pixels -- the units the move/resize
-- dispatchers work in. Falls back to the panel's known values if the monitor
-- object is missing, so a transient read never leaves a window half-shifted.
--
-- The fallback scale was 1.6, a leftover from when this machine ran at 160%.
-- It is now 1.5, the same default custom/general.lua owns, so the two files
-- cannot disagree about the machine's scale. The disagreement was not
-- cosmetic: this fallback exists for exactly the case where the monitor read
-- fails, and at 1.6 the logical work area computes to 1600x1000 instead of
-- the real 1707x1067 -- a window moved on that path would land 107px short
-- and 67px high, off the layout rather than merely the wrong size. Matching
-- the real default is what makes the fallback safe rather than merely present.
local function logicalMonitor(w)
    local mon = w and w.monitor
    local scale = (mon and mon.scale) or 1.5
    if not scale or scale <= 0 then scale = 1 end
    local lw = math.floor(((mon and mon.width) or 2560) / scale + 0.5)
    local lh = math.floor(((mon and mon.height) or 1600) / scale + 0.5)
    local mx = (mon and mon.x) or 0
    local my = (mon and mon.y) or 0
    return lw, lh, mx, my
end

-- Re-read a window by address; geometry work is only safe against a live
-- object (the read can lag the dispatch queue -- see closeDrag in
-- custom/general.lua for the same retry pattern).
local function liveWindow(addr)
    for _, w2 in ipairs(hl.get_windows() or {}) do
        if w2.address == addr then return w2 end
    end
    return nil
end

-- Is the given window currently in the covering state? A real fullscreen
-- window (fs == 2, the app's own F11) also counts: exiting handles both.
-- Declared before enter/exit, which consult it.
local function isCovering(w)
    return w ~= nil and (w.fullscreen or 0) ~= 0
end

-- "Covering" means: real fullscreen (fs ~= 0), OR a floating window that
-- fills its monitor (the state this module creates). The second test is
-- what makes SUPER+F a clean toggle after the redesign: the maximized
-- marker is gone, so the geometry IS the marker. Defined before exit, whose
-- strip guard walks every window through it.
--
-- The geometry test allows a small tolerance, and it has to. Hyprland does
-- not hand back the exact position that was dispatched for a float: a
-- window moved to (0,0) reads back as (1,1), because the float rules put
-- one logical pixel between a window and the screen edge. An exact
-- comparison therefore reported a full-screen float as NOT covering, and
-- every "go out" gesture took the "go in" branch instead -- swipe up to
-- leave fullscreen, and the window was covered again instead of restored,
-- which reads as the gesture doing nothing. Verified on this machine: the
-- covered kitty sits at 1,1 sized 1600x1000 on a 1600x1000 logical screen.
--
-- The tolerance is small (2 logical px) and applies to every edge, so a
-- window that is merely LARGE is still not mistaken for a cover -- a real
-- tiled or maximized window is always inset by far more than that.
local COVER_EPS = 2

local function near(a, b)
    return math.abs((a or 0) - (b or 0)) <= COVER_EPS
end

-- Can this window be SEEN covering the screen at all?
--
-- Added 2026-09-30, and it is the fix for "coming out of fullscreen does not
-- attach properly -- it shows in the top bar and everything". The geometry
-- test below cannot tell a VISIBLE full-screen float from a window that is
-- merely full-screen SIZED, and this desktop has a standing example of
-- exactly the wrong kind:
--
--     org.mozilla.Thunderbird  ws=special:tray  flt=true  at=(-1,-1)  1600x1000
--
-- That is the parked Thunderbird from the tray guard (services/TrayApps.qml
-- -- it is hidden by parking it on a special workspace, not by unmapping it).
-- It floats, it is exactly the monitor's logical size, and at (-1,-1) it is
-- inside COVER_EPS of the monitor origin -- so isCoverState() called it a
-- live cover, permanently, no matter what the user did.
--
-- The cost was not cosmetic. M.exit() walks every window to decide whether
-- the bar's strip can go back, and it holds the strip when it finds another
-- cover. A parked, invisible Thunderbird meant it ALWAYS found one, so the
-- strip was never returned. That is verbatim in the trace, twice in the same
-- minute, on a real Firefox exit:
--
--     22:22:39 exit 0x558da645e7a0 (strip held: another cover)
--     22:22:45 exit 0x558da645e7a0 (strip held: another cover)
--
-- With the strip held, the bar never takes its exclusive zone back, the
-- workarea stays wrong, and the window re-tiles underneath the bar -- which
-- is the reported symptom, verbatim.
--
-- So a window has to be VISIBLE to count as covering. Both of these are
-- parking, not covering:
--   * a special workspace (id < 1): the minimized/hidden store, which is
--     where TrayApps parks a window it does not want on screen;
--   * a window the compositor itself reports hidden.
-- A real cover is always on a normal, visible workspace -- it is covering
-- the screen the user is looking at, so that is the only place it can be.
local function canCoverScreen(w)
    if w.hidden == true then return false end
    local ws = w.workspace
    if ws ~= nil and (ws.id or 1) < 1 then return false end
    return true
end

local function isCoverState(w)
    if w == nil then return false end
    if not canCoverScreen(w) then return false end
    if (w.fullscreen or 0) ~= 0 then return true end
    if not w.floating then return false end
    local lw, lh, mx, my = logicalMonitor(w)
    local at, size = w.at, w.size
    if at == nil or size == nil then return false end
    return near(at.x, mx) and near(at.y, my)
        and near(size.x, lw) and near(size.y, lh)
end

-- Debounce for the cover toggle. Synthetic and held keypresses repeat
-- (~3 events per press), and the second event would otherwise enter AND exit
-- in the same breath -- landing the window wherever the interrupted cycle
-- left it.
--
-- The clock: os.clock() is CPU TIME, not wall time -- between two keypresses
-- on an idle desktop it advances by microseconds, so a millisecond window
-- built on it never expired and every second SUPER+F on the same window was
-- swallowed forever ("returning from fullscreen stopped working"). Wall-clock
-- time in plain Lua is os.time(), with one-second resolution -- which is
-- exactly right for repeat suppression: repeats land within milliseconds, so
-- "same address, same wall-clock second" drops them, while any deliberate
-- second press a moment later passes.
local lastToggle = { addr = nil, sec = 0 }

local function toggledTooSoon(addr)
    local now = os.time()
    if lastToggle.addr == addr and now == lastToggle.sec then
        return true
    end
    lastToggle.addr = addr
    lastToggle.sec = now
    return false
end

-- Take the window over the screen. `w` is a window object (from
-- hl.get_active_window() or a hl.get_windows() entry), never a selector:
-- selectors throw on this build, and a throw inside a gesture callback
-- silently aborts the whole gesture.
function M.enter(w)
    if not w or not w.address then return false end
    local addr = w.address
    -- The bar first, always: its strip is what the window is about to cover.
    M.barStrip(addr, true)

    -- Remember the pre-cover state so exit can restore it exactly. A tiled
    -- window must come back tiled AT ITS OLD TILE; a floating one must come
    -- back floating at its old geometry. Read BEFORE any dispatch.
    local lw, lh, mx, my = logicalMonitor(w)
    -- Geometry reads: this build exposes position/size as POINT OBJECTS
    -- (w.at.x, w.size.x -- the same shape closeDrag in general.lua reads),
    -- NOT arrays. Indexing w.at[1] read nil and silently broke every
    -- comparison below.
    local atX = (w.at and w.at.x) or nil
    local atY = (w.at and w.at.y) or nil
    local szW = (w.size and w.size.x) or nil
    local szH = (w.size and w.size.y) or nil
    M.remember[addr] = {
        addr = addr,
        wasFloating = (w.floating and true) or false,
        -- Floating windows: their current geometry is what restore re-asserts.
        fx = atX, fy = atY, fw = szW, fh = szH,
        -- Monitor the window was on, so a cover->switch->exit still restores
        -- against the right panel.
        mw = lw, mh = lh, mx = mx, my = my,
    }

    -- Float (set, not toggle: a floating window stays floating), then pin to
    -- the full monitor. Each dispatch is separate -- multi-statement evals
    -- have thrown in this build.
    hl.dispatch(hl.dsp.window.float({ action = "set", address = addr }))
    -- The float read can lag; retry the pin once a frame later if the first
    -- landed on a window the tiler had not yet released. (Same pattern as
    -- closeDrag's refloat in custom/general.lua.)
    local function pin()
        local now = liveWindow(addr)
        if not (now and now.floating) then
            hl.dispatch(hl.dsp.window.float({ action = "set", address = addr }))
        end
        hl.dispatch(hl.dsp.window.move({ x = mx, y = my, address = addr }))
        hl.dispatch(hl.dsp.window.resize({ x = lw, y = lh, address = addr }))
    end
    pin()
    hl.timer(function()
        local now = liveWindow(addr)
        -- Only re-pin if the geometry did not land: a second pin on a window
        -- that already covers the screen is invisible, but a pin that fires
        -- after the user LEFT cover (exit ran, window re-tiled) would yank it
        -- back out of its tile.
        if not (now and now.floating) then return end
        if now.at and now.size
            and now.at.x == mx and now.at.y == my
            and now.size.x == lw and now.size.y == lh then
            return
        end
        -- Still floating but not yet at the target: land it.
        if (now.fullscreen or 0) ~= 0 then return end
        hl.dispatch(hl.dsp.window.move({ x = mx, y = my, address = addr }))
        hl.dispatch(hl.dsp.window.resize({ x = lw, y = lh, address = addr }))
    end, { timeout = 60, type = "oneshot" })
    trace("enter " .. tostring(addr) .. " -> " .. tostring(lw) .. "x" .. tostring(lh)
        .. " @" .. tostring(mx) .. "," .. tostring(my)
        .. " wasFloating=" .. tostring(M.remember[addr].wasFloating))
    return true
end

-- Put it back. `w` may be nil if the window has already gone; in that case
-- only the bar is released, which is the safe direction (the strip comes back,
-- the bar is visible, nothing is stuck).
function M.exit(w)
    local addr = w and w.address or nil
    local mem = addr and M.remember and M.remember[addr] or nil
    if w and addr then
        -- A real fullscreen window (fs == 2) cannot be un-floated; leave that
        -- state first with the mode it actually has.
        if (w.fullscreen or 0) == 2 then
            hl.dispatch(hl.dsp.window.fullscreen({
                mode = "fullscreen", action = "toggle", address = addr }))
        end
        if mem and mem.addr == addr then
            if not mem.wasFloating then
                -- Tiled before: un-float. The toggle re-tiles into the split;
                -- the tiler remembers the window's old tile by itself.
                local now = liveWindow(addr)
                if now and now.floating then
                    hl.dispatch(hl.dsp.window.float({ action = "toggle", address = addr }))
                end
            else
                -- Floating before: put the exact geometry back.
                if mem.fx and mem.fy then
                    hl.dispatch(hl.dsp.window.move({ x = mem.fx, y = mem.fy, address = addr }))
                end
                if mem.fw and mem.fh then
                    hl.dispatch(hl.dsp.window.resize({ x = mem.fw, y = mem.fh, address = addr }))
                end
            end
        else
            -- No memory (cover started before this module loaded, or the
            -- window was covered by something else): fall back to un-float,
            -- the safe direction -- re-tile if it was tiled before, stay put
            -- if it was genuinely floating.
            local now = liveWindow(addr)
            if now and now.floating and not (mem and mem.wasFloating) then
                hl.dispatch(hl.dsp.window.float({ action = "toggle", address = addr }))
            end
        end
    end
    if M.remember then M.remember[addr] = nil end
    -- Hand the strip back only when nothing else is covering. The bar is a
    -- shared resource: two windows can be covered at once (cover one, switch
    -- workspace, cover another), and returning it under the second would push
    -- a covered window out of its edge-to-edge geometry. Without a remembered
    -- state, treat a full-monitor float as covering (the geometry IS the
    -- marker; see isCoverState).
    for _, w2 in ipairs(hl.get_windows() or {}) do
        if w2.address ~= addr and isCoverState(w2) then
            trace("exit " .. tostring(addr) .. " (strip held: another cover)")
            return
        end
    end
    M.barStrip(addr or "", false)
    trace("exit " .. tostring(addr))
end

-- Toggle, deciding from the window's CURRENT state rather than from a flag
-- kept here. A flag would drift the moment anything else changed the window's
-- state -- the app's own fullscreen button, a workspace switch, the window
-- closing -- and the bar would then be yielded for a window that is not
-- covering anything, or a bordered window with its bar still reserved.
--
-- Self-heal: exit every window that FLOATS at the monitor's full size but
-- has no remembered pre-state. Created for recovery after external churn --
-- a stuck CLI experiment, a crash mid-cover, a shell reload -- that leaves
-- windows floating full-screen with nothing able to reach the module's exit
-- through its normal entry points. POSITION is deliberately ignored (a churned
-- window is rarely still at [0,0]); a window WITH a remembered state is left
-- alone: it is a genuine, live cover. A user's own floating window at exactly
-- the monitor size is the one false positive possible -- it re-tiles once per
-- reload, which is the cheap direction to be wrong in.
-- Returns the number of windows exited. Safe at any time: a clean desktop
-- yields 0 and touches nothing.
-- "Is this window one this module is responsible for putting back?"
--
-- isCoverState() alone answers "does it LOOK like a cover right now", which
-- is the wrong question for the exit paths. The geometry is only a proxy for
-- the remembered state, and the proxy fails the moment anything moves the
-- window: isCoverState() goes false, the toggle reads that as "never covered",
-- and calls enter() -- which re-floats the window instead of restoring it.
-- That is the whole of "it came out of fullscreen and now it is a popup that
-- will not attach no matter what I do".
--
-- The memory is the truth; the geometry is the fallback for a cover this
-- module never made (a window covered by something else, or before this
-- module loaded). A dragged window keeps its memory, so it stays ours.
local function ownsWindow(w)
    if w == nil or w.address == nil then return false end
    if M.remember and M.remember[w.address] then return true end
    return isCoverState(w)
end

-- Restore the covers this module is holding that have been MOVED, and only
-- those. Narrow on purpose, because unlike sweep() this runs on an ordinary
-- gesture rather than from a deliberate recovery keypress:
--
--   * ours only -- a window with no remembered state is never touched, so the
--     dialogs, panels and picture-in-picture this desktop floats on purpose
--     cannot be dragged into the layout by a workspace swipe;
--   * drifted only -- isCoverState() must be false, i.e. the window really
--     has been moved out from under the cover;
--   * on screen only -- canCoverScreen(), so a parked window is not hauled
--     out of its hiding place.
--
-- Returns how many were restored, so a caller can log or ignore.
function M.restoreDrifted()
    local n = 0
    for _, w in ipairs(hl.get_windows() or {}) do
        if M.remember and M.remember[w.address]
            and canCoverScreen(w) and not isCoverState(w) then
            M.exit(w)
            n = n + 1
        end
    end
    if n > 0 then
        trace("restoreDrifted " .. tostring(n) .. " window(s)")
    end
    return n
end

function M.sweep()
    -- Half one: windows OURS that have been moved. Handled by the same
    -- routine an ordinary gesture calls, so the two can never disagree about
    -- what "drifted" means.
    local n = M.restoreDrifted()
    -- Half two, unchanged: a window floating at exactly the monitor size that
    -- nothing here ever covered is leftover churn from outside the module,
    -- and re-tiling it is the sweep's original job.
    --
    -- Same visibility gate as isCoverState, and for a worse reason if it is
    -- left out: sweep's job is to RE-TILE what it finds, so a parked window
    -- swept in would be pulled out of its hiding place and dropped into the
    -- layout. The parked Thunderbird floats at exactly the monitor's logical
    -- size with no remembered state -- it matched this test on every single
    -- run.
    --
    -- Written as one `if` rather than an early `goto continue`, because a
    -- forward goto past a `local` declaration jumps into that local's scope,
    -- which is a hard compile error in Lua 5.2+ -- and this file is loaded on
    -- every boot, where a compile error takes the whole config with it.
    -- luajit accepted it; other builds would not.
    for _, w in ipairs(hl.get_windows() or {}) do
        if (not M.remember or not M.remember[w.address]) and canCoverScreen(w) then
            local lw, lh = logicalMonitor(w)
            local sz = w.size
            if w.floating and sz and sz.x == lw and sz.y == lh then
                M.exit(w)
                n = n + 1
            end
        end
    end
    trace("sweep exited " .. tostring(n) .. " window(s)")
    return n
end

-- Recovery from stale covers is bound to SUPER+ALT+SHIFT+S in
-- custom/keybinds.lua ("Unstick stale full-screen covers"). It must be a REAL
-- keypress: dispatches issued from config-load timers and from synthetic
-- injection were observed to be dropped on this build, while bind-context
-- dispatches from genuine input land reliably.

function M.toggle(w)
    if not w or not w.address then return false end
    -- Key repeat fires the bind ~3x per press; without this the second event
    -- enters what the first just exited (or vice versa) inside one hold.
    if toggledTooSoon(w.address) then return false end
    if ownsWindow(w) then
        M.exit(w)
        return false
    end
    return M.enter(w)
end

M.isCovering = isCoverState
-- For the callers that decide "go IN or come OUT". ownsWindow, NOT
-- isCoverState: a cover that has been dragged out of the monitor rect is
-- still a cover as far as the exit path is concerned, and reading it as
-- "not covering" there is what stranded it.
M.owns = ownsWindow

return M
