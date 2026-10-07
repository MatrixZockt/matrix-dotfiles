import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Services.SystemTray
// For `GlobalStates`, which owns the dropdown's open state.
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets

// ── The system tray, Windows style ──────────────────────────────────────
//
// One `^` button, always there, and a card under it holding every tray
// icon. That is the whole shape of the thing, and it is the shape Windows
// has: the notification area is a single collapsed control, and the icons
// come out of it in a flyout rather than living in the bar.
//
// It used to be the other way round. The bar grew a row of tray icons and
// a 24px chevron to reach the overflow, so the two fought for the same
// strip, the icons could collide with the inline pocket, and there was no
// single place that meant "the tray". Collapsed-by-default fixes all three:
// the strip gives up one fixed 26px cell, and the icons appear where there
// is room for them.
//
// Why the chevron is ALWAYS visible, even with an empty tray: it is the
// affordance. A control that only exists once something has registered
// cannot be learned, cannot be aimed at, and makes the bar's own layout
// jump the first time an app starts. Windows shows `^` unconditionally for
// the same reason, and an empty card says "No tray applications" instead
// of leaving the user hunting for a button that is not there.
Item {
    id: root
    implicitWidth: trayOverflowButton.implicitWidth
    implicitHeight: trayOverflowButton.implicitHeight
    property bool vertical: false
    property bool invertSide: false
    // The dropdown's open state lives in GlobalStates, not here, so it can be
    // driven from outside the bar. This file is a plain Item buried inside
    // BarContent's layout: with the state local there was no way to open the
    // dropdown without a physical click on a 24px arrow, which made it
    // impossible to verify it rendered anything.
    readonly property bool trayOverflowOpen: GlobalStates.trayOverflowOpen
    property bool showOverflowMenu: true
    // Kept because call sites set it (the lock screen's Fcitx indicator), and
    // a binding to a property that no longer exists is a load error that takes
    // the whole config down -- not something to discover at runtime.
    //
    // It no longer paints anything. The dot existed to separate the chevron
    // from the icons that used to slide out beside it; the icons now live in
    // a panel, so there is nothing on the bar for a separator to divide.
    property bool showSeparator: true
    property var activeMenu: null

    // ── What the card holds ─────────────────────────────────────────────
    // EVERY registered tray item, pinned ones first, in one list.
    //
    // The two lists used to be treated as two destinations -- pinned icons
    // on the bar, unpinned ones in the dropdown -- and each had its own
    // cap, slice and count. With the bar collapsed to a single chevron
    // there is only one destination, so there is only one list: `allItems`
    // is both of them, concatenated. An app that has registered a tray
    // icon is reachable, and the order inside each half is the app's own.
    //
    // SETTABLE, not readonly, and that is the one concession to the older
    // shape: the lock screen uses this same component to show a single
    // specific tray icon (Fcitx's keyboard layout) with no chevron and no
    // card, so it assigns its own list.
    //
    // Filtered through `TrayApps.isDeadItem`, and this is a FILTER ON THE
    // MODEL rather than a hidden delegate -- the same distinction the
    // `liveRegistry` note below makes. The card's grid is placed by hand
    // from the cells that exist, so an item hidden with `visible: false`
    // would leave an empty gap in the middle of the tray, exactly the
    // shape of the icon that was removed.
    property list<var> allItems: TrayService.pinnedItems
        .concat(TrayService.unpinnedItems)
        .filter(i => !TrayApps.isDeadItem(i))
    // Icons the SHELL owns, for apps that register no tray item of their
    // own (Thunderbird on Linux). They are listed after the real ones --
    // an app that asked for a tray icon asked to be found -- but they count
    // towards the same grid, because the card is "everything in the tray"
    // and leaving the shell's own icons in a second row below it would
    // split that in two.
    //
    // `liveRegistry`, NOT `registry`: an app that is not running has no
    // tray icon, exactly as it would be if it registered one itself. See
    // the note on that property for why a permanently-present icon is a
    // launcher wearing a tray icon's clothes. Filtering the MODEL rather
    // than hiding the delegate is the part that matters -- the grid is
    // placed by hand from the cells that exist, so a hidden-but-present
    // delegate would leave an empty gap in the card exactly the shape of
    // the icon that was removed.
    property list<var> ownedItems: TrayApps.liveRegistry

    // ── The two halves of the card ─────────────────────────────────────
    //
    // Everyday APPS in the main grid; BACKGROUND SERVICE NOISE (avahi,
    // NetworkManager, portals, polkit, the distro package managers -- see
    // services/TrayNoise.qml) behind one collapsible "Advanced" row.
    //
    // Split on the MODEL, not by hiding delegates. The grid below is placed by
    // hand from the cells that exist, so a delegate left in the model with
    // `visible: false` would leave a hole in the card exactly the shape of the
    // icon that was "hidden" -- the same reason `allItems` filters rather than
    // hides.
    //
    // Both halves go through the same filter as `allItems` (dead classes)
    // first, so a reaped app leaves neither grid.
    readonly property var liveItems: allItems.concat(ownedItems)
    readonly property var appItems: liveItems.filter(i => !TrayNoise.isService(i))
    readonly property var serviceItems: liveItems.filter(i => TrayNoise.isService(i))

    // Whether the "Advanced" group of background services is open. COLLAPSED
    // on purpose: the whole point is that the everyday icons are what you see
    // when the card opens, and a tray full of daemons is only ever something
    // you go and look at deliberately.
    property bool advancedExpanded: false

    // Is there anything in the card? Only the card's EMPTY STATE asks; the
    // button does not -- see the note on `showOverflowMenu` below.
    readonly property bool hasItems: root.liveItems.length > 0

    // ── "Something new is in the tray" ────────────────────────────────
    //
    // A stable identity for the tray's current contents: the registered
    // items by their StatusNotifier `id`, the shell's own by window class.
    //
    // IDENTITY, not the count, and that is the whole design. `ownedItems` is
    // now "apps that are running", so it SHRINKS when an app quits. A
    // count-based check would read a quit followed by a start as a net
    // change of zero and stay silent, or -- worse -- read one quit as one
    // arrival and ping for an icon that is on its way out. Comparing the
    // sets answers the only question that matters: is there a name here
    // that was not here before?
    readonly property string trayIdentity: {
        return liveItems.map(i => {
            if (i && i.id !== undefined) return "s:" + i.id;
            if (i && i.cls) return "o:" + i.cls;
            return "?";
        }).join(",");
    }
    property string seenIdentity: ""
    // The first evaluation is everything that was already in the tray when
    // the shell started. Pinging once per icon at login would be noise, not
    // news -- the user did not just start those apps, they started them
    // before the bar existed.
    property bool identityPrimed: false

    onTrayIdentityChanged: {
        if (!identityPrimed) {
            identityPrimed = true;
            seenIdentity = root.trayIdentity;
            return;
        }
        const seen = {};
        for (const key of seenIdentity.split(","))
            if (key)
                seen[key] = true;
        let isNew = false;
        for (const key of root.trayIdentity.split(",")) {
            if (key && !seen[key]) {
                isNew = true;
                break;
            }
        }
        seenIdentity = root.trayIdentity;
        // Only while the card is CLOSED. Open, the new icon is already on
        // screen being looked at, and a pulse would be announcing something
        // the user can already see.
        if (isNew && !GlobalStates.trayOverflowOpen)
            newIconRing.ping();
    }

    // The flyout's grid: as square as the count allows, so a row of three
    // does not read as a lopsided 2+1. Bounded at 8 columns, because past
    // that a tray flyout is a wall of icons and the card outgrows the
    // screen it is trying to stay on.
    readonly property int gridColumns: Math.max(1, Math.min(8, Math.ceil(Math.sqrt(root.appItems.length || 1))))
    // One cell for one icon, sized like the other bar cells so the chevron
    // sits in the strip on the same rhythm as the sound and battery
    // buttons around it.
    readonly property int cellSize: 26
    // The icon INSIDE that cell. This has to be its own number, and it is
    // smaller than the cell on purpose: `SysTrayItem`/`SysTrayAppItem` size
    // their IconImage off `iconSize` and fall back to `parent.width` when it
    // is 0, so leaving it unset drew a 26px icon in a 26px cell -- the glyph
    // hard against the cell edge with no breathing room on any side, which
    // is what read as "the icons are too big".
    readonly property int iconSize: 18
    // Bigger inside the card, where the icons are the thing being aimed at
    // rather than glanced at, and where a 26px icon in a 26px cell leaves no
    // room for the hover plate to read.
    //
    // 32 for the cell, 18 for the icon.
    //
    // This number has been moved four times in one session, and the reason
    // it kept landing in the wrong place is that the SIZE was rarely the
    // complaint -- the RENDERING was. At 38/22 the icons were a size too
    // big, which is what a 128px bitmap point-sampled down to 22px looks
    // like: a soft-edged blob with no readable interior. Shrinking it to
    // 34/20 did not fix that, it just made the blob smaller, which is why
    // 16 read as "too small" rather than as tidy. Now that the artwork is
    // decoded at the drawn size (see SysTrayItem) the shape survives the
    // downscale and these two numbers are finally just a size preference.
    //
    // The cell comes down with the icon so the 7px of breathing room on
    // each side is preserved: dropping the icon alone would have made the
    // cell 34 wide around an 18px glyph, i.e. 8px a side, and the hover
    // plate would have started to look like the icon's own padding rather
    // than a separate target.
    readonly property int panelCellSize: 32
    // A tray app publishes ONE small pixmap and nothing else, so this is
    // always a resample of the source rather than an upscale of something
    // tiny -- and it now happens once, on the CPU, at this size.
    readonly property int panelIconSize: 18

    function grabFocus() {
        focusGrab.active = true;
    }

    function setExtraWindowAndGrabFocus(window) {
        if (root.activeMenu && root.activeMenu !== window) {
            if (typeof root.activeMenu.close === "function")
                root.activeMenu.close();
            root.activeMenu = null;
        }
        root.activeMenu = window;
        // Restart the hold's own watchdog (see below). A new menu is a new
        // chance to close cleanly, and a stale count would cut a menu that
        // has only just opened.
        if (window)
            root.menuHoldTicks = 0;
        root.grabFocus();
    }

    // The card is held open while one of its rows has a context menu out --
    // see `holdOpen` on StyledPopup for why that is not optional. The hold
    // has to be able to END BY ITSELF, though, because a menu can die
    // without ever saying so: the app it belongs to quits, the model changes
    // under it, the delegate is destroyed. In that case `menuClosed` never
    // arrives, and a card held open by a menu that no longer exists is a
    // card with nothing in it to click.
    //
    // Twenty seconds is far longer than any real interaction with a
    // three-row menu, and short enough that a stuck card is not something
    // anyone has to live with or work around.
    property int menuHoldTicks: 0
    Timer {
        interval: 500
        repeat: true
        running: root.activeMenu !== null
        onTriggered: {
            if (root.activeMenu === null)
                return;
            if (++root.menuHoldTicks >= 40)
                root.setExtraWindowAndGrabFocus(null);
        }
    }

    function releaseFocus() {
        focusGrab.active = false;
    }

    function closeOverflowMenu() {
        // Also drop the dropdown itself. An app quitting while its card is
        // open used to leave the card hanging over the bar with one fewer
        // icon in it, and the arrow still showing its clicked plate.
        focusGrab.active = false;
        GlobalStates.trayOverflowOpen = false;
    }

    Connections {
        // An app quitting must not leave an orphan cell behind: the card's
        // grid is rebuilt from `allItems` on every change, so a stale icon
        // would otherwise survive until the shell was reloaded.
        function onAllItemsChanged() {
            if (!root.hasItems)
                root.closeOverflowMenu();
        }
    }

    HyprlandFocusGrab {
        id: focusGrab
        active: false
        // ONLY the per-app context menu. The dropdown deliberately is NOT in
        // this list: it used to be, as `trayOverflowLayout.QsWindow?.window`
        // -- but that is a GridLayout inside the dropdown, not a window, so
        // the list was [undefined, null] and the grab had nothing to hold.
        // It cleared on the spot, `onCleared` set trayOverflowOpen back to
        // false, and the arrow's clicked background plate came and went in
        // the same frame. That was the "dropdown does nothing" and the
        // stuck highlight on the arrow, and it is one bug, not two.
        windows: [root.activeMenu]
        onCleared: {
            GlobalStates.trayOverflowOpen = false;
            if (root.activeMenu) {
                root.activeMenu.close();
                root.activeMenu = null;
            }
        }
    }

    // ── No chevron: the items ARE the control ───────────────────────────
    // `showOverflowMenu: false` means the caller wants the icons in the
    // strip, not behind a button. The lock screen uses this for the Fcitx
    // keyboard-layout icon, which is a status readout rather than a place
    // to go: it has one item, it never changes, and a card with a single
    // icon in it would be two clicks to read one glyph.
    //
    // Kept in the SAME component as the bar's tray on purpose. It used to
    // be a second mode of this file -- the icons on the bar, the chevron
    // to their overflow -- and the two are not the same thing any more:
    // here the icons are always open and there is no card at all, so
    // there is nothing to toggle and nothing to overflow.
    RowLayout {
        id: inlineRow
        visible: !root.showOverflowMenu && root.allItems.length > 0
        spacing: 6
        Layout.fillHeight: true

        Repeater {
            model: root.allItems

            delegate: SysTrayItem {
                required property SystemTrayItem modelData
                item: modelData
                cellSize: root.cellSize
                iconSize: root.iconSize
                onMenuClosed: root.releaseFocus();
                onMenuOpened: (qsWindow) => root.setExtraWindowAndGrabFocus(qsWindow);
            }
        }
    }

    RippleButton {
        id: trayOverflowButton
        // Unconditional. The `totalItemCount > 0` gate this replaced made
        // the control appear and disappear with the tray's contents, which
        // is exactly the behaviour Windows avoids by showing `^` always --
        // and which cost the bar a reflow every time an app started or quit.
        visible: root.showOverflowMenu
        // `anchors.fill`, NOT `Layout.fillHeight` / `Layout.fillWidth`.
        //
        // This button's parent is `root`, the plain `Item` at the top of this
        // file -- NOT a RowLayout or ColumnLayout. Layout attached properties
        // are only honoured by a parent that IS a layout, so both of those
        // were silently inert: the button never filled the cell the bar's row
        // gave it, and instead sat at y=0 at its own 26px implicit height.
        // The glyph's ink then measured y 10-30, centre 20.0, in a bar whose
        // own rows are 8-71 (centre 39.5) -- the arrow rode the top edge,
        // 19.5px above the wifi, bluetooth and volume glyphs beside it.
        //
        // Confirmed by substitution rather than inferred: putting `wifi` in
        // this slot measured centre 20.0 as well, while the real wifi in the
        // row measured 38.0. A font-metric quirk would have moved the
        // chevron but not a same-size glyph in the same font, so the fault was
        // the cell, not the font.
        //
        // Anchors work here because a plain Item is a perfectly good parent
        // for them, and they do not fight anything: `root`'s implicit size is
        // read from this button's IMPLICIT size, which anchoring leaves alone.
        anchors.fill: parent
        // On the BUTTON, not on `background`. `RippleButton` is a QtQuick
        // Controls `Button`, whose `implicitWidth` is
        // max(background, content) + leftPadding + rightPadding -- and the
        // default padding is 6 a side. Setting only
        // `background.implicitWidth` therefore bought a 26px plate inside a
        // 38px cell, and the layout reserved all 38: 6px of dead air on
        // each side of the chevron, a strip-wide gap to the connectivity
        // pill of 44px between glyphs where every other pair is 12, and a
        // bar island 12px wider than the icons in it. The other bar buttons
        // set it on the control for the same reason.
        implicitWidth: root.cellSize
        implicitHeight: root.cellSize
        background.implicitWidth: root.cellSize
        background.implicitHeight: root.cellSize
        background.anchors.centerIn: this
        toggled: GlobalStates.trayOverflowOpen
        property bool containsMouse: hovered

        downAction: () => {
            // Opens/closes the panel below the bar. Nothing is revealed
            // in place, so the bar's own strip is unchanged by the click
            // and the inline pockets keep their width.
            GlobalStates.trayOverflowOpen = !GlobalStates.trayOverflowOpen;
        }

        // No plate behind the arrow -- not when open, not on hover, and no
        // ripple disc either. This is the same call already made for the
        // bar's other icon buttons: two near-identical greys sitting side
        // by side read as a rendering fault, and on a capsule-shaped bar
        // the eye reads the plate, not the glyph.
        //
        // The arrow is also the one control whose plate used to flicker:
        // its `toggled` state was being reset within the same frame (see
        // the focus-grab note above), so a grey disc would blink in and
        // out on the click. The feedback is the glyph instead -- it turns
        // to the on-container colour and swells slightly.
        colBackground: "transparent"
        colBackgroundHover: "transparent"
        colBackgroundToggled: "transparent"
        colBackgroundToggledHover: "transparent"
        colRipple: "transparent"
        colRippleToggled: "transparent"

        // A plain `Item` wrapper, NOT a bare `MaterialSymbol` as the
        // `contentItem`.
        //
        // A Control ASSIGNS its contentItem's geometry, and it does it by
        // setting x/y/width/height directly. Declaring `anchors.centerIn` on
        // that same item makes anchors and the Control both write the same
        // four properties, and the two disagree. The chevron lost: measured
        // on the live bar, its ink sat at y 16-24 (centre 20.0) while the
        // wifi, bluetooth and volume glyphs all centred on y 38.0 -- 19.5px
        // too high, riding the top edge of a 40px bar. The Control sized the
        // glyph box from the font's line metrics and the anchor then pulled
        // that box up out of the cell.
        //
        // With a plain Item as the contentItem, the Control only ever sizes
        // the WRAPPER, and the glyph is centred inside that wrapper by
        // anchors -- the same arrangement `HoverIconButton` uses for every
        // other icon in this strip, which is why those measure correct.
        contentItem: Item {
            implicitWidth: root.cellSize
            implicitHeight: root.cellSize

            // ── The "new in the tray" pulse ───────────────────────────
            // A thin ring that leaves the chevron once, when something new
            // arrives, and is gone again inside a second.
            //
            // A RING, not a filled disc, and it is sized by animating its
            // own width/height rather than a `scale`. Scaling a bordered
            // rectangle scales the border with it, so a "thin" 1px ring
            // ends the animation as a fat 2px one -- the stroke thickens
            // exactly as the shape grows, which is the opposite of a pulse.
            // Growing the rectangle instead keeps the stroke at 1px for the
            // whole flight.
            //
            // It is centred on the chevron and allowed to overflow the 26px
            // cell (an Item does not clip unless told to), so the ring is
            // visibly bigger than the button by the time it fades -- which
            // is what makes it read as something arriving FROM the tray
            // rather than as the button changing state.
            Rectangle {
                id: newIconRing
                anchors.centerIn: parent
                // The animated size lives on its own property so the
                // NumberAnimation has a plain real to drive; width/height
                // follow it.
                property real ringSize: root.cellSize
                width: ringSize
                height: ringSize
                radius: Appearance.rounding.full
                color: "transparent"
                border.width: 1
                border.color: Appearance.colors.colOnLayer2
                opacity: 0
                // Fully out of the tree when idle, so an invisible Rectangle
                // is not left sitting in the button's hit-test and focus
                // chain for the other 23 hours of the day.
                visible: opacity > 0.01

                NumberAnimation {
                    id: ringGrow
                    target: newIconRing
                    property: "ringSize"
                    from: root.cellSize
                    to: root.cellSize * 2.1
                    duration: 900
                    easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    id: ringFade
                    target: newIconRing
                    property: "opacity"
                    // Not from 0: a pulse that starts at nothing has no
                    // leading edge to read. It appears already present and
                    // leaves, which is what makes it an alert rather than a
                    // transition.
                    from: 0.9
                    to: 0
                    duration: 900
                    // Accelerating out, matching the exit half of the
                    // motion pair the hover plate and the card use. Same
                    // reason: nothing should take as long to leave as to
                    // arrive.
                    easing.type: Easing.InQuad
                }

                function ping() {
                    ringGrow.restart();
                    ringFade.restart();
                }
            }

            MaterialSymbol {
                id: chevronGlyph
                anchors.centerIn: parent
                iconSize: Appearance.font.pixelSize.larger
                // ONE glyph, always. The chevron points at what the click
                // will do, so it has to change direction -- but that change
                // is the ROTATION below, not a second glyph.
                //
                // It used to be both: `text` swapped `expand_more` for
                // `expand_less` (itself a 180° flip) while `rotation`
                // animated 0 -> 180 at the same time. Two independent
                // half-turns ran together and the arrow made a FULL 360°
                // turn on every open and every close -- twice the rotation
                // the eye was asked to follow, and it read as a spinner
                // rather than a disclosure. One glyph, one 180° turn.
                text: "expand_more"
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                color: GlobalStates.trayOverflowOpen
                    ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer2
                rotation: (GlobalStates.trayOverflowOpen ? 180 : 0) - (90 * root.vertical) + (180 * root.invertSide)

                // The state cue is COLOUR and FILL, never size.
                //
                // The `scale: 1.15` this replaces grew the arrow on hover and
                // while open. These glyphs are native-rendered, so a scale
                // stretches the already-rasterized pixels: the arrow visibly
                // softened at exactly the moment the eye was on it, and being
                // the one icon in the strip that changed size it also broke
                // the row's optical rhythm on press. The FILL axis redraws
                // the outline at the SAME size, so the feedback is crisper
                // than the swell was and nothing around it moves -- this is
                // what `HoverIconButton` already does for wifi, bluetooth and
                // volume.
                fill: (GlobalStates.trayOverflowOpen || trayOverflowButton.hovered) ? 1 : 0

                Behavior on fill {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                }
                Behavior on rotation {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                }
            }
        }
        }   // trayOverflowButton

        // ── The card ─────────────────────────────────────────────────────
        // A real popup hanging UNDER the chevron: the same StyledPopup the
        // battery, clock and resources cards use, so it inherits the
        // anchoring, the slide-back when it would overflow the screen, and
        // the close-when-the-pointer-leaves behaviour that are all proven
        // here.
        //
        // It replaces BarAnchoredPanel, which was the wrong component
        // twice over: it is a centred modal card with a dimmed backdrop
        // (not "a box under the arrow"), and it was driven through a
        // Connections pair that could silently skip opening.
        StyledPopup {
            hoverTarget: trayOverflowButton
            // Right-clicking an icon opens that icon's menu in another
            // window, which the pointer has to travel to -- so the pointer
            // necessarily leaves this card, and without the hold the card
            // takes that as its cue to close and destroy the menu with it.
            // Held for as long as a menu is out, capped by the watchdog
            // above so it cannot outlive one.
            holdOpen: root.activeMenu !== null
            // Opt in to the fade-and-grow. Off by default across the rest of
            // the bar's popups; the tray card is the one the eye lands on
            // directly from a click, so it is the one where the arrival is
            // most noticeable.
            animateIn: true
            // 400ms, not the shared 1500. This is a two-icon flyout: it was
            // opened deliberately and it is read at a glance, so a second and
            // a half of it still being open after the pointer has left reads
            // as the card having missed the click, not as patience.
            //
            // And MUCH less than 400 when the tray is EMPTY. The two numbers
            // are not two opinions about the same card, they are answers to
            // two different questions. 400 is how long a card the user is
            // reading deserves to survive the pointer leaving it. An empty
            // card is not being read -- it says one fixed line, "No tray
            // applications", and there is nothing in it to read. Keeping that
            // on screen for another 400ms buys nothing and reads as lag: you
            // clicked `^`, saw there was nothing, moved on, and the card was
            // still hanging in the corner after you had left it.
            //
            // 150ms, the middle of the 100-200ms band, rather than 0. Not
            // zero because the pointer is often still settling as it comes
            // off the arrow, and a card that vanished inside the same gesture
            // that opened it feels like the click did not register. Long
            // enough to be sure you meant to leave, short enough that you
            // are not looking at it while you leave.
            closeDelay: root.hasItems ? 400 : 150
            // Click, not hover: a dropdown that appears under a 26px arrow
            // the moment the pointer grazes it would be in the way of
            // every swipe past the end of the bar.
            clickOnly: true
            requestOpen: GlobalStates.trayOverflowOpen
            // The pointer leaving both the card and the arrow closes it,
            // which is what puts `trayOverflowOpen` back and drops the
            // arrow's background plate.
            onAutoClose: GlobalStates.trayOverflowOpen = false

            // The popup's own box. Only the grid's measured size is
            // forwarded: `StyledPopup` sizes its card off the content's
            // implicit width and height, and a plain `Item` has neither.
            //
            // The EMPTY case has to be sized separately, and it is not
            // cosmetic. With no items the grid measures 0x0, the card
            // measured 0x0 plus its margin, and the "No tray
            // applications" line was a `StyledText` wrapping inside a
            // zero-width box -- so the card opened as a 20px dot with
            // nothing legible in it, which reads exactly like a popup that
            // failed to open. The empty state is given a real box of its
            // own.
            Item {
                id: trayCardContent
                // This Item is the `contentItem` of the popup, and
                // `StyledPopup` parents it with `children: [contentItem]`
                // and NOTHING else -- no anchors, no x/y. A QML item with
                // no position sits at 0,0, so the grid was flush into the
                // card's top-left corner while the card itself was sized
                // from the grid's implicit size PLUS a 10px margin on every
                // side. The result was 10px of dead air on the right and
                // bottom and none at all on the left and top: measured on
                // the live card, the 72x34 content sat at (0,0) inside a
                // 92x54 box, i.e. 0px left, 0px top, 20px right, 20px
                // bottom. That is the report that the spacing below the
                // icons is bigger than the spacing at their sides.
                //
                // Centring the content in the card is the fix, and it is
                // the only place it can live: StyledPopup is shared with the
                // battery, clock, weather and resources cards, and those
                // position their own content. Sizing and centring THIS
                // item makes the four margins equal by construction --
                // whatever the cell, gap and count work out to.
                anchors.centerIn: parent
                // The card is now TWO things stacked: the everyday app grid and,
                // below it, the collapsible "Advanced" group of background
                // services. This Item sizes off both.
                //
                // It stays an Item, and the Advanced group below is ANCHORED,
                // not a ColumnLayout. That is deliberate and it is the whole
                // reason the layout wrapper was taken back out: the app grid's
                // cells are placed by hand (`layoutCells`, see below), and a
                // Repeater delegate's parent is its Repeater's parent -- so
                // every cell would become a DIRECT child of the ColumnLayout,
                // and QQuickLayout would lay it out again, on top of the
                // placement, from column and row numbers of its own. That is
                // the same class of bug as the GridLayout this file already
                // documents ("QQuickLayout never laid the delegates out"), just
                // with one more layout in the way. Anchors place the Advanced
                // group once and leave `layoutCells` alone.
                width: implicitWidth
                height: implicitHeight
                // ── The grid, done by hand ────────────────────────────────
                //
                // This was a `GridLayout` with a `Repeater` in it, and
                // QQuickLayout never laid the delegates out. Measured live
                // with two items registered (one real tray app plus the
                // shell's own Thunderbird):
                //
                //   grid implicit = 38x38   <- one cell, for two icons
                //   child[0] SysTrayItem     pos=0,0 size=38x38
                //   child[2] SysTrayAppItem  pos=0,0 size=38x38
                //
                // Both icons were drawn on the same 38x38 pixel, in a card
                // sized for one, so the app registered with a real tray item
                // was hidden underneath the shell's own icon and the whole
                // bottom of the card was empty -- which is the report that
                // the spacing under the icons is bigger than the spacing at
                // their sides. It is not a padding number that was wrong;
                // the icons were never placed.
                //
                // Four numbers now do the work -- cell, gap, cols, rows --
                // and the card's own size is computed from the same ones, so
                // the four margins are equal by construction and two icons
                // cannot land on the same pixel.
                readonly property int cell: root.panelCellSize
                readonly property int gap: 4

                // ── The app grid: the first row of the card ──────────────
                // No wrapper Item: the grid's contents (the cell/gap/cols/rows
                // numbers, the Repeater, the empty-state text) sit directly in
                // `trayCardContent`, so they fill this column's first row, and
                // `trayCardContent` keeps being the thing `layoutCells()`
                // addresses by name.

                // `cellCount`, `cols` and `rows` are PLAIN properties, written
                // by `layoutCells()` and read by nothing else. They were
                // bindings over `allItems.length + ownedItems.length` before,
                // and a binding re-evaluates lazily -- so `layoutCells()` could
                // run with the OLD column count while `implicitHeight` was
                // already reading the new one. Measured, with two icons:
                //
                //   cells = 0,0 38x38 | 0,42 38x38     <- placed as 1 column
                //   card  = 80x38                        <- sized as 2 columns
                //
                // A vertical pair in a card with one row's height: the second
                // icon hanging out underneath the box, which is the report.
                // One function now writes the numbers AND places the cells, so
                // the box cannot disagree with what is inside it.
                property int cellCount: 0
                property int cols: 1
                property int rows: 1

                // Place every cell, in creation order, and size the card from
                // the same numbers. Not a binding on `index`: both delegate
                // components declare `pragma ComponentBehavior: Bound`, and
                // under it the Repeater's injected context does not reach the
                // delegate -- `index` came back as "ReferenceError: index is
                // not defined" even when declared `required`, which is how
                // every icon ended up back at 0,0 in the first place.
                function layoutCells() {
                    const cells = children.filter(c => c && c.objectName === "trayCell");
                    const n = cells.length;
                    // As square as the count allows, so two icons sit side by
                    // side and three sit 2+1 rather than 1+1+1.
                    const cols = n > 0 ? Math.max(1, Math.min(8, Math.ceil(Math.sqrt(n)))) : 1;
                    const changed = n !== trayCardContent.cellCount;
                    trayCardContent.cellCount = n;
                    trayCardContent.cols = cols;
                    trayCardContent.rows = n > 0 ? Math.ceil(n / cols) : 1;
                    // Placed CENTRED in the box, not flush at 0,0. The card
                    // is sized from these same numbers, so the offsets below
                    // are 0 whenever the box and the grid agree -- and they
                    // pick up the slack the moment they do not (the Advanced
                    // group widening the plate, a floor coming back), instead
                    // of leaving it all on one side.
                    const gridW = n > 0 ? cols * cell + (cols - 1) * gap : 0;
                    const gridH = n > 0 ? trayCardContent.rows * cell + (trayCardContent.rows - 1) * gap : 0;
                    const offX = Math.round((Math.max(gridW, trayCardContent.serviceGridWidth()) - gridW) / 2);
                    const offY = Math.round((Math.max(gridH, n > 0 ? 0 : 40) - gridH) / 2);
                    for (let i = 0; i < n; i++) {
                        cells[i].x = offX + (i % cols) * (cell + gap);
                        cells[i].y = offY + Math.floor(i / cols) * (cell + gap);
                    }
                    // Re-check for a moment after a change.
                    //
                    // A Repeater's delegate joins `children` the instant it is
                    // created, but the rest of this component's arithmetic
                    // reads properties off it that are still being evaluated
                    // -- and the SECOND repeater's delegate is the one that
                    // changed the answer, so the run that mattered was the
                    // one that saw a half-built cell. A card laid out from
                    // that is a box sized for one icon with the other one
                    // placed underneath it, hanging out below the card.
                    if (changed) {
                        settleTicks = 3;
                        layoutSettle.running = true;
                    }
                }
                // Every delegate that appears or goes runs this again, so the
                // card is never a box around a stale arrangement.
                onChildrenChanged: layoutCells()
                Component.onCompleted: Qt.callLater(layoutCells)

                // The settling pass above, as a plain re-check rather than a
                // binding: a binding cannot re-evaluate itself, which is
                // exactly what is needed here.
                property int settleTicks: 0
                Timer {
                    id: layoutSettle
                    interval: 40
                    repeat: true
                    running: false
                    onTriggered: {
                        // Qualified: inside this Timer, an unqualified name
                        // resolves against the FILE's root Item, not against
                        // `trayCardContent`, so a bare `settleTicks` was a
                        // ReferenceError on every tick.
                        if (trayCardContent.settleTicks <= 0) {
                            running = false;
                            return;
                        }
                        trayCardContent.settleTicks--;
                        trayCardContent.layoutCells();
                    }
                }

                // The CARD's size, not the grid's: it is now the taller of the two
                // sections, and the widest of them, because `trayCardContent`
                // is the popup's contentItem and `StyledPopup` sizes the card
                // off exactly this. Sizing it off the app grid alone is what
                // would clip the Advanced row.
                //
                // The empty case still gets a real box (172x40), for the
                // reason in the note above this Item: with a zero-sized
                // contentItem the "No tray applications" text has nothing to
                // lay out in and the card opens as a dot.
                // SIZED TO THE ICONS. The 172/40 floors below are the EMPTY
                // state's text box -- a zero-sized contentItem gives "No tray
                // applications" nothing to lay out in and the card opens as a
                // dot. They used to apply with icons present too, and that is
                // what made the open card read as misaligned: one 32px icon
                // opened a 192px-wide plate, right-aligned to the chevron but
                // with its icon placed at x=0, so the glyph sat ~77px LEFT of
                // the arrow above it with 140px of dead plate to its right.
                // Content-sized, the right edge stays pinned on the chevron
                // and the icon lands under it.
                implicitWidth: Math.max(
                    cellCount > 0 || root.serviceItems.length > 0
                        ? cols * cell + (cols - 1) * gap
                        : 172,
                    serviceGridWidth(),
                )
                // App grid, then the Advanced group below it, then the card's
                // own bottom breathing room. Read from the SAME numbers
                // `layoutCells` places with, so the box cannot disagree with
                // what is inside it.
                implicitHeight: appGridHeight()
                    + (root.serviceItems.length > 0 ? advancedHeight() + 16 : 0)

                // The app grid's own height. 40 when empty, for the reason in
                // the note on this Item: with nothing in the grid the
                // "No tray applications" text needs a real box to lay out in.
                function appGridHeight() {
                    return cellCount > 0
                        ? rows * cell + (rows - 1) * gap
                        : 40;
                }

                // The Advanced group's own grid width, from the same formula
                // `advancedCols()` places with. The card has to be at least
                // this wide or the service icons overflow a plate sized from
                // the app grid alone -- which the old 172 floor only hid by
                // accident, and which would show the moment the app grid
                // became the narrower of the two.
                function serviceGridWidth() {
                    const n = root.serviceItems.length;
                    if (n <= 0)
                        return 0;
                    const cols = Math.max(1, Math.min(8, Math.ceil(Math.sqrt(n))));
                    return cols * cell + (cols - 1) * gap;
                }

                // The Advanced group's height: the header, plus -- when open --
                // its grid of service icons. Does NOT include the 8px of
                // separation from the app grid, or the card's bottom margin;
                // `implicitHeight` above adds those.
                function advancedHeight() {
                    const header = 26;
                    if (!root.advancedExpanded || root.serviceItems.length === 0)
                        return header;
                    const n = root.serviceItems.length;
                    const gcols = Math.max(1, Math.min(8, Math.ceil(Math.sqrt(n))));
                    const grows = Math.ceil(n / gcols);
                    return header + 6 + grows * panelCellSize + (grows - 1) * 4;
                }

                Repeater {
                    // APPS ONLY. Both tray sources feed this one grid: the real
                    // StatusNotifier items and the shell's own registry entries,
                    // already concatenated into `appItems` with the service
                    // noise filtered out.
                    //
                    // The two tray shapes are different TYPES with different
                    // delegates, and a QML Repeater picks one delegate for the
                    // whole model. So the delegate is an Item that picks a
                    // Loader at runtime -- `appEntry` is set as an ordinary
                    // property and read by the loaded item, which sidesteps the
                    // injected-context problem that made `index` undefined
                    // under this file's `pragma ComponentBehavior: Bound`.
                    model: root.appItems

                    delegate: Item {
                        id: appCellItem
                        required property var modelData
                        objectName: "trayCell"
                        width: trayCardContent.cell
                        height: trayCardContent.cell
                        // Only the shell-owned registry entries carry `cls`;
                        // a StatusNotifierItem does not.
                        readonly property bool isAppEntry:
                            modelData && modelData.cls !== undefined
                        // Handed in as a property rather than read off `parent`
                        // inside the Component: a Repeater delegate's parent is
                        // the grid, not this item, so `parent.entry` would be
                        // undefined and the icon would never load.
                        property var appEntry: isAppEntry ? modelData : null
                        property SystemTrayItem sniItem:
                            isAppEntry ? null : modelData

                        Loader {
                            anchors.fill: parent
                            sourceComponent: appCellItem.isAppEntry
                                ? appDelegate : sniDelegate
                        }

                        Component {
                            id: appDelegate
                            SysTrayAppItem {
                                // No `required property entry` re-declared here:
                                // shadowing the inherited one left the real
                                // required property unset ("Required property
                                // entry was not initialized") and the icon
                                // resolved `entry.cls` to undefined. The binding
                                // below is what initializes it.
                                entry: appCellItem.appEntry
                                anchors.fill: parent
                                cellSize: trayCardContent.cell
                                iconSize: root.panelIconSize
                                showHoverPlate: true
                                onMenuClosed: root.releaseFocus()
                                onMenuOpened: (w) => root.setExtraWindowAndGrabFocus(w)
                            }
                        }
                        Component {
                            id: sniDelegate
                            SysTrayItem {
                                item: appCellItem.sniItem
                                anchors.fill: parent
                                cellSize: trayCardContent.cell
                                iconSize: root.panelIconSize
                                showHoverPlate: true
                                onMenuClosed: root.releaseFocus()
                                onMenuOpened: (w) => root.setExtraWindowAndGrabFocus(w)
                            }
                        }
                    }
                }

                // Nothing registered yet. The card still opens -- the
                // button is unconditional, so the card has to be too --
                // and says so rather than showing an empty box that could
                // be mistaken for a tray that failed to load.
                StyledText {
                    anchors.fill: parent
                    visible: !root.hasItems
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    wrapMode: Text.WordWrap
                    color: Appearance.colors.colSubtext
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    text: Translation.tr("No tray applications")
                }

                // ── "Advanced": the background services ────────────────
                //
                // avahi, NetworkManager, the desktop portals, polkit, the
                // distro package managers -- all real running services, all
                // still one click away, none of them competing with the
                // everyday icons for attention. See services/TrayNoise.qml
                // for what lands here and, more importantly, for what does
                // NOT (the default is "app").
                //
                // COLLAPSED by default, and the header says how many are in
                // it, so the group is never a mystery: a closed row reading
                // "Advanced  8" tells you the icons exist and are one click
                // away, which a hidden-and-unmentioned list would not.
                Item {
                    id: trayAdvanced
                    // Anchored below the app grid, not laid out beside it. See
                    // the note on `trayCardContent`: a ColumnLayout here would
                    // take the hand-placed app cells as its own children.
                    anchors.top: parent.top
                    anchors.topMargin: trayCardContent.appGridHeight() + 8
                    width: parent.width
                    height: advancedColumn.implicitHeight
                    visible: root.serviceItems.length > 0

                    readonly property bool open: advancedExpanded

                    ColumnLayout {
                        id: advancedColumn
                        anchors.fill: parent
                        spacing: 6

                        RippleButton {
                            Layout.fillWidth: true
                            implicitHeight: 26
                            onClicked: advancedExpanded = !advancedExpanded

                            contentItem: RowLayout {
                                spacing: 6
                                anchors.fill: parent

                                MaterialSymbol {
                                    Layout.alignment: Qt.AlignVCenter
                                    text: "expand_more"
                                    iconSize: 16
                                    // Points down when closed, up when open --
                                    // the one piece of state that makes the row
                                    // read as expandable at a glance.
                                    rotation: trayAdvanced.open ? 180 : 0
                                    Behavior on rotation {
                                        NumberAnimation { duration: 120 }
                                    }
                                    color: Appearance.colors.colOnLayer2
                                }

                                StyledText {
                                    Layout.alignment: Qt.AlignVCenter
                                    text: Translation.tr("Advanced")
                                    color: Appearance.colors.colOnLayer0
                                    font.pixelSize: Appearance.font.pixelSize.small
                                }

                                // The count, so a collapsed group still says
                                // what is in it.
                                StyledText {
                                    Layout.alignment: Qt.AlignVCenter
                                    text: root.serviceItems.length
                                    color: Appearance.colors.colOnLayer2
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                }

                                Item { Layout.fillWidth: true }
                            }
                        }

                        // The icons themselves, in the same hand-placed grid
                        // shape as the apps above but sized off ITS OWN
                        // numbers -- it cannot share `layoutCells`, because
                        // that function places every cell named "trayCell" in
                        // ITS parent and would move this group's icons into the
                        // app grid's coordinates.
                        Item {
                            id: advancedGrid
                            Layout.fillWidth: true
                            Layout.preferredHeight: advancedGridHeight()
                            visible: trayAdvanced.open

                            readonly property int cell: root.panelCellSize
                            readonly property int gap: 4

                            function advancedCols() {
                                const n = root.serviceItems.length;
                                return n > 0
                                    ? Math.max(1, Math.min(8, Math.ceil(Math.sqrt(n))))
                                    : 1;
                            }

                            function advancedGridHeight() {
                                const n = root.serviceItems.length;
                                if (n === 0)
                                    return 0;
                                const cols = advancedCols();
                                return Math.ceil(n / cols) * cell + (Math.ceil(n / cols) - 1) * gap;
                            }

                            Repeater {
                                model: root.serviceItems

                                delegate: Item {
                                    id: advancedCellItem
                                    required property var modelData
                                    objectName: "advancedTrayCell"
                                    width: advancedGrid.cell
                                    height: advancedGrid.cell

                                    readonly property bool isAppEntry:
                                        modelData && modelData.cls !== undefined
                                    property var appEntry:
                                        isAppEntry ? modelData : null
                                    property SystemTrayItem sniItem:
                                        isAppEntry ? null : modelData

                                    // Placed by hand from the index, in this
                                    // grid's own coordinates. See the note in
                                    // `layoutCells` for why this is a function
                                    // and not a binding on `index`.
                                    Component.onCompleted: Qt.callLater(advancedGrid.placeCells)
                                    Component.onDestruction: {}

                                    Loader {
                                        anchors.fill: parent
                                        sourceComponent: advancedCellItem.isAppEntry
                                            ? advAppDelegate : advSniDelegate
                                    }

                                    Component {
                                        id: advAppDelegate
                                        SysTrayAppItem {
                                            entry: advancedCellItem.appEntry
                                            anchors.fill: parent
                                            cellSize: advancedGrid.cell
                                            iconSize: root.panelIconSize
                                            showHoverPlate: true
                                            onMenuClosed: root.releaseFocus()
                                            onMenuOpened: (w) => root.setExtraWindowAndGrabFocus(w)
                                        }
                                    }
                                    Component {
                                        id: advSniDelegate
                                        SysTrayItem {
                                            item: advancedCellItem.sniItem
                                            anchors.fill: parent
                                            cellSize: advancedGrid.cell
                                            iconSize: root.panelIconSize
                                            showHoverPlate: true
                                            onMenuClosed: root.releaseFocus()
                                            onMenuOpened: (w) => root.setExtraWindowAndGrabFocus(w)
                                        }
                                    }
                                }
                            }

                            function placeCells() {
                                const cells = children.filter(
                                    c => c && c.objectName === "advancedTrayCell");
                                const cols = advancedCols();
                                const n = cells.length;
                                // Centred in the row, exactly as the app grid
                                // above is centred in its box: `width` here is
                                // the card's own content width, which is sized
                                // from whichever grid is the wider of the two,
                                // so this group can be narrower than the plate
                                // it sits in.
                                const gridW = n > 0
                                    ? cols * cell + (cols - 1) * gap : 0;
                                const offX = Math.round((width - gridW) / 2);
                                for (let i = 0; i < n; i++) {
                                    cells[i].x = offX + (i % cols) * (cell + gap);
                                    cells[i].y = Math.floor(i / cols) * (cell + gap);
                                }
                            }

                            onChildrenChanged: placeCells()
                        }   // advancedGrid
                    }       // advancedColumn
                }           // trayAdvanced
        }                   // trayCardContent
    }
}







