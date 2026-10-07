import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import Qt.labs.synchronizer
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

Scope {
    id: overviewScope
    property bool dontAutoCancelSearch: false

    // The highest desktop number in use right now: never less than the desktop you
    // are on, and never less than whatever hyprctl reports. That is the grid's
    // "how many desktops exist", read live. It is captured into
    // GlobalStates.overviewDesktopCount when the grid opens, so the tiles and the
    // Tab stepping agree for the whole time it is up.
    function existingDesktopCount() {
        const monitor = Hyprland.focusedMonitor;
        let highest = Math.max(1, Math.min(100, monitor?.activeWorkspace?.id ?? 1));
        const list = HyprlandData.workspaces ?? [];
        for (let i = 0; i < list.length; i++) {
            const id = list[i]?.id ?? 0;
            if (id > 0 && id < 100)
                highest = Math.max(highest, id);
        }
        return highest;
    }

    // ── Tap-mode click-away catcher ──────────────────────────────────────
    // A full-screen surface UNDER the grid (created first, so the panel maps
    // above it): in tap mode any click that is not on a tile lands here and
    // closes the overview -- the click-away a key-held peek never needs (its
    // release does the closing). The panel's own input mask still routes
    // tile clicks to the grid; this window only ever sees the rest of the
    // screen. Created before panelWindow on purpose.
    PanelWindow {
        id: tapCatcher
        visible: GlobalStates.overviewOpen && GlobalStates.overviewTapMode
        color: "transparent"
        WlrLayershell.namespace: "quickshell:overview-tapcatch"
        WlrLayershell.layer: WlrLayer.Top
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        MouseArea {
            anchors.fill: parent
            onClicked: GlobalStates.overviewOpen = false
        }
    }

    PanelWindow {
        id: panelWindow
        property string searchingText: ""
        readonly property HyprlandMonitor monitor: Hyprland.monitorFor(panelWindow.screen)
        property bool monitorIsFocused: (Hyprland.focusedMonitor?.id == monitor?.id)
        visible: GlobalStates.overviewOpen

        WlrLayershell.namespace: "quickshell:overview"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: GlobalStates.overviewOpen ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        color: "transparent"

        mask: Region {
            item: GlobalStates.overviewOpen ? columnLayout : null
        }

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        Connections {
            target: GlobalStates
            function onOverviewOpenChanged() {
                if (!GlobalStates.overviewOpen) {
                    searchWidget.disableExpandAnimation();
                    overviewScope.dontAutoCancelSearch = false;
                    // Tap mode never joined the grab, so dismissing it here
                    // would fire the very cleared->dismiss chain that closes
                    // key-held sessions -- skip it in that mode.
                    if (!GlobalStates.overviewTapMode)
                        GlobalFocusGrab.dismiss();
                    // Back to reading the desktop count live (the next open
                    // freezes a fresh one).
                    GlobalStates.overviewDesktopCount = 0;
                    // The next open decides the mode again; a stale tap-mode
                    // flag would make a SUPER+Tab peek grab-less.
                    GlobalStates.overviewTapMode = false;
                } else {
                    if (!overviewScope.dontAutoCancelSearch) {
                        searchWidget.cancelSearch();
                    }
                    // Tap mode is deliberately modal-less: no compositor
                    // focus grab. The grab needs a held key to stay alive
                    // and clears itself otherwise -- closing the grid under
                    // the user a couple of seconds in.
                    if (!GlobalStates.overviewTapMode)
                        GlobalFocusGrab.addDismissable(panelWindow);
                }
            }
        }

        Connections {
            target: GlobalFocusGrab
            function onDismissed() {
                GlobalStates.overviewOpen = false;
            }
        }
        implicitWidth: columnLayout.implicitWidth
        implicitHeight: columnLayout.implicitHeight

        function setSearchingText(text) {
            searchWidget.setSearchingText(text);
            searchWidget.focusFirstItem();
        }

        Column {
            id: columnLayout
            visible: GlobalStates.overviewOpen
            anchors {
                horizontalCenter: parent.horizontalCenter
                top: parent.top
            }
            spacing: -8
            // The search field would normally be holding the keyboard. In the
            // desktop panel there is no field, so the keyboard has to land here or
            // Escape would have nothing to reach.
            focus: GlobalStates.overviewOpen && GlobalStates.overviewMode === "desktops"

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    GlobalStates.overviewOpen = false;
                }
            }

            // Only in the search panel. SUPER+Tab is a look at your desktops, not a
            // search prompt, so it does not get a text field.
            SearchWidget {
                id: searchWidget
                anchors.horizontalCenter: parent.horizontalCenter
                visible: GlobalStates.overviewMode !== "desktops"
                Synchronizer on searchingText {
                    property alias source: panelWindow.searchingText
                }
            }

            // Only for the desktop panels -- never for the search panel, which is
            // what stopped the grid from appearing under an empty search field.
            Loader {
                id: overviewLoader
                anchors.horizontalCenter: parent.horizontalCenter
                active: GlobalStates.overviewOpen && GlobalStates.overviewMode !== "search"
                    && (Config?.options.overview.enable ?? true)
                sourceComponent: OverviewWidget {
                    screen: panelWindow.screen
                }
            }
        }
    }

    function toggleClipboard() {
        if (GlobalStates.overviewOpen && overviewScope.dontAutoCancelSearch) {
            GlobalStates.overviewOpen = false;
            return;
        }
        GlobalStates.overviewMode = "search";
        overviewScope.dontAutoCancelSearch = true;
        panelWindow.setSearchingText(Config.options.search.prefix.clipboard);
        GlobalStates.overviewOpen = true;
    }

    function toggleEmojis() {
        if (GlobalStates.overviewOpen && overviewScope.dontAutoCancelSearch) {
            GlobalStates.overviewOpen = false;
            return;
        }
        GlobalStates.overviewMode = "search";
        overviewScope.dontAutoCancelSearch = true;
        panelWindow.setSearchingText(Config.options.search.prefix.emojis);
        GlobalStates.overviewOpen = true;
    }

    IpcHandler {
        target: "search"


        // The search panel: the field, the recently-used row, nothing else.
        function toggle() {
            // SUPER-tap now opens the app search overlay (the card under the
            // centre island); this IPC path follows it so every entry point
            // lands on the same launcher.
            GlobalStates.appSearchOverlayOpen = !GlobalStates.appSearchOverlayOpen;
        }
        // Diagnostics: what the live app database says about a name (ids,
        // categories, "advanced" demotion) -- entry visibility decidable
        // from a terminal.
        function debugApps(substr: string): string {
            return LauncherSearch.debugApps(substr);
        }
        // What a query actually resolves to on the overview search surface (the
        // SUPER overlay has its own `type` diagnostic). Answers with the result
        // names in order, so a missing entry -- the shell's own Settings and
        // Task Manager above all -- is visible from a terminal.
        function type(q: string): string {
            LauncherSearch.query = q;
            return (LauncherSearch.results ?? []).map(r => String(r?.name ?? "")).join(" | ");
        }
        function workspacesToggle() {
            GlobalStates.overviewMode = "desktops";
            if (!GlobalStates.overviewOpen)
                GlobalStates.overviewDesktopCount = overviewScope.existingDesktopCount();
            GlobalStates.overviewOpen = !GlobalStates.overviewOpen;
        }
        function close() {
            GlobalStates.overviewOpen = false;
        }
        function open() {
            GlobalStates.overviewMode = "search";
            GlobalStates.overviewOpen = true;
        }
        // Opens the multi-desktop grid specifically (never the single-desktop
        // variant), and never toggles: SUPER+Tab is a hold, so pressing it when
        // the grid is somehow already up must not close it.
        function openWorkspaces() {
            GlobalStates.overviewMode = "desktops";
            GlobalStates.overviewSingleWorkspace = false;
            // Freeze the tile count for this hold -- see stepDesktop below.
            GlobalStates.overviewDesktopCount = overviewScope.existingDesktopCount();
            GlobalStates.overviewOpen = true;
        }
        // The tap-opened variant (the 4-finger TAP): identical grid, but
        // modal-less -- no focus grab -- and a TOGGLE, since there is no held
        // key whose release could close it. A second tap (or the click-away
        // catcher, or Escape) closes it. The grab-free open is the whole
        // point: the grab self-clears without a held key, which used to slam
        // the grid shut ~2.5s in.
        function tapWorkspaces() {
            if (GlobalStates.overviewOpen && GlobalStates.overviewMode === "desktops"
                && GlobalStates.overviewTapMode) {
                GlobalStates.overviewOpen = false;
                return;
            }
            GlobalStates.overviewTapMode = true;
            GlobalStates.overviewMode = "desktops";
            GlobalStates.overviewSingleWorkspace = false;
            GlobalStates.overviewDesktopCount = overviewScope.existingDesktopCount();
            GlobalStates.overviewOpen = true;
        }
        // The desktop grid scoped to one desktop -- ALT+Tab's window switcher.
        function openWindows() {
            GlobalStates.overviewMode = "windows";
            GlobalStates.overviewSingleWorkspace = true;
            GlobalStates.overviewOpen = true;
        }

        // Walk to the next (+1) or previous (-1) desktop while the grid is held
        // open on SUPER+Tab, wrapping inside the tiles the grid is actually
        // drawing: the desktops that exist plus the one empty "new desktop" slot.
        //
        // This lives here rather than in the keybind on purpose. The keybind
        // cannot see how many desktops exist, so it used to wrap over a fixed
        // group of ten -- Tab walked onto empty desktops the grid never showed,
        // which is exactly the "hidden somewhere" feeling the grid was meant to
        // replace. The shell knows the count; the keybind just asks.
        function stepDesktop(delta: int) {
            const monitor = Hyprland.focusedMonitor;
            const active = Math.max(1, Math.min(100, monitor?.activeWorkspace?.id ?? 1));
            // The frozen count from when the grid opened, so one Tab press cannot
            // change how many desktops the next press believes there are.
            const existing = GlobalStates.overviewDesktopCount > 0
                ? GlobalStates.overviewDesktopCount
                : overviewScope.existingDesktopCount();
            const columns = Math.max(1, Math.min(Config.options.overview.columns, existing + 1));
            const rows = Math.max(1, Config.options.overview.rows);
            const shown = rows * columns;
            const groupBase = Math.floor((active - 1) / shown) * shown;
            const indexInGroup = active - groupBase; // 1..shown
            const nextIndex = ((indexInGroup - 1 + delta) % shown + shown) % shown + 1;
            // The Lua dispatcher form, like every other dispatch in this shell:
            // this Hyprland runs the Lua config parser, where a bare
            // `workspace 3` string is not a dispatcher it recognises.
            Hyprland.dispatch(`hl.dsp.focus({ workspace = ${groupBase + nextIndex} })`);
        }
        function toggleReleaseInterrupt() {
            GlobalStates.superReleaseMightTrigger = false;
        }
        function clipboardToggle() {
            overviewScope.toggleClipboard();
        }
    }

    GlobalShortcut {
        name: "searchToggle"
        description: "Toggles search on press"

        onPressed: {
            GlobalStates.overviewMode = "search";
            GlobalStates.overviewOpen = !GlobalStates.overviewOpen;
        }
    }
    GlobalShortcut {
        name: "overviewWorkspacesClose"
        description: "Closes overview on press"

        onPressed: {
            GlobalStates.overviewOpen = false;
        }
    }
    GlobalShortcut {
        name: "overviewWorkspacesToggle"
        description: "Toggles the multi-desktop overview on press"

        onPressed: {
            // Full overview: the whole rows x columns grid of desktops.
            GlobalStates.overviewMode = "desktops";
            GlobalStates.overviewSingleWorkspace = false;
            GlobalStates.overviewOpen = !GlobalStates.overviewOpen;
        }
    }
    GlobalShortcut {
        name: "overviewDesktopToggle"
        description: "Toggles an overview of only this desktop's windows on press"

        onPressed: {
            // ALT+Tab: scope the overview to the desktop you are actually on, so
            // what you get is a switcher for its apps instead of a desktop grid.
            GlobalStates.overviewMode = "windows";
            GlobalStates.overviewSingleWorkspace = true;
            GlobalStates.overviewOpen = !GlobalStates.overviewOpen;
        }
    }
    GlobalShortcut {
        name: "searchToggleRelease"
        description: "Toggles search on release"

        onPressed: {
            GlobalStates.superReleaseMightTrigger = true;
        }

        onReleased: {
            if (!GlobalStates.superReleaseMightTrigger) {
                GlobalStates.superReleaseMightTrigger = true;
                return;
            }
            // A plain SUPER tap: the app search overlay -- the card under the
            // bar's centre island (the approved preview design) -- never the
            // desktop grid.
            GlobalStates.appSearchOverlayOpen = !GlobalStates.appSearchOverlayOpen;
        }
    }
    GlobalShortcut {
        name: "searchToggleReleaseInterrupt"
        description: "Interrupts possibility of search being toggled on release. " + "This is necessary because GlobalShortcut.onReleased in quickshell triggers whether or not you press something else while holding the key. " + "To make sure this works consistently, use binditn = MODKEYS, catchall in an automatically triggered submap that includes everything."

        onPressed: {
            GlobalStates.superReleaseMightTrigger = false;
        }
    }
    GlobalShortcut {
        name: "overviewClipboardToggle"
        description: "Toggle clipboard query on overview widget"

        onPressed: {
            overviewScope.toggleClipboard();
        }
    }

    GlobalShortcut {
        name: "overviewEmojiToggle"
        description: "Toggle emoji query on overview widget"

        onPressed: {
            overviewScope.toggleEmojis();
        }
    }
}
