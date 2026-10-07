pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
// For `Timer` (the pre-warm window). A service singleton that only ever held a
// Process did not need QtQuick at all; adding the warm timer without this
// import is a hard "Timer is not a type" at load.
import QtQuick
import qs.modules.common
import qs.services

/**
 * The shell's ONE waveform source.
 *
 * Before this, every surface that wanted a meter ran its own `cava`: the bar
 * island had one, the media window had another, and the now-bar panel had
 * none at all -- which is why the panel's equaliser was three rectangles with
 * hard-coded heights that flipped once on play/pause. It looked like it was
 * listening and it was not; it was reading a boolean.
 *
 * One pipeline, two doors. A surface sets the flag for the surface it is on
 * (`wantIsland` / `wantPanel`) rather than owning a process, so opening the
 * panel and the island at the same time costs exactly one `cava` instead of
 * two, and neither can end up showing a frozen copy of a stream it killed.
 *
 * `points` is the raw band list (cava's ";"-separated output) in the same
 * 0..maxVisualizerValue range `WaveVisualizer` already expects, so every
 * existing consumer keeps working unchanged.
 */
Singleton {
    id: root

    /** The live band values, or an empty list when nothing is running. */
    property list<real> points: []

    /** The bar island wants a meter (its media view is on screen). */
    property bool wantIsland: false
    /** The now-bar panel wants a meter (it is open, on the media tab). */
    property bool wantPanel: false

    // Who currently holds each door.
    //
    // A surface used to clear its flag in `Component.onDestruction`, and that
    // is wrong: the bar can rebuild its island (a config reload, a panel
    // family swap) and the OLD instance's destructor then runs AFTER the new
    // one has already claimed the door. The survivor is left believing nobody
    // wants a meter, so the sound bar goes dead while the music plays -- with
    // nothing in the log to explain it. This was observed happening.
    //
    // A release is therefore only honoured if it comes from the instance that
    // still holds the claim. Anything else is a stale voice talking over the
    // live one.
    property var islandHolder: null
    property var panelHolder: null

    function claimIsland(holder) {
        root.islandHolder = holder;
        root.wantIsland = true;
        // Opening a surface IS the warm-up moment. The meter is on screen from
        // this frame, so the process is already justified, and the 500ms of
        // cava startup is spent while the panel is still animating in rather
        // than while the user is watching a dead bar.
        root.warm();
    }
    function releaseIsland(holder) {
        if (root.islandHolder !== holder) return;  // a newer island owns it now
        root.islandHolder = null;
        root.wantIsland = false;
    }
    function claimPanel(holder) {
        root.panelHolder = holder;
        root.wantPanel = true;
        root.warm();      // same reasoning as `claimIsland`
    }
    function releasePanel(holder) {
        if (root.panelHolder !== holder) return;
        root.panelHolder = null;
        root.wantPanel = false;
    }

    readonly property bool wanted: root.wantIsland || root.wantPanel

    /**
     * Audio actually running. The process is stopped outright otherwise: a
     * `cava` sitting idle on a stopped sink still costs a wakeup per frame,
     * and on a laptop that is the difference between a shell you can battery
     * on and one you cannot.
     *
     * `warming` deliberately bypasses the `isPlaying` test. The pre-warm's
     * whole purpose is to have the pipeline up BEFORE the press, so requiring
     * audio to already be running would mean it never starts early enough to
     * be early. A warming pipe on a silent sink just reads as silence, which
     * is exactly what the meter should show at that moment anyway.
     */
    readonly property bool live: root.warming
        || ((MprisController.isPlaying ?? false) && root.wanted)

    // A `cava` that dies on its own has to be brought back, and it cannot be
    // done by assigning `proc.running`: that is a BINDING on `live`, so the
    // binding survives the process exiting, `running` stays true, and nothing
    // restarts it. The visualiser is then dead until something unrelated
    // happens to flip `live` -- which is why a killed or crashed `cava` used
    // to leave the bars frozen with nothing in the log to say so.
    //
    // Dropping this gate for one tick and putting it back makes the binding
    // re-evaluate, which respawns. Bounded, because a `cava` that cannot start
    // at all (no sink, no permission) must not become a fork bomb.
    property bool spawnGate: true
    property int restarts: 0
    property real lastRestartAt: 0
    readonly property int restartBurst: 3
    readonly property int restartWindowMs: 10000

    // ── Pre-warm ────────────────────────────────────────────────────────
    // MEASURED on this machine, spawn -> first non-zero band data:
    //
    //   D-Bus PlaybackStatus after pressing play ....   2 ms
    //   `cava` process present (pgrep) ...............  49 ms
    //   `cava` first line on stdout .................. 448 ms
    //   first line with any signal in it ............. 480 ms
    //   steady, full-height spectrum ................. 600 ms
    //
    // So the bridge and the QML side are instant and the whole perceived lag
    // is cava's own start. (`autosens` was suspected and ruled out by
    // measurement: at autosens=0 the first line still lands at 455ms. It is
    // process start plus the FFT fill, not sensitivity calibration.)
    //
    // Warming on `isPlayingChanged` therefore bought almost nothing: the warm
    // began at +2ms and the data still arrived at +480ms, i.e. inside the very
    // moment the user was watching the bar. The pipe has to be hot BEFORE the
    // press. Three things do that:
    //
    //   1. `warm()` on hover of every play control, which is ~450ms of warning.
    //   2. A warm window on the PAUSE edge too, not just the play edge. A
    //      pause is as strong a promise of a resume as a play is of a start,
    //      and it is the common case: stop, think, press play again. Without
    //      this the resume pays the full 500ms every time.
    //   3. `warm()` when a surface that shows a meter claims it (above), and
    //      when a track is loaded while stopped (below).
    //
    // MEASURED again, cold against warm, same machine, mid-track resume:
    //
    //   cold  (cava spawned by the press) ... first signal 516ms, moving 550ms
    //   warm  (cava already streaming) .... first signal  13ms, moving  46ms
    //
    // mpv's own contribution is the 13ms, so essentially the whole felt delay
    // is whether the pipeline exists when the press happens. That is the whole
    // design: there is no faster cava, only a cava that was already there.
    //
    // A config knob was tried and REFUTED, recorded so nobody tries it again:
    // `smooth_window` (the FFT window size, which looks exactly like the kind
    // of thing that would set the latency) does not move it. Measured cold
    // start at 500 / 200 / 100ms windows: 513ms / 527ms / 520ms to first
    // signal. The ~500ms is `cava`'s process start plus its pipewire stream
    // setup -- inside the program, not in its settings.
    property bool warming: false
    readonly property int warmMsDefault: 10000
    // A meter on screen makes every millisecond of that startup VISIBLE, so
    // when someone is looking the window is much longer than when nobody is.
    // The trade is one idle process: a `cava` on a stopped sink costs a
    // wakeup per frame, and this is the only place that trade is made.
    readonly property int warmMsWatched: 45000
    Timer {
        id: warmTimer
        interval: root.warmMsDefault
        onTriggered: root.warming = false
    }

    /**
     * Ask for the pipeline now, and keep it for a while.
     * Safe to call repeatedly and from anywhere: if a meter is already on
     * screen the flag it set is what keeps `cava` alive, and this is a no-op.
     */
    function warm(ms) {
        root.warming = true;
        // No explicit window means "the usual one for this situation": long
        // while a meter is on screen, short when it is not.
        warmTimer.interval = ms ?? (root.wanted ? root.warmMsWatched : root.warmMsDefault);
        warmTimer.restart();
    }

    Connections {
        target: MprisController
        // BOTH edges, deliberately -- see the note above.
        function onIsPlayingChanged() {
            if (root.wanted) return;   // somebody is already listening
            root.warm();
        }
    }

    // A track arriving while nothing is playing.
    //
    // This is the strongest signal available that a press is coming, and it is
    // free: the app has already decided what it is about to play, and it is
    // going to take some milliseconds yet to hand the first samples to
    // pipewire. `cava` needs 500ms of its own; between the two there is now
    // usually enough runway for the pipeline to be hot before the sound
    // starts, which is the only way the bars move on the first frame.
    //
    // Target is the PLAYER, not the controller: `MprisController` only changes
    // `shownPlayer` when the active player changes, so its own signals never
    // fire for a track swap inside the app that is already on top.
    Connections {
        target: MprisController.shownPlayer
        // `trackChanged`, not `metadataChanged`. Both exist, but the first is
        // Quickshell's "this is a different song now" signal; the second fires
        // on any metadata edit, including the ones a player makes to itself
        // while settling (position, art, playback state), which would warm the
        // pipeline for reasons that have nothing to do with a new song.
        function onTrackChanged() {
            // Nothing to warm for if there is no meter to feed, and nothing to
            // gain if it is already playing -- `live` covers that case.
            if (MprisController.isPlaying ?? false) return;
            root.warm(60000);
        }
    }

    Process {
        id: proc
        running: root.live && root.spawnGate
        onRunningChanged: {
            // A stopped pipeline must not leave the last frame on screen: every
            // meter in the shell would keep showing a frozen waveform, which
            // reads as "still playing" long after the music stopped.
            if (!proc.running)
                root.points = [];
        }
        // Restarting after an exit. See `spawnGate` for why the gate exists.
        onExited: (exitCode, exitStatus) => {
            const now = Date.now();
            root.restarts = (now - root.lastRestartAt < root.restartWindowMs)
                ? root.restarts + 1 : 1;
            root.lastRestartAt = now;
            if (root.restarts > root.restartBurst) {
                console.warn(`[AudioVisualizer] cava exited (code ${exitCode}) `
                    + `${root.restarts} times in ${root.restartWindowMs}ms -- giving up. `
                    + `The meter will stay flat until the next track or panel open.`);
                return;
            }
            root.spawnGate = false;
            Qt.callLater(() => { root.spawnGate = true; });
        }
        // `cava`'s complaints used to go to /dev/null. A visualiser that is
        // flat with a warm flag set is indistinguishable from a silent sink
        // unless something says why, and this is the only place it can.
        stderr: StdioCollector {
            onStreamFinished: console.warn(`[AudioVisualizer] cava: ${this.text.trim()}`)
        }
        // `Directories.scriptPath` is a file:// URL and cava wants a real
        // path. The strip is done inline rather than through the shell's
        // FileUtils helper: that helper is not visible from a service
        // singleton's imports, and a ReferenceError here is silent-but-fatal
        // for the whole pipeline (the process never starts, and nothing says
        // why).
        onStarted: console.log("[AudioVisualizer] cava started pid=" + proc.processId)
        command: ["cava", "-p", `${String(Directories.scriptPath).replace("file://", "")}/cava/raw_output_config.txt`]
        stdout: SplitParser {
            onRead: data => {
                root.points = data.split(";")
                    .map(p => parseFloat(p.trim()))
                    .filter(p => !isNaN(p));
            }
        }
    }
}
