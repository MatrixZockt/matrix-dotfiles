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
    // Set when that looking STARTS: the next history push seeds the whole
    // window with the value it read, instead of extending what the last
    // session left behind. See onActiveChanged and pushHistories.
    property bool freshWindow: false
    // Bumped on every sample, so bindings that read the histories re-evaluate.
    property int revision: 0

    // ── Discovered paths (once) ──────────────────────────────────────────
    property string tempPath: ""
    property string tempChip: ""
    property string gpuCurPath: ""
    property string gpuMaxPath: ""
    // The load is read from nvidia-smi rather than from a sysfs clock file --
    // see the discovery script for why the file was the wrong device. nvidia-smi
    // is the DISCRETE card, though, and it is not the half of this machine that
    // draws; `intelGpuPct` below is the other half, and gpuMetricPct reports
    // whichever of the two is actually working.
    property bool gpuIsNvidia: false
    property bool discovered: false

    // ── Current values ───────────────────────────────────────────────────
    property real tempC: -1            // -1 == this machine does not report it
    property real gpuClockMhz: -1
    property real gpuClockMaxMhz: -1
    // GPU BUSY FRACTION -- the same KIND of number as cpuPct and ramPct, which
    // is how a gauge labelled "GPU" is read.
    //
    // This is nvidia-smi's utilization.gpu (the fraction of the sample window in
    // which a kernel was executing) over 100.
    //
    // It was CAPACITY for a while -- watts drawn over the enforced power limit --
    // chosen because utilization is a "percent of TIME" measure that can sit at
    // 30% while the card does smoothly increasing work. That observation is
    // real, and it is also exactly why the gauge read ~8% on a laptop whose card
    // was plainly busy: an idle 4070 draws ~4 W of its 55 W limit, so the bar
    // barely left the floor and the number disagreed with every other tool on
    // the machine that calls this quantity "GPU %". The complaint it produced
    // is the one this file's author would have made too: the GPU tile does not
    // show the load the way the CPU and RAM tiles do.
    //
    // So utilization is back. The power reading did NOT lose its home: the
    // System tab's own GPU power row still reports "4.2 of 55 W" (see
    // gpuDrawRow in NowBarPanel.qml), which is a sentence about watts rather
    // than a percentage of something the reader has to infer from a caption.
    //
    // The NAME `gpuClockPct` is kept, for the same reason as before: every view
    // binds to it, and renaming it would touch a dozen call sites for no
    // behavioural gain. See sampleCommand for the measurement itself.
    property real gpuClockPct: -1
    // ── The card that is actually DRAWING ────────────────────────────────
    //
    // The number above is the 4070's. On this laptop the 4070 is not the
    // renderer: Hyprland draws on the Intel iGPU and the discrete card only
    // scans the panel out (card1-eDP-1 drives the panel, every client renders
    // on renderD128), so nvidia-smi's utilization.gpu sits at an honest 0%
    // while the machine is plainly busy. That is how the tile read, and the
    // owner's complaint is exactly the one a correct reading of the wrong chip
    // earns: "the GPU shows 0% ... fix it so it shows when the graphics card
    // is actually working" (2026-11-07). gpuMetricPct below therefore reports
    // the BUSIEST chip rather than a named one.
    //
    // The iGPU cannot answer from sysfs: i915 exposes no rc6_residency_ms on
    // this kernel, and unlike amdgpu there is no gpu_busy_percent -- the frozen
    // RC6 counter is the attempt this file already documents above. DRM's
    // per-process fdinfo does report accumulated engine time, and
    // scripts/system/gpu-busy.py turns that into a percentage, including the
    // unit gotcha (max per process, not sum per fd) that made an earlier
    // attempt read 187% for one process.
    //
    // Sampled at 1 Hz by ONE long-lived process, not on the 250 ms tick: a
    // fresh interpreter costs ~30 ms of start-up and four of those a second
    // would be a seventh of a core for a gauge. -1 until it has a baseline.
    property real intelGpuPct: -1
    // The two halves of the capacity fraction, exposed so a view can write
    // "7%" as "3.8 W of 55 W" instead of leaving the reader to wonder what the
    // percentage is a percentage OF. -1 when the driver did not report it.
    property real gpuPowerLimitW: -1
    // The card's own maximum: what the silicon CAN be allowed to draw, as
    // opposed to the cap in force right now (the enforced limit above). On this
    // board that is 140 W, against a 55 W vBIOS default and a 50 W enforced cap
    // while Dynamic Boost is inactive. nvidia-smi answers [N/A] for it while
    // the card is parked, which parses to NaN and leaves the last real reading
    // in place rather than inventing one.
    property real gpuPowerMaxW: -1
    property real gpuPowerDrawW: -1

    // ── What the hardware is doing, beyond the four gauges ───────────────
    //
    // Read for the island's System tab, which reports the live machine instead
    // of a spec sheet. Every one of these rides the tick that was already
    // running -- five more fields in the nvidia-smi query, and four small
    // files -- so this costs no timer, no second process, and no wake-up of its
    // own.
    property real gpuTempC: -1
    property real gpuVramUsedMiB: -1
    property real gpuVramTotalMiB: -1
    // Average and PEAK core clock in GHz, out of /proc/cpuinfo's per-thread
    // "cpu MHz". One file reports all 32 threads, which is the whole reason
    // this is not 32 reloads of scaling_cur_freq -- and the PEAK is kept
    // because on a laptop the interesting fact is whether any core is
    // actually reaching up, not what the average of the idle ones is.
    property real cpuClockGhz: -1
    property real cpuPeakGhz: -1
    // The kernel's answer rather than the daemon's LABEL: what the processor is
    // being held to right now. On intel_pstate `scaling_governor` reads
    // "powersave" in every profile -- EPP is the lever a power-mode switch
    // turns -- so the pair is the difference between "the profile says
    // Performance" and "the cores are running under the performance policy".
    property string cpuGovernor: ""
    property string cpuEpp: ""

    readonly property int historyLength: ResourceUsage.historyLength
    // The sampling cadence, in milliseconds. Named because the windows below
    // are DERIVED from it rather than guessed, and because the same 60 samples
    // are a minute long at one tick a second and fifteen seconds at four: the
    // rate is what decides how much time a graph covers. The Timer at the
    // bottom of this file uses this value; nothing else may assume another.
    readonly property int sampleIntervalMs: 250
    // The window these series span, in seconds -- NOT the processor's minute.
    //
    // The length is the shared one (60 samples, so the histories are the same
    // shape everywhere), but the cadence is this file's own: 60 * 0.25 = 15 s.
    // It is written down because a reader comparing the GPU or temperature
    // graph against the processor's has to know they are not the same span of
    // time -- and because the rate is the thing that decides it (see the
    // sampling Timer).
    readonly property real historySeconds: historyLength * (root.sampleIntervalMs / 1000)
    // ── The window the GPU graph DRAWS ───────────────────────────────────
    //
    // Five seconds, not the full fifteen, and that is a fix rather than a
    // taste -- the second half of the same complaint the cadence above was
    // raised for.
    //
    // The histories must stay long (they are the shared shape everywhere),
    // but a reader does not read a graph's *samples*, they read its *span*: a
    // load that steps from idle to busy enters a fifteen-second window as one
    // sample at the right-hand edge -- about 2% of the width -- and only reads
    // as a plateau once the minutes-old tail has scrolled out from under it,
    // which takes the whole fifteen seconds. That is exactly the reported
    // "the graph shows the GPU at 100% fifteen to twenty seconds after it was
    // already at 100%".
    //
    // Drawing the newest seconds is what makes the answer as immediate as the
    // number above it: at 5 s a step is a legible rise inside a second and a
    // half-width plateau inside three. The cost is zero -- the samples are
    // already in hand, and only the slice the view paints is shorter (see
    // NowBarPanel's metric band and NowBarPanel.perfPoints for the island).
    readonly property real gpuWindowSeconds: 5
    readonly property int gpuWindowPoints:
        Math.max(2, Math.round(root.gpuWindowSeconds / (root.sampleIntervalMs / 1000)))
    property var tempHistory: []
    property var gpuHistory: []

    // ── What the generic "GPU" number means ────────────────────────────────
    //
    // The DISCRETE card: its name and its utilization (`gpuClockPct`) -- what
    // the tile drew all along. It briefly spoke about the chip that RENDERS
    // the desktop instead, and that was reverted on 2026-10-23 for two reasons
    // a single screenshot showed at once, "Intel Graphics 100%":
    //
    //   1. It renamed the tile to a card its owner does not call "my GPU". A
    //      correct reading of the wrong chip is still the wrong answer.
    //   2. The number was not even correct. i915's RC6 residency counter is
    //      FROZEN on this laptop (delta 0 ms per second), so the busy
    //      fraction derived from it was a permanent 100% -- see
    //      HardwareStats.gpuLoad, where that source is now gone.
    //
    // What was right about the attempt is kept: every chip gets its OWN row in
    // the Resources view and the task manager, matched by PCI address
    // (`gpuOwnsLiveNumbers`), so the integrated GPU's clock and history are no
    // longer printed under the 4070's name.
    //
    // One policy in one place, because four surfaces draw it: the island's
    // tile and graphs, the bar pocket, the task manager card and the bar's
    // popup all read these three properties.
    readonly property real gpuMetricPct: Math.max(root.gpuClockPct, root.intelGpuPct)
    readonly property var gpuMetricHistory: root.gpuHistory
    readonly property string gpuMetricName: root.gpuName
    // Which of the two chips the number above belongs to, so that a caption
    // about the 4070's enforced watt cap is not printed underneath the iGPU's
    // percentage -- the same class of mistake as the 0% was. Ties go to the
    // discrete card, which is the one the owner calls "my GPU".
    readonly property bool gpuMetricDiscrete: root.gpuClockPct >= root.intelGpuPct

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

    // The iGPU's busy fraction, out of DRM fdinfo. One process for the life of
    // the shell (see intelGpuPct for why not one per tick), and `-u` because a
    // piped stdout is buffered: a line delivered when the 4 KB buffer fills is
    // a gauge that does not move.
    Process {
        id: gpuBusyProc
        running: root.active && root.discovered
        command: ["python3", "-u", Quickshell.shellPath("scripts/system/gpu-busy.py"), "--loop", "1"]
        stdout: SplitParser {
            onRead: line => {
                const v = parseFloat(String(line ?? "").trim());
                // -1 is the script's "no baseline yet", and it must not blank a
                // reading that was already earned: the first line after a shell
                // restart would otherwise read as an idle GPU.
                if (!isNaN(v) && v >= 0)
                    root.intelGpuPct = Math.min(100, v) / 100;
            }
        }
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
                //  |gpuTempC|vramUsedMiB|vramTotalMiB|gpuClockCeilingMhz
                //  |cpuClockMHz(avg)|cpuClockMHz(peak)|governor|epp|powerMaxW
                //  |utilPercent
                const t = parseFloat(parts[1]);
                root.tempC = isNaN(t) ? -1 : t / 1000;

                // WHICH NUMBER THE GAUGE DRAWS: utilization, computed HERE
                // rather than in the shell.
                //
                // It was computed in the sampler script first, with awk, and
                // the awk branch silently produced an empty field every time
                // -- so the gauge rendered "--" while the numbers were both
                // sitting right there in the same line. Two shell substitutions
                // and a subshell were doing arithmetic that JavaScript does
                // natively in one expression, and the only symptom was a blank
                // gauge. Hence: the shell MEASURES, this parses.
                //
                // utilization.gpu is the primary reading. The clock fraction is
                // the fallback for a machine with no NVIDIA part (or a parked
                // card answering [N/A]); it is a proxy for load, not a measure
                // of it, so it must not be preferred over the real thing.
                //
                // If neither is available, report -1 (renders "--") rather
                // than 0, because a missing reading must never masquerade as an
                // idle card.
                const w = parseFloat(parts[2]);
                const lim = parseFloat(parts[3]);
                const cc = parseFloat(parts[5]);
                const mm = parseFloat(parts[6]);
                const util = parseFloat(parts[16]);
                let pct = -1;
                if (!isNaN(util))
                    pct = Math.max(0, Math.min(100, util));
                else if (!isNaN(cc) && !isNaN(mm) && mm > 0)
                    pct = Math.max(0, Math.min(100, (cc / mm) * 100));

                root.gpuClockPct = pct < 0 ? -1 : pct / 100;
                const c = parseFloat(parts[4]);
                root.gpuClockMhz = isNaN(c) ? -1 : c;
                root.gpuPowerDrawW = isNaN(w) ? -1 : w;
                root.gpuPowerLimitW = isNaN(lim) ? -1 : lim;

                // The dGPU's own ceiling, which nvidia-smi reports per sample
                // and the sysfs clock file cannot supply at all. Left alone when
                // the driver answers [N/A] (the field parses to NaN), so the
                // iGPU path keeps whatever it read once at discovery.
                const gt = parseFloat(parts[7]);
                const mu = parseFloat(parts[8]);
                const mtotal = parseFloat(parts[9]);
                const mx = parseFloat(parts[10]);
                root.gpuTempC = isNaN(gt) ? -1 : gt;
                root.gpuVramUsedMiB = isNaN(mu) ? -1 : mu;
                root.gpuVramTotalMiB = isNaN(mtotal) ? -1 : mtotal;
                if (!isNaN(mx) && mx > 0)
                    root.gpuClockMaxMhz = mx;
                // The card's own maximum (power.max_limit), read off the same
                // sample as the cap in force. [N/A] while the card is parked
                // parses to NaN and leaves the last real reading alone -- the
                // same contract as the clock ceiling just above, and for the
                // same reason: a guess here is a number nobody measured.
                const pw = parseFloat(parts[15]);
                if (!isNaN(pw) && pw > 0)
                    root.gpuPowerMaxW = pw;
                const cavg = parseFloat(parts[11]);
                const cpeak = parseFloat(parts[12]);
                root.cpuClockGhz = isNaN(cavg) || cavg <= 0 ? -1 : cavg / 1000;
                root.cpuPeakGhz = isNaN(cpeak) || cpeak <= 0 ? -1 : cpeak / 1000;
                root.cpuGovernor = String(parts[13] ?? "").trim();
                root.cpuEpp = String(parts[14] ?? "").trim();
                root.pushHistories();
                root.revision += 1;
            }
        }
    }
    // One `sh` per tick. Emits `v|<tempMilliC>|<powerW>|<limitW>|<clockMHz>|...`
    // -- every field whichever source answered, so the parser below does not
    // branch on where the numbers came from.
    //
    // WHAT THE "LOAD" FIELD IS: utilization.gpu
    // ------------------------------------------------------------------
    // The percentage the gauge and the graphs draw is nvidia-smi's
    // utilization.gpu -- "percent of time a kernel was executing" -- which is
    // the quantity every other tool on this machine calls "GPU %", and the
    // same KIND of number as cpuPct and ramPct beside it.
    //
    // It was briefly power CAPACITY (watts drawn / enforced limit) instead, on
    // the argument that utilization is a percent-of-TIME measure that can
    // wander while real work climbs. What that bought and what it cost:
    //
    //     util%   drawW   power%   clk
    //      36     19.32    35.1    2010
    //      22     20.17    36.7    2205
    //      33     20.68    37.6    2205
    //      29     23.04    41.9    2445
    //      38     24.48    44.5    2445
    //
    // (the measurement that motivated the switch: utilization moving 22-38%
    // under a load that climbed smoothly). The cost was the whole left half of
    // the scale. An idle card draws ~4 W of 55 W, so a WORKING card could still
    // read a low teens percentage, and the tile then contradicted nvidia-smi,
    // the vendor tool and the user's own eyes -- reported as "the GPU shows 10%
    // when it is at 80-90%". A number that is right about watts and wrong
    // about what the reader asked is the worse error of the two.
    //
    // The wattage is not lost: the enforced limit and the live draw are still
    // sampled below, and the System tab draws them on its GPU power row
    // ("4.2 of 55 W"). Put the watts where they are labelled as watts.
    //
    // FALLBACK. On a machine with no NVIDIA part -- or a parked one answering
    // [N/A] -- utilization is unreadable, and the field falls back to the
    // graphics clock fraction the sysfs path supplies. That is a proxy for
    // load rather than a measure of it, which is why it is only the fallback.
    //
    // `[N/A]` parses to empty, i.e. to "unknown" (-1, drawn as "--"): a
    // missing reading must never masquerade as an idle card.
    readonly property string sampleCommand: `
t=$(cat ${root.tempPath.length > 0 ? root.tempPath : "/dev/null"} 2>/dev/null)
w=""; lim=""; cc=""; mm=""; gt=""; mu=""; mt=""; mx=""; pw=""
if command -v nvidia-smi >/dev/null 2>&1; then
  u=$(nvidia-smi --query-gpu=power.draw,clocks.current.graphics,enforced.power.limit,temperature.gpu,memory.used,memory.total,clocks.max.graphics,power.max_limit,utilization.gpu --format=csv,noheader,nounits -i 0 2>/dev/null | head -1)
  w=$(printf '%s' "$u" | cut -d, -f1 | tr -dc '0-9.')
  c=$(printf '%s' "$u" | cut -d, -f2 | tr -dc '0-9')
  lim=$(printf '%s' "$u" | cut -d, -f3 | tr -dc '0-9.')
  gt=$(printf '%s' "$u" | cut -d, -f4 | tr -dc '0-9.')
  mu=$(printf '%s' "$u" | cut -d, -f5 | tr -dc '0-9')
  mt=$(printf '%s' "$u" | cut -d, -f6 | tr -dc '0-9')
  mx=$(printf '%s' "$u" | cut -d, -f7 | tr -dc '0-9')
  # Appended LAST on purpose: every field above is addressed by index further
  # down the pipe, so a new one may only be added at the end.
  pw=$(printf '%s' "$u" | cut -d, -f8 | tr -dc '0-9.')
  # The load: utilization.gpu, which has no unit of its own in the CSV (it is
  # already a percentage). tr strips the trailing " %" some nvidia-smi builds
  # append even under nounits.
  # NOTE (backtick trap, see above): no backticks in this comment. Writing the
  # field name in shell-quoting style here terminates the enclosing JavaScript
  # template literal and takes SystemNow -- and every service importing it --
  # down with it.
  util=$(printf '%s' "$u" | cut -d, -f9 | tr -dc '0-9')
else
  cc=$(cat ${root.gpuCurPath.length > 0 ? root.gpuCurPath : "/dev/null"} 2>/dev/null | tr -dc '0-9')
  mm=$(cat ${root.gpuMaxPath.length > 0 ? root.gpuMaxPath : "/dev/null"} 2>/dev/null | tr -dc '0-9')
  c="$cc"
fi
# The processor: ONE awk pass over /proc/cpuinfo, which carries a live clock for
# every thread, for the mean and the highest of them -- then the two cpufreq
# files a power-mode switch actually rewrites. Stderr is discarded and an empty
# awk result is handled downstream (the fields come out empty and the parser
# reports -1), so a machine without cpufreq loses these rows and nothing else.
#
# TWO TRAPS BELOW, both from this being a JS template literal rather than a
# plain string: a stray BACKTICK ends it early, and a dollar-brace sequence is
# read as JavaScript interpolation. Either one gets the shell script after it
# parsed as JavaScript, which does not report "the script is wrong" -- it reports
# SystemNow.qml as unloadable and takes every service that imports it down too.
set -- $(awk '/cpu MHz/ { s += $4; n++; if ($4 > m) m = $4 } END { if (n > 0) printf "%.0f %.0f", s / n, m }' /proc/cpuinfo 2>/dev/null)
cavg=$1; cpeak=$2
gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null)
echo "v|$t|$w|$lim|$c|$cc|$mm|$gt|$mu|$mt|$mx|$cavg|$cpeak|$gov|$epp|$pw|$util"
`

    function sample() {
        if (!root.discovered || !root.active)
            return;
        sampleProc.command = ["sh", "-c", root.sampleCommand];
        sampleProc.running = false;
        sampleProc.running = true;
    }

    Timer {
        // ── The cadence IS the graph's time window ───────────────────────
        //
        // Four samples a second, not one, and that is a fix rather than a
        // taste. A history holds `historyLength` samples (60, the config's
        // number) whatever rate they arrive at, so the RATE decides how many
        // SECONDS the graph spans: at 1 Hz it spanned a minute, at 4 Hz it
        // spans fifteen seconds. Measured on this machine, the minute-long
        // window was the whole of the complaint that "the graph shows the GPU
        // at 100% fifteen to twenty seconds late": a load that steps from idle
        // to busy enters a 60-sample window as ONE sample, 1/60 of the graph's
        // width (3.5 px), which reads as nothing at all -- and it only became a
        // legible plateau after 10-20 more seconds had grown it from the right
        // edge. The processor's and memory's graphs never showed that because
        // their signals are never flat for a minute. At four samples a second
        // the same step is a visible rise within a second or two and a full
        // plateau inside the window's fifteen.
        //
        // The cost is why this is spelled out rather than assumed: each tick is
        // one `sh` and one nvidia-smi, and the nvidia-smi half measures at ~40
        // ms of wall time (32-40 ms over five runs) -- roughly a sixth of one
        // core while a surface is actually on screen, and nothing at all when
        // none is, because `active` gates the whole timer. The sub-second
        // cadence also has the side effect that every reading on the System tab
        // and the island's instruments (degrees, clocks, watts, VRAM, governor)
        // is a quarter-second old rather than a second old.
        //
        // The reason the number can move this fast at all is that the SHELL
        // measures and this parses (see sampleCommand): util comes off
        // utilization.gpu in the same line as everything else, so a faster tick
        // costs no extra query, and there is no second sampling path to keep in
        // step with this one.
        //
        // The cadence and the DRAWN window are two halves of one answer: this
        // decides how fresh a reading is and how long the history spans, and
        // gpuWindowSeconds (above) decides how much of that history a graph
        // shows. Raising the rate without it shortened the window and still
        // took fifteen seconds to read as a plateau; see the note there.
        interval: root.sampleIntervalMs
        repeat: true
        running: root.active && root.discovered
        onTriggered: root.sample()
    }

    onActiveChanged: {
        if (!root.active)
            return;
        // Sampling STARTS here (the island's performance view came up, or the
        // panel opened).
        //
        // The histories hold whatever was sampled the last time someone looked,
        // which makes them a window over "the samples we happened to take",
        // not over the last minute: close the panel while the graphics card is
        // busy and reopen it an hour later and the graph still drew that busy
        // plateau while the number above it said 4% -- and the other way round,
        // an idle window drew a flat line under a busy card. The first sample
        // of this session therefore REPLACES the window rather than extending
        // it, the same contract ResourceUsage.primeHistories() keeps for the
        // processor and memory, so the graph is full width immediately and its
        // right-hand end is always the number above it.
        root.freshWindow = true;
        root.sample();
    }

    function pushHistories() {
        const cap = root.historyLength;
        const seed = v => Array.from({ length: cap }, () => v);
        const push = (arr, v) => {
            if (root.freshWindow)
                return seed(v);
            const next = [...arr, v];
            while (next.length > cap) next.shift();
            return next;
        };
        let pushed = false;
        if (root.tempC >= 0) {
            root.tempHistory = push(root.tempHistory, root.tempC);
            root.tempLoadHistory = push(root.tempLoadHistory, root.tempLoad(root.tempC));
            pushed = true;
        }
        if (root.gpuMetricPct >= 0) {
            root.gpuHistory = push(root.gpuHistory, root.gpuMetricPct);
            pushed = true;
        }
        // Only a sample that carried data ends the priming: a tick that read
        // nothing (driver asleep, no hwmon) must not leave the window
        // half-primed and half-stale.
        if (pushed)
            root.freshWindow = false;
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
    // Vram, as used / total, so the reader can see the ceiling as well as the
    // load -- "7.4 GB" alone does not say whether that is most of the card.
    function vramText() {
        if (root.gpuVramUsedMiB < 0 || root.gpuVramTotalMiB <= 0)
            return "--";
        return `${(root.gpuVramUsedMiB / 1024).toFixed(1)} / ${(root.gpuVramTotalMiB / 1024).toFixed(1)} GB`;
    }
    // Mean and peak of the live per-thread clocks. The peak is dropped when it
    // equals the mean (a machine whose cores all sit together), so the common
    // case reads as one number rather than two identical ones.
    function cpuClockText() {
        if (root.cpuClockGhz < 0)
            return "--";
        return root.cpuPeakGhz > root.cpuClockGhz + 0.05
            ? `${root.cpuClockGhz.toFixed(1)} avg · ${root.cpuPeakGhz.toFixed(1)} peak GHz`
            : `${root.cpuClockGhz.toFixed(1)} GHz`;
    }
    function cpuPolicyText() {
        if (root.cpuGovernor === "" && root.cpuEpp === "")
            return "--";
        return root.cpuEpp === "" ? root.cpuGovernor : `${root.cpuGovernor} · EPP ${root.cpuEpp}`;
    }

    IpcHandler {
        target: "systemNow"
        function state(): string {
            return `discovered=${root.discovered} temp=${root.tempPath} gpu=${root.gpuCurPath} max=${root.gpuClockMaxMhz} active=${root.active}`;
        }
        // Every reading the System tab's rows are built from, on one line, so
        // those rows can be checked WITHOUT a pointer: the three-finger swipe
        // that opens the card is not a thing a test can perform, and a row
        // rendering "—" looks exactly like a source that never ran.
        function values(): string {
            return `cpu=${root.pct(root.cpuPct)} ram=${root.pct(root.ramPct)} gpu=${root.pct(root.gpuMetricPct)} temp=${root.tempText(root.tempC)}`
                + ` gpuDiscrete=${root.pct(root.gpuClockPct)} gpuIntegrated=${root.pct(root.intelGpuPct)}`
                + ` clock=${root.cpuClockText()} policy=${root.cpuPolicyText()}`
                + ` draw=${root.gpuPowerDrawW < 0 ? "--" : root.gpuPowerDrawW.toFixed(1)}W`
                + ` limit=${root.gpuPowerLimitW < 0 ? "--" : Math.round(root.gpuPowerLimitW)}W`
                + ` max=${root.gpuPowerMaxW < 0 ? "--" : Math.round(root.gpuPowerMaxW)}W`
                + ` gpuTemp=${root.tempText(root.gpuTempC)} vram=${root.vramText()}`;
        }
        // Drive the sampler without a pointer (the shell's usual test affordance).
        function probe(): void {
            root.active = true;
            root.sample();
        }
        // The SERIES the graph is drawn from, not just the number above it.
        //
        // The two are written by the same handler into the same pair of
        // properties, so they can only disagree in one place -- the drawing
        // (see the metric band's canvas in NowBarPanel.qml). Reading them side
        // by side is what tells the two apart: `pct` and `tail` are the data
        // (and must always match), while what the canvas PAINTED is a separate
        // question that only a screenshot can answer.
        //
        //   qs -c ii ipc call systemNow series
        function series(): string {
            const fmt = (v) => Number.isFinite(v) ? v.toFixed(2) : "-";
            const g = root.gpuHistory ?? [];
            const t = root.tempLoadHistory ?? [];
            const cpu = ResourceUsage.cpuUsageHistory ?? [];
            // How much of the window is drawn HIGH -- the plateau's width, as a
            // fraction of the graph. This is the number the reaction-time
            // question is actually about: a load that steps from idle to busy is
            // legible once the high samples are a visible share of the width,
            // and a sample is 1/len of that width whatever the cadence (so the
            // RATE decides how many seconds it takes to get there).
            const hi = g.filter(v => v >= 0.5).length;
            // The same fraction over the slice a graph actually PAINTS, which
            // is the number the reaction-time question is really about now
            // (see gpuWindowSeconds): `hi` counts a window nobody sees.
            const win = root.gpuWindowPoints;
            const drawn = g.slice(Math.max(0, g.length - win));
            const dhi = drawn.filter(v => v >= 0.5).length;
            return `active=${root.active} fresh=${root.freshWindow} rev=${root.revision}`
                + ` pct=${fmt(root.gpuClockPct)}`
                + ` gpu[n=${g.length} hi=${hi} high=${g.length ? (hi / g.length * 100).toFixed(0) : "--"}%`
                + ` win=${win} drawn=${drawn.length ? (dhi / drawn.length * 100).toFixed(0) : "--"}%`
                + ` head=${g.length ? fmt(g[0]) : "-"} tail=${g.length ? fmt(g[g.length - 1]) : "-"}]`
                + ` temp[n=${t.length} tail=${t.length ? fmt(t[t.length - 1]) : "-"}]`
                + ` cpu[n=${cpu.length} tail=${cpu.length ? fmt(cpu[cpu.length - 1]) : "-"}]`;
        }
        function off(): void {
            root.active = false;
        }
    }
}
