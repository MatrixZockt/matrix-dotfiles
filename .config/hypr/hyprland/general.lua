-- MONITOR CONFIG
hl.monitor({
    output = "",
    mode = "preferred",
    position = "auto",
    scale = 1
})

-- Local change (was: a generic three-finger swipe that moved windows).
--
-- Three fingers now have a JOB: down pops the top bar's middle island out into
-- its panel, up puts it back (custom/general.lua). A generic three-finger
-- gesture cannot coexist with directional ones -- the parser reports
-- "previous SWIPE shadows new DOWN" and the directional binding never fires --
-- so the generic one is removed here and the directional pair is registered in
-- the custom file, exactly the way the four-finger pair already is.
--
-- Losing "move" costs nothing on this desktop: window dragging was removed
-- outright (see custom/keybinds.lua's "No mouse dragging" and the SUPER-drag
-- follow gesture), so a three-finger window-drag was the last stray way to
-- shove a window around by touch. Three-finger pinch still toggles fullscreen.
hl.gesture({
    fingers = 3,
    direction = "pinch",
    action = "fullscreen"
})
hl.gesture({
    fingers = 4,
    direction = "horizontal",
    action = "workspace"
})
-- Local change (was: both directions toggled the overview):
--   four fingers down -> close the focused window
-- Four fingers up: UNBOUND here on purpose -- it is bound in
-- custom/general.lua instead, which does the same fullscreen toggle for a
-- window but also makes an open popup app (settings / task manager) morph
-- into a real fullscreen-capable window. Registering both had the base one
-- shadowing the custom one ("previous UP shadows new UP") and the morph
-- never fired.
-- Four fingers down: UNBOUND on purpose.
--
-- This was Hyprland's built-in "close" gesture (the window follows your fingers
-- down and closes if you let go past the threshold). It is removed because
-- closing is already SUPER+Q, and a swipe that can close a window is easy to
-- trigger by accident while scrolling. Four fingers sideways still switches
-- desktop; nothing is bound to down now.

