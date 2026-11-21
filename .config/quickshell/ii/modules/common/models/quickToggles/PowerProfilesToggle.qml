import QtQuick
import Quickshell
import Quickshell.Services.UPower
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

QuickToggleModel {
    id: root

    name: Translation.tr("Power Profile")

    // ── The MODE, read from the LIVE profile ──────────────────────────────
    //
    // This pin was moved to the setting (`PowerMode.current`) to fix a cycle
    // that computed its next notch from the wrong place. That cured the dead
    // tap and caused a worse bug: the setting is NOT what the machine is on.
    // power-failsafe raises Performance on a stall and backs out to the setting
    // when it calms, the bar's circular button writes PPD directly, and PPD can
    // decline a write -- and in every one of those the pin kept drawing Eco
    // while the notice said Performance and the processor ran unlocked. That is
    // the "switched to performance and the bar did not change" report.
    //
    // So the glyph, the colour, the label and the cycle's starting point all
    // come from `PowerMode.liveMode` (the PPD profile, mapped to a mode key):
    // the pin now always says what the machine is DOING. Taps still write the
    // SETTING, because that is the value PowerMode watches and the write that
    // announces the switch; the cycle's own guard below turns the old dead-tap
    // case (setting already holds `next`) into a re-apply, so a tap can never
    // be swallowed.
    readonly property string mode: PowerMode.liveMode

    toggled: root.mode !== "default"
    // A leaf for eco, a flame for performance: the glyph names the mode, the
    // colour below carries it. "energy" was a bolt over a battery outline,
    // which at 16px in the bar read as neither.
    icon: switch (root.mode) {
        case "eco": return "energy_savings_leaf"
        case "performance": return "local_fire_department"
        default: return "airwave"
    }
    // The mode's colour, worn by the GLYPH in the bar (no disc behind it: the
    // strip is outline icons on the bar's own surface). Green eco, the same
    // fire-orange the sidebar's power row and the performance alert already
    // use -- one colour language for the three modes, everywhere they appear.
    // Balanced is transparent on purpose: it has no colour of its own to say,
    // and this theme's accent is a grey taken from the wallpaper, so a tinted
    // balanced glyph would just be the grey icon it replaced.
    readonly property color tint: switch (root.mode) {
        case "eco": return "#43d17c"
        case "performance": return "#ff6d1f"
        default: return "transparent"
    }

    // The mode's name as the rest of the shell says it -- the settings page and
    // the island's power row call these Normal / Eco / Performance, and the bar
    // line read "Power Saver" for the same state.
    statusText: switch (root.mode) {
        case "eco": return "Eco"
        case "performance": return "Performance"
        default: return "Balanced"
    }

    // Cycles the MODE, through the config key -- not the PPD handle.
    //
    // Writing `PowerProfiles.profile` here switched the machine and said
    // nothing: PowerMode is what snapshots the hardware the machine is holding,
    // applies the mode (profile plus power-autoswitch's cap converge) and
    // records the switch the on-screen notice reads. It watches
    // `battery.powerMode`, so a write to that key is the whole path -- and the
    // same one the island's three mode buttons and the settings page already
    // take. Tapping this icon and pressing a button in the popup now do the
    // same thing, notice and hardware rows included.
    mainAction: () => {
        // The ring this pin walks: ECO -> BALANCED -> PERFORMANCE -> ECO, one
        // notch up per tap.
        //
        // Stated here rather than read from PowerMode.modes, whose order is the
        // SETTINGS page's (default, eco, performance). Read as a cycle that
        // went balanced -> eco -> performance, so a tap from balanced reached
        // the battery saver and a tap from eco jumped straight to the flame --
        // never the next step up. The list stays as the settings list it; only
        // the cycle is reordered.
        //
        // Performance is dropped on a machine without it (apply() would skip
        // the write anyway, and a cycle that lands on a mode the hardware
        // lacks is a dead tap).
        //
        // The starting point is the SETTING (root.mode), never the live
        // profile -- see the note on `mode`. A tap therefore always lands on a
        // value the setting does not already hold, which is what keeps a tap
        // from ever being swallowed as a no-op. The clamp covers a setting that
        // holds something unrecognised (a hand-edited config, or the moment
        // before the file loads): from "unknown" the next stop is eco, the
        // first notch, rather than jumping straight past two.
        const order = ["eco", "default", "performance"]
            .filter(value => value !== "performance" || PowerProfiles.hasPerformanceProfile)
        // The ring is walked from the LIVE mode (root.mode), so the notch a tap
        // lands on is always a real move from where the machine is standing --
        // including out of a Performance that power-failsafe raised and the
        // setting never held.
        const found = order.indexOf(root.mode)
        const at = found < 0 ? -1 : found
        const next = order[(at + 1) % order.length]
        if (Config.options?.battery && Config.options.battery.powerMode !== next)
            Config.options.battery.powerMode = next
        else
            // The setting already holds `next` while the hardware is elsewhere
            // (a failsafe raise, a direct PPD write, a config reloaded from
            // disk under us). The write above would be swallowed by the
            // same-mode guard in PowerMode, so re-apply is what makes the tap
            // mean something; apply() is idempotent.
            PowerMode.apply(next)
    }
    tooltipText: Translation.tr("Click: Eco → Balanced → Performance → Eco")


}
