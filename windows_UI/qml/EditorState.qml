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
    // (normalised to it) follows the drag until finishCrop() commits it;
    // `draftStraighten` is what the Ctrl-drag line asked for, applied with it.
    property bool cropMode: false
    property rect draftCrop: Qt.rect(0, 0, 1, 1)
    property real draftStraighten: 0
    // The aspect a crop grip keeps (source px width / height, 0 free): the
    // Crop section's preset when the committed crop is one (CropSection.qml
    // reads the same shape), as the Mac's grips keep Geometry.aspect.
    readonly property real cropLockRatio: {
        var c = preview.cropRect
        var w = preview.metadata.sourceWidth, h = preview.metadata.sourceHeight
        if (!preview.hasFrame || w === undefined || c.height <= 0) return 0
        if (c.x === 0 && c.y === 0 && c.width === 1 && c.height === 1) return 0
        var r = c.width * w / (c.height * h)
        var shown = preview.quarterTurns % 2 !== 0 ? 1 / r : r
        var folded = shown >= 1 ? shown : 1 / shown
        var presets = [1, 1.5, 4 / 3, 16 / 9]
        for (var i = 0; i < presets.length; ++i)
            if (Math.abs(folded - presets[i]) < 0.002) return r
        return 0
    }

    // --- the canvas tools (TopBar.swift, MetalCanvasView.swift) ---
    // The Original: pinned by the tool bar's pill, or held with Space. It and
    // the before/after split both end the crop editor, as the Mac's
    // toggledOriginal and comparing leave the crop tool (Session.swift).
    property bool originalPinned: false
    readonly property bool showingOriginal: preview.hasFrame && !cropMode && (originalPinned || CanvasTools.spaceHeld)
    // Before / after: the Original left of a vertical split, the print right
    // of it; the split is a fraction of the picture's width, so it stays on
    // the same part of the frame under zoom and pan (CompareOverlay.swift).
    property bool comparing: false
    property real comparePosition: 0.5
    readonly property bool canCompare: preview.hasFrame && !preview.batchExporting
    function toggleOriginal() {
        if (!preview.hasFrame) return
        if (!originalPinned && cropMode) finishCrop()
        originalPinned = !originalPinned
    }
    function toggleCompare() {
        if (!canCompare && !comparing) return
        if (!comparing && cropMode) finishCrop()
        comparing = !comparing
    }
    function setComparePosition(p) { comparePosition = Math.max(0, Math.min(1, p)) }
    // The controller makes the Original only while something shows it.
    readonly property bool originalWanted: preview.hasFrame && (showingOriginal || comparing)
    onOriginalWantedChanged: preview.originalWanted = originalWanted
    readonly property Connections spaceWatch: Connections {
        target: CanvasTools
        function onSpaceHeldChanged() { if (CanvasTools.spaceHeld && editorState.cropMode) editorState.finishCrop() }
    }

    // Export settings live in the recipes (exportRecipes, ExportRecipe.hpp).

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
        leftCollapsed = false; rightCollapsed = false; filmstripCollapsed = false; parametersTab = 0
        leftWidth = Theme.leftRailStandard; rightWidth = Theme.rightRailStandard
    }
    // The Parameters rail's tab: 0 Pre-Dev, 1 Post-Dev -- a view choice,
    // remembered across launches as the Mac's (RightPanel.swift @AppStorage
    // "parametersTab").
    property int parametersTab: AppSettings.value("layout.parametersTab", 0) === 1 ? 1 : 0
    onParametersTabChanged: AppSettings.setValue("layout.parametersTab", parametersTab)
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
    // Zoom (ViewportState.swift): fit, or 5 % to 800 % in the Mac's steps,
    // Ctrl+= / Ctrl+- and the bar's buttons stepping about the centre. Locked
    // while the crop editor is up, as the Mac's crop tool locks it
    // (Session.zoomLocked): the editor shows the whole source, fitted.
    readonly property bool zoomLocked: cropMode
    readonly property bool canZoomIn: preview.hasFrame && !zoomLocked && canvas !== null && canvas.canZoomIn
    readonly property bool canZoomOut: preview.hasFrame && !zoomLocked && canvas !== null && canvas.canZoomOut
    function zoomIn() { if (canZoomIn) canvas.zoomStep(1) }
    function zoomOut() { if (canZoomOut) canvas.zoomStep(-1) }
    function zoomTo(fraction) { if (canvas && preview.hasFrame && !zoomLocked) canvas.zoomTo(fraction) }

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
    // Post-Dev's bypass (Ctrl+Shift+B and the menu's Bypass / Restore
    // Adjustments): an edit of the open photograph, so it waits like one.
    readonly property bool canBypass: preview.settingsEditable && preview.hasFrame && !cropMode
    signal settingsRequested(string page)
    signal aboutRequested()
    signal quitRequested()
    signal appMenuRequested(bool open)

    function resetView(toFit) { if (canvas) canvas.resetView(toFit) }
    function startCrop() {
        if (!canEditCrop) return
        draftCrop = preview.cropRect
        draftStraighten = preview.straightenDegrees
        originalPinned = false
        comparing = false
        cropMode = true
        Qt.callLater(function() { editorState.resetView(true) })
    }
    function finishCrop() {
        var next = draftCrop
        var angle = draftStraighten
        var commit = cropMode && canEditCrop
        cropMode = false
        if (commit) preview.setCropGeometry(next, angle)
        Qt.callLater(function() { editorState.resetView(true) })
    }
    function cancelCrop() { cropMode = false; resetView(true) }
    function toggleCrop() { if (cropMode) finishCrop(); else startCrop() }
    function openExport() { if (canExport) exportOptionsRequested() }
}
