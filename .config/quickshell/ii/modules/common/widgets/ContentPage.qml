import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.widgets

StyledFlickable {
    id: root
    property real baseWidth: 600
    property bool forceWidth: false
    property real bottomContentPadding: 100
    // The horizontal breathing room the column keeps from the page edges.
    // Also the amount subtracted from the page width to get the usable width,
    // so the two can never disagree (see contentColumn.width).
    readonly property real horizontalMargin: 20

    default property alias contentData: contentColumn.data

    clip: true
    contentHeight: contentColumn.implicitHeight + root.bottomContentPadding // Add some padding at the bottom
    // The page's own implicit width is what it would LIKE, never more than it
    // can actually show. A parent that lays out against implicitWidth (the
    // settings app's Loader does) would otherwise size itself from a column
    // wider than the screen and the overflow is what got clipped.
    implicitWidth: Math.min(contentColumn.preferredWidth, Math.max(0, root.width - root.horizontalMargin * 2))

    // How wide the column would be if the window were big enough.
    readonly property real preferredWidth: forceWidth
        ? baseWidth
        : Math.max(baseWidth, contentColumn.implicitWidth)

    // How wide the column may ACTUALLY be: never more than the page can show.
    // This is the fix for the cut-off settings window. The column used to be
    // pinned to `preferredWidth` (a flat 600 for every page that sets
    // forceWidth), so on a narrow window it stayed 600 wide inside a page
    // with, say, 430px of room -- the ColumnLayout overflowed its parent and
    // `clip: true` cut the right-hand side off. Visible on the network page as
    // the "Scan for devices" switch sliced in half and the device rows running
    // past the edge.
    //
    // Taking the minimum means a wide window still gets the full 600px column,
    // and a narrow one gets a column that fits instead of one that is chopped.
    readonly property real availableWidth: Math.max(0, root.width - root.horizontalMargin * 2)

    ColumnLayout {
        id: contentColumn
        width: Math.min(root.preferredWidth, root.availableWidth)
        anchors {
            top: parent.top
            horizontalCenter: parent.horizontalCenter
        }
        // The column is anchored top and centre only, so `margins` here would
        // apply vertically AND try to inset a centred item horizontally. The
        // horizontal gap is `root.horizontalMargin` wide, subtracted in
        // `root.availableWidth` above, which is why it is not repeated here.
        spacing: 30
    }
}

