pragma Singleton
import Quickshell

Singleton {
    id: root
    /**
     * @param { string } summary 
     * @returns { string }
     */
    function findSuitableMaterialSymbol(summary = "") {
        const defaultType = 'chat';
        if (summary.length === 0) return defaultType;

        const keywordsToTypes = {
            'reboot': 'restart_alt',
            'record': 'screen_record',
            'battery': 'power',
            'power': 'power',
            'screenshot': 'desktop_windows',
            'welcome': 'waving_hand',
            'time': 'scheduleb',
            'installed': 'download',
            'configuration reloaded': 'reset_wrench',
            'unable': 'question_mark',
            "couldn't": 'question_mark',
            'config': 'reset_wrench',
            'update': 'update',
            'ai response': 'neurology',
            'control': 'settings',
            'upsca': 'compare',
            'music': 'queue_music',
            'install': 'deployed_code',
            'input': 'keyboard_alt',
            'preedit': 'keyboard_alt',
            'startswith:file': 'folder_copy', // Declarative startsWith check
            // Media notices (services/Volumes.qml) say what was plugged in, so
            // the notice wears the same drawing the drive has in the file
            // manager rather than the generic speech bubble.
            'sd card': 'sd_card',
            'usb stick': 'usb',
            'solid-state': 'hard_drive',
            'hard disk': 'hard_drive_2',
            // A device that could not be told apart still gets a drive, not a
            // speech bubble. Last, so the four above win when they match.
            'drive': 'hard_drive',
        };

        const lowerSummary = summary.toLowerCase();

        for (const [keyword, type] of Object.entries(keywordsToTypes)) {
            if (keyword.startsWith('startswith:')) {
                const startsWithKeyword = keyword.replace('startswith:', '');
                if (lowerSummary.startsWith(startsWithKeyword)) {
                    return type;
                }
            } else if (lowerSummary.includes(keyword)) {
                return type;
            }
        }

        return defaultType;
    }

    /**
     * @param { number | string | Date } timestamp 
     * @returns { string }
     */
    function getFriendlyNotifTimeString(timestamp) {
        if (!timestamp) return '';
        const messageTime = new Date(timestamp);
        const now = new Date();
        const diffMs = now.getTime() - messageTime.getTime();

        // Less than 1 minute
        if (diffMs < 60000)
            return 'Now';

        // Same day - show relative time
        if (messageTime.toDateString() === now.toDateString()) {
            const diffMinutes = Math.floor(diffMs / 60000);
            const diffHours = Math.floor(diffMs / 3600000);

            if (diffHours > 0) {
                return `${diffHours}h`;
            } else {
                return `${diffMinutes}m`;
            }
        }

        // Yesterday
        if (messageTime.toDateString() === new Date(now.getTime() - 86400000).toDateString())
            return 'Yesterday';

        // Older dates
        return Qt.formatDateTime(messageTime, "MMMM dd");
    }

    /**
     * One comparable spelling of an app, for matching a notification's sender
     * against the mute list.
     *
     * The same app arrives in three spellings -- `appName` ("WhatsApp
     * Desktop"), `desktopEntry` ("whatsapp-linux-desktop.desktop") and
     * `appIcon` (a full path into the icon theme) -- and no two of them are
     * equal. Reducing each to words: basename (identities arrive as paths), no
     * file extension, lowercase, every run of punctuation or space collapsed to
     * a single space.
     *
     * Shared by the daemon (services/Notifications.qml), which decides whether
     * to stay silent, and the Settings page, which draws the switch: if the two
     * disagreed about what "the same app" means, the row would say Muted while
     * the card kept arriving.
     *
     * @param { string } value
     * @returns { string }
     */
    function normalizeAppIdentity(value) {
        if (typeof value !== "string" || value.length === 0)
            return "";
        return value.split("/").pop()
            .replace(/\.desktop$/i, "")
            .replace(/\.(png|svg|xpm|ico|jpe?g|gif)$/i, "")
            .toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
    }

    /**
     * Is any spelling of this sender on the mute list?
     *
     * Whole-identity equality, not substring: muting "discord" must not mute
     * an unrelated app whose name merely contains the word, and muting
     * "Discord Canary" must not mute "Discord".
     *
     * @param { string[] } identities
     * @param { string[] } mutedApps
     * @returns { boolean }
     */
    function isIdentityMuted(identities, mutedApps) {
        const muted = (mutedApps ?? [])
            .map((a) => root.normalizeAppIdentity(a))
            .filter((t) => t.length > 0);
        if (muted.length === 0)
            return false;
        for (const raw of (identities ?? [])) {
            const token = root.normalizeAppIdentity(raw);
            if (token.length > 0 && muted.indexOf(token) >= 0)
                return true;
        }
        return false;
    }

    /**
     * The mute list with one app's state changed. Copy-on-write: the config
     * adapter only sees a new array, and the identity that was already on the
     * list is replaced rather than duplicated.
     *
     * @param { string[] } mutedApps
     * @param { string } appName
     * @param { boolean } muted
     * @returns { string[] }
     */
    function withAppMuted(mutedApps, appName, muted) {
        const key = root.normalizeAppIdentity(appName);
        const list = (mutedApps ?? []).filter((a) => root.normalizeAppIdentity(a) !== key);
        if (muted && key.length > 0)
            list.push(appName);
        return list;
    }

    function processNotificationBody(body, appName) {
        let processedBody = body
        
        // Clean Chromium-based browsers notifications - remove first line
        if (appName) {
            const lowerApp = appName.toLowerCase()
            const chromiumBrowsers = [
                "brave", "chrome", "chromium", "vivaldi", "opera", "microsoft edge"
            ]

            if (chromiumBrowsers.some(name => lowerApp.includes(name))) {
                const lines = body.split('\n\n')

                if (lines.length > 1 && lines[0].startsWith('<a')) {
                    processedBody = lines.slice(1).join('\n\n')
                }
            }
        }

        processedBody = processedBody.replace(/<img/gi, '\n\n<img');
        
        return processedBody
    }
}
