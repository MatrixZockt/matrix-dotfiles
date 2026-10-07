pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Simple polled resource usage service with RAM, Swap, and CPU usage.
 */
Singleton {
    id: root
	property real memoryTotal: 1
	property real memoryFree: 0
	property real memoryUsed: memoryTotal - memoryFree
    property real memoryUsedPercentage: memoryUsed / memoryTotal
    property real swapTotal: 1
	property real swapFree: 0
	property real swapUsed: swapTotal - swapFree
    property real swapUsedPercentage: swapTotal > 0 ? (swapUsed / swapTotal) : 0
    property real cpuUsage: 0
    property var previousCpuStats

    property string maxAvailableMemoryString: kbToGbString(ResourceUsage.memoryTotal)
    property string maxAvailableSwapString: kbToGbString(ResourceUsage.swapTotal)
    property string maxAvailableCpuString: "--"

    readonly property int historyLength: Config?.options.resources.historyLength ?? 60
    property list<real> cpuUsageHistory: []
    property list<real> memoryUsageHistory: []
    property list<real> swapUsageHistory: []

    function kbToGbString(kb) {
        return (kb / (1024 * 1024)).toFixed(1) + " GB";
    }

    function updateMemoryUsageHistory() {
        memoryUsageHistory = [...memoryUsageHistory, memoryUsedPercentage]
        if (memoryUsageHistory.length > historyLength) {
            memoryUsageHistory.shift()
        }
    }
    function updateSwapUsageHistory() {
        swapUsageHistory = [...swapUsageHistory, swapUsedPercentage]
        if (swapUsageHistory.length > historyLength) {
            swapUsageHistory.shift()
        }
    }
    function updateCpuUsageHistory() {
        cpuUsageHistory = [...cpuUsageHistory, cpuUsage]
        if (cpuUsageHistory.length > historyLength) {
            cpuUsageHistory.shift()
        }
    }
    function updateHistories() {
        updateMemoryUsageHistory()
        updateSwapUsageHistory()
        updateCpuUsageHistory()
    }

    // The graphs used to start as a single point and grow one sample at a time, so
    // the resource view spent its first minute looking like it was still loading.
    // Fill the history with the value we already have the first time round, so the
    // graph is drawn full width from the first frame.
    property bool historiesPrimed: false
    function primeHistories() {
        const seed = value => Array.from({
            length: historyLength
        }, () => value)
        memoryUsageHistory = seed(memoryUsedPercentage)
        swapUsageHistory = seed(swapUsedPercentage)
        cpuUsageHistory = seed(cpuUsage)
        historiesPrimed = true
    }

	Timer {
        // The interval is the configured one from the very first tick. It used to
        // start at 1 ms and re-assign its own interval at the end of each tick,
        // which meant any error thrown in between -- the parsing below, or the
        // history priming -- left a timer spinning a thousand times a second. The
        // first read is done by `triggeredOnStart` instead, so there is no window
        // in which this can become a busy loop.
		interval: Config.options?.resources?.updateInterval ?? 1000
        triggeredOnStart: true
        running: true
        repeat: true
		onTriggered: { const t = Date.now(); root.refresh(); StatusSignal.perfMark("resUsage", Date.now() - t); }
	}

    // Emitted once per sample. Anything that wants to keep in step with the
    // resource numbers -- the hardware monitor, for one -- hangs off this instead
    // of starting a timer of its own.
    signal tick()

    function refresh() {
        // Reload files
        fileMeminfo.reload()
        fileStat.reload()

        // Parse memory and swap usage
        const textMeminfo = fileMeminfo.text()
        memoryTotal = Number(textMeminfo.match(/MemTotal: *(\d+)/)?.[1] ?? 1)
        memoryFree = Number(textMeminfo.match(/MemAvailable: *(\d+)/)?.[1] ?? 0)
        swapTotal = Number(textMeminfo.match(/SwapTotal: *(\d+)/)?.[1] ?? 1)
        swapFree = Number(textMeminfo.match(/SwapFree: *(\d+)/)?.[1] ?? 0)

        // Parse CPU usage
        const textStat = fileStat.text()
        const cpuLine = textStat.match(/^cpu\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/)
        if (cpuLine) {
            const stats = cpuLine.slice(1).map(Number)
            const total = stats.reduce((a, b) => a + b, 0)
            const idle = stats[3]

            if (previousCpuStats) {
                const totalDiff = total - previousCpuStats.total
                const idleDiff = idle - previousCpuStats.idle
                cpuUsage = totalDiff > 0 ? (1 - idleDiff / totalDiff) : 0
            } else {
                // First sample: there is no previous reading to diff against, so
                // use the average load since boot rather than showing 0 and
                // making the bar look like it had not loaded yet.
                cpuUsage = total > 0 ? (1 - idle / total) : 0
            }

            previousCpuStats = { total, idle }
        }

        if (root.historiesPrimed)
            root.updateHistories()
        else
            root.primeHistories()

        root.tick()
    }

	FileView { id: fileMeminfo; path: "/proc/meminfo" }
    FileView { id: fileStat; path: "/proc/stat" }

    Process {
        id: findCpuMaxFreqProc
        environment: ({
            LANG: "C",
            LC_ALL: "C"
        })
        command: ["bash", "-c", "lscpu | grep 'CPU max MHz' | awk '{print $4}'"]
        running: true
        stdout: StdioCollector {
            id: outputCollector
            onStreamFinished: {
                root.maxAvailableCpuString = (parseFloat(outputCollector.text) / 1000).toFixed(0) + " GHz"
            }
        }
    }
}
