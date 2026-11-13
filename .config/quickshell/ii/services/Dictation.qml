pragma Singleton

import Quickshell
import Quickshell.Io
import QtQuick

// What the dictation daemon is doing right now.
//
// dictate-daemon.py writes a 60-byte JSON file (state + live microphone level)
// roughly 20 times a second while SUPER is held; this is the one place that
// reads it, so the island's pill and anything else that wants to know the
// recorder is live ask the same question.
//
// POLLED, not inotify. The daemon writes the file atomically (write a temp file,
// rename over the target), which is the only way to avoid a half-written
// document, and a rename gives the watched path a NEW inode -- an inotify watch
// on the old one never fires again, so `watchChanges` would show the first
// state and then sit there lying. Re-reading every 50ms costs one stat and one
// short read, and cannot go stale.
Singleton {
    id: root

    readonly property string statusPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/ii-dictate/status.json"

    /// "idle" | "recording" | "transcribing"
    property string state: "idle"
    /// "Transcribing", held for at least `minBusyMs` (see applyState).
    property bool busy: false
    property real busyStartedAt: 0
    /// Smoothed microphone level, 0..1, for the meter.
    property real level: 0

    /// Two-letter tag of the language the audio was recognised in ("de", "en"),
    /// empty until the first words come back -- whisper can only say once it
    /// has heard something. Sticky through the end of a dictation and cleared
    /// the moment the next hold begins (the daemon deletes its file then), so a
    /// tag never describes the wrong dictation.
    property string language: ""
    readonly property string languageLabel: language.length === 2
        ? language.toUpperCase()
        : language

    readonly property bool listening: state === "recording"
    /// Anything worth showing in the bar.
    readonly property bool showing: listening || busy

    // A warm whisper answers a short dictation in a few hundred milliseconds,
    // so the working tell can arrive and leave inside a single blink -- which
    // reads as a glitch instead of as "it is working". Once it has been up it
    // stays for at least this long. It only ever EXTENDS a state the daemon
    // really reported: the daemon ending the dictation still ends it, a beat
    // later, and the timer is cancelled the moment anything else happens.
    readonly property int minBusyMs: 900

    FileView {
        id: statusFile
        path: root.statusPath
        watchChanges: false
        printErrors: false

        onLoaded: root.ingest(text())
        onTextChanged: root.ingest(text())
    }

    // Fast while something is happening, slow the rest of the time: 20 reads a
    // second forever would be a small cost that never stops, and there is
    // nothing to see when the state is idle anyway. 250ms is still fast enough
    // that the pill is on screen a quarter of a second after SUPER arms.
    Timer {
        id: poll
        interval: root.showing ? 50 : 150
        repeat: true
        running: true
        onTriggered: statusFile.reload()
    }

    function ingest(raw) {
        if (!raw)
            return;
        try {
            const data = JSON.parse(raw);
            // A file left behind by a daemon that has since died would keep the
            // pill on screen forever, so an old timestamp counts as idle.
            //
            // Transcribing gets a longer lease than recording. Whisper is the
            // one step that can stall (a model loading, a long clip), and the
            // daemon refreshes the stamp every 250ms for as long as either is
            // really running -- so a stamp this old is over, or the daemon is
            // gone and the pill should clear itself instead of hanging on.
            const lease = data.state === "transcribing" ? 6.0 : 2.0;
            const next = Math.abs(Date.now() / 1000 - (data.ts ?? 0)) < lease
                ? (data.state ?? "idle")
                : "idle";
            applyState(next);
            level = next === "recording"
                ? Math.max(0, Math.min(1, data.level ?? 0))
                : 0;
            // Held rather than assigned: the daemon stops naming a language
            // the moment the dictation ends, and the tag should not blink out
            // while the island still says "Transcribing…". A new hold is the
            // one thing that makes it stale.
            const lang = String(data.lang ?? "");
            if (lang)
                language = lang;
            else if (next === "recording")
                language = "";
        } catch (e) {
            // Mid-rename or partially written: ignore this sample, the next one
            // 50ms later is whole.
        }
    }

    // The raw state plus the one rule that cannot live in the file: transcribing
    // is shown long enough to be read. Recording always wins, because the meter
    // is live and it is the half of a dictation with something to watch.
    function applyState(next) {
        // `busy` goes UP BEFORE `state` moves: they are two properties and
        // `showing` is derived from both, so writing `state` first dropped
        // `showing` for one property notification at every handover from
        // recording to transcribing. Everything watching `showing` saw a
        // dictation that had ended: the drop-down tell ran its lift animation,
        // and the immediate re-show raced it -- measured, the pill stayed
        // mapped at y 0 with opacity 0.00 for the whole transcribing half, so
        // the one tell that says "it is working" was invisible.
        if (next === "transcribing" && !busy) {
            busy = true;
            busyStartedAt = Date.now();
        }
        state = next;
        if (next === "transcribing") {
            busyHold.stop();
        } else if (busy) {
            const left = root.minBusyMs - (Date.now() - root.busyStartedAt);
            if (next === "recording" || left <= 0) {
                busy = false;
                busyHold.stop();
            } else {
                busyHold.holdMs = left;
                busyHold.restart();
            }
        }
    }

    // Counts the rest of the minimum, from whenever transcribing started. Its
    // own `holdMs` rather than `interval: root.minBusyMs`: a binding assigned
    // over at runtime is silently destroyed, so the one place that changes the
    // wait keeps a property of its own instead of quietly unhooking the rule.
    Timer {
        id: busyHold
        property int holdMs: root.minBusyMs
        interval: holdMs
        repeat: false
        onTriggered: if (root.state !== "transcribing") root.busy = false
    }
}
