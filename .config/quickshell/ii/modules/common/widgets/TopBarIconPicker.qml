// Top bar icons: what the bar shows, in one place.
//
// This is the body (no header of its own) that both places share:
//
//   * Settings > Bar > "Top bar icons"   (a collapsible section)
//   * the right sidebar's quick-toggle EDIT mode (a collapsible dropdown)
//
// Keeping it in one file is the point: the two surfaces used to drift, and a
// choice made in the sidebar had to be re-made in the settings app. There is
// exactly one list of chips and one stepper, and both surfaces render it.
//
// Three groups, and the two config shapes disagree about "unset" on purpose:
//
//   Indicators    the bar's own icons -- Wi-Fi and Bluetooth inside the
//                 connectivity pill, the sound icon, the battery. These are
//                 switches on the icons that already exist: turning Wi-Fi off
//                 removes it from the pill rather than adding a second icon for
//                 the same thing elsewhere. `bar.indicators`, ON by default
//                 (`!== false`), because the bar has always shown them.
//   Quick toggles one small icon per quick toggle (night light, mic, game mode,
//                 ...), pinned next to the pill. `bar.topBarWidgets`, OFF by
//                 default (`=== true`) -- those have never been in the bar
//                 unless asked for.
//   Tray icons    how many of the tray's icons sit directly on the bar (1..5);
//                 the rest live in the tray's overflow menu. Pure taste, and it
//                 predates the chip rows -- it is here because "what the top bar
//                 shows" is one question, not two.
//
// Deliberately holds NO toggle instances: every quick toggle already has its
// live model (the bar and the sidebar own them) and this file would only be a
// second copy of the same state -- toggle it in one place and the other drifts.
// Here we only read and write the config keys, which is also what makes the
// choice survive reboots.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.services
import qs.modules.common
import qs.modules.common.widgets

