pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import QtQuick
import qs
import qs.services

/**
 * The 3-finger swipe open of the wallpaper carousel.
 *
 * Mirrors WallpaperSwipe.qml (the 4-finger one) but for THREE fingers, whose
 * compositor gestures belong to the island panel and the field-move script
 * (custom/general.lua). There is no compositor trigger for this one at all:
 * a second instance of the evdev tracker (touchpad-swipe.py --fingers 3)
 * watches the pad and both the OPEN and the FRAMES come from here.
 *
 * The tracker is launched lazily, only while the carousel theatre is open --
 * no permanent extra process. While it runs, the theatre's carousel consumes
 * its dx frames as 1:1 horizontal scroll (WallpaperModal wires them in), so
 * three fingers drive the ring exactly like two. A decisive downward travel
 * still closes the theatre; a 3-finger TAP still opens the carousel (the
 * 4-finger tracker routes that via shell.qml -- taps never reach this
 * session, because taps end before the theatre opens).
 *
 * On close the tracker is stopped and the singleton resets -- a fresh open
 * starts a fresh session, so no stale fraction ever leaks between opens.
 */
Singleton {
    id: root

    readonly property string script: Quickshell.shellPath("scripts/input/touchpad-swipe.py")

    /// The 3-finger tracker is alive and found a device.
    property bool available: false
    /// True from the first real travel frame until the fingers lift: the
    /// theatre's entrance is being driven by hand.
    property bool opening: false
    /// Cumulative horizontal travel this session, in fractions of the pad's
    /// WIDTH (the tracker's htotal). The carousel converts to cards.
    property real totalX: 0
    /// Per-frame dx/dy (fractions of the pad), consumed by the carousel.
    property real frameDx: 0
    property real frameDy: 0
    /// Diagnostics line from the tracker.
    property string note: ""

    /// How much horizontal travel (pad sweeps) opens the theatre when the
    /// swipe arrives while it is closed. Roughly a tenth of a sweep: a
    /// deliberate pull, not a brush.
    readonly property real openTravel: 0.10

    Process {
        id: trackerProc
        // 2 AND 3, not 3 alone.
        //
        // `--fingers` is a SET and membership in it is the whole gate: in
        // touchpad-swipe.py's report(), a contact whose count is not in the
        // set hits `count not in self.finger_set` and the session is ENDED
        // before a gesture can begin. At `--fingers 3` a two-finger contact
        // was therefore not a gesture that failed to turn the ring -- it was
        // not a gesture at all, and the carousel only ever followed the pad
        // when three fingers were down. That is the reported "it only swipes
        // with 3 fingers, not 2", and it was a one-token omission here, not
        // anything in the carousel's own gesture code (which handles both
        // counts identically -- see carFrame below).
        //
        // 4 is deliberately left out: four fingers is the compositor's own
        // workspace gesture, and the bar's brightness/volume swipe already
        // lives in TouchpadSwipe's tracker at `--fingers 2,3,4`.
        command: ["bash", "-c", `trap 'kill -- "-$$" 2>/dev/null; pkill -P $$ 2>/dev/null' EXIT; python3 -u ${root.script} --fingers 2,3 & wait $!`]
        running: false

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: line => {
                if (!line) return;
                root.note = line;
                if (line.startsWith("tracking ")) root.available = true;
            }
        }
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => root.consume(line)
        }
        onExited: {
            root.available = false;
            root.reset();
        }
    }

    function start() {
        if (trackerProc.running) return;
        root.available = false;
        trackerProc.running = true;
    }

    function stop() {
        if (trackerProc.running)
            trackerProc.running = false; // the bash trap reaps the python child
        root.reset();
    }

    function reset() {
        root.available = false;
        root.opening = false;
        root.totalX = 0;
        root.frameDx = 0;
        root.frameDy = 0;
    }

    function consume(line) {
        if (!line || line.length === 0) return;
        let report;
        try { report = JSON.parse(line); } catch (e) { return; }
        if (!report || typeof report.phase !== "string") return;
        switch (report.phase) {
        case "begin":
            root.totalX = 0;
            break;
        case "update":
            root.frameDx = report.dx ?? 0;
            root.frameDy = report.dy ?? 0;
            root.totalX = report.htotal ?? root.totalX;
            // Open-on-pull: if the theatre is CLOSED and the pull is real,
            // three fingers opening it beats tapping first. Same guards as
            // every other open path: no popups, empty desktop.
            if (!GlobalStates.wallpaperStageOpen && !root.opening
                && Math.abs(root.totalX) >= root.openTravel) {
                if (!PopupApps.anyPresent && WallpaperSwipe.desktopEmptyNow()) {
                    root.opening = true;
                    GlobalStates.wallpaperStageOpen = true;
                }
            }
            // Frames reach the carousel whenever the theatre is open --
            // whether this swipe opened it or it was already up.
            if (GlobalStates.wallpaperStageOpen)
                root.carFrame();
            break;
        case "end":
        case "cancel":
            if (root.opening)
                root.sessionEnded();
            root.totalX = 0;
            break;
        }
    }

    signal carFrame()
    signal sessionEnded()
}

