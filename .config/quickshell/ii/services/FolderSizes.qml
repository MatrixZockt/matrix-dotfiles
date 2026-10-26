pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import QtQuick

// How heavy a folder is, with everything inside it -- the one number in the
// file manager that costs real I/O, because it is a tree walk.
//
// That cost is why the RULES matter more than the arithmetic here. Every one of
// them exists to answer "and what if the user is in a folder with 500
// subfolders?":
//
//   * ONE PROCESS AT A TIME. A single `du` runs at any moment, whatever else
//     asks. Five hundred rows scrolling past cannot become five hundred trees
//     being walked concurrently and a disk being thrashed; they queue.
//   * ONLY WHAT IS ON SCREEN ASKS. The request is made by the DELEGATE that
//     draws the row, not by a pass over the listing, so a folder nobody
//     scrolled to is never measured at all. Delegates are created for visible
//     rows only, so the work follows the eye.
//   * THE QUEUE IS BOUNDED. A fast scroll can enqueue more than the cap; the
//     OLDEST waiting entries are dropped when it overflows, because those are
//     the rows the user has already scrolled past.
//   * ONCE PER FOLDER. Answers are cached in memory by path, keyed by the
//     directory's own mtime: the row asks again every time it is drawn, and
//     every one of those asks after the first is free. Nothing is re-measured
//     on a paint, a hover, a poll or a timer -- there is no polling here at all.
//   * BOUNDED IN TIME. Each `du` gets a hard timeout. A network mount or a
//     runaway tree costs seconds ONCE and is then remembered as unmeasurable,
//     instead of being retried forever.
//
// The unit is BYTES of apparent size -- the same "sum of the sizes shown for
// its files" that Windows Explorer puts in a folder's Size column, and so the
// same arithmetic as the file rows next to it. (The Properties dialog reports
// `du`'s default instead, which is allocated blocks: for a folder of many tiny
// files that is the larger, and truer, "space it takes" number. The two are
// deliberately allowed to differ; each cell says what it is.)
//
// A value of -1 means NOT KNOWN YET. Callers draw nothing for it rather than a
// zero -- a folder that has not been measured is not an empty folder.
Singleton {
    id: root

    // path -> { bytes, stamp, at, note }
    //   bytes  the answer, or a negative sentinel for "cannot be measured"
    //   stamp  the directory mtime the answer belongs to; a newer stamp makes
    //          the answer stale and the folder measurable again
    //   note   "ok" | "timeout" | "error", for the log and the probe
    //
    // A plain JS object, not a Map: it is only ever read back by path from the
    // same process, and the notification that makes a QML binding re-read it is
    // `revision` below (a nested write to a var property notifies nothing, so
    // the bump is the notification).
    property var cache: ({})
    // Bumped every time an answer lands. A binding that wants to follow the
    // cache must depend on THIS -- a function call on a singleton creates no
    // dependency by itself, so callers pass `FolderSizes.revision` through the
    // function that needs it. (The same trap GlobalStates' transient flags
    // document.)
    property int revision: 0

    property var queue: []          // paths waiting, oldest first
    property string active: ""      // the path being walked right now
    property string activeSince: "" // its start, for a probe that asks "stuck?"
    property int dropped: 0         // entries the cap threw away
    property int measured: 0        // answers that landed, however they went
    property int failed: 0          // ...and of those, the ones with no number
    // Asked and answered-from-cache, counted separately. Without both, "a
    // redraw costs nothing" cannot be told apart from "a redraw asks nothing"
    // -- and the second one is a broken feature wearing the first one's
    // evidence. A check therefore asserts that HITS move while ASKED and
    // MEASURED do not.
    property int asked: 0
    property int hits: 0
    // The last walk as it was run and as it answered. Kept because the one
    // failure this cannot debug from outside is a NUMBER that came out wrong:
    // a probe can then show the command and the bytes it printed instead of
    // leaving the parse to be argued about.
    property string lastCommand: ""
    property string lastOutput: ""

    // ~48 folders ahead of the eye is deeper than a visible screen by a wide
    // margin, so the cap only ever bites on a deliberate fast scroll.
    readonly property int queueCap: 48
    // A tree that cannot be walked in this long is not going to be walked by a
    // file listing's worth of patience. `timeout` kills the walk, not the app.
    readonly property int duTimeoutSec: 25

    /// The measured size of a folder in bytes, or -1 when it is not known.
    ///
    /// 0 is a real answer -- an EMPTY folder measures 0 -- and is returned as
    /// such; the formatter decides that 0 bytes is drawn as nothing, which is a
    /// question about how to show it rather than about whether we measured it.
    function bytes(path) {
        const hit = root.cache[String(path ?? "")];
        if (!hit) return -1;
        return hit.bytes >= 0 ? hit.bytes : -1;
    }

    /// Is this folder queued or being walked right now? The UI uses it to tell
    /// "coming" from "cannot be measured", which are drawn differently (empty
    /// cell vs an empty cell that is never going to fill in).
    function pending(path) {
        const p = String(path ?? "");
        return root.active === p || root.queue.indexOf(p) !== -1;
    }

    /// Why a folder has no number, when it has none.
    function note(path) {
        const hit = root.cache[String(path ?? "")];
        return hit ? String(hit.note ?? "") : "";
    }

    /// Ask for a folder's size. `stamp` is the directory's own mtime: it is
    /// what makes a cached answer expire, because adding or removing anything
    /// in the folder moves it. A stamp of 0 means the caller has none -- the
    /// answer is then kept until `clear()`, rather than being thrown away and
    /// re-measured on every redraw.
    ///
    /// Free to call from a delegate's completion handler and from every
    /// re-draw: a fresh cached answer and a queued path both return at once.
    function request(path, stamp) {
        const p = String(path ?? "");
        if (p.length === 0) return;
        const hit = root.cache[p];
        const now = Number(stamp ?? 0);
        if (hit && (hit.stamp === now || now === 0)) {          // fresh, or unstamped
            root.hits++;
            return;
        }
        if (root.pending(p)) return;                            // already coming
        root.asked++;
        if (root.queue.length >= root.queueCap) {
            // Oldest first: the cap is reached by scrolling away from rows.
            root.queue = root.queue.slice(root.queue.length - root.queueCap + 1);
            root.dropped++;
        }
        // The stamp travels beside the queue: `du` needs the path, and the
        // freshness of the answer is a question about the caller's stamp, so
        // the two are kept in step and meet again when the answer lands.
        const stamps = {};
        for (const key in root.stamps) stamps[key] = root.stamps[key];
        stamps[p] = now;
        root.stamps = stamps;
        root.queue = root.queue.concat([p]);
        root.pump();
    }

    /// Forget one folder, or everything (a manual Refresh, or a probe).
    function forget(path) {
        const p = String(path ?? "");
        const next = {};
        for (const key in root.cache)
            if (key !== p) next[key] = root.cache[key];
        root.cache = next;
        root.queue = root.queue.filter(q => q !== p);
        root.revision++;
    }
    function clear() {
        root.cache = ({});
        root.queue = [];
        root.dropped = 0;
        root.revision++;
    }

    // The walk. One process, started only when there is something to do and
    // nothing running, and it takes the next path off the queue itself -- so
    // "one at a time" is structural rather than something callers must respect.
    //
    // `--apparent-size -B1`: bytes, summed as the file sizes are reported
    // rather than as blocks allocated (see the note at the top).
    // `-x`: stay on one filesystem, so a mounted drive inside the folder is
    // reported as the mount it is rather than being walked into as weight.
    // `timeout`: the one thing standing between a slow network mount and a
    // process that never ends.
    Process {
        id: duProc
        command: []
        property string output: ""
        property int exitCode: -1
        // The two halves of "the walk is over" arrive on their own schedule:
        // the exit status when the process ends, and the text when its stdout
        // stream has been drained. Acting on the EXIT alone was measured doing
        // the wrong thing here -- the collector had not spoken yet, the answer
        // read as an empty string, and an empty string parses as 0 bytes, which
        // is a wrong number rather than a missing one. So the answer is only
        // taken once BOTH have arrived, in whichever order that happens.
        property bool sawOutput: false
        property bool sawExit: false
        stdout: StdioCollector {
            onStreamFinished: {
                duProc.output = String(this.text ?? "");
                duProc.sawOutput = true;
                root.landed();
            }
        }
        onExited: (code, status) => {
            duProc.exitCode = Number(code ?? -1);
            duProc.sawExit = true;
            root.landed();
        }
    }

    function landed() {
        if (!duProc.sawOutput || !duProc.sawExit) return;
        duProc.sawOutput = false;
        duProc.sawExit = false;
        root.finish(duProc.exitCode);
    }

    function pump() {
        if (duProc.running) return;
        if (root.queue.length === 0) return;
        const next = root.queue[0];
        root.queue = root.queue.slice(1);
        root.active = next;
        root.activeSince = new Date().toISOString();
        duProc.output = "";
        duProc.exitCode = -1;
        duProc.sawOutput = false;
        duProc.sawExit = false;
        duProc.command = ["bash", "-c",
            `timeout ${root.duTimeoutSec} du -s -x --apparent-size -B1 -- ${root.shq(next)} 2>/dev/null`];
        root.lastCommand = String(duProc.command[duProc.command.length - 1]);
        duProc.running = true;
    }

    function finish(code) {
        const path = root.active;
        root.active = "";
        if (path.length === 0) return;
        const text = String(duProc.output ?? "");
        root.lastOutput = text;
        // An EMPTY answer is a missing number, not a zero: `du` prints one
        // number and a path, so a blank first field means nothing came back --
        // a killed walk, a missing tool, a folder that vanished mid-walk. It
        // must not be read as "this folder is empty".
        const field = text.trim().split(/[ \t]/)[0];
        const value = field === undefined || field === "" ? NaN : Number(field);
        // Why a folder has no number, named rather than collapsed into "no
        // size": a walk that was killed (124, the timeout), one that failed
        // (an unreadable tree, a missing tool) and one that answered with
        // nothing at all are three different things to a reader of the log.
        let note = "ok";
        if (code === 124) note = "timeout";
        else if (code !== 0) note = "error";
        else if (!(isFinite(value) && value >= 0)) note = "no-answer";
        const entry = {
            bytes: (note === "ok") ? value : -1,
            // The stamp is carried by the CALLER, so it is recovered from the
            // request: the queue holds paths only, and a stale answer is caught
            // on the next request anyway (the row hands its current mtime in).
            stamp: Number(root.stamps[path] ?? 0),
            at: new Date().toISOString(),
            note: note
        };
        const next = {};
        for (const key in root.cache) next[key] = root.cache[key];
        next[path] = entry;
        root.cache = next;
        const stamps = {};
        for (const key in root.stamps) if (key !== path) stamps[key] = root.stamps[key];
        root.stamps = stamps;
        if (note !== "ok") root.failed++;
        root.measured++;
        root.revision++;
        root.pump();
    }

    // The stamp each queued path was asked with. Kept beside the queue, because
    // the queue is paths (they are what `du` needs) while freshness is the
    // caller's stamp, and the two only meet again when the answer lands.
    property var stamps: ({})

    function shq(s) {
        return "'" + String(s ?? "").replace(/'/g, "'\\''") + "'";
    }

    // What a check can read from outside: the queue's depth, the one path being
    // walked, how many answers have landed, and the numbers themselves for the
    // rows on screen. `pending` is the honest measure of "is this feature
    // costing the disk anything right now" -- it must fall to 0 and stay there
    // once the visible rows are done.
    function probe() {
        const sample = [];
        for (const key in root.cache) {
            const entry = root.cache[key];
            sample.push({ path: key, bytes: entry.bytes, note: entry.note, at: entry.at });
        }
        return JSON.stringify({
            queued: root.queue.length,
            active: root.active,
            activeSince: root.activeSince,
            measured: root.measured,
            failed: root.failed,
            asked: root.asked,
            hits: root.hits,
            dropped: root.dropped,
            cached: sample.length,
            revision: root.revision,
            lastCommand: root.lastCommand,
            lastOutput: root.lastOutput,
            sample: sample.slice(-12)
        });
    }

    IpcHandler {
        target: "folderSizes"
        function state(): string { return root.probe(); }
        function clear(): void { root.clear(); }
        function forget(path: string): void { root.forget(path); }
    }
}
