import QtQuick
import qs
import qs.modules.common

MouseArea {
    id: root

    // It did turn out we need something here, eventually: the canvas is the
    // desktop itself, so it is the natural "clicked empty space" surface.
    // Desktop edit mode (4-finger tap on an empty desktop) ends when the user
    // clicks anywhere that is not a widget -- the same grammar as a popover
    // closing on an outside press. The widgets are children of this area, so
    // a press on a widget is delivered to the widget and never reaches here;
    // only genuinely empty desktop does.
    onClicked: mouse => {
        if (GlobalStates.desktopEditMode) {
            GlobalStates.exitDesktopEditMode();
            mouse.accepted = true;
        }
    }
}