ColumnLayout {
    id: root

    Layout.fillWidth: true
    spacing: 6

    // Shared with the search panel's "which icons does the bar show" listing.
    // `group` picks which config object the chip reads and writes; `key` is the
    // field name inside it.
    readonly property var indicators: [
        { key: "network", group: "indicators", icon: "wifi", name: Translation.tr("Wi-Fi") },
        { key: "bluetooth", group: "indicators", icon: "bluetooth", name: Translation.tr("Bluetooth") },
        { key: "sound", group: "indicators", icon: "volume_up", name: Translation.tr("Sound") },
        { key: "battery", group: "indicators", icon: "battery_full", name: Translation.tr("Battery") },
        { key: "mic", group: "indicators", icon: "mic_off", name: Translation.tr("Muted mic chip") },
        { key: "notifications", group: "indicators", icon: "notifications", name: Translation.tr("Notification bell chip"), sub: true },
    ]

    readonly property var toggles: [
        { key: "nightLight", group: "toggles", icon: "table_lamp", name: Translation.tr("Night Light") },
        { key: "darkMode", group: "toggles", icon: "dark_mode", name: Translation.tr("Dark mode") },
        { key: "mic", group: "toggles", icon: "mic", name: Translation.tr("Microphone") },
        { key: "idleInhibitor", group: "toggles", icon: "local_cafe", name: Translation.tr("Keep awake") },
        { key: "gameMode", group: "toggles", icon: "sports_esports", name: Translation.tr("Game mode") },
        { key: "performance", group: "toggles", icon: "speed", name: Translation.tr("Performance mode") },
        { key: "powerProfiles", group: "toggles", icon: "battery_saver", name: Translation.tr("Power profile") },
        { key: "screenSnip", group: "toggles", icon: "screenshot_region", name: Translation.tr("Screen snip") },
        { key: "colorPicker", group: "toggles", icon: "colorize", name: Translation.tr("Color picker") },
    ]

    readonly property int trayIcons: Math.max(1, Math.min(5, Config.options.bar.visibleTrayIcons ?? 3))

    function isOn(entry) {
        if (entry.group === "indicators") {
            // Nested keys (notifications.show) address a sub-object.
            if (entry.sub)
                return Config.options.bar.indicators[entry.key]?.show !== false;
            return Config.options.bar.indicators[entry.key] !== false;
        }
        return Config.options.bar.topBarWidgets[entry.key] === true;
    }

    function setOn(entry, value) {
        if (entry.group === "indicators") {
            if (entry.sub) {
                if (Config.options.bar.indicators[entry.key])
                    Config.options.bar.indicators[entry.key].show = value;
                return;
            }
            Config.options.bar.indicators[entry.key] = value;
        }
        else
            Config.options.bar.topBarWidgets[entry.key] = value;
    }

    component PinChip: RippleButton {
        id: chip

        // The model is the plain array above, so a delegate's entry arrives as
        // `modelData` (the same pattern the bar's own repeater uses); `entry` is
        // just a readable name for it below.
        required property var modelData
        readonly property var entry: chip.modelData
        readonly property bool on: root.isOn(chip.entry)

        width: 36
        height: 36
        buttonRadius: Appearance.rounding.small
        // Active chips use the ACCENT (primary), not secondaryContainer.
        // secondaryContainer is a low-emphasis tone that tracks the surface: in
        // the light scheme it is a near-white tint on the sidebar's white
        // panel, so an active chip vanished into its background and the icon
        // on it had nothing to read against. The primary is mid-tone by
        // definition in every Material scheme -- visible on both light and
        // dark panels -- and its fixed on-color guarantees icon contrast.
        colBackground: on ? Appearance.colors.colPrimary : Appearance.colors.colLayer2
        colBackgroundHover: on ? Appearance.colors.colPrimaryHover : Appearance.colors.colLayer2Hover
        colRipple: Appearance.colors.colPrimaryActive
        toggled: on

        onClicked: root.setOn(chip.entry, !chip.on)

        contentItem: Item {
            MaterialSymbol {
                anchors.centerIn: parent
                text: chip.entry.icon
                iconSize: Appearance.font.pixelSize.normal
                color: chip.on ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer2
            }
            // The pin mark is what says "this one is in the bar", so the chip
            // reads as a state, not just a button.
            MaterialSymbol {
                visible: chip.on
                anchors {
                    right: parent.right
                    top: parent.top
                    rightMargin: -1
                    topMargin: -1
                }
                text: "keep"
                iconSize: 10
                color: Appearance.colors.colOnPrimary
            }
            // Outline for the active chip: some wallpapers generate a palette
            // whose primary is near-white, and on the light scheme's panel a
            // white chip would otherwise have no visible edge of its own. The
            // hairline keeps the chip readable as a control in every palette;
            // transparent-centred, so the icon is untouched.
            Rectangle {
                anchors.fill: parent
                radius: Appearance.rounding.small
                color: "transparent"
                border.width: 1
                border.color: chip.on ? Appearance.colors.colOutline : "transparent"
            }
        }

        StyledToolTip {
            text: chip.on
                ? Translation.tr("%1 — showing in the top bar. Click to remove.").arg(chip.entry.name)
                : Translation.tr("%1 — click to add to the top bar.").arg(chip.entry.name)
        }
    }

    StyledText {
        text: Translation.tr("Indicators")
        color: Appearance.colors.colOnLayer1Inactive
        font.pixelSize: Appearance.font.pixelSize.small
    }

    // A wrap, not a grid: a row of icons is narrower than the sidebar, and a
    // Flow keeps even spacing if a translation lengthens a name, instead of
    // squeezing cells out of line.
    Flow {
        Layout.fillWidth: true
        spacing: 6

        Repeater {
            model: root.indicators
            delegate: PinChip {}
        }
    }

    StyledText {
        Layout.topMargin: 2
        text: Translation.tr("Quick toggles")
        color: Appearance.colors.colOnLayer1Inactive
        font.pixelSize: Appearance.font.pixelSize.small
    }

    Flow {
        Layout.fillWidth: true
        spacing: 6

        Repeater {
            model: root.toggles
            delegate: PinChip {}
        }
    }

    StyledText {
        Layout.topMargin: 2
        text: Translation.tr("Tray icons")
        color: Appearance.colors.colOnLayer1Inactive
        font.pixelSize: Appearance.font.pixelSize.small
    }

    // How many tray icons sit directly on the bar (1..5). A stepper rather than
    // a row of numbers: this is a single small integer, and the sidebar's own
    // version has always been a minus/plus pair -- Settings used five buttons,
    // which said the same thing in five times the width.
    RowLayout {
        Layout.fillWidth: true
        spacing: 6

        StyledText {
            Layout.fillWidth: true
            text: Translation.tr("Icons shown directly on the bar")
            color: Appearance.colors.colOnLayer1
            font.pixelSize: Appearance.font.pixelSize.small
        }

        RippleButton {
            implicitWidth: 32
            implicitHeight: 32
            buttonRadius: Appearance.rounding.small
            colBackground: Appearance.colors.colLayer2
            colBackgroundHover: Appearance.colors.colLayer2Hover
            colRipple: Appearance.colors.colLayer2Active
            enabled: root.trayIcons > 1
            opacity: enabled ? 1 : 0.5
            onClicked: Config.options.bar.visibleTrayIcons = Math.max(1, root.trayIcons - 1)
            contentItem: MaterialSymbol {
                anchors.centerIn: parent
                text: "remove"
                iconSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colOnLayer2
            }
        }

        StyledText {
            Layout.alignment: Qt.AlignVCenter
            text: `${root.trayIcons}`
            font.pixelSize: Appearance.font.pixelSize.normal
            font.family: Appearance.font.family.numbers
            color: Appearance.colors.colOnLayer1
        }

        RippleButton {
            implicitWidth: 32
            implicitHeight: 32
            buttonRadius: Appearance.rounding.small
            colBackground: Appearance.colors.colLayer2
            colBackgroundHover: Appearance.colors.colLayer2Hover
            colRipple: Appearance.colors.colLayer2Active
            enabled: root.trayIcons < 5
            opacity: enabled ? 1 : 0.5
            onClicked: Config.options.bar.visibleTrayIcons = Math.min(5, root.trayIcons + 1)
            contentItem: MaterialSymbol {
                anchors.centerIn: parent
                text: "add"
                iconSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colOnLayer2
            }
        }
    }
}
