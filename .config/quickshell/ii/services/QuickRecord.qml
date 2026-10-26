pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import qs.modules.common.functions
import qs.services
// GlobalStates lives in the config root, and a file under services/ only sees
// it with this import -- the same ReferenceError MusicPlayer.qml documents.
// What it bought: "Saved · <file>" after a stop was silently swallowed, and
// the stop itself looked like it had done nothing.
import qs
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Screen recording state -- the thing behind SUPER+S (record mode) and SUPER+R.
 *
 * WHAT RECORDS. gpu-screen-recorder, through scripts/videos/record-region.sh.
 * It is not wf-recorder, which this service used to assume: wf-recorder is not
 * installed on this machine, so every recording path failed before the first
 * frame, and it has no pause at all -- the only "pause" it offers is stopping
 * the file and starting another one. gpu-screen-recorder encodes on the GPU's
 * own hardware and pauses a LIVE capture when it is sent SIGUSR2, which is the
 * difference between a control box with a pause button and a control box that
 * lies.
 *
 * WHY A SCRIPT AND NOT THIS FILE. The pid. Quickshell's Process type has no pid
 * property and `execDetached` does not hand back a child, so there would be
 * nothing for pause/stop to signal. record-region.sh owns the pid file and
 * speaks five verbs (`start`, `pause`, `resume`, `toggle-pause`, `stop`,
 * `state`); this singleton is the QML side of that conversation.
 *
 * WHO OWNS THE TRUTH. The script does, not this service. The pill polls
 * `state` rather than trusting its own bookkeeping, for the same reason the
 * old version polled the process table: a recording can be started from a path
 * this file never saw (a terminal, another shell, `qs ipc call recorder
 * start-region`), and the pill and its clock must be right for those too.
 *
 * COORDINATES. `startRegion` takes Hyprland's logical rectangle, which is what
 * the snip UI has. gpu-screen-recorder scales it to the output's real pixels
 * itself -- verified: 400x300+120+120 on this 1.5x output produced a 600x450
 * file -- so this file does NOT multiply by the monitor scale the way the grim
 * path in RegionSelection does.
 */
