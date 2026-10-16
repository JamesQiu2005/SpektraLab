import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// One stock list -- a film group or the papers: an optional group header over
// a scrolling list of rows `{ name, key }`, where `key` is the controller's
// catalogue index (preview.filmIndex / preview.paperIndex). The list keeps the
// row whose key is `currentKey` in view; `highlighted: false` keeps that
// position but draws no selection (the papers while a slide film is chosen,
// whose paper choice is remembered for the next negative).
ColumnLayout {
    id: stock
    property string title
    property var rows: []
    property int currentKey: -1
    property bool highlighted: true
    property bool editable: true
    property real listHeight: 174
    // Kept on the ListView itself, where the single-file Main.qml had them.
    property alias listObjectName: list.objectName
    signal picked(int key)
    Layout.fillWidth: true; spacing: 3
    Text { visible: stock.title.length > 0; text: stock.title; color: Theme.muted; font.pixelSize: 10; font.bold: true }
    ListView {
        id: list
        Layout.fillWidth: true; Layout.preferredHeight: stock.listHeight
        model: stock.rows; clip: true
        currentIndex: {
            for (var i = 0; i < stock.rows.length; ++i)
                if (stock.rows[i].key === stock.currentKey) return i
            return -1
        }
        onCurrentIndexChanged: { if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain) }
        onCountChanged: Qt.callLater(function() { if (list.currentIndex >= 0) list.positionViewAtIndex(list.currentIndex, ListView.Contain) })
        ScrollBar.vertical: ScrollBar {}
        delegate: Rectangle {
            id: row
            required property var modelData
            readonly property bool selected: stock.highlighted && modelData.key === stock.currentKey
            width: list.width; height: 27; radius: 4
            color: selected ? Theme.selection : rowMouse.containsMouse && rowMouse.enabled ? "#41413e" : "transparent"
            Text {
                anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 6
                verticalAlignment: Text.AlignVCenter; text: row.modelData.name
                color: row.selected ? Theme.selectionText : stock.editable ? Theme.text : Theme.muted
                font.pixelSize: 10; elide: Text.ElideRight
            }
            MouseArea { id: rowMouse; anchors.fill: parent; hoverEnabled: true; enabled: stock.editable; onClicked: stock.picked(row.modelData.key) }
        }
    }
}
