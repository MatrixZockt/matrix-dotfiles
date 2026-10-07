pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import QtQuick

/**
 * Live four-finger swipe tracking, for the popup apps.
 *
 * Hyprland's gesture binding fires once, when a swipe is already over, and it
 * carries no distance -- only a direction. That is why the settings and
 * task-manager popups could never follow your fingers the way a real window
 * does under the compositor's close-drag: by the time the app hears anything,
 * the fingers have left the pad.
 *
 * This reads the touchpad directly instead (see
 * scripts/input/touchpad-swipe.py: the session user is in the `input` group,
 * and reading an evdev node does not grab it, so Hyprland keeps receiving the
 * same events). It exposes the swipe as it happens:
 *
 *   active    fingers are on the pad right now and the count matches
 *   total     distance travelled since the swipe began, in fractions of the
 *             pad's height -- 1.0 is a full sweep of the pad
 *
 * On top of the raw stream it runs the *dismiss drag* the popups share: the
 * same gesture a real window gets from the compositor, but driven by us. The
 * consumer sets `travelScale` (pixels of movement per pad sweep), listens to
 *
 *   dragStarted()                  the fingers took the card
 *   dragMoved(offset)              offset in px, downward (never negative)
 *   dragEnded(offset, dismissed)   released: close, or spring back
 *   dragCancelled()                a palm joined / the pad vanished
 *
 * and decides nothing itself. The rules that decide "close or snap back" live
 * here, in one place, because both popups have to agree on them: carry the
 * card past DismissRatio of the screen, or flick it quickly enough, and it
 * closes -- exactly the feel of the compositor's own close threshold.
 *
 * `available` is the honest part: false while there is no tracker (no python,
 * no readable touchpad). The popup apps publish that in their presence file so
 * Hyprland's own gesture stays in charge as the fallback -- a popup must never
 * end up unclosable because a helper did not start.
 */
