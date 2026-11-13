import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland

/**
 * The recording tell for a fullscreen screen.
 *
 * Holding SUPER to dictate normally says so in the bar's pill (`NowBar`'s
 * dictation tab) -- but over a fullscreen app there is no bar, and a fullscreen
 * app is exactly where "is this thing actually hearing me?" matters: a video
 * playing, a game with your voice in it, a call. So while a dictation is live
 * over a fullscreen window, this tiny surface drops out of the top edge and
 * shows the same two things the bar pill shows: a microphone glyph and a meter
 * that moves with the room.
 *
 * It is deliberately ONLY that. No transcript, no words, no buttons. A dictation
 * leaves nothing behind (see dictate.sh), and this is not a notification to read
 * -- it is a light on the machine.
 *
 * Overlay layer with an empty mask, like StatusTell: it must draw over the
 * fullscreen client, and it must never eat a click, a key or the cursor. The
 * pill is centred by a full-width window rather than by anchoring, since a
 * layer-shell surface has no horizontal-centre anchor.
 *
 * Never alongside the bar's own pill: while SUPER is held the bar is up and
 * showing it, and two meters for one microphone is noise. The bar goes away
 * with the key, so the drop-down picks the tell up there and keeps it for the
 * whole dictation -- including the transcribing half, which is the part that
 * used to vanish with the bar.
 */
