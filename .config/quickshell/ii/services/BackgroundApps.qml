pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs
import qs.modules.common

/**
 * The BACKGROUND-APPS REGISTRY: which of the shell's own desktop apps are
 * running right now with no window on screen.
 *
 * The problem it solves
 * ---------------------
 * The Music app is a face of the music daemon: closing its window only hides
 * it, so the song keeps playing and the process stays alive. That is exactly
 * what was asked for -- and it creates a gap. A window you closed is a window
 * you can no longer find, so the app needs one home of its own, independent of
 * whether it currently has a window. This is that home.
 *
 * How an app joins
 * ----------------
 * By writing a presence file, the same pattern PopupApps uses for the popup
 * group (and the reason both work: the shell and the apps are separate
 * processes, so no in-memory signal can cross between them):
 *
 *     $XDG_RUNTIME_DIR/quickshell-bgapp-<name>   containing the app's pid
 *
 * The Music app writes it at startup and removes it on a real quit. Because it
 * is written at STARTUP rather than when a window appears, an app whose window
 * is closed still shows up here -- which is the whole point. A new background
 * app joins by writing that file; it does not have to be listed anywhere.
 *
 * Why the process, not the file, is the authority
 * -----------------------------------------------
 * A pid alone cannot be trusted: pids are reused, and an app can die without
 * clearing its file (a crash, a kill -9). So the file only says WHO claims to
 * be running; the live process table decides whether it still is. A stale file
 * is dropped rather than shown as a phantom entry -- an app that is not really
 * running must never offer a Quit button, and the registry does not have to
 * guess about cleanup.
 */
