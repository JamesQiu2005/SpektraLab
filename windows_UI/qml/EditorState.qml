import QtQuick
import SpektraLab.Native 1.0

// The editor window's own state -- what is not the controller's: the crop
// editor, the export options, and the gates every pane agrees on. Main.qml
// creates one and hands it to each pane as `editor`, so no file reaches into
// another file's ids.
//
// The controller is the C++ context property `preview`, visible to every QML
// file in the engine; this object holds only what the window adds to it.
QtObject {
    id: editorState

    // The centre canvas, set once by Main.qml. Panes fit, zoom and read the
    // scale through resetView(), `fit` and `scalePercent` rather than through
    // the canvas's id, which lives in another file.
    property FrameCanvas canvas: null
    // The canvas is assigned after the panes' first bindings run; until then
    // these read as the canvas's own defaults (fit, 100 %), not as an error.
    readonly property bool fit: canvas ? canvas.fit : true
    readonly property real scalePercent: canvas ? canvas.scalePercent : 100

    // Set when the window is asked to close mid-operation; it closes once the
    // controller goes idle.
    property bool closePending: false

    // The crop editor: the canvas shows the uncropped source and `draftCrop`
    // (normalised to it) follows the drag until finishCrop() commits it.
    property bool cropMode: false
    property rect draftCrop: Qt.rect(0, 0, 1, 1)

    // Export options, shared by the options popup and the file dialogs.
    property int exportFormat: 0       // 0 TIFF16, 1 PNG8, 2 PNG16, 3 JPEG8
    property int exportQuality: 95
    property int exportLongEdge: 0     // 0 = the crop's own size

    readonly property bool canEditCrop: preview.hasFrame && !preview.busy && !preview.batchExporting
    readonly property bool canBrowse: preview.ready && !preview.busy && !preview.batchExporting && !cropMode
    readonly property bool canExport: preview.hasFrame && !preview.busy && !cropMode

    // Requests for what Main.qml owns: the import dialog and the export options.
    signal importRequested()
    signal exportOptionsRequested()

    function resetView(toFit) { if (canvas) canvas.resetView(toFit) }
    function startCrop() {
        if (!canEditCrop) return
        draftCrop = preview.cropRect
        cropMode = true
        Qt.callLater(function() { editorState.resetView(true) })
    }
    function finishCrop() {
        var next = draftCrop
        var commit = cropMode && canEditCrop
        cropMode = false
        if (commit) preview.setCropRect(next)
        Qt.callLater(function() { editorState.resetView(true) })
    }
    function cancelCrop() { cropMode = false; resetView(true) }
    function toggleCrop() { if (cropMode) finishCrop(); else startCrop() }
    function openExport() { if (canExport) exportOptionsRequested() }
}
