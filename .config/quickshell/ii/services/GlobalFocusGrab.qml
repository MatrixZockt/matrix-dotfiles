pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

/**
 * Manages a HyprlandFocusGrab that's to be shared by all windows.
 * "Persistent" is for windows that should always be included but not closed on dismiss, like bar and onscreen keyboard.
 * "Dismissable" is for stuff like sidebars
 *
 * This is a compositor-level grab, not a QML convenience: while it is active,
 * Hyprland routes input to the grabbing window. So a stale entry in the list
 * below does not just misbehave -- it swallows the whole session's clicks with
 * nothing on screen to explain it, and the desktop looks broken even though
 * every application in it is fine. That is the "sometimes I cannot click
 * anything" bug, and it is why nothing here trusts the list to be accurate:
 *
 *   * only windows that are still visible may hold the grab (`live*` below),
 *   * entries whose window is hidden or destroyed are pruned rather than waited
 *     on, and
 *   * the grab is released no matter what if nothing visible is left, checked on
 *     a short timer, so a window that forgets to remove itself costs 400ms
 *     instead of the rest of the session.
 */
Singleton {
    id: root

    signal dismissed()

    property list<var> persistent: []
    property list<var> dismissable: []

    function dismiss() {
        root.dismissable = [];
        root.dismissed();
    }

    // A window that still exists and is actually on screen. Anything we cannot
    // read `visible` on counts as live (a Scope has no `visible`), and anything
    // that throws while being read is a deleted object.
    function isLive(window) {
        if (!window)
            return false;
        try {
            return window.visible === undefined ? true : !!window.visible;
        } catch (error) {
            return false;
        }
    }

    // What may actually take the grab, as opposed to what the list says.
    readonly property var liveDismissable: (root.dismissable ?? []).filter(window => root.isLive(window))
    readonly property var livePersistent: (root.persistent ?? []).filter(window => root.isLive(window))

    // Drop the entries that no longer correspond to a window on screen. This is
    // the self-heal: a sidebar that was unloaded while open, a panel torn down
    // mid-animation and any other path that adds itself without removing itself
    // all end here instead of holding the grab.
    function prune() {
        const kept = (root.dismissable ?? []).filter(window => root.isLive(window));
        if (kept.length !== root.dismissable.length)
            root.dismissable = kept;
    }

    // The backstop. Runs only while something claims to be open, and only until
    // the claim stops being true.
    Timer {
        running: root.dismissable.length > 0
        interval: 400
        repeat: true
        onTriggered: root.prune()
    }

    // Debug affordance: read the grab's state, or force it released, without
    // restarting the shell. A grab that is active with nothing on screen is
    // what makes the whole session's clicks disappear, so being able to see
    // and clear it from a terminal is worth the ten lines.
    IpcHandler {
        target: "focusGrab"

        function state(): string {
            return `active=${grab.active} dismissable=${root.liveDismissable.length}/${(root.dismissable ?? []).length} persistent=${root.livePersistent.length}/${(root.persistent ?? []).length}`;
        }

        function liveNames(): string {
            return root.liveDismissable.map(w => w?.WlrLayershell?.namespace ?? w?.toString?.() ?? "?").join(", ");
        }

        function release(): void {
            root.dismiss();
        }
    }

    function addPersistent(window) {
        if (root.persistent.indexOf(window) === -1) {
            root.persistent.push(window);
        }
    }

    function removePersistent(window) {
        var index = root.persistent.indexOf(window);
        if (index !== -1) {
            root.persistent.splice(index, 1);
        }
    }

    function addDismissable(window) {
        if (root.dismissable.indexOf(window) === -1) {
            root.dismissable.push(window);
        }
    }

    function removeDismissable(window) {
        var index = root.dismissable.indexOf(window);
        if (index !== -1) {
            root.dismissable.splice(index, 1);
        }
    }

    function hasActive(element) {
        return element?.activeFocus || Array.from(
            element?.children
        ).some(
            (child) => hasActive(child)
        );
    }

    HyprlandFocusGrab {
        id: grab
        windows: root.liveDismissable.every(w => !w?.focusable) || root.liveDismissable.some(w => hasActive(w?.contentItem)) ? [...root.liveDismissable, ...root.livePersistent] : [...root.liveDismissable]
        // Never `dismissable.length`: only a window that is on screen gets to
        // hold the session's input.
        active: root.liveDismissable.length > 0
        onCleared: () => {
            root.dismiss();
        }
    }

}
