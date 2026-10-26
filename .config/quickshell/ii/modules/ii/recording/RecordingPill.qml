import QtQuick
import Quickshell
// GlobalShortcut is declared in Quickshell.Hyprland (it registers with the
// compositor's global shortcut registry) -- without this import it resolves
// to "GlobalShortcut is not a type" and the shell refuses to load.
import Quickshell.Hyprland
import Quickshell.Wayland
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

/**
 * The recording control box -- the floating half of SUPER+S record mode and
 * SUPER+R.
 *
 * WHAT IT IS. A small capsule that exists only while something is recording:
 * a live dot, the state word, the elapsed clock, and two buttons. Pause (or
 * play, when paused) and stop. That is the whole interface, on purpose -- the
 * point of it is to be reachable without covering the thing being recorded,
 * and every extra control is more of the frame it is sitting in.
 *
 * WHERE IT SITS. Against the edge of the area being recorded, not in a corner of
 * the screen: above it when there is room, below it when there is not, and
 * inside its top-right corner only when the region leaves nowhere else to go
 * (fullscreen). The rule behind the order is that the box is OUTSIDE the
 * captured rect whenever possible -- anything inside it is recorded into the
 * clip for its whole length. Every candidate is clamped to the screen, so a
 * region at the very edge of the display can never park the box off it. (See
 * `place()` below.)
 *
 * WHY IT IS NOT CLICK-THROUGH. The box needs two buttons, so its surface takes
 * the pointer -- but the surface is sized to the capsule and nothing else, so
 * the rest of the screen is untouched. No keyboard focus: a recording must not
 * steal typing.
 *
 * SUPER+R still toggles the whole thing (it is bound in `GlobalShortcut`
 * below); the box is the visible half, and it is the only place pause lives,
 * because a shortcut per control would be a keyboard map nobody asked for.
 */
