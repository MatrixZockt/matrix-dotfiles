pragma Singleton

import qs.modules.common
import qs.services
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * "Something is being updated right now", as state.
 *
 * The desktop had no answer to that at all: `paru -Syu` ran for minutes in a
 * terminal and the bar said nothing, so an update in progress was
 * indistinguishable from one that had finished or never started.
 *
 * `scripts/system/package-activity.py` is the source of truth (pacman's own
 * log, so the number it reports counts packages that have actually landed).
 * This service turns that into what the bar draws: a fraction for the status
 * line, and the APP's real name and logo for the island -- see
 * `scripts/system/package-app.py`.
 *
 * The percentage is packages done / packages in the transaction. The
 * transaction's size is not announced anywhere (pacman prints its plan to the
 * terminal, not the log), so it is inferred as "done + still pending", where
 * "still pending" is `pacman -Qu`: the upgrade list shrinks as the run
 * consumes it, which is exactly the total falling out of the arithmetic.
 * Nothing here invents a number it cannot see.
 *
 * Two samples are required before a state change lands. `pacman -Q` and
 * `paru -Ss` live for milliseconds and would otherwise flash an "updating"
 * bar across the desktop several times an hour; requiring the second
 * consecutive sample means the bar appears once a transaction has existed for
 * the better part of two seconds, which every real one has.
 *
 * WHAT SPEAKS, AND WHAT STAYS QUIET (owner, 2026-11-07):
 *     "dont have every package update show as a notification, only desktop app
 *     updates should show their status in the top bar and thats it"
 *
 * So a transaction no longer raises a notification at all -- not on start, not
 * on completion. And the top bar's progress is reserved for updates that are
 * an APP's: `package-app.py` answers {} for a library, a daemon or a hook, and
 * a run made only of those draws nothing anywhere. A run that passes through
 * at least one desktop app speaks once, when the first one turns up
 * (sawDesktopApp), which is also the first moment the bar has a name and a logo
 * to show instead of a package id.
 */
