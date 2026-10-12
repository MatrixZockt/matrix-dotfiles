import QtQuick
import qs.services
import qs.modules.waffle.looks

OSDValue {
    id: root
    iconName: WIcons.volumeIcon
    // The shell's fraction, so the bar is full at 100% instead of half-filled
    // at an honest full volume (the sink's own value is a fraction of two).
    value: Audio.currentVolume()

    Connections {
        // Listen to volume changes
        target: Audio.sink?.audio ?? null
        function onVolumeChanged() {
            if (Audio.ready)
                root.timer.restart();
        }
        function onMutedChanged() {
            if (Audio.ready)
                root.timer.restart();
        }
    }
}
