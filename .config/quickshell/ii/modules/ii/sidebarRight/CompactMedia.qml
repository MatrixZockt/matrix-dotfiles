// The sidebar's media player, at the size its content actually needs.
//
// Track art, ONE line of text (the title -- the artist/album line went away:
// the 60px card never had height for two comfortable rows, and the squeezed
// second line read worse than no line at all), a live equalizer like the top
// bar's, a play/pause button, and an "open app" button that raises the player
// producing the sound.
//
// Mouse contract kept identical to the bar's media widget, so the same hand
// movements work on both surfaces: left toggles the media controls, middle
// toggles playback, back/forward (and right) are previous/next. The open-app
// button is its own click target declared after the card's area, so it wins
// inside its own square.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
// (HyprlandData -- the window list -- comes from qs.services above; no extra
// import needed for the focus jump, which goes through hyprctl itself.)

Rectangle {
    id: root

    readonly property MprisPlayer activePlayer: MprisController.activePlayer
    readonly property bool playing: activePlayer?.playbackState === MprisPlaybackState.Playing
    readonly property string title: MprisController.mediaTitle(activePlayer) || Translation.tr("No media")
    readonly property string artUrl: activePlayer?.trackArtUrl ?? ""

    // The desktop app behind the sound, resolved the way the task manager's
    // Apps page resolves rows: match a client whose resourceClass or title
    // contains a piece of the player's identity. MPRIS bus names look like
    // org.mpris.MediaPlayer2.firefox / .spotify / .brave -- the tail is the
    // usable part.
    readonly property string playerTail: {
        const bus = activePlayer?.dbus?.name ?? "";
        const marker = "org.mpris.MediaPlayer2.";
        return bus.indexOf(marker) >= 0 ? bus.slice(bus.indexOf(marker) + marker.length) : "";
    }
    readonly property var targetWindow: {
        const tail = root.playerTail;
        if (!tail || tail.length === 0) return null;
        const clients = HyprlandData.windowList ?? [];
        const t = tail.toLowerCase();
        // Exact class match first ("firefox"), then a contained one
        // ("brave-browser" contains "brave"), then title.
        return clients.find(c => (c.class ?? "").toLowerCase() === t)
            ?? clients.find(c => (c.class ?? "").toLowerCase().includes(t))
            ?? clients.find(c => (c.title ?? "").toLowerCase().includes(t))
            ?? null;
    }

    // Art (44) plus the card's own padding. Fixed, so the sidebar above it does
    // not reflow when a player appears or disappears.
    implicitHeight: 60
    radius: Appearance.rounding.normal
    color: Appearance.colors.colLayer1

    // The card's own press targets, UNDER the play/pause button below (that one
    // is declared later, so it wins the press inside its own circle). A plain
    // left click opens the FULL music player (the left sidebar's Music tab --
    // library, playlists, artwork, transport), the same target as a press on
    // the island's media view. It used to toggle the little MPRIS card, which
    // is mostly a "No active player" placeholder.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.BackButton | Qt.ForwardButton | Qt.RightButton
        onClicked: (event) => {
            if (event.button === Qt.MiddleButton) {
                if (root.activePlayer) root.activePlayer.togglePlaying();
            } else if (event.button === Qt.BackButton) {
                if (root.activePlayer) root.activePlayer.previous();
            } else if (event.button === Qt.ForwardButton || event.button === Qt.RightButton) {
                if (root.activePlayer) root.activePlayer.next();
            } else {
                openMusicPlayerProc.running = false;
                openMusicPlayerProc.running = true;
            }
        }
    }

    RowLayout {
        anchors {
            fill: parent
            margins: 8
        }
        spacing: 8

        // Track art, with the fallback glyph behind it: an `Image` that is still
        // loading (or that has no art for this track) must not leave a hole.
        Rectangle {
            Layout.preferredWidth: 44
            Layout.preferredHeight: 44
            Layout.alignment: Qt.AlignVCenter
            radius: Appearance.rounding.small
            color: Appearance.colors.colLayer2
            clip: true

            MaterialSymbol {
                anchors.centerIn: parent
                text: "music_note"
                iconSize: Appearance.font.pixelSize.large
                color: Appearance.colors.colOnLayer2
            }
            Image {
                id: art
                anchors.fill: parent
                source: root.artUrl
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                visible: status === Image.Ready
            }
        }

        // The title, alone on its line -- full width, one row, no artist line
        // squeezed under it.
        StyledText {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            text: root.title
            elide: Text.ElideRight
            font.pixelSize: Appearance.font.pixelSize.normal
            color: Appearance.colors.colOnLayer1
        }

        // ── The equalizer ────────────────────────────────────────────────────
        // The same four-bar sound the top bar's MediaIndicator draws, in the
        // card's own palette. Moving only while the song plays; a paused song
        // lets every bar settle to the same short height by itself.
        Item {
            id: equalizer
            Layout.alignment: Qt.AlignVCenter
            implicitWidth: 4 * 3 + 3 * 2
            implicitHeight: 16

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
                anchors.centerIn: parent
                spacing: 2

                Repeater {
                    model: equalizer.barCount

                    Rectangle {
                        required property int index
                        width: 3
                        radius: 1.5
                        color: root.playing ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer1Inactive
                        height: equalizer.levels[index] ?? 4

                        Behavior on height {
                            NumberAnimation {
                                duration: 130
                                easing.type: Easing.OutQuad
                            }
                        }
                    }
                }
            }
        }

        // Play/pause. The one filled disc in this row: it was a bare
        // colOnLayer1 glyph on a transparent pad, which on the sidebar's own
        // background was the dimmest thing on screen -- the control people
        // reach for first, and the hardest to see.
        RippleButton {
            Layout.alignment: Qt.AlignVCenter
            implicitWidth: 34
            implicitHeight: 34
            buttonRadius: Appearance.rounding.full
            colBackground: root.activePlayer !== null
                ? Appearance.colors.colPrimary
                : ColorUtils.transparentize(Appearance.colors.colLayer1Hover, 1)
            colBackgroundHover: Appearance.colors.colPrimaryHover
            colRipple: Appearance.colors.colOnPrimary
            enabled: root.activePlayer !== null
            onClicked: root.activePlayer?.togglePlaying()

            contentItem: MaterialSymbol {
                anchors.centerIn: parent
                text: root.playing ? "pause" : "play_arrow"
                iconSize: Appearance.font.pixelSize.large
                fill: 1
                color: root.activePlayer !== null
                    ? Appearance.colors.colOnPrimary
                    : Appearance.colors.colOnLayer1Inactive
            }

            StyledToolTip {
                text: root.playing ? Translation.tr("Pause") : Translation.tr("Play")
            }
        }

        // ── Open the app behind the sound ────────────────────────────────────
        // The "arrow out of a box" every file manager and browser uses for
        // "open the real thing". Focuses the player's window on its desktop;
        // hidden button while no window matches (browser bars, video sites)
        // rather than a permanently dead one.
        RippleButton {
            Layout.alignment: Qt.AlignVCenter
            implicitWidth: 30
            implicitHeight: 30
            visible: root.targetWindow !== null
            buttonRadius: Appearance.rounding.small
            colBackground: "transparent"
            colBackgroundHover: Appearance.colors.colLayer2Hover
            colRipple: Appearance.colors.colLayer2Active

            onClicked: {
                const w = root.targetWindow;
                if (!w) return;
                // This build's dispatchers take a real window OBJECT (from
                // hl.get_windows()), not an address string -- the same
                // verified pattern the desktop's own anchoring gesture uses.
                // One Lua eval per click, evaluated on the compositor.
                Quickshell.execDetached(["hyprctl", "eval",
                    `for _,w in ipairs(hl.get_windows() or {}) do if w.address == '${w.address}' then hl.dispatch(hl.dsp.focus({window=w})) break end end`]);
            }

            contentItem: MaterialSymbol {
                anchors.centerIn: parent
                text: "open_in_new"
                iconSize: 16
                color: Appearance.colors.colOnLayer1Inactive
            }

            StyledToolTip {
                text: root.targetWindow
                    ? Translation.tr("Show the app playing this")
                    : Translation.tr("No window for this player")
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
