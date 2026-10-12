#!/usr/bin/env bash
# Open the task manager.
#
#   task-manager.sh            open it
#   task-manager.sh memory     open it on the Memory page
#   task-manager.sh disk:sda1  open it on a Storage page
#
# It used to start (or retarget) a separate `qs -p` desktop window -- the
# settings app converting into the task-manager face. That is why the task
# manager could never be "in front of everything": a client window lives on
# the Top layer, and a fullscreen client renders ABOVE every Top-layer
# surface. No focus call and no always-on-top hint fixes that, because the
# layer it is on is the problem.
#
# It is now an Overlay-layer surface of the MAIN shell
# (modules/ii/taskManager/TaskManagerOverlay.qml), the same surface kind the
# bar and the switcher use to sit correctly over a fullscreen window. So there
# is nothing to launch and nothing to retarget: this asks the shell that is
# already running to show its overlay, and the shell's watchdog keeps that one
# shell alive.
#
# The callers are unchanged -- the launcher's "Task Manager" entry (through
# `apps.taskManager` in config.json, whose value is this script's path), the
# Settings app's Overview hardware tiles (which name a device), and the
# CTRL+SHIFT+Escape keybind -- so the deep-link argument still works.
set -u

script_path="$(readlink -f "${BASH_SOURCE[0]}")"
shell_dir="$(dirname "$(dirname "$(dirname "$script_path")")")"
shell="$(basename "$shell_dir")"

key="${1:-}"

# The shell's IPC socket. `call` answers on stdout and exits non-zero when the
# target is not there, which is the only way this can fail: the shell is
# either up (it answers) or not (nothing to show a task manager in anyway).
#
# The socket's own answer is kept, because it is the whole reason a failure can
# give: "Couldn't open the task manager" with no cause is a dead end, while the
# socket answering "target taskManager not found" or "connection refused" is the
# thing to act on.
ipc_out="$(qs -c "$shell" ipc call taskManager open "$key" 2>&1)"
ipc_status=$?
if [ "$ipc_status" -eq 0 ]; then
    # Let the shell's "starting" card go if something raised one (the
    # launcher entry does). Harmless when nothing did.
    qs -c "$shell" ipc call loading dismiss >/dev/null 2>&1
    exit 0
fi

detail="$(printf '%s\n' "$ipc_out" | tr -d '\r' \
    | grep -v '^[[:space:]]*$' | head -n 1 | cut -c1-140)"
if [ -n "$detail" ]; then
    qs -c "$shell" ipc call loading fail "Couldn't open the task manager (${detail})" >/dev/null 2>&1
else
    qs -c "$shell" ipc call loading fail "Couldn't open the task manager (the shell is not answering its IPC)" >/dev/null 2>&1
fi
exit 1
