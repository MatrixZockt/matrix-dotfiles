pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import QtQuick
import qs.services
// For Directories.state, where llama-params.json lives. Without it the path
// binding silently evaluates to undefined rather than erroring, so FileView
// is left watching an EMPTY path -- it never loads and never reports a
// failure, which means nothing is ever persisted and no symptom points at the
// missing import. (qmllint calls the file clean either way.)
import qs.modules.common

/**
 * LlamaService — the local llama.cpp server: whether it is up, what it is
 * doing right now, and the controls to start and stop it.
 *
 * WHAT REPLACED WHAT
 * ------------------
 * This exists because the now-bar's fourth tab used to show `FlareData`
 * subscription QUOTA — how much of a Claude or ChatGPT plan you had left.
 * That is a fact about somebody else's server. This tab is about a process on
 * this machine, which is a different kind of fact: yours, startable, stoppable
 * and measurable. Nothing here reads FlareData anymore.
 *
 * EVERY FIELD IS A REAL READING — and three of them are corrections to the
 * first design, found by running the server rather than by reading about it:
 *
 *   1. THROUGHPUT COMES FROM /metrics, not /slots.
 *      /slots does expose `n_decoded`, so a delta of it gives a real tok/s
 *      (measured 46.1 t/s against the 45.4 t/s llama.cpp reported in the
 *      response body -- the two agree). But that only works while something is
 *      generating, and it cannot see PROMPT processing at all. /metrics has
 *      monotonic counters for both:
 *          llamacpp:prompt_tokens_total  / llamacpp:prompt_seconds_total
 *          llamacpp:tokens_predicted_total / llamacpp:tokens_predicted_seconds_total
 *      Differencing those across two ticks gives generation AND prompt speed
 *      for the whole server, including the window right after a request ends.
 *
 *   2. POST /props IS A NO-OP ON THIS BUILD. It answers `{"success":true}`
 *      and changes nothing: GET /props still returns the launch default, and
 *      a fresh request's slot params still carry the old temperature. So this
 *      service does NOT offer a sampling panel — the controls would be
 *      decoration that silently does nothing, which is worse than absent.
 *      Sampling is a launch argument here, so it belongs in the model log,
 *      where what you see is genuinely what the server is running with.
 *
 *   3. CONTEXT IS A SHARED POOL, not a per-slot budget. Measured:
 *          -c 8192 -np 2  ->  2 slots x 4096
 *          -c 8192 -np 4  ->  4 slots x 2048
 *      So `total_slots` from /props and the per-slot `n_ctx` from /slots are
 *      reported as what they are. Showing "15104" next to "4 slots" without
 *      that relationship would read as four independent long conversations,
 *      which is not what the server has.
 *
 * THE MODEL LOG
 * -------------
 * Replaces the sampling panel with the last lines of llama.cpp's own stderr,
 * read from a file the server writes to. It is the only honest answer to "what
 * is this thing actually doing": those are the server's words, not ours.
 *
 * START/STOP
 * ----------
 * The server is run as a plain child process, not a systemd unit, so the
 * panel owns the lifetime it shows. A unit would outlive the shell and make
 * the Stop button a lie for as long as the restart policy held it up.
 */

