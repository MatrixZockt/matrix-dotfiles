import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.modules.common.flare
import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Mpris

/**
 * The center island: the NOW bar.
 *
 * One compact view that always answers "what is happening right now":
 *   0 — pomodoro    (countdown + "timer" caption + transport, while a timer runs)
 *   1 — media       (track + artist + live waveform, while anything plays sound)
 *   2 — AI          (the top provider's usage today, the resting state)
 *   3 — performance (the machine itself: CPU / RAM / GPU bubbles)
 *
 * Audio always wins: the instant an MPRIS player starts (YouTube in the
 * browser, Spotify, mpv) the bar swaps to the media view with a live
 * waveform, and falls back to the pomodoro/AI view when the sound stops.
 * Two-finger horizontal swipe (MouseArea.onWheel -- the only wheel path
 * this Qt delivers on layer surfaces) or scroll flips the views by hand;
 * a manual choice holds for 15s before the auto priority takes back over.
 * Performance is never automatic -- nobody wants the machine's own numbers
 * to interrupt a song -- so it is only ever reached by hand.
 *
 * Hovering does nothing visually -- the island only reacts when it is
 * genuinely open. A THREE-FINGER SWIPE DOWN, while the cursor is over this
 * island, pops it out: the island morphs into a floating card under itself
 * (NowBarPanel) that stays until you press outside it, and while it is out
 * the capsule in the bar grows slightly and takes the accent ring, so the
 * card reads as this island enlarged (see BarContent's open tell). The
 * hover requirement is a handshake: this island publishes its hover state
 * to a runtime file and the compositor's gesture reads it (see the
 * publisher block below).
 */
