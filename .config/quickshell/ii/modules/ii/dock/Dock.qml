import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.flare
import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell.Io
import Quickshell
import Quickshell.Widgets
import Quickshell.Wayland
import Quickshell.Hyprland

/**
 * The bottom dock — the "right now" bar.
 *
 * HOVER-ONLY: the surface exists only while the pointer is at the bottom
 * edge or on the dock itself (or it is pinned). It reserves no permanent
 * strip of the screen — no exclusive zone, maximized windows can use every
 * pixel until you actually summon it.
 *
 * COLLAPSED: one slim attached pill carrying the thing you are most likely
 * to want right now — 1. music playing (MprisController), else 2. the
 * pomodoro if it is running, else 3. the AI provider rings.
 *
 * EXTENDED (hover held or two-finger horizontal swipe for tabs): the sheet
 * blooms to at most a THIRD of the screen height and adapts its width to
 * the screen. It carries the AI usage as ONE month github-style graph plus
 * the provider ring deck. Tabs (AI / pomodoro) switch with a two-finger
 * horizontal swipe — via MouseArea.onWheel, the only wheel path this Qt
 * build delivers on layer surfaces (WheelHandler is silently starved).
 *
 * The surface stays bottom-attached with the bar's droplet mouth fillets.
 */
Scope {
    id: root

    property bool pinned: Config.options?.dock.pinnedOnStartup ?? false

    readonly property real pillHeight: Config.options?.dock.height ?? 48
    readonly property real rowPadding: 18
    readonly property real bottomInset: Config.options.bar.cornerStyle === 1 ? Appearance.sizes.hyprlandGapsOut : 0
    // Hover grace around the pill: small enough not to ghost-capture the
    // desktop, big enough to keep the pointer captured between edge and pill.
    readonly property real hoverOverhang: 40
    readonly property real ringSize: Math.max(16, root.pillHeight - root.rowPadding * 2 + 12)
    readonly property real ringTrack: Math.max(2, root.ringSize * 0.09)
    // The panel never exceeds a third of the screen.
    readonly property real maxPanelThird: 0.34
    // The live tab: 0 = AI usage, 1 = pomodoro.
    property int tabIndex: 0
    readonly property int tabCount: 2
    function cycleTab(delta) {
        root.tabIndex = (root.tabIndex + delta + root.tabCount) % root.tabCount;
    }

    // ── "Right now" priority: music > running pomodoro > AI ─────────────
    readonly property bool musicLive: MprisController.isPlaying && (MprisController.activeTrack?.title ?? "") !== ""
    readonly property bool pomoLive: TimerService.pomodoroRunning
    readonly property int nowMode: musicLive ? 0 : pomoLive ? 1 : 2

    // The extend state.
    property bool usageHovered: false
    readonly property bool extended: root.usageHovered && FlareData.cells.length > 0

    property string diag: ""

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: dockRoot
            required property var modelData
            screen: modelData

            readonly property var monitor: Hyprland.monitorFor(dockRoot.modelData)
            readonly property bool fullscreenOnActive: Hyprland.workspaces.values.some(ws =>
                ws.monitor === dockRoot.monitor && ws.active
                && ws.toplevels.values.some(t => t.wayland?.fullscreen))

            // ── Hover-only reveal ──────────────────────────────────────
            // Shown while the pointer summoned it (bottom-edge hover/click
            // via EdgeReveal), while it is hovered, or when pinned. No
            // permanent anchor: no exclusive zone at all.
            //
            // The layer NEVER unmaps over fullscreen windows (only under the
            // lock screen): toggling `visible` on a layer surface remaps it,
            // and every remap flashes the whole desktop — that was the
            // "shell restarts for a split second" on every switch away from
            // a fullscreen app. The layer stays mapped; the CONTENT fades
            // and the input mask empties instead.
            readonly property bool summoned: root.pinned || GlobalStates.dockRevealed
                || GlobalStates.dockPointerInside || root.usageHovered
            readonly property bool shown: dockRoot.summoned && !dockRoot.fullscreenOnActive
            visible: !GlobalStates.screenLocked
            onShownChanged: {
                if (!shown) {
                    GlobalStates.dockPointerInside = false;
                    root.usageHovered = false;
                }
                FlareData.noteVisible(shown);
            }

            readonly property real sheetContentHeight: sheetLoader.item ? sheetLoader.item.implicitHeight + 8 : 200
            readonly property real screenH: dockRoot.modelData?.height ?? 1000
            readonly property real screenW: dockRoot.modelData?.width ?? 1400
            readonly property real maxPanelHeight: Math.max(160, screenH * root.maxPanelThird - root.pillHeight)
            readonly property real panelHeight: Math.min(Math.max(160, sheetContentHeight), maxPanelHeight)
            // Adaptive width: the sheet never swallows small screens.
            readonly property real panelWidth: Math.min(720, screenW * 0.44)
            implicitHeight: root.pillHeight + dockRoot.panelHeight + root.bottomInset

            readonly property string diagText: `revealed=${GlobalStates.dockRevealed} hover=${root.usageHovered}`
                + ` extended=${root.extended} mode=${root.nowMode}`
                + ` rings=${FlareData.cells.length} tab=${root.tabIndex}`
                + ` surface=${body.width.toFixed(0)}x${body.height.toFixed(0)}`
                + ` panel=${dockRoot.panelHeight.toFixed(0)}/${dockRoot.maxPanelHeight.toFixed(0)}`
            onDiagTextChanged: root.diag = diagText
            Component.onCompleted: root.diag = diagText

            anchors {
                bottom: true
                left: true
                right: true
            }

            // Hover-only: no space is reserved from windows.
            exclusiveZone: -1

            WlrLayershell.namespace: "quickshell:dock"
            color: "transparent"

            mask: Region {
                // Empty while the dock is not shown, so the mapped-but-faded
                // layer never steals pointer input from the window under it.
                item: dockRoot.shown ? dockMouseArea : null
            }

            MouseArea {
                id: dockMouseArea
                anchors.bottom: parent.bottom
                anchors.horizontalCenter: parent.horizontalCenter
                width: body.width + root.hoverOverhang * 2
                height: body.height
                hoverEnabled: true
                acceptedButtons: Qt.NoButton

                onContainsMouseChanged: {
                    GlobalStates.dockPointerInside = containsMouse;
                    if (!containsMouse)
                        root.usageHovered = false;
                }
                Component.onCompleted: GlobalStates.dockPointerInside = containsMouse

                Item {
                    id: body
                    anchors.bottom: parent.bottom
                    anchors.horizontalCenter: parent.horizontalCenter

                    // The fade that replaces the remap: leaving a fullscreen
                    // app eases the dock in instead of flashing it into
                    // existence. Instant hide under fullscreen (the app is
                    // the focus), smooth show.
                    opacity: dockRoot.shown ? 1 : 0
                    Behavior on opacity {
                        NumberAnimation {
                            duration: dockRoot.shown ? 0 : 200
                            easing.type: Easing.OutCubic
                        }
                    }

                    width: root.extended ? Math.max(pill.implicitWidth, dockRoot.panelWidth) : pill.implicitWidth
                    height: root.extended ? root.pillHeight + dockRoot.panelHeight : root.pillHeight
                    Behavior on width {
                        NumberAnimation {
                            duration: Appearance.animation.elementMove.duration
                            easing.type: Appearance.animation.elementMove.type
                            easing.bezierCurve: Appearance.animation.elementMove.bezierCurve
                        }
                    }
                    Behavior on height {
                        NumberAnimation {
                            duration: Appearance.animation.elementMove.duration
                            easing.type: Appearance.animation.elementMove.type
                            easing.bezierCurve: Appearance.animation.elementMove.bezierCurve
                        }
                    }

                    // ── The attached skin with mouth fillets ────────────
                    readonly property real filW: Math.min(9, body.height * 0.28)
                    readonly property real filH: Math.min(11, body.height * 0.38)
                    readonly property real rad: Math.min(Appearance.rounding.screenRounding - Appearance.sizes.hyprlandGapsOut + 1, body.height * 0.34)
                    readonly property real w: body.width
                    readonly property real h: body.height

                    Shape {
                        anchors.fill: parent
                        preferredRendererType: Shape.CurveRenderer

                        ShapePath {
                            strokeColor: "transparent"
                            strokeWidth: -1
                            fillColor: Appearance.colors.colLayer0

                            startX: body.filW + body.rad
                            startY: 0
                            PathLine { x: body.w - body.filW - body.rad; y: 0 }
                            PathQuad {
                                controlX: body.w - body.filW; controlY: 0
                                x: body.w - body.filW; y: body.rad
                            }
                            PathLine { x: body.w - body.rad; y: body.h - body.filH }
                            PathCubic {
                                control1X: body.w - body.rad; control1Y: body.h - body.filH * 0.55
                                control2X: body.w - body.filW * 0.08; control2Y: body.h
                                x: body.w; y: body.h
                            }
                            PathLine { x: 0; y: body.h }
                            PathCubic {
                                control1X: body.filW * 0.08; control1Y: body.h
                                control2X: body.filW; control2Y: body.h - body.filH * 0.55
                                x: body.filW; y: body.h - body.filH
                            }
                            PathLine { x: body.filW; y: body.rad }
                            PathQuad {
                                controlX: body.filW; controlY: 0
                                x: body.filW + body.rad; y: 0
                            }
                        }

                        ShapePath {
                            fillColor: "transparent"
                            strokeColor: Appearance.colors.colLayer0Border
                            strokeWidth: 1

                            startX: 0
                            startY: body.h
                            PathCubic {
                                control1X: body.filW * 0.08; control1Y: body.h
                                control2X: body.filW; control2Y: body.h - body.filH * 0.55
                                x: body.filW; y: body.h - body.filH
                            }
                            PathLine { x: body.filW; y: body.rad }
                            PathQuad {
                                controlX: body.filW; controlY: 0
                                x: body.filW + body.rad; y: 0
                            }
                            PathLine { x: body.w - body.filW - body.rad; y: 0 }
                            PathQuad {
                                controlX: body.w - body.filW; controlY: 0
                                x: body.w - body.filW; y: body.rad
                            }
                            PathLine { x: body.w - body.filW; y: body.h - body.filH }
                            PathCubic {
                                control1X: body.w - body.filW; control1Y: body.h - body.filH * 0.55
                                control2X: body.w - body.filW * 0.08; control2Y: body.h
                                x: body.w; y: body.h
                            }
                        }
                    }

                    // ── Two-finger horizontal swipe: switch tabs ─────────
                    // MouseArea.onWheel, NOT WheelHandler: this Qt build
                    // never delivers wheel events to WheelHandler on layer
                    // surfaces (proven with an on-screen probe on the
                    // wallpaper carousel, which uses exactly this pattern).
                    // acceptedButtons: NoButton keeps it transparent to the
                    // pill's buttons, rings and taps.
                    property real accX: 0
                    property real accY: 0
                    property bool horizontal: false
                    property bool firedThisGesture: false
                    Timer {
                        id: swipeEndTimer
                        interval: 180
                        onTriggered: {
                            body.accX = 0;
                            body.accY = 0;
                            body.horizontal = false;
                            body.firedThisGesture = false;
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        onWheel: event => {
                            const pd = event.pixelDelta;
                            const hasPixels = pd && (pd.x !== 0 || pd.y !== 0);
                            const deviceType = event.device?.type;
                            const isTouchpad = (deviceType !== undefined)
                                ? deviceType === PointerDevice.TouchPad
                                : hasPixels;
                            swipeEndTimer.restart();
                            if (isTouchpad) {
                                const dx = hasPixels ? (event.inverted ? pd.x : -pd.x) : event.angleDelta.x / 120 * 40;
                                const dy = hasPixels ? (event.inverted ? pd.y : -pd.y) : event.angleDelta.y / 120 * 40;
                                body.accX += Math.abs(dx);
                                body.accY += Math.abs(dy);
                                if (!body.horizontal && body.accX > body.accY * 1.25 && body.accX >= 12)
                                    body.horizontal = true;
                                if (body.horizontal && !body.firedThisGesture && body.accX >= 40) {
                                    root.cycleTab(dx > 0 ? 1 : -1);
                                    body.firedThisGesture = true;
                                }
                                event.accepted = true;
                            } else {
                                const dx = event.angleDelta.x !== 0 ? event.angleDelta.x : event.angleDelta.y;
                                if (dx === 0) return;
                                root.cycleTab(dx > 0 ? 1 : -1);
                                event.accepted = true;
                            }
                        }
                    }

                    // ── The AI month sheet (tab 0) ─────────────────────
                    Loader {
                        id: sheetLoader
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: pill.top
                        anchors.bottomMargin: 10
                        anchors.topMargin: 2
                        anchors.leftMargin: 2
                        anchors.rightMargin: 2
                        active: FlareData.cells.length > 0
                        sourceComponent: UsageMonthSheet {}
                        opacity: root.extended && root.tabIndex === 0 ? 1 : 0
                        visible: opacity > 0.01
                        Behavior on opacity {
                            NumberAnimation {
                                duration: root.extended ? Appearance.animation.elementMove.duration : 80
                                easing.type: Easing.OutCubic
                            }
                        }
                    }

                    // ── The pill strip ─────────────────────────────────
                    Item {
                        id: pill
                        anchors.bottom: parent.bottom
                        anchors.horizontalCenter: parent.horizontalCenter
                        height: root.pillHeight
                        implicitWidth: nowStrip.width + root.rowPadding * 2
                        width: implicitWidth
                        clip: true

                        Behavior on width {
                            NumberAnimation {
                                duration: Appearance.animation.elementMove.duration
                                easing.type: Appearance.animation.elementMove.type
                                easing.bezierCurve: Appearance.animation.elementMove.bezierCurve
                            }
                        }

                        HoverHandler {
                            onHoveredChanged: if (hovered)
                                root.usageHovered = true
                        }

                        // ── The "right now" content ────────────────────
                        RowLayout {
                            id: nowStrip
                            anchors.centerIn: parent
                            spacing: root.rowPadding

                            // ── Mode 0: music ──────────────────────────
                            Item {
                                visible: root.nowMode === 0
                                Layout.preferredHeight: root.ringSize
                                implicitWidth: artCover.width + titleCol.width + 6

                                Rectangle {
                                    id: artCover
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: root.ringSize
                                    height: root.ringSize
                                    radius: Appearance.rounding.small
                                    color: Appearance.colors.colLayer1
                                    clip: true
                                    // Album art when available; a note glyph otherwise.
                                    IconImage {
                                        anchors.fill: parent
                                        visible: (MprisController.activeTrack?.trackArtUrl ?? "") !== ""
                                        source: MprisController.activeTrack?.trackArtUrl ?? ""
                                        asynchronous: true
                                    }
                                    MaterialSymbol {
                                        anchors.centerIn: parent
                                        visible: (MprisController.activeTrack?.trackArtUrl ?? "") === ""
                                        text: "music_note"
                                        iconSize: parent.width * 0.5
                                        color: Appearance.colors.colOutline
                                    }
                                }
                                ColumnLayout {
                                    id: titleCol
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: artCover.right
                                    anchors.leftMargin: 10
                                    spacing: 1
                                    StyledText {
                                        text: MprisController.activeTrack?.trackTitle ?? ""
                                        font.pixelSize: Appearance.font.pixelSize.small
                                        font.weight: Font.Medium
                                        color: Appearance.colors.colOnLayer0
                                        elide: Text.ElideRight
                                        Layout.maximumWidth: 220
                                    }
                                    StyledText {
                                        text: MprisController.activeTrack?.trackArtists ?? ""
                                        font.pixelSize: Appearance.font.pixelSize.smallie
                                        color: Appearance.colors.colOutline
                                        elide: Text.ElideRight
                                        Layout.maximumWidth: 220
                                    }
                                }
                                // Controls: previous / play / next, compact.
                                RowLayout {
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: titleCol.right
                                    anchors.leftMargin: 10
                                    spacing: 0
                                    RippleButton {
                                        Layout.preferredWidth: 26
                                        Layout.fillHeight: true
                                        colBackground: hovered ? Appearance.colors.colLayer0Hover : "transparent"
                                        colBackgroundHover: Appearance.colors.colLayer0Hover
                                        onClicked: MprisController.previous()
                                        enabled: MprisController.canGoPrevious
                                        MaterialSymbol { anchors.centerIn: parent; text: "skip_previous"; iconSize: 15; color: Appearance.colors.colOnLayer0 }
                                    }
                                    RippleButton {
                                        Layout.preferredWidth: 26
                                        Layout.fillHeight: true
                                        // The play/pause is the filled disc; the
                                        // skip buttons stay quiet. A primary
                                        // GLYPH on a transparent pad reads as
                                        // a tint, not a control.
                                        buttonRadius: Appearance.rounding.full
                                        colBackground: hovered ? Appearance.colors.colLayer0Hover : "transparent"
                                        colBackgroundHover: Appearance.colors.colLayer0Hover
                                        onClicked: MprisController.togglePlaying()
                                        MaterialSymbol { anchors.centerIn: parent; text: MprisController.isPlaying ? "pause" : "play_arrow"; iconSize: 16; fill: 1; color: hovered ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer0 }
                                    }
                                    RippleButton {
                                        Layout.preferredWidth: 26
                                        Layout.fillHeight: true
                                        colBackground: hovered ? Appearance.colors.colLayer0Hover : "transparent"
                                        colBackgroundHover: Appearance.colors.colLayer0Hover
                                        onClicked: MprisController.next()
                                        enabled: MprisController.canGoNext
                                        MaterialSymbol { anchors.centerIn: parent; text: "skip_next"; iconSize: 15; color: Appearance.colors.colOnLayer0 }
                                    }
                                }
                            }

                            // ── Mode 1: running pomodoro ───────────────
                            RowLayout {
                                visible: root.nowMode === 1
                                spacing: root.rowPadding

                                Item {
                                    Layout.preferredHeight: root.ringSize
                                    implicitWidth: root.ringSize + 8
                                    readonly property real lapFrac: TimerService.pomodoroSecondsLeft > 0
                                        ? Math.max(0, Math.min(1, 1 - TimerService.pomodoroSecondsLeft / Math.max(1, TimerService.pomodoroLapDuration)))
                                        : 0
                                    readonly property color lapColor: Appearance.colors.colPrimary
                                    ProviderRing {
                                        anchors.centerIn: parent
                                        diameter: root.ringSize
                                        trackWidth: root.ringTrack
                                        arcWidth: root.ringTrack
                                        logoSize: root.ringSize * 0.40
                                        fraction: parent.lapFrac
                                        arcColor: parent.lapColor
                                        provider: "timer"
                                        dimmed: false
                                        exhausted: false
                                    }
                                    MaterialSymbol {
                                        anchors.centerIn: parent
                                        text: "timer"
                                        iconSize: root.ringSize * 0.40
                                        color: parent.lapColor
                                    }
                                }
                                StyledText {
                                    text: {
                                        const s = Math.max(0, TimerService.pomodoroSecondsLeft);
                                        const m = Math.floor(s / 60);
                                        const sec = s % 60;
                                        return `${m}:${sec < 10 ? "0" : ""}${sec}`;
                                    }
                                    font.pixelSize: Appearance.font.pixelSize.small
                                    font.weight: Font.Medium
                                    color: Appearance.colors.colOnLayer0
                                }
                                StyledText {
                                    text: Translation.tr("timer")
                                    font.pixelSize: Appearance.font.pixelSize.smallie
                                    color: Appearance.colors.colOutline
                                }
                                RippleButton {
                                    Layout.preferredWidth: 30
                                    Layout.fillHeight: true
                                    colBackground: hovered ? Appearance.colors.colLayer0Hover : "transparent"
                                    colBackgroundHover: Appearance.colors.colLayer0Hover
                                    onClicked: TimerService.togglePomodoro()
                                    MaterialSymbol { anchors.centerIn: parent; text: TimerService.pomodoroRunning ? "pause" : "play_arrow"; iconSize: 18; color: Appearance.colors.colOnLayer0 }
                                }
                            }

                            // ── Mode 2: AI rings ───────────────────────
                            RowLayout {
                                visible: root.nowMode === 2
                                spacing: root.rowPadding

                                Repeater {
                                    model: FlareData.cells
                                    Item {
                                        id: ringSlot
                                        required property var modelData
                                        readonly property var cell: modelData
                                        Layout.preferredHeight: root.ringSize
                                        implicitWidth: root.ringSize + 8

                                        ProviderRing {
                                            anchors.centerIn: parent
                                            diameter: root.ringSize
                                            trackWidth: root.ringTrack
                                            arcWidth: root.ringTrack
                                            logoSize: root.ringSize * 0.52
                                            fraction: ringSlot.cell.metered ? (ringSlot.cell.used ?? 0) : 0
                                            arcColor: ringSlot.cell.arcColor
                                            provider: ringSlot.cell.kind
                                            dimmed: ringSlot.cell.dimmed
                                            exhausted: ringSlot.cell.exhausted
                                        }
                                        HoverHandler {
                                            onHoveredChanged: if (hovered) {
                                                FlareData.usageProvider = ringSlot.cell.id;
                                                root.usageHovered = true;
                                            }
                                        }
                                        TapHandler {
                                            onTapped: {
                                                FlareData.usageProvider = ringSlot.cell.id;
                                                root.usageHovered = true;
                                            }
                                        }
                                    }
                                }

                                Text {
                                    visible: FlareData.cells.length === 0
                                    text: "No AI tools detected"
                                    color: Appearance.colors.colOnLayer0
                                    opacity: 0.55
                                    font.pixelSize: Appearance.font.pixelSize.small
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // The month view: one github-style graph per provider, deck of rings on
    // top to pick, and nothing else -- the week/session detail retired.
    component UsageMonthSheet: Rectangle {
        color: "transparent"

        // The sheet's own height: deck + graph band + label. Drives the
        // panel height through sheetLoader.item.implicitHeight.
        implicitHeight: 250

        readonly property var cells: FlareData.usageCells
        readonly property var cell: cells.find(c => c.id === FlareData.usageProvider) || cells[0] || null
        // Month buckets: per-day sums across the last ~30 days.
        readonly property var month: {
            if (!cell)
                return null;
            const hours = FlareData.viewActivity[cell.id] || [];
            const now = FlareData.now;
            const day0 = (() => { const d = new Date((now - 30 * 86400) * 1000); d.setHours(0, 0, 0, 0); return d.getTime() / 1000; })();
            const days = 31;
            const sums = new Array(days).fill(0);
            const known = new Array(days).fill(false);
            for (const h of hours) {
                const k = Math.floor((h[0] - day0) / 86400);
                if (k >= 0 && k < days) {
                    sums[k] += h[1];
                    known[k] = true;
                }
            }
            let max = 0;
            for (let k = 0; k < days; k++)
                if (sums[k] > max)
                    max = sums[k];
            return { sums: sums, known: known, max: max, day0: day0 };
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 14
            spacing: 14

            // The provider deck: pick whose month you see.
            RowLayout {
                id: providerDeck
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredHeight: 56
                spacing: 22
                Repeater {
                    model: FlareData.usageCells
                    delegate: Item {
                        required property var modelData
                        readonly property bool picked: FlareData.usageProvider === modelData.id || (!FlareData.usageProvider && index === 0)
                        Layout.preferredWidth: 44
                        Layout.preferredHeight: 52
                        ColumnLayout {
                            anchors.centerIn: parent
                            spacing: 4
                            ProviderRing {
                                Layout.alignment: Qt.AlignHCenter
                                diameter: 34
                                trackWidth: 3
                                arcWidth: 3
                                logoSize: 18
                                fraction: modelData.metered ? (modelData.used ?? 0) : 0
                                arcColor: modelData.arcColor
                                provider: modelData.kind
                                dimmed: modelData.dimmed
                                exhausted: modelData.exhausted
                            }
                            StyledText {
                                Layout.alignment: Qt.AlignHCenter
                                text: modelData.name
                                font.pixelSize: Appearance.font.pixelSize.smallie
                                color: parent.parent.picked ? Appearance.colors.colPrimary : Appearance.colors.colOutline
                            }
                        }
                        TapHandler {
                            onTapped: FlareData.usageProvider = modelData.id
                        }
                    }
                }
            }

            // The month graph: 31 day-columns, github darkness scale, all
            // bars on a shared bottom baseline.
            Rectangle {
                id: monthGraph
                Layout.fillWidth: true
                implicitHeight: 100
                clip: true
                color: "transparent"

                readonly property int dayW: 16
                readonly property int gap: 5
                readonly property int cols: month ? month.sums.length : 0

                Row {
                    id: barRow
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 6
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: monthGraph.gap
                    Repeater {
                        model: monthGraph.cols
                        delegate: Rectangle {
                            required property int index
                            width: monthGraph.dayW
                            anchors.bottom: parent.bottom
                            // The bar height: github-like intensity, min stub
                            // for zero days.
                            readonly property real frac: month && month.max > 0 ? month.sums[index] / month.max : 0
                            readonly property real hMin: 5
                            height: Math.max(hMin, (monthGraph.height - 10) * frac)
                            radius: 4
                            color: {
                                if (!month || !month.known[index])
                                    return Appearance.colors.colLayer1;
                                const f = frac;
                                if (f <= 0)
                                    return Qt.alpha(Appearance.colors.colPrimary, 0.16);
                                return Qt.alpha(Appearance.colors.colPrimary, 0.25 + 0.75 * f);
                            }
                            Behavior on height {
                                NumberAnimation { duration: 400; easing.type: Easing.OutCubic }
                            }
                        }
                    }
                }
            }

            // The month label + total.
            StyledText {
                Layout.alignment: Qt.AlignHCenter
                readonly property int total: month ? Math.round(month.sums.reduce((a, b) => a + b, 0)) : 0
                text: month ? `Last 31 days · ${total} tokens` : "No data yet"
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colOutline
            }
        }
    }

    // Diagnostic / test hook.
    IpcHandler {
        target: "dock"

        function open(): void { root.usageHovered = true }
        function close(): void { root.usageHovered = false }
        function tab(i: int): void { root.tabIndex = i }
        function cycle(delta: int): void { root.cycleTab(delta) }
        function pomodoro(action: string): void {
            if (action === "toggle") TimerService.togglePomodoro();
            else if (action === "reset") TimerService.resetPomodoro();
        }
        function mock(on: bool): void { FlareData.mockMode = on }
        function state(): string {
            return root.diag;
        }
    }
}
