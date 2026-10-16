import QtQuick
import QtQuick.Controls

// A capsule button, in the Mac's two shapes:
//
//   filled (default)  the rail's one button shape -- the Navigator's Fit, the
//                     clipboard's Sync: a ground-coloured capsule with the
//                     small label face (NavigatorSection.swift)
//   outlined          Process / Original on the tool bar (TopBar.swift): no
//                     plate, a 1 px outline and the largest type in the
//                     window, accent while `active`, metadata ink otherwise.
//                     A muted outline is not a disabled one; `available`
//                     carries that.
//
//   text, active, outlined
//   available, reason, toolTip   as IconButton (the root keeps hover so a
//                     greyed button still says why)
//   clicked()         a click while available
Item {
    id: root
    property string text
    property bool outlined: false
    property bool active: false
    property bool available: true
    property string reason
    property string toolTip
    signal clicked()
    implicitHeight: outlined ? Theme.actionHeight : Theme.controlHeight
    implicitWidth: Math.max(outlined ? 76 : 36, label.implicitWidth + (outlined ? 18 : 24))
    opacity: available ? 1 : Theme.disabledOpacity

    Rectangle {
        anchors.fill: parent
        radius: root.outlined ? Theme.actionRadius : height / 2
        color: root.outlined ? (mouse.containsMouse && root.available ? Theme.hover : "transparent")
                             : (mouse.containsMouse && root.available ? "#686866" : Theme.pill)
        border.width: root.outlined ? 1 : 0
        border.color: root.active ? Theme.accent : Theme.dim
    }
    Text {
        id: label
        anchors.centerIn: parent
        text: root.text
        color: root.outlined ? (root.active ? Theme.accent : Theme.dim) : Theme.text
        font.family: Theme.fontFamily
        font.pixelSize: root.outlined ? Theme.fontAction : Theme.fontSmall
        font.weight: root.outlined ? Theme.weightTitle : Theme.weightText
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        enabled: root.available
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
    HoverHandler { id: hover }
    readonly property string hint: root.available ? root.toolTip : root.reason
    ToolTip.visible: hover.hovered && hint.length > 0
    ToolTip.text: hint
    ToolTip.delay: 500
}
