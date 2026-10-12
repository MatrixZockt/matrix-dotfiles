pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import Quickshell.Wayland
// `Hyprland.dispatch`, for the wheel's desktop switch -- the same dispatcher
// form every other switch in this shell uses.
import Quickshell.Hyprland

import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * The SUPER-tap app search overlay: the design approved in
 * design/search-overlay-preview.html, built with the shell's own widgets.
 *
 * A frosted card centred on the monitor. The overlay window spans the whole
 * screen but paints nothing except the card, so the desktop around it stays
 * untouched; the compositor's blur rules (custom/rules.lua, xray off) let the
 * card show the APPLICATIONS behind it -- never the bare wallpaper -- so it
 * reads as sitting in front of whatever was open. A press outside the card,
 * Escape, or a desktop switch closes it.
 * Inside, top to bottom, exactly as the preview:
 *
 *   search field .... with the esc chip on the right
 *   tabs ............ Apps | Advanced
 *   Apps tab ........ Frequent grid + All apps grid (nothing typed),
 *                     a vertical icon+name list while typing
 *   Advanced tab .... grouped categories (terminal tools, system panels, ...)
 *   footer .......... key hints
 *
 * Data comes from the services the existing overview search already uses:
 * AppUsage for Frequent, AppSearch + LauncherSearch for queries and for the
 * advanced classification (terminal-only apps and distro panels, which the
 * plain search hides). Launching goes through GlobalStates.launchEntry, the
 * same choke point the overview results use, so an app that is already
 * running is focused instead of duplicated.
 *
 * Sizing: the card is 379 logical px wide -- the measured width of the bar's
 * centre island -- so it reads as the island's own dropdown, just re-centred
 * vertically. Colors, radius and fonts are the shell's live tokens
 * (Appearance.*), matching the preview.
 */
