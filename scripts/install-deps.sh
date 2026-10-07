#!/usr/bin/env bash
# Install everything ~/hyprland needs to actually run — and nothing else.
#
# The list below is derived from what the config *calls*, not from end-4's
# kitchen-sink meta packages. Each entry names the file that needs it, so it
# can be re-checked when the config changes.
#
#   ./scripts/install-deps.sh                sync + install missing packages
#   ./scripts/install-deps.sh --dry-run      show the plan, change nothing
#   ./scripts/install-deps.sh --no-sysupgrade
#                                            skip the full system upgrade
#                                            (only if the system is current)
#
# Must run as your normal user, not root: paru refuses to build as root and
# needs to call sudo itself for the package step.

set -euo pipefail

DRY_RUN=0
SYS_UPGRADE=1
for arg in "$@"; do
    case "$arg" in
        --dry-run)       DRY_RUN=1 ;;
        --no-sysupgrade) SYS_UPGRADE=0 ;;
        -h|--help)       sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [[ $EUID -eq 0 ]]; then
    echo "error: run this as your normal user (paru must not run as root)" >&2
    exit 1
fi

# ── Packages ─────────────────────────────────────────────────────────────────
# The desktop shell itself. Without this the config is a bar-less compositor --
# literally: /tmp/ii_shell.log fills with "exec: qs: not found".
REPO_PKGS=(
    quickshell
    # QML modules imported by the shell config:
    #   modules/**/*.qml imports Qt5Compat.GraphicalEffects  (71 times)
    #                                       org.kde.kirigami (8 times)
    #                                       QtPositioning, org.kde.syntaxhighlighting
    qt6-5compat
    kirigami
    qt6-positioning
    syntax-highlighting

    # Tools the config invokes. See the note after each one.
    fuzzel          # custom/scripts/window-controls.sh  (SUPER + Escape menu)
    cliphist        # hyprland/execs.lua                (clipboard history)
    ydotool         # hyprland/execs.lua                (clipboard paste injection)
    matugen         # quickshell/ii/scripts/colors/     (the whole colour pipeline)
    cava            # bar audio visualiser
    playerctl       # media widget / media keys
    swappy          # ScreenshotAction.qml annotation view (satty is off by default)
    hyprsunset      # night light toggle in the shell
    geoclue         # hyprland/scripts/start_geoclue_agent.sh (weather)
    gnome-keyring   # hyprland/execs.lua                (secrets daemon)

    # Shell-script dependencies.
    bc              # used by scripts/colors/*
    go-yq           # used by the shell's yq-driven config writers

    # Fonts. monospace + iconNerd in ~/.config/illogical-impulse/config.json
    ttf-jetbrains-mono-nerd

    # AUR helper, for the fonts below. Present in the CachyOS repos.
    paru
)

# AUR fonts, matching appearance.fonts in ~/.config/illogical-impulse/config.json
AUR_PKGS=(
    ttf-material-symbols-variable-git   # iconMaterial -> "Material Symbols Rounded"
                                        #   = every icon in the bar and popups
    ttf-google-sans-flex-variable       # main, title, numbers
    ttf-readex-pro                      # reading
    otf-space-grotesk                   # expressive
)

# Deliberately NOT installed (visible in upstream's meta packages, but not
# needed here): dolphin + systemsettings + bluedevil (the KDE meta -- the shell
# has its own QML file manager and settings app), easyeffects, tesseract, songrec,
# translate-shell, wlogout, microtex, ddcutil, uv/python stack, fish/starship/eza,
# adw-gtk-theme-git, darkly-bin, breeze-plus, bibata cursors, sddm theme,
# qt6-{multimedia,sensors,virtualkeyboard,quicktimeline} (never imported).

# ── Plan ─────────────────────────────────────────────────────────────────────
echo "packages to install (repo):"
printf '  %s\n' "${REPO_PKGS[@]}"
echo "packages to install (AUR):"
printf '  %s\n' "${AUR_PKGS[@]}"
echo

missing_repo=()
for p in "${REPO_PKGS[@]}"; do
    pacman -Qq "$p" >/dev/null 2>&1 || missing_repo+=("$p")
done

missing_aur=()
for p in "${AUR_PKGS[@]}"; do
    pacman -Qq "$p" >/dev/null 2>&1 || missing_aur+=("$p")
done

if [[ ${#missing_repo[@]} -eq 0 ]]; then
    echo "repo packages: all present"
else
    echo "repo packages not installed yet: ${missing_repo[*]}"
fi

if [[ ${#missing_aur[@]} -eq 0 ]]; then
    echo "AUR fonts: all present"
else
    echo "AUR packages not installed yet: ${missing_aur[*]}"
fi
echo

if [[ $DRY_RUN -eq 1 ]]; then
    echo "dry run: nothing was changed."
    exit 0
fi

# ── Install ──────────────────────────────────────────────────────────────────
if [[ ${#missing_repo[@]} -eq 0 ]]; then
    echo "==> repo packages: nothing to do"
else
    # A full sync is the supported way to add packages on a rolling release: a
    # bare `-Sy` followed by installing only some packages is the partial-upgrade
    # case that can leave mismatched libraries behind.
    if [[ $SYS_UPGRADE -eq 1 ]]; then
        echo "==> syncing + upgrading the system, then installing"
        sudo pacman -Syu --needed --noconfirm "${missing_repo[@]}"
    else
        echo "==> syncing databases, installing (no system upgrade)"
        sudo pacman -Sy --noconfirm
        sudo pacman -S --needed --noconfirm "${missing_repo[@]}"
    fi
fi

if [[ ${#missing_aur[@]} -eq 0 ]]; then
    echo
    echo "==> AUR fonts: nothing to do"
else
    if ! command -v paru >/dev/null 2>&1; then
        echo
        echo "error: paru is missing, cannot install the AUR fonts." >&2
        exit 1
    fi
    echo
    echo "==> AUR fonts"
    paru -S --needed --noconfirm "${missing_aur[@]}"
fi

echo
echo "==> refreshing the font cache"
fc-cache -f >/dev/null

# ── Verify ───────────────────────────────────────────────────────────────────
echo
echo "==> required binaries"
fail=0
for c in qs fuzzel cliphist ydotoold matugen cava playerctl swappy hyprsunset; do
    if command -v "$c" >/dev/null 2>&1; then
        printf '  ok       %s\n' "$c"
    else
        printf '  MISSING  %s\n' "$c"
        fail=1
    fi
done

echo
echo "==> fonts the shell asks for"
for f in "Material Symbols Rounded" "Google Sans Flex" "JetBrains Mono NF" "Readex Pro" "Space Grotesk"; do
    if fc-list :family 2>/dev/null | grep -qiF "$f"; then
        printf '  ok       %s\n' "$f"
    else
        printf '  MISSING  %s\n' "$f"
        fail=1
    fi
done

echo
if [[ $fail -eq 0 ]]; then
    echo "All dependencies are in place."
else
    echo "Some dependencies are still missing (see above)." >&2
fi

cat <<'EOF'

Next:
  ~/hyprland/install.sh     link the config into ~/.config (safe, backs up)
  ~/.config/quickshell/ii/scripts/launch/shell.sh   start the bar now
  make reload               apply config changes
EOF

exit $fail
