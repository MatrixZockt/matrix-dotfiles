pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.widgets

/**
 * Hardware: what this machine is, down to the model numbers.
 *
 * The performance view answers "how busy is it" and this one answers "what is
 * it", which are different questions and deserve different pages. Everything
 * here comes from `SystemFacts` (one read of /sys, /proc and a handful of
 * commands at startup), so a page that lists seventeen facts costs nothing to
 * look at, and nothing here is guessed: a field the kernel does not expose is
 * left out rather than filled with "Unknown".
 *
 * Nothing is behind a disclosure triangle. The reason to open this page is to
 * find one line -- the disk model, the driver, the battery's cycle count -- and a
 * page where every section starts collapsed makes that a hunt.
 */
StyledFlickable {
    id: root

    contentWidth: width
    contentHeight: column.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: StyledScrollBar {}

    // Section headings and their rows, built from SystemFacts. Each entry is
    // { title, icon, rows: [{ label, value, live }] } -- a plain description of
    // the page, so the drawing code below is one repeater rather than nine.
    readonly property var sections: {
        const _ = SystemFacts.facts;
        const out = [];

        const system = SystemFacts.system;
        out.push({
            title: Translation.tr("System"),
            icon: "laptop_mac",
            rows: [
                { label: Translation.tr("Device"), value: root.join([system.vendor, system.model]) },
                { label: Translation.tr("Hostname"), value: system.hostname },
                { label: Translation.tr("Operating system"), value: system.os },
                { label: Translation.tr("Kernel"), value: system.kernel },
                { label: Translation.tr("Architecture"), value: system.arch },
                { label: Translation.tr("Firmware"), value: root.join([system.bootMode, system.bios]) },
                { label: Translation.tr("Session"), value: system.desktop ? `${system.desktop} (${system.session})` : system.session },
                { label: Translation.tr("Shell"), value: system.shell },
                { label: Translation.tr("Uptime"), value: SystemFacts.uptime(system.uptime), live: true }
            ]
        });

        const cpu = SystemFacts.cpu;
        if (cpu.model) {
            out.push({
                title: Translation.tr("Processor"),
                icon: "developer_board",
                rows: [
                    { label: Translation.tr("Model"), value: cpu.model },
                    { label: Translation.tr("Cores"), value: cpu.cores > 0 ? Translation.tr("%1 physical · %2 logical").arg(cpu.cores).arg(cpu.threads) : "" },
                    { label: Translation.tr("Cache"), value: cpu.cache },
                    { label: Translation.tr("Frequency"), value: cpu.maxMhz > 0 ? Translation.tr("%1 – %2 MHz").arg(cpu.minMhz).arg(cpu.maxMhz) : "" },
                    { label: Translation.tr("Governor"), value: cpu.governor },
                    { label: Translation.tr("Virtualisation"), value: cpu.flags ? Translation.tr("Virtual machine") : Translation.tr("Physical machine") },
                    { label: Translation.tr("Usage"), value: (ResourceUsage.cpuUsage * 100).toFixed(0) + "%", live: true },
                    { label: Translation.tr("Load average"), value: root.loadAverage() }
                ]
            });
        }

        const memory = SystemFacts.memory;
        if (memory.total) {
            out.push({
                title: Translation.tr("Memory"),
                icon: "memory",
                rows: [
                    { label: Translation.tr("Installed"), value: SystemFacts.bytes(memory.total) },
                    { label: Translation.tr("In use"), value: Translation.tr("%1 (%2%)").arg(SystemFacts.bytes(ResourceUsage.memoryUsed * 1024)).arg((ResourceUsage.memoryUsedPercentage * 100).toFixed(0)), live: true },
                    { label: Translation.tr("Available"), value: SystemFacts.bytes(memory.available) },
                    { label: Translation.tr("Cached"), value: SystemFacts.bytes(memory.cached + memory.buffers) },
                    { label: Translation.tr("Swap"), value: memory.swapTotal > 0 ? Translation.tr("%1 of %2").arg(SystemFacts.bytes(ResourceUsage.swapUsed * 1024)).arg(SystemFacts.bytes(memory.swapTotal)) : Translation.tr("none"), live: memory.swapTotal > 0 }
                ]
            });
        }

        if (SystemFacts.gpus.length > 0) {
            // The live clock (gt_cur_freq_mhz) is an Intel/AMD sysfs file and
            // belongs to the iGPU; showing it on the idle NVIDIA row read as
            // "the dGPU is running at 1517 MHz" while it was at 0%. The row
            // whose driver has no clock file reports itself as idle.
            const clockPci = (() => {
                const nonNvidia = SystemFacts.gpus.find(g => String(g.driver ?? "") !== "nvidia");
                return nonNvidia ? String(nonNvidia.pci ?? "") : "";
            })();
            out.push({
                title: Translation.tr("Graphics"),
                icon: "videocam",
                rows: SystemFacts.gpus.map(gpu => ({
                    label: gpu.name,
                    value: String(gpu.pci ?? "") === clockPci
                        ? root.gpuValue(gpu)
                        : root.join([gpu.driver, Translation.tr("idle — no processes")])
                }))
            });
        }

        if (SystemFacts.disks.length > 0) {
            out.push({
                title: Translation.tr("Storage"),
                icon: "hard_disk",
                rows: SystemFacts.disks.map(disk => ({
                    label: disk.name,
                    value: root.join([disk.model, SystemFacts.bytes(disk.size), disk.type, disk.bus])
                        + (disk.mounts.length > 0 ? ` · ${disk.mounts.join(", ")}` : "")
                }))
            });
        }

        if (SystemFacts.networks.length > 0) {
            out.push({
                title: Translation.tr("Network"),
                icon: "lan",
                rows: SystemFacts.networks.map(net => ({
                    label: net.name,
                    value: root.join([
                        net.type === "wifi" ? Translation.tr("Wireless") : Translation.tr("Wired"),
                        net.state,
                        net.speedMbps > 0 ? Translation.tr("%1 Mb/s").arg(net.speedMbps) : "",
                        net.mac
                    ]) + root.addresses(net)
                }))
            });
        }

        if (SystemFacts.batteries.length > 0) {
            const batteryRows = [];
            for (const battery of SystemFacts.batteries) {
                batteryRows.push({ label: Translation.tr("%1 model").arg(battery.name), value: root.join([battery.manufacturer, battery.model]) });
                batteryRows.push({ label: Translation.tr("%1 charge").arg(battery.name), value: `${battery.capacity}%`, live: true });
                // The number people actually want: what the battery holds now
                // against what it was built to hold.
                batteryRows.push({
                    label: Translation.tr("%1 capacity").arg(battery.name),
                    value: root.join([
                        battery.energyFullDesign > 0
                            ? Translation.tr("%1 of %2 (%3%)").arg(SystemFacts.wattHours(battery.energyFull)).arg(SystemFacts.wattHours(battery.energyFullDesign)).arg(Math.round((battery.energyFull / battery.energyFullDesign) * 100))
                            : SystemFacts.wattHours(battery.energyFull),
                        battery.cycles >= 0 ? Translation.tr("%1 cycles").arg(battery.cycles) : "",
                        battery.technology
                    ])
                });
            }
            out.push({
                title: Translation.tr("Battery"),
                icon: "battery_full",
                rows: batteryRows
            });
        }

        if (SystemFacts.temperatures.length > 0) {
            out.push({
                title: Translation.tr("Sensors"),
                icon: "thermometer",
                rows: SystemFacts.temperatures.map(sensor => ({
                    label: `${sensor.chip} · ${sensor.label}`,
                    value: `${sensor.celsius.toFixed(1)} °C`
                }))
            });
        }

        const displays = SystemFacts.displays;
        if (displays.length > 0) {
            out.push({
                title: Translation.tr("Display"),
                icon: "monitor",
                rows: displays.map(display => ({
                    label: display.name,
                    value: display.connected
                        ? root.join([display.modes[0] ?? "", display.enabled ? Translation.tr("enabled") : Translation.tr("disabled")])
                        : Translation.tr("not connected")
                }))
            });
        }

        return out;
    }

    function join(parts) {
        return (parts ?? []).filter(part => part && String(part).trim().length > 0).join(" · ");
    }

    // Scroll the list so the named section heading is at the top. Answers true
    // when it happened (or can never happen -- an unknown title), false while
    // the sections are still being laid out; the deep-link caller retries
    // briefly on false. Works wherever this view is hosted: the overlay card
    // and the standalone task manager app both use it.
    function scrollToSection(title) {
        if (!title || title.length === 0)
            return true;
        for (let i = 0; i < column.children.length; i++) {
            const child = column.children[i];
            if (child.sectionTitle === title || child.modelData?.title === title) {
                root.contentY = Math.max(0, child.y - 4);
                return true;
            }
        }
        // Unknown title: never going to match, don't leave the caller retrying.
        const known = root.sections.some(section => section.title === title);
        return known ? false : true;
    }

    function addresses(net) {
        const parts = [];
        if ((net.ipv4 ?? []).length > 0)
            parts.push(net.ipv4.join(", "));
        if ((net.ipv6 ?? []).length > 0)
            parts.push(net.ipv6.join(", "));
        return parts.length > 0 ? ` · ${parts.join(" · ")}` : "";
    }

    function gpuValue(gpu) {
        const parts = [gpu.driver];
        if (gpu.pci)
            parts.push(Translation.tr("PCI %1").arg(gpu.pci));
        if (gpu.deviceId)
            parts.push(Translation.tr("device %1").arg(gpu.deviceId));
        if (HardwareStats.gpuClockMhz > 0)
            parts.push(`${HardwareStats.gpuClockMhz.toFixed(0)} MHz`);
        return root.join(parts);
    }

    // Straight from /proc/loadavg: the one number here that is not a fixed fact
    // and not something the services above already read.
    FileView {
        id: loadFile
        path: "/proc/loadavg"
    }
    function loadAverage() {
        const text = String(loadFile.text() ?? "").trim();
        if (text.length === 0)
            return "";
        const parts = text.split(" ");
        return parts.slice(0, 3).join(" · ");
    }

    ColumnLayout {
        id: column
        width: root.width
        spacing: 14

        Repeater {
            model: root.sections
            delegate: ColumnLayout {
                id: section
                required property var modelData
                Layout.fillWidth: true
                spacing: 2

                RowLayout {
                    Layout.fillWidth: true
                    Layout.bottomMargin: 2
                    spacing: 8

                    MaterialSymbol {
                        text: section.modelData.icon
                        iconSize: 17
                        color: Appearance.colors.colPrimary
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: section.modelData.title
                        font {
                            family: Appearance.font.family.title
                            pixelSize: Appearance.font.pixelSize.normal
                            variableAxes: Appearance.font.variableAxes.title
                        }
                        color: Appearance.colors.colOnLayer1
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        implicitHeight: 1
                        color: Appearance.colors.colOutlineVariant
                    }
                }

                Repeater {
                    model: section.modelData.rows
                    delegate: Rectangle {
                        id: specRow
                        required property var modelData
                        // Zebra striping needs the row number, and under Bound
                        // component semantics an unqualified `index` is a
                        // ReferenceError at runtime -- it threw for every row
                        // drawn (see the doctor's shell-log check).
                        required property int index
                        Layout.fillWidth: true
                        implicitHeight: Math.max(labelText.implicitHeight, valueText.implicitHeight) + 12
                        radius: Appearance.rounding.verysmall
                        color: specRow.index % 2 === 0 ? Appearance.colors.colLayer1 : "transparent"
                        // A row with no value is not a row: the kernel not
                        // exposing a field should leave a gap in the page, not a
                        // line that says nothing.
                        visible: (specRow.modelData.value ?? "").length > 0

                        RowLayout {
                            anchors {
                                fill: parent
                                leftMargin: 10
                                rightMargin: 10
                            }
                            spacing: 12

                            StyledText {
                                id: labelText
                                Layout.preferredWidth: 172
                                text: specRow.modelData.label ?? ""
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: Appearance.colors.colSubtext
                                elide: Text.ElideRight
                            }
                            StyledText {
                                id: valueText
                                Layout.fillWidth: true
                                text: specRow.modelData.value ?? ""
                                font {
                                    family: specRow.modelData.live ? Appearance.font.family.numbers : Appearance.font.family.main
                                    variableAxes: specRow.modelData.live ? Appearance.font.variableAxes.numbers : Appearance.font.variableAxes.main
                                    pixelSize: Appearance.font.pixelSize.smallie
                                }
                                color: Appearance.colors.colOnLayer1
                                elide: Text.ElideRight
                            }
                            MaterialSymbol {
                                visible: specRow.modelData.live ?? false
                                text: "bolt"
                                iconSize: 13
                                color: Appearance.colors.colPrimary
                            }
                        }
                    }
                }
            }
        }

        // Refusals and gaps, said out loud: a specs page that silently omits
        // something reads as broken, while a line that says the kernel would not
        // tell us reads as honest.
        StyledText {
            Layout.fillWidth: true
            Layout.topMargin: 2
            visible: !SystemFacts.ready
            text: SystemFacts.failed
                ? Translation.tr("Could not read the hardware facts — see the shell logs.")
                : Translation.tr("Reading the hardware inventory…")
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
        }
    }
}
