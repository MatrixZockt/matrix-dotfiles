import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import QtQuick.Controls
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Services.Mpris as MprisSvc
import Quickshell.Io
// For PowerProfiles + the PowerProfile enum: the three-button power-mode row
// in the System tab writes PPD profiles directly (same live handle the quick
// toggles use), so the Razer app is not needed for a profile switch.
import Quickshell.Services.UPower
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.modules.common.flare
import "../../common/widgets" as W
import "../../common/widgets/scrollfling.js" as Fling

/**
 * The middle island, popped out.
 *
 * The only way in: put three fingers on the pad and swipe down, and the
 * island TRANSFORMS OUT into a card of its own -- it starts as the island's
 * own shape in the island's own place and grows out of it, the same view
 * with room to breathe. (Hovering the island does nothing; the retired
 * hover pocket and this card also disarm each other, see BarContent.)
 * While the card is open, the island in the bar grows a hair and takes the
 * accent ring, so the card reads as that island enlarged.
 *
 *   * It hangs under the island, not in the middle of the screen: it is the
 *     island's continuation, and the eye is already there.
 *   * It closes when you press anywhere outside it. That is a
 *     HyprlandFocusGrab on a full-screen transparent layer surface (the same
 *     mechanism the sidebars and the bar's own panels use), so "outside" means
 *     the whole desktop, not just the card's edges.
 *    * It is swappable: two- OR three-finger horizontal swipes, left/right
    * arrows, or the tabs in its header -- all one step per gesture, the
    * same accumulator grammar the island uses -- driving the SAME view
    * state the island uses (GlobalStates.nowBarMode), so the island
    * underneath and the card above can never show different things.
 *
 * The frost behind it comes from the compositor's `quickshell:barPanel` layer
 * rule (custom/rules.lua), which is why the namespace is not its own.
 */
