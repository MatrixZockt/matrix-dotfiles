import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

Scope {
    id: root

    property Component regionComponent: Component {
        Region {}
    }
    
    Loader {
        id: overlayLoader
        active: GlobalStates.overlayOpen || OverlayContext.hasPinnedWidgets
        sourceComponent: PanelWindow {
            id: overlayWindow
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "quickshell:overlay"
            WlrLayershell.layer: WlrLayer.Overlay
            // Use OnDemand for pinned widgets to allow focus switching with mouse clicks
            WlrLayershell.keyboardFocus: GlobalStates.overlayOpen ? WlrKeyboardFocus.Exclusive : (OverlayContext.clickableWidgets.length > 0 ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None)
            visible: true
            color: "transparent"

            mask: Region {
                item: GlobalStates.overlayOpen ? overlayContent : null
                regions: OverlayContext.clickableWidgets.map((widget) => regionComponent.createObject(this, {
                    item: widget
                }));
            }

            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }

            HyprlandFocusGrab {
                id: grab
                windows: [overlayWindow]
                active: false
                onCleared: () => {
                    if (!active) GlobalStates.overlayOpen = false;
                }
            }

            Connections {
                target: GlobalStates
                function onOverlayOpenChanged() {
                    delayedGrabTimer.restart();
                }
            }

            Timer {
                id: delayedGrabTimer
                interval: Appearance.animation.elementMoveFast.duration
                onTriggered: {
                    grab.active = GlobalStates.overlayOpen;
                }
            }

            OverlayContent {
                id: overlayContent
                anchors.fill: parent
            }
        }
    }

    IpcHandler {
        target: "overlay"

        function toggle(): void {
            GlobalStates.overlayOpen = !GlobalStates.overlayOpen;
        }

        // Bring one specific widget up and show the overlay, without disturbing
        // the others. This is what lets something outside the shell -- the
        // launcher's Task Manager entry, a keybind, a script -- open the hardware
        // monitor directly instead of starting a separate application for it.
        //
        //   qs -c ii ipc call overlay reveal resources
        //   qs -c ii ipc call overlay reveal resources memory
        //
        // The second argument is optional in effect but not in the signature: it
        // names the device the hardware monitor should open on (see
        // OverlayContext.requestedDeviceKey), and an empty string means "the one
        // selected last". Both are always passed, because the CLI matches
        // arguments by position -- which is why
        // scripts/launch/task-manager.sh takes the key as an optional argument
        // rather than this taking an optional parameter.
        //
        // Not called `show`, deliberately: `qs ipc show` already exists, so a
        // function with that name is swallowed by the cli before it ever reaches
        // the shell and the argument is rejected as unexpected.
        //
        // The widget is centred, not restored to wherever it was dragged last.
        //
        // The request is left as a flag for the widget to pick up as it is
        // created, rather than emitted as a signal or armed on a timer: at this
        // point the delegate does not exist yet, and "wait ~120ms and hope" is
        // the kind of guess that silently stops working the first time the
        // window maps a little slower.
        function reveal(identifier: string, key: string): void {
            if (!Persistent.states.overlay.open.includes(identifier))
                Persistent.states.overlay.open = Persistent.states.overlay.open.concat([identifier]);
            OverlayContext.centerOnOpenIdentifier = identifier;
            // Only meaningful for the hardware monitor; the other cards ignore
            // it. Set BEFORE the overlay opens so the card finds it already in
            // place as it is created.
            OverlayContext.requestedDeviceKey = key ?? "";
            GlobalStates.overlayOpen = true;
        }
    }

    GlobalShortcut {
        name: "overlayToggle"
        description: "Toggles overlay on press"

        onPressed: {
            GlobalStates.overlayOpen = !GlobalStates.overlayOpen;
        }
    }
}
