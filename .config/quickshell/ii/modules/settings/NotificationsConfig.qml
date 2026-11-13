// Settings > Notifications.
//
// Two questions, one page: "may this app notify me?" and "what has it actually
// been doing?" -- the mute switch and the tally that proves the switch works.
//
// The mute itself is enforced in services/Notifications.qml, in the SHELL
// process; this page is the settings app, a different process, so nothing here
// can call the daemon. The two meet at two files:
//
//   * the config (`notifications.mutedApps`) -- written here, and the shell
//     picks it up through its own config file watch, so a toggle takes effect
//     on the next notification without a restart;
//   * the daemon's tally (`$XDG_CACHE_HOME/notifications/apps.json`, see
//     Directories.notificationsAppsPath) -- written there, read here.
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

    // ── The switch ──────────────────────────────────────────────────────
    //
    // Copy-on-write into the config; the shell's own config watch is what makes
    // the daemon honour it, so there is nothing to notify from here.
    function setMuted(appName, muted) {
        Config.options.notifications.mutedApps = NotificationUtils.withAppMuted(
            Config.options.notifications.mutedApps, appName, muted);
    }

    // ── One row per app ─────────────────────────────────────────────────
    //
    // Muted first (the ones the user just acted on stay under the cursor),
    // then most recently heard from. Apps that are only ever named in the mute
    // list are included too -- a mute the user cannot find is a mute they
    // cannot undo.
    readonly property var rows: {
        const mutedList = Config.options.notifications.mutedApps ?? [];
        const merged = {};
        for (const key of Object.keys(root.historyApps))
            merged[key] = Object.assign({ allowed: 0, blocked: 0, lastSummary: "" }, root.historyApps[key]);
        for (const key of Object.keys(root.appStats))
            merged[key] = Object.assign({}, merged[key] ?? {}, root.appStats[key]);
        for (const name of mutedList) {
            const key = NotificationUtils.normalizeAppIdentity(name);
            if (key.length === 0)
                continue;
            if (!merged[key])
                merged[key] = { name: name, appIcon: "", allowed: 0, blocked: 0, lastTime: 0, lastSummary: "" };
        }
        const out = [];
        for (const key of Object.keys(merged)) {
            const entry = merged[key];
            const name = entry.name || key;
            out.push({
                "name": name,
                "appIcon": entry.appIcon ?? "",
                "allowed": entry.allowed ?? 0,
                "blocked": entry.blocked ?? 0,
                "lastTime": entry.lastTime ?? 0,
                "lastSummary": entry.lastSummary ?? "",
                "muted": NotificationUtils.isIdentityMuted([name, entry.appIcon ?? ""], mutedList),
            });
        }
        out.sort((a, b) => (Number(b.muted) - Number(a.muted))
            || ((b.lastTime || 0) - (a.lastTime || 0))
            || a.name.localeCompare(b.name));
        return out;
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

        StyledText {
            Layout.fillWidth: true
            text: Translation.tr("Popup timing and the monitor to show notifications on are in Bluetooth & devices. An app muted below gets no popup, no sound and no card in the notification centre, but is still counted here.")
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.smaller
            wrapMode: Text.Wrap
        }
    }

    ContentSection {
        icon: "apps"
        title: Translation.tr("Apps")

        StyledText {
            Layout.fillWidth: true
            visible: root.rows.length === 0
            text: Translation.tr("No notifications recorded yet. Apps appear here the first time they notify you.")
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.small
            wrapMode: Text.Wrap
        }

        Repeater {
            model: root.rows

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
                            text: Translation.tr("%1 allowed · %2 blocked")
                                .arg(appRow.modelData.allowed)
                                .arg(appRow.modelData.blocked)
                                + (appRow.modelData.lastSummary.length > 0
                                    ? " · " + appRow.modelData.lastSummary
                                    : "")
                            color: Appearance.colors.colSubtext
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            elide: Text.ElideRight
                        }
                    }

                    StyledText {
                        Layout.fillWidth: false
                        visible: appRow.modelData.muted
                        text: Translation.tr("Muted")
                        color: Appearance.colors.colError
                        font.pixelSize: Appearance.font.pixelSize.smaller
                    }

                    StyledSwitch {
                        checked: appRow.modelData.muted
                        onClicked: root.setMuted(appRow.modelData.name, !appRow.modelData.muted)
                    }
                }
            }
        }
    }
}