Scope {
    id: root

    // The island in the bar: used to inherit its screen, and to know when the
    // bar exists at all.
    property Item anchorItem: null

    readonly property bool open: GlobalStates.nowBarPanelOpen

    // ── The System tab's sampler claim ───────────────────────────────────
    // The disk and network rows read HardwareStats, which samples only while
    // somebody is looking, so the card has to say when it is. The claim is held
    // by NAME and for exactly as long as the tab is the one on screen (see
    // HardwareStats.setActive), which is what stops this card and the overlay's
    // resource widget from switching each other's sampling off -- the failure a
    // shared boolean made unavoidable once there was more than one reader.
    readonly property bool systemSampling: root.open && root.mode === root.modePerf
    function syncSampling() {
        HardwareStats.setActive("nowBarSystem", root.systemSampling);
    }
    // The change handler alone is not enough: it does not run for the value a
    // property is BORN with, so a card that is already open on the System tab
    // when the shell loads (every reload of this file, and every session that
    // restores the panel) would never register its claim -- the rows would sit
    // at "0 B/s" until the user happened to switch tabs and come back. The
    // registration therefore also happens at startup, from the SINGLE
    // Component.onCompleted this object is allowed to have (see below: a second
    // one is a hard load failure), which is the same pair Resources.qml keeps.
    onSystemSamplingChanged: root.syncSampling()

    readonly property var fallbackScreen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
    property var cardScreen: null

    // ── Geometry ─────────────────────────────────────────────────────────
    // The card's size is fixed; only the ANIMATION interpolates. The motion is
    // a scale around the card's own centre, so it blooms out of the middle of
    // the screen rather than stretching out of one corner.
    // To-do-panel scale: the card must read as a real surface, not a pocket.
    // Width ≈ 760 logical px (the reference's ~62% screen at 2x scale),
    // height ≈ 460 -- large enough for the to-do layout's proportions, capped
    // so it always floats with air on every side.
    // A real surface, not a pocket: wide enough for the media card and the
    // weekly usage grid side by side, tall enough that all four views breathe,
    // and sized off the screen so it always floats with air around it.
    // Back to the 760x460 the comment above already describes. The numbers
    // had drifted to 920x580 -- a 21% wider, 26% taller card than the one the
    // design note describes, which is most of why the System view read as a
    // huge slab with the ledger marooned in the top-left of it. The caps and
    // the fractions are the only things that decide the size; 0.50 of the
    // screen height is what lands on 460 at this display.
    readonly property real cardWidth: Math.min(760, Math.max(520, (panel.width || 1200) - 240))
    readonly property real cardHeight: Math.min(460, Math.max(320, (panel.height || 800) * 0.50))
    readonly property real headerHeight: 34
    readonly property real gap: 8
    readonly property real margin: 24
    readonly property real barY: Appearance.sizes.barHeight
    // Floating center-screen: the pop-out is a temporary enlargement of the
    // island, not a docked card, so it takes the screen's middle.
    readonly property real targetCenterX: Math.max(cardWidth / 2 + margin,
        Math.min((panel.width || 1200) / 2, (panel.width || 1200) - cardWidth / 2 - margin))

    // 0 = closed, 1 = the popped-out card.
    //
    // One driver, one number: the card is always its full size at the screen's
    // centre, and `t` drives only a SCALE around the card's own middle -- so
    // the open is a bloom FROM THE MIDDLE, not a rectangle stretching from a
    // corner. It is also the cheaper render: one surface scaled per frame,
    // instead of width/height/x/y re-laid out on every tick.
    // 340ms in / 200ms out, a third faster than the shell's standard pair: a
    // big surface crossing most of the screen reads as slow at 400ms, and the
    // snappier beat keeps it feeling deliberate rather than heavy.
    //
    // Animated imperatively rather than with a Behavior, because Qt refuses to
    // *change* a Behavior's animation at runtime -- "Cannot change the
    // animation assigned to a Behavior": it warns and silently keeps the first
    // one, so an `open ? enter : exit` binding can only ever produce a single
    // curve for BOTH directions. Picking the pair below is what actually
    // preserves the asymmetry. `from` is left unset so the card can be
    // re-opened mid-retract and carry on from wherever it is.
    property real t: 0
    NumberAnimation {
        id: tAnim
        target: root
        property: "t"
        alwaysRunToEnd: false
    }
    // The panel is normally closed at creation, so the state change above is
    // what animates it. This only matters if the shell starts with it already
    // open: then there is no change to react to, and without this the card
    // would be mapped at zero scale.
    // ALSO publishes the panel state file — there can be only ONE
    // Component.onCompleted per object; a second one is a hard load failure
    // ("Property value set multiple times"), which is exactly what happened
    // when the state publisher declared its own.
    Component.onCompleted: {
        root.t = root.open ? 1 : 0;
        // The change handlers below only fire on a CHANGE, so a card opened
        // while music is already playing would start with no snapshot and show
        // the empty state until the track changed. Seed it here instead.
        if (root.currentPlaylist) {
            root.lastPlaylist = root.currentPlaylist;
            root.lastPlayingPath = root.playingPath;
        }
        root.publishPanelState();
        // The hardware sampler's claim, for a card that is born open on the
        // System tab. Same reason as the seeding above: the change handler is
        // not called for an initial value, and this object gets exactly one
        // Component.onCompleted -- which is why this call lives HERE rather
        // than next to the property it guards.
        root.syncSampling();
    }
    readonly property real k: Math.max(0, Math.min(1, root.t))
    function lerp(a, b, kk) { return a + (b - a) * kk; }

    // Wheel classification, mirrored from NowBar. NOT reachable as
    // `NowBar.wheelDx` from here: NowBar is a page type, not a singleton, so
    // its functions are instance functions and the panel holds no instance --
    // the old calls threw "Property 'wheelDx' of object NowBar is not a
    // function" on every wheel event, which is why panel swipes silently did
    // nothing. Same contract as the island's helpers: dx > 0 means fingers
    // moved right (natural-scroll un-inverted).
    function wheelDx(w, hasPixels) {
        const pd = w.pixelDelta;
        if (hasPixels) return w.inverted ? -pd.x : pd.x;
        return w.angleDelta.x / 120 * 40;
    }
    function wheelDy(w, hasPixels) {
        const pd = w.pixelDelta;
        if (hasPixels) return w.inverted ? -pd.y : pd.y;
        return w.angleDelta.y / 120 * 40;
    }

    // The card itself is FIXED at full size, dead centre, the moment it maps.
    // Everything else about the motion is scale.
    readonly property real cardCX: root.targetCenterX

    // ── The transport glyphs ────────────────────────────────────────────
    // Drawn by `TransportMark` (modules/common/widgets/TransportMark.qml),
    // which is also what the sidebar's music tab uses -- the top bar island's
    // own design, extracted so the two surfaces cannot drift apart. It was an
    // inline `component` here once, and MusicTab.qml kept a hand-copied
    // duplicate of it: two copies of one glyph is two copies that eventually
    // differ.
    //
    // `TransportCluster`, the 28/32/28 wrapper that used to hold all three
    // buttons, is gone with it.

    // ── Where the transport's outer buttons belong ──────────────────────
    //
    // The transport used to align to the MIDDLE ISLAND rather than the card's
    // own edges, via `transportEdgeInset` -- the skips sat hard against the
    // island's painted edge so the expanded card read as that island enlarged.
    // That no longer applies to anything: the skips have moved down to flank
    // the status bar, which is inset by the card's own 26px margin like every
    // other control in the card. So the inset is gone rather than left as a
    // property nothing reads.
    //
    // `nowBarWidth` is the island's width, published by BarContent.qml. Its
    // PAINTED edges are one `windowRounding` in on each side, which is
    // exactly the inset `centerIslandLeft/Right` use in the bar.
    readonly property real islandPaintedWidth: Math.max(0,
        (GlobalStates.nowBarWidth || 0) - 2 * Appearance.rounding.windowRounding)
    readonly property real targetCenterY: Math.max(
        root.barY + root.cardHeight / 2 + root.margin,
        (panel.height || 800) / 2)
    readonly property real cardCY: root.targetCenterY
    // 0 → 1 around the card's own centre (transformOrigin defaults to
    // Item.Center). The OutBack overshoot lands on this too, so the bloom
    // ends with the same tiny settle-bounce as every other shell surface.
    // The card slides DOWN out of the bar; the information slides IN FROM
    // THE RIGHT. Two motions, because they are two different things: the
    // card is a surface dropping from the bar that summoned it, and the
    // content is information arriving.
    //
    // The content slide is the one that matters and the one that was missing.
    // Fading the card as a whole -- whatever moves it -- still reads as
    // "appear", because nothing inside it ever changes position relative to
    // the card. Text has to TRAVEL, and it has to travel along the reading
    // direction: starting 56px to the right of where it rests and settling
    // leftward into place, so the eye follows the words in from the edge.
    //
    // 56, not 40: the column is ~1100px wide and a 40px travel over 380ms is
    // ~105px/s -- below what the eye parses as motion on a large surface. The
    // same reasoning caps the FADE at the first half of the travel: if the
    // text is already fully visible at k=0.4, the remaining 60% of the slide
    // reads as a separate, second motion. Content fully opaque at k=0.55
    // keeps the arrival and the fade braided together.
    // These follow `k` on the way IN, and on every animated way out. The one
    // exit that does not animate -- a desktop switch -- never reaches them: it
    // unmaps the surface outright (see `instantClose`), so there is no frame in
    // which a half-faded card is drawn over a moving desktop.
    readonly property real cardSlideOffset: (1 - root.k) * 40
    readonly property real cardOpacity: Math.min(1, root.k * 2.5)
    // The information's own travel, in the content column's coordinates.
    readonly property real contentSlideOffset: (1 - root.k) * 56
    readonly property real contentOpacity: Math.min(1, root.k / 0.55)

    // ── View state (shared with the island) ──────────────────────────────
    // The SAME ring indices the island uses (NowBar): shared view state
    // means shared numbering, or island and card show different views for
    // the same value.
    readonly property int modePerf: 0
    readonly property int modeMedia: 1
    readonly property int modePomodoro: 2
    readonly property int modeAi: 3
    readonly property int modeTrading: 4
    readonly property int modeCount: 5
    readonly property int mode: GlobalStates.nowBarMode
    function setMode(m) { GlobalStates.nowBarMode = ((m % root.modeCount) + root.modeCount) % root.modeCount; }

    // Does any surface actually want fresh llama.cpp numbers right now?
    //
    // The AI view is a FocusScope whose `visible` is a binding to its own
    // opacity, so `onVisibleChanged` on it never fires -- claiming polling from
    // there left `tabVisible` false with the panel open on the AI tab, and
    // every gated endpoint (/slots, /metrics, nvidia-smi) stayed at zero. So
    // the claim is made from the two conditions that are actually observable:
    // the card is open, and the AI tab is the selected one.
    // A BINDING, not a handler. `onModeChanged`/`onOpenChanged` were both tried
    // and both missed: the mode is a readonly alias onto `GlobalStates`, so a
    // mode change arriving from outside this component (the island's swipe,
    // the `nowbar mode` IPC call) does not reliably reach a handler declared
    // here, and the claim was left stale with the panel open on this tab. A
    // binding on the two facts that matter is re-evaluated whenever either
    // changes, whoever changed it.
    readonly property bool aiWanted: root.open && root.mode === root.modeAi
    onAiWantedChanged: {
        if (root.aiWanted)
            LlamaService.claim("panel");
        else
            LlamaService.release("panel");
    }

    function _syncAiClaim() {
        if (root.aiWanted)
            LlamaService.claim("panel");
        else
            LlamaService.release("panel");
    }

    // ── System-tab helpers (U1 redesign) ────────────────────────────────
    // Live GPU draw, as a number: GpuPower.powerDraw is "4.02 W".
    function gpuWatts() {
        const m = String(GpuPower.powerDraw ?? "").match(/([\d.]+)/);
        return m ? Number(m[1]) : null;
    }

    // ── Local-AI-tab formatting ──────────────────────────────────────────
    // Thousands grouped with SPACES rather than through `toLocaleString`,
    // which on this machine groups with a full stop: 65536 came out as
    // "65.536", which reads as a decimal to anyone who has not internalised
    // the locale. Grouping by hand is unambiguous everywhere and is also how
    // the numbers are written everywhere else on the desktop.
    function fmtCount(n) {
        const s = String(Math.round(Number(n) || 0));
        let out = "";
        for (let i = 0; i < s.length; i++) {
            if (i > 0 && (s.length - i) % 3 === 0)
                out += " ";
            out += s[i];
        }
        return out;
    }

    // Uptime as "12s" / "4m 12s" / "1h 02m" -- the zero-padded middle part is
    // what makes a pair of these scannable when several are on screen.
    function fmtUptime(sec) {
        const t = Math.max(0, Math.floor(Number(sec) || 0));
        if (t < 60)
            return `${t}s`;
        const m = Math.floor(t / 60);
        if (m < 60)
            return `${m}m ${String(t % 60).padStart(2, "0")}s`;
        return `${Math.floor(m / 60)}h ${String(m % 60).padStart(2, "0")}m`;
    }

    // The three numbers that decide what a start actually DOES, as words.
    // `-ngl 99` is llama.cpp's "offload everything" and `0` means "leave the
    // model on the CPU", so neither is a number a reader can do anything
    // with; `-c 65536` is a number, but only once it is grouped.
    function fmtLaunchParam(key) {
        const v = LlamaService.paramValue(key);
        if (key === "ngl") {
            const n = Number(v);
            if (n >= 99)
                return Translation.tr("all layers");
            if (n <= 0)
                return Translation.tr("CPU only");
            return n === 1 ? Translation.tr("1 layer") : Translation.tr("%1 layers").arg(n);
        }
        if (key === "ctx")
            return root.fmtCount(v);
        return String(v);
    }

    // ── Live GPU power cap (enforced limit) ─────────────────────────────
    // The cap is the number the power-mode buttons are really about: 55 W is
    // the vBIOS floor, ~115 W is what nvidia-powerd (Dynamic Boost) lifts the
    // ceiling to. Two sources, one truth, in strict order:
    //   * nvidia-smi's power.limit -- the MEASURED limit, but only readable
    //     while the card is awake; asleep it answers [N/A].
    //   * nvidia-powerd's state -- the cap's actual mechanism on this
    //     machine: daemon active = ceiling lifted, inactive = vBIOS floor.
    //     Readable even while the card sleeps.
    // The readout never invents a number and never parrots a stale one: every
    // displayed change is the result of a fresh query that said so.
    property real gpuCapW: 0               // 0 = no nvidia-smi reading this tick
    property bool gpuCapMeasured: false    // this tick had a real nvidia-smi number
    property bool gpuCapBoosted: false     // nvidia-powerd active (the ceiling is lifted)
    property bool gpuCapFlash: false       // brief highlight when the cap truly moves
    // A mode change is not instant: systemctl answers in ~100 ms, the daemon
    // then settles the new ceiling, and only a fresh query can prove it. While
    // that dance runs, the row locks and says so. The lock is UX, not safety:
    // power-limit changes are a supported, continuous operation (the card moves
    // its own targets under Dynamic Boost all the time), so there is nothing to
    // protect the hardware from -- but a burst of clicks would leave the
    // displayed cap guessing, and a guess is exactly what this row never does.
    property bool modeApplying: false
    property int applyingModeValue: -1
    // What `powerMode`/`setPowerMode` report: the mode the machine is actually
    // on (read off PPD), the mode the shell's config holds, and whether this
    // machine offers a Performance profile at all. A function on root, because
    // the IPC handler's functions are NOT properties of `root` -- calling
    // `root.powerMode()` from `setPowerMode` threw "Property 'powerMode' ... is
    // not a function" on every press.
    //
    // It also reports the NOTICE's record (PowerMode.lastChange and its
    // counter), which is what the mode-switch card prints. That record lives in
    // the power service, and the service cannot carry an IpcHandler of its own
    // -- adding one there failed the whole singleton at load ("IpcHandler is
    // not a type") and took every service importing it down with it. The panel
    // already has a working handler, and the buttons that drive a switch live
    // here, so the probe belongs here anyway.
    function powerModeText() {
        const c = PowerMode.lastChange;
        const last = c
            ? `${c.from}->${c.to} profileBefore=${c.profileBefore}`
            : "none";
        return `mode=${PowerMode.modeFor(PowerProfiles.profile)} `
             + `config=${Config.options?.battery?.powerMode ?? "?"} `
             + `perfAvailable=${PowerProfiles.hasPerformanceProfile}`
             + ` armed=${PowerMode.armed} seq=${PowerMode.changeSeq} last=${last}`;
    }
    function applyMode(p) {
        if (root.modeApplying)
            return;
        root.modeApplying = true;
        root.applyingModeValue = p;
        // Record the choice as the CONFIG value, not only as a PPD write.
        //
        // THIS IS THE "it jumps back to power saving" BUG. PowerMode re-asserts
        // Config.battery.powerMode, so a profile applied here without writing
        // that key was put back on its own within the minute: press
        // Performance, get power-saver a minute later, with nothing on screen
        // to explain it. The key is the single source of truth -- the settings
        // page, the Razer chips and PowerMode.load() all go through it -- and
        // this card now writes it on the way in.
        const mode = PowerMode.modeFor(p);
        if (Config.options?.battery && Config.options.battery.powerMode !== mode)
            Config.options.battery.powerMode = mode;
        // Applied directly as well, because `onCurrentChanged` only fires on an
        // actual CHANGE: re-picking the mode the config already holds (to
        // re-assert PPD after something else moved it) has to still take.
        PowerProfiles.profile = p;
        root.setPowerd(p === PowerProfile.Performance ? "start" : "stop");
        root.queryGpuCap();
        gpuCapRequery.restart();   // the fresh answer, after the daemon settles
        applyDoneTimer.restart();  // and the end of the applying state
    }
    function applyGpuCap(raw) {
        // stdout line 1: nvidia-smi limit ("115.00" or "N/A"); line 2: is-active
        const lines = String(raw ?? "").split("\n").map(s => s.trim()).filter(s => s.length > 0);
        const m = (lines[0] ?? "").match(/([\d.]+)/);
        const prevW = root.gpuCapW;
        const prevBoost = root.gpuCapBoosted;
        root.gpuCapMeasured = !!m;
        root.gpuCapW = m ? parseFloat(m[1]) : 0;
        root.gpuCapBoosted = (lines[1] ?? "") === "active";
        // Pulse only on a REAL move of the cap's meaning -- measured watts
        // changed, or the mechanism (boost on/off) flipped while asleep.
        const changed = (m && Math.round(root.gpuCapW) !== Math.round(prevW))
            || (!m && prevBoost !== root.gpuCapBoosted);
        if (changed) {
            root.gpuCapFlash = true;
            gpuCapFlashTimer.restart();
        }
    }
    function queryGpuCap() { gpuCapQuery.running = true; }
    Process {
        id: gpuCapQuery
        command: ["sh", "-c",
            "nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null; " +
            "systemctl is-active nvidia-powerd.service 2>/dev/null"]
        stdout: StdioCollector { onStreamFinished: root.applyGpuCap(this.text) }
    }
    // Buttons ask the daemon to follow the cap policy. Needs a polkit
    // allowance for the user; without one systemctl denies it, the Process
    // exits non-zero, and the readout below honestly does not move.
    Process { id: powerdCtl; command: ["true"] }
    function setPowerd(action) {
        powerdCtl.command = ["systemctl", action, "nvidia-powerd.service"];
        powerdCtl.running = true;
    }
    Timer {
        id: gpuCapFlashTimer
        interval: 900; repeat: false; running: false
        onTriggered: root.gpuCapFlash = false
    }
    // Whole-chip temperature: Package id 0 first, else the hottest core.
    function cpuPackageTemp() {
        const ts = SystemFacts.temperatures ?? [];
        const pkg = ts.find(t => t.chip === "coretemp" && /package/i.test(t.label ?? ""));
        if (pkg) return Math.round(pkg.celsius);
        const cores = ts.filter(t => t.chip === "coretemp");
        if (cores.length > 0) return Math.round(Math.max(...cores.map(t => t.celsius)));
        return null;
    }
    // The dGPU, named for humans when the vendor is certain.
    function gpuDisplayName() {
        const g = (SystemFacts.gpus ?? []).find(g => g.driver === "nvidia");
        if (!g) return Translation.tr("Graphics");
        return /10DE/i.test(g.vendorId ?? "") ? "RTX 4070" : (g.name || Translation.tr("Graphics"));
    }
    // CPU model, trimmed of the vendor prefix and any "@ speed" tail.
    function cpuDisplayName() {
        const m = SystemFacts.cpu.model ?? "";
        return m.replace(/^Intel\(R\)\s*/, "").replace(/\s*CPU\s*@.*$/, "").trim();
    }
    function formatKB1(kb) {
        return (kb / (1024 * 1024)).toFixed(1);
    }

    // ── Tab transition: the island's ring-slide, on the panel card ──────
    // Same grammar as NowBar.qml's FadeView: views sit at x offsets measured
    // in RING steps (3 -> 0 crosses the seam by one width, never rewinds),
    // the incoming view springs in with a hair of overshoot, the outgoing one
    // leaves flat, and both crossfade under the slide. Swipe two tabs and the
    // pair travels two widths in one motion.
    function ringStepsTo(to, from) {
        const n = root.modeCount;
        let d = (to - from) % n;
        if (d > n / 2) d -= n;
        if (d < -n / 2) d += n;
        return d;
    }
    readonly property real viewSwooshGap: 26

    // The panel's own FadeView: same animations, sized for the card.
    component PanelFadeView: FocusScope {
        id: pfv
        property bool on: false
        property int viewIndex: 0
        readonly property int steps: root.ringStepsTo(pfv.viewIndex, root.mode)
        visible: opacity > 0.01
        opacity: on ? 1 : 0
        scale: on ? 1 : 0.97
        anchors.fill: parent
        x: (pfv.steps) * (parent.width + root.viewSwooshGap)
        Behavior on x {
            NumberAnimation {
                duration: pfv.on ? 340 : 200
                easing.type: pfv.on ? Easing.OutBack : Easing.OutCubic
                easing.overshoot: 1.14
            }
        }
        Behavior on opacity {
            NumberAnimation {
                duration: pfv.on
                    ? Appearance.animation.elementMoveEnter.duration
                    : Appearance.animation.elementMoveExit.duration
                easing.type: pfv.on
                    ? Appearance.animation.elementMoveEnter.type
                    : Appearance.animation.elementMoveExit.type
                easing.bezierCurve: pfv.on
                    ? Appearance.animation.elementMoveEnter.bezierCurve
                    : Appearance.animation.elementMoveExit.bezierCurve
            }
        }
        Behavior on scale { animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(pfv) }
    }

    // ── Horizontal swipe over the PANEL: one gesture, one implementation ──
    //
    // These live on the Scope, not on the MouseArea, because the handler is
    // called from TWO places (the panel margins and the card itself) and a
    // gesture that crossed between them must not restart. Two accumulators
    // would let one physical swipe fire two steps.
    //
    // Why there are two callers at all: Qt delivers a wheel event to the item
    // under the cursor and then walks its PARENT chain. It never reaches a
    // SIBLING. `panelSwipeArea` and `card` are both children of `panel`, so a
    // swipe over the card could never reach the swipe area -- which is why the
    // gesture used to work only in the strip of empty panel above the card and
    // nowhere else. The fix is not to move the card (that would steal the
    // card's own clicks) but to give the card the same handler.
    // The scroller the view on screen wants a two-finger vertical gesture to
    // drive, published by the VIEW itself (see TradingTab.publishScrollTarget)
    // and null when that view is not showing. The card's swipe overlay is the
    // only item that ever sees a wheel over the card -- Qt delivers to the item
    // under the cursor and then walks its PARENT chain, never a sibling -- so a
    // scroller inside a view is unreachable unless the view hands it over.
    // The music tracklist stays the fallback below (it has no claim to make:
    // it is the card's default scroller), and its own `visible` still gates it.
    property var cardScrollTarget: null
    property real panelAccX: 0
    property real panelAccY: 0
    property bool panelSwipeHorizontal: false
    // The vertical half of the axis decision. Without it the card only ever
    // knew "horizontal", so it could not stop early on a gesture that is
    // really a scroll -- the island and the sidebar both decide both ways.
    property bool panelSwipeVertical: false
    property bool panelSwipeFired: false
    function resetPanelSwipe() {
        root.panelAccX = 0;
        root.panelAccY = 0;
        root.panelSwipeHorizontal = false;
        root.panelSwipeVertical = false;
        root.panelSwipeFired = false;
    }
    // The island's accumulator grammar: a swipe arrives as a BURST of wheel
    // events, so per-event stepping would walk one gesture through several
    // views. Pixels pile up, horizontal must win by a real margin before the
    // gesture means anything, ONE threshold crossing fires ONE step, and the
    // accumulator resets 180ms after the fingers stop.
    function handlePanelWheel(wheel) {
        const pd = wheel.pixelDelta;
        const hasPixels = pd && (pd.x !== 0 || pd.y !== 0);
        const deviceType = wheel.device?.type;
        const isTouchpad = (deviceType !== undefined)
            ? deviceType === PointerDevice.TouchPad
            : hasPixels;
        if (!isTouchpad) {
            // A real wheel: one notch, one step, no accumulation.
            const dx = wheel.angleDelta.x !== 0 ? wheel.angleDelta.x : wheel.angleDelta.y;
            if (dx === 0) return;
            if (dx > 0) root.setMode(root.mode + 1); else root.setMode(root.mode - 1);
            wheel.accepted = true;
            return;
        }
        const dx = root.wheelDx(wheel, hasPixels);
        const dy = root.wheelDy(wheel, hasPixels);
        // A frame with NO movement at all is the pad reporting lift-off, not a
        // gesture. It must not touch the accumulators and must not restart the
        // gesture timer: the zero frames trailing one flick used to keep the
        // PREVIOUS gesture's lock alive, so a fast follow-up swipe inherited
        // `panelSwipeFired` and was silently dropped. The island and the
        // sidebar both ignore these frames for the same reason.
        if (!hasPixels && dx === 0 && dy === 0) {
            wheel.accepted = true;
            return;
        }
        root.panelAccX += Math.abs(dx);
        root.panelAccY += Math.abs(dy);
        swipeReset.restart();
        // ONE AXIS PER GESTURE, decided once and then held -- the sidebar's
        // grammar, and now the island's. Both distance floors are GONE: the
        // card used to need 12px to arm and 40px to fire, and on a pad that
        // delivers ~10px per event that is several frames of the view sitting
        // still while the fingers are already moving. The ratio does the
        // protecting instead, and guessing the axis wrong costs one view,
        // whereas waiting costs a gesture that never answers.
        if (!root.panelSwipeHorizontal && !root.panelSwipeVertical) {
            const ax = root.panelAccX;
            const ay = root.panelAccY;
            if (ay > 0 && ay >= ax * 2.0)
                root.panelSwipeVertical = true;
            else if (ax > 0 && ax >= ay * 2.0)
                root.panelSwipeHorizontal = true;
            else if (ax > ay * 1.05)
                root.panelSwipeHorizontal = true;
            else if (ay > 0)
                root.panelSwipeVertical = true;
        }
        if (!root.panelSwipeHorizontal || root.panelSwipeFired)
            return;
        // Fingers right = NEXT view, the shared convention (island, card,
        // sidebar and the old compositor binds all agreed).
        root.setMode(root.mode + (dx > 0 ? 1 : -1));
        root.panelSwipeFired = true;
        wheel.accepted = true;
    }

    // System first, on request: the machine's own numbers are the tab people
    // reach for most, so it leads the row. The chip order is VISUAL only --
    // the views themselves keep their ring order (see modePomodoro..), so
    // swiping still cycles them the same way it always did.
    readonly property var tabs: [
        { m: root.modePerf, label: Translation.tr("System"), icon: "monitor_heart" },
        { m: root.modeMedia, label: Translation.tr("Playing"), icon: "graphic_eq" },
        { m: root.modePomodoro, label: Translation.tr("Clock"), icon: "schedule" },
        { m: root.modeAi, label: Translation.tr("Local AI"), icon: "memory" },
        { m: root.modeTrading, label: Translation.tr("Trading"), icon: "candlestick_chart" }
    ]
    // ── The timer's own length editor ──────────────────────────────────
    //
    // The length is edited ON the timer's digits, in the pomodoro half. It
    // used to be edited from the wall clock on the left, which replaced the
    // time with a separate minutes field: the clock -- a thing you look at to
    // know what time it is -- became a form field, and the thing you actually
    // wanted to change sat on the other side of the card, untouched. So the
    // digits you read are the digits you type, and the clock is only ever a
    // clock.
    //
    // Hours are editable for the same reason the display carries them: a
    // focus length of 90 minutes is a normal thing to want, and M:SS cannot
    // even name it (it reads "90:00", which is indistinguishable from an
    // hour and a half and from a typo).
    property bool timerEditing: false

    // ── How the card last went away, and when ──────────────────────────
    //
    // The card has five ways out (a press on the veil, Escape, the close
    // shortcut, a press that the compositor's grab reads as "outside", and a
    // desktop switch) and from the outside they are indistinguishable: a card
    // that will not close looks the same whichever one is broken. So the one
    // that fired is recorded here and reported by `state()`, which is the
    // difference between "Escape does nothing" being a guess and being a
    // reading.
    property string lastClose: ""
    property double lastCloseAt: 0
    function noteClose(reason) {
        root.lastClose = String(reason ?? "");
        root.lastCloseAt = Date.now();
    }
    // Whether the press reached the veil at all, and where. "A press outside
    // does nothing" and "the press never arrived" are the same screenshot and
    // two completely different bugs -- one is this file, the other is the
    // compositor's delivery -- so the veil counts what actually lands on it.
    property int veilPresses: 0
    property var veilPressPos: null

    // The countdown you READ. The formatter itself is DateTime.duration --
    // the same one the island's clock view uses, so a 90 minute timer cannot
    // read "1:30:00" in this card and "90:00" in the bar beside it. The editor
    // below writes into three separate boxes rather than a string, so this is
    // not what you type into.

    // What the editor opens on: the whole lap, not the time remaining. Editing
    // the remaining seconds would be a countdown you are trying to extend,
    // which is a different operation with different arithmetic; editing the
    // LENGTH is what "set a 45 minute timer" means, and the reset that
    // applying it performs is the honest result of "I want a 45 minute lap".
    function beginTimerEdit() {
        // Seed each box from the current lap, leaving a unit BLANK when it is
        // zero. A blank box and a "0" are the same length, but blank means
        // "not part of this value": opening a 25 minute timer shows "25" and
        // an empty seconds box, and the first digit typed lands in seconds --
        // which is where a correction of "25:07" belongs.
        const s = Math.max(0, Math.floor(TimerService.pomodoroLapDuration));
        hoursBox.text = s >= 3600 ? String(Math.floor(s / 3600)) : "";
        const m = Math.floor((s % 3600) / 60);
        const ss = s % 60;
        minutesBox.text = m > 0 ? String(m) : "";
        secondsBox.text = ss > 0 ? String(ss) : "";
        root.timerEditing = true;
        hoursBox.forceActiveFocus();
        hoursBox.selectAll();
    }
    function cancelTimerEdit() {
        root.timerEditing = false;
        panelKeyCatcher.forceActiveFocus();
    }
    function commitTimerEdit() {
        if (root.timerEditing) {
            // Each box is a UNIT, so each is clamped to what that unit can
            // hold rather than being allowed to roll into the next one: 75 in
            // the minutes box is not 75 minutes, it is a number the box cannot
            // express, and silently carrying it into the seconds column would
            // hide the mistake.
            const h = Math.min(23, parseInt(hoursBox.text || "0", 10) || 0);
            const m = Math.min(59, parseInt(minutesBox.text || "0", 10) || 0);
            const s = Math.min(59, parseInt(secondsBox.text || "0", 10) || 0);
            const secs = h * 3600 + m * 60 + s;
            if (secs > 0) {
                // setPomodoroFocus persists the length and resets (which also
                // stops any ringing alarm). The fresh lap is NOT started here:
                // a length you typed is a length you meant to run, but whether
                // it should start counting this instant is a separate
                // decision, and the play button is right there for it. (The
                // old clock editor started it unconditionally, which meant
                // every correction of a typo also started the timer.)
                TimerService.setPomodoroFocus(secs);
            }
        }
        root.timerEditing = false;
        panelKeyCatcher.forceActiveFocus();
    }

    // A digit landed in a box. This is the whole passcode behaviour:
    //
    //   * one digit too many -> the OLDEST digit is dropped, so the value
    //     substitutes one digit at a time (a 4 becomes a 7 in one keystroke,
    //     instead of four backspaces). The input is allowed to hold max+1
    //     characters precisely so this case is reachable -- with
    //     maximumLength set to max, the keystroke that should substitute is
    //     the one keystroke the input refuses.
    //   * the box is full -> focus moves on BY ITSELF, with the next box
    //     selected, so the digit after that substitutes there too.
    //   * the last box is full -> the value is complete, so it is applied.
    //     Nothing else is left to type, and waiting for an Enter that the user
    //     does not know to press is how a half-finished edit gets abandoned.
    function boxTyped(box, next, max) {
        if (box.text.length > max)
            box.text = box.text.slice(box.text.length - max);
        if (box.text.length < max)
            return;
        if (next) {
            next.forceActiveFocus();
            next.selectAll();
        } else {
            root.commitTimerEdit();
        }
    }

    // Keys that are about MOVING between boxes rather than typing into one.
    // Backspace on an empty box steps back and selects what is there, so the
    // next backspace clears it -- two presses to delete a unit, which is
    // forgiving in the right direction: one press never destroys digits.
    function boxKey(event, box, prev, next, max) {
        if (event.key === Qt.Key_Backspace) {
            if (box.text === "" && prev) {
                prev.forceActiveFocus();
                prev.selectAll();
                event.accepted = true;
            }
            return;
        }
        if (event.key === Qt.Key_Left && prev) {
            prev.forceActiveFocus();
            prev.selectAll();
            event.accepted = true;
        } else if (event.key === Qt.Key_Right && next) {
            next.forceActiveFocus();
            next.selectAll();
            event.accepted = true;
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.commitTimerEdit();
            event.accepted = true;
        }
    }

    function bestTab() {
        // What should be on screen when the panel opens: whatever the island
        // was showing, except that an idle AI view is less interesting than a
        // live machine -- so the panel opens on the busiest thing there is.
        if (MprisController.activePlayer?.isPlaying ?? false) return root.modeMedia;
        if (TimerService.pomodoroRunning) return root.modePomodoro;
        return root.mode;
    }

    // An IPC handle, because there was no other way to open this card from
    // outside the pointer. The `nowbar` target only exposes modeNext/next/
    // prev/mode, so every `qs ipc call nowbar panel true` used to fail with
    // "Function not found" -- into /dev/null, where it read as success. That
    // is why the card could not be screenshotted for verification: it was
    // never actually open, and the capture was of a closed panel.
    IpcHandler {
        target: "nowbarPanel"
        function open(): void { GlobalStates.nowBarPanelOpen = true; }
        function close(): void { root.close("ipc"); }

        // What the card is doing right now, and how it last went away. The
        // dismissal paths are indistinguishable from outside the shell -- a
        // card that will not close looks the same whichever one is broken -- so
        // this reports them rather than leaving them to be argued about:
        //
        //   qs -c ii ipc call nowbarPanel state
        function state(): string {
            return JSON.stringify({
                open: root.open,
                visible: panel.visible,
                // The surface's real geometry. It is the ONE number that decides
                // whether "a press outside the card" includes the bar strip, so
                // it is read back rather than assumed from the anchors.
                panelX: panel.x, panelY: panel.y, panelW: panel.width, panelH: panel.height,
                // Where the veil and the card actually ARE. The veil is the only
                // thing that dismisses on a press, so a "click outside does
                // nothing" report is really a question about these two rects --
                // and a veil that is a fraction of the surface, or a card larger
                // than it looks, is invisible in the source and obvious here.
                veil: (() => {
                    const p = panelSwipeArea.mapToItem(null, 0, 0);
                    return [Math.round(p.x), Math.round(p.y),
                            Math.round(panelSwipeArea.width), Math.round(panelSwipeArea.height)];
                })(),
                card: (() => {
                    const p = card.mapToItem(null, 0, 0);
                    return [Math.round(p.x), Math.round(p.y),
                            Math.round(card.width), Math.round(card.height)];
                })(),
                t: Math.round(root.t * 100) / 100,
                mode: root.mode,
                timerEditing: root.timerEditing,
                veilPresses: root.veilPresses,
                veilPressPos: root.veilPressPos,
                lastClose: root.lastClose,
                lastCloseAgo: root.lastCloseAt > 0 ? Date.now() - root.lastCloseAt : null
            });
        }
        function toggle(): void { GlobalStates.nowBarPanelOpen = !GlobalStates.nowBarPanelOpen; }
        function setMode(m: int): void { root.setMode(m); }

        // The desktop-swipe takeover, driven without a touchpad. A swipe is the
        // one exit that happens while the screen is moving, so it is also the
        // one that can only be judged by what the card does at the START of a
        // gesture -- and a hand cannot be put on the pad from a script. This
        // feeds the SHIPPED predicate and the SHIPPED exit the four numbers the
        // tracker itself reports, so what it exercises is the real path:
        //
        //   qs -c ii ipc call nowbarPanel swipeProbe 4 2 0.12 0.01
        //   qs -c ii ipc call nowbarPanel swipeProbe 2 2 0.03 0.001
        //
        // (fingers, start, htotal, total): the live count, the count the
        // gesture began with, and the sideways/vertical travel.
        // `at` is the instant of the decision, and it is the number the check
        // measures against: the compositor says when the surface actually
        // left (`closelayer`), and the gap between the two is what the eye
        // sees -- an exit animation, a forked read, or one frame.
        function swipeProbe(fingers: int, start: int, htotal: real, total: real): string {
            const take = root.desktopSwipe(fingers, start, htotal, total);
            if (take && (root.open || root.t > 0.001)) {
                root.close("desktop switch");
                root.startTransition();
            }
            return `take=${take} open=${root.open} t=${Math.round(root.t * 100) / 100} at=${Date.now()}`;
        }

        // Scriptable access to the power-mode buttons, so what a press of one
        // of them does can be driven and read back without a pointer:
        //
        //   qs -c ii ipc call nowbarPanel powerMode
        //   qs -c ii ipc call nowbarPanel setPowerMode performance
        //
        // `setPowerMode` goes through `applyMode` -- the same call the three
        // buttons make -- so what a probe exercises is the real path and not a
        // copy of it. It reports the mode key, which is the thing that has to
        // agree with the config for the choice to survive; PPD alone is not
        // enough (the shell re-asserts the config value).
        function powerMode(): string {
            return root.powerModeText();
        }
        function setPowerMode(mode: string): string {
            root.applyMode(PowerMode.profileFor(mode));
            return root.powerModeText();
        }

        // The transport's real geometry, read rather than assumed. The
        // island-relative inset is arithmetic on a value published by another
        // file, and when it silently fell back to 0 the skips sat at the
        // CARD's content edge instead of the island's -- which looks close
        // enough to pass for working. This is how that gets caught.
        function transport(): string {
            // The transport used to be a `TransportCluster` that published its
            // own geometry, and this probe read it from there. That cluster is
            // gone: the skips now flank the status bar and play sits on the
            // title row, all three as plain `TransportMark`s. So the probe
            // measures them directly -- the same measurement, taken from the
            // one place the surfaces draw it, which is the only way it can
            // compare them.
            const prev = panelSkipPrev;
            const bar = panelMergedBar;
            const next = panelSkipNext;
            const play = panelPlay;
            return `islandW=${root.islandPaintedWidth.toFixed(1)}`
                + ` nowBarW=${(GlobalStates.nowBarWidth || 0).toFixed(1)}`
                + ` | prev x=${prev.x.toFixed(1)}..${(prev.x + prev.width).toFixed(1)} w=${prev.width.toFixed(1)}`
                + ` bar x=${bar.x.toFixed(1)}..${(bar.x + bar.width).toFixed(1)} w=${bar.width.toFixed(1)} h=${bar.height.toFixed(1)}`
                + ` next x=${next.x.toFixed(1)}..${(next.x + next.width).toFixed(1)} w=${next.width.toFixed(1)}`
                + ` playOnTitleRow=${play.width.toFixed(1)}x${play.height.toFixed(1)}`
                // The hero's height is the number that decides how much
                // playlist is left, so it is measured rather than assumed: a
                // hero that quietly regains 80px of nothing looks identical
                // in the source and obvious on screen.
                + ` | heroH=${panelHeroRow.height.toFixed(1)}`
                // Measured with mapToItem on purpose. Reading `y`/`height`
                // off nested layouts mixes coordinate spaces and, worse, reads
                // whatever the last layout pass left there -- which is how the
                // first attempt at this reported a child at y=71 inside a
                // 56px parent. This is all one space, painted.
                + (() => {
                    const rowTop = panelHeroRow.mapToItem(null, 0, 0).y;
                    const rowBot = rowTop + panelHeroRow.height;
                    const barTop = panelMergedBar.mapToItem(null, 0, 0).y;
                    const barBot = barTop + panelMergedBar.height;
                    return ` identH=${panelHeroText.height.toFixed(1)}`
                        + ` rowTop=${rowTop.toFixed(1)} rowBot=${rowBot.toFixed(1)}`
                        + ` barTop=${barTop.toFixed(1)} barBot=${barBot.toFixed(1)}`
                        + ` BAND=${(barBot - rowTop).toFixed(1)}`
                        + ` gapRowBar=${(barTop - rowBot).toFixed(1)}`;
                })()
                + ` cover=${panelHeroCover.width.toFixed(0)}x${panelHeroCover.height.toFixed(0)}`
                + ` seekable=${root.seekable}`;
        }

        // What the merged sound + music bar is being driven by.
        //
        // This used to probe a standalone `pillBar` and a `modeRow`; both are
        // gone, folded into `SpectrumSeekBar`. The capability half of the
        // report is unchanged and still the point -- whether the board is on
        // screen depends on MPRIS capability flags AND on there being bands
        // to draw, and BOTH can be false while everything looks fine, which is
        // the failure this probe was added for.
        function soundProbe(): string {
            const sp = MprisController.shownPlayer;
            const pts = AudioVisualizer.points;
            // NOT `Array.isArray(pts) ? pts.length : 0`: a `property list<real>`
            // hands JS a QML list, not a JS Array, so that test is FALSE and the
            // probe reported bands=0 on every reading of a perfectly healthy
            // pipeline. It read as "the visualiser is dead" for the whole time
            // it was being used to diagnose the visualiser.
            const n = pts.length ?? 0;
            // What a full bar would look like right now, without needing a
            // track to be playing to find out.
            const loudest = n > 0 ? Math.max(...pts) : 0;
            return `mode=${root.mode} panelOpen=${root.open}`
                + ` || mergedVisible=${panelMergedBar.visible}`
                + ` merged=${panelMergedBar.width.toFixed(0)}x${panelMergedBar.height.toFixed(0)}`
                + ` barsH=${panelMergedBar.height.toFixed(0)}`
                + ` volume=${(panelMergedBar.volume).toFixed(3)}`
                + ` || shown=${sp?.identity ?? "null"}`
                + ` volume=${(sp?.volume ?? -1).toFixed(3)}`
                + ` volumeSupported=${sp?.volumeSupported}`
                + ` canControl=${sp?.canControl}`
                + ` isPlaying=${sp?.isPlaying}`
                + ` shuffleSupported=${sp?.shuffleSupported}`
                + ` || active=${MprisController.activePlayer?.identity ?? "null"}`
                + ` activeVolSupported=${MprisController.activePlayer?.volumeSupported}`
                + ` canChangeVolume=${MprisController.canChangeVolume}`
                + ` || bands=${n} loudest=${loudest.toFixed(0)}`
                // `warming`, not `warm`: `warm` is the FUNCTION, so it is always truthy and
                // this printed "warm=yes" on every single reading -- including
                // the ones taken with the pipeline dead, which is precisely
                // when the answer mattered.
                + ` warming=${AudioVisualizer.warming ? "yes" : "no"}`
                + ` wanted=${AudioVisualizer.wanted}`;
        }

        // Reports what the scrubber is actually being driven by. The bug this
        // was added for was invisible from the outside -- the bar looked
        // plausible, it was simply frozen -- so there was no way to tell a
        // correct position from a stale one without watching it for a minute.
        // `mprisPos` is the raw MPRIS value, `pos` is the interpolated one the
        // bar uses: if the first is stuck and the second is moving, the
        // interpolation is doing its job.
        function scrubberProbe(): string {
            const len = MprisController.shownPlayer?.length ?? 0;
            const mpris = MprisController.shownPlayer?.position ?? 0;
            return `len=${Math.round(len)}s mprisPos=${mpris.toFixed(1)}s`
                + ` interpolated=${root.position.toFixed(1)}s`
                + ` progress=${(root.progress * 100).toFixed(1)}%`
                + ` playing=${MprisController.shownPlayer?.isPlaying ?? false}`
                + ` seekable=${root.seekable}`
                // Which position source is in use, and why. `localMatch=false`
                // means the bar is interpolating a cached MPRIS value, which
                // is the source that cannot survive a seek -- so this pair is
                // the first thing to read when a seek looks like it did
                // nothing.
                + ` | localMatch=${root.localMatch}`
                + ` mpDuration=${MusicPlayer.duration.toFixed(1)}`
                + ` mpPos=${MusicPlayer.position.toFixed(1)}`
                + ` mpHasTrack=${MusicPlayer.hasTrack}`
                + ` scrubbing=${root.scrubbing}`
                + ` left="${root.timeLeft()}" clock="${root.clock(root.displayPosition)}"`;
        }

        // Seeks without a pointer, so the seek path can be measured at all.
        // A real drag cannot be driven from a script, which is exactly how the
        // last bug in this area survived: the position code looked right and
        // was never actually exercised end to end.
        function seekProbe(fraction: real): string {
            const before = root.position;
            root.seekToFraction(fraction);
            return `seek ${fraction} from ${before.toFixed(1)}s`
                + ` base=${root._posBase.toFixed(1)}s`
                + ` seekable=${root.seekable}`;
        }
    }

    // ── The exit a desktop switch gets: none at all ──────────────────────
    //
    // Switching desktop is not a dismissal of this card -- it is the whole
    // context the card describes going away -- and it is closed from outside
    // the card (GlobalStates, plus the workspace handler below). What that exit
    // may NOT be is an animation, and that is a measurement, not a taste:
    //
    //   * this surface is the WHOLE OUTPUT, on the Overlay layer
    //     (`exclusiveZone: -1`, all four anchors), and the compositor blurs it
    //     (`layer_rule { blur = true }` on `quickshell:barPanel`,
    //     custom/rules.lua). Laid over a desktop that is sliding, that is a
    //     full-screen blurred snapshot of the desktop being LEFT, re-blurred
    //     on every frame of the switch -- which is the visible glitch (a still,
    //     foggy sheet over moving content) and its cost.
    //
    //   * measured per switch, one switch per reading, against the shell's own
    //     tick instrument (`qs -c ii ipc call bar swipeDiag`, where `tickMax`
    //     is the event loop's worst lateness in ms):
    //
    //       card shut    tickMax  51-69ms
    //       card open    tickMax  64-130ms, with the stalls landing in the
    //                              switch's own window (~500ms after the reset)
    //
    // An exit animation is 120ms of exactly those two things, spent on a card
    // nobody can read while the desktop underneath is moving. So a desktop
    // switch gets NO animation: the card is unmapped in the same frame the
    // switch arrives, and the switch's own animation is the entire transition.
    //
    // The other four ways out keep the expressive retract: a press on the
    // veil, Escape, the close shortcut and the chevron are all deliberate
    // dismissals of a card that was being read, and a card leaving the screen
    // backwards is the right answer to a press. Only a change of desktop is
    // not a dismissal -- and it is the one exit with something else on screen
    // competing for the same frames.
    property bool instantClose: false

    // ── The transition, in one place ────────────────────────────────────
    //
    // Called by the state change, and again by the desktop switch below --
    // which has to be able to RE-TARGET an exit that has already begun, because
    // it cannot know whether GlobalStates closed this card before its own
    // handler ran. `alwaysRunToEnd: false` makes the second call a re-target
    // rather than a queue.
    function startTransition() {
        // A desktop switch: no animation, no frames. `t` goes to 0 in one write,
        // and the surface's own `visible` binding (`open || t > 0.01`) releases
        // it in the same frame -- so the compositor has no blurred full-screen
        // layer to re-composite while the desktops slide, and the shell has no
        // animation to run. Stopping the runner FIRST is what makes this
        // instant even when it interrupts an open that is still travelling:
        // without the stop, the running animation would keep writing `t` and
        // paint the very frames this exists to avoid.
        //
        // See the `instantClose` note above for the measurements behind it.
        if (!root.open && root.instantClose) {
            tAnim.stop();
            root.t = 0;
            return;
        }
        // 200 in / 130 out.
        //
        // It was 380 in, and that is what "slow paced" was. The duration was
        // not the whole story, though -- the CURVE was the bigger half.
        //
        // `elementMoveEnter` is `emphasizedDecel` = [0.05, 0.7, 0.1, 1],
        // which front-loads almost the entire move into the first fifth of the
        // run. Over 380ms that means:
        //
        //    38ms   content fully opaque, 21px of the 56px slide left
        //    95ms   9px left
        //   228ms   1.6px left
        //   380ms   done
        //
        // So the card LOOKED finished at about a quarter of a second and then
        // sat there drifting the last 21px for another 300ms at ~60px/s. No
        // fade was still running to explain the wait -- it was pure creep, and
        // a slow drift reads as hesitation, not as weight. Shortening the
        // duration alone would not have fixed it: the same curve at 200ms
        // still spends its last 100ms moving under 2px.
        //
        // `standard` = [0.2, 0, 0, 1] spreads the motion across the whole run
        // instead. Over 200ms the slide now travels 54px -> 26px -> 6px -> 0,
        // so the last pixel of movement happens at the same rate as the first,
        // and the card arrives rather than settles.
        //
        // The exit keeps `emphasizedAccel`, which is the correct shape for
        // leaving: back-loaded, so it starts from rest and accelerates out.
        // Back-loaded curves need a shorter run to read as quick -- long
        // enough and the acceleration itself becomes the lag.
        //
        // The divisor is per-direction, and that is a real fix rather than
        // tidying. It used to divide BOTH by 400, but `elementMoveExit`'s
        // base is 200, not 400 -- so the exit was scaled twice and the
        // documented "260 out" actually ran at 130ms. It happened to land near
        // a good number by accident, and the comment above it had been
        // describing a duration the card never used.
        const enter = Appearance.animation.elementMoveEnter;
        const exit = Appearance.animation.elementMoveExit;
        const spec = root.open ? enter : exit;
        const specBase = root.open ? 400 : 200;
        tAnim.stop();
        tAnim.duration = Math.round((root.open ? 200 : 130) * (spec.duration / specBase));
        tAnim.easing.type = Easing.BezierSpline;
        tAnim.easing.bezierCurve = root.open
            ? Appearance.animationCurves.standard
            : Appearance.animationCurves.emphasizedAccel;
        tAnim.to = root.open ? 1 : 0;
        tAnim.start();
    }

    onOpenChanged: {
        // The motion starts FIRST: before the claims, before the state file is
        // written, before the timer-edit cancellation below. That ordering is
        // not tidying -- it is the same ordering the SUPER menu's own handler
        // uses, and the exit used to be started at the very END of this one,
        // after the claims and after a process had been spawned for the state
        // file. Nothing on the far side of this handler needs the motion to
        // have started: `startTransition` reads two properties and starts one
        // animation.
        root.startTransition();
        // An open cancels an instant close that was armed but never consumed.
        if (root.open)
            root.instantClose = false;
        root.syncMeterClaim();
        root._syncAiClaim();
        root.publishPanelState();

        // ── An interval edit does not outlive the card it was opened in ──
        //
        // Here rather than in `close()`, because this is the one place every
        // close passes through -- including a caller that assigns
        // GlobalStates.nowBarPanelOpen directly -- and a flag that survives a
        // close is the reason Escape could do nothing at all on the next press:
        // the window's Shortcut was disabled while `timerEditing` was set, and
        // the item catcher answered by cancelling an edit with no editor on
        // screen, so the key was spent on a state the user could not see.
        //
        // Cancelled, not committed: closing the card is not "I finished
        // typing" (the editor's own Escape cancels too, and the card is
        // click-away), and cancelling is what hands focus back to the card's
        // key catcher.
        if (!root.open && root.timerEditing)
            root.cancelTimerEdit();

        if (root.open) {
            const screen = root.anchorItem ? root.anchorItem.QsWindow?.window?.screen : null;
            root.cardScreen = screen ?? root.fallbackScreen;
            // The panel is a deliberate act, so it opens on the view the island
            // is on rather than flipping anything behind the user's back.
            if (root.mode !== root.modePerf && root.mode !== root.modeMedia
                && root.mode !== root.modePomodoro && root.mode !== root.modeAi
                && root.mode !== root.modeTrading)
                root.setMode(root.modeAi);
        }
    }
    // A claim release, not a blind clear: a rebuilt panel must not switch the
    // meter off for the panel that replaced it. See AudioVisualizer. The
    // hardware sampler's claim is released on the way out for the same reason
    // and one more: a reload that rebuilds this card must not leave a claim
    // behind that keeps HardwareStats reading files for a tab nobody can see.
    Component.onDestruction: {
        AudioVisualizer.releasePanel(root)
        HardwareStats.setActive("nowBarSystem", false)
    }
    // Tab changes count too: the card is open either way, and a `cava` that
    // nobody is drawing from is just a wakeup per frame.
    //
    // The AI claim is recomputed here for the same reason, and for the extra
    // one that the AI view's own `visible` never reports itself as current --
    // it is a FocusScope whose `visible` is bound to its own opacity.
    onModeChanged: {
        root.syncMeterClaim();
        root._syncAiClaim();
    }
    function syncMeterClaim() {
        if (root.open && root.mode === root.modeMedia)
            AudioVisualizer.claimPanel(root);
        else
            AudioVisualizer.releasePanel(root);
    }

    // Escape, in one place, in the order the key is scoped: the interval
    // editor first, then a ringing alarm, and only then the card itself. The
    // window's `Shortcut` and the item catcher at the bottom of the card both
    // call this, so the two cannot drift apart -- they used to hold their own
    // copies of the same three branches, and the window's copy was the one that
    // could be disabled.
    function escaped() {
        if (root.timerEditing) {
            root.cancelTimerEdit();
            return;
        }
        if (TimerService.alarmActive) {
            TimerService.stopAlarm();
            return;
        }
        root.close("escape");
    }

    function close(reason) {
        // The one close that is not a dismissal of the card: a desktop switch
        // takes its whole context away, so it does not animate at all (see the
        // `instantClose` note above for what that is and how it was measured).
        // Decided HERE rather than in the workspace handler, so every caller
        // naming this reason gets the same exit: the reason string is the
        // funnel, and it is the only thing a caller has to know.
        //
        // ASSIGNED, not set. The flag tracks the close in flight, so an
        // ordinary dismissal clears it again. (The first attempt cleared it when
        // the animation finished, which was wrong in a way worth recording: the
        // quiet branch calls `tAnim.stop()` before it re-targets, `stop()` drops
        // `running`, and the handler ran there -- so the flag was cleared one
        // line before the quiet spec was applied and the card still slid.
        // MEASURED: 5px of the 40px slide, read at t=0.89.)
        root.instantClose = reason === "desktop switch";
        // `reason` is optional so the many existing callers keep working; the
        // ones that ARE a dismissal path name themselves, and the rest report
        // as a plain close. What happens to an open interval edit when the card
        // goes away is NOT here -- it is in `onOpenChanged`, which catches the
        // close no matter which of the five paths caused it, including a caller
        // that assigns the global directly.
        root.noteClose(reason ?? "close");
        GlobalStates.nowBarPanelOpen = false;
    }

    // ── Nothing inside the music tab closes this card ───────────────────
    //
    // There used to be a "stop takes the card with it" rule here: a media
    // card whose music had just stopped closed itself, on the theory that a
    // card full of dead transport buttons is a card nobody asked for. It had
    // `mediaStopped` / `hadTrack` / `checkMediaStop()` and three Connections
    // feeding it.
    //
    // It was wrong, and wrong in the worst possible way -- it closed the card
    // on the one press that was supposed to START the music. Pressing play
    // from a stopped player makes mpv report the change as two signals, and
    // they arrive in this order:
    //
    //   1. onTrackChanged      -- a new track is loading
    //   2. playbackState       -- STILL "Stopped" at this instant
    //   3. onPlaybackStateChanged -- now "Playing", a moment later
    //
    // The handler on step 1 read `playbackState` at exactly the moment it is
    // guaranteed to be stale, because the state change has not been delivered
    // yet. So it saw "stopped", saw `hadTrack` armed from when the card
    // opened, and called `close()`. The user pressed play and the panel
    // vanished; the music started playing to nobody.
    //
    // The rule could not tell "the track ended, this card is stale" from "a
    // track is starting, keep the card", because both look identical at step
    // 2. The only signal that can tell them apart arrives too late to be
    // useful here.
    //
    // Removed rather than patched, because there is no version of "close the
    // music card when the music stops" that does not also close it when the
    // user presses play -- and dismissing the card is not something a widget
    // inside the card gets to decide about itself. What is left is the whole
    // set of reasons the card is allowed to close, and it is short on purpose:
    // a press outside it, a press on a tab, the 3-finger swipe, the
    // close shortcut, or a desktop switch. All of them belong to the user.

    // ── Switching desktop takes the card with it ─────────────────────────
    // The card belongs to the bar of the desktop you are looking at. Leaving
    // it up across a workspace switch leaves a card describing the desktop you
    // just left, floating over the new one -- and because it dims what is
    // behind it, the new desktop looks broken rather than merely covered.
    //
    // It also has a habit of surviving switches the user never asked for: a
    // keybind moves the desktop under the pointer, the bar's own workspace
    // clicks do the same, and a mouse wheel on the bar changes it. None of
    // those are "I want to keep reading this", so the switch closes it the
    // same way a press outside closes it.
    //
    // `onActiveWorkspaceChanged` is the whole signal -- it fires on the switch
    // itself, not on the workspace list being rebuilt, so a window opening on
    // the current desktop cannot close the card out from under a reader.
    //
    // This lives here rather than in the island because the panel owns its own
    // lifetime: anything that can dismiss it should be able to say so in one
    // place, and `close()` is already the single funnel every other dismissal
    // goes through. It is a `Connections` block, not a second `onOpenChanged`
    // -- one object per signal, which is the rule this file has been bitten by
    // before.
    //
    // THE TRIGGER IS THE COMPOSITOR'S OWN EVENT, and how fast it arrives is the
    // whole point of the exit above. `Hyprland.monitorFor(<the card's screen>)`
    // is a native `HyprlandMonitor` fed by Quickshell's event socket: a desktop
    // switch notifies `activeWorkspace` in the same batch it arrives in. This
    // used to watch `HyprlandData.activeWorkspace` instead, which costs a
    // forked `hyprctl activeworkspace -j` and a JSON parse FIRST -- and that
    // wait is exactly what the instant exit cannot afford:
    //
    //   measured 2026-10-15, three switches, both signals timestamped inside the
    //   shell on the same clock: the native event is 52-67ms EARLIER than the
    //   forked read's assignment. At 60Hz that is 3-4 frames where a
    //   full-screen blurred card is still sitting over the desktops sliding
    //   underneath it -- the lag and the glitch, in the last place they were
    //   still reachable.
    //
    // Watching the card's OWN MONITOR is also the correct scope: the card
    // belongs to the bar of the screen it was opened on, so a switch on another
    // screen is not this card's business at all. The forked read could not tell
    // the two apart -- it reports the FOCUSED monitor's workspace globally.
    // (This machine has one monitor, so that half is reasoning, not measurement:
    // the speed half is measured, above.)
    //
    // ("Quickshell's `activeWorkspace` never fired here" is why this used to
    // reach for HyprlandData, and the note is worth keeping for what it got
    // wrong: the singleton has no `activeWorkspace` of its own -- the property
    // lives on the MONITOR, which is what this binds. Reading a property that
    // does not exist is a signal that never fires, which is what three trials
    // in a row measured.)
    //
    // The id comparison is not optional. A monitor's workspace object is
    // replaced as the compositor re-reads its state, so the signal can fire
    // while the desktop stands still; closing straight on the signal alone once
    // meant the card could not be opened at all -- it shut itself within a
    // second of every attempt. So the last id is remembered and only a genuine
    // CHANGE closes the card.
    //
    // -1 is "not seen yet": the first signal after startup only records the
    // desktop we are already on, so a panel that happens to be created during
    // startup does not slam itself shut.
    readonly property var cardMonitor: Hyprland.monitorFor(root.cardScreen ?? root.fallbackScreen)
    property int lastWorkspaceId: -1
    Connections {
        target: root.cardMonitor
        function onActiveWorkspaceChanged() {
            const id = Number(root.cardMonitor?.activeWorkspace?.id ?? 0);
            if (id < 1) return;
            if (root.lastWorkspaceId === -1 || root.lastWorkspaceId === id) {
                root.lastWorkspaceId = id;
                return;
            }
            root.lastWorkspaceId = id;
            // Nothing on screen: a switch closes nothing, and marks nothing.
            // Arming the quiet close anyway would leave the flag set for the
            // NEXT close -- a press outside -- and that one is a dismissal,
            // which is supposed to retract.
            if (!root.open && root.t <= 0.001)
                return;
            root.close("desktop switch");
            // And then re-assert the exit, unconditionally.
            //
            // GlobalStates closes this card on the same signal (its
            // `closeTransientPopups` is where every flag in the shell is put
            // away), and nothing orders the two handlers: if that one ran
            // first, the exit has already begun as an ordinary retract, and
            // `close()` above changes no state (the flag was already false), so
            // nothing would turn it into the instant one. Setting `t` to 0 is
            // idempotent and stops whatever runner is going, so the card is
            // gone in this frame whichever handler won the race -- and being
            // gone in this frame is the whole point: the surface must not be on
            // screen while the desktop slides.
            root.startTransition();
        }
    }

    // ── ...and the desktop SWIPE takes it at the gesture's own start ─────
    //
    // The handler above is one frame late for a swipe, and a swipe is how the
    // desktops change on this machine. `gestures.workspace_swipe_distance` is
    // 500 (custom/general.lua keeps it there on purpose), which means the
    // desktop swipe is INTERACTIVE: the workspaces follow the fingers, live,
    // and the compositor only announces the new one -- `workspace>>N` -- when
    // the gesture is over. Measured on this pad: a four-finger desktop swipe
    // runs 168-293ms (the shell's own tracker logs every one of them, 340 in
    // one session's log). So for the whole gesture the compositor has no news
    // to give, while it is busy dragging the desktops -- and this card's
    // surface is the WHOLE OUTPUT on the Overlay layer with the compositor's
    // blur on it (see the `instantClose` note above). A four-finger swipe is
    // therefore 170-290ms of a frozen, foggy sheet with a dim veil on it,
    // laid over desktops that are already moving: the "lag and glitch when
    // switching desktops" this exit was supposed to have ended.
    //
    // Waiting for the compositor cannot fix that, because at the start of a
    // swipe there is nothing to wait FOR. The shell can see it directly
    // instead: `TouchpadSwipe` reads this pad over evdev (the same stream the
    // compositor reads, not grabbed) and reports every gesture frame as it
    // happens -- the bar's brightness/volume swipe already rides it. So the
    // card is taken at the START of the gesture, one input frame after the
    // fingers move, which is before the desktops have moved at all.
    //
    // WHICH gestures, though -- the wrong gate here is worse than the bug:
    //
    //   * FOUR fingers, minimum. Two- and three-finger horizontal swipes are
    //     this card's OWN tab swipe, and two fingers over the bar are
    //     brightness/volume; closing on those would take the card away from a
    //     hand that was only changing tabs.
    //   * SIDEWAYS, and only sideways. A four-finger VERTICAL drag is the
    //     dismiss drag the popups share (`dragSession`, TouchpadSwipe.qml) --
    //     the card is supposed to FOLLOW those fingers, not vanish -- and four
    //     fingers down also means "close the focused window" in
    //     custom/general.lua. So two ways of reading "this is the sideways one":
    //
    //       DOMINANCE -- sideways travel of at least three times the vertical
    //       travel, with 1% of a pad width under it as the floor. This is the
    //       same shape, with the same constants, that BarContent.qml already
    //       uses to REFUSE its own vertical swipe when the gesture turns out to
    //       be this one: one reading of the same document, so the two cannot
    //       disagree about which gesture is in flight. It is the fast half --
    //       both sums accumulate per frame, so it is satisfied within the first
    //       millimetre of a real swipe and cannot be satisfied at all by a
    //       vertical drag (this pad's vertical drift is ~1/100th of its
    //       vertical travel, so it never gets within 3:1).
    //
    //       OR the tracker's OWN threshold for calling a swipe horizontal at
    //       all (`horizontalSwipeRatio`, the same number its `horizontalSwipeEnded`
    //       announcement gates on). That covers the hand that comes in
    //       DIAGONALLY: Hyprland axis-locks a swipe after 10 units of travel
    //       (gestures.workspace_swipe_direction_lock, custom/general.lua), so a
    //       60/40 gesture still drags the desktops even though its vertical
    //       travel is not negligible -- and the measured four-finger desktop
    //       swipes in this shell's log all ended at 0.073-0.123 of a pad width,
    //       so this lands well inside a real one. A four-finger vertical drag
    //       stays near 0.017, nowhere near it.
    //
    // `start` (the count the gesture began with) is checked as well as the
    // live count, because on this pad a four-finger swipe usually arrives as
    // `start=2` and grows: three fingers simply land first. Either count being
    // four is enough, and the live one gets there within a few frames.
    //
    // One predicate, and the IPC probe below calls the same one, so what a
    // test exercises is the shipped decision and not a copy of it.
    function desktopSwipe(fingers, start, htotal, total) {
        if (start < 4 && fingers < 4)
            return false;
        if (Math.abs(htotal) > Math.abs(total) * 3 && Math.abs(htotal) > 0.01)
            return true;
        return Math.abs(htotal) >= TouchpadSwipe.horizontalSwipeRatio;
    }
    Connections {
        target: TouchpadSwipe
        function onMoved(dy, x, y, fingers, start) {
            // Nothing on screen: a swipe closes nothing, and marks nothing --
            // the same rule as the workspace handler above, and for the same
            // reason (an armed quiet close would be inherited by the next
            // dismissal, which is supposed to retract).
            if (!root.open && root.t <= 0.001)
                return;
            if (!root.desktopSwipe(fingers, start, TouchpadSwipe.htotal, TouchpadSwipe.total))
                return;
            // A swipe that goes NOWHERE -- the left edge of desktop 1 is the
            // only one left, and it shakes the screen instead of moving -- still
            // takes the card, and that is deliberate: the gesture asked to leave
            // this desktop, and what the card describes is this desktop. Waiting
            // to find out whether the desktop actually moved is the same wait
            // that put 170-290ms of frozen blur on screen in the first place.
            //
            // The same exit and the same reason as the workspace switch: one
            // funnel (`close()` decides the quiet exit from the reason), and
            // the reason is honest -- a desktop switch is exactly what the
            // hand is doing.
            root.close("desktop switch");
            root.startTransition();
        }
    }

    // A finished lap turns INTO the notification: the panel blooms open on
    // the Clock tab with the stoppable alarm banner, and the ringtone loops
    // until it is stopped (banner button or any timer action). The island
    // follows the mode change, so the two can never disagree about the view.
    Connections {
        target: TimerService
        function onAlarmActiveChanged() {
            if (!TimerService.alarmActive) return;
            root.setMode(root.modePomodoro);
            GlobalStates.nowBarPanelOpen = true;
        }
    }

    // ── Panel state, published for the compositor ───────────────────────
    // The compositor owns libinput and thus the 3-finger swipes, but it cannot
    // see a Quickshell layer surface's open state. The down-swipe that POPS
    // the card out and the up-swipe that PUTS IT AWAY both need to know:
    // with the card open, three fingers up/down must close it (and never also
    // field-move a window behind the veil); with it closed, the swipes keep
    // their other meanings. This is the same file handshake the island's
    // hover publisher uses (NowBar.qml -> ii-nowbar-hover.json), and the Lua
    // side applies the same staleness rule.
    //
    //   $XDG_RUNTIME_DIR/ii-nowbar-panel.json  {"open":true,"ts":...}
    //
    // Written on every open/close change; refreshed every 2s while open (the
    // keepalive). A missing file means "closed": a shell that never got to
    // write it (or was killed between frames) leaves the swipes at their
    // defaults, which is the safe direction -- the field-move stays available
    // and a swipe can only ADD a popup, never get stuck unable to remove one.
    readonly property string panelStatePath:
        `${Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"}/ii-nowbar-panel.json`
    property real panelTs: 0
    Process {
        id: panelStateWriter
        command: ["sh", "-c",
            `printf '{"open":${root.open},"ts":${root.panelTs}}' > '${root.panelStatePath}'`]
    }
    function publishPanelState() {
        root.panelTs = Date.now() / 1000;
        panelStateWriter.running = false;
        panelStateWriter.running = true;
    }
    // (The startup publish lives in the single Component.onCompleted above;
    // a second one here was a hard load failure.)
    Timer {
        // The keepalive: only needed while open. A closed panel has nothing
        // for the compositor to honour, and a stale file reads as closed.
        interval: 2000
        repeat: true
        running: root.open
        onTriggered: root.publishPanelState()
    }

    // The gestures' other half: three fingers UP puts the card away. Its own
    // shortcut rather than the toggle, because "up" must never OPEN it.
    GlobalShortcut {
        name: "nowbarPanelClose"
        description: "Puts the now bar's panel away"
        onPressed: root.close("close shortcut")
    }

    // Outside press. GlobalFocusGrab is the shell's one shared compositor
    // grab: while the panel holds it, a press anywhere else fires `dismissed`.
    Connections {
        target: GlobalFocusGrab
        function onDismissed() {
            if (root.open) root.close("outside press");
        }
    }

    PanelWindow {
        id: panel

        screen: root.cardScreen ?? root.fallbackScreen
        // Kept mapped through the closing animation, then released.
        visible: root.open || root.t > 0.01
        color: "transparent"
        // ── The whole screen, bar strip included ────────────────────────
        //
        // -1, not 0: the surface ignores every other surface's exclusive zone,
        // so it is the OUTPUT's size rather than the output minus the bar. That
        // one number is the difference between "a press outside the card closes
        // it" and "a press on the top 45px does nothing".
        //
        // With `0` the bar's own reservation (Appearance.sizes.baseBarHeight +
        // the outer gaps) pushed this surface down to y=45, and the strip above
        // it belonged to the BAR -- a different surface, and a window the focus
        // grab below deliberately keeps as a grab member. So a press there was
        // input inside a grabbing window, which is exactly the case the shared
        // grab never dismisses on, and the bar's background swallowed it. The
        // comment at the top of this file promises the card "closes when you
        // press anywhere outside it ... 'outside' means the whole desktop, not
        // just the card's edges" -- this is what makes that true rather than
        // nearly true.
        //
        // -1 and NOT a negative margin or a hand-set height: the anchors below
        // already say top/bottom/left/right, and this is the only thing that
        // was overriding them. Nothing is reserved for anybody either way
        // (`exclusionMode: Ignore` stays), so the bar keeps its strip while the
        // card is shut -- the panel is unmapped then, and a layer surface that
        // is not on screen is not in anyone's way.
        exclusiveZone: -1
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "quickshell:barPanel"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        // Escape puts the card away, and it is answered from the WINDOW rather
        // than from whatever happens to be focused inside it: the surface holds
        // the keyboard exclusively while it is open, so an Escape that no item
        // consumes is an Escape that looks dead.
        //
        // It is enabled for as long as the card is open, and the SCOPING moved
        // into the handler. It used to be `enabled: root.open && !root.timerEditing`,
        // which made the timer editor a way for this key to do nothing at all:
        // an edit left open when the card closed (press the digits, then press
        // the veil) kept `timerEditing` true across the close, so on the next
        // open the only Escape handler on the surface was DISABLED and the item
        // catcher below answered by cancelling an edit nobody could see -- one
        // press that looks exactly like a dead key. `root.escaped()` keeps the
        // same order of answers (edit, then alarm, then the card) with no state
        // in which the key is unrouted.
        Shortcut {
            sequence: "Escape"
            enabled: root.open
            onActivated: root.escaped()
        }

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        onVisibleChanged: {
            if (visible && root.open) GlobalFocusGrab.addDismissable(panel);
            else GlobalFocusGrab.removeDismissable(panel);
        }



        // Horizontal swipe over the panel's empty space (and over the card --
        // the card's own area does not accept wheel either, so the event
        // bubbles up to here) changes the view, exactly like the island: TWO
        // OR THREE fingers, whatever arrives. Touchpad swipes of any finger
        // count arrive as pixel events, so the shared classifier (NowBar's
        // wheelDx / wheelDy) routes them through the pixel path, which is
        // both smoother and finger-count agnostic.
        //
        // The island's ACCUMULATOR grammar, not per-event stepping: a swipe
        // arrives as a BURST of wheel events, and the old per-event step (a
        // direction lock was its only brake) walked one physical gesture
        // through several views. Pixels pile up, horizontal must win by a
        // real margin before the gesture means anything, ONE threshold
        // crossing fires ONE step, and the accumulator resets 180ms after
        // the fingers stop -- one gesture = one view, both finger counts,
        // the same feel as over the island itself.
        // The catcher: the wheel belongs to the view, and a LEFT PRESS on the
        // empty space -- the veil around the card -- puts the card away. It
        // used to accept no buttons at all and lean on the compositor grab for
        // dismissal, but a press that lands on this surface is a press INSIDE
        // the grabbing window, so Hyprland never dismissed the grab and the
        // veil swallowed the press: clicking away from the card did nothing,
        // and the only exits were the chevron and the island. The card is drawn
        // on top, so a click on it never reaches this handler. (The app search
        // menu closes the same way.)
        //
        // PRESS, not click -- every other popup in this shell dismisses on
        // `onPressed` (see BarAnchoredPanel), and this one waited for the
        // RELEASE. That is one extra thing that has to go right before the card
        // goes away, and it is the half that goes wrong: the press is also the
        // moment the compositor hands the keyboard to the surface, and a press
        // spent on that is a press with no matching release to complete a
        // click. On press there is nothing to complete and nothing to lose.
        MouseArea {
            id: panelSwipeArea
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            onWheel: wheel => root.handlePanelWheel(wheel)
            onPressed: mouse => {
                root.veilPresses++;
                root.veilPressPos = [Math.round(mouse.x), Math.round(mouse.y)];
                root.close("veil press");
            }

            // ── Focus restoration ───────────────────────────────────────────
            // Reload the album art (and anything else bound to a transient
            // external snapshot) when the window regains focus, so the card
            // stays fresh on alt-tab return without churning the art on every
            // move event.
            //
            // These three live INSIDE the MouseArea on purpose: they are
            // Item properties, and the panel window they used to be stranded
            // on has no `focus` at all -- which is why the load failed with
            // "Cannot assign to non-existent property onFocusChanged".
            focusPolicy: Qt.NoFocus
            focus: true
            onFocusChanged: if (focus) root.refreshArtIfStale()
        }

            // ── The card ─────────────────────────────────────────────────────
        // Full size at dead centre from the first frame; the open/close
        // motion is a scale around its own middle, so it blooms out of the
        // centre of the screen instead of stretching from a corner.
        Rectangle {
            id: card
            width: root.cardWidth
            height: root.cardHeight
            x: root.cardCX - width / 2
            y: root.cardCY - height / 2 - root.cardSlideOffset
            opacity: root.cardOpacity
            radius: Appearance.rounding.windowRounding
            color: Appearance.colors.colLayer0
            border.width: 1
            border.color: Appearance.colors.colLayer0Border
            clip: true


            // Eat clicks on the card itself (padding, gutters) so they are
            // never read as "outside" presses.
            //
            // It also carries the horizontal-swipe handler, and that is the
            // whole point: Qt never delivers a wheel event to a sibling, so
            // before this the swipe only worked in the empty strip above the
            // card. Same shared handler as the panel margins, same
            // accumulator -- a gesture that crosses the card boundary is
            // still one gesture.
            MouseArea {
                anchors.fill: parent
                onWheel: wheel => root.handlePanelWheel(wheel)
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 10
                // THE SWIPE -- as a transform, NOT as `x`.
                //
                // The first attempt set `x: 14 + offset` here, and it did
                // nothing: this layout is anchored with anchors.fill, and an
                // anchored item ignores manual x -- anchors win, the binding
                // is dropped, and the content never moves. Qt does not even
                // warn. A Translate transform composes with anchors instead
                // of fighting them, so the offset actually applies.
                transform: Translate {
                    x: root.contentSlideOffset
                }
                opacity: root.contentOpacity

                // ── Header: the tabs ─────────────────────────────────────
                //
                // SYMMETRIC BY CONSTRUCTION: a spacer on each side of the
                // chips, so the five of them land on the card's own centre
                // line -- which is where the tick row below already sits.
                //
                // The row used to be left-packed against a close chevron in
                // the top-right corner, and the chevron is gone. It was one of
                // five ways out (a press on the veil, Escape, the close
                // shortcut and a desktop switch are the others), so the header
                // bought a pointer exit it did not need -- and paid for it
                // with the one thing the row is for.
                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: root.headerHeight - 6
                    spacing: 6

                    Item { Layout.fillWidth: true }

                    Repeater {
                        model: root.tabs
                        Rectangle {
                            id: tabChip
                            required property var modelData
                            readonly property bool active: root.mode === modelData.m
                            Layout.alignment: Qt.AlignVCenter
                            // 28, not 20: at 20 the label sat close enough to
                            // the box that the pill read as a tight fit around
                            // the words rather than a box the words sit in.
                            implicitWidth: tabRow.implicitWidth + 28
                            implicitHeight: 26
                            // A rounded rectangle, not a pill. `full` on a 26px
                            // box is a 13px corner, and at that radius the curve
                            // is the whole shape -- the chip stops reading as a
                            // box with a label in it.
                            radius: Appearance.rounding.normal
                            // Hover is the card's OWN colour, a small step
                            // toward its text colour -- not a wash of white, and
                            // not a lift taken from another layer. Measured with
                            // a pointer parked on a chip, the fill on screen is
                            // #101010 over a #0C0C0C card: +4/255, where the old
                            // cue (colLayer1Hover at 0.45, a blue-grey) landed
                            // near +10, and the selected chip's own fill carries
                            // +39.
                            //
                            // It is NOT `colLayer0Hover`: that token is
                            // `transparentize(mix(colLayer0, colOnLayer0, 0.9))`,
                            // and `transparentize` with no percentage defaults
                            // to alpha 0 -- so the token renders as nothing at
                            // all over any surface. Measured, not assumed: a
                            // swatch of it over this card is pixel-identical to
                            // the card.
                            color: tabChip.active
                                ? ColorUtils.transparentize(Appearance.colors.colPrimary, 0.78)
                                : tabChip.hovered
                                    ? ColorUtils.mix(Appearance.colors.colLayer0,
                                        Appearance.colors.colOnLayer0, 0.98)
                                    : "transparent"
                            // The stroke stays: on a rounded-rectangle corner the
                            // outline is what says "this one" at a glance.
                            border.width: tabChip.active ? 1 : 0
                            border.color: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.4)
                            property bool hovered: false
                            HoverHandler {
                                cursorShape: Qt.PointingHandCursor
                                onHoveredChanged: tabChip.hovered = hovered
                            }
                            TapHandler { onTapped: root.setMode(tabChip.modelData.m) }

                            // One motion for the accent: the chip's wash fades
                            // rather than snapping between tabs. The same
                            // animation carries the hover fill in and out, so
                            // the cue arrives and leaves as a fade, not a switch.
                            Behavior on color {
                                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                            }

                            Row {
                                id: tabRow
                                anchors.centerIn: parent
                                spacing: 5
                                MaterialSymbol {
                                    id: modeChipIcon
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: tabChip.modelData.icon
                                    iconSize: 15
                                    color: tabChip.active ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer0

                                    // The hover cue, and the ONLY one: the
                                    // chip's own fill (see `color` above), one
                                    // step lighter than the card it sits on,
                                    // fading on the shell's fast colour
                                    // animation. No underline, no ring -- this
                                    // chip is a bare Rectangle with its own
                                    // HoverHandler, not a RippleButton, so the
                                    // fill is the whole vocabulary it has.
                                }
                                StyledText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: tabChip.modelData.label
                                    font.pixelSize: Appearance.font.pixelSize.smallie
                                    color: tabChip.active ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer0
                                }


                            }
                        }
                    }

                    Item { Layout.fillWidth: true }
                }

                // ── The island's tabs, continued ─────────────────────────
                // The same tick row the island carries on its bottom edge, so
                // the card reads as that strip grown into a surface. Clicking
                // a tick jumps straight to that tab. Like the island's row,
                // it stays hidden until a view change answers "where did I
                // land?" -- it rides the same hint window, then fades away.
                // (Hovering the row's area still reveals it early -- the row
                // occupies its space either way, so the card does not jump.)
                Row {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 5
                    visible: opacity > 0.01 || tickRowHover.hovered
                    opacity: (GlobalStates.nowBarTickHint || tickRowHover.hovered) ? 1 : 0
                    // Hidden ticks must not reserve header space either: the
                    // row's layout height collapses to zero while hidden, so
                    // the header is symmetrical at rest and the row "makes
                    // room" for itself exactly when it appears.
                    Layout.preferredHeight:
                        (GlobalStates.nowBarTickHint || tickRowHover.hovered) ? implicitHeight : 0
                    Behavior on opacity {
                        animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                    }
                    HoverHandler { id: tickRowHover; cursorShape: Qt.PointingHandCursor }

                    Repeater {
                        model: root.modeCount

                        Rectangle {
                            required property int index
                            readonly property bool active: root.mode === index
                            width: active ? 22 : 10
                            height: 3
                            radius: 1.5
                            color: active
                                ? Appearance.colors.colPrimary
                                : ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.68)
                            opacity: tickHover.hovered ? 1.0 : (active ? 0.95 : 0.45)
                            HoverHandler {
                                id: tickHover
                                cursorShape: Qt.PointingHandCursor
                            }
                            TapHandler { onTapped: root.setMode(index) }
                            Behavior on width {
                                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                            }
                            Behavior on color {
                                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                            }
                            Behavior on opacity {
                                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                            }
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.7)
                }

                // ── The four views ───────────────────────────────────────
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    // ── 4 · Trading ───────────────────────────────────────
                    // The instrument's chart, then the day's red-folder
                    // events. The card's height is fixed, so the list
                    // SCROLLS when there are more events than fit -- the
                    // pop-out never grows to chase its own content.
                    PanelFadeView {
                        on: root.mode === root.modeTrading
                        viewIndex: root.modeTrading
                        TradingTab {
                            anchors.fill: parent
                            active: root.mode === root.modeTrading && root.open
                            // The view publishes the scroller its two-finger
                            // swipe should drive. Handed down because an id in
                            // another file is not reachable from here.
                            cardHost: root
                        }
                    }

                    // 1 · Media — hero on top, the whole current playlist
                    // below. The old view was a 128px cover floating beside a
                    // column of text and three buttons, and it used barely a
                    // third of a 920x580 card: the right half was empty and
                    // the track list was a four-row "up next" that answered
                    // the wrong question. The only way to see what else is in
                    // the playlist was to go and look somewhere else.
                    //
                    // The split is deliberate. The hero is the only part that
                    // changes second to second, so it gets a fixed band at the
                    // top where it cannot shove the list around; the list is
                    // the part you actually scan, so it gets every remaining
                    // pixel and scrolls.
                    PanelFadeView {
                        on: root.mode === root.modeMedia
                        viewIndex: root.modeMedia
                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 0

                        // ── Hero ────────────────────────────────────────
                        //
                        // A lot thinner, on purpose. This band was ~300px of a
                        // 580px card -- a 132px cover, 22px gaps twice over, a
                        // 44px transport disc and a 46px sound bar -- which
                        // left the playlist below with barely half the card and
                        // about four visible rows. The cover is the least
                        // informative thing up here (the same art is on every
                        // row of the list underneath, smaller), and the
                        // transport and the sound bar are controls you touch
                        // once and then stop looking at.
                        //
                        // So the hero keeps everything and spends much less:
                        // a 64px cover, 10px gaps, a 36px play disc, a 30px
                        // sound bar. That is ~130px handed straight to the
                        // list, which is the part that is actually scanned.
                        ColumnLayout {
                            // Named for the probe below. Its own `height` is NOT
                            // trustworthy -- the layout reports the hero row's
                            // height for it, which is how the first measurement of
                            // this came to believe the bar sat at y=71 inside a
                            // 56px parent. Measure the row and the bar, not it.
                            id: heroSection
                            Layout.fillWidth: true
                            Layout.leftMargin: 26
                            Layout.rightMargin: 26
                            // These four numbers are where the 8px of cover came
                            // from. They are margins and gaps, not content, so
                            // taking from them is what lets the art grow without
                            // the "playing now" band growing with it:
                            //   top 3 -> 2, bottom 2 -> 1, spacing 3 -> 1
                            //   the bar's topMargin 10 -> 3
                            // The bar keeps 3px of its own top margin AND `pad: 4`
                            // inside the widget, so the first lit pixel of the
                            // spectrum still sits 7px under the cover. That is
                            // what stops the spectrum reading as part of the
                            // identity block, which is what the original 10 was
                            // for -- and it is why the cover could be paid for out
                            // of this gap at all rather than out of the band.
                            Layout.topMargin: 2
                            Layout.bottomMargin: 1
                            spacing: 1


                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignBottom
                                spacing: 2


                                // The cover and the words it belongs to, side by side.
                                //
                                // These were two rows of a vertical layout: the art sat on a
                                // line of its own, and the title, artist and album were all
                                // UNDER it -- so the name read as a caption to the picture
                                // rather than as the thing the picture is for. A track's title
                                // is the primary label on this screen and the art is secondary,
                                // so they are a row now: 72px of cover, then the identity block
                                // filling the rest of the width.
                                //
                                // The cover is 56, down from 76, and it is the
                                // only thing setting the hero's height: the
                                // identity block beside it is two lines and
                                // comes in under that. So the cover is a
                                // direct dial on how tall this section is, and
                                // 20px off it is 20px onto the playlist --
                                // which is the part that gets scanned.
                                //
                                // 56 rather than something smaller because it
                                // has to stay a thumbnail you can recognise a
                                // track from, and the play button beside it is
                                // 34: any smaller and the art stops being the
                                // thing you look at.
                                RowLayout {
                                    id: panelHeroRow
                                    Layout.fillWidth: true
                                    spacing: 14
                                    Rectangle {
                                        id: panelHeroCover
                                        Layout.alignment: Qt.AlignVCenter
                                        // 64, up from 56. The art is the thing you
                                        // recognise a track by, and at 56 it was
                                        // losing to the three lines of text beside
                                        // it in a row that was already only as tall
                                        // as the cover.
                                        //
                                        // NOT paid for out of the section's height:
                                        // this row sets the hero's height, so every
                                        // pixel here is a pixel off the band below
                                        // unless it comes out of the AIR in the band.
                                        // Measured in one coordinate space, that air
                                        // was 12px between this row and the bar, plus
                                        // 3 above and 2 below -- 17 in total, of which
                                        // 8 are spent below. That is the whole
                                        // budget: the cover can grow by 12px before
                                        // the band grows, and only by what is left of
                                        // the gap you want to keep.
                                        Layout.preferredWidth: 64
                                        Layout.preferredHeight: 64
                                        radius: Appearance.rounding.normal
                                        color: Appearance.colors.colLayer1
                                        clip: true
                                        Image {
                                            anchors.fill: parent
                                            anchors.margins: 3
                                            source: MprisController.shownPlayer?.trackArtUrl ?? ""
                                            visible: (MprisController.shownPlayer?.trackArtUrl ?? "") !== ""
                                            fillMode: Image.PreserveAspectCrop
                                            asynchronous: true
                                        }
                                        MaterialSymbol {
                                            anchors.centerIn: parent
                                            visible: (MprisController.shownPlayer?.trackArtUrl ?? "") === ""
                                            text: "music_note"
                                            iconSize: 46
                                            color: Appearance.colors.colOnLayer1Inactive
                                        }
                                    }

                                    ColumnLayout {
                                        id: panelHeroText
                                        Layout.fillWidth: true
                                        Layout.alignment: Qt.AlignVCenter
                                        spacing: 3
                                        // The PLAYLIST name under the title, not the artist.
                                        //
                                        // Requested 2026-10-02. The artist was
                                        // never the useful second line here: the
                                        // track list underneath already names the
                                        // artist on every single row, and the
                                        // playlist was named NOWHERE on the card
                                        // -- which is the one piece of context
                                        // that tells you what you are listening
                                        // through, and the only thing on this
                                        // screen that answers "why is the next
                                        // track that one".
                                        //
                                        // The album goes with it rather than
                                        // replacing it: both are metadata about
                                        // the file, neither is about what you are
                                        // listening to, and they share a line
                                        // because the hero has exactly one line
                                        // to spare.
                                        StyledText {
                                            Layout.fillWidth: true
                                            text: MprisController.mediaTitle(MprisController.shownPlayer)
                                                || Translation.tr("Nothing playing")
                                            font.pixelSize: Appearance.font.pixelSize.title
                                            font.weight: Font.DemiBold
                                            color: Appearance.colors.colOnLayer0
                                            elide: Text.ElideRight
                                        }
                                        StyledText {
                                            Layout.fillWidth: true
                                            visible: root.subLineText !== ""
                                            // `subLineText` is what keeps the
                                            // playlist and the album from
                                            // printing the same word twice when
                                            // the folder and the tag agree --
                                            // which on a local library they
                                            // usually do.
                                            text: root.subLineText
                                            font.pixelSize: Appearance.font.pixelSize.normal
                                            color: Appearance.colors.colSubtext
                                            elide: Text.ElideRight
                                            maximumLineCount: 1
                                        }
                                    }

                                    // ── Transport, grouped at the right ─────────
                                    //
                                    // All THREE buttons now live here, on the
                                    // title row: skip-previous, play/pause,
                                    // skip-next. The skips used to flank the
                                    // seek bar on the row below, which cost
                                    // that bar 66px of its length for two
                                    // arrows that are about the SONG rather
                                    // than about where you are in it -- and
                                    // they are the same size here, so nothing
                                    // was gained by separating them.
                                    //
                                    // 8px between them, the same gap the
                                    // sidebar's marks use. Not tighter: the
                                    // play button carries a visible outline
                                    // and 8px is what keeps that outline from
                                    // reading as part of its neighbour.
                                    RowLayout {
                                        Layout.alignment: Qt.AlignVCenter
                                        spacing: 8

                                        // Shuffle/loop, Spotify-style, on the same
                                        // row as the transport they modify. Lit ring
                                        // + filled glyph while engaged; they route
                                        // through MPRIS (the bridge maps LoopStatus
                                        // onto loop-playlist, matching the daemon
                                        // default), so the app, sidebar, bar and
                                        // any MPRIS client all agree.
                                        TransportMark {
                                            id: panelShuffle
                                            objectName: "panelShuffleMark"
                                            Layout.alignment: Qt.AlignVCenter
                                            glyph: "shuffle"
                                            enabled: root.seekable
                                            modeOn: MprisController.hasShuffle
                                            onTriggered: () => {
                                                const p = MprisController.shownPlayer;
                                                if (p) p.shuffle = !p.shuffle;
                                            }
                                        }

                                        TransportMark {
                                            id: panelSkipPrev
                                            objectName: "panelSkipPrevMark"
                                            Layout.alignment: Qt.AlignVCenter
                                            glyph: "skip_previous"
                                            enabled: root.seekable
                                            onTriggered: () => MprisController.shownPlayer?.previous()
                                        }

                                        // Play/pause. It is BIGGER -- 34px
                                        // rather than the island's 25 -- because
                                        // here it is a primary control on its
                                        // own rather than a mark beside a song
                                        // title, and it has NO background wash
                                        // on hover: at that size a background
                                        // that only appears when the pointer
                                        // arrives left it looking like an
                                        // empty rounded rectangle nine times
                                        // out of ten. `outlined` gives it a
                                        // resting border that brightens.
                                        //
                                        // The sidebar's play mark is left at
                                        // 25px with its pad, where 25px is the
                                        // right number and the pad belongs.
                                        TransportMark {
                                            id: panelPlay
                                            objectName: "panelPlayMark"
                                            Layout.alignment: Qt.AlignVCenter
                                            Layout.preferredWidth: 34
                                            Layout.preferredHeight: 34
                                            box: 34
                                            em: 26
                                            outlined: true
                                            glyph: (MprisController.shownPlayer?.isPlaying ?? false)
                                                ? "pause" : "play_arrow"
                                            onTriggered: () => MprisController.shownPlayer?.togglePlaying()
                                        }

                                        TransportMark {
                                            id: panelSkipNext
                                            objectName: "panelSkipNextMark"
                                            Layout.alignment: Qt.AlignVCenter
                                            glyph: "skip_next"
                                            enabled: root.seekable
                                            onTriggered: () => MprisController.shownPlayer?.next()
                                        }

                                        // Loop: cycles None -> Playlist -> None
                                        // (repeat-one/"Track" also accepted by the
                                        // bridge). Same lit-if-engaged grammar.
                                        TransportMark {
                                            id: panelLoop
                                            objectName: "panelLoopMark"
                                            Layout.alignment: Qt.AlignVCenter
                                            glyph: "repeat"
                                            enabled: root.seekable
                                            modeOn: MprisController.loopSupported
                                                && MprisController.loopState === MprisSvc.MprisLoopState.Playlist
                                            onTriggered: () => {
                                                const p = MprisController.shownPlayer;
                                                if (!p) return;
                                                const on = MprisController.loopState === MprisSvc.MprisLoopState.Playlist;
                                                p.loopState = on ? MprisSvc.MprisLoopState.None
                                                    : MprisSvc.MprisLoopState.Playlist;
                                            }
                                        }
                                    }
                                }
// The secondary toggles and the sound bar, on
                                // their own line under the cover row.
                                //
                                // The transport used to live here too, pinned to
                                // the island's edges with play dead centre. It now
                                // sits on the title row instead -- which is what
                                // pays for the 76px cover -- so this line holds
                                // only the controls that have nothing to do with
                                // the identity of the track.
                                // The shuffle/loop row and the standalone sound
                                // bar used to live here, under the cover row.
                                // Both are now part of the merged bar below --
                                // one object instead of two stacked ones -- and
                                // the empty ColumnLayout that held them was
                                // DELETED rather than left behind. An empty
                                // layout still asks its parent for a height,
                                // and that request is what kept ~80px of
                                // nothing between the cover and the bar.
                                //
                                // Nothing sits here now.
                            }
                        }

                        // ── The merged sound + music bar ────────────────────
                        //
                        // ONE object where there were two, and now the widest
                        // thing on the card. The skips moved up to the title
                        // row to flank the play button, so this row is nothing
                        // but the bar: no arrows, no plate, and it runs from
                        // one side of the card's content to the other.
                        //
                        // The PLATE IS GONE. The bar used to draw its own
                        // `colLayer2` surface, which on a card that already
                        // has its own surface read as a box inside a box, and
                        // it is what made the bar look like a separate widget
                        // dropped into the card rather than part of it.
                        // Without a plate the line has to carry the row on its
                        // own, so the spacing below is doing the work a border
                        // used to.
                        //
                        // 6px inset, not 0 and not 26: flush to the card edge
                        // would touch the border, and 26 was half of what is
                        // now pure margin. The times sit 4px inside that.
                        //
                        // 10px ABOVE, which is new. It was 2, and the bar sat
                        // so close under the cover row that the spectrum read
                        // as part of the identity block rather than as its own
                        // thing -- and the time bubble, which floats 16px above
                        // this widget, was landing on the cover art. Space is
                        // what separates them; a border is not available here
                        // because the plate is gone.
                        SpectrumSeekBar {
                            id: panelMergedBar
                            objectName: "panelMergedBar"
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            Layout.leftMargin: 6
                            Layout.rightMargin: 6
                            Layout.topMargin: 3
                            Layout.bottomMargin: 6
                            pad: 4
                            // The up-and-down lines only, and only here: the
                            // seek line, both time stamps and the volume
                            // gesture stay put when nothing is playing.
                            showSpectrum: root.musicPlaying
                            active: root.seekable
                            position: root.displayPosition
                            duration: MprisController.shownPlayer?.length ?? 0
                            volume: MprisController.shownPlayer?.volume ?? 0
                            onSeekRequested: f => root.seekToFraction(f)
                            onVolumeRequested: lvl => {
                                const p = MprisController.shownPlayer;
                                if (p && p.volume !== undefined) p.volume = lvl;
                            }
                        }



                        // ── The playlist ─────────────────────────────────
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.minimumHeight: 120
                            color: "transparent"
                            border.width: 0

                            // Nothing to list. A visible, centred reason beats
                            // an empty bordered box, and beats hiding the
                            // section and leaving the card looking cut off.
                            //
                            // This is now ONLY reachable before anything has
                            // ever played in this session: once a playlist has
                            // been seen it stays on screen (see
                            // `shownPlaylist`), so stopping the music leaves
                            // the list and the row it stopped on exactly where
                            // they were instead of blanking the card.
                            ColumnLayout {
                                anchors.centerIn: parent
                                spacing: 6
                                visible: root.playlistTracks.length === 0
                                MaterialSymbol {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: "queue_music"
                                    iconSize: 30
                                    color: Appearance.colors.colOnLayer1Inactive
                                }
                                StyledText {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: root.playlistTracks.length === 0 && root.playingPath !== ""
                                        ? Translation.tr("This track is not part of a scanned playlist")
                                        : Translation.tr("No playlist playing")
                                    font.pixelSize: Appearance.font.pixelSize.smallie
                                    color: Appearance.colors.colOnLayer1Inactive
                                }
                            }

                            // The list itself.
                            //
                            // StyledListView, not a bare ListView. That
                            // component is where the shell already answers
                            // "make scrolling feel like the browser": a
                            // touchpad's pixel deltas are tracked 1:1 (the
                            // same fling Brave gives you, and libinput's
                            // momentum is left alone instead of being
                            // re-animated on top of), while a mouse wheel gets
                            // eased notches plus a decaying glide so the list
                            // keeps rolling after the last detent. A plain
                            // ListView has Qt's defaults for all of it, which
                            // is a dead-stop on every notch.
                            //
                            // It also carries the shell's own scrollbar, so
                            // the tracklist scrolls exactly like the file
                            // manager, the task manager and the notification
                            // centre instead of inventing a fourth feel.
                            StyledListView {
                                id: trackList
                                anchors.fill: parent
                                anchors.topMargin: 34
                                clip: true
                                visible: root.playlistTracks.length > 0
                                model: root.playlistTracks
                                // Air between the rows. This was `1`, which is
                                // not spacing so much as the absence of it:
                                // 34px rows butted against each other read as
                                // one striped block, and the only thing that
                                // separated "now" from "next" was a 2.5px rule
                                // on the current row. The row is TALLER and
                                // the gap is real, so a row can be picked out
                                // by its position and not only by its
                                // highlight -- which matters most exactly
                                // where it is hardest: on the current track,
                                // which is highlighted whether or not you
                                // were looking for it.
                                spacing: 5
                                // The library is rebuilt from scratch every
                                // scan, so this model is a brand new array
                                // once a minute. With the component's default
                                // pop-in, every row would re-scale and re-fade
                                // on that timer, which reads as a glitch rather
                                // than an animation.
                                animateAppearance: false
                                popin: false

                                ScrollBar.vertical: StyledScrollBar {
                                    // The house scrollbar only shows on hover or
                                    // press, which is right for a chrome nobody
                                    // is scrolling. A list you can scroll
                                    // should say so on its own: AlwaysOn still
                                    // hides the thumb entirely when everything
                                    // fits, because the shared component gates
                                    // its opacity on size < 1.0 as well.
                                    policy: ScrollBar.AlwaysOn
                                }

                                // currentIndex is the index of the PLAYING
                                // track inside this playlist, or -1. Following
                                // it is what keeps the row you care about
                                // visible while the list is long.
                                currentIndex: root.currentTrackIndex
                                onCurrentIndexChanged: {
                                    if (currentIndex < 0) return;
                                    // The library rescan resets the model, which
                                    // walks currentIndex through -1 and back to
                                    // the same track. Without this guard the
                                    // list yanked itself back to the playing row
                                    // every 60 seconds, discarding wherever the
                                    // user had scrolled to.
                                    if (root.playingPath === trackList.lastScrolledPath) return;
                                    trackList.lastScrolledPath = root.playingPath;
                                    positionViewAtIndex(currentIndex, ListView.Contain);
                                }
                                property string lastScrolledPath: ""

                                delegate: Item {
                                    id: trackRow
                                    required property int index
                                    required property var modelData

                                    readonly property bool isCurrent: trackRow.modelData.path === root.markedPath;

                                    width: trackList.width
                                    height: 42

                                    Rectangle {
                                        anchors.fill: parent
                                        anchors.leftMargin: 12
                                        anchors.rightMargin: 12
                                        radius: Appearance.rounding.normal
                                        // The current row is marked three ways
                                        // at once on purpose: colour alone fails
                                        // for anyone who cannot separate the
                                        // accent from the background, and a
                                        // single left border is easy to lose in
                                        // a long list.
                                        color: trackRow.isCurrent
                                            ? ColorUtils.transparentize(Appearance.colors.colPrimary, 0.88)
                                            : (rowHover.hovered
                                                ? Appearance.colors.colLayer1Hover
                                                : "transparent")
                                    }
                                    // A left rule rather than a full outline:
                                    // it points at the row without boxing it in.
                                    Rectangle {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 12
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 3
                                        height: 22
                                        radius: 1.25
                                        visible: trackRow.isCurrent
                                        color: Appearance.colors.colPrimary
                                    }

                                    HoverHandler { id: rowHover }

                                    // The cover, left of the name.
                                    //
                                    // EVERY row gets one, which is the point:
                                    // the list is scanned rather than read, and
                                    // a picture is how you find the track you
                                    // half-remember. The scan knows a cover
                                    // for every track it can find one for (a
                                    // sibling cover file, or the frame pulled
                                    // out of the mp3 into the shared cache), so
                                    // this is the same picture the sidebar's
                                    // rail uses, not a new source of art.
                                    //
                                    // What it looked like before was a FILLED
                                    // 24px tile in `colLayer1` carrying a faint
                                    // glyph. On a track with no cover that is
                                    // not an icon, it is a hole: a dark square
                                    // the same size and weight as a real
                                    // picture, reading as "broken" rather than
                                    // as "no artwork for this one". So the
                                    // tile is only drawn when there IS
                                    // something to show, and the no-cover case
                                    // is a plain glyph on the row's own
                                    // background -- present, aligned with
                                    // every other row, and unmistakably a
                                    // placeholder.
                                    readonly property bool hasArt:
                                        String(trackRow.modelData.art ?? "") !== ""
                                    Rectangle {
                                        id: rowArt
                                        x: 22
                                        width: 24
                                        height: 24
                                        anchors.verticalCenter: parent.verticalCenter
                                        radius: Appearance.rounding.small
                                        // Only for a real picture. See above.
                                        color: Appearance.colors.colLayer1
                                        visible: trackRow.hasArt
                                        clip: true
                                        Image {
                                            id: rowArtImage
                                            anchors.fill: parent
                                            anchors.margins: 0.5
                                            source: trackRow.hasArt
                                                ? "file://" + trackRow.modelData.art
                                                : ""
                                            visible: status === Image.Ready
                                            fillMode: Image.PreserveAspectCrop
                                            asynchronous: true
                                            // The list scrolls; a decode that
                                            // lands after the row has been
                                            // recycled must not paint on
                                            // whatever row holds this source
                                            // now.
                                            onStatusChanged: if (status === Image.Error) source = ""
                                        }
                                    }
                                    // The no-cover mark, in the same 24px slot
                                    // so the rows stay on one grid whether or
                                    // not the art resolved.
                                    MaterialSymbol {
                                        x: 22
                                        width: 24
                                        height: 24
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: !trackRow.hasArt
                                        text: "music_note"
                                        iconSize: 14
                                        color: Appearance.colors.colOnLayer1Inactive
                                    }

                                    // Same hand-placed columns as the header,
                                    // same offsets. A ListView delegate holding
                                    // a RowLayout gave the artist and time
                                    // columns zero width; anchoring each cell to
                                    // the delegate's own width cannot drift.
                                    StyledText {
                                        x: 54
                                        width: 26
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: String(trackRow.index + 1)
                                        font.pixelSize: Appearance.font.pixelSize.tiny
                                        font.family: Appearance.font.family.monospace
                                        color: Appearance.colors.colOnLayer1Inactive
                                    }
                                    StyledText {
                                        x: 86
                                        width: parent.width - 86 - 160 - 56 - 34
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: trackRow.modelData.title
                                        font.pixelSize: Appearance.font.pixelSize.normal
                                        font.weight: trackRow.isCurrent ? Font.DemiBold : Font.Normal
                                        color: trackRow.isCurrent
                                            ? Appearance.colors.colOnLayer0
                                            : Appearance.colors.colSubtext
                                        elide: Text.ElideRight
                                    }
                                    StyledText {
                                        x: parent.width - 160 - 56 - 34
                                        width: 150
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: trackRow.modelData.artist
                                        font.pixelSize: Appearance.font.pixelSize.smallie
                                        color: Appearance.colors.colOnLayer1Inactive
                                        elide: Text.ElideRight
                                    }
                                    // The playing row's meter — in the exact same slot as
                                    // the duration time (same width, same right edge),
                                    // right-aligned, when this track is the one
                                    // currently playing. Reads real bands off the
                                    // shared waveform so it moves with the music.
                                    Item {
                                        id: rowMeterSlot
                                        x: parent.width - 56 - 34
                                        width: 46
                                        height: 14
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: trackRow.isCurrent && root.musicPlaying
                                    }                                        Row {
                                        id: rowMeter
                                        anchors.right: rowMeterSlot.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 2
                                        height: 14
                                        visible: trackRow.isCurrent && root.musicPlaying
                                        // Same bar style as the original rowMeter —
                                        // just moved to the right side in the
                                        // duration slot.
                                        function bandAt(fraction) {
                                            const p = AudioVisualizer.points;
                                            if (!p || p.length < 3) return 0;
                                            const i = Math.min(p.length - 1,
                                                Math.max(0, Math.round(fraction * (p.length - 1))));
                                            return p[i];
                                        }
                                        Repeater {
                                            model: 5
                                            Rectangle {
                                                required property int index
                                                width: 2.5; radius: 1.25
                                                color: Appearance.colors.colPrimary
                                                anchors.bottom: parent.bottom
                                                height: 2 + Math.min(1, rowMeter.bandAt([0.06, 0.30, 0.72][index % 3]) / 900) * 12
                                                Behavior on height {
                                                    NumberAnimation { duration: 90; easing.type: Easing.OutCubic }
                                                }
                                            }
                                        }
                                    }
                                    StyledText {
                                        x: parent.width - 56 - 34
                                        width: 46
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: trackRow.modelData.duration
                                            ? root.clock(trackRow.modelData.duration)
                                            : ""
                                        horizontalAlignment: Text.AlignRight
                                        font.pixelSize: Appearance.font.pixelSize.tiny
                                        font.family: Appearance.font.family.monospace
                                        color: Appearance.colors.colOnLayer1Inactive
                                        visible: !trackRow.isCurrent || !root.musicPlaying
                                    }

                                    // Play this one, on click anywhere on the
                                    // row. Replacing the queue with the
                                    // playlist is what makes the click mean
                                    // what the list shows; a bare "append" here
                                    // would silently grow the queue instead.
                                    TapHandler {
                                        onTapped: {
                                            if (root.shownPlaylist)
                                                MusicPlayer.playPlaylist(root.shownPlaylist.name, trackRow.index);
                                        }
                                    }
                                }
                            }
                                // Column header, ABOVE the ListView and not
                                // inside it. As a delegate-positioned item at
                                // y:-34 it sat inside the view's clip, so the
                                // one row that explains what the columns mean
                                // was the one row you could not read.
                                Item {
                                    anchors.top: parent.top
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    height: 32
                                    z: 2
                                    // Columns are placed by hand, not by a
                                    // RowLayout. A layout gives the fillWidth
                                    // title everything that is left AFTER the
                                    // fixed columns, and in practice the last
                                    // two columns collapsed to nothing -- the
                                    // artist and the running time were simply
                                    // not on screen. Absolute offsets are also
                                    // the only way the header and the rows can
                                    // be guaranteed to line up.
                                    StyledText {
                                        x: 54; width: 26
                                        text: "#"
                                        font.pixelSize: Appearance.font.pixelSize.tiny
                                        color: Appearance.colors.colOnLayer1Inactive
                                    }
                                    StyledText {
                                        x: 86
                                        width: parent.width - 86 - 160 - 56 - 34
                                        text: Translation.tr("Title")
                                        font.pixelSize: Appearance.font.pixelSize.tiny
                                        color: Appearance.colors.colOnLayer1Inactive
                                    }
                                    StyledText {
                                        x: parent.width - 160 - 56 - 34
                                        width: 150
                                        text: Translation.tr("Artist")
                                        font.pixelSize: Appearance.font.pixelSize.tiny
                                        color: Appearance.colors.colOnLayer1Inactive
                                        elide: Text.ElideRight
                                    }
                                    StyledText {
                                        x: parent.width - 56 - 34
                                        width: 46
                                        text: Translation.tr("Time")
                                        horizontalAlignment: Text.AlignRight
                                        font.pixelSize: Appearance.font.pixelSize.tiny
                                        color: Appearance.colors.colOnLayer1Inactive
                                    }
                                    Rectangle {
                                        anchors.bottom: parent.bottom
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.leftMargin: 12
                                        anchors.rightMargin: 12
                                        height: 1
                                        color: ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.7)
                                    }
                                }
                        }
                    }
                }

                    // 2 · Clock: the wall clock, with everything the
                    // pomodoro does in its own half. The old "Focus" tab was
                    // a bare countdown; the tab is the clock's home now, and
                    // the timer lives beside it -- phase, countdown, cycle
                    // dots, start/pause + reset, and the focus length stepper
                    // (persisted through the Config, like the island's).
                    PanelFadeView {
                        on: root.mode === root.modePomodoro
                        viewIndex: root.modePomodoro
                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 0

                        // Own clock source at seconds precision: the shared
                        // DateTime runs minute-precision unless the shell is
                        // set otherwise, so its seconds chunk would freeze.
                        SystemClock {
                            id: tabClock
                            precision: SystemClock.Seconds
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: 28

                            // ── The clock: the tab's name made real ──
                            // Each half is a fillWidth ITEM (equal share of the
                            // row, guaranteed) with the content anchored dead
                            // centre inside. The previous nested fillWidth
                            // columns let the preset row's width-dependent
                            // preferred size skew the engine's space split,
                            // starving this half down to its implicit width --
                            // the clock clipped at the card edge while the
                            // pomodoro half swam in dead space. Anchored
                            // centring inside a fixed 50/50 wrapper cannot
                            // drift, whatever the children measure.
                            Item {
                                id: clockHalf
                                Layout.fillWidth: true
                                Layout.fillHeight: true

                                // Anchored to the half, not stacked by a
                                // positioner.
                                //
                                // A Column sizes its CHILDREN, never itself:
                                // its width and height stayed 0, and
                                // `anchors.centerIn` centres a BOX -- so the
                                // block sat with its top-left corner on the
                                // centre point and every anchored child (the
                                // clock row, the date) was then centred inside
                                // that zero-sized box and landed half its own
                                // width to the LEFT of the middle. Giving the
                                // block a real box fixed the horizontal drift,
                                // but a Column still leaves the vertical
                                // centring at the mercy of an implicit height
                                // that only exists after layout.
                                //
                                // So the block is a plain Item filling the
                                // half: the date is centred in it outright,
                                // and the time sits 8px above the date with an
                                // offset that makes the PAIR -- not just the
                                // date -- the centred thing. The offset is
                                // derived from the time row's own height, so it
                                // stays right for any font size.
                                Item {
                                    id: clockBlock
                                    anchors.fill: parent

                                    // The clock block is a clock and nothing
                                    // else. It used to be the timer editor: a
                                    // click replaced the time with a minutes
                                    // field, which meant the one number you
                                    // glance at to know what time it is was
                                    // also a form field that could be typed
                                    // over, and the length you actually wanted
                                    // to set was on the far side of the card.
                                    // The timer's own digits are editable now
                                    // (see the pomodoro half); this side only
                                    // tells the time.
                                    Item {
                                        anchors.fill: parent
                                    }

                                    Row {
                                        id: clockTimeRow
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.bottom: clockDate.top
                                        anchors.bottomMargin: 8
                                        spacing: 8
                                        StyledText {
                                            id: bigClockText
                                            text: Qt.locale().toString(tabClock.date, Config.options?.time.format ?? "hh:mm")
                                            // The lock screen's numbers family,
                                            // not monospace. This was the one
                                            // place in the card whose
                                            // typography was fighting the
                                            // reference rather than matching
                                            // it: monospaced digits hold a fixed
                                            // advance, so the clock read as
                                            // machine output beside the lock
                                            // screen's proportional figures,
                                            // and a "1" left a hole where a "0"
                                            // would have been.
                                            font.family: Appearance.font.family.numbers
                                            font.pixelSize: 76
                                            font.weight: Font.DemiBold
                                            color: Appearance.colors.colOnLayer0
                                        }
                                        StyledText {
                                            anchors.baseline: bigClockText.baseline
                                            text: Qt.locale().toString(tabClock.date, "ss")
                                            font.family: Appearance.font.family.numbers
                                            font.pixelSize: Appearance.font.pixelSize.normal
                                            color: Appearance.colors.colSubtext
                                        }
                                    }
                                    // The minutes field that used to live here
                                    // is gone with the rest of the clock editor:
                                    // editing the length now happens on the
                                    // timer's own digits, in the other half of
                                    // the card.

                                    StyledText {
                                        id: clockDate
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        // Half the time row plus the gap: the
                                        // pair's centre, not the date's, lands
                                        // on the half's centre line.
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.verticalCenterOffset: (8 + clockTimeRow.implicitHeight) / 2
                                        text: DateTime.collapsedCalendarFormat
                                        font.pixelSize: Appearance.font.pixelSize.small
                                        color: Appearance.colors.colSubtext
                                    }
                                }
                            }

                            // The divider: one hairline, inset, so the two
                            // halves read as two panels of one card.
                            Rectangle {
                                Layout.fillHeight: true
                                Layout.topMargin: 22
                                Layout.bottomMargin: 22
                                implicitWidth: 1
                                color: Appearance.colors.colOutlineVariant
                            }

                            // ── The pomodoro: redesigned for glanceability ──
                            // Phase chip up top (colour says focus/break at a
                            // distance), big countdown under it, a thin
                            // progress bar showing the lap draining, the cycle
                            // dots, then transport. Presets replace the +/-
                            // stepper: one tap = a known session shape.
                            Item {
                                id: pomoHalf
                                Layout.fillWidth: true
                                Layout.fillHeight: true

                                // "I am done editing": a click on the empty
                                // background around the boxes locks the value
                                // in, which is what Enter does.
                                //
                                // It lives in HERE, inside an Item, and that is
                                // the whole point. The first attempt put it in
                                // the RowLayout above as a third
                                // `Layout.fillWidth` child, which made the
                                // layout divide the row three ways instead of
                                // two: both halves lost width and the card got
                                // narrower for the sake of a click catcher. A
                                // layout manages its CHILDREN, so a catcher
                                // added as one is a participant whether it
                                // draws anything or not. Inside pomoHalf it is
                                // an ordinary child of an ordinary Item and the
                                // layout never sees it.
                                //
                                // Declared before the column, so it sits
                                // UNDER everything: a click on a box, a
                                // button, a chip or the progress bar is
                                // consumed by that thing, and only a click that
                                // reaches the background arrives here. Which is
                                // exactly what "the empty space around it"
                                // means, with nothing added to the screen.
                                MouseArea {
                                    anchors.fill: parent
                                    visible: root.timerEditing
                                    onClicked: root.commitTimerEdit()
                                }

                                // The editorial stack: a label, the numerals with their
                                // metadata on the right, a hairline for
                                // progress, and one quiet row of controls.
                                //
                                // Everything is LEFT aligned now. It used to
                                // be a centred stack -- pill, number, bar,
                                // buttons, chips -- five rows of equal
                                // weight, all of them shouting. A countdown
                                // is a figure, not a badge, and figures read
                                // from the left edge; centring them wasted
                                // the width the card already had and made
                                // every element on screen equally loud.
                                //
                                // `width` is the whole half because nothing
                                // sits beside it any more. It is still
                                // clamped at zero: a half can be narrower
                                // than zero on a very small island, and a
                                // negative width is a hard layout error.
                                Column {
                                    id: pomoColumn
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.max(0, pomoHalf.width)
                                    // 22, not 18 and not 30. The half is five
                                    // things tall -- eyebrow, numerals, rule,
                                    // controls -- and the gaps between them are
                                    // what make it read as one composed panel
                                    // rather than a list. Too tight and the
                                    // numerals collide with the rule they sit
                                    // on; too loose and the card stops being a
                                    // panel and becomes a poster with a widget
                                    // in it.
                                    spacing: 22

                                    // ── Finish alarm banner ──
                                    // The notification you can stop: appears
                                    // when a lap completes, carries the same
                                    // line the system notification shows, and
                                    // the ringtone loops until this button (or
                                    // any timer action) silences it.
                                    Rectangle {
                                        id: alarmBanner
                                        visible: TimerService.alarmActive
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        implicitWidth: alarmRow.implicitWidth + 28
                                        implicitHeight: 38
                                        radius: Appearance.rounding.full
                                        color: Qt.rgba(Appearance.colors.colError.r,
                                            Appearance.colors.colError.g,
                                            Appearance.colors.colError.b, 0.16)
                                        border.width: 1
                                        border.color: Appearance.colors.colError

                                        Row {
                                            id: alarmRow
                                            anchors.centerIn: parent
                                            spacing: 10

                                            MaterialSymbol {
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: "notifications_active"
                                                iconSize: 20
                                                color: Appearance.colors.colError
                                                SequentialAnimation on scale {
                                                    running: TimerService.alarmActive
                                                    loops: Animation.Infinite
                                                    NumberAnimation { to: 1.25; duration: 500; easing.type: Easing.InOutSine }
                                                    NumberAnimation { to: 1.0; duration: 500; easing.type: Easing.InOutSine }
                                                }
                                            }
                                            StyledText {
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: TimerService.alarmMessage !== ""
                                                    ? TimerService.alarmMessage
                                                    : Translation.tr("Timer finished")
                                                font.pixelSize: Appearance.font.pixelSize.small
                                                font.weight: Font.Medium
                                                color: Appearance.colors.colError
                                            }
                                            RippleButton {
                                                anchors.verticalCenter: parent.verticalCenter
                                                implicitWidth: 26
                                                implicitHeight: 26
                                                colRipple: Appearance.colors.colError
                                                onClicked: TimerService.stopAlarm()
                                                MaterialSymbol {
                                                    anchors.centerIn: parent
                                                    text: "close"
                                                    iconSize: 16
                                                    color: Appearance.colors.colError
                                                }
                                            }
                                        }
                                    }

                                // The eyebrow: what this half IS, not what phase it is
                                // in. 6px dot (pulsing while running) and a
                                // tracked-out uppercase word, no pill.
                                //
                                // It used to be a filled pill naming the PHASE
                                // -- and was tinted by phase before that, with
                                // focus in colError, so an ordinary running
                                // timer looked like something had gone wrong.
                                // Then the pill went but the words stayed
                                // centred above the numerals, which made a
                                // 60px badge compete with a 78px figure.
                                //
                                // The phase moved to the right of the
                                // numerals (see metaCol), where it annotates
                                // the number instead of heading it. What is
                                // left up here is the identity of the widget,
                                // set small enough to be furniture.
                                Row {
                                    id: phaseChip
                                    spacing: 8

                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 6; height: 6; radius: 3
                                        color: Appearance.colors.colOnLayer0
                                        SequentialAnimation on scale {
                                            running: TimerService.pomodoroRunning
                                            loops: Animation.Infinite
                                            NumberAnimation { to: 1.6; duration: 750; easing.type: Easing.InOutSine }
                                            NumberAnimation { to: 1.0; duration: 750; easing.type: Easing.InOutSine }
                                        }
                                    }
                                    StyledText {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: Translation.tr("timer")
                                        font.pixelSize: Appearance.font.pixelSize.tiny
                                        font.weight: Font.Medium
                                        font.letterSpacing: 1.4
                                        font.capitalization: Font.AllUppercase
                                        color: Appearance.colors.colOnLayer1Inactive
                                    }
                                }

                                // Numeral + metadata: the number on the left,
                                // the two facts you cannot read off it on the
                                // right. Same row, same baseline-ish, so the
                                // phase reads as an annotation of the time
                                // rather than a second control.
                                // The numeral and its own affordance. There
                                // is no metadata block beside it any more:
                                // the phase word and the lap counter were both
                                // describing a pomodoro cycle that no longer
                                // exists (see TimerService), and what is left
                                // to say -- that these digits can be edited --
                                // belongs touching the digits, not floating at
                                // the far end of the column.
                                Item {
                                    id: countdownSlot
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    height: 96
                                    StyledText {
                                        id: countdownText
                                        anchors.left: parent.left
                                        anchors.top: parent.top
                                        visible: !root.timerEditing
                                        text: DateTime.duration(TimerService.pomodoroSecondsLeft)
                                        font.family: Appearance.font.family.numbers
                                        font.pixelSize: 78
                                        font.weight: Font.Light
                                        font.letterSpacing: -2
                                        color: Appearance.colors.colOnLayer0
                                    }

                                        // The affordance, welded to the
                                        // numerals: immediately right of
                                        // the last digit, its bottom on
                                        // the digits' bottom edge.
                                        //
                                        // It has been three other things.
                                        // First 12px UNDER the digits, in
                                        // the seam between them and the
                                        // progress rule -- the busiest
                                        // line in the half, with the
                                        // smallest text on it. Then at the
                                        // far right of the column, beside
                                        // a phase word and a lap counter,
                                        // which is a different kind of
                                        // place entirely: those described
                                        // the timer, this describes a
                                        // target, and a target belongs
                                        // next to what it targets. Now it
                                        // is a subscript on the number.
                                        //
                                        // Anchored to countdownText rather
                                        // than to the slot, so it tracks the
                                        // digits as they change width:
                                        // "9:59" is narrower than "1:30:00"
                                        // and the label follows the last
                                        // zero instead of standing still
                                        // and letting the number run away
                                        // from it.
                                        StyledText {
                                            id: editHint
                                            anchors.left: countdownText.right
                                            anchors.leftMargin: 14
                                            anchors.bottom: countdownText.bottom
                                            anchors.bottomMargin: 10
                                            text: root.timerEditing
                                                ? Translation.tr("enter to apply")
                                                : Translation.tr("tap to set")
                                            font.pixelSize: Appearance.font.pixelSize.tiny
                                            font.letterSpacing: 1.2
                                            font.capitalization: Font.AllUppercase
                                            color: Appearance.colors.colOnLayer1Inactive
                                        }

                                    // The digits are the target, not the
                                    // whole row: the metadata beside them
                                    // is a label, not part of the number.
                                    MouseArea {
                                        anchors.left: parent.left
                                        anchors.top: parent.top
                                        width: Math.max(24, countdownText.width)
                                        height: countdownText.height
                                        visible: !root.timerEditing
                                        enabled: !root.timerEditing
                                        cursorShape: Qt.IBeamCursor
                                        onClicked: root.beginTimerEdit()
                                    }

                                    // Focus leaving the editor commits.
                                    // The delay is not cosmetic: QML moves
                                    // focus in the same event loop turn,
                                    // so the box that is LOSING focus is
                                    // asked before the box gaining it has
                                    // been given any, and a test written
                                    // there sees "nothing focused" while
                                    // the user is halfway through typing 1
                                    // into the hours. One frame of slack
                                    // is enough to tell a real departure
                                    // from an internal hop.
                                    Timer {
                                        id: focusSettle
                                        interval: 40
                                        onTriggered: {
                                            if (root.timerEditing && !durationBoxes.anyBoxFocused())
                                                root.commitTimerEdit();
                                        }
                                    }

                                    // The editor: one box per unit, hours
                                    // first, the way a duration is written
                                    // everywhere else. Left aligned with
                                    // the digits it replaces.
                                    Row {
                                        id: durationBoxes
                                        anchors.left: parent.left
                                        anchors.top: parent.top
                                        spacing: 4
                                        visible: root.timerEditing
                                        // ── hours ──
                                        Column {
                                            width: 58
                                            spacing: 6
                                            Rectangle {
                                                id: hoursFrame
                                                width: 58
                                                height: 54
                                                radius: Appearance.rounding.normal
                                                color: hoursBox.activeFocus
                                                    ? Qt.rgba(Appearance.colors.colOnLayer0.r,
                                                        Appearance.colors.colOnLayer0.g,
                                                        Appearance.colors.colOnLayer0.b, 0.10)
                                                    : Qt.rgba(Appearance.colors.colOnLayer0.r,
                                                        Appearance.colors.colOnLayer0.g,
                                                        Appearance.colors.colOnLayer0.b, 0.04)
                                                border.width: hoursBox.activeFocus ? 1.6 : 1
                                                border.color: hoursBox.activeFocus
                                                    ? Appearance.colors.colPrimary
                                                    : Appearance.colors.colOutlineVariant
                                                Behavior on border.color {
                                                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                                                }
                                                TextInput {
                                                    id: hoursBox
                                                    anchors.fill: parent
                                                    horizontalAlignment: TextInput.AlignHCenter
                                                    verticalAlignment: TextInput.AlignVCenter
                                                    font.family: Appearance.font.family.numbers
                                                    font.pixelSize: 30
                                                    font.weight: Font.DemiBold
                                                    color: Appearance.colors.colOnLayer0
                                                    selectionColor: Appearance.colors.colPrimary
                                                    selectedTextColor: Appearance.colors.colOnLayer0
                                                    // max + 1 on purpose: the
                                                    // overflow is what makes
                                                    // digit-by-digit
                                                    // substitution possible.
                                                    // Capped at max, the
                                                    // keystroke that should
                                                    // replace a digit is the
                                                    // one keystroke refused.
                                                    maximumLength: 3
                                                    inputMethodHints: Qt.ImhDigitsOnly
                                                    selectByMouse: true
                                                    validator: RegularExpressionValidator { regularExpression: /[0-9]{0,3}/ }
                                                    onActiveFocusChanged: focusSettle.restart()
                                                    onTextEdited: root.boxTyped(hoursBox, minutesBox, 2)
                                                    Keys.onPressed: event => root.boxKey(event, hoursBox, minutesBox, secondsBox, 2)
                                                    Keys.onEscapePressed: root.cancelTimerEdit()
                                                }
                                            }
                                            StyledText {
                                                width: parent.width
                                                horizontalAlignment: Text.AlignHCenter
                                                text: Translation.tr("hour")
                                                font.pixelSize: Appearance.font.pixelSize.tiny
                                                color: Appearance.colors.colOnLayer1Inactive
                                            }
                                        }
                                        StyledText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.verticalCenterOffset: -9
                                            width: 12
                                            horizontalAlignment: Text.AlignHCenter
                                            text: ":"
                                            font.family: Appearance.font.family.numbers
                                            font.pixelSize: 30
                                            color: Appearance.colors.colOnLayer1Inactive
                                        }
                                        // ── minutes ──
                                        Column {
                                            width: 58
                                            spacing: 6
                                            Rectangle {
                                                id: minutesFrame
                                                width: 58
                                                height: 54
                                                radius: Appearance.rounding.normal
                                                color: minutesBox.activeFocus
                                                    ? Qt.rgba(Appearance.colors.colOnLayer0.r,
                                                        Appearance.colors.colOnLayer0.g,
                                                        Appearance.colors.colOnLayer0.b, 0.10)
                                                    : Qt.rgba(Appearance.colors.colOnLayer0.r,
                                                        Appearance.colors.colOnLayer0.g,
                                                        Appearance.colors.colOnLayer0.b, 0.04)
                                                border.width: minutesBox.activeFocus ? 1.6 : 1
                                                border.color: minutesBox.activeFocus
                                                    ? Appearance.colors.colPrimary
                                                    : Appearance.colors.colOutlineVariant
                                                Behavior on border.color {
                                                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                                                }
                                                TextInput {
                                                    id: minutesBox
                                                    anchors.fill: parent
                                                    horizontalAlignment: TextInput.AlignHCenter
                                                    verticalAlignment: TextInput.AlignVCenter
                                                    font.family: Appearance.font.family.numbers
                                                    font.pixelSize: 30
                                                    font.weight: Font.DemiBold
                                                    color: Appearance.colors.colOnLayer0
                                                    selectionColor: Appearance.colors.colPrimary
                                                    selectedTextColor: Appearance.colors.colOnLayer0
                                                    maximumLength: 3
                                                    inputMethodHints: Qt.ImhDigitsOnly
                                                    selectByMouse: true
                                                    validator: RegularExpressionValidator { regularExpression: /[0-9]{0,3}/ }
                                                    onActiveFocusChanged: focusSettle.restart()
                                                    onTextEdited: root.boxTyped(minutesBox, secondsBox, 2)
                                                    Keys.onPressed: event => root.boxKey(event, minutesBox, hoursBox, secondsBox, 2)
                                                    Keys.onEscapePressed: root.cancelTimerEdit()
                                                }
                                            }
                                            StyledText {
                                                width: parent.width
                                                horizontalAlignment: Text.AlignHCenter
                                                text: Translation.tr("minute")
                                                font.pixelSize: Appearance.font.pixelSize.tiny
                                                color: Appearance.colors.colOnLayer1Inactive
                                            }
                                        }
                                        StyledText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.verticalCenterOffset: -9
                                            width: 12
                                            horizontalAlignment: Text.AlignHCenter
                                            text: ":"
                                            font.family: Appearance.font.family.numbers
                                            font.pixelSize: 30
                                            color: Appearance.colors.colOnLayer1Inactive
                                        }
                                        // ── seconds ──
                                        Column {
                                            width: 58
                                            spacing: 6
                                            Rectangle {
                                                id: secondsFrame
                                                width: 58
                                                height: 54
                                                radius: Appearance.rounding.normal
                                                color: secondsBox.activeFocus
                                                    ? Qt.rgba(Appearance.colors.colOnLayer0.r,
                                                        Appearance.colors.colOnLayer0.g,
                                                        Appearance.colors.colOnLayer0.b, 0.10)
                                                    : Qt.rgba(Appearance.colors.colOnLayer0.r,
                                                        Appearance.colors.colOnLayer0.g,
                                                        Appearance.colors.colOnLayer0.b, 0.04)
                                                border.width: secondsBox.activeFocus ? 1.6 : 1
                                                border.color: secondsBox.activeFocus
                                                    ? Appearance.colors.colPrimary
                                                    : Appearance.colors.colOutlineVariant
                                                Behavior on border.color {
                                                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                                                }
                                                TextInput {
                                                    id: secondsBox
                                                    anchors.fill: parent
                                                    horizontalAlignment: TextInput.AlignHCenter
                                                    verticalAlignment: TextInput.AlignVCenter
                                                    font.family: Appearance.font.family.numbers
                                                    font.pixelSize: 30
                                                    font.weight: Font.DemiBold
                                                    color: Appearance.colors.colOnLayer0
                                                    selectionColor: Appearance.colors.colPrimary
                                                    selectedTextColor: Appearance.colors.colOnLayer0
                                                    maximumLength: 3
                                                    inputMethodHints: Qt.ImhDigitsOnly
                                                    selectByMouse: true
                                                    validator: RegularExpressionValidator { regularExpression: /[0-9]{0,3}/ }
                                                    onActiveFocusChanged: focusSettle.restart()
                                                    onTextEdited: root.boxTyped(secondsBox, null, 2)
                                                    Keys.onPressed: event => root.boxKey(event, secondsBox, minutesBox, null, 2)
                                                    Keys.onEscapePressed: root.cancelTimerEdit()
                                                }
                                            }
                                            StyledText {
                                                width: parent.width
                                                horizontalAlignment: Text.AlignHCenter
                                                text: Translation.tr("second")
                                                font.pixelSize: Appearance.font.pixelSize.tiny
                                                color: Appearance.colors.colOnLayer1Inactive
                                            }
                                        }

                                        // Enter, from any box, applies -- handled in
                                        // root.boxKey, because the boxes are
                                        // separate inputs and only the focused one
                                        // would ever see a key press.
                                        //
                                        // Focus leaving the row entirely (a click on
                                        // the play button, the card closing)
                                        // commits too, so a half-typed duration is
                                        // never silently abandoned. It goes through
                                        // a short timer rather than being tested
                                        // inside the focus handler: focus moves
                                        // INSTANTLY from one box to the next, so at
                                        // the moment the old box's handler runs the
                                        // new one has not been given focus yet, and
                                        // a direct test there reads "nothing is
                                        // focused" and commits a value the user was
                                        // in the middle of typing.
                                        function anyBoxFocused() {
                                            return hoursBox.activeFocus || minutesBox.activeFocus || secondsBox.activeFocus;
                                        }
                                        }
                                }

                                // Lap progress: a hairline rule across the
                                // whole half, full at the start of the lap,
                                // empty at its end.
                                //
                                // It was a 4px rounded pill, 280px wide,
                                // floating in the middle of the half. In a
                                // stack of centred rows that made it one more
                                // element of equal weight -- a chunky bar
                                // pretending to be furniture -- and it was
                                // narrower than the numerals above it, so the
                                // card had two different widths in it. It is
                                // now the same measure as the column and 1px
                                // tall: the rule everything else is set on.
                                //
                                // The fill was colError on the focus phase, so
                                // this line used to be red -- the same red as
                                // the alarm banner. The alarm SHOULD be red;
                                // it is the one genuinely exceptional state.
                                // A running timer is not.
                                Rectangle {
                                    id: progressRule
                                    anchors.left: parent.left
                                    width: parent.width
                                    height: 1
                                    color: Appearance.colors.colOutlineVariant
                                    Rectangle {
                                        anchors.left: parent.left
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: TimerService.pomodoroLapDuration > 0
                                            ? Math.max(0, Math.min(1, TimerService.pomodoroSecondsLeft / TimerService.pomodoroLapDuration)) * parent.width
                                            : 0
                                        // 3px of fill on a 1px rule: the only
                                        // place in the half where a stroke is
                                        // allowed to be heavier than the
                                        // line it travels along, because it
                                        // is the one that has to be read at a
                                        // glance.
                                        height: 3
                                        radius: 1.5
                                        color: Appearance.colors.colOnLayer0
                                        Behavior on width {
                                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                                        }
                                    }
                                }

                                // The cycle dots are gone. They sat here as a
                                // row of four 8px circles whose only job was to
                                // say which lap of four you were on -- and the
                                // lap is already on screen as the number you
                                // care about, in a card that is mostly a
                                // countdown. They were also the only element in
                                // the half with a fixed pixel count, so the row
                                // changed width as the cycle count changed and
                                // everything around it shifted.

                                // Transport: start/pause · reset
                                //
                                // The skip-phase button is gone, along with
                                // TimerService.skipPomodoroPhase(). It jumped
                                // to the next lap from wherever you were --
                                // including out of a focus block you had not
                                // finished -- which is a mistake button with a
                                // friendly glyph on it. If a lap has to end
                                // early, the honest way to end it is to stop
                                // pressing play; there is nothing for this
                                // button to do that Reset plus a preset chip
                                // does not already do, only less destructively.
                                //
                                // Every remaining control says what it is.
                                //
                                // They were unlabelled glyphs, and
                                // `restart_alt` is a circular arrow that reads
                                // as "reload" or "try again" depending on who
                                // is looking. A caption settles that without a
                                // tooltip and without making anyone wait.
                                //
                                // One word each, deliberately. "Reset" is
                                // short and unambiguous; "Reset the timer" is
                                // more precise and is exactly the kind of
                                // caption that ends up wrapping to two lines
                                // and unbalancing the row.
                                //
                                // The captions are one word for a second
                                // reason: they sit UNDER the buttons, so a long
                                // one would push the row wider than the preset
                                // chips below it and break the alignment that
                                // makes the card read as one panel.
                                // The foot: lengths on the left as plain
                                // links, transport pinned right behind a
                                // hairline.
                                //
                                // The presets were five filled pills alone
                                // on a full-width row underneath everything
                                // else. Filled pills are the loudest thing
                                // in a half built from hairlines, and on
                                // their own row they read as the bottom of a
                                // form rather than as links. They are text
                                // now -- the selected one bold white on a
                                // wash, the rest grey -- which is what they
                                // always were, minus the shouting.
                                RowLayout {
                                    id: footRow
                                    width: parent.width
                                    spacing: 8

                                    // Session presets: one tap picks the
                                    // focus length. 10 (quick sprint), 25
                                    // (classic), 45 (deep block), 60 (long
                                    // haul), 90 (ultra).
                                    Row {
                                        id: presetRow
                                        Layout.alignment: Qt.AlignVCenter
                                        spacing: 2

                                        readonly property var presets: [
                                            { min: 10, label: "10" },
                                            { min: 25, label: "25" },
                                            { min: 45, label: "45" },
                                            { min: 60, label: "60" },
                                            { min: 90, label: "90" },
                                        ]

                                        Repeater {
                                            model: presetRow.presets

                                            RippleButton {
                                                id: presetLink
                                                required property var modelData
                                                readonly property bool activePreset:
                                                    Math.round(TimerService.focusTime / 60) === modelData.min
                                                implicitWidth: presetLinkLabel.implicitWidth + 16
                                                implicitHeight: 28
                                                buttonRadius: Appearance.rounding.normal
                                                colRipple: Appearance.colors.colLayer2Hover
                                                onClicked: TimerService.setPomodoroFocus(modelData.min * 60)

                                                Rectangle {
                                                    anchors.fill: parent
                                                    radius: Appearance.rounding.normal
                                                    color: presetLink.activePreset
                                                        ? Qt.rgba(Appearance.colors.colOnLayer0.r,
                                                            Appearance.colors.colOnLayer0.g,
                                                            Appearance.colors.colOnLayer0.b, 0.10)
                                                        : (presetLink.hovered ? Appearance.colors.colLayer2 : "transparent")
                                                    Behavior on color {
                                                        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                                                    }
                                                }
                                                StyledText {
                                                    id: presetLinkLabel
                                                    anchors.centerIn: parent
                                                    text: presetLink.modelData.label
                                                    font.pixelSize: Appearance.font.pixelSize.small
                                                    font.weight: presetLink.activePreset ? Font.DemiBold : Font.Medium
                                                    color: presetLink.activePreset
                                                        ? Appearance.colors.colOnLayer0
                                                        : Appearance.colors.colOnLayer1Inactive
                                                }
                                            }
                                        }

                                        // The unit, said once instead of five
                                        // times: it was "10 min" on every
                                        // chip, which spent the row on words
                                        // that are all the same word.
                                        StyledText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.leftMargin: 4
                                            text: Translation.tr("min")
                                            font.pixelSize: Appearance.font.pixelSize.tiny
                                            font.letterSpacing: 1.2
                                            font.capitalization: Font.AllUppercase
                                            color: Appearance.colors.colOnLayer1Inactive
                                        }
                                    }

                                    // The spring: everything between the
                                    // lengths and the transport is slack, so
                                    // the two groups sit at opposite ends
                                    // however wide the half is.
                                    Item {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 1
                                    }

                                    // The same hairline as the progress
                                    // rule, standing up. It says the
                                    // transport is a different kind of thing
                                    // from the settings beside it.
                                    Rectangle {
                                        Layout.alignment: Qt.AlignVCenter
                                        Layout.preferredWidth: 1
                                        Layout.preferredHeight: 30
                                        color: Appearance.colors.colOutlineVariant
                                    }

                                // The captions fade in on HOVER, after a beat.
                                //
                                // They were always on, which made the row read
                                // as a permanently labelled control bank --
                                // a line of text under every glyph, in a
                                // card that already names itself elsewhere. The
                                // labels are for the moment you are deciding
                                // which button is which, and that moment is
                                // when the pointer is on one of them.
                                //
                                // The 200ms is the important half. A caption
                                // that appears the instant the pointer crosses
                                // the button is noise: you cannot move toward a
                                // target you have not seen yet, and crossing
                                // the row on the way somewhere else would
                                // strobe labels on the way past. Waiting
                                // one beat means only a deliberate hover --
                                // stopping, not passing -- produces one, and
                                // that is exactly the intent the caption is
                                // there to serve.
                                //
                                // The space is RESERVED, not collapsed: the
                                // caption is always in the Column and only its
                                // opacity changes. A Positioner skips invisible
                                // children, so making it `visible: false` would
                                // shrink the Column and shove the whole half of
                                // the card upward the moment the pointer left
                                // the button.

                                    Column {
                                        Layout.alignment: Qt.AlignTop
                                        // Dropped so the GLYPH sits on the
                                        // same line as the length links.
                                        //
                                        // 21 is not a taste decision, it is
                                        // the two heights cancelling out. The
                                        // column is 63 tall (42 button + 7
                                        // gap + ~14 reserved caption), which
                                        // makes the row 63 + t tall; the
                                        // 28-tall links then centre at
                                        // t/2 + 31.5 and the glyph at t +
                                        // 21. Those are equal when t = 21.
                                        // Guessing t = 10 -- half of the
                                        // visible offset -- puts the glyph
                                        // 5px high, because raising the
                                        // transport also raises the row it
                                        // is centred in.
                                        Layout.topMargin: 21
                                        Layout.fillHeight: false
                                        id: playCol
                                        // 66 -> 46. The column is sized for
                                        // the CAPTION ("Start" / "Pause" is
                                        // ~28px at `tiny`), not for the
                                        // button, and 66 left 12px of dead
                                        // air either side of a 42px pad. Two
                                        // of those columns plus the 8px row
                                        // spacing put 34px between the play
                                        // and reset glyphs -- which is why
                                        // the reset read as a separate thing
                                        // parked at the far end rather than
                                        // the second half of one transport.
                                        // 46 leaves a 12px gap between the
                                        // two buttons and still fits the
                                        // longest caption.
                                        width: 46
                                        spacing: 7
                                        property bool labelOn: false
                                        Timer {
                                            id: playLabelTimer
                                            interval: 200
                                            onTriggered: playCol.labelOn = true
                                        }
                                        HoverHandler {
                                            onHoveredChanged: {
                                                if (hovered) playLabelTimer.restart();
                                                else playCol.labelOn = false;
                                            }
                                        }
                                        RippleButton {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            implicitWidth: 42; implicitHeight: 42
                                            buttonRadius: Appearance.rounding.full
                                            colRipple: Appearance.colors.colPrimary
                                            onClicked: TimerService.togglePomodoro()
                                            MaterialSymbol {
                                                anchors.centerIn: parent
                                                text: TimerService.pomodoroRunning ? "pause" : "play_arrow"
                                                iconSize: 24
                                                fill: 1
                                                color: Appearance.colors.colOnLayer0
                                            }
                                        }
                                        StyledText {
                                            width: parent.width
                                            horizontalAlignment: Text.AlignHCenter
                                            // Play/pause's glyph is colOnLayer0,
                                            // the same as the other two, NOT
                                            // colOnPrimary. colOnPrimary is a
                                            // colour meant to sit ON the accent,
                                            // and there is no accent behind it
                                            // here: this button has no
                                            // background, so that glyph was
                                            // painted straight onto the card in
                                            // a colour chosen to be readable
                                            // against a fill that is not there.
                                            // It read as the dimmest thing on
                                            // screen while being the control
                                            // people press most. (The same
                                            // mistake existed in the media hero,
                                            // where it was fixed by GIVING the
                                            // button the accent disc; here the
                                            // button is a bare glyph, so the
                                            // colour is what has to change.)
                                            text: TimerService.pomodoroRunning
                                                ? Translation.tr("Pause")
                                                : Translation.tr("Start")
                                            font.pixelSize: Appearance.font.pixelSize.tiny
                                            color: Appearance.colors.colSubtext
                                            opacity: playCol.labelOn ? 1 : 0
                                            Behavior on opacity {
                                                NumberAnimation { duration: 120 }
                                            }
                                        }
                                    }

                                    Column {
                                        Layout.alignment: Qt.AlignTop
                                        // The same drop as playCol, and for
                                        // the same reason: the arithmetic is
                                        // written out there.
                                        Layout.topMargin: 21
                                        Layout.fillHeight: false
                                        id: resetCol
                                        // The same 46 as playCol, for the
                                        // same reason: the two buttons have to
                                        // be the same distance from their
                                        // captions and the same distance from
                                        // each other, or the pair reads as
                                        // one big button and one stray glyph.
                                        width: 46
                                        spacing: 7
                                        property bool labelOn: false
                                        Timer {
                                            id: resetLabelTimer
                                            interval: 200
                                            onTriggered: resetCol.labelOn = true
                                        }
                                        HoverHandler {
                                            onHoveredChanged: {
                                                if (hovered) resetLabelTimer.restart();
                                                else resetCol.labelOn = false;
                                            }
                                        }
                                        RippleButton {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            // 38 -> 42, the play button's size.
                                            // They are one control in two parts;
                                            // a smaller reset beside a bigger
                                            // play is a hierarchy nobody asked
                                            // for, and the ripple of the smaller
                                            // one visibly did not match the
                                            // larger one's hit area.
                                            implicitWidth: 42; implicitHeight: 42
                                            buttonRadius: Appearance.rounding.full
                                            colRipple: Appearance.colors.colLayer1Hover
                                            onClicked: TimerService.resetPomodoro()
                                            MaterialSymbol {
                                                anchors.centerIn: parent
                                                text: "restart_alt"
                                                // 20 -> 21, and this one is
                                                // MEASURED rather than guessed:
                                                // play_arrow at em 24 has 18.0px
                                                // of ink, restart_alt at em 20
                                                // had 17.0, and at em 21 it is
                                                // 18.0 -- the two marks now
                                                // stand the same height, so the
                                                // row does not read as a big
                                                // triangle beside a small
                                                // circular arrow.
                                                iconSize: 21
                                                color: Appearance.colors.colOnLayer0
                                            }
                                        }
                                        StyledText {
                                            width: parent.width
                                            horizontalAlignment: Text.AlignHCenter
                                            text: Translation.tr("Reset")
                                            font.pixelSize: Appearance.font.pixelSize.tiny
                                            color: Appearance.colors.colSubtext
                                            opacity: resetCol.labelOn ? 1 : 0
                                            Behavior on opacity {
                                                NumberAnimation { duration: 120 }
                                            }
                                        }
                                    }
                                }

                                }

                            }
                        }
                    }
                }