Singleton {
    id: root

    // ── What a registered app looks like to the UI ───────────────────────
    // { id, name, icon, pid, summary, show(), quit() }
    readonly property var apps: appList
    readonly property bool anyRunning: appList.length > 0
    readonly property int runningCount: appList.length

    property var appList: []

    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") ?? "/tmp"
    readonly property string presenceGlob: `${root.runtimeDir}/quickshell-bgapp-*`

    // 1 Hz is plenty: these files change on app start and app quit, a handful
    // of times a session. Polling twice a second is far cheaper than an
    // inotify watch that has to survive writers dying without cleaning up.
    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: { const t = Date.now(); root.refresh(); StatusSignal.perfMark("bgApps", Date.now() - t); }
    }

    function refresh() {
        probe.running = false;
        probe.running = true;
    }

    // Discover and vet in ONE spawn.
    //
    // Two lines per candidate: the file's name, then "1" or "0" for whether
    // the pid it names is really alive. `kill -0` is the check, because it is
    // exactly the question being asked ("is there a process I may signal?")
    // and it needs no output parsing at all.
    //
    // Earlier versions read the pid out of a `ps -o pid=,args=` dump and
    // matched it in QML. That is fragile in a way this is not: this machine's
    // ps right-aligns the pid in a padded field, so the split has to survive
    // leading whitespace, and a missed split silently reads as "not running"
    // and lists nothing. Here a failure would have to make `kill` itself
    // misbehave, and a wrong answer is impossible to produce by accident.
    Process {
        id: probe
        command: ["sh", "-c",
            `for f in ${root.presenceGlob}; do
                 [ -e "$f" ] || continue
                 pid=$(head -n 1 "$f" 2>/dev/null | tr -d '[:space:]')
                 printf "%s\\n" "$(basename "$f")"
                 if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                     printf "1\\n"
                 else
                     printf "0\\n"
                 fi
             done`]
        stdout: StdioCollector {
            onStreamFinished: root.ingest(text ?? "")
        }
    }

    /**
     * Turn the probe's output into UI rows.
     *
     * A file whose pid is NOT alive is dropped rather than shown. That is the
     * whole reason liveness is decided here and not by the file: an app can
     * die without clearing its presence file (a crash, a kill -9, a power
     * event), and a "what is running?" list that offers to quit something
     * that is not running is worse than one that quietly forgets it.
     *
     * A file with no pid at all is kept: the app claimed a name and nothing
     * contradicts it, and dropping it would hide an app that is working.
     */
    function ingest(raw) {
        const lines = String(raw).split("\n")
            .map(l => l.trim())
            .filter(l => l.length > 0);
        const entries = [];
        for (let i = 0; i + 1 < lines.length; i += 2) {
            const file = lines[i];
            const id = file.replace(/^quickshell-bgapp-/, "");
            if (id.length === 0 || file === id)
                continue;   // not one of ours
            // "0" means the pid named a process that is not there.
            if (lines[i + 1] === "0")
                continue;
            const pid = parseInt(lines[i + 1], 10);
            entries.push(describe({ id: id, pid: isNaN(pid) ? 0 : pid }, ""));
        }
        root.publish(entries);
    }

    // The list only changes when the SET of apps or a row's summary changes,
    // so a repaint is not paid once a second for nothing. `summary` is part of
    // the comparison because the Music row's line tracks the track title.
    function publish(entries) {
        entries.sort((x, y) => x.order - y.order || x.name.localeCompare(y.name));
        let same = entries.length === root.appList.length;
        if (same) {
            for (let i = 0; i < entries.length; i++) {
                if (entries[i].id !== root.appList[i].id
                    || entries[i].summary !== root.appList[i].summary) {
                    same = false;
                    break;
                }
            }
        }
        if (!same)
            root.appList = entries;
    }

    /**
     * Turn a discovered {id, pid} into a UI row.
     *
     * `show` / `quit` are deliberately GENERIC and drive the app through the
     * two channels every app already has:
     *
     *   show  launch the app again. Because each one is a Gio.Application with
     *         a stable application_id, the launch is handed to the RUNNING
     *         instance, which re-presents its existing window. Nothing is
     *         started twice, and the music the app was playing is untouched --
     *         the window comes back, the state never left.
     *   quit  SIGTERM the process. Deliberately SIGTERM and not SIGKILL: the
     *         app then clears its own presence file on the way out, so the
     *         row disappears through the normal path instead of the registry
     *         having to notice a corpse.
     *
     * Neither ever touches the music DAEMON, which is a separate systemd unit.
     * Quitting the Music app is not quitting the music.
     */
    function describe(a, args) {
        const known = knownApps[a.id];
        return {
            id: a.id,
            name: known?.name ?? a.id,
            icon: known?.icon ?? "apps",
            order: known?.order ?? 50,
            pid: a.pid,
            args: args,
            summary: known?.summary?.() ?? Translation.tr("Running"),
            show: () => root.showApp(a.id),
            quit: () => root.quitApp(a),
        };
    }

    // The apps this shell ships, in listing order. An app not named here still
    // works -- it shows with a generic name at the end -- so adding one to this
    // table is a nicety (a proper name, an icon, a live subtitle), not a
    // requirement for it to be tracked.
    readonly property var knownApps: ({
        "music": {
            name: "Music",
            icon: "music_note",
            order: 10,
            launch: "ii-music-app",
            summary: () => root.musicSummary(),
        }
    })

    // Live one-liner for the Music row. Read from the MPRIS bridge rather than
    // from the app, so it stays true whether the song was started in the
    // sidebar, in the app, or from the bar.
    function musicSummary() {
        try {
            const p = MprisController.activePlayer;
            if (p && p.dbusName === "org.mpris.MediaPlayer2.iiMusic") {
                const t = String(p.trackTitle ?? "").trim();
                if (t.length === 0)
                    return "Nothing playing";
                return p.isPlaying ? `Playing · ${t}` : `Paused · ${t}`;
            }
        } catch (e) {
            // No player, or the Mpris service is not up yet: fall through.
        }
        return "Running";
    }

    /**
     * Bring a hidden app's window back.
     *
     * Launching the app is the mechanism, not a way to start a second one: the
     * single-instance application_id is what turns this into "present the
     * window you already have".
     *
     * THROUGH GlobalStates.openApp, not a bare execDetached. Two things were
     * missing when this was its own exec, and both are exactly what every
     * other launch in the desktop already had:
     *
     *   * the top bar's loading line. `openApp` is what calls showLoading, so
     *     the bar could not mark the wait for this path at all -- pressing
     *     "show" on a cold Music app produced a window out of nowhere with no
     *     sign the desktop had been asked for anything, which is the one
     *     thing a desktop should never do;
     *   * the already-open redirect and the duplicate-launch fold, so a
     *     second press could race a first into two processes.
     *
     * `open.sh` also records the pid in the compositor's launcher registry,
     * which is what makes the window attach to the layout instead of coming
     * up as a utility popup.
     */
    function showApp(id) {
        const bin = knownApps[id]?.launch ?? id;
        const name = knownApps[id]?.name ?? id;
        GlobalStates.openApp(bin, name);
    }

    function quitApp(a) {
        if (!a || a.pid <= 0)
            return;
        Quickshell.execDetached(["kill", "-TERM", String(a.pid)]);
    }

    // "Quit all" for the popover's footer. NOT wired to a right-click on the
    // bar icon: one mis-click would then take down every background app at
    // once, which is a far worse mistake than an extra click.
    function quitAll() {
        for (const a of root.appList.slice())
            root.quitApp(a);
    }

    IpcHandler {
        target: "backgroundApps"

        function list(): string {
            return root.appList.length === 0
                ? "none"
                : root.appList.map(a => `${a.name}(${a.pid})`).join(", ");
        }
        function refresh(): void { root.refresh(); }
        function show(id: string): void { root.showApp(id); }
        function quit(id: string): void {
            const a = root.appList.find(x => x.id === id);
            if (a)
                root.quitApp(a);
        }
    }
}
