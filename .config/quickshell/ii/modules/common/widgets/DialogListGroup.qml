import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts

/**
 * The card a run of dialog rows sits in.
 *
 * The Wi-Fi and Bluetooth dialogs used to be one flat full-bleed list, where a
 * hairline was the only thing separating the network you are on from the nine
 * you are not. That made the two groups indistinguishable: the eye had to read
 * every row to work out which one mattered. The card gives each group a body,
 * so "the one above the second label" is a position rather than something you
 * have to deduce.
 *
 * `clip` is the load-bearing part. Rows inside carry a rounded hover plate, and
 * without clipping the first and last plates square off the card's own corners
 * and the whole thing reads as a mistake.
 */
Rectangle {
    id: root

    default property alias contentData: contentColumn.data

    property string title: ""
    property alias titleVisible: header.visible
    // The label lines up with the rows' TEXT, not with the card's edge: the
    // glyph column is the only thing inside the padding, and a header flush to
    // the card against indented rows reads as two different alignments.
    property real headerInset: 44
    property real contentSpacing: 0
    // Set when the group hosts a scrolling list rather than a fixed run of
    // rows: the card then takes the dialog's leftover height and the inner
    // column stretches with it, instead of the card being as tall as the whole
    // list and the dialog growing to match.
    property bool stretches: false

    Layout.fillWidth: true
    // A stretching group takes the dialog's leftover height, so its implicit
    // height (header + padding, with a list contributing nothing) is only ever
    // the floor. Without the fill the scrollable group would collapse to that
    // floor and the list would have no height to scroll in.
    Layout.fillHeight: root.stretches
    implicitHeight: contentColumn.implicitHeight + (root.title.length > 0 ? header.implicitHeight + 8 : 0) + 12
    radius: Appearance.rounding.large
    color: Appearance.m3colors.m3surfaceContainerLow
    border.width: 1
    border.color: Appearance.m3colors.m3outlineVariant
    clip: true

    DialogListHeader {
        id: header
        visible: root.title.length > 0
        leftInset: root.headerInset
        y: 8
        text: root.title
    }

    ColumnLayout {
        id: contentColumn
        anchors {
            left: parent.left
            right: parent.right
            // The top inset only exists to clear the header; without a title
            // the rows start at the card's own padding and nothing is wasted.
            top: parent.top
            bottom: parent.bottom
            leftMargin: 6
            rightMargin: 6
            topMargin: root.title.length > 0 ? header.y + header.height + 4 : 6
            bottomMargin: 6
        }
        spacing: root.contentSpacing
    }
}
