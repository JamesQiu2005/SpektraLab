import QtQuick
import QtQuick.Controls

// The Mac's checkbox (ScrubSlider.swift `CheckBox`): a 10 px square with a
// 1 px edge, filled with the accent when on; off is an empty box in the
// metadata ink, so an unchecked option is quieter than its label.
//
//   checked        the state to draw -- bound to the model, never toggled here
//   toggledTo(on)  the click's request; the caller writes the model and the
//                  binding brings `checked` back, so undo and photo switches
//                  can never leave the box showing a stale state
//   available, reason, toolTip   as every rail control (IconButton.qml)
//
// The ink is 10 px; the target is Theme.hitTarget square around it.
Item {
    id: root
    property bool checked: false
    property bool available: true
    property string reason
    property string toolTip
    signal toggledTo(bool on)
    implicitWidth: Theme.hitTarget; implicitHeight: Theme.hitTarget
    opacity: available ? 1 : Theme.disabledOpacity

    Rectangle {
        anchors.centerIn: parent
        width: Theme.checkSize; height: Theme.checkSize
        radius: 1
        color: "transparent"
        border.width: 1
        border.color: root.checked ? Theme.accent : Theme.dim
        Rectangle {
            anchors.fill: parent; anchors.margins: 2
            radius: 0.5
            visible: root.checked
            color: Theme.accent
        }
    }
    MouseArea {
        anchors.fill: parent
        enabled: root.available
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggledTo(!root.checked)
    }
    HoverHandler { id: hover }
    readonly property string hint: root.available ? root.toolTip : root.reason
    ToolTip.visible: hover.hovered && hint.length > 0
    ToolTip.text: hint
    ToolTip.delay: 500
}