hl.config({
    gestures = {
        workspace_swipe_distance = 500,
        workspace_swipe_cancel_ratio = 0.2,
        workspace_swipe_min_speed_to_force = 5,
        workspace_swipe_direction_lock = true,
        workspace_swipe_direction_lock_threshold = 10,
        -- Desktop creation from a plain swipe: ON.
        --
        -- This was false on purpose -- a plain swipe could only land on a
        -- desktop that already existed, and creation was reserved for SUPER
        -- plus the same four-finger swipe (custom/general.lua,
        -- moveWindowToNeighbour). The cost was that the trailing "+" slot in
        -- the bottom desktop pill was UNREACHABLE by swiping: it is the only
        -- affordance for adding a desktop in the pill, so a user who drives
        -- the desktop with gestures could look at a "+" and have no gesture
        -- that lands on it. Requested 2026-09-30: a swipe past the last
        -- desktop should make that desktop, exactly as the pill's "+" already
        -- does when clicked.
        --
        -- The old "jumped to desktop 9" bug that motivated turning this off
        -- was never the gesture's fault -- the bar was rendering the LOCK
        -- SCREEN's sentinel workspace (2147483647 - N) as a phantom desktop,
        -- and WorkspaceModel.isSaneWorkspaceId now clamps every id to 1..100
        -- before the bar sees it. That is fixed at the source, so it no
        -- longer argues against creation here.
        --
        -- KNOWN CONSEQUENCE, and it is intended: desktop-edge.py's
        -- creates_its_own() reads THIS option, so the right edge is no longer
        -- a dead edge. The LEFT edge is the only one left with nowhere to
        -- go -- there is no id below 1 for Hyprland to create -- and a swipe
        -- into it is answered by the Quickshell desktop pill flashing, not
        -- by anything moving.
        workspace_swipe_create_new = true,
        -- NO `workspace_swipe_from_top` HERE, and that is a measured fact
        -- rather than an omission.
        --
        -- This build rejects the key outright:
        --   Your config has errors:
        --   general.lua:48: unknown config key 'gestures.workspace_swipe_from_top'
        --
        -- Every sibling key in this same block resolves
        -- (workspace_swipe_distance, _cancel_ratio, _min_speed_to_force,
        -- _direction_lock, _create_new, workspace_swipe_invert), and
        -- `hyprctl getoption gestures:workspace_swipe_from_top` answers "no
        -- such option", so the option does not exist in this Hyprland at all.
        --
        -- It was written here on 2026-10-03 as a belt against the top-edge
        -- workspace swipe reaching past the bar, and it cost more than it
        -- bought: Hyprland refuses the config on an unknown key, which takes
        -- the WHOLE config with it -- including every hl.gesture in
        -- custom/general.lua. That is why the three-finger swipe-down stopped
        -- working while this line was present.
        --
        -- The thing that actually keeps a bar-aimed swipe off the app behind
        -- the bar is `cursorOnMiddleBar()` in custom/general.lua, which needs
        -- no such option and is verified against the real cursor position.
        -- If a future Hyprland grows the option, add it HERE and re-read the
        -- reload output -- do not add it and assume.
    },
    general = {
        -- Gaps and border
        gaps_in = 4,
        gaps_out = 5,
        gaps_workspaces = 50,

        border_size = 1,

        col = {
            active_border = "rgba(0DB7D42A)",
            inactive_border = "rgba(31313600)"
        },
        resize_on_border = true,

        no_focus_fallback = true,
        allow_tearing = true, -- This just allows the `immediate` window rule to work
        snap = {
            enabled = true,
            window_gap = 4,
            monitor_gap = 5,
            respect_gaps = true
        }
    },
    decoration = {
        -- 2 = circle, higher = squircle, 4 = very obvious squircle
        -- Fuck clearly visible squircles. 100% Apple brainrot.
        rounding_power = 2.5,
        -- Tuned down from 18 to match the shell's own rounding (Appearance
        -- rounding.windowRounding = 12): windows and their decorations should
        -- sit in the same shape family as every button and card in the shell.
        rounding = 12,

        blur = {
            enabled = true,
            -- xray = true samples the WALLPAPER ONLY and pastes it as the blur
            -- source -- windows behind a blurred layer simply vanish from it.
            -- That was exactly the "the veil shows the flat background, not my
            -- open apps" complaint. With xray off the blur samples what is
            -- actually rendered behind the surface, windows included.
            xray = false,
            special = false,
            new_optimizations = true,
            -- Lighter blur: 4 -> 8px, 3 -> 2 passes. The popup veils sit at
            -- 90% transparency now, so a heavy stack behind them was the
            -- "very laggy" half of the popup complaint -- a full-screen
            -- 3-pass blur recomputed on every frame the veil is up. Same
            -- look at a third of the cost.
            size = 8,
            passes = 2,
            brightness = 1,
            noise = 0.05,
            contrast = 0.89,
            vibrancy = 0.5,
            vibrancy_darkness = 0.5,
            popups = false,
            popups_ignorealpha = 0.6,
            input_methods = true,
            input_methods_ignorealpha = 0.8
        },
        shadow = {
            enabled = true,
            range = 20,
            offset = {0, 2},
            render_power = 10,
            color = "rgba(00000020)"

        },
        -- Dim
        dim_inactive = true,
        dim_strength = 0.05,
        dim_special = 0.2
    },
    animations = {
        enabled = true
    },
    dwindle = {
        preserve_split = true,
        -- ON (was: false, 2026-09-29). The three-finger field swipe asks the
        -- tiler to push the focused window into the space a swipe points at.
        -- With smart_split off, a move into a direction that has nothing in it
        -- is silently dropped -- the tiler has no gap to insert into, so the
        -- swipe looked like it "only moved the cursor". With it on, the drop
        -- splits the window it lands on, which is what makes a swipe change
        -- positions and sizes instead of just focus.
        -- Stays off. It was turned on for the three-finger field swipe (a move
        -- into a direction with nothing in it is dropped without it), but the
        -- value does not survive a reload on this build: with the block and
        -- with a separate hl.config() call beside it, `getoption
        -- dwindle:smart_split` still reads `bool: false` after a reload and
        -- only flips from a live call. Nothing depends on it any more --
        -- FIELD_SWIPE reaches every layout it needs with a directional move
        -- (tiler-valid) and an absolute resize (also tiler-valid), both
        -- verified by watching the geometry change.
        smart_split = false,
        smart_resizing = false
        -- precise_mouse_move = true,
    },
})
-- Curves
hl.curve("expressiveFastSpatial", {
    type = "bezier",
    points = {{0.42, 1.67}, {0.21, 0.90}}
})
hl.curve("expressiveSlowSpatial", {
    type = "bezier",
    points = {{0.39, 1.29}, {0.35, 0.98}}
})
hl.curve("expressiveDefaultSpatial", {
    type = "bezier",
    points = {{0.38, 1.21}, {0.22, 1.00}}
})
hl.curve("emphasizedDecel", {
    type = "bezier",
    points = {{0.05, 0.7}, {0.1, 1}}
})
hl.curve("emphasizedAccel", {
    type = "bezier",
    points = {{0.3, 0}, {0.8, 0.15}}
})
hl.curve("standardDecel", {
    type = "bezier",
    points = {{0, 0}, {0, 1}}
})
hl.curve("menu_decel", {
    type = "bezier",
    points = {{0.1, 1}, {0, 1}}
})
hl.curve("menu_accel", {
    type = "bezier",
    points = {{0.52, 0.03}, {0.72, 0.08}}
})
hl.curve("stall", {
    type = "bezier",
    points = {{1, -0.1}, {0.7, 0.85}}
})
-- Configs
-- windows
hl.animation({
    leaf = "windowsIn",
    enabled = true,
    speed = 3,
    bezier = "emphasizedDecel",
    style = "popin 80%"
})
hl.animation({
    leaf = "fadeIn",
    enabled = true,
    speed = 3,
    bezier = "emphasizedDecel"
})
hl.animation({
    -- Window close: tightened from 2 to 3.2 -- a close should be decisive;
    -- a slow one reads as the machine thinking about it.
    leaf = "windowsOut",
    enabled = true,
    speed = 3.2,
    bezier = "emphasizedDecel",
    style = "popin 90%"
})
hl.animation({
    -- Matches the tightened windowsOut so opacity and scale finish together.
    leaf = "fadeOut",
    enabled = true,
    speed = 3.2,
    bezier = "emphasizedDecel"
})
hl.animation({
    -- Window moves/tiles/reflows: tightened from 3 to 4 -- a snappier settle
    -- that still reads as motion, not a cut. (Speed is inversely proportional
    -- to duration: higher = shorter.)
    leaf = "windowsMove",
    enabled = true,
    speed = 4,
    bezier = "emphasizedDecel",
    style = "slide"
})
hl.animation({
    leaf = "border",
    enabled = true,
    speed = 10,
    bezier = "emphasizedDecel"
})