Singleton {
    id: root

    readonly property string probeScript: Quickshell.shellPath("scripts/system/package-activity.py")
    readonly property string appScript: Quickshell.shellPath("scripts/system/package-app.py")

    /// A transaction is running (after the debounce below).
    property bool active: false
    /// pacman | paru | yay | flatpak -- who is doing it.
    property string manager: ""
    /// "transaction" (packages being written) or "prepare" (fetch/build).
    property string phase: ""
    /// Packages changed so far in this transaction.
    property int count: 0
    /// Upgrades still pending: `pacman -Qu`. -1 until measured.
    property int remaining: -1
    /// The package that just landed -- the one the bar names.
    property string packageName: ""
    /// Its app: "" for a library, which the bar then calls by package name.
    property string appName: ""
    property string appIcon: ""

    // The transaction's size, learned while it runs: the largest
    // "done + still pending" the run ever showed. Sticky, because pending
    // reaches 0 on the last package -- without remembering the earlier
    // figure the total would collapse to the count at exactly the moment the
    // bar finally matters.
    property int plannedTotal: 0
    // Whether a pending list was ever seen. `paru -S <one AUR package>` has
    // no upgrade list to consume, so its run has NO measurable total: rather
    // than paint a fake 100% the bar falls back to its indeterminate crawl
    // and the island states the app without a number. Never inventing a
    // percentage is the whole point of the figure.
    property bool measured: false
    readonly property int total: Math.max(root.plannedTotal, root.count, 1)
    /// 0..1, the line's fill and the percentage in the island. -1 = unknown.
    readonly property real fraction: !root.measured ? -1
        : Math.min(1, Math.max(0, root.count / Math.max(1, root.total)))
    readonly property int percent: root.measured
        ? Math.round(root.count / Math.max(1, root.total) * 100) : 0
    /// What the app is called in front of a human: the desktop entry's name,
    /// else the package name (a library upgrade still has to say SOMETHING).
    readonly property string displayName: root.appName !== ""
        ? root.appName : root.packageName
    /// The icon name the bar resolves through the icon theme; "" = none.
    readonly property string iconName: root.appIcon

    // Whether a DESKTOP APP has turned up in this run -- the only kind of
    // update allowed to draw status in the top bar (see the note at the top).
    // `package-app.py` answers {} for a library, so a library-only run never
    // sets it and the bar stays out of the way.
    property bool sawDesktopApp: false
    /// What the bar is allowed to draw: a live transaction that is an app's.
    readonly property bool showsInBar: root.active && root.sawDesktopApp

    // ── The run that just ended ───────────────────────────────────────────
    property int finishedCount: 0
    // Consecutive samples, for the debounce.
    property int _hits: 0
    property int _misses: 0
    // Packages counted during the run, so the completion notice does not have
    // to trust a log read that happens after the transaction is gone.
    property int _countedInRun: 0

    function sample(text) {
        let reading = null;
        try {
            reading = JSON.parse(String(text ?? "").trim() || "{}");
        } catch (error) {
            return; // a broken sample is not evidence of anything
        }
        const seen = reading.active === true;
        if (seen) {
            root._misses = 0;
            root._hits++;
        } else {
            root._hits = 0;
            root._misses++;
        }
        if (seen && !root.active && root._hits >= 2) {
            root.active = true;
            root.manager = String(reading.manager ?? "");
            root.phase = String(reading.phase ?? "");
            root.count = Number(reading.count ?? 0) || 0;
            root.remaining = -1;
            root.plannedTotal = 0;
            root.measured = false;
            root.packageName = String(reading.package ?? "");
            root._countedInRun = root.count;
            // Nothing is said here: the bar waits for the first desktop app in
            // the run (see appLookup). The package that opens a transaction is
            // usually a library, and that is exactly the case the owner asked
            // to keep quiet.
            root.sawDesktopApp = false;
            return;
        }
        if (!seen && root.active && root._misses >= 2) {
            root.active = false;
            root.finishedCount = root._countedInRun;
            root.phase = "";
            root.manager = "";
            root.count = 0;
            root.remaining = -1;
            root.plannedTotal = 0;
            root.measured = false;
            root.packageName = "";
            root.announceDone();
            return;
        }
        if (root.active) {
            root.manager = String(reading.manager ?? root.manager);
            root.phase = String(reading.phase ?? root.phase);
            root.count = Number(reading.count ?? root.count) || root.count;
            root.packageName = String(reading.package ?? root.packageName);
            if (root.count > root._countedInRun)
                root._countedInRun = root.count;
            root.learnTotal();
        }
    }
    // The run's size, from the one place that can see it: what is done plus
    // what is still on the upgrade list.
    function learnTotal() {
        if (!root.active || root.remaining < 0)
            return;
        root.plannedTotal = Math.max(root.plannedTotal, root.count + root.remaining);
        if (root.remaining > 0)
            root.measured = true;
    }
    onRemainingChanged: {
        root.learnTotal();
        // The run may already be past its pending list by the time the first
        // sample lands (a single-package run), and that is not an error -- it
        // simply has no measurable total.
    }

    // ── The app's real name and logo, once per package ────────────────────
    // Not per second: this asks pacman for the package's file list.
    onPackageNameChanged: {
        if (!root.active || root.packageName === "") {
            root.appName = "";
            root.appIcon = "";
            return;
        }
        appLookup.pkg = root.packageName;
        appLookup.running = false;
        appLookup.running = true;
    }

    Process {
        id: appLookup
        // `package` is a RESERVED WORD in QML -- naming this property that
        // failed the whole services import chain and took the bar with it.
        property string pkg: ""
        command: ["python3", root.appScript, appLookup.pkg]
        stdout: StdioCollector {
            onStreamFinished: {
                let info = {};
                try {
                    info = JSON.parse(String(text ?? "").trim() || "{}");
                } catch (error) {
                    return;
                }
                // Ignore a late answer for a package the run has moved past.
                if (String(info.package ?? "") !== "" && String(info.package) !== root.packageName)
                    return;
                root.appName = String(info.name ?? "");
                root.appIcon = String(info.icon ?? "");
                // The first desktop app of the run: the one moment worth a
                // tell. Announced once per run, because a run can pass through
                // several apps and a bar that blinked for each would be noise.
                if (root.active && root.appName !== "" && !root.sawDesktopApp) {
                    root.sawDesktopApp = true;
                    root.announceStart();
                }
            }
        }
    }

    // ── How much of the transaction is left ───────────────────────────────
    // `pacman -Qu` is the local upgrade list: it is what `-Syu` is going to
    // install, and it shrinks by one per package the run consumes. Sampled
    // every few seconds -- it reads the local database, so it is cheap, but
    // not free enough for the one-second probe.
    Timer {
        interval: 4000
        repeat: true
        running: root.active
        triggeredOnStart: true
        onTriggered: if (!pendingProbe.running && root.active) pendingProbe.running = true
    }
    Process {
        id: pendingProbe
        command: ["bash", "-c", "pacman -Qu 2>/dev/null | wc -l"]
        stdout: StdioCollector {
            onStreamFinished: {
                const n = parseInt(String(text ?? "").trim(), 10);
                if (!isNaN(n))
                    root.remaining = n;
            }
        }
    }

    // Both announcements go through the shell's OWN status channel, so an
    // update speaks in the same voice as a charger being plugged in: a pulse on
    // the bar's indication line, the sentence in the extended island, and the
    // small corner tell over a fullscreen app.
    function announceStart() {
        StatusSignal.blink(Appearance.colors.colPrimary,
            Translation.tr("Updating") + " " + (root.displayName !== ""
                ? root.displayName : root.packageName));
    }
    function announceDone() {
        const n = root.finishedCount;
        // No notification. The owner asked for package updates to stay silent
        // (2026-11-07), and a completion notice was the last thing that spoke
        // outside the bar. What is left is the bar's own tell, and only for a
        // run that touched a desktop app -- a library-only transaction now
        // finishes without a word, which is what "only desktop app updates"
        // means.
        if (root.sawDesktopApp) {
            const sentence = n > 0
                ? Translation.tr("%1 package(s) updated").arg(n)
                : Translation.tr("Update finished, nothing installed");
            StatusSignal.blink(n > 0 ? Appearance.colors.colPrimary : Appearance.colors.colError,
                sentence);
        }
        root.sawDesktopApp = false;
        // The update count behind the bar was stale the moment the transaction
        // ended, and that is true whatever the run was made of.
        Updates.refresh();
    }

    Timer {
        // One second: a package takes at least a few hundred milliseconds, and
        // the whole probe is a /proc scan plus a 60-byte log tail.
        interval: 1000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: if (!probe.running) probe.running = true
    }

    Process {
        id: probe
        command: ["python3", root.probeScript]
        stdout: StdioCollector {
            onStreamFinished: root.sample(String(text ?? ""))
        }
    }
}
