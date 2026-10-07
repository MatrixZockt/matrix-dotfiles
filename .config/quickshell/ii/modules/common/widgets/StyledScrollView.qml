import QtQuick
import QtQuick.Controls
import qs.modules.common

// A drop-in replacement for the raw ScrollView: the shell's kinetic scrolling
// physics (eased wheel glide, flick momentum) with the shell's own ScrollBar.
// Children land in the scrolling content; a ColumnLayout root should be given
// `contentHeight: <column>.implicitHeight` since there is no ScrollView to
// derive it automatically.
StyledFlickable {
    id: root

    default property alias contentData: root.data

    clip: true
    contentWidth: availableWidth

    ScrollBar.vertical: StyledScrollBar {}
}
