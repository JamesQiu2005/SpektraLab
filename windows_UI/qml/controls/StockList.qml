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
    // Every row is this tall and the list has no spacing, so a scroll position
    // that is a multiple of it starts on a whole row.
    readonly property int rowHeight: 27
    signal picked(int key)
    Layout.fillWidth: true; spacing: 3

    // Brings the current row into view on a whole-row boundary. Contain alone
    // stops where the current row's bottom meets the list's bottom: with the
    // list 174 px tall and Portra 400 seventh of the negatives, that left the
    // first row cut in half directly under the group header, where it read as
    // a film name drawn over the title. Rounding the position down the list
    // keeps the current row whole (its top is a row multiple at or below the
    // old position) and leaves any partial row at the bottom, which reads as
    // "more below" instead.
    function reveal() {
        if (list.currentIndex < 0) return
        list.positionViewAtIndex(list.currentIndex, ListView.Contain)
        var snapped = Math.ceil((list.contentY - list.originY) / rowHeight - 0.001) * rowHeight
        var end = Math.max(0, list.contentHeight + list.bottomMargin - list.height)
        list.contentY = list.originY + Math.min(snapped, end)
    }

    Text { visible: stock.title.length > 0; text: stock.title; color: Theme.muted; font.pixelSize: 10; font.bold: true }
    ListView {
        id: list
        Layout.fillWidth: true; Layout.preferredHeight: stock.listHeight
        model: stock.rows; clip: true
        // Room after the last row for the list to end on a whole row too
        // (the visible height less a whole number of rows): without it the
        // fully scrolled list would cut its top row again.
        bottomMargin: Math.round(height) % stock.rowHeight
        currentIndex: {
            for (var i = 0; i < stock.rows.length; ++i)
                if (stock.rows[i].key === stock.currentKey) return i
            return -1
        }
        onCurrentIndexChanged: stock.reveal()
        onCountChanged: Qt.callLater(function() { stock.reveal() })
        ScrollBar.vertical: ScrollBar {}
        delegate: Rectangle {
            id: row
            required property var modelData
            readonly property bool selected: stock.highlighted && modelData.key === stock.currentKey
            width: list.width; height: stock.rowHeight; radius: 4
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
