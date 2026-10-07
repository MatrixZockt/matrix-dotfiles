import qs.modules.common
import qs.modules.common.widgets
import QtQuick

/**
 * The small uppercase label that opens a group in a dialog list:
 * "CONNECTED", "AVAILABLE NETWORKS", "PAIRED DEVICES".
 *
 * One component rather than a `StyledText` with the same five properties
 * pasted into each delegate, because the whole point of the grouped layout is
 * that the groups line up -- and hand-set padding in five places drifts.
 *
 * `leftInset` exists so the label can align with the TEXT of the rows rather
 * than the edge of the group card. A header flush to the card's edge and rows
 * indented inside it read as two different alignments, which is the exact
 * sloppiness the grouping was meant to remove.
 */
StyledText {
    id: root

    property real leftInset: 0

    font.pixelSize: Appearance.font.pixelSize.smaller
    font.weight: Font.DemiBold
    font.capitalization: Font.AllUppercase
    // Wide tracking on a 10px uppercase label is what stops it reading as
    // body text at a glance; the shell's default tracking is tuned for
    // sentence case and makes small caps look cramped.
    font.letterSpacing: 1.1
    color: Appearance.colors.colSubtext
    renderType: Text.NativeRendering

    x: root.leftInset
}