-- layers
hl.animation({
    leaf = "layersIn",
    enabled = true,
    speed = 2.7,
    bezier = "emphasizedDecel",
    style = "popin 93%"
})
hl.animation({
    leaf = "layersOut",
    enabled = true,
    speed = 2.4,
    bezier = "menu_accel",
    style = "popin 94%"
})
-- fade
hl.animation({
    leaf = "fadeLayersIn",
    enabled = true,
    speed = 0.5,
    bezier = "menu_decel"
})
hl.animation({
    leaf = "fadeLayersOut",
    enabled = true,
    speed = 2.7,
    bezier = "stall"
})
-- workspaces
hl.animation({
    -- Workspace slide: tightened from 7 to 9 -- desktop switching should be a
    -- flick, not a ride.
    leaf = "workspaces",
    enabled = true,
    speed = 9,
    bezier = "menu_decel",
    style = "slide"
})
-- specialWorkspace
hl.animation({
    leaf = "specialWorkspaceIn",
    enabled = true,
    speed = 2.8,
    bezier = "emphasizedDecel",
    style = "slidevert"
})
hl.animation({
    leaf = "specialWorkspaceOut",
    enabled = true,
    speed = 1.2,
    bezier = "emphasizedAccel",
    style = "slidevert"
})
-- zoom
hl.animation({
    leaf = "zoomFactor",
    enabled = true,
    speed = 3,
    bezier = "standardDecel"
})

