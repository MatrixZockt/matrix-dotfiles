hl.bind("CTRL+SUPER+ALT+Slash", hl.dsp.exec_cmd("xdg-open ~/.config/hypr/custom/keybinds.lua"), {description = "Edit user keybinds"} )

-- WhatsApp Desktop: launch via SUPER+Shift+W (bypasses app-search catalogue)
if is_file_exists(HOME .. "/.config/hypr/custom/keybinds-whatsapp.lua") then
    require("custom.keybinds-whatsapp")
end

-- ── Talking to the shell ──────────────────────────────────────────
-- Some shortcuts below have to *close* a panel when a key is released, and that
-- goes over the shell's IPC socket rather than through a `global` dispatch:
-- Hyprland does run the body of a release bind (an `hl.exec_cmd` in there really
-- does run), but a `global` shortcut dispatched from inside one never arrives --
-- which is why panels used to sit on screen until their safety timeout after you
-- let go of the keys. `qs -c ii ipc call ...` has no such problem.
local shellConfig = os.getenv("qsConfig") or "ii"
local function shellIpc(args)
    return "qs -c " .. shellConfig .. " ipc call " .. args
end

-- Window binds act on the focused window, like they always do. (They used to
-- be gated through custom/popup.lua's guard: the settings and task-manager
-- apps were layer-shell veils with no focused window behind them, so a bind
-- fired then would have hit the window HIDDEN behind. Those apps are ordinary
-- desktop windows now, so there is nothing to guard.)
local popup = require("custom.popup")
-- The "fills the screen" action SUPER+F shares with the four-finger swipe up.
-- It lives in its own module because it is TWO actions that must happen
-- together (release the bar's strip, maximize the window) and a half-applied
-- version of it is the bug it exists to fix.
local cover = require("custom.cover")

-- Floating is retired on this desktop: every window is either ATTACHED
-- (tiled) or FULLSCREEN, and there is no third mode for anything to be put
-- into. The key still has to be REBOUND rather than merely unbound -- the
-- base config defines it, and an unbound line only removes OUR definition,
-- not theirs. It is the fullscreen toggle now, so the gesture a floating
-- window used to answer ("make this one window the whole screen") still does
-- something -- it just lands in the one mode this desktop allows.
hl.unbind("SUPER + ALT + Space")
hl.bind("SUPER + ALT + Space", hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }),
    { description = "Window: Fullscreen (floating is retired)" })

