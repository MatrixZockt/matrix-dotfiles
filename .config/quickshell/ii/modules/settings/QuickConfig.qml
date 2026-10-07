import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Io
// IconImage is a Quickshell type, not a QtQuick.Controls one. Without this the
// popup-app rows below it failed to load with "IconImage is not a type", which
// took out the whole Apps section of this page.
import Quickshell.Widgets
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

ContentPage {
    forceWidth: true

    // ── Per-app popup handling ─────────────────────────────────────────
    //
    // The compositor floats an app's SECOND window as a popup (a dialog, a
    // settings box, a sign-in sheet) instead of tiling it. That is the right
    // default and it stays the default; this is the per-app off switch for
    // the apps whose second window is a real window. TradingView is why it
    // exists.
    //
    // The list fills itself from what the machine has actually run -- every
    // app id the compositor reports is remembered (see common/PopupAppPolicy.qml)
    // -- so an app installed today is here the first time it opens, with
    // nothing to install-hook and no .desktop scan to keep in sync. Apps
    // with no desktop entry (launched straight from a binary) are shown by
    // their raw class, which is also exactly what the compositor matches on,
    // so the name on the row and the thing being configured are the same
    // string.
    component PopupAppRow: RippleButton {
        id: popupAppRow
        required property string appId

        Layout.fillWidth: true
        implicitHeight: contentItem.implicitHeight + 8 * 2
        font.pixelSize: Appearance.font.pixelSize.small
        // Bound, not assigned: the source of truth is the Config list, and a
        // row that held its own copy would keep showing the old state after
        // the setting changed anywhere else.
        readonly property bool popupAllowed: PopupAppPolicy.isPopupAllowed(popupAppRow.appId)

        onClicked: PopupAppPolicy.setPopupAllowed(
            popupAppRow.appId, !popupAppRow.popupAllowed)

        contentItem: RowLayout {
            spacing: 12
            IconImage {
                source: Quickshell.iconPath(
                    PopupAppPolicy.entryFor(popupAppRow.appId)?.icon ?? "",
                    Quickshell.shellPath("assets/icons/fluent/app-generic.svg"))
                sourceSize.width: 22
                sourceSize.height: 22
                Layout.fillWidth: false
            }
            StyledText {
                Layout.fillWidth: true
                text: PopupAppPolicy.nameFor(popupAppRow.appId)
                font: popupAppRow.font
                color: Appearance.colors.colOnSecondaryContainer
                elide: Text.ElideRight
                StyledToolTip {
                    text: popupAppRow.appId
                }
            }
            StyledSwitch {
                down: popupAppRow.down
                Layout.fillWidth: false
                checked: popupAppRow.popupAllowed
                // Swallow it: the row is the button, and letting the switch's
                // own click through as well toggles twice and lands back
                // where it started.
                onClicked: popupAppRow.clicked()
            }
        }
    }

    Process {
        id: randomWallProc
        property string status: ""
        property string scriptPath: `${Directories.scriptPath}/colors/random/random_konachan_wall.sh`
        command: ["bash", "-c", FileUtils.trimFileProtocol(randomWallProc.scriptPath)]
        stdout: SplitParser {
            onRead: data => {
                randomWallProc.status = data.trim();
            }
        }
    }

    component SmallLightDarkPreferenceButton: RippleButton {
        id: smallLightDarkPreferenceButton
        required property bool dark
        property color colText: toggled ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer2
        padding: 5
        Layout.fillWidth: true
        toggled: Appearance.m3colors.darkmode === dark
        colBackground: Appearance.colors.colLayer2
        onClicked: {
            Quickshell.execDetached(["bash", "-c", `${Directories.wallpaperSwitchScriptPath} --mode ${dark ? "dark" : "light"} --noswitch`]);
        }
        contentItem: Item {
            anchors.centerIn: parent
            ColumnLayout {
                anchors.centerIn: parent
                spacing: 0
                MaterialSymbol {
                    Layout.alignment: Qt.AlignHCenter
                    iconSize: 30
                    text: dark ? "dark_mode" : "light_mode"
                    color: smallLightDarkPreferenceButton.colText
                }
                StyledText {
                    Layout.alignment: Qt.AlignHCenter
                    text: dark ? Translation.tr("Dark") : Translation.tr("Light")
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: smallLightDarkPreferenceButton.colText
                }
            }
        }
    }


    ContentSection {
        icon: "desktop_windows"
        title: Translation.tr("Bar & screen")

        ConfigRow {
            ContentSubsection {
                title: Translation.tr("Bar position")
                ConfigSelectionArray {
                    currentValue: (Config.options.bar.bottom ? 1 : 0) | (Config.options.bar.vertical ? 2 : 0)
                    onSelected: newValue => {
                        Config.options.bar.bottom = (newValue & 1) !== 0;
                        Config.options.bar.vertical = (newValue & 2) !== 0;
                    }
                    options: [
                        {
                            displayName: Translation.tr("Top"),
                            icon: "arrow_upward",
                            value: 0 // bottom: false, vertical: false
                        },
                        {
                            displayName: Translation.tr("Left"),
                            icon: "arrow_back",
                            value: 2 // bottom: false, vertical: true
                        },
                        {
                            displayName: Translation.tr("Bottom"),
                            icon: "arrow_downward",
                            value: 1 // bottom: true, vertical: false
                        },
                        {
                            displayName: Translation.tr("Right"),
                            icon: "arrow_forward",
                            value: 3 // bottom: true, vertical: true
                        }
                    ]
                }
            }
            ContentSubsection {
                title: Translation.tr("Bar style")

                ConfigSelectionArray {
                    currentValue: Config.options.bar.cornerStyle
                    onSelected: newValue => {
                        Config.options.bar.cornerStyle = newValue; // Update local copy
                    }
                    options: [
                        {
                            displayName: Translation.tr("Hug"),
                            icon: "line_curve",
                            value: 0
                        },
                        {
                            displayName: Translation.tr("Float"),
                            icon: "page_header",
                            value: 1
                        },
                        {
                            displayName: Translation.tr("Rect"),
                            icon: "toolbar",
                            value: 2
                        }
                    ]
                }
            }
        }

        ConfigRow {
            ContentSubsection {
                title: Translation.tr("Screen round corner")

                ConfigSelectionArray {
                    currentValue: Config.options.appearance.fakeScreenRounding
                    onSelected: newValue => {
                        Config.options.appearance.fakeScreenRounding = newValue;
                    }
                    options: [
                        {
                            displayName: Translation.tr("No"),
                            icon: "close",
                            value: 0
                        },
                        {
                            displayName: Translation.tr("Yes"),
                            icon: "check",
                            value: 1
                        },
                        {
                            displayName: Translation.tr("When not fullscreen"),
                            icon: "fullscreen_exit",
                            value: 2
                        }
                    ]
                }
            }
            
        }
    }

    NoticeBox {
        Layout.fillWidth: true
        text: Translation.tr('Not all options are available in this app. You should also check the config file by hitting the "Config file" button on the topleft corner or opening %1 manually.').arg(Directories.shellConfigPath)

        Item {
            Layout.fillWidth: true
        }
        RippleButtonWithIcon {
            id: copyPathButton
            property bool justCopied: false
            Layout.fillWidth: false
            buttonRadius: Appearance.rounding.small
            materialIcon: justCopied ? "check" : "content_copy"
            mainText: justCopied ? Translation.tr("Path copied") : Translation.tr("Copy path")
            onClicked: {
                copyPathButton.justCopied = true
                Quickshell.clipboardText = FileUtils.trimFileProtocol(`${Directories.config}/illogical-impulse/config.json`);
                revertTextTimer.restart();
            }
            colBackground: ColorUtils.transparentize(Appearance.colors.colPrimaryContainer)
            colBackgroundHover: Appearance.colors.colPrimaryContainerHover
            colRipple: Appearance.colors.colPrimaryContainerActive

            Timer {
                id: revertTextTimer
                interval: 1500
                onTriggered: {
                    copyPathButton.justCopied = false
                }
            }
        }
    }

    ContentSection {
        icon: "picture_in_picture_alt"
        title: Translation.tr("Popup windows")

        StyledText {
            Layout.fillWidth: true
            Layout.bottomMargin: 8
            wrapMode: Text.WordWrap
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colOnLayer1Inactive
            text: Translation.tr("When an app opens a second window, the compositor floats it as a popup instead of tiling it. Turn that off for an app whose extra windows are real windows of their own.")
        }

        Repeater {
            // `PopupAppPolicy.list` is an array of app id strings, newest first.
            // A plain array rather than a model: the list is rebuilt whenever
            // a new app is seen or a switch flips, and a Repeater over a JS
            // array does that with no delegate lifecycle to get wrong.
            model: PopupAppPolicy.list

            delegate: PopupAppRow {
                required property var modelData
                appId: modelData
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.topMargin: 8
            visible: PopupAppPolicy.list.length === 0
            wrapMode: Text.WordWrap
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colOnLayer1Inactive
            // Not an error state: nothing seen yet means no ordinary window
            // has opened since the shell started, which is the normal state
            // of a machine sitting at a login screen.
            text: Translation.tr("No apps yet. They appear here as you use them.")
        }
    }
}
