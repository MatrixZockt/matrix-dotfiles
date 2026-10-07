import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import Qt5Compat.GraphicalEffects
import QtQuick
import QtQuick.Controls

/**
 * A button with ripple effect similar to in Material Design.
 */
Button {
    id: root
    property bool toggled
    property string buttonText
    property bool pointingHandCursor: true
    property real buttonRadius: Appearance?.rounding?.small ?? 4
    property real buttonRadiusPressed: buttonRadius
    property real buttonEffectiveRadius: root.down ? root.buttonRadiusPressed : root.buttonRadius
    property int rippleDuration: 1200
    property bool rippleEnabled: true
    property var downAction // When left clicking (down)
    property var releaseAction // When left clicking (release)
    property var altAction // When right clicking
    property var middleClickAction // When middle clicking

    // Optional press-and-move dragging. A button's mouse area already holds the
    // pointer grab while the button is held, so a separate DragHandler has to fight
    // it for that grab and usually loses (the dock's reordering never fired that
    // way). These three hooks let the owner borrow the existing grab instead:
    //   dragStartAction: ()               -- the pointer moved past the threshold
    //   dragMoveAction(mouse)             -- where it is, in this button's own
    //                                        coordinates, while dragging
    //   dragEndAction: ()                 -- released, or the press was cancelled
    // The click is suppressed once a drag has started, so dragging an icon never
    // also activates the app.
    property var dragStartAction
    property var dragMoveAction
    property var dragEndAction
    property real dragThreshold: 6
    property bool dragged: false
    property real dragStartX: 0
    property real dragStartY: 0

    property color colBackground: ColorUtils.transparentize(Appearance?.colors.colLayer1Hover, 1) || "transparent"
    property color colBackgroundHover: Appearance?.colors.colLayer1Hover ?? "#E5DFED"
    property color colBackgroundToggled: Appearance?.colors.colPrimary ?? "#65558F"
    property color colBackgroundToggledHover: Appearance?.colors.colPrimaryHover ?? "#77699C"
    property color colRipple: Appearance?.colors.colLayer1Active ?? "#D6CEE2"
    property color colRippleToggled: Appearance?.colors.colPrimaryActive ?? "#D6CEE2"

    // Opt-in hover swell. KEPT, but nothing asks for it any more.
    //
    // It was 0.10-0.14 on the bar's icon buttons, and it fought the one thing
    // the bar cannot afford: a settled layout. A transform on the button grew
    // it over its neighbours on the way in and shrank it on the way out, and
    // because the surrounding row never moved, the growth read as the icons
    // themselves inflating. The bar's hover cue is `underlineOnHover` below.
    property real hoverGrow: 0
    transform: hoverGrow > 0 ? hoverGrowScale : null
    Scale {
        id: hoverGrowScale
        xScale: root.down ? 1 - root.hoverGrow * 0.5 : (root.hovered ? 1 + root.hoverGrow : 1)
        yScale: root.down ? 1 - root.hoverGrow * 0.5 : (root.hovered ? 1 + root.hoverGrow : 1)
        Behavior on xScale {
            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
        }
        Behavior on yScale {
            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
        }
    }

    // ── The underline (RETIRE) ─────────────────────────────────────────
    // The hover cue is a background fill again. The rule under the icon was
    // the wrong shape for this bar: it read as a second class of emphasis, it
    // fought the icons for attention, and no amount of timing made it feel
    // like part of the surface. Kept as dead code so nothing that still sets
    // `underlineOnHover: true` fails to load -- but the Rectangle below no
    // longer paints, so the property is a no-op everywhere.
    property bool underlineOnHover: false

    opacity: root.enabled ? 1 : 0.4
    property color buttonColor: ColorUtils.transparentize(root.toggled ? 
        (root.hovered ? colBackgroundToggledHover : 
            colBackgroundToggled) :
        (root.hovered ? colBackgroundHover : 
            colBackground), root.enabled ? 0 : 1)
    property color rippleColor: root.toggled ? colRippleToggled : colRipple

    function startRipple(x, y) {
        const stateY = buttonBackground.y;
        rippleAnim.x = x;
        rippleAnim.y = y - stateY;

        const dist = (ox,oy) => ox*ox + oy*oy
        const stateEndY = stateY + buttonBackground.height
        rippleAnim.radius = Math.sqrt(Math.max(dist(0, stateY), dist(0, stateEndY), dist(width, stateY), dist(width, stateEndY)))

        rippleFadeAnim.complete();
        rippleAnim.restart();
    }

    component RippleAnim: NumberAnimation {
        duration: rippleDuration
        easing.type: Appearance?.animation.elementMoveEnter.type
        easing.bezierCurve: Appearance?.animationCurves.standardDecel
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: root.pointingHandCursor ? Qt.PointingHandCursor : Qt.ArrowCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onPressed: (event) => { 
            if(event.button === Qt.RightButton) {
                if (root.altAction) root.altAction(event);
                return;
            }
            if(event.button === Qt.MiddleButton) {
                if (root.middleClickAction) root.middleClickAction();
                return;
            }
            root.down = true
            root.dragged = false
            root.dragStartX = event.x
            root.dragStartY = event.y
            if (root.downAction) root.downAction();
            if (!root.rippleEnabled) return;
            const {x,y} = event
            startRipple(x, y)
        }
        onPositionChanged: (event) => {
            if (!root.down || !root.dragMoveAction)
                return;
            if (!root.dragged) {
                const dx = Math.abs(event.x - root.dragStartX);
                const dy = Math.abs(event.y - root.dragStartY);
                if (Math.max(dx, dy) < root.dragThreshold)
                    return;
                root.dragged = true;
                if (root.dragStartAction) root.dragStartAction();
            }
            root.dragMoveAction(event);
        }
        onReleased: (event) => {
            root.down = false
            if (event.button != Qt.LeftButton) return;
            if (root.dragged) { // A drag is not a click.
                root.dragged = false
                if (root.dragEndAction) root.dragEndAction();
                if (root.rippleEnabled) rippleFadeAnim.restart();
                return;
            }
            if (root.releaseAction) root.releaseAction();
            root.click() // Because the MouseArea already consumed the event
            if (!root.rippleEnabled) return;
            rippleFadeAnim.restart();
        }
        onCanceled: (event) => {
            root.down = false
            if (root.dragged) {
                root.dragged = false
                if (root.dragEndAction) root.dragEndAction();
            }
            if (!root.rippleEnabled) return;
            rippleFadeAnim.restart();
        }
    }

    RippleAnim {
        id: rippleFadeAnim
        duration: rippleDuration * 2
        target: ripple
        property: "opacity"
        to: 0
    }

    SequentialAnimation {
        id: rippleAnim

        property real x
        property real y
        property real radius

        PropertyAction {
            target: ripple
            property: "x"
            value: rippleAnim.x
        }
        PropertyAction {
            target: ripple
            property: "y"
            value: rippleAnim.y
        }
        PropertyAction {
            target: ripple
            property: "opacity"
            value: 1
        }
        ParallelAnimation {
            RippleAnim {
                target: ripple
                properties: "implicitWidth,implicitHeight"
                from: 0
                to: rippleAnim.radius * 2
            }
        }
    }

    background: Rectangle {
        id: buttonBackground
        radius: root.buttonEffectiveRadius
        implicitHeight: 30

        // ── The hover rule (removed) ─────────────────────────────────
        // The rule under the icon is gone. It was the wrong cue for this
        // desktop: a line is an emphasis OUTSIDE the surface, and what was
        // wanted was a response INSIDE it -- the button's own fill rising
        // slightly toward the background. That is `buttonColor` above, driven
        // by `hovered`, and it fades on the shell's own fast colour
        // animation. Any underline call site still compiles; nothing paints.

        color: root.buttonColor
        // The fill IS the hover response now: `buttonColor` folds
        // `colBackgroundHover` in when `hovered` is set, so a subtle colour
        // rise toward the background is what the pointer gets. The animation
        // object is created per-instance, which is what lets the same
        // component carry a different speed in a popup than on the bar.
        Behavior on color {
            animation: Appearance?.animation.elementMoveFast.colorAnimation.createObject(this)
        }

        // The mask is only alive while a ripple is actually on screen. It was
        // permanently enabled, which meant every button on the bar (and every
        // button in every popup) held its own render target all day -- a
        // standing invitation for the bar to flicker and for the GPU to
        // thrash on hover. The ripple is what needs the mask, so the mask
        // lives exactly as long as the ripple.
        layer.enabled: ripple.visible && ripple.opacity > 0.01
        layer.effect: OpacityMask {
            maskSource: Rectangle {
                width: buttonBackground.width
                height: buttonBackground.height
                radius: root.buttonEffectiveRadius
            }
        }

        Item {
            id: ripple
            width: ripple.implicitWidth
            height: ripple.implicitHeight
            opacity: 0
            visible: width > 0 && height > 0 && opacity > 0.01

            property real implicitWidth: 0
            property real implicitHeight: 0

            Behavior on opacity {
                animation: Appearance?.animation.elementMoveFast.colorAnimation.createObject(this)
            }

            RadialGradient {
                anchors.fill: parent
                gradient: Gradient {
                    GradientStop { position: 0.0; color: root.rippleColor }
                    GradientStop { position: 0.3; color: root.rippleColor }
                    GradientStop { position: 0.5; color: Qt.rgba(root.rippleColor.r, root.rippleColor.g, root.rippleColor.b, 0) }
                }
            }

            transform: Translate {
                x: -ripple.width / 2
                y: -ripple.height / 2
            }
        }
    }

    contentItem: StyledText {
        text: root.buttonText
    }
}
