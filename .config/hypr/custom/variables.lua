-- Override the base variables (which apps the keybinds launch, workspace count, ...).
-- The defaults live in hyprland/variables.lua — copy a line from there to change it.
--
-- NOTE: an entry here REPLACES the base default, it does not merge with it. A
-- stale override silently undoes a change made in the base file — that is how
-- SUPER + E kept opening dolphin after the QML file manager became the default.

-- Task manager, on CTRL + SHIFT + ESCAPE (and wherever the shell opens it).
--
-- Through the launch script, like the settings app: the script asks a copy that
-- is already open to re-scroll to the section that was asked for, and only
-- starts one when there is nothing to ask. The app itself is the shell's own
-- taskmanager.qml -- a full-screen frosted card showing the hardware specs --
-- which replaced both the overlay card (which read as a game overlay) and
-- mission-center (an external app that only knew Windows' idea of specs).
taskManager = "$HOME/.config/quickshell/$qsConfig/scripts/launch/task-manager.sh"

-- File manager, on SUPER + E: the Explorer app (~/.local/bin/hypr-explorer,
-- sources in ~/.local/lib/hypr-explorer). A regular GTK4 desktop window -- the
-- config's catch-all rule keeps it tiled, so it attaches like every other
-- application instead of being a layer popup. The same binary serves the
-- portal's picker mode (the file-chooser dialogs every app opens).
fileManager = "$HOME/.local/bin/hypr-explorer"

-- Settings app, on SUPER + ESCAPE (and wherever the shell's own buttons open it).
--
-- Through the script instead of `qs -p ~/.config/quickshell/$qsConfig/settings.qml`
-- directly: the script first asks a copy that is already open to walk to the page
-- that was asked for, and only starts one when there is nothing to ask. A bare
-- `qs -p` meant a new window every press, which is how the desktop ended up with
-- several settings windows stacked on each other.
settingsApp = "$HOME/.config/quickshell/$qsConfig/scripts/launch/settings.sh"

-- workspaceGroupSize = 10
