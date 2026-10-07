pragma Singleton
pragma ComponentBehavior: Bound

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
    // The synthesised paste, through the compositor. See paste() for why this
    // is not ydotool.
    property string pressPasteCommand: "ydotool key -d 1 29:1 47:1 47:0 29:0"
    readonly property string pasteShortcutCommand: "hyprctl dispatch 'hl.dsp.send_shortcut({ mods = \"CTRL\", key = \"v\" })'"
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

    readonly property int previousEntryCount: readProc.buffer.length

    function refresh() {
        readProc.buffer = []
        readProc.running = true
    }

    function copy(entry) {
        if (root.cliphistBinary.includes("cliphist")) // Classic cliphist
            Quickshell.execDetached(["bash", "-c", `printf '%s' '${StringUtils.shellSingleQuoteEscape(entry)}' | ${root.cliphistBinary} decode | wl-copy`]);
        else { // Stash
            const entryNumber = entry.split("\t")[0];
            Quickshell.execDetached(["bash", "-c", `${root.cliphistBinary} decode ${entryNumber} | wl-copy`]);
        }
    }

    function paste(entry) {
        // Decode the entry onto the clipboard, then ACTUALLY INPUT it into the
        // focused window.
        //
        // The keystroke goes through the COMPOSITOR (`hyprctl dispatch
        // hl.dsp.send_shortcut`), not through ydotool. Two reasons, both learned
        // the hard way:
        //
        //   * ydotool injects via /dev/uinput, which is a synthetic keyboard as
        //     far as Hyprland is concerned: it needs uinput permissions, it
        //     depends on ydotoold still being alive, and a release that does
        //     not land leaves the key stuck down -- which then types into
        //     whatever grabs focus next. That is not hypothetical here: a stuck
        //     key from an earlier paste kept appending characters into the
        //     clipboard popup's own search box.
        //   * wl-clipboard 2.3 has no `wl-copy --paste`, so there is no
        //     protocol-level "paste this now". Some keystroke has to be
        //     synthesised -- and the compositor is the reliable place to do it,
        //     because it addresses the focused window directly instead of
        //     hoping the virtual keyboard reaches it.
        //
        // The sleep is before the keys, and longer than it looks like it needs
        // to be: this popup closes as the click lands, and Hyprland gives the
        // keyboard back to the window underneath a beat later -- pasting into
        // a window that has not got focus yet is pasting into nothing.
        if (root.cliphistBinary.includes("cliphist")) { // Classic cliphist
            const decoded = `printf '%s' '${StringUtils.shellSingleQuoteEscape(entry)}' | ${root.cliphistBinary} decode | wl-copy`;
            Quickshell.execDetached(["bash", "-c",
                `${decoded}; sleep 0.18; ${root.pasteShortcutCommand}`]);
        } else { // Stash
            const entryNumber = entry.split("\t")[0];
            Quickshell.execDetached(["bash", "-c", `${root.cliphistBinary} decode ${entryNumber} | wl-copy; sleep 0.15; ${root.pressPasteCommand}`]);
        }
    }

    function superpaste(count, isImage = false) {
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

    Connections {
        target: Quickshell
        function onClipboardTextChanged() {
            delayedUpdateTimer.restart()
        }
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
                // Detect a newly copied entry: the list grew by one and the new tail is
                // the freshly copied item. Show a brief toast for it (never routed through
                // the notification service, so it doesn't enter notification history).
                if (readProc.buffer.length > 0
                    && readProc.buffer.length === previous.length + 1
                    && root.workSafety.clipboard.enable !== true) {
                    const newest = readProc.buffer[readProc.buffer.length - 1]
                    const isImage = root.entryIsImage(newest)
                    const text = isImage
                        ? Translation.tr("Copied an image")
                        : (newest.split("\t")[0]?.replace(/^\s*\S+\s+/, "") ?? "")
                    if (text !== "") {
                        root.showCopyToast(text)
                    } else {
                        root.showCopyToast(Translation.tr("Copied"))
                    }
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
    property string lastCopiedText: ""
    property bool copyToastVisible: false

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

    // Called by the copy notification path to surface a brief "copied" toast.
    function showCopyToast(text) {
        root.lastCopiedText = text;
        root.copyToastVisible = true;
        root.copyToastTimer.restart();
    }

    Timer {
        id: copyToastTimer
        interval: 1500
        repeat: false
        onTriggered: { root.copyToastVisible = false; root.lastCopiedText = ""; }
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
    }
}
