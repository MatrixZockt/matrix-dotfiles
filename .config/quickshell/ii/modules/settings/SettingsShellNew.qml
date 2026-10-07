import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions as CF

/**
 * The settings app's shell -- Windows' Settings layout.
 *
 * WHAT CHANGED, and why it is the layout and not the content:
 *
 * The old shell put the navigation in a collapsible ICON RAIL down the left
 * edge, collapsed to icons under 800px, with the config-file button on top and
 * seventeen pages scrolling under it. Finding anything meant: know which page
 * owns it, expand the rail if it had collapsed, scroll to it, then read the
 * page to find the control. That is four steps before you can change
 * anything, and the first one requires already knowing the answer.
 *
 * Windows solved this by inverting it. The navigation is a plain list of
 * words, always visible, and there is a SEARCH BOX at the top of it that you
 * can type into immediately. You no longer navigate to a setting; you say what
 * you want and go there.
 *
 * So the three things that carry that idea here:
 *
 *   1. THE SEARCH BOX is at the top of the sidebar, always present, focused on
 *      open, and it searches SETTINGS -- not just pages. Typing "night" takes
 *      you to the night-light control on the Display page, not to a page you
 *      then have to scan.
 *   2. The results float OVER the content rather than pushing it down, so the
 *      page you are looking at does not move while you type at it.
 *   3. The navigation list is words, not icons, and is grouped the way Windows
 *      groups it, so the app can be read rather than decoded.
 *
 * Everything about the PAGES is unchanged -- same registry, same Loader, same
 * components. That is deliberate: the pages work, and rewriting them is a
 * separate job. This is the frame around them.
 */
