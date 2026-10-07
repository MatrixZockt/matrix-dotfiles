pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Quick screen recording state -- the SUPER+R pipeline.
 *
 * The recorder is the shell's own wf-recorder wrapper (scripts/videos/
 * record.sh), which toggles by pid: running it starts a capture, running it
 * again stops the live one. This singleton answers the only question the
 * floating pill cares about -- *is wf-recorder alive right now* -- by asking
 * the process table directly.
 *
 * It polls rather than trusting its own bookkeeping, for one important
 * reason: recordings can start from paths this service never sees (the snip
 * flow's Record action, or the script run from a terminal). The pill is
 * therefore correct for every recording, not just the SUPER+R one.
 *
 * Poll cadence is 1.2s: fast enough that the pill appears while the recorder
 * is still spinning up, cheap enough to leave running forever (one pgrep).
 */
Singleton {
    id: root

    readonly property bool recording: root._alive
    property bool _alive: false

    // Elapsed seconds, counted from the moment the recorder was first seen.
    property int elapsed: 0
    property int sinceEpoch: 0

    function toggle() {
        // The script is its own toggle; the poll picks the result up within a
        // beat. Starting or stopping, the call is the same.
        Quickshell.execDetached([Directories.recordScriptPath, "--fullscreen"]);
        // Nudge the poll so the pill reacts immediately instead of waiting out
        // the interval.
        pollTimer.restart();
    }

    function stop() {
        if (!root._alive) return;
        Quickshell.execDetached([Directories.recordScriptPath]);
        pollTimer.restart();
    }

    Timer {
        id: pollTimer
        interval: 1200
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: {
            if (!checkProc.running)
                checkProc.running = true;
        }
    }

    Process {
        id: checkProc
        command: ["pgrep", "-x", "wf-recorder"]
        stdout: StdioCollector {
            onStreamFinished: {
                const alive = this.text.trim().length > 0;
                if (alive && !root._alive) {
                    root.sinceEpoch = Math.floor(Date.now() / 1000);
                    root.elapsed = 0;
                }
                if (!alive && root._alive) {
                    root.sinceEpoch = 0;
                    root.elapsed = 0;
                }
                root._alive = alive;
            }
        }
    }

    Timer {
        interval: 1000
        repeat: true
        running: root.recording
        onTriggered: {
            if (root.sinceEpoch > 0)
                root.elapsed = Math.max(0, Math.floor(Date.now() / 1000) - root.sinceEpoch);
        }
    }

    function clock(sec) {
        const s = Math.max(0, sec | 0);
        return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
    }

    IpcHandler {
        target: "recorder"

        function toggle(): void { root.toggle() }
        function stop(): void { root.stop() }
        function state(): string { return root._alive ? "recording" : "idle"; }
        function elapsed(): string { return root.clock(root.elapsed); }
    }
}
