import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

/**
 * The background-arrival tell.
 *
 * REQUESTED (2026-11-16): "when a new window is opened while in fullscreen,
 * instead of minimizing the fullscreen, give a small signal that something has
 * opened in the background ... not a notification from the top right".
 *
 * So the compositor now keeps the fullscreen app alone (`misc:
 * on_focus_under_fullscreen = 0` in custom/general.lua, which also removed the
 * hook that used to un-fullscreen the incumbent). A window that arrives
 * therefore lands BEHIND the fullscreen one, invisible and unfocused -- and
 * this is the only thing that says it happened: one small card, top centre,
 * naming the app, gone again after a few seconds. The app's icon and its name,
 * nothing else: the window title under it was one line too many, and it was the
 * line that pushed the name into an ellipsis.
 *
 * Deliberately NOT the notification popup. That one is a queue with history,
 * sounds and an inbox behind it; this is a glance, and it must never be
 * mistaken for something that needs dismissing. It carries no buttons for the
 * same reason -- going to look is SUPER+Tab's or the overview's job, and this
 * surface is a picture, not a target.
 *
 * Overlay layer with an empty input mask: the layer-shell kind that renders
 * above a fullscreen client (that is why the task manager lives there too),
 * and it must never eat a click or take a key from the app underneath.
 */
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: tell
        required property var modelData

        screen: tell.modelData
        color: "transparent"
        WlrLayershell.namespace: "quickshell:backgroundArrival"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        exclusiveZone: 0

        anchors {
            top: true
            left: true
            right: true
        }
        implicitHeight: card.height + 16
        // A card that is not up is not a surface to composite: the window
        // hides itself the moment the fade-out finishes, so nothing is left
        // mapping over a fullscreen game in between arrivals.
        visible: card.opacity > 0
        mask: Region { item: null }

        readonly property var monitor: Hyprland.monitorFor(tell.modelData)
        readonly property int monitorId: tell.monitor?.id ?? -1

        // ── What just arrived ───────────────────────────────────────────
        // { id, title, class } of the window the card is about, or null.
        property var arrival: null
        property int arrivalId: 0

        // ── Addresses already seen ──────────────────────────────────────
        // The arrival has to be a CHANGE in the client list, not a window
        // that was already there when the shell started: primed on the first
        // read, so logging in over a fullscreen app does not announce every
        // window on the desktop.
        property var known: ({})
        property bool primed: false

        function prime() {
            const next = ({});
            for (const w of (HyprlandData.windowList ?? []))
                next[w.address] = true;
            tell.known = next;
            tell.primed = true;
        }

        /**
         * Show the card for a window that opened behind a fullscreen one.
         *
         * `floating` windows are skipped on purpose: a floating window renders
         * ABOVE a fullscreen tiled one, so the user already sees it -- a
         * chooser, a polkit prompt or a floating app needs no announcement,
         * and announcing one would be the "notification for something you are
         * looking at" noise this replaces.
         *
         * A newcomer that is itself fullscreen is skipped too: that is the
         * other case entirely (it covers the screen, and custom/general.lua
         * still demotes arrivals that take it over).
         */
        function scan() {
            const list = HyprlandData.windowList ?? [];
            if (!tell.primed) {
                tell.prime();
                return;
            }
            let fresh = null;
            const next = ({});
            for (const w of list) {
                next[w.address] = true;
                if (fresh === null && !tell.known[w.address])
                    fresh = w;
            }
            tell.known = next;
            if (fresh === null)
                return;
            if (fresh.monitor !== tell.monitorId)
                return;               // arrived on another monitor
            if (fresh.floating)
                return;               // already visible above the fullscreen
            if ((fresh.fullscreen ?? 0) !== 0)
                return;               // it took the screen itself
            // Is it actually hidden? Only when a fullscreen window on the SAME
            // workspace covers this monitor. Without this check every window
            // opened on an ordinary desktop would get a card as well.
            const covered = list.some(o => o.address !== fresh.address
                && o.monitor === tell.monitorId
                && o.workspace?.id === fresh.workspace?.id
                && (o.fullscreen ?? 0) !== 0);
            if (!covered)
                return;
            tell.show(fresh);
        }

        function show(w) {
            tell.arrivalId += 1;
            tell.arrival = {
                id: tell.arrivalId,
                title: String(w.title ?? ""),
                class: String(w.class ?? ""),
            };
            enterAnim.restart();
            holdTimer.restart();
        }

        function dismiss() {
            exitAnim.restart();
            tell.arrival = null;
        }

        Connections {
            target: HyprlandData
            function onWindowListChanged() { tell.scan() }
        }

        // The card stays a beat longer than it takes to read two short lines.
        Timer {
            id: holdTimer
            interval: 3800
            onTriggered: tell.dismiss()
        }

        SequentialAnimation {
            id: enterAnim
            ParallelAnimation {
                NumberAnimation {
                    target: card
                    property: "opacity"
                    from: 0
                    to: 1
                    duration: 170
                    easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    target: slide
                    property: "y"
                    from: -10
                    to: 0
                    duration: 240
                    easing.type: Easing.OutCubic
                }
            }
        }

        SequentialAnimation {
            id: exitAnim
            ParallelAnimation {
                NumberAnimation {
                    target: card
                    property: "opacity"
                    to: 0
                    duration: 240
                    easing.type: Easing.InCubic
                }
                NumberAnimation {
                    target: slide
                    property: "y"
                    to: -6
                    duration: 240
                    easing.type: Easing.InCubic
                }
            }
        }

        // ── The card ────────────────────────────────────────────────────
        // A single row, pill-shaped, on the popup surface token so it reads as
        // part of the shell's card family rather than as a system banner.
        //
        // ONE LABEL, THE APP'S NAME (2026-11-17). It used to carry the window
        // title under the name and shrink to a fixed width, which is how a
        // "kitty" arrival came up as "kitty / ki..." -- the second line was
        // information nobody asked for at a glance, and the first one was cut
        // off to make room for it. What a background arrival has to say is
        // which app is now open behind the fullscreen thing; the title is what
        // the app's own tab bar is for.
        //
        // The width follows the name, so the pill is short for "kitty" and long
        // for something like "Visual Studio Code" -- and only a name too long
        // for the screen it is on gets an ellipsis, at the screen's edge rather
        // than at an arbitrary fixed width.
        Rectangle {
            id: card

            readonly property var entry: tell.arrival
                ? DesktopEntries.heuristicLookup(tell.arrival.class)
                : null
            readonly property string appName: card.entry?.name ?? tell.arrival?.class ?? ""

            // Everything in the pill that is not the name: the row's left and
            // right margins, the icon and the gap after it, plus the slack that
            // keeps the name from touching the rounded end.
            readonly property real chrome: 11 + 36 + 12 + 20 + 14
            readonly property real nameWidth: Math.ceil(nameLabel.implicitWidth)
            // The most the pill may take before it would run off the screen.
            readonly property real maxWidth: Math.max(120, tell.width - 48)

            anchors.top: parent.top
            anchors.topMargin: 16
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(card.nameWidth + card.chrome, card.maxWidth)
            height: 58
            radius: Appearance.rounding.full
            color: Appearance.colors.colSurfaceContainerHigh
            border.width: 1
            border.color: Appearance.colors.colOutlineVariant
            opacity: 0

            transform: Translate { id: slide; y: -10 }

            RowLayout {
                id: content
                anchors.fill: parent
                anchors.leftMargin: 11
                anchors.rightMargin: 20
                spacing: 12

                Rectangle {
                    Layout.preferredWidth: 36
                    Layout.preferredHeight: 36
                    Layout.alignment: Qt.AlignVCenter
                    radius: Appearance.rounding.normal
                    color: Appearance.colors.colSurfaceContainerHighest

                    AppIcon {
                        anchors.centerIn: parent
                        implicitSize: 22
                        source: card.entry?.icon ?? "application-x-executable"
                    }
                }

                StyledText {
                    id: nameLabel
                    Layout.alignment: Qt.AlignVCenter
                    // Not `fillWidth`: a filled child reports the space it was
                    // given, not the space its words need, and that is what made
                    // the pill measure itself too narrow to hold the name.
                    Layout.maximumWidth: Math.max(60, card.maxWidth - card.chrome)
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colOnSurface
                    elide: Text.ElideRight
                    text: card.appName
                }
            }
        }
    }
}
