// Throwaway probe: render ClockWallpaper off the desktop into a PNG, so the
// page colour and the four shadows can be looked at without changing the
// wallpaper that is actually in use.
//
// A layer surface, not a FloatingWindow: the compositor TILES a toplevel into
// whatever column is free and the clock then lays itself out in 844x1010, which
// is not what the desktop looks like. Anchored to all four edges it is the
// screen, which is the shape the wallpaper has.
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.modules.common
import qs.modules.ii.background

ShellRoot {
    PanelWindow {
        id: win
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        color: "#282828"
        WlrLayershell.layer: WlrLayer.Bottom
        WlrLayershell.namespace: "quickshell:clockprobe"
        ClockWallpaper {
            id: cw
            anchors.fill: parent
        }
    }
    Timer {
        interval: 1200
        running: true
        onTriggered: {
            // Grabbed at the panel's device pixel ratio, so the dial's circles
            // and the shadow gradients are drawn at the resolution the file
            // wants rather than upscaled afterwards.
            const w = Math.round(cw.width), h = Math.round(cw.height);
            const s = win.screen ? win.screen.devicePixelRatio : 1;
            cw.grabToImage(function (result) {
                console.log("[clockprobe] size=" + w + "x" + h + " scale=" + s
                    + " saved=" + result.saveToFile("/tmp/clock-page.png"));
                Qt.quit();
            }, Qt.size(Math.round(w * s), Math.round(h * s)));
        }
    }
}
