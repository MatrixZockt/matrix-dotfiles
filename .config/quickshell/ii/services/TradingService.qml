pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common

/**
 * The Trading tab's data.
 *
 * Two things the tab needs and nothing else does: a price SERIES to draw as
 * candles, and the DAY'S events to list as red-folder cards.
 *
 * ── Where the numbers come from ────────────────────────────────────────
 * Two answers, on purpose.
 *
 * The SERIES is local: the shell must start and draw with or without a
 * feed, and a service that fetched on construction would put a network
 * round-trip in the shell's own boot path. So the series is SEEDED locally
 * (a deterministic random walk per instrument, see reseed()) and then
 * ticked, which is what makes the chart move. A real quote feed is still
 * one function: write into `candles` / `price` / `openPrice`, bump `rev`,
 * and swap the tick Timer for the provider's cadence. Everything the views
 * read is already in the shape a quote API returns.
 *
 * The CALENDAR is fetched, on claim rather than on construction -- see the
 * events section below. An economic calendar typed into the source file is
 * a calendar that is wrong the moment the clock moves, so it is not a
 * fallback anybody should ever see.
 *
 * Cost: every Timer here only runs while a view CLAIMS the service (claim /
 * release, the same contract AudioVisualizer uses). A hidden tab costs
 * nothing -- there is no per-frame work anywhere in here.
 */
