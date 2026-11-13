pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.services
import qs.modules.common

/**
 * The anti-flashbang screen shader, driven as a Hyprland runtime option.
 *
 * The effect lives in `services/hyprlandAntiFlashbangShader/`: a compositor
 * shader that runs every frame. It counts how much of the frame is blank white
 * and how bright the frame is on average, and only when both say "this screen has
 * gone white" does it lay black over the frame -- uniformly, so whatever is on
 * screen keeps its contrast and colours. A window carrying content, a lighter
 * page, a photo, a terminal: the gate stays shut and they are drawn untouched.
 * Because it runs inside the compositor, on the frame being drawn, it cannot be
 * flashed through the way a layer-shell sheet can: there is no frame in which the
 * white is shown undimmed, and no timer between the flash and the dimming.
 *
 * LEVELS. Three of them, kept from upstream: off, weak, strong. The sidebar
 * button is a three-way switch -- one left click per step, weak -> strong ->
 * off -> weak (`toggle()` walks them, so there is no "right click to reach the
 * other strength" to remember). Weak takes a visible step off a blank-white frame
 * (1.00 -> 0.85); strong is the deeper step (1.00 -> 0.75) and is still a dim,
 * never a wash that turns white content grey. Both are reachable from a script
 * too (`set("strong")`, `cycle()`).
 *
 * Turning it off and on again starts at weak, so the switch never hands back a
 * level nobody asked for on that click.
 *
 * WHY THE LEVEL IS HELD IN THIS FILE, NOT READ BACK PER CLICK. Hyprland keeps
 * the option; asking it is an async `hyprctl` round trip, so a state derived
 * only from the readback is stale for the tens of milliseconds after a click.
 * Two quick clicks then both decided from the same stale state -- the second one
 * asked for the level the first had already set, and the switch looked stuck.
 * So `intent` is the answer to "which level", updated synchronously by the click
 * and persisted; the readback is what keeps the COMPOSITOR honest (see
 * reconcile), and is not consulted to decide what the next click should do. Writes
 * are queued rather than fired at a Process that may still be running, for the
 * same reason: a click that arrives mid-write used to be dropped.
 *
 * WHY THIS FILE IS NOT VERBATIM UPSTREAM. Upstream writes the option with
 * `HyprlandConfig.setMany`, i.e. `hyprctl keyword`, and reads it with
 * `HyprlandConfigOption`. Neither works on this fork:
 *
 *   * this Hyprland parses a Lua config, so `hyprctl keyword` answers
 *     "keyword can't work with non-legacy parsers. Use eval." and does nothing;
 *   * `HyprlandConfig` (the singleton `HyprlandConfigOption` calls into) is not
 *     in this tree at all -- only the option reader is, and it throws on every
 *     set.
 *
 * So the two ends of upstream's design are replaced by the equivalents that do
 * work here: writes go through `hyprctl eval 'hl.config({...})'`, reads through
 * `hyprctl getoption -j`. The public surface upstream's toggle expects --
 * enabled / weak / cycle() -- is kept exactly.
 *
 * `debug:damage_tracking = 1` comes with the shader on purpose: with full damage
 * tracking the compositor can redraw a region from a stale buffer and the patch
 * of screen keeps the previous frame's brightness for a moment, which reads as
 * exactly the flicker the shader is meant to remove. It is set alongside the
 * shader and put back to 2 (the default) when the shader comes off.
 */
