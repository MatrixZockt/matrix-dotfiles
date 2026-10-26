import qs.modules.common.widgets
import qs.services

QuickToggleButton {
    id: root
    toggled: Idle.inhibit
    buttonIcon: "coffee"
    // Left click: toggle idle inhibition on/off
    onClicked: {
        Idle.toggleInhibit()
    }
    // Right click: open detailed view
    StyledToolTip {
        text: Translation.tr("Keep system awake | Left-click to toggle\nRight-click for details")
    }

}
