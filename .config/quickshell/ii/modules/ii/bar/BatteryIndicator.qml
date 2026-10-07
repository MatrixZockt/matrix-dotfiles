import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts
// `Edges` comes from Quickshell; without this import the hover chip's
// `anchorEdges` binding fails (ReferenceError) and the bubble is placed by
// fallback instead of sitting under the indicator like the wifi/bluetooth chips.
import Quickshell

MouseArea {
    id: root
    property bool borderless: Config.options.bar.borderless
    readonly property var chargeState: Battery.chargeState
    readonly property bool isCharging: Battery.isCharging
    readonly property bool isPluggedIn: Battery.isPluggedIn
    readonly property real percentage: Battery.percentage
    readonly property bool isLow: percentage <= Config.options.battery.low / 100

    // The bolt's slot, reserved BY THIS ITEM rather than left to the inner
    // RowLayout to measure. The row's own implicit width never grew when the
    // bolt appeared (a hidden-then-shown Text child of a Layout does not
    // re-report its implicit width in this shell), so the item stayed 36 wide,
    // the bolt painted past the item's right edge -- over the neighbouring
    // icon and off the island -- and because every strip in the bar sizes off
    // implicit widths, nothing reflowed: the gaps went uneven as well.
    //
    // RESERVED ALWAYS, plugged in or not. It used to be reserved only while
    // `isPluggedIn`, which meant the space to the right of the battery was
    // `boltSlot` with the cable in and exactly nothing without it -- the bar
    // changed width when you plugged a charger in, for a bolt that appears
    // and disappears many times a day. The user's report, 2026-09-29: "when
    // removing it I want the right side of the battery to have the same
    // spacing, currently it has 0 spacing." The battery now measures the same
    // either way, and `chargingBolt.visible` is the only thing that changes.
    //
    // `boltGap` is the ONE number for the gap to the right of the battery,
    // and the bolt's slot is that gap plus the glyph. The bar sets it, so the
    // bolt sits exactly as far from the battery as every other icon in the
    // strip sits from its neighbour -- which is also how it went from 5 to
    // "more": the 5 was always going to read as tighter than the gaps
    // around it.
    //
    // `boltTrail` is the air booked AFTER the bolt, and it is the fix for the
    // 2026-10-06 report: "the charging flash symbol has no spacing to the
    // right". Measured on screen before it: the bolt's ink ended 3.3 logical
    // px from the island's edge, where any other icon ending the run shows
    // its inset (6) plus its own glyph bearing. The bolt fills its 12px slot
    // almost edge to edge, so with no trail the mark ended at the item's
    // right edge and the bar's own right inset landed outside the island,
    // past the glyph. Reserving the trail INSIDE the item is what moves the
    // glyph left without moving anything else: the strip hugs its content
    // against the right edge of the bar, so a wider item grows leftward and
    // only the bolt's distance to the island edge changes. The bar sets it so
    // that this trail plus the item's own `iconInset` right margin equal the
    // clock's leading air (`Appearance.rounding.screenRounding + 8`): the
    // right end of the bar is the left end mirrored, and the run's own gaps
    // stay `2 * iconInset`.
    property real boltGap: 8
    property real boltTrail: 0
    readonly property real boltSlot: Math.max(12, chargingBolt.implicitWidth) + root.boltGap + root.boltTrail
    implicitWidth: pillHost.implicitWidth + root.boltSlot
    implicitHeight: Appearance.sizes.barHeight

    // The detail card is CLICK driven. Hovering stays free for the tiny time
    // chip.
    //
    // The click is handled by this root MouseArea, NOT by a TapHandler child:
    // the indicator sits inside the bar's own section MouseArea, which grabs the
    // press before a TapHandler can ever complete, so a handler here never
    // fired and the battery was not clickable at all.
    onClicked: {
        if (panelLoader.item) {
            if (panelLoader.item.open)
                panelLoader.item.close();
            else
                panelLoader.item.open = true;
        } else {
            panelLoader.active = true;
        }
    }

    // The battery panel: a standalone "app" window over a blurred backdrop,
    // built on first click.
    Loader {
        id: panelLoader
        active: false
        sourceComponent: BatteryPanel { anchorItem: root }
        onLoaded: panelLoader.item.open = true
    }

    hoverEnabled: !Config.options.bar.tooltips.clickToShow
    cursorShape: Qt.PointingHandCursor

    // NO hover plate. The rounded fill this used to paint (margins 3) read as
    // an oval hovering behind the pill, the same stray shape the connectivity
    // pill's default hover fill was -- and this control's hover response is
    // the liquid pocket dropping out of the bar anyway, plus the time chip
    // under it. A third surface repeating "you are here" was one too many.

    RowLayout {
        id: batteryContent
        // Sized EXPLICITLY from the item's own reserved width, not from
        // `anchors.centerIn`. A RowLayout that is only anchored sizes itself to
        // its implicit width, and that implicit width does not grow when a
        // `Text` child flips `visible` -- it stayed 36 with the bolt on screen,
        // so the row laid the bolt out on top of the pill's own 36px. The
        // width the item already reserves (`root.implicitWidth`, pill +
        // `boltSlot`) is the honest box, and the row fills it exactly.
        width: root.implicitWidth
        anchors.verticalCenter: parent.verticalCenter
        // LEFT to right: pill, then the bolt. The bolt belongs on the RIGHT of
        // the battery again (requested 2026-09-29) -- that is the side facing
        // the screen edge, so the icon it sits next to is the charge state and
        // nothing else. The row grew its bolt on the wrong side before.
        //
        // `spacing` is the ONE gap between them, and it is the same 5px the
        // reserved `boltSlot` books, so the gap measures 5 whether or not the
        // cable is in -- plugging in shifts the neighbouring icons instead of
        // changing this distance. Never a per-item margin: a margin on a
        // hidden item still reserves nothing, so the gap jumped every time
        // the bolt appeared.
        layoutDirection: Qt.LeftToRight
        spacing: root.boltGap

        // The pill, back by popular demand: a ClippedProgressBar in the OneUI 7
        // style -- capsule track, proportional fill, and the percentage text
        // acting as a mask (the digits are "cut out" of the fill, so they are
        // legible over any charge level and the fill boundary can slice straight
        // through them without hurting readability). One change from the very
        // first version: the ends are rounded with the theme's `small` radius
        // instead of a full capsule, so the border is less round as asked.
        // Host for the pill. Sized exactly to the pill so the RowLayout
        // centers it vertically in the bar (an earlier charging badge used a
        // 6px top overhang + bottom anchoring here, which sat the pill too
        // low in the bar).
        Item {
            id: pillHost
            implicitWidth: batteryProgress.valueBarWidth
            implicitHeight: batteryProgress.valueBarHeight

            ClippedProgressBar {
                id: batteryProgress
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                valueBarWidth: 36
                valueBarHeight: 18
                radius: Appearance.rounding.small
                value: root.percentage
                highlightColor: (root.isLow && !root.isPluggedIn)
                    ? Appearance.m3colors.m3error
                    : Appearance.colors.colPrimary
                // OneUI 7 style: the digits are "cut out" of the fill, so
                // they are legible over any charge level.
                textMask: Item {
                    width: batteryProgress.valueBarWidth
                    height: batteryProgress.valueBarHeight
                    StyledText {
                        anchors.centerIn: parent
                        font.pixelSize: 11
                        font.weight: Font.DemiBold
                        text: Math.round(root.percentage * 100)
                    }
                }
            }

        }

        // Charging indicator: a small bolt right NEXT to the pill (the
        // user's ask), vertically centered with it. Sits after the pill in
        // the RowLayout, so it can never mangle the pill's text mask --
        // ClippedProgressBar's default property is that mask, so nothing
        // may be declared INSIDE the pill itself.
        // Shows whenever the machine is on AC (isPluggedIn): charging, full,
        // or holding at the firmware charge cap -- a strict Charging-only
        // gate left the bolt invisible exactly when the capped battery sits
        // plugged in at its target, which is the normal state on this laptop.
        MaterialSymbol {
            id: chargingBolt
            visible: root.isPluggedIn
            text: "bolt"
            fill: 1
            iconSize: 12
            Layout.alignment: Qt.AlignVCenter
            // The trail as a real layout MARGIN, not as width left over:
            // a row handed more width than its children need spreads that
            // surplus around them (measured: the pill slid 6px left and the
            // bolt only 1.4px, so the extra air appeared BETWEEN the two
            // marks instead of after them). A margin is part of the layout
            // arithmetic, so the surplus is exactly consumed and the bolt
            // ends `boltTrail` px before the item's right edge -- the air
            // that is then visible between the glyph and the island.
            Layout.rightMargin: root.boltTrail
            color: Appearance.colors.colPrimary
        }
    }

    // Small hover chip: ONLY the time bit -- remaining battery life while
    // unplugged, time until full while charging. No percentages, no wattage:
    // all of that lives in the battery panel, and one compact chip is what a
    // hover is for.
    //
    // The firmware cap case: this Surface holds the battery at 50%, so UPower
    // reports pending-charge with timeToFull = 0 even on a live cable. The
    // chip is honest about the math without sounding like a broken cable:
    // "Full in 0m" -- the battery is AT its (capped) target.
    //
    // PopupToolTip (the same widget the wifi and bluetooth chips use) instead
    // of StyledToolTip: it hangs the bubble directly under the indicator
    // itself, so the bubble sits in the same place as the other hover chips
    // instead of wherever the Tooltip singleton decides to put it.
    PopupToolTip {
        // Always worth showing: the percentage is meaningful on every hover,
        // whatever the charge state. (Previously the tooltip only appeared
        // while charging or with a known drain time, so most hovers gave
        // nothing at all.)
        //
        // BUT not while the liquid pocket is open: the bar now drops the
        // charge, state and time out of its own underside on hover, and the
        // floating card on top of that was literally a second layer over the
        // droplet -- the same information twice, one of them covering the
        // droplet's own right-hand column. This is the same gate the wifi and
        // bluetooth chips use.
        extraVisibleCondition: root.containsMouse && LiquidBar.pocketId === ""
        anchorEdges: Config.options.bar.bottom ? Edges.Top : Edges.Bottom
        text: {
            const pct = Translation.tr("%1%").arg(Math.round(root.percentage * 100));
            if (Battery.isPluggedIn) {
                if (Battery.chargeState === 4 || Battery.isFull)
                    return `${pct} · ${Translation.tr("Fully charged")}`;
                const h = Math.floor(Battery.timeToFull / 3600);
                const m = Math.floor((Battery.timeToFull % 3600) / 60);
                return `${pct} · ${Translation.tr("Full in %1m").arg(m)}`;
            }
            if (Battery.timeToEmpty > 0 && Battery.chargeState !== 4) {
                const h = Math.floor(Battery.timeToEmpty / 3600);
                const m = Math.floor((Battery.timeToEmpty % 3600) / 60);
                return h > 0
                    ? `${pct} · ${Translation.tr("%1h %2m remaining").arg(h).arg(m.toString().padStart(2, "0"))}`
                    : `${pct} · ${Translation.tr("%1m remaining").arg(m)}`;
            }
            return pct;
        }
    }

}

// touch
