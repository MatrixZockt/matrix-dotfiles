pragma ComponentBehavior: Bound
import qs
import QtQuick
import Quickshell
import Quickshell.Io
// GlobalShortcut lives here, not in Quickshell itself.
import Quickshell.Hyprland

// The shell's colour picker (SUPER + C) -- what hyprpicker was for, minus the
// dependency: a frozen grab of each screen with a crosshair, a loupe and a pill
// that shows the hex/rgba under it. One flag drives every surface; each entry
// point (GlobalShortcut, bar button, sidebar toggle, waffle snip panel) just
// sets GlobalStates.colorPickerOpen.
//
// Alongside the crosshair, every open brings the recent-colours card (the last
// few picks, bottom-left) so an earlier colour can be taken without picking it
// again. It is drawn by the picker's own surface -- see ColorPickerSurface.qml
// and ColorPickerHistory.qml -- because one window can hold both, and two
// windows could not share the keyboard and the click routing without fighting.
Scope {
    id: root

    // The last few picked hexes, newest first. In memory only on purpose: the
    // lifetime of "what I just picked" is the session, and a state file would
    // outlive its usefulness.
    readonly property int historyLimit: 5
    property var history: []
    // The output the card belongs to. Every screen runs a picker surface, so
    // without this a three-monitor pick would grow three identical cards; the
    // one the picker was opened from is the one that gets it.
    property string historyScreen: ""

    function rememberColor(hex) {
        if (!hex || hex.length === 0) return;
        root.history = [hex].concat(root.history.filter(color => color !== hex)).slice(0, root.historyLimit);
    }

    // A pick finished. Recorded only: nothing opens afterwards, because the
    // colour is already on the clipboard and the card's moment is the picker's
    // own opening (see openPicker).
    function finishPick(hex) {
        root.rememberColor(hex);
    }

    function dismiss() {
        GlobalStates.colorPickerOpen = false;
    }

    function openPicker() {
        GlobalStates.colorPickerOpen = true;
    }

    // The card's screen is stamped HERE, not in openPicker(): the sidebar
    // toggle, the bar button and the waffle snip panel all set the flag
    // themselves, and this is the one place every entry point passes through.
    Connections {
        target: GlobalStates
        function onColorPickerOpenChanged() {
            if (GlobalStates.colorPickerOpen)
                root.historyScreen = Hyprland.focusedMonitor?.name ?? "";
        }
    }

    function togglePicker() {
        if (GlobalStates.colorPickerOpen) GlobalStates.colorPickerOpen = false;
        else root.openPicker();
    }

    Variants {
        model: Quickshell.screens
        delegate: Loader {
            id: colorPickerLoader
            required property var modelData
            active: GlobalStates.colorPickerOpen

            sourceComponent: ColorPickerSurface {
                screen: colorPickerLoader.modelData
                historyColors: root.history
                showHistory: colorPickerLoader.modelData.name === root.historyScreen
                onDismiss: root.dismiss()
                onPicked: (hex) => root.finishPick(hex)
            }
        }
    }

    IpcHandler {
        target: "colorPicker"

        // qs -c ii ipc call colorPicker toggle
        function toggle() {
            root.togglePicker();
        }

        // qs -c ii ipc call colorPicker history -- the picker, which brings the
        // card with it (SUPER + C does the same).
        function history() {
            root.openPicker();
        }

        // qs -c ii ipc call colorPicker state -- what the picker thinks it
        // has, without opening anything.
        function state(): string {
            return `history=${root.history.length} picker=${GlobalStates.colorPickerOpen} colors=${root.history.join(",")}`;
        }
    }

    GlobalShortcut {
        name: "colorPicker"
        description: "Picks a color from the screen and copies its hex code"
        onPressed: root.togglePicker()
    }
}
