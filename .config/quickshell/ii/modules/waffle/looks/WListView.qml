import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Controls

StyledListView {
    id: root

    boundsBehavior: Flickable.StopAtBounds

    ScrollBar.vertical: WScrollBar {}

    displaced: Transition {
        animations: [Looks.transition.enter.createObject(this, {
                property: "y"
            })]
    }

}
