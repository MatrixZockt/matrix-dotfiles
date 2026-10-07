import QtQuick
import QtQuick.Layouts

RowLayout {
    property bool uniform: false
    spacing: 4
    uniformCellSizes: uniform

    // Hover state for the tooltips declared inside this row. A RowLayout has no
    // hover of its own, and StyledToolTip looks for one (`parent.hovered`);
    // without this a tooltip here would be visible all the time instead of on
    // hover. HoverHandler observes without ever taking a click.
    property bool hovered: hoverHandler.hovered

    HoverHandler {
        id: hoverHandler
    }
}
