pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.modules.waffle.looks

Rectangle {
    id: root
    implicitHeight: 176
    implicitWidth: 358
    color: Looks.colors.bgPanelBody
    anchors.fill: parent

    readonly property var activePlayer: MprisController.activePlayer

    Column {
        anchors {
            fill: parent
            leftMargin: 23
            rightMargin: 23
            topMargin: 16
            bottomMargin: 20
        }
        spacing: 25

        AppInfoRow {
            anchors {
                left: parent.left
                right: parent.right
            }
        }

        TrackInfoRow {
            anchors {
                left: parent.left
                right: parent.right
            }
        }

        ControlButtonsRow {
            anchors.horizontalCenter: parent.horizontalCenter
        }
    }

    component AppInfoRow: RowLayout {
        id: appInfo
        spacing: 8

        property var desktopEntry: {
            const desktopEntryString = root.activePlayer?.desktopEntry ?? "";
            return DesktopEntries.byId(desktopEntryString);
        }

        FluentIcon {
            implicitSize: 20
            icon: appInfo.desktopEntry?.icon || "music-note-2"
            monochrome: !appInfo.desktopEntry?.icon
        }

        WText {
            Layout.fillWidth: true
            text: appInfo.desktopEntry?.name ?? Translation.tr("Media")
            horizontalAlignment: Text.AlignLeft
            elide: Text.ElideRight
        }
    }

    component TrackInfoRow: RowLayout {
        spacing: 16

        ColumnLayout {
            id: trackInfo
            Layout.fillWidth: true
            spacing: 0

            WText {
                Layout.fillWidth: true
                font.weight: Looks.font.weight.strong
                font.pixelSize: Looks.font.pixelSize.large
                elide: Text.ElideRight
                text: MprisController.mediaTitle(root.activePlayer) || Translation.tr("Unknown Title")
            }

            WText {
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: root.activePlayer?.trackArtist || Translation.tr("Unknown Artist")
            }
        }

        StyledImage {
            id: artImage
            Layout.preferredWidth: 58
            Layout.preferredHeight: trackInfo.implicitHeight
            source: MprisController.activeTrack?.artUrl || ""
            fillMode: Image.PreserveAspectFit

            layer.enabled: true
            layer.effect: OpacityMask {
                maskSource: Item {
                    width: artImage.width
                    height: artImage.height
                    Rectangle {
                        anchors.centerIn: parent
                        width: artImage.paintedWidth
                        height: artImage.paintedHeight
                        radius: Looks.radius.medium
                    }
                }
            }
        }
    }

    component ControlButtonsRow: RowLayout {
        spacing: 26

        MediaControlButton {
            iconName: "previous"
            enabled: root.activePlayer?.canGoPrevious ?? false
            onClicked: root.activePlayer?.previous()
        }
        MediaControlButton {
            readonly property bool playing: root.activePlayer?.isPlaying ?? false
            iconName: playing ? "pause" : "play"
            // The transport's one filled disc. Three identical bare icons in a
            // row gave the eye no place to land; the middle one is now the
            // control, the two skips are context.
            highlight: true
            enabled: (playing && root.activePlayer?.canPause) || (!playing && root.activePlayer?.canPlay)
            onClicked: root.activePlayer?.togglePlaying()
        }
        MediaControlButton {
            iconName: "next"
            enabled: root.activePlayer?.canGoNext ?? false
            onClicked: root.activePlayer?.next()
        }
    }

    component MediaControlButton: WBorderlessButton {
        id: controlButton
        required property string iconName
        // The play/pause wears a filled disc; the skips stay bare.
        property bool highlight: false
        implicitHeight: 40
        implicitWidth: 40

        contentItem: Item {
            Rectangle {
                anchors.centerIn: parent
                width: 32
                height: 32
                radius: width / 2
                visible: controlButton.highlight && controlButton.enabled
                color: Looks.colors.accent
                Behavior on color {
                    ColorAnimation { duration: 120 }
                }
            }
            FluentIcon {
                anchors.centerIn: parent
                icon: controlButton.iconName
                monochrome: true
                filled: true
                implicitSize: controlButton.highlight ? 16 : 18
                color: controlButton.highlight && controlButton.enabled
                    ? Looks.colors.accentFg
                    : Looks.colors.controlFg
            }
        }
    }
}
