pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Widgets
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.modules.waffle.looks
import qs.services

// A tray icon the shell owns, for an app that registers none.
//
// This is SysTrayItem with the SystemTrayItem swapped for a plain
// registry entry: it cannot BE SysTrayItem, because that one declares
// `required property SystemTrayItem item`, a type the registry entry
// is not. Everything else -- the cell sizes, the swell on hover, the
// tooltip, the press behaviour -- is kept equivalent on purpose: two
// tray icons that handle a press differently is worse than one that is
// slightly duplicated.
//
// Press: left toggles (show/park/launch via TrayApps.toggle), right
// opens the app menu.

MouseArea {
    id: root
    // The registry entry this icon stands for.
    required property var entry
    property int cellSize: 20
    property int iconSize: 0
    property bool showHoverPlate: false

    signal menuOpened(qsWindow: var)
    signal menuClosed()

    // Recomputed from the window list, never stored: this icon has to be
    // right after the close gesture parks the window, and after the shell
    // restarts, and neither of those goes through this file.
    readonly property bool running: TrayApps.isRunning(root.entry.cls)
    readonly property bool appHidden: TrayApps.isHidden(root.entry.cls)
    // Cold start or a restore in flight for THIS app. The icon dims and
    // a ring turns over it, so the click reads as "working on it".
    readonly property bool busy: TrayApps.busyFor(root.entry.cls)

    // Circle reveal on first appear, matching the waffle bar's TrayButton
    // (TrayButton.qml): the icon scales up from 0 with Looks.transition.enter
    // the moment this item is created -- app launch, shell restart, or a
    // restore from the tray -- so it pops in rather than just appearing.
    property real iconScale: 0
    Component.onCompleted: {
        root.iconScale = 1
    }
    Behavior on iconScale {
        animation: Looks.transition.enter.createObject(this)
    }

    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    implicitWidth: cellSize
    implicitHeight: cellSize

    onPressed: (event) => {
        if (event.button === Qt.LeftButton) {
            // Not item.activate(): there is no app behind this icon, the
            // shell is. The shell decides: show it, park it, or start it.
            TrayApps.toggle(root.entry.cls);
        } else if (event.button === Qt.RightButton) {
            if (menu.active && menu.item && typeof menu.item.close === "function")
                menu.item.close();
            else
                menu.open();
        }
        event.accepted = true;
    }

    onEntered: {
        var name = root.entry.name;
        if (root.appHidden) {
            tooltip.text = name + " - hidden, click to show";
        } else if (root.running) {
            tooltip.text = name + " - click to hide";
        } else {
            tooltip.text = name + " - not running";
        }
    }

    Loader {
        id: menu
        function open() {
            menu.active = true;
        }
        active: false
        sourceComponent: SysTrayAppMenu {
            Component.onCompleted: this.open();
            entry: root.entry
            appHidden: root.appHidden
            anchor {
                window: root.QsWindow.window
                item: root
                gravity: Config.options.bar.vertical
                    ? (Config.options.bar.bottom ? Edges.Left : Edges.Right)
                    : (Config.options.bar.bottom ? Edges.Top : Edges.Bottom)
                edges: Config.options.bar.vertical
                    ? (Config.options.bar.bottom ? Edges.Left : Edges.Right)
                    : (Config.options.bar.bottom ? Edges.Top : Edges.Bottom)
                adjustment: PopupAdjustment.Flip | PopupAdjustment.SlideX | PopupAdjustment.SlideY
            }
            onMenuOpened: (window) => root.menuOpened(window);
            onMenuClosed: {
                root.menuClosed();
                menu.active = false;
            }
        }
    }

    // Same rounded-square plate as SysTrayItem: 1px inset, hairline
    // border, asymmetric enter/exit timing.
    Rectangle {
        id: hoverPlate
        anchors.fill: parent
        anchors.margins: 1
        radius: Appearance.rounding.normal
        color: Appearance.colors.colLayer1Hover
        border.width: 1
        border.color: ColorUtils.transparentize(Appearance.colors.colOnLayer2, 0.86)
        opacity: root.showHoverPlate && root.containsMouse ? 1 : 0
        Behavior on opacity {
            animation: (root.containsMouse
                ? Appearance.animation.elementMoveEnter
                : Appearance.animation.elementMoveExit).numberAnimation.createObject(this)
        }
    }

    IconImage {
        id: trayIcon
        source: TrayApps.iconFor(root.entry)
        anchors.centerIn: parent
        width: root.iconSize > 0 ? root.iconSize : parent.width
        height: width
        mipmap: true

        transform: Scale {
            // 1.06, matching SysTrayItem. iconScale is the 0->1 circle
            // reveal from the root object; multiplied in so the pop-in and
            // the hover swell compose instead of fighting.
            xScale: root.iconScale * (root.containsMouse ? 1.06 : 1)
            yScale: root.iconScale * (root.containsMouse ? 1.06 : 1)
            Behavior on xScale {
                animation: (root.containsMouse
                    ? Appearance.animation.elementMoveEnter
                    : Appearance.animation.elementMoveExit).numberAnimation.createObject(this)
            }
            Behavior on yScale {
                animation: (root.containsMouse
                    ? Appearance.animation.elementMoveEnter
                    : Appearance.animation.elementMoveExit).numberAnimation.createObject(this)
            }
        }

        // Faded, not hidden, while the app is coming back: the icon never
        // disappears and reappears.
        opacity: root.busy ? 0.35 : 1
        Behavior on opacity {
            animation: (root.busy
                ? Appearance.animation.elementMoveExit
                : Appearance.animation.elementMoveEnter).numberAnimation.createObject(this)
        }
    }

    // The ring that turns while the app is on its way back.
    Rectangle {
        id: busyRing
        anchors.centerIn: parent
        width: root.iconSize > 0 ? root.iconSize : parent.width
        height: width
        radius: Appearance.rounding.full
        color: "transparent"
        border.width: 1.5
        border.color: Appearance.colors.colOnLayer2
        opacity: root.busy ? 1 : 0
        visible: opacity > 0.01
        Behavior on opacity {
            animation: (root.busy
                ? Appearance.animation.elementMoveEnter
                : Appearance.animation.elementMoveExit).numberAnimation.createObject(this)
        }
        RotationAnimator on rotation {
            running: root.busy
            loops: Animation.Infinite
            duration: 900
            from: 0
            to: 360
        }
    }

    PopupToolTip {
        id: tooltip
        extraVisibleCondition: root.containsMouse
        alternativeVisibleCondition: extraVisibleCondition
        anchorEdges: (!Config.options.bar.bottom && !Config.options.bar.vertical) ? Edges.Bottom : Edges.Top
    }
}
