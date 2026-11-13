pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import qs.services
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * The bar's indication line, as a general channel.
 *
 * The loading line under the top bar used to be the app-launch wait's private
 * property. It is now the desktop's one place for brief, glanceable status
 * signals -- anything that deserves a moment of attention but not a card, a
 * notification or an OSD. One line, whole bar width, hairline thin; anything
 * that wants to be SEEN for a beat fires a pulse here and the line answers.
 *
 * A pulse carries:
 *   kind    "charge"  -- the launch wait: line grows from left, then fades
 *           "blink"   -- one soft full-width blink in `color`, then fades
 *                       (charger plugged, screenshot taken, ...) -- used both
 *                       as the under-bar line AND as the fullscreen tell
 *   text    optional; future consumers may read it, nothing draws it today
 *
 * The corner card still owns everything that must be READ ("Couldn't open X",
 * "already open"); this line owns everything that is only glanced at.
 *
 * One-shot semantics on purpose: the line never queues. A second signal
 * replaces the first -- a status channel that stacks six events while you
 * were looking away is a notification list, and that already exists.
 */
Singleton {
    id: root

    // ── The launch wait (the original face of the line) ───────────────
    // GlobalStates owns the launch lifecycle; the bar reads the line's two
    // faces through this service so all consumers have one place to ask.
    readonly property bool loadingLine: GlobalStates.loadingLine
    readonly property bool loadingFailFlash: GlobalStates.loadingFailFlash

    // ── The failure face: a BLINK, not a hold ───────────────────────────
    //
    // This was one flat red bar held for 1.4s, which says "something is wrong"
    // to someone already looking at the bar and says nothing at all to
    // someone who glanced away -- and the failure it reports is exactly the
    // case where the user has walked off to do something else while an app sat
    // there not opening. So it blinks, the same two-blink shape the low
    // battery alert already uses, and the clock lives here beside that one
    // rather than in the bar: the bar only draws.
    //
    // On/off are deliberately unequal (450/350). A square wave at one rate
    // reads as a flicker; a shorter off beat reads as two distinct flashes,
    // which is what "blink twice" has to mean to be legible at a glance.
    readonly property int loadingFailBlinks: GlobalStates.loadingFailBlinks
    property bool loadingFailOn: false
    Timer {
        id: failBlinkTimer
        interval: 400   // (450 + 350) / 2
        repeat: true
        running: root.loadingFailFlash
        onTriggered: root.loadingFailOn = !root.loadingFailOn
    }
    onLoadingFailFlashChanged: if (root.loadingFailFlash) root.loadingFailOn = true

    // ── Pulses: { kind, color, text, id } ────────────────────────────────
    property var pulse: null
    property int pulseId: 0
    readonly property bool hasPulse: pulse !== null

    // When the current pulse was fired, for the expiry below.
    property real pulseAt: 0

    function blink(color, text) {
        pulseId += 1;
        root.pulseAt = Date.now();
        pulse = { kind: "blink", color: color ?? Appearance.colors.colPrimary, text: text ?? "", id: pulseId };
    }

    function clearPulse() {
        pulse = null;
    }

    // The blink's own clock, here in the service rather than in whatever
    // draws it. A blink is a one-shot: it paints the whole line for three
    // quarters of a second and then it is over. When the expiry lived in the
    // bar, anything that kept that bar's timer from firing left the pulse
    // set, and a set pulse paints a SOLID full-width line AND outranks the
    // meter -- so volume and brightness stopped responding too, which is
    // exactly the "stuck on green no matter what I do" report.
    //
    // It polls the pulse's AGE rather than being armed by a change handler:
    // a handler only runs if a notification arrives, and the whole failure
    // being fixed here is a pulse that outlived every notification it had.
    // `running` is bound to the pulse itself, so the clock starts whenever a
    // pulse exists and stops when it is gone -- nothing to arm, nothing to
    // strand.
    Timer {
        interval: 250
        repeat: true
        running: root.hasPulse
        onTriggered: {
            if (Date.now() - root.pulseAt >= 750)
                root.clearPulse();
        }
    }

    // ── The battery-alert face (low / critical) ─────────────────────────
    // A blink with a LABEL: the line flashes the error colour `blinks`
    // times, and the extended island shows the sentence ("Low battery") for
    // as long as the alert is live. Replaces the corner notification for
    // low battery -- same information, no history entry, same sound.
    property var batteryAlert: null   // { text, blinks, id } or null
    property int batteryAlertId: 0
    readonly property bool hasBatteryAlert: batteryAlert !== null

    function fireBatteryAlert(text, blinks) {
        batteryAlertId += 1;
        batteryAlert = { text: text ?? "", blinks: blinks ?? 2, id: batteryAlertId };
    }

    function clearBatteryAlert() {
        batteryAlert = null;
    }

    Timer {
        id: batteryAlertTimer
        // Total live time = blinks × (on + off). Two blinks at 700/450ms is
        // ~2.3s of label + line -- enough to read twice.
        interval: 700
        repeat: true
        running: false
        property int left: 0
        onTriggered: {
            left -= 1;
            if (left <= 0) {
                running = false;
                root.clearBatteryAlert();
            }
        }
    }

    Connections {
        target: root
        function onBatteryAlertChanged() {
            if (root.hasBatteryAlert) {
                batteryAlertTimer.left = root.batteryAlert.blinks * 2 + 1;
                batteryAlertTimer.restart();
            } else
                batteryAlertTimer.stop();
        }
    }

    // The blink clock: half-period on, half-period off, for `blinks` cycles.
    property bool batteryAlertOn: false
    Timer {
        id: batteryBlinkTimer
        interval: 575   // (700 + 450) / 2
        repeat: true
        running: root.hasBatteryAlert
        onTriggered: root.batteryAlertOn = !root.batteryAlertOn
    }
    onHasBatteryAlertChanged: if (root.hasBatteryAlert) root.batteryAlertOn = true

    // ── The meter face (brightness / volume) ─────────────────────────────
    // The fourth face of the line: while it is live the line shows a VALUE
    // rather than a one-shot -- the bar fills to the brightness or volume the
    // screen is actually at, edge to edge, and a small label beside the middle
    // island names which of the two it is. Every change re-arms the clock, so
    // a continuous gesture keeps the line up for the whole swipe and it drops
    // a beat after the last change -- the same rhythm the floating OSD had,
    // minus the popup.
    property bool meterLive: false
    property string meterKind: ""   // "brightness" | "volume"
    property real meterValue: 0     // 0..1
    property int meterId: 0
    // Kill switch for the meter face, for diagnosis only. Every volume or
    // brightness change lands here (see OnScreenDisplay's Connections), so it
    // is the one thing a two-finger swipe touches that is NOT part of the
    // gesture itself -- which makes it the first thing to take out of a
    // measurement. Flipped by `qs -c ii ipc call status meter on|off`.
    property bool meterEnabled: true
    // The value waiting for its next slot, and when the face last moved.
    // See `meter()`: the face is throttled to ~30Hz, and the final value of a
    // burst always lands when the throttle timer fires after it.
    property real meterPending: 0
    property real meterAppliedAt: 0

    // ── Per-job timing, for the stall attribution ─────────────────────────
    // The bar's diagnostics can tell THAT the event loop stalled (`swipeDiag`,
    // the `[stall]` log line) but not WHO stalled it: the work happens after a
    // timer callback returns, in bindings and layout, so the callback itself is
    // the only handle QML has on it. The periodic jobs therefore report their
    // own wall time here, and one IPC call reads the whole table:
    //
    //   qs -c ii ipc call status perf
    //   qs -c ii ipc call status perfReset
    property var perfJobs: ({})
    function perfMark(name, ms) {
        const j = root.perfJobs[name] ?? { n: 0, sum: 0, max: 0 };
        j.n += 1;
        j.sum += ms;
        if (ms > j.max) j.max = ms;
        root.perfJobs[name] = j;
    }
    function perfState(): string {
        const out = [];
        for (const k of Object.keys(root.perfJobs)) {
            const j = root.perfJobs[k];
            out.push(`${k} n=${j.n} avg=${(j.sum / Math.max(1, j.n)).toFixed(1)}ms max=${j.max}ms`);
        }
        // The event loop's own lateness, kept HERE rather than only in the bar
        // so it keeps measuring when the bar window is torn down (closed,
        // reloading) -- the stalls are a shell-wide symptom and must not
        // disappear from the instrument exactly when the bar is out of the way.
        out.push(`tick max=${root.tickMax}ms late>50ms=${root.tickLate}`
            + ` (n=${root.tickN})`);
        return out.length > 0 ? out.join(" | ") : "no jobs yet";
    }

    // ── The event loop's heartbeat ───────────────────────────────────────
    // A 25ms timer whose own lateness IS the measurement: anything that keeps
    // the UI thread away longer than a frame shows up here as a late tick.
    property real tickMax: 0
    property real tickPrev: 0
    property int tickLate: 0
    property int tickN: 0
    Timer {
        interval: 25
        repeat: true
        running: true
        onTriggered: {
            const now = Date.now();
            root.tickN += 1;
            if (root.tickPrev > 0) {
                const late = now - root.tickPrev - 25;
                if (late > root.tickMax)
                    root.tickMax = late;
                if (late > 50)
                    root.tickLate += 1;
            }
            root.tickPrev = now;
        }
    }

    Timer {
        id: meterTimeout
        interval: 1100
        onTriggered: root.meterLive = false
    }
    Timer {
        id: meterThrottle
        interval: 33
        repeat: false
        onTriggered: root.applyMeter()
    }

    function applyMeter() {
        root.meterId += 1;
        root.meterValue = root.meterPending;
        root.meterAppliedAt = Date.now();
    }

    function meter(kind, value) {
        if (!root.meterEnabled)
            return;
        // A value being SET is the user's own hand on the bar, and it
        // outranks a status blink: the blink already had its beat, and while
        // one is up the meter face is suppressed -- so a blink that somehow
        // outlived its clock made volume and brightness look broken. Clearing
        // it here is the reset, from the user's own action.
        if (root.hasPulse)
            root.clearPulse();
        root.meterKind = kind;
        root.meterPending = Math.max(0, Math.min(1, value ?? 0));
        root.meterLive = true;
        meterTimeout.restart();
        // ── ~30Hz, not the tracker's rate ───────────────────────────────────
        // A two-finger swipe changes brightness/volume on EVERY tracker frame
        // (100-500Hz on this pad), and every one of those used to re-assign
        // `meterValue` -- which moves an edge-to-edge fill across the bar and
        // repaints the strip as fast as the fingers can move. Measured with
        // the bar's own harness (`qs -c ii ipc call bar swipeBench volume 300`):
        // that face alone was ~36% of the gesture's frame time -- 18.1ms average
        // frame interval with it, 11.6ms with it switched off.
        //
        // 33ms is the throttle: the eye cannot tell 30Hz from 500Hz on a moving
        // fill, and the smoothness of the gesture comes from the control itself
        // (the mirror and the device), not from the meter redrawn beside it.
        if (Date.now() - root.meterAppliedAt >= 33)
            root.applyMeter();
        else
            meterThrottle.restart();
    }

    // IPC: one place for scripts to fire a status blink.
    //   qs -c ii ipc call status blink "#2BD86B" "Charger connected"
    IpcHandler {
        target: "status"
        function blink(color: string, text: string): void {
            root.blink(color, text);
        }
        function meter(kind: string, value: real): void {
            root.meter(kind, value);
        }
        // The diagnostic kill switch for the meter face (see `meterEnabled`).
        function meterFace(on: string): void {
            root.meterEnabled = on === "on" || on === "true" || on === "1";
        }
        // The per-job timing table (see `perfMark`), and its reset.
        function perf(): string {
            return root.perfState();
        }
        function perfReset(): void {
            root.perfJobs = ({});
            root.tickMax = 0;
            root.tickLate = 0;
            root.tickN = 0;
            root.tickPrev = Date.now();
        }
        function batteryAlert(text: string, blinks: int): void {
            root.fireBatteryAlert(text, blinks);
        }
        function state(): string {
            return `pulse=${root.pulse?.kind ?? "none"} color=${root.pulse?.color ?? "-"} loadingLine=${root.loadingLine} failFlash=${root.loadingFailFlash} meter=${root.meterLive ? root.meterKind : "none"}@${Math.round(root.meterValue * 100)}% alert=${root.hasBatteryAlert ? root.batteryAlert.text + " blink=" + root.batteryAlertOn : "none"}`;
        }
    }

    // ── Charging plugged/unplugged ──────────────────────────────────────
    // Green blink when the charger connects, neutral blink when it leaves.
    // Deliberately quiet about charging STATE changes -- the tray icon and
    // the battery panel already carry that; this answers only the question
    // "did the plug just go in / come out".
    property bool wasPluggedIn: false
    property bool plugWatchPrimed: false
    Connections {
        target: Battery
        function onIsPluggedInChanged() {
            const now = Battery.isPluggedIn;
            if (!root.plugWatchPrimed) {
                root.wasPluggedIn = now; // no blink for the state at boot
                root.plugWatchPrimed = true;
                return;
            }
            if (now !== root.wasPluggedIn) {
                root.wasPluggedIn = now;
                // Battery green, matched to the level bar's charging colour;
                // the neutral blink uses the plain foreground tone so it
                // reads as "noted", not "celebrated".
                // The text is drawn now -- the extended island shows it while
                // the blink plays (see BarContent's status pocket). "Battery
                // charging" names the STATE (what the user asked for); the
                // neutral unplug says what the machine runs on now.
                root.blink(now ? "#2BD86B" : Appearance.colors.colOnLayer0,
                    now ? Translation.tr("Battery charging") : Translation.tr("Running on battery"));
            }
        }
    }


}
