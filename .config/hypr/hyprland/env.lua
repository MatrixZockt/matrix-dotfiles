local home_dir = os.getenv("HOME")

-- Wayland
hl.env("ELECTRON_OZONE_PLATFORM_HINT", "auto")

-- Applications
local xdg_data_dirs_old = os.getenv("XDG_DATA_DIRS") or ""
hl.env("XDG_DATA_DIRS", home_dir .. "/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share:" .. xdg_data_dirs_old)

-- Themes
hl.env("QT_QPA_PLATFORM", "wayland;xcb")
-- This was "kde". There is no KDE platform-theme plugin on this machine --
-- /usr/lib/qt6/plugins/platformthemes/ holds exactly libqgtk3.so and
-- libqxdgdesktopportal.so -- so the name resolved to nothing and Qt silently
-- fell back to its own default style, which is LIGHT. Every Qt app on the
-- desktop was therefore light regardless of what gsettings said, and no later
-- change could fix it: the platform theme is read once, at startup, from the
-- environment, and this is the environment every Hyprland-spawned process
-- inherits (including the shell, so the shell's own launcher passed it on too).
--
-- "gtk3" is also installed and is NOT the answer either. Measured on this
-- machine with a probe that builds a QApplication and prints
-- styleHints()->colorScheme() plus the resolved widget palette:
--
--     kde             -> colorScheme=Unknown  widgetPalette=LIGHT (0.937)
--     gtk3            -> colorScheme=Light    widgetPalette=LIGHT (0.977)
--     xdgdesktopportal-> colorScheme=Dark     widgetPalette=DARK  (0.196)
--
-- so QGtk3Theme never reports dark here (it does not pick the GTK dark flag up
-- into colorScheme), while QXdgDesktopPortalTheme reads
-- org.gnome.desktop.interface color-scheme through the portal and does -- and
-- it re-reads it, so a Qt app also follows a live theme switch rather than only
-- the state at startup. It is the plugin that makes the shell's single
-- light/dark decision (scripts/colors/sync-desktop-theme.sh) reach Qt.
hl.env("QT_QPA_PLATFORMTHEME", "xdgdesktopportal")
hl.env("XDG_MENU_PREFIX", "plasma-")

-- Cursor theme.
--
-- This is what actually decides whether a Qt app can draw a hand.
--
-- On Wayland a client does not render the cursor image itself: it asks the
-- compositor to change the SHAPE (`wp_cursor_shape_manager_v1`, which Hyprland
-- does advertise -- verified against this session's globals), and the
-- compositor looks the image up in ITS theme. Qt only sends a shape once it can
-- resolve that shape to a name inside a cursor theme it has actually loaded.
--
-- With XCURSOR_THEME unset, Qt loads no theme and falls back to a built-in one
-- that has nothing but the default arrow. Every `cursorShape` in the shell --
-- including the to-do row's drag grip and the 67 `PointingHandCursor` buttons
-- -- was therefore silently dropped, no matter what it asked for. The binding
-- was never wrong; Qt had no icon to send.
--
-- Named to the STOCK Bibata themes, installed under ~/.local/share/icons/ by
-- the v2.0.7 release, KEYLINE INCLUDED. Bibata-Modern-Ice is the white pointer
-- with its black rim -- the classic Bibata look. The borderless "-NoLine"
-- variants built on 2026-10-04 were removed on request (2026-10-22: "i want it
-- back to normal with the clean classic black border"): a solid pointer with no
-- rim is a different cursor, not a cleaner one, and the switch between the two
-- read as the cursor changing colour under the hand.
--
-- The previous note here said the Bibata names "do not exist anywhere on this
-- system" -- true when written, false since they were installed.
--
-- WHY THIS VARIABLE AND NOT `hyprctl setcursor`. setcursor is a no-op on this
-- build: it answers "ok" for any name, including ones that do not exist, and
-- the pointer never changes. Verified by diffing a `grim -c` capture against a
-- plain `grim` capture of the same region -- three different themes gave
-- byte-identical silhouettes -- and by `hyprctl getcursor` not existing and
-- `hl.config({cursor = {theme = ...}})` being rejected as an unknown key.
-- XCURSOR_THEME is the thing that actually resolves the cursor.
--
-- Read once, at startup, like QT_QPA_PLATFORMTHEME above -- which is why
-- changing the theme later requires the app to be restarted. The dark/light
-- switch is written by scripts/colors/sync-desktop-theme.sh.
hl.env("XCURSOR_THEME", "Bibata-Modern-Ice")

-- Virtual environment
hl.env("ILLOGICAL_IMPULSE_VIRTUAL_ENV", home_dir .. "/.local/state/quickshell/.venv")