Item {
    id: root

    // The island HUGS its content: the widest view plus the room the stage
    // needs. This has to be the truth, not a fixed 360 floor -- the bar's
    // centre capsule measures its background off this width (see
    // BarContent's centerIsland), so a fixed floor that the content exceeds
    // leaves the capsule narrower than what it carries.
    //
    // `stage.contentWidth`, NOT `stage.width`. The stage now spans the whole
    // island (see below), so asking it for its width here would be a loop:
    // island -> stage -> island, which QML breaks by giving up and
    // returning 0. The stage publishes what its views ASK for separately,
    // and that is the number the island is sized from.
    readonly property real contentWidth: stage.contentWidth
    implicitWidth: Math.max(360, root.contentWidth)
    implicitHeight: Appearance.sizes.baseBarHeight - 6


    // Ring order. System is index 0: its tick is then the LEFTMOST dot under
    // the island (the request -- the active bar sat "all the way on the
    // right" because System was tab 3 of 5 in the old ring), and the island's
    // resting view being System now agrees with the tick order too. The
    // panel's chip row leads with System for the same reason (NowBarPanel).
    // Four views: the old Lighting view retired -- profile switching lives in
    // the card's System tab (a dropdown over RazerService's mirror) and in
    // Razer Command Center itself.
    readonly property int modePerf: 0
    readonly property int modeMedia: 1
    readonly property int modePomodoro: 2
    readonly property int modeAi: 3
    readonly property int modeTrading: 4
    // ── The activity tab ───────────────────────────────────────────────
    // A package update, or a file coming down. This tab is NOT one of the
    // ring's permanent five: it exists only while something is actually
    // happening, so the island's ring grows by one tab for the duration and
    // shrinks back afterwards. It is a real view in the ring rather than
    // something painted over the live one -- an overlay collided with the
    // performance readings it was drawn on top of, which is exactly the
    // report this answers.
    // ── Dictation, a real tab of the ring ──────────────────────────────
    // NOT a badge beside the island and not a transient tab either: it is the
    // sixth permanent view, so the island's own switcher (the arrows, the
    // swipe, a cycle) lands on it like any other, and while SUPER is held the
    // island walks to it by itself. Its idle state says what the gesture is,
    // which is where a user finds it in the first place.
    //
    // Permanent rather than "only while recording" (the activity tab's shape)
    // because a tab that appears and disappears cannot be tapped: the ring's
    // indices would also move under the user's finger between swipes.
    readonly property int modeDictation: 5
    /// Something is running that has progress worth a tab: an update of a
    /// DESKTOP APP (see PackageUpdate.showsInBar -- a library-only transaction
    /// is silent by request), or a download from the bar's own downloader.
    readonly property int modeProgress: 6
    readonly property bool progressShowing: PackageUpdate.showsInBar
        || GlobalStates.downloadProgress >= 0
    readonly property bool dictationShowing: Dictation.showing

    readonly property int modeCount: 6 + (root.progressShowing ? 1 : 0)

    property int mode: root.modePerf

    // Pins the skip arrows' hover look on, for looking at. See
    // SkipArrow.held: the ring is a 1px border that only lights when the
    // pointer is within a few pixels of the arrow, which is not something to
    // judge by waving a mouse around. Off by default, and it is a switch
    // rather than a preview -- there is nothing to choose here any more.
    //   qs -c ii ipc call nowbar skipRing hold   -> both rings on
    //   qs -c ii ipc call nowbar skipRing off    -> back to hover only
    property bool skipRingHold: false
    // Which clock the TIMER tab is showing: false is the pomodoro countdown,
    // true is the stopwatch. UI state, not service state -- TimerService owns
    // both clocks' numbers and neither one owns which of them the island is
    // currently reading out, because the card and the sidebar each have their
    // own answer to that and must not fight over this one.
    //
    // Deliberately NOT persisted: a tab that comes back after a restart
    // showing a stopwatch nobody started is a mystery, and the pomodoro is
    // the clock the tab is named for.
    property bool stopwatchMode: false
    // The first sample of the fill-axis regression test, parked on the root
    // because the probe's locals are invisible to its Timer and an
    // IpcHandler holds no properties of its own.
    property real fillProbeNow: 0
    // Self-limiting. A hold that outlives its purpose is indistinguishable
    // from a broken hover ring -- it was left on once and the borders sat
    // there permanently, which is the one thing a hover ring must never do.
    // 20s is long enough to study both arrows and short enough that nobody
    // is ever left looking at permanently bordered buttons.
    Timer {
        id: skipRingTimer
        interval: 20000
        onTriggered: root.skipRingHold = false
    }

    // What a press on the island's BODY does (its two buttons act on their
    // own -- see inputArea). The media view opens the FULL music player --
    // the whole Music interface (library, playlists, artwork, transport) in
    // its own window, MusicPlayerPanel --
    // because the little MPRIS card that used to come up here is a "No
    // active player" placeholder more often than not and reads as a broken
    // popup. Every other view pops the island's own card out from under the
    // bar. Either way pressing the bar opens something: a press used to
    // fall through the views and die there, which read as a dead island.
    // A press on the island body ALWAYS pops the island's own card out from
    // under the bar -- on every view, media included.
    //
    // The media view used to be special-cased to launch the separate music
    // player app instead, which meant tapping the bar while a song played
    // threw up a completely different, light-coloured window rather than the
    // top-middle popup. That read as the bar spawning a random second player.
    // The card already HAS a full media view (NowBarPanel's "Playing" tab:
    // artwork, progress, transport), so it is the right answer everywhere and
    // there is no longer any need to cross the engine boundary here.
    function backgroundTap() {
        GlobalStates.nowBarPanelOpen = !GlobalStates.nowBarPanelOpen;
    }

    // Sampling the machine is only worth anything while its numbers are on
    // screen, and this is where that is decided for the island's own view.
    // (The panel turns it on for itself -- see NowBarPanel.)
    readonly property bool perfVisible: root.mode === root.modePerf

    // ── Auto priority: timer > sound > performance (resting) ──────────
    // No instant swaps: whatever is on the island keeps it for a beat, and
    // only after the swap delay does the highest-priority ACTIVE service
    // take over. Performance is THE resting view, not the last resort: the
    // card leads with System, and the island now rests on it too. AI usage
    // is out of the auto rotation on purpose -- an active meter used to
    // hold the resting view for hours at a stretch; AI stays one swipe (or
    // one card tab) away, with the ticks announcing the landing.
    // ANY app making sound, not just one with an MPRIS player: a game and
    // Discord have no bus at all, and a browser's bus is unreliable, so asking
    // a player kept the island on the resting view while sound was playing.
    readonly property bool audioPlaying: MprisController.soundOutputActive
        || (MprisController.shownPlayer?.isPlaying ?? false)
    // Pressing play should put the island on the media view -- and the sound
    // bar with it -- straight away, not up to `autoSwapDelayMs` later.
    //
    // The 7s delay exists so a view change never yanks the island out from
    // under someone mid-read. A track STARTING is not that case: nothing is
    // being interrupted, and the entire point of pressing play is to see the
    // thing you just started. Measured, the old path put a half-second of
    // dead bar between the press and the first frame -- the cava pipeline
    // alone needs ~500ms to spawn and emit, so the meter was always late.
    // NOT readonly: this holds the PREVIOUS value of `audioPlaying`, and it
    // has to be written back on every change to spot a rising edge. Declaring
    // it `readonly` while assigning it below makes Qt reject the write on
    // every evaluation, and the assignment is what records the edge.
    property bool prevAudioPlaying: false
    onAudioPlayingChanged: {
        // Swap the island IMMEDIATELY on a track starting. This used to wait
        // 220ms on a timer, justified in a comment as "shorter than the
        // pipeline's own startup, so the waveform is already there to draw".
        // That was measuring the wrong thing: the island swap is not gated on
        // the waveform, and a 220ms wait puts a visible dead beat between the
        // press and the bar changing. The pipeline is now pre-warmed on hover
        // of the play control (AudioVisualizer.warm), so by the time the click
        // lands the meter is already running and there is nothing to wait for.
        if (root.audioPlaying && !root.prevAudioPlaying) {
            AudioVisualizer.warm();
            // But NOT into an open card. This handler writes `root.mode`, and
            // the island and the popped-out card are ONE piece of state
            // (GlobalStates.nowBarMode), so a track starting while the card was
            // up dragged it off whatever tab the user had opened -- the exact
            // shape of "the user opened a tab on purpose and it was taken away"
            // that the swap timer below already documents, arriving through the
            // one door that guard does not cover.
            //
            // The press-to-play case the comment above is about is untouched:
            // nothing is popped out, the island still swaps the instant the
            // track starts. The track still gets its waveform either way
            // (`warm` is unconditional), and the card left where it was gets
            // walked back to the media view by the standing swap once it
            // closes -- see onNowBarPanelOpenChanged.
            // ...and never while the microphone is open. Dictation outranks
            // sound: something starting to play mid-sentence (a notification
            // chime, the track that was queued) used to yank the island to the
            // media view and take the meter off the screen at the exact moment
            // it mattered.
            if (!GlobalStates.nowBarPanelOpen && root.mode !== root.modeMedia
                    && !root.dictationShowing)
                root.setMode(root.modeMedia);
        }
        root.prevAudioPlaying = root.audioPlaying;
    }
    readonly property bool pomodoroRunning: TimerService.pomodoroRunning
    // The stopwatch counts as "the timer tab has something to show", for the
    // same reason a running pomodoro does: `autoMode` is what the island
    // walks itself back to after 7s of the user not touching it, and it only
    // returned to the timer tab for a RUNNING pomodoro. Left alone, the
    // stopwatch mark would be reachable for exactly seven seconds and then the
    // island would leave the tab -- the probe caught it exactly that way, with
    // every timer control reading `islandBody` and view 0 at opacity 1,
    // because `armed` follows `mode` and the island had gone back to System.
    //
    // `stopwatchTime > 0` as well as `stopwatchRunning`: a stopwatch that has
    // been started and paused still has a reading worth glancing at, and
    // without that half the island abandons a paused clock the moment the
    // user looks away.
    readonly property bool stopwatchShowing: root.stopwatchMode
        && (TimerService.stopwatchRunning || TimerService.stopwatchTime > 0)
    // Dictation first: the meter has to stay on screen while SUPER is held,
    // whatever else starts or stops in the meantime.
    readonly property int autoMode: root.dictationShowing
        ? root.modeDictation
        : root.progressShowing
        ? root.modeProgress
        : (pomodoroRunning || stopwatchShowing)
            ? root.modePomodoro
            : (audioPlaying ? root.modeMedia : root.modePerf)

    // The activity tab comes and goes with the work itself. It is entered
    // automatically (nobody wants to hunt for the tab that is showing the
    // thing they started), and left automatically the moment the work ends --
    // a tab that outlives its progress is a dead end, and the ring has no
    // room for one. An open card is a deliberate act and is never taken
    // away here, for the same reason the auto swap stands down for it.
    onProgressShowingChanged: {
        if (root.progressShowing) {
            if (root.mode !== root.modeProgress && !GlobalStates.nowBarPanelOpen)
                root.setMode(root.modeProgress);
        } else if (root.mode === root.modeProgress) {
            // NOT `autoMode` here. That property is itself derived from
            // `progressShowing`, and inside this notification it can still
            // hold the old answer -- 5 -- so the island would "leave" the
            // tab by re-selecting it and stay parked on a tab that no longer
            // exists. The fallback is spelled out instead.
            root.setMode((root.pomodoroRunning || root.stopwatchShowing)
                ? root.modePomodoro
                : (root.audioPlaying ? root.modeMedia : root.modePerf));
        }
    }

    // The dictation tab is permanent, but the island still goes to it by
    // itself when the microphone opens -- nobody starts talking to watch the
    // System tab -- and steps back to its resting view once the text is typed.
    // The tab stays reachable either way.
    onDictationShowingChanged: {
        if (root.dictationShowing) {
            if (!GlobalStates.nowBarPanelOpen)
                root.setMode(root.modeDictation);
        } else if (root.mode === root.modeDictation) {
            root.setMode((root.pomodoroRunning || root.stopwatchShowing)
                ? root.modePomodoro
                : (root.audioPlaying ? root.modeMedia : root.modePerf));
        }
    }

    // The swap delay: any change (in the world or by the user) restarts this;
    // when it fires, the auto view wins. Roughly 5-10s to match the island's
    // calm -- 7s is the middle.
    readonly property int autoSwapDelayMs: 7000
    Timer {
        id: autoSwapTimer
        interval: root.autoSwapDelayMs
        // While a song is playing the media view is not a preference, it is
        // where the island belongs for the length of the song -- so the swap
        // becomes a STANDING instruction (repeat) instead of a single fire.
        //
        // It used to be one-shot and re-armed only when autoMode itself
        // changed, which left a real hole: any view change that did not go
        // through setMode() (the popped-out card writing
        // GlobalStates.nowBarMode, a swipe handled elsewhere) parked the
        // island off the media view for the rest of the track. The soundbar
        // went dead in the same instant, because the cava pipeline is only
        // fed while the media view is on screen -- so the symptom the owner
        // reported ("not focused permanently while the song is running", no
        // soundbar) was one bug wearing two faces.
        //
        // The panel-open guard is the other half. `root.mode` and the popped-
        // out card are ONE piece of state (GlobalStates.nowBarMode), so this
        // timer was reaching into the card: with nothing playing and no
        // pomodoro running, `autoMode` is modePerf, so seven seconds after
        // ANY view change -- including a tab tapped inside the open card --
        // the island wrote `mode = modePerf` and the card followed it back to
        // System. The user opened a tab on purpose and it was taken away
        // seven seconds later, by a rule that exists to rest the ISLAND.
        //
        // An open card is a deliberate act, so while one is up this timer
        // stands down entirely: no fire, no repeat, no re-arm. The island's
        // own behaviour is untouched the moment the card closes (see
        // onNowBarPanelOpenChanged below).
        repeat: root.audioPlaying && !GlobalStates.nowBarPanelOpen
        onTriggered: {
            if (GlobalStates.nowBarPanelOpen) return;
            root.mode = root.autoMode;
        }
    }
    onAutoModeChanged: {
        // Same guard: do not even arm the timer for a card that is open.
        if (GlobalStates.nowBarPanelOpen) {
            autoSwapTimer.stop();
            return;
        }
        // Only park the timer when there is genuinely nothing to swap TO.
        // While audio plays there is always something to return to, so the
        // swap keeps running.
        if (root.mode === root.autoMode && !root.audioPlaying)
            autoSwapTimer.stop();
        else
            autoSwapTimer.restart();
    }
    // Closing the card hands the view back to the island's own rules. Without
    // this the timer would be left stopped by the guard above and the island
    // would never auto-swap again for the rest of the session -- a fix for
    // one surface that quietly breaks another.
    Connections {
        target: GlobalStates
        function onNowBarPanelOpenChanged() {
            if (GlobalStates.nowBarPanelOpen) {
                autoSwapTimer.stop();
                return;
            }
            if (root.mode !== root.autoMode)
                autoSwapTimer.restart();
        }
    }
    Component.onCompleted: {
        root.mode = root.autoMode;
        root.syncMeterClaim();
    }
    // Releasing is a CLAIM release, not a blind `wantIsland = false`: if this
    // island has already been replaced, the flag belongs to the replacement
    // and clearing it here would kill the sound bar out from under it.
    Component.onDestruction: AudioVisualizer.releaseIsland(root)

    // Publish the view so the extended panel (BarContent's nowbar pocket)
    // renders the same one.
    // The swap hint: the ticks brighten for a beat whenever the view changes,
    // however it changed (swipe, hover pocket, panel tab, auto swap).
    property bool swapHint: false
    Timer {
        id: swapHintTimer
        interval: 1600
        onTriggered: root.swapHint = false
    }

    onModeChanged: {
        // The activity tab is the ISLAND's, and only while it exists: the
        // popped-out card has its own five tabs and no sixth chip, so
        // publishing 5 there would leave it with a view none of its tabs
        // match. `nowBarMode` therefore keeps naming the real tab underneath,
        // and the card is never dragged onto a tab it cannot show.
        // The popped-out card has neither of the transient tabs -- it has its
        // own fixed five -- so neither is published; see the note below.
        if (root.mode !== root.modeProgress && root.mode !== root.modeDictation)
            GlobalStates.nowBarMode = root.mode;
        root.swapHint = true;
        swapHintTimer.restart();
        // The shared waveform's door for THIS surface: the island only wants a
        // meter while its media view is the one on screen.
        root.syncMeterClaim();
        // Re-arm the standing swap for EVERY route to another view, not just
        // setMode() (see autoSwapTimer). This is the half that closes the
        // hole: a card-driven or swipe-driven change lands here too, and while
        // a song plays the island now walks itself back to the media view.
        if (root.audioPlaying && root.mode !== root.modeMedia)
            autoSwapTimer.restart();
    }

    // The ticks exist to ANSWER a swipe: "where did it land?". At rest they
    // are hidden entirely -- a pill of dots permanently glued to the island
    // read as ornament. Any mode change (swipe, auto audio swap, a tab jump
    // from the card) shows the row for the hint window, then it fades away.
    // swapHint is already exactly that window, so the row simply rides it.

    function setMode(m) {
        root.mode = m;
        root._syncAiClaim();
        autoSwapTimer.restart(); // The user is driving: the auto view waits its beat.
    }
    function next() { root.setMode((root.mode + 1) % root.modeCount); }
    function prev() { root.setMode((root.mode + root.modeCount - 1) % root.modeCount); }

    // Claim (or release) the shared waveform for this island. Every route that
    // changes the claim goes through here, so the service can never be left
    // holding a claim from an island that is no longer on the media view.
    function syncMeterClaim() {
        if (root.mode === root.modeMedia)
            AudioVisualizer.claimIsland(root);
        else
            AudioVisualizer.releaseIsland(root);
    }

    // The same idea for the local-LLM readings, following syncMeterClaim
    // directly: every route that changes the view goes through setMode, and
    // the claim is recomputed from the mode rather than from a `visible`
    // signal that FadeView never emits for the current view.
    function _syncAiClaim() {
        if (root.mode === root.modeAi)
            LlamaService.claim("island");
        else
            LlamaService.release("island");
    }

    // ── Wheel-event helpers, shared with the panel ────────────────────
    // Both the island and the popped-out card classify wheel events the same
    // way: a touchpad delivers ANY finger count as pixel events (2- and
    // 3-finger swipes alike), only a real wheel needs the angleDelta path.
    // Helpers on the singleton so two surfaces can never disagree about
    // what an event meant.
    function isTouchpad(device, hasPixels) {
        const t = device?.type;
        return (t !== undefined) ? t === PointerDevice.TouchPad : hasPixels;
    }
    // Hyprland runs natural_scroll = true on this machine: a physical
    // rightward drag arrives as NEGATIVE pixelDelta AND the event carries
    // inverted = true. The contract here is "dx > 0 means fingers moved
    // right" (content-follows-fingers, the same convention the 3-finger
    // gestures are registered with), so the already-inverted delta must be
    // negated: the branches used to be swapped, which made the 2-finger
    // swipe step OPPOSITE to the 3-finger one -- fingers right went to the
    // previous view while the gesture went to the next.
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

    // The island's instruments, one per reading. This replaced a cluster of
    // coloured bubbles whose diameter carried the number: size told you how
    // busy something was but never *what* it was, the colour was the only key,
    // and two readings could not be compared by eye. Each instrument now says
    // what it is (an icon), how much (the number) and which way it has been
    // going (a live sparkline of the last minute).
    //
    // The panel above the bar shows this SAME list -- see NowBarPanel's own
    // perfGauges -- so the island and the card can never disagree about what
    // the machine is doing. Captions and labels are the panel's business; the
    // island has no room for prose.
    //
    // The list is DELIBERATELY static: only each instrument's identity lives
    // here. The live numbers used to sit in this array, which made the
    // Repeater's model change on every sampling tick -- and Qt answers a model
    // change by tearing the delegates down and rebuilding them, so all four
    // gauges were destroyed and recreated every second, flashing the whole
    // performance view each time. The live half is read inside the delegates
    // through the perf* functions below: those are property bindings (they
    // re-evaluate when the underlying services change) instead of model
    // entries, so the tiles persist and only their values tick.
    readonly property var perfGauges: [
        { key: "cpu", name: Translation.tr("CPU"), icon: "planner_review", accent: Appearance.colors.colPrimary },
        { key: "ram", name: Translation.tr("RAM"), icon: "memory", accent: Appearance.colors.colTertiary },
        { key: "gpu", name: Translation.tr("GPU"), icon: "developer_board", accent: Appearance.colors.colSecondary },
        { key: "temp", name: Translation.tr("Temp"), icon: "thermostat", accent: Appearance.colors.colError }
    ];

    // The live half of perfGauges. Reading a service property from inside a
    // function called by a binding still registers the dependency, so these
    // re-evaluate on every sample without ever changing the model.
    function perfValue(key) {
        if (key === "cpu") return SystemNow.pct(SystemNow.cpuPct);
        if (key === "ram") return SystemNow.pct(SystemNow.ramPct);
        if (key === "gpu") return SystemNow.pct(SystemNow.gpuMetricPct);
        if (key === "temp") return SystemNow.tempText(SystemNow.tempC);
        return "--";
    }
    function perfLoad(key) {
        if (key === "cpu") return SystemNow.cpuPct;
        if (key === "ram") return SystemNow.ramPct;
        // The BUSIEST chip's load, not a named one: on this laptop the renderer
        // is the iGPU and the 4070 only scans the panel out, so a gauge named
        // after the discrete card read 0% while the machine drew. See
        // SystemNow.gpuMetricPct.
        if (key === "gpu") return SystemNow.gpuMetricPct;
        if (key === "temp") return SystemNow.tempLoad(SystemNow.tempC);
        return -1;
    }
    function perfHistory(key) {
        if (key === "cpu") return ResourceUsage.cpuUsageHistory;
        if (key === "ram") return ResourceUsage.memoryUsageHistory;
        if (key === "gpu") return SystemNow.gpuMetricHistory;
        if (key === "temp") return SystemNow.tempLoadHistory;
        return [];
    }

    // Live waveform. The pipeline itself lives in the AudioVisualizer service
    // now -- the island and the popped-out panel share one `cava` instead of
    // each owning one -- so all this does is say "I want a meter" and read.
    property list<real> visualizerPoints: AudioVisualizer.points

    // The last track the island actually SAW -- the same "Title · Artist"
    // string the media row paints. `mediaView.title` empties the moment MPRIS
    // drops the player, which is exactly when "what was I just listening to?"
    // is the only useful thing the resting island can say, so the name is kept
    // here and the resting row shows it instead of falling straight to
    // "Nothing playing". Written from the row's own onTextChanged (the one
    // place that knows the composed string), never from a binding, and never
    // cleared: it is a memory, not state.
    property string lastTrackText: ""

    // `aiCell` (the top FlareData provider) is gone with the rest of the
    // subscription-quota view; the AI view now reads LlamaService.

    // Three-finger swipe down pops the island out (see NowBarPanel). Layer
    // surfaces never see libinput gestures, so this arrives as the shell's
    // GlobalShortcut, fired by the Hyprland gesture of the same name -- the
    // same path the overview's gestures take.
    GlobalShortcut {
        name: "nowbarPanelToggle"
        description: "Pops the now bar out into its panel"
        onPressed: GlobalStates.nowBarPanelOpen = !GlobalStates.nowBarPanelOpen
    }

    // Horizontal 2/3-finger swipes (registered as Hyprland gestures in
    // custom/general.lua) land on these. One pair serves every surface that
    // shows this view: with the card closed it flips the island (and the
    // pocket follows GlobalStates.nowBarMode); with the card open the island
    // publishes through the same state and the card's own binding flips it.
    // The count is read from GlobalStates, not from this island, so the step
    // is correct no matter which surface drove the view last.
    GlobalShortcut {
        name: "nowbarModeNext"
        description: "Flips the now bar's island to the next view"
        onPressed: root.setMode((GlobalStates.nowBarMode + 1) % root.modeCount)
    }
    GlobalShortcut {
        name: "nowbarModePrev"
        description: "Flips the now bar's island to the previous view"
        onPressed: root.setMode((GlobalStates.nowBarMode + root.modeCount - 1) % root.modeCount)
    }

    // ── Island-hover publisher (the gesture handshake) ───────────────────
    // The compositor owns libinput and thus the multi-finger gestures, but it
    // cannot see hover over a layer surface; only this island knows whether
    // the cursor is on it. The 3-finger-swipe-down that pops the card out is
    // gated on exactly that (see custom/general.lua), so this island
    // publishes its hover state to a runtime file the compositor's Lua reads
    // at gesture time:
    //
    //   $XDG_RUNTIME_DIR/ii-nowbar-hover.json   {"hovering":true,"ts":...}
    //
    // Written on every hover change and refreshed every 2s while hovered
    // (the keepalive); the reader treats the file as stale after 10s, so a
    // crashed shell can never leave a dead "hovering" pinning the gesture.
    // A missing file simply means "not hovering". The 2/3-finger horizontal
    // swipes need no handshake: they arrive here as wheel events and are
    // consumed by the island's own handler below, which is inherently
    // hover-scoped -- the file only carries what the compositor cannot see.
    readonly property string hoverFilePath:
        `${Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"}/ii-nowbar-hover.json`
    property bool islandHovered: false
    property real hoverTs: 0
    Process {
        id: hoverWriter
        // One shot per publish: rewrite the whole (tiny) file. `>` truncate
        // + write is atomic enough for a reader that only wants one line.
        command: ["sh", "-c",
            `printf '{"hovering":${root.islandHovered},"ts":${root.hoverTs}}' > '${root.hoverFilePath}'`]
    }
    function publishHover() {
        root.hoverTs = Date.now() / 1000;
        hoverWriter.running = false;
        hoverWriter.running = true;
    }
    Timer {
        // The keepalive: while the cursor rests on the island, keep the file
        // fresher than the reader's staleness window.
        interval: 2000
        repeat: true
        running: root.islandHovered
        onTriggered: root.publishHover()
    }

    // ── The edge mark ───────────────────────────────────────────────────
    // ONE glyph at the island's edge, and it is SkipArrow's numbers with the
    // arrowhead taken off. Not a second idea: an edge control that used
    // different insets, a different reveal or a different hover ring from the
    // skip arrows beside it would read as belonging to a different island, and
    // the edge is exactly where the eye learns the rule. So `edgeGap` (17),
    // `hitPad` (8), the em (20), the 25px ring, the 70/40 fade and the
    // 60/40 ring are all copied from SkipArrow deliberately -- change one and
    // it should be changed in both.
    //
    // What differs is only what a stopwatch mark has to say that a chevron
    // cannot: `active`, which lights the mark while the clock it selects is
    // the one on screen. Without it the tab is a tab with two readings and
    // nothing on screen to say which one you are looking at.
    component EdgeIcon: Item {
        id: edgeIcon
        property string glyph: "timer"
        // false = the island's left edge, true = its right. The visible glyph
        // is `edgeGap` from the border either way; `hitPad` is taken on the
        // inward side, where it overlaps nothing.
        property bool trailing: false
        property bool revealed: false
        // Driven by inputArea, exactly like IslandButton and SkipArrow: this
        // island owns the pointer and hit-tests by geometry, so a handler in
        // here would never fire.
        property bool hoverState: false
        property bool pressState: false
        property bool armed: true
        property bool held: false
        // Lit while whatever this mark selects is what the island is showing.
        property bool active: false
        signal triggered()
        readonly property bool hot: hoverState || pressState || held

        readonly property real em: 20
        // Passed in from the transport button's real width, like SkipArrow's
        // ring, so the ring is literally the same rectangle the play button
        // draws on hover.
        property real ringSize: 25
        // 17 is the skip arrows' inset and the default here, so an edge mark
        // that nobody has an opinion about lands where the edge already
        // means something. Not `readonly`: a mark the owner has an opinion
        // about overrides it at the call site, next to a comment saying why
        // (see pomoStopwatch).
        property real edgeGap: 17
        readonly property real hitPad: 8

        implicitWidth: em + edgeGap + hitPad
        implicitHeight: 20
        opacity: revealed || hot ? 1 : 0
        Behavior on opacity {
            NumberAnimation {
                duration: (edgeIcon.revealed || edgeIcon.hot) ? 70 : 40
                easing.type: Easing.OutCubic
            }
        }

        // The transport button's hover ring, matched property for property
        // with IslandButtonVisual and SkipArrow's: 1px border, the same radius
        // token, 0.55 on hover and on a pinned hold, 0.8 while pressed. The
        // one addition is the resting `active` step at 0.35 -- visible, but
        // quieter than a hover, because it is a state rather than a response.
        Rectangle {
            id: edgeRing
            width: edgeIcon.ringSize
            height: edgeIcon.ringSize
            radius: Appearance.rounding.small
            color: "transparent"
            border.width: 1
            border.color: (edgeIcon.hot || edgeIcon.active)
                ? Appearance.colors.colPrimary
                : Appearance.colors.colOnLayer0
            opacity: (edgeIcon.hoverState || edgeIcon.held)
                ? 0.55
                : (edgeIcon.pressState ? 0.8 : (edgeIcon.active ? 0.35 : 0))
            Behavior on opacity {
                NumberAnimation {
                    duration: (edgeIcon.hoverState || edgeIcon.held) ? 60 : 40
                }
            }
            x: art.x + (art.width - width) / 2
            anchors.verticalCenter: parent.verticalCenter
        }

        Item {
            id: art
            height: parent.height
            width: edgeIcon.em
            // Pinned to the OUTER edge; the slack is taken inward, so the
            // press target is bigger than the mark without the mark moving.
            x: edgeIcon.trailing ? edgeIcon.hitPad : edgeIcon.edgeGap

            MaterialSymbol {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: edgeIcon.glyph
                iconSize: edgeIcon.em
                // FILL pinned at 0, like SkipArrow's mark: the ring is the
                // hover tell, and a second animated layer over one 20px mark
                // is what read as a weird transition rather than a hover.
                fill: 0
                color: (edgeIcon.hot || edgeIcon.active)
                    ? Appearance.colors.colPrimary
                    : Appearance.colors.colOnLayer0
            }
        }
    }

    // THE island's one and only pointer layer. z: 100 lifts it above the
    // whole view stack: the views are plain Items, so a press had to fall
    // THROUGH them to arrive here, and on the media view it never made it
    // -- pressing or tapping the bar did nothing at all. Now nothing sits
    // above this area, so wheel/swipe, hover and every press land here
    // first, and the in-island buttons are hit-tested by geometry (see
    // buttonAt) and driven from here, so a button press can no longer be
    // swallowed by the text sitting above it either.
    MouseArea {
        id: inputArea
        anchors.fill: parent
        z: 100
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor

        // The button a press landed on; null means the island's body.
        property Item pressTarget: null
        // The control the pointer is over RIGHT NOW, cached. Everything
        // below runs on every motion event -- a fast pointer on this pad
        // delivers well over a hundred a second -- and the answer is almost
        // always "the same control as last time", so remembering it turns
        // the common case into one containment test instead of a fresh walk
        // of the list, and lets refreshHover write nothing at all when
        // nothing changed.
        property Item hoverTarget: null
        // 2px of slack around a control that is ALREADY lit. A pointer
        // sweeping across the island at speed clips corners, and without
        // this the state flipped twice inside one event: the FILL axis was
        // asked for 1, then 0, then 1 again in the time it takes to cross a
        // few pixels, and the glyph visibly strobed. Entering needs no
        // forgiveness; LEAVING gets some. Hover that survives a fast sweep
        // is worth more than hover that is exactly right.
        readonly property real hoverSlop: 2
        function islandButtons() {
            // The skip arrows are in here for the same reason the play
            // buttons are: the island owns the pointer, so an arrow that
            // is not in this list is neither hoverable nor clickable.
            // Reverse order matters -- buttonAt walks the list backwards, so
            // the last entry wins where two ever overlap.
            return [mediaPlayButton, pomoPlayButton, pomoResetButton, pomoStopwatch,
                skipPrev, skipNext, islandPowerBtn];
        }
        // Is (x, y), in inputArea's own coordinates, inside this control --
        // grown by `slop` on every side?
        function inside(b, x, y, slop) {
            // armed: a hidden view's button must not eat hover or taps meant
            // for the view that is actually on screen.
            if (!b || !b.armed || b.width <= 0)
                return false;
            const p = b.mapFromItem(inputArea, x, y);
            return p.x >= -slop && p.y >= -slop
                && p.x <= b.width + slop && p.y <= b.height + slop;
        }
        function buttonAt(x, y, slop) {
            const all = inputArea.islandButtons();
            for (let i = all.length - 1; i >= 0; --i) {
                if (inputArea.inside(all[i], x, y, slop ?? 0))
                    return all[i];
            }
            return null;
        }
        function refreshHover() {
            const prev = inputArea.hoverTarget;
            let hit = inputArea.buttonAt(mouseX, mouseY);
            // The control that is already lit keeps the pointer unless the
            // pointer has genuinely left every other control. One test, and
            // it only runs when the exact hit test disagrees.
            if (hit !== prev
                && inputArea.inside(prev, mouseX, mouseY, inputArea.hoverSlop))
                hit = prev;
            // The overwhelming majority of motion events land here: the same
            // control, so no property is written and no binding downstream
            // (the ring's opacity, the glyph's FILL axis) is re-evaluated.
            if (hit === prev)
                return;
            inputArea.hoverTarget = hit;
            const all = inputArea.islandButtons();
            for (let i = 0; i < all.length; ++i) {
                if (all[i])
                    all[i].hoverState = (all[i] === hit);
            }
        }
        function clearHover() {
            inputArea.hoverTarget = null;
            const all = inputArea.islandButtons();
            for (let i = 0; i < all.length; ++i) {
                if (all[i])
                    all[i].hoverState = false;
            }
        }
        onEntered: inputArea.refreshHover()
        onPositionChanged: inputArea.refreshHover()
        onExited: inputArea.clearHover()
        onPressed: event => {
            inputArea.pressTarget = inputArea.buttonAt(event.x, event.y);
            if (inputArea.pressTarget)
                inputArea.pressTarget.pressState = true;
        }
        onReleased: event => {
            const b = inputArea.pressTarget;
            inputArea.pressTarget = null;
            if (b) {
                // Let go somewhere else: cancel, don't fire.
                b.pressState = false;
                if (inputArea.buttonAt(event.x, event.y) === b)
                    b.triggered();
                return;
            }
            // A RIGHT click does nothing. On this touchpad a two-finger tap
            // IS a right click (custom/general.lua: `tap_button_map =
            // "1,2,3"`, two fingers -> right button), so this used to throw
            // the desktops overview over the whole screen every time a tap
            // landed on the island -- an ordinary tap while reaching for the
            // clock or flicking the pointer across the bar.
            //
            // The press is still ACCEPTED and simply dropped, rather than
            // removed from `acceptedButtons`: letting it through would hand it
            // to the bar's own stretch MouseAreas underneath, which is another
            // overview. Nothing is lost here -- SUPER+Tab, SUPER+Z and SUPER+D
            // all open the overviews, and a left click on the island body
            // still runs `backgroundTap()` below.
            if (event.button === Qt.RightButton)
                return;
            root.backgroundTap();
        }

        onContainsMouseChanged: {
            root.islandHovered = containsMouse;
            root.publishHover();
        }

        // ── 2-finger horizontal swipe = mode change ─────────────────────
        //
        // This handler used to be its own thing: an axis lock needing 12px to
        // arm, then a 40px distance floor before it would step. It now speaks
        // the SAME grammar as the left sidebar's swipe (SidebarLeftContent's
        // onSwipeWheel), which is the one the user has been calling snappy all
        // along. Two changes, both about reaction rather than about safety:
        //
        //   * NO DISTANCE FLOOR. It used to hold the step until 40px of
        //     accumulated travel. On this pad a deliberate flick delivers
        //     roughly 10px per event, so that is a four-event wait BEFORE
        //     anything visibly happens -- the view sits still while your
        //     fingers are already moving, which is what "not snappy" is. The
        //     sidebar commits on the first event that leans horizontal and
        //     has no floor at all; that is why it feels immediate and this
        //     did not.
        //
        //   * THE RATIO DOES THE PROTECTING, NOT THE FLOOR. The sidebar's
        //     insight: a touchpad's first frame is already overwhelmingly one
        //     axis (measured ~10px on one, 0-1 on the other), so axis
        //     discrimination does not need a distance budget. Guessing wrong
        //     costs one spurious view change; waiting costs a gesture that
        //     never answers, and the second is far more noticeable.
        //
        // The 12px arming gate is gone with the floor: it existed only to
        // reach the 40px floor safely, and it was the first thing making a
        // light flick do nothing at all.
        property real accX: 0
        property real accY: 0
        property bool horizontal: false
        property bool vertical: false
        property bool firedThisGesture: false

        // A sibling of the things it drives, never a child: MouseArea has no
        // default property, so a nested Timer is a hard load failure. The
        // sidebar hit exactly this and documents it.
        Timer {
            id: swipeEndTimer
            // 200ms, matching the sidebar rather than the old 180ms. Longer
            // than the gap between frames of one continuous gesture (6-10ms
            // on this pad) and shorter than a deliberate pause. The difference
            // matters when swiping repeatedly and fast: too short and one
            // physical swipe gets split into two and steps twice; too long and
            // the next swipe arrives while `firedThisGesture` is still set, so
            // it is silently swallowed and the island feels like it dropped
            // the input. 200ms is the value that survives back-to-back swipes.
            interval: 200
            onTriggered: {
                inputArea.accX = 0;
                inputArea.accY = 0;
                inputArea.horizontal = false;
                inputArea.vertical = false;
                inputArea.firedThisGesture = false;
            }
        }
        onWheel: w => {
            const pd = w.pixelDelta;
            const hasPixels = pd && (pd.x !== 0 || pd.y !== 0);
            const deviceType = w.device?.type;
            const isTouchpad = (deviceType !== undefined)
                ? deviceType === PointerDevice.TouchPad
                : hasPixels;

            if (!isTouchpad) {
                // A real wheel: one notch, one step, no accumulation.
                const dx = w.angleDelta.x !== 0 ? w.angleDelta.x : w.angleDelta.y;
                if (dx === 0) return;
                if (dx > 0) root.next(); else root.prev();
                w.accepted = true;
                return;
            }

            // Hyprland runs natural_scroll = true here, so a physical
            // rightward drag arrives as NEGATIVE pixelDelta; the dock
            // un-inverts the same way and the two surfaces must agree or one
            // will feel backwards. (Same helper as the panel, so the island
            // and the card can never drift apart.) 2- and 3-finger swipes both
            // arrive this way -- nothing here cares which produced it.
            const dx = root.wheelDx(w, hasPixels);
            const dy = root.wheelDy(w, hasPixels);

            // A frame with NO movement at all is the pad reporting lift-off,
            // not a gesture. It must not touch the accumulators and must not
            // restart the gesture timer. Restarting on these is what made a
            // fast sequence of swipes unreliable: the zero frames that trail
            // one flick kept the PREVIOUS gesture's lock alive, so the next
            // real swipe inherited `firedThisGesture` and was swallowed. The
            // sidebar fixed the same bug the same way.
            if (!hasPixels && dx === 0 && dy === 0) {
                w.accepted = true;
                return;
            }

            accX += Math.abs(dx);
            accY += Math.abs(dy);
            swipeEndTimer.restart();

            // ONE AXIS PER GESTURE, decided once and then held. Re-deciding
            // per event is what makes a handler feel broken: one tick where
            // the axis flips sends the rest of the gesture down the other
            // branch and the step never lands.
            if (!horizontal && !vertical) {
                const ax = accX, ay = accY;
                if (ay > 0 && ay >= ax * 2.0)
                    vertical = true;
                else if (ax > 0 && ax >= ay * 2.0)
                    horizontal = true;
                else if (ax > ay * 1.05)
                    horizontal = true;
                else if (ay > 0)
                    vertical = true;
            }

            // A vertical lean is the pad scrolling something, not a view
            // change: the island has no scrollable content, so there is
            // nothing to do and the event is simply consumed.
            if (vertical) {
                w.accepted = true;
                return;
            }

            w.accepted = true;
            if (!horizontal || firedThisGesture)
                return;

            // Fingers right = NEXT view, the convention shared with the left
            // sidebar and with the popped-out card. It was inverted once, and
            // the inversion meant the island and the card moved opposite ways
            // from the same physical gesture.
            if (dx > 0) root.next(); else root.prev();
            firedThisGesture = true;
        }

        // ── The hover pocket: retired ──────────────────────────────────────
        // Hovering used to extend the island into a detail pocket under the
        // bar (GlobalStates.nowBarExpanded → BarContent's "nowbar" pocket).
        // It read as the island grabbing for attention on every accidental
        // pass, and the popped-out card then floated over a generic pale pill
        // instead of a lit island. The island now reacts ONLY when it is
        // really open -- the three-finger swipe down (nowbarPanelToggle):
        // BarContent grows and relights the capsule itself, and
        // GlobalStates.nowBarExpanded stays false unless something explicitly
        // arms the pocket again. The pointer's job here is clicks, taps and
        // the wheel, nothing more.

        // NOTE: there is no onClicked here on purpose. Presses are handled
        // in onPressed/onReleased above so a press that starts on a button
        // can be cancelled and never reach the background action.
    }

    // ── The three views, cross-fading in place ───────────────────────────
    Item {
        id: stage
        anchors.centerIn: parent
        // Dead centre at rest; rides up a hair only while the tick row is
        // revealed (see tabTicks), so hidden ticks reserve no space.
        //
        // What the views ASK for, which is what sizes the island. Split out
        // from the width below so the two can differ without a binding loop.
        readonly property real contentWidth: Math.max(pomodoroView.implicitWidth, mediaView.implicitWidth, aiView.implicitWidth, perfView.implicitWidth, progressView.implicitWidth, dictationView.implicitWidth)
        // The FULL width of the island, not the widest view's width. This is
        // the fix for "the arrows are nowhere near the edge": the stage used
        // to be exactly as wide as the widest view and every view was CENTRED
        // in it, so on the media tab -- whose content (~190px) is narrower
        // than the island's 360px floor -- the row, and therefore both
        // arrows, sat (360 - 190) / 2 = 85px inside the painted border. The
        // arrows were flush with the row and the row was nowhere near the
        // edge. Stretching the stage is what makes "at the edge of the row"
        // and "at the edge of the island" the same place.
        width: root.width
        Behavior on anchors.verticalCenterOffset {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
        }
        // Taller than the island ON PURPOSE: this is the clip box for the
        // sideways swap, and clipping at the island's own height would shave
        // the performance bubbles, which run edge to edge by design.
        height: root.height + 12
        clip: true

        // ── The sideways swoosh ───────────────────────────────────────────
        // The four views are one horizontal strip, not four stacked layers:
        // each sits at its distance from the live view, so a swap sweeps them
        // ALL the same way -- the outgoing ducks out one side while the
        // incoming swooshes in from the other -- and they land on a curve with
        // a little overshoot, which is the bounce.
        //
        // The distance is measured around the RING, not along the row, so
        // every swap is one step sideways: 3 -> 0 moves the pair across the
        // seam by a single width instead of rewinding through all four.
        function ringSteps(to) {
            const n = root.modeCount;
            let d = (to - root.mode) % n;
            if (d > n / 2) d -= n;
            if (d < -n / 2) d += n;
            return d;
        }
        readonly property real swooshGap: 26

        component FadeView: Item {
            id: fadeView
            property bool on: false
            // Which tab of the ring this view is (0..modeCount-1).
            property int viewIndex: 0
            readonly property int steps: stage.ringSteps(fadeView.viewIndex)
            visible: opacity > 0.01
            opacity: on ? 1 : 0
            scale: on ? 1 : 0.94
            x: (stage.width - fadeView.width) / 2
                + fadeView.steps * (stage.width + stage.swooshGap)
            // Bouncy in, quick and flat out: the incoming view overshoots its
            // mark by a hair (the swoosh), the outgoing one just leaves. Both
            // sides land on a spring and both park EXACTLY on their slot --
            // "anchored": a view never rests between two positions, and a
            // mid-flight reversal (swipe, swipe back) hands over smoothly
            // because the overshoot flows into the return without a stop.
            Behavior on x {
                NumberAnimation {
                    duration: fadeView.on ? 340 : 200
                    easing.type: fadeView.on ? Easing.OutBack : Easing.OutCubic
                    easing.overshoot: 1.14
                }
            }
            // Asymmetric crossfade, riding under the slide: the incoming view
            // blooms on the enter spring, the outgoing one ducks on the exit
            // curve -- they meet in the middle instead of moving as one blob.
            // One animation whose *properties* are chosen as the fade starts,
            // never a swapped animation object: Qt refuses to change a
            // Behavior's animation at runtime (it warns "Cannot change the
            // animation assigned to a Behavior" and silently keeps the first),
            // so an `on ? enter : exit` object would give both directions the
            // same curve. A binding on the properties is re-read each time the
            // fade begins, which is exactly the moment the direction is known.
            Behavior on opacity {
                NumberAnimation {
                    alwaysRunToEnd: false
                    duration: fadeView.on
                        ? Appearance.animation.elementMoveEnter.duration
                        : Appearance.animation.elementMoveExit.duration
                    easing.type: fadeView.on
                        ? Appearance.animation.elementMoveEnter.type
                        : Appearance.animation.elementMoveExit.type
                    easing.bezierCurve: fadeView.on
                        ? Appearance.animation.elementMoveEnter.bezierCurve
                        : Appearance.animation.elementMoveExit.bezierCurve
                }
            }
            Behavior on scale { animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this) }
        }

        // ── 5 · Activity (only while there is something to watch) ──────
        // An app being updated, or a file coming down. The tab exists only
        // while that is true, and the island walks to it by itself; when the
        // work ends the tab goes and the island returns to whatever it would
        // otherwise show. Because it is a VIEW, the other tabs' labels can
        // never show through it -- an overlay drawn on top of the live view
        // collided with exactly those labels.
        FadeView {
            id: progressView
            anchors.verticalCenter: parent.verticalCenter
            viewIndex: root.modeProgress
            implicitWidth: progressColumn.implicitWidth
            width: stage.width
            implicitHeight: root.height
            on: root.mode === root.modeProgress

            // Not `active`: a transaction that is only libraries must not put
            // a line on the bar at all. See PackageUpdate.showsInBar.
            readonly property bool updating: PackageUpdate.showsInBar
            // 0..1, or -1 when the run has no measurable total (a single
            // package with no upgrade list behind it). The bar sweeps an
            // indeterminate segment then, rather than inventing a percentage.
            readonly property real fraction: progressView.updating
                ? PackageUpdate.fraction
                : GlobalStates.downloadProgress
            readonly property string label: {
                if (progressView.updating) {
                    const name = PackageUpdate.displayName;
                    if (PackageUpdate.phase === "prepare" || !PackageUpdate.measured)
                        return Translation.tr("Updating %1").arg(name);
                    return Translation.tr("Updating %1 · %2%")
                        .arg(name).arg(PackageUpdate.percent);
                }
                // Nothing live: the tab is on its way out (the fade lasts a
                // beat longer than the state change), and a "Downloading ·
                // -100%" would be nonsense. Empty, not a placeholder.
                if (GlobalStates.downloadProgress < 0)
                    return "";
                return Translation.tr("Downloading %1 · %2%")
                    .arg(GlobalStates.downloadName)
                    .arg(Math.round(GlobalStates.downloadProgress * 100));
            }
            // Position of the indeterminate segment along the track, 0..1.
            // Ignored whenever there is a real fraction to draw.
            property real sweep: 0
            SequentialAnimation {
                running: progressView.on && progressView.fraction < 0
                loops: Animation.Infinite
                NumberAnimation {
                    target: progressView
                    property: "sweep"
                    from: 0
                    to: 1
                    duration: 950
                    easing.type: Easing.InOutQuad
                }
                NumberAnimation {
                    target: progressView
                    property: "sweep"
                    from: 1
                    to: 0
                    duration: 950
                    easing.type: Easing.InOutQuad
                }
            }

            Column {
                id: progressColumn
                anchors.centerIn: parent
                spacing: 3

                Row {
                    id: progressRow
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 8

                    // The app's own logo, through the icon theme: the same
                    // picture its launcher shows. A library has none, so a
                    // glyph stands in rather than leaving a hole.
                    Image {
                        id: progressLogo
                        anchors.verticalCenter: parent.verticalCenter
                        visible: progressView.updating && PackageUpdate.iconName !== ""
                        source: visible
                            ? Quickshell.iconPath(PackageUpdate.iconName, "")
                            : ""
                        width: 16
                        height: 16
                        sourceSize.width: 32
                        sourceSize.height: 32
                        fillMode: Image.PreserveAspectFit
                        readonly property bool resolved: status === Image.Ready
                    }
                    MaterialSymbol {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !progressLogo.visible || !progressLogo.resolved
                        text: progressView.updating
                            ? (PackageUpdate.phase === "prepare" ? "download" : "package_2")
                            : "download"
                        iconSize: 16
                        color: Appearance.colors.colPrimary
                    }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        font.pixelSize: Appearance.font.pixelSize.smallie
                        color: Appearance.colors.colOnLayer0
                        text: progressView.label
                    }
                }

                // The progression itself, inside the tab it belongs to: a thin
                // track under the sentence that fills with the real fraction.
                Rectangle {
                    id: progressTrack
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.max(150, Math.min(260, progressRow.implicitWidth))
                    height: 3
                    radius: 1.5
                    color: ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.76)

                    Rectangle {
                        id: progressFill
                        height: parent.height
                        radius: parent.radius
                        color: Appearance.colors.colPrimary
                        width: progressView.fraction >= 0
                            ? progressTrack.width * Math.min(1, Math.max(0, progressView.fraction))
                            : progressTrack.width * 0.3
                        x: progressView.fraction >= 0
                            ? 0
                            : (progressTrack.width - width) * progressView.sweep
                        Behavior on width {
                            NumberAnimation { duration: 240; easing.type: Easing.OutQuad }
                        }
                    }
                }
            }
        }


        // ── 6 · Dictation (only while the microphone is open) ──────────
        // A real view in the ring, like the activity tab, so it IS the island
        // rather than a badge stuck beside it. The meter is fed by the level of
        // the very PCM the daemon is recording -- a moving bar is proof the
        // microphone is hearing something, not an animation that runs because
        // the state says "recording".
        FadeView {
            id: dictationView
            anchors.verticalCenter: parent.verticalCenter
            viewIndex: root.modeDictation
            implicitWidth: Math.max(210, dictationRow.implicitWidth + 26)
            width: stage.width
            implicitHeight: root.height
            on: root.mode === root.modeDictation

            // Travelling wave, so a quiet room still looks like listening: at
            // the levels a still room produces every bar would otherwise be the
            // same three pixels.
            property real wave: 0
            NumberAnimation on wave {
                from: 0; to: 1; duration: 1100; loops: Animation.Infinite
            }
            // Dictation.level is the daemon's meter, normalised against THIS
            // recording's own noise floor and peak (see Recorder in
            // dictate-daemon.py), so 0 is a still room and 1 is as loud as the
            // input gets -- whatever that input's gain is.
            //
            // Level owns the height: a bar with a quiet room is 5px and a bar
            // with speech is 17px, and that difference is the whole point of
            // showing a meter at all. The travelling wave only ripples the
            // tops, so the pill still looks alive between words without
            // drowning out the thing it is measuring.

            Row {
                id: dictationRow
                anchors.centerIn: parent
                spacing: 10

                MaterialSymbol {
                    anchors.verticalCenter: parent.verticalCenter
                    text: Dictation.busy ? "graphic_eq" : "mic"
                    iconSize: 17
                    // Filled and tinted only while it is actually live; at rest
                    // the tab looks like a hint, not like a running meter.
                    fill: Dictation.showing ? 1 : 0
                    color: Dictation.showing
                        ? Appearance.colors.colPrimary
                        : Appearance.colors.colOnLayer1Inactive
                }

                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2.5
                    visible: Dictation.showing
                    Repeater {
                        model: 7
                        Rectangle {
                            width: 3
                            radius: 1.5
                            anchors.verticalCenter: parent.verticalCenter
                            // The formula lives HERE, in the binding, and not
                            // in a helper function called from it. A function
                            // call in this binding did not re-run when
                            // Dictation.level changed -- measured: the bars sat
                            // at the height they were first drawn at (9px) while
                            // the same level drawn directly moved them 9px ->
                            // 26px. Inline, the property reads are dependencies
                            // in the usual way, so every bar follows the voice.
                            height: {
                                const wobble = 0.5 + 0.5 * Math.sin((dictationView.wave + index * 0.14) * Math.PI * 2);
                                const base = 0.12 + 0.88 * Dictation.level;
                                return 4 + 14 * Math.min(1, base * (0.82 + 0.18 * wobble));
                            }
                            color: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.15)
                            // No Behavior here. A 70ms height animation on top of
                            // a level that the daemon already smooths (and that
                            // arrives every 50ms) left the bars stuck at the
                            // height they were created with: the binding
                            // computed 17px while the pill drew 6px. The
                            // smoothing that matters is upstream, in dBFS.
                        }
                    }
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    font.pixelSize: Appearance.font.pixelSize.smallie
                    color: Dictation.showing
                        ? Appearance.colors.colOnLayer0
                        : Appearance.colors.colOnLayer1Inactive
                    // The idle line is where the gesture is learned: this tab is
                    // permanent, and an empty tab would never tell anyone that
                    // holding SUPER is what it is for.
                    text: Dictation.busy
                        ? Translation.tr("Transcribing…")
                        : Dictation.listening
                            ? Translation.tr("Listening… hold on, release to type")
                            : Translation.tr("Hold SUPER to dictate")
                }

                // Which language it is actually hearing. Appears as soon as
                // whisper has decided -- during a long hold that is a few
                // seconds in, when the first chunk comes back, and it stays up
                // through the transcribing tail. Nothing is shown before then
                // on purpose: "auto" is a setting, not an answer, and a guess
                // drawn from the PREVIOUS dictation would be worse than blank.
                Rectangle {
                    id: dictationLangChip
                    anchors.verticalCenter: parent.verticalCenter
                    visible: Dictation.showing && Dictation.languageLabel !== ""
                    implicitWidth: dictationLangText.implicitWidth + 10
                    implicitHeight: 16
                    radius: 5
                    color: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.84)

                    StyledText {
                        id: dictationLangText
                        anchors.centerIn: parent
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        font.weight: 600
                        color: Appearance.colors.colPrimary
                        text: Dictation.languageLabel
                    }
                }
            }
        }

        // ── 0 · Pomodoro ──────────────────────────────────────────────────
        FadeView {
            id: pomodoroView
            anchors.verticalCenter: parent.verticalCenter
            viewIndex: root.modePomodoro
            implicitWidth: pomoRow.width
            // The FULL width of the island, like mediaView's. Without it this
            // view is exactly as wide as its own row (implicitWidth above),
            // which is fine for a row that sits in the middle and is the
            // whole problem for the stopwatch mark at the right edge: there
            // is no edge to be at. `implicitWidth` still sizes the island, so
            // the two answers stay separate -- what the island must be wide
            // enough for, and how much room this view draws in.
            width: stage.width
            implicitHeight: root.height
            on: root.mode === root.modePomodoro

            // Hours too, once there are any. This was M:SS unconditionally,
            // so a 90 minute focus read "90:00" here while the same timer read
            // "1:30:00" in the popped-out card a few pixels away -- two
            // surfaces, two answers, and no way to tell from the island which
            // one you were looking at. DateTime.duration is now the single
            // formatter for both.
            readonly property string timeText: root.stopwatchMode
                ? pomodoroView.stopwatchText
                : DateTime.duration(TimerService.pomodoroSecondsLeft)

            // The stopwatch's reading, in the ONE form the island shows: MM:SS.
            //
            // Not the hundredths. The sidebar's stopwatch prints them as a
            // subscript (`12:34:56`) because it has 40px of type to spend on a
            // readout you are watching tick; this is a 16px monospace number in
            // a 34px island that you glance at while doing something else, and
            // at that size the hundredths are not readable, they are just
            // motion -- and worse, they make the box WIDTH breathe, which on
            // this row is fatal, because the box is what centres the text.
            //
            // The same MM:SS the sidebar prints, so the two surfaces cannot
            // disagree about the number -- the exact failure this file's
            // hour-rollover comment above is about, kept from happening twice.
            // Minutes are not wrapped at 60: a stopwatch that has run for an
            // hour says 60:00, as it does in the sidebar.
            readonly property string stopwatchText: {
                const secs = Math.floor(TimerService.stopwatchTime / 100);
                const mm = Math.floor(secs / 60).toString().padStart(2, "0");
                const ss = (secs % 60).toString().padStart(2, "0");
                return mm + ":" + ss;
            }

            // Laid out by hand, not by a RowLayout, and the buttons are
            // placed FROM the time rather than at the ends of a row. Both of
            // those are corrections:
            //
            //   * A RowLayout centres the GROUP, so every control added on
            //     one side pushes the time left by half its width -- 31px
            //     before this row existed, 47.5px with a reset button on the
            //     right (both measured off a rendered preview).
            //
            //   * Pinning the two groups to the row's ENDS was the wrong half
            //     of that fix. The row was as wide as the groups needed (77px)
            //     and the time is 48px, so centring the time inside it put
            //     the countdown ON TOP of both buttons: the buttons looked
            //     marooned in the middle of the island with the number
            //     running under them. Measured, not guessed -- the old probe
            //     read the time spanning 14.5..62.5 of a row whose left group
            //     ended at 40 and whose right group began at 52.
            //
            // So: the time is centred, and each button is anchored to the
            // time's own edge at `gap`. "Next to the timer" and "the time is
            // in the middle" are then the same statement, and neither can be
            // broken later by adding a control.
            Item {
                id: pomoRow
                anchors.centerIn: parent
                // Time to each button, identical on both sides.
                readonly property real gap: 10
                // What each HALF of the row has to hold, measured out from
                // the time rather than assumed equal. The left half is the
                // reset button and the gap. The right half is the label, the
                // gap after it, and the play button -- so it is the longer
                // of the two by the label's width, and that difference is
                // where the row's slack sits. Stated as arithmetic rather
                // than as one fudged total, because an earlier version
                // hardcoded the difference (15px, for a recording dot that
                // has since gone) and the probe caught the dot 1.5px INSIDE
                // the reset button.
                readonly property real rightHalf: gap + 25 + 7 + pomoLabel.width
                readonly property real leftHalf: gap + 25
                width: pomoTime.width + 2 * Math.max(leftHalf, rightHalf)
                height: 25

                // The countdown, dead centre. The word "timer" sits after it
                // as a caption -- it was removed for a while on the grounds
                // that the tab chip above already says Clock, and that was
                // true and also not worth 34px of the row's width. It is back
                // because the row reads as a bare number without it once the
                // recording dot went; the cost is paid on the right, where the
                // label and the play button both live, instead of on the
                // time's position.
                Text {
                    id: pomoTime
                    // An explicit x, NOT `anchors.horizontalCenter`, and the
                    // reason is worth keeping: the anchor was resolved while
                    // the row was still 1px wider (the countdown's width is
                    // only final once the monospace font has loaded), and Qt
                    // did not re-run it when the row settled -- so the time
                    // sat half a pixel right of the middle, permanently. A
                    // binding on x depends on both widths explicitly, so it
                    // cannot be resolved against a width that later changes.
                    // Half a pixel is invisible; "the one number in the row
                    // that must be exactly centred" being half a pixel off is
                    // the kind of thing that gets rediscovered in six months.
                    x: (pomoRow.width - width) / 2
                    anchors.verticalCenter: parent.verticalCenter
                    text: pomodoroView.timeText
                    color: Appearance.colors.colOnLayer0
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.normal
                    font.weight: 600
                }

                // The word "timer", back where it started: immediately after
                // the countdown, in the same dim ink as before. It is a
                // caption for the number, so it belongs beside the number --
                // and because the row is laid out from the time outwards, the
                // play button simply moves past the label rather than the
                // label pushing the time off the middle. That was the whole
                // reason the row is hand-placed: the caption can come and go
                // without the countdown ever moving.
                Text {
                    id: pomoLabel
                    anchors.left: pomoTime.right
                    anchors.leftMargin: 7
                    anchors.verticalCenter: parent.verticalCenter
                    // "timer" for the pomodoro, "watch" for the stopwatch: one word, five
                // letters in both cases, so the row's width barely moves when
                // the clock changes and the play button lands in the same
                // place either way. "stopwatch" itself is the honest word and
                // it is 64px of row for a caption, which is more than the
                // countdown it is captioning; "sw" would cost 15px and mean
                // nothing at a glance.
                text: root.stopwatchMode ? "watch" : "timer"
                    color: Appearance.colors.colOnLayer1Inactive
                    font.pixelSize: Appearance.font.pixelSize.small
                }

                // Reset, `gap` px from the time's left edge.
                //
                // An ordinary IslandButton, which is the whole point: it gets
                // the transport button's hover for free -- the same 25px pad,
                // the same em, the same accent ring, the same fill-on-hover --
                // because it IS the same component. It was briefly wired to a
                // `canReset` test that dimmed it and suppressed its ring until
                // the lap had run, which cost more than it bought: on a fresh
                // timer reset is a perfectly legible no-op, and a button that
                // does not look like the play button beside it is the thing
                // the eye notices first.
                IslandButton {
                    id: pomoResetButton
                    anchors.right: pomoTime.left
                    anchors.rightMargin: pomoRow.gap
                    anchors.verticalCenter: parent.verticalCenter
                    icon: "restart_alt"
                    armed: root.mode === root.modePomodoro
                    // Whichever clock is on screen, this resets THAT clock.
                    // Sending it to the pomodoro while the stopwatch is being
                    // read out is the kind of thing that only shows up once,
                    // as a pomodoro that silently went back to 25:00.
                    onTriggered: root.stopwatchMode
                        ? TimerService.stopwatchReset()
                        : TimerService.resetPomodoro()
                }

                // Play/pause, `gap` px past the label: the control people
                // reach for, and the same distance from what is next to it as
                // the reset has from the number on the other side.
                IslandButton {
                    id: pomoPlayButton
                    anchors.left: pomoLabel.right
                    anchors.leftMargin: pomoRow.gap
                    anchors.verticalCenter: parent.verticalCenter
                    armed: root.mode === root.modePomodoro
                    // Same glyph, same place, same hover -- pointed at whichever
                    // clock the tab is reading. `running` is read per mode so
                    // switching tabs mid-run cannot leave a play arrow on a
                    // running stopwatch.
                    icon: (root.stopwatchMode
                        ? TimerService.stopwatchRunning
                        : TimerService.pomodoroRunning) ? "pause" : "play_arrow"
                    onTriggered: root.stopwatchMode
                        ? TimerService.toggleStopwatch()
                        : TimerService.togglePomodoro()
                }
            }

            // The stopwatch mark, at the island's right edge -- where the
            // music tab puts its next-track arrow, so the edge means
            // "something lives out here" and not "the timer grew a button".
            // It reveals on hover like those arrows do, which is also what
            // keeps the resting timer tab EXACTLY as it was asked to look: at
            // rest there is no mark, no ring, and the countdown is the same
            // row it has always been.
            //
            // A SIBLING OF THE ROW, not a child of it. Anchored to pomoRow's
            // right it landed 93px inside the island's painted border, because
            // pomoRow is a content-fitted box centred in the view -- its right
            // edge is the end of the cluster, not the edge of anything. The
            // probe caught it at 93.2 where it should have been 17; "at the
            // edge" is a measurement or it is a wish.
            //
            // It cannot collide with the row. The cluster ends 284px into a
            // 360px island and this glyph's ink starts 12px from the right
            // border, leaving 44px of clear island between them -- measured by
            // the probe, not assumed.
            EdgeIcon {
                id: pomoStopwatch
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                trailing: true
                glyph: "timer"
                // 12, not the arrows' 17. This is the ONE edge mark that does
                // not sit where the skip arrows sit, and it is deliberate: the
                // arrows were asked to be further in, this one was asked to be
                // nearer the edge. Keeping the deviation here rather than in
                // the component means the next edge mark still inherits 17
                // from the arrows by default.
                edgeGap: 12
                // ALWAYS ON, not on hover. The arrows can hide, because the
                // music view announces itself the moment anything plays; the
                // timer tab is a resting tab and a control that only exists
                // while the pointer is near it is a control you have to find.
                // Hover now only decides whether the ring lights.
                revealed: true
                ringSize: pomoPlayButton.width
                held: root.skipRingHold
                active: root.stopwatchMode
                armed: root.mode === root.modePomodoro
                onTriggered: root.stopwatchMode = !root.stopwatchMode
            }
        }

        // ── 1 · Media ─────────────────────────────────────────────────────
        FadeView {
            id: mediaView
            anchors.verticalCenter: parent.verticalCenter
            viewIndex: root.modeMedia
            // How much width the media view ASKS for. This has to be the
            // row's natural content width, not the row's actual width: the
            // island is `max(360, widest view's implicitWidth)`, so this
            // number is what sizes the island. Using the row's real width
            // here instead would be circular -- the row is anchored to this
            // view's edges -- and collapsed the island to nothing.
            implicitWidth: mediaRow.contentWidth
            // ...and how much it GETS: the whole island, edge to edge. The
            // row is anchored left and right to this, so the row -- and with
            // it the two arrows, which anchor to the row -- spans the
            // painted border. The island is 360 wide whatever this view asks
            // for, so a view-sized row left the arrows marooned in the
            // middle of the island.
            width: stage.width
            implicitHeight: root.height
            on: root.mode === root.modeMedia

            // `shownPlayer`, not `activePlayer`: the island keeps the song on screen
            // while it is paused, and only hands over to another app when
            // that app is actually making sound (see MprisController).
            readonly property var player: MprisController.shownPlayer
            // One name, decided in MprisController: the AUDIBLE browser tab
            // when a browser is the one making sound (its bus only knows the
            // focused tab), else the player's track, else the app's own name
            // for a game or Discord, which publish no player at all.
            readonly property string title: MprisController.nowPlayingName
            // Some players report the artist as a plain string instead of a
            // list (a TypeError on .join() otherwise), so normalize both.
            readonly property string artists: {
                const a = player?.trackArtists ?? "";
                return Array.isArray(a) ? a.join(", ") : String(a);
            }

            // ── The row shows the SONG; the artist is an OPTION ─────────
            // The second field a player reports is not always an artist -- on
            // this library it can be the playlist or the folder -- so it is
            // never printed unconditionally beside the song name.
            //
            // The label is the song. The author is appended ONLY while the
            // pair still fits in one piece, measured below with the label's
            // own font: if it does not fit, the artist is dropped. It is never
            // allowed to be the reason the song name ends in "…".
            readonly property string artistSuffix: artists !== "" ? " · " + artists : ""
            // TWO budgets, and they are not the same number on purpose.
            //
            // `titleMaxW` is how wide the NAME may get. It is generous, because
            // the name is the point of the row: the island grows a little to
            // hold it rather than cutting a real title short -- measured on
            // this library, "a new kind of love - Enkei Remix" needs 229px, and
            // the old 186 budget truncated it to "a new kind of love - Enke…".
            //
            // `pairMaxW` is the budget the AUTHOR has to earn. It is the old,
            // compact width: the artist is a bonus, so it is only added while
            // the pair fits inside the width the island would have had anyway.
            // A name that needs the wider budget means there is no room to
            // spare, and then the author is simply left out -- never shown as
            // "…".
            readonly property real titleMaxW: 320
            readonly property real pairMaxW: 186
            // (`advanceWidth` is a PROPERTY of TextMetrics -- the width of the
            // `text` it is given -- not a function, so the pair is handed to
            // the metrics item and its width read back.)
            readonly property bool artistFits: artistSuffix !== ""
                && titleMetrics.advanceWidth <= pairMaxW
            readonly property string shownText: artistFits ? title + artistSuffix : title

            // Laid out by hand, not by a Layout: the label + soundbar block
            // and the transport button are anchored to each other, so the
            // block can never be squeezed or re-centred by a layout that
            // thinks it knows better (which is exactly what left the label
            // floating in the top half of the island with its soundbar
            // dropped below it).
            Item {
                id: mediaRow
                // FULL WIDTH of the island, not a content-fitted box. This used
                // to be `anchors.centerIn: parent` with the width summed from
                // its parts, which is exactly why the arrows sat next to the
                // label: the whole group [arrow, label, button, arrow] was one
                // centred unit, so "next to the label" and "at the island's
                // edge" were the same place. Stretching the row is what makes
                // those two different places -- the arrows can now go to the
                // edges while the label and button stay put in the middle.
                anchors.left: parent.left
                anchors.right: parent.right
                // WITHOUT this the music sat high in the island. The row is
                // shorter than the view (25 of 34), so with no vertical
                // anchor it simply stayed at y=0 and the whole music block --
                // label, soundbar, transport and arrows -- rode 4-5px above
                // where the other three tabs centre theirs. Nothing in the
                // row was wrong; the row itself was never told where to sit.
                anchors.verticalCenter: parent.verticalCenter
                height: Math.max(mediaBlock.height, mediaPlayButton.height)

                // What this row would need if nothing was pinned to the edges:
                // both arrows, their gaps, the label block and the transport
                // button. Read by the view above to size the island, so the
                // island is never narrower than its own content -- the
                // arrows reaching the edges is then free, because the island
                // already has the room.
                readonly property real contentWidth: skipPrev.width + 6
                    + mediaBlock.width + 9 + mediaPlayButton.width + 6
                    + skipNext.width

                // ── Skip arrows · now matching the transport button ───────
                //
                // These were bare Text glyphs -- the literal characters "‹"
                // and "›" at pixelSize.normal (16). Three things were wrong
                // with that, all of them the same request:
                //
                //   * Not the same DESIGN. A typed "‹" is whichever glyph the
                //     text font happens to carry for U+2039: it has no
                //     FILL axis, so it cannot do what the transport button
                //     does (an empty outline at rest, closing to solid on
                //     hover) and it never matched it in weight. Both arrows
                //     are now Material Symbols in the icon family, which is
                //     the same widget the play/pause button uses.
                //
                //   * Not the same SIZE. 16 against the button's 21 read as
                //     two different controls, not one transport. The em now
                //     comes from the transport button itself.
                //
                //   * Not at the island's EDGE. See mediaRow above: the row
                //     was content-fitted and centred, so the arrows floated
                //     next to the label. They now anchor to the row's own
                //     left and right, which are the island's painted edges.
                //
                // They also only APPEAR when the music is being reached for
                // (SkipArrow.revealed), and they carry the real "skip song"
                // mark -- triangle plus bar -- rather than chevrons.
                SkipArrow {
                    id: skipPrev
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    forward: false
                    revealed: root.islandHovered
                    // The transport button's own box, so the ring is
                    // literally the same rectangle the resume button draws.
                    ringSize: mediaPlayButton.width
                    held: root.skipRingHold
                    armed: root.mode === root.modeMedia
                    onTriggered: mediaView.player?.previous()
                }

                // The label and its soundbar are ONE block, and the block is
                // positioned by hand rather than by a layout. It is laid out
                // as a ROW: soundbar, then label, then transport.
                //
                // The meter's span is counted ONLY while audio plays
                // (`meterSpan` below). At rest the block is the label alone,
                // so the name sits on the island's centre; while audio plays
                // the block widens by the meter's span and the LABEL moves
                // right by exactly that much, leaving the meter its place at
                // the label's left.
                //
                // The old version drew a dim 24px track at rest -- a thin
                // horizontal hairline beside the name with nothing playing,
                // which read as a stray rule -- and reserved the meter's
                // width even then, so the name could never sit in the middle
                // of the island.
                //
                // The soundbar used to sit UNDER the label, centred, which is
                // where the owner's "weird line under the music" came from --
                // and it was also the reason they could not see a soundbar
                // next to the name at all. The label is now vertically
                // centred against the bar instead of standing on it, so the
                // two read as one unit: the bar is a level meter beside the
                // track, not a stray rule beneath it.
                Item {
                    id: mediaBlock
                    // Centred as HALF of the [label + transport] group, not on
                    // its own: the group's own centre sits
                    // (9 + buttonWidth) / 2 to the right of the label's, so
                    // centring the label alone would push the whole cluster
                    // right of the island's middle by half the button.
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.horizontalCenterOffset:
                        -(mediaPlayButton.width + 9) / 2
                    anchors.verticalCenter: parent.verticalCenter
                    // How much of this row the meter takes: its own width plus
                    // its gap, and ONLY while it is drawn. At rest this is 0,
                    // so the block is the label and nothing else -- the label
                    // lands on the island's centre instead of being shoved off
                    // it by a meter that is not on screen. While audio plays
                    // it is the meter's real span, and the label's left inset
                    // below reads this same number, so the two can never
                    // disagree about where the name starts.
                    readonly property real meterSpan: root.audioPlaying
                        ? mediaSoundbar.width + 6 : 0
                    // Hugs the label (up to the elide cap) plus whatever the
                    // meter is using, so the transport button sits right next
                    // to it instead of across an empty field.
                    width: meterSpan + Math.min(mediaView.titleMaxW, mediaTitle.implicitWidth)
                    height: 20

                    // The soundbar: a MINIATURE of the popped-out card's bar
                    // (NowBarPanel's pillBar) at the LEFT of the track name.
                    // Same design language, scaled down: rounded-TOP pills
                    // standing on a 1.5px bottom line, each pill reading its
                    // own band, the same /700 + 0.7 curve. It used to be a
                    // WaveVisualizer, whose blurred fill on a meter this small
                    // smeared into a pale oval beside the title -- the
                    // "strange light oval". Pills keep the accent crisp at
                    // this size because every bar is a solid rectangle.
                    //
                    // Fixed width (not "never wider than the label") so the
                    // label's own width changes -- a long title eliding, an
                    // artist line appearing -- can never resize the meter and
                    // make the whole block twitch.
                    Item {
                        id: mediaSoundbar
                        // Drawn ONLY while audio is playing. At rest the island
                        // has no meter at all: no pills (they were already
                        // gated) and no 1.5px bottom rule either -- that rule
                        // was the thin horizontal line left sitting beside the
                        // track name whenever nothing was playing.
                        visible: root.audioPlaying
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: 24
                        height: 14

                        // Five pills across 24px: 3px wide with 2px gaps, the
                        // same pill proportions as the card's bar, just fewer
                        // of them. More than five turns each pill sub-3px,
                        // where rounded tops stop rendering as anything but a
                        // blur.
                        readonly property int count: 5
                        readonly property real gap: 2
                        readonly property real pillW: (width - gap * (count - 1)) / count

                        // The same measured scaling as the card: mean ~283,
                        // p90 ~590 on this machine, so /700 with a 0.7 curve
                        // keeps quiet passages moving without pinning a loud
                        // one to the top.
                        //
                        // MAX-POOLING, not point sampling. Five pills cannot be
                        // five points of a 51-band spectrum: measured on the
                        // real stream, the energy lives in bands ~4-7 and
                        // ~15-16, so sampling indices 0/12/25/37/50 hit
                        // near-zero bands and every pill sat at its minimum
                        // height forever -- a meter that never moved. Each pill
                        // is instead the MAX of its slice of the spectrum,
                        // which is how few-bar analysers are built: nothing is
                        // missed between samples, a kick in band 5 lights the
                        // second pill even though pill two "is" band 10.
                        function bandFor(i) {
                            const p = root.visualizerPoints;
                            if (!p || p.length < 3) return 0;
                            const lo = Math.floor(i * p.length / count);
                            const hi = Math.max(lo + 1, Math.floor((i + 1) * p.length / count));
                            let m = 0;
                            for (let k = lo; k < hi && k < p.length; ++k)
                                if (p[k] > m) m = p[k];
                            return Math.pow(Math.min(1, m / 700), 0.7);
                        }

                        // The bottom line belongs to the METER, not to the
                        // resting island: while audio plays the pills rise
                        // from it, and with nothing playing it is not drawn at
                        // all. Visible is stated here as well as on the meter
                        // itself so the rule cannot come back on its own if
                        // that outer switch is ever changed.
                        Rectangle {
                            anchors.bottom: parent.bottom
                            width: parent.width
                            height: 1.5
                            radius: 0.75
                            color: ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.35)
                            visible: root.audioPlaying
                        }

                        Repeater {
                            model: mediaSoundbar.count
                            Rectangle {
                                required property int index
                                readonly property real v: mediaSoundbar.bandFor(index)
                                width: mediaSoundbar.pillW
                                // Rests ON the line, grows up, never crosses it.
                                height: Math.max(1.5, v * (mediaSoundbar.height - 2))
                                y: mediaSoundbar.height - height
                                x: index * (mediaSoundbar.pillW + mediaSoundbar.gap)
                                radius: width / 2
                                color: Appearance.colors.colPrimary
                                opacity: 0.55 + 0.45 * v
                                visible: root.audioPlaying
                                Behavior on height {
                                    NumberAnimation { duration: 90; easing.type: Easing.OutCubic }
                                }
                                Behavior on opacity {
                                    NumberAnimation { duration: 120 }
                                }
                            }
                        }
                    }

                    Text {
                        id: mediaTitle
                        // Anchored to the BLOCK, not to the meter: the meter's
                        // span is 0 at rest, and anchoring to a hidden bar's
                        // right edge would push the name right by a width that
                        // is not on screen. `leftMargin` IS the meter's span,
                        // so the name starts at the block's left edge when
                        // idle and 30px in when the meter is up.
                        //
                        // Vertically centred against the meter, not based on
                        // its top edge: with the bar beside the glyphs there
                        // is no edge to sit on, and verticalCenter is what
                        // actually centres text whose box carries leading
                        // under the baseline.
                        anchors.left: parent.left
                        anchors.leftMargin: mediaBlock.meterSpan
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(mediaView.titleMaxW, implicitWidth)
                        // Playing: the SONG name, plus the author when the pair
                        // fits whole (see mediaView.artistFits -- it is dropped
                        // rather than elided). At rest: the last song this
                        // island saw, remembered below -- "Nothing playing" is
                        // only for a session that never played anything.
                        text: mediaView.title !== ""
                            ? mediaView.shownText
                            : (root.lastTrackText !== "" ? root.lastTrackText
                                : (root.audioPlaying ? "Audio playing" : "Nothing playing"))
                        // The one writer of the memory above. The binding can
                        // only read; this stores the SONG NAME while there is a
                        // real track (an empty title means the player went
                        // away, not that the song changed), so the resting row
                        // still names it -- artist left out on purpose, since
                        // that field is not trusted enough to keep.
                        onTextChanged: if (mediaView.title !== "")
                            root.lastTrackText = mediaView.title
                        color: Appearance.colors.colOnLayer0
                        font.pixelSize: Appearance.font.pixelSize.small
                        font.weight: 500
                        elide: Text.ElideRight
                    }
                }

                // Compact transport: pause/play only -- pressing the island
                // body is a click away from the full card.
                IslandButton {
                    id: mediaPlayButton
                    anchors.left: mediaBlock.right
                    anchors.leftMargin: 9
                    anchors.verticalCenter: parent.verticalCenter
                    // This button is ANCHORED, not laid out, and a plain
                    // Item's width/height default to 0 -- implicitWidth
                    // only sizes an item a layout manages. Without this it
                    // drew its glyph (the symbol centres on a 0x0 parent)
                    // but had an empty hit rect, so presses fell through to
                    // the island background instead of the button.
                    width: implicitWidth
                    height: implicitHeight
                    armed: root.mode === root.modeMedia
                    // The glyph reads root.audioPlaying, the SAME flag the
                    // resting view, the auto-swap and the soundbar all read.
                    //
                    // It used to read mediaView.player?.isPlaying, and that is
                    // a DIFFERENT source: `player` is MprisController's
                    // currently-tracked object, which survives a track ending
                    // and gets re-pointed as players come and go. A player
                    // object that exists but is not the thing making sound
                    // reported its own stale state, so the button kept
                    // showing "play" (or "pause") while a song was actually
                    // running the other way. One flag, one truth: the island
                    // can no longer disagree with itself.
                    // When the sound is a browser, its MPRIS "isPlaying" is the
                    // FOCUSED tab's state -- the button showed "play" while a
                    // different tab was audible. The browser's own answer is
                    // used instead, so the glyph matches what you can hear.
                    readonly property bool browserTransport: MprisController.browserSounding
                        || (MprisController.soundAppName === ""
                            && MprisController.isBrowser(MprisController.shownPlayer))
                    // `browserTabPlayingShown`, not the measured property: a
                    // press states its intent at once (see MprisController),
                    // so the glyph turns under the finger instead of a second
                    // or two later, once a probe has caught up with the tab.
                    icon: (browserTransport
                        ? MprisController.browserTabPlayingShown
                        : root.audioPlaying) ? "pause" : "play_arrow"
                    // Hover is the earliest moment we know a press is coming,
                    // and it is ~450ms before the click. Starting the waveform
                    // pipeline here means the sound bar is already moving by
                    // the time the track actually starts, instead of fading up
                    // from nothing a beat after the press.
                    HoverHandler {
                        id: mediaPlayHover
                        onHoveredChanged: {
                            if (hovered)
                                AudioVisualizer.warm();
                        }
                    }                     onTriggered: {
                        // Same again on the press itself, for a click that
                        // arrives without a hover (touchpad tap, keyboard
                        // activation). `warm()` is idempotent.
                        AudioVisualizer.warm();
                        // A browser press must reach the AUDIBLE tab: the MPRIS
                        // verb goes to the media-session tab, which is whichever
                        // one is in front -- measured, that paused the previous
                        // tab and left the sounding one running.
                        if (mediaPlayButton.browserTransport) {
                            MprisController.browserTabAction("toggle");
                            return;
                        }
                        const p = mediaView.player;
                        if (p) p.togglePlaying();
                    }
                }

                // Next: the mirror of skipPrev, on the RIGHT EDGE of the
                // island. It used to hang off the transport button's right,
                // which put the two arrows on opposite ends of the label --
                // the arrangement that read as clutter next to a centred
                // cluster. Same mark, same size, same reveal, mirrored so
                // the bar leads on the way back and trails on the way on.
                SkipArrow {
                    id: skipNext
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    forward: true
                    revealed: root.islandHovered
                    ringSize: mediaPlayButton.width
                    held: root.skipRingHold
                    armed: root.mode === root.modeMedia
                    onTriggered: mediaView.player?.next()
                }
            }
        }