// Everything that watches the bar lives OUTSIDE Variants: Variants instantiates
// its delegate once per screen, so a FileView or Timer declared next to the
// PanelWindow inside it is a delegate candidate rather than something that runs
// -- and the tell then never appeared, because barOnScreen never changed.
Scope {
    id: root

    // Whether the bar is actually on screen, straight from the bar: it publishes
    // `visible` (its own `!hideBySlide`) to this file for the shell's gestures,
    // refreshes it every 2s while it is up, and writes it again the moment that
    // changes. Asking this instead of deriving it is what makes "the bar is
    // away" and "the drop-down should show" the same question -- `barHidden`
    // only tracks fullscreen, and this desktop has desktops where that reading
    // lags behind the bar itself, which is a tell that never appeared.
    readonly property string barVisiblePath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp")
        + "/ii-bar-visible.json"
    property bool barOnScreen: true

    FileView {
        id: barVisible
        path: root.barVisiblePath
        watchChanges: false
        printErrors: false
    }

    // Fast while a dictation is live, slow the rest of the time. The handover
    // at the release is the one moment this delay is visible: the bar's pill
    // slides away with the bar and the drop-down may not take over for up to
    // one poll, so the screen showed NOTHING in between -- read as "it just
    // disappeared". A tenth of a second is not a gap.
    Timer {
        interval: Dictation.showing ? 100 : 400
        repeat: true
        running: true
        onTriggered: {
            barVisible.reload();
            root.ingestBar(barVisible.text());
        }
    }

    function ingestBar(raw) {
        if (!raw)
            return;
        try {
            const d = JSON.parse(raw);
            // Fresh means the bar has spoken recently; a stale file is not a
            // reason to change anything, because the last thing it said was
            // said when the bar went away.
            if (Math.abs(Date.now() / 1000 - (d.ts ?? 0)) > 5)
                return;
            root.barOnScreen = d.visible === true;
        } catch (e) {
            // Mid-write; the next poll is whole.
        }
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win
            required property var modelData
            screen: modelData
            color: "transparent"

            WlrLayershell.namespace: "quickshell:dictationIndicator"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            exclusionMode: ExclusionMode.Ignore
            exclusiveZone: 0

            anchors {
                top: true
                left: true
                right: true
            }
            // The gap the pill drops out of. The surface starts at the top edge and
            // the pill slides down from behind it, so it reads as coming from the
            // screen's edge, not as a card that faded in. The few pixels of margin
            // are what gives the shadow room; flush to the edge it was clipped.
            margins.top: 6
            implicitHeight: pill.height + 10

            readonly property var monitor: Hyprland.monitorFor(win.modelData)
            // By NAME, not by identity. The Hyprland service rebuilds its
            // monitor objects when the monitor list is re-read (a display
            // change, a compositor reload, a fullscreen toggle settling), so
            // `focusedMonitor === monitorFor(screen)` goes false for a beat
            // even though nothing changed -- and the tell then decided this
            // screen was not the focused one and stayed away, which is exactly
            // the "sometimes it does not show" report. A name survives the
            // rebuild.
            readonly property bool focused: !!win.monitor
                && Hyprland.focusedMonitor?.name === win.monitor.name
            // The same reading StatusTell and the desktop pill use for "this screen
            // is covered", so every surface agrees on what fullscreen means.
            readonly property bool covered: Hyprland.workspaces.values.some(ws =>
                ws.monitor === win.monitor && ws.active
                && ws.toplevels.values.some(t => t.wayland?.fullscreen))

            readonly property bool live: Dictation.showing
            // Everything that decides whether the pill belongs on this screen. The
            // animations hang off THIS, not off `live`: entering a fullscreen app
            // while SUPER is already held, or a QML reload mid-dictation, both
            // arrive with the dictation already running, and a pill that only
            // animated on a CHANGE of the live flag stayed invisible through them.
            //
            // Only when the bar is not on screen. Outside fullscreen the bar is
            // always there and its pill is the tell, so the two never overlap; when
            // the bar has stood down -- a fullscreen client paints over it -- this
            // surface is the only tell there is, and it carries the whole dictation
            // (recording and transcribing) by itself.
            readonly property bool wanted: live && focused && !root.barOnScreen

            // A warm whisper server answers a short dictation in a few hundred
            // milliseconds, so the transcribing state can arrive and leave inside a
            // single blink: the pill appeared and was gone again, which reads as a
            // glitch instead of as "it is working". Once it has been up it stays for
            // at least this long, and only hides early if it never had anything to
            // show in the first place.
            readonly property int minShowMs: 900
            property bool shown: false

            onWantedChanged: {
                if (wanted) {
                    // Settled means `shown` was ALREADY true, so no show
                    // animation will run to put the pill back: a new dictation
                    // inside the min-show window inherits the previous one's
                    // flag, and if a hide was mid-flight (or a race left it at
                    // opacity 0) the tell would stay invisible for the whole
                    // hold. Placing it here costs nothing when it is already
                    // in place.
                    const settled = shown;
                    shown = true;
                    minShowTimer.restart();
                    if (settled)
                        settleShown();
                } else if (!minShowTimer.running) {
                    shown = false;
                }
            }

            Timer {
                id: minShowTimer
                interval: win.minShowMs
                repeat: false
                onTriggered: if (!win.wanted) win.shown = false
            }

            // Keep the surface mapped for the duration of the lift, so the pill does
            // not vanish mid-animation.
            visible: shown || pill.opacity > 0.01
            mask: Region { item: null }

            // Travelling wave, exactly like the bar pill's: a still room has a flat
            // level, and a meter that never moves is indistinguishable from a
            // recording that stopped.
            property real wave: 0
            NumberAnimation on wave {
                from: 0
                to: 1
                duration: 1100
                loops: Animation.Infinite
            }

            // Put the pill where "shown" says it belongs, with no animation.
            //
            // `shown` is a flag, not a promise about the pixels. A hide that is
            // undone immediately makes two animations write the same
            // properties, and the slower one's values stick: measured on the
            // recording -> transcribing handover, the pill sat mapped at y 0
            // with opacity 0.00, which is an invisible tell -- the exact thing
            // this file exists to prevent. Anywhere the answer is "it should be
            // up" while it is already flagged up, it is placed rather than
            // animated.
            function settleShown() {
                liftAnim.stop();
                dropAnim.stop();
                pill.y = 0;
                pill.opacity = 1;
            }

            // A dictation that begins while the pill is flagged up but not
            // actually up (the invisible half of a race, or a lift still on its
            // way out) gets placed: the tell has to be there for the whole
            // hold, and nothing else would put it back, because neither `shown`
            // nor `wanted` changes.
            Connections {
                target: Dictation
                function onShowingChanged() {
                    if (Dictation.showing && win.shown && !dropAnim.running
                            && pill.opacity < 0.99)
                        win.settleShown();
                }
            }

            onShownChanged: {
                if (shown) {
                    // The rival first: without this a lift that has just been
                    // started keeps writing y/opacity after the drop begins,
                    // and the last writer wins.
                    liftAnim.stop();
                    dropAnim.restart();
                } else {
                    dropAnim.stop();
                    liftAnim.restart();
                }
            }

            // The state a freshly created surface starts in, including the case
            // above where the dictation is already live at creation: no animation to
            // ride, so it is simply placed where it belongs.
            Component.onCompleted: {
                if (wanted) {
                    shown = true;
                    minShowTimer.restart();
                }
                pill.y = shown ? 0 : -pill.height;
                pill.opacity = shown ? 1 : 0;
            }

            ParallelAnimation {
                id: dropAnim
                NumberAnimation {
                    target: pill
                    property: "y"
                    from: -pill.height
                    to: 0
                    duration: 180
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: [0.15, 1.35, 0.4, 1.0]
                }
                NumberAnimation {
                    target: pill
                    property: "opacity"
                    from: 0
                    to: 1
                    duration: 130
                    easing.type: Easing.OutCubic
                }
            }

            ParallelAnimation {
                id: liftAnim
                NumberAnimation {
                    target: pill
                    property: "y"
                    to: -pill.height
                    duration: 150
                    easing.type: Easing.InCubic
                }
                NumberAnimation {
                    target: pill
                    property: "opacity"
                    to: 0
                    duration: 150
                    easing.type: Easing.InCubic
                }
            }

            StyledRectangularShadow {
                target: pill
                opacity: pill.opacity
            }

            Rectangle {
                id: pill
                anchors.horizontalCenter: parent.horizontalCenter
                y: -height
                opacity: 0
                implicitWidth: content.implicitWidth + 24
                implicitHeight: 36
                radius: Appearance.rounding.normal
                color: Appearance.colors.colBackgroundSurfaceContainer

                Row {
                    id: content
                    anchors.centerIn: parent
                    spacing: 9

                    // Filled mic while the room is being recorded, the waveform
                    // glyph while the words are being worked out: the two halves of
                    // a dictation, told apart without a label.
                    MaterialSymbol {
                        id: glyph
                        anchors.verticalCenter: parent.verticalCenter
                        text: Dictation.busy ? "graphic_eq" : "mic"
                        iconSize: 18
                        fill: 1
                        color: Appearance.colors.colPrimary

                        // Transcribing takes as long as whisper takes -- a few
                        // tenths of a second with the server warm, seconds when the
                        // model is loading -- and a glyph that just sits there is
                        // indistinguishable from a pill that has frozen. A slow
                        // breath is the smallest thing that says "still working".
                        opacity: 1
                        SequentialAnimation {
                            running: Dictation.busy
                            loops: Animation.Infinite
                            onRunningChanged: if (!running) glyph.opacity = 1
                            NumberAnimation {
                                target: glyph
                                property: "opacity"
                                to: 0.45
                                duration: 550
                                easing.type: Easing.InOutQuad
                            }
                            NumberAnimation {
                                target: glyph
                                property: "opacity"
                                to: 1.0
                                duration: 550
                                easing.type: Easing.InOutQuad
                            }
                        }
                    }

                    // The meter belongs to the recording half only: while the words
                    // are being transcribed the microphone is already closed, and
                    // bars that sit still read as a meter that has stopped.
                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2.5
                        visible: Dictation.listening
                        Repeater {
                            model: 5
                            Rectangle {
                                width: 3
                                radius: 1.5
                                anchors.verticalCenter: parent.verticalCenter
                                // Same shape of formula as the bar's pill, and the
                                // same reason it is inline: a helper call in this
                                // binding did not re-run when Dictation.level
                                // changed, while the property reads below do.
                                height: {
                                    const wobble = 0.5 + 0.5 * Math.sin((win.wave + index * 0.16) * Math.PI * 2);
                                    const base = 0.12 + 0.88 * Dictation.level;
                                    return 4 + 12 * Math.min(1, base * (0.82 + 0.18 * wobble));
                                }
                                color: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.15)
                            }
                        }
                    }
                }
            }
        }
    }
}
