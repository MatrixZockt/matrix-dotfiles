import qs
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

/**
 * The bottom-left notice card: what the desktop has to SAY about something it
 * was asked to do.
 *
 * It used to carry the wait as well -- "Opening X", a turning glyph in a corner
 * -- and that half is gone. A wait has nothing to read, and the corner is the
 * one part of the screen nobody is watching while they wait for a window; the
 * wait is drawn under the middle island instead (see BarContent's loading line
 * and GlobalStates.loadingLine). What is left here are the two things that are
 * sentences rather than waits, and both need a place to be READ:
 *
 *   * a failure -- "Couldn't open X" -- a still error glyph, the error colour
 *     and an error-tinted edge, so it reads as wrong from across the room
 *     before a word of it has been read;
 *   * a notice -- "X is already open", "Release to close" -- a check glyph, a
 *     calm accent edge, and its own short clock.
 *
 * It is global rather than per-screen on purpose: there is one of these, it is
 * only ever visible while GlobalStates.loadingCardVisible is set, and it takes
 * no input at all so it can never get in the way of what it is announcing.
 */
Scope {
    PanelWindow {
        id: window

        visible: GlobalStates.loadingCardVisible
        color: "transparent"
        WlrLayershell.namespace: "quickshell:loadingIndicator"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        exclusiveZone: 0

        anchors {
            bottom: true
            left: true
        }
        margins {
            bottom: Appearance.sizes.elevationMargin * 2
            left: Appearance.sizes.elevationMargin * 2
        }

        implicitWidth: card.implicitWidth
        implicitHeight: card.implicitHeight

        // An empty mask: the window is a picture, not a target. Without this it
        // would still swallow clicks in the corner it floats over.
        mask: Region {
            item: null
        }

        Rectangle {
            id: card
            anchors.fill: parent
            implicitWidth: rowLayout.implicitWidth + 26
            implicitHeight: rowLayout.implicitHeight + 16
            radius: Appearance.rounding.normal
            color: Appearance.colors.colBackgroundSurfaceContainer
            border.width: 1
            border.color: GlobalStates.loadingFailed
                ? Appearance.colors.colError
                : (GlobalStates.loadingInfo
                    ? Appearance.colors.colPrimary
                    : Appearance.colors.colOutlineVariant)

            // Fade in rather than blink in.
            opacity: GlobalStates.loadingCardVisible ? 1 : 0
            Behavior on opacity {
                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
            }

            RowLayout {
                id: rowLayout
                anchors.centerIn: parent
                spacing: 10

                MaterialSymbol {
                    id: glyph
                    Layout.alignment: Qt.AlignVCenter
                    // "error" is the exclamation-in-a-circle glyph: this is not a
                    // program being busy, it is a program that is not coming.
                    // "check_circle" marks the notice face -- "already open", the
                    // release-to-close hint -- neither of which alarms.
                    // "progress_activity" marks a plain wait -- something is
                    // starting and has not arrived yet.
                    text: GlobalStates.loadingFailed ? "error"
                        : (GlobalStates.loadingInfo ? "check_circle" : "check_circle")
                    iconSize: 20
                    color: GlobalStates.loadingFailed
                        ? Appearance.colors.colError
                        : Appearance.colors.colOnLayer1
                }

                StyledText {
                    Layout.alignment: Qt.AlignVCenter
                    text: GlobalStates.loadingText
                    color: GlobalStates.loadingFailed
                        ? Appearance.colors.colError
                        : Appearance.colors.colOnLayer1
                    font.pixelSize: Appearance.font.pixelSize.small
                }
            }
        }
    }
}
