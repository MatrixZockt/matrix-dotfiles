import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

Rectangle {
    id: root

    property bool show: false
    default property alias contentData: contentColumn.data
    /// The dialog's OPEN height. 0 means "as tall as the content needs"; the
    /// sidebar dialogs pass a fixed number instead. It must not be read back
    /// from `dialogBackground.implicitHeight`: that property is driven down to
    /// 0 when the dialog closes, so a binding to it was captured collapsed and
    /// every dialog after the first opened as a zero-height sliver, contents
    /// spilling out and buttons on top of the text. `onShowChanged` used to
    /// assign implicitHeight as well, which killed the binding for good.
    property real backgroundHeight: 0
    readonly property real openHeight: backgroundHeight > 0
        ? backgroundHeight
        : contentColumn.implicitHeight + dialogBackground.radius * 2
    property real backgroundWidth: 350
    property real backgroundAnimationMovementDistance: 60
    
    signal dismiss()
    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Escape) {
            root.dismiss();
            event.accepted = true;
        }
    }

    color: root.show ? Appearance.colors.colScrim : ColorUtils.transparentize(Appearance.colors.colScrim)
    Behavior on color {
        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
    }
    visible: dialogBackground.implicitHeight > 0

    onShowChanged: {
        dialogBackgroundHeightAnimation.easing.bezierCurve = (show ? Appearance.animationCurves.emphasizedDecel : Appearance.animationCurves.emphasizedAccel)
    }

    radius: Appearance.rounding.screenRounding - Appearance.sizes.hyprlandGapsOut + 1

    MouseArea { // Clicking outside the dialog should dismiss
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        hoverEnabled: true
        onPressed: root.dismiss()
    }

    Rectangle {
        id: dialogBackground
        anchors.horizontalCenter: parent.horizontalCenter
        radius: Appearance.rounding.large
        color: Appearance.m3colors.m3surfaceContainerHigh // Use opaque version of layer3
        
        property real targetY: root.height / 2 - root.openHeight / 2
        y: root.show ? targetY : (targetY - root.backgroundAnimationMovementDistance)
        implicitWidth: root.backgroundWidth
        implicitHeight: root.show ? root.openHeight : 0
        Behavior on implicitHeight {
            NumberAnimation {
                id: dialogBackgroundHeightAnimation
                duration: Appearance.animation.elementMoveFast.duration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.animationCurves.emphasizedDecel
            }
        }
        Behavior on y {
            NumberAnimation {
                duration: dialogBackgroundHeightAnimation.duration
                easing.type: dialogBackgroundHeightAnimation.easing.type
                easing.bezierCurve: dialogBackgroundHeightAnimation.easing.bezierCurve
            }
        }

        MouseArea { // So clicking inside the dialog won't dismiss
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
        }

        ColumnLayout {
            id: contentColumn
            anchors {
                fill: parent
                margins: dialogBackground.radius
            }
            spacing: 16
            opacity: root.show ? 1 : 0
            Behavior on opacity {
                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
            }

        }
    }
}
