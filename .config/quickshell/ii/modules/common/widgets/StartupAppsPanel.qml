import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions as CF

/**
 * Startup apps, as one list you can edit.
 *
 * Hosted by BOTH Settings (modules/settings/StartupConfig.qml, inside a
 * ContentSection) and the Task Manager (a rail page), which is why it is a
 * widget and not a page: the two apps are different windows of the same shell
 * tree, and a second copy of this list would be a second place to disagree
 * with the first. The store and the launching live in services/Startup.qml.
 *
 * The search field is also the "add" control: type, click the app, done. There
 * is no separate picker dialog because there is nothing else the dialog would
 * ask -- the two questions a row asks (start it at login, and start it in the
 * tray) are on the row.
 *
 * TRAY. "Start in tray" means the window is moved into `special:tray` the
 * moment it maps, so at login there is no window on any desktop: the app is
 * running, its tray icon is in the bar, and the only thing that moves on
 * screen is the tray's own "an icon arrived" animation. Apps the shell already
 * keeps a tray icon for (WhatsApp, Thunderbird) are switched on here by
 * default when they are added; everything else can be switched by hand.
 */
ColumnLayout {
    id: root
    spacing: 6

    property string query: ""

    // What the search field is offering. Apps already in the list are left
    // out: adding one twice is not a thing the user can mean.
    readonly property var suggestions: {
        const text = root.query.trim().toLowerCase();
        if (text.length === 0)
            return [];
        const added = Startup.entries.map(item => item.id);
        return (DesktopEntries.applications.values ?? [])
            .filter(entry => String(entry.name ?? "").toLowerCase().includes(text))
            .filter(entry => added.indexOf(String(entry.id ?? "").replace(/\.desktop$/, "")) < 0)
            .slice(0, 6);
    }

    MaterialTextField {
        id: searchField
        Layout.fillWidth: true
        placeholderText: Translation.tr("Add an app to start at login…")
        onTextChanged: root.query = text
    }

    // Search results, one line each.
    Repeater {
        model: root.suggestions

        delegate: RippleButton {
            required property var modelData
            Layout.fillWidth: true
            implicitHeight: 40
            buttonRadius: Appearance.rounding.verysmall
            colBackground: CF.ColorUtils.transparentize(Appearance.colors.colLayer1, 0.5)
            onClicked: {
                Startup.add(modelData);
                searchField.text = "";
                root.query = "";
            }

            contentItem: RowLayout {
                anchors {
                    fill: parent
                    leftMargin: 10
                    rightMargin: 10
                }
                spacing: 10

                AppIcon {
                    implicitSize: 20
                    source: modelData.icon ? Quickshell.iconPath(modelData.icon) : ""
                }
                StyledText {
                    Layout.fillWidth: true
                    text: modelData.name ?? ""
                    color: Appearance.colors.colOnLayer1
                    elide: Text.ElideRight
                }
                MaterialSymbol {
                    text: "add"
                    iconSize: 18
                    color: Appearance.colors.colPrimary
                }
            }
        }
    }

    // The list itself.
    Repeater {
        model: Startup.entries

        delegate: Rectangle {
            id: row
            required property var modelData
            Layout.fillWidth: true
            implicitHeight: 58
            radius: Appearance.rounding.small
            color: CF.ColorUtils.transparentize(Appearance.colors.colLayer1, 0.55)
            border.width: 1
            border.color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.45)

            RowLayout {
                anchors {
                    fill: parent
                    leftMargin: 12
                    rightMargin: 10
                }
                spacing: 12

                AppIcon {
                    implicitSize: 26
                    source: row.modelData.icon ? Quickshell.iconPath(row.modelData.icon) : ""
                    opacity: row.modelData.enabled ? 1 : 0.45
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    StyledText {
                        Layout.fillWidth: true
                        text: row.modelData.name
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: Appearance.colors.colOnLayer1
                        elide: Text.ElideRight
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: row.modelData.command
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colOnLayer1Inactive
                        elide: Text.ElideMiddle
                    }
                }

                StyledText {
                    text: Translation.tr("Start in tray")
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: row.modelData.tray && row.modelData.enabled
                        ? Appearance.colors.colPrimary
                        : Appearance.colors.colOnLayer1Inactive
                    opacity: row.modelData.enabled ? 1 : 0.45
                }
                StyledSwitch {
                    enabled: row.modelData.enabled
                    opacity: row.modelData.enabled ? 1 : 0.45
                    checked: row.modelData.tray
                    onCheckedChanged: Startup.set(row.modelData.id, { tray: checked })
                }

                StyledText {
                    text: Translation.tr("Start")
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colOnLayer1Inactive
                }
                StyledSwitch {
                    checked: row.modelData.enabled
                    onCheckedChanged: Startup.set(row.modelData.id, { enabled: checked })
                }

                RippleButton {
                    implicitWidth: 34
                    implicitHeight: 34
                    buttonRadius: Appearance.rounding.full
                    onClicked: Startup.remove(row.modelData.id)

                    contentItem: MaterialSymbol {
                        anchors.centerIn: parent
                        text: "delete"
                        iconSize: 18
                        color: Appearance.colors.colOnLayer1Inactive
                    }
                    StyledToolTip {
                        text: Translation.tr("Remove from startup")
                    }
                }
            }
        }
    }

    StyledText {
        Layout.fillWidth: true
        Layout.topMargin: 2
        visible: Startup.entries.length === 0
        text: Translation.tr("Nothing starts with the desktop yet. Search above to add an app.")
        font.pixelSize: Appearance.font.pixelSize.smaller
        color: Appearance.colors.colOnLayer1Inactive
        wrapMode: Text.WordWrap
    }

    StyledText {
        Layout.fillWidth: true
        Layout.topMargin: 4
        text: Translation.tr("Apps marked “Start in tray” run with no window: their icon appears in the bar and the desktop stays clear.")
        font.pixelSize: Appearance.font.pixelSize.smaller
        color: Appearance.colors.colOnLayer1Inactive
        wrapMode: Text.WordWrap
    }
}
