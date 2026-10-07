pragma Singleton

import qs
import qs.modules.common
import qs.modules.common.models
import qs.modules.common.functions
import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

Singleton {
    id: root

    property string query: ""

    function ensurePrefix(prefix) {
        if ([Config.options.search.prefix.action, Config.options.search.prefix.app, Config.options.search.prefix.clipboard, Config.options.search.prefix.emojis, Config.options.search.prefix.math, Config.options.search.prefix.shellCommand, Config.options.search.prefix.webSearch,].some(i => root.query.startsWith(i))) {
            root.query = prefix + root.query.slice(1);
        } else {
            root.query = prefix + root.query;
        }
    }

    // https://specifications.freedesktop.org/menu/latest/category-registry.html
    property list<string> mainRegisteredCategories: ["AudioVideo", "Development", "Education", "Game", "Graphics", "Network", "Office", "Science", "Settings", "System", "Utility"]
    property list<string> appCategories: (() => {
        const __t = Date.now();
        const acc = DesktopEntries.applications.values.reduce((acc, entry) => {
            for (const category of entry.categories) {
                if (!acc.includes(category) && mainRegisteredCategories.includes(category)) {
                    acc.push(category);
                }
            }
            return acc;
        }, []).sort();
        const __d = Date.now() - __t;
        if (__d > 15) console.log("[slow] appCategories " + __d + "ms");
        return acc;
    })()

    // Load user action scripts from ~/.config/illogical-impulse/actions/
    // Uses FolderListModel to auto-reload when scripts are added/removed
    property var userActionScripts: {
        const actions = [];
        for (let i = 0; i < userActionsFolder.count; i++) {
            const fileName = userActionsFolder.get(i, "fileName");
            const filePath = userActionsFolder.get(i, "filePath");
            if (fileName && filePath) {
                const actionName = fileName.replace(/\.[^/.]+$/, ""); // strip extension
                actions.push({
                    action: actionName,
                    execute: ((path) => (args) => {
                        Quickshell.execDetached([path, ...(args ? args.split(" ") : [])]);
                    })(FileUtils.trimFileProtocol(filePath.toString()))
                });
            }
        }
        return actions;
    }

    FolderListModel {
        id: userActionsFolder
        folder: Qt.resolvedUrl(Directories.userActions)
        showDirs: false
        showHidden: false
        sortField: FolderListModel.Name
    }

    property var searchActions: [
        {
            action: "accentcolor",
            execute: args => {
                Quickshell.execDetached([Directories.wallpaperSwitchScriptPath, "--noswitch", "--color", ...(args != '' ? [`${args}`] : [])]);
            }
        },
        {
            action: "dark",
            execute: () => {
                Quickshell.execDetached([Directories.wallpaperSwitchScriptPath, "--mode", "dark", "--noswitch"]);
            }
        },
        {
            action: "konachanwallpaper",
            execute: () => {
                Quickshell.execDetached([Quickshell.shellPath("scripts/colors/random/random_konachan_wall.sh")]);
            }
        },
        {
            action: "light",
            execute: () => {
                Quickshell.execDetached([Directories.wallpaperSwitchScriptPath, "--mode", "light", "--noswitch"]);
            }
        },
        {
            action: "superpaste",
            execute: args => {
                if (!/^(\d+)/.test(args.trim())) {
                    // Invalid if doesn't start with numbers
                    Quickshell.execDetached(["notify-send", Translation.tr("Superpaste"), Translation.tr("Usage: <tt>%1superpaste NUM_OF_ENTRIES[i]</tt>\nSupply <tt>i</tt> when you want images\nExamples:\n<tt>%1superpaste 4i</tt> for the last 4 images\n<tt>%1superpaste 7</tt> for the last 7 entries").arg(Config.options.search.prefix.action), "-a", "Shell"]);
                    return;
                }
                const syntaxMatch = /^(?:(\d+)(i)?)/.exec(args.trim());
                const count = syntaxMatch[1] ? parseInt(syntaxMatch[1]) : 1;
                const isImage = !!syntaxMatch[2];
                Cliphist.superpaste(count, isImage);
            }
        },
        {
            action: "todo",
            execute: args => {
                Todo.addTask(args);
            }
        },
        {
            action: "wallpaper",
            execute: () => {
                Hyprland.dispatch(`hl.dsp.global("quickshell:wallpaperSelectorToggle")`)
            }
        },
        {
            action: "wipeclipboard",
            execute: () => {
                Cliphist.wipe();
            }
        },
    ]

    // Combined built-in and user actions
    property var allActions: searchActions.concat(userActionScripts)

    // Distro control panels (KDE's systemsettings, GNOME's control-center, and the
    // individual panels beside them) are desktop entries that happen to live in the
    // Settings category. They are not *your* apps, and they used to fill the result
    // list the moment you typed "settings".
    function isSystemSettingsPanel(entry) {
        const id = (entry?.id ?? "").toLowerCase();
        if (id.indexOf("settings") === -1
            && id.indexOf("control-center") === -1
            && id.indexOf("controlcenter") === -1)
            return false;
        return (entry?.categories ?? []).includes("Settings");
    }

    // Tools that ship with the distro rather than being something you installed and
    // reach for by name -- partition editors, theme switchers, monitors, and the
    // standalone network/audio panels. Like terminal-only apps they are worth being
    // able to start, but they are not what you mean when you search for one of your
    // own apps, so they stay behind the Advanced section.
    readonly property list<string> systemToolCommands: [
        "arandr", "avahi-discover", "blueman-manager", "btop", "gparted",
        "gnome-disks", "gnome-system-monitor", "gnome-tweaks", "htop",
        "kvantummanager", "lxappearance", "missioncenter", "nm-connection-editor",
        "pavucontrol", "pavucontrol-qt", "plasma-systemmonitor", "qt5ct", "qt6ct",
        "systemsettings", "gnome-control-center", "xterm",
        // Terminal monitors and system inspectors that ship with the distro.
        "alacritty-monitor", "btm", "cpu-x", "glances", "hardinfo", "hwinfo",
        "inxi", "lshw-gtk", "neofetch", "fastfetch", "nvtop", "sensors",
        "ksysguard", "ksystemlog", "systemmonitor",
        // Disk / boot / snapshot tooling.
        "btrfs-assistant", "snapper-gui", "timeshift-gtk", "timeshift-launcher",
        // Package managers and mirror tools.
        "octopi", "pamac-manager", "bauh", "reflector-simple", "rate-mirrors",
        "pacseek", "yay", "paru",
        // Session / display-manager front-ends.
        "arcolinux-welcome", "cachyos-hello", "garuda-welcome", "manjaro-hello",
        "endeavouros-welcome", "nobara-welcome", "gdm-settings", "sddm-config-editor",
        // Single-purpose HARDWARE panels -- one device, one applet, no place in
        // a general app list. Added 2026-09-30: these were the last seven rows
        // of the Apps tab on this machine, all of them niche enough that the
        // grid read as clutter. Verified against the live app database
        // (`ipc call search debugApps ""`), which showed them all as
        // advanced=false, term=false -- i.e. sitting in the Apps tab:
        //
        //     qv4l2         Qt V4L2 test Utility        (Qt's own test tool)
        //     qvidcap       Qt V4L2 video capture       (ditto)
        //     hdspconf      HDSPConf                    (RME Fireface mixer)
        //     hdspmixer     HDSPMixer                   (ditto)
        //     hwmixvolume   Hwmixvolume                 (HDA mixer applets)
        //     envy24control Envy24 Control              (M-Audio mixer)
        //     hdajackretask HDAJackRetask               (retask jack routing)
        //
        // Every one of these is matched by its EXACT binary basename, not by a
        // substring, so there is no way for the list to reach an unrelated app
        // (there is no "hdspconf-editor" on this machine, and if one were added
        // later it would NOT be caught by a shorter pattern -- which is the
        // behaviour wanted here). They stay launchable from the Advanced tab.
        "qv4l2", "qvidcap",
        "hdspconf", "hdspmixer", "hwmixvolume", "envy24control", "hdajackretask"
    ]

    // Substrings that mark a desktop entry as part of the OPERATING SYSTEM or
    // the desktop environment rather than one of your apps: the distro's own
    // welcome/tweak tools, Hyprland/wlroots/quickshell plumbing, KDE/GNOME
    // control panels, portal backends and the service front-ends that ship
    // beside them. Matched case-insensitively against the entry id, its name,
    // its generic name and its command's basename -- distro entries are
    // inconsistent about which of those carries the giveaway.
    readonly property list<string> systemToolPatterns: [
        "cachyos", "garuda", "manjaro", "endeavouros", "arcolinux", "nobara",
        "bazzite", "opensuse", "dnf", "zypper",
        "hypr", "hyprland", "wlroots", "quickshell", "wayland-session",
        "sddm", "lightdm", "gdm", "greetd",
        "kcm_", "kcm-", "systemsettings", "control-center", "controlcenter",
        "dconf", "gsettings", "xdg-desktop-portal",
        "kvantum", "qt5ct", "qt6ct", "lxappearance", "gtk-theme",
        "systemd", "journalctl", "avahi", "cups", "cups-", "blueman",
        "networkmanager", "nm-connection", "nm-applet", "pavucontrol",
        "pipewire", "wireplumber", "alsamixer", "pulseaudio",
        "pacman", "paru", "yay", "reflector", "rate-mirrors",
        "gparted", "gnome-disks", "btrfs", "snapper", "timeshift",
        "mission-center", "plasma-systemmonitor", "gnome-system-monitor",
        "system-monitor", "btop", "htop", "glances", "nvtop", "hardinfo",
        "cpu-x", "lshw", "hwinfo", "inxi", "fastfetch", "neofetch",
        "screensaver", "polkit", "rsyslog", "udev",
        // Build tooling, added 2026-10-06: the machine's only cmake entry is
        // `cmake-gui` (name "CMake", cats=Development,Building, exec
        // `cmake-gui %f`), which none of the rules above catch -- Development
        // and Building are not system categories, so it came back
        // advanced=false and sat in the normal Apps tab of every search
        // surface. Verified with `ipc call search debugApps cmake` before and
        // after. TOKEN match (5 chars), so it catches `cmake-gui` and a plain
        // `cmake` entry alike while staying clear of unrelated names.
        "cmake"
    ]

    // Categories that only ever come from OS/DE tooling. Deliberately does NOT
    // include Utility or Settings alone: real apps use those too (an editor is
    // `Utility;TextEditor;`), so keyword matching handles the panels instead.
    readonly property list<string> systemCategories: [
        "System", "DesktopSettings", "HardwareSettings", "PackageManager",
        "X-System", "Panel", "Screensaver", "Session"
    ]

    function isDistroOrSystemEntry(entry) {
        const id = String(entry?.id ?? "").toLowerCase();
        const name = String(entry?.name ?? "").toLowerCase();
        const generic = String(entry?.genericName ?? "").toLowerCase();
        const binary = String((entry?.command ?? [])[0] ?? "").split("/").pop().toLowerCase();
        const haystack = `${id} ${name} ${generic} ${binary}`;
        // Tokens instead of raw substrings for the SHORT patterns: "hypr",
        // "gdm", "yay", "cups" must not match inside an unrelated word (a
        // user app called "Hyper" is not Hyprland plumbing). Long patterns
        // stay substring matches so "cachyos-hello" and friends are caught
        // wherever they appear in the id.
        const tokens = haystack.split(/[^a-z0-9]+/).filter(t => t.length > 0);
        for (const pattern of root.systemToolPatterns) {
            if (pattern.length >= 6) {
                if (haystack.indexOf(pattern) !== -1)
                    return true;
            } else if (tokens.indexOf(pattern) !== -1) {
                return true;
            }
        }
        return false;
    }

    // Apps that are NOT distro plumbing, even though the freedesktop category
    // says otherwise. GNOME's baobab declares `System` (among others), so the
    // category rule below filed it as a system panel -- which put Disk Usage
    // Analyzer behind the "Advanced" toggle in every search surface, where a
    // thing you installed yourself to answer "what is eating my disk" does not
    // belong. Matched by exact id, so nothing else can be caught by it.
    readonly property list<string> userFacingTools: [
        "org.gnome.baobab", "baobab"
    ]

    function isSystemTool(entry) {
        if (root.userFacingTools.indexOf(String(entry?.id ?? "")) !== -1)
            return false;
        if (root.isSystemSettingsPanel(entry))
            return true;
        const categories = entry?.categories ?? [];
        if (categories.includes("System"))
            return true;
        for (const category of root.systemCategories) {
            if (categories.includes(category))
                return true;
        }
        if (root.isDistroOrSystemEntry(entry))
            return true;
        const binary = String((entry?.command ?? [])[0] ?? "").split("/").pop();
        return root.systemToolCommands.indexOf(binary) !== -1;
    }

    // Diagnostics over IPC: what the LIVE shell's app database says about a
    // name -- which entries exist, their categories, and whether this service
    // would demote them to "advanced". The whole session's entry visibility
    // is decidable from a terminal, without guessing.
    function debugApps(substr: string): string {
        const needle = substr.toLowerCase();
        const matches = AppSearch.list.filter(e =>
            e.id.toLowerCase().includes(needle) || e.name.toLowerCase().includes(needle));
        const lines = matches.map(e =>
            `${e.id} | ${e.name} | cats=${e.categories.join(",") || "-"}`
            + ` | advanced=${root.isSystemTool(e)} | term=${e.runInTerminal}`
            + ` | exec=${e.execString ?? ""}`);
        return `total=${AppSearch.list.length} matches=${matches.length}\n` + lines.join("\n");
    }

    // The shell's own windows, offered by name. They are NOT desktop entries
    // -- they are windows this shell starts -- so nothing in the app catalogue
    // (AppSearch.fuzzyQuery, the app grids, the frequent row) can ever produce
    // them, and every search surface that wanted one had to grow its own copy
    // of these rows. One list, shared by all of them: the overview search
    // results and the SUPER overlay both read it from here.
    readonly property var shellApps: [
        {
            id: "ii-settings",
            shellApp: true,
            name: Translation.tr("Settings"),
            icon: "settings",
            comment: Translation.tr("Desktop and system"),
            keywords: [
                "settings", "preferences", "prefs", "config", "configuration",
                "options", "control panel", "system settings"
            ],
            script: "scripts/launch/settings.sh",
            loadingText: Translation.tr("Opening the settings window")
        },
        {
            id: "ii-task-manager",
            shellApp: true,
            name: Translation.tr("Task Manager"),
            icon: "monitor_heart",
            comment: Translation.tr("Processes and resources"),
            keywords: [
                "task manager", "taskmanager", "task", "system monitor",
                "systemmonitor", "processes", "process", "resources"
            ],
            script: "scripts/launch/task-manager.sh",
            loadingText: Translation.tr("Opening the task manager")
        }
    ]

    // Which of those windows a query names. Keyword-prefix matching in both
    // directions, so "set", "sett", "settings", "task", "task m" and
    // "taskmanager" all land on the right one.
    function shellAppsMatching(query) {
        const q = String(query ?? "").trim().toLowerCase();
        if (q.length < 2)
            return [];
        return root.shellApps.filter(app =>
            app.keywords.some(keyword => keyword.indexOf(q) === 0 || q.indexOf(keyword) === 0));
    }

    // Start one of them. The loading card is raised here and taken down by the
    // launch script itself (`answer()`), which knows whether it retargeted a
    // running copy or started a new one -- so the card never outlives the
    // launch, and a cold start still gets feedback.
    function launchShellApp(app) {
        if (!app?.script)
            return;
        GlobalStates.showLoading(app.loadingText ?? app.name);
        Quickshell.execDetached(["bash", Quickshell.shellPath(app.script)]);
    }

    property bool clipboardWorkSafetyActive: {
        const enabled = Config.options.workSafety.enable.clipboard;
        const sensitiveNetwork = (StringUtils.stringListContainsSubstring(Network.networkName.toLowerCase(), Config.options.workSafety.triggerCondition.networkNameKeywords));
        return enabled && sensitiveNetwork;
    }

    function containsUnsafeLink(entry) {
        if (entry == undefined)
            return false;
        const unsafeKeywords = Config.options.workSafety.triggerCondition.linkKeywords;
        return StringUtils.stringListContainsSubstring(entry.toLowerCase(), unsafeKeywords);
    }

    property list<var> results: {
        // Search results are handled here
        ////////////////// Skip? //////////////////
        if (root.query == "")
            return [];

        ///////////// Special cases ///////////////
        if (root.query.startsWith(Config.options.search.prefix.clipboard)) {
            // Clipboard
            const searchString = StringUtils.cleanPrefix(root.query, Config.options.search.prefix.clipboard);
            return Cliphist.fuzzyQuery(searchString).map((entry, index, array) => {
                const mightBlurImage = Cliphist.entryIsImage(entry) && root.clipboardWorkSafetyActive;
                let shouldBlurImage = mightBlurImage;
                if (mightBlurImage) {
                    shouldBlurImage = shouldBlurImage && (root.containsUnsafeLink(array[index - 1]) || root.containsUnsafeLink(array[index + 1]));
                }
                const type = `#${entry.match(/^\s*(\S+)/)?.[1] || ""}`;
                return resultComp.createObject(null, {
                    rawValue: entry,
                    name: StringUtils.cleanCliphistEntry(entry),
                    verb: "",
                    type: type,
                    execute: () => {
                        Cliphist.copy(entry);
                    },
                    actions: [resultComp.createObject(null, {
                            name: Translation.tr("Copy"),
                            iconName: "content_copy",
                            iconType: LauncherSearchResult.IconType.Material,
                            execute: () => {
                                Cliphist.copy(entry);
                            }
                        }), resultComp.createObject(null, {
                            name: Translation.tr("Delete"),
                            iconName: "delete",
                            iconType: LauncherSearchResult.IconType.Material,
                            execute: () => {
                                Cliphist.deleteEntry(entry);
                            }
                        })],
                    blurImage: shouldBlurImage
                });
            }).filter(Boolean);
        } else if (root.query.startsWith(Config.options.search.prefix.emojis)) {
            // Clipboard
            const searchString = StringUtils.cleanPrefix(root.query, Config.options.search.prefix.emojis);
            return Emojis.fuzzyQuery(searchString).map(entry => {
                const emoji = entry.match(/^\s*(\S+)/)?.[1] || "";
                return resultComp.createObject(null, {
                    rawValue: entry,
                    name: entry.replace(/^\s*\S+\s+/, ""),
                    iconName: emoji,
                    iconType: LauncherSearchResult.IconType.Text,
                    verb: Translation.tr("Copy"),
                    type: Translation.tr("Emoji"),
                    execute: () => {
                        Quickshell.clipboardText = entry.match(/^\s*(\S+)/)?.[1];
                    }
                });
            }).filter(Boolean);
        }

        ////////////////// Init ///////////////////
        const appResultObjects = AppSearch.fuzzyQuery(StringUtils.cleanPrefix(root.query, Config.options.search.prefix.app)).map(entry => {
            return resultComp.createObject(null, {
                type: Translation.tr("App"),
                id: entry.id,
                name: entry.name,
                iconName: entry.icon,
                iconType: LauncherSearchResult.IconType.System,
                verb: Translation.tr("Open"),
                // Terminal-only apps and the distro's own tools go to the advanced
                // list instead of the normal results.
                advanced: entry.runInTerminal || root.isSystemTool(entry),
                execute: () => {
                    // Remember it for the panel's "recently used" row, then launch
                    // it through the shell rather than straight from the desktop
                    // entry: that is what lets the corner card end with either
                    // "it is here" or "it is not", instead of going silent and
                    // leaving you to guess which one happened.
                    AppUsage.record(entry);
                    if (!entry.runInTerminal)
                        // The label must be the plain app name: the already-open
                        // matcher tests it against window classes, and a fluent
                        // sentence like "Opening Firefox" can never match one.
                        GlobalStates.openApp(entry.command.join(' '), entry.name ?? "");
                    else {
                        // Probably needs more proper escaping, but this will do for now
                        GlobalStates.openApp(`${Config.options.apps.terminal} -e '${StringUtils.shellSingleQuoteEscape(entry.command.join(' '))}'`,
                            entry.name ?? "");
                    }
                },
                comment: entry.comment,
                runInTerminal: entry.runInTerminal,
                genericName: entry.genericName,
                keywords: entry.keywords,
                actions: entry.actions.map(action => {
                    return resultComp.createObject(null, {
                        name: action.name,
                        iconName: action.icon,
                        iconType: LauncherSearchResult.IconType.System,
                        execute: () => {
                            if (!action.runInTerminal)
                                action.execute();
                            else {
                                Quickshell.execDetached(["bash", '-c', `${Config.options.apps.terminal} -e '${StringUtils.shellSingleQuoteEscape(action.command.join(' '))}'`]);
                            }
                        }
                    });
                })
            });
        });
        const commandResultObject = resultComp.createObject(null, {
            name: StringUtils.cleanPrefix(root.query, Config.options.search.prefix.shellCommand).replace("file://", ""),
            verb: Translation.tr("Run"),
            type: Translation.tr("Command"),
            fontType: LauncherSearchResult.FontType.Monospace,
            iconName: 'terminal',
            iconType: LauncherSearchResult.IconType.Material,
            execute: () => {
                let cleanedCommand = root.query.replace("file://", "");
                cleanedCommand = StringUtils.cleanPrefix(cleanedCommand, Config.options.search.prefix.shellCommand);
                if (cleanedCommand.startsWith(Config.options.search.prefix.shellCommand)) {
                    cleanedCommand = cleanedCommand.slice(Config.options.search.prefix.shellCommand.length);
                }
                Quickshell.execDetached(["bash", "-c", root.query.startsWith('sudo') ? `${Config.options.apps.terminal} fish -C '${cleanedCommand}'` : cleanedCommand]);
            }
        });
        const webSearchResultObject = resultComp.createObject(null, {
            name: StringUtils.cleanPrefix(root.query, Config.options.search.prefix.webSearch),
            verb: Translation.tr("Search"),
            type: Translation.tr("Web search"),
            iconName: 'travel_explore',
            iconType: LauncherSearchResult.IconType.Material,
            execute: () => {
                let query = StringUtils.cleanPrefix(root.query, Config.options.search.prefix.webSearch);
                let url = Config.options.search.engineBaseUrl + query;
                for (let site of Config.options.search.excludedSites) {
                    url += ` -site:${site}`;
                }
                Qt.openUrlExternally(url);
            }
        });
        const launcherActionObjects = root.allActions.map(action => {
            const actionString = `${Config.options.search.prefix.action}${action.action}`;
            if (actionString.startsWith(root.query) || root.query.startsWith(actionString)) {
                return resultComp.createObject(null, {
                    name: root.query.startsWith(actionString) ? root.query : actionString,
                    verb: Translation.tr("Run"),
                    type: Translation.tr("Action"),
                    iconName: 'settings_suggest',
                    iconType: LauncherSearchResult.IconType.Material,
                    execute: () => {
                        action.execute(root.query.split(" ").slice(1).join(" "));
                    }
                });
            }
            return null;
        }).filter(Boolean);

        // Our own windows, offered by name. Without these, typing "settings"
        // only ever found the distro's separate control panels, and the task
        // manager was unreachable by name at all. The list itself lives at the
        // top of this file so the SUPER overlay searches the same entries.
        const shellResultObjects = root.shellAppsMatching(root.query).map(app =>
            resultComp.createObject(null, {
                id: app.id,
                name: app.name,
                verb: Translation.tr("Open"),
                type: Translation.tr("App"),
                comment: app.comment,
                iconName: app.icon,
                iconType: LauncherSearchResult.IconType.Material,
                execute: () => root.launchShellApp(app)
            }));

        //////// Prioritized by prefix /////////
        let result = [];
        const startsWithShellCommandPrefix = root.query.startsWith(Config.options.search.prefix.shellCommand);
        const startsWithWebSearchPrefix = root.query.startsWith(Config.options.search.prefix.webSearch);
        if (startsWithShellCommandPrefix) {
            result.push(commandResultObject);
        } else if (startsWithWebSearchPrefix) {
            result.push(webSearchResultObject);
        }

        // Held above the app list so they are the first things Tab reaches.
        result = result.concat(shellResultObjects);

        //////////////// Apps //////////////////
        result = result.concat(appResultObjects);

        ////////// Launcher actions ////////////
        result = result.concat(launcherActionObjects);

        /// Math result, command, web search ///
        if (Config.options.search.prefix.showDefaultActionsWithoutPrefix) {
            if (!startsWithShellCommandPrefix)
                result.push(commandResultObject);
            if (!startsWithWebSearchPrefix)
                result.push(webSearchResultObject);
        }

        return result;
    }

    Component {
        id: resultComp
        LauncherSearchResult {}
    }
}
