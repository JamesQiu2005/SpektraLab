import QtQuick
import QtQuick.Shapes
import SpektraLab.Native 1.0

// The crop editor over the canvas (Canvas/CropOverlay.swift and the crop half
// of MetalCanvasView.swift): the uncropped source with everything outside
// `editor.draftCrop` dimmed, the frame with its corner blocks and edge bars,
// the rule-of-thirds grid, and the gestures -- the arithmetic is CanvasMath's
// (CanvasTools), in source-normalised space like Geometry.swift's.
//
//   drag a grip or an edge   resize, the opposite side pinned; the Crop
//                            section's aspect holds (editor.cropLockRatio),
//                            and Shift holds the current shape when it is free
//   drag inside              move, each axis stopping at the frame's edge
//   drag outside, or Alt-drag anywhere (the Mac's Option)
//                            draw a new rectangle, free unless Shift is held
//                            (the grips keep the aspect); it is committed at once, as
//                            this editor always has
//   Ctrl-drag                draw a line that should be level (or plumb); on
//                            release the straighten that levels it is held
//                            for the commit (the Mac's Cmd-drag)
//   Enter / the crop tool    commit; Esc abandons (Main.qml)
//
// The editor shows the unturned, unstraightened source, so the line's angle
// replaces the current straighten rather than adding to it. A drag starting
// outside the picture passes through; a drawn rectangle too small to mean
// anything restores the committed crop. Grips are drawn a constant size on
// screen and take the pointer within 10 px (CanvasNSView.handleGrab).
Item {
    id: cropOverlay
    objectName: "cropOverlay"
    required property FrameCanvas canvas
    required property EditorState editor
    anchors.fill: canvas
    visible: editor.cropMode
    readonly property rect imageBox: canvas ? canvas.imageRect : Qt.rect(0, 0, 0, 0)
    readonly property size sourceSize: Qt.size(preview.metadata.sourceWidth || 1, preview.metadata.sourceHeight || 1)
    // On whole pixels, so the four dimming bands meet without a doubly dimmed
    // seam where two of them would overlap by a fraction of a pixel.
    readonly property rect selectionBox: {
        var x0 = Math.round(imageBox.x + editor.draftCrop.x * imageBox.width)
        var y0 = Math.round(imageBox.y + editor.draftCrop.y * imageBox.height)
        var x1 = Math.round(imageBox.x + (editor.draftCrop.x + editor.draftCrop.width) * imageBox.width)
        var y1 = Math.round(imageBox.y + (editor.draftCrop.y + editor.draftCrop.height) * imageBox.height)
        return Qt.rect(x0, y0, x1 - x0, y1 - y0)
    }
    readonly property real grab: 10
    readonly property bool dragging: gesture.mode !== ""
    readonly property color ink: Theme.selectionFrame

    Rectangle { x: cropOverlay.imageBox.x; y: cropOverlay.imageBox.y; width: cropOverlay.imageBox.width; height: Math.max(0, cropOverlay.selectionBox.y - y); color: "#99000000" }
    Rectangle { x: cropOverlay.imageBox.x; y: cropOverlay.selectionBox.y + cropOverlay.selectionBox.height; width: cropOverlay.imageBox.width; height: Math.max(0, cropOverlay.imageBox.y + cropOverlay.imageBox.height - y); color: "#99000000" }
    Rectangle { x: cropOverlay.imageBox.x; y: cropOverlay.selectionBox.y; width: Math.max(0, cropOverlay.selectionBox.x - x); height: cropOverlay.selectionBox.height; color: "#99000000" }
    Rectangle { x: cropOverlay.selectionBox.x + cropOverlay.selectionBox.width; y: cropOverlay.selectionBox.y; width: Math.max(0, cropOverlay.imageBox.x + cropOverlay.imageBox.width - x); height: cropOverlay.selectionBox.height; color: "#99000000" }
    Item {
        id: frame
        x: cropOverlay.selectionBox.x; y: cropOverlay.selectionBox.y; width: cropOverlay.selectionBox.width; height: cropOverlay.selectionBox.height
        // The thirds: always there, faint, as the Mac draws them; brighter
        // while a drag is reshaping the frame.
        Repeater {
            model: 4
            Rectangle {
                readonly property bool vertical: index < 2
                readonly property real t: (index % 2 + 1) / 3
                x: vertical ? Math.round(frame.width * t) : 0
                y: vertical ? 0 : Math.round(frame.height * t)
                width: vertical ? 1 : frame.width
                height: vertical ? frame.height : 1
                color: cropOverlay.ink
                opacity: cropOverlay.dragging ? 0.6 : 0.3
            }
        }
        // The outline, with a hairline of shadow outside it.
        Rectangle { anchors.fill: parent; anchors.margins: -1; color: "transparent"; border.color: "#80000000"; border.width: 1 }
        Rectangle { anchors.fill: parent; color: "transparent"; border.color: cropOverlay.ink; border.width: 1 }
        // Corner blocks 11 px, edge bars 22 x 4 lying along their edge
        // (CropOverlay.swift grips), centred on the grip position.
        Repeater {
            model: [[0, 0, 1], [0.5, 0, 2], [1, 0, 3], [1, 0.5, 4], [1, 1, 5], [0.5, 1, 6], [0, 1, 7], [0, 0.5, 8]]
            Rectangle {
                readonly property bool corner: modelData[0] !== 0.5 && modelData[1] !== 0.5
                readonly property bool side: modelData[1] === 0.5
                width: corner ? 11 : (side ? 4 : 22)
                height: corner ? 11 : (side ? 22 : 4)
                x: frame.width * modelData[0] - width / 2
                y: frame.height * modelData[1] - height / 2
                color: gesture.handle === modelData[2] ? Theme.accent : cropOverlay.ink
                border.color: "#80000000"; border.width: 0.5
            }
        }
    }
    // The line being drawn, dashed in the accent, with the angle it will set.
    Shape {
        id: line
        anchors.fill: parent
        visible: gesture.mode === "straighten" && gesture.lineLength > 2
        preferredRendererType: Shape.CurveRenderer
        // A dark underlay keeps the dashes legible on a light sky.
        ShapePath {
            strokeColor: "#99000000"; strokeWidth: 3; fillColor: "transparent"
            startX: gesture.lineFrom.x; startY: gesture.lineFrom.y
            PathLine { x: gesture.lineTo.x; y: gesture.lineTo.y }
        }
        ShapePath {
            strokeColor: Theme.accent; strokeWidth: 1.5; fillColor: "transparent"
            strokeStyle: ShapePath.DashLine; dashPattern: [3, 2]
            startX: gesture.lineFrom.x; startY: gesture.lineFrom.y
            PathLine { x: gesture.lineTo.x; y: gesture.lineTo.y }
        }
    }
    // What the editor will apply besides the rectangle.
    Text {
        objectName: "cropStraightenNote"
        visible: gesture.mode === "straighten" ? gesture.pendingAngle !== undefined
                                               : Math.abs(cropOverlay.editor.draftStraighten - preview.straightenDegrees) > 1e-9
        x: cropOverlay.selectionBox.x + 8
        y: Math.max(cropOverlay.imageBox.y, cropOverlay.selectionBox.y) + 8
        text: L10n.tr("crop.straightenPending", [((gesture.mode === "straighten" && gesture.pendingAngle !== undefined) ? gesture.pendingAngle : cropOverlay.editor.draftStraighten).toFixed(1)])
        color: Theme.text
        font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightTitle
        style: Text.Raised; styleColor: "#99000000"
    }
    MouseArea {
        id: gesture
        anchors.fill: parent; enabled: cropOverlay.editor.canEditCrop
        hoverEnabled: true
        property string mode: ""        // "", "draw", "move", "resize", "straighten"
        property int handle: -1
        property point origin
        property point pressPoint
        property rect startCrop
        property real lockRatio: 0
        // The straighten line, in item px, and what it would set.
        property point lineFrom
        property point lineTo
        property real lineLength: 0
        property var pendingAngle: undefined
        function normalized(x, y) {
            var b = cropOverlay.imageBox
            return Qt.point((x - b.x) / b.width, (y - b.y) / b.height)
        }
        function clampedPoint(p) { return Qt.point(Math.max(0, Math.min(1, p.x)), Math.max(0, Math.min(1, p.y))) }
        function tolerance() { return cropOverlay.grab * cropOverlay.sourceSize.width / Math.max(cropOverlay.imageBox.width, 1) }
        function handleAt(x, y) {
            return CanvasTools.cropHandleAt(cropOverlay.editor.draftCrop, normalized(x, y), cropOverlay.sourceSize, tolerance())
        }
        function ratioFor(modifiers) {
            if (cropOverlay.editor.cropLockRatio > 0) return cropOverlay.editor.cropLockRatio
            if (modifiers & Qt.ShiftModifier) {
                var c = startCrop
                return c.height > 0 ? c.width * cropOverlay.sourceSize.width / (c.height * cropOverlay.sourceSize.height) : 0
            }
            return 0
        }
        // A drawn rectangle is free, as this editor has always drawn it;
        // Shift keeps the shape the crop had.
        function drawRatio(modifiers) {
            var c = startCrop
            return (modifiers & Qt.ShiftModifier) && c.height > 0 ? c.width * cropOverlay.sourceSize.width / (c.height * cropOverlay.sourceSize.height) : 0
        }
        function cursorFor(h) {
            switch (h) {
            case 1: case 5: return Qt.SizeFDiagCursor
            case 3: case 7: return Qt.SizeBDiagCursor
            case 2: case 6: return Qt.SizeVerCursor
            case 4: case 8: return Qt.SizeHorCursor
            case 0: return Qt.SizeAllCursor
            default: return Qt.CrossCursor
            }
        }
        cursorShape: Qt.CrossCursor
        onPressed: function(mouse) {
            var b = cropOverlay.imageBox
            var insidePicture = !(mouse.x < b.x || mouse.y < b.y || mouse.x > b.x + b.width || mouse.y > b.y + b.height)
            startCrop = cropOverlay.editor.draftCrop
            pressPoint = Qt.point(mouse.x, mouse.y)
            var p = normalized(mouse.x, mouse.y)
            if (mouse.modifiers & Qt.ControlModifier) {
                if (!insidePicture) { mouse.accepted = false; return }
                mode = "straighten"; origin = p
                lineFrom = Qt.point(mouse.x, mouse.y); lineTo = lineFrom; lineLength = 0; pendingAngle = undefined
                return
            }
            var h = (mouse.modifiers & Qt.AltModifier) ? -1 : handleAt(mouse.x, mouse.y)
            if (h > 0) { mode = "resize"; handle = h; return }
            if (h === 0) { mode = "move"; origin = p; return }
            if (!insidePicture) { mouse.accepted = false; return }
            mode = "draw"; origin = clampedPoint(p)
        }
        onPositionChanged: function(mouse) {
            if (mode === "") { cursorShape = cursorFor(handleAt(mouse.x, mouse.y)); return }
            var p = normalized(mouse.x, mouse.y)
            if (mode === "resize")
                cropOverlay.editor.draftCrop = CanvasTools.resizedCrop(startCrop, handle, p, cropOverlay.sourceSize, ratioFor(mouse.modifiers))
            else if (mode === "move")
                cropOverlay.editor.draftCrop = CanvasTools.movedCrop(startCrop, Qt.point(p.x - origin.x, p.y - origin.y))
            else if (mode === "draw")
                cropOverlay.editor.draftCrop = CanvasTools.drawnCrop(origin, p, cropOverlay.sourceSize, drawRatio(mouse.modifiers))
            else if (mode === "straighten") {
                var dx = mouse.x - lineFrom.x, dy = mouse.y - lineFrom.y
                lineLength = Math.sqrt(dx * dx + dy * dy)
                lineTo = Qt.point(mouse.x, mouse.y)
                pendingAngle = CanvasTools.straightenFromLine(origin, p, cropOverlay.sourceSize)
            }
        }
        onReleased: function(mouse) {
            var was = mode
            mode = ""; handle = -1
            if (was === "draw") {
                cropOverlay.editor.draftCrop = CanvasTools.drawnCrop(origin, normalized(mouse.x, mouse.y), cropOverlay.sourceSize, drawRatio(mouse.modifiers))
                if (cropOverlay.editor.draftCrop.width > 0.003 && cropOverlay.editor.draftCrop.height > 0.003) cropOverlay.editor.finishCrop()
                else cropOverlay.editor.draftCrop = startCrop
            } else if (was === "straighten") {
                var angle = CanvasTools.straightenFromLine(origin, normalized(mouse.x, mouse.y), cropOverlay.sourceSize)
                if (angle !== undefined) cropOverlay.editor.draftStraighten = Math.round(angle * 10) / 10
                lineLength = 0; pendingAngle = undefined
            }
        }
        onCanceled: {
            if (mode === "draw" || mode === "move" || mode === "resize") cropOverlay.editor.draftCrop = startCrop
            mode = ""; handle = -1; lineLength = 0; pendingAngle = undefined
        }
    }
}
