import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/**
 * The Ports tab: every TCP/UDP port bound on this machine, live or saved,
 * with search, start / stop / delete at hand. The list comes from
 * PortManager (scripts/system/ports.py does the ss parsing and the
 * lifecycle); the tab is its face: search field, cards, the add form,
 * and the toast.
 *
 * Delete is the loud one and says so: it kills the process AND removes
 * the systemd user unit that created the port, so it cannot come back at
 * the next login. A confirm state on the button (one click arms it, the
 * second click commits, moving away disarms) keeps a mis-click from
 * tearing a service down.
 *
 * Look: the theme's dark grey surfaces with a muted neutral ochre accent
 * instead of the stock blue/green. The accent touches only the running pill
 * and the Start/Save buttons; the chip, spine and everything else stays
 * neutral surface colours so the list stays calm.
 */
Rectangle {
    id: root

    // ── The accent ─────────────────────────────────────────────────────
    // Muted neutral ochre — the quiet design (B). No loud gold anywhere.
    // The accent only touches the running pill and the Start/Save buttons;
    // the chip, spine and buttons stay neutral surface colours so the
    // list stays calm.
    readonly property color accent: "#B08D57"
    readonly property color accentSoft: "#9C7A50"
    readonly property color accentOn: "#2A2218"

    radius: Appearance.rounding.normal
    color: Appearance.colors.colLayer1
    clip: true

    Component.onCompleted: PortManager.startPolling()
    Component.onDestruction: PortManager.stopPolling()

    // The list, one entry per (port, proto): scan rows come grouped by the
    // script already; dedupe live rows that share a port across addresses,
    // keeping the first bound one (they are the same service on 0.0.0.0/::).
    readonly property var rows: {
        const byKey = {};
        const order = [];
        for (const row of PortManager.ports) {
            const key = `${row.proto}:${row.port}`;
            if (byKey[key] !== undefined) {
                const prev = byKey[key];
                if (row.bound && !prev.bound)
                    byKey[key] = row;
                else if (row.bound && prev.bound && !prev.name && row.name)
                    byKey[key] = row;
                continue;
            }
            byKey[key] = row;
            order.push(key);
        }
        // Live first (busier half of the list), then saved-stopped.
        return order
            .map(k => byKey[k])
            .sort((a, b) => (b.bound - a.bound) || (a.port - b.port));
    }

    // The search: one lowercase needle, matched (wildcard-tolerant) against
    // everything a row can say — port number, name, command, address,
    // protocol, state. Substring, case-insensitive, and a best-effort
    // edit-distance so a typo still finds the right row.
    readonly property string query: searchField.text.trim().toLowerCase()
    // Wildcard-tolerant match for one term: its characters must appear in
    // the field in order (subsequence — separators inside the field are
    // skipped for free), but a few may be wrong or missing, so a typo does
    // not blank the list. The budget grows with term length: 0 typos for
    // 1-2 chars, 1 for 3-4, 2 for 5+. An empty field never matches.
    readonly property var fuzzyIncludes: (hay, needle) => {
        const h = (hay || "").toLowerCase();
        if (h.length === 0 || needle.length === 0) return false;
        const maxTypos = needle.length >= 5 ? 2 : needle.length >= 3 ? 1 : 0;
        let typos = 0;
        let hi = 0;
        for (let ni = 0; ni < needle.length; ni++) {
            const ch = needle[ni];
            const start = hi;
            let found = false;
            for (; hi < h.length; hi++) {
                if (h[hi] === ch) { hi++; found = true; break; }
            }
            if (!found) {
                // Typo: this needle character is wrong or extra. Put the
                // haystack cursor back — later characters may still match.
                hi = start;
                if (++typos > maxTypos) return false;
            }
        }
        return true;
    }
    readonly property var visibleRows: {
        const all = root.rows;
        const q = root.query;
        if (q.length === 0)
            return all;
        // Space-separated terms are ANDed; each term may hit any field.
        const terms = q.split(" ").filter(t => t.length > 0);
        return all.filter(r => {
            const fields = [
                String(r.port),
                r.name || "",
                r.command || "",
                r.ip || "",
                r.proto || "",
                r.bound ? "running" : "stopped",
            ];
            return terms.every(t => fields.some(f => fuzzyIncludes(f, t)));
        });
    }

    ColumnLayout {
        id: column
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        // ── Header ─────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            MaterialSymbol {
                text: "lan"
                iconSize: 20
                color: root.accent
            }
            StyledText {
                Layout.fillWidth: true
                text: Translation.tr("Ports")
                font.pixelSize: Appearance.font.pixelSize.large
                font.weight: Font.DemiBold
            }
            StyledText {
                text: `${root.rows.filter(r => r.bound).length} ${Translation.tr("live")}`
                color: Appearance.colors.colSubtext
            }
            RippleButton {
                implicitWidth: 30
                implicitHeight: 30
                buttonRadius: Appearance.rounding.full
                colBackground: Appearance.colors.colSurfaceContainerLow
                colBackgroundHover: Appearance.colors.colSurfaceContainerHigh
                onClicked: PortManager.refresh()
                MaterialSymbol {
                    anchors.centerIn: parent
                    text: PortManager.scanning ? "progress_activity" : "refresh"
                    iconSize: 16
                    color: Appearance.colors.colOnSurface
                    RotationAnimator on rotation {
                        from: 0
                        to: 360
                        duration: 1000
                        loops: Animation.Infinite
                        running: PortManager.scanning === true
                    }
                }
            }
        }

        // ── Search ─────────────────────────────────────────────────────
        // Quiet neutral field. The accent only lives in the running pill
        // and the Start/Save buttons; the field itself stays neutral.
        TextField {
            id: searchField
            Layout.fillWidth: true
            implicitHeight: 34
            color: Appearance.colors.colOnSurface
            placeholderText: Translation.tr("Search port, name, command…")
            placeholderTextColor: Appearance.colors.colSubtext
            selectedTextColor: Appearance.m3colors.m3onSecondaryContainer
            selectionColor: Appearance.colors.colSecondaryContainer
            verticalAlignment: TextInput.AlignVCenter
            leftPadding: 34
            rightPadding: searchClear.visible ? 32 : 12
            font.family: Appearance.font.family.main
            font.pixelSize: Appearance.font.pixelSize.small

            background: Rectangle {
                radius: Appearance.rounding.full
                color: Appearance.colors.colSurfaceContainerLow
                border.width: 1
                border.color: searchField.activeFocus
                    ? root.goldDim
                    : Appearance.colors.colOutlineVariant
            }

            MaterialSymbol {
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: "search"
                iconSize: 16
                color: root.query.length > 0 ? root.accent : Appearance.colors.colSubtext
            }
            // Clear ("x"): only while there is something to clear.
            Item {
                id: searchClear
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: 24
                implicitHeight: 24
                visible: searchField.text.length > 0
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        searchField.clear();
                        searchField.forceActiveFocus();
                    }
                }
                MaterialSymbol {
                    anchors.centerIn: parent
                    text: "close"
                    iconSize: 13
                    color: Appearance.colors.colSubtext
                }
            }
        }

        // ── Add a port ─────────────────────────────────────────────────
        CollapsibleContentSection {
            Layout.fillWidth: true
            title: Translation.tr("Add a port")
            icon: "add_circle"
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    MaterialTextField {
                        id: addPortField
                        Layout.preferredWidth: 90
                        placeholderText: Translation.tr("Port")
                        validator: IntValidator { bottom: 1; top: 65535 }
                    }
                    ComboBox {
                        id: addProto
                        model: ["tcp", "udp"]
                        Layout.preferredWidth: 90
                    }
                    MaterialTextField {
                        id: addName
                        Layout.fillWidth: true
                        placeholderText: Translation.tr("Name (optional)")
                    }
                }
                MaterialTextField {
                    id: addCommand
                    Layout.fillWidth: true
                    placeholderText: Translation.tr("Start command (e.g. python3 -m http.server 8000)")
                }
                RippleButton {
                    Layout.fillWidth: true
                    implicitHeight: 30
                    buttonRadius: Appearance.rounding.full
                    colBackground: root.accent
                    colBackgroundHover: root.accentSoft
                    onClicked: {
                        const p = parseInt(addPortField.text);
                        if (!(p >= 1 && p <= 65535) || addCommand.text.trim().length === 0)
                            return;
                        PortManager.savePort(p, addProto.currentText,
                            addName.text.trim() || `Port ${p}`,
                            addCommand.text.trim());
                        addPortField.text = "";
                        addName.text = "";
                        addCommand.text = "";
                    }
                    StyledText {
                        anchors.centerIn: parent
                        text: Translation.tr("Save — starts stopped")
                        font.weight: Font.DemiBold
                        color: root.accentOn
                    }
                }
            }
        }

        // ── The list ───────────────────────────────────────────────────
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            StyledListView {
                id: list
                anchors.fill: parent
                spacing: 6
                clip: true
                model: root.visibleRows

                delegate: Rectangle {
                    id: card
                    required property var modelData
                    readonly property bool bound: modelData.bound
                    readonly property int port: modelData.port

                    width: list.width
                    height: cardContent.implicitHeight + 20
                    radius: Appearance.rounding.normal
                    // A quiet card: flat dark surface, hairline border that does
                    // not warm up on hover — the accent lives only in the pill.
                    color: Appearance.colors.colSurfaceContainerLow
                    border.width: 1
                    border.color: Appearance.colors.colOutlineVariant

                    MouseArea {
                        id: cardMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.NoButton
                    }

                    // No accent spine. State is shown by the RUNNING pill only.

                    ColumnLayout {
                        id: cardContent
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 4

                        // Line 1: chip, name, state, proto
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            Rectangle {
                                implicitWidth: 54
                                implicitHeight: 22
                                radius: Appearance.rounding.full
                                color: Appearance.colors.colSurfaceContainerHigh
                                StyledText {
                                    anchors.centerIn: parent
                                    text: String(card.port)
                                    font.pixelSize: Appearance.font.pixelSize.small
                                    font.weight: Font.DemiBold
                                    color: root.accent
                                }
                            }
                            StyledText {
                                Layout.fillWidth: true
                                text: card.bound
                                    ? (modelData.name || Translation.tr("unknown process"))
                                    : (modelData.command
                                        ? (modelData.name || Translation.tr("saved listener"))
                                        : Translation.tr("stopped"))
                                elide: Text.ElideRight
                                color: Appearance.colors.colOnSurface
                            }
                            StyledText {
                                font.pixelSize: Appearance.font.pixelSize.tiny
                                font.weight: Font.DemiBold
                                font.letterSpacing: 0.8
                                text: card.bound ? Translation.tr("RUNNING") : Translation.tr("STOPPED")
                                color: card.bound ? root.accent : Appearance.colors.colSubtext
                            }
                            StyledText {
                                text: modelData.proto
                                font.pixelSize: Appearance.font.pixelSize.tiny
                                font.letterSpacing: 0.8
                                color: Appearance.colors.colSubtext
                            }
                        }

                        // Line 2: detail (pid/ip or the saved command)
                        StyledText {
                            Layout.fillWidth: true
                            visible: text.length > 0
                            text: {
                                if (card.bound)
                                    return (modelData.pid ? `pid ${modelData.pid} · ` : "")
                                        + modelData.ip;
                                if (modelData.command)
                                    return modelData.command;
                                return "";
                            }
                            elide: Text.ElideMiddle
                            font.pixelSize: Appearance.font.pixelSize.tiny
                            color: Appearance.colors.colSubtext
                        }

                        // Line 3: the actions
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            // Start (saved, stopped ports only) — the one
                            // accent button; starting is the point.
                            RippleButton {
                                visible: !card.bound && modelData.command
                                implicitHeight: 26
                                implicitWidth: 74
                                buttonRadius: Appearance.rounding.full
                                colBackground: root.accent
                                colBackgroundHover: root.accentSoft
                                onClicked: PortManager.startPort(card.port)
                                StyledText {
                                    anchors.centerIn: parent
                                    text: Translation.tr("Start")
                                    font.weight: Font.DemiBold
                                    color: root.accentOn
                                }
                            }

                            // Stop (live ports only)
                            RippleButton {
                                visible: card.bound
                                implicitHeight: 26
                                implicitWidth: 74
                                buttonRadius: Appearance.rounding.full
                                colBackground: Appearance.colors.colSurfaceContainerHighest
                                colBackgroundHover: Appearance.colors.colOutlineVariant
                                onClicked: PortManager.stopPort(card.port)
                                StyledText {
                                    anchors.centerIn: parent
                                    text: Translation.tr("Stop")
                                    color: Appearance.colors.colOnSurface
                                }
                            }

                            Item { Layout.fillWidth: true }

                            // Delete: armed on first click, commits on the second.
                            // Foreign ports (a browser's mDNS socket, systemd-
                            // resolved's DNS stub) are NOT ours to delete -- the
                            // button offers Forget instead, which only drops the
                            // saved record.
                            RippleButton {
                                readonly property bool foreign: !modelData.managed
                                readonly property bool armed: deleteArm.armFor === card.port
                                implicitHeight: 26
                                implicitWidth: armed ? 86 : (foreign ? 74 : 86)
                                buttonRadius: Appearance.rounding.full
                                colBackground: armed
                                    ? Appearance.m3colors.m3error
                                    : Appearance.colors.colSurfaceContainerHigh
                                colBackgroundHover: armed
                                    ? Appearance.m3colors.m3error
                                    : Appearance.colors.colSurfaceContainerHighest
                                onClicked: {
                                    if (foreign) {
                                        if (modelData.managed)
                                            return;
                                        PortManager.forgetPort(card.port);
                                        return;
                                    }
                                    if (deleteArm.armFor !== card.port) {
                                        deleteArm.armFor = card.port;
                                        deleteArm.restart();
                                    } else {
                                        deleteArm.armFor = -1;
                                        PortManager.deletePort(card.port);
                                    }
                                }
                                StyledText {
                                    anchors.centerIn: parent
                                    text: {
                                        if (card.armed)
                                            return Translation.tr("Confirm?");
                                        return card.foreign
                                            ? Translation.tr("Forget")
                                            : Translation.tr("Delete");
                                    }
                                    color: card.armed
                                        ? Appearance.colors.colOnError
                                        : Appearance.colors.colOnSurfaceVariant
                                }
                            }
                        }
                    }
                }
            }

            // Empty state: either the search found nothing or the machine
            // simply has no ports to show.
            StyledText {
                anchors.centerIn: parent
                visible: root.visibleRows.length === 0
                text: root.query.length > 0
                    ? Translation.tr("No ports match your search")
                    : Translation.tr("No ports found — refresh or add one")
                color: Appearance.colors.colSubtext
            }
        }

        // The toast: the last action's result, fading on its own.
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: toastText.implicitHeight + 14
            radius: Appearance.rounding.small
            color: Appearance.colors.colSurfaceContainerHighest
            visible: PortManager.lastAction.length > 0
            StyledText {
                id: toastText
                anchors.centerIn: parent
                text: PortManager.lastAction
                font.pixelSize: Appearance.font.pixelSize.tiny
                color: Appearance.colors.colOnSurfaceVariant
            }
            Timer {
                interval: 2600
                running: visible
                onTriggered: PortManager.lastAction = ""
            }
        }
    }

    // The armed-delete reset: any armed button disarms itself after a few
    // seconds, so a half-made decision does not linger.
    Timer {
        id: deleteArm
        property int armFor: -1
        interval: 3000
        onTriggered: armFor = -1
    }
}
