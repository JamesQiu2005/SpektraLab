import QtQuick
import SpektraLab.Native 1.0

// The crop editor over the canvas: the uncropped source with everything
// outside `editor.draftCrop` dimmed, a rule-of-thirds frame, and the drag that
// draws the crop. A drag starting outside the picture passes through; a drag
// too small to mean anything restores the committed crop.
Item {
    id: cropOverlay
    objectName: "cropOverlay"
    required property FrameCanvas canvas
    required property EditorState editor
    anchors.fill: canvas
    visible: editor.cropMode
    readonly property rect imageBox: canvas ? canvas.imageRect : Qt.rect(0, 0, 0, 0)
    readonly property rect selectionBox: Qt.rect(imageBox.x + editor.draftCrop.x * imageBox.width, imageBox.y + editor.draftCrop.y * imageBox.height, editor.draftCrop.width * imageBox.width, editor.draftCrop.height * imageBox.height)
    Rectangle { x: cropOverlay.imageBox.x; y: cropOverlay.imageBox.y; width: cropOverlay.imageBox.width; height: Math.max(0, cropOverlay.selectionBox.y - y); color: "#99000000" }
    Rectangle { x: cropOverlay.imageBox.x; y: cropOverlay.selectionBox.y + cropOverlay.selectionBox.height; width: cropOverlay.imageBox.width; height: Math.max(0, cropOverlay.imageBox.y + cropOverlay.imageBox.height - y); color: "#99000000" }
    Rectangle { x: cropOverlay.imageBox.x; y: cropOverlay.selectionBox.y; width: Math.max(0, cropOverlay.selectionBox.x - x); height: cropOverlay.selectionBox.height; color: "#99000000" }
    Rectangle { x: cropOverlay.selectionBox.x + cropOverlay.selectionBox.width; y: cropOverlay.selectionBox.y; width: Math.max(0, cropOverlay.imageBox.x + cropOverlay.imageBox.width - x); height: cropOverlay.selectionBox.height; color: "#99000000" }
    Rectangle {
        x: cropOverlay.selectionBox.x; y: cropOverlay.selectionBox.y; width: cropOverlay.selectionBox.width; height: cropOverlay.selectionBox.height
        color: "transparent"; border.color: Theme.accent; border.width: 1
        Rectangle { x: parent.width / 3; width: 1; height: parent.height; color: "#70ffffff" }
        Rectangle { x: parent.width * 2 / 3; width: 1; height: parent.height; color: "#70ffffff" }
        Rectangle { y: parent.height / 3; height: 1; width: parent.width; color: "#70ffffff" }
        Rectangle { y: parent.height * 2 / 3; height: 1; width: parent.width; color: "#70ffffff" }
    }
    MouseArea {
        anchors.fill: parent; enabled: cropOverlay.editor.canEditCrop; cursorShape: Qt.CrossCursor
        property point origin
        property bool drawing: false
        function normalized(x, y) {
            return Qt.point(Math.max(0, Math.min(1, (x - cropOverlay.imageBox.x) / cropOverlay.imageBox.width)), Math.max(0, Math.min(1, (y - cropOverlay.imageBox.y) / cropOverlay.imageBox.height)))
        }
        function updateCrop(x, y) {
            var p = normalized(x, y)
            cropOverlay.editor.draftCrop = Qt.rect(Math.min(origin.x, p.x), Math.min(origin.y, p.y), Math.abs(p.x - origin.x), Math.abs(p.y - origin.y))
        }
        onPressed: function(mouse) {
            var b = cropOverlay.imageBox
            if (mouse.x < b.x || mouse.y < b.y || mouse.x > b.x + b.width || mouse.y > b.y + b.height) { mouse.accepted = false; return }
            origin = normalized(mouse.x, mouse.y); drawing = true
        }
        onPositionChanged: function(mouse) { if (drawing) updateCrop(mouse.x, mouse.y) }
        onReleased: function(mouse) {
            if (!drawing) return
            updateCrop(mouse.x, mouse.y); drawing = false
            if (cropOverlay.editor.draftCrop.width > 0.003 && cropOverlay.editor.draftCrop.height > 0.003) cropOverlay.editor.finishCrop()
            else cropOverlay.editor.draftCrop = preview.cropRect
        }
        onCanceled: { drawing = false; cropOverlay.editor.draftCrop = preview.cropRect }
    }
}
