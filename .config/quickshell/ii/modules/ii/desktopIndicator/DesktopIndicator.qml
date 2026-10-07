import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.modules.ii.bar as Bar
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Io

/**
 * The desktops, small, at the bottom of the screen.
 *
 * They used to live in the bar, and that was the wrong home for them: a row of
 * dots that only changes when you switch desktop was spending bar length -- the
 * scarcest room on the screen -- on a status. A bar is for what you reach for;
 * this is for what you glance at. So the bar keeps the clock and the now bar,
 * and the desktops moved to a small capsule hugging the bottom edge, centred
 * under the middle island.
 *
 * It is not a new widget: it is `Bar.Workspaces` in its `compact` metrics, in
 * a capsule. Every interaction came with it -- click a dot to switch (through
 * the same anamorphic driver the keyboard uses), right click for the desktop
 * grid, scroll to step, back button for the special workspace, and the trailing
 * "+" slot is still how a new desktop gets made.
 *
 * What it is NOT is hover-reactive. Moving the pointer through the lower part
 * of the screen does not bring it up: it is a glance, and it answers to a
 * FOUR-FINGER HORIZONTAL SWIPE, in either direction -- not to the pointer
 * passing nearby, and deliberately not to the desktop changing either. The
 * pointer may hold an already-visible pill open so a reach for a dot does not
 * race the timer, but it cannot summon one.
 *
 * FIVE things it yields to, all of them cases where it would either be wrong or
 * in the way:
 *   * the dock -- its pill owns exactly this band, so the two never fight;
 *   * a fullscreen window on this monitor -- fullscreen is a request for no
 *     chrome;
 *   * the lock screen;
 *   * a bar variant that carries its own desktops (the vertical bar), so the
 *     desktops are never drawn twice.
 *
 * Like the dock, the layer stays MAPPED and only the content and the input mask
 * change. Toggling `visible` on a layer surface remaps it, and every remap
 * flashes the whole desktop -- the bug the dock already paid for once.
 */
