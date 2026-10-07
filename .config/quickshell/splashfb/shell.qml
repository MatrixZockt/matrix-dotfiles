//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic

// ── The failsafe indicator ─────────────────────────────────────────────────
//
// WHY THIS IS A SEPARATE CONFIG. `../splash/` is the login backdrop: silent by
// request, because a caption during ordinary startup is noise. That is still
// the right call there, and that file has been left untouched.
//
// But the same file was also being used for SUPER+CTRL+B, where the opposite
// is true. Pressing the failsafe kills the shell on purpose and then waits for
// it to come back, which on this machine measured 8-15 s idle and well over
// 50 s while the box was busy. During that window the screen is Hyprland's
// `misc:background_color`, #0A0A0A.
//
// Measured, and this is the whole bug: the backdrop painted #141414 over that,
// a difference of 10/255 that is invisible across a desk. The splash was
// running, its layer surface was mapped at level 2, its process was alive --
// and the user saw a black screen and no feedback at all. So a backdrop that
// exists to be "not a black flash" cannot also be the thing that tells you
// your desktop is coming back. Hence two configs.
//
// THE TEXT SAYS "RELOADING SHELL" AND NOT "STARTING ii". Those are different
// events and conflating them is what made the original caption read as noise.
// "Starting ii…" belongs to a login, where a caption is describing something
// that is already over. This only ever appears after SUPER+CTRL+B has
// deliberately killed a running desktop, so what the user needs to be told is
// that the kill was received and a replacement is on its way -- otherwise the
// several seconds of empty screen look exactly like the key having done
// nothing, which is the failure this whole mechanism exists to prevent.
//
// WHY THE LOADER IS DRAWN BY HAND. It was a `BusyIndicator`, and with
// QT_QUICK_CONTROLS_STYLE=Basic that paints as a static ring of eight dots. It
// is legible but reads as a stock widget, not as a considered loading state --
// and on a card that exists for a second or two, that is the whole impression.
// The ring below is a dim track plus a bright arc with a fading tail, which is
// what a loading state is expected to look like, and it costs three paths.
//
// THE LOADER IS A SPINNER, NOT A PROGRESS BAR. There is no progress to report:
// what is being waited on is another process, and any fraction here would be
// invented. An indeterminate arc says "working" without claiming to know how
// much is left, which is the only honest thing to draw.
//
// WHY IT IS TRANSPARENT AND BOTTOM-LEFT. Both were asked for, and both are
// better here than the obvious alternative.
//
// Opaque was chosen originally to guarantee the card would read against
// anything, on the reasoning that what is behind it during a reset is an empty
// desktop. That reasoning is wrong in the case that matters: the indicator is
// also raised at the START of a reset, while the desktop is still up and fully
// drawn. An opaque full-screen surface therefore blacks out a working desktop
// for the whole teardown and load -- which is exactly the "the desktop froze"
// feeling the failsafe exists to end. Transparent keeps the desktop visible
// behind the card the entire time, so a reload looks like a reload.
//
// BOTTOM-LEFT rather than centred because the centre of this screen is where
// the desktop's own content is, and the bottom-left corner is where this
// desktop already puts its own transient furniture -- the bar sits top-centre,
// the sidebars are on the left and right edges. The indicator lands where
// nothing else lives, so it never covers what the user is looking at, and it
// never covers the middle of the screen during a reload.
//
// NOT FOCUSABLE, so it can never swallow the keypress that started it.

