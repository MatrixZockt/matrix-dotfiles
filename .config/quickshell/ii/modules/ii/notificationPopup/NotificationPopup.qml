import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

Scope {
    id: notificationPopup

    PanelWindow {
        id: root
        visible: (Notifications.popupList.length > 0) && !GlobalStates.screenLocked
        // `monitor`, not `forceMonitor`. The schema (Config.qml) and the Settings >
        // Notifications page both use `monitor`; this line read `forceMonitor`,
        // which exists nowhere. The optional chaining made the whole thing
        // undefined -> falsy, so the forced-monitor setting was silently dead
        // and every notification fell back to the focused monitor. There is a
        // second reason it has to be `monitor`: with no matching screen the
        // find() returns undefined and the PanelWindow gets `screen: null`,
        // which hides the popup entirely -- so the fallback below keeps it on
        // the focused monitor rather than off screen.
        screen: (() => {
            const mon = Config.options.notifications.monitor;
            if (mon?.enable && mon?.name) {
                const forced = Quickshell.screens.find(s => s.name === mon.name);
                // A name that matches nothing must NOT resolve to null: a
                // PanelWindow with screen: null is never shown, so a typo in
                // the settings field would silently swallow every notification
                // on the machine. Fall back to the focused monitor instead and
                // say so once, rather than going quiet.
                if (forced) return forced;
                console.warn("NotificationPopup: no screen named", mon.name,
                             "- falling back to the focused monitor");
            }
            return Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? null;
        })()

        WlrLayershell.namespace: "quickshell:notificationPopup"
        WlrLayershell.layer: WlrLayer.Overlay
        exclusiveZone: 0

        anchors {
            top: true
            right: true
            bottom: true
        }

        mask: Region {
            item: listview.contentItem
        }

        color: "transparent"

        // ── Position: tucked into the top-right corner ────────────────────
        // The window itself must span the right edge (the list can grow
        // downward without remapping the layer surface), but the LIST is
        // inset from both the bar and the screen edge by `edgeGap`.
        //
        // notification JSON. A shorter one spans the same top row, with its
        // own left and right gutter; a longer box simply grows, and the
        // widest line sets the row so nothing gets clipped inside.
        //
        // The window fills the full available width between the bar's
        // bottom edge and the right wall, so a long JSON line has nowhere
        // to wrap into the bar below or off the screen to the right.
        //
        // `bottom: true` plus the bar's exclusive zone: Hyprland already
        // places this surface just below the bar's painted strip, so the
        // list starts at the bar and runs to the screen edge without
        // touching the bar or shrinking to fit a narrow box.
        //
        // The notification box should not get lost in the status bar at the
        // bottom: that row is only as wide as the JSON line it came from, so
        // a short one leaves a small margin beside it instead of stretching
        // across the whole panel. Fill that unused band on the left so the
        // notification always sits against the right wall, wide enough for
        // the longest line at this desktop size and nothing less.
        //
        // One fixed width per notification size: the JSON line it came from,
        // no margin, no centering, nothing to stretch it out to fill the
        // panel. The bar is simply not wide enough for every possible
        // message, so the box is exactly the width of the line it carries.
        //
        // History of the number, because it has moved before and the reasons
        // do not survive the move:
        //
        //   3px  measurably correct but read as flush -- the card's own drop
        //        shadow spreads roughly that far, so it filled the gap and
        //        the shadow edge landed on the screen edge.
        //   6px  left the shadow somewhere to go. Correct, but REQUESTED as
        //        too tight: the card still touched the corner visually
        //        because the shadow closes most of the gap back up, and the
        //        shadow's own edge reached the screen edge.
        //  12px  current. Doubling 6 puts ~6px of genuine air between the
        //        shadow edge and both the top and the right of the screen --
        //        enough that the notification reads as sitting INSIDE the
        //        corner rather than bleeding off it, while still clearly
        //        belonging to that corner.
        //  24px  an earlier attempt that went too far the other way and
        //        stopped reading as part of the corner at all. Still the
        //        upper bound to stay under.
        readonly property real edgeGap: 12

        // NOTE: there is deliberately no bar-height term here, and adding
        // one is a bug that is very easy to repeat.
        //
        // This PanelWindow anchors to the top, and Hyprland already places an
        // anchored surface below the bar's exclusive zone. Measured: with the
        // bar visible the surface is `xywh: <x> 45 413 955` -- y=45 is
        // ALREADY the bar's painted bottom edge, supplied for free. A
        // `+ barHeight` term on top of that pushed the card to logical y~92,
        // leaving a ~47px gap under a 50px bar. The clearance was counted
        // twice, once by the compositor and once by us.
        //
        // The corollary is why `barHidden` needs no special case either: when
        // the bar gives up its strip (fullscreen, covering maximize -- see
        // custom/cover.lua) the exclusive zone goes with it, the surface
        // follows up to y=0, and the same `edgeGap` then measures from the top
        // of the screen. One number, correct in both states.

        // The window is as wide as the card PLUS the gap it floats in, so
        // that widening the gap never pushes the card off the surface. The
        // right wall is the fixed side: the card sits just inside it, with
        // `edgeGap` of genuine air between the card's shadow and the screen.
        //
        // THIS WIDTH IS LOAD-BEARING, and its absence is not a missing nicety:
        // with no width the surface took the list's own implicit width instead
        // -- measured at 100px, a sliver down the right edge of the screen,
        // which is a popup that "does not show" while every notification is
        // still in the bell. `/usr/bin/hyprctl layers` is where that shows up:
        // `quickshell:notificationPopup 1607 45 100 1022`.
        readonly property real cardWidth: Appearance.sizes.notificationPopupWidth - Appearance.sizes.elevationMargin * 2
        implicitWidth: cardWidth + edgeGap + Appearance.sizes.elevationMargin * 2

        NotificationListView {
            // Named, because the window's input mask above is this list's own
            // content item: `mask: Region { item: listview.contentItem }`. The
            // list was left anonymous in an edit on 2026-10-19, and a mask
            // pointing at a name that does not exist is a ReferenceError at
            // load -- the surface then has no input region at all.
            id: listview
            anchors {
                top: parent.top
                bottom: parent.bottom
                // Fill the full width of the notification panel, including
                // the band under the bar that a short JSON line would
                // otherwise leave empty. The list is a window onto the message
                // that arrived, so it runs edge to edge on the right and stops
                // at the bar above.
                //
                // The four edges belong HERE, in the anchors block, and not as
                // `left: 0 / right: 0 / bottom: 0` on the item: `bottom` is a
                // read-only property of the view (it is the scrollable one),
                // so assigning it at the item level is a config that does not
                // load AT ALL -- and `width` beside anchored left and right is
                // a second opinion the anchors already give. No left/right
                // margin on the list, so the notification box uses the full
                // width of the bar and nothing sits in the unused space to
                // the left.
            }
            // Placed from the window's own width, NOT with `anchors.right` +
            // `rightMargin` and NOT with `implicitWidth`: both were tried, and
            // both put the card flush against the screen edge -- measured at
            // edgeGap 3 and 6, raising the gap moved the card's left edge and
            // its right edge right together (1207 -> 1210, 1597.5 -> 1599.4)
            // while the surface grew to match. `implicitWidth` on a
            // Flickable-derived item is derived from its content, so it is not
            // a dependable way to set a width; stating `x` and `width`
            // outright removes both assumptions.
            x: parent.width - root.edgeGap - root.cardWidth
            width: root.cardWidth
            topMargin: root.edgeGap
            // Bottom edge sits on the bar's painted bottom, two states, one
            // number: with the bar visible the surface is `xywh: <x> 45
            // 413 955` -- y=45 is ALREADY the bar's painted bottom edge.
            popup: true
        }
    }
}


