import qs
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland

/** 
 * A short message in the bottom-left corner.
 * 
 * The desktop already has channels for "something changed" -- the bar's
 * indication line (services/StatusSignal.qml) blinks, the whole-screen tell
 * flashes a border -- but both of those are glanceable EVENTS: a colour, a
 * pulse, no words. This is the other half: one line of text, said once, in a
 * corner where nothing else lives, for the cases where the answer itself is a
 * sentence and the person who needs it is a script.
 * 
 * The first caller is the input failsafe (custom/scripts/fix-mouse.sh,
 * SUPER+CTRL+M): that key exists because "I am not sure the desktop heard me"
 * is a real state, and it used to answer only into /tmp/fix-mouse.log -- the
 * one place the person pressing it is not looking. So the script now says on
 * screen what it is doing and, a beat later, what it found. Same reasoning as
 * the bar's line: a key that stops working has to be visible, or it is
 * indistinguishable from a key that was never bound.
 * 
 * One card, one message, one owner. A second `say()` while it is up REPLACES
 * the text and restarts the clock rather than queueing -- a corner that stacks
 * four sentences while you look away is a notification list, and that already
 * exists. That is also what makes the two-call pattern in fix-mouse.sh work:
 * "Reclaiming cursor" on the way in, the outcome on the way out, one card.
 * 
 * Overlay layer with an empty mask: a picture, not a target. It has to render
 * over a fullscreen client (a stuck grab is exactly a state where a window
 * covers everything) and it must never eat the click that a broken input state
 * has just made precious. Same contract as ScreenFlash, StatusTell and
 * SleepNotice.
 * 
 * It lives in shell.qml beside ScreenFlash, not in a panel family: the input
 * failsafe is a desktop-level key, so its feedback must not vanish when the
 * panel family is switched. It is one window on the focused screen (the
 * copyToast precedent) -- a corner card repeated on every monitor is noise.
 */
