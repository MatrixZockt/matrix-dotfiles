pragma Singleton

import qs.modules.common
import qs.modules.common.functions
// StatusSignal's perf table (the stall attribution). Same-module import is
// how ProcessList reaches the rest of the service singletons; without it the
// perfMark calls below resolve to a runtime ReferenceError, which would take
// `list` and `guessIcon` down with them.
import qs.services
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * - Eases fuzzy searching for applications by name
 * - Guesses icon name for window class name
 */
Singleton {
    id: root
    property bool sloppySearch: Config.options?.search.sloppy ?? false
    property real scoreThreshold: 0.2
    property var substitutions: ({
        "code-url-handler": "visual-studio-code",
        "Code": "visual-studio-code",
        "gnome-tweaks": "org.gnome.tweaks",
        "pavucontrol-qt": "pavucontrol",
        "wps": "wps-office2019-kprometheus",
        "wpsoffice": "wps-office2019-kprometheus",
        "footclient": "foot",
    })
    property var regexSubstitutions: [
        {
            "regex": /^steam_app_(\d+)$/,
            "replace": "steam_icon_$1"
        },
        {
            "regex": /Minecraft.*/,
            "replace": "minecraft"
        },
        {
            "regex": /.*polkit.*/,
            "replace": "system-lock-screen"
        },
        {
            "regex": /gcr.prompter/,
            "replace": "system-lock-screen"
        }
    ]

    // Does the program a desktop entry execs actually exist? The entry's exec
    // line is shell syntax ("prog --flag %U"), so the first word is the
    // candidate and everything after it is decoration: field codes (%U, %f)
    // and flags. An absolute path is checked directly; a bare name is looked
    // up on PATH.
    //
    // There is no synchronous filesystem API in this Quickshell build (the
    // obvious `FileSystem` singleton does not exist here -- verified against
    // /usr/lib/qt6/qml/Quickshell), so the check runs as ONE shell probe over
    // the whole catalogue and lands in `deadEntries`. Until the first probe
    // comes back the list is unfiltered -- a dead entry can appear for a
    // fraction of a second at shell start, which is still an improvement on
    // appearing forever.
    property var deadEntries: ({})

    function execTarget(execLine: string): string {
        const line = String(execLine ?? "").trim();
        if (line.length === 0) return "";
        let raw = line.split(/\s+/)[0];
        if (raw.length === 0) return "";
        // Expand a leading $VAR ($HOME/...), the form AppImage updaters love.
        if (raw.startsWith("$")) {
            const slash = raw.indexOf("/");
            const name = slash === -1 ? raw.slice(1) : raw.slice(1, slash);
            const value = Quickshell.env(name) ?? "";
            raw = value.length === 0 ? "" : value + raw.slice(name.length + 1);
        }
        return raw;
    }

    function probeExecutables() {
        const __t = Date.now();
        try {
        const entries = DesktopEntries.applications.values;
        if (entries.length === 0) return;
        // The probe's PATH decides which entries count as "dead". The shell
        // can be started by Hyprland (full login PATH) or by the systemd user
        // watchdog (compiled-in default: /usr/local/bin:/usr/bin, NO
        // ~/.local/bin) -- with the stripped PATH, every user-installed entry
        // (the vendor app and friends) probed "missing" and was hidden
        // from the SUPER menu, then reappeared depending on which launcher
        // had started the shell. So the probe always searches the user's own
        // bin dirs FIRST, regardless of how this process was launched.
        const userBins = [`${Quickshell.env("HOME")}/.local/bin`,
                          `${Quickshell.env("HOME")}/bin`,
                          `${Quickshell.env("HOME")}/.cargo/bin`]
            .filter(b => b.length > 0);
        const searchPath = [...userBins, Quickshell.env("PATH") ?? ""].join(":");
        let payload = "";
        for (const app of entries) {
            const line = app.execString ?? app.exec;
            // No readable exec line: never marked dead (hiding apps on a
            // guess would be a worse failure than the one this fixes).
            if (line === undefined || line === null) continue;
            const target = execTarget(String(line));
            if (target.length === 0) continue;
            payload += `${app.id}|${target}\n`;
        }
        if (payload.length === 0) {
            // Only disarm what is armed: an unconditional `{}` here re-fired
            // `list` (and everything derived from it) on every 45 s sweep of
            // an empty catalogue.
            if (Object.keys(deadEntries).length > 0)
                deadEntries = {};
            return;
        }
        execProbe.command = ["bash", "-c",
            `while IFS='|' read -r id target; do\n`
            + `  [ -n "$target" ] || continue\n`
            + `  case "$target" in\n`
            + `    */*) [ -x "$target" ] || echo "$id" ;;\n`
            + `    *) PATH=${JSON.stringify(searchPath)} command -v -- "$target" >/dev/null 2>&1 || echo "$id" ;;\n`
            + `  esac\n`
            + `done <<'II_PROBE_EOF'\n${payload}II_PROBE_EOF`];
        execProbe.running = false;
        execProbe.running = true;
        } finally {
            StatusSignal.perfMark("apProbe", Date.now() - __t);
        }
    }

    Process {
        id: execProbe
        command: []
        stdout: StdioCollector {
            onStreamFinished: {
                const dead = {};
                for (const id of String(text ?? "").split("\n")) {
                    const clean = id.trim();
                    if (clean.length > 0) dead[clean] = true;
                }
                // Content compare before assigning. The 45 s self-heal probe
                // almost always finds the same set, and assigning an
                // equal-but-fresh object re-fires `list` -- which rebuilt the
                // four prepped* arrays, typoTargets AND wiped the guessIcon
                // cache every 45 s for no change anybody could see.
                const prev = root.deadEntries;
                let changed = false;
                for (const id in dead) {
                    if (prev[id] !== true) { changed = true; break; }
                }
                if (!changed) {
                    for (const id in prev) {
                        if (dead[id] !== true) { changed = true; break; }
                    }
                }
                if (changed)
                    root.deadEntries = dead;
            }
        }
    }

    // ── One probe per refresh, not one per notification ───────────────────
    // `DesktopEntries.applications` notifies once per directory re-scan, and
    // touching ONE .desktop file produces 89 notifications in 14 s. Each one
    // used to call `probeExecutables()` directly, i.e. to fork a fresh `bash`
    // script that runs `command -v` over the whole catalogue -- 89 forks per
    // refresh, measured at 0.8-1.1 s of event-loop lateness per burst. That
    // was the stall the icon-cache work did not explain: it sits outside
    // every binding, so it showed up only as `tick` lateness, and it lands    // mid-gesture.
    //
    // A 250 ms one-shot coalesces the burst into the single probe the 45 s
    // self-heal would run anyway. The answer is identical; it just arrives a
    // quarter second after the LAST notification instead of after the first.
    Timer {
        id: probeDebounce
        interval: 250
        repeat: false
        onTriggered: root.probeExecutables()
    }

    Component.onCompleted: probeDebounce.restart()
    // The boot-time trigger. Component.onCompleted above usually runs BEFORE
    // the catalogue is loaded (its early-return then skips the probe) -- the
    // signal below usually fires -- but neither is guaranteed to land after
    // the entries arrive. This one cannot miss: it is the arrival itself.
    readonly property bool entriesReady: DesktopEntries.applications.values.length > 0
    onEntriesReadyChanged: if (entriesReady) probeDebounce.restart()
    Connections {
        target: DesktopEntries
        function onApplicationsChanged() {
            probeDebounce.restart();
        }
    }
    // The self-heal. The change signal above is the INSTANT path, but it has
    // two holes, both observed: the catalogue often finishes loading AFTER
    // this singleton's Component.onCompleted (the early-return then skips the
    // first probe), and a desktop file appearing on disk does not reliably
    // fire the signal (Freebuff's session re-creates its stale entry and the
    // shell noticed nothing for minutes). A slow sweep closes both: worst
    // case a dead entry shows for 45 s after a restart or a re-created file,
    // never for ever. The probe itself costs milliseconds for the whole
    // catalogue, so the idle cost is nothing.
    Timer {
        interval: 45000
        repeat: true
        running: true
        triggeredOnStart: false
        onTriggered: root.probeExecutables()
    }

    // Deduped list to fix double icons -- and, the part that mattered: entries
    // whose program no longer exists are dropped (see probeExecutables). A
    // stale entry used to stay perfectly visible (an updater had written a new
    // one next to it, the old one still pointed into a cleaned-out ~/Downloads),
    // so the launcher showed the app twice and half the clicks died with exit
    // 127 -- which the shell reports honestly, but three seconds after the
    // click, which reads as "opening apps is broken". Dead entries do not
    // surface at all now.
    readonly property list<DesktopEntry> list: (() => {
        // SINGLE PASS, not a dedup-by-findIndex.
        //
        // This used to be `.filter((app, index, self) => index ===
        // self.findIndex(t => t.id === app.id))`, which is O(n^2): for the
        // i-th entry `findIndex` rescans from the start looking for that same
        // id, so an n-entry desktop database costs n^2/2 property reads
        // against live QML objects. Measured by the QML profiler on this
        // machine: one evaluation of this binding took 1862ms (avg 621ms),
        // and it re-runs whenever the launcher database or a dead entry
        // changes -- which the bar then pays for inside an unrelated frame.
        //
        // `seen` keeps the FIRST occurrence per id, exactly what the old
        // `index === findIndex(...)` predicate selected, and the two later
        // filters are folded in as plain early continues so the order of
        // decisions is unchanged: first occurrence wins the id, then that
        // survivor is tested for deadness and for being listed.
        //
        // A plain object rather than a Set, for the same reason ProcessList
        // uses objects rather than a Map: this is QML's JS engine, and the
        // object-with-`=== true` test is the subset that is certain to hold.
        const seen = {};
        const out = [];
        const __t0 = Date.now();
        const all = Array.from(DesktopEntries.applications.values);
        for (let i = 0; i < all.length; i++) {
            const app = all[i];
            const id = app.id;
            if (seen[id] === true)
                continue;
            seen[id] = true;
            if (deadEntries[id] === true)
                continue;
            if (!root.isListed(app))
                continue;
            out.push(app);
        }
        const __r = out;
        StatusSignal.perfMark("apList", Date.now() - __t0);
        return __r;
    })()

    // Is this entry one of the "my apps" the menu should show?
    //
    // Two filters, both needed:
    //   * NoDisplay -- the spec's own opt-out. Honoured here (and it is NOT the
    //     same as "hidden by the user": these entries are hidden by the
    //     packages that ship them).
    //   * The user's own hidden list, Config.options.launcher.hiddenApps.
    //     Everything in it is a real, working program -- an HDSP control
    //     panel, the NVIDIA settings, a Java shell -- so none of it is
    //     "broken" in the sense `deadEntries` means. It is simply not an app
    //     you open; it is furniture. See the list for why it is a list and
    //     not a category heuristic.
    //
    // `showAllApps` is the escape hatch: flip it and the whole catalogue comes
    // back, so nothing here can permanently lock an app out of the menu.
    function isListed(app): bool {
        if (app === undefined || app === null)
            return false;
        if (app.noDisplay === true)
            return false;
        const launcher = Config.options?.launcher;
        if (launcher?.showAllApps === true)
            return true;
        const hidden = launcher?.hiddenApps ?? [];
        return hidden.indexOf(app.id) === -1;
    }
    
    readonly property var preppedNames: {
        const __t = Date.now();
        const __r = list.map(a => ({
            name: root.prepCached(`${a.name} `),
            entry: a
        }));
        StatusSignal.perfMark("apPrepNames", Date.now() - __t);
        return __r;
    }

    // The SECOND haystack, searched only when the first comes up short.
    //
    // The display name is not always the word people type. Freebuff is the
    // live case: its desktop entry has been called "Freebuff Desktop" and
    // "Freebuff" at different times, because the file it is launched through
    // was renamed once to stop shadowing the Freebuff CLI on PATH -- and an
    // app whose Name moves is an app you cannot search for. The entry ID
    // comes from the FILENAME, which never moved, so it is the stable handle.
    //
    // Deliberately a fallback and not a merge into `preppedNames`. Folding the
    // ID into the one haystack would let a two-letter query match every entry
    // with "code" in its filename and bury the apps you actually meant, which
    // is a worse failure than the one this fixes. Name matches always rank
    // first and are never displaced; this only ADDS what was missing.
    readonly property var preppedIds: {
        const __t = Date.now();
        const __r = list.map(a => ({
            name: root.prepCached(`${a.id} `),
            entry: a
        }));
        StatusSignal.perfMark("apPrepIds", Date.now() - __t);
        return __r;
    }

    readonly property var preppedIcons: {
        const __t = Date.now();
        const __r = list.map(a => ({
            name: root.prepCached(`${a.icon} `),
            entry: a
        }));
        StatusSignal.perfMark("apPrepIcons", Date.now() - __t);
        return __r;
    }

    // The THIRD haystack, and the one people actually expect to work.
    //
    // Names are not the words people type. Disk Usage Analyzer is found by
    // "disk", "space", "storage" or "cleanup"; Thunderbird by "mail"; a code
    // editor by "text". Those words live in the desktop entry's Comment,
    // GenericName and Keywords fields -- and nothing here read them, so a
    // search for any of them found nothing at all. Measured on this machine:
    // "storage" and "cleanup" both scored 0.000 against the name alone, even
    // though baobab's Keywords field literally lists them.
    //
    // Kept as a separate pass rather than folded into `preppedNames` for the
    // same reason `preppedIds` is: merging them would let a generic word like
    // "files" drag unrelated entries up next to an exact name match. A name
    // hit always outranks a keyword hit.
    readonly property var preppedDescriptions: {
        const __t = Date.now();
        const __r = list.map(a => ({
            name: root.prepCached(`${a.genericName ?? ""} ${a.comment ?? ""} ${(a.keywords ?? []).join(" ")} `),
            entry: a
        }));
        StatusSignal.perfMark("apPrepDesc", Date.now() - __t);
        return __r;
    }

    // Word-level tokens for the typo pass, one flat list per entry: the name,
    // the generic name, the keywords and the id. Built once, not per keystroke.
    //
    // Scoring is per TOKEN rather than against the whole name string, because
    // the raw name distance is misleading: "browesr" scores 0.494 against the
    // whole string "Brave" but 0.985 against the token "brave" -- a five-letter
    // name cannot absorb an eight-letter typo in its length ratio, and the
    // answer you want is obvious to a human. Comparing per token is what makes
    // this work on names of any length.
    readonly property var typoTargets: list.map(a => ({
        entry: a,
        tokens: `${a.name} ${a.genericName ?? ""} ${(a.keywords ?? []).join(" ")} ${a.id}`
            .toLowerCase()
            .split(/[^a-z0-9]+/)
            .filter(t => t.length >= 3)
    }))

    // Typo tolerance, as a score out of 1.0. Calibrated by scoring the real
    // catalogue rather than picked by feel -- the gap between "you meant this"
    // and "this is a different app" is wide:
    //
    //   accepted: spotfy/spotify 0.909  termnal/alacritty 0.931
    //             thundrbird/thunderbird 0.993  analyser/analyzer 0.975
    //             coed/code 0.540  ffox/firefox 0.597
    //   rejected: term/thunderbird 0.295  note/android 0.209
    //             chat/kitty 0.157  pdf/firefox 0.093
    //             code/alacritty 0.054  mail/discord 0.000
    //
    // 0.45 sits in the empty band between the two groups. Raising it loses real
    // typos (coed/code is only 0.540); dropping it starts returning unrelated
    // apps, which is worse than returning nothing.
    property real typoThreshold: 0.45

    // How good a NAME match has to be before it counts as one at all.
    //
    // fuzzysort matches SUBSEQUENCES, so it will happily report a hit for any
    // query whose letters appear in order anywhere in a name. On its own that
    // is the right behaviour for a name search, but it broke the tiering this
    // file depends on: a garbage query like "sinnc" matched eight apps by
    // scattered letters, so the list came back "full", the typo pass below
    // never ran, and a genuine typo like "analyser" (which should reach
    // Disk Usage Analyzer's "analyzer") was answered with unrelated rows
    // instead. A weak subsequence match is not an answer -- it is noise that
    // looks like one, and it actively hides the tier that would have found the
    // right app.
    //
    // This is a normalized fuzzysort score, where 1.0 is a perfect match. A
    // NEGATIVE value must never be used here: fuzzysort denormalizes the
    // threshold with Math.log(), and log of a negative is NaN, which makes every
    // comparison false and silently filters NOTHING. Measured on this machine,
    // thresholds of -0.2 through -0.8 all returned the identical unfiltered
    // count. The value is positive for that reason as much as for the score.
    property real nameThreshold: 0.4

    // One token's worth of fuzzy scoring against the query.
    //
    // `: real`, NOT `: number` -- and not because of style. `number` is not a
    // return type this QML engine knows, so a function declared `: number` is
    // treated as returning VOID, and every call logged an ERROR saying the
    // value "should be coerced to void because the function called is
    // insufficiently annotated". This function runs once per token per
    // catalogue entry on the icon-guessing path, so that was tens of thousands
    // of log lines per shell load and roughly 51 s of the 80 s cold start.
    //
    // See modules/common/functions/Levendist.qml for the measured repro table,
    // and note the sibling wrappers there are deliberately UNannotated for the
    // same reason. Both files are load-bearing; do not retype either one.
    function tokenScore(token: string, query: string): real {
        return Levendist.computeScore(token, query);
    }

    function fuzzyQuery(search: string): var { // Idk why list<DesktopEntry> doesn't work
        const query = String(search ?? "").trim();
        if (query.length === 0)
            return [];

        if (root.sloppySearch) {
            const results = list.map(obj => ({
                entry: obj,
                score: Levendist.computeScore(obj.name.toLowerCase(), search.toLowerCase())
            })).filter(item => item.score > root.scoreThreshold)
                .sort((a, b) => b.score - a.score)
            return results
                .map(item => item.entry)
        }

        const seen = new Set();
        const ordered = [];
        // Results are collected by TIER, not merged and re-sorted: a name match
        // must never be displaced by a keyword match or a typo match, no matter
        // how the scores compare. `seen` is what keeps one app from appearing
        // twice when several tiers match it.
        const collect = (haystack, threshold) => {
            for (const result of Fuzzy.go(query, haystack, {
                all: true,
                key: "name",
                threshold: threshold
            })) {
                const entry = result.obj.entry;
                if (seen.has(entry.id))
                    continue;
                seen.add(entry.id);
                ordered.push(entry);
            }
        };

        collect(root.preppedNames, root.nameThreshold);

        // Nothing by name: descriptions, then the entry ID (see preppedIds for
        // why the ID is a fallback rather than part of the name haystack).
        if (ordered.length === 0) {
            collect(root.preppedDescriptions, root.nameThreshold);
            if (ordered.length === 0)
                collect(root.preppedIds, 0);
        }

        // Still nothing -- so the query is a typo, not a word. Only now does
        // the loose pass run, so it can never reorder the exact matches above.
        // A query of one or two characters is skipped entirely: at that length
        // "ca" and "ch" are one edit from most of the alphabet, and matching
        // them would fill the list with noise instead of typos.
        if (ordered.length === 0 && query.length >= 3) {
            const lowerQuery = query.toLowerCase();
            const scored = [];
            for (const target of root.typoTargets) {
                let best = 0;
                for (const token of target.tokens) {
                    const score = root.tokenScore(token, lowerQuery);
                    if (score > best)
                        best = score;
                }
                if (best >= root.typoThreshold)
                    scored.push({ entry: target.entry, score: best });
            }
            scored.sort((a, b) => b.score - a.score);
            for (const item of scored) {
                if (seen.has(item.entry.id))
                    continue;
                seen.add(item.entry.id);
                ordered.push(item.entry);
            }
        }

        return ordered;
    }

    function iconExists(iconName) {
        if (!iconName || iconName.length == 0) return false;
        return (Quickshell.iconPath(iconName, true).length > 0) 
            && !iconName.includes("image-missing");
    }

    function getReverseDomainNameAppName(str) {
        return str.split('.').slice(-1)[0]
    }

    function getKebabNormalizedAppName(str) {
        return str.toLowerCase().replace(/\s+/g, "-");
    }

    function getUndescoreToKebabAppName(str) {
        return str.toLowerCase().replace(/_/g, "-");
    }

    // guessIcon()'s resolved answer, per input string.
    //
    // This is the fix for the hottest path the QML profiler found on this
    // machine: guessIcon is called per row per rebuild from the task manager,
    // the dock, the overview, the bar and the tray, and its LAST fallback
    // runs the full-catalogue fuzzy search including the Levenshtein typo
    // pass -- measured at 6.06 M calls into the inner loop of levendist.js in
    // 10.5 s, ~400 ms of every single second, even with every UI closed. The
    // input is a window class / app id (a small bounded set), so the answer
    // is memoized and the expensive path runs at most once per distinct
    // class instead of on every delegate re-evaluation.
    //
    // Invalidated whenever `list` changes, because the fuzzy tiers read it:
    // catalogue load, launcher config edits, and a dead-entry probe that
    // actually changes the set (probeExecutables skips no-op assignments so
    // the 45 s self-heal does not wipe this cache for nothing).
    property var _iconCache: ({})
    // Signature of the catalogue the cache was built against: id + icon per
    // entry, in order.
    //
    // `list` is a BINDING, so every re-evaluation hands it a fresh array and
    // fires `onListChanged` -- including refreshes where nothing actually
    // changed. Measured on this machine: touching ONE .desktop file re-ran
    // `list` 89 times in 14 s and wiped this cache 68 times. Every wipe threw
    // away answers that were still correct, so the next card rebuild re-ran
    // `guessIconUncached` -- 476 of them, 136 falling through to fuzzyQuery's
    // full-catalogue Levenshtein pass at 105 ms each. That is 14.4 s of
    // main-thread work inside a 14 s window: the event loop stalled 15.4 s,
    // which is the "freezes for a second while I swipe" report.
    //
    // Gating the wipe on the signature keeps a real catalogue change honest
    // (an app installed still invalidates) while a no-op refresh costs one
    // string compare.
    property string _iconSig: ""
    // How often a `list` refresh was recognised as a no-op (the wipe the
    // signature is there to skip). Against `apIconWipes` in `status perf`
    // this tells the gate apart from an unconditional wipe.
    property int iconKeep: 0
    // The same test with ONLY the ids: if this one holds while `iconKeep`
    // stays 0, the churn is in the icon field rather than in which apps are
    // listed -- and that decides what the wipe is allowed to depend on.
    property int iconKeepIds: 0
    property string _idSig: ""
    function listIdSignature(): string {
        const parts = [];
        for (let i = 0; i < list.length; i++)
            parts.push(String(list[i]?.id ?? ""));
        // SORTED, on purpose. `DesktopEntries.applications.values` comes back
        // in a different order on every re-scan -- 41 entries, same ids, same
        // total length, shuffled -- so a positional signature compared unequal
        // on all 68 refreshes and the gate never once held (measured: keep=0,
        // keepIds=0 while sigLen stayed 1117). Which apps are listed is the
        // question; the order they are listed in is not.
        parts.sort();
        return parts.join("\u0002");
    }
    function listIconSignature(): string {
        const parts = [];
        for (let i = 0; i < list.length; i++) {
            const e = list[i];
            parts.push(String(e?.id ?? "") + "\u0001" + String(e?.icon ?? ""));
        }
        parts.sort();
        return parts.join("\u0002");
    }
    onListChanged: {
        const sig = root.listIconSignature();
        if (sig === root._iconSig) {
            root.iconKeep += 1;  // no-op refresh: every cached answer still holds
            return;
        }
        const ids = root.listIdSignature();
        if (ids === root._idSig)
            root.iconKeepIds += 1;
        else
            root._idSig = ids;
        root._iconSig = sig;
        root._iconCache = ({})
        StatusSignal.perfMark("apIconWipes", 0);
    }
    onSloppySearchChanged: _iconCache = ({})

    // `Fuzzy.prepare` is fuzzysort's RAW `prepare` -- the UNcached one; only
    // `getPrepared` memoizes (fuzzysort.js:298). The derived haystacks below
    // therefore re-prepare all ~41 entries from scratch on every catalogue
    // refresh, and the first search after one pays for it: measured at ~105 ms
    // for a single `fuzzyQuery` call. Preparing is a pure function of the
    // string, so a plain object memo makes a rebuild free with no
    // invalidation to get wrong.
    property var _prepMemo: ({})
    function prepCached(s: string): var {
        const hit = root._prepMemo[s];
        if (hit !== undefined)
            return hit;
        const p = Fuzzy.prepare(s);
        root._prepMemo[s] = p;
        return p;
    }

    function guessIcon(str) {
        if (!str || str.length == 0) return "image-missing";
        // hasOwnProperty, not `!== undefined`: a class named "toString" or
        // "valueOf" must miss the cache, not return Object.prototype.
        if (Object.prototype.hasOwnProperty.call(_iconCache, str))
            return _iconCache[str];
        const resolved = guessIconUncached(str);
        _iconCache[str] = resolved;
        return resolved;
    }

    function guessIconUncached(str) {
        const __t0 = Date.now();
        try {
        if (!str || str.length == 0) return "image-missing";

        // Quickshell's desktop entry lookup
        const entry = DesktopEntries.byId(str);
        if (entry) return entry.icon;

        // Normal substitutions
        if (substitutions[str]) return substitutions[str];
        if (substitutions[str.toLowerCase()]) return substitutions[str.toLowerCase()];

        // Regex substitutions
        for (let i = 0; i < regexSubstitutions.length; i++) {
            const substitution = regexSubstitutions[i];
            const replacedName = str.replace(
                substitution.regex,
                substitution.replace,
            );
            if (replacedName != str) return replacedName;
        }

        // Icon exists -> return as is
        if (iconExists(str)) return str;


        // Simple guesses
        const lowercased = str.toLowerCase();
        if (iconExists(lowercased)) return lowercased;

        const reverseDomainNameAppName = getReverseDomainNameAppName(str);
        if (iconExists(reverseDomainNameAppName)) return reverseDomainNameAppName;

        const lowercasedDomainNameAppName = reverseDomainNameAppName.toLowerCase();
        if (iconExists(lowercasedDomainNameAppName)) return lowercasedDomainNameAppName;

        const kebabNormalizedGuess = getKebabNormalizedAppName(str);
        if (iconExists(kebabNormalizedGuess)) return kebabNormalizedGuess;

        const undescoreToKebabGuess = getUndescoreToKebabAppName(str);
        if (iconExists(undescoreToKebabGuess)) return undescoreToKebabGuess;

        // Search in desktop entries
        const __g0 = Date.now();
        const iconSearchResults = Fuzzy.go(str, preppedIcons, {
            all: true,
            key: "name"
        }).map(r => {
            return r.obj.entry
        });
        StatusSignal.perfMark("giFuzzyIcons", Date.now() - __g0);
        if (iconSearchResults.length > 0) {
            const guess = iconSearchResults[0].icon
            if (iconExists(guess)) return guess;
        }

        const __f0 = Date.now();
        // Name tier ONLY -- deliberately not `root.fuzzyQuery(str)`.
        //
        // fuzzyQuery's descriptions/ids/typo tiers exist for a HUMAN typing
        // "disk" or "browesr" into the launcher. This is a WINDOW CLASS being
        // mapped to an icon name, where a Levenshtein pass over every
        // catalogue token buys nothing -- and it was not cheap: measured
        // `giFuzzyQuery` at avg 96-159 ms, max 2805 ms per call, 244 calls,
        // riding along inside `clAssignList` (max 5016 ms) and a 23 s event
        // loop stall. The name tier is the same `Fuzzy.go` the icon tier
        // above already runs, so it costs what that one costs: ~0.1 ms.
        const nameSearchResults = Fuzzy.go(str, root.preppedNames, {
            all: true,
            key: "name",
            threshold: root.nameThreshold
        }).map(r => r.obj.entry);
        StatusSignal.perfMark("giFuzzyQuery", Date.now() - __f0);
        if (nameSearchResults.length > 0) {
            const guess = nameSearchResults[0].icon
            if (iconExists(guess)) return guess;
        }

        // Quickshell's desktop entry lookup
        const heuristicEntry = DesktopEntries.heuristicLookup(str);
        if (heuristicEntry) return heuristicEntry.icon;

        // Give up. Use the shell's own generic app icon: an icon theme may not ship
        // "application-x-executable" at a usable size (Adwaita does not), which made
        // widgets show a broken-image placeholder instead.
        return Quickshell.shellPath("assets/icons/fluent/app-generic.svg");
        } finally {
            StatusSignal.perfMark("giUncached", Date.now() - __t0);
        }
    }

    IpcHandler {
        target: "appSearchService"

        // How many entries survived the filters, and -- because "the menu is
        // missing my app" is the complaint this filter will cause -- exactly
        // which ones were dropped and why. Readable without a mouse.
        // Diagnostic: which version of the gate is running, and what it did.
        function iconDiag(): string {
            let cacheKeys = 0;
            for (const k in root._iconCache) cacheKeys++;
            let prepKeys = 0;
            for (const k in root._prepMemo) prepKeys++;
            return `sigLen=${root._iconSig.length} keep=${root.iconKeep}`
                + ` keepIds=${root.iconKeepIds}`
                + ` cacheKeys=${cacheKeys} prepKeys=${prepKeys}`
                + ` listLen=${root.list.length} sig=${root._iconSig.slice(0, 40)}`;
        }

        function state(): string {
            const all = Array.from(DesktopEntries.applications.values);
            const hiddenCfg = Config.options?.launcher?.hiddenApps ?? [];
            const showAll = Config.options?.launcher?.showAllApps === true;
            const dropped = all.filter(a => !root.isListed(a));
            return `catalogue=${all.length} listed=${root.list.length} dropped=${dropped.length}`
                + ` showAllApps=${showAll} hiddenApps=${hiddenCfg.length}`
                + (dropped.length === 0 ? "" : "\ndropped: " + dropped.map(a => a.id).join(", "));
        }
        // Escape hatch from the shell: bring everything back without editing
        // the config by hand.
        function showAll(): void {
            Config.options.launcher.showAllApps = true;
        }
        function hideSystem(): void {
            Config.options.launcher.showAllApps = false;
        }
        // Run a real search through the real ranking and report what came back.
        // Search behaviour is a ranking function, and a ranking function cannot
        // be checked by reading it -- this is the only way to see which TIER a
        // given query was answered by, which is the thing that decides whether
        // a keyword hit outranks a name hit or a typo hit outranks both.
        function query(q: string): string {
            const needle = String(q ?? "").trim();
            const hits = root.fuzzyQuery(needle);
            const names = hits.slice(0, 12).map(e => `${e.name}${root.isListed(e) ? "" : " [HIDDEN]"}`);
            return `q="${needle}" hits=${hits.length}`
                + ` threshold=${root.typoThreshold}`
                + ` list=${root.list.length} preppedNames=${root.preppedNames.length}`
                + ` rawName=${Fuzzy.go(needle, root.preppedNames, { all: true, key: "name" }).length}`
                + ` sloppy=${root.sloppySearch}`
                + `\n${names.join("\n")}`;
        }
        // Raw per-token scores for one query, so a threshold can be checked against
        // real numbers instead of argued about.
        function scores(q: string): string {
            const needle = String(q ?? "").trim().toLowerCase();
            const rows = [];
            for (const target of root.typoTargets) {
                let best = 0;
                let bestToken = "";
                for (const token of target.tokens) {
                    const s = root.tokenScore(token, needle);
                    if (s > best) { best = s; bestToken = token; }
                }
                if (best > 0.05)
                    rows.push(`${target.entry.name} :: ${best.toFixed(3)} via "${bestToken}"`);
            }
            rows.sort();
            return `q="${needle}" levendist=${typeof Levendist.computeScore}\n` + rows.slice(0, 14).join("\n");
        }
        // Score dump for several queries at once (pipe-separated), because each
        // round-trip to a crash-looping shell is expensive. Reports the actual
        // normalized fuzzysort score of every name/description hit, plus the
        // best Levenshtein token score per entry, so thresholds can be read off
        // real numbers instead of guessed.
        function probe(q: string): string {
            const out = [];
            for (const raw of String(q ?? "").split("|")) {
                const needle = raw.trim();
                if (needle.length === 0)
                    continue;
                const nameHits = Fuzzy.go(needle, preppedNames, { all: true, key: "name" })
                    .slice(0, 5).map(r => `${r.obj.entry.name}=${r.score.toFixed(2)}`);
                const descHits = Fuzzy.go(needle, preppedDescriptions, { all: true, key: "name" })
                    .slice(0, 5).map(r => `${r.obj.entry.name}=${r.score.toFixed(2)}`);
                const typo = [];
                for (const target of root.typoTargets) {
                    let best = 0, tok = "";
                    for (const token of target.tokens) {
                        const s = root.tokenScore(token, needle.toLowerCase());
                        if (s > best) { best = s; tok = token; }
                    }
                    if (best >= 0.3)
                        typo.push(`${target.entry.name}=${best.toFixed(2)}/${tok}`);
                }
                typo.sort();
                out.push(`[${needle}] list=${root.list.length}`
                    + `\n  NAME ${nameHits.join(" ") || "-"}`
                    + `\n  DESC ${descHits.join(" ") || "-"}`
                    + `\n  TYPO ${typo.slice(0, 6).join(" ") || "-"}`);
            }
            return out.join("\n");
        }
        // Which tier answered it. 1 = name, 2 = description/keywords/id,
        // 3 = typo-tolerant fallback.
        function tier(q: string): string {
            const needle = String(q ?? "").trim();
            if (needle.length === 0)
                return "q is empty";
            if (Fuzzy.go(needle, root.preppedNames, { all: true, key: "name" }).length > 0)
                return `q="${needle}" tier=1 name`;
            if (Fuzzy.go(needle, root.preppedDescriptions, { all: true, key: "name" }).length > 0)
                return `q="${needle}" tier=2 keywords`;
            if (Fuzzy.go(needle, root.preppedIds, { all: true, key: "name" }).length > 0)
                return `q="${needle}" tier=2 id`;
            if (needle.length >= 3)
                return `q="${needle}" tier=3 typo`;
            return `q="${needle}" tier=none (too short for the typo pass)`;
        }
    }
}

