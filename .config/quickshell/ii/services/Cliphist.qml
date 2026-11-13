pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import qs.modules.common.functions
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root
    // property string cliphistBinary: FileUtils.trimFileProtocol(`${Directories.home}/.cargo/bin/stash`)
    property string cliphistBinary: "cliphist"
    property real pasteDelay: 0.05
    // The paste keystroke, for superpaste() -- which fires several in a row and
    // has no popup to wait for. A single paste goes through
    // pasteKeystrokeScript below instead; see paste().
    property string pressPasteCommand: "ydotool key -d 1 29:1 47:1 47:0 29:0"
    // The Ctrl+V that lands one entry, as a SCRIPT. It waits for the clipboard
    // popup's layer surface to be gone before sending the key: the popup holds
    // the keyboard exclusively while it is up, so a paste sent any earlier
    // lands in the popup's own search field instead of the window underneath.
    // See the script for the measurements behind the wait.
    readonly property string pasteKeystrokeScript: Quickshell.shellPath("scripts/clipboard/paste-keystroke.sh")
    property bool sloppySearch: Config.options?.search.sloppy ?? false
    property real scoreThreshold: 0.2
    property list<string> entries: []
    readonly property var preparedEntries: entries.map(a => ({
        name: Fuzzy.prepare(`${a.replace(/^\s*\S+\s+/, "")}`),
        entry: a
    }))
    function fuzzyQuery(search: string): var {
        if (search.trim() === "") {
            return entries;
        }
        if (root.sloppySearch) {
            const results = entries.slice(0, 100).map(str => ({
                entry: str,
                score: Levendist.computeTextMatchScore(str.toLowerCase(), search.toLowerCase())
            })).filter(item => item.score > root.scoreThreshold)
                .sort((a, b) => b.score - a.score)
            return results
                .map(item => item.entry)
        }

        return Fuzzy.go(search, preparedEntries, {
            all: true,
            key: "name"
        }).map(r => {
            return r.obj.entry
        });
    }

    function entryIsImage(entry) {
        return !!(/^\d+\t\[\[.*binary data.*\d+x\d+.*\]\]$/.test(entry))
    }

    // cliphist stores whatever MIME the selection carried, and a FILE copied
    // with `wl-copy --type text/uri-list` arrives as a plain line starting
    // `file://`. That is not a text the popup offers to paste back, and the
    // thing that put it there (the recorder, after a stop) already says what
    // it saved -- its card is worth more than a second "Copied" flashing over
    // it half a second later (measured 2026-10-22: the save card was replaced
    // by this one before it could be read).
    function entryIsFileUri(entry) {
        return /^file:\/\//.test(String(entry ?? "").replace(/^\d+\t/, ""))
    }

    readonly property int previousEntryCount: readProc.buffer.length

    function refresh() {
        readProc.buffer = []
        readProc.running = true
    }

    function copy(entry) {
        root.noteShellCopy();
        if (root.cliphistBinary.includes("cliphist")) // Classic cliphist
            Quickshell.execDetached(["bash", "-c", `printf '%s' '${StringUtils.shellSingleQuoteEscape(entry)}' | ${root.cliphistBinary} decode | wl-copy`]);
        else { // Stash
            const entryNumber = entry.split("\t")[0];
            Quickshell.execDetached(["bash", "-c", `${root.cliphistBinary} decode ${entryNumber} | wl-copy`]);
        }
    }

    // An entry that has been decoded onto the clipboard and is waiting for the
    // popup to get out of the keyboard's way so its paste keystroke can be sent.
    property bool pendingPaste: false

    // Put the chosen entry back on the clipboard.
    //
    // NOTHING IS PASTED HERE, on purpose. The popup takes the keyboard
    // EXCLUSIVELY while it is open -- that is what makes the arrows and RETURN
    // work without a click first -- so a Ctrl+V sent at this moment goes to the
    // POPUP, not to the window the user is pasting into. That is the whole
    // reported bug: the paste landed in the popup's own search field (which is
    // where the stray text in its query came from), and retrying after the
    // popup happened to have closed worked often enough to read as "it pastes
    // on the twentieth try".
    //
    // So this only decodes. The keystroke is sent by sendPendingPaste(), once
    // the popup's surface is actually gone -- or, when no popup was up at all
    // (a paste asked for over IPC), by the fallback timer below. The script
    // itself re-checks that the surface is gone, so neither caller has to be
    // exactly right about the timing.
    function paste(entry) {
        root.noteShellCopy();
        if (root.cliphistBinary.includes("cliphist")) { // Classic cliphist
            Quickshell.execDetached(["bash", "-c", `printf '%s' '${StringUtils.shellSingleQuoteEscape(entry)}' | ${root.cliphistBinary} decode | wl-copy`]);
        } else { // Stash
            const entryNumber = entry.split("\t")[0];
            Quickshell.execDetached(["bash", "-c", `${root.cliphistBinary} decode ${entryNumber} | wl-copy`]);
        }
        root.pendingPaste = true;
    }

    // Send the Ctrl+V for a paste() that has already been decided. Idempotent:
    // the popup's unmap and the fallback timer both call it and only the first
    // one does anything.
    function sendPendingPaste() {
        if (!root.pendingPaste)
            return;
        root.pendingPaste = false;
        Quickshell.execDetached(["bash", root.pasteKeystrokeScript]);
    }

    // The no-popup fallback. A paste asked for over IPC, or one whose popup
    // never mapped, would otherwise sit in pendingPaste for ever; the normal
    // path (the popup unmapping) has already cleared the flag by this point, so
    // this is a no-op then. Its interval is not the paste timing -- the script
    // owns that -- it only decides how soon the script is started.
    Timer {
        id: pendingPasteFallback
        interval: 300
        repeat: false
        running: root.pendingPaste
        onTriggered: root.sendPendingPaste()
    }

    function superpaste(count, isImage = false) {
        root.noteShellCopy();
        // Find entries
        const targetEntries = entries.filter(entry => {
            if (!isImage) return true;
            return entryIsImage(entry);
        }).slice(0, count)
        const pasteCommands = [...targetEntries].reverse().map(entry => `printf '%s' '${StringUtils.shellSingleQuoteEscape(entry)}' | ${root.cliphistBinary} decode | wl-copy && sleep ${root.pasteDelay} && ${root.pressPasteCommand}`)
        // Act
        Quickshell.execDetached(["bash", "-c", pasteCommands.join(` && sleep ${root.pasteDelay} && `)]);
    }

    Process {
        id: deleteProc
        property string entry: ""
        command: ["bash", "-c", `printf '%s' '${StringUtils.shellSingleQuoteEscape(deleteProc.entry)}' | ${root.cliphistBinary} delete`]
        function deleteEntry(entry) {
            deleteProc.entry = entry;
            deleteProc.running = true;
            deleteProc.entry = "";
        }
        onExited: (exitCode, exitStatus) => {
            root.refresh();
        }
    }

    function deleteEntry(entry) {
        deleteProc.deleteEntry(entry);
    }

    Process {
        id: wipeProc
        command: [root.cliphistBinary, "wipe"]
        onExited: (exitCode, exitStatus) => {
            root.refresh();
        }
    }

    function wipe() {
        wipeProc.running = true;
    }

    // While this is in the future, clipboard changes are NOT announced. Dictation
    // is the reason: it sets the selection to paste a sentence and puts the old
    // text back a moment later, and two "Copied" cards for a sentence the user
    // never copied is noise on their screen. See dictate.sh (paste_text), which
    // asks for the window over IPC before it touches anything.
    property double quietUntil: 0
    function quiet(ms) {
        root.quietUntil = Date.now() + Math.max(0, Number(ms ?? 0));
    }

    // ── Noticing that something was copied ──────────────────────────────
    // NOT `Quickshell.clipboardText`, which is what this used to listen to. Under
    // Wayland a client only learns about the clipboard from a selection OFFER, and
    // offers follow focus -- a layer-shell background process like this shell never
    // has it, so that property simply sat still on this desktop and the toast had
    // no reason to ever look. Measured before replacing it: a copy produced no
    // signal here at all. `wl-paste --watch` is the standard answer -- one
    // long-lived process, one line per clipboard change, no focus, no polling --
    // and it was confirmed to fire on this compositor.
    Process {
        id: clipboardWatch
        command: ["wl-paste", "--watch", "bash", "-c", "echo changed"]
        running: true
        stdout: SplitParser {
            onRead: line => {
                // A change we caused ourselves (see quietUntil): the clipboard did
                // change, but there is nothing to tell the user about.
                if (Date.now() < root.quietUntil)
                    return;
                root.pendingChange = true
                root.pendingOwnCopy = root.shellCopied()
                root.toastRetries = 0
                delayedUpdateTimer.restart()
            }
        }
        onExited: (code, status) => {
            // A watcher that is gone leaves the toast silently missing until the
            // next reload, which reads as "the feature is broken" rather than "the
            // watcher stopped". 127 is "no such command": reviving a machine that
            // has no wl-clipboard every second would be a spawn loop.
            if (code !== 127)
                clipboardWatchRevive.restart()
        }
    }

    Timer {
        id: clipboardWatchRevive
        interval: 1000
        repeat: false
        onTriggered: clipboardWatch.running = true
    }

    // cliphist writes the entry to its store ASYNCHRONOUSLY -- measured on this
    // machine from 60 ms on a good copy to past 700 ms on a bad one -- while the
    // refresh that follows a change ran ~20 ms later, so it usually listed the
    // PREVIOUS store and the new entry was simply not in it yet. That is the second
    // reason the toast never appeared. So: ask again, shortly, until the newest
    // entry is one we have not announced. Bounded, and only while a change is
    // actually pending.
    Timer {
        id: toastRetryTimer
        interval: 150
        repeat: false
        onTriggered: root.refresh()
    }

    Timer {
        id: delayedUpdateTimer
        interval: Config.options.hacks.arbitraryRaceConditionDelay
        repeat: false
        onTriggered: {
            root.refresh()
        }
    }

    Process {
        id: readProc
        property list<string> buffer: []

        command: [root.cliphistBinary, "list"]

        stdout: SplitParser {
            onRead: (line) => {
                readProc.buffer.push(line)
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0) {
                const previous = root.entries
                root.entries = readProc.buffer
                // The newest entry, which cliphist prints FIRST -- verified against
                // a live store, where the highest id is the first line. This used to
                // take the LAST line, so the toast was tracking the OLDEST entry,
                // which only changes when that entry is eventually evicted: a third
                // reason it looked like it never worked at all.
                //
                // Announcing a change is for copies made OUT THERE -- Ctrl+C in an
                // app, a context menu, a screenshot -- and not for the shell putting
                // an entry back on the clipboard itself, which would flash a card at
                // someone who is already looking at the popup that did it. Nor does
                // it appear while work-safety mode is hiding the clipboard.
                //
                // The guard here used to read `root.workSafety.clipboard.enable`,
                // and `workSafety` is not a property of this service at all -- it
                // lives in the config as `workSafety.enable.clipboard`, so the
                // access threw and took the toast down with it before it could
                // ever be shown.
                const newest = readProc.buffer.length > 0 ? readProc.buffer[0] : ""
                if (newest !== root.announcedTail) {
                    root.pendingChange = false
                    root.toastRetries = 0
                    const own = root.pendingOwnCopy
                    root.pendingOwnCopy = false
                    if (!root.primedTail) {
                        // First read after a reload. Whatever is already on the
                        // clipboard was copied before this shell was listening, and
                        // announcing it would be a card for a copy nobody just made.
                        root.primedTail = true
                        root.announcedTail = newest
                    } else {
                        root.announcedTail = newest
                        if (newest !== ""
                            && !own
                            && !root.entryIsFileUri(newest)
                            && Config.options?.workSafety?.enable?.clipboard !== true) {
                            const isImage = root.entryIsImage(newest)
                            root.showCopyToast(isImage
                                ? Translation.tr("Image copied")
                                : Translation.tr("Copied"), isImage)
                        }
                    }
                } else if (root.pendingChange && root.toastRetries < 8) {
                    root.toastRetries++
                    toastRetryTimer.restart()
                }
            } else {
                console.error("[Cliphist] Failed to refresh with code", exitCode, "and status", exitStatus)
            }
        }
    }

    // ---- Clipboard pinning (shell-side store, since cliphist has no pin subcommand) ----
    // The pins live in a small JSON file, read/written through a FileView + JsonAdapter
    // so there is no shelling out and no dependency on nonexistent helper functions.
    //
    // Pins are stored by CONTENT (the entry text without cliphist's leading
    // "<id>\t" prefix), not by the full entry string: cliphist reassigns ids on
    // every new copy, so an id-based pin silently stopped matching -- and the
    // pinned entry vanished from the pinned view -- after the next copy.
    readonly property string pinStorePath: Directories.cache + "/cliphist-pinned.json"
    property list<string> pinnedContents: []
    // The label the toast shows: one short word, not the copied text. The card is
    // feedback that the copy LANDED, and a dump of what was copied turns a glance
    // into a read. `copyToastSeq` is how the toast learns that a SECOND copy
    // arrived while it was still up -- the label may be identical, so the text
    // cannot carry that.
    property string lastCopiedText: ""
    property bool copyToastVisible: false
    property int copyToastSeq: 0
    // Set by every path where the SHELL puts something on the clipboard; see
    // shellCopied(). A window rather than a flag, because the refresh that notices
    // the change is asynchronous -- a flag would have to be cleared by the very
    // detection it exists to suppress.
    property real shellCopyUntil: 0
    // The newest entry the toast has already spoken for, and whether the first
    // read after a reload has happened yet. Compared as the WHOLE line, because
    // cliphist's id is part of it: copying the same text again gets a new id and
    // is still a copy worth a card. Declared here rather than inferred from the
    // list length, which cannot tell "one new entry" from "cliphist has not
    // written it yet" -- see the retry in readProc.onExited.
    property string announcedTail: ""
    property bool primedTail: false
    property bool pendingChange: false
    property int toastRetries: 0
    // Whether the change now being tracked is the shell's OWN copy (a paste from
    // the popup, a superpaste). Decided when the change is NOTICED, not when it is
    // announced: cliphist's write is asynchronous and the retry can push the
    // announcement past the suppression window, which would flash a "Copied" card
    // at someone who just pasted from the popup that did it.
    property bool pendingOwnCopy: false

    function noteShellCopy() {
        root.shellCopyUntil = Date.now() + 800
    }

    function shellCopied(): bool {
        return Date.now() < root.shellCopyUntil
    }

    // The entry text without the numeric id cliphist prefixes.
    function entryContent(entry) {
        return entry.replace(/^\d+\t/, "");
    }

    FileView {
        id: pinsFileView
        path: root.pinStorePath
        watchChanges: true
        onLoaded: root.pinnedContents = pinStoreAdapter.pinned ?? []
        onLoadFailed: error => {
            root.pinnedContents = [];
            // First run: create an empty store so writes have somewhere to go.
            if (error == FileViewError.FileNotFound) {
                pinStoreAdapter.pinned = [];
                pinsFileView.writeAdapter();
            }
        }
        adapter: JsonAdapter {
            id: pinStoreAdapter
            property list<string> pinned: []
        }
    }

    function loadPinned() {
        pinsFileView.reload();
    }
    function clearPinned() {
        root.pinnedContents = [];
        pinStoreAdapter.pinned = [];
        pinsFileView.writeAdapter();
    }
    function isPinned(entry) {
        return root.pinnedContents.indexOf(entryContent(entry)) !== -1;
    }
    function togglePin(entry) {
        const content = entryContent(entry);
        if (root.isPinned(entry)) {
            root.pinnedContents = root.pinnedContents.filter(c => c !== content);
        } else {
            root.pinnedContents = root.pinnedContents.concat([content]);
        }
        pinStoreAdapter.pinned = root.pinnedContents;
        pinsFileView.writeAdapter();
    }
    function pinnedEntriesWithPinnedFirst() {
        const pins = [];
        const rest = [];
        for (let i = 0; i < root.entries.length; i++) {
            if (root.isPinned(root.entries[i])) pins.push(root.entries[i]);
            else rest.push(root.entries[i]);
        }
        return pins.concat(rest);
    }

    // Decode an image entry to a temp file and return its path (or null).
    function imagePreviewPath(entry) {
        if (!root.entryIsImage(entry)) return null;
        const entryNumber = entry.split("\t")[0];
        const out = Directories.cliphistDecode + "/" + entryNumber + ".png";
        Quickshell.execDetached(["bash", "-c", `${root.cliphistBinary} decode ${entryNumber} > '${out.replace(/'/g, "'\"'\"'")}`]);
        return out;
    }

    // ── Image previews for the popup (2026-10-28) ─────────────────────���────
    //
    // The popup shows a SNAPSHOT of a copied image instead of the word
    // "(image)", which means a PNG per entry on disk. Decoding is done in ONE
    // batch, once, when the popup opens:
    //
    //   * a decode per row per binding re-evaluation is what the old
    //     `imagePreviewPath` did -- it ran `cliphist decode` from inside a
    //     binding, so a re-render started the work again, and the Image had
    //     its source before the file existed and never retried.
    //   * `imageDecodeGeneration` is the signal that the batch has LANDED.
    //     Rows bind their Image source to it (see ClipboardListWindow), so the
    //     picture appears when the files exist instead of racing them.
    //
    // The files live in Directories.cliphistDecode, the same cache directory
    // the shell empties at start.
    property int imageDecodeGeneration: 0

    function imagePreviewFile(entry) {
        const id = String(entry ?? "").split("\t")[0];
        if (id.length === 0) return "";
        return Directories.cliphistDecode + "/" + id + ".png";
    }

    Process {
        id: imageDecodeProc
        property string script: ""
        command: ["bash", "-c", script]
        // The generation bump re-runs every row's Image binding: that is how a
        // preview shows up after the decode rather than staying on its
        // fallback.
        onExited: root.imageDecodeGeneration += 1
    }

    function decodeImagePreviews(entries) {
        if (imageDecodeProc.running) return;
        const list = (entries ?? []).filter(e => root.entryIsImage(e));
        if (list.length === 0) return;
        const cmds = [`mkdir -p '${Directories.cliphistDecode}'`];
        for (let i = 0; i < list.length; i++) {
            const file = root.imagePreviewFile(list[i]);
            if (file.length === 0) continue;
            const id = String(list[i]).split("\t")[0];
            const quoted = file.replace(/'/g, "'\"'\"'");
            // Already decoded (a previous open of this shell session): leave
            // it alone. Only missing or empty files are decoded -- an empty one
            // is a decode that failed, and retrying it is the only way it can
            // ever recover.
            cmds.push(`[ -s '${quoted}' ] || ${root.cliphistBinary} decode ${id} > '${quoted}' 2>/dev/null`);
        }
        imageDecodeProc.script = cmds.join("; ");
        imageDecodeProc.running = true;
    }

    // Surface the brief "copied" feedback.
    //
    // It is the desktop's top-right signal card, and deliberately NOT a
    // notification: a bare glyph plus one word, sized to the word, with a
    // countdown hairline and nothing else. A copy is a one-word glance, not a
    // message to read, answer or keep -- so it never enters the notification
    // list, its history or its sound. GlobalStates.showSignalToast owns the
    // label, glyph and clock; SignalToast.qml draws it.
    //
    // 1200ms: the toast's tuned hold. Tightened from 1500 (2026-10-19, "it
    // should disappear slightly faster"): the card is a confirmation, not a
    // message, and 1.2s is long enough to see it land and read the one word
    // without it becoming something to wait out.
    //
    // `isImage` chooses the GLYPH, not a translated label: "Image copied" and
    // "Copied" are strings, and guessing the kind from them is how a localized
    // label ends up wearing the wrong icon.
    //
    // The direct call also removes the round trip through gdbus that the
    // notification version needed -- the card is feedback, and it should not
    // arrive a fifth of a second after the thing it confirms.
    function showCopyToast(text, isImage) {
        root.lastCopiedText = text;
        root.copyToastVisible = true;
        root.copyToastSeq++;
        const summary = (text ?? "").trim();
        // Told straight to the top-right card instead of through the
        // notification daemon. The notification route cost a DBus round trip
        // and a GVariant quoted by hand in QML (which broke on this parser
        // once), only for the card to be stripped back down to a glyph and a
        // label -- and it could never be anything but the full notification
        // width. GlobalStates owns the label, the glyph and the clock;
        // SignalToast.qml draws it at the size the word needs.
        GlobalStates.showSignalToast(
            summary.length > 0 ? summary : Translation.tr("Copied"),
            isImage ? "image" : "content_copy",
            1200);
        // Printed because this is the one part of the feedback a terminal cannot see:
        // whether the copy was NOTICED at all is otherwise indistinguishable from a
        // card that was noticed and failed to draw.
        print(`[cliphist] copy toast: ${text} (seq ${root.copyToastSeq})`);
    }

    Component.onCompleted: {
        root.loadPinned();
        // Load the history NOW: without this the list fills only on the next
        // clipboard change, so the popup opened EMPTY after every shell restart
        // -- which read as "the clipboard is broken" when it just had not been
        // given a reason to read the store yet.
        root.refresh();
    }

    IpcHandler {
        target: "cliphistService"

        function update(): void {
            root.refresh()
        }
        // "a copy is happening, do not announce the next change(s)": called by
        // the dictation script around its own clipboard write.
        function quietFor(ms: string): void {
            root.quiet(ms)
        }
    }
}