Scope {
    id: root

    // The card's state. `showing` drives the fade; nothing outside decides
    // when it ends, so a caller that never calls hide() still gets retired.
    property bool showing: false
    property string message: ""

    // The focused monitor is the right screen, but at shell startup the
    // compositor may not have named one yet -- and the bare find() then yields
    // undefined, which Qt reports once per load as "Unable to assign
    // [undefined] to QuickshellScreenInfo*\" (seen in the journal on this
    // file's first reload). The first screen is the house's fallback for
    // exactly this (BarAnchoredPanel, RecordingPill, AppSearchOverlay), and
    // the Connections below corrects the window the moment the compositor
    // names a focused monitor -- which is why the wrong screen here is a
    // startup transient rather than a wrong-screen card.
    property var focusedScreen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name)
        ?? (Quickshell.screens.length > 0 ? Quickshell.screens[0] : null)

    // How long the message stays on screen, and how long the countdown line
    // inside the card takes to run out. ONE number for both, started together
    // in say(), so the line hitting zero and the message closing are the same
    // moment -- which is the contract the line makes with the reader: when it
    // is gone, the message goes.
    //
    // 1500ms (1.5s): asked for as "increase by 0.5s ... make the message
    // 1.5s" -- long enough to read one short sentence, short enough that the
    // corner stays quiet.
    property int displayTimeMs: 1500

    // 1 at arrival, running down to 0 over displayTimeMs. The status line
    // inside the card is this number drawn as a width -- not a second clock
    // with its own idea of the duration.
    property real statusProgress: 1

    // `say`, NOT `show`. The name is load-bearing: `show` is claimed by the
    // `qs ipc` command line itself, so a handler function called `show` resolves
    // to that instead of to this one -- `qs ipc call cornerNotice show \"...\"` answers
    // "the following argument was not expected" and the card never appears. Verified against two handlers this desktop already
    // has (`trayapps show cls`, `backgroundApps show id`): every function
    // called `show` is unreachable over IPC, every one that is not (park,
    // toggle, meterFace) takes its string argument fine.
    function say(text) {
        root.message = text ?? "";
        root.showing = true;
        // The card carries the sentence and the clock; `showing` is what the
        // IPC handler reports, so both still move together.
        noticeCard.show(root.message, "mouse", root.displayTimeMs);
        // The line and the clock are started together for the same
        // duration -- see displayTimeMs.
        root.statusProgress = 1;
        statusAnim.restart();
        holdTimer.restart();
    }

    function hide() {
        holdTimer.stop();
        statusAnim.stop();
        root.showing = false;
        noticeCard.hide();
    }

    // The countdown of the line itself, linear so its width is a fair
    // reading of the time left. holdTimer below owns the close -- both armed
    // with displayTimeMs and both restarted in say(), so they end on the same
    // frame; the timer stays the single owner of the close because it must
    // fire even where animations do not.
    NumberAnimation {
        id: statusAnim
        target: root
        property: "statusProgress"
        from: 1
        to: 0
        duration: root.displayTimeMs
        easing.type: Easing.Linear
    }

    // The close. The line runs out, the message closes -- see say().
    Timer {
        id: holdTimer
        interval: root.displayTimeMs
        repeat: false
        onTriggered: {
            root.showing = false;
            noticeCard.hide();
        }
    }

    IpcHandler {
        target: "cornerNotice"

        // qs -c ii ipc call cornerNotice say "Reclaiming cursor"
        function say(text: string): void {
            root.say(text);
        }

        function hide(): void {
            root.hide();
        }

        // Readable without pressing the key -- the same affordance the other
        // says-something surfaces keep, because a card nobody triggered and a
        // card that failed to load look identical in a screenshot of the rest
        // of the screen.
        function state(): string {
            return `showing=${root.showing} hold_ms=${holdTimer.interval} running=${holdTimer.running} message=${JSON.stringify(root.message)}`;
        }
    }

    // Always present, like ScreenFlash: the window is mapped only while the
    // card has any opacity left, and driving `visible` from the opacity (not
    // from `showing`) is what lets the fade-OUT play -- keying it on the flag
    // would tear the surface down on the frame the fade began.
    PanelWindow {
        id: noticeWindow
        color: "transparent"
        screen: root.focusedScreen

        Connections {
            target: root
            function onFocusedScreenChanged() {
                noticeWindow.screen = root.focusedScreen;
            }
        }

        WlrLayershell.namespace: "quickshell:cornerNotice"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        exclusiveZone: 0

        // Bottom-LEFT (asked for 2026-10-19). It was bottom-right, where the
        // clipboard toast already lives; the corner the eye checks for "the
        // desktop said something" is the left one, beside the launcher glow.
        // 
        // The margin accounts for the bar rather than assuming an edge:
        // whichever side the bar is on, the card keeps clear of its strip. The
        // GROUP form (`margins.left:`), never `margins: { ... }` -- assigning a
        // JS object to a value type is rejected at load and leaves the margins
        // at zero.
        anchors {
            bottom: true
            left: true
        }
        margins.left: Appearance.sizes.elevationMargin
        margins.top: Appearance.sizes.elevationMargin
        margins.right: Appearance.sizes.elevationMargin
        margins.bottom: Appearance.sizes.elevationMargin
            + (Config.options?.bar?.bottom === true ? Appearance.sizes.barHeight : 0)

        mask: Region { item: null }
        implicitWidth: noticeCard.implicitWidth + Appearance.sizes.elevationMargin * 2
        implicitHeight: noticeCard.implicitHeight + Appearance.sizes.elevationMargin * 2
        visible: noticeCard.opacity > 0.01

        StyledRectangularShadow {
            target: noticeCard
            opacity: noticeCard.opacity
        }

        // The bar's own material (see FeedbackCard): bar fill, bar hairline,
        // bar text colour, windowRounding corners. It replaced (1st) a plain
        // dark `colLayer0` box with a 1 px border and (2nd) a pale green card
        // borrowed from the restart confirmation -- both of which looked like
        // something other than this desktop. THE GREEN VERSION IS GONE.
        // reproduced in FeedbackCard): pale green, 12 px corners, one line of
        // dark text and a 5 px bar running out along the bottom. This replaced
        // a plain dark box with a 1 px hairline -- the "tooltip" look the
        // bottom-corner messages had.
        //
        // The mouse glyph stays: this card's first caller is the input failsafe
        // (SUPER+CTRL+M), and the glyph says WHICH kind of "something" it is
        // before the sentence is read.
        FeedbackCard {
            id: noticeCard
            anchors.centerIn: parent
            // The host owns the clock (holdTimer) so `hide()` still stops it
            // and the IPC state stays honest.
            autoHide: false
            lifetimeMs: root.displayTimeMs
            // Driven by say()/hide() rather than a `shown:` binding: show()
            // assigns the property, and assigning to a bound one would cut the
            // binding on the first message.
            onFinished: root.showing = false

            // Style note: FeedbackCard paints itself from the bar's own
            // tokens (colBarBackground fill, colBarBackgroundBorder hairline,
            // colOnLayer0 ink -- see FeedbackCard.qml), so there is NOTHING to
            // recolor here: `background`/`label` are not even properties of
            // the card (it is a Rectangle), and assigning them fails the load
            // of this whole file. What is set here is only the size.

            // Slightly larger popup for better readability
            implicitWidth: 280
            implicitHeight: 44

        // The status line, embedded IN the card: a hairline along its
        // bottom edge, EDGE TO EDGE (full card width, 2px -- asked for
        // 2026-10-19) that shrinks with the time left. Drawn from
        // statusProgress (one clock with holdTimer, see displayTimeMs),
        // so the frame the line runs out is the frame the message closes.
        // FeedbackCard clips, so its rounding crops the ends of the line.
        Rectangle {
            id: statusLine
            height: 2
            radius: 1
            color: Appearance.colors.colPrimary
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 5
            width: Math.max(0, parent.width * root.statusProgress)
        }
        }
    }
}
