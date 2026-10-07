import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

/**
 * Keyboard layouts.
 *
 * The list of enabled layouts is stored in the shell config
 * (`keyboard.layouts`) and turned into ~/.config/hypr/custom/keyboard.lua by
 * scripts/keyboard/apply.sh, which also reloads Hyprland. That keeps a single
 * source of truth and means this page never writes Hyprland config itself.
 *
 * The order of `enabledLayouts` is the order you cycle through them, so the
 * first one is the one you boot into.
 */
ContentPage {
    id: root
    forceWidth: true

    // `code` is the xkb code Hyprland wants in kb_layout.
    readonly property var availableLayouts: [
        { code: "de", name: "German" },
        { code: "us", name: "English (US)" },
        { code: "gb", name: "English (UK)" },
        { code: "fr", name: "French" },
        { code: "es", name: "Spanish" },
        { code: "it", name: "Italian" },
        { code: "nl", name: "Dutch" },
        { code: "pt", name: "Portuguese" },
        { code: "br", name: "Portuguese (Brazil)" },
        { code: "pl", name: "Polish" },
        { code: "cz", name: "Czech" },
        { code: "sk", name: "Slovak" },
        { code: "hu", name: "Hungarian" },
        { code: "ro", name: "Romanian" },
        { code: "tr", name: "Turkish" },
        { code: "se", name: "Swedish" },
        { code: "no", name: "Norwegian" },
        { code: "dk", name: "Danish" },
        { code: "fi", name: "Finnish" },
        { code: "ch", name: "Swiss" },
        { code: "ru", name: "Russian" },
        { code: "gr", name: "Greek" },
        { code: "jp", name: "Japanese" },
        { code: "kr", name: "Korean" },
    ]

    readonly property var enabledLayouts: {
        const stored = Config.options?.keyboard?.layouts;
        return Array.isArray(stored) ? stored.slice() : [];
    }

    function applyLayouts(list) {
        // The script is the single writer: it stores the list in the config and
        // regenerates the Hyprland file from it. The UI deliberately does not
        // write the config itself, so this can't half-apply. The list only ever
        // contains xkb codes, which the script re-validates anyway.
        Quickshell.execDetached(["bash", "-c",
            `'${Directories.keyboardApplyScriptPath}' --layouts '${list.join(",")}'`]);
    }

    function toggleLayout(code, enabled) {
        let list = enabledLayouts;
        if (enabled) {
            if (list.indexOf(code) === -1) list.push(code);
        } else {
            list = list.filter(item => item !== code);
        }
        // Refuse to end up with no layout at all -- that would leave the user
        // unable to type.
        if (list.length === 0) return;
        applyLayouts(list);
    }

    function moveLayout(code, delta) {
        let list = enabledLayouts;
        const from = list.indexOf(code);
        const to = from + delta;
        if (from === -1 || to < 0 || to >= list.length) return;
        list.splice(to, 0, list.splice(from, 1)[0]);
        applyLayouts(list);
    }

    ContentSection {
        icon: "keyboard"
        title: Translation.tr("Keyboard layouts")

        StyledText {
            Layout.fillWidth: true
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colSubtext
            wrapMode: Text.Wrap
            text: Translation.tr("Pick every layout you want available. The first one enabled is the one you start with, and Alt+Shift cycles through the rest. The lock screen also shows the active layout in its bottom-right corner.")
        }

        ConfigRow {
            StyledText {
                Layout.fillWidth: true
                text: Translation.tr("Active layout")
                font.pixelSize: Appearance.font.pixelSize.normal
                color: Appearance.colors.colOnSecondaryContainer
            }
            StyledText {
                text: HyprlandXkb.currentLayoutName || HyprlandXkb.currentLayoutCode || "—"
                font.pixelSize: Appearance.font.pixelSize.normal
                color: Appearance.colors.colOnSecondaryContainer
            }
        }
    }

    ContentSection {
        icon: "list"
        title: Translation.tr("Available")

        Flow {
            Layout.fillWidth: true
            spacing: 6

            Repeater {
                model: root.availableLayouts

                ConfigSwitch {
                    required property var modelData
                    width: 250
                    buttonIcon: root.enabledLayouts.indexOf(modelData.code) !== -1 ? "keyboard" : "keyboard_alt"
                    text: modelData.name
                    checked: root.enabledLayouts.indexOf(modelData.code) !== -1
                    onClicked: root.toggleLayout(modelData.code, !checked)
                }
            }
        }
    }

    ContentSection {
        icon: "reorder"
        title: Translation.tr("Order")

        StyledText {
            Layout.fillWidth: true
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colSubtext
            wrapMode: Text.Wrap
            text: Translation.tr("Alt+Shift cycles in this order. The top entry is the default layout at login.")
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4

            Repeater {
                model: root.enabledLayouts

                ConfigRow {
                    required property var modelData
                    required property var index
                    Layout.fillWidth: true

                    StyledText {
                        Layout.fillWidth: true
                        text: `${index + 1}.  ${modelData}`
                        font.pixelSize: Appearance.font.pixelSize.normal
                        color: Appearance.colors.colOnSecondaryContainer
                    }
                    RippleButton {
                        implicitWidth: 40
                        implicitHeight: 32
                        enabled: index > 0
                        onClicked: root.moveLayout(modelData, -1)
                        contentItem: MaterialSymbol {
                            anchors.centerIn: parent
                            text: "arrow_upward"
                            iconSize: 18
                        }
                    }
                    RippleButton {
                        implicitWidth: 40
                        implicitHeight: 32
                        enabled: index < root.enabledLayouts.length - 1
                        onClicked: root.moveLayout(modelData, 1)
                        contentItem: MaterialSymbol {
                            anchors.centerIn: parent
                            text: "arrow_downward"
                            iconSize: 18
                        }
                    }
                }
            }
        }
    }

    // ── Time (moved from the old General page) ────────────────────────
    Process {
        id: translationProc
        property string locale: ""
        command: [Directories.aiTranslationScriptPath, translationProc.locale]
    }

    ContentSection {
        icon: "schedule"
        title: Translation.tr("Time")

        ConfigSwitch {
            buttonIcon: "pace"
            text: Translation.tr("Second precision")
            checked: Config.options.time.secondPrecision
            onCheckedChanged: Config.options.time.secondPrecision = checked
            StyledToolTip {
                text: Translation.tr("Enable if you want clocks to show seconds accurately")
            }
        }

        ContentSubsection {
            title: Translation.tr("Format")

            ConfigSelectionArray {
                currentValue: Config.options.time.format
                onSelected: newValue => Config.options.time.format = newValue
                options: [
                    { displayName: Translation.tr("24h"), value: "hh:mm" },
                    { displayName: Translation.tr("12h am/pm"), value: "h:mm ap" },
                    { displayName: Translation.tr("12h AM/PM"), value: "h:mm AP" }
                ]
            }
        }
    }

    // ── Language (moved from the old General page) ────────────────────
    ContentSection {
        icon: "language"
        title: Translation.tr("Language")

        ContentSubsection {
            title: Translation.tr("Interface Language")
            tooltip: Translation.tr("Select the language for the user interface.\n\"Auto\" will use your system's locale.")

            StyledComboBox {
                id: languageSelector
                buttonIcon: "language"
                textRole: "displayName"

                model: [{
                    displayName: Translation.tr("Auto (System)"),
                    value: "auto"
                }].concat(Translation.allAvailableLanguages.map(lang => ({
                    displayName: lang,
                    value: lang
                })))

                currentIndex: {
                    const index = model.findIndex(item => item.value === Config.options.language.ui);
                    return index !== -1 ? index : 0;
                }

                onActivated: index => {
                    Config.options.language.ui = model[index].value;
                }
            }
        }
        ContentSubsection {
            title: Translation.tr("Generate translation with Gemini")
            tooltip: Translation.tr("You'll need to enter your Gemini API key first.\nType /key on the sidebar for instructions.")

            ConfigRow {
                MaterialTextArea {
                    id: localeInput
                    Layout.fillWidth: true
                    placeholderText: Translation.tr("Locale code, e.g. fr_FR, de_DE, zh_CN...")
                    text: Config.options.language.ui === "auto" ? Qt.locale().name : Config.options.language.ui
                }
                RippleButtonWithIcon {
                    id: generateTranslationBtn
                    Layout.fillHeight: true
                    nerdIcon: "\uf023"
                    enabled: !translationProc.running || (translationProc.locale !== localeInput.text.trim())
                    mainText: enabled ? Translation.tr("Generate\nTypically takes 2 minutes") : Translation.tr("Generating...\nDon't close this window!")
                    onClicked: {
                        translationProc.locale = localeInput.text.trim();
                        translationProc.running = false;
                        translationProc.running = true;
                    }
                }
            }
        }
    }

    // ── Policies (moved from the old General page) ────────────────────
    ContentSection {
        icon: "rule"
        title: Translation.tr("Policies")

        ConfigRow {
            ColumnLayout {
                ContentSubsectionLabel {
                    text: Translation.tr("AI")
                }
                ConfigSelectionArray {
                    currentValue: Config.options.policies.ai
                    onSelected: newValue => Config.options.policies.ai = newValue
                    options: [
                        { displayName: Translation.tr("No"), icon: "close", value: 0 },
                        { displayName: Translation.tr("Yes"), icon: "check", value: 1 },
                        { displayName: Translation.tr("Local only"), icon: "cloud_done", value: 2 }
                    ]
                }
            }
            ColumnLayout {
                ContentSubsectionLabel {
                    text: Translation.tr("Weeb")
                }
                ConfigSelectionArray {
                    currentValue: Config.options.policies.weeb
                    onSelected: newValue => Config.options.policies.weeb = newValue
                    options: [
                        { displayName: Translation.tr("No"), icon: "close", value: 0 },
                        { displayName: Translation.tr("Yes"), icon: "check", value: 1 },
                        { displayName: Translation.tr("Closet"), icon: "ev_shadow", value: 2 }
                    ]
                }
            }
        }
    }
}
