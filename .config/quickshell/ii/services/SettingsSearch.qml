pragma Singleton
pragma ComponentBehavior: Bound

// QtQuick is not optional here. Every other singleton in this config
// (Config, Appearance, LlamaService, ...) declares `Singleton {` as its root
// and imports QtQuick, and so must this one: with only the `CF` import the
// root type did not resolve, the whole file failed to instantiate, and the
// error cascaded the entire config down to "Failed to load configuration".
// `Singleton` is a Quickshell type (declared in quickshell-core.qmltypes), not
// a QtQuick one. Every other singleton in this config -- Config, Appearance,
// LlamaService -- imports Quickshell for exactly this reason; without it the
// root type does not resolve, this file fails to instantiate, and the error
// cascades all the way to "Failed to load configuration".
import Quickshell
import qs.modules.common.functions as CF

/**
 * The settings search index.
 *
 * Windows' Settings is searchable because every setting is a first-class
 * entry with its own name, its page, and a few words people actually type --
 * "night light", not "hyprsunset"; "scale", not "monitor,preferred,auto".
 * This is that index: a flat table of entries, each of which knows which page
 * it lives on, so a search result can JUMP straight to the control rather than
 * merely opening a page and leaving you to hunt for it.
 *
 * Two kinds of entry, deliberately distinguished:
 *
 *   * a PAGE (kind: "page") -- the nav destinations themselves. Always
 *     searchable, always in the index, even if the page has no settings of
 *     its own.
 *   * a SETTING (kind: "setting") -- one control on one page. Carries the
 *     words it should be findable by, which are NOT always the words on the
 *     label: a user types "night light" for a control labelled "Colour
 *     temperature", and "big text" for "Interface scale".
 *
 * `keywords` is the reason this works. Matching on the visible label alone
 * makes search feel broken for exactly the settings people most want, because
 * the words on screen are the compositor's words, not the user's.
 *
 * The page list is NOT duplicated here. `pages()` reads the app's own
 * registry (passed in by the host), so adding a page to the app adds it to
 * search automatically and there is no second list to forget to update.
 */
