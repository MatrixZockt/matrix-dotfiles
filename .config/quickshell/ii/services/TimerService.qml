pragma Singleton
pragma ComponentBehavior: Bound

import qs.services
import qs.modules.common

import Quickshell
import Quickshell.Io
import QtQuick

/**
 * Simple countdown timer.
 *
 * It used to be a pomodoro: one focus length, a short break, a longer
 * break every fourth lap, and a cycle counter to say which lap you were
 * on. All of that is gone. The timer is one length now -- the one the
 * presets and the inline editor set -- and when it runs out it says so
 * and starts the same lap again. There is no second phase to be in and
 * nothing to count.
 */
Singleton {
    id: root

    property int focusTime: Config.options.time.pomodoro.focus

    property bool pomodoroRunning: Persistent.states.timer.pomodoro.running
    property int pomodoroLapDuration: focusTime // This is a binding that's to be kept
    property int pomodoroSecondsLeft: pomodoroLapDuration // Reasonable init value, to be changed

    property bool stopwatchRunning: Persistent.states.timer.stopwatch.running
    property int stopwatchTime: 0
    property int stopwatchStart: Persistent.states.timer.stopwatch.start
    property var stopwatchLaps: Persistent.states.timer.stopwatch.laps

    // ── Finish alarm ──
    // A finished lap is not a silent flip: the phase change also raises a
    // stoppable alarm. `alarmActive` drives the panel's banner AND the
    // repeating ringtone; it stays on until the user stops it (banner button,
    // or any timer action) -- one chime per ~2.6s, the length of the system
    // "alarm-clock-elapsed" sample. The message is the same line the system
    // notification carries, so the banner can show what rang.
    property bool alarmActive: false
    property string alarmMessage: ""

    function startAlarm(message) {
        root.alarmMessage = message ?? "";
        if (root.alarmActive) return; // already ringing: refresh the text only
        root.alarmActive = true;
        if (Config.options.sounds.pomodoro)
            Audio.playSystemSound("alarm-clock-elapsed");
    }

    function stopAlarm() {
        root.alarmActive = false;
    }

    Timer {
        id: alarmRepeat
        interval: 2600
        running: root.alarmActive
        repeat: true
        onTriggered: {
            if (Config.options.sounds.pomodoro)
                Audio.playSystemSound("alarm-clock-elapsed");
        }
    }

    // General
    Component.onCompleted: {
        if (!stopwatchRunning)
            stopwatchReset();
    }

    function getCurrentTimeInSeconds() {  // Pomodoro uses Seconds
        return Math.floor(Date.now() / 1000);
    }

    function getCurrentTimeIn10ms() {  // Stopwatch uses 10ms
        return Math.floor(Date.now() / 10);
    }

    // Countdown
    //
    // One lap, and when it runs out the lap starts again. It used to flip a
    // break flag here and pick its message off the new phase, which meant
    // the notification, the alarm text, the phase word in three different
    // widgets and the cycle counter all had to agree about which of four
    // states the timer was in. There is one state now, so there is one
    // message.
    function refreshPomodoro() {
        if (getCurrentTimeInSeconds() >= Persistent.states.timer.pomodoro.start + pomodoroLapDuration) {
            Persistent.states.timer.pomodoro.start = getCurrentTimeInSeconds();

            const notificationMessage = Translation.tr(`⏱ Timer: %1 minutes`).arg(Math.floor(focusTime / 60));
            Quickshell.execDetached(["notify-send", "Timer", notificationMessage, "-a", "Shell"]);
            root.startAlarm(notificationMessage);
        }

        pomodoroSecondsLeft = pomodoroLapDuration - (getCurrentTimeInSeconds() - Persistent.states.timer.pomodoro.start);
    }

    Timer {
        id: pomodoroTimer
        interval: 200
        running: root.pomodoroRunning
        repeat: true
        onTriggered: refreshPomodoro()
    }

    function togglePomodoro() {
        root.stopAlarm(); // a user action always silences the ring
        Persistent.states.timer.pomodoro.running = !pomodoroRunning;
        if (Persistent.states.timer.pomodoro.running) {
            // Start/Resume
            Persistent.states.timer.pomodoro.start = getCurrentTimeInSeconds() + pomodoroSecondsLeft - pomodoroLapDuration;
        }
    }

    function resetPomodoro() {
        root.stopAlarm();
        Persistent.states.timer.pomodoro.running = false;
        Persistent.states.timer.pomodoro.start = getCurrentTimeInSeconds();
        refreshPomodoro();
    }

    

    // Change the focus length from the widget. Writes through the Config so
    // the value persists across sessions, and resets the running lap so the
    // new length takes effect immediately (a timer mid-run would otherwise
    // keep the old duration until the next lap). Returns silently when the
    // value is nonsense (<= 0 or > 24h).
    function setPomodoroFocus(seconds) {
        if (!(seconds > 0 && seconds <= 86400)) return;
        Config.options.time.pomodoro.focus = Math.floor(seconds);
        resetPomodoro();
    }

    // Stopwatch
    function refreshStopwatch() {  // Stopwatch stores time in 10ms
        stopwatchTime = getCurrentTimeIn10ms() - stopwatchStart;
    }

    Timer {
        id: stopwatchTimer
        interval: 10
        running: root.stopwatchRunning
        repeat: true
        onTriggered: refreshStopwatch()
    }

    function toggleStopwatch() {
        if (root.stopwatchRunning)
            stopwatchPause();
        else
            stopwatchResume();
    }

    function stopwatchPause() {
        Persistent.states.timer.stopwatch.running = false;
    }

    function stopwatchResume() {
        if (stopwatchTime === 0) Persistent.states.timer.stopwatch.laps = [];
        Persistent.states.timer.stopwatch.running = true;
        Persistent.states.timer.stopwatch.start = getCurrentTimeIn10ms() - stopwatchTime;
    }

    function stopwatchReset() {
        stopwatchTime = 0;
        Persistent.states.timer.stopwatch.laps = [];
        Persistent.states.timer.stopwatch.running = false;
    }

    function stopwatchRecordLap() {
        Persistent.states.timer.stopwatch.laps.push(stopwatchTime);
    }

    // Scripted control: scripts, the dock and testing can drive the timer
    // without reaching into the panel UI.
    IpcHandler {
        target: "pomodoro"

        function toggle(): void { root.togglePomodoro(); }
        function reset(): void { root.resetPomodoro(); }
        function stopAlarm(): void { root.stopAlarm(); }
        // The stopwatch, for the same reason the pomodoro is here: the
        // service owns the clock and the UIs cannot reach into it. Without
        // these the only way to start a stopwatch is a click in the sidebar,
        // and a click cannot be aimed at a layer surface from a script --
        // so the island's stopwatch mode was impossible to exercise at all.
        function swToggle(): void { root.toggleStopwatch(); }
        function swReset(): void { root.stopwatchReset(); }
        function swLap(): void { root.stopwatchRecordLap(); }
        function setFocus(minutes: string): void { root.setPomodoroFocus(Number(minutes) * 60); }
    }
}
