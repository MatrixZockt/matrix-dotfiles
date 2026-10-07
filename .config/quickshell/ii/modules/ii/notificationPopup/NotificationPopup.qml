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
        // 12px, and the SAME 12px on both axes. That is the whole design: a
        // notification belongs to the corner, sitting just inside it the way
        // a card rests on a table. Symmetry is what makes it read as tucked
        // in rather than parked -- an inset on one axis and a different one
        // on the other looks like a misalignment, and a large inset looks
        // like a panel that lives there rather than something that arrived.
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
        // that widening the gap never pushes the card off the surface.
        readonly property real cardWidth: Appearance.sizes.notificationPopupWidth - Appearance.sizes.elevationMargin * 2
        implicitWidth: cardWidth + edgeGap + Appearance.sizes.elevationMargin * 2

        NotificationListView {
            id: listview
            anchors {
                top: parent.top
                bottom: parent.bottom
            }
            topMargin: root.edgeGap
            // Positioned explicitly, NOT with `anchors.right` + `rightMargin`
            // and NOT with `implicitWidth`.
            //
            // Both of those were tried and both are wrong here, in a way that
            // looks correct in the source. Measured at edgeGap 3 and again at
            // 6: raising the gap moved the card's LEFT edge right (1207 ->
            // 1210) and its RIGHT edge right with it (1597.5 -> 1599.4),
            // instead of moving the right edge left. The card stayed flush
            // against the screen edge at every value, while the window grew
            // to match (413 -> 416 wide) -- so the gap bought empty surface
            // on the wrong side and nothing at all on the side it was for.
            //
            // The cause is `implicitWidth` on a Flickable-derived item: the
            // view is free to derive its own implicit width from its content,
            // so it is not a dependable way to set a width, and `rightMargin`
            // only offsets an anchor that actually took effect. Stating `x`
            // and `width` outright removes both assumptions -- the card is
            // placed from the window's own width, and the gap is a term in
            // that arithmetic rather than something a margin has to honour.
            x: parent.width - root.edgeGap - root.cardWidth
            width: root.cardWidth
            popup: true
        }
    }
}


