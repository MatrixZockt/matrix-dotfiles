pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.modules.waffle.looks

GridLayout {
    id: root

    columns: 4

    Component {
        id: aggAppCatComp
        AggregatedAppCategoryModel {}
    }

    // ORDER IS PRIORITY. Each entry is assigned to the first category that
    // claims it, so the group an app lands in is decided here and nowhere
    // else. "Disk & Storage" sits above "Utilities & Tools" on purpose: the
    // disk tools declare `Utility` as well as `Filesystem`, and a file about
    // disk usage has no business being filed under a generic toolbox.
    property list<AggregatedAppCategoryModel> aggregatedCategories: [
        aggAppCatComp.createObject(null, {
            name: Translation.tr("Productivity"),
            categories: ["Development", "Education", "Network", "Office"]
        }), aggAppCatComp.createObject(null, {
            name: Translation.tr("Disk & Storage"),
            categories: ["Filesystem", "DiskUtility"],
            extraIds: [
                "org.gnome.baobab", "btrfs-assistant", "limine-snapper-restore",
                "gnome-disks", "gparted", "org.gnome.baobab", "baobab"
            ]
        }), aggAppCatComp.createObject(null, {
            name: Translation.tr("Utilities & Tools"),
            categories: ["Utility", "Science"]
        }), aggAppCatComp.createObject(null, {
            name: Translation.tr("Creativity"),
            categories: ["AudioVideo", "Graphics"]
        }), aggAppCatComp.createObject(null, {
            name: Translation.tr("System"),
            categories: ["Settings", "System"]
        }), aggAppCatComp.createObject(null, {
            name: Translation.tr("Other"),
            categories: ["Game"]
        }),
    ]

    // One pass over the catalogue, one claim per entry. `claimed` is what stops
    // an app with several categories from being drawn in several groups.
    function assignEntries(categories) {
        const claimed = new Set();
        for (const category of categories) {
            const matches = Array.from(DesktopEntries.applications.values).filter(app => {
                if (claimed.has(app.id))
                    return false;
                const byCategory = (app.categories ?? []).some(cat => category.categories.indexOf(cat) !== -1);
                const byId = (category.extraIds ?? []).indexOf(app.id) !== -1;
                return byCategory || byId;
            }).sort((a, b) => String(a.name).localeCompare(String(b.name)));
            for (const entry of matches)
                claimed.add(entry.id);
            category.assignedEntries = matches;
        }
    }

    onAggregatedCategoriesChanged: assignEntries(aggregatedCategories)
    Component.onCompleted: assignEntries(aggregatedCategories)
    // The catalogue fills in asynchronously, so the first assignment pass can
    // run against an empty list and leave every category blank. This is the
    // signal that the entries actually arrived.
    Connections {
        target: DesktopEntries
        function onApplicationsChanged() {
            const __t = Date.now();
            assignEntries(root.aggregatedCategories);
            const __d = Date.now() - __t;
            if (__d > 15) console.log("[slow] allAppsAssign " + __d + "ms");
        }
    }

    Repeater {
        model: root.aggregatedCategories
        delegate: AppCategory {
            required property var modelData
            aggregatedCategory: modelData
        }
    }

    columnSpacing: 27
    rowSpacing: 12
    component AppCategory: Item {
        id: categoryItem
        property AggregatedAppCategoryModel aggregatedCategory
        implicitWidth: categoryLayout.implicitWidth
        implicitHeight: categoryLayout.implicitHeight
        ColumnLayout {
            id: categoryLayout
            anchors.fill: parent
            spacing: 4

            AppCategoryGrid {
                id: categoryGrid
                Layout.fillWidth: true
                aggregatedCategory: categoryItem.aggregatedCategory
            }

            WButton {
                id: categoryButton
                Layout.fillWidth: true
                implicitHeight: 32

                contentItem: WText {
                    id: categoryButtonText
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    text: categoryItem.aggregatedCategory.name
                }
                onClicked: {
                    categoryGrid.openCategoryFolder();
                }
            }
        }
    }
}
