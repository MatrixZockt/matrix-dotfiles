pragma ComponentBehavior: Bound
import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

// One screen's colour-picking surface: a frozen grab of that output, a
// crosshair, and a pill that shows the hex/rgba of whatever the crosshair is
// over. Alt+X (or a click, or Enter) copies the hex and closes; Esc closes
// without copying. hyprpicker used to be this, and was never installed.
//
// The recent-colours card is drawn in this window too (bottom-left, see
// ColorPickerHistory.qml), because SUPER + C opens the crosshair AND the card
// as one thing: the last few picks are offered the moment the picker appears,
// instead of after another colour has already been copied.
PanelWindow {
    id: root
    visible: false
    color: "transparent"
    WlrLayershell.namespace: "quickshell:colorPicker"
    WlrLayershell.layer: WlrLayer.Overlay
    // Exclusive like RegionSelection: a modal picker owns the keyboard for the
    // second it exists, so Esc and Alt+X reach THIS surface and not whatever
    // window is underneath.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore
    anchors {
        left: true
        right: true
        top: true
        bottom: true
    }

    signal dismiss()
    // Emitted with the copied hex when a pick is completed (never on Esc), so
    // the scope can add it to the recent-colours list.
    signal picked(string hex)

    // The recent picks, newest first, and whether this output is the one that
    // gets to show the card. Both are supplied by the scope (ColorPicker.qml):
    // every screen runs a surface, but only the output the picker was opened
    // from should grow a card.
    property var historyColors: []
    property bool showHistory: false

    // Unique per open ON PURPOSE. With one fixed filename the Image keeps the
    // first freeze for the rest of the session (QML caches file: URLs by URL),
    // so every later open showed -- and sampled -- the screen as it was the
    // first time. That made the picker return the same colours over and over.
    readonly property real grabToken: Date.now()
    readonly property string grabPath: `${Directories.screenshotTemp}/picker-${screen.name}-${grabToken}.png`

    // The readouts: hex is what gets copied, rgba is display-only. A screenshot
    // is always opaque so the alpha reads 1 -- the channel is shown because the
    // pill promises both.
    property color pickedColor: "black"
    property string pickedHex: "#000000"
    property string pickedRgba: "rgba(0, 0, 0, 1)"
    property bool pickedValid: false

    // Last crosshair position in SURFACE (logical) coords, kept on the root so
    // the sampler's first paint can answer with a swatch instead of waiting
    // for the pointer to move.
    property real lastX: -1
    property real lastY: -1
    // The sampled pixel's position inside the grab, in PHYSICAL pixels -- what
    // the loupe zooms around.
    property int sampleIx: -1
    property int sampleIy: -1

    // Grab pixels per surface unit: the grab is in PHYSICAL pixels (grim -o
    // writes the output buffer) while the pointer arrives in logical ones, so
    // this is what turns a cursor position into a grab pixel. Measured from
    // the two sizes rather than taken from the window's device pixel ratio,
    // which reads 2 here while the compositor scales 2560 physical pixels into
    // the surface' 1707 logical ones (1.4997) -- believing the 2 put the read
    // an inch from the crosshair.
    readonly property real grabScale: shot.width > 0 && root.width > 0 ? shot.width / root.width : 1

    // Point the crosshair at a surface position and start a read.
    //
    // The cursor arrives in surface units and the grab is in physical pixels,
    // so the grab pixel under the crosshair is the cursor times `grabScale`.
    // That index is also what the loupe zooms around, which is why the loupe
    // and the pill now always describe the same pixel.
    function sample(lx, ly) {
        if (shot.status !== Image.Ready || lx < 0 || ly < 0) return;
        // The pixel under the crosshair, in the grab's own pixels -- also what
        // the loupe zooms around.
        const ix = Math.min(shot.width - 1, Math.max(0, Math.round(lx * root.grabScale)));
        const iy = Math.min(shot.height - 1, Math.max(0, Math.round(ly * root.grabScale)));
        root.sampleIx = ix;
        root.sampleIy = iy;
        // The read itself happens in the canvas' paint handler, which fills
        // that canvas with this one pixel (see the Canvas below) -- so it has
        // to be repainted before the colour is known.
        sampler.requestPaint();
        // The loupe follows every hover move -- the pixels under the cursor
        // are the thing being picked, so it must repaint with them.
        loupe.requestPaint();
    }

    // The colour of one grab pixel, taken from the readback canvas once it has
    // painted. `sampler` holds nothing BUT that pixel, so this is the only
    // colour in it and the read cannot land on a neighbour.
    function applySampleColor(r, g, b) {
        root.pickedColor = Qt.rgba(r / 255, g / 255, b / 255, 1);
        root.pickedHex = "#" + [r, g, b].map(v => v.toString(16).padStart(2, "0")).join("").toUpperCase();
        root.pickedRgba = `rgba(${r}, ${g}, ${b}, 1)`;
        root.pickedValid = true;
    }

    function finish(copyHex) {
        if (copyHex && root.pickedValid) {
            Quickshell.clipboardText = root.pickedHex;
            root.picked(root.pickedHex);
        }
        Quickshell.execDetached(["rm", "-f", root.grabPath]);
        root.dismiss();
    }

    // A colour taken from the recent-colours card instead of from the screen.
    // It reaches the clipboard by the same exit as a pick (and closes the
    // picker on the way out), so nothing is left up for a second dismissal.
    // Not reported as `picked`: the card is a list of PICKS, and copying from
    // it again should not reshuffle the list.
    function copyFromHistory(hex) {
        Quickshell.clipboardText = hex;
        root.finish(false);
    }

    // Freeze first, surface second: the grab must not contain the pill (nor
    // the bar menu or sidebar that may have opened it), so grim runs a beat
    // after the window exists and the window only goes visible on success.
    // Same grim one-liner as RegionSelector.screenshotFullScreen.
    Component.onCompleted: grabDelay.start()

    Timer {
        id: grabDelay
        interval: 200
        onTriggered: grabProcess.running = true
    }

    Process {
        id: grabProcess
        readonly property string shellCommand:
            `mkdir -p '${Directories.screenshotTemp}'` +
            // Sweep the previous opens' grabs: they are only needed until the
            // window that took them is gone, and nothing else deletes them if
            // a reload tears the window down mid-pick.
            ` && rm -f '${Directories.screenshotTemp}'/picker-${screen.name}-*.png` +
            ` && grim -o '${screen.name}' '${root.grabPath}'`
        command: ["bash", "-c", shellCommand]
        onExited: (exitCode) => {
            if (exitCode === 0) {
                shot.source = Qt.resolvedUrl(root.grabPath);
                root.visible = true;
                return;
            }
            // A failed grab on a SECONDARY output must not take the picker
            // down on the one under the cursor (an output can refuse
            // screencopy while another is fine). Only the focused monitor's
            // surface gets to report the failure and dismiss.
            console.warn(`[Color Picker] grab failed for ${screen.name} with exit code ${exitCode}.`);
            if (Hyprland.monitorFor(screen)?.name === Hyprland.focusedMonitor?.name) {
                StatusSignal.blink(Appearance.colors.colError, Translation.tr("Color picker failed"));
                root.dismiss();
            }
        }
    }

    Image {
        id: shot
        visible: false
        // NOTE: caching stays ON. The fresh filename above is what prevents a
        // stale freeze; turning the cache off instead starves the Canvas
        // readback (drawImage on an uncached Image paints nothing, and every
        // sample reads transparent black).
        onStatusChanged: {
            if (status === Image.Ready) sampler.requestPaint();
        }
    }

    // The readback: ONE grab pixel, blown up to fill a small canvas, then read
    // back with `getImageData`. Offstage (opacity 0) because a canvas that is
    // not rendered never paints, and then there would be nothing to read; QML
    // offers no other way to read screen pixels, and this beats spawning grim
    // on every mouse move.
    //
    // Why one pixel instead of the whole grab: a canvas' readback coordinates
    // are NOT its drawable pixels on a scaled display. Measured on this
    // machine, `drawImage` and `getImageData` disagree by roughly 1.5x, so a
    // canvas holding the whole grab reported the colour of a pixel half a
    // screen away -- the pill's swatch and hex did not match the pixel under
    // the crosshair, while the loupe (which draws from the image directly) was
    // right. Every fix for that was an index correction that broke again at
    // the next scale factor.
    //
    // A canvas that contains exactly one colour needs no coordinate maths: the
    // 1x1 source pixel is stretched across the whole canvas, so ANY index in
    // it -- including (0, 0) -- is that pixel. The read is then exact by
    // construction, at any display scale.
    Canvas {
        id: sampler
        width: 16
        height: 16
        canvasSize: Qt.size(16, 16)
        opacity: 0
        onPaint: {
            if (root.sampleIx < 0 || root.sampleIy < 0)
                return;
            const ctx = sampler.getContext("2d");
            ctx.imageSmoothingEnabled = false;
            ctx.clearRect(0, 0, sampler.width, sampler.height);
            // The grab pixel under the crosshair, stretched over the canvas.
            ctx.drawImage(shot, root.sampleIx, root.sampleIy, 1, 1,
                          0, 0, sampler.width, sampler.height);
            const d = ctx.getImageData(0, 0, 1, 1).data;
            root.applySampleColor(d[0], d[1], d[2]);
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.CrossCursor
        focus: true
        acceptedButtons: Qt.LeftButton

        onPositionChanged: (mouse) => {
            root.lastX = mouse.x;
            root.lastY = mouse.y;
            root.sample(mouse.x, mouse.y);
        }
        onPressed: (mouse) => {
            root.lastX = mouse.x;
            root.lastY = mouse.y;
            root.sample(mouse.x, mouse.y);
            root.finish(true);
        }
        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Escape) {
                root.finish(false);
                event.accepted = true;
            } else if (event.key === Qt.Key_X && (event.modifiers & Qt.AltModifier)) {
                root.finish(true);
                event.accepted = true;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.finish(true);
                event.accepted = true;
            }
        }
    }

    // The pill: a loupe of the pixels under the crosshair, then swatch + hex +
    // rgba, riding just below-right of the cursor and flipped at the screen
    // edges so it never covers the pixel it is describing. Same primary pill as
    // the region selector's CursorGuide.
    Rectangle {
        id: pill
        readonly property real edge: 8
        readonly property real pointerGap: 24
        x: Math.min(Math.max(mouseArea.mouseX + pointerGap, edge), root.width - width - edge)
        y: Math.min(Math.max(mouseArea.mouseY + pointerGap, edge), root.height - height - edge)
        visible: root.pickedValid

        property real padding: 12
        implicitHeight: loupeBox.height + padding * 2
        implicitWidth: pillRow.implicitWidth + padding * 2

        topLeftRadius: 8
        bottomLeftRadius: 16
        bottomRightRadius: 16
        topRightRadius: 16
        color: Appearance.colors.colPrimary

        Behavior on implicitWidth {
            animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
        }

        Row {
            id: pillRow
            anchors.centerIn: parent
            spacing: 12

            // The loupe: a 6x zoom of the 15x15 physical pixels around the
            // crosshair, nearest-neighbour so single pixels stay square and
            // countable, with the picked pixel boxed dead centre. This is what
            // makes aiming at ONE pixel possible -- the swatch tells you the
            // colour, the loupe tells you which pixel you are on.
            Rectangle {
                id: loupeBox
                width: 90
                height: 90
                radius: 8
                clip: true
                color: "black"

                Canvas {
                    id: loupe
                    anchors.fill: parent
                    readonly property int sourcePixels: 15
                    readonly property real pixelSize: width / sourcePixels

                    onPaint: {
                        const ctx = loupe.getContext("2d");
                        const half = Math.floor(sourcePixels / 2);
                        // Window centred on the picked pixel, clamped so it
                        // never runs off the grab -- a cursor at a screen edge
                        // still gets a full loupe, just off-centre.
                        const sx = Math.min(Math.max(root.sampleIx - half, 0), shot.width - sourcePixels);
                        const sy = Math.min(Math.max(root.sampleIy - half, 0), shot.height - sourcePixels);
                        ctx.imageSmoothingEnabled = false;
                        ctx.clearRect(0, 0, width, height);
                        ctx.drawImage(shot, sx, sy, sourcePixels, sourcePixels, 0, 0, width, height);
                        // The picked pixel, boxed in black and white so it
                        // reads on any colour underneath.
                        const bx = (root.sampleIx - sx) * pixelSize;
                        const by = (root.sampleIy - sy) * pixelSize;
                        ctx.lineWidth = 2;
                        ctx.strokeStyle = "#000000";
                        ctx.strokeRect(bx - 1, by - 1, pixelSize + 2, pixelSize + 2);
                        ctx.lineWidth = 1;
                        ctx.strokeStyle = "#ffffff";
                        ctx.strokeRect(bx, by, pixelSize, pixelSize);
                    }
                }
            }

            // The readouts, vertically centred against the loupe.
            Item {
                width: textColumn.width
                height: loupeBox.height

                Column {
                    id: textColumn
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6

                    Row {
                        spacing: 8

                        // Swatch outlined so a white pick still reads against
                        // the pill.
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 18
                            height: 18
                            radius: 5
                            color: root.pickedColor
                            border.width: 2
                            border.color: Appearance.colors.colOnPrimary
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            color: Appearance.colors.colOnPrimary
                            text: root.pickedHex
                        }
                    }

                    StyledText {
                        color: Appearance.colors.colOnPrimary
                        opacity: 0.75
                        text: root.pickedRgba
                    }
                }
            }
        }
    }

    // The recent picks, bottom-left, over the freeze frame. Declared after the
    // full-screen picker area so it sits on top of it and its rows get their
    // clicks before the picker sees them.
    ColorPickerHistory {
        visible: root.showHistory && root.historyColors.length > 0
        anchors {
            left: parent.left
            bottom: parent.bottom
            margins: 18
        }
        colors: root.historyColors
        onCopyColor: (hex) => root.copyFromHistory(hex)
    }
}
