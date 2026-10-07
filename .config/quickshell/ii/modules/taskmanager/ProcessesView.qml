pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.services
import qs.modules.common
import qs.modules.common.widgets

/**
 * The process table: every program on the machine, sorted, searchable, and
 * endable. The task manager's Apps and Processes pages.
 *
 * It is deliberately a table and not a list of cards. A task manager is read
 * by comparing rows -- which of these is the one eating the processor -- and
 * a table is the only shape where the numbers line up under each other, so
 * the eye can do that without reading anything.
 *
 * Two things are borrowed from the task manager everybody already knows: rows
 * fold into one row per application (see ProcessList.grouped -- the Apps
 * view), and ending a task is offered on the row itself, where the process
 * you want to end is, rather than in a menu somewhere else that needs the row
 * selected first.
 *
 * Columns are fixed-width on purpose. A table whose columns resize themselves
 * to their contents has a different column boundary on every screen and grows
 * a different header each time the numbers change width; fixed widths plus
 * one flexible name column means the header is the ruler for every row below
 * it.
 */
ColumnLayout {
    id: root
    spacing: 8

    // Apps page = grouped by application (the way Windows' first tab reads);
    // Processes page = flat. The page the host is showing picks the mode.
    property bool groupedByApp: true

    onGroupedByAppChanged: {
        ProcessList.grouped = groupedByApp;
        ProcessList.collapseAll();
        // The two pages number their rows differently -- "app:brave" exists on
        // the Apps page and not on the flat one -- so a selection made on the
        // other page has nothing to point at. Clear it rather than leave the
        // highlight on whichever row happens to sort into that slot.
        root.selectedKey = "";
    }
    Component.onCompleted: {
        ProcessList.grouped = groupedByApp;
        // A fresh page, not the overlay continuing an old session.
        ProcessList.query = "";
        // setSort TOGGLES when handed the key it is already on, so calling it
        // with "cpu" on a config whose saved sort is cpu silently flipped the
        // table to ascending. Only set it when it is actually different.
        if (ProcessList.sortKey !== "cpu")
            ProcessList.setSort("cpu");
    }

    // Which row is selected, by its own key -- "app:firefox", "pid:1234". Kept
    // as the key rather than the row object so that a sample landing mid-click
    // cannot leave the selection pointing at a row that no longer exists.
    property string selectedKey: ""

    // The key the pointer is over, so a row can show its cross without being
    // the selected one. Kept off `selectedKey` on purpose: hovering is not
    // choosing, and the End task button must follow the SELECTION.
    property string hoverKey: ""

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
    readonly property int actionWidth: 64

    function rowIcon(row) {
        if (row.kind === "group")
            return "apps";
        return row.user === "root" ? "terminal" : "deployed_code";
    }

    // The icon PATH for a row's group, or "" when there is none.
    //
    // This function went missing: three call sites below still called
    // `root.iconFor(...)` after it was renamed, so every one of them threw
    // `TypeError: Property 'iconFor' ... is not a function` on every row, on
    // every repaint. That is the wrong/missing icons in the task list, and it
    // was firing ~46 times per line per launch.
    //
    // It is not `rowIcon()`. rowIcon returns a MATERIAL SYMBOL NAME ("apps",
    // "terminal"), which is what the MaterialSymbol below paints from. This
    // one has to return a filesystem path, because it feeds an AppIcon's
    // `source` -- handing that a symbol name is why the group rows looked
    // wrong rather than merely empty. Same shape as DesktopOverview.iconFor.
    function iconFor(row) {
        if (!row || row.kind !== "group")
            return "";
        // The SERVICE's cache, not a fresh resolve per delegate: the row
        // model is rebuilt every sample, so this binding re-runs for every
        // visible group each time. ProcessList.iconFor memoizes by name.
        return ProcessList.iconFor(row) ?? "";
    }

    // Windows-open classes, for the section split. The service rebuilds the
    // set per revision, so this reads it per revision too.
    // Windows-open classes, for the section split. The service owns the
    // matching (normalization included) -- the view only asks.
    function rowSection(row) {
        if (row.kind !== "group")
            return "apps";
        return ProcessList.isWindowed(row.name) ? "apps" : "advanced";
    }

    // True when this row is the FIRST "advanced" row in the table: exactly
    // one divider is inserted there.
    function isAdvancedDivider(index) {
        if (index === 0) return false;
        const prev = ProcessList.rows[index - 1];
        const cur = ProcessList.rows[index];
        return cur && prev && rowSection(cur) === "advanced" && rowSection(prev) === "apps";
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
        if (force)
            ProcessList.forceKill(row.pids, row.name);
        else
            ProcessList.endTask(row.pids, row.name);
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
            // The width reads the whole row, not just the text: the label
            // used to measure itself alone and the button clip its icon+text
            // row -- "End tas". Text + icon + symmetric padding fits with
            // room to spare.
            implicitWidth: endTaskRow.implicitWidth + 24
            buttonRadius: Appearance.rounding.small
            colBackground: root.selectedRow !== null ? Appearance.colors.colErrorContainer : Appearance.colors.colLayer1
            colBackgroundHover: root.selectedRow !== null ? Appearance.colors.colErrorContainerHover : Appearance.colors.colLayer1Hover
            onClicked: root.endSelected()
            contentItem: RowLayout {
                id: endTaskRow
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
            label: root.groupedByApp
                ? Translation.tr("Applications (%1 + %2 advanced)").arg(root.applicationsCount).arg(root.advancedCount)
                : Translation.tr("Name")
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

    // Section split for the header + divider. Computed from rows once per
    // revision; "apps" = a window is open for that application right now.
    readonly property int applicationsCount: {
        const _ = ProcessList.revision;
        let n = 0;
        for (const row of ProcessList.rows)
            if (root.rowSection(row) === "apps" && row.kind === "group") n++;
        return n;
    }
    readonly property int advancedCount: {
        const _ = ProcessList.revision;
        let n = 0;
        for (const row of ProcessList.rows)
            if (root.rowSection(row) === "advanced" && row.kind === "group") n++;
        return n;
    }

    // ── The table ────────────────────────────────────────────────────────
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
            //
            // currentIndex is NOT the selection. It used to be, and that was the
            // bug: `ProcessList.rows` is a fresh array on every sample (~2s), so
            // the ListView reset currentIndex to a clamped/stale value mid-
            // gesture, and the handler below wrote THAT row's key over the
            // selection -- the row you clicked silently became some other row,
            // then the next sample did it again. `selectedKey` is the single
            // source of truth; currentIndex only exists to scroll a row into
            // view, and is never read back.
            currentIndex: -1
            function selectKey(key) {
                root.selectedKey = key;
                const at = ProcessList.rows.findIndex(row => row.key === key);
                if (at >= 0) {
                    table.currentIndex = at;
                    table.positionViewAtIndex(at, ListView.Contain);
                }
            }
            function stepSelection(delta) {
                const rows = ProcessList.rows;
                // Step over the divider. It is not a row of its own -- an
                // ordinary process row is RENDERED as the caption when it sits
                // at the top of the advanced section -- so it is found by the
                // same predicate the delegate uses, not by a `kind`.
                let at = rows.findIndex(row => row.key === root.selectedKey);
                if (at < 0)
                    at = delta > 0 ? -1 : rows.length;
                for (let i = at + delta; i >= 0 && i < rows.length; i += delta) {
                    if (root.isAdvancedDivider(i))
                        continue;
                    table.selectKey(rows[i].key);
                    return true;
                }
                return false;
            }
            // Home/End: the first/last row that is not a divider caption.
            function selectEdge(dir) {
                const rows = ProcessList.rows;
                for (let i = dir > 0 ? 0 : rows.length - 1; i >= 0 && i < rows.length; i += dir) {
                    if (root.isAdvancedDivider(i))
                        continue;
                    table.selectKey(rows[i].key);
                    return true;
                }
                return false;
            }
            Keys.onPressed: (event) => {
                if (event.key === Qt.Key_Delete)
                    root.endSelected();
                else if (event.key === Qt.Key_Escape)
                    root.selectedKey = "";
                else if (event.key === Qt.Key_Up) {
                    table.stepSelection(-1);
                } else if (event.key === Qt.Key_Down) {
                    table.stepSelection(1);
                } else if (event.key === Qt.Key_PageUp) {
                    table.stepSelection(-10);
                } else if (event.key === Qt.Key_PageDown) {
                    table.stepSelection(10);
                } else if (event.key === Qt.Key_Home) {
                    table.selectEdge(1);
                } else if (event.key === Qt.Key_End) {
                    table.selectEdge(-1);
                } else
                    return;
                event.accepted = true;
            }
            readonly property var rows0: ProcessList.rows
            // Referenced only so the table re-reads rows when a sample lands;
            // the selection itself lives in root.selectedKey and needs no help.
            onRows0Changed: if (root.selectedKey !== "")
                table.currentIndex = table.rows0.findIndex(row => row.key === root.selectedKey)

            delegate: Rectangle {
                id: row
                required property var modelData
                required property int index

                readonly property bool isGroup: row.modelData.kind === "group"
                readonly property bool isSelected: root.selectedKey === row.modelData.key
                readonly property bool isDivider: root.isAdvancedDivider(row.index)

                width: table.width
                // Divider rows sit on top of the split; real rows are the
                // roomy 34px strips. The divider is NOT clickable.
                height: row.isDivider ? 30 : 34
                radius: Appearance.rounding.verysmall
                color: row.isDivider ? Appearance.colors.colLayer2 : row.isSelected ? Appearance.colors.colSecondaryContainer
                    : rowMouse.containsMouse ? Appearance.colors.colLayer2Hover
                    : "transparent"

                MouseArea {
                    id: rowMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: !row.isDivider
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onEntered: root.hoverKey = row.modelData.key
                    onExited: if (root.hoverKey === row.modelData.key) root.hoverKey = ""
                    onClicked: (event) => {
                        if (event.button === Qt.RightButton) {
                            // Right-click opens the row's properties menu --
                            // the same actions the toolbar carries, at the row
                            // itself. (It used to force-kill INSTANTLY, which
                            // was exactly as dangerous as it sounds: one
                            // stray right-click ended the task with no save
                            // prompts and no undo. The force-kill is still
                            // here, one deliberate menu item deeper.)
                            table.selectKey(row.modelData.key);
                            rowMenu.openFor(row.modelData, rowMouse);
                            return;
                        }
                        // ONE click, ONE job: select. It used to also fold the
                        // group open, which meant clicking an app to select it
                        // moved every row below it and lost the selection you
                        // just made. Folding is on the chevron now.
                        table.selectKey(row.modelData.key);
                    }
                }

                RowLayout {
                    anchors {
                        fill: parent
                        leftMargin: 4
                        rightMargin: 2
                    }
                    spacing: 0

                    // The name column: indent, disclosure, icon, label. A
                    // group whose desktop entry resolves shows its REAL app
                    // icon -- the instantly-recognizable kind -- with the
                    // Material glyph only as fallback.
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: row.isGroup ? 0 : 18
                        spacing: 6

                        Item {
                            visible: row.isGroup
                            Layout.leftMargin: 2
                            implicitWidth: 16
                            implicitHeight: row.height

                            MaterialSymbol {
                                anchors.centerIn: parent
                                text: row.modelData.expanded ? "expand_more" : "chevron_right"
                                iconSize: 16
                                color: chevronMouse.containsMouse ? Appearance.colors.colOnLayer1 : Appearance.colors.colSubtext
                            }
                            // The chevron is the only thing that folds a group.
                            // Its own hit area, wider than the glyph, because a
                            // 16px target is a 16px miss.
                            MouseArea {
                                id: chevronMouse
                                anchors.fill: parent
                                anchors.margins: -5
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    table.selectKey(row.modelData.key);
                                    ProcessList.toggleGroup(row.modelData.name);
                                }
                            }
                        }
                        AppIcon {
                            visible: row.isGroup && root.iconFor(row.modelData) !== ""
                            source: root.iconFor(row.modelData)
                            implicitSize: 17
                            animated: false
                        }
                        MaterialSymbol {
                            visible: !(row.isGroup && root.iconFor(row.modelData) !== "")
                            text: root.rowIcon(row.modelData)
                            iconSize: 15
                            color: row.isSelected ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                        }
                        StyledText {
                            Layout.fillWidth: true
                            text: {
                                const count = row.modelData.count ?? 0;
                                if (row.isDivider)
                                    return Translation.tr("Advanced — background processes (%1)").arg(root.advancedCount);
                                if (row.isGroup && count > 1)
                                    return `${row.modelData.name} (${count})`;
                                return row.modelData.name ?? "";
                            }
                            elide: Text.ElideRight
                            font.pixelSize: Appearance.font.pixelSize.smallie
                            color: row.isDivider ? Appearance.colors.colSubtext : row.isSelected ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                        }
                    }

                    StyledText {
                        Layout.preferredWidth: root.statusWidth
                        Layout.leftMargin: 6
                        Layout.rightMargin: 6
                        visible: !row.isDivider
                        text: row.isGroup ? "" : root.stateLabel(row.modelData.state)
                        elide: Text.ElideRight
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                    }

                    StyledText {
                        Layout.preferredWidth: root.cpuWidth
                        Layout.rightMargin: 6
                        visible: !row.isDivider
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
                        visible: !row.isDivider
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
                        visible: !row.isDivider
                        text: row.modelData.user ?? ""
                        elide: Text.ElideRight
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                    }

                    StyledText {
                        Layout.preferredWidth: root.pidWidth
                        Layout.rightMargin: 6
                        visible: !row.isDivider
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
                    // when the row is selected. The X itself carries the
                    // colour -- red icon on a quiet hover-circle -- so the
                    // table stays calm and the destructive affordance still
                    // reads at a glance; the old red BOX per row made the
                    // whole list look like a wall of alerts.
                    Item {
                        Layout.preferredWidth: root.actionWidth
                        implicitHeight: parent.height

                        Row {
                            anchors.centerIn: parent
                            spacing: 2

                        RippleButton {
                            id: rowClose
                            implicitWidth: 26
                            implicitHeight: 22
                            buttonRadius: Appearance.rounding.verysmall
                            // Always there on a real row. It used to appear only
                            // on hover, which is the wrong time to introduce a
                            // target: by the time the pointer has travelled to
                            // where the X was, the row it belonged to may be a
                            // different row -- or the rows may have re-sorted
                            // under it between frames, and the click lands on
                            // whatever process is there now. A permanent,
                            // correctly-placed target cannot do that. The
                            // divider is a caption and gets none.
                            visible: !row.isDivider
                            // Quiet red X normally, tinted chip under the
                            // pointer -- RippleButton tracks its own hover
                            // in `hovered`.
                            colBackground: "transparent"
                            colBackgroundHover: Appearance.colors.colErrorContainer
                            onClicked: {
                                // Select first, so the toolbar's End task and
                                // this row's X can never disagree about what is
                                // about to be ended.
                                table.selectKey(row.modelData.key);
                                ProcessList.endTask(row.modelData.pids, row.modelData.name);
                            }
                            contentItem: MaterialSymbol {
                                anchors.centerIn: parent
                                text: "close"
                                iconSize: 14
                                color: rowClose.hovered
                                    ? Appearance.colors.colOnErrorContainer
                                    : Appearance.colors.colError
                            }
                            StyledToolTip {
                                text: Translation.tr("End task")
                            }
                        }

                        // FORCE kill, per row.
                        //
                        // This used to live only in the right-click menu, one
                        // level deeper than most people ever go -- so "force
                        // close" was something the app had and the user could
                        // not find. It sits beside the graceful X now, on every
                        // real row, and does the one thing a task manager
                        // exists to do: end exactly this process, now.
                        //
                        // Deliberately the SIGKILL path and nothing more: no
                        // confirmation dialog, because the target is the row
                        // the pointer is on and a dialog for a two-pixel button
                        // is just an obstacle. The hover state is the warning.
                        RippleButton {
                            id: rowForce
                            implicitWidth: 26
                            implicitHeight: 22
                            buttonRadius: Appearance.rounding.verysmall
                            visible: !row.isDivider
                            colBackground: "transparent"
                            colBackgroundHover: Appearance.colors.colError
                            onClicked: {
                                table.selectKey(row.modelData.key);
                                ProcessList.forceKill(row.modelData.pids, row.modelData.name);
                            }
                            contentItem: MaterialSymbol {
                                anchors.centerIn: parent
                                text: "power_settings_new"
                                iconSize: 14
                                color: rowForce.hovered
                                    ? Appearance.colors.colOnErrorContainer
                                    : Appearance.colors.colError
                            }
                            StyledToolTip {
                                text: Translation.tr("Force kill this process now")
                            }
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

    // ── The row properties menu ──────────────────────────────────────────────
    // A small anchored popup with the row's actions. Lives at the root of the
    // view (one instance, re-aimed per open) so the table does not grow a
    // popup per row. `openFor` aims it under the cursor row; Escape or a
    // click elsewhere closes it.
    PopupWindow {
        id: rowMenu
        visible: false
        anchor {
            window: root.QsWindow.window
            adjustment: PopupAdjustment.Flip | PopupAdjustment.SlideX | PopupAdjustment.SlideY
        }
        implicitWidth: 210
        implicitHeight: menuColumn.implicitHeight + 12
        color: "transparent"

        property var target: null
        function openFor(modelData, mouse) {
            rowMenu.target = modelData;
            anchor.item = mouse;
            anchor.edges = Edges.Bottom;
            anchor.gravity = Edges.Bottom;
            visible = true;
        }

        Rectangle {
            anchors.fill: parent
            radius: Appearance.rounding.normal
            color: Appearance.colors.colLayer1
            border.width: 1
            border.color: Appearance.colors.colLayer0Border

            ColumnLayout {
                id: menuColumn
                anchors.fill: parent
                anchors.margins: 6
                spacing: 0

                component MenuRow: RippleButton {
                    id: menuAction
                    property string iconGlyph: ""
                    property string label: ""
                    property color labelColor: Appearance.colors.colOnLayer1
                    property var run: null
                    Layout.fillWidth: true
                    implicitHeight: 32
                    buttonRadius: Appearance.rounding.verysmall
                    colBackground: "transparent"
                    colBackgroundHover: Appearance.colors.colLayer1Hover
                    colRipple: Appearance.colors.colLayer1Active
                    onClicked: {
                        rowMenu.visible = false;
                        if (menuAction.run) menuAction.run();
                    }
                    contentItem: RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 8
                        MaterialSymbol {
                            text: menuAction.iconGlyph
                            iconSize: 15
                            color: menuAction.labelColor
                        }
                        StyledText {
                            text: menuAction.label
                            font.pixelSize: Appearance.font.pixelSize.small
                            color: menuAction.labelColor
                        }
                    }
                }

                MenuRow {
                    iconGlyph: "close"
                    label: Translation.tr("End task")
                    labelColor: Appearance.colors.colError
                    run: () => ProcessList.endTask(rowMenu.target?.pids ?? [], rowMenu.target?.name ?? "")
                }
                MenuRow {
                    iconGlyph: "dangerous"
                    label: Translation.tr("Force kill")
                    labelColor: Appearance.colors.colError
                    run: () => ProcessList.forceKill(rowMenu.target?.pids ?? [], rowMenu.target?.name ?? "")
                }
                MenuRow {
                    iconGlyph: "content_copy"
                    label: Translation.tr("Copy name")
                    run: () => Quickshell.clipboardText = String(rowMenu.target?.name ?? "")
                }
            }
        }
    }
}
