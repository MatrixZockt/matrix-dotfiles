import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import QtQuick
import Quickshell
import Quickshell.Wayland

/**
 * The frame around what is being recorded -- the "this box is going into the
 * file" marker, in the same calm red the control box uses (asked for
 * 2026-10-22: "show the space that its recording with the area and border
 * being the same nice calm red color as the video pause resume etc menu").
 *
 * WHERE THE PIXELS GO, AND WHY IT IS ALL OUTSIDE. gpu-screen-recorder captures
 * a rectangle of the COMPOSITED output, so anything drawn inside that rectangle
 * is baked into the clip -- forever, for every frame. A tinted "area" inside the
 * frame would hand back every recording with a pink cast, and a border drawn
 * half-in would leave a red line on the edge of the video. So the marker is
 * drawn entirely OUTSIDE the captured rect: the core line's inner edge sits
 * exactly on the boundary, and the soft band sits further out. The frame then
 * marks the space without ever becoming part of it. On a fullscreen recording
 * there is no outside and the marker is simply clipped away -- which is the
 * honest result: there is no room on screen for a frame that is not also in the
 * file.
 *
 * TWO BANDS, NO BLUR. A 2 px line for the boundary (it has to be crisp: it is a
 * fact about pixels) and a 4 px band a few pixels further out at low alpha for
 * the "area" the request asked for. No shadow, no glow -- the whole point of a
 * marker is that you can tell where it ends.
 *
 * PAUSED FOLLOWS THE BOX. The control box turns tertiary while paused; the frame
 * turns with it, so the two never disagree about the state of the recording.
 *
 * Contract, same as the veil and the snip: Overlay layer, empty input region
 * (it eats no click), no keyboard focus, ExclusionMode.Ignore. It is a marker,
 * not a target.
 */
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: frame

        required property var modelData
        screen: modelData

        WlrLayershell.namespace: "quickshell:recordingRegion"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        exclusiveZone: 0

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        color: "transparent"
        mask: Region { item: null }

        // The recorded rect, in this surface's own coordinates. `?? 0` rather
        // than a null check everywhere: with no region the whole item is
        // invisible, so a zero-size rectangle costs nothing.
        readonly property real rx: (QuickRecord.region?.x ?? 0) - (frame.modelData?.x ?? 0)
        readonly property real ry: (QuickRecord.region?.y ?? 0) - (frame.modelData?.y ?? 0)
        readonly property real rw: QuickRecord.region?.w ?? 0
        readonly property real rh: QuickRecord.region?.h ?? 0
        readonly property bool hasArea: QuickRecord.recording && rw > 0 && rh > 0
        readonly property bool onThisScreen: hasArea
            && rx + rw > 0 && ry + rh > 0
            && rx < (frame.modelData?.width ?? 0) && ry < (frame.modelData?.height ?? 0)

        readonly property color accent: QuickRecord.paused
            ? Appearance.colors.colTertiary : Appearance.colors.colError

        visible: frame.onThisScreen

        // A PanelWindow is a WINDOW, not an Item -- it has no `opacity`, so the
        // fade lives on this Item instead. (Assigning `opacity` to the window
        // itself is a load-time failure that takes the whole panel family with
        // it: "Cannot assign to non-existent property opacity".)
        Item {
            id: content
            anchors.fill: parent
            opacity: 0

            Behavior on opacity {
                NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
            }

            Connections {
                target: frame
                // A frame that snaps on reads as an error dialog; this is a
                // state, so it fades in like one.
                function onVisibleChanged() {
                    content.opacity = frame.visible ? 1 : 0;
                }
            }
            Component.onCompleted: content.opacity = frame.visible ? 1 : 0

            // ── The area ──────────────────────────────────────────────────
            // Four pixels further out, at 15 %: the "where it is" wash.
            // Entirely outside the capture (it starts 7 px out), so it cannot
            // tint a clip.
            Rectangle {
                x: Math.round(frame.rx - 7)
                y: Math.round(frame.ry - 7)
                width: Math.round(frame.rw) + 14
                height: Math.round(frame.rh) + 14
                radius: 11
                color: "transparent"
                border.width: 4
                border.color: ColorUtils.transparentize(frame.accent, 0.85)

                Behavior on border.color {
                    ColorAnimation { duration: 160 }
                }
            }

            // ── The boundary ──────────────────────────────────────────────
            // 2 px, one pixel CLEAR of the captured edge. Not on it: an edge
            // exactly at rx leaves a single antialiased pixel inside the rect --
            // measured on this 1.5x output, the first column of a 900x600 take
            // came back #2B2629 instead of the background's #191A1F, i.e. a red
            // hairline down the side of every clip. One pixel of gap costs
            // nothing to look at (it is over content that is not recorded) and
            // guarantees the file is untouched.
            Rectangle {
                x: Math.round(frame.rx - 3)
                y: Math.round(frame.ry - 3)
                width: Math.round(frame.rw) + 6
                height: Math.round(frame.rh) + 6
                radius: 7
                color: "transparent"
                border.width: 2
                border.color: ColorUtils.transparentize(frame.accent, 0.1)

                Behavior on border.color {
                    ColorAnimation { duration: 160 }
                }
            }
        }
    }
}
