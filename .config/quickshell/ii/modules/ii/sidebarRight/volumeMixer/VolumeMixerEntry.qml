import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Pipewire
import Qt5Compat.GraphicalEffects

/**
 * One app's row in the output mixer.
 *
 * Built around a `row` (Audio.mixerApps) rather than a bare PipeWire node,
 * because an app does not need to be making a sound to have a volume: the row
 * covers every app on the machine, and the node is simply there or not. When
 * there is one, it is the authority -- volume, mute and the live label all
 * come off it. When there is not, the values come from the shell's memory of
 * that app and are applied to its stream when it next plays (see
 * Audio.applyRememberedVolumes).
 */
Item {
    id: root
    required property var row
    property bool isSink: true

    // Only for a live stream. The node's own volume is a tracked property, so
    // the slider follows the media keys as well as the mouse.
    PwObjectTracker {
        objects: root.row?.node ? [root.row.node] : []
    }

    readonly property var saved: Audio.remembered(root.row?.key ?? "")
    // "This drag moved the value, so it owes a chime when it lets go."
    // Set from the slider, spent on release. Not a binding, and not anything
    // the chime itself touches.
    property bool previewDirty: false
    // A remembered value only counts once the user has actually moved the row
    // for an app that had nothing to read from.
    readonly property bool remembered: root.row?.node
        ? false
        : root.saved.remembered === true
    readonly property real volume: root.row?.node
        ? (root.row.node.audio?.volume ?? 0)
        : (root.remembered ? root.saved.volume : 1.0)
    readonly property bool muted: root.row?.node
        ? (root.row.node.audio?.muted === true)
        : (root.remembered && root.saved.muted === true)

    // The desktop icon, resolved once per row rather than per repaint. The
    // generic fallback is the shell's app-generic.svg, so an app nothing can
    // be found for still draws a glyph rather than a broken-image box.
    readonly property string iconSource: {
        const icon = String(root.row?.icon ?? "");
        if (icon === "")
            return "";
        return Quickshell.iconPath(icon,
            Quickshell.shellPath("assets/icons/fluent/app-generic.svg"));
    }

    implicitHeight: rowLayout.implicitHeight

    RowLayout {
        id: rowLayout
        anchors.fill: parent
        spacing: 6

        MouseArea {
            property real size: 36
            Layout.alignment: Qt.AlignHCenter | Qt.AlignVCenter
            Layout.preferredWidth: size
            Layout.preferredHeight: size

            cursorShape: Qt.PointingHandCursor
            onClicked: {
                Audio.setAppMuted(root.row.key, root.row.node, !root.muted);
                // Only the System Sounds row chimes. An app row cannot: the
                // sound it would play is the very thing being regulated, so it
                // would be judging its own level with the level in question.
                if (root.row?.previews === true)
                    Audio.previewSystemSound();
            }

            hoverEnabled: true
            property bool hovered: containsMouse
            StyledToolTip {
                text: root.muted ? Translation.tr("Click to unmute") : Translation.tr("Click to mute")
            }

            // ── The icon ───────────────────────────────────────────────────
            //
            // Three faces, because the rows are not all the same kind of thing
            // any more: a desktop app's own icon, a drawn mark for the
            // machine's own services, and the generic glyph for an app
            // nothing can be found for.
            //
            // The drawn faces are drawn rather than looked up, on purpose. The
            // local music daemon is mpv over a socket -- no .desktop entry, no
            // icon theme name, the stream reports the bare binary name -- and
            // system sounds have no app at all, so every lookup path lands on
            // the generic app glyph. What those rows should say is what they
            // ARE. A single note in a tinted disc, and a bell, read as that at a
            // glance and look like they belong to the same set as the app icons
            // beside them, where a desktop icon for a service never could.
            Rectangle {
                id: musicBadge
                anchors.fill: parent
                radius: width / 2
                visible: root.row?.music === true
                color: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.82)

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 1
                    radius: width / 2
                    color: "transparent"
                    border.width: 1
                    border.color: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.55)
                }

                MaterialSymbol {
                    anchors.centerIn: parent
                    text: "music_note"
                    iconSize: 19
                    color: Appearance.colors.colPrimary
                }
            }

            Rectangle {
                id: symbolBadge
                anchors.fill: parent
                radius: width / 2
                visible: root.row?.symbol !== undefined && root.row.symbol !== ""
                color: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.82)

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 1
                    radius: width / 2
                    color: "transparent"
                    border.width: 1
                    border.color: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.55)
                }

                MaterialSymbol {
                    anchors.centerIn: parent
                    // Empty rather than undefined for the rows that carry no
                    // symbol: this is a QString, and a hidden element still
                    // evaluates its bindings.
                    text: String(root.row?.symbol ?? "")
                    iconSize: 19
                    color: Appearance.colors.colPrimary
                }
            }

            StyledImage {
                id: iconImg
                anchors.fill: parent
                visible: root.row?.music !== true
                    && !(root.row?.symbol !== undefined && root.row.symbol !== "")
                    && root.iconSource !== ""
                source: root.iconSource
                asynchronous: true
            }

            Desaturate {
                anchors.fill: iconImg
                source: iconImg
                desaturation: root.muted ? 1.0 : 0.0
                visible: iconImg.source !== "" && iconImg.visible
                opacity: root.muted ? 0.4 : 1.0

                Behavior on opacity {
                    NumberAnimation {
                        duration: 150
                    }
                }
                Behavior on desaturation {
                    NumberAnimation {
                        duration: 150
                    }
                }
            }

            MaterialSymbol {
                anchors.centerIn: parent
                // Only over the app's own icon. Over a drawn mark it would hide
                // the one thing that identifies the row.
                visible: root.muted && root.row?.music !== true
                    && !(root.row?.symbol !== undefined && root.row.symbol !== "")
                text: root.isSink ? "volume_off" : "mic_off"
                iconSize: 22
                color: Appearance.colors.colOnLayer1
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: -4

            StyledText {
                Layout.fillWidth: true
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colSubtext
                elide: Text.ElideRight
                text: {
                    const name = root.row?.name ?? "";
                    // The music row is "Music - <song>", never "Music" and
                    // never the binary that happens to be playing it. The
                    // title comes from the daemon (see Audio.musicTitleFor),
                    // so it is there whether or not mpv is streaming; when
                    // nothing is playing there is no song to name and the row
                    // is just "Music".
                    if (root.row?.music === true) {
                        const song = String(root.row?.title ?? "").trim();
                        return song === "" ? name : `${name} - ${song}`;
                    }
                    // A playing stream can name the track; an app with no
                    // stream has nothing to add, so it says so instead of
                    // pretending to be silent for a reason.
                    const media = root.row?.node?.properties?.["media.name"];
                    const live = media != undefined && String(media).trim() !== "";
                    return live ? `${name} • ${media}` : name;
                }
            }

            StyledSlider {
                id: slider
                value: root.volume
                onMoved: {
                    Audio.setAppVolume(root.row.key, root.row.node, value);
                    // Marked, not played. See `previewDirty`.
                    if (root.row?.previews === true) {
                        root.previewDirty = true;
                        previewFallback.restart();
                    }
                }
                // The chime, two ways, because one of them has silently
                // failed and the symptom is indistinguishable from "the
                // volume control is broken".
                //
                // The release edge is the good one: the drag is over, the
                // value is final, play it. The trailing timer is the backstop
                // for when that edge never arrives -- a rebuild landing
                // mid-drag, a delegate being recycled, the press ending
                // outside the handle. It asks the simpler question: has the
                // value stopped moving? If it has, chime.
                //
                // They cannot double up, because `previewSystemSound` is
                // rate-limited: whichever fires first plays, and the other is
                // swallowed for the next 600ms.
                Timer {
                    id: previewFallback
                    interval: 400
                    repeat: false
                    onTriggered: {
                        if (!root.previewDirty)
                            return;
                        root.previewDirty = false;
                        print(`[mixer] preview via fallback zone=${root.row?.key}`);
                        Audio.previewSystemSound();
                    }
                }
                onPressedChanged: {
                    if (root.row?.previews !== true)
                        return;
                    print(`[mixer] pressed=${pressed} dirty=${root.previewDirty}`);
                    if (pressed) {
                        root.previewDirty = false;
                        previewFallback.stop();
                        return;
                    }
                    previewFallback.stop();
                    if (!root.previewDirty)
                        return;
                    root.previewDirty = false;
                    print(`[mixer] preview via release zone=${root.row?.key}`);
                    Audio.previewSystemSound();
                }
                // An app with nothing remembered and nothing playing has no
                // real value to show, so the bar is drawn empty rather than
                // confidently full.
                opacity: (root.row?.node || root.remembered) ? 1 : 0.45
                Behavior on opacity {
                    NumberAnimation {
                        duration: 150
                    }
                }
                configuration: StyledSlider.Configuration.S
            }
        }
    }
}