pragma Singleton
import Quickshell
// Imports are spelled out rather than assumed to be injected into every file's
// scope: a missing name only fails when the function that uses it is first
// called, and the functions here are reached for at the end of a day -- log
// out, shut down -- which is a bad moment to discover one. `import qs` is here
// for lock(): the lock state lives in GlobalStates, at the config root.
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
    //
    // It used to spawn `hyprlock`, which retired with the separate locker: the
    // lock is this shell's own surface now (modules/common/panels/lock/
    // LockScreen.qml), so the session menu, the start menu and SUPER+L all
    // raise THE SAME lock, on the same picture, instead of the session menu
    // throwing the old hyprlock screen over the top of it.
    function lock() {
        GlobalStates.screenLocked = true;
    }

    // Sleep: screen off, machine asleep, and every app, window and setting
    // exactly where it was left. Deliberately NOT a logout -- nothing is closed
    // and nothing is killed, which is the whole point of it.
    //
    // ONE call, and it is the same one logind performs when the lid closes
    // (`HandleLidSwitch=suspend`, /etc/systemd/logind.conf.d/50-lid-power.conf,
    // and the same call the power button is mapped to). Nothing of our own is
    // added on top, and that is the point rather than an omission: this used to
    // raise the lock in-process, blank the panel and prefer hibernate, and each
    // of those three made sleeping from the menu DIFFERENT from closing the
    // lid:
    //
    //   * the pre-lock painted the login screen on a LIT panel -- exactly what
    //     before-sleep.sh's ordering exists to avoid, because the hook raises
    //     the lock behind an already-dark panel so the prompt is only ever met
    //     on the way back;
    //   * blanking the panel first cut off "Going to sleep" before it could be
    //     read, so a laptop that was leaving looked identical to one that had
    //     died -- the one question that label exists to answer;
    //   * hibernate was chosen from logind's capability probe, but the lid only
    //     ever suspends, so the two "Sleep"s could do different things on one
    //     machine.
    //
    // What is left is what was always shared: logind performs the sleep, and
    // hypridle's before_sleep_cmd / after_sleep_cmd (custom/scripts/
    // before-sleep.sh and after-resume.sh) do the notice, the panel, the lock
    // and the wake. hypridle gates EVERY suspend -- it holds a delay inhibitor
    // and acts on logind's PrepareForSleep -- so this is not a hope about this
    // call site: it is the same path the lid and the power button take.
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
