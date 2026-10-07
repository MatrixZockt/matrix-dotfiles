pragma ComponentBehavior: Bound
import qs
import qs.services
import qs.modules.common
import qs.modules.common.models
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland

// "Ball & line" workspaces: the active desktop is an accent BALL; every other
// desktop is a line — longer and brighter when occupied, shorter and fainter
// when empty. No numbers anywhere. Switching morphs the outgoing ball down to
// a line and the incoming line up into a ball IN PLACE (no slide, no mask
// layers) — one spring, snappy like the rest of the bar. The trailing "+"
// slot is a line too (illuminated accent when active, the same faint tone as
// its glyph when not); the glyph never grows a dot background.
ButtonMouseArea {
    id: root

    readonly property HyprlandMonitor monitor: Hyprland.monitorFor(root.QsWindow.window?.screen)
    WorkspaceModel {
        id: wsModel
        monitor: root.monitor
    }

    property bool vertical: Config.options.bar.vertical

    // ── Compact ───────────────────────────────────────────────────────────
    // The same ball-and-line widget, sized for the small desktop indicator at
    // the bottom of the screen (see modules/ii/desktopIndicator). Only the
    // METRICS change: every interaction -- click to switch, right click for
    // the desktop grid, the wheel, the trailing "+" slot -- is the one the bar
    // already had, because it is the same component and not a copy of it.
    property bool compact: false

    // The reclaim tell: held true while the desktop indicator plays its
    // "this desktop just got its first window" moment (DesktopIndicator owns
    // the trigger; the animation itself lives on the active ball below).
    property bool farewellPulse: false

    property real workspaceButtonWidth: compact ? 21 : 30
    // Air INSIDE the cell: the active square sits centered with this margin on
    // every side, so it never touches its neighbours.
    property real activeWorkspaceMargin: compact ? 2.5 : 4
    property real activeWorkspaceSize: workspaceButtonWidth - activeWorkspaceMargin * 2
    property real specialTextSize: workspaceButtonWidth * 0.5

    // The shapes, one size (or two) for the whole widget: the active ball, the
    // dash of a desktop with windows, and the shorter dash of an empty one.
    readonly property real ballSize: compact ? 8 : 12
    readonly property real occupiedDash: compact ? 11 : 16
    readonly property real emptyDash: compact ? 6 : 9
    readonly property real dashThickness: compact ? 3 : 4
    // How much the whole cross grows when the slot is selected. Applied as a
    // UNIFORM scale on the glyph, never to one arm: a "+" that grew on the
    // horizontal only would stop being a plus. Deliberately small -- the
    // selected line does NOT change length at all any more (see
    // compactActiveLine), so this 15% is the only size change in the pill --
    // and it is on the one glyph that is not a desktop.
    //
    // There is NO line under the "+", ever. An earlier revision grew one in
    // below the cross and that was wrong: the pill is a row of lines, and
    // putting a line under the one cell that is not a desktop made it read
    // as a sixth desktop that had lost its label. The cross carries the
    // state on its own -- accent colour plus this small growth.
    readonly property real plusSelectedScale: 1.15

    // The trailing "+" can never be `isActive`: it is the slot that is NOT a
    // desktop, so `workspaceIndexInGroup` never lands on it. Hovering it is
    // how the pill says "this one is selected" (see `tileHovered`, and the
    // pill's own `index:` which follows the pointer for the same reason).
    // So the cross has to answer to hover too, or it never moves at all.
    readonly property bool plusSelected: root.containsMouse
        && root.hoverIndex === wsModel.shownCount - 1

    // ── Compact redesign (REQUESTED 2026-09-29) ──
    // The bottom desktop pill is now entirely LINES: every inactive desktop is
    // a flat grey line, the ACTIVE desktop is the same line in the accent
    // colour and slightly longer, and the trailing "+" is a grey line with a
    // grey glyph that turns accent when the pointer is on it or when the slot
    // IS the active desktop. No dots, no balls, and -- the part that had to go
    // with them -- no background fill behind the selected cell: the accent
    // LINE is the selection. A coloured plate behind it was saying the same
    // thing twice, and made a 3px line look like a tab.
    // The bar itself (compact: false) keeps ball-for-active /
    // line-for-inactive unchanged.
    //
    // The active line is the SAME LENGTH as the inactive ones: a switch reads
    // as "this one lit up", and nothing about it moves.
    //
    // It was 11 -> 18, a 64% jump. Then 11 -> 14, +27%. Both were still "too
    // big": the line in the bottom pill sits in a 21px cell, so ANY growth is
    // a visible slab un-building and re-building itself inside the capsule on
    // every desktop switch -- and at 1.6x scale that slab is what the eye
    // lands on, not the accent colour it was supposed to be confirming.
    //
    // So the growth is gone. `compactActiveLine` is now the inactive length
    // plus zero: every line in the pill is the same length at all times, and
    // the ACTIVE colour is the entire selection signal. That is the one state
    // a pill this small can carry without the mark moving under the eye.
    // The 3px thickness never changed either. To get a little length back,
    // this is the single number: +1 gives a 9% nudge, +2 a 18% one.
    readonly property real compactLine: compact ? 11 : 0
    readonly property real compactActiveLine: compactLine

    // Position of the focused workspace in the (dynamic) shown list, rather than its
    // raw id modulo a fixed group size -- the list is now only the desktops that exist.
    property int workspaceIndexInGroup: Math.max(0, wsModel.shownIds.indexOf(monitor?.activeWorkspace?.id ?? 1))
    readonly property real gridLength: wsModel.shownCount * workspaceButtonWidth

    Layout.alignment: vertical ? Qt.AlignHCenter : Qt.AlignVCenter
    Layout.fillWidth: vertical
    Layout.fillHeight: !vertical
    readonly property real barThickness: vertical ? Appearance.sizes.verticalBarWidth
        : (compact ? 24 : Appearance.sizes.barHeight)
    implicitWidth: vertical ? barThickness : gridLength
    implicitHeight: vertical ? gridLength : barThickness

    property real specialBlur: (wsModel.specialWorkspaceActive && !containsMouse) ? 1 : 0
    Behavior on specialBlur {
        animation: Appearance.animation.elementMoveSmall.numberAnimation.createObject(this)
    }

    // Interactions
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.BackButton
    hoverEnabled: true
    property int hoverIndex: {
        const position = root.vertical ? mouseY : mouseX;
        return Math.floor(position / root.workspaceButtonWidth);
    }

    function switchWorkspaceToHovered() {
        // Through the anamorphic driver so the click plays the same illusion
        // as the keyboard. This fork's Hyprland.dispatch Lua-evals its argument
        // (that is why the plain "exec ..." form throws, and hl.exec_cmd as a
        // *dispatch payload* is rejected by the compositor -- the verified
        // spawn path is Quickshell.execDetached, the same one Session.qml uses).
        Quickshell.execDetached(["bash", "-c",
            `${Quickshell.env("HOME")}/.config/hypr/custom/scripts/anamorphic.py focus ${wsModel.getWorkspaceIdAt(hoverIndex)}`]);
    }

    function toggleSpecial() {
        Hyprland.dispatch(`hl.dsp.workspace.toggle_special("special")`);
    }

    onPressed: mouse => {
        if (mouse.button == Qt.LeftButton)
            switchWorkspaceToHovered();
        else if (mouse.button == Qt.RightButton) {
            // Right-clicking the desktops is a request for the desktop grid.
            GlobalStates.overviewMode = "desktops";
            GlobalStates.overviewOpen = !GlobalStates.overviewOpen;
        }
        else if (mouse.button == Qt.BackButton) 
            toggleSpecial()
    }
    onWheel: event => {
        // Wheel steps go through the driver too (rel computes the target).
        const step = event.angleDelta.y < 0 ? 1 : -1;
        Quickshell.execDetached(["bash", "-c",
            `${Quickshell.env("HOME")}/.config/hypr/custom/scripts/anamorphic.py rel ${step}`]);
    }

    // Indications
    Item {
        id: regularWorkspaces
        anchors.fill: parent

        scale: 1 - 0.08 * root.specialBlur
        layer.smooth: true
        layer.enabled: root.specialBlur > 0
        layer.effect: MultiEffect {
            brightness: -0.1 * root.specialBlur
            blurEnabled: true
            blur: root.specialBlur
            blurMax: 32
        }

        /////////////////// Active desktop ///////////////////
        // The active marker does NOT travel: each cell morphs in place (see
        // NumberWorkspaceItem) -- the outgoing desktop's dot minimizes to a
        // dash while the incoming dash grows into the dot. One spring, no
        // slide, nothing to mask.

        /////////////////// Hover ///////////////////
        // Nothing behind the cells.
        //
        // The compact pill is a flat row of 3px lines; a coloured plate
        // behind the selected one said "selected" a second time, made a line
        // read as a tab, and -- on a row this small -- was the loudest thing
        // on screen, which is the opposite of a glance. The accent LINE is the
        // selection, and hover is carried by brightening the line under the
        // pointer (see shapeRect's colour) rather than by painting a shape.
        //
        // The bar (compact: false) is a different, larger component with its
        // own affordances, so it keeps the sliding pill and its hover plate.
        TrailingIndicator {
            id: interactionIndicator
            anchors.fill: parent
            z: 3
            visible: !root.compact
            index: root.containsMouse ? root.hoverIndex : root.workspaceIndexInGroup
            pillMode: true
            color: "transparent"
            StateOverlay {
                id: hoverOverlay
                anchors.fill: interactionIndicator.indicatorRectangle
                radius: interactionIndicator.indicatorRectangle.radius
                hover: root.containsMouse
                press: root.containsPress
                drag: true // There are too many layers so we need to force this to be a lil more opaque
                contentColor: Appearance.colors.colPrimary
            }
        }

        /////////////////// Desktops ///////////////////
        WorkspaceLayout {
            id: numbersGrid
            z: 4

            Repeater {
                model: wsModel.shownCount
                delegate: NumberWorkspaceItem {}
            }
        }
    }

    FadeLoader {
        anchors.centerIn: parent
        shown: wsModel.specialWorkspaceActive
        scale: 0.8 + 0.2 * root.specialBlur

        opacity: root.specialBlur
        Behavior on opacity {} // Don't animate, as specialBlur is already animated

        sourceComponent: WorkspaceTile {
            anchors.centerIn: parent
            property real undirectionalWidth: root.activeWorkspaceSize
            property real undirectionalLength: {
                const base = root.workspaceButtonWidth * Math.min(1.35, wsModel.shownCount); // Who tf only configures only 2 workspaces shown anyway?
                if (root.vertical)
                    return base;
                return specialWsText.implicitWidth + undirectionalWidth;
            }
            color: Appearance.colors.colPrimary

            implicitWidth: root.vertical ? undirectionalWidth : undirectionalLength
            implicitHeight: root.vertical ? undirectionalLength : undirectionalWidth

            StyledText {
                id: specialWsText
                anchors.centerIn: parent
                text: (!root.vertical ? wsModel.specialWorkspaceName : "S")
                color: Appearance.colors.colOnPrimary
                font.pixelSize: root.specialTextSize
            }

            Behavior on undirectionalLength {
                animation: Appearance.animation.elementMoveEnter.numberAnimation.createObject(this)
            }
        }
    }

    // Rounded-square tile used by the special-workspace display.
    component WorkspaceTile: Rectangle {
        radius: Appearance.rounding.small
    }

    component WorkspaceLayout: Box {
        anchors {
            top: !root.vertical ? parent.top : undefined
            bottom: !root.vertical ? parent.bottom : undefined
            left: root.vertical ? parent.left : undefined
            right: root.vertical ? parent.right : undefined
        }

        rowSpacing: 0
        columnSpacing: 0
        vertical: root.vertical
    }

    component WorkspaceItem: Item {
        required property int index
        readonly property int wsId: wsModel.getWorkspaceIdAt(index)
        implicitWidth: root.vertical ? root.barThickness : root.workspaceButtonWidth
        implicitHeight: root.vertical ? root.workspaceButtonWidth : root.barThickness
    }

    // (The layout-map blocks were retired with concept 3; the dot/dash
    // morph design is back. The component below remains for reference.)

    component NumberWorkspaceItem: WorkspaceItem {
        id: wsNum
        property int wsId: wsModel.getWorkspaceIdAt(index)
        property bool isActive: root.workspaceIndexInGroup === wsNum.index
        property bool occupied: !!wsModel.occupied[wsNum.index] && wsId !== wsModel.fakeWorkspace
        // The trailing empty slot is where a new desktop gets created.
        property bool isNewDesktopSlot: wsNum.index === wsModel.shownCount - 1 && !wsNum.occupied
        property bool tileHovered: root.containsMouse && root.hoverIndex === wsNum.index
        // The one scale both animations below drive. It used to be `scale` on
        // the shape itself, which only ever held ONE animation; with two, the
        // later one silently wins and the other is never seen.
        property real arrivalScale: 1.0
        // The "＋" cell's own state scale, kept separate from `scale` for the
        // same reason: the Behavior belongs on the state, and the pulse
        // belongs on arrivalScale. Multiplied together at the use site.
        property real plusScale: (wsNum.isActive || root.plusSelected)
            ? root.plusSelectedScale : 1.0
        Behavior on plusScale {
            animation: Appearance.animation.elementMoveSmall.numberAnimation.createObject(this)
        }
        // Whether this cell WAS active, so the pulse fires on a real handover
        // and not on first paint. A pill that pulses the desktop you are
        // already on every time the shell loads is worse than no pulse.
        property bool wasActive: false
        Component.onCompleted: wsNum.wasActive = wsNum.isActive
        onIsActiveChanged: {
            if (wsNum.isActive && !wsNum.wasActive)
                arrivalAnim.restart();
            wsNum.wasActive = wsNum.isActive;
        }
        property color contentColor: wsNum.isActive ? Appearance.colors.colOnPrimary :
            wsNum.occupied ? Appearance.colors.colOnSecondaryContainer :
            Appearance.colors.colOnLayer1Inactive
        // (The separate `shapeColor` this used to have went with the flat-line
        // redesign: the line's fill IS the state colour, there is no shape
        // behind it and no number sitting on an accent plate.)

        // The trailing "+" slot is a LINE like every other desktop — never a
        // ball. Inactive it is the same faint tone as the unselected "+" glyph;
        // when the slot IS the active desktop the line illuminates in the
        // accent and the glyph changes colour with it — no accent background,
        // the symbol itself carries the state.
        readonly property bool plusSlot: wsNum.isNewDesktopSlot
        // The bar (compact: false) still marks the active desktop with a
        // BALL and morphs into it. The bottom pill does not: its active
        // desktop is a line, so there is nothing to morph into and the ball
        // branch is skipped there entirely.
        readonly property bool morphsToBall: !root.compact && wsNum.isActive
            && !wsNum.plusSlot

        // The cell shape MORPHS IN PLACE on a switch: the active desktop is a
        // BALL (a plain accent dot -- numbers are gone), every other desktop
        // is a line -- wider and brighter when it has windows, shorter and
        // fainter when empty. So "shrink the ball, grow the line into a ball"
        // is the whole switch animation: no slide, one spring, snappy like
        // the rest of the bar.
        Rectangle {
            id: shapeRect
            anchors.centerIn: parent
            // The "+" cell draws NO line, at rest or selected. The pill is a
            // row of lines; a line under the one cell that is not a desktop
            // made it look like a desktop that had lost its label. The cross
            // is the whole mark, and it carries the state by lighting up and
            // growing a little.
            visible: !wsNum.plusSlot

            // Sized by the widget's own metrics, so the compact indicator is
            // the same design at a smaller scale rather than a second one.
            readonly property real ballSize: root.ballSize
            // Compact: every cell is a line. Inactive ones share ONE grey --
            // the occupied/empty distinction was a second thing to decode in a
            // 3px mark, and at that size it read as two different greys by
            // accident. The active line is the same length, in accent.
            //
            // There is deliberately no `plusSlot` case here. The "+" cell is
            // hidden outright above, so sizing it would be dead code -- and
            // dead code that still mentions the "+" is exactly how the line
            // under the cross came back the first time.
            implicitWidth: wsNum.morphsToBall ? ballSize
                : root.compact
                    ? (wsNum.isActive ? root.compactActiveLine : root.compactLine)
                    : (wsNum.occupied ? root.occupiedDash : root.emptyDash)
            implicitHeight: wsNum.morphsToBall ? ballSize : root.dashThickness
            radius: wsNum.morphsToBall ? ballSize / 2 : root.dashThickness / 2
            // Compact (the bottom pill): one flat grey for every inactive
            // desktop, accent for the active one. The bar keeps its own
            // occupied/empty distinction, which is legible at its size and is
            // not ours to change.
            color: root.compact
                ? (wsNum.isActive ? Appearance.colors.colPrimary
                    : wsNum.tileHovered ? Appearance.colors.colOnSecondaryContainer
                    : Appearance.colors.colOnLayer1Inactive)
                : (wsNum.isActive ? Appearance.colors.colPrimary
                    : wsNum.occupied ? Appearance.colors.colOnSecondaryContainer
                    : Appearance.colors.colOnLayer1Inactive)
            // The reclaim wink: one squash-and-stretch pulse when the first
            // window claims the desktop we are watching (root.farewellPulse,
            // driven by DesktopIndicator). Scale only -- the accent ball is
            // already the loudest thing in the pill, and a size pulse reads
            // as "this point just became real" without a single label.
            // alwaysRunToEnd so an early release never leaves the dot
            // mid-squash.
            scale: wsNum.arrivalScale
            SequentialAnimation {
                running: root.farewellPulse && wsNum.isActive
                alwaysRunToEnd: true
                loops: 1
                NumberAnimation { target: wsNum; property: "arrivalScale"; from: 1.0; to: 1.45; duration: 150; easing.type: Easing.OutCubic }
                NumberAnimation { target: wsNum; property: "arrivalScale"; from: 1.45; to: 0.8; duration: 230; easing.type: Easing.InOutQuad }
                NumberAnimation { target: wsNum; property: "arrivalScale"; from: 0.8; to: 1.0; duration: 300; easing.type: Easing.OutBack }
            }
            // (The "+" cell is `visible: false` at the top of this block.
            // There is no dash under the cross, ever -- not at rest, not on
            // hover, not selected. The cross carries that state alone.)

            Behavior on implicitWidth {
                animation: Appearance.animation.elementMoveSmall.numberAnimation.createObject(this)
            }
            Behavior on implicitHeight {
                animation: Appearance.animation.elementMoveSmall.numberAnimation.createObject(this)
            }
            Behavior on radius {
                animation: Appearance.animation.elementMoveSmall.numberAnimation.createObject(this)
            }
            Behavior on color {
                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
            }
            Behavior on opacity {
                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
            }
        }

        // ── The arrival pulse ─────────────────────────────────────────────
        // One soft swell as the active desktop becomes this one. Chosen over
        // a morph because the pill's marks are 3px tall: at that size a shape
        // CHANGE is what the eye lands on, and the active line is
        // deliberately the same length as every other line (see
        // `compactActiveLine`), so there is nothing to morph into. The bar's
        // own widget gets it too, where the active mark IS a ball and the
        // swell reads on a larger shape.
        //
        // Deliberately gentler than the reclaim wink above, and gentler than
        // the preview it was picked from: that one snapped to 1.45 in 150ms
        // and came back through a squash, which on a mark this small reads as
        // a click rather than a breath. This one swells to 1.16 over 280ms
        // and settles over 460ms, on curves with no overshoot and no
        // reversal: the whole motion is one direction out and one back, so it
        // cannot look like the mark flinched.
        SequentialAnimation {
            id: arrivalAnim
            running: false
            alwaysRunToEnd: true
            loops: 1
            NumberAnimation {
                target: wsNum; property: "arrivalScale"
                from: 1.0; to: 1.16; duration: 280
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: wsNum; property: "arrivalScale"
                from: 1.16; to: 1.0; duration: 460
                easing.type: Easing.InOutSine
            }
        }

        // The trailing empty slot reads as "add a desktop" rather than as
        // another unused line: click it (or move right to it) and Hyprland
        // creates it.
        //
        // The glyph scales by a SLAM 1.15 when the slot is selected, and by
        // nothing else. It used to sit at 0.82 and pop to 1.0 on hover/active
        // -- a 22% jump that made the one symbol in the pill the only thing
        // in it that changed shape. This is a nudge on the way to being
        // selected, it is uniform (both arms, or it would not be a plus any
        // more), and it settles with the same curve as the line cells use.
        FadeLoader {
            shown: wsNum.isNewDesktopSlot
            // The loader's item fills this cell, so centring the glyph in the
            // ITEM centres it in the cell; anchoring the inner icon to the
            // loader's centre let it drift off-centre by the loader's own
            // size rounding ("the cross is not centered").
            anchors.fill: parent
            MaterialSymbol {
                anchors.centerIn: parent
                text: "add"
                iconSize: root.workspaceButtonWidth * (root.compact ? 0.72 : 0.62)
                // The cross IS the state: accent when this slot is the active
                // desktop, brighter on hover, and at rest the same faint grey
                // as the line it sits beside. Selected also grows it a
                // little -- the same animation the lines' width change uses,
                // so the two cells answer a selection the same way.
                // Hover takes it all the way to accent, not a half-step up.
                // A line cell is either the accent colour or it is not, and
                // the cross answering a hover with a barely-brighter grey
                // read as nothing happening at all.
                color: wsNum.isActive || root.plusSelected ? Appearance.colors.colPrimary
                    : wsNum.tileHovered ? Appearance.colors.colOnSecondaryContainer
                    : Appearance.colors.colOnLayer1Inactive
                // BOTH motions live here: the settled state scale (animated by
                // the Behavior on plusScale) and the arrival pulse (animated
                // straight onto arrivalScale, no Behavior). The "＋" cell draws
                // no line -- shapeRect is hidden on it -- so before this the
                // pulse fired on a cell whose only visible mark was the cross,
                // and a swipe onto the new-desktop slot did nothing at all.
                scale: wsNum.plusScale * wsNum.arrivalScale
                Behavior on color {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }
            }
        }
        // (Numbers are retired: the ball alone marks the active desktop.)
    }

    // (The sliding pill indicator was retired with the dot design; the
    // component below remains only for reference.)
    component TrailingIndicator: Item {
        id: trailingIndicator
        anchors.fill: parent
        required property int index
        property alias indicatorRectangle: indicatorRect
        property alias color: indicatorRect.color
        // Pill mode: fully rounded ends and extra reach, so the active marker
        // reads as a wide pill instead of a square tile.
        property bool pillMode: false
        property real extraLength: 0

        property var indexPair: AnimatedTabIndexPair {
            id: idxPair
            index: trailingIndicator.index
        }

        StyledRectangle {
            id: indicatorRect

            anchors {
                verticalCenter: root.vertical ? undefined : parent.verticalCenter
                horizontalCenter: root.vertical ? parent.horizontalCenter : undefined
            }

            property real pillExtra: trailingIndicator.pillMode ? trailingIndicator.extraLength : 0
            // Rounded SQUARE tab, not a full pill: the active desktop reads as
            // a distinct selected tab (matching the bar's rounded-square
            // language) while still sliding. extraLength gives it the width;
            // radius keeps the corners rounded but not capsule-round.
            property real indicatorPosition: Math.max(
                Math.min(idxPair.idx1, idxPair.idx2) * root.workspaceButtonWidth + root.activeWorkspaceMargin - pillExtra / 2,
                0)
            property real indicatorLength: Math.abs(idxPair.idx1 - idxPair.idx2) * root.workspaceButtonWidth
                + root.activeWorkspaceSize + pillExtra
            property real indicatorThickness: root.activeWorkspaceSize

            contentLayer: StyledRectangle.ContentLayer.Group
            radius: trailingIndicator.pillMode ? Appearance.rounding.normal : Appearance.rounding.small
            color: Appearance.colors.colPrimary

            x: root.vertical ? null : indicatorPosition
            y: root.vertical ? indicatorPosition : null
            implicitWidth: root.vertical ? indicatorThickness : indicatorLength
            implicitHeight: root.vertical ? indicatorLength : indicatorThickness
        }
    }
}
