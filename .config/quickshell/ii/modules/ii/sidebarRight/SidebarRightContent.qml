import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Bluetooth
import Quickshell.Hyprland

import qs.modules.ii.sidebarRight.quickToggles
import qs.modules.ii.sidebarRight.quickToggles.classicStyle

import qs.modules.ii.sidebarRight.bluetoothDevices
import qs.modules.ii.sidebarRight.notifications
import qs.modules.ii.sidebarRight.nightLight
import qs.modules.ii.sidebarRight.volumeMixer
import qs.modules.ii.sidebarRight.wifiNetworks

Item {
    id: root
    property int sidebarWidth: Appearance.sizes.sidebarWidth
    property int sidebarPadding: 10
    property bool showAudioOutputDialog: false
    property bool showAudioInputDialog: false
    property bool showBluetoothDialog: false
    property bool showNightLightDialog: false
    property bool showWifiDialog: false
    property bool editMode: false // the pencil button below turns this on
    // "Give the notifications the whole sidebar": the list's count label turns
    // this on, and while it is on the quick panel, the top-bar icon row, the
    // sliders and the media strip step aside so the list has the sidebar's
    // full height. Temporary by design -- closing the sidebar drops it.
    //
    // The LIST cannot do this itself: it is an `anchors.fill` child of the
    // notifications card, and that card is one cell of this column, so the
    // only thing that can hand the column's other cells away is the thing
    // that owns the column.
    property bool notificationsExtended: false

    Connections {
        target: GlobalStates
        function onSidebarRightOpenChanged() {
            if (!GlobalStates.sidebarRightOpen) {
                root.notificationsExtended = false;
                root.showWifiDialog = false;
                root.showBluetoothDialog = false;
                root.showAudioOutputDialog = false;
                root.showAudioInputDialog = false;
            }
        }
    }

    implicitHeight: sidebarRightBackground.implicitHeight
    implicitWidth: sidebarRightBackground.implicitWidth

    StyledRectangularShadow {
        target: sidebarRightBackground
    }
    Rectangle {
        id: sidebarRightBackground

        anchors.fill: parent
        implicitHeight: parent.height - Appearance.sizes.hyprlandGapsOut * 2
        implicitWidth: sidebarWidth - Appearance.sizes.hyprlandGapsOut * 2
        color: Appearance.colors.colLayer0
        border.width: 1
        border.color: Appearance.colors.colLayer0Border
        radius: Appearance.rounding.screenRounding - Appearance.sizes.hyprlandGapsOut + 1

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: sidebarPadding
            spacing: sidebarPadding

            SystemButtonRow {
                Layout.fillHeight: false
                Layout.fillWidth: true
                // Layout.margins: 10
                Layout.topMargin: 5
                Layout.bottomMargin: 0
            }

            LoaderedQuickPanelImplementation {
                styleName: "classic"
                sourceComponent: ClassicQuickPanel {}
                visible: !root.notificationsExtended
            }

            LoaderedQuickPanelImplementation {
                styleName: "android"
                sourceComponent: AndroidQuickPanel {
                    editMode: root.editMode
                }
                visible: !root.notificationsExtended
            }

            // "Top bar icons": what the bar's right section shows.
            //
            // ALWAYS here, not only while editing the toggles. It used to appear
            // only in quick-toggle edit mode, which is why the only bar-icon
            // control most people ever saw was the settings app's -- the sidebar
            // version was hidden behind a pencil button. Folded it is one row
            // with its label; click it and you get the same list Settings > Bar >
            // Top bar icons shows, from the same file (TopBarIconPicker), so the
            // two can never disagree. "Tray icons on bar" is inside it now.
            TopBarWidgets {
                Layout.fillWidth: true
                Layout.topMargin: 2
            }

            // Volume sits UNDER the quick toggles: system buttons first, then the
            // toggles, then this, then the media player.
            Loader {
                id: slidersLoader
                Layout.fillWidth: true
                visible: active && !root.notificationsExtended
                active: {
                    const configQuickSliders = Config.options.sidebar.quickSliders
                    if (!configQuickSliders.enable) return false
                    if (!configQuickSliders.showMic && !configQuickSliders.showVolume && !configQuickSliders.showBrightness) return false;
                    return true;
                }
                sourceComponent: QuickSliders {}
            }

            // The media player, at its minimum: art, title, artist. It used to
            // be the bar's own widget inside a `fillHeight: true` card, which
            // stretched it into the biggest block in the sidebar (171px, measured)
            // around one line of text. See CompactMedia.qml.
            CompactMedia {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignHCenter
                visible: !root.notificationsExtended
            }

            // The notifications: the panel the To Do group used to be, and the
            // reason the media card above is a strip now.
            //
            // `fillHeight` gives the list every pixel the sidebar has left over,
            // so it is as tall as it can be rather than pinned to the To Do
            // group's old 350px box -- and its expand button hands it the quick
            // panel, the sliders and the media strip as well, for as long as you
            // want to read all of them (the button lives in the list's status
            // row; see NotificationList.qml).
            //
            // Measured budget: the stack above it (system row 48, quick panel
            // 192, top bar icons 46, sliders 59, media 60) plus spacing leaves
            // ~400px for this card on a 940px-tall screen, and ~730px when it is
            // extended. Before this arrangement the same stack ended in a 350px
            // media card and a 350px To Do group, which came to 918px in an
            // 865px sidebar: the bottom of it was silently past the panel's edge.
            // That is what the size changes here fix, not just taste.
            Rectangle {
                id: notificationsCard

                Layout.fillWidth: true
                Layout.fillHeight: true
                // Never collapse to nothing: on a short screen the list keeps
                // room for a couple of notifications and its status row.
                Layout.minimumHeight: 160
                radius: Appearance.rounding.normal
                color: Appearance.colors.colLayer1

                NotificationList {
                    anchors.fill: parent
                    anchors.margins: 5
                    extendable: true
                    extended: root.notificationsExtended
                    onExtendToggled: root.notificationsExtended = !root.notificationsExtended
                }
            }

            // The To Do / Timer group that used to close this column is gone:
            // its two widgets are tabs in the LEFT sidebar now (where a page gets
            // the sidebar's full height instead of a fixed 350px box), and the
            // space it held is what the notification panel above grew into. Both
            // widgets are still there, one tab away -- nothing was dropped,
            // BottomWidgetGroup.qml is simply no longer instantiated here.
        }
    }

    ToggleDialog {
        shownPropertyString: "showAudioOutputDialog"
        dialog: VolumeDialog {
            isSink: true
        }
    }

    ToggleDialog {
        shownPropertyString: "showAudioInputDialog"
        dialog: VolumeDialog {
            isSink: false
        }
    }

    ToggleDialog {
        shownPropertyString: "showBluetoothDialog"
        dialog: BluetoothDialog {}
        onShownChanged: {
            if (!shown) {
                Bluetooth.defaultAdapter.discovering = false;
            } else {
                Bluetooth.defaultAdapter.enabled = true;
                Bluetooth.defaultAdapter.discovering = true;
            }
        }
    }

    ToggleDialog {
        shownPropertyString: "showNightLightDialog"
        dialog: NightLightDialog {}
    }

    ToggleDialog {
        shownPropertyString: "showWifiDialog"
        dialog: WifiDialog {}
        onShownChanged: {
            if (!shown) return;
            Network.enableWifi();
            Network.rescanWifi();
        }
    }

    component ToggleDialog: Loader {
        id: toggleDialogLoader
        required property string shownPropertyString
        property alias dialog: toggleDialogLoader.sourceComponent
        readonly property bool shown: root[shownPropertyString]
        anchors.fill: parent

        onShownChanged: if (shown) toggleDialogLoader.active = true;
        active: shown
        onActiveChanged: {
            if (active) {
                item.show = true;
                item.forceActiveFocus();
            }
        }
        Connections {
            target: toggleDialogLoader.item
            function onDismiss() {
                toggleDialogLoader.item.show = false
                root[toggleDialogLoader.shownPropertyString] = false;
            }
            function onVisibleChanged() {
                if (!toggleDialogLoader.item.visible && !root[toggleDialogLoader.shownPropertyString]) toggleDialogLoader.active = false;
            }
        }
    }

    component LoaderedQuickPanelImplementation: Loader {
        id: quickPanelImplLoader
        required property string styleName
        Layout.alignment: item?.Layout.alignment ?? Qt.AlignHCenter
        Layout.fillWidth: item?.Layout.fillWidth ?? false
        visible: active
        active: Config.options.sidebar.quickToggles.style === styleName
        Connections {
            target: quickPanelImplLoader.item
            function onOpenAudioOutputDialog() {
                root.showAudioOutputDialog = true;
            }
            function onOpenAudioInputDialog() {
                root.showAudioInputDialog = true;
            }
            function onOpenBluetoothDialog() {
                root.showBluetoothDialog = true;
            }
            function onOpenNightLightDialog() {
                root.showNightLightDialog = true;
            }
            function onOpenWifiDialog() {
                root.showWifiDialog = true;
            }
        }
    }

    component SystemButtonRow: Item {
        implicitHeight: Math.max(userPill.implicitHeight, systemButtonsRow.implicitHeight)

        // The session menu lives only while the sidebar does. When the sidebar
        // closes, close the menu and drop the popup with it -- `Loader.active` is
        // the state that says "built". (This has to sit inside this component:
        // `sessionMenuLoader` is an id scoped here, not visible at file level.)
        Connections {
            target: GlobalStates
            function onSidebarRightOpenChanged() {
                if (GlobalStates.sidebarRightOpen) return;
                if (sessionMenuLoader.item?.visible ?? false)
                    sessionMenuLoader.item.close();
                sessionMenuLoader.active = false;
                // Same teardown for the power menu in this row: a popup left
                // pointing at a button that is about to be destroyed is the
                // crash SessionMenu documents.
                if (powerMenuLoader.item?.visible ?? false)
                    powerMenuLoader.item.close();
                powerMenuLoader.active = false;
            }
        }

        // Who is logged in, and the way out.
        //
        // This corner held the distribution logo, then the name, then the name
        // plus an uptime figure. It now holds just the name -- the one thing here
        // that is actually about you -- and it is a button: clicking it opens the
        // session menu (lock, log out, suspend, hibernate, restart, shut down),
        // which is where those actions belong. The uptime went because knowing the
        // machine has been on for three hours does not change what you do next,
        // and it competed with the name for the same small pill.
        RippleButton {
            id: userPill
            anchors {
                top: parent.top
                bottom: parent.bottom
                left: parent.left
            }
            buttonRadius: height / 2
            colBackground: Appearance.colors.colLayer1
            colBackgroundHover: Appearance.colors.colLayer1Hover
            colBackgroundToggled: Appearance.colors.colLayer1Hover
            colBackgroundToggledHover: Appearance.colors.colLayer1Hover
            toggled: sessionMenuLoader.item?.visible ?? false
            implicitHeight: userRow.implicitHeight + 8
            implicitWidth: userRow.implicitWidth + 22
            onClicked: {
                if (sessionMenuLoader.item?.visible ?? false) {
                    // Open: close it, and drop the popup entirely.
                    sessionMenuLoader.item.close();
                    sessionMenuLoader.active = false;
                } else if (sessionMenuLoader.active) {
                    // Closed by clicking away, but still built: just show it again.
                    sessionMenuLoader.item.open();
                } else {
                    // Not built at all yet; `onLoaded` opens it.
                    sessionMenuLoader.active = true;
                }
            }

            Row {
                id: userRow
                anchors.centerIn: parent

                // Keep this deliberately to the username only. The pill's hover
                // state is the affordance; the old distro icon and "Up 3m" text
                // added noise and made the session control look like a status readout.
                StyledText {
                    id: usernameText
                    anchors.verticalCenter: parent.verticalCenter
                    font.pixelSize: Appearance.font.pixelSize.normal
                    color: Appearance.colors.colOnLayer1
                    text: SystemInfo.username
                }
            }
        }

        // The session menu is built the first time the pill is clicked and
        // destroyed when it closes -- it is deliberately NOT a permanent child.
        //
        // Quickshell 0.2.1 can segfault inside PopupAnchor when the item a popup
        // is anchored to is destroyed while the popup still points at it:
        // `PopupAnchor::setItem()` -> `onItemWindowChanged()` -> `QQuickItem::window()`
        // on a freed item. This sidebar is built lazily and torn down whenever it
        // closes, and a hot reload while the menu is open hits the same path --
        // that is the crash in ~/.cache/quickshell/crashes/6p70bclt. Two guards
        // keep it off: the popup only exists while the menu is open, and
        // SessionMenu.open() anchors to a geometry snapshot of the pill plus the
        // window, never to the pill item itself, so there is no live item pointer
        // left to dangle. (`Loader.active` is the state that says "built".)
        Loader {
            id: sessionMenuLoader
            active: false
            sourceComponent: sessionMenuComponent
            onLoaded: sessionMenuLoader.item.open()
        }

        Component {
            id: sessionMenuComponent
            SessionMenu { anchorItem: userPill }
        }

        ButtonGroup {
            id: systemButtonsRow
            anchors {
                top: parent.top
                bottom: parent.bottom
                right: parent.right
            }
            color: Appearance.colors.colLayer1
            padding: 4

            QuickToggleButton {
                toggled: root.editMode
                visible: Config.options.sidebar.quickToggles.style === "android"
                buttonIcon: "edit"
                onClicked: root.editMode = !root.editMode
                StyledToolTip {
                    text: Translation.tr("Edit quick toggles") + (root.editMode ? Translation.tr("\nLMB to enable/disable\nRMB to toggle size\nScroll to swap position") : "")
                }
            }
            QuickToggleButton {
                toggled: false
                buttonIcon: "restart_alt"
                onClicked: {
                    Quickshell.execDetached(["hyprctl", "reload"])
                    Quickshell.reload(true);
                }
                StyledToolTip {
                    // Same right-edge overflow as the power tooltip below.
                    x: parent.width - width - 2
                    text: Translation.tr("Reload Hyprland & Quickshell")
                }
            }
            QuickToggleButton {
                toggled: false
                buttonIcon: "settings"
                onClicked: {
                    GlobalStates.sidebarRightOpen = false;
                    Quickshell.execDetached(["bash", Quickshell.shellPath("scripts/launch/settings.sh")]);
                }
                StyledToolTip {
                    text: Translation.tr("Settings")
                }
            }
            // Power: Sleep, Restart, Power off.
            //
            // Last in this row, so it is the button in the actual top-right
            // corner of the sidebar -- the corner people reach for without
            // looking, which is the whole point of putting it there.
            //
            // Built and destroyed on the same terms as the session menu above
            // (`sessionMenuLoader`): a PopupWindow keeps a live pointer to its
            // anchor item, and this row is torn down whenever the sidebar
            // closes, so holding the popup open across that teardown is the
            // segfault SessionMenu documents at length.
            QuickToggleButton {
                id: powerButton
                toggled: powerMenuLoader.item?.visible ?? false
                buttonIcon: "power_settings_new"
                onClicked: {
                    if (powerMenuLoader.item?.visible ?? false) {
                        powerMenuLoader.item.close();
                        powerMenuLoader.active = false;
                    } else if (powerMenuLoader.active) {
                        powerMenuLoader.item.open();
                    } else {
                        powerMenuLoader.active = true;
                    }
                }
                StyledToolTip {
                    // These buttons sit ~20px from the sidebar's right edge, and
                    // a Qt tooltip centres itself on its control -- so anything
                    // wider than ~40px runs out past the panel and gets its
                    // leading characters cut off. Right-aligning to the button
                    // instead of centring on it puts the whole label inside the
                    // sidebar. (StyledToolTipContent's own text/card sizing bug
                    // is fixed separately, in that file.)
                    x: parent.width - width - 2
                    text: Translation.tr("Power — sleep, restart or shut down")
                }
            }
            // The account button on the left of this row still carries the full
            // session menu (lock, log out, suspend, hibernate, restart, shut
            // down). This row's power button is the short, everyday one: the
            // three things you actually do at the end of a session, in the
            // corner you reach for. Sleep is deliberately absent from the
            // account menu's sense of the word and comes from Session.sleep(),
            // which keeps the session alive rather than ending it.
        }

        // The power menu, built on first click and dropped on close, for the
        // same reason and with the same guards as the session menu above.
        Loader {
            id: powerMenuLoader
            active: false
            sourceComponent: powerMenuComponent
            onLoaded: powerMenuLoader.item.open()
        }

        Component {
            id: powerMenuComponent
            PowerMenu { anchorItem: powerButton }
        }
    }
}
