pragma Singleton

import qs.services
import qs.modules.common
import Quickshell
import Quickshell.Services.UPower
import QtQuick
import Quickshell.Io

Singleton {
    id: root
    property bool available: UPower.displayDevice.isLaptopBattery
    property var chargeState: UPower.displayDevice.state
    property bool isCharging: chargeState == UPowerDeviceState.Charging
    // "On AC" is what the bolt means: charging, holding at the firmware
    // charge cap (pending-charge), or full on cable. A strict Charging-only
    // map left the bolt hidden whenever the capped battery simply floats at
    // its target while plugged in.
    property bool isPluggedIn: isCharging || chargeState == UPowerDeviceState.PendingCharge
        || chargeState == UPowerDeviceState.FullyCharged
    // ── Percentage, straight from the kernel ─────────────────────────────────
    // UPower owns the battery's *state*, but its percentage only reaches us when
    // UPower feels like re-publishing it, and that lag is what made the number in
    // the bar sit still for seconds after it had actually changed. The kernel's own
    // counter is watchable, so it is read directly and preferred whenever it is
    // there -- UPower stays the fallback for machines that expose no such file.
    // Which pack to read. This used to be hardcoded to BAT1, which is right for
    // some machines and silently wrong for the rest: this laptop exposes BAT0,
    // so the "preferred" sysfs counter never loaded at all and every
    // percentage quietly came from the UPower fallback instead -- the code
    // below could not tell the difference because a failed read just sets
    // sysfsPercentage to -1.
    //
    // The pack is therefore resolved at runtime: the first BAT* node wins.
    // Reading it through a Process keeps the FileView on a path that is known
    // to exist, so its error handling still means what it says.
    readonly property string sysfsBatteryPath: _batteryPath
    property string _batteryPath: ""

    Process {
        id: findBattery
        command: ["bash", "-c",
            "for d in /sys/class/power_supply/BAT*/; do "
          + "  [ -r \"${d}capacity\" ] || continue; "
          + "  echo \"${d%/}\"; break; done"]
        stdout: StdioCollector {
            onStreamFinished: {
                const found = (text ?? "").trim();
                root._batteryPath = found.length > 0 ? found : "/sys/class/power_supply/BAT1";
            }
        }
    }

    readonly property string sysfsCapacityPath:
        root.sysfsBatteryPath + "/capacity"
    property real sysfsPercentage: -1

    FileView {
        id: capacityFile
        path: root.sysfsCapacityPath
        watchChanges: true
        blockLoading: true
        printErrors: false

        function apply() {
            const value = parseInt(text().trim(), 10);
            root.sysfsPercentage = isNaN(value) ? -1 : value / 100;
        }

        onLoaded: apply()
        onTextChanged: apply()
        onLoadFailed: root.sysfsPercentage = -1
    }

    // Belt and braces: not every kernel delivers change notifications for sysfs
    // attributes, so the file is also re-read on a short timer. Two seconds is
    // comfortably inside "instant" while costing one file read.
    Timer {
        interval: 2000
        running: root.available
        repeat: true
        onTriggered: capacityFile.reload()
    }

    readonly property real upowerPercentage: UPower.displayDevice?.percentage ?? -1
    // Which percentage to believe. The kernel counter is preferred (see above),
    // but a fuel gauge can go stale while the machine keeps running on fumes --
    // the bar said 50% once and the laptop died moments later. When UPower, which
    // samples the battery through its own polls, meaningfully disagrees DOWNWARD,
    // take the pessimistic number: overestimating costs nothing, underestimating
    // costs an unsaved session. UPower reading higher is ignored -- that is just
    // its slightly slower update cadence.
    readonly property real percentage: {
        if (root.sysfsPercentage >= 0) {
            if (root.upowerPercentage >= 0 && root.upowerPercentage < root.sysfsPercentage - 0.05)
                return root.upowerPercentage;
            return root.sysfsPercentage;
        }
        return root.upowerPercentage >= 0 ? root.upowerPercentage : 1;
    }
    readonly property bool allowAutomaticSuspend: Config.options.battery.automaticSuspend
    readonly property bool soundEnabled: Config.options.sounds.battery

    property bool isLow: available && (percentage <= Config.options.battery.low / 100)
    property bool isCritical: available && (percentage <= Config.options.battery.critical / 100)
    property bool isSuspending: available && (percentage <= Config.options.battery.suspend / 100)
    property bool isFull: available && (percentage >= Config.options.battery.full / 100)

    property bool isLowAndNotCharging: isLow && !isCharging
    property bool isCriticalAndNotCharging: isCritical && !isCharging
    property bool isSuspendingAndNotCharging: allowAutomaticSuspend && isSuspending && !isCharging
    property bool isFullAndCharging: isFull && isCharging

    property real energyRate: UPower.displayDevice.changeRate
    property real timeToEmpty: UPower.displayDevice.timeToEmpty
    property real timeToFull: UPower.displayDevice.timeToFull

    // Absolute energy numbers for the battery detail popup: what is in the
    // tank right now and the size of the tank as the fuel gauge currently
    // believes it (watt-hours, from UPower). The design capacity is derived
    // from health, which UPower computes against it.
    readonly property real energy: UPower.displayDevice?.energy ?? 0
    readonly property real energyCapacity: UPower.displayDevice?.energyCapacity ?? 0
    readonly property real energyDesign: health > 0 ? energyCapacity / (health / 100) : 0

    // Charge cycles as the fuel gauge counts them (sysfs; UPower does not
    // expose cycle_count). -1 when the kernel does not provide the file.
    property int cycles: -1
    FileView {
        id: cyclesFile
        path: "/sys/class/power_supply/BAT1/cycle_count"
        watchChanges: false
        blockLoading: false
        printErrors: false
        onLoaded: {
            const value = parseInt(text().trim(), 10);
            root.cycles = isNaN(value) ? -1 : value;
        }
        onLoadFailed: root.cycles = -1
    }
    Timer {
        interval: 30000
        running: root.available
        repeat: true
        triggeredOnStart: true
        onTriggered: cyclesFile.reload()
    }

    property real health: (function() {
        const devList = UPower.devices.values;
        for (let i = 0; i < devList.length; ++i) {
            const dev = devList[i];
            if (dev.isLaptopBattery && dev.healthSupported) {
                const health = dev.healthPercentage;
                if (health === 0) {
                    return 0.01;
                } else if (health < 1) {
                    return health * 100;
                } else {
                    return health;
                }
            }
        }
        return 0;
    })()


    // (cycle_count is re-read by the Timer above)

    onIsLowAndNotChargingChanged: {
        if (!root.available || !isLowAndNotCharging) return;
        // The corner notification is replaced by the bar itself: the same
        // "Low battery" words in the extended island, the same warning sound
        // (the freedesktop message chime -- the notification daemon's own),
        // and the under-bar line blinking red twice. Nothing enters the
        // notification history.
        Notifications.playNotificationSound(null);
        StatusSignal.batteryAlert("Low battery", 2);
    }

    onIsCriticalAndNotChargingChanged: {
        if (!root.available || !isCriticalAndNotCharging) return;
        // Same treatment, one level up: longer text, the harsher sound the
        // old path used, and three red blinks.
        if (root.soundEnabled) Audio.playSystemSound("suspend-error");
        StatusSignal.batteryAlert("Critically low battery", 3);
    }

    onIsSuspendingAndNotChargingChanged: {
        if (root.available && isSuspendingAndNotCharging) {
            Quickshell.execDetached(["bash", "-c", `systemctl suspend || loginctl suspend`]);
        }
    }

    onIsFullAndChargingChanged: {
        if (!root.available || !isFullAndCharging) return;
        Quickshell.execDetached([
            "notify-send",
            Translation.tr("Battery full"),
            Translation.tr("Please unplug the charger"),
            "-a", "Shell",
            "--hint=int:transient:1",
        ]);

        if (root.soundEnabled) Audio.playSystemSound("complete");
    }

    onIsPluggedInChanged: {
        if (!root.available || !root.soundEnabled) return;
        if (isPluggedIn) {
            Audio.playSystemSound("power-plug")
        } else {
            Audio.playSystemSound("power-unplug")
        }
    }
}