hl.config({
    -- The tray vault, declared.
    --
    -- `TRAY_VAULT` in custom/general.lua parks a tray-managed window here,
    -- and it was the ONLY reference to this workspace anywhere in the
    -- config -- nothing declared it. Hyprland then created it implicitly,
    -- the first time something was parked on it, which leaves it
    -- non-persistent and absent from the workspace list until that moment.
    --
    -- An implicitly-created special workspace is a poor place to keep
    -- something: it does not exist until it is first used, it is torn down
    -- again when it empties, and it is not part of the declared set, so
    -- anything that walks or cycles the declared workspaces does not know
    -- it is there. Declaring it persistent means the vault is a real,
    -- permanent workspace from the moment the compositor starts: it cannot
    -- be swept up by workspace gestures, and it cannot be collected and
    -- dissolved out from under a window that is parked in it.
    workspace = {
        "special:tray, persistent:true"
    },

    input = {
        kb_layout = "us", -- overridden to "de" in custom/general.lua
        numlock_by_default = true,
        repeat_delay = 250,
        repeat_rate = 35,

        follow_mouse = 1,
        off_window_axis_events = 2,

        touchpad = {
            natural_scroll = true,
            disable_while_typing = true,
            clickfinger_behavior = true,
            scroll_factor = 0.7
        }
    },

    misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        vrr = 0,
        mouse_move_enables_dpms = true,
        key_press_enables_dpms = true,
        animate_manual_resizes = false,
        animate_mouse_windowdragging = false,
        enable_swallow = false,
        swallow_regex = "(foot|kitty|allacritty|Alacritty)",
        on_focus_under_fullscreen = 2,
        allow_session_lock_restore = true,
        session_lock_xray = true,
        initial_workspace_tracking = false,
        focus_on_activate = true
    },

    binds = {
        scroll_event_delay = 0,
        hide_special_on_workspace_change = true
    },

    cursor = {
        zoom_factor = 1,
        zoom_rigid = false,
        zoom_disable_aa = true,
        hotspot_padding = 1
    },

    -- THIS VALUE IS OVERRIDDEN, deliberately, by custom/general.lua (loaded
    -- after this file), which sets force_zero_scaling = true again.
    --
    -- The history here matters, because both settings were tried and both
    -- were rejected for a while: force_zero_scaling=true made Hyprland report
    -- logical == physical to every X11 client, so XWayland apps (TradingView,
    -- Steam, old GTK/Java apps) rendered at 1:1 while everything else was at
    -- 1.6 -- they looked tiny and unscaled next to the rest of the desktop,
    -- which is why it was turned off here. But false is not neutral either: it
    -- makes XWayland's root window the LOGICAL size (1707x1067) and has the
    -- compositor upscale every X11 window by 1.5 to fill the panel -- with
    -- xwayland:use_nearest_neighbor on, that upscale drops pixels rather than
    -- filtering them, so X11 apps came out pixelated (uneven glyph stems,
    -- 1px lines alternating between 1px and 2px). Measured, see
    -- custom/general.lua.
    --
    -- The way out of the either/or is to render X11 apps natively (true) AND
    -- tell their toolkits the DPI so they are still the right size:
    -- custom/scripts/x11-dpi.sh writes Xft.dpi (144 at scale 1.5), and
    -- custom/env.lua exports the X11-app scale for Steam and Qt. That is what
    -- custom/general.lua now does, so this block is effectively documentation
    -- of the base config's default rather than the value in force.
    xwayland = {
        force_zero_scaling = false
    }
})
