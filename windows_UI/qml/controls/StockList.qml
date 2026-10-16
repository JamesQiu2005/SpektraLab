import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The film and print lists (FilmSection.swift `StockList`): one-line rows
// sitting directly on the rail, group captions in the metadata ink, the
// chosen row marked by a white capsule inset from both edges with its text
// in near-black, and the CINE badge after a cinema stock.
//
//   rows          Catalog.filmRows() / paperRows(): `{ name, key, cine,
//                 header, enabled, reason }`; `key` is the controller's
//                 catalogue index
//   currentKey    the chosen row's key
//   highlighted   false keeps the list where it is but draws no capsule
//   editable      false: no row takes a click (settings locked)
//   visibleRows   rows on screen before the list scrolls
//   listObjectName  objectName of the ListView (kept from the first QML)
//   picked(key)   a row was clicked
//
// Every row is `Theme.listRowHeight` tall and the list has no spacing, so a
// scroll position that is a multiple of it starts on a whole row; reveal()
// keeps it that way (no film name half under the section header).
Item {
    id: stock
    property var rows: []
    property int currentKey: -1
    property bool highlighted: true
    property bool editable: true
    property int visibleRows: 9
    property alias listObjectName: list.objectName
    readonly property int rowHeight: Theme.listRowHeight
    signal picked(int key)

    implicitHeight: rowHeight * Math.min(visibleRows, Math.max(1, rows.length))
    implicitWidth: 200
    Layout.fillWidth: true
    Layout.preferredHeight: implicitHeight

    // Brings the current row into view on a whole-row boundary: Contain
    // alone can stop with the top row cut in half under the section header,
    // where it reads as a name drawn over the title.
    function reveal() {
        if (list.currentIndex < 0) return
        list.positionViewAtIndex(list.currentIndex, ListView.Contain)
        var snapped = Math.ceil((list.contentY - list.originY) / rowHeight - 0.001) * rowHeight
        var end = Math.max(0, list.contentHeight + list.bottomMargin - list.height)
        list.contentY = list.originY + Math.min(snapped, end)
    }

    ListView {
        id: list
        anchors.fill: parent
        model: stock.rows
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        // Room after the last row for the list to end on a whole row too.
        bottomMargin: Math.round(height) % stock.rowHeight
        currentIndex: {
            for (var i = 0; i < stock.rows.length; ++i)
                if (!stock.rows[i].header && stock.rows[i].key === stock.currentKey) return i
            return -1
        }
        onCurrentIndexChanged: stock.reveal()
        // The list is one row tall until its rows arrive; a reveal made then
        // would leave it scrolled when it grows. Re-reveal from the top
        // whenever the height or the rows change.
        onCountChanged: Qt.callLater(function() { list.contentY = list.originY; stock.reveal() })
        onHeightChanged: Qt.callLater(function() { list.contentY = list.originY; stock.reveal() })
        ScrollBar.vertical: ScrollBar {
            id: scrollBar
            width: 6
            policy: list.contentHeight > list.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
            contentItem: Rectangle { implicitWidth: 3; radius: 1.5; color: Theme.dim; opacity: scrollBar.active ? 0.9 : 0.5 }
        }
        delegate: Item {
            id: row
            required property var modelData
            required property int index
            readonly property bool header: modelData.header === true
            readonly property bool selected: !header && stock.highlighted && modelData.key === stock.currentKey
            readonly property bool usable: !header && modelData.enabled !== false
            width: list.width; height: stock.rowHeight

            Rectangle {
                x: Theme.stockLeadingInset
                width: row.width - Theme.stockLeadingInset - Theme.stockTrailingInset
                height: Theme.stockSelectionHeight
                anchors.verticalCenter: parent.verticalCenter
                radius: height / 2
                color: row.selected ? Theme.selection : rowMouse.containsMouse && row.usable && stock.editable ? Theme.hover : "transparent"
            }
            Text {
                x: row.header ? Theme.stockTextInset - 1 : Theme.stockTextInset
                anchors.verticalCenter: parent.verticalCenter
                width: row.width - x - Theme.stockTrailingInset - (row.modelData.cine ? Theme.cinePillWidth + 6 : 4)
                text: row.modelData.name
                elide: Text.ElideRight
                color: row.header ? Theme.dim : row.selected ? Theme.selectionInk : Theme.secondaryText
                opacity: row.header || row.usable ? 1 : Theme.disabledOpacity
                font.family: Theme.fontFamily
                font.pixelSize: row.header ? Theme.fontLabel : Theme.fontSmall
                font.weight: Theme.weightText
            }
            CinePill {
                visible: row.modelData.cine === true
                inverted: row.selected
                anchors.verticalCenter: parent.verticalCenter
                x: row.width - Theme.stockTrailingInset - width - 4
                opacity: row.usable ? 1 : Theme.disabledOpacity
            }
            MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                enabled: !row.header
                cursorShape: row.usable && stock.editable ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: if (row.usable && stock.editable) stock.picked(row.modelData.key)
            }
            ToolTip.visible: rowMouse.containsMouse && !row.usable && !row.header && String(row.modelData.reason || "").length > 0
            ToolTip.text: String(row.modelData.reason || "")
            ToolTip.delay: 500
        }
    }
}