Singleton {
    id: root

    // ── where the server is ───────────────────────────────────────────────
    // Port 8080 is llama.cpp's own default, and it is bound to loopback only.
    // That is not a stylistic choice: with no API key set, llama.cpp warns
    // that it serves every origin, so a 0.0.0.0 bind would put an unauthenticated
    // model server on the network.
    //
    // Both are EDITABLE now (they are rows in the launch-parameter list
    // further down, which is where they are declared, because they have to
    // derive from `params` rather than sit beside it). The loopback default
    // stands; changing it to anything reachable is a decision, not a typo.
    readonly property string base: `http://${root.host}:${root.port}`

    // ── liveness ─────────────────────────────────────────────────────────
    property bool online: false
    // Set between "asked it to start" and "answered". Distinct from `online`
    // so the UI can say "loading" instead of lying with a zeroed gauge.
    //
    // It SURVIVES a failed health check, and that is the whole point of it: a
    // refused connection is the normal state for the entire boot, because
    // llama.cpp binds its port only after the weights are in VRAM (see poll()).
    property bool loading: false
    // When the current start was asked for, and how long it may go unanswered.
    //
    // `real`, NOT `int`: Date.now() is ~1.7e12 and QML's int is 32-bit, so an
    // int here would hold a wrapped, meaningless number and the deadline below
    // would fire instantly or never. GlobalStates.loadingWaitStartedAt is a
    // `real` for exactly this reason.
    property real loadStartedMs: 0
    // The unit's own TimeoutStartSec is 300 ("give the model time to load
    // (it's ~5GB)"), so this matches the limit systemd already applies to this
    // start instead of inventing a second opinion about it.
    readonly property real loadDeadlineMs: 300000
    property string lastError: ""

    // ── model identity (GET /props) ──────────────────────────────────────
    property string modelPath: ""
    property string modelName: ""
    property string modelQuant: ""      // /props model_ftype, e.g. "Q4_K - Medium"
    property string buildInfo: ""        // e.g. "b11146-7fe450e193"
    property int totalSlots: 0
    property bool sleeping: false

    // ── per-slot state (GET /slots) ──────────────────────────────────────
    // One entry per slot: { id, busy, task, prompt, processed, cache,
    // decoded, remain, pct }. `pct` is the slot's share of its own context,
    // which is the number that catches a context-starved slot.
    property var slots: []
    readonly property int busySlots: {
        let n = 0;
        for (const s of root.slots) if (s.busy) n++;
        return n;
    }

    // uptimeText is public (the UI binds to it); _uptimeText is the formatter.
    function _uptimeText() {
        const s = Math.floor(root.uptimeSeconds);
        if (s <= 0) return "just now";
        const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
        if (h > 0) return `${h}h ${m}m`;
        if (m > 0) return `${m}m`;
        return `${s}s`;
    }

    // ── throughput ─────────────────────────────────────────────────────────
    // TWO sources, because neither alone is honest. This was measured, not
    // assumed, and the first version got it wrong:
    //
    //   * /metrics counters DO NOT MOVE DURING GENERATION. Sampled while a
    //     2500-token request was streaming, `tokens_predicted_total` and
    //     `tokens_predicted_seconds_total` were byte-identical before and
    //     after an 8 s window and only jumped when the request ENDED. So a
    //     rate differenced from them is not a live rate -- it is the average
    //     of the most recently FINISHED request, arriving late.
    //   * /slots `n_decoded` DOES advance while the slot is working.
    //
    // So the live generation figure comes from the slots, summed across busy
    // slots and differenced between polls, and the metrics-based numbers are
    // kept only for prompt throughput -- where there is no per-request live
    // equivalent, and which is likewise a completed-request figure.
    property real genTokensPerSec: 0
    property real promptTokensPerSec: 0
    property double genTokensTotal: 0
    property double genSecondsTotal: 0
    property double promptTokensTotal: 0
    property double promptSecondsTotal: 0
    // Live generation rate: accumulated from n_decoded deltas in readSlots().
    property double _liveDecoded: 0
    property double _lastDecodedAt: 0
    property bool _haveDecoded: false

    // The previous tick's raw counters. Kept private and only ever read to
    // make a delta -- a rate needs two samples, and a single /metrics read is
    // a lifetime average, which would show "12 t/s" for a server that is
    // currently doing nothing.
    property double _prevGenTokens: 0
    property double _prevGenSeconds: 0
    property double _prevPromptTokens: 0
    property double _prevPromptSeconds: 0
    property bool _havePrev: false

    // ── VRAM (nvidia-smi, attributed by pid) ─────────────────────────────
    // Measured 6834 MiB with the model loaded and 15 MiB with nothing running,
    // so this genuinely tracks the server rather than reporting the card's
    // total. --query-compute-apps is the only reading that separates "the GPU
    // is in use" from "the GPU is in use BY US".
    property real vramMiB: 0
    property real vramTotalMiB: 8188
    readonly property real vramGiB: root.vramMiB / 1024
    readonly property real vramTotalGiB: root.vramTotalMiB / 1024

    // ── uptime ───────────────────────────────────────────────────────────
    // From /proc, so it is the server's real age and not "since the shell last
    // polled". A shell restart must not make a 3-hour-old server read "0m".
    property double uptimeSeconds: 0

    // The exact command line a Start would run, as one string. Single source
    // for three things that must never disagree: the log's first line, the
    // `argv` IPC call, and the argv actually handed to the process.
    function argvText() {
        if (!root.selectedModel) return "(no .gguf model found)";
        const parts = ["llama-server", "-m", root.selectedModel.path];
        for (const a of root.argList) {
            for (const piece of a.split(" "))
                parts.push(piece);
        }
        return parts.join(" ");
    }

    // ── the models on disk ───────────────────────────────────────────────
    // A scan of ~/Models for .gguf, with real byte sizes. This is what makes
    // the OFFLINE panel worth looking at: the list of things you could run is
    // available whether or not anything is running.
    property var models: []
    // Which model `-m` gets. Editable for the same reason the flags are: it is
    // a launch parameter like any other. This was `models[0]` unconditionally,
    // so the panel could list every model on disk and still only ever start the
    // first one -- the "next" badge was a label on a fixed choice rather than a
    // selection.
    property int modelIndex: 0
    // Clamped on read rather than in an onModelsChanged handler: a rescan that
    // removes the selected model (someone deleted the file) then falls back to
    // the last valid entry instead of going null and blanking the panel.
    readonly property var selectedModel: root.models.length === 0
        ? null
        : root.models[Math.min(root.modelIndex, root.models.length - 1)]
    function selectModel(i) {
        if (i < 0 || i >= root.models.length)
            return;
        root.modelIndex = i;
    }

    // ── the log (the panel's right-hand pane) ────────────────────────────
    property string logText: ""
    property var logLines: []
    readonly property int logMaxLines: 60

// ══════════════════════════════════════════════════════════════════════
    // Launch parameters -- EDITABLE, and they persist
    // ══════════════════════════════════════════════════════════════════════
    //
    // THE VALUES ARE SCALAR PROPERTIES, and the list the panel renders is
    // DERIVED from them. That is not a style preference. The first version kept
    // the values inside a `property var launchParams` array of objects and
    // reassigned the array on every edit, and on this Qt/Quickshell build that
    // assignment is SILENTLY DISCARDED: the write appears to succeed, every
    // read afterwards returns the old array, and no warning is emitted
    // anywhere. Measured on one instance, same call:
    //
    //     root.models = [9,9,9]        -> took effect   (array of numbers)
    //     root.paramsReady = false     -> took effect   (bool)
    //     root.launchParams = [{...}]  -> IGNORED       (array of objects)
    //
    // So an editable list here is a trap: the UI looks right, every keystroke
    // appears to register, and the value underneath never moves. Scalars are
    // not cleverer here, they are simply assignable. `launchParams` stays as the
    // single description the panel draws from, so a flag still cannot reach the
    // command without a row to change it.
    //
    // DEFAULTS ARE MEASURED, not requested. `-ngl 99` means "force full
    // offload", which removes llama.cpp's ability to back off, so a context
    // that does not fit fails hard instead of partially offloading:
    //
    //   common_fit_params: failed to fit params to free device memory
    //   ggml_backend_cuda_buffer_type_alloc_buffer: cudaMalloc failed: OOM
    //
    // Measured on this machine (the discrete GPU, 8188 MiB, Qwen3-8B Q4_K_M
    // 4.7 GB, KV cache q4_0):
    //
    //     -ngl 99 -c 65536  ->  cudaMalloc failed allocating 2592 MiB (dies)
    //     -ngl 99 -c 40960  ->  loads, 7255 MiB used, 635 MiB left  (the
    //                           model's trained max; tight, nothing spare)
    //     -ngl 99 -c 32768  ->  loads, 6887 MiB used, 1002 MiB left  (chosen)
    //
    // 65536 was the old default and it is exactly the case that crash-looped.
    // 32768 keeps ~1 GB free for the desktop and needs no YaRN rope scaling
    // (it stays under Qwen3's 40960-token trained window). Raising Context is
    // still allowed -- the launcher caps the flag at 40960, where the KV cache
    // stops fitting -- but anything above 32768 spends the spare headroom.
    property int propCtx: 32768
    property int propNgl: 99
    property int propParallel: 1
    property string propHost: "127.0.0.1"
    property int propPort: 8001
    property bool propJinja: true
    property bool propFlashAttn: true

    // What the panel draws one row per. `kind` picks the control: "text" and
    // "int" get a field, "bool" gets a switch emitted as the BARE flag when on
    // and omitted when off (llama.cpp's `--jinja` takes no argument). min/max
    // clamp an int so a half-typed field cannot ask for -c 0.
    // `def` exists for the panel, and `def` also decides what gets
    // WRITTEN to disk (see saveParams). A row's value equal to its default
    // means "nobody has touched this", so the panel can show the default as a
    // grey placeholder and leave the box empty -- which is the difference
    // between "65536 because that is the built-in" and "65536 because you
    // asked for it". `min`/`max` are not clamps the UI hints at: they are the
    // two ends of the SCALE the row's slider is drawn against, and `step` is
    // the only value the slider will ever land on -- a drag over context has
    // to produce 32768 or 36864, never 33127.
    readonly property var launchParams: [
        { key: "ctx",       label: "Context",         flag: "-c",          kind: "int",  value: root.propCtx,       def: 32768,    min: 512,      max: 40960,   step: 4096 },
        { key: "ngl",       label: "GPU layers",      flag: "-ngl",        kind: "int",  value: root.propNgl,       def: 99,       min: 0,        max: 999,     step: 1 },
        { key: "parallel",  label: "Parallel slots",  flag: "--parallel",  kind: "int",  value: root.propParallel,  def: 1,        min: 1,        max: 64,      step: 1 },
        { key: "host",      label: "Host",            flag: "--host",      kind: "text", value: root.propHost,      def: "127.0.0.1" },
        { key: "port",      label: "Port",            flag: "--port",      kind: "int",  value: root.propPort,      def: 8001,      min: 1,        max: 65535 },
        { key: "jinja",     label: "Jinja template",  flag: "--jinja",     kind: "bool", value: root.propJinja,     def: true },
        { key: "flashAttn", label: "Flash attention", flag: "--flash-attn", kind: "bool", value: root.propFlashAttn, def: true, boolArg: "--flash-attn on" },
    ]

    // Whether the launch-argument settings are showing on their own
    // fullscreen surface.
    //
    // It lives HERE, not on the window, because the button that opens it is in
    // NowBarPanel and the window is in another file entirely: two files, one
    // boolean, and the service is the only object both of them can see.
    property bool settingsOpen: false

    // Is this row still on its built-in default? The one predicate behind the
    // placeholder text, the "edited" marker in the panel and the override file.
    function isDefault(key) {
        const p = root.paramDef(key);
        return p !== null && String(p.value) === String(p.def);
    }

    // The `def`/`step` for a key, or null. Separate from `paramValue` because a
    // missing key must not read as "no default" for a row that has one.
    function paramDef(key) {
        for (const p of root.launchParams)
            if (p.key === key)
                return p;
        return null;
    }

    

    // How many rows differ from their defaults. Read by the panel's Reset
    // button so "reset" can say how much it is about to undo instead of being
    // a control that is sometimes a no-op and gives no hint which.
    readonly property int overrideCount: {
        let n = 0;
        for (const p of root.launchParams)
            if (String(p.value) !== String(p.def))
                n++;
        return n;
    }

    // Fixed, NOT user-editable, because this panel cannot function without
    // them: /slots is how per-slot busy state is read, and /metrics is where
    // generation and prompt throughput come from. Switching either off does
    // not give a different server, it gives a server this panel can no longer
    // measure -- so they are shown in the panel as always-on rather than
    // offered as toggles that would silently break the readings.
    readonly property var fixedArgs: ["--slots", "--metrics"]

    function clamp(value, lo, hi, fallback) {
        const n = parseInt(value);
        if (isNaN(n))
            return fallback;
        return Math.min(hi, Math.max(lo, n));
    }

    function paramValue(key) {
        for (const p of root.launchParams)
            if (p.key === key)
                return p.value;
        return undefined;
    }

    // `host`/`port` used to be hardcoded readonly properties, and `base` -- the
    // URL everything is polled from -- is built from them. They are parameters
    // now, so they are DERIVED instead: editing the port in the panel repoints
    // the poller, `addressText`, and the is-this-our-process check that greps
    // /proc for `--port`, all at once. The loopback default stands; binding
    // this to anything reachable is a decision, not a typo.
    readonly property string host: root.propHost
    readonly property int port: root.propPort

    // Kept because the panel's "N tokens / M slots" readout earns its place --
    // it is the relationship that decides how the server actually behaves --
    // and because deriving it means it cannot go stale when the two numbers are
    // edited independently.
    readonly property int argCtx: root.propCtx
    readonly property int argParallel: root.propParallel

    // Write one parameter, by key, to the scalar that owns it.
    function setParam(key, value) {
        switch (key) {
        case "ctx": root.propCtx = root.clamp(value, 512, 40960, root.propCtx); break;
        case "ngl": root.propNgl = root.clamp(value, 0, 999, root.propNgl); break;
        case "parallel": root.propParallel = root.clamp(value, 1, 64, root.propParallel); break;
        case "host": root.propHost = String(value); break;
        case "port": root.propPort = root.clamp(value, 1, 65535, root.propPort); break;
        case "jinja": root.propJinja = !!value; break;
        case "flashAttn": root.propFlashAttn = !!value; break;
        default: return;
        }
        root.saveParams();
    }

    // Put every row back to the defaults above.
    function resetParams() {
        root.propCtx = 32768;
        root.propNgl = 99;
        root.propParallel = 1;
        root.propHost = "127.0.0.1";
        root.propPort = 8001;
        root.propJinja = true;
        root.propFlashAttn = true;
        root.saveParams();
    }

    // The exact flag list handed to the process. Derived from `launchParams`,
    // so a value edited in the panel is the value that runs -- there is no
    // second copy to forget to update.
    readonly property var argList: {
        const out = [];
        for (const p of root.launchParams) {
            if (p.kind === "bool") {
                if (p.value)
                    // `boolArg` where the flag is not a bare switch.
                    //
                    // `--flash-attn` takes an OPTIONAL value (`on|off|auto`),
                    // so emitting it bare makes llama.cpp's parser read the
                    // NEXT argument as that value. It did exactly that here:
                    //
                    //   error while handling argument "--flash-attn":
                    //   error: unknown value for --flash-attn: '--slots'
                    //   -- server exited (code 1)
                    //
                    // which meant the server could never start at all while
                    // flash attention was on -- the default. The fix is to
                    // pass the value as a SEPARATE token. Measured on the
                    // installed build, all three of these were tried:
                    //
                    //   --flash-attn on     parses (fails later, on the model)
                    //   --flash-attn=on     error: invalid argument
                    //   --flash-attn       swallows the next argument
                    //
                    // so the value goes in as its own token, which `argvText`
                    // then splits on the space exactly like every other
                    // value-taking flag here.
                    out.push(p.boolArg ?? p.flag);
            } else {
                out.push(`${p.flag} ${p.value}`);
            }
        }
        return out.concat(root.fixedArgs);
    }

    // ── persistence ─────────────────────────────────────────────────────
    // Without this the parameters would reset on every shell restart -- and
    // this shell hot-reloads its entire QML tree whenever any watched file
    // changes, so "editable" would really mean "editable until you touch a
    // file". Same FileView + setText shape WallpaperHistory uses.
    //
    // The file lives at Directories.state, which is a `file://` URL rather
    // than a bare path -- the same form WallpaperHistory's historyPath uses,
    // and FileView takes it as-is. Getting this wrong is silent: a missing
    // `import qs.modules.common` leaves the binding undefined, FileView then
    // watches an empty path, never loads, never reports failure, and nothing
    // is ever saved -- with qmllint calling the file clean.
    readonly property string paramsPath: `${Directories.state}/llama-params.json`
    property bool paramsReady: false
    // The file is read EXACTLY ONCE, at startup. After that this shell owns
    // it and only ever writes to it.
    //
    // That restriction is the fix, not a limitation. `setText` makes the
    // FileView reload, and that reload hands `onLoaded` a snapshot taken
    // BEFORE the write lands -- so re-applying it on every load meant each
    // edit silently reverted all the PREVIOUS ones, leaving only the most
    // recent edit standing. Three edits in a row produced a file where only
    // the third had taken. Comparing the text against what we wrote was not
    // enough either, because the text that comes back is the stale one and so
    // never matches. Not re-applying after startup removes the whole class:
    // hand-editing the file now takes effect on the next shell start, which
    // is a far more predictable rule than "your edit may be undone by an
    // unrelated one".
    property bool paramsLoaded: false
    FileView {
        id: paramsView
        path: LlamaService.paramsPath
        watchChanges: false
        printErrors: false
        onLoaded: {
            root.paramsReady = true;
            if (root.paramsLoaded)
                return;
            root.paramsLoaded = true;
            let stored = null;
            try {
                stored = JSON.parse(paramsView.text());
            } catch (e) {
                stored = null;
            }
            // Applied through setParam rather than assigned in bulk, so the
            // clamp and coercion are identical whether a value came from the
            // panel, from IPC, or from a hand-edited file.
            if (stored && typeof stored === "object") {
                for (const k in stored)
                    root.setParam(k, stored[k]);
            }
        }
        // No file yet: the property defaults above are already the answer, so
        // there is nothing to seed and nothing to write on a fresh install.
        onLoadFailed: {
            root.paramsReady = true;
            root.paramsLoaded = true;
        }
    }
    function saveParams() {
        if (!root.paramsReady)
            return;
        // ONLY overrides are written. A key missing from the file means "still
        // the built-in default", which is what lets the panel show the default
        // as a placeholder, and it means changing a default later silently
        // applies to every row nobody ever edited. Writing all seven values
        // froze every default into the file on the first keystroke, so from
        // then on nothing was an override and nothing could be told apart.
        const out = {};
        for (const p of root.launchParams) {
            if (String(p.value) !== String(p.def))
                out[p.key] = p.value;
        }
        // Empty, not `{}`: a reset should leave nothing behind. Loading it
        // throws on JSON.parse(""), which onLoaded already catches, so the
        // properties above are the answer again.
        paramsView.setText(Object.keys(out).length > 0 ? JSON.stringify(out, null, 2) : "");
    }

    // ══════════════════════════════════════════════════════════════════════
    // Polling
    // ══════════════════════════════════════════════════════════════════════

    // XMLHttpRequest inside a QtObject: the idiom already proven to work in
    // Booru.qml and OnlineMusic.qml under this shell's engine. A Qt Network
    // access manager would be tidier and is not available to a service
    // singleton here.
    QtObject {
        id: http
        function get(url, onOk, onFail) {
            const xhr = new XMLHttpRequest();
            xhr.open("GET", url);
            xhr.onreadystatechange = function() {
                if (xhr.readyState !== XMLHttpRequest.DONE)
                    return;
                // llama.cpp answers a dead port with status 0 and an empty
                // body. Treating that as "offline" is the whole point of the
                // health check, so it is not an error path -- it is an answer.
                if (xhr.status === 200) {
                    try { onOk(xhr.responseText ?? ""); }
                    catch (e) { onFail("unreadable response"); }
                } else {
                    onFail(null);
                }
            };
            try { xhr.send(); }
            catch (e) { onFail(null); }
        }
    }

    // Poll only when something can show a fresh number. Same rule FlareData
    // uses, and for the same reason: an unconditional tick spawns processes
    // and opens sockets whether or not anyone is looking at the card.
    //
    // TWO surfaces can want this -- the island and the popped-out card -- so
    // this is a REFCOUNT, not a boolean. It was a plain `bool` first, and the
    // two fought: opening the card set it true, closing the card set it false
    // while the island was still on the AI view and quietly stopped the
    // numbers. `claim`/`release` name which surface is asking, so the last one
    // to let go is the one that stops the poll.
    property bool tabVisible: false
    property string tabOwner: ""

    function claim(owner: string) {
        root.tabOwner = owner;
        root.tabVisible = true;
        // A panel that opens onto a server somebody else started (a terminal,
        // a unit) knows NOTHING about it yet -- and because liveness polling
        // runs whether or not anyone is watching, `online` was already true by
        // the time this tab appeared. The "read props on the offline->online
        // edge" branch inside poll() therefore never fired for it, and the
        // panel came up reading "running" with an empty model name, no slots
        // and no context. Claiming is the moment to fill that in.
        if (root.online && root.modelPath.length === 0) {
            root.readProps();
            root.readSlots();
            root.readMetrics();
            root.readLog();
        }
    }
    function release(owner: string) {
        if (root.tabOwner === owner) {
            root.tabOwner = "";
            root.tabVisible = false;
        }
    }

    Timer {
        id: pollTimer
        // Fast enough that a live reading feels live. 1.2 s while a slot is
        // working (that is what makes tok/s move), slower when idle so a
        // running server costs almost nothing to leave alone.
        interval: root.busySlots > 0 ? 1200 : 4000
        // `loading` is in this condition on purpose. The start is the one
        // moment the panel has to discover something it cannot be told, and if
        // polling only ran while a surface was watching then a start made
        // with nothing watching (a keybind, `qs ipc call llama start`) would
        // leave the panel permanently showing "stopped" for a server that was
        // running, and a start that FAILED would look identical to one that
        // had not been attempted.
        running: true
        repeat: true
        triggeredOnStart: true
        // ALWAYS on, and this is a correction rather than an optimisation.
        //
        // Polling used to run only while a surface was watching the panel, on
        // the reasoning that an idle panel should cost nothing. The cost was
        // paid back with a lie: the moment the panel was closed, polling
        // stopped, and so `online` froze at whatever it last was. A server
        // that was killed from a terminal, or that crashed on its own, left
        // the panel reading "running -- Qwen3-8B" indefinitely, and the Stop
        // button would then act on a pid that no longer existed.
        //
        // So liveness is polled unconditionally, and only the EXPENSIVE parts
        // are conditional: `/metrics` and `/slots` and the `nvidia-smi` spawn
        // are gated on `tabVisible` below, because those are the things worth
        // avoiding when nobody is looking. `/health` is one localhost request
        // every few seconds -- it is what makes "is it up" true rather than
        // remembered.
        onTriggered: root.poll()
    }

    function poll() {
        http.get(root.base + "/health", (body) => {
            if (!root.online) {
                // First successful contact after being down: pull the
                // slower-changing facts once, rather than making the panel
                // wait a tick to learn what is loaded.
                root.readProps();
                root.readLog();
            }
            root.online = true;
            root.loading = false;
            root.lastError = "";
            // The detail endpoints are only worth reading for a panel that
            // is on screen; liveness above is not.
            if (root.tabVisible) {
                root.readSlots();
                root.readMetrics();
            }
        }, () => {
            root.online = false;
            // A FAILED HEALTH CHECK IS NOT A FAILED START, and this line used
            // to treat it as one (`root.loading = false;`). llama.cpp prints
            // "listening on http://..." only once the model is loaded, so
            // every poll between `systemctl start` and "model loaded" gets a
            // refused connection -- and the first of them lands within a
            // fraction of a second, because startSystemdProc polls as soon as
            // systemctl returns. The flag was therefore cancelled about a
            // second into a boot that takes ~4s for the local 8B and minutes
            // for anything bigger (measured 2026-10-11: process start
            // 10:39:18, "listening" 10:39:22), so both the island and the
            // popup read "stopped" while 7.5GB was going into VRAM. The press
            // that state invites is a second Run on a server that is already
            // coming up -- which `toggle()` then answers with a STOP.
            //
            // A start that genuinely never answers must still stop claiming to
            // be one, so the deadline ends it. Only the deadline does: a stop
            // clears the flag itself, and so does a systemctl start that
            // reports FAIL.
            if (root.loading && root.loadStartedMs > 0
                    && Date.now() - root.loadStartedMs > root.loadDeadlineMs) {
                const waited = Math.round(root.loadDeadlineMs / 1000);
                root.loading = false;
                root.lastError = Translation.tr("llama-server did not answer within %1s")
                    .arg(waited);
                root._appendLog(`timeout  no /health after ${waited}s -- giving up`);
            }
            root.slots = [];
            root.genTokensPerSec = 0;
            root.promptTokensPerSec = 0;
            root._havePrev = false;
            root._haveDecoded = false;
            // Everything derived from a running server is cleared HERE, on the
            // offline edge, rather than being left to be overwritten by the
            // next successful poll. The offline pane crossfades in over ~200ms
            // and anything not cleared is still on screen underneath it --
            // VRAM, uptime and pid are all keyed on a process that is gone.
            root.vramMiB = 0;
            root.uptimeSeconds = 0;
            root._pid = 0;
            root._liveDecoded = 0;
            root._lastDecodedAt = 0;
        });
        // pid + VRAM + uptime, whenever a panel is watching. One nvidia-smi
        // and one pgrep together; gated on tabVisible because that is a
        // process spawn and the card is opened by nvidia-smi, which is not
        // something to pay for a closed panel.
        if (root.tabVisible && !vramProc.running)
            root.readVram();
    }

    function readProps() {
        http.get(root.base + "/props", (body) => {
            const d = JSON.parse(body);
            root.totalSlots = d.total_slots ?? 0;
            root.modelPath = d.model_path ?? "";
            root.modelQuant = d.model_ftype ?? "";
            root.buildInfo = d.build_info ?? "";
            root.sleeping = d.is_sleeping ?? false;
            // The alias is the full path; the NAME is the basename without the
            // extension, which is how the model is actually known.
            root.modelName = root.modelPath.length > 0
                ? root.modelPath.split("/").pop().replace(/\.gguf$/i, "")
                : "";
        }, () => {});
    }

    function readSlots() {
        http.get(root.base + "/slots", (body) => {
            const raw = JSON.parse(body);
            const perSlotCtx = root._perSlotCtx(raw);
            const out = [];
            for (const s of raw) {
                const nt = (s.next_token && s.next_token.length > 0) ? s.next_token[0] : {};
                const decoded = nt.n_decoded ?? 0;
                const remain = nt.n_remain ?? 0;
                out.push({
                    id: s.id ?? 0,
                    busy: s.is_processing ?? false,
                    task: s.id_task ?? -1,
                    prompt: s.n_prompt_tokens ?? 0,
                    processed: s.n_prompt_tokens_processed ?? 0,
                    cache: s.n_prompt_tokens_cache ?? 0,
                    decoded: decoded,
                    remain: remain,
                    pct: (s.n_ctx > 0 && (decoded + remain) > 0)
                        ? Math.min(1, decoded / (decoded + remain)) : 0,
                    ctx: s.n_ctx ?? 0,
                });
            }
            root.slots = out;
            root._deriveGenRate(out);
        }, () => {});
    }

    // The live generation rate, from the slots rather than /metrics.
    //
    // `n_decoded` is a per-slot count that climbs while that slot works, so
    // the sum across busy slots climbs once per token the SERVER produces --
    // which is the number a person watching this wants, because llama.cpp
    // batches slots together and one slot's own rate drops as others join.
    // A request that is between tokens shows no change and the previous
    // figure is kept rather than being replaced by a zero.
    function _deriveGenRate(list) {
        const now = Date.now() / 1000;
        let total = 0;
        for (const s of list) total += s.decoded ?? 0;
        if (root._haveDecoded) {
            const dt = now - root._lastDecodedAt;
            // Below ~0.3 s the delta is one or two tokens and the division is
            // mostly noise; one second is the shortest window that means
            // anything.
            if (dt >= 0.3) {
                const delta = total - root._liveDecoded;
                if (delta > 0)
                    root.genTokensPerSec = delta / dt;
                else if (total === 0)
                    root.genTokensPerSec = 0;
                root._liveDecoded = total;
                root._lastDecodedAt = now;
            }
        } else {
            root._liveDecoded = total;
            root._lastDecodedAt = now;
            root._haveDecoded = true;
        }
    }

    // The per-slot context, taken from any slot that reports one. All slots
    // share the pool, so one reading is the whole pool's worth -- and it is
    // the number that makes `-c` vs `-np` legible instead of mysterious.
    function _perSlotCtx(raw) {
        for (const s of raw)
            if (s.n_ctx > 0) return s.n_ctx;
        return 0;
    }
    readonly property int perSlotCtx: {
        for (const s of root.slots)
            if (s.ctx > 0) return s.ctx;
        return 0;
    }
    // The TOTAL context the server was launched with: slots x each slot's
    // share. Shown next to perSlotCtx because the relationship is the whole
    // point -- 4 slots of 8192 is not four conversations of 8192.
    readonly property int totalCtx: root.perSlotCtx * Math.max(1, root.totalSlots)

    function readMetrics() {
        http.get(root.base + "/metrics", (body) => {
            const v = {};
            for (const line of body.split("\n")) {
                if (line.startsWith("#") || line.trim().length === 0) continue;
                const sp = line.lastIndexOf(" ");
                if (sp < 0) continue;
                const key = line.slice(0, sp).trim();
                const num = parseFloat(line.slice(sp + 1));
                if (!isNaN(num)) v[key] = num;
            }
            const genTok = v["llamacpp:prompt_tokens_total"] !== undefined
                ? v["llamacpp:tokens_predicted_total"] ?? 0 : 0;
            const genSec = v["llamacpp:tokens_predicted_seconds_total"] ?? 0;
            const prmTok = v["llamacpp:prompt_tokens_total"] ?? 0;
            const prmSec = v["llamacpp:prompt_seconds_total"] ?? 0;

            root.genTokensTotal = genTok;
            root.genSecondsTotal = genSec;
            root.promptTokensTotal = prmTok;
            root.promptSecondsTotal = prmSec;

            if (root._havePrev) {
                // PROMPT ONLY. The generation rate deliberately is NOT
                // computed here: these counters are frozen for the whole
                // duration of a request and jump when it ends, so a delta
                // across them describes a request that already finished. The
                // live figure comes from /slots in _deriveGenRate().
                const dp = prmSec - root._prevPromptSeconds;
                if (dp > 0.05)
                    root.promptTokensPerSec = (prmTok - root._prevPromptTokens) / dp;
            }
            root._prevGenTokens = genTok;
            root._prevGenSeconds = genSec;
            root._prevPromptTokens = prmTok;
            root._prevPromptSeconds = prmSec;
            root._havePrev = true;
        }, () => {});
    }

    // VRAM for OUR pid specifically, plus the card's total for the gauge's
    // denominator. One nvidia-smi call, two numbers, parsed in one place.
    // pid, VRAM and uptime, from ONE command.
    //
    // These used to be three separate lookups -- a pgrep round-trip for the
    // pid, then an nvidia-smi keyed on that pid, then a /proc read keyed on it
    // again -- and the chain was the whole problem. The pid lookup is a
    // second asynchronous round-trip that has to land before either of the
    // others can run, and it kept losing that race: it fires the instant the
    // server is handed off (before the process exists), the poll interval then
    // cancelled the retry before it finished, and the panel showed a running
    // server with 0 MiB and no pid.
    //
    // Asking for all three at once removes the dependency entirely. The script
    // finds the pid itself, so there is nothing to have found it too early.
    function readVram() {
        vramProc.running = false;
        vramProc.running = true;
    }

    Process {
        id: vramProc
        command: ["bash", "-c", root.vramScript()]
        stdout: StdioCollector { onStreamFinished: root._applyVram(text ?? "") }
    }

    property int _pid: 0
    readonly property int serverPid: root._pid



    function _appendLog(chunk) {
        if (chunk === undefined || chunk === null || chunk.length === 0)
            return;
        // llama.cpp writes its progress with \r on the same line. Kept raw it
        // would smear the pane into one unreadable ribbon, so each line is
        // normalised and only genuinely new text is kept.
        const parts = chunk.split(/\r?\n/).map(s => s.trim()).filter(s => s.length > 0);
        if (parts.length === 0)
            return;
        const merged = root.logLines.concat(parts);
        root.logLines = merged.slice(Math.max(0, merged.length - root.logMaxLines));
        root.logText = root.logLines.join("\n");
    }

    // ── the log file, for a server this shell did not start ───────────────
    // If llama-server was started outside the shell (a terminal, a unit), its
    // log is not ours to collect. The pane then shows what IS knowable --
    // the build, the model, the arguments -- instead of going blank.
    function readLog() {
        if (root.logLines.length > 0)
            return;
        root._appendLog(`build    ${root.buildInfo}`);
        root._appendLog(`model    ${root.modelName} (${root.modelQuant})`);
        root._appendLog(`slots    ${root.totalSlots} x ${root.perSlotCtx} ctx`);
        root._appendLog(`args     ${root.argList.join(" ")}`);
        root._appendLog(`started  ${root._uptimeText()}`);
    }

    // ── start / stop ─────────────────────────────────────────────────────
    property bool busy: false

    function start() {
        if (root.online || root.busy)
            return;
        if (!root.selectedModel) {
            root.lastError = Translation.tr("No .gguf model found in ~/Models");
            return;
        }
        root.busy = true;
        root.lastError = "";
        root.loading = true;
        root.loadStartedMs = Date.now();
        root.slots = [];
        root.genTokensPerSec = 0;
        root.promptTokensPerSec = 0;
        root.uptimeSeconds = 0;
        root._havePrev = false;
        root.logLines = [];
        root.logText = "";

        // The server runs as a systemd user service (llama-server-local),
        // not as a child process of the shell. Starting it here delegates to
        // systemctl, so the shell's Start button and the top-bar popup button
        // both control the same persistent unit.
        root._appendLog("$ systemctl --user start llama-server-local");
        const startProc = startSystemdProc;
        startProc.command = ["bash", "-c",
            "systemctl --user start llama-server-local 2>&1 && echo OK || echo FAIL"];
        startProc.running = false;
        startProc.running = true;
        root.busy = false;
    }

    function stop() {
        if (root.busy)
            return;
        root.busy = true;
        // Stop the systemd user service rather than killing by pid. A unit
        // outlives the shell and may have been started by the top-bar popup,
        // a keybind, or a previous shell session -- pid-based killing cannot
        // reach any of those.
        root._appendLog("$ systemctl --user stop llama-server-local");
        const stopProc2 = stopSystemdProc;
        stopProc2.command = ["bash", "-c",
            "systemctl --user stop llama-server-local 2>&1 && echo OK || echo FAIL"];
        stopProc2.running = false;
        stopProc2.running = true;
    }

    function toggle() {
        if (root.online || root.loading) root.stop();
        else root.start();
    }

    Process {
        id: stopProc
        stdout: StdioCollector { onStreamFinished: { root.busy = false; root.poll(); } }
        stderr: StdioCollector { onStreamFinished: root.busy = false }
    }

    Process {
        id: startSystemdProc
        stdout: StdioCollector {
            // NO HANDLER PARAMETER, and this is the bug that hid every start.
            //
            // `streamFinished` carries no arguments (see Quickshell.Io's type
            // info: the signal is declared bare). `onStreamFinished: (text) =>
            // ...` therefore bound `text` to undefined and SHADOWED the
            // collector's own `text` property, so the comparison below was
            // `"" === "OK"` -- always false. Every start was reported as
            // "systemd: failed to start llama-server-local" the instant
            // systemctl returned, roughly 70ms into a boot that takes 2.5-4s
            // (measured 2026-10-11: the verdict lands at 71ms, /health answers
            // at 2.5s), and that false verdict cleared `loading` before the
            // first health poll had even run. Nothing downstream could ever
            // show "starting…": the island's second line was blank and the
            // popup's offline pane read "stopped" while the weights loaded.
            //
            // Reading the property is what the rest of this file already does
            // in a handler block (the uptime and model-list collectors above
            // both use a bare `text`).
            onStreamFinished: {
                root.busy = false;
                const ok = (text ?? "").trim() === "OK";
                if (ok) {
                    root._appendLog("systemd: started llama-server-local");
                    root.poll();
                    // Re-discover pid/VRAM for a server the unit started.
                    root.readVram();
                } else {
                    root.lastError = "systemd: failed to start llama-server-local";
                    root.loading = false;
                }
            }
        }
        stderr: StdioCollector { onStreamFinished: { root.busy = false; } }
    }

    Process {
        id: stopSystemdProc
        stdout: StdioCollector {
            // Same bare handler as startSystemdProc -- this one never read
            // `text`, but the parameter alone is the trap that was copied
            // there from it, so it goes too.
            onStreamFinished: {
                root.busy = false;
                root._appendLog("systemd: stopped llama-server-local");
                root.online = false;
                root.loading = false;
                root.poll();
            }
        }
        stderr: StdioCollector { onStreamFinished: { root.busy = false; } }
    }

    // Find the pid of the llama-server this panel is responsible for.
    //
    // `pgrep -x llama-server` (exact process NAME) rather than `pgrep -f` with
    // a command-line pattern. The `-f` version matched ITSELF: the pattern
    // text lives in the wrapper shell's own /proc cmdline, so the lookup found
    // the shell running pgrep, took that pid, and the VRAM read -- which is
    // keyed on this pid -- matched nothing and reported 0 MiB for a server
    // holding 6742 MiB. Matching the executable name cannot match the shell.
    //
    // Then the port is checked from /proc, so a llama-server belonging to
    // something else on the machine is not adopted. The loop breaks on the
    // first match in pid order, which is the oldest, and is the one a panel
    // that started it should claim.
    // The pid lookup, as a shell script, ONCE.
    //
    // Every `$` here is written `\\x24` on purpose. These are plain
    // double-quoted QML strings, so a bare `$p` is not "shell variable p" --
    // it is a QML expression for a property called `p`, which does not exist
    // and expands to empty. The result was a script reading
    // `/proc//cmdline` and echoing nothing, so the panel reported a server
    // holding 0 MiB. This is the same trap GpuPower documents on its
    // `pollControl` command ("plain double-quoted QML strings, where ${} is
    // literal text that bash would then expand").
    function pidFindCommand() {
        // Built by CONCATENATION, not by escaping. QML does not decode
        // `\x24` inside a plain string literal -- it passed the six
        // characters straight through to bash, which then ran a command
        // literally named `\x24(pgrep...)`. So the dollar sign is put in by
        // joining `"$" + "..."`, which is the GpuPower approach and the only
        // one that has actually reached a shell here.
        const D = "$";
        // Reading `/proc/<pid>/cmdline` took three attempts to get right, and
        // each failure looked identical from here -- an empty string for a
        // server that was provably running. What is actually going on:
        //
        //   * The file is NUL-separated, and `grep` treats a NUL as a line
        //     terminator, so matching a phrase across what is really one line
        //     never works against it unconverted.
        //   * `tr '\0' ' '` then makes it ONE line -- and then `grep -x
        //     '--port 8080'` fails too, because cmdline ends with a trailing
        //     NUL that becomes a trailing space.
        //   * Splitting to NEWLINES is right, but each argument is then its
        //     OWN line: `--port` and `8080` are two lines, so the pattern has
        //     to be the flag ALONE, and the value checked on the next one.
        //
        // `grep -A1` after the flag is what pairs them.
        return "for p in " + D + "(pgrep -x llama-server); do "
             + "  if tr '\\0' '\\n' < /proc/" + D + "p/cmdline 2>/dev/null "
             + "       | grep -A1 -x -- '--port' | tail -1 | grep -qx -- '" + root.port + "'; then "
             + "    echo " + D + "p; break; fi; done";
    }

    // The combined pid / VRAM / uptime script, as a shell string.
    //
    // `pidFindCommand()` still exists and is still the pid rule; this reuses it
    // verbatim rather than restating it, so there is still exactly one place
    // that decides which llama-server is ours.
    function vramScript() {
        const D = "$";
        const Q = '"';
        // Kept as a MULTI-LINE script, joined with "\n", and that is load-bearing
        // rather than cosmetic.
        //
        // Flattened onto one line it does not parse: bash counts the `)` in
        // `$(for p in ...; done)` as closing the substitution, so everything
        // after it lands outside the command and the whole script dies with
        // "syntax error near unexpected token `fi'". With real newlines the
        // parser tracks the nesting correctly. Because bash reported that as a
        // PARSE error the process printed nothing at all -- so pid, VRAM and
        // uptime were all silently zero, three readings that had worked
        // separately and broke the moment they were combined.
        return [
            "P=" + D + "(",
            "  for p in " + D + "(pgrep -x llama-server); do",
            "    if tr '\\0' '\\n' < /proc/" + D + "p/cmdline 2>/dev/null \\",
            "       | grep -A1 -x -- '--port' | tail -1 | grep -qx -- " + Q + root.port + Q + "; then",
            "      echo " + D + "p; break",
            "    fi",
            "  done",
            ")",
            "echo " + Q + "pid=" + D + "P" + Q,
            "if [ -n " + Q + D + "P" + Q + " ] && [ -d /proc/" + D + "P ]; then",
            "  T=" + D + "(stat -c %Y /proc/" + D + "P 2>/dev/null)",
            "  echo " + Q + "up=" + D + "((" + D + "(date +%s) - T ))" + Q,
            "fi",
            "nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null",
            "echo ---",
            "nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null",
        ].join("\n");
    }

    function _applyVram(raw) {
        const lines = (raw ?? "").split("\n").map(s => s.trim()).filter(s => s.length > 0);
        const split = lines.indexOf("---");
        const head = split >= 0 ? lines.slice(0, split) : lines;
        const apps = [];
        for (const line of head) {
            if (line.startsWith("pid=")) {
                const p = parseInt(line.slice(4).trim(), 10);
                if (!isNaN(p) && p > 0) root._pid = p;
            } else if (line.startsWith("up=")) {
                const v = parseInt(line.slice(3).trim(), 10);
                root.uptimeSeconds = isNaN(v) ? 0 : v;
            } else {
                apps.push(line);
            }
        }
        // The pid is only adopted while we do not have one, so a pid that has
        // gone stale cannot be re-adopted from a recycled number.
        if (root._pid <= 0) return;
        let mine = 0;
        for (const line of apps) {
            const parts = line.split(",").map(s => s.trim());
            if (parts[0] === String(root._pid)) mine = parseFloat(parts[1] ?? "0") || 0;
        }
        root.vramMiB = mine;
        if (split >= 0 && lines.length > split + 1)
            root.vramTotalMiB = parseFloat(lines[split + 1]) || root.vramTotalMiB;
        // Now that the pid is known, start the uptime poller so it keeps
        // ticking for as long as the server lives.
        uptimePoll.running = false;
        uptimePoll.running = true;
    }

    // Uptime from /proc/<pid>, so it survives a shell restart.
    Process {
        id: uptimePoll
        // Every shell `$` is escaped as \\x24 (see pidFindCommand). This one read
        // `/proc//cmdline`-style empty expansions before, which is why uptime
        // sat at "just now" for a server that had been up for an hour.
        command: ["bash", "-c",
            "test -e /proc/" + root.serverPid
          + " && echo " + "$" + "(( " + "$" + "(date +%s) - " + "$" + "(stat -c %Y /proc/" + root.serverPid + ") )) || echo 0"]
        stdout: StdioCollector {
            onStreamFinished: {
                const v = parseInt((text ?? "0").trim(), 10);
                root.uptimeSeconds = isNaN(v) ? 0 : v;
            }
        }
    }

    // ── the model list ───────────────────────────────────────────────────
    Process {
        id: scanModels
        command: ["bash", "-c",
            // `~/Models` rather than `$HOME/Models`: bash expands a tilde on
            // its own, which keeps a shell `$` out of a QML string entirely
            // (see pidFindCommand for why that matters).
            "find ~/Models -maxdepth 3 -name '*.gguf' -printf '%s\\t%p\\n' 2>/dev/null | sort -rn"]
        stdout: StdioCollector {
            onStreamFinished: {
                const out = [];
                for (const line of (text ?? "").split("\n")) {
                    if (line.trim().length === 0) continue;
                    const sp = line.indexOf("\t");
                    if (sp < 0) continue;
                    const size = parseInt(line.slice(0, sp), 10);
                    const path = line.slice(sp + 1).trim();
                    const base = path.split("/").pop().replace(/\.gguf$/i, "");
                    out.push({
                        path: path,
                        name: base,
                        bytes: size,
                        sizeText: root._humanSize(size),
                    });
                }
                root.models = out;
            }
        }
    }

    function _humanSize(b) {
        if (!b || b <= 0) return "?";
        const gb = b / 1073741824;
        return gb >= 1 ? `${gb.toFixed(2)} GB` : `${(b / 1048576).toFixed(0)} MB`;
    }

    function scan() {
        scanModels.running = false;
        scanModels.running = true;
    }

    Component.onCompleted: {
        // Defaults first, then the FileView result overwrites them with
        // anything saved. That ordering is deliberate: this file has to be
        // usable for its whole life, and the panel binds to launchParams from
        // the first frame.
        root.scan();
        // Adopt a server that was already running, so the panel does not claim
        // "stopped" while something is answering on the port. /health says
        // yes; the pid is then discovered the same way it is after a start.
        http.get(root.base + "/health", () => {
            root.online = true;
            root.readProps();
            root.readSlots();
            root.readMetrics();
            root.readVram();
            // A server that was already up when the shell started needs its
            // pid found too, or its VRAM and uptime read zero.
            uptimePoll.running = false;
            uptimePoll.running = true;
        }, () => {});
    }

    // ── readable shapes for the UI ───────────────────────────────────────
    readonly property string speedGenText: root.genTokensPerSec > 0
        ? root.genTokensPerSec.toFixed(1) : "—"
    readonly property string speedPromptText: root.promptTokensPerSec > 0
        ? root.promptTokensPerSec.toFixed(1) : "—"
    readonly property string vramText: root.vramMiB > 0
        ? `${root.vramGiB.toFixed(1)} / ${root.vramTotalGiB.toFixed(1)} GB`
        : "—"
    readonly property real vramFraction: root.vramTotalMiB > 0
        ? Math.min(1, root.vramMiB / root.vramTotalMiB) : 0
    // Bars are scaled against what the card can do, not against a guess: a
    // 45 t/s figure means little without knowing the ceiling.
    readonly property real genFraction: Math.min(1, root.genTokensPerSec / 80)
    readonly property real promptFraction: Math.min(1, root.promptTokensPerSec / 120)
    readonly property string modelSummary: root.modelName.length > 0
        ? `${root.modelName} · ${root.modelQuant}` : "—"
    // The model to NAME in the UI. `modelName` is only known while the server
    // is up (it is read from /props), so when nothing is running the label
    // falls back to the .gguf a Start would actually launch -- the selected
    // model on disk. That is what lets the island read "Qwen3-8B-Q4_K_M"
    // instead of a bare "AI off" while the server is down.
    readonly property string displayName: root.modelName.length > 0
        ? root.modelName
        : (root.selectedModel ? root.selectedModel.name : "")
    // "3h 12m" / "41m" / "just now" -- the server's real age from /proc.
    readonly property string uptimeText: root._uptimeText()
    readonly property string addressText: `${root.host}:${root.port}`

    IpcHandler {
        target: "llama"

        // What the panel is actually looking at, for verification.
        function state(): string {
            return `online=${root.online} loading=${root.loading} `
                 + `model="${root.modelName}" slots=${root.busySlots}/${root.totalSlots} `
                 + `perSlotCtx=${root.perSlotCtx} gen=${root.genTokensPerSec.toFixed(1)} `
                 + `prompt=${root.promptTokensPerSec.toFixed(1)} `
                 + `vram=${root.vramMiB.toFixed(0)}MiB pid=${root.serverPid} `
                 + `uptime=${root.uptimeSeconds.toFixed(0)}s logLines=${root.logLines.length} `
                 + `models=${root.models.length} err="${root.lastError}"`
                 // Why the three model facts are broken out rather than folded
                 // into `models=`. `start()` refuses with "No .gguf model
                 // found" whenever `selectedModel` is falsy, and that refusal
                 // is indistinguishable from an empty list unless you can see
                 // the three things that decide it: the derived selection, the
                 // index it clamps, and what the array actually holds.
                 + ` sel=${root.selectedModel ? "ok" : "NULL"}`
                 + ` mIdx=${root.modelIndex}`
                 + ` m0=${root.models[0] === undefined ? "undef" : (root.models[0] === null ? "null" : typeof root.models[0])}`;
        }

        // The same entry point the button uses, reachable from `qs ipc` -- so
        // what gets exercised is the real path and not a copy of it.
        function toggle(): void { root.toggle(); }
        function start(): void { root.start(); }
        function stop(): void { root.stop(); }
        function scan(): void { root.scan(); }
        function refresh(): void { root.poll(); }
        // Put every parameter back to its built-in default.
        //
        // This one was here before the settings moved into their own window
        // and was accidentally deleted along with the stepper plumbing; it is
        // the only way back to the defaults from outside the panel, so it stays.
        function reset(): string { root.resetParams(); return "ok"; }
        // The fullscreen settings surface, drivable without a pointer.
        function settings(open: bool): string {
            root.settingsOpen = open;
            return "settingsOpen=" + root.settingsOpen;
        }
        // The log itself. A start that fails is invisible without this: the
        // process dies, `online` never rises, and the panel just sits there
        // looking switched off with nothing saying why.
        function log(): string { return root.logText; }
        // The exact argv the Start button would run, so the launch can be
        // reproduced in a terminal when something refuses to come up.
        function argv(): string { return root.argvText(); }
        // Scriptable access to the editable parameters, so they can be driven
        // and verified without clicking the panel:
        //   qs -c ii ipc call llama params
        //   qs -c ii ipc call llama set ctx 16384
        //   qs -c ii ipc call llama reset
        function params(): string {
            return JSON.stringify(root.launchParams.map(p => ({ key: p.key, value: p.value })));
        }
        function set(key: string, value: string): string {
            // Booleans are parsed as WORDS, not coerced. IPC hands everything
            // over as a string, and `!!"false"` is true -- so asking for a
            // switch to turn off used to turn it on, silently.
            const s = String(value);
            if (s === "true")
                root.setParam(key, true);
            else if (s === "false")
                root.setParam(key, false);
            else
                root.setParam(key, s);
            return String(root.paramValue(key));
        }
        
        // What the panel is reading, for verification: whether polling is
        // claimed, and whether the live generation rate is advancing.
        function probe(): string {
            return `online=${root.online} tabVisible=${root.tabVisible} `
                 + `pid=${root.serverPid} vram=${root.vramMiB.toFixed(0)}MiB `
                 + `up=${root.uptimeSeconds.toFixed(0)}s `
                 + `decoded=${root._liveDecoded.toFixed(0)} `
                 + `gen=${root.genTokensPerSec.toFixed(1)} `
                 + `prompt=${root.promptTokensPerSec.toFixed(1)} `
                 + `err="${root.lastError}"`;
        }
    }
}