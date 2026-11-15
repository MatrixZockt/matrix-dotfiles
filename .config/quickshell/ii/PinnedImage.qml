import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland

/**
 * One pinned picture: a floating image that stays above the windows, can be
 * dragged anywhere, and answers a right click with save, copy and unpin.
 *
 * WHY A FULL-SCREEN SURFACE WITH A MASK, not a window the size of the picture.
 *
 * Dragging by moving the window itself does not work: the surface follows the
 * pointer, so the pointer's position inside it never changes and the drag reads
 * as zero travel. A surface that covers the screen and moves the picture INSIDE
 * it has one stable coordinate system -- the pointer's place on the screen -- so
 * a drag is just "keep the picture the same distance from the pointer". The
 * empty part of the surface is outside the mask, so every click that is not on
 * the picture or its menu goes to the desktop underneath, and the surface never
 * swallows one.
 *
 * The surface is on the Overlay layer, which is what "pinned in front" means
 * here: above tiled windows and above the bar, below nothing but the shell's own
 * dialogs. It takes no keyboard focus, so pinning a picture cannot steal the
 * typing from the window behind it.
 */
Scope {
    id: root

    // { key, path, x, y } from GlobalStates.pinnedImages -- the pin's registry
    // entry, which is also what unpinning removes. Variants hands each delegate
    // its item as `modelData`, so that is the entry.
    required property var modelData

    readonly property string imageKey: modelData?.key ?? ""
    readonly property string imagePath: modelData?.path ?? ""

    // A pin is either a picture or a live text card. Text has no file: its
    // content is the clipboard's current text, shared by every live card (see
    // GlobalStates.liveClipboardText), which is what makes it live at all.
    readonly property bool isText: (modelData?.kind ?? "image") === "text"
    readonly property string cardText: isText ? GlobalStates.liveClipboardText : ""

    // Where the picture sits, in screen pixels from the top-left corner. Seeded
    // from the entry and updated while dragging; it lives here rather than in
    // the registry because writing the list back on every release would rebuild
    // every pinned surface, which is a visible blink for a saved position.
    property real posX: modelData?.x ?? 160
    property real posY: modelData?.y ?? 120

    // Which monitor it was pinned on. Pinning is a thing done on the screen being
    // looked at, so the picture appears there; the fallback is the same one the
    // signal card uses, for the startup frame where the compositor has not named
    // a focused monitor yet.
    readonly property var targetScreen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name)
        ?? (Quickshell.screens.length > 0 ? Quickshell.screens[0] : null)

    // The picture may not be larger than a third of the screen: a pinned
    // screenshot should sit on the desktop as a reference beside the windows,
    // not cover the windows it was pinned to look at. A third of each side is
    // roughly half the AREA of the old 70%, which still read as "a window".
    // Anything smaller than this keeps its own size -- a small snip is pinned
    // exactly as large as it was taken, never blown up to fill the cap. Aspect
    // ratio is kept either way, because a stretched screenshot is a wrong one.
    readonly property real maxWidth: (targetScreen?.width ?? 1920) * 0.35
    readonly property real maxHeight: (targetScreen?.height ?? 1080) * 0.35


    PanelWindow {
        id: win
        screen: root.targetScreen
        color: "transparent"
        // A text pin has no file to check, so it is "there" whenever it exists.
        visible: root.isText || root.imagePath.length > 0

        WlrLayershell.namespace: "quickshell:pinnedImage"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        exclusiveZone: 0

        anchors {
            top: true
            left: true
            right: true
            bottom: true
        }

        // Nothing but the picture and its menu is a target.
        mask: Region { item: pictureFrame }

        // The picture with its shadow, border, corner unpin and context menu.
        Item {
            id: pictureFrame
            x: root.posX
            y: root.posY
            // The picture sizes itself and this follows it. Nothing here divides
            // by an implicit size or anchors the image into its own parent: both
            // of those leave a fresh surface reporting one pixel until the load
            // settles, and a pin you cannot see is a pin you think did not work.
            width: root.isText ? textPanel.width : Math.max(1, picture.width)
            height: root.isText ? textPanel.height : Math.max(1, picture.height)

            // Where the pointer took hold of the frame, so the drag keeps the
            // same point under the cursor for the whole gesture.
            property real grabX: 0
            property real grabY: 0

            function dragStart(mouseX, mouseY) {
                pictureFrame.grabX = mouseX;
                pictureFrame.grabY = mouseY;
            }

            // The surface is the whole screen and never moves, so the pointer's
            // screen place is the frame's own x plus the pointer's place in it --
            // an absolute reading, immune to the drift accumulated deltas pick up.
            function dragMove(mouseX, mouseY) {
                const screenX = pictureFrame.x + mouseX - pictureFrame.grabX;
                const screenY = pictureFrame.y + mouseY - pictureFrame.grabY;
                root.posX = Math.max(0, Math.min(screenX, win.width - pictureFrame.width));
                root.posY = Math.max(0, Math.min(screenY, win.height - pictureFrame.height));
            }

            // The picture and its outline share one rounded frame: the shadow
            // needs a radius to blur around, and a screenshot over the desktop
            // with a hard corner reads as a pasted rectangle rather than as a
            // card that is meant to be moved.
            Image {
                id: picture
                visible: !root.isText
                // Empty, not "file://" when there is nothing to show: the bare
                // scheme resolves to the root directory and warns.
                source: !root.isText && root.imagePath.length > 0 ? "file://" + root.imagePath : ""
                asynchronous: true
                cache: false
                fillMode: Image.PreserveAspectFit
                smooth: true
                // Downscaled at DECODE time, so a 4K screenshot does not become a
                // 4K texture a second after it is pinned. The rounded value also
                // IS the width the surface takes: an unanchored Image is as big as
                // its own implicit size, and this is that size.
                sourceSize {
                    width: Math.round(root.maxWidth)
                    height: Math.round(root.maxHeight)
                }
                // The cap is applied here as well as at decode time: a decoded
                // image can still arrive larger than requested, and a pinned
                // screenshot may not cover most of the screen it was pinned to
                // look at. Height follows the picture's own ratio, so nothing is
                // ever stretched.
                width: Math.min(Math.max(1, implicitWidth), root.maxWidth)
                height: Math.min(width * (implicitHeight / Math.max(1, implicitWidth)), root.maxHeight)
            }

            // The outline and the shadow blur around it. Drawn over the picture
            // rather than clipping it: a clip here would shave the shadow off the
            // full-screen surface, and a screenshot's own corners are square
            // anyway -- the line is what separates it from the desktop.
            Rectangle {
                id: frame
                anchors.fill: parent
                visible: !root.isText
                radius: Appearance.rounding.small
                color: "transparent"
                border.width: 1
                border.color: Appearance.colors.colOutlineVariant
                antialiasing: true
            }

            StyledRectangularShadow {
                target: root.isText ? textPanel : frame
            }

            // The live text card. Its own surface material rather than a
            // screenshot's outline, because there is no picture to frame: what is
            // being kept is words, and they need a background that text can be
            // read on wherever it lands.
            Rectangle {
                id: textPanel
                visible: root.isText
                width: Math.min(root.maxWidth, 420)
                height: Math.min(root.maxHeight, Math.max(110, bodyText.implicitHeight + 46))
                radius: Appearance.rounding.small
                color: Appearance.colors.colBackgroundSurfaceContainer
                border.width: 1
                border.color: Appearance.colors.colOutlineVariant
                clip: true

                // A right click anywhere on the card opens the menu, body
                // included: the body below owns left-button selection, and a tap
                // handler for the right button does not take that away.
                TapHandler {
                    acceptedButtons: Qt.RightButton
                    onTapped: (eventPoint, button) => menu.openAt(eventPoint.position.x, eventPoint.position.y)
                }

                // The grip. Text has to stay selectable, so the card cannot be
                // dragged from anywhere the way a picture can: this strip is what
                // moves it, and it is also where a right click opens the menu.
                Item {
                    id: textHeader
                    anchors {
                        top: parent.top
                        left: parent.left
                        right: parent.right
                    }
                    height: 26

                    MouseArea {
                        id: headerArea
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        cursorShape: Qt.OpenHandCursor

                        onPressed: (mouse) => {
                            if (mouse.button === Qt.RightButton) {
                                menu.openAt(mouse.x, mouse.y);
                                return;
                            }
                            pictureFrame.dragStart(mouse.x, mouse.y);
                        }

                        onPositionChanged: (mouse) => {
                            if (pressed && !menu.visible)
                                pictureFrame.dragMove(mouse.x, mouse.y);
                        }
                    }

                    RowLayout {
                        anchors {
                            fill: parent
                            leftMargin: 12
                            rightMargin: 30
                        }
                        spacing: 6

                        MaterialSymbol {
                            text: "sync"
                            iconSize: 13
                            color: Appearance.colors.colOnSurfaceVariant
                        }

                        StyledText {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            // Says what it is: a card that follows the clipboard,
                            // not a snapshot that will go stale.
                            text: Translation.tr("Live text")
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: Appearance.colors.colOnSurfaceVariant
                        }
                    }
                }

                Flickable {
                    id: bodyFlick
                    anchors {
                        top: textHeader.bottom
                        left: parent.left
                        right: parent.right
                        bottom: parent.bottom
                        leftMargin: 12
                        rightMargin: 12
                        bottomMargin: 10
                    }
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    contentWidth: width
                    contentHeight: bodyText.implicitHeight

                    TextEdit {
                        id: bodyText
                        width: bodyFlick.width
                        text: root.cardText
                        readOnly: true
                        selectByMouse: true
                        wrapMode: TextEdit.Wrap
                        color: Appearance.colors.colOnSurface
                        selectionColor: Appearance.colors.colPrimary
                        selectedTextColor: Appearance.colors.colOnPrimary
                        font.pixelSize: Appearance.font.pixelSize.small
                    }
                }
            }

            // Drag, and the right-click menu's target. Left button moves the
            // picture; right button opens its actions at the pointer.
            MouseArea {
                id: dragArea
                anchors.fill: parent
                visible: !root.isText
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: menu.visible ? Qt.ArrowCursor : Qt.OpenHandCursor
                // Distance from the pointer to the picture's corner when the drag
                // began. Constant for the whole gesture, which is what keeps the
                // picture from jumping under the cursor.
                property real grabX: 0
                property real grabY: 0

                onPressed: (mouse) => {
                    if (menu.visible) {
                        menu.visible = false;
                        return;
                    }
                    if (mouse.button === Qt.RightButton) {
                        menu.openAt(mouse.x, mouse.y);
                        return;
                    }
                    pictureFrame.dragStart(mouse.x, mouse.y);
                }

                onPositionChanged: (mouse) => {
                    if (!pressed || menu.visible)
                        return;
                    pictureFrame.dragMove(mouse.x, mouse.y);
                }
            }

            // The quick way out: a small unpin button in the top-right corner, on
            // the picture itself. Always there while the picture is pinned (that
            // is the point of "quick"), translucent enough not to fight the
            // screenshot, and ringed on hover so it reads as a button.
            Item {
                id: unpinButton
                anchors.top: pictureFrame.top
                anchors.right: pictureFrame.right
                anchors.topMargin: 8
                anchors.rightMargin: 8
                width: 24
                height: 24

                Rectangle {
                    anchors.fill: parent
                    radius: height / 2
                    // A dark disc with a white cross, not a theme colour: this
                    // sits ON a screenshot, whose colours are unknown, so the
                    // button has to read against whatever is underneath it.
                    color: unpinArea.containsMouse
                        ? Appearance.colors.colPrimary
                        : Qt.rgba(0, 0, 0, 0.55)
                    opacity: unpinArea.containsMouse ? 1 : 0.85

                    Behavior on opacity { NumberAnimation { duration: 140 } }
                    Behavior on color { ColorAnimation { duration: 140 } }
                }

                MaterialSymbol {
                    anchors.centerIn: parent
                    text: "close"
                    iconSize: 15
                    color: unpinArea.containsMouse ? Appearance.colors.colOnPrimary : "white"
                }

                MouseArea {
                    id: unpinArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: GlobalStates.unpinImage(root.imageKey)
                }
            }

            // The right-click actions, inside the picture's own bounds: a menu
            // that hung outside them would be beyond the input mask, and a click
            // on it would land on the desktop instead.
            Rectangle {
                id: menu
                visible: false
                width: 152
                implicitHeight: menuColumn.implicitHeight + 12
                height: implicitHeight
                radius: Appearance.rounding.small
                color: Appearance.colors.colBackgroundSurfaceContainer
                border.width: 1
                border.color: Appearance.colors.colOutlineVariant

                function openAt(localX, localY) {
                    menu.x = Math.max(4, Math.min(localX, pictureFrame.width - menu.width - 4));
                    menu.y = Math.max(4, Math.min(localY, pictureFrame.height - menu.height - 4));
                    menu.visible = true;
                }

                StyledRectangularShadow {
                    target: menu
                }

                ColumnLayout {
                    id: menuColumn
                    anchors {
                        left: parent.left
                        right: parent.right
                        top: parent.top
                        margins: 6
                    }
                    spacing: 2

                    Repeater {
                        model: root.isText
                            ? [
                                { action: "copyText", label: Translation.tr("Copy text"), icon: "content_copy" },
                                { action: "unpin", label: Translation.tr("Unpin"), icon: "close" },
                            ]
                            : [
                                { action: "save", label: Translation.tr("Save"), icon: "download" },
                                { action: "copy", label: Translation.tr("Copy"), icon: "content_copy" },
                                { action: "unpin", label: Translation.tr("Unpin"), icon: "close" },
                            ]

                        delegate: Rectangle {
                            id: menuItem
                            required property var modelData
                            Layout.fillWidth: true
                            implicitHeight: 32
                            radius: Appearance.rounding.small
                            color: menuItemArea.containsMouse
                                ? Appearance.colors.colLayer2Hover
                                : "transparent"

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 8
                                spacing: 10

                                MaterialSymbol {
                                    text: menuItem.modelData.icon
                                    iconSize: 17
                                    color: Appearance.colors.colOnSurface
                                }

                                StyledText {
                                    Layout.fillWidth: true
                                    text: menuItem.modelData.label
                                    font.pixelSize: Appearance.font.pixelSize.small
                                    color: Appearance.colors.colOnSurface
                                }
                            }

                            MouseArea {
                                id: menuItemArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    menu.visible = false;
                                    if (menuItem.modelData.action === "save")
                                        GlobalStates.savePinnedImage(root.imageKey);
                                    else if (menuItem.modelData.action === "copy")
                                        GlobalStates.copyPinnedImage(root.imageKey);
                                    else if (menuItem.modelData.action === "copyText")
                                        GlobalStates.copyPinnedText();
                                    else
                                        GlobalStates.unpinImage(root.imageKey);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
