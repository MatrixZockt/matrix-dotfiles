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
-- Then the window half was floating: float + move-to-origin + resize-to-the-
-- monitor (proven live, [0,0] 1707x1067). That geometry is still exact and it
-- is what legacyCover() below does, but its MOTION was wrong, and the motion
-- is what this file changed for on 2026-10-11:
--
--   * a window dispatcher that sets a floating window's box is applied by the
--     compositor with NO animation. Measured twice over: with every animation
--     leaf slowed to ~2.5s (10x), the covering window's top edge still went
--     from its tile (y=75 physical) to y=0 in a single captured frame --
--     there was no intermediate frame to capture. `misc:animate_manual_resizes`
--     is false on this build and turning it on changed nothing;
--   * everything ARRIVING at the transition still animated -- the neighbours'
--     reflow into the freed slot is ~275ms of eased motion (measured). So the
--     covering window teleported while the rest of the desktop glided around
--     it, which is exactly the "half laggy" report and the reason for this
--     rewrite.
--
-- The working mechanism now is the compositor's OWN expanded state, asked for
-- the internal half only:
--
--     hl.dsp.window.fullscreen_state({ internal = 2, client = 0, action = "set" })
--
-- `client = 0` is the whole point, and it is what the float cover was invented
-- for: the window fills the monitor (internal fullscreen) while the app is
-- never told it is fullscreen, so Chromium keeps its tab strip. Measured
-- afterwards: at=[0,0] size=[1707,1067] fs=2 fullscreenClient=0.
--
-- It also fixes the motion, because a fullscreen window is a LAYOUT change and
-- this compositor animates layout changes (that is the same path that made the
-- neighbours glide all along). Measured on this machine with the same harness
-- that exposed the teleport: the top edge now sweeps 56/17/8/3/1/0 over ~310ms
-- going in, and 20/49/57/62/67/70/72/73/74/75 over ~440ms coming out -- one
-- eased move per direction, played by the compositor, with the neighbours
-- covered and restored inside the same animation. Nothing is hand-played and
-- no per-frame dispatch is issued.
--
-- `action = "set"` and not "toggle" so entering is deterministic; measured,
-- "unset" is a NO-OP on this build (accepted, does nothing), so the way out is
-- the toggle with both halves zero -- see exit().
--
-- What this retires: the pre-cover geometry memory is no longer needed to put
-- the window back, because the tiler never lost it -- un-fullscreening lands
-- the window in the tile (or the floating geometry) it had, measured. The
-- memory stays for two reasons: it marks the window as OURS for the sweep and
-- the drift repair, and it is what restores a window covered by an OLDER
-- version of this module (a full-monitor float, fs == 0). legacyCover() is
-- kept for the same two cases plus the one real fallback: a window that
-- refuses the fullscreen request must still be able to fill the screen.
--
-- ═══ The bar is NOT told anything any more (2026-10-14) ═══════════════════
--
-- Every enter/exit here used to ask the shell for the bar's strip over
-- `qs -c ii ipc call barCover onCover <on> <addr>`. That call is GONE, and it
-- was pure cost:
--
--   * IT SPAWNED A PROCESS ON THE KEYPRESS PATH. `qs` is the whole Qt client
--     binary, so each request meant a fresh process loading Qt to deliver two
--     strings. Measured on this machine: 89ms wall, 78% of a core, twice per
--     toggle (enter and exit) -- CPU burned *underneath* the transition it was
--     meant to serve.
--
--   * IT CHANGED NOTHING. The bar's exclusive zone stopped answering to this
--     request long ago: measured, handing the zone back while a cover was up
--     moved the covering window by zero pixels and moved every OTHER window
--     45px, so the zone now follows auto-hide alone (see Bar.qml's
--     `exclusiveZone`). The flag's one remaining consumer was the bar's
--     hide decision -- and that is DERIVED, from the same window list the bar
--     already watches: `fullscreenOnMonitor` for the internal-fullscreen
--     cover this module creates, `coverByGeometry` for the old float+pin one.
--
--     Verified both ways on this machine, reading the bar's own state with the
--     request never sent: an internal-fullscreen cover reads `barHidden=true`,
--     and a float pinned to the monitor (1707x1067 @ 1,1, the legacy shape)
--     reads `barHidden=true` too -- identical to the same window covered
--     through this module with the request in place.
--
-- What that removes is not only the CPU: the spawn was long enough for focus
-- to leave the window being expanded before the geometry dispatch landed
-- (the reason focusAddr() below exists), and it landed the bar's own state
-- change in the middle of the compositor's transition. The transition is now
-- the only thing happening.

