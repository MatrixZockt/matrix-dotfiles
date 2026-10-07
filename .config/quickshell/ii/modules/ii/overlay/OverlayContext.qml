pragma Singleton
pragma ComponentBehavior: Bound
import Quickshell

Singleton {
    id: root
    
    signal requestCenter(string identifier)

    // Identifier of a widget that should centre itself the moment it is
    // created. Set by `overlay reveal <id>` (the launcher's Task Manager entry,
    // the keybind): opening the machine monitor is a fresh request to see it,
    // and restoring the position from a drag three days ago is indistinguishable
    // from "it opened wrong".
    //
    // A flag rather than the requestCenter signal, because the widget does not
    // exist yet when the request arrives -- a signal would be delivered to
    // nobody. The widget reads this as it is created and clears it.
    property string centerOnOpenIdentifier: ""

    // Which device the hardware monitor should be showing when it comes up, in
    // the Resources card's own vocabulary: "cpu", "memory", "swap",
    // "gpu:<name>", "disk:<name>", "net:<name>".
    //
    // The settings app's Overview tiles set this: clicking the RAM tile asks for
    // the task manager "on that hardware", which is only true if the card opens
    // already pointed at it. Empty means "whatever was selected last", which is
    // what a bare Task Manager click wants.
    //
    // Same flag-not-signal reasoning as above, with one addition: the card may
    // ALSO already exist (the overlay was open, or the card is pinned), so the
    // widget watches this property as well as reading it on creation.
    property string requestedDeviceKey: ""

    readonly property list<var> availableWidgets: [
        { identifier: "crosshair", materialSymbol: "point_scan" },
        { identifier: "fpsLimiter", materialSymbol: "animation" },
        { identifier: "floatingImage", materialSymbol: "imagesmode" },
        { identifier: "recorder", materialSymbol: "screen_record" },
        { identifier: "resources", materialSymbol: "monitoring" },
        { identifier: "notes", materialSymbol: "note_stack" },
        { identifier: "volumeMixer", materialSymbol: "volume_up" },
    ]
    
    readonly property bool hasPinnedWidgets: root.pinnedWidgetIdentifiers.length > 0

    property list<string> pinnedWidgetIdentifiers: []
    property list<var> clickableWidgets: []

    function pin(identifier: string, pin = true) {
        if (pin) {
            if (!root.pinnedWidgetIdentifiers.includes(identifier)) {
                root.pinnedWidgetIdentifiers.push(identifier)
            }
        } else {
            root.pinnedWidgetIdentifiers = root.pinnedWidgetIdentifiers.filter(id => id !== identifier)
        }
    }

    function registerClickableWidget(widget: var, clickable = true) {
        if (clickable) {
            if (!root.clickableWidgets.includes(widget)) {
                root.clickableWidgets.push(widget)
            }
        } else {
            root.clickableWidgets = root.clickableWidgets.filter(w => w !== widget)
        }
    }
}
