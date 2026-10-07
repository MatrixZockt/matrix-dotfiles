import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.services

/**
 * One reading from the machine, drawn as an instrument.
 *
 * It exists because the performance view used to be a cluster of coloured
 * circles whose *diameter* was the number: the size told you how busy something
 * was but nothing said which thing it was, so the colour was the only key and
 * two readings were impossible to compare by eye. An instrument answers all
 * three questions in the same glance -- what it is (an icon), how much (a
 * number and a level bar), and which way it has been going (a sparkline of the
 * last minute).
 *
 * The same instrument has two sizes, and they are the same numbers:
 *   * `compact` -- the island in the bar: icon and value on one line, the
 *     sparkline under it. No label: there is no room for one, and the icon is
 *     the label.
 *   * the full tile -- the popped-out card: a soft icon square, the label
 *     spelled out, the value large, a caption saying what the number is a
 *     fraction *of*, a level bar, and a chart with room to read.
 *
 * `load` is 0-1, or -1 for "this machine does not report it" (no thermal
 * sensor, no graphics clock): the icon and the bar then go quiet instead of
 * pretending the reading is zero, and the value text is whatever the caller
 * passed (typically "--").
 */
Item {
    id: root

    property string icon: "insights"
    property string label: ""
    property string value: "--"
    property string caption: ""
    property real load: -1
    property var history: []
    property color accent: Appearance.colors.colPrimary
    property bool compact: false
    // `dense` is the middle size: the same instrument as the full tile, with
    // the chart dropped and the type stepped down, so four of them fit on one
    // row. It exists because "a chart you cannot read" and "no chart" are
    // not the same trade: at four across, a 38%-height sparkline under a
    // 168px-wide tile is texture, not information -- and the space it eats is
    // worth more to the things underneath it. The charts are not lost: the
    // island keeps its sparklines and the overlay's Performance view keeps
    // the full-size tiles.
    property bool dense: false

    readonly property bool known: root.load >= 0
    // The level is clamped here, once, so every drawing below reads the same
    // number and no consumer has to remember to clamp.
    readonly property real level: root.known ? Math.max(0, Math.min(1, root.load)) : 0
    readonly property bool hasHistory: (root.history?.length ?? 0) > 1

    // The compact instrument is a fixed width rather than a measured one: the
    // four of them sit in a row in the island, and a row that re-measures every
    // time a digit changes would shuffle the whole cluster sideways. 4 × 74 plus
    // the gaps fills the island's stage almost exactly.
    implicitWidth: root.compact ? 74 : 168
    implicitHeight: root.compact ? 22 : (root.dense ? 84 : 132)

    // ── Compact: the island's instrument ─────────────────────────────────
    // Icon and value, and nothing else. The chart belongs to the carded view:
    // in the island a sparkline is thirteen pixels of faint line per reading,
    // and four of them inside one capsule stop being charts and become
    // texture -- four competing squiggles saying less than the numbers they
    // sit under. The number IS the reading; the icon says what of; the graphs
    // are where there is room to read them (see the pop-out's tiles).
    RowLayout {
        id: compactRow
        visible: root.compact
        anchors.centerIn: parent
        spacing: 5

        MaterialSymbol {
            Layout.alignment: Qt.AlignVCenter
            text: root.icon
            iconSize: Appearance.font.pixelSize.smallie
            color: root.known ? root.accent : Appearance.colors.colOnLayer1Inactive
        }
        StyledText {
            Layout.alignment: Qt.AlignVCenter
            text: root.value
            color: Appearance.colors.colOnLayer0
            font.pixelSize: Appearance.font.pixelSize.smaller
            font.weight: Font.Medium
        }
    }

    // ── Full: the card's tile ────────────────────────────────────────────
    Rectangle {
        id: tile
        visible: !root.compact
        anchors.fill: parent
        radius: Appearance.rounding.small
        color: Appearance.colors.colLayer1
        border.width: 1
        border.color: Appearance.colors.colOutlineVariant

        // The chart takes the bottom of the tile, which is what gives the
        // carded view its "this is a dashboard, not a list of numbers" read.
        Graph {
            id: tileGraph
            visible: root.hasHistory
            anchors {
                left: parent.left
                right: parent.right
                bottom: parent.bottom
                margins: 1
            }
            height: Math.round(parent.height * (root.dense ? 0.3 : 0.38))
            values: root.history ?? []
            points: ResourceUsage.historyLength
            alignment: Graph.Alignment.Right
            color: root.accent
            fillOpacity: 0.24
        }

        RowLayout {
            anchors {
                fill: parent
                margins: 12
                // Only reserve the chart's band when there IS a chart. The
                // graph keeps its height whether or not it is visible, so
                // adding its height unconditionally left every chartless tile
                // with a dead strip under the text.
                bottomMargin: 12 + (root.hasHistory ? tileGraph.height : 0)
            }
            spacing: 10

            // The icon in a soft square: the only decoration the tile has, and
            // the thing that makes four tiles scannable at a distance.
            // Both halves of the block are centred in the space above the
            // chart: top-aligning them left the tiles with a dead band between
            // the number and the graph, which read as a half-empty card.
            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: root.dense ? 28 : 34
                implicitHeight: root.dense ? 28 : 34
                radius: Appearance.rounding.verysmall
                color: ColorUtils.transparentize(root.accent, 0.82)

                MaterialSymbol {
                    anchors.centerIn: parent
                    text: root.icon
                    iconSize: root.dense ? 17 : 20
                    color: root.known ? root.accent : Appearance.colors.colOnLayer1Inactive
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 0

                StyledText {
                    Layout.fillWidth: true
                    text: root.label.toUpperCase()
                    color: Appearance.colors.colOnLayer1Inactive
                    font.pixelSize: root.dense
                        ? Appearance.font.pixelSize.smallest
                        : Appearance.font.pixelSize.smaller
                    font.weight: Font.Medium
                    elide: Text.ElideRight
                }

                StyledText {
                    Layout.fillWidth: true
                    text: root.value
                    color: Appearance.colors.colOnLayer1
                    font.pixelSize: root.dense
                        ? Appearance.font.pixelSize.large
                        : Appearance.font.pixelSize.huge
                    font.weight: Font.Medium
                    elide: Text.ElideRight
                }

                StyledText {
                    Layout.fillWidth: true
                    visible: root.caption.length > 0
                    text: root.caption
                    color: Appearance.colors.colOnLayer1Inactive
                    font.pixelSize: root.dense
                        ? Appearance.font.pixelSize.smallest
                        : Appearance.font.pixelSize.smaller
                    elide: Text.ElideRight
                }

                // The level, under the number it belongs to: "this much of
                // something", which is exactly what a reading is. Hollow (track
                // only) when the machine has nothing to report.
                Item {
                    Layout.fillWidth: true
                    Layout.topMargin: 5
                    Layout.preferredHeight: 4

                    Rectangle {
                        anchors.fill: parent
                        radius: height / 2
                        color: ColorUtils.transparentize(root.accent, 0.80)
                    }

                    Rectangle {
                        anchors {
                            left: parent.left
                            top: parent.top
                            bottom: parent.bottom
                        }
                        width: parent.width * root.level
                        radius: height / 2
                        color: root.accent
                        Behavior on width {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }
                    }
                }
            }
        }
    }
}