Singleton {
    id: root

    // ── The one search box ────────────────────────────────────────────────
    // A single field, owned here rather than in the UI, so the keyboard
    // shortcut, the results list and the navigation all read the same value
    // and cannot disagree about what is being searched for.
    property string query: ""

    readonly property bool active: root.query.trim().length > 0
    property int highlightedIndex: 0

    // Set by the host at startup: the app's own page registry. Kept as a
    // property rather than imported so this service stays independent of the
    // window that owns it (and so it can be unit-probed).
    property var pageRegistry: []

    // ── Settings ─────────────────────────────────────────────────────────
    //
    // The table. `page` is a SLUG (see the app's registry), never a name --
    // names are translated, slugs are not, and a translated lookup key breaks
    // the moment the locale changes.
    //
    // `section` is the tab within the page where the setting lives (the
    // network page's "bluetooth" tab, for instance), or "" when the setting is
    // on the page's default view. It is passed through to the page so a result
    // can land on the right tab as well as the right page.
    readonly property var settings: [
        // ── System ────────────────────────────────────────────────────────
        { page: "display", section: "", name: "Display", keywords: "screen monitor panel resolution brightness", icon: "desktop_windows" },
        { page: "display", section: "", name: "Interface scale", keywords: "scale zoom size dpi text bigger smaller magnification", icon: "zoom_in", short: "scale zoom dpi hi-dpi hidpi" },
        { page: "display", section: "", name: "Brightness", keywords: "brightness dim backlight light screen luminance", icon: "brightness_6", short: "brightness backlight" },
        { page: "display", section: "", name: "Night light", keywords: "night light warm amber colour temperature eye strain bedtime hyprsunset", icon: "bedtime", short: "night nightlight night-light nite" },
        { page: "display", section: "", name: "Refresh rate", keywords: "refresh rate hz flicker fps motion", icon: "refresh" },
        { page: "display", section: "", name: "Variable refresh rate", keywords: "vrr variable refresh rate adaptive tearing gaming", icon: "speed", short: "vrr" },
        { page: "display", section: "", name: "Display orientation", keywords: "orientation rotate portrait landscape flip upside down", icon: "rotate_right" },
        { page: "display", section: "", name: "Render quality", keywords: "render quality performance balanced quality animations effects", icon: "diamond" },
        { page: "display", section: "", name: "Resolution", keywords: "resolution mode pixels native", icon: "grid_on" },
        { page: "display", section: "", name: "Display layout", keywords: "display layout arrange mirror extend position external second", icon: "space_dashboard" },

        { page: "sound", section: "", name: "Output", keywords: "output speaker sound device volume", icon: "volume_up", short: "audio output speakers sound" },
        { page: "sound", section: "", name: "Input", keywords: "input microphone mic voice record stereo", icon: "mic", short: "input mic microphone" },
        { page: "sound", section: "", name: "Volume", keywords: "volume loudness gain mixer", icon: "volume_up" },
        { page: "sound", section: "", name: "Earbang protection", keywords: "earbang protection clipping distortion safety", icon: "hearing" },
        { page: "sound", section: "", name: "Balance", keywords: "balance left right channels pan", icon: "balance" },

        { page: "services", section: "", name: "Notifications", keywords: "notification alert banner toast do not disturb", icon: "notifications" },
        { page: "services", section: "", name: "Do not disturb", keywords: "do not disturb dnd focus silence quiet", icon: "do_not_disturb_on", short: "dnd do not disturb" },
        { page: "services", section: "", name: "Lock screen", keywords: "lock screen lock screensaver blank", icon: "lock", short: "lock lockscreen" },

        // ── Devices ───────────────────────────────────────────────────────
        // ── Network ──────────────────────────────────────────────────────────
// The network page is two TABS (see NetworkConfig.sections), so these carry
        // a `section`: searching "pair a device" lands on the Bluetooth tab
        // directly rather than on the page with the wrong tab showing.
        { page: "network", section: "wifi", name: "Wi-Fi", keywords: "wifi wi-fi wireless network internet ssid connect", icon: "wifi", short: "wifi wi-fi" },
        { page: "network", section: "bluetooth", name: "Bluetooth", keywords: "bluetooth pair device connect wireless", icon: "bluetooth", short: "bt bluetooth" },
        { page: "interface", section: "", name: "Network", keywords: "network internet ethernet wired", icon: "lan", short: "net network" },
        { page: "interface", section: "", name: "Printers", keywords: "printer print scanners", icon: "print" },
        { page: "interface", section: "", name: "Removable media", keywords: "usb removable media drive disk mount", icon: "usb" },
        { page: "interface", section: "", name: "Camera", keywords: "camera webcam video", icon: "photo_camera" },
        { page: "interface", section: "", name: "Power & battery", keywords: "power battery charge energy saver", icon: "battery_charging_full", short: "battery power" },

        { page: "mouse", section: "", name: "Mouse", keywords: "mouse pointer cursor click speed", icon: "mouse", short: "mouse" },
        { page: "mouse", section: "", name: "Touchpad", keywords: "touchpad trackpad gestures tap scroll natural", icon: "touchpad", short: "tp touchpad trackpad" },
        { page: "mouse", section: "", name: "Natural scrolling", keywords: "natural scrolling direction reverse wheel", icon: "swap_vert", short: "scrl scroll scrolling natural-scroll" },
        { page: "mouse", section: "", name: "Click & drag", keywords: "click drag button tap finger", icon: "ads_click" },
        { page: "mouse", section: "", name: "Pointer speed", keywords: "pointer speed acceleration cursor sensitivity", icon: "speed" },
        { page: "mouse", section: "", name: "Double click", keywords: "double click interval", icon: "ads_click" },

        { page: "keyboard", section: "", name: "Keyboard", keywords: "keyboard layout keys repeat", icon: "keyboard" },
        { page: "keyboard", section: "", name: "Repeat rate", keywords: "repeat rate delay key hold", icon: "repeat" },
        { page: "keyboard", section: "", name: "Shortcuts", keywords: "shortcut hotkey keybind bindings", icon: "keyboard_command_key", short: "keybinds shortcuts hotkeys" },
        { page: "keyboard", section: "", name: "Input method", keywords: "input method ime keyboard layout language", icon: "translate" },
        { page: "keyboard", section: "", name: "Modifier keys", keywords: "modifier caps alt ctrl swap", icon: "keyboard_capslock" },

        { page: "keybinds", section: "", name: "Accounts", keywords: "account user login password profile", icon: "person" },
        { page: "keybinds", section: "", name: "Sign in", keywords: "sign in login account user", icon: "login" },

        // ── Appearance ────────────────────────────────────────────────────
        { page: "appearance", section: "", name: "Colour mode", keywords: "dark light theme colour mode night day appearance", icon: "dark_mode", short: "theme dark light mode" },
        { page: "appearance", section: "", name: "Wallpaper", keywords: "wallpaper background desktop picture image photo", icon: "wallpaper", short: "wlp wallpaper bg background" },
        { page: "appearance", section: "", name: "Accent colour", keywords: "accent colour color highlight tint", icon: "palette" },
        { page: "appearance", section: "", name: "Transparency", keywords: "transparency blur opacity see through acrylic", icon: "blur_on" },
        { page: "appearance", section: "", name: "Colour from wallpaper", keywords: "colour from wallpaper automatic colours extract palette", icon: "auto_awesome" },
        { page: "appearance", section: "", name: "Language", keywords: "language locale translation language", icon: "translate" },
        { page: "appearance", section: "", name: "Fonts", keywords: "font typeface family size text", icon: "font_download" },
        { page: "appearance", section: "", name: "Cursor", keywords: "cursor pointer mouse theme size shape", icon: "mouse" },
        { page: "appearance", section: "", name: "Rounded corners", keywords: "rounded corners radius rounding", icon: "rounded_corner" },

        { page: "desktop", section: "", name: "Desktop & wallpaper", keywords: "desktop wallpaper background icons workspace", icon: "desktop_windows" },
        { page: "desktop", section: "", name: "Desktop icons", keywords: "desktop icons show hide files", icon: "apps" },

        { page: "bar", section: "", name: "Top bar", keywords: "bar panel top status bar widgets", icon: "top_panel_close" },
        { page: "bar", section: "", name: "Dock", keywords: "dock favourites pinned taskbar launcher", icon: "dock" },
        { page: "bar", section: "", name: "Modules", keywords: "modules widgets bar items show hide", icon: "extension" },
        { page: "bar", section: "", name: "Tray", keywords: "tray systray icons status indicators", icon: "tray" },

        { page: "sidebars", section: "", name: "Sidebars", keywords: "sidebar panel edge left right reveal", icon: "view_sidebar" },
        { page: "sidebars", section: "", name: "Left sidebar", keywords: "left sidebar panel apps ai chat", icon: "view_sidebar" },
        { page: "sidebars", section: "", name: "Right sidebar", keywords: "right sidebar panel calendar weather music", icon: "view_sidebar" },

        // ── Apps & system ─────────────────────────────────────────────────
        { page: "quick", section: "", name: "Apps", keywords: "apps applications launchers favourites default", icon: "apps" },
        { page: "quick", section: "", name: "Default applications", keywords: "default applications link file handler", icon: "apps" },
        { page: "quick", section: "", name: "Startup", keywords: "startup autostart boot run at login", icon: "power_settings_new" },

        { page: "advanced", section: "", name: "For developers", keywords: "developer advanced debug logging experimental", icon: "code" },
        { page: "advanced", section: "", name: "Performance mode", keywords: "performance mode battery power saving animations", icon: "speed" },
        { page: "advanced", section: "", name: "Reload shell", keywords: "reload restart shell quickshell reset", icon: "restart_alt" },

        { page: "overview", section: "", name: "Overview", keywords: "overview home start summary system information", icon: "dashboard" },
        { page: "about", section: "", name: "About", keywords: "about version system information device name specs", icon: "info" }
    ]

    // The page list, as search entries.
    function pageEntries() {
        const pages = root.pageRegistry ?? [];
        return pages.map(p => ({
            kind: "page",
            page: p.slug,
            section: "",
            name: p.name,
            group: p.group ?? "",
            icon: p.icon ?? "settings",
            keywords: [p.slug, p.group ?? "", p.section ?? ""].join(" "),
            short: [p.slug, p.name].join(" ")
        }));
    }

    // Everything, pages first so a query that matches both a page and a
    // setting on it puts the page on top -- the page is the safer jump.
    readonly property var allEntries: {
        const settings = root.settings.map(s => Object.assign({ kind: "setting", group: "" }, s));
        return [...root.pageEntries(), ...settings];
    }

    function entryFor(slug) {
        return root.pageRegistry?.find(p => p.slug === slug) ?? null;
    }

    function pageName(slug) {
        return root.entryFor(slug)?.name ?? slug;
    }

    /**
     * Search.
     *
     * Fuzzy (fuzzysort, the same matcher the app launcher uses) rather than a
     * plain substring test, because the whole point is that people type
     * fragments: "nitelight", "scrl", "bt". A substring search would find none
     * of those and the feature would read as broken on first use.
     *
     * A page match OUTRANKS a setting match at equal score. "display" should
     * mean the Display page, not the "Display layout" row inside it.
     *
     * `Fuzzy.single(q, text)`, not `Fuzzy.go`: `go`'s second argument is a
     * target LIST. Passing a prepared search there makes every row score
     * identically, which is exactly the bug this was rewritten to fix -- all
     * queries came back as the same three unrelated results.
     *
     * NOTE the score direction, because getting it backwards is invisible and
     * catastrophic. fuzzysort's normalised `.score` is 1 for a PERFECT match
     * and 0 for the worst one -- higher is better, and the sort is DESCENDING.
     * Internally it works the other way round (`_score` is a penalty that
     * starts at -Infinity), which is exactly how the first version of this
     * ended up ranking "About" above "Bluetooth" for the query "bt".
     *
     * Three tweaks keep short queries from turning into noise. fuzzysort will
     * happily match "bt" against "About" at a plausible-looking score, so a
     * score floor rejects the long tail, an exact-substring hit is pushed to
     * the front (typing the whole word should beat a clever partial), and the
     * words people actually type as abbreviations live in `short`.
     */
    readonly property var results: {
        const q = root.query.trim();
        if (q.length === 0)
            return [];
        const lower = q.toLowerCase();
        const scored = [];
        for (const entry of root.allEntries) {
            // The name is weighted above the keywords so a label that matches
            // directly outranks one that only mentions the word in passing.
            const byName = CF.Fuzzy.single(q, entry.name);
            const byKeyword = entry.keywords ? CF.Fuzzy.single(q, entry.keywords) : null;
            const byShort = entry.short ? CF.Fuzzy.single(q, entry.short) : null;
            const best = [byName, byKeyword, byShort].filter(Boolean)
                .reduce((a, b) => (!a || b.score > a.score ? b : a), null);
            if (!best)
                continue;
            // 1 = perfect, ~0 = scattered letters that merely happen to be in
            // order. Below 0.4 it is a coincidence, not a match, and a list of
            // coincidences is worse than a short list.
            if (best.score < 0.4)
                continue;

            let score = best.score;
            // An abbreviation is an exact hit by definition, not a fuzzy one,
            // so it beats even a good name match.
            if (byShort)
                score = Math.max(score, byShort.score);
            else if (byName)
                score = byName.score;
            else
                score = byKeyword.score * 0.75;

            // Typing the whole word is the common case; make sure it lands
            // above the entries that merely contain the letters in order.
            const haystack = (entry.name + " " + (entry.keywords ?? "")).toLowerCase();
            if (haystack.includes(lower) || haystack.includes(" " + lower))
                score = Math.min(1, score + 0.1);

            // A page match outranks a setting match at equal quality: the page
            // is the safer jump, and "display" should mean the Display page.
            if (entry.kind === "page")
                score = Math.min(1.05, score + 0.1);
            scored.push({ entry: entry, score: score });
        }
        scored.sort((a, b) => b.score - a.score);
        return scored.slice(0, 40).map(s => s.entry);
    }

    readonly property var highlighted: root.results.length > 0
        ? root.results[Math.max(0, Math.min(root.highlightedIndex, root.results.length - 1))]
        : null

    function reset() {
        root.query = "";
        root.highlightedIndex = 0;
    }

    // Typing a new query resets the highlight: keeping index 3 while the
    // result list is rebuilt under it makes Enter open something the user
    // never pointed at.
    onQueryChanged: root.highlightedIndex = 0

    function moveHighlight(delta) {
        if (root.results.length === 0)
            return;
        const next = root.highlightedIndex + delta;
        if (next < 0)
            root.highlightedIndex = root.results.length - 1;
        else if (next >= root.results.length)
            root.highlightedIndex = 0;
        else
            root.highlightedIndex = next;
    }

    // Where a result goes. A setting carries its page AND its section, so
    // "Night light" lands on the Display page with the right tab already open
    // rather than dumping the user at the top of the page.
    function targetFor(entry) {
        if (!entry)
            return null;
        return { page: entry.page, section: entry.section ?? "" };
    }
}