Scope {
    id: root

    // Touch the service so it exists from startup: a QML singleton is only
    // created on first use, and its IPC handler lives there.
    readonly property bool serviceAlive: QuickRecord.recording

    GlobalShortcut {
        name: "recorderToggle"
        description: "Quick record: start or stop the screen recording"
        onPressed: QuickRecord.toggle()
    }

    RecordingPillWindow {}
    // The frame around what is being captured. Its own file: it is a Variants
    // over the screens (one surface per monitor), and the box above is a single
    // window on the screen the recording lives on.
    RecordingRegion {}

    component RecordingPillWindow: PanelWindow {
        id: win

        readonly property bool show: QuickRecord.recording
        // Kept mapped through the closing animation, then released.
        visible: root.show || win.hideAnim > 0.001
        // The screen the recording is ON, not the first one in the list: a
        // region recorded on a second monitor must not have its box and frame
        // drawn on the primary one.
        screen: {
            const r = QuickRecord.region;
            if (r && r.w > 0) {
                const cx = r.x + r.w / 2, cy = r.y + r.h / 2;
                for (let i = 0; i < Quickshell.screens.length; i++) {
                    const s = Quickshell.screens[i];
                    if (cx >= s.x && cx < s.x + s.width
                            && cy >= s.y && cy < s.y + s.height) return s;
                }
            }
            return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
        }
        color: "transparent"
        exclusiveZone: -1
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "quickshell:recordingPill"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        // Anchored to the top-left and moved by margins, which is how a
        // PanelWindow can sit at a computed point: `place()` returns the offset
        // from this window's own screen origin.
        anchors {
            top: true
            left: true
        }

        readonly property real screW: win.screen?.width ?? 0
        readonly property real screH: win.screen?.height ?? 0
        readonly property real pillW: pill.width
        readonly property real pillH: pill.height
        readonly property int gap: 10
        readonly property int edgePad: 12

        readonly property var spot: win.place()

        /**
         * The corner of the screen nearest the recording, in this surface's
         * coordinates.
         *
         * The order is the whole design:
         *   1. above the region, right-aligned to it      (outside the clip)
         *   2. below it, if the top of the screen is in the way  (outside)
         *   3. inside its top-right corner, under the bar (no room outside)
         *   4. the old top-right corner, when no region is known at all
         *
         * "Not outside of the screen in case the video area is the entire
         * sceen" is the reason for the clamps on every candidate: the box may be
         * anywhere near the area, but never off the display.
         */
        function place() {
            const margin = win.edgePad;
            const maxX = Math.max(margin, win.screW - win.pillW - margin);
            const maxY = Math.max(margin, win.screH - win.pillH - margin);
            const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

            const r = QuickRecord.region;
            if (r && r.w > 0 && r.h > 0 && win.screW > 0) {
                const rx = r.x - (win.screen?.x ?? 0);
                const ry = r.y - (win.screen?.y ?? 0);
                const rightAligned = rx + r.w - win.pillW;

                const above = ry - win.pillH - win.gap;
                if (above >= margin)
                    return { x: clamp(rightAligned, margin, maxX), y: above };

                const below = ry + r.h + win.gap;
                if (below <= maxY)
                    return { x: clamp(rightAligned, margin, maxX), y: below };

                return {
                    x: clamp(rx + r.w - win.pillW - margin, margin, maxX),
                    y: clamp(ry + Appearance.sizes.barHeight + win.gap, margin, maxY)
                };
            }

            // No region known: the corner it has always used, below the bar so
            // it collides with neither island of it.
            return { x: maxX, y: Appearance.sizes.barHeight + win.gap };
        }

        property real hideAnim: 0
        Behavior on hideAnim {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
        }
        Connections {
            target: win
            function onShowChanged() { win.hideAnim = win.show ? 1 : 0 }
        }

        margins {
            top: Math.round(win.spot.y)
            left: Math.round(win.spot.x)
        }

        // The surface sizes to its content's IMPLICIT size (an explicit width
        // alone leaves the window at the 100x100 default), so the capsule
        // states both.
        implicitWidth: pill.width
        implicitHeight: pill.height

        Rectangle {
            id: pill
            readonly property bool paused: QuickRecord.paused
            readonly property color accent: paused ? Appearance.colors.colTertiary : Appearance.colors.colError

            implicitWidth: row.implicitWidth + 24
            implicitHeight: 38
            width: implicitWidth
            height: implicitHeight
            radius: height / 2
            // OPAQUE, from the bar's own tokens, not a tinted wash. The first
            // version was `transparentize(accent, 0.86)`, which measured
            // unreadable the moment the box landed over a bright window: the
            // tab strip showed straight through the clock and the two glyphs.
            // A control surface has to be legible over ANY content -- that is
            // the point of floating above it -- so the fill is the bar's solid
            // material and the recording state speaks through the border, the
            // dot and the word instead of through transparency.
            // colLayer0 is the window surface itself -- dark in a dark theme,
            // light in a light one -- and colOnLayer0 is its ink, so the box
            // stays legible in both. The accent only tints it (a hint of red,
            // a hint of the paused colour) and owns the border.
            color: ColorUtils.mix(accent, Appearance.colors.colLayer0Base, paused ? 0.12 : 0.16)
            border.width: 1
            border.color: ColorUtils.transparentize(accent, paused ? 0.35 : 0.25)

            Behavior on color {
                ColorAnimation { duration: 160 }
            }
            Behavior on border.color {
                ColorAnimation { duration: 160 }
            }

            opacity: win.hideAnim
            scale: 0.9 + 0.1 * win.hideAnim
            transformOrigin: Item.TopRight

            Row {
                id: row
                anchors.centerIn: parent
                spacing: 8

                // The dot is the clock's heartbeat: it pulses while frames are
                // going in, and holds perfectly still while paused -- a paused
                // recording that still pulses would say "capturing" with the
                // most visible part of the box.
                Item {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 10
                    height: 10

                    Rectangle {
                        anchors.fill: parent
                        radius: 5
                        color: pill.accent
                        opacity: pill.paused ? 1 : 0
                    }

                    Rectangle {
                        anchors.fill: parent
                        radius: 5
                        color: pill.accent
                        visible: !pill.paused
                        SequentialAnimation on opacity {
                            running: win.show && !pill.paused
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.25; duration: 650; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1.0; duration: 650; easing.type: Easing.InOutSine }
                        }
                    }
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: pill.paused ? Translation.tr("PAUSED") : Translation.tr("REC")
                    font.pixelSize: Appearance.font.pixelSize.smallie
                    font.weight: Font.DemiBold
                    font.letterSpacing: 0.6
                    color: pill.paused ? Appearance.colors.colOnLayer1 : Appearance.colors.colOnLayer0
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: QuickRecord.clock(QuickRecord.elapsed)
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.smallie
                    color: Appearance.colors.colOnLayer0
                }


                // A hairline instead of a gap: the clock is information, the
                // two glyphs are controls, and they should not read as one row
                // of text.
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 1
                    height: 16
                    color: ColorUtils.transparentize(pill.accent, 0.7)
                }

                RecordingControlButton {
                    anchors.verticalCenter: parent.verticalCenter
                    icon: pill.paused ? "play_arrow" : "pause"
                    tooltip: pill.paused ? Translation.tr("Resume") : Translation.tr("Pause")
                    onClicked: QuickRecord.togglePause()
                }

                RecordingControlButton {
                    anchors.verticalCenter: parent.verticalCenter
                    icon: "stop"
                    tooltip: Translation.tr("Stop and save")
                    tint: Appearance.colors.colError
                    onClicked: QuickRecord.stop()
                }
            }
        }
    }
}
