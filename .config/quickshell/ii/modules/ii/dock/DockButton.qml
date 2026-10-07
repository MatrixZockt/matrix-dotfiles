import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts

RippleButton {
    Layout.fillHeight: true
    // Square. The old formula subtracted `topInset` and `bottomInset`, which are
    // not declared anywhere in this shell (they belong to the waffle variant), so
    // the expression evaluated against `undefined` and the width had nothing to do
    // with the height -- that is why the icons did not fit the pill.
    implicitWidth: implicitHeight
    buttonRadius: Appearance.rounding.normal

    background.implicitHeight: implicitHeight
}
