pragma ComponentBehavior: Bound

import Qt.labs.synchronizer
import Qt5Compat.GraphicalEffects
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets

import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

Item { // Wrapper
    id: root


    readonly property string xdgConfigHome: Directories.config
    readonly property int typingDebounceInterval: 200
    readonly property int typingResultLimit: 15 // Should be enough to cover the whole view

    property string searchingText: LauncherSearch.query
    property bool showResults: searchingText != ""
    // While the field is empty there is nothing to search for, so the panel offers
    // the apps that were opened from it before instead of an empty box.
    property bool recentVisible: !root.showResults && AppUsage.recent.length > 0
    // Terminal-only apps and the distro's control panels are held back until the
    // Advanced section is opened, so an ordinary search lists only real apps.
    property bool showAdvanced: false
    property int advancedResultCount: 0

    function refreshResults() {
        const all = LauncherSearch.results ?? [];
        root.advancedResultCount = all.filter(r => r?.advanced).length;
        const visible = root.showAdvanced ? all : all.filter(r => !r?.advanced);
        resultModel.values = visible.slice(0, root.showAdvanced ? 40 : root.typingResultLimit);
        root.focusFirstItem();
    }

    onSearchingTextChanged: {
        // A new query always starts collapsed.
        root.showAdvanced = false;
        root.refreshResults();
    }
    implicitWidth: searchWidgetContent.implicitWidth + Appearance.sizes.elevationMargin * 2
    implicitHeight: searchWidgetContent.implicitHeight + searchBar.verticalPadding * 2 + Appearance.sizes.elevationMargin * 2

    function focusFirstItem() {
        appResults.currentIndex = 0;
    }

    function focusSearchInput() {
        searchBar.forceFocus();
    }

    function disableExpandAnimation() {
        searchBar.animateWidth = false;
    }

    function cancelSearch() {
        // Clear, don't just select: selectAll() kept the old query visible
        // (highlighted) when the panel reopened, which read as "my search text
        // is still there". A SUPER tap gets a genuinely empty field.
        searchBar.searchInput.clear();
        LauncherSearch.query = "";
        searchBar.animateWidth = true;
    }

    function setSearchingText(text) {
        searchBar.searchInput.text = text;
        LauncherSearch.query = text;
    }

    Keys.onPressed: event => {
        // Prevent Esc and Backspace from registering
        if (event.key === Qt.Key_Escape)
            return;

        // Handle Backspace: focus and delete character if not focused
        if (event.key === Qt.Key_Backspace) {
            if (!searchBar.searchInput.activeFocus) {
                root.focusSearchInput();
                if (event.modifiers & Qt.ControlModifier) {
                    // Delete word before cursor
                    let text = searchBar.searchInput.text;
                    let pos = searchBar.searchInput.cursorPosition;
                    if (pos > 0) {
                        // Find the start of the previous word
                        let left = text.slice(0, pos);
                        let match = left.match(/(\s*\S+)\s*$/);
                        let deleteLen = match ? match[0].length : 1;
                        searchBar.searchInput.text = text.slice(0, pos - deleteLen) + text.slice(pos);
                        searchBar.searchInput.cursorPosition = pos - deleteLen;
                    }
                } else {
                    // Delete character before cursor if any
                    if (searchBar.searchInput.cursorPosition > 0) {
                        searchBar.searchInput.text = searchBar.searchInput.text.slice(0, searchBar.searchInput.cursorPosition - 1) + searchBar.searchInput.text.slice(searchBar.searchInput.cursorPosition);
                        searchBar.searchInput.cursorPosition -= 1;
                    }
                }
                // Always move cursor to end after programmatic edit
                searchBar.searchInput.cursorPosition = searchBar.searchInput.text.length;
                event.accepted = true;
            }
            // If already focused, let TextField handle it
            return;
        }

        // Only handle visible printable characters (ignore control chars, arrows, etc.)
        if (event.text && event.text.length === 1 && event.key !== Qt.Key_Enter && event.key !== Qt.Key_Return && event.key !== Qt.Key_Delete && event.text.charCodeAt(0) >= 0x20) // ignore control chars like Backspace, Tab, etc.
        {
            if (!searchBar.searchInput.activeFocus) {
                root.focusSearchInput();
                // Insert the character at the cursor position
                searchBar.searchInput.text = searchBar.searchInput.text.slice(0, searchBar.searchInput.cursorPosition) + event.text + searchBar.searchInput.text.slice(searchBar.searchInput.cursorPosition);
                searchBar.searchInput.cursorPosition += 1;
                event.accepted = true;
                root.focusFirstItem();
            }
        }
    }

    StyledRectangularShadow {
        target: searchWidgetContent
    }
    Rectangle { // Background
        id: searchWidgetContent
        anchors {
            top: parent.top
            horizontalCenter: parent.horizontalCenter
            topMargin: Appearance.sizes.elevationMargin
        }
        clip: true
        implicitWidth: columnLayout.implicitWidth
        implicitHeight: columnLayout.implicitHeight
        radius: searchBar.height / 2 + searchBar.verticalPadding
        color: Appearance.colors.colBackgroundSurfaceContainer

        Behavior on implicitHeight {
            id: searchHeightBehavior
            enabled: GlobalStates.overviewOpen && (root.showResults || root.recentVisible)
            animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
        }

        ColumnLayout {
            id: columnLayout
            anchors {
                top: parent.top
                horizontalCenter: parent.horizontalCenter
            }
            spacing: 0

            // clip: true
            layer.enabled: true
            layer.effect: OpacityMask {
                maskSource: Rectangle {
                    width: searchWidgetContent.width
                    height: searchWidgetContent.width
                    radius: searchWidgetContent.radius
                }
            }

            SearchBar {
                id: searchBar
                property real verticalPadding: 4
                Layout.fillWidth: true
                Layout.leftMargin: 10
                Layout.rightMargin: 4
                Layout.topMargin: verticalPadding
                Layout.bottomMargin: verticalPadding
                Synchronizer on searchingText {
                    property alias source: root.searchingText
                }
            }

            Rectangle {
                // Separator
                visible: root.showResults || root.recentVisible
                Layout.fillWidth: true
                height: 1
                color: Appearance.colors.colOutlineVariant
            }

            // ── Recently used apps ───────────────────────────────────────────
            // A row of app tiles rather than a list: this is meant to be recognised
            // at a glance and clicked, not read. Every tile is an app that was
            // launched from this panel before, most recent first, and the whole row
            // can be forgotten with the x.
            ColumnLayout {
                id: recentsSection
                visible: root.recentVisible
                Layout.fillWidth: true
                Layout.leftMargin: 12
                Layout.rightMargin: 12
                Layout.topMargin: 8
                Layout.bottomMargin: 10
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    MaterialSymbol {
                        Layout.alignment: Qt.AlignVCenter
                        text: "history"
                        iconSize: 16
                        color: Appearance.colors.colOnSurfaceVariant
                    }
                    StyledText {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        text: Translation.tr("Recently used")
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colOnSurfaceVariant
                    }
                    RippleButton {
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: 28
                        implicitHeight: 28
                        buttonRadius: Appearance.rounding.full
                        onClicked: AppUsage.clear()
                        contentItem: MaterialSymbol {
                            anchors.centerIn: parent
                            text: "delete_sweep"
                            iconSize: 15
                            color: Appearance.colors.colOnSurfaceVariant
                        }
                        StyledToolTip {
                            text: Translation.tr("Forget these")
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    Repeater {
                        model: AppUsage.recent

                        delegate: RippleButton {
                            id: recentTile
                            required property var modelData
                            Layout.alignment: Qt.AlignVCenter
                            implicitWidth: 46
                            implicitHeight: 46
                            buttonRadius: Appearance.rounding.normal
                            onClicked: {
                                GlobalStates.overviewOpen = false;
                                // Launch through the shell, so a remembered app that
                                // has since been uninstalled ends with "couldn't
                                // open it" on the card instead of nothing at all.
                                const command = AppUsage.commandFor(recentTile.modelData.id);
                                if (command.length === 0)
                                    return;
                                // Plain name, not "Opening X": the label is tested
                                // against window classes by the already-open matcher.
                                GlobalStates.openApp(command, recentTile.modelData.name ?? "");
                            }
                            contentItem: IconImage {
                                anchors.centerIn: parent
                                implicitSize: 28
                                source: Quickshell.iconPath(AppUsage.resolveIcon(recentTile.modelData.id, recentTile.modelData.icon), Quickshell.shellPath("assets/icons/fluent/app-generic.svg"))
                            }
                            StyledToolTip {
                                text: recentTile.modelData.name ?? ""
                            }
                        }
                    }

                    Item {
                        Layout.fillWidth: true
                    }
                }
            }

            StyledListView { // App results
                id: appResults
                visible: root.showResults
                Layout.fillWidth: true
                implicitHeight: Math.min(600, appResults.contentHeight + topMargin + bottomMargin)
                clip: true
                topMargin: 10
                bottomMargin: 10
                spacing: 2
                KeyNavigation.up: searchBar
                highlightMoveDuration: 100

                onFocusChanged: {
                    if (focus)
                        appResults.currentIndex = 1;
                }

                Connections {
                    target: root
                    function onSearchingTextChanged() {
                        if (appResults.count > 0)
                            appResults.currentIndex = 0;
                    }
                }

                Timer {
                    id: debounceTimer
                    interval: root.typingDebounceInterval
                    onTriggered: root.refreshResults()
                }

                Connections {
                    target: LauncherSearch
                    function onResultsChanged() {
                        root.refreshResults();
                        debounceTimer.restart();
                    }
                }

                model: ScriptModel {
                    id: resultModel
                    objectProp: "key"
                }

                delegate: SearchItem {
                    id: searchItem
                    // The selectable item for each search result
                    required property var modelData
                    // Route through the shell's launch choke point so an app
                    // that is already running focuses instead of duplicating.
                    itemExecute: () => GlobalStates.launchSearchEntry(searchItem.entry)
                    anchors.left: parent?.left
                    anchors.right: parent?.right
                    entry: modelData
                    query: StringUtils.cleanOnePrefix(root.searchingText, [Config.options.search.prefix.action, Config.options.search.prefix.app, Config.options.search.prefix.clipboard, Config.options.search.prefix.emojis, Config.options.search.prefix.math, Config.options.search.prefix.shellCommand, Config.options.search.prefix.webSearch])

                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Tab) {
                            if (LauncherSearch.results.length === 0)
                                return;
                            const tabbedText = searchItem.modelData.name;
                            LauncherSearch.query = tabbedText;
                            searchBar.searchInput.text = tabbedText;
                            event.accepted = true;
                            root.focusSearchInput();
                        }
                    }
                }
            }

            // The Advanced section. Only appears when there is something in it,
            // and never opens itself.
            RippleButton {
                id: advancedToggle
                visible: root.showResults && root.advancedResultCount > 0
                Layout.fillWidth: true
                Layout.leftMargin: 10
                Layout.rightMargin: 10
                Layout.bottomMargin: 10
                implicitHeight: 34
                buttonRadius: Appearance.rounding.small
                onClicked: {
                    root.showAdvanced = !root.showAdvanced;
                    root.refreshResults();
                }
                contentItem: RowLayout {
                    spacing: 8
                    MaterialSymbol {
                        Layout.leftMargin: 6
                        text: root.showAdvanced ? "expand_less" : "expand_more"
                        iconSize: 18
                        color: Appearance.colors.colOnSurfaceVariant
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: root.showAdvanced
                            ? Translation.tr("Hide advanced (%1)").arg(root.advancedResultCount)
                            : Translation.tr("Advanced (%1) - command-line apps and system panels").arg(root.advancedResultCount)
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colOnSurfaceVariant
                        elide: Text.ElideRight
                    }
                }
            }
        }
    }
}
