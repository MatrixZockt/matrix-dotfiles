pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common.functions

Singleton {
    id: root
    property string filePath: Directories.shellConfigPath
    property alias options: configOptionsJsonAdapter
    property bool ready: false
    property int readWriteDelay: 50 // milliseconds
    property bool blockWrites: false

    function setNestedValue(nestedKey, value) {
        let keys = nestedKey.split(".");
        let obj = root.options;
        let parents = [obj];

        // Traverse and collect parent objects
        for (let i = 0; i < keys.length - 1; ++i) {
            if (!obj[keys[i]] || typeof obj[keys[i]] !== "object") {
                obj[keys[i]] = {};
            }
            obj = obj[keys[i]];
            parents.push(obj);
        }

        // Convert value to correct type using JSON.parse when safe
        let convertedValue = value;
        if (typeof value === "string") {
            let trimmed = value.trim();
            if (trimmed === "true" || trimmed === "false" || !isNaN(Number(trimmed))) {
                try {
                    convertedValue = JSON.parse(trimmed);
                } catch (e) {
                    convertedValue = value;
                }
            }
        }

        obj[keys[keys.length - 1]] = convertedValue;
    }

    // ── Our own write must not be read back over the value we just set ──────
    //
    // Watch-and-write on one file is a race, and this shell kept losing it:
    // a property write schedules a flush in 50 ms, the flush changes the file,
    // watchChanges reports that as a change, and the 50 ms reload then stamps
    // the adapter with whatever the file happened to contain -- which, for a
    // write still in flight, is the PREVIOUS value. The property visibly
    // snapped back, and the next write was computed from the reverted value.
    //
    // It showed up as "changing the power mode sometimes does nothing": tapping
    // the bar's power icon twice quickly set performance, then eco, then read
    // eco again -- a reload had put the older value back -- so the third tap
    // walked the ring from the wrong notch. Anything with a cycle or a
    // read-modify-write on config was exposed the same way, most visibly under
    // fast clicks (a real click pair is ~130 ms, and the window below is 250).
    //
    // So a change we caused is not news: `selfWrite` covers the flush (and the
    // file event it raises), and reloads are skipped while it is up. Changes
    // from anywhere else -- the settings app, a hand edit -- are still picked
    // up exactly as before, because they do not go through this flush.
    property bool selfWrite: false
    Timer {
        id: selfWriteTimer
        interval: 250
        repeat: false
        onTriggered: root.selfWrite = false
    }

    Timer {
        id: fileReloadTimer
        interval: root.readWriteDelay
        repeat: false
        onTriggered: {
            // Not while our own flush is in flight: the file is mid-write, and
            // what it holds now is older than what memory holds.
            if (root.selfWrite)
                return
            configFileView.reload()
        }
    }

    Timer {
        id: fileWriteTimer
        interval: root.readWriteDelay
        repeat: false
        onTriggered: {
            root.selfWrite = true
            selfWriteTimer.restart()
            configFileView.writeAdapter()
        }
    }

    FileView {
        id: configFileView
        path: root.filePath
        watchChanges: true
        blockWrites: root.blockWrites
        onFileChanged: fileReloadTimer.restart()
        onAdapterUpdated: fileWriteTimer.restart()
        onLoaded: root.ready = true
        onLoadFailed: error => {
            if (error == FileViewError.FileNotFound) {
                writeAdapter();
            }
        }

        JsonAdapter {
            id: configOptionsJsonAdapter

            property string panelFamily: "ii" // "ii", "waffle"
            // Performance mode: keeps the look, drops the motion budget
            // (animations off, hand-played transitions cut short) so a slow
            // machine or a heavy workload stays responsive. Applied by
            // scripts/performance/apply.sh; see services/PerformanceMode.qml.
            property bool performanceMode: false

            property JsonObject policies: JsonObject {
                property int ai: 1 // 0: No | 1: Yes | 2: Local
                property int weeb: 1 // 0: No | 1: Open | 2: Closet
            }

            property JsonObject ai: JsonObject {
                property string systemPrompt: "## Style\n- Use casual tone, don't be formal!\n- Always be brief and to the point, unless asked otherwise\n- Don't repeat the user's question\n- Be approachable: Avoid using overly complicated, domain-specific terms and provide analogies when asked to explain a concept\n\n## Context (ignore when irrelevant)\n- You are a helpful and inspiring sidebar assistant on a {DISTRO} Linux system\n- Desktop environment: {DE}\n- Current date & time: {DATETIME}\n- Focused app: {WINDOWCLASS}\n\n## Presentation\n- Use Markdown features in your response: \n  - **Bold** text to **highlight keywords** in your response\n  - **Split long information into small sections** with h2 headers and a relevant emoji at the start of it (for example `## 🐧 Linux`). Bullet points are preferred over long paragraphs, unless you're offering writing support or instructed otherwise by the user.\n- Asked to compare different options? You should firstly use a table to compare the main aspects, then elaborate or include relevant comments from online forums *after* the table. Make sure to provide a final recommendation for the user's use case!\n- Use LaTeX formatting for mathematical and scientific notations whenever appropriate. Enclose all LaTeX '$$' delimiters. NEVER generate LaTeX code in a latex block unless the user explicitly asks for it. DO NOT use LaTeX for regular documents (resumes, letters, essays, CVs, etc.).\n\nThanks!\n"
                property string tool: "functions" // search, functions, or none
                property list<var> extraModels: [
                    {
                        "api_format": "openai", // Most of the time you want "openai". Use "gemini" for Google's models
                        "description": "This is a custom model. Edit the config to add more! | Anyway, this is DeepSeek R1 Distill LLaMA 70B",
                        "endpoint": "https://openrouter.ai/api/v1/chat/completions",
                        "homepage": "https://openrouter.ai/deepseek/deepseek-r1-distill-llama-70b:free", // Not mandatory
                        "icon": "spark-symbolic", // Not mandatory
                        "key_get_link": "https://openrouter.ai/settings/keys", // Not mandatory
                        "key_id": "openrouter",
                        "model": "deepseek/deepseek-r1-distill-llama-70b:free",
                        "name": "Custom: DS R1 Dstl. LLaMA 70B",
                        "requires_key": true
                    }
                ]
            }

            property JsonObject appearance: JsonObject {
                property bool extraBackgroundTint: true
                property int fakeScreenRounding: 2 // 0: None | 1: Always | 2: When not fullscreen
                property real textScale: 1.0 // Accessibility: global UI text scale multiplier (0.8–1.4)
                property string styleTemplate: "" // GUI shape template: "", "sharp", "arctic", "brutal", "ink". Reshapes widgets only; never behaviour or Hyprland config.
                property JsonObject fonts: JsonObject {
                    property string main: "Google Sans Flex"
                    property string numbers: "Google Sans Flex"
                    property string title: "Google Sans Flex"
                    property string iconNerd: "JetBrains Mono NF"
                    property string monospace: "JetBrains Mono NF"
                    property string reading: "Readex Pro"
                    property string expressive: "Space Grotesk"
                }
                property JsonObject transparency: JsonObject {
                    property bool enable: false
                    property bool automatic: true
                    property real backgroundTransparency: 0.11
                    property real contentTransparency: 0.57
                }
                property JsonObject wallpaperTheming: JsonObject {
                    property bool enableAppsAndShell: true
                    property bool enableQtApps: true
                    property bool enableTerminal: true
                    property JsonObject terminalGenerationProps: JsonObject {
                        property real harmony: 0.6
                        property real harmonizeThreshold: 100
                        property real termFgBoost: 0.35
                        property bool forceDarkMode: false
                    }
                }
                property JsonObject palette: JsonObject {
                    property string type: "auto" // Allowed: auto, scheme-content, scheme-expressive, scheme-fidelity, scheme-fruit-salad, scheme-monochrome, scheme-neutral, scheme-rainbow, scheme-tonal-spot
                    property string accentColor: ""
                }
            }

            property JsonObject audio: JsonObject {
                // Values in %
                property JsonObject protection: JsonObject {
                    // Prevent sudden bangs
                    property bool enable: false
                    property real maxAllowedIncrease: 10
                    property real maxAllowed: 99
                }
            }

            property JsonObject apps: JsonObject {
                property string bluetooth: "kcmshell6 kcm_bluetooth"
                property string changePassword: "kitty -1 --hold=yes fish -i -c 'passwd'"
                property string network: "kcmshell6 kcm_networkmanagement"
                property string manageUser: "kcmshell6 kcm_users"
                property string networkEthernet: "kcmshell6 kcm_networkmanagement"
                // The shell's own task manager: the hardware-specs app
                // (taskmanager.qml) through its launch script. The script is the
                // single-instance gate -- it walks a copy that is already open to
                // the section asked for and only starts one when none is running --
                // so a direct IPC call here would bypass exactly the gate that
                // keeps fast double-clicks from leaving two copies.
                property string taskManager: `~/.config/quickshell/ii/scripts/launch/task-manager.sh`
                property string terminal: "kitty -1" // This is only for shell actions
                property string update: "kitty -1 --hold=yes fish -i -c 'pkexec pacman -Syu'"
                property string volumeMixer: `~/.config/hypr/hyprland/scripts/launch_first_available.sh "pavucontrol-qt" "pavucontrol"`
                // ── Per-app popup handling ─────────────────────────────────
                // WM classes for which the compositor's automatic popup
                // classifier (custom/general.lua: "an app's second window is a
                // popup") is switched OFF, so every window of that app always
                // attaches to the tiler.
                //
                // A LIST of the exceptions, not a map of every app: the
                // default has to stay "the classifier applies", because that
                // is how the compositor has behaved forever and a config that
                // had to enumerate every app to keep working would silently
                // change behaviour the first time an app was missed. Empty
                // list = nothing is exempt.
                property list<string> popupHandlingOff: []
                // ── Single-instance apps ───────────────────────────────────
                // The apps for which clicking a launcher entry while the app
                // ALREADY has a window focuses that window instead of
                // starting a second session (the "X is already open" notice).
                //
                // An allowlist, not a denylist, because the redirect is a
                // single-instance POLICY rather than a launch guard: applied
                // to every app it was actively wrong. A Chromium browser is
                // the case that made it obvious -- "open Brave" while a
                // private window is up has to give a new NORMAL window, and
                // the redirect answered with a notice and never launched.
                //
                // Matched case-insensitively against the Hyprland window
                // class, by whole class or by class segment ("brave-browser"
                // splits on "-"), so a reverse-DNS class is reached by its
                // last segment. Empty list = every launch starts fresh.
                property list<string> singleInstance: ["discord", "tradingview"]
            }

            property JsonObject background: JsonObject {
                // Auto-switch: the wallpaper carousel applies the next
                // wallpaper on a wall-clock interval (Settings → Look).
                property JsonObject autoSwitch: JsonObject {
                    property bool enable: false
                    property int intervalS: 300 // seconds between changes
                }
                // The clock wallpaper (modules/ii/background/
                // ClockWallpaper.qml): the desktop becomes the pen's #282828
                // page, and the neumorphic clock with its hourly line is the
                // whole picture.
                //
                // Off by default, and it never touches the wallpaper file: the
                // path in `wallpaperPath` stays what the theme and the lock
                // screen read, so turning this off brings the picture straight
                // back (and the colour palette never had to change).
                property JsonObject clockWallpaper: JsonObject {
                    property bool enable: false
                }
                property JsonObject widgets: JsonObject {
                    // (The sidebar WidgetsBoard and the SoundBar desktop rail
                    // were deleted; their config blocks went with them.)
                    property JsonObject wallpaper: JsonObject {
                        property bool enable: true
                        property string placementStrategy: "free" // "free", "leastBusy", "mostBusy"
                        property real x: 0
                        property real y: 0
                    }
                    property JsonObject clock: JsonObject {
                        property bool enable: true
                        property bool showOnlyWhenLocked: false
                        property string placementStrategy: "leastBusy" // "free", "leastBusy", "mostBusy"
                        property real x: 100
                        property real y: 100
                        property string style: "cookie"        // Options: "cookie", "digital"
                        property string styleLocked: "cookie"  // Options: "cookie", "digital"
                        property JsonObject cookie: JsonObject {
                            property bool aiStyling: false
                            property int sides: 14
                            property string dialNumberStyle: "full"   // Options: "dots" , "numbers", "full" , "none"
                            property string hourHandStyle: "fill"     // Options: "classic", "fill", "hollow", "hide"
                            property string minuteHandStyle: "medium" // Options "classic", "thin", "medium", "bold", "hide"
                            property string secondHandStyle: "dot"    // Options: "dot", "line", "classic", "hide"
                            property string dateStyle: "bubble"       // Options: "border", "rect", "bubble" , "hide"
                            property bool timeIndicators: true
                            property bool hourMarks: false
                            property bool dateInClock: true
                            property bool constantlyRotate: false
                            property bool useSineCookie: false
                        }
                        property JsonObject digital: JsonObject {
                            property bool adaptiveAlignment: true
                            property bool showDate: true
                            property bool animateChange: true
                            property bool vertical: false
                            property JsonObject font: JsonObject {
                                property string family: "Google Sans Flex"
                                property real weight: 350
                                property real width: 100
                                property real size: 90
                                property real roundness: 0
                            }
                        }
                        property JsonObject quote: JsonObject {
                            property bool enable: false
                            property string text: ""
                        }
                    }
                    property JsonObject weather: JsonObject {
                        property bool enable: false
                        property string placementStrategy: "free" // "free", "leastBusy", "mostBusy"
                        property real x: 400
                        property real y: 100
                    }
                }
                property string wallpaperPath: ""
                property string thumbnailPath: ""
                // A separate wallpaper for the light and the dark theme. When
                // `separateThemeWallpaper` is on, the two paths below are what the
                // shell draws -- whichever one matches the theme that is currently
                // on -- and picking a wallpaper from the selector stores it against
                // the theme you were in at the time. With it off, `wallpaperPath`
                // is used for both, exactly as before.
                property bool separateThemeWallpaper: false
                property string wallpaperPathLight: ""
                property string wallpaperPathDark: ""
                // Optional: a picture baked into the login (SDDM) screen on the
                // next Reinstall. Empty = the desktop wallpaper is baked.
                property string wallpaperPathLogin: ""
                // Optional: the picture the lock screen (SUPER+L) draws. Empty
                // = the lock shows the same wallpaper as the desktop, and it
                // keeps following it as the desktop changes.
                property string wallpaperPathLock: ""
                property bool hideWhenFullscreen: true
                property JsonObject parallax: JsonObject {
                    property bool vertical: false
                    property bool autoVertical: false
                    property bool enableWorkspace: false
                    property real workspaceZoom: 1.07 // Relative to wallpaper size
                    property bool enableSidebar: false
                    property real widgetsFactor: 1.2
                }
            }

            property JsonObject bar: JsonObject {
                // Master switch. With this off the bar (top/bottom or vertical) is
                // not loaded at all -- no surface, no reserved screen edge.
                property bool enable: true
                property JsonObject autoHide: JsonObject {
                    property bool enable: false
                    property int hoverRegionWidth: 2
                    property bool pushWindows: false
                    property JsonObject showWhenPressingSuper: JsonObject {
                        property bool enable: true
                        property int delay: 140
                    }
                }
                property bool bottom: false // Instead of top
                property int cornerStyle: 0 // 0: Hug | 1: Float | 2: Plain rectangle
                property bool floatStyleShadow: true // Show shadow behind bar when cornerStyle == 1 (Float)
                property bool borderless: false // true for no grouping of items
                property string topLeftIcon: "spark" // Options: "distro" or any icon name in ~/.config/quickshell/ii/assets/icons
                property bool showBackground: true
                property bool verbose: true
                property bool vertical: false
                // Whether the bar stays on screen over a fullscreen window.
                //
                // Off (default) is the smart behaviour: the bar slides away
                // while a window is fullscreen and comes back when you PRESS
                // the very top edge -- the same gesture the sidebars use at
                // their edges, so the top and the sides behave alike. On a
                // normal desktop the bar still opens on hover, as it always
                // has. On keeps the bar exactly where it is, fullscreen or
                // not -- the switch to flip when you are running something
                // fullscreen and still want the clock, tray and workspaces in
                // view.
                property bool showInFullscreen: false
                // Live quick-toggle icons in the top bar's right section,
                // chosen in the right sidebar's "Top-bar widgets" editor.
                // Each key is one of the shell's quick-toggle models; a true
                // value puts its small icon in the bar (click opens the right
                // sidebar, right click runs the toggle's quick action).
                property JsonObject topBarWidgets: JsonObject {
                    property bool nightLight: false
                    property bool darkMode: false
                    property bool bluetooth: false
                    property bool network: false
                    property bool mic: false
                    property bool idleInhibitor: false
                    property bool gameMode: false
                    property bool powerProfiles: false
                    property bool screenSnip: false
                    property bool colorPicker: false
                    property bool performance: false
                }
                property JsonObject resources: JsonObject {
                    property bool alwaysShowSwap: true
                    property bool alwaysShowCpu: true
                    property int memoryWarningThreshold: 95
                    property int swapWarningThreshold: 85
                    property int cpuWarningThreshold: 90
                }
                property list<string> screenList: [] // List of names, like "eDP-1", find out with 'hyprctl monitors' command
                property JsonObject utilButtons: JsonObject {
                    property bool showScreenSnip: false
                    property bool showColorPicker: false
                    property bool showMicToggle: false
                    property bool showKeyboardToggle: false
                    property bool showDarkModeToggle: true
                    property bool showPerformanceProfileToggle: false
                    property bool showScreenRecord: false
                    // Left-to-right order of the buttons that are enabled. Managed
                    // by dragging them around in Settings > Bar > Utility buttons;
                    // keys this list does not mention are appended after it.
                    property list<string> order: [
                        "screenSnip", "screenRecord", "colorPicker",
                        "keyboardToggle", "micToggle", "darkModeToggle",
                        "performanceProfileToggle"
                    ]
                }
                property JsonObject workspaces: JsonObject {
                    property bool monochromeIcons: true
                    property int shown: 10
                    property bool showAppIcons: true
                    property bool alwaysShowNumbers: false
                    property int showNumberDelay: 300 // milliseconds
                    property list<string> numberMap: ["1", "2"] // Characters to show instead of numbers on workspace indicator
                    property bool useNerdFont: false
                }
                property JsonObject weather: JsonObject {
                    property bool enable: false
                    property bool enableGPS: true // gps based location
                    property string city: "" // When 'enableGPS' is false
                    property bool useUSCS: false // Instead of metric (SI) units
                    property int fetchInterval: 10 // minutes
                }
                // Which of the bar's own indications are drawn. These are the
                // switches the right sidebar's edit mode offers (add/remove a
                // bar icon), and they are the bar's existing icons rather than
                // copies: turning Wi-Fi off takes the Wi-Fi icon out of the
                // connectivity pill instead of adding a second one somewhere
                // else. Defaults are true, and anything missing counts as true
                // (`!== false` everywhere), because an untouched bar has always
                // shown these and a config written before this existed must not
                // silently lose them.
                property JsonObject indicators: JsonObject {
                    property bool network: true // Wi-Fi, in the connectivity pill
                    property bool bluetooth: true // Bluetooth, in the same pill
                    // The VPN / tailnet indication, in that same pill (see
                    // services/Tailscale.qml). The one indicator whose subject
                    // may not exist: the icon needs the tailscale CLI AND this
                    // switch -- exactly the pair of conditions Wi-Fi and
                    // Bluetooth already answer with (`installed`/`available`
                    // plus the switch). Off removes the icon from the pill even
                    // where the CLI is present.
                    property bool vpn: true
                    property bool sound: true // volume / mute
                    property bool battery: true // charge
                    // The muted-MICROPHONE chip in the pill (its sink twin
                    // follows the `sound` switch -- one mute icon per device
                    // would be two switches for one state).
                    property bool mic: true
                    property JsonObject notifications: JsonObject {
                        property bool show: true // the bell chip itself
                        property bool showUnreadCount: false
                    }
                }
                // How many tray icons show directly on the bar (1..5). The rest --
                // and everything unpinned -- lives in the tray's overflow menu, so
                // nothing is ever unreachable, just one click further away.
                property int visibleTrayIcons: 3
                property JsonObject tooltips: JsonObject {
                    property bool clickToShow: false
                }
            }

            property JsonObject battery: JsonObject {
                property int low: 20
                property int critical: 5
                property int full: 101
                property bool automaticSuspend: true
                property int suspend: 3
                // What the machine is being tuned for. One choice, three jobs,
                // applied by services/PowerMode.qml:
                //
                //   "default"     Balanced. The platform profile is balanced and
                //                 the desktop animates normally. Nothing is
                //                 forced in either direction; this is the default.
                //   "eco"         Power saver. Lower platform profile for the
                //                 longest runtime, at the cost of peak speed.
                //   "performance" Performance profile AND motion cut right down
                //                 -- the shell's animations to 12% and Hyprland's
                //                 window animations off -- so the interface gets
                //                 out of the way while you work.
                property string powerMode: "default"
                // Fan mode chosen in the app: "quiet" holds the fans a step
                // below the firmware curve, "default" leaves it alone,
                // "noisy" pins them high for a cooler machine, "manual"
                // pins the exact level in fanManualLevel (TFN1, 0-50).
                property string fanMode: "default"
                property int fanManualLevel: 0
                // The TFN1 level the app last actually wrote. The kernel's
                // cooling_device0/cur_state is write-only on this machine
                // (reads return EINVAL), so this is the only record of what
                // the hardware is running. Written by the app, read by
                // nothing in the shell -- declared so the shared config
                // store keeps a known shape.
                property int fanAppliedLevel: 0
                // Backlight percentage the screen dims to on idle. The display
                // never turns off: it parks here, visible but not burning
                // watts, and any input restores the previous brightness.
                property int idleDimPercent: 1
                // What idling does BESIDES dimming. The display is never turned
                // off and the machine is never suspended from here -- see
                // hypr/hypridle.conf, which has no such listener any more.
                //
                //   "dim"  backlight to the floor, nothing else touched.
                //   "eco"  dim + blur/shadows/animations off and VFR on: the
                //          compositor stops redrawing hard, so the watts come
                //          from the right place, and the picture stays exactly
                //          as legible as it was.
                //   "veil" dim + a screen shader that mutes and darkens the
                //          finished frame: reads as asleep, still readable.
                //   "deep" veil + eco, the quietest of the four.
                property string idleMode: "eco"
            }

            property JsonObject calendar: JsonObject {
                property string locale: "en-GB"
            }

            property JsonObject cheatsheet: JsonObject {
                // Use a nerdfont to see the icons
                // 0: 󰖳  | 1: 󰌽 | 2: 󰘳 | 3:  | 4: 󰨡
                // 5:  | 6:  | 7: 󰣇 | 8:  | 9: 
                // 10:  | 11:  | 12:  | 13:  | 14: 󱄛
                property string superKey: ""
                property bool useMacSymbol: false
                property bool splitButtons: false
                property bool useMouseSymbol: false
                property bool useFnSymbol: false
                property JsonObject fontSize: JsonObject {
                    property int key: Appearance.font.pixelSize.smaller
                    property int comment: Appearance.font.pixelSize.smaller
                }
            }

            property JsonObject conflictKiller: JsonObject {
                property bool autoKillNotificationDaemons: false
                property bool autoKillTrays: false
            }

            property JsonObject crosshair: JsonObject {
                // Valorant crosshair format. Use https://www.vcrdb.net/builder
                property string code: "0;P;d;1;0l;10;0o;2;1b;0"
            }

            property JsonObject dock: JsonObject {
                property bool enable: true
                property bool monochromeIcons: false
                property real height: 52
                // Height of the strip at the bottom edge that brings the dock
                // back. It used to default to 2, which is practically
                // unhittable -- the dock could never be revealed by hovering.
                property real hoverRegionHeight: 30
                property bool pinnedOnStartup: false
                property bool hoverToReveal: true // When false, only reveals on empty workspace
                property list<string> pinnedApps: [ // IDs of pinned entries
                    "org.kde.dolphin", "kitty"]
                property list<string> ignoredAppRegexes: []
            }

            // Keyboard layouts. The list lives here and is turned into
            // ~/.config/hypr/custom/keyboard.lua by scripts/keyboard/apply.sh,
            // which is what Hyprland actually reads. Managed from
            // Settings > Keyboard.
            property JsonObject keyboard: JsonObject {
                property list<string> layouts: ["de"]
                property string options: "grp:alt_shift_toggle"
            }

            property JsonObject interactions: JsonObject {
                property JsonObject scrolling: JsonObject {
                    property bool fasterTouchpadScroll: false // Enable faster scrolling with touchpad
                    property int mouseScrollDeltaThreshold: 120 // delta >= this then it gets detected as mouse scroll rather than touchpad
                    property int mouseScrollFactor: 120
                    property int touchpadScrollFactor: 200
                }
                property JsonObject deadPixelWorkaround: JsonObject { // Hyprland leaves out 1 pixel on the right for interactions
                    property bool enable: false
                }
            }

            property JsonObject language: JsonObject {
                property string ui: "auto" // UI language. "auto" for system locale, or specific language code like "zh_CN", "en_US"
                property JsonObject translator: JsonObject {
                    property string engine: "auto" // Run `trans -list-engines` for available engines. auto should use google
                    property string targetLanguage: "auto" // Run `trans -list-all` for available languages
                    property string sourceLanguage: "auto"
                }
            }

            property JsonObject launcher: JsonObject {
                property list<string> pinnedApps: [ "org.kde.dolphin", "kitty", "cmake-gui"]
                // Desktop-entry IDs the launcher never lists.
                //
                // The SUPER menu is built from EVERY installed .desktop file,
                // which on this machine means one-off hardware configuration
                // dialogs (HDSPConf, HDSPMixer, HDAJackRetask, lstopo, the
                // NVIDIA control panel, the SchedExt GUI, the OpenJDK shells)
                // sit shoulder to shoulder with the apps you actually open.
                // Those are real programs and they do belong on the machine --
                // they just are not part of "my apps", and a menu that lists
                // them turns a launcher into an inventory.
                //
                // An explicit list rather than a category heuristic, because
                // categories do not separate them: kitty, Alacritty and btop
                // are all `System;`, and so is the kernel manager. Anything
                // cleverer than a list would have to be wrong about one of
                // those to get HDSPConf right. Edit this to taste -- it is
                // ordinary config and round-trips through the JsonAdapter.
                property list<string> hiddenApps: [
                    // Audio interfaces
                    "hdspconf", "hdspmixer", "hdajackretask",
                    // Hardware / driver panels
                    "lstopo", "nvidia-settings",
                    // Kernel tuning
                    "org.cachyos.scx-manager", "org.cachyos.KernelManager",
                    // Java runtime shells (the IDE launches these itself)
                    "jconsole-java17-openjdk", "jshell-java17-openjdk",
                    "java-java17-openjdk",
                    // Misc system furniture
                    "org.freedesktop.Xwayland", "avahi-discover",
                ]
                // When true, the hidden list is ignored and everything shows
                // again. One switch, so the list above is never in the way of
                // reaching something you actually need.
                property bool showAllApps: false
            }

            property JsonObject light: JsonObject {
                property JsonObject night: JsonObject {
                    property bool automatic: true
                    property string from: "19:00" // Format: "HH:mm", 24-hour time
                    property string to: "06:30"   // Format: "HH:mm", 24-hour time
                    property int colorTemperature: 5000
                }
            }

            property JsonObject lock: JsonObject {
                // The lock is this shell's own now -- a full-screen Overlay-layer
                // surface (see modules/common/panels/lock/LockScreen.qml) -- and the
                // `useHyprlock` switch that chose between that and a separate
                // hyprlock process went with hyprlock itself. Note what this is NOT:
                // it is not a WlSessionLock, which is still pinned off on purpose
                // (Quickshell hot-reloads its whole QML tree on any watched file
                // change, which killed the session-lock surface mid-lock). A layer
                // surface has no such contract with the compositor.
                // See the lock screen's templates in services/LoginLayouts.qml --
                // the lock and the login are one screen, so there is nothing about
                // its shape to choose here.
                property bool launchOnStartup: false
                property JsonObject blur: JsonObject {
                    property bool enable: true
                    property real radius: 100
                    property real extraZoom: 1.1
                }
                property bool centerClock: true
                property bool showLockedText: true
                property JsonObject security: JsonObject {
                    property bool unlockKeyring: true
                    property bool requirePasswordToPower: false
                }
                property bool materialShapeChars: true
            }

            property JsonObject media: JsonObject {
                // Attempt to remove dupes (the aggregator playerctl one and browsers' native ones when there's plasma browser integration)
                property bool filterDuplicatePlayers: true
            }

            property JsonObject networking: JsonObject {
                property string userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36"
            }

            property JsonObject notifications: JsonObject {
                property int timeout: 7000
                // Play a sound when a notification arrives. It was silent
                // before (nothing in the shell ever asked for a sound), which
                // read as "the audio stack is broken" while YouTube played fine.
                property bool sound: true
                // ── Apps the user has muted ──
                // A list of names, not a JsonObject: the config adapter DROPS
                // any key inside a JsonObject that is not declared here (see the
                // note on declared keys above), and apps are discovered at runtime, so
                // there is nothing to declare. Stored as the app's own display
                // name; matching is by normalized identity
                // (NotificationUtils.normalizeAppIdentity), because one app
                // spells itself three ways -- name, desktop entry, icon path.
                //
                // Written from Settings > Notifications, read by
                // services/Notifications.qml in the shell process.
                property list<string> mutedApps: []
                property JsonObject monitor: JsonObject {
                    property bool enable: false
                    property string name: "" // Name of the monitor to show notifications on, like "eDP-1". Find out with 'hyprctl monitors' command
                }
            }

            property JsonObject osd: JsonObject {
                property int timeout: 1000
            }

            property JsonObject osk: JsonObject {
                property string layout: "qwerty_full"
                property bool pinnedOnStartup: false
            }

            property JsonObject overlay: JsonObject {
                property bool openingZoomAnimation: true
                property bool darkenScreen: true
                property real clickthroughOpacity: 0.8
                property JsonObject floatingImage: JsonObject {
                    property string imageSource: "https://media.tenor.com/H5U5bJzj3oAAAAAi/kukuru.gif"
                    property real scale: 0.5
                }
            }

            property JsonObject overview: JsonObject {
                property bool enable: true
                property real scale: 0.18 // Relative to screen size
                // One row is the horizontal strip: desktops side by side, which
                // is the shape SUPER+Tab is designed around. The count is a
                // maximum -- the grid only draws the desktops that exist plus one
                // empty tile, so these numbers do not create empty desktops.
                property real rows: 1
                property real columns: 10
                property bool orderRightLeft: false
                property bool orderBottomUp: false
                property bool centerIcons: true
            }

            property JsonObject regionSelector: JsonObject {
                property JsonObject targetRegions: JsonObject {
                    property bool windows: true
                    property bool layers: false
                    property bool content: true
                    property bool showLabel: false
                    property real opacity: 0.3
                    property real contentRegionOpacity: 0.8
                    property int selectionPadding: 5
                }
                property JsonObject rect: JsonObject {
                    property bool showAimLines: true
                }
                property JsonObject circle: JsonObject {
                    property int strokeWidth: 6
                    property int padding: 10
                }
                property JsonObject annotation: JsonObject {
                    property bool useSatty: false
                }
            }

            property JsonObject resources: JsonObject {
                // Short enough that the readout keeps up with what you are doing;
                // reading /proc twice a second costs nothing.
                // 2 s, not 1 s: every sample repaints the bar's numbers, and each
                    // repaint is a wake-up for the display chip. Twice the interval is
                    // half the wake-ups for a readout nobody watches that closely.
                    property int updateInterval: 2000
                property int historyLength: 60
            }

            property JsonObject tray: JsonObject {
                // FALSE, where the dock and the workspaces default to true.
                //
                // This one is not a style choice, it is a legibility
                // choice, and it was the reason the tray icons read as
                // "greyed out" rather than as coloured artwork. The
                // monochrome path is not a tint: it is a `Desaturate` at
                // 0.8 feeding a `ColorOverlay` of colOnLayer0 at 90%
                // opacity, i.e. 80% of the colour removed and then
                // mostly buried under a near-opaque wash on top. A
                // tray app publishes its real icon -- Discord sends one
                // 24x24 pixmap, Thunderbird a blue-and-white logo -- and
                // that pipeline throws the colour away and flattens the
                // contrast, so what reaches the eye is grey regardless of
                // what the icon actually contains.
                //
                // It is still a user setting and the settings panel still
                // exposes it; this only changes what a config that has
                // never touched the key starts with.
                property bool monochromeIcons: false
                property bool showItemId: false
                property bool invertPinnedItems: true // Makes the below a whitelist for the tray and blacklist for the pinned area
                property list<var> pinnedItems: [ "Fcitx" ]
                property bool filterPassive: true

                // Extra id/title substrings to treat as BACKGROUND SERVICE
                // NOISE, on top of the built-in list in services/TrayNoise.qml
                // (avahi, NetworkManager, portals, polkit, the distro package
                // managers and so on). Comma separated, case-insensitive.
                //
                // This is the escape hatch for the daemon that is not in the
                // built-in list. Matched against the same fields, so a single
                // word is usually enough:
                //   "foo-agent,foo-tray"
                //
                // Anything matched here joins the collapsible "Advanced"
                // group in the tray card instead of the main grid. Nothing is
                // ever hidden outright -- it is all still there, one click
                // further away.
                property string extraServicePatterns: ""

                // Which apps get MINIMIZED TO THE TRAY instead of closed:
                // a map of Hyprland window class -> true.
                //
                // It is a map, not a list of enabled names, because the key
                // an app is known by is its window class and that is not the
                // same string in every place: the desktop entry id, the tray
                // item's id and the window class differ often enough
                // (org.mozilla.Thunderbird / thunderbird /
                // org.mozilla.Thunderbird) that a list would need three
                // parallel spellings and a rule for which one to match.
                //
                // EMPTY. This used to default Thunderbird to on, so that the
                // compositor would park its window instead of closing it,
                // because the app cannot do that itself on Linux
                // (`mail.closeToTray` is Windows-only). That whole mechanism
                // has been removed at the user's request -- Thunderbird is a
                // normal desktop app with no tray icon -- so there is nothing
                // for this map to enable. It is kept as an empty map so an
                // older persisted config that still names Thunderbird has
                // somewhere to land, and so nothing has to be null-checked.
                property var closeToTray: ({})
            }

            property JsonObject musicRecognition: JsonObject {
                property int timeout: 16
                property int interval: 4
            }

            property JsonObject search: JsonObject {
                property int nonAppResultDelay: 30 // This prevents lagging when typing
                property string engineBaseUrl: "https://www.google.com/search?q="
                property list<string> excludedSites: ["quora.com", "facebook.com"]
                property bool sloppy: false // Uses levenshtein distance based scoring instead of fuzzy sort. Very weird.
                property JsonObject prefix: JsonObject {
                    property bool showDefaultActionsWithoutPrefix: true
                    property string action: "/"
                    property string app: ">"
                    property string clipboard: ";"
                    property string emojis: ":"
                    property string math: "="
                    property string shellCommand: "$"
                    property string webSearch: "?"
                }
                property JsonObject imageSearch: JsonObject {
                    property string imageSearchEngineBaseUrl: "https://lens.google.com/uploadbyurl?url="
                    property bool useCircleSelection: false
                }
            }

            property JsonObject sidebar: JsonObject {
                // Both sidebars' normal width. The left one still widens while
                // its chat is expanded (that is a different number, see
                // Appearance.sizes.sidebarWidthExtended) -- this is the resting
                // width you see when a sidebar is simply open.
                //
                // 480, up from 340. At 340 the panels were too narrow for what
                // they hold: the quick-toggle labels, the Wi-Fi and Bluetooth
                // rows and the calendar all ran into eliding or wrapping, and
                // the wide two-column parts (quick toggles, the top-bar pin
                // strip) had no room to breathe. 480 is the width a desktop
                // panel is normally given -- comfortably under a third of this
                // screen (1410 logical wide), still clearly a panel rather than
                // a drawer. It stays adjustable in Settings > Sidebars > Width
                // (240..560).
                property int width: 480
                property bool keepRightSidebarLoaded: true
                // Whether an open sidebar draws OVER a fullscreen window.
                //
                // A sidebar lives in the Top layer by default, and a fullscreen
                // client renders above every Top-layer surface -- which is why
                // opening one while a window was fullscreen looked like the
                // sidebar "did nothing": it was open, it was just underneath.
                //
                // On (default) the sidebar surfaces move to the Overlay layer,
                // so a sidebar you opened on purpose appears on top of the
                // fullscreen window. Off restores the old Top layer, where a
                // fullscreen window hides them completely.
                property bool showInFullscreen: true
                property JsonObject translator: JsonObject {
                    property bool enable: false
                    property int delay: 300 // Delay before sending request. Reduces (potential) rate limits and lag.
                }
                property JsonObject ai: JsonObject {
                    property bool textFadeIn: false
                }
                property JsonObject booru: JsonObject {
                    property bool allowNsfw: false
                    property string defaultProvider: "yandere"
                    property int limit: 20
                    property JsonObject zerochan: JsonObject {
                        property string username: "[unset]"
                    }
                }
                property JsonObject cornerOpen: JsonObject {
                    property bool enable: true
                    property bool bottom: false
                    property bool valueScroll: true
                    property bool clickless: false
                    property int cornerRegionWidth: 250
                    property int cornerRegionHeight: 5
                    property bool visualize: false
                    property bool clicklessCornerEnd: true
                    property int clicklessCornerVerticalOffset: 1
                }

                property JsonObject quickToggles: JsonObject {
                    property string style: "android" // Options: classic, android
                    property JsonObject android: JsonObject {
                        property int columns: 5
                        property list<var> toggles: [
                            { "size": 2, "type": "network" },
                            { "size": 2, "type": "bluetooth"  },
                            { "size": 2, "type": "tailscale" },
                            { "size": 1, "type": "idleInhibitor" },
                            { "size": 1, "type": "mic" },
                            { "size": 2, "type": "audio" },
                            { "size": 2, "type": "nightLight" },
                            // The compositor's anti-flashbang shader (upstream
                            // end-4's). Left click turns it on and off; right
                            // click switches the weak/strong strength.
                            { "size": 1, "type": "antiFlashbang" }
                        ]
                    }
                }

                property JsonObject quickSliders: JsonObject {
                    property bool enable: false
                    property bool showMic: false
                    property bool showVolume: true
                    property bool showBrightness: true
                }
            }

            property JsonObject screenRecord: JsonObject {
                // EMPTY = TEMPORARY, the same contract screenSnip has had all
                // along ("only copy to clipboard when empty"). A recording is
                // something you paste into a chat or an editor, so by default it
                // is put on the clipboard and kept in the cache, where the
                // recording script prunes it. It used to default to ~/Videos,
                // which meant every take ever recorded stayed on disk forever
                // (asked for 2026-10-22: "they should only be saved temp so i can
                // copy the video like a snip i can copy"). Set a path here to
                // keep every clip there instead.
                property string savePath: ""
            }

            property JsonObject screenSnip: JsonObject {
                property string savePath: "" // only copy to clipboard when empty
            }

            property JsonObject sounds: JsonObject {
                property bool battery: false
                property bool pomodoro: false
                property string theme: "freedesktop"
            }

            property JsonObject time: JsonObject {
                // https://doc.qt.io/qt-6/qtime.html#toString
                property string format: "hh:mm"
                property string shortDateFormat: "dd/MM"
                property string dateWithYearFormat: "dd/MM/yyyy"
                property string dateFormat: "ddd, dd/MM"
                property JsonObject pomodoro: JsonObject {
                    // One length. breakTime, longBreak and
                    // cyclesBeforeLongBreak went with the break phase: nothing
                    // read them any more, and leaving them in the schema only
                    // invites someone to set a break that cannot happen.
                    property int focus: 1500
                }
                property bool secondPrecision: false
            }

            property JsonObject updates: JsonObject {
                property bool enableCheck: true
                property int checkInterval: 120 // minutes
                property int adviseUpdateThreshold: 75 // packages
                property int stronglyAdviseUpdateThreshold: 200 // packages
            }
            
            property JsonObject wallpaperSelector: JsonObject {
                property bool useSystemFileDialog: false
            }
            
            property JsonObject windows: JsonObject {
                property bool showTitlebar: true // Client-side decoration for shell apps
                property bool centerTitle: true
            }

            property JsonObject hacks: JsonObject {
                property int arbitraryRaceConditionDelay: 20 // milliseconds
            }

            property JsonObject workSafety: JsonObject {
                property JsonObject enable: JsonObject {
                    property bool wallpaper: false
                    property bool clipboard: false
                }
                property JsonObject triggerCondition: JsonObject {
                    property list<string> networkNameKeywords: ["airport", "cafe", "college", "company", "eduroam", "free", "guest", "public", "school", "university"]
                    property list<string> fileKeywords: ["anime", "booru", "ecchi", "hentai", "yande.re", "konachan", "breast", "nipples", "pussy", "nsfw", "spoiler", "girl"]
                    property list<string> linkKeywords: ["hentai", "porn", "sukebei", "hitomi.la", "rule34", "gelbooru", "fanbox", "dlsite"]
                }
            }

            property JsonObject waffles: JsonObject {
                // Some spots are kinda janky/awkward. Setting the following to
                // false will make (some) stuff also be like that for accuracy. 
                // Example: the right-click menu of the Start button
                property JsonObject tweaks: JsonObject {
                    property bool switchHandlePositionFix: true
                    property bool smootherMenuAnimations: true
                    property bool smootherSearchBar: true
                }
                property JsonObject bar: JsonObject {
                    property bool bottom: true
                    property bool leftAlignApps: false
                }
                property JsonObject actionCenter: JsonObject {
                    property list<string> toggles: [ "network", "bluetooth", "easyEffects", "powerProfile", "idleInhibitor", "nightLight", "darkMode", "cloudflareWarp", "mic", "musicRecognition", "notifications", "onScreenKeyboard", "gameMode", "screenSnip", "colorPicker", "performance" ]
                }
                property JsonObject calendar: JsonObject {
                    property bool force2CharDayOfWeek: true
                }
            }
        }
    }
}

