pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import QtQuick

/**
 * GpuPower — the discrete GPU's power POLICY, and what it is actually doing.
 *
 * WHAT THIS IS NOT
 * ----------------
 * It is not a way to unload the NVIDIA driver, and that is deliberate. On
 * this machine Hyprland is itself an nvidia client (`nvidia-smi` listed it
 * holding 39 MiB), `nvidia_drm` carries 22 references with modeset=Y, and the
 * `nvidia` module is held by `nvidia_uvm` + `nvidia_modeset`. Unloading it
 * would be refused, and forcing it would very likely hard-freeze the
 * compositor -- and because the driver would then be gone, it would NOT come
 * back when something needed it. That is the "the GPU won't start working
 * when needed" failure, and it is a reboot away. Nothing here touches the
 * module.
 *
 * WHAT IT ACTUALLY CONTROLS
 * -------------------------
 * The PCI runtime-power policy on the dGPU, /sys/.../power/control:
 *
 *   auto — the kernel MAY drop the card to a low-power state when nothing
 *          is using it. This is the "off" the switch offers.
 *   on   — never power down, so there is zero wake latency. This is the "on".
 *
 * Both are policy only. Neither suspends the card by itself.
 *
 * WHAT THE NUMBERS WILL (AND WON'T) SHOW
 * --------------------------------------
 * The card is already as low as it goes. With RTD3 and S0ix both enabled
 * (NVreg_DynamicPowerManagement=0x3, NVreg_EnableS0ixPowerManagement=1,
 * written by the Razer Command Center's GPU page) it idles in P8 at ~4 W, and
 * `runtime_status` reads "active" with `runtime_suspended_time` at 0 even when
 * idle. That is not a bug in the reading: with S0ix the device stays in D0 and
 * reaches low power *internally*, so the PCI runtime-suspend counter never
 * moves. `parked` here therefore means "policy allows parking", not "the card
 * is currently cold" — the card is cold either way, which is why this is a
 * small switch and not a headline number.
 */
