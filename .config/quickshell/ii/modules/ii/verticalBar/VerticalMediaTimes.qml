// Vertical-media: the time column the sidebar's CompactMedia currently hides.
// Replaces the (now-removed) position/duration columns with one live row:
//   0:37 / 3:12   (position)/(duration), from MprisController directly.
import QtQuick
import Quickshell
import Quickshell.Services.Mpris

Item {
    id: root

    readonly property var player: MprisController.activePlayer

    property real positionMs: 0
    property real durationMs: 0

    property bool timeRowVisible: root.player !== null

    Timer {
        interval: 250
        repeat: true
        running: root.timeRowVisible
        onTriggered: {
            if (root.player) {
                root.positionMs = root.player.position * 1000
                root.durationMs = root.player.duration * 1000
            }
        }
    }

    function fmt(ms) {
        val = Math.max(0, parseInt(ms || 0))
        s = Math.floor(val / 1000)
        m = Math.floor(s / 60)
        sec = s % 60
        return "%1:%2".arg(m).arg(sec, 2, '0')
    }

    readonly property string positionText: root.timeRowVisible
        ? fmt(root.positionMs) : "--"
    readonly property string durationText: root.timeRowVisible
        ? fmt(root.durationMs) : "--"

    readonly property bool hasDuration: root.durationMs > 0
}
