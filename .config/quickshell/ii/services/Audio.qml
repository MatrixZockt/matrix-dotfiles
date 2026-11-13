pragma Singleton
pragma ComponentBehavior: Bound
import qs.modules.common
import qs.services
import QtQuick
import Quickshell
// FileView and Process, for the remembered per-app volumes below.
import Quickshell.Io
import Quickshell.Services.Pipewire
// `DesktopEntries` is deliberately NOT imported: this build does not ship the
// `Quickshell.Services.DesktopEntries` module, and importing it took the whole
// configuration down ("module ... is not installed", which surfaced as a
// cascade of unrelated "Type unavailable" errors from shell.qml). Every other
// file here reaches it without an import, because Quickshell puts the service
// in scope for them; adding the import is the one way to break it.

/**
 * A nice wrapper for default Pipewire audio sink and source.
 */
Singleton {
    id: root

    // Misc props
    property bool ready: Pipewire.defaultAudioSink?.ready ?? false
    property PwNode sink: Pipewire.defaultAudioSink
    property PwNode source: Pipewire.defaultAudioSource
    // ── One scale for volume, and its end is 100% ─────────────────────────
    //
    // `hardMaxValue` is the sink value the shell calls 100%: 2.0, which is what
    // PipeWire accepts on this machine and what the loud end has always been.
    // What changed is only the NAME it is called. The sink used to be read as
    // "1.0 = 100%", so the shell displayed up to 200% and every surface had to
    // know that its percentage was really a fraction of two -- which is how the
    // bar could say "200%" at all.
    //
    // Now there is ONE scale, 0..1, whose top is `hardMaxValue`, and the two
    // functions below (`currentVolume` / `setSinkVolume`) are the only places
    // that know the ratio. Nothing in the UI can read above 100%, and the whole
    // loud range is still reachable -- rescaled, not capped: "100%" now means
    // what "200%" used to.
    readonly property real hardMaxValue: 2.00 // People keep joking about setting volume to 5172% so...
    property string audioTheme: Config.options.sounds.theme
    // The shell's own volume fraction (0..1, 100% = `hardMaxValue`). A MIRROR,
    // never a write path: the sink is the only thing that reaches PipeWire, so
    // writes go through `setSinkVolume` and this follows them.
    property real value: root.currentVolume()
    
    // Both of these are called from bindings while PipeWire is churning -- a
    // device appearing or leaving, the default sink switching. In that window a
    // node can be null or not yet populated, and reading through it threw
    // "Cannot read property 'properties' of null" on every such change. Guarded
    // rather than assumed: the display name is never worth an exception.
    function friendlyDeviceName(node) {
        return (node?.nickname || node?.description || Translation.tr("Unknown"));
    }
    function appNodeDisplayName(node) {
        return (node?.properties?.["application.name"] || node?.description || node?.name || Translation.tr("Unknown"))
    }

    // ── The icon on an app's audio row ──────────────────────────────────
    //
    // The mixer used to draw whatever `application.icon-name` said and, when
    // the stream did not say anything (most do not), fall straight to the
    // generic app glyph -- so the rows were a column of identical placeholder
    // icons, which is the one thing a list of apps must not be. `node.name` is
    // no better: it is a stream name, not a desktop id.
    //
    // Three steps, cheapest first, each one better evidence than the last:
    //   1. what the app itself claims (`application.icon-name`);
    //   2. the desktop entry for its app id or app name -- "brave",
    //      "org.mozilla.firefox", "Spotify" all resolve through the same
    //      heuristic the switcher and the dock use for running windows;
    //   3. the window that is actually playing this stream, matched on class,
    //      for the app whose stream metadata says nothing useful at all.
    //
    // An empty string means "nothing found", and the caller keeps its own
    // generic fallback for that.
    function appNodeIconName(node) {
        const props = node?.properties ?? {};
        const claimed = String(props["application.icon-name"] ?? "").trim();
        if (claimed !== "" && AppSearch.iconExists(claimed))
            return claimed;

        for (const key of appNodeIdentityKeys(node)) {
            const entry = DesktopEntries.heuristicLookup(key);
            if (entry?.icon)
                return entry.icon;
            const guessed = AppSearch.guessIcon(key);
            if (AppSearch.iconExists(guessed))
                return guessed;
        }
        return "";
    }

    // The names a stream might be known by, best first. Anything under three
    // characters is dropped: "mpv" is a real app but so is a stray two-letter
    // token, and a wrong icon is worse than the generic one.
    function appNodeIdentityKeys(node) {
        const props = node?.properties ?? {};
        const raw = [
            props["application.id"],
            props["application.name"],
            props["application.process.binary"],
            node?.name ?? "",
        ];
        const out = [];
        for (const item of raw) {
            const key = String(item ?? "").trim().toLowerCase();
            if (key.length >= 3 && !out.includes(key))
                out.push(key);
        }
        return out;
    }

    // The class of the window playing this stream, or "" when no window
    // matches. A stream has no idea which window it belongs to, so this is a
    // name match -- and deliberately a conservative one: an exact class match,
    // then a class that starts with the app's name. A "contains" match would
    // hand a terminal's icon to a stream belonging to the terminal INSIDE it.
    function appNodeWindowClass(node) {
        const clients = HyprlandData.windowList ?? [];
        if (clients.length === 0)
            return "";
        for (const key of appNodeIdentityKeys(node)) {
            const hit = clients.find(c => String(c?.class ?? "").toLowerCase() === key)
                ?? clients.find(c => String(c?.class ?? "").toLowerCase().startsWith(key));
            if (hit)
                return String(hit.class);
        }
        return "";
    }

    // ── Every app that can be regulated, playing or not ──────────────────
    //
    // The mixer used to list `Pipewire.nodes` filtered down to streams, which
    // is the same list as "apps making a sound at this instant": an app with
    // no live stream has no node, so it had no row, so its volume could not
    // be set before it played. That is precisely the moment you want to set
    // it -- the game you are about to start, the browser tab you know is going
    // to start playing on its own.
    //
    // So the rows are built from two sources and merged on the app key: the
    // live streams, and every app that has a window (plus the local music
    // daemon, which is a service and never has one). An app with no stream is
    // not a decoration either -- its slider writes the shell's own memory of
    // that app's volume, and that memory is applied to the stream the moment
    // the app does make a sound (see applyRememberedVolumes).
    //
    // Input is deliberately NOT expanded this way. A capture device that does
    // not exist cannot be pre-set: there is no node to write to, and a
    // remembered microphone volume for an app that has never opened a
    // microphone is a control that cannot do anything. The input tab stays a
    // list of what is actually capturing.
    // NOT a binding. That is the whole point of this property.
//
// It used to be `readonly property var mixerApps: root.buildMixerApps()`,
// which makes the list a live dependency on `Pipewire.nodes.values`. QML then
// re-evaluated it INSIDE the same event that created or unbound a node -- and
// `buildMixerApps()` walks that very list reading `node.properties` off each
// entry. A node that has just been unbound is still in the list for a moment
// after it is gone, so the walk reads freed memory and takes the entire shell
// down with a SIGSEGV. There is no QML error first and nothing to catch:
//
//   Unbinding object PwNode(id=97/bound)
//   QML Audio: Binding loop detected for property "mixerApps"
//   Enumerating props param for PwNode(id=97/unbound)      <- segfault here
//
// Identical in every crash, and it predates the system-sounds work: this fires
// on ANY node churn, so mpv starting, a browser tab beginning to play, or the
// shell's own chime all reach it. Reducing how often we churn nodes only makes
// it rarer; it cannot make it safe.
//
// So the rebuild is moved OFF the change signal and onto a timer. By the time
// this runs, PipeWire has finished the batch and the node list is settled, so
// there is nothing unbound in it to read. The list is a tenth of a second
// behind reality, which is invisible: a row's live volume comes off its own
// node through `PwObjectTracker`, not off this list.
property var mixerApps: []

// Debounced off the node model, then rebuilt on a settled list.
Connections {
    target: Pipewire.nodes
    function onValuesChanged() {
        mixerRebuild.restart();
    }
}

Timer {
    id: mixerRebuild
    interval: 250
    repeat: false
    onTriggered: {
        const t = Date.now();
        root.mixerApps = root.buildMixerApps();
        StatusSignal.perfMark("mixerBuild", Date.now() - t);
    }
}

// The music row's label carries the song name, and the song changes without
// any PipeWire node appearing or disappearing -- the same stream just carries
// different metadata. The node-count sweep above would never notice, so the
// row would keep naming the track it started with. Rebuild on the change
// instead, through the same debounce so a fast skip still only builds once.
Connections {
    target: MusicPlayer
    function onTrackTitleChanged() {
        mixerRebuild.restart();
    }
    function onHasTrackChanged() {
        mixerRebuild.restart();
    }
}

// A slow unconditional sweep as well, so the list is never stale for long even
// if the model's change signal is not delivered on this build -- the debounce
// above is an optimisation, not the only path.
Timer {
    interval: 800
    repeat: true
    running: true
    onTriggered: {
        // Only when the node COUNT moved. An unconditional sweep would
        // reassign `mixerApps` every 800ms and put a drag at the mercy of
        // whether the delegate was reused -- which is not something a drag
        // should be betting on. The debounced Connections above still catch
        // every real change; this is the net under it.
        const n = Pipewire.nodes.values.length;
        if (n !== root.mixerNodeCount) {
            root.mixerNodeCount = n;
            mixerRebuild.restart();
        }
    }
}

// The node count the fallback sweep last saw. Zero on purpose, so the first
// sweep always builds.
property int mixerNodeCount: 0

// The first build. Deferred rather than immediate so the shell's startup
// traffic has passed before the first walk, and the list is empty for a beat
// rather than crashing on startup.
Timer {
    interval: 1200
    running: true
    repeat: false
    onTriggered: root.mixerApps = root.buildMixerApps()
}

    function buildMixerApps() {
        // What the last rebuild produced, so an app that has not changed can be
        // handed back as the SAME object.
        //
        // This is not a micro-optimisation. The delegate declares
        // `required property var row`, so handing it a fresh object for a row
        // whose contents are identical destroys and recreates it -- and a
        // rebuild that lands mid-drag destroys the slider out from under the
        // pointer. That is why dragging the System Sounds row stopped
        // chimming: `pressed` never went false, because the item being
        // pressed ceased to exist before it could be released. Reusing the
        // object keeps the delegate, its slider and its drag all intact, and
        // the list is only allowed to churn when something really changed.
        const prev = root.mixerAppCache ?? new Map();
        const rows = new Map();
        const put = (key, patch) => {
            if (!key || key.length < 2)
                return;
            const existing = rows.get(key);
            // First source wins for identity (a stream knows its own app better
            // than a window class does); later sources only fill gaps and
            // upgrade the node from null to a live one.
            if (existing) {
                if (!existing.node && patch.node)
                    existing.node = patch.node;
                if (!existing.cls && patch.cls)
                    existing.cls = patch.cls;
                if (!existing.icon && patch.icon)
                    existing.icon = patch.icon;
                if (patch.music)
                    existing.music = true;
                if (!existing.title && patch.title)
                    existing.title = patch.title;
                return;
            }
            // Same app, same live node, same labels: keep the object that the
            // current delegate is already holding. `title` is part of the
            // comparison because it is part of the label: without it the
            // music row would be handed back with the song name it had three
            // tracks ago, still pointing at the current node.
            const old = prev.get(key);
            if (old && old.node === patch.node && old.name === patch.name
                && old.icon === patch.icon && old.live === patch.live
                && old.cls === patch.cls && old.title === patch.title) {
                if (patch.music)
                    old.music = true;
                if (patch.symbol !== undefined)
                    old.symbol = patch.symbol;
                old.title = patch.title;
                rows.set(key, old);
                return;
            }
            rows.set(key, patch);
        };

        // 1. The live streams.
        for (const node of root.outputAppNodes) {
            // The shell's own notification chime is a stream too, and it
            // belongs to the System Sounds row rather than to a row of its
            // own -- see isSystemSoundNode. Skipping it here is also what
            // stops the row being rebuilt out from under a drag of that
            // row's own slider.
            if (root.isSystemSoundNode(node))
                continue;
            const keys = root.appNodeIdentityKeys(node);
            const key = keys[0] ?? String(node?.name ?? "").toLowerCase();
            if (!key)
                continue;
            const cls = root.appNodeWindowClass(node);
            put(key, {
                key,
                node,
                cls,
                name: root.appDisplayName(node, keys, cls),
                icon: root.appIconName(node, keys, cls),
                music: root.isMusicApp(keys, cls),
                title: root.musicTitleFor(node),
                live: true,
            });
        }

        // 2. Every app with a window, whether or not it is audible.
        const classes = [];
        for (const win of (HyprlandData.windowList ?? [])) {
            const cls = String(win?.class ?? "");
            if (cls !== "" && !classes.includes(cls))
                classes.push(cls);
        }
        classes.sort();
        for (const cls of classes) {
            const key = cls.toLowerCase();
            const entry = DesktopEntries.heuristicLookup(cls);
            put(key, {
                key,
                node: null,
                cls,
                name: entry?.name ?? cls,
                icon: entry?.icon ?? "",
                music: root.isMusicApp([key], cls),
                live: false,
            });
        }

        // 3. The local music daemon: a service, so it has no window and no
        // stream while it is idle -- and it is exactly the app you want a row
        // for, since it is the thing that plays music on this machine all day.
        const musicKey = root.musicDaemonRowKey();
        if (musicKey !== "") {
            put(musicKey, {
                key: musicKey,
                node: null,
                cls: "",
                name: Translation.tr("Music"),
                icon: "",
                music: true,
                title: root.musicTitleFor(null),
                live: false,
            });
        }

        // 4. System sounds. See systemSoundsKey for why this is not an app
        // row like the others.
        put(root.systemSoundsKey, {
            key: root.systemSoundsKey,
            node: null,
            cls: "",
            name: Translation.tr("System Sounds"),
            icon: "",
            symbol: "notifications",
            live: false,
            previews: true,
        });

        // Audible things first (that is the useful order while something is
        // playing), then the rest by name so the list does not reshuffle as
        // apps come and go. The system-sounds row is pinned to the very top:
        // it is not an app, it is the one row that is about the machine.
        const list = [...rows.values()];
        list.sort((a, b) => (a.key === root.systemSoundsKey)
            ? -1
            : (b.key === root.systemSoundsKey)
                ? 1
                : ((a.live === b.live)
                    ? a.name.localeCompare(b.name)
                    : (a.live ? -1 : 1)));
        root.mixerAppCache = rows;
        return list;
    }

    // The last set of row objects handed to the mixer. Read by buildMixerApps()
    // so an unchanged app can be passed back by identity.
    property var mixerAppCache: new Map()

    // The song name for the music row, or "" when nothing is playing.
    //
    // Two sources, in order of trust.
    //
    // The daemon first: `MusicPlayer` already knows the title it asked mpv to
    // play, properly parsed, and it is the same object the shell's own media
    // surfaces read, so the mixer cannot disagree with them about what is
    // playing.
    //
    // The stream second, because mpv publishes NO `media.name` at all on this
    // machine (`wpctl inspect` on the live node shows only
    // `application.name = "mpv"`), so there is nothing to read and the row had
    // no way to name the song it was controlling.
    //
    // The filename fallback exists for a stream from some OTHER player, where
    // the name is at least something. This library's files are filed as
    // "<artist> - <title>.mp3", so the leading part is the artist and is
    // dropped: the row already says "Music", and "Music - hkmori" answers
    // nothing.
    function musicTitleFor(node): string {
        try {
            if (MusicPlayer?.hasTrack === true) {
                const title = String(MusicPlayer.trackTitle ?? "").trim();
                if (title !== "")
                    return title;
            }
        } catch (error) {
            // No daemon, no problem: fall through to the filename.
        }
        const raw = String(node?.properties?.["media.name"]
            ?? node?.properties?.["media.title"] ?? "").trim();
        if (raw === "")
            return "";
        // Basename first: media.name is sometimes the whole path.
        const base = raw.split("/").pop() ?? raw;
        const noExt = base.replace(/\.[a-z0-9]{2,4}$/i, "");
        const dash = noExt.lastIndexOf(" - ");
        return dash !== -1 && dash < noExt.length - 3
            ? noExt.slice(dash + 3).trim()
            : noExt.trim();
    }

    function appDisplayName(node, keys, cls) {
        // The music player is "Music", not whatever its desktop entry happens
        // to be called. `/usr/share/applications/mpv.desktop` ships
        // `Name=mpv Media Player`, so the row came out reading "mpv Media
        // Player" -- which describes the binary rather than what the row is
        // for, and which changes if the entry is ever replaced. The daemon
        // placeholder beside it already said "Music"; this makes the live
        // stream say the same thing, so the two agree.
        if (root.isMusicApp(keys, cls))
            return Translation.tr("Music");
        const app = String(node?.properties?.["application.name"] ?? "").trim();
        if (app !== "") {
            const entry = DesktopEntries.heuristicLookup(app);
            return entry?.name ?? app;
        }
        if (cls !== "")
            return DesktopEntries.heuristicLookup(cls)?.name ?? cls;
        if (keys.length > 0)
            return DesktopEntries.heuristicLookup(keys[0])?.name ?? keys[0];
        return Translation.tr("Application");
    }

    function appIconName(node, keys, cls) {
        if (node !== null && node !== undefined)
            return root.appNodeIconName(node);
        const probe = cls || keys[0] || "";
        const entry = probe === "" ? null : DesktopEntries.heuristicLookup(probe);
        return entry?.icon ?? "";
    }

    // The row the music player belongs in RIGHT NOW.
    //
    // It used to be a fixed "ii-music", which is the key of the service
    // placeholder added when nothing is playing. The moment mpv actually
    // streams, the live stream arrives under its OWN key ("mpv") and the two
    // sit side by side: one labelled "Music", one labelled "mpv Media Player",
    // both being the same music. So when a live music row is already in the
    // list, the placeholder joins THAT one and there is a single row either
    // way.
    function musicDaemonRowKey(): string {
        const serviceKey = root.musicDaemonKey();
        if (serviceKey === "")
            return "";
        for (const row of root.mixerAppCache?.values?.() ?? []) {
            if (row?.music === true && row.key !== serviceKey)
                return String(row.key);
        }
        return serviceKey;
    }

    // The local music daemon's key, or "" when it is not running.
    //
    // The music service is mpv driven over a private socket, so the honest
    // liveness signal is the shell's own service rather than a process name.
    function musicDaemonKey(): string {
        try {
            if (!MusicPlayer?.daemonUp)
                return "";
        } catch (error) {
            return "";
        }
        return "ii-music";
    }

    // Is this the PC's own music rather than an app? Keyed off the daemon
    // patterns plus one deliberate condition: a DAEMON has no window. An mpv
    // the user launched themselves has one, and stays an ordinary app with its
    // own icon and its own row.
    function isMusicApp(keys, cls): boolean {
        const joined = [...(keys ?? []), cls ?? ""].join(" ").toLowerCase();
        if (!/(^|[^a-z])(mpd|mpv|ii[-_. ]?music|music[-_. ]?player)/.test(joined))
            return false;
        return (cls ?? "") === "";
    }

    // ── The per-app volume the shell remembers ───────────────────────────
    //
    // For an app with no stream there is nothing in PipeWire to write to, so
    // the value lives here, persisted, and is pushed onto the stream when the
    // app finally makes a sound. "Never touched" is a distinct state from a
    // value of 1.0, and it matters: it is what lets a live stream stay the
    // authority the moment one exists. The remembered value only takes over
    // for an app the user has actually moved the row of while it was silent.
    property var rememberedVolumes: ({})

    function remembered(key: string) {
        const entry = root.rememberedVolumes?.[key];
        if (!entry)
            return { volume: 1.0, muted: false, remembered: false };
        return entry;
    }

    // ── Streams adjusted on their own ───────────────────────────────────
    //
    // `applyRememberedVolumes` pushes an APP's remembered level onto every
    // stream that app opens, every 1.5s. That is right for the mixer, whose
    // rows are apps -- and wrong for a row that is one stream: the write lands,
    // then the next sweep snaps it back to the app's value, so the control
    // looks dead (measured: set to 70%, back to 35% inside two seconds).
    //
    // So a stream that was adjusted individually is remembered here, by node
    // id, and the sweep skips it. Marks are session-only and cleared with the
    // node: there is nothing to persist, because the value lives on the stream.
    property var perStreamAdjusted: ({})
    function markPerStreamAdjusted(node) {
        if (!node || node.id === undefined || node.id === null)
            return;
        const next = Object.assign({}, root.perStreamAdjusted);
        next[String(node.id)] = true;
        root.perStreamAdjusted = next;
    }

    function setAppVolume(key: string, node, volume: real) {
        if (node?.audio)
            node.audio.volume = volume;
        root.remember(key, volume, root.remembered(key).muted);
    }

    function setAppMuted(key: string, node, muted: bool) {
        if (node?.audio)
            node.audio.muted = muted;
        root.remember(key, root.remembered(key).volume, muted);
    }

    function remember(key: string, volume: real, muted: bool) {
        if (!key || key === "")
            return;
        const next = Object.assign({}, root.rememberedVolumes);
        next[key] = { volume, muted, remembered: true };
        root.rememberedVolumes = next;
        root.persistRemembered();
    }

    // Push the remembered values onto streams that have appeared since. A
    // stream is created when an app starts making a sound, which is the whole
    // point: the volume set while it was silent arrives with its first note.
    function applyRememberedVolumes() {
        const saved = root.rememberedVolumes;
        if (!saved)
            return;
        for (const node of root.outputAppNodes) {
            if (root.isSystemSoundNode(node))
                continue;
            if (root.perStreamAdjusted[String(node.id)] === true)
                continue;
            const key = root.appNodeIdentityKeys(node)[0];
            const entry = key ? saved[key] : null;
            if (!entry || !node?.audio)
                continue;
            if (entry.muted !== (node.audio.muted === true))
                node.audio.muted = entry.muted;
            if (Math.abs((node.audio.volume ?? -1) - entry.volume) > 0.001)
                node.audio.volume = entry.volume;
        }
    }

    // ── System sounds ────────────────────────────────────────────────────
    //
    // Notification and event sounds (a message arriving, the battery
    // finishing, a timer going off) are not a stream. `pw-play` is spawned per
    // sound, plays for a few hundred milliseconds and disconnects, so by the
    // time the mixer looks at PipeWire there is nothing left to regulate -- and
    // nothing to write a volume to either, because the node is already gone.
    //
    // The only place the sound still exists is the moment the player starts, so
    // that is where the volume is applied: the row's value is handed to the
    // spawn. It is the one mixer row that controls something by passing an
    // argument rather than by moving a node.
    //
    // The key is reserved rather than derived, so it cannot collide with a real
    // app: no window class and no process name can produce a leading "__". It
    // also means applyRememberedVolumes, which looks its values up by app key,
    // walks straight past it.
    readonly property string systemSoundsKey: "__system-sounds"

    function systemSoundEntry(): var {
        return root.remembered(root.systemSoundsKey);
    }

    // 1.0 until the user actually moves the row: an untouched row is the
    // neutral factor, and the sound plays at it -- the sink applies its own
    // volume to the stream afterwards, as it does to music. See
    // playSystemSoundFile, which also accepts an optional per-sound gain.
    function systemSoundVolume(): real {
        const entry = root.systemSoundEntry();
        if (!entry || entry.remembered !== true)
            return 1.0;
        const volume = Number(entry.volume);
        if (isNaN(volume))
            return 1.0;
        return Math.max(0, Math.min(1, volume));
    }

    function systemSoundMuted(): bool {
        const entry = root.systemSoundEntry();
        return entry?.remembered === true && entry.muted === true;
    }

    // Play a sound file at the system-sounds volume.
    //
    // ONE FACTOR, and it is honestly one factor. This used to multiply
    // `currentVolume()` in as well, so that "the two sliders compose" -- but
    // PipeWire already applies the sink's volume to every stream it mixes, so
    // that factor landed on these sounds a SECOND time. Measured 2026-10-11,
    // sink at 30%: a music stream carries volume 1.0 and is heard at the
    // sink's 30%, while the device click was spawned at `--volume 0.151`
    // (30% / 2, this shell's scale) -- about 16 dB under the music, and ~22 dB
    // once the click sample's own -6 dBFS headroom is counted. That is the
    // "sometimes plugging a USB drive in makes no sound" report: the click
    // was a whisper, and the quieter the desktop, the quieter it got.
    //
    // The row stays. It is the one control that is ABOUT these sounds (turning
    // System Sounds down has to turn them down), and it is a stream volume:
    // the same scale a music player sits at 100% on. So these sounds at row
    // 100% are as loud as music at 100%, and the sink governs both.
    //
    // ONE OPTIONAL SECOND FACTOR, and it is not the sink coming back in. A
    // caller may hand a sound a GAIN, which multiplies the row -- but only
    // DOWNWARD: this player takes 0-1.0 and clamps, so a gain above 1 is not a
    // way to make one sound louder than the row (see the clamp note in the
    // body). Making a sound louder than music is the SAMPLE's job, and both
    // sounds that needed it now carry their level in the file
    // (assets/sounds/notification.oga is the chime at -0.9 dBFS peak). The
    // row still scales gains in every direction -- a row at zero or muted
    // spawns nothing at all -- and the sink is applied once, by the sink.
    // Measured in the log line below as `row x gain`, so the identity is
    // checkable from a terminal rather than from ears.
    //
    // Returns false without spawning anything when the row is muted or when
    // either factor is zero: a slider at zero means "do not play this", and
    // honouring that by spawning a silent player is both slower and wrong -- the
    // notification still costs a process spawn and a PipeWire client on the wire.
    // The gain has NO default value, and that is not an oversight: QML's JS
    // engine does not support default arguments on an annotated function
    // ("Type annotations are not supported (yet)"), and a config with one fails
    // to load -- the whole desktop, over a parameter that is meant to be
    // optional. An omitted argument arrives as `undefined` instead, which the
    // NaN test below turns back into 1.0, so callers that do not care about it
    // can simply leave it off.
    function playSystemSoundFile(file: string, gain: real): bool {
        const path = String(file ?? "").trim();
        if (path.length === 0)
            return false;
        const row = root.systemSoundVolume();
        // ── The factor cannot exceed 1.0, and pretending otherwise cost the
        // notifications their whole boost ────────────────────────────────────
        //
        // `pw-play --volume` takes 0-1.0 and CLAMPS anything above it; measured
        // 2026-10-26, `--volume 1.8` produces a stream at 65536 / 100 %. The
        // chime used to ask for 1.8 and the drive click for 1.5, so both played
        // at exactly the mixer row while the comments promised +5.1 / +3.5 dB
        // -- which is precisely "music too loud, notification sounds too
        // quiet": music is a full-scale master at 100 %, and a soft 311 ms
        // drop at -5.9 dBFS does not survive under it.
        //
        // paplay CAN go above unity, but it cannot carry the mixer mark (its
        // PULSE_PROP application.name is overwritten, measured the same day),
        // and an unmarked stream would appear in the volume mixer as a
        // flickering "paplay" row -- the bug isSystemSoundNode exists to
        // prevent. So the level lives in the SAMPLE instead
        // (assets/sounds/notification.oga is the chime at +4.9 dB), and the
        // factor is clamped here so no caller can silently believe in a boost
        // that the player throws away.
        const factor = (isNaN(gain) || gain <= 0) ? 1.0 : Math.min(1, gain);
        const volume = row * factor;
        if (root.systemSoundMuted() || volume <= 0.001) {
            print(`[mixer] preview silent: muted=${root.systemSoundMuted()} row=${row} gain=${factor}`);
            return false;
        }
        const level = volume.toFixed(3);
        print(`[mixer] preview playing ${path} at ${level} (row ${row} x ${factor}, sink applies its own)`);
        // The mark the mixer filters on (see isSystemSoundNode). Set on the
        // pw-* players, which take `--properties`; the fallbacks cannot be
        // marked, but they only run on a machine with no PipeWire tooling at
        // all, which is not this one.
        const tag = `{ application.name = ${root.systemSoundAppName}`
            + ` node.name = ${root.systemSoundAppName} }`;
        // pw-play and pw-cat are PipeWire's own players and the only ones here
        // that take a level; the others are kept purely as a fallback for a
        // machine that somehow has no pw-* binary, and play at full volume
        // rather than not at all.
        try {
            Quickshell.execDetached(["sh", "-c",
                "f=\"$1\"; v=\"$2\"; p=\"$3\"; "
                + "if command -v pw-play >/dev/null 2>&1; then exec pw-play --volume \"$v\" --properties \"$p\" \"$f\"; "
                + "elif command -v pw-cat >/dev/null 2>&1; then exec pw-cat --volume \"$v\" --properties \"$p\" \"$f\"; "
                + "elif command -v paplay >/dev/null 2>&1; then exec paplay \"$f\"; "
                + "elif command -v canberra-gtk-play >/dev/null 2>&1; then exec canberra-gtk-play -f \"$f\"; fi",
                "system-sound", path, level, tag]);
            return true;
        } catch (error) {
            // No sound is never a failure worth propagating: a missing player
            // must not take a notification down with it.
            return false;
        }
    }

    // The chime the System Sounds row plays back when it is moved.
    //
    // A row that only writes a number somewhere is invisible: the whole reason
    // to turn it down instead of muting is that you want to hear the new level
    // without waiting for the next notification to arrive. So changing it
    // chimes once, at the level just set.
    //
    // Two things make this safe to wire to a slider rather than to a button.
    // It is rate-limited, because `onMoved` fires for every pixel of a drag and
    // an unchimed chime per pixel is a machine gun. And it goes through
    // playSystemSoundFile, so a row at zero or muted plays nothing -- which is
    // the correct confirmation, not a missing feature: you just turned the
    // sound off and hearing nothing is how you know.
    property real lastSystemSoundPreview: 0
    readonly property int systemSoundPreviewInterval: 600

    function previewSystemSound(): bool {
        const now = Date.now();
        if (now - root.lastSystemSoundPreview < root.systemSoundPreviewInterval) {
            print(`[mixer] preview suppressed (rate limit)`);
            return false;
        }
        root.lastSystemSoundPreview = now;
        const theme = root.audioTheme !== "" ? root.audioTheme : "freedesktop";
        for (const ext of [".oga", ".ogg"]) {
            if (root.playSystemSoundFile(`/usr/share/sounds/${theme}/stereo/message${ext}`))
                return true;
        }
        return false;
    }

    // An event sound from the configured sound theme (battery, timers). Named
    // rather than a path, because the theme ships .oga on most systems and .ogg
    // on some, and the old version fired ffplay twice to cover both -- which
    // meant every battery chime was played twice wherever both existed.
    function playSystemSound(soundName: string) {
        const name = String(soundName ?? "").trim();
        if (name.length === 0)
            return;
        const theme = root.audioTheme !== "" ? root.audioTheme : "freedesktop";
        for (const ext of [".oga", ".ogg"]) {
            if (root.playSystemSoundFile(`/usr/share/sounds/${theme}/stereo/${name}${ext}`))
                return;
        }
    }

    Timer {
        // Every half second. It walks the streams and writes only where a
        // remembered value and the live one actually disagree, so this costs an
        // array scan rather than a write per tick.
        //
        // Now 1.5s, not 0.5s, and that is a safety margin rather than a
        // tuning choice. This loop reads `node.audio` off every stream it can
        // see, and a stream that is in the middle of being torn down is still
        // in that list for a moment after it has been unbound -- reading it is
        // a use-after-free inside Quickshell's PipeWire bindings and takes the
        // whole shell down with a SIGSEGV, no QML error first. Sampling less
        // often is the only lever available from QML: a segfault cannot be
        // caught, so the only thing to do is stop being so often in the way.
        //
        // 1.5s costs nothing by its own lights -- the thing it does is apply
        // a remembered volume to a stream that has just appeared, and nothing
        // waits on a tenth of a second for that.
        interval: 1500
        repeat: true
        running: true
        onTriggered: {
            const t = Date.now();
            root.applyRememberedVolumes();
            StatusSignal.perfMark("memVolumes", Date.now() - t);
        }
    }

    function persistRemembered() {
        try {
            rememberWriter.body = JSON.stringify(root.rememberedVolumes ?? {});
            rememberWriter.running = false;
            rememberWriter.running = true;
        } catch (error) {
            // Persistence is a convenience; a shell that cannot write the file
            // must still control volume for this session.
        }
    }

    Process {
        id: rememberWriter
        property string body: "{}"
        running: false
        command: ["bash", "-c",
            `mkdir -p "$(dirname '${root.rememberedPath}')" && printf '%s' '${root.body}' > '${root.rememberedPath}'`]
    }

    // The remembered volumes are the one mixer value that cannot be re-read
    // from PipeWire (there is no node for a silent app), so losing them on
    // every reload -- and a reload happens on every saved file edit -- would
    // quietly undo the whole reason these rows exist.
    readonly property string rememberedPath: `${Directories.state}/audio/app-volumes.json`

    FileView {
        id: rememberedFile
        path: root.rememberedPath
        watchChanges: false
        onLoaded: {
            try {
                const parsed = JSON.parse((rememberedFile.text() || "{}").trim() || "{}");
                if (parsed && typeof parsed === "object")
                    root.rememberedVolumes = parsed;
            } catch (error) {
                // A corrupt file is not worth failing over: the rows fall back
                // to live values, and the next change rewrites it.
            }
        }
    }

    Component.onCompleted: rememberedFile.reload()

    // Words that describe the audio FORMAT or the chip, never the thing you
    // plugged in. They are the only words safe to drop: a name is shortened by
    // removing noise, not by guessing which half the user cares about.
    readonly property var _nameFiller: (["stereo", "mono", "digital", "analog", "audio", "2ch", "4ch", "output"])

    // A SHORT name for a device, for places that show it inline next to
    // something else -- the bar's sound pocket above all.
    //
    // PipeWire names a sink after its hardware chain rather than its port.
    // This machine's default sink is
    //   "700 Series Chipset Family HD Audio Speaker"  (41 characters)
    // and the bar sizes its pocket from the name at ~6.2px a character, so
    // that one line reserved roughly 250px of the top bar to say the word
    // "Speaker" at the end of it. Nobody reads vendor and chipset; the port
    // is the whole answer.
    //
    // The rule, in order:
    //   1. A real `nickname` wins outright -- someone set that on purpose, and
    //      it is short by intent.
    //   2. Drop the format words above.
    //   3. If more than three words survive, that is a hardware chain rather
    //      than a product name, so keep the tail: the port.
    //   4. If the tail turns out to be a bare number -- "HDMI / DisplayPort 1
    //      Output" ends in "1", and "1" is not a device -- keep the last two
    //      words instead.
    //   5. If nothing survives, return the description UNTOUCHED. A mangled
    //      device name is worse than a long one, and this is presentation
    //      only: the device picker and every switch still use the full name.
    function shortDeviceName(node) {
        const nick = (node?.nickname || "").trim();
        if (nick !== "")
            return nick;

        const desc = (node?.description || node?.name || "").trim();
        if (desc === "")
            return Translation.tr("No output device");

        const words = desc.split(/\s+/);
        const kept = words.filter(w => !root._nameFiller.includes(w.toLowerCase()));
        if (kept.length === 0)
            return desc;
        if (kept.length <= 3)
            return kept.join(" ");

        // A bare numeral is a port index, not a port. "DisplayPort 1" is a
        // device; "1" on its own is a list position.
        return /^\d+$/.test(kept[kept.length - 1])
            ? kept.slice(-2).join(" ")
            : kept[kept.length - 1];
    }

    // Lists
    function correctType(node, isSink) {
        return (node.isSink === isSink) && node.audio
    }
    function appNodes(isSink) {
        return Pipewire.nodes.values.filter((node) => { // Should be list<PwNode> but it breaks ScriptModel
            return root.correctType(node, isSink) && node.isStream
        })
    }
    function devices(isSink) {
        return Pipewire.nodes.values.filter(node => {
            return root.correctType(node, isSink) && !node.isStream
        })
    }
    readonly property list<var> outputAppNodes: root.appNodes(true)
    readonly property list<var> inputAppNodes: root.appNodes(false)
    readonly property list<var> outputDevices: root.devices(true)
    readonly property list<var> inputDevices: root.devices(false)

    // ── The shell's own system sounds ────────────────────────────────────
    //
    // Every notification chime and event sound really is a PipeWire stream --
    // `pw-play` is spawned, plays for a few hundred milliseconds and goes
    // away. That made it show up in the mixer as an app of its own, called
    // "pw-play", sitting under the System Sounds row that is supposed to be
    // controlling it.
    //
    // It also made that row impossible to use. `mixerApps` is a binding, so a
    // stream appearing REBUILDS the whole list; the spawn happens on the same
    // `onMoved` that is adjusting the System Sounds slider, so every chime
    // replaced the delegate under the pointer and the drag simply stopped
    // responding. The row was not refusing to change -- it was being deleted
    // a few times a second while it was being dragged.
    //
    // So the spawn announces itself and the mixer ignores it. The mark is a
    // property the shell sets on its own player, so the test is exact: it
    // cannot swallow a stream from a real application, however that
    // application happens to be named.
    readonly property string systemSoundAppName: "ii-system-sound"

    function isSystemSoundNode(node): bool {
        if (!node)
            return false;
        // BOTH are tested, and the second one is the load-bearing one.
        //
        // `application.name` is not there when the mixer first looks. A node
        // is created unbound, bound, and only then has its initial props
        // enumerated; a rebuild that lands in that window reads a props map
        // that still holds pw-play's DEFAULTS, so the tag was missed and the
        // row appeared under the name "pw-play" -- which is the whole reason
        // this looked unfixed while the property was demonstrably set on the
        // node (`wpctl inspect` showed it every time).
        //
        // `node.name` is a direct property rather than an entry in the
        // enumerated props map, so it is there from the moment the node is
        // bound. Setting it to the same mark makes the two independent and
        // the test true whichever one a given build populates first.
        if (String(node.name ?? "") === root.systemSoundAppName)
            return true;
        const name = String(node.properties?.["application.name"] ?? "");
        return name === root.systemSoundAppName;
    }

    // Signals
    signal sinkProtectionTriggered(string reason);

    // Controls
    function toggleMute() {
        Audio.sink.audio.muted = !Audio.sink.audio.muted
    }

    function toggleMicMute() {
        Audio.source.audio.muted = !Audio.source.audio.muted
    }

    // The shell's volume, read and written as a plain 0..1 fraction where 1.0
    // is `hardMaxValue`. `sink.audio.volume` is the only path that actually
    // reaches PipeWire, and `sink` is null until the daemon answers, so callers
    // go through these two functions rather than at the node. The bar's
    // two-finger swipe is absolute control (it anchors on the volume the
    // fingers land over and follows the travel from there), which a step API
    // cannot express.
    //
    // EVERY surface reads its fraction here and writes it through
    // `setSinkVolume`: the bar's rail, the swipe band, the OSD, the sidebar
    // slider, the mixer's system row and the wheel steps all used to touch
    // `sink.audio.volume` themselves, each with its own idea of what 1.0 meant
    // -- and once the scale moved, a single missed site would have been a
    // control that silently stopped at half volume.
    function currentVolume(): real {
        const raw = Audio.sink?.audio?.volume ?? 0;
        return Math.max(0, Math.min(1, raw / root.hardMaxValue));
    }

    function setSinkVolume(fraction: real): void {
        if (!Audio.sink?.audio) return;
        // Clamped to 0..1 of the SHELL's scale -- 100%, not 200%. `hardMaxValue`
        // is 2.0 because that is the amplifier's usable headroom (PipeWire
        // accepts it: `wpctl set-volume 150%` reads back 1.50) and it is the
        // same ceiling the volume rail has always drawn; calling it "100%" is
        // what keeps the UI from ever naming a number above the scale it draws.
        //
        // Sustained maximum is inert: the sink only writes when the value
        // changes, and both the swipe's band and the rail stop at the ceiling
        // rather than queueing against it.
        const clamped = Math.max(0, Math.min(1, fraction));
        // Zero is SILENT, and now it says so. The sink's own mute flag goes with
        // the number, so every surface that reads `muted` -- the bar's icon, the
        // mixer's row, the sidebar slider -- agrees with the 0% instead of
        // showing a live-looking control on a silent sink. How the zero was
        // asked for makes no difference: the two-finger swipe's floor reaches it
        // now (see BarContent's per-zone floor), and so does a slider dragged to
        // the bottom or a tap that means "silence now".
        //
        // Coming back OFF zero clears the mute again, which is what keeps the
        // gesture from becoming a dead end: swipe down to 0, swipe back up, and
        // the level returns AND is audible. Only a write that was at zero BEFORE
        // it happens is allowed to clear it, so a deliberate mute at 40% is not
        // undone by a write that moves the level sideways -- the bar's own wheel
        // handler already draws that line for scrolling up, see its
        // `if (Audio.sink.audio.muted && step > 0)`.
        const wasSilent = Audio.currentVolume() <= 0;
        Audio.sink.audio.volume = clamped * root.hardMaxValue;
        if (clamped <= 0 && !Audio.sink.audio.muted)
            Audio.sink.audio.muted = true;
        else if (clamped > 0 && wasSilent && Audio.sink.audio.muted)
            Audio.sink.audio.muted = false;
    }

    // The same scale, for a row that might BE the default sink.
    //
    // The waffle mixer builds one slider row from a bare node and hands it
    // `Audio.sink` for the System row and an app's stream for every row below.
    // A stream's own volume is PipeWire's own scale (1.0 is its unity gain),
    // but the default sink's is the shell's -- so a row that read and wrote
    // `node.audio.volume` itself made the System slider a HALF-length control:
    // its right end landed on the sink's 1.0, which the shell now calls 50%,
    // and its tooltip named "200%" at the loud end. These two route a node
    // through the scale that belongs to what the node is, so one row component
    // can serve both without knowing which it got.
    function isDefaultSink(node): bool {
        return node !== null && node !== undefined && node.id === root.sink?.id;
    }

    function nodeVolumeFraction(node): real {
        if (!node?.audio)
            return 0;
        return root.isDefaultSink(node)
            ? root.currentVolume()
            : node.audio.volume;
    }

    function setNodeVolumeFraction(node, fraction: real): void {
        if (!node?.audio)
            return;
        if (root.isDefaultSink(node))
            root.setSinkVolume(fraction);
        else
            node.audio.volume = fraction;
    }

    // ── Volume-rail math, shared ─────────────────────────────────────────
    // The desktop rail draws on the BOTTOM layer (no input under a focused
    // window) and a Top-layer input proxy receives the gestures; both must
    // respond identically, so the mapping lives here instead of in a copy on
    // each side (the two had already drifted once).
    //   fraction 0..1 spans the WHOLE groove, which is the full hardMaxValue
    //   range, exactly like dragging the rail's fill.
    function setVolumeFraction(fraction) {
        Audio.setSinkVolume(fraction);
    }

    function nudgeVolumeBy(deltaFraction) {
        Audio.setSinkVolume(Audio.currentVolume() + deltaFraction);
    }

    // Pixel y inside the rail's interaction rect -> fraction (top = full).
    function volumeFractionFromY(y, height) {
        if (!(height > 0))
            return Audio.currentVolume();
        return Math.max(0, Math.min(1, 1 - y / height));
    }

    // ── Two-finger volume swipe, shared ──────────────────────────────────
    // The rail draws on the BOTTOM layer and a Top-layer proxy receives the
    // gestures; both feed the same gesture machine here, so the two can never
    // disagree about what a swipe means (they had already drifted once).
    //
    // This replaced a straight 1:1 mapping (finger pixels -> groove pixels),
    // which is what made the bar feel twitchy: a touchpad emits one wheel
    // event per few pixels, so a short flick crossed most of the groove and a
    // finger resting on the pad still leaked a percent at a time. Three
    // guards now stand between the fingers and the value:
    //
    //   * a DEAD ZONE -- nothing moves until the vertical travel passes
    //     volumeSwipeEngagePx, so resting-finger jitter cannot drift the bar;
    //   * an AXIS LOCK -- a sideways-dominant event is dropped (and the bank
    //     cleared), so a horizontal swipe cannot drain the volume;
    //   * QUANTIZED STEPS -- travel is banked and spent in whole pieces, so
    //     the same gesture always lands on the same number instead of
    //     accumulating sub-pixel leftovers into a wander.
    //
    // Calibration: a full groove (0..100% on the rail) takes
    // volumeSwipePxPerFull of finger travel -- an unhurried swipe nudges the
    // volume rather than throwing it across the screen.
    readonly property real volumeSwipePxPerFull: 620
    readonly property real volumeSwipeEngagePx: 12
    readonly property real volumeSwipeMaxStep: 0.04
    readonly property real volumeSwipeAxisRatio: 1.2
    property real volumeSwipeBank: 0
    property bool volumeSwipeEngaged: false

    // The gesture ends when the wheel events stop, not when a button is
    // released -- there is no release for a two-finger scroll.
    Timer {
        id: volumeSwipeSettle
        interval: 200
        repeat: false
        onTriggered: {
            Audio.volumeSwipeBank = 0;
            Audio.volumeSwipeEngaged = false;
        }
    }

    // One touchpad wheel event. `px`/`py` are its deltas in logical pixels,
    // sign-corrected by the caller so a positive `py` always means "louder".
    // Always returns true: the swipe belongs to the volume rail, never to a
    // scroller behind it.
    function volumeSwipe(px, py) {
        volumeSwipeSettle.restart();
        const ax = Math.abs(px), ay = Math.abs(py);
        const sideways = ax > ay * Audio.volumeSwipeAxisRatio;
        if (!Audio.volumeSwipeEngaged) {
            if (sideways) {
                // Not ours yet -- and do not bank it, or a diagonal start
                // would pre-load the volume before the swipe even begins.
                Audio.volumeSwipeBank = 0;
                return true;
            }
            Audio.volumeSwipeBank += py;
            if (Math.abs(Audio.volumeSwipeBank) < Audio.volumeSwipeEngagePx)
                return true;
            Audio.volumeSwipeEngaged = true;
        } else {
            if (sideways)   // veered off-axis mid-gesture: hold the value
                return true;
            Audio.volumeSwipeBank += py;
        }
        const wanted = Audio.volumeSwipeBank / Audio.volumeSwipePxPerFull;
        const step = Math.max(-Audio.volumeSwipeMaxStep,
            Math.min(Audio.volumeSwipeMaxStep, wanted));
        if (step !== 0)
            Audio.nudgeVolumeBy(step);
        // Spend the travel, so a slow drag moves in even pieces and a burst
        // cannot stack dozens of steps into one jump.
        Audio.volumeSwipeBank = 0;
        return true;
    }

    // Keybind/mixer wheel steps, in the shell's fractions: fine near silence,
    // then ordinary 2% steps, and they stop at 100% like every other control
    // (they used to stop at 100% of the SINK while the rail beside them went to
    // 200% -- the same split the swipe had, one scale up).
    function incrementVolume() {
        const step = Audio.currentVolume() < 0.1 ? 0.01 : 0.02;
        Audio.setSinkVolume(Audio.currentVolume() + step);
    }

    function decrementVolume() {
        const step = Audio.currentVolume() < 0.1 ? 0.01 : 0.02;
        Audio.setSinkVolume(Audio.currentVolume() - step);
    }

    function setDefaultSink(node) {
        Pipewire.preferredDefaultAudioSink = node;
    }

    function setDefaultSource(node) {
        Pipewire.preferredDefaultAudioSource = node;
    }

    // Internals
    PwObjectTracker {
        objects: [sink, source]
    }

    Connections { // Protection against sudden volume changes
        target: sink?.audio ?? null
        property bool lastReady: false
        property real lastVolume: 0
        function onVolumeChanged() {
            if (!Config.options.audio.protection.enable) return;
            const newVolume = sink.audio.volume;
            // when resuming from suspend, we should not write volume to avoid pipewire volume reset issues
            if (isNaN(newVolume) || newVolume === undefined || newVolume === null) {
                lastReady = false;
                lastVolume = 0;
                return;
            }
            if (!lastReady) {
                lastVolume = newVolume;
                lastReady = true;
                return;
            }
            // The config's two numbers are percentages of the SHELL's scale
            // ("max allowed 99" means 99%), so they are scaled into sink units
            // here: `hardMaxValue` is what 100% means. Without this the guard
            // would clamp a 100% volume to 99% of the SINK -- half the range
            // it was written to allow.
            const maxAllowedIncrease = Config.options.audio.protection.maxAllowedIncrease / 100
                * root.hardMaxValue;
            const maxAllowed = Config.options.audio.protection.maxAllowed / 100
                * root.hardMaxValue;

            if (newVolume - lastVolume > maxAllowedIncrease) {
                sink.audio.volume = lastVolume;
                root.sinkProtectionTriggered(Translation.tr("Illegal increment"));
            } else if (newVolume > maxAllowed || newVolume > root.hardMaxValue) {
                root.sinkProtectionTriggered(Translation.tr("Exceeded max allowed"));
                sink.audio.volume = Math.min(lastVolume, maxAllowed);
            }
            lastVolume = sink.audio.volume;
        }
    }

    // An event sound from the configured sound theme (battery, timers) is
    // played through playSystemSound above.
}
