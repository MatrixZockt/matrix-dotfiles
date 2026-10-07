pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root
    property alias states: persistentStatesJsonAdapter
    property string fileDir: Directories.state
    property string fileName: "states.json"
    property string filePath: `${root.fileDir}/${root.fileName}`

    property bool ready: false
    property string previousHyprlandInstanceSignature: ""
    property bool isNewHyprlandInstance: previousHyprlandInstanceSignature !== states.hyprlandInstanceSignature

    onReadyChanged: {
        root.previousHyprlandInstanceSignature = root.states.hyprlandInstanceSignature
        root.states.hyprlandInstanceSignature = Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || ""
    }

    Timer {
        id: fileReloadTimer
        interval: 100
        repeat: false
        onTriggered: {
            persistentStatesFileView.reload()
        }
    }

    Timer {
        id: fileWriteTimer
        interval: 100
        repeat: false
        onTriggered: {
            persistentStatesFileView.writeAdapter()
        }
    }

    FileView {
        id: persistentStatesFileView
        path: root.filePath

        watchChanges: true
        onFileChanged: fileReloadTimer.restart()
        onAdapterUpdated: fileWriteTimer.restart()
        onLoaded: root.ready = true
        onLoadFailed: error => {
            console.log("Failed to load persistent states file:", error);
            if (error == FileViewError.FileNotFound) {
                fileWriteTimer.restart();
            }
        }

        adapter: JsonAdapter {
            id: persistentStatesJsonAdapter

            property string hyprlandInstanceSignature: ""

            // Which prepared colour template is currently applied, set from the
            // Themes page in the settings app. Empty means "following the
            // wallpaper", which is how the shell behaved before templates
            // existed. Kept here rather than in Config because no other part of
            // the shell reads it -- it exists so the picker can show you which
            // one is live.
            property string themeTemplate: ""
            property bool themeTemplateDark: true
            property string loginLayout: "" // SDDM login screen layout slug; composed by set-login-layout.sh

            // Where the wallpaper picker sends the picture you choose:
            // "desktop" (switch the wallpaper and regenerate the colours) or
            // "lock" (only the lock screen's picture). Sticky, because picking
            // a lock picture is usually several in a row.
            property string wallpaperTarget: "desktop"

            property JsonObject ai: JsonObject {
                property string model: "gemini-2.5-flash"
                property real temperature: 0.5
            }

            property JsonObject cheatsheet: JsonObject {
                property int tabIndex: 0
            }

            // Which tab the left sidebar was last showing.
            //
            // A sidebar that reopens on To Do every time, no matter which tab
            // you left it on, is a small papercut on every single open: you
            // close it, do something else, come back, and have to find your
            // way back to Music again. The cheatsheet has done this for its
            // own tabs for a while; the left sidebar never did, which is why
            // it is the one that felt wrong.
            property JsonObject sidebarLeft: JsonObject {
                property int tabIndex: 0
            }

            // The music app's settings. Every value here was verified to be a
            // REAL, runtime-settable property on the mpv daemon this machine
            // runs (mpv 0.41) -- the obvious names are not the right ones:
            // `audio-replay-gain` and `gapless-playback` are both rejected
            // with "property not found", while `replaygain` and `gapless-audio`
            // work. Guessing here would have shipped a settings page whose
            // controls silently did nothing.
            property JsonObject music: JsonObject {
                // ── Playback ──
                // "no" | "track" | "album" — replay-gain mode. Album is the
                // right default for a library: it keeps the whole record at
                // one level instead of making quiet tracks jump up.
                property string replayGain: "album"
                property bool gapless: true
                // Crossfade in seconds, 0 = off. Implemented with mpv's `af`
                // (a lavfi afade pair), which is why it only reads cleanly
                // where the duration is known.
                property real crossfade: 0
                // Volume to restore at login, as a percentage of volume-max.
                property int startVolume: 80
                // Whether the volume-max itself is raised above 100, for people
                // who want headroom on a laptop speaker.
                property int volumeMax: 100

                // ── Library ──
                // Where "Save" on an online result writes, relative to HOME.
                property string downloadFolder: "Music/Spotify/Audius"
                // Re-scan the library the moment a download finishes, so the
                // new file appears without a manual refresh.
                property bool rescanAfterDownload: true
                // Show the online search panel when the music app opens.
                property bool onlinePanelByDefault: false

                // ── Online source ──
                // Audius is keyless, but it uses this as the caller identity
                // for rate limiting, so it should name this machine.
                property string onlineAppName: "hyprland-music"

                // ── Recent playlists ──
                // The music tab's top strip shows the last few playlists
                // actually played, most recent first. playPlaylist() records
                // the name here; the strip renders at most five, so older
                // entries fall off the end.
                property var recentPlaylists: []

                // ── Where the library was left ──
                //
                // The playlist the sidebar had selected, and the song it was
                // on. Both are here so that closing the sidebar and opening it
                // again lands on the same place instead of resetting the
                // selection to the first playlist alphabetically and leaving
                // nothing highlighted.
                //
                // `lastSongPath` is a PATH, matched the same way the live
                // highlight matches (see MusicTab's `currentPath`): by title
                // it would be ambiguous across folders, and the title is also
                // the one field a stopped player keeps reporting.
                property string selectedPlaylist: ""
                property string lastSongPath: ""
            }

            // Bluetooth's own version of the same idea, and for the same
            // reason it exists for Wi-Fi: the quick panel should be able to
            // offer a device you used yesterday without making you go looking
            // for it. `BluetoothStatus.recordKnownDevices()` writes an entry
            // here the moment a device pairs or connects; the panel renders
            // the ones that are not in the current device list.
            //
            // Array of { mac, name, lastSeen }. `lastSeen` is a Unix ms stamp
            // and is what orders the list -- the adapter's own paired list has
            // no notion of recency, so without it "recent" would just be
            // alphabetical like everything else.
            property var bluetoothHistory: []

            // The file manager's Places rail: the paths you have REMOVED from
            // the rail, and the ones you have PINNED to the top. Paths, not
            // indices -- the rail's order shifts as soon as anything is
            // pinned or hidden, so an index would silently start meaning a
            // different folder after the next change.
            //
            // They have to be DECLARED here. An adapter only serialises
            // properties it knows about, so assigning
            // `Persistent.states.someNewKey` on an undeclared name does
            // nothing at all: the value changes in memory for as long as the
            // app lives and is silently dropped on the next write.
            property var fileManagerHiddenPlaces: []
            property var fileManagerPinnedPlaces: []

            property JsonObject sidebar: JsonObject {
                property JsonObject bottomGroup: JsonObject {
                    property bool collapsed: false
                    property int tab: 0
                }
            }

            property JsonObject booru: JsonObject {
                property bool allowNsfw: false
                property string provider: "yandere"
            }

            property JsonObject idle: JsonObject {
                property bool inhibit: false
            }

            property JsonObject overlay: JsonObject {
                property list<string> open: ["crosshair", "recorder", "volumeMixer", "resources"]
                property JsonObject crosshair: JsonObject {
                    property bool pinned: false
                    property bool clickthrough: true
                    property real x: 827
                    property real y: 441
                    property real width: 250
                    property real height: 100
                }
                property JsonObject floatingImage: JsonObject {
                    property bool pinned: false
                    property bool clickthrough: false
                    property real x: 1650
                    property real y: 390
                    property real width: 0
                    property real height: 0
                }
                property JsonObject fpsLimiter: JsonObject {
                    property bool pinned: false
                    property bool clickthrough: false
                    property real x: 1570
                    property real y: 615
                    property real width: 280
                    property real height: 80
                }
                property JsonObject recorder: JsonObject {
                    property bool pinned: false
                    property bool clickthrough: false
                    property real x: 80
                    property real y: 80
                    property real width: 350
                    property real height: 130
                }
                // The hardware monitor. Clickable by default: it is a list you
                // are meant to click through, and having it start as a picture
                // that ignores the pointer is how "I cannot press on the other
                // hardware" happened -- the tabs were there, the clicks went
                // straight through the card to the window behind it.
                property JsonObject resources: JsonObject {
                    property bool pinned: false
                    property bool clickthrough: false
                    property real x: 1320
                    property real y: 700
                    // Big enough for the task manager's widest page (the process
                    // table's six columns and the rail beside them). The card is
                    // clamped up to its own minimum anyway, so an older, smaller
                    // saved size still opens at a usable one.
                    property real width: 880
                    property real height: 480
                    property string selectedKey: "cpu"
                    // Which page was last being read: processes, performance or
                    // hardware.
                    property string section: "processes"
                }
                property JsonObject volumeMixer: JsonObject {
                    property bool pinned: false
                    property bool clickthrough: false
                    property real x: 80
                    property real y: 280
                    property real width: 350
                    property real height: 600
                    property int tabIndex: 0
                }
                property JsonObject notes: JsonObject {
                    property bool pinned: false
                    property bool clickthrough: true
                    property real x: 1400
                    property real y: 42
                    property real width: 460
                    property real height: 330
                }
            }

            property JsonObject timer: JsonObject {
                property JsonObject pomodoro: JsonObject {
                    // isBreak and cycle are gone with the break phase. Old
                    // values for them stay in the state file on disk until
                    // something rewrites it; they are simply never read.
                    property bool running: false
                    property int start: 0
                }
                property JsonObject stopwatch: JsonObject {
                    property bool running: false
                    property int start: 0
                    property list<var> laps: []
                }
            }
        }
    }
}
