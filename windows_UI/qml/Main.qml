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
        preview.setDialogOpen(editorState.cropMode || openDialog.visible || exportPage.visible)
    }
    function startCrop() { editorState.startCrop() }
    function openExport() { editorState.openExport() }
    function showExportOptions() { editorState.openExport() }
    onClosing: function(event) {
        if (preview.batchExporting) preview.cancelExport()
        if (preview.busy) { editorState.closePending = true; event.accepted = false }
    }

    EditorState {
        id: editorState
        canvas: centre.canvas
        onCropModeChanged: window.updateDialogState()
        onImportRequested: openDialog.open()
        onExportOptionsRequested: exportPage.open()
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
    Shortcut { sequences: [StandardKey.Open]; enabled: editorState.canBrowse; onActivated: openDialog.open() }
    Shortcut { sequence: "Ctrl+E"; enabled: editorState.canExport; onActivated: editorState.openExport() }
    Shortcut { sequence: "Ctrl+0"; enabled: preview.hasFrame; onActivated: editorState.resetView(true) }
    Shortcut { sequence: "Ctrl+1"; enabled: preview.hasFrame && !editorState.cropMode; onActivated: editorState.resetView(false) }
    // The Mac's Cmd+= / Cmd+- on the zoom buttons; the canvas steps between
    // fit and 100 % (EditorState.zoomIn / zoomOut).
    Shortcut { sequences: [StandardKey.ZoomIn, "Ctrl+="]; enabled: editorState.canZoomIn; onActivated: editorState.zoomIn() }
    Shortcut { sequences: [StandardKey.ZoomOut]; enabled: editorState.canZoomOut; onActivated: editorState.zoomOut() }
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
    // The export page (ExportPage.swift). Still "exportPopup" to the
    // self-test, which opens it with openExport() and closes it with close().
    ExportPage {
        id: exportPage
        objectName: "exportPopup"
        editor: editorState
        onVisibleChanged: window.updateDialogState()
    }
}
