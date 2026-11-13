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

    // A picture instead of a bare glyph: a copied image arrives with its own
    // thumbnail and a download button, because "Image copied" alone gives no
    // way to keep the picture and no way to check that the right thing was
    // copied. The card takes input only in this case — see the mask below.
    readonly property bool hasImage: GlobalStates.signalToastImage.length > 0

    // What is left of the hold when the pointer is resting on the card. Hovering
    // freezes the countdown instead of letting it expire: the card is the only
    // place the picture can be saved from, so it must not disappear while
    // someone is aiming at the button. The clock resumes with the remainder it
    // had, not from the top.
    property real pausedRemaining: 300

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
            // The hold is per-card, and a previous card may have been paused
            // short by a hover: always start from the duration the caller asked
            // for, or a second copy would inherit the first one's remaining
            // milliseconds.
            countdown.stop();
            dismissTimer.stop();
            dismissTimer.interval = GlobalStates.signalToastDurationMs;
            countdown.restart();
            dismissTimer.restart();
            // A new signal while the pointer is already on the card: stay
            // frozen, so replacing the card does not yank it out from under the
            // cursor.
            if (hoverCard.hovered) {
                root.pausedRemaining = Math.max(300, GlobalStates.signalToastDurationMs);
                countdown.pause();
                dismissTimer.stop();
            }
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

        // The plain one-word card is not a target: it is a picture, and the
        // window is exactly its size, so nothing invisible may swallow a click.
        // With a picture on it the card becomes a control (save), so the mask
        // covers the card and nothing beyond it.
        //
        // A REGION NEEDS A REAL, TALL-ENOUGH ITEM AT CREATION. Swapping `item`
        // between `card` and `null` looks right and does not work: the window is
        // first created for a plain one-word toast, its input region is empty,
        // and it stays empty for the picture card that follows, so the pointer
        // never enters and the countdown never freezes (measured 2026-11-13 by
        // moving the cursor onto the card: no HoverHandler, card expired at 4 s).
        // The region therefore always comes from an item that exists, and that
        // item is sized to nothing unless there is a picture to save.
        mask: Region { item: inputArea }

        // Keep the surface mapped while the fade-out runs; keying this on the
        // flag would tear the window down on the frame the fade began.
        visible: GlobalStates.signalToastVisible || card.opacity > 0.01

        // The click target: the card while a picture is up, nothing at all
        // otherwise. Zero-sized keeps its region empty, so a plain "Copied" chip
        // still lets the desktop receive clicks underneath it.
        Item {
            id: inputArea
            // Same place as the card: `content` is the card's parent and sits one
            // drop travel below the surface's top edge.
            x: content.x + card.x
            y: content.y + card.y
            width: root.hasImage ? card.width : 0
            height: root.hasImage ? card.height : 0
        }

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
                    anchors { leftMargin: 16; rightMargin: 12 }
                    spacing: 12

                    // The thumbnail replaces the glyph when there is a picture:
                    // it says "your image" better than any icon can, and it lets
                    // the snip be checked before it is saved. Cropped, not
                    // stretched, and clipped to the card's own rounding so it
                    // reads as part of the card.
                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        visible: root.hasImage
                        width: 34
                        height: 34
                        radius: Appearance.rounding.small
                        color: Appearance.colors.colLayer2
                        clip: true

                        Image {
                            anchors.fill: parent
                            // Empty, not "file://", when there is no picture: an
                            // empty URL is a quiet no-image, while the bare
                            // scheme resolves to the root directory and warns
                            // once per binding evaluation.
                            source: root.hasImage ? "file://" + GlobalStates.signalToastImage : ""
                            sourceSize { width: 34; height: 34 }
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            cache: false
                        }
                    }

                    // The bare glyph, the same contract as the notification
                    // signal face: no disc behind it, because this is not an
                    // app identifying itself. A small circle of empty space
                    // keeps the glyph from looking like a tab underline next to
                    // the word.
                    MaterialSymbol {
                        Layout.alignment: Qt.AlignVCenter
                        visible: !root.hasImage
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

                    // Save: the one action a copied picture can need. It appears
                    // only for a picture and only while the card is up, so the
                    // chip stays a chip for every other signal.
                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        visible: root.hasImage
                        width: 30
                        height: 30
                        radius: 15
                        color: saveArea.containsMouse
                            ? Appearance.colors.colPrimaryContainer
                            : Appearance.colors.colLayer2

                        Behavior on color {
                            ColorAnimation { duration: 120 }
                        }

                        MaterialSymbol {
                            anchors.centerIn: parent
                            text: "download"
                            iconSize: 18
                            color: saveArea.containsMouse
                                ? Appearance.colors.colOnPrimaryContainer
                                : Appearance.colors.colOnSurface
                        }

                        MouseArea {
                            id: saveArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            // Save to Pictures/Screenshots and open the file
                            // manager on the result — never a silent copy to a
                            // path nobody looked at.
                            onClicked: GlobalStates.saveSignalToastImage()
                        }
                    }
                }

                // Freeze on hover: the picture can only be saved from here, so
                // the card must not vanish mid-reach. Leaving resumes the clock
                // with the time it had left.
                HoverHandler {
                    id: hoverCard
                    onHoveredChanged: {
                        if (hovered) {
                            root.pausedRemaining = Math.max(300,
                                GlobalStates.signalToastDurationMs * root.progress);
                            countdown.pause();
                            dismissTimer.stop();
                        } else {
                            dismissTimer.interval = root.pausedRemaining;
                            countdown.resume();
                            dismissTimer.restart();
                        }
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
