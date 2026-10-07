import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

/**
 * The shell's popup apps for the top bar.
 *
 * Clicking a bar icon opens its quick menu as one small card floating in the
 * middle of the screen, with the desktop behind it frosted and gently dimmed.
 * Clicking anywhere on that backdrop (or pressing Escape) closes it again. The
 * card is deliberately modest -- a quick menu, not a full screen app -- and it
 * scrolls internally when its content is taller than the cap.
 *
 * Three things here are load-bearing, and each was a real bug before:
 *
 *   * The content alias lives on the ROOT object. Declared on the nested card
 *     Rectangle instead, it never became the component's default property, so
 *     subclasses' children were silently dropped and every popup came up empty.
 *   * The backdrop is a plain translucent scrim and Hyprland does the blurring
 *     (see the `quickshell:barPanel` layer rule in custom/rules.lua). The Qt
 *     ShaderEffect that used to blur a fullscreen wallpaper image segfaulted the
 *     shell in QQuickWindow::maybeUpdate() as the surface mapped and unmapped.
 *   * The screen falls back to the first of `Quickshell.screens`.
 *     `Quickshell.primaryScreen` does not exist in Quickshell 0.2.1, and
 *     referencing it left the window with no screen at all.
 */
Scope {
    id: root

    // Subclass content lands here; the card sizes itself from it.
    default property alias contentData: contentColumn.data

    property bool open: false
    signal opened()

    // The bar icon that opened the panel. Used only to pick the screen.
    property Item anchorItem
    // Content width subclasses want; the card adds its own padding.
    property real contentWidth: 320
    readonly property real padding: 14

    // The screen whose bar icon opened the panel, snapshotted at open time.
    property var cardScreen: null
    readonly property var fallbackScreen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null

    // The card never becomes a wall: at most ~60% of the screen height, so the
    // desktop stays visible around it and it always reads as a popup.
    function maxCardHeight(screenHeight) {
        return Math.max(220, Math.min(screenHeight * 0.60, 560));
    }

    function close() {
        root.open = false;
    }

    // Another popup grabbed focus (tray menu, clipboard, ...): close quietly.
    Connections {
        target: GlobalFocusGrab
        function onDismissed() {
            root.open = false;
        }
    }

    onOpenChanged: {
        if (!root.open)
            return;
        // Resolve the screen from the icon's window. Written out rather than
        // chained with `?.` because attached properties do not tolerate
        // optional chaining, and a throw here would leave the card with no
        // screen at all.
        var screen = null;
        try {
            const window = root.anchorItem ? root.anchorItem.QsWindow.window : null;
            screen = window ? window.screen : null;
        } catch (error) {
            screen = null;
        }
        root.cardScreen = screen ?? root.fallbackScreen;
        root.opened();
    }

    PanelWindow {
        id: panelRoot

        screen: root.cardScreen ?? root.fallbackScreen
        visible: root.open
        color: "transparent"
        exclusiveZone: 0
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "quickshell:barPanel"
        // Overlay: the same reason as the bar -- a fullscreen client renders
        // above Top-layer surfaces, and these popups open from the bar.
        WlrLayershell.layer: WlrLayer.Overlay
        // Exclusive while open so Escape always reaches the card. The panel is
        // modal anyway: a click on the backdrop is what closes it.
        WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        onVisibleChanged: {
            if (visible)
                GlobalFocusGrab.addDismissable(panelRoot);
            else
                GlobalFocusGrab.removeDismissable(panelRoot);
        }

        // ── The frosted backdrop ────────────────────────────────────────────
        // One motion, one scrim: the fade is a single NumberAnimation on the
        // scrim's opacity so the frost (compositor blur under it) and the card
        // appear and disappear together -- no two-stage materialize.
        Rectangle {
            id: backdrop
            anchors.fill: parent
            color: ColorUtils.transparentize(Appearance.colors.colLayer0, 0.55)
            opacity: root.open ? 1 : 0

            Behavior on opacity {
                NumberAnimation {
                    duration: 180
                    easing.type: Easing.OutCubic
                }
            }
        }

        // A click anywhere on the backdrop closes the app. Declared before the
        // card, so the card (a later sibling) sits on top of it.
        MouseArea {
            anchors.fill: parent
            onPressed: root.close()
        }

        // ── The floating card ───────────────────────────────────────────────
        Rectangle {
            id: card
            anchors.centerIn: parent
            width: Math.min(root.contentWidth + root.padding * 2, panelRoot.width - 48)
            height: Math.min(contentColumn.implicitHeight + root.padding * 2,
                root.maxCardHeight(panelRoot.height))
            color: Appearance.colors.colLayer0
            radius: Appearance.rounding.windowRounding
            border.width: 1
            border.color: Appearance.colors.colLayer0Border
            clip: true
            // The card pops in with the same emphasized motion the popup apps
            // use (popin to 96%), riding the same 180ms beat as the backdrop
            // fade -- one perceived motion, not a scrim snap + card pop.
            scale: root.open ? 1 : 0.96
            opacity: root.open ? 1 : 0

            Behavior on scale {
                NumberAnimation {
                    duration: 180
                    easing.type: Easing.OutCubic
                }
            }
            Behavior on opacity {
                NumberAnimation {
                    duration: 180
                    easing.type: Easing.OutCubic
                }
            }

            // Eat clicks that land on the card itself (its padding, scroll
            // gutters) so they are never mistaken for backdrop clicks.
            MouseArea {
                anchors.fill: parent
            }

            // StyledFlickable: kinetic wheel scrolling instead of raw steps.
            StyledFlickable {
                id: flick
                anchors.fill: parent
                anchors.margins: root.padding
                contentWidth: width
                contentHeight: contentColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: contentColumn
                    width: flick.width
                    spacing: 8
                }
            }
        }

        // Escape closes. A plain Item: it holds focus and swallows no mouse
        // input, so it can sit on top without stealing clicks from the card.
        // (Keys on the PanelWindow itself do not work -- the window is not an
        // Item, and Quickshell logs a warning for every attempt.)
        Item {
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    root.close();
                    event.accepted = true;
                }
            }
        }
    }
}
