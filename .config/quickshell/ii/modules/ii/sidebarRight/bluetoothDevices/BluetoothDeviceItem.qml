import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

/**
 * One device, as a row inside a `DialogListGroup`.
 *
 * The old row already had two lines -- name, then "Connected • 70%" -- but the
 * actions were hidden behind a second click on a chevron, and the whole row was
 * one flat band. Both are fixed here: the row is a grouped card member with a
 * rounded hover plate, and the battery is a small inline meter on the right
 * rather than a number buried in the meta line.
 *
 * The expand/collapse stays. A device list is a list of facts, and turning the
 * row into two always-visible buttons would put four controls in a column where
 * most entries only need one.
 */
DialogListItem {
    id: root
    required property var device
    property bool expanded: false
    pointingHandCursor: !expanded

    buttonRadius: Appearance.rounding.normal
    verticalPadding: 12

    onClicked: expanded = !expanded
    altAction: () => expanded = !expanded

    readonly property bool isConnected: (root.device?.connected || root.device?.paired) ?? false

    component ActionButton: DialogButton {
        colBackground: Appearance.colors.colPrimary
        colBackgroundHover: Appearance.colors.colPrimaryHover
        colRipple: Appearance.colors.colPrimaryActive
        colText: Appearance.colors.colOnPrimary
    }

    contentItem: ColumnLayout {
        anchors {
            fill: parent
            topMargin: root.verticalPadding
            leftMargin: root.horizontalPadding
            rightMargin: root.horizontalPadding
        }
        spacing: 0

        RowLayout {
            spacing: 16

            MaterialSymbol {
                iconSize: Appearance.font.pixelSize.larger
                text: Icons.getBluetoothDeviceMaterialSymbol(root.device?.icon || "")
                color: root.isConnected
                    ? Appearance.colors.colPrimary
                    : Appearance.colors.colOnSurfaceVariant
            }

            ColumnLayout {
                spacing: 3
                Layout.fillWidth: true

                StyledText {
                    Layout.fillWidth: true
                    font.pixelSize: Appearance.font.pixelSize.small
                    font.weight: root.isConnected ? Font.DemiBold : Font.Normal
                    color: root.isConnected
                        ? Appearance.colors.colOnLayer0
                        : Appearance.colors.colOnSurfaceVariant
                    elide: Text.ElideRight
                    text: root.device?.name || Translation.tr("Unknown device")
                    textFormat: Text.PlainText
                }

                RowLayout {
                    spacing: 6
                    visible: root.isConnected
                    Layout.fillWidth: true

                    Rectangle {
                        implicitWidth: 5
                        implicitHeight: 5
                        radius: 3
                        color: root.device?.connected
                            ? Appearance.colors.colPrimary
                            : Appearance.colors.colSubtext
                    }

                    StyledText {
                        Layout.fillWidth: true
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                        elide: Text.ElideRight
                        text: root.device?.connected
                            ? Translation.tr("Connected")
                            : Translation.tr("Paired")
                    }
                }
            }

            // The battery, as a meter rather than a percentage. A four-digit
            // number at 12px next to a device name is a column of digits the
            // eye has to decode; a 30px bar is read pre-attentively, and the
            // exact figure is still one glance away in the expanded panel.
            Item {
                visible: (root.device?.batteryAvailable ?? false)
                implicitWidth: 30
                implicitHeight: 14

                Rectangle {
                    id: shell
                    anchors.fill: parent
                    radius: Appearance.rounding.verysmall
                    color: "transparent"
                    border.width: 1
                    border.color: Appearance.colors.colOutlineVariant

                    Rectangle { // the terminal nub, outside the shell
                        anchors.left: parent.right
                        anchors.leftMargin: 1
                        anchors.verticalCenter: parent.verticalCenter
                        width: 2
                        height: 6
                        radius: 1
                        color: Appearance.colors.colOutlineVariant
                    }

                    Rectangle {
                        anchors {
                            left: parent.left
                            leftMargin: 2
                            top: parent.top
                            bottom: parent.bottom
                            topMargin: 2
                            bottomMargin: 2
                        }
                        // Clamped: a device reporting >100% (some do, briefly
                        // off a dock) would otherwise overflow the shell.
                        width: Math.max(0, Math.min(1, root.device?.battery ?? 0))
                            * (shell.width - 4)
                        radius: Appearance.rounding.verysmall - 1
                        color: Appearance.colors.colSubtext
                        Behavior on width {
                            animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
                        }
                    }
                }
            }

            MaterialSymbol {
                text: "expand_more"
                iconSize: Appearance.font.pixelSize.normal
                color: Appearance.colors.colOnLayer3
                rotation: root.expanded ? 180 : 0
                Behavior on rotation {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                }
            }
        }

        RowLayout {
            visible: root.expanded
            Layout.topMargin: 10
            spacing: 8
            Item {
                Layout.fillWidth: true
            }
            ActionButton {
                readonly property bool p: root.device?.paired ?? false
                colBackground: p ? Appearance.colors.colError : ColorUtils.transparentize(Appearance.colors.colLayer3, 1)
                colBackgroundHover: p ? Appearance.colors.colErrorHover : ColorUtils.transparentize(Appearance.colors.colLayer3, 1)
                colRipple: p ? Appearance.colors.colErrorActive : Appearance.colors.colLayer3Hover
                colText: p ? Appearance.colors.colOnError : Appearance.colors.colPrimary

                buttonText: p ? Translation.tr("Forget") : Translation.tr("Always connect")
                onClicked: {
                    if (root.device?.paired) {
                        root.device?.forget();
                    } else {
                        root.device?.pair();
                    }
                }
            }
            ActionButton {
                buttonText: root.device?.connected ? Translation.tr("Disconnect") : Translation.tr("Connect")

                onClicked: {
                    if (root.device?.connected) {
                        root.device.disconnect();
                    } else {
                        root.device.connect();
                    }
                }
            }
        }
        Item {
            Layout.fillHeight: true
        }
    }
}
