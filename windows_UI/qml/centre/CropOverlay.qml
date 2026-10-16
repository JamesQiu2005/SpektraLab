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
    // While a film edge holds the crop at its gate (preview.cropLockRatio,
    // source width / height) a drawn rectangle keeps the gate's shape, and a
    // drag that starts inside the crop moves the picture under the gate
    // (FilmEdgeSection.swift: "the picture moves under a gate fixed at the
    // format's aspect"); the move commits on release, as a drawn crop does.
    readonly property real lockRatio: preview.cropLockRatio
    MouseArea {
        anchors.fill: parent; enabled: cropOverlay.editor.canEditCrop
        cursorShape: moving ? Qt.ClosedHandCursor : Qt.CrossCursor
        property point origin
        property bool drawing: false
        property bool moving: false
        property rect startCrop
        function normalized(x, y) {
            return Qt.point(Math.max(0, Math.min(1, (x - cropOverlay.imageBox.x) / cropOverlay.imageBox.width)), Math.max(0, Math.min(1, (y - cropOverlay.imageBox.y) / cropOverlay.imageBox.height)))
        }
        function updateCrop(x, y) {
            var p = normalized(x, y)
            if (moving) {
                var c = startCrop
                cropOverlay.editor.draftCrop = Qt.rect(Math.max(0, Math.min(1 - c.width, c.x + p.x - origin.x)),
                                                       Math.max(0, Math.min(1 - c.height, c.y + p.y - origin.y)), c.width, c.height)
                return
            }
            if (cropOverlay.lockRatio > 0) {
                // The gate's shape in screen pixels: the image box keeps the
                // source's aspect, so the source ratio holds there too.
                var b = cropOverlay.imageBox
                var dx = (p.x - origin.x) * b.width, dy = (p.y - origin.y) * b.height
                var w = Math.abs(dx), h = Math.abs(dy)
                if (w > h * cropOverlay.lockRatio) h = w / cropOverlay.lockRatio; else w = h * cropOverlay.lockRatio
                var room = Math.min(1, ((dx >= 0 ? 1 - origin.x : origin.x) * b.width) / Math.max(w, 1e-6),
                                    ((dy >= 0 ? 1 - origin.y : origin.y) * b.height) / Math.max(h, 1e-6))
                var nw = w * room / b.width, nh = h * room / b.height
                cropOverlay.editor.draftCrop = Qt.rect(dx >= 0 ? origin.x : origin.x - nw, dy >= 0 ? origin.y : origin.y - nh, nw, nh)
                return
            }
            cropOverlay.editor.draftCrop = Qt.rect(Math.min(origin.x, p.x), Math.min(origin.y, p.y), Math.abs(p.x - origin.x), Math.abs(p.y - origin.y))
        }
        onPressed: function(mouse) {
            var b = cropOverlay.imageBox
            if (mouse.x < b.x || mouse.y < b.y || mouse.x > b.x + b.width || mouse.y > b.y + b.height) { mouse.accepted = false; return }
            origin = normalized(mouse.x, mouse.y); drawing = true
            var s = cropOverlay.selectionBox
            startCrop = cropOverlay.editor.draftCrop
            moving = cropOverlay.lockRatio > 0 && mouse.x > s.x && mouse.x < s.x + s.width && mouse.y > s.y && mouse.y < s.y + s.height
        }
        onPositionChanged: function(mouse) { if (drawing) updateCrop(mouse.x, mouse.y) }
        onReleased: function(mouse) {
            if (!drawing) return
            updateCrop(mouse.x, mouse.y); drawing = false
            const wasMoving = moving; moving = false
            if (wasMoving || (cropOverlay.editor.draftCrop.width > 0.003 && cropOverlay.editor.draftCrop.height > 0.003)) cropOverlay.editor.finishCrop()
            else cropOverlay.editor.draftCrop = preview.cropRect
        }
        onCanceled: { drawing = false; moving = false; cropOverlay.editor.draftCrop = preview.cropRect }
    }
}
