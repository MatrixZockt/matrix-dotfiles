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

    // ── No view state ──────────────────────────────────────────────────
    //
    // A `minimizedIds` set used to live here: the ids of just-ticked tasks, kept
    // so the ticked row could fold in place on the Unfinished page and retire to
    // Done only when that page was left. It is gone, because it put a finished
    // task in the list of things still owed, for as long as the page was open,
    // and kept it off Done in the meantime -- the opposite of what the tick
    // says. `tick` (TaskList.qml) now marks the task and nothing else, so a
    // task's `done` flag is the whole of its state and the two pages are plain
    // views of it.

    // ── Live lookups for the row bindings ──────────────────────────────
    //
    // The entries in `list` are plain JS objects, and a QML binding that reads a
    // field of a plain object NEVER re-evaluates: nothing about an object like
    // that emits a change signal, so a row kept whatever it read when its
    // delegate was built. That was invisible while the only thing reading these
    // fields was the Done page (whose delegates are built with `done` already
    // true) -- but the same row can be drawn on either page, and a task can be
    // unticked from Done and ticked again from Unfinished without its delegate
    // being rebuilt, so a stale `done` means a finished task still drawing an
    // empty circle and bright text (or the reverse).
    //
    // Every field a row DRAWS therefore goes through one of these, and what makes
    // them live is the read of `list` they do on the way: `list` is a notifiable
    // property, and `persist()` reassigns it on every mutation -- the same
    // reassignment ScriptModel already watches -- so the binding has something
    // to depend on and re-evaluates the moment the task changes.
    function taskById(id) {
        for (let i = 0; i < list.length; i++) {
            if (list[i].id === id)
                return list[i]
        }
        return null
    }

    function isDone(id) {
        const task = taskById(id)
        return task !== null && task.done === true
    }

    function contentOf(id) {
        const task = taskById(id)
        return task === null ? "" : String(task.content ?? "")
    }

    // ── Completion stamps and retention ────────────────────────────────
    //
    // A task that is ticked gets a `completedAt` (epoch ms) written the moment
    // it is marked done, and the stamp is removed the moment it is unticked.
    // The stamp exists for two reasons: the Done page draws it under the task
    // text, and retention below is measured from it.
    //
    // Done tasks are NOT kept forever. One month after they are finished they
    // are dropped, so the Done page stays a record of recent work rather than
    // an ever-growing archive. Only DONE tasks are ever dropped -- an
    // unfinished task has no stamp and is never touched, however old it is.
    //
    // `double`, NOT `int`: QML's `int` is 32-bit, and 30 days in ms is
    // 2,592,000,000 -- past INT32_MAX. Declared `int` it wrapped to a NEGATIVE
    // number, which made `now - completedAt > retentionMs` true for every
    // stamp and would have deleted every finished task at once. Epoch
    // milliseconds are inherently 64-bit and so is this.
    readonly property double retentionMs: 30 * 86400000

    // Live lookup for the row bindings, in the same shape as `isDone` /
    // `contentOf`: it reads `list` on the way, so a row re-evaluates the
    // moment its task is stamped or unstamped rather than keeping whatever
    // the delegate read when it was built. 0 means "no stamp".
    function completedAtOf(id) {
        const task = taskById(id)
        if (task === null || task.completedAt === undefined || task.completedAt === null)
            return 0
        return Number(task.completedAt)
    }

    // Stamp any done task that predates the stamp (a list written before this
    // field existed). They are stamped with the load time, which starts their
    // retention window now -- the alternative, dropping them on sight the
    // first time the shell loads after this change, would delete a month of
    // finished work the user never asked to lose.
    //
    // Returns true if anything was added, so the caller can write the file
    // back exactly once.
    function ensureCompletedAt() {
        const now = Date.now()
        let added = false
        for (let i = 0; i < list.length; i++) {
            const task = list[i]
            if (task.done === true
                    && (task.completedAt === undefined || task.completedAt === null)) {
                task.completedAt = now
                added = true
            }
        }
        return added
    }

    // Drop every done task finished more than `retentionMs` ago. Unfinished
    // tasks are never candidates, and a done task with no stamp is left alone
    // (`ensureCompletedAt` gives it one first).
    //
    // Mutates `list` and writes the file itself, so it is safe to call from
    // anywhere -- the load path, a tick, or the hourly timer -- and returns
    // true only when something was actually dropped. Only rewriting the file
    // when it changed matters: an unconditional write here would churn the
    // file every hour for no reason.
    function purgeExpiredDone() {
        const now = Date.now()
        const kept = list.filter(t => !(t.done === true
            && t.completedAt !== undefined && t.completedAt !== null
            && now - Number(t.completedAt) > retentionMs))
        if (kept.length === list.length)
            return false
        root.list = kept
        todoFileView.setText(JSON.stringify(root.list))
        return true
    }

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
            list[index].completedAt = Date.now()
            persist()
            purgeExpiredDone()
        }
    }

    function markUnfinished(index) {
        if (index >= 0 && index < list.length) {
            list[index].done = false
            delete list[index].completedAt
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
        // Stamp it now. The Done page draws this and retention counts from it,
        // so a done task without one is the one shape that must never reach
        // the list.
        list[i].completedAt = Date.now()
        persist()
        // A tick can be the moment a task crosses the retention line (the
        // shell may have been running across it), so sweep at the same time.
        purgeExpiredDone()
        return true
    }

    function markUnfinishedById(id) {
        const i = list.findIndex(t => t.id === id)
        if (i < 0)
            return false
        list[i].done = false
        // Unticking is "this is not finished after all", so the stamp goes
        // with the tick. A task re-ticked later gets a fresh one.
        delete list[i].completedAt
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

    // ── IPC: writing tasks down without a pointer ──────────────────────
    //
    // The list is also where finished work gets recorded ("this was verified on
    // this machine, and here is the number it produced"), and there was no way
    // to write that from a terminal: the JSON file is loaded ONCE at startup
    // (see the FileView below -- no watcher, no reload on external change), so
    // a file edited behind the running shell's back is not shown, and the next
    // tick writes the stale in-memory list straight over it. The handler makes
    // the running shell do the write, which is the only path that survives.
    //
    //   qs -c ii ipc call todo state
    //   qs -c ii ipc call todo addDone "Verified: ..."
    //
    // addDone stamps `completedAt` itself, the same way markDoneById does: a
    // done task without a stamp is the one shape that must never reach the
    // list, because retention and the Done page both measure from it.
    IpcHandler {
        target: "todo"

        function add(text: string): string {
            root.addTask(text);
            return String(root.list[root.list.length - 1].id);
        }

        function addDone(text: string): string {
            const id = root.nextId;
            root.nextId += 1;
            root.addItem({ "id": id, "content": text, "done": true, "completedAt": Date.now() });
            root.purgeExpiredDone();
            return String(id);
        }

        function state(): string {
            const done = root.list.filter(t => t.done === true).length;
            return `total=${root.list.length} done=${done} open=${root.list.length - done}`;
        }
    }

    // Retention also runs on a slow clock, so a task that crosses the line
    // while the shell is running disappears on its own instead of waiting for
    // the next restart or tick. Hourly is chosen because the boundary is
    // measured in days: nothing is gained by checking more often, and the
    // sweep itself is free when nothing is due (see `purgeExpiredDone`).
    Timer {
        interval: 3600000
        running: true
        repeat: true
        onTriggered: root.purgeExpiredDone()
    }

    FileView {
        id: todoFileView
        path: Qt.resolvedUrl(root.filePath)
        onLoaded: {
            const fileContents = todoFileView.text()
            root.list = JSON.parse(fileContents)
            // Three migrations/upkeeps, each reporting whether it changed
            // anything, so the file is written back AT MOST once.
            //
            // 1. Give every pre-existing task a stable id, so from here on
            //    every task has one for the rest of its life.
            // 2. Stamp done tasks that predate the stamp, starting their
            //    retention window now.
            // 3. Drop done tasks past that window.
            //
            // The order matters: 2 before 3 means an unstamped done task is
            // given a fresh stamp and then judged as recent, rather than
            // being treated as ancient and deleted.
            let changed = ensureIds()
            changed = ensureCompletedAt() || changed
            // `purgeExpiredDone` writes the file itself when it drops
            // something, so `changed` only has to make sure a stamp/ids
            // migration is not lost.
            purgeExpiredDone()
            if (changed) {
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

