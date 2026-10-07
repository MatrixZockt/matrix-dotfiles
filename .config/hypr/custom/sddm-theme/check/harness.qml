import QtQuick
import QtQml

Rectangle {
    width: 1280; height: 800; color: "black"

    // --- fake context objects (what the real greeter injects) ---
    QtObject {
        id: fakeSddm
        signal loginFailed()
        signal informationMessage(string message)
        function login(u, p, s) { console.log("[harness] sddm.login", u, "***", s) }
        function powerOff() { console.log("[harness] powerOff") }
        function reboot() { console.log("[harness] reboot") }
        function suspend() { console.log("[harness] suspend") }
        property bool canPowerOff: true
        property bool canReboot: true
        property bool canSuspend: true
    }
    ListModel {
        id: fakeUsers
        ListElement { name: "matrix"; realName: "matrix"; avatar: "" }
        ListElement { name: "other"; realName: "Other User"; avatar: "" }
    }
    QtObject {
        id: fakeSessions
        property int index: 0
        property int lastIndex: 0
    }
    QtObject {
        id: fakeKeyboard
        property var layouts: [ { shortName: "us", longName: "English (US)" },
                                { shortName: "de", longName: "German" } ]
        property int currentLayout: 0
    }

    // expose under the names the theme reads
    property alias sddm: fakeSddm
    property alias userModel: fakeUsers
    property alias sessionModel: fakeSessions
    property alias keyboard: fakeKeyboard
    property var config: ({ "background": "background.png", "surface": "#141314" })

    Loader {
        id: themeLoader
        anchors.fill: parent
        source: "Main.qml"
        onStatusChanged: (status) => {
            if (status === Loader.Error) console.log("[harness] RESULT: LOAD ERROR")
            else if (status === Loader.Ready) console.log("[harness] RESULT: LOADED OK")
        }
    }
    Component.onCompleted: console.log("[harness] engine started")
}
