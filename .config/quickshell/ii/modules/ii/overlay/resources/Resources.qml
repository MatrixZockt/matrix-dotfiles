pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.ii.overlay

/**
 * The task manager: what this machine is, what it is doing, and what is doing it.
 *
 * Three pages, because those are the three questions a task manager is opened to
 * answer, and they want different shapes:
 *
 *   * **Processes** -- a table. "Something is eating the machine" is answered by
 *     comparing rows, and only a table lines the numbers up to be compared.
 *   * **Performance** -- one device at a time, with a graph. "How hard has the
 *     disk been working" is a question about one number over time.
 *   * **Hardware** -- the specs. "What is this machine" is a page of facts, and
 *     facts want to be readable, not pretty.
 *
 * This used to be one page of three tabs (CPU / RAM / Swap) with graphs, which
 * showed a third of the machine and never said what any of it was. The tabs also
 * sat in pills far too round for the row of text inside them, so the highlight
 * never looked like it belonged to the label it was highlighting.
 *
 * Sampling is driven from here, not from the pages, because "is anybody looking"
 * is a question only this widget can answer: the process table costs a process of
 * its own to read, so it is only read while the page that draws it is the one on
 * screen, and both stop entirely when the card is neither open nor pinned.
 */
StyledOverlayWidget {
    id: root

    // Wide enough for the process table's six columns without any of them
    // squeezing, and for the performance page's device list beside its graph.
    minimumWidth: 820
    minimumHeight: 460

    title: Translation.tr("Task Manager")

    // ── Pages ────────────────────────────────────────────────────────────────
    readonly property var sections: [
        {
            key: "processes",
            name: Translation.tr("Processes"),
            icon: "list_alt",
            description: Translation.tr("Every program on the machine")
        },
        {
            key: "performance",
            name: Translation.tr("Performance"),
            icon: "monitoring",
            description: Translation.tr("One piece of hardware at a time")
        },
        {
            key: "hardware",
            name: Translation.tr("Hardware"),
            icon: "developer_board",
            description: Translation.tr("What this machine is")
        }
    ]

    // Persisted: which page you were last reading is a preference, not a
    // transient state, and reopening into the one you left is how every other
    // task manager behaves.
    property string section: Persistent.states.overlay.resources.section ?? "processes"

    function selectSection(key) {
        root.section = key;
        Persistent.states.overlay.resources.section = key;
    }

    readonly property int sectionIndex: Math.max(0, root.sections.findIndex(entry => entry.key === root.section))

    // One line of the rail's footer: a label and the number that goes with it.
    // Declared here rather than beside its use because an inline component is
    // file-scoped, and mixing declarations into a layout makes the layout harder
    // to read than the type is to find.
    component RailStat: RowLayout {
        id: railStat
        required property string label
        required property string value
        required property string icon
        spacing: 8

        MaterialSymbol {
            Layout.alignment: Qt.AlignVCenter
            text: railStat.icon
            iconSize: 15
            color: Appearance.colors.colSubtext
        }
        StyledText {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            text: railStat.label
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
        }
        StyledText {
            Layout.alignment: Qt.AlignVCenter
            text: railStat.value
            font {
                family: Appearance.font.family.numbers
                variableAxes: Appearance.font.variableAxes.numbers
                pixelSize: Appearance.font.pixelSize.smaller
            }
            color: Appearance.colors.colOnLayer1
        }
    }

    // ── Sampling ─────────────────────────────────────────────────────────────
    // "On screen" means the overlay is open (this card is one of the things it
    // shows) or the card is pinned to the desktop. A pinned card is still being
    // looked at, so it keeps being read; anything else costs nothing.
    readonly property bool onScreen: GlobalStates.overlayOpen || (root.pinned && root.open)

    function syncSampling() {
        HardwareStats.setActive("resources", root.onScreen);
        // The process table only runs while it is the page being shown: it is a
        // second interpreter starting up every couple of seconds, which is fine
        // to pay for the table you are reading and silly to pay for a page you
        // are not.
        ProcessList.setActive("resources", root.onScreen && root.section === "processes");
    }

    onOnScreenChanged: root.syncSampling()
    onPinnedChanged: root.syncSampling()
    onSectionChanged: root.syncSampling()
    Component.onCompleted: {
        root.syncSampling();
        root.applyRequestedDevice();
    }
    // The card is destroyed when the overlay closes with nothing pinned, so it has
    // to say so on the way out -- otherwise the last value (`true`) outlives it and
    // the readings carry on in the background for the rest of the session.
    Component.onDestruction: {
        HardwareStats.setActive("resources", false);
        ProcessList.setActive("resources", false);
    }
    Connections {
        target: GlobalStates
        function onOverlayOpenChanged() {
            root.syncSampling();
        }
    }

    // ── "Open the task manager on this piece of hardware" ────────────────────
    // The settings app's Overview tiles ask for this: clicking the RAM tile opens
    // the task manager *on the RAM*. A one-shot flag, cleared as it is applied,
    // so closing the card and reopening it from the launcher goes back to
    // remembering the last page instead of re-honouring an old click.
    function applyRequestedDevice() {
        const requested = OverlayContext.requestedDeviceKey ?? "";
        if (requested.length === 0)
            return;
        OverlayContext.requestedDeviceKey = "";
        root.selectSection("performance");
        performanceView.revealDevice(requested);
    }
    Connections {
        target: OverlayContext
        function onRequestedDeviceKeyChanged() {
            root.applyRequestedDevice();
        }
    }

    contentItem: OverlayBackground {
        id: contentItem
        radius: root.contentRadius

        // Ctrl+Tab walks the pages, the same way it does in the settings app:
        // the rail is right there, but a card you opened over a game should be
        // usable without aiming at it.
        focus: true
        Keys.onPressed: (event) => {
            if (event.modifiers !== Qt.ControlModifier)
                return;
            if (event.key === Qt.Key_Tab) {
                root.selectSection(root.sections[(root.sectionIndex + 1) % root.sections.length].key);
                event.accepted = true;
            }
            else if (event.key === Qt.Key_Backtab) {
                root.selectSection(root.sections[(root.sectionIndex - 1 + root.sections.length) % root.sections.length].key);
                event.accepted = true;
            }
        }

        RowLayout {
            anchors {
                fill: parent
                margins: 8
            }
            spacing: 8

            // ── Page rail ────────────────────────────────────────────────────
            ColumnLayout {
                Layout.fillHeight: true
                Layout.preferredWidth: 168
                spacing: 2

                Repeater {
                    model: root.sections
                    delegate: RippleButton {
                        id: sectionRow
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: 38
                        // A row highlight, not a pill: the smallest radius the
                        // theme has, and the button box *is* the row box, so the
                        // fill has exactly the icon and the label inside it.
                        buttonRadius: Appearance.rounding.verysmall
                        colBackground: "transparent"
                        colBackgroundHover: Appearance.colors.colLayer2Hover
                        colBackgroundToggled: Appearance.colors.colSecondaryContainer
                        colBackgroundToggledHover: Appearance.colors.colSecondaryContainerHover
                        toggled: root.section === sectionRow.modelData.key
                        onClicked: root.selectSection(sectionRow.modelData.key)

                        contentItem: RowLayout {
                            anchors {
                                fill: parent
                                leftMargin: 10
                                rightMargin: 10
                            }
                            spacing: 10

                            MaterialSymbol {
                                Layout.alignment: Qt.AlignVCenter
                                text: sectionRow.modelData.icon
                                iconSize: 18
                                color: sectionRow.toggled ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                            }
                            StyledText {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignVCenter
                                text: sectionRow.modelData.name
                                elide: Text.ElideRight
                                font.pixelSize: Appearance.font.pixelSize.smallie
                                color: sectionRow.toggled ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                            }
                        }

                        StyledToolTip {
                            text: sectionRow.modelData.description
                        }
                    }
                }

                // A horizontal rule, then the two numbers that are the reason
                // this card gets opened at all, so the rail is useful even while
                // you are reading a different page.
                Rectangle {
                    Layout.fillWidth: true
                    Layout.topMargin: 6
                    Layout.bottomMargin: 6
                    implicitHeight: 1
                    color: Appearance.colors.colOutlineVariant
                }

                RailStat {
                    Layout.fillWidth: true
                    Layout.leftMargin: 10
                    Layout.rightMargin: 10
                    icon: "planner_review"
                    label: Translation.tr("CPU")
                    value: (ResourceUsage.cpuUsage * 100).toFixed(0) + "%"
                }
                RailStat {
                    Layout.fillWidth: true
                    Layout.leftMargin: 10
                    Layout.rightMargin: 10
                    icon: "memory"
                    label: Translation.tr("RAM")
                    value: (ResourceUsage.memoryUsedPercentage * 100).toFixed(0) + "%"
                }
                RailStat {
                    Layout.fillWidth: true
                    Layout.leftMargin: 10
                    Layout.rightMargin: 10
                    icon: "spoke"
                    label: Translation.tr("Tasks")
                    value: String(ProcessList.count)
                }

                Item { Layout.fillHeight: true }
            }

            Rectangle {
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                color: Appearance.colors.colOutlineVariant
            }

            // ── The page ─────────────────────────────────────────────────────
            // A StackLayout rather than a Loader: all three pages stay alive, so
            // switching between them is instant and "open the task manager on the
            // RAM" can reach the performance page before it has ever been shown.
            // What is *sampled* is still decided by `syncSampling` above, which is
            // where the cost was in the first place.
            StackLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                currentIndex: root.sectionIndex

                ProcessesView { id: processesView }
                PerformanceView { id: performanceView }
                HardwareView { id: hardwareView }
            }
        }
    }
}
