pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common

/**
 * The login screen's layout templates -- ONE list, read from the login screen
 * itself.
 *
 *   * the SDDM login screen, which reads a fragment from
 *     hypr/custom/sddm-theme/layouts/*.js (composed into active.js by
 *     scripts/set-login-layout.sh and baked in by install-sddm-theme.sh);
 *   * the in-session lock (SUPER+L), which is a shell surface and reads this
 *     list at run time.
 *
 * WHY THIS IS A GENERATED FILE AND NOT A LIST
 * ------------------------------------------
 * This used to be a hand-written list of seven templates whose own header
 * claimed the .js fragments "mirrored these numbers". That was the wrong way
 * round: it was a COPY, and copies drift. `sheet` was added to the SDDM theme
 * and never reached this list, so the lock asked for "sheet", `byValue()`
 * found nothing, and returned `fallback` -- which is "classic". The result was
 * a login screen and a lock screen that looked nothing alike, with no error
 * anywhere and no config to fix, because the two were reading from different
 * files that had quietly fallen out of step.
 *
 * So the fragments are now the only copy. scripts/login/generate-layout-index.sh
 * reads every layouts/*.js and writes the numbers to
 * state/user/generated/loginLayouts.json; this file reads that. Change a
 * login template and the lock follows on the next reload, because there is
 * nothing left here to change.
 *
 * The one thing still declared here is `fallbackList` -- what to do when the
 * index cannot be read at all (a fresh checkout before the generator has run,
 * or a theme directory that has gone missing). It exists so a missing file
 * degrades to a working lock screen instead of an empty one, and it is a
 * deliberately conservative subset rather than a third copy of the truth.
 *
 * The fields are exactly the variables the SDDM fragments carry:
 *
 *   value       slug written to Persistent.states.loginLayout
 *   name        what the settings picker shows (derived; see displayMeta)
 *   icon        Material symbol in the picker
 *   fragment    the .js file in the SDDM layouts directory for this template
 *   align       "center" or "left"
 *   verticalOffset  column offset from centre, as a fraction of screen height
 *   clock       is the clock drawn at all
 *   card        is there a frosted panel behind the column
 *   clockScale  clock size multiplier (1.0 = the shipped size)
 *   hud         "ops"-style HUD presentation: corner telemetry, big centred
 *               clock with accent seconds, segmented passphrase card, and
 *               the arrow / dot template switcher (see LockSurface.qml)
 *   sheet       the "sheet" arrangement: clock top-right, account tile and
 *               password baseline bottom-left, flat scrim, corner telemetry
 */
