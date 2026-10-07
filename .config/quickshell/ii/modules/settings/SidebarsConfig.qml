import QtQuick
import QtQuick.Layouts
import qs.services
import qs.modules.common
import qs.modules.common.widgets

/**
 * Both sidebars, one page.
 *
 * Left and right are separate sections rather than one flat list, because the
 * two panels are not interchangeable: the right one is the quick-toggle panel
 * (toggles, sliders, notifications) and the left one is the assistant (chat,
 * translator, images). Grouping them means you know which panel a switch acts
 * on without reading the label.
 *
 * The layout section at the top is the only part that touches both: their width
 * and how they are revealed from the screen edge are shared.
 */
ContentPage {
    id: root
    forceWidth: true

    ContentSection {
        icon: "view_sidebar"
        title: Translation.tr("Layout")

        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: 8
            rowSpacing: 4

            ConfigSpinBox {
                Layout.fillWidth: true
                icon: "width"
                text: Translation.tr("Width")
                value: Config.options.sidebar.width
                from: 240
                to: 560
                stepSize: 20
                onValueChanged: Config.options.sidebar.width = value
            }

            ConfigSwitch {
                Layout.fillWidth: true
                buttonIcon: "keep"
                text: Translation.tr("Keep the right sidebar loaded")
                checked: Config.options.sidebar.keepRightSidebarLoaded
                onCheckedChanged: Config.options.sidebar.keepRightSidebarLoaded = checked
                StyledToolTip {
                    text: Translation.tr("Off means it is built when you open it and torn down when you close it, which frees memory but makes the first open slower.")
                }
            }
        }

        ConfigSwitch {
            buttonIcon: "fullscreen"
            text: Translation.tr("Open over fullscreen windows")
            checked: Config.options.sidebar.showInFullscreen
            onCheckedChanged: Config.options.sidebar.showInFullscreen = checked
            StyledToolTip {
                text: Translation.tr("A fullscreen window is drawn above the layer the sidebars normally live in, which is why opening one while a window was fullscreen looked like nothing happened -- it was open, just underneath.\nOn (default): the sidebar is drawn above the fullscreen window.\nOff: back in the normal layer, where a fullscreen window covers it.")
            }
        }

        ContentSubsection {
            title: Translation.tr("Reveal from the screen edge")

            ConfigSwitch {
                // `dock_to_right`, not `screenshot_edge`: the latter is a real
                // Material Symbols name that this font build does not have, so Qt
                // drew the letters -- the switch was labelled "_EDGE". The
                // doctor finds these against the font's own ligature table.
                buttonIcon: "dock_to_right"
                text: Translation.tr("Enable edge reveal")
                checked: Config.options.sidebar.cornerOpen.enable
                onCheckedChanged: Config.options.sidebar.cornerOpen.enable = checked
            }

            ConfigSwitch {
                buttonIcon: "vertical_align_bottom"
                text: Translation.tr("Reveal from the bottom corner")
                checked: Config.options.sidebar.cornerOpen.bottom
                enabled: Config.options.sidebar.cornerOpen.enable
                onCheckedChanged: Config.options.sidebar.cornerOpen.bottom = checked
            }

            ConfigSpinBox {
                icon: "width"
                text: Translation.tr("Hot zone width (px)")
                value: Config.options.sidebar.cornerOpen.cornerRegionWidth
                from: 50
                to: 600
                stepSize: 10
                enabled: Config.options.sidebar.cornerOpen.enable
                onValueChanged: Config.options.sidebar.cornerOpen.cornerRegionWidth = value
            }

            ConfigSpinBox {
                icon: "height"
                text: Translation.tr("Hot zone height (px)")
                value: Config.options.sidebar.cornerOpen.cornerRegionHeight
                from: 1
                to: 40
                stepSize: 1
                enabled: Config.options.sidebar.cornerOpen.enable
                onValueChanged: Config.options.sidebar.cornerOpen.cornerRegionHeight = value
            }
        }
    }

    ContentSection {
        icon: "right_panel_open"
        title: Translation.tr("Right sidebar")

        ContentSubsection {
            title: Translation.tr("Quick toggles")

            ConfigSelectionArray {
                currentValue: Config.options.sidebar.quickToggles.style
                onSelected: newValue => Config.options.sidebar.quickToggles.style = newValue
                options: [
                    { displayName: Translation.tr("Android"), value: "android", icon: "android" },
                    { displayName: Translation.tr("Classic"), value: "classic", icon: "grid_view" },
                ]
            }
        }

        ContentSubsection {
            title: Translation.tr("Sliders")
            tooltip: Translation.tr("The brightness / volume / microphone sliders at the top of the panel")

            ConfigSwitch {
                buttonIcon: "tune"
                text: Translation.tr("Show sliders")
                checked: Config.options.sidebar.quickSliders.enable
                onCheckedChanged: Config.options.sidebar.quickSliders.enable = checked
            }

            GridLayout {
                Layout.fillWidth: true
                columns: 3
                columnSpacing: 8

                ConfigSwitch {
                    Layout.fillWidth: true
                    buttonIcon: "brightness_6"
                    text: Translation.tr("Brightness")
                    checked: Config.options.sidebar.quickSliders.showBrightness
                    enabled: Config.options.sidebar.quickSliders.enable
                    onCheckedChanged: Config.options.sidebar.quickSliders.showBrightness = checked
                }

                ConfigSwitch {
                    Layout.fillWidth: true
                    buttonIcon: "volume_up"
                    text: Translation.tr("Volume")
                    checked: Config.options.sidebar.quickSliders.showVolume
                    enabled: Config.options.sidebar.quickSliders.enable
                    onCheckedChanged: Config.options.sidebar.quickSliders.showVolume = checked
                }

                ConfigSwitch {
                    Layout.fillWidth: true
                    buttonIcon: "mic"
                    text: Translation.tr("Microphone")
                    checked: Config.options.sidebar.quickSliders.showMic
                    enabled: Config.options.sidebar.quickSliders.enable
                    onCheckedChanged: Config.options.sidebar.quickSliders.showMic = checked
                }
            }
        }
    }

    ContentSection {
        icon: "left_panel_open"
        title: Translation.tr("Left sidebar")

        ConfigSwitch {
            buttonIcon: "translate"
            text: Translation.tr("Enable the translator")
            checked: Config.options.sidebar.translator.enable
            onCheckedChanged: Config.options.sidebar.translator.enable = checked
        }

        ConfigSpinBox {
            icon: "timer"
            text: Translation.tr("Translation delay (ms)")
            value: Config.options.sidebar.translator.delay
            from: 0
            to: 2000
            stepSize: 50
            enabled: Config.options.sidebar.translator.enable
            onValueChanged: Config.options.sidebar.translator.delay = value
        }

        ConfigSwitch {
            buttonIcon: "animation"
            text: Translation.tr("Fade in AI replies as they arrive")
            checked: Config.options.sidebar.ai.textFadeIn
            onCheckedChanged: Config.options.sidebar.ai.textFadeIn = checked
        }

        ContentSubsection {
            title: Translation.tr("Image search")

            ConfigSwitch {
                buttonIcon: "mood_bad"
                text: Translation.tr("Allow NSFW results")
                // The image-search sidebar does NOT read
                // Config.options.sidebar.booru.allowNsfw -- it reads
                // Persistent.states.booru.allowNsfw, which is also what its
                // own in-sidebar switch writes. Writing the config key here
                // therefore did nothing at all: the toggle moved, the value
                // saved, and the sidebar carried on filtering as if it were
                // still off. Both stores are written so the setting and the
                // sidebar's own switch agree whichever one moved last.
                checked: Persistent.states.booru.allowNsfw
                onCheckedChanged: {
                    Persistent.states.booru.allowNsfw = checked;
                    Config.options.sidebar.booru.allowNsfw = checked;
                }
            }

            ConfigSpinBox {
                icon: "list"
                text: Translation.tr("Results per page")
                value: Config.options.sidebar.booru.limit
                from: 5
                to: 60
                stepSize: 5
                onValueChanged: Config.options.sidebar.booru.limit = value
            }
        }
    }
}

