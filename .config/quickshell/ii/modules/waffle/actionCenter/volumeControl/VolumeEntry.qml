import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Pipewire
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.modules.waffle.looks
import qs.modules.waffle.actionCenter

RowLayout {
    id: root
    required property PwNode node
    property alias icon: iconButton.iconName
    property alias monochrome: iconButton.monochrome
    monochrome: false

    PwObjectTracker { // Necessary for useful info to be present in 'node'
        objects: [root.node]
    }

    WPanelIconButton {
        id: iconButton
        iconName: WIcons.audioAppIcon(root.node)
        onClicked: root.node.audio.muted = !root.node?.audio.muted

        FluentIcon {
            id: muteIcon
            visible: root.node?.audio.muted ?? false
            anchors {
                bottom: parent.bottom
                right: parent.right
                margins: -1
            }
            implicitSize: 16
            icon: "speaker-mute"
        }

        WToolTip {
            extraVisibleCondition: iconButton.shouldShowTooltip
            text: Audio.appNodeDisplayName(root.node)
        }
    }

    // Through the audio service, because this one row serves TWO scales: the
    // System row is handed the default sink (the shell's 0..1, 100% = the loud
    // end), every row below it an application's stream (PipeWire's own, 100% =
    // its unity gain). Reading `node.audio.volume` here made the System slider
    // reach only half the range -- its right end was the sink's 1.0, which the
    // shell calls 50% -- and its tooltip said "200%" at the loud end.
    WSlider {
        Layout.fillWidth: true
        Layout.rightMargin: 10
        value: Audio.nodeVolumeFraction(root.node)
        onMoved: Audio.setNodeVolumeFraction(root.node, value)
    }
}
