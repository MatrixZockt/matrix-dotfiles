pragma ComponentBehavior: Bound
import qs
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

// Options toolbar
Toolbar {
    id: root

    // Use a synchronizer on these
    property var action
    property var selectionMode
    // Signals
    signal dismiss()

    ToolbarTabBar {
        id: tabBar
        tabButtonList: [
            {"icon": "activity_zone", "name": Translation.tr("Rect")},
            {"icon": "gesture", "name": Translation.tr("Circle")}
        ]
        currentIndex: root.selectionMode === RegionSelection.SelectionMode.RectCorners ? 0 : 1
        // Propagate the change OUTSIDE the currentIndex change notification.
        // Writing selectionMode synchronously inside the handler re-evaluated
        // the binding above while it was still on the stack, which logged
        // "Binding loop detected for property currentIndex" on every open of
        // the region selector. Qt.callLater() breaks the cycle; the equality
        // guard makes the deferred write a no-op when they already agree.
        onCurrentIndexChanged: Qt.callLater(() => {
            const want = currentIndex === 0 ? RegionSelection.SelectionMode.RectCorners : RegionSelection.SelectionMode.Circle;
            if (root.selectionMode !== want)
                root.selectionMode = want;
        })
    }
}
