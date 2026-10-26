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
    # The wake path's one root step: the speaker amp is re-programmed by
    # restarting its system unit after every suspend/resume, and restarting a
    # system unit from a session is what asked for the admin password on every
    # wake. See the rule's own header -- polkitd named that command as the
    # caller on 2026-10-13.
    $sudo_or install -Dm 0644 "$REPO/extras/etc/polkit-1/rules.d/20-razer-speakers.rules" \
        /etc/polkit-1/rules.d/20-razer-speakers.rules
    $sudo_or systemctl restart polkit 2>/dev/null || true
    echo "  polkit  org.matrix.razercc actions + rule installed (passwordless for matrix)"
    echo "  polkit  razer-speakers restart allowed (waking from sleep asks nothing)"
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

# Account recovery: ii-recover goes to /usr/local/sbin, root-owned, and its store
# directory /var/lib/ii-recovery is created root-owned too. Both are the security
# property, not housekeeping: the helper is run as root (pkexec from the settings
# app's Account page, or directly from a console when the password is gone), and a
# helper or a recovery record the session user could rewrite would be a way to
# reset the password with a code of one's own choosing. The settings page reads
# this file (0644, salt+hash only) so it can show whether a code is set -- the
# code itself is 100 random bits behind scrypt and is never stored.
#
# Changing a password needs none of this: /usr/bin/passwd is setuid and does that
# on its own (see extras/bin/ii-passwd).
RECOVER_SYSTEM=0
if [[ -f "$REPO/extras/sbin/ii-recover" && $DRY_RUN -eq 0 ]]; then
    if [ "$(id -u)" -eq 0 ]; then
        RECOVER_SYSTEM=1
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        RECOVER_SYSTEM=1
    else
        echo "  (skipped: run 'sudo bash install.sh' or copy extras/sbin/ii-recover to /usr/local/sbin/)"
    fi
fi
if [[ $RECOVER_SYSTEM -eq 1 ]]; then
    sudo_or=""
    [ "$(id -u)" -ne 0 ] && sudo_or="sudo"
    $sudo_or install -Dm 0755 "$REPO/extras/sbin/ii-recover" /usr/local/sbin/ii-recover
    $sudo_or install -d -m 0755 -o root -g root /var/lib/ii-recovery
    echo "  recover ii-recover installed (root-owned); /var/lib/ii-recovery ready"
    echo "          generate a code from Settings > Account, or: sudo ii-recover --setup"
fi

# Lid state at resume: this Blade's firmware never reports the lid as open
# after a resume and _LID keeps answering "closed", so the driver, the input
# switch, the proc file and logind all agree on a wrong value -- and on
# 2026-10-16 the post-resume lid watcher slept a machine whose lid was open.
# The kernel's own quirk table answers exactly this firmware for sibling Razer
# models, but not for this one, and `button` is built into the kernel (no
# button.ko) so the parameter has to be set at boot from userspace. The unit's
# header carries the measurement and the revert recipe; a failure here is
# visible in `systemctl --failed` and named by lid-guard.sh in the journal.
LID_UNIT=0
if [[ -f "$REPO/extras/etc/systemd/system/lid-init-state.service" && $DRY_RUN -eq 0 ]]; then
    if [ "$(id -u)" -eq 0 ]; then
        LID_UNIT=1
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        LID_UNIT=1
    else
        echo "  (skipped: run 'sudo bash install.sh' or copy extras/etc/systemd/system/lid-init-state.service to /etc/systemd/system/)"
    fi
fi
if [[ $LID_UNIT -eq 1 ]]; then
    sudo_or=""
    [ "$(id -u)" -ne 0 ] && sudo_or="sudo"
    $sudo_or install -Dm 0644 "$REPO/extras/etc/systemd/system/lid-init-state.service" \
        /etc/systemd/system/lid-init-state.service
    $sudo_or systemctl daemon-reload
    # --now, because the parameter is not a boot-time-only convenience: it is
    # read on the resume path, and the first resume after this install should
    # already be the fixed one.
    $sudo_or systemctl enable --now lid-init-state.service >/dev/null 2>&1 || \
        echo "  (could not enable lid-init-state.service -- enable it by hand)"
    echo "  unit    lid-init-state.service installed (lid reported open at resume)"
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
