import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland

/**
 * The transcript rescue chip: a small pill in the bottom-RIGHT corner.
 *
 * A dictation is typed at the caret and, until now, existed nowhere else -- no
 * history (dictations are never saved), no copy, nothing to retrieve if the
 * caret was not in a text box and the paste went nowhere. This chip is that
 * safety net: for a few seconds after each dictation it says a transcript is
 * there, with a Countdown line showing how long it has left and a Copy button
 * that puts it on the clipboard (sensitive, so cliphist does not keep it).
 *
 * The sentence itself is NOT drawn. It is the least readable thing on screen
 * anyway (a few words, often landing in a box you cannot see), it made the card
 * 400px wide for no gain, and a failed dictation is rescued by Copy -- not by
 * reading a one-line elision of it.
 *
 * THE SAME BOX AS THE COPY TOAST. The top-right "Copied" chip (SignalToast) is
 * this desktop's size for "a short thing happened": 240x50, windowRounding,
 * colBackgroundSurfaceContainer, a 26px glyph beside one small line, and a 2px
 * countdown inset 8px from the corners. A dictation notice is the same kind of
 * message, so it is drawn at the same size rather than as its own invention --
 * 44px and its own padding made it read as a different species of notification.
 *
 * WHEN THE CARD GOES, THE TEXT GOES WITH IT. The countdown is not decoration:
 * the script's file is deleted at the end of the fade, and the card's own copy
 * is cleared with it. That is the promise the rest of the dictation stack
 * already keeps -- nothing is stored -- while still leaving a window long
 * enough to rescue a sentence that never reached a prompt box.
 *
 * Reads the file the dictation script writes, by polling it, for the same
 * reason Dictation.qml polls its status: the script renames a temp file over
 * the target, and a watched path would keep pointing at the old inode.
 */
