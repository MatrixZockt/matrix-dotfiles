import QtQuick
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.services
import qs.modules.common as C

NestableObject {
    id: root

    required property HyprlandMonitor monitor
    readonly property var liveMonitorData: HyprlandData.monitors.find(m => m.id === monitor.id)
    readonly property Toplevel activeWindow: ToplevelManager.activeToplevel
    readonly property int activeWorkspace: monitor?.activeWorkspace?.id ?? 1
    // An empty workspace you are standing on is a "fake" workspace: it only exists
    // because you focused it, and Hyprland will remove it as soon as you leave.
    // This is read from Hyprland's own window count rather than the toplevel
    // activation flag, which lags and made a desktop with windows look empty.
    readonly property bool currentWorkspaceNotFake: (HyprlandData.workspaceById[root.activeWorkspace]?.windows ?? 0) > 0
    readonly property int fakeWorkspace: currentWorkspaceNotFake ? -9999 : activeWorkspace
    readonly property int group: 0 // Unused now that the bar shows a dynamic list

    // Workspaces on this monitor that actually hold windows. This reads Hyprland's
    // own window count per workspace (the same data `hyprctl workspaces` reports)
    // rather than quickshell's workspace toplevel model, which does not always
    // populate and made the bar think every desktop except the current one was
    // empty. Hyprland already destroys a regular workspace once it is left empty,
    // so this list is exactly "the desktops that have something on them".
    // A workspace id the bar is allowed to show. The lock screen parks the
    // session on a sentinel workspace (2147483647 - N) while locked, and the
    // monitor model reports it RAW -- injecting it here rendered a phantom
    // desktop tile that looked like a window had jumped to a desktop nobody
    // had ("Freebuff randomly jumping to desktop 9"). HyprlandData already
    // sanitises its own list to 1..100; the bar must apply the same rule to
    // every id it touches, MONITOR ACTIVE WORKSPACE INCLUDED.
    function isSaneWorkspaceId(id) {
        return id >= 1 && id <= 100;
    }

    readonly property var occupiedIds: HyprlandData.workspaces
        .filter(ws => root.isWorkspaceOnThisMonitor(ws))
        .filter(ws => (ws.windows ?? 0) > 0)
        .map(ws => ws.id)
        .sort((a, b) => a - b)

    function isWorkspaceOnThisMonitor(ws) {
        if (!(ws && root.isSaneWorkspaceId(ws.id)))
            return false;
        if (!root.monitor)
            return true;
        if (ws.monitorID === undefined)
            return true;
        return ws.monitorID === root.monitor.id;
    }

    // What the bar renders: every occupied desktop, plus exactly one empty slot to
    // the right. That trailing slot is the "new desktop" affordance -- focusing it
    // creates the workspace, and if you leave it empty again Hyprland removes it,
    // so the bar can never fill up with unused desktops. While you are standing on
    // that empty desktop it *is* the new one, so no extra slot is added.
    readonly property var shownIds: {
        const ids = root.occupiedIds.slice();
        if (root.isSaneWorkspaceId(root.activeWorkspace) && ids.indexOf(root.activeWorkspace) === -1)
            ids.push(root.activeWorkspace);
        ids.sort((a, b) => a - b);
        const last = ids.length > 0 ? ids[ids.length - 1] : 0;
        const standingOnEmpty = !root.currentWorkspaceNotFake && root.activeWorkspace === last;
        if (!standingOnEmpty)
            ids.push(last + 1);
        return ids;
    }
    readonly property int shownCount: Math.max(1, root.shownIds.length)

    readonly property var occupied: root.shownIds.map(id =>
        (HyprlandData.workspaceById[id]?.windows ?? 0) > 0)

    readonly property var biggestWindow: root.shownIds.map(id =>
        HyprlandData.biggestWindowForWorkspace(id))

    // ── Window-layout map (the bar's desktop tiles) ──────────────────────
    // Per shown desktop, how its real windows are arranged: "empty",
    // "one", "twoCol", "twoRow" (a pair's orientation is read off the
    // actual client geometry -- side-by-side vs stacked), or "three"
    // (three or more → tall block + two halves). The bar draws the
    // miniature from this; opening/closing windows reclassifies and the
    // tile's blocks morph.
    readonly property var layoutOf: root.shownIds.map(id => {
        const wins = HyprlandData.windowList.filter(w => (w.workspace?.id ?? -1) === id);
        const n = wins.length;
        if (n <= 0)
            return "empty";
        if (n === 1)
            return "one";
        if (n === 2) {
            const a = wins[0], b = wins[1];
            const ax = a.at?.[0] ?? 0, aw = a.size?.[0] ?? 0;
            if (aw > 0 && (b.at?.[0] ?? 0) >= ax + aw * 0.5)
                return "twoCol";
            const ay = a.at?.[1] ?? 0, ah = a.size?.[1] ?? 0;
            if (ah > 0 && (b.at?.[1] ?? 0) >= ay + ah * 0.5)
                return "twoRow";
            return "twoCol";
        }
        return "three";
    })

    readonly property var specialWorkspace: liveMonitorData?.specialWorkspace
    readonly property string specialWorkspaceName: specialWorkspace?.name.replace("special:", "") ?? "special"
    readonly property bool specialWorkspaceActive: specialWorkspaceName !== ""

    function getWorkspaceIdAt(index) {
        return root.shownIds[index] ?? root.shownIds[root.shownIds.length - 1] ?? 1;
    }
}
