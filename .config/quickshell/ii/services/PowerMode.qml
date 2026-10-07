pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick

import Quickshell
import Quickshell.Hyprland
import Quickshell.Services.UPower

import qs
import qs.modules.common
import qs.services

/**
 * What the machine is tuned for: one choice, three jobs.
 *
 *   Normal       balanced platform profile, the desktop animates normally.
 *   Eco          power-saver profile: lower clocks for the longest runtime.
 *   Performance  performance profile, and motion cut right down -- the shell's
 *                animations to 12% (Appearance.animationCurves.motionScale reads
 *                the same config value) and Hyprland's window animations off.
 *
 * The three settings a mode touches are deliberately kept in one place, because
 * they have to move together: setting the platform profile to performance while
 * leaving half-second window slides in place is not "performance mode", and
 * switching the animations off without the profile does not save anything.
 *
 * Two of the three survive on their own: power-profiles-daemon remembers the
 * profile across reboots, and the motion scale is read live from the config by
 * Appearance. Hyprland's animation keyword is the exception -- it lives in the
 * running compositor and a config reload resets it -- so this re-applies it
 * whenever Hyprland reloads its config, not just at login.
 */
Singleton {
    id: root

    // The order the settings show them in, with the words used on the page.
    readonly property var modes: [
        {
            "value": "default",
            "name": Translation.tr("Normal"),
            "icon": "balance",
            "default": true,
            "description": Translation.tr("Balanced, and the default. The platform profile stays balanced, so the machine chooses clock speeds on its own, and the desktop animates normally. Nothing is forced in either direction.")
        },
        {
            "value": "eco",
            "name": Translation.tr("Eco"),
            "icon": "energy",
            "default": false,
            "description": Translation.tr("Power saver. The processor and graphics are held back to stretch the battery and keep the machine cooler and quieter. Everything still works, it just does it more slowly. The right choice on battery.")
        },
        {
            "value": "performance",
            "name": Translation.tr("Performance"),
            "icon": "local_fire_department",
            "default": false,
            "description": Translation.tr("Performance profile, and motion cut right down: the shell's animations run at 12% length and Hyprland's window and workspace animations are switched off, so the interface gets out of the way. Fastest and smoothest, at the cost of battery.")
        }
    ]

    readonly property string current: Config.options?.battery?.powerMode ?? "default"
    readonly property bool isPerformance: root.current === "performance"
    readonly property var currentMode: root.modes.find(mode => mode.value === root.current) ?? root.modes[0]

    // For ConfigSelectionArray, which wants { displayName, value, icon }.
    readonly property var selectorOptions: root.modes.map(mode => ({
        "displayName": mode.default ? Translation.tr("%1 (default)").arg(mode.name) : mode.name,
        "value": mode.value,
        "icon": mode.icon
    }))

    function descriptionFor(value) {
        const mode = root.modes.find(entry => entry.value === value);
        return mode ? mode.description : "";
    }

    function profileFor(value) {
        switch (value) {
        case "eco":
            return PowerProfile.PowerSaver;
        case "performance":
            return PowerProfile.Performance;
        default:
            return PowerProfile.Balanced;
        }
    }

    // The inverse of `profileFor`, for controls that hold a PPD profile and
    // need to know WHICH setting that is. The bar's three power buttons work in
    // profiles (they are switches on the live PPD handle) but the shell's
    // setting is the mode key, and a profile write that skips the key is undone
    // the next time anything re-signals the config -- see applyMode in
    // NowBarPanel, which is where that was happening.
    function modeFor(profile) {
        switch (profile) {
        case PowerProfile.PowerSaver:
            return "eco";
        case PowerProfile.Performance:
            return "performance";
        default:
            return "default";
        }
    }

    function apply(value) {
        // 1. The platform profile: clocks, power limits, fan curves. A machine
        //    without a performance profile (some desktops, some VMs) gets the
        //    balanced/saver pair only -- asking for a profile that does not
        //    exist would leave the request silently ignored.
        const wanted = root.profileFor(value);
        if (wanted !== PowerProfile.Performance || PowerProfiles.hasPerformanceProfile)
            PowerProfiles.profile = wanted;

        // 2. Hyprland's own animations. Through the Lua config parser, like
        //    every other dispatch in this shell.
        root.applyCompositorMotion(value === "performance");

        // 3. The shell's motion (Appearance.animationCurves.motionScale) reads
        //    the config value directly, so there is nothing to push here.
    }

    function applyCompositorMotion(reduced) {
        // `hyprctl eval`, NOT Hyprland.dispatch(). This Hyprland runs the Lua
        // config parser, where dispatch() expects a *dispatcher* -- a plain
        // config call is rejected with "hl.dispatch: expected a dispatcher
        // (e.g. hl.dsp.window.close())". eval runs the Lua as a config
        // statement, which is what a setting like this needs.
        Quickshell.execDetached(["hyprctl", "eval",
            `hl.config({ animations = { enabled = ${reduced ? "false" : "true"} } })`]);
    }

    function load() {
        root.apply(root.current);
    }

    // `current` is a binding on the config value, so this fires whenever the
    // setting changes -- from the settings app, or from a hand edit of
    // config.json -- without depending on how the config object signals nested
    // writes.
    onCurrentChanged: root.apply(root.current)

    // Two arrival races, both of which used to leave the machine on the wrong
    // profile for a beat after every shell start or reload -- and the second
    // one silently DROPPED a Performance request, which is indistinguishable
    // from "it keeps going back".
    //
    // 1. `load()` runs from Component.onCompleted, which can beat the config
    //    file. `current` then reads its DEFAULT (balanced), so the shell first
    //    put the machine on balanced and only corrected once the file landed.
    Connections {
        target: Config
        function onReadyChanged() {
            if (Config.ready)
                root.apply(root.current);
        }
    }
    // 2. PPD's own profile list can arrive after we ask for Performance, and
    //    `apply()` skips the write while `hasPerformanceProfile` is false (that
    //    guard exists so a machine without the profile is not asked for it).
    //    Asking again when the list shows up is what makes the request land.
    Connections {
        target: PowerProfiles
        function onHasPerformanceProfileChanged() { root.apply(root.current); }
    }

    // A config reload resets what was set at runtime, so put the animations
    // back where the mode says they belong.
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "configreloaded")
                root.applyCompositorMotion(root.isPerformance);
        }
    }
}
