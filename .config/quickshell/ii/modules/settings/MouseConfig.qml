import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.services
import qs.modules.common
import qs.modules.common.widgets

/**
 * Bluetooth & devices' "Mouse & touchpad" subsection content, and its own
 * page when opened by slug `mouse`. Backed by InputService, which mirrors the
 * compositor's live input state (hyprctl) rather than a config file -- these
 * are hardware behaviours, not shell preferences.
 */
ContentPage {
    id: root
    forceWidth: true

    ContentSection {
        icon: "mouse"
        title: Translation.tr("Mouse")

        ConfigSlider {
            Layout.fillWidth: true
            buttonIcon: "speed"
            text: Translation.tr("Cursor sensitivity")
            from: 0
            to: 200
            value: InputService.mouseSensitivityPercent
            onValueChanged: InputService.setMouseSensitivityPercent(value)
            StyledToolTip {
                text: Translation.tr("Pointer speed. 100% is neutral; below slows the cursor down, above speeds it up.")
            }
        }

        ConfigSwitch {
            buttonIcon: "swap_horiz"
            text: Translation.tr("Left-handed mouse")
            checked: InputService.leftHanded
            onCheckedChanged: InputService.setLeftHanded(checked)
            StyledToolTip {
                text: Translation.tr("Swaps the primary and secondary mouse buttons.")
            }
        }
    }

    ContentSection {
        icon: "touch_app"
        title: Translation.tr("Touchpad")

        ConfigSwitch {
            buttonIcon: "swap_vert"
            text: Translation.tr("Natural scrolling")
            checked: InputService.naturalScroll
            onCheckedChanged: InputService.setNaturalScroll(checked)
            StyledToolTip {
                text: Translation.tr("Content follows your fingers: two-finger scroll up moves the page up, like a phone.")
            }
        }
        ConfigSlider {
            Layout.fillWidth: true
            buttonIcon: "swipe_vertical"
            text: Translation.tr("Scroll speed")
            from: 0.1
            to: 3.0
            value: InputService.scrollFactor
            onValueChanged: InputService.setScrollFactor(value)
            StyledToolTip {
                text: Translation.tr("How far one finger-swipe scrolls. 1.0 is the libinput default; this desktop ships 0.5 for finer control.")
            }
        }
        ConfigSwitch {
            buttonIcon: "touch_app"
            text: Translation.tr("Tap to click")
            checked: InputService.tapToClick
            onCheckedChanged: InputService.setTapToClick(checked)
        }
        ConfigSwitch {
            buttonIcon: "pan_tool"
            text: Translation.tr("Tap and drag")
            checked: InputService.tapAndDrag
            onCheckedChanged: InputService.setTapAndDrag(checked)
            StyledToolTip {
                text: Translation.tr("A tap followed by holding drags, the way a physical button click-drag would.")
            }
        }
        ConfigSwitch {
            buttonIcon: "keyboard_hide"
            text: Translation.tr("Disable while typing")
            checked: InputService.disableWhileTyping
            onCheckedChanged: InputService.setDisableWhileTyping(checked)
            StyledToolTip {
                text: Translation.tr("Ignores touchpad input for a moment after a keypress, so your palm does not move the cursor while you type.")
            }
        }
    }
}
