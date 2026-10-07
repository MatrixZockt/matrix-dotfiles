import qs.modules.common
import qs.modules.common.widgets
import QtQuick

RippleButton {
    id: button

    required default property Item content
    property bool extraActiveCondition: false
    // Minimum hit area. Individual buttons can raise this to be easier to click.
    property real buttonSize: 26

    // Every quick toggle in the bar used to swell 12% on hover. It no longer
    // does. A transform grew the button over its neighbours on the way in and
    // shrank it on the way out while the row stayed put, so the growth read
    // as the icons themselves inflating -- and at 26px, 12% is three whole
    // pixels of a glyph that has to stay legible.
    //
    // The hover cue is the button's own fill, slightly rising toward the
    // background and fading in on the shell's fast colour animation. The
    // underline experiment is over; the default hover vocabulary was right.
    hoverGrow: 0
    implicitHeight: Math.max(content.implicitHeight, buttonSize, content.implicitHeight)
    implicitWidth: implicitHeight
    contentItem: content

}
