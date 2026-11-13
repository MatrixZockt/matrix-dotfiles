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
    -- TEXT copies are stored by custom/scripts/clipboard-plain.sh, not by a
    -- bare `cliphist store`, because that script also STRIPS the copy down to
    -- plain text before it is stored and before anything pastes it: a copy out
    -- of a browser carries `text/html` beside `text/plain`, which is what made
    -- pasted text arrive with the source's styling (2026-11-05, the user's
    -- rule). It does the storing itself so one copy is one history entry --
    -- see its header, and its marker note for the rewrite not re-storing.
    -- flock because this file is parsed on every config reload: without it a
    -- reload stacks a second watcher and every copy is stored twice. The lock
    -- dies with the watcher, so a crash is recoverable on the next reload.
    hl.exec_cmd([[bash -c 'exec 9>"$XDG_RUNTIME_DIR/ii-clip-plain.lock"; flock -n 9 || exit 0; exec wl-paste --type text --watch "$HOME/.config/hypr/custom/scripts/clipboard-plain.sh"']])
    hl.exec_cmd("wl-paste --type image --watch bash -c 'cliphist store && qs -c $qsConfig ipc call cliphistService update'")

    -- ydotoold: the virtual-input daemon the clipboard's paste AND dictation
    -- need. Without it every Ctrl+V synthesis dies with "Connection refused",
    -- clicking a clipboard entry does nothing visible, and dictation falls back
    -- to wtype -- which never reaches an XWayland window. It used to be spawned
    -- bare from here, so an OOM sweep left it dead with no restart; it is a
    -- systemd user unit now (Restart=on-failure, enabled into default.target),
    -- and this line only nudges it. The unit removes the stale socket itself.
    hl.exec_cmd("systemctl --user start ydotoold.service")

    -- Cursor: deliberately NOT set here.
    --
    -- There used to be a `hyprctl setcursor capitaine-cursors 24` at startup,
    -- and it was one of THREE places that named a cursor theme -- this one, the
    -- mode-dependent pair in custom/theme.lua, and XCURSOR_THEME for the
    -- clients. Every one of them is a different answer to "what does the
    -- pointer look like", so the pointer could change artwork between windows:
    -- a white borderless arrow in one place, an outlined one in another. That
    -- is the "my mouse border turns from black to white sometimes" report, and
    -- the fix is not a better name in three places, it is one name in one
    -- place.
    --
    -- The single name lives in hyprland/env.lua (XCURSOR_THEME) and reaches
    -- the compositor, Qt clients and X11 clients alike. Nothing sets it per
    -- mode and nothing swaps it mid-session any more.
end)
