import Quickshell.Hyprland
import qs.services
import qs.modules.common
import qs.modules.common.functions
import Qt5Compat.GraphicalEffects
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets

DockButton {
    id: root
    property var appToplevel
    property var appListRoot
    property int lastFocused: -1
    // Sized to sit inside the pill with the same amount of air on every side: the
    // dock derives it from the pill height (`dock.height - 24`) and the row's gaps
    // from the same number, so the icon, the dots underneath it and the pill's
    // padding cannot drift apart.
    property real iconSize: 24
    property real countDotWidth: 9
    property real countDotHeight: 3
    property bool appIsActive: appToplevel.toplevels.find(t => (t.activated == true)) !== undefined

    readonly property bool isSeparator: appToplevel.appId === "SEPARATOR"
    property var desktopEntry: DesktopEntries.heuristicLookup(appToplevel.appId)
    enabled: !isSeparator
    // The dock passes its own `delegateWidth` in; this is the fallback, and it uses
    // the same convention (a couple of pixels of slop on each side of the icon).
    implicitWidth: isSeparator ? 1 : root.iconSize + 4

    // --- Reordering ----------------------------------------------------------
    // How far from its own slot this icon should be drawn right now. The list keeps
    // owning `x`; this only shifts the drawing, so the icon can follow the pointer
    // while the slots underneath it shuffle. `pointerGrabX` is where inside the icon
    // the press landed, so the icon does not jump on the first move.
    property real dragOffsetX: 0
    property real pointerGrabX: 0
    readonly property bool dragging: root.dragged

    transform: Translate {
        x: root.dragOffsetX
    }
    z: root.dragging ? 2 : 0
    scale: root.dragging ? 1.08 : 1
    Behavior on scale {
        animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
    }

    dragStartAction: () => {
        root.pointerGrabX = root.dragStartX;
        root.appListRoot.reordering = true;
    }
    dragMoveAction: (mouse) => {
        // `mouse.x` is the pointer in this button's own coordinates, which stay put
        // while the drawing is translated -- so the icon moves with the pointer, and
        // the same number works no matter where the list has shuffled it to.
        root.dragOffsetX = mouse.x - root.pointerGrabX;
        const slot = root.appListRoot.indexAt(root.x + mouse.x);
        if (slot >= 0)
            TaskbarApps.moveTo(root.appToplevel.appId, slot);
    }
    dragEndAction: () => {
        root.dragOffsetX = 0;
        root.appListRoot.reordering = false;
    }

    Connections {
        target: DesktopEntries

        function onApplicationsChanged() {
            const __t = Date.now();
            root.desktopEntry = DesktopEntries.heuristicLookup(appToplevel.appId);
            const __d = Date.now() - __t;
            if (__d > 15) console.log("[slow] dockLookup " + __d + "ms");
        }
    }

    Loader {
        active: isSeparator
        anchors {
            fill: parent
            topMargin: 14
            bottomMargin: 14
        }
        sourceComponent: DockSeparator {}
    }

    // Hover for the window-preview popup. This has to be a passive handler and not
    // a MouseArea: a MouseArea covering the button swallows the press, which
    // silently ate every click and drag on an icon whose app had a window open --
    // only the pinned-but-closed entries still reacted.
    HoverHandler {
        id: hoverHandler
        enabled: appToplevel.toplevels.length > 0

        onHoveredChanged: {
            if (hovered) {
                if (root.dragging)
                    return;
                appListRoot.lastHoveredButton = root
                appListRoot.buttonHovered = true
                lastFocused = appToplevel.toplevels.length - 1
            } else if (appListRoot.lastHoveredButton === root) {
                appListRoot.buttonHovered = false
            }
        }
    }

    onClicked: {
        if (appToplevel.toplevels.length === 0) {
            // Choke point: if a window exists without being tracked by the
            // dock's app list (class mismatch), the redirect still catches it.
            GlobalStates.launchEntry(root.desktopEntry);
            return;
        }
        lastFocused = (lastFocused + 1) % appToplevel.toplevels.length
        appToplevel.toplevels[lastFocused].activate()
    }

    middleClickAction: () => {
        GlobalStates.launchEntry(root.desktopEntry);
    }

    // Right-click: the button's properties menu (pin/unpin, new window,
    // close all windows) instead of the old silent pin-toggle -- the toggle
    // is still there, as the menu's first item, and the menu is the same
    // species the task manager's rows and the launcher's results use.
    altAction: (event) => {
        dockAppMenu.targetApp = root.appToplevel;
        dockAppMenu.anchor.item = root;
        dockAppMenu.anchor.edges = Edges.Top;
        dockAppMenu.anchor.gravity = Edges.Top;
        dockAppMenu.visible = true;
    }

    PopupWindow {
        id: dockAppMenu
        property var targetApp: null
        visible: false
        implicitWidth: 200
        implicitHeight: dockMenuColumn.implicitHeight + 12
        color: "transparent"
        anchor {
            window: root.QsWindow.window
            adjustment: PopupAdjustment.Flip | PopupAdjustment.SlideX | PopupAdjustment.SlideY
        }

        Rectangle {
            anchors.fill: parent
            radius: Appearance.rounding.normal
            color: Appearance.colors.colLayer1
            border.width: 1
            border.color: Appearance.colors.colLayer0Border

            ColumnLayout {
                id: dockMenuColumn
                anchors.fill: parent
                anchors.margins: 6
                spacing: 0

                component DockMenuRow: RippleButton {
                    id: dockMenuAction
                    required property string iconGlyph
                    required property string label
                    property color labelColor: Appearance.colors.colOnLayer1
                    property var run: null
                    Layout.fillWidth: true
                    implicitHeight: 32
                    buttonRadius: Appearance.rounding.verysmall
                    colBackground: "transparent"
                    colBackgroundHover: Appearance.colors.colLayer1Hover
                    colRipple: Appearance.colors.colLayer1Active
                    onClicked: {
                        dockAppMenu.visible = false;
                        if (dockMenuAction.run) dockMenuAction.run();
                    }
                    contentItem: RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 8
                        MaterialSymbol {
                            text: dockMenuAction.iconGlyph
                            iconSize: 15
                            color: dockMenuAction.labelColor
                        }
                        StyledText {
                            text: dockMenuAction.label
                            font.pixelSize: Appearance.font.pixelSize.small
                            color: dockMenuAction.labelColor
                        }
                    }
                }

                DockMenuRow {
                    iconGlyph: TaskbarApps.isPinned(dockAppMenu.targetApp?.appId ?? "") ? "pin_off" : "pin"
                    label: TaskbarApps.isPinned(dockAppMenu.targetApp?.appId ?? "")
                        ? Translation.tr("Unpin") : Translation.tr("Pin to dock")
                    run: () => TaskbarApps.togglePin(dockAppMenu.targetApp?.appId ?? "")
                }
                DockMenuRow {
                    iconGlyph: "add_circle"
                    label: Translation.tr("New window")
                    visible: (dockAppMenu.targetApp?.toplevels?.length ?? 0) > 0
                    run: () => GlobalStates.launchEntry(dockAppMenu.targetApp ? root.desktopEntry : null)
                }
                DockMenuRow {
                    iconGlyph: "open_with"
                    label: Translation.tr("Resize…")
                    visible: (dockAppMenu.targetApp?.toplevels?.length ?? 0) > 0
                    run: () => {
                        // Prefer the app's focused window; else its first.
                        const wins = dockAppMenu.targetApp?.toplevels ?? [];
                        const focused = Hyprland.activeToplevel?.HyprlandToplevel?.address;
                        const pick = wins.find(w => w?.HyprlandToplevel?.address === focused) ?? wins[0];
                        const addr = pick?.HyprlandToplevel?.address;
                        if (addr)
                            VisualSizer.arm(`0x${addr}`);
                    }
                }
                DockMenuRow {
                    iconGlyph: "close"
                    label: Translation.tr("Close all windows")
                    labelColor: Appearance.colors.colError
                    visible: (dockAppMenu.targetApp?.toplevels?.length ?? 0) > 0
                    run: () => {
                        // Close through Hyprland by address: QML Toplevel has
                        // no close() in this build (the overview and the task
                        // view close windows the same way). The address lives
                        // on the Hyprland extension object (see
                        // HyprlandData.clientForToplevel).
                        const wins = dockAppMenu.targetApp?.toplevels ?? [];
                        for (let i = 0; i < wins.length; i++) {
                            const addr = wins[i]?.HyprlandToplevel?.address;
                            if (addr)
                                Hyprland.dispatch(`hl.dsp.window.close({ window = "address:0x${addr}" })`);
                        }
                    }
                }
            }
        }
    }

    contentItem: Loader {
        active: !isSeparator
        sourceComponent: Item {
            // Fills the button rather than sizing itself from its children, which is
            // what made the icon's width depend on the icon itself before.
            anchors.fill: parent

            Loader {
                id: iconImageLoader
                anchors.horizontalCenter: parent.horizontalCenter
                // Centred in the pill, so the air above the icon is `rowPadding`
                // and the dots below it use the matching air underneath.
                anchors.verticalCenter: parent.verticalCenter
                active: !root.isSeparator
                sourceComponent: IconImage {
                    source: Quickshell.iconPath(AppSearch.guessIcon(appToplevel.appId), Quickshell.shellPath("assets/icons/fluent/app-generic.svg"))
                    implicitSize: root.iconSize
                }
            }

            Loader {
                active: Config.options.dock.monochromeIcons
                anchors.fill: iconImageLoader
                sourceComponent: Item {
                    Desaturate {
                        id: desaturatedIcon
                        visible: false // There's already color overlay
                        anchors.fill: parent
                        source: iconImageLoader
                        desaturation: 0.8
                    }
                    ColorOverlay {
                        anchors.fill: desaturatedIcon
                        source: desaturatedIcon
                        color: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.9)
                    }
                }
            }

            RowLayout {
                spacing: 3
                anchors {
                    top: iconImageLoader.bottom
                    topMargin: 2
                    horizontalCenter: parent.horizontalCenter
                }
                Repeater {
                    model: Math.min(appToplevel.toplevels.length, 3)
                    delegate: Rectangle {
                        required property int index
                        radius: Appearance.rounding.full
                        implicitWidth: (appToplevel.toplevels.length <= 3) ?
                            root.countDotWidth : root.countDotHeight // Circles when too many
                        implicitHeight: root.countDotHeight
                        color: appIsActive ? Appearance.colors.colPrimary : ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.4)
                    }
                }
            }
        }
    }
}
