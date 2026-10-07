import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions as CF

/**
 * Windows-Settings "Accessibility" (slug `general`): the settings that change
 * how the desktop reads and moves, for eyes, ears and hands. What was on this
 * page before (audio, battery, time, language, policies) moved to the pages
 * whose Windows names they belong to (Sound, Display, Time & language);
 * the work-safety toggles stayed because they change what you SEE.
 */
ContentPage {
    id: root
    forceWidth: true

    ContentSection {
        icon: "text_fields"
        title: Translation.tr("Text & display")

        ConfigSlider {
            Layout.fillWidth: true
            buttonIcon: "format_size"
            text: Translation.tr("Text size")
            from: 0.8
            to: 1.4
            value: Config.options?.appearance?.textScale ?? 1.0
            onValueChanged: Config.options.appearance.textScale = value
            StyledToolTip {
                text: Translation.tr("Scales interface text. 100% is the default; this affects every shell surface, not apps.")
            }
        }

        ConfigSwitch {
            buttonIcon: "animations"
            text: Translation.tr("Reduce motion")
            checked: (Config.options?.battery?.powerMode ?? "") === "performance"
            onCheckedChanged: {
                // Same mechanism as the Power page: one switch, three jobs
                // (profile, shell motion, compositor animations).
                Config.options.battery.powerMode = checked ? "performance" : "default";
                PowerMode.apply(Config.options.battery.powerMode);
            }
            StyledToolTip {
                text: Translation.tr("Cuts animations down everywhere -- shell, compositor and windows. Also available as the Performance power mode on the Display page.")
            }
        }
    }

    ContentSection {
        icon: "mouse"
        title: Translation.tr("Mouse & touchpad")

        ConfigRow {
            StyledText {
                Layout.fillWidth: true
                text: Translation.tr("Cursor speed, tap-to-click, natural scrolling and friends live on their own page.")
                color: Appearance.colors.colOnLayer2
                font.pixelSize: Appearance.font.pixelSize.smaller
                wrapMode: Text.Wrap
            }
        }
        RippleButton {
            Layout.fillWidth: false
            implicitWidth: 220
            implicitHeight: 38
            buttonRadius: Appearance.rounding.small
            colBackground: Appearance.colors.colPrimaryContainer
            onClicked: SettingsNav.request("mouse", "")
            contentItem: RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 8
                MaterialSymbol {
                    text: "mouse"
                    iconSize: 18
                    color: Appearance.colors.colOnPrimaryContainer
                }
                StyledText {
                    text: Translation.tr("Open Mouse & touchpad")
                    color: Appearance.colors.colOnPrimaryContainer
                    font.pixelSize: Appearance.font.pixelSize.small
                }
            }
        }
    }

    ContentSection {
        icon: "music_note"
        title: Translation.tr("Sound cues")

        ConfigRow {
            uniform: true
            ConfigSwitch {
                buttonIcon: "battery_full"
                text: Translation.tr("Battery")
                checked: Config.options.sounds.battery
                onCheckedChanged: Config.options.sounds.battery = checked
            }
            ConfigSwitch {
                buttonIcon: "av_timer"
                text: Translation.tr("Pomodoro")
                checked: Config.options.sounds.pomodoro
                onCheckedChanged: Config.options.sounds.pomodoro = checked
            }
        }
    }

    ContentSection {
        icon: "work_alert"
        title: Translation.tr("Work safety")

        ConfigSwitch {
            buttonIcon: "assignment"
            text: Translation.tr("Hide clipboard images copied from sussy sources")
            checked: Config.options.workSafety.enable.clipboard
            onCheckedChanged: Config.options.workSafety.enable.clipboard = checked
        }
        ConfigSwitch {
            buttonIcon: "wallpaper"
            text: Translation.tr("Hide sussy/anime wallpapers")
            checked: Config.options.workSafety.enable.wallpaper
            onCheckedChanged: Config.options.workSafety.enable.wallpaper = checked
        }
    }
}
