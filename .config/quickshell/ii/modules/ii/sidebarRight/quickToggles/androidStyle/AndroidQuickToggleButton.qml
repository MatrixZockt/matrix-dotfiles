import QtQuick
import QtQuick.Layouts
import qs.services
import qs.modules.common
import qs.modules.common.models.quickToggles
import qs.modules.common.functions
import qs.modules.common.widgets

GroupButton {
    id: root
    
    // Info to be passed to by repeater
    required property int buttonIndex
    required property var buttonData
    required property bool expandedSize
    required property real baseCellWidth
    required property real baseCellHeight
    required property real cellSpacing
    required property int cellSize

    // Signals
    signal openMenu()

    // Edit-mode plumbing: the panel owns the config mutations (copy-assign
    // through setToggles; raw in-place splice/push on the config list is
    // what made the grid duplicate and lose icons). panelRef additionally
    // serves the drag-and-drop slot mapping.
    property var editOps: null
    property var panelRef: null

    // Declared in specific toggles
    property QuickToggleModel toggleModel
    property string name: toggleModel?.name ?? ""
    property string statusText: (toggleModel?.hasStatusText) ? (toggleModel?.statusText || (toggled ? Translation.tr("On") : Translation.tr("Off"))) : ""
    property string tooltipText: toggleModel?.tooltipText ?? ""
    property string buttonIcon: toggleModel?.icon ?? "close"
    property bool available: toggleModel?.available ?? true
    toggled: toggleModel?.toggled ?? false
    property var mainAction: toggleModel?.mainAction ?? null
    altAction: toggleModel?.hasMenu ? (() => root.openMenu()) : (toggleModel?.altAction ?? null)

    // Edit mode state
    property bool editMode: false

    // Sizing shenanigans
    baseWidth: root.baseCellWidth * cellSize + cellSpacing * (cellSize - 1)
    baseHeight: root.baseCellHeight
    enableImplicitWidthAnimation: !editMode && root.mouseArea.containsMouse
    enableImplicitHeightAnimation: !editMode && root.mouseArea.containsMouse
    Behavior on baseWidth {
        animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
    }
    Behavior on baseHeight {
        animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
    }
    opacity: 0
    Component.onCompleted: {
        opacity = 1
    }
    Behavior on opacity {
        animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
    }

    enabled: available || editMode
    padding: 6
    horizontalPadding: padding
    verticalPadding: padding

    colBackground: Appearance.colors.colLayer2
    colBackgroundToggled: (altAction && expandedSize) ? Appearance.colors.colLayer2 : Appearance.colors.colPrimary
    colBackgroundToggledHover: (altAction && expandedSize) ? Appearance.colors.colLayer2Hover : Appearance.colors.colPrimaryHover
    colBackgroundToggledActive: (altAction && expandedSize) ? Appearance.colors.colLayer2Active : Appearance.colors.colPrimaryActive
    buttonRadius: toggled ? Appearance.rounding.large : height / 2
    buttonRadiusPressed: Appearance.rounding.normal
    property color colText: (toggled && !(altAction && expandedSize) && enabled) ? Appearance.colors.colOnPrimary : ColorUtils.transparentize(Appearance.colors.colOnLayer2, enabled ? 0 : 0.7)
    property color colIcon: expandedSize ? ((root.toggled) ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer3) : colText

    onClicked: {
        if (root.expandedSize && root.altAction) root.altAction();
        else root.mainAction();
    }

    contentItem: RowLayout {
        id: contentItem
        spacing: 4
        anchors {
            centerIn: root.expandedSize ? undefined : parent
            fill: root.expandedSize ? parent : undefined
            leftMargin: root.horizontalPadding
            rightMargin: root.horizontalPadding
        }

        // Icon
        MouseArea {
            id: iconMouseArea
            hoverEnabled: true
            acceptedButtons: (root.expandedSize && root.altAction) ? Qt.LeftButton : Qt.NoButton
            Layout.alignment: Qt.AlignHCenter
            Layout.fillHeight: true
            Layout.topMargin: root.verticalPadding
            Layout.bottomMargin: root.verticalPadding
            implicitHeight: iconBackground.implicitHeight
            implicitWidth: iconBackground.implicitWidth
            cursorShape: Qt.PointingHandCursor

            onClicked: root.mainAction()

            Rectangle {
                id: iconBackground
                anchors.fill: parent
                implicitWidth: height
                radius: root.radius - root.verticalPadding
                color: {
                    const baseColor = root.toggled ? Appearance.colors.colPrimary : Appearance.colors.colLayer3
                    const transparentizeAmount = (root.altAction && root.expandedSize) ? 0 : 1
                    return ColorUtils.transparentize(baseColor, transparentizeAmount)
                }

                Behavior on radius {
                    animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
                }
                Behavior on color {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }

                MaterialSymbol {
                    anchors.centerIn: parent
                    fill: root.toggled ? 1 : 0
                    iconSize: root.expandedSize ? 22 : 24
                    color: root.colIcon
                    text: root.buttonIcon
                }

                // State layer
                Loader {
                    anchors.fill: parent
                    active: (root.expandedSize && root.altAction)
                    sourceComponent: Rectangle {
                        radius: iconBackground.radius
                        color: ColorUtils.transparentize(root.colIcon, iconMouseArea.containsPress ? 0.88 : iconMouseArea.containsMouse ? 0.95 : 1)
                        Behavior on color {
                            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                        }
                    }
                }
            }
        }

        // Text column for expanded size
        Loader {
            Layout.alignment: Qt.AlignVCenter
            Layout.fillWidth: true
            visible: root.expandedSize
            active: visible
            sourceComponent: Column {
                spacing: -2

                StyledText {
                    anchors {
                        left: parent.left
                        right: parent.right
                    }
                    font.pixelSize: Appearance.font.pixelSize.smallie
                    font.weight: 600
                    color: root.colText
                    elide: Text.ElideRight
                    text: root.name
                }

                StyledText {
                    visible: root.statusText
                    anchors {
                        left: parent.left
                        right: parent.right
                    }
                    font {
                        pixelSize: Appearance.font.pixelSize.smaller
                        weight: 100
                    }
                    color: root.colText
                    elide: Text.ElideRight
                    text: root.statusText
                }
            }
        }
    }

    MouseArea { // Blocking MouseArea for edit interactions
        id: editModeInteraction
        visible: root.editMode
        anchors.fill: parent
        cursorShape: dragActive ? Qt.ClosedHandCursor : Qt.PointingHandCursor
        hoverEnabled: true
        acceptedButtons: Qt.AllButtons

        // ── Drag to reorder (edit mode) ──────────────────────────────
        // Press-and-hold-free: a drag starts the moment the pointer moves
        // past a small threshold while held, and the ghost follows it. On
        // release the panel inserts this toggle at the slot under the
        // pointer (moveTypeTo handles the copy-assign + dedupe).
        property bool dragActive: false
        property point pressPoint
        property bool dragArmed: false

        Drag.active: dragActive
        Drag.dragType: Drag.Automatic
        Drag.supportedActions: Qt.MoveAction
        Drag.mimeData: { "text/plain": root.buttonData?.type ?? "" }
        Drag.keys: ["quicktoggle"]

        onPressed: (event) => {
            if (event.button === Qt.LeftButton) {
                pressPoint = Qt.point(event.x, event.y);
                dragArmed = true;
            } else if (event.button === Qt.RightButton) {
                root.editOps?.toggleSize(root.buttonIndex, root.buttonData.type);
            }
        }
        onPositionChanged: (event) => {
            if (!dragArmed || dragActive) return;
            const dx = event.x - pressPoint.x;
            const dy = event.y - pressPoint.y;
            if (dx * dx + dy * dy > 14 * 14) {
                dragActive = true;
                root.panelRef?.dragStarted(root.buttonData.type);
            }
        }
        onReleased: (event) => {
            if (event.button !== Qt.LeftButton) return;
            dragArmed = false;
            const wasDragging = dragActive;
            dragActive = false;
            if (wasDragging) {
                // Land it: map to the panel, ask which slot we are over.
                const target = root.panelRef?.dropTargetFor(
                    root.mapToItem(null, event.x, event.y), root.buttonData.type);
                if (target !== undefined && target !== null && target >= 0)
                    root.panelRef?.moveTypeTo(root.buttonData.type, target);
                root.panelRef?.dragEnded();
                return;
            }
            root.editOps?.toggleEnabled(root.buttonIndex, root.buttonData.type);
        }
        onPressAndHold: (event) => { // size toggle, for touch
            root.editOps?.toggleSize(root.buttonIndex, root.buttonData.type);
        }
        onWheel: (event) => {
            if (event.angleDelta.y < 0) { // Move to right
                root.editOps?.movePositionBy(root.buttonIndex, root.buttonData.type, 1);
            } else if (event.angleDelta.y > 0) { // Move to left
                root.editOps?.movePositionBy(root.buttonIndex, root.buttonData.type, -1);
            }
            event.accepted = true;
        }
    }

    StyledToolTip {
        extraVisibleCondition: root.tooltipText !== ""
        text: root.tooltipText
    }
}