Item {
    id: root

    // The host supplies these, exactly as the old shell did.
    property var pages: []
    property int currentPage: 0
    property real contentPadding: 12

    signal quitRequested()
    // A search result asked for a specific page AND section. The host applies
    // the page; the section is applied by the page itself (see onActivated).
    signal sectionRequested(string section)

    function quitApp() {
        root.quitRequested();
    }

    function goToPage(slug) {
        if (!slug || slug.length === 0) return;
        const index = root.pages.findIndex(page => page.slug === slug);
        if (index >= 0 && index !== root.currentPage) root.currentPage = index;
    }

    readonly property var currentPageData: {
        const index = Math.max(0, Math.min(root.currentPage, root.pages.length - 1));
        return root.pages[index];
    }

    focus: true

    // ── Keyboard ──────────────────────────────────────────────────────────
    //
    // Windows: Ctrl+F (or just "/" ) focuses the search box from anywhere.
    // That shortcut is the whole reason search feels native rather than
    // bolted on -- you never have to look for the box.
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape) {
            // Escape belongs to the search first: if a search is running, it
            // closes, and only an Escape with nothing to close leaves the app.
            if (SettingsSearch.active || searchOpen) {
                root.closeSearch();
                event.accepted = true;
                return;
            }
            root.quitApp();
            event.accepted = true;
            return;
        }
        // Ctrl+F, or "/" when not already typing into something.
        if ((event.modifiers === Qt.ControlModifier && event.key === Qt.Key_F)
            || (event.key === Qt.Key_Slash && event.modifiers === Qt.NoModifier)) {
            root.openSearch();
            event.accepted = true;
            return;
        }
        if (event.modifiers === Qt.ControlModifier) {
            if (event.key === Qt.Key_PageDown || event.key === Qt.Key_Tab) {
                root.currentPage = Math.min(root.currentPage + 1, root.pages.length - 1);
                event.accepted = true;
            } else if (event.key === Qt.Key_PageUp || event.key === Qt.Key_Backtab) {
                root.currentPage = Math.max(root.currentPage - 1, 0);
                event.accepted = true;
            }
        }
    }

    // ── Search state ──────────────────────────────────────────────────────
    //
    // `searchOpen` is separate from `SettingsSearch.active` on purpose:
    // "the user asked to search" (the box is focused, results are allowed to
    // drop) and "there is text in the box" are different states, and the box
    // has to stay put in the first while the second is false.
    property bool searchOpen: false

    function openSearch() {
        root.searchOpen = true;
        searchBox.focusSearch();
    }

    function closeSearch() {
        root.searchOpen = false;
        SettingsSearch.reset();
        root.forceActiveFocus();
    }

    // A result was chosen: go to its page, tell the page which section, and
    // put the keyboard back where it was.
    function onSearchActivated(pageSlug, section) {
        root.closeSearch();
        root.goToPage(pageSlug);
        if (section && section.length > 0)
            root.sectionRequested(section);
    }

    // The app's page registry is the search index's page list, so adding a
    // page adds it to search. Set once, here, rather than in the service --
    // the service has no business knowing the app exists.
    Component.onCompleted: SettingsSearch.pageRegistry = root.pages

    // ── Grouped navigation ────────────────────────────────────────────────
    //
    // Windows groups its sidebar into sections with a small caption above
    // each. The registry already carries a `group` per page, so the grouping is
    // derived rather than hand-written -- a new page joins its group by
    // carrying the right name.
    readonly property var groups: {
        const order = [];
        const buckets = {};
        for (const page of root.pages) {
            const g = page.group ?? "";
            if (!buckets[g]) {
                buckets[g] = [];
                order.push(g);
            }
            buckets[g].push(page);
        }
        return order.map(name => ({ name: name, pages: buckets[name] }));
    }

    Rectangle {
        id: background
        anchors.fill: parent
        color: CF.ColorUtils.transparentize(Appearance.m3colors.m3surfaceContainerLow, 0.5)
    }

    RowLayout {
        anchors.fill: parent
        anchors.margins: root.contentPadding
        spacing: root.contentPadding

        // ══ Sidebar ═══════════════════════════════════════════════════════
        Rectangle {
            id: sidebar
            Layout.fillHeight: true
            // Wide enough for the longest label and never narrower than the
            // search box needs. Fixed, because this is the app's one
            // navigation surface and a sidebar that reflows with the window
            // is the thing being replaced.
            Layout.preferredWidth: Math.max(280, Math.min(340, root.width * 0.3))
            radius: Appearance.rounding.normal
            color: CF.ColorUtils.transparentize(Appearance.colors.colLayer1, 0.35)

            // The results list is WIDER than the sidebar and hangs down over
            // the content pane. QML paints a sibling's children with that
            // sibling, and the content pane is declared after the sidebar, so
            // without this the pane would paint straight over the results and
            // the search would look broken only while it had something to
            // show. Raised only while there are results, so the ordinary case
            // keeps the natural stacking.
            z: (root.searchOpen && SettingsSearch.results.length > 0) ? 10 : 0

            // The box lives INSIDE the sidebar at the top, like Windows. It is
            // not a header and not a floating overlay: it is part of the
            // navigation, because that is what it replaces.
            SettingsSearchBox {
                id: searchBox
                anchors {
                    left: parent.left
                    right: parent.right
                    top: parent.top
                    leftMargin: 12
                    rightMargin: 12
                    topMargin: 12
                }
                onActivated: (pageSlug, section) => root.onSearchActivated(pageSlug, section)
            }

            StyledFlickable {
                id: navList
                anchors {
                    left: parent.left
                    right: parent.right
                    top: searchBox.bottom
                    bottom: parent.bottom
                    topMargin: 8
                }
                contentHeight: navColumn.implicitHeight + 24
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: navColumn
                    x: 12
                    y: 12
                    width: navList.width - 24
                    spacing: 2

                    // Group captions, then that group's pages -- the shape
                    // Windows uses, and the reason the sidebar reads as a
                    // list of things rather than a wall of icons.
                    Repeater {
                        model: root.groups
                        delegate: ColumnLayout {
                            id: groupBlock
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: 2

                            StyledText {
                                Layout.fillWidth: true
                                Layout.topMargin: groupBlock.index === 0 ? 0 : 14
                                Layout.bottomMargin: 4
                                Layout.leftMargin: 12
                                visible: (groupBlock.modelData.name ?? "").length > 0
                                color: Appearance.colors.colSubtext
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                font.weight: Font.Medium
                                // Uppercased and letter-spaced: a caption, not
                                // an item. This one small typographic choice is
                                // most of what separates "grouped list" from
                                // "list".
                                text: (groupBlock.modelData.name ?? "").toUpperCase()
                            }

                            Repeater {
                                model: groupBlock.modelData.pages
                                delegate: RippleButton {
                                    id: navItem
                                    required property var modelData
                                    required property int index

                                    Layout.fillWidth: true
                                    implicitHeight: 42
                                    buttonRadius: Appearance.rounding.small
                                    colBackground: "transparent"
                                    colBackgroundHover: Appearance.colors.colLayer1Hover
                                    pointingHandCursor: true
                                    onClicked: {
                                        if (root.searchOpen || SettingsSearch.active)
                                            root.closeSearch();
                                        const i = root.pages.findIndex(p => p.slug === navItem.modelData.slug);
                                        if (i >= 0)
                                            root.currentPage = i;
                                    }

                                    // The selected page's pill. Drawn as an
                                    // explicit child rather than left to
                                    // `toggled`, because the pill has to be
                                    // visible even when the pointer is nowhere
                                    // near the sidebar.
                                    Rectangle {
                                        anchors.fill: parent
                                        // `buttonRadius`, not `radius`: on a
                                        // RippleButton the radius property is
                                        // `buttonRadius`, and `radius` resolves
                                        // to undefined -- which is an
                                        // "Unable to assign [undefined] to
                                        // double" that takes the shell down.
                                        radius: navItem.buttonRadius
                                        color: Appearance.colors.colSecondaryContainer
                                        visible: {
                                            const i = root.pages.findIndex(p => p.slug === navItem.modelData.slug);
                                            return i >= 0 && i === root.currentPage;
                                        }
                                    }

                                    contentItem: RowLayout {
                                        spacing: 12

                                        MaterialSymbol {
                                            Layout.alignment: Qt.AlignVCenter
                                            text: navItem.modelData.icon ?? "settings"
                                            iconSize: Appearance.font.pixelSize.larger
                                            rotation: navItem.modelData.iconRotation ?? 0
                                            color: {
                                                const i = root.pages.findIndex(p => p.slug === navItem.modelData.slug);
                                                return i === root.currentPage
                                                    ? Appearance.colors.colOnSecondaryContainer
                                                    : Appearance.colors.colOnSurfaceVariant;
                                            }
                                        }

                                        StyledText {
                                            Layout.fillWidth: true
                                            elide: Text.ElideRight
                                            font.pixelSize: Appearance.font.pixelSize.small
                                            color: {
                                                const i = root.pages.findIndex(p => p.slug === navItem.modelData.slug);
                                                return i === root.currentPage
                                                    ? Appearance.colors.colOnSecondaryContainer
                                                    : Appearance.colors.colOnLayer0;
                                            }
                                            text: navItem.modelData.name
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // ══ Content ═══════════════════════════════════════════════════════
        Rectangle {
            id: contentPane
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Appearance.rounding.small
            color: CF.ColorUtils.transparentize(Appearance.m3colors.m3surfaceContainerLow, 0.5)

            // Header: the page title and where it lives. Kept outside the
            // page's own scroll area so it stays put while the page scrolls,
            // and so the page always says what it is.
            RowLayout {
                id: pageHeader
                anchors {
                    top: parent.top
                    left: parent.left
                    right: parent.right
                    topMargin: 18
                    leftMargin: 24
                    rightMargin: 24
                }
                spacing: 12

                MaterialSymbol {
                    Layout.alignment: Qt.AlignVCenter
                    text: root.currentPageData?.icon ?? "settings"
                    iconSize: Appearance.font.pixelSize.huge
                    rotation: root.currentPageData?.iconRotation ?? 0
                    color: Appearance.colors.colPrimary
                }

                StyledText {
                    Layout.alignment: Qt.AlignVCenter
                    text: root.currentPageData?.name ?? ""
                    color: Appearance.colors.colOnLayer0
                    font {
                        family: Appearance.font.family.title
                        pixelSize: Appearance.font.pixelSize.huge
                        variableAxes: Appearance.font.variableAxes.title
                    }
                }

                Rectangle {
                    Layout.alignment: Qt.AlignVCenter
                    visible: (root.currentPageData?.group ?? "").length > 0
                    implicitWidth: groupChip.implicitWidth + 16
                    implicitHeight: 22
                    radius: Appearance.rounding.verysmall
                    color: Appearance.colors.colSecondaryContainer

                    StyledText {
                        id: groupChip
                        anchors.centerIn: parent
                        text: root.currentPageData?.group ?? ""
                        color: Appearance.colors.colOnSecondaryContainer
                        font.pixelSize: Appearance.font.pixelSize.smaller
                    }
                }

                Item { Layout.fillWidth: true }

                RippleButton {
                    implicitWidth: 34
                    implicitHeight: 34
                    buttonRadius: Appearance.rounding.full
                    colBackground: "transparent"
                    colBackgroundHover: Appearance.colors.colLayer1Hover
                    onClicked: root.quitApp()
                    contentItem: MaterialSymbol {
                        anchors.centerIn: parent
                        text: "close"
                        iconSize: 20
                        color: Appearance.colors.colOnSurfaceVariant
                    }
                    StyledToolTip {
                        text: Translation.tr("Close settings")
                    }
                }
            }

            Loader {
                id: pageLoader
                anchors {
                    top: pageHeader.bottom
                    left: parent.left
                    right: parent.right
                    bottom: parent.bottom
                    topMargin: 12
                }
                opacity: 1.0
                active: Config.ready
                source: root.pages[root.currentPage]?.component ?? ""

                Component.onCompleted: root.goToPage(SettingsNav.requestedPage)
            }
        }
    }

}
