pragma ComponentBehavior: Bound
import QtQuick
import qs.modules.common

Item {
    id: root

    signal clicked(event: var)
    property alias iconText: fabWidget.iconText
    default property alias fabData: fabWidget.data
    property bool enableShadow: true

    anchors {
        verticalCenter: parent.verticalCenter
    }
    implicitWidth: fabWidget.implicitWidth
    implicitHeight: fabWidget.implicitHeight
    Loader {
        active: root.enableShadow
        anchors.fill: parent
        sourceComponent: StyledRectangularShadow {
            target: fabWidget
            radius: fabWidget.buttonRadius
            // This item's parent is the Loader, not fabWidget, so
            // StyledRectangularShadow's own `anchors.fill: target` fails with
            // "Cannot anchor to an item that isn't a parent or sibling" and
            // leaves the shadow unpositioned. The Loader already fills the
            // target, and a Loader sizes its item to itself -- same pattern as
            // Toolbar.qml.
            anchors.fill: undefined
        }
    }
    FloatingActionButton {
        id: fabWidget
        onClicked: e => root.clicked(e)
        baseSize: 48
        colBackground: Appearance.colors.colTertiaryContainer
        colBackgroundHover: Appearance.colors.colTertiaryContainerHover
        colRipple: Appearance.colors.colTertiaryContainerActive
        colOnBackground: Appearance.colors.colOnTertiaryContainer
    }
}