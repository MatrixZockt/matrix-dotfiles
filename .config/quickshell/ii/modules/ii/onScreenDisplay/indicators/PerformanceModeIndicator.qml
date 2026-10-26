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
 * THE PANEL'S OWN MODE IS TWO OF THOSE ROWS: the resolution and the refresh
 * rate the screen is being driven at, read from the COMPOSITOR (PowerMode's
 * one command, the same read, the same parser -- see the display rows below).
 * A power mode moves the refresh rate on this machine -- power-saver drives
 * this 240 Hz panel at 60 -- so a switch that also changes how the desktop
 * feels has to say so, or the smoothest thing about Performance mode goes
 * unmentioned. It is also the only pair of rows here reporting something a
 * person can SEE, which makes them the check on the others: if the rate did
 * not move, this is where that shows.
 *
 * AND IT MOVES. A row does not simply appear holding its answer. It opens
 * showing the value the machine HAD -- alone, right-aligned, where a single
 * value sits -- and then that value slides aside as the arrow and the value the
 * switch brought arrive beside it. The rows are staggered, so the table is READ
 * down the card rather than glimpsed in one frame. The card itself lands with a
 * hair of scale and a fade first, so the order the eye gets is: the card, then
 * the values moving, one row at a time. See the reveal in the delegate for the
 * exact order, and for why the stagger is not scaled by motionScale while the
 * swoosh itself is.
 *
 * AND IT DOES NOT MOVE UNTIL THERE IS SOMETHING TO SAY. A switch hands this
 * card its values in waves: the switch's own record at once, the first hardware
 * read a tenth of a second later, and the settled one about a second in. So the
 * after column passes through the "—" placeholder, and rows 3 and 4 often pass
 * through the OLD mode's numbers as well (the cap takes 390-650 ms to converge),
 * before it holds anything worth comparing. A row therefore reveals only once
 * BOTH sides are real readings (see `comparable` in the delegate), and it reveals
 * exactly once per comparison (`playedPair`), so the value the switch actually
 * ended up bringing is the one the old value slides aside for.
 *
 * That order matters, and this is the bug it fixes. The placeholder reveal used
 * to fire the moment `before` landed -- the old value slid aside for "—", a
 * 38 px move instead of the 180 the real answer needs -- and it then spent the
 * one reveal the row was allowed, so when the settled value arrived there was
 * nothing left to animate: `travel` was still 1, and the old value and the arrow
 * appeared at their final layout in a single frame. Two artifacts of one cause,
 * and both were visible: a short shift left that was never the real move, then a
 * teleport to the position the old value should have slid to. The reveal now
 * starts from the value's parked position -- right-aligned, where a lone value
 * sits -- and covers the whole distance, because the distance it animates is the
 * one the final comparison asks for.
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
        id: refreshTimer
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

    // A switch that arrives while this card is STILL ON SCREEN reuses it: the
    // OSD loads the indicator by source URL (OnScreenDisplay.qml) and that URL
    // has not changed, so the component is not rebuilt -- only its bindings
    // re-evaluate. Which meant the second switch of a quick pair kept the first
    // one's measurement: the before column moved (PowerMode.before is a
    // binding), the after column did not (the schedule above had already run
    // out), both columns read the same, and the arrow -- the entire point of
    // the row -- did not appear. Measured 2026-10-12 on two switches 5 s apart,
    // which is exactly how someone compares two modes.
    //
    // So the measurement restarts with the SWITCH, not with the card: the old
    // numbers are dropped (a "—" is honest while the new ones are being read,
    // and the read takes ~50 ms) and the full schedule runs again. The OSD
    // pushes its own dismissal back on a switch, so there is time for it.
    Connections {
        target: PowerMode
        function onChangeSeqChanged() {
            root.now = null;
            root.refreshes = 0;
            facts.running = false;
            facts.running = true;
            refreshTimer.restart();
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

    // ── The panel's mode ────────────────────────────────────────────────
    //
    // Two rows rather than one line holding both facts, which is against this
    // card's taste for rows that move -- and deliberately so. The resolution is
    // what proves the panel is on its NATIVE mode (the thing "optimized" means
    // for this screen), and the refresh rate is what a power mode actually
    // changes about the screen. Fused into one string, the rate's arrow would
    // sit at the end of a line twice as long as any other row, and the one
    // value that moved would be the one hardest to find.
    //
    // Both read from PowerMode's single reading of the COMPOSITOR -- the mode
    // the panel is being DRIVEN at, not the modes it advertises -- which is
    // also why the resolution row is allowed to read the same on both sides:
    // it is a fact about the machine right now, not a spec sheet.
    function resolutionText(state) {
        if (!state || !state.displayW || !state.displayH)
            return Translation.tr("—");
        return `${state.displayW}×${state.displayH}`;
    }
    function refreshText(state) {
        if (!state || !state.displayHz)
            return Translation.tr("—");
        return Translation.tr("%1 Hz").arg(Math.round(state.displayHz));
    }

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
    //
    // `measured` says where the after column's value comes from, and the reveal
    // reads it (see `comparable` in the delegate): the four hardware rows are
    // showing "—" until the read below has landed, while the two that come off
    // PowerMode's own record of the switch are real the instant the card exists.
    // Without the distinction the reveal cannot tell a placeholder from a
    // reading, and it animates for the placeholder -- which is exactly how the
    // old value used to spend its reveal on "—" and teleport when the real answer
    // arrived.
    readonly property var rows: [
        {
            icon: "tune",
            label: Translation.tr("Platform profile"),
            measured: false,
            before: root.change ? root.profileName(root.change.profileBefore) : "",
            after: root.profileName(PowerProfiles.profile)
        },
        {
            icon: "monitor",
            label: Translation.tr("Resolution"),
            measured: true,
            before: root.before ? root.resolutionText(root.before) : "",
            after: root.resolutionText(root.now)
        },
        {
            icon: "refresh",
            label: Translation.tr("Refresh rate"),
            measured: true,
            before: root.before ? root.refreshText(root.before) : "",
            after: root.refreshText(root.now)
        },
        {
            icon: "developer_board",
            label: Translation.tr("Graphics cap"),
            measured: true,
            before: root.before ? root.capText(root.before) : "",
            after: root.capText(root.now)
        },
        {
            icon: "speed",
            label: Translation.tr("CPU policy"),
            measured: true,
            before: root.before ? root.policyText(root.before) : "",
            after: root.policyText(root.now)
        },
        {
            icon: "animation",
            label: Translation.tr("Shell motion"),
            measured: false,
            before: root.change ? root.motionText(root.change.from) : "",
            after: root.motionText(root.change ? root.change.to : PowerMode.current)
        }
    ]

    // Wider than the volume card on purpose: this one is a small table, not a
    // bar, and six rows of two values need the room to stay on one line each.
    //
    // 380 rather than the 340 this carried while it had four rows. The row that
    // forces it is CPU policy, whose two values are the longest here
    // ("35/45 W · turbo on" and "20/30 W · turbo off") and which is the one
    // row whose LABEL was being elided -- measured off a screenshot of a
    // Balanced -> Power saver switch: it read "CPU pol…" because the label
    // column is the only part of a row that can shrink. Nothing was wrong with
    // the values; the table was simply too narrow to name its rows. The
    // display's two rows did not cause that, and are not why this is wider.
    implicitWidth: 380 + 2 * Appearance.sizes.elevationMargin
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
        // ── The card lands, it does not switch on ───────────────────────────
        // A hair of scale and a fade, which is the entrance the copy toast
        // already wears (OnScreenDisplay.qml), so a notice that arrives over
        // whatever is on screen reads as dropped in rather than as a rectangle
        // blinking into existence. The rows do the rest of the work: their own
        // staggered reveal starts just after this lands, so the card arrives
        // and THEN the values move, in that order.
        opacity: 0
        scale: 0.98
        Component.onCompleted: {
            opacity = 1;
            scale = 1;
        }
        Behavior on opacity {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
        }
        Behavior on scale {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
        }
        implicitWidth: 380
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

            // The model is the row COUNT, not the rows themselves. `root.rows`
            // is rebuilt every time a measurement lands -- every 900 ms while
            // the card is up -- and a JS array is not diffable, so handing the
            // Repeater a new one RECREATES every delegate. That is not a
            // micro-optimisation: a recreated delegate starts its reveal over,
            // so the first version of this card swooshed, settled, and swooshed
            // again for the whole five seconds it was on screen. A frame strip
            // taken across a switch showed values moving backwards and forwards
            // between frames, which is impossible for one animation and is what
            // gave the replay away.
            //
            // A fixed count keeps the six delegates for the card's whole life,
            // so their bindings re-evaluate in place (which is all a new read
            // needs), and the per-row state below -- how far each row has
            // revealed, and whether it has already played for this switch --
            // survives the read that follows it.
            Repeater {
                model: root.rows.length

                delegate: RowLayout {
                    id: row
                    required property int index
                    // This row's two values, re-read in place.
                    readonly property var rowData: root.rows[index] ?? {}
                    // `before` is the value this row held a moment ago; it is
                    // joined to the new one by an arrow rather than described,
                    // so the eye finds the rows that MOVED without reading any
                    // of them.
                    readonly property bool moved: rowData.before !== ""
                        && rowData.before !== rowData.after

                    // A row may only REVEAL once its after column holds a real
                    // reading. `moved` alone cannot say that: while the after
                    // column still carries "—" it is true for every row ("—" is
                    // not the value the machine had), so the reveal used to fire
                    // against the placeholder -- a 38 px slide for a 10.75 px
                    // "—" -- and, having spent the row's one reveal, left the real
                    // answer to appear with no animation at all. The teleport.
                    //
                    // So the two are separate on purpose. `moved` is what the row
                    // SHOWS (and the layout it reserves: the old value, the arrow,
                    // the new one). `comparable` is what it may ANIMATE, and the
                    // row keeps its one reveal until this is true.
                    readonly property bool comparable: row.moved
                        && (!rowData.measured || root.now !== null)

                    // Both values, as one string: the identity of the comparison
                    // this row is currently showing. The latch below is keyed on
                    // it rather than on the switch, because a switch alone does
                    // not say WHICH comparison a read has produced -- the same
                    // switch produces up to three (placeholder, unconverged,
                    // settled) and only the last is the answer.
                    readonly property string pairKey:
                        rowData.before + " | " + rowData.after

                    // ── The reveal: the old value moves out of the way ──────
                    //
                    // WHAT THE EYE GETS, in order, per row:
                    //
                    //   start     the value the machine HAD, drawn where a
                    //             lone value sits -- right-aligned at the
                    //             card's value edge, so the row starts life
                    //             looking like a row with one value;
                    //   end       that value out of the way, with the arrow
                    //             and the value the switch brought beside it.
                    //
                    // So the row reads as one value MOVING aside rather than
                    // as two numbers that were printed next to each other, and
                    // the second value arrives carrying an arrow that names the
                    // direction of the change.
                    //
                    // `swoosh` is the exact distance the old value travels --
                    // the arrow, the new value, and the two gaps between the
                    // three of them -- which is what makes 0 land exactly on
                    // the new value's own right edge.
                    readonly property real swoosh:
                        row.spacing + arrowMark.implicitWidth + row.spacing + afterText.implicitWidth

                    // The two halves are TWO NUMBERS with two animations, not
                    // two fractions of one. That distinction is the whole fix.
                    //
                    // Both are plain properties, not bindings: the animation
                    // drives them, and it drives them in turn -- the value
                    // moves out, and only once it has stopped do the arrow and
                    // the new value arrive. The order is the owner's own words:
                    // the value swooshes left, AND THEN an arrow is made
                    // showing the new value beside it. (A single eased
                    // parameter split at 0.6 was the first version, and a frame
                    // captured mid-flight showed what it costs: the old value
                    // still crossing the space the new one was being faded
                    // into, the two drawn as one smudged line at exactly the
                    // moment the eye is following the movement.)
                    property real travel: 0
                    property real arrive: 0
                    // Whether a reveal this row started is still the current
                    // one. Parking the row (a rewrite of the values that leaves
                    // nothing to compare) stops the animations below, and a
                    // `stopped` out of that must not be read as "the travel
                    // landed" and fade an arrow into a row that is waiting.
                    property bool revealing: false

                    // ── The one distance this reveal is allowed to use ──────
                    //
                    // `swoosh` reads the widths of the arrow and the after value
                    // AS THEY ARE ON SCREEN, and at the instant the data changes
                    // they are not yet the new value's: this delegate's own
                    // `moved`/`pairKey`/`comparable` bindings re-evaluate in the
                    // same pass that queues the text, and they run FIRST -- so a
                    // distance taken then is the PREVIOUS string's width.
                    // Measured, with the distance logged as it was taken: a
                    // row's first reveal read 0 px for that width (both gaps and
                    // nothing between them -- a 14 px creep) and a later one read
                    // the 31.5 px of "60 Hz" while the row was already holding
                    // "240 Hz" (38.2 px).
                    //
                    // Either way the old value started the travel from the wrong
                    // place, and then jumped: `swoosh` is a live binding, so the
                    // moment the text items did take their strings the travelled
                    // distance changed under a value that was already moving --
                    // in one frame, which is exactly the teleport this card was
                    // reported for.
                    //
                    // So the travel does not use the live binding. It is given
                    // the distance ONCE, when the motion actually starts -- after
                    // the staggering pause, by which time the layout has long
                    // since taken the new strings -- and holds it for the whole
                    // travel. The PARKED position still uses the live `swoosh`,
                    // deliberately: while the old value waits at the right edge,
                    // nothing is animating, and the live binding is what keeps it
                    // exactly at that edge as the after value's width settles.
                    property real travelOrigin: 0

                    // THE BUDGET, and why the floor is on the whole reveal
                    // rather than on one blended parameter.
                    //
                    // elementMoveEnter is 400 ms x motionScale. In Performance
                    // mode that is 48 ms, which this card has always refused
                    // outright -- 48 ms is a flick, and a flick no longer says
                    // WHICH of the two values moved, which is this card's whole
                    // product -- so it floored the reveal at 150 ms.
                    //
                    // But 150 ms is a floor for ONE motion. Split across two
                    // sequential ones it is 82 ms of travel and 68 ms of
                    // arrival, and 68 ms is not a reveal, it is a blink: the
                    // arrow is there without being seen to arrive. The floor
                    // therefore belongs to the PAIR -- 320 ms, so each half
                    // keeps the time it needs to be read. The LENGTH is still
                    // the shell's own (elementMoveEnter x motionScale) rather
                    // than a number this card made up; the curves are the
                    // shell's own two, and which half takes which -- and why
                    // they are not both the same one -- is below, at the
                    // animation.
                    readonly property real revealMs:
                        Math.max(320, Appearance.animation.elementMoveEnter.duration)
                    // The travel takes a little more than half: it covers the
                    // wider distance, and the arrival, being a fade, reads
                    // sooner than its share of the clock would suggest.
                    readonly property real travelMs: Math.round(row.revealMs * 0.55)
                    readonly property real arriveMs: Math.max(1, row.revealMs - row.travelMs)

                    // The latch: ONE reveal per row per COMPARISON, held as the
                    // comparison itself. Without a latch any later read that
                    // re-evaluates the row (a refresh coming back with the same
                    // answer, the array behind `root.rows` being rebuilt every
                    // 900 ms) would start it over, and the card would keep
                    // performing itself instead of reporting once. Keyed on the
                    // switch it was too coarse in the other direction: the
                    // placeholder, the unconverged read and the settled one all
                    // arrive under ONE switch, so the first of them took the
                    // latch and the real comparison -- the only one worth
                    // animating -- was refused it and appeared instantly.
                    property string playedPair: ""

                // The one way a reveal starts, and the only way one ends.
                //
                // It PARKS FIRST, unconditionally -- the old value back at the
                // right edge, where a lone value sits, with the staggers and both
                // animations stopped -- and then decides whether to play again.
                // Two reasons, and both are about the reveal being a thing that
                // can be interrupted. The parked position is the reveal's
                // STARTING point, so a row that waits here for a real reading
                // begins its slide from the right place instead of from its slot;
                // and a reveal caught mid-flight is taken back to that start
                // rather than left to speed up from wherever it got to, which is
                // what "the values moved again while it was moving" used to look
                // like (a jump, because the distance under it had changed).
                //
                // `revealing` is dropped FIRST, before the stops below: stopping
                // the travel emits its `stopped`, and that must not be read as
                // "the travel landed" and fade an arrow into a row that is only
                // parking (see `revealing`).
                function playReveal() {
                    row.revealing = false;
                    revealPause.stop();
                    travelAnim.stop();
                    arriveAnim.stop();
                    row.travel = 0;
                    row.arrive = 0;
                    // Not a comparison yet -- the after column is still the "—"
                    // placeholder, so this row has nothing to slide aside for.
                    // Parked, and its latch let go when it stops being a
                    // comparison at all: a row that goes back to one value has no
                    // claim to hold, and a value that arrives later gets its own
                    // turn.
                    if (!row.comparable) {
                        if (!row.moved)
                            row.playedPair = "";
                        return;
                    }
                    // Already played, for exactly these two values.
                    if (row.pairKey === row.playedPair)
                        return;
                    row.playedPair = row.pairKey;
                    row.revealing = true;
                    revealPause.restart();
                }

                    Layout.fillWidth: true
                    spacing: 7

                    // WHEN the cascade starts, and it is measured rather than
                    // guessed. The card lands with an opacity and a scale over
                    // elementMoveFast -- 200 ms at normal motion, 24 ms in
                    // Performance -- and this row started at a FLAT 120 ms, so
                    // in every mode but Performance the values began moving
                    // WHILE the card was still fading in over them. Two motions
                    // over the same pixels at the same time is what reads as
                    // muddy rather than as an order of events, and this file
                    // already states the order it wants: the card lands, and
                    // THEN the values move. So the first row waits for the
                    // landing to finish plus a beat, and the 70 ms per-row
                    // stagger follows it -- still deliberately NOT scaled by
                    // motionScale, because a cascade is this report's own
                    // choreography rather than the interface's response time.
                    readonly property real cardLandMs:
                        Appearance.animation.elementMoveFast.duration + 30
                    //
                    // TWO animations in a sequence, each taking a WHOLE curve
                    // of its own, and that is the difference between an arrow
                    // that is revealed and one that merely turns up.
                    //
                    // BOTH BUGS WERE REAL, and the second one is the reason the
                    // first was hard to see.
                    //
                    //   1. ONE eased parameter split at 0.6 meant the second
                    //      half inherited the TAIL of that curve. elementMoveEnter
                    //      is emphasizedDecel, which covers about 97% of its
                    //      distance in the first tenth of its time -- so the
                    //      arrow and the new value were already 93% in some
                    //      40 ms and then crawled through the remaining 280 ms
                    //      of a motion nothing could see.
                    //
                    //   2. Fixing that into two animations still left the same
                    //      curve underneath, and a frame strip taken across a
                    //      switch proved it: measured at 50 ms intervals, the
                    //      whole reveal fitted between the 126 ms and the 176 ms
                    //      frame. A 320 ms motion that is over in 50 is not slow,
                    //      it is a snap with a hang after it.
                    //
                    // So the curve changes too, and the two halves do NOT take
                    // the same one -- that is the third fix, and the one the
                    // owner still felt after the first two.
                    //
                    // emphasizedDecel is right for an element arriving from
                    // outside the screen -- fast, then settling into place --
                    // and wrong for a value sliding 130 px INSIDE a table, where
                    // the eye is already tracking it.
                    //
                    // The TRAVEL takes animationCurves.standard, the symmetric
                    // one (Material's "standard" bezier): it accelerates,
                    // glides, decelerates. At a third of the way through it has
                    // covered about a third of the distance, so every frame is
                    // a different picture -- which is what smooth means here --
                    // and the value never outruns the eye.
                    //
                    // The ARRIVAL takes standardDecel instead, because a
                    // symmetric curve on a FADE leaves a dead beat: its first
                    // third barely moves, so for some 50 ms after the old value
                    // stops, nothing on the row happens at all and then the
                    // arrow turns up. See the arrival below.
                    //
                    // The LENGTH still comes from the shell (elementMoveEnter,
                    // x motionScale), floored at this card's own minimum. That
                    // floor used to be 150 ms, and 150 ms is a floor for ONE
                    // motion: split across two sequential ones it is 82 ms of
                    // travel and 68 ms of arrival, and 68 ms is a blink -- the
                    // arrow appears without being seen to appear. The floor now
                    // belongs to the PAIR, so each half keeps the time it needs
                    // to be read.
                    // ── The three stages, driven explicitly ────────────────
                    //
                    // A Timer for the stagger, then the travel, then the
                    // arrival -- NOT the SequentialAnimation with three
                    // children this was, and the reason is measured rather than
                    // stylistic: in this Qt build a SequentialAnimation
                    // reports its own `started`/`stopped` and NEVER those of
                    // its children (a three-line test logged the sequence's
                    // own two signals and neither child's), and this reveal
                    // needs both edges of the travel -- the distance is taken
                    // at its start, the arrival is launched at its end. A
                    // handler that never runs is not a sequencing primitive, so
                    // the stages are driven by the two signals that do fire.
                    Timer {
                        id: revealPause
                        repeat: false
                        interval: Math.round(row.cardLandMs + row.index * 70)
                        onTriggered: travelAnim.restart()
                    }
                    // One: the old value out of the way.
                    //
                    // The distance is taken HERE, at the last instant before the
                    // motion -- see travelOrigin. Reading it when the data
                    // changed reads the layout of the previous value, which is
                    // what made this motion a 14 px creep followed by a jump.
                    // (Not `onStarted` on a child of a SequentialAnimation, which
                    // is where this started: see the note above the Timer.)
                    NumberAnimation {
                        id: travelAnim
                        target: row
                        property: "travel"
                        from: 0
                        to: 1
                        duration: row.travelMs
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: Appearance.animationCurves.standard
                        onStarted: row.travelOrigin = row.swoosh
                        // Two, and only for a reveal that is still current (see
                        // `revealing`): parking the row stops this animation,
                        // and that `stopped` must not start the arrival.
                        onStopped: {
                            if (row.revealing)
                                arriveAnim.restart();
                        }
                    }
                    // Two: the arrow and the new value in, starting only
                    // once the first has landed.
                    //
                    // standardDECEL, not the symmetric standard the travel
                    // uses -- and the reason is a dead beat rather than a
                    // curve preference. A symmetric curve spends its first
                    // third barely moving, so on a FADE that third is
                    // invisible: the old value stops, and for some 50 ms
                    // nothing on the row happens at all before the arrow
                    // arrives. That gap is the half of the transition the
                    // owner is still calling not smooth, and it is the
                    // arrival's fault, not the travel's.
                    //
                    // The travel keeps the symmetric curve because it starts
                    // from rest and should look pushed: accelerate, glide,
                    // settle. The arrival starts at once and settles gently
                    // instead, so the arrow begins to appear at the instant
                    // the value has finished moving and the two halves join
                    // up into one gesture.
                    NumberAnimation {
                        id: arriveAnim
                        target: row
                        property: "arrive"
                        from: 0
                        to: 1
                        duration: row.arriveMs
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: Appearance.animationCurves.standardDecel
                        // The reveal is over: the row is no longer "revealing",
                        // so a later stop of the travel (a park, or the next
                        // switch) can no longer be mistaken for this one landing.
                        onStopped: row.revealing = false
                    }

                    // WHEN a row plays. Four routes, and the three ways the values
                    // can arrive are the first three of them (see the header):
                    //
                    //   pairKey      both values moved at once -- `before` and a
                    //                read landing together, or a later read
                    //                replacing the unconverged numbers with the
                    //                settled ones. This is the route the real
                    //                comparison takes, and it is the reason the
                    //                row no longer needs `moved` to be watched:
                    //                a value that changes while the row is
                    //                already a comparison changes the pair too.
                    //   comparable   the last side to arrive was the reading, not
                    //                the value: the row was already comparing
                    //                against "—" and only now has something real
                    //                to slide aside for.
                    //   changeSeq    a new switch while this card is still up
                    //                (the OSD reuses it). The row's reveal belongs
                    //                to the previous comparison, so it lets go of
                    //                its latch and parks before starting the new
                    //                one.
                    //   completed    the card being built with both values already
                    //                in hand.
                    Component.onCompleted: row.playReveal()
                    onPairKeyChanged: row.playReveal()
                    onComparableChanged: row.playReveal()
                    Connections {
                        target: PowerMode
                        function onChangeSeqChanged() {
                            row.playedPair = "";
                            row.playReveal();
                        }
                    }

                    MaterialSymbol {
                        text: rowData.icon
                        iconSize: 15
                        color: Appearance.colors.colSubtext
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: rowData.label
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                        elide: Text.ElideRight
                    }
                    StyledText {
                        id: beforeText
                        visible: row.moved
                        text: rowData.before
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colOnLayer1Inactive
                        // A Translate rather than `x`: the row is a layout and
                        // owns the item's position, so an animated `x` would be
                        // overwritten by the layout on the very next frame.
                        // A render transform moves the pixels and leaves the
                        // layout -- the label's elide, the row's width -- alone.
                        //
                        // Parked (travel 0) the offset is the live distance, so
                        // the old value sits exactly on the right edge; moving,
                        // it is the distance the travel was given (travelOrigin),
                        // so the motion cannot be nudged mid-flight.
                        transform: Translate {
                            x: row.travel > 0
                                ? (1 - row.travel) * row.travelOrigin
                                : row.swoosh
                        }
                    }
                    MaterialSymbol {
                        id: arrowMark
                        visible: row.moved
                        text: "arrow_forward"
                        iconSize: 13
                        color: Appearance.colors.colPrimary
                        opacity: row.arrive
                    }
                    StyledText {
                        id: afterText
                        text: rowData.after
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        font.weight: row.moved ? Font.Medium : Font.Normal
                        color: row.moved ? Appearance.colors.colPrimary
                            : Appearance.colors.colOnLayer0
                        elide: Text.ElideRight
                        // A row that never moved has one value and nothing to
                        // reveal: it is simply there, at full strength.
                        opacity: row.moved ? row.arrive : 1
                        transform: Translate { x: (1 - row.arrive) * 8 }
                    }
                }
            }
        }
    }
}
