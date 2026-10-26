pragma Singleton
pragma ComponentBehavior: Bound

import qs.services

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Removable media, announced.
 *
 * Plugging a stick in and hearing nothing happened is a complaint about the
 * SESSION, not about a window that happens to be closed, so the answer does not
 * live in the file manager: this reads `lsblk` on a slow timer -- the cheap
 * version of a hotplug bus, no udev rule to install and no daemon to keep -- and
 * speaks up when a device arrives or leaves.
 *
 * WHY THE DIFF IS BY DISK, NOT BY PARTITION. A card that is read for the first
 * time goes from one partition-less device to eight partitions inside a single
 * poll, and a per-partition diff answers that with eight notifications for one
 * card. What changed, as far as the person who pushed it in is concerned, is
 * one device: the disk node. So the disk node is what is watched, and the
 * partitions it carries are only there to describe it -- one line per thing you
 * can hold.
 *
 * Internal disks are deliberately absent from all of this. A notification every
 * time a laptop's NVMe re-appears would be noise about hardware nobody moved.
 *
 * AND IT CLICKS.  A device going in is something you DO with your hands, so
 * the sound that answers it is the sound of the thing happening -- a short,
 * bright, dry CLICK, the snap of a controller seating on its console -- not
 * the session's notification sound. See the sound section below for why that
 * distinction is worth a whole feature and two synthesized files.
 */
