// The task manager as an always-on-top OVERLAY.
//
// WHY THIS IS A LAYER SURFACE AND NOT A WINDOW.
//
// The task manager used to open as a separate `qs -p` desktop window (the
// settings app converting into the task-manager face). That is why it could
// never be "in front of everything": a client window lives on the Top layer,
// and a fullscreen client renders ABOVE every Top-layer surface. No amount of
// focus-stealing, raising or `always-on-top` fixes that, because the layer it
// is on is the problem.
//
// An Overlay-layer surface is above fullscreen clients by construction -- it
// is the same mechanism the bar, the switcher and the notification popups
// already use here, all of which sit correctly over a fullscreen window. So
// the task manager becomes one of those: a surface of the MAIN shell, on the
// focused monitor, with keyboard focus only while it is open.
//
// It hosts the SAME `TaskManagerContent` tree the settings window uses, so the
// UI is not rebuilt and is not duplicated: one component, two skins, exactly
// as that file's own header describes.
//
// Opened and closed over IPC (`taskManager open|close|toggle|state`), because
// the keybind lives in Hyprland and cannot touch QML directly.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs
import qs.modules.common
import qs.modules.common.functions
// The task manager UI is imported by RELATIVE PATH, exactly as settings.qml
// does it (`import "modules/taskmanager" as TaskManagerUI`), not as a module:
// modules/taskmanager/qmldir declares `module qs.modules.taskmanager`, so the
// `TaskManagerUI` name only exists inside that relative import.
import "../../taskmanager" as TaskManagerUI

Scope {
    id: root

    // MIRRORED into the shell's shared flag, not kept private.
    //
    // This surface is on the Overlay layer, so the compositor cannot close it:
    // there is no window to close. The four-finger swipe DOWN reaches it by
    // asking the shell to dismiss its popup (GlobalStates.dismissPopupForGesture
    // -> quickshell:popupDismiss), and that request answers
    // `GlobalStates.taskManagerOpen`. One flag, so the swipe, the backdrop
    // click, Escape and the IPC all close the same state -- a private `open`
    // here would have left the overlay invisible to the gesture (the bug
    // reported 2026-10-27: "popup windows like taskmanager etc are still not
    // being closed when having them open in the front").
    // (A `property alias` to the singleton is NOT possible -- "Invalid alias
    // reference. Unable to find id GlobalStates": an alias needs an id in
    // scope, and a singleton type name is not one. So the two are kept in step
    // by hand, with a guard on each side, which is the same contract without
    // the loader refusing the whole shell over it.)
    property bool open: false

    onOpenChanged: {
        // Closed from outside (the four-finger swipe asks the shell to put its
        // popup away, which answers the shared flag): drop the deep-link key
        // exactly as close() does, or the next open would land on the old page.
        if (!root.open && root.requestedKey !== "")
            root.requestedKey = "";
        if (GlobalStates.taskManagerOpen !== root.open)
            GlobalStates.taskManagerOpen = root.open;
    }

    Connections {
        target: GlobalStates
        function onTaskManagerOpenChanged() {
            if (root.open !== GlobalStates.taskManagerOpen)
                root.open = GlobalStates.taskManagerOpen;
        }
    }
    // A key the caller can hand over (the launcher's "memory", a settings
    // tile naming a device), so the deep links keep working on this skin.
    property string requestedKey: ""

    function show(key) {
        if (key !== undefined && key !== null && key !== "")
            root.requestedKey = key;
        root.open = true;
    }

    // `reason` is not decoration: "the task manager closed by itself" is the
    // kind of report that is unanswerable without knowing WHICH path closed
    // it, and every caller here has a different answer (a stray click, the
    // Escape inside the app, a keybind, the launcher). One line in the shell
    // log settles it.
    function close(reason) {
        console.log("[TaskManagerOverlay] closed by: " + (reason ?? "unspecified"));
        root.open = false;
        root.requestedKey = "";
    }

    function toggle() {
        if (root.open)
            root.close("toggle()");
        else
            root.show("");
    }

    IpcHandler {
        target: "taskManager"

        function open(key: string): void {
            root.show(key);
        }

        // Named `close`, not `quit`: `qs ipc call` has its own subcommands and
        // a colliding name is refused before it ever reaches the handler.
        function dismiss(): void {
            root.close("ipc dismiss");
        }

        function toggle(key: string): void {
            if (root.open)
                root.close("ipc toggle");
            else
                root.show(key);
        }

        function state(): string {
            return `open=${root.open} key=${root.requestedKey}`;
        }
    }

    // One surface on the focused monitor only: a second monitor must not get a
    // duplicate task manager drawn over it.
    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: surface
            required property var modelData

            screen: surface.modelData
            visible: root.open
                && (Hyprland.monitorFor(surface.modelData)?.id === Hyprland.focusedMonitor?.id)

            WlrLayershell.namespace: "quickshell:taskManager"
            WlrLayershell.layer: WlrLayer.Overlay
            // Focus ONLY while open, so the surface never steals typing from
            // the app underneath when it is merely mapped.
            WlrLayershell.keyboardFocus: root.open
                ? WlrKeyboardFocus.Exclusive
                : WlrKeyboardFocus.None
            exclusionMode: ExclusionMode.Ignore
            exclusiveZone: 0
            color: "transparent"

            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }

            // A press on the backdrop closes, like every other overlay here.
            MouseArea {
                anchors.fill: parent
                onClicked: root.close("backdrop click")
            }

            Rectangle {
                id: scrim
                anchors.fill: parent
                color: Appearance.colors.colScrim ?? "#000000"
                opacity: 0.35
            }

            Rectangle {
                id: card
                anchors.centerIn: parent
                width: Math.min(1180, parent.width - 120)
                height: Math.min(760, parent.height - 120)
                radius: Appearance.rounding.large
                color: Appearance.colors.colLayer0
                border.width: 1
                border.color: Appearance.colors.colLayer0Border
                clip: true

                TaskManagerUI.TaskManagerContent {
                    id: content
                    anchors.fill: parent
                    selectedKey: root.requestedKey !== "" ? root.requestedKey : "apps"
                    onSelectedKeyChanged: root.requestedKey = selectedKey
                    // This skin is standalone: there is no settings window
                    // behind it to return to, and Escape closes the surface.
                    showBackButton: false
                    onQuitRequested: root.close("content quitRequested (Escape inside)")
                }

                // Escape closes the surface. On the Overlay layer the shell
                // does not get the key for free, so the focus is claimed by
                // the card and the key is handled here.
                FocusScope {
                    anchors.fill: parent
                    focus: root.open
                    Keys.onEscapePressed: root.close("focus scope Escape")
                }
            }
        }
    }
}
