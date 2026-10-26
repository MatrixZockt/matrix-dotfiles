// FilesWindowHost -- RETIRED, kept as the record of the morph contract.
//
// This was how the Files popup became a real window: the morph spawned this
// empty Window at the screen rect and pushed it fullscreen (same contract as
// SettingsWindowHost). It is doubly retired: the file manager became an ordinary
// window (filemanager.qml was a plain `Window`, so there was nothing to morph
// INTO), and then went back to being a bar-style POPUP -- today it is a layer
// surface with a card on a scrim, which cannot be a morph target at all. See
// filemanager.qml's header for the two measured failures of the window form that
// sent it back.
// Nothing references this file. It is left in the tree rather than deleted
// because it is the only written-down version of the pid-guarded fullscreen
// assertion (focus by pid, then fullscreen, retried to win the race with the
// map) that the settings window host still uses.
//
// --- original header ---------------------------------------------------
// FilesWindowHost -- the file manager as a REAL desktop window, for the
// popup → fullscreen morph. Same contract as SettingsWindowHost: the Window
// is created empty, spawned by the morph at the full-screen rect, asks the
// compositor for fullscreen (guarded by pid), and pinning/un-pin restores a
// sane floating size. Closing it ends the process.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import Quickshell
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions as CF

Scope {
    id: host

    property bool active: false
    property int wx: 100
    property int wy: 100
    property int ww: 920
    property int wh: 700
    property QtObject winRef: null

    function spawn(x, y, w, h) {
        host.wx = Math.round(x);
        host.wy = Math.round(y);
        host.ww = Math.round(w);
        host.wh = Math.round(h);
        host.active = true;
    }

    function closeWindow() {
        if (winRef) winRef.close();
    }

    LazyLoader {
        active: host.active

        Window {
            id: appWindow

            title: "Files"
            color: "transparent"
            visibility: Window.FullScreen
            visible: true
            x: host.wx
            y: host.wy
            width: host.ww
            height: host.wh
            minimumWidth: 640
            minimumHeight: 480

            Component.onCompleted: host.winRef = appWindow

            // Anchor-restore: leaving fullscreen hands back the physical
            // fullscreen buffer as floating geometry; pin back to this
            // screen's logical rect (SettingsWindowHost's measured fix).
            onVisibilityChanged: {
                if (visibility !== Window.FullScreen && visibility !== Window.Hidden
                    && visibility !== Window.Minimized) {
                    reassertTimer.restart();
                }
            }
            Timer {
                id: reassertTimer
                interval: 60
                repeat: true
                property int attempts: 0
                onTriggered: {
                    attempts += 1;
                    const s = appWindow.screen;
                    if (s) appWindow.setGeometry(0, 0, s.width, s.height);
                    if (attempts >= 5) stop();
                }
            }

            Rectangle {
                id: winBg
                anchors.fill: parent
                radius: Appearance.rounding.windowRounding
                color: Appearance.m3colors.m3background
                border.width: 1
                border.color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.6)
            }

            FileManagerContent {
                anchors.fill: parent
                onQuitRequested: appWindow.close()
            }

            // Same pid-guarded fullscreen assertion as SettingsWindowHost:
            // focus THIS window by pid, then fullscreen it, retried a few
            // times to win the race with the map.
            Timer {
                id: goFullscreen
                property int attempts: 0
                interval: 140
                repeat: true
                running: appWindow.visible
                onTriggered: {
                    attempts += 1;
                    Quickshell.execDetached(["hyprctl", "eval",
                        `local app = ${Quickshell.processId}\nhl.dispatch(hl.dsp.focus({ window = "pid:" .. app }))\nlocal w = hl.get_active_window()\nif w and w.pid == app and w.fullscreen == 0 then\n  if not w.floating then hl.dispatch(hl.dsp.window.float({ address = w.address })) end\n  local m = w.monitor\n  if m then\n    hl.dispatch(hl.dsp.window.resize({ x = m.width, y = m.height, address = w.address }))\n    hl.dispatch(hl.dsp.window.move({ x = m.x, y = m.y, address = w.address }))\n  end\n  hl.dispatch(hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }))\nend`]);
                    if (attempts >= 5) stop();
                }
            }

            onClosing: Qt.quit()
        }
    }
}
