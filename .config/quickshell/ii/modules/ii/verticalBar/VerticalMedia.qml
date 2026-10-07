import QtQuick
import Quickshell
import Quickshell.Services.Mpris

Item {
    id: root
    property real positionMs: 0
    property real durationMs: 0

    readonly property var activePlayer: MprisController.activePlayer

    Timer {
        interval: 250
        repeat: true
        running: root.activePlayer !== null
        onTriggered: {
            root.positionMs = root.activePlayer.position * 1000
            root.durationMs = root.activePlayer.duration * 1000
        }
    }

    function fmt(ms) {
        val = parseInt(ms)
        if (isNaN(val) || val < 0) val = 0
        s = Math.floor(val / 1000)
        m = Math.floor(s / 60)
        s = s % 60
        return "%1:%2".arg(m).arg(s, 2, '0')
    }
}
