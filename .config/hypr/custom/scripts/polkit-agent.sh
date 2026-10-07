#!/usr/bin/env bash
# Start the polkit authentication agent, once.
#
# Why this exists: without any agent registered, polkitd has nowhere to send an
# authorization request. pkexec then falls back to a TEXTUAL agent, which needs
# a controlling terminal -- and anything launched from a session without one
# (a systemd-run unit, a cron job, an agent's non-interactive shell) fails with
#
#     Error creating textual authentication agent:
#     Error opening current controlling terminal (`/dev/tty')
#
# and udisks/gvfs simply refuse to mount anything, with no prompt on screen.
# That is the whole reason `sudo mount` had to be run by hand for the SSD, and
# the reason the Files window could not mount it on its own.
#
# polkit-gnome is ALREADY INSTALLED on this box -- the agent binary just lives
# outside PATH, at /usr/lib/polkit-gnome/, which is why `which
# polkit-gnome-authentication-agent-1` finds nothing and the agent looked
# missing. Nothing needs installing for this to work.
#
# hyprpolkit-agent is tried first when present (it is the native agent for this
# compositor and looks better), then polkit-gnome. Whichever starts first owns
# the polkit socket, so exactly one is ever launched.
#
# This runs on every config parse, including reloads, so it must be idempotent:
# a second agent would fight the first one for that socket.

set -u

GNOME_AGENT="/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1"

# Already running? Nothing to do. pgrep -f, because "polkit-gnome-
# authentication-agent-1" is far longer than the 15-char process-name limit.
if pgrep -f 'polkit-gnome-authentication-agent-1' >/dev/null 2>&1 \
   || pgrep -x 'hyprpolkit-agent' >/dev/null 2>&1; then
    exit 0
fi

# Prefer the compositor-native agent when it is actually installed.
if command -v hyprpolkit-agent >/dev/null 2>&1; then
    setsid hyprpolkit-agent >/tmp/polkit-agent.log 2>&1 </dev/null &
    exit 0
fi

# Fall back to the one that is installed here. Stay silent if this box ever
# loses it too, rather than filling the log on every reload.
if [ -x "$GNOME_AGENT" ]; then
    setsid "$GNOME_AGENT" >/tmp/polkit-agent.log 2>&1 </dev/null &
fi

exit 0