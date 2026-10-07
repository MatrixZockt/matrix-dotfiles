import QtQuick
import Quickshell
import qs.services

QtObject {
    property string name
    property list<string> categories
    // Entries that belong here by exact ID rather than by category. For
    // categories that mean something narrower than the freedesktop registry
    // defines ("Disk & Storage" is not a registered category, and only
    // baobab declares `Filesystem` on this machine).
    readonly property list<string> extraIds: []
    // Filled in by the grid that owns this model, so every entry lands in
    // exactly ONE category. See AllAppsGrid for why that is not optional.
    property list<DesktopEntry> assignedEntries: []
}
