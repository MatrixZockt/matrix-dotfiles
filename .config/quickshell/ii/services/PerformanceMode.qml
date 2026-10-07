pragma Singleton

import QtQuick
import Quickshell
import qs.modules.common

/**
 * Interface performance mode.
 *
 * A look-preserving, behaviour-preserving switch for the *motion budget*: with
 * it on, Hyprland's animations are off and the desktop's hand-played motion
 * (the fullscreen -> anchored glide, the finger-following close-drag) cuts
 * straight to the end instead of running a dispatch per frame. The theme, the
 * layout, the popups and every gesture stay exactly as they are.
 *
 * Persisted in the shell config (`performanceMode`), and applied by
 * scripts/performance/apply.sh -- the ONLY writer of
 * ~/.config/hypr/custom/performance.lua, so the UI never hand-writes Hyprland
 * config (the same contract the keyboard layouts use). Nothing else needs to
 * know how it is applied: the compositor reads that file, and the config's own
 * Lua reads the flag it sets.
 */
Singleton {
    id: root

    readonly property bool enabled: Config.options?.performanceMode === true

    function setEnabled(on) {
        const next = on === true;
        if (root.enabled === next)
            return;
        Config.options.performanceMode = next;
        // Explicit value, not a read-back: the config write is debounced, so
        // the script would otherwise read the value it just replaced.
        Quickshell.execDetached([
            "bash", "-c",
            `'${Directories.performanceApplyScriptPath}' ${next ? "on" : "off"}`
        ]);
    }

    function toggle() {
        root.setEnabled(!root.enabled);
    }
}
