import qs.modules.common
import QtQuick
import QtQuick.Layouts

Rectangle {
    // Fixed insets: this used to reach into Dock.qml for `dockRow.padding`, which
    // no longer exists (the padding lives on the dock root now).
    Layout.topMargin: 12
    Layout.bottomMargin: 12
    Layout.fillHeight: true
    implicitWidth: 1
    color: Appearance.colors.colOutlineVariant
}