Singleton {
    id: root

    // ── the dGPU's PCI address, found by vendor id rather than hardcoded ──
    // 0000:01:00.0 is this machine today; the bus/function of a discrete GPU
    // is not something to hardcode, and a wrong path here would mean writing
    // a power policy to some other device.
    readonly property string pciAddress: _pciAddr
    property string _pciAddr: ""

    // ── state ───────────────────────────────────────────────────────────
    property bool available: false          // an NVIDIA dGPU was found at all
    property bool parkAllowed: true         // power/control == "auto"
    property bool runtimeActive: true       // runtime_status == "active"
    property string pstate: ""              // P0..P8
    property string powerDraw: ""           // e.g. "4.02 W"
    property bool driverRtd3: false         // NVreg_DynamicPowerManagement != 0
    property bool s0ix: false
    property string lastError: ""
    property bool working: false

    // Whether the PCI device is runtime-suspended, kept as its own property
    // rather than being folded into `runtimeActive`.
    //
    // This matters because nvidia-smi OPENS the device. Polling a card that
    // has just managed to sleep does not read its state, it undoes the
    // sleep and wakes it back up. Measured on this machine the bar ran
    // nvidia-smi every 4 s unconditionally, so any moment the card reached
    // its cold state -- closing the last GPU app, say -- the next tick
    // dragged it straight back out. That is self-inflicted: a monitoring
    // panel keeping the thing it monitors awake.
    property bool runtimeSuspended: false

    // The raw reply from the power/control read, kept so a disagreement
    // between this and the kernel can be told apart from a parse slip.
    property string lastControlRaw: ""

    // The switch is "on" when the card is pinned awake. Naming it this way
    // keeps the UI honest: "GPU on" in a power panel means "held awake", not
    // "more performance" -- the driver is always loaded either way.
    readonly property bool heldAwake: !parkAllowed

    function _parseNvidiaSmi(text) {
        // nvidia-smi --format=csv,noheader -> "P8, 4.02 W"
        const t = (text ?? "").trim();
        if (t.length === 0) return;
        const parts = t.split(",").map(s => s.trim());
        if (parts.length >= 1) root.pstate = parts[0];
        if (parts.length >= 2) root.powerDraw = parts[1];
    }

    // ── read the current policy ─────────────────────────────────────────
    Process {
        id: discover
        command: ["bash", "-c",
            "for d in /sys/bus/pci/devices/*/; do "
          + "  [ -r \"${d}vendor\" ] || continue; "
          + "  [ \"$(cat ${d}vendor 2>/dev/null)\" = \"0x10de\" ] || continue; "
          + "  echo \"${d%/}\"; break; done"]
        stdout: StdioCollector {
            onStreamFinished: {
                const a = (text ?? "").trim();
                if (a.length === 0) {
                    root.available = false;
                    return;
                }
                root._pciAddr = a;
                root.available = true;
                pollControl.running = false;
                pollControl.running = true;
                pollModprobe.running = false;
                pollModprobe.running = true;
            }
        }
    }

    Process {
        id: pollControl
        command: ["bash", "-c",
            // Concatenated, NOT "${...}": these are plain double-quoted QML
            // strings, where ${} is literal text that bash would then expand
            // as its own (unset) variable. That silently read nothing and
            // left park/hold at whatever its default was.
            "p=" + root.pciAddress + "/power/control; "
          + "c=$(cat $p 2>/dev/null); "
          + "s=$(cat " + root.pciAddress + "/power/runtime_status 2>/dev/null); "
          + "echo \"${c:-?} ${s:-?}\""]
        stdout: StdioCollector {
            onStreamFinished: {
                root.lastControlRaw = (text ?? "").trim();
                const t = root.lastControlRaw.split(/\s+/);
                if (t[0] === "auto") root.parkAllowed = true;
                else if (t[0] === "on") root.parkAllowed = false;
                root.runtimeActive = t[1] !== "suspended";
                root.runtimeSuspended = t[1] === "suspended";
            }
        }
    }

    // Whether the DRIVER would let the card park at all. This is a modprobe
    // parameter, so it is read from the config file rather than from sysfs,
    // and it only changes on a module load.
    Process {
        id: pollModprobe
        command: ["bash", "-c",
            "f=/etc/modprobe.d/60-nvidia-pm.conf; "
          + "d=$(grep -oP 'DynamicPowerManagement=\\K0x[0-9a-f]+' $f 2>/dev/null | head -1); "
          + "s=$(grep -oP 'EnableS0ixPowerManagement=\\K[01]' $f 2>/dev/null | head -1); "
          + "echo \"${d:-0x0} ${s:-0}\""]
        stdout: StdioCollector {
            onStreamFinished: {
                const t = (text ?? "").trim().split(/\s+/);
                const dpm = t[0] ?? "0x0";
                root.driverRtd3 = dpm !== "0x0" && dpm !== "0x00";
                root.s0ix = (t[1] ?? "0") === "1";
            }
        }
    }

    Process {
        id: pollSmi
        command: ["nvidia-smi", "--query-gpu=pstate,power.draw",
                  "--format=csv,noheader"]
        stdout: StdioCollector {
            onStreamFinished: root._parseNvidiaSmi(text)
        }
    }

    // ── the switch ──────────────────────────────────────────────────────
    /**
     * parkAllowed = true  -> "on":  pin the card awake (power/control = on)
     * parkAllowed = false -> "off": let it park when idle (power/control = auto)
     *
     * Through pkexec, so this prompts for the admin password. The command
     * carries no user-supplied path: the device is re-discovered inside the
     * shell by vendor id, and the value is validated against the two legal
     * values before it is interpolated at all.
     */
    function setParkAllowed(allow) {
        if (!root.available || root.working)
            return;
        root.working = true;
        root.lastError = "";
        const value = allow ? "auto" : "on";
        if (value !== "auto" && value !== "on") {
            root.lastError = "refusing an unknown power policy";
            root.working = false;
            return;
        }
        apply.command = ["pkexec", "bash", "-c",
            "set -e; for d in /sys/bus/pci/devices/*/; do "
          + "  [ -r \"${d}vendor\" ] || continue; "
          + "  [ \"$(cat ${d}vendor 2>/dev/null)\" = \"0x10de\" ] || continue; "
          + "  [ -w \"${d}power/control\" ] || continue; "
          + "  echo " + value + " > \"${d}power/control\"; exit 0; done; "
          + "  echo 'no writable NVIDIA power control' >&2; exit 1"];
        apply.running = true;
    }

    Process {
        id: apply
        running: false
        stderr: StdioCollector {
            onStreamFinished: {
                const t = (text ?? "").trim();
                if (t.length > 0) root.lastError = t;
            }
        }
        onExited: (code, status) => {
            root.working = false;
            // Re-read rather than assume: the write may have been refused.
            pollControl.running = false;
            pollControl.running = true;
        }
    }

    Timer {
        // Fast while the card is up, slow once it is down.
        //
        // 4 s is right for a live reading, but it is also 15 nvidia-smi
        // spawns a minute, each one opening /dev/nvidia0. While the card is
        // runtime-suspended the pstate and wattage cannot change without
        // something waking it, so there is nothing to poll for -- and
        // polling is precisely what would wake it. 30 s is long enough to
        // notice the card coming back without ever being the reason it left.
        interval: root.runtimeSuspended ? 30000 : 4000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (!root.available) {
                discover.running = false;
                discover.running = true;
                return;
            }
            // sysfs only. Reads two text files under the PCI device and does
            // NOT open /dev/nvidia0, so this half is safe on a cold card --
            // it is what tells us the card went to sleep in the first place.
            pollControl.running = false;
            pollControl.running = true;

            // Never wake a sleeping card to draw a number for it.
            if (root.runtimeSuspended) {
                root.pstate = "";
                root.powerDraw = "";
                return;
            }
            pollSmi.running = false;
            pollSmi.running = true;
        }
    }

    IpcHandler {
        target: "gpuPower"

        function state(): string {
            return `available=${root.available} addr=${root.pciAddress} `
                 + `parkAllowed=${root.parkAllowed} heldAwake=${root.heldAwake} `
                 + `runtime=${root.runtimeActive ? "active" : "suspended"} `
                 + `pstate=${root.pstate} draw=${root.powerDraw} `
                 + `rtd3=${root.driverRtd3} s0ix=${root.s0ix} `
                 + `err="${root.lastError}"`;
        }

        // The same entry point the switch uses, reachable from a keybind or
        // from `qs ipc` -- what gets exercised is the real path, not a copy
        // of it. The argument arrives as a string.
        function setPark(allow: string): void {
            root.setParkAllowed(allow !== "false" && allow !== "0" && allow !== "off");
        }

        // Named off "show" on purpose: that is a reserved `qs ipc` subcommand
        // and the function is then uncallable, which is the same trap the
        // music IPC hit.
        // What the read is actually being asked, and what came back.
        function debug(): string {
            return `cmd=[${pollControl.command.join(" ")}] raw="${root.lastControlRaw}"`
                 + ` running=${pollControl.running}`;
        }

        function refresh(): void {
            pollControl.running = false;
            pollControl.running = true;
        }
    }
}