Singleton {
    id: root

    // ── Instruments ────────────────────────────────────────────────────
    // `seed`/`start`/`last` define the generated series; `step` is the size
    // of one tick, which is what keeps gold's wobble and the euro's fifth
    // decimal looking like the instruments they are.
    readonly property var instruments: [
        { sym: "XAU/USD", decimals: 2, step: 1.90,    seed: 11, start: 2631.10, last: 2648.40 },
        { sym: "EUR/USD", decimals: 5, step: 0.00042, seed: 22, start: 1.09580, last: 1.09124 },
        { sym: "GBP/USD", decimals: 5, step: 0.00055, seed: 33, start: 1.26890, last: 1.27358 },
        { sym: "BTC/USD", decimals: 0, step: 96,      seed: 44, start: 63980,   last: 63210 }
    ]
    property string symbol: "XAU/USD"
    readonly property var instrument: root.instruments.find(i => i.sym === root.symbol) ?? root.instruments[0]
    readonly property int decimals: root.instrument ? root.instrument.decimals : 2

    // ── Timeframes ─────────────────────────────────────────────────────
    // The chart is ONE walk, generated at 15-minute bars (see `base`), and
    // every timeframe is that walk ROLLED UP: 1H is four 15m bars, 4H is
    // sixteen, 1D is a trading day's ninety-six. So the buttons change the
    // GRANULARITY of the same data instead of drawing four unrelated walks
    // -- switch, switch back, and the candles are where you left them --
    // and the quote in the header cannot jump, because a roll-up preserves
    // the first open and the last close.
    readonly property var timeframes: [
        { tf: "15m", agg: 1 },
        { tf: "1H",  agg: 4 },
        { tf: "4H",  agg: 16 },
        { tf: "1D",  agg: 96 }
    ]
    property string timeframe: "15m"
    readonly property int tfAgg: (root.timeframes.find(t => t.tf === root.timeframe) ?? root.timeframes[0]).agg

    // ── The series ─────────────────────────────────────────────────────
    // `base` is the source series: 15-minute bars, oldest first, 56 daily
    // bars' worth. `candles` is the LAST 56 of those bars aggregated to the
    // selected timeframe -- what the chart draws. `rev` is bumped on every
    // write so a Canvas can repaint without diffing the array, which QML
    // cannot do for us.
    property var base: []
    property var candles: []
    property real price: 0
    property real openPrice: 0
    property int rev: 0
    readonly property real change: root.price - root.openPrice
    readonly property real changePct: root.openPrice > 0
        ? (root.price - root.openPrice) / root.openPrice * 100 : 0
    readonly property bool up: root.change >= 0

    // ── The day's calendar events, one per folder colour ───────────────
    //
    // FETCHED. Nothing in this list is authored any more.
    //
    // It used to be nine hand-typed entries carrying their times, their
    // countdowns and a "live" flag frozen into the source, and the card drew
    // them under a header that said "Red folder · today": rows that never
    // matched the clock, two of which were not even red-folder, under a
    // "today" that was whatever day the file happened to be written. A
    // calendar that is confidently wrong is worse than no calendar, so every
    // field the tab prints about an event is now DERIVED:
    //
    //   source   the community ForexFactory mirror -- the feed the design
    //            notes name, and the place the impact tiers the phrase
    //            "red folder" comes from actually live (High / Medium /
    //            Low / Holiday)
    //   filter   impact === "High" AND the release falls on TODAY in this
    //            machine's local zone. That filter is the whole of the
    //            header's claim
    //   states   recomputed from the clock every second while the tab is
    //            open, so "released" and the countdown cannot drift from it
    //   actual   the mirror publishes forecast and previous but NOT the
    //            released figure, so actuals come from a SECOND feed and
    //            only where both agree it is the same release -- same
    //            currency, same minute, same (or containing) title. Where
    //            they do not agree, `actual` stays "—": one event's number
    //            printed under another event's name is the one thing a
    //            calendar like this must never do
    //   compare  after the sort, each row gets `cmp` -- the release
    //            IMMEDIATELY BEFORE it in the list -- so the card can put
    //            today's earlier actual and forecast beside this one's
    //
    // `events` is only reassigned when the payload actually CHANGES (see
    // `_feedSig`): replacing the array rebuilds every delegate in the list,
    // and a card that collapses its own expansion once a minute looks like
    // it is glitching.
    property var events: []
    /** id -> { state: "upcoming" | "released", countdown: string | null } */
    property var eventStates: ({})

    // ── Which folders the list shows ───────────────────────────────────
    //
    // The four folder colours are the calendar's own convention -- red High,
    // orange Medium, yellow Low, and the grey/white of a Holiday or a
    // Non-Economic note -- and each one is a toggle (drawn in the tab's
    // header). The STATE lives here rather than in the tab, for the reason
    // every other piece of view state does: the tab is built per bar card and
    // this object is one, so a filter set on the card survives the card being
    // rebuilt -- and the IPC below can read and drive it, which is the only
    // way it can be checked from a script (the toggles are 18px targets in a
    // popover).
    //
    // Defaults: red and orange ON, yellow and grey OFF. Red is the tab's whole
    // reason to exist; orange is what was asked for and is the half a
    // High-only list hides (measured: the USD releases of a quiet day are
    // routinely all Medium, so "nothing on the calendar" was often really
    // "nothing HIGH"); yellow and grey are the noise floor -- available, off,
    // one click each.
    property bool showHigh: true
    property bool showMedium: true
    property bool showLow: false
    property bool showGrey: false

    // ── ...and the filter is REMEMBERED ─────────────────────────────────
    //
    // "Survives the card being rebuilt" is not the same as "survives": the
    // choice used to live only in this object, so it outlived the card and
    // nothing else -- close the shell, or log back in, and the filter was
    // back to its defaults, which reads as the tab forgetting what you asked
    // for. It is written to the shell's own state file instead
    // (modules/common/Persistent.qml -> states.json), the same place the
    // sidebar's tab and the music app's settings live, and read back on
    // load.
    //
    // TWO FUNCTIONS AND A GUARD, rather than binding the four properties to
    // the state file. A binding would be shorter, and it would be wrong:
    // QML DROPS a binding the first time something assigns the property, and
    // these four are assigned from three directions -- the header's toggles,
    // the IPC `folders` call, and this loader -- so the first toggle would
    // quietly detach the filter from the file it is supposed to be saved in.
    // The guard is what keeps the load from echoing back as a write.
    property bool _hydratingFilter: false

    function loadFolderFilter(): void {
        const t = Persistent.states.trading;
        root._hydratingFilter = true;
        root.showHigh = t.folderHigh;
        root.showMedium = t.folderMedium;
        root.showLow = t.folderLow;
        root.showGrey = t.folderGrey;
        root._hydratingFilter = false;
    }

    function saveFolderFilter(): void {
        if (root._hydratingFilter)
            return;
        const t = Persistent.states.trading;
        t.folderHigh = root.showHigh;
        t.folderMedium = root.showMedium;
        t.folderLow = root.showLow;
        t.folderGrey = root.showGrey;
    }

    // One handler per property, because QML has no "any of these changed":
    // every path that can move the filter lands in exactly one of them, the
    // toggles and the IPC call included.
    onShowHighChanged: root.saveFolderFilter()
    onShowMediumChanged: root.saveFolderFilter()
    onShowLowChanged: root.saveFolderFilter()
    onShowGreyChanged: root.saveFolderFilter()

    /**
     * The four folder colours, in the market's own order, as the header's
     * toggles read them: `key` is the impact bucket an event carries, `label`
     * is the word the header prints. The COLOURS are deliberately not here --
     * they are market semantics and live in the view (TradingTab.colorForImpact)
     * so the service stays theme-free.
     */
    readonly property var folders: [
        { key: "high",   label: "Red" },
        { key: "medium", label: "Orange" },
        { key: "low",    label: "Yellow" },
        { key: "grey",   label: "Grey" }
    ]

    /** The bucket a feed row's impact names. Unknown, blank and Holiday all
     *  land in `grey`: a row that cannot be named is still a row on the
     *  calendar, and the fourth folder is exactly where an unnamed one
     *  belongs -- the alternative (dropping it) is how the feed's own
     *  Non-Economic entries used to disappear without a trace. */
    function folderOf(raw) {
        const s = String(raw ?? "").trim().toLowerCase();
        if (s === "high") return "high";
        if (s === "medium") return "medium";
        if (s === "low") return "low";
        return "grey";
    }

    /** Whether the filter keeps an event, by its bucket. */
    function folderShown(key) {
        if (key === "high") return root.showHigh;
        if (key === "medium") return root.showMedium;
        if (key === "low") return root.showLow;
        return root.showGrey;
    }

    /** Flip one folder on/off -- what a header toggle calls. */
    function toggleFolder(key) {
        if (key === "high") root.showHigh = !root.showHigh;
        else if (key === "medium") root.showMedium = !root.showMedium;
        else if (key === "low") root.showLow = !root.showLow;
        else root.showGrey = !root.showGrey;
    }

    /** How many rows each bucket holds today, whether or not it is switched on. */
    function folderCounts() {
        const out = { high: 0, medium: 0, low: 0, grey: 0 };
        for (const e of root.events)
            out[e.impact] = (out[e.impact] ?? 0) + 1;
        return out;
    }
    /** Why the list is what it is: "idle" | "loading" | "ok" | "error". */
    property string feedState: "idle"
    readonly property string feedUrl: "https://nfs.faireconomy.media/ff_calendar_thisweek.json"
    property string _feedSig: ""
    property real _lastFetch: 0
    // The two payloads behind `events`: `_lastFF` is the list itself (the
    // mirror), `_tv` the released figures (the second feed). They arrive
    // independently -- the list must not wait for the actuals, and the
    // actuals re-apply the list when they land -- so both are kept.
    property var _lastFF: null
    property var _tv: []
    property bool _inFlight: false
    // No fetch before this instant. The mirror sits behind a rate limiter
    // (Cloudflare 429 with a Retry-After), so retrying on a fixed minute
    // while throttled only extends the penalty -- the answer to "asked too
    // often" is to wait exactly as long as it says.
    property real _nextFetchAt: 0

    // ── Which day the card is drawing ─────────────────────────────────
    // "" is the ACTIVE day: whatever today is when the filter runs, so the
    // card follows the clock across a date roll with no call of its own.
    // A "YYYY-MM-DD" token reverses the card to that date, set only by the
    // IPC `show(day)` below; `show("")` puts it back on the active day,
    // re-opening the fetch gates so the return is immediate rather than
    // whenever the three-minute clock next comes round.
    property string _shownDate: ""
    /** "today" while the card is on the active day, else the shown date. */
    readonly property string shownDay: root._shownDate === ""
        ? "today"
        : fmtT(root._shownDate);

    /** Normal cadence between refreshes: 3 minutes. */
    readonly property int refreshIntervalMs: 180000

    // ── Retrograde daylight-savings safe local-date (ISO, no time) ─────

    /** iso-local ::= "YYYY-MM-DD" → "YYYY-MM-DD". */
    function isoLocal(s: string): string { return s; }

    /** "2026-10-02" -> "2026-10-02". A real local-date token, or "". */
    function fmtT(s) {
        const d = new Date(s + "T12:00:00");
        return String(d.getFullYear()) + "-"
            + (d.getMonth() < 9 ? "0" : "") + String(d.getMonth() + 1) + "-"
            + (d.getDate() < 10 ? "0" : "") + String(d.getDate());
    }

    /**
     * The shown day as a local-noon Date, or now when the token is not a
     * date at all.
     *
     * Noon rather than midnight on purpose: a DST shift moves MIDNIGHT by
     * an hour, which can make the same calendar day compare as the day
     * before or after it, while noon sits safely on both sides of a
     * transition. `_applyFeed` reads the year/month/date off this to decide
     * which releases belong to the day the card is drawing.
     */
    function thr(date: string): Date {
        const d = new Date(date + "T12:00:00");
        return isNaN(d.getTime()) ? new Date() : d;
    }

    // The RELEASED figures get their own gate, because they have their own
    // deadline: a number that prints at 14:30 cannot wait for the list's
    // three-minute clock. See fetchActuals().
    property real _nextActualsAt: 0
    property bool _actualsInFlight: false
    /** Never closer than this between actuals-only pulls: 60 seconds. */
    readonly property int actualsIntervalMs: 60000
    /** Keep hunting for a figure this long after its release: 12 minutes. */
    readonly property int actualsHuntMs: 720000

    // HTTP: the XMLHttpRequest-inside-a-QtObject idiom from OnlineMusic /
    // Booru -- the pattern already proven to work under this shell's engine.
    QtObject {
        id: http
        function get(url, onOk, onFail, headers) {
            const xhr = new XMLHttpRequest();
            xhr.open("GET", url);
            // Optional request headers, set before send. Not decoration: the
            // released-figure endpoint 403s unless it is told which origin
            // is asking (measured -- every UA passes, no Origin fails).
            if (headers) {
                for (const k in headers)
                    xhr.setRequestHeader(k, headers[k]);
            }
            xhr.onreadystatechange = function() {
                if (xhr.readyState !== XMLHttpRequest.DONE)
                    return;
                if (xhr.status === 200) {
                    try { onOk(JSON.parse(xhr.responseText ?? "[]")); }
                    catch (e) { onFail("could not parse the response"); }
                } else {
                    // The limiter's own countdown, so the caller can obey
                    // it instead of hammering and being throttled longer.
                    const ra = Number(xhr.getResponseHeader("Retry-After"));
                    onFail(`HTTP ${xhr.status}`, xhr.status,
                        Number.isFinite(ra) && ra > 0 ? ra : 0);
                }
            };
            try { xhr.send(); } catch (e) { onFail("request could not be sent"); }
        }
    }

    /**
     * "2026-10-04T05:15:00-04:00" or "2026-10-04T12:15:00.000Z" -> epoch ms,
     * or NaN. Both feeds are accepted because they stamp time differently:
     * the mirror in the US/Eastern session the calendar is published in,
     * the second feed in UTC with milliseconds.
     *
     * Parsed by hand rather than with `new Date(string)`: the one part of
     * this that must not be approximated is the instant an event happens.
     * Epoch ms, rendered in the local zone for display, is the only
     * representation with no timezone opinion baked into it.
     */
    function _parseFeedDate(s) {
        const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?([Zz]|[+-]\d{2}:?\d{2})$/.exec(String(s ?? "").trim());
        if (!m)
            return NaN;
        let ms = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] ?? 0));
        const off = m[7];
        if (off !== "Z" && off !== "z") {
            // "-04:00" means the stamp sits four hours BEHIND UTC, so UTC is
            // the stamp plus four -- i.e. subtract a signed offset.
            const sign = off[0] === "-" ? -1 : 1;
            const oh = +off.slice(1, 3);
            const om = +(off.length === 6 ? off.slice(4, 6) : off.slice(3, 5));
            ms -= sign * (oh * 60 + om) * 60000;
        }
        return ms;
    }

    function _pad2(n) { return n < 10 ? "0" + n : String(n); }
    /** Local wall clock for an epoch ms -- the zone this shell runs in. */
    function _hhmm(ms) {
        const d = new Date(ms);
        return root._pad2(d.getHours()) + ":" + root._pad2(d.getMinutes());
    }
    /** Real time-to-go: "in 45s" / "in 24m" / "in 1h 24m". */
    function _countdown(ms) {
        const s = Math.max(0, Math.round(ms / 1000));
        if (s >= 86400)
            return `in ${Math.floor(s / 86400)}d ${Math.floor((s % 86400) / 3600)}h`;
        const h = Math.floor(s / 3600);
        const m = Math.floor((s % 3600) / 60);
        if (h > 0)
            return `in ${h}h ${m}m`;
        if (m > 0)
            return `in ${m}m`;
        return `in ${s}s`;
    }

    /**
     * A figure as a NUMBER, or NaN. "6.5%", "-41.7K" and "1.234" have to
     * compare with each other; "—", "n/a" and anything else the feeds
     * refuse to quantify has to stay unquantified -- read as zero, a
     * missing number would silently turn into a direction call.
     */
    function _num(v) {
        const s = String(v ?? "").trim().replace(/,/g, "");
        if (!s || s === "—")
            return NaN;
        const m = /^([+-]?\d+(?:\.\d+)?)\s*([KMB])?/i.exec(s);
        if (!m)
            return NaN;
        let n = parseFloat(m[1]);
        const suf = (m[2] ?? "").toUpperCase();
        if (suf === "K") n *= 1e3;
        else if (suf === "M") n *= 1e6;
        else if (suf === "B") n *= 1e9;
        return n;
    }

    /**
     * Which way the release leaned: the ACTUAL against the PREVIOUS figure
     * for the same indicator -- "up" / "down" / "".
     *
     * That comparison is the whole call: beat the last reading and the
     * number came in higher, miss it and lower, and a tie or a pair that
     * cannot be quantified says NOTHING -- the card then draws no arrow
     * rather than a guessed one. Direction of the price itself is the
     * market's business; this is only the figure's own sign.
     */
    function _bias(act, pv) {
        const a = root._num(act), p = root._num(pv);
        if (!isFinite(a) || !isFinite(p))
            return "";
        if (a > p) return "up";
        if (a < p) return "down";
        return "";
    }

    /**
     * How the released figure landed against its CONSENSUS -- "above",
     * "below", "inline", or "" when the pair cannot be quantified.
     *
     * `_bias` above is actual against the PREVIOUS reading ("did this
     * indicator go up?"); this is actual against the FORECAST ("did it come
     * in hotter than the market expected?"). They are two different
     * questions and the card needs both: the arrow beside the figure answers
     * the first, the verdict sentence below answers the second.
     */
    function _beat(act, fc) {
        const a = root._num(act), f = root._num(fc);
        if (!isFinite(a) || !isFinite(f))
            return "";
        if (a > f) return "above";
        if (a < f) return "below";
        return "inline";
    }

    /**
     * The releases for which a HIGHER figure is BAD for the currency.
     *
     * "Actual above forecast is good for the currency" is the rule for most
     * of a calendar -- a hotter GDP, CPI, retail sales or rate decision is
     * money moving IN -- which is why the exceptions are what has to be
     * listed rather than the rule. An unemployment series is the clear one:
     * more people out of work is a worse economy for that money, so a
     * figure ABOVE consensus is bearish and one BELOW is bullish, the
     * mirror image of everything around it in the list.
     *
     * Matched on the title rather than on an indicator id, because neither
     * feed carries one -- so the test is on the WORDS the feeds use, which
     * is also why the words are whole enough to be unambiguous: "unemployed
     * persons" still matches, while "employment change" (a hotter jobs
     * number, which IS good) does not, since the substring has to be
     * `unemployment`.
     */
    readonly property var invertedReleases: [
        "unemployment", "jobless claims", "claimant count"
    ]

    /** Whether a higher reading of this release is BAD for its currency. */
    function _inverts(name) {
        const s = String(name ?? "").toLowerCase();
        for (const w of root.invertedReleases) {
            if (s.indexOf(w) >= 0)
                return true;
        }
        return false;
    }

    /**
     * How the beat reads for the CURRENCY: true (good for it), false (bad),
     * or null when there is nothing to read -- no released figure, no
     * consensus, or the two exactly level.
     */
    function _favourable(name, beat) {
        if (beat !== "above" && beat !== "below")
            return null;
        const higher = beat === "above";
        return root._inverts(name) ? !higher : higher;
    }

    /**
     * The sentence the card prints when a release is opened: what the beat
     * means for that currency, in the calendar's own reading.
     *
     * Kept here beside `_detail` rather than in the view, because it is a
     * READ of the numbers and not a label on them -- the two feeds hand over
     * an actual and a consensus, and "is that good for the USD" is the
     * question the card exists to answer. The view only decides the COLOUR
     * (good / bad / neither), which is its own business.
     */
    function _verdict(currency, name, beat) {
        if (beat === "")
            return "";
        if (beat === "inline")
            return "Actual in line with forecast — no surprise for "
                + (currency === "—" ? "the currency" : currency) + ".";
        const higher = beat === "above";
        return `Actual ${higher ? "greater than" : "lower than"} forecast — `
            + `${root._favourable(name, beat) ? "good" : "bad"} for `
            + (currency === "—" ? "the currency" : currency) + ".";
    }

    /** A row's detail line: only the facts the feed actually carries. */
    function _detail(currency, fc, pv) {
        const bits = [];
        if (fc !== "—") bits.push(`consensus ${fc}`);
        if (pv !== "—") bits.push(`previous ${pv}`);
        return `High-impact ${currency} release, from today's calendar.`
            + (bits.length > 0
                ? ` ${bits.join(", ")}.`
                : ` Neither a consensus nor a prior figure is published for it.`);
    }

    /** Lowercased and stripped of punctuation -- the two feeds title the
     *  same release differently ("Core CPI m/m" vs "Core CPI (MoM)"), and
     *  the join below needs one form it can compare. */
    function _normTitle(s) {
        return String(s ?? "").toLowerCase().replace(/[^a-z0-9]/g, "");
    }

    /**
     * The released figure for ONE event, from the second feed, or "—".
     *
     * The mirror has the impact tiers and no actuals; the other feed has
     * actuals and impact tiers that do not survive being read off its API.
     * So they are joined the only way that is safe: SAME currency, the same
     * MINUTE (±10), and a title that is either identical to this one or
     * wholly contained in it -- and if two candidates inside that window
     * carry DIFFERENT figures, the answer is "—", because at least one of
     * them is a different release. An exact-title hit always wins over a
     * containing one: "Inflation Rate" is answered by the row named
     * exactly that even while "Core Inflation Rate" and "Inflation Rate
     * Mom" sit in the same window disagreeing with each other -- a clash
     * among NEIGHBOURING titles only decides the question when there is no
     * exact answer to decide it.
     */
    function _actualFor(cur, at, name) {
        const mine = root._normTitle(name);
        if (!mine || root._tv.length === 0)
            return "—";
        let exact = null, contained = null, exactClash = false, containedClash = false;
        for (const e of root._tv) {
            if (String(e.currency ?? "").trim().toUpperCase() !== cur)
                continue;
            const t = root._parseFeedDate(e.date);
            if (isNaN(t) || Math.abs(t - at) > 600000)  // 10 minutes
                continue;
            const val = String(e.actual ?? "").trim();
            if (!val)
                continue;                       // not printed yet
            const other = root._normTitle(e.indicator);
            if (!other)
                continue;
            if (other === mine) {
                if (exact !== null && exact !== val) {
                    // Two rows claiming THIS title with different figures:
                    // more than one release of it sits in the window, so
                    // there is no safe answer at all.
                    exactClash = true;
                    break;
                }
                exact = val;
            } else if (other.includes(mine) || mine.includes(other)) {
                // Note: no break. An exact hit further in still outranks
                // any disagreement between neighbouring titles.
                if (contained === null)
                    contained = val;
                else if (contained !== val)
                    containedClash = true;
            }
        }
        if (exactClash || (exact === null && containedClash))
            return "—";
        return exact ?? contained ?? "—";
    }

    /**
     * Window for the released-figure feed: local midnight yesterday to
     * local midnight in six days, so today is always inside it and the URL
     * cannot go stale while the tab stays open across a date roll.
     */
    function _actualsUrl() {
        const a = new Date(); a.setHours(0, 0, 0, 0); a.setDate(a.getDate() - 1);
        const b = new Date(); b.setHours(0, 0, 0, 0); b.setDate(b.getDate() + 6);
        return `https://economic-calendar.tradingview.com/events?from=${a.toISOString()}&to=${b.toISOString()}`;
    }

    /**
     * `_lastFF` (+ `_tv`) -> today's calendar rows, or a throw.
     *
     * Every impact level is kept (see `folders`): what the tab SHOWS is the
     * view's filter, and this function's job is only to decide which rows are
     * real -- today, in this machine's zone, with a name. Nothing else decides
     * what the tab shows. The
     * second pass over the SORTED list is `cmp`: the release before this
     * one, which is what lets the card show today's earlier numbers beside
     * the current ones.
     */
    function _applyFeed() {
        const list = root._lastFF;
        if (!Array.isArray(list))
            throw new Error("payload is not an array");
        const now = root._shownDate === ""
            ? new Date()
            : thr(root._shownDate);
        const y = now.getFullYear(), mo = now.getMonth(), da = now.getDate();
        const out = [];
        for (const e of list) {
            if (!e)
                continue;
            // ── Every folder, not just the red one ────────────────────
            // This loop used to drop everything that was not High, at the
            // service, so the tab could not show an orange folder no matter
            // what its own filter said. WHICH folders are on screen is the
            // view's filter now (see `folders` above); this end keeps the
            // calendar it was handed and names each row's folder.
            const impact = root.folderOf(e.impact);
            const at = root._parseFeedDate(e.date);
            if (isNaN(at))
                continue;
            const d = new Date(at);
            if (d.getFullYear() !== y || d.getMonth() !== mo || d.getDate() !== da)
                continue;                       // today, in THIS machine's zone
            const name = String(e.title ?? "").trim();
            if (!name)
                continue;
            const fc = String(e.forecast ?? "").trim() || "—";
            const pv = String(e.previous ?? "").trim() || "—";
            const cur = String(e.country ?? "").trim().toUpperCase() || "—";
            // forecast/previous are the mirror's own words for this release
            // and are passed through untouched; actual is the second feed's,
            // and the direction is read off the two only where both are
            // numbers.
            const act = root._actualFor(cur, at, name);
            const beat = root._beat(act, fc);
            out.push({
                // Stable identity: release instant + title. The same event
                // on a refetch is the same id, which is what lets a refresh
                // be told apart from a change.
                id: `${e.date}|${name}`,
                at: at,
                time: root._hhmm(at),
                currency: cur,
                name: name,
                // "high" | "medium" | "low" | "grey" -- the folder colour.
                // The rail and the folder toggles both read it.
                impact: impact,
                forecast: fc,
                previous: pv,
                actual: act,
                // "up" / "down" / "" -- actual against previous, empty
                // until a figure exists and can be compared.
                bias: root._bias(act, pv),
                // How the release landed against CONSENSUS, and what that
                // means for its currency -- the sentence the card prints
                // when the row is opened (see `_beat` / `_verdict`). Empty
                // until both a figure and a consensus exist, so a row that
                // has not printed says nothing rather than guessing.
                beat: beat,
                favourable: root._favourable(name, beat),
                verdict: root._verdict(cur, name, beat),
                cmp: null,                      // filled in below
                detail: root._detail(cur, fc, pv),
            });
        }
        out.sort((a, b) => a.at - b.at);        // the day reads the way the clock runs
        for (let i = 1; i < out.length; i++) {
            out[i].cmp = {
                time: out[i - 1].time,
                name: out[i - 1].name,
                forecast: out[i - 1].forecast,
                actual: out[i - 1].actual,
            };
        }

        const sig = JSON.stringify(out);
        if (sig !== root._feedSig) {
            root._feedSig = sig;
            root.events = out;
        }
        root.recomputeStates();
    }

    /**
     * Two fetches, decoupled on purpose.
     *
     * The mirror is the LIST and it alone decides whether the refresh
     * succeeded; the second feed is only ever a source of released figures,
     * so its failure leaves a fully working tab with `actual` reading "—".
     * If it answers after the list is already drawn, the list is re-applied
     * with the numbers merged in -- one rebuild, and only when a figure has
     * actually appeared.
     */
    function refresh() {
        if (root._inFlight || Date.now() < root._nextFetchAt)
            return;
        root._inFlight = true;
        root._lastFetch = Date.now();
        root._nextFetchAt = Date.now() + root.refreshIntervalMs;
        if (root.events.length === 0)
            root.feedState = "loading";
        http.get(root.feedUrl, ff => {
            root._lastFF = ff;
            try {
                root._applyFeed();
                root.feedState = "ok";
            } catch (e) {
                console.log(`[TradingService] bad calendar payload: ${e}`);
                root.feedState = "error";
            }
            root._inFlight = false;
        }, (why, status, retryAfter) => {
            // Whatever was last rendered stays on screen: a list fetched
            // today is still today's, and the view labels it stale rather
            // than blanking it. With nothing rendered, it says so.
            //
            // 429 is not "the feed is down", it is "you asked too often":
            // hold off for exactly as long as the limiter asked, instead of
            // pushing every following attempt into the same penalty window.
            if (status === 429 && retryAfter > 0)
                root._nextFetchAt = Date.now() + retryAfter * 1000;
            console.log(`[TradingService] calendar fetch failed: ${why}`
                + (retryAfter > 0 ? ` (backing off ${retryAfter}s)` : ""));
            root.feedState = "error";
            root._inFlight = false;
        });
        // The figures ride alongside, on their own gate: the list is not
        // held up by them and they are not held up by the list.
        root.fetchActuals();
    }

    /**
     * The released figures, on their own clock.
     *
     * The whole point is the SECOND a folder trips: recomputeStates() runs
     * every second and asks for a pull the moment one of today's rows
     * crosses to "released", so the actual lands as soon as the second feed
     * has it instead of whenever the three-minute list refresh next comes
     * around. Guarded so that asking cannot become hammering: one request
     * at a time, never closer than a minute, honouring the limiter's own
     * Retry-After, and only for as long after the release as the figure
     * might still be missing (a speech that will never print one stops
     * being asked about twelve minutes after it happened).
     */
    function fetchActuals() {
        if (root._actualsInFlight || Date.now() < root._nextActualsAt)
            return;
        root._actualsInFlight = true;
        root._nextActualsAt = Date.now() + root.actualsIntervalMs;
        http.get(root._actualsUrl(), tv => {
            root._actualsInFlight = false;
            const rows = (tv && Array.isArray(tv.result)) ? tv.result : [];
            if (rows.length === 0)
                return;
            // Only rebuild the list when a figure actually APPEARED -- a
            // payload answering with the same numbers would otherwise churn
            // every delegate once a minute for nothing. The compare happens
            // BEFORE the write, which is the whole of its meaning.
            const prev = JSON.stringify(root._tv);
            const next = JSON.stringify(rows);
            if (next === prev)
                return;
            root._tv = rows;
            if (root._lastFF === null)
                return;
            try { root._applyFeed(); }
            catch (e) { console.log(`[TradingService] actuals merge failed: ${e}`); }
        }, (why, status, retryAfter) => {
            root._actualsInFlight = false;
            if (status === 429 && retryAfter > 0)
                root._nextActualsAt = Date.now() + retryAfter * 1000;
            console.log(`[TradingService] released-figure fetch failed: ${why}`
                + (retryAfter > 0 ? ` (backing off ${retryAfter}s)` : ""));
        }, {
            "Origin": "https://www.tradingview.com",
            "Referer": "https://www.tradingview.com/"
        });
    }

    /**
     * What each row SAYS, rebuilt from the clock.
     *
     * The old list hard-coded a `state` per event -- including one that was
     * permanently "live" -- which is how the tab could contradict the clock
     * in the bar above it. States are OUTPUT here, never input.
     */
    function recomputeStates() {
        const now = Date.now();
        const map = {};
        let hunting = false;
        for (const ev of root.events) {
            const released = now >= ev.at;
            map[ev.id] = released
                ? { state: "released", countdown: null }
                : { state: "upcoming", countdown: root._countdown(ev.at - now) };
            // A row that has tripped but carries no number yet is the one
            // thing worth asking the figures feed about RIGHT NOW -- that is
            // the moment the actual is expected to appear.
            if (released && ev.actual === "—" && now - ev.at < root.actualsHuntMs)
                hunting = true;
        }
        root.eventStates = map;
        if (hunting)
            root.fetchActuals();
    }

    // ── Formatting ─────────────────────────────────────────────────────
    // Grouping is applied to the INTEGER part only: a five-decimal pair
    // must read 1.09124, never "1.09 124".
    function formatPrice(v) {
        const s = Number(v).toFixed(root.decimals);
        const parts = s.split(".");
        parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, " ");
        return parts.join(".");
    }
    function formatSigned(v) {
        return (v >= 0 ? "+" : "−") + root.formatPrice(Math.abs(v));
    }

    // ── Series generation & ticking ────────────────────────────────────
    function reseed() {
        const inst = root.instrument;
        let s = inst.seed >>> 0;
        function rnd() {
            s = (s * 1664525 + 1013904223) >>> 0;
            return s / 4294967296;
        }
        // 56 daily bars once aggregated to 1D, i.e. 56 * 96 fifteen-minute
        // bars. The length is set by the LARGEST timeframe, not by what the
        // 15m view draws: every timeframe rolls up from this one array.
        const n = 56 * 96;
        const drift = (inst.last - inst.start) / n;

        // A BRIDGE, not a free walk: the noise is generated first, then
        // pulled linearly back to zero at the end, so bar n-1 closes exactly
        // on `inst.last`. Across 5376 bars that free noise wanders about
        // ±80 on gold, and pinning it only at the very end would turn the
        // whole wander into one giant candle in the 1D view -- a candle that
        // never traded.
        const noise = [];
        let acc = 0;
        for (let i = 0; i < n; i++) {
            acc += (rnd() - 0.5) * inst.step * 2;
            noise.push(acc);
        }
        const endNoise = noise[n - 1];

        const out = [];
        let prevClose = inst.start;
        for (let i = 0; i < n; i++) {
            const o = prevClose;
            const c = inst.start + drift * (i + 1)
                + (noise[i] - endNoise * (i + 1) / n);
            out.push({
                o: o, c: c,
                h: Math.max(o, c) + rnd() * inst.step,
                l: Math.min(o, c) - rnd() * inst.step,
                v: 0.3 + rnd() * 0.7
            });
            prevClose = c;
        }
        root.base = out;
        root._publish();
    }

    /**
     * `base` -> the 56 candles of the SELECTED timeframe.
     *
     * Every field is an OHLC roll-up of `agg` source bars: the open is the
     * group's first open, the close its last close, the high and low the
     * extremes across it, and `v` the mean (the chart draws volume as a bar,
     * not a sum). `openPrice` stays pinned to the base series' own first
     * open, so the header's change is about the QUOTE and does not move when
     * you press 4H.
     */
    function _publish() {
        const agg = root.tfAgg;
        const b = root.base;
        const out = [];
        // The chart draws 56 bars: the newest 56 at this granularity, taken
        // from a group boundary (5376 is a multiple of every agg).
        const start = Math.max(0, Math.floor((b.length - 56 * agg) / agg) * agg);
        for (let i = start; i + agg <= b.length; i += agg) {
            let h = -Infinity, l = Infinity, v = 0;
            for (let j = i; j < i + agg; j++) {
                if (b[j].h > h) h = b[j].h;
                if (b[j].l < l) l = b[j].l;
                v += b[j].v;
            }
            out.push({ o: b[i].o, h: h, l: l, c: b[i + agg - 1].c, v: v / agg });
        }
        root.candles = out;
        root.openPrice = b.length > 0 ? b[0].o : 0;
        root.price = b.length > 0 ? b[b.length - 1].c : 0;
        root.rev++;
    }

    // One tick: move the live 15m bar, and every so often roll a new one so
    // the walk moves forward instead of only breathing on its last bar. The
    // chart is re-rolled from `base` every time, so whichever timeframe is
    // on screen moves with it.
    function tick() {
        if (root.base.length === 0) {
            root.reseed();
            return;
        }
        const inst = root.instrument;
        const arr = root.base.slice();
        const last = arr[arr.length - 1];
        last.c += (Math.random() - 0.48) * inst.step * 0.8;
        last.h = Math.max(last.h, last.c);
        last.l = Math.min(last.l, last.c);
        last.v = Math.min(1, last.v + Math.random() * 0.05);
        if (Math.random() < 0.05) {
            arr.push({ o: last.c, h: last.c, l: last.c, c: last.c, v: 0.3 });
            if (arr.length > 56 * 96)
                arr.shift();
        }
        root.base = arr;
        root._publish();
    }

    /**
     * Switch the chart's granularity. The source series is NOT rebuilt --
     * only re-aggregated -- so switching back returns the same candles, and
     * the symbol switch (below) stays the only thing that reseeds.
     */
    function selectTimeframe(tf) {
        if (root.timeframe === tf || !root.timeframes.some(t => t.tf === tf))
            return;
        root.timeframe = tf;
        root._publish();
    }

    function selectSymbol(sym) {
        if (!root.instruments.some(i => i.sym === sym))
            return;
        if (root.symbol === sym)
            return;
        root.symbol = sym;
        root.reseed();
    }

    // ── The claim contract ─────────────────────────────────────────────
    // Only tick while something is actually drawing us.
    property var _claims: []
    readonly property bool live: root._claims.length > 0
    function claim(owner) {
        if (root._claims.indexOf(owner) < 0)
            root._claims = root._claims.concat([owner]);
        // The calendar arrives WITH a claim, never at construction: the
        // first claim pulls it (if the backoff window has passed), the
        // timer below keeps it fresh while the tab is open, and
        // Component.onCompleted still touches no network at all.
        if (Date.now() >= root._nextFetchAt)
            root.refresh();
    }
    function release(owner) {
        root._claims = root._claims.filter(o => o !== owner);
    }

    Timer {
        interval: 1100
        repeat: true
        running: root.live
        onTriggered: root.tick()
    }

    // ── The calendar's own two clocks ─────────────────────────────────
    // One second: recompute what each event's row SAYS, so the countdown
    // and the released/upcoming split are the clock's output and cannot
    // drift from it. Three minutes: re-pull the feed, which is also what
    // re-filters "today" when the date rolls over under an open tab. Three
    // minutes and not one because this is a WEEKLY calendar file behind a
    // rate limiter while the countdowns it feeds are recomputed locally
    // every second anyway -- a minute-long cadence earned a 429 here. Both
    // stop the moment the tab is hidden.
    Timer {
        interval: 1000
        repeat: true
        running: root.live
        onTriggered: root.recomputeStates()
    }
    Timer {
        interval: root.refreshIntervalMs
        repeat: true
        running: root.live
        onTriggered: root.refresh()
    }

    // The stored filter arrives with the state file, which is read
    // asynchronously -- so it is taken here if it is already in, and from
    // `ready` if it is not. Both paths run `loadFolderFilter`, which is
    // idempotent (it only ever writes what the file already holds).
    Component.onCompleted: {
        root.reseed();
        if (Persistent.ready)
            root.loadFolderFilter();
    }
    Connections {
        target: Persistent
        function onReadyChanged() {
            if (Persistent.ready)
                root.loadFolderFilter();
        }
    }

    // ── IPC: `qs -c ii ipc call trading …` ─────────────────────────────
    // "Is the tab telling the truth?" is a data question, and `state`
    // answers it from a script by printing exactly the rows the card would
    // draw -- the filter can then be READ rather than believed, which is
    // the only way to check it without a pointer on a layer surface.
    IpcHandler {
        target: "trading"
        function refresh(): void { root.refresh(); }

        /** `qs -c ii ipc call trading timeframe 4H` -- switch without a pointer. */
        function timeframe(tf: string): void { root.selectTimeframe(tf); }

        /** `qs -c ii ipc call trading show YYYY-MM-DD` -- reverse to any past date.
         *  When `day` is empty, the card goes back to the live day -- the active
         *  date it was drawing before this call, whatever that was when the call
         *  landed. The shell accepts the call as-is (it is typed as `string`),
         *  so `qs -c ii ipc call trading show ""` is the explicit reset.
         *
         *  The feed delivered for a past date is a SAME-DAY slice from the
         *  released-figures endpoint, which is the only one that carries the
         *  actuals the card needs to say anything about that day. For a past
         *  date the mirror (which only reflects releases inside its weekly
         *  window) is being honest by returning no High rows for it -- a past
         *  day that the weekly calendar never covered is, for this card, a day
         *  with nothing to list. The header there reads the date, not "today".
         *
         *  Only the IPC surface is wired: there is no on-screen button for this.
         *  That is deliberate -- the card already reverses itself as soon as any
         *  IPC `show(day)` lands, so adding a button would only be a second way
         *  to issue the same call. The feature exists to be invoked from a script
         *  / keybind / helper, not from the tab's own chrome.
         */
        function show(day: string): void {
            // Only a real date token (or the empty token) is accepted: a
            // malformed day would make `shownDay` read "NaN-NaN-NaN" while
            // the filter quietly fell back to today -- two different
            // answers to "which day is this?". The shape check keeps the
            // from/to URL well-formed; the parse check catches shaped-but-
            // impossible dates ("2026-99-99"). Refuse either and keep the
            // day already on screen.
            if (day !== ""
                && (!/^\d{4}-\d{2}-\d{2}$/.test(day)
                    || isNaN(new Date(day + "T12:00:00").getTime()))) {
                console.log(`[TradingService] show: "${day}" is not a YYYY-MM-DD date; still showing ${root.shownDay}`);
                return;
            }
            root._shownDate = day;
            if (day === "") {
                // Back to the ACTIVE day, and now rather than eventually.
                // The reversed day's `show(...)` filled `_lastFF`/`_tv` from
                // a single-date slice, so the weekly mirror has to be pulled
                // again -- and the three-minute gate that would normally
                // hold that pull open for minutes is re-opened here. Both
                // gates go, so the calendar AND the released figures for the
                // live day land as soon as the feeds answer.
                root._nextFetchAt = 0;
                root._nextActualsAt = 0;
                root.refresh();
                return;
            }

            http.get("https://economic-calendar.tradingview.com/events?from="
                + day + "T00:00:00.000Z&to=" + day + "T23:59:59.999Z", tv => {
                const rows = (tv && Array.isArray(tv.result)) ? tv.result : [];
                root._tv = rows;
                root._lastFF = rows.filter(r => r.importance === 1).map(r => ({
                    title: r.indicator, country: r.currency, date: r.date,
                    impact: "High", forecast: r.forecast ?? "", previous: r.previous ?? ""
                }));
                try { root._applyFeed(); root.feedState = "ok"; }
                catch (e) { console.log(`[TradingService] show failed: ${e}`); }
            }, why => console.log(`[TradingService] show fetch failed: ${why}`),
            { "Origin": "https://www.tradingview.com", "Referer": "https://www.tradingview.com/" });
        }

        /** `qs -c ii ipc call trading shownDay` -- which day the card is
         *  drawing: "today" on the active day, else the reversed date. */
        function shownDay(): string { return root.shownDay; }

        /** `qs -c ii ipc call trading folders red=on orange=on yellow=off grey=off`
         *  -- the header's toggles, without a pointer on a popover.
         *
         *  ONE TOKEN PER FOLDER, and that is a constraint of the boundary, not
         *  a style choice: the IPC splits on whitespace before it calls, so
         *  `folders red on orange off` arrives as EIGHT arguments and is
         *  refused ("4 required but 8 were provided") with nothing applied.
         *  Each token is `name=state`, so the four can come in any order and a
         *  name that is not a folder is ignored rather than silently mapping to
         *  the wrong one. "on"/"true"/"1" switch a folder on and anything else
         *  (including a typo) switches it off -- a filter is read at a glance,
         *  so half-applying one is worse than applying the wrong one. */
        function folders(red: string, orange: string, yellow: string, grey: string): void {
            const on = (v) => v === "on" || v === "true" || v === "1";
            for (const token of [red, orange, yellow, grey]) {
                const at = String(token ?? "").indexOf("=");
                if (at < 0)
                    continue;                  // not a name=state token; ignore
                const name = String(token).slice(0, at).trim().toLowerCase();
                const state = on(String(token).slice(at + 1).trim().toLowerCase());
                if (name === "red" || name === "high") root.showHigh = state;
                else if (name === "orange" || name === "medium") root.showMedium = state;
                else if (name === "yellow" || name === "low") root.showLow = state;
                else if (name === "grey" || name === "gray") root.showGrey = state;
            }
        }

        function state(): string {
            const rows = root.events.map(e =>
                `${e.time} ${e.currency} ${e.name}`
                + ` [${e.impact ?? "?"}]`
                + ` [${((root.eventStates[e.id]) ?? {}).state ?? "?"}]`
                + ` fc=${e.forecast} pv=${e.previous} act=${e.actual}`
                + (e.bias ? ` ${e.bias === "up" ? "▲" : "▼"}` : "")
                + (e.beat ? ` beat=${e.beat}/${e.favourable === null ? "-" : (e.favourable ? "good" : "bad")}` : "")
                + (e.verdict ? ` [${e.verdict}]` : "")
                + (e.cmp ? ` ‹ ${e.cmp.time} fc=${e.cmp.forecast} act=${e.cmp.actual}` : ""));
            // `range` is the whole reason it is printed: bars is 56 at
            // every timeframe, so the high/low of those 56 candles is what
            // shows the roll-up actually re-published different data.
            const lo = root.candles.length > 0
                ? Math.min(...root.candles.map(c => c.l)) : 0;
            const hi = root.candles.length > 0
                ? Math.max(...root.candles.map(c => c.h)) : 0;
            // `shownDay` is printed WITH the rows because it labels them:
            // the same list reads as "today" or as a reversed date, and a
            // script checking the card must be able to tell which.
            // `folders`/`counts`/`shown` are printed beside the rows for the
            // same reason the rows are printed at all: the filter is state,
            // and "which folders are on, how many rows each holds, and how
            // many survive the filter" is the whole question the toggles ask.
            // `shown` is what the tab draws; `count` is what the feed gave.
            const c = root.folderCounts();
            return `feed=${root.feedState} count=${rows.length} tf=${root.timeframe}`
                + ` folders[red=${root.showHigh} orange=${root.showMedium}`
                + ` yellow=${root.showLow} grey=${root.showGrey}]`
                + ` counts[red=${c.high} orange=${c.medium} yellow=${c.low} grey=${c.grey}]`
                + ` shown=${root.events.filter(e => root.folderShown(e.impact)).length}`
                + ` bars=${root.candles.length} rev=${root.rev}`
                + ` range=${lo.toFixed(5)}..${hi.toFixed(5)} live=${root.live}`
                + ` shownDay=${root.shownDay}`
                + (rows.length > 0 ? "\n  " + rows.join("\n  ") : "");
        }
    }
}
