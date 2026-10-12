import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower

/**
 * The power-mode notice: what a switch moved.
 *
 * Switching mode used to be silent. The platform profile, the graphics cap and
 * the shell's own motion all move together, and nothing on screen said which of
 * them had moved -- so the only way to know what a mode had done was to go and
 * look at three separate places, one of which (the cap) takes a second and a
 * half to settle.
 *
 * Two of the rows report a REAL before and after, because the service that
 * performs the switch records them (PowerMode.lastChange): the platform profile
 * it captured the moment before writing, and the shell's motion, which is a
 * pure function of the mode.
 *
 * The other two -- the graphics cap and the CPU package limit -- are hardware,
 * and they are the two the switch actually moves in Performance. Their AFTER
 * column is measured HERE, in this card, when it appears: the notice can open
 * with the island on another view and the card closed, neither of which is
 * sampling, so measuring it here is the only way it is never stale. Their
 * BEFORE column is the snapshot PowerMode takes at the instant of the switch
 * (PowerMode.before) -- see DON'T READ THE HARDWARE FOR "BEFORE" below.
 *
 * WHAT THESE TWO ROWS GOT WRONG, and why they are worth this much text:
 *
 *   * The graphics row asked nvidia-smi for power.limit, which answers [N/A]
 *     on this card, so the row always fell through to a hardcoded pair --
 *     "cap 115 W · boost" / "cap 55 W · idle" -- and read the SAME in balanced
 *     and in Performance. A mode switch that moved the ceiling looked like one
 *     that had moved nothing. The field that answers is enforced.power.limit.
 *   * The CPU row reported the scaling governor and EPP. intel_pstate runs the
 *     "powersave" governor in EVERY profile (EPP is what it varies), so on this
 *     machine the row said "powersave" in all three modes: the exact shape of
 *     "it is still in power saver when it is not". The number that actually
 *     moves is the package cap (RAPL PL1/PL2) plus turbo.
 *   * The before column was left by the PREVIOUS card (PowerMode.lastCaps), so
 *     it only existed after a mode had been switched twice in one session: the
 *     first switch -- the one people actually look at -- showed no transition
 *     at all. "55 W -> up to 140 W · boost" is the whole point of the graphics
 *     row and it was the one thing that could not be read.
 *   * And the numbers it read could be the ones it was replacing: the CPU
 *     package cap is applied by power-autoswitch on a 5 s poll, so a switch
 *     could sit on the old cap for up to 5.3 s while this card measured,
 *     printed the previous mode's "20/30 W · turbo off", and closed. Turbo
 *     "off" in Performance, measured (see PowerMode.apply, which now asks the
 *     daemon to converge straight away -- the cap lands in 390-650 ms).
 *
 * DON'T READ THE HARDWARE FOR "BEFORE".
 *
 * By the time this card exists the switch has already happened, so the values
 * it is comparing against are gone: the GPU ceiling lifts ~400 ms after the
 * write and the package cap follows at ~650 ms. PowerMode therefore takes one
 * snapshot at the top of the change handler -- before apply() runs, ~50 ms of
 * reading with the ceiling still ~350 ms away -- and the notice formats what
 * came back. That is also why this card no longer leaves a measurement behind
 * for the next one: the service has the real thing, on every switch, including
 * the first one after a reload.
 */
