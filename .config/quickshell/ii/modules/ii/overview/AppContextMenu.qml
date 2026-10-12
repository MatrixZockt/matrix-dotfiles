pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
// IconImage, for the app's own icon in the header -- the same widget the
// launcher's rows draw, so the menu shows the app the same way the tiles do.
import Quickshell.Widgets
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * The right-click menu for an app in the SUPER launcher.
 *
 * It shows every option the app actually has, and that list is not written
 * here: AppAdmin probes the app and returns what applies. That is what keeps a
 * flatpak from being offered "run as administrator", an AppImage from being
 * offered a repair it has no way to perform, and a program in your home
 * directory from being described as a package -- an option that is displayed is
 * an option that exists.
 *
 * TWO THINGS THAT ARE NOT OPTIONAL, and both are about the same worry:
 *
 *   * the rows that DELETE something do not run on the click that chose them.
 *     They open a confirmation that names the command and every path about to
 *     go, because "uninstall" in a launcher is one click away from a long
 *     afternoon, and because the paths are the part a user cannot predict --
 *     an app's settings have nothing to do with where its package lives.
 *   * what the confirmation shows is the command the script will run, asked
 *     for on demand (AppAdmin.requestPlan). It is not a sentence assembled by
 *     this file to look like a command line, so it cannot drift from the act.
 *
 * The menu is a child of the overlay's full-screen surface and is positioned
 * where the pointer was, clamped so it never hangs off the screen. It is
 * declared after the overlay's click catcher, so a press on the menu is the
 * menu's and a press beside it closes the launcher -- which is what a press
 * beside a menu means everywhere else.
 */
