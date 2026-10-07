import qs
import qs.services
import qs.modules.common
// `ColorUtils` is a shell singleton living in this module (qs.modules.common.functions),
// NOT a QtQuick type -- unlike most names in this file, which come from QtQuick
// itself. Without this import the row's `color:` bindings throw
// "ColorUtils is not defined" and every row paints white.
import qs.modules.common.functions
import qs.modules.common.widgets
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

/**
 * The BACKGROUND APPS popover: everything this shell is running with no
 * window on screen, in one card, opened from one bar icon.
 *
 * Why it exists
 * -------------
 * The Music app is a face of the music daemon -- closing its window only hides
 * it, so the song keeps playing. That is the point, and it creates a gap: a
 * window you closed is a window you can no longer find. This card is where
 * such apps live, so "what is still running back there?" has one answer that
 * does not depend on remembering what you opened.
 *
 * Why a bar icon
 * --------------
 * The pointer already goes to the top-right corner for volume, network and
 * battery, and this shell already has the machinery for "click an icon, get a
 * card" (BarAnchoredPanel). So this is one more icon, not a new pattern. The
 * icon only exists while something is actually running, so the bar carries
 * nothing at all in the normal case.
 *
 * Per-app actions
 * ---------------
 *   left click on a row ...... show the app (re-presents its existing window)
 *   right click on a row ..... the same thing
 *   the row's one button ..... the same thing again, without knowing that
 *
 * Right click IS the two-finger tap here: this compositor maps a two-finger
 * press to RMB (clickfinger, custom/keybinds.lua), so one handler covers a
 * mouse and a touchpad with nothing to configure.
 *
 * NO QUIT, ANYWHERE
 * -----------------
 * There used to be three ways to kill an app from here: a "Quit app" button
 * on the row, a Show/Quit strip behind the right click, and a "Quit all" in
 * the footer. All three are gone, and nothing in the shell reaches
 * `BackgroundApps.quitAll()` any more.
 *
 * The reason is the one this card has argued for in every comment it has:
 * these apps are FACES of daemons, and closing a face is not the same act as
 * stopping the daemon. A "Quit" sitting in this tray quietly teaches the
 * opposite -- that the two are one act -- and this panel is the one people
 * open to answer "is it still running?", not to end something. So the panel
 * became read-and-reopen: one action, and no way to lose a track by aiming
 * at the wrong row of a list you were only reading.
 */
