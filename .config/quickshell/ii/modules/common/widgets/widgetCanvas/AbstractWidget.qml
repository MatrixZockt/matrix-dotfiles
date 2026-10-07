import QtQuick
import Quickshell
import qs
import qs.modules.common

/*
 * Widget to be placed on a WidgetCanvas
 */
MouseArea {
    id: root

    property alias animateXPos: xBehavior.enabled
    property alias animateYPos: yBehavior.enabled
    // Widgets are NOT freely draggable any more: the desktop widgets moving
    // under a stray click was a misfire waiting to happen. Dragging exists
    // only in the desktop's edit mode (the 4-finger tap on an empty desktop);
    // `draggable` remains the per-widget opt-in switch on top of that gate.
    readonly property bool editMode: GlobalStates.desktopEditMode
    property bool draggable: true
    drag.target: (draggable && editMode) ? root : undefined
    cursorShape: (draggable && editMode)
        ? (containsPress ? Qt.ClosedHandCursor : Qt.OpenHandCursor)
        : Qt.ArrowCursor

    // While the finger is down the move Behaviors must be OFF: their eased
    // animation trails the pointer, so the widget lags behind the drag and
    // catches up after release -- the "rubber" feel. With them disabled the
    // drag is 1:1, and they re-arm for the snap-back... nothing, because the
    // release commit below is a plain assignment.
    animateXPos: !drag.active
    animateYPos: !drag.active

    function center() {
        root.x = (root.parent.width - root.width) / 2
        root.y = (root.parent.height - root.height) / 2
    }

    Behavior on x {
        id: xBehavior
        animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
    }
    Behavior on y {
        id: yBehavior
        animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
    }
}
