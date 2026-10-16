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

    // The two rails (EditorWindow.swift): each folds with its sidebar button
    // on the tool bar, and its width is the user's between the Theme bounds
    // (PanelResize.swift). Kept in the preferences file under "layout." (the
    // Mac's ui2.leftCollapsed / PanelWidthStore), which a test run keeps in
    // its own directory (AppSettings.hpp); Settings > Reset All Layout clears
    // them (resetLayout()).
    property bool leftCollapsed: AppSettings.value("layout.leftCollapsed", false) === true
    property bool rightCollapsed: AppSettings.value("layout.rightCollapsed", false) === true
    property real leftWidth: clampLeft(Number(AppSettings.value("layout.leftRailWidth", Theme.leftRailStandard)))
    property real rightWidth: clampRight(Number(AppSettings.value("layout.rightRailWidth", Theme.rightRailStandard)))
    onLeftCollapsedChanged: AppSettings.setValue("layout.leftCollapsed", leftCollapsed)
    onRightCollapsedChanged: AppSettings.setValue("layout.rightCollapsed", rightCollapsed)
    function clampLeft(w) { return isNaN(w) ? Theme.leftRailStandard : Math.max(Theme.leftRailNarrowest, Math.min(Theme.leftRailWidest, w)) }
    function clampRight(w) { return isNaN(w) ? Theme.rightRailStandard : Math.max(Theme.rightRailNarrowest, Math.min(Theme.rightRailWidest, w)) }
    function setLeftWidth(w) { leftWidth = clampLeft(w); AppSettings.setValue("layout.leftRailWidth", leftWidth) }
    function setRightWidth(w) { rightWidth = clampRight(w); AppSettings.setValue("layout.rightRailWidth", rightWidth) }
    function toggleSidePanels() { var fold = !(leftCollapsed && rightCollapsed); leftCollapsed = fold; rightCollapsed = fold }
    // Back to the drawing: the caller then clears the stored "layout." keys.
    function resetLayout() {
        leftCollapsed = false; rightCollapsed = false; filmstripCollapsed = false
        leftWidth = Theme.leftRailStandard; rightWidth = Theme.rightRailStandard
    }
    // The Parameters rail's tab: 0 Pre-Dev, 1 Post-Dev (not built yet).
    property int parametersTab: 0
    // The filmstrip folds with the tab on the canvas's lower edge (the Mac's
    // one surviving collapse tab, CollapseTab.swift).
    property bool filmstripCollapsed: AppSettings.value("layout.filmstripCollapsed", false) === true
    onFilmstripCollapsedChanged: AppSettings.setValue("layout.filmstripCollapsed", filmstripCollapsed)

    // What part of the frame the canvas shows, normalised to the frame: the
    // whole of it while fitted, a window into it at 100 %. The navigator
    // frames it and a click there re-centres the canvas (centreOn).
    readonly property rect visibleFraction: {
        if (!canvas || fit) return Qt.rect(0, 0, 1, 1)
        var r = canvas.imageRect
        if (r.width <= 0 || r.height <= 0) return Qt.rect(0, 0, 1, 1)
        var x0 = Math.max(0, -r.x / r.width), y0 = Math.max(0, -r.y / r.height)
        var x1 = Math.min(1, (canvas.width - r.x) / r.width), y1 = Math.min(1, (canvas.height - r.y) / r.height)
        return Qt.rect(x0, y0, Math.max(0, x1 - x0), Math.max(0, y1 - y0))
    }
    function centreOn(nx, ny) {
        if (!canvas || fit) return
        var r = canvas.imageRect
        canvas.panBy(canvas.width / 2 - (r.x + nx * r.width), canvas.height / 2 - (r.y + ny * r.height))
    }
    // The canvas has two scales, fit and one physical pixel per source pixel
    // (FrameCanvas); zoom in and out step between them until it has more.
    readonly property bool canZoomIn: preview.hasFrame && !cropMode && fit
    readonly property bool canZoomOut: preview.hasFrame && !fit
    function zoomIn() { if (canZoomIn) resetView(false) }
    function zoomOut() { if (canZoomOut) resetView(true) }

    // Requests for what Main.qml owns: the import dialog and the export options.
    signal importRequested()
    signal exportOptionsRequested()

    // The application menu (shell/AppMenu.qml) and Main.qml's Shortcuts share
    // these gates and requests, so a key and its menu item do one thing.
    readonly property bool canUndo: preview.settingsEditable && preview.canUndo && !cropMode
    readonly property bool canRedo: preview.settingsEditable && preview.canRedo && !cropMode
    readonly property bool canSelectAll: canBrowse && preview.libraryItems.length > 0
    readonly property bool canSync: canBrowse && preview.hasFrame && preview.selectedCount > 0
    readonly property bool canResetPhoto: preview.settingsEditable && preview.hasFrame && !cropMode
    signal settingsRequested(string page)
    signal aboutRequested()
    signal quitRequested()
    signal appMenuRequested(bool open)

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
