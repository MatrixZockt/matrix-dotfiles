import qs
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland

/**
 * The top-right signal card: a bare glyph and one short label.
 *
 * It is the clipboard's "Copied" card grown into a general channel, because a
 * second surface for one sentence was a second thing to keep in sync. The
 * desktop already says things in a few places -- the bar's line for events, the
 * corner card for sentences -- and this is the one for "that worked": a copy, a
 * cursor reclaim, anything whose whole message is two words and an icon.
 *
 * SIZED BY ITS CONTENT, not by a panel width. "Copied" is a small label, and a
 * 390px notification card with one word in the corner read as a leftover
 * notification rather than as feedback (2026-10-19). The width is the row's own
 * implicit width, so "Cursor reclaimed" and "Image copied" grow the card and the
 * window with it -- while the card stays anchored to the same top-right corner.
 *
 * Measured on this desktop: 77px for "Copied", 131px for "Image copied", 147px
 * for "Cursor reclaimed", at one 34px height. Padding and glyph are deliberately
 * one notch smaller than the notification card's: this is a chip that confirms
 * an action, not a card that asks to be read.
 *
 * ONE CARD, REPLACED, never queued: a second say() while it is up rewrites the
 * label and restarts the clock, exactly like CornerNotice. The countdown line
 * is the same clock drawn as a width, so it cannot disagree with the timer.
 *
 * No input at all: empty mask, and the window is only as large as the card, so
 * there is no invisible strip over the desktop eating clicks.
 */
