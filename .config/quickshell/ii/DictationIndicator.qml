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
 * The dictation tell for a screen the bar is not showing on.
 *
 * Holding SUPER to dictate normally says so in the bar's own pill (NowBar's
 * dictation tab). A fullscreen app is exactly where that question matters --
 * "is this thing hearing me, and is it working on the words?" -- and it is
 * exactly where the bar is out of the way, so the answer used to be nothing at
 * all: the microphone was live, the spinner was turning, and the only sign of
 * it was on a screen edge hidden behind the app.
 *
 * So while a dictation is live on a covered screen, this pill drops out of the
 * top edge and says the same thing the bar pill says, in words as well as in
 * glyphs: "Listening…" while it records, "Transcribing…" while whisper works,
 * with the live meter and the language it recognised.
 *
 * Overlay layer, empty mask, no exclusive zone: it must draw above the
 * fullscreen client, and it must never take a click, a key or the cursor from
 * it. The pill is centred by a full-width window rather than by anchoring,
 * because a layer-shell surface has no horizontal-centre anchor.
 *
 * WHEN it belongs on screen is the one thing this got wrong before, so the rule
 * is stated twice, from both authorities:
 *
 *   * a real fullscreen window (HyprlandData, `fullscreen == 2` -- the same
 *     reading Bar.qml trusts, and NOT the Quickshell toplevel model, which was
 *     measured reporting the wrong thing in both directions on this machine);
 *   * or the bar saying it is not on screen, from the file it already publishes
 *     for the compositor's gestures (ii-bar-visible.json). That covers the
 *     other way the bar leaves -- auto-hide, and a window floated over the
 *     monitor by SUPER+F, where `fullscreen` is 0 and only the geometry says
 *     the screen is covered.
 *
 * Either one is enough, so a compositor state that settles late can never leave
 * a live dictation with no tell anywhere.
 */
