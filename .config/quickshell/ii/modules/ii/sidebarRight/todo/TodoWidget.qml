import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// To Do, rebuilt for speed of use.
//
// The old shape was a floating action button that opened a modal dialog:
// click FAB, wait for the scrim, click the field, type, click Add, click
// through the scrim to get back to the list -- five interactions to add one
// task, and deleting needed a trip into each row's bottom action row.
//
// This shape is the one task apps converged on: a composer row pinned to the
// top of the list -- click (or just type), press Enter, and the task is in;
// the field keeps focus so the next task is one more Enter away. Deleting is
// one click on the X that every row carries (see TaskList.qml), no hover
// hunting, no confirmation.
Item {
    id: root

    // ── Two-finger tab swipe ────────────────────────────────────────────
    //
    // Re-implemented here because the pager's own wheel handling was given up
    // to kill mouse-drag paging (see `interactive: false` on the SwipeView).
    // It is the same shape as the left sidebar's `swipeSurface`, and for the
    // same reason: a touchpad swipe reaches the shell as a wheel event, and
    // once the pager is not interactive that event has nowhere to go.
    //
    // `acceptedButtons: Qt.NoButton` is the load-bearing part. This surface
    // must take NO presses -- if it took left button it would sit on top of
    // every row and no task could be clicked, hovered or dragged. Wheel events
    // are unaffected by the button mask, so it can be topmost and still
    // invisible to the mouse.
    //
    // ONE AXIS PER GESTURE, decided on the first frame that leans and then held.
    // Re-deciding per event is what made a swipe "work for a second": a real
    // horizontal swipe bleeds slightly into y, one tick tipped the other way,
    // the gesture went to the scrolling branch, and the tab never changed for
    // the rest of that gesture.
    property bool swipeHorizontal: false
    property bool swipeVertical: false
    property bool swipeFired: false
    property real swipeAccX: 0
    property real swipeAccY: 0

    Timer {
        id: swipeReset
        interval: 160
        onTriggered: {
            root.swipeHorizontal = false;
            root.swipeVertical = false;
            root.swipeFired = false;
            root.swipeAccX = 0;
            root.swipeAccY = 0;
        }
    }

    function onSwipeWheel(w) {
        const pd = w.pixelDelta;
        const ad = w.angleDelta;

        // Lifted-off frames: the pad reporting that the fingers left. They
        // must not restart the gesture timer, or the single gesture gets split
        // in two and only the second half counts.
        const hasPixels = pd && (pd.x !== 0 || pd.y !== 0);
        const hasAngle = ad && (ad.x !== 0 || ad.y !== 0);
        if (!hasPixels && !hasAngle) {
            w.accepted = true;
            return;
        }

        // dx is undo-inverted so positive always means "fingers moved right",
        // which is the convention the rest of the shell uses.
        let dx = hasPixels ? pd.x : -ad.x / 120 * 40;
        let dy = hasPixels ? pd.y : ad.y / 120 * 40;

        root.swipeAccX += Math.abs(dx);
        root.swipeAccY += Math.abs(dy);
        swipeReset.restart();

        if (!root.swipeHorizontal && !root.swipeVertical) {
            const ax = root.swipeAccX;
            const ay = root.swipeAccY;
            if (ax > 0 && ax >= ay * 1.05)
                root.swipeHorizontal = true;
            else if (ay > 0)
                root.swipeVertical = true;
        }

        if (root.swipeHorizontal) {
            w.accepted = true;
            if (root.swipeFired)
                return;
            root.swipeFired = true;
            // Fingers right = NEXT tab, matching the left sidebar's stepTab and
            // the now-bar card.
            tabBar.incrementCurrentIndex();
            if (dx < 0)
                tabBar.decrementCurrentIndex();
            return;
        }

        // Vertical: the lists own this. Hand the event to the visible page's
        // list, which has a tuned touchpad path of its own (gain, fling, coast)
        // -- writing contentY from out here would bypass all of it.
        if (root.swipeVertical) {
            const page = swipeView.currentItem;
            if (page && typeof page.handleWheel === "function") {
                page.handleWheel(w);
                return;
            }
            w.accepted = true;
        }
    }

    // Kept for parity with the other sidebar widgets' keyboard contract:
    // PageUp/PageDown flip tabs when the page has focus. The old "N opens the
    // dialog" shortcut is gone with the dialog; Escape blurs the composer so
    // the tab bar takes over again.
    Keys.onPressed: (event) => {
        if ((event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp) && event.modifiers === Qt.NoModifier) {
            if (event.key === Qt.Key_PageDown) {
                tabBar.incrementCurrentIndex();
            } else if (event.key === Qt.Key_PageUp) {
                tabBar.decrementCurrentIndex();
            }
            event.accepted = true;
        }
        else if (event.key === Qt.Key_Escape && todoInput.activeFocus) {
            todoInput.focus = false;
            event.accepted = true;
        }
    }

    function addTask() {
        const text = todoInput.text.trim();
        if (text.length === 0)
            return;
        Todo.addTask(text);
        todoInput.text = "";
        // Stay in the composer: adding several tasks in a row is the common
        // case, and re-focusing after every add is the friction this removes.
        todoInput.forceActiveFocus();
        tabBar.setCurrentIndex(0); // jump to the unfinished list so it is visible
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── Composer ──────────────────────────────────────────────────────
        // A borderless pill: reads as part of the list, not as a form. Enter
        // adds; the trailing button adds without touching the keyboard.
        Rectangle {
            id: composer
            Layout.fillWidth: true
            implicitHeight: 44
            radius: Appearance.rounding.full
            color: todoInput.activeFocus
                ? Appearance.colors.colLayer2
                : Appearance.colors.colLayer1
            border.width: 1
            border.color: todoInput.activeFocus
                ? Appearance.colors.colPrimary
                : Appearance.colors.colLayer0Border

            Behavior on color {
                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
            }
            Behavior on border.color {
                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 6
                spacing: 8

                MaterialSymbol {
                    text: "add"
                    iconSize: Appearance.font.pixelSize.larger
                    color: todoInput.activeFocus
                        ? Appearance.colors.colPrimary
                        : Appearance.m3colors.m3outline
                }

                TextField {
                    id: todoInput
                    Layout.fillWidth: true
                    placeholderText: Translation.tr("Add a task and press Enter")
                    placeholderTextColor: Appearance.m3colors.m3outline
                    color: Appearance.m3colors.m3onSurface
                    renderType: Text.NativeRendering
                    background: null
                    padding: 0
                    // The composer is where typing should land when the To Do
                    // page opens -- no click into a field first.
                    focus: root.visible
                    onAccepted: root.addTask()
                }

                TodoItemActionButton {
                    visible: todoInput.text.length > 0
                    implicitWidth: 32
                    implicitHeight: 32
                    onClicked: root.addTask()
                    contentItem: MaterialSymbol {
                        anchors.centerIn: parent
                        text: "arrow_forward"
                        iconSize: Appearance.font.pixelSize.larger
                        color: Appearance.colors.colOnLayer1
                    }
                }
            }
        }

        SecondaryTabBar {
            id: tabBar
            Layout.topMargin: 10
            currentIndex: swipeView.currentIndex

            Repeater {
                model: [
                    {"icon": "checklist", "name": Translation.tr("Unfinished")},
                    {"name": Translation.tr("Done"), "icon": "check_circle"}
                ]
                delegate: SecondaryTabButton {
                    buttonText: modelData.name
                    buttonIcon: modelData.icon
                }
            }
        }

        SwipeView {
            id: swipeView
            Layout.topMargin: 10
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 10
            clip: true
            currentIndex: tabBar.currentIndex

            // No MOUSE-drag paging. Two-finger swipe only.
            //
            // Press a row's action button, move sideways without lifting, and
            // the pager slid from Unfinished to Done: the actions are buttons,
            // a button does not grab the pointer on press, and the drag fell
            // straight through to the pager underneath.
            //
            // `interactive: false` removes that path outright. It costs the
            // pager its OWN wheel handling too, so the two-finger swipe is
            // re-implemented explicitly below -- the same shape the left
            // sidebar uses, and for the same reason.
            //
            // NOT a `DragHandler { target: null }`, which is the obvious way to
            // eat a drag and is a trap here: a handler on the pager is an
            // ANCESTOR of every row, so it takes the grab before the row's
            // `MouseArea` can claim it, and the to-do rows stop being
            // grabbable at all.
            //
            // NOT `dragEnabled`, which Qt 6.11's `SwipeView` does not have --
            // assigning it is a load error that kills the whole shell.
            interactive: false


            TaskList {
                emptyPlaceholderIcon: "check_circle"
                emptyPlaceholderText: Translation.tr("Nothing here!")
                // A plain `filter`, NOT a `map` that clones each entry.
                //
                // It used to be
                //   Todo.list.map((item, i) => Object.assign({}, item, {originalIndex: i}))
                //     .filter(item => !item.done)
                // to give each row its position in the full list. The clone gave
                // every task a new object identity on every rebuild, and
                // Quickshell's ScriptModel keys rows on identity -- so each
                // rebuild read as the whole list being deleted and re-added.
                // Dragging ends in exactly one rebuild, at drop, and the
                // dragged task visibly duplicated.
                //
                // `filter` keeps the original objects, and tasks now carry a
                // stable `id` (see Todo.qml), so nothing here has to be
                // positional and a reorder is a pure move.
                taskList: Todo.list.filter(function(item) { return !item.done; })
            }
            TaskList {
                emptyPlaceholderIcon: "checklist"
                emptyPlaceholderText: Translation.tr("Finished tasks will go here")
                taskList: Todo.list.filter(function(item) { return item.done; })
            }
        }
    }

    // TOPMOST, and a direct child of the ROOT -- not of the ColumnLayout.
    //
    // Two things depend on that. It must come after the layout in the child
    // list to paint and receive events above it, and it must be outside the
    // layout because a layout manages its own children's geometry: an
    // `anchors.fill` on a child of a ColumnLayout is undefined behaviour and
    // Qt says so in the log on every load.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        onWheel: w => root.onSwipeWheel(w)
    }
}
