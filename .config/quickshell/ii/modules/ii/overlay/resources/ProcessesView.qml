pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.services
import qs.modules.common
import qs.modules.common.widgets

/**
 * The process table: every program on the machine, sorted, searchable, and
 * endable.
 *
 * It is deliberately a table and not a list of cards. A task manager is read by
 * comparing rows -- which of these is the one eating the processor -- and a
 * table is the only shape where the numbers line up under each other, so the
 * eye can do that without reading anything.
 *
 * Two things are borrowed from the task manager everybody already knows: rows
 * fold into one row per application (see ProcessList.grouped), and ending a task
 * is offered on the row itself, where the process you want to end is, rather
 * than in a menu somewhere else that needs the row selected first.
 *
 * Columns are fixed-width on purpose. A table whose columns resize themselves to
 * their contents has a different column boundary on every screen and grows a
 * different header each time the numbers change width; fixed widths plus one
 * flexible name column means the header is the ruler for every row below it.
 */
ColumnLayout {
    id: root
    spacing: 8

    // Which row is selected, by its own key -- "app:firefox", "pid:1234". Kept
    // as the key rather than the row object so that a sample landing mid-click
    // cannot leave the selection pointing at a row that no longer exists.
    property string selectedKey: ""

    readonly property var selectedRow: {
        const _ = ProcessList.revision;
        return ProcessList.rows.find(row => row.key === root.selectedKey) ?? null;
    }

    // Column widths, in one place, so the header and the rows cannot drift.
    readonly property int statusWidth: 78
    readonly property int cpuWidth: 62
    readonly property int memoryWidth: 80
    readonly property int userWidth: 92
    readonly property int pidWidth: 56
    readonly property int actionWidth: 34

    function rowIcon(row) {
        if (row.kind === "group")
            return "apps";
        return row.user === "root" ? "terminal" : "deployed_code";
    }

    function stateLabel(state) {
        // The kernel's one-letter states, in the words the other task manager
        // uses. Sleeping is what almost every process is doing at any moment,
        // and calling that "Running" is not a lie: it is a process that is
        // ready to run and not waiting for anything.
        switch (state) {
        case "R": return Translation.tr("Running");
        case "S": return Translation.tr("Running");
        case "D": return Translation.tr("Waiting");
        case "I": return Translation.tr("Suspended");
        case "T": return Translation.tr("Suspended");
        case "t": return Translation.tr("Traced");
        case "Z": return Translation.tr("Zombie");
        case "X": return Translation.tr("Dead");
        default: return state ?? "";
        }
    }


    function endSelected(force) {
        const row = root.selectedRow;
        if (!row)
            return;
        ProcessList.endTask(row.pids, row.name);
        if (row.kind === "group" && ProcessList.expandedGroups.includes(String(row.name).toLowerCase()))
            ProcessList.toggleGroup(row.name);
    }

    // ── Toolbar ──────────────────────────────────────────────────────────────
    RowLayout {
        Layout.fillWidth: true
        spacing: 6

        ToolbarTextField {
            id: searchField
            Layout.fillHeight: false
            implicitWidth: 200
            implicitHeight: 34
            placeholderText: Translation.tr("Search processes")
            text: ProcessList.query
            onTextChanged: ProcessList.query = text
        }

        RippleButton {
            implicitWidth: 34
            implicitHeight: 34
            buttonRadius: Appearance.rounding.small
            colBackground: Appearance.colors.colLayer1
            colBackgroundHover: Appearance.colors.colLayer1Hover
            onClicked: ProcessList.sample()
            contentItem: MaterialSymbol {
                anchors.centerIn: parent
                text: ProcessList.sampling ? "autorenew" : "refresh"
                iconSize: 17
                color: Appearance.colors.colOnLayer1
                rotation: ProcessList.sampling ? 0 : 0
                NumberAnimation on rotation {
                    running: ProcessList.sampling
                    from: 0
                    to: 360
                    duration: 1200
                    loops: Animation.Infinite
                }
            }
            StyledToolTip { text: Translation.tr("Sample again") }
        }

        Item { Layout.fillWidth: true }

        RippleButton {
            implicitHeight: 34
            implicitWidth: groupRow.implicitWidth + 20
            buttonRadius: Appearance.rounding.small
            toggled: ProcessList.grouped
            colBackground: Appearance.colors.colLayer1
            colBackgroundHover: Appearance.colors.colLayer1Hover
            colBackgroundToggled: Appearance.colors.colSecondaryContainer
            colBackgroundToggledHover: Appearance.colors.colSecondaryContainerHover
            onClicked: {
                ProcessList.grouped = !ProcessList.grouped;
                ProcessList.collapseAll();
            }
            contentItem: RowLayout {
                id: groupRow
                anchors.centerIn: parent
                spacing: 6
                MaterialSymbol {
                    text: ProcessList.grouped ? "workspaces" : "view_list"
                    iconSize: 16
                    color: ProcessList.grouped ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                }
                StyledText {
                    text: Translation.tr("Group by app")
                    font.pixelSize: Appearance.font.pixelSize.smallie
                    color: ProcessList.grouped ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                }
            }
            StyledToolTip {
                text: Translation.tr("Fold every process of one application into a single row")
            }
        }

        RippleButton {
            id: endTaskButton
            enabled: root.selectedRow !== null
            implicitHeight: 34
            implicitWidth: endTaskText.implicitWidth + 26
            buttonRadius: Appearance.rounding.small
            colBackground: Appearance.colors.colErrorContainer
            colBackgroundHover: Appearance.colors.colErrorContainerHover
            onClicked: root.endSelected()
            contentItem: RowLayout {
                anchors.centerIn: parent
                spacing: 6
                MaterialSymbol {
                    text: "close"
                    iconSize: 16
                    color: endTaskButton.enabled ? Appearance.colors.colOnErrorContainer : Appearance.colors.colOnLayer1Inactive
                }
                StyledText {
                    id: endTaskText
                    text: Translation.tr("End task")
                    font.pixelSize: Appearance.font.pixelSize.smallie
                    color: endTaskButton.enabled ? Appearance.colors.colOnErrorContainer : Appearance.colors.colOnLayer1Inactive
                }
            }
            StyledToolTip {
                text: Translation.tr("End the selected process now -- no confirmation.\nIf it will not quit, it is force-closed after 1s.")
            }
        }
    }

    // Refusals, in the place the action happened rather than in a dialog: the
    // interesting part of a failed "End task" is the reason, and a dialog that
    // has to be dismissed hides the table while you read it.
    Rectangle {
        Layout.fillWidth: true
        visible: ProcessList.lastError.length > 0
        implicitHeight: errorRow.implicitHeight + 14
        radius: Appearance.rounding.small
        color: Appearance.colors.colErrorContainer

        RowLayout {
            id: errorRow
            anchors {
                fill: parent
                leftMargin: 12
                rightMargin: 6
            }
            spacing: 8

            MaterialSymbol {
                text: "error"
                iconSize: 16
                color: Appearance.colors.colOnErrorContainer
            }
            StyledText {
                Layout.fillWidth: true
                text: ProcessList.lastErrorSubject.length > 0
                    ? Translation.tr("%1 — %2").arg(ProcessList.lastErrorSubject).arg(ProcessList.lastError)
                    : ProcessList.lastError
                font.pixelSize: Appearance.font.pixelSize.smallie
                color: Appearance.colors.colOnErrorContainer
                elide: Text.ElideRight
            }
            RippleButton {
                implicitWidth: 24
                implicitHeight: 24
                buttonRadius: Appearance.rounding.full
                colBackground: "transparent"
                onClicked: ProcessList.dismissError()
                contentItem: MaterialSymbol {
                    anchors.centerIn: parent
                    text: "close"
                    iconSize: 14
                    color: Appearance.colors.colOnErrorContainer
                }
            }
        }
    }

    // ── Header ───────────────────────────────────────────────────────────────
    component HeaderCell: RippleButton {
        id: headerCell
        required property string columnKey
        required property string label
        property int alignment: Text.AlignLeft
        property bool sorted: ProcessList.sortKey === headerCell.columnKey
        property bool descending: sorted && !ProcessList.sortAscending

        implicitHeight: 26
        buttonRadius: Appearance.rounding.verysmall
        colBackground: "transparent"
        colBackgroundHover: Appearance.colors.colLayer2Hover
        onClicked: ProcessList.setSort(headerCell.columnKey)

        contentItem: RowLayout {
            anchors {
                fill: parent
                leftMargin: 6
                rightMargin: 6
            }
            layoutDirection: headerCell.alignment === Text.AlignRight ? Qt.RightToLeft : Qt.LeftToRight
            spacing: 2

            StyledText {
                Layout.fillWidth: true
                text: headerCell.label
                horizontalAlignment: headerCell.alignment
                font.pixelSize: Appearance.font.pixelSize.smallie
                color: headerCell.sorted ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                elide: Text.ElideRight
            }
            MaterialSymbol {
                visible: headerCell.sorted
                text: headerCell.descending ? "arrow_downward" : "arrow_upward"
                iconSize: 13
                color: Appearance.colors.colPrimary
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 0

        HeaderCell {
            Layout.fillWidth: true
            columnKey: "name"
            label: Translation.tr("Name")
        }
        HeaderCell {
            Layout.preferredWidth: root.statusWidth
            columnKey: "state"
            label: Translation.tr("Status")
        }
        HeaderCell {
            Layout.preferredWidth: root.cpuWidth
            columnKey: "cpu"
            label: Translation.tr("CPU")
            alignment: Text.AlignRight
        }
        HeaderCell {
            Layout.preferredWidth: root.memoryWidth
            columnKey: "memory"
            label: Translation.tr("Memory")
            alignment: Text.AlignRight
        }
        HeaderCell {
            Layout.preferredWidth: root.userWidth
            columnKey: "user"
            label: Translation.tr("User")
        }
        HeaderCell {
            Layout.preferredWidth: root.pidWidth
            columnKey: "pid"
            label: Translation.tr("PID")
            alignment: Text.AlignRight
        }
        Item { Layout.preferredWidth: root.actionWidth }
    }

    // ── The table ────────────────────────────────────────────────────────────
    Rectangle {
        Layout.fillWidth: true
        Layout.fillHeight: true
        radius: Appearance.rounding.small
        color: Appearance.colors.colLayer1
        clip: true

        StyledListView {
            id: table
            anchors {
                fill: parent
                margins: 4
            }
            model: ProcessList.rows
            clip: true
            spacing: 1
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: StyledScrollBar {}
            // Keyboard, because a table you have to reach for the mouse to use is
            // half a table: arrows walk the rows, Delete ends the task, Escape
            // clears the selection.
            activeFocusOnTab: true
            currentIndex: ProcessList.rows.findIndex(row => row.key === root.selectedKey)
            onCurrentIndexChanged: {
                const row = ProcessList.rows[currentIndex];
                if (row)
                    root.selectedKey = row.key;
            }
            Keys.onPressed: (event) => {
                if (event.key === Qt.Key_Delete)
                    root.endSelected();
                else if (event.key === Qt.Key_Escape) {
                    root.selectedKey = "";
                    table.currentIndex = -1;
                }
                else
                    return;
                event.accepted = true;
            }

            delegate: Rectangle {
                id: row
                required property var modelData
                required property int index

                readonly property bool isGroup: row.modelData.kind === "group"
                readonly property bool isSelected: root.selectedKey === row.modelData.key

                width: table.width
                height: 28
                radius: Appearance.rounding.verysmall
                color: row.isSelected ? Appearance.colors.colSecondaryContainer
                    : rowMouse.containsMouse ? Appearance.colors.colLayer2Hover
                    : "transparent"

                MouseArea {
                    id: rowMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: (event) => {
                        if (event.button === Qt.RightButton) {
                            // Right-click ends the task outright, forced: it is
                            // the shortcut for the case this card exists for --
                            // something will not close. (Force-kill: SIGKILL,
                            // no save prompts, no cleanup.)
                            ProcessList.forceKill(row.modelData.pids, row.modelData.name);
                            root.selectedKey = row.modelData.key;
                            return;
                        }
                        root.selectedKey = row.modelData.key;
                        table.currentIndex = row.index;
                        if (row.isGroup)
                            ProcessList.toggleGroup(row.modelData.name);
                    }
                }

                RowLayout {
                    anchors {
                        fill: parent
                        leftMargin: 4
                        rightMargin: 2
                    }
                    spacing: 0

                    // The name column: indent, disclosure, icon, label.
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: row.isGroup ? 0 : 18
                        spacing: 6

                        MaterialSymbol {
                            visible: row.isGroup
                            Layout.leftMargin: 2
                            text: row.modelData.expanded ? "expand_more" : "chevron_right"
                            iconSize: 16
                            color: Appearance.colors.colSubtext
                        }
                        MaterialSymbol {
                            text: root.rowIcon(row.modelData)
                            iconSize: 15
                            color: row.isSelected ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                        }
                        StyledText {
                            Layout.fillWidth: true
                            text: {
                                const count = row.modelData.count ?? 0;
                                if (row.isGroup && count > 1)
                                    return `${row.modelData.name} (${count})`;
                                return row.modelData.name ?? "";
                            }
                            elide: Text.ElideRight
                            font.pixelSize: Appearance.font.pixelSize.smallie
                            color: row.isSelected ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                        }
                    }

                    StyledText {
                        Layout.preferredWidth: root.statusWidth
                        Layout.leftMargin: 6
                        Layout.rightMargin: 6
                        text: row.isGroup ? "" : root.stateLabel(row.modelData.state)
                        elide: Text.ElideRight
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                    }

                    StyledText {
                        Layout.preferredWidth: root.cpuWidth
                        Layout.rightMargin: 6
                        horizontalAlignment: Text.AlignRight
                        text: (row.modelData.cpu ?? 0).toFixed(1) + "%"
                        font {
                            family: Appearance.font.family.numbers
                            variableAxes: Appearance.font.variableAxes.numbers
                            pixelSize: Appearance.font.pixelSize.smallie
                        }
                        // A heat cue, not a chart: the number stays the number,
                        // and the colour says the same thing at a glance from
                        // across the room.
                        color: {
                            const cpu = row.modelData.cpu ?? 0;
                            if (cpu >= 25)
                                return Appearance.colors.colError;
                            if (cpu >= 5)
                                return Appearance.colors.colTertiary;
                            return row.isSelected ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1;
                        }
                    }

                    StyledText {
                        Layout.preferredWidth: root.memoryWidth
                        Layout.rightMargin: 6
                        horizontalAlignment: Text.AlignRight
                        text: SystemFacts.bytes(row.modelData.memory ?? 0)
                        font {
                            family: Appearance.font.family.numbers
                            variableAxes: Appearance.font.variableAxes.numbers
                            pixelSize: Appearance.font.pixelSize.smallie
                        }
                        color: row.isSelected ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                    }

                    StyledText {
                        Layout.preferredWidth: root.userWidth
                        Layout.leftMargin: 6
                        Layout.rightMargin: 6
                        text: row.modelData.user ?? ""
                        elide: Text.ElideRight
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                    }

                    StyledText {
                        Layout.preferredWidth: root.pidWidth
                        Layout.rightMargin: 6
                        horizontalAlignment: Text.AlignRight
                        text: String(row.modelData.pid ?? "")
                        font {
                            family: Appearance.font.family.numbers
                            variableAxes: Appearance.font.variableAxes.numbers
                            pixelSize: Appearance.font.pixelSize.smaller
                        }
                        color: Appearance.colors.colSubtext
                    }

                    // The per-row action, where the row is. Shown on hover or
                    // when the row is selected, so it never competes with the
                    // numbers for attention.
                    Item {
                        Layout.preferredWidth: root.actionWidth
                        implicitHeight: parent.height

                        RippleButton {
                            anchors.centerIn: parent
                            implicitWidth: 26
                            implicitHeight: 22
                            buttonRadius: Appearance.rounding.verysmall
                            visible: rowMouse.containsMouse || row.isSelected
                            colBackground: Appearance.colors.colErrorContainer
                            colBackgroundHover: Appearance.colors.colErrorContainerHover
                            onClicked: ProcessList.endTask(row.modelData.pids, row.modelData.name)
                            contentItem: MaterialSymbol {
                                anchors.centerIn: parent
                                text: "close"
                                iconSize: 14
                                color: Appearance.colors.colOnErrorContainer
                            }
                            StyledToolTip {
                                text: Translation.tr("End task")
                            }
                        }
                    }
                }
            }
        }

        StyledText {
            anchors.centerIn: parent
            visible: ProcessList.rows.length === 0
            text: ProcessList.query.length > 0
                ? Translation.tr("Nothing matches “%1”.").arg(ProcessList.query)
                : Translation.tr("Reading the process list…")
            font.pixelSize: Appearance.font.pixelSize.smallie
            color: Appearance.colors.colSubtext
        }
    }

    // ── Footer ───────────────────────────────────────────────────────────────
    RowLayout {
        Layout.fillWidth: true
        spacing: 10

        StyledText {
            // Grouped, the table is a list of applications and saying "243
            // processes" beside 150 rows reads as a bug; both numbers are true
            // and the label has to say which one it is counting.
            text: ProcessList.grouped
                ? Translation.tr("%1 processes in %2 applications").arg(ProcessList.count).arg(ProcessList.rows.length)
                : Translation.tr("%1 processes").arg(ProcessList.count)
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
        }
        StyledText {
            text: Translation.tr("%1 CPU").arg(ProcessList.totalCpu.toFixed(1) + "%")
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
        }
        StyledText {
            text: Translation.tr("%1 memory").arg(SystemFacts.bytes(ProcessList.totalMemory))
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
        }
        Item { Layout.fillWidth: true }
        StyledText {
            // Only when a search is narrowing the table: the count on the left is
            // the number of *processes*, and this is the number of rows that
            // survived the filter, which are different questions.
            visible: ProcessList.query.length > 0
            text: Translation.tr("%1 shown").arg(ProcessList.rows.length)
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
        }
    }
}
