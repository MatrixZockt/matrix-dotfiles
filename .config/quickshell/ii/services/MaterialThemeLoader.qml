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
    }
}

