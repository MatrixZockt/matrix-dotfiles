import QtQuick
TextInput {
    property color borderColor: "black"
    property color focusColor: "black"
    property color hoverColor: "black"
    property color textColor: "black"
    property real radius: 0
    property bool tooltipEnabled: false
    color: textColor
    echoMode: TextInput.Password
}
