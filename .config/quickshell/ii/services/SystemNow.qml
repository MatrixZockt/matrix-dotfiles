pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import qs.services
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * The machine, right now -- the numbers behind the island's performance view.
 *
 * ResourceUsage already answers two of the four questions (how busy is the
 * processor, how full is the memory) and HardwareStats answers what the
 * hardware *is*. Neither reports the two things a "how is it going" view
 * actually wants: how hot it is getting, and how hard the graphics chip is
 * working.
 *
 * Temperature and the graphics clock are plain single-value files under /sys,
 * so they are read as values rather than deltas. The PATHS are discovered once
 * at startup -- coretemp / k10temp / zenpower name themselves, and the Intel
 * and AMD graphics drivers expose gt_cur_freq_mhz on the DRM card -- and the
 * sampling then re-reads those same two files. That keeps the per-tick cost to
 * one tiny `sh` instead of re-walking hwmon every second.
 *
 * Sampling only runs while `active` (the island's performance view or the
 * panel is on screen): a monitor nobody is looking at costs nothing, the same
 * contract HardwareStats follows.
 */
Singleton {
    id: root

    // Set by whoever is looking at the numbers.
    property bool active: false
    // Bumped on every sample, so bindings that read the histories re-evaluate.
    property int revision: 0

    // ── Discovered paths (once) ──────────────────────────────────────────
    property string tempPath: ""
    property string tempChip: ""
    property string gpuCurPath: ""
    property string gpuMaxPath: ""
    // The load is read from nvidia-smi rather than from a sysfs clock file --
    // see the discovery script for why the file was the wrong device.
    property bool gpuIsNvidia: false
    property bool discovered: false

    // ── Current values ───────────────────────────────────────────────────
    property real tempC: -1            // -1 == this machine does not report it
    property real gpuClockMhz: -1
    property real gpuClockMaxMhz: -1
    // Despite the name, this is now CAPACITY (watts drawn / enforced power
    // limit), not nvidia-smi's utilization. The name is kept because every
    // view binds to it and renaming it would touch a dozen call sites for no
    // behavioural gain -- but the caption in each view says "of W limit", so
    // nobody has to guess what the number means. See sampleCommand for the
    // measurement that replaced it and why.
    property real gpuClockPct: -1
    // The two halves of the capacity fraction, exposed so a view can write
    // "7%" as "3.8 W of 55 W" instead of leaving the reader to wonder what the
    // percentage is a percentage OF. -1 when the driver did not report it.
    property real gpuPowerLimitW: -1
    property real gpuPowerDrawW: -1

    readonly property int historyLength: ResourceUsage.historyLength
    property var tempHistory: []
    property var gpuHistory: []

    // ── Temperature, normalised for the graphs ───────────────────────────
    // A temperature is a real quantity, not a fraction of anything, so a chart
    // of it needs a fixed window to mean anything: 30-90 °C, the same window
    // the island's meter has always used. Kept here so the island and the
    // popped-out card cannot normalise it differently, and so the °C value and
    // the bar drawn from it are always two views of one number.
    readonly property real tempFloor: 30
    readonly property real tempCeil: 90
    function tempLoad(v) {
        return v < 0 ? -1 : Math.max(0, Math.min(1, (v - root.tempFloor) / (root.tempCeil - root.tempFloor)));
    }
    property var tempLoadHistory: []

    // The four faces of the performance view. CPU and RAM are re-exported from
    // ResourceUsage so the view has ONE source per number.
    readonly property real cpuPct: ResourceUsage.cpuUsage
    readonly property real ramPct: ResourceUsage.memoryUsedPercentage
    readonly property bool hasTemp: root.tempC >= 0
    readonly property bool hasGpu: root.gpuClockPct >= 0
    readonly property string gpuName: (HardwareStats.gpuNames ?? [])[0] ?? ""

    // ── Discovery ────────────────────────────────────────────────────────
    // A chip name that reports temperature: coretemp (Intel), k10temp and
    // zenpower (AMD), acpitz / cpu_thermal (the generic ACPI sensor, last
    // resort). The hottest of that chip's inputs is the one worth showing.
    readonly property string discoverScript: `
# A chip that reports temperature: coretemp (Intel), k10temp and zenpower
# (AMD), acpitz / cpu_thermal (the generic ACPI sensor, LAST RESORT).
#
# THE ORDER OF THIS LIST IS THE POINT, and the version it replaces threw it
# away: it walked /sys/class/hwmon/hwmon* in glob order and broke on the first
# chip with a readable input. On this laptop that is hwmon2 = "acpitz" -- the
# generic ACPI thermal ZONE, which is not a live CPU reading at all, and which
# sat at exactly 45000 forever. hwmon8 = "coretemp" (the real sensor, Package id
# 0, 52-54 C and moving) comes later in the glob and was never reached. The
# comment already called acpitz a last resort; only the loop disagreed. So the
# search is now driven BY this list instead of by filesystem order.
#
# Within the chosen chip a labelled "Package" input wins over the hottest core:
# the package is the number people mean by "CPU temperature", and one hot core
# can otherwise drag the reading around on its own.
for want in coretemp k10temp zenpower acpitz cpu_thermal.0 cpu_thermal; do
  for d in /sys/class/hwmon/hwmon*; do
    n=$(cat "$d/name" 2>/dev/null)
    [ "$n" = "$want" ] || continue
    pkg=""; pv=-1; best=""; bv=-1
    for f in "$d"/temp*_input; do
      [ -r "$f" ] || continue
      v=$(cat "$f" 2>/dev/null)
      case "$v" in ''|*[!0-9]*) continue ;; esac
      if [ "$v" -gt "$bv" ]; then bv=$v; best="$f"; fi
      l=$(cat "$(dirname "$f")/$(basename "$f" _input)_label" 2>/dev/null)
      case "$l" in
        *[Pp]ackage*) if [ "$v" -gt "$pv" ]; then pv=$v; pkg="$f"; fi ;;
      esac
    done
    if [ -n "$pkg" ]; then echo "temp|$pkg|$n"; break 2; fi
    if [ -n "$best" ]; then echo "temp|$best|$n"; break 2; fi
  done
done
# Graphics: nvidia-smi when there is one. This machine's real GPU is the NVIDIA
# RTX 4070 Laptop, but the sysfs clock file this read unconditionally is an
# Intel interface -- on this box /sys/class/drm/card2/gt_cur_freq_mhz belongs
# to the i915 iGPU. So the gauge reported the iGPU's clock ratio (700 of 1650
# MHz) under a caption naming the NVIDIA card: the number and the name were two
# different devices. nvidia-smi asks the dGPU itself.
if command -v nvidia-smi >/dev/null 2>&1; then
  echo "gpu|nvidia||"
else
  g=$(ls /sys/class/drm/card*/gt_cur_freq_mhz 2>/dev/null | head -1)
  gm=$(ls /sys/class/drm/card*/gt_max_freq_mhz 2>/dev/null | head -1)
  echo "gpu|$g|$gm"
fi
`

    Process {
        id: discoverProc
        running: true
        command: ["sh", "-c", root.discoverScript]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = String(this.text ?? "").split("\n");
                for (const line of lines) {
                    const parts = line.split("|");
                    if (parts[0] === "temp") {
                        root.tempPath = parts[1] ?? "";
                        root.tempChip = parts[2] ?? "";
                    } else if (parts[0] === "gpu") {
                        root.gpuIsNvidia = (parts[1] ?? "") === "nvidia";
                        root.gpuCurPath = root.gpuIsNvidia ? "" : (parts[1] ?? "");
                        root.gpuMaxPath = root.gpuIsNvidia ? "" : (parts[2] ?? "");
                    }
                }
                root.discovered = true;
                // The maximum is a constant, so it is read once here rather
                // than on every tick. nvidia-smi supplies its own ceiling per
                // sample, so there is nothing to read for it.
                if (!root.gpuIsNvidia && root.gpuMaxPath.length > 0) gpuMaxFile.reload();
                root.sample();
            }
        }
    }

    // The graphics clock ceiling: a fixed number, read once.
    FileView {
        id: gpuMaxFile
        path: root.gpuMaxPath
        onLoaded: {
            const v = parseFloat(String(gpuMaxFile.text() ?? "").trim());
            root.gpuClockMaxMhz = isNaN(v) ? -1 : v;
        }
        onLoadFailed: root.gpuClockMaxMhz = -1
    }

    // ── Sampling ─────────────────────────────────────────────────────────
    // One `sh` per tick, reading the two discovered files. Rebuilt whenever
    // the paths change (discovery finishing, or a graphics driver appearing
    // later) so it never runs with empty paths.
    Process {
        id: sampleProc
        command: []
        stdout: StdioCollector {
            onStreamFinished: {
                const line = String(this.text ?? "").trim();
                const parts = line.split("|");
                if (parts[0] !== "v")
                    return;
                // v|tempMilliC|powerW|limitW|clockMHz|curClock|maxClock
                const t = parseFloat(parts[1]);
                root.tempC = isNaN(t) ? -1 : t / 1000;

                // CAPACITY, computed HERE rather than in the shell.
                //
                // It was computed in the sampler script first, with awk, and
                // the awk branch silently produced an empty field every time
                // -- so the gauge rendered "--" while watts and the limit
                // were both sitting right there in the same line. Two shell
                // substitutions and a subshell were doing arithmetic that
                // JavaScript does natively in one expression, and the only
                // symptom was a blank gauge.
                //
                // Prefer power draw / enforced power limit. Fall back to the
                // clock fraction on a machine with no NVIDIA part. If neither
                // pair is complete, report -1 (renders "--") rather than 0,
                // because a missing denominator must never masquerade as an
                // idle card.
                const w = parseFloat(parts[2]);
                const lim = parseFloat(parts[3]);
                const cc = parseFloat(parts[5]);
                const mm = parseFloat(parts[6]);
                let pct = -1;
                if (!isNaN(w) && !isNaN(lim) && lim > 0)
                    pct = Math.max(0, Math.min(100, (w / lim) * 100));
                else if (!isNaN(cc) && !isNaN(mm) && mm > 0)
                    pct = Math.max(0, Math.min(100, (cc / mm) * 100));

                root.gpuClockPct = pct < 0 ? -1 : pct / 100;
                const c = parseFloat(parts[4]);
                root.gpuClockMhz = isNaN(c) ? -1 : c;
                root.gpuPowerDrawW = isNaN(w) ? -1 : w;
                root.gpuPowerLimitW = isNaN(lim) ? -1 : lim;
                root.pushHistories();
                root.revision += 1;
            }
        }
    }
    // One `sh` per tick. Emits `v|<tempMilliC>|<loadPercent>|<clockMHz>` -- the
    // same four fields whichever source answered, so the parser below does not
    // branch on where the numbers came from.
    //
    // WHAT "LOAD" MEANS HERE, AND WHY IT IS NOT nvidia-smi's utilization
    // ------------------------------------------------------------------
    // This used to query utilization.gpu, which nvidia-smi defines as "percent
    // of time a kernel was executing". That is a CLOCK measure. Measured here
    // under one steady workload, side by side with watts drawn:
    //
    //     util%   drawW   power%   clk
    //      36     19.32    35.1    2010
    //      22     20.17    36.7    2205
    //      33     20.68    37.6    2205
    //      29     23.04    41.9    2445
    //      38     24.48    44.5    2445
    //
    // Utilization wandered between 22% and 38% while the actual work climbed
    // smoothly and monotonically. So the panel now reports CAPACITY: watts
    // drawn divided by the power limit the board actually enforces (55 W on
    // this machine). That is the same number the Razer app's "of power limit"
    // gauge shows, so the two surfaces cannot contradict each other.
    //
    // The floor is not zero: an idle card draws ~3.8 W, which is ~7% of 55 W.
    // That is correct, not a bug -- this driver cannot reach 0 W. Reporting it
    // as a real fraction of a real ceiling is the honest version.
    //
    // If the limit cannot be read, the field is left EMPTY rather than
    // computed as 0. A blank renders as "--" (unknown); a 0 would render as
    // "0%" and claim an idle card that may well be working.
    readonly property string sampleCommand: `
t=$(cat ${root.tempPath.length > 0 ? root.tempPath : "/dev/null"} 2>/dev/null)
w=""; lim=""; cc=""; mm=""
if command -v nvidia-smi >/dev/null 2>&1; then
  u=$(nvidia-smi --query-gpu=power.draw,clocks.current.graphics,enforced.power.limit --format=csv,noheader,nounits -i 0 2>/dev/null | head -1)
  w=$(printf '%s' "$u" | cut -d, -f1 | tr -dc '0-9.')
  c=$(printf '%s' "$u" | cut -d, -f2 | tr -dc '0-9')
  lim=$(printf '%s' "$u" | cut -d, -f3 | tr -dc '0-9.')
else
  cc=$(cat ${root.gpuCurPath.length > 0 ? root.gpuCurPath : "/dev/null"} 2>/dev/null | tr -dc '0-9')
  mm=$(cat ${root.gpuMaxPath.length > 0 ? root.gpuMaxPath : "/dev/null"} 2>/dev/null | tr -dc '0-9')
  c="$cc"
fi
echo "v|$t|$w|$lim|$c|$cc|$mm"
`

    function sample() {
        if (!root.discovered || !root.active)
            return;
        sampleProc.command = ["sh", "-c", root.sampleCommand];
        sampleProc.running = false;
        sampleProc.running = true;
    }

    Timer {
        // Only while someone is looking. The GPU clock moves far faster than
        // this, but the view is a trend, not a scope -- and a 1 Hz read of two
        // /sys files is invisible next to the CPU counter ResourceUsage reads
        // anyway.
        interval: 1000
        repeat: true
        running: root.active && root.discovered
        onTriggered: root.sample()
    }

    onActiveChanged: if (root.active) root.sample()

    function pushHistories() {
        const cap = root.historyLength;
        const push = (arr, v) => {
            const next = [...arr, v];
            while (next.length > cap) next.shift();
            return next;
        };
        if (root.tempC >= 0) {
            root.tempHistory = push(root.tempHistory, root.tempC);
            root.tempLoadHistory = push(root.tempLoadHistory, root.tempLoad(root.tempC));
        }
        if (root.gpuClockPct >= 0) root.gpuHistory = push(root.gpuHistory, root.gpuClockPct);
    }

    // ── Display helpers ──────────────────────────────────────────────────
    function pct(v) {
        return v < 0 ? "--" : `${Math.round(v * 100)}%`;
    }
    function tempText(v) {
        return v < 0 ? "--" : `${Math.round(v)}°C`;
    }
    function gpuText() {
        return root.gpuClockMhz < 0 ? "--" : `${Math.round(root.gpuClockMhz)} MHz`;
    }

    IpcHandler {
        target: "systemNow"
        function state(): string {
            return `discovered=${root.discovered} temp=${root.tempPath} gpu=${root.gpuCurPath} max=${root.gpuClockMaxMhz} active=${root.active}`;
        }
        function values(): string {
            return `cpu=${root.pct(root.cpuPct)} ram=${root.pct(root.ramPct)} gpu=${root.pct(root.gpuClockPct)} temp=${root.tempText(root.tempC)}`;
        }
        // Drive the sampler without a pointer (the shell's usual test affordance).
        function probe(): void {
            root.active = true;
            root.sample();
        }
        function off(): void {
            root.active = false;
        }
    }
}
