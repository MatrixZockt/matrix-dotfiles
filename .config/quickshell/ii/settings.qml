//@ pragma UseQApplication
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import "modules/settings" as SettingsUI
import "modules/taskmanager" as TaskManagerUI
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions as CF

// The settings app -- a NORMAL desktop window.
//
// It used to be a full-screen layer-shell "popup": a veil over the whole
// screen, a floating card, presence files gating Hyprland's binds, a
// four-finger close-drag and a morph into a real window. All of that special
// machinery is gone on purpose (requested): this is now an ordinary xdg
// toplevel like every other app -- it opens at a sensible size, sits in the
// tiling layout, tiles, fullscreens, closes with the compositor's own window
// close animation, and the task manager is its second face (the content
// crossfades in place; no second process, no veil).
// A plain QtQuick Window, not a PanelWindow: PanelWindow is backed by the
// layer shell, and this app must be an ordinary xdg toplevel -- the thing a
// compositor tiles, floats and fullscreens like any other app.
Window {
    id: root

    // The pages, in the order you meet them -- and the order is Windows'.
    //
    //   * `component` is a file name ONLY (e.g. "Overview.qml"), not a path:
    //     the page is loaded by the Loader in modules/settings/
    //     SettingsAppContent.qml, and a relative URL in QML resolves against
    //     the file that does the assigning -- that Loader's own directory. A
    //     path from the config root ("modules/settings/Overview.qml") is
    //     therefore resolved to modules/settings/modules/settings/Overview.qml,
    //     which does not exist: every page failed to load and the app opened
    //     with an empty content pane (the nav rail was all that drew).
    //   * `slug` is the identifier other parts of the shell use to open this
    //     app on a page (`QS_SETTINGS_PAGE=network`, the bar's Wi-Fi and
    //     Bluetooth icons) and what the Overview's shortcut tiles jump to.
    //     Names get translated, so they are useless as identifiers.
    //   * `section` draws as a small caption between rail groups (Windows:
    //     the grey header above each cluster), `group` as the chip beside
    //     the page title. Sections only render on the FIRST page of the
    //     section -- the page that introduces it.
    //
    // The mapping from what was here before (this shell had its own naming):
    // Interface -> Bluetooth & devices' neighbours, General -> System,
    // Quick -> Notifications, Advanced -> For developers. Slugs unchanged,
    // so every deep link keeps working.
    property var pages: [
        {
            name: Translation.tr("Overview"),
            slug: "overview",
            section: Translation.tr("System"),
            group: Translation.tr("System"),
            icon: "dashboard",
            component: "Overview.qml"
        },
        {
            name: Translation.tr("Network & internet"),
            slug: "network",
            section: "",
            group: Translation.tr("Network"),
            icon: "wifi",
            component: "NetworkConfig.qml"
        },
        {
            name: Translation.tr("Bluetooth & devices"),
            slug: "interface",
            section: "",
            group: Translation.tr("Devices"),
            icon: "bluetooth",
            component: "InterfaceConfig.qml"
        },
        {
            name: Translation.tr("Mouse & touchpad"),
            slug: "mouse",
            section: "",
            group: Translation.tr("Devices"),
            icon: "mouse",
            component: "MouseConfig.qml"
        },
        {
            name: Translation.tr("Personalisation"),
            slug: "appearance",
            section: Translation.tr("Personalisation"),
            group: Translation.tr("Appearance"),
            icon: "brush",
            component: "AppearanceConfig.qml"
        },
        {
            name: Translation.tr("Desktop & wallpaper"),
            slug: "desktop",
            section: "",
            group: Translation.tr("Appearance"),
            icon: "wallpaper",
            component: "BackgroundConfig.qml"
        },
        {
            name: Translation.tr("Top bar & dock"),
            slug: "bar",
            section: "",
            group: Translation.tr("Appearance"),
            icon: "top_panel_close",
            iconRotation: 180,
            component: "BarConfig.qml"
        },
        {
            name: Translation.tr("Sidebars"),
            slug: "sidebars",
            section: "",
            group: Translation.tr("Appearance"),
            icon: "view_sidebar",
            component: "SidebarsConfig.qml"
        },
        {
            name: Translation.tr("Apps"),
            slug: "quick",
            section: Translation.tr("Apps"),
            group: Translation.tr("Apps"),
            icon: "apps",
            component: "QuickConfig.qml"
        },
        // The Accounts page, which is now about the account. It used to open
        // KeybindsConfig.qml -- the rail said "Accounts", the search index sent
        // the words account/user/login/password to the keybinds page, and the
        // page that could have held a password control held a shortcut list
        // instead. Keybinds moved to its own entry below (with the keyboard it
        // belongs to); this slug is new, so nothing that opened "keybinds"
        // changes meaning.
        {
            name: Translation.tr("Account"),
            slug: "account",
            section: "",
            group: Translation.tr("Accounts"),
            icon: "person",
            component: "AccountConfig.qml"
        },
        {
            name: Translation.tr("Time & language"),
            slug: "keyboard",
            section: "",
            group: Translation.tr("Time & language"),
            icon: "schedule",
            component: "KeyboardConfig.qml"
        },
        // Where the shortcut list ended up. Same slug as before ("keybinds"),
        // so a deep link or a search hit that already named it still lands here
        // -- it is only the rail that moved it, next to the keyboard settings it
        // belongs with rather than under Accounts.
        {
            name: Translation.tr("Keybinds"),
            slug: "keybinds",
            section: "",
            group: Translation.tr("Time & language"),
            icon: "keyboard_command_key",
            component: "KeybindsConfig.qml"
        },
        {
            name: Translation.tr("Sound"),
            slug: "sound",
            section: "",
            group: Translation.tr("System"),
            icon: "volume_up",
            component: "SoundConfig.qml"
        },
        {
            name: Translation.tr("Display"),
            slug: "display",
            section: "",
            group: Translation.tr("System"),
            icon: "desktop_windows",
            component: "DisplayConfig.qml"
        },
        {
            name: Translation.tr("Notifications"),
            slug: "services",
            section: "",
            group: Translation.tr("System"),
            icon: "notifications",
            component: "ServicesConfig.qml"
        },
        {
            name: Translation.tr("For developers"),
            slug: "advanced",
            section: Translation.tr("System"),
            group: Translation.tr("For developers"),
            icon: "code",
            component: "AdvancedConfig.qml"
        },
        {
            name: Translation.tr("About"),
            slug: "about",
            section: "",
            group: Translation.tr("System"),
            icon: "info",
            component: "About.qml"
        }
    ]
    property int currentPage: 0

    // ── Task manager mode ────────────────────────────────────────────────
    // One app, two faces. The task manager used to be a separate popup
    // process that a hardware tile spawned and then killed this app to make
    // room for. It is one window now: the content swaps in place with a
    // crossfade, the mode state lives here, and every close/IPC path keeps
    // working unchanged.
    property bool taskManagerMode: false
    // The device key the conversion was asked for ("cpu", "gpu:<name>"...).
    property string taskManagerKey: ""
    // Which face was showing before the conversion, so Back restores it.
    property int settingsPageBeforeTm: -1
    // The name the app answers to right now. It IS the window's title: the
    // float-at-map window rule matches on it, and the launch scripts'
    // "already open" lookups find it by it. Settings is the owning face;
    // wearing the task manager face means announcing it.
    readonly property string appTitle: taskManagerMode
        ? Translation.tr("Task Manager")
        : Translation.tr("Settings")
    readonly property var currentPageData: {
        const index = Math.max(0, Math.min(root.currentPage, root.pages.length - 1));
        return root.pages[index];
    }

    // ── The window ────────────────────────────────────────────────────────
    // A window rule in ~/.config/hypr/custom/rules.lua floats it at this
    // size and centres it; from there it behaves like any app -- SUPER+F
    // fills the screen, SUPER+Q closes it, it tiles with the rest.
    //
    // There is deliberately NO `screen:` binding. This build declares the
    // property as QuickshellScreenInfo but its setter wants a
    // QQuickScreenInfo, so any object handed to it is rejected:
    //     WARN settings.qml[220:5] Unable to assign
    //          QuickshellScreenInfo to QQuickScreenInfo
    // The assignment therefore never took effect anyway; the window simply
    // used the default screen. With no binding there is no warning and no
    // behaviour change. (Same dead binding exists in RecordingPill.qml and
    // WaffleNotificationPopup.qml, both panels pinned to one screen anyway.)
    color: "transparent"
    visible: true
    title: root.appTitle
    width: 920
    height: 700
    minimumWidth: 640
    minimumHeight: 480

    // The window's own background -- OPAQUE. A real app window is solid; the
    // grey is the terminal's, the same colour this app has always ended its
    // animations on, so nothing else about its look changes.
    Rectangle {
        id: winBg

        anchors.fill: parent
        radius: Appearance.rounding.windowRounding
        color: Appearance.colors.colTerminalSurfaceSolid
        border.width: 1
        border.color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.6)
    }

    Component.onCompleted: {
        MaterialThemeLoader.reapplyTheme()
        Config.readWriteDelay = 0 // Settings app always only sets one var at a time so delay isn't needed
        root.goToPage(SettingsNav.requestedPage)
    }

    // The first half of the reuse in scripts/launch/settings.sh: a copy of the
    // app that is already open is walked to the page that was asked for instead
    // of a second copy being started, and the request can arrive at any time.
    Connections {
        target: SettingsNav
        function onPageRequested(page) {
            root.goToPage(page);
        }
    }

    // The second half: the page and section request, reachable from outside the
    // app. The script is the only caller.
    //
    //   qs ipc --pid <settings pid> call settings open network bluetooth
    //
    // Not called `show`: `qs ipc show` is a built-in of the CLI and swallows a
    // handler of that name before the shell ever sees it.
    IpcHandler {
        target: "settings"

        // Answers with the page that is showing. It is also how the script tells
        // "already open" from "not running": an unreachable target means nothing
        // is listening, and an unreachable target is a failed process, not a
        // failed page.
        function ping(): string {
            return root.currentPageData?.slug ?? "";
        }

        function open(page: string, section: string): void {
            // An `open` while the window wears the task manager face first
            // converts back: the caller asked for a settings page, and the
            // face has to match the content it is about to show.
            if (root.taskManagerMode)
                root.convertBackToSettings();
            SettingsNav.request(page, section);
        }

        // Close the app from outside. The launcher uses this to replace a copy it
        // cannot talk to on its page: asking it to quit lets it clean up after
        // itself, which killing it does not (see `quitApp`). The old popup close
        // modes ("in"/"down") are accepted and ignored -- there is one close now,
        // the window's own.
        function quit(mode: string): void {
            root.quitApp();
        }

        // Settings <-> Task Manager conversion (the two faces of this one
        // app). `toTaskManager` puts the window in the task manager face and
        // walks it to the device page named by `key`; `backToSettings`
        // restores the page the window was on before the conversion. Both
        // mirror what the hardware tiles and the rail's Back entry do, so a
        // launch script can retarget an open copy without knowing which face
        // it wears.
        function toTaskManager(key: string): void {
            root.convertToTaskManager(key);
        }

        function backToSettings(): void {
            root.convertBackToSettings();
        }
    }

    // Closing the app is not just `Qt.quit()`.
    //
    // The settings app is its own Quickshell instance, so the services it pulls in
    // hold child processes of their own -- `nmcli monitor` above all -- and Qt only
    // cleans up the processes it started itself. Closing Settings twenty times left
    // twenty watchers running behind it; the last thing the app does now is stop
    // what it started. `$PPID` in that shell is this process, and the shell skips
    // itself. Every close path lands here: the close button, Escape, SUPER+Q (the
    // compositor closes the window), and the IPC `quit`.
    function quitApp() {
        childReaper.running = true;
    }

    // The window being closed must take the PROCESS with it. This is a plain
    // xdg toplevel now, so the compositor's close (SUPER+Q, the close button,
    // killactive) only destroys the window -- the instance keeps running,
    // keeps answering `settings ping`, and keeps every child watcher it
    // started alive. The launch scripts believe that process is the app, so
    // they retarget it instead of starting a new one: the window never comes
    // back and "open Settings" looks like it did nothing. Quitting here is
    // also what the reaper comment above always assumed it was doing.
    onClosing: function(close) {
        close.accepted = true;
        root.quitApp();
    }

    Process {
        id: childReaper
        // Captured while this app is provably alive.
        property string pid: `${Quickshell.processId}`
        command: ["sh", "-c", `me=$$; kids=$(pgrep -P ${pid} 2>/dev/null | grep -vw "$me"); [ -n "$kids" ] && kill $kids 2>/dev/null; exit 0`]
        onExited: Qt.quit()
    }

    function goToPage(slug) {
        if (!slug || slug.length === 0) return;
        const index = root.pages.findIndex(page => page.slug === slug);
        if (index >= 0 && index !== root.currentPage) root.currentPage = index;
    }

    // The app itself, drawn by the shared component. Two faces, one window:
    // the Settings pages and (as a sibling) the task manager panel,
    // crossfaded by taskManagerMode. The settings face is ALWAYS alive -- a
    // Loader would destroy it on every conversion, and its recreation
    // re-applies the launch deep link (SettingsNav.requestedPage), yanking
    // the user off the page they were on when they clicked a hardware tile.
    // The TM face keeps its Loader: its instantiation cost (process polling,
    // model build) is only worth paying when it is first converted to.
    // The WINDOWS-STYLE shell (2026-10-04).
    //
    // Replaces SettingsAppContent, which is kept in the tree and still in the
    // qmldir so this is a one-line switch back: the old icon-rail shell is
    // `SettingsUI.SettingsAppContent`, the new grouped-sidebar-and-search one
    // is `SettingsUI.SettingsShellNew`. Nothing inside SettingsAppContent was
    // edited.
    //
    // The two differences in what this passes down, and why:
    //
    //   * `sectionRequested` -- a search result can name a TAB as well as a
    //     page ("Wi-Fi" on Network & internet), so the shell emits it and the
    //     host forwards it to SettingsNav, which is the existing deep-link
    //     channel the bar's icons already use. No new plumbing invented.
    //   * `contentPadding` is left at the new shell's own default; the old
    //     shell wanted 8 and the new one wants a little more air.
    SettingsUI.SettingsShellNew {
        id: settingsFace
        anchors.fill: parent
        opacity: root.taskManagerMode ? 0 : 1
        visible: opacity > 0.01
        pages: root.pages
        currentPage: root.currentPage
        onCurrentPageChanged: root.currentPage = currentPage
        onQuitRequested: root.quitApp()
        onSectionRequested: function(section) {
            // The page we JUST navigated to, not `SettingsNav.requestedPage`.
            // That property is sticky -- it holds whatever a launch or an
            // earlier deep link asked for and is never cleared -- so putting
            // it first meant a search for "bt" could address its tab at
            // whatever page was requested last, which is usually not the one
            // on screen. onSearchActivated calls goToPage() before emitting
            // this, so currentPageData is already the target page here.
            SettingsNav.request(root.currentPageData?.slug ?? SettingsNav.requestedPage ?? "", section);
        }
        Behavior on opacity {
            NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
        }
    }
    Loader {
        id: tmFace
        anchors.fill: parent
        active: root.taskManagerMode
        opacity: root.taskManagerMode ? 1 : 0
        visible: opacity > 0.01
        sourceComponent: tmFaceComponent
        Behavior on opacity {
            NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
        }
    }
    Component {
        id: tmFaceComponent
        TaskManagerUI.TaskManagerContent {
            selectedKey: root.taskManagerKey
            onSelectedKeyChanged: root.taskManagerKey = selectedKey
            // The Back entry is what makes the conversion a two-way
            // street: it restores the page the window was on before the
            // hardware tile converted it.
            showBackButton: true
            onBackRequested: root.convertBackToSettings()
            onQuitRequested: root.quitApp()
        }
    }

    // A page (the Overview hardware tiles) asking for the task manager face
    // lands here, on the same "a page asks, the app answers" path that
    // SettingsNav.pageRequested uses for deep links.
    Connections {
        target: SettingsNav
        function onTaskManagerRequested(key) {
            root.convertToTaskManager(key);
        }
    }

    // ── The conversion, both ways ──────────────────────────────────────────
    // The key normalization the old standalone task manager applied at launch
    // (taskmanager.qml's resolveKey): an empty key means the front door, the
    // running-apps list; "swap" is memory's alias; unknown keys fall back to
    // the CPU page rather than nowhere. Kept identical on purpose -- tiles,
    // IPC and the launcher must land on the same page whichever face of the
    // app answers.
    function resolveTmKey(key) {
        if (!key || key.length === 0)
            return "apps";
        const head = key.indexOf(":") >= 0 ? key.slice(0, key.indexOf(":")) : key;
        if (head === "swap")
            return "memory";
        if ((head === "gpu" || head === "disk" || head === "net") && key.indexOf(":") >= 0) {
            const name = key.slice(key.indexOf(":") + 1);
            if (name.length > 0)
                return key;
        }
        if (head === "battery" || head === "cpu" || head === "memory" || head === "system"
            || head === "apps" || head === "processes")
            return head;
        return "cpu";
    }

    function convertToTaskManager(key) {
        // Normalize like the old standalone app's launch did (resolveKey).
        key = resolveTmKey(key);
        root.taskManagerKey = key;
        if (!root.taskManagerMode) {
            root.settingsPageBeforeTm = root.currentPage;
            root.taskManagerMode = true;
        }
        // The graphs need the sampler. The way back turns it off again --
        // Overview deliberately costs nothing while it is the face showing.
        HardwareStats.setActive("taskManager", true);
    }

    function convertBackToSettings() {
        if (!root.taskManagerMode) return;
        root.taskManagerMode = false;
        if (root.settingsPageBeforeTm >= 0 && root.settingsPageBeforeTm < root.pages.length)
            root.currentPage = root.settingsPageBeforeTm;
        root.settingsPageBeforeTm = -1;
        root.taskManagerKey = "";
        HardwareStats.setActive("taskManager", false);
    }
}
