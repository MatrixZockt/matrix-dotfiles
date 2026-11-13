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

    // ── The MODE, read from the setting, not from the live profile ──────────
    //
    // This pin used to read `PowerProfiles.profile` for everything: the glyph,
    // the colour, the label -- and, worst of all, the starting point of the
    // cycle below. That is the machine's CURRENT PROFILE, which is a different
    // fact from the shell's setting, and the two drift apart:
    //
    //   * apply() skips the profile write while `hasPerformanceProfile` is
    //     false, so for a beat after a shell start the setting can say
    //     Performance while the profile is still balanced;
    //   * anything else on the system may move the profile (a TLP hook, a
    //     manual `powerprofilesctl set`, a resume);
    //   * PPD can decline a write -- and then the setting and the profile say
    //     different things with nothing to reconcile them.
    //
    // When they drift, the cycle below started from the wrong notch: a tap on a
    // pin sitting on Performance computed "next = performance", wrote the value
    // the setting already held, and NOTHING HAPPENED. Repeatedly, until
    // something resynced them. That is the "changing the power mode sometimes
    // does nothing" report, and it is why the mode comes from here now.
    //
    // `PowerMode.current` is the setting itself -- the same value the mode menu
    // marks as active and the settings page shows -- so the bar, the menu and
    // the page can no longer disagree about where the machine is, and the cycle
    // has a starting point that moves the instant you tap.
    readonly property string mode: PowerMode.current ?? "default"

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
        const found = order.indexOf(root.mode)
        const at = found < 0 ? -1 : found
        const next = order[(at + 1) % order.length]
        if (Config.options?.battery && Config.options.battery.powerMode !== next)
            Config.options.battery.powerMode = next
        else
            // Same-mode guard above, and the case it leaves open: the setting
            // already holds `next` (a config that was reloaded from disk under
            // us) while the hardware is elsewhere. apply() is idempotent, so
            // re-applying is the way to make the tap mean something rather than
            // doing nothing.
            PowerMode.apply(next)
    }
    tooltipText: Translation.tr("Click: Eco → Balanced → Performance → Eco")


}
