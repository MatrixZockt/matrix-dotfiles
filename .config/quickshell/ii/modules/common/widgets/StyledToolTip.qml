import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ToolTip {
    id: root
    property bool extraVisibleCondition: true
    property bool alternativeVisibleCondition: false    // Show only when the parent SAYS it is hovered -- a parent with no hover
    // How wide the text may grow before it WRAPS.
    //
    // It had `wrapMode: Text.Wrap` and nothing else, which is a no-op: Text
    // only wraps inside an implicit width, and without a maximum the implicit
    // width is the whole unwrapped line. So every long string produced one
    // enormous tooltip that ran off the side of the screen -- for the
    // clipboard, exactly the case that matters, since the entries are
    // arbitrary pasted text (a URL, a stack trace, a paragraph).
    //
    // Wrapping is strictly better than clipping: the text is all still there,
    // it is just folded. Overridable per-callsite for the rare tooltip that
    // genuinely wants to be one line.
    property real maximumTextWidth: 420
    // state at all used to count as "no condition, so show", which is how a
    // tooltip inside a plain layout (ConfigRow, ConfigSlider, ConfigSpinBox, a
    // Flow of chips) ended up painted on the page permanently: a line of
    // unwrapped text across the full width that never went away. Containers that
    // can be hovered therefore have to expose `hovered` (see ConfigRow,
    // ConfigSlider, ConfigSpinBox, ConfigSelectionArray); anything that cannot is
    // expected to pass `alternativeVisibleCondition` instead, the way
    // ContentSubsection does.
    readonly property bool internalVisibleCondition: (extraVisibleCondition && root.parent !== null
        && root.parent.hovered === true) || alternativeVisibleCondition
    verticalPadding: 5
    horizontalPadding: 10
    background: null
    font {
        family: Appearance.font.family.main
        variableAxes: Appearance.font.variableAxes.main
        pixelSize: Appearance?.font.pixelSize.smaller ?? 14
        hintingPreference: Font.PreferNoHinting // Prevent shaky text
    }

    delay: 0
    visible: internalVisibleCondition
    
    contentItem: StyledToolTipContent {
        id: contentItem
        font: root.font
        text: root.text
        maximumTextWidth: root.maximumTextWidth
        shown: root.internalVisibleCondition
        horizontalPadding: root.horizontalPadding
        verticalPadding: root.verticalPadding
    }
}