local M = {}

-- Per-window pre-cover state, keyed by address -- NOT one shared slot.
-- A single M.remember meant cover A, then cover B, then exit A restored A's
-- pixels with B's memory (or nothing at all): exactly the 'exit leaves the
-- window wrong' reported when covering several windows in a row.
-- The table itself MUST exist here: when this was refactored from the single
-- slot, the initialisation was dropped with it, and enter() then wrote into a
-- nil table -- throwing AFTER the save and BEFORE the
-- window was expanded. Covering died silently, and the state it left read as
-- "a cover that was never entered".
M.remember = M.remember or {}

-- (A `shellConfig`/`qsConfig` read lived here too, for the shell call above.
-- Nothing in this module talks to the shell any more, so it is gone with it --
-- a stale `qsConfig` here would only invite the call back.)

local function trace(msg)
    local f = io.open("/tmp/hypr-cover.log", "a")
    if f then f:write(os.date("%H:%M:%S ") .. msg .. "\n"); f:close() end
end

-- (The `barCover` request and its public `M.barStrip` wrapper used to live
-- here: one hl.dispatch of an exec_cmd that ran
--
--     qs -c <config> ipc call barCover onCover <on> <addr>
--
-- on every enter and every exit -- a full Qt process per toggle, for a strip
-- the bar no longer ties to this request. See the header. There is now no
-- channel from this module to the shell at all, and none is needed: the shell
-- derives "a window is covering the screen" from its own window list, which is
-- the same authority it already uses for real fullscreen.)

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
-- marker is gone, so the geometry IS the marker. It is also what the SHELL
-- reads now -- the bar decides whether to get out of the way from the same
-- predicate, on its own window list (modules/ii/bar/Bar.qml's
-- `coverByGeometry`), which is why no request crosses between the two any
-- more.
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
-- The cost was not cosmetic, and it is worth keeping because the shape of it
-- outlived the mechanism. Exiting a cover used to ask the shell to hand the
-- bar's strip back -- and it asked only when it found no OTHER cover, so a
-- window that merely LOOKED like one held the strip away from a real exit.
-- A parked, invisible Thunderbird was such a window: it meant the strip was
-- never returned. That is verbatim in the trace, twice in the same minute, on
-- a real Firefox exit:
--
--     22:22:39 exit 0x558da645e7a0 (strip held: another cover)
--     22:22:45 exit 0x558da645e7a0 (strip held: another cover)
--
-- With the strip held, the bar never took its exclusive zone back, the
-- workarea stayed wrong, and the window re-tiled underneath the bar -- which
-- was the reported symptom, verbatim.
--
-- The strip request itself is gone now (see the header), so that particular
-- stranding cannot happen again; what survives is the reason this predicate
-- has to tell a PARKED window from a covering one. The sweep and the drift
-- repair below still walk every window through it.
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

-- Focus a window by address, as a WINDOW OBJECT. The window dispatchers on
-- this build act on the focused window and ignore an `address` argument (see
-- the long note in custom/general.lua), so anything that resizes or expands a
-- window has to take focus first -- and the cover does, because focus is not
-- ours to assume: a notification, a click or another gesture can move it
-- between the keypress and the dispatch, and an expansion that lands on a
-- different window expands that one instead.
--
-- (The other reason focus had to be retaken -- the bar's strip request
-- spawning a `qs` process that outlasted the keypress -- went with the
-- request itself; see the header.)
local function focusAddr(addr)
    local w = liveWindow(addr)
    if not w then return nil end
    hl.dispatch(hl.dsp.focus({ window = w }))
    return w
end