import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    readonly property color fbBg: "#141414"
    readonly property color fbCard: "#1A1A1A"
    // Against a transparent surface the card no longer has a flat backdrop to
    // sit on, so it needs a shadow to stay readable over wallpaper as well as
    // over the desktop's own surfaces. Measured: with no shadow and a card
    // fill close to the panel colours, the card's edge disappears over a
    // mid-tone wallpaper and the indicator reads as floating text.
    readonly property color fbOutline: "#5A5A5A"
    readonly property color fbAccent: "#F2F2F2"
    // Pre-blended tail segments. These were `opacity: 0.28` / `0.55` on the
    // ShapePaths, but ShapePath in this Qt build has no `opacity` property at
    // all -- setting it fails the whole config at load with 'Cannot assign to
    // non-existent property "opacity"', which takes the indicator down rather
    // than degrading. These are the same two steps blended toward the track:
    //   0.28 -> 51 + 0.28*(242-51) = 105 = #69
    //   0.55 -> 51 + 0.55*(242-51) = 156 = #9C
    readonly property color fbTailFar: "#686868"
    readonly property color fbTailNear: "#9C9C9C"
    readonly property color fbTrack: "#333333"
    readonly property color fbLabel: "#C9C9C9"

    // ── The "it worked" state ───────────────────────────────────────────────
    //
    // WHY THIS EXISTS. An in-place reload of an UNCHANGED config is, by design,
    // invisible: the wallpaper, the bar and both sidebars are already up and
    // they look exactly the same afterwards. Measured on this machine the whole
    // thing now takes ~2s and the desktop never blanks. That is the correct
    // behaviour and it is exactly what was asked for -- and it is also
    // indistinguishable, to the person pressing the key, from the key doing
    // nothing. The reported symptom was literally "it says shell reloading and
    // nothing changes".
    //
    // So the card has to carry the result, not just the attempt. reset-shell.sh
    // CONFIRMS the reload is genuinely finished (wallpaper + both sidebars + bar
    // all mapped again) and then touches the marker file below; this watches for
    // it, swaps the spinner for a tick, rewrites the caption, and quits a beat
    // later. The confirmation is only ever shown AFTER that real check, so it
    // cannot claim success for a reload that did not happen -- which was the
    // whole defect in Quickshell's own built-in "Quickshell reloaded" popup.
    // A FIXED PATH, DELIBERATELY. This was first written as
    // Quickshell.env["XDG_RUNTIME_DIR"] + "/ii-reload-done" with a /tmp
    // fallback, which silently disagreed with the shell scripts: the QML fell
    // back to /tmp while splash.sh wrote to $XDG_RUNTIME_DIR, so the card
    // polled a file that was never created and logged "File does not exist" on
    // every poll. Two processes agreeing on a path by independent environment
    // lookups is a bug waiting to happen; one literal cannot drift.
    readonly property string doneMarker: "/tmp/ii-reload-done"
    property bool done: false
    // The marker's CONTENTS, not its existence, carry the signal.
    //
    // splash.sh pre-creates this file with a fresh token every time it raises
    // the card, so the FileView never polls a missing path (which logs a
    // warning per poll -- ten a second). reset-shell.sh then OVERWRITES the
    // token when the reload is confirmed, and a change from the token this card
    // was born holding is what means "finished". Existence alone cannot carry
    // it: the file always exists, so the card would read it as "done" the
    // instant it appeared.
    property string seenToken: ""

    // The spinner Item is rotated by an infinite RotationAnimator. Stopping the
    // animator does NOT reset `rotation` -- it leaves the property wherever the
    // animation happened to be, so the confirmation tick inherited an arbitrary
    // angle and rendered as a randomly tilted "^" instead of a tick. Measured
    // on a screenshot, which is the only way this would ever have been caught.
    onDoneChanged: {
        if (done && spinner)
            spinner.rotation = 0;
    }

    FileView {
        id: doneWatch
        path: root.doneMarker
        blockWrites: true
        onLoaded: {
            const token = text();
            if (root.seenToken === "") {
                // First read: this is whatever splash.sh wrote when it raised
                // this card. Remember it and wait for it to CHANGE.
                root.seenToken = token;
                return;
            }
            if (root.done || token === root.seenToken)
                return;
            root.done = true;
            quitTimer.restart();
        }
    }

    // Polled rather than watched: the marker does not exist when this card
    // starts, so there is no change event to attach to, and a 100ms poll of a
    // path that is almost always absent costs nothing. Kept OUT of the
    // FileView -- its default property is the adapter slot, so a Timer nested
    // inside it fails the whole config at load.
    Timer {
        interval: 100
        repeat: true
        running: !root.done
        onTriggered: doneWatch.reload()
    }

    // Held for a beat so the tick is readable rather than a single frame. Long
    // enough to register, short enough that it never feels like something is
    // still happening.
    Timer {
        id: quitTimer
        interval: 1400
        onTriggered: Qt.quit()
    }

    PanelWindow {
        id: overlay

        anchors.top: true
        anchors.bottom: true
        anchors.left: true
        anchors.right: true

        exclusiveZone: 0
        focusable: false
        // Transparent, so a reset never blacks out a desktop that is still up.
        color: "transparent"

        WlrLayershell.namespace: "quickshell:splashfb"

        Rectangle {
            id: card

            // Bottom-left, in the corner this desktop keeps free. Anchored to
            // the window's own edges with explicit margins rather than an
            // offset from centre: an offset is only correct at one screen size,
            // and this runs at whatever scale and resolution the session has.
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.leftMargin: 56
            anchors.bottomMargin: 56
            // Sized to its contents rather than fixed. This used to be a
            // 248x168 box chosen for a LOADER-ABOVE-CAPTION stack; with the
            // two side by side the content is much wider and much shorter, and
            // a hardcoded width would either clip the caption or leave a wide
            // empty band to its right. Deriving it from the Row means the
            // padding is the only number that has to be right.
            // THINNER. These were +56 horizontal and +36 vertical on a 44px
            // loader, which made the card 168px tall at its smallest and read as
            // a chunky dialog rather than a status line. The numbers are now
            // sized to the 32px loader below, not the old 44px one: 36/22 is
            // about one loader-radius of breathing room, so the card is 54px
            // tall and sits on the desktop edge instead of floating in it.
            width: row.implicitWidth + 36
            height: row.implicitHeight + 22
            // SQUARER. 26 on a 54px card is not a rounded rectangle, it is a
            // pill -- the top and bottom curves met and the box stopped reading
            // as a box. 10 is enough to soften the corner against the text
            // inside it and no more.
            radius: 10
            color: root.fbCard
            border.width: 1
            border.color: root.fbOutline

            // The loader sits LEFT of the caption, not above it. As a column
            // the card was nearly square and the label sat under a spinner,
            // which reads as a centred "loading..." dialog; beside it the two
            // read as one status line -- icon then text -- the way a status
            // item is actually written.
            Row {
                id: row
                anchors.centerIn: parent
                spacing: 12

                // ── the loader ────────────────────────────────────────────
                Item {
                    id: spinner
                    width: 32
                    height: 32
                    // No centring anchor here any more. This one was added
                    // when the card was a Column, where a child without an
                    // anchor lands at x: 0 against the Column's width -- which
                    // is set by the WIDEST child, the caption -- and the loader
                    // measured 54px left of everything else. A Row does not
                    // have that problem: it stacks children itself, and an
                    // anchor here would fight its layout.

                    // Everything is drawn in a 44x44 box and centred at 22,22,
                    // so the track and the arc share a centre exactly. Two
                    // rings at slightly different radii would visibly beat
                    // against each other as the arc spins.
                    readonly property real c: width / 2
                    readonly property real r: 12
                    // Hidden entirely once confirmed, so neither the track nor
                    // the arc can be mistaken for a still-running spinner.
                    visible: !root.done

                    Shape {
                        anchors.fill: parent
                        // The whole ring goes away once the reload is confirmed.
                        // Leaving a spinning-looking track next to the word
                        // "Reloaded" reads as work still in progress.
                        visible: !root.done

                        // The dim full circle the arc travels on. Without it
                        // the bright segment looks like it is randomly jumping
                        // rather than sweeping.
                        ShapePath {
                            strokeColor: root.fbTrack
                            // 3px on an 18px radius is a sixth of the ring's
                            // width; at this size that reads as a thick band
                            // rather than a hairline spinner. 1.6 keeps it
                            // legible against the card without dominating it.
                            strokeWidth: 1.6
                            fillColor: "transparent"
                            capStyle: ShapePath.RoundCap
                            PathAngleArc {
                                centerX: spinner.c
                                centerY: spinner.c
                                radiusX: spinner.r
                                radiusY: spinner.r
                                startAngle: 0
                                sweepAngle: 360
                            }
                        }

                        // The fading tail. Three segments of decreasing
                        // brightness rather than one hard arc is what makes it
                        // read as motion instead of as a rotating dash; a
                        // single arc with round caps looks like a clock hand.
                        //
                        // `sweepAngle`, not `endAngle`: PathAngleArc describes a
                        // span, and endAngle belongs to PathArc. Measured --
                        // using it fails the whole config at load with
                        // 'Cannot assign to non-existent property "endAngle"',
                        // which takes the indicator down entirely.
                        ShapePath {
                            strokeColor: root.fbTailFar
                            strokeWidth: 1.6
                            fillColor: "transparent"
                            capStyle: ShapePath.RoundCap
                            PathAngleArc {
                                centerX: spinner.c
                                centerY: spinner.c
                                radiusX: spinner.r
                                radiusY: spinner.r
                                startAngle: 0
                                sweepAngle: 95
                            }
                        }
                        ShapePath {
                            strokeColor: root.fbTailNear
                            strokeWidth: 1.6
                            fillColor: "transparent"
                            capStyle: ShapePath.RoundCap
                            PathAngleArc {
                                centerX: spinner.c
                                centerY: spinner.c
                                radiusX: spinner.r
                                radiusY: spinner.r
                                startAngle: 95
                                sweepAngle: 60
                            }
                        }

                        // The bright head.
                        ShapePath {
                            strokeColor: root.fbAccent
                            strokeWidth: 1.6
                            fillColor: "transparent"
                            capStyle: ShapePath.RoundCap
                            PathAngleArc {
                                centerX: spinner.c
                                centerY: spinner.c
                                radiusX: spinner.r
                                radiusY: spinner.r
                                startAngle: 155
                                sweepAngle: 40
                            }
                        }
                    }

                    RotationAnimator on rotation {
                        from: 0
                        to: 360
                        duration: 900
                        loops: Animation.Infinite
                        // Stop dead when the reload is confirmed. A spinner
                        // still turning next to the word "Reloaded" says the
                        // work is ongoing, which is the opposite of the truth.
                        running: !root.done
                    }
                }

                // ── the confirmation tick ──────────────────────────────
                //
                // A SIBLING of the spinner, not a child of it, and that is the
                // whole trick. The spinner Item carries an infinite
                // RotationAnimator, and an animator that stops does NOT restore
                // the property it was driving -- `rotation` is simply left
                // wherever the animation was at. A tick drawn inside that Item
                // therefore inherited a random angle every time: measured on
                // screenshots, it rendered as a tilted "^", then as a
                // near-vertical stroke. Resetting `rotation` from a handler was
                // not reliable either, because the animator's final value could
                // land after it.
                //
                // So the tick simply does not live under the rotating node. Both
                // Items are 32x32 and only one is ever visible, so the Row's
                // layout -- and therefore the card's width -- is identical in
                // both states.
                Item {
                    id: tickBox
                    width: 32
                    height: 32
                    visible: root.done

                    readonly property real c: width / 2
                    readonly property real r: 12

                    Shape {
                        id: tickShape
                        anchors.fill: parent

                        // Drawn with a ShapePath rather than an image or an
                        // icon-font glyph, for the same reason the spinner is
                        // hand-drawn: no asset that can fail to load, and it
                        // takes the same hairline weight as the ring it
                        // replaces, so the two states read as one component
                        // changing state rather than two things appearing.
                        //
                        // PathPolyline, not startX/startY plus PathLines -- the
                        // latter rendered as a small pennant rather than a tick
                        // at this size.
                        //
                        // Referenced by the Shape's OWN id: inside PathPolyline
                        // the parent is the ShapePath, which has no cx/r, so
                        // `parent.cx` was undefined and the tick drew nothing.
                        readonly property real cx: width / 2
                        readonly property real r: 12

                        ShapePath {
                            strokeColor: root.fbAccent
                            strokeWidth: 2
                            fillColor: "transparent"
                            capStyle: ShapePath.RoundCap
                            joinStyle: ShapePath.RoundJoin
                            PathPolyline {
                                path: [
                                    Qt.point(tickShape.cx - tickShape.r * 0.58, tickShape.cx + tickShape.r * 0.08),
                                    Qt.point(tickShape.cx - tickShape.r * 0.17, tickShape.cx + tickShape.r * 0.50),
                                    Qt.point(tickShape.cx + tickShape.r * 0.58, tickShape.cx - tickShape.r * 0.42)
                                ]
                            }
                        }
                    }
                }

                Text {
                    // Vertically centred on the loader, since a Row only lays
                    // out horizontally. Without this the text sits on the Row's
                    // baseline and the two do not line up.
                    anchors.verticalCenter: parent.verticalCenter
                    // The caption is the actual confirmation. "Reloaded" is only
                    // ever shown after reset-shell.sh has verified the desktop
                    // is whole again, so unlike Quickshell's own reloaded popup
                    // this cannot appear while the screen is still empty.
                    text: root.done ? "Shell reloaded" : "Reloading shell..."
                    color: root.fbLabel
                    font.pixelSize: 14
                    font.family: "Inter"
                    font.weight: Font.Medium
                    // A little tracking: at 14px the default spacing reads as
                    // cramped next to a 32px loader.
                    font.letterSpacing: 0.4
                }
            }
        }
    }
}