// 3 · Local AI: the llama.cpp server, running or not
                    //
                    // This replaces a four-week subscription-heat grid read from
                    // FlareData -- how much Claude/ChatGPT quota was left, which
                    // is a fact about somebody else's server. What is here is a
                    // fact about a process on this machine: whether it is up,
                    // how fast it is generating right now, which slots are
                    // working, and the control to start and stop it.
                    //
                    // The Sampling panel the first design had is GONE, and that
                    // is a correction rather than a cut. `POST /props` on this
                    // build answers `{"success":true}` and changes nothing:
                    // GET /props still returns the launch default and a fresh
                    // request's slot params still carry the old temperature. A
                    // slider that moves and means nothing is worse than no
                    // slider, so this pane is the server's own log instead --
                    // the only honest answer to "what is it actually doing".
                    PanelFadeView {
                        id: aiConsole
                        on: root.mode === root.modeAi
                        viewIndex: root.modeAi

                        // Tell the service when a number is worth fetching.
                        //
                        // Driven by the PANEL being open AND this being the
                        // selected mode -- NOT by `onVisibleChanged` on this
                        // item. `PanelFadeView` is a FocusScope whose `visible`
                        // is a BINDING to its own opacity (it stays visible
                        // while sliding between tabs so the crossfade has
                        // something to draw on), and a FocusScope is not a
                        // visible item in the first place. Listening for
                        // `visible` here therefore never fired: `tabVisible`
                        // stayed false with the panel open on this tab, and
                        // because the expensive endpoints are gated on it, the
                        // slots and tok/s quietly stayed at zero.
                        Component.onCompleted: root._syncAiClaim()
                        Component.onDestruction: LlamaService.release("panel")

                        // The offline->online motion. One property drives the
                        // whole body, so the change of state reads as the card
                        // changing rather than as a dozen rows animating apart.
                        readonly property real aiFade: LlamaService.online ? 1 : 0

                        // ── OFFLINE: the same card, filled ──────────────
                        //
                        // Not an error and not an empty state: a local model
                        // server being off is the NORMAL condition, so this
                        // shows what you could run and how it would be run.
                        // The models are real -- a scan of ~/Models for .gguf
                        // with byte sizes -- so this is a list, not a label.
                        Rectangle {
                            id: aiBody
                            anchors.fill: parent
                            anchors.margins: 2
                            radius: Appearance.rounding.small + 2
                            color: Appearance.colors.colLayer1
                            border.width: 1
                            border.color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.82)
                            // The pane scrolls (below). A scrolled child
                            // paints wherever contentY puts it, so without this
                            // the rounded card would leak rows past its border.
                            clip: true
                            opacity: 1 - aiConsole.aiFade
                            visible: opacity > 0.01
                            enabled: opacity > 0.5

                            Behavior on opacity {
                                NumberAnimation {
                                    duration: aiConsole.aiFade > 0 ? 260 : 180
                                    easing.type: Easing.OutCubic
                                }
                            }

                            // THE OFFLINE PANE IS ONE SCROLLABLE COLUMN.
                            //
                            // It used to be a ColumnLayout pinned with
                            // anchors.fill, so its height was the panel's and
                            // whatever did not fit simply kept going: seven
                            // parameter rows, the fixed-args note, the
                            // per-slot line and the argv block ran past the
                            // bottom of the card and off the panel, with the
                            // last row sitting half outside the rounded
                            // border. A ColumnLayout cannot scroll, so that
                            // overflow had nowhere to go and nothing to reach
                            // it with.
                            //
                            // StyledFlickable is the shell's own scrolling
                            // surface (wheel + touchpad gain + fling +
                            // scrollbar), so the last argument is as
                            // reachable as the first.
                            StyledFlickable {
                                id: aiOfflineScroll
                                anchors.fill: parent
                                anchors.margins: 10
                                contentWidth: width
                                contentHeight: aiOfflineCol.implicitHeight
                                clip: true

                                // AsNeeded, not AlwaysOn. This pane is sized to FIT: the
                                // three blocks -- model list, launch
                                // configuration, endpoint -- are laid out to
                                // the panel's height, so with the usual one or
                                // two models there is nothing to scroll and a
                                // permanently-drawn bar advertised a movement
                                // that does not exist.
                                //
                                // It is still here rather than removed, and
                                // that is deliberate: the one case that
                                // genuinely overflows is a long model list, and
                                // a bar that appears then is the difference
                                // between "there is more below" and a last row
                                // silently cut off by the clip.
                                ScrollBar.vertical: StyledScrollBar {
                                    policy: ScrollBar.AsNeeded
                                }

                                ColumnLayout {
                                    id: aiOfflineCol
                                    // 6px narrower than the viewport: the
                                    // scrollbar thumb is an overlay, and
                                    // without this it lands on the card's own
                                    // right border.
                                    width: Math.max(0, aiOfflineScroll.width - 6)
                                    spacing: 10

                                // The models block. Its own spacing is 8: the
                                // header is a label for what is under it, so
                                // it sits closer to the list than the list
                                // sits to the endpoint card below.
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 8

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8
                                        MaterialSymbol {
                                            text: "deployed_code"
                                            // Matched to the 15px header face
                                            // below, so the glyph's cap height
                                            // and the text's read as one line
                                            // rather than as a large icon
                                            // next to small text.
                                            iconSize: 16
                                            color: Appearance.colors.colPrimary
                                        }
                                        StyledText {
                                            text: Translation.tr("Models on disk")
                                            font.pixelSize: Appearance.font.pixelSize.small
                                            font.weight: Font.DemiBold
                                            color: Appearance.colors.colOnLayer0
                                        }
                                        Item { Layout.fillWidth: true }
                                        TapHandler {
                                            cursorShape: Qt.PointingHandCursor
                                            onTapped: LlamaService.scan()
                                        }
                                        MaterialSymbol {
                                            text: "refresh"
                                            iconSize: 15
                                            color: Appearance.colors.colSubtext
                                        }
                                    }

                                    Repeater {
                                        model: LlamaService.models
                                        delegate: Rectangle {
                                            id: modelDelegate
                                            required property var modelData
                                            required property int index
                                            // Compared by PATH, not by `selectedModel === modelData`. The
                                            // models are plain JS objects handed to a Repeater
                                            // through a `property var` array, and the
                                            // delegate's `modelData` is not the same
                                            // reference the service holds -- so the
                                            // identity test was always false and the
                                            // selection marker (the row border and the
                                            // "next" pill) never appeared for any
                                            // model, selected or not. The path is
                                            // unique per file and is what `-m` is
                                            // given, so it is the honest identity.
                                            readonly property bool next: LlamaService.selectedModel !== null
                                                && LlamaService.selectedModel.path === modelData.path
                                            Layout.fillWidth: true
                                            // 38 was sized for ONE line of text
                                            // but this row has always carried
                                            // TWO (name, then size · path), so
                                            // the second sat under the clip and a
                                            // long model name pushed it out
                                            // entirely.
                                            //
                                            // 54 is the same measurement at the
                                            // type scale the rest of the tab
                                            // settled on: a 16px name line and a
                                            // 12px meta line are ~36px of text,
                                            // plus 18px of margin. It is a
                                            // deliberately generous row -- the
                                            // model list is the main thing this
                                            // tab is for, and a list crammed
                                            // against 9px margins reads as an
                                            // afterthought.
                                            implicitHeight: 54
                                            radius: Appearance.rounding.small
                                            color: modelDelegate.hovered
                                                ? ColorUtils.transparentize(Appearance.colors.colLayer1Hover, 0.45)
                                                : ColorUtils.transparentize(Appearance.colors.colLayer0, 0.45)
                                            border.width: modelDelegate.next ? 1 : 0
                                            border.color: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.4)
                                            property bool hovered: false
                                            HoverHandler {
                                                cursorShape: Qt.PointingHandCursor
                                                onHoveredChanged: modelDelegate.hovered = hovered
                                            }
                                            // Clicking a model now picks it, which is
                                            // what makes `-m` a parameter like
                                            // every other row. This used to be
                                            // `index === 0` -- a badge on a choice
                                            // the panel never actually offered.
                                            TapHandler {
                                                cursorShape: Qt.PointingHandCursor
                                                onTapped: LlamaService.selectModel(modelDelegate.index)
                                            }

                                            RowLayout {
                                                anchors.fill: parent
                                                anchors.margins: 9
                                                spacing: 10

                                                // 24, not 20: at the new type
                                                // scale a 20px tile beside a
                                                // 16px name looked like an
                                                // initial dropped into the row
                                                // rather than a deliberate mark.
                                                Rectangle {
                                                    Layout.alignment: Qt.AlignVCenter
                                                    width: 24; height: 24; radius: 6
                                                    color: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.85)
                                                    StyledText {
                                                        anchors.centerIn: parent
                                                        text: modelData.name.substring(0, 1).toUpperCase()
                                                        font.pixelSize: Appearance.font.pixelSize.smaller
                                                        font.weight: Font.DemiBold
                                                        color: Appearance.colors.colPrimary
                                                    }
                                                }

                                                ColumnLayout {
                                                    Layout.fillWidth: true
                                                    spacing: 1
                                                    StyledText {
                                                        Layout.fillWidth: true
                                                        text: modelData.name
                                                        font.pixelSize: Appearance.font.pixelSize.normal
                                                        color: Appearance.colors.colOnLayer0
                                                        elide: Text.ElideRight
                                                    }
                                                    StyledText {
                                                        Layout.fillWidth: true
                                                        // The size is the file's real
                                                        // byte count from the scan.
                                                        text: `${modelData.sizeText} · ${modelData.path}`
                                                        font.pixelSize: Appearance.font.pixelSize.smaller
                                                        color: Appearance.colors.colSubtext
                                                        elide: Text.ElideMiddle
                                                    }
                                                }

                                                // PLAY, on the model it belongs
                                                // to. This used to be a single
                                                // Start button on the endpoint
                                                // card, which meant the tab made
                                                // you select a model and then go
                                                // somewhere else to run it --
                                                // two places to look and one way
                                                // to get it wrong. The button is
                                                // on the row, so the model you
                                                // press is the model that
                                                // starts; nothing is selected
                                                // implicitly.
                                                //
                                                // It becomes the row's Stop
                                                // button while THAT model is the
                                                // one serving, and it is disabled
                                                // outright while another model is
                                                // up: starting a second server on
                                                // the same port cannot work, and
                                                // a button that silently does
                                                // nothing is worse than one that
                                                // looks unavailable.
                                                Rectangle {
                                                    id: runBtn
                                                    Layout.alignment: Qt.AlignVCenter
                                                    width: 30
                                                    height: 30
                                                    radius: Appearance.rounding.full
                                                    readonly property bool running: modelDelegate.next
                                                        && (LlamaService.online || LlamaService.loading)
                                                    readonly property bool usable: runBtn.running
                                                        ? !LlamaService.busy
                                                        : (!LlamaService.online && !LlamaService.loading && !LlamaService.busy)
                                                    color: !runBtn.usable
                                                        ? "transparent"
                                                        : (runBtn.hovered
                                                            ? ColorUtils.transparentize(runBtn.running ? Appearance.colors.colError : Appearance.colors.colPrimary, 0.82)
                                                            : ColorUtils.transparentize(runBtn.running ? Appearance.colors.colError : Appearance.colors.colPrimary, 0.9))
                                                    border.width: runBtn.usable ? 1 : 0
                                                    border.color: ColorUtils.transparentize(
                                                        runBtn.running ? Appearance.colors.colError : Appearance.colors.colPrimary, 0.55)
                                                    opacity: runBtn.usable ? 1 : 0.35
                                                    property bool hovered: false

                                                    Behavior on color {
                                                        ColorAnimation { duration: 110 }
                                                    }
                                                    Behavior on opacity {
                                                        NumberAnimation { duration: 110 }
                                                    }

                                                    HoverHandler {
                                                        enabled: runBtn.usable
                                                        cursorShape: Qt.PointingHandCursor
                                                        onHoveredChanged: runBtn.hovered = hovered
                                                    }
                                                    TapHandler {
                                                        enabled: runBtn.usable
                                                        onTapped: {
                                                            if (runBtn.running) {
                                                                LlamaService.stop();
                                                            } else {
                                                                // Order matters: `start()`
                                                                // launches `-m` from the
                                                                // SELECTED model, so the
                                                                // selection has to move to
                                                                // this row first or the
                                                                // button would start the
                                                                // wrong one.
                                                                LlamaService.selectModel(modelDelegate.index);
                                                                LlamaService.start();
                                                            }
                                                        }
                                                    }

                                                    MaterialSymbol {
                                                        anchors.centerIn: parent
                                                        text: runBtn.running ? "stop" : "play_arrow"
                                                        iconSize: 16
                                                        color: runBtn.running
                                                            ? Appearance.colors.colError
                                                            : Appearance.colors.colPrimary
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    // Shown only when the scan genuinely found
                                    // nothing -- NOT a placeholder while it
                                    // runs, which would flash on every open.
                                    StyledText {
                                        Layout.fillWidth: true
                                        visible: LlamaService.models.length === 0
                                        text: Translation.tr("No .gguf models found in ~/Models")
                                        font.pixelSize: Appearance.font.pixelSize.smallie
                                        color: Appearance.colors.colSubtext
                                        wrapMode: Text.WordWrap
                                    }
                                }

                                // WHAT A START WILL ACTUALLY DO.
                                //
                                // These three numbers decide what pressing play
                                // on a model really runs: how much context the
                                // server keeps, how much of the model is put on
                                // the GPU, and how many conversations it serves
                                // at once. They are edited in the settings
                                // window, which is the right place to change
                                // them and the wrong place to check them --
                                // so this is the read-only echo.
                                //
                                // The value is bright only when it DIFFERS from
                                // the default, which is the thing actually worth
                                // knowing at a glance: not what a setting says,
                                // but whether you changed it.
                                Rectangle {
                                    Layout.fillWidth: true
                                    implicitHeight: launchInfoCol.implicitHeight + 24
                                    radius: Appearance.rounding.small
                                    color: ColorUtils.transparentize(Appearance.colors.colLayer0, 0.45)
                                    border.width: 1
                                    border.color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.85)

                                    ColumnLayout {
                                        id: launchInfoCol
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        anchors.margins: 12
                                        spacing: 10

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 7
                                            MaterialSymbol {
                                                text: "tune"
                                                iconSize: 16
                                                color: Appearance.colors.colPrimary
                                            }
                                            StyledText {
                                                text: Translation.tr("Launch configuration")
                                                font.pixelSize: Appearance.font.pixelSize.small
                                                font.weight: Font.DemiBold
                                                color: Appearance.colors.colOnLayer0
                                            }
                                            Item { Layout.fillWidth: true }
                                            StyledText {
                                                text: LlamaService.overrideCount > 0
                                                    ? Translation.tr("%1 changed").arg(LlamaService.overrideCount)
                                                    : Translation.tr("defaults")
                                                font.pixelSize: Appearance.font.pixelSize.smaller
                                                color: Appearance.colors.colSubtext
                                            }
                                        }

                                        Repeater {
                                            // Only the three that change what is
                                            // actually computed. Host, port and
                                            // the two switches are settings, but
                                            // they are not what anyone opens this
                                            // tab to check.
                                            model: [
                                                { key: "ctx", label: Translation.tr("Context") },
                                                { key: "ngl", label: Translation.tr("GPU layers") },
                                                { key: "parallel", label: Translation.tr("Parallel slots") },
                                            ]
                                            delegate: RowLayout {
                                                id: infoRow
                                                required property var modelData
                                                Layout.fillWidth: true
                                                spacing: 10

                                                StyledText {
                                                    Layout.fillWidth: true
                                                    text: infoRow.modelData.label
                                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                                    color: Appearance.colors.colSubtext
                                                    elide: Text.ElideRight
                                                }
                                                StyledText {
                                                    text: root.fmtLaunchParam(infoRow.modelData.key)
                                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                                    font.weight: Font.Medium
                                                    color: LlamaService.isDefault(infoRow.modelData.key)
                                                        ? Appearance.colors.colSubtext
                                                        : Appearance.colors.colPrimary
                                                }
                                            }
                                        }

                                    }
                                }

                                // The address, and the one button that opens the settings.
                                                                //
                                                                // This card used to hold all seven launch
                                                                // parameters, and it is the reason this tab
                                                                // felt like a wall of controls: the popup is
                                                                // 460px tall, so the settings had to be small
                                                                // to fit, which made them hard to aim at, and
                                                                // the two facts anyone opens this tab for --
                                                                // which model, and where the server will be --
                                                                // were the two things squeezed to make room.
                                                                //
                                                                // So the settings moved to their own window
                                                                // (LlamaSettingsWindow) and this keeps the
                                                                // facts.
                                                                Rectangle {
                                                                    Layout.fillWidth: true
                                                                    implicitHeight: endpointCol.implicitHeight + 24
                                                                    radius: Appearance.rounding.small
                                                                    color: ColorUtils.transparentize(Appearance.colors.colLayer0, 0.45)
                                                                    border.width: 1
                                                                    border.color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.85)

                                                                    ColumnLayout {
                                                                        id: endpointCol
                                                                        anchors.left: parent.left
                                                                        anchors.right: parent.right
                                                                        anchors.top: parent.top
                                                                        anchors.margins: 12
                                                                        spacing: 12

                                                                        RowLayout {
                                                                            Layout.fillWidth: true
                                                                            spacing: 7
                                                                            MaterialSymbol {
                                                                                text: "lan"
                                                                                iconSize: 16
                                                                                color: Appearance.colors.colPrimary
                                                                            }
                                                                            StyledText {
                                                                                text: Translation.tr("Endpoint")
                                                                                font.pixelSize: Appearance.font.pixelSize.small
                                                                                font.weight: Font.DemiBold
                                                                                color: Appearance.colors.colOnLayer0
                                                                            }
                                                                            Item { Layout.fillWidth: true }
                                                                            // The state, in one word, next to the
                                                                            // address it belongs to.
                                                                            StyledText {
                                                                                text: LlamaService.online
                                                                                    ? Translation.tr("running")
                                                                                    : (LlamaService.loading ? Translation.tr("starting…") : Translation.tr("stopped"))
                                                                                // 12, not 10: this word is the live
                                                                                // state of the server, and at the
                                                                                // smallest step it was too small
                                                                                // to be read at a glance from
                                                                                // across a desk.
                                                                                font.pixelSize: Appearance.font.pixelSize.smaller
                                                                                color: LlamaService.online
                                                                                    ? Appearance.colors.colPrimary
                                                                                    : Appearance.colors.colSubtext
                                                                            }
                                                                        }

                                                                        // THE ADDRESS, shown only while the
                                                                        // server is actually up.
                                                                        //
                                                                        // It used to be the headline of the
                                                                        // tab whether or not anything was
                                                                        // running, which made a stopped
                                                                        // server look like a live one: the
                                                                        // tab's loudest text was an
                                                                        // address nothing was listening
                                                                        // on. Now the address appears when
                                                                        // there is something to reach, and
                                                                        // the card says what to do instead
                                                                        // when there is not.
                                                                        StyledText {
                                                                            Layout.fillWidth: true
                                                                            visible: LlamaService.online || LlamaService.loading
                                                                            text: `${LlamaService.host}:${LlamaService.port}`
                                                                            // `larger` (19), not `title` (22).
                                                                            // It is still the headline of this
                                                                            // card, but at 22 it was shouting
                                                                            // the only string in the tab that
                                                                            // nobody needs to read -- the
                                                                            // address is a fact to confirm, not
                                                                            // content. 19 keeps it a headline
                                                                            // while the model names sit at 16.
                                                                            font.pixelSize: Appearance.font.pixelSize.larger
                                                                            font.family: "JetBrains Mono"
                                                                            font.weight: Font.DemiBold
                                                                            color: Appearance.colors.colPrimary
                                                                            elide: Text.ElideRight
                                                                        }

                                                                        StyledText {
                                                                            Layout.fillWidth: true
                                                                            visible: LlamaService.online || LlamaService.loading
                                                                            // While it is up, the two facts that
                                                                            // actually tell you whether it is
                                                                            // worth keeping up: how long it has
                                                                            // been serving, and how many of the
                                                                            // parallel slots are busy.
                                                                            text: LlamaService.online
                                                                                ? `${Translation.tr("up")} ${root.fmtUptime(LlamaService.uptimeSeconds)} · ${LlamaService.busySlots}/${LlamaService.totalSlots} ${Translation.tr("slots busy")}`
                                                                                : Translation.tr("Waiting for the server to answer…")
                                                                            font.pixelSize: Appearance.font.pixelSize.smaller
                                                                            color: Appearance.colors.colSubtext
                                                                            wrapMode: Text.WordWrap
                                                                        }

                                                                        StyledText {
                                                                            Layout.fillWidth: true
                                                                            visible: !LlamaService.online && !LlamaService.loading
                                                                            text: Translation.tr("Nothing is serving yet. Press play on a model to start the server.")
                                                                            font.pixelSize: Appearance.font.pixelSize.smaller
                                                                            color: Appearance.colors.colSubtext
                                                                            wrapMode: Text.WordWrap
                                                                        }

                                                                        RowLayout {
                                                                            Layout.fillWidth: true
                                                                            Layout.topMargin: 2
                                                                            spacing: 8

                                                                            // The only control left on this
                                                                            // card, and the reason the card
                                                                            // still exists at all once the
                                                                            // Start button moved onto the
                                                                            // model rows. Labelled with what
                                                                            // is inside it, because a button
                                                                            // that says "Settings" and a tab
                                                                            // that used to hold them are
                                                                            // different places to look.
                                                                            RippleButton {
                                                                                buttonText: Translation.tr("Launch settings")
                                                                                Layout.fillWidth: true
                                                                                implicitHeight: 36
                                                                                // A resting FILL, because the
                                                                                // widget's default is a fully
                                                                                // transparent background: next to
                                                                                // an outlined Start button that
                                                                                // left "Launch settings" as
                                                                                // bare text floating in the row,
                                                                                // which read as a label nobody
                                                                                // had styled. A quiet surface
                                                                                // makes it the secondary action
                                                                                // it actually is.
                                                                                colBackground: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.93)
                                                                                colBackgroundHover: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.87)
                                                                                releaseAction: () => { LlamaService.settingsOpen = true; }
                                                                            }
                                                                        }
                                                                    }
                                                                }
                            }
                                }
                        }

                        // ── ONLINE: the console ───────────────────────────
                        //
                        // Crossfaded against the offline pane by the same
                        // aiFade, so the two states are one card changing
                        // rather than two cards swapping. The offline pane is
                        // only faded, never destroyed, which is why Stop puts
                        // it straight back.
                        Rectangle {
                            id: aiLive
                            anchors.fill: parent
                            anchors.margins: 2
                            radius: Appearance.rounding.small + 2
                            color: "transparent"
                            opacity: aiConsole.aiFade
                            visible: opacity > 0.01
                            enabled: opacity > 0.5

                            Behavior on opacity {
                                NumberAnimation {
                                    duration: aiConsole.aiFade > 0 ? 320 : 160
                                    easing.type: Easing.OutCubic
                                }
                            }

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 12
                                spacing: 9

                                // Hero: who is loaded, and the one control.
                                Rectangle {
                                    Layout.fillWidth: true
                                    implicitHeight: heroRow.implicitHeight + 18
                                    radius: Appearance.rounding.small
                                    color: ColorUtils.transparentize(Appearance.colors.colLayer1, 0.5)
                                    border.width: 1
                                    // A start takes about four seconds, and a
                                    // border that pulses says "working" where a
                                    // frozen one would read as "failed".
                                    border.color: LlamaService.loading
                                        ? ColorUtils.applyAlpha(Appearance.colors.colPrimary, 0.35 + 0.35 * heroPulse.value)
                                        : ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.82)

                                    SequentialAnimation on border.color {
                                        running: LlamaService.loading
                                        loops: Animation.Infinite
                                        NumberAnimation {
                                            target: heroPulse; property: "value"
                                            to: 1; duration: 900; easing.type: Easing.InOutSine
                                        }
                                        NumberAnimation {
                                            target: heroPulse; property: "value"
                                            to: 0; duration: 900; easing.type: Easing.InOutSine
                                        }
                                    }
                                    QtObject { id: heroPulse; property real value: 0 }

                                    RowLayout {
                                        id: heroRow
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        anchors.margins: 9
                                        spacing: 9

                                        Rectangle {
                                            Layout.alignment: Qt.AlignVCenter
                                            width: 9; height: 9; radius: 4.5
                                            color: Appearance.colors.colPrimary
                                            // Breathes only while work is
                                            // happening: a heartbeat on an idle
                                            // server is noise dressed as
                                            // activity.
                                            SequentialAnimation on opacity {
                                                running: LlamaService.busySlots > 0
                                                loops: Animation.Infinite
                                                NumberAnimation { to: 0.3; duration: 850; easing.type: Easing.InOutSine }
                                                NumberAnimation { to: 1.0; duration: 850; easing.type: Easing.InOutSine }
                                            }
                                        }

                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 1
                                            StyledText {
                                                Layout.fillWidth: true
                                                text: LlamaService.modelSummary
                                                font.pixelSize: Appearance.font.pixelSize.normal
                                                font.weight: Font.DemiBold
                                                color: Appearance.colors.colOnLayer0
                                                elide: Text.ElideRight
                                            }
                                            StyledText {
                                                Layout.fillWidth: true
                                                text: LlamaService.loading
                                                    ? Translation.tr("loading model…")
                                                    : `${LlamaService.addressText} · ${LlamaService.buildInfo} · up ${LlamaService.uptimeText}`
                                                font.pixelSize: Appearance.font.pixelSize.tiny
                                                color: Appearance.colors.colSubtext
                                                elide: Text.ElideRight
                                            }
                                        }

                                        // ONE control that ALTERNATES, not a
                                        // pair: green Run while nothing is up,
                                        // red Stop while it is. The label names
                                        // the action the press will take, so
                                        // there is never a dimmed twin sitting
                                        // beside it saying nothing.
                                        RowLayout {
                                            Layout.alignment: Qt.AlignVCenter
                                            spacing: 6

                                            // Green Run while stopped, red Stop
                                            // while running. `running` drives the
                                            // glyph, the word and the colour from
                                            // one value, so they cannot disagree.
                                            Rectangle {
                                                id: heroPowerBtn
                                                Layout.alignment: Qt.AlignVCenter
                                                implicitWidth: heroPowerRow.implicitWidth + 18
                                                implicitHeight: 28
                                                radius: Appearance.rounding.full
                                                // The same green the shell uses
                                                // for "go" (ModeIcon). Kept as a
                                                // literal because the M3 scheme
                                                // has no success/green token.
                                                readonly property color runColor: "#3fb950"
                                                readonly property bool running: LlamaService.online
                                                    || LlamaService.loading
                                                readonly property color actionColor: heroPowerBtn.running
                                                    ? Appearance.colors.colError
                                                    : heroPowerBtn.runColor
                                                readonly property bool usable: !LlamaService.busy
                                                property bool hovered: false
                                                color: heroPowerBtn.hovered && heroPowerBtn.usable
                                                    ? ColorUtils.transparentize(heroPowerBtn.actionColor, 0.82)
                                                    : "transparent"
                                                border.width: 1
                                                border.color: ColorUtils.transparentize(heroPowerBtn.actionColor,
                                                    heroPowerBtn.usable ? 0.45 : 0.78)
                                                opacity: heroPowerBtn.usable ? 1 : 0.4
                                                HoverHandler {
                                                    enabled: heroPowerBtn.usable
                                                    cursorShape: Qt.PointingHandCursor
                                                    onHoveredChanged: heroPowerBtn.hovered = hovered
                                                }
                                                TapHandler {
                                                    enabled: heroPowerBtn.usable
                                                    onTapped: LlamaService.toggle()
                                                }
                                                Row {
                                                    id: heroPowerRow
                                                    anchors.centerIn: parent
                                                    spacing: 5
                                                    MaterialSymbol {
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        text: heroPowerBtn.running ? "stop" : "play_arrow"
                                                        iconSize: 14
                                                        color: heroPowerBtn.actionColor
                                                    }
                                                    StyledText {
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        text: heroPowerBtn.running
                                                            ? Translation.tr("Stop")
                                                            : Translation.tr("Run")
                                                        font.pixelSize: Appearance.font.pixelSize.small
                                                        color: heroPowerBtn.actionColor
                                                    }
                                                }
                                            }

                                        }
                                    }
                                }

                                // The four readings. Same four-up the System
                                // tab uses, so the two tabs read as one card.
                                GridLayout {
                                    Layout.fillWidth: true
                                    columns: 4
                                    columnSpacing: 10
                                    rowSpacing: 6

                                    component Reading: ColumnLayout {
                                        id: reading
                                        property string label: ""
                                        property string value: ""
                                        property real fraction: 0
                                        property bool live: true
                                        spacing: 3
                                        StyledText {
                                            text: reading.label
                                            font.pixelSize: Appearance.font.pixelSize.tiny
                                            color: Appearance.colors.colSubtext
                                            font.capitalization: Font.AllUppercase
                                        }
                                        StyledText {
                                            text: reading.value
                                            font.pixelSize: Appearance.font.pixelSize.normal
                                            font.family: "JetBrains Mono"
                                            color: reading.live
                                                ? Appearance.colors.colOnLayer0
                                                : Appearance.colors.colSubtext
                                        }
                                        Rectangle {
                                            Layout.fillWidth: true
                                            implicitHeight: 3
                                            radius: 1.5
                                            color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.8)
                                            Rectangle {
                                                width: Math.max(0, Math.min(1, reading.fraction)) * parent.width
                                                height: 3
                                                radius: 1.5
                                                color: Appearance.colors.colPrimary
                                                Behavior on width {
                                                    NumberAnimation { duration: 420; easing.type: Easing.OutCubic }
                                                }
                                            }
                                        }
                                    }

                                    Reading {
                                        Layout.fillWidth: true
                                        label: Translation.tr("Generation")
                                        // "—" when nothing has generated: a
                                        // lifetime average across an idle
                                        // stretch would be a number about the
                                        // past, shown as one about now.
                                        value: LlamaService.speedGenText
                                        fraction: LlamaService.genFraction
                                        live: LlamaService.genTokensPerSec > 0
                                    }
                                    Reading {
                                        Layout.fillWidth: true
                                        label: Translation.tr("Prompt")
                                        value: LlamaService.speedPromptText
                                        fraction: LlamaService.promptFraction
                                        live: LlamaService.promptTokensPerSec > 0
                                    }
                                    Reading {
                                        Layout.fillWidth: true
                                        label: Translation.tr("VRAM")
                                        value: LlamaService.vramText
                                        fraction: LlamaService.vramFraction
                                        live: LlamaService.vramMiB > 0
                                    }
                                    Reading {
                                        Layout.fillWidth: true
                                        label: Translation.tr("Context")
                                        // Per slot AND the pool, because the
                                        // pool is what the arguments set and
                                        // the per-slot figure is what one
                                        // conversation actually gets.
                                        value: LlamaService.perSlotCtx > 0
                                            ? `${LlamaService.perSlotCtx} × ${LlamaService.totalSlots}`
                                            : "—"
                                        fraction: LlamaService.perSlotCtx > 0
                                            ? LlamaService.perSlotCtx / 4096 : 0
                                        live: LlamaService.perSlotCtx > 0
                                    }
                                }

                                // Slots. Each is an independent conversation;
                                // the pool is shared, which is why the reading
                                // above pairs the two numbers.
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 5
                                    visible: LlamaService.totalSlots > 0

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8
                                        MaterialSymbol {
                                            text: "layers"
                                            iconSize: 14
                                            color: Appearance.colors.colPrimary
                                        }
                                        StyledText {
                                            text: Translation.tr("Slots")
                                            font.pixelSize: Appearance.font.pixelSize.small
                                            font.weight: Font.DemiBold
                                            color: Appearance.colors.colOnLayer0
                                        }
                                        Item { Layout.fillWidth: true }
                                        StyledText {
                                            text: `${LlamaService.busySlots} / ${LlamaService.totalSlots} busy`
                                            font.pixelSize: Appearance.font.pixelSize.tiny
                                            font.family: "JetBrains Mono"
                                            color: Appearance.colors.colSubtext
                                        }
                                    }

                                    GridLayout {
                                        Layout.fillWidth: true
                                        columns: Math.min(4, Math.max(1, LlamaService.totalSlots))
                                        columnSpacing: 6
                                        rowSpacing: 4

                                        Repeater {
                                            model: LlamaService.slots
                                            delegate: Rectangle {
                                                required property var modelData
                                                Layout.fillWidth: true
                                                implicitHeight: 32
                                                radius: Appearance.rounding.small
                                                color: ColorUtils.transparentize(Appearance.colors.colLayer1, 0.5)
                                                border.width: modelData.busy ? 1 : 0
                                                border.color: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.35)

                                                ColumnLayout {
                                                    anchors.fill: parent
                                                    anchors.margins: 6
                                                    spacing: 2
                                                    RowLayout {
                                                        Layout.fillWidth: true
                                                        StyledText {
                                                            text: `#${modelData.id}`
                                                            font.pixelSize: Appearance.font.pixelSize.tiny
                                                            color: modelData.busy
                                                                ? Appearance.colors.colOnLayer0
                                                                : Appearance.colors.colSubtext
                                                        }
                                                        Item { Layout.fillWidth: true }
                                                        StyledText {
                                                            text: modelData.busy
                                                                ? Translation.tr("busy") : Translation.tr("idle")
                                                            font.pixelSize: Appearance.font.pixelSize.tiny
                                                            color: Appearance.colors.colSubtext
                                                        }
                                                    }
                                                    StyledText {
                                                        Layout.fillWidth: true
                                                        // decoded/total for a busy
                                                        // slot, both straight out of
                                                        // /slots.
                                                        text: modelData.busy
                                                            ? `${modelData.decoded} / ${modelData.decoded + modelData.remain}`
                                                            : "—"
                                                        font.pixelSize: Appearance.font.pixelSize.tiny
                                                        font.family: "JetBrains Mono"
                                                        color: Appearance.colors.colSubtext
                                                        elide: Text.ElideRight
                                                    }
                                                    Rectangle {
                                                        Layout.fillWidth: true
                                                        implicitHeight: 2
                                                        radius: 1
                                                        color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.85)
                                                        Rectangle {
                                                            width: Math.max(0, Math.min(1, modelData.pct)) * parent.width
                                                            height: 2
                                                            radius: 1
                                                            color: Appearance.colors.colPrimary
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                // The log: the server's own words. Replaces the
                                // sampling panel -- everything here came out
                                // of llama.cpp itself, which is the point. It
                                // is the one pane in this tab that cannot
                                // flatter the server.
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    spacing: 5

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8
                                        MaterialSymbol {
                                            text: "article"
                                            iconSize: 14
                                            color: Appearance.colors.colPrimary
                                        }
                                        StyledText {
                                            text: Translation.tr("Server log")
                                            font.pixelSize: Appearance.font.pixelSize.small
                                            font.weight: Font.DemiBold
                                            color: Appearance.colors.colOnLayer0
                                        }
                                    }

                                    Rectangle {
                                        Layout.fillWidth: true
                                        Layout.fillHeight: true
                                        Layout.minimumHeight: 60
                                        radius: Appearance.rounding.small
                                        color: ColorUtils.transparentize(Appearance.colors.colLayer0, 0.55)
                                        border.width: 1
                                        border.color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.85)
                                        clip: true

                                        Flickable {
                                            id: logFlick
                                            anchors.fill: parent
                                            anchors.margins: 8
                                            contentWidth: width
                                            contentHeight: logText.implicitHeight
                                            clip: true
                                            boundsBehavior: Flickable.StopAtBounds
                                            // Keep the newest line in view. A log
                                            // you must scroll to see what just
                                            // happened is a scrollback buffer,
                                            // not a log.
                                            onContentHeightChanged: contentY = Math.max(0, contentHeight - height)

                                            StyledText {
                                                id: logText
                                                width: parent.width
                                                text: LlamaService.logText.length > 0
                                                    ? LlamaService.logText
                                                    : Translation.tr("waiting for output…")
                                                font.pixelSize: Appearance.font.pixelSize.tiny
                                                font.family: "JetBrains Mono"
                                                color: Appearance.colors.colSubtext
                                                wrapMode: Text.NoWrap
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // 4 · System: live instruments on top, then the machine's
                    // own facts, categorized.
                    //
                    // Design (user-picked, mockup "B — Category sidebar"):
                    // a slim live strip (CPU / RAM / GPU / temp — percentage
                    // AND the absolute value, e.g. "19% · 12.1/64 GB"), then
                    // a category rail on the left and one fully-detailed pane
                    // on the right. The facts come from SystemFacts (read
                    // once at startup — showing them costs nothing) and the
                    // pane is the only scrollable part, so a category never
                    // gets cut off by the card's height.
                    //
                    // The old layout was eight gauge tiles — power and
                    // hardware numbers with no context. The Razer controls
                    // that used to share this tab are one click away in Razer
                    // Command Center itself.
                    PanelFadeView {
                        on: root.mode === root.modePerf
                        viewIndex: root.modePerf
ColumnLayout {
                        anchors.fill: parent
                        spacing: 20

                        // ── The band: four metrics, one history each ──
                        // Power used to lead this tab as a filled tile, with
                        // CPU/RAM/GPU/Temp as four more tiles beside it, each
                        // a number at the top and a bar pinned to the
                        // bottom with nothing in between: five boxes with a
                        // hole in the middle of each one, and the hole is
                        // where the eye actually goes -- "is this machine
                        // doing anything right now".
                        //
                        // The band answers that with four small histories
                        // instead. Every metric gets the same treatment, at
                        // the same height, with the current value as the
                        // headline and the last minute underneath it.
                        RowLayout {
                            id: metricBand
                            Layout.fillWidth: true
                            Layout.preferredHeight: 132
                            spacing: 24

                            Repeater {
                                model: [
                                    { key: "cpu",  label: Translation.tr("CPU") },
                                    { key: "ram",  label: Translation.tr("Memory") },
                                    { key: "gpu",  label: Translation.tr("GPU") },
                                    { key: "temp", label: Translation.tr("Temp") },
                                ]

                                delegate: ColumnLayout {
                                    id: metricCell
                                    required property var modelData
                                    Layout.fillWidth: true
                                    spacing: 5

                                    // Label left, value right, on one line:
                                    // the two things you read are the same
                                    // two things, and putting them on the
                                    // same baseline means you read them
                                    // together instead of hunting.
                                    Item {
                                        Layout.fillWidth: true
                                        implicitHeight: 24

                                        StyledText {
                                            id: metricLabel
                                            anchors.left: parent.left
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: metricCell.modelData.label
                                            font.pixelSize: Appearance.font.pixelSize.tiny
                                            font.weight: Font.Medium
                                            font.letterSpacing: 1.4
                                            font.capitalization: Font.AllUppercase
                                            color: Appearance.colors.colOnLayer1Inactive
                                        }
                                        StyledText {
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: {
                                                const k = metricCell.modelData.key;
                                                if (k === "cpu") return SystemNow.pct(SystemNow.cpuPct);
                                                if (k === "ram") return SystemNow.pct(SystemNow.ramPct);
                                                if (k === "gpu") return root.gpuMetricValue();
                                                const t = root.cpuPackageTemp();
                                                return t !== null ? t + "°" : "—°";
                                            }
                                            font.family: Appearance.font.family.numbers
                                            font.pixelSize: 23
                                            font.weight: Font.Light
                                            color: Appearance.colors.colOnLayer0
                                        }
                                    }

                                    // The one line of context the number
                                    // cannot give you. It earns its place by
                                    // saying something true -- the peak, the
                                    // absolute figure behind the percentage,
                                    // whether the part is even awake.
                                    StyledText {
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                        text: {
                                            const k = metricCell.modelData.key;
                                            if (k === "cpu") {
                                                let peak = 0;
                                                for (const v of ResourceUsage.cpuUsageHistory) peak = Math.max(peak, v);
                                                return Translation.tr("peak %1 · 60 s").arg(SystemNow.pct(peak));
                                            }
                                            if (k === "ram")
                                                return Translation.tr("%1 of %2 GB").arg(root.formatKB1(ResourceUsage.memoryUsed)).arg(root.formatKB1(ResourceUsage.memoryTotal));
                                            if (k === "gpu") {
                                                // Same three words the Razer app's GPU
                                                // page uses (see gpu_state_pill there), so
                                                // the two panels can no longer read as
                                                // contradicting each other.
                                                //
                                                // The word used to be derived from
                                                // runtime_status, i.e. "awake", while this
                                                // said "idle" — same card, same 0%, two
                                                // apparently different verdicts. runtime_status
                                                // describes the DRIVER (it stays "active"
                                                // for as long as the compositor holds
                                                // /dev/nvidia0 open, which is always);
                                                // pstate describes the CARD. Say the card's.
                                                if (!GpuPower.available)
                                                    return Translation.tr("dGPU off");
                                                if (!GpuPower.runtimeActive)
                                                    return Translation.tr("asleep");
                                                // The CAP, not the idle word: the user asked
                                                // to watch the enforced limit here, because
                                                // that is the number a power-mode switch is
                                                // supposed to move (55 W floor -> ~115 W
                                                // under Dynamic Boost). Measured while the
                                                // card is awake; mechanism-derived while it
                                                // sleeps; the pstate verdict lives on in the
                                                // Razer app's own GPU page.
                                                //
                                                // What comes AFTER the cap is
                                                // gpuCaption()'s call: the
                                                // model's memory while a model
                                                // is loaded, the mechanism word
                                                // otherwise.
                                                if (root.gpuCapMeasured && root.gpuCapW > 0)
                                                    return root.gpuCaption(Translation.tr("cap %1 W").arg(Math.round(root.gpuCapW)), "");
                                                if (root.gpuCapBoosted)
                                                    return root.gpuCaption(Translation.tr("cap 115 W"), Translation.tr("boost"));
                                                return root.gpuCaption(Translation.tr("cap 55 W"), Translation.tr("idle"));
                                            }
                                            return Translation.tr("package · ceiling 90°");
                                        }
                                        font.pixelSize: Appearance.font.pixelSize.tiny
                                        color: Appearance.colors.colSubtext
                                    }

                                    // The history, as a ROUNDED RIDGE.
                                    //
                                    // Five shapes have been tried here and the
                                    // reasons the others are gone are kept, so
                                    // they stay gone.
                                    //
                                    // A bare 60-sample polyline is a loose
                                    // noodle: every sample is a vertex, the eye
                                    // chases the zig-zag instead of the trend,
                                    // and four side by side read as scribble.
                                    //
                                    // A row of one mark per sample fixed the
                                    // tangle and was honest, but the marks are
                                    // VERTICAL LINES, and at 60 samples across
                                    // 330 px they fused into a comb. Widening the
                                    // scale floor out to 10 points to make them
                                    // taller only made it worse: real CPU load
                                    // moves 8%-12%, so the floor crushed every
                                    // graph into a 6 px fringe and the band read
                                    // as one flat smear.
                                    //
                                    // A smooth curve removed every hard edge but
                                    // invented values between the samples, and
                                    // the monotone variant still bowed above data
                                    // that was never measured.
                                    //
                                    // What is here is the stepped ridge again --
                                    // one horizontal run per sample, which is
                                    // genuinely what the data is -- with every
                                    // corner replaced by a quadratic arc. The
                                    // runs are kept because they are honest; the
                                    // hard vertical joins are gone because they
                                    // are what made it read as machinery. There
                                    // is no straight vertical edge left in the
                                    // drawing.
                                    //
                                    // Temperature is the only one drawn in the
                                    // accent. Four coloured graphs would be
                                    // four things shouting; one is a thing
                                    // being pointed at.
                                    Item {
                                        id: spark
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 46
                                        clip: true

                                        readonly property var series: {
                                            const k = metricCell.modelData.key;
                                            if (k === "cpu") return ResourceUsage.cpuUsageHistory;
                                            if (k === "ram") return ResourceUsage.memoryUsageHistory;
                                            if (k === "gpu") return root.gpuMetricSeries();
                                            return SystemNow.tempLoadHistory;
                                        }
                                        readonly property bool isTemp:
                                            metricCell.modelData.key === "temp"
                                        readonly property color lineColor:
                                            spark.isTemp
                                                ? Appearance.colors.colPrimary
                                                : Appearance.colors.colOnLayer0

                                        // ── The window: each metric's own scale ──
                                        //
                                        // 0 at the baseline, 1 at the top, for
                                        // all four series. Every history is
                                        // already a fraction of its own ceiling:
                                        // cpuUsage and memoryUsedPercentage are
                                        // 0-1, gpuClockPct is the card's
                                        // utilization, and tempLoadHistory
                                        // arrives normalised against the 30-90 °C
                                        // window (SystemNow.tempLoad) whose
                                        // ceiling the caption above states. So the
                                        // height of the line IS the number above
                                        // it -- 90% draws near the top, 44% a
                                        // little under half -- and the band agrees
                                        // with the popped-out Performance card,
                                        // which plots these same histories through
                                        // Graph (`y = height - value * height`).
                                        //
                                        // The band used to auto-fit instead: the
                                        // window ran from the series' own minimum
                                        // to its maximum, never tighter than a
                                        // 4-point floor, so a metric sitting at
                                        // 90% and moving one point drew a line
                                        // along the baseline. That looked alive and
                                        // told the one lie a usage graph cannot
                                        // afford -- "the machine is idle" while
                                        // the headline above it said 90% -- so the
                                        // min/max fit, its floor and the 0.2/1.28
                                        // padding are gone.
                                        readonly property real windowLo: 0
                                        readonly property real windowSpan: 1
                                        // How many of the series' newest samples
                                        // this graph draws, and where that
                                        // number comes from.
                                        //
                                        // 0 means "all of them" (the processor
                                        // and memory histories are a minute of
                                        // one-second samples and are read as
                                        // such). The GPU's history is the same
                                        // 60 samples at four a second, and the
                                        // fifteen seconds that adds up to is
                                        // what the graph PAINTED -- so a load
                                        // that steps to 100% only became a
                                        // legible plateau after the whole
                                        // fifteen had passed, fifteen to twenty
                                        // seconds after the number above it
                                        // already said 100%. The slice is the
                                        // fix: the same data, the newest five
                                        // seconds of it, matching the reading.
                                        readonly property int window:
                                            metricCell.modelData.key === "gpu"
                                                ? SystemNow.gpuWindowPoints : 0
                                        readonly property var shown: {
                                            const s = spark.series ?? [];
                                            return spark.window > 0 && s.length > spark.window
                                                ? s.slice(s.length - spark.window) : s;
                                        }
                                        readonly property int count:
                                            (spark.shown && spark.shown.length) || 0
                                        // One sample's bar, as a fraction of the
                                        // graph's height, clamped at 0 so a
                                        // sample below the window's floor sits
                                        // ON the baseline rather than under it.
                                        function norm(v) {
                                            if (spark.windowSpan <= 0) return 0;
                                            const t = (v - spark.windowLo) / spark.windowSpan;
                                            return Math.max(0, Math.min(1, t));
                                        }
                                        // Distance between samples, and the
                                        // height of the plot area above the
                                        // baseline.
                                        readonly property real step:
                                            spark.count > 1
                                                ? spark.width / (spark.count - 1)
                                                : 0
                                        readonly property real plotH:
                                            Math.max(1, spark.height - 1)

// The curve, sampled from the samples.
                                        //
                                        // This is the shape the design calls
                                        // for: one smooth line stroked thin,
                                        // with a wash under it that fades to
                                        // nothing at the baseline. Five shapes
                                        // died here and the file keeps the
                                        // reasons so they stay dead:
                                        //
                                        //  - a bare polyline through the raw
                                        //    samples is the "loose noodle": at
                                        //    60 samples across ~330px every
                                        //    0.4-point wobble is a visible
                                        //    zig and the eye reads noise.
                                        //  - a stepped ridge (one horizontal
                                        //    run per sample) is honest -- each
                                        //    run IS a value held until the next
                                        //    sample -- but its hard 90-degree
                                        //    joins are what made it read as
                                        //    machinery.
                                        //  - rounding those joins into arcs
                                        //    fixed the joins and created a new
                                        //    problem: a generous radius ate the
                                        //    run between samples, so a busy
                                        //    series became a row of lozenges.
                                        //    Sharpening it just walked that
                                        //    back toward the hard join.
                                        //  - per-sample bars and dots were
                                        //    rejected as scribble, and every
                                        //    bar is a vertical line.
                                        //
                                        // A smooth curve escapes all of it:
                                        // the eye travels along it instead of
                                        // stopping at every sample.
                                        //
                                        // Catmull-Rom is sampled into straight
                                        // segments for two reasons. A
                                        // PathPolyline cannot express a curve,
                                        // and PathSvg -- which can take a path
                                        // as a string -- drew nothing at all at
                                        // this size when it was tried here. Four
                                        // segments per interval is visually
                                        // indistinguishable from the curve and
                                        // goes through the path that works.
                                        //
                                        // Each generated y is CLAMPED to the
                                        // two samples it sits between. Plain
                                        // Catmull-Rom overshoots, and on a
                                        // series that is flat -- GPU at 0% --
                                        // that overshoot invents peaks that
                                        // were never measured. The clamp costs
                                        // a little of the curve's roundness at
                                        // a peak and buys never showing a value
                                        // the machine did not report.
                                        readonly property var curveY: {
                                            const s = spark.shown;
                                            const n = spark.count;
                                            if (!s || n === 0 || spark.width <= 0)
                                                return [];
                                            const h = spark.plotH;
                                            const ys = [];
                                            // A sample that is not a finite
                                            // number would put NaN into the
                                            // geometry and the whole shape
                                            // silently vanishes. Such a sample
                                            // is held at the previous good
                                            // value, which is also what "no
                                            // reading this second" means.
                                            let last = 0;
                                            for (let i = 0; i < n; i++) {
                                                const raw = Number(s[i]);
                                                const v = Number.isFinite(raw) ? raw : last;
                                                ys.push(h - spark.norm(v) * h);
                                                last = v;
                                            }
                                            if (n === 1)
                                                return ys;
                                            // TENSION. 0.5 is textbook
                                            // Catmull-Rom. Below it the curve
                                            // flattens through each sample and
                                            // reads calmer; at 0.5 a series that
                                            // genuinely steps changes direction
                                            // noticeably faster than the data
                                            // did. 0.42 is the middle of that.
                                            const t = 0.42;
                                            const out = [ys[0]];
                                            for (let i = 0; i < n - 1; i++) {
                                                const p0 = ys[i > 0 ? i - 1 : 0];
                                                const p1 = ys[i];
                                                const p2 = ys[i + 1];
                                                const p3 = ys[i + 2 < n ? i + 2 : n - 1];
                                                const m1 = (p2 - p0) / 2 * t;
                                                const m2 = (p3 - p1) / 2 * t;
                                                const lo = Math.min(p1, p2);
                                                const hi = Math.max(p1, p2);
                                                const SEG = 4;
                                                for (let k = 1; k <= SEG; k++) {
                                                    const u = k / SEG;
                                                    const u2 = u * u, u3 = u2 * u;
                                                    const h00 = 2 * u3 - 3 * u2 + 1;
                                                    const h10 = u3 - 2 * u2 + u;
                                                    const h01 = -2 * u3 + 3 * u2;
                                                    const h11 = u3 - u2;
                                                    let y = h00 * p1 + h10 * m1
                                                          + h01 * p2 + h11 * m2;
                                                    if (!Number.isFinite(y)) y = p1;
                                                    out.push(Math.max(lo, Math.min(hi, y)));
                                                }
                                            }
                                            return out;
                                        }
                                        // The same curve as points, for the
                                        // stroke.
                                        readonly property var curvePoints: {
                                            const ys = spark.curveY;
                                            if (ys.length < 2) return [];
                                            const pts = [];
                                            for (let i = 0; i < ys.length; i++)
                                                pts.push(Qt.point(i * spark.step, ys[i]));
                                            return pts;
                                        }
                                        // The paint routine for graphCanvas.
                                        //
                                        // One path, drawn twice: filled with
                                        // the vertical fade, then stroked as
                                        // the line. Sharing the path is the
                                        // whole point -- the shade is bounded
                                        // by exactly the geometry the line is
                                        // drawn from, so it cannot end up
                                        // above it on a spike.
                                        function paintGraph(ctx) {
                                            const pts = spark.curvePoints;
                                            const h = spark.plotH;
                                            const w = spark.width;
                                            ctx.reset();
                                            if (!pts || pts.length < 2 || w <= 0)
                                                return;

                                            // QML colours expose r/g/b/a as
                                            // 0..1 doubles; the canvas wants a
                                            // CSS string. Converting here rather
                                            // than using ColorUtils keeps the
                                            // alpha ramp in one place.
                                            const c = spark.lineColor;
                                            const cr = Math.round(c.r * 255);
                                            const cg = Math.round(c.g * 255);
                                            const cb = Math.round(c.b * 255);
                                            const rgba = (a) =>
                                                "rgba(" + cr + "," + cg + "," + cb
                                                + "," + a + ")";

                                            // The outline, once. It is walked
                                            // twice rather than stored, because
                                            // the canvas has no reusable path
                                            // object and the list is small.
                                            const trace = () => {
                                                ctx.beginPath();
                                                ctx.moveTo(pts[0].x, pts[0].y);
                                                for (let i = 1; i < pts.length; i++)
                                                    ctx.lineTo(pts[i].x, pts[i].y);
                                            };

                                            // ── the shade ──
                                            //
                                            // Closed down to the baseline, so
                                            // it is the curve's own area and
                                            // nothing else. The fade runs from
                                            // the top of the plot to the
                                            // baseline: a quick fall away from
                                            // the line, then a long tail that
                                            // reaches nothing, which is what
                                            // makes it melt into the card
                                            // instead of ending on an edge.
                                            //
                                            // The peak is not the usual 11-16%
                                            // wash. Against this card's surface
                                            // colOnLayer0 at 0.15 lands near
                                            // rgb(46,46,46) -- a 1.37:1
                                            // contrast, below where a large area
                                            // reads as a shape at all. The
                                            // accent is weaker in luminance
                                            // still, so temperature starts a
                                            // little higher to land in the same
                                            // place.
                                            trace();
                                            ctx.lineTo(w, h);
                                            ctx.lineTo(0, h);
                                            ctx.closePath();
                                            const g = ctx.createLinearGradient(0, 0, 0, h);
                                            const peak = spark.isTemp ? 0.46 : 0.42;
                                            g.addColorStop(0.0, rgba(peak));
                                            g.addColorStop(0.45, rgba(peak * 0.36));
                                            g.addColorStop(1.0, rgba(0));
                                            ctx.fillStyle = g;
                                            ctx.fill();

                                            // ── the line ──
                                            //
                                            // At full strength: it is the one
                                            // element that has to read at a
                                            // glance, so it gets no dimming.
                                            trace();
                                            ctx.strokeStyle =
                                                "rgb(" + cr + "," + cg + "," + cb + ")";
                                            ctx.lineWidth = 1.6;
                                            ctx.lineJoin = "round";
                                            ctx.lineCap = "round";
                                            ctx.stroke();
                                        }


                                        // The floor the history sits on: a
                                        // hairline at 0%, so a flat idle row is
                                        // visibly flat rather than looking like
                                        // a broken chart.
                                        Rectangle {
                                            anchors.bottom: parent.bottom
                                            width: parent.width
                                            height: 1
                                            color: Appearance.colors.colOutlineVariant
                                        }

                                        // The wash: the curve's own shape, in a
                                        // gradient that fades to nothing at the
                                        // baseline.
                                        //
                                        // A flat fill of the curve's colour was
                                        // tried first and it reads as a slab --
                                        // the eye sees a block with a top edge
                                        // rather than an area under a line. The
                                        // fade is what makes it read as depth.
                                        //
                                        // The values are not the usual 11-16%
                                        // wash. Against this card's #131313
                                        // surface colOnLayer0 at 0.15 lands at
                                        // rgb(46,46,46), a 1.37:1 contrast,
                                        // which is below where a large area
                                        // still reads as a shape. 0.42 puts the
                                        // top of the fade at rgb(94,94,94), and
                                        // because it fades to zero the mass
                                        // never competes with the numbers above
                                        // it. The accent is weaker in
                                        // luminance, so temperature starts a
                                        // little higher to land in the same
                                        // place.
// The shade and the line, drawn together in ONE pass.
                                        //
                                        // This is a Canvas rather than a
                                        // Shape because the shade has to be a
                                        // real, continuous gradient, and
                                        // nothing in this Qt build can clip a
                                        // gradient to a path:
                                        //
                                        //  - Item.mask does not exist ("Cannot
                                        //    assign to non-existent property
                                        //    mask", on a Rectangle and on an
                                        //    Item alike).
                                        //  - Shape.gradient does not exist,
                                        //    and ShapeGradient is abstract.
                                        //
                                        // The shape that WAS here instead cut
                                        // the area into twelve horizontal
                                        // bands at stepped alphas. It rendered,
                                        // and it was wrong in two visible ways.
                                        // Twelve bands quantise the shade's
                                        // top edge to 3.8px steps, so on a steep
                                        // rise the fill's edge visibly lags the
                                        // line and on the fall it overshoots
                                        // above it -- a high spike drew shade
                                        // outside the line it belonged to. And
                                        // the steps read as a stack of
                                        // rectangles, which is the one thing
                                        // the design is not.
                                        //
                                        // No number of bands fixes that; the
                                        // banding itself is the defect. Canvas
                                        // is the one route here that gives a
                                        // genuine vertical fade against a path
                                        // that follows the curve exactly, so the
                                        // shade meets the line with no gap and
                                        // never crosses it.
                                        //
                                        // Both the fill and the stroke go
                                        // through the SAME path here, which is
                                        // what guarantees they agree: the shade
                                        // cannot drift off the line, because it
                                        // is the line's own outline.
                                        Canvas {
                                            id: graphCanvas
                                            anchors.fill: parent
                                            // Cooperative keeps the repaint off
                                            // the render thread's back. The
                                            // canvas is tiny and only redraws
                                            // once a second, so immediate is
                                            // not needed.
                                            renderStrategy: Canvas.Cooperative
                                            // Nothing to draw without data, and nothing
                                            // sensible to draw in a collapsed layout: the
                                            // panel window shrinks to its minimum while the
                                            // card is away, which collapses these boxes to a
                                            // few pixels -- and a curve laid out across a
                                            // 2px box is a vertical spike whose wash fills
                                            // the whole box. That frame used to be the one
                                            // texture the canvas kept: reopening the card
                                            // showed the last thing painted while it was
                                            // shrinking (a solid block under a headline
                                            // reading 4%) instead of the flat line the data
                                            // described. Gating on a real width keeps the
                                            // spike from ever being painted.
                                            visible: spark.curvePoints.length > 2 && spark.width > 16
                                            onPaint: spark.paintGraph(getContext("2d"))
                                            // Becoming visible again has to repaint.
                                            //
                                            // With Cooperative rendering the paint runs on
                                            // the render thread, and a `requestPaint()`
                                            // issued while the surface is unmapped can be
                                            // dropped outright -- which is exactly the
                                            // state the canvas is in when the card is
                                            // closed, so the stored texture could be the
                                            // last frame of a previous session. Qt re-asks
                                            // for nothing when a hidden item comes back;
                                            // this is that ask.
                                            onVisibleChanged: if (visible) requestPaint()
                                            // The curve is rebuilt once a tick,
                                            // and the box moves on resize. Both
                                            // need a repaint; Canvas has no
                                            // built-in signal for either, so it
                                            // is wired up by hand.
                                            Connections {
                                                target: spark
                                                function onCurvePointsChanged() {
                                                    graphCanvas.requestPaint();
                                                }
                                                function onWidthChanged() {
                                                    graphCanvas.requestPaint();
                                                }
                                                function onHeightChanged() {
                                                    graphCanvas.requestPaint();
                                                }
                                            }
                                            Component.onCompleted: requestPaint()
                                        }
                                    }
                                }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 1
                            color: Appearance.colors.colOutlineVariant
                        }

                        // ── Ledger and power ──
                        // Below the rule nothing is live, so nothing is
                        // drawn: the facts about the machine, set as rows,
                        // and the one number that IS live -- the board's
                        // power -- given its own ruled column because it is
                        // the only measurement here with no natural place in
                        // the list.
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: 26

                            // The ledger MUST NOT COLLAPSE. Its rows are plain
                            // Items (they size themselves as a share of the
                            // leftover height), so the ColumnLayout's implicit
                            // width is ZERO -- with nothing to ask for, the
                            // RowLayout hands it no width at all and the
                            // power column lands on top of the labels. The
                            // minimum is the floor that stops that; fillWidth
                            // still gives it everything else.
                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.minimumWidth: 260
                                Layout.fillHeight: true
                                spacing: 0

                                Repeater {
                                    // The rows, in the order the machine is read:
                                    // processor, graphics, memory, then the display
                                    // and the two interfaces.
                                    //
                                    // This block used to be a SPEC SHEET -- the
                                    // processor's model, how much RAM was free,
                                    // the root disk's capacity, thread count,
                                    // uptime -- and the objection to it is not
                                    // that it was wrong but that none of it
                                    // changes while you look at it. What the
                                    // panel now shows is what the machine is
                                    // DOING, including the numbers a power mode
                                    // moves (governor and EPP, the enforced
                                    // wattage ceiling, the driven refresh rate),
                                    // which is the one thing a spec sheet can
                                    // never show.
                                    //
                                    // Free, Storage, Swap, Threads and Uptime went
                                    // with the rewrite: three were quantities of
                                    // things NOT in use, threads are already the
                                    // caption under the processor gauge, and
                                    // uptime is a fact about the session rather
                                    // than the hardware. The two inventory rows
                                    // that remain -- processor and graphics --
                                    // stay because the live numbers around them
                                    // mean nothing without knowing which chip
                                    // they came off. Every other row can change
                                    // between two openings of this card, and
                                    // every one of them renders "—" rather than
                                    // 0 when its source is missing: a blank or a
                                    // zero would read as a measurement.
                                    //
                                    // Panel, Disk, Network and GPU clock went the
                                    // same way in the second pass. The panel's own
                                    // ceiling is what the Display row already
                                    // implies (the mode it is DRIVEN at, plus how
                                    // fast that panel can go) and the rest of it
                                    // belongs in Settings > Display, which lists the
                                    // modes (2560x1600@240.00Hz among them) rather
                                    // than under a live readout; disk and network
                                    // throughput are acts of copying, not facts
                                    // about this hardware; and the clock row's two
                                    // numbers answered questions the rows around
                                    // it answer better -- how parked the card is,
                                    // IS the wattage it is drawing against its
                                    // cap, which is the number one row up.
                                    model: [
                                        { k: Translation.tr("Processor"),  v: root.cpuDisplayName() },
                                        { k: Translation.tr("Clock"),      v: SystemNow.cpuClockText() },
                                        { k: Translation.tr("CPU policy"), v: SystemNow.cpuPolicyText() },
                                        { k: Translation.tr("Graphics"),   v: root.gpuIdentityRow() },
                                        { k: Translation.tr("GPU power"),  v: root.gpuDrawRow() },
                                        { k: Translation.tr("VRAM"),       v: SystemNow.vramText() },
                                        { k: Translation.tr("Memory"),     v: `${root.formatKB1(ResourceUsage.memoryUsed)} / ${root.formatKB1(ResourceUsage.memoryTotal)} GB` },
                                        { k: Translation.tr("Display"),    v: root.displayModeRow() },
                                    ]
                                    delegate: Item {
                                        required property var modelData
                                        // Every row is a share of the leftover
                                        // height, so the ledger fills whatever
                                        // the card is and the gaps between
                                        // rows are equal at any size. A fixed
                                        // row height would leave the void the
                                        // tiles used to have, just lower down.
                                        Layout.fillWidth: true
                                        Layout.fillHeight: true
                                        Layout.minimumHeight: 22

                                        StyledText {
                                            id: rowLabel
                                            anchors.left: parent.left
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: modelData.k
                                            font.pixelSize: Appearance.font.pixelSize.small
                                            color: Appearance.colors.colSubtext
                                        }
                                        StyledText {
                                            anchors.right: parent.right
                                            anchors.left: rowLabel.right
                                            anchors.leftMargin: 16
                                            anchors.verticalCenter: parent.verticalCenter
                                            horizontalAlignment: Text.AlignRight
                                            elide: Text.ElideMiddle
                                            text: modelData.v
                                            font.family: Appearance.font.family.numbers
                                            font.pixelSize: Appearance.font.pixelSize.small
                                            color: Appearance.colors.colOnLayer0
                                        }
                                        Rectangle {
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.bottom: parent.bottom
                                            height: 1
                                            color: Appearance.colors.colOutlineVariant
                                        }
                                    }
                                }
                            }

                            Rectangle {
                                Layout.preferredWidth: 1
                                Layout.fillHeight: true
                                color: Appearance.colors.colOutlineVariant
                            }

// ── Power / battery ──
                                // What this column used to say, and why it
                                // changed.
                                //
                                // It was headed "Power output" and showed
                                // gpuWatts() -- which is nvidia-smi's
                                // power.draw, the graphics card's OWN board
                                // draw and nothing else. Under that heading
                                // it read as the whole machine, and it is
                                // not: this laptop cannot report total
                                // system watts at all (ACPI exposes only
                                // AC0 online, no current), and the CPU
                                // package's RAPL sensor is readable only by
                                // root. A "7 W" under a heading called Power
                                // output was a lie of omission.
                                //
                                // This now reports the one power figure that
                                // is genuinely whole-machine and always
                                // available:
                                //
                                //  - ON BATTERY -> how much is left, and for
                                //    how long. That is what the user needs
                                //    off mains.
                                //  - ON MAINS, CHARGING -> what the charger
                                //    is putting in, in watts, from
                                //    Battery.energyRate (UPower's
                                //    changeRate). Also whole-machine: while
                                //    the pack is filling, everything the
                                //    machine burns arrives through the
                                //    charger.
                                //  - ON MAINS, NOT CHARGING -> charge level
                                //    again, with the reason stated, because a
                                //    bare percentage looks broken there.
                                //
                                // A machine with no battery at all falls back
                                // to the GPU figure under an honest heading
                                // ("Graphics card") rather than pretending
                                // it is the whole machine.
                                //
                                // The dGPU draw is kept as a small line
                                // beneath. It is real measured data and
                                // there is no reason to discard it -- it just
                                // no longer claims to be everything.
                                ColumnLayout {
                                    id: powerCol
                                    Layout.preferredWidth: 214
                                    Layout.minimumWidth: 214
                                    Layout.maximumWidth: 214
                                    Layout.fillHeight: true
                                    spacing: 0

                                    readonly property bool hasBattery: Battery.available
                                    readonly property bool charging: Battery.isCharging
                                    // Deliberately NOT Battery.isPluggedIn. That is defined as
                                    // "charging or about to", so it is FALSE
                                    // for a full battery on AC -- exactly the
                                    // state this column most needs to name
                                    // correctly, and the one where "On
                                    // battery / N min left" would have been
                                    // actively wrong. UPower's state is the
                                    // honest source: 1 charging, 2
                                    // discharging, 4 fully charged, 5
                                    // pending charge, 6 on mains, not charging.
                                    readonly property int chargeState:
                                        Battery.chargeState ?? 0
                                    readonly property bool onMains:
                                        powerCol.charging
                                        || powerCol.chargeState === 4
                                        || powerCol.chargeState === 5
                                        || powerCol.chargeState === 6
                                    readonly property bool full:
                                        powerCol.chargeState === 4
                                    // Is a charge limit holding it back?
                                    //
                                    // On mains, not charging, no current
                                    // flowing, and still well short of full:
                                    // that combination is the fingerprint of a
                                    // firmware charge cap. The kernel does not
                                    // publish the threshold -- there is no
                                    // charge_control_end_threshold anywhere
                                    // under /sys/class/power_supply -- so the
                                    // number below is what the machine is
                                    // sitting at, NOT a reading of the cap
                                    // itself. Saying so is the honest version.
                                    readonly property bool limitHolding:
                                        powerCol.hasBattery
                                        && powerCol.onMains
                                        && !powerCol.charging
                                        && Math.abs(Battery.energyRate ?? 0) < 0.01
                                        && powerCol.pct > 30
                                        && powerCol.pct < 100
                                    readonly property bool gpuKnown:
                                        GpuPower.available && root.gpuWatts() !== null
                                    readonly property int pct: Math.round(
                                        (Battery.percentage ?? 1) * 100)
                                    // energyRate is UPower's changeRate: watts,
                                    // positive in, negative out. It reads 0
                                    // whenever the pack is idle, so it is only
                                    // trusted while actually charging.
                                    readonly property real inWatts:
                                        charging ? Math.abs(Battery.energyRate ?? 0) : 0

                                    readonly property string headline:
                                        powerCol.charging ? Translation.tr("Charging in")
                                        : powerCol.hasBattery ? Translation.tr("Battery")
                                        : powerCol.gpuKnown ? Translation.tr("Graphics card")
                                        : Translation.tr("Power")

                                    readonly property string value:
                                        powerCol.hasBattery
                                            ? (powerCol.charging && powerCol.inWatts > 0.01
                                                ? powerCol.inWatts.toFixed(1) + " W"
                                                : powerCol.pct + "%")
                                            : (powerCol.gpuKnown
                                                ? root.gpuWatts().toFixed(1) + " W"
                                                : "—")

                                    StyledText {
                                        text: powerCol.headline
                                        font.pixelSize: Appearance.font.pixelSize.tiny
                                        font.weight: Font.Medium
                                        font.letterSpacing: 1.4
                                        font.capitalization: Font.AllUppercase
                                        color: Appearance.colors.colOnLayer1Inactive
                                    }
                                    StyledText {
                                        Layout.topMargin: 10
                                        text: powerCol.value
                                        font.family: Appearance.font.family.numbers
                                        font.pixelSize: 44
                                        font.weight: Font.Light
                                        color: Appearance.colors.colOnLayer0
                                    }
                                    RowLayout {
                                        Layout.topMargin: 12
                                        spacing: 7
                                        Rectangle {
                                            Layout.alignment: Qt.AlignVCenter
                                            width: 5; height: 5; radius: 2.5
                                            color: powerCol.charging
                                                ? Appearance.colors.colPrimary
                                                : Appearance.colors.colOnLayer0
                                        }
                                        StyledText {
                                            text: {
                                                if (!powerCol.hasBattery)
                                                    return Translation.tr("No battery");
                                                if (powerCol.charging) {
                                                    const t = Math.round(
                                                        (Battery.timeToFull ?? 0) / 60);
                                                    return t > 0
                                                        ? Translation.tr("Full in %1 min").arg(t)
                                                        : Translation.tr("Charging");
                                                }
                                                if (powerCol.full)
                                                    return Translation.tr("Full · on mains");
                                                if (powerCol.limitHolding)
                                                    return Translation.tr("Held at %1% · BIOS limit").arg(
                                                        powerCol.pct);
                                                if (powerCol.onMains)
                                                    return Translation.tr("On mains · not charging");
                                                const t = Math.round(
                                                    (Battery.timeToEmpty ?? 0) / 60);
                                                return t > 0
                                                    ? Translation.tr("%1 min left").arg(t)
                                                    : Translation.tr("On battery");
                                            }
                                            font.pixelSize: Appearance.font.pixelSize.tiny
                                            color: Appearance.colors.colSubtext
                                        }
                                    }

                                    // ── Power mode: three icon buttons ──────────────────
                                    // Inside powerCol on purpose: the row shares the battery
                                    // figure's exact width and edges, so the thirds line up
                                    // with everything above them. Icon-only per the user's
                                    // redesign -- no labels, no boxes; colour carries the
                                    // meaning (green saver, primary balanced, fire-orange
                                    // performance, the same fire the screen alert wears).
                                    // A tap sets the PPD profile AND applies the cap policy
                                    // on nvidia-powerd: performance lifts the GPU ceiling,
                                    // the calmer modes drop it back to the 55 W vBIOS floor.
                                    RowLayout {
                                        Layout.fillWidth: true
                                        Layout.topMargin: 14
                                        spacing: 8

                                        Repeater {
                                            model: [
                                                { p: PowerProfile.PowerSaver,  icon: "energy",                tint: "#43d17c" },
                                                { p: PowerProfile.Balanced,    icon: "airwave",               tint: Appearance.colors.colPrimary },
                                                { p: PowerProfile.Performance, icon: "local_fire_department", tint: "#ff6d1f" }
                                            ]

                                            Rectangle {
                                                id: modeButton
                                                required property var modelData
                                                Layout.fillWidth: true
                                                implicitHeight: 42
                                                radius: Appearance.rounding.normal
                                                readonly property bool active:
                                                    PowerProfiles.profile === modeButton.modelData.p
                                                property bool hovered: false
                                                readonly property bool perfAvailable:
                                                    modeButton.modelData.p !== PowerProfile.Performance
                                                    || PowerProfiles.hasPerformanceProfile

                                                // Flat at rest; on hover the button washes in its
                                                // OWN colour, the icon jumps to full tint and the
                                                // whole button leans in a touch. The active mode
                                                // keeps the strongest wash. No borders anywhere.
                                                color: modeButton.active
                                                    ? ColorUtils.transparentize(modeButton.modelData.tint, 0.84)
                                                    : modeButton.hovered
                                                        ? ColorUtils.transparentize(modeButton.modelData.tint, 0.92)
                                                        : "transparent"
                                                opacity: !modeButton.perfAvailable
                                                    ? 0.35
                                                    : (root.modeApplying && root.applyingModeValue !== modeButton.modelData.p
                                                        ? 0.55 : 1.0)
                                                scale: modeButton.hovered && modeButton.perfAvailable && !root.modeApplying ? 1.04 : 1.0
                                                Behavior on color { ColorAnimation { duration: 140 } }
                                                Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }

                                                MouseArea {
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: root.modeApplying
                                                        ? Qt.BusyCursor : Qt.PointingHandCursor
                                                    onHoveredChanged: modeButton.hovered = hovered
                                                    onClicked: {
                                                        if (!modeButton.perfAvailable)
                                                            return;
                                                        // One change at a time: applyMode
                                                        // ignores clicks while one is in
                                                        // flight (see its comment).
                                                        root.applyMode(modeButton.modelData.p);
                                                    }
                                                }

                                                MaterialSymbol {
                                                    id: modeIcon
                                                    anchors.centerIn: parent
                                                    text: modeButton.modelData.icon
                                                    iconSize: 24
                                                    color: modeButton.active || modeButton.hovered
                                                        ? modeButton.modelData.tint
                                                        : ColorUtils.transparentize(modeButton.modelData.tint, 0.5)
                                                    Behavior on color { ColorAnimation { duration: 140 } }
                                                    // The tapped mode breathes while its change
                                                    // is in flight; the rest dim (see opacity
                                                    // on the button).
                                                    SequentialAnimation on opacity {
                                                        running: root.modeApplying
                                                            && root.applyingModeValue === modeButton.modelData.p
                                                        loops: Animation.Infinite
                                                        onStopped: modeIcon.opacity = 1
                                                        NumberAnimation { to: 0.35; duration: 380 }
                                                        NumberAnimation { to: 1.0; duration: 380 }
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    // The feedback line: the enforced GPU limit, freshly
                                    // read. It brightens only when the cap genuinely moved;
                                    // an unchanged system leaves it calm. While a mode
                                    // change is in flight it says so -- the number comes
                                    // back only once a query has actually seen it.
                                    RowLayout {
                                        Layout.alignment: Qt.AlignHCenter
                                        Layout.topMargin: 2
                                        spacing: 5

                                        MaterialSymbol {
                                            visible: root.modeApplying
                                            text: "progress_activity"
                                            iconSize: 12
                                            color: Appearance.colors.colSubtext
                                            RotationAnimation on rotation {
                                                from: 0; to: 360; duration: 900
                                                loops: Animation.Infinite
                                                running: root.modeApplying
                                            }
                                        }
                                        StyledText {
                                            text: root.modeApplying
                                                ? Translation.tr("applying…")
                                                : root.gpuCapMeasured && root.gpuCapW > 0
                                                    ? Translation.tr("GPU cap %1 W").arg(Math.round(root.gpuCapW))
                                                    : root.gpuCapBoosted
                                                        ? Translation.tr("GPU cap 115 W · boost")
                                                        : Translation.tr("GPU cap 55 W · idle")
                                            font.pixelSize: Appearance.font.pixelSize.tiny
                                            color: root.gpuCapFlash
                                                ? Appearance.colors.colPrimary
                                                : Appearance.colors.colSubtext
                                            Behavior on color { ColorAnimation { duration: 300 } }
                                        }
                                    }

                                    Timer {
                                        id: gpuCapRequery
                                        interval: 1200; repeat: false; running: false
                                        onTriggered: root.queryGpuCap()
                                    }
                                    // The applying state's own clock: long enough for the
                                    // 1.2 s requery to land, short enough to never feel
                                    // stuck. It also guarantees the lock always ends,
                                    // even if a query never comes back.
                                    Timer {
                                        id: applyDoneTimer
                                        interval: 1500; repeat: false; running: false
                                        onTriggered: {
                                            root.modeApplying = false;
                                            root.applyingModeValue = -1;
                                        }
                                    }
                                    Component.onCompleted: root.queryGpuCap()

                                    // Refresh on a slow tick while the System tab is open, so
                                    // cap changes from OUTSIDE (the failsafe, a daemon
                                    // restart) show up on their own. This block only exists
                                    // while the tab is loaded, so the query sleeps with it.
                                    Timer {
                                        interval: 3000; repeat: true; running: true
                                        onTriggered: root.queryGpuCap()
                                    }

                                    StyledText {
                                        Layout.fillWidth: true
                                        Layout.fillHeight: true
                                        Layout.topMargin: 22
                                        wrapMode: Text.WordWrap
                                        verticalAlignment: Text.AlignBottom
                                        text: {
                                                // When a cap is holding the pack,
                                                // say WHERE it lives. Linux
                                                // exposes no threshold file, so
                                                // the honest answer is "the
                                                // firmware" -- and a user who
                                                // has just watched their
                                                // battery sit still for an
                                                // hour deserves to know it is
                                                // not a bug.
                                                if (powerCol.limitHolding)
                                                    return Translation.tr(
                                                        "The firmware is holding the charge here. Linux cannot see the limit -- it is set in the BIOS (F2 on boot).");
                                                return GpuPower.available
                                                    // One value per arg() call: QML's String.arg takes a
                                                    // single argument, so handing it two logged "Invalid
                                                    // arguments" and left the row printing %1 and %2 raw.
                                                    ? Translation.tr("dGPU %1 · %2 W of that is the card").arg(
                                                        GpuPower.pstate).arg(
                                                        root.gpuWatts() !== null
                                                            ? root.gpuWatts().toFixed(1)
                                                            : "?")
                                                    : Translation.tr("No discrete GPU is reporting.");
                                            }
                                        font.pixelSize: Appearance.font.pixelSize.tiny
                                        color: Appearance.colors.colOnLayer1Inactive
                                    }
                                }

                        }
                    }
                }
                }
            }
        
            // ── Horizontal swipe, anywhere on the card ───────────────────
            //
            // Declared LAST so it is the topmost item: a wheel event is
            // delivered to whatever is under the cursor, and Qt then walks
            // that item's PARENT chain -- never a sibling. The panel's swipe
            // area is a sibling of the card, which is why the gesture used to
            // work only in the empty strip of panel above the card.
            //
            // `acceptedButtons: Qt.NoButton` is what keeps this honest: the
            // area sits over the whole card but grabs no presses, so the tabs,
            // rows, sliders and chips underneath still get their clicks.
            // Qt 6 delivers wheel to a MouseArea unconditionally -- there is
            // no `wheelEnabled` property on this build, and asking for one is
            // a load-time error, not a silent no-op.
            MouseArea {
                id: cardSwipeOverlay
                anchors.fill: parent
                acceptedButtons: Qt.NoButton
                onWheel: wheel => {
                    // ── THE SHELL-WIDE SCROLL RULE, applied ──────────────
                    //
                    // This overlay is stacked ABOVE the card's scrollers, so
                    // it is the only thing that ever sees a wheel event over
                    // the song list: whatever it swallows, the list never
                    // gets. That is the price of the horizontal swipe, and
                    // it is the right trade -- but only if the overlay
                    // forwards properly when the gesture is vertical.
                    //
                    // It used to scroll the list ITSELF, by writing
                    // `scroller.contentY += dy` with its own arithmetic. That
                    // one line is the entire "slow, and stops dead" report
                    // for the music under the hero:
                    //
                    //   * it bypassed the scroller's gain, so the list tracked
                    //     the raw pad 1:1 instead of at the shell's rate --
                    //     roughly a third of the speed the same gesture gets
                    //     everywhere else, which is "very slow";
                    //   * and it bypassed the fling, so there was no coast at
                    //     all and the list halted the instant the fingers came
                    //     off the pad, which is the other half of it.
                    //
                    // The sidebar's music list never had either fault,
                    // because its overlay hands the event to the list's own
                    // handler. So: pick the scroller under the pointer, decide
                    // the axis, and ROUTE the event through the one door in
                    // scrollfling.js instead of moving the list here. Same
                    // gain, same momentum, same bounds as every other list in
                    // the shell, and no per-surface copy to drift.
                    // The list is in visual order, and the FIRST one that can
                    // actually move wins. `cardScrollTarget` leads because it
                    // is the scroller of the view that is on screen -- the
                    // trading tab's news today -- and it is null in every
                    // other mode, so the music tracklist below it keeps the
                    // gesture there. Note what is NOT here: the trading list
                    // is reached through the view's own publication, not by
                    // naming an id from this file, because ids do not cross
                    // files -- and the older note about a "category pane"
                    // referred to an id that never existed, which threw on
                    // every wheel event over the card.
                    const scroller = Fling.pickScrollable([root.cardScrollTarget, trackList]);
                    if (scroller && !root.panelSwipeHorizontal) {
                        const pd = wheel.pixelDelta;
                        const hasPixels = pd && (pd.x !== 0 || pd.y !== 0);
                        const deviceType = wheel.device?.type;
                        const isTouchpad = (deviceType !== undefined)
                            ? deviceType === PointerDevice.TouchPad
                            : hasPixels;
                        if (isTouchpad) {
                            const dx = root.wheelDx(wheel, hasPixels);
                            const dy = root.wheelDy(wheel, hasPixels);
                            // Axis lock with commitment, identical to the
                            // panel's own: a gesture that clearly means
                            // vertical belongs to the scroller, one that
                            // clearly means horizontal still switches views.
                            // Until it commits, the event is passed on to
                            // handlePanelWheel below exactly as before.
                            root.panelAccX += Math.abs(dx);
                            root.panelAccY += Math.abs(dy);
                            swipeReset.restart();
                            if (root.panelAccY > root.panelAccX * 1.25 && root.panelAccY >= 12) {
                                if (Fling.route(wheel, scroller)) {
                                    wheel.accepted = true;
                                    return;
                                }
                            }
                        }
                    }
                    root.handlePanelWheel(wheel);
                }
            }
}

        // Arrow keys swap the view; Escape puts the card away. A plain focused
        // Item: it holds focus and swallows no pointer input.
        Item {
            id: panelKeyCatcher
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    // One implementation of the key, shared with the window's
                    // Shortcut -- see `escaped()`. The two used to hold their
                    // own copies of these branches, and the window's copy was
                    // the one that could be disabled while an edit was
                    // (wrongly) still open, which is how Escape became a key
                    // that did nothing on the first press.
                    root.escaped();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Right) {
                    root.setMode(root.mode + 1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Left) {
                    root.setMode(root.mode - 1);
                    event.accepted = true;
                }
            }
        }
    }

    // Gesture-end reset for the panel's swipe accumulator (see the wheel
    // handler above): after 200ms with no events the gesture is over, so the
    // next one starts from zero and can fire again. (Replaced the old
    // direction-only `swipeLock`, which stepped once per EVENT -- one
    // physical swipe walked through several views.)
    //
    // 200ms, not 180ms: the island and the sidebar both use 200. Too short and
    // one physical swipe gets split and steps twice; too long and a fast
    // follow-up swipe arrives while the fired flag is still set, so it is
    // swallowed and the card looks like it dropped the input.
    Timer {
        id: swipeReset
        interval: 200
        onTriggered: root.resetPanelSwipe()
    }

    // ── Media facts ──────────────────────────────────────────────────────
    readonly property var player: MprisController.shownPlayer
    readonly property string artistText: {
        const a = root.player?.trackArtists ?? "";
        return Array.isArray(a) ? a.join(", ") : String(a);
    }
    readonly property string albumText: {
        // The bridge substitutes "Unknown Album" for a track that carries no
        // album tag. That is a fine thing for a log and a terrible thing for
        // a card: it reads as a real album called "Unknown Album". The line
        // is visibility-gated on being non-empty, so blanking the placeholder
        // is what actually removes it.
        const a = String(root.player?.trackAlbum ?? "").trim();
        return (a === "" || a.toLowerCase() === "unknown album") ? "" : a;
    }
    // The playlist the card is playing through, for the line under the title.
    // Empty when the track is not part of a scanned playlist, and the line is
    // hidden on empty rather than showing a placeholder.
    readonly property string playlistLineText: String(root.shownPlaylist?.name ?? "").trim()

    /**
     * The one line under the title: playlist, and album when it says anything
     * new.
     *
     * It used to be built inline as `playlist · album`, and on a local
     * library that printed the same word twice -- the folder is called
     * "My Breakcore" and the files inside it carry ALBUM=My Breakcore, so the
     * line read "My Breakcore  ·  My Breakcore". That is not a cosmetic
     * oddity: the playlist is the more important of the two (it is the only
     * thing on this screen that answers "why is the next track that one"),
     * and burying it in a duplicate makes the line read as noise.
     *
     * Compared case-insensitively, because folder and tag disagree on case
     * often enough that an exact test would let "my breakcore" through beside
     * "My Breakcore" and reintroduce the same thing.
     */
    readonly property string subLineText: {
        const pl = root.playlistLineText;
        const al = root.albumText;
        if (pl === "") return al;
        if (al === "") return pl;
        if (al.toLowerCase() === pl.toLowerCase()) return pl;
        return `${pl}  ·  ${al}`;
    }
    readonly property string provider: {
        const p = root.player;
        if (!p) return "";
        const id = (p.identity ?? "").toLowerCase();
        if (id.includes("spotify")) return "Spotify";
        if (id.includes("youtube")) return "YouTube Music";
        const src = `${p.trackArtUrl ?? ""}`.toLowerCase();
        if (src.includes("music.youtube")) return "YouTube Music";
        if (src.includes("youtube")) return "YouTube";
        return p.identity ?? "";
    }
    // ── Playback position: interpolated, not read ────────────────────────
    //
    // MPRIS `position` is a SNAPSHOT, not a clock. mpv's MPRIS plugin
    // publishes it on a track change and then, for the rest of the track,
    // leaves it alone -- nothing ticks it. So reading it directly gave a
    // number frozen at whatever the position was when the song started: the
    // scrubber sat at roughly zero for the whole track and both time labels
    // stood still, which is the "bar doesn't fill up" report.
    //
    // So the position is reconstructed here from two things: the last value
    // MPRIS actually reported, and how much wall time has passed since. The
    // base is re-synced from MPRIS whenever MPRIS does speak up (a seek, a
    // pause, a track change), so a local estimate can never drift far from
    // the truth -- the worst case is one tick of drift, not a whole track.
    property real _posBase: 0
    property int _posStamp: 0
    // Bumped by the ticker. The readonly property below has no other
    // dependency that changes during playback, so without this it would be
    // evaluated once and cached, and no amount of ticking would move it.
    property int _posTick: 0

    function syncPosition() {
        // Nothing to resync when the local mpv is the player on screen: the
        // position is read straight off the socket and the base is not used
        // at all. See `localMatch` and the note on `position`.
        if (root.localMatch)
            return;
        const p = MprisController.shownPlayer;
        if (!p)
            return;
        root._posBase = p.position ?? 0;
        root._posStamp = Date.now();
    }

    /**
     * Is the player on screen the LOCAL mpv daemon?
     *
     * The test is that both sides report the same track length to within a
     * second and a half. That is not a guess about identity strings: it is
     * the observation that the two are describing the same file on the same
     * player, which is the only thing the answer is used for.
     */
    readonly property bool localMatch: (MprisController.shownPlayer?.length ?? 0) > 0
        && MusicPlayer.hasTrack
        && Math.abs(MusicPlayer.duration
            - (MprisController.shownPlayer?.length ?? 0)) < 1.5

    readonly property real position: {
        // Read the ticker so this re-evaluates as playback proceeds.
        const _ = root._posTick;

        // THE LOCAL PLAYER IS THE TRUTH, not MPRIS.
        //
        // mpv's MPRIS plugin CACHES `Position`. It never learns about a seek
        // made over the ipc socket, so after a socket seek the two disagree
        // permanently: measured, mpv at 21.0s while MPRIS still reported
        // 112.3s and carried on from there. Interpolating that value -- which
        // is what everything below does -- means a seek that genuinely worked
        // gets dragged back to a position the song is not at. Holding the
        // base for a fixed window only postpones it; the bar snaps back the
        // moment the window ends.
        //
        // `MusicPlayer` observes `time-pos` off the same socket, so it is
        // correct immediately and stays correct. The interpolation below is
        // still needed for every OTHER player, where MPRIS really is all
        // there is -- it is only wrong for the one we can read directly.
        if (root.localMatch)
            return MusicPlayer.position;

        const p = MprisController.shownPlayer;
        if (!p)
            return 0;
        if (root._posStamp === 0)
            return p.position ?? 0;
        if (!(p.isPlaying ?? false))
            return root._posBase;
        const elapsed = (Date.now() - root._posStamp) / 1000;
        // Only extrapolate across a short, trustworthy interval. If the stamp
        // is old then the ticker was not running and the player has not been
        // reporting, so adding all that time in one go is a guess -- and it
        // was a guess that pinned the bar to 100% and the clock to 2:59.
        if (elapsed > 2)
            return root._posBase;
        const len = p.length ?? 0;
        const advanced = root._posBase + elapsed;
        // Never past the end: a missing or wrong `length` would otherwise let
        // the bar run off the right-hand edge.
        return len > 0 ? Math.min(advanced, len) : advanced;
    }

    // Keeps the base and its timestamp FRESH, which is the whole job.
    //
    // This deliberately does NOT stop when the panel is closed. Gating it on
    // `root.open` let the timestamp age for as long as the panel was shut, so
    // the first evaluation after reopening added every one of those seconds at
    // once -- measured, it pinned progress at 100.0% with the clock reading
    // 2:59 while the song was three seconds in. A 500ms timer that re-anchors
    // whenever the real player disagrees is cheap, and it makes the stale-
    // timestamp case impossible rather than merely unlikely.
    Timer {
        interval: 500
        repeat: true
        running: MprisController.shownPlayer !== null
        onTriggered: {
            root._posTick++;
            const p = MprisController.shownPlayer;
            if (!p)
                return;
            const reported = p.position ?? 0;
            // Re-anchor when the real player disagrees with where we think we
            // are. The tolerance is needed because MPRIS rounds to whole
            // seconds; comparing exactly would re-anchor on every tick and
            // hold the bar at the reported value instead of letting it glide.
            if (Math.abs(reported - root._posBase) > 1.5 || Date.now() - root._posStamp > 2000)
                root.syncPosition();
        }
    }

    // MPRIS does signal a track change, and that is the one moment the base
    // must be thrown away outright rather than carried forward.
    Connections {
        target: MprisController.shownPlayer
        function onPositionChanged() {
            root.syncPosition();
        }
        function onPlaybackStateChanged() {
            root.syncPosition();
        }
    }
    Connections {
        target: MprisController
        function onTrackChanged() {
            root.syncPosition();
        }
    }

    // ── Scrubbing ───────────────────────────────────────────────────────
    //
    // True while a pointer is down on the scrubber. While it is, the bar and
    // BOTH time labels show `scrubTarget` instead of the real position, so the
    // thing under the cursor is the thing being read. Nothing is sent to the
    // player until the pointer comes up: MPRIS `seek` is a DBus round-trip
    // per call, and issuing one per drag event made the player stutter and
    // queue dozens of seeks behind the gesture.
    property bool scrubbing: false
    property real scrubTarget: 0
    property bool scrubHover: false
    property real scrubHoverAt: 0

    /** Can this player be seeked at all? Some MPRIS implementations cannot. */
    readonly property bool seekable:
        (MprisController.shownPlayer?.positionSupported ?? false)
        && (MprisController.shownPlayer?.length ?? 0) > 0

    /**
     * Is music actually PLAYING? (requested 2026-10-03)
     *
     * Read from MPRIS, which is where this bar already gets everything else:
     * `duration`, `position` and `volume` are all `shownPlayer` properties, so
     * this is the same player's state the bar is about to draw. Gating on a
     * different source would let the two disagree.
     *
     * That disagreement is not hypothetical. The music SERVICE reports
     * `track=- pos=0/0` at the same moment MPRIS reports
     * `PlaybackStatus "Stopped"` with `Position 107048000` and a real track
     * loaded -- so a predicate built on the service would have hidden the bar
     * for a stopped track while a predicate built on "is there a track" would
     * have SHOWN it, which is the thing being asked to go away. Only
     * playback status answers the question as asked: playing, or not.
     *
     * Verified against the Quickshell MprisPlayer docs, which is where the
     * earlier version of this went wrong. There is no `playbackStatus`
     * property: the state is `playbackState`, an ENUM, and there is no
     * `toString()` on it that yields "Playing" -- so
     *   (player?.playbackStatus ?? "") === "Playing"
     * was a comparison of undefined to a string, i.e. false forever, and the
     * spectrum stayed hidden even with music playing. The bool the same
     * player exposes IS documented and is exactly this predicate:
     *   isPlaying : "True if playbackState == MprisPlaybackState.Playing."
     * That is the property this uses.
     *
     * The MPRIS enum is Playing / Paused / Stopped, and only "Playing" shows
     * the spectrum -- so pausing takes it away and resuming brings it back.
     */
    readonly property bool musicPlaying:
        MprisController.shownPlayer?.isPlaying ?? false

    /** Where the bar and the clocks read from: the drag, or the truth. */
    readonly property real displayPosition: root.scrubbing
        ? root.scrubTarget : root.position

    /**
     * Seek to a fraction of the track. MPRIS `seek` takes an OFFSET and
     * `position` is read-only, so an absolute seek has to be expressed as
     * "how far from where I am now" -- and measured against the interpolated
     * position, not the raw one, or every seek would be short by however long
     * the last resync was ago.
     */
    function seekToFraction(f) {
        const p = MprisController.shownPlayer;
        if (!p || !root.seekable) return;
        const len = p.length ?? 0;
        if (len <= 0) return;
        const target = Math.max(0, Math.min(len, f * len));
        const delta = target - root.position;
        // Under half a second is not a seek, it is a rounding artefact from
        // the interpolation, and mpv treats a near-zero seek as a no-op.
        if (Math.abs(delta) < 0.5) return;
        // SECONDS, not microseconds.
        //
        // MPRIS2's `Seeked` offset is defined in microseconds, which makes it
        // very tempting to multiply by 1e6 here. Do not: Quickshell's
        // MprisPlayer.seek already does that conversion, and doing it twice
        // asks mpv to jump five hours. Measured, a double-scaled seek to the
        // midpoint of a 182s track did not land at 91s -- it ran to the end
        // and rolled on to the next song.
        //
        // And the reason this took two attempts to pin down: the obvious way
        // to check, reading the position back through MprisController, is
        // worthless here, because that value is the same stale MPRIS cache
        // this whole file exists to work around. It has to be read off the
        // bus directly.
        // EXACTLY ONE SEEK, and which one depends on who is playing.
        //
        // Sending both is what made "clicking the bar doesn't work": MPRIS's
        // `seek()` is RELATIVE, so the socket's absolute jump to the target
        // followed by MPRIS's offset landed at TWICE the requested position.
        // Measured: a click at 30% of a 192s track (57.6s) put the song at
        // 115.6s. Two correct seeks, added together, one wrong answer.
        //
        // The local mpv goes through the socket, because that is also where
        // the position is read from -- see `position` -- so the thing that
        // moved the song and the thing the bar draws are the same source and
        // cannot disagree.
        if (root.localMatch) {
            MusicPlayer.seekTo(target);
        } else {
            p.seek(delta);
        }

        // The base is only read by the MPRIS interpolation, which the local
        // player no longer uses. Setting it keeps `seekProbe` honest for the
        // other players.
        root._posBase = target;
        root._posStamp = Date.now();
        // The player will report its new position on its own schedule, but the
        // base is what the bar is measured from, so move it now rather than
        // letting the bar visibly snap backwards and then catch up.
        root._posBase = target;
        root._posStamp = Date.now();
    }

    /** Map a pointer x within the bar to a 0..1 fraction. */
    function fractionAt(x, width) {
        if (!width || width <= 0) return 0;
        return Math.max(0, Math.min(1, x / width));
    }

    readonly property real progress: {
        const len = root.player?.length ?? 0;
        if (!len || len <= 0) return 0;
        return Math.max(0, Math.min(1, root.displayPosition / len));
    }
    function clock(sec) {
        const s = Math.max(0, Math.floor(sec ?? 0));
        return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
    }

    // ── The current playlist ────────────────────────────────────────────
    // The file that is actually playing, as an absolute path. This is the join
    // key for everything below and it is deliberately NOT queuePos: the queue
    // can be shuffled, filtered to one track, or hold tracks from several
    // folders, so an index into it says nothing about which playlist is on
    // screen.
    readonly property string playingPath:
        MusicPlayer.queue[MusicPlayer.queuePos]?.filename ?? ""

    // Which scanned folder the playing file lives in. A path is in at most one
    // folder, so the first match is also the only match.
    readonly property var currentPlaylist: {
        const p = root.playingPath;
        if (p === "") return null;
        for (const pl of MusicPlayer.library)
            for (const t of (pl.tracks || []))
                if (t.path === p) return pl;
        return null;
    }

    // ── What the card shows when nothing is playing ──────────────────────
    //
    // `currentPlaylist` is derived from the PLAYING file, so the instant
    // playback stopped -- or the file was not in a scanned folder -- the list
    // went blank and the card said "No playlist playing", throwing away a
    // playlist the user had been looking at a second earlier. Pausing music
    // emptied the panel.
    //
    // So the card keeps the last playlist it saw. It is a REFERENCE to the
    // playlist object, not a copy of its tracks: the library is rebuilt from
    // scratch on every scan, so a copied array would freeze the rows -- and
    // their covers -- at whatever the scan knew when the music stopped, and
    // would then disagree with the rail in the sidebar.
    property var lastPlaylist: null
    property string lastPlayingPath: ""
    readonly property var shownPlaylist: root.currentPlaylist ?? root.lastPlaylist
    // The row that carries the accent rule and the live meter. While something
    // plays that is the playing track; once it stops, the list stays pointing
    // at the track it stopped on, so it reads as "paused here" rather than as
    // a list that forgot where it was.
    readonly property string markedPath:
        root.playingPath !== "" ? root.playingPath : root.lastPlayingPath
    onCurrentPlaylistChanged: {
        if (!root.currentPlaylist) return;
        root.lastPlaylist = root.currentPlaylist;
        root.lastPlayingPath = root.playingPath;
    }
    onPlayingPathChanged: {
        if (root.playingPath !== "") root.lastPlayingPath = root.playingPath;
    }

    // The rows the list renders. Durations are attached HERE, at read time,
    // rather than being stored on the track: the library is rebuilt on every
    // scan and a duration written onto the track at parse time would be lost
    // every time the cache gained a new entry.
    readonly property var playlistTracks: {
        const pl = root.shownPlaylist;
        if (!pl) return [];
        return (pl.tracks || []).map(t => ({
            path: t.path,
            title: t.title,
            artist: t.artist,
            // The cover the scanner already found for this file: a sibling
            // cover file in its folder, or the frame pulled out of the mp3
            // into the shared cache. Carried on the track by the scan, and
            // simply not being passed on to the rows before.
            art: t.art ?? "",
            duration: MusicPlayer.durationOf(t.path),
        }));
    }

    // -1 when nothing in the list is playing, which is also what tells the
    // ListView not to scroll and what keeps the scrubber's "Track n of m"
    // from claiming there is a track 0.
    readonly property int currentTrackIndex: {
        const p = root.markedPath;
        if (p === "") return -1;
        return root.playlistTracks.findIndex(t => t.path === p);
    }

    /** "M:SS left" — the number that answers "do I have time". */
    function timeLeft() {
        const len = MprisController.shownPlayer?.length ?? 0;
        if (!len) return "";
        // root.position, not the raw MPRIS value: this label used to read the
        // same frozen snapshot the scrubber did, so "1:37 left" sat unchanged
        // for the rest of the track.
        return root.clock(Math.max(0, len - root.displayPosition));
    }

    // ── Performance instruments ──────────────────────────────────────────
    // The island's four readings (see NowBar's perfGauges -- same keys, same
    // order), plus the two things only a card has room for: a caption saying
    // what each number is a fraction OF, and a chart big enough to read the
    // shape of rather than just the last point.
    //
    // The list is DELIBERATELY static: only each instrument's identity lives
    // here. The live numbers used to sit in this array, which made the
    // Repeater's model change on every sampling tick -- and Qt answers a model
    // change by tearing the delegates down and rebuilding them, so all four
    // gauge tiles were destroyed and recreated every second, which read as the
    // performance view flashing and lagging every time it refreshed. The live
    // half is read inside the delegates through the perf* functions below:
    // those are property bindings (they re-evaluate when the services change)
    // instead of model entries, so the tiles persist and only values tick.
    readonly property var perfGauges: [
        { key: "cpu", name: Translation.tr("CPU"), icon: "planner_review", accent: Appearance.colors.colPrimary },
        { key: "ram", name: Translation.tr("RAM"), icon: "memory", accent: Appearance.colors.colTertiary },
        { key: "gpu", name: Translation.tr("GPU"), icon: "developer_board", accent: Appearance.colors.colSecondary },
        { key: "temp", name: Translation.tr("Temp"), icon: "thermostat", accent: Appearance.colors.colError }
    ];

    // The live half of perfGauges. Reading a service property from inside a
    // function called by a binding still registers the dependency, so these
    // re-evaluate on every sample without ever changing the model.
    // ── The live GPU number ────────────────────────────────────────────
    //
    // The discrete card's utilization, by way of SystemNow (gpuMetric*), so
    // this card, the island's gauges, the bar pocket and the task manager
    // cannot drift apart. It briefly read the chip that renders the desktop
    // instead; that is reverted -- see SystemNow for the two measurements that
    // ended it ("Intel Graphics 100%" from a frozen RC6 counter).
    function gpuMetricValue() {
        return SystemNow.pct(SystemNow.gpuMetricPct);
    }
    function gpuMetricSeries() {
        return SystemNow.gpuMetricHistory;
    }

    function perfValue(key) {
        if (key === "cpu") return SystemNow.pct(SystemNow.cpuPct);
        if (key === "ram") return SystemNow.pct(SystemNow.ramPct);
        if (key === "gpu") return root.gpuMetricValue();
        if (key === "temp") return SystemNow.tempText(SystemNow.tempC);
        return "--";
    }
    // The wattage itself, for the tooltip. Cheap to expose and it turns "7%"
    // into "7% (3.8 W of 55 W)", which is a complete sentence.
    function perfLoad(key) {
        if (key === "cpu") return SystemNow.cpuPct;
        if (key === "ram") return SystemNow.ramPct;
        if (key === "gpu") return SystemNow.gpuMetricPct;
        if (key === "temp") return SystemNow.tempLoad(SystemNow.tempC);
        return -1;
    }
    function perfCaption(key) {
        if (key === "cpu") return HardwareStats.cpuThreads > 0
            ? Translation.tr("%1 threads").arg(HardwareStats.cpuThreads) : "";
        if (key === "ram") return Translation.tr("of %1").arg(ResourceUsage.maxAvailableMemoryString);
        // Names the CHIP. The percentage beside it is a busy fraction now
        // (utilization), the same kind of number as the CPU and RAM tiles, so
        // there is no denominator left to state -- and on a machine with two
        // graphics chips, WHICH chip the number belongs to is the useful thing
        // a caption can add.
        //
        // The wording here used to be "of 55 W limit", which belonged to the
        // capacity reading this gauge no longer draws. The wattage did not go
        // anywhere: it is the GPU power row further down this same tab, where
        // it reads "4.2 of 55 W" and is labelled as watts rather than implied
        // by a percentage.
        // The card the percentage belongs to: the discrete GPU, named as the
        // inventory spells it (minus the maker suffix -- see shortGpuName).
        if (key === "gpu") {
            return root.shortGpuName() !== ""
                ? root.shortGpuName()
                : (SystemNow.gpuClockMhz >= 0 ? Translation.tr("%1 MHz").arg(Math.round(SystemNow.gpuClockMhz)) : "");
        }
        if (key === "temp") return root.tempState(SystemNow.tempC);
        return "";
    }

    // The row descriptors for one category: { label, value, live }.
    // Values are re-read on every access; the binding re-evaluates when
    // SystemFacts (rarely) or the picked category changes.
    // The pane's rows: just the picked category's, through the function so
    // the delegate binding tracks the selection without changing the model
    // array identity every tick.
    // A graphics chip's inventory name is written for a spec sheet, not for a
    // caption line: "Intel Corporation Kaby Lake-R GT2 [UHD Graphics 620] (rev
    // 07)" spends half its width on a company suffix and a hardware revision
    // nobody reads at a glance. Those two go; the rest stays verbatim (so an
    // unfamiliar chip still prints its full name rather than a guess).
    function shortGpuName() {
        return SystemNow.gpuName
            .replace(/\s*\((?:rev|revision)[^)]*\)\s*$/i, "")
            .replace(/\s+(Corporation|Inc\.?|Corp\.?|Ltd\.?)\b/g, "")
            .trim();
    }

    // ── The System tab's live rows ───────────────────────────────────────
    //
    // Each of these answers something the four gauges above cannot, because a
    // percentage is not a number you can act on: "GPU 13%" does not say whether
    // the card is being held at a 55 W ceiling or a 140 W one, and a memory bar
    // does not say the machine has a 240 Hz panel it is driving at 60. Every
    // value here comes off the tick SystemNow already runs or the counters
    // HardwareStats already keeps, so a row costs one function call and no
    // sampling of its own.

    // ── Disk and network rows: REMOVED ──────────────────────────────────
    //
    // `diskActivityRow`, `networkActivityRow` and the three helpers that existed
    // only for them (`rateText` for the units, `busiestDisk` and
    // `busiestNetwork` for picking which drive and which interface to name) are
    // gone with their rows: throughput is a quantity that moves when something
    // copies, not a measurement of this hardware, and both rows were the kind a
    // reader skips past to reach the ones they came for.
    //
    // Nothing lost a source. HardwareStats still samples every disk and every
    // interface -- the Performance view and the task manager draw them -- so the
    // only thing that left is the pair of rows on this tab.

    // The display, read from the COMPOSITOR rather than from a spec sheet: the
    // mode it is being driven at right now. This machine runs 60 Hz while the
    // panel advertises a single 240 Hz mode, and whether that is deliberate or a
    // power mode's doing is not something a bare "60 Hz" can tell you -- which
    // is why the two rows travel together.
    function focusedMonitor() {
        const list = HyprlandData.monitors ?? [];
        return list.find(m => m.focused) ?? (list.length > 0 ? list[0] : null);
    }
    function displayModeRow() {
        const m = root.focusedMonitor();
        if (!m) return "—";
        return `${m.width}×${m.height} @ ${Math.round(m.refreshRate ?? 0)} Hz`;
    }
    // ── Panel row: REMOVED ──────────────────────────────────────────────
    //
    // `panelMaxRow` reported the display's own ceiling (fastest advertised rate,
    // plus VRR) as a row beside a live readout. It is a fact about the panel, not
    // about what the machine is doing with it, so the ceiling moved out and the
    // mode it is being DRIVEN at kept the row above (displayModeRow, read from
    // the compositor). The ceiling itself is still one page away, listed as a
    // mode on Settings > Display (DisplayConfig.qml reads the same list), so
    // nothing became unknowable -- it just stopped being a row that never
    // changes sitting among rows that do.

    // The card, named, then the ceiling it COULD be given: "RTX 4070 · 140 W
    // max". Three different wattages now live on this tab and they are not
    // interchangeable:
    //
    //   * 140 W -- power.max_limit: what the silicon may be allowed at all. A
    //     property of the board, read off the same nvidia-smi sample as
    //     everything else here.
    //   * 50 W -- the enforced limit: what the power-mode buttons have currently
    //     allowed it. It is the denominator on the GPU power row and the divisor
    //     behind the GPU gauge above, so those two cannot disagree.
    //   * the live draw itself, on the GPU power row.
    //
    // None of the three is the machine's total draw. Omitted when the card has
    // never answered (the driver returns [N/A] for a parked card), so an unknown
    // ceiling shortens the row instead of printing a number nobody measured.
    function gpuIdentityRow() {
        const name = root.gpuDisplayName();
        return SystemNow.gpuPowerMaxW > 0
            ? `${name} · ${Math.round(SystemNow.gpuPowerMaxW)} W max`
            : name;
    }

    // The watts, WITH the ceiling they belong to -- the ceiling being the part a
    // power mode moves. nvidia-smi's plain power.limit answers [N/A] on this
    // driver; the enforced limit is what the board actually applies, and it is
    // the same denominator the GPU gauge above reports its percentage of, so the
    // two surfaces cannot contradict each other.
    //
    // WHOSE WATTS THESE ARE, because the row used to leave it open.
    //
    // This is the graphics card's OWN board draw, measured by the card, which is
    // why its label now reads "GPU power" rather than "Power draw". It is not
    // this machine: on mains the laptop cannot report total system watts at all
    // (ACPI exposes AC0's online flag and no current), and the processor
    // package's energy counter is root-only. On battery the whole-machine figure
    // IS available -- that is what the battery column beside this one shows --
    // but the two are different measurements, and this row no longer reads as
    // the other one. Checked against the card side by side: this row's draw and
    // limit track nvidia-smi's power.draw and enforced.power.limit exactly.
    // ── The GPU cell's caption, in full ──────────────────────────────────
    //
    // One line, two facts, and they take turns rather than share. The cell is
    // about 150 px wide and its caption is the smallest type in the card, so
    // cap + mechanism + memory at once would elide into a smear.
    //
    // The second fact is the memory a locally running model holds, and while
    // there is one it WINS the slot, because that is the number the reader
    // compares against: reported as the model's own reservation (LlamaService
    // -- the same figure its tab prints) rather than as the device total, which
    // happens to be the same number here only because the model is the only
    // thing using the card. The complaint this answers was exactly that gap --
    // "the local llm shows vram 7.4 out of 8, but the System tab does not show
    // that that is the true value".
    //
    // With no model loaded the memory is not interesting and the mechanism word
    // is (is the card held at 55 W, or boosted?), so that is what shows
    // instead, exactly as it did before.
    function gpuVramShort() {
        if (LlamaService.vramMiB > 0)
            return Translation.tr("VRAM %1/%2 GB")
                .arg(LlamaService.vramGiB.toFixed(1))
                .arg(LlamaService.vramTotalGiB.toFixed(1));
        return "";
    }
    function gpuCaption(capText, mechanism) {
        const mem = root.gpuVramShort();
        if (mem !== "")
            return `${capText} · ${mem}`;
        return mechanism === "" ? capText : `${capText} · ${mechanism}`;
    }

    function gpuDrawRow() {
        if (SystemNow.gpuPowerDrawW < 0) return "—";
        return SystemNow.gpuPowerLimitW > 0
            ? `${SystemNow.gpuPowerDrawW.toFixed(1)} of ${Math.round(SystemNow.gpuPowerLimitW)} W`
            : `${SystemNow.gpuPowerDrawW.toFixed(1)} W`;
    }
    // ── GPU clock row: REMOVED ──────────────────────────────────────────
    //
    // It read "210 / 3105 MHz · 45 °C". The clock goes, and so does the GPU
    // TEMPERATURE that rode on the end of it -- which leaves the card's
    // temperature with no home on this tab at all (the band's Temp cell is the
    // processor package sensor, and gt_cur_freq_mhz on this machine belongs to
    // the Intel chip, which is why the row's clock was the 4070's but its bed
    // was not). If it is missed, the GPU power row has the room: "6.7 of 50 W ·
    // 46 °C", and SystemNow.gpuTempC is still sampled either way.
    //
    // What answered the question the row was really asked -- how parked is the
    // card? -- is the wattage one row up, drawn against the cap in force. That
    // is the same fraction the gauge above already divides, and 210 MHz never
    // said it: MHz is a number you have to know the ceiling to read.

    // What a temperature means, in a word. The bar and the chart show the
    // level and the trend; neither of those answers the question a temperature
    // reading is actually asked -- whether 71 °C is fine or alarming.
    function tempState(v) {
        if (v < 0) return "";
        if (v < 55) return Translation.tr("Cool");
        if (v < 75) return Translation.tr("Warm");
        return Translation.tr("Hot");
    }

    // ── AI weekly grid: REMOVED ──────────────────────────────────────────
    //
    // `aiCell`, `aiSeries`, `aiDays`, `aiPeak`, `aiWeeklySummary` and
    // `aiCellColor` all read `FlareData.usageCells` -- Claude/ChatGPT
    // subscription quota, drawn as a four-week heat grid. The tab is now the
    // local llama.cpp console (see the view above and services/LlamaService),
    // which is a fact about this machine rather than about a plan, so all six
    // are dead and have been deleted rather than left behind an unused
    // binding.
}

