Item {
    id: root

    // The switch being reported. PowerMode records it before applying, so it is
    // already there when this card is loaded by the OSD.
    readonly property var change: PowerMode.lastChange
    readonly property var mode: PowerMode.currentMode

    // ── The measurements ─────────────────────────────────────────────────
    //
    // `now` is this card's own settled reading of the hardware, taken over the
    // seconds after the switch (see the refresh schedule below). `before` is
    // the snapshot PowerMode took at t=0 -- bound rather than copied, so this
    // card updates the moment the read lands (~50 ms after it opens) and so a
    // card can never show a previous switch's state.
    property var now: null
    readonly property var before: PowerMode.before
    // The raw text behind the last reading, kept for the probe below: a wrong
    // number can then be told apart from a parse slip without a second probe.
    property string lastRaw: ""

    // One process, one line per field, `---` between them. The command and its
    // parser live in PowerMode: this service has to read the same facts at the
    // moment of a switch, and two formats would be two things to keep in step.
    Process {
        id: facts
        command: PowerMode.capsCommand
        stdout: StdioCollector {
            onStreamFinished: {
                root.lastRaw = this.text;
                root.now = PowerMode.parseCaps(this.text);
            }
        }
    }

    // ── Measuring at the right moment ────────────────────────────────────
    //
    // A switch moves the platform profile, the boost daemon and the package cap
    // through three different services, at three very different speeds.
    // Measured on this machine from the config write (three trials each way):
    //
    //     Dynamic Boost on/off          90-400 ms  (ceiling; the daemon itself
    //                                                flips at ~90-135 ms)
    //     package cap (RAPL)            3.0-5.3 s  (power-autoswitch -> pkexec,
    //                                               on the daemon's 5 s poll)
    //     package cap, with the poke    390-650 ms (PowerMode.apply asks for
    //                                               --converge immediately, and
    //                                               that is what a switch does)
    //
    // So a single read at t=0 caught the hardware BEFORE it had settled and
    // reported the PREVIOUS mode's numbers -- the same complaint as reporting
    // nothing at all. The card therefore reads immediately (so it is never
    // blank) and then keeps reading until the values have had time to land,
    // taking the last answer. Bounded by the card's own lifetime: the OSD holds
    // this card for the configured timeout plus the extra OnScreenDisplay adds
    // for it. `refreshes`/`refreshMax` are 900 ms apart and stop at 4.5 s, and
    // the card lives 5.0 s at the default 1 s timeout, so the last reading is
    // the settled one and it is on screen to be read.
    //
    // Deliberately a fixed schedule rather than "stop once two reads agree":
    // the two halves settle half a second apart and either can be the slower
    // one (measured both ways: the ceiling at 400 ms with the cap at 650, and
    // the cap at 390 ms with the ceiling at 640), so a CPU row can agree with
    // itself twice while its cap is still on the way. Stopping early would
    // freeze exactly the numbers this card exists to correct.
    property int refreshes: 0
    readonly property int refreshMax: 5

    Timer {
        interval: 900
        running: true
        repeat: true
        onTriggered: {
            if (root.refreshes >= root.refreshMax) {
                stop();
                return;
            }
            root.refreshes += 1;
            facts.running = false;
            facts.running = true;
        }
    }

    Component.onCompleted: facts.running = true

    // ── Reading the card from outside ────────────────────────────────────
    //
    // What this card SAYS, as text, without a screenshot: the rows are the
    // whole product and the interesting failures are all content failures (a
    // before column that was never filled, a turbo that reads the old mode).
    // Same shape as the bar panel's probes, and the only way to check the text
    // of a card that lives for five seconds:
    //
    //   qs -c ii ipc call nowbarPanel setPowerMode performance
    //   qs -c ii ipc call performanceMode rows
    //
    // The handler exists only while the card is on screen, because the card
    // does: the OSD loads it on demand.
    IpcHandler {
        target: "performanceMode"

        function rows(): string {
            return JSON.stringify(root.rows);
        }

        // The inputs behind those rows: both readings, and the raw text the
        // last one parsed (see lastRaw).
        function facts(): string {
            return JSON.stringify({
                before: root.before,
                now: root.now,
                refreshes: root.refreshes,
                raw: root.lastRaw
            });
        }
    }

    // ── Formatting ───────────────────────────────────────────────────────
    function profileName(profile) {
        switch (profile) {
        case PowerProfile.Performance:
            return Translation.tr("Performance");
        case PowerProfile.PowerSaver:
            return Translation.tr("Power saver");
        default:
            return Translation.tr("Balanced");
        }
    }

    // The shell's own motion, straight off the value it is applied from (see
    // Appearance.animationCurves.motionScale): every duration in the interface
    // is its full length times this, so 12% is what "the interface answers
    // immediately" actually means here.
    function motionText(mode) {
        return mode === "performance" ? "12%" : "100%";
    }

    // The reached ceiling while Dynamic Boost is on, and the fixed one while it
    // is off -- which is the difference a mode switch actually makes here.
    //
    // No invented numbers: an unreadable field says so rather than falling back
    // to a constant, because a constant is exactly what made this row read the
    // same in every mode (it used to print "cap 115 W · boost" whether the
    // hardware said 115, 140 or nothing at all). A boosted state reports the
    // REACHABLE ceiling rather than the idle reading: 115 W is not a cap, it is
    // what the same ceiling happens to read when nothing is asking for the
    // watts, and 140 W is what it reads under a real load.
    function capText(state) {
        if (!state)
            return Translation.tr("—");
        if (state.boosted) {
            const reach = Math.round(state.capMaxW > 0 ? state.capMaxW : 0);
            if (reach > 0)
                return Translation.tr("up to %1 W · boost").arg(reach);
            return Translation.tr("dynamic boost");
        }
        if (state.capKnown && state.capW > 0)
            return Translation.tr("cap %1 W").arg(Math.round(state.capW));
        return Translation.tr("—");
    }

    // The package cap and turbo: the numbers the mode actually moves. The
    // governor is deliberately gone from this row -- intel_pstate runs
    // "powersave" in every profile, so it reported the same word in all three
    // modes and looked like a machine stuck in power saver.
    function policyText(state) {
        if (!state || (state.pl1W <= 0 && state.pl2W <= 0))
            return Translation.tr("—");
        const watts = Translation.tr("%1/%2 W").arg(state.pl1W).arg(state.pl2W);
        return state.turbo === "" ? watts : Translation.tr("%1 · turbo %2").arg(watts).arg(state.turbo);
    }

    // The card's contents, as rows. A row's `before` is blank when there is
    // nothing to compare against (the shell has just started, or PowerMode's
    // snapshot has not landed yet) -- blank, not "—", because this column draws
    // an arrow when it has a value and an empty cell is honestly empty.
    readonly property var rows: [
        {
            icon: "tune",
            label: Translation.tr("Platform profile"),
            before: root.change ? root.profileName(root.change.profileBefore) : "",
            after: root.profileName(PowerProfiles.profile)
        },
        {
            icon: "developer_board",
            label: Translation.tr("Graphics cap"),
            before: root.before ? root.capText(root.before) : "",
            after: root.capText(root.now)
        },
        {
            icon: "speed",
            label: Translation.tr("CPU policy"),
            before: root.before ? root.policyText(root.before) : "",
            after: root.policyText(root.now)
        },
        {
            icon: "animation",
            label: Translation.tr("Shell motion"),
            before: root.change ? root.motionText(root.change.from) : "",
            after: root.motionText(root.change ? root.change.to : PowerMode.current)
        }
    ]

    // Wider than the volume card on purpose: this one is a small table, not a
    // bar, and four rows of two values need the room to stay on one line each.
    implicitWidth: 340 + 2 * Appearance.sizes.elevationMargin
    implicitHeight: card.implicitHeight + 2 * Appearance.sizes.elevationMargin

    StyledRectangularShadow {
        target: card
    }
    Rectangle {
        id: card
        anchors {
            fill: parent
            margins: Appearance.sizes.elevationMargin
        }
        implicitWidth: 340
        implicitHeight: content.implicitHeight + 24
        // Not the volume card's pill: a rounded rectangle reads as a panel of
        // facts, and the two can be on screen together.
        radius: Appearance.rounding.large
        color: Appearance.colors.colLayer0

        ColumnLayout {
            id: content
            anchors {
                fill: parent
                margins: 12
            }
            spacing: 7

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Rectangle {
                    implicitWidth: 32
                    implicitHeight: 32
                    radius: Appearance.rounding.verysmall
                    color: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.84)
                    MaterialSymbol {
                        anchors.centerIn: parent
                        text: root.mode?.icon ?? "bolt"
                        iconSize: 19
                        color: Appearance.colors.colPrimary
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    StyledText {
                        Layout.fillWidth: true
                        text: Translation.tr("POWER MODE").toUpperCase()
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        font.weight: Font.Medium
                        font.letterSpacing: 1.4
                        color: Appearance.colors.colOnLayer1Inactive
                        elide: Text.ElideRight
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: root.mode?.name ?? ""
                        font.pixelSize: Appearance.font.pixelSize.normal
                        font.weight: Font.Medium
                        color: Appearance.colors.colOnLayer0
                        elide: Text.ElideRight
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 1
                color: Appearance.colors.colOutlineVariant
            }

            Repeater {
                model: root.rows

                delegate: RowLayout {
                    id: row
                    required property var modelData
                    // `before` is the value this row held a moment ago; it is
                    // joined to the new one by an arrow rather than described,
                    // so the eye finds the rows that MOVED without reading any
                    // of them.
                    readonly property bool moved: modelData.before !== ""
                        && modelData.before !== modelData.after

                    Layout.fillWidth: true
                    spacing: 7

                    MaterialSymbol {
                        text: modelData.icon
                        iconSize: 15
                        color: Appearance.colors.colSubtext
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: modelData.label
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                        elide: Text.ElideRight
                    }
                    StyledText {
                        visible: row.moved
                        text: modelData.before
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colOnLayer1Inactive
                    }
                    MaterialSymbol {
                        visible: row.moved
                        text: "arrow_forward"
                        iconSize: 13
                        color: Appearance.colors.colPrimary
                    }
                    StyledText {
                        text: modelData.after
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        font.weight: row.moved ? Font.Medium : Font.Normal
                        color: row.moved ? Appearance.colors.colPrimary
                            : Appearance.colors.colOnLayer0
                        elide: Text.ElideRight
                    }
                }
            }
        }
    }
}
