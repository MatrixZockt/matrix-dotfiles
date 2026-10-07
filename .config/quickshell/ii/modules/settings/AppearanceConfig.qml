import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

/**
 * Everything about how the desktop looks, in one page: the colour scheme, the
 * wallpaper, and the lock screen.
 *
 * These three used to be scattered -- the theme picker on its own page, the
 * wallpaper under Background, the lock screen under Interface -- which meant
 * changing the look of the desktop took three different pages. They are one
 * decision, so they are one page.
 *
 * Every control here is a button, a swatch or a switch. The only paragraphs are
 * the ones that explain a choice you cannot see the effect of until later (the
 * lock layout, which applies at the next lock).
 */
ContentPage {
    id: root
    forceWidth: true

    // ── Colour templates ─────────────────────────────────────────────────
    readonly property string manifestPath: FileUtils.trimFileProtocol(Quickshell.shellPath("themes/templates/manifest.json"))
    readonly property string templatesDir: FileUtils.parentDirectory(root.manifestPath)
    property var templates: []
    readonly property string activeTemplate: Persistent.states.themeTemplate ?? ""
    readonly property bool activeTemplateIsDark: Persistent.states.themeTemplateDark ?? Appearance.m3colors.darkmode

    FileView {
        id: manifestView
        path: root.manifestPath
        watchChanges: true
        onLoaded: root.readManifest()
        onFileChanged: manifestView.reload()
        onLoadFailed: root.templates = []
    }

    function readManifest() {
        try {
            root.templates = (JSON.parse(manifestView.text()).templates) ?? [];
        } catch (error) {
            console.log("[Appearance] Could not read the template manifest:", error);
            root.templates = [];
        }
    }

    function applyTemplate(template, dark) {
        // Delegates to the shared primitive in MaterialThemeLoader, so the
        // settings picker, the right sidebar's quick toggle and the theme
        // shortcut cannot drift apart in what they write or how they reload.
        MaterialThemeLoader.applyTemplatePalette(template, dark);
    }

    function followWallpaper() {
        Persistent.states.themeTemplate = "";
        Quickshell.execDetached([
            Directories.wallpaperSwitchScriptPath,
            "--mode", Appearance.m3colors.darkmode ? "dark" : "light",
            "--noswitch",
        ]);
    }

    // ── Wallpaper ────────────────────────────────────────────────────────
    function wallpaperName(path) {
        if (!path || path.length === 0) return Translation.tr("Not set");
        const parts = String(path).split("/");
        try {
            return decodeURIComponent(parts[parts.length - 1]);
        } catch (error) {
            return parts[parts.length - 1];
        }
    }

    function openWallpaperPicker() {
        Hyprland.dispatch('hl.dsp.global("quickshell:wallpaperSelectorToggle")');
    }

    // ── Configuration paths ──────────────────────────────────────────────
    readonly property string hyprConfigDir: FileUtils.trimFileProtocol(Directories.config) + "/hypr"

    // The lock screen has no layout of its own any more. It is drawn from the
    // LOGIN screen's templates (services/LoginLayouts.qml), so picking a
    // template shapes both screens and there is exactly one list to keep. The
    // hyprlock config and its four layout files -- a second, unrelated design --
    // are archived in ~/.config/hypr/.archive-lock/.
    //
    // Kept as a name (not a stored value) because the wallpaper section's
    // preview tiles still draw "the lock screen" and need something to label it
    // with; it now simply names the template in force.
    readonly property string lockLayout: LoginLayouts.current

    // ── Login screen (SDDM) ────────────────────────────────────────────
    // The login screen is SDDM with this desktop's own theme. Its sources
    // live in ~/.config/hypr/custom/sddm-theme and are installed to
    // /usr/share/sddm/themes/ii by install-sddm-theme.sh, which bakes the
    // wallpaper and palette of the moment into theme.conf. The layout of
    // that theme (what sits where) is chosen here and baked in on the next
    // install -- the login screen itself never reads the shell's config.
    readonly property string loginThemeScript: `${root.hyprConfigDir}/custom/scripts/set-login-layout.sh`
    readonly property string sddmInstallScript: `${root.hyprConfigDir}/custom/scripts/install-sddm-theme.sh`
    readonly property string loginLayoutsDir: `${root.hyprConfigDir}/custom/sddm-theme/layouts`
    readonly property string loginInstallMarker: "/usr/share/sddm/themes/ii/Main.qml"
    property string loginLayout: Persistent.states.loginLayout ?? ""
    property string sddmStatus: ""
    // The template list lives in services/LoginLayouts.qml, because the lock
    // screen is built from the SAME templates as the login screen: the lock is
    // the login design, shown in-session. Adding a fragment to the SDDM theme
    // and an entry to that list adds it to the picker below as well.
    readonly property var loginLayouts: LoginLayouts.list

    function applyLoginLayout(name) {
        Persistent.states.loginLayout = name;
        root.loginLayout = name;
        Quickshell.execDetached(["bash", "-c", `"${root.loginThemeScript}" '${name}'`]);
        root.rebakeLoginTheme();
    }

    // Regenerate the hyprlock config from the shared template state. The lock
    // screen (SUPER+L) runs bare `hyprlock`, and hyprlock.conf is GENERATED --
    // see scripts/lock/generate-hyprlock-conf.sh. Without this call the lock
    // screen only ever learned about layout changes at the next manual
    // regeneration, which is to say never: the wallpaper, palette and layout
    // the settings page was previewing were not what SUPER+L showed.
    //
    // It rides along with the SDDM rebake (both are "the login/lock theme
    // changed"), and the two are independent: the SDDM half needs root and
    // may be cancelled, while this half is a user-level file write that must
    // happen regardless.
    function regenerateHyprlockConf() {
        Quickshell.execDetached(["bash", Quickshell.shellPath("scripts/lock/generate-hyprlock-conf.sh")]);
    }

    function rebakeLoginTheme() {
        // Re-running the installer bakes the CURRENT wallpaper and palette
        // into the installed theme, so the login screen follows the desktop
        // again. It needs root (it writes under /usr/share), so it goes
        // through pkexec -- the same privileged path other settings use.
        root.sddmStatus = Translation.tr("Installing… confirm the password prompt");
        root.regenerateHyprlockConf();
        root.sddmInstallProc.exec(["bash", "-c",
            `"${root.sddmInstallScript}" 2>&1 && echo OK || echo FAILED`]);
    }

    Process {
        id: sddmInstallProc
        stdout: StdioCollector {
            onStreamFinished: {
                const ok = text.trim().endsWith("OK");
                root.sddmStatus = ok
                    ? Translation.tr("Installed — the login screen updates at next boot or logout.")
                    : Translation.tr("Install failed — cancelled or an error occurred.");
            }
        }
    }


    // ── Wallpaper ────────────────────────────────────────────────────────
    // Desktop, lock screen and login screen pictures. First section of
    // the page so the most-visited setting is what you see directly.
    ContentSection {
        icon: "wallpaper"
        title: Translation.tr("Wallpaper")

        // Re-applies the colour theme from the current wallpaper.
        RippleButton {
            Layout.fillWidth: false
            implicitWidth: 180
            implicitHeight: 40
            buttonRadius: Appearance.rounding.small
            colBackground: Appearance.colors.colLayer1Hover
            onClicked: root.followWallpaper()
            contentItem: RowLayout {
                anchors {
                    fill: parent
                    leftMargin: 12
                    rightMargin: 12
                }
                spacing: 8
                MaterialSymbol {
                    Layout.alignment: Qt.AlignVCenter
                    text: "wallpaper"
                    iconSize: Appearance.font.pixelSize.normal
                    color: Appearance.colors.colOnLayer1
                }
                StyledText {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    text: Translation.tr("Colours from wallpaper")
                    color: Appearance.colors.colOnLayer1
                }
            }
            }

        // Reusable card: a thumbnail of one surface's picture plus the
        // actions that make sense for it. Used for the desktop's dark and
        // light slots, the lock screen and the login screen.
        component WallpaperSlotCard: Rectangle {
            id: slotCard

            property string slotPath: ""
            property string slotTitle: ""
            property string slotSubtitle: ""
            property bool clearable: false
            property bool adoptable: false
            signal pickRequested()
            signal adoptRequested()
            signal clearRequested()

            Layout.fillWidth: true
            implicitHeight: slotColumn.implicitHeight + 20
            radius: Appearance.rounding.normal
            color: Appearance.colors.colLayer1
            border.width: 1
            border.color: Appearance.colors.colOutlineVariant

            ColumnLayout {
                id: slotColumn
                anchors {
                    fill: parent
                    margins: 10
                }
                spacing: 8

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 96
                    radius: Appearance.rounding.small
                    color: Appearance.colors.colLayer0
                    clip: true

                    Image {
                        anchors.fill: parent
                        visible: slotCard.slotPath.length > 0
                        source: visible ? Qt.resolvedUrl("file://" + slotCard.slotPath) : ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                    }

                    MaterialSymbol {
                        anchors.centerIn: parent
                        visible: slotCard.slotPath.length === 0
                        text: "wallpaper"
                        iconSize: 28
                        color: Appearance.colors.colOnLayer1Inactive
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: slotCard.pickRequested()
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        StyledText {
                            Layout.fillWidth: true
                            text: slotCard.slotTitle
                            color: Appearance.colors.colOnLayer1
                            font.pixelSize: Appearance.font.pixelSize.small
                            font.weight: Font.Medium
                            elide: Text.ElideRight
                        }
                        StyledText {
                            Layout.fillWidth: true
                            visible: slotCard.slotSubtitle.length > 0
                            text: slotCard.slotSubtitle
                            color: Appearance.colors.colOnLayer1Inactive
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            elide: Text.ElideMiddle
                        }
                    }

                    IconToolbarButton {
                        visible: slotCard.slotPath.length > 0
                        text: "edit"
                        onClicked: slotCard.pickRequested()
                        StyledToolTip { text: Translation.tr("Choose a picture") }
                    }
                    IconToolbarButton {
                        visible: slotCard.adoptable
                        text: "check"
                        onClicked: slotCard.adoptRequested()
                        StyledToolTip { text: Translation.tr("Use the current wallpaper") }
                    }
                    IconToolbarButton {
                        visible: slotCard.clearable && slotCard.slotPath.length > 0
                        text: "close"
                        onClicked: slotCard.clearRequested()
                        StyledToolTip { text: Translation.tr("Follow the desktop wallpaper again") }
                    }
                }
            }
        }

        // Where the next pick lands: desktop, lock screen or login screen.
        // Shown here as well as used by the picker, because picking a lock
        // picture by accident is easy when you cannot see the mode.
        // Wraps instead of overflowing.
        //
        // This row is the widest thing on the page: three 104px chips, their
        // label, and the "Random" button together need more than a narrow
        // window's content column has, so in a RowLayout the tail ran off the
        // right edge and was clipped -- "Random" showed as "Rando" and the
        // button's icon was cut in half. `Flow` re-flows onto as many lines as
        // it needs, so everything stays reachable at any width and the row
        // looks the same as before when there is room for one line.
        Flow {
            id: wallpaperTargetRow
            Layout.fillWidth: true
            spacing: 8

            StyledText {
                text: Translation.tr("Next pick goes to")
                color: Appearance.colors.colOnLayer1Inactive
                font.pixelSize: Appearance.font.pixelSize.smaller
            }

            Repeater {
                model: [
                    { value: "desktop", name: Translation.tr("Desktop"), icon: "desktop_windows" },
                    { value: "lock", name: Translation.tr("Lock screen"), icon: "lock" },
                    { value: "login", name: Translation.tr("Login"), icon: "person" },
                ]
                delegate: RippleButton {
                    id: targetChip
                    required property var modelData
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: 104
                    implicitHeight: 32
                    buttonRadius: Appearance.rounding.small
                    toggled: (Persistent.states.wallpaperTarget ?? "desktop") === targetChip.modelData.value
                    colBackgroundToggled: Appearance.colors.colSecondaryContainer
                    colBackgroundHover: Appearance.colors.colLayer1Hover
                    onClicked: Persistent.states.wallpaperTarget = targetChip.modelData.value
                    contentItem: RowLayout {
                        anchors.centerIn: parent
                        spacing: 6
                        MaterialSymbol {
                            Layout.alignment: Qt.AlignVCenter
                            text: targetChip.modelData.icon
                            iconSize: 15
                            color: targetChip.toggled ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                        }
                        StyledText {
                            Layout.alignment: Qt.AlignVCenter
                            text: targetChip.modelData.name
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: targetChip.toggled ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                        }
                    }
                }
            }

            Item { Layout.fillWidth: true; Layout.preferredWidth: 0; width: 0 }

            IconAndTextToolbarButton {
                iconText: "shuffle"
                text: Translation.tr("Random")
                onClicked: Wallpapers.randomFromCurrentFolder()
            }
        }

        // One wallpaper for both themes, or a dark one and a light one.
        // Off = the two slots below are independent, each applied when its
        // theme is active.
        ConfigSwitch {
            buttonIcon: "brightness_6"
            text: Translation.tr("One wallpaper for dark and light themes")
            checked: !Config.options.background.separateThemeWallpaper
            onCheckedChanged: Config.options.background.separateThemeWallpaper = !checked
        }

        // ── Desktop slots: dark, light, or the single shared one ─────────
        GridLayout {
            Layout.fillWidth: true
            columns: Config.options.background.separateThemeWallpaper ? 2 : 1
            columnSpacing: 8
            rowSpacing: 8

            WallpaperSlotCard {
                id: darkSlot
                visible: Config.options.background.separateThemeWallpaper && Appearance.m3colors.darkmode
                slotTitle: Translation.tr("Dark theme wallpaper")
                slotSubtitle: root.wallpaperName(Config.options.background.wallpaperPathDark || Config.options.background.wallpaperPath)
                slotPath: Config.options.background.wallpaperPathDark || Config.options.background.wallpaperPath
                clearable: false
                adoptable: true
                onPickRequested: {
                    Persistent.states.wallpaperTarget = "desktop";
                    root.openWallpaperPicker();
                }
                onAdoptRequested: Config.options.background.wallpaperPathDark = Config.options.background.wallpaperPath
            }

            WallpaperSlotCard {
                id: lightSlot
                visible: Config.options.background.separateThemeWallpaper && !Appearance.m3colors.darkmode
                slotTitle: Translation.tr("Light theme wallpaper")
                slotSubtitle: root.wallpaperName(Config.options.background.wallpaperPathLight || Config.options.background.wallpaperPath)
                slotPath: Config.options.background.wallpaperPathLight || Config.options.background.wallpaperPath
                clearable: false
                adoptable: true
                onPickRequested: {
                    Persistent.states.wallpaperTarget = "desktop";
                    root.openWallpaperPicker();
                }
                onAdoptRequested: Config.options.background.wallpaperPathLight = Config.options.background.wallpaperPath
            }

            WallpaperSlotCard {
                id: sharedSlot
                visible: !Config.options.background.separateThemeWallpaper
                slotTitle: Translation.tr("Desktop wallpaper")
                slotSubtitle: root.wallpaperName(Config.options.background.wallpaperPath)
                slotPath: Config.options.background.wallpaperPath
                clearable: false
                adoptable: false
                onPickRequested: {
                    Persistent.states.wallpaperTarget = "desktop";
                    root.openWallpaperPicker();
                }
            }

            // The inactive slot stays configurable even while its theme is
            // not the active one: assign it without switching themes first.
            WallpaperSlotCard {
                id: otherSlot
                visible: Config.options.background.separateThemeWallpaper && !Appearance.m3colors.darkmode
                slotTitle: Translation.tr("Dark theme wallpaper")
                slotSubtitle: root.wallpaperName(Config.options.background.wallpaperPathDark || Config.options.background.wallpaperPath)
                slotPath: Config.options.background.wallpaperPathDark || Config.options.background.wallpaperPath
                clearable: false
                adoptable: true
                onPickRequested: {
                    Persistent.states.wallpaperTarget = "desktop";
                    root.openWallpaperPicker();
                }
                onAdoptRequested: Config.options.background.wallpaperPathDark = Config.options.background.wallpaperPath
            }

            WallpaperSlotCard {
                visible: Config.options.background.separateThemeWallpaper && Appearance.m3colors.darkmode
                slotTitle: Translation.tr("Light theme wallpaper")
                slotSubtitle: root.wallpaperName(Config.options.background.wallpaperPathLight || Config.options.background.wallpaperPath)
                slotPath: Config.options.background.wallpaperPathLight || Config.options.background.wallpaperPath
                clearable: false
                adoptable: true
                onPickRequested: {
                    Persistent.states.wallpaperTarget = "desktop";
                    root.openWallpaperPicker();
                }
                onAdoptRequested: Config.options.background.wallpaperPathLight = Config.options.background.wallpaperPath
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: Config.options.background.separateThemeWallpaper
            color: Appearance.colors.colOnLayer1Inactive
            font.pixelSize: Appearance.font.pixelSize.smaller
            wrapMode: Text.Wrap
            text: Translation.tr("Both slots shown: the active theme's card is on top, the other theme's below it.")
        }

        // ── Every wallpaper you have used: the same coverflow the desktop
        //    pill shows ───────────────────────────────────────────────────
        // One component, two places. Standing in Settings, choosing a
        // wallpaper should look and behave exactly like choosing one from the
        // desktop pill: the current picture in the middle, its neighbours
        // stacked either side with their reflections, click a card to apply
        // it, the add tile at the end to bring in a new image.
        ContentSubsection {
            title: Translation.tr("Wallpapers")

            Rectangle {
                id: carouselCard
                Layout.fillWidth: true
                // The carousel reports its size UP into these rather than the
                // card reaching down to it: a binding on an ancestor that
                // references a descendant id is evaluated while the tree is
                // still being built, before that id exists, and throws
                // "pickerCarousel is not defined".
                property real contentW: 0
                property real contentH: 0
                // The carousel is wider than a narrow settings pane; scale it
                // down rather than let it spill out of the card.
                readonly property real fit: contentW > 0
                    ? Math.min(1, (width - 24) / contentW)
                    : 1
                implicitHeight: (contentH > 0 ? contentH : 300) + 32
                radius: Appearance.rounding.normal
                color: Appearance.colors.colLayer0
                border.width: 1
                border.color: Appearance.colors.colOutlineVariant
                clip: true

                WallpaperCarousel {
                    id: pickerCarousel
                    anchors.centerIn: parent
                    scale: carouselCard.fit
                    onImplicitWidthChanged: carouselCard.contentW = implicitWidth
                    onImplicitHeightChanged: carouselCard.contentH = implicitHeight
                    Component.onCompleted: {
                        carouselCard.contentW = implicitWidth;
                        carouselCard.contentH = implicitHeight;
                    }
                    items: WallpaperHistory.images
                    currentPath: WallpaperHistory.currentWallpaper
                    allowRemove: true
                    keyboardEnabled: true
                    backdrop: carouselCard.color
                    autoSwitchEnabled: Config.options.background.autoSwitch.enable
                    autoSwitchIntervalS: Config.options.background.autoSwitch.intervalS
                    onAutoSwitched: path => Wallpapers.apply(String(path))
                    onActivated: path => Wallpapers.apply(String(path))
                    onAddRequested: root.openWallpaperPicker()
                    onRemoveRequested: path => {
                        pickerRemove.mp = String(path);
                        pickerRemove.restart();
                    }

                    // Let the tile's exit animation finish before the entry
                    // disappears out of the model.
                    Timer {
                        id: pickerRemove
                        property string mp: ""
                        interval: 160
                        onTriggered: WallpaperHistory.remove(pickerRemove.mp)
                    }
                }
            }

            StyledText {
                Layout.fillWidth: true
                color: Appearance.colors.colOnLayer1Inactive
                font.pixelSize: Appearance.font.pixelSize.smaller
                wrapMode: Text.Wrap
                text: Translation.tr("Click a picture to apply it. The current wallpaper is the large card in the middle; use the + tile to add a new image.")
            }

            // ── Auto-switch: the carousel turns itself ──────────────────
            // A switch plus a custom-interval slider, persisted in the shell
            // config; the running timer lives in the carousel component and
            // binds to these same keys, so the preview in this page rotates
            // with the desktop.
            ConfigSwitch {
                Layout.fillWidth: true
                buttonIcon: "autorenew"
                text: Translation.tr("Switch wallpaper automatically")
                checked: Config.options.background.autoSwitch.enable
                onCheckedChanged: Config.options.background.autoSwitch.enable = checked
                StyledToolTip {
                    text: Translation.tr("Every interval the next wallpaper in the carousel is applied, wrapping around. Turning the ring by hand pauses nothing: the timer never fights you mid-gesture.")
                }
            }
            ConfigSlider {
                Layout.fillWidth: true
                visible: Config.options.background.autoSwitch.enable
                buttonIcon: "timer"
                text: Translation.tr("Every %1 min").arg((Config.options.background.autoSwitch.intervalS / 60).toLocaleString(Qt.locale(), "f", 1))
                from: 0.5
                to: 120
                value: Config.options.background.autoSwitch.intervalS / 60
                onValueChanged: Config.options.background.autoSwitch.intervalS = Math.round(value * 2) / 2
                StyledToolTip {
                    text: Translation.tr("Minutes between automatic wallpaper changes, 0.5 to 120.")
                }
            }
        }

        // ── Lock screen and login screen pictures ────────────────────────
        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: 8
            rowSpacing: 8

            WallpaperSlotCard {
                id: lockSlot
                slotTitle: Translation.tr("Lock screen picture")
                slotSubtitle: root.lockWallpaperPath.length > 0 ? root.wallpaperName(root.lockWallpaperPath) : Translation.tr("Follows the desktop wallpaper")
                slotPath: root.lockWallpaperPath.length > 0 ? root.lockWallpaperPath : Config.options.background.wallpaperPath
                clearable: true
                adoptable: false
                onPickRequested: {
                    Persistent.states.wallpaperTarget = "lock";
                    root.openWallpaperPicker();
                }
                onClearRequested: root.clearLockWallpaper()
            }

            WallpaperSlotCard {
                id: loginSlot
                slotTitle: Translation.tr("Login picture")
                slotSubtitle: Config.options.background.wallpaperPathLogin.length > 0
                    ? root.wallpaperName(Config.options.background.wallpaperPathLogin)
                    : Translation.tr("Not set — the desktop picture is used")
                slotPath: Config.options.background.wallpaperPathLogin.length > 0
                    ? Config.options.background.wallpaperPathLogin
                    : Config.options.background.wallpaperPath
                clearable: true
                adoptable: false
                onPickRequested: {
                    Persistent.states.wallpaperTarget = "login";
                    root.openWallpaperPicker();
                }
                onClearRequested: Config.options.background.wallpaperPathLogin = ""
            }
        }

        // ── Previews: the actual screens, with the actual picture and the
        //    actual layout arrangement ────────────────────────────────────
        ContentSubsection {
            title: Translation.tr("Previews")

            GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: 8
                rowSpacing: 8

                // The lock screen: its own picture (or the desktop's), the
                // chosen layout's arrangement drawn to scale.
                Rectangle {
                    id: lockPreview
                    Layout.fillWidth: true
                    implicitHeight: 140
                    radius: Appearance.rounding.normal
                    color: Appearance.colors.colLayer0
                    clip: true
                    border.width: 1
                    border.color: Appearance.colors.colOutlineVariant

                    Image {
                        anchors.fill: parent
                        source: Qt.resolvedUrl("file://" + (root.lockWallpaperPath.length > 0 ? root.lockWallpaperPath : Config.options.background.wallpaperPath))
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                    }

                    Rectangle {
                        anchors.fill: parent
                        color: Qt.rgba(0, 0, 0, 0.35)
                    }

                    // The layout, drawn from the REAL template fields
                    // (services/LoginLayouts.qml) rather than from slugs this
                    // file invented. The preview used to test for "poster" and
                    // "quiet" -- two slugs no template has (the real ones are
                    // classic / corner / minimal / glass / studio / beacon /
                    // ops) -- so every layout rendered the same generic
                    // arrangement and the picker looked like it did nothing.
                    //
                    // Scaled to the tile: `t` maps the lock screen's height to
                    // the preview's, so offsets written as fractions of screen
                    // height land in the same place a proportionally.
                    Rectangle {
                        readonly property var tpl: LoginLayouts.active
                        readonly property real t: lockPreview.height / 1000
                        readonly property bool leftAligned: (tpl?.align ?? "center") === "left"

                        anchors.top: parent.top
                        anchors.topMargin: (tpl?.clock ?? true)
                            ? Math.max(10, (0.06 + (tpl?.offset ?? 0.04)) * lockPreview.height * 0.4)
                            : lockPreview.height * 0.42
                        anchors.horizontalCenter: leftAligned ? undefined : parent.horizontalCenter
                        anchors.left: leftAligned ? parent.left : undefined
                        anchors.leftMargin: leftAligned ? 14 : 0

                        width: Math.max(46, (tpl?.clock ?? true) ? 120 * (tpl?.clockScale ?? 1.0) * t * 4 : 40)
                        height: 9
                        radius: 4
                        // A template without a clock draws nothing here; the
                        // bar below IS the layout's mark.
                        opacity: (tpl?.clock ?? true) ? 1 : 0
                        color: Qt.rgba(1, 1, 1, 0.92)
                    }
                    Rectangle {
                        visible: (LoginLayouts.active?.card ?? false)
                        anchors.horizontalCenter: (LoginLayouts.active?.align ?? "center") === "left"
                            ? undefined : parent.horizontalCenter
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: lockPreview.height * (LoginLayouts.offset ?? 0.04)
                        anchors.left: (LoginLayouts.active?.align ?? "center") === "left" ? parent.left : undefined
                        anchors.leftMargin: 8
                        width: (LoginLayouts.active?.align ?? "center") === "left" ? lockPreview.width * 0.55 : lockPreview.width - 16
                        height: lockPreview.height * 0.45
                        radius: Appearance.rounding.normal
                        color: Qt.rgba(1, 1, 1, 0.10)
                        border.width: 1
                        border.color: Qt.rgba(1, 1, 1, 0.22)
                    }
                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 14
                        width: 76
                        height: 7
                        radius: 3.5
                        color: Qt.rgba(1, 1, 1, 0.65)
                        border.width: 1
                        border.color: Qt.rgba(1, 1, 1, 0.35)
                    }

                    Rectangle {
                        anchors {
                            left: parent.left
                            bottom: parent.bottom
                            margins: 6
                        }
                        radius: Appearance.rounding.verysmall
                        color: Qt.rgba(0, 0, 0, 0.45)
                        implicitWidth: lockPreviewLabel.implicitWidth + 12
                        implicitHeight: lockPreviewLabel.implicitHeight + 6

                        StyledText {
                            id: lockPreviewLabel
                            anchors.centerIn: parent
                            text: Translation.tr("Lock · %1").arg(root.lockLayout)
                            color: Qt.rgba(1, 1, 1, 0.9)
                            font.pixelSize: Appearance.font.pixelSize.smaller
                        }
                    }
                }

                // The login screen: the current wallpaper (what the next
                // Reinstall bakes) and the chosen login layout's arrangement.
                Rectangle {
                    id: loginPreview
                    Layout.fillWidth: true
                    implicitHeight: 140
                    radius: Appearance.rounding.normal
                    color: Appearance.colors.colLayer0
                    clip: true
                    border.width: 1
                    border.color: Appearance.colors.colOutlineVariant

                    Image {
                        anchors.fill: parent
                        source: Qt.resolvedUrl("file://" + (Config.options.background.wallpaperPathLogin.length > 0 ? Config.options.background.wallpaperPathLogin : Config.options.background.wallpaperPath))
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                    }

                    Rectangle {
                        anchors.fill: parent
                        color: Qt.rgba(0, 0, 0, 0.30)
                    }

                    // Clock, when this login layout shows one.
                    Rectangle {
                        visible: root.loginClockVisible
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        anchors.topMargin: 10
                        width: 52
                        height: 8
                        radius: 4
                        color: Qt.rgba(1, 1, 1, 0.92)
                    }
                    Rectangle {
                        visible: root.loginClockVisible
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        anchors.topMargin: 22
                        width: 34
                        height: 4
                        radius: 2
                        color: Qt.rgba(1, 1, 1, 0.55)
                    }

                    // The login column: avatar, name, password line, placed
                    // by the layout's vertical offset.
                    Column {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: parent.height * root.loginVerticalOffset
                        spacing: 5

                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 18
                            height: 18
                            radius: 9
                            color: Qt.rgba(1, 1, 1, 0.30)
                            border.width: 1
                            border.color: Qt.rgba(1, 1, 1, 0.55)
                        }
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 40
                            height: 5
                            radius: 2.5
                            color: Qt.rgba(1, 1, 1, 0.80)
                        }
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 64
                            height: 6
                            radius: 3
                            color: "transparent"
                            border.width: 1
                            border.color: Qt.rgba(1, 1, 1, 0.70)
                        }
                    }

                    Rectangle {
                        anchors {
                            left: parent.left
                            bottom: parent.bottom
                            margins: 6
                        }
                        radius: Appearance.rounding.verysmall
                        color: Qt.rgba(0, 0, 0, 0.45)
                        implicitWidth: loginPreviewLabel.implicitWidth + 12
                        implicitHeight: loginPreviewLabel.implicitHeight + 6

                        StyledText {
                            id: loginPreviewLabel
                            anchors.centerIn: parent
                            text: Translation.tr("Login · %1").arg(root.loginLayout)
                            color: Qt.rgba(1, 1, 1, 0.9)
                            font.pixelSize: Appearance.font.pixelSize.smaller
                        }
                    }
                }
            }
        }

    }

    // ── Performance ──────────────────────────────────────────────────────
    // The look-preserving speed switch. Nothing about the desktop changes:
    // the same theme, the same layout, the same popups, the same gestures --
    // only the motion budget goes away (Hyprland's animations off, and the
    // desktop's hand-played transitions cut straight to the end instead of
    // running a dispatch per frame). Use it on a slow machine, while gaming,
    // or when the interface feels heavy under load.
    //
    // This is the same switch as the right sidebar's button and its top-bar
    // icon: all three go through services/PerformanceMode.qml, which owns the
    // config value and the script that applies it.
    ContentSection {
        icon: "speed"
        title: Translation.tr("Performance")

        ConfigSwitch {
            buttonIcon: "speed"
            text: Translation.tr("Performance mode — fewer animations, snappier interface")
            checked: PerformanceMode.enabled
            onCheckedChanged: {
                PerformanceMode.setEnabled(checked);
            }
        }
    }

    // ── Theme ────────────────────────────────────────────────────────────
    ContentSection {
        icon: "palette"
        title: Translation.tr("Theme")

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            ConfigSwitch {
                buttonIcon: "dark_mode"
                text: Translation.tr("Dark mode")
                checked: Appearance.m3colors.darkmode
                onClicked: MaterialThemeLoader.toggleLightDark()
            }

        }

        GridLayout {
            Layout.fillWidth: true
            Layout.topMargin: 4
            columns: 2
            columnSpacing: 8
            rowSpacing: 8

            Repeater {
                model: ScriptModel {
                    values: root.templates
                    objectProp: "slug"
                }
                delegate: Rectangle {
                    id: templateCard
                    required property var modelData

                    Layout.fillWidth: true
                    implicitHeight: cardColumn.implicitHeight + 20
                    radius: Appearance.rounding.small
                    color: Appearance.colors.colLayer1
                    border.width: root.activeTemplate === templateCard.modelData.slug ? 2 : 1
                    border.color: root.activeTemplate === templateCard.modelData.slug
                        ? Appearance.colors.colPrimary
                        : Appearance.colors.colOutlineVariant

                    FileView {
                        id: paletteView
                        path: `${root.templatesDir}/${templateCard.modelData.palettes.dark}`
                        blockLoading: true
                        onLoaded: templateCard.swatches = templateCard.parse()
                    }
                    // Not `palette`: QQuickItem already has one, and the name
                    // would be an override that never receives the colours.
                    property var swatches: null
                    function parse() {
                        try {
                            const parsed = JSON.parse(paletteView.text());
                            return [
                                parsed.primary,
                                parsed.secondary,
                                parsed.tertiary,
                                parsed.surfaceContainer,
                                parsed.surface,
                            ];
                        } catch (error) {
                            return null;
                        }
                    }

                    ColumnLayout {
                        id: cardColumn
                        anchors {
                            fill: parent
                            margins: 10
                        }
                        spacing: 6

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 3

                            Repeater {
                                model: templateCard.swatches ?? [
                                    Appearance.colors.colPrimary,
                                    Appearance.colors.colSecondary,
                                    Appearance.colors.colTertiary,
                                    Appearance.colors.colLayer1Hover,
                                    Appearance.colors.colLayer0,
                                ]
                                delegate: Rectangle {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    implicitHeight: 22
                                    radius: Appearance.rounding.verysmall
                                    color: modelData
                                    border.width: 1
                                    border.color: ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.5)
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            StyledText {
                                Layout.fillWidth: true
                                text: templateCard.modelData.name
                                color: Appearance.colors.colOnLayer1
                                font.weight: Font.Medium
                                elide: Text.ElideRight
                            }

                            // Two small buttons instead of two lines of text.
                            RippleButton {
                                implicitWidth: 30
                                implicitHeight: 26
                                buttonRadius: Appearance.rounding.verysmall
                                toggled: root.activeTemplate === templateCard.modelData.slug && root.activeTemplateIsDark
                                colBackgroundToggled: Appearance.colors.colPrimary
                                onClicked: root.applyTemplate(templateCard.modelData, true)
                                contentItem: MaterialSymbol {
                                    anchors.centerIn: parent
                                    text: "dark_mode"
                                    iconSize: 16
                                    color: parent.parent.toggled ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer1
                                }
                                StyledToolTip {
                                    text: Translation.tr("Apply the dark palette")
                                }
                            }

                            RippleButton {
                                implicitWidth: 30
                                implicitHeight: 26
                                buttonRadius: Appearance.rounding.verysmall
                                toggled: root.activeTemplate === templateCard.modelData.slug && !root.activeTemplateIsDark
                                colBackgroundToggled: Appearance.colors.colPrimary
                                onClicked: root.applyTemplate(templateCard.modelData, false)
                                contentItem: MaterialSymbol {
                                    anchors.centerIn: parent
                                    text: "light_mode"
                                    iconSize: 16
                                    color: parent.parent.toggled ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer1
                                }
                                StyledToolTip {
                                    text: Translation.tr("Apply the light palette")
                                }
                            }
                        }
                    }
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: root.templates.length === 0
            color: Appearance.colors.colOnLayer1Inactive
            text: Translation.tr("No templates found in themes/templates.")
        }

        // ── Style templates ──────────────────────────────────────────────
        // Not recolours: each one reshapes the shell -- corner rounding, bar
        // geometry, panel treatment -- through the shared Appearance values
        // every widget already reads. No behaviour changes, and no Hyprland
        // configuration is touched in any way.
        ContentSubsection {
            title: Translation.tr("Style")

            StyledText {
                Layout.fillWidth: true
                color: Appearance.colors.colOnLayer1Inactive
                font.pixelSize: Appearance.font.pixelSize.smaller
                wrapMode: Text.Wrap
                text: Translation.tr("Changes the shape of the interface — corners, bars and cards. Features and behaviour are never touched.")
            }

            GridLayout {
                Layout.fillWidth: true
                Layout.topMargin: 4
                columns: 2
                columnSpacing: 8
                rowSpacing: 8

                Repeater {
                    model: Appearance.styles
                    delegate: RippleButton {
                        id: styleCard
                        required property var modelData
                        readonly property bool active: Appearance.styleSlug === modelData.slug

                        Layout.fillWidth: true
                        implicitHeight: styleColumn.implicitHeight + 20
                        buttonRadius: Appearance.rounding.small
                        toggled: styleCard.active
                        colBackgroundToggled: Appearance.colors.colSecondaryContainer
                        colBackgroundHover: Appearance.colors.colLayer1Hover
                        onClicked: Config.options.appearance.styleTemplate = modelData.slug

                        contentItem: ColumnLayout {
                            id: styleColumn
                            anchors {
                                fill: parent
                                margins: 10
                            }
                            spacing: 8

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8

                                Row {
                                    spacing: 3
                                    Repeater {
                                        model: styleCard.modelData.swatch
                                        delegate: Rectangle {
                                            required property var modelData
                                            width: 14
                                            height: 14
                                            radius: 3
                                            color: modelData
                                        }
                                    }
                                }

                                StyledText {
                                    Layout.fillWidth: true
                                    text: styleCard.modelData.name
                                    color: styleCard.active ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                                    font.weight: Font.Medium
                                    elide: Text.ElideRight
                                }

                                MaterialSymbol {
                                    text: styleCard.active ? "check_circle" : ""
                                    iconSize: 18
                                    visible: styleCard.active
                                    color: Appearance.colors.colOnSecondaryContainer
                                }
                                // Inactive marker: a plain ring, drawn -- no
                                // dependency on a glyph existing in the font.
                                Rectangle {
                                    visible: !styleCard.active
                                    width: 16
                                    height: 16
                                    radius: 8
                                    color: "transparent"
                                    border.width: 2
                                    border.color: Appearance.colors.colOnLayer1Inactive
                                }
                            }

                            // Mini preview: two shape ghosts drawn with the
                            // template's own rounding, so the corner language
                            // is visible before choosing it.
                            Item {
                                Layout.fillWidth: true
                                implicitHeight: 34
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: parent.left
                                    width: parent.width * 0.62
                                    height: 14
                                    radius: Math.min(styleCard.modelData.shape.normal ?? 8, 7)
                                    color: styleCard.active ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                                    opacity: styleCard.active ? 0.25 : 0.55
                                }
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.right: parent.right
                                    width: 30
                                    height: 26
                                    radius: Math.min(styleCard.modelData.shape.large ?? 10, 13)
                                    color: styleCard.active ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                                    opacity: styleCard.active ? 0.4 : 0.8
                                }
                            }

                            StyledText {
                                Layout.fillWidth: true
                                text: styleCard.modelData.description
                                color: styleCard.active ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1Inactive
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                wrapMode: Text.Wrap
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Lock screen wallpaper ────────────────────────────────────────────
    // The lock screen's own picture lives in hyprlock/lock-wallpaper.conf
    // as a $background_image assignment; an empty or missing file means
    // "follow the desktop wallpaper". Read here for the settings preview
    // and cards; written through set-lock-wallpaper.sh, the same script
    // the wallpaper picker uses, so both paths stay in agreement.
    readonly property string lockWallpaperScript: `${FileUtils.trimFileProtocol(Directories.scriptPath)}/colors/set-lock-wallpaper.sh`
    property string lockWallpaperPath: ""

    function readLockWallpaper() {
        const match = lockWallpaperFile.text().match(/^\$background_image\s*=\s*(.+)$/m);
        root.lockWallpaperPath = match ? match[1].trim() : "";
    }

    FileView {
        id: lockWallpaperFile
        path: `${root.hyprConfigDir}/hyprlock/lock-wallpaper.conf`
        watchChanges: true
        onLoaded: root.readLockWallpaper()
        onFileChanged: lockWallpaperFile.reload()
        onLoadFailed: root.lockWallpaperPath = ""
    }

    function applyLockWallpaper(path) {
        Quickshell.execDetached(["bash", "-c", `"${root.lockWallpaperScript}" '${path}'`]);
        // hyprlock.conf bakes the wallpaper path in at generation time, so a
        // new lock picture needs a regeneration to reach the lock screen.
        root.regenerateHyprlockConf();
        lockWallpaperReloadTimer.restart();
    }

    function clearLockWallpaper() {
        Quickshell.execDetached(["bash", "-c", `"${root.lockWallpaperScript}" --clear`]);
        root.regenerateHyprlockConf();
        lockWallpaperReloadTimer.restart();
    }

    Timer {
        id: lockWallpaperReloadTimer
        interval: 900
        onTriggered: lockWallpaperFile.reload()
    }

    // ── Login layout values for the preview ─────────────────────────────
    // The composed login layout fragment (sddm-theme/layouts/active.js) is
    // plain JS with three variables. Parse it so the preview reflects the
    // real arrangement; defaults mirror the shipped classic look.
    property string loginAlign: "center"
    property real loginVerticalOffset: 0.04
    property bool loginClockVisible: true

    function readLoginLayout() {
        const text = activeLoginLayoutFile.text();
        const alignMatch = text.match(/^var\s+align\s*=\s*"(\w+)"/m);
        if (alignMatch)
            root.loginAlign = alignMatch[1];
        const offsetMatch = text.match(/^var\s+verticalOffset\s*=\s*(-?[\d.]+)/m);
        if (offsetMatch)
            root.loginVerticalOffset = Math.max(-0.3, Math.min(0.4, parseFloat(offsetMatch[1])));
        const clockMatch = text.match(/^var\s+clockVisible\s*=\s*(true|false)/m);
        if (clockMatch)
            root.loginClockVisible = clockMatch[1] === "true";
    }

    FileView {
        id: activeLoginLayoutFile
        path: `${root.hyprConfigDir}/custom/sddm-theme/layouts/active.js`
        watchChanges: true
        onLoaded: root.readLoginLayout()
        onFileChanged: activeLoginLayoutFile.reload()
        onLoadFailed: root.readLoginLayout()
    }



    // ── Login screen ────────────────────────────────────────────────────
    // The boot/login screen: SDDM with this desktop's theme. Layout and
    // colours live here; the lock screen (SUPER+L) is a different system,
    // configured in its own section below.
    ContentSection {
        icon: "person"
        title: Translation.tr("Login")

        ContentSubsection {
            title: Translation.tr("Layout")

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Repeater {
                    model: root.loginLayouts
                    delegate: RippleButton {
                        id: loginChoice
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: 40
                        buttonRadius: Appearance.rounding.small
                        toggled: root.loginLayout === loginChoice.modelData.value
                        colBackgroundToggled: Appearance.colors.colSecondaryContainer
                        colBackgroundHover: Appearance.colors.colLayer1Hover
                        onClicked: root.applyLoginLayout(loginChoice.modelData.value)
                        contentItem: RowLayout {
                            anchors.centerIn: parent
                            spacing: 6
                            MaterialSymbol {
                                Layout.alignment: Qt.AlignVCenter
                                text: loginChoice.modelData.icon
                                iconSize: 18
                                color: loginChoice.toggled ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                            }
                            StyledText {
                                Layout.alignment: Qt.AlignVCenter
                                text: loginChoice.modelData.name
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: loginChoice.toggled ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                            }
                        }
                    }
                }
            }

            StyledText {
                Layout.fillWidth: true
                color: Appearance.colors.colOnLayer1Inactive
                font.pixelSize: Appearance.font.pixelSize.smaller
                wrapMode: Text.Wrap
                text: Translation.tr("Re-bakes the login theme with the current wallpaper and colours. Applies at the next login screen.")
            }
        }

        ContentSubsection {
            title: Translation.tr("Theme source")

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                RippleButton {
                    implicitHeight: 36
                    buttonRadius: Appearance.rounding.small
                    colBackground: Appearance.colors.colLayer1Hover
                    onClicked: root.rebakeLoginTheme()
                    contentItem: RowLayout {
                        anchors.centerIn: parent
                        spacing: 6
                        MaterialSymbol {
                            Layout.alignment: Qt.AlignVCenter
                            text: "download"
                            iconSize: 17
                            color: Appearance.colors.colOnLayer1
                        }
                        StyledText {
                            Layout.alignment: Qt.AlignVCenter
                            text: Translation.tr("Reinstall with current wallpaper & colours")
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: Appearance.colors.colOnLayer1
                        }
                    }
                }

                IconToolbarButton {
                    text: "refresh"
                    onClicked: root.rebakeLoginTheme()
                    StyledToolTip { text: Translation.tr("Same thing: re-bake from the live wallpaper and palette") }
                }
            }

            StyledText {
                Layout.fillWidth: true
                visible: root.sddmStatus.length > 0
                color: Appearance.colors.colOnLayer1
                font.pixelSize: Appearance.font.pixelSize.smaller
                elide: Text.ElideRight
                text: root.sddmStatus
            }
        }
    }

    // ── Lock screen ──────────────────────────────────────────────────────
    // What shows when the session itself is locked (SUPER+L). The lock IS the
    // login now -- these are the LOGIN section's templates, drawn by this shell
    // instead of handed to a separate hyprlock process, which is why picking
    // one here also picks it for the login screen. What is left that is only
    // about locking is behaviour and security, below; the lock screen's
    // picture is chosen with the wallpaper button.
    ContentSection {
        icon: "lock"
        title: Translation.tr("Lock screen")

        // Layout: the LOGIN templates. Shared with the Login section on
        // purpose -- there is one screen, so there is one choice, and both
        // pickers show the same selected tile.
        GridLayout {
            Layout.fillWidth: true
            columns: 3
            columnSpacing: 8
            rowSpacing: 8

            Repeater {
                model: root.loginLayouts
                delegate: RippleButton {
                    id: layoutChoice
                    required property var modelData
                    Layout.fillWidth: true
                    implicitHeight: lockPreviewColumn.implicitHeight + 16
                    buttonRadius: Appearance.rounding.small
                    toggled: root.loginLayout === layoutChoice.modelData.value
                    colBackgroundToggled: Appearance.colors.colSecondaryContainer
                    colBackgroundHover: Appearance.colors.colLayer1Hover
                    onClicked: root.applyLoginLayout(layoutChoice.modelData.value)
                    contentItem: ColumnLayout {
                        id: lockPreviewColumn
                        anchors {
                            fill: parent
                            margins: 8
                        }
                        spacing: 6

                        // Miniature of the layout: wallpaper-ish ground, then
                        // the clock and password line placed the way the real
                        // Miniature of THIS template, from the same fields
                        // the real lock uses (LoginLayouts.list entries -- the
                        // model here IS that list). Used to test for "poster"
                        // and "quiet", two slugs no template ever had, so all
                        // seven tiles drew the same picture.
                        //
                        // Each template entry is reachable directly through
                        // modelData: align/offset/clock/card/clockScale/hud.
                        Rectangle {
                            id: miniTile
                            Layout.fillWidth: true
                            implicitHeight: 74
                            radius: Appearance.rounding.verysmall
                            color: ColorUtils.transparentize(Appearance.colors.colLayer0, 0.35)
                            clip: true

                            readonly property var tpl: layoutChoice.modelData
                            readonly property bool leftAligned: (tpl?.align ?? "center") === "left"
                            readonly property bool hasClock: tpl?.clock ?? true

                            // clock block: present only when the template draws
                            // one, offset scaled from the template's fraction.
                            Rectangle {
                                visible: miniTile.hasClock
                                anchors.horizontalCenter: miniTile.leftAligned ? undefined : parent.horizontalCenter
                                anchors.left: miniTile.leftAligned ? parent.left : undefined
                                anchors.leftMargin: miniTile.leftAligned ? 8 : 0
                                anchors.top: parent.top
                                anchors.topMargin: Math.max(6, miniTile.height * ((miniTile.tpl?.offset ?? 0.04) * 0.6))
                                width: miniTile.hasClock ? 34 : 0
                                height: 5
                                radius: 2
                                color: layoutChoice.toggled ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                                opacity: 0.9
                            }
                            // date line, just under the clock, same visibility
                            // rule as the clock itself.
                            Rectangle {
                                visible: miniTile.hasClock
                                anchors.horizontalCenter: miniTile.leftAligned ? undefined : parent.horizontalCenter
                                anchors.left: miniTile.leftAligned ? parent.left : undefined
                                anchors.leftMargin: miniTile.leftAligned ? 8 : 0
                                anchors.top: parent.top
                                anchors.topMargin: Math.max(14, miniTile.height * ((miniTile.tpl?.offset ?? 0.04) * 0.6) + 8)
                                width: 22
                                height: 3
                                radius: 1.5
                                color: layoutChoice.toggled ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                                opacity: 0.5
                            }
                            // frosted panel, when the template has one
                            Rectangle {
                                visible: miniTile.tpl?.card ?? false
                                anchors.horizontalCenter: miniTile.leftAligned ? undefined : parent.horizontalCenter
                                anchors.left: miniTile.leftAligned ? parent.left : undefined
                                anchors.leftMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                width: miniTile.leftAligned ? parent.width * 0.55 : parent.width - 12
                                height: parent.height * 0.5
                                radius: 3
                                color: layoutChoice.toggled
                                    ? Appearance.colors.colOnSecondaryContainer
                                    : Appearance.colors.colOnLayer1
                                opacity: 0.12
                            }
                            // password field
                            Rectangle {
                                anchors.horizontalCenter: miniTile.leftAligned ? undefined : parent.horizontalCenter
                                anchors.left: miniTile.leftAligned ? parent.left : undefined
                                anchors.leftMargin: miniTile.leftAligned ? 10 : 0
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: 12
                                width: 40
                                height: 6
                                radius: 3
                                color: layoutChoice.toggled ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOutlineVariant
                            }
                        }

                        Item {
                            Layout.fillWidth: true
                            implicitHeight: nameRow.implicitHeight

                            RowLayout {
                                id: nameRow
                                anchors.centerIn: parent
                                spacing: 4
                                MaterialSymbol {
                                    Layout.alignment: Qt.AlignVCenter
                                    text: layoutChoice.modelData.icon
                                    iconSize: 14
                                    color: layoutChoice.toggled ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                                }
                                StyledText {
                                    Layout.alignment: Qt.AlignVCenter
                                    text: layoutChoice.modelData.name
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                    color: layoutChoice.toggled ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                                }
                            }
                        }
                    }
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            color: Appearance.colors.colOnLayer1Inactive
            font.pixelSize: Appearance.font.pixelSize.smaller
            wrapMode: Text.Wrap
            text: Translation.tr("Applies the next time you lock the screen (SUPER+L).")
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            IconToolbarButton {
                text: "wallpaper"
                onClicked: {
                    Persistent.states.wallpaperTarget = "lock";
                    root.openWallpaperPicker();
                }
                StyledToolTip { text: Translation.tr("Pick the lock screen's picture") }
            }

            StyledText {
                Layout.fillWidth: true
                text: Translation.tr("The lock screen can show a different picture from the desktop.")
                color: Appearance.colors.colOnLayer1Inactive
                font.pixelSize: Appearance.font.pixelSize.smaller
                elide: Text.ElideRight
            }
        }

        ContentSubsection {
            title: Translation.tr("Behaviour")

            ConfigSwitch {
                buttonIcon: "account_circle"
                text: Translation.tr("Launch the shell on startup")
                checked: Config.options.lock.launchOnStartup
                onCheckedChanged: Config.options.lock.launchOnStartup = checked
            }
        }

        ContentSubsection {
            title: Translation.tr("Security")

            ConfigSwitch {
                buttonIcon: "settings_power"
                text: Translation.tr("Require password to power off or restart")
                checked: Config.options.lock.security.requirePasswordToPower
                onCheckedChanged: Config.options.lock.security.requirePasswordToPower = checked
            }

            ConfigSwitch {
                buttonIcon: "key_vertical"
                text: Translation.tr("Also unlock the keyring")
                checked: Config.options.lock.security.unlockKeyring
                onCheckedChanged: Config.options.lock.security.unlockKeyring = checked
            }
        }
    }
}