Scope {
    id: root

    // The one instance this config's IPC diagnostics talk about. Filled by
    // the delegate itself (there is exactly one screen on this machine; the
    // assignment would just pick whichever instance came up last on a
    // multi-monitor setup, which is still a useful answer).
    property var primaryInstance: null

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: surface
            required property var modelData
            screen: modelData
            color: "transparent"

            readonly property var monitor: Hyprland.monitorFor(surface.modelData)
            // A fullscreen window on THIS monitor. Read the same way the dock
            // reads it, so the two agree about what "fullscreen" means.
            readonly property bool fullscreenOnMonitor: Hyprland.workspaces.values.some(ws =>
                ws.monitor === surface.monitor && ws.active
                && ws.toplevels.values.some(t => t.wayland?.fullscreen))

            // The vertical bar carries the desktops itself; showing them here
            // as well would draw the same status twice on one screen.
            readonly property bool barWantsDesktops: Config.options.bar.enable && Config.options.bar.vertical

            // The fixture gates (dock, bar-variant, lock, fullscreen) keep the
            // pill from LINGERING where it does not belong. The swipe flash is
            // deliberately NOT gated by fullscreen (requested 2026-09-26):
            // swiping onto a fullscreen desktop is exactly when you want the
            // "you are on desktop N" glance, and fullscreen is a request for
            // no PERSISTENT chrome -- the pill vanishes again on its own after
            // the flash. So `shown` keeps every gate except fullscreen, and
            // fullscreen only suppresses the non-flash (edit) ways in.
            readonly property bool shown: !GlobalStates.screenLocked
                && !GlobalStates.dockRevealed && !GlobalStates.dockPointerInside
                && !surface.barWantsDesktops

            // ── Transient: flash on a four-finger SWIPE, then fade away ───
            // The pill is a glance, not a fixture: it appears when a
            // four-finger horizontal swipe happens, holds about a second and a
            // half so the eye can find it, and dissolves. It stays up while
            // hovered (so reaching it never races the timer) and while desktop
            // edit mode is on (the pen tell has to survive; the dots are the
            // edit surface then).
            property bool flash: false
            Timer {
                id: flashTimer
                interval: 1400
                onTriggered: surface.flash = false
            }
            Connections {
                target: GlobalStates
                // The ONLY thing that flashes this pill: a four-finger
                // horizontal swipe, in either direction (shell.qml raises this
                // from TouchpadSwipe.onHorizontalSwipeEnded, unconditionally --
                // see the "Nothing that way" block there for why there is no
                // "did it land?" test).
                //
                // It used to also flash on Hyprland's `workspace` events, which
                // meant simply landing on another desktop brought the bar up.
                // That listener is gone, and deliberately: a desktop change the
                // user did not ask to be interrupted by is not a glance worth
                // interrupting them for, and the swipe -- where the gesture may
                // have done nothing at all -- is the moment an answer is
                // actually wanted. Same flag, same timer, same appearance; one
                // trigger instead of two.
                function onDesktopPillFlash() {
                    surface.flash = true;
                    flashTimer.restart();
                }
            }

            // ── Empty-desktop stay ─────────────────────────────────────────
            // An empty desktop used to be the worst case for a GLANCE-based
            // pill: you land on it, the flash dissolves, and the one screen
            // where the dots are most useful -- there is nothing else to
            // look at, and the next thing you will do is reach for another
            // desktop or an app -- is exactly where the pill was gone.
            // Requested (2026-09-27): while the active desktop has no
            // windows, the pill STAYS -- two seconds minimum, and for as
            // long as the desktop remains empty. The moment an app opens,
            // the desktop is reclaimed: the active ball gives one farewell
            // wink and the pill dissolves (see the reclaim block below).
            readonly property int activeWsId: surface.monitor?.activeWorkspace?.id ?? -1
            // This monitor's active desktop, judged by the same predicate
            // GlobalStates uses for the focused one: no mapped, unhidden
            // windows on it. Per-monitor on purpose -- two displays can
            // disagree about which desktop is up, let alone whether it is
            // empty.
            readonly property bool activeDesktopEmpty: {
                const wid = surface.activeWsId;
                if (wid < 1) return false;
                return !HyprlandData.windowList.some(w => (w.workspace?.id ?? -1) === wid
                    && w.mapped !== false && w.hidden !== true);
            }
            readonly property bool emptyStay: surface.shown
                && !surface.fullscreenOnMonitor && surface.activeDesktopEmpty
            // When the stay began, so an early reclaim can still be honoured
            // for the full two seconds the stay promised.
            property real emptyStaySince: 0
            onEmptyStayChanged: if (emptyStay) emptyStaySince = Date.now()

            // ── Reclaim: the desktop got its first window ──────────────────
            // An app opened on the desktop we are watching (SAME workspace id
            // -- a switch to a busy desktop is a switch, not a reclaim, and
            // the ordinary flash already covers it): the ball winks once and
            // the pill takes its leave. The wink needs the pill VISIBLE for
            // its whole run, so `farewell` holds `visibleNow` up while the
            // timer runs -- at least as long as the animation, and long
            // enough to honour the two-second promise when the app was quick.
            property bool farewell: false
            property real farewellStarted: 0
            Timer {
                id: farewellTimer
                onTriggered: surface.farewell = false
            }
            property int lastWsId: -1
            property bool wasEmpty: false
            Component.onCompleted: {
                surface.lastWsId = surface.activeWsId;
                surface.wasEmpty = surface.activeDesktopEmpty;
                root.primaryInstance = surface;
            }
            onActiveWsIdChanged: surface.evaluateReclaim()
            onActiveDesktopEmptyChanged: surface.evaluateReclaim()
            function evaluateReclaim() {
                const sameDesktop = surface.activeWsId === surface.lastWsId;
                if (sameDesktop && surface.wasEmpty && !surface.activeDesktopEmpty
                    && surface.lastWsId >= 1 && surface.emptyStay) {
                    surface.farewellStarted = Date.now();
                    // The two-second promise: a reclaim within the stay's
                    // first two seconds keeps the pill up to the mark.
                    farewellTimer.interval = Math.max(900, 2000 - (surface.farewellStarted - surface.emptyStaySince));
                    surface.farewell = true;
                    farewellTimer.restart();
                }
                surface.lastWsId = surface.activeWsId;
                surface.wasEmpty = surface.activeDesktopEmpty;
            }

            // Fullscreen suppresses the fixture paths (edit mode) but never
            // the flashes: those are self-removing glances, and fullscreen is
            // a request for no PERSISTENT chrome -- which is exactly what the
            // stay is, so the stay (unlike flash/farewell) stays gated.
            // Pointer actually over the pill RIGHT NOW, as a property rather
            // than a one-shot. See the HoverHandler below: it used to only
            // restart the flash timer on hover ENTER, so 1.4s later the timer
            // fired and dissolved the pill out from under a pointer that had
            // not moved -- which is exactly what made the trailing "+" feel
            // unclickable. The pointer is the reason to stay, so the pointer
            // keeps it up.
            property bool pointerInside: false
            // `pointerInside` is deliberately NOT part of `visibleNow` below.
            //
            // It used to be, and the mask below is permanently non-null
            // whenever `shown` is, so the pill's ~100x30 box at the bottom
            // centre is hit-testable at all times. With the pointer in
            // `visibleNow` that meant simply sweeping the mouse through the
            // lower part of the screen popped the desktops up out of
            // nowhere -- the pill is a glance, but it was answering to
            // proximity rather than to the swipe that raises it.
            //
            // The pointer still HOLDS a pill that is already up (see the
            // HoverHandler), so reaching for a dot does not race the timer.
            // It just cannot bring one into being.
            readonly property bool visibleNow: (surface.shown || surface.flash || surface.emptyStay
                || surface.farewell)
                && (surface.flash || surface.farewell || surface.emptyStay
                    || (GlobalStates.desktopEditMode && !surface.fullscreenOnMonitor))


            WlrLayershell.namespace: "quickshell:desktopIndicator"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            // No space is reserved from windows: this is an overlay, not a bar.
            exclusionMode: ExclusionMode.Ignore
            exclusiveZone: -1
            // Anchored to the bottom edge ONLY, and sized to its content: with
            // no left or right anchor the compositor centres it horizontally,
            // which is exactly where it belongs -- directly under the middle
            // island. (The OSD is placed the same way.)
            anchors.bottom: true
            // 12, not the usual 5px gap: the bottom edge's dock-reveal strip is
            // 10px tall (EdgeReveal.stripWidth), and a pill whose lower half
            // sat inside it would summon the dock every time someone reached
            // for a desktop dot -- the dock would then rise over the pill it
            // was hiding. 12 clears the band with the pill still hugging the
            // bottom edge.
            margins.bottom: 12
            implicitWidth: capsule.implicitWidth
            implicitHeight: capsule.implicitHeight
            visible: true

            mask: Region {
                // The input region follows `visibleNow`, so it exists exactly
                // when the pill is actually on screen.
                //
                // It used to follow `shown`, which kept the pill's ~100x30 box
                // at the bottom centre hit-testable even when the pill was
                // fully faded. That was load-bearing while hover-to-reveal
                // existed -- the region is what makes the surface hit-testable
                // at all, so with it null the pill could not receive the very
                // hover meant to bring it back. Now that the pointer can no
                // longer summon the pill, that arrangement buys nothing and
                // costs a permanently invisible click-eater over window
                // content. Gating on `visibleNow` keeps every real
                // interaction -- the flash, the empty-desktop stay, the
                // farewell wink, edit mode -- and stops the pill from eating
                // presses aimed at the window underneath it when it is not
                // there.
                item: surface.visibleNow ? capsule : null
            }

            Rectangle {
                id: capsule
                anchors.centerIn: parent
                // Air around the dots, not around the capsule: the capsule is
                // sized from the row so a fifth desktop widens it by one cell
                // -- and so the edit-mode pen's slot (part of the same row)
                // widens it too; sized from the dots alone the window stayed
                // narrow and clipped the pen.
                implicitWidth: capsuleRow.implicitWidth + 16
                implicitHeight: capsuleRow.implicitHeight + 6
                // The islands' own rounding -- the full-capsule bend read as a
                // different species next to the top bar.
                radius: Appearance.rounding.windowRounding
                // The bar islands' own skin, so the pill reads as belonging to
                // this desktop's language rather than as a stray chip.
                // In desktop edit mode it lights up in the accent and gains an
                // edit glyph: this pill is the one always-on piece of chrome,
                // so it is the right place for the "you are editing" tell.
                color: Appearance.colors.colLayer0
                border.width: 1
                border.color: GlobalStates.desktopEditMode
                    ? Appearance.colors.colPrimary
                    : Appearance.colors.colLayer0Border
                Behavior on border.color {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }

                opacity: surface.visibleNow ? 1 : 0
                // It rises a few pixels as it fades in, so a flash or a
                // fullscreen exit reads as the pill arriving rather than as it
                // having been there all along, half-transparent.
                transform: Translate {
                    y: surface.visibleNow ? 0 : 5
                    Behavior on y {
                        // The pill's own show animation, written out rather
                        // than taken from Appearance, because this one is on the
                        // swipe's critical path. `elementMoveFast` is
                        // expressiveEffectsDuration -- 200ms -- which on top of
                        // the gesture's own latency made a swipe answer feel
                        // like it had been ignored: the bar was still arriving
                        // a fifth of a second after you asked it a question.
                        // 90ms is below the threshold where motion reads as
                        // animation at all and just reads as "it is there".
                        animation: NumberAnimation {
                            duration: 90
                            easing.type: Easing.OutCubic
                        }
                    }
                }
                Behavior on opacity {
                    // Same reasoning as the rise above, and the same number.
                    // The fade OUT is the one worth keeping gentle, so the bar
                    // does not blink out of existence; `visibleNow` going false
                    // is the only common case, and 90ms in / 160ms out reads
                    // as a glance rather than a flicker.
                    animation: NumberAnimation {
                        duration: surface.visibleNow ? 90 : 160
                        easing.type: surface.visibleNow ? Easing.OutCubic : Easing.InQuad
                    }
                }

                // Hovering the pill holds it open, continuously, not just on
                // entry. The old one-shot restarted `flashTimer` when the
                // pointer arrived and then went quiet, so the 1.4s timer
                // expired underneath a stationary cursor and took the pill --
                // and the "+" -- away mid-reach. `pointerInside` is now part of
                // `visibleNow`, so the pill stays for as long as the pointer
                // is on it and leaves on the way out.
                HoverHandler {
                    onHoveredChanged: {
                        surface.pointerInside = hovered;
                        // HOLD, never SUMMON. The old handler set `flash`
                        // unconditionally on entry, and because the mask is
                        // always live that turned "move the mouse through the
                        // bottom band" into a desktop-indicator popup. Now the
                        // timer is only restarted for a pill that is already
                        // up, so the pointer cannot race the 1.4s dissolve
                        // mid-reach (the bug `pointerInside` was originally
                        // added for) but also cannot conjure the pill.
                        if (hovered && (surface.flash || surface.emptyStay
                            || surface.farewell)) {
                            surface.flash = true;
                            flashTimer.restart();
                        }
                    }
                }

                Row {
                    id: capsuleRow
                    anchors.centerIn: parent
                    spacing: 8

                    // The edit-mode tell: a small accent pen beside the dots.
                    // It lives in an animated slot rather than toggling
                    // `visible` -- a Row drops invisible children on the spot,
                    // which would snap the capsule's width; this way the pill
                    // grows a cell for the pen and shrinks back smoothly.
                    // The slot is dot-height (a positioner child cannot use
                    // anchors) so centring the glyph in it centres it in the
                    // pill. "edit": "edit_square" is not in the bundled font
                    // and rendered nothing.
                    Item {
                        width: GlobalStates.desktopEditMode ? 13 : 0
                        height: desktopDots.implicitHeight
                        Behavior on width {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }
                        MaterialSymbol {
                            anchors.centerIn: parent
                            text: "edit"
                            iconSize: 13
                            color: Appearance.colors.colPrimary
                            opacity: GlobalStates.desktopEditMode && parent.width > 4 ? 1 : 0
                            Behavior on opacity {
                                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                            }
                        }
                    }

                    Bar.Workspaces {
                        id: desktopDots
                        compact: true
                        anchors.verticalCenter: parent.verticalCenter
                        // The reclaim tell: the active ball winks once while
                        // `farewell` holds the pill up (DesktopIndicator owns
                        // the trigger; Workspaces owns the wink).
                        farewellPulse: surface.farewell
                    }
                }
            }
        }
    }

    // State of the pill, for the primary monitor's instance. Diagnostics:
    //   qs -c ii ipc call desktopPill state
    // Verified against the screens: eDP-1 is the only display here, so the
    // Variants loop produces exactly one instance and `screens[0]` is it.
    IpcHandler {
        target: "desktopPill"
        function state(): string {
            const pill = root.primaryInstance;
            if (!pill)
                return "no instance";
            return `flash=${pill.flash} emptyStay=${pill.emptyStay} farewell=${pill.farewell}`
                + ` ws=${pill.activeWsId} empty=${pill.activeDesktopEmpty}`
                + ` shown=${pill.shown} visibleNow=${pill.visibleNow}`;
        }
    }
}
