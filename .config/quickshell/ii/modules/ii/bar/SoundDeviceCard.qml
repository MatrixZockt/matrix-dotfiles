import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts
import Quickshell.Services.Pipewire

/**
 * One audio device, as a card: the tile pressed in the sound popup to make that
 * device the default.
 *
 * A file of its own rather than an inline `component` in SoundPanel.qml, and
 * not by preference: this Quickshell build rejected the inline form with
 * "DeviceCard is not a type" at its own declaration, which took the whole bar
 * down with it. A type that lives in a file can always be named.
 *
 * Self-contained on purpose -- it reads the defaults and the Audio service
 * itself instead of taking a parent panel, so a second popup could reuse it
 * without inheriting this one's layout.
 */
RippleButton {
    id: card

    required property var node
    required property bool forInput

    readonly property bool active: {
        if (!card.node)
            return false;
        const current = card.forInput ? Pipewire.defaultAudioSource : Pipewire.defaultAudioSink;
        return current?.id === card.node.id;
    }

    // Kept in step with `cardHeight` in SoundPanel.qml: the grid maths there
    // reserves exactly this much per row.
    implicitHeight: 60
    buttonRadius: Appearance.rounding.normal
    colBackground: card.active ? Appearance.colors.colLayer2 : Appearance.colors.colLayer1
    colBackgroundHover: card.active ? Appearance.colors.colLayer2Hover : Appearance.colors.colLayer1Hover
    colRipple: Appearance.colors.colLayer2Active

    onClicked: {
        if (card.forInput)
            Audio.setDefaultSource(card.node);
        else
            Audio.setDefaultSink(card.node);
    }

    contentItem: ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 1

        RowLayout {
            Layout.fillWidth: true
            spacing: 4

            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                text: card.forInput ? "mic" : "speaker"
                iconSize: Appearance.font.pixelSize.large
                color: card.active ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer1
            }
            Item {
                Layout.fillWidth: true
            }
            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                visible: card.active
                text: "check_circle"
                iconSize: Appearance.font.pixelSize.normal
                color: Appearance.colors.colPrimary
            }
        }
        StyledText {
            Layout.fillWidth: true
            Layout.fillHeight: true
            // The SHORT name: a card has room for a label, not a hardware
            // chain, and the full description waits in the tooltip.
            text: Audio.shortDeviceName(card.node)
            font.pixelSize: Appearance.font.pixelSize.small
            color: card.active ? Appearance.colors.colOnLayer0 : Appearance.colors.colOnLayer1
            elide: Text.ElideRight
            maximumLineCount: 1
        }
    }

    StyledToolTip {
        text: card.node?.description || card.node?.name || Translation.tr("Unknown device")
    }
}