Singleton {
    id: root

    readonly property string shaderPath: Quickshell.shellPath("services/hyprlandAntiFlashbangShader/anti-flashbang.glsl")
    readonly property string weakShaderPath: Quickshell.shellPath("services/hyprlandAntiFlashbangShader/anti-flashbang-weak.glsl")

    // The level that was asked for. Everything the UI shows comes from this, so a
    // click is reflected in the icon at the same instant it is made.
    property string intent: "strong"

    // What the COMPOSITOR holds, as last read back. Only used to notice drift --
    // a config reload resetting the option, or a restart dropping it.
    property string activePath: ""

    readonly property bool enabled: intent !== "off"
    readonly property bool weak: intent === "weak"

    // ── The video hold ───────────────────────────────────────────────────
    //
    // The shader's gate asks "has this frame gone blank white", and a VIDEO is
    // the one thing that answers that constantly: a cut to a white slide, a
    // bright sky, an explosion, a title card blinking on and off. Each of those
    // is a legitimate white frame and each one gets dimmed, so watching a film
    // turns into a fight with the effect that is meant to protect you.
    //
    // So while media is PLAYING, the level is held at off. `intent` is left
    // untouched -- it is the user's setting, it is what the sidebar and the
    // persistence file keep, and it must survive the film ending -- and only
    // what is written to the compositor changes. Playback stopping puts the
    // remembered level straight back.
    //
    // Which players count. MPRIS cannot tell a video from an audio stream: a
    // browser publishes the same one title for a YouTube video and for a web
    // radio station. The list below is therefore by APP -- browsers and video
    // players suspend, everything else (Spotify, the shell's own iiMusic, mpd,
    // cmus) is left alone, because those never put white frames on screen. The
    // cost of the heuristic is that music playing in a browser also suspends
    // the shader; the cost of the opposite default is the effect glitching
    // through every video, which is what was reported.
    readonly property var videoApps: [
        "brave", "chromium", "chrome", "vivaldi", "opera", "edge",
        "firefox", "zen", "librewolf", "waterfox",
        "mpv", "vlc", "celluloid", "haruna", "totem", "smplayer",
        "kodi", "freetube", "qutebrowser", "epiphany"
    ]

    function isVideoPlayer(player) {
        const identity = String(player?.identity ?? "").toLowerCase();
        // The bus name carries an instance suffix (…MediaPlayer2.brave.instance2189035),
        // so it is matched from the start rather than by containment.
        const marker = "org.mpris.mediaplayer2.";
        const bus = String(player?.dbusName ?? "").toLowerCase();
        const tail = bus.indexOf(marker) >= 0
            ? bus.slice(bus.indexOf(marker) + marker.length).split(".")[0]
            : "";
        for (const name of root.videoApps) {
            if (identity.includes(name))
                return true;
            if (tail !== "" && tail.startsWith(name))
                return true;
        }
        return false;
    }

    // Read from the MPRIS map itself, not from MprisController's filtered array.
    //
    // That array is a `var` rebuilt by a filter, and it was measured here
    // arriving late at its first read: after a shell reload the shader stayed on
    // for the whole first video even though the bus said "Playing", while every
    // pause/play transition after that landed correctly. A hold that arrives
    // late is the glitch this exists to prevent, so the answer is recomputed
    // BOTH ways -- event-driven when the controller's array changes (the common
    // case, immediate) and on a slow poll (the arrival, and any signal a given
    // Quickshell build does not emit).
    property var videoPlayers: []
    property bool videoPlaying: false

    function refreshVideoHold() {
        const playing = (Mpris.players.values ?? [])
            .filter(p => p?.isPlaying === true && root.isVideoPlayer(p));
        root.videoPlayers = playing;
        // Assigning the same boolean does not emit, so a poll that changes
        // nothing costs nothing: no write, no re-apply.
        root.videoPlaying = playing.length > 0;
    }

    Timer {
        interval: 1500
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refreshVideoHold()
    }

    Connections {
        target: MprisController
        function onPlayingPlayersChanged() { root.refreshVideoHold(); }
    }
    readonly property string videoName:
        root.videoPlaying ? String(root.videoPlayers[0]?.identity ?? "") : ""

    // Cleared when the user sets a level BY HAND during playback -- a click that
    // visibly does nothing reads as a broken switch -- and re-armed when the
    // video stops, so the next one holds again.
    property bool autoHold: true
    readonly property bool heldByVideo: root.videoPlaying && root.autoHold
    onVideoPlayingChanged: if (!root.videoPlaying) root.autoHold = true
    onHeldByVideoChanged: root.apply()

    // What the compositor should hold: the user's level, or nothing while a
    // video is up. Every write and every reconcile reads THIS, never `intent`
    // directly, so the two can never disagree.
    readonly property string effectivePath:
        root.heldByVideo ? "" : root.pathFor(root.intent)

    readonly property var levels: ({ "off": "", "weak": weakShaderPath, "strong": shaderPath })

    Component.onCompleted: {
        root.intent = Persistent.states?.antiFlashbang ?? "strong";
        root.refreshVideoHold();
        root.refresh();
    }

    function pathFor(level) {
        return root.levels[level] ?? "";
    }

    // The switch: a three-way cycle, weak -> strong -> off -> weak. The sidebar
    // button calls this, so one button walks the whole range instead of needing
    // a second gesture for the second strength.
    function toggle() { root.cycle(); }

    // The levels themselves, for scripts.
    function enable() { root.setLevel("weak"); }
    function enableWeak() { root.setLevel("weak"); }
    function disable() { root.setLevel("off"); }

    // Off -> weak -> strong -> off, upstream's cycle. This is the button.
    function cycle() {
        root.setLevel(root.intent === "off" ? "weak" : (root.intent === "weak" ? "strong" : "off"));
    }

    // Left/right of a pair, for scripts and the IPC: jump between the two
    // strengths without going through off. The button itself is the three-way
    // switch above.
    function alternate() {
        root.setLevel(root.intent === "weak" ? "strong" : "weak");
    }

    function setLevel(level) {
        // Asked for by hand while a video plays: honour it for the rest of that
        // playback instead of having the hold undo the click on the next frame.
        if (root.videoPlaying)
            root.autoHold = false;
        root.intent = level;
        if (Persistent.states)
            Persistent.states.antiFlashbang = level;
        root.apply();
    }

    // ── Writing: queued, one process at a time ───────────────────────────
    // A Process cannot have its command changed while it runs, so a second click
    // during the first click's `hyprctl` used to be swallowed. The newest wanted
    // path is held here and written as soon as the running one exits; only the
    // last one matters, the ones in between are already superseded.
    property bool hasQueued: false

    // No path argument, deliberately: the path is read from `effectivePath` when
    // the queued write actually runs, so a video starting or stopping between
    // the click and the write cannot be undone by the click's older answer.
    function apply() {
        root.hasQueued = true;
        root.drainWrites();
    }

    function drainWrites() {
        if (writeProc.running || !root.hasQueued)
            return;
        const path = root.effectivePath;
        root.hasQueued = false;
        const shader = JSON.stringify(path); // a Lua string literal
        const damage = path === "" ? 2 : 1;
        writeProc.command = ["hyprctl", "eval",
            `hl.config({ decoration = { screen_shader = ${shader} }, debug = { damage_tracking = ${damage} } })`];
        writeProc.running = true;
    }

    // ── Reading: queued too ──────────────────────────────────────────────
    // `running = false` immediately followed by `running = true` is a restart
    // that Qt is free to coalesce; the read then simply never happens and the
    // readback stays stale forever. One flag, one restart, from onExited.
    property bool hasQueuedRead: false

    function refresh() {
        root.hasQueuedRead = true;
        root.drainReads();
    }

    function drainReads() {
        if (readProc.running || !root.hasQueuedRead)
            return;
        root.hasQueuedRead = false;
        readProc.running = true;
    }

    // The compositor does not always hold what was asked for: a config reload
    // resets options to the config's own values, and a Hyprland restart takes a
    // runtime option with it. Whenever the shader has been expected and has gone
    // missing it is put back. A shader that is someone else's is left alone for
    // as long as we are off, so this never stomps another program's effect.
    function reconcile() {
        const want = root.effectivePath;
        if (want === root.activePath)
            return;
        const foreign = root.activePath !== "" && root.activePath !== root.shaderPath
            && root.activePath !== root.weakShaderPath;
        if (foreign && want === "")
            return;
        root.apply();
    }

    Process {
        id: readProc
        command: ["hyprctl", "getoption", "-j", "decoration:screen_shader"]
        onExited: root.drainReads() // a refresh asked for while this ran
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const option = JSON.parse(text);
                    const raw = (option.str ?? "").trim();
                    // `hyprctl getoption -j` spells an unset string as the
                    // literal "[[EMPTY]]", not as "". Left as-is it reads as
                    // some OTHER program's shader, which made reconcile() stand
                    // down after a config reload and leave the screen undimmed
                    // while the toggle said "on".
                    root.activePath = raw === "[[EMPTY]]" ? "" : raw;
                    root.reconcile();
                } catch (e) {
                    console.log(`[HyprlandAntiFlashbangShader] Could not read decoration:screen_shader: ${e}\n  ${text.trim()}`);
                }
            }
        }
    }

    Process {
        id: writeProc
        // Read back rather than trust the exit code: `hyprctl eval` answers "ok"
        // for a call that changed nothing, and it is the option that decides
        // whether the screen is dimmed.
        onExited: {
            if (root.hasQueued)
                root.drainWrites();
            else
                root.refresh();
        }
    }

    // Cheap drift check, and only while the shader is supposed to be on: one
    // getoption every few seconds. This is what notices a Hyprland restart
    // taking the shader with it.
    Timer {
        interval: 5000
        repeat: true
        // Only while something is supposed to BE on screen: during a video hold
        // the answer is "nothing", and there is no drift to chase.
        running: root.effectivePath !== ""
        onTriggered: root.refresh()
    }

    IpcHandler {
        target: "antiflashbang"

        function cycle(): void { root.cycle(); }
        function toggle(): void { root.toggle(); }
        function alternate(): void { root.alternate(); }
        function set(level: string): void { root.setLevel(level); }
        function status(): string {
            return `${root.intent} (compositor holds "${root.activePath}")`
                + (root.heldByVideo ? ` | held off for ${root.videoName || "video"}` : "");
        }
    }
}
