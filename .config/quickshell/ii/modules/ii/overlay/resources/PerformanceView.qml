pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import qs.services
import qs.modules.common
import qs.modules.common.widgets

/**
 * Performance: one piece of hardware at a time, with its graph and its numbers.
 *
 * The list down the left is every device the machine actually has, rebuilt from
 * live services rather than from a fixed list of three, and the right-hand side
 * is whatever is selected. Nothing is behind a menu, so the answer to "what is
 * using the disk" is one click from here rather than a rediscovery of the UI.
 *
 * Under the graph sits what the device *is* -- the processor's real name, the
 * disk's model and size, the interface's address -- because a graph tells you
 * how hard something is working and never tells you what it is working on.
 */
ColumnLayout {
    id: root
    spacing: 8

    // Which device is being shown. Persisted, because it is a preference rather
    // than a transient state -- if you always want to see the disk, you should not
    // have to re-pick it every time the card comes back.
    property string selectedKey: Persistent.states.overlay.resources.selectedKey ?? "cpu"

    // Somebody asked for one specific device -- the settings app's Overview tiles
    // do, so that "click the RAM tile" lands on the RAM row rather than wherever
    // the card was left last time. A device this machine does not have is ignored
    // rather than honoured blindly, so the pane can never land on nothing.
    function revealDevice(key) {
        if (!key || key.length === 0)
            return;
        if (root.devices.some(device => device.key === key))
            root.select(key);
    }

    readonly property var devices: {
        const _revision = HardwareStats.revision;   // re-evaluate on every sample
        const list = [];

        list.push({
            key: "cpu",
            icon: "planner_review",
            name: Translation.tr("CPU"),
            headline: (ResourceUsage.cpuUsage * 100).toFixed(0) + "%",
            caption: Translation.tr("of %1").arg(ResourceUsage.maxAvailableCpuString),
            detail: ResourceUsage.maxAvailableCpuString === "--"
                ? Translation.tr("Processor")
                : [HardwareStats.cpuName, HardwareStats.cpuThreads > 0 ? Translation.tr("%1 threads").arg(HardwareStats.cpuThreads) : "", HardwareStats.cpuMaxFreq].filter(part => part !== "").join(" · "),
            spec: root.cpuSpec(),
            history: ResourceUsage.cpuUsageHistory
        });

        list.push({
            key: "memory",
            icon: "memory",
            name: Translation.tr("RAM"),
            headline: (ResourceUsage.memoryUsedPercentage * 100).toFixed(0) + "%",
            caption: Translation.tr("of %1").arg(ResourceUsage.maxAvailableMemoryString),
            detail: Translation.tr("%1 in use, %2 free").arg(ResourceUsage.kbToGbString(ResourceUsage.memoryUsed)).arg(ResourceUsage.kbToGbString(ResourceUsage.memoryFree)),
            spec: root.memorySpec(),
            history: ResourceUsage.memoryUsageHistory
        });

        if (ResourceUsage.swapTotal > 1024) {
            list.push({
                key: "swap",
                icon: "swap_horiz",
                name: Translation.tr("Swap"),
                headline: (ResourceUsage.swapUsedPercentage * 100).toFixed(0) + "%",
                caption: Translation.tr("of %1").arg(ResourceUsage.maxAvailableSwapString),
                detail: Translation.tr("%1 in use").arg(ResourceUsage.kbToGbString(ResourceUsage.swapUsed)),
                spec: SystemFacts.memory.swapTotal > 0
                    ? Translation.tr("%1 on disk").arg(SystemFacts.bytes(SystemFacts.memory.swapTotal))
                    : "",
                history: ResourceUsage.swapUsageHistory
            });
        }

        for (const gpu of root.gpuNames()) {
            // The clock belongs to ONE card. gt_cur_freq_mhz is an Intel iGPU
            // file, and attaching its number to every GPU row made the idle
            // dGPU show the iGPU's live clock as its own -- on this Blade the
            // 4070 (which drives nothing) read "1517 MHz" while actually
            // sitting at 0% with no processes. Only the row whose PCI address
            // matches the clock file's card gets the live number; the rest
            // say they are idle, which is the truth.
            const clockIsFor = root.gpuClockCardPci();
            const gpuPci = (SystemFacts.gpus.find(entry => entry.name === gpu) ?? {}).pci ?? "";
            const hasClock = HardwareStats.gpuClockMhz > 0
                && (clockIsFor === "" || gpuPci === "" || clockIsFor === gpuPci);
            list.push({
                key: "gpu:" + gpu,
                // `developer_board` is the chip-and-traces glyph. (There is no
                // `videocard` in Material Symbols -- naming one that does not
                // exist draws the letters themselves, which is what made this row
                // render as an oversized "VIDEOCARD" and clip its own number.)
                icon: "developer_board",
                name: Translation.tr("Graphics"),
                headline: hasClock ? HardwareStats.gpuClockMhz.toFixed(0) + " MHz" : Translation.tr("idle"),
                caption: hasClock
                    ? (HardwareStats.gpuClockMaxMhz > 0 ? Translation.tr("of %1 MHz").arg(HardwareStats.gpuClockMaxMhz.toFixed(0)) : Translation.tr("clock"))
                    : Translation.tr("no processes"),
                detail: gpu,
                spec: root.gpuSpec(gpu),
                history: hasClock ? HardwareStats.gpuHistory : []
            });
        }

        for (const disk of HardwareStats.disks) {
            list.push({
                key: "disk:" + disk.name,
                icon: disk.name.startsWith("nvme") ? "hard_disk" : "storage",
                name: disk.name,
                headline: HardwareStats.formatBytes(Math.max(disk.readBps, disk.writeBps)),
                caption: Translation.tr("read %1 · write %2").arg(HardwareStats.formatBytes(disk.readBps)).arg(HardwareStats.formatBytes(disk.writeBps)),
                detail: [disk.model, disk.size].filter(part => part !== "").join(" · "),
                spec: root.diskSpec(disk.name),
                history: disk.history
            });
        }

        for (const net of HardwareStats.networks) {
            list.push({
                key: "net:" + net.name,
                icon: net.name.startsWith("wl") || net.name.startsWith("mlan") ? "wifi" : "lan",
                name: net.name,
                headline: HardwareStats.formatBytes(net.rxBps),
                caption: Translation.tr("down · %1 up").arg(HardwareStats.formatBytes(net.txBps)),
                detail: Translation.tr("Network interface"),
                spec: root.networkSpec(net.name),
                history: net.history
            });
        }

        return list;
    }

    readonly property var selected: {
        const _revision = HardwareStats.revision;
        const key = root.selectedKey;
        return root.devices.find(device => device.key === key) ?? root.devices[0] ?? null;
    }

    function select(key) {
        root.selectedKey = key;
        Persistent.states.overlay.resources.selectedKey = key;
    }

    // ── What each device is ──────────────────────────────────────────────────
    // Read from SystemFacts, which reads the machine once, rather than from the
    // sampling services, which only know how busy it is.
    readonly property var gpuNamesList: {
        const _ = SystemFacts.facts;
        return SystemFacts.gpus.map(gpu => gpu.name).filter(name => name !== "");
    }
    function gpuNames() {
        // HardwareStats' inventory is what the sampling side actually has a clock
        // for; fall back to the facts when the driver exposes no clock at all.
        return HardwareStats.gpuNames.length > 0 ? HardwareStats.gpuNames : root.gpuNamesList;
    }

    function join(parts) {
        return parts.filter(part => part && String(part).length > 0).join(" · ");
    }

    function cpuSpec() {
        const cpu = SystemFacts.cpu;
        if (!cpu.model)
            return "";
        return root.join([
            cpu.model,
            cpu.cores > 0 ? Translation.tr("%1 cores / %2 threads").arg(cpu.cores).arg(cpu.threads) : "",
            cpu.cache.length > 0 ? Translation.tr("%1 cache").arg(cpu.cache) : "",
            cpu.maxMhz > 0 ? Translation.tr("%1–%2 MHz").arg(cpu.minMhz).arg(cpu.maxMhz) : "",
            cpu.governor.length > 0 ? Translation.tr("governor %1").arg(cpu.governor) : ""
        ]);
    }

    function memorySpec() {
        const memory = SystemFacts.memory;
        if (!memory.total)
            return "";
        return root.join([
            Translation.tr("%1 total").arg(SystemFacts.bytes(memory.total)),
            Translation.tr("%1 cached").arg(SystemFacts.bytes(memory.cached + memory.buffers))
        ]);
    }

    function gpuSpec(name) {
        const gpu = SystemFacts.gpus.find(entry => entry.name === name) ?? SystemFacts.gpus[0];
        if (!gpu)
            return "";
        return root.join([
            gpu.driver,
            gpu.pci ? Translation.tr("PCI %1").arg(gpu.pci) : "",
            gpu.deviceId ? Translation.tr("device %1").arg(gpu.deviceId) : ""
        ]);
    }

    // Which PCI device the live clock file belongs to. gt_cur_freq_mhz is an
    // Intel/AMD sysfs file -- NVIDIA cards never have one -- so the clock
    // belongs to the first non-nvidia GPU in the facts list. Empty when
    // there is no such GPU (the caller then keeps the clock on every row).
    function gpuClockCardPci() {
        const gpus = SystemFacts.gpus;
        const nonNvidia = gpus.find(g => String(g.driver ?? "") !== "nvidia");
        return nonNvidia ? String(nonNvidia.pci ?? "") : "";
    }

    function diskSpec(name) {
        const disk = SystemFacts.disks.find(entry => entry.name === name);
        if (!disk)
            return "";
        return root.join([
            disk.model,
            SystemFacts.bytes(disk.size),
            disk.type,
            disk.bus,
            disk.mounts.length > 0 ? Translation.tr("mounted at %1").arg(disk.mounts.join(", ")) : ""
        ]);
    }

    function networkSpec(name) {
        const net = SystemFacts.networks.find(entry => entry.name === name);
        if (!net)
            return "";
        return root.join([
            net.type === "wifi" ? Translation.tr("Wireless") : Translation.tr("Wired"),
            net.connected ? Translation.tr("connected") : Translation.tr("disconnected"),
            net.ipv4.length > 0 ? net.ipv4.join(", ") : "",
            net.mac,
            net.driver
        ]);
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: 8

        // ── Hardware list ────────────────────────────────────────────────
        // StyledFlickable: kinetic wheel scrolling instead of raw steps.
        StyledFlickable {
            Layout.fillHeight: true
            Layout.preferredWidth: 196
            contentHeight: deviceColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: StyledScrollBar {}

            ColumnLayout {
                id: deviceColumn
                width: parent.width
                spacing: 2

                Repeater {
                    model: root.devices
                    delegate: RippleButton {
                        id: deviceRow
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: 36
                        // A row highlight, not a pill: the smallest radius the
                        // theme has (8, against a 36px row -- a stadium would be
                        // 18), and the button box *is* the row box, so the fill
                        // has exactly the icon, the label and the number inside
                        // it and nothing else.
                        buttonRadius: Appearance.rounding.verysmall
                        colBackground: "transparent"
                        colBackgroundHover: Appearance.colors.colLayer2Hover
                        colBackgroundToggled: Appearance.colors.colSecondaryContainer
                        colBackgroundToggledHover: Appearance.colors.colSecondaryContainerHover
                        toggled: root.selectedKey === deviceRow.modelData.key
                        onClicked: root.select(deviceRow.modelData.key)

                        contentItem: RowLayout {
                            anchors {
                                fill: parent
                                leftMargin: 8
                                rightMargin: 8
                            }
                            spacing: 8

                            MaterialSymbol {
                                Layout.alignment: Qt.AlignVCenter
                                text: deviceRow.modelData.icon
                                iconSize: 17
                                color: deviceRow.toggled ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                            }
                            StyledText {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignVCenter
                                text: deviceRow.modelData.name
                                elide: Text.ElideMiddle
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: deviceRow.toggled ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                            }
                            StyledText {
                                Layout.alignment: Qt.AlignVCenter
                                text: deviceRow.modelData.headline
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: deviceRow.toggled ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colSubtext
                            }
                        }
                    }
                }
            }
        }

        Rectangle {
            Layout.fillHeight: true
            Layout.preferredWidth: 1
            color: Appearance.colors.colOutlineVariant
        }

        // ── The selected device ──────────────────────────────────────────
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 6

            StyledText {
                Layout.fillWidth: true
                text: root.selected?.name ?? ""
                font.pixelSize: Appearance.font.pixelSize.normal
                color: Appearance.colors.colOnLayer1
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                StyledText {
                    text: root.selected?.headline ?? "—"
                    font {
                        family: Appearance.font.family.numbers
                        variableAxes: Appearance.font.variableAxes.numbers
                        pixelSize: Appearance.font.pixelSize.large
                    }
                    color: Appearance.colors.colPrimary
                }
                StyledText {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignBottom
                    Layout.bottomMargin: 3
                    text: root.selected?.caption ?? ""
                    font.pixelSize: Appearance.font.pixelSize.smallie
                    color: Appearance.colors.colSubtext
                    elide: Text.ElideRight
                }
            }

            StyledText {
                Layout.fillWidth: true
                text: root.selected?.detail ?? ""
                font.pixelSize: Appearance.font.pixelSize.smallie
                color: Appearance.colors.colSubtext
                elide: Text.ElideRight
                maximumLineCount: 2
                wrapMode: Text.Wrap
            }

            Rectangle {
                id: graphBg
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.topMargin: 2
                radius: Appearance.rounding.small
                color: Appearance.colors.colSecondaryContainer
                layer.enabled: true
                layer.effect: OpacityMask {
                    maskSource: Rectangle {
                        width: graphBg.width
                        height: graphBg.height
                        radius: graphBg.radius
                    }
                }

                Graph {
                    anchors.fill: parent
                    values: root.selected?.history ?? []
                    points: ResourceUsage.historyLength
                    alignment: Graph.Alignment.Right
                }

                StyledText {
                    anchors.centerIn: parent
                    visible: (root.selected?.history?.length ?? 0) < 3
                    text: Translation.tr("Collecting samples…")
                    font.pixelSize: Appearance.font.pixelSize.smallie
                    color: Appearance.colors.colSubtext
                }
            }

            // What the device is. The graph above says how hard it is working;
            // this says what "it" is.
            StyledText {
                Layout.fillWidth: true
                visible: (root.selected?.spec ?? "").length > 0
                text: root.selected?.spec ?? ""
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colSubtext
                wrapMode: Text.Wrap
            }
        }
    }
}
