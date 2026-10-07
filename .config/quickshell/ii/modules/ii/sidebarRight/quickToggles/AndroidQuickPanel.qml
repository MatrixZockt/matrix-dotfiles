import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Bluetooth

import qs.modules.ii.sidebarRight.quickToggles.androidStyle

AbstractQuickPanel {
    id: root
    property bool editMode: false
    Layout.fillWidth: true

    // Sizes
    implicitHeight: (editMode ? contentItem.implicitHeight : usedRows.implicitHeight) + root.padding * 2
    Behavior on implicitHeight {
        animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
    }
    property real spacing: 6
    property real padding: 6
    readonly property real baseCellWidth: {
        // This is the wrong calculation, but it looks correct in reality???
        // (theoretically spacing should be multiplied by 1 column less)
        const availableWidth = root.width - (root.padding * 2) - (root.spacing * (root.columns))
        return availableWidth / root.columns
    }
    readonly property real baseCellHeight: 56

    // Toggles
    readonly property list<string> availableToggleTypes: ["network", "bluetooth", "idleInhibitor", "easyEffects", "nightLight", "darkMode", "cloudflareWarp", "gameMode", "performance", "screenSnip", "colorPicker", "onScreenKeyboard", "mic", "audio", "notifications", "powerProfile","musicRecognition"]
    readonly property int columns: Config.options.sidebar.quickToggles.android.columns

    // ── The single source of truth, accessed through helpers ─────────────
    // The config array is a `list<var>`: mutating it in place (push/splice on
    // the value a read returns) has UNRELIABLE change notification in this
    // Quickshell build — the grid sometimes does not re-render, so the next
    // edit computed from a stale view produced the duplicate / vanishing
    // icons this panel used to show. Every mutation therefore goes through
    // setToggles(), which copies, fixes, ASSIGNS BACK (assignment always
    // notifies) and lets the JsonAdapter persist.
    readonly property list<var> toggles: dedupeToggles(Config.ready ? Config.options.sidebar.quickToggles.android.toggles : [])
    readonly property list<var> toggleRows: toggleRowsForList(toggles)
    readonly property list<var> unusedToggles: {
        const used = new Set(toggles.filter(t => t && t.type).map(t => t.type));
        return availableToggleTypes.filter(type => !used.has(type))
            .map(type => { return { type: type, size: 1 } });
    }
    readonly property list<var> unusedToggleRows: toggleRowsForList(unusedToggles)

    // Config can hold duplicates (from the very divergence bug this fixes)
    // or nulls: one entry per type, first occurrence wins, nulls dropped.
    // Runs on every read, so the UI can never show a type twice no matter
    // what the file went through.
    function dedupeToggles(list) {
        const seen = new Set();
        const out = [];
        for (let i = 0; i < list.length; i++) {
            const t = list[i];
            if (!t || !t.type || seen.has(t.type))
                continue;
            seen.add(t.type);
            out.push(t);
        }
        return out;
    }

    function setToggles(newList) {
        Config.options.sidebar.quickToggles.android.toggles = dedupeToggles(newList);
    }

    function toggleRowsForList(togglesList) {
        var rows = [];
        var row = [];
        var totalSize = 0; // Total cols taken in current row
        for (var i = 0; i < togglesList.length; i++) {
            if (!togglesList[i]) continue;
            if (totalSize + togglesList[i].size > columns) {
                rows.push(row);
                row = [];
                totalSize = 0;
            }
            row.push(togglesList[i]);
            totalSize += togglesList[i].size;
        }
        if (row.length > 0) {
            rows.push(row);
        }
        return rows;
    }

    // ── Edit operations (all copy-assign; see setToggles) ────────────────
    function addToggle(type) {
        const list = toggles.slice();
        if (list.some(t => t.type === type)) return;
        list.push({ type: type, size: 1 });
        setToggles(list);
    }

    function removeToggle(type) {
        setToggles(toggles.filter(t => t.type !== type));
    }

    function toggleEnabled(index, type) {
        const list = toggles;
        if (!list.some(t => t.type === type)) {
            addToggle(type);
        } else {
            removeToggle(type);
        }
    }

    function toggleSize(index, type) {
        const list = toggles.slice();
        const i = list.findIndex(t => t.type === type);
        if (i === -1) return;
        list[i] = Object.assign({}, list[i], { size: list[i].size === 1 ? 2 : 1 });
        setToggles(list);
    }

    function movePositionBy(index, type, offset) {
        const list = toggles.slice();
        const i = list.findIndex(t => t.type === type);
        const target = i + offset;
        if (i === -1 || target < 0 || target >= list.length) return;
        const temp = list[i];
        list[i] = list[target];
        list[target] = temp;
        setToggles(list);
    }

    // Drag-and-drop reordering: the overlay in edit mode reports a drop as
    // "type → target slot index"; the entry is lifted out and inserted there
    // (rows recompute; sizes shift naturally).
    function moveTypeTo(type, targetIndex) {
        const list = toggles.slice();
        const i = list.findIndex(t => t.type === type);
        if (i === -1) {
            // Dragging an UNUSED toggle in from below: insert it fresh.
            if (targetIndex >= list.length) {
                list.push({ type: type, size: 1 });
            } else {
                list.splice(Math.max(0, targetIndex), 0, { type: type, size: 1 });
            }
            setToggles(list);
            return;
        }
        const clamped = Math.max(0, Math.min(list.length, targetIndex));
        const [item] = list.splice(i, 1);
        const insertAt = i < clamped ? clamped - 1 : clamped;
        list.splice(insertAt, 0, item);
        setToggles(list);
    }

    // ── Drag state (for the drop slot feedback) ──────────────────────────
    property string dragType: ""
    property int dragHoverSlot: -1

    function dragStarted(type) {
        dragType = type;
        dragHoverSlot = -1;
    }

    function dragEnded() {
        dragType = "";
        dragHoverSlot = -1;
    }

    // Which list index does this panel-space point fall on? Uses the real
    // rendered geometry of the used rows (each cell knows its own bounds);
    // a point past the last cell means "append".
    function dropTargetFor(panelPoint, draggedType) {
        const cells = usedRowsRepeater.children;
        let slot = 0;
        let found = -1;
        for (let r = 0; r < root.toggleRows.length; r++) {
            const rowGroup = toggleRowAt(r);
            if (!rowGroup) continue;
            const rowTop = rowGroup.mapToItem(contentItem, 0, 0).y;
            const rowBottom = rowTop + rowGroup.height;
            if (panelPoint.y >= rowTop - 4 && panelPoint.y <= rowBottom + 4) {
                const kids = rowGroup.children;
                for (let c = 0; c < kids.length; c++) {
                    const cell = kids[c];
                    if (!cell.width) continue;
                    const p = cell.mapToItem(contentItem, 0, 0);
                    if (panelPoint.x < p.x + cell.width / 2) {
                        found = slot;
                        break;
                    }
                    slot++;
                }
                if (found === -1) found = slot;
                break;
            }
        }
        if (found === -1) found = toggles.length; // below all rows: append
        return found;
    }

    function toggleRowAt(rowIndex) {
        const rep = usedRowsRepeater;
        for (let i = 0; i < rep.count; i++) {
            const item = rep.itemAt(i);
            if (item && item.index === rowIndex)
                return item;
        }
        return null;
    }

    Column {
        id: contentItem
        anchors {
            fill: parent
            margins: root.padding
        }
        spacing: 12
        
        Column {
            id: usedRows
            spacing: root.spacing

            Repeater {
                id: usedRowsRepeater
                model: ScriptModel {
                    values: Array(root.toggleRows.length)
                }
                delegate: ButtonGroup {
                    id: toggleRow
                    required property int index
                    property var modelData: root.toggleRows[index]
                    property int startingIndex: {
                        const rows = root.toggleRows;
                        let sum = 0;
                        for (let i = 0; i < index; i++) {
                            sum += rows[i].length;
                        }
                        return sum;
                    }
                    spacing: root.spacing

                    Repeater {
                        model: ScriptModel {
                            values: toggleRow?.modelData ?? []
                            objectProp: "type"
                        }
                        delegate: AndroidToggleDelegateChooser {
                            startingIndex: toggleRow.startingIndex
                            editMode: root.editMode
                            editOps: root
                            panelRef: root
                            baseCellWidth: root.baseCellWidth
                            baseCellHeight: root.baseCellHeight
                            spacing: root.spacing
                            onOpenAudioOutputDialog: root.openAudioOutputDialog()
                            onOpenAudioInputDialog: root.openAudioInputDialog()
                            onOpenBluetoothDialog: root.openBluetoothDialog()
                            onOpenNightLightDialog: root.openNightLightDialog()
                            onOpenWifiDialog: root.openWifiDialog()
                        }
                    }
                }
            }
        }

        FadeLoader {
            shown: root.editMode
            anchors {
                left: parent.left
                right: parent.right
                leftMargin: root.baseCellHeight / 2
                rightMargin: root.baseCellHeight / 2
            }
            sourceComponent: Rectangle {
                implicitHeight: 1
                color: Appearance.colors.colOutlineVariant
            }
        }

        FadeLoader {
            shown: root.editMode
            sourceComponent: Column {
                id: unusedRows
                spacing: root.spacing

                Repeater {
                    model: ScriptModel {
                        values: Array(root.unusedToggleRows.length)
                    }
                    delegate: ButtonGroup {
                        id: unusedToggleRow
                        required property int index
                        property var modelData: root.unusedToggleRows[index]
                        spacing: root.spacing

                        Repeater {
                            model: ScriptModel {
                                values: unusedToggleRow?.modelData ?? []
                                objectProp: "type"
                            }
                            delegate: AndroidToggleDelegateChooser {
                                startingIndex: -1
                                editMode: root.editMode
                                editOps: root
                                panelRef: root
                                baseCellWidth: root.baseCellWidth
                                baseCellHeight: root.baseCellHeight
                                spacing: root.spacing
                            }
                        }
                    }
                }
            }
        }
    }
}
