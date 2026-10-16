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
// `cropMode`, startCrop() and openExport() stay on the window because the C++
// --self-test drives them by name (main.cpp), as it finds "frameCanvas",
// "exportPopup", "exposureSlider", "undoButton" and "redoButton" by objectName.
ApplicationWindow {
    id: window
    objectName: "editorWindow"
    width: 1540; height: 980
    minimumWidth: 1100; minimumHeight: 740
    visible: true
    color: Theme.card
    title: (preview.hasFrame ? preview.fileName + " — " : "") + L10n.tr("app.name")
    font.family: "Segoe UI"
    font.pixelSize: 12
    palette.window: Theme.card
    palette.windowText: Theme.text
    palette.text: Theme.text
    palette.buttonText: Theme.text
    palette.base: Theme.well
    palette.button: Theme.well
    palette.highlight: Theme.accent
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
    Shortcut { sequence: "Ctrl+0"; enabled: preview.hasFrame; onActivated: editorState.resetView(true) }
    Shortcut { sequence: "Ctrl+1"; enabled: preview.hasFrame && !editorState.cropMode; onActivated: editorState.resetView(false) }
    Shortcut { sequence: "Ctrl+Z"; enabled: preview.settingsEditable && preview.canUndo && !editorState.cropMode && !window.editingText; onActivated: preview.undo() }
    Shortcut { sequences: ["Ctrl+Shift+Z", "Ctrl+Y"]; enabled: preview.settingsEditable && preview.canRedo && !editorState.cropMode && !window.editingText; onActivated: preview.redo() }
    Shortcut { sequence: "Escape"; enabled: editorState.cropMode; onActivated: editorState.cancelCrop() }
    Shortcut { sequence: "Return"; enabled: editorState.cropMode; onActivated: editorState.finishCrop() }

    RowLayout {
        anchors.fill: parent; spacing: 1
        LeftRail { editor: editorState }
        CentrePane { id: centre; editor: editorState }
        RightRail { editor: editorState }
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
