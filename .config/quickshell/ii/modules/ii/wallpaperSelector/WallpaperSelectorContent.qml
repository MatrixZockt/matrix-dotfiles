import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Io

MouseArea {
    id: root
    property int columns: 4
    property real previewCellAspectRatio: 4 / 3
    property bool useDarkMode: Appearance.m3colors.darkmode

    function updateThumbnails() {
        const totalImageMargin = (Appearance.sizes.wallpaperSelectorItemMargins + Appearance.sizes.wallpaperSelectorItemPadding) * 2;
        const thumbnailSizeName = Images.thumbnailSizeNameForDimensions(grid.cellWidth - totalImageMargin, grid.cellHeight - totalImageMargin);
        Wallpapers.generateThumbnail(thumbnailSizeName);
    }

    Connections {
        target: Wallpapers
        function onDirectoryChanged() {
            root.updateThumbnails();
        }
    }

    function handleFilePasting(event) {
        const currentClipboardEntry = Cliphist.entries[0];
        if (/^\d+\tfile:\/\/\S+/.test(currentClipboardEntry)) {
            const url = StringUtils.cleanCliphistEntry(currentClipboardEntry);
            Wallpapers.setDirectory(FileUtils.trimFileProtocol(decodeURIComponent(url)));
            event.accepted = true;
        } else {
            event.accepted = false; // No image, let text pasting proceed
        }
    }

    // Where the picture you pick is going to go.
    //
    //   "desktop" ... the usual: switch the wallpaper and regenerate the
    //                 shell's colours from it
    //   "lock"    ... only the lock screen's background, via the override file
    //                 hyprlock sources after matugen's colors.conf. The desktop
    //                 wallpaper and the colour scheme are left completely alone,
    //                 which is the point: a dark lock picture and a light
    //                 desktop can coexist.
    // Remembered between sessions, because picking a lock picture is usually
    // two or three in a row.
    property string target: Persistent.states.wallpaperTarget ?? "desktop"
    readonly property string lockWallpaperScript: `${FileUtils.trimFileProtocol(Directories.scriptPath)}/colors/set-lock-wallpaper.sh`

    function selectWallpaperPath(filePath) {
        if (filePath && filePath.length > 0) {
            if (root.target === "lock") {
                root.applyLockWallpaper(filePath);
                return; // The selector stays open: you are usually picking several.
            }
            if (root.target === "login") {
                // The login screen only reads its picture on a Reinstall
                // (Settings → Login), so remember the choice and close.
                Config.options.background.wallpaperPathLogin = filePath;
                GlobalStates.wallpaperSelectorOpen = false;
                return;
            }
            Wallpapers.select(filePath, root.useDarkMode);
            filterField.text = "";
        }
    }

    function applyLockWallpaper(filePath) {
        // `$1` rather than string interpolation: a path with a space or a quote
        // in it is not worth breaking over.
        Quickshell.execDetached([
            "bash", "-c",
            `"${root.lockWallpaperScript}" "$1" && notify-send -a "${Translation.tr("Wallpaper")}" -i "$1" "${Translation.tr("Lock screen picture set")}" "$(basename "$1")"`,
            "set-lock-wallpaper",
            filePath,
        ]);
    }

    function clearLockWallpaper() {
        Quickshell.execDetached([
            "bash", "-c",
            `"${root.lockWallpaperScript}" --clear && notify-send -a "${Translation.tr("Wallpaper")}" "${Translation.tr("Lock screen follows the desktop again")}"`,
        ]);
    }

    acceptedButtons: Qt.BackButton | Qt.ForwardButton
    onPressed: event => {
        if (event.button === Qt.BackButton) {
            Wallpapers.navigateBack();
        } else if (event.button === Qt.ForwardButton) {
            Wallpapers.navigateForward();
        }
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape) {
            GlobalStates.wallpaperSelectorOpen = false;
            event.accepted = true;
        } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_V) { // Intercept Ctrl+V to handle "paste to go to" in pickers
            root.handleFilePasting(event);
        } else if (event.modifiers & Qt.AltModifier && event.key === Qt.Key_Up) {
            Wallpapers.navigateUp();
            event.accepted = true;
        } else if (event.modifiers & Qt.AltModifier && event.key === Qt.Key_Left) {
            Wallpapers.navigateBack();
            event.accepted = true;
        } else if (event.modifiers & Qt.AltModifier && event.key === Qt.Key_Right) {
            Wallpapers.navigateForward();
            event.accepted = true;
        } else if (event.key === Qt.Key_Left) {
            grid.moveSelection(-1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Right) {
            grid.moveSelection(1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Up) {
            grid.moveSelection(-grid.columns);
            event.accepted = true;
        } else if (event.key === Qt.Key_Down) {
            grid.moveSelection(grid.columns);
            event.accepted = true;
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            grid.activateCurrent();
            event.accepted = true;
        } else if (event.key === Qt.Key_Backspace) {
            if (filterField.text.length > 0) {
                filterField.text = filterField.text.substring(0, filterField.text.length - 1);
            }
            filterField.forceActiveFocus();
            event.accepted = true;
        } else if (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_L) {
            addressBar.focusBreadcrumb();
            event.accepted = true;
        } else if (event.key === Qt.Key_Slash) {
            filterField.forceActiveFocus();
            event.accepted = true;
        } else {
            if (event.text.length > 0) {
                filterField.text += event.text;
                filterField.cursorPosition = filterField.text.length;
                filterField.forceActiveFocus();
            }
            event.accepted = true;
        }
    }

    implicitHeight: mainLayout.implicitHeight
    implicitWidth: mainLayout.implicitWidth

    StyledRectangularShadow {
        target: wallpaperGridBackground
    }
    Rectangle {
        id: wallpaperGridBackground
        anchors {
            fill: parent
            margins: Appearance.sizes.elevationMargin
        }
        focus: true
        border.width: 1
        border.color: Appearance.colors.colLayer0Border
        color: Appearance.colors.colLayer0
        radius: Appearance.rounding.screenRounding - Appearance.sizes.hyprlandGapsOut + 1

        property int calculatedRows: Math.ceil(grid.count / grid.columns)

        implicitWidth: gridColumnLayout.implicitWidth
        implicitHeight: gridColumnLayout.implicitHeight

        RowLayout {
            id: mainLayout
            anchors.fill: parent
            spacing: -4

            Rectangle {
                Layout.fillHeight: true
                Layout.margins: 4
                implicitWidth: quickDirColumnLayout.implicitWidth
                implicitHeight: quickDirColumnLayout.implicitHeight
                color: Appearance.colors.colLayer1
                radius: wallpaperGridBackground.radius - Layout.margins

                ColumnLayout {
                    id: quickDirColumnLayout
                    anchors.fill: parent
                    spacing: 0

                    StyledText {
                        Layout.margins: 12
                        font {
                            pixelSize: Appearance.font.pixelSize.normal
                            weight: Font.Medium
                        }
                        // Says where the picture is going, because the same
                        // grid now serves two destinations and a silent mode
                        // switch is how you set the wrong wallpaper.
                        text: root.target === "lock"
                            ? Translation.tr("Pick a lock screen picture")
                            : Translation.tr("Pick a wallpaper")
                    }
                    StyledListView {
                        // Quick dirs
                        Layout.fillHeight: true
                        Layout.margins: 4
                        implicitWidth: 140
                        clip: true
                        model: [
                            {
                                icon: "home",
                                name: "Home",
                                path: Directories.home
                            },
                            {
                                icon: "docs",
                                name: "Documents",
                                path: Directories.documents
                            },
                            {
                                icon: "download",
                                name: "Downloads",
                                path: Directories.downloads
                            },
                            {
                                icon: "image",
                                name: "Pictures",
                                path: Directories.pictures
                            },
                            {
                                icon: "movie",
                                name: "Videos",
                                path: Directories.videos
                            },
                            {
                                icon: "",
                                name: "---",
                                path: "INTENTIONALLY_INVALID_DIR"
                            },
                            {
                                icon: "wallpaper",
                                name: "Wallpapers",
                                path: `${Directories.pictures}/Wallpapers`
                            },
                            ...(Config.options.policies.weeb === 1 ? [
                                    {
                                        icon: "favorite",
                                        name: "Homework",
                                        path: `${Directories.pictures}/homework`
                                    }
                                ] : []),]
                        delegate: RippleButton {
                            id: quickDirButton
                            required property var modelData
                            anchors {
                                left: parent.left
                                right: parent.right
                            }
                            onClicked: Wallpapers.setDirectory(quickDirButton.modelData.path)
                            enabled: modelData.icon.length > 0
                            toggled: Wallpapers.directory === Qt.resolvedUrl(modelData.path)
                            colBackgroundToggled: Appearance.colors.colSecondaryContainer
                            colBackgroundToggledHover: Appearance.colors.colSecondaryContainerHover
                            colRippleToggled: Appearance.colors.colSecondaryContainerActive
                            buttonRadius: height / 2
                            implicitHeight: 38

                            contentItem: RowLayout {
                                MaterialSymbol {
                                    color: quickDirButton.toggled ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                                    iconSize: Appearance.font.pixelSize.larger
                                    text: quickDirButton.modelData.icon
                                    fill: quickDirButton.toggled ? 1 : 0
                                }
                                StyledText {
                                    Layout.fillWidth: true
                                    horizontalAlignment: Text.AlignLeft
                                    color: quickDirButton.toggled ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                                    text: quickDirButton.modelData.name
                                }
                            }
                        }
                    }
                }
            }

            ColumnLayout {
                id: gridColumnLayout
                Layout.fillWidth: true
                Layout.fillHeight: true

                AddressBar {
                    id: addressBar
                    Layout.margins: 4
                    Layout.fillWidth: true
                    Layout.fillHeight: false
                    directory: Wallpapers.effectiveDirectory
                    onNavigateToDirectory: path => {
                        Wallpapers.setDirectory(path.length == 0 ? "/" : path);
                    }
                    radius: wallpaperGridBackground.radius - Layout.margins
                }

                Item {
                    id: gridDisplayRegion
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    StyledIndeterminateProgressBar {
                        id: indeterminateProgressBar
                        visible: Wallpapers.thumbnailGenerationRunning && value == 0
                        anchors {
                            bottom: parent.top
                            left: parent.left
                            right: parent.right
                            leftMargin: 4
                            rightMargin: 4
                        }
                    }

                    StyledProgressBar {
                        visible: Wallpapers.thumbnailGenerationRunning && value > 0
                        value: Wallpapers.thumbnailGenerationProgress
                        anchors.fill: indeterminateProgressBar
                    }

                    GridView {
                        id: grid
                        visible: Wallpapers.folderModel.count > 0

                        readonly property int columns: root.columns
                        readonly property int rows: Math.max(1, Math.ceil(count / columns))
                        property int currentIndex: 0

                        anchors.fill: parent
                        cellWidth: width / root.columns
                        cellHeight: cellWidth / root.previewCellAspectRatio
                        interactive: true
                        clip: true
                        keyNavigationWraps: true
                        boundsBehavior: Flickable.StopAtBounds
                        bottomMargin: extraOptions.implicitHeight
                        ScrollBar.vertical: StyledScrollBar {}

                        Component.onCompleted: {
                            root.updateThumbnails();
                        }

                        function moveSelection(delta) {
                            currentIndex = Math.max(0, Math.min(grid.model.count - 1, currentIndex + delta));
                            positionViewAtIndex(currentIndex, GridView.Contain);
                        }

                        function activateCurrent() {
                            const filePath = grid.model.get(currentIndex, "filePath");
                            root.selectWallpaperPath(filePath);
                        }

                        model: Wallpapers.folderModel
                        onModelChanged: currentIndex = 0
                        delegate: WallpaperDirectoryItem {
                            required property var modelData
                            required property int index
                            fileModelData: modelData
                            width: grid.cellWidth
                            height: grid.cellHeight
                            colBackground: (index === grid?.currentIndex || containsMouse) ? Appearance.colors.colPrimary : (fileModelData.filePath === Config.options.background.wallpaperPath) ? Appearance.colors.colSecondaryContainer : ColorUtils.transparentize(Appearance.colors.colPrimaryContainer)
                            colText: (index === grid.currentIndex || containsMouse) ? Appearance.colors.colOnPrimary : (fileModelData.filePath === Config.options.background.wallpaperPath) ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer0

                            onEntered: {
                                grid.currentIndex = index;
                            }

                            onActivated: {
                                root.selectWallpaperPath(fileModelData.filePath);
                            }
                        }

                        layer.enabled: true
                        layer.effect: OpacityMask {
                            maskSource: Rectangle {
                                width: gridDisplayRegion.width
                                height: gridDisplayRegion.height
                                radius: wallpaperGridBackground.radius
                            }
                        }
                    }

                    Row {
                        id: extraOptions
                        anchors {
                            bottom: parent.bottom
                            horizontalCenter: parent.horizontalCenter
                            bottomMargin: 8
                        }
                        spacing: 6
                        Toolbar {

                            // Destination: desktop or lock screen.
                            IconToolbarButton {
                                implicitWidth: height
                                text: "desktop_windows"
                                toggled: root.target === "desktop"
                                onClicked: Persistent.states.wallpaperTarget = "desktop"
                                StyledToolTip {
                                    text: Translation.tr("Set the desktop wallpaper")
                                }
                            }

                            IconToolbarButton {
                                implicitWidth: height
                                text: "lock"
                                toggled: root.target === "lock"
                                onClicked: Persistent.states.wallpaperTarget = "lock"
                                altAction: () => root.clearLockWallpaper()
                                StyledToolTip {
                                    text: Translation.tr("Set the lock screen picture\nRight-click to follow the desktop wallpaper again")
                                }
                            }

                            IconToolbarButton {
                                implicitWidth: height
                                text: "person"
                                toggled: root.target === "login"
                                onClicked: Persistent.states.wallpaperTarget = "login"
                                altAction: () => Config.options.background.wallpaperPathLogin = ""
                                StyledToolTip {
                                    text: Translation.tr("Set the login screen picture\nApplied on the next Reinstall (Settings → Login)\nRight-click to follow the desktop wallpaper again")
                                }
                            }

                            IconToolbarButton {
                                implicitWidth: height
                                onClicked: {
                                    Wallpapers.openFallbackPicker(root.useDarkMode);
                                    GlobalStates.wallpaperSelectorOpen = false;
                                }
                                altAction: () => {
                                    Wallpapers.openFallbackPicker(root.useDarkMode);
                                    GlobalStates.wallpaperSelectorOpen = false;
                                    Config.options.wallpaperSelector.useSystemFileDialog = true;
                                }
                                text: "open_in_new"
                                StyledToolTip {
                                    text: Translation.tr("Use the system file picker instead\nRight-click to make this the default behavior")
                                }
                            }

                            IconToolbarButton {
                                implicitWidth: height
                                onClicked: {
                                    Wallpapers.randomFromCurrentFolder();
                                }
                                text: "ifl"
                                StyledToolTip {
                                    text: Translation.tr("Pick random from this folder")
                                }
                            }

                            IconToolbarButton {
                                implicitWidth: height
                                onClicked: root.useDarkMode = !root.useDarkMode
                                text: root.useDarkMode ? "dark_mode" : "light_mode"
                                StyledToolTip {
                                    text: Translation.tr("Click to toggle light/dark mode\n(applied when wallpaper is chosen)")
                                }
                            }

                            ToolbarTextField {
                                id: filterField
                                placeholderText: focus ? Translation.tr("Search wallpapers") : Translation.tr("Hit \"/\" to search")

                                // Style
                                clip: true
                                font.pixelSize: Appearance.font.pixelSize.small

                                // Search
                                onTextChanged: {
                                    Wallpapers.searchQuery = text;
                                }

                                Keys.onPressed: event => {
                                    if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_V) { // Intercept Ctrl+V to handle "paste to go to" in pickers
                                        root.handleFilePasting(event);
                                        return;
                                    } else if (text.length !== 0) {
                                        // No filtering, just navigate grid
                                        if (event.key === Qt.Key_Down) {
                                            grid.moveSelection(grid.columns);
                                            event.accepted = true;
                                            return;
                                        }
                                        if (event.key === Qt.Key_Up) {
                                            grid.moveSelection(-grid.columns);
                                            event.accepted = true;
                                            return;
                                        }
                                    }
                                    event.accepted = false;
                                }
                            }
                        }

                        ToolbarPairedFab {
                            iconText: "close"
                            onClicked: GlobalStates.wallpaperSelectorOpen = false;
                            StyledToolTip {
                                text: Translation.tr("Cancel wallpaper selection")
                            }
                        }
                    }
                }
            }
        }
    }

    Connections {
        target: GlobalStates
        function onWallpaperSelectorOpenChanged() {
            if (GlobalStates.wallpaperSelectorOpen && monitorIsFocused) {
                filterField.forceActiveFocus();
            }
        }
    }

    Connections {
        target: Wallpapers
        function onChanged() {
            GlobalStates.wallpaperSelectorOpen = false;
        }
    }
}
