pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.functions as CF
import qs.modules.common.widgets

/**
 * Keybinds.
 *
 * The list is read live from Hyprland (`hyprctl binds -j`), so it is the real set
 * of active shortcuts rather than a hand-maintained copy that drifts.
 *
 * On editing, honestly: every bind in this setup is a Lua closure, and Hyprland
 * reports all of them as dispatcher `__lua` with a registry index for an argument.
 * That means an existing shortcut cannot be "re-pointed" from out here -- there is
 * no reconstructable action to bind a new key to. What this page can do, and does,
 * is the useful half: switch a shortcut off, and add your own. Both are written to
 * ~/.config/illogical-impulse/keybinds.json by scripts/keybinds/apply.sh, which
 * regenerates the override file that custom/keybinds.lua loads last.
 */
ContentPage {
    id: root
    forceWidth: true

    property var allBinds: []
    property var removed: []
    property var custom: []
    property string searchText: ""

    readonly property int maxRows: 140

    // ── Reading state ────────────────────────────────────────────────────────
    Process {
        id: bindsProc
        command: ["hyprctl", "binds", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.allBinds = JSON.parse(text) || [];
                } catch (e) {
                    console.error("[Keybinds] could not parse hyprctl binds:", e);
                    root.allBinds = [];
                }
            }
        }
    }

    Process {
        id: stateProc
        command: ["bash", "-c", "cat \"$HOME/.config/illogical-impulse/keybinds.json\" 2>/dev/null || echo '{}'"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const d = JSON.parse(text) || {};
                    root.removed = d.removed || [];
                    root.custom = d.custom || [];
                } catch (e) {
                    root.removed = [];
                    root.custom = [];
                }
            }
        }
    }

    function refresh() {
        bindsProc.running = true;
        stateProc.running = true;
    }

    Component.onCompleted: refresh()

    // Give the generator a moment to finish writing before re-reading.
    Timer {
        id: settleTimer
        interval: 700
        repeat: false
        onTriggered: root.refresh()
    }

    // ── Formatting helpers ───────────────────────────────────────────────────
    // Hyprland's own modifier bit field.
    function modifiersFor(modmask) {
        const parts = [];
        if (modmask & 64) parts.push("SUPER");
        if (modmask & 4) parts.push("CTRL");
        if (modmask & 8) parts.push("ALT");
        if (modmask & 1) parts.push("SHIFT");
        return parts;
    }

    function comboFor(bind) {
        if (bind.key === "") return "";
        return modifiersFor(bind.modmask).concat([bind.key]).join(" + ");
    }

    function groupFor(bind) {
        const d = bind.description || "";
        const idx = d.indexOf(":");
        if (idx > 0) return d.slice(0, idx).trim();
        return "Other";
    }

    // A flat rows array so one Repeater can draw headers and binds in order.
    readonly property var rows: {
        const query = root.searchText.trim().toLowerCase();
        const seen = ({});
        const entries = [];
        for (const bind of root.allBinds) {
            if (!bind || bind.catch_all) continue;
            const combo = root.comboFor(bind);
            if (combo === "") continue;
            const description = bind.description || "";
            const key = combo + "|" + description;
            if (seen[key]) continue;
            seen[key] = true;
            if (query !== ""
                && combo.toLowerCase().indexOf(query) === -1
                && description.toLowerCase().indexOf(query) === -1)
                continue;
            entries.push({
                combo: combo,
                description: description !== "" ? description : Translation.tr("(no description)"),
                group: root.groupFor(bind),
                disabled: root.removed.indexOf(combo) !== -1,
                raw: bind
            });
        }
        entries.sort((a, b) => (a.group + a.combo).localeCompare(b.group + b.combo));

        const out = [];
        let lastGroup = null;
        for (const entry of entries) {
            if (out.length >= root.maxRows) break;
            if (entry.group !== lastGroup) {
                lastGroup = entry.group;
                out.push({ isHeader: true, group: entry.group });
            }
            out.push(entry);
        }
        return out;
    }

    readonly property bool truncated: rows.length >= maxRows

    // ── "Switch off" / "add" ────────────────────────────────────────────────
    function setDisabled(combo, disabled) {
        const flag = disabled ? "--disable" : "--enable";
        Quickshell.execDetached(["bash", "-c",
            `'${Directories.keybindsApplyScriptPath}' ${flag} ${StringUtils.shellSingleQuoteEscape(combo)}`]);
        settleTimer.restart();
    }

    function addCustom(combo, command) {
        if (combo === "" || command.trim() === "")
            return;
        Quickshell.execDetached(["bash", "-c",
            `'${Directories.keybindsApplyScriptPath}' --add-keys ${StringUtils.shellSingleQuoteEscape(combo)}`
            + ` --add-cmd ${StringUtils.shellSingleQuoteEscape(command)}`
            + ` --add-desc ${StringUtils.shellSingleQuoteEscape("Custom: " + command.trim())}`]);
        settleTimer.restart();
    }

    function removeCustom(index) {
        Quickshell.execDetached(["bash", "-c",
            `'${Directories.keybindsApplyScriptPath}' --remove-custom ${index}`]);
        settleTimer.restart();
    }

    ContentSection {
        icon: "keyboard"
        title: Translation.tr("All shortcuts")

        StyledText {
            Layout.fillWidth: true
            Layout.bottomMargin: 6
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colSubtext
            wrapMode: Text.Wrap
            text: Translation.tr("Read live from Hyprland, so this is exactly what is active right now. \"Switch off\" unbinds a shortcut and remembers it.")
        }

        MaterialTextField {
            Layout.fillWidth: true
            placeholderText: Translation.tr("Search by keys or by what it does")
            onTextChanged: root.searchText = text
        }
    }

    ContentSection {
        visible: root.rows.length > 0
        icon: "list"
        title: root.searchText === "" ? Translation.tr("%1 shortcuts").arg(root.rows.length) : Translation.tr("Matches")

        StyledText {
            Layout.fillWidth: true
            Layout.bottomMargin: 6
            visible: root.truncated
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            wrapMode: Text.Wrap
            text: Translation.tr("Showing the first %1. Narrow the search to see the rest.").arg(root.maxRows)
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 3

            Repeater {
                model: root.rows

                // One row. The model is already flattened, so a single delegate
                // draws both group headings and shortcuts, in order.
                ConfigRow {
                    id: bindRow
                    required property var modelData
                    readonly property bool isHeader: bindRow.modelData.isHeader === true
                    readonly property string combo: bindRow.isHeader ? "" : (bindRow.modelData.combo ?? "")
                    Layout.fillWidth: true
                    Layout.topMargin: bindRow.isHeader ? 10 : 2
                    implicitHeight: bindRow.isHeader ? 22 : 34

                    StyledText {
                        visible: bindRow.isHeader
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        text: bindRow.isHeader ? (bindRow.modelData.group ?? "") : ""
                        font {
                            pixelSize: Appearance.font.pixelSize.small
                            weight: Font.DemiBold
                        }
                        color: Appearance.colors.colPrimary
                    }

                    StyledText {
                        visible: !bindRow.isHeader
                        Layout.preferredWidth: 260
                        text: bindRow.combo
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: bindRow.modelData.disabled
                            ? ColorUtils.transparentize(Appearance.colors.colOnSurface, 0.5)
                            : Appearance.colors.colOnSecondaryContainer
                        elide: Text.ElideRight
                    }

                    StyledText {
                        visible: !bindRow.isHeader
                        Layout.fillWidth: true
                        text: bindRow.isHeader ? "" : (bindRow.modelData.description ?? "")
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                        elide: Text.ElideRight
                    }

                    RippleButton {
                        visible: !bindRow.isHeader
                        implicitWidth: 120
                        implicitHeight: 28
                        onClicked: root.setDisabled(bindRow.combo, !bindRow.modelData.disabled)
                        contentItem: StyledText {
                            anchors.centerIn: parent
                            text: bindRow.modelData.disabled
                                ? Translation.tr("Switch on")
                                : Translation.tr("Switch off")
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: Appearance.colors.colPrimary
                        }
                    }
                }
            }
        }
    }

    ContentSection {
        icon: "add"
        title: Translation.tr("Add your own shortcut")

        StyledText {
            Layout.fillWidth: true
            Layout.bottomMargin: 6
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colSubtext
            wrapMode: Text.Wrap
            text: Translation.tr("Press the keys you want, then give it a command. It is saved and applied immediately.")
        }

        ConfigRow {
            Layout.fillWidth: true

            RippleButton {
                id: captureButton
                implicitWidth: 260
                implicitHeight: 36
                property bool recording: false
                property string captured: ""

                function startRecording() {
                    recording = true;
                    forceActiveFocus();
                }

                onClicked: startRecording()

                Keys.onPressed: event => {
                    if (!captureButton.recording)
                        return;
                    if (event.key === Qt.Key_Escape) {
                        captureButton.recording = false;
                        captureButton.captured = "";
                        event.accepted = true;
                        return;
                    }
                    // Ignore a modifier pressed on its own -- wait for the real key.
                    const ignored = [Qt.Key_Shift, Qt.Key_Control, Qt.Key_Alt, Qt.Key_Meta,
                                     Qt.Key_AltGr, Qt.Key_CapsLock, Qt.Key_Super_L, Qt.Key_Super_R];
                    if (ignored.indexOf(event.key) !== -1) {
                        event.accepted = true;
                        return;
                    }
                    const mods = [];
                    if (event.modifiers & Qt.MetaModifier) mods.push("SUPER");
                    if (event.modifiers & Qt.ControlModifier) mods.push("CTRL");
                    if (event.modifiers & Qt.AltModifier) mods.push("ALT");
                    if (event.modifiers & Qt.ShiftModifier) mods.push("SHIFT");
                    const keyName = root.keyNameFor(event);
                    if (keyName === "") {
                        event.accepted = true;
                        return;
                    }
                    captureButton.captured = mods.concat([keyName]).join(" + ");
                    captureButton.recording = false;
                    event.accepted = true;
                }

                contentItem: StyledText {
                    anchors.centerIn: parent
                    text: captureButton.recording
                        ? Translation.tr("Press a key combination… (Esc to cancel)")
                        : (captureButton.captured !== ""
                            ? captureButton.captured
                            : Translation.tr("Click, then press keys"))
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colOnSecondaryContainer
                }
            }

            MaterialTextField {
                id: commandField
                Layout.fillWidth: true
                placeholderText: Translation.tr("Command to run, e.g. kitty")
            }

            RippleButton {
                implicitWidth: 100
                implicitHeight: 36
                enabled: captureButton.captured !== "" && commandField.text.trim() !== ""
                onClicked: {
                    root.addCustom(captureButton.captured, commandField.text);
                    captureButton.captured = "";
                    commandField.text = "";
                }
                contentItem: StyledText {
                    anchors.centerIn: parent
                    text: Translation.tr("Add")
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colPrimary
                }
            }
        }
    }

    ContentSection {
        visible: root.custom.length > 0 || root.removed.length > 0
        icon: "tune"
        title: Translation.tr("Your changes")

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 3

            Repeater {
                model: root.custom

                ConfigRow {
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true
                    implicitHeight: 34

                    StyledText {
                        Layout.preferredWidth: 260
                        text: modelData.keys ?? ""
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: Appearance.colors.colOnSecondaryContainer
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: modelData.command ?? ""
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                        elide: Text.ElideRight
                    }
                    RippleButton {
                        implicitWidth: 100
                        implicitHeight: 28
                        onClicked: root.removeCustom(index)
                        contentItem: StyledText {
                            anchors.centerIn: parent
                            text: Translation.tr("Remove")
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: Appearance.colors.colError
                        }
                    }
                }
            }

            Repeater {
                model: root.removed

                ConfigRow {
                    required property var modelData
                    Layout.fillWidth: true
                    implicitHeight: 34

                    StyledText {
                        Layout.preferredWidth: 260
                        text: modelData
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: ColorUtils.transparentize(Appearance.colors.colOnSurface, 0.5)
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: Translation.tr("switched off")
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                    }
                    RippleButton {
                        implicitWidth: 100
                        implicitHeight: 28
                        onClicked: root.setDisabled(modelData, false)
                        contentItem: StyledText {
                            anchors.centerIn: parent
                            text: Translation.tr("Restore")
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: Appearance.colors.colPrimary
                        }
                    }
                }
            }
        }
    }

    ContentSection {
        icon: "info"
        title: Translation.tr("Changing a built-in shortcut's keys")

        StyledText {
            Layout.fillWidth: true
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colSubtext
            wrapMode: Text.Wrap
            text: Translation.tr("This setup's shortcuts are Lua functions, and Hyprland reports every one of them to the outside world as an opaque callback -- so an existing shortcut's keys cannot be reassigned from a settings screen. Switching one off and adding your own key for the same command gives the same result. The definitions themselves live in:")
        }

        RippleButton {
            Layout.topMargin: 8
            implicitWidth: 340
            implicitHeight: 36
            // Directories.config is a "file://" URL; xdg-open needs a real path,
            // so the button silently did nothing without the trim.
            onClicked: Quickshell.execDetached(["xdg-open",
                `${CF.FileUtils.trimFileProtocol(Directories.config)}/hypr/custom/keybinds.lua`])
            contentItem: StyledText {
                anchors.centerIn: parent
                text: "hypr/custom/keybinds.lua"
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colPrimary
            }
        }
    }
}
