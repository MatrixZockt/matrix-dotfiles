import qs.modules.common
import qs.modules.common.functions
import qs.services
import QtQuick
import Quickshell.Services.Notifications

RippleButton {
    id: button
    property string buttonText
    property string urgency

    implicitHeight: 34
    leftPadding: 15
    rightPadding: 15
    buttonRadius: Appearance.rounding.small
    // A wash, not a layer token.
    //
    // This button sits on the notification CARD, which is a solid fill. Every
    // `colLayerN*` token is `solveOverlayColor`d against `1 -
    // contentTransparency`, so all three of the states below carry the same
    // low alpha -- laid over an opaque card they land a couple of values
    // apart, which is how a row of app-supplied action buttons ends up
    // looking like a row of ghosts that do not respond to the pointer. A
    // `colPrimary` wash over an opaque surface always lightens, by an amount
    // we choose, whatever the theme and the transparency slider have done to
    // the layers underneath.
    //
    // 0.07 rests as a surface, 0.16 reads as hover, 0.24 is the press. The
    // steps are wide on purpose: a hover you cannot see is not a hover.
    colBackground: (urgency == NotificationUrgency.Critical) ? Appearance.colors.colSecondaryContainer : ColorUtils.applyAlpha(Appearance.colors.colPrimary, 0.07)
    colBackgroundHover: (urgency == NotificationUrgency.Critical) ? Appearance.colors.colSecondaryContainerHover : ColorUtils.applyAlpha(Appearance.colors.colPrimary, 0.16)
    colRipple: (urgency == NotificationUrgency.Critical) ? Appearance.colors.colSecondaryContainerActive : ColorUtils.applyAlpha(Appearance.colors.colPrimary, 0.24)

    contentItem: StyledText {
        horizontalAlignment: Text.AlignHCenter
        text: buttonText
        color: (urgency == NotificationUrgency.Critical) ? Appearance.m3colors.m3onSurfaceVariant : Appearance.m3colors.m3onSurface
    }
}
