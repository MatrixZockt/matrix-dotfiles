import QtQuick
import QtQuick.Layouts
import Quickshell
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

/**
 * The power-mode menu: the three modes, opened with a two-finger tap on the
 * bar's power icon.
 *
 * The bar icon CYCLES on one tap, which is the fast path but a blind one --
 * you cannot see what you are cycling to, and with three modes the only way to
 * reach a specific one was to tap until it came round. This is the other half
 * of that gesture: the list, with the mode you are on marked, so the choice is
 * a choice rather than a count.
 *
 * A pick writes `battery.powerMode`, exactly as the popup's three buttons and
 * the settings page do, and NOT PowerProfiles directly. That write is what
 * PowerMode watches: it snapshots the hardware the machine is holding, applies
 * the mode (platform profile plus power-autoswitch's cap converge) and records
 * the switch the on-screen notice reads. So picking a mode here raises the
 * same notice -- the graphics cap and CPU policy included -- that a press in
 * the popup raises, because it is the same switch.
 *
 * The colours and glyphs are the bar's own language for the three modes (green
 * leaf for eco, airwave for balanced, fire-orange flame for performance), so
 * the row you are picking wears what the icon will wear afterwards.
 */
BarAnchoredPanel {
    id: root

    contentWidth: 300

    // The settings' own order and words -- one list, not a second copy of it.
    readonly property var modes: PowerMode.modes

    function glyphFor(value) {
        switch (value) {
        case "eco":
            return "energy_savings_leaf"
        case "performance":
            return "local_fire_department"
        default:
            return "airwave"
        }
    }

    // Balanced is not tinted: it has no colour of its own to say, and this
    // theme's accent is a grey taken from the wallpaper -- a tinted balanced
    // glyph would read as a disabled row. See PowerProfilesToggle.tint.
    function tintFor(value) {
        switch (value) {
        case "eco":
            return "#43d17c"
        case "performance":
            return "#ff6d1f"
        default:
            return Appearance.colors.colOnLayer0
        }
    }

    function pick(value) {
        // Re-picking the mode the machine is already on is a no-op on purpose:
        // the config write is what announces a switch, and announcing a
        // non-switch would put the notice on screen for nothing.
        if (Config.options?.battery && Config.options.battery.powerMode !== value)
            Config.options.battery.powerMode = value
        root.close()
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            MaterialSymbol {
                text: root.glyphFor(PowerMode.current)
                iconSize: Appearance.font.pixelSize.larger
                color: root.tintFor(PowerMode.current)
            }
            StyledText {
                Layout.fillWidth: true
                text: Translation.tr("Power mode")
                font.pixelSize: Appearance.font.pixelSize.title
                color: Appearance.colors.colOnLayer0
            }
            RippleButton {
                Layout.preferredWidth: 30
                Layout.preferredHeight: 30
                buttonRadius: Appearance.rounding.small
                colBackground: "transparent"
                colBackgroundHover: Appearance.colors.colLayer1Hover
                onClicked: root.close()
                contentItem: MaterialSymbol {
                    anchors.centerIn: parent
                    text: "close"
                    iconSize: Appearance.font.pixelSize.normal
                    color: Appearance.colors.colOnLayer0
                }
            }
        }

        Repeater {
            model: root.modes

            delegate: Rectangle {
                id: modeRow
                required property var modelData
                readonly property bool active: PowerMode.current === modeRow.modelData.value
                property bool hovered: false

                Layout.fillWidth: true
                implicitHeight: 44
                radius: Appearance.rounding.normal
                // The active row is washed in its OWN colour -- the same tint
                // the bar icon wears for that mode -- so "this is the one you
                // are on" and "this is what it looks like" are one signal.
                color: modeRow.active
                    ? ColorUtils.transparentize(root.tintFor(modeRow.modelData.value), 0.84)
                    : (modeRow.hovered ? Appearance.colors.colLayer1Hover : "transparent")
                Behavior on color {
                    ColorAnimation {
                        duration: 140
                    }
                }

                RowLayout {
                    anchors {
                        fill: parent
                        leftMargin: 12
                        rightMargin: 12
                    }
                    spacing: 10

                    MaterialSymbol {
                        Layout.alignment: Qt.AlignVCenter
                        text: root.glyphFor(modeRow.modelData.value)
                        iconSize: Appearance.font.pixelSize.larger
                        color: root.tintFor(modeRow.modelData.value)
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: modeRow.modelData.name
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: Appearance.colors.colOnLayer0
                        elide: Text.ElideRight
                    }
                    MaterialSymbol {
                        Layout.alignment: Qt.AlignVCenter
                        visible: modeRow.active
                        text: "check"
                        iconSize: Appearance.font.pixelSize.normal
                        color: Appearance.colors.colPrimary
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: modeRow.hovered = true
                    onExited: modeRow.hovered = false
                    onClicked: root.pick(modeRow.modelData.value)
                }
            }
        }
    }
}
