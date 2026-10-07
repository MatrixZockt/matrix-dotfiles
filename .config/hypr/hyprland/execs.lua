-- put former exec-once commands inside the func and former exec commands outside
hl.on("hyprland.start", function ()

    -- Bar, wallpaper
    hl.exec_cmd("$HOME/.config/hypr/hyprland/scripts/start_geoclue_agent.sh")
    -- Through the shell's own launcher instead of a bare `qs -c $qsConfig`:
    -- the launcher is idempotent (a live `qs -c ii` makes it exit), so this and
    -- the same call in custom/execs.lua can never stack two bars, and it logs
    -- to /tmp/ii_shell.log, which is the only way to see *why* the shell failed
    -- if it ever does. Booting into a compositor with no bar and no sidebars is
    -- indistinguishable from "my Hyprland configs stopped loading", and that is
    -- exactly what a bare `qs` doing nothing looks like.
    hl.exec_cmd("$HOME/.config/quickshell/ii/scripts/launch/shell.sh")
    -- Through `bash`, not run directly. switchwall.sh regenerates this file
    -- whenever the wallpaper changes, and the still-image branch of it wrote the
    -- file without the executable bit -- so running it directly failed at login
    -- ("Permission denied") and a video wallpaper never came back. An
    -- interpreter does not need the bit, so this cannot break again.
    hl.exec_cmd("bash $HOME/.config/hypr/custom/scripts/__restore_video_wallpaper.sh")

    -- Core components (authentication, lock screen, notification daemon)
    hl.exec_cmd("gnome-keyring-daemon --start --components=secrets")
    -- hypridle has been observed to SIGABRT on resume; respawn it if it dies.
    hl.exec_cmd("bash -c 'while :; do hypridle; sleep 3; done' & disown")

    -- NO audio guard here. This used to run a `while :` loop that started
    -- pipewire / pipewire-pulse / wireplumber with `setsid` whenever they were
    -- not found running. It was written for the 2026-09-16 case where the
    -- systemd user manager died 33s into the session and took the audio units
    -- with it -- but it solved that by fighting systemd, and it lost:
    --
    --   * systemd's own pipewire.service / pipewire.socket / pipewire-pulse.socket
    --     went to `failed (Result: start-limit-hit)` -- they could never start,
    --     because a daemon was already running outside their supervision;
    --   * the guard's copies raced each other. Every new instance unlinked and
    --     recreated /run/user/1000/pipewire-0, so the socket *file* ended up
    --     belonging to a dead server while the live one held the old, unlinked
    --     inode. Every client that connected to the path got errno 112
    --     (EHOSTDOWN, "Host is down") -- including `wpctl`, which is what the
    --     volume keys run, and the shell's own Audio service;
    --   * the loop was immortal and duplicated (three copies were alive), so
    --     the mess grew across loads and never healed.
    --
    -- The supervision belongs to systemd, and the resilience the guard was
    -- reaching for now lives there too: Restart=always with no start limit, via
    -- the drop-ins in ~/.config/systemd/user/{pipewire,pipewire-pulse,wireplumber}.service.d/
    -- (see those files for the full story). That restarts the stack if it dies
    -- AND leaves the sockets owned by whoever is actually serving them.
    hl.exec_cmd("dbus-update-activation-environment --all")
    hl.exec_cmd("sleep 1 && dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP") -- Some fix idk

    -- Audio (only if easyeffects is actually installed; otherwise this logged an
    -- "command not found" on every single login)
    hl.exec_cmd("command -v easyeffects >/dev/null 2>&1 && easyeffects --hide-window --service-mode")

    -- Clipboard: history
    --hl.exec_cmd("wl-paste --watch cliphist store")
    hl.exec_cmd("wl-paste --type text --watch bash -c 'cliphist store && qs -c $qsConfig ipc call cliphistService update'")
    hl.exec_cmd("wl-paste --type image --watch bash -c 'cliphist store && qs -c $qsConfig ipc call cliphistService update'")

    -- ydotoold: the virtual-input daemon the clipboard's paste needs. Without it
    -- every Ctrl+V synthesis dies with "Connection refused" and clicking a
    -- clipboard entry does nothing visible. Nothing else on the system started
    -- it (checked execs, systemd user units), and the stale socket at
    -- ~/.ydotool_socket makes a leftover daemon look alive, so the socket is
    -- removed first.
    hl.exec_cmd("bash -c 'rm -f $XDG_RUNTIME_DIR/.ydotool_socket; exec ydotoold'")

    -- Cursor
    --
    -- `Bibata-Modern-Classic` does not exist anywhere on this system -- not in
    -- /usr/share/icons, not in ~/.local/share/icons, nowhere on disk. It was
    -- removed or never installed.
    --
    -- This mattered far more than it looks. `setcursor` is how Hyprland tells
    -- the COMPOSITOR which cursor theme to draw, and it applies to every
    -- client -- including the Quickshell shell. Naming a theme that is not
    -- there made Hyprland fall back to its built-in arrow for everything, so
    -- no client could ever get a hand, a move cross, or a resize arrow
    -- rendered, no matter what cursorShape it asked for. A Qt binding saying
    -- `Qt::OpenHandCursor` was therefore invisible: the compositor, not Qt,
    -- owned the cursor and it had nothing to draw.
    --
    -- `capitaine-cursors` is the theme that is actually installed here (it is
    -- also what org.gnome.desktop.interface cursor-theme now names, which
    -- covers clients that ask the portal instead of asking Hyprland). Both
    -- Bibata names are gone; if a Bibata theme is ever installed again, this
    -- is the one line to change.
    hl.exec_cmd("hyprctl setcursor capitaine-cursors 24")
end)
