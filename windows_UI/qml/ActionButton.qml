import QtQuick
import QtQuick.Controls
Button {
    id: root
    property bool accented: false
    padding: 9
    font.pixelSize: 12
    hoverEnabled: true
    contentItem: Text {
        text: root.text; color: root.enabled ? Theme.text : "#777773"
        font: root.font; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
    }
    background: Rectangle {
        radius: 3
        color: root.down ? "#686762" : root.hovered ? "#585752" : root.accented ? "#645039" : Theme.well
        border.width: root.accented ? 1 : 0
        border.color: Theme.accent
    }
}