Scope {
    id: root

    // The focused monitor, with the same startup fallback CornerNotice uses:
    // the compositor may not have named one yet, and `screen: null` would make
    // the window unmappable rather than merely misplaced.
    property var focusedScreen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name)
        ?? (Quickshell.screens.length > 0 ? Quickshell.screens[0] : null)

    // 0..1, how much of the card's countdown is left. Drawn as the bottom line's
    // width; the hide timer is what actually closes the card, so an animation
    // that is interrupted cannot leave the window up.
    property real progress: 1

    // The card's drop distance. Short on purpose: the arrival is a pop, not a
    // fall (see the notification card's own tuned numbers).
    readonly property real dropTravel: 12

    Connections {
        target: root
        function onFocusedScreenChanged() {
            toastWindow.screen = root.focusedScreen;
        }
    }

    // A new signal: reset the entrance instantly (no animation from wherever
    // the last one ended), then play them together.
    Connections {
        target: GlobalStates
        function onSignalToastSeqChanged() {
            showAnim.stop();
            hideAnim.stop();
            dropTranslate.y = -12;
            card.scale = 0.94;
            card.opacity = 0;
            root.progress = 1;
            showAnim.start();
            countdown.restart();
            dismissTimer.restart();
        }
        function onSignalToastVisibleChanged() {
            if (GlobalStates.signalToastVisible)
                return;
            showAnim.stop();
            countdown.stop();
            hideAnim.restart();
        }
    }

    // Entrance, one 140ms gesture: down from a short hop, a hard scale pop
    // (past 1 and back), and the fade. Same numbers as the notification
    // popup's own entrance so the two do not feel like different systems.
    ParallelAnimation {
        id: showAnim
        NumberAnimation {
            target: card
            property: "opacity"
            from: 0
            to: 1
            duration: 140
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: dropTranslate
            property: "y"
            from: -12
            to: 0
            duration: 140
            easing.type: Easing.BezierSpline
            easing.bezierCurve: [0.15, 1.75, 0.42, 1.0]
        }
        NumberAnimation {
            target: card
            property: "scale"
            from: 0.94
            to: 1
            duration: 140
            easing.type: Easing.OutBack
            easing.overshoot: 2.2
        }
    }

    ParallelAnimation {
        id: hideAnim
        NumberAnimation {
            target: card
            property: "opacity"
            to: 0
            duration: 140
            easing.type: Easing.InCubic
        }
        NumberAnimation {
            target: card
            property: "scale"
            to: 0.98
            duration: 140
            easing.type: Easing.InCubic
        }
    }

    NumberAnimation {
        id: countdown
        target: root
        property: "progress"
        from: 1
        to: 0
        duration: GlobalStates.signalToastDurationMs
        easing.type: Easing.Linear
    }

    Timer {
        id: dismissTimer
        interval: GlobalStates.signalToastDurationMs
        repeat: false
        onTriggered: GlobalStates.hideSignalToast()
    }

    PanelWindow {
        id: toastWindow
        color: "transparent"
        screen: root.focusedScreen

        WlrLayershell.namespace: "quickshell:signalToast"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        // NO `ExclusionMode.Ignore` here, and that is deliberate: that mode
        // places the surface at the raw screen edge, which put this card OVER
        // the top bar (measured y=12 with a 45px bar). Leaving the default in
        // place lets the compositor put it below the bar's exclusive zone, the
        // same way the notification popup is placed; `exclusiveZone: 0` still
        // means the card reserves no space of its own.
        exclusiveZone: 0

        // The same 12px inset the notification popup uses, so the two cards sit
        // on one line in the corner rather than near each other.
        //
        // `margins.top` is 0 and the 12px lives in the surface instead (see
        // dropTravel): the surface must be TALL enough for the card to start
        // above its resting spot, or the drop would be clipped by its own
        // window and the card's top corners would be shaved off on the way in.
        anchors {
            top: true
            right: true
        }
        margins.top: 0
        margins.right: 12

        // As tall/wide as the sentence needs -- never a fixed panel width --
        // plus the drop's travel above the resting place.
        implicitWidth: content.width
        implicitHeight: content.height + dropTravel

        // Not a target: the card is a picture, and the window is exactly its
        // size, so nothing invisible can swallow a click.
        mask: Region { item: null }

        // Keep the surface mapped while the fade-out runs; keying this on the
        // flag would tear the window down on the frame the fade began.
        visible: GlobalStates.signalToastVisible || card.opacity > 0.01

        Item {
            id: content
            width: card.implicitWidth
            height: card.implicitHeight

            // The resting position is one travel below the surface's top edge,
            // so the entrance can start at the edge itself and be fully drawn
            // the whole way down.
            y: dropTravel

            transform: Translate {
                id: dropTranslate
                y: 0
            }

            StyledRectangularShadow {
                target: card
                opacity: card.opacity
            }

            Rectangle {
                id: card
                anchors.fill: parent
                // The notification card's material, so this reads as the same
                // family and not as a new kind of overlay.
                color: Appearance.colors.colBackgroundSurfaceContainer
                radius: Appearance.rounding.normal
                clip: true
                opacity: 0
                scale: 1
                transformOrigin: Item.Center

                implicitWidth: Math.max(240, signalRow.implicitWidth + 40)
                implicitHeight: Math.max(50, signalRow.implicitHeight + 24)

                RowLayout {
                    id: signalRow
                    anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                    anchors { leftMargin: 16; rightMargin: 4 }
                    spacing: 12

                    // The bare glyph, the same contract as the notification
                    // signal face: no disc behind it, because this is not an
                    // app identifying itself. A small circle of empty space
                    // keeps the glyph from looking like a tab underline next to
                    // the word.
                    MaterialSymbol {
                        Layout.alignment: Qt.AlignVCenter
                        text: GlobalStates.signalToastIcon
                        iconSize: 26
                        color: Appearance.colors.colOnSurface
                    }

                    StyledText {
                        Layout.alignment: Qt.AlignVCenter
                        text: GlobalStates.signalToastText
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: Appearance.colors.colOnSurface
                    }
                }

                // The same countdown the notification popup draws, but INSET
                // rather than edge to edge: at this width the full-bleed line
                // ran into both rounded corners and read as an underline under
                // the word, which made a chip look like a tab. A hairline that
                // starts and ends inside the padding says "this is going away"
                // without becoming the loudest thing on the card.
                Rectangle {
                    height: 2
                    radius: 1
                    color: Appearance.colors.colPrimary
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.leftMargin: 8
                    anchors.bottomMargin: 4
                    width: Math.max(0, parent.width - 16) * root.progress
                }
            }
        }
    }
}
