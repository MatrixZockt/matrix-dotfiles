import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import Quickshell

/**
 * Popup card used by the bar (battery, clock, weather, resources, tray
 * overflow) as a real anchored child popup instead of a free-floating
 * window.
 *
 * It is a PopupWindow anchored to the item that opened it: it hangs below
 * that item on a top bar (above it on a bottom bar), grows down-left /
 * up-left so its right edge lines up with the item, and the compositor
 * slides/flips it back on screen when it would overflow. The geometry is
 * snapshotted once at open time into `anchor.rect` -- the same
 * reload-crash-safe approach SessionMenu uses: no live item pointer is kept,
 * so a hot reload while a popup is open cannot dangle the anchor (the
 * PopupAnchor::setItem segfault this codebase hit once).
 */
LazyLoader {
    id: root

    property Item hoverTarget
    default property Item contentItem
    property real popupBackgroundMargin: 0

    // Click-to-open mode (clock, battery detail): the owner toggles
    // `requestOpen`, and the popup closes itself once the pointer has left
    // both the popup and the thing that opened it. Without it the popup is
    // hover-driven: open while the pointer is on the target.
    property bool clickOnly: false
    property bool requestOpen: false
    signal autoClose()

    // Milliseconds the pointer may be off both the popup and its opener
    // before `autoClose` fires. See the timer at the bottom of the component.
    property int closeDelay: 1500

    // ── Held open by a menu, not by the pointer ─────────────────────────
    //
    // A row inside the card can open a context menu of its own, in ANOTHER
    // window, hanging off the card. Getting to it means moving the pointer
    // off the card and onto that window -- and a card whose rule is "the
    // pointer left, so close" reads that as the pointer leaving for good.
    //
    // On the tray that was fatal rather than merely premature. The card
    // closes -> `shouldShow` goes false -> `active` goes false -> and
    // `LazyLoader` DESTROYS its component, which is the card's own content:
    // the delegate, the `Loader` inside it and the menu window that delegate
    // owns all go with it, mid-gesture. The right-click menu appeared and
    // was taken away again in the same quarter second, which reads as the
    // tray having ignored the right-click entirely.
    //
    // So a caller whose content can raise a menu sets this, and the card
    // stays up for as long as the menu is. The pointer still closes it
    // normally the moment the menu is gone.
    property bool holdOpen: false

    // ── The open/close animation, opt-in ────────────────────────────────
    //
    // OFF by default, and that is a deliberate blast-radius choice: this
    // component is shared by the battery, clock, weather and resources
    // cards, and changing how all of them open is a different decision
    // from changing how the tray does. A caller that wants it sets
    // `animateIn: true` and gets the pair below.
    property bool animateIn: false

    // What the pointer wants. This expression used to BE `active`, and it
    // still decides everything when `animateIn` is off.
    readonly property bool shouldShow: hoverTarget
        && (holdOpen || (clickOnly ? requestOpen : hoverTarget.containsMouse))

    // What the animation actually plays against, and what is allowed to
    // outlive `shouldShow` for a moment.
    //
    // LazyLoader DESTROYS its component the instant `active` goes false --
    // that is the whole point of the type. So driving opacity and scale
    // straight off `active` gives an entrance and no exit at all: the card
    // would fade up on the way in and simply cease to exist on the way out.
    // Hence the linger -- `shown` drops immediately so the exit curve
    // starts, and `active` stays true until the curve has finished, so
    // there is still an object on screen to play it on.
    property bool shown: false

    active: animateIn ? (shown || closeLinger.running) : shouldShow

    onShouldShowChanged: {
        if (!animateIn)
            return;
        if (shouldShow) {
            shown = true;
            closeLinger.stop();
        } else if (shown) {
            shown = false;
            closeLinger.restart();
        }
    }
    Component.onCompleted: {
        if (animateIn && shouldShow)
            shown = true;
    }

    // Slightly longer than the exit curve, so the card is fully gone before
    // the window is. Trimming it to exactly the curve duration tears the
    // last frame off the animation, which is visible as a flicker on close.
    //
    // Declared as a PROPERTY VALUE, and that is load-bearing twice over.
    // `LazyLoader`'s default property is `component`
    // (LazyLoader.qmltypes: defaultProperty: "component"), so a bare
    // `Timer { }` written as a child here is not parented to this object at
    // all -- it is assigned to the COMPONENT property, where it replaces
    // the PopupWindow and is then replaced by it. The symptom is not a load
    // error but "ReferenceError: closeLinger is not defined" from the
    // bindings above, because the object the id named no longer exists
    // anywhere. `data: [ ... ]` is not the way out either: `data` is not
    // assignable on this type ("Cannot assign to non-existent property
    // data"). An object assigned to a property IS parented to the object
    // that declares it, which is what we actually need -- so the Timer goes
    // in a property, and is reached as `closeLinger` rather than by id.
    readonly property Timer closeLinger: Timer {
        interval: Appearance.animation.elementMoveExit.duration + 40
    }

    // Space around the card inside the window: the visual gap to the item,
    // and room for the drop shadow so it is not clipped.
    readonly property real gap: 10

    component: PopupWindow {
        id: popupWindow

        visible: true
        color: "transparent"

        readonly property real screenW: root.QsWindow?.window?.screen?.width ?? 1000
        readonly property real screenH: root.QsWindow?.window?.screen?.height ?? 800
        readonly property real maxPopupHeight: Math.max(120, screenH - Appearance.sizes.barHeight - Appearance.sizes.elevationMargin * 2)

        implicitWidth: Math.min(popupBackground.implicitWidth + root.gap * 2, Math.max(120, screenW - 16))
        implicitHeight: Math.min(popupBackground.implicitHeight + root.gap * 2, maxPopupHeight)

        function updateAnchor() {
            const item = root.hoverTarget;
            const win = item?.QsWindow?.window;
            if (!item || !win)
                return;
            const mapped = item.mapToItem(win.contentItem, 0, 0);
            anchor.window = win;
            anchor.rect = Qt.rect(mapped.x, mapped.y, item.width, item.height);
            if (Config.options.bar.vertical) {
                // Side bar: open beside the item instead of under it.
                anchor.edges = Edges.Left | Edges.Bottom;
                anchor.gravity = Edges.Right | Edges.Bottom;
            } else if (Config.options.bar.bottom) {
                // Bottom bar: the card grows up-left from the item's top edge.
                anchor.edges = Edges.Top | Edges.Right;
                anchor.gravity = Edges.Top | Edges.Left;
            } else {
                // Top bar: hang from the item's bottom edge, right edges aligned,
                // growing down-left -- directly under the thing that opened it.
                anchor.edges = Edges.Bottom | Edges.Right;
                anchor.gravity = Edges.Bottom | Edges.Left;
            }
            anchor.adjustment = PopupAdjustment.Flip | PopupAdjustment.SlideX | PopupAdjustment.SlideY;
        }
        Component.onCompleted: popupWindow.updateAnchor()

        // Input lands on the card only; the gap and shadow stay click-through.
        mask: Region {
            item: popupBackground
        }

        HoverHandler {
            id: popupHoverHandler
        }
        // How long the pointer may sit off BOTH the popup and the thing
        // that opened it before the popup gives up and closes.
        //
        // 1500 by default, which is a long time to be looking at a card you
        // are no longer touching. It is a property rather than a literal
        // because the timer is shared by every popup in the bar, and the
        // right delay is not the same for all of them: this is a grace
        // period, and how much grace depends on how far the pointer is
        // going to wander. The tray sets 400 because it is a two-icon
        // flyout that was opened deliberately and is read at a glance --
        // lingering on it after the pointer has left is not a thing anyone
        // does with a card that small. The clock and battery cards keep the
        // long one, because those are read WHILE the pointer is on them and
        // the delay only matters on the way out.
        Timer {
            interval: root.closeDelay
            running: root.clickOnly && root.requestOpen
                && !root.holdOpen
                && !popupHoverHandler.hovered
                && !(root.hoverTarget && root.hoverTarget.containsMouse)
            onTriggered: root.autoClose()
        }

        StyledRectangularShadow {
            target: popupBackground
        }

        Rectangle {
            id: popupBackground
            readonly property real margin: 10
            anchors.centerIn: parent
            implicitWidth: root.contentItem.implicitWidth + margin * 2 + root.popupBackgroundMargin
            implicitHeight: root.contentItem.implicitHeight + margin * 2 + root.popupBackgroundMargin
            // Translucent on purpose, and this is the whole reason the
            // compositor blur behind this popup is visible at all.
            //
            // The layer rule already exists -- custom/rules.lua sets blur and
            // ignore_alpha = 0 on `quickshell:barPanel`, and its own comment
            // describes the intended result as "translucent card +
            // compositor blur". But m3surfaceContainer is #201f20, fully
            // opaque, so the card painted over the top of the blurred layer
            // and the frosting never showed: the blur was running, and the
            // user saw nothing.
            //
            // 0.93 is deliberately faint. The card is a dark surface over a
            // blurred desktop, so the text contrast barely moves -- and a
            // stronger translucency starts letting bright windows behind the
            // popup bleed through the small, bright type. This is meant to
            // read as "there is a layer here", not as a sheet of glass.
            color: ColorUtils.applyAlpha(
                Appearance.m3colors.m3surfaceContainer, 0.93)
            radius: Appearance.rounding.small
            children: [root.contentItem]

            border.width: 1
            border.color: Appearance.colors.colLayer0Border

            // ── The animation ───────────────────────────────────────────
            // FADE plus a small GROW from the edge nearest the thing that
            // opened it. Not a slide: the card is anchored to that edge, so
            // sliding moves the edge the user just aimed at, and the aim
            // point is the one thing about a popup that must not move.
            // Growing from that same edge keeps the target still and still
            // reads as "coming out of" it.
            //
            // 0.96 is a small enough travel to read as material rather than
            // as a zoom. Anything past ~0.9 starts looking like a transition
            // between two different cards.
            opacity: !root.animateIn ? 1 : (root.shown ? 1 : 0)
            scale: !root.animateIn ? 1 : (root.shown ? 1 : 0.96)
            // Grow AWAY from the bar, i.e. from the edge the popup is
            // anchored to, so the anchored edge stays pinned under the
            // pointer for the whole animation.
            transformOrigin: {
                if (Config.options.bar.vertical)
                    return Config.options.bar.bottom ? Item.Left : Item.Right;
                return Config.options.bar.bottom ? Item.Bottom : Item.Top;
            }

            // The same asymmetric pair the tray's hover plate uses: a long
            // decel on the way in, a short accel on the way out. A popup
            // that leaves as slowly as it arrives feels like it is
            // hesitating, and exit is the half of the motion nobody is
            // waiting for.
            Behavior on opacity {
                animation: (root.shown
                    ? Appearance.animation.elementMoveEnter
                    : Appearance.animation.elementMoveExit).numberAnimation.createObject(this)
            }
            Behavior on scale {
                animation: (root.shown
                    ? Appearance.animation.elementMoveEnter
                    : Appearance.animation.elementMoveExit).numberAnimation.createObject(this)
            }
        }
    }
}
