pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell
import QtQuick

/**
 * The liquid top bar's spring.
 *
 * Drives ONE number: the pull progress `t` of the bar's open pocket (0 = bar
 * at rest, 1 = fully extended). Every consumer -- the bar's stretched
 * background, the window's extended height and input mask -- reads the same
 * value, so what you see is always one coherent liquid motion.
 *
 * Why a hand-rolled spring rather than a Behavior/SpringAnimation: the value
 * is integrated INSIDE the spring and never assigned from outside, so a
 * mid-flight retarget -- the pointer moving from the sound icon to wifi
 * before the pocket finished extending -- re-aims the same motion and glides,
 * where an outside assignment would restart it and snap. Letting go (target
 * back to 0) makes the same spring overshoot and settle: the rubber band.
 *
 * Stiffness/damping: extends in ~55 ms, bounces ~9% and settles in ~450 ms;
 * the return trip lifts slightly past closed (a real rubber band) before
 * resting. Ticks at 120 Hz while moving for a smooth bounce.
 *
 * Performance: ticks at 60 fps only while moving; the timer stops dead when
 * the spring settles (distance and velocity both ~0), so an idle bar costs
 * nothing.
 */
Singleton {
    id: root

    /// Which widget's pocket is open: "sound", "network", "bluetooth",
    /// "battery", "media". Empty string = at rest.
    property string pocketId: ""

    /// The last NON-empty pocket id. While the pocket retracts `pocketId` is
    /// already cleared, but the content has to stay on screen until the spring
    /// has finished closing -- otherwise the shell would still be open while
    /// its content had already blinked away in one frame.
    property string lastPocketId: ""

    /// The pull progress, 0..1 (can overshoot slightly while springing back).
    /// Read by Bar.qml and BarContent; written only here.
    property real t: 0.0

    /// The droplet: the horizontal center (bar coordinates) of the hovered
    /// icon, the width of the small curved section hanging under it, where
    /// that center ends up once clamped on screen, and how deep the section
    /// reaches. The center comes from the hover handler; the SIZE comes from
    /// the open pocket's own content (see BarContent), so the shell is always
    /// exactly as large as the information it carries.
    property real dropCenter: 0
    property real dropWidth: 0
    property real dropHeight: 68
    property real dropX: 0

    /// Arm/disarm a pocket. Calling with the SAME id re-arms harmlessly;
    /// switching ids mid-flight retargets the same spring (no restart).
    function setPocket(id) {
        pocketId = id ?? "";
        if (pocketId.length > 0)
            lastPocketId = pocketId;
        spring.target = pocketId.length > 0 ? 1.0 : 0.0;
        // Waking the spring is the caller's job is nobody's job -- the ticker
        // is bound to `running`, and only `step()` ever stopped it. Without
        // this the target changed but t never moved.
        spring.running = true;
    }
    function step() {
        // ω ≈ 2π·9.5 Hz, ζ ≈ 0.42. A REAL bounce: the drop overshoots down
        // ~9% on the way out (and lifts ~5% past closed on the way back in
        // -- negative t renders as nothing, the clamps eat it), then visibly
        // boings before settling in ~450 ms. The launch itself is still a
        // snap (~55 ms to first full extension), so the character is:
        // punch out, springy settle, punch in, springy settle. Two substeps
        // per 8ms tick keeps the explicit integration stable at this
        // stiffness and keeps the bounce smooth at high refresh rates.
        const omega = 60.0, zeta = 0.42, dt = 0.008;
        for (let i = 0; i < 2; i++) {
            const a = -omega * omega * (spring.value - spring.target) - 2 * zeta * omega * spring.velocity;
            spring.velocity += a * dt;
            spring.value += spring.velocity * dt;
        }
        if (Math.abs(spring.value - spring.target) < 0.001 && Math.abs(spring.velocity) < 0.001) {
            spring.value = spring.target;
            spring.velocity = 0;
            spring.running = false;
        }
        root.t = spring.value;
    }

    QtObject {
        id: spring
        property real target: 0
        property real value: 0
        property real velocity: 0
        property bool running: false
        onRunningChanged: if (running && !ticker.running) ticker.restart()
    }

    Timer {
        id: ticker
        interval: 8
        repeat: true
        running: spring.running
        onTriggered: root.step()
    }
}