-- The pre-2026-10-11 way to fill the screen: float the window (action = "set",
-- so an already-floating window is not toggled back to tiled), then pin it to
-- the monitor's logical rect. The geometry is exact and it holds -- a window
-- floated by dispatch stays floated -- but the compositor applies it with no
-- animation (see the header), so this is now only:
--   * the fallback when a window refuses the fullscreen request, and
--   * the way a window covered by an OLDER version of this module is put back.
local function legacyCover(addr)
    local w = liveWindow(addr)
    if not w then return false end
    local lw, lh, mx, my = logicalMonitor(w)
    focusAddr(addr)
    hl.dispatch(hl.dsp.window.float({ action = "set", address = addr }))
    local function pin()
        local cur = liveWindow(addr)
        if not (cur and cur.floating) then
            hl.dispatch(hl.dsp.window.float({ action = "set", address = addr }))
        end
        hl.dispatch(hl.dsp.window.move({ x = mx, y = my, address = addr }))
        hl.dispatch(hl.dsp.window.resize({ x = lw, y = lh, address = addr }))
    end
    pin()
    -- The float read can lag; retry the pin once a frame later if the first
    -- landed on a window the tiler had not yet released. (Same pattern as
    -- closeDrag's refloat in custom/general.lua.)
    hl.timer(function()
        local cur = liveWindow(addr)
        -- Only re-pin if the geometry did not land: a second pin on a window
        -- that already covers the screen is invisible, but a pin that fires
        -- after the user LEFT cover (exit ran, window re-tiled) would yank it
        -- back out of its tile.
        if not (cur and cur.floating) then return end
        if cur.at and cur.size
            and cur.at.x == mx and cur.at.y == my
            and cur.size.x == lw and cur.size.y == lh then
            return
        end
        if (cur.fullscreen or 0) ~= 0 then return end
        hl.dispatch(hl.dsp.window.move({ x = mx, y = my, address = addr }))
        hl.dispatch(hl.dsp.window.resize({ x = lw, y = lh, address = addr }))
    end, { timeout = 60, type = "oneshot" })
    return true
end

-- Take the window over the screen. `w` is a window object (from
-- hl.get_active_window() or a hl.get_windows() entry), never a selector:
-- selectors throw on this build, and a throw inside a gesture callback
-- silently aborts the whole gesture.
function M.enter(w)
    if not w or not w.address then return false end
    local addr = w.address

    -- Remember the pre-cover state. Exit no longer needs it to place the
    -- window (the compositor restores the tile itself), but the sweep and the
    -- drift repair use the memory to tell a live cover from leftover churn,
    -- and legacyCover() restores from it. Read BEFORE any dispatch.
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

    -- ONE dispatch: the compositor's own expanded state, internal half only.
    -- The app is not told anything (client = 0), and because the window's box
    -- now changes as a LAYOUT change the compositor animates it -- see the
    -- header for the measurements.
    focusAddr(addr)
    hl.dispatch(hl.dsp.window.fullscreen_state({
        internal = 2, client = 0, action = "set" }))

    -- One beat later, check that it took. A window that refuses the request
    -- (a rule, a client that will not resize) has to be able to fill the
    -- screen anyway, so the old float+pin is kept for exactly that case.
    hl.timer(function()
        -- Only while this cover is still OURS. exit() drops the memory, so a
        -- window deliberately taken back out of the cover inside this 60ms beat
        -- must not be read as "it refused the request" -- without this test the
        -- timer floats and pins a window the user has already restored, leaving
        -- a monitor-sized float that no later call can tell from a real cover
        -- (the geometry IS the marker for a float cover).
        --
        -- A hand cannot exit inside 60ms; a script that drives enter and then
        -- exit (a test harness, a recovery script) can, and this fired four
        -- times in one measurement run -- "fullscreen refused" in the log, for a
        -- window that had simply been let go a beat earlier.
        if not (M.remember and M.remember[addr]) then return end
        local now = liveWindow(addr)
        if now == nil then return end
        if (now.fullscreen or 0) ~= 0 then return end
        trace("enter " .. tostring(addr) .. ": fullscreen refused, float+pin fallback")
        legacyCover(addr)
    end, { timeout = 60, type = "oneshot" })
    trace("enter " .. tostring(addr) .. " internal fullscreen @"
        .. tostring(mx) .. "," .. tostring(my) .. " " .. tostring(lw) .. "x" .. tostring(lh)
        .. " wasFloating=" .. tostring(M.remember[addr].wasFloating))
    return true
end

-- Put it back. `w` may be nil if the window has already gone; that is then a
-- no-op, and the safe direction -- the bar is not left yielded for a window that
-- no longer exists, because it follows the window list rather than a request
-- (see the header), so a vanished window clears the cover by itself.
function M.exit(w)
    local addr = w and w.address or nil
    local mem = addr and M.remember and M.remember[addr] or nil
    if w and addr then
        -- Leave the expanded state first. TWO shapes of it, and they need
        -- different doors off the screen:
        --
        --   * a window the APP put in fullscreen (or SUPER+ALT+F's spoof): the
        --     client half has to be handed back explicitly, with the mode the
        --     window actually has -- toggling "fullscreen" on a maximized
        --     window would stack a real fullscreen on top of the maximize.
        --     Unchanged from before this rewrite.
        --
        --   * OUR cover: internal fullscreen with the client never told
        --     (fs == 2, fullscreenClient == 0). That is ONE dispatch, and the
        --     compositor plays the whole way back itself -- landing the window
        --     in the tile (or the floating geometry) it had before, in one
        --     eased move. This is the exit half of "one clean transition";
        --     nothing here is hand-played. The toggle with BOTH halves zero is
        --     this build's way out (`action = "unset"` is accepted and does
        --     nothing -- measured).
        if (w.fullscreen or 0) == 2 then
            if (w.fullscreenClient or 0) ~= 0 then
                hl.dispatch(hl.dsp.window.fullscreen({
                    mode = "fullscreen", action = "toggle", address = addr }))
            else
                focusAddr(addr)
                hl.dispatch(hl.dsp.window.fullscreen_state({
                    internal = 0, client = 0, action = "toggle" }))
            end
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
    -- Nothing to hand back to the bar: it follows the window list, so the
    -- strip (and the slide, and the edge-reveal) are already answered for this
    -- window the moment it stops covering. The walk that used to sit here --
    -- "hold the strip if another window is still covering" -- existed to
    -- decide whether to send that request, and went with it: two covered
    -- windows now yield nothing between them at all.
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

-- Is this window in the compositor-side expanded state THIS module creates --
-- fullscreen for the compositor, an ordinary resize for the app? That is
-- fs == 2 with NO client-side fullscreen (fullscreenClient == 0), and it is
-- the test custom/general.lua's four-finger-up needs to route the exit: our
-- cover leaves through M.exit (ONE dispatch, animated by the compositor),
-- while a window the APP fullscreened has a client-side state to hand back and
-- keeps its own path (anchoredTransition). Both doors must never fire for the
-- same window -- the old code chose by `fs ~= 0`, which sent our cover into the
-- hand-played glide and would have stacked a client fullscreen on top of it.
function M.isInternalCover(w)
    return w ~= nil and (w.fullscreen or 0) == 2
        and (w.fullscreenClient or 0) == 0
end

-- "Can this window be seen covering the screen at all?" -- exported because
-- custom/general.lua's sweep has to ask the same question about windows OUTSIDE
-- this module's memory (it drops stale memories for parked windows), and the
-- vault predicate must have one definition, not two. Same reasoning as owns():
-- a special workspace is parking, not covering.
M.canCoverScreen = canCoverScreen

-- Drop a window's remembered pre-cover state.
--
-- The caller is the compositor sweep in custom/general.lua, once per pass, for
-- windows that have been PARKED (special:tray -- see TrayApps.qml's vault):
-- parking is what a close-to-tray app's close does, and the vault un-floats a
-- window on the way back out, so the cover the memory describes is gone. Left
-- in place it is not merely stale but actively wrong -- owns() reads the
-- MEMORY as the truth, so the next SUPER+F was read as "exit that cover" and
-- the window did not fill the screen until the press after that. That is the
-- tray half of "I can't put this app in fullscreen".
-- Accepts a window object or a bare address, so callers need not look one up.
function M.forget(w)
    local addr = type(w) == "table" and w.address or w
    if addr and M.remember then M.remember[addr] = nil end
end

return M
