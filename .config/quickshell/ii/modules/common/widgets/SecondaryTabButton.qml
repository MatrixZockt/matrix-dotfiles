import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import Qt5Compat.GraphicalEffects
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

TabButton {
    id: root
    property string buttonText
    property string buttonIcon
    property int rippleDuration: 1200
    property int tabContentWidth: buttonBackground.width - buttonBackground.radius*2

    property color colBackground: ColorUtils.transparentize(Appearance.colors.colSurfaceContainer)
    // Hover fill.
    //
    // `transparentize(color, percentage)` returns `alpha * (1 - percentage)`, so
    // the SECOND argument is how much to FADE, not how much to KEEP.
    //
    // It was being passed `root.checked ? 1 : 0.95`, which resolved to a
    // 0%-alpha (fully invisible) fill on the ACTIVE tab and a 5% wash on the
    // inactive ones -- so hovering a tab produced almost no feedback, and none
    // at all on the tab you were already on. The value reads as opacity, which
    // is what misled it.
    //
    // 0.88 keeps 12% of the on-surface colour: a visible but quiet state layer
    // in both states, which is the point of a hover.
    property color colBackgroundHover: ColorUtils.transparentize(Appearance.colors.colOnSurface, 0.88)
    property color colRipple: ColorUtils.transparentize(Appearance.colors.colOnSurface, 0.95)

    PointingHandInteraction {}

    component RippleAnim: NumberAnimation {
        duration: rippleDuration
        easing.type: Appearance.animation.elementMoveEnter.type
        easing.bezierCurve: Appearance.animationCurves.standardDecel
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onPressed: (event) => {
            root.click() // Because the MouseArea already consumed the event
            const {x,y} = event
            const stateY = buttonBackground.y;
            rippleAnim.x = x;
            rippleAnim.y = y - stateY;

            const dist = (ox,oy) => ox*ox + oy*oy
            const stateEndY = stateY + buttonBackground.height
            rippleAnim.radius = Math.sqrt(Math.max(dist(0, stateY), dist(0, stateEndY), dist(width, stateY), dist(width, stateEndY)))

            rippleFadeAnim.complete();
            rippleAnim.restart();
        }
        onReleased: (event) => {
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
        anchors {
            fill: parent
            margins: 3
        }
        radius: Appearance?.rounding.normal
        implicitHeight: 42
        color: (root.hovered ? root.colBackgroundHover : root.colBackground)
        layer.enabled: true
        layer.effect: OpacityMask {
            maskSource: Rectangle {
                width: buttonBackground.width
                height: buttonBackground.height
                radius: buttonBackground.radius
            }
        }
        
        Behavior on color {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
        }

        Item {
            id: ripple
            width: ripple.implicitWidth
            height: ripple.implicitHeight
            opacity: 0

            property real implicitWidth: 0
            property real implicitHeight: 0
            visible: width > 0 && height > 0

            Behavior on opacity {
                animation: Appearance?.animation.elementMoveFast.colorAnimation.createObject(this)
            }

            RadialGradient {
                anchors.fill: parent
                gradient: Gradient {
                    GradientStop { position: 0.0; color: root.colRipple }
                    GradientStop { position: 0.3; color: root.colRipple }
                    GradientStop { position: 0.5 ; color: Qt.rgba(root.colRipple.r, root.colRipple.g, root.colRipple.b, 0) }
                }
            }

            transform: Translate {
                x: -ripple.width / 2
                y: -ripple.height / 2
            }
        }
    }

    contentItem: Item {
        anchors.centerIn: buttonBackground
        RowLayout {
            anchors.centerIn: parent
            spacing: 0
            
            Loader {
                id: iconLoader
                active: buttonIcon?.length > 0
                sourceComponent: buttonIcon?.length > 0 ? materialSymbolComponent : null
                Layout.rightMargin: 5
            }

            Component {
                id: materialSymbolComponent
                MaterialSymbol {
                    verticalAlignment: Text.AlignVCenter
                    text: buttonIcon
                    iconSize: Appearance.font.pixelSize.huge
                    fill: root.checked ? 1 : 0
                    color: root.checked ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer1
                    Behavior on color {
                        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                    }
                }
            }
            StyledText {
                id: buttonTextWidget
                verticalAlignment: Text.AlignVCenter
                font.pixelSize: Appearance.font.pixelSize.small
                color: root.checked ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer1
                text: buttonText
                Behavior on color {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }
            }
        }
    }
}