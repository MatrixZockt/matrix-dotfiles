pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.modules.common
// GlobalStates lives in the config root: without this import every
// `GlobalStates.something = ...` below was a ReferenceError, and Quickshell
// swallows an exception thrown inside an IPC handler -- so `music show`
// returned success and did absolutely nothing.
import qs

/**
 * The background music player: a headless mpv daemon plus the local library.
 *
 * There is NO music application window. mpv runs GUI-less ("--no-video
 * --idle=yes") as the background engine and is driven over its JSON IPC
 * socket from here; the ONLY user interface is the shell's left sidebar
 * Music tab, which lists the raw downloaded songs (~/Music/Spotify/<playlist>
 * folders) and plays them through this service.
 *
 * Everything is local files: no ads, no streaming, works offline.
 */
Singleton {
    id: root

    readonly property string musicDir: `${Quickshell.env("HOME")}/Music/Spotify`
    readonly property string socketPath: `${Quickshell.env("XDG_RUNTIME_DIR") ?? "/run/user/1000"}/ii-music-ipc`
    readonly property string mpvBin: "/usr/bin/mpv"

    // ── Daemon state ─────────────────────────────────────────────────────
    property bool daemonUp: false          // socket connected
    property bool paused: true
    property string trackTitle: ""
    property string trackArtist: ""
    property real position: 0
    property real duration: 0
    property int volume: 80
    property var queue: []                 // [{filename}]
    property int queuePos: -1
    readonly property bool hasTrack: trackTitle !== "" && queuePos >= 0

    // ── Library (the raw downloaded data) ────────────────────────────────
    // [{name, dir, tracks: [{path, title, artist}]}] — one entry per playlist
    // folder, tracks sorted by filename.
    property var library: []
    property bool scanning: false
    readonly property int totalTracks: library.reduce((n, p) => n + p.tracks.length, 0)

    onHasTrackChanged: if (!hasTrack) { root.trackTitle = ""; root.trackArtist = ""; }

    // ── Settings (persisted; see Persistent.qml's music object) ───────────
    // These are not decoration: applySettings() pushes every one of them into
    // the mpv daemon as a real property, and it runs on connect, so a fresh
    // login comes up with the same sound the last one had.
    readonly property var settings: Persistent.states.music
    function applySettings() {
        const s = root.settings;
        // volume-max FIRST: it caps volume, so setting volume before it would
        // clamp the value the user asked for.
        root.cmd(["set_property", "volume-max", s.volumeMax]);
        // Verified against mpv 0.41 on this machine -- the documented-looking
        // spellings (`gapless-playback`, `audio-replay-gain`) are NOT settable
        // at runtime and answer "property not found".
        root.cmd(["set_property", "replaygain", s.replayGain]);
        root.cmd(["set_property", "gapless-audio", s.gapless ? "yes" : "no"]);
        root.cmd(["set_property", "af", root._crossfadeFilter(s.crossfade)]);
        root.cmd(["set_property", "volume", s.startVolume]);
        root.volume = s.startVolume;
    }
    /**
     * mpv has no crossfade option of its own; it is a filter. A fade-out is
     * scheduled relative to the track length, so "st" is recomputed per file
     * and clamped to zero for anything shorter than twice the fade, where
     * overlapping the two ends would just clip.
     */
    function _crossfadeFilter(seconds) {
        // The empty string is what CLEARS mpv's filter chain -- verified
        // against the running daemon, where the intuitive "null" is REJECTED
        // ("property not found"-style failure) and silently leaves the old
        // crossfade in place. Turning crossfade off has to actually remove it.
        if (!seconds || seconds <= 0) return "";
        const d = Number(seconds);
        const len = root.duration > 0 ? root.duration : 0;
        const st = len > d * 2 ? Math.max(0, len - d) : 0;
        return `lavfi=[afade=t=in:st=0:d=${d},afade=t=out:st=${st}:d=${d}]`;
    }

    // ── Daemon lifecycle ─────────────────────────────────────────────────
    function ensureDaemon() {
        if (root.daemonUp) return;
        sock.connected = true; // attempt; the retry timer handles the rest
    }

    // The daemon is NOT owned by the shell: it is the systemd --user unit
    // ii-music-mpd.service (Restart=always), so exactly one mpv exists per
    // login, it outlives shell restarts, and the stale-socket/duplicate-
    // spawn class of bugs is gone by construction. The shell only CONNECTS.

    // Reconnect state machine: Quickshell's Socket remembers a failed
    // attempt internally (a later `connected = true` is a no-op — observed:
    // exactly one ServerNotFoundError per shell boot, then nothing), so the
    // retry has to JOLT it: clear the path, then re-arm. The flip alternates
    // the attempt across ticks so the two writes are never coalesced.
    property bool flip: false
    function attemptConnect() {
        sock.path = "";
        sock.connected = false;
        return true; // keep the timer alive until it lands
    }
    function commitConnect() {
        sock.path = root.socketPath;
        sock.connected = true;
        return !root.daemonUp; // keep retrying while still down
    }

    Timer {
        interval: 2000
        running: true
        repeat: true
        onTriggered: {
            if (!root.daemonUp) {
                root.flip = !root.flip;
                if (root.flip) root.attemptConnect();
                else root.commitConnect();
            }
        }
    }

    Socket {
        id: sock
        path: root.socketPath
        connected: false
        parser: SplitParser {
            splitMarker: "\n"
            onRead: line => root.handleLine(line)
        }
        onConnectionStateChanged: {
            root.daemonUp = sock.connected;
            console.log("[Music] socket state:", sock.connected);
            if (sock.connected) {
                console.log("[Music] mpv IPC connected");
                // Push the stored settings the moment the daemon is reachable;
                // without this every fresh login would come up on mpv's
                // defaults and the app's controls would look like they worked
                // only until a restart.
                root.applySettings();
                // Deferred: writing IPC commands inside the state-change
                // callback dropped the connection immediately (error 1 —
                // observed repeatedly). One tick later the pipe is settled
                // and the same writes live.
                observeLater.restart();
            }
        }
        onError: error => {
            console.log("[Music] socket error:", error);
            root.daemonUp = false;
        }
    }

    Timer {
        id: observeLater
        interval: 300
        onTriggered: {
            if (root.daemonUp) root.observeAll();
        }
    }

    // Periodic truth poll. Property-change events are the live path, but a
    // missed event (socket hiccup, busy tick) would leave the sidebar lying
    // forever — observed once with `pause`. A tiny round-trip every 5 s pins
    // the displayed state to reality; the events keep it smooth between.
    Timer {
        interval: 5000
        running: root.daemonUp
        repeat: true
        triggeredOnStart: false
        onTriggered: {
            if (!root.daemonUp) return;
            root.cmd(["get_property", "pause"], d => { root.paused = !!d; });
            root.cmd(["get_property", "time-pos"], d => { if (d !== null) root.position = d; });
            root.cmd(["get_property", "duration"], d => { if (d !== null) root.duration = d; });
            root.cmd(["get_property", "media-title"], d => { if (d) root.trackTitle = String(d); });
            root.cmd(["get_property", "playlist-pos"], d => { root.queuePos = d ?? -1; });
            root.cmd(["get_property", "metadata"], d => {
                const m = d ?? {};
                const a = String(m.artist ?? m.ARTIST ?? "");
                if (a !== "") root.trackArtist = a;
            });
        }
    }

    property int nextReqId: 0
    property var pending: ({})
    function cmd(command, cb) {
        if (!root.daemonUp) { root.ensureDaemon(); return; }
        const id = ++root.nextReqId;
        if (cb) root.pending[id] = cb;
        sock.write(JSON.stringify({ command: command, request_id: id }) + "\n");
        sock.flush();
    }

    function observeAll() {
        for (const name of ["pause", "time-pos", "duration", "media-title",
                            "metadata", "playlist-count", "playlist-pos", "idle-active"])
            sock.write(JSON.stringify({ command: ["observe_property", 0, name] }) + "\n");
        sock.flush();
    }

    function handleLine(line) {
        if (!line || line.length === 0) return;
        let d;
        try { d = JSON.parse(line); } catch (e) { return; }
        if (d.request_id !== undefined && root.pending[d.request_id] !== undefined) {
            const cb = root.pending[d.request_id];
            delete root.pending[d.request_id];
            if (d.error === "success") cb(d.data);
            return;
        }
        if (d.event !== "property-change") return;
        switch (d.name) {
        case "pause": root.paused = d.data !== false && d.data !== 0 ? !!d.data : false; break;
        case "time-pos": root.position = d.data ?? 0; break;
        case "duration": root.duration = d.data ?? 0; break;
        case "media-title": root.trackTitle = d.data ?? ""; break;
        case "metadata": {
            const m = d.data ?? {};
            root.trackArtist = String(m.artist ?? m.ARTIST ?? "");
            const t = String(m.title ?? m.TITLE ?? "");
            if (t !== "") root.trackTitle = t;
            break;
        }
        case "playlist-count": root.refreshQueue(); break;
        case "playlist-pos": root.queuePos = d.data ?? -1; break;
        case "idle-active": if (d.data) { root.queue = []; root.queuePos = -1; root.trackTitle = ""; root.trackArtist = ""; root.position = 0; root.duration = 0; root.paused = true; } break;
        }
    }

    function refreshQueue() {
        root.cmd(["get_property", "playlist"], data => {
            root.queue = (data ?? []).map(e => ({ filename: String(e.filename ?? "") }));
        });
        // The remembered song follows mpv's position in the queue, and it is
        // recorded HERE rather than in a change handler because the two
        // properties come from two separate asynchronous replies: a handler on
        // `queuePos` would read the PREVIOUS queue about half the time and
        // remember the wrong track. By the time this reply is handled the
        // queue above is current.
        //
        // Not an `onQueueAssigned` either -- this build answers that with
        // "Cannot assign to non-existent property", which takes the whole
        // configuration down as a cascade of unrelated "Type unavailable"
        // errors from shell.qml. A plain call has neither problem.
        root.cmd(["get_property", "playlist-pos"], data => {
            root.queuePos = data ?? -1;
            root.rememberTrack(root.queue?.[root.queuePos]?.filename ?? "");
        });
    }


    // ── Transport ────────────────────────────────────────────────────────
    function playPause() {
        // Starting, not stopping, is the moment to take the audio: pressing
        // play on the local player should silence the browser, and pressing
        // pause should obviously not. `paused` is an observed property, so it
        // is the real current state rather than a guess at the cycle.
        if (root.paused) root.claimOutput();
        root.cmd(["cycle", "pause"]);
    }
    // This player's own MPRIS bus, published by the bridge in scripts/music.
    // Matching on it is what keeps claimOutput() from pausing the very thing
    // it is trying to hand the audio to.
    readonly property string localMprisBus: "org.mpris.MediaPlayer2.iiMusic"

    /**
     * Take the machine's audio: pause every OTHER MPRIS player, so the local
     * one is the only thing sounding.
     *
     * The user asked for this literally -- start music from the sidebar and
     * the browser stops making noise -- but it is also just correct: two
     * players talking over each other is never what anyone wants. The local
     * player is skipped by its own bus name, which is the only way to tell
     * "the other player" from "me": MprisController.activePlayer is no use
     * here, because it is whichever bus the compositor happened to see.
     *
     * Only players that are actually PLAYING are touched, and a player with
     * no transport at all is left alone rather than sent a command it will
     * answer with an error. canPause alone is not enough to gate on: Brave
     * reports canPause = false while it is merely stopped, and a player only
     * bothers to set it once it has something to pause, so requiring it
     * would skip a browser that was very much playing. Hence the toggle
     * fallback, which on a playing player can only mean "stop".
     */
    function claimOutput() {
        for (const p of Mpris.players.values) {
            if (p.dbusName === root.localMprisBus) continue;
            if (!p.isPlaying) continue;
            if (p.canPause) p.pause();
            else if (p.canTogglePlaying) p.togglePlaying();
        }
    }
    function next() { root.cmd(["playlist-next", "weak"]); }
    function previous() { root.cmd(["playlist-prev", "weak"]); }

    /**
     * Record the song the library is sitting on.
     *
     * Called whenever mpv's position in the queue moves, not only when a
     * playlist is started: the queue advances on its own (gapless autoplay,
     * the next-track button, skipping), and the sidebar's remembered song has
     * to follow it or it reopens pointing at a track that finished an hour
     * ago.
     *
     * Skipped when the value would not change. Every skip re-arms the
     * persisted-states write, and a plain track change would otherwise dirty
     * that file for the sake of writing the same string back.
     */
    function rememberTrack(path: string) {
        const p = String(path ?? "");
        if (p === "" || p === Persistent.states.music.lastSongPath)
            return;
        Persistent.states.music.lastSongPath = p;
    }
    function stop() { root.cmd(["stop"]); }
    function setVolume(v) { root.volume = Math.max(0, Math.min(100, Math.round(v))); root.cmd(["set_property", "volume", root.volume]); }
    function seekTo(seconds) { root.cmd(["seek", Math.max(0, Math.round(seconds)), "absolute"]); }
    function seekFraction(f) { if (root.duration > 0) root.seekTo(f * root.duration); }

    /** Queue a whole playlist folder, starting at track `start` (default 0). */
    function playPlaylist(name, start = 0) {
        const pl = root.library.find(p => p.name === name);
        if (!pl || pl.tracks.length === 0) return;
        // Before the first note, not after: the point is that the browser
        // goes quiet as the music starts, and the mpv commands below are
        // asynchronous, so claiming afterwards would leave a beat of overlap.
        root.claimOutput();
        // Record for the music tab's recent-playlists strip: most recent
        // first, deduplicated, capped at five (the strip's capacity).
        const recent = (Persistent.states.music.recentPlaylists ?? []).filter(n => n !== name);
        recent.unshift(name);
        Persistent.states.music.recentPlaylists = recent.slice(0, 5);
        // Where the library was left, so the sidebar comes back to this
        // playlist rather than to the first one alphabetically. The song is
        // recorded here too, and re-recorded by the queue listener below as
        // it changes -- so skipping forward through a playlist ends up
        // remembered as the track actually being played, not the one it
        // started on.
        Persistent.states.music.selectedPlaylist = name;
        root.rememberTrack(pl.tracks[Math.max(0, Math.min(start, pl.tracks.length - 1))]?.path ?? "");
        // `stop` FIRST, and it matters: mpv's `playlist-clear` clears the
        // playlist EXCEPT the currently-playing file, which it keeps at index
        // 0. Every appended track then lands one slot later than its sidebar
        // row, and `playlist-play-index i` played the row ABOVE the one the
        // user clicked. A stopped player has no current file, so the appends
        // land at 0..N-1 exactly and the index is honest again.
        root.cmd(["stop"]);
        for (const t of pl.tracks)
            sock.write(JSON.stringify({ command: ["loadfile", t.path, "append-play"] }) + "\n");
        sock.flush();
        root.cmd(["playlist-play-index", start]);
        root.cmd(["set_property", "pause", false]);
        root.refreshQueue();
    }

    /** Append one track to the running queue (and play it if idle). */
    function queueTrack(path) {
        root.cmd(["loadfile", path, root.hasTrack ? "append" : "replace"]);
        if (!root.hasTrack) {
            // Only when this actually starts the music. Appending behind a
            // track that is already playing must not cut off whatever else
            // the user is listening to.
            root.claimOutput();
            root.cmd(["set_property", "pause", false]);
        }
    }

    // ── Artwork ─────────────────────────────────────────────────────────
    // Resolved in the SAME bash pass as the library scan, because that pass
    // already has the file list and a shell: asking "does a cover exist" per
    // track over IPC would be one round trip per song for a question the shell
    // answers instantly.
    //
    // Order of preference, cheapest first:
    //   1. a cover image sitting in the track's folder (cover.jpg and friends)
    //   2. the frame embedded in the mp3, already pulled into the shared cache
    //   3. nothing -> the note glyph
    // The cache is the SAME directory the MPRIS bridge writes to, so the bar,
    // the island and the sidebar all show the same image for a track instead
    // of each holding its own copy.
    readonly property string artCache: `${Quickshell.env("HOME")}/.cache/ii-music-art`

    /**
     * The cache key for one track. It MUST match what the scan's shell builds
     * for the same file (`tr -c 'A-Za-z0-9' '_' | cut -c1-80`), because the
     * scan is what discovers the cached file in the first place.
     *
     * The subtlety is BYTES, not characters. `tr -c` rewrites every byte that
     * is not in the set, and a non-ASCII character is several bytes: the É in
     * "DJ STÉFANO" is two, so the shell produces ST__FANO. This used to run a
     * plain per-character regex, which produced ST_FANO and therefore never
     * matched the file the shell had written -- every lookup for a track with
     * an accent (or Japanese, or a Cyrillic name) silently missed. Encoding to
     * UTF-8 first and mapping over the bytes reproduces `tr` exactly, in every
     * locale, because the mapping no longer depends on a locale at all.
     */
    function cachedArtName(path) {
        const bytes = [];
        for (const b of new TextEncoder().encode(path)) {
            const c = String.fromCharCode(b);
            bytes.push((b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5a)
                || (b >= 0x61 && b <= 0x7a) ? c : "_");
        }
        return `${bytes.join("").slice(0, 80)}.jpg`;
    }

    /**
     * The scan command. Emits `<path>|||<art>` per track, art empty when there
     * is none. A sibling cover wins over the cache because it is the
     * deliberate choice of whoever curated the folder.
     */
    function scanCommand() {
        const cache = root.artCache;
        return [
            "bash", "-c",
            `find '${root.musicDir}' -name '*.mp3' | sort | while IFS= read -r f; do
                 d=$(dirname "$f")
                 art=""
                 for n in cover folder album front; do
                   for e in jpg jpeg png webp; do
                     if [ -f "$d/$n.$e" ]; then art="$d/$n.$e"; break 2; fi
                   done
                 done
                 if [ -z "$art" ]; then
                   key=$(printf '%s' "$f" | tr -c 'A-Za-z0-9' '_' | cut -c1-80)
                   if [ -f "${cache}/$key.jpg" ]; then art="${cache}/$key.jpg"; fi
                 fi
                 printf '%s|||%s\n' "$f" "$art"
               done`
        ];
    }

    /**
     * Extraction is delegated to scripts/music/extract-art.sh, which does its
     * own `find`.
     *
     * The obvious alternative -- building one `ffmpeg ...; ffmpeg ...` string
     * with every library path spliced in -- was tried and it fails: bash
     * rejects the whole batch with "syntax error near unexpected token", and
     * because it is all-or-nothing every good extraction dies with the bad one.
     * Letting the script find its own files removes the quoting minefield
     * entirely, and one unreadable file can no longer cost the other 124.
     */
    property bool extracting: false
    // extractArt() ends with a rescan, and the rescan is what discovers the
    // newly cached covers. Without a one-shot guard that is an infinite
    // loop: a track that genuinely has no embedded frame never gains art, so
    // every scan would queue it again.
    property bool artAttempted: false

    Process {
        id: artProc
        stdout: StdioCollector {
            onStreamFinished: console.log("[MusicArt]", String(text ?? "").trim())
        }
        stderr: StdioCollector {
            onStreamFinished: console.log("[MusicArt] err:", String(text ?? "").slice(0, 300))
        }
        onExited: {
            root.extracting = false;
            // The run that just finished may have probed durations for files
            // the scan had already recorded without one.
            root.readDurations();
            root.rescan();
        }
    }

    function extractArt() {
        if (root.extracting || root.artAttempted) return;
        root.artAttempted = true;
        root.extracting = true;
        artProc.command = [
            "bash",
            // Directories.scriptPath is a file:// URL; the same .replace the
            // rest of the services use turns it into a real path.
            `${Directories.scriptPath}/music/extract-art.sh`.replace(/file:\/\//, ""),
            root.musicDir,
            root.artCache,
        ];
        artProc.running = false;
        artProc.running = true;
    }

    // Deferred one tick: extractArt() reads root.library, which is assigned
    // immediately AFTER this handler returns. Calling it inline would scan the
    // PREVIOUS library.
    Timer {
        id: extractArtSoon
        interval: 300
        onTriggered: root.extractArt()
    }

    // ── Durations ────────────────────────────────────────────────────────
    // scripts/music/extract-art.sh writes "<path>\t<seconds>" per track into
    // the art cache and only probes files it has not seen before, so this is
    // one read of a small text file rather than 125 ffprobe calls.
    //
    // It is a MAP, not a second copy of the library: the library is rebuilt
    // from scratch on every scan (every 60s, and after every download) and
    // stamping each track's length at parse time would mean the UI has to
    // re-bind whenever the cache is replaced. A lookup keyed on path survives
    // that, and the panel's time column is right even for a track that was
    // scanned before its duration was ever known.
    property var durations: ({})

    function readDurations() {
        durView.path = Qt.resolvedUrl(`${root.artCache}/durations.tsv`);
        durView.reload();
    }

    function parseDurations(raw) {
        const map = {};
        for (const line of String(raw ?? "").split("\n")) {
            if (line.length === 0) continue;
            const tab = line.indexOf("\t");
            if (tab <= 0) continue;
            const secs = parseInt(line.slice(tab + 1), 10);
            if (!isNaN(secs)) map[line.slice(0, tab)] = secs;
        }
        root.durations = map;
    }

    FileView {
        id: durView
        // Qt.resolvedUrl + watchChanges + a reload on change is the idiom the
        // rest of the shell's FileViews use. `text` is a METHOD on this build,
        // not a property: reading `text` in a handler silently yields the
        // function object, String()s it to source code, and the map ends up
        // empty with nothing logged -- which is exactly what a time column of
        // zeroes looks like from the other end.
        printErrors: false
        watchChanges: true
        onFileChanged: this.reload()
        onLoadedChanged: root.parseDurations(durView.text())
    }

    function durationOf(path) {
        const s = root.durations[path];
        return s === undefined ? 0 : s;
    }

    Component.onCompleted: root.readDurations()

    // ── Library scan: plain filesystem read, no player involved ──────────
    function rescan() {
        root.scanning = true;
        scanProc.command = root.scanCommand();
        scanProc.running = false;
        scanProc.running = true;
    }

    Process {
        id: scanProc
        stdout: StdioCollector {
            onStreamFinished: {
                const groups = {};
                for (const line of String(text ?? "").split("\n")) {
                    const raw = line.trim();
                    if (raw.length === 0) continue;
                    // The scan emits "<path>|||<art>". Split ONCE, up front:
                    // parsing the art field after already slicing the path out
                    // of `raw` is how the folder/title derivation ends up
                    // working on a string that still has "|||" glued to it.
                    const split = raw.indexOf("|||");
                    const p = (split === -1 ? raw : raw.slice(0, split)).trim();
                    const art = split === -1 ? "" : raw.slice(split + 3).trim();
                    if (p.length === 0) continue;
                    const rel = p.slice(root.musicDir.length + 1);
                    const slash = rel.indexOf("/");
                    const folder = slash === -1 ? "Music" : rel.slice(0, slash);
                    const base = rel.slice(slash + 1).replace(/\.mp3$/, "");
                    const dash = base.indexOf(" - ");
                    if (groups[folder] === undefined) groups[folder] = [];
                    groups[folder].push({
                        path: p,
                        title: dash === -1 ? base : base.slice(dash + 3),
                        artist: dash === -1 ? "" : base.slice(0, dash),
                        art: art,
                    });
                }
                // The scan has just told us which tracks have no art yet;
                // pull their embedded frames in the background.
                if (!root.artAttempted) extractArtSoon.restart();
                root.library = Object.keys(groups).sort().map(name => ({
                    name, dir: `${root.musicDir}/${name}`, tracks: groups[name],
                }));
                root.scanning = false;
            }
        }
    }

    // Rescan periodically while downloads are running, and once at start.
    Timer {
        interval: 60000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.rescan()
    }

    // ── Playlist editing: add a track, or create a playlist ──────────────
    //
    // Everything above this point only ever READS the library. The data model
    // is folders, so writing is deliberately dumb: hand the work to
    // scripts/music/playlist-edit.sh and rescan. There is no database to keep
    // in step and nothing in playback that has to learn a new concept.
    //
    // The name handling and the hardlink-then-copy fallback live in the script
    // rather than here on purpose. Splicing a path into a bash string from JS
    // is how the cover-extraction code ended up needing its own script, and a
    // playlist name is user input -- it must be validated as a path segment
    // somewhere that cannot get the quoting wrong.
    readonly property string playlistEditScript:
        `${Quickshell.env("HOME")}/.config/quickshell/ii/scripts/music/playlist-edit.sh`

    // The result of the last edit, as the script's single status token:
    // "LINKED" | "COPIED" | "DUPLICATE" | "CREATED" | "EXISTS" | "ERROR",
    // with `lastOpDetail` carrying the rest of the line. The UI keys off
    // lastOp only; nothing parses the detail.
    property string lastOp: ""
    property string lastOpDetail: ""

    function addToPlaylist(trackPath, playlistName) {
        if (!trackPath || !playlistName) return;
        ensureDaemon();
        root.lastOp = "BUSY";
        root.lastOpDetail = "";
        editProc.command = ["bash", root.playlistEditScript, "add", trackPath, playlistName];
        editProc.running = false;
        editProc.running = true;
    }

    function createPlaylist(playlistName) {
        const name = String(playlistName ?? "").trim();
        if (name === "") return;
        root.lastOp = "BUSY";
        root.lastOpDetail = "";
        editProc.command = ["bash", root.playlistEditScript, "create", name];
        editProc.running = false;
        editProc.running = true;
    }

    Process {
        id: editProc
        stdout: StdioCollector {
            onStreamFinished: {
                // One line, but split anyway: if the script ever grows a
                // warning, the LAST line is still the status token.
                const lines = String(text ?? "").trim().split("\n").filter(l => l.length > 0);
                const line = lines.length > 0 ? lines[lines.length - 1] : "";
                const sp = line.indexOf(" ");
                root.lastOp = sp === -1 ? line : line.slice(0, sp);
                root.lastOpDetail = sp === -1 ? "" : line.slice(sp + 1);
                // A rescan is what makes a new track or playlist appear; the
                // 60s poll would otherwise make the UI look broken for a
                // minute after every add.
                if (root.lastOp === "LINKED" || root.lastOp === "COPIED"
                    || root.lastOp === "CREATED")
                    root.rescan();
            }
        }
        stderr: StdioCollector {
            onStreamFinished: {
                const e = String(text ?? "").trim();
                if (e.length > 0) {
                    root.lastOp = "ERROR";
                    root.lastOpDetail = e.slice(0, 200);
                }
            }
        }
    }

    // ── IPC: `qs -c ii ipc call music …` ─────────────────────────────────
    IpcHandler {
        target: "music"

        function status(): string {
            const per = root.library.map(p => `${p.name}:${p.tracks.length}`).join(", ");
            return `daemon=${root.daemonUp} playing=${!root.paused && root.hasTrack}`
                + ` track=${root.trackTitle || "-"} pos=${root.queuePos + 1}/${root.queue.length}`
                + ` total=${root.totalTracks} [${per}]`;
        }

        function show(): void {
            GlobalStates.sidebarLeftOpen = true;
            GlobalStates.sidebarLeftTargetTab = "Music";
        }


        function playPause(): void { root.ensureDaemon(); root.playPause(); }
        function next(): void { root.next(); }
        function previous(): void { root.previous(); }
        function stop(): void { root.stop(); }

        function play(name: string): void {
            root.ensureDaemon();
            root.playPlaylist(name);
        }

        function refresh(): void { root.rescan(); }

        // Playlist editing is on the bus too, so the desktop music app can
        // drive the same folders instead of growing a second writer. It
        // returns nothing on purpose -- the caller watches `lastOp` rather
        // than a synchronous result, because the work is a Process.
        function addToPlaylist(trackPath: string, playlist: string): void {
            root.addToPlaylist(trackPath, playlist);
        }
        function createPlaylist(playlist: string): void {
            root.createPlaylist(playlist);
        }
    }
}