Singleton {
    id: root

    readonly property bool recording: root._recording
    readonly property bool paused: root._paused
    readonly property int elapsed: root._elapsed
    readonly property string path: root._path
    // WHAT IS BEING CAPTURED, in Hyprland's logical space: `{ x, y, w, h }` or
    // null when unknown. The shell draws a frame around it and parks the
    // control box against its edge (asked for 2026-10-22: "show the space that
    // its recording"). It comes from the script's state file, not from these
    // functions, so a recording started from a terminal is framed too.
    readonly property var region: root._region
    readonly property string mode: root._mode

    property bool _recording: false
    property bool _paused: false
    property int _elapsed: 0
    property string _path: ""
    property var _region: null
    property string _mode: ""
    // Set once per stop so a surface can say where the clip went.
    property string lastSavedPath: ""
    property int saveSeq: 0

    function clock(sec) {
        const s = Math.max(0, sec | 0);
        return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
    }

    function _geometry(x, y, w, h) {
        // Physical-safe integers; the script passes the string to gsr verbatim.
        return `${Math.max(1, Math.round(w))}x${Math.max(1, Math.round(h))}`
            + `+${Math.max(0, Math.round(x))}+${Math.max(0, Math.round(y))}`;
    }

    function startRegion(x, y, w, h, withSound) {
        if (root.recording) {
            GlobalStates.showSignalToast(Translation.tr("Already recording"), "info", 1600);
            return false;
        }
        const cmd = [Directories.recordRegionScriptPath, "start", "region", root._geometry(x, y, w, h)];
        if (withSound) cmd.push("sound");
        // The frame goes up NOW, from the numbers the snip already has. Waiting
        // for the first `state` poll would leave the capture running for ~200 ms
        // with nothing marking it, which is exactly the moment you are unsure
        // whether it started.
        root._mode = "region";
        root._region = {
            x: Math.round(x), y: Math.round(y),
            w: Math.round(Math.max(1, w)), h: Math.round(Math.max(1, h))
        };
        startProc.command = cmd;
        startProc.running = true;
        return true;
    }

    function startFullscreen(withSound) {
        if (root.recording) {
            GlobalStates.showSignalToast(Translation.tr("Already recording"), "info", 1600);
            return false;
        }
        const cmd = [Directories.recordRegionScriptPath, "start", "monitor"];
        if (withSound) cmd.push("sound");
        startProc.command = cmd;
        startProc.running = true;
        return true;
    }

    function togglePause() {
        if (!root.recording) return;
        Quickshell.execDetached([Directories.recordRegionScriptPath, "toggle-pause"]);
        // The script flips its own state file; ask it again straight away so the
        // button's icon does not wait out the poll interval.
        root.poll();
    }

    function stop() {
        if (!root.recording) return;
        stopProc.running = true;
    }

    // SUPER+R: one key, start or stop. Silence by default (the choice made for
    // SUPER+S record mode on 2026-10-21); a caller that wants sound says so.
    function toggle() {
        if (root.recording) root.stop();
        else root.startFullscreen(false);
    }

    function poll() {
        if (stateProc.running) return;
        stateProc.running = true;
    }

    Timer {
        id: pollTimer
        interval: root.recording ? 600 : 2200
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.poll()
    }

    Process {
        id: stateProc
        command: [Directories.recordRegionScriptPath, "state"]
        stdout: StdioCollector {
            onStreamFinished: {
                const text = String(this.text ?? "").trim();
                if (!text.startsWith("recording ")) {
                    if (root._recording)
                        root._elapsed = root._elapsed; // keep the last second on screen
                    root._recording = false;
                    root._paused = false;
                    return;
                }
                const paused = /paused=(\d)/.exec(text);
                const elapsed = /elapsed=(\d+)/.exec(text);
                // `path=` runs until ` elapsed=`, and a path can contain spaces.
                const path = /path=(.*) elapsed=\d+$/.exec(text);
                // Written by the script at start; absent for a recording made
                // before this existed, in which case the frame simply stays
                // where it was and the box falls back to its old corner.
                const mode = /mode=(\w*)/.exec(text);
                const region = /region=(-?\d+),(-?\d+),(\d+),(\d+)/.exec(text);
                root._recording = true;
                root._paused = paused ? paused[1] === "1" : false;
                root._elapsed = elapsed ? Number(elapsed[1]) : 0;
                if (path) root._path = path[1];
                if (mode) root._mode = mode[1];
                if (region) {
                    root._region = {
                        x: Number(region[1]), y: Number(region[2]),
                        w: Number(region[3]), h: Number(region[4])
                    };
                }
            }
        }
    }

    Process {
        id: startProc
        stdout: StdioCollector {
            onStreamFinished: {
                const p = String(this.text ?? "").trim();
                if (p.length > 0) root._path = p;
            }
        }
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                GlobalStates.showSignalToast(Translation.tr("Recording failed"), "error", 2600);
                console.warn(`[recorder] start failed (exit ${exitCode})`);
            }
            root.poll();
        }
    }

    Process {
        id: stopProc
        command: [Directories.recordRegionScriptPath, "stop"]
        // The script answers with the path on line 1 and, when it managed to
        // put the clip on the clipboard, the word `copied` on line 2. Taking
        // the whole text as a path (what this did before) would now hand a
        // two-line string to everything downstream.
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = String(this.text ?? "").trim().split("\n").map(l => l.trim()).filter(l => l.length > 0);
                const p = lines.length > 0 ? lines[0] : "";
                if (p.length === 0) return;
                root.lastSavedPath = p;
                root.saveSeq++;
                const name = p.split("/").pop();
                // "copied" is the clip being on the clipboard for the next
                // paste -- the half of a stop a toast can actually tell you
                // about.
                const copied = lines.includes("copied");
                // "temp" is a cache-dir clip that will be pruned. It is not
                // SAVED anywhere you would go looking, so saying "Saved" (and
                // naming a file you will never open again) was a lie with a
                // timestamp on it -- the length of the take is the useful fact.
                const temp = lines.includes("temp");
                const label = temp
                    ? (copied ? Translation.tr("Copied") : Translation.tr("Recorded"))
                        + " · " + root.clock(root._elapsed)
                    : Translation.tr("Saved") + " · " + name
                        + (copied ? " · " + Translation.tr("copied") : "");
                GlobalStates.showSignalToast(label, "videocam", 2600);
            }
        }
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                GlobalStates.showSignalToast(Translation.tr("Stop failed"), "error", 2200);
            }
            root.poll();
        }
    }

    IpcHandler {
        target: "recorder"

        function toggle(): void { root.toggle() }
        function startRegion(x: string, y: string, w: string, h: string): string {
            root.startRegion(Number(x), Number(y), Number(w), Number(h), false);
            return "starting";
        }
        function pause(): void { root.togglePause() }
        function stop(): void { root.stop() }
        function state(): string {
            return root.recording
                ? (root.paused ? "paused" : "recording") + " " + root.clock(root.elapsed)
                : "idle";
        }
        function elapsed(): string { return root.clock(root.elapsed) }
        // Where the last clip went, for a script that wants to open it.
        function last(): string { return root.lastSavedPath }
        // The folder the clips live in -- the cache directory while recordings
        // are temporary, whatever `screenRecord.savePath` says when they are not.
        function clips(): string {
            const i = root.lastSavedPath.lastIndexOf("/");
            return i > 0 ? root.lastSavedPath.substring(0, i) : "";
        }
    }
}
