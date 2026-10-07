//@ pragma UseQApplication
//
// Standalone lock screen.
//
// This runs as its OWN Quickshell process (`qs -p lockscreen.qml`), launched by
// scripts/lock/lock.sh. That is deliberate and it is the whole point:
//
//   The main shell hot-reloads its entire QML tree whenever any watched file
//   changes. If the main shell held the Wayland session lock, editing any shell
//   file while locked destroyed the lock surface mid-lock, Hyprland painted its
//   "lockscreen app died" fallback, and the session was unrecoverable from the
//   graphical side. Holding the lock from a separate process means nothing the
//   main shell does can disturb it.
//
// The launcher also supervises this process and falls back to hyprlock if it dies
// without unlocking, so a crash here still leaves a working lock screen behind.
//
// Enter behaves the way it was asked to:
//   * Enter with an empty field only reveals/focuses the field -- it does NOT
//     submit a blank password and trip "authentication failed".
//   * Enter a second time, or Enter with something typed, submits.
// Typing reveals the field as well, so nobody has to press Enter to start typing.
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pam
import QtQuick
import qs.services
import qs.modules.common

ShellRoot {
    id: root

    // Set by `lock.sh --test`: render the UI as an ordinary layer-shell overlay
    // and do NOT take the session lock. This is how the layout and the Enter
    // behaviour get checked without any risk of locking the session.
    readonly property bool testMode: Quickshell.env("QS_LOCK_TEST") === "1"
    readonly property string unlockMarker: "/tmp/qs-lock-unlocked"

    property string typed: ""
    property bool revealed: false
    property bool failed: false
    property bool busy: false
    property string clockText: ""
    property string dateText: ""
    property string layoutText: ""

    Component.onCompleted: {
        root.tick();
        layoutProc.running = true;
    }

    function tick() {
        const now = new Date();
        root.clockText = Qt.formatTime(now, "HH:mm");
        root.dateText = Qt.formatDate(now, "dd MMMM");
    }

    // Enter. Empty field + not yet revealed -> just reveal. Otherwise submit.
    function onReturn() {
        if (root.busy)
            return;
        if (root.typed.length > 0 || root.revealed)
            root.submit();
        else
            root.revealed = true;
    }

    // Note: an EMPTY submit is deliberately allowed here. `onReturn` is what
    // decides whether we are at the reveal step or the submit step, and a second
    // Enter is an intentional submit -- refusing it would make the "press it twice"
    // behaviour silently do nothing.
    function submit() {
        if (root.busy)
            return;
        root.busy = true;
        pam.start();
    }

    function finish() {
        // Tell the supervising launcher this was a real unlock, so it does not
        // treat our exit as a crash and bring hyprlock up behind us.
        Quickshell.execDetached(["bash", "-c", `: > ${root.unlockMarker}`]);
        lock.locked = false;
        quitTimer.start();
    }

    function switchLayout() {
        Quickshell.execDetached(["bash", "-c", "hyprctl switchxkblayout all next"]);
        layoutTimer.restart();
    }

    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: root.tick()
    }

    Timer {
        id: layoutTimer
        interval: 600
        repeat: false
        onTriggered: layoutProc.running = true
    }

    Timer {
        id: quitTimer
        interval: 250
        repeat: false
        onTriggered: Qt.quit()
    }

    // Layout name for the bottom-right label. Asking Hyprland directly keeps this
    // independent of any particular shell service's API.
    Process {
        id: layoutProc
        command: ["bash", "-c",
            "hyprctl devices -j | python3 -c \"import json,sys; d=json.load(sys.stdin); "
            + "k=[x for x in d.get('keyboards',[]) if x.get('main')] or d.get('keyboards',[]); "
            + "print(k[0].get('active_keymap','') if k else '')\""]
        stdout: StdioCollector {
            onStreamFinished: root.layoutText = text.trim()
        }
    }

    PamContext {
        id: pam

        onPamMessage: {
            if (this.responseRequired)
                this.respond(root.typed);
        }

        onCompleted: result => {
            root.busy = false;
            if (result == PamResult.Success) {
                root.finish();
            } else {
                root.failed = true;
                root.typed = "";
                root.revealed = true;
            }
        }
    }

    // ── The lock itself ─────────────────────────────────────────────────────
    // In test mode `locked` stays false, so the session is never actually locked.
    WlSessionLock {
        id: lock
        locked: !root.testMode
        surface: WlSessionLockSurface {
            color: "black"
            LockBody {
                anchors.fill: parent
            }
        }
    }

    // Test host: the same body as a plain overlay, so it can be seen and typed
    // into without locking anything.
    PanelWindow {
        visible: root.testMode
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        color: "transparent"
        exclusiveZone: 0
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "quickshell:lockTest"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

        LockBody {
            anchors.fill: parent
        }
    }

    component LockBody: Item {
        id: body

        Rectangle {
            anchors.fill: parent
            color: Appearance.m3colors.m3background
        }

        Column {
            anchors.centerIn: parent
            spacing: 14
            width: parent.width

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.dateText
                color: Appearance.colors.colSubtext
                font {
                    pixelSize: 24
                    family: Appearance.font.family.main
                }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.clockText
                color: Appearance.colors.colOnLayer0
                font {
                    pixelSize: 120
                    family: Appearance.font.family.numbers
                }
            }

            Item {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 360
                height: 56

                Rectangle {
                    anchors.fill: parent
                    radius: height / 2
                    color: Appearance.colors.colLayer1
                    border.width: 2
                    border.color: root.failed
                        ? Appearance.m3colors.m3error
                        : (field.activeFocus ? Appearance.colors.colPrimary : Appearance.colors.colLayer0Border)
                }

                Text {
                    anchors.centerIn: parent
                    visible: root.typed.length === 0
                    text: root.failed
                        ? Translation.tr("Wrong password")
                        : (root.revealed ? Translation.tr("Type your password") : Translation.tr("Press Enter to type"))
                    color: root.failed ? Appearance.m3colors.m3error : Appearance.colors.colSubtext
                    font.pixelSize: 18
                }

                TextInput {
                    id: field
                    anchors.fill: parent
                    anchors.margins: 18
                    focus: true
                    verticalAlignment: TextInput.AlignVCenter
                    horizontalAlignment: TextInput.AlignHCenter
                    echoMode: TextInput.Password
                    passwordCharacter: "•"
                    color: Appearance.colors.colOnLayer1
                    font.pixelSize: 20
                    selectByMouse: false
                    // Enter is handled here so it can reveal instead of submitting.
                    Keys.onReturnPressed: root.onReturn()
                    Keys.onEnterPressed: root.onReturn()
                    onTextChanged: {
                        root.typed = text;
                        if (text.length > 0) {
                            root.revealed = true;
                            root.failed = false;
                        }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    z: -1
                    onClicked: root.revealed = true
                }
            }
        }

        // Bottom right: the keyboard layout, and it is clickable so it is obvious
        // that the layout can be changed from here.
        Rectangle {
            id: layoutChip
            anchors {
                right: parent.right
                bottom: parent.bottom
                margins: 22
            }
            width: layoutLabel.implicitWidth + 28
            height: 38
            radius: height / 2
            color: layoutMouse.containsMouse
                ? Appearance.colors.colLayer1Hover
                : Appearance.colors.colLayer1

            Text {
                id: layoutLabel
                anchors.centerIn: parent
                text: root.layoutText.length > 0
                    ? Translation.tr("Keyboard layout: %1").arg(root.layoutText)
                    : Translation.tr("Keyboard layout")
                color: Appearance.colors.colSubtext
                font.pixelSize: 15
            }

            MouseArea {
                id: layoutMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.switchLayout()
            }
        }
    }
}
