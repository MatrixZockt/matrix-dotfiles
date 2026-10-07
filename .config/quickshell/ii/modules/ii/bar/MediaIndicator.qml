import qs.modules.common
import qs
import qs.modules.common.widgets
import qs.services
import qs.modules.common.functions

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris

/**
 * The now-playing widget that sits on the bar next to the desktops.
 *
 * Nothing here while nothing is playing -- the widget has no "no media" state, it
 * simply is not there -- and when a player appears it shows a small equalizer and
 * the track name. The bars move only while the player is actually playing: a
 * paused song leaves them resting at a low, even height, which is a much clearer
 * signal than any icon.
 *
 *   left click ....... open the media controls panel
 *   middle click ..... play/pause
 *   right click ...... next track
 *
 * The title is elided rather than allowed to push the desktops around, because
 * the bar's centre group is what it shares its width with.
 */
Item {
    id: root

    readonly property MprisPlayer player: MprisController.activePlayer
    readonly property bool playing: MprisController.isPlaying === true
    readonly property string trackTitle: MprisController.mediaTitle(root.player)
    readonly property string trackArtist: root.player?.trackArtist ?? ""
    readonly property bool hasTrack: root.player !== null && root.trackTitle.length > 0

    visible: root.hasTrack
    Layout.alignment: Qt.AlignVCenter
    implicitWidth: root.hasTrack ? (contentRow.implicitWidth + 20) : 0
    implicitHeight: Appearance.sizes.barHeight

    // The track length is not read from a timer here: the shell already refreshes
    // the active player's position for its progress bar, and this widget only
    // needs to know *whether* the song is playing, which is a property of the
    // player and not something that drifts.

    transform: Scale {
        xScale: mediaHover.hovered ? 1.06 : 1
        yScale: mediaHover.hovered ? 1.06 : 1
        Behavior on xScale {
            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
        }
        Behavior on yScale {
            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
        }
    }

    Rectangle {
        anchors.fill: parent
        anchors.topMargin: 4
        anchors.bottomMargin: 4
        radius: Appearance.rounding.small
        color: mediaHover.hovered
            ? ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.9)
            : ColorUtils.transparentize(Appearance.colors.colOnLayer0, 1)
        Behavior on color {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
        }
    }

    HoverHandler {
        id: mediaHover
        cursorShape: Qt.PointingHandCursor
    }

    // Public read of the hover state, for the bar's liquid pocket wiring.
    readonly property bool mediaHovered: mediaHover.hovered

    // MouseArea, not TapHandler: the bar's own section MouseArea grabs the
    // press before a TapHandler can complete, so the now-playing widget was not
    // clickable (and middle/right click did nothing).
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: event => {
            if (event.button === Qt.MiddleButton)
                MprisController.togglePlaying();
            else if (event.button === Qt.RightButton)
                MprisController.next();
            else {
                openMusicPlayerProc.running = false;
                openMusicPlayerProc.running = true;
            }
        }
    }

    RowLayout {
        id: contentRow
        anchors.centerIn: parent
        spacing: 8

        // ── The equalizer ────────────────────────────────────────────────────
        // Four bars, re-randomised on a short timer while the song plays. Each bar
        // eases to its new height instead of jumping, so the row reads as sound
        // rather than as noise. Paused, the timer stops and every bar settles to
        // the same short height by itself.
        Item {
            id: equalizer
            Layout.alignment: Qt.AlignVCenter
            implicitWidth: 4 * 3 + 3 * 2
            implicitHeight: 15

            readonly property int barCount: 4
            property var levels: [4, 7, 5, 9]

            Timer {
                running: root.playing
                interval: 165
                repeat: true
                onTriggered: {
                    const next = [];
                    for (let i = 0; i < equalizer.barCount; ++i)
                        next.push(3 + Math.random() * (equalizer.implicitHeight - 4));
                    equalizer.levels = next;
                }
            }

            Row {
                id: bars
                anchors.centerIn: parent
                spacing: 2

                Repeater {
                    model: equalizer.barCount

                    Item {
                        required property int index
                        width: 3
                        height: equalizer.implicitHeight

                        Rectangle {
                            anchors.bottom: parent.bottom
                            width: parent.width
                            radius: 1.5
                            color: root.playing
                                ? Appearance.colors.colPrimary
                                : ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.45)
                            height: root.playing
                                ? Math.max(3, equalizer.levels[index] ?? 4)
                                : 4
                            Behavior on height {
                                NumberAnimation {
                                    duration: 165
                                    easing.type: Easing.InOutSine
                                }
                            }
                            Behavior on color {
                                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                            }
                        }
                    }
                }
            }
        }

        ColumnLayout {
            Layout.alignment: Qt.AlignVCenter
            spacing: -2

            StyledText {
                Layout.fillWidth: true
                Layout.maximumWidth: 190
                text: root.trackTitle
                color: Appearance.colors.colOnLayer0
                font.pixelSize: Appearance.font.pixelSize.small
                elide: Text.ElideRight
            }

            // The second line folds away unless this widget's pocket is open:
            // the liquid bar reveals artist/channel UNDER the title on hover
            // (BarContent arms LiquidBar with "media"), and at rest the widget
            // is title-only, as asked. The Reveal is height-animated, so the
            // line unfolds with the pocket's own rubber motion instead of
            // popping.
            Revealer {
                reveal: LiquidBar.pocketId === "media"
                Layout.fillHeight: true
                Behavior on implicitHeight {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                }
                StyledText {
                    Layout.maximumWidth: 190
                    visible: root.trackArtist.length > 0
                    text: root.trackArtist
                    color: ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.35)
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    elide: Text.ElideRight
                }
            }
        }
    }

    // Opening the music player crosses a QML-engine boundary: GlobalStates is
    // instantiated once PER ENGINE, so a flag set here never reaches the panel
    // window listening for it -- which is why every in-app attempt to open a
    // popup from this surface silently did nothing. An IPC call does cross it
    // (the handler lives in the panel's own engine), so the shell asks for the
    // player the same way a keybind does.
    Process {
        id: openMusicPlayerProc
        command: ["/usr/bin/qs", "-c", "ii", "ipc", "call", "musicPlayer", "open"]
    }

}
