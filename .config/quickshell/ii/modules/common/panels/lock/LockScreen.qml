pragma ComponentBehavior: Bound
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

Scope {
    id: root

    required property Component lockSurface
    property alias context: lockContext
    property Component sessionLockSurface: WlSessionLockSurface {
        id: sessionLockSurface
        color: "transparent"
        Loader {
            active: GlobalStates.screenLocked
            anchors.fill: parent
            opacity: active ? 1 : 0
            Behavior on opacity {
                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
            }
            sourceComponent: root.lockSurface
        }
    }

    // ── The lock, as a LAYER-SHELL surface ────────────────────────────────
    // hyprlock is retired: SUPER+L no longer hands locking to a separate
    // process. This is the same trick every other overlay in this shell uses
    // (the wallpaper theatre, the search panel): a full-screen PanelWindow on
    // the Overlay layer, which the compositor serves input to before anything
    // else, with the keyboard grabbed for as long as it is up. Nothing behind
    // it can see a click or a key.
    //
    // Deliberately NOT a WlSessionLock. Quickshell hot-reloads its whole QML
    // tree whenever any watched file changes, which killed the session-lock
    // surface mid-lock and made Hyprland paint its "the lockscreen app died"
    // fallback over the session -- which is why the WlSessionLock below is
    // pinned off and hyprlock used to hold the lock instead. A layer surface
    // has no such contract with the compositor: a reload simply re-creates the
    // window that was already covering the screen.
    //
    // The surface is deliberately opaque: the session stays alive behind it
    // (SUPER+L is a LOCK, not a log-out), but nothing of it is readable. The
    // background canvas additionally blurs itself while locked, so what shows
    // through the scrim is the wallpaper, not the windows.
    Variants {
        model: Quickshell.screens
        delegate: PanelWindow {
            id: lockWindow
            required property ShellScreen modelData

            screen: modelData
            visible: GlobalStates.screenLocked
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "quickshell:lock"
            WlrLayershell.keyboardFocus: GlobalStates.screenLocked
                ? WlrKeyboardFocus.Exclusive
                : WlrKeyboardFocus.None
            exclusionMode: ExclusionMode.Ignore
            anchors {
                top: true
                left: true
                right: true
                bottom: true
            }

            // The compositor-level grab, the same mechanism the bar's anchored
            // panels use: it is what makes the password keys and Escape arrive
            // even when another window held the keyboard when the lock came up.
            //
            // GlobalFocusGrab is a SINGLETON -- one shared HyprlandFocusGrab for
            // the whole shell -- so it is SPOKEN TO, never instantiated. Writing
            // `GlobalFocusGrab { ... }` here (as the first revision of this file
            // did) is not a harmless no-op: a composite singleton cannot be
            // created, and that single line made Quickshell fail to load the
            // ENTIRE config -- shell.qml -> IllogicalImpulseFamily -> Lock ->
            // LockScreen -> here -- leaving the previous tree running.
            onVisibleChanged: {
                if (visible)
                    GlobalFocusGrab.addDismissable(lockWindow);
                else
                    GlobalFocusGrab.removeDismissable(lockWindow);
            }
            Component.onCompleted: {
                if (lockWindow.visible)
                    GlobalFocusGrab.addDismissable(lockWindow);
            }
            // The shared grab is dropped WHOLE when anything calls its dismiss()
            // -- that clears every dismissable entry, this window included --
            // and a locked screen that has silently lost its keyboard is the
            // worst failure this file can have. Re-arm while locked; it costs
            // one array lookup twice a second.
            Timer {
                running: lockWindow.visible
                interval: 500
                repeat: true
                onTriggered: GlobalFocusGrab.addDismissable(lockWindow)
            }

            Rectangle {
                anchors.fill: parent
                color: Appearance.colors.colLayer0
                opacity: 0.94
            }

            Loader {
                id: lockSurfaceLoader
                anchors.fill: parent
                active: GlobalStates.screenLocked
                sourceComponent: root.lockSurface
                // The backdrop rides the same hand-over as the context: the
                // surface is told what to draw, it does not go and look.
                // A family whose surface has no `backdropUrl` property (the
                // assignment is duck-typed by the surface, not by this base)
                // simply keeps the flat wash.
                onLoaded: {
                    item.context = lockContext;
                    if (item.backdropUrl !== undefined)
                        item.backdropUrl = root.lockBackdropUrl;
                }
            }

            // A picture picked while the screen is ALREADY locked (the
            // wallpaper selector can do that) reaches the live surface, not
            // just the next lock. Lives here, beside the Loader it talks to:
            // the id above belongs to this delegate, so a Connections at the
            // Scope's level could not see it.
            Connections {
                target: root
                function onLockBackdropUrlChanged() {
                    if (lockSurfaceLoader.item && lockSurfaceLoader.item.backdropUrl !== undefined)
                        lockSurfaceLoader.item.backdropUrl = root.lockBackdropUrl;
                }
            }
        }
    }

    Process {
        id: unlockKeyringProc
        onExited: (exitCode, exitStatus) => {
            KeyringStorage.fetchKeyringData();
        }
    }
    function unlockKeyring() {
        unlockKeyringProc.exec({
            environment: ({
                "UNLOCK_PASSWORD": lockContext.currentText
            }),
            command: ["bash", "-c", Quickshell.shellPath("scripts/keyring/unlock.sh")]
        })
    }

    // ═════════════════════════════════════════════════════════════════════
    // The login screen's picture
    // ═════════════════════════════════════════════════════════════════════
    // The lock and the login already share their layouts (LoginLayouts), but
    // not their BACKDROP: locking showed a flat colLayer0 wash, so the same
    // design sat on two different pictures and pressing SUPER+L did not look
    // like the machine going to sleep into the screen you meet at the next
    // boot. The lock surface now wears the greeter's own image.
    //
    // The picture belongs to the SDDM theme, so it is resolved the way SDDM
    // resolves it -- theme from the sddm config, then that theme's
    // [General] background= -- by scripts/lock/greeter-backdrop.sh rather
    // than hardcoded. Change the greeter's theme or its picture and the lock
    // follows; there is no second file to edit and no way for the two to
    // drift. An empty result is a real case (no greeter theme installed) and
    // simply leaves the old flat wash in charge.
    //
    // Resolved HERE rather than inside the lock surface, which only exists
    // while the screen is locked: the path is then already known when the
    // surface is created, one resolution serves every monitor, and the
    // `lock backdrop` diagnostic can read it with the screen unlocked.
    property string greeterBackdropUrl: ""

    // ── ...unless a picture was picked FOR THE LOCK ──────────────────────
    // Settings → Appearance → Lock screen picture (and the wallpaper
    // selector's "Lock" target) write background.wallpaperPathLock. That
    // setting used to land in hyprlock/lock-wallpaper.conf, a file the lock
    // no longer reads now that the lock is this shell's own surface -- so
    // picking a lock picture changed a setting and changed nothing on screen.
    // Reading it here is what makes the setting real.
    //
    // Empty = follow the login picture below, which is the normal state: the
    // lock and the login are one screen, so they show one picture.
    readonly property string configuredLockWallpaper: Config.options.background.wallpaperPathLock ?? ""
    readonly property string lockBackdropUrl: root.configuredLockWallpaper.length > 0
        ? "file://" + root.configuredLockWallpaper
        : root.greeterBackdropUrl

    Process {
        id: greeterBackdropProc
        command: ["bash", "-c", Quickshell.shellPath("scripts/lock/greeter-backdrop.sh")]
        stdout: StdioCollector {
            onStreamFinished: {
                const path = text.trim();
                root.greeterBackdropUrl = path.length > 0 ? "file://" + path : "";
            }
        }
    }
    function refreshGreeterBackdrop(): void {
        // `running` reads false again once the process has exited, so this is
        // a re-run and not a no-op; the explicit false first covers being
        // called while one is still in flight.
        greeterBackdropProc.running = false;
        greeterBackdropProc.running = true;
    }
    // Re-resolved on every lock, not once at startup: the greeter is a
    // separate process that can be reconfigured while this session runs, and
    // a lock screen showing last boot's picture is exactly the drift this is
    // here to remove.
    Connections {
        target: GlobalStates
        function onScreenLockedChanged() {
            if (GlobalStates.screenLocked)
                root.refreshGreeterBackdrop();
        }
    }
    Component.onCompleted: root.refreshGreeterBackdrop()

    // This stores all the information shared between the lock surfaces on each screen.
    // https://github.com/quickshell-mirror/quickshell-examples/tree/master/lockscreen
    LockContext {
        id: lockContext

        Connections {
            target: GlobalStates
            function onScreenLockedChanged() {
                if (GlobalStates.screenLocked) {
                    lockContext.reset();
                    lockContext.tryFingerUnlock();
                }
            }
        }

        onUnlocked: (targetAction) => {
            // Perform the target action if it's not just unlocking
            if (targetAction == LockContext.ActionEnum.Poweroff) {
                Session.poweroff();
                return;
            } else if (targetAction == LockContext.ActionEnum.Reboot) {
                Session.reboot();
                return;
            }

            // Unlock the keyring if configured to do so
            if (Config.options.lock.security.unlockKeyring) root.unlockKeyring(); // Async

            // Unlock the screen before exiting, or the compositor will display a
            // fallback lock you can't interact with.
            GlobalStates.screenLocked = false;

            // Reset
            lockContext.reset();

            // Post-unlock actions
            if (lockContext.alsoInhibitIdle) {
                lockContext.alsoInhibitIdle = false;
                Idle.toggleInhibit(true);
            }
        }
    }

    // HARD-DISABLED ON PURPOSE -- do not re-enable.
    //
    // This used to be `locked: GlobalStates.screenLocked`, which let Quickshell
    // acquire the Wayland session lock itself. Quickshell hot-reloads its ENTIRE
    // QML tree whenever any watched file changes, so editing any shell file while
    // the screen was locked destroyed this object mid-lock. Hyprland then reported
    // that the lockscreen app had died and covered the session with its
    // lockdead2.png fallback, which is the error that kept appearing.
    //
    // Pinning it to false means the shell can never take a session lock no matter
    // what any config value says. hyprlock holds the lock instead -- it is a
    // separate process, so nothing the shell does can disturb it.
    WlSessionLock {
        id: lock
        locked: false
        surface: root.sessionLockSurface
    }

    // Locking is now one line: the layer surfaces above are already bound to
    // this flag, so setting it IS the lock. The hyprlock hand-off that used to
    // live here (and the `useHyprlock` switch that chose it) is gone -- the
    // lock and the login are one screen now, and that screen is this one.
    function lock() {
        GlobalStates.screenLocked = true;
    }

    IpcHandler {
        target: "lock"

        function activate(): void {
            root.lock();
        }
        function focus(): void {
            lockContext.shouldReFocus();
        }
        // Diagnostic: which picture the lock screen is about to draw, and
        // whether one resolved at all. Readable while UNLOCKED on purpose --
        // locking to check it would need the password to undo.
        function backdrop(): string {
            root.refreshGreeterBackdrop();
            return "backdrop=" + (root.lockBackdropUrl.length > 0
                ? root.lockBackdropUrl : "NONE (flat wash)")
                + " source=" + (root.configuredLockWallpaper.length > 0 ? "lock" : "login")
                + " locked=" + String(GlobalStates.screenLocked);
        }
        // Which login template the lock is about to draw, and where that
        // answer came from. Readable while UNLOCKED on purpose -- locking to
        // check it would need the password to undo.
        //
        // This exists because the lock and the login used to disagree for
        // months with nothing to look at: the lock asked for a template the
        // greeter was showing, did not recognise it, and silently drew its
        // fallback. `known=false` is that failure, named.
        function layout(): string {
            return "template=" + LoginLayouts.current
                + " known=" + String(LoginLayouts.currentKnown)
                + " sheet=" + String(LoginLayouts.sheet)
                + " hud=" + String(LoginLayouts.hud)
                + " greeter=" + LoginLayouts.sddmActive
                + " shell=" + (Persistent.states.loginLayout ?? "")
                + " templates=" + LoginLayouts.list.length
                + " loaded=" + String(LoginLayouts.indexLoaded)
                + " data=" + (LoginLayouts.indexData
                    ? String(LoginLayouts.indexData.list.length) : "null");
        }
    }

    GlobalShortcut {
        name: "lock"
        description: "Locks the screen"

        onPressed: {
            root.lock()
        }
    }

    GlobalShortcut {
        name: "lockFocus"
        description: "Re-focuses the lock screen. This is because Hyprland after waking up for whatever reason"
            + "decides to keyboard-unfocus the lock screen"

        onPressed: {
            lockContext.shouldReFocus();
        }
    }

    function initIfReady() {
        if (!Config.ready || !Persistent.ready) return;
        if (Config.options.lock.launchOnStartup && Persistent.isNewHyprlandInstance) {
            root.lock();
        } else {
            KeyringStorage.fetchKeyringData();
        }
    }
    Connections {
        target: Config
        function onReadyChanged() {
            root.initIfReady();
        }
    }
    Connections {
        target: Persistent
        function onReadyChanged() {
            root.initIfReady();
        }
    }
}
