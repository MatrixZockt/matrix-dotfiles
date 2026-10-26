pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import QtQuick

// LEFTOVER POPUP PLUMBING, shell-side.
//
// This singleton used to be the registry of the "popup apps" -- the settings
// app, the task manager and the file manager were full-screen layer-shell
// surfaces with presence files, veil rules and a morph into a real window.
// All three are ordinary desktop windows now (settings.qml hosts two faces of
// one Window, filemanager.qml is the third), so the registry rows, the window
// title table, the presence files and the morph are gone -- the compositor
// needs no help closing, tiling or fullscreening a real window.
//
// What is left is the ONE layer surface in the group -- the portal's
// FileChooser dialog (filemanager-picker.qml), which now lives in the Overlay
// layer for its whole life (see the note in that file) -- and one question the
// desktop gestures ask:
//
//   * anyPresent      "is any popup app up?", asked by the wallpaper swipe
//                     handlers before they act. Nothing writes a presence file
//                     any more, so this is false by definition -- kept because
//                     those handlers still ask, and correct either way: a
//                     gesture now acts on the focused window, which is what
//                     they want it to do.
//
// The yield flag (yieldLayer / setYield / its poll and writer in the wallpaper
// explorer) is gone with the dialog's layer CHANGE. It existed so the wallpaper
// explorer could rise above a dialog that was already open, by dropping the
// dialog to the Top layer -- but the dialog published the flag itself, so it
// dropped on every open, and on Hyprland 0.56.2 a layer surface that changes
// layer while mapped is faded to alpha 0 under a fullscreen window: a dialog
// that was up, drawing and answering probes, and invisible on screen.
Singleton {
    id: root

    // Is ANY popup app up right now? The presence files are the registry
    // (one per app: quickshell-popup-<name>), so "any file exists" is the
    // answer. Polled on a cheap 2Hz clock. Gestures consult
    // this before acting.
    property bool anyPresent: false

    Timer {
        interval: 500
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: { const t = Date.now(); presenceProbe.running = true; StatusSignal.perfMark("popupPresenceFork", Date.now() - t); }
    }
    Process {
        id: presenceProbe
        command: ["sh", "-c", `ls '${Quickshell.env("XDG_RUNTIME_DIR") ?? "/tmp"}'/quickshell-popup-* 2>/dev/null | head -1`]
        stdout: StdioCollector {
            onStreamFinished: root.anyPresent = text.trim().length > 0
        }
    }

}

