#!/usr/bin/env bash
# Link this repo's .config/* into ~/.config, so the repo IS the live config.
# Anything already there gets backed up (never deleted).
#
#   ./install.sh            link everything
#   ./install.sh --dry-run  show what would happen, change nothing

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${XDG_CONFIG_HOME:-$HOME/.config}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

echo "repo: $REPO"
echo "dest: $DEST"
echo

if [[ ! -d "$REPO/.config" ]]; then
    echo "error: $REPO/.config not found" >&2
    exit 1
fi

for src in "$REPO"/.config/*; do
    name="$(basename "$src")"
    target="$DEST/$name"
    rel="$(realpath --relative-to="$DEST" "$src")"

    if [[ -L "$target" ]]; then
        if [[ "$(readlink -f "$target")" == "$(readlink -f "$src")" ]]; then
            echo "  ok      $name (already linked)"
            continue
        fi
        echo "  relink  $name"
        [[ $DRY_RUN -eq 0 ]] && ln -sfn "$rel" "$target"
    elif [[ -e "$target" ]]; then
        echo "  backup  $name -> $name.$STAMP (backup kept)"
        if [[ $DRY_RUN -eq 0 ]]; then
            mv "$target" "$target.$STAMP"
            ln -s "$rel" "$target"
        fi
    else
        echo "  link    $name"
        [[ $DRY_RUN -eq 0 ]] && ln -s "$rel" "$target"
    fi
done

# Extras: desktop entries and icons for apps that do not ship them (see extras/).
# Without these, apps like AppImages fall back to a broken-image placeholder in
# the bar instead of showing their real logo.
for pair in "applications:$HOME/.local/share/applications" \
            "icons/hicolor/512x512/apps:$HOME/.local/share/icons/hicolor/512x512/apps" \
            "bin:$HOME/.local/bin"; do
    src="$REPO/extras/${pair%%:*}"
    dest="${pair##*:}"
    [[ -d "$src" ]] || continue
    mkdir -p "$dest"
    for f in "$src"/*; do
        [[ -e "$f" ]] || continue
        echo "  copy    $(basename "$f") -> $dest"
        # bin/ holds executables (appimage-run, the double-click handler):
        # install with the exec bit. Everything else is plain data.
        if [[ "${pair%%:*}" == "bin" ]]; then
            [[ $DRY_RUN -eq 0 ]] && install -m 0755 "$f" "$dest/"
        else
            [[ $DRY_RUN -eq 0 ]] && cp -f "$f" "$dest/"
        fi
    done
done
if [[ $DRY_RUN -eq 0 ]]; then
    command -v gtk-update-icon-cache >/dev/null && \
        gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1
fi

# systemd USER units from extras/systemd. These are what make a helper survive
# logout/login; without this block the units in the repo are never deployed and
# the features they back silently do nothing on a fresh machine. Only user
# units are handled here -- anything needing root lives in extras/etc and is
# installed by the elevated Razer step below.
if [[ -d "$REPO/extras/systemd/user" ]]; then
    mkdir -p "$HOME/.config/systemd/user"
    for f in "$REPO/extras/systemd/user"/*.service; do
        [[ -e "$f" ]] || continue
        name="$(basename "$f")"
        echo "  unit    $name"
        if [[ $DRY_RUN -eq 0 ]]; then
            install -m 0644 "$f" "$HOME/.config/systemd/user/$name"
            # Enable without --now: starting a unit during install would race
            # the session that is still coming up, and every unit here is
            # WantedBy=default.target, so the next login starts it anyway. The
            # daemon-reload is needed for an already-running session to notice.
            systemctl --user daemon-reload >/dev/null 2>&1
            systemctl --user enable "$name" >/dev/null 2>&1 || \
                echo "  (could not enable $name -- enable it by hand)"
        fi
    done
fi

# Razer Command Center's passwordless elevation: the polkit action file and
# rule go to SYSTEM locations, so this step needs one elevated shell. The
# helper binary goes to /usr/local/sbin. Run manually with sudo once; the
# installed files persist across reinstalls (versioned with the repo).
RAZER_CC_SYSTEM=0
if [[ -d "$REPO/extras/share/polkit-1/actions" && $DRY_RUN -eq 0 ]]; then
    if [ "$(id -u)" -eq 0 ]; then
        RAZER_CC_SYSTEM=1
    elif command -v sudo >/dev/null 2>&1; then
        echo "polkit: one elevated step for the Command Center's actions (or run install.sh as root)"
        if sudo -n true 2>/dev/null; then
            RAZER_CC_SYSTEM=1
        else
            echo "  (skipped: run 'sudo bash install.sh' or deploy manually — see extras/share/polkit-1/)"
        fi
    fi
fi
if [[ $RAZER_CC_SYSTEM -eq 1 ]]; then
    sudo_or=""
    [ "$(id -u)" -ne 0 ] && sudo_or="sudo"
    $sudo_or install -Dm 0755 "$REPO/extras/sbin/razer-cc-elevate" /usr/local/sbin/razer-cc-elevate
    $sudo_or install -Dm 0644 "$REPO/extras/share/polkit-1/actions/org.matrix.razercc.policy" \
        /usr/share/polkit-1/actions/org.matrix.razercc.policy
    $sudo_or install -Dm 0644 "$REPO/extras/etc/polkit-1/rules.d/60-razercc.rules" \
        /etc/polkit-1/rules.d/60-razercc.rules
    $sudo_or systemctl restart polkit 2>/dev/null || true
    echo "  polkit  org.matrix.razercc actions + rule installed (passwordless for matrix)"
fi

# Removable media: the rule that lets the session user mount a stick, a card or
# a phone without the admin password. Same shape of elevated step as the
# Command Center's above -- and the same file the file manager's own note names
# (modules/filemanager/FileManagerContent.qml, mountVolume). Silent-sudo only:
# an install that is already running unattended must not stop to ask, and the
# file can always be deployed by hand from extras/etc/polkit-1/rules.d/.
REMOVABLE_POLKIT=0
if [[ -f "$REPO/extras/etc/polkit-1/rules.d/10-ii-removable-mount.rules" && $DRY_RUN -eq 0 ]]; then
    if [ "$(id -u)" -eq 0 ]; then
        REMOVABLE_POLKIT=1
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        REMOVABLE_POLKIT=1
    else
        echo "  (skipped: run 'sudo bash install.sh' or copy extras/etc/polkit-1/rules.d/10-ii-removable-mount.rules to /etc/polkit-1/rules.d/)"
    fi
fi
if [[ $REMOVABLE_POLKIT -eq 1 ]]; then
    sudo_or=""
    [ "$(id -u)" -ne 0 ] && sudo_or="sudo"
    $sudo_or install -Dm 0644 "$REPO/extras/etc/polkit-1/rules.d/10-ii-removable-mount.rules" \
        /etc/polkit-1/rules.d/10-ii-removable-mount.rules
    $sudo_or systemctl restart polkit 2>/dev/null || true
    echo "  polkit  removable-media rule installed (mount / umount / blockdev, no password)"
fi

# Make AppImages and loose executables launch on double-click, permanently:
# register appimage-run as the default handler for their mime types. This
# writes [Default Applications] entries into ~/.config/mimeapps.list, which
# gio and every xdg-compliant file manager re-read on each login -- nothing
# else to do after install. Only claimed when a type has NO handler yet, so
# a choice the user (or another tool) makes later always wins.
if [[ $DRY_RUN -eq 0 ]]; then
    for mime in application/vnd.appimage \
                application/x-executable \
                application/x-pie-executable; do
        if [[ -n "$(XDG_DATA_DIRS=/usr/share xdg-mime query default "$mime" 2>/dev/null)" ]]; then
            echo "  mime    $mime (already has a handler, left alone)"
        else
            XDG_DATA_DIRS=/usr/share xdg-mime default appimage-run.desktop "$mime" && \
                echo "  mime    $mime -> appimage-run.desktop"
        fi
    done
else
    echo "  mime    (dry run) appimage-run would become the double-click handler for AppImages/executables"
fi

echo
if [[ $DRY_RUN -eq 1 ]]; then
    echo "dry run: nothing was changed."
    exit 0
fi

cat <<'EOF'
Done. Next steps on a fresh machine:

  1. Make sure the desktop stack is installed (Hyprland 0.56+, Quickshell, the
     illogical-impulse packages). The easy path is end-4's installer:
       git clone https://github.com/end-4/dots-hyprland ~/dots-hyprland
       cd ~/dots-hyprland && ./setup install
     ...then re-run this script so YOUR config wins over theirs again.

  2. Reload Hyprland:   make reload
  3. See what broke:    make check
EOF
