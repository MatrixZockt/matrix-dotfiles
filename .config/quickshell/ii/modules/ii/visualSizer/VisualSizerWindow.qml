import QtQuick
import Quickshell
import Quickshell.Wayland

import qs.modules.common
import qs.services

/**
 * The visual sizer's overlay surface: an accent frame hugging the armed
 * window, with eight drag handles and a center move surface. Mounted by the
 * panel family; all state and the compositor dispatches live in the
 * VisualSizer singleton.
 *
 * Coordinate notes that matter:
 *  - The frame's x/y/w/h are in the monitor's LOGICAL space, which is the
 *    same space the compositor reports for clients and accepts in the
 *    pixel move/resize dispatches. The window fills the whole screen, so
 *    window coordinates == screen coordinates here.
 *  - Drag math uses WINDOW coordinates (mapToItem null), never local ones:
 *    when a west/north handle drags, the frame itself moves, so its local
 *    space is not a stable ruler. The sizer window never moves.
 */
PanelWindow {
    id: sizerWindow

    visible: VisualSizer.armed
    exclusionMode: ExclusionMode.Ignore
    exclusiveZone: -1
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell:visualSizer"
    // Exclusive while armed so the arrow nudge reaches the window.
    WlrLayershell.keyboardFocus: VisualSizer.armed ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    // Only the frame (and the handles on it) take input; the rest of the
    // overlay passes clicks straight through, so the desktop underneath
    // never feels blocked while the frame is up.
    mask: Region { item: frame }

    Rectangle {
        id: frame

        // Keyboard: arrows resize, Shift+arrows bigger steps, Esc/Enter exit.
        focus: true
        Keys.onPressed: (event) => {
            const step = event.modifiers & Qt.ShiftModifier ? VisualSizer.nudgeStepBig : VisualSizer.nudgeStep;
            let changed = false;
            switch (event.key) {
            case Qt.Key_Left:  VisualSizer.winW = Math.max(VisualSizer.minW, VisualSizer.winW - step); changed = true; break;
            case Qt.Key_Right: VisualSizer.winW = VisualSizer.winW + step; changed = true; break;
            case Qt.Key_Up:    VisualSizer.winH = Math.max(VisualSizer.minH, VisualSizer.winH - step); changed = true; break;
            case Qt.Key_Down:  VisualSizer.winH = VisualSizer.winH + step; changed = true; break;
            case Qt.Key_Escape:
            case Qt.Key_Enter:
            case Qt.Key_Return:
                VisualSizer.disarm();
                event.accepted = true;
                return;
            default:
                return;
            }
            event.accepted = true;
            if (changed)
                VisualSizer.commit();
            VisualSizer.bumpTimeout();
        }

        x: VisualSizer.winX
        y: VisualSizer.winY
        width: VisualSizer.winW
        height: VisualSizer.winH
        // A whisper of the accent inside the frame so the target surface
        // reads as "selected" without hiding the app underneath.
        color: Qt.rgba(Appearance.colors.colPrimary.r, Appearance.colors.colPrimary.g, Appearance.colors.colPrimary.b, 0.06)
        radius: Appearance.rounding.normal
        border.width: 3
        border.color: Appearance.colors.colPrimary
        visible: VisualSizer.armed

        Behavior on x { NumberAnimation { duration: 40 } }
        Behavior on y { NumberAnimation { duration: 40 } }
        Behavior on width { NumberAnimation { duration: 40 } }
        Behavior on height { NumberAnimation { duration: 40 } }

        // Center drag surface: moves the window (floating only).
        MouseArea {
            id: moveMa

            anchors.fill: parent
            enabled: VisualSizer.targetFloating
            cursorShape: Qt.SizeAllCursor
            onPressed: (event) => {
                VisualSizer.dragMode = 0;
                VisualSizer.dragging = true;
                const p = moveMa.mapToItem(null, event.x, event.y);
                VisualSizer.pressX = p.x; VisualSizer.pressY = p.y;
                VisualSizer.origX = VisualSizer.winX; VisualSizer.origY = VisualSizer.winY;
                VisualSizer.origW = VisualSizer.winW; VisualSizer.origH = VisualSizer.winH;
                VisualSizer.bumpTimeout();
            }
            onPositionChanged: (event) => {
                if (!VisualSizer.dragging)
                    return;
                const p = moveMa.mapToItem(null, event.x, event.y);
                VisualSizer.winX = VisualSizer.origX + (p.x - VisualSizer.pressX);
                VisualSizer.winY = VisualSizer.origY + (p.y - VisualSizer.pressY);
                VisualSizer.commit();
            }
            onReleased: () => {
                VisualSizer.dragging = false;
                VisualSizer.syncGeometry();
            }
        }

        // Hint pill: what this is and how to leave.
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: -34
            radius: height / 2
            color: Appearance.colors.colLayer1
            border.width: 1
            border.color: Appearance.colors.colLayer0Border
            width: hint.implicitWidth + 20
            height: 24
            opacity: hintTimer.running ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 200 } }

            Timer { id: hintTimer; interval: 4000; running: VisualSizer.armed }
            Text {
                id: hint
                anchors.centerIn: parent
                text: VisualSizer.targetFloating
                    ? "Drag edges to resize · center to move · Esc to exit"
                    : "Drag edges to resize · Esc to exit"
                color: Appearance.colors.colOnLayer1
                font.pixelSize: 11
            }
        }

        component Handle: Rectangle {
            id: handleRoot

            // mode: bitfield 1=N 2=E 4=S 8=W
            property int mode

            color: handleMa.containsMouse || handleMa.containsPress
                ? Qt.rgba(Appearance.colors.colPrimary.r, Appearance.colors.colPrimary.g, Appearance.colors.colPrimary.b, 0.35)
                : "transparent"
            radius: 4

            MouseArea {
                id: handleMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: {
                    const m = handleRoot.mode;
                    if (m === (1 | 2) || m === (4 | 8)) return Qt.SizeFDiagCursor;
                    if (m === (1 | 8) || m === (4 | 2)) return Qt.SizeBDiagCursor;
                    if (m & 2 || m & 8) return Qt.SizeHorCursor;
                    return Qt.SizeVerCursor;
                }
                onPressed: (event) => {
                    VisualSizer.dragMode = handleRoot.mode;
                    VisualSizer.dragging = true;
                    // Same ruler as the move surface: window coordinates.
                    const p = handleMa.mapToItem(null, event.x, event.y);
                    VisualSizer.pressX = p.x; VisualSizer.pressY = p.y;
                    VisualSizer.origX = VisualSizer.winX; VisualSizer.origY = VisualSizer.winY;
                    VisualSizer.origW = VisualSizer.winW; VisualSizer.origH = VisualSizer.winH;
                    VisualSizer.bumpTimeout();
                }
                onPositionChanged: (event) => {
                    if (!VisualSizer.dragging)
                        return;
                    const m = VisualSizer.dragMode;
                    const p = handleMa.mapToItem(null, event.x, event.y);
                    const dx = p.x - VisualSizer.pressX;
                    const dy = p.y - VisualSizer.pressY;
                    if (m & 2) { // east edge follows the pointer
                        VisualSizer.winW = Math.max(VisualSizer.minW, VisualSizer.origW + dx);
                    }
                    if (m & 8) { // west edge: width and origin move together
                        const w = Math.max(VisualSizer.minW, VisualSizer.origW - dx);
                        VisualSizer.winX = VisualSizer.origX + (VisualSizer.origW - w);
                        VisualSizer.winW = w;
                    }
                    if (m & 4) {
                        VisualSizer.winH = Math.max(VisualSizer.minH, VisualSizer.origH + dy);
                    }
                    if (m & 1) {
                        const h = Math.max(VisualSizer.minH, VisualSizer.origH - dy);
                        VisualSizer.winY = VisualSizer.origY + (VisualSizer.origH - h);
                        VisualSizer.winH = h;
                    }
                    VisualSizer.commit();
                }
                onReleased: () => {
                    VisualSizer.dragging = false;
                    VisualSizer.syncGeometry();
                }
            }
        }

        // Edges (hit strips, tinted on hover)
        Handle { mode: 2; anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 14 }
        Handle { mode: 8; anchors.left: parent.left;  anchors.top: parent.top; anchors.bottom: parent.bottom; width: 14 }
        Handle { mode: 4; anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right; height: 14 }
        Handle { mode: 1; anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right; height: 14 }

        // Corners (on top of the edge strips)
        Handle { mode: 1 | 2; width: 22; height: 22; anchors.top: parent.top;    anchors.right: parent.right }
        Handle { mode: 1 | 8; width: 22; height: 22; anchors.top: parent.top;    anchors.left: parent.left }
        Handle { mode: 4 | 2; width: 22; height: 22; anchors.bottom: parent.bottom; anchors.right: parent.right }
        Handle { mode: 4 | 8; width: 22; height: 22; anchors.bottom: parent.bottom; anchors.left: parent.left }
    }
}
