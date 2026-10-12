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

-- File manager, on SUPER + E: the shell's own Files app -- the QML file
-- manager (explorer-shaped: drives, tabs, details/tiles).
--
-- This line used to point at the GTK Explorer in ~/.local/bin/hypr-explorer,
-- and because an override here REPLACES the base line, SUPER + E kept opening
-- that app no matter what the base config said. The base default is this same
-- value; the override is kept (rather than deleted) so the file says which
-- program the key is meant to open. Through the launch script like the
-- settings app: a copy that is already open is raised instead of a second one
-- being started. The classic file managers are the fallback, so the key is
-- never dead.
fileManager = "$HOME/.config/quickshell/$qsConfig/scripts/launch/filemanager.sh || $HOME/.config/hypr/hyprland/scripts/launch_first_available.sh 'dolphin' 'nautilus' 'nemo' 'thunar'"

-- Settings app, on SUPER + ESCAPE (and wherever the shell's own buttons open it).
--
-- Through the script instead of `qs -p ~/.config/quickshell/$qsConfig/settings.qml`
-- directly: the script first asks a copy that is already open to walk to the page
-- that was asked for, and only starts one when there is nothing to ask. A bare
-- `qs -p` meant a new window every press, which is how the desktop ended up with
-- several settings windows stacked on each other.
settingsApp = "$HOME/.config/quickshell/$qsConfig/scripts/launch/settings.sh"

-- workspaceGroupSize = 10
