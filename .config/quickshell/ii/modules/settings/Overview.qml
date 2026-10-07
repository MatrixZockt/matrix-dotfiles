import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import Quickshell
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

/**
 * The settings app's first page: what this machine IS, not what it is doing.
 *
 * Windows' "System > About" is the model: device name, processor, installed
 * RAM, system type -- static facts you read once, not numbers that tick. The
 * live graphs (CPU load, disk throughput, ...) belong to the task manager,
 * which is where every tile here links to. The only live value left on the
 * page is the battery, because "how charged is it" is a status, not a graph,
 * and this is the one hardware reading a user looks for outside a monitor.
 *
 * Nothing on this page samples anything: HardwareStats stays OFF while the
 * Overview is open (an inventory read once at startup is all it needs), so
 * having settings open costs no iostat, no sensors, nothing.
 */
ContentPage {
    id: root
    forceWidth: true

    readonly property var hardware: HardwareStats
    readonly property var brightnessMonitor: Brightness.getMonitorForScreen(Quickshell.screens.length > 0 ? Quickshell.screens[0] : null)

    // Static inventory only. `active` would start the per-second samplers
    // (disk/net/GPU) that power the task manager's graphs -- exactly what this
    // page must NOT run.
    // Static inventory only. HardwareStats runs its inventory (lsblk/lspci)
    // once at shell start; the per-second samplers only run while `active` is
    // true -- and this page must never set that, so the Overview costs nothing.
    Component.onCompleted: () => {}

    // ── Formatting ───────────────────────────────────────────────────────
    function chargePercent() {
        return Math.round((Battery.percentage ?? 0) * 100);
    }

    // Seconds as "2h 15m" / "48m". UPower reports 0 when it does not know yet.
    function duration(seconds) {
        const total = Math.round((seconds ?? 0) / 60);
        if (total <= 0) return "—";
        const hours = Math.floor(total / 60);
        const minutes = total % 60;
        return hours > 0 ? `${hours}h ${minutes}m` : `${minutes}m`;
    }

    // "12.3 W", or an em dash when the fuel gauge is not reporting a rate.
    function watts(value) {
        const rate = Math.abs(value ?? 0);
        return rate > 0.05 ? rate.toFixed(1) + " W" : "—";
    }

    // Switch to another page of this app by slug.
    function openPage(slug) {
        const window = Window.window;
        if (!window || !window.pages) return;
        const index = window.pages.findIndex(page => page.slug === slug);
        if (index >= 0) window.currentPage = index;
    }

    // Send the card to the task manager FACE -- the old path spawned the
    // standalone task manager app and closed this one, so clicking a tile
    // cost a full app re-launch (presence file, veil, "starting" card) and
    // the way back was another re-launch. The two apps are one now: the
    // request rides the same page→app signal path as the deep links
    // (services/SettingsNav.qml), and the app root converts the card in
    // place -- same surface, crossfade, title flips to Task Manager.
    function openInTaskManager(key) {
        SettingsNav.requestTaskManager(key ?? "");
    }

    // One "spec" row of the About list: a label, a value, nothing moving.
    component SpecRow: Rectangle {
        id: specRow

        property string icon: "info"
        property string label: ""
        property string value: ""

        Layout.fillWidth: true
        implicitHeight: 44
        radius: Appearance.rounding.small
        color: Appearance.colors.colLayer1

        RowLayout {
            // Anchored left+right, NOT `anchors.fill: parent`: a Control
            // positions its own contentItem, so a fill anchor on it is thrown
            // away and the row was CENTRED by its content width instead --
            // every DeviceTile's text column started at a different x
            // ("Disk sda" worst) and the arrows landed in different columns.
            // Left/right anchors pin one shared inset for every row, so the
            // icon and text columns line up down the whole list. Same fix as
            // the shell's SysTrayMenuEntry.
            anchors {
                verticalCenter: parent.verticalCenter
                left: parent.left
                right: parent.right
                leftMargin: 12
                rightMargin: 12
            }
            spacing: 10

            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                text: specRow.icon
                iconSize: 20
                color: Appearance.colors.colPrimary
            }
            StyledText {
                Layout.alignment: Qt.AlignVCenter
                // Left-aligned explicitly, and with a reserved width so the
                // column of labels is one straight edge whether the label is
                // "User" or "Installed RAM" -- the row used to start each
                // label wherever its own text happened to begin.
                Layout.preferredWidth: 150
                horizontalAlignment: Text.AlignLeft
                elide: Text.ElideRight
                text: specRow.label
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colSubtext
            }
            StyledText {
                Layout.alignment: Qt.AlignVCenter
                // The value takes whatever the label column leaves, rather than
                // a fixed width: a fixed 260 left the CPU string ("Intel(R)
                // Core(TM) i9-14900HX · 32 threads @ 5.6 GHz") elided even with
                // the whole pane to spare. The middle is gone -- the label has
                // its own reserved width, so the value can simply fill the rest
                // and still end on one right-hand edge.
                Layout.fillWidth: true
                text: specRow.value
                font.pixelSize: Appearance.font.pixelSize.small
                elide: Text.ElideMiddle
                horizontalAlignment: Text.AlignRight
            }
        }
    }    // A device tile: name + model, opens the task manager on that device. No
    // number, no sparkline -- the reading lives where the reading lives.

    component DeviceTile: RippleButton {
        id: deviceTile

        // "icon" would shadow a FINAL property of the button base class, and
        // Qt refuses the override at runtime ("Cannot override FINAL
        // property") -- the tile drew with no icon at all. Its own name it is.
        property string deviceIcon: "storage"
        property string title: ""
        property string subtitle: ""
        property string deviceKey: ""

        Layout.fillWidth: true
        implicitHeight: 52
        buttonRadius: Appearance.rounding.small
        colBackground: Appearance.colors.colLayer1
        colBackgroundHover: Appearance.colors.colLayer1Hover
        onClicked: root.openInTaskManager(deviceTile.deviceKey)

        contentItem: Item {
            // WHY AN INERT ITEM WRAPS THE ROW.
            //
            // QQC2's Button OWNS its contentItem: every layout pass it sets the
            // contentItem's x/y/width/height itself, from the control's padding
            // and available size. Anchors written on the contentItem are
            // therefore overwritten, and what is left is a row sized to its own
            // implicit width and CENTRED -- which is exactly the screenshot: each
            // title starts at a different x, and the arrows land in a different
            // column on every row.
            //
            // An empty Item as the contentItem breaks that ownership. The Button
            // still positions the Item, but nothing repositions the layout
            // inside it, so `anchors.fill` there holds and the row spans the
            // button. Left edge, text column and arrow column are then the same
            // for all six rows, whatever their text length.
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 10

                MaterialSymbol {
                    Layout.alignment: Qt.AlignVCenter
                    text: deviceTile.deviceIcon
                    iconSize: 22
                    color: Appearance.colors.colSecondary
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    StyledText {
                        Layout.fillWidth: true
                        // Explicit left alignment: the label column must start
                        // at the same x on every row, not at whatever the text
                        // happens to measure.
                        Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                        horizontalAlignment: Text.AlignLeft
                        text: deviceTile.title
                        font.pixelSize: Appearance.font.pixelSize.small
                        elide: Text.ElideRight
                    }
                    StyledText {
                        Layout.fillWidth: true
                        visible: deviceTile.subtitle.length > 0
                        Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                        horizontalAlignment: Text.AlignLeft
                        text: deviceTile.subtitle
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                        elide: Text.ElideRight
                    }
                }
                // Fixed-width arrow cell, hard against the right inset: the
                // chevrons then form one straight column instead of drifting
                // with each row's text width.
                Item {
                    Layout.preferredWidth: 16
                    Layout.alignment: Qt.AlignVCenter
                    Layout.fillHeight: true

                    MaterialSymbol {
                        anchors.centerIn: parent
                        text: "arrow_forward"
                        iconSize: 16
                        color: Appearance.colors.colOutline
                    }
                }
            }
        }
    }

    // ── About this PC ────────────────────────────────────────────────────
    ContentSection {
        icon: "computer"
        title: Translation.tr("About this PC")

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 6

            SpecRow {
                icon: "badge"
                label: Translation.tr("Device name")
                value: SystemInfo.hostname?.length > 0 ? SystemInfo.hostname : "—"
            }
            SpecRow {
                icon: "memory"
                label: Translation.tr("Processor")
                value: {
                    const freq = root.hardware.cpuMaxFreq?.length > 0 ? ` @ ${root.hardware.cpuMaxFreq}` : "";
                    const name = root.hardware.cpuName?.length > 0 ? root.hardware.cpuName : "—";
                    return root.hardware.cpuThreads > 0 ? `${name} · ${root.hardware.cpuThreads} threads${freq}` : name + freq;
                }
            }
            SpecRow {
                // "memory_alt" is NOT a verified ligature in this font build
                // (the task manager's rail comment measured it); "memory" is.
                icon: "memory"
                label: Translation.tr("Installed RAM")
                value: ResourceUsage.maxAvailableMemoryString ?? "—"
            }
            SpecRow {
                icon: "desktop_windows"
                label: Translation.tr("System type")
                value: `${SystemInfo.distroName} · ${SystemInfo.windowingSystem?.length > 0 ? SystemInfo.windowingSystem : "Wayland"}`
            }
            SpecRow {
                icon: "auto_awesome"
                label: Translation.tr("Desktop")
                value: "Hyprland"
            }
            SpecRow {
                icon: "person"
                label: Translation.tr("User")
                value: SystemInfo.username ?? "—"
            }
        }
    }

    // ── Devices (each opens the task manager) ────────────────────────────
    ContentSection {
        icon: "developer_board"
        title: Translation.tr("Devices")

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 6

            DeviceTile {
                deviceIcon: "memory"
                title: Translation.tr("Processor & memory")
                subtitle: root.hardware.cpuName
                deviceKey: "cpu"
            }
            DeviceTile {
                visible: root.hardware.gpuNames.length > 0
                deviceIcon: "developer_board"
                title: Translation.tr("Graphics")
                subtitle: root.hardware.gpuNames[0] ?? ""
                deviceKey: root.hardware.gpuNames.length > 0 ? `gpu:${root.hardware.gpuNames[0]}` : ""
            }
            Repeater {
                model: root.hardware.disks
                delegate: DeviceTile {
                    required property var modelData
                    deviceIcon: modelData.name.startsWith("nvme") ? "hard_disk" : "storage"
                    title: Translation.tr("Disk %1").arg(modelData.name)
                    subtitle: {
                        const size = modelData.size && modelData.size.length > 0 ? modelData.size : "";
                        const bits = [modelData.model, size].filter(s => s && s.length > 0);
                        return bits.join(" · ");
                    }
                    deviceKey: `disk:${modelData.name}`
                }
            }
            DeviceTile {
                deviceIcon: "battery_5_bar"
                title: Translation.tr("Battery & power")
                subtitle: Battery.available ? root.chargePercent() + "%" : ""
                deviceKey: "battery"
            }
        }
    }

    // ── Status (the only live part) ──────────────────────────────────────
    ContentSection {
        icon: "bolt"
        title: Translation.tr("Status")

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 6

            // Battery: a status, not a graph.
            Rectangle {
                visible: Battery.available
                Layout.fillWidth: true
                implicitHeight: 56
                radius: Appearance.rounding.small
                color: Appearance.colors.colLayer1

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    spacing: 10

                    MaterialSymbol {
                        text: Battery.isCharging ? "battery_charging_full"
                            : root.chargePercent() > 80 ? "battery_full"
                            : root.chargePercent() > 20 ? "battery_5_bar"
                            : "battery_alert"
                        iconSize: 24
                        color: Battery.isLow ? Appearance.colors.colError : Appearance.colors.colPrimary
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        StyledText {
                            Layout.fillWidth: true
                            // Same left-alignment rule as the device tiles: a
                            // ColumnLayout centres its text by default, so
                            // "On battery" drifted out of line with every label
                            // above it.
                            Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                            horizontalAlignment: Text.AlignLeft
                            text: Battery.isCharging
                                ? Translation.tr("Charging · %1").arg(root.watts(Battery.energyRate))
                                : Translation.tr("On battery · %1").arg(root.watts(Battery.energyRate))
                            font.pixelSize: Appearance.font.pixelSize.small
                            elide: Text.ElideRight
                        }
                        StyledText {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                            horizontalAlignment: Text.AlignLeft
                            text: Battery.isFull
                                ? Translation.tr("Full")
                                : Battery.isCharging
                                    ? Translation.tr("%1 to full").arg(root.duration(Battery.timeToFull))
                                    : Translation.tr("%1 left").arg(root.duration(Battery.timeToEmpty))
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: Appearance.colors.colSubtext
                            elide: Text.ElideRight
                        }
                    }
                    StyledText {
                        text: root.chargePercent() + "%"
                        font.pixelSize: Appearance.font.pixelSize.larger
                        color: Battery.isLow ? Appearance.colors.colError : Appearance.colors.colOnSurface
                    }
                }
            }

            // Wi-Fi: a status line, opens the network page.
            RippleButton {
                Layout.fillWidth: true
                implicitHeight: 52
                buttonRadius: Appearance.rounding.small
                colBackground: Appearance.colors.colLayer1
                colBackgroundHover: Appearance.colors.colLayer1Hover
                onClicked: root.openPage("network")

                // The inert-Item wrapper is the DeviceTile rule: QQC2 owns its
                // contentItem and rewrites its geometry every layout pass, so
                // anchors written straight onto the row do not survive. Without
                // this the Wi-Fi and Bluetooth rows are centred by their own text
                // width and sit visibly out of line with the device tiles above.
                contentItem: Item {
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        spacing: 10

                        MaterialSymbol {
                            Layout.alignment: Qt.AlignVCenter
                            text: Network.wifiEnabled ? "wifi" : "wifi_off"
                            iconSize: 22
                            color: Appearance.colors.colSecondary
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            StyledText {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                                horizontalAlignment: Text.AlignLeft
                                text: Network.networkName && Network.networkName.length > 0 ? Network.networkName : Translation.tr("Offline")
                                font.pixelSize: Appearance.font.pixelSize.small
                                elide: Text.ElideRight
                            }
                            StyledText {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                                horizontalAlignment: Text.AlignLeft
                                text: Network.wifiEnabled
                                    ? Translation.tr("%1 · %2% signal").arg(Network.wifiStatus).arg(Network.active?.strength ?? 0)
                                    : Translation.tr("Wi-Fi off")
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: Appearance.colors.colSubtext
                                elide: Text.ElideRight
                            }
                        }
                        Item {
                            Layout.preferredWidth: 16
                            Layout.alignment: Qt.AlignVCenter
                            Layout.fillHeight: true

                            MaterialSymbol {
                                anchors.centerIn: parent
                                text: "arrow_forward"
                                iconSize: 16
                                color: Appearance.colors.colOutline
                            }
                        }
                    }
                }
            }

            // Bluetooth, same pattern.
            RippleButton {
                visible: BluetoothStatus.available
                Layout.fillWidth: true
                implicitHeight: 52
                buttonRadius: Appearance.rounding.small
                colBackground: Appearance.colors.colLayer1
                colBackgroundHover: Appearance.colors.colLayer1Hover
                onClicked: root.openPage("network")

                contentItem: Item {
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        spacing: 10

                        MaterialSymbol {
                            Layout.alignment: Qt.AlignVCenter
                            text: BluetoothStatus.connected ? "bluetooth_connected" : BluetoothStatus.enabled ? "bluetooth" : "bluetooth_disabled"
                            iconSize: 22
                            color: Appearance.colors.colTertiary
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            StyledText {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                                horizontalAlignment: Text.AlignLeft
                                text: BluetoothStatus.activeDeviceCount > 0
                                    ? Translation.tr("%1 connected").arg(BluetoothStatus.activeDeviceCount)
                                    : (BluetoothStatus.enabled ? Translation.tr("Bluetooth on") : Translation.tr("Bluetooth off"))
                                font.pixelSize: Appearance.font.pixelSize.small
                                elide: Text.ElideRight
                            }
                            StyledText {
                                Layout.fillWidth: true
                                visible: BluetoothStatus.firstActiveDevice !== null
                                Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                                horizontalAlignment: Text.AlignLeft
                                text: BluetoothStatus.firstActiveDevice?.name ?? ""
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: Appearance.colors.colSubtext
                                elide: Text.ElideRight
                            }
                        }
                        Item {
                            Layout.preferredWidth: 16
                            Layout.alignment: Qt.AlignVCenter
                            Layout.fillHeight: true

                            MaterialSymbol {
                                anchors.centerIn: parent
                                text: "arrow_forward"
                                iconSize: 16
                                color: Appearance.colors.colOutline
                            }
                        }
                    }
                }
            }
        }
    }

    // ── How it looks (unchanged: theme is a setting's overview) ──────────
    ContentSection {
        icon: "palette"
        title: Translation.tr("Appearance")

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            // The live palette, as the thing you actually judge a theme by.
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 64
                radius: Appearance.rounding.small
                color: Appearance.colors.colLayer1
                border.width: 1
                border.color: Appearance.colors.colOutlineVariant

                RowLayout {
                    anchors {
                        fill: parent
                        margins: 10
                    }
                    spacing: 4

                    Repeater {
                        model: [
                            Appearance.colors.colPrimary,
                            Appearance.colors.colSecondary,
                            Appearance.colors.colTertiary,
                            Appearance.colors.colError,
                            Appearance.colors.colLayer0,
                        ]
                        delegate: Rectangle {
                            required property var modelData
                            Layout.fillWidth: true
                            implicitHeight: 44
                            radius: Appearance.rounding.verysmall
                            color: modelData
                            border.width: 1
                            border.color: ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.5)
                        }
                    }
                }
            }

            StatTile {
                Layout.fillWidth: true
                icon: Appearance.m3colors.darkmode ? "dark_mode" : "light_mode"
                label: Translation.tr("Theme")
                value: (Persistent.states.themeTemplate && Persistent.states.themeTemplate.length > 0)
                    ? Persistent.states.themeTemplate
                    : Translation.tr("From wallpaper")
                caption: Appearance.m3colors.darkmode ? Translation.tr("Dark") : Translation.tr("Light")
                accent: Appearance.colors.colPrimary
                interactive: true
                onClicked: root.openPage("appearance")
            }
        }
    }
}
