import QtQuick
import QtQuick.Controls
import QtQuick.Shapes
import SpektraLab.Native 1.0

// The half-frame pair's marks on the canvas (Canvas/PairOverlay.swift): a + on
// an empty hole (the way a frame gets in), the picked hole's frame in the
// selection frame's ink (dashed while its picture is being cropped), and --
// in the crop mode -- how to finish. The canvas draws the piece; this draws
// what is said about it.
//
// The pointer, as on the Mac (MetalCanvasView): a click picks the hole under
// it, anywhere else on the piece the film (the canvas keeps its pan: the tap
// only watches); a right click picks the hole and opens its menu -- Replace,
// Crop, Turn, Reset Crop, Remove, Open Alone, then the piece's Swap and Turn
// the Camera. In the crop mode a drag moves the picked frame's picture under
// its hole and the wheel scales it about the pointer; until its develop lands
// the hole shows the developed picture moved the way the gesture has it
// (PairDragPreview). Ctrl+J is New Half-Frame Pair (Session.newPair).
Item {
    id: overlay
    objectName: "pairOverlay"
    required property FrameCanvas canvas
    required property EditorState editor
    anchors.fill: canvas
    readonly property var pair: preview.pair
    readonly property bool shown: pair.active === true && pair.shown === true && !editor.cropMode
    visible: shown
    readonly property rect box: canvas ? canvas.imageRect : Qt.rect(0, 0, 0, 0)
    readonly property bool placing: pair.placing === true

    function normalised(px, py) {
        return Qt.point((px - box.x) / Math.max(1, box.width), (py - box.y) / Math.max(1, box.height))
    }
    function viewRect(r) {
        if (!r) return Qt.rect(0, 0, 0, 0)
        return Qt.rect(box.x + r.x * box.width, box.y + r.y * box.height, r.width * box.width, r.height * box.height)
    }
    function holeAt(px, py) { var n = normalised(px, py); return preview.pairHoleAt(n.x, n.y) }
    function holeOf(side) { var h = pair.holes || []; return side === "first" ? h[0] : side === "second" ? h[1] : null }

    Shortcut { sequence: "Ctrl+J"; enabled: preview.canMakePair && overlay.editor.canBrowse; onActivated: preview.newPair() }
    Shortcut { sequences: ["Escape", "Return", "Enter"]; enabled: overlay.shown && overlay.placing; onActivated: preview.setPairPlacing(false) }

    // A click picks; a right click picks and opens the hole's menu. Both only
    // watch the pointer, so a drag still pans the canvas.
    TapHandler {
        enabled: overlay.shown && !overlay.placing
        acceptedButtons: Qt.LeftButton
        onTapped: function(point) { var n = overlay.normalised(point.position.x, point.position.y); preview.pairClicked(n.x, n.y) }
    }
    TapHandler {
        enabled: overlay.shown
        acceptedButtons: Qt.RightButton
        onTapped: function(point) {
            var n = overlay.normalised(point.position.x, point.position.y)
            if (!overlay.placing) preview.pairClicked(n.x, n.y)
            holeMenu.popup()
        }
    }

    Repeater {
        model: overlay.pair.holes || []
        Item {
            id: hole
            required property var modelData
            required property int index
            readonly property rect r: overlay.viewRect(modelData.rect)
            readonly property bool picked: overlay.pair.layer === modelData.side
            readonly property var drag: overlay.pair.drag
            readonly property bool moving: drag !== undefined && drag.active === true && drag.side === modelData.side
            x: r.x; y: r.y; width: r.width; height: r.height
            objectName: "pairHole_" + modelData.side

            // The gesture's picture: the developed hole moved as the gesture
            // has it, on the unexposed film it uncovers.
            Item {
                anchors.fill: parent
                visible: hole.moving
                clip: true
                Rectangle { anchors.fill: parent; color: "black" }
                Item {
                    x: -hole.x; y: -hole.y
                    width: overlay.width; height: overlay.height
                    transform: [
                        Scale { origin.x: hole.x; origin.y: hole.y; xScale: hole.moving ? hole.drag.scale : 1; yScale: hole.moving ? hole.drag.scale : 1 },
                        Translate { x: hole.moving ? hole.drag.offsetX * hole.width : 0; y: hole.moving ? hole.drag.offsetY * hole.height : 0 }
                    ]
                    FrameCanvas {
                        anchors.fill: parent
                        image: preview.previewImage
                        follow: overlay.canvas
                        enabled: false
                    }
                }
            }
            // The picked hole's frame: the selection frame's own ink.
            Rectangle {
                anchors.fill: parent
                visible: hole.picked && !overlay.placing
                color: "transparent"
                border.width: 1.5
                border.color: Theme.selectionFrame
                objectName: "pairPickedFrame"
            }
            Shape {
                anchors.fill: parent
                visible: hole.picked && overlay.placing
                ShapePath {
                    strokeColor: Theme.selectionFrame; strokeWidth: 1.5; fillColor: "transparent"
                    strokeStyle: ShapePath.DashLine; dashPattern: [4, 2.7]
                    startX: 0.75; startY: 0.75
                    PathLine { x: hole.width - 0.75; y: 0.75 }
                    PathLine { x: hole.width - 0.75; y: hole.height - 0.75 }
                    PathLine { x: 0.75; y: hole.height - 0.75 }
                    PathLine { x: 0.75; y: 0.75 }
                }
            }
            // An empty hole: the way a frame gets in.
            Item {
                visible: hole.modelData.filled !== true
                anchors.centerIn: parent
                width: Math.max(Math.min(hole.width, 160), 60); height: Math.max(Math.min(hole.height, 120), 60)
                Column {
                    anchors.centerIn: parent
                    spacing: 8
                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 44; height: 44; radius: 22
                        color: addMouse.containsMouse ? Qt.rgba(0.976, 0.969, 0.953, 0.24) : Qt.rgba(0.976, 0.969, 0.953, 0.14)
                        Text {
                            anchors.centerIn: parent
                            text: Icons.add
                            font.family: Theme.iconFamily; font.pixelSize: 18
                            color: Theme.text
                        }
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: L10n.tr("pair.addFrameShort")
                        color: Theme.secondaryText
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel; font.weight: Theme.weightText
                    }
                }
                MouseArea {
                    id: addMouse
                    objectName: "pairAdd_" + hole.modelData.side
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: preview.settingsEditable
                    onClicked: { preview.setPairLayer(hole.modelData.side); picker.openFor(hole.modelData.side) }
                }
                ToolTip.visible: addMouse.containsMouse
                ToolTip.text: L10n.tr("pair.addFrameHelp")
                ToolTip.delay: 600
            }
        }
    }

    // The crop mode inside a hole: the drag and the wheel are the picture's.
    MouseArea {
        anchors.fill: parent
        enabled: overlay.shown && overlay.placing
        visible: enabled
        acceptedButtons: Qt.LeftButton
        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        preventStealing: true
        property bool dragging: false
        onPressed: function(mouse) {
            var n = overlay.normalised(mouse.x, mouse.y)
            dragging = preview.beginPairDrag(n.x, n.y)
            if (!dragging) {
                // A press on the other hole picks it; the gap ends nothing.
                var side = preview.pairHoleAt(n.x, n.y)
                if (side.length > 0) preview.setPairLayer(side)
            }
        }
        onPositionChanged: function(mouse) {
            if (!dragging) return
            var n = overlay.normalised(mouse.x, mouse.y)
            preview.movePairDrag(n.x, n.y)
        }
        onReleased: { if (dragging) preview.endPairDrag(); dragging = false }
        onCanceled: { if (dragging) preview.endPairDrag(); dragging = false }
        onWheel: function(wheel) {
            var n = overlay.normalised(wheel.x, wheel.y)
            var notches = (wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.pixelDelta.y / 2) / 120
            preview.zoomPairPlacement(Math.pow(1.1, notches), n.x, n.y)
        }
    }

    // What the gestures are, and the way out (PairOverlay.swift cropBar).
    Rectangle {
        visible: overlay.placing
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom; anchors.bottomMargin: 14
        height: 34; radius: 17
        width: barRow.implicitWidth + 28
        color: Qt.rgba(0.176, 0.176, 0.173, 0.94)
        Row {
            id: barRow
            anchors.centerIn: parent
            spacing: 10
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: L10n.tr("pair.cropHint")
                color: Theme.text
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel; font.weight: Theme.weightText
            }
            PillButton {
                anchors.verticalCenter: parent.verticalCenter
                text: L10n.tr("pair.done")
                onClicked: preview.setPairPlacing(false)
            }
        }
    }

    PairFramePicker { id: picker }

    RailMenu {
        id: holeMenu
        readonly property var picked: overlay.holeOf(overlay.pair.layer)
        RailMenuItem {
            text: holeMenu.picked && holeMenu.picked.filled ? L10n.tr("pair.menu.replace") : L10n.tr("pair.menu.add")
            enabled: !!(holeMenu.picked !== null && holeMenu.picked !== undefined && preview.settingsEditable)
            onTriggered: picker.openFor(holeMenu.picked.side)
        }
        RailMenuItem {
            text: overlay.placing ? L10n.tr("pair.menu.doneCropping") : L10n.tr("pair.menu.crop")
            enabled: !!(holeMenu.picked && holeMenu.picked.filled === true && holeMenu.picked.exists === true)
            onTriggered: preview.setPairPlacing(!overlay.placing)
        }
        RailMenuItem {
            text: L10n.tr("pair.menu.turnPicture")
            enabled: !!(holeMenu.picked && holeMenu.picked.filled === true && preview.settingsEditable)
            onTriggered: preview.turnPairPicture(holeMenu.picked.side)
        }
        RailMenuItem {
            text: L10n.tr("pair.menu.resetCrop")
            enabled: !!(holeMenu.picked && holeMenu.picked.filled === true && preview.settingsEditable &&
                     (holeMenu.picked.placement.scale !== 1 || holeMenu.picked.placement.x !== 0 ||
                      holeMenu.picked.placement.y !== 0 || holeMenu.picked.placement.quarterTurns !== 0))
            onTriggered: preview.resetPairPlacement(holeMenu.picked.side)
        }
        RailMenuItem {
            text: L10n.tr("pair.menu.remove")
            enabled: !!(holeMenu.picked && holeMenu.picked.filled === true && preview.settingsEditable)
            onTriggered: preview.removePairFrame(holeMenu.picked.side)
        }
        RailMenuItem {
            text: L10n.tr("pair.menu.openAlone")
            enabled: !!(holeMenu.picked && holeMenu.picked.exists === true && overlay.editor.canBrowse)
            onTriggered: preview.openPairFrameAlone(holeMenu.picked.side)
        }
        MenuSeparator {}
        RailMenuItem {
            text: L10n.tr("pair.menu.swap")
            enabled: (overlay.pair.filled || 0) > 0 && preview.settingsEditable
            onTriggered: preview.swapPairFrames()
        }
        RailMenuItem {
            text: overlay.pair.turned ? L10n.tr("pair.menu.holdLevel") : L10n.tr("pair.menu.turnCamera")
            enabled: preview.settingsEditable
            onTriggered: preview.setPairTurned(!overlay.pair.turned)
        }
        MenuSeparator {}
        RailMenuItem {
            text: L10n.tr("pair.menu.fit")
            enabled: !overlay.editor.zoomLocked
            onTriggered: overlay.editor.resetView(true)
        }
        RailMenuItem {
            text: L10n.tr("pair.menu.export")
            enabled: overlay.pair.complete === true && overlay.editor.canExport
            onTriggered: overlay.editor.openExport()
        }
    }
}
