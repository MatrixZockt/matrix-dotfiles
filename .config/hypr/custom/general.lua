-- Your own general settings.
-- This file is loaded AFTER the base config, so what you set here wins.
-- This is the update-safe place for personal preferences.

-- Display scaling
-- This panel is ~198 DPI (2560x1600), so at the base config's scale 1 every
-- element is drawn very small. 1.5 is the default: comfortably larger, and
-- the middle of the two scales this machine was usually lived at.
--
-- 1.5 divides NEITHER panel dimension into whole logical pixels
-- (2560/1.5 = 1706.67), and that is fine -- see the note on the reader below.
--
-- The scale is VALUE-DRIVEN, read from ~/.cache/display/scale (one number, a
-- clean divisor of the panel). That file is what the Razer Command Center app
-- and the shell's own Settings > Display page write, so a change there
-- survives every reboot and every reload WITHOUT this file being rewritten --
-- the same generation pattern as custom/keyboard.lua and
-- custom/performance.lua, but simpler: the file holds only the value, and it
-- is read here, where the monitor rules need it.
--
-- The scale-check switches that used to live here now live in custom/env.lua,
-- which is loaded before the monitor rules so they take effect on the scale.
-- The panel's connector NAME is not stable across boots: this machine's
-- cardN numbering follows GPU probe order, and the panel's connector name
-- follows its card (card1-eDP-1 vs card2-eDP-2 -- both observed on this
-- machine, one boot apart). The panel is whichever eDP-* exists, so match
-- both spellings. Without this, a boot where the iGPU probes second renames
-- the panel to eDP-2 and it silently falls through to the scale-1 catch-all
-- below -- every app and the whole desktop rendering at 62% size.
local scaleValue = 1.5
-- The scales that may be applied: exactly the ones Settings > Display offers,
-- and nothing else. An explicit list rather than a rule, because the rule this
-- replaced was simply false.
--
-- It used to accept a value only if it divided 2560 AND 1600 into whole
-- logical pixels, on the stated grounds that "Hyprland rejects fractional
-- scales that do not divide into whole logical pixels". It does not. Hyprland's
-- `scale` is a plain float multiplier -- 1.5 is an ordinary value, and the
-- config itself proves the point: custom/env.lua sets
-- `debug.disable_scale_checks = true`, which switches OFF the very check the
-- comment claims Hyprland enforces. The rule therefore did nothing except
-- make 150% impossible to select, while looking like a guard.
--
-- The allowlist keeps the part that was real: a garbage or typo'd value must
-- never reach the monitor rule, because a rule Hyprland will not accept leaves
-- the panel on the base config's scale 1 -- the "everything tiny" failure.
local ALLOWED_SCALES = { [1.0] = true, [1.25] = true, [1.5] = true, [1.6] = true, [2.0] = true }
do
    local f = io.open((os.getenv("HOME") or "") .. "/.cache/display/scale", "r")
    if f then
        local v = tonumber(f:read("*l"))
        f:close()
        if v and v >= 1 and v <= 3 and ALLOWED_SCALES[v] then
            scaleValue = v
        end
    end
end
local function monitorRule(output)
    -- NOTE: `disabled` is deliberately NOT set here. A previous revision of
    -- this file carried `disabled = true`, which matches BOTH eDP spellings
    -- and therefore switched the machine's only physical output off at every
    -- boot. Hyprland kept running fine (it happily serves a session with zero
    -- outputs), so the symptom was a completely black screen on login with no
    -- error anywhere: the compositor was healthy, it just had nothing to draw
    -- on. If the panel ever needs to be turned off again, do it at runtime
    -- with `hyprctl keyword monitor eDP-1,disable` instead -- never as a
    -- standing rule in the config, or the next login is black again.
    hl.monitor({
        output = output,
        mode = "preferred",
        position = "auto",
        scale = scaleValue,
    })
end
monitorRule("eDP-1")
monitorRule("eDP-2")

-- Keyboard layouts are NOT set here any more. They live in the shell config
-- (keyboard.layouts) and are written to custom/keyboard.lua by
-- scripts/keyboard/apply.sh, so the settings app can manage them. That file is
-- loaded right after this one, so it wins over the base config's "us".
hl.config({

    -- Gap between two tiled windows, halved from the base config's 4.
    --
    -- Both neighbours already draw their own 1px border, so the visible line
    -- between two windows is the gap plus BOTH borders: at 4 that was a 6px
    -- seam, which reads as a thick divider rather than a shared edge. At 2 the
    -- seam is 4px -- borders and a hair of space, the way a tiled desktop
    -- normally looks. gaps_out (the distance to the screen edge) stays at the
    -- base config's 5, so the outer margin still frames the layout.
    general = {
        gaps_in = 2,

    -- ── The mouse cannot MOVE a window. It can RESIZE one, from its edges. ──
    --
    -- Attached (tiled) windows are FIXED in place. The way you move a window is a
    -- three-finger swipe (the built-in "move" gesture registered in
    -- hyprland/general.lua), and the way you take one to another desktop is
    -- SUPER + four-finger swipe (custom/general.lua). Nothing else.
    --
    -- `resize_on_border` is ON again (2026-09-28), by request: a press inside
    -- the grab band around any window edge and a drag resizes, and Hyprland
    -- anchors it to the edge/corner nearest the CURSOR for the whole drag
    -- (dwindle:smart_resizing, set below). No modifier is held.
    --
    -- Two input paths reach the same drag:
    --   * LEFT button press on the edge band ... press and hold, then move
    --   * TWO-FINGER PRESS on the edge band ... clickfinger maps that to the
    --     right button, so a two-finger press + move resizes too, and the
    --     two-finger MOUSE MOVE on its own still scrolls normally everywhere
    --     else. Only a genuine press arms the drag; hovering the edge (even
    --     while two fingers are scrolling) never does, which is what keeps
    --     this from firing on ordinary scrolling.
    --
    -- The grab band is 10px: wide enough to hit with a fingertip without
    -- leaning on the window, narrow enough that the middle of a window stays
    -- entirely the application's own (so sliders, text selection and the
    -- sidebar's controls are unaffected).
    --
    -- `smart_resizing` (dwindle block below) is what makes this feel right:
    -- the corner/edge you press CLOSEST TO is the one that follows your
    -- fingers for the whole drag, at whatever angle you happen to be coming
    -- in from. A tiled window resizing re-splits the layout and the
    -- neighbours shift -- that is what resizing an attached window IS.
    -- Keyboard resizing is still SUPER+ALT+arrows (40px per press,
    -- in custom/keybinds.lua), and SUPER+two-finger press-drag still works
    -- as a second path to the same resize.
    resize_on_border = true,
    extend_border_grab_area = 10,
    },

    -- Corner-follows-the-cursor resize (dwindle, a sibling of `general`).
    -- This table REPLACES the base dwindle block wholesale (config tables
    -- here do not merge -- the touchpad table above taught that the hard
    -- way), so every base dwindle key is restated. smart_resizing IS the
    -- requested rule: the corner/edge of the window nearest the CURSOR is
    -- the one the SUPER + two-finger press-drag resize moves.
    dwindle = {
        preserve_split = true,
        smart_split = false,
        smart_resizing = true,
    },

    -- `binds:drag_threshold` used to be set to 10 here, to support dragging a
    -- window with the plain left mouse button. That bind was removed (see
    -- custom/keybinds.lua): the threshold cannot distinguish a title-bar grab
    -- from a drag inside an application, so ordinary click-drags moved windows
    -- around. Without a plain-button drag bind the setting does nothing.
    --
    -- Window MOVE dragging is gone (the SUPER+LMB bind was unbound in
    -- custom/keybinds.lua); the one drag that remains is the SUPER +
    -- two-finger press RESIZE (see the general block above), and keyboard
    -- resizing lives in custom/keybinds.lua.

    -- A touch softer than the base config's 10.
    --
    -- The shell's popups and the task manager now blur the LIVE desktop (their
    -- layer rules turn xray off), and at size 10 that live content turned to
    -- mush -- you could no longer tell what was open behind the popup, which is
    -- the whole point of a card floating over your desktop. 8 keeps the
    -- background readable. This is global: every other blurred surface (the
    -- launcher, notifications, the session menu) softens with it.
    decoration = {
        blur = {
            size = 8,
        },
    },

    -- Touchpad scrolling: continuous, not stepped.
    --
    -- `emulate_discrete_scroll` defaults to 1, which makes Hyprland chop the
    -- touchpad's continuous motion into discrete wheel notches. That is why
    -- two-finger scrolling felt like it was sticking: every few pixels the
    -- gesture is rounded to a notch, so the content lurches and pauses instead
    -- of following your fingers. 0 passes the motion through as it arrives.
    --
    -- `scroll_factor` is dropped from the base config's 0.7 (and this file's
    -- earlier 1.0) to 0.5: the touchpad was too hot for general scrolling.
    -- Natural scrolling (two fingers up moves the page down) stays on -- that is
    -- a matter of taste, and the base config already had it on.
    input = {
        emulate_discrete_scroll = 0,
        touchpad = {
            natural_scroll = true,
            disable_while_typing = true,
            clickfinger_behavior = true,
            scroll_factor = 0.7,
            -- Tap gestures: tap-to-click (a tap is a click) and tap-and-drag
            -- (double-tap-and-hold drags INSIDE apps -- sliders, text
            -- selection, the sidebar's controls). This table REPLACES the base
            -- config's touchpad block, so every key must be restated here:
            -- anything left out silently falls back to the fork's default,
            -- which is how tap-to-click died and every tap gesture with it.
            -- Windows are NOT dragged by this: there is no plain mouse-drag
            -- bind (both were unbound), so a synthesized held button only
            -- ever reaches applications.
            --
            -- `drag_lock` is OFF (it was on, 2026-09-29, on request). Its whole
            -- purpose is the opposite of what a drag should do on this desktop:
            -- after a hold it KEEPS the drag alive with no finger on the pad,
            -- so lifting off left the drag hanging for about a second -- long
            -- enough that a drag that was over still looked live, and a drag
            -- that hit the end of a slider or list kept moving after the hand
            -- had already left. With it off, the synthesized button is
            -- released the instant the last finger lifts, for every
            -- application, which is the only behaviour a drag can have
            -- consistently. Clickfinger stays: that is the two-finger press
            -- used for the edge resize, and it is unrelated to release timing.
            tap_to_click = true,
            tap_and_drag = true,
            drag_lock = false,
            -- WHICH BUTTON an N-finger tap presses. This key was missing, and
            -- `hyprctl getoption input:touchpad:tap_button_map` answered
            -- [[EMPTY]] -- so a two-finger tap synthesised NO button at all.
            -- Every app in the config that offers a right-click menu (the
            -- file manager's Places rows and file rows, every context menu)
            -- was therefore unreachable by touchpad, no matter what it did
            -- with the press. This is the exact failure the comment above
            -- warns about, one key further down: the table REPLACES the base
            -- block, and what is left out silently disappears.
            --
            -- 1 / 2 / 3 fingers -> left / right / middle, the standard map.
            --
            -- The third entry is what makes a THREE-finger tap arrive at the
            -- focused application as a MIDDLE CLICK, and middle click is
            -- "paste the PRIMARY selection" in every text field on the
            -- desktop. That is a real bug on this machine: a three-finger
            -- tap inside an input pasted whatever text happened to be
            -- selected elsewhere (a page of settings, dumped into a prompt
            -- box). Confirmed with `wl-paste --primary`, which returns
            -- exactly the blob that appeared -- so the application was
            -- pasting its own PRIMARY, and the clipboard history was never
            -- involved (every Cliphist paste call was logged while the bug
            -- was live: zero hits).
            --
            -- It is LEFT as "3" anyway, because the third entry is not what
            -- fixes it. Setting it to 0 (and to -1) changed nothing
            -- observable, which says the tap button is not being decided
            -- here at all -- `clickfinger_behavior` below is the more likely
            -- author, and that one is load-bearing: it is what makes a
            -- two-finger PRESS a right button, which is the resize drag in
            -- custom/keybinds.lua. Guessing at this value risks silently
            -- turning three-finger taps into LEFT clicks, which is a worse
            -- bug than the one being fixed.
            --
            -- The actual fix is one line in custom/keybinds.lua: a
            -- modifier-free bind on the middle button, so a middle click is
            -- consumed by the compositor and never reaches an application.
            -- That holds no matter which layer synthesised it.
            tap_button_map = "1,2,3",
        },
    },
})

