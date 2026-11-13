// The task manager's actual UI, independent of the surface that hosts it.
//
// This is the settings app's architecture, applied: the app (rail on the left,
// device page on the right) is ONE component, and the two skins of the app --
// the layer-surface popup (taskmanager.qml) and the real desktop window
// (TaskManagerWindowHost.qml) -- both host this same tree. That is what makes
// the SUPER+F morph possible for this app the way it works for settings: the
// popup hands over to the window without the UI ever being rebuilt, so the
// selected device page survives the change of skin.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions as CF

Item {
    id: root

    // Which page is showing -- "cpu", "memory", "gpu:<name>", "disk:<name>",
    // "net:<name>", "battery", "system", "apps", "processes".
    // Apps is the front door: resolveKey falls back to it for a plain launch,
    // and the initial value matches so the first frame is already the list of
    // running apps.
    property string selectedKey: "apps"

    // Escape inside the app quits it, whichever skin it is wearing; what
    // "quitting" means is the host's business (popup close vs window close).
    signal quitRequested()

    // The way back to Settings. Only the EMBEDDED face of this panel offers it
    // -- when the settings app converted itself into the task manager instead of
    // spawning this as a separate app, the hardware tiles' "open the task
    // manager" keeps one process, and this is how it goes back. The standalone
    // app has nothing behind it to return to and never shows the entry.
    signal backRequested()

    // Whether that back entry exists in the rail at all.
    property bool showBackButton: false

    // Settings tiles send "cpu" / "memory" / "swap" / "gpu:<name>" /
    // "disk:<name>" / "net:<name>" / "battery". They name a page here; an
    // unknown key falls back to the CPU page rather than nowhere.
    function resolveKey(key) {
        // A plain launch (no requested page) opens on Apps, the way the task
        // manager everybody knows does -- the list of running things is its
        // front door. Settings' tiles always pass an explicit key, so they
        // are unaffected; an UNKNOWN key still falls back to CPU below.
        if (!key || key.length === 0)
            return "apps";
        const head = key.indexOf(":") >= 0 ? key.slice(0, key.indexOf(":")) : key;
        if (head === "swap")
            return "memory";
        if ((head === "gpu" || head === "disk" || head === "net") && key.indexOf(":") >= 0) {
            const name = key.slice(key.indexOf(":") + 1);
            if (name.length > 0)
                return key;
        }
        if (head === "battery" || head === "cpu" || head === "memory" || head === "system"
            || head === "apps" || head === "processes")
            return head;
        return "cpu";
    }

    // ── Live data, the shape the pages need ────────────────────────────────
    // One reactive snapshot of the static facts: `SystemFacts.facts` bumps
    // when the inventory lands, and the pages below read from here instead of
    // poking the service in fifteen places.
    readonly property var sys: {
        const _ = SystemFacts.facts;
        return {
            system: SystemFacts.system,
            cpu: SystemFacts.cpu,
            memory: SystemFacts.memory,
            gpus: SystemFacts.gpus,
            disks: SystemFacts.disks,
            networks: SystemFacts.networks,
            batteries: SystemFacts.batteries,
            temperatures: SystemFacts.temperatures,
        };
    }

    // ── The rail: one entry per device, with its live number ───────────────
    // Rebuilt from the inventory, so a machine with two GPUs gets two entries
    // and a desktop without a battery gets none.
    readonly property var railModel: {
        const out = [];
        // Apps + Processes first, like Windows: "what is running" before
        // "what is the hardware doing".
        out.push({ key: "apps", icon: "apps", label: Translation.tr("Apps"), accent: Appearance.colors.colPrimary, listPage: true });
        out.push({ key: "processes", icon: "list_alt", label: Translation.tr("Processes"), accent: Appearance.colors.colPrimary, listPage: true });
        // "developer_board" (chip) for the CPU, "memory" (DIMM) for memory --
        // both verified ligatures in this font build; "memory_alt" and "ram"
        // are not, and an absent ligature draws its own text as the icon.
        out.push({ key: "cpu", icon: "developer_board", label: Translation.tr("Processor"), accent: Appearance.colors.colTertiary });
        out.push({ key: "memory", icon: "memory", label: Translation.tr("Memory"), accent: Appearance.colors.colTertiary });
        for (let i = 0; i < root.sys.gpus.length; i++)
            out.push({ key: `gpu:${root.sys.gpus[i].name}`, icon: "videocam", label: root.shortGpuName(root.sys.gpus[i].name), accent: Appearance.colors.colPrimary });
        for (let i = 0; i < root.sys.disks.length; i++)
            out.push({ key: `disk:${root.sys.disks[i].name}`, icon: root.sys.disks[i].name.startsWith("nvme") ? "hard_disk" : "storage", label: Translation.tr("Disk %1").arg(root.sys.disks[i].name), accent: Appearance.colors.colTertiary });
        for (let i = 0; i < root.sys.networks.length; i++)
            out.push({ key: `net:${root.sys.networks[i].name}`, icon: root.sys.networks[i].name.startsWith("w") ? "wifi" : "lan", label: root.sys.networks[i].name, accent: Appearance.colors.colSecondary });
        if (root.sys.batteries.length > 0 || Battery.available)
            out.push({ key: "battery", icon: "battery_full", label: Translation.tr("Battery"), accent: root.batteryAccent() });
        out.push({ key: "system", icon: "laptop_mac", label: Translation.tr("System"), accent: Appearance.colors.colSecondary });
        return out;
    }

    function shortGpuName(name) {
        const n = String(name ?? "");
        if (n.length <= 22)
            return n;
        return n.slice(0, 19) + "…";
    }

    function batteryAccent() {
        if (!Battery.available)
            return Appearance.colors.colSecondary;
        if (Battery.isCharging)
            return Appearance.colors.colPrimary;
        if (Battery.isCritical)
            return Appearance.colors.colError;
        return Appearance.colors.colSecondary;
    }

    // WHICH listed card the live clock and load belong to. The counters are
    // ONE card's (`card2/gt_*` is the Intel iGPU on this laptop) while the rail
    // lists every chip, so printing them under the other card's name made the
    // idle dGPU read the iGPU's 1650 MHz clock and the iGPU's graph. Matched by
    // PCI address, the same way the resource overlay rows do it.
    function gpuOwnsLiveNumbers(name) {
        const gpu = (root.sys.gpus ?? []).find(entry => entry.name === name) ?? {};
        const pci = gpu.pci ?? "";
        return pci === "" || HardwareStats.gpuClockPci === "" || pci === HardwareStats.gpuClockPci;
    }

    // The little number at the rail's right edge, per entry kind.
    function railValue(key) {
        const head = key.indexOf(":") >= 0 ? key.slice(0, key.indexOf(":")) : key;
        const name = key.indexOf(":") >= 0 ? key.slice(key.indexOf(":") + 1) : "";
        switch (head) {
        case "cpu":
            return (ResourceUsage.cpuUsage * 100).toFixed(0) + "%";
        case "memory":
            return (ResourceUsage.memoryUsedPercentage * 100).toFixed(0) + "%";
        case "gpu": {
            if (!root.gpuOwnsLiveNumbers(name))
                return "—";
            // Busy fraction where the driver reports one (the chip that
            // renders); the clock only as a fallback, because a clock is a
            // number to explain and a percentage is not.
            if (HardwareStats.gpuLoad >= 0)
                return (HardwareStats.gpuLoad * 100).toFixed(0) + "%";
            return HardwareStats.gpuClockMhz > 0 ? `${HardwareStats.gpuClockMhz.toFixed(0)} MHz` : "—";
        }
        case "disk": {
            const d = HardwareStats.disks.find(x => x.name === name);
            return d ? HardwareStats.formatBytes(Math.max(d.readBps, d.writeBps)) : "—";
        }
        case "net": {
            const n = HardwareStats.networks.find(x => x.name === name);
            return n ? HardwareStats.formatBytes(Math.max(n.rxBps, n.txBps)) : "—";
        }
        case "battery":
            return Battery.available ? `${Math.round(Battery.percentage * 100)}%` : "—";
        default:
            return "";
        }
    }

    // ── Battery's own history ──────────────────────────────────────────────
    // UPower publishes watts every couple of seconds; the battery page's graph
    // is that rate, kept here so the page owns its window of time.
    property list<real> powerHistory: []
    readonly property int historyLength: ResourceUsage.historyLength
    Timer {
        interval: 2000
        running: root.visible && Battery.available
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            root.powerHistory = root.powerHistory.concat([Math.min(1, Math.max(Battery.energyRate, 0) / 30)]).slice(-root.historyLength);
        }
    }

    function join(parts) {
        return (parts ?? []).filter(part => part && String(part).trim().length > 0).join(" · ");
    }

    function fmtTime(seconds) {
        if (!(seconds > 0))
            return "—";
        const h = Math.floor(seconds / 3600);
        const m = Math.round((seconds % 3600) / 60);
        if (h > 0)
            return Translation.tr("%1 h %2 min").arg(h).arg(m);
        return Translation.tr("%1 min").arg(m);
    }

    // ── The app: rail on the left, device page on the right ────────────────
    RowLayout {
        anchors {
            fill: parent
            margins: 10
        }
        spacing: 0

        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Escape) {
                root.quitRequested();
                event.accepted = true;
            }
        }

        // ── The rail ───────────────────────────────────────────────────────
        ColumnLayout {
            Layout.preferredWidth: 218
            Layout.fillHeight: true
            Layout.topMargin: 4
            spacing: 4

            RowLayout { // Title, compact: the pages carry the big text
                Layout.fillWidth: true
                Layout.leftMargin: 10
                Layout.bottomMargin: 6
                spacing: 9

                MaterialSymbol {
                    text: "monitoring"
                    iconSize: 21
                    color: Appearance.colors.colPrimary
                }
                StyledText {
                    text: Translation.tr("Task Manager")
                    font {
                        family: Appearance.font.family.title
                        pixelSize: Appearance.font.pixelSize.title
                        variableAxes: Appearance.font.variableAxes.title
                    }
                    color: Appearance.colors.colOnLayer0
                    elide: Text.ElideRight
                }
                Item { Layout.fillWidth: true }
            }

            // Back to Settings. Same button grammar as the rail entries below
            // (a RippleButton at 42px with the hover tint), sitting above them:
            // the conversion reads as a two-sided street, not a one-way trap.
            RippleButton {
                Layout.fillWidth: true
                Layout.leftMargin: 10
                implicitHeight: 42
                buttonRadius: Appearance.rounding.small
                visible: root.showBackButton

                colBackground: backMouse.containsMouse
                    ? CF.ColorUtils.transparentize(Appearance.colors.colLayer1Hover, 0.5)
                    : "transparent"
                Behavior on colBackground {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }
                onClicked: root.backRequested()

                MouseArea {
                    id: backMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: parent.clicked()
                }

                contentItem: RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    spacing: 10

                    MaterialSymbol {
                        text: "arrow_back"
                        iconSize: 20
                        color: Appearance.colors.colPrimary
                    }
                    StyledText {
                        text: Translation.tr("Back to Settings")
                        color: Appearance.colors.colOnLayer0
                        elide: Text.ElideRight
                    }
                }
            }

            // Entries. The selected one gets a filled pill; the number at the
            // right edge is the same live value the page's graph is drawing.
            Repeater {
                model: root.railModel

                delegate: RippleButton {
                    id: railButton
                    required property var modelData
                    readonly property bool selected: root.selectedKey === modelData.key
                    Layout.fillWidth: true
                    implicitHeight: 42
                    buttonRadius: Appearance.rounding.small
                    onClicked: root.selectedKey = modelData.key

                    // The list pages (Apps / Processes) mark the boundary in
                    // the rail: everything below is hardware.

                    Behavior on colBackground {
                        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                    }
                    // RippleButton exposes its background as `colBackground`,
                    // not `color` -- assigning `color` fails to load the whole
                    // app ("Cannot assign to non-existent property").
                    colBackground: selected ? Appearance.colors.colLayer1Hover : (railMouse.containsMouse ? CF.ColorUtils.transparentize(Appearance.colors.colLayer1Hover, 0.5) : "transparent")

                    MouseArea {
                        id: railMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        // The button handles the click; this one only watches.
                        onClicked: railButton.clicked()
                    }

                    contentItem: Item {
                        RowLayout {
                            anchors {
                                fill: parent
                                leftMargin: 12
                                rightMargin: 12
                            }
                            spacing: 10

                            // Selection marker: a slim bar at the left edge,
                            // quieter than a full second background.
                            Rectangle {
                                implicitWidth: 3
                                implicitHeight: 18
                                radius: 1.5
                                visible: railButton.selected
                                color: railButton.modelData.accent
                            }

                            MaterialSymbol {
                                text: railButton.modelData.icon
                                iconSize: 19
                                color: railButton.selected ? railButton.modelData.accent : Appearance.colors.colSubtext
                            }

                            StyledText {
                                Layout.fillWidth: true
                                text: railButton.modelData.label
                                font.pixelSize: Appearance.font.pixelSize.small
                                color: railButton.selected ? Appearance.colors.colOnLayer1 : Appearance.colors.colSubtext
                                elide: Text.ElideRight
                            }

                            StyledText {
                                text: root.railValue(railButton.modelData.key)
                                font {
                                    family: Appearance.font.family.numbers
                                    variableAxes: Appearance.font.variableAxes.numbers
                                    pixelSize: Appearance.font.pixelSize.smaller
                                }
                                color: railButton.selected ? Appearance.colors.colOnLayer1 : Appearance.colors.colOnLayer1Inactive
                            }
                        }
                    }
                }
            }

            Item { Layout.fillHeight: true } // spring

            // The list pages' live total, parked where the footer was: the
            // same “what am I looking at” job the hostname text does for the
            // hardware pages.
            StyledText {
                visible: root.isListPage
                Layout.fillWidth: true
                Layout.leftMargin: 12
                Layout.bottomMargin: 4
                text: root.isListPage ? root.listPageSummary() : ""
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colOnLayer1Inactive
                elide: Text.ElideRight
            }

            StyledText { // footer: the machine this page is describing
                visible: !root.isListPage
                Layout.fillWidth: true
                Layout.leftMargin: 12
                Layout.bottomMargin: 4
                text: root.sys.system.hostname ?? ""
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colOnLayer1Inactive
                elide: Text.ElideRight
            }
        }

        Rectangle { // divider between rail and page
            Layout.fillHeight: true
            Layout.leftMargin: 4
            Layout.rightMargin: 10
            implicitWidth: 1
            color: Appearance.colors.colOutlineVariant
            visible: !root.isListPage
        }

        // ── The list pages: Apps and Processes ─────────────────────────────
        // Same directory, so the type resolves directly (the qmldir export
        // is for other modules).
        ProcessesView {
            visible: root.isListPage
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.topMargin: 10
            Layout.rightMargin: 10
            Layout.bottomMargin: 10
            // The two pages share this one view; the grouped flag is the
            // difference between "Apps" and "Processes".
            groupedByApp: root.selectedKey === "apps"
        }

        // ── The device page ────────────────────────────────────────────────
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.topMargin: 14
            Layout.rightMargin: 14
            Layout.bottomMargin: 12
            spacing: 12
            visible: !root.isListPage

            // Header: what you are looking at, and how busy it is -- the two
            // numbers the page exists for, at opposite ends of one row.
            RowLayout {
                Layout.fillWidth: true
                spacing: 16

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    StyledText {
                        Layout.fillWidth: true
                        text: root.pageTitle
                        font {
                            family: Appearance.font.family.title
                            pixelSize: Appearance.font.pixelSize.larger
                            variableAxes: Appearance.font.variableAxes.title
                        }
                        color: Appearance.colors.colOnLayer0
                        elide: Text.ElideRight
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: root.pageSubtitle
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: Appearance.colors.colSubtext
                        elide: Text.ElideRight
                    }
                }

                ColumnLayout { // the big live number
                    spacing: 0

                    StyledText {
                        text: root.pageBigValue
                        font {
                            family: Appearance.font.family.numbers
                            variableAxes: Appearance.font.variableAxes.numbers
                            pixelSize: Appearance.font.pixelSize.huge * 1.4
                        }
                        color: Appearance.colors.colOnLayer0
                    }
                    StyledText {
                        Layout.alignment: Qt.AlignRight
                        text: root.pageBigCaption
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colOnLayer1Inactive
                    }
                }
            }

            // The graph. Height enough to read shape, gridlines quiet enough
            // to ignore when the shape is obvious.
            Rectangle {
                id: graphCard
                Layout.fillWidth: true
                Layout.preferredHeight: 190
                radius: Appearance.rounding.small
                color: CF.ColorUtils.transparentize(Appearance.colors.colLayer1, 0.55)
                border.width: 1
                border.color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.5)

                // Gridlines at 0 / 50 / 100 with their labels on the left.
                Repeater {
                    model: [
                        { frac: 0.0, label: "0" },
                        { frac: 0.5, label: "50" },
                        { frac: 1.0, label: "100" }
                    ]

                    delegate: Item {
                        required property var modelData
                        anchors {
                            left: parent.left
                            right: parent.right
                            leftMargin: 34
                            rightMargin: 12
                        }
                        y: 12 + (parent.height - 24) * (1 - modelData.frac)

                        Rectangle {
                            anchors {
                                left: parent.left
                                right: parent.right
                                verticalCenter: parent.verticalCenter
                            }
                            implicitHeight: 1
                            color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.55)
                        }
                        StyledText {
                            anchors {
                                left: parent.left
                                leftMargin: -34
                                verticalCenter: parent.verticalCenter
                            }
                            width: 26
                            text: modelData.label
                            font {
                                family: Appearance.font.family.numbers
                                variableAxes: Appearance.font.variableAxes.numbers
                                pixelSize: Appearance.font.pixelSize.smaller
                            }
                            color: Appearance.colors.colOnLayer1Inactive
                            horizontalAlignment: Text.AlignRight
                        }
                    }
                }

                Graph {
                    anchors {
                        fill: parent
                        margins: 12
                        leftMargin: 34
                    }
                    visible: root.pageHistory.length > 1
                    values: root.pageHistory
                    points: root.historyLength
                    color: root.pageAccent
                    fillOpacity: 0.35
                }

                // A device with no rate gets no fake chart: a note instead.
                StyledText {
                    anchors.centerIn: parent
                    visible: root.pageHistory.length < 2
                    text: root.pageGraphEmptyText
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colOnLayer1Inactive
                }
            }

            // The rows: what it is and what it is doing, one line each.
            // StyledFlickable: two-finger scroll with kinetic glide (the same
            // Brave-like momentum the settings page has), not stop-on-lift.
            StyledFlickable {
                id: detailsFlick
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: width
                contentHeight: detailsColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: detailsColumn
                    width: detailsFlick.width
                    spacing: 0

                    Repeater {
                        model: root.pageRows

                        delegate: Rectangle {
                            id: row
                            required property var modelData
                            required property int index
                            Layout.fillWidth: true
                            implicitHeight: Math.max(rowLabel.implicitHeight, rowValue.implicitHeight) + 16
                            radius: Appearance.rounding.verysmall
                            color: row.index % 2 === 0 ? CF.ColorUtils.transparentize(Appearance.colors.colLayer1, 0.45) : "transparent"
                            visible: (row.modelData.value ?? "").length > 0

                            RowLayout {
                                anchors {
                                    fill: parent
                                    leftMargin: 14
                                    rightMargin: 14
                                }
                                spacing: 14

                                StyledText {
                                    id: rowLabel
                                    Layout.preferredWidth: 190
                                    text: row.modelData.label ?? ""
                                    font.pixelSize: Appearance.font.pixelSize.small
                                    color: Appearance.colors.colSubtext
                                    elide: Text.ElideRight
                                }
                                StyledText {
                                    id: rowValue
                                    Layout.fillWidth: true
                                    text: row.modelData.value ?? ""
                                    font {
                                        family: row.modelData.live ? Appearance.font.family.numbers : Appearance.font.family.main
                                        variableAxes: row.modelData.live ? Appearance.font.variableAxes.numbers : Appearance.font.variableAxes.main
                                        pixelSize: Appearance.font.pixelSize.small
                                    }
                                    color: Appearance.colors.colOnLayer1
                                    elide: Text.ElideRight
                                }
                                MaterialSymbol {
                                    visible: row.modelData.live ?? false
                                    text: "bolt"
                                    iconSize: 13
                                    color: root.pageAccent
                                }
                            }
                        }
                    }

                    Item { Layout.preferredHeight: 4 }
                }
            }
        }
    }

    // ── Per-page bindings ──────────────────────────────────────────────────
    // Each page is three things plus its rows: a title, a big number, and a
    // history for the graph. Kept as functions of selectedKey so the switch
    // happens in one place.
    // The list pages (Apps / Processes) hide the device page and show the
    // process table instead; they also own the ProcessList sampler, which
    // must stop when the app closes -- a task manager that keeps sampling
    // after it is gone is exactly the background cost this shell avoids.
    readonly property bool isListPage: selectedKey === "apps" || selectedKey === "processes"

    // The one-line total under the rail on the list pages: "214 processes ·
    // CPU 12% · Memory 5.2 GB". Reads ProcessList directly (revision keeps it
    // live between samples).
    function listPageSummary() {
        const _ = ProcessList.revision;
        const cpu = ProcessList.totalCpu.toFixed(0);
        const mem = ProcessList.totalMemory >= 1024 * 1024 * 1024
            ? (ProcessList.totalMemory / (1024 * 1024 * 1024)).toFixed(1) + " GB"
            : Math.round(ProcessList.totalMemory / (1024 * 1024)) + " MB";
        return ProcessList.count + Translation.tr(" processes · CPU ") + cpu + "% · Memory " + mem;
    }
    // True only when this tree sits in a window that is ACTUALLY shown.
    //
    // `visible` is an Item property and stays true inside a hidden window:
    // both skins (the overlay panel and the settings window) build this tree
    // at shell start and merely do not display it. The old `isListPage &&
    // visible` therefore armed the process sampler at EVERY shell start and
    // never released it -- it was the `owners=[taskmanager]` reported by
    // `processList owners` while nothing was on screen, and the reason the
    // "costs nothing when closed" contract never held for this card.
    readonly property bool onScreenNow: root.visible
        && root.Window.window !== null
        && root.Window.window.visible
    // The GPU column rides the same gate as the process table: same surfaces,
    // same condition. Reading the card costs a process spawn that OPENS the
    // device, so it must stop the moment the table leaves the screen.
    onIsListPageChanged: {
        ProcessList.setActive("taskmanager", root.isListPage && root.onScreenNow);
        GpuProcesses.setActive("taskmanager", root.isListPage && root.onScreenNow);
    }
    onVisibleChanged: {
        ProcessList.setActive("taskmanager", root.isListPage && root.onScreenNow);
        GpuProcesses.setActive("taskmanager", root.isListPage && root.onScreenNow);
    }
    onOnScreenNowChanged: {
        ProcessList.setActive("taskmanager", root.isListPage && root.onScreenNow);
        GpuProcesses.setActive("taskmanager", root.isListPage && root.onScreenNow);
    }
    // Opened directly on a list page (QS_TM_KEY=apps): no change signal ever
    // fires, so the initial state has to be applied by hand too.
    Component.onCompleted: {
        ProcessList.setActive("taskmanager", root.isListPage && root.onScreenNow);
        GpuProcesses.setActive("taskmanager", root.isListPage && root.onScreenNow);
    }
    Component.onDestruction: {
        ProcessList.setActive("taskmanager", false);
        GpuProcesses.setActive("taskmanager", false);
    }
    readonly property color pageAccent: {
        const entry = root.railModel.find(e => e.key === root.selectedKey);
        return entry ? entry.accent : Appearance.colors.colPrimary;
    }

    readonly property string pageTitle: {
        const entry = root.railModel.find(e => e.key === root.selectedKey);
        if (entry)
            return entry.label;
        return Translation.tr("Task Manager");
    }

    readonly property string pageSubtitle: {
        const head = root.selectedKey.indexOf(":") >= 0 ? root.selectedKey.slice(0, root.selectedKey.indexOf(":")) : root.selectedKey;
        switch (head) {
        case "cpu":
            return root.sys.cpu.model ?? "";
        case "memory":
            return Translation.tr("%1 installed").arg(SystemFacts.bytes(root.sys.memory.total));
        case "gpu":
            return root.selectedKey.slice(4);
        case "disk":
            return root.selectedKey.slice(5);
        case "net":
            return root.selectedKey.slice(4);
        case "battery":
            return root.batterySubtitle();
        default:
            return root.sys.system.os ?? "";
        }
    }

    function batterySubtitle() {
        if (!Battery.available)
            return Translation.tr("No battery detected");
        if (Battery.isCharging)
            return Translation.tr("Charging · %1").arg(root.fmtTime(Battery.timeToFull));
        if (Battery.isPluggedIn)
            return Translation.tr("Plugged in");
        return root.fmtTime(Battery.timeToEmpty) + Translation.tr(" remaining");
    }

    readonly property string pageBigValue: {
        const head = root.selectedKey.indexOf(":") >= 0 ? root.selectedKey.slice(0, root.selectedKey.indexOf(":")) : root.selectedKey;
        const name = root.selectedKey.indexOf(":") >= 0 ? root.selectedKey.slice(root.selectedKey.indexOf(":") + 1) : "";
        switch (head) {
        case "cpu":
            return (ResourceUsage.cpuUsage * 100).toFixed(0) + "%";
        case "memory":
            return (ResourceUsage.memoryUsedPercentage * 100).toFixed(0) + "%";
        case "gpu":
            // A percentage, like the processor and memory cards -- the same
            // question, answered the same way (see gpuOwnsLiveNumbers).
            if (!root.gpuOwnsLiveNumbers(name))
                return "—";
            if (HardwareStats.gpuLoad >= 0)
                return (HardwareStats.gpuLoad * 100).toFixed(0) + "%";
            return HardwareStats.gpuClockMhz > 0 ? HardwareStats.gpuClockMhz.toFixed(0) : "—";
        case "disk": {
            const d = HardwareStats.disks.find(x => x.name === root.selectedKey.slice(5));
            return d ? HardwareStats.formatBytes(Math.max(d.readBps, d.writeBps)) : "—";
        }
        case "net": {
            const n = HardwareStats.networks.find(x => x.name === root.selectedKey.slice(4));
            return n ? HardwareStats.formatBytes(Math.max(n.rxBps, n.txBps)) : "—";
        }
        case "battery":
            return Battery.available ? `${Math.round(Battery.percentage * 100)}%` : "—";
        case "system": {
            const s = root.sys.system;
            return s.uptime > 0 ? SystemFacts.uptime(s.uptime) : "—";
        }
        default:
            return "—";
        }
    }

    readonly property string pageBigCaption: {
        const head = root.selectedKey.indexOf(":") >= 0 ? root.selectedKey.slice(0, root.selectedKey.indexOf(":")) : root.selectedKey;
        const name = root.selectedKey.indexOf(":") >= 0 ? root.selectedKey.slice(root.selectedKey.indexOf(":") + 1) : "";
        switch (head) {
        case "cpu":
            return Translation.tr("Utilization");
        case "memory":
            return Translation.tr("In use · %1 of %2").arg(SystemFacts.bytes(ResourceUsage.memoryUsed * 1024)).arg(SystemFacts.bytes(root.sys.memory.total));
        case "gpu": {
            if (!root.gpuOwnsLiveNumbers(name))
                return Translation.tr("No live counters for this chip");
            if (HardwareStats.gpuLoad >= 0 && HardwareStats.gpuClockMhz > 0)
                return Translation.tr("Busy · %1 MHz").arg(HardwareStats.gpuClockMhz.toFixed(0));
            return Translation.tr("Clock · max %1").arg(HardwareStats.gpuClockMaxMhz > 0 ? `${HardwareStats.gpuClockMaxMhz.toFixed(0)} MHz` : "—");
        }
        case "disk":
            return Translation.tr("Read + write");
        case "net":
            return Translation.tr("Down + up");
        case "battery":
            return Battery.isCharging ? Translation.tr("Charge · +%1 W").arg(Battery.energyRate.toFixed(1)) : Translation.tr("Charge · %1 W draw").arg(Battery.energyRate.toFixed(1));
        case "system":
            return Translation.tr("Uptime");
        default:
            return "";
        }
    }

    // The graph's window of time. Devices with no rate (system specs) return
    // an empty array -- the page shows a note instead of a fake chart.
    readonly property var pageHistory: {
        const head = root.selectedKey.indexOf(":") >= 0 ? root.selectedKey.slice(0, root.selectedKey.indexOf(":")) : root.selectedKey;
        const name = root.selectedKey.indexOf(":") >= 0 ? root.selectedKey.slice(root.selectedKey.indexOf(":") + 1) : "";
        switch (head) {
        case "cpu":
            return ResourceUsage.cpuUsageHistory;
        case "memory":
            return ResourceUsage.memoryUsageHistory;
        case "gpu":
            // That card's OWN curve, never another chip's: its busy history
            // when its driver publishes one, its clock history otherwise. A
            // chip this desktop keeps no counters for starts empty, which is
            // what the page's note is for.
            if (!root.gpuOwnsLiveNumbers(name))
                return [];
            return HardwareStats.gpuLoad >= 0
                ? (HardwareStats.gpuLoadHistory ?? []) : HardwareStats.gpuHistory;
        case "disk": {
            const d = HardwareStats.disks.find(x => x.name === name);
            return d?.history ?? [];
        }
        case "net": {
            const n = HardwareStats.networks.find(x => x.name === name);
            return n?.history ?? [];
        }
        case "battery":
            return root.powerHistory;
        default:
            return [];
        }
    }

    readonly property string pageGraphEmptyText: {
        const head = root.selectedKey.indexOf(":") >= 0 ? root.selectedKey.slice(0, root.selectedKey.indexOf(":")) : root.selectedKey;
        if (head === "system" || head === "battery" && root.powerHistory.length < 2)
            return Translation.tr("The last minute fills in as it happens");
        return Translation.tr("Collecting a minute of samples…");
    }

    // The rows under the graph. `live` rows carry the bolt and the numbers
    // font; the rest are facts, read once.
    readonly property var pageRows: {
        const head = root.selectedKey.indexOf(":") >= 0 ? root.selectedKey.slice(0, root.selectedKey.indexOf(":")) : root.selectedKey;
        const name = root.selectedKey.indexOf(":") >= 0 ? root.selectedKey.slice(root.selectedKey.indexOf(":") + 1) : "";
        const out = [];
        switch (head) {
        case "cpu": {
            const cpu = root.sys.cpu;
            out.push({ label: Translation.tr("Cores"), value: cpu.cores > 0 ? Translation.tr("%1 physical · %2 logical").arg(cpu.cores).arg(cpu.threads) : "" });
            out.push({ label: Translation.tr("Base – max clock"), value: cpu.maxMhz > 0 ? Translation.tr("%1 – %2 MHz").arg(cpu.minMhz).arg(cpu.maxMhz) : "" });
            out.push({ label: Translation.tr("Cache"), value: cpu.cache });
            out.push({ label: Translation.tr("Governor"), value: cpu.governor });
            out.push({ label: Translation.tr("Virtualisation"), value: cpu.flags ? Translation.tr("Virtual machine") : Translation.tr("Physical machine") });
            out.push({ label: Translation.tr("Load average"), value: root.loadAverageText(), live: true });
            break;
        }
        case "memory": {
            const mem = root.sys.memory;
            out.push({ label: Translation.tr("In use"), value: Translation.tr("%1 of %2 (%3%)").arg(SystemFacts.bytes(ResourceUsage.memoryUsed * 1024)).arg(SystemFacts.bytes(mem.total)).arg((ResourceUsage.memoryUsedPercentage * 100).toFixed(0)), live: true });
            out.push({ label: Translation.tr("Available"), value: SystemFacts.bytes(mem.available) });
            out.push({ label: Translation.tr("Cached + buffers"), value: SystemFacts.bytes(mem.cached + mem.buffers) });
            if (mem.swapTotal > 0) {
                out.push({ label: Translation.tr("Swap"), value: Translation.tr("%1 of %2 (%3%)").arg(SystemFacts.bytes(ResourceUsage.swapUsed * 1024)).arg(SystemFacts.bytes(mem.swapTotal)).arg((ResourceUsage.swapUsedPercentage * 100).toFixed(0)), live: true });
                out.push({ label: Translation.tr("Swap history"), value: Translation.tr("seen in the Memory graph at low level") });
            }
            break;
        }
        case "gpu": {
            const gpu = root.sys.gpus.find(g => g.name === name) ?? {};
            out.push({ label: Translation.tr("Driver"), value: gpu.driver ?? "" });
            out.push({ label: Translation.tr("PCI address"), value: gpu.pci ?? "" });
            out.push({ label: Translation.tr("Device ID"), value: gpu.deviceId ?? "" });
            {
                const live = root.gpuOwnsLiveNumbers(name) && HardwareStats.gpuClockMhz > 0;
                out.push({ label: Translation.tr("Clock"), value: live ? `${HardwareStats.gpuClockMhz.toFixed(0)} MHz` : "", live: live });
                if (root.gpuOwnsLiveNumbers(name) && HardwareStats.gpuLoad >= 0)
                    out.push({ label: Translation.tr("Load"), value: (HardwareStats.gpuLoad * 100).toFixed(0) + "%", live: true });
            }
            if (root.sys.temperatures.length > 0) {
                const t = root.sys.temperatures.find(x => /gpu|amdgpu|radeon|nouveau|nvidia/i.test(`${x.chip} ${x.label}`));
                if (t)
                    out.push({ label: Translation.tr("Temperature"), value: `${t.celsius.toFixed(1)} °C`, live: true });
            }
            break;
        }
        case "disk": {
            const d = root.sys.disks.find(x => x.name === name) ?? HardwareStats.disks.find(x => x.name === name) ?? {};
            out.push({ label: Translation.tr("Model"), value: d.model ?? "" });
            out.push({ label: Translation.tr("Size"), value: d.size > 0 ? SystemFacts.bytes(d.size) : "" });
            out.push({ label: Translation.tr("Type · bus"), value: root.join([d.type, d.bus]) });
            out.push({ label: Translation.tr("Mounted at"), value: (d.mounts ?? []).join(", ") });
            const live = HardwareStats.disks.find(x => x.name === name);
            if (live) {
                out.push({ label: Translation.tr("Reading"), value: HardwareStats.formatBytes(live.readBps), live: true });
                out.push({ label: Translation.tr("Writing"), value: HardwareStats.formatBytes(live.writeBps), live: true });
            }
            break;
        }
        case "net": {
            const net = root.sys.networks.find(x => x.name === name) ?? {};
            out.push({ label: Translation.tr("Kind"), value: net.type === "wifi" ? Translation.tr("Wireless") : Translation.tr("Wired") });
            out.push({ label: Translation.tr("State"), value: net.state ?? "", live: true });
            out.push({ label: Translation.tr("Link speed"), value: net.speedMbps > 0 ? Translation.tr("%1 Mb/s").arg(net.speedMbps) : "" });
            out.push({ label: Translation.tr("MAC"), value: net.mac ?? "" });
            const ips = root.join([...(net.ipv4 ?? []), ...(net.ipv6 ?? [])]);
            out.push({ label: Translation.tr("Addresses"), value: ips, live: true });
            const live = HardwareStats.networks.find(x => x.name === name);
            if (live) {
                out.push({ label: Translation.tr("Receiving"), value: HardwareStats.formatBytes(live.rxBps), live: true });
                out.push({ label: Translation.tr("Sending"), value: HardwareStats.formatBytes(live.txBps), live: true });
            }
            break;
        }
        case "battery": {
            if (!Battery.available)
                break;
            const b = root.sys.batteries[0] ?? {};
            out.push({ label: Translation.tr("Charge"), value: `${Math.round(Battery.percentage * 100)}%`, live: true });
            out.push({ label: Translation.tr("State"), value: Battery.isCharging ? Translation.tr("Charging") : (Battery.isPluggedIn ? Translation.tr("Plugged in") : Translation.tr("Discharging")), live: true });
            out.push({ label: Translation.tr("Power draw"), value: `${Battery.energyRate.toFixed(1)} W`, live: true });
            out.push({ label: Translation.tr("Time remaining"), value: Battery.isCharging ? root.fmtTime(Battery.timeToFull) : root.fmtTime(Battery.timeToEmpty), live: true });
            out.push({ label: Translation.tr("Stored energy"), value: Battery.energy > 0 ? Translation.tr("%1 of %2 Wh").arg(Battery.energy.toFixed(1)).arg(Battery.energyCapacity.toFixed(1)) : "" });
            if (b.energyFullDesign > 0) {
                const healthPct = Math.round((b.energyFull / b.energyFullDesign) * 100);
                out.push({ label: Translation.tr("Health"), value: Translation.tr("%1 of %2 Wh · %3%").arg(SystemFacts.wattHours(b.energyFull)).arg(SystemFacts.wattHours(b.energyFullDesign)).arg(healthPct) });
            }
            out.push({ label: Translation.tr("Cycle count"), value: (b.cycles ?? -1) >= 0 || Battery.cycles >= 0 ? Translation.tr("%1 cycles").arg(b.cycles >= 0 ? b.cycles : Battery.cycles) : "" });
            out.push({ label: Translation.tr("Technology"), value: b.technology ?? "" });
            out.push({ label: Translation.tr("Manufacturer"), value: root.join([b.manufacturer, b.model]) });
            break;
        }
        case "system": {
            const s = root.sys.system;
            out.push({ label: Translation.tr("Device"), value: root.join([s.vendor, s.model]) });
            out.push({ label: Translation.tr("Hostname"), value: s.hostname });
            out.push({ label: Translation.tr("Operating system"), value: s.os });
            out.push({ label: Translation.tr("Kernel"), value: s.kernel });
            out.push({ label: Translation.tr("Architecture"), value: s.arch });
            out.push({ label: Translation.tr("Firmware"), value: root.join([s.bootMode, s.bios]) });
            out.push({ label: Translation.tr("Session"), value: s.desktop ? `${s.desktop} (${s.session})` : s.session });
            out.push({ label: Translation.tr("Shell"), value: s.shell });
            out.push({ label: Translation.tr("Uptime"), value: s.uptime > 0 ? SystemFacts.uptime(s.uptime) : "", live: true });
            if (root.sys.temperatures.length > 0) {
                const hottest = root.sys.temperatures.reduce((a, b) => (b.celsius > a.celsius ? b : a));
                out.push({ label: Translation.tr("Hottest sensor"), value: `${hottest.chip} · ${hottest.label} — ${hottest.celsius.toFixed(1)} °C`, live: true });
            }
            break;
        }
        }
        return out;
    }

    FileView {
        id: loadFile
        path: "/proc/loadavg"
    }
    function loadAverageText() {
        const text = String(loadFile.text() ?? "").trim();
        if (text.length === 0)
            return "";
        return text.split(" ").slice(0, 3).join(" · ");
    }
}
