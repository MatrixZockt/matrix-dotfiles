pragma Singleton
pragma ComponentBehavior: Bound
import qs
import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * A nice wrapper for date and time strings.
 */
Singleton {
    property var clock: SystemClock {
        id: clock
        precision: {
            if (Config.options.time.secondPrecision || GlobalStates.screenLocked)
                return SystemClock.Seconds;
            return SystemClock.Minutes;
        }
    }
    property string time: Qt.locale().toString(clock.date, Config.options?.time.format ?? "hh:mm")
    // Seconds chunk for the ops-style HUD clock ("30" in the corner of the
    // big HH:MM). Empty-formatted so callers can hide the label cleanly.
    property string seconds: Qt.locale().toString(clock.date, "ss")
    // 24h-independent short day name + time under the big clock ("MON 09.11.26")
    property string hudDateLine: Qt.locale().toString(clock.date, "ddd dd.MM.yy").toUpperCase()
    property string shortDate: Qt.locale().toString(clock.date, Config.options?.time.shortDateFormat ?? "dd/MM")
    property string date: Qt.locale().toString(clock.date, Config.options?.time.dateWithYearFormat ?? "dd/MM/yyyy")
    property string longDate: Qt.locale().toString(clock.date, Config.options?.time.dateFormat ?? "dddd, dd/MM")
    property string collapsedCalendarFormat: Qt.locale().toString(clock.date, "dddd, MMMM dd")
    property string uptime: "0h, 0m"

    // A DURATION, not a time of day: the countdown a timer shows.
    //
    // This lives here rather than beside either of its two callers (the middle
    // island's clock view in NowBar.qml, and the timer half of the popped-out
    // card in NowBarPanel.qml) because the two used to format it differently,
    // and that is the same failure as the scroll rule: one surface gets a
    // feature and the other silently does not, so the same timer reads
    // "1:30:00" in the card and "90:00" in the island beside it.
    //
    // M:SS below an hour, H:MM:SS at or above it. The hours cannot simply
    // always be shown -- "0:25:00" for a 25 minute pomodoro is three times
    // the width for a zero -- but they cannot be omitted either, because at
    // 90 minutes M:SS renders "90:00", which is indistinguishable from a
    // typo and from a different unit entirely.
    function duration(sec) {
        const s = Math.max(0, Math.floor(sec ?? 0));
        const h = Math.floor(s / 3600);
        const m = Math.floor((s % 3600) / 60);
        const ss = s % 60;
        const mm = String(m).padStart(2, "0");
        const ssx = String(ss).padStart(2, "0");
        return h > 0 ? `${h}:${mm}:${ssx}` : `${m}:${ssx}`;
    }

    Timer {
        interval: 10
        running: true
        repeat: true
        onTriggered: {
            fileUptime.reload();
            const textUptime = fileUptime.text();
            const uptimeSeconds = Number(textUptime.split(" ")[0] ?? 0);

            // Convert seconds to days, hours, and minutes
            const days = Math.floor(uptimeSeconds / 86400);
            const hours = Math.floor((uptimeSeconds % 86400) / 3600);
            const minutes = Math.floor((uptimeSeconds % 3600) / 60);

            // Build the formatted uptime string
            let formatted = "";
            if (days > 0)
                formatted += `${days}d`;
            if (hours > 0)
                formatted += `${formatted ? ", " : ""}${hours}h`;
            if (minutes > 0 || !formatted)
                formatted += `${formatted ? ", " : ""}${minutes}m`;
            uptime = formatted;
            interval = Config.options?.resources?.updateInterval ?? 3000;
        }
    }

    FileView {
        id: fileUptime

        path: "/proc/uptime"
    }
}
