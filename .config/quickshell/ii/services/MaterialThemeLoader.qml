pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

/**
 * Automatically reloads generated material colors.
 * It is necessary to run reapplyTheme() on startup because Singletons are lazily loaded.
 */
Singleton {
    id: root
    property string filePath: Directories.generatedMaterialThemePath

    function reapplyTheme() {
        themeFileView.reload()
    }

    // ── Light mode's grey ladder ───────────────────────────────────────────
    //
    // WHAT WAS WRONG. In light mode every role whose whole job is to be
    // DIFFERENT from the surface around it -- the toggled chip, the selected
    // row, the meter accent, the card, the hairline -- was coming out as a
    // slightly paler grey than the surface it sits on, i.e. no difference at
    // all. Measured on this machine (2026-10-15, contrast ratio against the
    // panel each role is actually drawn on, ash template):
    //
    //   role                  light    dark
    //   secondaryContainer     1.12    1.43     toggled pills, selected rows,
    //                                           text selection, combo boxes
    //   tertiaryContainer      1.13    1.48     the paired FAB
    //   surfaceVariant         1.12    1.48     --
    //   primaryContainer       1.28    1.65     notice boxes, the FAB
    //   outlineVariant         1.79    1.65     dividers, card edges, hairlines
    //
    // 1.05-1.28:1 is a smudge, not a difference: a role that is supposed to
    // MARK something is there, is drawn, and cannot be seen. `colTertiary` is
    // the worst case, because it is not a background at all -- it is an
    // ACCENT (the RAM meter in the performance gauges, the minute hand, the
    // sidebar's unread dot) and in light mode it was `#DEDEDE` on a `#F0F0F0`
    // page. Dark mode has no such problem: the same roles sit at 1.32-1.65:1
    // there, which is exactly the separation a chip needs to read as a chip.
    //
    // WHAT IT IS NOW. Light mode gets the same separation dark mode has, from
    // an explicit grey ladder instead of a lighter copy of the same washed
    // tint. The ladder is a fixed set of steps from the page's own white down
    // to a near-black line colour, so the tones are ORDERED rather than merely
    // different from each other, and each contrast
    // role lands clear of the one below it, measured on the Ash palette: the
    // contrast chip 1.28 -> 2.50:1, the tertiary container 1.20 -> 1.86:1, the
    // primary container 1.37 -> 1.65:1, the deepest surface container
    // 1.30 -> 1.55:1, the outline 4.47 -> 5.04:1, and the invisible tertiary
    // ACCENT 1.18 -> 5.04:1.
    //
    // WHY HERE, and not in the template files. The report was about light mode
    // rather than about Ash: a wallpaper-derived palette (Settings > wallpaper
    // theming) is `colors.json` too, and it is BORN light when the wallpaper
    // says so -- so the rule belongs where every palette becomes the live
    // theme. `applyColors` is that place: the template picker, the dark/light
    // toggle, the wallpaper pipeline and plain startup-from-disk all land here
    // (see the comment on `applySystemTheme` below for the same argument).
    // Putting it in `themes/templates/*-light.json` would have fixed Ash and
    // left the other eleven templates and every generated palette alone.
    //
    // ABSOLUTE, NOT RELATIVE, AND DARKER-ONLY. Each entry is a target value,
    // not a darkening delta, and every move is `min(current, target)` -- so
    // running this twice on an already adjusted palette lands on the same
    // numbers, and a palette that is already darker than the target for some
    // role keeps what it has instead of being lightened into a worse one.
    // That matters: `applyColors` runs on every change to colors.json, not
    // only on a real theme change.
    //
    // THE `on*` INK ROLES ARE DELIBERATELY NOT TOUCHED. They are not paired
    // with their containers in this shell -- `colOnSecondaryContainer` is used
    // as ordinary ink in ~12 places that have no container at all (the
    // wallpaper clock's digits, the bar's workspace numbers, the config
    // widgets' labels) where it happens to work because it is the same tone as
    // `onSurface`. Inverting the containers to dark grey would need all of
    // those moved to a different token; darkening the containers UNDER the
    // existing dark ink gets the contrast without touching a single call site.
    // Checked against the ink, not assumed: on the new Ash fills,
    // `onSecondaryContainer` is 5.72:1 on the chip, `onPrimaryContainer`
    // 9.63:1, `onTertiaryContainer` 7.77:1, `onSecondary` 8.45:1, and the
    // subtext ink is 6.16:1 on the deepest container -- every one of them above
    // the 4.5:1 body-text line, and every one of them measured rather than
    // eyeballed. scripts/colors/check-light-ladder.py re-measures all four
    // pairs in all twelve light palettes and fails below the line.
    //
    // THE THREE KEYS THAT IDENTIFY A TEMPLATE ARE NOT TOUCHED: `primary`,
    // `surface` and `onBackground`. `scripts/colors/identify-template.py`
    // recognises which template is active by exactly that triple, and the
    // dark/light toggle's whole routing depends on that identification -- a
    // ladder that moved any of the three would make the toggle forget where it
    // is. The page (`background`/`surface`) also stays put on purpose: it is
    // the one tone in a light theme that is not supposed to be grey.
    //
    // NOTHING IS FORCED TO GREY. A tone keeps its own hue and saturation and
    // only its value moves, so a tinted palette stays tinted -- the `isGrey`
    // gate below is what decides whether a role belongs to this ladder at all,
    // not a desaturation pass. Ash, being monochrome, is the one palette where
    // the ladder therefore rewrites the whole set; everywhere else it takes
    // the pale near-neutral tones and leaves the palette's colours alone.
    //
    // THE LADDER ONLY MOVES (NEAR) GREY ROLES, AND ONLY DARKER. Both limits
    // are load-bearing and both were found by running the ladder over every
    // template light palette (12 of them) rather than over Ash alone:
    //
    //   * Eleven of the twelve templates are TINTED, and their containers are
    //     not washed-out greys at all -- catppuccin's `tertiary` is olive
    //     (#7A7814) with white ink, dracula's is #8F6793. Forcing the grey
    //     ladder onto those does not fix a contrast problem, it deletes the
    //     palette: the olive became grey and catppuccin's own chip ink
    //     (#6D5E7E) fell to 1.98:1 on the grey it produced. So a role is only
    //     touched when it is actually
    //     grey: no more than 5% chroma (max-min of the RGB channels), which
    //     is Ash's monochrome set (0%) and the pale panels of a tinted theme
    //     (~3%), and far below any real accent.
    //   * The other half of the same finding: some templates are already
    //     DARKER than the ladder's target for a role (catppuccin's
    //     tertiaryContainer is 4.4:1 on its page; the ladder wanted 0.70 and
    //     would have LIGHTENED it to 1.9:1, i.e. made it worse). Every move
    //     is therefore `min(current, target)` -- darker or unchanged, never
    //     lighter -- and the check asserts that direction rather than the
    //     final value.
    //
    // THE DARKENING HAPPENS IN HSV, NOT HSL. Measured, not preferred:
    // catppuccin's `surfaceBright` is #FFF7FE, and moving it one step down in
    // HSL (which keeps an off-white's saturation at 1.0, because HSL
    // saturation is defined against the distance to white) came out #FFF1FD
    // -- a MORE tinted surface than the one it started from, i.e. the ladder
    // adding colour to a palette while claiming to clean it. HSV saturation
    // for that same colour is 0.03, and moving its value down keeps the tint
    // where it was. For the near-grey roles below the two spaces differ by at
    // most half a step, so nothing else moves.
    //
    // old -> new, ash template (value, HSV):
    //   secondaryContainer   #D6D6D6 -> #999999   the contrast chip
    //   tertiary             #DEDEDE -> #666666   the invisible meter accent
    //   tertiaryContainer    #DCDCDC -> #B2B2B2
    //   primaryContainer     #CFCFCF -> #BDBDBD
    //   surfaceContainerLow  #E9E9E9 -> #E6E6E6   the shell's own panels, one
    //   surfaceContainer     #E2E2E2 -> #DADADA   step each, so a nested card
    //   surfaceContainerHigh #DBDBDB -> #CFCFCF   is a visible card
    //   surfaceContainerHighest #D4D4D4 -> #C3C3C3
    //   surfaceVariant       #DDDDDD -> #D1D1D1
    //   outlineVariant       #B0B0B0 -> #A3A3A3
    //   outline              #6E6E6E -> #666666
    //   secondary            #555555 -> #4C4C4C
    //
    // The structural half: the page-adjacent ladder, which has no ink of its
    // own and is the same fix for every palette -- a panel that is 1.07:1 from
    // the page it sits on is not a panel. Values are the target VALUE (HSV),
    // which for a grey is the same number HSL would have called lightness.
    readonly property var lightSurfaceLadder: ({
        surfaceBright: 0.973,
        surfaceContainerLowest: 0.965,
        surfaceDim: 0.87,
        surfaceContainerLow: 0.900,
        surfaceContainer: 0.855,
        surfaceContainerHigh: 0.810,
        surfaceContainerHighest: 0.765,
        surfaceVariant: 0.820,
        outlineVariant: 0.640,
        outline: 0.400,
        inverseSurface: 0.160,
    })

    // The contrast half: roles that stand in for a control being selected,
    // toggled or measured. These carry somebody's ink, so each one is clamped
    // by that ink -- see `lightLadderInks`.
    readonly property var lightContrastLadder: ({
        secondaryContainer: 0.600,
        tertiaryContainer: 0.700,
        primaryContainer: 0.740,
        secondary: 0.300,
        tertiary: 0.400,
    })

    // Which ink each contrast role is drawn with, so the ladder can be held to
    // it. Nothing here is assumed: scripts/colors/check-light-ladder.py
    // measures every one of these pairs in every template and fails below
    // 4.5:1.
    readonly property var lightLadderInks: ({
        secondaryContainer: "onSecondaryContainer",
        tertiaryContainer: "onTertiaryContainer",
        primaryContainer: "onPrimaryContainer",
        secondary: "onSecondary",
    })

    // A role is part of the grey ladder only if it IS grey. Chroma (max-min of
    // the RGB channels) rather than HSL saturation, because saturation lies
    // about very light colours: a near-white lilac like #F9F1F9 has an HSL
    // saturation of 0.33 and reads as white. 0.05 is the line: Ash's greys are
    // 0, the pale panels of the tinted templates are around 0.03, and the
    // palest real accent container in the set (nord's secondaryContainer,
    // #D0E6ED) is 0.11 -- more than twice the line, so no accent can be
    // mistaken for a grey by it.
    function isGrey(c) {
        return (Math.max(c.r, c.g, c.b) - Math.min(c.r, c.g, c.b)) <= 0.05;
    }

    // WCAG relative luminance, for the ink clamp below. Small, but it is the
    // same arithmetic the check uses, so the two cannot disagree about what
    // "readable" means.
    function relativeLuminance(c) {
        function channel(x) {
            return x <= 0.03928 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4);
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
    }
    function contrastRatio(a, b) {
        const la = relativeLuminance(a);
        const lb = relativeLuminance(b);
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
    }

    function applyLightGreyLadder() {
        function headroom(target, role) {
            const ink = root.lightLadderInks[role];
            return ink ? Appearance.m3colors[`m3${ink}`] : null;
        }
        // `shade` is the one place a tone is ever produced: same hue, same
        // saturation (HSV), value moved -- and only downwards, past the check
        // that it is actually darker than what the palette shipped with.
        function shade(c, wanted) {
            return Qt.hsva(c.hsvHue, c.hsvSaturation, Math.min(c.hsvValue, wanted), c.a);
        }
        for (const role in root.lightSurfaceLadder) {
            const current = Appearance.m3colors[`m3${role}`];
            // A palette file that does not carry the role at all is left
            // alone: `undefined` in, a colour out, is worse than the honest
            // absence. The templates this ship with all carry every one of
            // them (asserted by scripts/colors/check-light-ladder.py, not
            // assumed).
            if (current === undefined)
                continue;
            Appearance.m3colors[`m3${role}`] = shade(Qt.color(current), root.lightSurfaceLadder[role]);
        }
        for (const role in root.lightContrastLadder) {
            const current = Appearance.m3colors[`m3${role}`];
            if (current === undefined)
                continue;
            const c = Qt.color(current);
            if (!root.isGrey(c))
                continue;
            const wanted = root.lightContrastLadder[role];
            const ink = headroom(wanted, role);
            if (ink === null) {
                Appearance.m3colors[`m3${role}`] = shade(c, wanted);
                continue;
            }
            // Walk back toward the original value until the role's own ink
            // reads on it again (see `contrastRatio`), terminating on the original
            // value, which the palette is assumed to have been designed around
            // -- so the fallback is "leave this one as the template author had
            // it", not "ship a fill nobody can read".
            const inkColor = Qt.color(ink);
            let value = wanted;
            for (let step = 0; step <= 20; step++) {
                const candidate = Math.min(c.hsvValue, wanted + step * (c.hsvValue - wanted) / 20);
                const colour = shade(c, candidate);
                if (root.contrastRatio(colour, inkColor) >= 4.5) {
                    value = candidate;
                    break;
                }
            }
            Appearance.m3colors[`m3${role}`] = shade(c, value);
        }
    }

    // The live palette, as text, for scripts/colors/check-light-ladder.py and
    // for `qs -c ii ipc call theme state`. Same shape and same reason as `volumes state` and
    // `taskManager state`: the shell is the only thing that knows what it has
    // ACTUALLY applied, as opposed to what is in the file on disk -- and with
    // the light ladder in the path the two are no longer the same by
    // construction, which is exactly what a reader needs to be able to see.
    function paletteState() {
        function hex(c) {
            function part(x) {
                const v = Math.round(Math.max(0, Math.min(1, x)) * 255);
                return (v < 16 ? "0" : "") + v.toString(16);
            }
            return `#${part(c.r)}${part(c.g)}${part(c.b)}`;
        }
        const parts = [`mode=${Appearance.m3colors.darkmode ? "dark" : "light"}`];
        const roles = Object.assign({}, root.lightSurfaceLadder, root.lightContrastLadder);
        for (const role in roles)
            parts.push(`${role}=${hex(Appearance.m3colors[`m3${role}`])}`);
        return parts.join(" ");
    }

    function applyColors(fileContent) {
        const json = JSON.parse(fileContent)
        for (const key in json) {
            if (json.hasOwnProperty(key)) {
                // Convert snake_case to CamelCase
                const camelCaseKey = key.replace(/_([a-z])/g, (g) => g[1].toUpperCase())
                const m3Key = `m3${camelCaseKey}`
                Appearance.m3colors[m3Key] = json[key]
            }
        }
        
        Appearance.m3colors.darkmode = (Appearance.m3colors.m3background.hslLightness < 0.5)
    // Light mode's grey ladder. See `lightSurfaceLadder` / `lightContrastLadder`
    // for why this exists and what it changes; it runs BEFORE anything is
    // derived from the palette below (the desktop sync, the cursor, the lock
    // screen, the terminal), so every consumer sees the adjusted tones and none
    // of them sees the file's washed-out ones.
        if (!Appearance.m3colors.darkmode)
            root.applyLightGreyLadder();
        // Push the same decision out to the rest of the desktop. See
        // `applySystemTheme` for why this lives here and not on the toggle.
        root.applySystemTheme(Appearance.m3colors.darkmode);
        // Sync the active-template state with what colors.json actually IS.
        // The state can drift: the file is published by hand, by the template
        // picker before Persistent has flushed, or by the wallpaper pipeline.
        // Without this the dark/light toggle believes no template is active and
        // falls back to the (non-functional here) matugen route -- i.e. the
        // toggle does nothing. This is called AFTER `darkmode` is set, because
        // the whole point is to agree with the palette on screen.
        root.identifyActiveTemplate()
        // The cursor follows the theme, inverted for contrast: a WHITE cursor
        // on the dark theme, a dark cursor on the light theme. Runs on every
        // theme application, so it also re-asserts the right cursor at startup
        // after execs.lua has set its default.
        //
        // IT IS NOT DECIDED HERE. That is the whole point of this comment.
        //
        // This block used to hardcode the two theme names and call
        // `hyprctl setcursor` itself, and it was the single reason no cursor on
        // this desktop could ever be anything but the plain arrow: at the time
        // it named Bibata-Modern-Ice / Bibata-Modern-Classic and NEITHER ONE
        // EXISTED on this machine -- not in /usr/share/icons, not in
        // ~/.local/share/icons, nowhere. `setcursor` is the compositor's
        // cursor theme for every client, so naming a theme that is not
        // installed leaves Hyprland drawing its built-in arrow no matter what
        // any application requests. It was then repointed at
        // `capitaine-cursors` / `capitaine-cursors-light` as a stopgap.
        //
        // The mapping now lives in ONE place -- custom/theme.lua, in the
        // applyCursor() that runs inside its apply(), which
        // applyHyprlandTheme() below already calls on exactly the same
        // code path and at exactly the same frequency as this line used to
        // fire. Keeping a second copy here was not free even when the two
        // agreed: two `setcursor` calls racing on every theme change means
        // whichever happened to be dispatched last won, so the pointer could
        // disagree with the desktop for a frame, and a fix applied to one file
        // would silently not apply to the other.
        //
        // The Bibata themes named above ARE installed now (2026-10-04, from
        // the v2.0.7 release tarballs into ~/.local/share/icons/), verified by
        // decoding left_ptr at 32px: Ice is a white arrow with a dark keyline,
        // Classic is a black arrow with a white one, both hotspot (6,2). So
        // the original intent is live again -- just owned somewhere saner.
        // To change the pointer, edit M.CURSORS in custom/theme.lua.
        //
        // What is NOT covered: XWayland clients read XCURSOR_THEME once, when
        // the X server starts, so an already-running XWayland keeps the theme
        // it booted with and does not follow the toggle until XWayland
        // restarts. Wayland clients are unaffected -- they all ask the
        // compositor, and the compositor is what this changes.
    }

    function resetFilePathNextTime() {
        resetFilePathNextWallpaperChange.enabled = true
    }

    // ── The rest of the desktop follows the shell ─────────────────────────
    // The shell is not the only thing on screen that has an opinion about
    // light or dark. Every GTK3/GTK4/libadwaita application that is left on
    // "follow the system" reads one key -- org.gnome.desktop.interface
    // color-scheme -- and that is what makes a dark desktop actually dark
    // instead of a dark bar sitting on top of a desktop full of white windows.
    //
    // It is called from `applyColors` rather than from the toggle on purpose.
    // `applyColors` is the one place a palette becomes the live theme: the
    // template picker, the quick toggle, the global shortcut, the wallpaper
    // pipeline and plain startup-from-disk all funnel through it. Syncing on
    // the signal instead of the command means the system cannot drift away
    // from what the shell is showing -- which is exactly how this machine
    // ended up running a dark bar over a prefer-light desktop: the shell had
    // stopped calling switchwall.sh, and the gsettings write lived in that
    // script, so nothing carried the decision across.
    // A single key is not the desktop theme. `color-scheme` covers
    // libadwaita and GTK4, and it was the ONLY thing set here, so GTK3 apps
    // (which ignore it and read `gtk-theme`, pointing at an `adw-gtk3` that is
    // not installed and silently falls back to light Adwaita) and Qt apps
    // (no qtct here, so no key at all) stayed light on a dark desktop. That is
    // the "dark is selected but the apps are light" report.
    //
    // scripts/colors/sync-desktop-theme.sh owns the whole set now: color-scheme
    // AND the gtk-application-prefer-dark-theme flag in both settings.ini
    // files AND the Qt platform theme. One decision, one script, every
    // toolkit -- rather than three keys that can drift apart.
    //
    // The guard matters because `applyColors` runs on every file change, not
    // only on a real theme change; without it this would spawn a process each
    // time the file is touched.
    property string _lastSystemScheme: ""
    property string _lastHyprlandMode: ""
    function applySystemTheme(dark) {
        const want = dark ? "prefer-dark" : "prefer-light";
        if (root._lastSystemScheme !== want) {
            root._lastSystemScheme = want;
            Quickshell.execDetached(["bash", Quickshell.shellPath("scripts/colors/sync-desktop-theme.sh"), dark ? "dark" : "light"]);
        }
        // The same guard applies here. `applyColors` runs on every change to
        // the colours file, not only on a real theme change, and both of these
        // cost a process spawn, so the mode is remembered and only a genuine
        // change pushes to gsettings or to the compositor.
        const mode = dark ? "dark" : "light";
        if (root._lastHyprlandMode === mode) return;
        root._lastHyprlandMode = mode;
        root.applyHyprlandTheme(mode);
        // The terminal follows the theme the same way: kitty.conf holds no
        // colours any more, it `include`s a GENERATED theme.conf, and this
        // script writes that file for the mode and SIGUSR1-reloads running
        // windows. Lives beside the hyprlock regeneration because both are
        // "generated file from the mode" consumers, debounced by the same
        // guard -- a palette-file touch that does not change the mode must
        // not spawn it.
        Quickshell.execDetached(["bash", Quickshell.shellPath("scripts/colors/generate-kitty-theme.sh"), mode]);
        // The lock screen reads its colours from a GENERATED hyprlock.conf
        // (scripts/lock/generate-hyprlock-conf.sh), which baked the palette in
        // at generation time. A theme switch therefore needs a regeneration,
        // or SUPER+L shows the previous theme's colours. Runs detached and
        // debounced by the same mode guard as everything above.
        Quickshell.execDetached(["bash", Quickshell.shellPath("scripts/lock/generate-hyprlock-conf.sh")]);
    }

    // ── Hyprland's own chrome follows too ──────────────────────────────────
    // The compositor draws more than the shell does: window borders, the
    // desktop background, shadows, the inactive-window dim. Those were
    // hardcoded dark, in the Hyprland config, with no connection to the shell's
    // theme -- so the desktop could be light while the compositor was still
    // drawing dark chrome around every window.
    //
    // The colours themselves belong to Hyprland (custom/theme.lua holds a dark
    // and a light set); this only tells it which one. That split is deliberate:
    // the compositor should not have to import the shell's palette, and the
    // shell should not have to know what a border alpha is.
    //
    // The mode is ALSO written to a file, because `hyprctl eval` only reaches a
    // compositor that is already running. custom/theme.lua reads that file when
    // the config loads, so a Hyprland restart -- or a fresh login before the
    // shell is up -- starts in the right theme instead of flashing the other
    // one and correcting itself a second later.
    function applyHyprlandTheme(mode) {
        const home = Quickshell.env("HOME", false) ?? "";
        if (home !== "") {
            Quickshell.execDetached(["sh", "-c", `mkdir -p "${home}/.local/state/quickshell" && printf '%s' '${mode}' > "${home}/.local/state/quickshell/theme-mode"`]);
        }
        // `hyprctl keyword` refuses to run against this config -- it is a
        // Lua (non-legacy) parser and answers "keyword can't work with
        // non-legacy parsers. Use eval." -- so the compositor is driven
        // through hl.config() in the Lua module instead.
        Quickshell.execDetached(["hyprctl", "eval", `require("custom.theme").apply("${mode}")`]);
    }

    Connections {
        id: resetFilePathNextWallpaperChange
        enabled: false
        target: Config.options.background
        function onWallpaperPathChanged() {
            root.filePath = ""
            root.filePath = Directories.generatedMaterialThemePath
            resetFilePathNextWallpaperChange.enabled = false
        }
    }

    Timer {
        id: delayedFileRead
        interval: Config.options?.hacks?.arbitraryRaceConditionDelay ?? 100
        repeat: false
        running: false
        onTriggered: {
            root.applyColors(themeFileView.text())
        }
    }

	FileView { 
        id: themeFileView
        path: Qt.resolvedUrl(root.filePath)
        watchChanges: true
        onFileChanged: {
            this.reload()
            delayedFileRead.start()
        }
        onLoadedChanged: {
            const fileContent = themeFileView.text()
            root.applyColors(fileContent)
        }
        onLoadFailed: root.resetFilePathNextTime();
    }

    function toggleLightDark() {
        // NOTE (2026-09-28): this used to shell out to switchwall.sh --mode,
        // which regenerates the palette from the wallpaper through matugen.
        // That pipeline needs its Python venv and never ran on this install:
        // colors.json did not exist and the toggle silently did nothing.
        // The shell now themes itself from the design templates (see
        // themes/build_templates.py), so switching means copying the same
        // template's other palette over colors.json. The wallpaper route is
        // still available in settings via "follow wallpaper".
        root.switchMode(!Appearance.m3colors.darkmode);
    }

    /**
     * Apply a template palette by slug. The one theme-change primitive the
     * whole shell shares: the settings app, the right sidebar's quick toggle
     * and this service's own shortcuts all land here, and the running shell
     * picks the new palette up through the colors.json FileView watcher.
     */
    property string templatesDir: Quickshell.shellPath("themes/templates")
    Process {
        id: templateCopyProc
        onExited: root.reapplyTheme()
    }
    function applyTemplatePalette(template, dark) {
        if (!template || !template.palettes) return false;
        const file = dark ? template.palettes.dark : template.palettes.light;
        if (!file) return false;
        Persistent.states.themeTemplate = template.slug;
        Persistent.states.themeTemplateDark = dark;
        templateCopyProc.command = ["cp", `${root.templatesDir}/${file}`, Directories.generatedMaterialThemePath];
        templateCopyProc.running = false;
        templateCopyProc.running = true;
        return true;
    }

    /**
     * The manifest of design templates, read once. The settings app reads the
     * same file for its richer picker UI.
     */
    property var themeManifest: []
    FileView {
        path: Qt.resolvedUrl(`${root.templatesDir}/manifest.json`)
        watchChanges: false
        onLoadedChanged: {
            try {
                root.themeManifest = (JSON.parse(this.text()).templates) ?? [];
            } catch (error) {
                root.themeManifest = [];
            }
        }
        Component.onCompleted: this.reload()
    }

    /**
     * Identify which template the applied palette came from and record it in
     * the persistent state, so the dark/light toggle (and the settings picker's
     * active highlight) always agree with the palette actually on screen.
     *
     * A subprocess, not an in-QML read. This used to walk the manifest and
     * read every palette with a blocking `FileView`; a service singleton has no
     * window context, that read silently produced nothing, and the template was
     * therefore NEVER identified. The symptom was a dark/light toggle that
     * looked like it did nothing: `switchMode` found no active template and
     * handed off to the wallpaper pipeline, whose Python venv is not installed
     * on this machine, so colors.json never changed. The gsettings write lived
     * in that same dead script, which is how the desktop stayed `prefer-light`
     * under a dark bar.
     *
     * The helper also reads the manifest itself, so there is no longer a race
     * between "the colours arrived" and "the manifest finished loading" -- the
     * old code re-ran identification when the manifest landed, but that second
     * attempt needed a palette that had already been thrown away.
     */
    Process {
        id: identifyProc
        stdout: StdioCollector {
            id: identifyOutput
            onStreamFinished: {
                const parts = String(identifyOutput.text ?? "").trim().split(/\s+/);
                if (parts.length !== 2 || parts[0] === "")
                    return;  // a wallpaper-generated palette: no template to name
                const slug = parts[0];
                const dark = parts[1] === "dark";
                if (Persistent.states.themeTemplate !== slug)
                    Persistent.states.themeTemplate = slug;
                if (Persistent.states.themeTemplateDark !== dark)
                    Persistent.states.themeTemplateDark = dark;
            }
        }
    }
    function identifyActiveTemplate() {
        identifyProc.command = [
            "python3",
            Quickshell.shellPath("scripts/colors/identify-template.py"),
            Directories.generatedMaterialThemePath,
            root.templatesDir
        ];
        identifyProc.running = false;
        identifyProc.running = true;
    }

    /**
     * Switch dark/light. Uses the active template when there is one (the
     * normal case now); otherwise falls back to the wallpaper pipeline.
     * Returns the template applied, or null for the wallpaper fallback.
     */
    function switchMode(dark) {
        const slug = Persistent.states.themeTemplate ?? "";
        const entry = root.themeManifest.find(t => t.slug === slug) ?? null;
        if (entry && root.applyTemplatePalette(entry, dark))
            return entry;
        Quickshell.execDetached([Directories.wallpaperSwitchScriptPath, "--mode", dark ? "dark" : "light", "--noswitch"]);
        return null;
    }

    GlobalShortcut {
        name: "toggleLightDark"
        description: "Toggles between dark theme and light theme"

        onPressed: {
            root.toggleLightDark();
        }
    }

    IpcHandler {
        target: "theme"

        function toggleLightDark(): void {
            root.toggleLightDark();
        }

        function state(): string {
            return root.paletteState();
        }
    }
}

