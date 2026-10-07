import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * The launch-argument settings, on their own fullscreen surface.
 *
 * WHY A SEPARATE WINDOW, and not another tab in the popup: the popup is a
 * 460px-tall card anchored above the bar, and this settings surface is seven
 * controls that each want to be big enough to grab. Every version of this that
 * lived inside the popup was a negotiation between those two facts, and the
 * popup always won -- the controls got small enough to read but not to aim at.
 * The popup now shows the two facts people actually look at (which model, which
 * address) and this shows the controls at a size that does not need defending.
 *
 * A fullscreen layer surface rather than a floating window: a window would land
 * somewhere arbitrary, be resizable to nothing, and sit behind other windows
 * the moment focus moved. A layer surface is always where it was put.
 *
 * The open state lives on the service, not here, because the button that opens
 * it is in a different file and both have to agree on one boolean.
 */
Scope {
    id: root

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win
            required property var modelData
            screen: modelData

            // Visible only while the service says so. Bound rather than
            // assigned: `LlamaService.settingsOpen` is the single truth, and
            // the button in the popup and this window have no other way to
            // hear about each other.
            visible: LlamaService.settingsOpen

            anchors {
                top: true
                left: true
                right: true
                bottom: true
            }

            color: "#000000"

            WlrLayershell.namespace: "quickshell:llama-settings"
            // Exclusive while open, so Escape and the close button work
            // without the popup having to hold focus for them.
            //
            // It has to be `WlrLayershell.keyboardFocus`, not a bare
            // `WlrKeyboardFocus:` -- the latter is an "Invalid attached object
            // assignment" and takes the whole shell down with it.
            WlrLayershell.keyboardFocus: win.visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
            WlrLayershell.layer: WlrLayer.Overlay
            exclusionMode: ExclusionMode.Ignore

            // A dimmed field rather than an opaque black one: this is still the
            // shell, and a hard cut to #000 reads as leaving the desktop.
            Rectangle {
                anchors.fill: parent
                color: ColorUtils.transparentize(Appearance.colors.colLayer0, 0.72)

                // Clicking the field around the card closes, the way every
                // modal in this shell does. It sits UNDER the card so the
                // settings themselves are never a click that dismisses them.
                MouseArea {
                    anchors.fill: parent
                    onClicked: LlamaService.settingsOpen = false
                }

                Rectangle {
                    id: card
                    readonly property real chrome: 92
                    width: Math.min(parent.width - 160, 720)
                    // Tall enough for the header, the rule and the content --
                    // and no taller. A card stretched to the screen with half
                    // of it empty says "loading" and says it for ever.
                    height: Math.min(parent.height - 120, card.chrome + content.neededHeight)
                    anchors.centerIn: parent
                    radius: Appearance.rounding.large ?? 16
                    color: Appearance.colors.colLayer1
                    border.width: 1
                    border.color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.7)
                    clip: true

                    // Escape closes, and so does the same key that closes
                    // every other surface here.
                    Keys.onEscapePressed: LlamaService.settingsOpen = false
                    focus: true

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 22
                        spacing: 14

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 9
                            MaterialSymbol {
                                text: "tune"
                                iconSize: 17
                                color: Appearance.colors.colPrimary
                            }
                            StyledText {
                                text: Translation.tr("Launch settings")
                                font.pixelSize: Appearance.font.pixelSize.normal
                                font.weight: Font.DemiBold
                                color: Appearance.colors.colOnLayer0
                            }
                            Item { Layout.fillWidth: true }
                            StyledText {
                                // The endpoint is the one thing worth seeing
                                // while changing the port: the setting and the
                                // thing it changes, on one screen.
                                text: `${LlamaService.host}:${LlamaService.port}`
                                font.pixelSize: Appearance.font.pixelSize.small
                                font.family: "JetBrains Mono"
                                color: Appearance.colors.colSubtext
                            }
                            RippleButton {
                                buttonText: Translation.tr("Close")
                                implicitHeight: 28
                                releaseAction: () => { LlamaService.settingsOpen = false; }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 1
                            color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.85)
                        }

                        // The controls themselves, shared verbatim with the
                        // version that used to live in the popup.
                        LlamaSettings {
                            id: content
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                        }
                    }
                }
            }
        }
    }
}