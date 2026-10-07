pragma ComponentBehavior: Bound
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions as CF
import qs.modules.ii.sidebarLeft
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

/**
 * The FULL music player, as a popup: the same Music tab that lives in the
 * left sidebar -- library, playlists, artwork, transport -- hosted in its own
 * window instead of a narrow sidebar column.
 *
 * Why not just open the sidebar and switch to its Music tab? Because the left
 * sidebar's window runs in its OWN QML engine, so the `GlobalStates` it binds
 * to is a different object than the one the bar sees: `sidebarLeftOpen = true`
 * from the island changes a copy nothing is listening to, the sidebar does not
 * open, and nothing on screen says why. This window is built by the same panel
 * family as the media card and in the same engine as the bar, so one flag
 * opens it from the island, the sidebar's music card, the bar's media widgets
 * or a script -- and they can never disagree.
 *
 * Opened with GlobalStates.musicPlayerOpen; closed by clicking outside (it is
 * a focus-grab dismissable, exactly like every other panel in this shell).
 */
Scope {
    id: root

    IpcHandler {
        target: "musicPlayer"

        // The scriptable entry point. `music show` on the MusicPlayer service
        // cannot be used for this: that service lives in its own QML engine,
        // so the GlobalStates it writes is a different singleton from the one
        // this window binds to -- it reported success and nothing happened.
        function open(): void {
            GlobalStates.musicPlayerOpen = true;
        }

        function close(): void {
            GlobalStates.musicPlayerOpen = false;
        }

        function toggle(): void {
            GlobalStates.musicPlayerOpen = !GlobalStates.musicPlayerOpen;
        }
    }

    // The old narrow media card is deleted, but everything that used to point
    // at it -- scripts calling `mediaControls open`, the mediaControlsOpen /
    // mediaControlsClose / mediaControlsToggle keybinds -- is kept alive here
    // and routed to the big player, so nothing silently stops working.
    IpcHandler {
        target: "mediaControls"

        function open(): void {
            GlobalStates.musicPlayerOpen = true;
        }

        function close(): void {
            GlobalStates.musicPlayerOpen = false;
        }

        function toggle(): void {
            GlobalStates.musicPlayerOpen = !GlobalStates.musicPlayerOpen;
        }
    }

    GlobalShortcut {
        name: "mediaControlsToggle"
        description: "Toggles the music player on press"

        onPressed: {
            GlobalStates.musicPlayerOpen = !GlobalStates.musicPlayerOpen;
        }
    }
    GlobalShortcut {
        name: "mediaControlsOpen"
        description: "Opens the music player on press"

        onPressed: {
            GlobalStates.musicPlayerOpen = true;
        }
    }
    GlobalShortcut {
        name: "mediaControlsClose"
        description: "Closes the music player on press"

        onPressed: {
            GlobalStates.musicPlayerOpen = false;
        }
    }

    Loader {
        id: musicPlayerLoader
        active: GlobalStates.musicPlayerOpen
        onActiveChanged: {
            if (!musicPlayerLoader.active && root.totalTracks === 0)
                GlobalStates.musicPlayerOpen = false;
        }

        readonly property int totalTracks: MusicPlayer.totalTracks

        sourceComponent: PanelWindow {
            id: panelWindow
            visible: true

            exclusionMode: ExclusionMode.Ignore
            exclusiveZone: 0
            implicitWidth: 560
            implicitHeight: Math.min(760, panelWindow.screen.height * 0.74)
            color: "transparent"
            WlrLayershell.namespace: "quickshell:musicPlayer"

            anchors {
                top: true
                left: true
            }
            margins {
                // Centred under the top bar, where every other dropdown in
                // this shell drops from.
                top: Appearance.sizes.barHeight + 12
                left: Math.max(0, (panelWindow.screen.width - panelWindow.implicitWidth) / 2)
            }

            mask: Region {
                item: card
            }

            Component.onCompleted: {
                GlobalFocusGrab.addDismissable(panelWindow);
            }
            Component.onDestruction: {
                GlobalFocusGrab.removeDismissable(panelWindow);
            }
            Connections {
                target: GlobalFocusGrab
                function onDismissed() {
                    GlobalStates.musicPlayerOpen = false;
                }
            }

            StyledRectangularShadow {
                target: card
                radius: card.radius
            }

            Rectangle {
                id: card
                anchors.fill: parent
                // The terminal surface, the same token the settings app and the
                // task manager now use (Appearance.colors.colTerminalSurface
                // -> #CFCFCF light, #1F1F1F dark). The owner's complaint was
                // one surface in the shell that did not sit in the same family
                // as everything else; sharing the token is what makes the four
                // agree by construction instead of by four matching numbers.
                color: Appearance.colors.colTerminalSurface
                border.width: 1
                border.color: Appearance.colors.colLayer0Border
                radius: Appearance.rounding.screenRounding - Appearance.sizes.hyprlandGapsOut + 1

                // The Music tab fills whatever it is given; the sidebar sized
                // it, this window does.
                MusicTab {
                    anchors.fill: parent
                    anchors.margins: 6
                }
            }
        }
    }
}
