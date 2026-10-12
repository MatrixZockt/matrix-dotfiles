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
// FileChooser dialog (filemanager-picker.qml) -- and the desktop gestures that
// must yield to it:
//
//   * yieldLayer      the picker drops from Overlay to Top while a layer-shell
//                     sibling that must sit above it is up (the wallpaper
//                     explorer), so it rises over that instead of the reverse;
//   * setYield        how the wallpaper explorer publishes that state (one flag
//                     file, because these are separate Quickshell processes);
//   * anyPresent      "is any popup app up?", asked by the wallpaper swipe
//                     handlers before they act. Nothing writes a presence file
//                     any more, so this is false by definition -- kept because
//                     those handlers still ask, and correct either way: a
//                     gesture now acts on the focused window, which is what
//                     they want it to do.
Singleton {
    id: root

    // True while a layer-shell sibling that must sit ABOVE the files app is
    // up -- the wallpaper explorer being the case at hand. Consumed by the
    // file manager root as its layer binding:
    // `WlrLayershell.layer: PopupApps.yieldLayer ? Top : Overlay`.
    //
    // Cross-process by flag file: the popups are separate Quickshell
    // instances from the main shell that owns the explorer, so no in-memory
    // signal can reach them. The main shell publishes (this FileView writes,
    // the explorer's toggle does); every popup instance watches the same
    // file and rebinds its layer reactively. Runtime-only path in
    // XDG_RUNTIME_DIR: it is state of the running session, not config, and
    // needs no persistence across logins.
    readonly property string yieldFlagPath: `${Quickshell.env("XDG_RUNTIME_DIR") ?? "/tmp"}/quickshell-popup-yield`
    property bool yieldLayer: false

    // Polled rather than watched: FileView's inotify watch misses the
    // create/delete of the flag file when the writer is another process, and
    // a 2Hz stat+read of a one-byte file costs nothing. The layer binding
    // re-evaluates reactively whenever yieldLayer flips.
    Timer {
        interval: 500
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: { const t = Date.now(); yieldProc.running = true; StatusSignal.perfMark("popupYieldFork", Date.now() - t); }
    }

    Process {
        id: yieldProc
        command: ["sh", "-c", `cat '${root.yieldFlagPath}' 2>/dev/null || true`]
        stdout: StdioCollector {
            onStreamFinished: root.yieldLayer = text.trim().length > 0
        }
    }

    // Is ANY popup app up right now? The presence files are the registry
    // (one per app: quickshell-popup-<name>), so "any file exists" is the
    // answer. Polled on the same cheap clock as yieldLayer. Gestures consult
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

    // Publish the yield state from the main shell. Writing through
    // execDetached (like present/unpresent) keeps one write path for every
    // writer, main shell or popup instance alike.
    function setYield(on) {
        Quickshell.execDetached(["sh", "-c",
            on ? `printf '1\\n' > '${root.yieldFlagPath}'`
               : `rm -f '${root.yieldFlagPath}'`]);
    }

}

