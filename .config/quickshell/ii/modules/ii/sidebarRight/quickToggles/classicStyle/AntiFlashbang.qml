import qs.services
import qs.modules.common
import qs.modules.common.widgets

/**
 * The anti-flashbang switch for the classic toggle row: a three-way switch, the
 * same as the Android toggle. Each left click steps weak -> strong -> off ->
 * weak, and the icon says which step is active.
 *
 * Both strengths only dim a blank-white frame (weak to 0.85, strong to 0.75);
 * neither turns white content grey, so strong is simply the stronger setting.
 *
 * The state shown is read back from the compositor by
 * services/HyprlandAntiFlashbangShader.qml, so an icon that says "on" means the
 * shader is actually loaded, not that it was asked for.
 */
QuickToggleButton {
    buttonIcon: !HyprlandAntiFlashbangShader.enabled ? "flash_on"
        : (HyprlandAntiFlashbangShader.weak ? "sunny_snowing" : "flash_off")
    toggled: HyprlandAntiFlashbangShader.enabled
    onClicked: HyprlandAntiFlashbangShader.toggle()

    StyledToolTip {
        text: HyprlandAntiFlashbangShader.enabled
            ? (HyprlandAntiFlashbangShader.weak
                ? Translation.tr("Anti-flashbang: Weak | Left-click: strong")
                : Translation.tr("Anti-flashbang: Strong | Left-click: off"))
            : Translation.tr("Anti-flashbang: Off | Left-click: weak")
    }
}
