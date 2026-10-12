import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

/**
 * "Going to sleep" -- the one tell in this shell that is not a value.
 *
 * Every other on-screen display here answers a question with a number: the
 * volume, the brightness, a delta. This one answers a question with no number
 * at all -- "is my machine dying, or is it leaving?" -- because a laptop that
 * simply goes black looks identical either way. It is raised by the sleep hook
 * (custom/scripts/before-sleep.sh) a beat before the panel is taken down, and
 * it is the reason that hook waits at all instead of cutting straight to black.
 *
 * IT IS DELIBERATELY NOT THE LOCK SCREEN. The lock is where a sleep ENDS, and
 * showing it on the way in was a real complaint: the login prompt on a lit
 * panel tells you nothing, and it is a screen you can start typing into on a
 * machine that is already leaving. This is the opposite: a wash with a label,
 * no input, no prompt, gone before anything is asked of you.
 *
 * Transient by construction. announce() arms a timer as well as showing, and
 * the hook also calls clear() explicitly once the panel is dark -- so a hook
 * that dies half-way cannot leave the label stuck on screen, and nothing has to
 * be remembered across the suspend. That is why this holds its own state
 * instead of a GlobalStates flag: a flag would survive the sleep, and the
 * machine would come back wearing it.
 *
 * Overlay layer, keyboardFocus None, empty mask: a picture, not a target --
 * the same contract as ScreenFlash and StatusTell. It must render over a
 * fullscreen client and it must never eat a click, a key or the cursor.
 * Variants over Quickshell.screens, so a second monitor announces with the
 * first rather than going dark on its own.
 *
 * Timer is intentionally longer than the dark step in the hook (see
 * defaultHoldMs): the label is still up when the panel is cut, and the timer
 * only ever fires on screen if the hook never got that far.
 */
Scope {
    id: root

    property bool announcing: false

    // Longer than the wait in before-sleep.sh, on purpose: this is the safety
    // net, not the schedule.
    readonly property int defaultHoldMs: 2500

    function announce(holdMs) {
        const ms = (typeof holdMs === "number" && holdMs > 0) ? holdMs : root.defaultHoldMs;
        root.announcing = true;
        holdTimer.interval = ms;
        holdTimer.restart();
    }

    function clear() {
        holdTimer.stop();
        root.announcing = false;
    }

    Timer {
        id: holdTimer
        interval: root.defaultHoldMs
        repeat: false
        onTriggered: root.announcing = false
    }

    IpcHandler {
        target: "sleepNotice"

        // qs -c ii ipc call sleepNotice announce
        function announce(): void {
            root.announce(root.defaultHoldMs);
        }

        // qs -c ii ipc call sleepNotice clear -- called by the hook with the
        // panel already dark, so the label is never seen disappearing.
        function clear(): void {
            root.clear();
        }

        // Diagnostic, and readable WITHOUT sleeping to check it -- the same
        // reason the lock has backdrop() and layout(): the label is on screen
        // for two seconds out of every suspension, so "did it work" is
        // otherwise a question you can only answer by catching it.
        function state(): string {
            return "announcing=" + String(root.announcing)
                + " hold_ms=" + String(holdTimer.interval)
                + " running=" + String(holdTimer.running);
        }
    }

    Variants {
        model: Quickshell.screens

        delegate: PanelWindow {
            id: noticeWindow
            required property var modelData

            screen: modelData
            color: "transparent"

            // Above everything, including a fullscreen client -- the same layer
            // the lock and the screen-wide alert use.
            WlrLayershell.namespace: "quickshell:sleepNotice"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            exclusionMode: ExclusionMode.Ignore

            // The empty input region this component's own docstring promises --
            // "a picture, not a target". It was documented but never set, and
            // the cost was total: this is a full-screen, always-mapped overlay,
            // so leaving the default input region in place swallowed EVERY
            // pointer event aimed at the windows underneath (the bar still
            // answered because it is stacked above this layer). ScreenFlash and
            // StatusTell, the two siblings with the same contract, both set it;
            // this one now matches them.
            mask: Region { item: null }

            anchors {
                top: true
                left: true
                right: true
                bottom: true
            }

            // The same wash the shell's own full-screen dialogs use (Polkit,
            // the task manager, a selection dialog): Material's scrim at half
            // strength, so the desktop is still legible underneath and the
            // screen reads as "covered" rather than "crashed".
            Rectangle {
                id: scrim
                anchors.fill: parent
                color: Appearance.colors.colScrim
                opacity: root.announcing ? 1 : 0
                Behavior on opacity {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }
            }

            Column {
                anchors.centerIn: parent
                spacing: 18
                opacity: scrim.opacity

                // White regardless of the theme, and that is not laziness: the
                // scrim is fixed black (m3scrim is), so there is no "on scrim"
                // colour role to read from the palette. Text that follows the
                // theme would be dark in a light theme, on black.
                MaterialSymbol {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "bedtime"
                    iconSize: Appearance.font.pixelSize.scaled(58)
                    color: "white"
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Translation.tr("Going to sleep")
                    font.pixelSize: Appearance.font.pixelSize.scaled(30)
                    font.weight: Font.DemiBold
                    color: "white"
                }
            }
        }
    }
}
