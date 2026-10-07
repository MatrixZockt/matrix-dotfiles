import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts
import Quickshell.Widgets

Item {
    id: root
    required property real value
    required property string icon
    required property string name
    property bool rotateIcon: false
    property bool scaleIcon: false
    // How much the value moved with the last step (signed). When it is not
    // zero the readout says WHICH WAY it went -- an arrow and the size of the
    // step next to the percentage -- because "Volume 42" alone did not tell
    // you whether you had just turned it up or down.
    property real delta: 0
    property alias from: valueProgressBar.from
    property alias to: valueProgressBar.to

    property real valueIndicatorVerticalPadding: 9
    property real valueIndicatorLeftPadding: 10
    property real valueIndicatorRightPadding: 20 // An icon is circle ish, a column isn't, hence the extra padding

    implicitWidth: Appearance.sizes.osdWidth + 2 * Appearance.sizes.elevationMargin
    implicitHeight: valueIndicator.implicitHeight + 2 * Appearance.sizes.elevationMargin

    StyledRectangularShadow {
        target: valueIndicator
    }
    Rectangle {
        id: valueIndicator
        anchors {
            fill: parent
            margins: Appearance.sizes.elevationMargin
        }
        radius: Appearance.rounding.full
        color: Appearance.colors.colLayer0

        implicitWidth: valueRow.implicitWidth
        implicitHeight: valueRow.implicitHeight

        RowLayout { // Icon on the left, stuff on the right
            id: valueRow
            Layout.margins: 10
            anchors.fill: parent
            spacing: 10

            Item {
                implicitWidth: 30
                implicitHeight: 30
                Layout.alignment: Qt.AlignVCenter
                Layout.leftMargin: valueIndicatorLeftPadding
                Layout.topMargin: valueIndicatorVerticalPadding
                Layout.bottomMargin: valueIndicatorVerticalPadding

                MaterialSymbol { // Icon
                    anchors {
                        centerIn: parent
                        alignWhenCentered: !root.rotateIcon
                    }
                    color: Appearance.colors.colOnLayer0
                    renderType: Text.QtRendering

                    text: root.icon
                    iconSize: 20 + 10 * (root.scaleIcon ? value : 1)
                    rotation: 180 * (root.rotateIcon ? value : 0)

                    Behavior on iconSize {
                        animation: Appearance.animation.elementMoveEnter.numberAnimation.createObject(this)
                    }
                    Behavior on rotation {
                        animation: Appearance.animation.elementMoveEnter.numberAnimation.createObject(this)
                    }
                
                }
            }
            ColumnLayout { // Stuff
                Layout.alignment: Qt.AlignVCenter
                Layout.rightMargin: valueIndicatorRightPadding
                spacing: 5

                RowLayout { // Name fill left, value on the right end
                    Layout.leftMargin: valueProgressBar.height / 2 // Align text with progressbar radius curve's left end
                    Layout.rightMargin: valueProgressBar.height / 2 // Align text with progressbar radius curve's left end

                    StyledText {
                        color: Appearance.colors.colOnLayer0
                        font.pixelSize: Appearance.font.pixelSize.small
                        Layout.fillWidth: true
                        text: root.name
                    }

                    StyledText {
                        color: Appearance.colors.colOnLayer0
                        font.pixelSize: Appearance.font.pixelSize.small
                        Layout.fillWidth: false
                        text: Math.round(root.value * 100)
                        // A small nudge on every step, so the eye can tell a
                        // change happened even when the bar is nearly full.
                        scale: valuePulse.running ? 1.18 : 1
                        Behavior on scale {
                            NumberAnimation { duration: 140; easing.type: Easing.OutBack }
                        }
                        SequentialAnimation on opacity {
                            id: valuePulse
                            running: false
                            NumberAnimation { to: 0.55; duration: 70 }
                            NumberAnimation { to: 1.0; duration: 150; easing.type: Easing.OutCubic }
                        }
                        onTextChanged: valuePulse.restart()
                    }

                    // Direction chip: ▲/▼ plus the step, only while the
                    // change is fresh (the caller clears `delta` after a beat).
                    RowLayout {
                        Layout.fillWidth: false
                        spacing: 1
                        visible: Math.abs(root.delta) > 0.001
                        opacity: visible ? 1 : 0
                        Behavior on opacity {
                            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
                        }
                        MaterialSymbol {
                            text: root.delta > 0 ? "arrow_upward" : "arrow_downward"
                            iconSize: 14
                            color: root.delta > 0 ? Appearance.colors.colPrimary : Appearance.colors.colError
                        }
                        StyledText {
                            text: Math.max(1, Math.round(Math.abs(root.delta) * 100))
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: root.delta > 0 ? Appearance.colors.colPrimary : Appearance.colors.colError
                        }
                    }
                }
                
                StyledProgressBar {
                    id: valueProgressBar
                    Layout.fillWidth: true
                    value: root.value
                    // The fill eases to the new value instead of jumping, so
                    // the step itself is legible.
                    Behavior on value {
                        animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                    }
                }
            }
        }
    }
}
