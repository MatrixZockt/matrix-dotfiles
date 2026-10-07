import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions as CF

/**
 * The search box and its results -- Windows' Settings search, sized for a
 * shell panel.
 *
 * One component, two states, because that is what makes it feel like Windows:
 *
 *   * COLLAPSED -- a rounded field with a magnifier, a caret, and placeholder
 *     text. You can type in it immediately; it is never a button that has to
 *     be clicked first.
 *   * EXPANDED -- the same field, with a results list dropped underneath,
 *     floating OVER the content rather than pushing it down. Pushing the page
 *     down on every keystroke is the single most common way a search box feels
 *     wrong: the thing you are searching for moves while you type at it.
 *
 * The results are settings, not just pages, and each one says where it lives
 * ("Display") so you can tell two same-named controls apart before you commit.
 * Enter jumps: page AND section, so "Night light" lands on the Display page
 * with the right part in view.
 *
 * Keyboard is the primary input, because that is how Windows does it and it is
 * simply faster: Up/Down move, Enter opens, Escape closes (first press clears
 * the text, second press closes the results -- so one Escape is never a
 * wasted keystroke).
 */
Item {
    id: root

    // Emitted when a result is chosen, so the host can navigate.
    signal activated(string pageSlug, string section)

    implicitHeight: searchField.implicitHeight

    function focusSearch() {
        searchInput.forceActiveFocus();
    }

    // Open a result: hand it up and get out of the way, so the content pane
    // is not animating under a results list on top of it.
    function choose(entry) {
        if (!entry)
            return;
        const target = SettingsSearch.targetFor(entry);
        SettingsSearch.reset();
        root.activated(target.page, target.section);
    }

    // ── The field ─────────────────────────────────────────────────────────
    Rectangle {
        id: searchField

        anchors {
            left: parent.left
            right: parent.right
            top: parent.top
        }
        implicitHeight: 44
        radius: height / 2
        color: SettingsSearch.active
            ? Appearance.colors.colLayer2
            : Appearance.colors.colLayer1

        Behavior on color {
            NumberAnimation {
                duration: Appearance.animation.elementMoveFast.duration
                easing.type: Appearance.animation.elementMoveFast.type
            }
        }

        // The focus ring. Drawn rather than taken from a control's own
        // `focus` visual, because the field is a Rectangle: it has no
        // indicator of its own to colour.
        Rectangle {
            anchors.fill: parent
            anchors.margins: -2
            radius: parent.radius + 2
            color: "transparent"
            border.width: 2
            border.color: Appearance.colors.colPrimary
            opacity: searchInput.activeFocus ? 0.9 : 0.0
            Behavior on opacity {
                NumberAnimation { duration: Appearance.animation.elementMoveFast.duration }
            }
        }

        MaterialSymbol {
            id: magnifier
            anchors {
                left: parent.left
                leftMargin: 14
                verticalCenter: parent.verticalCenter
            }
            text: "search"
            iconSize: Appearance.font.pixelSize.larger
            color: searchInput.activeFocus || SettingsSearch.active
                ? Appearance.colors.colOnSurface
                : Appearance.colors.colOnSurfaceVariant
        }

        // The real text input. Invisible: this TextField exists for its
        // editing behaviour (caret, selection, clipboard, IME) and its text is
        // drawn by the StyledText below, which is what lets the matched
        // characters of a RESULT be highlighted. Two text layers is the price
        // of that, and it is the same trade every highlighted-search UI makes.
        TextField {
            id: searchInput
            anchors {
                left: magnifier.right
                right: clearButton.visible ? clearButton.left : parent.right
                leftMargin: 12
                rightMargin: 8
                verticalCenter: parent.verticalCenter
            }
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            background: null
            color: "transparent"
            selectionColor: Appearance.colors.colPrimary
            selectedTextColor: Appearance.colors.colOnPrimary
            font.pixelSize: Appearance.font.pixelSize.small
            text: SettingsSearch.query
            onTextChanged: SettingsSearch.query = text
            // Re-entering text from the model would fight the caret.
            onActiveFocusChanged: if (!activeFocus) selectAll()

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    // Two-stage Escape: clear first, close second. One press
                    // to get your typing back without losing the results you
                    // were reading.
                    //
                    // Only the first stage is handled here. `SettingsSearch
                    // .active` is derived (readonly) from the query, so it
                    // cannot be switched off directly -- clearing the query is
                    // what closes the results, and a second Escape on an
                    // already-empty field falls through to the shell's own
                    // handler, which owns closing the search overlay.
                    if (SettingsSearch.query.length > 0)
                        SettingsSearch.query = "";
                    event.accepted = true;
                } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
                    SettingsSearch.moveHighlight(event.key === Qt.Key_Down ? 1 : -1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.choose(SettingsSearch.highlighted);
                    event.accepted = true;
                }
            }

            Connections {
                target: SettingsSearch
                function onQueryChanged() {
                    if (searchInput.text !== SettingsSearch.query)
                        searchInput.text = SettingsSearch.query;
                }
            }
        }

        // The text itself. The TextField above is transparent on purpose, so
        // something has to draw the query -- without this the field fills up
        // and looks completely empty while you type into it, which is the
        // worst possible failure for a search box. Anchored to the same place
        // as the input so the caret lines up with the glyphs.
        StyledText {
            anchors {
                left: magnifier.right
                leftMargin: 12
                right: clearButton.visible ? clearButton.left : parent.right
                rightMargin: 8
                verticalCenter: parent.verticalCenter
            }
            visible: SettingsSearch.query.length > 0
            elide: Text.ElideRight
            color: Appearance.colors.colOnSurface
            font.pixelSize: Appearance.font.pixelSize.small
            text: SettingsSearch.query
        }

        StyledText {
            anchors {
                left: magnifier.right
                leftMargin: 12
                verticalCenter: parent.verticalCenter
            }
            visible: SettingsSearch.query.length === 0
            color: Appearance.colors.colOnSurfaceVariant
            font.pixelSize: Appearance.font.pixelSize.small
            text: Translation.tr("Find a setting")
        }

        RippleButton {
            id: clearButton
            anchors {
                right: parent.right
                rightMargin: 8
                verticalCenter: parent.verticalCenter
            }
            implicitWidth: 28
            implicitHeight: 28
            visible: SettingsSearch.active
            buttonRadius: Appearance.rounding.full
            colBackground: "transparent"
            colBackgroundHover: Appearance.colors.colLayer1Hover
            onClicked: {
                SettingsSearch.query = "";
                searchInput.forceActiveFocus();
            }
            contentItem: MaterialSymbol {
                anchors.centerIn: parent
                text: "close"
                iconSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colOnSurfaceVariant
            }
            StyledToolTip {
                text: Translation.tr("Clear search")
            }
        }

        // Clicking anywhere on the field takes the keyboard, so the box works
        // without first having to hit the exact text area.
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.IBeamCursor
            acceptedButtons: Qt.LeftButton
            // Let the buttons inside keep their own clicks.
            onClicked: function(mouse) {
                if (mouse.button !== Qt.LeftButton)
                    return;
                searchInput.forceActiveFocus();
            }
            // Swallow clicks on the field so they do not fall through to the
            // page underneath and navigate away from the search.
            onPressed: function(mouse) { mouse.accepted = true; }
            onReleased: function(mouse) { mouse.accepted = true; }
            z: -1
        }
    }

    // ── The results ───────────────────────────────────────────────────────
    //
    // Positioned by the host (an overlay), never inline: see the header note
    // about the content moving while you type.
    Rectangle {
        id: resultsPanel

        anchors {
            top: searchField.bottom
            topMargin: 6
            left: searchField.left
            right: searchField.right
        }
        visible: SettingsSearch.active && SettingsSearch.results.length > 0
        height: visible ? Math.min(resultsList.contentHeight + 12, 420) : 0
        radius: Appearance.rounding.normal
        color: Appearance.colors.colLayer1
        border.width: 1
        border.color: CF.ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.5)
        z: 100

        Behavior on height {
            NumberAnimation {
                duration: Appearance.animation.elementMoveFast.duration
                easing.type: Appearance.animation.elementMoveFast.type
            }
        }

        clip: true

        ListView {
            id: resultsList
            anchors {
                fill: parent
                topMargin: 6
                bottomMargin: 6
            }
            model: SettingsSearch.results
            spacing: 2
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            delegate: RippleButton {
                id: resultRow
                required property var modelData
                required property int index

                width: resultsList.width
                implicitHeight: 52
                buttonRadius: Appearance.rounding.small
                colBackground: "transparent"
                colBackgroundHover: Appearance.colors.colLayer1Hover
                // The keyboard highlight has to read as selected even though
                // the pointer is nowhere near it, so it is drawn explicitly
                // rather than left to hover.
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 2
                    // NOT `parent.radius`: RippleButton has no `radius`
                    // property (it is `buttonRadius`), so reading it yields
                    // undefined and the whole assignment throws.
                    radius: Appearance.rounding.small
                    color: Appearance.colors.colSecondaryContainer
                    visible: SettingsSearch.highlightedIndex === resultRow.index
                }
                onClicked: root.choose(resultRow.modelData)

                contentItem: RowLayout {
                    spacing: 14

                    MaterialSymbol {
                        text: resultRow.modelData.icon ?? "settings"
                        iconSize: Appearance.font.pixelSize.larger
                        color: SettingsSearch.highlightedIndex === resultRow.index
                            ? Appearance.colors.colOnSecondaryContainer
                            : Appearance.colors.colOnSurfaceVariant
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1

                        StyledText {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            font.pixelSize: Appearance.font.pixelSize.small
                            font.weight: Font.Medium
                            color: SettingsSearch.highlightedIndex === resultRow.index
                                ? Appearance.colors.colOnSecondaryContainer
                                : Appearance.colors.colOnLayer0
                            text: resultRow.modelData.name
                        }

                        // Where it lives. Without this, two results with the
                        // same name are indistinguishable and the search feels
                        // arbitrary.
                        StyledText {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: SettingsSearch.highlightedIndex === resultRow.index
                                ? Appearance.colors.colOnSecondaryContainer
                                : Appearance.colors.colSubtext
                            text: SettingsSearch.pageName(resultRow.modelData.page)
                        }
                    }

                    // A PAGE is a destination; a SETTING is a control inside
                    // one. Saying which is the difference between "this opens
                    // the Display page" and "this turns something on it".
                    StyledText {
                        visible: resultRow.modelData.kind === "page"
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                        text: Translation.tr("Page")
                    }
                }
            }
        }
    }

    // "Nothing matched" -- said plainly, because a search box that silently
    // shows nothing reads as broken rather than as "no results".
    StyledText {
        anchors {
            top: searchField.bottom
            topMargin: 10
            left: searchField.left
            right: searchField.right
        }
        visible: SettingsSearch.active && SettingsSearch.results.length === 0
        horizontalAlignment: Text.AlignHCenter
        color: Appearance.colors.colOnSurfaceVariant
        font.pixelSize: Appearance.font.pixelSize.small
        text: Translation.tr("No settings match \"%1\"").arg(SettingsSearch.query)
        z: 100
    }
}
