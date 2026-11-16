import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import SpektraLab.Native 1.0

ApplicationWindow {
    id: window
    objectName: "editorWindow"
    width: 1540; height: 980
    minimumWidth: 1100; minimumHeight: 740
    visible: true
    color: Theme.card
    title: (preview.hasFrame ? preview.fileName + " — " : "") + "SpektraLab"
    font.family: "Segoe UI"
    font.pixelSize: 12
    palette.window: Theme.card
    palette.windowText: Theme.text
    palette.text: Theme.text
    palette.buttonText: Theme.text
    palette.base: Theme.well
    palette.button: Theme.well
    palette.highlight: Theme.accent
    property bool closePending: false
    property bool cropMode: false
    property rect draftCrop: Qt.rect(0, 0, 1, 1)
    property int exportFormat: 0
    property int exportQuality: 95
    property int exportLongEdge: 0
    property int exportOutputSpace: 0
    property bool exportCopyMetadata: false
    property string advancedPage: "chemistry"
    readonly property bool canEditCrop: preview.hasFrame && !preview.busy && !preview.batchExporting
    readonly property bool canBrowse: preview.ready && !preview.busy && !preview.batchExporting && !cropMode
    // Text controls keep their own undo stack while they own keyboard focus.
    readonly property bool editingText: activeFocusItem !== null && typeof activeFocusItem.text === "string" && typeof activeFocusItem.undo === "function"
    onCropModeChanged: updateDialogState()

    function updateDialogState() {
        preview.setDialogOpen(cropMode || openDialog.visible || saveDialog.visible || batchDialog.visible ||
                              createCatalogDialog.visible || openCatalogDialog.visible || exportPopup.visible)
    }
    function startCrop() {
        if (!canEditCrop) return
        draftCrop = preview.cropRect
        cropMode = true
        Qt.callLater(function() { canvas.resetView(true) })
    }
    function finishCrop() {
        var next = draftCrop
        var commit = cropMode && canEditCrop
        cropMode = false
        if (commit) preview.setCropRect(next)
        Qt.callLater(function() { canvas.resetView(true) })
    }
    function cancelCrop() { cropMode = false; canvas.resetView(true) }
    function filmGroup(positive) {
        var rows = []
        for (var i = 0; i < preview.films.length; ++i)
            if (preview.films[i].positive === positive)
                rows.push({ "name": preview.films[i].name, "catalogIndex": i })
        return rows
    }
    function openExport() { if (preview.hasFrame && !preview.busy && !cropMode) exportPopup.open() }
    function showExportOptions() { openExport() }
    function formatFilter() {
        if (exportFormat === 3) return ["JPEG 图像 (*.jpg *.jpeg)"]
        if (exportFormat === 4) return ["HEIF 图像 (*.heic *.heif)"]
        if (exportFormat === 1 || exportFormat === 2) return ["PNG 图像 (*.png)"]
        return ["16 位 TIFF (*.tif *.tiff)"]
    }
    onClosing: function(event) {
        if (preview.batchExporting) preview.cancelExport()
        if (preview.busy) { closePending = true; event.accepted = false }
    }
    Connections {
        target: preview
        function onStateChanged() { if (window.closePending && !preview.busy) window.close() }
        function onSourceOpened() { window.cropMode = false; canvas.resetView(true) }
    }
    FileDialog {
        id: openDialog
        title: "导入一张或多张 RAW 照片"
        fileMode: FileDialog.OpenFiles
        nameFilters: ["相机 RAW (*.arw *.nef *.nrw *.dng *.cr2 *.cr3 *.raf *.rw2 *.orf *.pef *.srw)", "所有文件 (*)"]
        onVisibleChanged: window.updateDialogState()
        onAccepted: preview.openFiles(selectedFiles)
    }
    FileDialog {
        id: createCatalogDialog
        title: "新建 SpektraLab 目录"
        fileMode: FileDialog.SaveFile
        nameFilters: ["SpektraLab 目录 (*.spkcatalog)"]
        defaultSuffix: "spkcatalog"
        onVisibleChanged: window.updateDialogState()
        onAccepted: preview.createLibraryCatalog(selectedFile)
    }
    FolderDialog {
        id: openCatalogDialog
        title: "打开 SpektraLab 目录"
        onVisibleChanged: window.updateDialogState()
        onAccepted: preview.openLibraryCatalog(selectedFolder)
    }
    FolderDialog {
        id: linkedFolderDialog
        title: "链接已有 RAW 文件夹"
        onVisibleChanged: window.updateDialogState()
        onAccepted: preview.addLinkedFolder(selectedFolder)
    }
    FileDialog {
        id: saveDialog
        title: "导出当前画面 · 不覆盖现有文件"
        fileMode: FileDialog.SaveFile
        nameFilters: window.formatFilter()
        defaultSuffix: window.exportFormat === 3 ? "jpg" : window.exportFormat === 4 ? "heic" :
                       window.exportFormat === 0 ? "tif" : "png"
        currentFolder: preview.sourceFolder
        onVisibleChanged: window.updateDialogState()
        onAccepted: preview.exportImageWithRecipe(selectedFile, window.exportFormat, window.exportQuality, window.exportLongEdge, window.exportOutputSpace, window.exportCopyMetadata)
    }
    FolderDialog {
        id: batchDialog
        title: "选择批量导出文件夹 · 跳过已有文件"
        currentFolder: preview.sourceFolder
        onVisibleChanged: window.updateDialogState()
        onAccepted: preview.exportBatchWithRecipe(selectedFolder, window.exportFormat, window.exportQuality, window.exportLongEdge, window.exportOutputSpace, window.exportCopyMetadata)
    }
    Shortcut { sequences: [StandardKey.Open]; enabled: window.canBrowse; onActivated: openDialog.open() }
    Shortcut { sequence: "Ctrl+E"; enabled: preview.hasFrame && !preview.busy && !window.cropMode; onActivated: window.openExport() }
    Shortcut { sequence: "Ctrl+0"; enabled: preview.hasFrame; onActivated: canvas.resetView(true) }
    Shortcut { sequence: "Ctrl+1"; enabled: preview.hasFrame && !window.cropMode; onActivated: canvas.resetView(false) }
    Shortcut { sequence: "Ctrl+Z"; enabled: preview.settingsEditable && preview.canUndo && !window.cropMode && !window.editingText; onActivated: preview.undo() }
    Shortcut { sequences: ["Ctrl+Shift+Z", "Ctrl+Y"]; enabled: preview.settingsEditable && preview.canRedo && !window.cropMode && !window.editingText; onActivated: preview.redo() }
    Shortcut { sequence: "Escape"; enabled: window.cropMode; onActivated: window.cancelCrop() }
    Shortcut { sequence: "Return"; enabled: window.cropMode; onActivated: window.finishCrop() }

    component Note: Text {
        Layout.fillWidth: true
        color: Theme.muted
        font.pixelSize: 10
        wrapMode: Text.WordWrap
        lineHeight: 1.35
    }
    component Adjustment: ColumnLayout {
        id: adjustment
        property string label
        property string setting
        property real from: 0
        property real to: 2
        property real step: 0.05
        property int decimals: 2
        property string suffix: ""
        property real fallback: 0
        property bool available: true
        readonly property real current: preview.adjustments[setting] === undefined ? fallback : Number(preview.adjustments[setting])
        Layout.fillWidth: true; spacing: 2
        RowLayout {
            Layout.fillWidth: true
            Text { text: adjustment.label; color: adjustment.available ? Theme.text : Theme.muted; font.pixelSize: 11 }
            Item { Layout.fillWidth: true }
            Text { text: adjustment.current.toFixed(adjustment.decimals) + adjustment.suffix; color: Theme.muted; font.pixelSize: 10 }
        }
        Slider {
            Layout.fillWidth: true; implicitHeight: 24
            from: adjustment.from; to: adjustment.to; stepSize: adjustment.step
            value: adjustment.current
            enabled: preview.settingsEditable && adjustment.available
            onPressedChanged: {
                if (pressed) preview.beginEditGesture(adjustment.setting)
                else preview.endEditGesture()
            }
            onMoved: preview.setAdjustment(adjustment.setting, value)
        }
    }
    component Effect: ColumnLayout {
        id: effect
        property string label
        property string activeKey
        property string amountKey
        property real maximum: 2
        Layout.fillWidth: true; spacing: 1
        CheckBox {
            text: effect.label; font.pixelSize: 11
            palette.windowText: Theme.text
            checked: preview.adjustments[effect.activeKey] === undefined ? true : preview.adjustments[effect.activeKey]
            enabled: preview.settingsEditable
            onToggled: preview.setAdjustment(effect.activeKey, checked)
        }
        Adjustment { label: "强度"; setting: effect.amountKey; fallback: 1; from: 0; to: effect.maximum; available: preview.adjustments[effect.activeKey] !== false }
    }
    component Toggle: CheckBox {
        id: toggle
        property string label
        property string setting
        text: label; font.pixelSize: 11
        palette.windowText: Theme.text
        checked: preview.adjustments[setting] === true
        enabled: preview.settingsEditable
        onToggled: preview.setAdjustment(setting, checked)
    }
    component Choice: RowLayout {
        id: choice
        property string label
        property string setting
        property var labels: []
        property var values: []
        Layout.fillWidth: true
        Text { text: choice.label; color: Theme.text; font.pixelSize: 11; Layout.preferredWidth: 92 }
        ComboBox {
            Layout.fillWidth: true
            model: choice.labels
            currentIndex: choice.values.indexOf(preview.adjustments[choice.setting])
            enabled: preview.settingsEditable
            onActivated: preview.setAdjustment(choice.setting, choice.values[currentIndex])
        }
    }
    component SettingText: RowLayout {
        id: settingText
        property string label
        property string setting
        property string placeholder
        Layout.fillWidth: true
        Text { text: settingText.label; color: Theme.text; font.pixelSize: 11; Layout.preferredWidth: 92 }
        TextField {
            Layout.fillWidth: true
            text: preview.adjustments[settingText.setting] === undefined ? "" : String(preview.adjustments[settingText.setting])
            placeholderText: settingText.placeholder
            enabled: preview.settingsEditable
            onEditingFinished: preview.setAdjustment(settingText.setting, text)
        }
    }
    component FilmGroup: ColumnLayout {
        id: group
        property bool positive: false
        Layout.fillWidth: true; spacing: 3
        Text { text: group.positive ? "反转片 · Positive" : "负片 · Negative"; color: Theme.muted; font.pixelSize: 10; font.bold: true }
        ListView {
            id: list
            objectName: group.positive ? "positiveFilmList" : "filmList"
            Layout.fillWidth: true; Layout.preferredHeight: group.positive ? 112 : 174
            model: window.filmGroup(group.positive); clip: true
            currentIndex: {
                for (var i = 0; i < model.length; ++i)
                    if (model[i].catalogIndex === preview.filmIndex) return i
                return -1
            }
            onCurrentIndexChanged: { if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain) }
            onCountChanged: Qt.callLater(function() { if (list.currentIndex >= 0) list.positionViewAtIndex(list.currentIndex, ListView.Contain) })
            ScrollBar.vertical: ScrollBar {}
            delegate: Rectangle {
                required property var modelData
                width: list.width; height: 27; radius: 4
                color: modelData.catalogIndex === preview.filmIndex ? Theme.selection : filmMouse.containsMouse ? "#41413e" : "transparent"
                Text {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 6
                    verticalAlignment: Text.AlignVCenter; text: modelData.name
                    color: modelData.catalogIndex === preview.filmIndex ? Theme.selectionText : preview.settingsEditable ? Theme.text : Theme.muted
                    font.pixelSize: 10; elide: Text.ElideRight
                }
                MouseArea { id: filmMouse; anchors.fill: parent; hoverEnabled: true; enabled: preview.settingsEditable; onClicked: preview.filmIndex = modelData.catalogIndex }
            }
        }
    }

    RowLayout {
        anchors.fill: parent; spacing: 1
        Rectangle {
            Layout.preferredWidth: Theme.leftWidth; Layout.fillHeight: true; color: Theme.card
            ColumnLayout {
                anchors.fill: parent; spacing: 0
                Text { text: "胶片与相纸"; color: Theme.text; font.pixelSize: 14; font.bold: true; Layout.leftMargin: 14; Layout.preferredHeight: Theme.topHeight; verticalAlignment: Text.AlignVCenter }
                ScrollView {
                    Layout.fillWidth: true; Layout.fillHeight: true; clip: true; contentWidth: availableWidth
                    ColumnLayout {
                        width: parent.width; spacing: 0
                        Section {
                            title: "导航图"
                            Rectangle {
                                Layout.fillWidth: true; Layout.preferredHeight: 132; color: Theme.wellDark
                                FrameCanvas { anchors.fill: parent; anchors.margins: 6; image: preview.previewImage; enabled: false }
                                Text { anchors.centerIn: parent; visible: !preview.hasFrame; text: "导入照片开始"; color: Theme.muted; font.pixelSize: 11 }
                            }
                            RowLayout {
                                ActionButton { text: "适合"; implicitHeight: 23; enabled: preview.hasFrame; onClicked: canvas.resetView(true) }
                                Item { Layout.fillWidth: true }
                                Text { text: preview.hasFrame ? canvas.scalePercent.toFixed(1) + "%" : ""; color: Theme.muted; font.pixelSize: 10 }
                            }
                        }
                        Section {
                            title: "胶片"
                            FilmGroup { positive: true }
                            FilmGroup { positive: false }
                        }
                        Section {
                            title: "相纸"
                            Note { visible: preview.filmIsPositive; text: "反转片直接扫描，不使用相纸。"; color: Theme.accent }
                            ListView {
                                id: papers; objectName: "paperList"
                                Layout.fillWidth: true; Layout.preferredHeight: 174; clip: true
                                model: preview.papers; currentIndex: preview.paperIndex
                                onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
                                onCountChanged: Qt.callLater(function() { papers.positionViewAtIndex(preview.paperIndex, ListView.Contain) })
                                ScrollBar.vertical: ScrollBar {}
                                delegate: Rectangle {
                                    required property var modelData
                                    required property int index
                                    width: papers.width; height: 27; radius: 4
                                    color: !preview.filmIsPositive && index === preview.paperIndex ? Theme.selection : paperMouse.containsMouse && paperMouse.enabled ? "#41413e" : "transparent"
                                    Text {
                                        anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 6; verticalAlignment: Text.AlignVCenter; text: modelData.name
                                        color: !preview.filmIsPositive && index === preview.paperIndex ? Theme.selectionText : preview.settingsEditable && !preview.filmIsPositive ? Theme.text : Theme.muted
                                        font.pixelSize: 10; elide: Text.ElideRight
                                    }
                                    MouseArea { id: paperMouse; anchors.fill: parent; hoverEnabled: true; enabled: preview.settingsEditable && !preview.filmIsPositive; onClicked: preview.paperIndex = index }
                                }
                            }
                        }
                        Section {
                            title: "裁切"
                            RowLayout {
                                Layout.fillWidth: true
                                ComboBox {
                                    id: cropAspect; Layout.fillWidth: true
                                    model: ["自由比例", "1:1", "3:2", "4:3", "16:9"]; enabled: window.canEditCrop
                                    currentIndex: {
                                        var c = preview.cropRect
                                        if (!preview.hasFrame || (c.x === 0 && c.y === 0 && c.width === 1 && c.height === 1)) return 0
                                        var ratio = c.width * preview.metadata.sourceWidth / (c.height * preview.metadata.sourceHeight)
                                        if (preview.quarterTurns % 2 !== 0) ratio = 1 / ratio
                                        var values = [0, 1, 1.5, 4 / 3, 16 / 9]
                                        for (var i = 1; i < values.length; ++i)
                                            if (Math.abs(ratio - values[i]) < 0.002) return i
                                        return 0
                                    }
                                    onActivated: { window.cropMode = false; preview.setCropAspect([0, 1, 1.5, 4 / 3, 16 / 9][currentIndex]); canvas.resetView(true) }
                                }
                                ActionButton { text: "重置"; enabled: window.canEditCrop; onClicked: { window.cropMode = false; preview.resetCrop(); canvas.resetView(true) } }
                            }
                            ActionButton { Layout.fillWidth: true; text: window.cropMode ? "完成裁切" : "在画面中拖选裁切"; accented: window.cropMode; enabled: window.canEditCrop; onClicked: window.cropMode ? window.finishCrop() : window.startCrop() }
                            Note { text: window.cropMode ? "在未旋转原图上拖出矩形；完成后恢复方向与拉直。Enter 确认，Esc 取消。" : "预览与导出使用同一裁切与方向；原始 RAW 不变。" }
                            RowLayout {
                                Layout.fillWidth: true
                                ActionButton { objectName: "rotateLeftButton"; Layout.fillWidth: true; text: "左转 90°"; enabled: window.canEditCrop && !window.cropMode; onClicked: { preview.rotateCounterClockwise(); canvas.resetView(true) } }
                                ActionButton { objectName: "rotateRightButton"; Layout.fillWidth: true; text: "右转 90°"; enabled: window.canEditCrop && !window.cropMode; onClicked: { preview.rotateClockwise(); canvas.resetView(true) } }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                ActionButton { objectName: "flipHorizontalButton"; Layout.fillWidth: true; text: "水平翻转"; accented: preview.flipHorizontal; enabled: window.canEditCrop && !window.cropMode; onClicked: preview.setFlipHorizontal(!preview.flipHorizontal) }
                                ActionButton { objectName: "flipVerticalButton"; Layout.fillWidth: true; text: "垂直翻转"; accented: preview.flipVertical; enabled: window.canEditCrop && !window.cropMode; onClicked: preview.setFlipVertical(!preview.flipVertical) }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                Text { text: "拉直"; color: Theme.text; font.pixelSize: 11 }
                                Item { Layout.fillWidth: true }
                                Text { text: (straightenSlider.pressed ? straightenSlider.from + straightenSlider.position * (straightenSlider.to - straightenSlider.from) : preview.straightenDegrees).toFixed(1) + "°"; color: Theme.muted; font.pixelSize: 10 }
                            }
                            Slider {
                                id: straightenSlider; objectName: "straightenSlider"
                                Layout.fillWidth: true; implicitHeight: 24
                                from: -45; to: 45; stepSize: 0.1; live: false
                                value: preview.straightenDegrees
                                enabled: window.canEditCrop && !window.cropMode
                                onPressedChanged: {
                                    if (pressed) preview.beginEditGesture("straightenDegrees")
                                    else {
                                        preview.setStraightenDegrees(Math.round((from + position * (to - from)) * 10) / 10)
                                        preview.endEditGesture()
                                    }
                                }
                                onMoved: { if (!pressed) preview.setStraightenDegrees(value) }
                            }
                            Note { text: "拉直在松开滑块后应用。边缘自动收紧以避免空白。" }
                            ActionButton { objectName: "resetGeometryButton"; Layout.fillWidth: true; text: "重置裁切与方向"; enabled: window.canEditCrop && !window.cropMode; onClicked: { preview.resetGeometry(); canvas.resetView(true) } }
                        }
                        Section {
                            title: "放大机 · 相纸亮度"
                            RowLayout {
                                Layout.fillWidth: true
                                Text { text: "亮度"; color: Theme.text; font.pixelSize: 11 }
                                Item { Layout.fillWidth: true }
                                Text { text: preview.filmIsPositive ? "不适用" : (preview.exposureEv >= 0 ? "+" : "") + preview.exposureEv.toFixed(1) + " EV"; color: Theme.muted; font.pixelSize: 10 }
                            }
                            Slider {
                                objectName: "exposureSlider"; Layout.fillWidth: true; from: -2; to: 2; stepSize: 0.1; implicitHeight: 24
                                value: preview.exposureEv; enabled: preview.settingsEditable && !preview.filmIsPositive
                                onPressedChanged: { if (pressed) preview.beginEditGesture("exposureEv"); else preview.endEditGesture() }
                                onMoved: preview.exposureEv = value
                            }
                            Adjustment { label: "黄色滤镜"; setting: "yFilterShift"; from: -1; to: 1; step: 0.01; decimals: 2; available: !preview.filmIsPositive }
                            Adjustment { label: "洋红滤镜"; setting: "mFilterShift"; from: -1; to: 1; step: 0.01; decimals: 2; available: !preview.filmIsPositive }
                        }
                    }
                }
            }
        }
        Rectangle {
            Layout.fillWidth: true; Layout.fillHeight: true; color: Theme.ground
            ColumnLayout {
                anchors.fill: parent; spacing: 0
                Rectangle {
                    Layout.fillWidth: true; implicitHeight: Theme.topHeight; color: Theme.card
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 6
                        ActionButton { text: "导入 RAW"; enabled: window.canBrowse; onClicked: openDialog.open(); implicitHeight: 27 }
                        ActionButton { text: "导出"; enabled: preview.hasFrame && !preview.busy && !window.cropMode; onClicked: window.openExport(); implicitHeight: 27 }
                        ActionButton { text: "裁切"; accented: window.cropMode; enabled: window.canEditCrop; onClicked: window.cropMode ? window.finishCrop() : window.startCrop(); implicitHeight: 27 }
                        ActionButton { objectName: "undoButton"; text: "撤销"; enabled: preview.settingsEditable && preview.canUndo && !window.cropMode; onClicked: preview.undo(); implicitHeight: 27; ToolTip.visible: hovered; ToolTip.text: "撤销当前照片的上一步调整 · Ctrl+Z" }
                        ActionButton { objectName: "redoButton"; text: "重做"; enabled: preview.settingsEditable && preview.canRedo && !window.cropMode; onClicked: preview.redo(); implicitHeight: 27; ToolTip.visible: hovered; ToolTip.text: "重做当前照片的调整 · Ctrl+Shift+Z / Ctrl+Y" }
                        Item { Layout.fillWidth: true }
                        Text { text: preview.hasFrame ? canvas.scalePercent.toFixed(1) + "%" : ""; color: Theme.muted; font.pixelSize: 10; horizontalAlignment: Text.AlignRight }
                        ActionButton { text: "适合"; accented: canvas.fit; enabled: preview.hasFrame; onClicked: canvas.resetView(true); implicitHeight: 27 }
                        ActionButton { text: "100%"; accented: !canvas.fit; enabled: preview.hasFrame && !window.cropMode; onClicked: canvas.resetView(false); implicitHeight: 27 }
                    }
                }
                Item {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    FrameCanvas { id: canvas; objectName: "frameCanvas"; anchors.fill: parent; anchors.margins: 18; image: window.cropMode ? preview.uncroppedImage : preview.previewImage; enabled: !window.cropMode }
                    Item {
                        id: cropOverlay
                        objectName: "cropOverlay"
                        anchors.fill: canvas
                        visible: window.cropMode
                        readonly property rect imageBox: canvas.imageRect
                        readonly property rect selectionBox: Qt.rect(imageBox.x + window.draftCrop.x * imageBox.width, imageBox.y + window.draftCrop.y * imageBox.height, window.draftCrop.width * imageBox.width, window.draftCrop.height * imageBox.height)
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
                            anchors.fill: parent; enabled: window.canEditCrop; cursorShape: Qt.CrossCursor
                            property point origin
                            property bool drawing: false
                            function normalized(x, y) {
                                return Qt.point(Math.max(0, Math.min(1, (x - cropOverlay.imageBox.x) / cropOverlay.imageBox.width)), Math.max(0, Math.min(1, (y - cropOverlay.imageBox.y) / cropOverlay.imageBox.height)))
                            }
                            function updateCrop(x, y) {
                                var p = normalized(x, y)
                                window.draftCrop = Qt.rect(Math.min(origin.x, p.x), Math.min(origin.y, p.y), Math.abs(p.x - origin.x), Math.abs(p.y - origin.y))
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
                                if (window.draftCrop.width > 0.003 && window.draftCrop.height > 0.003) window.finishCrop()
                                else window.draftCrop = preview.cropRect
                            }
                            onCanceled: { drawing = false; window.draftCrop = preview.cropRect }
                        }
                    }
                    Column {
                        anchors.centerIn: parent; spacing: 16; visible: !preview.hasFrame
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "SpektraLab"; color: "#e5e2dc"; font.pixelSize: 32; font.letterSpacing: 1 }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "导入 RAW，逐张选择胶片与相纸"; color: "#d0cdc6"; font.pixelSize: 13 }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "支持一次拖入多张照片"; color: "#c0bdb7"; font.pixelSize: 11 }
                    }
                    DropArea { anchors.fill: parent; enabled: window.canBrowse; onDropped: function(drop) { if (drop.hasUrls) preview.openFiles(drop.urls) } }
                    Rectangle {
                        anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 26
                        width: window.cropMode ? 78 : 48; height: 20; radius: 2; color: "#b32d2d2c"; visible: preview.hasFrame
                        Text { anchors.centerIn: parent; text: window.cropMode ? "裁切原图" : "FULL"; color: Theme.text; font.pixelSize: 9; font.letterSpacing: 1 }
                    }
                    BusyIndicator { anchors.centerIn: parent; running: preview.busy; visible: running; width: 44; height: 44 }
                }
                Rectangle {
                    Layout.fillWidth: true; implicitHeight: 28; color: Theme.card
                    Text { anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; verticalAlignment: Text.AlignVCenter; text: preview.hasFrame ? preview.metadata.width + " × " + preview.metadata.height + "   ·   SDR sRGB / 8 位预览   ·   " + (preview.dirty ? "更新预览中…" : "选择与调整自动应用") : "完整分辨率预览"; color: preview.dirty ? Theme.accent : Theme.muted; font.pixelSize: 10; elide: Text.ElideRight }
                }
                Rectangle {
                    Layout.fillWidth: true; implicitHeight: Theme.stripHeight; color: Theme.card
                    Rectangle { width: parent.width; height: 1; color: Theme.line; opacity: 0.5 }
                    ColumnLayout {
                        anchors.fill: parent; anchors.margins: 8; spacing: 6
                        RowLayout {
                            Layout.fillWidth: true; spacing: 6
                            TextField {
                                id: librarySearch
                                objectName: "librarySearch"
                                Layout.preferredWidth: 210; implicitHeight: 23; font.pixelSize: 10
                                placeholderText: "按文件名筛选照片"
                                selectByMouse: true
                                onTextChanged: searchDelay.restart()
                                Timer { id: searchDelay; interval: 120; onTriggered: preview.setLibrarySearch(librarySearch.text) }
                            }
                            ComboBox {
                                objectName: "librarySort"
                                implicitWidth: 108; implicitHeight: 23; font.pixelSize: 10
                                model: ["目录顺序", "名称 A–Z", "名称 Z–A", "星级优先", "色标优先"]
                                currentIndex: 0
                                onActivated: preview.setLibrarySort(index === 0 ? 0 : index === 1 ? 0 : index === 2 ? 1 : index === 3 ? 2 : 3)
                            }
                            ActionButton { objectName: "newCatalogButton"; text: "新建目录"; implicitHeight: 23; font.pixelSize: 10; enabled: window.canBrowse; onClicked: createCatalogDialog.open() }
                            ActionButton { objectName: "openCatalogButton"; text: "打开目录"; implicitHeight: 23; font.pixelSize: 10; enabled: window.canBrowse; onClicked: openCatalogDialog.open() }
                            ActionButton { objectName: "linkFolderButton"; text: "链接文件夹"; implicitHeight: 23; font.pixelSize: 10; enabled: window.canBrowse; onClicked: linkedFolderDialog.open() }
                            Item { Layout.fillWidth: true }
                            ActionButton {
                                objectName: "trashOrRestoreButton"
                                readonly property var activeItem: preview.libraryItems.find(function(item) { return item.catalogIndex === preview.activeIndex })
                                text: preview.collectionFilter === "__trash__" ? "恢复照片" : "移到回收站"
                                implicitHeight: 23; font.pixelSize: 10
                                enabled: window.canBrowse && !!activeItem
                                onClicked: preview.collectionFilter === "__trash__"
                                    ? preview.restoreFromTrash(preview.activeIndex)
                                    : preview.moveToTrash(preview.activeIndex)
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true; spacing: 6
                            ComboBox {
                                objectName: "librarySourceSelector"
                                implicitWidth: 138; implicitHeight: 23; font.pixelSize: 10
                                model: preview.librarySources; textRole: "name"
                                currentIndex: preview.activeLibrarySource
                                onActivated: preview.switchLibrarySource(index)
                            }
                            Text { text: preview.libraryItems.length + " 张照片 · 已选 " + preview.selectedCount; color: Theme.muted; font.pixelSize: 10 }
                            ComboBox {
                                objectName: "collectionSelector"
                                implicitWidth: 130; implicitHeight: 23; font.pixelSize: 10
                                model: [{ name: "", label: "全部照片" }].concat(
                                    preview.collections.map(function(item) { return { name: item.name, label: item.name + " (" + item.count + ")" } }),
                                    [{ name: "__trash__", label: "回收站 (" + preview.trashCount + ")" }])
                                textRole: "label"
                                currentIndex: {
                                    for (var i = 0; i < model.length; ++i) if (model[i].name === preview.collectionFilter) return i
                                    return 0
                                }
                                onActivated: preview.setCollectionFilter(model[currentIndex].name)
                            }
                            ActionButton { text: "新建收藏"; implicitHeight: 23; font.pixelSize: 10; enabled: window.canBrowse && preview.libraryItems.length > 0; onClicked: collectionDialog.open() }
                            ActionButton { text: "删除收藏"; implicitHeight: 23; font.pixelSize: 10; enabled: preview.collectionFilter.length > 0 && preview.collectionFilter !== "__trash__"; onClicked: preview.deleteCollection(preview.collectionFilter) }
                            ActionButton { objectName: "composePairButton"; text: "组成半格双联"; implicitHeight: 23; font.pixelSize: 10; enabled: window.canBrowse && preview.selectedCount === 2; onClicked: preview.createPairFromSelection(); ToolTip.visible: hovered; ToolTip.text: "按选择顺序把两张照片装入 135 半格双联" }
                            ActionButton { objectName: "newVariantButton"; text: "新变体"; implicitHeight: 23; font.pixelSize: 10; readonly property var activeItem: preview.libraryItems.find(function(item) { return item.catalogIndex === preview.activeIndex }); enabled: window.canBrowse && !!activeItem && !activeItem.isPair && preview.collectionFilter !== "__trash__"; onClicked: preview.createVariant(preview.activeIndex, false); ToolTip.visible: hovered; ToolTip.text: "以默认设置建立同一文件的新编辑变体" }
                            ActionButton { objectName: "cloneVariantButton"; text: "克隆变体"; implicitHeight: 23; font.pixelSize: 10; readonly property var activeItem: preview.libraryItems.find(function(item) { return item.catalogIndex === preview.activeIndex }); enabled: window.canBrowse && !!activeItem && !activeItem.isPair && preview.collectionFilter !== "__trash__"; onClicked: preview.createVariant(preview.activeIndex, true); ToolTip.visible: hovered; ToolTip.text: "复制当前变体的编辑与评分" }
                            ActionButton { objectName: "deleteVariantButton"; text: "删除变体"; implicitHeight: 23; font.pixelSize: 10; readonly property var activeItem: preview.libraryItems.find(function(item) { return item.catalogIndex === preview.activeIndex }); enabled: window.canBrowse && !!activeItem && !activeItem.isPair && activeItem.variantCount > 1 && preview.collectionFilter !== "__trash__"; onClicked: deleteVariantDialog.open() }
                            Item { Layout.fillWidth: true }
                            ActionButton { text: "全选"; implicitHeight: 23; font.pixelSize: 10; enabled: window.canBrowse && preview.libraryItems.length > 0; onClicked: preview.selectAllPhotos(true) }
                            ActionButton { text: "清除选择"; implicitHeight: 23; font.pixelSize: 10; enabled: window.canBrowse && preview.selectedCount > 0; onClicked: preview.selectAllPhotos(false) }
                            ActionButton { text: "同步设置"; implicitHeight: 23; font.pixelSize: 10; enabled: window.canBrowse && preview.hasFrame && preview.selectedCount > 0; onClicked: preview.syncSelectedSettings(false); ToolTip.visible: hovered; ToolTip.text: "将当前照片的胶片、相纸、解码和效果同步到所选照片，不同步裁切。" }
                        }
                        ListView {
                            id: filmstrip; objectName: "photoStrip"
                            Layout.fillWidth: true; Layout.fillHeight: true
                            orientation: ListView.Horizontal; spacing: 8; clip: true
                            model: preview.libraryItems
                            currentIndex: {
                                var items = preview.libraryItems
                                for (var i = 0; i < items.length; ++i) if (items[i].catalogIndex === preview.activeIndex) return i
                                return -1
                            }
                            onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
                            ScrollBar.horizontal: ScrollBar {}
                            delegate: Rectangle {
                                required property var modelData
                                required property int index
                                width: 132; height: filmstrip.height - 3
                                color: Theme.wellDark; border.color: modelData.active ? Theme.accent : Theme.line; border.width: modelData.active ? 2 : 0
                                Rectangle { anchors.top: parent.top; anchors.left: parent.left; width: 9; height: 9; color: modelData.colorLabel === 0 ? "transparent" : ["", "#e2534d", "#e99b36", "#e5cf4a", "#55ad6a", "#4b9ed8", "#d56cab", "#806ad4"][modelData.colorLabel] }
                                Text { anchors.centerIn: parent; anchors.verticalCenterOffset: -8; text: modelData.error ? "无法读取" : "点击预览"; color: modelData.error ? "#ffb39f" : Theme.muted; font.pixelSize: 10 }
                                FrameCanvas { anchors.fill: parent; anchors.margins: 5; anchors.bottomMargin: 22; image: modelData.thumbnail; enabled: false }
                                Text { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 6; text: modelData.name; color: Theme.text; font.pixelSize: 10; elide: Text.ElideMiddle }
                                Text { visible: modelData.isPair; anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 6; text: "双联"; color: Theme.accent; font.pixelSize: 9 }
                                Text { visible: modelData.variantCount > 1; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 5; text: modelData.variantNumber + " / " + modelData.variantCount; color: Theme.accent; font.pixelSize: 9 }
                                MouseArea {
                                    anchors.fill: parent; enabled: window.canBrowse; hoverEnabled: true
                                    onClicked: { window.cropMode = false; preview.selectImage(modelData.catalogIndex) }
                                    ToolTip.visible: containsMouse && modelData.error.length > 0; ToolTip.text: modelData.error
                                }
                                Text {
                                    anchors.left: parent.left; anchors.leftMargin: 19; anchors.top: parent.top; anchors.topMargin: 5
                                    text: modelData.rating > 0 ? "★".repeat(modelData.rating) : "☆"
                                    color: modelData.rating > 0 ? "#e8bd58" : Theme.muted; font.pixelSize: 10
                                    MouseArea {
                                        anchors.fill: parent; anchors.margins: -4; enabled: window.canBrowse
                                        onClicked: preview.setRating(modelData.catalogIndex, (modelData.rating + 1) % 6)
                                        ToolTip.visible: containsMouse; ToolTip.text: "单击设置星级（0–5）"
                                    }
                                }
                                MouseArea {
                                    anchors.left: parent.left; anchors.top: parent.top; anchors.margins: 4
                                    width: 9; height: 9; enabled: window.canBrowse
                                    onClicked: preview.setColorLabel(modelData.catalogIndex, (modelData.colorLabel + 1) % 8)
                                    ToolTip.visible: containsMouse; ToolTip.text: "色标"
                                }
                                CheckBox { anchors.top: parent.top; anchors.right: parent.right; padding: 0; scale: 0.8; checked: modelData.selected; enabled: window.canBrowse; onToggled: preview.setItemSelected(modelData.catalogIndex, checked) }
                            }
                        }
                    }
                }
            }
        }
        Rectangle {
            Layout.preferredWidth: Theme.rightWidth; Layout.fillHeight: true; color: Theme.card
            ColumnLayout {
                anchors.fill: parent; spacing: 0
                Text { text: "参数 · 显影前"; color: Theme.text; font.pixelSize: 14; font.bold: true; Layout.leftMargin: 14; Layout.preferredHeight: Theme.topHeight; verticalAlignment: Text.AlignVCenter }
                ScrollView {
                    Layout.fillWidth: true; Layout.fillHeight: true; clip: true; contentWidth: availableWidth
                    ColumnLayout {
                        width: parent.width; spacing: 0
                        Section {
                            title: "输入 / 相机"
                            Adjustment { label: "胶片曝光"; setting: "filmExposureEv"; from: -4; to: 4; step: 0.1; decimals: 1; suffix: " EV" }
                            Note { text: "在胶片曝光前调整场景亮度。每张照片的效果与裁切自动保存，下次导入时恢复。" }
                        }
                        Section {
                            title: "胶片画幅与效果"
                            RowLayout {
                                Text { text: "画幅长边"; color: Theme.text; font.pixelSize: 11 }
                                ComboBox {
                                    Layout.fillWidth: true
                                    model: ["18 mm", "24 mm", "35 mm（默认）", "36 mm（135）", "56 mm", "70 mm", "90 mm"]
                                    readonly property var lengths: [18, 24, 35, 36, 56, 70, 90]
                                    readonly property real actualLength: Number(preview.adjustments.filmFormatMm === undefined ? 35 : preview.adjustments.filmFormatMm)
                                    currentIndex: lengths.indexOf(actualLength)
                                    displayText: currentIndex < 0 ? actualLength.toFixed(1) + " mm（自定）" : currentText
                                    enabled: preview.settingsEditable
                                    onActivated: preview.setAdjustment("filmFormatMm", lengths[currentIndex])
                                }
                            }
                            Note { text: "物理画幅决定颗粒与光晕尺度；裁切不改变画幅。" }
                            Effect { label: "颗粒"; activeKey: "grainActive"; amountKey: "grainAmount" }
                            Effect { label: "光晕"; activeKey: "halationActive"; amountKey: "halationAmount"; maximum: 4 }
                            Effect { label: "眩光"; activeKey: "glareActive"; amountKey: "glareAmount"; maximum: 30 }
                        }
                        Section {
                            title: "胶片工作的完整控制"
                            ComboBox {
                                objectName: "advancedPageSelector"
                                Layout.fillWidth: true
                                model: ["显影与胶片", "镜头、滤镜与像差", "片边、日期与漏光", "局部场景蒙版"]
                                currentIndex: window.advancedPage === "chemistry" ? 0 : window.advancedPage === "lens" ? 1 : window.advancedPage === "edges" ? 2 : 3
                                enabled: preview.settingsEditable
                                onActivated: window.advancedPage = ["chemistry", "lens", "edges", "sceneLayer"][currentIndex]
                            }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 6
                                visible: window.advancedPage === "chemistry"
                                Toggle { label: "Cineon 数字中间片"; setting: "digital_intermediate" }
                                Note { text: "按 Cineon Log 曝光处理，并用随附的 ProPhoto 显示表预览与导出。" }
                                Choice {
                                    label: "相机滤镜"; setting: "camera_filter"
                                    labels: ["无", "W8 黄", "W11 黄绿", "W12 深黄", "W15 深黄", "W21 橙", "W25 红", "W47 蓝", "W58 绿"]
                                    values: ["", "w8", "w11", "w12", "w15", "w21", "w25", "w47", "w58"]
                                }
                                Toggle { label: "颗粒分子层"; setting: "grain_sublayers_active" }
                                Toggle { label: "DIR 成色剂"; setting: "dir_couplers_active" }
                                Adjustment { label: "DIR 强度"; setting: "dir_couplers_amount"; fallback: 1; from: 0; to: 4 }
                                Adjustment { label: "感光曲线 Gamma"; setting: "density_curve_gamma"; fallback: 1; from: 0.2; to: 4; step: 0.01 }
                                Adjustment { label: "光晕提亮"; setting: "halation_boost_ev"; from: 0; to: 8; step: 0.1; decimals: 1; suffix: " EV" }
                                Toggle { label: "去除防光晕层"; setting: "antihalation_removed" }
                                Toggle { label: "场景宽容度映射"; setting: "scene_latitude_active" }
                                Choice {
                                    label: "映射基准"; setting: "scene_latitude_norm"
                                    labels: ["Power", "Y", "Max"]; values: ["power", "y", "max"]
                                }
                                Adjustment { label: "高光膝点"; setting: "scene_latitude_highlight_knee"; fallback: 2; from: -24; to: 24; step: 0.1; decimals: 1; suffix: " EV"; available: preview.adjustments.scene_latitude_active === true }
                                Adjustment { label: "高光余量"; setting: "scene_latitude_highlight_room"; from: 0; to: 24; step: 0.1; decimals: 1; suffix: " EV"; available: preview.adjustments.scene_latitude_active === true }
                                Adjustment { label: "阴影膝点"; setting: "scene_latitude_shadow_knee"; fallback: -2; from: -24; to: 24; step: 0.1; decimals: 1; suffix: " EV"; available: preview.adjustments.scene_latitude_active === true }
                                Adjustment { label: "阴影余量"; setting: "scene_latitude_shadow_room"; from: 0; to: 24; step: 0.1; decimals: 1; suffix: " EV"; available: preview.adjustments.scene_latitude_active === true }
                                Adjustment { label: "滚降阶数"; setting: "scene_latitude_rolloff"; fallback: 2; from: 1; to: 4; step: 0.05; available: preview.adjustments.scene_latitude_active === true }
                                Adjustment { label: "最大提亮"; setting: "scene_latitude_max_lift"; fallback: 4; from: 0.25; to: 12; step: 0.05; suffix: " EV"; available: preview.adjustments.scene_latitude_active === true }
                                Toggle { label: "虚拟对比度蒙版"; setting: "contrast_mask_active" }
                                Adjustment { label: "提亮高光"; setting: "contrast_mask_highlights"; from: 0; to: 3; step: 0.01; suffix: " EV"; available: preview.adjustments.contrast_mask_active === true }
                                Adjustment { label: "压低阴影"; setting: "contrast_mask_shadows"; from: 0; to: 3; step: 0.01; suffix: " EV"; available: preview.adjustments.contrast_mask_active === true }
                                Adjustment { label: "保留核心"; setting: "contrast_mask_core"; fallback: 1; from: 0; to: 3; step: 0.01; suffix: " EV"; available: preview.adjustments.contrast_mask_active === true }
                                Adjustment { label: "蒙版半径"; setting: "contrast_mask_scale"; fallback: 0.03; from: 0.002; to: 0.12; step: 0.001; decimals: 3; available: preview.adjustments.contrast_mask_active === true }
                                Adjustment { label: "相纸预闪"; setting: "preflash_exposure"; from: 0; to: 0.2; step: 0.002; decimals: 3; available: !preview.filmIsPositive }
                                Choice {
                                    label: "放大机光源"; setting: "enlarger_illuminant"
                                    labels: ["TH-KG3"]; values: ["TH-KG3"]
                                }
                                Adjustment { label: "黄中性值"; setting: "y_filter_neutral"; fallback: 55; from: 0; to: 200; step: 0.1; decimals: 1 }
                                Adjustment { label: "洋红中性值"; setting: "m_filter_neutral"; fallback: 65; from: 0; to: 200; step: 0.1; decimals: 1 }
                                Adjustment { label: "青中性值"; setting: "c_filter_neutral"; from: 0; to: 200; step: 0.1; decimals: 1 }
                                Toggle { label: "扫描白场校正"; setting: "scanner_white_correction" }
                                Toggle { label: "扫描黑场校正"; setting: "scanner_black_correction" }
                                Adjustment { label: "扫描镜头模糊"; setting: "scanner_lens_blur"; from: 0; to: 20; step: 0.1; decimals: 1 }
                                Toggle { label: "反转片 HDR 扫描"; setting: "scan_hdr_stretch" }
                                Adjustment { label: "扫描余量"; setting: "scan_hdr_headroom"; from: 0; to: 16; step: 0.1; decimals: 1; suffix: "×"; available: preview.filmIsPositive && preview.adjustments.scan_hdr_stretch === true }
                                Adjustment { label: "扫描输出缩放"; setting: "scan_hdr_output_scale"; fallback: 1; from: 0.0625; to: 1; step: 0.0005; decimals: 3; available: preview.filmIsPositive && preview.adjustments.scan_hdr_stretch === true }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 6
                                visible: window.advancedPage === "lens"
                                Adjustment { label: "镜头模糊"; setting: "lens_blur_um"; from: 0; to: 200; step: 0.1; decimals: 1; suffix: " µm" }
                                Toggle { label: "柔光滤镜"; setting: "diffusion_filter_active" }
                                Choice {
                                    label: "滤镜类型"; setting: "diffusion_filter_family"
                                    labels: ["Black Pro-Mist", "Pro-Mist", "Glimmerglass", "CineBloom"]
                                    values: ["black_pro_mist", "pro_mist", "glimmerglass", "cinebloom"]
                                }
                                Adjustment { label: "滤镜强度"; setting: "diffusion_filter_strength"; fallback: 0.5; from: 0; to: 2; step: 0.01; available: preview.adjustments.diffusion_filter_active === true }
                                Adjustment { label: "扩散范围"; setting: "diffusion_filter_spatial_scale"; fallback: 1; from: 0.25; to: 4; step: 0.01; available: preview.adjustments.diffusion_filter_active === true }
                                Adjustment { label: "光晕暖度"; setting: "diffusion_filter_halo_warmth"; from: -1.5; to: 1.5; step: 0.01; available: preview.adjustments.diffusion_filter_active === true }
                                Adjustment { label: "核心强度"; setting: "diffusion_filter_core_intensity"; fallback: 1; from: 0; to: 4; step: 0.01; available: preview.adjustments.diffusion_filter_active === true }
                                Adjustment { label: "核心尺寸"; setting: "diffusion_filter_core_size"; fallback: 1; from: 0.25; to: 4; step: 0.01; available: preview.adjustments.diffusion_filter_active === true }
                                Adjustment { label: "光晕强度"; setting: "diffusion_filter_halo_intensity"; fallback: 1; from: 0; to: 4; step: 0.01; available: preview.adjustments.diffusion_filter_active === true }
                                Adjustment { label: "光晕尺寸"; setting: "diffusion_filter_halo_size"; fallback: 1; from: 0.25; to: 4; step: 0.01; available: preview.adjustments.diffusion_filter_active === true }
                                Adjustment { label: "Bloom 强度"; setting: "diffusion_filter_bloom_intensity"; fallback: 1; from: 0; to: 4; step: 0.01; available: preview.adjustments.diffusion_filter_active === true }
                                Adjustment { label: "Bloom 尺寸"; setting: "diffusion_filter_bloom_size"; fallback: 1; from: 0.25; to: 4; step: 0.01; available: preview.adjustments.diffusion_filter_active === true }
                                Toggle { label: "镜头像差"; setting: "lens_aberrations_active" }
                                Adjustment { label: "场曲"; setting: "lens_field_curvature_um"; from: 0; to: 120; step: 0.1; decimals: 1; suffix: " µm"; available: preview.adjustments.lens_aberrations_active === true }
                                Adjustment { label: "像散"; setting: "lens_astigmatism_um"; from: -120; to: 120; step: 0.1; decimals: 1; suffix: " µm"; available: preview.adjustments.lens_aberrations_active === true }
                                Adjustment { label: "场衰减指数"; setting: "lens_field_exponent"; fallback: 2; from: 1; to: 4; step: 0.05; available: preview.adjustments.lens_aberrations_active === true }
                                Adjustment { label: "中心清晰半径"; setting: "lens_sharp_radius"; from: 0; to: 0.8; step: 0.01; available: preview.adjustments.lens_aberrations_active === true }
                                Adjustment { label: "彗差"; setting: "lens_coma_um"; from: -150; to: 150; step: 0.1; decimals: 1; suffix: " µm"; available: preview.adjustments.lens_aberrations_active === true }
                                Adjustment { label: "球差占比"; setting: "lens_spherical_amount"; from: 0; to: 0.6; step: 0.01; available: preview.adjustments.lens_aberrations_active === true }
                                Adjustment { label: "球差半径"; setting: "lens_spherical_um"; fallback: 60; from: 10; to: 400; step: 0.1; decimals: 1; suffix: " µm"; available: preview.adjustments.lens_aberrations_active === true }
                                Adjustment { label: "横向色差 R"; setting: "lens_lateral_ca_r"; from: -3; to: 3; step: 0.01; available: preview.adjustments.lens_aberrations_active === true }
                                Adjustment { label: "横向色差 B"; setting: "lens_lateral_ca_b"; from: -3; to: 3; step: 0.01; available: preview.adjustments.lens_aberrations_active === true }
                                Adjustment { label: "纵向色差"; setting: "lens_loca_um"; from: 0; to: 30; step: 0.01; suffix: " µm"; available: preview.adjustments.lens_aberrations_active === true }
                                Choice {
                                    label: "纵向色差颜色"; setting: "lens_loca_sign"
                                    labels: ["紫边", "绿边"]; values: ["purple", "green"]
                                }
                                Adjustment { label: "高光门限"; setting: "lens_loca_highlight_gate"; fallback: 1; from: 0; to: 1; step: 0.01; available: preview.adjustments.lens_aberrations_active === true }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 6
                                visible: window.advancedPage === "edges"
                                Toggle { label: "显示片边"; setting: "overscan_active" }
                                Choice {
                                    label: "片幅"; setting: "overscan_format"
                                    labels: ["135", "135 半格", "645", "6×6", "6×7", "6×8", "6×9"]
                                    values: ["135", "135_half", "120_645", "120_6x6", "120_6x7", "120_6x8", "120_6x9"]
                                }
                                Choice {
                                    label: "扫描范围"; setting: "overscan_mode"
                                    labels: ["整条片边", "窄片边"]; values: ["strip", "filed"]
                                }
                                Adjustment { label: "相机种子"; setting: "overscan_camera_seed"; fallback: 1; from: 1; to: 100000; step: 1; decimals: 0; available: preview.adjustments.overscan_active === true }
                                Adjustment { label: "画格种子"; setting: "overscan_frame_seed"; fallback: 1; from: 1; to: 100000; step: 1; decimals: 0; available: preview.adjustments.overscan_active === true }
                                Adjustment { label: "片边雾化"; setting: "overscan_fog"; fallback: 1; from: 0; to: 4; step: 0.01; available: preview.adjustments.overscan_active === true }
                                Adjustment { label: "片边漏光"; setting: "overscan_leaks"; from: 0; to: 4; step: 0.01; available: preview.adjustments.overscan_active === true }
                                SettingText { label: "片边文字"; setting: "overscan_edge_text"; placeholder: "KODAK PORTRA 400" }
                                Adjustment { label: "拍摄光圈"; setting: "overscan_f_number"; from: 0; to: 64; step: 0.1; decimals: 1; available: preview.adjustments.overscan_active === true }
                                Choice {
                                    label: "片门形状"; setting: "overscan_gate"
                                    labels: ["自动", "方角", "圆角", "Erneman", "Shouldered", "Kicked"]
                                    values: ["auto", "square", "rounded", "eared", "shouldered", "kicked"]
                                }
                                Choice {
                                    label: "片孔外"; setting: "overscan_holes"
                                    labels: ["白场", "黑场"]; values: ["white", "black"]
                                }
                                Adjustment { label: "画格号码"; setting: "overscan_frame_number"; from: 0; to: 99; step: 1; decimals: 0; available: preview.adjustments.overscan_active === true }
                                Choice {
                                    label: "片夹"; setting: "overscan_carrier"
                                    labels: ["无", "黑色", "敞开"]; values: ["none", "black", "open"]
                                }
                                Toggle { label: "半格双联"; setting: "overscan_pair" }
                                Choice {
                                    label: "120 片孔"; setting: "overscan_perforation"
                                    labels: ["无", "KS65"]; values: ["none", "ks65"]
                                }
                                Adjustment { label: "镜头暗角"; setting: "overscan_falloff"; from: 0; to: 1.5; step: 0.01; available: preview.adjustments.overscan_active === true }
                                Toggle { label: "日期后背"; setting: "date_imprint_active" }
                                SettingText { label: "日期文字"; setting: "date_imprint_text"; placeholder: "'26 11 15" }
                                SettingText { label: "第二格日期"; setting: "date_imprint_text_b"; placeholder: "半格双联时使用" }
                                SettingText { label: "拍摄数据"; setting: "date_imprint_data_text"; placeholder: "1/125  F5.6" }
                                Choice {
                                    label: "印制位置"; setting: "date_imprint_placement"
                                    labels: ["画面内", "片边"]; values: ["frame", "rebate"]
                                }
                                Choice {
                                    label: "日期字体"; setting: "date_imprint_style"
                                    labels: ["LCD", "点阵", "数据字"]; values: ["lcd", "dots", "data"]
                                }
                                Adjustment { label: "日期曝光"; setting: "date_imprint_ev"; fallback: 5.5; from: -2; to: 8; step: 0.1; decimals: 1; suffix: " EV"; available: preview.adjustments.date_imprint_active === true }
                                Adjustment { label: "日期大小"; setting: "date_imprint_size"; fallback: 1; from: 0.4; to: 3; step: 0.01; available: preview.adjustments.date_imprint_active === true }
                                Choice {
                                    label: "画面角落"; setting: "date_imprint_corner"
                                    labels: ["右下", "左下", "右上", "左上"]; values: ["br", "bl", "tr", "tl"]
                                }
                                Adjustment { label: "水平内缩"; setting: "date_imprint_inset_x"; fallback: 3; from: 0; to: 30; step: 0.1; decimals: 1; suffix: " mm"; available: preview.adjustments.date_imprint_active === true }
                                Adjustment { label: "垂直内缩"; setting: "date_imprint_inset_y"; fallback: 2.4; from: 0; to: 30; step: 0.1; decimals: 1; suffix: " mm"; available: preview.adjustments.date_imprint_active === true }
                                Choice {
                                    label: "数据位置"; setting: "date_imprint_data_placement"
                                    labels: ["画格间", "片孔间"]; values: ["gap", "perfs"]
                                }
                                SettingText { label: "片头数据"; setting: "date_imprint_data_leader"; placeholder: "MZ-S · 画格 1 使用" }
                                Choice {
                                    label: "漏光类型"; setting: "leak_kind"
                                    labels: ["关闭", "自动", "条带", "冲洗", "局部"]
                                    values: ["off", "auto", "band", "wash", "spot"]
                                }
                                Adjustment { label: "漏光量"; setting: "leak_amount"; fallback: 1; from: 0; to: 4; step: 0.01; available: preview.adjustments.leak_kind !== "off" }
                                Adjustment { label: "出现概率"; setting: "leak_rate"; fallback: 1; from: 0; to: 1; step: 0.01; available: preview.adjustments.leak_kind !== "off" }
                                Adjustment { label: "前光比例"; setting: "leak_front"; fallback: -1; from: -1; to: 1; step: 0.01; available: preview.adjustments.leak_kind !== "off" }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 6
                                visible: window.advancedPage === "sceneLayer"
                                Toggle { label: "启用局部场景蒙版"; setting: "scene_layer_active" }
                                Choice {
                                    label: "蒙版形状"; setting: "scene_layer_shape"
                                    labels: ["椭圆", "矩形"]; values: ["ellipse", "rectangle"]
                                }
                                Adjustment { label: "中心 X"; setting: "scene_layer_x"; fallback: 0.5; from: 0; to: 1; step: 0.005; decimals: 3; available: preview.adjustments.scene_layer_active === true }
                                Adjustment { label: "中心 Y"; setting: "scene_layer_y"; fallback: 0.5; from: 0; to: 1; step: 0.005; decimals: 3; available: preview.adjustments.scene_layer_active === true }
                                Adjustment { label: "半径 X"; setting: "scene_layer_radius_x"; fallback: 0.25; from: 0.01; to: 0.5; step: 0.005; decimals: 3; available: preview.adjustments.scene_layer_active === true }
                                Adjustment { label: "半径 Y"; setting: "scene_layer_radius_y"; fallback: 0.25; from: 0.01; to: 0.5; step: 0.005; decimals: 3; available: preview.adjustments.scene_layer_active === true }
                                Adjustment { label: "边缘羽化"; setting: "scene_layer_feather"; fallback: 0.3; from: 0; to: 0.95; step: 0.01; available: preview.adjustments.scene_layer_active === true }
                                Adjustment { label: "局部曝光"; setting: "scene_layer_exposure_ev"; fallback: 1; from: -4; to: 4; step: 0.1; decimals: 1; suffix: " EV"; available: preview.adjustments.scene_layer_active === true }
                                Adjustment { label: "覆盖强度"; setting: "scene_layer_coverage"; fallback: 1; from: 0; to: 1; step: 0.01; available: preview.adjustments.scene_layer_active === true }
                                Toggle { label: "反转蒙版"; setting: "scene_layer_invert" }
                                Note { text: "蒙版在胶片曝光阶段改变局部场景光量；坐标与尺寸按整幅画面归一化。" }
                            }
                            Note { text: "所有参数随照片自动保存。片边文字、日期和第二格设置需先在预览中得到有效渲染，才会写入编辑记录。" }
                        }
                        Section {
                            title: "RAW 解码"
                            RowLayout {
                                Layout.fillWidth: true
                                Text { text: "曲线通道"; color: Theme.muted; font.pixelSize: 11; Layout.fillWidth: true }
                                Repeater {
                                    model: ["RGB", "亮度", "R", "G", "B"]
                                    delegate: Button {
                                        required property int index
                                        required property string modelData
                                        text: modelData
                                        flat: true
                                        padding: 5
                                        font.pixelSize: 10
                                        checkable: true
                                        checked: curveEditor.channelIndex === index
                                        onClicked: curveEditor.channelIndex = index
                                        background: Rectangle {
                                            radius: 3
                                            color: parent.checked ? Theme.selection : (parent.hovered ? Theme.well : "transparent")
                                            border.color: Theme.line
                                            border.width: parent.checked ? 0 : 1
                                        }
                                        contentItem: Text {
                                            text: parent.text
                                            color: parent.checked ? Theme.selectionText : Theme.text
                                            font: parent.font
                                            horizontalAlignment: Text.AlignHCenter
                                        }
                                    }
                                }
                            }
                            SceneCurveEditor {
                                id: curveEditor
                                objectName: "sceneCurveEditor"
                                Layout.fillWidth: true
                                Layout.preferredHeight: 230
                                enabled: preview.settingsEditable
                                curveText: preview.adjustments.scene_curve === undefined ? "" : preview.adjustments.scene_curve
                                onEditStarted: preview.beginEditGesture("scene_curve")
                                onCurveEdited: function(value) {
                                    preview.setAdjustment("scene_curve", value)
                                    preview.endEditGesture()
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                Text { text: "单击添加点，拖动调整；右键删除。"; color: Theme.muted; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                ActionButton {
                                    text: "重置曲线"
                                    enabled: preview.settingsEditable
                                    onClicked: preview.setAdjustment("scene_curve", "")
                                }
                            }
                            ComboBox { id: decode; Layout.fillWidth: true; model: ["兼容模式（默认）", "高光扩展（实验）"]; currentIndex: preview.decodeMode; enabled: preview.settingsEditable; onActivated: preview.decodeMode = currentIndex }
                            Note { text: preview.decodeMode ? "保留去马赛克后的部分高光及负值；仍使用整数去马赛克。" : "与已验证的原生 RAW 流程保持一致。" }
                        }
                        Section {
                            title: "照片信息"
                            Note { text: preview.hasFrame ? preview.metadata.camera : "尚未打开照片"; color: Theme.text }
                            Note { text: preview.hasFrame ? preview.metadata.width + " × " + preview.metadata.height + " 像素\n" + (preview.metadata.mode === "headroom" ? "高光扩展解码" : "兼容解码") : "" }
                            Note { text: preview.hasFrame ? "本次渲染 " + (preview.metadata.renderMs / 1000).toFixed(2) + " 秒 · " + (preview.metadata.cached ? "复用负片" : "完整渲染") : "" }
                            ActionButton { Layout.fillWidth: true; text: "重置当前照片设置"; enabled: preview.settingsEditable; onClicked: preview.resetSettings() }
                        }
                        Section {
                            title: preview.batchExporting ? "批量导出" : preview.failed ? "无法完成操作" : "状态"
                            Note { text: window.closePending ? "等待当前操作完成后关闭…" : preview.status; color: preview.failed ? "#ffb39f" : Theme.muted }
                            Note { objectName: "savedStatusNote"; text: preview.savedStatus; visible: text.length > 0 }
                            Note { objectName: "persistenceWarningNote"; text: preview.persistenceWarning; visible: text.length > 0; color: "#ffb39f" }
                            ProgressBar { Layout.fillWidth: true; visible: preview.batchExporting; from: 0; to: Math.max(1, preview.batchTotal); value: preview.batchProgress }
                            ActionButton { Layout.fillWidth: true; text: "当前照片完成后停止"; visible: preview.batchExporting; onClicked: preview.cancelExport() }
                            ActionButton { Layout.fillWidth: true; text: "重新尝试预览"; visible: preview.failed && preview.hasFrame && !preview.batchExporting; enabled: !preview.busy; onClicked: preview.apply() }
                        }
                    }
                }
            }
        }
    }
    Popup {
        id: collectionDialog
        objectName: "collectionDialog"
        anchors.centerIn: parent
        width: 360; padding: 20
        modal: true; focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        onVisibleChanged: window.updateDialogState()
        background: Rectangle { color: Theme.card; border.color: Theme.line; radius: 7 }
        contentItem: ColumnLayout {
            spacing: 12
            Text { text: "新建收藏"; color: Theme.text; font.pixelSize: 18; font.bold: true }
            Note { text: "收藏会包含当前选中的照片；没有选中时使用当前照片。" }
            TextField {
                id: collectionName
                Layout.fillWidth: true
                placeholderText: "收藏名称"
                selectByMouse: true
                onAccepted: createButton.clicked()
            }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                ActionButton { text: "取消"; onClicked: collectionDialog.close() }
                ActionButton {
                    id: createButton
                    text: "创建"; accented: true
                    enabled: collectionName.text.trim().length > 0
                    onClicked: {
                        preview.createCollection(collectionName.text)
                        collectionName.clear()
                        collectionDialog.close()
                    }
                }
            }
        }
    }
    Popup {
        id: deleteVariantDialog
        objectName: "deleteVariantDialog"
        anchors.centerIn: parent
        width: 400; padding: 20
        modal: true; focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        onVisibleChanged: window.updateDialogState()
        background: Rectangle { color: Theme.card; border.color: Theme.line; radius: 7 }
        contentItem: ColumnLayout {
            spacing: 12
            Text { text: "删除变体"; color: Theme.text; font.pixelSize: 18; font.bold: true }
            Note { text: "只删除当前变体的编辑记录。原始照片和其他变体都会保留。" }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                ActionButton { text: "取消"; onClicked: deleteVariantDialog.close() }
                ActionButton {
                    objectName: "confirmDeleteVariantButton"
                    text: "删除变体"; accented: true
                    onClicked: {
                        preview.deleteVariant(preview.activeIndex)
                        deleteVariantDialog.close()
                    }
                }
            }
        }
    }
    Popup {
        id: exportPopup
        objectName: "exportPopup"
        anchors.centerIn: parent
        width: 520; padding: 22
        modal: true; focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        onVisibleChanged: window.updateDialogState()
        background: Rectangle { color: Theme.card; border.color: Theme.line; radius: 7 }
        contentItem: ColumnLayout {
            spacing: 14
            Text { text: "导出照片"; color: Theme.text; font.pixelSize: 20; font.bold: true }
            Note { text: "保存裁切、效果与所选 RGB 色彩空间；配方可重复使用。" }
            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.line; opacity: 0.5 }
            RowLayout {
                Text { text: "导出配方"; color: Theme.text; Layout.preferredWidth: 76 }
                ComboBox {
                    id: recipeBox; objectName: "exportRecipeSelector"
                    Layout.fillWidth: true
                    model: [{ "name": "自定义" }].concat(preview.exportRecipes)
                    textRole: "name"
                    onActivated: {
                        if (index === 0) return
                        var recipe = preview.exportRecipe(index - 1)
                        window.exportFormat = recipe.format
                        window.exportQuality = recipe.quality
                        window.exportLongEdge = recipe.maxLongEdge
                        window.exportOutputSpace = recipe.outputSpace
                        window.exportCopyMetadata = recipe.copyMetadata
                        recipeName.text = recipe.name
                    }
                }
                ActionButton { text: "删除"; enabled: recipeBox.currentIndex > 0; onClicked: { preview.deleteExportRecipe(recipeBox.currentIndex - 1); recipeBox.currentIndex = 0; recipeName.clear() } }
            }
            RowLayout {
                Text { text: "配方名称"; color: Theme.text; Layout.preferredWidth: 76 }
                TextField { id: recipeName; objectName: "exportRecipeName"; Layout.fillWidth: true; placeholderText: "例如：网页 JPEG" }
                ActionButton { objectName: "saveExportRecipeButton"; text: "保存"; enabled: recipeName.text.trim().length > 0; onClicked: { if (preview.saveExportRecipe(recipeName.text, window.exportFormat, window.exportQuality, window.exportLongEdge, window.exportOutputSpace, window.exportCopyMetadata)) recipeBox.currentIndex = 0 } }
            }
            RowLayout {
                Text { text: "格式"; color: Theme.text; Layout.preferredWidth: 76 }
                ComboBox { objectName: "exportFormatSelector"; Layout.fillWidth: true; model: ["TIFF · 16 位", "PNG · 8 位", "PNG · 16 位", "JPEG · 8 位", "HEIF · 8 位"]; currentIndex: window.exportFormat; onActivated: { window.exportFormat = currentIndex; if (currentIndex === 4) window.exportOutputSpace = 0 } }
            }
            RowLayout {
                visible: window.exportFormat === 3 || window.exportFormat === 4
                Text { text: "JPEG 质量"; color: Theme.text; Layout.preferredWidth: 76 }
                Slider { Layout.fillWidth: true; from: 1; to: 100; stepSize: 1; value: window.exportQuality; onMoved: window.exportQuality = value }
                Text { text: window.exportQuality; color: Theme.muted; Layout.preferredWidth: 28 }
            }
            RowLayout {
                Text { text: "输出尺寸"; color: Theme.text; Layout.preferredWidth: 76 }
                ComboBox {
                    Layout.fillWidth: true; model: ["原始裁切尺寸", "长边 3840 像素", "长边 2560 像素", "长边 1920 像素", "长边 1080 像素"]
                    readonly property var sizes: [0, 3840, 2560, 1920, 1080]
                    currentIndex: Math.max(0, sizes.indexOf(window.exportLongEdge))
                    onActivated: window.exportLongEdge = sizes[currentIndex]
                }
            }
            RowLayout {
                Text { text: "色彩空间"; color: Theme.text; Layout.preferredWidth: 76 }
                ComboBox { objectName: "exportOutputSpace"; Layout.fillWidth: true; enabled: window.exportFormat !== 4; model: ["sRGB", "Display P3", "Adobe RGB (1998)", "ProPhoto RGB"]; currentIndex: window.exportOutputSpace; onActivated: window.exportOutputSpace = currentIndex }
            }
            CheckBox { objectName: "exportCopyMetadata"; text: "复制相机与型号描述"; checked: window.exportCopyMetadata; onToggled: window.exportCopyMetadata = checked }
            Note { text: "保持长宽比例，不放大图像。PNG 无损保存，JPEG / HEIF 为有损压缩；Windows HEIF 需要系统图像扩展，固定为 sRGB。" }
            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.line; opacity: 0.5 }
            ActionButton { Layout.fillWidth: true; accented: true; text: "导出当前已显示画面…"; enabled: preview.hasFrame && !preview.busy; onClicked: { saveDialog.open(); exportPopup.close() } }
            ActionButton { Layout.fillWidth: true; text: "导出所选 " + preview.selectedCount + " 张到文件夹…"; enabled: preview.selectedCount > 0 && !preview.busy; onClicked: { batchDialog.open(); exportPopup.close() } }
            Note { text: "当前画面导出不覆盖已有文件。批量导出逐张处理，自动跳过同名文件；未访问的照片也按各自设置渲染。" }
            ActionButton { Layout.alignment: Qt.AlignRight; text: "取消"; onClicked: exportPopup.close() }
        }
    }
}
