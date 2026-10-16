import QtQuick

// The grip on a rail's inner edge (PanelResize.swift `PanelResizeHandle`):
// an invisible strip wider than the line it stands for, an accent line while
// the pointer is on it, a drag measured from the width the drag started at
// (accumulating onto the live width would make the rail run away from the
// pointer, and lag it after a bound), and a double-click back to standard.
//
//   railWidth        the rail's current width
//   growsRight       true for the left rail (its grip is on its right edge:
//                    dragging right widens it); false for the right rail
//   resized(width)   the wanted width; the owner clamps it
//   resetRequested() a double-click: back to the standard width
//
// Placed by its owner across the rail's inner edge, Theme.resizeHandleWidth
// wide and full height.
Item {
    id: handle
    property real railWidth: 0
    property bool growsRight: true
    signal resized(real width)
    signal resetRequested()
    width: Theme.resizeHandleWidth

    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        width: 1; height: parent.height
        color: Theme.accent
        opacity: area.containsMouse || area.pressed ? 0.8 : 0
        Behavior on opacity { NumberAnimation { duration: 120 } }
    }
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.SizeHorCursor
        property real startWidth: 0
        property real startX: 0
        onPressed: function(mouse) { startWidth = handle.railWidth; startX = handle.mapToItem(null, mouse.x, 0).x }
        onPositionChanged: function(mouse) {
            if (!pressed) return
            var dx = handle.mapToItem(null, mouse.x, 0).x - startX
            handle.resized(startWidth + (handle.growsRight ? dx : -dx))
        }
        onDoubleClicked: handle.resetRequested()
    }
}
