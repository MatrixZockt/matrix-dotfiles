import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts
import qs.modules.common.functions
import qs.modules.ii.bar as Bar

MouseArea {
    id: root
    property bool borderless: Config.options.bar.borderless
    readonly property var chargeState: Battery.chargeState
    readonly property bool isCharging: Battery.isCharging
    readonly property bool isPluggedIn: Battery.isPluggedIn
    readonly property real percentage: Battery.percentage
    readonly    property bool isLow: percentage <= Config.options.battery.low / 100
    // How far the charging bolt sits from the pill. The horizontal bar's
    // indicator exposes the same knob under the same name, and
    // VerticalBarContent sets both from one number so the two bars put the
    // bolt the same distance out.
    //
    // It has to exist: VerticalBarContent has been assigning `boltGap` here
    // since 15:18 on 2026-09-29, and this component had no such property.
    // Assigning a property that does not exist is a FATAL QML type error --
    // it took down VerticalBar -> IllogicalImpulseFamily -> the whole shell,
    // in a crash loop of one restart every six seconds from 15:16 to 15:18.
    // The desktop it left behind was a login screen with nothing behind it:
    // no shell, so no password field, so no way in. Note the direction is
    // different from the horizontal bar's -- there the bolt sits to the
    // SIDE (this is the gap the row's spacing books); here the pill is a
    // vertical bar and the bolt overhangs its TOP, so this number is that
    // overhang and only that.
    property real boltGap: 6

    implicitWidth: batteryContent.implicitWidth
    implicitHeight: batteryContent.implicitHeight
    hoverEnabled: !Config.options.bar.tooltips.clickToShow
    cursorShape: Qt.PointingHandCursor

    // Handled by this root MouseArea rather than a TapHandler child: the
    // vertical bar's section MouseArea grabs the press first, so the handler
    // never completed and the indicator was not clickable.
    onClicked: {
        if (panelLoader.item) {
            if (panelLoader.item.open)
                panelLoader.item.close();
            else
                panelLoader.item.open = true;
        } else {
            panelLoader.active = true;
        }
    }

    Column {
        id: batteryContent
        anchors.centerIn: parent
        spacing: 4

        // The pill: the vertical ClippedProgressBar capsule with a
        // proportional fill and the number knocked out of the fill, with the
        // theme's `small` radius instead of the full capsule. The percentage
        // stays visible in every state; charging is shown by the corner bolt
        // badge (sibling of the pill -- ClippedProgressBar's default property
        // IS the mask, so a child would mangle it).
        ClippedProgressBar {
            id: vBatteryProgress
            anchors.horizontalCenter: parent.horizontalCenter
            vertical: true
            valueBarWidth: 18
            valueBarHeight: 28
            radius: Appearance.rounding.small
            value: root.percentage
            highlightColor: (root.isLow && !root.isPluggedIn)
                ? Appearance.m3colors.m3error
                : Appearance.colors.colPrimary
            textMask: Item {
                width: 18
                height: 28
                StyledText {
                    anchors.centerIn: parent
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                    text: `${Math.round(root.percentage * 100)}`
                }
            }
        }

        // Charging badge on the pill's top edge, ringed with the bar
        // background so it reads cleanly over any fill.
        Rectangle {
            visible: root.isCharging
            anchors.horizontalCenter: vBatteryProgress.horizontalCenter
            anchors.top: vBatteryProgress.top
            anchors.topMargin: -root.boltGap
            width: 14
            height: 14
            radius: 7
            color: Appearance.colors.colPrimary
            border.width: 2
            border.color: Appearance.colors.colLayer0
            MaterialSymbol {
                anchors.centerIn: parent
                text: "bolt"
                fill: 1
                iconSize: 9
                color: Appearance.colors.colOnPrimary
            }
        }
    }

    // Attached panel: the bar's BatteryPanel, anchored beside the indicator
    // (the panel grows down-left from it; Slide keeps it on screen).
    Loader {
        id: panelLoader
        active: false
        sourceComponent: Bar.BatteryPanel { anchorItem: root }
        onLoaded: panelLoader.item.open = true
    }

}
