pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import qs
import qs.services
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

    property bool silent: false
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
    // ── Notification sound ─────────────────────────────────────────────────
    //
    // The daemon had none: cards appeared in complete silence. That is the whole
    // story behind "I can't hear the Freebuff notification" while YouTube plays
    // fine -- the audio stack was never the problem (the sink is up and at 55%),
    // nothing in this shell ever asked for a sound to be played.
    //
    // The file comes from the freedesktop sound theme and is played through
    // PipeWire. The notification itself gets the final say, as the spec intends:
    // an explicit `sound-file` hint is played, `suppress-sound` (Chromium-family
    // apps set it) or `sound-name: "silent"` keeps it quiet, and a `sound-name`
    // is used when the theme actually has that sound.
    //
    // Playing is Audio's job, not this file's: the mixer has a System Sounds
    // row, and that row works by handing a level to the player at spawn time.
    // Spawning here instead would mean this file had its own private, always
    // full-volume path that the row could not reach.
    // The shell's own copy, NOT the system message.oga. See the level note
    // below: the system file peaks at -5.9 dBFS, which is why the chime could
    // not be heard over music, and the only way to raise it is to raise the
    // SAMPLE -- the player cannot go past 100 %.
    readonly property string defaultNotifSound: Quickshell.shellPath("assets/sounds/notification.oga")

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
    // Measured on the system file: message.oga peaks at -5.9 dBFS with an RMS
    // of -26.7 dB -- a soft, short drop (311 ms), and music (a full-scale
    // master, RMS around -10 dB) simply plays over it. A stream volume above
    // 100 % is not available to this player, so the level has to live in the
    // audio itself: assets/sounds/notification.oga is that same chime at
    // +4.9 dB, peaking at -0.9 dBFS with an RMS of -21.7 dB. That is the most
    // that can be given to it without clipping, and it is ~5 dB above where
    // the chime used to play.
    //
    // So the gain is 1.0 here, and the file carries the level -- which is also
    // why Volumes.qml's device click no longer asks for a factor above one.
    // The System Sounds row still multiplies this in every direction: at 0 or
    // muted nothing is spawned at all, and the sink applies its own volume to
    // the stream exactly as it does to music. This is a level for THIS sound,
    // not a way around the mixer.
    readonly property real notificationGain: 1.0

    // ── Apps that sound their own notifications ─────────────────────────────
    //
    // REQUESTED (2026-10-23): "have notification sound not play if the app
    // making that notification has a sound of its own (like discord or
    // whatsapp)". Those apps chime themselves the moment a message lands, so
    // the shell's chime there is not an announcement in a silence -- it is a
    // SECOND sound, a beat late, over the app's own, which reads as the
    // desktop duplicating every message.
    //
    // The spec has a way to say "I make my own noise" (`sound-name: "silent"`
    // and `suppress-sound`, both honoured above), but Discord and WhatsApp
    // publish neither: they assume the notification daemon is quiet, which is
    // what a desktop normally is. So this is a list of names, and it has to
    // be: what an app does with its audio is invisible from outside, no sender
    // publishes an "I already played something" field, and the decision has
    // to be made before the chime starts rather than after. Everything not
    // named here keeps the shell's chime.
    //
    // The consequence, stated so it is not a surprise: an app that is in this
    // list AND whose own notification sound is switched off in that app will
    // be silent here too. That is the trade the request asks for -- one sound
    // per message -- and the app's own setting is the one place to change it.
    readonly property var selfSoundingApps: [
        // Discord and the clients built on it
        "discord", "discordcanary", "discordptb", "vesktop", "equibop", "armcord", "legcord", "webcord",
        // WhatsApp, however its Linux client spells itself
        "whatsapp", "whatsie", "whatsdesk",
        // messengers that chime for a message themselves
        "telegram", "slack", "signal", "mattermost", "viber", "zulip",
        // messenger aggregators, which bring their apps' sounds with them
        "ferdium", "rambox", "franz",
        // and the two non-chat ones with a notification sound on by default
        "steam", "thunderbird"
    ]

    // One comparable spelling of an app: the basename (identities arrive as
    // desktop-file ids and as icon paths), no file extension, lowercase, and
    // every run of punctuation or space collapsed to a single space. So
    // "WhatsApp Desktop", "whatsapp-linux-desktop" and "/usr/share/icons/.../
    // whatsapp.png" all become words that can be compared -- which is the
    // whole point, because none of those three spellings equals another and a
    // sender picks whichever it likes.
    function identityText(value) {
        if (typeof value !== "string" || value.length === 0)
            return "";
        return value.split("/").pop()
            .replace(/\.desktop$/i, "")
            .replace(/\.(png|svg|xpm|ico|jpe?g|gif)$/i, "")
            .toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
    }

    readonly property var selfSoundingTokens: root.selfSoundingApps.map((a) => root.identityText(a))

    // Does this sender play its own notification sound? Checked against every
    // spelling the notification carries, plus the window class the tray
    // registry resolves -- the class is the one identity that survives a
    // sender with a localised or truncated name (see senderClass).
    function appSoundsItself(appName, desktopEntry, appIcon) {
        const texts = [];
        const add = (v) => {
            const t = root.identityText(v);
            if (t.length > 0 && texts.indexOf(t) < 0)
                texts.push(t);
        };
        add(appName);
        add(desktopEntry);
        add(appIcon);
        add(TrayApps.classForNotification({
            appName: appName,
            desktopEntry: desktopEntry,
            appIcon: appIcon,
        }));
        for (const text of texts) {
            for (const token of root.selfSoundingTokens) {
                if (token.length === 0) continue;
                // Whole word, not substring: "discord" must match "discord"
                // and "discord canary", and must not match a longer app name
                // that merely contains it.
                if (new RegExp("(^| )" + token + "( |$)").test(text))
                    return true;
            }
        }
        return false;
    }

    function playNotificationSound(notification) {
        if (!(Config?.options.notifications.sound ?? true)) return;
        const hints = notification?.hints ?? {};
        if (hints["suppress-sound"] === true) return;
        const name = hints["sound-name"] ?? "";
        if (name === "silent") return;
        // The app makes the announcement itself; a second chime over it is the
        // duplication this exists to stop. See selfSoundingApps.
        if (root.appSoundsItself(notification?.appName ?? "",
                notification?.desktopEntry ?? "", notification?.appIcon ?? "")) {
            console.log("[Notifications] " + (notification?.appName ?? "?")
                + " sounds its own notifications -- no chime");
            return;
        }
        const file = hints["sound-file"];
        let target = "";
        // A sound the SENDER chose is played at the row's own level: it picked
        // that file for its own balance, and the gain below is about making
        // this session's soft default chime survive a music bed.
        let gain = 1.0;
        if (typeof file === "string" && file.length > 0) {
            target = file;
        } else if (typeof name === "string" && name.length > 0) {
            target = "/usr/share/sounds/freedesktop/stereo/" + name + ".oga";
        }
        if (target.length === 0) {
            target = root.defaultNotifSound;
            gain = root.notificationGain;
        }
        // Detached, not a tracked Process: a tracked one cannot be restarted
        // while it is still running, so a second notification arriving while
        // the first was still playing was silently dropped.
        Audio.playSystemSoundFile(target, gain);
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
            root.playNotificationSound(notification);
            const newNotifObject = notifComponent.createObject(root, {
                "notificationId": notification.id + root.idOffset,
                "notification": notification,
                "time": Date.now(),
            });
			root.list = [...root.list, newNotifObject];

            // Popup
            if (!root.popupInhibited) {
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
        // Whether a chime is silenced by an app's own sound is invisible from
        // the outside: both answers look like "a card appeared". This answers
        // it in words, and it goes through the very function the daemon calls,
        // so a green answer here is the behaviour rather than a copy of it.
        function sound(appName: string, desktopEntry: string, appIcon: string): string {
            const own = root.appSoundsItself(appName, desktopEntry, appIcon);
            const id = `${appName} / ${desktopEntry || "-"} / ${appIcon || "-"}`;
            if (own)
                return `${id} -> app sounds its own notification, no shell chime`;
            return `${id} -> shell chime at ${root.notificationGain}x row ${Audio.systemSoundVolume().toFixed(3)}`;
        }
    }
}