Singleton {
    id: root

    // device path -> record. Both disks and their partitions, because the
    // partitions are what describe a disk in the notification text.
    property var known: ({})
    // The first poll is a census, not an event: whatever was already plugged in
    // when the shell started must not be announced as newly inserted.
    property bool primed: false
    property int pollCount: 0
    property string lastEvent: ""
    property int noticed: 0

    // ── Telling drives apart ────────────────────────────────────────────
    // `tran` says how a device is attached (usb / mmc / nvme / sata) and `rota`
    // says whether the medium spins. The second is the only honest way to tell
    // an SSD from an HDD on the same transport; guessing from the name is
    // guessing.
    function classify(tran, removable, rotational) {
        const t = String(tran ?? "").toLowerCase();
        if (t === "mmc" || t === "mmcblk") return "sd";
        if (t === "usb" || removable === true) return "usb";
        if (t === "nvme" || rotational === false) return "ssd";
        if (rotational === true) return "hdd";
        return "disk";
    }
    function kindWord(kind) {
        switch (kind) {
        case "sd": return Translation.tr("SD card");
        case "usb": return Translation.tr("USB stick");
        case "ssd": return Translation.tr("Solid-state drive");
        case "hdd": return Translation.tr("Hard disk");
        // The two kinds the USB census below reports: a device that speaks MTP
        // is a phone (or a camera, and it is mounted the same way), everything
        // else on a pluggable port is simply a thing that was plugged in.
        case "phone": return Translation.tr("Phone or camera");
        case "usbdev": return Translation.tr("USB device");
        default: return Translation.tr("Drive");
        }
    }
    function fmtSize(bytes) {
        const b = Number(bytes ?? 0);
        if (!isFinite(b) || b <= 0) return "";
        const units = ["B", "KB", "MB", "GB", "TB"];
        let i = 0, n = b;
        while (n >= 1000 && i < units.length - 1) { n /= 1000; i++; }
        return (n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)) + " " + units[i];
    }
    // One line about a device, built from its partitions when it has any: the
    // label of the first filesystem is the name a person recognises a stick by
    // ("USBSTICK"), and the disk node of that same stick usually has none.
    function summarize(diskPath, records) {
        const vols = [];
        let disk = null;
        for (const p in records) {
            if (p === diskPath) {
                disk = records[p];
                // A stick without a partition table carries its filesystem on
                // the disk node itself; that is a volume like any other, and
                // reporting it as "no filesystem found" would be a lie about a
                // perfectly readable stick.
                if (records[p].hasFs) vols.push(records[p]);
            } else if (records[p].disk === diskPath && records[p].hasFs) {
                vols.push(records[p]);
            }
        }
        const parts = [];
        if (vols.length > 0) {
            const labels = vols.map(v => v.label.length > 0 ? v.label : v.name);
            if (labels.length <= 2) parts.push(labels.join(", "));
            else parts.push(labels.length + " " + Translation.tr("volumes"));
            if (vols.length === 1 && vols[0].fstype.length > 0)
                parts.push(vols[0].fstype.toUpperCase());
            const total = vols.reduce((a, v) => a + v.size, 0);
            const size = total > 0 ? total : Number(disk?.size ?? 0);
            if (size > 0) parts.push(root.fmtSize(size));
            if (vols.length === 1 && vols[0].mountpoint.length > 0)
                parts.push(vols[0].mountpoint);
        } else {
            // No filesystem anywhere on it -- a card whose partition table the
            // kernel has not read yet, which is exactly the case worth saying
            // out loud instead of staying silent about.
            const name = (disk?.model?.length > 0) ? disk.model
                : (disk?.name?.length > 0 ? disk.name : diskPath);
            parts.push(name);
            parts.push(Translation.tr("no filesystem found"));
            if (Number(disk?.size ?? 0) > 0) parts.push(root.fmtSize(disk.size));
        }
        return parts.join(" · ");
    }
    // ── The click you hear when a drive goes in ─────────────────────────
    //
    // WHAT WAS WRONG. The notification that announces a stick used the
    // session's notification sound, which is a soft, low "drop" -- measured
    // on this machine: /usr/share/sounds/freedesktop/stereo/message.oga is
    // 311 ms long with almost no high-frequency content (first-difference
    // energy ratio 0.01, 1700 zero crossings a second). It is also the same
    // sound every OTHER notification makes, so it says "a message arrived"
    // about a piece of hardware you just pushed into a port -- and the one
    // thing a device arriving is not, is a notification.
    //
    // WHAT IT IS NOW. A click cut from a recording: 200 ms at -1 dBFS, and
    // (REQUESTED 2026-10-11) that level is deliberate -- it used to be -6,
    // which put a 200 ms transient well under the music playing beside it, so
    // the click was easy to miss exactly when a drive went in. Peaking just
    // under full scale makes it read above music and above the other chimes.
    //
    // AND IT PLAYS ABOVE THE ROW (REQUESTED 2026-10-14: "slightly louder than
    // now so it's over the music"). -1 dBFS is the sample's ceiling -- there is
    // nowhere left to raise the file, and limiting its decay would change the
    // click into something else -- so the second half of the answer is a
    // playback gain, `deviceSoundGain` below. The sample and the gain are one
    // decision made in two places, which is why they are described together.
    //
    // shipped as assets/sounds/device-insert.wav. It was synthesised here
    // first (scripts/system/make-device-sounds.py still holds that recipe) and
    // then replaced, because the sound wanted was one specific recording --
    // the momentary click a console makes -- that the recipe did not match to
    // taste. `scripts/system/import-device-sound.py` finds the attack in a
    // source recording, trims the half-second of room that trails it, and
    // writes the pair.
    //
    // Removing a device plays the SAME samples backwards -- not a second
    // recording, and not the same sound lowered: the two halves are one cut of
    // one click, so unplugging is the same gesture going the other way, and
    // the check suite asserts that reversal sample for sample.
    //
    // TWO THINGS THIS DELIBERATELY DOES NOT DO:
    //   * it does not play both. The notification goes out with the
    //     `suppress-sound` hint -- which the shell's own Notifications service
    //     honours ("suppress-sound" is the freedesktop hint for exactly this)
    //     -- so the click IS the sound of the announcement, not a second layer
    //     on top of the drop.
    //   * it does not add a switch of its own. The click is played through
    //     Audio.playSystemSoundFile, which applies the mixer's "System
    //     Sounds" row: turning that row down or muting it silences the click
    //     along with the battery and timer chimes, and spawns nothing at all
    //     when it is off.
    readonly property string insertSoundPath: Quickshell.shellPath("assets/sounds/device-insert.wav")
    readonly property string removeSoundPath: Quickshell.shellPath("assets/sounds/device-remove.wav")
    // Counted because it is the only part of this a terminal cannot hear:
    // `state` reports it, so the check suite can assert that a device going in
    // actually asked for the click (and that a muted mixer asks for nothing).
    property int chimed: 0
    property int silent: 0
    // ── How far above a chime the click plays ────────────────────────────
    //
    // REQUESTED (2026-10-14): "slightly louder than now so it's over the
    // music". The sample has no headroom left to give. Measured on the shipped
    // pair: the attack sits at -1.00 dBFS (29203) and the useful part of the
    // click is its first 30 ms, while the remaining 170 ms decays from -28 to
    // -44 dBFS -- a crest factor of 23.6 dB, which is exactly why a 200 ms
    // transient at full scale still reads as quiet beside music at the same
    // mixer setting (music carries about 10 dB of crest). Raising the FILE is
    // not available: -1 dBFS is deliberate headroom and 0 dBFS is clipping.
    //
    // So the boost is a playback factor, and a named one rather than a nudge to
    // the System Sounds row. The row is the control for every system sound and
    // it stays the control: at 0 or muted this spawns nothing at all, and the
    // sink still applies its own volume as it does to music. What the row is
    // NOT is the right place to solve this one sound's problem -- a chime that
    // plays over silence does not need to beat anything, while this click has
    // to be heard WHILE music is playing, with a hand still on the stick.
    //
    // +3.5 dB (1.5x) is "slightly": about a third of the way to the point
    // where a click stops being an announcement and becomes painful, and small
    // enough that the sink at 100% with the row at 100% is the only corner of
    // the volume range where the attack can touch the ceiling.
    // ── 1.0, not 1.5: the factor never worked ───────────────────────────────
    //
    // This used to be 1.5 (+3.5 dB) on the argument above -- and it was a
    // no-op: `pw-play --volume` clamps at 1.0 (measured 2026-10-26; a 1.5
    // stream comes up at 65536 / 100 %), so the click has always played at
    // exactly the mixer row. The sample is already peak-normalised at
    // -1.0 dBFS, which is the ceiling for a file, and a stream cannot go
    // above 100 % through this player (see Audio.playSystemSoundFile for why
    // paplay is not an option: it cannot carry the mixer mark). So the honest
    // value is 1.0, and what was really needed -- the click being audible over
    // music -- came from the music side: MusicPlayer's start volume is no
    // longer 80 % of a full-scale master.
    readonly property real deviceSoundGain: 1.0
    function playDeviceSound(inserted: bool): bool {
        const path = inserted ? root.insertSoundPath : root.removeSoundPath;
        const played = Audio.playSystemSoundFile(path, root.deviceSoundGain);
        if (played)
            root.chimed++;
        else
            root.silent++;
        return played;
    }
    function announce(kind, inserted: bool, body) {
        const title = root.kindWord(kind) + " "
            + (inserted ? Translation.tr("inserted") : Translation.tr("removed"));
        // `-h boolean:suppress-sound:true`: no drop over the click. A malformed
        // hint makes notify-send fail outright, so a typo here would take the
        // announcement down with it -- which is the one thing this must not do.
        Quickshell.execDetached(["notify-send", title, body, "-a", "Shell",
            "-h", "boolean:suppress-sound:true"]);
        root.playDeviceSound(inserted);
        root.lastEvent = title + " — " + body;
        root.noticed++;
        console.log(`[volumes] ${title}: ${body}`);
    }

    // ── Reading the bus ─────────────────────────────────────────────────
    Process {
        id: lsblkProc
        command: ["bash", "-c",
            "lsblk -J -b -o NAME,PATH,LABEL,FSTYPE,SIZE,TYPE,TRAN,RM,MODEL,MOUNTPOINTS,ROTA,PKNAME 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: root.consume(this.text)
        }
    }
    function poll() {
        lsblkProc.running = false;
        lsblkProc.running = true;
    }
    // ── The fast half: the kernel's own announcement ────────────────────
    //
    // The timer below is a census, and a census is always late: a stick that
    // goes in is announced by the NEXT tick, up to three seconds later, which is
    // long enough for the hand to have left the stick -- and then the click feels
    // like a reply to something else. The device does not have to be waited for.
    // The kernel says so, on a socket, and `udevadm monitor` is that stream: one
    // line per event. It costs nothing while nothing is happening (it is a
    // blocking read, not a process that wakes up) and it answers in about a
    // tenth of a second.
    //
    // Both subsystems, because both are pluggable: `block` is the stick and the
    // card, `usb` is the phone -- which is never a block device at all. The poll
    // stays, as the safety net for a device that was already in and for an event
    // that was somehow missed.
    Process {
        id: hotplugWatch
        command: ["udevadm", "monitor", "--udev", "--subsystem-match=block", "--subsystem-match=usb"]
        running: true
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => {
                const event = String(line ?? "");
                // add/remove are the two that matter, and change because a card
                // whose partition table the kernel has just read is announced
                // that way -- which is exactly the SD card that "does not show
                // up" for the first few seconds.
                if (event.indexOf(" add ") === -1 && event.indexOf(" remove ") === -1
                        && event.indexOf(" change ") === -1)
                    return;
                root.hotplugEvents++;
                hotplugDebounce.restart();
                // The phone half: only a USB event can mean one arrived, and
                // "(usb)" is how udevadm spells the subsystem it came from.
                if (event.indexOf("(usb)") !== -1) {
                    // Both halves: the notice about what arrived, and the phone
                    // mount, which needs its own longer grace period.
                    usbScanDebounce.restart();
                    mtpScanDebounce.restart();
                }
            }
        }
        // A watcher that is dead would leave only the slow census behind, and
        // the difference is the whole point of it, so it is put back.
        onExited: hotplugRestart.running = true
    }
    Timer {
        // One insertion arrives as several lines (the disk, each partition, the
        // by-id links); one poll answers all of them.
        id: hotplugDebounce
        interval: 120
        onTriggered: root.poll()
    }
    Timer {
        id: hotplugRestart
        interval: 3000
        onTriggered: hotplugWatch.running = true
    }
    // Counted, and reported through `state`, because it is the only part of the
    // fast path a terminal cannot see: a check asserts that events are being
    // received at all (the watcher is alive and the socket is readable), rather
    // than trusting that a stream which prints nothing is working.
    property int hotplugEvents: 0
    Timer {
        // Three seconds, and no longer the thing that decides how fast a stick
        // is noticed: the udev stream above does that. This is the census that
        // keeps the diff honest -- it catches a device that was already plugged
        // in when the shell started, and anything an event missed.
        interval: 3000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.poll()
    }

    function consume(text) {
        let parsed = null;
        try {
            parsed = JSON.parse(String(text ?? ""));
        } catch (e) {
            return;   // a torn read is not a device change
        }
        const now = {};
        const walk = (node, parent) => {
            const type = String(node.type ?? "");
            if (type === "loop" || type === "zram")
                return;
            const tran = String(node.tran ?? parent?.tran ?? "").trim().toLowerCase();
            const removable = (node.rm === true || node.rm === "1");
            const rotational = (node.rota === true || node.rota === "1");
            const external = removable || tran === "usb" || tran === "mmc";
            const fstype = String(node.fstype ?? "");
            const hasFs = fstype.length > 0 && fstype.toLowerCase() !== "swap";
            if (external && (hasFs || ["disk", "part"].includes(type))) {
                const mounts = (node.mountpoints ?? []).filter(m => m && String(m).length > 0);
                const name = String(node.name ?? "");
                now[String(node.path ?? "")] = {
                    name: name,
                    disk: "/dev/" + String(node.pkname ?? name),
                    type: type,
                    label: String(node.label ?? ""),
                    fstype: hasFs ? fstype : "",
                    hasFs: hasFs,
                    size: Number(node.size ?? 0),
                    model: String(parent?.model ?? node.model ?? "").trim(),
                    mountpoint: mounts.length > 0 ? String(mounts[0]) : "",
                    kind: root.classify(tran, removable, rotational)
                };
            }
            for (const kid of (node.children ?? []))
                walk(kid, node);
        };
        for (const disk of (parsed?.blockdevices ?? []))
            walk(disk, null);
        root.pollCount++;
        if (root.primed) {
            root.diff(root.known, now);
            // The same arrival the click above announces is the arrival that
            // gets mounted. After the diff and before `known` is replaced, so
            // both halves read the same pair of tables.
            root.autoMount(now);
        }
        root.known = now;
        root.primed = true;
    }
    // Only disk nodes are announced, for the reason in the header: one device
    // in your hand is one event. The direction is passed as a BOOLEAN, not as
    // the translated word: the sound and the title are both chosen from it, and
    // deciding a sound by comparing against a translated string would break the
    // moment the shell runs in another language.
    function diff(before, after) {
        for (const p in after) {
            if (p in before) continue;
            if (after[p].type !== "disk") continue;
            root.announce(after[p].kind, true, root.summarize(p, after));
        }
        for (const p in before) {
            if (p in after) continue;
            if (before[p].type !== "disk") continue;
            root.announce(before[p].kind, false, root.summarize(p, before));
        }
    }

    // ── Auto-mounting: a stick only has to be pushed in ─────────────────
    //
    // REQUESTED (2026-10-11): disposable media -- a USB stick, an SD card, a
    // phone -- should be mounted the moment it is plugged in, with no prompt
    // and nothing clicked. Two halves, and both are needed:
    //
    //   * the AUTOMATION is here. The census above already knows when a device
    //     arrives and already excludes internal disks, so the volume is mounted
    //     in the session -- no window open, nothing to click;
    //   * the PERMISSION is a polkit rule, because `/usr/bin/mount` through
    //     pkexec is a password prompt until polkit is told otherwise. That rule
    //     is extras/etc/polkit-1/rules.d/10-ii-removable-mount.rules in this
    //     config, installed by install.sh -- the same file the file manager's
    //     own note names. Without it this code still runs and still asks.
    //
    // THE COMMAND IS THE FILE MANAGER'S COMMAND. Same mount point
    // (/run/media/<user>/<label>), same uid=/gid= options that make an exFAT or
    // NTFS stick writable by whoever plugged it in, same `--mkdir` so that
    // mount creates the directory itself -- which is what lets the polkit rule
    // name /usr/bin/mount rather than bless a shell. See mountVolume,
    // mountOptions and mountPointFor in modules/filemanager. Two mount points
    // for one stick would present as a drive that is mounted and invisible at
    // the same time, which is the only thing this duplication is for.
    //
    // ONCE PER PLUG is the whole of the policy: a device already seen is left
    // alone, so unmounting a drive to be safe is not undone by the next
    // census, and its key is dropped when it goes away, so plugging it back in
    // mounts it again.
    //
    // WHAT IS NOT AUTOMATIC, deliberately:
    //   * squashfs / erofs / iso9660 / udf -- images and read-only payloads
    //     (the SD card's own Home Assistant partitions are two of them).
    //     Mounting those on arrival would file four read-only rows into the
    //     sidebar for nobody's benefit; they mount on demand, as before;
    //   * internal disks -- absent from the census by construction, above;
    //   * a device with no filesystem YET -- the card whose partition table the
    //     kernel has not read. It is deliberately NOT marked as tried, so the
    //     poll after the table lands mounts it, instead of the arrival being
    //     spent on a `mount` that could not have worked;
    //   * whatever was already plugged in when the shell started -- the first
    //     census is a census (see `primed`), and mounting somebody's drive
    //     behind their back at login is not what "auto mount" was asked for.
    readonly property string userName: Quickshell.env("USER") ?? "user"
    // The same constant the file manager uses for its own `userUid`: there is
    // one desktop user, and spawning `id -u` per mount to learn it would be a
    // process to read a literal.
    readonly property int userUid: 1000
    readonly property var readOnlyImages: ["squashfs", "erofs", "iso9660", "udf"]
    // device path -> mounted-or-attempted under this plug.
    property var autoTried: ({})
    property int autoMounts: 0
    property int autoMountFailures: 0
    // The last command actually issued, kept because it is the only part of
    // this a terminal cannot see: `state` reports it, so a check can assert the
    // exact argv shape (and the polkit rule that has to allow it) without a
    // stick in the machine.
    property string autoMountCommand: ""
    // And what the last attempt SAID, which is the difference between the two
    // ways this can fail: "mount: /dev/sdX1: no such device" is the drive, a
    // polkit line is the rule, and only one of them is this feature's fault.
    property string autoMountNote: ""
    function shq(s) {
        return "'" + String(s ?? "").replace(/'/g, "'\\''") + "'";
    }
    function autoMountNameFor(rec) {
        const source = rec.label.length > 0 ? rec.label : String(rec.name ?? "");
        const clean = source.replace(/[^\w.-]+/g, "_");
        return clean.length > 0 ? clean : String(rec.name ?? "drive");
    }
    function autoMountPointFor(rec) {
        return `/run/media/${root.userName}/${root.autoMountNameFor(rec)}`;
    }
    function autoMountOptions(fstype) {
        const fs = String(fstype ?? "").toLowerCase();
        if (["exfat", "vfat", "ntfs", "ntfs3", "fuseblk"].includes(fs))
            return `uid=${root.userUid},gid=${root.userUid},noatime`;
        return "noatime";
    }
    function autoMountable(rec) {
        if (!rec || !rec.hasFs || rec.mountpoint.length > 0) return false;
        return !root.readOnlyImages.includes(String(rec.fstype).toLowerCase());
    }
    // The pass that runs after every census. `now` is the fresh table, so a
    // device that is gone takes its "tried" mark with it on the way out.
    function autoMount(now) {
        const tried = Object.assign({}, root.autoTried);
        for (const p in tried)
            if (!(p in now)) delete tried[p];
        const cmds = [];
        for (const p in now) {
            const rec = now[p];
            // A record with no filesystem yet is not spent -- see the note
            // above -- so it is skipped BEFORE the mark, unlike the rest.
            if (!rec.hasFs) continue;
            if (tried[p]) continue;
            if (!root.autoMountable(rec)) continue;
            tried[p] = true;
            // A FAILURE HAS TO MOVE THE EXIT STATUS, not just print. The first
            // cut of this line ended `|| echo "auto-mount failed: …"`, which
            // makes the whole script exit 0 whatever mount did -- so the count
            // below credited a failed mount as a mounted drive, and the state
            // line agreed with it. (Found by unmounting a real stick and
            // watching the counter.) `fail=1` is what the exit status reads.
            cmds.push(`pkexec /usr/bin/mount --mkdir -t ${root.shq(rec.fstype)}`
                + ` -o ${root.shq(root.autoMountOptions(rec.fstype))}`
                + ` ${root.shq(p)} ${root.shq(root.autoMountPointFor(rec))}`
                + ` || { echo "auto-mount failed: ${p}"; fail=1; }`);
        }
        root.autoTried = tried;
        if (cmds.length === 0) return cmds.length;
        // Reported as ONE line and run as several: `state` is read by checks as a
        // single string, and a newline in it would turn every field after it
        // into a line of its own.
        root.autoMountCommand = cmds.join(" ; ");
        automountProc.script = "fail=0\n" + cmds.join("\n") + "\nexit $fail";
        automountProc.running = false;
        automountProc.running = true;
        return cmds.length;
    }
    Process {
        id: automountProc
        property string script: ""
        command: ["bash", "-c", automountProc.script]
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => {
                const text = String(line ?? "");
                root.autoMountNote = text;
                if (text.indexOf("auto-mount failed:") === 0)
                    root.autoMountFailures++;
                console.log(`[volumes] ${text}`);
            }
        }
        // The census is asked again, so a mount that landed shows up as a
        // mountpoint in the very next table rather than one poll later.
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0) root.autoMounts++;
            root.poll();
        }
    }

    // ── Phones: the other half of "disposable", and not a block device ───
    //
    // A phone in file-transfer mode has no /dev node, so it is never in the
    // census above and `mount` is never the answer for it. What it needs is a
    // FUSE mounter -- aft-mtp-mount, which is already installed and needs no
    // privilege at all: it mounts under XDG_RUNTIME_DIR as this user, which is
    // exactly what "no admin password" means for a phone.
    //
    // Driven by the USB half of the udev stream ABOVE, not by the census: the
    // scan is a walk of /sys/bus/usb, and doing it every three seconds forever
    // would be a process spawn per tick to answer a question that only changes
    // when a cable moves. The debounce is longer than the block one because a
    // phone needs a moment to enumerate its MTP interface after the device
    // itself appears -- the same few seconds the file manager's own "looking
    // for the phone" note covers.
    readonly property string mtpRoot: (Quickshell.env("XDG_RUNTIME_DIR") ?? "/tmp") + "/mtp"
    readonly property string mtpScanScript: Quickshell.shellPath("scripts/system/mtp-devices.sh")
    // Readable phones only: a mount point that lists something. See
    // mtpRefusing below for the mounts that are up and answering nothing.
    property var mtpMounted: ({})
    // Mounts that are UP and REFUSING (the phone was locked, or its "allow
    // access to phone data" prompt was still unanswered, when the session was
    // opened): directory to the entry count the scan saw, so 0 is a live empty
    // directory and -1 is a session that did not answer at all. These are the
    // case this whole block used to get wrong -- a phone mounted at plug time
    // by the shell is not evidence that the phone is open, and treating it as
    // open left an empty folder on screen for the rest of the session with
    // nothing ever asking again.
    property var mtpRefusing: ({})
    property var mtpAutoTried: ({})
    // Attempts made per mount point since it was plugged in, and the ones the
    // SHELL opened (whether or not the phone has answered yet). Both are
    // forgotten when the device leaves the bus: a replug is a new complaint,
    // not a remembered one. mtpOpened is what makes "auto mounted" mean
    // something: a phone that starts answering after the attempt is still this
    // shell's doing, and it is confirmed on whichever later scan sees it.
    property var mtpRepairs: ({})
    property var mtpOpened: ({})
    // Six attempts, four seconds apart: the hand that plugs a phone in unlocks
    // it and taps the phone's own prompt within a few seconds, and a refused
    // session only yields to a FRESH one, so the retry is the whole mechanism.
    // Bounded because a device that refuses for a minute is not going to start
    // answering on the tenth ask, and a loop with no cap is how a hotplug
    // handler turns into a background process.
    readonly property int mtpRepairLimit: 6
    readonly property int mtpRepairSpacing: 4000
    property int mtpAutoMounts: 0
    property int mtpScans: 0
    // Its label and its directory: the SAME rule the file manager uses
    // (mtpLabel/mtpMountPoint there), because the two have to agree on where a
    // phone is mounted -- the app reads the mount table to decide whether the
    // phone it can see is open, and "mounted somewhere else" reads as closed.
    function mtpLabelOf(d) {
        const product = String(d?.product ?? "");
        if (product.length > 0) return product;
        const maker = String(d?.manufacturer ?? "");
        if (maker.length > 0) return maker;
        return Translation.tr("Phone or camera");
    }
    function mtpMountPointOf(d) {
        const clean = String(root.mtpLabelOf(d)).replace(/[^\w.-]+/g, "_");
        return root.mtpRoot + "/" + (clean.length > 0 ? clean : "device");
    }
    function scanMtp() {
        mtpScanProc.running = false;
        mtpScanProc.running = true;
    }
    Process {
        id: mtpScanProc
        command: ["bash", root.mtpScanScript]
        stdout: StdioCollector {
            onStreamFinished: root.autoMountPhones(this.text)
        }
    }
    // One attempt at a fresh session for a mount point.
    //
    // It is the only thing that can help, and the take-down half is not
    // optional: an AFT session that was refused storages answers "nothing" for
    // its whole life, so mounting on top of it changes nothing. `fusermount -u`
    // normally takes its process with it, and `pkill` is there for when it does
    // not -- a leftover holder keeps the phone's single MTP interface claimed,
    // and a mount that cannot claim it comes up as another empty directory
    // (measured on this machine: libusb_claim_interface() reports device is
    // busy, and aft-mtp-mount still exits 0).
    function mtpMountCommand(dir) {
        const d = root.shq(dir);
        return `mkdir -p ${d}`
            + `; fusermount3 -u ${d} >/dev/null 2>&1 || fusermount -u ${d} >/dev/null 2>&1 || umount ${d} >/dev/null 2>&1`
            + `; pkill -x -f ${root.shq("aft-mtp-mount " + dir)} >/dev/null 2>&1`
            + `; aft-mtp-mount ${d} >/dev/null 2>&1 || { echo "phone mount failed: ${dir}"; fail=1; }`;
    }
    function autoMountPhones(text) {
        root.mtpScans++;
        const readable = {};
        const refusing = {};
        const devices = [];
        for (const raw of String(text ?? "").split("\n")) {
            const line = raw.trim();
            if (line.indexOf("mounts|") === 0) {
                const parts = line.split("|");
                const dir = String(parts[1] ?? "").trim();
                if (dir.length === 0) continue;
                // The third field is how many entries the mount LISTS (see
                // scripts/system/mtp-devices.sh): >0 readable, 0 refused,
                // -1 did not answer. Missing on purpose is not possible -- an
                // older script without the field reads as unreadable, which
                // errs towards asking again rather than towards showing an
                // empty folder.
                const entries = Number(String(parts[2] ?? "-1"));
                if (entries > 0) readable[dir] = true;
                else refusing[dir] = Number.isFinite(entries) ? entries : -1;
                continue;
            }
            if (line.indexOf("dev|") !== 0) continue;
            const f = line.split("|");
            if (f.length < 6) continue;
            devices.push({ name: f[1], manufacturer: f[4], product: f[5] });
        }
        root.mtpMounted = readable;
        root.mtpRefusing = refusing;
        // Same once-per-plug rule as the drives: a phone that is not there any
        // more forgets that it was tried, a phone that is readable is left
        // alone, and a phone the user ejected stays ejected until it is
        // replugged. The one thing that renews the budget on its own is a
        // mount that is REFUSING: that is not a phone in use, it is a phone
        // whose permission arrived after the session did.
        const tried = {};
        const repairs = {};
        const opened = {};
        const cmds = [];
        for (const d of devices) {
            const dir = root.mtpMountPointOf(d);
            const made = Number(root.mtpRepairs[dir] ?? 0);
            const ours = root.mtpOpened[dir] === true;
            if (readable[dir]) {
                tried[dir] = true;
                // Counted here and not on the mounter's exit status: exit 0 is
                // what an empty tree looks like too. "Automounted" means the
                // phone ended up READABLE.
                if (ours) root.mtpAutoMounts++;
                continue;
            }
            tried[dir] = true;
            const refusingHere = Object.prototype.hasOwnProperty.call(refusing, dir);
            const act = !root.mtpAutoTried[dir]
                || (refusingHere && made < root.mtpRepairLimit);
            if (act) {
                repairs[dir] = made + 1;
                opened[dir] = true;
                cmds.push(root.mtpMountCommand(dir));
            } else if (made > 0 || ours) {
                // Still not readable and no longer asking: remembered as tried
                // so the budget is not renewed by a scan that changes nothing,
                // and remembered as ours so a late unlock still counts.
                repairs[dir] = made;
                opened[dir] = true;
            }
        }
        root.mtpAutoTried = tried;
        root.mtpRepairs = repairs;
        root.mtpOpened = opened;
        if (cmds.length === 0) return;
        mtpMountProc.script = "fail=0\n" + cmds.join("\n") + "\nexit $fail";
        mtpMountProc.running = false;
        mtpMountProc.running = true;
    }
    Process {
        id: mtpMountProc
        property string script: ""
        command: ["bash", "-c", mtpMountProc.script]
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => console.log(`[volumes] ${String(line ?? "")}`)
        }
        // Look again after the attempt, whatever it printed: the question
        // "did the phone become readable?" is answered by a scan, and a phone
        // unlocked while the mount was being made answers on the NEXT session,
        // not on this one. mtpRepairTimer decides whether another attempt is
        // owed.
        onExited: (exitCode, exitStatus) => mtpRepairTimer.restart()
    }
    Timer {
        // The phone's grace period after a USB event, for the reason above.
        id: mtpScanDebounce
        interval: 1500
        onTriggered: root.scanMtp()
    }
    Timer {
        // The retry, at the mount block's own cadence. Spaced rather than
        // immediate because every attempt is a fresh MTP session: asking again
        // in the same second asks the same unanswered question.
        id: mtpRepairTimer
        interval: root.mtpRepairSpacing
        onTriggered: root.scanMtp()
    }

    // ── The other half: the things that are not drives ──────────────────
    //
    // REQUESTED (2026-10-14): "I get no notification when plugging something in
    // and out of the pc like a usb key." The census above answers that for
    // storage and for nothing else, because lsblk only knows block devices --
    // which is the exact shape of the report: a stick was announced and a
    // phone (or a pad, or a headset dongle) was not, while from the outside
    // both are the same gesture on the same port. Found on this machine while
    // fixing it, and it is the published case: a Samsung phone on bus 1
    // (`1-12`, `removable`) giving no sign of itself anywhere in the session.
    //
    // So this is the second census, over sysfs rather than lsblk
    // (scripts/system/usb-devices.sh), and it announces the devices the drive
    // census cannot see -- same notification, same click, because a device
    // going in is one gesture whether it is a stick or a phone.
    //
    // WHAT KEEPS IT QUIET, since "every USB device" on a laptop is every
    // internal part it has:
    //   * `removable` ONLY -- the firmware's own answer about the PORT, read
    //     from sysfs. Measured on this machine 2026-10-14: the camera (1-8),
    //     the keyboard (1-10) and the Bluetooth (1-14) all read `fixed`, and
    //     the phone on a cable read `removable`. A port the firmware cannot
    //     classify reads `unknown` and is left alone rather than guessed at,
    //     which is what keeps a resume (when the whole bus re-enumerates) from
    //     producing a notice about hardware nobody moved;
    //   * hubs (class 09) are skipped: the thing plugged into the hub is the
    //     gesture, the hub is the splitter;
    //   * mass storage is skipped HERE by construction -- the drive census
    //     announces it with the label, filesystem and size a person recognises,
    //     and one plug gets one notice, not two;
    //   * the first scan is a census (`usbPrimed`), the same rule as the drive
    //     side: whatever was already plugged in when the shell started is not
    //     news.
    readonly property string usbScanScript: Quickshell.shellPath("scripts/system/usb-devices.sh")
    // sysfs device name ("1-12") -> record. The drive side keeps a row per
    // device because its notice is built from partitions; here the product name
    // is the whole of it, so a record holds exactly what a notice needs.
    property var usbKnown: ({})
    // The drive side calls its first poll a census; this is the same flag for
    // the same reason, and it is separate because the two arrive at different
    // times -- the phone is up in a second, a card whose partition table the
    // kernel has not read yet is not.
    property bool usbPrimed: false
    property int usbScans: 0
    function usbKind(rec) {
        return rec.mtp ? "phone" : "usbdev";
    }
    // One line about a device: what it calls itself, and who made it. Both, when
    // they are different -- "SAMSUNG_Android · SAMSUNG" is how a person
    // recognises the thing on the end of the cable, where the sysfs name `1-12`
    // is not.
    function usbDescribe(rec) {
        const parts = [];
        const product = String(rec?.product ?? "").trim();
        const maker = String(rec?.manufacturer ?? "").trim();
        if (product.length > 0) parts.push(product);
        if (maker.length > 0 && maker !== product) parts.push(maker);
        if (parts.length === 0) parts.push(String(rec?.name ?? ""));
        return parts.join(" · ");
    }
    function scanUsb() {
        usbScanProc.running = false;
        usbScanProc.running = true;
    }
    Process {
        id: usbScanProc
        command: ["bash", root.usbScanScript]
        stdout: StdioCollector {
            onStreamFinished: root.consumeUsb(this.text)
        }
    }
    function consumeUsb(text) {
        root.usbScans++;
        const now = {};
        for (const raw of String(text ?? "").split("\n")) {
            const line = raw.trim();
            if (line.indexOf("dev|") !== 0) continue;
            const f = line.split("|");
            if (f.length < 8) continue;
            const rec = {
                name: f[1],
                product: f[2],
                manufacturer: f[3],
                removable: f[4],
                deviceClass: f[5],
                massStorage: f[6] === "1",
                mtp: f[7] === "1"
            };
            // A pluggable port, and not the drive census's business.
            if (rec.removable !== "removable") continue;
            if (rec.massStorage) continue;
            now[rec.name] = rec;
        }
        if (root.usbPrimed)
            root.diffUsb(root.usbKnown, now);
        root.usbKnown = now;
        root.usbPrimed = true;
    }
    // Same shape as the drive diff above, and for the same reason: what is
    // present now but was not is an insertion, what was and is not is a
    // removal, and everything present in both is nothing at all.
    function diffUsb(before, after) {
        for (const name in after) {
            if (name in before) continue;
            root.announce(root.usbKind(after[name]), true, root.usbDescribe(after[name]));
        }
        for (const name in before) {
            if (name in after) continue;
            root.announce(root.usbKind(before[name]), false, root.usbDescribe(before[name]));
        }
    }
    Timer {
        // Longer than the block debounce (one insertion arrives there as a disk
        // and each of its partitions) because a USB device has more to publish
        // before it settles -- a phone brings up five interfaces, and a notice
        // fired between the device and its first interface names a device that
        // is not finished existing. Shorter than the MTP grace period, so the
        // notice about a phone arrives before the mount is attempted.
        id: usbScanDebounce
        interval: 700
        onTriggered: root.scanUsb()
    }
    // The census at startup, and deliberately not `triggeredOnStart` on a
    // repeating timer: this one asks once, because the udev stream is what
    // answers from then on and a census every few seconds would be a process
    // spawn per tick to answer a question that only changes when a cable moves.
    // The USB census at startup, and the PHONE half with it: the MTP scan used
    // to run only on a hotplug event, so a shell that started with a phone
    // already on the bus (a reload, a relogin, a phone plugged in before the
    // session) never looked at it. The census is the precedent -- a device that
    // is there now is read now.
    Component.onCompleted: {
        root.scanUsb();
        root.scanMtp();
    }

    // ── Reachable by hand ───────────────────────────────────────────────
    // There is no way to plug a device in from a script, so the checks read
    // this instead: `state` is the current census, `forget` drops a device from
    // it so the very next poll sees it as newly inserted and fires the real
    // notification path, and `poll` just asks again. `automountNow` drives the
    // automount pass by hand, for the same reason and for the same class of
    // question: whether "plugged in" really means "mounted", which no keypress
    // can otherwise ask. The USB census has the same quartet -- `usbForget`,
    // `usbPhantom`, `usbScan` and the `usb=` field of `state` -- because a
    // phone cannot be plugged in from a script any more than a stick can.
    function stateLine() {
        const rows = [];
        for (const p in root.known)
            rows.push(`${p}:${root.known[p].type}:${root.known[p].kind}:${root.known[p].hasFs ? "fs" : "raw"}`);
        // The USB census is reported by NAME and kind, not by count: a check
        // (and a person reading `state`) has to be able to name the device it
        // is about to drop, and the sysfs name is the handle both use.
        const usbRows = [];
        for (const n in root.usbKnown)
            usbRows.push(`${n}:${root.usbKind(root.usbKnown[n])}:${String(root.usbKnown[n].product ?? "").replace(/\s+/g, "_")}`);
        return `primed=${root.primed} poll=${root.pollCount} noticed=${root.noticed}`
            + ` chimed=${root.chimed} silent=${root.silent}`
            + ` hotplug=${hotplugWatch.running ? "on" : "off"}/${root.hotplugEvents}`
            + ` devices=${rows.length ? rows.join(",") : "-"}`
            + ` automounted=${root.autoMounts} automountFailures=${root.autoMountFailures}`
            + ` mtpScans=${root.mtpScans} mtpAutoMounted=${root.mtpAutoMounts}`
            + ` mtpRefusing=${Object.keys(root.mtpRefusing).length}`
            + ` usbPrimed=${root.usbPrimed} usbScans=${root.usbScans} usb=${usbRows.length ? usbRows.join(",") : "-"}`
            + ` autoCmd="${root.autoMountCommand}" autoSaid="${root.autoMountNote}"`
            + ` last="${root.lastEvent}"`;
    }
    // Drive the automount pass by hand: the drives that are in the census right
    // now, and a fresh look at the USB bus for a phone. Both halves of what
    // "auto mounted" means, without a device to plug in.
    function automountNow() {
        const eligible = root.autoMount(root.known);
        root.scanMtp();
        return `automount: ${eligible} device(s) considered, command="${root.autoMountCommand}"`
            + ` | phones: ${root.mtpScans} scans, ${root.mtpAutoMounts} mounted`;
    }
    // The other direction of the same problem, and it is the reason `phantom`
    // exists below on the drive side: an unplug cannot be staged either. The
    // record is planted in the census, so the next scan finds it gone and fires
    // the ordinary "removed" notice, click and all.
    function usbPhantom(name, kind, product) {
        const n = String(name ?? "").trim();
        const next = Object.assign({}, root.usbKnown);
        next[n] = {
            name: n,
            product: String(product ?? ""),
            manufacturer: "",
            removable: "removable",
            deviceClass: "00",
            massStorage: false,
            mtp: kind === "phone"
        };
        root.usbKnown = next;
        return `planted usb ${n}: the next scan will report it removed`;
    }
    // The USB half of `forget`, and with the same limit stated there: there is
    // no way to unplug a phone from a script either, so the check suite drops a
    // device this census can see and the next scan reports it INSERTED -- the
    // real notice, the real click and the real popup, driven by hand. It is the
    // only way to exercise that path without hardware in the port.
    function usbForget(name) {
        const n = String(name ?? "").trim();
        if (!(n in root.usbKnown))
            return `unknown usb device: ${n} (known: ${Object.keys(root.usbKnown).join(", ") || "none"})`;
        const next = Object.assign({}, root.usbKnown);
        delete next[n];
        root.usbKnown = next;
        return `forgot usb ${n}: the next scan will report it inserted`;
    }
    function forget(path) {
        const p = String(path ?? "");
        if (!(p in root.known))
            return `unknown device: ${p} (known: ${Object.keys(root.known).join(",") || "none"})`;
        const next = Object.assign({}, root.known);
        delete next[p];
        root.known = next;
        return `forgot ${p}: the next poll will report it inserted`;
    }
    // The other direction, and for the same reason: a device that is not there.
    // The record is planted in the census, so the next poll finds it gone and
    // fires the ordinary "removed" announcement -- which is otherwise only
    // testable by physically unplugging something.
    function phantom(path, kind, label, size) {
        const p = String(path ?? "");
        const next = Object.assign({}, root.known);
        next[p] = {
            name: p.split("/").pop(),
            disk: p,             // its own disk: one device, described by itself
            type: "disk",
            label: String(label ?? ""),
            fstype: "exfat",
            hasFs: true,
            size: Number(size ?? 0),
            model: "",
            mountpoint: "",
            kind: ["usb", "sd", "ssd", "hdd", "disk"].includes(kind) ? kind : "usb"
        };
        root.known = next;
        return `planted ${p}: the next poll will report it removed`;
    }
}
