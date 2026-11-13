#!/usr/bin/env python3
"""
Hold SUPER alone to dictate. Read the keyboard below the compositor.

WHY THIS IS NOT A HYPRLAND BIND
    Every bind on SUPER in Hyprland fires for chords as well: `ignore_mods`
    matches SUPER+Q too, and the `long_press` flag of this build's Lua binding
    is dropped on the floor (it registers as a plain bind -- verified with
    hyprctl). So a bind either recorded through every SUPER shortcut or never
    fired. Neither is acceptable: SUPER+Q closes a window, SUPER+drag moves one,
    and a SUPER tap opens search.

    This reads /dev/input/event* directly instead, which is the only place that
    can see "SUPER is down and NOTHING ELSE is". Nothing is bound, so nothing
    about SUPER changes for any other gesture -- this process only observes.

THE GESTURE, and why it is instant
    * SUPER goes down          -> recording starts IMMEDIATELY (audio from the
                                 very first syllable, no waiting to find out
                                 whether this is a hold).
    * any other key or click   -> cancelled: recorder killed, no pill, no text.
                                 The chord goes to the compositor untouched,
                                 which is the whole point of watching below it.
    * still held, alone, after ARM_MS -> ARMED: the island's pill appears and
                                 starts moving with the microphone.
    * SUPER released while armed      -> stop, transcribe, type the words.

    So the latency that matters (the first word) is zero, and the decision that
    matters (is this a chord or is this speech) is made while the user is still
    opening their mouth. A chord pressed slowly -- hold SUPER, think, press Q --
    arms the pill and then cancels it the instant Q arrives, typing nothing.

STATE FOR THE SHELL
    $XDG_RUNTIME_DIR/ii-dictate/status.json -- {"state": "...", "level": 0..1}
    written atomically, and read by services/Dictation.qml, which the island's
    pill follows. States: "idle", "recording" (armed, level live),
    "transcribing" (words are being worked out). While either of the two real
    states is running the file also carries "lang": the two-letter code of the
    language whisper recognised this dictation in, so the bar can say which one
    it is hearing. It is absent until the first words have come back (nothing
    has been recognised yet), and the file it comes from is deleted when a new
    hold begins, so one dictation's German never labels the next one.

No dependencies: /sysfs device discovery by hand, raw evdev reads, and the
existing dictate.sh for the whisper/typing half.
"""

import json
import math
import os
import queue
import select
import signal
import struct
import subprocess
import sys
import threading
import time

HOME = os.path.expanduser("~")
DATA = os.path.join(HOME, ".local/share/ii-dictate")
STATE = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "ii-dictate")
STATUS = os.path.join(STATE, "status.json")
LOG = os.path.join(STATE, "daemon.log")
DICTATE = os.path.join(HOME, ".config/hypr/custom/scripts/dictate.sh")

# Long enough that no tap can arm it (measured taps here are 60-120ms), short
# enough that the pill is there before the first sentence is over.
ARM_MS = int(os.environ.get("II_DICTATE_ARM_MS", "300"))
# A hold shorter than this is not worth sending to whisper even if armed.
MIN_RECORD_S = float(os.environ.get("II_DICTATE_MIN_S", "0.35"))

# ── Transcribing WHILE the user talks ───────────────────────────────────────
# Whisper is fast per second of audio, but the whole clip used to be handed over
# only after the key came up, so the wait grew with the dictation: measured on
# this machine, 15s came back in 0.7s and 240s in 2.9s. That is the "it lags
# when I give it a lot of input" report -- the machine was not slow, it simply
# started working when the talking stopped.
#
# So the recorder now cuts the audio at PAUSES and sends each piece off to the
# warm server as it goes. At release only the tail is left (a few seconds), and
# the wait is roughly constant whatever the length of the dictation.
#
# The cut has to land in silence, or whisper is handed half a word: QUIET_RMS is
# well under speech (measured here: speech 0.02-0.25, a quiet room 0.005-0.01),
# and a cut needs QUIET_BLOCKS x 100ms of it. CHUNK_MAX_S is the backstop for
# someone who never pauses -- 30s is also whisper's own window, so cutting there
# costs it nothing.
QUIET_RMS = float(os.environ.get("II_DICTATE_QUIET_RMS", "0.012"))
QUIET_BLOCKS = int(os.environ.get("II_DICTATE_QUIET_BLOCKS", "3"))
CHUNK_MIN_S = float(os.environ.get("II_DICTATE_CHUNK_MIN_S", "4.0"))
CHUNK_MAX_S = float(os.environ.get("II_DICTATE_CHUNK_MAX_S", "30.0"))