Singleton {
    id: root

    // ── Where the truth lives ───────────────────────────────────────────
    // A FileView, not a hardcoded array: this is the whole point of the file.
    // `blockLoading` is deliberately NOT set -- a singleton that blocks on a
    // disk read can be constructed during shutdown, and blocking there is how
    // a shell ends up wedged. It loads asynchronously and the fallback list
    // covers the gap.
    readonly property int indexLoaded: root.indexData ? 1 : 0

    FileView {
        id: layoutsFile
        path: Qt.resolvedUrl(Directories.generatedLoginLayoutsPath)
        watchChanges: true
        // Blocking is correct here: the index is ~1.5 KB of local JSON, and a
        // singleton is constructed lazily so the first read has to have
        // happened by the time the binding below first evaluates.
        blockLoading: true
        preload: true
        onFileChanged: layoutsFile.reload()
    }

    // Bumped whenever the file lands, so the bindings that read the parsed
    // index re-evaluate. QML does not reliably track a read made inside a
    // JS function called from a binding, and this build's FileView never sets
    // `loaded` for a path outside the config dir, so neither `loaded` nor a
    // bare text() read is a reliable trigger. An explicit generation counter
    // is. The comma operator is deliberate: it makes the counter a dependency
    // of the binding without contributing a value.
    property int indexGeneration: 0
    Connections {
        target: layoutsFile
        function onFileChanged() { root.indexGeneration++; }
        function onLoadedChanged() { root.indexGeneration++; }
    }

    // Writes a new template selection (see requestLayout).
    Process {
        id: switchLayout
        running: false
    }

    // Parsed once, no side effects: a binding that assigns to another
    // property re-enters itself, and this one feeds the visible template.
    function parseIndex() {
        // `loaded` is deliberately NOT consulted: this build leaves it false
        // for a file outside the config directory even after the reader has
        // finished, so gating on it meant the lock drew its fallback forever.
        // An empty read is the honest "not ready yet" signal, and it is the
        // same condition the fallback list exists for.
        const raw = layoutsFile.text();
        if (!raw || raw.length === 0)
            return null;
        try {
            const parsed = JSON.parse(raw);
            if (!parsed || !Array.isArray(parsed.layouts) || parsed.layouts.length === 0)
                return null;
            // Normalise onto the field names the rest of the shell uses, and
            // drop anything malformed rather than letting one bad fragment
            // take the whole lock screen down with it.
            const out = [];
            for (const entry of parsed.layouts) {
                if (!entry || typeof entry.value !== "string" || entry.value.length === 0)
                    continue;
                const meta = root.displayMeta(entry.value);
                out.push({
                    value: entry.value,
                    name: meta.name,
                    icon: meta.icon,
                    fragment: entry.value,
                    align: (entry.align === "left") ? "left" : "center",
                    verticalOffset: (typeof entry.verticalOffset === "number") ? entry.verticalOffset : 0.04,
                    clock: entry.clockVisible !== false,
                    card: entry.card === true,
                    clockScale: (typeof entry.clockScale === "number") ? entry.clockScale : 1.0,
                    hud: entry.hud === true,
                    sheet: entry.sheet === true
                });
            }
            if (out.length === 0)
                return null;
            return {
                active: (typeof parsed.active === "string" && parsed.active.length > 0)
                    ? parsed.active : "classic",
                list: out
            };
        } catch (e) {
            console.warn("LoginLayouts: could not parse the generated index:", e);
            return null;
        }
    }

    // The parsed index, or null while it is unavailable.
    readonly property var indexData: (root.indexGeneration, root.parseIndex())

    // The real list, or null while it is unavailable.
    readonly property var indexList: root.indexData?.list ?? null

    // The template the login screen is showing, straight from the greeter's
    // own composed fragment. This outranks the shell's own record: the
    // settings picker writes Persistent.states.loginLayout, but choosing a
    // layout with set-login-layout.sh updates active.js and nothing else, so
    // the two are independent records of one fact and they drift. The
    // greeter's record is the one that describes what you meet at boot.
    readonly property string sddmActive: root.indexData?.active ?? ""

    // What the shell actually uses. The fallback is intentionally a SUBSET:
    // it is here to keep a lock screen drawable when the generator has not run,
    // not to be a place to edit a template.
    readonly property var list: root.indexList ?? root.fallbackList

    // Only the entries the shell knows how to draw a picker row for, minus
    // anything the fragments describe that the lock cannot render. Kept small
    // on purpose -- see the class comment.
    readonly property var fallbackList: [
        {
            value: "classic", name: Translation.tr("Classic"), icon: "crop_landscape",
            fragment: "classic", align: "center", verticalOffset: 0.04,
            clock: true, card: false, clockScale: 1.0, hud: false, sheet: false
        }
    ]

    // Display chrome for the settings picker. This is NOT in the fragments,
    // and deliberately so: they describe geometry, not UI. Keyed by slug with
    // a derived-name fallback, so adding a template to the login screen costs
    // nothing here -- it just shows up with a capitalised name and a generic
    // icon rather than being missing.
    readonly property var icons: ({
        "beacon": "schedule",
        "classic": "crop_landscape",
        "corner": "north_west",
        "glass": "blur_on",
        "minimal": "minimize",
        "ops": "radar",
        "sheet": "description",
        "studio": "video_label"
    })

    function displayMeta(slug) {
        let name = slug;
        if (name.length > 0)
            name = name.charAt(0).toUpperCase() + name.slice(1);
        return {
            name: Translation.tr(name),
            icon: root.icons[slug] ?? "widgets"
        };
    }

    readonly property var fallback: {
        for (let i = 0; i < root.list.length; ++i) {
            if (root.list[i].value === "classic")
                return root.list[i];
        }
        return root.list[0];
    }

    // Which template is in force.
    //
    // The login screen's own answer wins. `Persistent.states.loginLayout` is
    // still read, but only as a fallback for when the index is unavailable:
    // it is a second record of the same decision, written by the settings
    // picker and NOT by set-login-layout.sh, so trusting it over the greeter
    // is how the lock ended up drawing "classic" while the login drew "sheet".
    // The lock screen's whole job is to look like the login screen, so it
    // follows the login screen.
    readonly property string current: (root.sddmActive.length > 0)
        ? root.sddmActive
        : (Persistent.states.loginLayout || "classic")

    function byValue(value) {
        for (let i = 0; i < root.list.length; ++i) {
            if (root.list[i].value === value)
                return root.list[i];
        }
        return root.fallback;
    }

    readonly property var active: root.byValue(root.current)

    readonly property string align: root.active?.align ?? "center"
    readonly property real offset: root.active?.verticalOffset ?? 0.04
    readonly property bool clockVisible: root.active?.clock ?? true
    readonly property bool card: root.active?.card ?? false
    readonly property real clockScale: root.active?.clockScale ?? 1.0
    readonly property bool hud: root.active?.hud ?? false
    readonly property bool sheet: root.active?.sheet ?? false

    // True when `current` names a template that actually exists. A false here
    // is the drift this file used to have: the login screen picked a layout
    // the lock had never heard of, and the lock quietly drew its fallback
    // instead. The settings page reads it to say so out loud.
    readonly property bool currentKnown: root.indexList !== null
        && root.indexList.some((t) => t.value === root.current)

    // True when the shell's own record disagrees with the greeter's. Not an
    // error -- the picker writes one and the script writes the other -- but it
    // is the exact condition that used to leave the lock drawing a different
    // screen from the login, so it is worth being able to ask about it.
    readonly property bool persistentAgrees: (Persistent.states.loginLayout ?? "") === root.current

    // Index helpers for the HUD's arrow / dot switcher: the dots are one per
    // template and the side arrows step through them.
    function indexOf(value) {
        for (let i = 0; i < root.list.length; ++i)
            if (root.list[i].value === value) return i;
        return 0;
    }
    function cycle(dir) {
        const i = root.indexOf(root.current);
        const n = root.list.length;
        if (n < 2)
            return;
        const next = root.list[((i + dir) % n + n) % n];
        if (!next || next.value === root.current)
            return;
        root.requestLayout(next.value);
    }

    // Apply a template the way the settings picker does, so the greeter's
    // record and the shell's stay in step.
    //
    // These arrows used to assign `current` directly, which was both a write
    // to a read-only property and the very thing that let the lock and the
    // login disagree: only the shell moved, the greeter never heard about
    // it, and the next lock showed a template no login screen had. Going
    // through set-login-layout.sh means `current` (which follows the greeter)
    // changes for the same reason the login does.
    //
    // The greeter itself reads the INSTALLED theme under /usr/share, so the
    // login screen picks the change up at the next rebake or reboot -- that
    // step needs root and belongs to the settings page, not to an arrow. The
    // lock follows immediately, because it reads the fragment.
    function requestLayout(value) {
        Persistent.states.loginLayout = value;
        const script = `${Directories.hyprConfigDir}/custom/scripts/set-login-layout.sh`;
        switchLayout.command = ["bash", "-c",
            `"${script}" '${value}' && "${root.generatorPath}"`];
        switchLayout.running = false;
        switchLayout.running = true;
    }

    readonly property string generatorPath: `${Directories.scriptPath}/login/generate-layout-index.sh`
}



