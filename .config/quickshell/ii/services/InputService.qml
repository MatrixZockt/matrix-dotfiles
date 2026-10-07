pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs
import qs.modules.common

/**
 * Mouse / touchpad settings that live in the COMPOSITOR, not the config file.
 *
 * Hyprland's input block is compositor state: it can be changed at runtime
 * with `hyprctl eval hl.config({ input = {...} })` (the same mechanism
 * PowerMode uses for animations), and a config reload resets it. So:
 *   - writes go through hyprctl eval,
 *   - the value is re-read from `hyprctl getoption` after each write,
 *   - and everything is re-applied on every Hyprland config reload.
 *
 * Sensitivity: Hyprland's `input:sensitivity` spans -1..1, which is alien to
 * users. The UI exposes 0-200% where 100% = sensitivity 0.0, mapped linearly.
 */
Singleton {
    id: root

    // ── Live compositor truth ──────────────────────────────────────────
    property real sensitivityValue: 0.0      // Hyprland's -1..1
    property bool naturalScroll: true
    property real scrollFactor: 0.5
    property bool tapToClick: true
    property bool tapAndDrag: true
    property bool disableWhileTyping: true
    property bool leftHanded: false

    property bool loaded: false

    // ── UI mapping ─────────────────────────────────────────────────────
    readonly property int mouseSensitivityPercent: Math.round((root.sensitivityValue + 1.0) * 100)

    function setMouseSensitivityPercent(p) {
        const clamped = Math.max(0, Math.min(200, Math.round(p)));
        const sens = (clamped / 100.0 - 1.0).toFixed(2);
        Quickshell.execDetached(["hyprctl", "eval",
            `hl.config({ input = { sensitivity = ${sens} } })`]);
        root.sensitivityValue = clamped / 100.0 - 1.0;
    }

    function setNaturalScroll(on) {
        Quickshell.execDetached(["hyprctl", "eval",
            `hl.config({ input = { touchpad = { natural_scroll = ${on ? "true" : "false"} } } })`]);
        root.naturalScroll = on;
    }

    function setScrollFactor(f) {
        const v = Math.max(0.1, Math.min(3.0, Math.round(f * 100) / 100));
        Quickshell.execDetached(["hyprctl", "eval",
            `hl.config({ input = { touchpad = { scroll_factor = ${v} } } })`]);
        root.scrollFactor = v;
    }

    function setTapToClick(on) {
        // NOTE: the fork's hl.config wrapper only accepts underscore keys --
        // the config-file hyphen spelling (tap-to-click) errors out here.
        Quickshell.execDetached(["hyprctl", "eval",
            `hl.config({ input = { touchpad = { tap_to_click = ${on ? "true" : "false"} } } })`]);
        root.tapToClick = on;
    }

    function setTapAndDrag(on) {
        Quickshell.execDetached(["hyprctl", "eval",
            `hl.config({ input = { touchpad = { tap_and_drag = ${on ? "true" : "false"} } } })`]);
        root.tapAndDrag = on;
    }

    function setDisableWhileTyping(on) {
        Quickshell.execDetached(["hyprctl", "eval",
            `hl.config({ input = { touchpad = { disable_while_typing = ${on ? "true" : "false"} } } })`]);
        root.disableWhileTyping = on;
    }

    function setLeftHanded(on) {
        Quickshell.execDetached(["hyprctl", "eval",
            `hl.config({ input = { left_handed = ${on ? "true" : "false"} } })`]);
        root.leftHanded = on;
    }

    // ── Reading the truth back ─────────────────────────────────────────
    Process {
        id: reader
        property string pending: ""
        command: ["sh", "-c",
            "hyprctl getoption input:sensitivity -j; " +
            "hyprctl getoption input:touchpad:natural_scroll -j; " +
            "hyprctl getoption input:touchpad:scroll_factor -j; " +
            "hyprctl getoption input:touchpad:tap-to-click -j; " +
            "hyprctl getoption input:touchpad:tap-and-drag -j; " +
            "hyprctl getoption input:touchpad:disableWhileTyping -j; " +
            "hyprctl getoption input:left_handed -j"]
        stdout: StdioCollector {
            onStreamFinished: {
                // Each hyprctl -j line is one JSON object; option name is not
                // in the payload, so we rely on the fixed order above.
                const objs = String(text).split("\n")
                    .map(l => l.trim()).filter(l => l.startsWith("{"))
                    .map(l => { try { return JSON.parse(l); } catch (e) { return null; } })
                    .filter(o => o !== null);
                if (objs.length < 7) return;
                root.sensitivityValue = objs[0].float ?? 0.0;
                root.naturalScroll = objs[1].bool ?? true;
                root.scrollFactor = objs[2].float ?? 0.5;
                root.tapToClick = objs[3].bool ?? true;
                root.tapAndDrag = objs[4].bool ?? true;
                root.disableWhileTyping = objs[5].bool ?? true;
                root.leftHanded = objs[6].bool ?? false;
                root.loaded = true;
            }
        }
    }

    function refresh() {
        reader.running = false;
        reader.running = true;
    }

    Component.onCompleted: root.refresh()

    // A config reload resets runtime options -- put them back where they are.
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "configreloaded")
                root.refresh();
        }
    }
}
