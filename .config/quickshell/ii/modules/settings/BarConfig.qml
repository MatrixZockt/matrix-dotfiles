import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import qs.services
import qs.modules.common
import qs.modules.common.widgets

ContentPage {
    id: root
    forceWidth: true

    // The apps that offer a tray to minimize to, filled from what is
    // actually running. Declared HERE, at page level, because the rows below
    // read it as `root.trayAppsList`; declared inside the Tray section it
    // became a property of that section instead, and every `root.…` read in
    // it was `undefined` -- three TypeErrors per reload, silent apart from
    // the log (see the note at the section for the rest).
    readonly property var trayAppsList: TrayApps.capableApps()

    // The bar's utility buttons, and what they are called, so the same list can be
    // shown and dragged around below.
    readonly property var utilButtonMeta: ({
        screenSnip: { icon: "crop_free", name: Translation.tr("Screen snip") },
        screenRecord: { icon: "videocam", name: Translation.tr("Record") },
        colorPicker: { icon: "colorize", name: Translation.tr("Color picker") },
        keyboardToggle: { icon: "keyboard", name: Translation.tr("Keyboard toggle") },
        micToggle: { icon: "mic", name: Translation.tr("Mic toggle") },
        darkModeToggle: { icon: "dark_mode", name: Translation.tr("Dark/Light button") },
        performanceProfileToggle: { icon: "speed", name: Translation.tr("Performance profile button") }
    })
    // The saved order, with anything it forgets appended -- exactly what the bar
    // itself does, so nothing can be missing from this list.
    readonly property list<string> utilButtonOrder: {
        const all = ["screenSnip", "screenRecord", "colorPicker", "keyboardToggle", "micToggle", "darkModeToggle", "performanceProfileToggle"];
        const saved = Config.options?.bar.utilButtons.order ?? [];
        const known = saved.filter(key => all.indexOf(key) !== -1);
        return known.concat(all.filter(key => known.indexOf(key) === -1));
    }

    function utilButtonShown(key) {
        switch (key) {
        case "screenSnip": return Config.options.bar.utilButtons.showScreenSnip;
        case "screenRecord": return Config.options.bar.utilButtons.showScreenRecord;
        case "colorPicker": return Config.options.bar.utilButtons.showColorPicker;
        case "keyboardToggle": return Config.options.bar.utilButtons.showKeyboardToggle;
        case "micToggle": return Config.options.bar.utilButtons.showMicToggle;
        case "darkModeToggle": return Config.options.bar.utilButtons.showDarkModeToggle;
        case "performanceProfileToggle": return Config.options.bar.utilButtons.showPerformanceProfileToggle;
        }
        return false;
    }

    function setUtilButtonShown(key, value) {
        switch (key) {
        case "screenSnip": Config.options.bar.utilButtons.showScreenSnip = value; break;
        case "screenRecord": Config.options.bar.utilButtons.showScreenRecord = value; break;
        case "colorPicker": Config.options.bar.utilButtons.showColorPicker = value; break;
        case "keyboardToggle": Config.options.bar.utilButtons.showKeyboardToggle = value; break;
        case "micToggle": Config.options.bar.utilButtons.showMicToggle = value; break;
        case "darkModeToggle": Config.options.bar.utilButtons.showDarkModeToggle = value; break;
        case "performanceProfileToggle": Config.options.bar.utilButtons.showPerformanceProfileToggle = value; break;
        }
    }

    // Drag-to-reorder: `key` lands in `targetIndex` of the list order.
    function moveUtilButton(key, targetIndex) {
        const order = root.utilButtonOrder.slice();
        const from = order.indexOf(key);
        if (from === -1)
            return;
        const to = Math.max(0, Math.min(order.length - 1, targetIndex));
        if (from === to)
            return;
        order.splice(to, 0, order.splice(from, 1)[0]);
        Config.options.bar.utilButtons.order = order;
    }

    ContentSection {
        icon: "notifications"
        title: Translation.tr("Notifications")
        ConfigSwitch {
            buttonIcon: "counter_2"
            text: Translation.tr("Unread indicator: show count")
            checked: Config.options.bar.indicators.notifications.showUnreadCount
            onCheckedChanged: {
                Config.options.bar.indicators.notifications.showUnreadCount = checked;
            }
        }
    }
    
    ContentSection {
        icon: "visibility"
        title: Translation.tr("Visibility")

        ConfigSwitch {
            buttonIcon: "horizontal_rule"
            text: Translation.tr("Show the bar")
            checked: Config.options.bar.enable
            onCheckedChanged: {
                Config.options.bar.enable = checked;
            }
        }

        ConfigSwitch {
            buttonIcon: "dock_to_bottom"
            text: Translation.tr("Show the dock")
            checked: Config.options.dock.enable
            onCheckedChanged: {
                Config.options.dock.enable = checked;
            }
        }

        ConfigSwitch {
            buttonIcon: "fullscreen_exit"
            text: Translation.tr("Keep the bar over fullscreen windows")
            checked: Config.options.bar.showInFullscreen
            onCheckedChanged: {
                Config.options.bar.showInFullscreen = checked;
            }
            StyledToolTip {
                text: Translation.tr("Off (default): a fullscreen window hides the bar completely -- click once on the very top edge to bring it back down, the same gesture the sidebars use at their edges.\nOn: the bar keeps its place over fullscreen windows, with the clock, workspaces and tray always in view.")
            }
        }

        StyledText {
            Layout.fillWidth: true
            text: Translation.tr("Switching the bar off removes it completely, edge and all. The dock can be brought back the same way, or by hovering the very bottom edge of the screen when it is on.")
            color: Appearance.colors.colOnLayer2
            font.pixelSize: Appearance.font.pixelSize.smaller
            wrapMode: Text.Wrap
        }
    }

    ContentSection {
        icon: "spoke"
        title: Translation.tr("Positioning")

        ConfigRow {
            ContentSubsection {
                title: Translation.tr("Bar position")
                Layout.fillWidth: true

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
                title: Translation.tr("Automatically hide")
                Layout.fillWidth: false

                ConfigSelectionArray {
                    currentValue: Config.options.bar.autoHide.enable
                    onSelected: newValue => {
                        Config.options.bar.autoHide.enable = newValue; // Update local copy
                    }
                    options: [
                        {
                            displayName: Translation.tr("No"),
                            icon: "close",
                            value: false
                        },
                        {
                            displayName: Translation.tr("Yes"),
                            icon: "check",
                            value: true
                        }
                    ]
                }
            }
        }

        ConfigRow {
            
            ContentSubsection {
                title: Translation.tr("Corner style")
                Layout.fillWidth: true

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

            ContentSubsection {
                title: Translation.tr("Group style")
                Layout.fillWidth: false

                ConfigSelectionArray {
                    currentValue: Config.options.bar.borderless
                    onSelected: newValue => {
                        Config.options.bar.borderless = newValue; // Update local copy
                    }
                    options: [
                        {
                            displayName: Translation.tr("Pills"),
                            icon: "location_chip",
                            value: false
                        },
                        {
                            displayName: Translation.tr("Line-separated"),
                            icon: "split_scene",
                            value: true
                        }
                    ]
                }
            }
        }
    }

    // What the bar's right section shows: the bar's own indicators (Wi-Fi,
    // Bluetooth, sound, battery), one icon per quick toggle, and how many tray
    // icons sit directly on the bar.
    //
    // FOLDED BY DEFAULT, and the same collapsed-on-click list the right
    // sidebar's edit mode shows -- both render TopBarIconPicker, so a choice
    // made here and one made in the sidebar are the same choice. It folds
    // because it is a picker of small icons, not a page of settings: folded it
    // is one line, and the Bar page stays readable.
    CollapsibleContentSection {
        icon: "add_to_queue"
        title: Translation.tr("Top bar icons")

        TopBarIconPicker {}
    }

    ContentSection {
        icon: "shelf_auto_hide"
        title: Translation.tr("Tray")

        StyledText {
            Layout.fillWidth: true
            text: Translation.tr("The tray's overflow menu holds every icon that is not on the bar, so nothing is ever unreachable -- just one click further away. How many sit on the bar is set above, under Top bar icons.")
            color: Appearance.colors.colOnLayer2
            font.pixelSize: Appearance.font.pixelSize.smaller
            wrapMode: Text.Wrap
        }

        ConfigSwitch {
            buttonIcon: "keep"
            text: Translation.tr('Make icons pinned by default')
            checked: Config.options.tray.invertPinnedItems
            onCheckedChanged: {
                Config.options.tray.invertPinnedItems = checked;
            }
        }
        
        ConfigSwitch {
            buttonIcon: "colors"
            text: Translation.tr('Tint icons')
            checked: Config.options.tray.monochromeIcons
            onCheckedChanged: {
                Config.options.tray.monochromeIcons = checked;
            }
        }

    // ── Minimize to tray, per app ──────────────────────────────────────
    //
    // Closing a window usually ends the app. For an app that lives in the
    // tray that is the wrong verb: the tray icon is already there, and the
    // window is the second window, not the app. This switch says which is
    // true for each app -- close it goes to the tray and stays running, off
    // it closes for real.
    //
    // The list is not a list of programs. It fills itself from the apps that
    // CAN be minimized -- the ones with a tray icon, and only while they
    // have a window open, because a tray icon with no window behind it (a
    // network or input daemon) has nothing to minimize. So the list grows
    // and shrinks with what is actually running rather than asking anyone
    // to keep it in step with a .desktop scan.
    //
    // Same shape as the per-app popup list on the Quick page: icon, name,
    // switch, and the row itself is the button so the switch does not
    // toggle twice.
    component TrayAppRow: RippleButton {
        id: trayAppRow
        required property var appData

        Layout.fillWidth: true
        implicitHeight: contentItem.implicitHeight + 8 * 2
        font.pixelSize: Appearance.font.pixelSize.small
        // Bound, not assigned: Config is the source of truth, and a row
        // holding its own copy would keep showing the old state after the
        // setting changed anywhere else.
        readonly property bool enabledForTray: TrayApps.closeToTrayEnabled(trayAppRow.appData.cls)

        onClicked: TrayApps.setCloseToTray(trayAppRow.appData.cls, !trayAppRow.enabledForTray)

        contentItem: RowLayout {
            spacing: 12
            IconImage {
                source: trayAppRow.appData.icon && trayAppRow.appData.icon.length > 0
                    ? trayAppRow.appData.icon
                    : Quickshell.shellPath("assets/icons/fluent/app-generic.svg")
                // `implicitSize`, not `sourceSize`: this build's IconImage has
                // no `sourceSize` property, and assigning to it fails the
                // whole page load rather than the one row ("Cannot assign to
                // non-existent property sourceSize", read out of the
                // settings instance's own log).
                implicitSize: 22
                Layout.fillWidth: false
            }
            StyledText {
                Layout.fillWidth: true
                text: trayAppRow.appData.name
                font: trayAppRow.font
                color: Appearance.colors.colOnSecondaryContainer
                elide: Text.ElideRight
                StyledToolTip {
                    text: trayAppRow.appData.cls
                }
            }
            StyledSwitch {
                down: trayAppRow.down
                Layout.fillWidth: false
                checked: trayAppRow.enabledForTray
                onClicked: trayAppRow.clicked()
            }
        }
    }

        StyledText {
            Layout.fillWidth: true
            Layout.topMargin: 8
            visible: root.trayAppsList.length > 0
            text: Translation.tr("Minimize to tray")
            color: Appearance.colors.colOnLayer2
            font.pixelSize: Appearance.font.pixelSize.small
        }

        StyledText {
            Layout.fillWidth: true
            visible: root.trayAppsList.length > 0
            text: Translation.tr("On: closing one of these windows keeps the app running and parks the window in the tray — click the tray icon to get it back. Off: closing its window closes the app.")
            color: Appearance.colors.colOnLayer2
            font.pixelSize: Appearance.font.pixelSize.smaller
            wrapMode: Text.Wrap
        }

        Repeater {
            model: root.trayAppsList
            delegate: TrayAppRow {
                required property var modelData
                appData: modelData
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: root.trayAppsList.length === 0
            text: Translation.tr("No apps offer a tray to minimize to yet. Start one that registers a tray icon — Discord, Steam, a downloader — and it will appear here.")
            color: Appearance.colors.colOnLayer2
            font.pixelSize: Appearance.font.pixelSize.smaller
            wrapMode: Text.Wrap
        }
    }

    ContentSection {
        icon: "widgets"
        title: Translation.tr("Utility buttons")

        StyledText {
            Layout.fillWidth: true
            text: Translation.tr("Drag a button to change the order it shows up in on the bar. The switch turns it on or off.")
            color: Appearance.colors.colOnLayer2
            font.pixelSize: Appearance.font.pixelSize.smaller
            wrapMode: Text.Wrap
        }

        StyledListView {
            id: utilButtonOrderList
            Layout.fillWidth: true
            implicitHeight: contentHeight
            interactive: false
            spacing: 6
            model: root.utilButtonOrder

            // Dragged rows slide into their new place instead of jumping.
            move: Transition {
                NumberAnimation {
                    property: "y"
                    duration: Appearance.animation.elementMoveFast.duration
                    easing.type: Easing.OutCubic
                }
            }
            moveDisplaced: Transition {
                NumberAnimation {
                    property: "y"
                    duration: Appearance.animation.elementMoveFast.duration
                    easing.type: Easing.OutCubic
                }
            }

            delegate: Item {
                id: utilButtonRow
                required property int index
                required property string modelData
                readonly property var meta: root.utilButtonMeta[utilButtonRow.modelData] ?? ({})
                // How far from its slot this row should be drawn while it is dragged.
                property real dragOffsetY: 0

                width: utilButtonOrderList.width
                height: 46
                z: utilButtonDragArea.pressed ? 2 : 0
                transform: Translate {
                    y: utilButtonRow.dragOffsetY
                }

                Rectangle {
                    anchors.fill: parent
                    radius: Appearance.rounding.small
                    color: Appearance.colors.colLayer2
                    border.width: 1
                    border.color: Appearance.colors.colLayer0Border
                }

                // The drag surface. It is declared before the row below so the
                // switch stays on top and keeps its own clicks; presses anywhere
                // else on the row start a reorder. `mouse.y` is already in this
                // row's coordinates, so the slot under the pointer is just the
                // row's own y plus that.
                MouseArea {
                    id: utilButtonDragArea
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton
                    cursorShape: Qt.OpenHandCursor
                    property real grabY: 0

                    onPressed: (mouse) => {
                        utilButtonDragArea.grabY = mouse.y;
                    }
                    onPositionChanged: (mouse) => {
                        if (!pressed)
                            return;
                        utilButtonRow.dragOffsetY = mouse.y - utilButtonDragArea.grabY;
                        const slot = utilButtonOrderList.indexAt(10, utilButtonRow.y + mouse.y);
                        if (slot >= 0)
                            root.moveUtilButton(utilButtonRow.modelData, slot);
                    }
                    onReleased: {
                        utilButtonRow.dragOffsetY = 0;
                    }
                    onCanceled: {
                        utilButtonRow.dragOffsetY = 0;
                    }
                }

                RowLayout {
                    anchors {
                        fill: parent
                        leftMargin: 10
                        rightMargin: 10
                    }
                    spacing: 10

                    MaterialSymbol {
                        text: utilButtonRow.meta.icon ?? "widgets"
                        iconSize: Appearance.font.pixelSize.larger
                        color: Appearance.colors.colOnLayer2
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: utilButtonRow.meta.name ?? utilButtonRow.modelData
                        color: Appearance.colors.colOnLayer2
                    }
                    StyledSwitch {
                        Layout.fillWidth: false
                        checked: root.utilButtonShown(utilButtonRow.modelData)
                        onClicked: root.setUtilButtonShown(utilButtonRow.modelData, !root.utilButtonShown(utilButtonRow.modelData))
                    }
                    MaterialSymbol {
                        text: "drag_indicator"
                        iconSize: Appearance.font.pixelSize.larger
                        color: Appearance.colors.colSubtext
                    }
                }

            }
        }

        // The theme switch itself (not a bar button). It runs the same command the
        // bar button does, so the wallpaper is re-tinted too.
        ConfigRow {
            uniform: true
            ConfigSwitch {
                buttonIcon: "dark_mode"
                text: Translation.tr("Dark mode (theme)")
                checked: Appearance.m3colors.darkmode
                onCheckedChanged: {
                    if (checked === Appearance.m3colors.darkmode)
                        return; // Ignore the binding settling on load.
                    // Goes through the service so that a separate light/dark
                    // wallpaper comes along with the theme change when one is set.
                    Wallpapers.setTheme(checked);
                }
            }
        }
    }

    ContentSection {
        icon: "cloud"
        title: Translation.tr("Weather")
        ConfigSwitch {
            buttonIcon: "check"
            text: Translation.tr("Enable")
            checked: Config.options.bar.weather.enable
            onCheckedChanged: {
                Config.options.bar.weather.enable = checked;
            }
        }
    }

    ContentSection {
        icon: "workspaces"
        title: Translation.tr("Workspaces")

        // Only `shown` is here on purpose. The four controls that used to sit
        // here -- "Always show numbers", "Show app icons", "Tint app icons",
        // "Number show delay when pressing Super" and the "Number style"
        // picker (Normal / Han chars / Roman) -- were removed because they
        // drove NOTHING. Workspaces.qml was rebuilt as the "ball & line"
        // design, which draws no numbers and no per-desktop app icons at all
        // (see the comment at the top of that file: "No numbers anywhere"), so
        // every one of those switches moved a slider and changed no pixel.
        // Their config keys are still in Config.qml for anyone who cares about
        // a stored value; they are simply no longer offered as settings,
        // because offering a control that cannot do anything is worse than
        // not offering it.
        ConfigSpinBox {
            icon: "view_column"
            text: Translation.tr("Workspaces shown")
            value: Config.options.bar.workspaces.shown
            from: 1
            to: 30
            stepSize: 1
            onValueChanged: {
                Config.options.bar.workspaces.shown = value;
            }
        }
    }

    ContentSection {
        icon: "tooltip"
        title: Translation.tr("Tooltips")
        ConfigSwitch {
            buttonIcon: "ads_click"
            text: Translation.tr("Click to show")
            checked: Config.options.bar.tooltips.clickToShow
            onCheckedChanged: {
                Config.options.bar.tooltips.clickToShow = checked;
            }
        }
    }
}
