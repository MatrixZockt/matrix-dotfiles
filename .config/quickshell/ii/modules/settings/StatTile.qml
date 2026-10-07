import QtQuick
import QtQuick.Layouts
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

/**
 * One reading, as a tile.
 *
 * Built for the dashboard's job: show a number, a shape and an icon, and almost
 * no prose. A tile says "CPU 37%" and draws the last minute of it; a sentence
 * saying "your processor is currently 37% busy, which is normal" does not fit on
 * a dashboard and is not what you look at it for.
 *
 * Three things are optional and independent:
 *   * `history`  -- drawn as a sparkline along the bottom of the tile
 *   * `progress` -- a value from 0 to 1; -1 hides the level bar
 *   * `caption`  -- the one line of small text, for units or a secondary number
 *
 * The corner radius is deliberately the small token: a settings window full of
 * very round cards reads as a phone app, and these are dense information tiles.
 */
Rectangle {
    id: root

    property string icon: "insights"
    property string label: ""
    property string value: "--"
    property string caption: ""
    property var history: []
    property real progress: -1
    property color accent: Appearance.colors.colPrimary
    property bool interactive: false
    signal clicked()

    // The level bar needs the extra 10px; tiles without one keep the dense
    // height they had.
    implicitHeight: root.progress >= 0 ? 106 : 96
    radius: Appearance.rounding.small
    color: tileMouse.containsMouse && root.interactive
        ? Appearance.colors.colLayer1Hover
        : Appearance.colors.colLayer1
    border.width: 1
    border.color: Appearance.colors.colOutlineVariant

    Behavior on color {
        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
    }

    MouseArea {
        id: tileMouse
        anchors.fill: parent
        hoverEnabled: root.interactive
        enabled: root.interactive
        cursorShape: root.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.clicked()
    }

    // Sparkline, behind the content and clipped to the tile's own rounding.
    Graph {
        visible: root.history && root.history.length > 1
        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
            margins: 1
        }
        height: 34
        values: root.history ?? []
        points: ResourceUsage.historyLength
        color: root.accent
        fillOpacity: 0.35
    }

    RowLayout {
        anchors {
            fill: parent
            margins: 12
            bottomMargin: root.history && root.history.length > 1 ? 30 : 12
        }
        spacing: 10

        // Icon in a soft square, the only decoration the tile has.
        Rectangle {
            Layout.alignment: Qt.AlignTop
            implicitWidth: 34
            implicitHeight: 34
            radius: Appearance.rounding.verysmall
            color: ColorUtils.transparentize(root.accent, 0.82)

            MaterialSymbol {
                anchors.centerIn: parent
                text: root.icon
                iconSize: 20
                color: root.accent
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            spacing: 0

            StyledText {
                Layout.fillWidth: true
                text: root.label.toUpperCase()
                color: Appearance.colors.colOnLayer1Inactive
                font.pixelSize: Appearance.font.pixelSize.smaller
                font.weight: Font.Medium
                elide: Text.ElideRight
            }

            StyledText {
                Layout.fillWidth: true
                text: root.value
                color: Appearance.colors.colOnLayer1
                font.pixelSize: Appearance.font.pixelSize.huge
                font.weight: Font.Medium
                elide: Text.ElideRight
            }

            StyledText {
                Layout.fillWidth: true
                visible: root.caption.length > 0
                text: root.caption
                color: Appearance.colors.colOnLayer1Inactive
                font.pixelSize: Appearance.font.pixelSize.smaller
                elide: Text.ElideRight
            }

            // Optional level bar, directly under the number it belongs to.
            //
            // A ring was here. A ring means "a fraction of a whole, going
            // round", which is fine for a countdown and nonsense for things that
            // are not circular: Wi-Fi signal strength as a ring was the clearest
            // example -- there is no whole to be a fraction OF. A bar under the
            // value reads as "this much of something" for a charge, a volume and
            // a signal alike, and it sits in the same column as the number, so
            // the eye gets value and level in one place instead of two corners.
            Item {
                Layout.fillWidth: true
                Layout.topMargin: 5
                Layout.preferredHeight: 4
                visible: root.progress >= 0

                Rectangle {
                    anchors.fill: parent
                    radius: height / 2
                    color: ColorUtils.transparentize(root.accent, 0.80)
                }

                Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    radius: height / 2
                    width: parent.width * Math.max(0, Math.min(root.progress, 1))
                    color: root.accent
                    Behavior on width {
                        animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                    }
                }
            }
        }
    }
}
