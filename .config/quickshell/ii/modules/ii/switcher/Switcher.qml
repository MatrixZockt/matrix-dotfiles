pragma ComponentBehavior: Bound

import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets

/**
 * ALT+Tab switcher.
 *
 * Two modes, chosen by the keybind according to what is focused:
 *
 *   "apps"      -> the open windows of the desktop you are on, so Tab walks from
 *                  one app to the next
 *   "desktops"  -> every desktop that currently has something on it, plus a final
 *                  "+ New desktop" row
 *
 * ALT+Tab (and ALT+SHIFT+Tab) only move the highlight; nothing switches until you
 * let go of ALT. That is what makes it a switcher rather than a chain of jumps --
 * and taking it back is free, since releasing ALT is the only thing that commits.
 *
 * Note the binds are Hyprland-side, so this panel never needs keyboard focus; it
 * cannot steal typing from the window underneath. A timeout closes it if it is
 * somehow left open.
 */
Scope {
    id: root

    property bool open: false
    property string mode: "apps" // "apps" | "desktops"
    property int selection: 0

    readonly property int activeWorkspaceId: HyprlandData.activeWorkspace?.id ?? 1

    readonly property var appItems: {
        if (!root.open)
            return [];
        return HyprlandData.windowList
            .filter(w => w.workspace?.id === root.activeWorkspaceId)
            .map(w => ({
                kind: "window",
                address: w.address,
                title: w.title,
                appClass: w.class,
                floating: w.floating,
                fullscreen: w.fullscreen,
                workspaceId: w.workspace?.id
            }));
    }

    readonly property var desktopItems: {
        if (!root.open)
            return [];
        const ids = [];
        for (const w of HyprlandData.windowList) {
            const id = w.workspace?.id;
            if (id && id > 0 && !ids.includes(id))
                ids.push(id);
        }
        ids.sort((a, b) => a - b);
        const rows = ids.map(id => {
            const wins = HyprlandData.windowList.filter(w => w.workspace?.id === id);
            return {
                kind: "desktop",
                id: id,
                count: wins.length,
                preview: wins.slice(0, 3).map(w => w.title)
            };
        });
        rows.push({
            kind: "new",
            id: -1,
            count: 0,
            preview: []
        });
        return rows;
    }

    readonly property var items: root.mode === "apps" ? root.appItems : root.desktopItems

    // Safety net: if the switcher is ever left open (ALT released somewhere we did
    // not hear about), it closes itself rather than blocking the screen.
    Timer {
        id: idleClose
        interval: 6000
        repeat: false
        running: root.open
        onTriggered: root.close()
    }

    onOpenChanged: idleClose.restart()

    function close() {
        root.open = false;
        root.selection = 0;
    }

    function clampSelection() {
        const count = root.items.length;
        if (count === 0) {
            root.selection = 0;
            return;
        }
        if (root.selection < 0)
            root.selection = count - 1;
        if (root.selection >= count)
            root.selection = 0;
    }

    // First press opens the panel; every press after that walks the highlight.
    function begin(which) {
        if (!root.open || root.mode !== which) {
            root.mode = which;
            root.selection = 0;
            root.open = true;
        } else {
            root.selection += 1;
        }
        root.clampSelection();
        idleClose.restart();
    }

    function advance(step) {
        if (!root.open)
            return;
        root.selection += step;
        root.clampSelection();
        idleClose.restart();
    }

    function activate() {
        if (!root.open)
            return;
        const item = root.items[root.selection];
        root.close();
        if (!item)
            return;

        if (item.kind === "window") {
            // Fullscreen-first, always: picking an app from the switcher gives
            // you that app fullscreen. This works from anywhere -- the switcher
            // is no longer a fullscreen-only panel, so ALT+Tab on a tiled
            // desktop now focuses the app AND takes it fullscreen. A window
            // that is already fullscreen is left alone, never toggled off.
            const targetFullscreen = (item.fullscreen ?? 0) >= 2;
            Hyprland.dispatch(`hl.dsp.focus({ window = "address:${item.address}" })`);
            if (!targetFullscreen)
                Hyprland.dispatch(`hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" })`);
        } else if (item.kind === "desktop") {
            Hyprland.dispatch(`hl.dsp.focus({ workspace = ${item.id} })`);
        } else if (item.kind === "new") {
            root.openNewDesktop();
        }
    }

    // A "+ New desktop" row. Picks the lowest id nothing is using and goes there,
    // which is also what makes the bar grow a new desktop slot.
    function openNewDesktop() {
        const used = {};
        for (const w of HyprlandData.windowList) {
            const id = w.workspace?.id;
            if (id && id > 0)
                used[id] = true;
        }
        let target = null;
        for (let id = 1; id <= 50; id++) {
            if (!used[id]) {
                target = id;
                break;
            }
        }
        if (target === null)
            return;
        Hyprland.dispatch(`hl.dsp.focus({ workspace = ${target} })`);
    }

    // The live surface behind a window, for a REAL preview.
    //
    // The old list drew a schematic because occluded windows could not be
    // captured -- a comment that was true but treated as final. It is not:
    // this shell ALREADY captures real windows elsewhere (the waffle task
    // view), via `ScreencopyView` with `captureSource` set to the toplevel
    // object from the Wayland ToplevelManager. That gives the switcher actual
    // pixels -- the real terminal text, the real page -- instead of a grey
    // box with a logo in it.
    //
    // `items` carries the Hyprland-side window data (address, title), which
    // screencopy cannot use: it needs the Toplevel object itself, so the two
    // are joined here by address.
    function toplevelFor(address) {
        for (const t of ToplevelManager.toplevels.values) {
            if (t.HyprlandToplevel && `0x${t.HyprlandToplevel.address}` === address)
                return t;
        }
        return null;
    }

    // Grid geometry. Fixed tile size, so the grid is predictable and Tab
    // walks it left-to-right, top-to-bottom, matching the order of `items`.
    readonly property int gridColumns: 3
    readonly property int tileWidth: 244
    readonly property int tileHeight: 168

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: switcherWindow
            required property var modelData

            screen: switcherWindow.modelData
            // Only on the monitor that is actually focused, so a multi-monitor
            // setup does not show the same switcher twice.
            visible: root.open && (Hyprland.monitorFor(switcherWindow.modelData)?.id === Hyprland.focusedMonitor?.id)

            WlrLayershell.namespace: "quickshell:switcher"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            exclusionMode: ExclusionMode.Ignore

            color: "transparent"
            exclusiveZone: 0

            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }

            // Click anywhere outside the card to cancel.
            MouseArea {
                anchors.fill: parent
                onClicked: root.close()
            }

            Rectangle {
                id: card
                anchors.centerIn: parent
                implicitWidth: root.mode === "apps" ? 800 : 520
                implicitHeight: Math.min(620, column.implicitHeight + 24)
                radius: Appearance.rounding.large
                color: Appearance.colors.colLayer0
                border.width: 1
                border.color: Appearance.colors.colLayer0Border
                clip: true

                ColumnLayout {
                    id: column
                    anchors.centerIn: parent
                    width: parent.width - 24
                    spacing: 4

                    StyledText {
                        Layout.fillWidth: true
                        Layout.topMargin: 4
                        Layout.bottomMargin: 4
                        text: root.mode === "apps"
                            ? Translation.tr("Switch app")
                            : Translation.tr("Switch desktop")
                        font {
                            pixelSize: Appearance.font.pixelSize.normal
                            weight: Font.DemiBold
                        }
                        color: Appearance.colors.colSubtext
                    }

                    // APPS: a grid of real window previews. This is the
                    // whole point of the redesign -- the actual window, at a
                    // size you can read, rather than a logo beside a smudge.
                    GridView {
                        id: grid
                        visible: root.mode === "apps"
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.min(contentHeight, 520)
                        implicitHeight: Math.max(40, Layout.preferredHeight)
                        clip: true
                        model: root.items
                        currentIndex: root.selection
                        cellWidth: root.tileWidth + 12
                        cellHeight: root.tileHeight + 12
                        delegate: SwitcherTile {
                            required property var modelData
                            required property int index
                            width: root.tileWidth
                            height: root.tileHeight
                            itemData: modelData
                            selected: index === root.selection
                            onActivated: {
                                root.selection = index;
                                root.activate();
                            }
                            onHovered: root.selection = index
                        }
                    }

                    // DESKTS: still a list -- a desktop is a concept, not a
                    // window, so there is nothing to capture.
                    StyledListView {
                        id: listView
                        visible: root.mode !== "apps"
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.min(contentHeight, 460)
                        implicitHeight: Math.max(40, Layout.preferredHeight)
                        spacing: 2
                        clip: true
                        model: root.items
                        currentIndex: root.selection
                        delegate: SwitcherRow {
                            required property var modelData
                            required property int index
                            width: listView.width
                            itemData: modelData
                            selected: index === root.selection
                            onActivated: {
                                root.selection = index;
                                root.activate();
                            }
                            onHovered: root.selection = index
                        }
                    }
                }
            }
        }
    }

    GlobalShortcut {
        name: "switcherApps"
        description: "ALT+Tab: open or advance the app switcher"

        onPressed: root.begin("apps")
    }
    GlobalShortcut {
        name: "switcherDesktops"
        description: "ALT+Tab: open or advance the desktop switcher"

        onPressed: root.begin("desktops")
    }
    GlobalShortcut {
        name: "switcherNext"
        description: "Advance the ALT+Tab selection"

        onPressed: root.advance(1)
    }
    GlobalShortcut {
        name: "switcherPrev"
        description: "Move the ALT+Tab selection back"

        onPressed: root.advance(-1)
    }
    GlobalShortcut {
        name: "switcherActivate"
        description: "Commit the ALT+Tab selection (fires on ALT release)"

        onPressed: root.activate()
    }
    GlobalShortcut {
        name: "switcherCancel"
        description: "Dismiss the ALT+Tab switcher"

        onPressed: root.close()
    }

    // The same actions over the shell's IPC socket.
    //
    // Key *release* is what needs these: Hyprland runs a release-bind callback (a
    // `hl.exec_cmd` in there really does run), but a `global` shortcut dispatched
    // from inside one never arrives, so the old release binds left the panel
    // sitting on screen until its 6 second safety timeout. Talking to the shell's
    // socket from the release bind has no such problem, which is what makes
    // letting go of ALT close the switcher immediately.
    IpcHandler {
        target: "switcher"

        function apps(): void {
            root.begin("apps");
        }
        function desktops(): void {
            root.begin("desktops");
        }
        function next(): void {
            root.advance(1);
        }
        function prev(): void {
            root.advance(-1);
        }
        function activate(): void {
            root.activate();
        }
        function cancel(): void {
            root.close();
        }
    }

    // One row: icon, a title, and a bit of context.
    component SwitcherRow: Rectangle {
        id: row
        required property var itemData
        property bool selected: false
        signal activated()
        signal hovered()

        implicitHeight: 52
        radius: Appearance.rounding.small
        color: row.selected
            ? Appearance.colors.colSecondaryContainer
            : (hoverArea.containsMouse ? Appearance.colors.colLayer1Hover : "transparent")

        Behavior on color {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
        }

        readonly property var entry: row.itemData.kind === "window"
            ? DesktopEntries.heuristicLookup(row.itemData.appClass)
            : null

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 12
            spacing: 12

            // ── Layout preview ───────────────────────────────────────────
            // Real per-window thumbnails do not exist on this stack (occluded
            // windows cannot be captured on Wayland), so this is the desktop's
            // REAL tiling geometry, drawn big enough to read: every window at
            // its true position and relative size -- each with its app icon and
            // a title bar -- and the row's own window accented.
            //
            // The geometry is scaled to the BOUNDING BOX of that desktop's
            // windows, not to the whole monitor: mapping one app-sized window
            // onto a 1920x1080 pane is what made previews read as "a small
            // random image" in a corner. Fitting the box means a single window
            // and a six-window tiling both fill the pane and are comparable
            // between rows.
            Item {
                id: previewPane
                visible: row.itemData.kind !== "new"
                Layout.preferredWidth: 132
                Layout.preferredHeight: 76
                Layout.alignment: Qt.AlignVCenter

                readonly property int wsId: row.itemData.kind === "desktop"
                    ? row.itemData.id : (row.itemData.workspaceId ?? -1)
                readonly property var wins: wsId > 0
                    ? HyprlandData.windowList.filter(w => w.workspace?.id === wsId).slice(0, 8)
                    : []

                // Geometry accessors. The compositor (and so HyprlandData) hands
                // these out as PAIRS -- at: [x, y], size: [w, h] -- the same
                // shape WorkspaceModel and the overview read. Reading them as
                // .x/.width silently yielded undefined, so EVERY preview fell
                // back to a 100x100 box: whatever the window was, the schematic
                // drew the same little square. Both shapes are accepted here so
                // a future change of source cannot reintroduce that.
                function winX(w) { return Array.isArray(w?.at) ? (w.at[0] ?? 0) : (w?.at?.x ?? 0); }
                function winY(w) { return Array.isArray(w?.at) ? (w.at[1] ?? 0) : (w?.at?.y ?? 0); }
                function winW(w) { return Array.isArray(w?.size) ? (w.size[0] ?? 100) : (w?.size?.width ?? 100); }
                function winH(w) { return Array.isArray(w?.size) ? (w.size[1] ?? 100) : (w?.size?.height ?? 100); }

                // The union of the windows' rectangles: what to fit.
                readonly property var bounds: {
                    if (wins.length === 0)
                        return { x: 0, y: 0, w: 1, h: 1 };
                    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
                    for (const w of wins) {
                        const wx = winX(w), wy = winY(w);
                        const ww = winW(w), wh = winH(w);
                        x0 = Math.min(x0, wx);
                        y0 = Math.min(y0, wy);
                        x1 = Math.max(x1, wx + ww);
                        y1 = Math.max(y1, wy + wh);
                    }
                    if (!isFinite(x0) || x1 - x0 <= 0 || y1 - y0 <= 0)
                        return { x: 0, y: 0, w: 1, h: 1 };
                    return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
                }
                readonly property real pad: 6
                readonly property real fit: Math.min(
                    (width - pad * 2) / Math.max(1, bounds.w),
                    (height - pad * 2) / Math.max(1, bounds.h))
                function px(wx) { return pad + (wx - bounds.x) * fit; }
                function py(wy) { return pad + (wy - bounds.y) * fit; }
                function pw(w) { return Math.max(8, w * fit); }
                function ph(h) { return Math.max(6, h * fit); }

                Rectangle {
                    anchors.fill: parent
                    radius: Appearance.rounding.small
                    color: Appearance.colors.colLayer0
                    opacity: 0.5
                    border.width: 1
                    border.color: Appearance.colors.colLayer0Border
                }

                Repeater {
                    model: previewPane.wins
                    delegate: Rectangle {
                        id: miniWin
                        required property var modelData
                        required property int index
                        // The row's OWN window: the one this app row is about.
                        readonly property bool own: row.itemData.kind === "window"
                            && modelData.address === row.itemData.address
                        readonly property var entry: DesktopEntries.heuristicLookup(modelData.class ?? "")
                        readonly property var ownEntry: row.itemData.kind === "window"
                            ? DesktopEntries.heuristicLookup(row.itemData.appClass ?? "") : null
                        readonly property string label: own
                            ? (row.itemData.title || row.itemData.appClass || "")
                            : (modelData.title || modelData.class || "")

                        // The preview pane is tiny (132x76). The window it
                        // stands for is drawn at its TRUE proportional size --
                        // a maximized window therefore fills the pane, which
                        // is correct and reads correctly ONLY if the body is
                        // window-coloured. It used to be flooded with the
                        // accent colour, so a fullscreen app previewed as a
                        // solid orange block with a speck of an icon.
                        x: previewPane.px(previewPane.winX(modelData))
                        y: previewPane.py(previewPane.winY(modelData))
                        width: previewPane.pw(previewPane.winW(modelData))
                        height: previewPane.ph(previewPane.winH(modelData))
                        radius: 3
                        // The pane's context windows are quiet; the row's own
                        // window is the lit one.
                        color: own
                            ? Appearance.colors.colLayer1
                            : (Appearance.m3colors.darkmode ? Qt.rgba(1, 1, 1, 0.06) : Qt.rgba(0, 0, 0, 0.05))
                        opacity: own ? 1.0 : 0.75
                        border.width: own ? 1.4 : 0.8
                        border.color: own ? Appearance.colors.colPrimary : Appearance.colors.colLayer0Border
                        clip: true

                        // The title bar: a real strip with the app's icon in
                        // it -- the single strongest "this is a window" cue,
                        // and the only place the app is identifiable when the
                        // window fills the whole pane.
                        Rectangle {
                            id: miniTitle
                            anchors {
                                left: parent.left
                                right: parent.right
                                top: parent.top
                            }
                            height: Math.max(9, Math.min(14, parent.height * 0.28))
                            color: own
                                ? ColorUtils.transparentize(Appearance.colors.colPrimary, 0.65)
                                : Qt.rgba(1, 1, 1, 0.10)

                            Row {
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left
                                anchors.leftMargin: 3
                                spacing: 3

                                IconImage {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.min(9, miniTitle.height - 3)
                                    height: width
                                    source: {
                                        const e = own ? ownEntry : entry;
                                        if (e && e.icon)
                                            return Quickshell.iconPath(e.icon);
                                        return Quickshell.iconPath("application-x-executable",
                                            Quickshell.shellPath("assets/icons/fluent/apps.svg"));
                                    }
                                    asynchronous: true
                                }
                                StyledText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: miniTitle.width > 44
                                    text: miniWin.label
                                    font.pixelSize: 7
                                    color: own ? Appearance.colors.colOnLayer0 : Appearance.colors.colSubtext
                                    elide: Text.ElideRight
                                    width: Math.min(implicitWidth, miniTitle.width - 24)
                                }
                            }
                        }

                        // A whisper of content lines under the title bar, so a
                        // maximized window does not read as an empty tile.
                        Column {
                            anchors {
                                top: miniTitle.bottom
                                left: parent.left
                                right: parent.right
                                margins: 4
                            }
                            spacing: 3
                            Repeater {
                                model: 3
                                Rectangle {
                                    // The delegate evaluates its bindings the
                                    // instant the Repeater creates it, before the
                                    // contentItem reparents it -- parent is null
                                    // for that first tick, and a bare parent.width
                                    // threw a TypeError per window per open.
                                    width: (parent ? parent.width : 0)
                                        * (index === 2 ? 0.55 : 1.0)
                                    height: 2
                                    radius: 1
                                    color: Qt.rgba(1, 1, 1, own ? 0.10 : 0.06)
                                }
                            }
                        }
                    }
                }

                // An empty desktop still says something useful.
                MaterialSymbol {
                    anchors.centerIn: parent
                    visible: previewPane.wins.length === 0
                    text: "crop_square"
                    iconSize: 20
                    color: Appearance.colors.colOutline
                }
            }

            Item {
                Layout.preferredWidth: 32
                Layout.preferredHeight: 32
                Layout.alignment: Qt.AlignVCenter

                IconImage {
                    id: rowIcon
                    anchors.fill: parent
                    source: {
                        if (row.itemData.kind === "new")
                            return Quickshell.iconPath("list-add", "add");
                        if (row.itemData.kind === "desktop")
                            return Quickshell.iconPath("desktop", Quickshell.shellPath("assets/icons/fluent/apps.svg"));
                        const entry = row.entry;
                        if (entry && entry.icon)
                            return Quickshell.iconPath(entry.icon);
                        return Quickshell.iconPath("application-x-executable", Quickshell.shellPath("assets/icons/fluent/apps.svg"));
                    }
                    asynchronous: true
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 0

                StyledText {
                    Layout.fillWidth: true
                    text: {
                        if (row.itemData.kind === "new")
                            return Translation.tr("+ New desktop");
                        if (row.itemData.kind === "desktop")
                            return Translation.tr("Desktop %1").arg(row.itemData.id);
                        return row.itemData.title || row.itemData.appClass || "";
                    }
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colOnSurface
                    elide: Text.ElideRight
                }

                StyledText {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: {
                        if (row.itemData.kind === "new")
                            return Translation.tr("Creates an empty desktop and switches to it");
                        if (row.itemData.kind === "desktop")
                            return row.itemData.count > 0
                                ? Translation.tr("%1 window(s): %2").arg(row.itemData.count).arg(row.itemData.preview.join(", "))
                                : "";
                        return row.itemData.appClass || "";
                    }
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                    elide: Text.ElideRight
                }
            }
        }

        MouseArea {
            id: hoverArea
            anchors.fill: parent
            hoverEnabled: true
            onClicked: row.activated()
            onEntered: row.hovered()
        }
    }

    // One tile of the apps grid: the REAL window, captured.
    component SwitcherTile: Rectangle {
        id: tile
        required property var itemData
        property bool selected: false
        readonly property var toplevel: root.toplevelFor(tile.itemData.address)
        signal activated()
        signal hovered()

        radius: Appearance.rounding.small
        color: Appearance.colors.colLayer1
        border.width: tile.selected ? 2 : 1
        border.color: tile.selected
            ? Appearance.colors.colPrimary
            : Appearance.colors.colLayer0Border
        clip: true
        scale: tile.selected ? 1.0 : 0.965

        Behavior on border.color {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
        }
        Behavior on scale {
            NumberAnimation {
                duration: 120
                easing.type: Easing.OutCubic
            }
        }

        // The real thing. `live` because a screencopy that only fires once
        // can land before the surface has content; the tile is short-lived,
        // so a continuously updating copy costs nothing noticeable.
        ScreencopyView {
            id: capture
            anchors.fill: parent
            anchors.bottomMargin: 26
            visible: tile.toplevel !== null
            captureSource: tile.toplevel
            live: true
            paintCursor: false
        }

        // Fallback for a window the compositor cannot hand over a surface
        // for. Never leave a tile blank and unexplained.
        Rectangle {
            anchors.fill: parent
            anchors.bottomMargin: 26
            visible: tile.toplevel === null
            color: Appearance.colors.colLayer2

            Column {
                anchors.centerIn: parent
                spacing: 6
                width: parent.width - 20

                IconImage {
                    width: 40
                    height: 40
                    anchors.horizontalCenter: parent.horizontalCenter
                    asynchronous: true
                    source: {
                        const e = DesktopEntries.heuristicLookup(tile.itemData.appClass ?? "");
                        if (e && e.icon)
                            return Quickshell.iconPath(e.icon);
                        return Quickshell.iconPath("application-x-executable",
                            Quickshell.shellPath("assets/icons/fluent/apps.svg"));
                    }
                }
                StyledText {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: Translation.tr("preview unavailable")
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                    elide: Text.ElideRight
                }
            }
        }

        // Caption: icon + title, always, so a tile is identifiable even
        // before the capture paints its first frame.
        Rectangle {
            anchors {
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            height: 26
            color: tile.selected
                ? ColorUtils.transparentize(Appearance.colors.colPrimary, 0.75)
                : Appearance.colors.colLayer0

            Row {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: 7
                anchors.right: parent.right
                anchors.rightMargin: 7
                spacing: 6

                IconImage {
                    id: tileIcon
                    width: 15
                    height: 15
                    anchors.verticalCenter: parent.verticalCenter
                    asynchronous: true
                    source: {
                        const e = DesktopEntries.heuristicLookup(tile.itemData.appClass ?? "");
                        if (e && e.icon)
                            return Quickshell.iconPath(e.icon);
                        return Quickshell.iconPath("application-x-executable",
                            Quickshell.shellPath("assets/icons/fluent/apps.svg"));
                    }
                }
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(0, parent.width - tileIcon.width - 14)
                    text: tile.itemData.title || tile.itemData.appClass || ""
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colOnSurface
                    elide: Text.ElideRight
                }
            }
        }

        MouseArea {
            id: tileHover
            anchors.fill: parent
            hoverEnabled: true
            onClicked: tile.activated()
            onEntered: tile.hovered()
        }
    }
}
