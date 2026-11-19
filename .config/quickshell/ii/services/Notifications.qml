pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import qs
import qs.services
// NotificationUtils (the shared app-identity matcher behind the per-app mute).
// Without this import every mute check threw "ReferenceError: NotificationUtils
// is not defined", which aborted onNotification before anything was recorded --
// the whole feature silently did nothing.
import qs.modules.common.functions
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import Quickshell.Hyprland

/**
 * Provides extra features not in Quickshell.Services.Notifications:
 *  - Persistent storage
 *  - Popup notifications, with timeout
 *  - Notification groups by app
 */
Singleton {
	id: root
    component Notif: QtObject {
        id: wrapper
        required property int notificationId // Could just be `id` but it conflicts with the default prop in QtObject
        property Notification notification
        property list<var> actions: notification?.actions.map((action) => ({
            "identifier": action.identifier,
            "text": action.text,
        })) ?? []
                  property bool popup: false
          // Has this one been in front of the user's eyes in the panel? Only
          // read for the shell's own "copied" notices -- see
          // sweepSaveableNotices.
          property bool seen: false
        property bool isTransient: notification?.hints.transient ?? false
        // ── A signal, not a notification ────────────────────────────────
        //
        // The clipboard's "Copied" card (services/Cliphist.qml) borrows the
        // notification card for its material, width and corner -- and for
        // nothing else. This hint is what lets the card stripe very
        // affordance that makes a notification a notification: the "now"
        // timestamp, the expand chevron, the delete button, click-to-open
        // and drag-to-dismiss are all dropped when it is set (see
        // NotificationGroup/NotificationItem). Read through the hints map
        // rather than a dedicated field, because that is the only channel a
        // DBus sender has for saying something the spec does not define.
        // What kind of signal this is: "" for a real notification, otherwise
        // the glyph the card should wear. The sender puts the kind IN the hint
        // (`x-ii-signal: "copy"` / `"image"`), so the card does not have to
        // guess from the summary -- "Image copied" and "Copied" are just
        // strings, and a translated one would guess wrong. A bare `true` is
        // still read as a text copy, which keeps an older sender working.
        property string signalKind: {
            const hint = notification?.hints?.["x-ii-signal"];
            if (hint === true) return "copy";
            return (typeof hint === "string" && hint.length > 0) ? hint : "";
        }
        property bool isSignal: signalKind !== ""
        property string appIcon: notification?.appIcon ?? ""
        property string appName: notification?.appName ?? ""
        property string body: notification?.body ?? ""
        property string image: notification?.image ?? ""
        property string summary: notification?.summary ?? ""
        property double time
        property string urgency: notification?.urgency.toString() ?? "normal"
        property Timer timer

        onNotificationChanged: {
            if (notification === null) {
                root.discardNotification(notificationId);
            }
        }
    }

    function notifToJSON(notif) {
        return {
            "notificationId": notif.notificationId,
            "actions": notif.actions,
            "appIcon": notif.appIcon,
            "appName": notif.appName,
            "body": notif.body,
            "image": notif.image,
            "summary": notif.summary,
            "time": notif.time,
            "urgency": notif.urgency,
        }
    }
    function notifToString(notif) {
        return JSON.stringify(notifToJSON(notif), null, 2);
    }

    component NotifTimer: Timer {
        required property int notificationId
        interval: 7000
        running: true
        onTriggered: () => {
            const index = root.list.findIndex((notif) => notif.notificationId === notificationId);
            const notifObject = root.list[index];
            print("[Notifications] Notification timer triggered for ID: " + notificationId + ", transient: " + notifObject?.isTransient);
            if (notifObject.isTransient) root.discardNotification(notificationId);
            else root.timeoutNotification(notificationId);
            destroy()
        }
    }

    // ── Do not disturb ──────────────────────────────────────────────────
    //
    // The switch lives in the CONFIG file, not in this singleton's memory,
    // because the Settings app is a different process with no way to call
    // into the shell. Writing there and reading the config watch here is the
    // only channel the two share (the same one `mutedApps` uses).
    //
    // It can also switch itself off: `dndUntil` is an epoch-ms deadline and
    // `dndClock` advances through a timer while a deadline is set, so
    // `silent` re-evaluates on its own. A deadline is a promise -- "quiet for
    // the next hour" must not leave the desktop silent until the next login.
    readonly property bool dndOn: Config?.options.notifications.doNotDisturb ?? false
    readonly property real dndUntil: Config?.options.notifications.dndUntil ?? 0
    readonly property int dndDurationMin: Config?.options.notifications.dndDurationMin ?? 0
    property real dndClock: Date.now()
    readonly property bool silent: NotificationUtils.dndActive(root.dndOn, root.dndUntil, root.dndClock)
    // Date.now(), not `dndClock`: the clock above only advances while a timer
    // is running, and reporting "64 s left" for a 4 s deadline because the
    // last tick predates the switch is exactly the kind of readout that makes
    // a working feature look broken.
    readonly property real dndRemainingMs: root.dndUntil > 0 ? Math.max(0, root.dndUntil - Date.now()) : 0

    function setDoNotDisturb(enabled, durationMin) {
        const notifications = Config.options.notifications;
        const minutes = Number(durationMin ?? root.dndDurationMin) || 0;
        notifications.dndDurationMin = minutes;
        notifications.doNotDisturb = enabled;
        notifications.dndUntil = enabled
            ? NotificationUtils.dndDeadline(minutes, Date.now())
            : 0;
        root.dndClock = Date.now();
    }

    function toggleDoNotDisturb() {
        root.setDoNotDisturb(!root.silent, root.dndDurationMin);
    }

    // A stale clock must not outlive the switch: an externally-set DND (the
    // Settings app, a hand edit) never calls setDoNotDisturb(), so the moment
    // the setting flips is also when the clock has to be re-stamped.
    onDndOnChanged: root.dndClock = Date.now()

    Timer {
        // Only while DND is on: an ordinary desktop needs no wake-ups, and the
        // deadline check below is the only thing here that has to be timely.
        interval: 5000
        repeat: true
        running: root.dndOn
        onTriggered: {
            root.dndClock = Date.now();
            if (root.dndUntil > 0 && root.dndClock >= root.dndUntil)
                root.setDoNotDisturb(false, root.dndDurationMin);
        }
    }

    property int unread: 0
    property var filePath: Directories.notificationsPath
    property list<Notif> list: []
    property var popupList: list.filter((notif) => notif.popup);
    property bool popupInhibited: (GlobalStates?.sidebarRightOpen ?? false) || silent

    // ── How long a popup may stay in the corner ──────────────────────────
    //
    // A CEILING, not a default, and the distinction is the whole point. The
    // number the popup actually waits is chosen by the sending app: many send
    // `expireTimeout: -1` ("pick your own default"), plenty send 5000 or
    // 10000, and some send 0 meaning "never expire". So a default bounds
    // nothing -- the card sits in the corner for as long as the app that sent
    // it felt like, which is not a decision this shell should be handing out.
    //
    // Nothing is lost by bounding it. When the timer fires, `NotifTimer`
    // calls `timeoutNotification`, which clears `popup` and leaves the
    // notification in the history; it is still in the bell, still in the
    // sidebar, and still on disk. Only the transient card in the corner goes
    // away, which is the part that was never meant to be permanent.
    readonly property int popupMaxMs: 2500

    // The lifetime actually used for a popup: whatever the app asked for,
    // bounded above by `popupMaxMs`. A SHORTER request is still honoured --
    // an app that says "this is only worth a moment" gets its moment -- and
    // only the long and unbounded requests are pulled down to the ceiling.
    function popupIntervalFor(expireTimeout) {
        const fallback = Config?.options.notifications.timeout ?? 7000;
        let requested = expireTimeout < 0 ? fallback : expireTimeout;
        // 0 is the spec's "never expire", and a negative value other than the
        // documented -1 is nonsense. Neither may park a card in the corner
        // forever: both fall back to the ceiling.
        if (!(requested > 0)) requested = root.popupMaxMs;
        return Math.min(requested, root.popupMaxMs);
    }
    // ── The last few that came through ──────────────────────────────────
    //
    // Dismissing a notification used to erase it: `list` is what the sidebar
    // draws, what the bell counts and what the file keeps, so once a card was
    // gone there was no way back to "what did that actually say?". This is the
    // record of what ARRIVED, kept for the last `historyMax` of them, and
    // dismissing never touches it -- the rewind button at the bottom of the
    // notification panel reads it (NotificationList.qml).
    //
    // In memory only, deliberately. This is a glance back at the last few
    // things that happened, not an archive: it starts empty on every shell
    // start, which keeps it out of the config directory, out of a file that
    // grows without limit, and out of "why is a notification from Tuesday
    // still on my disk". 30 is a comfortable page of them.
    readonly property int historyMax: 30
    property var history: []

    function archive(notification) {
        const entry = {
            "notificationId": notification.notificationId,
            "appName": notification.appName ?? "",
            "appIcon": notification.appIcon ?? "",
            "summary": notification.summary ?? "",
            "body": notification.body ?? "",
            "image": notification.image ?? "",
            "urgency": String(notification.urgency ?? "normal"),
            "time": notification.time,
            "archivedAt": Date.now(),
        };
        // Newest last in storage, so trimming the oldest is one shift().
        const next = root.history.slice();
        next.push(entry);
        while (next.length > root.historyMax)
            next.shift();
        root.history = next;
    }

    // Newest first: the order a history is read in. A new array, so the
    // view's binding re-evaluates when `history` is replaced.
    readonly property var historyNewestFirst: root.history.slice().reverse()

    function clearHistory() {
        root.history = [];
    }

    property var latestTimeForApp: ({})

    // ── "point at the newest one" (the bar's bell) ──────────────────────
    //
    // A monotonically increasing token, not a notification id. The bar asks
    // for a highlight by bumping this; the list watches it and flashes the
    // group holding the newest notification.
    //
    // A token rather than "flash notification id N" because the request has
    // to be repeatable: pressing the bell twice in a row must flash twice,
    // and an id that is already the target would not change, so nothing
    // would re-fire. A counter always changes.
    property int highlightToken: 0
    // Set alongside the token so the list knows WHICH group to flash, and
    // cleared by a timer afterwards so a group created later (the sidebar
    // animating in) does not flash on arrival -- the flash belongs to the
    // press, not to the delegate existing.
    property int highlightNotificationId: -1
    // Guards against a flash that outlives its press: if a delegate is
    // created more than this long after the request, the request is stale.
    property real highlightRequestedAt: 0
    readonly property real highlightWindow: 1200

    function requestHighlight() {
        if (root.list.length === 0) return;
        root.highlightNotificationId = root.list[0].notificationId;
        root.highlightRequestedAt = Date.now();
        root.highlightToken = root.highlightToken + 1;
    }

    function highlightIsLive() {
        return root.highlightNotificationId >= 0
            && (Date.now() - root.highlightRequestedAt) < root.highlightWindow;
    }
    Component {
        id: notifComponent
        Notif {}
    }
    Component {
        id: notifTimerComponent
        NotifTimer {}
    }

    function stringifyList(list) {
        // Transients are popups, never history: NotifTimer discards them at
        // timeout, and they must not reach the file either -- a shell killed
        // mid-popup would otherwise resurrect "Copied" as a permanent row.
        return JSON.stringify(list.filter((notif) => !notif.isTransient)
            .map((notif) => notifToJSON(notif)), null, 2);
    }
    
    onListChanged: {
        // Update latest time for each app
        root.list.forEach((notif) => {
            if (!root.latestTimeForApp[notif.appName] || notif.time > root.latestTimeForApp[notif.appName]) {
                root.latestTimeForApp[notif.appName] = Math.max(root.latestTimeForApp[notif.appName] || 0, notif.time);
            }
        });
        // Remove apps that no longer have notifications
        Object.keys(root.latestTimeForApp).forEach((appName) => {
            if (!root.list.some((notif) => notif.appName === appName)) {
                delete root.latestTimeForApp[appName];
            }
        });
    }

    function appNameListForGroups(groups) {
        return Object.keys(groups).sort((a, b) => {
            // Sort by time, descending
            return groups[b].time - groups[a].time;
        });
    }

    function groupsForList(list) {
        const groups = {};
        list.forEach((notif) => {
            if (!groups[notif.appName]) {
                groups[notif.appName] = {
                    appName: notif.appName,
                    appIcon: notif.appIcon,
                    notifications: [],
                    time: 0
                };
            }
            groups[notif.appName].notifications.push(notif);
            // Always set to the latest time in the group
            groups[notif.appName].time = latestTimeForApp[notif.appName] || notif.time;
        });
        return groups;
    }

    property var groupsByAppName: groupsForList(root.list)
    property var popupGroupsByAppName: groupsForList(root.popupList)
    property list<string> appNameList: appNameListForGroups(root.groupsByAppName)
    property list<string> popupAppNameList: appNameListForGroups(root.popupGroupsByAppName)

    // ── One card per notification ──────────────────────────────────────
    //
    // The grouped lists above still exist -- the popup's arrival animation
    // and the highlight logic are written in terms of them -- but they are
    // no longer what the lists DRAW. An app with four notifications used to
    // be one card with a count badge, two lines peeking out of it and a
    // right-click (or the badge) to open the rest, which means the four
    // things the user was actually told are stacked inside a container they
    // have to expand to read, and hovering it invites an expansion they did
    // not ask for.
    //
    // Each notification is now its own card, newest first, in the shape the
    // single-notification group always had: the app icon, the summary as the
    // title, the time, and the body. Nothing to expand, no count, nothing
    // hidden behind a hover.
    //
    // They are still expressed as one-notification groups, because
    // NotificationGroup is a good card and this only changes what goes INTO
    // it. `time` is the notification's own time rather than the app's
    // newest, which is what the grouped version showed and is wrong for a
    // list where each line is its own thing.
    function flatCardsFor(source) {
        return source
            .slice()
            .sort((a, b) => (b.time || 0) - (a.time || 0))
            .map((n) => ({
                appName: n.appName,
                appIcon: n.appIcon,
                notifications: [n],
                time: n.time,
            }));
    }

    // History NEVER draws a transient (asked for as "a notification that
    // don't stay in the notification sidebar"): the card lives in the corner
    // popup and vanishes there -- the sidebar must not show it, not even for
    // the moment it is popping.
    property var flatCards: flatCardsFor(root.list.filter((n) => !n.isTransient))
    property var flatPopupCards: flatCardsFor(root.popupList)

    // Which window class sent this notification.
    //
    // `TrayApps.classForNotification` answers that only for the apps in the
    // shell's tray registry (WhatsApp, Thunderbird) -- so
    // on its own it said "(no match)" for a kitty notification and the
    // click-to-focus had nothing to focus. That is the trap this function
    // exists to avoid: the registry is the right answer for a tray app and
    // the wrong answer for everything else.
    //
    // So: the registry first (it knows the app whose class is spelled
    // nothing like its name), then the generic matcher, which compares the
    // sender's own strings against the classes that are on screen right now.
    // A notification from an app that is not running matches nothing, which
    // is the correct answer -- there is no window to jump to.
    function senderClass(notif) {
        if (!notif)
            return "";
        const live = notif.notification;
        const fromRegistry = TrayApps.classForNotification({
            appName: notif.appName,
            desktopEntry: live ? live.desktopEntry : "",
            appIcon: notif.appIcon,
        });
        if (fromRegistry !== "")
            return fromRegistry;
        // The icon path is the most reliable of the three for an app with a
        // generic name: a kitty notification carries
        // /usr/lib/kitty/logo/kitty.png, and the class is `kitty`.
        const icon = String(notif.appIcon || "").split("/").pop().replace(/\.(png|svg|xpm|ico)$/, "").toLowerCase();
        const name = String(notif.appName || "").toLowerCase();
        const entry = String(live ? live.desktopEntry : "").split("/").pop().replace(/\.desktop$/, "").toLowerCase();
        return TrayApps.classForTrayItem({ id: entry || name, title: icon || name });
    }

    // ── Which desktop entry sent this notification ──────────────────────
    //
    // The bridge from a notification to the thing that can OPEN its app, for
    // the case in `focusSender` below where the sender has no window at all.
    //
    // Three spellings of the same identity, in the order they are worth
    // trusting: the `desktop-entry` hint, which a sender publishes precisely
    // so that its icon and its window can be resolved; the app icon's
    // basename, which for the packaged apps on this machine IS the desktop
    // file's id (Thunderbird sends `org.mozilla.Thunderbird`, and
    // `/usr/share/applications/org.mozilla.Thunderbird.desktop` is the file
    // that starts it, so an icon we can draw is a launch we can make); and
    // the display name last, because a name is a label rather than an id and
    // matches only by accident of packaging.
    function senderEntry(notif) {
        if (!notif) return null;
        const live = notif.notification;
        const cands = [];
        const push = (v) => {
            const key = root.entryKey(v);
            if (key.length > 0 && cands.indexOf(key) < 0)
                cands.push(key);
        };
        if (live) push(live.desktopEntry);
        push(notif.appIcon);
        push(notif.appName);
        if (cands.length === 0)
            return null;

        // Pass 1: the file id, exactly. This is the fast path and it is the
        // one the two trustworthy candidates almost always take.
        for (const c of cands) {
            const entry = DesktopEntries.byId(c);
            if (entry)
                return entry;
        }
        // Pass 2: the id, then the display name, compared over the whole
        // list. This is what catches a sender that told us nothing but
        // "Thunderbird" -- a label, but the exact label the entry carries.
        const all = Array.from(DesktopEntries.applications.values);
        for (const c of cands) {
            const hit = all.find((e) => String(e.id ?? "").toLowerCase().replace(/\.desktop$/, "") === c);
            if (hit)
                return hit;
        }
        for (const c of cands) {
            const hit = all.find((e) => String(e.name ?? "").trim().toLowerCase() === c);
            if (hit)
                return hit;
        }
        // Pass 3: Quickshell's own fuzzy lookup, and LAST, because it is a
        // heuristic and what this decides is whether a program is started.
        // A wrong answer here is not a mislabelled row, it is someone's
        // editor opening because a script named itself after it.
        for (const c of cands) {
            const entry = DesktopEntries.heuristicLookup(c);
            if (entry)
                return entry;
        }
        return null;
    }

    // One candidate spelling reduced to something comparable: basename (icons
    // and desktop files arrive as paths), no .desktop, no image extension,
    // lowercased. Empty for anything that is not a usable string.
    function entryKey(v) {
        if (typeof v !== "string" || v.length === 0)
            return "";
        return v.split("/").pop()
            .replace(/\.desktop$/i, "")
            .replace(/\.(png|svg|xpm|ico|jpe?g|gif)$/i, "")
            .trim().toLowerCase();
    }

    // ── Click a notification: go to the app that sent it ───────────────
    //
    // A notification is a message ABOUT a window, so acting on it by raising
    // that window is the obvious thing for it to do. "Go to the app" has two
    // answers, though, and only one of them used to be handled: the app is
    // open and gets focused, or the app is CLOSED and gets OPENED. The second
    // is not a corner case -- a mail client that is not running still gets to
    // tell you it has mail, and its card used to answer a click with silence.
    //
    // Returns what it actually did -- "focused", "launched" or "none" -- so
    // the diagnostics IPC `focus` can say it, which is how this is checked
    // without a mouse.
    //
    // The dispatch pair is the one the rest of the shell uses and the only
    // one this Hyprland build answers: `hl.dsp.focus({ workspace = N })`
    // first -- focusing a window on another workspace is a silent no-op --
    // and then the window itself.
    function focusSender(notif) {
        if (!notif) return "none";
        // Resolve against the LIVE notification when there is one, because a
        // notification restored from the history file has no desktopEntry to
        // read (see the `dump` handler below for the same trap). A tray app
        // that has been parked is brought back FIRST, for the reason in
        // `attemptInvokeAction`: its window is on `special:tray`, and
        // focusing that focuses nothing the user can see.
        const cls = root.senderClass(notif);
        if (cls !== "" && TrayApps.isHidden(cls))
            TrayApps.show(cls);
        const wins = (HyprlandData.windowList || []).filter((w) => w.class === cls);
        if (wins.length === 0) {
            // Nothing on screen to raise, so open the app instead.
            //
            // Through GlobalStates.launchEntry, NOT entry.execute(): that is
            // the shell's one launch choke point, and it is what makes this
            // launch indistinguishable from one off the app menu -- same
            // open.sh, same tray `allow` for the close-to-tray apps, same pid
            // record the compositor reads to tell a launcher window from a
            // popup someone else opened, same "starting" card while it comes
            // up. A second launch mechanism here would be a second set of
            // those behaviours, and the ones that would go missing are
            // exactly the ones that are invisible until they are wrong.
            const entry = root.senderEntry(notif);
            if (entry) {
                console.log("[Notifications] No window for sender: " + (cls || notif.appName)
                    + " -- opening " + (entry.id || entry.name));
                GlobalStates.launchEntry(entry);
                return "launched";
            }
            console.log("[Notifications] No window and no desktop entry for sender: " + (cls || notif.appName));
            return "none";
        }
        // Prefer a window already on the workspace being looked at: switching
        // to another workspace to get a second window of an app that has one
        // here is the wrong answer to "take me there".
        const active = HyprlandData.activeWorkspace?.id;
        const here = wins.find((w) => w.workspace && w.workspace.id === active);
        const target = here || wins[0];
        // The switch runs through the SAME dispatcher every other desktop
        // change uses (the keybinds, the overview, the swipes), so it plays the
        // same transition: with animations on, `hl.dsp.focus({workspace})`
        // slides the desktops with the config's own `workspaces` motion
        // instead of cutting. Nothing extra is needed here to make the jump
        // animated -- it is animated because it is not a special case.
        //
        // A window already on the VISIBLE desktop has no switch to play: the
        // compositor raises it where it stands, and a z-order change is not
        // something it can animate. That case looks the way it always has.
        if (target.workspace && target.workspace.id >= 0)
            Hyprland.dispatch(`hl.dsp.focus({ workspace = ${target.workspace.id} })`);
        const addr = String(target.address || "");
        if (addr.length > 0)
            Hyprland.dispatch(`hl.dsp.focus({ window = "address:${addr}" })`);
        return "focused";
    }

    // Quickshell's notification IDs starts at 1 on each run, while saved notifications
    // can already contain higher IDs. This is for avoiding id collisions
    // ── A copied picture is not news, and does not keep ─────────────────────
    //
    // The shell's own notices ("Image copied", "Video copied · 0:12") carry a
    // file path and two buttons, and they exist for the one case where the
    // corner card was missed: going back for something seen a moment ago. Past
    // that they are clutter (asked for 2026-11-15: drop them five minutes after
    // they arrive, unless the panel was opened in the meantime).
    //
    // "Opened" is the whole condition. The moment the notification sidebar is up,
    // whatever is in it has been read, so the countdown stops mattering and the
    // entry stays until it is deleted by hand -- and that is also why the sweep
    // marks as well as deletes: with the panel on screen, the time limit is not
    // being run against anything.
    readonly property int saveableNoticeLifeMs: 5 * 60 * 1000

    function isSaveableNotice(entry) {
        return String(entry?.appName ?? "") === GlobalStates.saveableAppName;
    }

    function markSaveableNoticesSeen() {
        let changed = false;
        for (let i = 0; i < root.list.length; i++) {
            const entry = root.list[i];
            if (!root.isSaveableNotice(entry) || entry.seen)
                continue;
            entry.seen = true;
            changed = true;
        }
        // Not a rewrite of the archive: `seen` is about this session's panel
        // visit, and the file is rewritten on the next real change anyway.
        return changed;
    }

    function sweepSaveableNotices() {
        if (GlobalStates.sidebarRightOpen) {
            root.markSaveableNoticesSeen();
            return;
        }
        const cutoff = Date.now() - root.saveableNoticeLifeMs;
        for (let i = root.list.length - 1; i >= 0; i--) {
            const entry = root.list[i];
            if (!root.isSaveableNotice(entry) || entry.seen)
                continue;
            // `time` is milliseconds (set on arrival); an entry that somehow
            // has none is kept rather than swept on a guess.
            const at = Number(entry.time ?? 0);
            if (at <= 0 || at > cutoff)
                continue;
            root.discardNotification(entry.notificationId);
        }
    }

    Connections {
        target: GlobalStates
        function onSidebarRightOpenChanged() {
            if (GlobalStates.sidebarRightOpen)
                root.markSaveableNoticesSeen();
        }
    }

    // Once a minute, not once per notice: one sweep for the whole list, and it
    // costs nothing while there is nothing to sweep.
    Timer {
        interval: 60000
        repeat: true
        running: true
        onTriggered: root.sweepSaveableNotices()
    }

    // ── Notification sound ─────────────────────────────────────────────────
    //
    // The daemon had none: cards appeared in complete silence. That is the whole
    // story behind "I can't hear the Freebuff notification" while YouTube plays
    // fine -- the audio stack was never the problem (the sink is up and at 55%),
    // nothing in this shell ever asked for a sound to be played.
    //
    // REQUESTED (2026-11-19): "make sure the notification sound of every single
    // notification is being inputted with the new chime". So the sender's sound
    // hints are NOT consulted any more: `sound-file` (a file of the app's own),
    // `sound-name` (a file from the freedesktop theme) and `suppress-sound`
    // (Chromium-family apps set it -- the browser notifications were silent)
    // all used to produce a different sound or no sound at all, which read as
    // the desktop having several notification sounds. One chime, everywhere.
    //
    // Playing is Audio's job, not this file's: the mixer has a System Sounds
    // row, and that row works by handing a level to the player at spawn time.
    // Spawning here instead would mean this file had its own private, always
    // full-volume path that the row could not reach.
    // The shell's own copy, NOT the system message.oga. See the level note
    // below: the system file peaks at -5.9 dBFS, which is why the chime could
    // not be heard over music, and the only way to raise it is to raise the
    // SAMPLE -- the player cannot go past 100 %.
    //
    // The file is a three-step chime synthesised in assets/sounds/notify/ (see
    // generate.py): A4 - E5 - B5 (440 / 659 / 988 Hz), 80 ms apart, 260 ms in
    // total, peak -3 dBFS. It has no contact tick at all and its attack is a
    // 3.5 ms ramp, so a notification arrives as a soft three-note rise -- an
    // acceptance rather than an alert. Regenerating the sounds rewrites this
    // file from the take named CHOSEN in that script (notify-tone-warm-a).
    readonly property string defaultNotifSound: Quickshell.shellPath("assets/sounds/notification.wav")

    // ── How loud the chime is, and why the gain is 1.0 ──────────────────────
    //
    // REQUESTED (2026-10-23): "make the notification audio from apps louder
    // than the general music audio". That was first answered with a playback
    // factor of 1.8 on the system file -- and it never did anything: `pw-play
    // --volume` takes 0-1.0 and CLAMPS above it (measured 2026-10-26: a
    // --volume 1.8 stream comes up at 65536 / 100 %), so the chime played at
    // exactly the mixer row while the code claimed +5.1 dB. That is the
    // "music is too loud and the notifications are too quiet" report.
    //
    // Measured on the system file: message.oga peaked at -5.9 dBFS with an RMS
    // of -26.7 dB -- a soft, short drop (311 ms), and music (a full-scale
    // master, RMS around -10 dB) simply plays over it. A stream volume above
    // 100 % is not available to this player, so the level has to live in the
    // audio itself: the generated chime peaks at -3 dBFS. The louder .oga that
    // used to carry that level is gone -- the generated file carries it now,
    // and generate.py is the only thing that writes the sound.
    //
    // So the gain is 1.0 here, and the file carries the level -- which is also
    // why Volumes.qml's device click no longer asks for a factor above one.
    // The System Sounds row still multiplies this in every direction: at 0 or
    // muted nothing is spawned at all, and the sink applies its own volume to
    // the stream exactly as it does to music. This is a level for THIS sound,
    // not a way around the mixer.
    readonly property real notificationGain: 1.0

    // One comparable spelling of an app: the basename (identities arrive as
    // desktop-file ids and as icon paths), no file extension, lowercase, and
    // every run of punctuation or space collapsed to a single space. So
    // "WhatsApp Desktop", "whatsapp-linux-desktop" and "/usr/share/icons/.../
    // whatsapp.png" all become words that can be compared -- which is the
    // whole point, because none of those three spellings equals another and a
    // sender picks whichever it likes.
    //
    // Shared with the Settings page, which decides what the Mute switch means:
    // see NotificationUtils.normalizeAppIdentity.
    function identityText(value) {
        return NotificationUtils.normalizeAppIdentity(value);
    }

    // ── The two notices that keep their own sound ───────────────────────────
    //
    // Everything an APP sends gets the chime, whatever its hints say. These two
    // names are the shell speaking about itself, not an app notifying:
    //
    //   * a picture or a recording the SHELL copied already has its card in the
    //     top-right corner, and a chime for something the user did themselves
    //     -- a snip, a stopped take -- is noise (asked for 2026-11-15: "it
    //     shouldn't make the notification sound").
    //   * a drive going in plays its own click, which IS the sound of that
    //     gesture; adding the chime over it would be two sounds for one event
    //     (see Volumes.announce).
    readonly property var ownSoundAppNames: ["Shell", GlobalStates.saveableAppName]

    function playNotificationSound(notification) {
        if (!(Config?.options.notifications.sound ?? true)) return;
        // Do not disturb has to include the chime. A "quiet" switch that still
        // rings at every mail arrival is not quiet; the notification is still
        // collected in the sidebar, it just makes no noise.
        if (root.silent) return;
        const appName = String(notification?.appName ?? "");
        if (root.ownSoundAppNames.indexOf(appName) >= 0)
            return;
        // ── The chime is NOT a per-app setting ──────────────────────────────
        // REQUESTED (2026-11-19): "sound turned off drops the Notification of
        // the app and not the PC chime". Muting an app is about the app's own
        // notification -- and whatever sound comes with it -- never about this
        // desktop's sound: one chime, every app, always.
        // Detached, not a tracked Process: a tracked one cannot be restarted
        // while it is still running, so a second notification arriving while
        // the first was still playing was silently dropped.
        Audio.playSystemSoundFile(root.defaultNotifSound, root.notificationGain);
    }

    // ── Per-app mute ────────────────────────────────────────────────────
    //
    // REQUESTED (2026-11-13): "allow me to manually mute notifications of
    // certain apps", with a way to see what each app was allowed and what it
    // was blocked from.
    //
    // A muted app gets no popup and no card in the notification centre -- the
    // two things a notification IS here -- and the sender is dismissed, so the
    // app's own notice (and the default chime it plays with it) never lands.
    // The CHIME still plays: asked for 2026-11-19, "turn the notification off
    // for that app but keep the notification sound from the PC working" and
    // again as "sound turned off drops the Notification of the app and not the
    // PC chime" -- hiding an app's notifications must not take the desktop's
    // own sound with it. This is the only per-app sound switch there is: the
    // shell cannot reach into a running app to silence audio it plays itself,
    // so "this app's sound is off" is honoured by not delivering the app's
    // notification at all, which is what its sound belongs to.
    //
    // It is not dropped silently, though: `recordApp` counts it, so the
    // Settings page can say "12 blocked" and show the last summary it
    // swallowed, which is the difference between "muted" and "broken" when a
    // mail client goes quiet.
    //
    // DND (`silent`, above) is still the whole-desktop switch; this is per app
    // and persists in the config file.
    readonly property var mutedApps: Config?.options.notifications.mutedApps ?? []

    // Every spelling this sender answers to, including the window class the
    // tray registry resolves -- the class is the one identity that survives a
    // sender with a localised or truncated name (see senderClass).
    function identitiesOf(appName, desktopEntry, appIcon) {
        const list = [appName, desktopEntry, appIcon];
        const cls = TrayApps.classForNotification({
            appName: appName,
            desktopEntry: desktopEntry,
            appIcon: appIcon,
        });
        if (cls && cls.length > 0)
            list.push(cls);
        return list;
    }

    function isMuted(appName, desktopEntry, appIcon) {
        return NotificationUtils.isIdentityMuted(
            root.identitiesOf(appName, desktopEntry, appIcon), root.mutedApps);
    }

    function isAppMuted(appName) {
        return NotificationUtils.isIdentityMuted([appName], root.mutedApps);
    }

    function setAppMuted(appName, muted) {
        Config.options.notifications.mutedApps = NotificationUtils.withAppMuted(
            root.mutedApps, appName, muted);
        return Config.options.notifications.mutedApps;
    }

    // ── Per-app sound: the APP's sound, not this desktop's ───────────────
    //
    // REQUESTED (2026-11-19): "I want to see the notification but not hear the
    // desktop app sound and only hear the PC chime with the notification".
    // The first attempt got this backwards twice: it silenced the shell's own
    // chime, then it dropped the app's notification. Neither is the sound the
    // user is complaining about -- apps like Discord and WhatsApp play their
    // own notification sound themselves, entirely outside the notification
    // daemon, so a notification hint cannot reach it and blocking the
    // notification does not stop it either.
    //
    // What IS reachable is their audio: every playing program owns a PipeWire
    // stream. An app on this list has its streams muted for the couple of
    // seconds around its notification (scripts/audio/
    // silence-app-notification-sound.py), which takes its default chime and
    // leaves the popup, the card and this desktop's chime exactly as they are.
    //
    // Only the app's own streams are touched, and only unmuted ones, so a mute
    // set in the mixer survives.
    readonly property var soundMutedApps: Config?.options.notifications.soundMutedApps ?? []

    function isAppSoundMuted(appName, desktopEntry, appIcon) {
        return NotificationUtils.isIdentityMuted(
            root.identitiesOf(appName, desktopEntry, appIcon), root.soundMutedApps);
    }

    function setAppSoundMuted(appName, muted) {
        Config.options.notifications.soundMutedApps = NotificationUtils.withAppMuted(
            root.soundMutedApps, appName, muted);
        return Config.options.notifications.soundMutedApps;
    }

    // How long the app's audio is muted as its notification lands. Long enough
    // to swallow a default chime (a few hundred ms) and not one second more:
    // the same streams carry its calls, its music and the video it is playing.
    readonly property string appSoundSilenceSeconds: "2"

    function silenceOwnAppSound(notification) {
        if (!notification)
            return false;
        const appName = String(notification.appName ?? "");
        const desktopEntry = String(notification.desktopEntry ?? "");
        const appIcon = String(notification.appIcon ?? "");
        if (!root.isAppSoundMuted(appName, desktopEntry, appIcon))
            return false;
        console.log("[Notifications] silencing the app's own sound: " + appName);
        const identities = root.identitiesOf(appName, desktopEntry, appIcon)
            .map((identity) => String(identity ?? "").trim())
            .filter((identity) => identity.length > 0);
        // Detached: the helper lives for its whole window and this must not
        // block the daemon (or be cancelled by a second notification).
        Quickshell.execDetached(["python3",
            Quickshell.shellPath("scripts/audio/silence-app-notification-sound.py"),
            root.appSoundSilenceSeconds].concat(identities));
        return true;
    }

    // ── What each app was allowed, and what was blocked ─────────────────
    //
    // Keyed by normalized identity, and PERSISTED, because the Settings page is
    // a separate process: it cannot read this singleton's memory, only
    // `${cache}/notifications/apps.json`. Counts survive a shell restart for the
    // same reason -- a tally that reset on every reload would answer "allowed"
    // with 0 for everything every morning.
    readonly property int appStatsMax: 60
    property var appStats: ({})

    function recordApp(appName, appIcon, summary, outcome) {
        const key = root.identityText(appName ?? "");
        if (key.length === 0)
            return;
        const prev = root.appStats[key] ?? {
            name: appName ?? "",
            appIcon: "",
            allowed: 0,
            blocked: 0,
            lastSummary: "",
            lastTime: 0,
        };
        const next = Object.assign({}, prev);
        next.name = appName ?? prev.name;
        if (typeof appIcon === "string" && appIcon.length > 0)
            next.appIcon = appIcon;
        if (outcome === "blocked")
            next.blocked = (prev.blocked ?? 0) + 1;
        else
            next.allowed = (prev.allowed ?? 0) + 1;
        next.lastSummary = summary ?? "";
        next.lastTime = Date.now();
        next.lastOutcome = outcome;
        next.muted = root.isAppMuted(appName ?? "");

        const merged = Object.assign({}, root.appStats);
        merged[key] = next;
        // Bounded: the file is a tally for the Settings page, not an archive of
        // every app that has ever spoken to this desktop.
        const keys = Object.keys(merged);
        if (keys.length > root.appStatsMax) {
            keys.sort((a, b) => (merged[a].lastTime || 0) - (merged[b].lastTime || 0));
            for (const k of keys.slice(0, keys.length - root.appStatsMax))
                delete merged[k];
        }
        root.appStats = merged;
        root.saveAppStats();
    }

    function saveAppStats() {
        appsFileView.setText(JSON.stringify(root.appStats, null, 2));
    }

    // The apps that were already in the notification history when this feature
    // first ran still deserve a row: without this, the page would open empty on
    // a machine that has been receiving notifications for months.
    function seedAppStatsFromList() {
        const merged = Object.assign({}, root.appStats);
        let changed = false;
        root.list.forEach((notif) => {
            if (notif.isSignal)
                return;
            const key = root.identityText(notif.appName ?? "");
            if (key.length === 0 || merged[key])
                return;
            merged[key] = {
                name: notif.appName ?? "",
                appIcon: notif.appIcon ?? "",
                allowed: 1,
                blocked: 0,
                lastSummary: notif.summary ?? "",
                lastTime: notif.time ?? 0,
                lastOutcome: "allowed",
                muted: root.isAppMuted(notif.appName ?? ""),
            };
            changed = true;
        });
        if (changed) {
            root.appStats = merged;
            root.saveAppStats();
        }
    }

    property int idOffset
    signal initDone();
    signal notify(notification: var);
    signal discard(id: int);
    signal discardAll();
    signal timeout(id: var);

	NotificationServer {
        id: notifServer
        // actionIconsSupported: true
        actionsSupported: true
        bodyHyperlinksSupported: true
        bodyImagesSupported: true
        bodyMarkupSupported: true
        bodySupported: true
        imageSupported: true
        keepOnReload: false
        persistenceSupported: true

        onNotification: (notification) => {
            notification.tracked = true
            // ── A muted app stops here ─────────────────────────────────
            //
            // Counted, chime, then dismissed: no popup and no card, but the
            // PC's notification sound still plays for this app (muting its
            // banners must not take the sound with it). The sender is told the
            // notification is gone (dismiss watches the DBus
            // NotificationClosed signal) instead of being left to believe a
            // card is waiting to be read.
            // The app's own sound goes first, before any branch can return:
            // whether the notification is shown or muted, an app whose sound
            // is switched off must not be heard while its notification lands.
            root.silenceOwnAppSound(notification);
            if (root.isMuted(notification.appName ?? "", notification.desktopEntry ?? "", notification.appIcon ?? "")) {
                root.recordApp(notification.appName, notification.appIcon, notification.summary, "blocked");
                root.playNotificationSound(notification);
                notification.dismiss();
                return;
            }
            root.recordApp(notification.appName, notification.appIcon, notification.summary, "allowed");
            root.playNotificationSound(notification);
            const newNotifObject = notifComponent.createObject(root, {
                "notificationId": notification.id + root.idOffset,
                "notification": notification,
                "time": Date.now(),
            });
			root.list = [...root.list, newNotifObject];

			// Remembered before anything can dismiss it. A transient is
			// feedback and a signal is the clipboard's own card, so neither
			// belongs in a history of notifications.
			if (!newNotifObject.isTransient && !newNotifObject.isSignal)
				root.archive(newNotifObject);

            // ── Our own saveable notices skip the popup ────────────────
            //
            // A copied picture and a finished recording already speak through the
            // top-right card; a second popup in the corner for the same event is
            // noise. What the panel adds is the part the card cannot: it keeps the
            // notice, and the file's path with it, so it can still be saved later.
            const saveable = String(notification.appName ?? "") === GlobalStates.saveableAppName;

            // Popup
            if (!root.popupInhibited && !saveable) {
                newNotifObject.popup = true;
                // ALWAYS armed, where this used to be skipped entirely for
                // `expireTimeout: 0`. Skipping it is what let a "never
                // expire" notification sit in the corner indefinitely, which
                // the ceiling above exists to prevent. `popupIntervalFor`
                // turns that request into `popupMaxMs` rather than obeying it.
                newNotifObject.timer = notifTimerComponent.createObject(root, {
                    "notificationId": newNotifObject.notificationId,
                    "interval": root.popupIntervalFor(notification.expireTimeout),
                });
                // A transient is feedback, not something unread: it never
                // lands in the history, so the bell must not count it.
                if (!newNotifObject.isTransient) root.unread++;
            }
            // A transient that never popped is never anything at all: with no
            // popup no timer was armed either, so it would sit in the list
            // forever. Discard it now -- discard also dismisses the
            // server-side notification and writes the file without it -- and
            // skip the emit/write below, which it would otherwise duplicate.
            if (newNotifObject.isTransient && !newNotifObject.popup) {
                root.discardNotification(newNotifObject.notificationId);
                return;
            }
            root.notify(newNotifObject);
            // console.log(notifToString(newNotifObject));
            notifFileView.setText(stringifyList(root.list));
        }
    }

    function markAllRead() {
        root.unread = 0;
    }

    function discardNotification(id) {
        console.log("[Notifications] Discarding notification with ID: " + id);
        const index = root.list.findIndex((notif) => notif.notificationId === id);
        const notifServerIndex = notifServer.trackedNotifications.values.findIndex((notif) => notif.id + root.idOffset === id);
        if (index !== -1) {
            root.list.splice(index, 1);
            notifFileView.setText(stringifyList(root.list));
            triggerListChange()
        }
        if (notifServerIndex !== -1) {
            notifServer.trackedNotifications.values[notifServerIndex].dismiss()
        }
        root.discard(id); // Emit signal
    }

    function discardAllNotifications() {
        root.list = []
        triggerListChange()
        notifFileView.setText(stringifyList(root.list));
        notifServer.trackedNotifications.values.forEach((notif) => {
            notif.dismiss()
        })
        root.discardAll();
    }

    function cancelTimeout(id) {
        const index = root.list.findIndex((notif) => notif.notificationId === id);
        if (root.list[index] != null)
            root.list[index].timer.stop();
    }

    function timeoutNotification(id) {
        const index = root.list.findIndex((notif) => notif.notificationId === id);
        if (root.list[index] != null)
            root.list[index].popup = false;
        root.timeout(id);
    }

    function timeoutAll() {
        root.popupList.forEach((notif) => {
            root.timeout(notif.notificationId);
        })
        root.popupList.forEach((notif) => {
            notif.popup = false;
        });
    }

    function attemptInvokeAction(id, notifIdentifier) {
        console.log("[Notifications] Attempting to invoke action with identifier: " + notifIdentifier + " for notification ID: " + id);
        const notifServerIndex = notifServer.trackedNotifications.values.findIndex((notif) => notif.id + root.idOffset === id);
        console.log("Notification server index: " + notifServerIndex);
        if (notifServerIndex !== -1) {
            const notifServerNotif = notifServer.trackedNotifications.values[notifServerIndex];
            const action = notifServerNotif.actions.find((action) => action.identifier === notifIdentifier);
            // console.log("Action found: " + JSON.stringify(action));

            // ── Tray apps come back before their action runs ────────────
            //
            // Invoking an action makes the SENDER raise one of its own
            // windows. For an app the tray is holding, that window is on
            // `special:tray`, off screen: Thunderbird gets new mail, the
            // notification arrives and is perfectly readable, the user
            // clicks "Open", and Thunderbird focuses a window nobody can
            // see. The notification was never the broken part.
            //
            // So if the sender is a tray app and it is currently parked,
            // it is restored FIRST, on the ordinary restore path (the same
            // verified state machine a click on the tray icon uses), and
            // only then does the action run against a window that is
            // actually on a desktop.
            //
            // Deliberately not done for a VISIBLE tray app: `isHidden`
            // asks whether every window of the class is parked, so an app
            // on screen is left strictly alone and its own activation
            // behaves exactly as it did before.
            const cls = TrayApps.classForNotification(notifServerNotif);
            if (cls !== "" && TrayApps.isHidden(cls)) {
                console.log("[Notifications] Restoring tray app from the vault before invoking: " + cls);
                TrayApps.show(cls);
            }

            action.invoke()
        } 
        else {
            console.log("Notification not found in server: " + id)
        }
        root.discardNotification(id);
    }

    function triggerListChange() {
        root.list = root.list.slice(0)
    }

    function refresh() {
        notifFileView.reload()
    }

    Component.onCompleted: {
        refresh()
    }

    FileView {
        id: notifFileView
        path: Qt.resolvedUrl(filePath)
        onLoaded: {
            const fileContents = notifFileView.text()
            root.list = JSON.parse(fileContents).map((notif) => {
                return notifComponent.createObject(root, {
                    "notificationId": notif.notificationId,
                    "actions": [], // Notification actions are meaningless if they're not tracked by the server or the sender is dead
                    "appIcon": notif.appIcon,
                    "appName": notif.appName,
                    "body": notif.body,
                    "image": notif.image,
                    "summary": notif.summary,
                    "time": notif.time,
                    "urgency": notif.urgency,
                });
            });
            // Find largest notificationId
            let maxId = 0
            root.list.forEach((notif) => {
                maxId = Math.max(maxId, notif.notificationId)
            })

            console.log("[Notifications] File loaded")
            root.idOffset = maxId
            root.seedAppStatsFromList()
            root.initDone()
        }
        onLoadFailed: (error) => {
            if(error == FileViewError.FileNotFound) {
                console.log("[Notifications] File not found, creating new file.")
                root.list = []
                notifFileView.setText(stringifyList(root.list));
            } else {
                console.log("[Notifications] Error loading file: " + error)
            }
        }
    }

    // The per-app tally the Settings page reads. Separate from the notification
    // file above: that one is what the centre draws and is rewritten on every
    // dismiss, this one only changes when an app's counts do.
    FileView {
        id: appsFileView
        path: Qt.resolvedUrl(Directories.notificationsAppsPath)
        onLoaded: {
            let loaded = {};
            try {
                loaded = JSON.parse(appsFileView.text()) ?? {};
            } catch (e) {
                loaded = {};
            }
            // In-memory entries win: they are newer than the file (an event may
            // have been recorded before this load finished).
            const merged = Object.assign({}, loaded);
            for (const key of Object.keys(root.appStats))
                merged[key] = Object.assign({}, loaded[key] ?? {}, root.appStats[key]);
            root.appStats = merged;
        }
        onLoadFailed: (error) => {
            if (error === FileViewError.FileNotFound) {
                console.log("[Notifications] No app tally yet, creating one.")
                root.appStats = ({});
                root.saveAppStats();
            }
        }
    }

    // ── Diagnostics ──────────────────────────────────────────────────────
    //
    // `qs -c ii ipc call notifications dump` answers the only question
    // that matters about a tray-held app: did its notification actually
    // arrive, and can the shell tell which app it belongs to. The second
    // half is the one that is easy to get wrong and impossible to see --
    // `classForNotification` matches on `appName`/`desktopEntry`/
    // `appIcon`, and whether a real notification carries the field that
    // matches is not something to assume.
    IpcHandler {
        target: "notifications"

        function dump(): string {
            if (root.list.length === 0)
                return "no notifications held";
            return root.list.map(n => {
                // The WRAPPER's fields, not the live notification's. A
                // notification restored from the history file has no live
                // object behind it at all -- `n.notification` is null --
                // so resolving against it reports "no match" for every
                // notification the shell is actually holding, which is
                // the opposite of what this is for. `appName` and
                // `appIcon` are stored with the entry, and those are
                // exactly the two fields the resolver needs.
                const cls = TrayApps.classForNotification({
                    appName: n.appName,
                    desktopEntry: n.notification ? n.notification.desktopEntry : "",
                    appIcon: n.appIcon
                });
                return `app="${n.appName}" live=${n.notification ? "yes" : "no "} icon=${(n.appIcon || "-").slice(0, 48)} -> tray=${cls === "" ? "-" : cls} hidden=${cls === "" ? "-" : TrayApps.isHidden(cls)}`;
            }).join("\n");
        }

        // What the lists actually draw now: one card per notification, newest
        // first. Readable over IPC because the click-to-focus handler is
        // impossible to exercise from here -- ydotool does not reach this
        // compositor, so `focus` below drives the very function the card
        // calls rather than a copy of it.
        // `notifications dnd` -- the whole-desktop switch as the shell sees
        // it: the setting, its deadline, and whether that deadline has already
        // passed. The last field is the point -- enforcement and the deadline
        // are two different pieces, and reading them apart is how a switch that
        // silently stopped expiring would be noticed.
        function dnd(): string {
            return `on=${root.dndOn} durationMin=${root.dndDurationMin}`
                + ` until=${Math.round(root.dndUntil)}`
                + ` remainingMs=${Math.round(root.dndRemainingMs)}`
                + ` silent=${root.silent}`;
        }

        function cards(): string {
            return `list=${root.list.length} grouped=${root.appNameList.length} cards=${root.flatCards.length}\n`
                + root.flatCards.map((c, i) =>
                    `${i}: app="${c.appName}" n=${c.notifications.length} id=${c.notifications[0].notificationId} time=${c.time} "${(c.notifications[0].summary || "").slice(0, 40)}"`).join("\n");
        }

        // `notifications focus <id>` -- the click handler's exact path.
        //
        // Reports which of the two answers it took. `launched` is the case
        // that used to report "no window" and mean "nothing happened";
        // `none` is now the honest one for a sender with neither a window nor
        // a desktop entry, which is a notification from something that
        // cannot be opened at all.
        function focus(id: string): string {
            const n = root.list.find((x) => String(x.notificationId) === String(id));
            if (!n)
                return `no notification with id ${id}`;
            const result = root.focusSender(n);
            const entry = root.senderEntry(n);
            return `focusSender(${id}) app="${n.appName}" cls=${root.senderClass(n) || "(none)"}`
                + ` entry=${entry ? (entry.id || entry.name) : "(none)"} -> ${result}`;
        }

        // `notifications clear` -- the same call the sidebar's "Clear all"
        // makes, available from a script.
        //
        // Added with the popup layout check: producing a stack of test cards
        // is the only way to see whether they collide, and a run of them is
        // also 30-odd rows in the user's own history afterwards. Tests have
        // to be able to leave the shell as they found it.
        // `notifications historyDump` -- exactly what the rewind view draws.
        // The view is only reachable by a click that cannot be delivered to
        // this compositor from a script, so this is the same data, in words.
        function historyDump(): string {
            if (root.history.length === 0)
                return "history empty";
            return `${root.history.length}/${root.historyMax} remembered\n`
                + root.historyNewestFirst.map((n, i) =>
                    `${i}: app="${n.appName}" time=${n.time} "${(n.summary || "").slice(0, 40)}"`).join("\n");
        }

        // `notifications apps` -- every app this daemon has seen, what it was
        // allowed and blocked, and whether it is muted right now. The mute
        // switch lives in another process (the settings app), so this is how
        // the daemon side is checked without a mouse.
        function apps(): string {
            const keys = Object.keys(root.appStats);
            if (keys.length === 0)
                return "no apps recorded";
            keys.sort((a, b) => (root.appStats[b].lastTime || 0) - (root.appStats[a].lastTime || 0));
            return `muted=${root.mutedApps.length ? root.mutedApps.join(", ") : "(none)"}\n`
                + `app sound off=${root.soundMutedApps.length ? root.soundMutedApps.join(", ") : "(none)"}\n`
                + keys.map((k) => {
                    const s = root.appStats[k];
                    return `${s.name}${root.isAppMuted(s.name) ? " [muted]" : ""}: allowed=${s.allowed ?? 0} blocked=${s.blocked ?? 0} last=\"${(s.lastSummary || "").slice(0, 40)}\"`;
                }).join("\n");
        }

        // `notifications mute <appName> <true|false>` -- the switch, from a
        // script. Writes the same config key the Settings page writes.
        function mute(appName: string, muted: string): string {
            const on = String(muted).toLowerCase() === "true" || String(muted) === "1";
            const list = root.setAppMuted(appName, on);
            return `${appName} -> ${on ? "muted" : "allowed"}; muted list: ${list.length ? list.join(", ") : "(none)"}`;
        }

        function clear(): string {
            const had = root.list.length;
            root.discardAllNotifications();
            return `cleared ${had} notification(s)`;
        }

        // Resolves a notifier's identity without a real notification,
        // against whatever strings a sender is likely to publish.
        function resolve(appName: string, desktopEntry: string, appIcon: string): string {
            const cls = TrayApps.classForNotification({
                appName: appName,
                desktopEntry: desktopEntry,
                appIcon: appIcon
            });
            return `${appName} / ${desktopEntry} / ${appIcon} -> ${cls === "" ? "(no match)" : cls}`;
        }

        // `notifications sound <appName> [desktopEntry] [appIcon]` -- what a
        // notification from this sender would sound like, without sending one.
        //
        // Every app gets the same chime, and nothing per-app can take it away.
        // What a sender can have taken away is its OWN sound, by muting its
        // audio streams around the notification -- so that is what is printed.
        function sound(appName: string, desktopEntry: string, appIcon: string): string {
            const id = `${appName} / ${desktopEntry || "-"} / ${appIcon || "-"}`;
            const own = root.isAppSoundMuted(appName, desktopEntry, appIcon)
                ? `the app's own sound is muted for ${root.appSoundSilenceSeconds}s as its notification lands`
                : "the app's own sound is left alone";
            return `${id} -> shell chime at ${root.notificationGain}x row ${Audio.systemSoundVolume().toFixed(3)}; ${own}`;
        }

        // `notifications appSound <appName> <true|false>` -- the switch, from a
        // script. Writes the same config key the Settings page and the launcher
        // menu write.
        function appSound(appName: string, muted: string): string {
            const on = String(muted).toLowerCase() === "true" || String(muted) === "1";
            const list = root.setAppSoundMuted(appName, on);
            return `${appName} -> app sound ${on ? "off" : "on"}; list: ${list.length ? list.join(", ") : "(none)"}`;
        }
    }
}