Scope {
    id: root

    readonly property string transcriptPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp")
        + "/ii-dictate/transcript.json"

    // How long the sentence stays. Long enough to glance at it and click Copy
    // if it did not land, short enough to never feel like a notification that
    // needs dismissing by hand.
    readonly property int holdMs: 3500
    readonly property int fadeMs: 150

    property string text: ""
    property string copyPayload: ""
    property real lastStamp: 0
    // The stamp of the dictation the card is currently showing, as opposed to
    // lastStamp, which moves on as soon as a newer file is seen. This is what
    // the wipe is checked against.
    property real shownStamp: 0
    property bool shown: false
    property bool copied: false
    property real progress: 1
    // Hovering holds the card open: 3.5 seconds is enough to notice a sentence
    // that failed, not enough to aim at it. While the pointer is on the card the
    // countdown stops where it is, and it picks up from there when the pointer
    // leaves -- so hovering neither rushes it nor keeps it forever.
    property bool hovered: false
    property int remainingMs: holdMs

    property var focusedScreen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name)
        ?? (Quickshell.screens.length > 0 ? Quickshell.screens[0] : null)

    Connections {
        target: root
        function onFocusedScreenChanged() {
            cardWindow.screen = root.focusedScreen;
        }
    }

    FileView {
        id: transcriptFile
        path: root.transcriptPath
        watchChanges: false
        printErrors: false

        onLoaded: root.ingest(text())
        onTextChanged: root.ingest(text())
    }

    Timer {
        interval: 250
        repeat: true
        running: true
        onTriggered: transcriptFile.reload()
    }

    function ingest(raw) {
        if (!raw)
            return;
        try {
            const data = JSON.parse(raw);
            const stamp = Number(data.ts ?? 0);
            const sentence = String(data.text ?? "").trim();
            // Only a NEWER dictation replaces the card: the file is re-read
            // four times a second and must not restart its own countdown.
            if (!sentence || stamp <= root.lastStamp)
                return;
            root.lastStamp = stamp;
            // A file the shell did not see being written (it was down, or this
            // QML was reloaded a while later) must not pop up as if it were new.
            // The card's whole point is "the dictation you just made": an old
            // one is deleted rather than shown.
            if (Date.now() / 1000 - stamp > root.holdMs / 1000 + 30) {
                wipeProcess.running = true;
                return;
            }
            root.shownStamp = stamp;
            root.text = sentence;
            root.copied = false;
            root.progress = 1;
            root.remainingMs = root.holdMs;
            root.shown = true;
            closeTimer.stop();
            showAnim.restart();
            // A hover resume replaces this animation's duration with the time
            // that was left (see resumeAfterHover), so every new dictation has
            // to put the full hold back or it would inherit the short one.
            countdown.duration = root.holdMs;
            countdown.restart();
        } catch (e) {
            // Mid-rename or not written yet; the next poll is whole.
        }
    }

    function copyNow() {
        if (root.text.length === 0)
            return;
        // The sentence is taken from its own property, not from `text`: copying
        // closes the card at once, and the card clears `text` as it goes.
        copyPayload = root.text;
        purgeText = root.text;
        // ── Re-arm the pipe BEFORE the run ────────────────────────────────
        // `wl-copy` finishes on EOF, so the write below closes stdin
        // (stdinEnabled = false). Quickshell only gives a process a stdin pipe
        // when stdinEnabled is TRUE as it starts, so without this line the
        // SECOND copy of a session spawned wl-copy with no stdin at all: it
        // wrote nothing, exited, and left the clipboard holding whatever an
        // earlier copy had put there -- which reads exactly as "Copy copied a
        // message from three dictations ago", and is why it worked the first
        // time and not after. Every other repeatable stdin writer in this
        // shell re-enables it per run for the same reason (texteditor.qml,
        // AccountConfig.qml, KeyringStorage.qml).
        copyProcess.stdinEnabled = true;
        // Ask the clipboard watcher to stay quiet BEFORE the copy: announcing
        // one's own change is the one thing a Copy button must not do, and the
        // watcher fires within milliseconds of the new selection.
        Cliphist.quiet(2500);
        copyProcess.running = true;
        purgeTimer.restart();
        copied = true;
        // Copied means rescued: nothing left to wait for. But the card does not
        // vanish on the click -- the glyph turns into a tick, and a confirmation
        // nobody sees is not a confirmation. It goes a beat later, or as soon as
        // the pointer leaves it if it was being hovered.
        countdown.stop();
        if (!root.hovered) {
            closeTimer.interval = 900;
            closeTimer.restart();
        }
    }

    // Where the countdown stands, so a hover can hold it and let it go again.
    function pauseForHover() {
        if (!root.shown)
            return;
        root.remainingMs = Math.max(0, Math.round(root.progress * root.holdMs));
        countdown.stop();
    }

    function resumeAfterHover() {
        if (!root.shown)
            return;
        // Copied already: the tick is up, and the card only waits for the
        // pointer to leave.
        if (root.copied) {
            closeTimer.interval = 600;
            closeTimer.restart();
            return;
        }
        if (root.remainingMs <= 0) {
            root.dismiss();
            return;
        }
        countdown.duration = root.remainingMs;
        countdown.restart();
    }

    function setHovered(h) {
        if (h === root.hovered)
            return;
        root.hovered = h;
        if (root.copied) {
            if (h)
                closeTimer.stop();
            else
                closeTimer.interval = 600;
            if (h)
                return;
            closeTimer.restart();
            return;
        }
        if (h)
            pauseForHover();
        else
            resumeAfterHover();
    }

    function dismiss() {
        if (!root.shown && card.opacity <= 0.01)
            return;
        showAnim.stop();
        countdown.stop();
        closeTimer.stop();
        root.shown = false;     // nothing new may arrive while it closes
        hideAnim.restart();
    }

    // --helpers
    function forget() {
        root.shown = false;
        root.text = "";
        root.progress = 0;
        stampWipeProcess.running = true;
    }

    // wl-copy with --sensitive so the sentence advertises the password-manager
    // hint and cliphist leaves it out of the history, exactly like the paste
    // path in the dictation script. The text goes in on stdin, never on a
    // command line.
    Process {
        id: copyProcess
        command: ["wl-copy", "--sensitive", "-t", "text/plain"]
        stdinEnabled: true

        onRunningChanged: {
            if (!copyProcess.running)
                return;
            copyProcess.write(root.copyPayload);
            copyProcess.stdinEnabled = false;
            root.copyPayload = "";
        }
    }

    Process {
        id: wipeProcess
        command: ["rm", "-f", root.transcriptPath]
    }

    // The card's own wipe, checked by timestamp: a blind rm here deleted the
    // NEXT dictation's transcript when its file landed between this card's last
    // poll and its fade-out, so that dictation failed silently. See the helper.
    Process {
        id: stampWipeProcess
        command: ["python3", (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
            + "/hypr/custom/scripts/transcript-wipe.py", root.transcriptPath,
            root.shownStamp.toFixed(3)]
    }

    // Defence in depth for the copy above: `--sensitive` is a request, and this
    // desktop has seen cliphist store a sensitive selection anyway. The
    // dictation script knows how to take one entry back out by value, so the
    // card asks it to -- a second after the copy, once cliphist has written.
    property string purgeText: ""

    Process {
        id: purgeProcess
        property string payload: ""
        command: ["bash", (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
            + "/hypr/custom/scripts/dictate.sh", "forget"]
        stdinEnabled: true

        onRunningChanged: {
            if (!purgeProcess.running)
                return;
            purgeProcess.write(purgeProcess.payload);
            purgeProcess.stdinEnabled = false;
            purgeProcess.payload = "";
        }
    }

    Timer {
        id: purgeTimer
        interval: 1000
        repeat: false
        onTriggered: {
            if (root.purgeText.length === 0)
                return;
            purgeProcess.payload = root.purgeText;
            // Same re-arm as the copy, and the same reason: the forget pass
            // closes stdin when it is done, so a second purge started with no
            // stdin would not have the sentence and could not take it back
            // out of the clipboard history -- the one thing this is for.
            purgeProcess.stdinEnabled = true;
            purgeProcess.running = true;
        }
    }

    ParallelAnimation {
        id: showAnim
        NumberAnimation {
            target: card
            property: "opacity"
            from: 0
            to: 1
            duration: 150
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: cardTranslate
            property: "y"
            from: 10
            to: 0
            duration: 150
            easing.type: Easing.BezierSpline
            easing.bezierCurve: [0.15, 1.6, 0.42, 1.0]
        }
    }

    ParallelAnimation {
        id: hideAnim
        NumberAnimation {
            target: card
            property: "opacity"
            to: 0
            duration: root.fadeMs
            easing.type: Easing.InCubic
        }
        NumberAnimation {
            target: cardTranslate
            property: "y"
            to: 6
            duration: root.fadeMs
            easing.type: Easing.InCubic
        }
        onFinished: root.forget()
    }

    // One clock, not two: the bar's progress IS the time left, so a hover can
    // stop it and start it again at the exact width it had reached.
    NumberAnimation {
        id: countdown
        target: root
        property: "progress"
        to: 0
        duration: root.holdMs
        easing.type: Easing.Linear
        onFinished: root.dismiss()
    }

    // The beat after a copy, so the tick is actually seen.
    Timer {
        id: closeTimer
        interval: 900
        repeat: false
        onTriggered: root.dismiss()
    }

    PanelWindow {
        id: cardWindow
        color: "transparent"
        screen: root.focusedScreen

        WlrLayershell.namespace: "quickshell:transcriptCard"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusiveZone: 0

        anchors {
            bottom: true
            right: true
        }
        margins.bottom: 12
        margins.right: 12

        implicitWidth: card.implicitWidth
        implicitHeight: card.implicitHeight + 10

        // The card IS the mask: unlike the signal chip there is a button to
        // press, so the window has to accept clicks -- but only where the card
        // is drawn, never over the desktop around it.
        mask: Region { item: card }

        // Keep the surface mapped through the fade-out.
        visible: root.shown || card.opacity > 0.01

        StyledRectangularShadow {
            target: card
            opacity: card.opacity
        }

        Rectangle {
            id: card
            y: 0
            implicitWidth: Math.max(240, row.implicitWidth + 40)
            implicitHeight: Math.max(50, row.implicitHeight + 24)
            color: Appearance.colors.colBackgroundSurfaceContainer
            radius: Appearance.rounding.normal
            clip: true
            opacity: 0

            transform: Translate {
                id: cardTranslate
                y: 0
            }

            // The whole pill is the Copy button. There is one thing to do with
            // a sentence that failed to paste -- take it -- and making the user
            // aim at a small button to do it is a needless second step;
            // clicking anywhere on the pill does the same thing and closes it.
            // The labelled button stays because a chip you can click is not
            // obviously clickable without one.
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                hoverEnabled: true
                onClicked: root.copyNow()
                onContainsMouseChanged: root.setHovered(containsMouse)
            }

            RowLayout {
                id: row
                anchors {
                    left: parent.left
                    right: parent.right
                    top: parent.top
                    bottom: parent.bottom
                    leftMargin: 16
                    rightMargin: 12
                    topMargin: 6
                    bottomMargin: 6
                }
                spacing: 12

                // SignalToast's measurements: a 26px glyph, a small line of
                // colOnSurface ink, no disc behind the glyph.
                MaterialSymbol {
                    Layout.alignment: Qt.AlignVCenter
                    text: "graphic_eq"
                    iconSize: 26
                    color: Appearance.colors.colOnSurface
                }

                StyledText {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    text: Translation.tr("Transcript")
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colOnSurface
                }

                // A bare copy glyph, not a button in its own right: the pill is
                // already one big Copy target, so a boxed "Copy" button next to
                // it was two controls for one action. The icon says what a click
                // does; hovering the pill warms its colour so it reads as
                // clickable.
                //
                // A plain Item, NOT another MouseArea: Qt Quick gives hover to
                // one item only, so a hover-enabled box on top of the card's
                // own MouseArea took the hover away from it the moment the
                // pointer reached the glyph. That resumed the countdown and
                // closed the card under the pointer that was trying to read
                // (or click) it. No second hover target, no competition.
                Item {
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: 22
                    implicitHeight: 22

                    // The copy glyph shrinks away and a tick takes its place, in
                    // the same 22px, so the confirmation lands where the click
                    // did instead of somewhere else on screen.
                    MaterialSymbol {
                        anchors.centerIn: parent
                        text: "content_copy"
                        iconSize: 18
                        opacity: root.copied ? 0 : 1
                        scale: root.copied ? 0.4 : 1
                        color: root.hovered
                            ? Appearance.colors.colPrimary
                            : Appearance.colors.colOnSurface
                        Behavior on opacity {
                            NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
                        }
                        Behavior on scale {
                            NumberAnimation { duration: 140; easing.type: Easing.InCubic }
                        }
                    }

                    MaterialSymbol {
                        anchors.centerIn: parent
                        text: "check"
                        iconSize: 18
                        color: Appearance.colors.colPrimary
                        opacity: root.copied ? 1 : 0
                        scale: root.copied ? 1 : 0.4
                        Behavior on opacity {
                            NumberAnimation { duration: 130; easing.type: Easing.OutCubic }
                        }
                        // A small overshoot, so the tick reads as "done" rather
                        // than as a glyph that was always there.
                        Behavior on scale {
                            NumberAnimation { duration: 220; easing.type: Easing.OutBack }
                        }
                    }
                }
            }

            // Last 3px of the pill: the time it has left, read without
            // taking eyes off the caret.
            Rectangle {
                id: countdownBar
                height: 2
                radius: 1
                color: Appearance.colors.colPrimary
                anchors {
                    left: parent.left
                    bottom: parent.bottom
                    leftMargin: 8
                    bottomMargin: 4
                }
                width: Math.max(0, parent.width - 16) * root.progress
                // Copied: there is no time left to show, only the confirmation.
                opacity: root.copied ? 0 : 1
                Behavior on opacity {
                    NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                }
            }
        }
    }
}