Item {
    id: root

    // ── What the overlay tells it ─────────────────────────────────────────
    property bool open: false
    property var entry: null
    // Where the pointer was, in the PANEL's coordinates: the menu is a child
    // of the whole-screen surface, not of the card, so it can sit beside the
    // card as happily as on top of it.
    property real anchorX: 0
    property real anchorY: 0

    signal launchRequested(var entry)
    // Carries the live DesktopAction, not a name for it: the overlay executes
    // it, and an object that knows how to launch itself cannot be misread.
    signal appActionRequested(var action)

    readonly property int menuWidth: 348
    readonly property int rowHeight: 40

    // The row whose consequence is being shown, or null.
    property var confirming: null

    // It has to FILL the layer above all else: the menu places itself in this
    // item's coordinates, and a zero-sized parent clamps every anchor to the
    // top-left corner -- which is exactly what a menu that "opens" but is
    // never where the pointer was turns out to be.
    anchors.fill: parent
    visible: root.open
    // Above the card and above the catcher, by declaration order; `z` is set
    // rather than relied on, because the catcher is a sibling that fills the
    // same surface.
    z: 10

    onOpenChanged: {
        if (root.open) {
            root.confirming = null;
            AppAdmin.probe(root.entry);
        } else {
            root.confirming = null;
            AppAdmin.clear();
        }
    }
    onEntryChanged: {
        if (root.open)
            AppAdmin.probe(root.entry);
    }

    // Closed by the overlay's own dismissal paths (Escape, a press beside it,
    // the card, or the launcher closing): the menu takes the FIRST dismissal
    // and the launcher the second, which is what a menu on screen means.
    function dismiss() {
        root.open = false;
    }

    // ── The rows ──────────────────────────────────────────────────────────
    //
    // Two sources, one list. The first is what AppAdmin found: the options the
    // INSTALLER makes possible. The second is the .desktop file's own Actions
    // -- "New Window", "New Private Window" -- which are the app's own idea of
    // what it offers, and which belong in a menu that claims to show all of
    // them. They launch a NEW session rather than redirecting to the running
    // one, which is the whole reason they exist.
    //
    // The app's own actions are read from the LIVE entry rather than from the
    // probe's copy of them: a DesktopAction knows how to execute itself, and
    // re-implementing that from the script's parsed Exec line would be a second
    // reading of the same file, free to disagree with the one the rest of the
    // shell uses (SearchItem and the taskbar both call action.execute()).
    readonly property var rows: {
        const out = [];
        if (!AppAdmin.plan)
            return out;
        const buckets = { run: [], maintain: [], remove: [] };
        for (const action of AppAdmin.actions) {
            const group = buckets[action.group] ? action.group : "run";
            buckets[group].push({
                key: "a:" + action.id,
                kind: "action",
                actionId: String(action.id),
                label: String(action.label ?? ""),
                icon: String(action.icon ?? "play_arrow"),
                destructive: action.destructive === true
            });
        }
        const own = [];
        for (const action of (root.entry && root.entry.actions) ? root.entry.actions : []) {
            own.push({
                key: "d:" + String(action.id),
                kind: "app",
                actionId: String(action.id),
                label: String(action.name || action.id),
                icon: String(action.icon || "open_in_new"),
                destructive: false
            });
        }
        const sections = [
            { title: Translation.tr("Launch"), rows: buckets.run },
            { title: Translation.tr("This app's own options"), rows: own },
            { title: Translation.tr("Repair"), rows: buckets.maintain },
            { title: Translation.tr("Remove"), rows: buckets.remove }
        ];
        for (const section of sections) {
            if (section.rows.length === 0)
                continue;
            out.push({ key: "h:" + section.title + out.length, header: section.title });
            for (const row of section.rows)
                out.push(row);
        }
        return out;
    }

    function choose(row) {
        if (!row || !row.actionId)
            return;
        if (row.kind === "app") {
            const actions = (root.entry && root.entry.actions) ? root.entry.actions : [];
            const action = actions.find(a => String(a.id) === row.actionId);
            root.dismiss();
            if (action)
                root.appActionRequested(action);
            return;
        }
        if (row.destructive === true) {
            // Not run yet -- planned. The confirmation below is what runs it.
            root.confirming = row;
            AppAdmin.requestPlan(row.actionId);
            return;
        }
        if (row.actionId === "open") {
            root.dismiss();
            root.launchRequested(root.entry);
            return;
        }
        AppAdmin.run(row.actionId);
    }

    // ── The card ──────────────────────────────────────────────────────────
    Rectangle {
        id: card

        readonly property real margin: 8

        // Placed at the pointer, then pushed back inside the surface: a menu
        // opened near an edge has to be readable, and the two clamps are the
        // whole of it.
        x: Math.max(card.margin, Math.min(root.anchorX, (parent ? parent.width : 0) - width - card.margin))
        y: Math.max(card.margin, Math.min(root.anchorY, (parent ? parent.height : 0) - height - card.margin))

        width: root.menuWidth
        implicitHeight: body.implicitHeight
        radius: Appearance.rounding.normal
        color: ColorUtils.transparentize(Appearance.colors.colLayer0, 0.15)
        border.width: 1
        border.color: Appearance.colors.colLayer0Border

        // Swallow presses on the card itself, so a click on the padding is not
        // a click on the launcher behind it -- the catcher would otherwise
        // close everything the moment the user missed a row by two pixels.
        MouseArea {
            anchors.fill: parent
        }

        ColumnLayout {
            id: body
            width: parent.width
            spacing: 0

            // ── Header: which app this is about ───────────────────────────
            Item {
                Layout.fillWidth: true
                implicitHeight: 58

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    spacing: 10

                    IconImage {
                        Layout.alignment: Qt.AlignVCenter
                        implicitSize: 28
                        source: Quickshell.iconPath(
                            root.entry ? root.entry.icon : "",
                            Quickshell.shellPath("assets/icons/fluent/app-generic.svg"))
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        Text {
                            Layout.fillWidth: true
                            text: String((root.entry && root.entry.name) ?? "")
                            elide: Text.ElideRight
                            color: Appearance.colors.colOnSurface
                            font.family: Appearance.font.family.main
                            font.pixelSize: Appearance.font.pixelSize.normal
                        }
                        // The line that makes the options below make sense: an
                        // app whose source is unknown has a shorter menu, and
                        // this is where that is visible rather than puzzling.
                        Text {
                            Layout.fillWidth: true
                            text: root.subtitle()
                            elide: Text.ElideRight
                            color: Appearance.colors.colOutline
                            font.family: Appearance.font.family.monospace
                            font.pixelSize: Appearance.font.pixelSize.smallest
                        }
                    }
                }
            }

            // ── The options, or the confirmation, or the outcome ──────────
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                // While the probe is in flight there is nothing to show yet;
                // saying so is better than an empty card that reads as broken.
                Text {
                    Layout.fillWidth: true
                    Layout.margins: 14
                    visible: root.confirming === null && !AppAdmin.plan
                    text: AppAdmin.probeError.length > 0
                        ? AppAdmin.probeError
                        : Translation.tr("Looking up this app…")
                    wrapMode: Text.WordWrap
                    color: Appearance.colors.colOutline
                    font.family: Appearance.font.family.main
                    font.pixelSize: Appearance.font.pixelSize.small
                }

                Repeater {
                    model: root.confirming === null ? root.rows : []

                    delegate: Item {
                        id: rowHost
                        required property int index
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: rowHost.modelData.header !== undefined
                            ? 26
                            : root.rowHeight

                        // A section heading, thin and unclickable.
                        Text {
                            visible: rowHost.modelData.header !== undefined
                            anchors.left: parent.left
                            anchors.leftMargin: 12
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 4
                            text: rowHost.modelData.header ?? ""
                            color: Appearance.colors.colOnSurfaceVariant
                            font.family: Appearance.font.family.main
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            font.letterSpacing: 0.7
                            font.capitalization: Font.AllUppercase
                        }

                        RippleButton {
                            id: rowButton
                            visible: rowHost.modelData.header === undefined
                            anchors.fill: parent
                            anchors.leftMargin: 6
                            anchors.rightMargin: 6
                            anchors.topMargin: 1
                            anchors.bottomMargin: 1
                            buttonRadius: Appearance.rounding.small
                            pointingHandCursor: true
                            onClicked: root.choose(rowHost.modelData)
                            colBackground: "transparent"
                            colBackgroundHover: Appearance.colors.colSurfaceContainerHigh
                            colBackgroundToggled: "transparent"
                            colBackgroundToggledHover: Appearance.colors.colSurfaceContainerHigh

                            contentItem: RowLayout {
                                spacing: 10

                                MaterialSymbol {
                                    Layout.alignment: Qt.AlignVCenter
                                    text: String(rowHost.modelData.icon ?? "")
                                    iconSize: 18
                                    color: root.rowTint(rowHost.modelData)
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: String(rowHost.modelData.label ?? "")
                                    elide: Text.ElideRight
                                    color: root.rowTint(rowHost.modelData)
                                    font.family: Appearance.font.family.main
                                    font.pixelSize: Appearance.font.pixelSize.small
                                }
                                // A destructive row says so before it is
                                // clicked, not only after: the icon is the
                                // same red, and this is the second signal that
                                // it is not an ordinary one.
                                MaterialSymbol {
                                    Layout.alignment: Qt.AlignVCenter
                                    visible: rowHost.modelData.destructive === true
                                    text: "warning"
                                    iconSize: 14
                                    color: Appearance.colors.colError
                                }
                            }
                        }
                    }
                }
            }

            // ── Confirmation ─────────────────────────────────────────────
            ColumnLayout {
                Layout.fillWidth: true
                Layout.margins: 14
                visible: root.confirming !== null
                spacing: 8

                Text {
                    Layout.fillWidth: true
                    text: root.confirmTitle()
                    wrapMode: Text.WordWrap
                    color: Appearance.colors.colOnSurface
                    font.family: Appearance.font.family.main
                    font.pixelSize: Appearance.font.pixelSize.normal
                }

                // The command, as the script builds it. Monospace and wrapped:
                // it is a claim about what will happen, and it should look like
                // one.
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: commandText.implicitHeight + 14
                    radius: Appearance.rounding.verysmall
                    color: Appearance.colors.colSurfaceContainerHigh

                    Text {
                        id: commandText
                        anchors.fill: parent
                        anchors.margins: 7
                        text: AppAdmin.planning
                            ? Translation.tr("Working out the command…")
                            : String((AppAdmin.pendingPlan && AppAdmin.pendingPlan.cmd) || "—")
                        wrapMode: Text.WrapAnywhere
                        color: Appearance.colors.colOnSurfaceVariant
                        font.family: Appearance.font.family.monospace
                        font.pixelSize: Appearance.font.pixelSize.smallest
                    }
                }

                // Every path that goes with it. This is the half of an
                // uninstall a user cannot predict, so it is never summarised
                // as "and your settings": the paths are listed as they are.
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: root.confirmDeletesData()
                    spacing: 2

                    Text {
                        text: Translation.tr("Also deleted:")
                        color: Appearance.colors.colOnSurfaceVariant
                        font.family: Appearance.font.family.main
                        font.pixelSize: Appearance.font.pixelSize.smallest
                    }
                    Repeater {
                        model: root.confirmDeletesData() ? AppAdmin.dataPaths : []
                        delegate: Text {
                            required property var modelData
                            Layout.fillWidth: true
                            text: String(modelData)
                            elide: Text.ElideMiddle
                            color: Appearance.colors.colError
                            font.family: Appearance.font.family.monospace
                            font.pixelSize: Appearance.font.pixelSize.smallest
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Item { Layout.fillWidth: true }

                    RippleButton {
                        implicitWidth: 88
                        implicitHeight: 34
                        buttonRadius: Appearance.rounding.small
                        onClicked: {
                            root.confirming = null;
                            AppAdmin.pendingPlan = null;
                        }
                        colBackground: "transparent"
                        colBackgroundHover: Appearance.colors.colSurfaceContainerHigh
                        contentItem: Text {
                            anchors.centerIn: parent
                            text: Translation.tr("Cancel")
                            color: Appearance.colors.colOnSurfaceVariant
                            font.family: Appearance.font.family.main
                            font.pixelSize: Appearance.font.pixelSize.small
                        }
                    }

                    RippleButton {
                        implicitWidth: 108
                        implicitHeight: 34
                        buttonRadius: Appearance.rounding.small
                        enabled: !AppAdmin.planning
                        onClicked: {
                            const action = root.confirming ? root.confirming.actionId : "";
                            root.confirming = null;
                            AppAdmin.run(action);
                        }
                        colBackground: Appearance.colors.colErrorContainer
                        colBackgroundHover: Appearance.colors.colErrorContainerHover
                        colBackgroundToggled: Appearance.colors.colErrorContainer
                        contentItem: Text {
                            anchors.centerIn: parent
                            text: Translation.tr("Delete")
                            color: Appearance.colors.colOnErrorContainer
                            font.family: Appearance.font.family.main
                            font.pixelSize: Appearance.font.pixelSize.small
                            font.weight: Font.DemiBold
                        }
                    }
                }
            }

            // ── Outcome ──────────────────────────────────────────────────
            //
            // The result is shown where the choice was made rather than as a
            // notification, because an uninstall that failed has to be
            // readable next to the thing that failed: the password being
            // cancelled and the package being held back by a dependency are
            // the two usual outcomes, and both are in this text.
            ColumnLayout {
                Layout.fillWidth: true
                Layout.margins: 14
                visible: root.confirming === null && (AppAdmin.busy || AppAdmin.resultText.length > 0)
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    MaterialLoadingIndicator {
                        Layout.alignment: Qt.AlignVCenter
                        visible: AppAdmin.busy
                        implicitSize: 18
                    }
                    MaterialSymbol {
                        Layout.alignment: Qt.AlignVCenter
                        visible: !AppAdmin.busy
                        text: AppAdmin.resultOk ? "check_circle" : "error"
                        iconSize: 18
                        color: AppAdmin.resultOk
                            ? Appearance.colors.colPrimary
                            : Appearance.colors.colError
                    }
                    Text {
                        Layout.fillWidth: true
                        text: AppAdmin.busy
                            ? Translation.tr("Working…")
                            : (AppAdmin.resultOk ? Translation.tr("Done") : Translation.tr("Could not finish"))
                        color: AppAdmin.resultOk
                            ? Appearance.colors.colOnSurface
                            : Appearance.colors.colError
                        font.family: Appearance.font.family.main
                        font.pixelSize: Appearance.font.pixelSize.small
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: !AppAdmin.busy && AppAdmin.resultText.length > 0
                    text: AppAdmin.resultText
                    wrapMode: Text.WordWrap
                    maximumLineCount: 10
                    elide: Text.ElideRight
                    color: Appearance.colors.colOnSurfaceVariant
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.smallest
                }

                RowLayout {
                    Layout.fillWidth: true
                    visible: !AppAdmin.busy && AppAdmin.resultText.length > 0
                    Item { Layout.fillWidth: true }
                    RippleButton {
                        implicitWidth: 88
                        implicitHeight: 34
                        buttonRadius: Appearance.rounding.small
                        onClicked: root.dismiss()
                        colBackground: Appearance.colors.colSecondaryContainer
                        colBackgroundHover: Appearance.colors.colSecondaryContainerHover
                        contentItem: Text {
                            anchors.centerIn: parent
                            text: Translation.tr("Close")
                            color: Appearance.colors.colOnSecondaryContainer
                            font.family: Appearance.font.family.main
                            font.pixelSize: Appearance.font.pixelSize.small
                        }
                    }
                }
            }

            Item { Layout.preferredHeight: 6 }
        }
    }

    // ── Little readings of the plan, kept together ───────────────────────
    function subtitle() {
        if (!AppAdmin.plan)
            return "";
        const plan = AppAdmin.plan;
        const kind = String(plan.kind ?? "unknown");
        const bits = [];
        if (plan.package)
            bits.push(String(plan.package));
        if (plan.version)
            bits.push(String(plan.version));
        else if (kind !== "unknown" && kind !== "local" && kind !== "appimage")
            bits.push(kind);
        switch (kind) {
        case "pacman": bits.push("pacman"); break;
        case "flatpak": bits.push("flatpak"); break;
        case "snap": bits.push("snap"); break;
        case "appimage": bits.push(Translation.tr("AppImage")); break;
        case "local": bits.push(Translation.tr("not from a package")); break;
        default: bits.push(Translation.tr("source unknown")); break;
        }
        if (AppAdmin.dataPaths.length > 0)
            bits.push(Translation.tr("%1 data paths").arg(AppAdmin.dataPaths.length));
        return bits.join("  ·  ");
    }

    function rowTint(row) {
        if (!row)
            return Appearance.colors.colOnSurface;
        if (row.destructive === true)
            return Appearance.colors.colError;
        return Appearance.colors.colOnSurface;
    }

    function confirmTitle() {
        const name = String((root.entry && root.entry.name) ?? "");
        if (!root.confirming)
            return "";
        switch (root.confirming.actionId) {
        case "uninstall":
            return Translation.tr("Uninstall %1?").arg(name);
        case "uninstall-purge":
            return Translation.tr("Uninstall %1 and delete all of its data?").arg(name);
        case "remove-entry":
            return Translation.tr("Remove this launcher entry?");
        default:
            return Translation.tr("Apply \"%1\"?").arg(String(root.confirming.label ?? ""));
        }
    }

    // Only a purge takes data with it; asking about settings otherwise would
    // teach the user to click past the list that matters.
    function confirmDeletesData() {
        return root.confirming !== null && root.confirming.actionId === "uninstall-purge"
            && AppAdmin.dataPaths.length > 0;
    }
}
