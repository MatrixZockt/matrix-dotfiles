// A ContentSection you can fold away.
//
// Same header as ContentSection (icon + title) and the same column of content,
// except the header is a button: click it and the content folds in or out. Used
// for pickers that are long lists of small icons rather than a handful of rows
// -- "Top bar icons" above all -- so a settings page stays readable without
// hiding the setting somewhere else entirely.
//
// Folded by default: the closed row is the summary, and the header still names
// what is inside.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.widgets

ColumnLayout {
    id: root
    property string title
    property string icon: ""
    property bool expanded: false
    default property alias contentData: sectionContent.data

    Layout.fillWidth: true
    spacing: 6

    RippleButton {
        id: header

        Layout.fillWidth: true
        // The sidebar's twin of this header is 46px so it is easy to hit; this
        // one sits in a settings page, where 42 keeps the page's rhythm while
        // still reading as a button rather than as a heading.
        implicitHeight: 42
        buttonRadius: Appearance.rounding.small
        colBackground: "transparent"
        colBackgroundHover: Appearance.colors.colLayer2Hover
        colRipple: Appearance.colors.colLayer2Active

        onClicked: root.expanded = !root.expanded

        contentItem: RowLayout {
            spacing: 6

            OptionalMaterialSymbol {
                icon: root.icon
                iconSize: Appearance.font.pixelSize.hugeass
            }
            StyledText {
                Layout.fillWidth: true
                text: root.title
                font.pixelSize: Appearance.font.pixelSize.larger
                font.weight: Font.Medium
                color: Appearance.colors.colOnSecondaryContainer
            }
            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                text: root.expanded ? "expand_less" : "expand_more"
                iconSize: Appearance.font.pixelSize.normal
                color: Appearance.colors.colOnSecondaryContainer
            }
        }
    }

    ColumnLayout {
        id: sectionContent
        Layout.fillWidth: true
        spacing: 4
        visible: root.expanded
    }
}
