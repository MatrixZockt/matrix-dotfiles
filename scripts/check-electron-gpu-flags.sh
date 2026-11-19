#!/usr/bin/env bash
# Does every Chromium/Electron app on this desk carry the same safe GPU switch
# set -- and none of the one that blanks a window?
#
# WHY THIS EXISTS (2026-11-19): WhatsApp opened a fully white window. Its
# launcher combined --enable-zero-copy with --disable-gpu-compositing, so the
# CPU compositor was handed zero-copy buffers and drew nothing; an X11 capture
# of the window was a single flat gray(255) frame. --enable-zero-copy buys one
# buffer copy and, on this stack, can cost the whole window, so it is banned on
# every launch path here. Tile rasterisation and VA-API decoding stay on the
# GPU -- that is where the CPU win actually came from.
#
# The check covers the LIVE launch paths, the shared flags files, the local
# .desktop overrides, AND the copies in this repo that install.sh restores --
# because a fix that exists only in ~/.local/bin is lost on the next install.
#
#   bash scripts/check-electron-gpu-flags.sh
set -u
export LC_ALL=C

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

# Comments explain the flags (and name the banned one); only code counts.
active() { grep -v '^[[:space:]]*#' "$1" 2>/dev/null; }

# Live launch paths, then the repo copies that install.sh puts back.
live_files=( 
    "$HOME/.local/bin/whatsapp-desktop"
    "$HOME/.local/bin/discord"
    "$HOME/.local/bin/tradingview"
    "$HOME/.local/bin/claude-desktop"
    "$HOME/.local/bin/freebuff-desktop"
    "$HOME/.config/electron-flags.conf"
    "$HOME/.config/brave-flags.conf"
    "$HOME/.local/share/applications/discord.desktop"
    "$HOME/.local/share/applications/whatsapp-linux-desktop.desktop"
    "$HOME/.local/share/applications/tradingview.desktop"
)
repo_files=(
    "$REPO/extras/bin/whatsapp-desktop"
    "$REPO/extras/bin/discord"
    "$REPO/extras/bin/tradingview"
    "$REPO/extras/bin/claude-desktop"
    "$REPO/extras/bin/freebuff-desktop"
    "$REPO/.config/electron-flags.conf"
    "$REPO/.config/brave-flags.conf"
    "$REPO/extras/applications/discord.desktop"
    "$REPO/extras/applications/whatsapp-linux-desktop.desktop"
    "$REPO/extras/applications/tradingview.desktop"
)

echo "1. no launch path passes --enable-zero-copy"
for f in "${live_files[@]}" "${repo_files[@]}"; do
    [ -f "$f" ] || continue
    shown="${f/#$HOME/~}"
    shown="${shown/#$REPO/<repo>}"
    if active "$f" | grep -q -- '--enable-zero-copy'; then
        bad "$shown still passes --enable-zero-copy"
    else
        ok "$shown"
    fi
done
echo

echo "2. the browser config files leave rasterisation on the GPU"
for f in "$HOME/.config/brave-flags.conf" "$HOME/.config/electron-flags.conf"; do
    [ -f "$f" ] || continue
    if active "$f" | grep -q -- '--enable-gpu-rasterization'; then
        ok "${f/#$HOME/~} has --enable-gpu-rasterization"
    else
        bad "${f/#$HOME/~} lost --enable-gpu-rasterization"
    fi
done
for f in "$HOME/.local/bin/whatsapp-desktop" "$HOME/.local/bin/discord" \
         "$HOME/.local/bin/tradingview" "$HOME/.local/bin/claude-desktop" \
         "$HOME/.local/bin/freebuff-desktop"; do
    [ -f "$f" ] || continue
    if active "$f" | grep -q -- '--enable-gpu-rasterization'; then
        ok "${f/#$HOME/~} has --enable-gpu-rasterization"
    else
        bad "${f/#$HOME/~} lost --enable-gpu-rasterization"
    fi
done
echo

echo "3. the repo copies are the ones that are live (edit the repo, not ~/.local)"
pairs=(
    "$REPO/extras/bin/whatsapp-desktop:$HOME/.local/bin/whatsapp-desktop"
    "$REPO/extras/bin/discord:$HOME/.local/bin/discord"
    "$REPO/extras/bin/tradingview:$HOME/.local/bin/tradingview"
    "$REPO/extras/bin/claude-desktop:$HOME/.local/bin/claude-desktop"
    "$REPO/extras/bin/freebuff-desktop:$HOME/.local/bin/freebuff-desktop"
    "$REPO/.config/electron-flags.conf:$HOME/.config/electron-flags.conf"
    "$REPO/.config/brave-flags.conf:$HOME/.config/brave-flags.conf"
    "$REPO/extras/applications/discord.desktop:$HOME/.local/share/applications/discord.desktop"
    "$REPO/extras/applications/whatsapp-linux-desktop.desktop:$HOME/.local/share/applications/whatsapp-linux-desktop.desktop"
    "$REPO/extras/applications/tradingview.desktop:$HOME/.local/share/applications/tradingview.desktop"
)
for pair in "${pairs[@]}"; do
    src="${pair%%:*}"
    dst="${pair#*:}"
    [ -f "$src" ] || { bad "missing repo copy: ${src/#$REPO/<repo>}"; continue; }
    [ -f "$dst" ] || { bad "missing live file: ${dst/#$HOME/~}"; continue; }
    if cmp -s "$src" "$dst"; then
        ok "${dst/#$HOME/~} matches the repo"
    else
        bad "${dst/#$HOME/~} drifted from the repo copy"
    fi
done

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
