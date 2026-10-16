import QtQuick
import QtQuick.Controls

// One naming chip (ExportPage.swift tokenChip): the token's word on a capsule,
// the accent when it is in the filename and the drawing's grey plate when it
// is not. A click switches it (the last one on refuses, NamingRule.toggle);
// dragging it onto another chip moves it there, which is the filename's order.
//
//   token, label, on, last   the chip's model
//   toggled()                a click
//   moved(token, before)     dropped onto the chip `before`
Item {
    id: chip
    property string token
    property string label
    property bool on: false
    property bool last: false
    signal toggled()
    signal moved(string token, string before)
    implicitWidth: plate.implicitWidth
    implicitHeight: 17

    Rectangle {
        id: plate
        implicitWidth: word.implicitWidth + 12
        width: implicitWidth; height: chip.height
        radius: height / 2
        color: chip.on ? Theme.accent : "#686969"
        border.width: drop.containsDrag ? 1 : 0
        border.color: Theme.text
        opacity: dragArea.drag.active ? 0.6 : 1
        Drag.active: dragArea.drag.active
        Drag.keys: ["spektralab-token"]
        Drag.mimeData: { "text/plain": chip.token }
        Drag.hotSpot.x: width / 2; Drag.hotSpot.y: height / 2
        property string token: chip.token
        Text {
            id: word
            anchors.centerIn: parent
            text: chip.label
            color: chip.on ? Theme.card : Theme.text
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta + 1; font.weight: Theme.weightText
        }
    }
    z: dragArea.drag.active ? 10 : 0
    MouseArea {
        id: dragArea
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        drag.target: plate
        hoverEnabled: true
        onClicked: chip.toggled()
        onReleased: {
            if (drag.active) plate.Drag.drop()
            plate.x = 0; plate.y = 0
        }
        ToolTip.visible: containsMouse && !drag.active
        ToolTip.delay: 600
        ToolTip.text: chip.on && chip.last ? L10n.tr("export.naming.lastPart")
                    : chip.on ? L10n.tr("export.naming.remove", [chip.label]) : L10n.tr("export.naming.add", [chip.label])
    }
    DropArea {
        id: drop
        anchors.fill: parent
        keys: ["spektralab-token"]
        onDropped: function(event) {
            const moving = event.source && event.source.token !== undefined ? event.source.token : ""
            if (moving.length > 0 && moving !== chip.token) chip.moved(moving, chip.token)
            event.accept()
        }
    }
}