hl.unbind("SUPER + F")
-- Visual window sizer: freezes an accent frame with drag handles around the
-- focused window (the shell's overlay does the rest; see VisualSizer.qml).
-- Arrow keys nudge the size while it is up, Esc/Enter release it.
hl.bind("SUPER + SHIFT + R", hl.dsp.exec_cmd(shellIpc("sizer armFocused")),
    { description = "Window: Visual resize frame (arrow keys nudge, Esc exits)" })
-- SUPER+F is the "fills the screen" toggle for the focused window.
--
-- It is NOT Hyprland's `fullscreen` as the base config defines it, and that is
-- the point (REQUESTED): the real thing tells the CLIENT to go fullscreen,
-- which is what makes Chromium hide its tab strip -- pressing it in the browser
-- made the tabs disappear, which is not what "make this fill the screen" means.
--
-- cover.toggle asks the compositor for its OWN expanded state with the client
-- half left out -- `fullscreen_state({ internal = 2, client = 0 })`: the window
-- fills the monitor, the app is told nothing, and the bar is asked to yield its
-- strip so the app really reaches the top edge (a workarea-bound window stops
-- at the bar's reserved strip). See custom/cover.lua, which also explains why
-- the window half is no longer a float+pin: a dispatched box change is applied
-- by this compositor WITHOUT animation, so the window used to teleport while
-- the rest of the desktop glided -- the "half laggy" transition. The
-- compositor's expanded state is a layout change, and layout changes animate.
hl.bind("SUPER + F", function()
    -- Remember where the window sits before it goes over the screen. The cover
    -- itself no longer needs this (un-covering restores the tile), but the
    -- app's OWN fullscreen path -- anchoredTransition in general.lua -- still
    -- reads the slot from here, and it cannot be read back from the tiler once
    -- the window is out of the layout.
    local win = hl.get_active_window()
    if win and (win.fullscreen or 0) == 0 then popup.rememberSlot(win) end
    cover.toggle(win)
end,
    { description = "Window: Fill the screen (bar yields its strip; app keeps its chrome)" })

-- Unstick: exit every stale cover state -- windows left floating at the
-- monitor's full size with no remembered pre-state (a crash mid-cover, an
-- external tool that churned window state). Live covers keep their memory
-- and are left alone. Safety valve; a clean desktop makes it a no-op.
hl.bind("SUPER + ALT + SHIFT + S", function()
    cover.sweep()
end,
    { description = "Window: Unstick stale full-screen covers" })

hl.unbind("SUPER + ALT + F")
hl.bind("SUPER + ALT + F", hl.dsp.window.fullscreen_state({ internal = 0, client = 3, action = "toggle" }),
    { description = "Window: Fullscreen spoof" })

-- SUPER+P pinned a window (an always-on-top floating window -- the one thing
-- this house rule forbids). The base config owns the key, so it has to be
-- REBOUND rather than merely unbound: leaving it unbound would just let THEIR
-- pin bind fire.
--
-- The key is the WHOLE-SCREEN SNIP now (2026-10-14, requested): the plain
-- version of SUPER+S, with no region asked for. The pin stays retired and the
-- no-op this used to be is gone -- a key that does nothing is a key that reads
-- as broken, and this one has a screenshot to offer. See
-- RegionSelector.screenshotFullScreen(): same grim + clipboard path, no region
-- surface, and nothing left on disk (screenSnip.savePath is empty, so the copy
-- lives in the clipboard until the next one replaces it).
hl.unbind("SUPER + P")
hl.bind("SUPER + P", hl.dsp.global("quickshell:regionScreenshotFull"),
    { description = "Utilities: Whole-screen snip (copy to clipboard)" })

-- ── No mouse dragging. The window binds for the mouse are REMOVED. ─────────
--
-- The base config binds SUPER + LMB to move a window and SUPER + RMB to resize
-- it. The MOVE bind is unbound here and nothing replaces it: the mouse has no
-- way to move a window at all.
--
-- Why remove even the modifier-gated ones: they act on whatever is focused, and
-- a drag on a TILED window first floats it -- so a window that was sitting in
-- the layout is suddenly loose on top of the others, at a new size, with the
-- whole layout re-split behind it. That is the scattering this is here to stop.
-- SUPER is also held near-constantly in this setup (the shell's search opens on
-- a SUPER tap, the gestures all use it), so SUPER+drag was never really a
-- deliberate two-key action.
--
-- The RESIZE bind is deliberately BACK (2026-09-26), as the one hand path to
-- resizing -- requested: the two-finger press + drag resizes the window, and
-- the corner/edge nearest the cursor is the one that moves. That anchor is
-- dwindle:smart_resizing (set true in custom/general.lua): Hyprland reads the
-- cursor position at press time and drives THAT corner for the whole drag.
-- It is granted with eyes open:
--   * it stays modifier-gated (SUPER), so no habitual touchpad motion can
--     ever fire it;
--   * on a TILED window it re-splits the layout and the neighbours shift --
--     that is what resizing an attached window IS (SUPER+ALT+arrows do the
--     same, 40px at a time). On a FLOATING window it is the classic corner
--     drag with no layout consequences.
-- The anchor needs the window under the cursor to be the focused one, which
-- input:follow_mouse = 1 (base config) guarantees: the press focuses whatever
-- is under the cursor before the drag starts.
--
-- How windows are handled by hand, by design:
--   SUPER + two-finger press + drag ... resize it (corner nearest cursor)
--   three-finger swipe ........ move the window (built-in gesture, base config)
--   SUPER + four-finger swipe . take it to the next/previous desktop
--   SUPER + arrows ............ resize it, attached, 40px per press
--   SUPER + SHIFT + arrows .... swap it with a neighbour in the layout
--   CTRL + SUPER + HJKL ....... focus the neighbour in that direction
--   SUPER + ALT + arrows ...... resize it, 40px per press (kept, same as above)
--   SUPER + ALT + H / SHIFT+H . minimize / restore
--
-- (Also worth knowing: binding a Lua FUNCTION with { drag = true } does not
-- produce a drag bind in this build -- hyprctl reports it as a plain release
-- bind, so the guard-wrapped drags that used to be here never armed a drag at
-- all. Dispatcher-based drags like the one below are the real thing; they are
-- what the base config itself used.)
hl.unbind("SUPER + mouse:272")
hl.unbind("SUPER + mouse:274")
hl.unbind("SUPER + mouse:273")

-- The resize drag, back by request. On this touchpad a TWO-FINGER PRESS is
-- right-button (clickfinger_behavior), so: hold SUPER, press with two fingers
-- on the window, drag -- the nearest corner follows your fingers, 1:1.
-- { mouse = true } is the flag that makes this a real mouse-drag bind in this
-- build ({ drag = true } silently registers a plain release bind instead --
-- verified with hyprctl binds).
hl.bind("SUPER + mouse:273", hl.dsp.window.resize(), { mouse = true, description = "Window: Resize" })

-- ═══ The middle button never reaches an application ═════════════════════
--
-- A THREE-finger tap was pasting a large blob into text boxes. What that
-- blob is, and how it was identified:
--
--   * `wl-paste --primary` returns exactly the pasted text; the regular
--     clipboard holds something else entirely. So the app was pasting its
--     own PRIMARY selection, not the clipboard.
--   * Pasting PRIMARY is what a MIDDLE CLICK does in every toolkit. So the
--     tap was arriving as a middle button, from a layer that decides this
--     on its own -- `input:touchpad:tap_button_map` and
--     `clickfinger_behavior` in custom/general.lua, not the shell.
--   * The shell was never involved. `services/TouchpadSwipe.qml` reads the
--     evdev node directly, so the same tap still toggles play/pause and
--     always did; and every Cliphist paste call was logged while the bug was
--     live, with zero hits.
--
-- Restating `tap_button_map` to "1,2,0" and then "1,2,-1" changed nothing
-- observable, so the button is not decided by that key and guessing further
-- at it is how a three-finger tap turns into a LEFT click, which is worse.
-- `clickfinger_behavior` is the more likely author but cannot be turned off
-- without breaking the SUPER + two-finger-press resize above.
--
-- So the middle button is caught HERE, with no modifier: the compositor
-- consumes it and no application ever sees it. That is deliberately blunt
-- and deliberately permanent -- it holds regardless of which layer
-- synthesised the button, now or after a compositor update.
--
-- The cost, stated plainly: middle-click paste and middle-click autoscroll
-- (some X11 apps) stop working on this desktop. Both were unreachable in
-- practice -- the only way to get a middle click was the gesture that was
-- breaking text input. Delete this bind to get the behaviour back.
--
-- The log line is not decoration: if this bind ever fires when you did not
-- expect it, `tail /tmp/tapbtn.log` says when. Delete the exec (keep the
-- bind) to silence it once you trust it.
hl.bind("mouse:274", hl.dsp.exec_cmd(
    "printf '%s middle click swallowed\\n' \"$(date +%H:%M:%S)\" >> /tmp/tapbtn.log"),
    { mouse = true, description = "Swallow middle click (no PRIMARY paste)" })

-- SUPER + SHIFT + arrows: move the focused window. Kept directional (the
-- base's own semantics) so the rebind changes nothing else.
do
    local arrowkey = { "Left", "Right", "Up", "Down" }
    local focusdir = { "l", "r", "u", "d" }
    for i = 1, 4 do
        hl.unbind("SUPER + SHIFT + " .. arrowkey[i])
        hl.bind("SUPER + SHIFT + " .. arrowkey[i],
            hl.dsp.window.move({ direction = focusdir[i] }),
            { description = "Window: Move window" })
    end
end

-- SUPER+Q: close the focused window. It used to park close-to-tray apps into
-- `special:tray` first (config.json's tray.closeToTray), and that is what made
-- a Thunderbird compose window vanish instead of closing -- see the note in
-- custom/general.lua at the close-drag's finish, where the same branch was
-- removed on 2026-10-22. One gesture, one verb: it closes.
hl.unbind("SUPER + Q")
hl.bind("SUPER + Q", function()
    hl.dispatch(hl.dsp.window.close())
end, { description = "Window: Close" })

-- Panel brightness keys. These go through the resolver
-- (scripts/system/brightness-device.sh) rather than plain `brightnessctl`,
-- and that indirection is the whole point of the script.
--
-- This machine has two backlight nodes: `intel_backlight`, which actually
-- drives the built-in panel, and `nvidia_0`, which changes nothing you can
-- see. `brightnessctl` with no `-d` picks whichever the kernel lists first,
-- which here is nvidia_0 -- so the keys fired, the node moved, and the screen
-- stayed exactly as bright as before. Verified: pressing the brightness keys
-- left intel_backlight pinned at 156 while nvidia_0 swung 1 -> 100 -> 0.
--
-- The script resolves the panel from the DRM state instead (the connected
-- eDP-* connector's own backlight), and the keyboard-backlight keys below keep
-- their separate script, since a keyboard backlight is a different device.
hl.unbind("XF86MonBrightnessUp")
hl.bind("XF86MonBrightnessUp",
    hl.dsp.exec_cmd("bash $HOME/.config/quickshell/ii/scripts/system/brightness-device.sh step +5"),
    { locked = true, repeating = true, description = "Utilities: Brightness up (panel)" })
hl.unbind("XF86MonBrightnessDown")
hl.bind("XF86MonBrightnessDown",
    hl.dsp.exec_cmd("bash $HOME/.config/quickshell/ii/scripts/system/brightness-device.sh step -5"),
    { locked = true, repeating = true, description = "Utilities: Brightness down (panel)" })


-- Colour picker: SUPER + C.
-- The shell's own GlobalShortcut does the work (modules/ii/colorPicker):
-- a frozen grab of the screen, a crosshair and a live hex/rgba pill;
-- Alt+X or a click copies the hex, Esc closes. The unbind is needed because
-- the base file binds SUPER + C to the code editor later in its run.
hl.unbind("SUPER + C")
hl.bind("SUPER + C", hl.dsp.global("quickshell:colorPicker"),
    { description = "Utilities: Pick color #RRGGBB >> clipboard" })

-- Media keys: straight to wpctl/playerctl, permanently.
--
-- Same story as the brightness rebinds above: the base XF86 binds are
-- registered once at login, and after the shell daemon's crash + watchdog
-- resurrection this session, the original binds' dispatchers stopped
-- reaching their commands (fresh re-registrations fire fine, the old ones
-- no longer do). These unbind-and-rebind rows keep the keys on simple,
-- stateless commands that cannot go stale -- every reload re-runs this
-- file, so the keys are always freshly wired.
-- The volume steps are in SINK units, and the shell calls the sink's 2.0
-- "100%" -- so one press is 4% here (the shell's own 2% step) and the cap is
-- 2.0, not 1.5. At 2%/-l 1.5 the keys stopped at three quarters of the
-- desktop's own scale and every press moved the bar's number by one percent:
-- the keys and the bar disagreed about where the top was.
do
    local mediaKeys = {
        { "XF86AudioRaiseVolume", "wpctl set-volume @DEFAULT_AUDIO_SINK@ 4%+ -l 2.0", "Volume up" },
        { "XF86AudioLowerVolume", "wpctl set-volume @DEFAULT_AUDIO_SINK@ 4%-",        "Volume down" },
        { "XF86AudioMute",        "wpctl set-mute @DEFAULT_SINK@ toggle",             "Toggle mute" },
        { "XF86AudioMicMute",     "wpctl set-mute @DEFAULT_SOURCE@ toggle",           "Toggle mic mute" },
        { "XF86AudioPlay",        "playerctl play-pause",                             "Play/pause media" },
        { "XF86AudioPause",       "playerctl play-pause",                             "Play/pause media" },
        { "XF86AudioNext",        "playerctl next",                                   "Next track" },
        { "XF86AudioPrev",        "playerctl previous",                               "Previous track" },
    }
    for _, k in ipairs(mediaKeys) do
        hl.unbind(k[1])
        hl.bind(k[1], hl.dsp.exec_cmd(k[2]),
            { locked = true, repeating = true, description = "Media: " .. k[3] })
    end
end

-- CTRL + SUPER + arrows: the keyboard twins of the three-finger swipes
-- (custom/general.lua). They call FIELD_SWIPE, the same function the gestures
-- do, so the two can never drift apart: swap focus with the neighbour in that
-- direction, and only if there is nothing there move the neighbour across
-- instead. That function lives in custom/general.lua, which is required
-- earlier in hyprland.lua -- and it is called at key-press time, not at bind
-- time, so the load order is not load-bearing here anyway.
do
    local arrowkey = { "Left", "Right", "Up", "Down" }
    local fielddir = { "left", "right", "up", "down" }
    for i = 1, 4 do
        local dir = fielddir[i]
        hl.unbind("CTRL + SUPER + " .. arrowkey[i])
        hl.bind("CTRL + SUPER + " .. arrowkey[i],
            function() FIELD_SWIPE(dir) end,
            { description = "Window: Swap with neighbour " .. dir })
    end
end

hl.unbind("SUPER + ALT + S")
hl.bind("SUPER + ALT + S", hl.dsp.window.move({ workspace = "special:special", follow = false }),
    { description = "Window: Send to scratchpad" })

hl.unbind("CTRL + SUPER + Backslash")
hl.bind("CTRL + SUPER + Backslash", hl.dsp.window.resize({ x = 640, y = 480, "exact" }))

-- ── Window management (added on top of the base config) ─────────────────────
--
-- Mouse dragging is off in every form except ONE. Two separate things used to
-- let the pointer grab a window:
--
--   1. a plain-left-button drag bind -- removed long ago. binds:drag_threshold
--      cannot tell a title-bar grab from a drag *inside* an app, so selecting
--      text or dragging a slider moved the whole window instead.
--   2. `general:resize_on_border` (on in the base config) -- a press near any
--      window edge began a resize drag with NO modifier held. Removed in
--      custom/general.lua along with the extended grab area. (This was switched
--      off 2026-09-28 and back on 2026-10-16; the dated note there carries the
--      measurement that ended it -- the band sat OUTSIDE the window, so aiming
--      at the border grabbed the window instead. The 15px here was the old
--      band; it had been 10px.)
--
-- The SUPER + LMB move drag the base config binds is unbound above. The ONE
-- deliberate exception is the SUPER + RMB (= two-finger press) RESIZE drag,
-- re-bound above with the cursor-nearest-corner anchor (smart_resizing).
-- What is left is deliberate-only:
--
--   SUPER + two-finger press+drag ... resize it (corner nearest the cursor)
--   three-finger swipe ........ move a window around the screen
--   SUPER + four-finger swipe . move it to another desktop
--   SUPER + arrows ............ resize it, attached, 40px per press
--   SUPER + SHIFT + arrows .... swap it with a neighbour
--   CTRL + SUPER + HJKL ....... focus the neighbour in that direction
--   SUPER + ALT + arrows ...... resize, 40px per press (kept, same as SUPER+arrows)
--
-- Tested and kept from the base config: SUPER+D maximize, SUPER+F fullscreen,
-- SUPER+ALT+Space float/tile, SUPER+SHIFT+arrows move window, SUPER+P pin,
-- SUPER+Q close, SUPER+S / SUPER+ALT+S scratchpad show / send.

--#! Utilities
--# Clipboard history (SUPER + V)
-- A popup that is just the clipboard icon, the word Clipboard, and the entries,
-- opened right under the pointer -- and pulled back inside the screen margins
-- when the cursor is near an edge, so the card can never end up half off the
-- display. See ClipboardListWindow.qml.
--
-- The base config points SUPER+V at the shell's overview, which drags the whole
-- desktop-summary backdrop and its search bar along with the clipboard; this
-- replaces that with the dedicated popup.
--
-- The popup is a TOGGLE that STAYS OPEN: press SUPER+V once, let go of
-- everything, and it is still on screen to pick from. No key on this side closes
-- it on a SUPER edge any more -- see the SUPER_L/SUPER_R binds further down for
-- what used to and why it fired on the wrong edge -- and the shell dismisses it
-- when it should: a fresh SUPER press, Escape, a click away, a desktop change.
--
-- The release-interrupt fires first, like every other SUPER chord here: SUPER is
-- still held when V goes down, and an uninterrupted SUPER release would open the
-- plain-tap app search card a beat after the popup appeared.
hl.unbind("SUPER + V")
hl.bind("SUPER + V", function()
    hl.exec_cmd(shellIpc("search toggleReleaseInterrupt"))
    hl.exec_cmd(shellIpc("clipboard toggle"))
end, { description = "Utilities: Clipboard history" })

--# Failsafe: reload the desktop shell
-- SUPER+CTRL+B is the "something is stuck" key. The shell is one process that
-- draws the bar, sidebars, dock and every popup, and it owns the keyboard/pointer
-- while one of those is open -- so a bad reload, a popup that will not close or
-- input that seems swallowed all look like a frozen desktop even though your apps
-- are fine.
--
-- The reload is three steps and nothing else (reload-shell.sh):
--   1. rebuild the shell binary (cargo build --release -p quickshell), when a
--      source tree is present at ~/.config/quickshell/ii
--   2. kill the running shell                 (qs -c ii kill)
--   3. let shell-watchdog.service relaunch it
--
-- There is deliberately NO verification: no splash indicator, no ydotool
-- press/release sweep, no "did it come back?" retry loop, no success card. The
-- bar reappearing is the confirmation. The old failsafe (reset-shell.sh) still
-- exists and is still worth running by hand when the load-failure report it
-- writes is what you want -- this key is the shortcut, not the diagnostic.
hl.bind("CTRL + SUPER + B", hl.dsp.exec_cmd("$HOME/.config/hypr/custom/scripts/reload-shell.sh"),
    { description = "Shell: Reload the desktop shell" })

--#! Utilities
--# Failsafe: give the mouse back (SUPER + CTRL + M)
--
-- The "I can move the pointer but I cannot CLICK anything" key, in EVERY shape
-- that failure has -- not only the compositor-grab one it used to clear:
--
--   * a button or key left held on ydotoold's virtual device. That device's
--     state belongs to the session, so a press whose release never went out (a
--     script killed halfway, a shell that reloaded mid-keystroke) leaves the
--     button down, and from then on the press has already happened and no new
--     one lands. This was reset-shell.sh's job alone before; it is step 1 here.
--   * a compositor-level input grab: while the shell holds a HyprlandFocusGrab,
--     Hyprland routes input to the grabbing window, so a claimant that stays
--     active with nothing on screen swallows the session's clicks while the
--     desktop looks perfectly normal. The shell's own GlobalFocusGrab prunes
--     dead entrants on a timer; this key is the manual version, over the IPC
--     the shell already exposes for it.
--   * a shell that is mapped but MUTE -- it holds its surfaces, it answers
--     nothing, so every step above is swallowed. That one escalates.
--   * and the KEYBOARD held somewhere else, which is not a pointer failure at
--     all: clicks land everywhere, but a text field never takes input. A stuck
--     submap is that case -- every key goes to the submap, so nothing can be
--     typed anywhere.
--
-- It is deliberately NOT SUPER+CTRL+B. That key reloads the whole shell (kill +
-- relaunch), which is slow and disturbs every surface; this one drops the held
-- input and the grab in place, so windows, panels and the bar never move, and
-- only escalates to the reload when the shell really is the problem.
--
-- submap_universal, deliberately: a submap is one of the things this key
-- clears, and a bind that does not fire from inside a submap could never clear
-- one -- the desktop would keep swallowing every key with no way back. It is
-- the same exception the VM submap's own escape key takes.
--
-- See custom/scripts/fix-mouse.sh for the whole story.
hl.bind("CTRL + SUPER + M", hl.dsp.exec_cmd("$HOME/.config/hypr/custom/scripts/fix-mouse.sh"),
    { submap_universal = true,
      description = "Utilities: Fix input (held keys / stuck grab / stuck submap)" })

-- SUPER+CTRL+SHIFT+B is INTENTIONALLY UNBOUND (2026-10-03).
--
-- It used to run the same failsafe script as SUPER+CTRL+B. It was briefly
-- repurposed to be a "restart the screen" key in the spirit of the Windows
-- SUPER+CTRL+SHIFT+B (which restarts the graphics driver), then that was
-- dropped: a real GPU reset needs root (nvidia-smi -r answers "Insufficient
-- Permissions" on this hybrid Intel+NVIDIA machine) and Hyprland is the session
-- compositor, so restarting it is a logout that destroys every window.
--
-- `hl.unbind` rather than simply deleting the `hl.bind`: a bind is an override,
-- and this combination is now free to be claimed by anything later without
-- having to reason about a stale entry that is still in this file's history.
-- SUPER+CTRL+B above is unchanged and remains the one shell failsafe.
hl.unbind("CTRL + SHIFT + SUPER + B")

--#! Utilities
--# Clear the shell loading indicator (SUPER + CTRL + SHIFT + B)
-- The combination above was released on 2026-10-03 and left deliberately free.
-- It is claimed here for the one thing that combination is actually good for.
--
-- WHY THIS KEY EXISTS. The failsafe's loading indicator is a FULL-SCREEN layer
-- surface, and it is normally removed by a watcher process watching for the
-- shell's surfaces to appear. That watcher is the only thing standing between
-- the user and a spinner drawn over a desktop that has already finished
-- loading -- a state where the desktop is usable but the screen says it is not,
-- and nothing on it can be dismissed. An indicator you cannot clear is worse
-- than no indicator, because it hides a working desktop and lies about it.
--
-- So the escape hatch is a key rather than a heuristic, and it is deliberately
-- on the SHIFT variant: SUPER+CTRL+B is the key people reach for when the
-- desktop looks stuck, and binding "get rid of the loading screen" to it would
-- mean the obvious response to a stuck-looking desktop restarts it all over
-- again -- showing the indicator once more. Shift is the "and just let me have
-- my screen back" modifier.
--
-- This removes the indicator and does nothing else. See the script for why.
hl.bind("CTRL + SHIFT + SUPER + B",
    hl.dsp.exec_cmd("$HOME/.config/hypr/custom/scripts/dismiss-loading.sh"),
    { description = "Utilities: Clear the shell loading indicator" })

--#! Window
--# Alt-Tab
-- A switcher, not a chain of jumps: ALT+Tab shows the APPS of the desktop you
-- are on, from anywhere (fullscreen or not), and picking one takes it
-- fullscreen -- the desktop is fullscreen-first, so that is the useful landing
-- state either way.
--
-- Nothing switches as you press: ALT+Tab / ALT+SHIFT+Tab only move the highlight,
-- and letting go of ALT commits the selection. So overshooting costs nothing and
-- you are never forced into a state you did not pick.
--
-- Earlier versions of this bind only worked over a fullscreen window, and before
-- that it opened the desktop switcher (which duplicated SUPER+Tab's overview).
--
-- The desktop overview keeps its own shortcut on SUPER+Tab -- see "Desktop
-- overview" further down -- it is a hold-to-look grid, not part of this.
hl.unbind("ALT + Tab")
hl.unbind("ALT + SHIFT + Tab")
hl.unbind("ALT_L")
hl.unbind("ALT_R")

hl.bind("ALT + Tab", function()
    -- The app switcher, from ANYWHERE. It used to fire only over a fullscreen
    -- window (and do nothing otherwise, on the theory that a bare ALT+Tab was
    -- a reflex) -- but "nothing happened" is its own bug when you actually
    -- wanted the switcher. Now it always opens, and picking an app takes that
    -- app fullscreen (see the shell's switcherActivate): this desktop is
    -- fullscreen-first, so that is the useful outcome in both directions.
    hl.dispatch(hl.dsp.global("quickshell:switcherApps"))
end, { repeating = true, description = "Window: Alt-Tab app switcher (picked app goes fullscreen)" })

hl.bind("ALT + SHIFT + Tab", hl.dsp.global("quickshell:switcherPrev"),
    { repeating = true, description = "Window: Alt-Tab switcher backwards" })

-- Releasing ALT is what commits, and it commits *immediately*: the IPC call
-- below switches to whatever is highlighted and closes the panel in the same
-- beat. This is a bare-modifier release bind, the same pattern the base config
-- uses for SUPER, and it is inert when the switcher is not open.
--
-- Releasing TAB while ALT is still down keeps the panel, so you can Tab on --
-- and that is simply what "nothing happened" means here. There is deliberately
-- NOTHING bound to TAB.
--
-- There used to be a third bind: `ALT + Tab` with `ignore_mods`, `transparent`
-- and `release`, whose one job was the "let go of everything" case -- release
-- TAB after ALT is already up and the panel is dismissed. It is gone, and it is
-- not coming back. `ignore_mods` makes a chord match with NO modifiers held as
-- well (that is exactly why the bare SUPER_L/SUPER_R binds use it), so that
-- bind was a Hyprland bind on a bare TAB: the compositor looking at a key that
-- belongs to whatever is focused. TAB has to reach the application untouched --
-- a form field, a spreadsheet cell, an editor's indent all depend on it, and
-- none of them may depend on whether the compositor is holding the edge of a
-- key for a panel that is not even open. Nothing is lost: letting go of TAB
-- while ALT is down still keeps the panel (no bind, no action), and letting go
-- of ALT is what commits either way -- which is the only thing a TAB release
-- could have been waiting for.
for _, altKey in ipairs({ "ALT_L", "ALT_R" }) do
    hl.bind(altKey, function()
        hl.exec_cmd(shellIpc("switcher activate"))
    end, { ignore_mods = true, transparent = true, release = true })
end
-- ALT+ALT (tap ALT twice) dismisses without switching, if you change your mind.
hl.bind("ALT + ALT_L", hl.dsp.global("quickshell:switcherCancel"),
    { ignore_mods = true, transparent = true })
hl.bind("ALT + ALT_R", hl.dsp.global("quickshell:switcherCancel"),
    { ignore_mods = true, transparent = true })

--#! Shell
--# The drag-to-reorder desktop grid on SUPER + Tab -- a toggle
-- SUPER+Tab now opens the standalone desktop stage
-- (modules/ii/overview/DesktopOverview.qml): frosted cards with live previews,
-- and a card can be picked up -- click-hold ~450ms or double-tap then press-move
-- -- and dropped elsewhere to rearrange the desktops. Nothing grabs a card by
-- itself; hovering the idle grid cannot.
--
-- This REPLACES the old hold-to-peek (2026-10-07): that one opened the older
-- step-through grid via the search IPC, kept it open while the chord was held
-- and closed it on release -- machinery (tabHeld/superHeld/peeking/stepDesktop
-- and the SUPER release-side teardown) that is gone with it. A toggle needs no
-- held-key semantics: press again, Escape, a click away from the cards, or
-- picking a desktop all put it away. SUPER+SHIFT+Tab (the old "step back") went
-- with the peek; it has no meaning here.
--
-- The release-interrupt fires first, like every other SUPER chord: an
-- uninterrupted SUPER release after Tab would otherwise open the search panel a
-- beat behind the grid.
hl.unbind("SUPER + Tab")
hl.bind("SUPER + Tab", function()
    hl.exec_cmd(shellIpc("search toggleReleaseInterrupt"))
    hl.dispatch(hl.dsp.global("quickshell:desktopOverviewToggle"))
end, { description = "Shell: Desktop overview (drag-to-reorder grid)" })

-- SUPER press and release are already bound in the base config to the
-- workspace-number hint, so rather than take that key over these keep the hint
-- and add the release side of the peek above.
hl.unbind("SUPER_L")
hl.unbind("SUPER_R")
-- A plain SUPER *tap* still opens the search panel through the base config's own
-- `SUPER + SUPER_L` release bind (that bind is deliberately left alone, including
-- its fuzzel fallback for when the shell is not running). These binds stay out of
-- its way entirely.
--
-- DISPATCHERS, one per edge, and NO clipboard dismissal here any more.
--
-- The clipboard close used to live in this loop as a Lua FUNCTION body, on the
-- understanding that a function body is a press bind. In this build it is not:
-- a function body registers as a plain RELEASE bind -- the same quirk that makes
-- `{ drag = true }` a no-op (see the note on the resize drag further up) -- so
-- that "on press" close fired on the way UP. SUPER+V opened the popup, SUPER was
-- let go, and the popup shut a beat later, which is exactly the reported "you
-- have to hold SUPER to keep the clipboard open".
--
-- The dismissal belongs to the shell now (ClipboardListWindow watches
-- GlobalStates.superDown, so the edge is the shell's own record of the key
-- instead of a bind flag), and nothing on this side closes the popup.
--
-- The hint is bound on BOTH edges here, not left to the base config, because the
-- two `hl.unbind`s above took that pair away: numbers while SUPER is held, icons
-- the moment it is let go.
for _, superKey in ipairs({ "SUPER_L", "SUPER_R" }) do
    hl.bind(superKey, hl.dsp.global("quickshell:workspaceNumber"),
        { ignore_mods = true, transparent = true })
    hl.bind(superKey, hl.dsp.global("quickshell:workspaceNumber"),
        { ignore_mods = true, transparent = true, release = true })
end

-- ── SUPER + SPACE: the desktops, on its own key (2026-10-14, retuned
--    2026-10-15 -- requested) ───────────────────────────────────────────────
--
-- Press it and the desktop grid comes up; press it again and it goes away. That
-- is one action for one action, the same deal the four-finger swipe offers --
-- which is what this key is FOR. It was a 300 ms hold at first, and a tap did
-- nothing at all: a key that opens a view, that ignores a press of it, is a key
-- that reads as broken (measured -- the first thing anyone does with it is
-- tap it). The hold still works, trivially: the press has already toggled.
--
-- IT DOES NOT GRAB A DESKTOP (2026-10-16, requested). It did for a day: the
-- grid came up holding the desktop under the POINTER (2026-10-15). Both halves
-- of that are gone now -- this chord raises no lift on its press edge any more
-- (GlobalStates.superPressEdge) and the SUPER + four-finger swipe down that
-- shared the behaviour is deleted from custom/general.lua -- so the key is what
-- it was before: a plain toggle onto the grid. A click there still switches
-- desktop and a click-HOLD still picks a card up to rearrange the desktops;
-- what no longer happens is a card arriving in your hand because you pressed
-- this key. The compositor side never changed and is still single: this key
-- only names the chord.
--
-- The desktop numbers show while the chord is down, exactly as they do on a
-- bare-SUPER hold, and the app search card never opens on the way up: the
-- chord's SUPER release is not a tap (see the release-interrupt below, and
-- GlobalStates.superPressEdge).
--
-- A different GlobalShortcut from the bare key's `workspaceNumber`, on purpose.
-- The shell hears only names, so ONE name for both keys would make "bare SUPER
-- was held" and "SUPER+Space was held" the same event -- which is precisely
-- what put the grid on a slow bare-SUPER press. Two names, and the shell can
-- keep the numbers hint and the search card on the bare key and the grid on
-- this one (GlobalStates.qml: `superPressEdge`/`superReleaseEdge`, called by
-- both shortcuts).
--
-- No `ignore_mods` here, deliberately. That flag exists on the bare binds
-- because the keypress that RAISES SUPER is the event that creates the
-- modifier, so a modifier-strict bind never matches it. On this chord the
-- modifier is long established, and `ignore_mods` would instead make the bind
-- match a bare Space -- stealing the space bar from every app on the desktop.
--
-- NOT transparent, also deliberately: the bare binds pass the key through so
-- the hint can coexist with the Super+<number> workspace binds. Here the chord
-- IS the action, so the space is consumed rather than typed into whatever is
-- focused -- which is what the old accidental "SUPER+Space behaves like a bare
-- SUPER tap and also types a space" was made of.
--
-- The release is bound as well as the press, and not because anything waits on
-- it: the TOGGLE happens on the press edge. The release edge is what tells the
-- shell the chord is over -- `superDown` goes false, and the tap candidate the
-- press cleared stays cleared (GlobalStates.superReleaseEdge). Without it the
-- shell would believe SUPER was still down until the next press told it
-- otherwise.
hl.bind("SUPER + Space", hl.dsp.global("quickshell:superHold"),
    { description = "Shell: Toggle the desktops (SUPER + Space)" })
hl.bind("SUPER + Space", hl.dsp.global("quickshell:superHold"),
    { description = "Shell: Toggle the desktops (release)", release = true })


-- Kept from before: a no-look "next occupied desktop" cycle, for when you do not
-- want to see anything.
local function nextOccupiedWorkspace()
    local active = hl.get_active_workspace()
    if not active then return nil end
    local ids = {}
    for _, w in ipairs(hl.get_windows()) do
        if w.workspace and w.workspace.id and w.workspace.id > 0 then
            ids[#ids + 1] = w.workspace.id
        end
    end
    table.sort(ids)
    for index, id in ipairs(ids) do
        if id == active.id then
            return ids[index % #ids + 1] -- wrap around at the end
        end
    end
    return ids[1]
end

hl.bind("SUPER + ALT + Tab", function()
    local nextId = nextOccupiedWorkspace()
    if nextId then
        hl.dispatch(hl.dsp.focus({ workspace = nextId }))
    end
end, { description = "Window: Jump to next occupied desktop" })

--#! Desktop
--# The drag-to-reorder desktop grid: SUPER + Z
--
-- Z for "zoom out": the overview IS the zoomed-out view of every desktop --
-- frosted cards with live previews, and (the reason it gets its own key) a
-- card can be picked up and dropped elsewhere to rearrange the desktops:
-- click-hold a card ~450ms, or double-tap it and press-move; the neighbours
-- slide aside to open the drop gap. Nothing else grabs a card -- moving the
-- pointer over the idle grid cannot.
--
-- This is deliberately NOT the SUPER+Tab peek above: that one is the older
-- step-through grid driven by the search IPC, held open by the key. This is
-- the standalone stage (modules/ii/overview/DesktopOverview.qml) the
-- four-finger swipe opens -- a TOGGLE, because a key chord has no held-mod
-- release semantics here: press again, Escape, a click away from the cards,
-- or picking a desktop all put it away.
--
-- The release-interrupt fires first, like every other SUPER chord here: Z
-- goes down while SUPER is still held, and an uninterrupted SUPER release
-- would open the search panel a beat after the grid came up. (Same ordering
-- requirement as toggleTaskManager below -- a shell IPC call, not part of
-- the dispatch string, because order matters.)
hl.bind("SUPER + Z", function()
    hl.exec_cmd(shellIpc("search toggleReleaseInterrupt"))
    hl.dispatch(hl.dsp.global("quickshell:desktopOverviewToggle"))
end, { description = "Shell: Desktop overview (drag-to-reorder grid)" })

--#! Window
--# Move the focused window to the desktop next door: SUPER + four-finger swipe
--
-- This was ten keybinds:
--
--   SUPER + SHIFT + <n> ... move the focused window to desktop n AND go with it
--
-- They are unbound rather than rebound. The gesture below covers the same idea
-- without ten keys to remember, and a key that is unbound is better than a key
-- that quietly does something else. The number row is one block to bring back:
--
--   for i = 1, 10 do
--       hl.bind("SUPER + SHIFT + " .. (i % 10), function()
--           hl.dispatch(hl.dsp.window.move({ workspace = workspace_in_group(i), follow = true }))
--       end, { description = "Window: Move to desktop " .. i .. " and follow" })
--   end
--
-- The gesture itself lives in custom/general.lua, next to the other trackpad
-- settings, because that file is loaded after the base config's gestures.
for i = 1, 10 do
    hl.unbind("SUPER + SHIFT + " .. (i % 10))
end

--# Minimize and restore
-- Hide the active window: it goes to a "minimized" workspace that is not shown.
-- Restore with SUPER+SHIFT+H, which toggles that workspace back into view.
hl.bind("SUPER + ALT + H", hl.dsp.window.move({ workspace = "special:minimized", follow = false }),
    { description = "Window: Minimize (hide)" })
hl.bind("SUPER + SHIFT + H",
    hl.dsp.workspace.toggle_special("minimized"),
    { description = "Window: Show minimized" })

--# Resize with the keyboard (hold to keep resizing)
--
-- SUPER + an arrow is the RESIZE, and it is the plain one: no ALT. That is the
-- requested gesture -- "resize the selected window that way, but keep it
-- attached to the others, like dragging its edge with the mouse" -- and on
-- this all-tiled desktop the two are the same operation, because nothing
-- floats and every window is in the layout.
--
-- What actually happens, measured on a live tiled pair (two windows side by
-- side, focus on the left one):
--
--   before   left x=6   w=845  |  right x=857 w=844
--   Left     left x=6   w=695  |  right x=707 w=994
--   Left     left x=6   w=545  |  right x=557 w=1144
--
-- The boundary between them MOVES and the tiler re-splits: the focused window
-- gives up the room, the neighbour takes it, neither is ever detached. That is
-- the whole point -- a window stays attached, and its neighbours close ranks.
--
-- "Push the shared boundary that way" is the honest description, not "move my
-- window's edge". Hyprland's relative resize is relative to the SPLIT, so the
-- sign flips with which side of the boundary you are on: with focus on the
-- RIGHT window, x=+150 SHRINKS it (the boundary moves right, away from it).
-- Both outcomes are what the mouse does too, because on the far side of a
-- boundary "drag my edge outward" and "push the boundary outward" are the same
-- gesture -- the room has to come from the neighbour either way. At the screen
-- edge there is no neighbour, and the resize is a safe no-op rather than
-- throwing the window off the workarea.
--
-- At a screen edge, or with a single window on the workspace, nothing moves.
-- That is deliberate: a floating-style resize would tear the window out of the
-- layout, which is exactly what this desktop does not allow.
--
-- `repeating = true` so HOLDING the key keeps resizing -- that is what makes
-- this feel like a drag rather than four separate presses. 40px per step
-- matches SUPER+ALT+arrows below and the mouse border drag closely enough that
-- the two feel like the same tool.
--
-- The base config owns SUPER + arrows for FOCUS (hyprland/keybinds.lua), so
-- each one is unbound before it is rebound -- an unbound line only removes OUR
-- definition, not theirs.
--
-- Directional focus did not disappear, it moved: see CTRL+SUPER+HJKL just
-- below.
do
    local arrowkey = { "Left", "Right", "Up", "Down" }
    -- Signed step per direction. Positive pushes the boundary in that
    -- direction; the tiler sorts out which window that shrinks.
    -- Signed step per direction. Positive pushes the boundary in that
    -- direction; the tiler sorts out which window that shrinks.
    local steps = { { x = -40, y = 0 }, { x = 40, y = 0 }, { x = 0, y = -40 }, { x = 0, y = 40 } }
    for i = 1, 4 do
        local s = steps[i]
        hl.unbind("SUPER + " .. arrowkey[i])
        hl.bind("SUPER + " .. arrowkey[i],
            hl.dsp.window.resize({ x = s.x, y = s.y, relative = true }),
            { repeating = true, description = "Window: Resize " .. arrowkey[i] })
    end
end

-- Directional focus, moved here from SUPER + arrows (which is resize above).
--
-- CTRL + SUPER + HJKL rather than SUPER + HJKL, and not by preference: SUPER+J,
-- SUPER+K and SUPER+L are all already bound (toggle bar, on-screen keyboard,
-- lock), so the bare-SUPER row was never available. CTRL+SUPER was chosen
-- because it is already this config's "act on the neighbour" modifier -- its
-- arrows swap with the neighbour (custom/keybinds.lua, further down) -- so
-- focusing a neighbour and swapping with a neighbour now sit on the same
-- modifier. Verified free in hyprctl binds before binding.
do
    local vimkey = { "H", "J", "K", "L" }
    local focusdir = { "l", "d", "u", "r" }
    for i = 1, 4 do
        hl.unbind("CTRL + SUPER + " .. vimkey[i])
        hl.bind("CTRL + SUPER + " .. vimkey[i],
            hl.dsp.focus({ direction = focusdir[i] }),
            { description = "Window: Focus " .. vimkey[i] .. " (" ..
                ({ "left", "down", "up", "right" })[i] .. ")" })
    end
end

-- The original 40px-per-press resize, kept on SUPER+ALT+arrows. It now
-- duplicates what the plain SUPER+arrows above does, and that duplication is
-- intentional rather than an oversight: SUPER+ALT+arrow predates the plain
-- binding, and the config's own comments above tell the reader that
-- "SUPER + ALT + arrows ...... resize it, 40px per press" is the way windows
-- are handled by hand. Leaving it means nothing that was muscle memory stops
-- working, and it costs one line each.
hl.bind("SUPER + ALT + Right", hl.dsp.window.resize({ x = 40, y = 0, relative = true }),
    { repeating = true, description = "Window: Grow right" })
hl.bind("SUPER + ALT + Left", hl.dsp.window.resize({ x = -40, y = 0, relative = true }),
    { repeating = true, description = "Window: Grow left" })
hl.bind("SUPER + ALT + Down", hl.dsp.window.resize({ x = 0, y = -40, relative = true }),
    { repeating = true, description = "Window: Shrink up" })
hl.bind("SUPER + ALT + Up", hl.dsp.window.resize({ x = 0, y = 40, relative = true }),
    { repeating = true, description = "Window: Grow up" })

--#! Window
--# Show desktop
-- First press: you are taken to an empty desktop, so you see the bare desktop.
-- Second press: you are returned to the desktop you came from.
-- NOTHING is moved or resized at any point - the windows are simply left alone on
-- their own workspaces - so they come back exactly as they were, down to the tiling
-- order of every tile. (An earlier version moved every window to a hidden
-- workspace and moved them back, which re-tiled them in a different arrangement.)
-- The base config's maximize action moved to SUPER+ALT+D.
--
-- The pair "workspace you came from" / "the empty desktop we jumped to" is kept in
-- a file so it survives a config reload, and so pressing the key from somewhere
-- else starts a fresh show-desktop instead of jumping to a stale workspace.
local showDesktopPath = (os.getenv("HOME") or "/tmp") .. "/.cache/hypr-show-desktop"

local function readShowDesktop()
    local file = io.open(showDesktopPath, "r")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    local from, scratch = (content or ""):match("^(%S+)%s+(%S+)$")
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

hl.unbind("SUPER + D")
hl.bind("SUPER + D", function()
    -- REVERSED (requested): SUPER+D now opens the DESKTOPS OVERVIEW -- the
    -- zoomed-out grid every desktop drawn to scale -- which the 4-finger tap
    -- used to own; the tap took showDesktop over instead (routing in
    -- shell.qml). Both live in custom/popup.lua next to each other so the
    -- shared popup guard stays in one file. Plain navigation, no edit mode.
    popup.desktopsOverview()
end, { description = "Shell: Desktops overview (SUPER+D, was the 4-finger tap)" })

hl.bind("SUPER + ALT + D", hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" }),
    { description = "Window: Maximize" })

--# Screen snip
-- What SUPER+S used to be: "Workspace: Toggle scratchpad" (the base config showed
-- or hid a single special workspace, and SUPER+SHIFT+S sent the focused window
-- into it). Both of those still work on CTRL+SUPER+S (toggle) and
-- CTRL+SUPER+SHIFT+S (send) — see the base keybinds.
-- SUPER+S is now the region screenshot ("snip") the shell provides; it dims the
-- screen and lets you drag a selection, then opens the annotation editor.
hl.unbind("SUPER + S")
hl.bind("SUPER + S", hl.dsp.global("quickshell:regionScreenshot"), { description = "Utilities: Screen snip" })

-- SUPER+R is the quick record: starts a fullscreen wf-recorder capture
-- right away (no region picker) and the shell shows a small floating REC
-- pill while it runs. Pressing it again stops the recording. The pill also
-- answers clicks as a stop button.
hl.unbind("SUPER + R")
hl.bind("SUPER + R", hl.dsp.global("quickshell:recorderToggle"), { description = "Utilities: Quick record screen" })

--#! Window
--# Window controls menu (close / minimize / maximize)
-- Hyprland deliberately draws NO window decorations - no title bar, no buttons -
-- so real close/minimize/maximize buttons on the window need a compositor plugin
-- (hyprbars). This menu is the plugin-free equivalent: it acts on the window you
-- are looking at, from inside any application.
--
--   SUPER + ALT + Escape ... open the controls menu
--   SUPER + scroll down .... open it with the mouse
--
-- (SUPER + Escape opens the settings app.)
-- The menu is drawn by fuzzel, which this desktop already themes to match.
-- `$HOME`, never `~`: these run through `sh -c`, which does not expand a tilde,
-- so `~/....sh` was a file named `~` in the current directory, the exec failed
-- with "No such file or directory", and SUPER+ALT+Escape did nothing at all
-- while looking perfectly correct in this file.
hl.bind("SUPER + ALT + Escape", hl.dsp.exec_cmd("$HOME/.config/hypr/custom/scripts/window-controls.sh"),
    { description = "Window: Controls menu" })
hl.bind("SUPER + mouse:276", hl.dsp.exec_cmd("$HOME/.config/hypr/custom/scripts/window-controls.sh"),
    { description = "Window: Controls menu (mouse)" })

--# Settings
-- SUPER+Escape opens the shell's settings app -- the graphical one built from
-- settings.qml, the same window SUPER+I opens. CTRL+SHIFT+Escape opens the
-- shell's own task manager the same way.
--
-- The task manager is an OVERLAY surface of the main shell now
-- (modules/ii/taskManager/TaskManagerOverlay.qml), not a desktop window. That
-- is the whole reason it can be relied on to be in front: a client window is
-- on the Top layer, and a fullscreen client paints ABOVE every Top-layer
-- surface, so the old `qs -p` window could never cover one no matter what it
-- was told. The overlay is the same surface kind the bar and the switcher
-- already use over fullscreen.
--
-- It therefore opens over the shell's IPC socket rather than by launching a
-- process, and it carries the search string the old script accepted
-- (`task-manager.sh memory`) so the launcher and the settings tiles keep
-- working.
hl.bind("SUPER + Escape", hl.dsp.exec_cmd(settingsApp),
    { description = "App: Settings app" })

-- The task manager, as an overlay of the main shell (see the note above).
-- One body, two chords. CTRL+ALT+Escape is the Windows Task Manager
-- muscle-memory key people reach for without thinking; CTRL+SHIFT+Escape is
-- the chord this desktop already shipped. They toggle the SAME overlay, so
-- both are kept rather than replacing one with the other.
--
-- The body is a function, not a string command, because the release-
-- interrupt has to fire before the toggle. Writing it as a single
-- exec_cmd("a && b") would work today but hides the ordering requirement
-- in a shell string, which is exactly the sort of thing that silently
-- regresses when someone edits it later.
local function toggleTaskManager()
    -- SUPER is not involved here, but the release-interrupt is cheap and
    -- keeps a stray held modifier from opening the search panel on release.
    hl.exec_cmd(shellIpc("search toggleReleaseInterrupt"))
    -- The empty argument is NOT decoration: the handler is
    -- `function toggle(key: string)` (the argument is the page to deep-link
    -- to), and `qs ipc` runs its argument checks before the call reaches the
    -- shell, so `taskManager toggle` on its own is refused with "Too few
    -- arguments provided (1 required but 0 were provided)" and nothing
    -- happens. That is why the chord looked dead even where it was bound:
    -- measured 2026-11-12 by running the exact string this line builds.
    hl.exec_cmd(shellIpc("taskManager toggle ''"))
end

-- ── The stock bind on the SAME chord has to go first ────────────────────
-- hyprland/keybinds.lua binds CTRL + SHIFT + Escape to `taskManager` (its
-- generic system monitor: gnome-system-monitor, else btop in a terminal). Both
-- binds were registered -- `hyprctl binds` listed two entries with modmask 5 --
-- and the stock one is the one Hyprland fired, so the shell's own overlay
-- never came up and the chord opened a stranger's task manager instead (or
-- nothing at all when none of those programs is installed).
--
-- Unbound rather than deleted from hyprland/keybinds.lua on purpose: that file
-- is the shipped default the rest of this config is built on, and every other
-- override of it lives here beside its reason (SUPER + F, SUPER + P and the
-- mouse binds at the top of this file do the same thing).
hl.unbind("CTRL + SHIFT + Escape")

hl.bind("CTRL + SHIFT + Escape", toggleTaskManager,
    { description = "App: Task manager (always on top)" })
hl.bind("CTRL + ALT + Escape", toggleTaskManager,
    { description = "App: Task manager (CTRL+ALT+Escape)" })

--#! Session
--# Lock (SUPER+L, Windows-style)
-- SUPER+L LOCKS. It never ends the session, and nothing reachable from this
-- key may. Every app, every window and all of its state stays exactly where it
-- is behind the password prompt, and unlocking returns to the same picture --
-- like Win+L on Windows.
--
-- It was briefly bound to a logout instead, on the reading that "the lock
-- should be the real login screen". That was tried on a real session and the
-- cost is not theoretical: pressing it closed every app and the desktop came
-- back empty. A login screen cannot be shown over a live session on this
-- machine anyway (the greeter is Xorg on vt2 and sddm only starts
-- sddm-greeter when no session is running), so the honest way to get the
-- login screen's LOOK is to wear it, not to become it -- which is what the
-- lock surface does now: the same wallpaper the greeter draws, resolved
-- through the greeter's own config, so the two cannot drift apart.
--
-- Log out lives in the session menu, where it is labelled as ending the
-- session. Nothing else in this file may end the session either: a keybind is
-- one stray press away from a lost desktop, and a "fallback" that ends
-- Hyprland when the shell is not answering is exactly that. (One WAS added
-- here, to make the key survive the shell being down, and it destroyed a
-- session the moment it was pressed. `qs ipc call` exiting 255 is a nuisance;
-- it is not a licence to kill the compositor.)
--
-- THE LOCK IS THE SHELL'S OWN -- hyprlock is retired.
--
-- There used to be two lock screens with two designs and two sets of layout
-- files: hyprlock (a separate process) and the login screen (SDDM). They are
-- one screen now: the shell draws a full-screen Overlay-layer surface from the
-- SAME template list as the login (services/LoginLayouts.qml), on the login
-- screen's own picture (scripts/lock/greeter-backdrop.sh).
--
-- It is deliberately NOT a Wayland session lock. Quickshell hot-reloads its
-- whole QML tree on any watched file change, which used to kill a
-- session-lock surface mid-lock and make Hyprland paint its "the lockscreen
-- app died" fallback over the session -- which is exactly why hyprlock was
-- there in the first place. A LAYER surface has no such contract with the
-- compositor: a reload simply re-creates the window that was already
-- covering the screen. See modules/common/panels/lock/LockScreen.qml.
hl.unbind("SUPER + L")
hl.bind("SUPER + L", function()
    -- SUPER is still HELD while this runs, and its RELEASE lands after the
    -- lock is up -- an uninterrupted release opens the search panel on top of
    -- the lock, which looks exactly like "SUPER+L doesn't work". Same fix the
    -- SUPER gestures use: tell the shell this hold of SUPER was spent on
    -- something else.
    hl.exec_cmd(shellIpc("search toggleReleaseInterrupt"))
    hl.exec_cmd(shellIpc("lock activate"))
end, { description = "Session: Lock (the login screen's own screen; apps stay open)" })

-- ── Overrides, generated from Settings > Keybinds ────────────────────────────
-- Loaded last on purpose: it contains the shortcuts switched off in the settings
-- (as plain unbinds) and any you added yourself, so it wins over everything above.
-- The file is generated by scripts/keybinds/apply.sh; do not edit it by hand.
if is_file_exists(HOME .. "/.config/hypr/custom/keybind-overrides.lua") then
    require("custom.keybind-overrides")
end

-- ═══ Send-window-to-workspace chords: UNBOUND ════════════════════════════
-- The base config binds SUPER+ALT+<digit> (and the numpad twins, plus the
-- Page and wheel "send left/right" variants) to move the FOCUSED WINDOW to
-- another desktop. They are the only thing besides the SUPER+4-finger
-- gesture that moves a window across desktops, and they are silent: a
-- stray ALT (or a layout that emits "9" from some other key) teleports the
-- window away with no feedback, which is the "Freebuff randomly jumped to
-- desktop 9" report.
--
-- Per the desktop's own rule -- windows move ONLY by the SUPER + four-finger
-- gesture -- the whole family is unbound here. The workspace FOCUS chords
-- (SUPER+<digit>) are untouched. To bring the sends back, comment this block
-- out or keep the specific chord you want.
for i = 1, 10 do
    hl.unbind("SUPER + ALT + " .. (i % 10))
end
for _, code in ipairs({ 87, 88, 89, 83, 84, 85, 79, 80, 81, 90 }) do
    hl.unbind("SUPER + ALT + code:" .. code)
end
hl.unbind("SUPER + SHIFT + mouse_down")
hl.unbind("SUPER + SHIFT + mouse_up")
hl.unbind("SUPER + ALT + mouse_down")
hl.unbind("SUPER + ALT + mouse_up")
hl.unbind("SUPER + SHIFT + Page_Up")
hl.unbind("SUPER + SHIFT + Page_Down")
hl.unbind("SUPER + ALT + Page_down")
hl.unbind("SUPER + ALT + Page_up")
hl.unbind("CTRL + SUPER + SHIFT + Right")
hl.unbind("CTRL + SUPER + SHIFT + Left")

-- ── Every SUPER chord must silence the bare-SUPER action ──────────────
--
-- A bare SUPER tap opens the app search card ON RELEASE, and that release
-- fires unconditionally: "GlobalShortcut.onReleased in quickshell triggers
-- whether or not you press something else while holding the key" -- the
-- shell's own words, from the interrupt shortcut that exists for this reason.
-- So every chord has to say so out loud. Each chord below carries one extra
-- bind whose only job is to trip `search toggleReleaseInterrupt`, which clears
-- the shell's `superReleaseMightTrigger` and with it both the card-on-release
-- and the pending hold-SUPER-for-the-desktops timer (GlobalStates.qml: the
-- HOLD that reveals the desktops and the tap that opens the card cannot share
-- an edge without one of them being cancellable).
--
-- TWO BINDS ON ONE CHORD IS SAFE HERE -- verified on this build, not assumed:
-- a temporary second bind on SUPER+Period ran alongside the original (both
-- surfaces opened), so nothing below replaces or shadows a chord. An earlier
-- attempt used one `ignore_mods` bind per KEY to cover every modifier
-- combination with eight lines; it never fired, neither for the chord nor for
-- a bare key press, so the chords are listed exactly.
--
-- THIS BLOCK MUST STAY AT THE END OF THE FILE. `hl.unbind` takes the chord's
-- binds away and the re-bind that follows only puts back the action, so a
-- block placed further up is quietly erased for the twelve chords that are
-- re-bound later (D, L, R, S, the four arrows, CTRL+SUPER+H/J/K/L) -- measured
-- at 105 of 117 covered before it was moved down here.
--
-- The list is the live bind set: every bind whose modmask contains SUPER,
-- minus only the bare SUPER_L/SUPER_R holds (they ARE the hold, and cancelling
-- it from itself would make it impossible).
--
-- THE MOUSE CHORDS ARE IN HERE ON PURPOSE, and they matter more than they
-- look: SUPER+left-drag is a WINDOW RESIZE here, so a drag held past the hold
-- delay would otherwise raise the grid in the middle of the drag.
-- Four chords in it (V, Tab, Z, L) already interrupt in place further up;
-- the duplicate is harmless and keeps this a complete statement of the rule
-- rather than a list of exceptions to it. Regenerate by listing the same set:
--
-- NOTE, because this file has been edited by hand here: SUPER + Space BELONGS
-- in this list now that it is a chord (the toggle, bound further up). Without it,
-- the release after a SUPER+Space tap would look like an untouched SUPER hold
-- and open the app search a beat later -- the same job every other entry here
-- does, and the shell drops the same candidate on the chord's own press edge
-- (GlobalStates.superPressEdge), so the two agree either way round. Nothing but
-- chords and commas may live inside
-- the brackets: the loop below splits on commas and newlines, so a comment in
-- there becomes a bind of the comment's own text.
--
--   hyprctl binds -j | python3 -c "..."    (modmask & 64, key not SUPER_L/R)
local SUPER_CHORD_LIST = [[
ALT + SUPER + A, ALT + SUPER + D, ALT + SUPER + Down, ALT + SUPER + Equal,
ALT + SUPER + Escape, ALT + SUPER + F, ALT + SUPER + F11, ALT + SUPER + F12,
ALT + SUPER + H, ALT + SUPER + Left, ALT + SUPER + M, ALT + SUPER + R,
ALT + SUPER + Right, ALT + SUPER + S, ALT + SUPER + Space, ALT + SUPER + Tab,
ALT + SUPER + Up, CTRL + ALT + SUPER + Left, CTRL + ALT + SUPER + Right,
CTRL + ALT + SUPER + Slash, CTRL + ALT + SUPER + T, CTRL + SUPER + B,
CTRL + SUPER + Backslash, CTRL + SUPER + BracketLeft, CTRL + SUPER + BracketRight,
CTRL + SUPER + Down, CTRL + SUPER + H, CTRL + SUPER + J, CTRL + SUPER + K,
CTRL + SUPER + L, CTRL + SUPER + Left, CTRL + SUPER + M, CTRL + SUPER + P,
CTRL + SUPER + Page_Down, CTRL + SUPER + Page_Up, CTRL + SUPER + R,
CTRL + SUPER + Right, CTRL + SUPER + S, CTRL + SUPER + T, CTRL + SUPER + Up,
CTRL + SUPER + V, CTRL + SUPER + mouse_down, CTRL + SUPER + mouse_up,
SHIFT + ALT + SUPER + Q, SHIFT + ALT + SUPER + R, SHIFT + ALT + SUPER + S,
SHIFT + ALT + SUPER + Slash, SHIFT + ALT + SUPER + mouse:273,
SHIFT + ALT + SUPER + mouse:275, SHIFT + ALT + SUPER + mouse:276,
SHIFT + CTRL + ALT + SUPER + Delete, SHIFT + CTRL + ALT + SUPER + W,
SHIFT + CTRL + SUPER + B, SHIFT + CTRL + SUPER + D, SHIFT + SUPER + A,
SHIFT + SUPER + B, SHIFT + SUPER + C, SHIFT + SUPER + Down, SHIFT + SUPER + G,
SHIFT + SUPER + H, SHIFT + SUPER + L, SHIFT + SUPER + Left, SHIFT + SUPER + M,
SHIFT + SUPER + N, SHIFT + SUPER + P, SHIFT + SUPER + R, SHIFT + SUPER + Right,
SHIFT + SUPER + S, SHIFT + SUPER + T, SHIFT + SUPER + Up, SHIFT + SUPER + W,
SHIFT + SUPER + X, SUPER + 0, SUPER + 1, SUPER + 2, SUPER + 3, SUPER + 4, SUPER + 5,
SUPER + 6, SUPER + 7, SUPER + 8, SUPER + 9, SUPER + A, SUPER + Apostrophe, SUPER + B,
SUPER + Space, SUPER + BracketLeft, SUPER + BracketRight, SUPER + C, SUPER + D, SUPER + Down,
SUPER + E, SUPER + Equal, SUPER + Escape, SUPER + F, SUPER + G, SUPER + I, SUPER + J,
SUPER + K, SUPER + L, SUPER + Left, SUPER + M, SUPER + Minus, SUPER + N, SUPER + O,
SUPER + P, SUPER + Page_Down, SUPER + Page_Up, SUPER + Period, SUPER + Q, SUPER + R,
SUPER + Return, SUPER + Right, SUPER + S, SUPER + Semicolon, SUPER + Slash, SUPER + T,
SUPER + Tab, SUPER + Up, SUPER + V, SUPER + W, SUPER + X, SUPER + Z, SUPER + mouse:273,
SUPER + mouse:275, SUPER + mouse:276, SUPER + mouse_down, SUPER + mouse_up
]]

for raw in SUPER_CHORD_LIST:gmatch("[^,\n]+") do
    -- A separate local on purpose: this config runs on Luau, where the loop
    -- variable is const and trimming it in place is a load-time error (the
    -- whole file after it silently stops registering -- found the hard way).
    local chord = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if chord ~= "" then
        -- The description is the same on purpose: it makes the whole set one
        -- greppable answer to "is this chord covered?" in `hyprctl binds` and
        -- in the shell's own bind listing.
        hl.bind(chord, hl.dsp.global("quickshell:searchToggleReleaseInterrupt"),
            { description = "Shell: SUPER chord (cancels the bare-SUPER action)" })
    end
end

--#! Panel
-- ── Panel care: the OLED's two knobs ────────────────────────────────────────
-- This display is a Samsung OLED (eDP-1, 2560x1600). Every pixel emits, and
-- every pixel ages in proportion to how hard and how long it has been driven,
-- so a large bright field held in one place leaves a ghost -- first temporary
-- retention, then burn-in. The desktop cannot make an app not be bright, and it
-- must not touch the brightness dial, which is the user's own choice. What it
-- CAN do, through the compositor's screen shader, is cap the peak and even out
-- what is already there. custom/scripts/panel-care.py is the controller and its
-- docstring is the long version; these are the two gestures.
--
-- The ceiling is applied at login and on every reload by execs.lua, so it is
-- already on and this chord is the off switch, not the on switch.
hl.bind("SUPER + SHIFT + O",
    hl.dsp.exec_cmd("$HOME/.config/hypr/custom/scripts/panel-care.py toggle"),
    { description = "Panel: toggle the OLED peak ceiling" })

-- A flat, uniform field for four minutes -- deliberately under the five-minute
-- idle dim in hypridle.conf, because a wash at 1% backlight is not a wash.
-- Pressing the same chord again stops it early: the script reads a second call
-- while a wash is running as the cancel gesture, so two can never overlap.
hl.bind("SUPER + SHIFT + ALT + O",
    hl.dsp.exec_cmd("$HOME/.config/hypr/custom/scripts/panel-care.py wash"),
    { description = "Panel: even out retention (uniform wash, 4 min)" })

--#! Dictation
-- Hold to talk: hold the key, speak, let go, and the words are typed at the
-- cursor of whatever has focus. The Linux stand-in for Wispr Flow -- local
-- whisper.cpp, no account, no API key, nothing leaves the machine
-- (custom/scripts/dictate.sh has the pipeline and the settings).
--
-- THE KEY, and why it is not Fn: Fn cannot be bound on this laptop. It never
-- reaches the kernel at all -- no input device in /proc/bus/input/devices
-- advertises KEY_FN, so there is no keycode for Hyprland, a remapper or
-- anything else to see; the firmware handles it and swallows it. Control_R is
-- the nearest key that DOES reach Linux, it sits beside Fn on this keyboard,
-- and nothing else here uses it. Moving it is one edit: put any keysym in both
-- binds below ("Caps_Lock", "Alt_R", "F9"...).
--
-- NO BINDS FOR THIS, deliberately. Every Hyprland bind on SUPER fires for
-- chords as well: `ignore_mods` matches SUPER+Q too, and `long_press` on this
-- build's Lua binding is dropped on the floor (it registers as a plain bind --
-- verified with hyprctl), so a bind here would either record through every
-- SUPER chord or never fire at all.
--
-- The detector therefore lives below the compositor: scripts/dictate-daemon.py
-- reads the keyboard devices directly and arms only when SUPER is held ALONE
-- past a threshold -- any other key cancels it, so SUPER+Q, SUPER+numbers,
-- SUPER+drag and SUPER+tap (search) are untouched. Nothing here for the
-- compositor to mis-handle, and no way for a chord to leave a recorder running.
--
-- Start it with execs.lua; the island's recording pill is in
-- modules/ii/bar/NowBar.qml.
local dictate = nil -- (kept as a name for the next reader: see above)

--#! Shell
-- TAB belongs to the focused application: it moves between form fields, indents
-- code, steps through a table's cells. Nothing on this desktop may own the bare
-- key. The one bind that used to is described above -- an `ignore_mods` release
-- bind, which by definition also matched with no modifiers held.
--
-- This is the standing guarantee, re-asserted on every load instead of trusted
-- to the absence of a mistake. It runs LAST in this file, so any bare-TAB bind
-- registered before it -- here, in custom/general.lua, or in the vendored base
-- config -- is dropped before the compositor starts answering keys. It is a
-- no-op when there is nothing to remove, and it cannot touch the modifier
-- chords above: Alt+Tab and SUPER+Tab are binds under a different key string,
-- not this one.
hl.unbind("Tab")
