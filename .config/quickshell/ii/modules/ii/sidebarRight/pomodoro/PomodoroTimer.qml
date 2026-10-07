import qs.services
import qs.modules.common
import qs.modules.common.widgets
import Qt5Compat.GraphicalEffects
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

Item {
    id: root

    // Current focus length in minutes (the presets and the free-entry field
    // both key off this; TimerService owns the seconds).
    readonly property int focusMinutes: Math.round(TimerService.focusTime / 60)

    implicitHeight: contentColumn.implicitHeight
    implicitWidth: contentColumn.implicitWidth

    // Length editing, toggled by clicking the clock face itself.
    //
    // Changing the length used to mean finding a separate "Custom __ min" row
    // under the presets -- a bare Qt TextField, which renders as a plain black
    // rectangle with none of this theme's shape or colour on it. The clock is
    // the thing you are setting, so the clock is the control now: click the
    // dial and the readout in the middle becomes the editor, in the same pill
    // language as every other control in the shell.
    property bool editing: false
    readonly property int minMinutes: 1
    readonly property int maxMinutes: 1440

    function beginEditing() {
        editField.text = root.focusMinutes.toString();
        editing = true;
        editField.forceActiveFocus();
        editField.selectAll();
    }

    // Leaving edit mode takes the field's focus WITH it. The two paths that
    // commit are Enter (onAccepted below) and clicking anywhere outside the
    // field (focus loss -> onActiveFocusChanged -> commit): both end here, and
    // without this line Enter committed the value but left focus in a field
    // that was already invisible -- so the next digit typed went nowhere and
    // the sidebar's other keys appeared dead.
    onEditingChanged: {
        if (!editing && editField.activeFocus)
            editField.focus = false;
    }

    function commitEditing() {
        if (!editing) return;
        const v = parseInt(editField.text, 10);
        if (!isNaN(v) && v >= root.minMinutes && v <= root.maxMinutes)
            TimerService.setPomodoroFocus(v * 60);
        editing = false;
    }

    function nudgeMinutes(delta) {
        let v = root.focusMinutes + delta;
        v = Math.max(root.minMinutes, Math.min(root.maxMinutes, v));
        TimerService.setPomodoroFocus(v * 60);
        editField.text = v.toString();
        editField.cursorPosition = editField.text.length;
    }

    ColumnLayout {
        id: contentColumn
        anchors.fill: parent
        spacing: 0

        // The Pomodoro timer circle
        CircularProgress {
            Layout.alignment: Qt.AlignHCenter
            lineWidth: 8
            value: {
                return TimerService.pomodoroSecondsLeft / TimerService.pomodoroLapDuration;
            }
            implicitSize: 200
            enableAnimation: true

            ColumnLayout {
                anchors.centerIn: parent
                spacing: 0
                visible: !root.editing

                StyledText {
                    Layout.alignment: Qt.AlignHCenter
                    text: {
                        let minutes = Math.floor(TimerService.pomodoroSecondsLeft / 60).toString().padStart(2, '0');
                        let seconds = Math.floor(TimerService.pomodoroSecondsLeft % 60).toString().padStart(2, '0');
                        return `${minutes}:${seconds}`;
                    }
                    font.pixelSize: 40
                    color: Appearance.m3colors.m3onSurface
                }
            }

            // The affordance, so "click the clock to set it" is understood
            // before it is ever tried: a pencil badge on the dial's lower
            // left. It used to have a twin on the lower right -- a 36px
            // circle holding the lap number -- so the dial read as symmetric.
            // The lap is gone with the break phase, and a badge that says "2"
            // was never information anyway. Quiet while idle, and it picks up
            // the accent while the pointer is anywhere on the dial -- the
            // same "this is one control" signal the cursor already gives.
            Rectangle {
                visible: !root.editing
                radius: Appearance.rounding.full
                color: dialMouse.containsMouse ? Appearance.colors.colPrimary : Appearance.colors.colLayer2
                anchors {
                    left: parent.left
                    bottom: parent.bottom
                }
                implicitWidth: 36
                implicitHeight: implicitWidth

                Behavior on color {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }

                MaterialSymbol {
                    anchors.centerIn: parent
                    text: "edit_square"
                    iconSize: 18
                    color: dialMouse.containsMouse ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer2

                    Behavior on color {
                        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                    }
                }
            }

            // The whole dial is the target, not just the digits: it is a big,
            // obvious circle in the middle of the panel, and "click the clock to
            // set the clock" needs no explaining -- the badge says where to
            // look, the cursor confirms the whole face is the button.
            MouseArea {
                id: dialMouse
                anchors.fill: parent
                enabled: !root.editing
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.beginEditing()

                StyledToolTip {
                    text: Translation.tr("Click the clock to set the length")
                }
            }

            // The editor, in the clock's own spot: a layer-coloured pill holding
            // a borderless input, flanked by -1 / +1 steppers.
            RowLayout {
                anchors.centerIn: parent
                visible: root.editing
                spacing: 6

                RippleButton {
                    implicitWidth: 34
                    implicitHeight: 34
                    buttonRadius: Appearance.rounding.full
                    colBackground: Appearance.colors.colLayer2
                    colBackgroundHover: Appearance.colors.colLayer2Hover
                    onClicked: root.nudgeMinutes(-1)
                    contentItem: StyledText {
                        anchors.centerIn: parent
                        horizontalAlignment: Text.AlignHCenter
                        text: "\u2212"
                        font.pixelSize: Appearance.font.pixelSize.larger
                        color: Appearance.colors.colOnLayer2
                    }
                }

                Rectangle {
                    implicitWidth: 96
                    implicitHeight: 44
                    radius: Appearance.rounding.full
                    color: Appearance.colors.colLayer2
                    border.width: 2
                    border.color: editField.activeFocus ? Appearance.colors.colPrimary : "transparent"

                    StyledTextInput {
                        id: editField
                        anchors.centerIn: parent
                        width: parent.width - 24
                        horizontalAlignment: TextInput.AlignHCenter
                        font.pixelSize: 30
                        color: Appearance.colors.colOnLayer2
                        inputMethodHints: Qt.ImhDigitsOnly
                        validator: IntValidator { bottom: root.minMinutes; top: root.maxMinutes }
                        onAccepted: root.commitEditing()
                        // Clicking away is the same as pressing Enter; Escape
                        // leaves the length as it was.
                        onActiveFocusChanged: if (!activeFocus) root.commitEditing()
                        Keys.onEscapePressed: root.editing = false
                        Keys.onUpPressed: root.nudgeMinutes(1)
                        Keys.onDownPressed: root.nudgeMinutes(-1)
                    }
                }

                RippleButton {
                    implicitWidth: 34
                    implicitHeight: 34
                    buttonRadius: Appearance.rounding.full
                    colBackground: Appearance.colors.colLayer2
                    colBackgroundHover: Appearance.colors.colLayer2Hover
                    onClicked: root.nudgeMinutes(1)
                    contentItem: StyledText {
                        anchors.centerIn: parent
                        horizontalAlignment: Text.AlignHCenter
                        text: "+"
                        font.pixelSize: Appearance.font.pixelSize.larger
                        color: Appearance.colors.colOnLayer2
                    }
                }
            }
        }

        // Preset focus lengths, then the free override.
        //
        // These used to be one row of 26px slivers -- six targets squeezed into
        // ~250px, with the label the only thing that fit, which is why the row
        // read as an afterthought next to the timer. They are a 3x2 grid of
        // full-width pills now: each one a 38px target with the shape this theme
        // uses everywhere else (the rail's own pill, full rounding), 8px of air
        // between them, and the active preset filled with the accent so which
        // length is in force is readable at a glance rather than by reading six
        // labels. The free minutes entry sits on its own centred line beneath,
        // where it cannot squeeze the pills.
        GridLayout {
            Layout.fillWidth: true
            columns: 3
            columnSpacing: 8
            rowSpacing: 8

            Repeater {
                model: [
                    { label: "1m",  seconds: 60 },
                    { label: "5m",  seconds: 300 },
                    { label: "10m", seconds: 600 },
                    { label: "25m", seconds: 1500 },
                    { label: "30m", seconds: 1800 },
                    { label: "1h",  seconds: 3600 }
                ]

                RippleButton {
                    id: presetChip
                    required property var modelData
                    readonly property bool active: root.focusMinutes === Math.round(modelData.seconds / 60)

                    Layout.fillWidth: true
                    implicitHeight: 38
                    buttonRadius: Appearance.rounding.full
                    colBackground: active ? Appearance.colors.colPrimary : Appearance.colors.colLayer2
                    colBackgroundHover: active ? Appearance.colors.colPrimaryHover : Appearance.colors.colLayer2Hover
                    onClicked: TimerService.setPomodoroFocus(modelData.seconds)

                    contentItem: StyledText {
                        anchors.centerIn: parent
                        text: presetChip.modelData.label
                        font.pixelSize: Appearance.font.pixelSize.normal
                        font.weight: presetChip.active ? Font.DemiBold : Font.Normal
                        color: presetChip.active ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer2
                    }
                }
            }
        }

        // (The old "Custom __ min" row lived here -- a bare Qt TextField and a
        // label. It is gone: the length is edited by clicking the clock face
        // above, which keeps this column to the timer, the presets and the
        // controls.)

        // The Start/Stop and Reset buttons
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 10

            RippleButton {
                contentItem: StyledText {
                    anchors.centerIn: parent
                    horizontalAlignment: Text.AlignHCenter
                    text: TimerService.pomodoroRunning ? Translation.tr("Pause") : (TimerService.pomodoroSecondsLeft === TimerService.focusTime) ? Translation.tr("Start") : Translation.tr("Resume")
                    color: TimerService.pomodoroRunning ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnPrimary
                }
                implicitHeight: 35
                implicitWidth: 90
                font.pixelSize: Appearance.font.pixelSize.larger
                onClicked: TimerService.togglePomodoro()
                colBackground: TimerService.pomodoroRunning ? Appearance.colors.colSecondaryContainer : Appearance.colors.colPrimary
                colBackgroundHover: TimerService.pomodoroRunning ? Appearance.colors.colSecondaryContainer : Appearance.colors.colPrimary
            }

            RippleButton {
                implicitHeight: 35
                implicitWidth: 90

                onClicked: TimerService.resetPomodoro()
                enabled: TimerService.pomodoroSecondsLeft < TimerService.pomodoroLapDuration

                font.pixelSize: Appearance.font.pixelSize.larger
                colBackground: Appearance.colors.colErrorContainer
                colBackgroundHover: Appearance.colors.colErrorContainerHover
                colRipple: Appearance.colors.colErrorContainerActive

                contentItem: StyledText {
                    anchors.centerIn: parent
                    horizontalAlignment: Text.AlignHCenter
                    text: Translation.tr("Reset")
                    color: Appearance.colors.colOnErrorContainer
                }
            }
        }
    }
}
