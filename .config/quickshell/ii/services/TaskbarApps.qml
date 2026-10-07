pragma Singleton

import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Wayland

Singleton {
    id: root

    function isPinned(appId) {
        return Config.options.dock.pinnedApps.indexOf(appId) !== -1;
    }

    function togglePin(appId) {
        if (root.isPinned(appId)) {
            Config.options.dock.pinnedApps = Config.options.dock.pinnedApps.filter(id => id !== appId)
        } else {
            Config.options.dock.pinnedApps = Config.options.dock.pinnedApps.concat([appId])
        }
    }

    // Reordering by dragging. `appId` lands in `targetIndex` of the order the dock
    // is showing. Everything that is already pinned keeps its pin; the dragged
    // entry is pinned where it landed, because an order is only remembered for
    // pinned entries. Windows that stay unpinned simply follow the pinned ones.
    function moveTo(appId, targetIndex) {
        const order = [];
        for (const entry of root.apps)
            order.push(entry.appId);
        const from = order.indexOf(appId);
        if (from === -1)
            return;
        // The remembered order only covers pinned entries: windows that are merely
        // open always sit after them. So the drop slot is clamped to the pinned
        // block -- dragging a window into that block pins it where it landed, and
        // dragging a pinned icon past a window keeps it inside the block instead of
        // jumping back the moment the pointer is released.
        const pinnedCount = order.filter(id => root.isPinned(id)).length;
        const to = Math.max(0, Math.min(pinnedCount, targetIndex));
        if (from === to)
            return;
        order.splice(to, 0, order.splice(from, 1)[0]);
        Config.options.dock.pinnedApps = order.filter(id => root.isPinned(id) || id === appId);
    }

    property list<var> apps: {
        var map = new Map();

        // Pinned apps
        const pinnedApps = Config.options?.dock.pinnedApps ?? [];
        for (const appId of pinnedApps) {
            if (!map.has(appId.toLowerCase())) map.set(appId.toLowerCase(), ({
                pinned: true,
                toplevels: []
            }));
        }

        // Ignored apps
        const ignoredRegexStrings = Config.options?.dock.ignoredAppRegexes ?? [];
        const ignoredRegexes = ignoredRegexStrings.map(pattern => new RegExp(pattern, "i"));
        // Open windows — only from the current workspace (special workspaces are
        // always shown too). Pinned apps stay in the dock, but windows on other
        // desktops never create or feed an entry.
        //
        // Workspace matching goes through HyprlandData.clientForToplevel(): a
        // Quickshell toplevel (freedesktop foreign-toplevel management) has NO
        // workspace property, so `toplevel.workspace?.id` was always undefined and
        // the old filter silently rejected every window. The overview matches
        // toplevels to hyprctl clients the same way, via the Hyprland address.
        const currentWorkspaceId = HyprlandData.activeWorkspace?.id ?? -1;
        for (const toplevel of ToplevelManager.toplevels.values) {
            if (ignoredRegexes.some(re => re.test(toplevel.appId))) continue;
            const client = HyprlandData.clientForToplevel(toplevel);
            const wsId = client?.workspace?.id;
            const onCurrentDesktop = wsId === currentWorkspaceId;
            const inSpecialWorkspace = client?.workspace?.name?.startsWith("special:") ?? false;
            if (!onCurrentDesktop && !inSpecialWorkspace) continue;
            if (!map.has(toplevel.appId.toLowerCase())) map.set(toplevel.appId.toLowerCase(), ({
                pinned: false,
                toplevels: []
            }));
            map.get(toplevel.appId.toLowerCase()).toplevels.push(toplevel);
        }

        var values = [];

        for (const [key, value] of map) {
            values.push(appEntryComp.createObject(null, { appId: key, toplevels: value.toplevels, pinned: value.pinned }));
        }

        return values;
    }

    component TaskbarAppEntry: QtObject {
        id: wrapper
        required property string appId
        required property list<var> toplevels
        required property bool pinned
    }
    Component {
        id: appEntryComp
        TaskbarAppEntry {}
    }
}
