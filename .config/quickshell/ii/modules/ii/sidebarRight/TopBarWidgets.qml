// Top bar icons -- the sidebar half.
//
// A dropdown that sits in the right sidebar under the quick panel, ALWAYS -- not
// only while editing the toggles, which is where it used to live. Open it and you
// get the same list the settings app shows in Settings > Bar > "Top bar icons":
// the bar's indicators (Wi-Fi, Bluetooth, sound, battery), the quick toggles, and
// how many tray icons sit on the bar.
//
// The body lives in qs.modules.common.widgets.TopBarIconPicker, so the two
// surfaces can never disagree about what the bar shows -- this file is only the
// header that folds it away, with the sidebar's own colours.
//
// Folded it is one readable row: a pin/queue icon, the words "Top bar icons", and
// a chevron. That row is the whole affordance, so it is deliberately a size you
// can hit without aiming (46px, the same as the sidebar's other rows).
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
// Translation lives in services: without this the header's own label is a
// ReferenceError at runtime, which shows up as an empty row rather than as
// anything you can see.
import qs.services
import qs.modules.common
import qs.modules.common.widgets

ColumnLayout {
    id: root

    Layout.fillWidth: true
    spacing: 4

    // Folded until asked. The state lives here rather than in the config on
    // purpose: this is a disclosure control, not a preference.
    property bool expanded: false

    RippleButton {
        id: header

        Layout.fillWidth: true
        implicitHeight: 46
        buttonRadius: Appearance.rounding.normal
        colBackground: root.expanded ? Appearance.colors.colLayer1Hover : Appearance.colors.colLayer1
        colBackgroundHover: Appearance.colors.colLayer1Hover
        colRipple: Appearance.colors.colLayer1Active

        onClicked: root.expanded = !root.expanded

        contentItem: RowLayout {
            anchors {
                fill: parent
                leftMargin: 12
                rightMargin: 12
            }
            spacing: 8

            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                text: "add_to_queue"
                iconSize: Appearance.font.pixelSize.large
                color: Appearance.colors.colOnLayer1
            }
            StyledText {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                text: Translation.tr("Top bar icons")
                font.pixelSize: Appearance.font.pixelSize.normal
                color: Appearance.colors.colOnLayer1
            }
            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                text: root.expanded ? "expand_less" : "expand_more"
                iconSize: Appearance.font.pixelSize.large
                color: Appearance.colors.colOnLayer1Inactive
            }
        }

        StyledToolTip {
            text: Translation.tr("What the top bar shows — the same list as Settings > Bar > Top bar icons.")
        }
    }

    TopBarIconPicker {
        visible: root.expanded
        // Folded away items still occupy layout space unless the height goes
        // with them; a ColumnLayout child that is invisible is skipped, so this
        // only has to stop the fade-in from popping.
        opacity: root.expanded ? 1 : 0
        Behavior on opacity {
            NumberAnimation {
                duration: 140
                easing.type: Easing.OutQuad
            }
        }
    }
}
