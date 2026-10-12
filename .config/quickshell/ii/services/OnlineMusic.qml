pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs

/**
 * The online catalog: search, play and download, on top of the local library.
 *
 * WHAT THIS IS NOT
 * ----------------
 * Playback is still 100% local. The mpv daemon (ii-music-mpd.service) plays
 * files off disk out of ~/Music/Spotify, exactly as before, and nothing here
 * changes that. This service only ADDS a way to find things and to put them on
 * disk (or straight into the queue) once you have picked them.
 *
 * WHY AUDIUS
 * ----------
 * Audius is artist-owned: the people making the music decide whether a track
 * is streamable and whether it may be downloaded (`access.download`), and the
 * API exposes both. There is no ad layer to strip out and no account to hold,
 * which is precisely why a legal "look online, play ad-free, download if I
 * want" player can be built on it. The honest limitation: it is an independent
 * catalogue, not the mainstream one, so expect remixes and community uploads
 * rather than label masters.
 *
 * The API is public and keyless. `app_name` is the only required parameter and
 * Audius uses it for rate limiting, so it is a real name rather than a
 * throwaway.
 */
Singleton {
    id: root

    // ── Config ─────────────────────────────────────────────────────────
    readonly property string apiBase: "https://discoveryprovider.audius.co/v1"

    // Downloaded online tracks land beside the local ones so the library scan
    // picks them up with no extra plumbing. Both this and appName follow the
    // persisted settings, so changing them in the app changes them HERE too --
    // a constant here would have quietly ignored the user's choice.
    readonly property string downloadDir: `${Quickshell.env("HOME")}/${MusicPlayer.settings.downloadFolder}`
    readonly property string appNameSetting: MusicPlayer.settings.onlineAppName

    // How long a search may take before it is called failed.
    readonly property int searchTimeoutMs: 12000

    // ── Paging ─────────────────────────────────────────────────────────
    //
    // "All the songs" is a paging problem, not a limit problem. The search
    // endpoint returns 10 rows with no parameters at all, and honours
    // limit/offset (verified against the live API: limit=100 returns 100,
    // offset=10 returns a different first row). So results ACCUMULATE across
    // pages and the UI asks for more, rather than being silently cut at
    // whatever the first page happened to hold.
    readonly property int pageSize: 50
    property int offset: 0
    property bool hasMore: false

    // ── State ──────────────────────────────────────────────────────────
    property bool searching: false
    property string query: ""
    property string lastError: ""
    // [{id, title, artist, artUrl, streamUrl, downloadable, duration, plays, localPath}]
    property var results: []
    // id -> saved file path, for rows that have been downloaded this session.
    // The row needs this because after a save the track is ALSO a local
    // library entry, and without it the same song shows up twice with no way
    // to tell which one is on the disk yet.
    property var saved: ({})
    // Set while a download runs, so the row can show progress and the button
    // can disable itself.
    property string downloadingId: ""
    property real downloadProgress: 0

    // ── Search ─────────────────────────────────────────────────────────
    // NO type annotations on a plain QML function: this engine's JS parser
    // rejects them outright ("Type annotations are not supported (yet)") and
    // takes the WHOLE config down with it. Annotations are only allowed on
    // IpcHandler functions, where Quickshell parses them itself.
    function search(text, append = false) {
        const q = (text ?? "").trim();
        root.query = q;
        root.lastError = "";
        if (q.length < 2) {
            root.results = [];
            root.searching = false;
            root.hasMore = false;
            root.offset = 0;
            return;
        }
        // A new query throws away what is loaded; loadMore() passes append and
        // keeps it. Mixing pages of two different queries in one list would
        // be worse than either behaviour on its own.
        if (!append) {
            root.results = [];
            root.offset = 0;
        }
        root.searching = true;
        searchTimeout.restart();
        const from = append ? root.offset : 0;
        http.get(`${root.apiBase}/tracks/search?query=${encodeURIComponent(q)}`
                 + `&limit=${root.pageSize}&offset=${from}`
                 + `&app_name=${encodeURIComponent(root.appNameSetting)}`,
                 (parsed) => root._onSearchOk(parsed, append), root._onSearchFail);
    }

    /** Ask for the next page of the current query. */
    function loadMore() {
        if (root.searching || !root.hasMore) return;
        if (root.query.trim().length < 2) return;
        root.search(root.query, true);
    }

    function clear() {
        root.query = "";
        root.results = [];
        root.lastError = "";
        root.offset = 0;
        root.hasMore = false;
        searchTimeout.stop();
    }

    function _onSearchOk(parsed, append) {
        searchTimeout.stop();
        try {
            const data = parsed.data ?? [];
            const fresh = data.map(t => root._map(t)).filter(t => t.streamUrl !== "");
            if (append) {
                // Dedupe by id: two pages of a shifting index can overlap, and
                // the same row twice is worse than one row missing.
                const seen = {};
                for (const t of root.results) seen[t.id] = true;
                root.results = root.results.concat(fresh.filter(t => !seen[t.id]));
            } else {
                root.results = fresh;
            }
            root.offset += data.length;
            // A short page is the last page: the endpoint simply stops
            // returning rows, so "fewer than we asked for" is the only
            // end-of-results signal there is.
            root.hasMore = data.length >= root.pageSize;
        } catch (e) {
            if (!append) root.results = [];
            root.lastError = "Could not read the search response";
            root.hasMore = false;
        }
        root.searching = false;
    }

    function _onSearchFail(msg) {
        searchTimeout.stop();
        root.searching = false;
        root.results = [];
        root.lastError = `Search failed (${msg})`;
    }

    // HTTP: the XMLHttpRequest-inside-a-QtObject idiom from Booru.qml, which
    // is the pattern already proven to work under this shell's engine.
    QtObject {
        id: http
        function get(url, onOk, onFail) {
            const xhr = new XMLHttpRequest();
            xhr.open("GET", url);
            xhr.onreadystatechange = function() {
                if (xhr.readyState !== XMLHttpRequest.DONE)
                    return;
                if (xhr.status === 200) {
                    try { onOk(JSON.parse(xhr.responseText ?? "{}")); }
                    catch (e) { onFail("Could not read the response"); }
                } else {
                    onFail(`HTTP ${xhr.status}`);
                }
            };
            try { xhr.send(); } catch (e) { onFail("Request could not be sent"); }
        }
    }

    Timer {
        id: searchTimeout
        interval: root.searchTimeoutMs
        onTriggered: {
            if (root.searching) {
                root.searching = false;
                root.lastError = "Search timed out";
            }
        }
    }

    /** One Audius track -> the shape the UI binds to. */
    function _map(t) {
        const art = (t.artwork ?? {});
        const access = t.access ?? {};
        return {
            id: t.id ?? "",
            title: t.title ?? "Unknown",
            artist: t.user?.name ?? "Unknown artist",
            artUrl: art["480x480"] ?? art["150x150"] ?? "",
            // Audius resolves the stream through an endpoint that redirects to
            // the CDN; `stream_url` is null in search results, so it is always
            // built from the id.
            streamUrl: t.id ? `${root.apiBase}/tracks/${t.id}/stream?app_name=${encodeURIComponent(root.appNameSetting)}` : "",
            downloadable: access.download === true,
            duration: t.duration ?? 0,
            plays: t.favorite_count ?? 0,
            localPath: "",
        };
    }

    // ── Play / download ────────────────────────────────────────────────
    /**
     * Queue a track for immediate playback without touching the disk.
     *
     * mpv streams the URL directly, so this is instant and leaves no file
     * behind -- the "just listen" path. The library scan is untouched, so a
     * stream never pollutes the local library.
     */
    function playNow(track) {
        if (!track?.streamUrl) return;
        // `replace`, not `append-play`: playlist-clear spares the CURRENTLY
        // playing file, so with append-play a running local song kept playing
        // and the stream was queued behind it -- "I clicked online, an offline
        // song played". replace stops the current file and starts the stream
        // now.
        //
        // `force-media-title` rides along as a per-file option: without it
        // mpv names a bare stream after its URL, and the top bar read
        // "stream?app_name=ii" as the song name. The bridge reads this
        // property for the bar's label.
        MusicPlayer.cmd(["playlist-clear"]);
        // mpv 0.38+: per-file options are the FIFTH loadfile argument (after
        // the insertion index), not the fourth. The 4th-arg shape was rejected
        // with "invalid parameter" on this build (v0.41).
        MusicPlayer.cmd(["loadfile", track.streamUrl, "replace", -1, {
            "force-media-title": (track.artist && track.artist.length > 0
                ? track.artist + " - " : "") + (track.title ?? "Online track")
        }]);
        MusicPlayer.cmd(["set_property", "pause", false]);
        MusicPlayer.refreshQueue();
    }

    /** Put a track on the end of the current queue. */
    function queueTrack(track) {
        if (!track?.streamUrl) return;
        MusicPlayer.cmd(["loadfile", track.streamUrl, "append"]);
        if (!MusicPlayer.hasTrack)
            MusicPlayer.cmd(["set_property", "pause", false]);
    }

    /**
     * Put a track on the disk so it plays with no network.
     *
     * `folder` is OPTIONAL and that is the whole point of the API shape:
     *
     *  - omitted  -> the standalone bucket (`downloadDir`, by default
     *    ~/Music/Spotify/Audius): saved offline, deliberately in none of the
     *    user's playlists. The library is folder-per-playlist, so a file has
     *    to live somewhere; this is the somewhere that means "just keep it".
     *  - a name   -> that playlist. Creating the folder is part of the
     *    download, so a playlist that did not exist yet still works.
     *
     * Either way the file lands inside the library root and the next scan
     * picks it up, which is what makes it a local track rather than a cache.
     */
    function download(track, folder = "") {
        if (!track?.streamUrl || root.downloadingId !== "") return "";
        root.downloadingId = track.id;
        root.downloadProgress = 0;
        const dir = root.targetDir(folder);
        const path = `${dir}/${root.sanitize(track.artist)} - ${root.sanitize(track.title)}.mp3`;
        root.pendingPath = path;
        // curl -L because the stream endpoint 302s to the CDN, and --fail so an
        // HTML error page is never written out as a "song". The folder is
        // created here rather than by a library rescan, so the file exists
        // before the rescan looks for it.
        dlProc.command = [
            "bash", "-c",
            `mkdir -p "${dir}" && `
            + `curl -L --fail --remove-on-error --silent --show-error `
            + `-o "${path}" "${track.streamUrl}" && echo ok`
        ];
        dlProc.running = false;
        dlProc.running = true;
        return path;
    }

    /** Save into a named playlist (created if it does not exist). */
    function saveTo(track, playlistName) {
        const name = String(playlistName ?? "").trim();
        if (name === "") return download(track);
        return download(track, name);
    }

    /** Absolute directory a save lands in. */
    function targetDir(folder = "") {
        const name = root.sanitize(String(folder ?? "").trim());
        if (name === "") return root.downloadDir;
        return `${MusicPlayer.musicDir}/${name}`;
    }

    /** Where a track was saved this session, or "" if it was not. */
    function savedPath(track) {
        return root.saved[track?.id ?? ""] ?? "";
    }

    // The file being written right now, so a success can be recorded against
    // the track it belongs to.
    property string pendingPath: ""
    // The last thing curl wrote to stderr, for the failure message.
    property string dlErr: ""

    /** Called from dlProc.onExited: decide whether the save worked. */
    function _finishDownload(code) {
        const id = root.downloadingId;
        const path = root.pendingPath;
        if (code === 0) {
            root.lastError = "";
            // Remember it so the row can say "saved" instead of offering the
            // same download twice. Re-assign a copy: mutating the object in
            // place does not emit changed(), so the UI would never update.
            if (id !== "" && path !== "") {
                const s = Object.assign({}, root.saved);
                s[id] = path;
                root.saved = s;
            }
            // Re-scan so the new file appears in the library list (unless the
            // user turned that off in settings).
            if (MusicPlayer.settings.rescanAfterDownload)
                MusicPlayer.rescan();
        } else if (code === 22 && /404/.test(root.dlErr)) {
            // Not a bug in the URL: Audius indexes a handful of tracks whose
            // file no longer resolves ("track not found"), and curl --fail
            // turns that into exit 22. Say so in words, not in curl.
            root.lastError = "This track can no longer be downloaded";
        } else {
            root.lastError = root.dlErr !== "" ? root.dlErr : "Download failed";
        }
        root.downloadingId = "";
        root.pendingPath = "";
        root.dlErr = "";
        root.downloadProgress = 0;
    }

    /** Filesystem-safe "Artist - Title". */
    function sanitize(s) {
        return String(s ?? "")
            .replace(/[\/\\?%*:|"<>]/g, "-")
            .replace(/\s+/g, " ")
            .trim();
    }

    Process {
        id: dlProc
        // The verdict is decided in onExited, NOT in the collectors'
        // onStreamFinished. A collector finishes before Process.exitCode is
        // populated, so reading it there reports a perfectly good 3 MB
        // download as "Download failed" -- which is exactly what happened
        // before this was fixed. onExited is also what the rest of this
        // config already uses for exit codes.
        stderr: StdioCollector {
            onStreamFinished: {
                if (text) root.dlErr = String(text).trim().split("\n").pop();
            }
        }
        onExited: (code) => root._finishDownload(code ?? 0)
    }

    // ── IPC ────────────────────────────────────────────────────────────
    IpcHandler {
        target: "onlineMusic"

        function search(q: string): void { root.search(q); }
        function loadMore(): void { root.loadMore(); }
        function clear(): void { root.clear(); }
        /**
         * Save result `i` of the current query. An empty folder means the
         * standalone bucket, a name means that playlist -- the same two
         * choices the row's two buttons make.
         */
        function saveIndex(i: int, folder: string): string {
            const t = root.results[Math.max(0, i)];
            if (!t) return "no-such-result";
            if (t.downloadable !== true) return "not-downloadable";
            return root.download(t, folder);
        }
        /** Where saveIndex(i, folder) would write. */
        function targetFor(i: int, folder: string): string {
            const t = root.results[Math.max(0, i)];
            if (!t) return "";
            return `${root.targetDir(folder)}/${root.sanitize(t.artist)} - ${root.sanitize(t.title)}.mp3`;
        }
        function status(): string {
            return `query="${root.query}" results=${root.results.length}`
                + ` searching=${root.searching} dir=${root.downloadDir}`
                + ` offset=${root.offset} hasMore=${root.hasMore}`
                + ` saved=${Object.keys(root.saved).length}`
                + ` downloading="${root.downloadingId}"`
                + ` dlErr="${root.dlErr}"`
                + (root.lastError ? ` error=${root.lastError}` : "");
        }
        /** Where result `i` was saved, or "" -- proves a row flipped to "saved". */
        function savedFor(i: int): string {
            const t = root.results[Math.max(0, i)];
            if (!t) return "";
            return root.savedPath(t);
        }
    }
}
