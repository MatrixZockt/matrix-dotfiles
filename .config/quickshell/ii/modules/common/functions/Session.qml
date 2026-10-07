pragma Singleton
import Quickshell
// `qs` is the config root, and it is where GlobalStates lives -- referenced by
// sleep() below. Imported explicitly rather than assumed to be injected into
// every file's scope: this is the only file in modules/common/functions/ that
// names GlobalStates, so nothing else here would have proved the dependency,
// and a missing name only fails when the function is first called -- which for
// sleep() is a button the user is reaching for at the end of the day.
import qs
import qs.services
import qs.modules.common

Singleton {
    id: root

    function closeAllWindows() {
        HyprlandData.windowList.map(w => w.pid).forEach(pid => {
            Quickshell.execDetached(["kill", pid]);
        });
    }

    function changePassword() {
        Quickshell.execDetached(["bash", "-c", `${Config.options.apps.changePassword}`]);
    }

    // Lock is back, Windows-style: unlike the login screen this keeps the
    // whole session -- every app, every window, its state -- alive behind the
    // password prompt. It was removed once on the theory that logging out is
    // strictly more useful for the same key; in practice that threw away the
    // session, so SUPER+L now locks and Log out (below) is the session-ender.
    function lock() {
        Quickshell.execDetached(["hyprlock"]);
    }

    // Sleep: screen off, machine asleep, and every app, window and setting
    // exactly where it was left. Deliberately NOT a logout -- nothing is closed
    // and nothing is killed, which is the whole point of it.
    //
    // The lock comes first and in-process, so it is up before the machine goes
    // anywhere: the shell's own lock screen (the same one SUPER+L raises, via
    // the same `screenLocked` flag) rather than spawning a second, separate
    // hyprlock on top of it. The ordering matters -- once the script has asked
    // for the sleep there is no guarantee another line of QML would ever run.
    //
    // The script decides hibernate-vs-suspend by asking systemd-logind what this
    // machine can actually do, and blanks the panel with Hyprland's DPMS
    // dispatcher before the sleep starts. See scripts/session/sleep.sh.
    function sleep() {
        GlobalStates.screenLocked = true;
        Quickshell.execDetached(["bash", Quickshell.shellPath("scripts/session/sleep.sh")]);
    }

    function suspend() {
        Quickshell.execDetached(["bash", "-c", "systemctl suspend || loginctl suspend"]);
    }

    function logout() {
        closeAllWindows();
        Quickshell.execDetached(["pkill", "-i", "Hyprland"]);
    }

    function launchTaskManager() {
        Quickshell.execDetached(["bash", "-c", `${Config.options.apps.taskManager}`]);
    }

    function hibernate() {
        Quickshell.execDetached(["bash", "-c", `systemctl hibernate || loginctl hibernate`]);
    }

    // Both of these used to SIGTERM every window's pid and then reboot in the
    // same instant, which is the abrupt version: an application that was
    // mid-save never got to finish, because the machine was already tearing
    // itself down. They now go through a script that asks first, waits, flushes
    // the writes to disk, holds a shutdown inhibitor so nothing can veto the
    // transition half-way, and only then hands over to systemd. See
    // scripts/session/power-action.sh for the full ordering and the reasoning.
    function poweroff() {
        Quickshell.execDetached(["bash", Quickshell.shellPath("scripts/session/power-action.sh"), "poweroff"]);
    }

    function reboot() {
        Quickshell.execDetached(["bash", Quickshell.shellPath("scripts/session/power-action.sh"), "reboot"]);
    }

    function rebootToFirmware() {
        closeAllWindows();
        Quickshell.execDetached(["bash", "-c", `systemctl reboot --firmware-setup || loginctl reboot --firmware-setup`]);
    }
}
