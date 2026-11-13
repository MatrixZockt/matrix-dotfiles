pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Services.SystemTray
import Quickshell.Widgets
import Qt5Compat.GraphicalEffects
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

MouseArea {
    id: root
    required property SystemTrayItem item
    property bool targetMenuOpen: false
    // The size of the hit target. 20 on the bar; the tray's dropdown panel
    // asks for more, because that row is a list to be pressed rather than a
    // strip of glyphs to be glanced at. The icon inside scales with the
    // parent, so a bigger cell is a bigger icon and a bigger target, and
    // neither needs a second code path.
    property int cellSize: 20
    // The icon's own size, 0 for "fill the cell". The cell is deliberately
    // larger than the icon: the difference is what the hover plate fills,
    // and a plate that exactly covers the icon reads as the icon changing
    // colour rather than as a button being pressed.
    property int iconSize: 0
    // Whether hovering draws a plate behind the icon. On inside a card, so
    // a grid of them reads as a grid of controls. Off on the bar, where the
    // tray sits among a row of other glyphs and a plate behind one of them
    // would be a stray shape with nothing to divide.
    property bool showHoverPlate: false

    // ── Reopening an app that hides itself ──────────────────────────────────
    // `item.activate()` re-raises the app's window exactly where it last was,
    // so after asking the app to come back the window is pulled to the
    // workspace the user is actually on (TrayApps.bringToActive). It has to
    // POLL: activate() is fire-and-forget, and an Electron app needs to
    // un-hide and commit a frame first.
    //
    // The clock lives HERE, one Timer per tray icon, scoped to the thing that
    // was clicked -- NOT in the TrayApps singleton. A version with the timer
    // and its counters in the singleton drove the shell's main thread to 100%
    // of a core (measured: 106% with it, 21% without, same restart twice).
    property string revealCls: ""
    property int revealTries: 0
    property bool revealMoved: false

    Timer {
        id: revealTimer
        interval: 120
        repeat: true
        running: false
        onTriggered: {
            const st = TrayApps.bringToActive(root.revealCls);
            root.revealTries += 1;
            if (st.moved)
                root.revealMoved = true;
            // A deadline, plus an early stop once the window has been moved
            // and stays put -- a menu-only tray daemon owns no window and must
            // not be polled forever.
            if (root.revealTries >= 25 || (root.revealMoved && !st.moved && st.found > 0))
                revealTimer.running = false;
        }
    }

    // The window class of this item, when the app behind it is one the
    // shell has parked. Non-empty means "there is a window in the tray and
    // this icon is the way back to it".
    //
    // It is needed because `item.activate()` cannot do the job: it asks the
    // APP to show itself, and the app has no idea its window was moved to a
    // special workspace -- so it raises whatever it likes and the parked
    // window stays in the vault. With minimize-to-tray on for an app that
    // registers its own icon (not just the shell's Thunderbird), clicking
    // that icon has to restore the window the same way the shell's own icon
    // does.
    readonly property string parkedClass: {
        const cls = TrayApps.classForTrayItem(root.item);
        return cls !== "" && TrayApps.isHidden(cls) ? cls : "";
    }

    signal menuOpened(qsWindow: var)
    signal menuClosed(qsWindow: var)
    // A LEFT press on this icon. The tray card listens: a press inside the tray
    // means the user has moved on from whatever menu was out, so the card
    // dismisses that menu without dismissing itself (SysTray.dismissOpenMenu).
    //
    // NOT emitted for the right button, and that is the load-bearing half: the
    // right button is the menu's own toggle, so right-clicking the icon that
    // owns the open menu has to close it -- if this fired first, the toggle
    // below would always find `menu.active` false and re-open instead.
    signal itemPressed()

    hoverEnabled: true
    // Both buttons, always. Right click opens the app's own menu, which is
    // also what a two-finger tap becomes: libinput reports a two-finger tap
    // as a right-button press, so this one branch covers the gesture without
    // the item having to know it came from a touchpad.
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    implicitWidth: cellSize
    implicitHeight: cellSize
    onPressed: (event) => {
        switch (event.button) {
        case Qt.LeftButton:
            root.itemPressed();
            // Parked window first: restoring it IS the user's click. With
            // nothing parked, the app's own activate() is still the right
            // answer -- for most tray items it is the only thing there is --
            // and the poll above then moves the window to this workspace.
            if (root.parkedClass !== "") {
                TrayApps.show(root.parkedClass);
            } else {
                root.revealCls = TrayApps.classForTrayItem(root.item);
                item.activate();
                root.revealTries = 0;
                root.revealMoved = false;
                if (root.revealCls !== "")
                    revealTimer.restart();
            }
            break;
        case Qt.RightButton:
            if (item.hasMenu)
                if (menu.active && menu.item && typeof menu.item.close === "function")
                    menu.item.close();
                else 
                    menu.open();
            break;
        }
        event.accepted = true;
    }
    onEntered: {
        tooltip.text = TrayService.getTooltipForItem(root.item);
    }

    Loader {
        id: menu
        function open() {
            menu.active = true;
        }
        active: false
        sourceComponent: SysTrayMenu {
            Component.onCompleted: this.open();
            trayItemMenuHandle: root.item.menu
            trayItemId: root.item.id
            anchor {
                window: root.QsWindow.window
                item: root
                gravity: Config.options.bar.vertical
                    ? (Config.options.bar.bottom ? Edges.Left : Edges.Right)
                    : (Config.options.bar.bottom ? Edges.Top : Edges.Bottom)
                edges: Config.options.bar.vertical
                    ? (Config.options.bar.bottom ? Edges.Left : Edges.Right)
                    : (Config.options.bar.bottom ? Edges.Top : Edges.Bottom)
                // Slide/flip back on screen instead of clipping when the
                // menu would cross a screen edge.
                adjustment: PopupAdjustment.Flip | PopupAdjustment.SlideX | PopupAdjustment.SlideY
            }
            onMenuOpened: (window) => root.menuOpened(window);
            onMenuClosed: {
                // The window, so the tray can drop a hold that belongs to
                // THIS menu and not to a menu that replaced it.
                root.menuClosed(menu.item);
                menu.active = false;
            }
        }
    }

    // The hover plate, UNDER the icon. Sized to the cell rather than to
    // the icon so the highlight reads as a target and not as the glyph
    // changing colour.
    //
    // A ROUNDED SQUARE, not a circle. `radius: rounding.full` made this a
    // 34px disc behind a 20px glyph, and a disc that much larger than what
    // it surrounds stops reading as a state layer and starts reading as a
    // button -- a grey coin dropped behind the icon. The card it sits in
    // uses `rounding.small`, so a same-family radius here is the shape
    // language the container is already using, and the highlight reads as
    // part of the card rather than as an object floating in it.
    //
    // The 1px inset is what keeps that true: flush to the cell edges, the
    // plate's corners line up with the gap between cells and the eye sees a
    // grid of boxes. Inset, it is unambiguously a highlight ON the cell.
    Rectangle {
        id: hoverPlate
        anchors.fill: parent
        anchors.margins: 1
        radius: Appearance.rounding.normal
        color: Appearance.colors.colLayer1Hover
        // A hairline in the on-layer colour, at the same 14% weight the
        // fill uses. This is the "outlined" half of the modern treatment:
        // the edge of the target is stated rather than implied by a blob of
        // fill, which is what lets the fill itself stay this quiet.
        border.width: 1
        border.color: ColorUtils.transparentize(Appearance.colors.colOnLayer2, 0.86)
        // Faded, NOT toggled. `visible:` snapped the plate on and off, so
        // hover had a hard leading edge and no trailing one -- the plate
        // appeared instantly and vanished instantly, which read as a flicker
        // rather than as a transition. Opacity gives it both ends.
        opacity: root.showHoverPlate && root.containsMouse ? 1 : 0
        Behavior on opacity {
            // Asymmetric on purpose. `elementMoveEnter` is the long decel
            // curve and `elementMoveExit` the short accel one -- the pair
            // the rest of the shell's motion is built from, so the plate
            // arrives and leaves on the same timing as everything else it
            // sits beside. A single symmetric duration (what the 120ms
            // OutCubic below was) is the reason this felt cheap: state
            // layers that take as long to leave as to arrive read as lag.
            animation: (root.containsMouse
                ? Appearance.animation.elementMoveEnter
                : Appearance.animation.elementMoveExit).numberAnimation.createObject(this)
        }
    }

    IconImage {
        id: trayIcon
        visible: !Config.options.tray.monochromeIcons
        source: root.item.icon
        anchors.centerIn: parent
        width: root.iconSize > 0 ? root.iconSize : parent.width
        height: width
        // NOT `sourceSize` here. `IconImage` already binds its backing
        // `Image.sourceSize` to `min(width, height)`, so the artwork is
        // decoded at the size it is drawn -- setting it again from outside
        // is at best redundant, and at worst (it is not a property the
        // component re-exposes) a hard load error that takes the whole
        // config down. `mipmap` is the part that is ours to set.
        //
        // THE ARTWORK IS DRAWN AS THE APP PUBLISHED IT, AT CELL SIZE, WITH
        // NOTHING TRIMMED AND NOTHING CLIPPED. That was tried and reverted
        // twice, and both attempts are worth remembering:
        //
        //   * Trimming the transparent margin off the file (ImageMagick,
        //     cached per icon) made file-backed icons fill their cell --
        //     and did nothing at all for the app that prompted it, because
        //     Discord hands the tray a LIVE PIXMAP (`image://qspixmap/...`),
        //     which has no file to trim.
        //   * Drawing a pixmap 1.34x and clipping the cell to the middle
        //     does remove the margin, geometrically -- and it CUTS the
        //     icon. Discord's tray art is a 24x24 canvas with the glyph
        //     18x18 at +3+3, but the badge variants run to the very edge,
        //     so the clip amputates them. "Revert it, the spacing before
        //     was fine" is the correct verdict on that trade: a tray icon
        //     that is complete but a little smaller beats one that is
        //     bigger and has pieces of it missing.
        //
        // An app that pads its canvas is an app drawing the icon the
        // freedesktop spec asks for. Every tray shows the canvas, so every
        // icon in every tray has this property, and the padding is
        // consistent within an app and across versions of it -- which makes
        // it a look, not a fault.
        mipmap: true

        // A swell, but a much smaller one: 1.18 -> 1.06.
        //
        // 18% is a lot of travel on a 20px glyph -- 3.6px of growth, which
        // is most of the gap between cells, so hovering two icons in a row
        // made the row appear to shuffle. At 1.06 the icon lifts by about a
        // pixel: enough to register as responsive, not enough to move
        // anything. The plate above now carries the hover, so the glyph does
        // not also have to.
        //
        // On a transform, so the cell never re-lays-out under the pointer.
        transform: Scale {
            xScale: root.containsMouse ? 1.06 : 1
            yScale: root.containsMouse ? 1.06 : 1
            // Same enter/exit pair as the plate, for the same reason, and so
            // the two never disagree: an icon still growing while its plate
            // has already started fading is what makes a hover look broken.
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
    }

    Loader {
        active: Config.options.tray.monochromeIcons
        anchors.fill: trayIcon
        sourceComponent: Item {
            Desaturate {
                id: desaturatedIcon
                visible: false // There's already color overlay
                anchors.fill: parent
                source: trayIcon
                desaturation: 0.8 // 1.0 means fully grayscale
            }
            ColorOverlay {
                anchors.fill: desaturatedIcon
                source: desaturatedIcon
                color: ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.9)
            }
        }
    }

    PopupToolTip {
        id: tooltip
        extraVisibleCondition: root.containsMouse
        alternativeVisibleCondition: extraVisibleCondition
        anchorEdges: (!Config.options.bar.bottom && !Config.options.bar.vertical) ? Edges.Bottom : Edges.Top
    }

}
