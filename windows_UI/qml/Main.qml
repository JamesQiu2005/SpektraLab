import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import SpektraLab.Native 1.0

ApplicationWindow {
    id: window
    objectName: "editorWindow"
    width: 1440; height: 920
    minimumWidth: 1050; minimumHeight: 720
    visible: true
    color: Theme.card
    title: (preview.hasFrame ? preview.fileName + " — " : "") + "SpektraLab"
    font.family: "Segoe UI"
    font.pixelSize: 12
    palette.window: Theme.card
    palette.text: Theme.text
    palette.buttonText: Theme.text
    palette.base: Theme.well
    palette.button: Theme.well
    palette.highlight: Theme.accent
    property bool closePending: false
    onClosing: function(event) { if (preview.busy) { closePending = true; event.accepted = false } }
    Connections {
        target: preview
        function onStateChanged() { if (window.closePending && !preview.busy) window.close() }
        function onSourceOpened() { canvas.resetView(true) }
    }
    FileDialog {
        id: openDialog
        title: "打开 RAW"
        nameFilters: ["相机 RAW (*.arw *.nef *.nrw *.dng *.cr2 *.cr3 *.raf *.rw2 *.orf *.pef *.srw)", "所有文件 (*)"]
        onAccepted: preview.openRaw(selectedFile)
    }
    FileDialog {
        id: saveDialog
        title: "导出当前画面 · 不覆盖现有文件"
        fileMode: FileDialog.SaveFile
        nameFilters: ["16 位 TIFF (*.tif *.tiff)"]
        defaultSuffix: "tif"
        currentFolder: preview.sourceFolder
        onAccepted: preview.exportTiff(selectedFile)
    }
    Shortcut { sequences: [StandardKey.Open]; enabled: preview.ready && !preview.busy; onActivated: openDialog.open() }
    Shortcut { sequence: "Ctrl+E"; enabled: preview.hasFrame && !preview.busy; onActivated: saveDialog.open() }
    Shortcut { sequence: "Ctrl+0"; enabled: preview.hasFrame; onActivated: canvas.resetView(true) }
    Shortcut { sequence: "Ctrl+1"; enabled: preview.hasFrame; onActivated: canvas.resetView(false) }
    RowLayout {
        anchors.fill: parent; spacing: 1
        Rectangle {
            Layout.preferredWidth: Theme.leftWidth; Layout.fillHeight: true; color: Theme.card
            ColumnLayout {
                anchors.fill: parent; spacing: 0
                Text { text: "胶片与相纸"; color: Theme.text; font.pixelSize: 14; font.bold: true; Layout.leftMargin: 14; Layout.preferredHeight: Theme.topHeight; verticalAlignment: Text.AlignVCenter }
                ScrollView {
                    Layout.fillWidth: true; Layout.fillHeight: true; clip: true
                    contentWidth: availableWidth
                    ColumnLayout {
                        width: parent.width; spacing: 0
                        Section {
                            title: "胶片"
                            Text { text: preview.films.length ? preview.films[preview.filmIndex].name : "加载胶片目录…"; color: Theme.accent; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                            ListView {
                                id: films
                                objectName: "filmList"
                                Layout.fillWidth: true; Layout.preferredHeight: 282; clip: true
                                model: preview.films
                                currentIndex: preview.filmIndex
                                onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
                                onCountChanged: Qt.callLater(function() { films.positionViewAtIndex(preview.filmIndex, ListView.Contain) })
                                ScrollBar.vertical: ScrollBar {}
                                delegate: Rectangle {
                                    required property var modelData
                                    required property int index
                                    width: films.width; height: 29
                                    color: index === preview.filmIndex ? "#514b40" : filmMouse.containsMouse ? "#41413e" : "transparent"
                                    Rectangle { width: 2; anchors.top: parent.top; anchors.bottom: parent.bottom; color: Theme.accent; visible: index === preview.filmIndex }
                                    Text { anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 8; verticalAlignment: Text.AlignVCenter; text: modelData.name; color: preview.busy ? "#858580" : Theme.text; font.pixelSize: 11; elide: Text.ElideRight }
                                    MouseArea { id: filmMouse; anchors.fill: parent; hoverEnabled: true; enabled: preview.ready && !preview.busy; onClicked: preview.filmIndex = index }
                                }
                            }
                        }
                        Section {
                            title: "相纸"
                            ListView {
                                id: papers
                                objectName: "paperList"
                                Layout.fillWidth: true; Layout.preferredHeight: 198; clip: true
                                model: preview.papers; currentIndex: preview.paperIndex
                                onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
                                onCountChanged: Qt.callLater(function() { papers.positionViewAtIndex(preview.paperIndex, ListView.Contain) })
                                ScrollBar.vertical: ScrollBar {}
                                delegate: Rectangle {
                                    required property var modelData
                                    required property int index
                                    width: papers.width; height: 29
                                    color: index === preview.paperIndex ? "#514b40" : paperMouse.containsMouse ? "#41413e" : "transparent"
                                    Rectangle { width: 2; anchors.top: parent.top; anchors.bottom: parent.bottom; color: Theme.accent; visible: index === preview.paperIndex }
                                    Text { anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 8; verticalAlignment: Text.AlignVCenter; text: modelData.name; color: preview.busy ? "#858580" : Theme.text; font.pixelSize: 11; elide: Text.ElideRight }
                                    MouseArea { id: paperMouse; anchors.fill: parent; hoverEnabled: true; enabled: preview.ready && !preview.busy; onClicked: preview.paperIndex = index }
                                }
                            }
                        }
                    }
                }
                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.line; opacity: 0.5 }
                Text { text: "SpektraLab  ·  Windows\n原生胶片模拟引擎"; color: Theme.muted; font.pixelSize: 10; lineHeight: 1.5; Layout.margins: 14 }
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
                        ActionButton { text: "打开 RAW"; enabled: preview.ready && !preview.busy; onClicked: openDialog.open(); implicitHeight: 27 }
                        ActionButton { text: "导出"; enabled: preview.hasFrame && !preview.busy; onClicked: saveDialog.open(); implicitHeight: 27 }
                        Item { Layout.fillWidth: true }
                        Text { text: preview.hasFrame ? canvas.scalePercent.toFixed(1) + "%" : ""; color: Theme.muted; font.pixelSize: 11; Layout.minimumWidth: 44; horizontalAlignment: Text.AlignRight }
                        ActionButton { text: "适合"; accented: canvas.fit; enabled: preview.hasFrame; onClicked: canvas.resetView(true); implicitHeight: 27 }
                        ActionButton { text: "100%"; accented: !canvas.fit; enabled: preview.hasFrame; onClicked: canvas.resetView(false); implicitHeight: 27 }
                    }
                }
                Item {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    FrameCanvas { id: canvas; objectName: "frameCanvas"; anchors.fill: parent; anchors.margins: 18; image: preview.previewImage }
                    Column {
                        anchors.centerIn: parent; spacing: 16; visible: !preview.hasFrame
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "SpektraLab"; color: "#e5e2dc"; font.pixelSize: 32; font.letterSpacing: 1 }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "打开 RAW，选择胶片与相纸"; color: "#d0cdc6"; font.pixelSize: 13 }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "也可将照片拖到这里"; color: "#c0bdb7"; font.pixelSize: 11 }
                    }
                    DropArea { anchors.fill: parent; enabled: preview.ready && !preview.busy; onDropped: function(drop) { if (drop.hasUrls && drop.urls.length === 1) preview.openRaw(drop.urls[0]) } }
                    Rectangle {
                        anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 26
                        width: 48; height: 20; radius: 2; color: "#b32d2d2c"; visible: preview.hasFrame
                        Text { anchors.centerIn: parent; text: "FULL"; color: Theme.text; font.pixelSize: 9; font.letterSpacing: 1 }
                    }
                    BusyIndicator { anchors.centerIn: parent; running: preview.busy; visible: running; width: 44; height: 44 }
                }
                Rectangle {
                    Layout.fillWidth: true; implicitHeight: 28; color: Theme.card
                    Text { anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; verticalAlignment: Text.AlignVCenter; text: preview.hasFrame ? preview.metadata.width + " × " + preview.metadata.height + "   ·   SDR sRGB / 8 位预览   ·   双击切换适合 / 100%" : "完整分辨率预览"; color: Theme.muted; font.pixelSize: 10; elide: Text.ElideRight }
                }
                Rectangle {
                    Layout.fillWidth: true; implicitHeight: Theme.stripHeight; color: Theme.card
                    Rectangle { width: parent.width; height: 1; color: Theme.line; opacity: 0.5 }
                    Row {
                        anchors.left: parent.left; anchors.leftMargin: 14; anchors.verticalCenter: parent.verticalCenter; spacing: 14; visible: preview.hasFrame
                        Rectangle {
                            width: 130; height: 100; color: "#242422"; border.width: 1; border.color: Theme.accent
                            FrameCanvas { anchors.fill: parent; anchors.margins: 5; image: preview.previewImage; enabled: false }
                        }
                        Column {
                            anchors.verticalCenter: parent.verticalCenter; spacing: 8
                            Text { text: preview.fileName; color: Theme.text; font.pixelSize: 12; width: Math.max(80, window.width - Theme.leftWidth - Theme.rightWidth - 188); elide: Text.ElideRight }
                            Text { text: "当前照片"; color: Theme.muted; font.pixelSize: 10 }
                            Text { text: preview.dirty ? "设置尚未应用" : "画面与导出使用同一渲染结果"; color: preview.dirty ? Theme.accent : Theme.muted; font.pixelSize: 10 }
                        }
                    }
                }
            }
        }
        Rectangle {
            Layout.preferredWidth: Theme.rightWidth; Layout.fillHeight: true; color: Theme.card
            ColumnLayout {
                anchors.fill: parent; spacing: 0
                Text { text: "参数"; color: Theme.text; font.pixelSize: 14; font.bold: true; Layout.leftMargin: 14; Layout.preferredHeight: Theme.topHeight; verticalAlignment: Text.AlignVCenter }
                ScrollView {
                    Layout.fillWidth: true; Layout.fillHeight: true; clip: true; contentWidth: availableWidth
                    ColumnLayout {
                        width: parent.width; spacing: 0
                        Section {
                            title: "RAW 解码"
                            ComboBox {
                                id: decode; Layout.fillWidth: true; model: ["兼容模式（默认）", "高光扩展（实验）"]
                                currentIndex: preview.decodeMode; enabled: preview.ready && !preview.busy
                                onActivated: preview.decodeMode = currentIndex
                            }
                            Text { Layout.fillWidth: true; text: preview.decodeMode ? "保留去马赛克后的部分高光及负值；仍使用整数去马赛克。" : "与已验证的原生 RAW 流程保持一致。"; color: Theme.muted; font.pixelSize: 10; wrapMode: Text.WordWrap; lineHeight: 1.3 }
                        }
                        Section {
                            title: "相纸亮度"
                            RowLayout {
                                Layout.fillWidth: true
                                Text { text: "亮度"; color: Theme.text; font.pixelSize: 11 }
                                Item { Layout.fillWidth: true }
                                Text { text: (preview.exposureEv >= 0 ? "+" : "") + preview.exposureEv.toFixed(1) + " EV"; color: Theme.text; font.pixelSize: 11 }
                            }
                            Slider {
                                objectName: "exposureSlider"; Layout.fillWidth: true; from: -2; to: 2; stepSize: 0.1
                                value: preview.exposureEv; enabled: preview.ready && !preview.busy
                                onMoved: preview.exposureEv = value
                            }
                            Text { Layout.fillWidth: true; text: "调节相纸上的亮度，复用已生成的负片。"; color: Theme.muted; font.pixelSize: 10; wrapMode: Text.WordWrap }
                            ActionButton { Layout.fillWidth: true; text: "应用效果"; accented: true; enabled: preview.hasFrame && !preview.busy; onClicked: preview.apply() }
                            ActionButton { Layout.fillWidth: true; text: "重置选择与亮度"; enabled: preview.ready && !preview.busy; onClicked: preview.resetSettings() }
                        }
                        Section {
                            title: "照片信息"
                            Text { Layout.fillWidth: true; text: preview.hasFrame ? preview.metadata.camera : "尚未打开照片"; color: Theme.text; font.pixelSize: 11; wrapMode: Text.WordWrap }
                            Text { Layout.fillWidth: true; text: preview.hasFrame ? preview.metadata.width + " × " + preview.metadata.height + " 像素\n" + (preview.metadata.mode === "headroom" ? "高光扩展解码" : "兼容解码") : ""; color: Theme.muted; font.pixelSize: 10; lineHeight: 1.6; wrapMode: Text.WordWrap }
                            Text { Layout.fillWidth: true; text: preview.hasFrame ? "本次渲染  " + (preview.metadata.renderMs / 1000).toFixed(2) + " 秒\n" + (preview.metadata.cached ? "负片缓存已命中" : "完整胶片渲染") : ""; color: Theme.muted; font.pixelSize: 10; lineHeight: 1.6; wrapMode: Text.WordWrap }
                        }
                        Section {
                            title: "导出"
                            Text { Layout.fillWidth: true; text: "保存当前已显示的画面为 16 位 sRGB TIFF。现有文件不会被覆盖。"; color: Theme.muted; font.pixelSize: 10; wrapMode: Text.WordWrap; lineHeight: 1.4 }
                            ActionButton { Layout.fillWidth: true; text: "导出当前画面…"; enabled: preview.hasFrame && !preview.busy; onClicked: saveDialog.open() }
                        }
                        Section {
                            title: preview.failed ? "无法完成操作" : "状态"
                            Text { Layout.fillWidth: true; text: window.closePending ? "等待当前操作完成后关闭…" : preview.status; color: preview.failed ? "#ffb39f" : Theme.muted; font.pixelSize: 10; wrapMode: Text.Wrap; lineHeight: 1.4 }
                        }
                    }
                }
            }
        }
    }
}
