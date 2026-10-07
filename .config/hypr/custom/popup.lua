-- Shared desktop actions and fullscreen slot memory.
--
-- This file used to be the popup-app support for the settings and task
-- manager layer-shell overlays: presence files, bind guards, the veil and
-- the popup -> window morph. Those apps are ordinary desktop windows now
-- (settings.qml hosts both), so all of that machinery is retired -- the
-- compositor needs no help closing a real window. What remains here are the
-- things unrelated to popups that lived here and are still used:
--
--   showDesktop()      SUPER+D / 4-finger tap: jump to an empty desktop,
--                      second press comes back
--   desktopsOverview() SUPER+D's overview (see custom/keybinds.lua)
--   wallpaperCarousel()3-finger tap on an empty desktop
--   is_workspace_empty(id)
--   rememberSlot/slotOf/forgetSlot
--                      where a window sat before it went fullscreen, for the
--                      hand-played return transition (anchoredTransition in
--                      custom/general.lua)

local M = {}

-- ═══ Where a window was, before it went fullscreen ═════════
--
-- The way back OUT of fullscreen is a geometry change this build cannot
-- animate on its own (there is no `fullscreen` animation leaf), so it is played
-- by hand -- see anchoredTransition in general.lua. For that to land in the
-- right place, the transition has to know the slot the window occupied BEFORE
-- it went fullscreen: while it is fullscreen the tiler has no memory that can
-- be read back, and simply re-inserting the window lets the layout decide
-- again -- which is how "anchored" came back in a different place.
--
-- Remembered by address, on the way IN to fullscreen. Stale entries are
-- harmless (an address belongs to exactly one window) but the table is capped
-- so a long session cannot grow it without bound.
local slots = {}
local slotOrder = {}
function M.rememberSlot(w)
    if not w or not w.address or not w.at or not w.size then return end
    local addr = w.address
    if not slots[addr] then table.insert(slotOrder, addr) end
    slots[addr] = { x = w.at.x, y = w.at.y, w = w.size.x, h = w.size.y }
    while #slotOrder > 24 do
        local old = table.remove(slotOrder, 1)
        slots[old] = nil
    end
end

function M.slotOf(addr)
    if addr and slots[addr] then return slots[addr] end
    return nil
end

function M.forgetSlot(addr)
    slots[addr] = nil
end

-- ═══ Show desktop (SUPER+D, and the four-finger TAP) ═══════
--
-- "Minimize everything": jump to an empty desktop, and jump BACK on the second
-- press. Lived in custom/keybinds.lua for the key; the four-finger tap (the
-- touchpad's face for the same action -- the shell emits a `tap` phase and
-- runs this through its IPC) shares this one implementation, so the key and
-- the tap can never disagree about where "back" is.
local showDesktopPath = (os.getenv("HOME") or "/tmp") .. "/.cache/hypr-show-desktop"

local function readShowDesktop()
    local file = io.open(showDesktopPath, "r")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    -- %s* before the last capture, not %s+: the file ends with a newline, and
    -- the old pattern "^(%S+)%s+(%S+)$" NEVER matched a line that ends in
    -- one -- %S+$ cannot cross the trailing \n, so the whole match failed,
    -- readShowDesktop returned nil, and the back-jump branch was dead code:
    -- every "show desktop" opened a new empty desktop and a second press
    -- opened yet another instead of coming back. (The same bug sat in the
    -- keybind-local copy this replaced.)
    local from, scratch = (content or ""):match("^(%S+)%s*(%S+)")
    if not from then return nil end
    return { from = from, scratch = scratch }
end

local function writeShowDesktop(from, scratch)
    local file = io.open(showDesktopPath, "w")
    if not file then return end
    if from and scratch then
        file:write(from .. " " .. scratch .. "\n")
    end
    file:close()
end

-- The desktop edit mode lives in the shell and is entered explicitly from
-- the shell's own UI. The gestures below deliberately NEVER trigger it
-- (requested): show-desktop, the overview and the wallpaper carousel are
-- navigation, not editing sessions.

function M.showDesktop()
    local active = hl.get_active_workspace()
    if not active then return end
    -- We WRITE the ids ourselves (tostring(target) below), so "here" is
    -- compared by id. The workspace object's `name` is not reliably the bare
    -- number in this API -- with a name-based comparison the back-jump branch
    -- silently never matched and a second tap opened a THIRD empty desktop
    -- instead of coming back (observed live).
    local here = tostring(active.id or 0)
    local marked = readShowDesktop()

    -- Second press (still on the empty desktop we jumped to): go back.
    if marked and marked.scratch == here then
        writeShowDesktop(nil, nil)
        hl.dispatch(hl.dsp.focus({ workspace = marked.from }))
        -- NO edit mode here (requested): the show-desktop jump is plain
        -- navigation, it must never open the desktop-edit canvas.
        return
    end

    -- First press: find a desktop nothing lives on and jump there.
    local occupied = {}
    for _, w in ipairs(hl.get_windows()) do
        local workspace = w.workspace
        if workspace and workspace.id and workspace.id > 0 then
            occupied[workspace.id] = true
        end
    end

    local target = nil
    for id = 1, 20 do
        if not occupied[id] and id ~= active.id then
            target = id
            break
        end
    end
    if not target then
        target = (active.id or 1) + 1
    end

    writeShowDesktop(here, tostring(target))
    hl.dispatch(hl.dsp.focus({ workspace = tostring(target) }))
    -- NO edit mode here (requested): an empty desktop is just an empty
    -- desktop.
end

-- ═══ Multi-finger taps: show desktop + wallpaper carousel ══════════
--
-- REVERSED (requested): the 4-finger TAP now runs showDesktop (the jump to
-- an empty desktop, second tap comes back) -- the action SUPER+D used to
-- own -- and SUPER+D now opens the desktops overview instead (the REAL
-- zoomed-out grid, `search tapWorkspaces`). Neither fires the desktop edit
-- mode: the tap path and the key path are pure navigation now. The tap
-- routing lives in the shell (shell.qml, TouchpadSwipe tapTriggered); the
-- key binding lives in custom/keybinds.lua. The overview opens in its
-- tap-mode variant on purpose: modal-less, no focus grab, closes on a
-- second press / Escape / click-away.
--
-- The 3-finger TAP opens the wallpaper carousel -- but only where nothing
-- is open. On a desktop with windows it is a no-op: the gesture is for the
-- empty desktop you landed on (or live on), where changing the mood costs
-- nothing. The emptiness check is the same arithmetic showDesktop uses,
-- extracted below so the two can never disagree.
function M.desktopsOverview()
    os.execute("qs -c ii ipc call search tapWorkspaces >/dev/null 2>&1 &")
end

function M.wallpaperCarousel()
    local active = hl.get_active_workspace()
    if not active then return end
    if not M.is_workspace_empty(active.id) then return end
    -- The carousel opens on its own (the modal in the shell); NO edit mode
    -- (requested) -- opening the picker must not flip the desktop into its
    -- widget-dragging canvas.
    os.execute("qs -c ii ipc call wallpaperStage open >/dev/null 2>&1 &")
end

-- True when nothing app-shaped lives on workspace `id`. showDesktop and
-- wallpaperCarousel share it, so "empty" is one definition, not two.
function M.is_workspace_empty(id)
    for _, w in ipairs(hl.get_windows()) do
        local workspace = w.workspace
        if workspace and workspace.id and workspace.id > 0
            and workspace.id == id then
            return false
        end
    end
    return true
end

return M
