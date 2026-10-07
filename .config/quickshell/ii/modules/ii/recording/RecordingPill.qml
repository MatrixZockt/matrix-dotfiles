import QtQuick
import Quickshell
// GlobalShortcut is declared in Quickshell.Hyprland (it registers with the
// compositor's global shortcut registry) -- without this import it resolves
// to "GlobalShortcut is not a type" and the shell refuses to load.
import Quickshell.Hyprland
import Quickshell.Wayland
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

/**
 * The quick-record status pill -- the visible half of SUPER+R.
 *
 * A small capsule pinned to the top edge that only exists while it has
 * something to say: it blooms in when a recording starts and slides away
 * the moment it ends. Red pulsing dot, a REC label and the elapsed clock;
 * clicking it (or pressing SUPER+R again) stops the recording.
 *
 * It is deliberately SMALL -- a status, not a panel -- and deliberately
 * ABSENT when idle: the user asked for a bar that shows itself only while
 * recording.
 */
Scope {
    id: root

    // Touch the service so it exists from startup. A QML singleton is only
    // created on first use, and both its IPC handler and the recording state
    // live there -- without a real binding here, `qs -c ii ipc call recorder
    // state` answered "Target not found" until something happened to read it.
    readonly property bool serviceAlive: QuickRecord.recording

    // SUPER+R. Toggling is the whole interface: once to start, once to stop.
    // Declared here rather than in the service: GlobalShortcut is a shell
    // window-scope type and is not resolvable from a plain singleton (it took
    // the whole shell down with "GlobalShortcut is not a type").
    GlobalShortcut {
        name: "recorderToggle"
        description: "Quick record: start or stop the screen recording"
        onPressed: QuickRecord.toggle()
    }

    // Instantiated directly, not through a LazyLoader: the loader needs an
    // explicit `active`, and this window is cheap and unmapped unless a
    // recording is actually running (visible drives the surface).
    RecordingPillWindow {}

    component RecordingPillWindow: PanelWindow {
        id: win

        readonly property bool show: QuickRecord.recording
        // Kept mapped through the closing animation, then released.
        visible: root.show || win.hideAnim > 0.001
        screen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
        color: "transparent"
        exclusiveZone: -1
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "quickshell:recordingPill"
        WlrLayershell.layer: WlrLayer.Overlay

        // Top-RIGHT, just under the bar. The bar's own islands own the very
        // top edge (clock on the left, indicators on the right), so a pill
        // parked at 12,12 sat on top of the clock -- it tucks in below them
        // instead, which still reads as "top right\" and collides with nothing.
        anchors {
            top: true
            right: true
        }

        property real hideAnim: 0
        Behavior on hideAnim {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
        }
        // Track the target: 1 while shown, 0 while hidden. A Binding would
        // fight the Behavior; an explicit connection does not.
        Connections {
            target: win
            function onShowChanged() { win.hideAnim = win.show ? 1 : 0 }
        }

        margins {
            top: Appearance.sizes.barHeight + 10
            right: 14
        }

        // The surface sizes to its content's IMPLICIT size (an explicit width
        // alone leaves the window at the 100x100 default), so the pill states
        // both.
        implicitWidth: pill.width
        implicitHeight: pill.height

        Rectangle {
            id: pill
            implicitWidth: row.implicitWidth + 26
            implicitHeight: 34
            width: implicitWidth
            height: implicitHeight
            radius: 17
            color: ColorUtils.transparentize(Appearance.colors.colError, 0.86)
            border.width: 1
            border.color: ColorUtils.transparentize(Appearance.colors.colError, 0.45)

            opacity: win.hideAnim
            scale: 0.85 + 0.15 * win.hideAnim
            transformOrigin: Item.TopLeft

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: QuickRecord.stop()
            }

            Row {
                id: row
                anchors.centerIn: parent
                spacing: 7

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 9
                    height: 9
                    radius: 4.5
                    color: Appearance.colors.colError
                    SequentialAnimation on opacity {
                        running: win.show
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.25; duration: 650; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1.0; duration: 650; easing.type: Easing.InOutSine }
                    }
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: Translation.tr("REC")
                    font.pixelSize: Appearance.font.pixelSize.smallie
                    font.weight: Font.DemiBold
                    color: Appearance.colors.colOnLayer0
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: QuickRecord.clock(QuickRecord.elapsed)
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.smallie
                    color: Appearance.colors.colOnLayer0
                }
            }
        }
    }
}
