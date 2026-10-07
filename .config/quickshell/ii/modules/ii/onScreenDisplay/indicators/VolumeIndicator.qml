import qs.services
import QtQuick
import qs.modules.ii.onScreenDisplay

/**
 * The volume OSD: which way the volume went, and how much.
 *
 * It used to print "Volume <percent>" and nothing else -- turning the volume
 * up and down looked identical. Now:
 *   · the icon reflects the LEVEL (mute / low / high), not just the presence
 *     of sound, so the shape alone tells you where you are;
 *   · the percentage carries a direction chip (arrow + step) that appears
 *     with the change and fades a beat later;
 *   · the number nudges and the bar eases, so a step is visible even when the
 *     bar is already near the top.
 */
OsdValueIndicator {
    id: osdValues

    readonly property real currentVolume: Audio.sink?.audio.volume ?? 0
    readonly property bool muted: Audio.sink?.audio.muted ?? false

    // The last step, kept only long enough to be read.
    //
    // `delta` is NOT redeclared here: OsdValueIndicator already owns it (it is
    // what draws the direction chip -- arrow + step, coloured by sign). The
    // old copy declared `property real delta: 0` AND then bound `delta:
    // osdValues.delta` a few lines below. Both target the same property, so the
    // object set it twice (QML: "Property value set multiple times", logged on
    // every volume change) and the second one made the binding
    // self-referential -- `delta` bound to `delta` -- so the chip never showed
    // a real step. Writing `osdValues.delta` below now just assigns the
    // inherited property directly, which is what the base reads.
    property real lastVolume: currentVolume

    onCurrentVolumeChanged: {
        const d = osdValues.currentVolume - osdValues.lastVolume;
        if (Math.abs(d) > 0.0005) {
            osdValues.delta = d;
            deltaClear.restart();
        }
        osdValues.lastVolume = osdValues.currentVolume;
    }
    Timer {
        id: deltaClear
        interval: 1100
        onTriggered: osdValues.delta = 0
    }

    value: osdValues.currentVolume
    // Level-aware glyph: off / silent / quiet / loud.
    icon: osdValues.muted ? "volume_off"
        : osdValues.currentVolume <= 0.001 ? "volume_mute"
        : osdValues.currentVolume < 0.5 ? "volume_down"
        : "volume_up"
    name: Translation.tr("Volume")
}