# ── The pill's meter ────────────────────────────────────────────────────────
# dBFS window that maps to an empty and a full bar. Calibrated on this machine's
# own dictations, not on theory: median speech lands at -17..-21 dBFS, louder
# syllables peak near -6, and a still room sits around -38. The ceiling is where
# the bar is allowed to reach the top -- a raised voice, not a normal sentence.
# FLOOR_DB is negative, so `db - FLOOR_DB` is the distance above the floor.
FLOOR_DB = float(os.environ.get("II_DICTATE_METER_FLOOR_DB", "-42.0"))
CEIL_DB = float(os.environ.get("II_DICTATE_METER_CEIL_DB", "-4.0"))
# Smoothing per 100ms block: attack, release. The release is deliberately
# quicker than the attack, so the gaps between words read as dips instead of
# leaving the bar where the loudest syllable put it.
RISE = 0.6
FALL = 0.45

META_KEYS = {125, 126}            # KEY_LEFTMETA, KEY_RIGHTMETA


# Which source to capture. Same config file and same key as dictate.sh, so a
# machine with two microphones is configured in one place.
def _config_mic():
    if os.environ.get("MIC"):
        return os.environ["MIC"]
    path = os.path.join(HOME, ".config/ii-dictate.conf")
    try:
        for line in open(path):
            line = line.split("#", 1)[0].strip()
            if line.startswith("MIC="):
                return line.split("=", 1)[1].strip().strip('"\'')
    except OSError:
        pass
    return ""


MIC = _config_mic()