Scope {
    id: root

    readonly property bool open: GlobalStates.appSearchOverlayOpen

    // ── Fade in / fade out ────────────────────────────────────────────────
    //
    // One number, one item: `fade` drives the CARD's opacity and nothing else.
    // No scale, no blur, no shadow, no layer -- an opacity on an item that is
    // already in the scene graph is a single property write per frame, so this
    // costs one number's worth of work and cannot re-layout the menu (opacity
    // does not touch geometry, unlike the width/height/x/y animation the card
    // used to be tempted by).
    //
    // The window is kept mapped only while the fade is actually running
    // (`visible: root.open || root.fade > 0.01` below), so a closed menu is an
    // unmapped surface: it draws nothing, blur or no blur, and the shell spent
    // nothing to keep it. That is also what makes the fade-out possible at all
    // -- `visible: root.open` alone would unmap the surface on the same tick
    // the state flipped and the menu would snap out of existence.
    //
    // The durations ride the shell's own motion budget (motionScale), so the
    // performance power profile shortens these along with everything else
    // rather than leaving one surface still animating at full length.
    property real fade: 0

    // Whether the card has been shown at least once this session. Read by the
    // window's `visible` below, and the reason the second and every later SUPER
    // tap is instant while the first one is not: see the note there. Not
    // persisted -- a fresh shell is free to start with an unmapped surface.
    property bool hasOpened: false

    NumberAnimation {
        id: fadeAnim
        target: root
        property: "fade"
        // Re-opening or re-closing mid-fade carries on from where it is
        // instead of restarting from the far end.
        alwaysRunToEnd: false
    }

    // ── Geometry ──────────────────────────────────────────────────────────
    // 540 instead of the old 379. 379 was the width of the bar's centre
    // island, which made the launcher read as that island's dropdown -- but
    // you search IN a launcher, and at 379px a result row held one clipped
    // app name next to one icon. 540 is the width real launchers use: enough
    // for a 3-column grid whose labels are not truncated, a row height you
    // can hit, and a footer of key hints on one line. The grid, the field and
    // every row height below are derived from these, so the proportions hold
    // rather than being hand-tuned per part.
    readonly property real cardWidth: 540
    readonly property real pad: 18

    // Type and hit-target scale, so "bigger" means bigger everywhere and not
    // just a wider box with the same 11px text inside it.
    readonly property real fieldHeight: 44
    readonly property real rowHeight: 44
    readonly property real tileHeight: 76
    readonly property real gap: 6
    readonly property int gridColumns: 3

    // ── Overlay state ─────────────────────────────────────────────────────
    property string query: ""
    property int activeTab: 0 // 0 = Apps, 1 = Advanced
    property int selectedIndex: 0

    // ── Data ──────────────────────────────────────────────────────────────
    // Frequent: the apps the panel itself launched before, most recent first.
    readonly property var frequentApps: AppUsage.recent.slice(0, 6).map(r => AppUsage.entryFor(r.id)).filter(e => e)

    // All apps, alphabetically, minus the advanced ones (they live in the
    // Advanced tab, same split the overview search applies).
    readonly property var allApps: {
        const list = AppSearch.list.filter(app => !LauncherSearch.isSystemTool(app) && !app.runInTerminal);
        list.sort((a, b) => String(a.name).localeCompare(String(b.name)));
        return list;
    }

    // Advanced: everything the plain list holds back, grouped.
    readonly property var advancedEntries: AppSearch.list.filter(app => LauncherSearch.isSystemTool(app) || app.runInTerminal)

    readonly property var advancedGroups: {
        const groups = [
            { name: Translation.tr("Terminal & shells"), icon: "terminal", entries: [] },
            { name: Translation.tr("Audio & video hardware"), icon: "graphic_eq", entries: [] },
            { name: Translation.tr("System settings"), icon: "settings", entries: [] },
            { name: Translation.tr("Files & storage"), icon: "hard_drive", entries: [] },
            { name: Translation.tr("Network & firewall"), icon: "lan", entries: [] },
            { name: Translation.tr("Logs & diagnostics"), icon: "monitoring", entries: [] }
        ];
        const idOf = e => String(e.id ?? "").toLowerCase();
        const cmdOf = e => String((e.command ?? [])[0] ?? "").toLowerCase();
        for (const entry of root.advancedEntries) {
            if (entry.runInTerminal || ["kitty", "alacritty", "foot", "fish", "bash", "zsh", "konsole"].some(t => idOf(entry).includes(t) || cmdOf(entry).includes(t)))
                groups[0].entries.push(entry);
            else if (["qv4l2", "qvidcap", "hdspconf", "hdspmixer", "hwmixvolume", "envy24control", "hdajackretask", "alsamixer", "pavucontrol", "easymix", "mixxx"].some(t => idOf(entry) === t || cmdOf(entry).includes(t)))
                // Added 2026-09-30 with the demotion of these to Advanced (see
                // systemToolCommands in services/LauncherSearch.qml). Without a
                // branch of their own they all fell through to the final `else`
                // and were filed under "System settings" -- an HDSP audio mixer
                // and a Qt V4L2 capture test utility are not settings panels, and
                // a group called "System settings" holding them is just wrong.
                // Matched on the EXACT id as well as the command, so the list
                // cannot catch an unrelated app whose name merely contains one
                // of these words.
                groups[1].entries.push(entry);
            else if ((entry.categories ?? []).includes("Settings") || idOf(entry).includes("settings"))
                groups[2].entries.push(entry);
            else if (["gparted", "gnome-disks", "dolphin", "nautilus", "thunar", "btrfs", "snapper", "timeshift", "disks"].some(t => idOf(entry).includes(t) || cmdOf(entry).includes(t)))
                groups[3].entries.push(entry);
            else if (["network", "nm-", "firewall", "wifi"].some(t => idOf(entry).includes(t) || cmdOf(entry).includes(t)))
                groups[4].entries.push(entry);
            else if (["log", "journal", "monitor", "htop", "btop", "mission"].some(t => idOf(entry).includes(t) || cmdOf(entry).includes(t)))
                groups[5].entries.push(entry);
            else
                groups[2].entries.push(entry);
        }
        return groups.filter(g => g.entries.length > 0);
    }

    // The shell's own windows (Settings, Task Manager) lead the list. They are
    // not desktop entries, so AppSearch.fuzzyQuery cannot produce them at all
    // and typing "settings" used to find nothing but the distro's control
    // panels; LauncherSearch owns that list, and this is the same one the
    // overview search uses, so both surfaces always agree.
    readonly property var shellMatches: LauncherSearch.shellAppsMatching(root.query)

    // Is this entry one the Apps tab hides? The shell's own windows are NOT --
    // they are not desktop entries and the split has never claimed them -- so
    // `shellApp` is checked first and short-circuits, otherwise typing
    // "settings" would throw the shell's own Settings window into Advanced.
    function isAdvancedEntry(entry) {
        if (!entry || entry.shellApp === true)
            return false;
        return entry.runInTerminal === true || LauncherSearch.isSystemTool(entry);
    }

    // The fuzzy query, split at the source instead of filtered after the fact.
    // One pass over the same (already sorted) list the Apps tab used, then two
    // buckets: the Apps tab gets only what allApps would have contained, and
    // the Advanced tab gets everything else in the SAME ranking order. Both
    // buckets are needed. Filtering the query and stopping there is what made
    // "hdsp" a dead end -- the mixer IS installed, it is just not an app -- and
    // showing it in the Apps tab is what put HDSPConf and OpenJDK_Java 17 Shell
    // between Android Studio and Thunderbird.
    readonly property var rawMatches: {
        const q = root.query.trim();
        if (q.length === 0)
            return [];
        return AppSearch.fuzzyQuery(q);
    }

    // Apps tab. Filtered FIRST, then capped: capping before filtering (as this
    // used to) let eight system tools eat the top of a 15-row list, so a search
    // for an ordinary app could not even fill the rows it had.
    readonly property var matches: root.shellMatches.concat(
        root.rawMatches.filter(e => !isAdvancedEntry(e)).slice(0, 15 - root.shellMatches.length))

    // Advanced tab, while typing. Capped like the Apps tab: the raw fuzzy list
    // is unfiltered, so a two-letter query can name dozens of panel applets and
    // the list has to stop somewhere the card can actually hold.
    readonly property var advancedMatches: root.rawMatches.filter(isAdvancedEntry).slice(0, 15)

    // ── Emoji mode ────────────────────────────────────────────────────────
    //
    // The emoji prefix ("`:`" unless the config says otherwise) turns this
    // card's results into the emoji list. It is the panel SUPER+. opens that
    // has understood that prefix all along; this card -- the one a SUPER TAP
    // gives you -- only ever searched installed apps, so `:` ran through the
    // app pipeline, matched nothing, and answered "No matches". One prefix,
    // one meaning: the emoji service below is the same Emojis.fuzzyQuery that
    // panel uses, so the two doors show the same list in the same order and
    // cannot drift apart.
    readonly property string emojiPrefix: Config.options.search.prefix.emojis
    readonly property bool emojiMode: root.query.trim().startsWith(root.emojiPrefix)

    // The whole set when nothing follows the prefix -- `Emojis.fuzzyQuery("")`
    // returns every entry rather than nothing (checked against the live
    // service: `:` alone answers with all ~1900 of them), which is what makes
    // a bare `:` mean "show me the emojis" instead of an empty box.
    readonly property var emojiMatches: {
        if (!root.emojiMode)
            return [];
        const search = StringUtils.cleanPrefix(root.query.trim(), root.emojiPrefix);
        return Emojis.fuzzyQuery(search).map(line => {
            const glyph = line.match(/^\s*(\S+)/)?.[1] ?? "";
            return { glyph: glyph, name: line.replace(/^\s*\S+\s+/, "") };
        });
    }

    // How tall the emoji list is allowed to get. The card is as tall as its
    // contents, so this is the one number that keeps a 1900-row list inside the
    // screen; scroll bars and the rest follow from it.
    readonly property real emojiListHeight: 470

    // Right-aligned type label for a match row. No longer rendered -- the
    // match rows are name-only now (see the row's contentItem) -- but kept
    // because it is the shell's single place that knows an entry's KIND, and
    // the next thing to want it is a tooltip or a details pane. Dead code
    // beats a duplicated label table if that lands.
    function typeLabel(entry) {
        if (!entry)
            return Translation.tr("App");
        if (entry.shellApp)
            return Translation.tr("Shell");
        if (entry.runInTerminal)
            return Translation.tr("Terminal");
        if (LauncherSearch.isSystemTool(entry))
            return Translation.tr("System");
        return Translation.tr("App");
    }

    readonly property bool typing: query.trim().length > 0
    onQueryChanged: root.selectedIndex = 0

    // ── Open -> focus timing (diagnostic) ───────────────────────────────
    // Keystrokes typed between these two instants are the ones that go
    // nowhere, so the interval between them is the whole "typing right after
    // opening does not register" report, measured instead of guessed.
    // `state()` reports it as `focusDelayMs`.
    property double openedAt: 0
    property double focusLandedAt: 0
    // Which branch last took the overlay down, so "it closed itself" is
    // reportable rather than guessed at: `state()` returns it as `lastClose`
    // together with how long after opening it happened.
    property string lastClose: ""
    property double lastCloseAt: 0
    function noteClose(reason: string): void {
        root.lastClose = reason;
        root.lastCloseAt = Date.now();
    }

    // What the keyboard is on. One flat identity per visible row so ↑↓ and
    // ↵ have exactly one thing to act on: the Frequent grid's first row only
    // (the All apps grid is a click surface, like the preview's static tiles).
    readonly property int selectableCount: {
        // Emoji mode replaces the row set outright: while a prefix is being
        // typed the only selectable rows are the emojis, whatever tab is on.
        if (root.emojiMode)
            return root.emojiMatches.length;
        // Two different lists under one tab: groups when idle, entries when
        // typing. The row set the ↑↓ keys walk has to be the row set on screen.
        if (activeTab === 1)
            return typing ? advancedMatches.length : advancedGroups.length;
        if (typing)
            return matches.length;
        return Math.min(3, frequentApps.length); // Frequent grid's top row
    }

    // Open: reset the field, tab and selection. Close: make the close STICK.
    //
    // The second half is not bookkeeping, it is the difference between a menu
    // that closes and one that appears not to. SUPER *release* toggles this menu
    // (Overview.qml, `searchToggleRelease`), and that handler only stands down
    // while the interrupt flag is clear. So every way OUT of the menu has to
    // clear it: with the flag still set, a release in flight toggles the menu
    // straight back open -- Escape (or a click outside the card) closes it and
    // it reappears the moment SUPER comes up, which is exactly what "I cannot
    // close it" looks like from the keyboard. The wheel path clears the flag by
    // hand because it has to happen before its settle timer; every other exit
    // is covered here, on the close itself, whichever path caused it.
    onOpenChanged: {
        // The fade is driven from here -- the one place that knows the state
        // changed, whichever path changed it (Escape, the click catcher, a
        // launch, the wheel's desktop switch, or SUPER released again) -- so no
        // future exit can forget to fade.
        //
        // 160 in / 120 out at the shell's standard curve. A fade is a change of
        // ALPHA and nothing else: long enough to be seen as a transition,
        // short enough that the keyboard does not wait on it, and the field has
        // its focus the same tick either way (see below), so typing is never
        // blocked by the animation.
        fadeAnim.stop();
        fadeAnim.duration = Math.round((root.open ? 160 : 120)
            * Appearance.animationCurves.motionScale);
        fadeAnim.easing.type = Easing.BezierSpline;
        fadeAnim.easing.bezierCurve = root.open
            ? Appearance.animationCurves.standard
            : Appearance.animationCurves.emphasizedAccel;
        fadeAnim.to = root.open ? 1 : 0;
        fadeAnim.start();

        if (root.open) {
            root.hasOpened = true;
            root.openedAt = Date.now();
            root.focusLandedAt = 0;
            root.query = "";
            root.activeTab = 0;
            root.selectedIndex = 0;
            fieldInput.text = "";
            // Claim the field on the SAME tick the overlay opens rather than
            // waiting for the first timer tick or for `onVisibleChanged`:
            // SUPER is released, this handler runs, and the keystrokes that
            // follow arrive a few frames later. Asking here means the field
            // already holds scene focus by the time they do, and the timer
            // below only has to cover the compositor's own focus handover.
            fieldInput.forceActiveFocus();
            fieldForceTimer.restart();
            return;
        }
        GlobalStates.superReleaseMightTrigger = false;
        // The menu belongs to this surface and does not outlive it: closing the
        // launcher with a menu open leaves nothing of the menu behind.
        appMenu.open = false;
    }

    // The field takes focus, and KEEPS RE-ASKING until it actually has it.
    //
    // This used to be a single 60ms shot fired when `open` flipped -- which is
    // BEFORE the window has mapped, so on a busy shell the attempt was over and
    // done with while the surface did not exist yet. The compositor only hands
    // this overlay the keyboard when it maps, and mapping waits on the shell's
    // main thread, so the keystrokes typed right after the card appeared went to
    // the window underneath instead of the field: "the menu is open but I can't
    // type for a few seconds".
    //
    // Retrying every 60ms while open and unfocused covers all of it: the field
    // gets focus the instant the surface has the keyboard, a late or stale
    // window activation is corrected on the next tick, and the timer stops by
    // itself the moment focus lands (idle cost: none).
    Timer {
        id: fieldForceTimer
        // 20ms, not 60: one frame at 60Hz. The first keystroke after a SUPER
        // tap lands well inside the old 60ms window, so a focus handover that
        // needed a second attempt used to eat it -- "the menu is open but the
        // first letters do nothing". At a frame per attempt the correction is
        // invisible and the idle cost is nil (the timer stops the moment
        // focus lands).
        interval: 20
        repeat: true
        running: root.open && !fieldInput.activeFocus
        onTriggered: fieldInput.forceActiveFocus()
    }

    Connections {
        target: fieldInput
        function onActiveFocusChanged() {
            if (fieldInput.activeFocus && root.open && root.focusLandedAt === 0)
                root.focusLandedAt = Date.now();
            // Said out loud the moment typing becomes impossible: without this
            // "it does not take my keys" and "it took them fine" are the same
            // line in the log. `itemFocus` separates the two causes in one
            // glance (see state()).
            if (root.open && !fieldInput.activeFocus)
                console.log(`[focus] field lost focus while open`
                    + ` itemFocus=${fieldInput.focus}`
                    + ` openFor=${Date.now() - root.openedAt}ms`);
        }
    }

    function moveSelection(delta) {
        const n = root.selectableCount;
        if (n === 0)
            return;
        root.selectedIndex = ((root.selectedIndex + delta) % n + n) % n;
    }

    function activateSelection() {
        // An emoji row COPIES, it does not launch: there is no window behind an
        // emoji, and Enter on a highlighted row means the same thing as
        // clicking it.
        if (root.emojiMode) {
            root.copyEmoji(root.emojiMatches[root.selectedIndex]);
            return;
        }
        if (root.activeTab === 1) {
            // Typed: the rows are individual entries, so Enter launches the one
            // under the cursor. Idle: the rows are groups, which launch their
            // first entry (unchanged behaviour).
            if (root.typing) {
                const entry = root.advancedMatches[root.selectedIndex];
                if (entry)
                    root.launchEntry(entry);
                return;
            }
            const g = root.advancedGroups[root.selectedIndex];
            if (g)
                root.launchEntry(g.entries[0]);
            return;
        }
        if (root.typing) {
            const m = root.matches[root.selectedIndex];
            if (m)
                root.launchEntry(m);
            return;
        }
        const f = root.frequentApps[root.selectedIndex];
        if (f)
            root.launchEntry(f);
    }

    // Its own IPC target (moved out of shell.qml): `type`/`state` need the
    // overlay instance's live fields, which only a handler inside the same
    // file can reach.
    IpcHandler {
        target: "appSearch"

        function open(): void {
            GlobalStates.appSearchOverlayOpen = true;
        }

        function close(): void {
            root.noteClose("ipc");
            GlobalStates.appSearchOverlayOpen = false;
        }

        function toggle(): void {
            GlobalStates.appSearchOverlayOpen = !GlobalStates.appSearchOverlayOpen;
        }

        function state(): string {
            return JSON.stringify({
                open: root.open,
                // Focus probes, so "can I type yet" is answerable from a
                // terminal: `focus` is the field's scene focus, `winActive`
                // is whether the compositor actually gave this surface the
                // keyboard. Keys only reach the field when BOTH are true.
                focus: fieldInput.activeFocus,
                // Item-level focus, independent of whether the WINDOW still
                // holds the compositor's keyboard. `focus` true + `activeFocus`
                // false means the surface lost the keyboard (something else
                // took it) -- a completely different fault from the field
                // itself losing focus inside a live window.
                itemFocus: fieldInput.focus,
                winActive: panel.active,
                lastClose: root.lastClose,
                lastCloseAgo: root.lastCloseAt > 0 ? Date.now() - root.lastCloseAt : null,
                // The card's opacity, 0..1: the fade is a real animated value,
                // so it is readable here rather than guessed at from pixels.
                fade: Math.round(root.fade * 100) / 100,
                focusDelayMs: (root.open && root.openedAt > 0)
                    ? (root.focusLandedAt > 0 ? root.focusLandedAt - root.openedAt : -1)
                    : null,
                query: root.query,
                typing: root.typing,
                emojiMode: root.emojiMode,
                emojiCount: root.emojiMatches.length,
                matchCount: root.matches.length,
                advancedMatchCount: root.advancedMatches.length,
                selected: root.selectedIndex,
                tab: root.activeTab === 0 ? "apps" : "advanced"
            });
        }

        // Drive the typing state without a keyboard: injects the query into
        // the field and reports what the pipeline produced.
        function type(q: string): string {
            if (!GlobalStates.appSearchOverlayOpen)
                GlobalStates.appSearchOverlayOpen = true;
            fieldInput.text = q;
            return JSON.stringify({
                open: root.open,
                query: root.query,
                typing: root.typing,
                emojiMode: root.emojiMode,
                emojiCount: root.emojiMatches.length,
                matchCount: root.matches.length,
                advancedMatchCount: root.advancedMatches.length,
                selected: root.selectedIndex,
                firstName: root.matches.length > 0 ? String(root.matches[0].name) : null,
                firstAdvancedName: root.advancedMatches.length > 0 ? String(root.advancedMatches[0].name) : null
            });
        }

        // Verification helper: switch tabs without a keyboard (synthetic key
        // events turn out to disturb the SUPER-release state machine, so
        // ydotool cannot be trusted for this one).
        function setTab(t: string): string {
            root.activeTab = t === "advanced" ? 1 : 0;
            root.selectedIndex = 0;
            return `tab=${root.activeTab === 0 ? "apps" : "advanced"} groups=${root.advancedGroups.length} advancedMatches=${root.advancedMatches.length}`;
        }

        // Launch the highlighted row the way Enter does. Synthetic key events
        // reach the compositor rather than this layer surface, so the real
        // Enter path can only be exercised by hand; this runs the same
        // activateSelection() the key calls.
        function activate(): string {
            const target = root.activeTab === 1
                ? (root.typing ? root.advancedMatches[root.selectedIndex] : root.advancedGroups[root.selectedIndex]?.entries[0])
                : (root.typing ? root.matches[root.selectedIndex] : root.frequentApps[root.selectedIndex]);
            const name = String(target?.name ?? "");
            root.activateSelection();
            return `launched=${name}`;
        }

        // Open an app's right-click menu without a pointer.
        //
        // This overlay is a layer surface, so a synthetic press can hover it but
        // never lands in the QML -- the same limitation the To Do widget's tick
        // has. This calls the very function the right press calls, mapped from
        // a point inside the card, so the menu can be looked at (and its rows
        // reported) rather than described.
        function menu(id: string): string {
            // Both spellings, and the heuristic as a last resort: the launcher
            // hands over `kitty` in one place and `kitty.desktop` in another,
            // and a terminal has no way of knowing which one this is.
            const bare = String(id).replace(/\.desktop$/, "");
            const found = DesktopEntries.byId(id)
                ?? DesktopEntries.byId(bare)
                ?? DesktopEntries.heuristicLookup(bare);
            if (!found)
                return "not found: " + id;
            if (!GlobalStates.appSearchOverlayOpen)
                GlobalStates.appSearchOverlayOpen = true;
            root.openAppMenu(found, card, { x: card.width / 2, y: card.height * 0.4 });
            return appMenu.open
                ? `menu open for ${found.name} rows=${appMenu.rows.length}`
                : "no menu (a shell window has none)";
        }

        // What the menu is showing: the rows themselves -- the same list its
        // Repeater is handed -- what a destructive row is confirming, and the
        // probe behind all of it.
        function menuState(): string {
            return JSON.stringify({
                open: appMenu.open,
                entry: String((appMenu.entry && appMenu.entry.name) ?? ""),
                confirming: appMenu.confirming ? appMenu.confirming.actionId : null,
                rows: appMenu.rows.map(r => r.header !== undefined ? "# " + r.header : r.label),
                kind: AppAdmin.kind,
                package: AppAdmin.packageName,
                dataPaths: AppAdmin.dataPaths,
                actions: AppAdmin.actions.map(a => a.id),
                busy: AppAdmin.busy,
                resultOk: AppAdmin.resultOk,
                result: AppAdmin.resultText
            });
        }

        // Put the menu away and leave the launcher standing -- what a press
        // beside the menu does. Separate from `close` above, which takes the
        // whole launcher down: the two are different dismissals and the
        // difference is the thing worth being able to check.
        function menuClose(): string {
            appMenu.dismiss();
            return "menu open=" + appMenu.open;
        }

        // Choose a row the way a click does, found by label, so the confirm
        // step and then the run step can both be reached without a pointer.
        function menuChoose(label: string): string {
            const wanted = String(label ?? "").toLowerCase();
            const row = appMenu.rows.find(r => r.header === undefined
                && String(r.label ?? "").toLowerCase() === wanted);
            if (!row)
                return "no row: " + label;
            appMenu.choose(row);
            return "chose " + row.actionId;
        }
    }

    // A desktop switch dismisses the overlay. `activeWorkspace` is reassigned
    // on every compositor event (it is a parsed JSON object, so the property
    // change signal fires each time), which is why the id is compared rather
    // than the signal trusted: only a genuine workspace change closes.
    property int lastWorkspaceId: -1
    Connections {
        target: HyprlandData
        function onActiveWorkspaceChanged() {
            const id = HyprlandData.activeWorkspace?.id ?? -1;
            if (root.lastWorkspaceId !== -1 && id !== root.lastWorkspaceId && root.open) {
                root.noteClose(`ws ${root.lastWorkspaceId}->${id}`);
                GlobalStates.appSearchOverlayOpen = false;
            }
            root.lastWorkspaceId = id;
        }
    }

    // ── The wheel over the menu is a desktop switch ─────────────────────
    //
    // Scroll to change desktop while this menu is up and the desktop did not
    // move -- but the menu closed anyway, which is the two halves of one
    // gesture disagreeing. Both causes are here, and both are fixed here:
    //
    //   the switch   the overlay takes input over the whole screen, so a
    //                scroll lands on it and stops. A mouse wheel still got
    //                through -- the compositor's SUPER+scroll bind is a wheel
    //                bind and fires under a layer surface -- but a touchpad's
    //                finger scroll does not reach it, so with two fingers on
    //                the pad the desktop stood still.
    //   the close    SUPER then goes up having been interrupted by nothing,
    //                and the release side of the SUPER tap is what toggles
    //                this menu (Overview.qml, searchToggleRelease: only a KEY
    //                pressed while SUPER is down marks the chord as "not a
    //                tap"). One scroll, and the only thing it did was put the
    //                menu away.
    //
    // So the overlay finishes the job itself: it takes the wheel, moves the
    // desktop the way the SUPER+scroll bind would (up = +1, down = -1), and
    // puts itself away -- and it marks the chord as used, so the release that
    // follows cannot toggle the menu back.
    //
    // Two details make it behave rather than merely fire:
    //
    //   * it DEFERS to the compositor. With a mouse wheel the bind does fire,
    //     and the desktop moves on its own -- measured ~20ms after the event.
    //     So no switch is issued blindly: the wheel only arms a short settle
    //     timer, and at the end of it the active desktop is compared with the
    //     one the gesture started on. Moved -> the compositor did it, and the
    //     watcher above has already closed the menu; dispatching here as well
    //     would skip a desktop. Not moved -> the touchpad case, and the shell
    //     dispatches the switch itself.
    //
    //   * one gesture is one desktop. Settling waits for the wheel to stop, so
    //     a whole two-finger scroll moves one desktop instead of one per
    //     frame -- and since the switch takes the menu away with it, the rest
    //     of the same gesture lands on the desktop, not on the menu.
    property int wheelStartId: -1
    property int wheelStep: 0

    function wheelOverlay(step: int): void {
        if (root.wheelStartId === -1)
            root.wheelStartId = Number(HyprlandData.activeWorkspace?.id ?? 0);
        root.wheelStep = step;
        // The chord is not a plain SUPER tap any more (the same flag the key
        // interrupt sets), or the release toggles the menu straight back open
        // -- which is the half of this bug that was visible.
        GlobalStates.superReleaseMightTrigger = false;
        wheelSettle.restart();
    }

    Timer {
        id: wheelSettle
        // The compositor's own switch lands ~20ms after the wheel; this is
        // that with room to spare, and still not felt as a delay.
        interval: 120
        onTriggered: {
            const step = root.wheelStep;
            const from = root.wheelStartId;
            root.wheelStartId = -1;
            root.wheelStep = 0;
            if (step === 0 || !root.open)
                return;                 // no gesture in flight, or already gone
            const now = Number(HyprlandData.activeWorkspace?.id ?? 0);
            if (now !== from)
                return;                 // the compositor switched; nothing left to do
            root.noteClose(`wheel ${step > 0 ? "+1" : "-1"}`);
            GlobalStates.appSearchOverlayOpen = false;
            Hyprland.dispatch(`hl.dsp.focus({ workspace = "${step > 0 ? "+1" : "-1"}" })`);
        }
    }

    // ── The right-click menu ──────────────────────────────────────────────
    //
    // RippleButton calls `altAction` on a right press (its own MouseArea
    // already accepts the right button), so every app surface in this card
    // reaches the menu by the same route: the tile, the match row and the
    // advanced row each hand over their model and themselves.
    //
    // The press is mapped into the menu LAYER's coordinates rather than the
    // card's, because the menu is positioned where the pointer was and may sit
    // partly outside the card -- the layer fills the whole surface, so a menu
    // opened at the card's edge is placed correctly instead of being clamped
    // into the card and drawn in the wrong place.
    //
    // A shell window (Settings, Task Manager) is not an installed app: there
    // is no package behind it and nothing to uninstall, so it has no menu at
    // all rather than a menu of options that cannot apply.
    function openAppMenu(entry, item, mouse) {
        if (!entry || !item || !AppAdmin.available(entry))
            return;
        const point = item.mapToItem(menuLayer, mouse.x, mouse.y);
        appMenu.entry = entry;
        appMenu.anchorX = point.x;
        appMenu.anchorY = point.y;
        appMenu.open = true;
    }

    // Put an emoji on the clipboard. `Quickshell.clipboardText` is the one
    // clipboard write the shell makes (the panel's emoji rows and the clipboard
    // history both use it), so a copied emoji lands there and nowhere else.
    //
    // The card then closes, exactly as it does after launching anything: the
    // pick is the end of the interaction. The row that was clicked stays
    // visible for the length of the fade, so it reads as "that one".
    function copyEmoji(emoji) {
        if (!emoji || !emoji.glyph)
            return;
        Quickshell.clipboardText = emoji.glyph;
        root.noteClose("emoji");
        GlobalStates.appSearchOverlayOpen = false;
    }

    function launchEntry(entry) {
        if (!entry)
            return;
        root.noteClose("launch");
        GlobalStates.appSearchOverlayOpen = false;
        // A shell window is not a desktop entry: GlobalStates.launchEntry would
        // look for a window whose class equals the entry id, never find one,
        // raise a loading card and wait for an address that never comes. The
        // launch script owns all of that (it retargets a running copy or starts
        // one, and takes the card down either way).
        if (entry.shellApp) {
            LauncherSearch.launchShellApp(entry);
            return;
        }
        AppUsage.record(entry);
        GlobalStates.launchEntry(entry);
    }

    // The default state is closed, so there is nothing to seed in the common
    // case -- but a config reload that happens to land while the menu is open
    // would otherwise map it at zero opacity and leave it there until the next
    // state change. Same reason NowBarPanel seeds its own `t`.
    Component.onCompleted: root.fade = root.open ? 1 : 0

    PanelWindow {
        id: panel

        readonly property var fallbackScreen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
        screen: fallbackScreen
        // Mapped through the fade-out, and -- once the card has been seen once
        // -- kept mapped, because MAPPING IS WHAT COSTS THE FIRST KEYSTROKE.
        //
        // The compositor can only give this surface the keyboard after it has
        // been mapped, and mapping this one is not cheap: the surface is
        // created, its whole card is built and laid out, and only then does the
        // keyboard arrive. Measured on this machine with real input on the wire
        // (a SUPER tap, then "fi" typed at a range of gaps after it): at 0, 15
        // and 30ms after the tap both characters went to the window UNDERNEATH,
        // at 50 and 80ms the first one still did, and only from 120ms did both
        // land. So "I tap SUPER and start typing" lost the beginning of the
        // query, every time, and the shell had no way to hear those keys --
        // they were never addressed to it.
        //
        // A surface that is already mapped has nothing left to create, so the
        // keyboard arrives on the compositor's next frame instead of after the
        // card is built. `hasOpened` is what stops that being a standing cost
        // for a launcher nobody uses: before the first open this window is
        // unmapped exactly as it always was, and it only stays resident once
        // the card has actually been on screen.
        visible: root.hasOpened || root.open || root.fade > 0.01
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "quickshell:appSearchOverlay"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        // A RESIDENT SURFACE MUST NOT BE A TARGET.
        //
        // This one covers the whole screen whenever it is up, so a surface left
        // mapped with no input region is precisely the bug the sleep notice was
        // fixed for:
        // with nothing on screen to explain it, every click in the session
        // lands on it and goes nowhere. So the input region follows `open`
        // exactly -- empty while the launcher is closed, whole while it is up.
        // `Region { item: null }` is this shell's "no region" idiom (the same
        // one ScreenFlash, StatusTell and SleepNotice use).
        mask: root.open ? openRegion : closedRegion
        Region { id: closedRegion; item: null }
        Region { id: openRegion; item: clickCatcher }

        // Assert focus the moment the surface exists, so the first frame and the
        // first keystroke do not race. The timer above covers anything this one
        // cannot see (it runs while the window is still hidden).

        // Full-screen surface: the card floats centred on the monitor. The
        // compositor frost rules (custom/rules.lua: blur + xray off for this
        // namespace) show the APPLICATIONS behind the card through it, while
        // the wallpaper around it stays sharp and undimmed.
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        // Escape closes, from the WINDOW rather than from the field alone.
        //
        // The field's own Keys handler (down in the card) used to be the only
        // thing that ever answered Escape, which is fine right up until the
        // field is not the focused item -- a click on the card's own padding, a
        // focus handover the compositor never completed, or any moment while
        // the retry timer is between attempts. Then the key arrived at the
        // surface and NOTHING consumed it: the menu stayed up and Escape looked
        // dead. A Shortcut on the window is evaluated before item-level focus
        // matters, so the key is answered whenever this surface owns the
        // keyboard, whatever happens to be focused inside it.
        Shortcut {
            sequence: "Escape"
            enabled: root.open
            onActivated: {
                // A menu on screen is what Escape means first: closing the
                // launcher out from under an open menu would dismiss two
                // things with one key, the second of which is the surface the
                // user was working in.
                if (appMenu.open) {
                    appMenu.dismiss();
                    return;
                }
                root.noteClose("escape");
                GlobalStates.appSearchOverlayOpen = false;
            }
        }

        // The whole surface takes input while the card is open, so a press
        // anywhere outside the card lands on this catcher and simply closes.
        // While the card is CLOSED the region above is empty, so this catcher
        // is unreachable -- `enabled` says the same thing a second time so the
        // intent survives anyone editing the mask binding.
        MouseArea {
            id: clickCatcher
            enabled: root.open
            anchors.fill: parent
            onClicked: mouse => {
                // The first press beside an open menu puts the menu away and
                // leaves the launcher standing; the launcher itself takes the
                // next one. Without this, right-clicking an app and then
                // clicking its menu's padding would close the whole overlay.
                if (appMenu.open) {
                    appMenu.dismiss();
                    return;
                }
                root.noteClose(`click@${Math.round(mouse.x)},${Math.round(mouse.y)}/${panel.width}x${panel.height}`);
                GlobalStates.appSearchOverlayOpen = false;
            }
            // The wheel on the catcher is the desktop switch -- see
            // `wheelOverlay`. It sits here rather than on the card on purpose:
            // Qt offers a wheel to the item under the pointer and then walks
            // down the stack until something ACCEPTS it, so the card's own
            // lists get first refusal and only a scroll they refuse reaches
            // this handler. That fall-through is measured, not assumed -- a
            // wheel aimed at the middle of the card arrives here, because the
            // menu's grids do not scroll by wheel, and that scroll is exactly
            // the one that used to do nothing at all.
            //
            // The arithmetic is the bar island's own (NowBar.wheelDy/
            // wheelDx), including the natural-scroll un-inversion, so the
            // overlay and the island can never disagree about which way a
            // scroll goes. Positive is "next desktop", the direction the
            // compositor's SUPER+scroll uses.
            onWheel: event => {
                const pd = event.pixelDelta;
                const hasPixels = pd && (pd.x !== 0 || pd.y !== 0);
                const dy = hasPixels ? (event.inverted ? -pd.y : pd.y) : event.angleDelta.y / 120 * 40;
                const dx = hasPixels ? (event.inverted ? -pd.x : pd.x) : event.angleDelta.x / 120 * 40;
                const d = dy !== 0 ? dy : dx;
                if (d !== 0)
                    root.wheelOverlay(d > 0 ? 1 : -1);
            }
        }

        Rectangle {
            id: card

            // The window is wider than the visible card so the click catcher
            // around it belongs to THIS surface: a press just outside the
            // card must land on the catcher that closes the overlay, not on
            // whatever is underneath. `extra` is that catcher margin.
            //
            // It used to be described as shadow breathing room, back when the
            // card had a StyledRectangularShadow whose blur needed the room.
            // The shadow is gone (see below) but the catcher still does, so
            // the margin stays.
            readonly property real innerWidth: root.cardWidth
            readonly property real extra: 20

            anchors.centerIn: parent
            width: innerWidth + extra * 2
            implicitHeight: column.implicitHeight
            // The whole menu, in one property: see `root.fade`. Everything
            // drawn here is a child of this card, so the card's opacity is the
            // menu's opacity and there is nothing else to keep in step.
            opacity: root.fade
            radius: Appearance.rounding.large
            // Frosted glass: translucent, so the compositor blur shows the
            // windows behind the card (xray off = never the wallpaper).
            color: ColorUtils.transparentize(Appearance.colors.colLayer0, 0.3)

            // NO border and NO drop shadow -- both removed 2026-09-30.
            //
            // The border read as a "weird blurred border" because it was
            // being drawn INSIDE the compositor's blur region: the card is a
            // rounded rect inside a full-screen surface, the layer rule blurs
            // the surface, and a 1px hairline on the boundary is exactly the
            // kind of high-contrast 1-pixel feature that a blur pass smears
            // into a soft grey fringe. It was not a styling mistake; the hairline
            // and the blur were fighting each other. The card's own
            // translucency over the blurred desktop is what separates it from
            // the background, and that is enough.
            //
            // StyledRectangularShadow went for the same reason: its blur radius
            // sat outside the card and the compositor blurred that too, so the
            // "shadow" read as a halo rather than as depth.

            // Eat clicks that land on the card so they never reach the catcher.
            MouseArea {
                anchors.fill: parent
                // ...except that a click on the card is still a click away
                // from an open app menu, so the menu goes and the launcher
                // stays. The event is eaten either way.
                onClicked: {
                    if (appMenu.open)
                        appMenu.dismiss();
                }
            }

            ColumnLayout {
                id: column
                x: (parent.width - width) / 2
                width: card.innerWidth
                spacing: 0

                // ── Search field ─────────────────────────────────────────
                Item {
                    id: searchField
                    Layout.fillWidth: true
                    Layout.topMargin: root.pad
                    implicitHeight: root.fieldHeight

                    Rectangle {
                        anchors.fill: parent
                        radius: Appearance.rounding.normal
                        color: Appearance.colors.colSurfaceContainerLow
                        border.width: 1
                        border.color: Appearance.colors.colOutlineVariant
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 14
                        anchors.rightMargin: 8
                        spacing: 10

                        MaterialSymbol {
                            Layout.alignment: Qt.AlignVCenter
                            text: "search"
                            iconSize: 20
                            color: Appearance.colors.colOutline
                        }

                        TextInput {
                            id: fieldInput
                            Layout.fillWidth: true
                            color: Appearance.colors.colOnSurface
                            font.family: Appearance.font.family.main
                            font.pixelSize: Appearance.font.pixelSize.normal
                            clip: true
                            verticalAlignment: TextInput.AlignVCenter
                            inputMethodHints: Qt.ImhNoPredictiveText
                            // Drive the overlay state from the field.
                            onTextChanged: root.query = text
                            Keys.onPressed: event => {
                                if (event.key === Qt.Key_Escape) {
                                    if (appMenu.open) {
                                        appMenu.dismiss();
                                        event.accepted = true;
                                        return;
                                    }
                                    root.noteClose("escape");
                                    GlobalStates.appSearchOverlayOpen = false;
                                    event.accepted = true;
                                } else if (event.key === Qt.Key_Down) {
                                    root.moveSelection(1);
                                    event.accepted = true;
                                } else if (event.key === Qt.Key_Up) {
                                    root.moveSelection(-1);
                                    event.accepted = true;
                                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                    root.activateSelection();
                                    event.accepted = true;
                                } else if (event.key === Qt.Key_Tab) {
                                    root.activeTab = root.activeTab === 0 ? 1 : 0;
                                    root.selectedIndex = 0;
                                    event.accepted = true;
                                }
                            }

                            Text { // placeholder
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                visible: fieldInput.text.length === 0
                                text: Translation.tr("Search apps…")
                                color: Appearance.colors.colOutline
                                font: fieldInput.font
                            }
                        }

                        // esc chip
                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            implicitWidth: escText.implicitWidth + 14
                            implicitHeight: 22
                            radius: Appearance.rounding.verysmall
                            color: "transparent"
                            border.width: 1
                            border.color: Appearance.colors.colOutlineVariant

                            Text {
                                id: escText
                                anchors.centerIn: parent
                                text: "esc"
                                color: Appearance.colors.colOutline
                                font.family: Appearance.font.family.monospace
                                font.pixelSize: Appearance.font.pixelSize.small
                            }
                        }
                    }
                }

                // ── Tabs ─────────────────────────────────────────────────
                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 10
                    Layout.bottomMargin: 10
                    spacing: 4

                    Repeater {
                        model: [Translation.tr("Apps"), Translation.tr("Advanced")]

                        delegate: RippleButton {
                            id: tabButton
                            required property int index
                            required property string modelData
                            readonly property bool on: root.activeTab === tabButton.index
                            Layout.fillWidth: true
                            implicitHeight: 32
                            buttonRadius: Appearance.rounding.small
                            toggled: on
                            onClicked: {
                                root.activeTab = tabButton.index;
                                root.selectedIndex = 0;
                            }
                            // The active tab keeps the preview's raised look;
                            // toggled's primary fill is too loud for a segmented
                            // control, so the colours are pinned instead.
                            colBackground: on
                                ? Appearance.colors.colSurfaceContainerHigh
                                : ColorUtils.transparentize(Appearance.colors.colSurfaceContainerHigh, 1)
                            colBackgroundHover: on
                                ? Appearance.colors.colSurfaceContainerHighest
                                : Appearance.colors.colSurfaceContainerHigh
                            colBackgroundToggled: Appearance.colors.colSurfaceContainerHigh
                            colBackgroundToggledHover: Appearance.colors.colSurfaceContainerHighest

                            contentItem: Item {
                                implicitWidth: tabLabel.implicitWidth
                                implicitHeight: tabLabel.implicitHeight

                                Text {
                                    id: tabLabel
                                    anchors.centerIn: parent
                                    text: tabButton.modelData
                                    color: tabButton.on
                                        ? Appearance.colors.colOnSurface
                                        : Appearance.colors.colOnSurfaceVariant
                                    font.family: Appearance.font.family.main
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                }
                            }
                        }
                    }
                }

                // ── APPS TAB ─────────────────────────────────────────────
                ColumnLayout {
                    visible: root.activeTab === 0
                    Layout.fillWidth: true
                    spacing: 0

                    // While typing: vertical match list (the preview's state 2)
                    // -- unless an emoji prefix is being typed, which swaps in
                    // the emoji list below instead of app matches.
                    ColumnLayout {
                        visible: root.typing && !root.emojiMode
                        Layout.fillWidth: true
                        Layout.leftMargin: root.pad
                        Layout.rightMargin: root.pad
                        Layout.bottomMargin: 12
                        spacing: 2

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.bottomMargin: 4
                            spacing: 8

                            Text {
                                text: Translation.tr("Matches")
                                color: Appearance.colors.colOnSurfaceVariant
                                font.family: Appearance.font.family.main
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                font.letterSpacing: 0.7
                                font.capitalization: Font.AllUppercase
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: String(root.matches.length)
                                color: Appearance.colors.colOutline
                                font.family: Appearance.font.family.main
                                font.pixelSize: Appearance.font.pixelSize.smallest
                            }
                        }

                        Repeater {
                            model: root.matches

                            delegate: RippleButton {
                                id: matchRow
                                required property int index
                                required property var modelData
                                readonly property bool selected: root.selectedIndex === matchRow.index
                                Layout.fillWidth: true
                                implicitHeight: root.rowHeight
                                buttonRadius: Appearance.rounding.small
                                pointingHandCursor: true
                                onClicked: root.launchEntry(matchRow.modelData)
                                altAction: mouse => root.openAppMenu(matchRow.modelData, matchRow, mouse)
                                // Selected row = secondaryContainer fill, the
                                // shell's list-selection treatment (preview #333).
                                toggled: selected
                                colBackground: "transparent"
                                colBackgroundHover: Appearance.colors.colSurfaceContainerHigh
                                colBackgroundToggled: Appearance.colors.colSecondaryContainer
                                colBackgroundToggledHover: Appearance.colors.colSecondaryContainer

                                contentItem: RowLayout {
                                    spacing: 10

                                    // A shell window has a Material symbol, not
                                    // an icon-theme name, so the two row kinds
                                    // need different icon widgets.
                                    MaterialSymbol {
                                        Layout.alignment: Qt.AlignVCenter
                                        visible: matchRow.modelData.shellApp === true
                                        text: String(matchRow.modelData.icon ?? "")
                                        iconSize: 26
                                        color: matchRow.selected
                                            ? Appearance.colors.colOnSecondaryContainer
                                            : Appearance.colors.colOnSurface
                                    }
                                    IconImage {
                                        Layout.alignment: Qt.AlignVCenter
                                        visible: matchRow.modelData.shellApp !== true
                                        implicitSize: 26
                                        source: Quickshell.iconPath(matchRow.modelData.icon, Quickshell.shellPath("assets/icons/fluent/app-generic.svg"))
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: matchRow.modelData.name ?? ""
                                        elide: Text.ElideRight
                                        color: matchRow.selected
                                            ? Appearance.colors.colOnSecondaryContainer
                                            : Appearance.colors.colOnSurface
                                        font.family: Appearance.font.family.main
                                        font.pixelSize: Appearance.font.pixelSize.normal
                                    }
                                    // No description/type column. This row used
                                    // to carry a right-aligned label that showed
                                    // the app's `comment` (its .desktop
                                    // Description) while selected and a
                                    // type word ("App", "Shell", "System",
                                    // "Terminal") otherwise. Requested 2026-09-29:
                                    // a search result is the app's NAME and
                                    // nothing else -- the description was noise
                                    // that only appeared on the selected row,
                                    // so the row changed shape as you moved
                                    // through the list with the arrow keys.
                                }
                            }
                        }

                        Text {
                            visible: root.typing && root.matches.length === 0
                            Layout.fillWidth: true
                            Layout.topMargin: 8
                            Layout.bottomMargin: 8
                            horizontalAlignment: Text.AlignHCenter
                            text: root.advancedMatches.length > 0
                                // Otherwise "hdsp" on a machine that has
                                // hdspconf reports "No matches", which reads as
                                // "not installed" rather than "wrong tab" -- the
                                // one place the split can still feel like a
                                // dead end, so it names where the result went.
                                ? Translation.tr("No matches — %1 in Advanced").arg(String(root.advancedMatches.length))
                                : Translation.tr("No matches")
                            color: Appearance.colors.colOutline
                            font.family: Appearance.font.family.main
                            font.pixelSize: Appearance.font.pixelSize.smaller
                        }
                    }

                    // ── Emoji list (the emoji prefix, typed) ─────────────────
                    //
                    // One row per emoji: the glyph, then its name. Clicking (or
                    // Enter) copies the glyph and closes the card -- see
                    // copyEmoji. Nothing here launches an app, so there is no
                    // right-click app menu on these rows.
                    ColumnLayout {
                        visible: root.emojiMode
                        Layout.fillWidth: true
                        Layout.leftMargin: root.pad
                        Layout.rightMargin: root.pad
                        Layout.bottomMargin: 12
                        spacing: 2

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.bottomMargin: 4
                            spacing: 8

                            Text {
                                text: Translation.tr("Emojis")
                                color: Appearance.colors.colOnSurfaceVariant
                                font.family: Appearance.font.family.main
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                font.letterSpacing: 0.7
                                font.capitalization: Font.AllUppercase
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: String(root.emojiMatches.length)
                                color: Appearance.colors.colOutline
                                font.family: Appearance.font.family.main
                                font.pixelSize: Appearance.font.pixelSize.smallest
                            }
                        }

                        // A scrolling list, NOT the Repeater the app rows use.
                        //
                        // The card is as tall as its contents, so a Repeater
                        // over the whole emoji set (~1900 rows with `:` on its
                        // own) would build every row and grow the card past the
                        // screen. This builds the rows in view and scrolls
                        // inside a fixed height -- the same reason the other
                        // launcher's results are a ListView.
                        StyledListView {
                            id: emojiList
                            Layout.fillWidth: true
                            // Short lists stay short (three matches = three
                            // rows); long ones stop at the cap and scroll.
                            Layout.preferredHeight: Math.min(root.emojiListHeight, emojiList.contentHeight)
                            clip: true
                            spacing: 2
                            // Every keystroke REPLACES the model, so the add
                            // animation would pop every visible row in again on
                            // each key. This list is substituted, not appended
                            // to, and should look substituted.
                            animateAppearance: false
                            // ~1900 rows with no bar give no hint of where in
                            // them you are (see the flag's own comment).
                            scrollBarAlwaysOn: true
                            model: root.emojiMatches
                            // The arrows walk the same index this list draws its
                            // highlight on, so the selected row is kept in view
                            // rather than being selected off-screen.
                            currentIndex: root.selectedIndex
                            onCurrentIndexChanged: emojiList.positionViewAtIndex(root.selectedIndex, ListView.Contain)

                            delegate: RippleButton {
                                id: emojiRow
                                required property int index
                                required property var modelData
                                readonly property bool selected: root.selectedIndex === emojiRow.index
                                width: ListView.view.width
                                implicitHeight: root.rowHeight
                                buttonRadius: Appearance.rounding.small
                                pointingHandCursor: true
                                onClicked: root.copyEmoji(emojiRow.modelData)
                                toggled: selected
                                colBackground: "transparent"
                                colBackgroundHover: Appearance.colors.colSurfaceContainerHigh
                                colBackgroundToggled: Appearance.colors.colSecondaryContainer
                                colBackgroundToggledHover: Appearance.colors.colSecondaryContainer

                                contentItem: RowLayout {
                                    spacing: 10

                                    // The glyph itself -- a character, not an
                                    // icon file, and set in its own column wide
                                    // enough for the emoji font to draw it at
                                    // this size without clipping.
                                    Text {
                                        Layout.alignment: Qt.AlignVCenter
                                        Layout.preferredWidth: 36
                                        horizontalAlignment: Text.AlignHCenter
                                        text: emojiRow.modelData.glyph
                                        color: emojiRow.selected
                                            ? Appearance.colors.colOnSecondaryContainer
                                            : Appearance.colors.colOnSurface
                                        font.pixelSize: Appearance.font.pixelSize.larger
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: emojiRow.modelData.name ?? ""
                                        elide: Text.ElideRight
                                        color: emojiRow.selected
                                            ? Appearance.colors.colOnSecondaryContainer
                                            : Appearance.colors.colOnSurface
                                        font.family: Appearance.font.family.main
                                        font.pixelSize: Appearance.font.pixelSize.normal
                                    }
                                }
                            }
                        }

                        Text {
                            visible: root.emojiMatches.length === 0
                            Layout.fillWidth: true
                            Layout.topMargin: 8
                            Layout.bottomMargin: 8
                            horizontalAlignment: Text.AlignHCenter
                            text: Translation.tr("No matches")
                            color: Appearance.colors.colOutline
                            font.family: Appearance.font.family.main
                            font.pixelSize: Appearance.font.pixelSize.smaller
                        }
                    }

                    // Nothing typed: Frequent grid + All apps grid (state 1)
                    ColumnLayout {
                        visible: !root.typing
                        Layout.fillWidth: true
                        spacing: 0

                        RowLayout { // FREQUENT header
                            visible: root.frequentApps.length > 0
                            Layout.fillWidth: true
                            Layout.leftMargin: root.pad
                            Layout.rightMargin: root.pad
                            Layout.bottomMargin: 4
                            spacing: 8

                            Text {
                                text: Translation.tr("Frequent")
                                color: Appearance.colors.colOnSurfaceVariant
                                font.family: Appearance.font.family.main
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                font.letterSpacing: 0.7
                                font.capitalization: Font.AllUppercase
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: String(Math.min(6, root.frequentApps.length))
                                color: Appearance.colors.colOutline
                                font.family: Appearance.font.family.main
                                font.pixelSize: Appearance.font.pixelSize.smallest
                            }
                        }

                        GridLayout { // Frequent tiles: 3 across
                            visible: root.frequentApps.length > 0
                            Layout.fillWidth: true
                            Layout.leftMargin: root.pad
                            Layout.rightMargin: root.pad
                            Layout.bottomMargin: 8
                            columns: root.gridColumns
                            columnSpacing: root.gap
                            rowSpacing: root.gap

                            Repeater {
                                model: root.frequentApps.slice(0, 6)

                                delegate: RippleButton {
                                    id: freqTile
                                    required property int index
                                    required property var modelData
                                    readonly property bool selected: root.selectedIndex === freqTile.index
                                    Layout.fillWidth: true
                                    implicitHeight: root.tileHeight
                                    buttonRadius: Appearance.rounding.normal
                                    onClicked: root.launchEntry(freqTile.modelData)
                                    altAction: mouse => root.openAppMenu(freqTile.modelData, freqTile, mouse)
                                    toggled: selected
                                    colBackground: "transparent"
                                    colBackgroundHover: Appearance.colors.colSurfaceContainerHigh
                                    colBackgroundToggled: Appearance.colors.colSurfaceContainerHigh
                                    colBackgroundToggledHover: Appearance.colors.colSurfaceContainerHighest

                                    contentItem: ColumnLayout {
                                            spacing: 6
                                            IconImage {
                                                Layout.alignment: Qt.AlignHCenter
                                                implicitSize: 34
                                                source: Quickshell.iconPath(freqTile.modelData.icon, Quickshell.shellPath("assets/icons/fluent/app-generic.svg"))
                                            }
                                        Text {
                                            Layout.alignment: Qt.AlignHCenter
                                            Layout.maximumWidth: freqTile.width - 10
                                            text: freqTile.modelData.name ?? ""
                                            elide: Text.ElideRight
                                            horizontalAlignment: Text.AlignHCenter
                                            color: Appearance.colors.colOnSurface
                                            font.family: Appearance.font.family.main
                                            font.pixelSize: Appearance.font.pixelSize.small
                                        }
                                    }
                                }
                            }
                        }

                        RowLayout { // ALL APPS header
                            Layout.fillWidth: true
                            Layout.leftMargin: root.pad
                            Layout.rightMargin: root.pad
                            Layout.bottomMargin: 4
                            spacing: 8

                            Text {
                                text: Translation.tr("All apps")
                                color: Appearance.colors.colOnSurfaceVariant
                                font.family: Appearance.font.family.main
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                font.letterSpacing: 0.7
                                font.capitalization: Font.AllUppercase
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: String(root.allApps.length)
                                color: Appearance.colors.colOutline
                                font.family: Appearance.font.family.main
                                font.pixelSize: Appearance.font.pixelSize.smallest
                            }
                        }

                        // A fixed-height peek at the full alphabetical list --
                        // the card is a dropdown, not a window; reaching the
                        // rest of the catalogue happens by typing.
                        Item {
                            Layout.fillWidth: true
                            Layout.leftMargin: root.pad
                            Layout.rightMargin: root.pad
                            Layout.bottomMargin: 14
                            implicitHeight: 3 * root.tileHeight + 2 * root.gap // three rows of tiles
                            clip: true

                            GridLayout {
                                id: allAppsColumn
                                width: parent.width
                                columns: root.gridColumns
                                columnSpacing: root.gap
                                rowSpacing: root.gap

                                Repeater {
                                    model: root.allApps.slice(0, root.gridColumns * 3)

                                    delegate: RippleButton {
                                        id: allTile
                                        required property int index
                                        required property var modelData
                                        Layout.fillWidth: true
                                        implicitHeight: root.tileHeight
                                        buttonRadius: Appearance.rounding.normal
                                        onClicked: root.launchEntry(allTile.modelData)
                                        altAction: mouse => root.openAppMenu(allTile.modelData, allTile, mouse)

                                        contentItem: ColumnLayout {
                                                spacing: 6
                                                IconImage {
                                                    Layout.alignment: Qt.AlignHCenter
                                                    implicitSize: 34
                                                source: Quickshell.iconPath(allTile.modelData.icon, Quickshell.shellPath("assets/icons/fluent/app-generic.svg"))
                                            }
                                            Text {
                                                Layout.alignment: Qt.AlignHCenter
                                                Layout.maximumWidth: allTile.width - 10
                                                text: allTile.modelData.name ?? ""
                                                elide: Text.ElideRight
                                                horizontalAlignment: Text.AlignHCenter
                                                color: Appearance.colors.colOnSurface
                                                font.family: Appearance.font.family.main
                                                font.pixelSize: Appearance.font.pixelSize.small
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // ── ADVANCED TAB ─────────────────────────────────────────
                ColumnLayout {
                    visible: root.activeTab === 1
                    Layout.fillWidth: true
                    Layout.leftMargin: root.pad
                    Layout.rightMargin: root.pad
                    Layout.bottomMargin: 12
                    spacing: 2

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.bottomMargin: 4
                        spacing: 8

                        Text {
                            text: Translation.tr("System & terminal")
                            color: Appearance.colors.colOnSurfaceVariant
                            font.family: Appearance.font.family.main
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            font.letterSpacing: 0.7
                            font.capitalization: Font.AllUppercase
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            text: String(root.typing ? root.advancedMatches.length : root.advancedEntries.length)
                            color: Appearance.colors.colOutline
                            font.family: Appearance.font.family.main
                            font.pixelSize: Appearance.font.pixelSize.smallest
                        }
                    }

                    // While typing: the same flat entry list the Apps tab shows,
                    // restricted to the entries the Apps tab hides. The group
                    // rows below cannot stand in for this -- they are not
                    // filtered by the query and each one launches only its
                    // first entry, so there is no way to reach hdajackretask
                    // from a group but by luck of the ordering.
                    ColumnLayout {
                        visible: root.typing
                        Layout.fillWidth: true
                        spacing: 2

                        Repeater {
                            model: root.advancedMatches

                            delegate: RippleButton {
                                id: advancedRow
                                required property int index
                                required property var modelData
                                readonly property bool selected: root.selectedIndex === advancedRow.index
                                Layout.fillWidth: true
                                implicitHeight: root.rowHeight
                                buttonRadius: Appearance.rounding.small
                                pointingHandCursor: true
                                onClicked: root.launchEntry(advancedRow.modelData)
                                altAction: mouse => root.openAppMenu(advancedRow.modelData, advancedRow, mouse)
                                toggled: selected
                                colBackground: "transparent"
                                colBackgroundHover: Appearance.colors.colSurfaceContainerHigh
                                colBackgroundToggled: Appearance.colors.colSecondaryContainer
                                colBackgroundToggledHover: Appearance.colors.colSecondaryContainer

                                contentItem: RowLayout {
                                    spacing: 10

                                    IconImage {
                                        Layout.alignment: Qt.AlignVCenter
                                        implicitSize: 26
                                        source: Quickshell.iconPath(advancedRow.modelData.icon, Quickshell.shellPath("assets/icons/fluent/app-generic.svg"))
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: advancedRow.modelData.name ?? ""
                                        elide: Text.ElideRight
                                        color: advancedRow.selected
                                            ? Appearance.colors.colOnSecondaryContainer
                                            : Appearance.colors.colOnSurface
                                        font.family: Appearance.font.family.main
                                        font.pixelSize: Appearance.font.pixelSize.normal
                                    }
                                    // The one place the type label is still
                                    // drawn. Here it is doing real work rather
                                    // than decorating: a list of terminals,
                                    // distro panels and hardware applets is
                                    // otherwise several dozen rows of bare
                                    // names with nothing to tell them apart.
                                    Text {
                                        text: root.typeLabel(advancedRow.modelData)
                                        color: Appearance.colors.colOutline
                                        font.family: Appearance.font.family.main
                                        font.pixelSize: Appearance.font.pixelSize.smallest
                                    }
                                }
                            }
                        }

                        Text {
                            visible: root.advancedMatches.length === 0
                            Layout.fillWidth: true
                            Layout.topMargin: 8
                            Layout.bottomMargin: 8
                            horizontalAlignment: Text.AlignHCenter
                            text: Translation.tr("No matches")
                            color: Appearance.colors.colOutline
                            font.family: Appearance.font.family.main
                            font.pixelSize: Appearance.font.pixelSize.smaller
                        }
                    }

                    Repeater {
                        model: root.advancedGroups

                        delegate: RippleButton {
                            id: groupRow
                            required property int index
                            required property var modelData
                            readonly property bool selected: root.selectedIndex === groupRow.index
                            // Groups are the idle view; typing swaps the panel
                            // to the flat entry list above.
                            visible: !root.typing
                            Layout.fillWidth: true
                            implicitHeight: root.rowHeight
                                buttonRadius: Appearance.rounding.small
                            onClicked: {
                                // One row per group, like the preview; the row
                                // launches the group's first entry.
                                root.launchEntry(groupRow.modelData.entries[0]);
                            }
                            toggled: selected
                            colBackground: "transparent"
                            colBackgroundHover: Appearance.colors.colSurfaceContainerHigh
                            colBackgroundToggled: Appearance.colors.colSurfaceContainerHigh
                            colBackgroundToggledHover: Appearance.colors.colSurfaceContainerHighest

                            contentItem: RowLayout {
                                spacing: 9

                                Rectangle {
                                    Layout.alignment: Qt.AlignVCenter
                                    implicitWidth: 24
                                    implicitHeight: 24
                                    radius: Appearance.rounding.verysmall
                                    color: Appearance.colors.colSecondaryContainer

                                    MaterialSymbol {
                                        anchors.centerIn: parent
                                        text: groupRow.modelData.icon
                                        iconSize: 14
                                        color: Appearance.colors.colOnSecondaryContainer
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0
                                    Text {
                                        text: groupRow.modelData.name
                                        color: Appearance.colors.colOnSurface
                                        font.family: Appearance.font.family.main
                                        font.pixelSize: Appearance.font.pixelSize.smallie
                                    }
                                    Text {
                                        text: groupRow.modelData.entries.slice(0, 4).map(e => String(e.name ?? "")).join(", ")
                                        elide: Text.ElideRight
                                        color: Appearance.colors.colOutline
                                        font.family: Appearance.font.family.main
                                        font.pixelSize: Appearance.font.pixelSize.smallest
                                    }
                                }

                                Rectangle {
                                    Layout.alignment: Qt.AlignVCenter
                                    implicitWidth: countText.implicitWidth + 12
                                    implicitHeight: 16
                                    radius: Appearance.rounding.full
                                    color: "transparent"
                                    border.width: 1
                                    border.color: Appearance.colors.colOutlineVariant

                                    Text {
                                        id: countText
                                        anchors.centerIn: parent
                                        text: String(groupRow.modelData.entries.length)
                                        color: Appearance.colors.colOutline
                                        font.family: Appearance.font.family.main
                                        font.pixelSize: Appearance.font.pixelSize.smallest
                                    }
                                }

                                MaterialSymbol {
                                    Layout.alignment: Qt.AlignVCenter
                                    text: "chevron_right"
                                    iconSize: 14
                                    color: Appearance.colors.colOutline
                                }
                            }
                        }
                    }
                }

                // ── Footer ───────────────────────────────────────────────
                Item {
                    Layout.fillWidth: true
                    implicitHeight: 34

                    Rectangle { // hairline
                        anchors.top: parent.top
                        width: parent.width
                        height: 1
                        color: Appearance.colors.colOutlineVariant
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: root.pad
                        anchors.rightMargin: root.pad
                        spacing: 12

                        Text {
                            text: Translation.tr("↑↓ move")
                            color: Appearance.colors.colOutline
                            font.family: Appearance.font.family.monospace
                            font.pixelSize: Appearance.font.pixelSize.smallest
                        }
                        Text {
                            text: root.emojiMode
                                ? Translation.tr("↵ copy")
                                : Translation.tr("↵ launch")
                            color: Appearance.colors.colOutline
                            font.family: Appearance.font.family.monospace
                            font.pixelSize: Appearance.font.pixelSize.smallest
                        }
                        Text {
                            text: Translation.tr("tab %1").arg(root.activeTab === 0 ? Translation.tr("Advanced") : Translation.tr("Apps"))
                            color: Appearance.colors.colOutline
                            font.family: Appearance.font.family.monospace
                            font.pixelSize: Appearance.font.pixelSize.smallest
                        }
                    }
                }
            }
        }

        // ── The app's own right-click menu ────────────────────────────────
        //
        // Laid over the whole surface and declared LAST, so it is above both
        // the card and the click catcher. The layer is what makes that safe:
        // it is an empty Item that accepts no input of its own, so a press
        // that misses the menu falls through to the catcher underneath and
        // closes the launcher -- while a press on the menu belongs to the menu.
        //
        // It is also the coordinate space the press is mapped into (see
        // openAppMenu): the menu is placed where the pointer was, in the
        // surface's own coordinates, so it can sit beside the card at the
        // screen edge without being clamped into a card it is not a child of.
        Item {
            id: menuLayer
            anchors.fill: parent

            AppContextMenu {
                id: appMenu
                open: false
                entry: null
                onLaunchRequested: entry => root.launchEntry(entry)
                onAppActionRequested: action => {
                    // A desktop action asks for a NEW session -- "New window",
                    // "New private window" -- so it is executed directly rather
                    // than through GlobalStates.launchEntry, whose whole job is
                    // to redirect to the copy already running.
                    root.noteClose("app action");
                    GlobalStates.appSearchOverlayOpen = false;
                    action.execute();
                }
            }
        }
    }
}