Singleton {
    id: root

    readonly property string script: Quickshell.shellPath("scripts/input/touchpad-swipe.py")

    /// The tracker is alive and found a device.
    property bool available: false
    /// Fingers are on the pad and the count matches the gesture.
    property bool active: false
    property int fingers: 0
    /// Fractions of the pad's height, since the swipe began / since last report.
    property real total: 0
    property real delta: 0
    /// Horizontal travel of the gesture, in fractions of the pad's WIDTH.
    /// Positive rightward. The four-finger horizontal swipe is the
    /// compositor's native workspace gesture (it drags the desktops live),
    /// so the shell never acts on it -- but it WATCHES it: when the gesture
    /// ends against a dead edge (no desktop that way), the shell shakes the
    /// whole screen as the "that direction does not work" feedback. This is
    /// the data that detection reads.
    property real htotal: 0
    /// Where the fingers are ON THE PAD, 0..1, top-left origin. A touchpad is
    /// an absolute device, so this is how a gesture says WHERE it happened --
    /// which is the whole basis of the bar's two-finger brightness/volume
    /// swipe: the same two fingers mean different things over the left island
    /// and the right one, and only the position can tell them apart.
    /// -1 while no finger has reported a coordinate.
    property real xpos: -1
    property real ypos: -1
    /// Horizontal swipes under this much of a pad-width are jitter, not
    /// intent -- the same spirit as the vertical tracker's own thresholds.
    ///
    /// 0.05, not the 0.08 this used to be, and the log is why: real
    /// four-finger swipes were arriving at 0.075, 0.078 and 0.079 -- a
    /// deliberate swipe missing the gate by a hair, which is what made this
    /// gesture feel intermittent rather than broken. 0.05 still sits well
    /// clear of the drift a four-finger VERTICAL drag produces (measured at
    /// about 0.017 on this pad), so the dismiss drag cannot start flashing
    /// the pill by leaning slightly sideways.
    readonly property real horizontalSwipeRatio: 0.05
    /// Last line the tracker wrote to stderr, kept for diagnostics.
    property string note: ""
    /// True once the tracker has failed too many times in a row to keep
    /// retrying. Gestures are off in this state and the log says so; it is
    /// the one condition that must never be silent.
    property bool down: false
    /// Consecutive exits that happened faster than a real tracker run, used
    /// only to tell a crash loop from a one-off.
    property int fastExits: 0
    /// When the tracker's heartbeat last arrived, 0 if never. This is the
    /// ground truth for "is a finger event reader actually running", as
    /// opposed to `available` or `Process.running`, which both describe what
    /// the shell BELIEVES.
    property double lastBeat: 0
    /// When the liveness check may next act. Set when the tracker reports in
    /// and again after every restart, so a shell that is still starting up is
    /// never judged.
    property double settleUntil: 0
    /// When the current run of silence was first noticed, 0 if the last check
    /// saw a heartbeat. Silence must survive two checks to count as death.
    property double silentSince: 0
    /// Whether this tracker start has already said hello.
    property bool announced: false

    Timer {
        id: restartDelay
        interval: 700
        onTriggered: {
            if (!root.down)
                tracker.running = true;
        }
    }

    // ── The liveness check: the actual permanent fix ───────────────────
    // Three things were believed to be enough, and none of them were:
    //
    //   `Process.running`  -- it says what the shell BELIEVES. Quickshell
    //                         restarts a tracker that dies on its own (verified:
    //                         killed twice, a new one appeared both times), so
    //                         this reads true and is useless as a health check.
    //   `onExited`         -- it does not fire for those restarts. Observed
    //                         directly: two kills, two restarts, zero log lines.
    //   `available`        -- set from the tracker's own stderr and never
    //                         cleared by anything but an exit nobody sees.
    //
    // What is left is the only honest signal available: the tracker's own
    // heartbeat, which it writes every 2s precisely so a dead reader is
    // noticed. A still hand means no gesture lines at all, so the heartbeat is
    // the ONLY thing that distinguishes "idle" from "gone" -- which is why it
    // exists in the script in the first place.
    //
    // This is the state the taps were found broken in: a config that loaded
    // clean, a shell with no errors, `available` true, `running` true, and no
    // reader process at all -- while a hand-run copy of the same script
    // emitted flawless tap events to a file. Every signal the shell had said
    // everything was fine. The heartbeat is what said otherwise.
    Timer {
        interval: 3000
        repeat: true
        running: true
        onTriggered: {
            if (root.down)
                return;
            // Never heard one yet: the reader may simply not have started, so
            // there is nothing to compare against.
            if (root.lastBeat === 0)
                return;
            // The settle window. A QML timer measures WALL time, and this
            // shell's event loop is blocked for many seconds while it starts
            // (thumbnails, the bar, every panel). Heartbeats queue in the pipe
            // during that and are delivered late, so a check that fires early
            // in the life of a shell sees a long gap that means nothing --
            // the reader is fine, the shell just has not read its pipe yet.
            //
            // The first version of this check had no settle window and no
            // second sighting, so it fired ~8s into every startup, killed a
            // healthy tracker, and took the whole shell into a relaunch loop
            // with it: "tracker silent for 8s" every single time, forever.
            // Two independent guards now, because a watchdog that cries wolf
            // is worse than no watchdog: it restarts the thing it watches.
            if (Date.now() < root.settleUntil)
                return;
            const silentMs = Date.now() - root.lastBeat;
            if (silentMs <= 8000) {
                root.silentSince = 0;
                return;
            }
            // Silence has to persist across a SECOND check before it counts.
            // One window is an event loop hiccup; two is a dead reader.
            if (root.silentSince === 0) {
                root.silentSince = Date.now();
                return;
            }
            console.warn(`[touchpad] tracker silent for ${Math.round(silentMs / 1000)}s over two checks -- gestures were dead, restarting it`);
            // false then true, because assigning true to an already-true
            // `running` would not spawn anything.
            tracker.running = false;
            tracker.running = true;
            // Wait for a fresh heartbeat before judging again.
            root.lastBeat = 0;
            root.silentSince = 0;
            root.settleUntil = Date.now() + 20000;
        }
    }

    // A tracker that has been up for a moment is healthy again, so the
    // crash-loop counter resets. Anything that survives this long is not
    // crash-looping.
    Timer {
        interval: 15000
        running: tracker.running
        repeat: false
        onTriggered: root.fastExits = 0
    }

    // ── The dismiss drag ──────────────────────────────────────────────────
    /// Pixels of card movement per full sweep of the pad. Set by the consumer
    /// (a screen's worth, so dragging the pad's height drags the screen's).
    property real travelScale: 1000
    /// How far the card is dragged, in px, right now.
    property real dragOffset: 0
    /// True from the moment the fingers land until they lift.
    readonly property bool dragging: dragSession

    /// Progress past which letting go closes the app, as a fraction of a pad
    /// sweep. Roughly a fifth of the pad: the same "carried it far enough"
    /// feel as a window's own dismiss distance.
    readonly property real dismissRatio: 0.15
    /// ...or a short-but-fast flick: this far past, at this speed (pad
    /// sweeps per second), counts as "thrown away" even if it did not travel.
    readonly property real flickRatio: 0.05
    readonly property real flickSpeed: 0.7

    signal dragStarted()
    // Every tracked gesture's motion, as it happens. The bar's two-finger
    // brightness/volume swipe rides this rather than polling `total` from a
    // timer: a poll quantises the gesture to whatever the timer's interval
    // is, which on a fast flick means the whole swipe lands in one step and
    // the backlight jumps. This is the tracker's own event rate.
    //
    //   dy   vertical travel this frame, in pad heights (positive = down)
    //   x, y where the fingers are on the pad, 0..1 top-left
    //   fingers, start  the live count, and the count the gesture began with
    signal moved(real dy, real x, real y, int fingers, int start)
    // Emitted when a gesture actually begins tracking (the `begin` phase).
    // The bar's swipe uses it to recognise a burst SEQUENCE: a new gesture
    // landing inside its end-grace continues the previous one -- same zone,
    // same anchor -- instead of tearing the latch down and re-probing, which
    // is what made minimal-movement brightness control stutter.
    signal gestureStarted(int start)
    // The gesture is over -- fingers lifted, or the count left the tracked set.
    // The bar's swipe needs this to drop its step budget: without it the
    // leftover half-step from one swipe would be carried into the next, and
    // the first press of a fresh gesture would jump by a step before the
    // fingers had travelled a pixel.
    signal gestureEnded(int start)
    // A four-finger HORIZONTAL swipe that just ended with real sideways
    // travel. The compositor owns the gesture itself (workspace switch);
    // this signal is only the announcement the shell uses to judge whether
    // the swipe went somewhere (a desktop moved) or hit a dead edge (shake).
    signal horizontalSwipeEnded(real travel)
    // A multi-finger TAP (rest, don't swipe): the tracker judged the contact
    // short and still. `fingers` is the count at the START of the gesture --
    // the count the user meant -- because by emit time the fingers have
    // lifted and the live slots are gone. Routing lives in shell.qml:
    //   3 fingers -> play/pause of the active MPRIS player, falling back
    //                to the wallpaper carousel when no player exists
    //   4 fingers -> the desktops overview
    signal tapTriggered(int fingers)
    signal dragMoved(real offset)
    signal dragEnded(real offset, bool dismissed)
    signal dragCancelled()

    property bool dragSession: false
    property double dragStartedAt: 0

    function consume(line) {
        if (!line || line.length === 0) return;
        let report;
        try {
            report = JSON.parse(line);
        } catch (error) {
            return; // a torn line, or something else on stdout: ignore
        }
        // The tracker's heartbeat (`{"hb":1}`) carries no phase and is of no
        // use to any gesture. It matters for exactly one thing: proving the
        // reader is ALIVE while the pad is idle.
        if (report && report.hb) {
            // One line per tracker start, and only one: the heartbeat arrives
            // every 2 seconds forever, and the whole point of it is that it is
            // not written to the log. This single line is the difference
            // between "the reader is talking to the shell" and "a process
            // exists somewhere", which is the distinction this whole check
            // exists to make.
            //
            // `lastBeat` is NOT set here, and that is deliberate. The tracker
            // only writes a heartbeat when its poll TIMES OUT -- when there
            // have been no events for two seconds -- so a hand that keeps
            // moving starves the heartbeat completely. Judging liveness on the
            // heartbeat alone therefore restarted a healthy tracker in the
            // middle of a long scroll: "silent for 19s" while the gesture
            // frames were streaming past, which kills the very gesture the
            // check was meant to protect.
            root.lastBeat = Date.now();
            if (!root.announced) {
                root.announced = true;
                console.log(`[touchpad] tracker alive on ${root.note}`);
            }
            return;
        }
        if (!report || typeof report.phase !== "string") return;
        // Any gesture frame is proof the reader is alive and reading -- which
        // is exactly what the heartbeat cannot say while the pad is in use, so
        // both kinds of traffic feed the same liveness clock.
        root.lastBeat = Date.now();
        if (report.phase === "begin")
            root.gestureStarted(report.start ?? root.fingers ?? 0);

        root.fingers = report.fingers ?? 0;
        switch (report.phase) {
        case "begin":
            root.active = true;
            // Adopt the report's total rather than blindly zeroing: a RE-JOIN
            // begin (finger count dipped and returned within the tracker's
            // grace) carries the PRESERVED accumulator, and the bar's swipe
            // distinguishes re-join from true-new-gesture precisely by this
            // value being non-zero. A true new gesture reports 0, so the
            // old behaviour is unchanged for it.
            root.total = report.total ?? 0;
            root.delta = 0;
            root.htotal = report.htotal ?? 0;
            root.xpos = report.x ?? -1;
            root.ypos = report.y ?? -1;
            // The dismiss drag belongs to the FOUR-finger gesture alone. The
            // tracker now also reports two-finger contacts (the bar's
            // brightness/volume swipe), and a two-finger drag of a card was
            // never a thing anybody asked for -- it would fight the swipe that
            // is the whole reason those contacts are being watched.
            root.dragSession = (report.start ?? root.fingers) === 4;
            root.dragOffset = 0;
            root.dragStartedAt = Date.now();
            if (root.dragSession)
                root.dragStarted();
            break;
        case "tap":
            // The tracker judged the contact a TAP (short, still): a
            // multi-finger tap, routed by the count that STARTED it. Not a
            // drag session -- nothing follows fingers here -- so no drag
            // signals fire and every listener stays untouched.
            root.active = false;
            root.dragSession = false;
            root.tapTriggered(report.start ?? 0);
            break;
        case "update":
            root.active = true;
            root.delta = report.dy ?? 0;
            root.total = report.total ?? root.total;
            root.htotal = report.htotal ?? root.htotal;
            if (report.x !== undefined) root.xpos = report.x;
            if (report.y !== undefined) root.ypos = report.y;
            root.moved(report.dy ?? 0, root.xpos, root.ypos,
                report.fingers ?? root.fingers, report.start ?? root.fingers);
            if (root.dragSession) {
                // Downward only: this is a dismiss gesture, and a card that
                // flew up under an upward swipe would read as a bug.
                root.dragOffset = Math.max(0, root.total) * root.travelScale;
                root.dragMoved(root.dragOffset);
            }
            break;
        case "end":
            root.active = false;
            root.gestureEnded(report.start ?? root.fingers);
            // Announce a real four-finger horizontal swipe BEFORE the drag
            // teardown: the shake detector only needs the ended gesture's
            // travel, and the vertical dismiss machinery below must not
            // swallow it (a horizontal swipe has ~zero vertical travel, so
            // `dismissed` would be false and nothing else would react).
            // `peak`, NOT `start`. The tracker corrects `start` to the peak
            // only when it decides a gesture was a TAP; for an "end" it keeps
            // whatever count happened to land first, and four fingers do not
            // land in the same millisecond -- three usually qualify first. So a
            // genuine four-finger swipe was arriving here as `start: 3`,
            // failing this gate, and horizontalSwipeEnded never fired AT ALL.
            // That is why the desktop pill stopped appearing for the swipe
            // and why no [edge] line was ever written: the signal never left
            // this object. `peak` is in every payload, is the count the tap
            // path already routes on, and is the only one of the three that
            // describes how many fingers the user actually used.
            if ((report.peak ?? report.start ?? root.fingers) === 4
                && Math.abs(root.htotal) >= root.horizontalSwipeRatio) {
                console.log(`[swipe] 4-finger horizontal travel=${root.htotal.toFixed(3)} peak=${report.peak} start=${report.start} dur=${report.dur_ms}ms`);
                root.horizontalSwipeEnded(root.htotal);
            } else {
                // Why a four-finger horizontal gesture did NOT qualify, with
                // the numbers that decided it. A gesture that silently fails
                // to reach the shell is indistinguishable from one that was
                // never wired up, which is exactly how the peak bug above
                // survived so long.
                console.log(`[swipe] end not a 4-finger horizontal: peak=${report.peak} start=${report.start} htotal=${root.htotal.toFixed(3)} need=${root.horizontalSwipeRatio} dur=${report.dur_ms}ms`);
            }
            root.finishDrag(true);
            break;
        case "cancel":
            root.active = false;
            root.gestureEnded(report.start ?? root.fingers);
            root.finishDrag(false);
            break;
        }
    }

    function finishDrag(natural) {
        if (!root.dragSession) return;
        root.dragSession = false;
        if (!natural) {
            // A palm landed, or the device went away: never close on that.
            root.dragCancelled();
            root.dragOffset = 0;
            return;
        }
        const elapsed = Math.max(1, Date.now() - root.dragStartedAt);
        const speed = root.total / (elapsed / 1000);
        const dismissed = root.total >= root.dismissRatio
            || (root.total >= root.flickRatio && speed >= root.flickSpeed);
        root.dragEnded(root.dragOffset, dismissed);
    }

    function reset() {
        root.active = false;
        root.total = 0;
        root.delta = 0;
        root.htotal = 0;
        root.xpos = -1;
        root.ypos = -1;
        root.dragSession = false;
        root.dragOffset = 0;
    }

    Process {
        id: tracker

        // Orphan-proofing, the honest way. The tracker used to be this
        // singleton's direct child; a popup app killed without cleanup left
        // its tracker orphaned but ALIVE, reparented to init -- and each
        // orphan still held the launch scripts' flock (children inherit
        // fds), which is how the task manager "stopped opening": every
        // launch waited out its lock timeout and gave up, silently. Three
        // orphans were found live. Quickshell has no detach option on
        // Process (launchdetached does not exist -- verified), so the child
        // is a bash that supervises the python reader and traps EXIT.
        //
        // The exec matters: an earlier revision wrote "exec python3", which
        // REPLACED bash with python -- the trap was destroyed with the shell
        // that owned it, and a shell restart left the old tracker running
        // (observed: orphan pid 50747 outlived its shell). Without exec,
        // bash outlives python, waits for it, and the trap cleans up the
        // group. For the hard case -- the shell itself dies without killing
        // children -- the pipe is the cleanup: python's stdout IS the pipe
        // to the shell, the first write after the shell's death raises
        // BrokenPipeError, python exits, wait returns, the trap fires.
        // The tracked counts. 3 is here because the shell routes a THREE-finger
        // tap to play/pause, and the helper only tracks counts in this set --
        // `if count not in self.finger_set: self.end()` -- so with "2,4" a
        // three-finger contact was ended before it ever began and the tap
        // could not exist. Nothing else changes: the four-finger swipe and the
        // two-finger bar swipe both gate on their own count downstream
        // (`=== 4`, `start !== 2`), so three fingers is tracked and then
        // ignored by both, and only the tap consumes it.
        command: ["bash", "-c", `trap 'kill -- "-$$" 2>/dev/null; pkill -P $$ 2>/dev/null' EXIT; python3 -u ${root.script} --fingers 2,3,4 & wait $!`]
        running: true

        // ── The tracker restarts itself ────────────────────────────────
        // `running: true` starts the process ONCE. When it exits, Quickshell
        // clears `running` and nothing puts it back: the singleton goes on
        // looking perfectly healthy -- `available` is still true from the
        // last time it reported, no property moves, nothing is logged -- while
        // no finger event reaches the shell at all. Every gesture on the
        // touchpad then silently does nothing.
        //
        // That is not hypothetical: the tracker was killed (by hand, while
        // swapping the script out) and never came back, and the symptom was
        // "three- and four-finger taps do not work" with a clean config, a
        // healthy shell, and a tracker that turned out to be provably
        // emitting perfect tap events -- to a file, from a second copy of the
        // same script, while the shell's own copy was dead on the floor.
        //
        // So the death is now an event with a consequence: restart after a
        // beat, and say so. The delay keeps a shell that is tearing the
        // tracker down on purpose from racing it back up, and the
        // consecutive-failure cap stops a genuinely broken script from
        // becoming a spawn loop -- in that case the shell says the tracker is
        // down instead of quietly pretending it is up.
        onExited: (exitCode) => {
            // No tracker: back to Hyprland's gesture, and say so, so a popup
            // is never left with a swipe that does nothing. The reset is the
            // original behaviour and stays -- a half-finished gesture must not
            // survive into the next one.
            root.available = false;
            root.reset();
            root.fastExits += 1;
            if (root.fastExits > 5) {
                console.error(`[touchpad] tracker gave up after ${root.fastExits} fast exits -- gestures are OFF until the config reloads`);
                root.down = true;
                return;
            }
            console.warn(`[touchpad] tracker exited (${exitCode}), restarting`);
            // Bare id, NOT `root.restartDelay`: an id is not a property, so
            // reaching it through `root` yields undefined. The first version
            // of this line did exactly that and every tracker exit threw a
            // TypeError instead of restarting anything.
            restartDelay.restart();
        }


        // The tracker names the device it settled on before it starts reading,
        // and that line is also the proof it is working: only then is it safe
        // to hand the swipe over from Hyprland's own gesture.
        stderr: SplitParser {
            splitMarker: "\n"
            onRead: line => {
                if (!line) return;
                root.note = line;
                if (line.startsWith("tracking ")) {
                    root.available = true;
                    // It is talking: give it the settle window before any
                    // liveness check is allowed to judge it.
                    root.settleUntil = Date.now() + 20000;
                    root.silentSince = 0;
                    // It reported in, so it is alive: clear the failure state
                    // a previous crash loop left behind.
                    root.fastExits = 0;
                    root.down = false;
                }
            }
        }

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => root.consume(line)
        }

        // The process is gone: back to Hyprland's gesture, and say so, so a
        // popup is never left with a swipe that does nothing.
        //
        // The RESTART lives in the `onExited` above rather than here, because
        // `running: true` starts a Process exactly once: when the tracker
        // exits, Quickshell clears `running` and nothing ever set it back.
        // The singleton then goes on looking perfectly healthy -- `available`
        // was true from the last report, no property moves, nothing is logged
        // -- while no finger event reaches the shell at all, and every
        // gesture on the touchpad silently does nothing.
        //
        // That is not hypothetical. The tracker was killed once while its
        // script was being swapped, never came back, and the symptom was
        // "three- and four-finger taps do not work at all" against a config
        // that loaded clean and a shell with no errors in it -- while a second
        // copy of the same script, run by hand, was emitting perfect tap
        // events to a file. The gestures were working. Nothing was listening.
    }
}
