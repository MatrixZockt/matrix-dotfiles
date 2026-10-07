pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * The Trading tab, as the popped-out card shows it.
 *
 * Two bands, and the split is deliberate:
 *
 *   * the CHART gets a fixed height at the top. It is the thing that
 *     changes second to second, so it must not shove the list under it
 *     around while it ticks.
 *   * the NEWS fills every remaining pixel and SCROLLS. There are more
 *     red-folder events in a day than fit in a 460px card, and the answer
 *     to "too many" is a scroll, never a taller card -- the card's size is
 *     fixed by NowBarPanel and grows for nobody.
 *
 * Each news row is a small card that EXPANDS in place to show the detail.
 * Only the card's own height animates; the detail block is always laid out
 * at full size and simply clipped, so the reveal is one smooth number
 * instead of two animations trying to stay in step.
 */
Item {
    id: root

    // Set by the view in NowBarPanel. Only a claimed service ticks, so a
    // hidden tab costs nothing.
    property bool active: false

    onActiveChanged: root.syncClaim()
    Component.onCompleted: root.syncClaim()
    Component.onDestruction: TradingService.release(root)

    function syncClaim() {
        if (root.active)
            TradingService.claim(root);
        else
            TradingService.release(root);
    }

    // Market semantics, kept out of the theme on purpose: these four mean
    // the same thing on every terminal in the world.
    readonly property color highColor: "#E5484D"
    readonly property color mediumColor: "#E6A23C"
    readonly property color lowColor: "#D4C04A"
    readonly property color upColor: "#46A758"
    readonly property color downColor: "#E5484D"

    // The chart band. 210 of the ~384px the card has for content leaves the
    // list about three rows before it scrolls, which is the intent.
    readonly property real chartBandHeight: 210

    ColumnLayout {
        anchors.fill: parent
        spacing: 10

        // ── The chart ──────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: root.chartBandHeight
            radius: Appearance.rounding.normal
            color: Appearance.colors.colLayer1

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 6

                // Symbol switcher, then the timeframes it is read on.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 5

                    Repeater {
                        model: TradingService.instruments

                        Rectangle {
                            id: symChip
                            required property var modelData
                            readonly property bool active: TradingService.symbol === symChip.modelData.sym
                            Layout.alignment: Qt.AlignVCenter
                            implicitWidth: symLabel.implicitWidth + 18
                            implicitHeight: 25
                            radius: Appearance.rounding.small
                            color: symChip.active
                                ? Appearance.colors.colPrimary
                                : symChip.hovered ? Appearance.colors.colLayer2Hover : Appearance.colors.colLayer2
                            property bool hovered: false

                            HoverHandler {
                                cursorShape: Qt.PointingHandCursor
                                onHoveredChanged: symChip.hovered = hovered
                            }
                            TapHandler { onTapped: TradingService.selectSymbol(symChip.modelData.sym) }
                            Behavior on color {
                                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                            }

                            Text {
                                id: symLabel
                                anchors.centerIn: parent
                                text: symChip.modelData.sym
                                font.family: Appearance.font.family.monospace
                                font.pixelSize: Appearance.font.pixelSize.tiny
                                font.weight: Font.DemiBold
                                color: symChip.active ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer1
                            }
                        }
                    }

                    Item { Layout.fillWidth: true }

                    // Timeframes are CONTROLS. The series is one
                    // 15-minute walk and each button rolls it up to its own
                    // granularity (4 / 16 / 96 source bars), so pressing one
                    // re-publishes the SAME candles at that size instead of
                    // drawing a different walk -- switch and switch back and
                    // the chart is where you left it.
                    Row {
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 2
                        Repeater {
                            model: TradingService.timeframes
                            delegate: Rectangle {
                                id: tfChip
                                required property var modelData
                                readonly property bool active: TradingService.timeframe === tfChip.modelData.tf
                                property bool hovered: false
                                implicitWidth: tfLabel.implicitWidth + 12
                                implicitHeight: 22
                                radius: Appearance.rounding.verylarge
                                color: tfChip.active
                                    ? Appearance.colors.colLayer2
                                    : tfChip.hovered ? Appearance.colors.colLayer2Hover : "transparent"
                                HoverHandler {
                                    cursorShape: Qt.PointingHandCursor
                                    onHoveredChanged: tfChip.hovered = hovered
                                }
                                TapHandler { onTapped: TradingService.selectTimeframe(tfChip.modelData.tf) }
                                Text {
                                    id: tfLabel
                                    anchors.centerIn: parent
                                    text: tfChip.modelData.tf
                                    font.family: Appearance.font.family.monospace
                                    font.pixelSize: Appearance.font.pixelSize.tiny
                                    color: tfChip.active
                                        ? Appearance.colors.colOnLayer1
                                        : ColorUtils.transparentize(Appearance.colors.colOnLayer1, tfChip.hovered ? 0.3 : 0.55)
                                }
                                Behavior on color {
                                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                                }
                            }
                        }
                    }
                }

                // The quote itself.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        text: TradingService.formatPrice(TradingService.price)
                        font.family: Appearance.font.family.monospace
                        font.pixelSize: Appearance.font.pixelSize.huge
                        color: Appearance.colors.colOnLayer0
                    }
                    Text {
                        Layout.alignment: Qt.AlignBottom
                        text: (TradingService.up ? "▲ " : "▼ ")
                            + TradingService.formatSigned(TradingService.change)
                            + "  (" + (TradingService.up ? "+" : "−")
                            + Math.abs(TradingService.changePct).toFixed(2) + "%)"
                        font.family: Appearance.font.family.monospace
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: TradingService.up ? root.upColor : root.downColor
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        Layout.alignment: Qt.AlignVCenter
                        text: "live"
                        font.pixelSize: Appearance.font.pixelSize.tiny
                        color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.5)
                    }
                }

                CandleChart {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    candles: TradingService.candles
                    rev: TradingService.rev
                    decimals: TradingService.decimals
                }
            }
        }

        // ── News header ────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 2
            spacing: 7

            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: 9
                implicitHeight: 9
                radius: 2
                color: root.highColor
            }
            StyledText {
                Layout.alignment: Qt.AlignVCenter
                text: Translation.tr("Red folder · today")
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colOnLayer0
            }
            Item { Layout.fillWidth: true }
            StyledText {
                Layout.alignment: Qt.AlignVCenter
                // The count is the FILTERED list's length -- red folder and
                // today -- so it can never advertise more than the list
                // holds, and a list whose last refresh failed is labelled
                // stale rather than presented as current.
                text: TradingService.events.length + " " + Translation.tr("events")
                    + (TradingService.feedState === "error" && TradingService.events.length > 0
                        ? " · " + Translation.tr("stale") : "")
                font.family: Appearance.font.family.monospace
                font.pixelSize: Appearance.font.pixelSize.tiny
                color: ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.5)
            }
        }

        // ── The list: scrolls when there are more than fit ─────────────
        StyledFlickable {
            id: newsScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: width
            contentHeight: newsColumn.implicitHeight
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: newsColumn
                width: newsScroll.width
                spacing: 6

                // Nothing to show, and the reason differs: the feed answered
                // and today really is quiet, the answer is still coming, or
                // the feed could not be reached at all. Each gets its own
                // words -- the tab never fills a gap with sample rows, so an
                // empty calendar here is a fact and not a failure to load.
                StyledText {
                    visible: TradingService.events.length === 0
                    width: newsColumn.width
                    text: TradingService.feedState === "ok"
                        ? Translation.tr("No red-folder events on the calendar for today.")
                        : TradingService.feedState === "error"
                            ? Translation.tr("Calendar feed unreachable — nothing is shown rather than guessed.")
                            : Translation.tr("Fetching today's red-folder events…")
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.35)
                    wrapMode: Text.WordWrap
                }

                Repeater {
                    model: TradingService.events

                    Rectangle {
                        id: eventCard
                        required property var modelData
                        readonly property var ev: eventCard.modelData
                        // What the row SAYS, read from the clock-driven map
                        // in the service rather than baked into the event.
                        // The old list carried a decided-at-authoring-time
                        // state -- including one event that was permanently
                        // "live" -- which is how this card could disagree with
                        // the clock in the bar above it.
                        readonly property var st: TradingService.eventStates[eventCard.ev.id] ?? { state: "released", countdown: null }
                        readonly property bool high: eventCard.ev.min === "high"
                        readonly property color railColor: eventCard.high
                            ? root.highColor
                            : (eventCard.ev.min === "medium" ? root.mediumColor : root.lowColor)
                        readonly property bool printed: eventCard.ev.actual !== "—" && eventCard.ev.actual !== undefined
                        // The release IMMEDIATELY BEFORE this one in the
                        // list. Only the second card of the day has one, so
                        // the comparison in the detail block exists only
                        // where there is something to compare against.
                        readonly property bool hasCmp: eventCard.ev.cmp !== null && eventCard.ev.cmp !== undefined
                        // Failsafe for a release that publishes NOTHING:
                        // no forecast, no actual, no previous. Three empty
                        // cells would read like the data is merely out of
                        // view; one sentence says it does not exist for
                        // this one -- a speech prints no figures at all,
                        // and with no actual there is no up/down
                        // comparison to draw either.
                        readonly property bool noFigures: (eventCard.ev.actual ?? "—") === "—"
                            && (eventCard.ev.forecast ?? "—") === "—"
                            && (eventCard.ev.previous ?? "—") === "—"
                        property bool expanded: false
                        property bool hovered: false

                        width: newsColumn.width
                        // 40 collapsed (the header row) + 78 of detail. The
                        // detail is laid out either way and clipped when shut.
                        implicitHeight: eventCard.expanded ? 118 : 40
                        clip: true
                        radius: Appearance.rounding.normal
                        color: eventCard.hovered
                            ? Appearance.colors.colLayer1Hover
                            : Appearance.colors.colLayer1
                        Behavior on implicitHeight {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }
                        Behavior on color {
                            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                        }

                        HoverHandler {
                            cursorShape: Qt.PointingHandCursor
                            onHoveredChanged: eventCard.hovered = hovered
                        }
                        TapHandler { onTapped: eventCard.expanded = !eventCard.expanded }

                        ColumnLayout {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            spacing: 0

                            // ── Header row: always visible ─────────────
                            RowLayout {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 40
                                Layout.leftMargin: 12
                                Layout.rightMargin: 10
                                spacing: 10

                                Rectangle {
                                    Layout.alignment: Qt.AlignVCenter
                                    implicitWidth: 3
                                    implicitHeight: 18
                                    radius: 2
                                    color: eventCard.railColor
                                }
                                Text {
                                    Layout.alignment: Qt.AlignVCenter
                                    Layout.preferredWidth: 34
                                    text: eventCard.ev.time
                                    font.family: Appearance.font.family.monospace
                                    font.pixelSize: Appearance.font.pixelSize.tiny
                                    color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.35)
                                }
                                Rectangle {
                                    Layout.alignment: Qt.AlignVCenter
                                    implicitWidth: curLabel.implicitWidth + 10
                                    implicitHeight: 18
                                    radius: Appearance.rounding.verysmall
                                    color: Appearance.colors.colLayer2
                                    Text {
                                        id: curLabel
                                        anchors.centerIn: parent
                                        text: eventCard.ev.currency
                                        font.family: Appearance.font.family.monospace
                                        font.pixelSize: Appearance.font.pixelSize.tiny
                                        font.weight: Font.DemiBold
                                        color: Appearance.colors.colOnLayer2
                                    }
                                }
                                StyledText {
                                    Layout.fillWidth: true
                                    Layout.alignment: Qt.AlignVCenter
                                    text: eventCard.ev.name
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                    color: Appearance.colors.colOnLayer1
                                    elide: Text.ElideRight
                                }

                                // Right cell: the printed set when there is
                                // one, otherwise what the event is waiting
                                // for. A row that has printed and a row that
                                // has not are the two states worth telling
                                // apart at a glance.
                                Row {
                                    Layout.alignment: Qt.AlignVCenter
                                    spacing: 8
                                    visible: eventCard.printed

                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: eventCard.ev.actual
                                        font.family: Appearance.font.family.monospace
                                        font.pixelSize: Appearance.font.pixelSize.tiny
                                        font.weight: Font.DemiBold
                                        color: eventCard.ev.tone === "down" ? root.downColor
                                            : eventCard.ev.tone === "up" ? root.upColor
                                            : Appearance.colors.colOnLayer1
                                    }
                                    // The read on that number: actual against
                                    // the PREVIOUS figure for the same
                                    // indicator. Higher is ▲, lower is ▼, and
                                    // a tie or a figure that never printed
                                    // draws nothing at all -- the service
                                    // hands over "" exactly when there is no
                                    // comparison to make.
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: (eventCard.ev.bias ?? "") !== ""
                                        text: eventCard.ev.bias === "up" ? "▲" : "▼"
                                        font.pixelSize: Appearance.font.pixelSize.tiny
                                        color: eventCard.ev.bias === "up" ? root.upColor : root.downColor
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "fc " + eventCard.ev.forecast
                                        font.family: Appearance.font.family.monospace
                                        font.pixelSize: Appearance.font.pixelSize.tiny
                                        color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.4)
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "prev " + eventCard.ev.previous
                                        font.family: Appearance.font.family.monospace
                                        font.pixelSize: Appearance.font.pixelSize.tiny
                                        color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.4)
                                    }
                                }

                                Rectangle {
                                    Layout.alignment: Qt.AlignVCenter
                                    visible: !eventCard.printed
                                    implicitWidth: stateLabel.implicitWidth + 14
                                    implicitHeight: 20
                                    radius: Appearance.rounding.verysmall
                                    color: eventCard.st.state === "live"
                                        ? ColorUtils.transparentize(root.highColor, 0.82)
                                        : Appearance.colors.colLayer2
                                    Text {
                                        id: stateLabel
                                        anchors.centerIn: parent
                                        text: eventCard.st.state === "live"
                                            ? Translation.tr("live")
                                            : (eventCard.st.countdown ?? Translation.tr("released"))
                                        font.family: Appearance.font.family.monospace
                                        font.pixelSize: Appearance.font.pixelSize.tiny
                                        color: eventCard.st.state === "live"
                                            ? root.highColor
                                            : ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.35)
                                    }
                                }

                                MaterialSymbol {
                                    Layout.alignment: Qt.AlignVCenter
                                    text: eventCard.expanded ? "expand_less" : "expand_more"
                                    iconSize: 17
                                    color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.45)
                                }
                            }

                            // ── Detail: laid out always, revealed by the
                            //    card's own height ─────────────────────
                            Item {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 78
                                clip: true

                                ColumnLayout {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    anchors.leftMargin: 25
                                    anchors.rightMargin: 12
                                    spacing: 8

                                    StyledText {
                                        Layout.fillWidth: true
                                        text: eventCard.ev.detail
                                        font.pixelSize: Appearance.font.pixelSize.tiny
                                        color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.25)
                                        wrapMode: Text.WordWrap
                                    }
                                    // The failsafe line. It sits in the SAME
                                    // slot the figures row would occupy, so a
                                    // card with no data costs no extra height
                                    // -- and instead of three empty cells it
                                    // says plainly that there is no figure and
                                    // no up/down comparison to read.
                                    StyledText {
                                        visible: eventCard.noFigures
                                        Layout.fillWidth: true
                                        text: Translation.tr("Data not shown in calendar — no actual or up/down comparison.")
                                        font.pixelSize: Appearance.font.pixelSize.tiny
                                        color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.35)
                                        wrapMode: Text.WordWrap
                                    }
                                    RowLayout {
                                        // objectName, because the probe below
                                        // asks THIS row whether it fits and a
                                        // delegate's `id` is not reachable from
                                        // the file's root.
                                        objectName: "detailRow"
                                        visible: !eventCard.noFigures
                                        Layout.fillWidth: true
                                        spacing: 14
                                        Repeater {
                                            // The order the eye reads it in:
                                            // the number that JUST LANDED
                                            // first, what was expected second,
                                            // what came before it third --
                                            // actual against previous is the
                                            // comparison that matters, so the
                                            // arrow sits beside the actual.
                                            model: [
                                                { k: Translation.tr("actual"), v: eventCard.ev.actual, dir: true },
                                                { k: Translation.tr("forecast"), v: eventCard.ev.forecast },
                                                { k: Translation.tr("previous"), v: eventCard.ev.previous }
                                            ]
                                            delegate: RowLayout {
                                                required property var modelData
                                                spacing: 5
                                                Text {
                                                    text: parent.modelData.k
                                                    font.pixelSize: Appearance.font.pixelSize.tiny
                                                    color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.45)
                                                }
                                                Text {
                                                    text: parent.modelData.v
                                                    font.family: Appearance.font.family.monospace
                                                    font.pixelSize: Appearance.font.pixelSize.tiny
                                                    color: Appearance.colors.colOnLayer1
                                                }
                                                // ▲ / ▼, only on the actual,
                                                // only where actual and
                                                // previous are both numbers
                                                // and differ -- see
                                                // TradingService._bias().
                                                Text {
                                                    visible: parent.modelData.dir === true
                                                        && (eventCard.ev.bias ?? "") !== ""
                                                    text: eventCard.ev.bias === "up" ? "▲" : "▼"
                                                    font.pixelSize: Appearance.font.pixelSize.tiny
                                                    color: eventCard.ev.bias === "up" ? root.upColor : root.downColor
                                                }
                                            }
                                        }

                                        // ── The release BEFORE this one ──
                                        // The SAME row, deliberately: the whole
                                        // reason to expand a card is to compare
                                        // two numbers, and a number you have to
                                        // scroll back up to recall is not a
                                        // comparison. It appears only when an
                                        // earlier release exists today -- the
                                        // day's first card has nothing to be
                                        // measured against -- and the filler
                                        // below gives this row whatever width
                                        // is left, so both sides stay on one
                                        // line instead of wrapping.
                                        Rectangle {
                                            visible: eventCard.hasCmp
                                            Layout.alignment: Qt.AlignVCenter
                                            implicitWidth: 1
                                            implicitHeight: 12
                                            color: ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.55)
                                        }
                                        Text {
                                            visible: eventCard.hasCmp
                                            Layout.alignment: Qt.AlignVCenter
                                            text: eventCard.hasCmp ? "‹ " + eventCard.ev.cmp.time : ""
                                            font.family: Appearance.font.family.monospace
                                            font.pixelSize: Appearance.font.pixelSize.tiny
                                            color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.45)
                                        }
                                        Repeater {
                                            model: eventCard.hasCmp ? [
                                                { k: Translation.tr("forecast"), v: eventCard.ev.cmp.forecast },
                                                { k: Translation.tr("actual"), v: eventCard.ev.cmp.actual }
                                            ] : []
                                            delegate: RowLayout {
                                                required property var modelData
                                                spacing: 5
                                                Text {
                                                    text: parent.modelData.k
                                                    font.pixelSize: Appearance.font.pixelSize.tiny
                                                    color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.45)
                                                }
                                                Text {
                                                    text: parent.modelData.v
                                                    font.family: Appearance.font.family.monospace
                                                    font.pixelSize: Appearance.font.pixelSize.tiny
                                                    color: Appearance.colors.colOnLayer1
                                                }
                                            }
                                        }
                                        Item { Layout.fillWidth: true }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ── IPC: `qs -c ii ipc call tradingTab detail` ───────────────────────
    // "Does it all fit on one row?" asked of the LAYOUT rather than guessed
    // from the source: the detail row reports the width it HAS against the
    // width it actually WANTS, summed from the children it is holding, so
    // the answer is arithmetic instead of an opinion. The row is found by
    // objectName because an id inside a delegate is not reachable from here.
    IpcHandler {
        target: "tradingTab"
        function detail(): string {
            const rows = [];
            const walk = item => {
                if (!item)
                    return;
                if (item.objectName === "detailRow") {
                    rows.push(item);
                    return;
                }
                const kids = item.children ?? [];
                for (let i = 0; i < kids.length; i++)
                    walk(kids[i]);
            };
            walk(root);
            if (rows.length === 0)
                return "no detail row on screen";
            const fmt = row => {
                const parts = row.children
                    .filter(c => c.visible && c.implicitWidth > 0)
                    .map(c => Math.round(c.implicitWidth)).join(" + ");
                return `have=${Math.round(row.width)} need=${Math.round(row.implicitWidth)}`
                    + ` [${parts}] -> `
                    + (row.implicitWidth <= row.width
                        ? "FITS on one row" : "OVERFLOWS the row");
            };
            // Every card lays one out, and only the ones carrying a
            // comparison are the interesting ones -- so the WIDEST row is
            // reported, plus how many overflow at all.
            const widest = rows.reduce((a, b) =>
                a.implicitWidth >= b.implicitWidth ? a : b);
            const over = rows.filter(r => r.implicitWidth > r.width).length;
            return `${rows.length} card(s); widest -> ${fmt(widest)}`
                + ` | overflowing: ${over}`;
        }
    }
}
