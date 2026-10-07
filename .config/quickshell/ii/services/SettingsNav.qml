pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

/**
 * Where the settings app is being asked to open.
 *
 * Two ways in, one place to read them:
 *
 *   * a launch asks for a page with an environment variable
 *     (`QS_SETTINGS_PAGE=network QS_SETTINGS_SECTION=wifi …`), which is what the
 *     app's first frame uses, and
 *   * a request to a copy that is ALREADY open arrives over IPC (`request`
 *     below) and has to be able to arrive at any moment, not only at startup.
 *
 * Without the second half, "open the Wi-Fi tab" means starting a second copy of
 * the app: clicking the bar's Wi-Fi icon and then its Bluetooth icon left two
 * settings windows stacked on top of each other, which is exactly what this
 * desktop used to do. See scripts/launch/settings.sh -- it is the one caller
 * that decides between "talk to the copy that exists" and "start one".
 *
 * A page listens for the signal rather than reading the property, because a
 * page that is already on screen has to be walked to another tab *now*, and a
 * binding alone would not tell it that a request happened (the request may name
 * the tab it is already showing).
 */
Singleton {
    id: root

    // The page the app should be on -- a page `slug` (settings.qml's `pages`),
    // never a translated name. Empty means "wherever it was left".
    property string requestedPage: Quickshell.env("QS_SETTINGS_PAGE") ?? ""
    // And the tab inside a page that holds more than one thing: the Network
    // page carries Wi-Fi and Bluetooth. Empty means the page's own default.
    property string requestedSection: Quickshell.env("QS_SETTINGS_SECTION") ?? ""

    signal pageRequested(string page)
    signal sectionRequested(string section)

    // A page asking for the task manager -- the settings app's other face.
    // The Overview hardware tiles used to launch the standalone task manager
    // app for this; since the app converts between the two faces in place,
    // the request is a signal on the same hub as the deep links, and the app
    // root answers it by converting the card.
    signal taskManagerRequested(string key)

    function requestTaskManager(key) {
        root.taskManagerRequested(key ?? "");
    }

    function request(page, section) {
        if (page && page.length > 0) {
            root.requestedPage = page;
            root.pageRequested(page);
        }
        if (section && section.length > 0) {
            root.requestedSection = section;
            root.sectionRequested(section);
        }
    }
}
