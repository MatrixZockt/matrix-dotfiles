pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import Quickshell.Wayland

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
        // Two different lists under one tab: groups when idle, entries when
        // typing. The row set the ↑↓ keys walk has to be the row set on screen.
        if (activeTab === 1)
            return typing ? advancedMatches.length : advancedGroups.length;
        if (typing)
            return matches.length;
        return Math.min(3, frequentApps.length); // Frequent grid's top row
    }

    // Reset the field, tab and selection each time the overlay opens.
    onOpenChanged: {
        if (root.open) {
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
        }
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
                focusDelayMs: (root.open && root.openedAt > 0)
                    ? (root.focusLandedAt > 0 ? root.focusLandedAt - root.openedAt : -1)
                    : null,
                query: root.query,
                typing: root.typing,
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

    PanelWindow {
        id: panel

        readonly property var fallbackScreen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
        screen: fallbackScreen
        visible: root.open
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "quickshell:appSearchOverlay"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

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

        // No input mask: the whole surface takes input, so a press anywhere
        // outside the card lands on this catcher and simply closes.
        MouseArea {
            anchors.fill: parent
            onClicked: mouse => {
                root.noteClose(`click@${Math.round(mouse.x)},${Math.round(mouse.y)}/${panel.width}x${panel.height}`);
                GlobalStates.appSearchOverlayOpen = false;
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
                    ColumnLayout {
                        visible: root.typing
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
                            text: Translation.tr("↵ launch")
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
    }
}

