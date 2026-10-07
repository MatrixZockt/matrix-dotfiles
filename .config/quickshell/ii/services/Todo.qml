pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import Quickshell;
import Quickshell.Io;
import QtQuick;

/**
 * Simple to-do list manager.
 * Each item is an object with "content" and "done" properties.
 */
Singleton {
    id: root
    property var filePath: Directories.todoPath
    property var list: []

    // Every mutation funnels through here. Before the reorder work each function
    // repeated the same two lines -- reassign `list` so the ScriptModel sees a
    // new reference, then write the JSON -- and a new mutator that forgot the
    // reassign would update the screen and silently lose the change on the next
    // reload. One place to get it wrong instead of five.
    function persist() {
        root.list = list.slice(0)
        todoFileView.setText(JSON.stringify(root.list))
    }

    function addItem(item) {
        list.push(item)
        persist()
    }

    function addTask(desc) {
        const item = {
            "id": nextId,
            "content": desc,
            "done": false,
        }
        nextId += 1
        addItem(item)
    }

    // Every task carries a stable `id`, allocated once and never reused.
    //
    // WHY THIS EXISTS: the two task views used to be built by cloning every
    // entry to attach a positional `originalIndex` --
    //   `Todo.list.map((item, i) => Object.assign({}, item, {originalIndex: i}))`
    // -- which gives every task a brand-new object identity on every rebuild.
    // Quickshell's ScriptModel identifies rows by object identity, so each
    // rebuild looked like the entire list was deleted and re-added. During a
    // drag that rebuild fires exactly once, at drop, and rendered as the
    // dragged task briefly duplicating.
    //
    // With ids the views are plain `filter()` calls, which preserve identity,
    // so a reorder is now a pure permutation: ScriptModel emits a move, not a
    // remove/add, and nothing ghosts.
    property int nextId: 1

    // True while a task row is being dragged, wherever in the shell that drag
    // lives.
    //
    // The sidebars close on pointer-out after a short grace, and a drag that
    // carries the cursor past the edge used to trip that: the panel began to
    // close mid-drag, the row it was carrying was destroyed with the loader,
    // and the task snapped back to the last slot it had passed over. A global
    // flag lets the sidebars stand down while a drag is in flight.
    property bool dragInFlight: false

    // Backfill ids onto a list loaded from disk, and point `nextId` past the
    // highest one seen. Runs on every load so ids survive restarts.
    function ensureIds() {
        let max = 0
        for (let i = 0; i < list.length; i++) {
            const id = list[i].id
            if (typeof id === "number" && id > max)
                max = id
        }
        let added = false
        for (let i = 0; i < list.length; i++) {
            if (list[i].id === undefined || list[i].id === null) {
                max += 1
                list[i].id = max
                added = true
            }
        }
        nextId = max + 1
        return added
    }

    function markDone(index) {
        if (index >= 0 && index < list.length) {
            list[index].done = true
            persist()
        }
    }

    function markUnfinished(index) {
        if (index >= 0 && index < list.length) {
            list[index].done = false
            persist()
        }
    }

    function deleteItem(index) {
        if (index >= 0 && index < list.length) {
            list.splice(index, 1)
            persist()
        }
    }

    // ── Id-addressed mutators ────────────────────────────────────────
    // The task views filter the list, so a row's position in a view is not its
    // position in the file. These take the task's stable id instead, which is
    // true regardless of which view it came from.

    function markDoneById(id) {
        const i = list.findIndex(t => t.id === id)
        if (i < 0)
            return false
        list[i].done = true
        persist()
        return true
    }

    function markUnfinishedById(id) {
        const i = list.findIndex(t => t.id === id)
        if (i < 0)
            return false
        list[i].done = false
        persist()
        return true
    }

    function deleteById(id) {
        const i = list.findIndex(t => t.id === id)
        if (i < 0)
            return false
        list.splice(i, 1)
        persist()
        return true
    }

    // Replace a task's text, addressed by id like every other mutator here.
    //
    // An empty or whitespace-only edit is REJECTED rather than stored. A task
    // whose whole content is blank is indistinguishable from a broken entry in
    // the list -- there is nothing to click open and nothing to read -- and
    // the composer already refuses to add one, so saving one here would let the
    // two paths disagree about what a valid task is. The row falls back to the
    // text it already had.
    //
    // Returns true only if something actually changed, so the caller can decide
    // whether to leave edit mode.
    function editById(id, content) {
        const i = list.findIndex(t => t.id === id)
        if (i < 0)
            return false
        const text = String(content ?? "").trim()
        if (text.length === 0)
            return false
        if (list[i].content === text)
            return true
        list[i].content = text
        persist()
        return true
    }

    // Move `fromId` so that it sits immediately BEFORE `targetId`. Pass null
    // for `targetId` to send it to the end.
    //
    // Working on a copy and reusing the same objects keeps every identity
    // intact, so ScriptModel sees a permutation and animates it as a move.
    function moveBeforeId(fromId, targetId) {
        const from = list.findIndex(t => t.id === fromId)
        if (from < 0)
            return false
        if (targetId !== null && targetId !== undefined && targetId === fromId)
            return false

        const next = list.slice(0)
        const [moved] = next.splice(from, 1)

        let at
        if (targetId === null || targetId === undefined) {
            at = next.length
        } else {
            at = next.findIndex(t => t.id === targetId)
            if (at < 0)
                at = next.length
        }
        next.splice(at, 0, moved)

        root.list = next
        todoFileView.setText(JSON.stringify(root.list))
        return true
    }

    // ── Positional helpers, kept for compatibility ───────────────────
    //
    // The task views now address tasks by the stable `id` (see
    // `moveBeforeId`), because a positional index is only meaningful when the
    // list is unfiltered -- and both views are. These are no longer called from
    // the UI but are left in place rather than deleted.
    //
    // Both indices are positions in the WHOLE list. Splicing inside a filtered
    // view would silently drop every hidden task.
    function moveItem(from, to) {
        if (from === to)
            return false;
        if (from < 0 || to < 0 || from >= list.length || to >= list.length)
            return false;

        const next = list.slice(0);
        const [moved] = next.splice(from, 1);
        next.splice(to, 0, moved);

        root.list = next;
        todoFileView.setText(JSON.stringify(root.list));
        return true;
    }

    // Positional convenience wrappers. See the note on `moveItem`.
    function moveBefore(fromOriginalIndex, targetOriginalIndex) {
        return moveItem(fromOriginalIndex, targetOriginalIndex);
    }

    function moveToEnd(fromOriginalIndex) {
        if (fromOriginalIndex < 0 || fromOriginalIndex >= list.length)
            return false;
        return moveItem(fromOriginalIndex, list.length - 1);
    }

    function refresh() {
        todoFileView.reload()
    }

    Component.onCompleted: {
        refresh()
    }

    FileView {
        id: todoFileView
        path: Qt.resolvedUrl(root.filePath)
        onLoaded: {
            const fileContents = todoFileView.text()
            root.list = JSON.parse(fileContents)
            // Give every pre-existing task a stable id and write the file back,
            // so from here on every task has one for the rest of its life.
            if (ensureIds()) {
                root.list = list.slice(0)
                todoFileView.setText(JSON.stringify(root.list))
            }
            console.log("[To Do] File loaded")
        }
        onLoadFailed: (error) => {
            if(error == FileViewError.FileNotFound) {
                console.log("[To Do] File not found, creating new file.")
                root.list = []
                todoFileView.setText(JSON.stringify(root.list))
            } else {
                console.log("[To Do] Error loading file: " + error)
            }
        }
    }
}

