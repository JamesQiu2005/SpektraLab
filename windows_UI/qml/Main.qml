import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

// The editor window: the three panes, the file dialogs, the export options and
// the keyboard shortcuts. Each pane is its own file -- left/, centre/, right/,
// export/ -- and what they share lives in one EditorState, handed to each as
// `editor`; the controller is the C++ context property `preview`. Every
// user-visible string is L10n.tr("key"), from windows_UI/i18n/en.json.
//
// The layout is the macOS editor's (EditorWindow.swift): a left rail, the
// centre column (tool bar, canvas, filmstrip) and the Parameters rail, flush,
// separated by hairlines; both rails fold from the tool bar and take a
// user width. The look -- colours, rows, pills -- is Theme.qml and the
// controls in controls/.
//
// `cropMode`, startCrop() and openExport() stay on the window because the C++
// --self-test drives them by name (main.cpp), as it finds "frameCanvas",
// "exportPopup", "exposureSlider", "undoButton" and "redoButton" by objectName.
ApplicationWindow {
    id: window
    objectName: "editorWindow"
    width: 1540; height: 980
    minimumWidth: Theme.minWindowWidth; minimumHeight: Theme.minWindowHeight
    visible: true
    color: Theme.card
    title: (preview.hasFrame ? preview.fileName + " — " : "") + L10n.tr("app.name")
    font.family: Theme.fontFamily
    font.pixelSize: Theme.fontLabel
    palette.window: Theme.card
    palette.windowText: Theme.text
    palette.text: Theme.text
    palette.buttonText: Theme.text
    palette.base: Theme.well
    palette.button: Theme.well
    palette.highlight: Theme.accent
    palette.highlightedText: Theme.selectionInk
    palette.toolTipBase: "#1f1f1e"
    palette.toolTipText: Theme.text
    palette.dark: Theme.ruleRegion
    palette.mid: Theme.rule
    property alias cropMode: editorState.cropMode
    // Text controls keep their own undo stack while they own keyboard focus.
    readonly property bool editingText: activeFocusItem !== null && typeof activeFocusItem.text === "string" && typeof activeFocusItem.undo === "function"

    // Any modal surface pauses pending preview updates until it closes.
    function updateDialogState() {
        preview.setDialogOpen(editorState.cropMode || openDialog.visible || saveDialog.visible || batchDialog.visible || exportPopup.visible)
    }
    function startCrop() { editorState.startCrop() }
    function openExport() { editorState.openExport() }
    function showExportOptions() { editorState.openExport() }
    function formatFilter() {
        if (editorState.exportFormat === 3) return [L10n.tr("dialog.filter.jpeg") + " (*.jpg *.jpeg)"]
        if (editorState.exportFormat === 1 || editorState.exportFormat === 2) return [L10n.tr("dialog.filter.png") + " (*.png)"]
        return [L10n.tr("dialog.filter.tiff16") + " (*.tif *.tiff)"]
    }
    onClosing: function(event) {
        if (preview.batchExporting) preview.cancelExport()
        if (preview.busy) { editorState.closePending = true; event.accepted = false }
    }

    EditorState {
        id: editorState
        objectName: "editorState"
        canvas: centre.canvas
        onCropModeChanged: window.updateDialogState()
        onImportRequested: openDialog.open()
        onExportOptionsRequested: exportPopup.open()
    }
    Connections {
        target: preview
        function onStateChanged() { if (editorState.closePending && !preview.busy) window.close() }
        function onSourceOpened() { editorState.cropMode = false; editorState.resetView(true) }
    }
    FileDialog {
        id: openDialog
        title: L10n.tr("dialog.import.title")
        fileMode: FileDialog.OpenFiles
        nameFilters: [L10n.tr("dialog.filter.cameraRaw") + " (*.arw *.nef *.nrw *.dng *.cr2 *.cr3 *.raf *.rw2 *.orf *.pef *.srw)", L10n.tr("dialog.filter.allFiles") + " (*)"]
        onVisibleChanged: window.updateDialogState()
        onAccepted: preview.openFiles(selectedFiles)
    }
    FileDialog {
        id: saveDialog
        title: L10n.tr("dialog.export.title")
        fileMode: FileDialog.SaveFile
        nameFilters: window.formatFilter()
        defaultSuffix: editorState.exportFormat === 3 ? "jpg" : editorState.exportFormat === 0 ? "tif" : "png"
        currentFolder: preview.sourceFolder
        onVisibleChanged: window.updateDialogState()
        onAccepted: preview.exportImage(selectedFile, editorState.exportFormat, editorState.exportQuality, editorState.exportLongEdge)
    }
    FolderDialog {
        id: batchDialog
        title: L10n.tr("dialog.batch.title")
        currentFolder: preview.sourceFolder
        onVisibleChanged: window.updateDialogState()
        onAccepted: preview.exportBatch(selectedFolder, editorState.exportFormat, editorState.exportQuality, editorState.exportLongEdge)
    }
    Shortcut { sequences: [StandardKey.Open]; enabled: editorState.canBrowse; onActivated: openDialog.open() }
    Shortcut { sequence: "Ctrl+E"; enabled: editorState.canExport; onActivated: editorState.openExport() }
    // Zoom, the Mac's View menu as Windows spells it: Ctrl+0 / Ctrl+1 and
    // Capture One's `,` / `.` are fit and 100 %; Ctrl+= / Ctrl+- step the
    // ladder (ViewportState.zoomSteps) about the centre; Z toggles fit and
    // 100 % (MetalCanvasView keyDown). Single keys yield to a focused text
    // field, which takes them as typing. All wait while the crop editor is up.
    Shortcut { sequences: ["Ctrl+0", ","]; enabled: preview.hasFrame && !editorState.zoomLocked; onActivated: editorState.resetView(true) }
    Shortcut { sequences: ["Ctrl+1", "."]; enabled: preview.hasFrame && !editorState.zoomLocked; onActivated: editorState.zoomTo(1) }
    Shortcut { sequence: "Z"; enabled: preview.hasFrame && !editorState.zoomLocked && centre.canvas !== null; onActivated: centre.canvas.toggleHundred(centre.canvas.width / 2, centre.canvas.height / 2) }
    Shortcut { sequences: [StandardKey.ZoomIn, "Ctrl+="]; enabled: editorState.canZoomIn; onActivated: editorState.zoomIn() }
    Shortcut { sequences: [StandardKey.ZoomOut]; enabled: editorState.canZoomOut; onActivated: editorState.zoomOut() }
    // Before / after: the Mac's Y (Capture One's), and Alt+\ for its
    // Option-\. Ctrl+\ is left alone; Alt+letter is the Windows menu mnemonic.
    Shortcut { sequences: ["Y", "Alt+\\"]; enabled: editorState.canCompare || editorState.comparing; onActivated: editorState.toggleCompare() }
    // Full screen: the Mac's Ctrl+Cmd+F, as Windows spells it.
    Shortcut { sequence: "F11"; onActivated: window.visibility = window.visibility === Window.FullScreen ? Window.Windowed : Window.FullScreen }
    Shortcut { sequence: "Ctrl+Z"; enabled: preview.settingsEditable && preview.canUndo && !editorState.cropMode && !window.editingText; onActivated: preview.undo() }
    Shortcut { sequences: ["Ctrl+Shift+Z", "Ctrl+Y"]; enabled: preview.settingsEditable && preview.canRedo && !editorState.cropMode && !window.editingText; onActivated: preview.redo() }
    Shortcut { sequence: "Escape"; enabled: editorState.cropMode; onActivated: editorState.cancelCrop() }
    Shortcut { sequence: "Return"; enabled: editorState.cropMode; onActivated: editorState.finishCrop() }

    RowLayout {
        anchors.fill: parent; spacing: 0
        // Above the centre column, so each rail's resize grip -- which
        // straddles the rail's inner edge -- takes the pointer on both sides.
        LeftRail { editor: editorState; z: 1 }
        CentrePane { id: centre; editor: editorState }
        RightRail { editor: editorState; z: 1 }
    }
    ExportPopup {
        id: exportPopup
        objectName: "exportPopup"
        editor: editorState
        onVisibleChanged: window.updateDialogState()
        onExportCurrentRequested: saveDialog.open()
        onExportBatchRequested: batchDialog.open()
    }
}
