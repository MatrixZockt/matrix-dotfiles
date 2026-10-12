import qs
import qs.services
import qs.modules.common
import QtQuick
import Quickshell.Io
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

Scope {
    id: root
    property int sidebarWidth: Appearance.sizes.sidebarWidth

    PanelWindow {
        id: panelWindow
        // ALWAYS mapped: the open/close is a spring on the content (stretch
        // from the screen edge + fade), not a layer remap. Remapping played
        // only the compositor's popin -- this way the sidebar genuinely
        // stretches out of the edge and back, in and out, like the top bar's
        // hover tabs. An empty input mask while closed keeps the surface
        // click-through.
        visible: true
        property bool open: GlobalStates.sidebarRightOpen
        // 0..1 spring driving the whole motion.
        property real t: open ? 1 : 0
        Behavior on t {
            // Asymmetric, chosen by direction, and deliberately the same pair
            // SidebarLeft.qml uses so the two sidebars cannot drift apart:
            // decelerate in, accelerate out, 200ms/150ms. See
            // Appearance.animation for why these are not elementMoveEnter.
            //
            // ONE inline NumberAnimation whose duration and curve are bound,
            // rather than `animation:` picking between two Components. A
            // Behavior accepts its animation exactly once -- re-assigning it
            // is a runtime error ("Cannot change the animation assigned to a
            // Behavior") -- so the direction has to be expressed INSIDE the
            // animation. Qualifying `open` with the window's id is also
            // required: an attached Behavior does not see the target object's
            // bare property names.
            NumberAnimation {
                alwaysRunToEnd: true
                duration: panelWindow.open
                    ? Appearance.animation.sidebarRevealEnter.duration
                    : Appearance.animation.sidebarRevealExit.duration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: panelWindow.open
                    ? Appearance.animationCurves.emphasizedDecel
                    : Appearance.animationCurves.emphasizedAccel
            }
        }

        function hide() {
            GlobalStates.sidebarRightOpen = false;
        }

        exclusiveZone: 0
        implicitWidth: sidebarWidth
        // Overlay (not the default Top) so an open sidebar draws over a
        // fullscreen window instead of silently vanishing behind it. A
        // fullscreen client renders above every Top-layer surface, which is
        // exactly what made the sidebar look broken while fullscreen. Settings >
        // Sidebars can put it back in the Top layer.
        WlrLayershell.layer: (Config?.options.sidebar?.showInFullscreen ?? true) ? WlrLayer.Overlay : WlrLayer.Top
        WlrLayershell.namespace: "quickshell:sidebarRight"
        WlrLayershell.keyboardFocus: GlobalStates.sidebarRightOpen ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        color: "transparent"

        mask: Region {
            x: 0
            y: 0
            width: panelWindow.t > 0.1 ? panelWindow.width : 0
            height: panelWindow.t > 0.1 ? panelWindow.height : 0
        }

        // ── The screen edge is an OPENING gesture, both halves of it ──────
        //
        // Mirrored from SidebarLeft, and it is that file's lesson too: this
        // used to be a click-to-close sliver, on the reasoning that the edge
        // strip OPENS the panel by hover so a click arriving afterwards would
        // find it already up and, if it could only open, do nothing at all.
        //
        // Backwards, as a real mouse showed: pointer on the edge, hover opens
        // the panel, user clicks to bring it out -- and this sliver dismissed
        // it. Every time, which reads as "the sidebar only opens on hover".
        //
        // The top edge's rule is the good one (Bar.qml's fsEdgePress: a press
        // only ever opens, and a press on the revealed bar is a no-op), so the
        // right edge now follows it: the strip opens, and a click on the
        // panel's own edge does nothing. Leaving the edge, Esc, the bar's
        // buttons and the shortcuts still close it.
        //
        // The mask above already covers these pixels while the panel is out, so
        // a click here stays with the panel rather than reaching the app.

        anchors {
            top: true
            right: true
            bottom: true
        }

        onOpenChanged: {
            if (open) {
                GlobalFocusGrab.addDismissable(panelWindow);
                // Armed from the live hover state, not forced to false. Opened
                // from the screen edge the pointer is already over the panel by
                // the time this runs, and forcing the flag false left the
                // mouse-out close disarmed with no further hover transition
                // coming to re-arm it. Off the edge (a keybind) the hover is
                // false and the panel correctly stays put.
                panelWindow.pointerWasInside = windowHover.hovered;
            } else {
                GlobalFocusGrab.removeDismissable(panelWindow);
            }
        }

        // ── Close when the pointer leaves ─────────────────────────────
        // Same contract as the left sidebar: a passive HoverHandler on the
        // window (it does not block hover for the controls inside), and a
        // short-grace timer that fires only after the pointer has been here
        // and then left. "Not on a pixel, with a small buffer": 12px of slack
        // plus half a second absorbs an overshoot -- crossing to a nested
        // control, or moving slightly too far on the way somewhere else --
        // without ever reading as a lag on a deliberate exit.
        property bool pointerWasInside: false

        // ── What counts as "still on the sidebar": the CARD, not the window ──
        //
        // Mirrors SidebarLeft.qml's block exactly, and for the same reason
        // measured there: the HoverHandler covers the WINDOW, whose width is
        // not the card's -- the card is inset by the elevation margin and the
        // outer gaps (see the contentStage Loader below), so the window's edge
        // is a strip of empty surface beside it. Deciding the close from the
        // pointer's POSITION against the card's own rectangle means the panel
        // retracts when the pointer is genuinely away from the card, instead of
        // never -- and the two numbers below decide what "away" means: how far
        // past the card still counts as being on it, and how long a departure
        // may last before it is taken at its word.
        //
        // The region reaches the screen edge on the sidebar's own side: that is
        // where the edge strip (EdgeReveal.qml) is, and a hand resting on it
        // has not left the sidebar.
        readonly property real cardLeft: Appearance.sizes.elevationMargin
        readonly property real cardTop: Appearance.sizes.hyprlandGapsOut
        readonly property real cardWidth: Math.max(0, root.sidebarWidth
            - Appearance.sizes.hyprlandGapsOut - Appearance.sizes.elevationMargin)
        readonly property real cardHeight: Math.max(0, panelWindow.height
            - Appearance.sizes.hyprlandGapsOut * 2)
        // Slack around that card, in pixels: the same 12 as the left sidebar's,
        // and for the same measured reason -- at 4, "outside" began the instant
        // the cursor crossed the edge, so an overshoot of a few pixels was
        // treated exactly like having left for good. 12px is about one
        // deliberate slip of the hand.
        readonly property real pointerOutBuffer: 12

        // How long the pointer may sit outside that region before the panel
        // retracts. Half a second: long enough to come back from an overshoot,
        // short enough that leaving on purpose still reads as leaving.
        //
        // NOT scaled by `motionScale` -- this is slack for a hand, not an
        // animation, and a hand does not move faster on a different power
        // profile. (The two sides keep the same numbers: this block and the
        // left sidebar's are a mirror, deliberately.)
        readonly property int pointerOutGraceMs: 500

        // Live pointer position, in this window's coordinates, for as long as
        // the pointer is on this surface at all -- a bound property of its own
        // so the close decision below re-evaluates on every motion.
        readonly property var pointerPos: windowHover.point.position

        readonly property bool pointerOnCard: {
            if (!windowHover.hovered)
                return false;
            const p = panelWindow.pointerPos;
            if (p.y < panelWindow.cardTop - panelWindow.pointerOutBuffer)
                return false;
            if (p.y > panelWindow.cardTop + panelWindow.cardHeight + panelWindow.pointerOutBuffer)
                return false;
            // The window's own right edge, not the card's plus a buffer: the
            // edge strip the panel is opened from lives there.
            return p.x <= panelWindow.width
                && p.x >= panelWindow.cardLeft - panelWindow.pointerOutBuffer;
        }

        HoverHandler {
            id: windowHover
            onHoveredChanged: {
                if (hovered)
                    panelWindow.pointerWasInside = true;
            }
        }            Timer {
            id: mouseOutTimer
            interval: panelWindow.pointerOutGraceMs
            repeat: false
            // Held down for the whole of a task drag.
            //
            // A reorder is the one gesture here that is EXPECTED to leave the
            // panel -- the cursor has to travel down the list and often past
            // its edge. Closing on that pointer-out tore the panel down
            // mid-gesture: the loader was deactivated, the delegate being
            // carried was destroyed with it, and the task jumped back to the
            // last slot it had crossed instead of landing where it was
            // released.
            //
            // The session and power menus are the second such gesture, for the
            // same reason: their rows are in a separate popup window, so
            // getting the cursor from the button to the menu necessarily leaves
            // this panel. Closing here made the menu vanish as the user
            // reached for it. `sidebarRightPopupOpen` suspends the pointer-out
            // close for exactly as long as one of them is up; when it goes
            // back to false the condition is true again and this timer re-arms
            // by itself, so the sidebar still closes on its own once the menu is
            // gone and the pointer is elsewhere.
            running: GlobalStates.sidebarRightOpen && panelWindow.pointerWasInside
                && !panelWindow.pointerOnCard && !Todo.dragInFlight
                && !GlobalStates.sidebarRightPopupOpen
            onTriggered: {
                // Re-checked, not just guarded on `running`: the popup flag can
                // flip back to false while this timer is sitting on its half
                // second, and closing then would be exactly the bug.
                if (!panelWindow.pointerOnCard && !Todo.dragInFlight
                    && !GlobalStates.sidebarRightPopupOpen)
                    panelWindow.hide();
            }
        }
        Connections {
            target: GlobalFocusGrab
            function onDismissed() {
                // A dismissal mid-drag would tear the panel down under the
                // gesture exactly as the pointer-out path used to: the delegate
                // being carried is destroyed with the loader and the task
                // reappears at the last slot it crossed. A drag is the one
                // interaction that has to survive the panel wanting to close.
                if (Todo.dragInFlight)
                    return;
                panelWindow.hide();
            }
        }

        Item {
            id: contentStage
            anchors.fill: parent

            // The stretch: grows out of the RIGHT edge (origin pinned there),
            // with a slight vertical breathe -- the same expressive spring the
            // bar's droplet uses.
            transform: [
                Scale {
                    id: popScale
                    xScale: 0.82 + 0.18 * panelWindow.t
                    yScale: 0.96 + 0.04 * panelWindow.t
                    origin.x: contentStage.width
                    origin.y: contentStage.height / 2
                }
            ]
            opacity: panelWindow.t
            visible: panelWindow.t > 0.001

            Loader {
            id: sidebarContentLoader
            active: GlobalStates.sidebarRightOpen || Config?.options.sidebar.keepRightSidebarLoaded
            anchors {
                fill: parent
                margins: Appearance.sizes.hyprlandGapsOut
                leftMargin: Appearance.sizes.elevationMargin
            }
            width: sidebarWidth - Appearance.sizes.hyprlandGapsOut - Appearance.sizes.elevationMargin
            height: parent.height - Appearance.sizes.hyprlandGapsOut * 2

            focus: GlobalStates.sidebarRightOpen
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    panelWindow.hide();
                }
            }

            sourceComponent: SidebarRightContent {}
            }
        }
    }

    IpcHandler {
        target: "sidebarRight"

        function toggle(): void {
            GlobalStates.sidebarRightOpen = !GlobalStates.sidebarRightOpen;
        }

        function close(): void {
            GlobalStates.sidebarRightOpen = false;
        }

        function open(): void {
            GlobalStates.sidebarRightOpen = true;
        }

        // Mirrors sidebarLeft.state(): flag, animation value, and the input
        // region the surface is actually declaring, so "it is open but nothing
        // is drawn / nothing is clickable" is a readable state instead of a
        // guess. See the same note in SidebarLeft.qml.
        function state(): string {
            // `onCard` and `cardLeft` are the pointer-out close's own inputs --
            // see the same note in SidebarLeft.qml.
            return `open=${GlobalStates.sidebarRightOpen} t=${panelWindow.t.toFixed(2)}`
                + ` mask=${panelWindow.mask.width.toFixed(0)}x${panelWindow.mask.height.toFixed(0)}@${panelWindow.mask.x.toFixed(0)}`
                + ` window=${panelWindow.width.toFixed(0)}x${panelWindow.height.toFixed(0)}`
                // The pointer-out close's two magnitudes, read off the live
                // window rather than the source (see SidebarLeft.qml).
                + ` buffer=${panelWindow.pointerOutBuffer}`
                + ` grace=${panelWindow.pointerOutGraceMs}`
                + ` onCard=${panelWindow.pointerOnCard}`
                + ` cardLeft=${panelWindow.cardLeft.toFixed(0)}`
                + ` latch=${GlobalStates.sidebarRightEdgeLatch}`;
        }
    }

    GlobalShortcut {
        name: "sidebarRightToggle"
        description: "Toggles right sidebar on press"

        onPressed: {
            GlobalStates.sidebarRightOpen = !GlobalStates.sidebarRightOpen;
        }
    }
    GlobalShortcut {
        name: "sidebarRightOpen"
        description: "Opens right sidebar on press"

        onPressed: {
            GlobalStates.sidebarRightOpen = true;
        }
    }
    GlobalShortcut {
        name: "sidebarRightClose"
        description: "Closes right sidebar on press"

        onPressed: {
            GlobalStates.sidebarRightOpen = false;
        }
    }
}