BarAnchoredPanel {
    id: root

    contentWidth: 340

    readonly property var items: BackgroundApps.apps
    readonly property bool empty: items.length === 0

    onOpened: BackgroundApps.refresh();

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 6

        // ── Header ────────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            MaterialSymbol {
                text: "apps"
                iconSize: Appearance.font.pixelSize.larger
                color: Appearance.colors.colOnLayer0
            }
            StyledText {
                text: "Background apps"
                font.pixelSize: Appearance.font.pixelSize.title
                color: Appearance.colors.colOnLayer0
            }
            // The slack goes HERE rather than into the title. `fillWidth` on the
            // title handed every spare pixel to a left-aligned label, so the
            // air landed between "Background apps" and "1 running" and the two
            // read as "Background apps1 running" -- one word with a number
            // stuck to it. An explicit spacer puts the count next to the
            // buttons it belongs beside, where a count belongs.
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
            }
            StyledText {
                visible: !root.empty
                text: `${root.items.length} running`
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colSubtext
            }
            RippleButton {
                Layout.preferredWidth: 30
                Layout.preferredHeight: 30
                buttonRadius: Appearance.rounding.small
                colBackground: "transparent"
                colBackgroundHover: Appearance.colors.colLayer1Hover
                // A refresh is a re-read, not a restart: nothing here can
                // resurrect a dead app, it can only notice a live one sooner.
                onClicked: BackgroundApps.refresh()
                contentItem: MaterialSymbol {
                    anchors.centerIn: parent
                    text: "refresh"
                    iconSize: Appearance.font.pixelSize.normal
                    color: Appearance.colors.colOnLayer0
                }
                StyledToolTip { text: "Refresh" }
            }
            RippleButton {
                Layout.preferredWidth: 30
                Layout.preferredHeight: 30
                buttonRadius: Appearance.rounding.small
                colBackground: "transparent"
                colBackgroundHover: Appearance.colors.colLayer1Hover
                onClicked: root.close()
                contentItem: MaterialSymbol {
                    anchors.centerIn: parent
                    text: "close"
                    iconSize: Appearance.font.pixelSize.normal
                    color: Appearance.colors.colOnLayer0
                }
                StyledToolTip { text: "Close" }
            }
        }

        // ── The empty state ───────────────────────────────────────────────
        // Reachable in principle (everything quit while the card was open) and
        // worth saying out loud rather than showing a blank card: it explains
        // why the bar icon is not there.
        ColumnLayout {
            Layout.fillWidth: true
            visible: root.empty
            spacing: 4
            // A ColumnLayout has no topPadding/bottomPadding -- those are not
            // properties of QtQuick.Layouts' ColumnLayout at all, and naming
            // them is a hard parse error that took the whole shell down. The
            // equivalent is the attached Layout margin.
            Layout.topMargin: 10
            Layout.bottomMargin: 14

            StyledText {
                Layout.fillWidth: true
                text: "Nothing running in the background"
                font.pixelSize: Appearance.font.pixelSize.normal
                color: Appearance.colors.colOnLayer0
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }
            StyledText {
                Layout.fillWidth: true
                text: "Apps that keep playing or syncing after you close their window appear here."
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colSubtext
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }
        }

        // ── The rows ──────────────────────────────────────────────────────
        Repeater {
            model: root.items

            delegate: Rectangle {
                id: appRow
                required property var modelData
                required property int index

                readonly property var app: modelData
                readonly property bool last: index === root.items.length - 1

                Layout.fillWidth: true
                // 12 of air, not 18: the row is two lines of text, so the
                // padding was a third of the thing it was padding. The strip
                // that used to add its own height below the row is gone, and
                // with it the reason this number was ever generous.
                implicitHeight: rowCol.implicitHeight + 12
                radius: Appearance.rounding.small
                color: rowHover.hovered
                    ? Appearance.colors.colLayer1Hover
                    : ColorUtils.transparentize(Appearance.colors.colLayer1Hover, 1)
                Behavior on color {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }

                // A hairline between rows, but NOT after the last one -- a
                // trailing rule reads as a cut-off list.
                Rectangle {
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 1
                    visible: index > 0
                    color: ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.9)
                }

                HoverHandler {
                    id: rowHover
                }

                RowLayout {
                    id: rowCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    // Fills the row rather than floating in its middle, so the
                    // text block can sit at the TOP of it (see nameCol) while
                    // the icon and the button stay centred. A vertically
                    // centred row is the reason the name used to read as a
                    // value in a list rather than as the app's title.
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.topMargin: 6
                    anchors.bottomMargin: 6
                    anchors.leftMargin: 10
                    anchors.rightMargin: 8
                    spacing: 10

                    // Icon
                    Rectangle {
                        Layout.preferredWidth: 32
                        Layout.preferredHeight: 32
                        radius: Appearance.rounding.small
                        color: Appearance.colors.colLayer2
                        MaterialSymbol {
                            anchors.centerIn: parent
                            text: appRow.app.icon
                            iconSize: Appearance.font.pixelSize.larger
                            color: Appearance.colors.colPrimary
                        }
                    }

                    // THE APP'S TITLE, not a row label.
                    //
                    // Three changes, all aimed at the same thing. The name was
                    // set in the body face at Medium and hung in the middle of
                    // the row, which is exactly how a list renders a VALUE --
                    // it said "Music is running", not "this is the Music app".
                    //
                    //   * a different face. `expressive` (Space Grotesk) is a
                    //     different design from the body face on purpose, so
                    //     the name never reads as more of the same sentence.
                    //   * top right. Right-aligned against the row's trailing
                    //     edge and pinned to the top of the text block, so it
                    //     sits where a window title sits and the summary hangs
                    //     off it instead of competing beside it.
                    //   * less air. spacing 1 -> 0, and the summary drops one
                    //     step down the scale, so the two lines lock up as
                    //     one object with a title and a subtitle. The old gap
                    //     was a paragraph.
                    ColumnLayout {
                        id: nameCol
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.alignment: Qt.AlignTop
                        spacing: 0

                        StyledText {
                            Layout.fillWidth: true
                            text: appRow.app.name
                            font.family: Appearance.font.family.expressive
                            font.pixelSize: Appearance.font.pixelSize.normal
                            font.weight: Font.DemiBold
                            font.variableAxes: ({ "wght": 600 })
                            // A touch of tracking: Space Grotesk at DemiBold is
                            // a wide, geometric face, and at 16px in a 340px
                            // card the untracked version crowds its own
                            // baseline. This is the one place in the panel
                            // where looser is better.
                            font.letterSpacing: 0.4
                            horizontalAlignment: Text.AlignRight
                            color: Appearance.colors.colOnLayer0
                            elide: Text.ElideRight
                        }
                        StyledText {
                            Layout.fillWidth: true
                            text: appRow.app.summary
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            horizontalAlignment: Text.AlignRight
                            color: Appearance.colors.colSubtext
                            elide: Text.ElideRight
                        }
                    }

                    // The one action, always visible. It was the left of two
                    // buttons; the right one was Quit, and with Quit gone this
                    // is the whole trailing edge of the row.
                    RippleButton {
                        Layout.preferredWidth: 28
                        Layout.preferredHeight: 28
                        buttonRadius: Appearance.rounding.full
                        colBackground: "transparent"
                        colBackgroundHover: Appearance.colors.colLayer2Hover
                        onClicked: {
                            appRow.app.show();
                            root.close();
                        }
                        contentItem: MaterialSymbol {
                            anchors.centerIn: parent
                            text: "open_in_new"
                            iconSize: Appearance.font.pixelSize.normal
                            color: Appearance.colors.colOnLayer0
                        }
                        StyledToolTip { text: "Show window" }
                    }
                }

                // The strip that used to live here (right click / two-finger
                // tap: Show, Quit, and the "Music keeps playing" reassurance
                // that went with Quit) is gone along with Quit itself. It
                // existed to hold a second action; with one action left it was
                // the same button the row already had, one click further away.

                // A MouseArea, not a TapHandler: the card is its own window, so
                // nothing steals the press the way the bar's section area does
                // on the bar icons -- but the row's own button sits on top, and
                // a MouseArea ordered first keeps it clickable.
                MouseArea {
                    anchors.fill: parent
                    // The row's own button is on top of this; leaving the left
                    // button enabled here means the rest of the row is the
                    // click target.
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        // Both buttons do the same thing now. Right click is
                        // still ACCEPTED rather than ignored: it is the
                        // two-finger tap on this compositor (clickfinger maps
                        // it to RMB), and a two-finger tap that did nothing
                        // would read as a dead row. It is not a menu any more.
                        appRow.app.show();
                        root.close();
                    }
                }
            }
        }
    }

}
