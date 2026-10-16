import QtQuick
import QtQuick.Controls

// One command of the application menu: a RailMenuItem with its keyboard
// shortcut at the trailing edge in the metadata ink, as a Windows menu shows
// it. The shortcut itself is a Shortcut in Main.qml; this only names it, so
// the menu and the key can never do two different things -- both call the
// same function.
//
//   text, enabled, triggered()   MenuItem's own
//   shortcutText                 "Ctrl+O"; empty for none
RailMenuItem {
    id: command
    property string shortcutText
    rightPadding: 16 + (shortcutText.length > 0 ? keys.implicitWidth + 24 : 0)
    Text {
        id: keys
        anchors.right: parent.right; anchors.rightMargin: 14
        anchors.verticalCenter: parent.verticalCenter
        visible: command.shortcutText.length > 0
        text: command.shortcutText
        color: Theme.dim
        opacity: command.enabled ? 1 : Theme.disabledOpacity
        font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
    }
}
