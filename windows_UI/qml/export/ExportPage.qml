import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import SpektraLab.Native 1.0

// The export page (modern_UI/.../Export/ExportPage.swift): the recipe on the
// left, the picture it will write in the middle, the worklist down the right.
// On the Mac it is a window of its own; here it covers the editor as a modal
// page (edits are paused while it is up, as for any dialog) and Escape or
// Close returns to the editor.
//
// The left rail is the Mac's five sections -- Export Formula (the saved
// recipes), Location, Naming, Format and Size, Summary -- plus Metadata, the
// Windows choice of which EXIF fields travel (the Mac always copies them all).
// Every edit is saved to the recipe file at once (exportRecipes); there is no
// Apply. Export writes every selected photo -- the displayed one when none
// is -- one at a time, and Stop ends the run between photos.
//
// The centre is a proof: the displayed frame through the same conversion the
// file gets, drawn colour-managed (preview.exportProof).
Popup {
    id: page
    required property EditorState editor
    readonly property var recipe: exportRecipes.selected
    readonly property bool running: preview.batchExporting
    property string resultText
    property bool resultWarning: false
    readonly property real labelColumn: 82

    parent: Overlay.overlay
    x: 0; y: 0
    width: parent ? parent.width : 0
    height: parent ? parent.height : 0
    padding: 0
    modal: true; focus: true
    closePolicy: running ? Popup.NoAutoClose : Popup.CloseOnEscape
    background: Rectangle { color: Theme.ground }
    Overlay.modal: Rectangle { color: "transparent" }

    // --- what the page reads off the controller ---
    // Only while the page is shown: every library item, strip picture
    // included, rebuilt on each library change -- with a folder of hundreds
    // loading its previews that held the GUI thread whether the page was
    // open or not.
    readonly property var items: page.visible ? preview.libraryItems : []
    readonly property var worklist: {
        var out = []
        for (var i = 0; i < items.length; ++i)
            if (items[i].selected) out.push({ index: i, name: items[i].name, url: items[i].url, active: items[i].active,
                                              thumbnail: items[i].strip, error: items[i].error })
        if (out.length === 0 && preview.activeIndex >= 0 && preview.activeIndex < items.length) {
            var a = items[preview.activeIndex]
            out.push({ index: preview.activeIndex, name: a.name, url: a.url, active: true, thumbnail: a.strip, error: a.error })
        }
        return out
    }
    readonly property var sources: worklist.map(function(w) { return w.url })
    readonly property var activeUrl: preview.activeIndex >= 0 && preview.activeIndex < items.length ? items[preview.activeIndex].url : ""
    readonly property string filmId: preview.filmIndex >= 0 && preview.filmIndex < preview.films.length ? preview.films[preview.filmIndex].id : ""
    readonly property string paperId: preview.paperIndex >= 0 && preview.paperIndex < preview.papers.length ? preview.papers[preview.paperIndex].id : ""
    readonly property string sampleName: { recipe; return exportRecipes.sampleName(activeUrl, filmId, paperId) }
    readonly property var folders: { recipe; return exportRecipes.destinationFolders(sources) }
    readonly property string destinationSummary: folders.length === 0 ? "" : folders.length === 1 ? folders[0]
        : L10n.tr("export.location.manyFolders", [folders.length, folders[0]])
    readonly property int frameWidth: preview.metadata.width !== undefined ? preview.metadata.width : 0
    readonly property int frameHeight: preview.metadata.height !== undefined ? preview.metadata.height : 0
    readonly property string sizeLine: {
        var w = frameWidth, h = frameHeight, edge = recipe.longEdge
        if (edge > 0 && Math.max(w, h) > edge) {
            var s = edge / Math.max(w, h)
            w = Math.max(1, Math.round(w * s)); h = Math.max(1, Math.round(h * s))
        }
        var px = L10n.tr("export.size.pixels", [w, h])
        if (worklist.length <= 1) return px
        return L10n.tr(edge > 0 ? "export.size.batchLongEdge" : "export.size.batchOriginal", [px, worklist.length - 1])
    }
    readonly property var summaryLines: [
        L10n.tr("export.summary.recipe", [recipe.name]),
        L10n.tr("export.summary.images", [worklist.length, items.length]),
        L10n.tr("export.summary.fileName", [sampleName]),
        L10n.tr("export.summary.format", [recipe.formatLabel, recipe.bitDepth]),
        L10n.tr("export.summary.size", [sizeLine]),
        recipe.takesColorSpace ? L10n.tr("export.summary.colorSpace", [recipe.colorSpaceName]) : L10n.tr("export.summary.untagged"),
        L10n.tr(recipe.exif ? "export.summary.exif" : "export.summary.noExif"),
        L10n.tr("export.summary.folder", [destinationSummary])
    ]

    function refreshProof() { if (page.visible && preview.hasFrame) preview.requestExportProof(exportRecipes.selectedJson) }
    function run() {
        if (running || worklist.length === 0) return
        resultText = ""; resultWarning = false
        preview.exportWithRecipe(exportRecipes.selectedJson)
    }
    onOpened: { resultText = ""; refreshProof() }
    Connections {
        target: exportRecipes
        function onChanged() { page.refreshProof() }
    }
    Connections {
        target: preview
        function onFrameChanged() { page.refreshProof() }
        function onExportFinished(summary, warning, files) {
            page.resultText = summary; page.resultWarning = warning
            exportRecipes.openAfterExport(files)
        }
    }

    // Opens on the recipe's own folder when it has one, else where the last
    // one was chosen.
    RememberedDialog {
        id: folderDialog
        objectName: "exportFolderDialogLoader"
        folder: function() { return page.recipe.besideOriginal ? AppSettings.dialogFolder("exportFolder") : exportRecipes.folderUrl() }
        dialog: FolderDialog {
            objectName: "exportFolderDialog"
            title: L10n.tr("export.location.chooseTitle")
            onAccepted: {
                AppSettings.rememberDialogFolder("exportFolder", selectedFolder)
                exportRecipes.setFolder(selectedFolder)
            }
        }
    }
    // An ordinary file dialog for an .exe, not Windows' Open With chooser:
    // the folder of the last application chosen is the app's to remember.
    RememberedDialog {
        id: appDialog
        folder: function() { return AppSettings.dialogFolder("openWith") }
        dialog: FileDialog {
            title: L10n.tr("export.openWith.chooseTitle")
            nameFilters: [L10n.tr("export.openWith.filter") + " (*.exe)"]
            onAccepted: {
                AppSettings.rememberDialogFolder("openWith", selectedFile)
                exportRecipes.setOpenWithApplication(selectedFile)
            }
        }
    }
    // The Mac's "Rename Recipe" alert: a draft name, Rename (also Return) or
    // Cancel (also Escape). The field keeps what was typed when it loses
    // focus -- clicking Rename takes focus off it before onAccepted reads it.
    Dialog {
        id: renameDialog
        objectName: "exportRenameDialog"
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        title: L10n.tr("export.formula.renameTitle")
        background: Rectangle { color: Theme.card; border.color: Theme.ruleRegion; radius: 8 }
        contentItem: ColumnLayout {
            spacing: 8
            Note { text: L10n.tr("export.formula.renameNote") }
            ExportField {
                id: renameField
                objectName: "exportRenameField"
                Layout.preferredWidth: 260
                keepsDraft: true
                placeholder: L10n.tr("export.formula.renamePlaceholder")
                onAccepted: renameDialog.accept()
            }
        }
        footer: Item {
            implicitHeight: renameButtons.implicitHeight + 24
            Row {
                id: renameButtons
                anchors.right: parent.right; anchors.rightMargin: 12
                anchors.top: parent.top; anchors.topMargin: 4
                spacing: 8
                ActionButton { text: L10n.tr("action.cancel"); onClicked: renameDialog.reject() }
                ActionButton {
                    objectName: "exportRenameButton"
                    accented: true
                    text: L10n.tr("export.formula.renameAction")
                    enabled: renameField.text.trim().length > 0
                    onClicked: renameDialog.accept()
                }
            }
        }
        onOpened: { renameField.text = page.recipe.name; renameField.forceActiveFocus(); renameField.selectAll() }
        onAccepted: exportRecipes.rename(renameField.text)
    }

    contentItem: RowLayout {
        spacing: 0

        // ===================== the settings rail =====================
        Rectangle {
            Layout.preferredWidth: 330; Layout.fillHeight: true
            color: Theme.card
            ColumnLayout {
                anchors.fill: parent; spacing: 0
                Item {
                    Layout.fillWidth: true; Layout.preferredHeight: Theme.headerBarHeight
                    Text {
                        anchors.left: parent.left; anchors.leftMargin: Theme.rowInset
                        anchors.verticalCenter: parent.verticalCenter
                        text: L10n.tr("export.title")
                        color: Theme.text
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontRail; font.weight: Theme.weightTitle
                    }
                }
                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.ruleRegion }
                ScrollView {
                    id: railScroll
                    Layout.fillWidth: true; Layout.fillHeight: true
                    contentWidth: availableWidth
                    clip: true
                    ColumnLayout {
                        width: railScroll.availableWidth
                        spacing: 0
                        property real railLabelWidth: page.labelColumn

                        // ---- Export Formula ----
                        MacSection {
                            sectionId: "exportFormula"
                            title: L10n.tr("export.formula.title")
                            menuItems: [
                                RailMenuItem { text: L10n.tr("export.formula.new"); onTriggered: exportRecipes.add() },
                                RailMenuItem { text: L10n.tr("export.formula.duplicate"); onTriggered: exportRecipes.duplicate() },
                                RailMenuItem { text: L10n.tr("export.formula.rename"); onTriggered: renameDialog.open() },
                                MenuSeparator {},
                                RailMenuItem { text: L10n.tr("export.formula.delete"); enabled: exportRecipes.recipes.length > 1; onTriggered: exportRecipes.remove() },
                                MenuSeparator {},
                                RailMenuItem { text: L10n.tr("export.formula.reveal"); onTriggered: exportRecipes.revealRecipesFile() }
                            ]
                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: recipeList.height + 34
                                radius: 6; color: Theme.navigatorWell
                                ListView {
                                    id: recipeList
                                    objectName: "exportRecipeList"
                                    x: 1; y: 6; width: parent.width - 2
                                    height: Math.min(contentHeight, 144)
                                    clip: true
                                    model: exportRecipes.recipes
                                    spacing: 1
                                    delegate: Rectangle {
                                        required property var modelData
                                        required property int index
                                        width: recipeList.width; height: Theme.listRowHeight
                                        radius: height / 2
                                        color: index === exportRecipes.selectedIndex ? Theme.selection : rowHover.hovered ? Theme.hover : "transparent"
                                        Text {
                                            anchors.left: parent.left; anchors.leftMargin: 14
                                            anchors.right: parent.right; anchors.rightMargin: 8
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: modelData.name
                                            elide: Text.ElideRight
                                            color: index === exportRecipes.selectedIndex ? Theme.selectionInk : Theme.secondaryText
                                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall; font.weight: Theme.weightText
                                        }
                                        HoverHandler { id: rowHover }
                                        TapHandler { onTapped: exportRecipes.select(index); onDoubleTapped: renameDialog.open() }
                                    }
                                }
                                Row {
                                    anchors.right: parent.right; anchors.rightMargin: 10
                                    anchors.bottom: parent.bottom; anchors.bottomMargin: 4
                                    spacing: 4
                                    IconButton { size: 22; glyphSize: 10; glyph: Icons.add; toolTip: L10n.tr("export.formula.newHelp"); onClicked: exportRecipes.add() }
                                    IconButton { size: 22; glyphSize: 10; glyph: Icons.remove; available: exportRecipes.recipes.length > 1
                                                 toolTip: L10n.tr("export.formula.deleteHelp"); reason: L10n.tr("export.formula.lastRecipe")
                                                 onClicked: exportRecipes.remove() }
                                }
                            }
                        }

                        // ---- Location ----
                        MacSection {
                            sectionId: "exportLocation"
                            title: L10n.tr("export.location.title")
                            menuItems: [
                                RailMenuItem { text: L10n.tr("export.location.choose"); onTriggered: folderDialog.openRemembered() },
                                RailMenuItem { text: L10n.tr("export.location.useOwn"); onTriggered: exportRecipes.setBesideOriginal() },
                                MenuSeparator {},
                                RailMenuItem { text: L10n.tr("export.location.clearSubfolder"); onTriggered: exportRecipes.setSubfolder("") },
                                RailMenuItem { text: L10n.tr("export.location.reveal"); enabled: page.folders.length > 0; onTriggered: exportRecipes.reveal(page.folders[0]) }
                            ]
                            ParamRow {
                                label: L10n.tr("export.location.folder")
                                toolTip: page.recipe.besideOriginal ? L10n.tr("export.location.besideHelp") : L10n.tr("export.location.fixedHelp")
                                PillDropdown {
                                    objectName: "exportFolderPicker"
                                    model: page.recipe.besideOriginal ? [L10n.tr("export.location.beside"), L10n.tr("export.location.chooseItem")]
                                                                      : [L10n.tr("export.location.beside"), page.recipe.folderLabel, L10n.tr("export.location.chooseItem")]
                                    readonly property int shown: { model; return page.recipe.besideOriginal ? 0 : 1 }
                                    currentIndex: shown
                                    // "Choose..." is an action, not a place: the pill goes back to
                                    // the recipe's folder, and follows it when the dialog sets one.
                                    // A plain assignment here would end the binding for good -- the
                                    // pill then stayed on "Beside the original" after a choice.
                                    onActivated: function(i) {
                                        if (i === 0) exportRecipes.setBesideOriginal()
                                        else if (i === model.length - 1) folderDialog.openRemembered()
                                        currentIndex = Qt.binding(function() { return shown })
                                    }
                                }
                            }
                            ParamRow {
                                label: L10n.tr("export.location.subfolder")
                                ExportField {
                                    anchors.fill: parent; anchors.topMargin: 2; anchors.bottomMargin: 2
                                    modelText: page.recipe.subfolder
                                    placeholder: L10n.tr("export.location.none")
                                    onCommitted: function(v) { exportRecipes.setSubfolder(v) }
                                }
                            }
                            ParamRow {
                                label: L10n.tr("export.location.existing")
                                toolTip: L10n.tr("export.location.existingHelp")
                                PillDropdown {
                                    model: [L10n.tr("export.existing.addSuffix"), L10n.tr("export.existing.overwrite"), L10n.tr("export.existing.skip")]
                                    currentIndex: { model; return page.recipe.existing }
                                    onActivated: function(i) { exportRecipes.setExisting(i) }
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 6
                                Note { text: page.destinationSummary; Layout.fillWidth: true; wrapMode: Text.WrapAnywhere }
                                ActionButton {
                                    text: L10n.tr("export.location.revealShort")
                                    implicitHeight: 18; leftPadding: 8; rightPadding: 8
                                    enabled: page.folders.length > 0
                                    onClicked: exportRecipes.reveal(page.folders[0])
                                }
                            }
                        }

                        // ---- Naming ----
                        MacSection {
                            sectionId: "exportNaming"
                            title: L10n.tr("export.naming.title")
                            menuItems: [
                                RailMenuItem { text: L10n.tr("export.naming.originalOnly"); onTriggered: exportRecipes.originalNameOnly() },
                                RailMenuItem { text: L10n.tr("export.naming.selectAll"); onTriggered: exportRecipes.selectAllTokens() },
                                MenuSeparator {},
                                RailMenuItem { text: L10n.tr("export.naming.resetOrder"); onTriggered: exportRecipes.resetTokenOrder() }
                            ]
                            RowLayout {
                                Layout.fillWidth: true; spacing: 0
                                Text {
                                    Layout.preferredWidth: page.labelColumn; Layout.alignment: Qt.AlignTop; Layout.topMargin: 1
                                    text: L10n.tr("export.naming.format")
                                    color: Theme.secondaryText
                                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel; font.weight: Theme.weightText
                                }
                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 5
                                    Repeater {
                                        model: page.recipe.chips
                                        TokenChip {
                                            required property var modelData
                                            token: modelData.token
                                            label: modelData.token === "filmStock" ? L10n.tr("export.token.filmStock")
                                                 : modelData.token === "printStock" ? L10n.tr("export.token.printStock")
                                                 : modelData.token === "date" ? L10n.tr("export.token.date")
                                                 : L10n.tr("export.token.originalName")
                                            on: modelData.on
                                            last: page.recipe.tokenCount === 1
                                            onToggled: exportRecipes.toggleToken(token)
                                            onMoved: function(t, before) { exportRecipes.moveToken(t, before) }
                                        }
                                    }
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 0
                                Text {
                                    Layout.preferredWidth: page.labelColumn; Layout.alignment: Qt.AlignTop
                                    text: L10n.tr("export.naming.fileName")
                                    color: Theme.secondaryText
                                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel; font.weight: Theme.weightText
                                }
                                TextEdit {
                                    objectName: "exportSampleName"
                                    Layout.fillWidth: true
                                    readOnly: true; selectByMouse: true
                                    wrapMode: TextEdit.WrapAnywhere
                                    text: page.sampleName
                                    color: Theme.text
                                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall; font.weight: Theme.weightText
                                }
                            }
                        }

                        // ---- Format and Size ----
                        MacSection {
                            sectionId: "exportFormat"
                            title: L10n.tr("export.format.title")
                            ParamRow {
                                label: L10n.tr("export.format")
                                RowLayout {
                                    anchors.fill: parent; spacing: 8
                                    PillDropdown {
                                        Layout.fillWidth: true; Layout.preferredHeight: Theme.controlHeight
                                        model: [L10n.tr("export.format.jpeg"), L10n.tr("export.format.png"), L10n.tr("export.format.tiff"), L10n.tr("export.format.di")]
                                        currentIndex: { model; return page.recipe.format }
                                        onActivated: function(i) { exportRecipes.setFormat(i) }
                                    }
                                    PillDropdown {
                                        Layout.preferredWidth: 64; Layout.preferredHeight: Theme.controlHeight
                                        model: [L10n.tr("export.depth.bits", [8]), L10n.tr("export.depth.bits", [16])]
                                        currentIndex: { model; return page.recipe.bitDepth === 16 ? 1 : 0 }
                                        available: page.recipe.depthChoosable
                                        toolTip: L10n.tr("export.depth.help")
                                        reason: L10n.tr("export.depth.fixed", [page.recipe.formatLabel])
                                        onActivated: function(i) { exportRecipes.setDepth(i === 1 ? 16 : 8) }
                                    }
                                }
                            }
                            Note { visible: page.recipe.isDI; text: L10n.tr("export.di.what") + "\n" + L10n.tr("export.di.next") }
                            ParamRow {
                                visible: page.recipe.takesColorSpace
                                label: L10n.tr("export.colorSpace")
                                toolTip: L10n.tr("export.colorSpace.help")
                                PillDropdown {
                                    objectName: "exportColorSpace"
                                    model: exportRecipes.colorSpaceNames
                                    currentIndex: page.recipe.colorSpaceIndex
                                    displayText: page.recipe.colorSpaceName
                                    onActivated: function(i) { exportRecipes.setColorSpace(i) }
                                }
                            }
                            ScrubSlider {
                                visible: page.recipe.takesQuality
                                label: L10n.tr("export.quality")
                                from: 30; to: 100; defaultValue: 95; step: 1; snap: 5; decimals: 0
                                value: Math.round(page.recipe.quality * 100)
                                onMoved: function(v) { exportRecipes.setQuality(Math.round(v) / 100) }
                            }
                            CheckRow {
                                visible: page.recipe.carriesPreviewPage
                                label: L10n.tr("export.preview")
                                toolTip: L10n.tr("export.preview.help")
                                checked: page.recipe.embedsPreview
                                onToggledTo: function(on) { exportRecipes.setEmbedsPreview(on) }
                            }
                            ParamRow {
                                label: L10n.tr("export.size")
                                toolTip: L10n.tr("export.size.help")
                                RowLayout {
                                    anchors.fill: parent; spacing: 6
                                    PillDropdown {
                                        Layout.fillWidth: true; Layout.preferredHeight: Theme.controlHeight
                                        model: [L10n.tr("export.size.original"), L10n.tr("export.size.longEdge")]
                                        currentIndex: { model; return page.recipe.longEdge > 0 ? 1 : 0 }
                                        onActivated: function(i) {
                                            exportRecipes.setLongEdge(i === 0 ? 0 : Math.max(16, Math.max(page.frameWidth, page.frameHeight, 16)))
                                        }
                                    }
                                    ExportField {
                                        visible: page.recipe.longEdge > 0
                                        Layout.preferredWidth: 64; Layout.preferredHeight: Theme.controlHeight
                                        numeric: true
                                        modelText: String(page.recipe.longEdge)
                                        onCommitted: function(v) { var n = parseInt(v); if (n > 0) exportRecipes.setLongEdge(n) }
                                        ToolTip.visible: hovered; ToolTip.delay: 600
                                        ToolTip.text: L10n.tr("export.size.edgeHelp")
                                    }
                                }
                            }
                            Note { text: page.sizeLine; Layout.leftMargin: page.labelColumn }
                            ParamRow {
                                label: L10n.tr("export.openWith")
                                toolTip: L10n.tr("export.openWith.help")
                                PillDropdown {
                                    readonly property var values: ["", "default", "explorer"]
                                    readonly property bool custom: values.indexOf(page.recipe.openWith) < 0
                                    model: {
                                        var m = [L10n.tr("export.openWith.none"), L10n.tr("export.openWith.default"), L10n.tr("export.openWith.explorer")]
                                        if (custom) m.push(page.recipe.openWithLabel)
                                        m.push(L10n.tr("export.openWith.choose"))
                                        return m
                                    }
                                    readonly property int shown: { model; return custom ? 3 : values.indexOf(page.recipe.openWith) }
                                    currentIndex: shown
                                    onActivated: function(i) {
                                        if (i < 3) exportRecipes.setOpenWith(values[i])
                                        else if (i === model.length - 1) appDialog.openRemembered()
                                        currentIndex = Qt.binding(function() { return shown })
                                    }
                                }
                            }
                        }

                        // ---- Metadata (Windows) ----
                        MacSection {
                            sectionId: "exportMetadata"
                            title: L10n.tr("export.metadata.title")
                            CheckRow {
                                label: L10n.tr("export.metadata.exif")
                                toolTip: L10n.tr("export.metadata.exifHelp")
                                checked: page.recipe.exif
                                onToggledTo: function(on) { exportRecipes.setMetadata("exif", on) }
                            }
                            CheckRow { label: L10n.tr("export.metadata.camera"); available: page.recipe.exif; checked: page.recipe.exifCamera
                                       onToggledTo: function(on) { exportRecipes.setMetadata("camera", on) } }
                            CheckRow { label: L10n.tr("export.metadata.lens"); available: page.recipe.exif; checked: page.recipe.exifLens
                                       onToggledTo: function(on) { exportRecipes.setMetadata("lens", on) } }
                            CheckRow { label: L10n.tr("export.metadata.exposure"); available: page.recipe.exif; checked: page.recipe.exifExposure
                                       onToggledTo: function(on) { exportRecipes.setMetadata("exposure", on) } }
                            CheckRow { label: L10n.tr("export.metadata.date"); available: page.recipe.exif; checked: page.recipe.exifDate
                                       onToggledTo: function(on) { exportRecipes.setMetadata("date", on) } }
                        }

                        // ---- Summary ----
                        MacSection {
                            sectionId: "exportSummary"
                            title: L10n.tr("export.summary.title")
                            divider: false
                            menuItems: [ RailMenuItem { text: L10n.tr("export.summary.copy"); onTriggered: exportRecipes.copyText(page.summaryLines.join("\n")) } ]
                            Repeater {
                                model: page.summaryLines
                                Note { required property string modelData; text: modelData; color: Theme.secondaryText; wrapMode: Text.WrapAnywhere }
                            }
                        }
                    }
                }
                // ---- the footer ----
                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.rule }
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.margins: 12
                    spacing: 6
                    Note { visible: exportRecipes.problem.length > 0; text: exportRecipes.problem; color: Theme.warning }
                    Note {
                        objectName: "exportResult"
                        visible: page.resultText.length > 0
                        text: page.resultText
                        color: page.resultWarning ? Theme.accent : Theme.secondaryText
                        wrapMode: Text.WrapAnywhere
                        maximumLineCount: 8; elide: Text.ElideRight
                    }
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        ProgressBar {
                            visible: page.running
                            Layout.preferredWidth: 70
                            from: 0; to: Math.max(1, preview.batchTotal); value: preview.batchProgress
                        }
                        Text {
                            Layout.fillWidth: true
                            text: page.running ? L10n.tr("export.running", [preview.batchProgress, preview.batchTotal])
                                 : page.worklist.length === 0 ? L10n.tr("export.noImages")
                                 : L10n.tr(page.worklist.length === 1 ? "export.oneImage" : "export.images", [page.worklist.length])
                            color: Theme.dim
                            elide: Text.ElideRight
                            font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
                        }
                        ActionButton {
                            visible: page.running
                            text: L10n.tr("export.stop")
                            onClicked: preview.cancelExport()
                        }
                        ActionButton {
                            objectName: "exportRunButton"
                            accented: true
                            text: page.running ? L10n.tr("export.exporting") : L10n.tr("export.export")
                            enabled: !page.running && !preview.busy && page.worklist.length > 0
                            onClicked: page.run()
                        }
                    }
                }
            }
            Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.ruleRegion }
        }

        // ===================== the proof =====================
        Item {
            Layout.fillWidth: true; Layout.fillHeight: true
            // The bar: the count, and the way back to the editor.
            Rectangle {
                id: bar
                anchors.top: parent.top; anchors.topMargin: 6
                anchors.horizontalCenter: parent.horizontalCenter
                width: barRow.implicitWidth + 24; height: Theme.zoomPillHeight + 8
                radius: height / 2; color: Theme.card
                RowLayout {
                    id: barRow
                    anchors.centerIn: parent; spacing: 12
                    Text {
                        text: L10n.tr(page.worklist.length === 1 ? "export.oneImage" : "export.images", [page.worklist.length])
                        color: Theme.text
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall; font.weight: Theme.weightText
                    }
                    ActionButton {
                        objectName: "exportCloseButton"
                        text: L10n.tr("export.close")
                        implicitHeight: 20
                        enabled: !page.running
                        onClicked: page.close()
                    }
                }
            }
            FrameCanvas {
                id: proofCanvas
                objectName: "exportProofCanvas"
                anchors.fill: parent
                anchors.topMargin: bar.height + 24; anchors.bottomMargin: 64
                anchors.leftMargin: 24; anchors.rightMargin: 24
                image: preview.exportProof
                enabled: false
                visible: preview.hasFrame
            }
            Text {
                anchors.centerIn: parent
                visible: !preview.hasFrame
                text: L10n.tr("export.nothingOpen")
                color: Theme.dim
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel; font.weight: Theme.weightText
            }
            Rectangle {
                anchors.bottom: parent.bottom; anchors.bottomMargin: 14
                anchors.horizontalCenter: parent.horizontalCenter
                visible: preview.hasFrame && preview.exportProofInfo.space !== undefined
                width: caption.implicitWidth + 20; height: caption.implicitHeight + 10
                radius: 6; color: Qt.rgba(0.176, 0.176, 0.172, 0.9)
                Column {
                    id: caption
                    anchors.centerIn: parent; spacing: 2
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: L10n.tr("export.proof.caption", [preview.exportProofInfo.space !== undefined ? preview.exportProofInfo.space : ""])
                        color: Theme.secondaryText
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        readonly property real clipped: preview.exportProofInfo.clipped !== undefined ? preview.exportProofInfo.clipped : 0
                        visible: clipped >= 0.0001
                        text: L10n.tr("export.proof.clipped", [clipped >= 0.01 ? Math.round(clipped * 100) + " %" : (clipped * 100).toFixed(1) + " %",
                                                               preview.exportProofInfo.space !== undefined ? preview.exportProofInfo.space : ""])
                        color: Theme.accent
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: preview.exportProofInfo.digitalIntermediate === true
                        text: L10n.tr("export.proof.di")
                        color: Theme.dim
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
                    }
                }
            }
        }

        // ===================== the worklist =====================
        Rectangle {
            Layout.preferredWidth: 200; Layout.fillHeight: true
            color: Theme.card
            Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: Theme.ruleRegion }
            ListView {
                id: strip
                objectName: "exportWorklist"
                anchors.fill: parent; anchors.margins: 12
                clip: true
                spacing: 10
                model: page.worklist
                delegate: Item {
                    id: cell
                    required property var modelData
                    width: strip.width; height: 110
                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 0; width: parent.width; height: 88
                        color: "transparent"
                        border.width: cell.modelData.active ? 2 : 0
                        border.color: Theme.selectionFrame
                        radius: 2
                        // The whole photo under its crop mask, as the strip shows it\r
                        // (CropMaskedThumbnail.swift); until one is read, its place.
                        Rectangle { anchors.fill: parent; anchors.margins: 3; color: Theme.navigatorWell }
                        FrameCanvas {
                            anchors.fill: parent; anchors.margins: 3
                            image: cell.modelData.thumbnail
                            enabled: false
                        }
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 92; width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: cell.modelData.name
                        elide: Text.ElideMiddle
                        color: cell.modelData.error ? Theme.warning : Theme.text
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
                    }
                    // Read-only here: the page is modal, and the controller
                    // holds the open photo and the selection while any
                    // dialog is up. The batch is chosen in the filmstrip.
                }
                Text {
                    anchors.centerIn: parent; width: parent.width
                    visible: page.worklist.length === 0
                    wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter
                    text: L10n.tr("export.worklistEmpty")
                    color: Theme.dim
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontLabel; font.weight: Theme.weightText
                }
            }
        }
    }
}
