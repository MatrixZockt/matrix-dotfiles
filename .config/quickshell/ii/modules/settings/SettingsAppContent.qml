// The settings app UI, surface-independent.
//
// The layer-surface popup (settings.qml) and the real desktop window
// (SettingsAppWindow.qml, which the popup morphs into on SUPER+F) host the
// same tree; the host supplies pages/currentPage/quitApp and this file only
// draws. Extracted verbatim from settings.qml -- including its comments.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions as CF

Item {
    id: root

    // Everything the tree below reads from its host.
    property var pages: []
    property int currentPage: 0
    readonly property real contentPadding: 8
    // Popup geometry drives this in the layer app; the window just uses its
    // own width (the rail's expand breakpoint reads it).
    property real cardWidth: width

    signal quitRequested()

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

    // focus: the window host relies on this to get Escape and the page
    // shortcuts; the layer surface delivers keys regardless.
    focus: true

    ColumnLayout {
        anchors {
            fill: parent
            margins: contentPadding
        }

        Keys.onPressed: (event) => {
            // Escape closes the app. It is handled here rather than on the window
            // because anything that deals with Escape itself -- a dialog, a
            // keybind capture -- gets the event first and accepts it, so only an
            // unhandled one gets this far.
            if (event.key === Qt.Key_Escape) {
                root.quitApp();
                event.accepted = true;
                return;
            }
            if (event.modifiers === Qt.ControlModifier) {
                if (event.key === Qt.Key_PageDown) {
                    root.currentPage = Math.min(root.currentPage + 1, root.pages.length - 1)
                    event.accepted = true;
                } 
                else if (event.key === Qt.Key_PageUp) {
                    root.currentPage = Math.max(root.currentPage - 1, 0)
                    event.accepted = true;
                }
                else if (event.key === Qt.Key_Tab) {
                    root.currentPage = (root.currentPage + 1) % root.pages.length;
                    event.accepted = true;
                }
                else if (event.key === Qt.Key_Backtab) {
                    root.currentPage = (root.currentPage - 1 + root.pages.length) % root.pages.length;
                    event.accepted = true;
                }
            }
        }

        Item { // Titlebar
            visible: Config.options?.windows.showTitlebar
            Layout.fillWidth: true
            Layout.fillHeight: false
            implicitHeight: Math.max(titleText.implicitHeight, windowControlsRow.implicitHeight)
            StyledText {
                id: titleText
                anchors {
                    left: Config.options.windows.centerTitle ? undefined : parent.left
                    horizontalCenter: Config.options.windows.centerTitle ? parent.horizontalCenter : undefined
                    verticalCenter: parent.verticalCenter
                    leftMargin: 12
                }
                color: Appearance.colors.colOnLayer0
                text: Translation.tr("Settings")
                font {
                    family: Appearance.font.family.title
                    pixelSize: Appearance.font.pixelSize.title
                    variableAxes: Appearance.font.variableAxes.title
                }
            }
            RowLayout { // Window controls row
                id: windowControlsRow
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                RippleButton {
                    buttonRadius: Appearance.rounding.full
                    implicitWidth: 35
                    implicitHeight: 35
                    onClicked: root.quitApp()
                    contentItem: MaterialSymbol {
                        anchors.centerIn: parent
                        horizontalAlignment: Text.AlignHCenter
                        text: "close"
                        iconSize: 20
                    }
                }
            }
        }

        RowLayout { // Window content with navigation rail and content pane
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: contentPadding
            Item {
                id: navRailWrapper
                Layout.fillHeight: true
                Layout.margins: 5
                // Wide enough for the longest label's full visualWidth
                // (icon 56 + gap 20 + text) plus the scrollbar lane.
                //
                // This was 200, and 200 was never actually reached: see the rail
                // below. It is 240 now so the labels -- the longest is
                // "Appearance" -- sit in the lane with room to spare instead of
                // ending a few pixels from the edge.
                implicitWidth: navRail.expanded ? 240 : fab.baseSize
                Behavior on implicitWidth {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                }
                NavigationRail { // Window content with navigation rail and content pane
                    id: navRail
                    anchors {
                        left: parent.left
                        top: parent.top
                        bottom: parent.bottom
                        // The rail is the WRAPPER's width. Without this anchor it
                        // took its own implicit width -- the widest child's, the
                        // FAB's -- so the flickable inside was ~150px wide while
                        // the wrapper promised 200. Every nav button's highlight
                        // (icon 56 + gap 20 + its label) is wider than that for
                        // any label longer than a few letters, so the pill ran
                        // past the flickable's right edge and `clip: true` sliced
                        // its rounded end off: "the animated background on hover
                        // is cut off" on every category.
                        right: parent.right
                    }
                    spacing: 10
                    expanded: root.cardWidth > 800
                    
                    NavigationRailExpandButton {
                        focus: root.visible
                    }

                    FloatingActionButton {
                        id: fab
                        property bool justCopied: false
                        iconText: justCopied ? "check" : "edit"
                        buttonText: justCopied ? Translation.tr("Path copied") : Translation.tr("Config file")
                        expanded: navRail.expanded
                        downAction: () => {
                            Qt.openUrlExternally(`${Directories.config}/illogical-impulse/config.json`);
                        }
                        altAction: () => {
                            Quickshell.clipboardText = CF.FileUtils.trimFileProtocol(`${Directories.config}/illogical-impulse/config.json`);
                            fab.justCopied = true;
                            revertTextTimer.restart()
                        }

                        Timer {
                            id: revertTextTimer
                            interval: 1500
                            onTriggered: {
                                fab.justCopied = false;
                            }
                        }

                        StyledToolTip {
                            text: Translation.tr("Open the shell config file\nAlternatively right-click to copy path")
                        }
                    }

                    // The page list scrolls.
                    //
                    // Fourteen pages at 56px each is nearly 800px of rail, and
                    // the card is 620 -- on a 940px-tall screen it can never be
                    // taller. A ColumnLayout handed more children than it has
                    // room for does not shrink them, it overflows: the last
                    // pages (Services, Advanced, About) were drawn past the
                    // card's bottom edge, outside the app, and could not be
                    // reached at all. So the list is given the height it
                    // actually has and the rail the height it actually has, and
                    // the difference is a scroll -- the shell's own flickable,
                    // so the wheel and a trackpad flick behave here exactly as
                    // they do in a settings page.
                    StyledFlickable {
                        id: railTabs
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        // Where NavigationRailTabArray used to keep its own top
                        // margin from; a Layout property means nothing to a
                        // flickable, so it lives here now.
                        Layout.topMargin: 25
                        clip: true
                        contentHeight: tabArray.implicitHeight
                        // (No scrollbar lane property exists on a Flickable: an
                        // interactive ScrollBar docks INSIDE the view's right
                        // edge, so keeping the labels clear is done by the tab
                        // array below, which stops 12px short of the edge.)

                        NavigationRailTabArray {
                            id: tabArray
                            // 12px narrower than the flickable: the scrollbar
                            // docks inside the flickable's right edge, and the
                            // rail labels used to end exactly where the thumb
                            // draws -- reading as overlap. This is their lane.
                            width: railTabs.width - 12
                            height: tabArray.implicitHeight
                            currentIndex: root.currentPage
                            expanded: navRail.expanded
                            Repeater {
                                model: root.pages
                                NavigationRailButton {
                                    id: railButton
                                    required property var index
                                    required property var modelData
                                    toggled: root.currentPage === index
                                    onPressed: root.currentPage = index;
                                    expanded: navRail.expanded
                                    buttonIcon: modelData.icon
                                    buttonIconRotation: modelData.iconRotation || 0
                                    buttonText: modelData.name
                                    showToggledHighlight: false

                                    // ══ Collapsed rail: icons only ════════
                                    //
                                    // The collapsed state kept the label BELOW
                                    // the icon, and every rail page is 56px tall
                                    // while the two-line collapsed button needs
                                    // more -- so its text drew past its own
                                    // bottom edge: "labels are cut off when
                                    // minimising the sidebar". Collapsed is now
                                    // icons-only, the label lives in a tooltip,
                                    // and each icon is chosen to carry its page
                                    // alone (a brush for Personalisation, a
                                    // wallpaper for Desktop, a person for
                                    // Accounts...).
                                    Component.onCompleted: {
                                        if (!navRail.expanded)
                                            railButton.buttonText = "";
                                    }
                                    Connections {
                                        target: navRail
                                        function onExpandedChanged() {
                                            railButton.buttonText = navRail.expanded ? railButton.modelData.name : "";
                                        }
                                    }
                                    StyledToolTip {
                                        visible: !navRail.expanded && railButton.hovered
                                        text: railButton.modelData.name
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Rectangle { // Content container
                Layout.fillWidth: true
                Layout.fillHeight: true
                // Translucent like the card it sits in, not opaque: this covers
                // most of the app, so an opaque value here is what hid the blur.
                color: CF.ColorUtils.transparentize(Appearance.m3colors.m3surfaceContainerLow, 0.5)
                radius: Appearance.rounding.small

                // Page header, outside the page's own scroll area, so it stays
                // put while the page scrolls and always says which page you are
                // on -- with the group chip, the rail above stops needing to be
                // read to know where you are.
                RowLayout {
                    id: pageHeader
                    anchors {
                        top: parent.top
                        left: parent.left
                        right: parent.right
                        topMargin: 14
                        leftMargin: 20
                        rightMargin: 20
                    }
                    spacing: 10

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
                        implicitWidth: groupLabel.implicitWidth + 16
                        implicitHeight: 22
                        radius: Appearance.rounding.verysmall
                        color: Appearance.colors.colSecondaryContainer

                        StyledText {
                            id: groupLabel
                            anchors.centerIn: parent
                            text: root.currentPageData?.group ?? ""
                            color: Appearance.colors.colOnSecondaryContainer
                            font.pixelSize: Appearance.font.pixelSize.smaller
                        }
                    }

                    Item { Layout.fillWidth: true }
                }

                Loader {
                    id: pageLoader
                    anchors {
                        top: pageHeader.bottom
                        left: parent.left
                        right: parent.right
                        bottom: parent.bottom
                        topMargin: 8
                    }
                    opacity: 1.0

                    active: Config.ready
                    Component.onCompleted: {
                        // Honour the requested page here too: the animation's
                        // first frame would otherwise flash General before
                        // jumping to the deep-linked page. (There is no
                        // separate "requested page" function: the request is a
                        // slug, and goToPage is what understands slugs.)
                        root.goToPage(SettingsNav.requestedPage);
                        source = root.pages[root.currentPage].component
                    }

                    Connections {
                        target: root
                        function onCurrentPageChanged() {
                            switchAnim.complete();
                            switchAnim.start();
                        }
                    }

                    SequentialAnimation {
                        id: switchAnim

                        NumberAnimation {
                            target: pageLoader
                            properties: "opacity"
                            from: 1
                            to: 0
                            duration: 100
                            easing.type: Appearance.animation.elementMoveExit.type
                            easing.bezierCurve: Appearance.animationCurves.emphasizedFirstHalf
                        }
                        ParallelAnimation {
                            PropertyAction {
                                target: pageLoader
                                property: "source"
                                value: root.pages[root.currentPage].component
                            }
                            PropertyAction {
                                target: pageLoader
                                property: "anchors.topMargin"
                                value: 16
                            }
                        }
                        ParallelAnimation {
                            NumberAnimation {
                                target: pageLoader
                                properties: "opacity"
                                from: 0
                                to: 1
                                duration: 200
                                easing.type: Appearance.animation.elementMoveEnter.type
                                easing.bezierCurve: Appearance.animationCurves.emphasizedLastHalf
                            }
                            NumberAnimation {
                                target: pageLoader
                                properties: "anchors.topMargin"
                                to: 8
                                duration: 200
                                easing.type: Appearance.animation.elementMoveEnter.type
                                easing.bezierCurve: Appearance.animationCurves.emphasizedLastHalf
                            }
                        }
                    }
                }
            }
        }
    }
}
