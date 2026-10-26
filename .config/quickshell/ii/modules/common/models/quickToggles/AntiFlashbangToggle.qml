import QtQuick
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

/**
 * The anti-flashbang switch in the right sidebar's quick toggles.
 *
 * It is a three-way switch, not an on/off: every left click steps weak ->
 * strong -> off -> weak. Both strengths are dims of a blank-white frame, not
 * grey washes -- weak takes it to 0.85, strong to 0.75 -- so strong is the
 * "more" setting rather than a different look. The icon says which step is
 * active.
 *
 * It owns nothing: the shader itself lives in
 * services/HyprlandAntiFlashbangShader.qml and the choice is persisted there.
 */
QuickToggleModel {
    name: HyprlandAntiFlashbangShader.enabled
        ? (HyprlandAntiFlashbangShader.weak ? Translation.tr("Anti-flash: Weak") : Translation.tr("Anti-flash: Strong"))
        : Translation.tr("Anti-flashbang")
    tooltipText: HyprlandAntiFlashbangShader.enabled
        ? (HyprlandAntiFlashbangShader.weak
            ? `${Translation.tr("Anti-flashbang")}: ${Translation.tr("Weak")} | ${Translation.tr("Left-click: strong")}`
            : `${Translation.tr("Anti-flashbang")}: ${Translation.tr("Strong")} | ${Translation.tr("Left-click: off")}`)
        : `${Translation.tr("Anti-flashbang")}: ${Translation.tr("Off")} | ${Translation.tr("Left-click: weak")}`
    icon: HyprlandAntiFlashbangShader.enabled
        ? (HyprlandAntiFlashbangShader.weak ? "sunny_snowing" : "flash_off")
        : "flash_on"
    toggled: HyprlandAntiFlashbangShader.enabled

    mainAction: () => HyprlandAntiFlashbangShader.toggle()
}