// Everything that watches the bar lives OUTSIDE Variants: Variants instantiates
// its delegate once per screen, so a FileView or Timer declared next to the
// PanelWindow inside it is a delegate candidate rather than something that runs.
Scope {
    id: root

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
    // at the release is the one moment this delay would show: the bar's pill
    // slides away with the bar and the drop-down may not take over for up to
    // one poll. A tenth of a second is not a gap.
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
            if (Math.abs(Date.now() / 1000 - (d.ts ?? 0)) > 10)
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
            // The gap the pill drops out of: the surface starts at the top edge
            // and the pill slides down from behind it, so it reads as coming
            // from the edge of the screen rather than as a card that faded in.
            // The few pixels of margin are what gives the shadow room; flush to
            // the edge it was clipped.
            margins.top: 6
            implicitHeight: pill.height + 10

            readonly property var monitor: Hyprland.monitorFor(win.modelData)
            // By NAME, not by identity: the Hyprland service rebuilds its
            // monitor objects when the monitor list is re-read, so comparing
            // the objects goes false for a beat and the tell then decided this
            // screen was not the focused one and stayed away.
            readonly property bool focused: !!win.monitor
                && Hyprland.focusedMonitor?.name === win.monitor.name

            // A real fullscreen window on THIS monitor, from the compositor's
            // own client list (see the note at the top of the file).
            readonly property bool fullscreenHere: {
                const activeWs = Number(win.monitor?.activeWorkspace?.id);
                if (!Number.isFinite(activeWs))
                    return false;
                const list = HyprlandData.windowList ?? [];
                for (let i = 0; i < list.length; i++) {
                    const c = list[i];
                    if (Number(c?.fullscreen) !== 2) continue;
                    if (c?.hidden) continue;
                    if (Number(c?.workspace?.id) !== activeWs) continue;
                    return true;
                }
                return false;
            }

            readonly property bool covered: fullscreenHere || !root.barOnScreen
            readonly property bool live: Dictation.showing
            // Everything that decides whether this pill belongs on this screen.
            // The animations hang off THIS, not off `live`: entering a
            // fullscreen app while SUPER is already held, or a QML reload
            // mid-dictation, both arrive with the dictation already running.
            readonly property bool wanted: live && focused && covered

            // A warm whisper answers a short dictation in a few hundred
            // milliseconds, so the transcribing half can arrive and leave
            // inside one blink; once the pill has been up it stays long enough
            // to be read.
            readonly property int minShowMs: 700
            property bool shown: false

            onWantedChanged: {
                if (wanted) {
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

            // Keep the surface mapped through the lift, so the pill does not
            // vanish mid-animation.
            visible: shown || pill.opacity > 0.01
            mask: Region { item: null }

            // Travelling wave, exactly like the bar pill's: a still room has a
            // flat level, and a meter that never moves is indistinguishable
            // from a recording that stopped.
            property real wave: 0
            NumberAnimation on wave {
                from: 0
                to: 1
                duration: 1100
                loops: Animation.Infinite
            }

            // Put the pill where `shown` says it belongs, with no animation.
            // `shown` is a flag, not a promise about the pixels: a hide undone
            // immediately makes two animations write the same properties and
            // the slower one's values stick (measured once before as the pill
            // sitting mapped at y 0 with opacity 0 -- an invisible tell).
            function settleShown() {
                liftAnim.stop();
                dropAnim.stop();
                pill.y = 0;
                pill.opacity = 1;
            }

            // A dictation that begins while the pill is flagged up but not
            // actually up gets placed: nothing else would put it back, because
            // neither `shown` nor `wanted` changes.
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
                    liftAnim.stop();
                    dropAnim.restart();
                } else {
                    dropAnim.stop();
                    liftAnim.restart();
                }
            }

            // The state a freshly created surface starts in, including the case
            // where the dictation is already live at creation: there is no
            // animation to ride, so it is simply placed where it belongs.
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
                implicitWidth: content.implicitWidth + 26
                implicitHeight: 36
                radius: Appearance.rounding.normal
                color: Appearance.colors.colBackgroundSurfaceContainer

                Row {
                    id: content
                    anchors.centerIn: parent
                    spacing: 9

                    // The two halves of a dictation, told apart at a glance: a
                    // live microphone while it records, a turning mark while the
                    // words are being made. The bar pill draws the same pair.
                    Item {
                        anchors.verticalCenter: parent.verticalCenter
                        implicitWidth: 18
                        implicitHeight: 18

                        MaterialSymbol {
                            anchors.centerIn: parent
                            visible: !Dictation.busy
                            text: "mic"
                            iconSize: 18
                            fill: 1
                            color: Appearance.colors.colPrimary
                        }

                        MaterialSymbol {
                            anchors.centerIn: parent
                            visible: Dictation.busy
                            text: "progress_activity"
                            iconSize: 18
                            color: Appearance.colors.colPrimary

                            RotationAnimation on rotation {
                                running: Dictation.busy
                                from: 0
                                to: 360
                                duration: 900
                                loops: Animation.Infinite
                                direction: RotationAnimation.Clockwise
                            }
                        }
                    }

                    // The meter belongs to the recording half only: while the
                    // words are being transcribed the microphone is already
                    // closed, and bars that sit still read as a meter that has
                    // stopped.
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
                                // Same shape of formula as the bar's pill, and
                                // the same reason it is inline: a helper call in
                                // this binding did not re-run when
                                // Dictation.level changed, while the property
                                // reads do.
                                height: {
                                    const wobble = 0.5 + 0.5 * Math.sin((win.wave + index * 0.16) * Math.PI * 2);
                                    const base = 0.12 + 0.88 * Dictation.level;
                                    return 4 + 12 * Math.min(1, base * (0.82 + 0.18 * wobble));
                                }
                                color: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.15)
                            }
                        }
                    }

                    // In words. A glyph alone is a light on the machine; what was
                    // missing over a fullscreen app was knowing whether it is
                    // still listening or already working on the sentence.
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        font.pixelSize: Appearance.font.pixelSize.smallie
                        color: Appearance.colors.colOnSurface
                        text: Dictation.busy
                            ? Translation.tr("Transcribing…")
                            : Translation.tr("Listening… release to type")
                    }

                    // Which language it is actually hearing, as soon as whisper
                    // has decided. Nothing before that: a guess drawn from the
                    // previous dictation would be worse than blank.
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: Dictation.languageLabel !== ""
                        implicitWidth: langText.implicitWidth + 10
                        implicitHeight: 16
                        radius: 5
                        color: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.84)

                        StyledText {
                            id: langText
                            anchors.centerIn: parent
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            font.weight: 600
                            color: Appearance.colors.colPrimary
                            text: Dictation.languageLabel
                        }
                    }
                }
            }
        }
    }
}
