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

    // ── When the COMPOSITOR took the input away ─────────────────────────────
    //
    // A bar card holds the session's input through this grab, and a four-finger
    // swipe appears to be what makes the compositor drop it: the card is then
    // gone BEFORE the gesture's own `begin` line has finished travelling from
    // the touchpad script to this shell. So the swipe fallback in shell.qml --
    // which owes the user the desktop move the popup stole -- could not ask "is
    // a popup open?" at the gesture's start: that question answers NO about the
    // very popup the swipe just closed, which is why the swipe closed the card
    // and switched nothing. (The evidence for the timing is the log: the log
    // popups -- the launcher, the island -- reported "popup under the gesture"
    // when they were swiped over, and the bar cards never did. What remains to
    // be seen for the CLEAR itself is one real swipe over one real card; the
    // log line below and shell.qml's `[swipe] begin:` line are what show it.)
    //
    // This is that popup's last word. It moves for a COMPOSITOR clear only
    // (`onCleared` below), never for our own `dismiss()`: a backdrop press, an
    // Escape and "another popup is opening" are all deliberate closes, and
    // arming a desktop move on one of those would answer a swipe nobody made.
    property double clearedAt: 0
    property string clearedNames: ""

    // The last moment ANYTHING held the grab, however it stopped holding it.
    //
    // `clearedAt` above only moves when the compositor takes the input away.
    // A card can also simply BE GONE -- a loader torn down mid-swipe removes it
    // from the list on its own -- and then no dismissal is ever called and the
    // card has no other record of having been open (a bar card keeps no
    // GlobalStates flag; the grab list IS its open state). So this clock is the
    // witness for that route, and it exists to be READ IN A LOG: a gesture's
    // begin reports it, which is how "the card was already closed before the
    // gesture's own begin line arrived" can be told apart from "nothing was
    // ever open" -- the two look identical from every other angle.
    property double lastLiveAt: 0

    function noteLive() {
        if ((root.dismissable ?? []).length > 0)
            root.lastLiveAt = Date.now();
    }

    // The names of what is holding the grab right now, for a log line. Both
    // halves are tried because a card may not be a `WlrLayershell` in every
    // case; `?` is better than a missing row.
    function nameOf(window) {
        try {
            return window?.WlrLayershell?.namespace ?? window?.toString?.() ?? "?";
        } catch (error) {
            return "?";
        }
    }

    function dismiss() {
        root.noteLive();
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
        root.noteLive();
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
            return `active=${grab.active} dismissable=${root.liveDismissable.length}/${(root.dismissable ?? []).length} persistent=${root.livePersistent.length}/${(root.persistent ?? []).length}`
                + ` clearedAgo=${root.clearedAt > 0 ? Date.now() - root.clearedAt : -1}ms`
                + ` lastLiveAgo=${root.lastLiveAt > 0 ? Date.now() - root.lastLiveAt : -1}ms`;
        }

        function liveNames(): string {
            return root.liveDismissable.map(w => w?.WlrLayershell?.namespace ?? w?.toString?.() ?? "?").join(", ");
        }

        function release(): void {
            root.dismiss();
        }

        // Reproduces the COMPOSITOR's own clear, which is otherwise reachable
        // only by really taking the input away -- on this machine a four-finger
        // swipe is the one gesture that cannot be synthesised, and it is the
        // gesture this clock exists for. Everything after the stamp is the real
        // path: the grab is released exactly as the compositor releases it, so
        // shell.qml's swipe fallback arms on it for the next 400ms, which is
        // what the bar cards depend on. See `qs -c ii ipc call swipe simulate`.
        function cleared(): string {
            root.clearedAt = Date.now();
            root.clearedNames = root.liveDismissable.map(w => root.nameOf(w)).join(", ") || "probe";
            root.dismiss();
            return `clearedAt=${root.clearedAt} had=${root.clearedNames}`;
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
        root.noteLive();
    }

    function removeDismissable(window) {
        root.noteLive();
        var index = root.dismissable.indexOf(window);
        if (index !== -1) {
            const name = root.nameOf(window);
            root.dismissable.splice(index, 1);
            // Logged on the way to EMPTY and only then: that is a card closing
            // by a route that is not a dismissal, which is exactly the case
            // with no other trace anywhere in the shell.
            if (root.dismissable.length === 0)
                console.log(`[focusGrab] last dismissable left (${name})`);
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
            // Stamped BEFORE the dismiss, because `dismiss()` empties the list
            // this line is about to describe.
            root.clearedAt = Date.now();
            root.clearedNames = root.liveDismissable.map(w => root.nameOf(w)).join(", ");
            console.log(`[focusGrab] compositor cleared the grab (had=${root.clearedNames || "-"})`);
            root.dismiss();
        }
    }

}
