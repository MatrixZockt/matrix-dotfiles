// Settings > Notifications.
//
// Two questions, one page: "may this app notify me?" and "what has it actually
// been doing?" -- the mute switch and the tally that proves the switch works.
// On top of both sits the whole-desktop switch, Do not disturb.
//
// The mute itself is enforced in services/Notifications.qml, in the SHELL
// process; this page is the settings app, a different process, so nothing here
// can call the daemon. The two meet at the config file (`notifications.*`),
// which the shell watches, so a toggle takes effect on the next notification
// without a restart. The daemon's tally (`$XDG_CACHE_HOME/notifications/
// apps.json`, see Directories.notificationsAppsPath) is the read-only half.
//
// Both sides reduce an app to the same normalized identity
// (NotificationUtils.normalizeAppIdentity), because one app spells itself three
// ways: display name, desktop entry, icon path.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import qs.services // Translation
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.functions as CF
import qs.modules.common.widgets

ContentPage {
    id: root
    forceWidth: true

    // ── What the daemon recorded ────────────────────────────────────────
    // Keyed by normalized identity: { name, appIcon, allowed, blocked,
    // lastSummary, lastTime }.
    property var appStats: ({})

    // Apps that are already in the notification history but predate the tally
    // (or whose entry was trimmed). Without them the page would open empty on a
    // machine that has been receiving notifications for months.
    property var historyApps: ({})

    // The app filter. Substring, case-insensitive: this list is scanned by
    // name, not ranked, so fuzzy tiers would only make rows move around while
    // the user is looking for a switch.
    property string appQuery: ""

    FileView {
        id: statsFileView
        path: Qt.resolvedUrl(Directories.notificationsAppsPath)
        onLoaded: {
            let loaded = {};
            try {
                loaded = JSON.parse(statsFileView.text()) ?? {};
            } catch (e) {
                loaded = {};
            }
            // In-memory entries win: they can only be newer than the file.
            const merged = Object.assign({}, loaded);
            for (const key of Object.keys(root.appStats))
                merged[key] = Object.assign({}, loaded[key] ?? {}, root.appStats[key]);
            root.appStats = merged;
        }
        onLoadFailed: (error) => {
            if (error === FileViewError.FileNotFound)
                root.appStats = ({});
        }
    }

    FileView {
        id: historyFileView
        path: Qt.resolvedUrl(Directories.notificationsPath)
        onLoaded: {
            let list = [];
            try {
                list = JSON.parse(historyFileView.text()) ?? [];
            } catch (e) {
                list = [];
            }
            const apps = {};
            for (const n of list) {
                const key = NotificationUtils.normalizeAppIdentity(n.appName ?? "");
                if (key.length === 0)
                    continue;
                if (!apps[key])
                    apps[key] = { name: n.appName ?? "", appIcon: "", lastTime: 0 };
                if (!apps[key].appIcon && n.appIcon)
                    apps[key].appIcon = n.appIcon;
                apps[key].lastTime = Math.max(apps[key].lastTime, Number(n.time) || 0);
            }
            root.historyApps = apps;
        }
    }

    // ── Do not disturb ──────────────────────────────────────────────────
    //
    // Read and written straight from the config: `services/Notifications.qml`
    // owns enforcement and this page owns the switch, and the config file is
    // the only thing the two processes share. `dndClock` is bumped by a slow
    // timer so the "turns off in" line stays true while the page is open.
    property real dndClock: Date.now()

    Timer {
        interval: 20000
        repeat: true
        running: root.visible
        onTriggered: root.dndClock = Date.now()
    }

    function setDoNotDisturb(enabled, durationMin) {
        const notifications = Config.options.notifications;
        const minutes = Number(durationMin) || 0;
        notifications.dndDurationMin = minutes;
        notifications.doNotDisturb = enabled;
        notifications.dndUntil = enabled
            ? NotificationUtils.dndDeadline(minutes, Date.now())
            : 0;
        root.dndClock = Date.now();
    }

    readonly property bool dndOn: Config.options.notifications.doNotDisturb ?? false
    readonly property real dndUntil: Config.options.notifications.dndUntil ?? 0
    readonly property bool dndTimed: root.dndOn && root.dndUntil > 0

    readonly property string dndRemainingText: {
        const ms = Math.max(0, root.dndUntil - root.dndClock);
        const mins = Math.ceil(ms / 60000);
        if (mins >= 60) {
            const h = Math.floor(mins / 60);
            const m = mins % 60;
            return m > 0 ? `${h} h ${m} min` : `${h} h`;
        }
        return `${mins} min`;
    }

    // ── The per-app switches ────────────────────────────────────────────
    //
    // Copy-on-write into the config; the shell's own config watch is what makes
    // the daemon honour it, so there is nothing to notify from here.
    //
    // A row can answer to more than one name -- the display name a notification
    // carries, and the stable desktop-entry id -- so every one of them is
    // written to the list. Muting "Discord" by its display name alone would
    // miss a sender that only sets `desktopEntry`, and vice versa.
    function setMuted(identities, muted) {
        let list = Config.options.notifications.mutedApps ?? [];
        for (const identity of identities)
            list = NotificationUtils.withAppMuted(list, identity, muted);
        Config.options.notifications.mutedApps = list;
    }

    // The sound switch is about the APP's sound, never this desktop's: the app
    // keeps popping up and the PC chime keeps playing, but the app's own audio
    // streams are muted for a moment as the notification lands. Same config
    // shape as the mute list, so the daemon's matching is the same identity.
    function setSoundMuted(identities, muted) {
        let list = Config.options.notifications.soundMutedApps ?? [];
        for (const identity of identities)
            list = NotificationUtils.withAppMuted(list, identity, muted);
        Config.options.notifications.soundMutedApps = list;
    }

    // ── One row per app ─────────────────────────────────────────────────
    //
    // Muted first (the ones the user just acted on stay under the cursor),
    // then most recently heard from. Apps that are only ever named in the mute
    // list are included too -- a mute the user cannot find is a mute they
    // cannot undo.
    //
    // And every INSTALLED app is included, not only the ones that have already
    // notified: asked for 2026-11-19, "all the apps can be shown", so a switch
    // never has to wait for the app to speak first. The catalogue and the tally
    // are merged on their normalized identities, because the tally knows a
    // display name ("WhatsApp Desktop") and the catalogue knows a desktop id
    // ("whatsapp-linux-desktop") and those are not the same string.
    readonly property var rows: {
        const mutedList = Config.options.notifications.mutedApps ?? [];
        const soundMutedList = Config.options.notifications.soundMutedApps ?? [];
        const merged = {};
        const known = {};

        const remember = (entry) => {
            for (const token of [entry.name, entry.id, entry.appIcon]) {
                const key = NotificationUtils.normalizeAppIdentity(token ?? "");
                if (key.length > 0)
                    known[key] = true;
            }
        };

        const note = (key, entry) => {
            merged[key] = Object.assign({ allowed: 0, blocked: 0, lastSummary: "", lastTime: 0 },
                merged[key] ?? {}, entry);
            remember(merged[key]);
        };

        for (const key of Object.keys(root.historyApps))
            note(key, root.historyApps[key]);
        for (const key of Object.keys(root.appStats))
            note(key, root.appStats[key]);

        // A name that only exists in a list -- muted here, muted from the
        // launcher's right-click menu -- still gets a row. A switch the user
        // cannot find is a switch they cannot undo.
        for (const name of mutedList.concat(soundMutedList)) {
            const key = NotificationUtils.normalizeAppIdentity(name);
            if (key.length === 0 || merged[key])
                continue;
            note(key, { name: name, appIcon: "", allowed: 0, blocked: 0, lastTime: 0, lastSummary: "" });
        }

        // Everything installed. `noDisplay` entries are the spec's own "do not
        // show this in a menu" flag and are skipped; everything else is a real
        // program that can notify.
        const entries = DesktopEntries.applications?.values ?? [];
        for (const entry of entries) {
            if (!entry || entry.noDisplay === true)
                continue;
            const name = String(entry.name ?? "").trim();
            const id = String(entry.id ?? "").trim();
            const nameKey = NotificationUtils.normalizeAppIdentity(name);
            const idKey = NotificationUtils.normalizeAppIdentity(id);
            if (nameKey.length === 0 && idKey.length === 0)
                continue;
            // Already known under either spelling: the tally's row wins, so
            // the counts and the last summary stay on screen.
            if ((nameKey.length > 0 && known[nameKey]) || (idKey.length > 0 && known[idKey]))
                continue;
            const key = idKey.length > 0 ? idKey : nameKey;
            merged[key] = {
                name: name.length > 0 ? name : id,
                id: id,
                appIcon: entry.icon ?? "",
                allowed: 0,
                blocked: 0,
                lastTime: 0,
                lastSummary: "",
            };
            remember(merged[key]);
        }

        const out = [];
        for (const key of Object.keys(merged)) {
            const entry = merged[key];
            const name = entry.name || key;
            const identities = [];
            for (const token of [name, entry.id ?? "", entry.appIcon ?? ""]) {
                const clean = String(token ?? "").trim();
                if (clean.length > 0 && identities.indexOf(clean) < 0)
                    identities.push(clean);
            }
            out.push({
                "name": name,
                "id": entry.id ?? "",
                "appIcon": entry.appIcon ?? "",
                "identities": identities,
                "allowed": entry.allowed ?? 0,
                "blocked": entry.blocked ?? 0,
                "lastTime": entry.lastTime ?? 0,
                "lastSummary": entry.lastSummary ?? "",
                "muted": NotificationUtils.isIdentityMuted(identities, mutedList),
                "soundMuted": NotificationUtils.isIdentityMuted(identities, soundMutedList),
            });
        }
        out.sort((a, b) => (Number(b.muted) - Number(a.muted))
            || (Number(b.soundMuted) - Number(a.soundMuted))
            || ((b.lastTime || 0) - (a.lastTime || 0))
            || a.name.localeCompare(b.name));
        return out;
    }

    readonly property var visibleRows: {
        const query = root.appQuery.trim().toLowerCase();
        if (query.length === 0)
            return root.rows;
        return root.rows.filter((row) => row.name.toLowerCase().indexOf(query) >= 0
            || String(row.id ?? "").toLowerCase().indexOf(query) >= 0);
    }

    ContentSection {
        icon: "do_not_disturb_on"
        title: Translation.tr("Do not disturb")

        ConfigSwitch {
            buttonIcon: "do_not_disturb_on"
            text: Translation.tr("Silence notifications")
            checked: root.dndOn
            onCheckedChanged: {
                if (checked === root.dndOn)
                    return;
                root.setDoNotDisturb(checked, Config.options.notifications.dndDurationMin);
            }
        }

        StyledText {
            Layout.fillWidth: true
            text: !root.dndOn
                ? Translation.tr("Popups and chimes are on. Turning this on hides popups and keeps the notifications themselves in the sidebar.")
                : root.dndTimed
                    ? Translation.tr("No popups and no chime. Turns itself off in %1; notifications are still collected in the sidebar.").arg(root.dndRemainingText)
                    : Translation.tr("No popups and no chime until you turn it off. Notifications are still collected in the sidebar.")
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.smaller
            wrapMode: Text.Wrap
        }

        ContentSubsection {
            Layout.fillWidth: true
            title: Translation.tr("Turn off automatically")

            ConfigSelectionArray {
                currentValue: Config.options.notifications.dndDurationMin
                onSelected: newValue => {
                    // "Never" is a preference, not a reason to switch DND on:
                    // it only clears a deadline that is already running.
                    if (newValue === 0) {
                        Config.options.notifications.dndDurationMin = 0;
                        if (Config.options.notifications.doNotDisturb)
                            Config.options.notifications.dndUntil = 0;
                        return;
                    }
                    root.setDoNotDisturb(true, newValue);
                }
                options: [
                    {
                        displayName: Translation.tr("Never"),
                        icon: "all_inclusive",
                        value: 0
                    },
                    {
                        displayName: Translation.tr("15 min"),
                        icon: "timer",
                        value: 15
                    },
                    {
                        displayName: Translation.tr("30 min"),
                        icon: "timer",
                        value: 30
                    },
                    {
                        displayName: Translation.tr("1 h"),
                        icon: "timer",
                        value: 60
                    },
                    {
                        displayName: Translation.tr("2 h"),
                        icon: "timer",
                        value: 120
                    },
                    {
                        displayName: Translation.tr("4 h"),
                        icon: "timer",
                        value: 240
                    },
                    {
                        displayName: Translation.tr("8 h"),
                        icon: "timer",
                        value: 480
                    }
                ]
            }
        }
    }

    ContentSection {
        icon: "notifications_active"
        title: Translation.tr("Notifications")

        ConfigSwitch {
            buttonIcon: "volume_up"
            text: Translation.tr("Play a sound when a notification arrives")
            checked: Config.options.notifications.sound
            onCheckedChanged: {
                Config.options.notifications.sound = checked;
            }
        }

        ConfigSwitch {
            buttonIcon: "music_off"
            text: Translation.tr("Only the desktop chime (silence each app's own notification sound)")
            checked: Config.options.notifications.silenceAppSounds ?? true
            onCheckedChanged: {
                Config.options.notifications.silenceAppSounds = checked;
            }
        }

        StyledText {
            Layout.fillWidth: true
            text: Translation.tr("Popup timing and the monitor to show notifications on are in Bluetooth & devices. The app's own notification sound is silenced for a moment by default, so every notification is heard as the desktop chime alone -- the same sound an administration prompt makes. Sound off silences that app's own sound while its notification still appears; the PC notification sound is not affected and always plays. Muted stops the app's notifications from appearing at all.")
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.smaller
            wrapMode: Text.Wrap
        }
    }

    ContentSection {
        icon: "apps"
        title: Translation.tr("Apps")

        MaterialTextField {
            Layout.fillWidth: true
            placeholderText: Translation.tr("Search apps")
            onTextChanged: root.appQuery = text
        }

        StyledText {
            Layout.fillWidth: true
            visible: root.visibleRows.length === 0
            text: root.rows.length === 0
                ? Translation.tr("No apps found on this system.")
                : Translation.tr("No app matches \"%1\".").arg(root.appQuery)
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.small
            wrapMode: Text.Wrap
        }

        Repeater {
            model: root.visibleRows

            delegate: Rectangle {
                id: appRow
                required property var modelData

                Layout.fillWidth: true
                implicitHeight: rowLayout.implicitHeight + 14
                radius: Appearance.rounding.small
                // A muted row is tinted, not hidden: the point of this page is
                // to see at a glance which apps are silent right now.
                color: appRow.modelData.muted
                    ? CF.ColorUtils.transparentize(Appearance.colors.colError, 0.86)
                    : Appearance.colors.colLayer1

                RowLayout {
                    id: rowLayout
                    anchors {
                        fill: parent
                        leftMargin: 10
                        rightMargin: 10
                    }
                    spacing: 12

                    IconImage {
                        implicitSize: 26
                        source: Quickshell.iconPath(appRow.modelData.appIcon,
                            Quickshell.shellPath("assets/icons/fluent/app-generic.svg"))
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1

                        StyledText {
                            Layout.fillWidth: true
                            text: appRow.modelData.name
                            color: Appearance.colors.colOnLayer1
                            font.pixelSize: Appearance.font.pixelSize.small
                            elide: Text.ElideRight
                        }

                        StyledText {
                            Layout.fillWidth: true
                            text: (appRow.modelData.allowed > 0 || appRow.modelData.blocked > 0
                                    ? Translation.tr("%1 allowed · %2 blocked")
                                        .arg(appRow.modelData.allowed)
                                        .arg(appRow.modelData.blocked)
                                    : Translation.tr("No notifications yet"))
                                + (appRow.modelData.lastSummary.length > 0
                                    ? " · " + appRow.modelData.lastSummary
                                    : "")
                            color: Appearance.colors.colSubtext
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            elide: Text.ElideRight
                        }
                    }

                    // ── Two switches, two different silences ────────────
                    // Sound silences the APP's own sound (its streams are muted
                    // for the moment its notification lands) and changes
                    // nothing about this desktop's chime. Muted stops the app's
                    // popup and card. Asked for 2026-11-19: "I want to see the
                    // notification but not hear the desktop app sound and only
                    // hear the PC chime".
                    RowLayout {
                        Layout.fillWidth: false
                        spacing: 8

                        StyledText {
                            Layout.fillWidth: false
                            text: Translation.tr("Sound")
                            color: appRow.modelData.soundMuted
                                ? Appearance.colors.colError
                                : Appearance.colors.colSubtext
                            font.pixelSize: Appearance.font.pixelSize.smaller
                        }

                        StyledSwitch {
                            checked: !appRow.modelData.soundMuted
                            onClicked: root.setSoundMuted(appRow.modelData.identities,
                                !appRow.modelData.soundMuted)
                        }

                        StyledText {
                            Layout.fillWidth: false
                            text: Translation.tr("Muted")
                            color: appRow.modelData.muted
                                ? Appearance.colors.colError
                                : Appearance.colors.colSubtext
                            font.pixelSize: Appearance.font.pixelSize.smaller
                        }

                        StyledSwitch {
                            checked: appRow.modelData.muted
                            onClicked: root.setMuted(appRow.modelData.identities,
                                !appRow.modelData.muted)
                        }
                    }
                }
            }
        }
    }
}
