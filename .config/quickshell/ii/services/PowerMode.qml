pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick

import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower

import qs
import qs.modules.common
import qs.services

/**
 * What the machine is tuned for: the platform profile, and how long the shell's
 * own animations run.
 *
 *   Normal       balanced platform profile, shell animations at full length.
 *   Eco          power-saver profile: lower clocks for the longest runtime.
 *   Performance  performance profile: the processor and graphics are unlocked,
 *                and the shell's animations run at 12% (Appearance
 *                .animationCurves.motionScale reads the same config value) so
 *                the interface answers immediately.
 *
 * WHY THIS DOES NOT TOUCH HYPRLAND'S OWN ANIMATIONS ANY MORE.
 *
 * Performance mode used to switch the compositor's animation system off with
 * the mode (`hl.config({ animations = { enabled = false } })`). That does not
 * shorten motion, it deletes it: every window drop, every popup and every
 * desktop switch became a hard cut. The desktop switch is the one that hurt,
 * because it is navigation -- a SUPER+digit, a click on the bar's desktop
 * strip, or the notification that jumps to an app all teleported with no slide
 * to say which way you went, while the four-finger swipe kept its glide.
 *
 * So the compositor's motion is now left exactly as custom/general.lua
 * configures it, in every mode. The setting that genuinely means "the
 * interface holds still" is Game mode (the quick toggle), which turns
 * animations, blur, shadows, gaps and rounding off together.
 *
 * The rest of the mode still survives on its own: power-profiles-daemon
 * remembers the profile across reboots, and the motion scale is read live from
 * the config by Appearance -- so apply() has exactly one job left.
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
            "description": Translation.tr("Balanced, and the default. The platform profile stays balanced, so the machine chooses clock speeds on its own, and the shell animates at full length. Nothing is forced in either direction.")
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
            "description": Translation.tr("Performance profile: the processor and graphics are unlocked, and the shell's own animations are shortened to 12% so the interface answers immediately. The compositor's motion -- windows dropping in, the desktop slide -- is left as you configured it. Fastest and smoothest, at the cost of battery.")
        }
    ]

    readonly property string current: Config.options?.battery?.powerMode ?? "default"
    readonly property bool isPerformance: root.current === "performance"
    readonly property var currentMode: root.modes.find(mode => mode.value === root.current) ?? root.modes[0]

    // ── What the last switch changed ─────────────────────────────────────
    //
    // Switching mode used to be silent: the platform profile, the graphics cap
    // and the shell's motion all moved, and nothing on screen said which of
    // them had moved or from where. This is the record the notice reads, taken
    // HERE rather than by the notice -- the "before" values only exist for as
    // long as it takes apply() to write the new ones.
    //
    //   from, to        the mode keys, i.e. what the setting held and holds
    //   profileBefore   PPD's answer the moment before the write below
    //
    // `changeSeq` is bumped with every record so a view can watch a counter
    // instead of an object's identity.
    property var lastChange: null
    property int changeSeq: 0

    // ── What the machine held the moment before the switch ────────────────
    //
    // The notice's subject is "what moved", and the two rows that matter most
    // on it are hardware: the graphics ceiling and the CPU package cap. Neither
    // can be read by the card, because by the time a card exists the switch has
    // already been applied and those values are gone -- the ceiling lifts in
    // ~400 ms and the package cap follows at ~650 ms (measured 2026-10-12; see
    // the snapshot below).
    //
    // So it is read HERE, at the one instant where the old values still exist:
    // `current` has already moved by the time this handler runs, apply() below
    // has not run yet, and the two things that will change the hardware are
    // both started after it. Measured on this machine, the whole read takes
    // ~50 ms (nvidia-smi 28-38 ms, systemctl 3-5 ms) and the ceiling does not
    // move until ~400 ms, so what comes back is the previous mode's state and
    // not a glimpse of the new one.
    //
    // In memory only and per switch: reloaded to `null` at the start of every
    // change, so a card can never read a previous switch's numbers as its own
    // "before". A null here is honest -- a shell that has just started has no
    // previous state to report, and the card leaves that row's before column
    // empty rather than inventing one.
    property var before: null

    // ── The caps facts: one command, one parser, two readers ──────────────
    //
    // Read by this service once per switch (above) and by the notice for its
    // own settled measurement. Both read the SAME text, in the same order, and
    // parse it with the same function, because a second copy of either is a
    // second chance for the two to disagree about what the hardware said.
    //
    // enforced.power.limit is the field that answers on this card; power.limit
    // answers [N/A] here, which is what once made the graphics row read the
    // same in every mode. `systemctl is-active` is read FIRST and echoed in its
    // place in the format: it is the fact that moves first (the daemon is
    // signalled ~135 ms after the switch) and the fact the whole row's meaning
    // keys on, so it is the one that must not be caught mid-switch.
    readonly property var capsCommand: ["sh", "-c",
        "d=$(systemctl is-active nvidia-powerd.service 2>/dev/null); " +
        "nvidia-smi --query-gpu=enforced.power.limit,power.max_limit --format=csv,noheader,nounits 2>/dev/null; echo ---; " +
        "echo \"$d\"; echo ---; " +
        // The package cap, discovered rather than assumed to be intel-rapl:0 --
        // the same care the Command Center takes with it.
        "p=$(ls -d /sys/class/powercap/intel-rapl:[0-9] 2>/dev/null | head -1); " +
        "cat $p/constraint_0_power_limit_uw 2>/dev/null; echo ---; " +
        "cat $p/constraint_1_power_limit_uw 2>/dev/null; echo ---; " +
        "cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null"]

    function parseCaps(raw) {
        // One line per field, `---` between them (see capsCommand). Nothing is
        // assumed to be a number: the card may answer [N/A] while it is parked,
        // and a wrong number that looks right is worse than a blank.
        const parts = String(raw ?? "").split("---").map(s => s.trim());
        // Line 1: "55.00 W, 140.00 W" -- the enforced limit, then the ceiling
        // the mechanism can reach.
        const nums = (parts[0] ?? "").match(/[\d.]+/g) ?? [];
        // sysfs reports microwatts; everything here reads in watts.
        const watts = text => {
            const m = String(text ?? "").match(/\d+/);
            return m ? Math.round(parseInt(m[0]) / 1000000) : 0;
        };
        return {
            "capKnown": nums.length > 0,
            "capW": nums.length > 0 ? parseFloat(nums[0]) : 0,
            "capMaxW": nums.length > 1 ? parseFloat(nums[1]) : 0,
            "boosted": (parts[1] ?? "") === "active",
            "pl1W": watts(parts[2]),
            "pl2W": watts(parts[3]),
            // no_turbo is the INVERSE of the question the notice asks.
            "turbo": parts[4] === "1" ? "off" : (parts[4] === "0" ? "on" : "")
        };
    }

    Process {
        id: beforeFacts
        command: root.capsCommand
        stdout: StdioCollector {
            onStreamFinished: root.before = root.parseCaps(this.text)
        }
    }
    // The last value `current` was seen to hold. `current` has already moved by
    // the time the change handler runs, so without this the record could only
    // say where the mode went, never where it came from. Seeded with the
    // shell's own default, which is what `current` reads until the config file
    // lands (see load()).
    property string _lastSeen: root.modes[0].value

    // Whether a change of `current` is a SWITCH a person made.
    //
    // The first value the config hands this service is not: at every shell
    // start `current` lands on the stored mode, and announcing that would put
    // the notice on screen on every reload. The service is armed once the
    // shell has had time to settle.
    property bool armed: false
    Timer {
        interval: 2000
        repeat: false
        running: true
        onTriggered: root.armed = true
    }

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
        // The platform profile: clocks, power limits, fan curves. A machine
        // without a performance profile (some desktops, some VMs) gets the
        // balanced/saver pair only -- asking for a profile that does not exist
        // would leave the request silently ignored.
        const wanted = root.profileFor(value);
        if (wanted !== PowerProfile.Performance || PowerProfiles.hasPerformanceProfile)
            PowerProfiles.profile = wanted;

        // Ask the cap's owner to converge NOW instead of on its next tick.
        //
        // The profile above is only half of what a mode means here: the CPU
        // package cap and turbo belong to power-autoswitch (the app's fan mode
        // is what the Command Center re-asserts the cap from), and that daemon
        // follows the profile on a 5 s poll. So Performance could sit on Power
        // saver's 20/30 W with turbo off for up to five seconds, which is long
        // enough for the mode notice -- whose rows are hardware measurements
        // taken in the few seconds after a switch -- to read the OLD numbers
        // and go away before they changed. That is "turbo off in Performance",
        // and it was measured: 390-650 ms with this call against 3.0-5.3 s
        // without it.
        //
        // The script is called, never rewritten: this is the same contract the
        // performance script and the keyboard layouts use, and the cap still
        // has exactly one writer and one policy table.
        Quickshell.execDetached([
            `${Quickshell.env("HOME")}/.local/bin/power-autoswitch`, "--converge"
        ]);

        // Nothing else to push. The shell's motion (Appearance
        // .animationCurves.motionScale) reads the config value directly, and
        // Hyprland's own animations are configuration, not a mode -- see the
        // header for why the mode stopped touching them.
    }

    function load() {
        root.apply(root.current);
    }

    // There is deliberately NO IpcHandler here.
    //
    // One was added for the notice's diagnostics and it broke the shell: a
    // singleton that failed on it ("IpcHandler is not a type") took every
    // service importing PowerMode down with it. The record above is still
    // readable from outside -- `qs -c ii ipc call nowbarPanel powerMode`
    // prints it, from the panel that owns the buttons which drive this file.

    // `current` is a binding on the config value, so this fires whenever the
    // setting changes -- from the settings app, or from a hand edit of
    // config.json -- without depending on how the config object signals nested
    // writes.
    //
    // This is also the ONLY common place a mode change passes through: the
    // island's three buttons and the settings page both write the setting
    // first and let this run. That is why the notice is recorded here rather
    // than at either button.
    onCurrentChanged: {
        const previous = root._lastSeen;
        root._lastSeen = root.current;
        // Read PPD BEFORE apply() writes it: a moment later the old profile is
        // gone and there is nothing left to compare the new one against.
        const profileBefore = PowerProfiles.profile;
        // And read the hardware before apply() moves it -- the same argument,
        // for the two rows the notice measures (see `before` above).
        root.before = null;
        beforeFacts.running = false;
        beforeFacts.running = true;
        root.apply(root.current);
        if (!root.armed || previous === root.current)
            return;
        root.lastChange = {
            "from": previous,
            "to": root.current,
            "profileBefore": profileBefore
        };
        root.changeSeq += 1;
    }

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
}