-- Trackpad gestures
--
--   four fingers left/right (plain)  ... switch desktops (base config).
--                                        CREATES the desktop when there is
--                                        none that way: a swipe past the last
--                                        desktop makes it, which is what
--                                        workspace_swipe_create_new = true
--                                        (hyprland/general.lua) is for, and
--                                        it is how the bottom pill's trailing
--                                        "+" is reached by gesture. The only
--                                        edge left with nowhere to go is
--                                        therefore the LEFT one -- ids start
--                                        at 1, so there is nothing there for
--                                        Hyprland to create. Swiping into it
--                                        flashes the bottom pill and moves
--                                        nothing (see "nothing happens here
--                                        any more" further down).
--   SUPER + four fingers left/right  ... take the focused window to the desktop
--                                        next door (and follow it there),
--                                        CREATING that desktop when there is
--                                        none that way (moveWindowToNeighbour)
--   four fingers down               ... close the focused window
--
-- The SUPER variant replaces SUPER+SHIFT+<number> (see custom/keybinds.lua).
--
-- Two things matter for whether the SUPER drag ever fires:
--
--   1. DISCRETE directions. Hyprland's Lua `direction` takes the axis names the
--      wiki documents -- "horizontal", "left", "right", "up", "down", "pinch"
--      -- and there is no 1:1 mode name among them. An unknown value makes
--      Hyprland reject the gesture at load time, which is exactly why
--      `direction = "swipe"` never did anything. "left"/"right" are the
--      discrete forms: one action per swipe, one binding per direction.
--
--   2. `mods` disambiguates, so nothing has to be unregistered. A
--      modifier-restricted gesture and the plain one with the same finger
--      count coexist: Hyprland matches the one whose modifiers fit what you
--      are actually holding. The base config's plain desktop switch stays.
--
--   3. Each action also fires the shell's "interrupt the SUPER tap" shortcut.
--      A plain SUPER *tap* opens the search panel on release, and a gesture is
--      not a key press, so without this the shell still saw an untouched SUPER
--      hold: letting go after moving a window opened the search bar on top of
--      everything. The interrupt is the shell's own switch for exactly this
--      ("this SUPER hold was used for something else"), so trip it on every
--      swipe that used SUPER.
-- Shared desktop actions (custom/popup.lua: show desktop, the desktops
-- overview, the wallpaper carousel, fullscreen slot memory). The popup
-- guards that used to gate the gestures here are retired: the settings and
-- task-manager apps are ordinary desktop windows now, so a gesture always
-- acts on the focused window.
local popup = require("custom.popup")
-- Performance mode's live flag (custom/performance.lua, written by the
-- settings app's toggle through scripts/performance/apply.sh).
local performance = require("custom.performance")
-- The "fills the screen" action, shared with SUPER+F (custom/keybinds.lua).
-- The swipe's maximize half was already right; what it never did was ask the
-- shell to give up the bar's exclusive zone, so the maximized window stopped
-- at the bar's reserved strip instead of reaching the top edge.
local cover = require("custom.cover")

-- ── Where a SUPER swipe may take a window ───────────────────────────────
-- CREATE the desktop if there is none that way (requested 2026-09-26: no
-- more "No desktop that way" -- always create in the swiped direction).
--
-- History: the first version asked for "the workspace next door"
-- (`workspace = "r+1"`), which created one on EVERY overshoot -- the
-- "Freebuff randomly jumped to desktop 9" report. So creation was clamped to
-- the trailing "+" slot only, and a swipe left from the FIRST desktop said
-- "no desktop that way". The compaction service changed the picture: the
-- shell RENUMBERS desktops to stay contiguous (HyprlandData.compactWorkspaces,
-- via hl.dsp.workspace.change_id -- rename-in-place, windows and the active
-- pointer follow the object), so "create one to the left" can be done
-- honestly: put the window on an id BELOW the minimum and compaction
-- renumbers the set into [1..n] with the new desktop in the leftmost slot.
-- One step, one desktop, in exactly the direction swiped -- and no message.
local function workspacesInUse()
    local ids, seen = {}, {}
    for _, w in ipairs(hl.get_windows() or {}) do
        local id = w.workspace and w.workspace.id
        if id and id >= 1 and id <= 100 and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    local active = hl.get_active_workspace()
    if active and active.id and active.id >= 1 and active.id <= 100 and not seen[active.id] then
        ids[#ids + 1] = active.id
    end
    table.sort(ids)
    return ids
end

-- The neighbouring desktop in `step` direction, or nil when there is none.
local function neighbourWorkspace(fromId, step)
    local ids = workspacesInUse()
    if step > 0 then
        for _, id in ipairs(ids) do
            if id > fromId then return id end
        end
    else
        for i = #ids, 1, -1 do
            if ids[i] < fromId then return ids[i] end
        end
    end
    return nil
end

local function moveWindowToNeighbour(step)
    local win = hl.get_active_window()
    local fromId = win and win.workspace and win.workspace.id
    if not fromId then return end
    local target = neighbourWorkspace(fromId, step)
    if not target then
        -- Nothing that way: CREATE one, one step, in the swiped direction.
        --
        -- Rightward: the trailing "+" slot -- max in use + 1 (the compaction
        -- keeps ids contiguous, so that is exactly the slot the bar shows).
        -- Leftward: ids start at 1, so when desktop 1 exists there is no
        -- free number below. Every existing desktop is renamed +1 (highest
        -- FIRST, so no rename collides with a not-yet-renamed id) -- which
        -- frees id 1 -- and the window then moves onto that freed id,
        -- creating the new leftmost desktop. Rename-in-place follows the
        -- windows and the active-workspace pointer, so nothing jumps; the
        -- set stays contiguous and the bar grows one slot on the left.
        local ids = workspacesInUse()
        if step > 0 then
            local maxId = ids[#ids] or fromId
            if maxId < 100 then target = maxId + 1 end
        else
            local minId = ids[1] or fromId
            if minId > 1 then
                target = minId - 1
            else
                local maxId = ids[#ids] or fromId
                if maxId >= 100 then return end
                for i = #ids, 1, -1 do
                    hl.dispatch(hl.dsp.workspace.change_id({ workspace = ids[i], id = ids[i] + 1 }))
                end
                target = minId -- freed by the renames above (was desktop 1)
            end
        end
        if not target then return end
    end
    hl.dispatch(hl.dsp.window.move({ workspace = target, follow = true }))
    hl.dispatch(hl.dsp.global("quickshell:searchToggleReleaseInterrupt"))
end

-- ═══ Three fingers down: pop the now bar's island out ══════════════════
--
-- The island's hover extension is a glance; this is the deliberate version of
-- the same view -- it TRANSFORMS the island into a card under itself that
-- stays until you press outside it (modules/ii/bar/NowBarPanel.qml).
--
-- ═══ REQUESTED (2026-09-26): only when the cursor is ON the middle island ═══
--
-- The compositor owns libinput (so it sees the gesture) but cannot see hover
-- over a layer surface; the shell owns hover but never sees gestures. So the
-- shell publishes the island's hover state to a runtime file and this gesture
-- reads it at gesture time:
--
--   $XDG_RUNTIME_DIR/ii-nowbar-hover.json   {"hovering":true,"ts":<epoch>}
--
-- Written by the shell's island (NowBar.qml) on hover changes, on panel
-- open/close, and refreshed by a 2s keepalive timer; this side treats the
-- file as stale after 10s without a refresh (a crashed shell must never
-- leave a dead "hovering" pinning the gesture) and treats "no file" as
-- not-hovering. The file is also what keeps 2/3-finger horizontal swipes
-- single-stepped: the island consumes those itself over its own surface, so
-- there are deliberately NO global horizontal binds here any more.
--
-- Falls back to the OLD always-fire behavior only if the file cannot be read
-- AT ALL (e.g. an older shell that has never written it) -- a half-updated
-- pair must not break the panel open. A file that says hovering=false is
-- honored as a real "no".
local function nowBarHoverFile()
    local dir = os.getenv("XDG_RUNTIME_DIR")
    if not dir or dir == "" then dir = "/tmp" end
    return dir .. "/ii-nowbar-hover.json"
end

-- ═══ Sidebar state, for the three-finger close ═════════════════════════
--
-- The compositor owns libinput and therefore every multi-finger gesture, but
-- it cannot see a Quickshell layer surface: there is no way for it to ask
-- "is a sidebar open right now". The shell publishes the one bit it knows
-- (GlobalStates.qml -> ii-sidebar-state.json), the same handshake the island
-- uses for hover just above.
--
--   {"left":true,"right":false,"ts":1756...}
--
-- A three-finger swipe TOWARDS an open sidebar closes it -- left on a swipe
-- left, right on a swipe right -- and is consumed there. That is the whole
-- point of the branch in the gesture handlers below: the window underneath a
-- sidebar is a window the user cannot see, so letting FIELD_SWIPE move or
-- swap it would act on something invisible. Sidebar wins outright while it is
-- open; with no sidebar open the swipe falls through to the window actions
-- exactly as before.
--
-- Returns nil for "cannot know", which the callers treat as "no sidebar" --
-- the safe direction, since the fallback is the pre-existing window action.
-- Staleness matters more here than for hover: a crashed shell that left
-- "left":true behind would otherwise make the left sidebar permanently
-- un-closeable by gesture, with nothing on screen to explain why.
local function sidebarStateFile()
    local dir = os.getenv("XDG_RUNTIME_DIR")
    if not dir or dir == "" then dir = "/tmp" end
    return dir .. "/ii-sidebar-state.json"
end

-- Reads the file, returning a table {left=bool, right=bool} or nil.
local function readSidebarState()
    local file = io.open(sidebarStateFile(), "r")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    local has_left = text:match('"left"%s*:%s*(true)') ~= nil
        or text:match('"left"%s*:%s*(false)') ~= nil
    local has_right = text:match('"right"%s*:%s*(true)') ~= nil
        or text:match('"right"%s*:%s*(false)') ~= nil
    if not has_left and not has_right then return nil end -- unparseable
    local ts = tonumber(text:match('"ts"%s*:%s*([0-9%.]+)'))
    if ts and (os.time() - ts) > 10 then return nil end -- stale keepalive
    return {
        left = has_left and text:match('"left"%s*:%s*true') ~= nil,
        right = has_right and text:match('"right"%s*:%s*true') ~= nil,
    }
end

-- (readSwipeSuppressed and cursorInsideLeftSidebar were here for a
-- two-finger compositor bind for the sidebar's tab swipe, and are gone
-- with it: the bind never fired, so nothing ever called them.)

-- The close action itself. `direction` is the swipe: "left" closes the left
-- sidebar, "right" the right one.
local function closeSidebarToward(direction)
    local state = readSidebarState()
    if not state then return false end
    if direction == "left" and state.left then
        -- Both names are the shell's own GlobalShortcuts (SidebarLeft.qml /
        -- SidebarRight.qml), the same ones the keybinds fire, so this path
        -- and the keyboard path cannot drift apart.
        hl.dispatch(hl.dsp.global("quickshell:sidebarLeftClose"))
        return true
    end
    if direction == "right" and state.right then
        hl.dispatch(hl.dsp.global("quickshell:sidebarRightClose"))
        return true
    end
    return false
end

-- true / false / nil (nil = "cannot know" -> caller falls back).
local function readNowBarHover()
    local file = io.open(nowBarHoverFile(), "r")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    local hovering = text:match('"hovering"%s*:%s*(true)') ~= nil
        or text:match('"hovering"%s*:%s*(false)') ~= nil
    if not hovering then return nil end -- unparseable: same as unreadable
    local ts = tonumber(text:match('"ts"%s*:%s*([0-9%.]+)'))
    if ts and (os.time() - ts) > 10 then return false end -- stale keepalive
    return text:match('"hovering"%s*:%s*true') ~= nil
end

-- ── Bar on screen? (the gesture handshake) ────────────────────────────
-- $XDG_RUNTIME_DIR/ii-bar-visible.json, written by the shell (modules/ii/
-- bar/Bar.qml) whenever `!hideBySlide`, refreshed every 2s while visible.
--
-- One fact about the bar, and it is the only one a gesture can honestly ask
-- for: IS IT ON SCREEN, and for the middle island's screen-x run and the
-- bar's painted height. `cursorOnMiddleBar()` below turns those three
-- numbers plus hl.get_cursor_pos() into the one yes/no SWIPE_DOWN_POP asks,
-- which is the rule that was asked for: the popup opens from the middle top
-- bar and nowhere else.
--
-- Same contract as readNowBarHover above, and for the same reason:
-- unreadable or unparseable is nil ("cannot know", caller decides), STALE is
-- false, so a crashed shell cannot leave the gestures latched on with no bar
-- to aim at.
local function barVisibleFile()
    local dir = os.getenv("XDG_RUNTIME_DIR")
    if not dir or dir == "" then dir = "/tmp" end
    return dir .. "/ii-bar-visible.json"
end

local function readBarVisible()
    local file = io.open(barVisibleFile(), "r")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    local seen = text:match('"visible"%s*:%s*(true)') ~= nil
        or text:match('"visible"%s*:%s*(false)') ~= nil
    if not seen then return nil end -- unparseable: same as unreadable
    local ts = tonumber(text:match('"ts"%s*:%s*([0-9%.]+)'))
    if ts and (os.time() - ts) > 10 then return false end -- stale keepalive
    return text:match('"visible"%s*:%s*true') ~= nil
end

-- The bar's GEOMETRY, from the same file: the painted strip height and the
-- middle island's screen-x run. Nil when the file cannot answer or the
-- keepalive has gone stale, and every caller treats that as "not on the bar".
--
-- WHY GEOMETRY AND NOT THE HOVER FILE. `readNowBarHover` above answers the
-- same question the obvious way -- "did the island see a hover" -- and it is
-- the wrong instrument here. Island hover rides on layer-shell pointer
-- delivery, which is precisely what is missing when a fullscreen window is up,
-- when the bar's input region has gaps cut out of it, or when the pointer is
-- warped instead of walked. Measured, not assumed: with the pointer sitting
-- at x=854, y=25 -- dead centre of the middle island, whose painted run is
-- 669..1039 -- `islandHovered` stayed false and the hover file never wrote a
-- `true`. A gate that silently reads "no" is worse than no gate, because it
-- looks like the gesture is broken.
--
-- So the shell publishes where the middle bar IS, and the compositor does the
-- comparison itself against hl.get_cursor_pos(). No event, no delivery, no
-- input region: a pointer at (854, 25) is on the middle bar because the
-- arithmetic says so. It is also the only version that can be verified from
-- here, which is how the numbers below were obtained.
local function barGeometry()
    local file = io.open(barVisibleFile(), "r")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    local ts = tonumber(text:match('"ts"%s*:%s*([0-9%.]+)'))
    if ts and (os.time() - ts) > 10 then return nil end -- stale keepalive
    local visible = text:match('"visible"%s*:%s*true') ~= nil
    if not visible then return nil end
    local stripH = tonumber(text:match('"stripH"%s*:%s*([0-9%.]+)'))
    local midL = tonumber(text:match('"midL"%s*:%s*([0-9%.]+)'))
    local midR = tonumber(text:match('"midR"%s*:%s*([0-9%.]+)'))
    if not stripH or stripH <= 0 then return nil end
    if not midL or not midR or midR <= midL then return nil end
    return stripH, midL, midR
end

-- ── THE RULE ───────────────────────────────────────────────────────────
-- Is the pointer on the MIDDLE top bar, right now?
--
-- REQUESTED (2026-10-03): the three-finger swipe-down popup opens ONLY from
-- the middle top bar -- not from anywhere on the screen, not from the left
-- or right island, not from the empty stretches between them. This is that
-- rule and nothing else.
--
-- A touchpad swipe moves no cursor, but the cursor does not MOVE during one:
-- it is stationary, so parking it on the middle bar and swiping is stable and
-- repeatable. That is what makes a cursor-position gate usable for a
-- gesture at all, and it is why this is not the same thing as the earlier
-- broken version (which asked about the now-playing island's own hover and so
-- fired only in the one spot the island happened to occupy).
--
-- Fails OPEN, as every other reader here does: if the geometry cannot be read
-- -- shell down, bar hidden, file stale -- this returns false and the caller
-- keeps whatever the swipe did before any of this existed.
--
-- AND the access itself lives here, once, guarded. The first version of the
-- tracing call site asked for the cursor with a BARE hl.get_cursor_pos(),
-- and that is a loaded gun in a gesture callback: if it throws, the callback
-- aborts on that line, so the popup does not open AND the trace never gets
-- written -- a failure that looks exactly like "the gesture does not fire".
-- Everything that wants the pointer now asks this function.
local function cursorXY()
    local ok, cur = pcall(hl.get_cursor_pos)
    if not ok or not cur then return nil, nil end
    return tonumber(cur.x), tonumber(cur.y)
end

local function cursorOnMiddleBar()
    local stripH, midL, midR = barGeometry()
    if not stripH then return false end
    local x, y = cursorXY()
    if not x or not y then return false end
    return y >= 0 and y <= stripH and x >= midL and x <= midR
end



-- ── Wallpaper theatre owns 3-finger swipes while it is open ──────────
-- The shell's carousel consumes three fingers 1:1 while the theatre is up
-- (WallpaperSwipe3 -> WallpaperCarousel.feedDrag), so the compositor's own
-- 3-finger binds must stand down: one physical swipe would otherwise both
-- scroll the ring AND field-move a window. The keepalive file follows the
-- ii-nowbar-hover.json pattern, staleness included: a crashed shell that
-- never writes "open":false must not pin the gestures down forever.
local function wallpaperStageKeepaliveFile()
    local dir = os.getenv("XDG_RUNTIME_DIR")
    if not dir or dir == "" then dir = "/tmp" end
    return dir .. "/ii-wallpaper-stage.json"
end

local function wallpaperStageOpen()
    local file = io.open(wallpaperStageKeepaliveFile(), "r")
    if not file then return false end
    local text = file:read("*a")
    file:close()
    local ts = tonumber(text:match('"ts"%s*:%s*([0-9]+)'))
    if ts and (os.time() - ts) > 10 then return false end -- stale keepalive
    return text:match('"open"%s*:%s*true') ~= nil
end

-- ── Now-bar PANEL open state (the popped-out card) ────────────────────
-- The shell publishes the card's open state to a runtime file, the same
-- handshake as the island hover file above. The compositor cannot see a
-- Quickshell layer surface, so it reads this at gesture time instead:
--
--   $XDG_RUNTIME_DIR/ii-nowbar-panel.json  {"open":true,"ts":...}
--
-- While the card is open, 3-finger up AND down must put it away -- the user
-- asked for it to disappear with either direction, and a swipe that ALSO
-- field-moves a window behind the popup veil would act on a window the user
-- cannot see. Staleness rule identical to the hover file: a crashed shell
-- that never writes "open":false must not pin the gestures down forever,
-- so an old file simply reads as closed.
local function nowBarPanelStateFile()
    local dir = os.getenv("XDG_RUNTIME_DIR")
    if not dir or dir == "" then dir = "/tmp" end
    return dir .. "/ii-nowbar-panel.json"
end

local function nowBarPanelOpen()
    local file = io.open(nowBarPanelStateFile(), "r")
    if not file then return false end -- no file = closed
    local text = file:read("*a")
    file:close()
    local ts = tonumber(text:match('"ts"%s*:%s*([0-9%.]+)'))
    if ts and (os.time() - ts) > 10 then return false end -- stale = closed
    return text:match('"open"%s*:%s*true') ~= nil
end

-- ── Desktop-overview (the frosted desktop grid) open state ───────────
-- The grid is a Quickshell layer surface, so the compositor cannot see it,
-- and it matters: the plain four-finger swipe DOWN is the close-window drag,
-- so while the grid is up that same swipe would grab the focused window
-- standing BEHIND it and close it. The shell therefore publishes the grid's
-- state, and the drag checks it before it grabs anything:
--
--   $XDG_RUNTIME_DIR/ii-desktop-overview.json  {"open":true,"ts":...}
--
-- Same staleness rule as the two files above -- a missing or old file reads
-- as closed, so a crashed shell leaves the close-drag working (a swipe can
-- then only ADD the grid, never get stuck unable to remove it).
local function desktopOverviewStateFile()
    local dir = os.getenv("XDG_RUNTIME_DIR")
    if not dir or dir == "" then dir = "/tmp" end
    return dir .. "/ii-desktop-overview.json"
end

local function desktopOverviewOpen()
    local file = io.open(desktopOverviewStateFile(), "r")
    if not file then return false end -- no file = closed
    local text = file:read("*a")
    file:close()
    local ts = tonumber(text:match('"ts"%s*:%s*([0-9%.]+)'))
    if ts and (os.time() - ts) > 10 then return false end -- stale = closed
    return text:match('"open"%s*:%s*true') ~= nil
end

-- (The swipe trace helper, `trace`, is DEFINED HERE rather than beside the
-- swipe-up body that first used it. A `local` in Lua is only visible to code
-- textually AFTER it, and anchoredTransition below also reports through it --
-- from inside a pcall, where calling a nil local reads as "the transition
-- threw" and then throws again on the error path. One definition, above every
-- user.)
local tracePath = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/quickshell-swipeup.log"
local function trace(line)
    pcall(function()
        local f = io.open(tracePath, "a")
        if not f then return end
        f:write(os.date("%H:%M:%S ") .. line .. "\n")
        f:close()
    end)
end

-- A trace file of its OWN for the popup gate, separate from the gesture
-- trace above. That file is written by dozens of gestures; one that answers
-- "was the cursor on the middle bar?" has to be readable on its own, and
-- sharing a file with the close-drag means the answer is buried under
-- whatever else the user did in the same second.
--
-- It exists because this gate has been wrong three different ways in one
-- session -- island hover, bar-visible, and a cursor position that only the
-- compositor can see -- and in every case the only evidence available was
-- "the swipe did nothing". One line per swipe says which way it went and why.
local popupGateTracePath =
    (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/bar-popup-gate.log"

-- Written with its own pcall rather than through tracef() above: this runs on
-- the swipe's critical path, and the reason the formatted-trace helper exists
-- at all is that an exception in a gesture callback IS the gesture failing.
local function gateTrace(...)
    -- The arguments are captured into a table BEFORE the pcall: `...` is in
    -- scope only in this function, not in a closure nested inside it, and
    -- reading it there is a syntax error rather than a silent nil.
    local args = { ... }
    local count = select("#", ...)
    pcall(function()
        local parts = {}
        for i = 1, count do parts[#parts + 1] = tostring(args[i]) end
        local f = io.open(popupGateTracePath, "a")
        if not f then return end
        f:write(os.date("%H:%M:%S ") .. table.concat(parts, " ") .. "\n")
        f:close()
    end)
end

-- Formatted trace, and the ONLY safe way to build one.
--
-- `trace(string.format(...))` looks safe -- trace() has a pcall around the file
-- write -- but the format runs at the CALL SITE, before trace() is entered, so
-- a bad argument throws straight past the guard. From inside a gesture
-- callback that is not a log line failing, it is the gesture failing: the
-- diagnostic silently deleted the feature it was added to watch (measured: a
-- `%d` on a fractional touchpad delta raised "bad argument to 'format'" in
-- the gesture END callback, so the close never ran).
--
-- So the formatting is inside the pcall here, and a value that cannot be
-- formatted degrades to a placeholder instead of taking the caller down. Any
-- trace of anything computed must go through this.
local function tracef(fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    trace(ok and line or (tostring(fmt) .. " <unformattable>"))
end


-- Names and values of a gesture event's own fields, as a log line.
--
-- Written because this compositor build's gesture event has already cost one
-- whole feature: a field the close-drag assumed (`time_ms`) turned out not to
-- exist, and the resulting nil-minus-nil threw inside a callback nobody was
-- watching, so the four-finger close silently stopped working with nothing in
-- any log. Guessing a field name a second time is not a fix; printing the
-- fields once is. Safe on anything, including a nil or a non-table.
local function describeGestureEvent(e)
    local parts = {}
    if type(e) ~= "table" then return "event is " .. type(e) end
    for k, v in pairs(e) do
        if type(v) == "table" then
            local inner = {}
            for k2, v2 in pairs(v) do inner[#inner + 1] = tostring(k2) .. "=" .. tostring(v2) end
            parts[#parts + 1] = tostring(k) .. "{" .. table.concat(inner, ",") .. "}"
        else
            parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
        end
    end
    return "event{ " .. table.concat(parts, " ") .. " }"
end
-- ═══ 3/4-finger navigation: SWAP first, move only as the fallback ═══════
--
-- REQUESTED (2026-09-29). A three-finger swipe used to RELOCATE the focused
-- window into the field the swipe pointed at, which is why a plain "show me
-- the window next to this one" moved the desktop around instead of just
-- looking at it. The rule now:
--
--   1. SWAP (the normal case). There is a window over there -> focus moves to
--      it and NOTHING MOVES. You end up looking at the other window, which is
--      what a three-finger swipe means everywhere else.
--
--   2. FALLBACK (nothing over there). The NEIGHBOUR is moved across into the
--      space the swipe was asking about, and focus STAYS where it is -- so the
--      half of the screen you swiped towards is never left empty. This is the
--      "one app occupies a whole side" case: two windows side by side, swipe
--      down, nothing below to swap with, so the window beside you drops into
--      the lower half and the one you were looking at keeps the upper half and
--      grows into it.
--
-- WHY THIS IS LUA AND NOT field-move.py. That script could not do the swap at
-- all: `hl.dsp.focus({ window = "address:0x..." })` is rejected --
-- "expected a window object or selector" -- because this build takes a real
-- window OBJECT, which only code inside the config can produce. Every
-- `hyprctl dispatch hl.dsp.window.move({ window = "address:..." })` the old
-- script issued was failing the same way and being swallowed, which is why
-- the old 3f swipes so often did nothing visible. The focus and move
-- dispatchers here act on the FOCUSED window, so "focus the other one" IS the
-- swap, and "focus it, then move, then focus back" IS the fallback.
--
-- Exposed as a global so the CTRL+SUPER+arrow keybinds (custom/keybinds.lua,
-- loaded after this file) share exactly one implementation.

-- Edge-adjacency tolerance for the swipe geometry, in logical px. Same value
-- field-move.py used, so a swipe treats a window as "directly above/below"
-- across the small gaps the tiler leaves between neighbours.
local GAP_TOL = 26

local function fieldsInWorkspace(wsId)
    local out = {}
    for _, w in ipairs(hl.get_windows() or {}) do
        if w.workspace and w.workspace.id == wsId and w.mapped ~= false
            and w.hidden ~= true and not w.floating and not w.pinned
            and (w.fullscreen or 0) == 0 then
            out[#out + 1] = w
        end
    end
    return out
end

local function rectsOverlap(a, b, axis)
    -- axis "x": do the two windows share a column?
    if axis == "x" then
        local lo = math.max(a.at.x, b.at.x)
        local hi = math.min(a.at.x + a.size.x, b.at.x + b.size.x)
        return math.max(0, hi - lo)
    end
    local lo = math.max(a.at.y, b.at.y)
    local hi = math.min(a.at.y + a.size.y, b.at.y + b.size.y)
    return math.max(0, hi - lo)
end

-- The window a swipe towards `direction` should swap with: the NEAREST one
-- whose centre is on that side of ours and which shares our row (left/right)
-- or our column (up/down) closely enough to read as "over there".
local function neighbourInDirection(me, wins, direction)
    local mcx = me.at.x + me.size.x / 2
    local mcy = me.at.y + me.size.y / 2
    local best, bestD = nil, nil
    for _, o in ipairs(wins) do
        if o.address ~= me.address then
            local ocx = o.at.x + o.size.x / 2
            local ocy = o.at.y + o.size.y / 2
            local along, cross, need
            if direction == "left" then
                along = (ocx < mcx - GAP_TOL) and (mcx - ocx) or nil
                if along then cross = rectsOverlap(o, me, "y"); need = me.size.y * 0.4 end
            elseif direction == "right" then
                along = (ocx > mcx + GAP_TOL) and (ocx - mcx) or nil
                if along then cross = rectsOverlap(o, me, "y"); need = me.size.y * 0.4 end
            elseif direction == "up" then
                along = (ocy < mcy - GAP_TOL) and (mcy - ocy) or nil
                if along then cross = rectsOverlap(o, me, "x"); need = me.size.x * 0.4 end
            else -- down
                along = (ocy > mcy + GAP_TOL) and (ocy - mcy) or nil
                if along then cross = rectsOverlap(o, me, "x"); need = me.size.x * 0.4 end
            end
            -- It has to share the row/column we are looking along, or it is
            -- not "over there", it is just some other window.
            if along and cross >= need and (bestD == nil or along < bestD) then
                best, bestD = o, along
            end
        end
    end
    return best
end


-- Which side of a window a swipe retracts when there is nothing to move into:
-- the side FACING AWAY from the swipe, because that is the side whose
-- neighbour can grow into the room this window gives up.
--
--   swipe up    -> retract the BOTTOM edge, the window below grows upward
--   swipe down  -> retract the TOP edge, the window above grows downward
--   swipe left  -> retract the RIGHT edge, the window right grows leftward
--   swipe right -> retract the LEFT edge, the window left grows rightward
--
-- "Retract" is a resize anchored at the top-left corner, so only the two
-- edges that hang off the BOTTOM/RIGHT can be pulled in on the window itself
-- (up, left). The other two (down, right) are the same layout expressed on
-- the OTHER window: growing the neighbour that shares the row/column pushes
-- its far edge past ours, which is precisely our near edge retreating.
local SWIPE_DIR = { left = "l", right = "r", up = "u", down = "d" }
-- The axis a swipe trades room on: a horizontal swipe moves width around, a
-- vertical one moves height.
local SWIPE_AXIS = { left = "x", right = "x", up = "y", down = "y" }
local RETRACT_ON_SELF = { up = "y", left = "x" } -- resize OUR window smaller
local RETRACT_ON_OTHER = { down = "y", right = "x" } -- resize the NEIGHBOUR bigger
-- The side a dead-end swipe reaches ACROSS to find the window that fills the
-- gap. Swiping up finds the window BELOW, swiping right finds the one to the
-- LEFT -- always the far side, because that is the side being retracted.
local RETRACT_ACROSS = { up = "down", down = "up", left = "right", right = "left" }

-- Smallest and largest slice, in logical px, a retract may take or hand over.
-- Without a floor a swipe could squeeze a window down to a sliver; without a
-- ceiling it could swallow its neighbour whole.
local RETRACT_MIN = 120
-- Hard floor on the result of any resize a swipe asks for. A window narrower
-- or shorter than this is not a window any more -- it is the "weirdly created
-- space" a swipe is supposed to be fixing, so a swipe must never make one,
-- and a swipe that lands on one grows it back out. Set below the width a
-- sensible column reaches (the 294px column in a four-window layout is fine),
-- well above the slivers (120-200px) a bad move leaves behind.
local MIN_SIDE_W = 260
local MIN_SIDE_H = 180

-- How much a dead-end swipe is allowed to hand over, in logical px, along
-- `axis`. Three limits, all of them learned the hard way:
--
--   * we keep MIN_SIDE ourselves, or the swipe is refused;
--   * we never give away more than a third of what we have, so a swipe moves
--     the layout instead of redrawing it;
--   * and the swap is only allowed to take from windows that have slack --
--     the tiler pays a horizontal give out of our WHOLE column, not just out
--     of us, so a generous give quietly turns the windows stacked below us
--     into 190px slivers (measured: a 395px give on a 791px window left its
--     two neighbours at 196 and 194).
local function retractAllowance(me, across, wins, axis)
    local floorSize = (axis == "x") and MIN_SIDE_W or MIN_SIDE_H
    local mine = (axis == "x") and me.size.x or me.size.y
    local room = math.max(0, mine - floorSize)
    local slack = 0
    for _, o in ipairs(wins) do
        if o.address ~= me.address and (not across or o.address ~= across.address) then
            -- Same row (for a width trade) or same column (for a height one).
            local shares = (axis == "x") and rectsOverlap(o, me, "y") > 0
                or rectsOverlap(o, me, "x") > 0
            if shares then
                local s = (axis == "x") and o.size.x or o.size.y
                slack = slack + math.max(0, s - floorSize)
            end
        end
    end
    return math.min(math.min(room, slack), math.max(RETRACT_MIN, math.floor(mine / 3)))
end

-- Put the cursor back exactly where it was.
--
-- `input.follow_mouse` (hyprland/general.lua) warps the pointer onto whatever
-- window a dispatcher focuses, and EVERY geometry verb here focuses its
-- target: `move`/`resize` act on the focused window on this build (the
-- `window =` selector is dropped -- verified: a resize aimed at an unfocused
-- window landed on the focused one instead). So the focus juggling these
-- swipes need would otherwise drag the pointer across the screen, which is
-- exactly the "it only moves the cursor" symptom this replaces. Snapshotting
-- the pointer before the moves and restoring it after makes the layout change
-- the ONLY visible effect.
--
-- The restore is TIMED, not immediate. Dispatch is asynchronous: the last
-- `focus` is still queued when this function runs, and it warps the pointer
-- on its way through, so an immediate restore is undone a frame later. The
-- callback therefore fires again one or two frames down, once the queue has
-- drained, and only moves the pointer if it is not already where it belongs.
local function cursorHold()
    local cur = hl.get_cursor_pos()
    if not cur then return function() end end
    local function restore()
        local now = hl.get_cursor_pos()
        -- Only if something actually moved it: a restore that always fires
        -- would fight the user if they moved the mouse during the animation.
        if now and (math.abs(now.x - cur.x) > 0.5 or math.abs(now.y - cur.y) > 0.5) then
            hl.dispatch(hl.dsp.cursor.move({ x = tostring(cur.x), y = tostring(cur.y) }))
        end
    end
    return function()
        restore()
        hl.timer(restore, { timeout = 40, type = "oneshot" })
        hl.timer(restore, { timeout = 120, type = "oneshot" })
    end
end

-- Resize a window to an ABSOLUTE size, by address.
--
-- Two things about this build make the naive version wrong, and both of them
-- showed up as "the swipe resized the wrong window, or not at all":
--
--   * `resize` acts on the FOCUSED window, and dispatch is queued. Firing
--     `focus` and `resize` back to back lets the resize land on whatever was
--     focused before the focus was processed. So: if the target is already
--     active, resize straight away; otherwise focus first and resize from a
--     timer, once the queue has drained.
--   * A resize can be swallowed entirely -- the tiler clamps a request that
--     does not fit its parent and, in the nested layouts a swipe produces,
--     sometimes drops it. So the size is read back afterwards and the resize
--     is retried once against the size the window actually has.
local function resizeTo(addr, width, height)
    local w = hl.get_window("address:" .. addr)
    if not w then return end
    local want = {
        x = math.max(MIN_SIDE_W, math.floor(width)),
        y = math.max(MIN_SIDE_H, math.floor(height))
    }

    local function fire(attempt, from)
        local cur = hl.get_window("address:" .. addr)
        if not cur then return end
        local aw = hl.get_active_window()
        if not aw or aw.address ~= addr then
            -- The focus has not been processed yet (dispatch is queued).
            hl.dispatch(hl.dsp.focus({ window = cur }))
            if attempt < 3 then
                hl.timer(function() fire(attempt + 1, from) end, { timeout = 45, type = "oneshot" })
            end
            return
        end
        local tx, ty = want.x, want.y
        if from then
            -- A previous attempt was clamped or dropped. Ask for the same
            -- CHANGE again, measured from where the window actually is now.
            tx = math.max(MIN_SIDE_W, cur.size.x + (want.x - from.x))
            ty = math.max(MIN_SIDE_H, cur.size.y + (want.y - from.y))
        end
        hl.dispatch(hl.dsp.window.resize({ x = tostring(tx), y = tostring(ty) }))
        if attempt < 2 then
            hl.timer(function()
                local after = hl.get_window("address:" .. addr)
                if not after then return end
                if math.abs(after.size.x - tx) > 8 or math.abs(after.size.y - ty) > 8 then
                    tracef("  resize retry %s %dx%d wanted %dx%d",
                        tostring(after.class), after.size.x, after.size.y, tx, ty)
                    fire(attempt + 1, from or { x = after.size.x, y = after.size.y })
                end
            end, { timeout = 120, type = "oneshot" })
        end
    end

    local aw = hl.get_active_window()
    if aw and aw.address == addr then
        fire(1, nil)
    else
        hl.dispatch(hl.dsp.focus({ window = w }))
        hl.timer(function() fire(1, nil) end, { timeout = 45, type = "oneshot" })
    end
end

-- Trade places with another window. `window.move` (movewindow) restructures
-- the tiler tree, and in a layout with a stack beside a full-height window it
-- leaves holes -- verified: moving a full-height window into a column that
-- held two stacked ones left the opposite quadrant EMPTY and put two windows
-- in the same slot. `window.swap` exchanges the two nodes in place, which
-- gives the same visible result (both apps change position AND size, the
-- layout stays gap-free) without the tree surgery. Falls back to `move` only
-- if this build ever stops accepting `target`.
local function swapWith(addr, targetAddr)
    local me = hl.get_window("address:" .. addr)
    local other = hl.get_window("address:" .. targetAddr)
    if not me or not other then return false end
    hl.dispatch(hl.dsp.focus({ window = me }))
    local ok = pcall(function()
        hl.dispatch(hl.dsp.window.swap({ target = other }))
    end)
    return ok
end

-- Force the tiler to re-seat a window: float it and immediately un-float it.
-- Un-floating re-inserts the window into the tree, and the tree hands it a
-- fair cell again.
--
-- This is the ONLY way back from a window the tiler has wedged, and that is
-- not a guess. Measured: once a stacked window has been squeezed to 9px wide
-- it refuses EVERY growth request afterwards -- 200, 391 and 600 all came
-- back with no change at all -- so no amount of swiping can change its size
-- again. Float/un-float took the same window from 9x468 to 294x232 and left
-- its column neighbour at 294x230: the two of them evened out, which is the
-- whole point.
-- Forward declaration: `refocus` is defined below this point, and a local
-- function is only visible to code textually after it.
--
-- This declaration was DEAD for a long time and the cost was a live bug. The
-- definition below was spelled `function refocus(addr)` -- a GLOBAL assignment
-- -- so it never assigned to this local. Every call therefore resolved to a
-- nil GLOBAL, and the only reason it went unnoticed is that the calls are all
-- inside `hl.timer` callbacks and pcall bodies, where a throw is swallowed.
--
-- Measured, by running the exact call: `attempt to call a nil value (global
-- 'refocus')`. It fired on every three-finger refusal, in restore(), AFTER
-- the window had been put back -- so the shiver ran and then the error banner
-- appeared, which is exactly the reported symptom.
--
-- THE SPELLING MATTERS TWICE OVER, and this file has now got it wrong in BOTH
-- directions. Only a BARE `function refocus(addr)` assigns to this local. A
-- `local function refocus(addr)` is sugar for `local refocus; refocus = ...`:
-- it declares a SECOND local, shadowing this one, so this declaration stays
-- nil forever and every call still raises
-- `attempt to call a nil value (upvalue 'refocus')`. Identical symptom, so
-- "fix" attempts that only swap one of the two spellings change nothing --
-- which is exactly what happened once. Checked mechanically now, by scanning
-- every forward declaration in this file against every `local function` of
-- the same name.
local refocus

local function reseat(addr)
    local w = hl.get_window("address:" .. addr)
    if not w then return end
    hl.dispatch(hl.dsp.focus({ window = w }))
    hl.dispatch(hl.dsp.window.float({ action = "set" }))
    local function unfloat()
        local cur = hl.get_window("address:" .. addr)
        if not cur then return end
        local aw = hl.get_active_window()
        if not aw or aw.address ~= addr then hl.dispatch(hl.dsp.focus({ window = cur })) end
        hl.dispatch(hl.dsp.window.float({ action = "unset" }))
        hl.timer(function() refocus(addr) end, { timeout = 60, type = "oneshot" })
    end
    hl.timer(unfloat, { timeout = 70, type = "oneshot" })
    -- Belt and braces: never leave the window floating if a dispatch is lost.
    hl.timer(function()
        local cur = hl.get_window("address:" .. addr)
        if cur and cur.floating then
            trace("  reseat: unfloating late")
            unfloat()
        end
    end, { timeout = 500, type = "oneshot" })
end

-- Hand `give` px of room along `axis` from the focused window to `other`.
--
-- Used when a swipe lands on a window that is exactly the same size as the
-- one under the pointer: swapping those two moves the apps but leaves every
-- number on screen where it was, which is what "the swipe doesn't change
-- their sizes" looks like (two windows in one narrow column, say). In that
-- case the swipe means "give that window more room", and this is that --
-- the same two resizes the dead-end retract already makes, in the same
-- order, so it inherits the same safety.
local function transferTo(addr, otherAddr, axis, wins)
    local me = hl.get_window("address:" .. addr)
    local other = hl.get_window("address:" .. otherAddr)
    if not me or not other then return false end
    local give = retractAllowance(me, other, wins, axis)
    if give < RETRACT_MIN then return false end
    local mw, mh = me.size.x, me.size.y
    local ow, oh = other.size.x, other.size.y
    if axis == "x" then
        resizeTo(otherAddr, ow + give, oh)
        hl.timer(function() resizeTo(addr, mw - give, mh) end, { timeout = 70, type = "oneshot" })
    else
        resizeTo(otherAddr, ow, oh + give)
        hl.timer(function() resizeTo(addr, mw, mh - give) end, { timeout = 70, type = "oneshot" })
    end
    tracef("  transfer %s by %d to %s", axis, give, tostring(other.class))
    return true
end

-- ═══ Pressed against the wall ═══════════════════════════════════════════
--
-- REQUESTED (2026-10-01): a swipe at an edge -- where there is no window to
-- trade with -- should feel like shoving the window into the wall, and the
-- window should be squashed flat by it while whatever sits beside it takes
-- the room.
--
-- What it CANNOT be is a restack: two apps side by side, three fingers down,
-- ending up one above the other. That is measured, not assumed, and the
-- measurements are at the call site. The short version: this is Dwindle, its
-- split axis is fixed by the order the windows arrived, `window.move` is a
-- swap that does nothing at a dead end, `window.resize` only trades room along
-- the axis the layout is already splitting, and float/un-float puts a window
-- back in the node it left. So the press can only give ground along an axis
-- the layout is already splitting, which is why the AXIS is measured rather
-- than assumed: see spanAxis below.
--
-- One resize of the pressed window does the whole thing: measured, asking a
-- 791px column for 1588 came back 1507 with its sibling squeezed to 75 --
-- Dwindle pays for the request out of the sibling, so the two windows always
-- end up exactly filling the band and no hole can appear.
--
-- THE PRESS SNAPS TO THE GRID. IT NEVER RESIZES BY A RATIO. A press gives up
-- exactly ONE CELL and whatever was sharing the band grows into it:
--
--     4 apps in a 2x2, every window already one cell  -> the press does
--     NOTHING. There is no finer cell to fall into, so the swipe is a no-op.
--
--     3 apps, one spanning two cells beside two that span one each -> the
--     two-cell window becomes one cell, its neighbour becomes two.
--
-- The cell is READ OFF THE LAYOUT, not assumed -- but it is not a fixed size
-- either. Dwindle only ever splits in two, so the finest division present IS
-- the grid: "is anything smaller than me beside me" is what decides whether we
-- are still spanning more than one cell, and the 2x2 case (nothing smaller
-- anywhere) is therefore correctly a no-op. The SIZE of the cell we hand over
-- is then simply half of our own extent, so the neighbour that was half our
-- size takes the whole cell and doubles. Nothing here is measured against a
-- constant, which is why the same press reads correctly on a 3-app layout and
-- on a 4x4 one.
--
-- THE CELL IS FIXED, NOT MEASURED FROM THE SWIPE. The gesture action takes no
-- arguments on this build, so how hard the push was cannot be read off it; a
-- press is always one cell, never two. Stated rather than implied.
--
-- The window a press TRADES with: the one sharing our band -- beside us, or
-- above/below us. Overlap on the cross axis decides "shares a band"; the
-- largest overlap wins, nearest breaks a tie.
local function bandPartner(me, wins)
    local best, bestOverlap, bestDistance = nil, nil, nil
    for _, o in ipairs(wins) do
        if o.address ~= me.address then
            -- Sharing a ROW (overlap in y) means side by side; sharing a
            -- COLUMN (overlap in x) means stacked.
            local sideBySide = rectsOverlap(o, me, "y")
            local stacked = rectsOverlap(o, me, "x")
            local overlap = math.max(sideBySide, stacked)
            if overlap > 0 then
                local distance = (sideBySide >= stacked)
                    and math.abs(o.at.x - me.at.x)
                    or math.abs(o.at.y - me.at.y)
                if best == nil or overlap > bestOverlap
                    or (overlap == bestOverlap and distance < bestDistance) then
                    best, bestOverlap, bestDistance = o, overlap, distance
                end
            end
        end
    end
    return best
end

-- ONE GRID CELL, measured from the layout: the finest division the workspace
-- already contains along `axis`, i.e. the smallest extent any other tiled
-- window occupies. `wins` is already filtered to real tiled windows (no
-- floaters, no fullscreen, no pinned -- see fieldsInWorkspace), so the grid is
-- read off the whole layout rather than off one band.
--
-- Requiring the windows to SHARE A BAND first was measured to be wrong, and
-- wrong on the exact layout this is for: a window two cells tall sits in a
-- column of its own, so nothing shares its column, and the press refused the
-- one case it was built for. The grid is a property of the screen, not of a
-- pair.
--
-- Only windows strictly SMALLER than us set the cell. A window already the
-- size of everything around it is one cell already, which is exactly the 2x2
-- case where the press must do nothing.
local function gridStep(me, wins, axis)
    local mine = (axis == "x") and me.size.x or me.size.y
    local step = nil
    for _, o in ipairs(wins) do
        if o.address ~= me.address then
            local theirs = (axis == "x") and o.size.x or o.size.y
            if theirs < mine - 1 and (step == nil or theirs < step) then
                step = theirs
            end
        end
    end
    return step
end

-- WHICH AXIS THE PRESS TRADES, AND HOW BIG A CELL IS. A window spans more than
-- one cell on an axis exactly when something sharing its band is smaller than
-- it on THAT axis: a tall window beside two short ones is two cells TALL, and
-- height is what it gives up.
--
-- Deriving the axis from the PAIR instead -- from the axis the two windows
-- share -- was measured to be wrong. Two windows side by side share their
-- height, so that rule always answered "width"; a tall window beside two
-- short ones has the same width as both, so it came back "already a single
-- cell" and the press did nothing on the one layout that should have snapped.
--
-- Neither axis smaller than us means we are one cell already, so there is
-- nothing to fall into. When both axes qualify (a window bigger than its
-- neighbours in both directions) the one it spans MORE cells of wins: that is
-- the coarser, more meaningful cell.

-- WHY THE PRESS DOES NOT RESIZE (this used to be tradeableOn, now removed).
-- These are the measurements that ruled the resize path out, kept because they
-- are the reason pressBand moves a window instead of resizing one:
--
--   * Two windows side by side, asking for a height -> SILENTLY IGNORED. That
--     pair is split on width, so height is not a dimension it can trade.
--   * Two windows stacked, asking for a height -> applied.
--   * A window ALONE in its column -> height silently ignored, whatever it is
--     asked for. Its column has no vertical split, so its height is simply
--     not a traded dimension.
--   * A window spanning the FULL WIDTH, asking for a width -> silently
--     ignored, in BOTH the plain and the "exact" form (verified asking 791 of
--     1588). It has no row-mate to pay the request out of.
--
-- Dwindle pays a resize out of a sibling along the axis the layout is already
-- splitting. A window that spans the whole width, or stands alone in its
-- column, has no such sibling -- so the request is discarded without any
-- error, and the swipe looks broken. That was the reported symptom.

local function spanAxis(me, wins)
    local best = nil
    for _, axis in ipairs({ "x", "y" }) do
        local step = gridStep(me, wins, axis)
        -- Oversized only. Whether the axis is TRADEABLE is deliberately not
        -- checked here: a lone two-cell window spans an axis it cannot trade,
        -- and that is precisely the case the move below exists to handle.
        if step then
            local mine = (axis == "x") and me.size.x or me.size.y
            local span = mine / step
            if best == nil or span > best.span then
                best = { axis = axis, cell = step, span = span }
            end
        end
    end
    if not best then return nil, nil end
    return best.axis, best.cell
end

-- (This used to be rowMates, the "windows beside us" lookup, and before that
-- colMates, the "windows above and below" lookup. Both are gone: each found
-- nothing in half the layouts, which is exactly how the press came to refuse
-- and then to fall through to a resize the tiler discarded. swipeBand now
-- takes the union of the two, and the reasoning survives in its notes.)

-- WHICH NEIGHBOUR GROWS, GIVEN A HORIZONTAL SWIPE. The user named this exactly:
-- THE BAND FOR A GIVEN SWIPE: every window that shares a line with us, whether
-- beside us or above/below us.
--
-- Why the union, measured: which set can actually grow depends on the layout,
-- and neither half is enough on its own.
--
--   * "lone full-height window beside a two-window stack": the stack shares our
--     ROW (it is in the other column, so it overlaps us in y but not in x).
--     A vertical swipe grows the bottom of that stack. (measured: P 791x988 ->
--     791x491, the bottom of the stack 791x491 -> 1588x491, the top untouched)
--
--   * "long window across the bottom, two windows side by side above it": the
--     pair share our COLUMN (they overlap us in x, not in y). A downward swipe
--     lowers us and the window above extends. (measured: P 1588x468 ->
--     791x468 in the bottom-right cell, the top-left window 791x469 ->
--     791x943, the other untouched)
--
-- Asking only for the row-band finds nothing in the second layout and only for
-- the column-band finds nothing in the first, so the press refused half the
-- time. The union is what "there is something to press into" actually means.
--
-- NOTE the grower below only chooses which window gets NAMED in the trace
-- line. The behaviour itself comes from the single `move` along the swipe
-- direction; the tiler decides what actually grows. So an imprecise pick
-- costs a slightly wrong log line, never a wrong layout.
local function swipeBand(me, wins, direction)
    local mates = {}
    for _, o in ipairs(wins) do
        if o.address ~= me.address
            and (rectsOverlap(o, me, "y") > 0 or rectsOverlap(o, me, "x") > 0) then
            mates[#mates + 1] = o
        end
    end
    table.sort(mates, function(a, b)
        if a.at.y ~= b.at.y then return a.at.y < b.at.y end
        return a.at.x < b.at.x
    end)
    return mates
end

-- swiping right on the long window grows the window ABOVE-LEFT of it, and
-- swiping left grows the one ABOVE-RIGHT. The pressed window keeps its own
-- corner and just gives up the width; nothing is exchanged.
--
-- The vertical pair is the same rule stood on end, and was measured the same
-- way on a lone full-height window beside a two-window stack:
--
--   swipe UP   -> the window BELOW grows across the band; the pressed window
--                 keeps the top and gives up a cell.  (measured: P 791x988 ->
--                 791x491 staying at 6,6; the window below 791x491 ->
--                 1588x491; the one above untouched)
--
--   swipe DOWN -> the window ABOVE grows across the band, and the pressed
--                 window is LOWERED to the bottom row.  (measured: P 6,6
--                 791x988 -> 6,503 791x491; the window above 791x491 ->
--                 1588x491; the one below untouched)
--
-- So the grower is the window on the FAR SIDE of the swipe, chosen by extreme
-- position along the swipe axis, not by distance. Returns nil when the band is
-- empty, which is the honest "there is nothing to grow" answer.
local function growerFor(me, mates, direction)
    if #mates == 0 then return nil end
    local vertical = (direction == "up" or direction == "down")
    local best = nil
    for _, o in ipairs(mates) do
        if best == nil then
            best = o
        elseif vertical then
            -- far side of an UP swipe is DOWN, so take the lowest window;
            -- far side of a DOWN swipe is UP, so take the highest.
            if direction == "up" then
                if o.at.y > best.at.y then best = o end
            else
                if o.at.y < best.at.y then best = o end
            end
        elseif direction == "right" then
            -- the far side of a rightward swipe is the LEFT: take left-most
            if o.at.x < best.at.x then best = o end
        else
            -- the far side of a leftward swipe is the RIGHT: take right-most
            if o.at.x > best.at.x then best = o end
        end
    end
    return best
end

-- THE PRESS. Two ways to answer a swipe into a border, and the FIRST one is
-- the one that actually produces the grid that was asked for.
--
-- 1. SIDEWAYS PRESS ON A FULL-WIDTH WINDOW (the reported case). Two windows
--    side by side on top, one long window across the bottom; swipe left or
--    right on the long one.
--
--    WHY THIS IS NOT A RESIZE, MEASURED: a window spanning the full width has
--    no sibling in its own row, and Dwindle pays a resize out of that sibling.
--    Asking it for half its width is therefore SILENTLY DISCARDED -- verified
--    for both the plain form and the "exact" form, at 791 out of 1588. Only
--    height moves on such a window. So the old resize path could not have
--    worked here no matter how it was written.
--
--    WHY THIS IS NOT A MOVE, MEASURED: `window.move` does not slide a window
--    out of the way, it EXCHANGES two windows. Dragging the long one sideways
--    swapped it with a neighbour, which is the "you keep swapping browsers"
--    complaint.
--
--    WHAT WORKS, MEASURED FROM A VERIFIED-CLEAN START (3 windows, two on top,
--    one full width below; swipe right):
--
--        before   F 6,51 791x469    D 803,51 791x469    P 6,526 1588x468
--        after    F 6,51 791x943    D 803,51 791x469    P 803,526 791x468
--
--    F grew in place to full height. D was not touched AT ALL -- same origin,
--    same size. P kept its bottom row and gave up exactly the width of one
--    cell. Nothing was exchanged: no two apps changed places, which is the
--    whole point. Swipe left is the mirror and was measured the same way:
--    the top-RIGHT window grows to 791x943, the top-left is untouched, and P
--    becomes the bottom-left cell.
--
--    So the gesture moves the PRESSED window one cell along the swipe, and the
--    window on the FAR side of the swipe is the one that grows into the space.
--    That is the opposite of what `move` did, and it is what was asked for.
--
-- 2. HALVE, for the vertical presses and for the single-column layouts. There
--    the long axis IS traded, so halving works.
local function pressBand(me, partner, wins, direction)
    local addr = me.address
    -- spanAxis answers one question: is this window still spanning more than
    -- one cell on either axis? If not, there is nothing to snap to.
    local axis = spanAxis(me, wins)
    if not axis then
        trace("  press refused: already one cell, the grid has nothing finer")
        return false
    end

    -- 1. A swipe in any of the four directions. ONE rule, measured in both
    --    orientations: move OURSELVES along the swipe and the window on the
    --    FAR side of it is the one that grows. Nothing is exchanged.
    --
    --    The band is every window that shares a line with us, above/below or
    --    beside -- see swipeBand. The old lookup only ever looked at ONE of
    --    those two, which is why the press did nothing on the screenshot
    --    layout and why the vertical case needed a second, different path.
    --
    --    The vertical case used to move a window SIDEWAYS across the column
    --    boundary, which is what made an upward swipe change the two stacked
    --    windows' places, and made a downward swipe move the far bottom
    --    window instead of lowering us. Both are gone; up and down are now
    --    simply the vertical form of the
    --    same rule.
    local mates = swipeBand(me, wins, direction)
    local grower = growerFor(me, mates, direction)
    if grower then
        trace(string.format(
            "  press %s: %s gives up one cell %s, %s grows to two",
            direction, tostring(me.class), direction, tostring(grower.class)))
        -- Move OURSELVES one cell along the swipe. The tiler re-cuts the band
        -- so the far neighbour doubles; no two windows change places.
        hl.dispatch(hl.dsp.focus({ window = me }))
        hl.dispatch(hl.dsp.window.move({ direction = direction }))
        hl.timer(function() refocus(addr) end, { timeout = 120, type = "oneshot" })
        return true
    end
    trace("  press refused: no window in the band on the far side to grow")
    return false
end

-- The press, and the retract it falls back to ═══════════════════════
--
-- `retractDeadEnd` is the dead-end branch: a bounded give along one axis,
-- paid for by our own window or by the neighbour on the far side. Two
-- resizes inside an existing tree, no re-cutting -- which is exactly why it
-- is all this tiler allows (see the measurement at the call site).
local function retractDeadEnd(me, across, direction, wins)
    local addr = me.address
    local selfAxis = RETRACT_ON_SELF[direction]
    local otherAxis = RETRACT_ON_OTHER[direction]
    if selfAxis then
        local give = retractAllowance(me, across, wins, selfAxis)
        if give < RETRACT_MIN then
            trace("  retract refused: no room to give")
            return false
        end
        tracef("  retract self %s by %d", selfAxis, give)
        if selfAxis == "x" then
            resizeTo(addr, me.size.x - give, me.size.y)
        else
            resizeTo(addr, me.size.x, me.size.y - give)
        end
    else
        local give = retractAllowance(me, across, wins, otherAxis)
        if give < RETRACT_MIN then
            trace("  retract refused: no room to give")
            return false
        end
        tracef("  retract other %s by %d", otherAxis, give)
        if otherAxis == "x" then
            resizeTo(across.address, across.size.x + give, across.size.y)
        else
            resizeTo(across.address, across.size.x, across.size.y + give)
        end
    end
    hl.timer(function() refocus(addr) end, { timeout = 90, type = "oneshot" })
    return true
end

-- Shove the focused window against the wall it was swiped at.
--
-- Everything about the geometry is read AFTER the move, from fresh window
-- objects, because the ones captured before it describe a layout that no
-- longer exists -- and the partner is found in the NEW layout too, where it
-- is the window the press displaced rather than the one that happened to be
-- on the far side beforehand.
-- Re-focus a window by ADDRESS. The object captured before a move goes stale
-- once the tiler re-tiles (a `focus` carrying it is then silently dropped,
-- which is how a swipe used to end up leaving focus on some other window).
--
-- BARE `function`, NOT `local function`, and the comment that used to say the
-- opposite here was itself the bug: only a bare `function` assigns to the
-- forward declaration above. `local function` shadows it and leaves every call
-- site resolving to nil. See the note on that declaration.
function refocus(addr)
    local w = hl.get_window("address:" .. addr)
    if w then hl.dispatch(hl.dsp.focus({ window = w })) end
end

-- ── The three-finger field swipe: TRADE the layout, never just the focus ──
--
-- REQUESTED (2026-09-29). This used to SWAP focus with the window in the
-- swiped direction and move nothing, and because focusing warps the pointer
-- (follow_mouse), the only thing a three-finger swipe visibly did was drag
-- the cursor onto the other window. The rule now:
--
--   1. THERE IS A WINDOW OVER THERE -> the focused window TRADES PLACES with
--      it. The two slots are exchanged, so the apps change position AND size,
--      which is what rearranging a desktop is supposed to mean. The trade is
--      done with `swap`, not `move`: `move` rewrites the tiler tree and in an
--      uneven layout (a narrow stack beside a full-height window) it punches
--      holes in it -- the very "weirdly created space" the user is trying to
--      swipe away, and impossible to swipe back out of.
--
--   2. NOTHING OVER THERE (upward from the top window, say) -> the focused
--      window is PRESSED against the wall it was swiped at: the tiler tree is
--      re-cut so it ends up flush against that edge and the windows beside it
--      are shoved out of the way, and the arrangement changes with it. Two
--      side-by-side windows and a swipe down become one above the other. When
--      the move does not land, this falls back to the older behaviour -- give
--      up a bounded slice of one axis to the neighbour on the far side --
--      which never changes the arrangement. Focus comes back to the window
--      the user was looking at either way.
--
--   3. Two windows of the SAME size (the two halves of one narrow column) ->
--      trading them would move the apps without changing a single number, so
--      the swipe hands room to the one that was swiped at instead. This is the
--      case that used to read as "the swipe does nothing".
--
--   4. The focused window is a SLIVER (< MIN_SIDE) -> the swipe repairs it
--      instead of rearranging anything, because a window the tiler has wedged
--      ignores every size request (see reseat) and is unrecoverable by
--      resizing, retracting or swapping.
--
-- No branch can leave a sliver behind: every size asked for is floored at
-- MIN_SIDE_W/MIN_SIDE_H, and room is only ever taken from windows that have
-- more than the floor to spare (see retractAllowance).
--
-- The pointer is held still across all of them (see cursorHold).
-- Forward declaration, and it has to sit HERE rather than beside the real
-- definition. The real one needs DIALOG_CLASSES and lives ~1700 lines below,
-- but promotePopup, FIELD_SWIPE and anchoredTransition are all ABOVE it and
-- all call it. A `local function` is only visible from its definition
-- onwards, so without this declaration their calls resolve to a GLOBAL
-- `isDialogClass` -- nil -- and raise "attempt to call a nil value" inside a
-- gesture handler, where nothing surfaces it: the swipe simply stops
-- working. `luac -p` does not catch this, because it is correct Lua; only
-- the ordering is wrong.
local isDialogClass

-- Forward declaration for the same reason, and it sits here for the same
-- reason. The gesture handlers that call it are just below; its body needs
-- setFloat (further down) and isDialogClass (much further down still).
local attachFocusedFloat

-- Forward declaration for the THIRD time this file needs one, and for the
-- same underlying reason: FIELD_SWIPE (just below) has to be able to say "this
-- swipe did nothing", and the only thing that can make a window visibly
-- refuse is defined next to the dead-edge pulse, ~400 lines further down.
local bumpRefusal

-- TWO MORE, found the same way, both on the three-finger path, both live.
--
-- promotePopup sits just below and calls findWindow and setFloat, whose
-- definitions are ~900 and ~950 lines further down (they live with the
-- float/fullscreen helpers). Nothing declared them early, so both calls
-- resolved to GLOBALS -- nil -- and threw the moment a three-finger swipe
-- landed on a floating window:
--
--   custom/general.lua:1459: attempt to call a nil value (global 'findWindow')
--
-- That is the three-finger error that came back after it was believed fixed.
-- The throw happens inside FIELD_SWIPE's pcall, so the swipe is reported as
-- failed and the attach gesture never runs -- the symptom is "three-finger
-- swipes do nothing and an error banner appears", which is what was reported.
local findWindow
local setFloat

-- ═══ Promoting a popup: "I want to KEEP this one" ═══════════════════════
--
-- A popup is a temporary thing by definition -- it floats because it
-- arrived, does one job and goes away. But two actions say the opposite:
-- you swiped it somewhere with the window, or you gave it the whole screen
-- and took it back. Both are ways of treating a window as a real one, and
-- both should leave it as one.
--
-- So this is the promotion rule, in one line: a floating window that the
-- user deliberately MOVES or FULLSCREENS becomes attached. Until then it
-- stays a popup. Nothing about the popup decision itself changes -- a
-- captcha that nobody touches still floats and still closes.
--
-- Dialogs are exempt, and must be. A file chooser, a polkit agent, an
-- "are you sure" -- these float BECAUSE they are dialogs, and a dialog that
-- the user fullscreened or swiped is still a dialog; tiling it would drop a
-- system prompt into the layout with no way back. The exemption is checked
-- BEFORE any float dispatch, so the worst case is that a promoted window
-- keeps floating, which is today's behaviour.
local function promotePopup(addr)
    local w = findWindow(addr)
    if not w or not w.floating then return false end
    if isDialogClass(w.class or w.initialClass) then return false end
    -- setFloat focuses the window first and only reports success once it
    -- has read the window back, so a lost dispatch is not believed.
    return setFloat(addr, false)
end

function FIELD_SWIPE(direction)
    -- `didSomething` is the whole point of the bump: every branch below that
    -- acts on the layout sets it, and the one exit that does not is the
    -- refusal. It is a local of the pcall rather than a return value because
    -- the branches `return` from inside it, and a `return` would skip any code
    -- after the pcall.
    local didSomething = false
    local refused = false
    local ok, err = pcall(function()
        local me = hl.get_active_window()
        if not me then return end
        local ws = me.workspace
        if not ws or not ws.id or ws.id < 1 then return end
        -- A floating window used to be skipped outright here, which is what
        -- made a three-finger swipe over a popup do nothing at all. It is now
        -- read as the one thing a swipe over a popup can mean -- "keep this
        -- one" -- and the window is attached. The swipe itself does not then
        -- also rearrange the layout in the same breath: the tiler has not
        -- seen the window yet, so every rect it would compute is stale, and
        -- the second swipe (once the window has settled) does the arranging.
        if me.floating then
            if promotePopup(me.address) then
                didSomething = true
                trace(string.format("FIELD_SWIPE %s: promoted popup %s to the layout",
                    direction, tostring(me.class)))
            else
                -- A DIALOG: promotePopup refuses it by design, so the swipe
                -- genuinely achieved nothing. It is also the one refusal that
                -- must stay silent -- bumpRefusal checks the same predicate
                -- and returns before touching any geometry.
                refused = true
            end
            return
        end

        local wins = fieldsInWorkspace(ws.id)
        tracef("FIELD_SWIPE %s me=%s ws=%d wins=%d", direction,
            tostring(me.class), ws.id, #wins)
        -- One window on the desktop: there is nothing to swap with, nothing
        -- to press against and nothing to retract into. This is the dead end
        -- the request describes, and it is the most common one -- a single
        -- full-screen app is what most desktops actually look like.
        if #wins <= 1 then
            refused = true
            return
        end

        local addr = me.address
        local releaseCursor = cursorHold()

        -- 0. A swipe that lands on a window the tiler has already mangled is
        --    the user's way out of it. A window under the size floor is not
        --    resized -- the tiler ignores growth requests that size (see
        --    reseat) -- it is floated and un-floated, which is the one thing
        --    that does work. Fixing it is the whole swipe: the layout the user
        --    was complaining about is a layout with a sliver in it.
        if me.size.x < MIN_SIDE_W or me.size.y < MIN_SIDE_H then
            tracef("  repairing sliver %dx%d", me.size.x, me.size.y)
            reseat(addr)
            releaseCursor()
            didSomething = true
            return
        end

        -- 1. Something over there: trade places with it. Positions and sizes
        --    change, and the tiler keeps every cell covered.
        local target = neighbourInDirection(me, wins, direction)
        trace("  moveTarget=" .. tostring(target and target.class))
        if target then
            -- Two windows of the same size: trading them places would move the
            -- apps without changing a single number, so the swipe gives the
            -- room to the one that was swiped at instead.
            local sameSize = math.abs(target.size.x - me.size.x) <= 8
                and math.abs(target.size.y - me.size.y) <= 8
            if sameSize and transferTo(addr, target.address, SWIPE_AXIS[direction], wins) then
                hl.timer(function() refocus(addr) end, { timeout = 140, type = "oneshot" })
                releaseCursor()
                didSomething = true
                return
            end
            if swapWith(addr, target.address) then
                trace("  swapped with " .. tostring(target.class))
                refocus(addr)
            else
                -- Only if this build ever stops taking `target`.
                hl.dispatch(hl.dsp.focus({ window = me }))
                hl.dispatch(hl.dsp.window.move({ direction = SWIPE_DIR[direction] }))
            end
            releaseCursor()
            didSomething = true
            return
        end-- 2. Dead end: PRESS the window against the wall it was swiped at. It
        --    gives up exactly ONE GRID CELL along the axis this layout is
        --    splitting, and the neighbour that was sharing its band grows into
        --    it. A window that is already a single cell is left alone -- in a
        --    2x2 of four apps there is nothing finer to fall into, so the
        --    swipe is a deliberate no-op. See the measurement block above for
        --    why this trades the layout's axis instead of restacking the pair:
        --    the honest version of "the wall wins" on a tiler that cannot
        --    re-cut itself.
        local partner = bandPartner(me, wins)
        if partner then
            -- A refusal is the ANSWER here, not a reason to look for another
            -- way to act: falling through to the retract would give the 2x2
            -- case something to do, which is the opposite of what was asked.
            --
            -- pressBand returns whether it actually re-cut anything, and a
            -- false here is the 2x2 dead end: four apps, all one cell, no
            -- finer grid to fall into. That is a refusal, and it is the case
            -- the request is really about -- a swipe that visibly does nothing
            -- at all rather than one that does something small.
            if pressBand(me, partner, wins, direction) then
                didSomething = true
            else
                refused = true
            end
            releaseCursor()
            return
        end

        -- Nothing shares our band, so there is no room to trade. The old
        -- retract still answers the swipe when a window does sit on the far
        -- side (measured: reachable, and still the better answer than
        -- nothing).
 local across = neighbourInDirection(me, wins, RETRACT_ACROSS[direction])
  trace("  retractAcross=" .. tostring(across and across.class))
        if not across then
     releaseCursor()
            -- Dead end with nothing at all on the far side. Nothing was
            -- traded, nothing was resized: the silent no-op.
            refused = true
            return
        end
        -- retractDeadEnd reports whether it found room to give. "No room" is
        -- the same silence as the branches above, so it gets the same answer.
        if retractDeadEnd(me, across, direction, wins) then
            didSomething = true
        else
            refused = true
        end

        -- Back to the window the swipe was aimed at, and the pointer where the
        -- user left it.
        releaseCursor()
    end)
    if not ok then trace("FIELD_SWIPE FAILED: " .. tostring(err)) end
    -- The refusal shake, and ONLY for a refusal. Deliberately after the pcall
    -- so a throw on any branch is reported and then still answers the swipe:
    -- a gesture that dies mid-way and says nothing is exactly the
    -- indistinguishable-from-broken case the bump exists to remove.
    --
    -- `refused` and not `not didSomething`: a branch can neither act nor
    -- refuse (no active window, a special workspace), and those must stay
    -- silent rather than shaking a desktop nobody swiped.
    -- The direction is passed through so the window is pushed into the wall
    -- the swipe was aimed at. Without it the vibration would be symmetric and
    -- directionless, which reads as a twitch rather than a refusal.
    if refused and not didSomething then bumpRefusal(direction) end
end

-- ── 3 fingers: wallpaper carousel first, island panel second, field-swipe last

--
-- The two finger counts share the GUARDS and then decide differently, so the
-- guards are factored out rather than the whole action: the carousel claim,
-- the float attach and the panel close must not be able to drift apart
-- between the two registrations.
--
-- Returns true when the swipe has been consumed and means nothing else.
local function SWIPE_DOWN_GUARDS()
    -- The carousel is up: its own handlers own this swipe entirely
    -- (a decisive down-flick closes the theatre from inside).
    if wallpaperStageOpen() then return true end
    -- A float that should not be one gets attached, and the swipe is
    -- spent. Checked before the panel and the field move so the verdict
    -- is the user's first say about the window under their fingers.
    if attachFocusedFloat() then return true end
    -- The popped-out card is open: fingers DOWN close it. Closing
    -- wins over everything else; in particular the field-move below must
    -- not act on a window hidden behind the card's dimmer.
    if nowBarPanelOpen() then
        hl.dispatch(hl.dsp.global("quickshell:nowbarPanelClose"))
        return true
    end
    return false
end

-- Three fingers down: the whole gesture, bar or no bar.
local function SWIPE_DOWN_POP()
    if SWIPE_DOWN_GUARDS() then return end
    -- REQUESTED (2026-10-03): THE POPUP OPENS ONLY WITH THE CURSOR OVER THE
    -- MIDDLE TOP BAR. Not over the left island, not over the right one, not
    -- over empty screen -- the middle bar only. Everywhere else this swipe is
    -- the field layout's, exactly as it was before the popup was given a
    -- gesture.
    --
    -- TWO conditions, both required, and the second one is not decoration:
    --
    --   cursorOnMiddleBar()   the pointer is on the middle bar right now,
    --                         and that bar is actually on screen
    --
    -- The second half of the condition is inside the helper: it reads the
    -- same file, and refuses to answer "yes" for a bar that is not visible,
    -- so a popup can never be popped for a bar nobody can see.
    --
    -- Anything not positively known to be over the middle bar falls through
    -- to the field, including every "cannot know" case -- a shell that is down
    -- leaves this swipe doing what it did before any of this existed rather
    -- than going quiet.
    -- LOGGED BEFORE ANYTHING ELSE, and through gateTrace's own pcall, so
    -- that a failure anywhere below still leaves a line saying the swipe
    -- arrived. The trace is not a nicety here: this gate has been wrong in
    -- three different ways today and "nothing happened" was the only symptom
    -- every time.
    local stripH, midL, midR = barGeometry()
    local cx, cy = cursorXY()
    local onBar = cursorOnMiddleBar()
    gateTrace(string.format(
        "3fg-down cursor=(%s,%s) mid=%s..%s stripH=%s visible=%s onMiddleBar=%s -> %s",
        tostring(cx), tostring(cy), tostring(midL), tostring(midR),
        tostring(stripH), tostring(stripH and "yes" or "no"),
        tostring(onBar), onBar and "POPUP" or "field"))
    if onBar then
        hl.dispatch(hl.dsp.global("quickshell:nowbarPanelToggle"))
        return
    end
    FIELD_SWIPE("down")
end

-- ── THE BINDING ────────────────────────────────────────────────────────
-- Restored 2026-10-03. `SWIPE_DOWN_POP` was DEFINED and never REGISTERED:
-- removing the two-finger bind below took this `hl.gesture` block with it,
-- and because `hl.gesture` runs rather than declares, nothing complains.
-- The file parses clean, `luac -p` is clean, `hyprctl reload` says ok, and
-- Hyprland still logs a complete three-finger swipe
-- ([3fg] FINGER_DETECTED -> SWIPE_START -> SWIPE -> END) -- while the
-- function that swipe should call is never invoked and never even traced.
--
-- It is worth writing down how that presents, because it is the worst kind of
-- bug to chase: the symptom is "the gesture does nothing", and every check
-- that a person would reach for passes. What exposed it was a load marker --
-- a line after the registration that writes to the trace file -- plus the
-- absence of ANY trace line, which proved the callback was never entered and
-- moved the search upstream of the gate to the binding itself.
--
-- The registration must therefore stay immediately below this function. If
-- the two-finger note below is ever edited, check this block survived.
hl.gesture({
    fingers = 3,
    direction = "down",
    disable_inhibit = true,
    action = SWIPE_DOWN_POP
})

gateTrace("CONFIG LOAD: 3fg-down registered")

-- Two fingers down: the BAR ONLY, and deliberately not the field move.
--
-- REQUESTED (2026-10-03). Nothing else in this config uses a two-finger
-- DIRECTIONAL swipe -- the only two-finger gestures registered are the
-- wallpaper carousel's pinch in and out (further down this file) -- so the
-- slot was free. Hyprland matches swipe gestures on the EXACT finger count,
-- so a three-finger swipe still fires only the gesture above and the two
-- never both run.
--
-- WHY NOT THE WHOLE ACTION, since that was the first thing written here:
--
-- Two fingers on this bar are the BRIGHTNESS and VOLUME swipe. The shell
-- owns that gesture (services/TouchpadSwipe.qml + BarContent.qml) and works
-- in BOTH directions, so every two-finger flick up or down over the bar is
-- already a control the user aims at something on purpose. Giving the
-- two-finger DOWN to the field layout as well would mean one flick in the
-- gap beside the islands turned the volume down AND threw the focused
-- window into the field below it. That is a regression in a gesture that
-- gets used all day, in exchange for something nobody asked for -- the
-- request was about the BAR.
--
-- The shell already declines its own two-finger swipe over an island ("on
-- ANY island the cursor points at content ... whose own meaning wins"), so
-- over the middle island this gesture is the ONLY thing acting on the
-- fingers: nothing to arbitrate, nothing to disable.
--
-- ── Two fingers down: NOT AVAILABLE on this machine, and not a config bug ──
-- A two-finger swipe-down was written here and bound exactly like the
-- three-finger one above. It could never fire, and no amount of editing this
-- file would have changed that:
--
--   hyprland.log, counted over the whole file:
--     [2fg] GESTURE_EVENT_SWIPE_START .... 0
--     [3fg] GESTURE_EVENT_SWIPE_START ... 80
--     [4fg] GESTURE_EVENT_SWIPE_START .. 262
--
-- Two-finger movement on this touchpad is consumed by SCROLLING, so libinput
-- never classifies it as a swipe and Hyprland never invokes a two-finger
-- gesture -- not this one, not any other. (`hyprctl devices` also lists
-- `1a58300a:00-06cb:cf0f-touchpad` under mice rather than touchpads, and
-- `input:scroll_method` is unset, i.e. the 2-finger default.)
--
-- The only way to get two-finger swipes is `input.scroll_method = "finger"`,
-- which would make SCROLLING three-finger -- i.e. two-finger scrolling would
-- stop working everywhere, for a gesture. Requested 2026-10-03: skip it, the
-- three-finger popup is enough. That is why this is a note and not a bind.
--
-- Note that the bar's OWN two-finger brightness/volume swipe is unaffected by
-- any of this -- it is not a compositor gesture at all. It runs in QML off
-- the same evdev node (services/TouchpadSwipe.qml), which is also why it
-- works while no two-finger Hyprland gesture ever does.

-- Three fingers UP: over the island / inside the open panel it puts the
-- card away. Everywhere else it moves the focused window into the field
-- above -- the panel case wins only where the panel actually is.
hl.gesture({
    fingers = 3,
    direction = "up",
    disable_inhibit = true,
    action = function()
        if wallpaperStageOpen() then return end
        if attachFocusedFloat() then return end
        -- Card open: put it away, whichever direction the swipe went. Same
        -- reasoning as the down handler above.
        if nowBarPanelOpen() then
            hl.dispatch(hl.dsp.global("quickshell:nowbarPanelClose"))
            return
        end
        local hovering = readNowBarHover()
        if hovering == false then
            FIELD_SWIPE("up")
            return
        end
        hl.dispatch(hl.dsp.global("quickshell:nowbarPanelClose"))
    end
})

-- ═══ 3 fingers left · right: close a sidebar, else SWAP with the neighbour
--
-- REQUESTED: a three-finger swipe TOWARDS an open sidebar closes it -- left
-- swipe closes the left sidebar, right swipe closes the right one -- and the
-- window underneath does NOT get the gesture. That window is one the user
-- cannot see (a sidebar is 480px of opaque panel over it), so letting
-- FIELD_SWIPE move or swap it would act on something invisible: the sidebar
-- would appear to swallow a swipe aimed at the desktop.
--
-- "Sidebar wins while open" is deliberate and total. With no sidebar open,
-- closeSidebarToward returns false and the swipe falls through to the
-- original behaviour, unchanged: show you the window over there. See
-- FIELD_SWIPE above for that rule (swap, and only move the neighbour when
-- there is nothing to swap with).
--
-- The wallpaper theatre still stands down first: while it is up its own
-- handlers own three fingers 1:1.
-- Keyboard twins: CTRL+SUPER+arrows in custom/keybinds.lua.

-- (A two-finger horizontal bind for the sidebar's tab swipe WAS here, and
-- has been removed after being measured rather than guessed at. It wrote a
-- trace line before every gate on every invocation, and across every swipe
-- that line count was ZERO: Hyprland never delivered the two-finger
-- horizontal gesture to it at all, while the three- and four-finger binds
-- in this same file work. The sidebar does the swipe itself now, in QML, on
-- a surface that is TOPMOST over its whole content -- see the note in
-- modules/ii/sidebarLeft/SidebarLeftContent.qml.)

hl.gesture({
    fingers = 3,
    direction = "left",
    disable_inhibit = true,
    action = function()
        if wallpaperStageOpen() then return end
        -- A float that should not be one gets attached, and the swipe is
        -- spent here rather than reaching the sidebar close or the field
        -- move. Left/right included, deliberately: the request was "any
        -- direction", and a sideways swipe over a floating app is the most
        -- accidental one there is -- it is the gesture people make while
        -- reaching past a window that is in their way.
        if attachFocusedFloat() then return end
        -- A cover that was dragged out of the monitor rect is restored on its
        -- way past, so the workspace you land on is never one whose window
        -- was left floating. Runs AFTER the sidebar close, which is a real
        -- mode the swipe might have been meant for, and BEFORE the switch, so
        -- the repair is already done by the time the desktop changes.
        cover.restoreDrifted()
        if closeSidebarToward("left") then return end
        FIELD_SWIPE("left")
    end
})

hl.gesture({
    fingers = 3,
    direction = "right",
    disable_inhibit = true,
    action = function()
        if wallpaperStageOpen() then return end
        if attachFocusedFloat() then return end
        cover.restoreDrifted()
        if closeSidebarToward("right") then return end
        FIELD_SWIPE("right")
    end
})

-- ═══ 4 fingers left / right: nothing happens here any more ═══════════
--
-- A four-finger horizontal swipe that lands on no desktop used to jolt the
-- whole desktop: DESKTOP_EDGE_PULSE (now gone) moved every window by pulsing
-- general.gaps_workspaces, in step with the wallpaper's own spring
-- (DesktopBump.qml in the Quickshell config) and a whole-screen shader
-- shake. Three answers to one gesture, and none of them agreed about how
-- big the "no" was.
--
-- There is no jolt now, and there is nothing left for this config to do:
-- the shell answers a dead edge the way it answers a real switch, by
-- flashing the desktop pill at the bottom of the screen, and nothing on
-- screen moves. That decision is the shell's because it is the only thing
-- that sees both the gesture and the workspace list -- a second
-- fingers=4 horizontal binding here would be shadowed by the base config's
-- own workspace swipe (the FIRST binding for a direction wins), which is
-- why this block was never a gesture to begin with.

-- ═══ The three-finger refusal: the window itself says "no" ═══════════════
--
-- REQUESTED: a three-finger swipe at a desktop edge that neither resizes nor
-- moves anything should make the APP VIBRATE ONCE, so the swipe reads as
-- "that doesn't work here" rather than as an ignored gesture.
--
-- THE WINDOW REALLY DOES MOVE. MEASURED, NOT ASSUMED.
-- -----------------------------------------------
-- The previous version of this block claimed, in a comment inherited from
-- DESKTOP_EDGE_PULSE, that moving a window was impossible here and so shook
-- the WALLPAPER INSTEAD. The trace log proved that block fired on every swipe
-- while the user saw nothing move. The claims were then measured directly on
-- this machine with `hyprctl eval`, and one of them turned out to be WRONG:
--
--   1. `move({relative=true})` on a TILED window: accepted, then UNDONE.
--      firefox stayed at 6,6 after a +40px nudge. The tiler owns the
--      position. This part of the old comment was right.
--
--   2. BUT `float` does NOT make the window fill the screen. Dispatched on
--      its own, a tiled firefox went 791x988 @ 6,6 -> 1600x1000 @ -1,-1.
--      Dispatched as float + resize(original) + move(original) IN THE SAME
--      TICK, it stayed exactly 791x988 @ 6,6 and simply became floating. The
--      fill is the DEFAULT, not a rule, and restoring the geometry in the
--      same tick beats it. (Two separate eval calls do NOT work -- by the
--      second one something has already re-tiled it. Same tick is the trick.)
--
--   3. A floating window moves for real: +60 then -60, measured 6 -> 66 -> 6.
--      `general.snap` does not exist on this build, so nothing pulls it back.
--
--   4. `float({action='unset'})` restores the EXACT original slot: measured
--      791x988 @ 6,6 both before and after. The tiler re-inserts it where it
--      belongs, so this is not a window left half a pixel off its layout
--      position -- which was the stated reason the old block refused to try.
--
-- So the app can be made to vibrate, at the cost of one float/un-float pair
-- per refusal.
--
-- FOCUS FIRST, EVERY TIME. The window dispatchers on this build act on the
-- FOCUSED window and ignore any address (see the note above focusAddr), so a
-- move without a preceding focus is silently dropped. That was measured too:
-- the same nudge that moved the window 6 -> 66 with a focus did nothing at
-- all without one, which is why an earlier probe of this code looked broken.
--
-- HORIZONTAL, AND THE DIRECTION IS IGNORED ON PURPOSE
-- ---------------------------------------------------
-- The first version pushed the window in the SWIPED direction, which was a
-- reasonable reading of "that doesn't work" and the wrong one: a single push
-- reads as the window being shoved, and a shove looks like the compositor
-- disagreeing with you about where the window goes. What was asked for is the
-- other thing entirely -- a SHIVER, left and right, like something cold, the
-- way an error message shakes. That is a different signal: a push says "you
-- asked for the wrong thing", a shiver says "that did not work", with no
-- direction implied at all. So the vector table is gone and every step is on
-- the X axis regardless of which way the fingers went.
--
-- WHY THE NUMBERS ARE WHAT THEY ARE
-- ---------------------------------
-- REQUESTED (third pass, and the previous two were both rejected in the same
-- way -- "too weird, small, not professional"): vibrate QUICK, one left one
-- right ONCE, big movement but not too big, and it has to read as a
-- VIBRATION and not a SHIFT. Every one of those is a constraint the last two
-- profiles broke, so each is answered explicitly below rather than by
-- turning one knob and hoping.
--
--   1. QUICK. The last profile was 17 beats over 414ms with intervals
--      lengthening from 18ms to 34ms. That is 24 frames of fine motion and it
--      reads as a wobble settling, not as a snap. A refusal has to be
--      legible in the same time it takes to look away and back -- roughly
--      150ms, under 10 frames. So: 6 moving beats at a flat 24ms, ~144ms.
--   2. ONE LEFT ONE RIGHT, ONCE. Two pairs, not four and certainly not
--      eight-and-a-half. A repeated oscillation stops being a refusal signal
--      and starts being an animation the desktop is performing, which is the
--      "weird" that was reported. Four excursions, then home.
--   3. BIG, BUT NOT A SHIFT. 12px. Enough to cross a visible chunk of the
--      titlebar and be unmistakable; well short of the ~50px that would read
--      as the window being shoved somewhere. Critically, the amplitude
--      DECAYS across the two pairs -- 12, 12, 8, 8 -- so the motion has a
--      peak and then a smaller echo, which is what separates a shake from a
--      slide. A single pair at constant amplitude is literally a shift, and
--      that is what the first profile effectively was.
--   4. NOT A SHIFT. Three things enforce it. The first beat is the full
--      excursion, not a ramp: the window is displaced IMMEDIATELY, so it
--      never sits at an in-between position long enough to look like it is
--      travelling. The pairs cancel, so it is back on its slot after 72ms.
--      And the intervals are FLAT rather than decelerating -- a lengthening
--      interval is a body coming to rest, which is what made the old
--      profile look like a wobble. Flat and hard reads as a knock.
--
-- EVERY CONSECUTIVE PAIR SUMS TO ZERO, so the net displacement is exactly 0
-- by construction and the window cannot drift off its slot even if a late beat
-- is dropped. The absolute reposition in restore() is belt-and-braces, not the
-- mechanism.
--
-- THE PROFILE LIVES HERE AGAIN, because the shake is compositor-side once more.
-- It moved to services/RefusalShake.qml while the overlay experiment was in
-- place and came back with the rest of that revert. If this ever moves again,
-- move the LOAD-TIME ASSERTION with it -- the two drifting apart is how a
-- shiver becomes a drift.
--
-- ONE PAIR, NOT TWO: -12, 12, then the 0 terminator. The previous profile was
-- four beats (12, 12, 8, 8) over 96ms and it read as "something is still
-- happening to this window" rather than "that did not work". A second, smaller
-- pair needs time to be perceived as a decay, and at this amplitude it just
-- wobbles. 18ms a beat is about one frame per leg.
--
-- THE TWO LISTS ARE CHECKED AT LOAD, not assumed. Two mistakes are possible
-- here and both were made once: a steps list whose pairs do not cancel (the
-- window drifts a pixel off its slot every refusal, permanently), and a timing
-- list that does not line up with the beats (the tail fires with no delay and
-- the decay does not happen). Neither shows up in luac, neither shows up in a
-- screenshot, and both are one edit away forever.
local VIBRATE_STEPS = {
    -12, 12,  -- the knock: one left, one right, at full size, immediately
    0,        -- home. Absolute, so the window lands exactly on its slot
}
-- Flat 18ms per moving beat: just over one frame at 60Hz, so each excursion is
-- crisp and the whole thing lands in about three. One entry per beat that
-- actually moves -- the trailing 0 is the terminator and is not timed, so this
-- list is deliberately ONE SHORTER than VIBRATE_STEPS. An earlier version had
-- it four short, which meant the last beats fired back to back with no delay
-- (the timer read nil and defaulted) and the decay never happened.
--
-- ~54ms total, about three frames: gone before it can be studied.
local VIBRATE_MS = {
    18, 18,
}

do
    local net = 0
    for _, v in ipairs(VIBRATE_STEPS) do net = net + v end
    -- One timed entry per MOVING beat: the trailing 0 terminates.
    local timed = #VIBRATE_STEPS - 1
    if net ~= 0 or #VIBRATE_MS ~= timed then
        -- Refusing to load would take the whole desktop's gestures with it,
        -- which is a far worse outcome than a slightly wrong shiver, so this
        -- is reported and the obvious fix is applied in place instead: zero the
        -- list so the sequence is a clean no-op rather than a drifting one.
        tracef("refusal: VIBRATE profile BROKEN net=%d steps=%d ms=%d -- disabling",
            net, #VIBRATE_STEPS, #VIBRATE_MS)
        for i = #VIBRATE_STEPS, 1, -1 do VIBRATE_STEPS[i] = 0 end
        for i = #VIBRATE_MS, 1, -1 do VIBRATE_MS[i] = 0 end
    end
end
local vibrateRunning = false

-- ═══ The sibling expansion, and why it is a TIMING problem ══════════════
--
-- MEASURED: the moment a tiled window is floated, Dwindle re-cuts around the
-- hole and the sibling GROWS INTO IT. On a two-window side-by-side layout
-- jetbrains-studio went 844x1010 @ 857,51 -> 1695x1010 @ 6,51 the instant
-- kitty floated. Measured on a three-window layout too (a sibling went
-- 502 -> 1010 tall), so it is the tiler filling the gap, not something
-- specific to a pair.
--
-- BUT THE GROWTH IS NOT VISIBLE, AND THAT IS THE WHOLE POINT.
--
-- The sibling's new rect is 6..1701 and our floating window sits at 6..851,
-- ON TOP of it (verified: kitty is above jetbrains-studio in the client list,
-- which is bottom-to-top stacking). The sibling's expansion is therefore
-- entirely BEHIND our own window -- it covers precisely the region we already
-- occupy and nothing else. There is nothing to see.
--
-- SO WHY WAS IT SEEN AT ALL? Not because of WHEN. That was the belief for a
-- long time and it is WRONG: disabling the animation leaf BEFORE the float
-- does make the reflow land in a single frame, but the growth still holds for
-- the whole 144ms of the shake, because the window stays detached for all of
-- it. Sampled at 25ms through a real shake:
--
--   jetbrains@857,51 844x1010 | kitty@6,51 845x1010      before
--   jetbrains@6,51 1695x1010 | kitty@-6,51 845x1010FLOAT  during
--   jetbrains@857,51 844x1010 | kitty@6,51 845x1010      after
--
-- 844 -> 1695, the whole work area, held for the entire shake. The claim that
-- follows -- that the growth is "entirely BEHIND our own window" -- is also
-- wrong: that is only true of the part overlapping our old slot. The rest of
-- a work-area-wide growth is plainly on screen, and it is the bug the user
-- reported with a screenshot.
--
-- THE CONSEQUENCE, as of 2026-10-02: this is FIXED, and not here. Every
-- compositor-side workaround failed (the full list is below and at
-- bumpRefusal), so the shake no longer detaches ANY window. A refusal now
-- hands the window's rect to the shell, which captures it, hides its PIXELS
-- with `set_prop opacity=0`, and vibrates the picture in a layer-shell
-- overlay. The window never leaves the tiler, so there is no hole, no
-- reflow, and nothing for the neighbour to grow into. The ordering note
-- below is kept because it explains why the float version was arranged the
-- way it was, but it no longer describes anything that happens.
--
-- The older reasoning, kept because it explains why the ordering was changed
-- in the first place: because of WHEN, not what. The tiler animates a reflow
-- over its own duration (windowsMove at the configured speed 4, a few hundred
-- ms). For those frames our window has not been raised and placed yet, so the
-- sibling is seen sliding leftward and growing -- and then our window lands on
-- top of it, hiding the growth, and on the restore it snaps back. A grow, then
-- a hide, then a shrink: read as "another app tried to take its place".
--
-- THE FIX IS THEREFORE ONE LINE OF ORDERING: the animation leaf goes off
-- BEFORE the float, not after it. With it already off, the sibling's reflow
-- lands in a single frame -- the same frame our window is raised in -- so
-- there is no window of time in which the growth is on screen. Nothing about
-- the geometry changes; only the frames in which it is observable do.
--
-- WHAT WAS TRIED AND REVERTED, so it is not tried again:
--   * pinning the sibling -- REFUSED on this build, "Window does not qualify
--     to be pinned" (verified twice);
--   * asking the sibling to shrink back -- impossible, once our window has
--     left the tiler there is no pair left to trade with (measured: it stayed
--     at 1695);
--   * pre-growing the sibling to the full work area so there is no hole --
--     this made things WORSE, not better. The resize is focus-scoped, so
--     asking the sibling for the full width actually resized the wrong window:
--     kitty took 1608 and jetbrains was squeezed to an 81px sliver. Reverted.
--   * holding the band (floating the neighbour too) -- stops the growth and
--     destroys the layout on restore. Reverted.
--
-- NOTE ON AN OLD CLAIM HERE. This comment used to say all sixteen `set_prop`
-- names were rejected, "Invalid prop name". That was WRONG -- a typo,
-- `hl.dsp.window.setProp` for `hl.dsp.window.set_prop`. The compositor
-- accepts opacity, alpha, noanim, noblur and others. `opacity` is what made
-- the graphical shake possible, and it is verified working: a grim capture of
-- a window's rect changes md5 under opacity=0 and returns byte-identical on
-- restore, WITH THE GEOMETRY AND FLOATING STATE UNCHANGED.

-- ═══ The refusal: float, vibrate, put back ═════════════════════════════
--
-- THE REAL WINDOW MOVES. That is deliberate, and it is a reversal of the
-- shell-overlay attempt below.
--
-- WHY. The overlay took a screenshot of the window, hid the real pixels with
-- `set_prop opacity=0`, and vibrated the picture in a layer-shell surface. It
-- worked -- verified, no neighbour ever grew -- but it could never be made to
-- FEEL right, and it glitched three separate ways across three attempts:
--
--   * the window was hidden before the ~500KB PNG had decoded, so bare desktop
--     showed through the window's own rect for a frame or two;
--   * gating that on Image.Ready did not help, because with synchronous
--     decoding "Ready" means DECODED, not PAINTED, so the hide still landed
--     before the overlay surface had mapped -- the same flash, inverted;
--   * even once correctly sequenced, a frozen still of a live window swapped in
--     and out of place reads as a broken display rather than a window
--     refusing something.
--
-- The last of those is the one that cannot be engineered away. A screenshot
-- swap is inherently a discontinuity, and a refusal that reads as a display
-- fault has failed at being a refusal.
--
-- So this is the compositor-side shake again: float, nudge left and right,
-- put back. Real pixels, real motion, no capture and no overlay -- and the
-- animation is exactly the one that was asked for.
--
-- THE PRICE, MEASURED AND NOT HIDDEN. Floating a tiled window hands its cell
-- to the band partner, which grows into the hole for as long as the window is
-- detached:
--
--   before    kitty@857,51 844x1010 | org.mozi@6,51 845x1010
--   detached  org.mozi@6,51 1695x1010 | kitty@-6,6 845x1055 FLOAT
--   restored  kitty@857,51 844x1010 | org.mozi@6,51 845x1010
--
-- 845 -> 1695, the whole work area, for the length of the shake. Re-measured
-- today rather than quoted from a note, because several other measurements in
-- this file turned out to be wrong.
--
-- WHY IT CANNOT BE SUPPRESSED. Every approach, re-tested today on a clean
-- two-window row:
--   * pin the neighbour -- "Window does not qualify to be pinned". Genuinely
--     refused for a TILED window; it only succeeds on an already-floating one.
--   * ask the neighbour to shrink -- impossible once we have left the tiler.
--   * hold the band (float the neighbour too) -- stops the growth and destroys
--     the layout on restore.
--   * `pin`, `noblur`, `noanim` and friends via set_prop -- none of them
--     constrain a reflow.
--
-- The overlay was the only thing that ever avoided the growth, and it could not
-- be made to look right. Given the choice between a correct-looking knock that
-- grows its neighbour for ~54ms and a glitch, the knock was asked for and the
-- growth is accepted.
--
-- NOT `local function bumpRefusal()`. `local function f` is sugar for
-- `local f; f = function...`, so it declares a SECOND local that SHADOWS the
-- forward declaration above instead of assigning to it, leaving the gesture's
-- upvalue nil forever ("attempt to call a nil value (upvalue 'bumpRefusal')").
-- A bare `function f()` assigns to the visible local, which is what
-- isDialogClass and attachFocusedFloat use and what this uses.
function bumpRefusal(direction)
    local ok, err = pcall(function()
        -- Re-entrancy: a second refusal mid-shake is dropped rather than
        -- queued, so a repeated swipe cannot leave a window stranded half way
        -- through its float cycle.
        if vibrateRunning then return end
        local me = hl.get_active_window()
        -- No window, or a window we must not move: silent. The dialog check is
        -- FIRST, before anything is detached, so a polkit prompt or a file
        -- chooser is never made to move -- it is the last place to introduce
        -- motion, and a system prompt has no business twitching.
        if not me or not me.address then return end
        if isDialogClass(me.class or me.initialClass) then
            trace("refusal: dialog, staying quiet")
            return
        end

        -- Already floating (a popup the attach gesture declined): shiver it in
        -- place. No float/un-float pair is needed, and none is wanted -- its
        -- geometry belongs to the user, not to the tiler.
        local wasFloating = me.floating and true or false
        local ox, oy = me.at.x, me.at.y
        local ow, oh = me.size.x, me.size.y

        -- Focus before EVERY window dispatch. On this build the window
        -- dispatchers act on the FOCUSED window and ignore the address, so a
        -- move without a preceding focus is silently dropped -- measured: the
        -- same nudge that moved a window 6 -> 66 with a focus did nothing at all
        -- without one.
        local function focusBack()
            local w = hl.get_window("address:" .. me.address)
            if w then hl.dispatch(hl.dsp.focus({ window = w })) end
        end

        -- Put the window back exactly where the layout wants it. Used on the
        -- normal exit AND on the error path, because a throw midway would
        -- otherwise strand the app floating and nudged off its slot, which is a
        -- far worse outcome than no vibration at all.
        local function restore()
            pcall(function()
                focusBack()
                -- The beats sum to zero, so this is normally a no-op move. It is
                -- here for the case where a beat was DROPPED (a timer that did
                -- not land, a throw caught above), which would otherwise leave
                -- the window a pixel or two off its slot for the rest of the
                -- session. Absolute, not relative, so it cannot compound.
                hl.dispatch(hl.dsp.window.move({ x = ox, y = oy }))
                if not wasFloating then
                    hl.dispatch(hl.dsp.window.float({ action = "unset" }))
                    -- The re-tile is what shrinks the neighbour back to its own
                    -- cell, and it happens with the animation still off, which
                    -- lands it in a single frame instead of tweening across the
                    -- next -- without that, the beats smear into a slow slide
                    -- and the whole thing stops reading as a shiver.
                    hl.timer(function()
                        -- `speed` is REQUIRED by hl.animation even when
                        -- re-enabling, and these are the values
                        -- hyprland/general.lua declares. Leaving speed out
                        -- throws "missing required field \"speed\"" -- which
                        -- aborted this timer body, so windowsMove stayed
                        -- DISABLED for the rest of the session and every
                        -- window move after a refusal played with no animation
                        -- at all.
                        --
                        -- The values match restoreMoveAnim() further down;
                        -- any other place that re-enables windowsMove must
                        -- agree with it or the desktop silently inherits
                        -- whatever ran last.
                        hl.animation({
                            leaf = "windowsMove", enabled = true, speed = 4,
                            bezier = "emphasizedDecel", style = "slide"
                        })
                    end, { timeout = 60, type = "oneshot" })
                end
            end)
            vibrateRunning = false
        end

        -- Detach and restore the geometry in the SAME TICK. Anything less
        -- flashes the window to full screen for a frame, which is a far worse
        -- bug than the one this block exists to fix.
        hl.animation({ leaf = "windowsMove", enabled = false, speed = 1 })
        if not wasFloating then
            hl.dispatch(hl.dsp.focus({ window = hl.get_window("address:" .. me.address) or me }))
            hl.dispatch(hl.dsp.window.float({ action = "set" }))
            hl.dispatch(hl.dsp.window.resize({ x = ow, y = oh }))
            hl.dispatch(hl.dsp.window.move({ x = ox, y = oy }))
        end

        vibrateRunning = true
        tracef("refusal: shiver on %s swipe, %d beats", tostring(direction), #VIBRATE_STEPS)

        local i = 0
        local function step()
            i = i + 1
            focusBack()
            local okStep = pcall(function()
                hl.dispatch(hl.dsp.window.move({
                    x = VIBRATE_STEPS[i],
                    y = 0,
                    relative = true,
                }))
            end)
            if not okStep then
                trace("refusal: step FAILED: " .. tostring(okStep))
                restore()
                return
            end
            -- THE LAST BEAT RESTORES IMMEDIATELY. VIBRATE_MS is deliberately
            -- one shorter than VIBRATE_STEPS (the trailing 0 is the
            -- terminator and has no interval), so on the final index
            -- VIBRATE_MS[i] is nil -- and `hl.timer` with a nil timeout throws.
            -- That throw happens in an ASYNC callback, long after this pcall has
            -- returned, so nothing catches it: the desktop shows an error
            -- banner, restore() never runs, and the window is stranded FLOATING
            -- with the animation off for the rest of the session.
            --
            -- Measured: replaying the exact sequence left jetbrains-studio
            -- floating at 851,1 854x1065 after a full excursion, with no
            -- restore.
            if i >= #VIBRATE_STEPS then
                restore()
                return
            end
            hl.timer(step, { timeout = VIBRATE_MS[i], type = "oneshot" })
        end
        step()
    end)
    if not ok then
        vibrateRunning = false
        trace("bumpRefusal FAILED: " .. tostring(err))
    end
end

-- ═══ 2/3 fingers left · right: REMOVED from here, on purpose ═══════════
--
-- These were global binds that fired the shell's modeNext/modePrev from
-- ANYWHERE on the desktop -- including while the cursor was over the island
-- or the popped-out card, BOTH of which consume the very same swipes
-- themselves (touchpad swipes of any finger count arrive on layer surfaces
-- as wheel events, and NowBar/NowBarPanel both classify and step on them).
-- The overlap meant one physical swipe over the island stepped TWO views:
-- once here, once in the shell.
--
-- The requested behavior is now exactly what the shell already implements:
--   * over the ISLAND  : 2- and 3-finger horizontal swipes flip the views
--                        (NowBar.qml's wheel handler, axis-locked, one
--                        step per gesture) -- works while hovering only,
--                        because that is where the surface is;
--   * inside the PANEL : the same, over the whole card (NowBarPanel.qml's
--                        wheel handler) -- 2 and 3 fingers alike;
--   * anywhere else    : horizontal 2/3-finger swipes do nothing. They
--                        stay free for future binds.
-- The modeNext/modePrev GlobalShortcuts and the panel's IPC stay registered
-- in the shell (they are harmless) -- only the compositor's duplicate
-- gesture bindings are gone.

hl.gesture({
    fingers = 4,
    direction = "left",
    mods = "SUPER",
    disable_inhibit = true,
    action = function() moveWindowToNeighbour(-1) end
})

hl.gesture({
    fingers = 4,
    direction = "right",
    mods = "SUPER",
    disable_inhibit = true,
    action = function() moveWindowToNeighbour(1) end
})

-- ═══ SUPER + four fingers DOWN: the desktop overview ═════════════════
--
-- The bar's empty stretches open it too (BarContent.qml), so this is the
-- keyboard-free way in from anywhere on the desktop.
--
-- The hard requirement, and the reason this is a separate modifier-bound
-- gesture rather than a change to the plain one: IT MUST NOT CLOSE THE
-- CURRENT APP. Plain four-fingers-down is the close-drag (window follows your
-- fingers, closes past the commit threshold) and it stays exactly that --
-- only the SUPER variant is bound here, and `mods` is how Hyprland
-- disambiguates: a modifier-restricted gesture and the plain one with the
-- same finger count and direction coexist, and the one whose modifiers fit
-- what you are holding is the one that fires.
--
-- It also dispatches the SUPER-release interrupt, like every other SUPER
-- gesture here. A SUPER *tap* opens the app search overlay on release, and a
-- gesture is not a key press -- without the interrupt, letting go after this
-- swipe opened the launcher on top of the overview.
hl.gesture({
    fingers = 4,
    direction = "down",
    mods = "SUPER",
    disable_inhibit = true,
    action = function()
        hl.dispatch(hl.dsp.global("quickshell:searchToggleReleaseInterrupt"))
        hl.dispatch(hl.dsp.global("quickshell:desktopOverviewToggle"))
    end
})

-- Four fingers down closes the focused window. The window follows your
-- fingers downward and only actually closes if you carry it past the commit
-- threshold; let go early and it springs back to where it was.
--
-- Implementation notes that matter (this build is unforgiving):
--   * HL.Window exposes NO writable position fields -- `win.x = ...` throws
--     "attempt to modify read-only hl object" on every gesture frame, which is
--     exactly the runtime-error flood an older version of this block produced.
--     Every interaction here therefore goes through DISPATCHERS:
--     hl.dsp.window.move({x=, y=, relative=true, address=}) and .close().
--   * Relative pixel moves only apply to FLOATING windows; the tiler owns a
--     tiled window's position and silently ignores them. So a TILED window is
--     floated at gesture start (remembering that we did) and follows the
--     fingers like any floating window; releasing early springs it back and
--     re-tiles it. A FULLSCREEN window (including the morphed settings /
--     task-manager window) is detached the same way but pinned to the monitor
--     rect in the same frame, so it follows the fingers at the size it was
--     already showing and the desktop is revealed behind it; releasing early
--     restores fullscreen.
--   * The `windowsMove` animation is disabled while a follow-drag is active so
--     each per-frame move lands instantly (true 1:1), and re-enabled for the
--     spring-back so the return trip is a smooth animated settle for free.
--   * The little "this closes the app" hint you see while dragging is the
--     shell's own chip (GlobalStates); it keys off the window actually moving
--     past the screen edge, which the follow path produces.
-- Close a window, smartly: park to the tray workspace if the window's class
-- is in config.json's tray.closeToTray list, otherwise close normally. Used by
-- both the 4-finger-down close-drag finish and the SUPER+Q keybind (custom/
-- keybinds.lua). Returns true when the window was parked (caller should not
-- also close it), false when it should be closed.
-- Reusable check: is this window class in config.json's tray.closeToTray?
-- Used by both smartClose (park the window) and the 4-finger-close start path
-- (skip the unfullscreen/float dance for a tray app so a fullscreen tray app
-- stays fullscreen while the fingers move, instead of flashing non-fullscreen).
function isTrayAppCls(cls)
    if not cls or cls == "" then return false end
    local ok, payload = pcall(function()
        local f = io.open(os.getenv("HOME") .. "/.config/illogical-impulse/config.json", "r")
        if f then local s = f:read("*a"); f:close(); return s end
        return nil
    end)
    if not (ok and payload) then return false end
    local object = payload:match('"closeToTray"%s*:%s*({[^}]*})')
    if not object then return false end
    local escaped = cls:gsub("([^%w])", "%%%1")
    return object:match('"' .. escaped .. '"%s*:%s*true') ~= nil
end

function smartClose(addr)
    local w = findWindow(addr)
    if not w then return false end
    local cls = w.class or w.initialClass or ""
    if not isTrayAppCls(cls) then return false end
    -- Park to the special tray workspace. The shell re-asserts the tray icon
    -- from the parked window, and SysTrayAppItem.qml reads TrayApps.isRunning/
    -- isHidden to keep the icon in sync.
    -- NOTE: do NOT call focusAddr() here -- it is a `local function` declared
    -- further down, so at this point in the file it resolves to a nil global
    -- and the throw aborted the whole bind (no park, no close). Focus inline
    -- via the window we already looked up above.
    hl.dispatch(hl.dsp.focus({ window = w }))
    hl.dispatch(hl.dsp.window.move({ workspace = "special:tray", follow = false }))
    return true
end

local closeDrag = nil
-- windowsMove's live values cannot be read back (hl.get_config returns nil for
-- animation leaves), but the values that matter are defined in THIS config:
-- enabled, speed 4, emphasizedDecel, style slide (hyprland/general.lua, where
-- the leaf is declared). Re-applying the leaf therefore restores exactly what
-- the config says, whoever last touched it.
--
-- The speed was 3.0 here, which is NOT what the config declares: a four-finger
-- close-drag turned the user's snappier settle (4) into 3.0 permanently, and
-- nothing read it back to notice. Anything that restores this leaf -- this
-- function and the dead-edge pulse below -- must use the declared value.
local function restoreMoveAnim()
    hl.animation({ leaf = "windowsMove", enabled = true, speed = 4, bezier = "emphasizedDecel", style = "slide" })
end

-- ═══ Fullscreen -> anchored, played as a motion ═══════════════════════════
--
--
-- Leaving fullscreen is a geometry change, and this build has no `fullscreen`
-- animation leaf ("no such animation leaf") -- that is also what used to put
-- the red error badge on this config -- so the compositor simply puts the
-- window down wherever the layout says: a teleport. On the popup windows there
-- was a second jump on top of it (a 350ms float-toggle that re-tiled the
-- window), which is the "strict teleport glitch".
--
-- So the transition is played here instead, and played without the desktop
-- breathing underneath it: the window's destination is read from the layout,
-- the other tiled windows are pinned at the rects they are about to end up
-- with anyway, and the window itself is tweened from the fullscreen rect into
-- its slot on an ease-out. At the end every window rejoins the tiler at the
-- rect it already occupies.
-- BARE `function`: fills in the forward declaration above (see there).
function findWindow(addr)
    for _, w in ipairs(hl.get_windows() or {}) do
        if w.address == addr then return w end
    end
    return nil
end

-- ═══ Tray-managed apps: closed into the vault, not into the void ════════
--
-- ═══ No per-app tray mechanism, by request ═════════════════════════════
--
-- REMOVED, deliberately and completely. Everything between here and the old
-- `rectOf` helper used to implement "closing some apps minimises them to a
-- tray instead of closing": a special workspace to park windows on, a
-- per-app class list published by the shell as JSON, a compositor sweep that
-- watched the desktop and pulled windows off it, a permit file with a TTL, a
-- shell-side re-assert on a timer, and a park-verify-retry-close routine for
-- the close gesture.
--
-- It is gone because it never worked, and because the way it failed was the
-- real problem. It did not fail as one bug: it failed as a SHAPE. Making one
-- app's close mean something different from every other app's required a
-- second process to hold a veto over what the first process put on screen,
-- synchronised through files with timestamps and timers measured in
-- milliseconds. Every mechanism that required was another chance for the two
-- processes to disagree, and the disagreements were silent -- every one of
-- them reached the user as the same sentence: "the four-finger swipe down
-- does not work".
--
-- Two of the failures were self-inflicted, which is the part worth recording.
-- A park-verification helper read the wrong field on a window object and
-- concluded every park had failed, so a fallback that CLOSED the window ran
-- instead -- which on Linux is a quit: the gesture the user made to PRESERVE a
-- mail client destroyed it. Then a diagnostic log line formatted a float with
-- an integer specifier, which is a hard error in Lua 5.3+, and it threw inside
-- the gesture's end callback and took the close down with it. Both fixes were
-- worse than the bug they replaced, and both were introduced while fixing the
-- original problem. A mechanism this entangled cannot be debugged by editing
-- it; it has to be taken out.
--
-- The replacement is the thing that was wanted in the first place: Thunderbird
-- is a normal desktop app. It opens, tiles, fullscreens, swipes and closes
-- exactly like everything else, with no tray icon and nothing special about
-- it. If a future Thunderbird ships a real Linux tray icon, it will appear in
-- the tray the ordinary way, as a StatusNotifier item, with no compositor-side
-- help -- which is how every other tray icon on this desktop works.


local function rectOf(w)
    if not w or not w.at or not w.size then return nil end
    return { x = w.at.x, y = w.at.y, w = w.size.x, h = w.size.y }
end

local function sameRect(a, b)
    if not a or not b then return false end
    return math.abs(a.x - b.x) < 3 and math.abs(a.y - b.y) < 3
        and math.abs(a.w - b.w) < 3 and math.abs(a.h - b.h) < 3
end

-- ═══ Window operations here are FOCUS-SCOPED, not address-scoped ══════════
--
-- Verified live in this build: the window dispatchers IGNORE an `address`
-- argument and act on the FOCUSED window. `float({ action = "set", address = A })`
-- floated a different window, and the placeWindow() below moved whatever held
-- focus instead of the window it named. That is why the fullscreen -> anchored
-- glide was heavy AND came to rest somewhere else: its per-frame absolute
-- resize was landing on a TILED window (the focused one), and an absolute
-- resize on a tiled window is a SPLIT-RATIO change -- so each of the ~28 frames
-- re-laid-out the whole workspace and rewrote the tree the window was about to
-- rejoin, which is why the desktop's windows also shifted.
--
-- `hl.dsp.focus({ window = <object> })` DOES work (verified: after focusing a
-- window by object, a plain float/resize/move acted on it). So every operation
-- below is "focus the window, then dispatch", and the focus goes back
-- afterwards.
local function focusAddr(addr)
    local w = findWindow(addr)
    if not w then return nil end
    hl.dispatch(hl.dsp.focus({ window = w }))
    return w
end

-- Plain move+resize: acts on the focused window (see the note above).
local function placeFocused(r)
    hl.dispatch(hl.dsp.window.resize({ x = r.w, y = r.h }))
    hl.dispatch(hl.dsp.window.move({ x = r.x, y = r.y }))
end

-- BARE `function`, and `findWindow` likewise below: both have forward
-- declarations above, and only a bare `function` fills them in. `local
-- function` would shadow the declaration and leave the promotePopup call
-- sites nil. There is now a mechanical check for this shape in the file's
-- notes below.
local function isFloating(addr)
    local w = findWindow(addr)
    return (w and w.floating and true) or false
end

-- Explicit float state, never a toggle, and only reported successful when the
-- window is VERIFIED to be in that state afterwards.
function setFloat(addr, on)
    if isFloating(addr) == on then return true end
    if not focusAddr(addr) then return false end
    hl.dispatch(hl.dsp.window.float({ action = on and "set" or "unset" }))
    return isFloating(addr) == on
end

-- ═══ "This float was not meant to be one" ═════════════════════════════
--
-- REQUESTED: a three-finger swipe in ANY direction, or four fingers up,
-- ATTACHES the focused window when it is floating and is not one of the
-- windows that is SUPPOSED to float. The gesture is the user's verdict on
-- the window ("this is an app, put it in the layout"), and a verdict is
-- worth more than a rule: no amount of class matching can know that the
-- Brave window which opened itself at 1334x789 is a second browser window
-- and not a picture-in-picture.
--
-- WHY A GESTURE AND NOT A RULE
-- -----------------------------
-- Because the compositor cannot tell the two apart, and neither can a class
-- list. The catch-all in rules.lua already forces float=false for every
-- class, and the windows that still arrive floating are exactly the ones
-- that asked to be (Electron, AppImage, a browser's own popup). That is why
-- the ONLY way to separate "app that should tile" from "popup that should
-- float" is to be told. This is that signal.
--
-- WHAT COUNTS AS A REAL POPUP (and is therefore left alone)
-- ----------------------------------------------------------
-- The exemption list is not invented here. It is read back out of the float
-- rules in rules.lua, so the gesture can never attach a window that a rule
-- deliberately floated:
--
--   * dialogs, portals, polkit agents   -- isDialogClass
--   * the file chooser / "wants to open or save" prompts (by title)
--   * picture-in-picture and the screen-sharing indicator (by title)
--   * the wallpaper theatre              (by title)
--   * Bitwarden's small utility panel   (by class)
--   * the Razer charge-limit prompt      (by title)
--
-- A dialog that attached would be the worst possible outcome: a system
-- password prompt dropped into the tiling layout with no way back. So the
-- dialog check runs FIRST and returns before anything else is considered.
--
-- WHY IT REPORTS rather than acting, and why the callers consume it
-- -----------------------------------------------------------------
-- Returns true only when it actually attached something. Every gesture that
-- calls it does `if attachFocusedFloat() then return end`, so a swipe over
-- an ordinary tiled window -- the overwhelmingly common case -- falls
-- straight through to the gesture's real behaviour, unchanged. Only a
-- genuine float costs a round trip, and that is one focus and one float
-- dispatch.
function attachFocusedFloat()
    local w = hl.get_active_window()
    if not w or not w.floating then return false end
    local cls = w.class or w.initialClass
    local title = tostring(w.title or "")
    -- Dialogs first, and alone. See above: this is the one case where
    -- attaching is actively harmful.
    if isDialogClass(cls) then return false end
    -- The rest of the deliberate floats, by title.
    --
    -- The ANCHORING is copied from the float rules in rules.lua rather than
    -- invented, and it is stricter than a substring test on purpose. A loose
    -- test was measured wrong in both directions on a table of real window
    -- titles: a substring "wallpapers" refused to attach an editor with the
    -- tab "wallpapers/main.qml" open, and a substring "save as" refused to
    -- attach a browser sitting on the web.dev page "How to save as a service
    -- worker". Here a false positive is worse than in rules.lua: a rule that
    -- floats a browser page by mistake is invisible, but a gesture that
    -- refuses to attach one leaves a window the user cannot get into the
    -- layout at all, which is the exact complaint this gesture exists for.
    --
    -- So: the trigger must be at the START of the title (as
    -- `^(Open File|Select a File|...)(.*)$` is), AND what follows it must not
    -- look like a file path or a lower-case continuation. The second half is
    -- what separates the real dialog "Authenticate" from the editor tab
    -- "authenticate/Auth.kt" -- the same word, the same start, opposite
    -- meaning, and only the character after it tells them apart.
    local lt = title:lower()
    local function leadsWithDialogWord(word)
        if lt:sub(1, #word) ~= word then return false end
        local rest = lt:sub(#word + 1)
        -- End of title, or a space/punctuation that a dialog title uses.
        -- A "/" continues a PATH and a lower-case letter continues a
        -- SENTENCE, and both mean this is an ordinary window.
        if rest == "" then return true end
        local c = rest:sub(1, 1)
        if c == "/" then return false end
        if c:match("%l") then return false end
        return true
    end
    if leadsWithDialogWord("open file") then return false end
    if leadsWithDialogWord("select a file") then return false end
    if leadsWithDialogWord("open folder") then return false end
    if leadsWithDialogWord("save as") then return false end
    if leadsWithDialogWord("file upload") then return false end
    if leadsWithDialogWord("choose wallpaper") then return false end
    if leadsWithDialogWord("library") then return false end
    if leadsWithDialogWord("authentication required") then return false end
    if leadsWithDialogWord("authenticate") then return false end
    -- Anchored at the END, like `^(.*)(wants to save|wants to open)$`.
    if lt:find("wants to save$") then return false end
    if lt:find("wants to open$") then return false end
    -- Anchored at both ends, like `^Change charge limit$`.
    if lt == "change charge limit" then return false end
    -- Unanchored in the rule too: `.*is sharing (a window|your screen).*`
    if lt:find("is sharing a window", 1, true) then return false end
    if lt:find("is sharing your screen", 1, true) then return false end
    -- Picture-in-picture, anchored at the start, in the spellings apps
    -- actually use. The rule is `^([Pp]icture[-\s]?[Ii]n[-\s]?[Pp]icture)`:
    -- a hyphen OR a space (or nothing) between the words, which covers
    -- "Picture-in-Picture", "Picture in Picture" and "PictureinPicture".
    if lt:match("^picture[%s-]?in[%s-]?picture") then return false end
    -- Exact, like `^(Wallpapers)$` -- the wallpaper theatre is the only
    -- window with this title, and a loose match here would refuse to attach
    -- any editor or browser that merely has the word in a tab or a path.
    if lt == "wallpapers" then return false end
    -- Bitwarden floats on purpose (rules.lua) -- it is a utility panel, not
    -- a document, and stretching it across the layout is the bug that rule
    -- exists to prevent.
    if cls and tostring(cls):lower():find("bitwarden", 1, true) then return false end
    -- Our own shell surfaces are not app windows.
    if cls == "org.quickshell" then return false end
    if not w.address then return false end
    -- tracef, not trace, per the rule at its definition: this line is built
    -- from window fields, and a value that cannot be formatted must degrade
    -- to a placeholder rather than abort the attach.
    tracef("attach-gesture: attaching %s \"%s\"", tostring(cls), title)
    return setFloat(w.address, false)
end

-- ── Fullscreen demote, for the sweep ─────────────────────────────────
-- Thunderbird keeps arriving FULLSCREEN when the launcher opens it (either
-- kind: compositor fullscreen 1/2, or the client-requested kind, which the
-- stub calls fullscreenClient). attachSweep used to handle only the FLOAT
-- half; a fullscreen window is tiled, so the floating branch never matched
-- and nothing demoted it. The demote follows the same focus-then-verb-and-
-- verify contract as setFloat, and it demotes each window ONCE: a user who
-- fullscreens the app deliberately afterwards is respected -- the marker is
-- set only after a VERIFIED demote, so a dropped dispatch retries instead
-- of leaving the window stuck.
local demotedFullscreen = {}
local function isFullscreened(w)
    return (w.fullscreen or 0) ~= 0 or (w.fullscreenClient or 0) ~= 0
end
local function demoteFullscreen(addr)
    local w = findWindow(addr)
    if not w or not isFullscreened(w) then return end
    if not focusAddr(addr) then return end
    -- 1 = maximized, 2 = fullscreen on this build; unsetting the wrong mode
    -- on a maximized window would stack the two states (see the phase-5
    -- note in services/TrayApps.qml for the measured behaviour).
    local mode = ((w.fullscreen or 0) == 1) and "maximized" or "fullscreen"
    hl.dispatch(hl.dsp.window.fullscreen({ mode = mode, action = "unset" }))
    local after = findWindow(addr)
    if after and not isFullscreened(after) then
        demotedFullscreen[addr] = true
    end
end

local function monitorRectOf(w)
    local mon = w and w.monitor
    local scale = (mon and mon.scale) or 1
    if scale <= 0 then scale = 1 end
    return {
        x = (mon and mon.x) or 0,
        y = (mon and mon.y) or 0,
        w = math.floor(((mon and mon.width) or 1410) / scale + 0.5),
        h = math.floor(((mon and mon.height) or 940) / scale + 0.5),
    }
end

-- (A `anchorPins` / unpinWindows() mechanism used to live here: during the
-- fullscreen -> anchored glide it floated every other window on the workspace
-- and pinned it at the rect it was going to end up with anyway, so the freed
-- slot could not make the desktop breathe mid-glide. It worked and it was
-- expensive -- floating a window takes it out of the tiler, so each pin was a
-- full workspace re-layout plus a resize and a move, and each release another
-- re-layout: with two neighbours that is ~6 relayouts (and ~6 full-screen
-- re-renders, blur included) around a 200ms animation. Removed. The tiler now
-- reflows once at the start of the glide -- animated by windowsMove, which is
-- still enabled at that point -- which is both cheaper and smoother than
-- holding windows still and putting them back.

-- Landing: the neighbours rejoin the tiler first, then this window. Dwindle
-- inserts a window NEXT TO the one that is focused, so the neighbour nearest
-- the slot we want is focused first -- that is what makes the window come to
-- rest where it started instead of wherever the tree happened to be. If the
-- tree still puts it on the wrong side, one swap in that direction fixes it.
local function land(addr, dest, wasActive)
    local w = findWindow(addr)
    local wsId = w and w.workspace and w.workspace.id
    local best, bestD = nil, math.huge
    for _, other in ipairs(hl.get_windows() or {}) do
        if other.address ~= addr and other.workspace and other.workspace.id == wsId then
            local r = rectOf(other)
            if r then
                local d = math.abs((r.x + r.w / 2) - (dest.x + dest.w / 2))
                    + math.abs((r.y + r.h / 2) - (dest.y + dest.h / 2))
                if d < bestD then best, bestD = other.address, d end
            end
        end
    end
    if best then focusAddr(best) end
    focusAddr(addr)
    hl.dispatch(hl.dsp.window.float({ action = "unset" }))

    -- Did it come to rest where it belongs? Checked a beat later, because the
    -- tiler's geometry for a window that has just rejoined is not readable in
    -- the same frame -- acting on that stale rect would swap a window that was
    -- already in the right place. And the tolerance is generous (80px) for the
    -- same reason: the fallback is here for "the tree put it on the other
    -- side", not for a few pixels of gap.
    local check = function()
        local now = rectOf(findWindow(addr))
        if now and not sameRect(now, dest) then
            local dx = (dest.x + dest.w / 2) - (now.x + now.w / 2)
            local dy = (dest.y + dest.h / 2) - (now.y + now.h / 2)
            local dir
            if math.abs(dx) > math.abs(dy) then
                if dx < -80 then dir = "l" elseif dx > 80 then dir = "r" end
            else
                if dy < -80 then dir = "u" elseif dy > 80 then dir = "d" end
            end
            if dir then
                focusAddr(addr)
                hl.dispatch(hl.dsp.window.swap({ direction = dir }))
            end
        end
        if wasActive and wasActive.address ~= addr then
            hl.dispatch(hl.dsp.focus({ window = wasActive }))
        end
    end
    hl.timer(check, { timeout = 90, type = "oneshot" })
    restoreMoveAnim()
end

-- `forceTile`: the popup windows, which must come to rest in the layout (that
-- is what "anchored with the other desktop apps" means for them). A normal app
-- is left in whatever state it returns to -- tiled if it was tiled, floating at
-- its own rect if it was floating.
local function anchoredTransition(addr, forceTile)
    local w = findWindow(addr)
    if not w then return end
    local from = monitorRectOf(w)
    local wasActive = hl.get_active_window()
    -- The slot the window had BEFORE it went fullscreen (recorded by
    -- popup.rememberSlot at the moment it left the desktop). That -- not
    -- whatever the tiler decides afterwards -- is where "anchored" means.
    local dest = popup.slotOf(addr)

    if not focusAddr(addr) then return end
    -- Leave whatever expanded state the window is ACTUALLY in. The numeric
    -- fullscreen is 1 = maximized, 2 = fullscreen (probed on this build);
    -- toggling "fullscreen" on a maximized window would stack a real
    -- fullscreen ON TOP of the maximize -- the app's tabs would vanish on
    -- the way OUT of the anchored transition, exactly backwards.
    hl.dispatch(hl.dsp.window.fullscreen({
        mode = ((w.fullscreen or 0) == 2) and "fullscreen" or "maximized",
        action = "toggle" }))

    -- ═══ The window must NEVER be left floating ═══════════════════════════
    --
    -- "Sometimes, coming out of fullscreen does not show the other desktop
    -- apps" is this: the glide floats the window and resizes it, frame by
    -- frame, on its way back to its slot. If it is cut short -- a second
    -- gesture, a workspace switch, a reload, a throw anywhere in the frame
    -- chain -- the window keeps the FLOAT and the fullscreen-sized rect it
    -- had mid-glide, and a floating window that covers the whole monitor
    -- hides every other app behind it. The old safety net only restored the
    -- move ANIMATION; nothing ever put the window back in the layout.
    --
    -- `release()` is the one way out, and every exit from here goes through
    -- it: it re-tiles the window, restores the animation, and hands focus
    -- back. land() calls it on the happy path; the watchdog below calls it if
    -- land() never arrives.
    local released = false
    local function release(why)
        if released then return end
        released = true
        restoreMoveAnim()
        -- Only ever re-tile OUR window, and only if it is still floating: a
        -- window the user has since deliberately floated again must be left
        -- alone.
        local cur = findWindow(addr)
        if cur and cur.floating then
            focusAddr(addr)
            hl.dispatch(hl.dsp.window.float({ action = "unset" }))
        end
        if wasActive and wasActive.address ~= addr then
            hl.dispatch(hl.dsp.focus({ window = wasActive }))
        end
    end

    -- ═══ Everything below waits ONE frame, and that is a bug fix ═══════════
    --
    -- Dispatchers are QUEUED: reading a window in the same Lua tick as the
    -- dispatch that changed it returns the state from BEFORE it. That is what
    -- made this transition unreliable. setFloat() dispatched the float and then
    -- re-read the window in the same tick, saw the pre-dispatch state, decided
    -- the float had failed and fell back to a plain cut -- so roughly whenever
    -- the timing went the wrong way, swiping up looked like it did nothing at
    -- all ("sometimes the windows are not reacting to my 4 finger swipe up").
    --
    -- One frame (16ms) is invisible, and it makes every read below true: the
    -- un-fullscreen has been applied, the window is back in the layout looking
    -- for a slot, and the float state setFloat() reports is the real one.
    local function begin()
    -- pcall because a throw in here used to skip every remaining step --
    -- including the re-tile. A throw must still leave the desktop sane.
    local ok, err = pcall(function()
    local after = findWindow(addr)
    if not after then return end

    -- No remembered slot (a window that has never been anchored): ask the
    -- layout instead, by letting it rejoin the tiler once and reading the rect
    -- it is given.
    if not dest then
        -- Re-attach for EITHER reason. `forceTile` is the caller's explicit
        -- request; the other reason is a window that is floating and is not a
        -- dialog, which is a popup the user just gave the whole screen and
        -- has now taken back. Coming out of fullscreen is a decision to keep
        -- the window, so it lands in the layout rather than floating over
        -- everything at its fullscreen rect -- the "floating window covering
        -- the monitor hides every other app" failure this function exists to
        -- prevent. Dialogs are excluded inside promotePopup.
        local wantTile = forceTile
        if not wantTile and after.floating
            and not isDialogClass(after.class or after.initialClass) then
            wantTile = true
        end
        if wantTile and setFloat(addr, false) then
            dest = rectOf(findWindow(addr))
        else
            dest = rectOf(after)
        end
        if not dest then return end
    end

    -- Performance mode: no motion at all -- the window is simply back on the
    -- desktop. That is the point of the mode: this transition costs a handful
    -- of dispatches per frame normally, and one toggle here.
    if performance.performance then
        if forceTile then setFloat(addr, false) end
        if wasActive and wasActive.address ~= addr then
            hl.dispatch(hl.dsp.focus({ window = wasActive }))
        end
        return
    end

    -- Already there (a window that was never really moved): nothing to play,
    -- but a popup window still has to end up IN the layout.
    if sameRect(from, dest) then
        if forceTile then setFloat(addr, false) end
        return
    end

    -- Never tween a window that is not VERIFIED floating (see the note above):
    -- a tween frame is an absolute resize, and on a tiled window that is a
    -- split-ratio change -- the workspace would be rearranged instead of
    -- animated. If it will not float, it stays exactly as the layout put it:
    -- a plain cut, never damage.
    if not setFloat(addr, true) then
        if forceTile then setFloat(addr, false) end
        return
    end
    placeFocused(from)

    -- One glide, on THIS window.
    --
    -- 10 frames on 16ms ticks (~160ms) rather than 12: this is dispatch-bound
    -- work (two dispatches and a re-draw per frame), so the shorter the glide
    -- the less of the frame budget it eats, and easeOutCubic reads the same at
    -- either length.
    hl.animation({ leaf = "windowsMove", enabled = false, speed = 1 })
    local frames, i = 10, 0
    local function tick()
        i = i + 1
        -- Every frame dispatches on the FOCUSED window (see the note above),
        -- so if focus was stolen -- a notification, a click, another gesture
        -- -- the resize and move would land on a TILED window instead, which
        -- is a split-ratio change: the workspace rearranges itself mid-glide
        -- and the window we are animating keeps its fullscreen float. Take
        -- the window back first, and if it cannot be had, stop the glide and
        -- let the watchdog put things right.
        if not focusAddr(addr) then
            release("lost-focus")
            return
        end
        local t = i / frames
        local e = 1 - (1 - t) * (1 - t) * (1 - t) -- easeOutCubic
        placeFocused({
            x = math.floor(from.x + (dest.x - from.x) * e + 0.5),
            y = math.floor(from.y + (dest.y - from.y) * e + 0.5),
            w = math.floor(from.w + (dest.w - from.w) * e + 0.5),
            h = math.floor(from.h + (dest.h - from.h) * e + 0.5),
        })
        if i < frames then
            hl.timer(tick, { timeout = 16, type = "oneshot" })
        else
            land(addr, dest, wasActive)
            release("landed")
        end
    end
    hl.timer(tick, { timeout = 16, type = "oneshot" })
    -- The watchdog. The normal path is ~160ms, so 900ms is generous; this
    -- exists purely for the paths that never reach land() -- a reload, a
    -- workspace switch, an app closing, a throw above. It restores the move
    -- animation AND puts the window back in the layout, which is the part the
    -- old net was missing and the part that was hiding the desktop.
    hl.timer(function() release("watchdog") end, { timeout = 900, type = "oneshot" })
    end)
    if not ok then
        -- Named rather than swallowed: see the trace note above. Written to a
        -- file, because print() from this VM never reaches hyprland.log.
        trace("anchoredTransition FAILED: " .. tostring(err))
        release("throw")
        return
    end
    end
    hl.timer(begin, { timeout = 16, type = "oneshot" })
end

hl.gesture({
    fingers = 4,
    direction = "down",
    -- Closing the window you are looking at should not stop working just
    -- because it is fullscreen.
    disable_inhibit = true,
    action = {
        start = function(e)
            -- The desktop grid is up. This swipe belongs to IT here: it puts
            -- the grid away and the gesture ends, so no window behind it is
            -- ever grabbed, moved or closed. Checked first, before the
            -- wallpaper carousel and the close-drag below, because the
            -- carousel's branch is a plain `return` and would otherwise
            -- swallow the swipe on a desktop that happens to be empty.
            if desktopOverviewOpen() then
                hl.dispatch(hl.dsp.global("quickshell:desktopOverviewDismiss"))
                closeDrag = nil
                return
            end
            -- Empty desktop: the close-drag has no window to close, but an
            -- open wallpaper carousel does -- four fingers DOWN over it is
            -- its close, the mirror of the 4f-up open. The shell's close
            -- shortcut is a no-op when the stage is shut. (popup.lua's
            -- is_workspace_empty, not desktopIsEmpty, which is declared
            -- further down and would be nil in scope here.)
            local aws = hl.get_active_workspace()
            if aws and aws.id and aws.id >= 1 and popup.is_workspace_empty(aws.id) then
                hl.dispatch(hl.dsp.global("quickshell:wallpaperSwipeClose"))
                closeDrag = nil
                return
            end
            local win = hl.get_active_window()
            if not win then
                trace("4f-down start: no active window")
                closeDrag = nil
                return
            end
            tracef("4f-down start: %s fs=%.0f floating=%s",
                tostring(win.class or "?"), tonumber(win.fullscreen) or 0,
                tostring(win.floating and true or false))
            local addr = win.address
            -- Screen height for the threshold, measured from the window's
            -- monitor so a second display does not skew it.
            local mon = win.monitor
            local screenH = (mon and mon.height) or 900
            closeDrag = { addr = addr, dy = 0, t0 = e.time_ms, screenH = screenH,
                wasFloating = win.floating, wasFullscreen = (win.fullscreen or 0) ~= 0 }
            -- The RAW event, dumped once per gesture. The timing arithmetic in
            -- finish() needs a timestamp field, and this build's gesture event
            -- has never been confirmed to carry the one that code assumed --
            -- which is exactly why a missing field there silently killed the
            -- entire close (see finish). Rather than guess a field name again,
            -- the keys are recorded once so the next swipe names them.
            trace("4f-down start: " .. describeGestureEvent(e))
            if closeDrag.wasFullscreen then
                -- Fullscreen: it detaches and follows the fingers like anything
                -- else. This used to be threshold-close only (unfullscreening
                -- under the hand was judged to read as the window exploding),
                -- but that left fullscreen apps -- and the morphed settings /
                -- task-manager window, which is exactly this case -- as the one
                -- thing four fingers down could NOT move. It is safe now because
                -- the window is pinned to the monitor rect in the same frame it
                -- leaves fullscreen: for that instant it looks identical, and
                -- from there it slides down with the fingers and reveals the
                -- desktop behind it instead of vanishing.
                --
                -- Exception: a tray app (WhatsApp, etc.) is going to be parked
                -- into the vault, not closed. Unfullscreening it at the start of
                -- the swipe makes it flash non-fullscreen for the duration of the
                -- gesture ("reopens in fullscreen for a few seconds and then
                -- closes truthfully in the system tray"). A fullscreen window
                -- cannot follow the fingers via hl.dsp.window.move anyway, so
                -- skip the unfullscreen/float/resize/move dance for tray apps:
                -- keep it fullscreen, disable follow, and let the commit path
                -- park the fullscreen window directly.
                closeDrag.wasFloating = win.floating
                if isTrayAppCls(win.class or win.initialClass or "") then
                    closeDrag.follow = false
                    closeDrag.weUnfullscreened = false
                else
                    closeDrag.follow = true
                    closeDrag.weUnfullscreened = true
                    local mon = win.monitor
                    -- monitor.width/height are PHYSICAL here (2256x1504 on this
                    -- 1.6x panel) while the geometry dispatchers work in LOGICAL
                    -- units, so divide by scale (1410x940).
                    local mw = (mon and mon.width) or 1410
                    local mh = (mon and mon.height) or 940
                    local mscale = (mon and mon.scale) or 1
                    if mscale <= 0 then mscale = 1 end
                    local lw = math.floor(mw / mscale + 0.5)
                    local lh = math.floor(mh / mscale + 0.5)
                    local mx = (mon and mon.x) or 0
                    local my = (mon and mon.y) or 0
                    closeDrag.savedW, closeDrag.savedH = lw, lh
                    closeDrag.savedX, closeDrag.savedY = mx, my
                    hl.animation({ leaf = "windowsMove", enabled = false, speed = 1 })
                    -- Leave fullscreen, then pin to the rect it visually already
                    -- had, so the first follow frame starts from what the user is
                    -- looking at.
                    hl.dispatch(hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle", address = addr }))
                    -- Float it EXPLICITLY -- and unconditionally. `float()`
                    -- TOGGLES, and this build drops a float request that arrives
                    -- while the window is still fullscreen, so a toggle could leave
                    -- it TILED. The absolute resize below is then a SPLIT-RATIO
                    -- change rather than a size change, which permanently rearranged
                    -- the workspace: that is exactly "the desktop apps' positions
                    -- get shifted". `set` states the intent, and is a no-op when it
                    -- is already floating.
                    hl.dispatch(hl.dsp.window.float({ action = "set", address = addr }))
                    -- Re-read it: geometry work is only safe once it really is
                    -- floating.
                    local function refloat()
                        for _, w2 in ipairs(hl.get_windows() or {}) do
                            if w2.address == addr then return w2 end
                        end
                        return nil
                    end
                    local now = refloat()
                    closeDrag.isFloating = (now and now.floating) or false
                    if closeDrag.isFloating then
                        hl.dispatch(hl.dsp.window.resize({ x = lw, y = lh, address = addr }))
                        hl.dispatch(hl.dsp.window.move({ x = mx, y = my, address = addr }))
                    else
                        -- The read can lag the dispatch queue. Retry once, one
                        -- frame later; if it is floating by then the pin lands and
                        -- the follow starts, offset by however far the fingers
                        -- already travelled. If it still is not, the window is left
                        -- alone entirely and this swipe stays a threshold close.
                        closeDrag.follow = false
                        hl.timer(function()
                            if not closeDrag or closeDrag.addr ~= addr then return end
                            local w3 = refloat()
                            if not w3 or not w3.floating then return end
                            closeDrag.isFloating = true
                            closeDrag.follow = true
                            hl.dispatch(hl.dsp.window.resize({ x = lw, y = lh, address = addr }))
                            hl.dispatch(hl.dsp.window.move({ x = mx, y = my + closeDrag.dy, address = addr }))
                        end, { timeout = 40, type = "oneshot" })
                    end
                end
            elseif win.floating then
                -- Floating already: follow the fingers 1:1. Kill the move
                -- animation so per-frame dispatches land instantly. (speed is
                -- REQUIRED by hl.animation even when disabling -- leaving it
                -- out throws, which is how an older revision of this gesture
                -- silently skipped the disable: every follow move then played
                -- the windowsMove tween and the card rubber-banded behind the
                -- fingers instead of tracking them.)
                closeDrag.follow = true
                hl.animation({ leaf = "windowsMove", enabled = false, speed = 1 })
            else
                -- Tiled: the tiler owns the position and ignores pixel moves,
                -- so float the window first (remembering that we did, to undo
                -- it on a spring-back) and then follow like any floating
                -- window. Float alone RESIZES the window to its last floating
                -- geometry (a 696x883 tile became an 800x700 float -- the
                -- "app changes size when swiping down" bug), so measure the
                -- tiled rect BEFORE floating and reassert it right after:
                -- resize to the exact tiled size, move to the exact tiled
                -- position. Each dispatch is separate (multi-statement evals
                -- with locals have thrown in this build), and each was verified
                -- to land the exact geometry on a floating window. From the
                -- user's eye the window is now the SAME SIZE while it starts
                -- following the fingers.
                closeDrag.follow = true
                closeDrag.weFloated = true
                -- size/at are {x=,y=} tables, NOT arrays -- size[1] was nil and
                -- the resize/move then dispatched nil geometry (which throws
                -- inside dsp.focus -- its own x&y validator).
                closeDrag.savedW = win.size and win.size.x or nil
                closeDrag.savedH = win.size and win.size.y or nil
                closeDrag.savedX = win.at and win.at.x or nil
                closeDrag.savedY = win.at and win.at.y or nil
                hl.animation({ leaf = "windowsMove", enabled = false, speed = 1 })
                hl.dispatch(hl.dsp.window.float({ address = addr }))
                if closeDrag.savedW and closeDrag.savedH then
                    hl.dispatch(hl.dsp.window.resize({ x = closeDrag.savedW, y = closeDrag.savedH, address = addr }))
                    hl.dispatch(hl.dsp.window.move({ x = closeDrag.savedX, y = closeDrag.savedY, address = addr }))
                end
            end
        end,
        update = function(e)
            local d = closeDrag
            if not d or e.cancelled then return end
            -- `delta` is read defensively. An event field that is missing or
            -- renamed must cost a frame of drag, not the whole gesture: this
            -- handler used to index `e.delta.y` blind, and a nil there threw
            -- inside a per-frame callback, where Hyprland has no interest in
            -- telling anyone.
            local delta = e.delta or {}
            local dy = tonumber(delta.y) or 0
            d.dy = d.dy + dy
            if d.dy < 0 then d.dy = 0 end -- one-way: this is a dismiss gesture
            -- Performance mode: no per-frame dispatches -- the drag records
            -- its travel and finish() closes or springs directly. That is
            -- the mode's whole contract: fewer dispatches, same features.
            if d.follow and not performance.performance then
                hl.dispatch(hl.dsp.window.move({ x = 0, y = dy, relative = true }))
            end
        end,
        finish = function(e)
            local d = closeDrag
            closeDrag = nil
            if not d then
                -- No window was taken: nothing was focused. (The popup-app
                -- fallback that used to close a layer-surface app here is
                -- retired with the popups.)
                trace("4f-down finish: no drag armed (start bailed early)")
                return
            end
            -- Commit: past a fifth of the screen, or a fast flick. A cancelled
            -- gesture never commits -- the fingers went somewhere else.
            --
            -- NOTHING HERE MAY THROW. This is the fix for the whole bug: the
            -- gesture used to compute `e.time_ms - d.t0` to get the flick
            -- speed, and this build's gesture event does not carry `time_ms`,
            -- so the subtraction was nil-minus-nil and THREW. The throw
            -- happened on the first line after the drag was set up, which meant
            -- everything after it never ran: no commit, no close, no park, and
            -- the window left floating where the fingers had dragged it. The
            -- symptom was "the four-finger swipe does not close anything", and
            -- it was invisible because the failure was a Lua error inside a
            -- compositor callback, on the one code path in this file that had
            -- no logging on it at all.
            --
            -- So: every field is coerced, the speed is simply 0 when there is
            -- no usable timing (which disables the flick shortcut and leaves
            -- the distance threshold doing the work), and the gesture degrades
            -- to a plain threshold close instead of dying. A cosmetic
            -- enhancement -- recognising a fast flick -- is never worth being
            -- the reason the primary action does not happen.
            local now = tonumber(e.time_ms) or tonumber(e.time) or tonumber(e.timestamp) or 0
            local t0 = tonumber(d.t0) or 0
            local dt = (now > t0) and ((now - t0) / 1000) or 0
            local speed = (dt > 0) and (d.dy / dt) or 0
            local commit = not e.cancelled
                and (d.dy > d.screenH * 0.2
                     or (d.dy > d.screenH * 0.05 and speed > 900))
            -- Traced UNCONDITIONALLY, including the non-committing case. A
            -- trace that only appears on success cannot answer "why did it not
            -- close", which is the question that matters when a dismiss gesture
            -- misbehaves -- and it is exactly why the last few rounds of this
            -- were guesswork. `speed` is the number to read when the window
            -- follows the fingers and springs back: it says whether the swipe
            -- simply did not travel far enough, or was cancelled.
            -- %.0f, NOT %d. `dy` accumulates touchpad deltas and is routinely
            -- fractional, and `%d` on a non-integral float is a hard error in
            -- Lua 5.3+ -- "bad argument to 'format' (number has no integer
            -- representation)". That error is thrown from inside the gesture
            -- END callback, so it aborts the very code path the log line was
            -- added to observe: the diagnostic took down the feature it was
            -- diagnosing. A log line that can throw is worse than no log line,
            -- because it converts a silent failure into a loud one that still
            -- loses the behaviour.
            tracef("4f-down finish: %s dy=%.0f need>%.0f speed=%.0f commit=%s",
                tostring(findWindow(d.addr) and (findWindow(d.addr).class or "?")),
                d.dy, d.screenH * 0.2, speed, tostring(commit))
            if commit then
                restoreMoveAnim()
                -- Traced, because this branch is where "the swipe did nothing"
                -- is decided and there was no way to see it happen. Every
                -- question worth asking about a dismiss that misbehaves --
                -- did the swipe commit at all, on which window, and how far it
                -- travelled -- is answered here, in one log.
                tracef("4f-down COMMIT %s dy=%.0f/%.0f speed=%.0f",
                    tostring(findWindow(d.addr) and (findWindow(d.addr).class or "?")),
                    d.dy, d.screenH, speed)
                --
                -- EVERY APP IS CLOSED THE SAME WAY NOW. There is no per-app
                -- branch here: no vault, no tray hide, no "close to tray"
                -- list, no special case of any kind. One gesture, one verb.
                --
                -- The per-app tray mechanism was removed at the user's
                -- request, after it failed to deliver the one thing it was
                -- for -- minimising a mail client to a tray instead of closing
                -- it -- across several attempts. What it actually cost is
                -- worth stating plainly, because the cost was structural and
                -- not a matter of a bug here or there:
                --
                --   * It needed a second process to watch the desktop and pull
                --     windows off it, so "is this app allowed on screen"
                --     became a question two processes had to agree on, live,
                --     via files with timestamps.
                --   * Every mechanism built for that -- a 150ms sweep, a 400ms
                --     re-assert, a permit handshake, a heartbeat -- was a
                --     place where one process could rearrange another
                --     process's windows, and each one is where the bugs lived.
                --   * Its failure modes were all silent, and all of them
                --     presented as "the four-finger swipe does not work".
                --
                -- So the honest trade is the one now in force: Thunderbird
                -- closes like every other app on this desktop, and the user
                -- gets no tray icon for it. If minimising instead of closing
                -- is wanted later, the right shape is the app's OWN mechanism
                -- (Thunderbird has none on Linux -- `mail.closeToTray` is
                -- Windows-only), not a compositor-side impersonation of one.
                --
                -- Window dispatchers ignore an `address` argument in this
                -- build and act on the FOCUSED window (the note at the top of
                -- this file) -- so the close is focus-scoped: make sure the
                -- dragged window is the focused one first, then close. A raw
                -- `{ address = ... }` here would close whatever holds focus
                -- if anything stole it mid-drag.
                focusAddr(d.addr)
                -- Per-app minimize-to-tray: if this window's class is in
                -- config.json's tray.closeToTray list, park it on the special
                -- tray workspace instead of closing (smartClose, above) --
                -- the same helper SUPER+Q uses, so the two paths cannot
                -- drift apart. Everything else closes normally.
                --
                -- A tray app is about to be PARKED, not closed -- and the drag's
                -- own start path may have floated this window (the tiled-start
                -- dance, or the fullscreen detach). Parking it in that state put
                -- a FLOATING window in the vault, and every later tray-icon open
                -- then restored that popup: the "opens as popup" regression.
                -- So undo the drag's float before parking. The vault invariant
                -- this enforces: smartClose never receives a floating window.
                -- (The float dispatcher on this build is focus-scoped -- an
                -- address form moved the wrong window, see focusRunningApp's
                -- note in the shell -- so focus first, then unset WITHOUT
                -- naming an address. focusAddr above already aims the focus.)
                -- For a non-tray app the float is deliberately left alone: it
                -- is closed outright below, and the close-survived spring-back
                -- already knows how to un-float a window that survived.
                if d.weFloated or d.weUnfullscreened then
                    local w = findWindow(d.addr)
                    if w and isTrayAppCls(w.class or w.initialClass or "") then
                        focusAddr(d.addr)
                        hl.dispatch(hl.dsp.window.float({ action = "unset" }))
                    end
                end
                if smartClose(d.addr) then return end
                hl.dispatch(hl.dsp.window.close())
                -- A close that asks for confirmation ("Save before
                -- quitting?") does not actually close: the window survived,
                -- still floating, still dragged half off its slot -- and
                -- pressing No left it there (the "app stays floating" report).
                -- So shortly after the close dispatch, check: if the window
                -- still exists, undo the drag -- spring it back up to where it
                -- sat, then hand it home (fullscreen for a detached one, the
                -- tiler for a floated one). A window that closed as expected
                -- makes the check a no-op.
                hl.timer(function()
                    if not findWindow(d.addr) then return end
                    -- Same focus-first contract as the spring-back below: these
                    -- three verbs ignore `address`, so each one has to be aimed
                    -- by focusing the window it is meant for.
                    focusAddr(d.addr)
                    if d.dy > 0 then
                        hl.dispatch(hl.dsp.window.move({ x = 0, y = -d.dy, relative = true }))
                    end
                    if d.weUnfullscreened then
                        hl.timer(function()
                            focusAddr(d.addr)
                            hl.dispatch(hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }))
                        end, { timeout = 350, type = "oneshot" })
                    elseif d.weFloated then
                        hl.timer(function()
                            focusAddr(d.addr)
                            hl.dispatch(hl.dsp.window.float({ action = "unset" }))
                        end, { timeout = 350, type = "oneshot" })
                    end
                end, { timeout = 450, type = "oneshot" })
                return
            end
            if d.follow then
                -- Spring back: re-enable the animation FIRST so this single
                -- move tweens smoothly to the origin, then hand the state
                -- back (the timer keeps nothing alive -- it is one-shot).
                restoreMoveAnim()
                -- FOCUS FIRST, then every verb below. `address` is IGNORED by
                -- these dispatchers on this build -- measured, not assumed: a
                -- relative move naming a window moved the focused one instead.
                -- So the spring-back was aiming at a window that could be
                -- anywhere, and when it was not the focused one the window was
                -- never re-tiled and stayed floating for the rest of the
                -- session. That is the "Thunderbird will not close any more,
                -- it just sits there" report, and it is why every verb in this
                -- function -- here and in the close-survived path above --
                -- focuses explicitly first.
                focusAddr(d.addr)
                if d.dy > 0 then
                    hl.dispatch(hl.dsp.window.move({ x = 0, y = -d.dy, relative = true }))
                end
                -- A window we floated for the drag goes back to the tiler once
                -- its spring-back has had time to play (the tween above is
                -- ~300ms); a barely-moved swipe re-tiles immediately.
                if d.weUnfullscreened then
                    -- It was fullscreen and was detached only so it could follow
                    -- the fingers. The swipe did not commit, so put it back
                    -- exactly as it was.
                    --
                    -- The old sequence un-floated the window on the way back:
                    -- float unset -> a TILED frame at whatever split geometry
                    -- -> fullscreen. That tiled frame is the flash -- the
                    -- "weird transition" the swipe-down close showed from
                    -- fullscreen. So the window STAYS floating through the
                    -- spring-back and only the fullscreen toggle comes after
                    -- the tween: a floating window that fullscreens keeps its
                    -- exact size for that instant, so no intermediate geometry
                    -- is ever on screen. (A toggled float-unset on the way back
                    -- also risked landing the window tiled in the WRONG state
                    -- when the tween had not finished.)
                    hl.timer(function()
                        focusAddr(d.addr)
                        hl.dispatch(hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }))
                    end, { timeout = 350, type = "oneshot" })
                elseif d.weFloated then
                    -- Re-tile EXPLICITLY (action = "unset"), never a toggle:
                    -- the bare float() call toggles, and if the spring-back
                    -- timer raced a second gesture (or the immediate path ran
                    -- while the window had already been un-floated), the toggle
                    -- re-FLOATED the window -- the "app stays floating after a
                    -- short swipe-down" report. Stating `unset` is
                    -- idempotent: floating or tiled afterwards, the tiler owns
                    -- the window again either way.
                    local retiler = function()
                        -- Focus first, for the reason given above: without it
                        -- this unset is aimed at whatever the user is looking at
                        -- now, and the dragged window keeps its float.
                        focusAddr(d.addr)
                        hl.dispatch(hl.dsp.window.float({ action = "unset" }))
                    end
                    if d.dy < 20 then
                        retiler()
                    else
                        hl.timer(retiler, { timeout = 350, type = "oneshot" })
                    end
                end
            end
        end,
    }
})

-- Layer surfaces: the popups (settings, the task manager, Wi-Fi, Bluetooth,
-- the sidebars) live on the layer shell, and the base config gives layers the
-- `menu_accel` / `stall` pair -- curves that start lazily and are still moving
-- at the end, which reads as sluggish rather than settled. These are the same
-- motion as a window's, just quicker: fast away, long settle, and the fade
-- finishing first so the surface is already gone when the frame drops.
hl.animation({
    leaf = "layersIn",
    enabled = true,
    speed = 3.8,
    bezier = "emphasizedDecel",
    style = "popin 96%"
})
hl.animation({
    leaf = "fadeLayersIn",
    enabled = true,
    speed = 2.6,
    bezier = "emphasizedDecel"
})
hl.animation({
    leaf = "layersOut",
    enabled = true,
    speed = 4.2,
    bezier = "emphasizedDecel",
    style = "popin 97%"
})
hl.animation({
    leaf = "fadeLayersOut",
    enabled = true,
    speed = 4.4,
    bezier = "standardDecel"
})

-- Windows, on both ends of a window's life: the same drop-in the sidebars use.
--
-- The layer surfaces above swing in with `popin 96%` on emphasizedDecel at
-- 3.4. A window used to OPEN with `popin 80%` at speed 3 and CLOSE with
-- `popin 90%` at speed 2 -- two different motions, the exit lazier and flatter
-- than the entry, which is why dismissing a window (four fingers down, or the
-- close button) read as a plain fade rather than the app's own swing played
-- backwards. Entry and exit now carry identical numbers, and those numbers are
-- the sidebars' own, so the entry swing and the exit swing are one gesture
-- seen in two directions. The fades are matched the same way.
hl.animation({
    leaf = "windowsIn",
    enabled = true,
    speed = 3.4,
    bezier = "emphasizedDecel",
    style = "popin 96%"
})
hl.animation({
    leaf = "windowsOut",
    enabled = true,
    speed = 3.4,
    bezier = "emphasizedDecel",
    style = "popin 96%"
})
hl.animation({
    leaf = "fadeIn",
    enabled = true,
    speed = 3.0,
    bezier = "emphasizedDecel"
})
hl.animation({
    leaf = "fadeOut",
    enabled = true,
    speed = 3.0,
    bezier = "emphasizedDecel"
})

-- Four fingers up makes the open popup a REAL fullscreen window.
--
-- With a window open this mirrors SUPER+F on the focused window (the
-- "fills the screen" toggle), so the app anchors with the desktop's other
-- windows when you swipe up again, exactly as asked. (It used to also morph
-- the settings / task-manager popups into windows; those apps are ordinary
-- desktop windows now, so the compositor handles them like everything else
-- and the popup branch is gone.)
-- ═══ Why the swipe up is instrumented ═══════════════════════════════════
--
-- "Sometimes the windows are not reacting to my four finger swipe up" could not
-- be reproduced from outside: a swipe cannot be synthesised (`ydotool` sends
-- keys and pointers, not libinput gesture events) and Hyprland fires this action
-- only at the END of a recognised swipe, with no distance and no way to ask it
-- what it decided. And `print()` from Lua never reaches the compositor log on
-- this build (verified: a marker print from the config VM leaves nothing in
-- hyprland.log), which is why the old failure message here was never seen.
--
-- So every swipe up now leaves a one-line trace in a file, saying what it found
-- and what it did: whether a popup app was present, whether the popup window was
-- found by title, what state it was in, and which branch ran. If it ever "does
-- nothing" again, that file says exactly which step came up empty instead of it
-- being guesswork -- and a swipe that reaches the end without matching anything
-- is recorded too, because "the gesture never fired at all" looks identical from
-- the outside and is the one thing this cannot distinguish for you.
-- Title match, forgiving: exact first, then case/whitespace-insensitive, then
-- "contains". A window whose title is still settling must not cost you a swipe.
local function titleMatches(title, want)
    if title == want then return true end
    local a = tostring(title or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local b = tostring(want or ""):lower()
    return a == b or a:find(b, 1, true) ~= nil
end

-- The swipe-up body, as a named function so it can run under pcall (below).
local function swipeUpBody()
    -- Four fingers up is "fill the screen WITHOUT telling the app it is
    -- fullscreen": the window is MAXIMIZED (mode = "maximized") and the bar is
    -- asked to give up its exclusive strip.
    --
    -- An earlier version of this comment described the opposite design -- real
    -- fullscreen, "mode = fullscreen" -- and claimed the cover handshake could
    -- not be trusted. The measurements it cited were real, but the diagnosis
    -- was not: the handshake was fine and the BAR half was reading two
    -- properties that do not exist on its own object (see coverAlive in
    -- modules/ii/bar/Bar.qml), so it returned false on every single evaluation.
    -- The bar therefore never yielded, which left the maximized window at
    -- [5,50] 1590x945 with the strip still reserved -- exactly the symptom that
    -- was blamed on the handshake.
    --
    -- Both halves are wanted, and they are wanted together:
    --
    --   * "maximized", NOT "fullscreen". This is the difference between sizing
    --     the window and TELLING THE APP it is fullscreen. mode = "fullscreen"
    --     asks the client to enter its own fullscreen state, which in a browser
    --     is F11 -- tabs, address bar and bookmarks all disappear, and the
    --     window that comes back is not the window that went out. What this
    --     gesture is for is "make this app fill the screen".
    --
    --   * the bar yields its strip, so the maximized window can actually reach
    --     the top edge instead of stopping at the workarea. A maximized window
    --     stops at the workarea, and the workarea includes the bar's strip, so
    --     without this half the app is left 50px down with a hoverable gap.
    --
    -- The strip request stays a request rather than a standalone mechanism: the
    -- bar re-derives whether to keep hiding from the window's own live state
    -- (coverAlive), so a window that closes or leaves the desktop cannot leave
    -- the bar stranded off-screen.
    local active = hl.get_active_window()
    trace("swipe up: active=" .. tostring(active and active.class)
        .. " fs=" .. tostring(active and active.fullscreen))
    if not active then
        trace("swipe up: no active window")
        return
    end
    if (active.fullscreen or 0) ~= 0 or cover.owns(active) then
        -- Coming back OUT: the window leaves its expanded state FIRST, and
        -- only then is the bar's strip returned -- the reverse order snaps
        -- the window's height twice in two frames.
        --
        -- Two shapes of "out" exist now:
        --   * fs ~= 0 (an app fullscreened itself): anchoredTransition toggles
        --     it off and re-tiles -- the pre-float-cover path, unchanged.
        --   * the float-cover THIS module creates (fs == 0, floating at the
        --     full monitor): anchoredTransition has nothing to toggle, so
        --     cover.exit does the restore -- un-float, old tile, geometry.
        --     Calling both would un-float twice and land the window floating.
        if (active.fullscreen or 0) ~= 0 then
            anchoredTransition(active.address, false)
            cover.barStrip(active.address, false)
        else
            cover.exit(active)
        end
        return
    end
    -- Where it sat before it covered the screen. It cannot be read back from
    -- the tiler once the window is out of the layout, which is what
    -- anchoredTransition lands on the way home.
    popup.rememberSlot(active)
    -- Yield the strip first: the window is about to be laid out, and this
    -- keeps the bar from animating over the app for a frame.
    cover.barStrip(active.address, true)
    --
    -- "maximized", NOT "fullscreen". This is the difference between sizing
    -- the window and TELLING THE APP it is fullscreen: mode = "fullscreen"
    -- asks the client to enter its own fullscreen state, which in a browser
    -- is F11 -- the tabs, the address bar and the bookmark bar all disappear,
    -- and the window that comes back is not the window that went out. What
    -- this gesture is for is "make this app fill the screen", so it fills
    -- the work area and the app is left alone. Probed states on this build
    -- are 1 = maximized and 2 = fullscreen.
    -- The cover itself: float + pin to the exact full-monitor geometry. NOT
    -- "maximized" (gaps_out framed it on all four sides -- the visible
    -- background border), and NOT "fullscreen" (that is F11 to the client).
    -- The app is never told anything; fs stays 0. See custom/cover.lua.
    cover.enter(active)
    trace("swipe up: cover " .. tostring(active.address))
end

-- Four fingers up is TWO gestures now, split by what the desktop looks like:
--
--   EMPTY desktop  -> the wallpaper carousel, opened by the swipe itself: the
--   shell's stage maps on the first travel and follows the fingers 1:1 until
--   release (WallpaperSwipe.qml). The open is triggered at the swipe's START,
--   not its end -- that is the whole point of the follow-finger feel -- and
--   the finish trigger tells the shell the fingers came up (commit or abort).
--
--   BUSY desktop   -> the focused window is MAXIMIZED: it fills the work
--   area and the app is never told it is fullscreen. It used to be
--   mode = "fullscreen", which is an F11 to the client -- a browser lost its
--   tabs, address bar and bookmark bar, and the window that came back was
--   not the one that went out. Sizing the window is what this gesture is
--   for; the app's own fullscreen mode is the app's business.
--   (The four-finger-DOWN close-drag gesture is a separate binding and is
--   untouched; this only re-shapes the UP gesture.)
--
-- The empty-desktop check happens in `start`, on the same predicate the 3f
-- and pinch paths use (popup.is_workspace_empty -- NOT desktopIsEmpty, which
-- is a local declared further down this file and reads as nil from a closure
-- created before that declaration runs). `fourUpSwipeArmed` records that the
-- swipe was handed to the shell, and `finish` consumes it -- so even if the
-- desktop somehow stops being empty mid-swipe, the finish never ALSO fires
-- the fullscreen toggle. A 4-finger TAP also passes through `start` -- the
-- shell only opens its stage after real travel, so taps still fall through
-- to the overview untouched.
--
-- The same throw-rule as before applies, now to both halves: ANY throw inside
-- a gesture callback aborts the whole gesture silently (that is how
-- four-fingers-up once died on `hl.get_window({class = ...})` -- "expected a
-- window object or selector" -- with nothing in the log). Everything runs
-- under pcall, and failures are named in the trace file instead of vanishing.
local fourUpSwipeArmed = false
-- The four-finger-up attach, for the same reason and with the same
-- start/finish split: `start` attaches, `finish` must not also maximize.
-- Declared here, beside the flag it mirrors, so the two cannot drift apart.
local fourUpAttachArmed = false

hl.gesture({
    fingers = 4,
    direction = "up",
    disable_inhibit = true,
    action = {
        start = function(e)
            -- The flag is cleared FIRST, every time, before anything else.
            -- It is the only state this gesture keeps, and a leftover "true"
            -- from an earlier swipe (one the shell never finished, e.g. a
            -- swipe started on an empty desktop and lifted before the stage
            -- mapped) makes the NEXT four-finger-up return out of `finish`
            -- without fullscreening anything -- the gesture silently does
            -- nothing and looks like some other gesture is eating it. Reset
            -- here and a stale flag can never outlive its own swipe.
            fourUpSwipeArmed = false
            -- Same attach verdict as the three-finger swipes, on the gesture
            -- that otherwise maximizes. It runs in START and sets its own
            -- flag, because the maximize lives in FINISH: attaching here and
            -- letting finish run would attach the window and then maximize
            -- it in the same swipe, which is the opposite of what was asked.
            fourUpAttachArmed = false
            local ok, err = pcall(function()
                if attachFocusedFloat() then
                    fourUpAttachArmed = true
                    return
                end
                local aws = hl.get_active_workspace()
                if not aws or not aws.id or aws.id < 1 then
                    trace("4f-up start: no usable workspace")
                    return
                end
                if not popup.is_workspace_empty(aws.id) then
                    trace("4f-up start: busy desktop -> fullscreen path")
                    return
                end
                fourUpSwipeArmed = true
                trace("4f-up start: empty desktop -> wallpaper carousel")
                hl.dispatch(hl.dsp.global("quickshell:wallpaperSwipeOpen"))
            end)
            if not ok then trace("4f-up start FAILED: " .. tostring(err)) end
        end,
        finish = function(e)
            -- Always told to the shell: it resolves the swipe-open (commit,
            -- or abort a too-tiny drag). A no-op when nothing was armed.
            local ok, err = pcall(function()
                hl.dispatch(hl.dsp.global("quickshell:wallpaperSwipeFinish"))
            end)
            if not ok then trace("4f-up finish FAILED: " .. tostring(err)) end
            -- The swipe was the carousel's: resolved above, and the
            -- fullscreen toggle must not also fire.
            if fourUpSwipeArmed then
                fourUpSwipeArmed = false
                trace("4f-up finish: swipe belonged to the carousel")
                return
            end
            -- The swipe belonged to the attach above. Checked immediately
            -- after the carousel, and before the empty-desktop test, so no
            -- later branch can maximize what was just attached.
            if fourUpAttachArmed then
                fourUpAttachArmed = false
                trace("4f-up finish: swipe belonged to the attach")
                return
            end
            local aws = hl.get_active_workspace()
            if not aws or not aws.id or aws.id < 1 then
                trace("4f-up finish: no usable workspace")
                return
            end
            if popup.is_workspace_empty(aws.id) then
                trace("4f-up finish: desktop went empty mid-swipe, not touching anything")
                return
            end
            trace("swipe up fired")
            local ok2, err2 = pcall(swipeUpBody)
            if ok2 then return end
            -- Written to a file, not printed: see the trace note above -- print()
            -- from this VM never reaches hyprland.log on this build.
            trace("action FAILED: " .. tostring(err2))
            local w = hl.get_active_window()
            if not w then return end
            if (w.fullscreen or 0) == 0 then popup.rememberSlot(w) end
            -- Same shape as swipeUpBody, and for the same reason: it COVERS
            -- (float + pin) rather than fullscreens, so this gesture can
            -- never put an app into its own fullscreen mode (the F11 case --
            -- a browser losing its tabs). Going out it restores whatever the
            -- window actually was (cover.exit) or toggles a real fullscreen
            -- (2) off; the two never stack.
            if (w.fullscreen or 0) == 2 then
                hl.dispatch(hl.dsp.window.fullscreen({
                    mode = "fullscreen", action = "toggle", address = w.address }))
                cover.barStrip(w.address, false)
            else
                cover.toggle(w)
            end
        end
    }
})

-- (No animation leaf is set for fullscreening here: this build has no
-- `fullscreen` leaf -- setting one is an error, "no such animation leaf", and
-- a red badge on the config. See anchoredTransition above for how the way back
-- out of fullscreen is animated.)

-- ═══ Desktop swap: the "card whip" ════════════════════════════════════════
-- Not the usual horizontal conveyor: switching desktops now
--   1. holds a beat (the screen barely moves for the first third),
--   2. WHIPS vertically through the swap in one punchy motion,
--   3. settles hard, no float.
-- The direction flip (vertical instead of horizontal) plus the
-- anticipation-and-whip curve makes the swap read as flicking a card
-- off a deck rather than sliding a drawer.
--
-- `deskwhip` curve: cubic-bezier(0.42, 0.02, 0.16, 0.96) -- flat launch,
-- explosive middle, instant settle. Deliberately NOT an ease-out: the
-- stillness before the punch is the character of the motion.
hl.curve("deskwhip", {
    type = "bezier",
    points = {{0.42, 0.02}, {0.16, 0.96}}
})

-- The workspace glide itself: HORIZONTAL (the desktops are arranged left to
-- right, so the swap travels the way the bar's own widget reads), with a
-- follow-through settle. That curve choice is what makes it "go together
-- with the swipe": the native four-finger swipe drags the desktops 1:1 with
-- the fingers, and on release THIS animation finishes the trip -- so it must
-- start fast (carrying the hand's momentum) and ease out, not punch from a
-- standstill. The tiny ~5% overshoot lands the deck with a settle-bounce.
hl.curve("desksettle", {
    type = "bezier",
    points = {{0.16, 1.05}, {0.30, 1.0}}
})
hl.animation({
    leaf = "workspaces",
    enabled = true,
    speed = 3.6,
    bezier = "desksettle",
    style = "slide"
})

-- During the whip the outgoing desktop dims and the incoming one brightens,
-- which separates the two decks instead of both being fully lit mid-slide.
hl.animation({
    leaf = "fadeSwitch",
    enabled = true,
    speed = 2.5,
    bezier = "standardDecel"
})

-- The special-workspace overlay (the dropdown deck) plays the same whip,
-- so every desktop change speaks one motion language.
hl.animation({
    leaf = "specialWorkspaceIn",
    enabled = true,
    speed = 3.4,
    bezier = "deskwhip",
    style = "slidevert"
})
hl.animation({
    leaf = "specialWorkspaceOut",
    enabled = true,
    speed = 3.0,
    bezier = "deskwhip",
    style = "slidevert"
})

-- ═══ Desktop switch: anamorphic illusion ══════════════════════════════════
-- Every workspace switch plays the anamorphic-illusion screen pass: the
-- anamorphic.py driver arms the compositor's GLSL shader, dispatches the
-- switch, and clears it; the shader self-terminates at ~0.8 s even if the
-- driver dies. Upstream's plain SUPER+digit / code switchers are unbound
-- here (this file loads after hyprland/keybinds.lua) and re-bound through
-- the driver. Secondary chords (CTRL+SUPER+arrows, Page keys, mouse wheel)
-- keep their plain behaviour so the effect never fires by accident.
local ANAMORPHIC = HOME .. "/.config/hypr/custom/scripts/anamorphic.py"
local function ana_switch(target)
    hl.exec_cmd(ANAMORPHIC .. " focus " .. target)
end

for i = 1, 10 do
    hl.unbind("SUPER + " .. (i % 10))
end
local numberkeys = { 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 }
local numpadkeys = { 87, 88, 89, 83, 84, 85, 79, 80, 81, 90 }
for i = 1, 10 do
    hl.unbind("SUPER + code:" .. numberkeys[i])
    hl.unbind("SUPER + code:" .. numpadkeys[i])
end
for i = 1, 10 do
    hl.bind("SUPER + " .. (i % 10), function()
        ana_switch(workspace_in_group(i))
    end, { description = "Workspace: Focus " .. i .. " (anamorphic)" })
    hl.bind("SUPER + code:" .. numberkeys[i], function()
        ana_switch(workspace_in_group(i))
    end)
    hl.bind("SUPER + code:" .. numpadkeys[i], function()
        ana_switch(workspace_in_group(i))
    end)
end

-- ═══ Pinch: open/close the wallpaper carousel ═════════════════════════
--
-- REQUESTED (2026-09-26): the wallpaper pill is gone; the wallpaper carousel
-- (the shell's "theatre", modules/ii/background/WallpaperModal.qml) opens by
-- PINCHING OUT on the touchpad, and only when the ACTIVE DESKTOP IS EMPTY --
-- no app window on it. Pinching in closes it again (and while it is open
-- there is by definition nothing else on the desktop, so the empty check
-- costs nothing there).
--
-- Like every gesture this fires once, on completion: no distance, no live
-- scale -- so both directions get one decisive action. The empty-desktop
-- rule is the same one the retired pill's own gesture layer used (zero
-- mapped windows on the active workspace; special workspaces never count).
-- 3-finger pinch is deliberately untouched: it stays the fullscreen toggle
-- from the base config.
local function desktopIsEmpty()
    local active = hl.get_active_workspace()
    if not active or not active.id or active.id < 1 then return false end
    for _, w in ipairs(hl.get_windows() or {}) do
        if w.workspace and w.workspace.id == active.id
            and w.mapped ~= false and w.hidden ~= true then
            return false
        end
    end
    return true
end

hl.gesture({
    fingers = 2,
    direction = "pinchout",
    disable_inhibit = true,
    action = function()
        if not desktopIsEmpty() then return end
        hl.dispatch(hl.dsp.global("quickshell:wallpaperStageOpen"))
    end
})

hl.gesture({
    fingers = 2,
    direction = "pinchin",
    disable_inhibit = true,
    action = function()
        -- No empty-desktop gate on the way in: closing what is open must
        -- always work, whatever the desktop looks like behind the modal.
        hl.dispatch(hl.dsp.global("quickshell:wallpaperStageClose"))
    end
})

-- SUPER + 3-finger swipe UP: the second way into the wallpaper carousel.
-- Same empty-desktop rule as the pinch (both were requested together):
-- desktops with app windows keep the swipe for the window gestures (the
-- popup morph / fullscreen toggle). The plain 3-finger up stays the popup
-- morph / fullscreen toggle; this SUPER variant only ever opens the
-- carousel -- it must not double as a close, so a misfire on a busy desktop
-- does nothing instead of closing something.
hl.gesture({
    fingers = 3,
    direction = "up",
    mods = "SUPER",
    disable_inhibit = true,
    action = function()
        if not desktopIsEmpty() then return end
        hl.dispatch(hl.dsp.global("quickshell:wallpaperStageOpen"))
    end
})

-- SUPER + 3-finger swipe DOWN closes the carousel: the mirror of the open
-- gesture, so both hands-full gestures are reversible without a pinch.
hl.gesture({
    fingers = 3,
    direction = "down",
    mods = "SUPER",
    disable_inhibit = true,
    action = function()
        hl.dispatch(hl.dsp.global("quickshell:wallpaperStageClose"))
    end
})

-- ═══ New windows must not cover the desktop ═════════════════════════════
--
-- REQUESTED (2026-09-26): SUPER+Return opened the terminal FULLSCREEN over
-- the apps already on the desktop — "it hides the other desktop apps". The
-- repro (probe + clients polling) showed it is not the terminal bind at all:
-- this fork's dwindle hands EVERY new tiled window a maximized frame on
-- arrival (fs=1 at ~200ms, the live client list confirms it for kitty and
-- for any other class), which demotes whatever held the screen before it —
-- so any app launched from anywhere lands covering the desktop. The
-- fullscreen-first DESIGN stays: a window arriving on an EMPTY desktop (or
-- being the only one there) still gets the whole screen; that is the
-- desktop's identity. What is removed is only the eviction: when the target
-- desktop ALREADY has windows, the newcomer opens as a plain tile beside
-- them instead of stealing the screen. Applies to every application (the
-- rule is "any window", not per-class), and deliberately also to dialogs —
-- a dialog on a busy desktop is equally a tile, and the float rules below
-- still apply on top of this for the ones that float.
--
-- Mechanics, the parts that were learned the hard way:
--   * `hl.on("window.open", ...)` fires AT MAP TIME — but the tiler applies
--     the maximized frame LATER (~200ms after map on this build, measured);
--     a single early check would read fs=0 and do nothing. So the check is
--     a RETRY LOOP: every 60ms for up to ~1.2s, until the window's state
--     settles (maximized -> demote and stop; still tiled past the window ->
--     give up quietly).
--   * Dispatchers in this build ignore `{ address = ... }` for some verbs;
--     acting on `hl.dsp.focus({window = w})` first is the reliable way to
--     aim the fullscreen dispatcher at the right window (the codebase's own
--     "focus-then-act" pattern, as used by the swipe-down close).
--   * `action = "unset"` (not "toggle") is idempotent: a double delivery of
--     the event can never RE-maximize the window.
--   * The window may already be gone when a retry runs (fast apps, spawns
--     that fail) — every step is guarded and pcall-wrapped so a dying
--     window can never take the config down.
--   * Special workspaces (the minimized store) are skipped entirely: their
--     windows are hidden by definition and must not be unmapped/rearranged.
--   * Only windows on the ACTIVE workspace are demoted: that is the whole
--     SUPER+Return case (spawns follow focus here), and it means a window
--     an app restores onto a BACKGROUND desktop can never yank the view
--     there — the focus-then-act dispatch below would otherwise do that.
--     Background arrivals keep the fullscreen-first frame; the user meets
--     them on navigation, where the empty-desktop design still applies.
-- A DIALOG must never be able to disturb the window it was opened from.
-- Two bugs came out of that not being true here, both reported as "clicking
-- a dropdown (Auswählen) breaks the app":
--
--   1. A FULLSCREEN app lost its fullscreen the instant a chooser opened.
--      The picker is its own window, and it is not floating (the float rule
--      loses the race to the catch-all float=false -- see the picker block in
--      rules.lua), so the count below saw TWO tiled windows on the desktop
--      and unset fullscreen on the parent. Reproduced: brave went fs=2 at
--      16:11:44 to fs=0 the frame org.hypr.Explorer.Picker appeared.
--   2. An ATTACHED app visibly reflowed for about a second on every click.
--      Same count, opposite direction: the picker joined the tiler, so the
--      parent's tile was recomputed (measured live: brave's y went 96 -> 6 ->
--      96 across consecutive frames as the picker was placed and the layout
--      settled).
--
-- So the fix is not in the fullscreen logic at all -- it is to make sure a
-- DIALOG is never treated as an occupant of the layout. The picker, portal
-- dialogs, polkit agents and the "wants to open/save" prompts are all
-- dialogs; they float, they are transient, and they must be invisible to
-- every count below.
--
-- Matching is by CLASS, deliberately, and the list is the same one the float
-- rules use. Matching by title alone was not enough: the chooser's title is
-- set by whoever opened it ("Auswählen", "Save As", a file name), which is
-- exactly the "dropdown menus like in the image" case, and no title pattern
-- covers every one of them.
local DIALOG_CLASSES = {
    ["org.hypr.Explorer.Picker"] = true,   -- every portal Open/Save dialog
    ["org.hypr.Explorer"] = true,         -- the file manager itself
    ["xdg-desktop-portal-gtk"] = true,
    ["xdg-desktop-portal-gtk4"] = true,
}

-- Portals pick their window class at runtime, so a substring match on
-- "portal" and "polkit" is the net for the ones not listed by name. Kept
-- narrow on purpose: this predicate EXCLUDES a window from the layout logic
-- below, so a false positive would let a real app cover the desktop.
function isDialogClass(class)
    local c = tostring(class or "")
    if DIALOG_CLASSES[c] then return true end
    if c:find("portal", 1, true) then return true end
    if c:lower():find("polkit", 1, true) then return true end
    return false
end

hl.on("window.open", function(w)
    local addr = tostring(w)
    local tries = 0
    local function check()
        pcall(function()
            local wins = hl.get_windows() or {}
            local live = nil
            for _, x in ipairs(wins) do
                if tostring(x) == addr then live = x break end
            end
            if not live then return end -- gone: nothing to do, stop
            local ws = live.workspace
            if not ws or (ws.id or 0) < 1 then return end -- special/hidden
            -- Dialogs are not ours: not counted as occupants below, and never
            -- demoted themselves.
            if live.floating or isDialogClass(live.class) then return end
            local act = hl.get_active_workspace()
            if not act or act.id ~= ws.id then return end -- background spawn
            if (live.fullscreen or 0) ~= 0 then
                -- The expanded frame has landed (or was already there).
                --
                -- UNCONDITIONAL, and this used to be gated on the desktop
                -- already being occupied (`if count > 1`, counting the
                -- non-dialog, non-floating windows on the workspace). That
                -- gate meant the ONE case nobody wants was the only case
                -- left alone: start an app on an empty desktop, it is the
                -- only window there, so it kept the fullscreen-first frame
                -- and filled the screen, while every arrival onto a busy
                -- desktop was demoted. The count is gone rather than kept
                -- as dead code.
                --
                -- This is the same rule as `float = false` in rules.lua,
                -- applied to the other half of "attached": a window that
                -- starts covering the whole monitor is not attached to
                -- anything, it is a card on top of the desktop.
                --
                -- Mirror anchoredTransition's mode pick: unsetting
                -- "maximized" on a TRUE fullscreen window would stack
                -- states — leave the window in the mode it is in.
                local mode = ((live.fullscreen or 0) == 2) and "fullscreen" or "maximized"
                hl.dispatch(hl.dsp.focus({ window = live }))
                hl.dispatch(hl.dsp.window.fullscreen({ mode = mode, action = "unset" }))
                return -- settled: stop watching
            end
            -- Not expanded YET — the tiler may still be about to do it.
            tries = tries + 1
            if tries < 20 then hl.timer(check, { timeout = 60, type = "oneshot" }) end
        end)
    end
    hl.timer(check, { timeout = 60, type = "oneshot" })
end)

-- ═══ A new app must be SEEN, so a fullscreen neighbour steps aside ═════
--
-- REQUESTED: opening another app while something is fullscreen should leave
-- fullscreen and go back to ATTACHED, so the app that just opened is
-- actually visible.
--
-- WHY IT IS NOT ALREADY TRUE
-- -------------------------
-- The hook above handles the OPPOSITE case: a window that ARRIVES fullscreen
-- gets demoted. This one handles a window that arrives NORMAL while a
-- DIFFERENT window is already fullscreen. Nothing in the config looked at
-- that, so the new app mapped itself into the layout underneath a
-- fullscreen window that covered all of it -- the launcher was dismissed, the
-- new app was running, and the screen looked unchanged. Measured shape of the
-- bug: the new window is in `hl.get_windows()` at a normal tiled rect, and
-- the fullscreen one is still `fullscreen == 2` on top of it.
--
-- WHY UNSETTING IS ENOUGH, and why the window goes back to ATTACHED rather
-- than being floated
-- -------------------------------------------------------------------------
-- A fullscreen window on this build is still a TILED window: the tiler never
-- dropped it, so its slot is intact and `fullscreen {action = "unset"}`
-- returns it to exactly that slot. Nothing has to be reconstructed, which is
-- why this is a one-line demotion and not a re-tile. (The same fact is what
-- makes the "attached, not floating" wording correct here.)
--
-- WHAT IS DELIBERATELY NOT TOUCHED
-- --------------------------------
--   * DIALOGS. A polkit prompt or a file chooser floats ABOVE fullscreen
--     already, so it is visible without this. Demoting for one would yank
--     the user out of a video for a dialog they can already see.
--   * SPECIAL/HIDDEN WORKSPACES. A window arriving on one is not stealing the
--     screen, so there is nothing to reveal.
--   * THE ARRIVING WINDOW ITSELF. Only the incumbent is demoted. A window
--     that opens fullscreen is the hook above's business, and doing both
--     here would fight it.
--   * A WORKSPACE WITH NO FULLSCREEN WINDOW. The common case: nothing to do,
--     and the early return keeps this off the hot path entirely.
--
-- The mode is read the same way as everywhere else in this file (1 =
-- maximized, 2 = fullscreen, probed on this build) so unsetting never stacks
-- a maximized state on top of a fullscreen one.
hl.on("window.open", function(w)
    -- `w.address`, NOT `tostring(w)`. The payload is a USERDATA window, and
    -- tostring on it yields "HL.Window(0x55dda1d33060)" -- a debug string
    -- that contains the address but is not one. Probed, not guessed:
    --
    --   type=userdata tostring=HL.Window(0x55dda1d33060)
    --
    -- findWindow() compares `w.address == addr`, so a tostring'd payload
    -- never matches, `newcomer` was nil on every tick, and the hook returned
    -- without ever demoting anything. It looked like it worked -- the
    -- fullscreen window did come out of fullscreen when a new app opened --
    -- which is the dangerous part: that was the FIRST hook above doing its
    -- own job, not this one, so the trace never fired and the real cause
    -- would have been misfiled as "already fixed".
    --
    -- The first hook gets away with tostring because it compares tostring
    -- against tostring of a window from the same list, so the two debug
    -- strings are equal by pointer identity. Matching a debug string is not
    -- the same as matching an address, and only one of the two is correct.
    local addr = w.address
    if not addr then return end
    local settled = false
    local function step()
        pcall(function()
            if settled then return end
            local newcomer = findWindow(addr)
            -- Not in the list yet is the NORMAL first tick, not "nothing to
            -- do" -- measured, and the reason the popup hook below documents
            -- at length. So return without settling and let the timer retry.
            if not newcomer then return end
            -- ANY window counts now. There used to be an early return here:
            --
            --     if newcomer.floating or isDialogClass(...) then
            --         settled = true; return
            --     end
            --
            -- which meant a POPUP opening never demoted anything. That was
            -- defensible when the rule only protected tiled windows -- a
            -- floating dialog already draws above a fullscreen tiled window,
            -- so it did not need the screen vacated. But the request is
            -- simply "if another app or popup opens, the fullscreen app
            -- becomes attached automatically", and that early return is
            -- exactly the case that was failing: the newcomer was skipped
            -- before the incumbent was ever looked for, so fullscreen stayed
            -- and the popup opened underneath it.
            --
            -- Nothing else is lost by dropping it. The incumbent search below
            -- is what actually decides anything, and it still only acts on a
            -- window that is expanded on the ACTIVE workspace, so this cannot
            -- reach across desktops or disturb a window that was not
            -- fullscreen in the first place.
            local ws = newcomer.workspace
            if not ws or (ws.id or 0) < 1 then
                settled = true
                return -- special/hidden: not stealing the screen
            end
            local act = hl.get_active_workspace()
            if not act or act.id ~= ws.id then
                settled = true
                return -- background spawn on another workspace
            end
            -- Find the incumbent: another window, same workspace, expanded.
            --
            -- TWO PASSES, tiled first. The first is the original rule and is
            -- unchanged. The second is new and covers the case that made this
            -- look broken on the desktop where the fullscreen window is
            -- FLOATING rather than tiled.
            local incumbent = nil
            local incumbentFloating = false
            local incumbentCovered = false
            local wins = hl.get_windows() or {}
            for _, other in ipairs(wins) do
                if other.address ~= newcomer.address
                    and other.workspace and other.workspace.id == ws.id
                    and not other.floating
                    and not isDialogClass(other.class or other.initialClass)
                    and (isFullscreened(other) or cover.isCovering(other)) then
                    incumbent = other
                    break
                end
            end
            -- Second pass: a FLOATING window that is expanded AND actually
            -- covers the newcomer.
            --
            -- Why this needed adding, measured rather than guessed. With a
            -- floating incumbent, `fullscreen {action="unset"}` clears the
            -- flag and changes nothing else -- the window keeps its geometry,
            -- so a window that was full-screen-sized STAYS full-screen-sized.
            -- Observed on the live desktop: incumbent went fs=2 -> fs=0 in
            -- under half a second, and the terminal that had just opened was
            -- still 100% hidden behind it, because the incumbent's rect
            -- [0,0 1707x1067] still contained the newcomer's [6,51
            -- 1695x1010] entirely. The flag cleared; the screen did not change.
            -- A tiled incumbent never had this problem because unsetting
            -- returns it to its tiler slot, which is smaller than the screen
            -- by definition.
            --
            -- `coversCentre` rather than "is any floating fullscreen window on
            -- this workspace": a fullscreen window is by definition over the
            -- whole monitor, but two windows can share a workspace id across
            -- two monitors, and demoting the far monitor's window because
            -- something opened here would be exactly the kind of quiet
            -- misfire this file keeps warning about.
            if not incumbent then
                local function coversCentre(cover, target)
                    local ca, cs = cover.at, cover.size
                    local ta, ts = target.at, target.size
                    if not (ca and cs and ta and ts) then return false end
                    local cx = (ta.x or 0) + (ts.x or 0) / 2
                    local cy = (ta.y or 0) + (ts.y or 0) / 2
                    return cx >= (ca.x or 0) and cx <= (ca.x or 0) + (cs.x or 0)
                        and cy >= (ca.y or 0) and cy <= (ca.y or 0) + (cs.y or 0)
                end
                for _, other in ipairs(wins) do
                    if other.address ~= newcomer.address
                        and other.workspace and other.workspace.id == ws.id
                        and other.floating
                        and not isDialogClass(other.class or other.initialClass)
                        and (isFullscreened(other) or cover.isCovering(other))
                        and coversCentre(other, newcomer) then
                        incumbent = other
                        incumbentFloating = true
                        break
                    end
                end
            end
            if not incumbent then
                settled = true
                return -- the overwhelmingly common case
            end
            -- isFullscreened() also matches fullscreenClient, which the
            -- compositor does NOT clear on its own when a new window maps
            -- (see the note above on what native does and does not cover).
            -- A client that owns its own fullscreen -- a video player, a
            -- game, anything that toggles it internally rather than asking
            -- the compositor -- stays covering the screen after this hook
            -- has long since settled, and the app the user just opened is
            -- still invisible. That is the case this exists for.
            local mode = ((incumbent.fullscreen or 0) == 1) and "maximized" or "fullscreen"
            hl.dispatch(hl.dsp.focus({ window = incumbent }))
            if (incumbent.fullscreen or 0) == 0 and (incumbent.fullscreenClient or 0) == 0 then
                -- NEITHER fullscreen flag is set, so there is no fullscreen to
                -- unset -- the window is covering the screen as a COVER, which
                -- is what the four-finger swipe up and SUPER+F do.
                --
                -- This was the whole bug. "Fills the screen" (custom/cover.lua)
                -- deliberately never tells the app it is fullscreen: it floats
                -- the window and gives it the monitor's exact geometry, so a
                -- browser keeps its tab strip. fs stays 0 BY DESIGN. Every
                -- check in this hook was `isFullscreened()`, which is false for
                -- a cover, so a covered window was never even considered as an
                -- incumbent -- and an app opened behind one stayed behind it,
                -- invisibly, with no sign anything had happened.
                --
                -- cover.exit() is the only correct way back: it unfloats,
                -- restores the remembered geometry and hands the window to the
                -- tiler. A fullscreen unset here would have been a no-op.
                pcall(function() cover.exit(incumbent) end)
                incumbentCovered = true
            elseif (incumbent.fullscreen or 0) ~= 0 then
                hl.dispatch(hl.dsp.window.fullscreen({ mode = mode, action = "unset" }))
            else
                -- Client-owned: unset the CLIENT state, not the compositor's.
                -- Unsetting the wrong one is a no-op that leaves the window
                -- exactly as covered as before.
                hl.dispatch(hl.dsp.window.fullscreen_state({
                    internal = 0, client = 2, action = "unset"
                }))
            end
            -- A FLOATING incumbent needs the second half of the job: clearing
            -- the flag is not enough, because nothing resizes it. Shrink it to
            -- half the monitor and park it top-left, so the newcomer -- which
            -- the tiler has given the full width -- is visible down the right.
            --
            -- Done on a timer, not inline: the unsetting dispatch above is
            -- queued, so an immediate resize would be measured against the
            -- pre-unset geometry and would ask for half of the WRONG size.
            if incumbentFloating and not incumbentCovered then
                local ia = incumbent.at
                local isz = incumbent.size
                if ia and isz and (isz.x or 0) > 0 and (isz.y or 0) > 0 then
                    local targetW = math.max(MIN_SIDE_W, math.floor((isz.x or 0) * 0.5))
                    local targetH = math.max(MIN_SIDE_H, math.floor((isz.y or 0) * 0.62))
                    hl.timer(function()
                        pcall(function()
                            resizeTo(incumbent.address, targetW, targetH)
                        end)
                    end, { timeout = 90, type = "oneshot" })
                    -- AND focus the newcomer a second time, later.
                    --
                    -- The hand-back scheduled above runs at 60ms and is NOT
                    -- enough on this path: resizeTo has to focus its own
                    -- target first (every window dispatcher here is
                    -- focus-scoped) and only then resizes, across up to three
                    -- internal retries. That leaves focus parked on the
                    -- incumbent we just shrank -- exactly the failure the
                    -- hand-back exists to prevent, reintroduced one step
                    -- later. 420ms is past resizeTo's worst case with room to
                    -- spare, and re-focusing something already focused is
                    -- free.
                    hl.timer(function()
                        pcall(function()
                            local back = findWindow(addr)
                            if back then hl.dispatch(hl.dsp.focus({ window = back })) end
                        end)
                    end, { timeout = 420, type = "oneshot" })
                end
            end
            -- Hand focus back. The demote focuses the incumbent (every window
            -- dispatcher on this build is focus-scoped and silently drops
            -- otherwise), and leaving focus there would put the user on the
            -- app they were ALREADY looking at -- the reveal would work and
            -- the focus would still be wrong, which is worse than not doing
            -- it, because the newly opened app then looks focused but is not.
            --
            -- Marked in demotedFullscreen so the once-per-session sweep does
            -- not immediately re-demote it: the user may well fullscreen it
            -- again on purpose, and that decision has to stick.
            demotedFullscreen[incumbent.address] = true
            hl.timer(function()
                pcall(function()
                    local back = findWindow(addr)
                    if back then hl.dispatch(hl.dsp.focus({ window = back })) end
                end)
            end, { timeout = 60, type = "oneshot" })
            tracef("fullscreen: stepped aside for %s so %s is visible",
                tostring(incumbent.class), tostring(newcomer.class))
            settled = true
        end)
    end
    -- FIRST PASS SYNCHRONOUSLY, THEN A FEW TIMED TICKS. This ordering is the
    -- whole fix and the opposite of what this hook did first, which is worth
    -- recording because the symptom was identical either way.
    --
    -- MEASURED, and this is the part that was not obvious: Hyprland ALREADY
    -- unfullscreens existing windows when a new one maps on their workspace.
    -- Disabled this hook entirely and the demote still happened, with
    -- fullscreen dropping to 0 at roughly 300ms. The first version of this
    -- hook deferred its first look to a 90ms timer, by which time native had
    -- already done the job -- so the hook found no incumbent, settled, and
    -- its trace NEVER FIRED in any test. The behaviour looked correct and
    -- the code doing it was never exercised, which is the worst combination
    -- there is: it would have been deleted as redundant, and the client
    -- fullscreen case below would have shipped broken.
    --
    -- So: look NOW, at map time, while an expanded incumbent is still
    -- expanded. The timed retries after it are only for the case where the
    -- window is not in hl.get_windows() on the first pass, which is the
    -- normal first tick (measured, see above).
    step()
    if settled then return end
    local tries = 0
    local function retry()
        if settled then return end
        tries = tries + 1
        step()
        if not settled and tries < 6 then
            hl.timer(retry, { timeout = 60, type = "oneshot" })
        end
    end
    hl.timer(retry, { timeout = 60, type = "oneshot" })
end)

-- ═══ The file chooser must be a DIALOG, not a tile ═════════════════════
--
-- rules.lua gives org.hypr.Explorer.Picker a `float = true` rule, and the
-- comment above it explains why that alone is not enough: the catch-all
-- `float = false` RE-ASSERTS ITSELF after map-time state changes, so a
-- runtime float dispatch loses the race and the picker stays TILED.
--
-- That comment describes the working recipe as "this rule is the login-time
-- baseline, and the picker ALSO anchors itself live with address-targeted
-- dispatches" -- but that second half did not exist in this file. Only the
-- baseline did, so the picker arrived tiled, which is both reported bugs:
-- a fullscreen app lost its fullscreen, and an attached app reflowed for
-- about a second. This is that missing half.
--
-- Why a retry loop and not a single dispatch: the tiler applies its own
-- layout ~200ms after map on this build, and the catch-all re-asserts inside
-- that window. Floating once at map time is undone. Retrying for a short
-- while is the same technique the hook above uses, for the same reason.
--
-- Sized and placed from the FOCUSED MONITOR rather than the active one: the
-- dialog must land on the monitor the app that opened it is on. The
-- dispatcher's move() rejects expression strings, so the coordinates are
-- computed here.
--
-- Deliberately NO pin. A pinned window follows every desktop switch, which
-- is the "the chooser did not stay on the desktop I opened it on" report;
-- a floating window is already independent of the tiler and stays put.
hl.on("window.open", function(w)
    local addr = tostring(w)
    local tries = 0
    local function anchor()
        pcall(function()
            local live = nil
            for _, x in ipairs(hl.get_windows() or {}) do
                if tostring(x) == addr then live = x break end
            end
            if not live then return end
            if live.class ~= "org.hypr.Explorer.Picker" then return end
            local ws = live.workspace
            if not ws or (ws.id or 0) < 1 then return end

            -- SET, not "unset" -- and that is the whole fix for a picker
            -- that flickered between 780x560 and a full-height tile.
            --
            -- This used to say `action = "unset"` under a comment claiming
            -- that was the idempotent choice. It is the opposite: "unset"
            -- means REMOVE from floating, i.e. RE-ATTACH TO THE TILER. The
            -- picker was therefore being tiled by this hook 12 times, 60ms
            -- apart, while explorer.py's own `_hypr_anchor` was floating it
            -- 10 times, 180ms apart. Two loops, two opposite verbs, and the
            -- dialog visibly flipped: measured live at 780x560/floating ->
            -- 802x988/tiled -> 780x560/floating -> 802x988/tiled, settling
            -- only once this hook ran out of retries. That is the "glitches
            -- strongly" and "sizing off everywhere" report.
            --
            -- "set" is also the idempotent one here: floating an
            -- already-floating window is a no-op, whereas "unset" on a
            -- floating window always produces a visible re-tile.
            --
            -- FOCUS FIRST, then float with NO address. Measured on this build:
            -- `float({... , address=...})` is accepted and returns ok but
            -- does nothing. Focusing first and dispatching against the
            -- focused window works, and is the codebase's own idiom (see the
            -- demotion hook above and the four-finger-down close).
            hl.dispatch(hl.dsp.focus({ window = live }))
            -- FLOAT ONLY IF IT IS NOT ALREADY FLOATING.
            --
            -- `action = "set"` is NOT idempotent on this build. Measured on a
            -- live save dialog, dispatching it three times in a row:
            --
            --   before      floating=False size=[802, 988]
            --   after set #1 floating=True  size=[780, 560]
            --   after set #2 floating=False size=[791, 988]
            --   after set #3 floating=True  size=[780, 560]
            --
            -- It TOGGLES. So this line used to be the cause of the whole
            -- "glitches strongly / sizing off everywhere" report rather than
            -- the cure for it: every tick of the retry loop re-asserted
            -- float on a dialog that was already floating and pushed it
            -- straight back into the layout, and the next tick pulled it out
            -- again. That is the 780x560 <-> 802x988 flip, measured
            -- repeatedly on real opens, and it is why the dialog could not
            -- settle no matter how long the loop watched.
            --
            -- The codebase already had the answer and this hook had been
            -- ignoring it: setFloat() at the top of this file guards on
            -- `isFloating(addr) == on` for exactly this reason, and the
            -- "only if it is still floating" check before the unset at the
            -- end of the swipe-to-tile gesture is the same idea.
            if not live.floating then
                hl.dispatch(hl.dsp.window.float({ action = "set" }))
            end

            -- ACT ONLY WHEN WRONG.
            --
            -- The resize/move below used to run on EVERY tick, unconditionally,
            -- for as long as the loop lasted. Each one is a forced relayout of
            -- the chooser's grid and sidebar, so a dialog that was already
            -- correct was still being re-laid-out a dozen times in the first
            -- second -- the shimmer that made the panel look like it was
            -- "sizing off everywhere" even in the frames where its geometry
            -- was right. Geometry is read BEFORE dispatching and the whole
            -- block is skipped when it already matches.
            local sz0 = live.size
            local at0 = live.at
            local want_w, want_h, margin = 780, 560, 24
            -- Where it SHOULD be: size, and the top-right anchor.
            local mon0 = live.monitor
            local already_right = false
            if sz0 and at0 and mon0 then
                local sc0 = mon0.scale or 1
                if sc0 <= 0 then sc0 = 1 end
                local mw0 = math.floor((mon0.width or 1920) / sc0 + 0.5)
                local want_x = (mon0.x or 0) + mw0 - want_w - margin
                already_right = math.abs((sz0.x or 0) - want_w) < 6
                    and math.abs((sz0.y or 0) - want_h) < 6
                    and math.abs((at0.x or 0) - want_x) < 6
                    and math.abs((at0.y or 0) - ((mon0.y or 0) + margin)) < 6
            end

            -- Size and place it as well, anchored to the TOP-RIGHT of the
            -- monitor the opening app is on. The rules.lua `size` is applied
            -- by the same map-time state change the catch-all overrides, so
            -- it is lost in exactly the same way the float is -- the dialog
            -- needs its geometry given live too.
            --
            -- Coordinates are computed HERE because move() rejects expression
            -- strings. Monitors report PHYSICAL width/height while the
            -- geometry dispatchers work in LOGICAL units, so the scale is
            -- divided out: using the raw numbers puts the dialog at roughly
            -- twice the intended offset on a scaled display.
            local mon = live.monitor
            if mon and not already_right then
                local mscale = (mon.scale or 1)
                if mscale <= 0 then mscale = 1 end
                local mw = math.floor((mon.width or 1920) / mscale + 0.5)
                local mh = math.floor((mon.height or 1080) / mscale + 0.5)
                local dw, dh = 780, 560
                -- Clamp, so a small monitor cannot push the dialog off-screen
                -- -- which reads as "the chooser never opened".
                if dw > mw - 40 then dw = mw - 40 end
                if dh > mh - 40 then dh = mh - 40 end
                -- No `address` on either: same measured reason as the float
                -- above -- these act on the focused window, which is the
                -- picker we just focused.
                hl.dispatch(hl.dsp.window.resize({ x = dw, y = dh }))
                hl.dispatch(hl.dsp.window.move({
                    x = (mon.x or 0) + mw - dw - margin,
                    y = (mon.y or 0) + margin,
                }))
            end
            -- WATCH LONGER THAN YOU ACT -- the same distinction explorer.py's
            -- _hypr_anchor makes, and for the same reason.
            --
            -- Acting is conditional (the dispatches above run only when the
            -- window is real, and resize/move only matter when the geometry
            -- is off), but WATCHING is not conditional on being right: the
            -- catch-all `float = false` re-asserts ~200ms after map, so a
            -- loop that returns the first time it sees a correct 780x560
            -- float stops BEFORE the re-assert and leaves the dialog tiled
            -- at 802x988. The floor below is what keeps it watching through
            -- that window; without it, speeding the first tick up made the
            -- dialog end up TILED on three of five measured opens.
            local sz = live.size
            local geom_ok = live.floating and already_right
            tries = tries + 1
            if geom_ok and tries >= 12 then return end
            if tries >= 24 then return end
            -- Fast ticks through the vulnerable window, then a slower tail.
            -- Ten 12ms retries cover the ~200ms the tiler needs to
            -- re-assert; the geometric check means none of them re-lay-out
            -- a dialog that is already right.
            local delay = tries < 10 and 12 or 60
            hl.timer(anchor, { timeout = delay, type = "oneshot" })
        end)
    end
    -- 1ms, not 10ms and not the 40ms this used to be. The catch-all in
    -- rules.lua has ALREADY stretched the window into the layout by the time
    -- a 40ms timer runs -- the comment on the second window.open hook below
    -- records that measurement (40ms produced a full-size window, 1ms
    -- produced the correct one), and the same race applies here with the
    -- same answer. The loop's later ticks are the ones that fight the
    -- re-assert; this first one is the one that gets in before the tiler has
    -- sized the dialog.
    hl.timer(anchor, { timeout = 1, type = "oneshot" })
end)

-- ═══ An app's SECOND window is a popup; the app itself stays attached ════
--
-- The catch-all in rules.lua attaches EVERY window to the tiler. That is
-- right for applications and wrong for the dialogs an application opens: a
-- GTK "Preferences" window or an Electron "About" box is sized by its parent
-- and is unusable stretched across the screen. rules.lua could only fix that
-- with a list of dialog TITLES, and a list is always one release behind --
-- which is why "that dialog opened fullscreen" kept coming back.
--
-- Hyprland gives rules no way to ask "is this window transient for another":
-- xdg popups are not toplevels at all, and transient-for is not exposed to
-- the config. So the test here STARTS from the one thing a dialog always is
-- and an application window never is: IT IS NOT THE FIRST WINDOW OF ITS
-- APP -- and that used to be the whole test, which is why a private browser
-- window and a keybind-opened terminal floated. It is now the first gate of
-- a three-signal verdict (class, title, size); see "The middle ground"
-- below for the rest and for why the sibling test cannot stand alone.
--
-- Deliberately NOT applied to:
--   * the shell's own windows (settings, the task manager, the files app) --
--     they are chrome, not popups. The launcher's search bar, the tray menu
--     and every other panel the shell draws are LAYER surfaces, so they are
--     not toplevels and can never reach this code at all;
--   * the Explorer and its picker -- they carry their own geometry rules and
--     their own live hook above;
--   * portals and polkit agents -- already floated by rules.lua, and their
--     size is dictated by the portal that asked for them.
local popupExempt = {
    ["quickshell"] = true,
    ["org.hypr.Explorer"] = true,
    ["org.hypr.Explorer.Picker"] = true,
}

local function popupExemptClass(cls)
    if popupExempt[cls] then return true end
    if not cls then return true end
    local lower = string.lower(cls)
    if string.find(lower, "portal", 1, true) then return true end
    if string.find(lower, "polkit", 1, true) then return true end
    return false
end

-- ═══ Per-app popup handling: the settings switch ═════════════════════
--
-- The classifier above has no off switch: for every app it decides that a
-- second window is a popup. That is right often enough that it should stay
-- the default, and wrong for the apps whose "second window" is a real
-- application window -- TradingView among them.
--
-- The exceptions are owned by the shell (Settings -> Apps), which writes one
-- app class per line to a file in the cache. This side only reads it.
--
-- WHY A FILE: the classifier runs on every window open, and asking the shell
-- over IPC would spawn a `qs` process each time -- tens of milliseconds on
-- the critical path of a window appearing.
--
-- WHY THE FILE LISTS THE EXCEPTIONS: a missing or empty file has to mean
-- "everything behaves as it always has", because the shell may not be
-- running and the cache may have been cleared. If the file listed the
-- inventory instead, those two states would silently mean "nothing floats",
-- which is the one outcome a user cannot diagnose from the symptom.
--
-- Read at most every POPUP_OFF_TTL seconds. The same window is judged
-- several times (the rule re-asserts on later ticks to fight the tiler), and
-- re-opening the file on each of those is the sort of thing that turns a
-- 1ms rule back into a slow one.
local POPUP_OFF_PATH = ((os.getenv("XDG_CACHE_HOME")
    or ((os.getenv("HOME") or "/tmp") .. "/.cache")) .. "/quickshell/popup-handling-off.txt")
local POPUP_OFF_TTL = 2

local popupOffCache = nil
local popupOffReadAt = 0

-- True when the shell has switched popup handling OFF for this app, i.e.
-- every window of it attaches to the tiler like a first window does.
local function popupHandlingOff(cls)
    if not cls then return false end
    local now = os.time()
    if popupOffCache == nil or (now - popupOffReadAt) >= POPUP_OFF_TTL then
        local set = {}
        local f = io.open(POPUP_OFF_PATH, "r")
        if f then
            for line in f:lines() do
                local c = line:gsub("^%s+", ""):gsub("%s+$", "")
                -- Lower-cased on both sides: Hyprland's class and the shell's
                -- app id are the same string in practice, but not reliably
                -- the same case, and a switch that silently does nothing
                -- because of a capital letter is indistinguishable from a
                -- switch that does not work.
                if c ~= "" then set[string.lower(c)] = true end
            end
            f:close()
        end
        popupOffCache = set
        popupOffReadAt = now
    end
    return popupOffCache[string.lower(cls)] == true
end

-- ═══ An app's SECOND window: popup or real window? ═══════════════════
--
-- THE HISTORY, because the symptom looked like something else. The rule
-- here used to be the sibling test ALONE:
--
--     if siblingsOfClass(liveCls, addr) >= 1 then float + centre end
--
-- and it read on the desktop as "any window not opened from the menu
-- floats". Being precise about this matters because the fix depends on it:
-- the sibling test counts OTHER toplevels of the same class. A window
-- opened from the LAUNCHER is normally its app's FIRST window, so 0
-- siblings, so it tiled. A window opened from INSIDE a running app -- the
-- browser's own File > New Private Window, a keybind opening a terminal
-- while a terminal is already running -- is that app's SECOND window, so
-- 1 sibling, so it floated. The launcher was never tested; what was
-- actually being tested was the window's POSITION IN THE APP'S HISTORY.
--
-- ═══ The middle ground: POPUP or APPLICATION ═══════════════════════════
--
-- REQUESTED (2026-09-30): "any window not opened from the menu floats" is
-- wrong in three named ways. The sibling test below cannot tell a dialog
-- from a second REAL window, because both are "a window of an app that
-- already had one":
--
--   * a private/incognito browser window opened from the browser's own
--     menu -- a full application window, and it must be ATTACHED;
--   * a terminal opened from a keybind while a terminal is already running
--     -- also an application window, and it must be ATTACHED;
--   * a temporary verification window -- captcha/anti-bot popups, the
--     screen-share chooser, permission/certificate/print dialogs -- which
--     must FLOAT, because it is sized by its parent and is unusable
--     stretched across the screen.
--
-- So "second window" stops being the answer on its own and becomes one of
-- three signals, in this order:
--
--   1. CLASS. Terminals and browsers are APPLICATION windows; every window
--      of those classes is attached unless it is recognisably a popup (2)
--      or recognisably small (3). This is what makes the private window
--      tile without having to detect "private" at all -- there is nothing
--      to detect, the window is simply never a popup candidate.
--   2. TITLE. The dialog wordings the popups actually use ("Print",
--      "Permission Request", "Verifying you are human", "Choose what to
--      share"). Deliberately the exact dialog phrasing, never a word like
--      "Permission" or "Certificate" on its own -- a web page titled
--      "Permissions" must not turn its browser window into a popup.
--   3. SIZE. The app's OWN requested geometry, read on the first tick
--      where the window exists and before the tiler has stretched it. Small
--      (< 62% of the work area in both directions) = popup. This is the
--      generic fallback: it covers captcha windows whose title we do not
--      recognise, and it is why an unknown app's second window is only
--      floated when it is actually small.
--
-- Anything else -- a second window that arrived at (or near) full size --
-- is an application window and stays attached. That is the answer for
-- every private browser window, whatever it is titled.
local TERMINAL_CLASSES = {
    -- A terminal's second window is ALWAYS an application window: a
    -- keybind-opened kitty while kitty is already running is the worked
    -- example, and it used to float loose on top of the desktop every
    -- single time. There is no kitty dialog to catch, so these are exempt
    -- from the popup test outright rather than merely unlikely.
    ["kitty"] = true,
    ["kitty-icbns"] = true,
    ["foot"] = true,
    ["footclient"] = true,
    ["alacritty"] = true,
    ["Alacritty"] = true,
    ["ghostty"] = true,
    ["wezterm"] = true,
    ["wezterm-gui"] = true,
    ["konsole"] = true,
    ["gnome-terminal"] = true,
    ["gnome-terminal-server"] = true,
    ["org.gnome.Console"] = true,
    ["xterm"] = true,
    ["XTerm"] = true,
    ["st"] = true,
    ["contour"] = true,
    ["rio"] = true,
}

-- Browsers. Every browser window is attached -- normal, private and
-- incognito alike -- so nothing here has to detect "private" at all; the
-- private window simply never becomes a popup candidate. The popups these
-- apps open are recovered by the title patterns or by arriving small.
local BROWSER_CLASSES = {
    ["brave-browser"] = true,
    ["brave"] = true,
    ["firefox"] = true,
    ["firefox-esr"] = true,
    ["firefoxdeveloperedition"] = true,
    ["org.mozilla.firefox"] = true,
    ["chromium"] = true,
    ["chromium-browser"] = true,
    ["google-chrome"] = true,
    ["google-chrome-stable"] = true,
    ["vivaldi-stable"] = true,
    ["opera"] = true,
}

-- The wordings a popup actually arrives with. Patterns, not plain words:
-- a rule (or this hook) that matches "Permission" also matches a web page
-- titled "Permissions", and would float that page's browser window.
local POPUP_TITLE_PATTERNS = {
    "^Print$",
    "^Print%.%.%.$",
    "^Print Preview",
    "^Page Setup$",
    "^Certificate Viewer",
    "^View Certificate",
    "^Site Information",
    "^Permission Request",
    "^Firefox is requesting",
    -- Lua patterns have no alternation: `|` is a literal character, so
    -- "wants to (open|save)" would never match the real title
    -- "brave.com wants to open" -- it would match the literal text
    -- "wants to (open|save)" and float nothing. One pattern per verb.
    "wants to open",
    "wants to save",
    "wants to connect",
    "^Verifying you are human",
    "^Just a moment",
    "^Attention Required",
    "^Checking your browser",
    "^Are you a robot",
    "^Verify (that )?you are",
    "^Choose what to share",
    "^Select a window to share",
    "^Select a Window or Screen to Share",
    "^Share your (screen|window)",
    "^Sharing your (screen|window)",
    "^Screen(sharing| Sharing) ",
    "^Capture your screen",
    "^Choose a Window",
}

local function isPopupTitle(title)
    if not title or title == "" then return false end
    for _, pat in ipairs(POPUP_TITLE_PATTERNS) do
        if string.match(title, pat) then return true end
    end
    return false
end

-- Is this window's OWN geometry small enough to be a dialog?
--
-- Read on the first tick where the window exists. That matters: by the time
-- the tiler has finished (about 200ms after map on this build) EVERY new
-- window is stretched to the whole layout, and the test would then read
-- "big" for every window including the popups it exists to catch. The first
-- observation is the app's own request.
local function isPopupSized(live, frac)
    local mon = live.monitor
    local size = live.size
    if not mon or not size then return nil end -- unknown yet: ask again
    local mscale = mon.scale or 1
    if mscale <= 0 then mscale = 1 end
    local mw = math.floor((mon.width or 1920) / mscale + 0.5)
    local mh = math.floor((mon.height or 1080) / mscale + 0.5)
    local ww = size.x or mw
    local wh = size.y or mh
    if ww <= 0 or wh <= 0 then return nil end
    frac = frac or 0.62
    return (ww < mw * frac) and (wh < mh * frac)
end

-- How many OTHER toplevels of this class are mapped. Counted across desktops
-- on purpose: an app with a window on desktop 1 that opens another window on
-- desktop 3 is still an app that already had a window.
--
-- Addresses are compared RAW, never through tostring(): findWindow() (and so
-- setFloat, isFloating and focusAddr) compares w.address for EQUALITY, so a
-- stringified address silently fails every lookup -- which is exactly how this
-- rule managed to run, match its own class, and still do nothing at all.
local function siblingsOfClass(cls, addr)
    local n = 0
    for _, x in ipairs(hl.get_windows() or {}) do
        if x.address ~= addr then
            local c = x.class or x.initialClass
            if c == cls then n = n + 1 end
        end
    end
    return n
end

-- Put the dialog at a size you can actually use, centred on the monitor the
-- opening app is on.
--
-- The 1ms first tick wins that race MOST of the time but not always: the
-- catch-all in rules.lua stretches a new window to the whole layout at map
-- time, and when that lands first the dialog comes up 1600x1000 -- which is
-- the exact "that dialog opened fullscreen" report this rule exists to
-- remove. So the outcome is made deterministic rather than left to the
-- scheduler: a window that came out the size of the entire layout is put
-- back to something dialog-shaped, and one that kept its own size is left
-- strictly alone.
--
-- Logical units throughout, so the monitor scale comes out first -- the same
-- correction the Explorer hook makes. resize/move act on the FOCUSED window,
-- which is the one setFloat just focused.
local function placeDialog(addr)
    -- Re-fetched by address, NOT taken from the window object the open event
    -- handed over: that one is a snapshot from map time, when the window was
    -- still small, so the "is this stretched to the whole layout?" test read
    -- stale and never fired.
    local live = findWindow(addr)
    if not live then return end
    local mon = live.monitor
    if not mon then return end
    local mscale = mon.scale or 1
    if mscale <= 0 then mscale = 1 end
    local mw = math.floor((mon.width or 1920) / mscale + 0.5)
    local mh = math.floor((mon.height or 1080) / mscale + 0.5)
    local size = live.size or {}
    local ww = size.x or mw
    local wh = size.y or mh

    -- resize/move act on the FOCUSED window, and by the time this runs the
    -- focus is not reliably still ours: the float above was three dispatches
    -- ago and anything on screen can have taken it. Measured -- without this
    -- the resize was dispatched and simply landed on another window, which is
    -- why a stretched dialog stayed 1600x1000 while the code claimed to have
    -- fixed it. Claim the window first, then place it.
    hl.dispatch(hl.dsp.focus({ window = live }))

    if ww >= mw * 0.95 and wh >= mh * 0.95 then
        ww = math.max(320, math.floor(mw * 0.55))
        wh = math.max(240, math.floor(mh * 0.55))
        hl.dispatch(hl.dsp.window.resize({ x = ww, y = wh }))
    end

    hl.dispatch(hl.dsp.window.move({
        x = (mon.x or 0) + math.floor((mw - ww) / 2),
        y = (mon.y or 0) + math.floor((mh - wh) / 2),
    }))
end

hl.on("window.open", function(w)
    local addr = w.address
    local cls = w.class or w.initialClass
    if addr == nil or popupExemptClass(cls) then return end
    -- The app has popup handling switched off in the shell's settings: do
    -- nothing at all for this window, rather than judging it and then
    -- ignoring the verdict. Cheapest place for the check and the only one
    -- that leaves the window entirely alone.
    if popupHandlingOff(cls) then return end

    -- Every exit re-arms the timer, because the window is NOT in
    -- hl.get_windows() when this event fires. Measured: at `window.open`
    -- findWindow() returns nil while siblingsOfClass() already sees the
    -- other two windows of the same app. Returning on a nil window is
    -- therefore not "nothing to do" -- it is the normal first tick, and it
    -- is what silently disabled this whole rule until it was logged.
    --
    -- The FIRST tick is 1ms, not the 40ms the Explorer hook above uses, and
    -- that difference is the whole point. The catch-all in rules.lua has
    -- already stretched the window to the full layout by the time a 40ms
    -- timer runs: measured on the same app, a 40ms first tick produced a
    -- 1600x1000 floating window (the app's own 805x505 lost), while 1ms
    -- produced 805x505 centred. A dialog that opens at screen size is the
    -- exact failure this rule exists to remove, so the window has to be
    -- pulled out of the tiler before the tiler has sized it. The later ticks
    -- stay at 60ms and are only there to fight the re-assert afterwards.
    -- `decided` is the whole shape of the fix. The verdict is taken ONCE,
    -- from the first tick where the window exists, and then held: a later
    -- tick would read the tiler's stretched geometry instead of the app's
    -- own, so re-deciding every 60ms would quietly turn "small popup" into
    -- "full-size window" and stop floating anything.
    local decided = nil
    local tries = 0
    local function judge(live, liveCls)
        if popupExemptClass(liveCls) then return false end
        -- Same switch, re-read on the judge path too: `window.open` is not
        -- the only way a window reaches here, and a class that turned the
        -- switch off between the event and the first tick must still be
        -- honoured.
        if popupHandlingOff(liveCls) then return false end
        -- "Not the first window of its app" stays the gate for EVERYTHING,
        -- including the title match: an app's own first window is an
        -- application window by definition, and a browser launched from the
        -- bar is as likely to come up small as it is to come up maximised.
        -- Only a window opened BY an already-running app is a popup
        -- candidate at all.
        if siblingsOfClass(liveCls, addr) < 1 then return false end
        -- A terminal's own popup still gets the title test (a terminal
        -- asking to open a file must float), but never the size test.
        if isPopupTitle(live.title) then return true end
        if TERMINAL_CLASSES[liveCls] then return false end
        -- BROWSERS: the title is the ONLY evidence, with no size net under
        -- it. This replaces a stricter size test (50% rather than 62%, i.e.
        -- under 800x500 on this 1600x1000 logical work area) whose stated
        -- reason was exactly this case -- and that reasoning was wrong.
        --
        -- A private/incognito window is by definition opened BY another
        -- window of the same app, so it always clears the siblings gate
        -- above and is always a popup candidate. Chromium does not give it a
        -- fresh default size either: it INHERITS the opening window's. So a
        -- private window's size tracks the size of the window that spawned
        -- it -- which is precisely the quantity the test was deciding on.
        -- Start Brave at half the screen and every private window arrives
        -- under the threshold and floats. Size cannot separate "private
        -- window that inherited a small size" from "real popup that is
        -- genuinely small", because they are literally the same size.
        --
        -- The title does separate them. Every genuine Chromium popup
        -- announces itself -- Print, Certificate Viewer, Site Information,
        -- Permission Request, "wants to open", "Verifying you are human",
        -- the screen-share prompts -- all in POPUP_TITLE_PATTERNS, and
        -- isPopupTitle() has already run by the time we get here. A private
        -- window carries the PAGE title, which matches none of them.
        --
        -- The trade is deliberate and its failure mode is the better one: a
        -- Chromium dialog whose title is missing from the list will now
        -- ATTACH instead of floating. That is a visible mistake with a
        -- one-word fix (add the pattern above), which beats silently
        -- mis-classifying every private window the user opens.
        if BROWSER_CLASSES[liveCls] then return false end
        local small = isPopupSized(live, 0.62)
        if small == nil then return nil end
        return small
    end
    local function floatIfPopup()
        if tries >= 12 then return end
        tries = tries + 1
        pcall(function()
            local live = findWindow(addr)
            if live then
                if decided == nil then
                    -- Re-read the class: some toolkits set a better one
                    -- after map.
                    local liveCls = live.class or live.initialClass or cls
                    -- ONLY a real verdict is stored. judge() returns nil to
                    -- mean "the geometry has not landed yet, ask again", and
                    -- `judge(...) or false` -- which is what this said --
                    -- turns that nil into a PERMANENT false on the very
                    -- first tick. A popup whose size was not readable yet
                    -- was then denied for the rest of the retry loop and
                    -- arrived tiled. Measured on this machine: a 520x380
                    -- second browser window came up as a 791x469 half-tile
                    -- instead of floating, which is the dialog behaviour
                    -- this hook exists to prevent.
                    local verdict = judge(live, liveCls)
                    if verdict ~= nil then decided = verdict end
                end
                if decided then
                    -- setFloat, not a bare dispatch: it VERIFIES w.floating
                    -- afterwards, so a lost race is retried, not believed.
                    if setFloat(addr, true) and isFloating(addr) then
                        placeDialog(addr)
                    end
                end
            end
            hl.timer(floatIfPopup, { timeout = 60, type = "oneshot" })
        end)
    end
    hl.timer(floatIfPopup, { timeout = 1, type = "oneshot" })
end)

-- ═══ Why there is no "re-anchor what is already open" sweep ══════════════
--
-- The request was to anchor the apps already on screen as well as the new
-- ones. Window rules apply when a window MAPS, so a reload cannot re-apply
-- them -- and on this build there is no runtime way to do it by hand either.
-- Measured, all four attempts against a live floating window, each one
-- checked through w.floating afterwards:
--
--     float({ action = "unset", address = addr })   floating stays true
--     focus(addr) + float({ action = "unset" })     floating stays true
--     float({ action = "toggle", address = addr })  floating stays true
--     focus(addr) + float({ action = "toggle" })    floating stays true
--
-- Floating ON works at runtime (`action = "set"` -- that is how the popup
-- rule above floats a dialog), but nothing puts a window BACK. There is no
-- hl.dsp.tiler.* and no window.settiled in this build's Lua API, and the
-- tiler only inserts a window at map time. So a sweep here would be dead
-- code that looks like it works: it would dispatch on every reload, change
-- nothing, and quietly cost a focus steal each time.
--
-- Nothing is lost in practice. The attaching half of the request was ALREADY
-- true and always was: rules.lua's catch-all (`class = ".*"` -> float = false)
-- attaches every application, settings, the task manager and the files app
-- included, and it is a login-time baseline rather than something that has to
-- be re-applied. The only genuinely new behaviour is the one above -- an app's
-- dialogs float -- and that is inherently a map-time event.
--
-- …except for the apps in SELF_FLOATING below, which is what the note above
-- gets wrong, and the correction is worth recording because it contradicts
-- a measurement taken here earlier in the session.

-- ═══ Apps that ask to float AFTER the rules have run ═══════════════════
--
-- A window rule is applied at MAP time. Discord does not map floating, so
-- the catch-all (`class = ".*"` -> float = false) attaches it correctly --
-- and then Electron asks for a floating window with its remembered
-- geometry a moment later, and that request is not a map, so no rule sees
-- it. Measured on this machine, a cold `discord` start:
--
--     flt True   at [159, -214]   size [1282, 1427]
--
-- A 1282x1427 window at a NEGATIVE y on a 943px-tall work area: it is
-- bigger than the screen, hanging off the top, loose on top of the layout.
-- That is the "discord opens as a popup, not attached" report, and the
-- catch-all is powerless against it by construction.
--
-- The fix is the one the tray's restore already uses: focus the window,
-- then `float unset`, then READ IT BACK. The note above claims that
-- nothing puts a window back into the tiler at runtime, and that was true
-- of the four forms it tried -- all of which either passed an address the
-- dispatcher ignores or toggled instead of setting. Focus-then-set with
-- verification is a different thing, and it is verified working: the
-- Thunderbird park/restore round trip goes `floating: true` ->
-- `floating: false` through exactly that sequence (see `show()` in
-- services/TrayApps.qml).
--
-- An explicit list, not a general "un-float everything that floats": the
-- dialogs that are MEANT to float (the popup rule above, the file chooser,
-- the polkit agents, a screen recorder's preview) are all floating for a
-- reason, and a general sweep would take them all down with it. Each entry
-- here is an app measured to arrive floating with a broken geometry.
local SELF_FLOATING = {
    ["discord"] = true,
}

-- ═══ Launched from the shell's launcher? Then it ATTACHES. ═════════════
--
-- The rule this implements, in one line: an application you start from the
-- SUPER menu is an application you are going to WORK IN, so it goes into
-- the layout. A popup is a thing that arrives on its own and leaves again.
-- The user's words for it: apps they actively work on attach, temporary
-- popups fired by a browser or something else do not.
--
-- WHY THIS IS NOT A WINDOW RULE
-- ------------------------------
-- Because a window rule can only see class, title and geometry, and none of
-- those carry launch origin. The same app launched two ways is the same
-- window: Bitwarden from the Brave extension (a small utility panel, wants
-- to float) and Bitwarden from SUPER (an app you will use for a while,
-- wants to attach) are byte-identical from the compositor's point of view.
-- No static rule can separate them.
--
-- The compositor CAN see it, though, because the launcher stamps it. Every
-- app the shell starts goes through scripts/launch/open.sh, which runs it as
--
--     env II_OPENED_BY_II=1 bash -c "<command>"
--
-- and that variable is inherited by the app and by everything it spawns --
-- which is the part that makes this work for Chromium and Electron apps,
-- since they all re-exec themselves and the WINDOW belongs to a grandchild.
-- open.sh documents that inheritance as the reason its own error reporting
-- is reliable; here it is read from the other end.
--
-- So the launch origin is recovered from the window's own process:
--
--     HL.Window.pid  ->  /proc/<pid>/environ  ->  II_OPENED_BY_II=1
--
-- `pid` is a field on HL.Window on this build (checked against
-- /usr/share/hypr/stubs/hl.meta.lua), and /proc/<pid>/environ is readable
-- for a process the compositor is already managing as this user.
--
-- WHY A PID REGISTRY, NOT THE ENVIRONMENT STAMP
-- ----------------------------------------------
-- The obvious way to tell "launched by SUPER" from "launched by something
-- else" is the variable open.sh already sets: every app the shell starts
-- runs as `env II_OPENED_BY_II=1 ...`, and that is inherited all the way
-- down. So the compositor could read the window's own process environment.
--
-- MEASURED, AND IT DOES NOT WORK for exactly the apps that matter:
--
--     window pid : 1375421  comm=electron
--     /proc/1375421/environ -> Permission denied
--
-- Chromium and Electron deliberately clear their own dumpable flag at
-- startup, which is what makes /proc/<pid>/environ root-owned and
-- unreadable. The window belongs to the renderer, not to the shell that
-- started it. Walking UP the process tree does not rescue it either: the
-- intermediate processes were exec'd away, so the pid that carried the
-- variable IS the electron process, and it is the one process that cannot be
-- read. Every Chromium-family app -- Bitwarden, Brave, Discord, VS Code,
-- Freebuff -- hits this, so the stamp is useless precisely where the rule
-- is needed.
--
-- A PID REGISTRY has none of that problem. ppid comes from /proc/<pid>/stat
-- and is readable whatever the dumpable flag says, and open.sh knows the
-- pid of the process it started. So the launcher writes that pid down, and
-- the sweep walks up from the window's pid until it hits a recorded one.
--
-- open.sh appends "<pid> <unix-seconds>" and prunes anything older than
-- LAUNCH_WINDOW seconds on every launch, so the file stays a few lines long
-- and a stale entry cannot attach something the user opened by hand much
-- later.
--
-- WHY IT OVERRIDES THE FLOAT RULES
-- --------------------------------
-- This runs in the sweep, AFTER the window rules, and it uses the same
-- focus-then-`float unset`-and-read-back that SELF_FLOATING above already
-- uses and that is verified working. That ordering is the whole point: the
-- Bitwarden rule in rules.lua floats Bitwarden so the extension's copy stops
-- grabbing the whole workspace, and this pass puts the SUPER-launched copy
-- back into the layout one second later. Both halves of "Bitwarden floats
-- from the extension, attaches from SUPER" therefore hold at the same time,
-- which no single rule can express.
--
-- Dialogs are still exempt. `isDialogClass` is checked first on purpose: an
-- app opened from SUPER can still open a genuine dialog afterwards, and a
-- dialog that snapped into the layout would be the same class of wrong the
-- popup engine above exists to prevent.
local LAUNCH_REGISTRY = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/ii-super-launched"
-- Long enough for a slow app (an AppImage unpacking itself, an Electron
-- cold start on a spinning disk -- Bitwarden took over 4s to map), short
-- enough that it cannot claim a window the user opened by hand much later.
local LAUNCH_WINDOW = 45

local function recentLauncherPids()
    local now = os.time()
    local set = {}
    local fh = io.open(LAUNCH_REGISTRY, "r")
    if not fh then return set end
    for line in fh:lines() do
        local pid, ts = string.match(line, "^(%d+)%s+(%d+)$")
        if pid and ts and (now - tonumber(ts)) <= LAUNCH_WINDOW then
            set[tonumber(pid)] = true
        end
    end
    fh:close()
    return set
end

local function launchedByLauncher(win, pids)
    if not pids or next(pids) == nil then return false end
    local pid = win and win.pid
    if not pid or pid <= 0 then return false end
    -- Up the tree, not just the window's own pid: the launcher starts a
    -- wrapper which may fork the real binary, and it is the WRAPPER's pid
    -- that got recorded. Bounded, because ppid is not guaranteed to
    -- terminate and a cycle must not hang the sweep.
    local seen = {}
    for _ = 1, 12 do
        if not pid or pid <= 1 or seen[pid] then return false end
        seen[pid] = true
        if pids[pid] then return true end
        local fh = io.open("/proc/" .. tostring(pid) .. "/stat", "r")
        if not fh then return false end
        local stat = fh:read("*a")
        fh:close()
        -- The ppid is field 4, and the comm field (2) is parenthesised and
        -- may itself contain spaces or parentheses, so the scan starts after
        -- the LAST ')' rather than splitting on whitespace.
        local close = stat and stat:find("%)[^%)]*$")
        if not close then return false end
        local rest = stat:match("^.*%)%s+(%d+)")
        pid = rest and tonumber(rest) or nil
    end
    return false
end

-- THE TRIGGER IS A SWEEP, NOT THE EVENT, and that is measured rather than
-- preferred. `hl.on("window.open", ...)` never fires for this window: a
-- zenity window logs the hook immediately, and a cold `discord` start logs
-- NOTHING at all -- not the hook, not the fullscreen-demote hook above,
-- nothing. So an event-driven rule is not "late" here, it is blind, and
-- any amount of retrying inside the callback would have been retrying in a
-- function that is never called.
--
-- The sweep is one pass over the window list per second, and it only does
-- anything when an app on the list is actually floating. The cost of the
-- idle case is reading a list of a dozen objects once a second; the cost
-- of the busy case is one focus and one float dispatch, which is what
-- attaching a window costs anyway.
local function attachSweep()
    -- Read the registry ONCE per pass, not once per window: it is a file
    -- read, and doing it per window would be the only I/O in the sweep.
    local pids = nil
    pcall(function()
        pids = recentLauncherPids()
        local seen = {}
        for _, win in ipairs(hl.get_windows() or {}) do
            local cls = win.class or win.initialClass
            seen[win.address or ""] = true
            if cls and not isDialogClass(cls) then
                -- Two states a window of ours must not arrive in: floating
                -- with broken geometry (un-float it) or fullscreen (demote
                -- it, ONCE). Everything else is left as it arrived -- a
                -- popup, a file chooser, a polkit agent, a recorder's
                -- preview all float or fullscreen on purpose.
                local wants = SELF_FLOATING[cls] or launchedByLauncher(win, pids)
                if wants and win.address then
                    if win.floating then
                        -- setFloat focuses the window FIRST (the float
                        -- dispatcher is focus-scoped on this build) and only
                        -- reports success once it has read the window back,
                        -- so a lost dispatch is retried on the next pass
                        -- rather than believed.
                        setFloat(win.address, false)
                    elseif isFullscreened(win) and not demotedFullscreen[win.address] then
                        demoteFullscreen(win.address)
                    end
                end
            end
        end
        -- Prune the demote markers of windows that are gone, so the table
        -- cannot grow across a long session (a relaunched app must be
        -- demotable again, too).
        for addr in pairs(demotedFullscreen) do
            if not seen[addr] then demotedFullscreen[addr] = nil end
        end
    end)
    hl.timer(attachSweep, { timeout = 1000, type = "oneshot" })
end
hl.timer(attachSweep, { timeout = 1000, type = "oneshot" })
-- ═══ The tray guard is gone too ══════════════════════════════════════
--
-- The second half of the removed mechanism: the 150ms sweep that watched
-- every window on the desktop and pulled close-to-tray apps off it, the
-- release-permit file it honoured, and the `offDesktop` predicate. None of
-- it has a reason to exist now that there is no per-app tray behaviour, and
-- all of it was I/O on a timer, forever, for a feature that is gone.

-- ═══ Restacking a row into a column: MEASURED, and it is one-sided ═══════
--
-- CORRECTION (2026-10-02). An earlier version of this file, and earlier
-- sessions, recorded that Dwindle "cannot re-cut a row into a column" and
-- that a two-window stacked column could not be constructed on this build.
-- BOTH CLAIMS ARE WRONG. The user caught it by pointing at a working layout,
-- which was the right thing to do, and the measurement below is what actually
-- happens.
--
-- COLUMN -> ROW WORKS, on the first attempt, through the ordinary shim:
--
--     before                    @6,559 1695x502  |  @6,51 1695x502   (column)
--     move({direction="right"}) @857,51 844x1010 |  @6,51 845x1010    (row)
--
-- So the tiler re-cuts a column into a row without complaint. A two-window
-- column is also plainly constructible -- workspace 2 held exactly that
-- (two kitty, 1695x502 each, stacked) with no floats.
--
-- ROW -> COLUMN DOES NOT, and this is the half that is genuinely blocked:
--
--     before                @857,51 844x1010  |  @6,51 845x1010   (row)
--     move({direction="up"})  unchanged, twice, on BOTH windows
--     movewindow up/down      unchanged
--     swapwindow up           unchanged
--
-- Tried on a two-window row AND on a two-window row with each window focused
-- in turn. So the asymmetry is real: Dwindle will re-split a stacked pair
-- into a side-by-side pair, but will not re-split a side-by-side pair into a
-- stacked one. A swipe up or down on a side-by-side pair therefore has no
-- tiler-native restack, which is why FIELD_SWIPE refuses it.
--
-- WHY THE EARLIER TESTS PROVED NOTHING. Two mistakes, both mine, both of
-- which made the operation look impossible when it was merely untried:
--
--   1. `hl.get_workspace(2).windows` is a COUNT, a number -- not a list of
--      window objects. Iterating it errored or silently produced nothing, so
--      several "measured" runs logged empty and I read the silence as "no
--      change". `hl.get_workspace_windows(id)` is the list.
--   2. Those runs also went through `hl.dsp.window.move`, which I had
--      concluded was a no-op because an EARLIER run had shown it doing
--      nothing. It is not a no-op -- the run above uses the very same
--      dispatcher and it converted a column to a row.
--
-- Both mistakes have the same shape: an empty or unchanged reading was
-- recorded as a property of Hyprland rather than as a fault in the
-- measurement. Anything in this file that claims a compositor behaviour is
-- "impossible" deserves the same scepticism it just earned.
--
-- NOT ATTEMPTED: constructing a stacked pair by floating both windows into
-- column-shaped rects and un-floating them. That was tried and it un-floats
-- back into a row -- but given the correction above, it is worth re-testing
-- now that the measurement itself is known to have been unsound.

-- ═══ The graphical refusal shake: VERIFIED WORKING 2026-10-02 ═══════════
--
-- The neighbour-growth bug is GONE, and the proof is that the geometry of
-- every window is identical before, during and after a refusal. Sampled on a
-- live shake of a tiled firefox in a five-window layout:
--
--   BEFORE  brave@857,559 844x502 | kitty@6,51 1695x1010 | firefox@857,51
--           844x502 | brave@6,51 845x1010 | thunder@6,51 1695x1010
--   DURING  (byte-identical)
--   AFTER   (byte-identical)
--
-- Compare with the float shake this replaced, which held the partner at
-- 1695x1010 -- the whole work area -- for the full 144ms. Nothing moves now.
-- The window is never floated, so Dwindle is never asked to re-cut.
--
-- HOW IT WORKS, in one line: the window's PIXELS are hidden with
-- `set_prop opacity=0` (verified by md5 of a grim capture, and geometry
-- unchanged while invisible) while the shell paints the captured image in a
-- layer-shell overlay and vibrates THAT.
--
-- The sequencing lives in the shell, not here, and has to: grim takes ~140ms
-- cold, so capturing first (while the window is still visible, which is
-- invisible to the user because nothing has changed yet) is the only order
-- that does not flash a black hole where the window was.