// ── 2 · Local AI ───────────────────────────────────────────────────
        // The island's half of the same fact the card's fourth tab shows.
        //
        // It used to read FlareData and show "Claude · Pro · 43% used today" --
        // a cloud plan's quota. That is gone with the rest of it. What is here
        // is the small end of the same question the console answers in full:
        // is the local server up, and if it is, how fast is it going.
        //
        // At island size there is no room for gauges, so it is the agent mark,
        // a model name and one number. The mark breathes ONLY while a slot is
        // working, because a heartbeat on an idle server is noise dressed as
        // activity.
        FadeView {
            id: aiView
            anchors.verticalCenter: parent.verticalCenter
            viewIndex: root.modeAi
            implicitWidth: aiRow.implicitWidth
            implicitHeight: root.height
            on: root.mode === root.modeAi

            // The island is collapsed most of the time, so it only asks for a
            // real reading while this view is actually the one on screen.
            //
            // Driven by `on`, not by `visible`: `FadeView` binds `visible` to
            // its own opacity so a view stays drawn while it slides, which
            // means `onVisibleChanged` fires for tab CHANGES rather than for
            // this view becoming the current one -- and it stayed false here
            // entirely, leaving the island's readings permanently blank.
            onOnChanged: root._syncAiClaim()
            Component.onCompleted: root._syncAiClaim()
            Component.onDestruction: LlamaService.release("island")

            RowLayout {
                id: aiRow
                anchors.centerIn: parent
                spacing: 9

                // The local model, marked as an agent rather than as a status
                // dot. Online/offline is the face: eyes open while the server
                // is up, closed while it is not -- and it breathes ONLY while a
                // slot is working, because a heartbeat on an idle server is
                // noise dressed as activity.
                AgentMark {
                    id: aiMark
                    Layout.alignment: Qt.AlignVCenter
                    markColor: LlamaService.online
                        ? Appearance.colors.colPrimary
                        : Appearance.colors.colOnLayer1Inactive
                    awake: LlamaService.online

                    SequentialAnimation on opacity {
                        running: LlamaService.online && LlamaService.busySlots > 0
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.35; duration: 850; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1.0; duration: 850; easing.type: Easing.InOutSine }
                    }
                }

                ColumnLayout {
                    Layout.alignment: Qt.AlignVCenter
                    spacing: -3
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        // The model is NAMED whether or not the server is up:
                        // `displayName` falls back to the selected .gguf on
                        // disk, so the island says which model a Run would
                        // start instead of a bare "AI off". Only the colour
                        // reports liveness now (the mark beside it does too).
                        text: LlamaService.displayName.length > 0
                            ? LlamaService.displayName
                            : Translation.tr("No model")
                        color: LlamaService.online
                            ? Appearance.colors.colPrimary
                            : Appearance.colors.colSubtext
                        font.pixelSize: Appearance.font.pixelSize.small
                        font.weight: 500
                    }
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        // The one number worth the two lines: generation
                        // speed. Blank rather than "—" when idle, because the
                        // island shows a name above it and a dash under a name
                        // reads as a broken value.
                        //
                        // "starting…" outranks the speed and takes the accent,
                        // because while the weights are loading there is no
                        // speed to print and this line was BLANK for the whole
                        // boot -- which is what made a server that was coming
                        // up read exactly like one that was off. The island is
                        // the only place the model is named while the popup is
                        // shut, so it is the only place that can say so. The
                        // word matches the offline pane's Endpoint row, which
                        // says the same thing one surface over.
                        text: LlamaService.loading
                            ? Translation.tr("starting…")
                            : (LlamaService.genTokensPerSec > 0
                                ? `${LlamaService.genTokensPerSec.toFixed(1)} t/s`
                                : "")
                        visible: LlamaService.loading || LlamaService.genTokensPerSec > 0
                        color: LlamaService.loading
                            ? Appearance.colors.colPrimary
                            : Appearance.colors.colOnLayer1Inactive
                        font.pixelSize: Appearance.font.pixelSize.tiny
                    }
                }

                // ONE power control that ALTERNATES, not a pair: a green play
                // labelled "Run" while nothing is up, a red stop labelled
                // "Stop" while it is. Drawn here, PRESSED from inputArea -- the
                // island keeps a single pointer layer, so a control absent from
                // islandButtons() can neither hover nor click (see that
                // function).
                AiCtl {
                    id: islandPowerBtn
                    Layout.alignment: Qt.AlignVCenter
                    readonly property bool running: LlamaService.online || LlamaService.loading
                    glyph: islandPowerBtn.running ? "stop" : "play_arrow"
                    label: islandPowerBtn.running
                        ? Translation.tr("Stop")
                        : Translation.tr("Run")
                    tint: islandPowerBtn.running ? Appearance.colors.colError : "#3fb950"
                    usable: !LlamaService.busy
                    armed: root.mode === root.modeAi
                    onTriggered: LlamaService.toggle()
                }
            }
        }

        // ── 3 · Performance ───────────────────────────────────────────────
        // The machine itself, as four instruments in a row: an icon, the
        // number, and the last minute of it drawn underneath. Readings with no
        // source on this machine (no graphics clock, no thermal sensor) go
        // quiet -- a hollow track and "--" -- instead of pretending to be zero.
        //
        // No labels here: at this size there is no room, and the icon is the
        // label. The carded view names each one.
        FadeView {
            id: perfView
            anchors.verticalCenter: parent.verticalCenter
            viewIndex: root.modePerf
            implicitWidth: perfRow.implicitWidth
            implicitHeight: root.height
            on: root.mode === root.modePerf

            Row {
                id: perfRow
                anchors.centerIn: parent
                spacing: 10

                Repeater {
                    model: root.perfGauges

                    SystemGauge {
                        required property var modelData
                        readonly property string key: modelData.key
                        anchors.verticalCenter: parent.verticalCenter
                        compact: true
                        icon: modelData.icon
                        value: root.perfValue(key)
                        load: root.perfLoad(key)
                        history: root.perfHistory(key)
                        accent: modelData.accent
                    }
                }
            }
        }

        // ── 4 · Trading ───────────────────────────────────────────────────
        // The instrument, its price, the move since the open, and the last
        // few closes as a sparkline: the same three facts the card leads
        // with, at island size. The chip is the symbol switcher's answer to
        // "which one am I looking at" -- switching happens in the card.
        FadeView {
            id: tradingView
            anchors.verticalCenter: parent.verticalCenter
            viewIndex: root.modeTrading
            implicitWidth: tradingRow.implicitWidth + 8
            implicitHeight: root.height
            width: stage.width
            on: root.mode === root.modeTrading
            // Only a shown trading view ticks the series. Same claim the
            // card's view takes, so the two can never both drive it.
            // Claimed on `visible`, not on the boolean: a view that is off
            // still HOLDS this property while it fades out, and the claim
            // only has to be true while something is drawn. Same contract
            // the card's view uses, so the island and the card can never
            // both drive the series.
            onVisibleChanged: if (tradingView.visible) TradingService.claim(tradingView); else TradingService.release(tradingView)
            Component.onDestruction: TradingService.release(tradingView)

            Row {
                id: tradingRow
                anchors.centerIn: parent
                spacing: 9

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: tradingSymbol.implicitWidth + 12
                    height: 20
                    radius: Appearance.rounding.verysmall
                    color: Appearance.colors.colLayer1
                    Text {
                        id: tradingSymbol
                        anchors.centerIn: parent
                        text: TradingService.symbol
                        font.family: Appearance.font.family.monospace
                        font.pixelSize: Appearance.font.pixelSize.tiny
                        font.weight: Font.DemiBold
                        color: Appearance.colors.colOnLayer1
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: TradingService.formatPrice(TradingService.price)
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colOnLayer0
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: (TradingService.up ? "▲ " : "▼ ")
                        + Math.abs(TradingService.changePct).toFixed(2) + "%"
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.tiny
                    color: TradingService.up ? "#46A758" : "#E5484D"
                }
                Canvas {
                    id: tradingSpark
                    anchors.verticalCenter: parent.verticalCenter
                    width: 48
                    height: 18
                    property int rev: TradingService.rev
                    onRevChanged: requestPaint()
                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()
                    onPaint: {
                        const ctx = getContext("2d");
                        ctx.clearRect(0, 0, width, height);
                        const cs = TradingService.candles;
                        if (cs.length < 2)
                            return;
                        const pts = cs.slice(-26).map(c => c.c);
                        const lo = Math.min.apply(null, pts);
                        const hi = Math.max.apply(null, pts);
                        const sp = (hi - lo) || 1;
                        ctx.strokeStyle = TradingService.up ? "#46A758" : "#E5484D";
                        ctx.lineWidth = 1.4;
                        ctx.beginPath();
                        for (let i = 0; i < pts.length; i++) {
                            const x = i / (pts.length - 1) * (width - 2) + 1;
                            const y = height - 2 - (pts[i] - lo) / sp * (height - 4);
                            if (i === 0)
                                ctx.moveTo(x, y);
                            else
                                ctx.lineTo(x, y);
                        }
                        ctx.stroke();
                    }
                }
            }
        }
    }

    // ── The tabs tell ─────────────────────────────────────────────────────
    // How many views this island can be swapped to, and which one you are on:
    // one tick per tab along the island's own bottom edge, the live one longer
    // and accented. It leans forward (brighter, wider) for a beat after every
    // swap, so the count is legible exactly when you went looking for it, and
    // it rides the same fast curve as the rest of the tab logic.
    // The island's buttons are drawn here and PRESSED from inputArea above:
    // the island keeps exactly one pointer layer, and a button is found by
    // hit-testing its own rect there. That is what makes both in-island
    // buttons (and every press on the island) reliable instead of
    // depending on a press falling through the view stack.
    // ── The skip mark ───────────────────────────────────────────────────
    // GLYPH AND BAR, NOTHING ELSE. No pad, no ring, no box: the transport
    // button next to it is a 25px pad around a 21px mark, which is right for
    // a button you press and wrong for two arrows that only mean "go back"
    // and "go on" -- padded out, they read heavier than the song title they
    // flank. The only hover feedback is colour and the FILL axis.
    //
    // This started life as bare typed ‹ › characters, then as a
    // triangle-and-bar icon sized to match the play/pause button, then as a
    // menu of six candidates the owner picked from. It is now simply the
    // mark: a chevron with a bar in front of it, the shape a "skip song"
    // control has everywhere else, cut to the chevron's own stroke.
    component SkipArrow: Item {
        id: skipArrow
        // false = go back, true = go on.
        property bool forward: true
        // Whether the pointer is anywhere near the music. The arrows are
        // hidden at rest and fade in together rather than one at a time: an
        // invisible control you have to find by touching it is not a
        // control, it is a trap. Opacity only, never `visible`, so they keep
        // their slot in the layout and revealing them moves nothing.
        property bool revealed: false
        //
        // This component's input is NOT its own. The island has one
        // full-bleed MouseArea above everything (inputArea, z 100) and
        // hit-tests its buttons by geometry, so a HoverHandler or TapHandler
        // in here never sees a single event. So they speak the same contract
        // as IslandButton: the island sets hoverState/pressState and calls
        // triggered().
        property bool hoverState: false
        property bool pressState: false
        property bool armed: true
        // Pins the hover look on without the pointer. The ring is a 1px
        // accent border at 0.55 opacity on a mark that only appears while
        // the island is hovered, and it lights up ONLY when the pointer is
        // within a few pixels of the arrow itself -- so judging it by waving
        // a mouse around it is how three rounds of "I don't see any change"
        // happen. `qs -c ii ipc call nowbar skipRing hold` turns both rings
        // on at once to look at; `off` puts it back. It is a switch, not a
        // preview: no designs, nothing to choose, and it defaults off.
        property bool held: false
        signal triggered()
        readonly property bool hot: hoverState || pressState || held

        // ── The mark ───────────────────────────────────────────────────
        // The icon font's OWN skip mark, |◀ and ▶|, drawn as one glyph
        // (skip_previous / skip_next) instead of a chevron with a bar stuck
        // on the front.
        //
        // The old mark was those two pieces separately, and the bar was the
        // problem: 9px against the chevron's 15px of ink, so it stopped
        // halfway up the arrow and hung off one side -- which is not a
        // control, it is the recipe for a lowercase k. Six candidates were
        // measured at the em (see the probe's skipCands line); the font's own
        // mark won because it was drawn by the same people who drew the
        // play_arrow beside it, so the triangle and the bar are already the
        // right weight for each other.
        //
        // What it gives up: the FILL axis. The chevron was an outline glyph,
        // so it could close to solid; this one is a solid triangle and there
        // is nothing to fill. Nothing was lost by it -- the arrows lost the
        // fill axis when MaterialSymbol's fill sweep was deleted, and the
        // ring was the hover tell from then on. Same as now.
        readonly property string glyph: forward
            ? "skip_next" : "skip_previous";
        // 20, the same em as the transport glyph (IslandButton.glyphSize), so
        // the two marks are the same size by construction and neither can be
        // resized without the other.
        readonly property real em: 20

        // The bar, cut from the chevron rather than guessed, and both numbers
        // came down a size because the pair was reading heavier than the
        // song title it flanks:
        //   width  em * 1.5/20 -> 1.5px at em 20, down from 1.9. The old
        //                       number was the chevron's own stroke, which
        //                       is the right answer for a mark drawn ALONE;
        //                       beside the arrow it is a line as thick as
        //                       the arrow's whole stem, and the two together
        //                       read as one thick mark.
        //   height em * 9/20  -> 9px, down from 11, against the arrow's ~15px
        //                       of ink. At the arrow's full height the pair
        //                       read as a pause button; at 11 they still
        //                       filled the gap between the chevron's arms; at
        //                       9 the bar is a stem the arrow grows out of.
        // Both scale with the em, so the mark stays in proportion if it is
        // ever resized instead of needing its own numbers.
        // The mark's FILL axis, PINNED at 0 and named so the pin is something
        // the probe can report rather than a literal buried in the glyph's
        // bindings. A second animated hover layer is exactly the sort of
        // regression that comes back silently, three edits later.
        readonly property real markFill: 0
        // ── Where the INK is, measured ──────────────────────────────────
        // Everything below is laid out on the measured INK, not on the text
        // box. A ligature's layout box is a full em (20px) whatever the
        // drawing inside it is -- skip_next draws 12px of ink in a 20px box --
        // and the ink is not guaranteed to sit in the middle of that box.
        // Centring the box centres the wrong thing by however far the ink is
        // off, which is exactly the "icon looks slightly wrong inside the
        // hover square" that cannot be seen in code and only shows up on the
        // bar.
        //
        // So markInk measures the real glyph with the REAL font (bound to the
        // widget that draws it, so family, opsz and weight are the ones in
        // use) and the art is positioned from the ink's own centre.
        TextMetrics {
            id: markInk
            // The font is taken FROM the glyph rather than rebuilt here: a
            // hand-built font would drop the opsz axis, and this font's ink
            // is not linear in the em, so a rebuilt font measures a different
            // shape from the one on screen.
            font: mark.font
            text: skipArrow.glyph
        }
        readonly property rect ink: markInk.tightBoundingRect
        // Exposed rather than read from `markInk` by the probe: an id inside
        // this component is not in scope in the IpcHandler, and referencing
        // it there throws a ReferenceError that Quickshell swallows whole --
        // the probe prints NOTHING at all, with no error anywhere.
        readonly property real advance: markInk.advanceWidth
        // The glyph's LINE height, which is NOT the art's height and NOT the
        // ink's. TextMetrics.height is the font's ascent+descent, and the Text
        // item is laid out at it, so this is the box the baseline sits in.
        // Reported by the probe, because a mark positioned against the wrong
        // one lands a whole line box out.
        readonly property real lineHeight: markInk.height
        // The ink's offset from the BASELINE, not from the top of anything.
        // Published under a name that says so, because `ink.y` read as a
        // top-relative offset is the mistake that pushed the arrows off the
        // bottom of the island.
        readonly property real inkFromBaseline: ink.y
        readonly property real inkWidth: ink.width
        readonly property real inkHeight: ink.height
        // The ink's centre, in the glyph's own coordinates.
        readonly property real inkCentreX: ink.x + ink.width / 2
        readonly property real inkCentreY: ink.y + ink.height / 2
        // How far the ink sits from the middle of its own ADVANCE. This is
        // the number that says whether centring the layout box would even
        // have been right: if this is 0 the box and the ink agree and the
        // measurement bought nothing; if it is not 0, the box was centring
        // the wrong rectangle by exactly this much. Reported by the probe so
        // the answer is known rather than assumed.
        readonly property real inkOffsetInAdvance: inkCentreX
            - markInk.advanceWidth / 2
        // The art's box IS the ink now (12px at em 20), so the 17px inset is
        // measured to the drawing and not to a box that happens to contain
        // it. The old 5.5px box was deliberately narrower than the chevron's
        // ink so the two shapes could overlap and hide their seam; there is
        // no second shape to hide anything from any more.
        readonly property real artWidth: inkWidth;
        // The ring's box IS the transport button's box -- its 25px pad, the
        // same rounded rect the resume/stop button draws on hover. It is
        // passed in from that button's real width rather than written as 25
        // here, so the two cannot drift apart when the pad changes, and it
        // is the same on both arrows and in every tab by construction.
        //
        // This is the opposite trade to the tight ring that came before (the
        // mark plus 4px, which was too small to read as the same control): a
        // 25px box around an 8.6px mark leaves ~8px at the sides against
        // ~5px top and bottom. Equal margins and "the same rectangle as the
        // resume button" cannot both be true of a mark this shape, and the
        // button's rectangle is the one that was asked for.
        property real ringSize: 25

        // How the art sits in the island's own box. The visible mark is
        // `edgeGap` from the border, and that number has been the whole
        // argument: 4px of symmetric air was "not at the edge", 1px was
        // "glued to the side", 17 is where it settled. It lives here as the
        // one place to move both sides together. The rest of the width is
        // hit area taken from the EMPTY side, inward, where it overlaps
        // nothing and costs nothing to look at: the mark stays small but the
        // target does not.
        //
        // Both arrows read the same number, so the inset is symmetric by
        // construction -- `art.x` is `edgeGap` on the way back and `hitPad`
        // on the way on precisely because the box is `hitPad` wider than the
        // art, which leaves `edgeGap` on the far side either way.
        readonly property real edgeGap: 17;
        readonly property real hitPad: 8;

        implicitWidth: artWidth + edgeGap + hitPad
        implicitHeight: 20
        opacity: revealed || hot ? 1 : 0
        // ASYMMETRIC, and the asymmetry is the point. 120ms both ways was
        // the original setting and it felt wrong in one direction only:
        // arriving read as responsive, leaving read as the arrow hanging
        // around after you had already looked away. These are the third
        // pass -- 90/55 was still a beat behind the pointer -- and the
        // numbers are now short enough that the fade finishes inside the
        // gap between two motion events on a fast sweep, so the arrows feel
        // attached to the cursor rather than trailing it.
        //
        // The exit is also what hides the slowest thing here: the glyph's
        // FILL axis runs on the shared 200ms token (MaterialSymbol's own
        // Behavior, used by every icon in the shell), so the chevron
        // un-filling drags on well past any fade shorter than that. At 40ms
        // the arrow is invisible before the tail starts, which is why the
        // fill was never shortened: it does not need to be.
        Behavior on opacity {
            NumberAnimation {
                duration: (skipArrow.revealed || skipArrow.hot) ? 70 : 40
                easing.type: Easing.OutCubic
            }
        }

        // The hover ring: the transport button's, matched property for
        // property -- 1px border, the same radius token, the same accent, the
        // same 0.55 hover / 0.8 press opacities, the same 110ms. It is the
        // button's only hover tell, and these arrows had none but a colour
        // change, so a pointer over one looked like a colour change and
        // nothing else.
        //
        // The transport button's own hover ring, box and all: 25x25,
        // `rounding.small`, 1px accent border, 0.55 on hover and 0.8 held
        // (see IslandButtonVisual, which is the same numbers on the same
        // 110ms). Declared before `art` so the mark paints on top of it.
        Rectangle {
            id: ring
            width: skipArrow.ringSize
            height: skipArrow.ringSize
            radius: Appearance.rounding.small
            color: "transparent"
            border.width: 1
            border.color: (skipArrow.hoverState || skipArrow.pressState)
                ? Appearance.colors.colPrimary
                : Appearance.colors.colOnLayer0
            // Hover 0.55, press brighter so a held press still reads as
            // harder than a pass-over -- the transport button's own numbers.
            // `held` rides the same 0.55 so the pinned state is exactly the
            // hover state and not a brighter lie.
            opacity: (skipArrow.hoverState || skipArrow.held)
                ? 0.55 : (skipArrow.pressState ? 0.8 : 0)
            // THE hover tell for these arrows, and now the ONLY one -- the
            // glyph's fill is pinned off (see the mark below). Same asymmetry
            // as the arrow's own fade, kept short on purpose: with the second
            // animated layer gone there is nothing for a long curve to
            // overlap, so this can be as close to instant as a fade gets
            // without flickering. `duration: 0` here if you want it literal.
            Behavior on opacity {
                NumberAnimation {
                    duration: (skipArrow.hoverState || skipArrow.held) ? 60 : 40
                }
            }
            x: art.x + (art.width - width) / 2
            anchors.verticalCenter: art.verticalCenter
        }

        Item {
            id: art
            height: parent.height
            width: skipArrow.artWidth
            // Pinned to the OUTER edge rather than centred: the empty side is
            // the one that keeps the press target, not the one that holds
            // the drawing.
            x: skipArrow.forward ? skipArrow.hitPad : skipArrow.edgeGap

            MaterialSymbol {
                id: mark
                // The text box is the glyph's own ADVANCE, left-aligned, and
                // x/y are set so that the INK lands dead centre of the art.
                // Centring the box instead (which is what this used to do,
                // with AlignHCenter in a box the size of the mark) centres the
                // empty space around the drawing rather than the drawing --
                // which is the whole of "the icon looks slightly off inside
                // the hover square". No anchors on this item: an anchor and
                // an explicit y cannot both be set, and the measurement is
                // what the position has to come from.
                width: markInk.advanceWidth
                x: skipArrow.artWidth / 2 - skipArrow.inkCentreX
                // VERTICALLY this is Qt's job, not the measurement's, and
                // getting that backwards cost an afternoon:
                //
                // `TextMetrics.tightBoundingRect.y` is measured from the
                // BASELINE, not from the top of the item. The probe reads
                // `ink.y` as -15.00 for a glyph with 15px of ink, which is
                // the ink sitting that far ABOVE the baseline -- so treating
                // it as a top-relative offset and solving for y put the whole
                // glyph one line box (24px) below where it belonged, and the
                // arrows rendered off the bottom of the island.
                //
                // The horizontal correction is still worth having, because x
                // is a plain left-to-right distance from the item's left edge
                // and the baseline does not enter into it. Vertically the Text
                // widget already knows where its own line sits; asking it is
                // strictly better than re-deriving it from a rectangle whose
                // origin is the baseline.
                anchors.verticalCenter: parent.verticalCenter
                text: skipArrow.glyph
                iconSize: skipArrow.em
                // PINNED at 0, and the pin is the fix.
                //
                // The FILL axis was hover feedback once, on top of the ring,
                // and that is two animated layers over one 25px mark: a 1px
                // border fading in while the glyph simultaneously grew from
                // outline to solid AND from Regular to DemiBold (the family's
                // weight axis rides on the same fill), on the shared 200ms
                // curve inside MaterialSymbol. Two things moving at two
                // different speeds over the same 20px of screen is what read
                // as a weird transition rather than as a hover.
                //
                // The transport button keeps its fill-on-hover -- it is one
                // control with one job, and it was tuned and approved that
                // way. An arrow is not a button: it says which way the track
                // goes, and the border already says "you are on me". So the
                // glyph holds its weight and its outline, and the only thing
                // that moves is the border. `color` has no Behavior, so the
                // accent swap is instant and adds no second motion.
                fill: skipArrow.markFill
                color: skipArrow.hot
                    ? Appearance.colors.colPrimary
                    : Appearance.colors.colOnLayer0
            }
        }
    }

    // The local model's own mark: a ROBOT FACE.
    //
    // It replaces a 9px ring that said "something is running" and nothing about
    // what. This drawing is the shell's own, deliberately NOT a stock icon-font
    // glyph and NOT an image file: nothing to license, nothing that arrives
    // looking unlike the rest of the bar, and it takes `Appearance` colours so
    // it follows the theme like every other mark in the island.
    //
    // LEAN ON PURPOSE -- three shapes, no more. A round cap on a short stem IS
    // the antenna, the head is one rounded square with no mouth and no ears, and
    // the eyes are the only thing inside it. Everything else a face "needs"
    // turns to mush at 13px in a top bar; the eyes carry the whole expression,
    // and the generous corner radius is what keeps a 10x7.5 box reading as a
    // modern head rather than as a box.
    //
    // The eyes are also where the STATE lives: solid dots while the server is
    // up, two closed lines while it is down. A change of SHAPE, not of
    // brightness -- the distinction the ring it replaces insisted on ("stopped"
    // and "idle" must not look like one circle at two brightnesses"). The
    // caller breathes the mark while a slot is working.
    //
    // Painted with Canvas, NOT QtQuick.Shapes. This file already records that
    // Shapes do not paint on this machine's setup at all ("19 path nodes, fill
    // #e2e2e2, visible true, scale 1.0 ... and NOTHING painted") -- which is why
    // the transport's pause bars are plain rectangles. Canvas is the one that
    // does paint here: the waveform below is one.
    component AgentMark: Item {
        id: agentMark
        property color markColor: Appearance.colors.colPrimary
        // True while the server is up. The eyes are OPEN -- solid dots -- and
        // they close to two flat lines when it goes down.
        property bool awake: true
        implicitWidth: 13
        implicitHeight: 13

        // Canvas refuses a QColor for a style, so the colour crosses as the one
        // string form the 2D context actually defines.
        readonly property string markCss: `rgba(${Math.round(agentMark.markColor.r * 255)},`
            + `${Math.round(agentMark.markColor.g * 255)},`
            + `${Math.round(agentMark.markColor.b * 255)},${agentMark.markColor.a.toFixed(3)})`

        // Repaint exactly when the picture changes, never per frame. The
        // caller's breathing animation is on `opacity`, which the scene graph
        // composites without touching this texture -- so the mark pulses for
        // free rather than re-rasterising the face 60 times a second.
        onMarkCssChanged: markCanvas.requestPaint()
        onAwakeChanged: markCanvas.requestPaint()
        Component.onCompleted: markCanvas.requestPaint()

        Canvas {
            id: markCanvas
            anchors.fill: parent
            renderStrategy: Canvas.Cooperative
            onPaint: {
                const ctx = getContext("2d");
                const w = width, h = height;
                const cx = w / 2;

                ctx.clearRect(0, 0, w, h);
                ctx.antialias = true;
                ctx.strokeStyle = agentMark.markCss;
                ctx.fillStyle = agentMark.markCss;
                ctx.lineWidth = Math.max(1, w * 0.085);
                // Round joins and caps, everywhere: every other mark in this
                // island is drawn with a round end, and a square one at 1px
                // reads as a rendering fault rather than as a choice.
                ctx.lineJoin = "round";
                ctx.lineCap = "round";

                // The head's box, first: the antenna hangs off its top edge and
                // the eyes are placed inside it, so both come from this.
                const hx = w * 0.10;
                const hw = w * 0.80;
                const headTop = h * 0.31;
                const hh = h * 0.58;

                // ── The antenna: a stem with a cap on it ─────────────
                // The one cue that says MACHINE. Drawn first so the head's
                // stroke lands on top of the stem's end rather than beside it.
                const stemY = h * 0.11;
                ctx.beginPath();
                ctx.moveTo(cx, headTop);
                ctx.lineTo(cx, stemY);
                ctx.stroke();
                ctx.beginPath();
                ctx.arc(cx, stemY, w * 0.055, 0, Math.PI * 2);
                ctx.fill();

                // ── The head: one rounded square, nothing else ────────
                // Corners from quadraticCurveTo rather than arcTo or roundRect:
                // the curves are the one path primitive already proven in this
                // canvas, and a corner here is a quarter turn, not an arc that
                // has to be measured.
                const r = h * 0.17;
                const hr = hx + hw, hb = headTop + hh;
                ctx.beginPath();
                ctx.moveTo(hx + r, headTop);
                ctx.lineTo(hr - r, headTop);
                ctx.quadraticCurveTo(hr, headTop, hr, headTop + r);
                ctx.lineTo(hr, hb - r);
                ctx.quadraticCurveTo(hr, hb, hr - r, hb);
                ctx.lineTo(hx + r, hb);
                ctx.quadraticCurveTo(hx, hb, hx, hb - r);
                ctx.lineTo(hx, headTop + r);
                ctx.quadraticCurveTo(hx, headTop, hx + r, headTop);
                ctx.closePath();
                ctx.stroke();

                // ── The eyes: the state ───────────────────────────────
                // Above the head's centre line, because a face whose eyes sit
                // at the exact middle reads as a socket, not as a face.
                const eyeY = headTop + hh * 0.42;
                const eyeDx = hw * 0.21;
                if (agentMark.awake) {
                    const eyeR = w * 0.065;
                    ctx.beginPath();
                    ctx.arc(cx - eyeDx, eyeY, eyeR, 0, Math.PI * 2);
                    ctx.fill();
                    ctx.beginPath();
                    ctx.arc(cx + eyeDx, eyeY, eyeR, 0, Math.PI * 2);
                    ctx.fill();
                } else {
                    // Closed: two short lines, a touch wider than the open eyes
                    // so the change is legible at a glance.
                    const half = w * 0.075;
                    ctx.beginPath();
                    ctx.moveTo(cx - eyeDx - half, eyeY);
                    ctx.lineTo(cx - eyeDx + half, eyeY);
                    ctx.moveTo(cx + eyeDx - half, eyeY);
                    ctx.lineTo(cx + eyeDx + half, eyeY);
                    ctx.stroke();
                }
            }
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
        }
    }

    // A compact island control: a small pill holding an icon AND its word, that
    // speaks the same protocol as every other in-island button (hoverState /
    // pressState / armed / triggered) so inputArea's single pointer layer can
    // drive it. `usable` dims it while it cannot act, matching the panel's hero
    // controls. Used by the AI view's power control below.
    //
    // THE WORD IS NOT DECORATION. An icon-only power control says nothing about
    // which way it will go: a square and a triangle at 14px are easy to confuse
    // at a glance, and "the off square" is exactly how it read. `label` names
    // the action the press will take, and the owner flips glyph and word
    // together from one `running` value so they can never disagree.
    component AiCtl: Item {
        id: aiCtl
        property string glyph: "play_arrow"
        property string label: ""
        property color tint: Appearance.colors.colPrimary
        property bool usable: true
        property bool hoverState: false
        property bool pressState: false
        property bool armed: true
        signal triggered()
        // The pill's box, and the alignment contract with the text beside it.
        //
        // 22 matches the island's own line box, and the glyph and the word are
        // centred inside it as a Row rather than anchored separately -- the old
        // icon-only version centred a MaterialSymbol, whose font box is taller
        // than the mark it draws, so the square sat above the ring's centre.
        // One Row in one box removes that whole class of drift.
        implicitWidth: aiLabelRow.implicitWidth + 14
        implicitHeight: 22
        opacity: aiCtl.usable ? 1 : 0.32
        Rectangle {
            anchors.fill: parent
            radius: Appearance.rounding.full
            color: (aiCtl.hoverState || aiCtl.pressState)
                ? ColorUtils.transparentize(aiCtl.tint, 0.82)
                : "transparent"
            border.width: 1
            border.color: ColorUtils.transparentize(aiCtl.tint, 0.45)
        }
        Row {
            id: aiLabelRow
            anchors.centerIn: parent
            spacing: 5
            MaterialSymbol {
                anchors.verticalCenter: parent.verticalCenter
                text: aiCtl.glyph
                iconSize: 13
                color: aiCtl.tint
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: aiCtl.label.length > 0
                text: aiCtl.label
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: aiCtl.tint
            }
        }
    }

    component IslandButton: Item {
        id: islandButton
        property string icon: ""
        // Driven by inputArea: it owns the press, we own the looks.
        property bool hoverState: false
        property bool pressState: false
        // False while this button's view is off screen, so it can never
        // swallow a tap meant for the view that is showing.
        property bool armed: true
        signal triggered()
        // 24 -> 18. The pad is still larger than the 12x10 mark inside it,
        // so the target stays comfortable, but the whole thing no longer
        // reads as a button sitting IN the pill -- it reads as part of the
        // island's text, which is what it is.
        //
        // 25, and it TRACKS the glyph: the pad is the glyph's em plus 2px of
        // air each side, so the mark never touches the ring on hover. This
        // number has moved with the glyph three times (16 -> 19 -> 25) for
        // the same reason each time: a pad sized for an older, smaller mark
        // leaves so little margin that the glyph and the ring touch, and the
        // button then reads as the glyph -- the exact failure the pad exists
        // to prevent.
        //
        // It stayed at 25 when the glyph dropped to 20, and that is not an
        // oversight. The pad is invisible until hover -- what the owner sees
        // is the mark -- and the row takes its height from the larger of this
        // and the label block, so 24 (even) against the title's 21px box
        // pushed the button's centre half a pixel off the song title's, the
        // one alignment this island has a probe for. The glyph is what
        // shrank; the pad did not.
        implicitWidth: 25
        implicitHeight: 25
        // The transport mark's size, as PROPERTIES rather than literals, so
        // the media button and the timer button can be matched (or
        // deliberately un-matched) per instance. They share this component,
        // so they were always the same size; these make that explicit instead
        // of accidental, and let one be smaller without touching the other.
        //
        // MEASURED to match the song title's height, not guessed.
        //
        // "As tall as the song name" is two font metrics, not one number.
        // `font.pixelSize` is the EM; the ink inside it is only part of that,
        // and these two fonts place their ink differently. Measured on this
        // machine with TextMetrics.tightBoundingRect, which reports the INK
        // rather than the layout box:
        //
        //   title  "H"             at em 15 -> cap 11px
        //   title  "Nothing playing" at em 15 -> ink 16px
        //   title  "Hxp"           at em 15 -> ink 15px
        //   glyph  play_arrow: em 13.8 -> 11px, 15 -> 12, 16 -> 12, 17 -> 13,
        //                       18 -> 14, 19 -> 15, 20 -> 15, 21 -> 16, 22 -> 17
        //
        // THE TARGET IS THE STRING, NOT THE CAPITAL. An earlier pass matched
        // the cap height (11px) and the mark still read as too small, twice.
        // That was the wrong measurement: a capital is the SHORTEST thing in
        // a line of text. The title has ascenders (h, l, t, the dot on i) and
        // descenders (g, y, p), so the letters the eye actually measures
        // against span 16px from the top of an ascender to the bottom of a
        // descender. 16px of ink is em 21.
        //
        // Nor can it be SOLVED rather than found. Scaling the measured ratio
        // (ink/em = 0.797 at em 13.8) predicts 16 / 0.797 = 20.1, which lands
        // on 15px -- a pixel short. The icon family carries an opsz axis, so
        // the em also changes the glyph's optical size and the ink does not
        // scale in proportion. Hence the sweep.
        //
        // Both the media button and the timer button take this default, so one
        // number moves the pair together and they cannot drift apart.
        //
        // 21 -> 20, a whole point down. The sweep put play_arrow's ink at 15px
        // for both em 19 and em 20 against 16px at 21, so 20 is the smallest
        // step that actually shows: one pixel of ink off the triangle, and
        // the song title it sits beside is 16px of real ink, so the mark no
        // longer quite matches the words. That was asked for; if the triangle
        // ever needs to be tall as the title again, this is the one number.
        property real glyphSize: 20
        // The glyph's own font, published so the probe measures the REAL thing.
        // `font` cannot be a property on an IpcHandler ("Type QFont cannot be
        // used across IPC"), so it is carried on the button and read there.
        // A bare `Qt.font()` copy is NOT equivalent: it loses the opsz variable
        // axis, and without opsz the family resolves at a different optical
        // size -- which is how the first attempt measured an impossible 13px of
        // ink for a 12px em.
        readonly property font glyphFont: glyphWidget.font
        // The FILL value the font is actually being handed, published for
        // the same reason `glyphFont` is: the "small triangle inside the
        // triangle" artefact is a FRACTIONAL fill, and the only way to prove
        // it cannot come back is to read the number the font receives rather
        // than trust that nothing is animating it.
        readonly property real glyphFill: glyphWidget.truncatedFill
        // `glyphWidget.truncatedFill` is the string from toFixed(1); Number()
        // so a fractional value would print as one instead of hiding.
        readonly property real glyphFillNum: Number(glyphWidget.truncatedFill)
        readonly property string glyphText: glyphWidget.text

        // Geometry in, looks out: the island hit-tests the pointer against
        // THIS rect (see inputArea.buttonAt), so the button's size is the
        // hit area and must not move while the pointer is being tested
        // against it.
        //
        // It used to be also why the visuals sat on an inner item -- that
        // inner item carried a Scale that swelled the pad to 1.15 on hover.
        // The swell is GONE. A control that grows when the pointer arrives
        // moves the thing you were reaching for, and on a 24px glyph sitting
        // on a busy bar the growth read as a flicker rather than a cue.
        // Hover now says one thing and one thing only: the border. The pad
        // is already a permanent control cue at rest, so it does not need to
        // swell to prove the button is there.
        Item {
            id: islandButtonVisual
            anchors.centerIn: parent
            width: parent.width
            height: parent.height
            readonly property bool drawnGlyph: islandButton.icon === "play_arrow"
                || islandButton.icon === "pause"

            // A rounded RECT, not a circle. `radius: width/2` on a square pad
            // makes a perfect disc, and next to the media view that disc read
            // as a stray light oval floating in the bar. A small corner radius
            // keeps the "this is a control" cue without putting a blob on the
            // island.
            Rectangle {
                id: islandButtonPad
                anchors.fill: parent
                radius: Appearance.rounding.small
                color: Appearance.colors.colLayer1Hover
                // Always something, low: at rest this used to be fully
                // invisible (opacity 0) with a `colOnLayer1Inactive` glyph on
                // top, so the play/pause on the island was a dim smudge you
                // had to already know was there -- the one control on the bar
                // people need first. A permanent low pad costs nothing
                // visually and makes it a control at a glance.
                //
                // Only the PRESS brightens it. Hover deliberately does not:
                // the ring below is the hover tell, and letting the fill
                // brighten at the same time was half of what made the button
                // look like it was inflating under the pointer.
                opacity: islandButton.pressState ? 1 : 0.32
                Behavior on opacity {
                    NumberAnimation { duration: 110 }
                }
            }
            // The hover ring. This is now the ONLY thing hover changes about
            // the button's body -- no growth, no fill swell -- so it has to
            // carry the whole cue. It was 0.16 before, which on a busy bar you
            // could easily miss; at 0.55 in the accent colour it reads.
            Rectangle {
                anchors.fill: parent
                radius: Appearance.rounding.small
                color: "transparent"
                border.width: 1
                // Accent on hover, matching the glyph's own hover colour, so
                // the outline and the glyph read as one gesture rather than
                // two unrelated highlights.
                border.color: (islandButton.hoverState || islandButton.pressState)
                    ? Appearance.colors.colPrimary
                    : Appearance.colors.colOnLayer0
                // THE hover tell, and the only one: no scale, no fill change.
                // Press keeps a brighter ring than hover so a held press still
                // reads as harder than a pass-over.
                opacity: islandButton.hoverState ? 0.55 : (islandButton.pressState ? 0.8 : 0)
                Behavior on opacity {
                    NumberAnimation { duration: 110 }
                }
            }
            // THE GLYPH IS THE FONT, and that is a decision rather than a
            // retreat.
            //
            // The drawn version (a ShapePath triangle with an even-odd hole)
            // was correct every time it was asked: 19 path nodes, fill
            // #e2e2e2, visible true, scale 1.0, sitting in a 16px slot that
            // the island had plainly reserved space for. And NOTHING painted.
            // The pad and the hover ring in the same Item drew; the tab
            // chevrons either side of this button, which are MaterialSymbols,
            // drew. Only the Shape did not -- under either renderer, at 1x and
            // at 8x. So QtQuick.Shapes is not painting on this setup, and any
            // geometry approach would fail here for the same reason.
            //
            // The font cannot fail that way, and at this size it is the
            // better-looking option anyway: it is hinted, where a 1.5px ring
            // cannot be.
            //
            // `fill` is a VARIABLE-FONT AXIS (FILL 0..1). The original bug on
            // this island was asking it for 0.75 -- a value BETWEEN the axis's
            // two real stops, which the font interpolates into a hollow
            // triangle with a smaller solid triangle inside it. 0 and 1 are
            // the only real glyphs: a clean empty outline at rest, closing to
            // solid on hover. Whole numbers only, always.
            MaterialSymbol {
                id: glyphWidget
                anchors.centerIn: parent
                text: islandButton.icon
                iconSize: islandButton.glyphSize
                fill: islandButton.hoverState || islandButton.pressState ? 1 : 0
                // Pause is drawn as its own pair of pill bars below -- the
                // user wants those two rectangles thinner and rounder than
                // the font glyph offers. Everything else keeps the font.
                visible: islandButton.icon !== "pause"
                // `colOnLayer0` rather than `colOnLayer1Inactive`: the inactive
                // ink made the transport read as disabled when it was merely
                // idle, and this is the one control people need first.
                color: islandButton.hoverState
                    ? Appearance.colors.colPrimary
                    : Appearance.colors.colOnLayer0
                // Pressing dips the glyph; hovering does NOT scale it. These
                // are natively rendered glyphs, so a scale transform smears
                // the raster -- the same blur the bar's icons had.
                scale: islandButton.pressState ? 0.82 : 1
                Behavior on scale {
                    NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
                }
            }
            // The drawn pause: the same two pill bars the expanded card's
            // transport uses, with the SAME outline->solid language as the
            // play triangle -- hollow 1.7px strokes at rest, filling to solid
            // accent on hover/press, exactly what the font's FILL axis does
            // for every other glyph here. PLAIN RECTANGLES, deliberately: the
            // island's history with ShapePath is that it does not paint on
            // this setup (see the play triangle's story above); Rectangles are
            // core QtQuick and proven all over the shell.
            Item {
                anchors.centerIn: parent
                width: 13
                height: 13
                visible: islandButton.icon === "pause"
                scale: islandButton.pressState ? 0.82 : 1
                Behavior on scale {
                    NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
                }
                Rectangle {
                    width: 5; height: 13; radius: 2.5
                    anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                    color: islandButton.hoverState || islandButton.pressState
                        ? Appearance.colors.colPrimary : "transparent"
                    border.width: 1.7
                    border.color: islandButton.hoverState || islandButton.pressState
                        ? Appearance.colors.colPrimary
                        : Appearance.colors.colOnLayer0
                    Behavior on color { ColorAnimation { duration: 110 } }
                    Behavior on border.color { ColorAnimation { duration: 110 } }
                }
                Rectangle {
                    width: 5; height: 13; radius: 2.5
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    color: islandButton.hoverState || islandButton.pressState
                        ? Appearance.colors.colPrimary : "transparent"
                    border.width: 1.7
                    border.color: islandButton.hoverState || islandButton.pressState
                        ? Appearance.colors.colPrimary
                        : Appearance.colors.colOnLayer0
                    Behavior on color { ColorAnimation { duration: 110 } }
                    Behavior on border.color { ColorAnimation { duration: 110 } }
                }
            }
        }

    }

    Row {
        id: tabTicks
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 2
        spacing: 4
        // Gone until a swipe, back for the hint window, then away: the row
        // rides the SHARED hint flag (GlobalStates.nowBarTickHint), which
        // fires on any view change from any surface -- island, card or
        // pocket -- so a card-driven swap still reveals the island's ticks.
        visible: opacity > 0.01
        opacity: GlobalStates.nowBarTickHint ? 1 : 0
        Behavior on opacity {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
        }

        Repeater {
            model: root.modeCount

            Rectangle {
                required property int index
                readonly property bool active: root.mode === index
                anchors.verticalCenter: parent.verticalCenter
                width: active ? 15 : 7
                height: 2.5
                radius: 1.25
                color: active
                    ? Appearance.colors.colPrimary
                    : ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.7)
                opacity: active ? 0.95 : (root.swapHint ? 0.62 : 0.38)
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

    // The machine's numbers are only sampled while they are on screen: this
    // mode, or the popped-out panel (which sets the flag for itself).
    Binding {
        target: SystemNow
        property: "active"
        value: root.perfVisible || GlobalStates.nowBarPanelOpen
    }

    // The popped-out panel drives the SAME view: its tabs and swipes write
    // GlobalStates.nowBarMode, and the island follows, so the card above and
    // the island under it can never disagree. (The reverse direction is the
    // onModeChanged publish above -- writing back the identical value, so this
    // never loops.)
    Connections {
        target: GlobalStates
        function onNowBarModeChanged() {
            if (GlobalStates.nowBarPanelOpen && root.mode !== GlobalStates.nowBarMode)
                root.setMode(GlobalStates.nowBarMode);
        }
    }

    // The ink measurement needs a TextMetrics, and an IpcHandler has NO
    // default property (nesting one inside it is a hard load failure), so it
    // lives here on the root.
    TextMetrics {
        id: inkMetrics
    }

    // The song label's own metrics, for the one question the label cannot
    // answer about itself: would "Song · Artist" fit whole? Asked with the
    // label's font OBJECT, so the answer is the width that label is actually
    // going to paint rather than an estimate from a lookalike font. Ids are
    // file-wide, so this can live here while the label it measures sits inside
    // the media view; and, like inkMetrics, it must not be nested inside the
    // IpcHandler, which has no default property.
    TextMetrics {
        id: titleMetrics
        font: mediaTitle.font
        // The PAIR, so `advanceWidth` is the width of "Song · Artist" as the
        // label would paint it. When the artist is dropped the label paints the
        // song alone, and that width is the label's own `implicitWidth`.
        text: mediaView.title + mediaView.artistSuffix
    }

    // The fill-axis regression test's second sample, and it is a SIBLING of
    // the TextMetrics above rather than a child of it: TextMetrics has no
    // default property either, so a Timer nested in one is the same hard load
    // failure ("Cannot assign to non-existent default property"), which is
    // exactly how it failed the first time.
    Timer {
        id: fillShoot
        interval: 140
        onTriggered: {
            print("[nowbar.probe] fill axis: at hover " + root.fillProbeNow
                + " | at +140ms " + mediaPlayButton.glyphFillNum
                + " | hoverState " + mediaPlayButton.hoverState);
            mediaPlayButton.hoverState = false;
        }
    }

    IpcHandler {
        target: "nowbar"

        function mode(m: string): void {
            root.setMode(Math.max(0, Math.min(root.modeCount - 1, Number(m))));
        }
        function next(): void { root.next(); }
        function prev(): void { root.prev(); }
        // Horizontal 2/3-finger swipes land here: they are registered as
        // Hyprland gestures in custom/general.lua (the compositor owns
        // libinput; layer surfaces never see them) and dispatched into this
        // shell exactly like the panel toggle.
        function modeNext(): void { root.next(); }
        // Pins the skip arrows' hover look (ring + filled glyph) on, so it
        // can be looked at without chasing the pointer. `off` restores
        // hover-only, and it also times out on its own -- see
        // skipRingTimer, because a forgotten hold looks exactly like a
        // broken hover.
        function skipRing(arg: string): void {
            root.skipRingHold = (arg ?? "") !== "off";
            if (root.skipRingHold)
                skipRingTimer.restart();
            else
                skipRingTimer.stop();
        }
        // Flips which clock the timer tab reads out, from the keyboard.
        //
        // The mark at the island's edge does this on a click, and a click is
        // something neither a script nor a screenshot can perform on a layer
        // surface -- the island's pixels are not in any framebuffer the tools
        // here can read, and an absolute pointer move pins to the screen
        // corner. So the one piece of this feature that could not otherwise be
        // exercised at all gets a switch, exactly like skipRing above.
        //   qs -c ii ipc call nowbar stopwatch   -> read the stopwatch
        //   qs -c ii ipc call nowbar stopwatch p -> back to the pomodoro
        function stopwatch(arg: string): void {
            root.stopwatchMode = (arg ?? "") === "p" ? false : !root.stopwatchMode;
        }
        function tapTest(): void { root.backgroundTap(); }
        function modePrev(): void { root.prev(); }
        // Pop the island out (or put it back). The panel keeps its own state in
        // GlobalStates so the gesture, the IPC and the escape key all agree.
        function panel(open: string): void {
            GlobalStates.nowBarPanelOpen = (open === "" || open === undefined)
                ? !GlobalStates.nowBarPanelOpen
                : (open === "true" || open === "1");
        }
        // Reports the transport glyph's real geometry against the song title's
        // box. Both Items anchor to `parent.verticalCenter`, so their BOXES
        // always agree and reading the source tells you nothing; what can be
        // off is the optical centre, and that needs numbers. Not a debug
        // leftover: this is how `triDrop` gets tuned.
        // (The first sample of the fill-axis test is parked on `root`, not
        // here: an IpcHandler declares no usable properties -- a `property
        // real` on one is parsed as a signal and assigning it fails with
        // "Cannot assign to non-existent property", which kills the whole
        // probe before its first print.)

        function probe(): void {
            // THE fill-axis test. Force the transport button's hover on and
            // read the value the font is being handed, immediately and again
            // 140ms later. With the `Behavior on fill` in MaterialSymbol, the
            // first sample was already fractional (0.0 -> 0.2 -> ... -> 1.0),
            // and every one of those is a glyph the font does not have: a
            // hollow triangle with a smaller solid one nested inside it. The
            // axis is two-stop, so the only correct readings are 0 and 1.
            mediaPlayButton.hoverState = true;
            root.fillProbeNow = mediaPlayButton.glyphFillNum;
            fillShoot.restart();
            print("[nowbar.probe] fill axis: at rest "
                + "0 | forced hover " + mediaPlayButton.glyphFillNum
                + " (want exactly 1, never a fraction)");
            // Locals, not properties of this handler: an IpcHandler parses
            // every function it holds, and a parameter typed "item" or
            // "QVariant" cannot cross that boundary ("Type of argument 1
            // cannot be used across IPC"). Inside the function body nothing
            // is parsed, so the helpers live here.
            const nameOf = b => !b ? "islandBody"
                : b === mediaPlayButton ? "mediaPlayButton"
                : b === pomoPlayButton ? "pomoPlayButton"
                : b === pomoResetButton ? "pomoResetButton"
                : b === pomoStopwatch ? "pomoStopwatch"
                : b === skipPrev ? "skipPrev"
                : b === skipNext ? "skipNext"
                : "unknown";
            // A control's own centre in the coordinates buttonAt expects.
            const centreIn = it => {
                const p = it.mapToItem(inputArea, it.width / 2, it.height / 2);
                return [p.x, p.y];
            };
            const b = mediaPlayButton;
            const t = mediaTitle;
            const bb = b.mapToItem(null, 0, 0);
            const bt = t.mapToItem(null, 0, 0);
            print("[nowbar.probe] buttonBox y " + bb.y.toFixed(2)
                + " h " + b.height.toFixed(2)
                + " centre " + (bb.y + b.height / 2).toFixed(2)
                + " | titleBox y " + bt.y.toFixed(2)
                + " h " + t.height.toFixed(2)
                + " centre " + (bt.y + t.height / 2).toFixed(2)
                + " | delta " + (bb.y + b.height / 2 - (bt.y + t.height / 2)).toFixed(2)
                + " | icon " + b.icon
                + " | glyph " + b.glyphSize.toFixed(1));

            // MEASURED, not guessed. "Make the triangle as tall as the song
            // name" is not one number: font.pixelSize is the EM, and the ink
            // inside it is only part of that. For a Material Symbol the ink is
            // roughly 60-70% of the em (the glyphs are drawn on a padded grid),
            // while for the title the ink is the CAP height, about 71% of its
            // em. So matching the two EM sizes would make the triangle visibly
            // SHORTER than the text, which is the opposite of what is wanted.
            //
            // TextMetrics.tightBoundingRect is the one reading that answers it
            // directly: it is the ink, not the layout box. The title is
            // measured on a capital with no descender, so what it reports is
            // the cap height the eye actually compares against.
            //
            // `font.capHeight` and `font.ascent` were tried first and are
            // `undefined` in this Qt build, which is why this exists.
            function ink(text, font) {
                const m = inkMetrics;
                m.text = text;
                m.font = font;
                return m.tightBoundingRect.height;
            }
            // The glyph's own font, taken from the widget that renders it, so
            // family, size and the opsz axis are all the real ones.
            const titleCap = ink("H", t.font);
            // The FULL ink of the string actually on screen, and of a
            // representative string with both an ascender and a descender.
            // This is the height the eye compares the mark against -- not the
            // cap height, which is only the capitals.
            const titleInkReal = ink(t.text, t.font);
            const titleInkRef = ink("Hxp", t.font);
            const glyphInk = ink(b.glyphText, b.glyphFont);
            print("[nowbar.probe] titleCap " + titleCap.toFixed(2)
                + " | glyphInk " + glyphInk.toFixed(2)
                + " | glyphEm " + b.glyphSize.toFixed(1)
                + " | titleEm " + t.font.pixelSize
                + " | inkRatio " + (glyphInk / b.glyphSize).toFixed(3)
                + " | capRatio " + (titleCap / t.font.pixelSize).toFixed(3)
                // The em size that would make the glyph's ink equal the cap.
                + " | emForMatch " + (titleCap * b.glyphSize / glyphInk).toFixed(2));
            print("[nowbar.probe] titleInkReal " + titleInkReal.toFixed(2)
                + " (" + t.text + ")"
                + " | titleInkRef " + titleInkRef.toFixed(2)
                + " | titleBoxH " + t.height.toFixed(2));

            // A SWEEP, because the relationship is NOT linear: the icon family
            // carries an opsz axis, so growing the em also changes the glyph's
            // optical size and the ink does not scale in proportion. Scaling
            // the measured ratio predicts em 14.67, which is a pixel too TALL;
            // the em has to be FOUND, not solved. This is also the check that
            // `glyphSize` is still on the plateau if either font changes.
            // Clone the LIVE font and vary only the size. `Qt.font()` with no
            // arguments takes none here ("Insufficient arguments"), and a
            // hand-built font would drop the opsz axis that makes this
            // relationship non-linear in the first place.
            const sw = [];
            for (const px of [13.8, 15, 16, 17, 18, 19, 20, 21, 22]) {
                const f = Qt.font(b.glyphFont);
                f.pixelSize = px;
                sw.push(px + ":" + ink("play_arrow", f).toFixed(1));
            }
            print("[nowbar.probe] sweep(em:ink) " + sw.join(" "));

            // The bar in front of the chevron has to be the chevron's own
            // weight, or the pair reads as two different drawings. Ink box of
            // the arrow (not its em, not its layout box) at the em the island
            // wears, so the bar can be cut to it.
            const cf = Qt.font(b.glyphFont);
            cf.pixelSize = skipPrev.em;
            inkMetrics.text = skipPrev.glyph;
            inkMetrics.font = cf;
            const cb = inkMetrics.tightBoundingRect;
            // The card's transport pair, at the sizes it uses them. Two
            // buttons that are supposed to match, measured rather than
            // eyeballed: 42px play next to a 38px reset, with glyphs at 24
            // and 20. If their INK differs, the row reads as two different
            // controls no matter how the boxes are arranged -- so this is
            // what decides the reset glyph's em, not taste.
            const cardGlyphs = [];
            for (const [name, px] of [["play_arrow", 24], ["restart_alt", 20],
                ["restart_alt", 22], ["restart_alt", 24], ["restart_alt", 26]]) {
                const gf = Qt.font(b.glyphFont);
                gf.pixelSize = px;
                const gm = inkMetrics;
                gm.text = name;
                gm.font = gf;
                const gb = gm.tightBoundingRect;
                cardGlyphs.push(name + "@" + px + ":"
                    + gb.width.toFixed(1) + "x" + gb.height.toFixed(1));
            }
            print("[nowbar.probe] cardGlyphs " + cardGlyphs.join("  "));

            // Every candidate for the skip mark, at the em the arrows wear,
            // measured with the SAME TextMetrics and the SAME font object the
            // mark is drawn with. Nothing here can be measured in a browser:
            // a canvas picks a different instance of this variable font than
            // Qt does (Chromium reported the chevron at 0.48 em tall where
            // this widget draws it at 0.75), so a preview's numbers and the
            // island's numbers are not the same numbers. These are.
            const skipCands = [];
            for (const n of ["chevron_left", "chevron_right", "skip_previous",
                "skip_next", "fast_rewind", "fast_forward",
                "keyboard_double_arrow_left", "keyboard_double_arrow_right",
                "play_arrow"]) {
                // Measured with the transport button's font, NOT the mark's own. That is a
            // known and reported difference, not an oversight: the mark is
            // drawn with a font carrying the opsz axis, and this table's font
            // does not, so the table reads skip_previous at 12.0x16.0 where
            // the mark itself measures 10.0x15.0 (printed alongside it as
            // `ink`). Every candidate in the table uses the SAME font, so the
            // comparison between them holds; only the absolute numbers differ.
            // A `font`-typed property was tried here to reach the real font
            // and it made the whole probe throw and print NOTHING -- the
            // handler swallows a ReferenceError without a word.
            const nf = Qt.font(b.glyphFont);
                nf.pixelSize = skipPrev.em;
                const nm = inkMetrics;
                nm.text = n;
                nm.font = nf;
                const nb = nm.tightBoundingRect;
                skipCands.push(n + ":" + nb.width.toFixed(1) + "x"
                    + nb.height.toFixed(1));
            }
            print("[nowbar.probe] skipCands@" + skipPrev.em + " "
                + skipCands.join("  "));

            print("[nowbar.probe] chevron em " + skipPrev.em
                + " ink " + cb.width.toFixed(1) + "x" + cb.height.toFixed(1)
                + " box " + skipPrev.width.toFixed(1)
                + "x" + skipPrev.height.toFixed(1)
                + " | play_arrow ink "
                + ink("play_arrow", cf).toFixed(1) + " tall");

            // Arrow geometry, so "at the edge of the island" is a measurement.
            // mapToItem(null) puts all three in the island's own coordinates.
            const row = mediaRow.mapToItem(null, 0, 0);
            const pv = skipPrev.mapToItem(null, 0, 0);
            const nx = skipNext.mapToItem(null, 0, 0);
            const blk = mediaBlock.mapToItem(null, 0, 0);
            const btn = mediaPlayButton.mapToItem(null, 0, 0);
            print("[nowbar.probe] row x " + row.x.toFixed(1) + " w " + mediaRow.width.toFixed(1)
                + " | prev x " + pv.x.toFixed(1) + " w " + skipPrev.width.toFixed(1)
                + " | next x " + nx.x.toFixed(1) + " w " + skipNext.width.toFixed(1)
                + " | block x " + blk.x.toFixed(1) + " w " + mediaBlock.width.toFixed(1)
                + " meterSpan " + mediaBlock.meterSpan.toFixed(1)
                + " meterDrawn " + mediaSoundbar.visible
                + " audio " + root.audioPlaying
                + " | title x " + t.mapToItem(null, 0, 0).x.toFixed(1)
                + " text [" + t.text + "]"
                + " recalled [" + root.lastTrackText + "]"
                + " shownW " + t.implicitWidth.toFixed(1)
                + " pairW " + titleMetrics.advanceWidth.toFixed(1)
                + " cap " + mediaView.titleMaxW + "/" + mediaView.pairMaxW
                + " artistFits " + mediaView.artistFits
                + " elided " + t.truncated
                + " | btn x " + btn.x.toFixed(1) + " w " + mediaPlayButton.width.toFixed(1));
            // Gaps measured against the ISLAND, in the ISLAND's coordinates.
            // Two mistakes lived here for several rounds, both worth writing
            // down: measuring against the ROW (flush with the row, 85px from
            // the border), and mixing `mapToItem(null)` -- which lands in
            // WINDOW coordinates, x 620 and up -- with root.width, which is
            // 0..360. Both together printed a confident, meaningless zero.
            const apR = skipPrev.mapToItem(root, 0, 0);
            const anR = skipNext.mapToItem(root, 0, 0);
            // INSIDE the row, which is the arrows' own parent. Anything mapped
            // further up crosses the FadeView, and an inactive view is scaled
            // to 0.94 -- so a mapped x comes back shrunk while the width read
            // beside it is the real 360, and the subtraction is off by ~21px
            // of pure measurement error. It read as "the right arrow is 19.6px
            // inside the row" on a perfectly flush layout.
            const pvW = skipPrev.mapToItem(mediaRow, 0, 0);
            const edgePt = skipPrev.mapToItem(inputArea, 0, 0);
            const nxW = skipNext.mapToItem(mediaRow, 0, 0);
            const blkW = mediaBlock.mapToItem(mediaRow, 0, 0);
            const btnW = mediaPlayButton.mapToItem(mediaRow, 0, 0);

            // VERTICAL alignment of the three things in the music row. BOXES, not
            // ink: `TextMetrics.tightBoundingRect.y` is measured from the
            // BASELINE, so an "ink centre" built from it lands a whole line
            // box out -- which is exactly the error that put the arrows off
            // the bottom of the island, and the reason this comparison reads
            // boxes. `inkFromBaseline` is printed alongside so the baseline
            // origin is visible rather than rediscovered.
            const tAt = mediaTitle.mapToItem(mediaRow, 0, 0);
            const titleBoxMid = tAt.y + mediaTitle.height / 2;
            const arrowBoxMid = pvW.y + skipPrev.height / 2;
            const btnMid = btnW.y + mediaPlayButton.height / 2;
            print("[nowbar.probe] vertical: arrowBox "
                + arrowBoxMid.toFixed(2)
                + " | titleBox " + titleBoxMid.toFixed(2)
                + " | playBtn " + btnMid.toFixed(2)
                + " | arrow-title " + (arrowBoxMid - titleBoxMid).toFixed(2)
                + " | btn-title " + (btnMid - titleBoxMid).toFixed(2)
                + " | rowH " + mediaRow.height.toFixed(2)
                + " arrowH " + skipPrev.height.toFixed(2)
                + " lineH " + skipPrev.lineHeight.toFixed(2)
                + " inkFromBaseline " + skipPrev.inkFromBaseline.toFixed(2));
            // The timer tab, measured the same way as the media row: is the
            // countdown really in the middle, and is the reset honest about
            // having nothing to do? In the row's OWN space, for the scale
            // reason above.
            const pt = pomoTime.mapToItem(pomoRow, 0, 0);
            print("[nowbar.probe] pomo row w " + pomoRow.width.toFixed(2)
                + " | timeX " + pt.x.toFixed(2)
                + " timeW " + pomoTime.width.toFixed(2)
                + " implicitW " + pomoTime.implicitWidth.toFixed(2)
                + " | timeCentre " + (pt.x + pomoTime.width / 2).toFixed(2)
                + " vs rowCentre " + (pomoRow.width / 2).toFixed(2)
                // The two gaps that matter, in the row's own space: each
                // button's edge to the countdown's edge. They are the whole
                // layout, and printing them catches the exact failure that
                // shipped once -- the row was 77px wide with a 48px time
                // centred inside it, so the number overlapped BOTH buttons
                // and the gaps read NEGATIVE.
                + " | gapL " + (pt.x - pomoResetButton.x - pomoResetButton.width).toFixed(1)
                + " gapR " + (pomoPlayButton.x - (pt.x + pomoTime.width)).toFixed(1)
                + " labelGap " + (pomoLabel.x - (pt.x + pomoTime.width)).toFixed(1)
                + " playGap " + (pomoPlayButton.x - (pomoLabel.x + pomoLabel.width)).toFixed(1)
                + " label " + pomoLabel.width.toFixed(1)
                // canReset is gone with the dimming it drove. The NAME is printed and
                // not just the yes/no: "the reset is not hit" is a much worse
                // bug report than "something else is sitting on top of the
                // reset", and the first version of this line could only say
                // the first thing.
                + " hitReset " + nameOf(inputArea.buttonAt(
                    ...centreIn(pomoResetButton)))
                + " hitPlay " + nameOf(inputArea.buttonAt(
                    ...centreIn(pomoPlayButton)))
                // Both transport buttons, side by side: same component, so
                // same pad, same em, same ring. Printed because "the reset
                // should hover like the play button" is only true if they
                // really are the same size, and reading the source does not
                // prove that.
                + " | play " + pomoPlayButton.width.toFixed(0)
                + "x" + pomoPlayButton.height.toFixed(0)
                + "@" + pomoPlayButton.glyphSize.toFixed(0)
                + " reset " + pomoResetButton.width.toFixed(0)
                + "x" + pomoResetButton.height.toFixed(0)
                + "@" + pomoResetButton.glyphSize.toFixed(0)
                + " running " + TimerService.pomodoroRunning
                + " left " + TimerService.pomodoroSecondsLeft
                + "/" + TimerService.pomodoroLapDuration
                + " | showing " + (root.stopwatchMode ? "stopwatch" : "pomodoro")
                + " swText " + pomodoroView.stopwatchText
                + " swRun " + TimerService.stopwatchRunning
                + " swT " + TimerService.stopwatchTime
                // The service's stopwatch methods EXIST. A TypeError inside an
                // onTriggered handler is swallowed without a word -- the
                // button simply does nothing -- and the reset button here
                // called `resetStopwatch()` for a while, because the real
                // name is `stopwatchReset()`. The island looked perfect in
                // every probe and the button was dead. Two typeofs, printed
                // on every probe, so the next typo is a line in the log
                // instead of a dead control you have to click to find.
                + " | api swReset:" + (typeof TimerService.stopwatchReset)
                + " swToggle:" + (typeof TimerService.toggleStopwatch));

            // The stopwatch mark at the edge, in ITS OWN VIEW's coordinates.
            // Not mapToItem(null): the view sits at scale 0.94 unless it is
            // the live one, and a scaled x measured against an unscaled width
            // is how this probe produced nonsense once already.
            const swMark = pomoStopwatch.mapToItem(pomodoroView, 0, 0);
            const swInkL = swMark.x + pomoStopwatch.hitPad;
            const swInkR = swInkL + pomoStopwatch.em;
            const swClusterR = pomoRow.x + pomoPlayButton.x
                + pomoPlayButton.width;
            // Is the `timer` ligature real, or is the font handing back the
            // literal word? A resolved ligature is one em of ink; the word is
            // roughly 2.5x that, and an icon that is quietly the word "timer"
            // at 20px is a very confusing thing to find in an island.
            const swf = Qt.font(b.glyphFont);
            swf.pixelSize = pomoStopwatch.em;
            inkMetrics.text = "timer";
            inkMetrics.font = swf;
            const swb = inkMetrics.tightBoundingRect;
            print("[nowbar.probe] stopwatch mark: view w "
                + pomodoroView.width.toFixed(1)
                + " box " + pomoStopwatch.width.toFixed(0)
                + "x" + pomoStopwatch.height.toFixed(0)
                + " at x " + swMark.x.toFixed(1)
                + " | ink " + swInkL.toFixed(1) + ".." + swInkR.toFixed(1)
                + " edgeGap " + (pomodoroView.width - swInkR).toFixed(1)
                + " | clear of cluster " + (swInkL - swClusterR).toFixed(1)
                + " | ring " + pomoStopwatch.ringSize.toFixed(0)
                + " op " + pomoStopwatch.opacity.toFixed(2)
                + " active " + pomoStopwatch.active
                + " hit " + (inputArea.buttonAt(
                    ...centreIn(pomoStopwatch)) === pomoStopwatch)
                + " | timer@" + pomoStopwatch.em + " ink "
                + swb.width.toFixed(1) + "x" + swb.height.toFixed(1)
                + " (one em wide means the ligature resolved)");

            print("[nowbar.probe] island w " + root.width.toFixed(1)
                + " row w " + mediaRow.width.toFixed(1)
                + " | mediaOn " + mediaView.on
                + " viewScale " + mediaView.scale.toFixed(2)
                + " | edgeGapL(row) " + pvW.x.toFixed(2)
                + " edgeGapR(row) " + (mediaRow.width
                    - (nxW.x + skipNext.width)).toFixed(2)
                + " | edgeGapL(island) " + apR.x.toFixed(2)
                + " edgeGapR(island) "
                + (root.width - (anR.x + skipNext.width)).toFixed(2)
                // The INK's inset, which is what the eye judges. The boxes
                // above are flush by design -- `edgeGap` of the box is the
                // hit area -- so they cannot answer "is it glued to the
                // side".
                + " | markInsetL " + skipPrev.edgeGap.toFixed(2)
                + " markInsetR " + skipNext.edgeGap.toFixed(2)
                // The ring's box next to the transport button's, and the
                // margins the ring leaves around the mark -- which are NOT
                // equal on the axes now that the ring is the button's square.
                + " | ring " + skipPrev.ringSize.toFixed(1)
                + "x" + skipPrev.ringSize.toFixed(1)
                + " (play button " + b.width.toFixed(1)
                + "x" + b.height.toFixed(1) + ")"
                + " | margins side " + ((skipPrev.ringSize - skipPrev.artWidth) / 2).toFixed(1)
                + " top " + ((skipPrev.ringSize - ink("chevron_left", cf)) / 2).toFixed(1)
                + " hot " + skipPrev.hot + "/" + skipNext.hot
                // Is the mark CENTRED in its hover square, or only centred as a layout box?
                // The ink's position inside its advance is the whole question:
                // if it is 0, centring the box happened to be right; if it is
                // not, the box was centring the wrong rectangle by exactly
                // that much. The mark is positioned from the ink now, so this
                // number is what the centring is worth rather than what it
                // costs.
                + " | ink " + skipPrev.inkWidth.toFixed(1)
                + "x" + skipPrev.inkHeight.toFixed(1)
                + " advance " + skipPrev.advance.toFixed(1)
                + " artW " + skipPrev.artWidth.toFixed(2)
                // The FILL pin, reported so it cannot be undone unnoticed.
                + " markFill " + skipPrev.markFill
                // The cluster spans from the block's LEFT edge to the
                // button's RIGHT edge, so its centre is the mean of those
                // two ends -- one division, not two. In the row's OWN space,
                // for the view-scale reason above.
                + " | clusterCentre " + (
                    (blkW.x + btnW.x + mediaPlayButton.width) / 2
                ).toFixed(2)
                + " vs rowCentre " + (mediaRow.width / 2).toFixed(2)
                + " | arrowEm " + skipPrev.em
                + " glyph " + skipPrev.glyph
                + " inkOffCentreInAdvance "
                + skipPrev.inkOffsetInAdvance.toFixed(2)
                + " arrowOp " + skipPrev.opacity.toFixed(2)
                + "/" + skipNext.opacity.toFixed(2));

            // Why are the arrows not showing? Two candidate answers, and
            // they need different fixes: the pointer never reaches the row
            // (hover wiring), or the row is hovered and the mark is still
            // invisible (geometry/paint). So print both halves.
            const ap = skipPrev.mapToItem(null, 0, 0);
            const an = skipNext.mapToItem(null, 0, 0);
            print("[nowbar.probe] hover island=" + root.islandHovered
                // The slop, proved without a pointer: 1.5px past the arrow's
                // right edge is a MISS under the exact test and a HIT under
                // the slop, which is the whole mechanism -- a fast sweep that
                // clips the corner keeps the fill instead of strobing it.
                // (inputArea's own coordinates, so the point is nowhere near
                // any other control in the list.)
                + " | slop exact="
                + (inputArea.buttonAt(
                    edgePt.x + skipPrev.width + 1.5,
                    edgePt.y + skipPrev.height / 2) === skipPrev)
                + " withSlop="
                + inputArea.inside(skipPrev,
                    edgePt.x + skipPrev.width + 1.5,
                    edgePt.y + skipPrev.height / 2, inputArea.hoverSlop)
                + " armed=" + skipPrev.armed
                + " hotPrev=" + skipPrev.hoverState
                + " hotNext=" + skipNext.hoverState
                // The island's OWN hit test, fed each control's centre in the
                // island's coordinates -- the same buttonAt() a real press
                // goes through, minus the need for a pointer. If this does
                // not name the arrows, they are not clickable and not
                // hoverable no matter what they look like.
                + " | hitPrev=" + nameOf(inputArea.buttonAt(...centreIn(skipPrev)))
                + " hitNext=" + nameOf(inputArea.buttonAt(...centreIn(skipNext)))
                + " hitBody=" + nameOf(inputArea.buttonAt(...centreIn(mediaBlock)))
                + " | prev x" + ap.x.toFixed(1) + " y" + ap.y.toFixed(1)
                + " w" + skipPrev.width.toFixed(1) + " h" + skipPrev.height.toFixed(1)
                + " vis" + skipPrev.visible + " op" + skipPrev.opacity.toFixed(2)
                + " | next x" + an.x.toFixed(1) + " w" + skipNext.width.toFixed(1)
                + " h" + skipNext.height.toFixed(1)
                + " vis" + skipNext.visible + " op" + skipNext.opacity.toFixed(2));

            // Vertical alignment across the four views. Every view declares
            // implicitHeight: root.height, but "declares" is not "is" -- a
            // view that is laid out by something else (a RowLayout, or its
            // own implicit size) lands at a different height per tab, which
            // is what the owner sees when they swipe from one tab to the
            // next. Everything below is in the island's own coordinates.
            const vs = [];
            for (const f of [perfView, mediaView, pomodoroView, aiView]) {
                // Own coordinates, not mapToItem: an inactive view is scaled
                // to 0.94, and mapToItem folds that scale into the point it
                // returns, so mixing a mapped y with an unscaled height
                // invents a centre that is not the item's.
                vs.push(f.viewIndex + ":y" + f.y.toFixed(2)
                    + "/h" + f.height.toFixed(2)
                    + "/c" + (f.y + f.height / 2).toFixed(2)
                    + "/s" + f.scale.toFixed(2)
                    + "/o" + f.opacity.toFixed(2));
            }
            const rows = [];
            for (const r of [perfRow, mediaRow, pomoRow, aiRow]) {
                rows.push(r.y.toFixed(2) + "/h" + r.height.toFixed(2)
                    + "/c" + (r.y + r.height / 2).toFixed(2));
            }
            print("[nowbar.probe] root y " + root.y.toFixed(2)
                + " h " + root.height.toFixed(2)
                + " stage y " + stage.y.toFixed(2)
                + " h " + stage.height.toFixed(2)
                + " | views(idx:y/h/centre/scale/op) " + vs.join(" "));
            print("[nowbar.probe] rowCentres perf " + rows[0]
                + " | media " + rows[1]
                + " | pomo " + rows[2]
                + " | ai " + rows[3]
                + " | stageCentre " + (stage.height / 2).toFixed(2));

        }
    }
}
