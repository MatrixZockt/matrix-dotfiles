import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Wayland

/**
 * The whole-screen tell.
 *
 * Most status signals ride the bar's indication line -- but the bar is small
 * and the corner card can be missed. When GlobalStates raises a screen-wide
 * alert (the power failsafe flipping the machine to performance, or its
 * return), the entire screen answers with a double blink: a thin border
 * around the full screen that snaps on, off, on again, then fades away,
 * ~1.1 s total. One double-blink per alert -- a flare, not a lamp.
 *
 * A failed launch DOES come through here (since 2026-10-18, requested):
 * the 2px line and the island row only reach someone already looking at the
 * bar, and a failure has to reach eyes anywhere on the screen. The coupling
 * is still explicit -- showLoadingError() calls pulseScreenFlash on purpose,
 * rather than any failing state's rising edge repainting the whole screen --
 * so the line's own face changes can never flash it without being asked.
 * Everything else here (the power failsafe, its return) has no home on the
 * bar either.
 *
 * Overlay layer with an empty mask: it is a picture, not a target -- it must
 * render over everything, including fullscreen clients, and it must never eat
 * a click, a key or the cursor. Same contract as StatusTell.
 *
 * There is one of these per screen (Variants over Quickshell.screens); a
 * second monitor blinks in the same instant as the first.
 */
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: flashWindow

        required property var modelData
        screen: modelData
        color: "transparent"
        WlrLayershell.namespace: "quickshell:screenFlash"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        exclusiveZone: 0

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        // Border look: the COMPOSITOR's own edge, not a judgement call.
        //
        // This used to be 3px of four square bars, and it read as a box drawn
        // OVER the desktop rather than the screen's own edge -- reported twice
        // (2026-10-19: "still too thick and the border are not rounded to
        // match the hyprland rounded edges everywhere"). Hyprland on this
        // machine draws window borders at border_size = 1 and rounds them at
        // 12, and Appearance.rounding.windowRounding is kept equal to that
        // value on purpose (see hyprland/general.lua's note). So the screen
        // edge is those two numbers, and it is one rounded rectangle instead
        // of four bars -- four bars cannot have corners.
        readonly property int thickness: 1
        readonly property int radius: Appearance.rounding.windowRounding
        // The border's colour is part of the message: each alert carries a
        // kind, and the kind picks the colour (GlobalStates holds the
        // palette). The colour is latched when the blink starts so a second
        // alert with a different kind mid-fade swaps the frame cleanly.
        property color flashColor: GlobalStates.screenFlashColorError
        Connections {
            target: GlobalStates
            function onScreenFlashTickChanged() {
                // A new pulse always starts from the resting frame, whatever the
                // last held edge left behind.
                flashWindow.releasing = false;
                flashWindow.releaseP = 0;
                flashWindow.flashColor =
                    GlobalStates.screenFlashKind === GlobalStates.screenFireOrange ? GlobalStates.screenFlashColorFire
                    : GlobalStates.screenFlashKind === GlobalStates.screenFlashGreen ? GlobalStates.screenFlashColorGreen
                    : GlobalStates.screenFlashColorError;
                blinkAnim.restart();
            }
        }

        // 0 = invisible, 1 = fully lit. Driven only by blinkAnim below.
        property real borderOpacity: 0.0
        // ── Held, for a launch failure ────────────────────────────────────
        // The pulse above is a flare, and a flare says "look here". A message
        // that sits in the bar for twelve seconds needs an edge that sits
        // with it, not one that blinks twice and leaves it alone on screen.
        // So the border also has a HELD mode: flat, full, error-coloured, for
        // exactly as long as GlobalStates keeps the flag up. Nothing else
        // uses it, and it never starts a blink of its own.
        readonly property bool held: GlobalStates.screenFailureHold

        // ── Leaving the held state ─────────────────────────────────────────
        // A held edge that vanishes on the frame the flag drops is the one
        // abrupt thing left in this surface: the bar's sentence fades out over
        // 260 ms and the edge under it used to cut. `releaseP` walks 0 -> 1 over
        // that fade, and drives BOTH the opacity and a 3 px inward pull, so the
        // line recedes as it goes instead of blinking off. Three pixels, not
        // twelve: the border is allowed to settle inward, not to retreat. The
        // curve is OutQuad over 360 ms rather than OutCubic over 300 -- a cubic
        // spends its first third almost at full brightness and then drops, which
        // reads as a cut that was a frame late rather than as a fade.
        property real releaseP: 0
        // An explicit flag, not `releaseAnim.running`: the window's `visible`
        // binding is re-evaluated in the same breath as `held`, and reading an
        // animation's `running` there is a race this lost once -- the surface
        // unmapped before the fade could start, and the edge simply vanished.
        property bool releasing: false
        onHeldChanged: {
            if (held) {
                releaseAnim.stop();
                releasing = false;
                releaseP = 0;
                blinkAnim.stop();
                flashWindow.flashColor = GlobalStates.screenFlashColorError;
            } else {
                releasing = true;
                releaseAnim.restart();
            }
        }
        NumberAnimation {
            id: releaseAnim
            target: flashWindow
            property: "releaseP"
            from: 0
            to: 1
            duration: 360
            easing.type: Easing.OutQuad
            // Back to the resting frame once the fade is over, so the next
            // pulse starts at the screen edge and not 3 px inside it.
            onFinished: {
                flashWindow.releasing = false;
                flashWindow.releaseP = 0;
            }
        }
        visible: borderOpacity > 0.0 || held || releasing

        // One blink per alert, and the alert has to ASK.
        //
        // `pulseScreenFlash` is STILL the only way in -- never a state's
        // rising edge, which is what used to repaint all 2560x1600 of screen
        // from the line's internal failure clock, unasked. What changed
        // (2026-10-18) is that a failed launch now asks on purpose:
        // `showLoadingError` calls pulseScreenFlash itself, so one deliberate
        // flare lands together with the bar's line and the card that says
        // "Couldn't open X" -- three surfaces saying one thing, all raised by
        // the same function instead of by one property changing underneath.
        // The kind it carries picks the colour, latched above.

        SequentialAnimation {
            id: blinkAnim

            // Blink 1: snap on, hold a beat, snap off.
            NumberAnimation {
                target: flashWindow
                property: "borderOpacity"
                to: 1
                duration: 90
            }
            PauseAnimation { duration: 160 }
            NumberAnimation {
                target: flashWindow
                property: "borderOpacity"
                to: 0
                duration: 90
            }
            // The beat between the two blinks. Short enough to read as one
            // event said twice, long enough that the off-gap is unmistakable.
            PauseAnimation { duration: 110 }
            // Blink 2: snap on, hold, then fade all the way out.
            NumberAnimation {
                target: flashWindow
                property: "borderOpacity"
                to: 1
                duration: 90
            }
            PauseAnimation { duration: 200 }
            NumberAnimation {
                target: flashWindow
                property: "borderOpacity"
                to: 0
                duration: 380
                easing.type: Easing.OutQuad
            }
        }

        // Empty input region: the window covers the screen but passes every
        // event through. Without this, one blink per alert would eat one
        // click per alert.
        mask: Region { item: null }

        // One rounded stroke hugging the screen edge -- the same shape and
        // weight Hyprland gives a window, scaled to the screen.
        //
        // Inset by half the stroke so the line sits ON the edge rather than
        // just inside it (a 1px stroke centred on the boundary paints one
        // pixel at 0 and is clipped cleanly by the surface). `margins` rather
        // than `border` alone is what keeps the outer edge exactly at the
        // screen: the border is drawn inside the rectangle's own bounds.
        Rectangle {
            id: frame
            anchors.fill: parent
            // Inset by half the stroke, plus the release pull: as the held edge
            // lets go, the whole line walks 4 px inward with the fade.
            anchors.margins: flashWindow.thickness / 2
                + (flashWindow.releasing ? flashWindow.releaseP * 3 : 0)
            color: "transparent"
            radius: flashWindow.radius
            border.width: flashWindow.thickness
            border.color: flashWindow.flashColor
            // The held edge is fully lit; the pulse keeps its own envelope, and
            // the release hands the opacity over to the fade.
            opacity: flashWindow.held ? 1
                : (flashWindow.releasing ? 1 - flashWindow.releaseP : flashWindow.borderOpacity)
        }
    }
}
