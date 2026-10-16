import QtQuick
import QtQuick.Controls

// A text button in the accent (the Mac's `.buttonStyle(.plain)` captions in
// Settings and `.link` buttons in About): "Reset All Layout", "Show in
// Explorer", a source URL. Underlined while hovered, as a Windows link is.
//
//   text, available, reason, toolTip   as PillButton
//   clicked()
Text {
    id: link
    property bool available: true
    property string reason
    property string toolTip
    signal clicked()
    color: Theme.accent
    opacity: available ? 1 : Theme.disabledOpacity
    font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
    font.underline: area.containsMouse && available
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        enabled: link.available
        cursorShape: Qt.PointingHandCursor
        onClicked: link.clicked()
    }
    HoverHandler { id: hover }
    readonly property string hint: link.available ? link.toolTip : link.reason
    ToolTip.visible: hover.hovered && hint.length > 0
    ToolTip.text: hint
    ToolTip.delay: 500
}
