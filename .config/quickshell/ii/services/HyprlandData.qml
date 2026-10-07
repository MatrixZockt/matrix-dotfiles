pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

/**
 * Provides access to some Hyprland data not available in Quickshell.Hyprland.
 */
Singleton {
    id: root
    property var windowList: []
    property var addresses: []
    property var windowByAddress: ({})
    property var workspaces: []
    property var workspaceIds: []
    property var workspaceById: ({})
    property var activeWorkspace: null
    // The window that currently holds focus, whole, exactly as the compositor
    // reports it -- or null when there is none (an empty desktop).
    //
    // It has to be ASKED for. Three cheaper answers were measured on this
    // build and all three are wrong:
    //   * `Hyprland.focusedWindow` does not exist in Quickshell 0.3.1 (it is a
    //     newer addition), so reading it yields undefined.
    //   * `Hyprland.activeToplevel` exists but stayed null on a desktop with a
    //     focused window, in a clean probe.
    //   * the highest `focusHistoryID` in the client list is NOT the focused
    //     window: with focus on one window, that field named a different one.
    // Two of those fail silently, which is the worst kind -- a title resolver
    // or a focus check built on them just quietly never fires.
    property var activeWindow: null
    property var monitors: []
    property var layers: ({})

    // Convenient stuff

    function toplevelsForWorkspace(workspace) {
        return ToplevelManager.toplevels.values.filter(toplevel => {
            const address = `0x${toplevel.HyprlandToplevel?.address}`;
            var win = HyprlandData.windowByAddress[address];
            return win?.workspace?.id === workspace;
        })
    }

    function hyprlandClientsForWorkspace(workspace) {
        return root.windowList.filter(win => win.workspace.id === workspace);
    }

    function clientForToplevel(toplevel) {
        if (!toplevel || !toplevel.HyprlandToplevel) {
            return null;
        }
        const address = `0x${toplevel?.HyprlandToplevel?.address}`;
        return root.windowByAddress[address];
    }

    // Internals

    // ── Client-list rate limit ─────────────────────────────────────────────
    //
    // Every raw Hyprland event used to re-fork `hyprctl clients -j`, and the
    // compositor emits events in BURSTS -- one real change (a click, a window
    // mapping, a workspace move) arrives as openwindow + movewindow +
    // activewindow + focusedmon within a few milliseconds. Forking the heaviest
    // reader in the shell once per event in that burst is what made the desktop
    // hitch: each fork starts a process, dials the IPC socket, re-serialises
    // every client's full record, and the result is parsed and diffused into
    // every binding that reads `windowList`.
    //
    // So the read is rate-limited instead of event-triggered: `clientsDirty`
    // is "a read is already scheduled", and a burst of any length collapses to
    // at most one `clients -j` per `clientsDebounce.interval`. Firing a fixed
    // 60ms after the FIRST event of a burst (rather than after the last) is
    // deliberate: a trailing debounce can be starved indefinitely by a stream
    // of events, whereas a leading one is a hard ceiling on how often the shell
    // may fork. 60ms is inside a single frame budget's worth of slack and far
    // shorter than anything a person can perceive in the bar's contents.
    property bool clientsDirty: false
    function clientsScheduled() {
        if (root.clientsDirty)
            return; // already scheduled; the burst adds nothing
        root.clientsDirty = true;
        clientsDebounce.restart();
    }

    function updateWindowList() {
        root.clientsScheduled();
    }

    function updateLayers() {
        getLayers.running = true;
    }

    function updateMonitors() {
        getMonitors.running = true;
    }

    function updateWorkspaces() {
        getWorkspaces.running = true;
        getActiveWorkspace.running = true;
    }

    function updateActiveWindow() {
        getActiveWindow.running = true;
    }

    // The rate limiter itself. `repeat: false` plus the dirty flag means one
    // refresh per window at most -- see the note on `clientsDirty` above.
    Timer {
        id: clientsDebounce
        interval: 60
        repeat: false
        onTriggered: {
            const t = Date.now();
            root.clientsDirty = false;
            getClients.running = true;
            StatusSignal.perfMark("hyprClientsFork", Date.now() - t);
        }
    }

    // ── Follow-up reads for geometry that lands WITHOUT an event ──────────
    //
    // Measured 2026-10-06: on this build the float/move/resize dispatchers
    // emit NO window event -- a cover (custom/cover.lua: float, then pin to
    // the full monitor) produced exactly one compositor event,
    // `changefloatingmode`, fired when the float was applied but BEFORE the
    // move/resize landed. The clients re-read triggered by that event
    // therefore still described the window at its old tile, every binding
    // reading `windowList` kept answering from that stale record, and the bar
    // only noticed the cover when some UNRELATED event (a TradingView title
    // tick) forced the next re-read -- measured 5.3s late on a busy desktop,
    // and with no ticking app at all it would never have happened.
    //
    // So a bounded series of re-reads is scheduled instead: three punches,
    // 140ms apart, each riding the normal 60ms coalesced fork. Bounded on
    // purpose -- this is a question that becomes true shortly after it is
    // asked and then stops changing, so a few retries cover the whole window
    // without turning into a poll. It is kicked from two places: the float
    // event itself, and the shell's cover latch (Bar.qml's onCover), which
    // knows a cover has just been requested.
    property int silentRecheckLeft: 0
    function recheckSilentGeometry(): void {
        root.silentRecheckLeft = 3;
        silentRecheckTimer.restart();
    }
    Timer {
        id: silentRecheckTimer
        interval: 140
        repeat: false
        onTriggered: {
            root.updateWindowList();
            root.silentRecheckLeft--;
            if (root.silentRecheckLeft > 0)
                silentRecheckTimer.restart();
        }
    }

    // Everything `updateAll()` used to do, in the same order. Only the client
    // read changed shape (it is coalesced now); monitors, layers, workspaces
    // and the focused window are still asked for on every event exactly as
    // before, because they are cheap reads and their consumers expect that
    // freshness.
    function updateAll() {
        const t = Date.now();
        root.clientsScheduled();
        updateMonitors();
        // NOT updateLayers() here. The layer list only ever changes when a
        // surface maps or goes away -- that is openlayer/closelayer, which the
        // raw-event handler below now routes to updateLayers() on its own.
        // Refreshing it on every window/workspace/focus event bought nothing
        // (the data is identical) and cost one `hyprctl layers -j` fork per
        // event, on the exact path -- a burst of window events while
        // maximizing or switching -- that has to stay cheap. Layers are also
        // now fresher when they DO change, because the event that changes them
        // is the one that used to return early without refreshing anything.
        updateWorkspaces();
        updateActiveWindow();
        StatusSignal.perfMark("hyprUpdateAll", Date.now() - t);
    }

    function biggestWindowForWorkspace(workspaceId) {
        const windowsInThisWorkspace = HyprlandData.windowList.filter(w => w.workspace.id == workspaceId);
        return windowsInThisWorkspace.reduce((maxWin, win) => {
            const maxArea = (maxWin?.size?.[0] ?? 0) * (maxWin?.size?.[1] ?? 0);
            const winArea = (win?.size?.[0] ?? 0) * (win?.size?.[1] ?? 0);
            return winArea > maxArea ? win : maxWin;
        }, null);
    }

    Component.onCompleted: {
        updateAll();
        // Layers are no longer part of updateAll (see the note there), so the
        // very first read has to be asked for here: the shell's own surfaces
        // map a moment later and would refresh it anyway via openlayer, but
        // RegionSelection reads this list and must not be able to catch the
        // window where nothing has asked for it yet.
        updateLayers();
    }

    // ── Desktop compaction ─────────────────────────────────────────────────
    // Hyprland destroys a workspace once it empties, but never renumbers the
    // ones after it: closing desktop 1 of [1,2,3] leaves [2,3]. The desktops
    // should be contiguous, so when a gap opens every workspace left of it
    // slides down by RENAMING IN PLACE -- hl.dsp.workspace.change_id retargets
    // the workspace object's id; its windows, their focus and the monitor's
    // active-workspace pointer all follow the object. Nothing is moved between
    // workspaces and nothing is destroyed (unlike window.move, which this
    // fork's compositor drops -- and onto a nonexistent workspace it even
    // eats the window -- so rename-in-place is the only safe primitive).
    property real lastCompactAt: 0
    Timer {
        id: compactDebounce
        interval: 450
        onTriggered: root.compactWorkspaces()
    }
    function requestCompaction(): void {
        // A shift itself emits events; the timestamp keeps the chain from
        // re-arming off its own dispatch.
        if (Date.now() - root.lastCompactAt < 700)
            return;
        compactDebounce.restart();
    }
    function compactWorkspaces(): void {
        root.lastCompactAt = Date.now();
        const occ = root.workspaces
            .filter(ws => ws.id >= 1 && ws.id <= 100 && (ws.windows ?? 0) > 0)
            .map(ws => ws.id)
            .sort((a, b) => a - b);
        for (let k = 0; k < occ.length; k++) {
            const target = k + 1;
            if (occ[k] <= target)
                continue; // contiguous so far
            // The target must be a true hole. If an EMPTY-but-alive workspace
            // sits there (the user is standing on it), renaming into it would
            // hijack their spot -- skip and let a later event retry.
            if (root.workspaceIds.includes(target))
                continue;
            // Standing on the SOURCE workspace is fine: change_id renames the
            // workspace object in place and the monitor's active pointer
            // follows the object, so the view never jumps -- only the number
            // changes under the user. (Verified live.)
            // Bare Lua expression -- the same proven form the bar's
            // switchWorkspaceToHovered uses; Hyprland.dispatch executes it.
            Hyprland.dispatch(`hl.dsp.workspace.change_id({ workspace = ${occ[k]}, id = ${target} })`);
            // One shift per pass; the rename's own event refreshes the data
            // and the guard-window expiry lets the next pass continue.
            Qt.callLater(() => compactDebounce.restart());
            return;
        }
    }

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            // console.log("Hyprland raw event:", event.name);
            // Layer surfaces come and go on their own events, and those used
            // to return WITHOUT refreshing anything -- so the layer list was
            // stale exactly when it changed, while being re-read on every
            // unrelated window event instead. Now: the layer event refreshes
            // layers and nothing else (opening a panel must not fork the whole
            // window/monitor/workspace/active-window set), and screencast
            // still changes no data any consumer reads.
            if (event.name === "openlayer" || event.name === "closelayer") {
                root.updateLayers();
                return;
            }
            if (["screencast"].includes(event.name)) return;
            // The one event whose follow-through is silent: the float applies
            // and is announced, but the move/resize that pin a covered window
            // to the monitor's full geometry arrive with no event at all (see
            // recheckSilentGeometry above), so this event schedules the
            // re-reads that will actually catch the final geometry.
            if (String(event.name).startsWith("changefloatingmode"))
                root.recheckSilentGeometry();
            // Unchanged in shape: every event still refreshes everything it
            // always did. The ONLY difference is that the client read inside
            // `updateAll()` is coalesced (see `clientsDirty`), so a burst of
            // events costs one `clients -j` instead of one per event.
            updateAll()
            // The focused window only needs re-asking when it could have
            // changed; a workspace switch moves it, and so does anything that
            // opens, closes or moves a window.
            if (["activewindow", "activewindowv2", "focusedmon", "focusedmonv2",
                "openwindow", "closewindow", "movewindow", "movewindowv2",
                "workspace", "workspacev2", "fullscreen"].includes(event.name))
                activeWindowDebounce.restart();
            // Window left a workspace (closed or moved away): close any gap
            // that leaves behind. Switch events are included so a compaction
            // that was deferred while the user stood on a just-emptied desk
            // still lands once they move away.
            if (["closewindow", "movewindow", "movewindowv2", "workspace", "activeworkspace", "activeworkspacev2"].includes(event.name))
                requestCompaction();
        }
    }

    Process {
        id: getClients
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector {
            id: clientsCollector
            onStreamFinished: {
                const __t = Date.now();
                try {
                // A FAILED READ MUST NOT LOOK LIKE AN EMPTY DESKTOP.
                //
                // Every reader here forks `hyprctl`, and `hyprctl` talks to
                // the compositor over a socket in $XDG_RUNTIME_DIR. When that
                // socket is missing -- it was deleted from /run on this
                // machine, once, and nothing recreated it -- every fork
                // returns "Couldn't connect" as its STDOUT, `JSON.parse`
                // throws, and the list silently stays whatever it was. An
                // empty array then reads as "there are no windows", which is
                // a real state and must look identical -- so every consumer
                // is quietly wrong.
                //
                // That is not theoretical. The bar's fullscreen test is
                // "is any window on this workspace fullscreen", answered from
                // this list: with the list empty the answer is permanently
                // NO, so the bar sat on top of fullscreen apps and refused to
                // hide. Nothing in the log said why -- only a repeated
                // "SyntaxError: JSON.parse", which does not name the cause and
                // is easy to write off as a schema change.
                //
                // So the failure says what it is, ONCE per transition rather
                // than once per event (the event stream re-asks on every
                // window/workspace change, and a broken session generates a
                // lot of them), and keeps the last GOOD list rather than
                // blanking it. A stale-but-real list degrades far better than
                // a confidently empty one: the bar may keep a fullscreen
                // window's verdict for a moment, but it never concludes "no
                // windows exist" from a broken pipe.
                let parsed;
                const __t1 = Date.now();
                try {
                    parsed = JSON.parse(clientsCollector.text);
                } catch (error) {
                    root.reportUnreachable();
                    return;
                }
                StatusSignal.perfMark("clJson", Date.now() - __t1);
                if (!Array.isArray(parsed)) {
                    root.reportUnreachable();
                    return;
                }
                const __t2 = Date.now();
                root.reportReachable();
                root.windowList = parsed;
                StatusSignal.perfMark("clAssignList", Date.now() - __t2);
                const __t3 = Date.now();
                let tempWinByAddress = {};
                for (var i = 0; i < root.windowList.length; ++i) {
                    var win = root.windowList[i];
                    tempWinByAddress[win.address] = win;
                }
                root.windowByAddress = tempWinByAddress;
                StatusSignal.perfMark("clByAddr", Date.now() - __t3);
                const __t4 = Date.now();
                root.addresses = root.windowList.map(win => win.address);
                StatusSignal.perfMark("clAddresses", Date.now() - __t4);
                } finally {
                    StatusSignal.perfMark("hyprClientsParse", Date.now() - __t);
                }
            }
        }
    }

    // ── Is the compositor actually reachable? ────────────────────────────────
    // The one-line summary of the failure above, for the log. See the note on
    // `getClients` for why this is not a luxury: the symptom it explains (a
    // bar that ignores fullscreen, a window list that reads empty) looks like
    // a shell bug and sends you looking in the wrong file entirely.
    property bool compositorReachable: true
    function reportUnreachable() {
        if (!root.compositorReachable) return; // already said it
        root.compositorReachable = false;
        console.error("[hyprland] cannot reach the compositor: `hyprctl` did not "
            + "return JSON (its IPC socket is most likely gone from "
            + "$XDG_RUNTIME_DIR). Window/workspace data is now STALE, not "
            + "empty -- anything reading it is answering from the last good "
            + "read. Logging out and back in recreates the socket.");
    }
    function reportReachable() {
        if (root.compositorReachable) return;
        root.compositorReachable = true;
        console.warn("[hyprland] compositor reachable again -- window data live.");
    }

    Process {
        id: getMonitors
        command: ["hyprctl", "monitors", "-j"]
        stdout: StdioCollector {
            id: monitorsCollector
            onStreamFinished: {
                root.monitors = JSON.parse(monitorsCollector.text);
            }
        }
    }

    Process {
        id: getLayers
        command: ["hyprctl", "layers", "-j"]
        stdout: StdioCollector {
            id: layersCollector
            onStreamFinished: {
                root.layers = JSON.parse(layersCollector.text);
            }
        }
    }

    Process {
        id: getWorkspaces
        command: ["hyprctl", "workspaces", "-j"]
        stdout: StdioCollector {
            id: workspacesCollector
            onStreamFinished: {
                var rawWorkspaces = JSON.parse(workspacesCollector.text);
                // Filter out invalid workspace ids (e.g. lock-screen temp workspace 2147483647 - N)
                root.workspaces = rawWorkspaces.filter(ws => ws.id >= 1 && ws.id <= 100);
                let tempWorkspaceById = {};
                for (var i = 0; i < root.workspaces.length; ++i) {
                    var ws = root.workspaces[i];
                    tempWorkspaceById[ws.id] = ws;
                }
                root.workspaceById = tempWorkspaceById;
                root.workspaceIds = root.workspaces.map(ws => ws.id);
            }
        }
    }

    Process {
        id: getActiveWorkspace
        command: ["hyprctl", "activeworkspace", "-j"]
        stdout: StdioCollector {
            id: activeWorkspaceCollector
            onStreamFinished: {
                root.activeWorkspace = JSON.parse(activeWorkspaceCollector.text);
            }
        }
    }

    Process {
        id: getActiveWindow
        command: ["hyprctl", "activewindow", "-j"]
        stdout: StdioCollector {
            id: activeWindowCollector
            onStreamFinished: {
                // An empty desktop answers with `{}`, and a failed call with
                // no output at all. Both are "nothing is focused", which is a
                // state this property is allowed to be in -- so neither is
                // allowed to throw.
                try {
                    const parsed = JSON.parse((activeWindowCollector.text || "").trim() || "{}");
                    root.activeWindow = (parsed && parsed.address) ? parsed : null;
                } catch (error) {
                    root.activeWindow = null;
                }
            }
        }
    }

    // Focus moves in bursts -- a click sends openwindow, movewindow,
    // activewindow and focusedmon in quick succession -- and every one of them
    // would otherwise fork a `hyprctl` to ask a question whose answer cannot
    // have changed since the last one. Coalesced instead: one fork per burst,
    // 120ms after it goes quiet.
    Timer {
        id: activeWindowDebounce
        interval: 120
        repeat: false
        onTriggered: root.updateActiveWindow()
    }
}
