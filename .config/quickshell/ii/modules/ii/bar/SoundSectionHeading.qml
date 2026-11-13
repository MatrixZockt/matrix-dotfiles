import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts

/**
 * A column heading in the sound popup: the word, and the one switch that
 * belongs to it.
 *
 * The microphone's switch is its mute, because a muted mic is what that column
 * is reached for far more often than a different mic. The output column passes
 * `showMute: false` and keeps its mute beside the level slider instead, where
 * the level it silences is.
 *
 * Its own file for the same reason as SoundDeviceCard: an inline component in
 * SoundPanel.qml was refused by this build, and a file-based type always
 * resolves.
 */
RowLayout {
    id: heading

    required property string label
    required property bool showMute
    required property bool muted

    spacing: 4

    StyledText {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        text: heading.label
        font.pixelSize: Appearance.font.pixelSize.smaller
        color: Appearance.colors.colSubtext
    }

    RippleButton {
        Layout.preferredWidth: 28
        Layout.preferredHeight: 28
        visible: heading.showMute
        buttonRadius: Appearance.rounding.small
        colBackground: "transparent"
        colBackgroundHover: Appearance.colors.colLayer1Hover
        onClicked: Audio.toggleMicMute()
        contentItem: MaterialSymbol {
            anchors.centerIn: parent
            text: heading.muted ? "mic_off" : "mic"
            iconSize: Appearance.font.pixelSize.normal
            color: heading.muted ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer1
        }
        StyledToolTip {
            text: heading.muted ? Translation.tr("Unmute microphone") : Translation.tr("Mute microphone")
        }
    }
}