def resolve_source(name):
    """Turn a source NAME into the node id pw-record actually listens to.

    Measured here 2026-11-09: `pw-record --target <name>` accepts the name,
    exits 0, and then records the DEFAULT source -- `pactl list source-outputs`
    even reports the name back, so the mistake is invisible from outside and
    looks exactly like a microphone that hears nothing. The numeric id does the
    right thing. Hence this lookup, and the id (or nothing) passed to pw-record.
    """
    if not name:
        return ""
    if name.isdigit():
        return name
    try:
        out = subprocess.run(["pactl", "list", "short", "sources"],
                             capture_output=True, text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    for line in out.splitlines():
        cols = line.split("\t")
        if len(cols) >= 2 and cols[1] == name:
            return cols[0]
    say("source %r not found, using the default" % name)
    return ""


SOURCE = resolve_source(MIC)
MOUSE_BUTTONS = set(range(0x110, 0x118))   # BTN_LEFT .. BTN_TASK
EV_SYN, EV_KEY, EV_REL = 0, 1, 2
REL_WHEEL, REL_HWHEEL = 8, 6


def say(*parts):
    line = "%s %s" % (time.strftime("%H:%M:%S"), " ".join(str(p) for p in parts))
    try:
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


# ── device discovery ────────────────────────────────────────────────────────
# /proc/bus/input/devices carries each device's KEY bitmap; the bit for a key
# tells us whether this device can produce it at all. Only devices that can
# produce SUPER are opened, which excludes touchpads and power buttons.
def key_bitmaps():
    found = []
    try:
        text = open("/proc/bus/input/devices").read()
    except OSError:
        return found
    for block in text.split("\n\n"):
        hand = keys = name = None
        for line in block.splitlines():
            if line.startswith("H: Handlers="):
                hand = line.split("=", 1)[1].split()
            elif line.startswith("B: KEY="):
                keys = line.split("=", 1)[1].split()
            elif line.startswith("N: Name="):
                name = line.split("=", 1)[1].strip().strip('"')
        if not hand or not keys:
            continue
        # A device that exists only to INJECT keys is not the user pressing
        # them. ydotool delivers a sentence as Ctrl+V through one of these, and
        # wtype types it character by character through another, and both look
        # exactly like a keyboard from here. That was fatal in practice: a
        # sentence still being delivered while SUPER was already down for the
        # next one arrived as a "chord", so the new recording was stopped --
        # reported as the button being let go even while it was held. Skipping
        # them also means a dictation can never be started or cancelled by our
        # own typing. The real keyboard is still watched, so SUPER itself is
        # unaffected.
        if name and any(word in name.lower() for word in VIRTUAL_DEVICES):
            say("ignoring virtual keyboard", name)
            continue
        event = next((h for h in hand if h.startswith("event")), None)
        if not event:
            continue
        bits = set()
        for i, word in enumerate(reversed(keys)):
            try:
                value = int(word, 16)
            except ValueError:
                continue
            for b in range(64):
                if value >> b & 1:
                    bits.add(i * 64 + b)
        if bits & META_KEYS:
            found.append(("/dev/input/" + event, bits))
    return found


# ── status file ─────────────────────────────────────────────────────────────
# Injected keys are not the user's fingers, and the delivery of a sentence is a
# Ctrl+V chord: on this desktop CTRL + SUPER + V opens the volume mixer. So a
# sentence landing while SUPER is already down for the next one opened that
# window instead of pasting. dictate.sh waits for SUPER to come up before it
# delivers anything; this is the one bit it needs to do that, kept next to the
# status file for the same reason (it is small, and it is written on change).
VIRTUAL_DEVICES = ("ydotoold", "wtype", "uinput", "virtual")
SUPER_FILE = os.path.join(STATE, "super")
# What the warm server decided the audio was, written by dictate.sh next to the
# transcript it produced. Not one of ours: we only fold it into status.json, so
# the shell has one file to poll and one place the answer can come from.
LANG_FILE = os.path.join(STATE, "language.json")


def write_super(down):
    tmp = SUPER_FILE + ".tmp"
    try:
        with open(tmp, "w") as f:
            f.write("down" if down else "up")
        os.replace(tmp, SUPER_FILE)
    except OSError:
        pass


# ── WHAT is running, counted instead of overwritten ─────────────────────────
# The state the pill follows used to be one string that whoever wrote last won.
# A dictation is not one thing at a time, though: a sentence is still being
# delivered while the next hold is already recording, and the older delivery's
# final "idle" then blanked the pill while the microphone was open. The state is
# derived from COUNTED tasks now, so overlapping work cannot end another's, and
# a cancelled hold cannot leave a phantom "transcribing" behind.
#
# The timestamp is refreshed by a heartbeat for as long as anything is running.
# The shell treats a status older than 2s as idle -- the rule that keeps a
# daemon which died mid-dictation from leaving a pill on screen forever -- so
# every blocking spell here (stopping the recorder, a chunk still in whisper,
# ffmpeg, a screen grab) used to age the file out and take the tell with it.
# Measured: the pill went out in the middle of the wait after the key came up,
# and the transcribing state that followed was a flash nobody could read. No
# writer blocks for longer than a heartbeat now, so the state is true for as
# long as it is shown.
_status_lock = threading.Lock()
_tasks = {"recording": 0, "transcribing": 0}
_level = 0.0
_last_level_write = 0.0


def _read_language():
    """The language the last words came back in, or "" if there are none yet.

    Read, not remembered: dictate.sh writes this file from a separate process
    (one per chunk, one for the tail) and the shell's copy has to follow
    whatever the LATEST piece of audio was recognised in. A value that is
    missing, half-written or unreadable is simply no language -- the bar then
    shows no tag, which is also the honest answer.
    """
    try:
        with open(LANG_FILE) as f:
            return str(json.load(f).get("lang") or "")
    except (OSError, ValueError, AttributeError):
        return ""


def clear_language():
    """Forget the previous dictation's language. Called when a hold begins."""
    try:
        os.unlink(LANG_FILE)
    except OSError:
        pass


def _write_locked(now):
    """Write status.json. The caller holds _status_lock."""
    state = ("recording" if _tasks["recording"] > 0
             else "transcribing" if _tasks["transcribing"] > 0
             else "idle")
    payload = {
        "state": state,
        "level": round(_level if state == "recording" else 0.0, 3),
        "ts": round(now, 3),
    }
    # Only while something is really running: an idle file that still named a
    # language would make the bar's tag outlive the dictation it describes.
    if state != "idle":
        lang = _read_language()
        if lang:
            payload["lang"] = lang
    payload = json.dumps(payload)
    tmp = STATUS + ".tmp"
    try:
        with open(tmp, "w") as f:
            f.write(payload)
        os.replace(tmp, STATUS)
    except OSError:
        pass


def set_task(task, running):
    """Begin or end one piece of work. Writes only when the state changes."""
    with _status_lock:
        before = _tasks[task]
        _tasks[task] = max(0, before + (1 if running else -1))
        if _tasks[task] != before:
            _write_locked(time.time())


def set_level(level):
    """The live meter: one write per 50ms, the same rate the recorder emits."""
    global _level, _last_level_write
    now = time.time()
    _level = level
    with _status_lock:
        if _tasks["recording"] <= 0:
            return
        if now - _last_level_write < 0.05:
            return
        _last_level_write = now
        _write_locked(now)


def idle():
    """Nothing is running: drop every task and say so once."""
    with _status_lock:
        _tasks["recording"] = 0
        _tasks["transcribing"] = 0
        _write_locked(time.time())


def heartbeat():
    """Keep the timestamp fresh while anything is running.

    A separate thread on purpose: the reader is the shell and the writers are
    several threads, any one of which can block for a second or two while the
    others are still working. This is the one writer that never does.
    """
    while True:
        time.sleep(0.25)
        with _status_lock:
            if _tasks["recording"] > 0 or _tasks["transcribing"] > 0:
                _write_locked(time.time())


# ── recorder ────────────────────────────────────────────────────────────────
class Recorder(threading.Thread):
    """parec straight into memory, metering as it goes.

    Reading the capture ourselves (rather than letting the shell read a file
    after the fact) is what makes the pill move: the same bytes that will be
    transcribed are the ones the level comes from, so the animation cannot be
    out of step with what is being recorded.
    """

    def __init__(self):
        super().__init__(daemon=True)
        self.proc = None
        # One flat buffer, not a list of reads: a cut hands over everything
        # after `cut_at`, and an index into a bytearray is the only way to say
        # that without copying the whole recording on every 100ms block.
        self.buf = bytearray()
        self.cut_at = 0
        self.total = 0
        self.stop_flag = threading.Event()
        self.level = 0.0
        # Every smoothed level this hold produced, for the one-line summary in
        # the log when it ends. Numbers only -- never the words.
        self.levels = []
        # ── the meter's own window, per recording ─────────────────────────
        # A fixed dBFS window assumed the input was exactly as loud as the one
        # it was calibrated on. A quieter source -- another mic, a remapped
        # one, a lower PipeWire gain -- then left every bar parked at the
        # floor while transcription still worked perfectly, which on screen
        # reads as "the meter is broken". So the window follows THIS hold: the
        # floor chases the quietest block, the peak rides the loudest, and the
        # bar is drawn between those two. Speech spans the pill whatever the
        # input gain happens to be, and a raised voice still has somewhere to
        # go because the peak decays.

        self.started = time.time()
        # ── the pieces already sent off, and who sends them ──────────────
        # `parts` are the words that came back for the chunks ahead of the
        # tail, in order. A single worker thread per recording keeps them
        # ordered (the server is one model, one request at a time anyway) and
        # keeps this thread's only job reading the microphone.
        self.jobs = queue.Queue()
        self.parts = []
        self.parts_lock = threading.Lock()
        # False the moment any chunk fails to come back: a missing piece would
        # silently delete a sentence, so the release falls back to transcribing
        # the WHOLE capture instead. Slower, never wrong.
        self.chunks_ok = True
        self.worker = threading.Thread(target=self._work, daemon=True)
        self.worker.start()
        self.quiet_run = 0
        self.cut_loud = False

    def run(self):
        # pw-record, not parec: parec on this machine exits without an error and
        # without a single byte of audio (tested from the default source, a named
        # source and a null-sink monitor), which silently transcribes silence.
        self.proc = subprocess.Popen(
            ["pw-record", "--rate", "16000", "--channels", "1", "--format", "s16",
             *(["--target", SOURCE] if SOURCE else []), "-"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        while not self.stop_flag.is_set():
            data = self.proc.stdout.read(1600)   # 100ms at 16kHz mono s16
            if not data:
                break
            self.buf += data
            self.total += len(data)
            rms = 0.0
            if len(data) >= 2:
                count = len(data) // 2
                # Decode as signed 16-bit; sum of squares without numpy.
                values = struct.unpack("<%dh" % count, data[:count * 2])
                rms = math.sqrt(sum(v * v for v in values) / count) / 32768.0
            # The level the pill draws, in dBFS -- and the reason this is not
            # `(rms * 12) ** 0.6` any more. That curve crossed 1.0 at about
            # -25 dBFS, and this microphone records ORDINARY conversation at a
            # median of -17 to -21 dBFS (measured over the saved dictations),
            # so the bar sat pinned at maximum for every word and the meter
            # said nothing. Reported as "it keeps being at max even if I'm not
            # screaming".
            #
            #   -42 dBFS (still room) .. -4 dBFS (a raised voice) -> 0 .. 1
            #
            # Measured on the saved dictations with this window and the
            # smoothing below: pauses ~0.10, normal speech around 0.55-0.6,
            # emphasised syllables ~0.75, and no block at all pinned at 1.0 for
            # a normal sentence. The 1.2 exponent is a gentle tilt, not another
            # log: it keeps quiet speech from hugging the floor without
            # squashing the top.
            db = 20.0 * math.log10(rms) if rms > 1e-6 else -90.0
            # The fixed window, as measured against this machine's own saved
            # dictations (still room ~-38, speech -17..-21, peaks ~-6). Two
            # adaptive versions were tried on the way here -- one chasing the
            # recording's own floor, one centring on the loudest block -- and
            # both made a SILENT room read 0.5-0.65, which is a meter that says
            # "something is happening" when nothing is. The calibration was
            # never the problem; nothing here needs to fight the input gain.
            shaped = min(1.0, max(0.0, (db - FLOOR_DB) / (CEIL_DB - FLOOR_DB))) ** 1.2
            # Rises quickly, falls a little slower: a syllable should show up
            # immediately, a gap between words should read as a dip rather than
            # leaving the bar parked where the loudest moment put it.
            weight = RISE if shaped > self.level else FALL
            self.level = self.level * (1.0 - weight) + shaped * weight
            self.levels.append(self.level)
            set_level(self.level)
            self._maybe_cut(rms)

    # ── cutting the recording into pieces as it arrives ──────────────────
    def _maybe_cut(self, rms):
        """Hand off everything up to now if this is a good place to cut.

        A good place is a PAUSE: QUIET_BLOCKS of consecutive quiet blocks, not a
        single quiet one -- a closed mouth between two syllables is 30ms, and
        cutting there splits a word across two whisper requests. CHUNK_MIN_S
        keeps the requests worth making, CHUNK_MAX_S is the backstop for speech
        that never pauses.
        """
        if rms < QUIET_RMS:
            self.quiet_run += 1
        else:
            self.quiet_run = 0
            self.cut_loud = True
        since = self.total - self.cut_at
        if since < int(16000 * 2 * CHUNK_MIN_S):
            return
        # Nothing but room tone so far: there are no words to chew on.
        if not self.cut_loud:
            return
        if self.quiet_run >= QUIET_BLOCKS or since >= int(16000 * 2 * CHUNK_MAX_S):
            self._cut()

    def _cut(self):
        blob = bytes(self.buf[self.cut_at:self.total])
        self.cut_at = self.total
        self.cut_loud = False
        self.quiet_run = 0
        path = os.path.join(STATE, "chunk-%d-%03d.pcm" % (
            int(time.time() * 1000), threading.get_ident() % 1000))
        try:
            with open(path, "wb") as f:
                f.write(blob)
        except OSError as exc:
            self.chunks_ok = False
            say("chunk write failed:", exc)
            return
        self.jobs.put(path)

    def _work(self):
        """Transcribe queued chunks, in order, until stop() sends None."""
        while True:
            path = self.jobs.get()
            if path is None:
                return
            t0 = time.time()
            text = ""
            try:
                done = subprocess.run(["bash", DICTATE, "chunk", path],
                                      capture_output=True, text=True, timeout=120)
                if done.returncode == 0:
                    text = done.stdout.strip()
                else:
                    # The exit code, not the emptiness, is the failure signal: a
                    # piece cut between two sentences can honestly transcribe to
                    # nothing, and that must not cost the other pieces.
                    self.chunks_ok = False
            except Exception as exc:
                self.chunks_ok = False
                say("chunk failed:", exc)
            if text:
                with self.parts_lock:
                    self.parts.append(text)
            # The text itself is never written to the log: transcripts are not
            # saved anywhere on this machine, including the runtime log.
            say("chunk %.1fs transcribed in %d ms: %d char(s)" % (
                os.path.getsize(path) / 32000.0 if os.path.exists(path) else 0,
                (time.time() - t0) * 1000, len(text)))
            try:
                os.unlink(path)
            except OSError:
                pass

    def stop(self):
        """Stop capturing, wait out the queued chunks, return what is left.

        Returns (tail, parts, full): the audio after the last cut (what is left
        to transcribe), the text of the chunks already transcribed, and the
        whole capture (for the history's audio file). `parts` is empty whenever
        any chunk failed, which makes the caller transcribe the whole capture
        instead.
        """
        self.stop_flag.set()
        proc = self.proc
        if proc:
            try:
                proc.terminate()
                proc.wait(timeout=1.5)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
        # Everything below the last cut is the tail, whether or not it was
        # worth a chunk of its own.
        self.jobs.put(None)
        try:
            self.worker.join(timeout=30)
        except Exception:
            pass
        tail = bytes(self.buf[self.cut_at:self.total])
        full = bytes(self.buf)
        with self.parts_lock:
            parts = list(self.parts)
        if not self.chunks_ok:
            parts = []
        # One line of numbers about the meter this hold produced, so a report of
        # "the bars never move" can be answered with data instead of a guess.
        # No words are logged anywhere.
        if self.levels:
            s = sorted(self.levels)
            say("meter: %d samples, p10=%.2f median=%.2f p90=%.2f max=%.2f" % (
                len(s), s[len(s) // 10], s[len(s) // 2],
                s[min(len(s) - 1, int(len(s) * 0.9))], s[-1]))
        return tail, parts, full


def finish(raw_bytes, parts=None, full_bytes=None):
    """Hand the captured audio to dictate.sh for wrapping, whisper and typing.

    `raw_bytes` is only what was NOT already transcribed (see Recorder), and
    `parts` are the words that were. In the normal case the release therefore
    costs one short request instead of one long one, and the wait stops growing
    with the length of the dictation.

    The caller has ALREADY begun the "transcribing" task (see the release in
    main): this function owns the rest of that task and ends it in `finally`,
    whatever happens -- a too-short clip, a whisper crash, a timeout. A task
    left behind would hold the pill on screen, a worse failure than a tell that
    vanishes, and the reason the end is here and not at every return.
    """
    parts = parts or []
    # A file PER capture, not one shared live.pcm. Each release starts this in
    # its own thread, so two of them can overlap (start talking again while the
    # previous sentence is still transcribing), and the second one's `unlink`
    # then deleted the first one's audio mid-read -- whisper got an empty file
    # and the dictation vanished with "recorded 0.000s" in the log.
    stamp = "%d-%03d" % (int(time.time() * 1000), threading.get_ident() % 1000)
    raw_path = os.path.join(STATE, "capture-%s.pcm" % stamp)
    prefix_path = os.path.join(STATE, "parts-%s.txt" % stamp)
    full_path = os.path.join(STATE, "full-%s.pcm" % stamp)
    try:
        say("release: %.2fs of tail left, %d part(s) already transcribed" % (
            len(raw_bytes) / 32000.0, len(parts)))
        if len(raw_bytes) < 1600 * MIN_RECORD_S and not parts:
            say("too short (%.2fs), dropped" % (len(raw_bytes) / 32000.0))
            return
        with open(raw_path, "wb") as f:
            f.write(raw_bytes)
        args = ["bash", DICTATE, "finish", raw_path]
        if parts:
            # One line per completed chunk; dictate.sh joins them ahead of the
            # tail's words. Written with a newline so `cat` cannot glue a
            # sentence into the next one at a seam.
            with open(prefix_path, "w") as f:
                f.write("\n".join(parts) + "\n")
            args.append(prefix_path)
            if full_bytes:
                # The history's audio file is the whole dictation, not the tail.
                with open(full_path, "wb") as f:
                    f.write(full_bytes)
                args.append(full_path)
        # No status write here: the task was begun on the release and the
        # heartbeat keeps its timestamp fresh for as long as it runs (see the
        # note above set_task). Writing once and walking away was the old bug.
        proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 120
        while proc.poll() is None:
            if time.time() > deadline:
                proc.kill()
                say("finish timed out")
                break
            time.sleep(0.4)
    except Exception as exc:
        say("finish failed:", exc)
    finally:
        for path in (raw_path, prefix_path, full_path):
            try:
                os.unlink(path)
            except OSError:
                pass
        set_task("transcribing", False)


# ── the watcher ─────────────────────────────────────────────────────────────
PIDFILE = os.path.join(STATE, "daemon.pid")


def already_running():
    """True if a live copy of this daemon owns the pidfile.

    execs.lua is file-scope and therefore runs again on every Hyprland reload;
    without this, each reload would leave another reader of every keyboard
    behind, all of them starting a recorder when SUPER goes down.
    """
    try:
        pid = int(open(PIDFILE).read().strip())
    except (OSError, ValueError):
        return False
    try:
        cmdline = open("/proc/%d/cmdline" % pid).read()
    except OSError:
        return False
    return "dictate-daemon" in cmdline


def main():
    os.makedirs(STATE, exist_ok=True)
    if already_running():
        say("already running, this copy exits")
        return 0
    with open(PIDFILE, "w") as f:
        f.write(str(os.getpid()))
    idle()
    threading.Thread(target=heartbeat, daemon=True).start()
    # Only the copy that owns the keyboards may say SUPER is up: a duplicate
    # copy (execs.lua runs again on every Hyprland reload) would otherwise clear
    # the marker while the real one has the key down, and a delivery would slip
    # out mid-chord.
    write_super(False)

    devices = key_bitmaps()
    if not devices:
        say("no keyboard devices found")
        return 1
    say("watching", ", ".join(d for d, _ in devices))

    fds = {}
    for path, _bits in devices:
        try:
            fds[os.open(path, os.O_RDONLY | os.O_NONBLOCK)] = path
        except OSError as exc:
            say("cannot open", path, exc)

    running = True

    def bye(*_a):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, bye)
    signal.signal(signal.SIGINT, bye)

    down = set()          # every key currently held, on any keyboard
    metas = set()         # which meta keys are down
    recorder = None       # Recorder while a candidate/armed hold is running
    cancelled = False     # this hold became a chord: never type anything
    armed_at = 0.0

    while running:
        try:
            ready, _, _ = select.select(list(fds), [], [], 0.05)
        except OSError:
            continue
        for fd in ready:
            try:
                data = os.read(fd, 24 * 64)
            except OSError:
                data = b""
            for off in range(0, len(data) - 23, 24):
                _s, _us, etype, code, value = struct.unpack_from("llHHi", data, off)
                if etype == EV_REL:
                    # A wheel turned with SUPER held is someone reaching for a
                    # shortcut (scroll-to-volume and friends), not speech.
                    # Pointer MOTION is deliberately not a cancel: a hand resting
                    # on the touchpad must not silence the microphone.
                    if recorder is not None and value != 0 and code in (REL_WHEEL, REL_HWHEEL):
                        cancelled = True
                        # The state changes BEFORE the join: stopping the
                        # recorder can wait on a chunk still in whisper, and
                        # the pill must not sit on a hold that is over.
                        set_task("recording", False)
                        recorder.stop()
                        recorder = None
                        armed_at = 0.0
                        say("cancelled by scroll")
                    continue
                if etype != EV_KEY:
                    continue

                if code in META_KEYS:
                    if value == 1:
                        metas.add(code)
                        write_super(True)
                        # Only a hold that begins with SUPER ALONE can dictate:
                        # SUPER pressed in the middle of something else is a
                        # chord, and SUPER pressed while another key is down is
                        # someone reaching for a shortcut.
                        if recorder is None and not cancelled and not down:
                            # A new hold: whatever the previous one was
                            # recognised in describes a dictation that is over.
                            # Cleared here, before any audio is transcribed, so
                            # the tag can only ever be this dictation's.
                            clear_language()
                            recorder = Recorder()
                            recorder.start()
                            armed_at = 0.0
                    elif value == 0:
                        metas.discard(code)
                        write_super(bool(metas))
                        if not metas:
                            # The hold is over. Decide what it was.
                            was_armed = armed_at > 0.0
                            if recorder is not None:
                                delivering = was_armed and not cancelled
                                # "Transcribing" begins NOW, on the key coming
                                # up -- not when the finish process is finally
                                # spawned. Stopping the recorder can wait on a
                                # chunk still in whisper, and that whole wait is
                                # transcription as far as the person watching is
                                # concerned. The task is what keeps the
                                # timestamp fresh (see heartbeat), so the pill
                                # stays up through it instead of going out and
                                # coming back.
                                if delivering:
                                    set_task("transcribing", True)
                                set_task("recording", False)
                                raw, parts, full = recorder.stop()
                                recorder = None
                                armed_at = 0.0
                                if delivering:
                                    threading.Thread(target=finish,
                                                     args=(raw, parts, full),
                                                     daemon=True).start()
                                else:
                                    say("tap or chord, discarded %d bytes" % len(raw))
                            elif cancelled:
                                say("chord released")
                            # ALWAYS reset here, and never only in the recorder
                            # branch: a cancelled chord has no recorder left, and
                            # leaving the flag set made every later hold look
                            # cancelled too -- dictation died for the rest of
                            # the session after one SUPER+Q.
                            cancelled = False
                    continue

                # Any other key: a chord is being played. This is the whole
                # safety property -- SUPER+Q, SUPER+1, SUPER+Enter all land
                # here on their first keypress and stop the recording before it
                # can become text.
                if value == 1:
                    down.add(code)
                    if recorder is not None:
                        # Any key or click at all, armed or not: the user is
                        # doing something else with SUPER held. The compositor
                        # handles the chord; this only stops the microphone.
                        cancelled = True
                        set_task("recording", False)
                        recorder.stop()
                        recorder = None
                        armed_at = 0.0
                        say("cancelled by", "click" if code in MOUSE_BUTTONS else "key", code)
                elif value == 0:
                    down.discard(code)

        # Arming: the key is still down, alone, and has been for long enough.
        if (recorder is not None and armed_at == 0.0 and not cancelled
                and metas and not (down - META_KEYS)
                and (time.time() - recorder.started) * 1000 >= ARM_MS):
            armed_at = time.time()
            set_task("recording", True)
            set_level(recorder.level)
            say("armed after %d ms" % ARM_MS)

    if recorder is not None:
        set_task("recording", False)
        recorder.stop()
    idle()
    try:
        if open(PIDFILE).read().strip() == str(os.getpid()):
            os.unlink(PIDFILE)
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
