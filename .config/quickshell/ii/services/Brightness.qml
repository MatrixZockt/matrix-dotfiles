pragma Singleton
pragma ComponentBehavior: Bound

// From https://github.com/caelestia-dots/shell with modifications.
// License: GPLv3

import qs.modules.common
import qs.modules.common.functions
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import QtQuick

/**
 * For managing brightness of monitors. Supports both brightnessctl and ddcutil.
 */
Singleton {
    id: root
    signal brightnessChanged()

    // The one canonical brightness entry point: resolves which backlight
    // device actually drives the built-in panel (see the script's header for
    // the nvidia_0-vs-intel_backlight story) and reads/sets/steps it.
    readonly property string brightnessScript: Quickshell.shellPath("scripts/system/brightness-device.sh")

    property var ddcMonitors: []
    readonly property list<BrightnessMonitor> monitors: Quickshell.screens.map(screen => monitorComp.createObject(root, {
        screen
    }))

    function getMonitorForScreen(screen: ShellScreen): var {
        return monitors.find(m => m.screen === screen);
    }

    // The monitor a bare brightness action means: the focused one. Split out
    // of increase/decreaseBrightness so every writer -- keys, the sliders and
    // the bar's swipe -- resolves the same panel instead of each carrying its
    // own idea of which one is "the" backlight.
    function focusedMonitor(): var {
        const focusedName = Hyprland.focusedMonitor?.name ?? "";
        return root.monitors.find(m => m.screen.name === focusedName)
            ?? root.monitors[0] ?? null;
    }

    // Read/write the panel as a plain 0..1 fraction. The bar's two-finger
    // swipe is ABSOLUTE control -- the value under the fingers when they land
    // plus however far they travel -- so it needs to be able to ask where the
    // backlight is now and to put it somewhere specific. A step API cannot
    // express either.
    function brightnessFraction(): real {
        const m = root.focusedMonitor();
        return m ? m.brightness : 0;
    }

    function setBrightnessFraction(fraction: real): void {
        const m = root.focusedMonitor();
        if (!m) return;
        if (m.instantWrites) {
            // Gesture mode: the bar's ordered write pipe owns device writes.
            // This call is MIRROR-ONLY -- update the tracked value (UI, OSD,
            // next-gesture anchor) without forking. instantWrites also
            // disables the Behaviour, so there are no intermediate values
            // and this fires exactly once per gesture write.
            m.suppressSync = true;
            m.setBrightness(fraction);
            m.suppressSync = false;
        } else {
            m.setBrightness(fraction);
        }
    }

    // The bar's two-finger swipe flips this for the life of a gesture so its
    // writes land the frame the fingers move (see BrightnessMonitor). The
    // device-level flag lives on the monitor, but which monitor is "the"
    // panel is resolved HERE, the same way every other writer does it.
    function setInstantWrites(instant: bool): void {
        const m = root.focusedMonitor();
        if (m) m.instantWrites = instant;
        else root.monitors.forEach(m => m.instantWrites = instant);
    }

    // ── Gamma is NOT brightness ────────────────────────────────────────
    // Both step functions used to couple to hyprsunset: increase diverted
    // to gamma whenever gamma was not 100 (so after ANY gamma dip -- the
    // night-light dialog, an old ratchet -- brightness-up adjusted GAMMA
    // and the panel never moved), and decrease ratcheted gamma down by 5
    // every time brightness hit 0. Together they were a loop: a few dips
    // walked gamma down, then the brightness keys ``spasmed'' -- flicking
    // the gamma OSD while brightness sat still. Gamma has exactly one
    // owner, the night-light dialog; these functions now touch the
    // backlight and nothing else.
    function increaseBrightness(): void {
        const focusedName = Hyprland.focusedMonitor.name;
        const monitor = monitors.find(m => focusedName === m.screen.name);
        if (monitor) {
            if (monitor.isDdc)
                monitor.setBrightness(monitor.brightness + 0.05);
            else
                monitor.stepFromDevice(0.05); // re-read first: see stepFromDevice
        }
    }

    function decreaseBrightness(): void {
        const focusedName = Hyprland.focusedMonitor.name;
        const monitor = monitors.find(m => focusedName === m.screen.name);
        if (!monitor || monitor.brightness <= 0)
            return; // already at the floor -- gamma is NOT the next step down
        if (monitor.isDdc)
            monitor.setBrightness(monitor.brightness - 0.05);
        else
            monitor.stepFromDevice(-0.05); // re-read first: see stepFromDevice
    }

    reloadableId: "brightness"

    // `ddcutil` is not installed on this machine, so the detection process
    // below never starts and its `onExited` never fires. That used to leave
    // every monitor un-initialized -- `ready` false, `brightness` 0 -- so the
    // sidebar's brightness slider sat at 0% no matter what the panel was
    // actually doing. The sysfs path in initializeMonitor() is the right one
    // for the built-in panel anyway, so probe for ddcutil first and skip
    // detection entirely when it is absent instead of waiting forever on a
    // process that cannot run.
    onMonitorsChanged: {
        ddcMonitors = [];
        probeProc.running = false;
        probeProc.running = true;
    }

    // Whether `ddcutil` is on PATH. Probed once per monitor-list change: a
    // missing binary is a static fact, so there is no reason to re-check it
    // on every reload.
    property bool ddcutilAvailable: false

    function initializeMonitor(i: int): void {
        if (i >= monitors.length)
            return;
        monitors[i].initialize();
    }

    function ddcDetectFinished(): void {
        initializeMonitor(0);
    }

    Process {
        id: probeProc
        command: ["bash", "-c", "command -v ddcutil"]
        stdout: StdioCollector {
            id: probeCollector
            onStreamFinished: {
                root.ddcutilAvailable = probeCollector.text.trim().length > 0;
                if (root.ddcutilAvailable) {
                    ddcProc.running = false;
                    ddcProc.running = true;
                } else {
                    root.ddcDetectFinished();
                }
            }
        }
    }

    Process {
        id: ddcProc

        command: ["ddcutil", "detect", "--brief"]
        stdout: SplitParser {
            splitMarker: "\n\n"
            onRead: data => {
                if (data.startsWith("Display ")) {
                    const lines = data.split("\n").map(l => l.trim());
                    root.ddcMonitors.push({
                        name: lines.find(l => l.startsWith("DRM connector:")).split("-").slice(1).join('-'),
                        busNum: lines.find(l => l.startsWith("I2C bus:")).split("/dev/i2c-")[1]
                    });
                }
            }
        }
        onExited: root.ddcDetectFinished()
    }

    component BrightnessMonitor: QtObject {
        id: monitor

        required property ShellScreen screen
        property bool isDdc
        property string busNum
        property int rawMaxBrightness: 100
        property real brightness
        // The value the DEVICE is written from, deliberately separate from
        // `brightness`: `brightness` is the logical value the UI sets and
        // reads, and it has to track a finger instantly, while this is the one
        // the panel is walked to -- the Behavior below turns that walk into a
        // 200ms glide.
        //
        // This property used to be `multipliedBrightness`, a second factor
        // that the anti-flashbang feature scaled by a screenshot-derived
        // lightness multiplier. That feature is deleted (it cost ~750ms of CPU
        // per event for a reaction that arrived too late to matter). The
        // property itself stays, because the UI/device split above is the
        // whole reason a slider tracks the finger while the panel still eases.
        // A BINDING, but deliberately NOT `readonly`: a Behavior has to be able
        // to assign to the property it animates. Marking this read-only is
        // not a cosmetic difference -- it makes the `Behavior on
        // deviceBrightness` below an "Invalid property assignment", which
        // fails the whole config load.
        property real deviceBrightness: Math.max(0, Math.min(1, monitor.brightness))
        property bool ready: false
        property bool animateChanges: !monitor.isDdc

        // The bar's two-finger brightness swipe sets this for the life of a
        // gesture: its writes must land the frame the fingers move, not glide
        // there on the 200ms Behaviour that makes the slider feel nice.
        // Without it the panel trails the fingers by a fifth of a second and
        // the swipe reads as lag, not tracking.
        property bool instantWrites: false
        // Set around a mirror-only update (see setBrightnessFraction): the
        // gesture's write pipe owns device writes, so the change handler must
        // NOT fork another write for this value.
        property bool suppressSync: false

        onBrightnessChanged: {
            if (!monitor.ready) return;
            root.brightnessChanged();
        }

        Behavior on deviceBrightness {
            enabled: monitor.animateChanges && !monitor.instantWrites
            NumberAnimation {
                duration: 200
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.animationCurves.expressiveEffects
            }
        }
        onDeviceBrightnessChanged: {
            // Mirror-only update (gesture pipe owns the device): do not fork.
            // This guard is what makes the swipe single-writer -- without it,
            // the Behavior's intermediate values each forked their own
            // unordered brightnessctl, racing the gesture's ordered pipe.
            if (monitor.suppressSync)
                return;
            // DDC's writes are slow and must not be spammed, so it keeps the
            // debounced timer; the panel is written straight away.
            if (!monitor.isDdc)
                syncBrightness();
            else
                setTimer.restart();
        }

        function initialize() {
            monitor.ready = false;
            const match = root.ddcMonitors.find(m => m.name === screen.name && !root.monitors.slice(0, root.monitors.indexOf(this)).some(mon => mon.busNum === m.busNum));
            isDdc = !!match;
            busNum = match?.busNum ?? "";
            // Non-DDC path through the helper script: on this KEYBOARD this laptop
            // plain `brightnessctl` resolves to the dGPU's `nvidia_0`, which
            // drives nothing visible -- the panel is the iGPU's
            // `intel_backlight`. The helper resolves the right device from
            // the DRM state instead of enumeration order (and prints the
            // same "a b c CUR MAX" line the old pipeline did).
            initProc.command = isDdc ? ["ddcutil", "-b", busNum, "getvcp", "10", "--brief"]
                : ["bash", root.brightnessScript, "read"];
            initProc.running = true;
        }

        readonly property Process initProc: Process {
            stdout: SplitParser {
                onRead: data => {
                    const [, , , current, max] = data.split(" ");
                    monitor.rawMaxBrightness = parseInt(max);
                    monitor.brightness = parseInt(current) / monitor.rawMaxBrightness;
                    monitor.ready = true;
                }
            }
            onExited: (exitCode, exitStatus) => {
                initializeMonitor(root.monitors.indexOf(monitor) + 1);
            }
        }

        // We need a delay for DDC monitors because they can be quite slow and might act weird with rapid changes
        property var setTimer: Timer {
            id: setTimer
            interval: monitor.isDdc ? 300 : 0
            onTriggered: {
                syncBrightness();
            }
        }

        function syncBrightness() {
            const brightnessValue = Math.max(monitor.deviceBrightness, 0);
            if (isDdc) {
                const rawValueRounded = Math.max(Math.floor(brightnessValue * monitor.rawMaxBrightness), 1);
                setProc.exec(["ddcutil", "-b", busNum, "setvcp", "10", rawValueRounded]);
            } else {
                // Through the helper (see initialize): keeps the write on the
                // device that actually drives the panel. 0 stays "1" so the
                // screen can never go fully black.
                //
                // execDetached, and on purpose: `setProc.exec` BLOCKS the QML
                // thread until the helper returns, and a brightness swipe
                // writes a dozen times a second -- each one stalling the very
                // event loop that is supposed to be feeding it the next
                // finger position. The panel is the last thing the shell
                // should wait for.
                let valuePercentNumber = Math.floor(brightnessValue * 100);
                if (valuePercentNumber == 0) valuePercentNumber = 1; // Prevent fully black
                Quickshell.execDetached(["bash", root.brightnessScript, "set", String(valuePercentNumber)]);
            }
        }

        function setBrightness(value: real): void {
            value = Math.max(0, Math.min(1, value));
            monitor.brightness = value;
        }

        // DDC writes only -- the local panel's write went fire-and-forget
        // (see syncBrightness): ddcutil is slow enough that serializing its
        // writes through one process is a feature, not a cost.
        readonly property Process setProc: Process {}

        // ── The device is the truth ─────────────────────────────────
        // External writers exist on this machine: the idle screensaver dims
        // and restores the panel's backlight directly, and the keybind
        // fallback path writes through the same helper script. The tracked
        // value can therefore drift from what the screen really shows, and
        // a keyboard step from a stale number reads as "the keys do
        // nothing" (or a wild jump). Before every KEYBOARD step the device
        // is re-read and adopted, so the step always lands relative to the
        // brightness the screen actually has. (DDC is excluded: its reads
        // cost ~1s per probe.)
        property real pendingStep: 0
        readonly property Process readProc: Process {
            stdout: SplitParser {
                onRead: data => {
                    const [, , , current, max] = data.split(" ");
                    const m = parseInt(max);
                    const c = parseInt(current);
                    if (m > 0 && !isNaN(c)) {
                        monitor.rawMaxBrightness = m;
                        monitor.brightness = c / m;
                        monitor.setBrightness(c / m + monitor.pendingStep);
                    }
                }
            }
        }
        function stepFromDevice(delta: real): void {
            monitor.pendingStep = delta;
            readProc.command = ["bash", root.brightnessScript, "read"];
            readProc.running = false;
            readProc.running = true;
        }

    }

    Component {
        id: monitorComp

        BrightnessMonitor {}
    }

    // ── Anti-flashbang: NOT HERE ─────────────────────────────────────────
    //
    // Two earlier versions of this feature lived in this file and are gone:
    // a per-monitor `Variants` scope that measured the screen with grim +
    // ImageMagick on every Hyprland event (~750 ms of CPU per event, and the
    // reaction landed after the flash), and then a layer-shell veil driven by
    // a Python daemon, which could not cover the gap between a window appearing
    // and the veil being raised.
    //
    // The feature now lives in the compositor, where it cannot be late:
    // services/HyprlandAntiFlashbangShader.qml loads a screen_shader that dims
    // each frame in proportion to its own average brightness. Nothing here is
    // reachable any more, and nothing in this file touches the backlight for
    // it -- which also means keying brightness up and down by hand is never
    // fighting a running filter.

    // External trigger points

    IpcHandler {
        target: "brightness"

        function increment() {
            onPressed: root.increaseBrightness()
        }

        function decrement() {
            onPressed: root.decreaseBrightness()
        }
    }

    GlobalShortcut {
        name: "brightnessIncrease"
        description: "Increase brightness"
        onPressed: root.increaseBrightness()
    }

    GlobalShortcut {
        name: "brightnessDecrease"
        description: "Decrease brightness"
        onPressed: root.decreaseBrightness()
    }
}
