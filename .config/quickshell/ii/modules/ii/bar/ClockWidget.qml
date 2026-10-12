import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

Item {
    id: root
    property bool borderless: Config.options.bar.borderless
    property bool showDate: Config.options.bar.verbose

    // The time is deliberately much bigger than the rest of the bar; the date sits
    // to its right, smaller. Date format comes from `time.dateFormat` in the shell
    // config ("dd MMMM" reads as e.g. "12 September").
    property int timeSize: 26
    property int dateSize: Appearance.font.pixelSize.small

    // The calendar popup is CLICK driven (see ClockWidgetPopup / StyledPopup
    // clickOnly): hovering the clock no longer pops it up, clicking does.
    property bool popupOpen: false

    // How far the hover highlight reaches past the clock's text, on each side.
    // Named, because the highlight is anchored to the TEXT (see hoverBackground)
    // and this is the whole of its margin.
    readonly property real hoverPadding: 5

    // ── Which hover feedback the clock shows ────────────────────────────────
    //
    // One word, and every style below is drawn from the theme's own tokens, so
    // all of them follow the wallpaper like the rest of the bar:
    //
    //   tint     the box this bar has always had: a rounded fill one step
    //            brighter than the surface it sits on
    //   faint    the same box, further transparentised -- feedback that is
    //            there when you look for it and not before
    //   primary  the same box in the ACCENT colour at low alpha instead of a
    //            neutral one: the same shape, a colour that means "this"
    //   pill     the same fill as `tint`, hugged into a capsule
    //   ring     no fill at all, an accent hairline capsule around the text
    //   underline  no box: a short accent rule under the time
    //   text     no box and no rule: the time takes the accent and the date
    //            brightens -- the clock reacting as text rather than as a
    //            button, which is what this widget is (see the no-scaling note)
    //
    // The default is the incumbent: this property exists so the choice is one
    // word in one place, not so the bar changes shape on its own.
    property string hoverStyle: "tint"

    // The styles that stand a little further off the ink than the flat box.
    readonly property real stylePadding:
        (hoverStyle === "pill" || hoverStyle === "ring") ? 8 : hoverPadding

    // The one hover state every piece of feedback reads, so all seven styles
    // react to exactly the same thing (and a future style has one place to
    // hook into rather than its own condition).
    readonly property bool hovered: mouseArea.containsMouse

    implicitWidth: rowLayout.implicitWidth
    implicitHeight: Appearance.sizes.barHeight

    // ── No hover scaling ───────────────────────────────────────────────────
    //
    // There is deliberately NO `transform: Scale { ... containsMouse ? 1.05 }`
    // here, and it must not come back.
    //
    // It was the "hover grows the widget" house style, copied from the round
    // icon buttons -- and on a 26px clock next to a date it read as the clock
    // jumping and swelling under the cursor: the text shifted, changed size, and
    // poked out of the capsule the bar paints behind it (that capsule is sized
    // from this item's `width`, and a transform does not change `width`, so the
    // box stayed put while the text grew out of it). A clock is a value you read,
    // not a button that reacts: the hover highlight below is the whole feedback.
    //
    // Anything hover-driven added here must leave `width`, `height`, `x`, `y` and
    // the ink's own box alone. The highlight is a background, painted behind the
    // text by declaration order -- it moves nothing.

    Rectangle {
        id: hoverBackground
        // Fitted to the TEXT, not to this item's own box.
        //
        // `anchors.fill: parent; anchors.margins: 3` (the old form) put the box
        // on the item's box, and the two are not the same rectangle: the texts
        // carry their own side bearings, and the row below is inset 8px while the
        // item's implicit width is taken from the row, so the box came out
        // lopsided -- measured, 5px of air on the left of the time and 9px on the
        // right of the date, which reads as a highlight that is shifted off the
        // clock it belongs to.
        //
        // The text items are the one honest reference for where the clock is, so
        // the box is measured off them directly and follows the date when
        // `bar.verbose` hides it.
        //
        // Arithmetic, not anchors: an anchor target has to be a sibling or the
        // parent, and these texts live inside the row below. A binding may read
        // across the tree, so this is both legal and live -- it re-fits when the
        // time string changes width at the minute, or when the date appears and
        // disappears with `bar.verbose`.
        readonly property real inkLeft: timeText.x
        readonly property real inkRight: root.showDate ? dateText.x + dateText.width
            : timeText.x + timeText.width
        x: rowLayout.x + inkLeft - root.stylePadding
        width: inkRight - inkLeft + root.stylePadding * 2
        y: 3
        height: parent.height - 6
        radius: (root.hoverStyle === "pill" || root.hoverStyle === "ring")
            ? Appearance.rounding.full
            : Appearance.rounding.normal
        // Every style but the two that paint no box. Returning "transparent"
        // rather than hiding the item keeps the geometry (and therefore the
        // rule and the ink) identical across styles, so what changes in a
        // comparison is the colour, never the position.
        color: {
            if (!root.hovered)
                return "transparent";
            switch (root.hoverStyle) {
            case "faint":
                return ColorUtils.transparentize(Appearance.colors.colLayer1Hover, 0.55);
            case "primary":
                return ColorUtils.transparentize(Appearance.colors.colPrimary, 0.80);
            case "ring":
            case "underline":
            case "text":
                return "transparent";
            default:
                return Appearance.colors.colLayer1Hover;
            }
        }
        // The ring's hairline, in the accent (a neutral outline on a dark bar
        // is a box with no visible edge -- the same reason colBarBackgroundBorder
        // is built from m3outline and not its variant).
        border.width: (root.hoverStyle === "ring" && root.hovered) ? 1.5 : 0
        border.color: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.15)
        Behavior on color {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
        }
    }

    // The `underline` style's feedback: a short accent rule under the ink, at
    // the same width as the box the other styles draw, so switching styles
    // moves nothing.
    Rectangle {
        id: hoverUnderline
        visible: root.hoverStyle === "underline" && root.hovered
        x: hoverBackground.x
        width: hoverBackground.width
        y: hoverBackground.y + hoverBackground.height - 4
        height: 2.5
        radius: Appearance.rounding.full
        color: Appearance.colors.colPrimary
    }

    RowLayout {
        id: rowLayout

        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: 8
        spacing: 12

        StyledText {
            id: timeText
            Layout.alignment: Qt.AlignVCenter
            font.pixelSize: root.timeSize
            // `text` style: the hover feedback is the text itself, which is
            // the only one of these that adds nothing to the bar's surface.
            color: (root.hoverStyle === "text" && root.hovered)
                ? Appearance.colors.colPrimary
                : Appearance.colors.colOnLayer1
            Behavior on color {
                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
            }
            text: DateTime.time
        }

        StyledText {
            id: dateText
            visible: root.showDate
            Layout.alignment: Qt.AlignVCenter
            font.pixelSize: root.dateSize
            // Brightens to the plain text colour under `text`, so the pair
            // reads as one item coming forward rather than two fading.
            color: (root.hoverStyle === "text" && root.hovered)
                ? Appearance.colors.colOnLayer1
                : Appearance.colors.colSubtext
            Behavior on color {
                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
            }
            text: DateTime.longDate
        }

        // Right padding, so the widget's own box has room to the right of the
        // date. The hover highlight no longer depends on it -- that is fitted to
        // the text itself, in hoverBackground above.
        Item {
            Layout.preferredWidth: 8
            Layout.fillHeight: true
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: !Config.options.bar.tooltips.clickToShow
        acceptedButtons: Qt.LeftButton

        onClicked: {
            root.popupOpen = !root.popupOpen
        }

        // Calendar lives here now: the sidebar's calendar tab was removed, so
        // clicking the clock/date opens the month calendar as a floating app.
        ClockWidgetPopup {
            id: calendarPopup
            anchorItem: mouseArea

            Connections {
                target: root
                function onPopupOpenChanged() {
                    calendarPopup.open = root.popupOpen;
                }
            }
            Connections {
                target: calendarPopup
                function onOpenChanged() {
                    // Closed from outside (backdrop click, Escape, focus grab):
                    // un-press the clock so the next click opens it again.
                    if (!calendarPopup.open && root.popupOpen)
                        root.popupOpen = false;
                }
            }
        }
    }
}
