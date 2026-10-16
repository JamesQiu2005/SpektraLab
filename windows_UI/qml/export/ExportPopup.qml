import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Export options: format, JPEG quality and output size (kept in EditorState so
// the save dialogs use them), then export the displayed frame or the selected
// photos. The file dialogs belong to Main.qml; this asks for them.
Popup {
    id: exportPopup
    required property EditorState editor
    signal exportCurrentRequested()
    signal exportBatchRequested()
    anchors.centerIn: parent
    width: 470; padding: 22
    modal: true; focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: Rectangle { color: Theme.card; border.color: Theme.line; radius: 7 }
    contentItem: ColumnLayout {
        spacing: 14
        Text { text: "导出照片"; color: Theme.text; font.pixelSize: 20; font.bold: true }
        Note { text: "当前画面或所选照片 · sRGB\n裁切与效果一起写入文件。" }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.line; opacity: 0.5 }
        RowLayout {
            Text { text: "格式"; color: Theme.text; Layout.preferredWidth: 76 }
            ComboBox {
                Layout.fillWidth: true; model: ["TIFF · 16 位", "PNG · 8 位", "PNG · 16 位", "JPEG · 8 位"]
                currentIndex: exportPopup.editor.exportFormat
                onActivated: exportPopup.editor.exportFormat = currentIndex
            }
        }
        RowLayout {
            visible: exportPopup.editor.exportFormat === 3
            Text { text: "JPEG 质量"; color: Theme.text; Layout.preferredWidth: 76 }
            Slider { Layout.fillWidth: true; from: 1; to: 100; stepSize: 1; value: exportPopup.editor.exportQuality; onMoved: exportPopup.editor.exportQuality = value }
            Text { text: exportPopup.editor.exportQuality; color: Theme.muted; Layout.preferredWidth: 28 }
        }
        RowLayout {
            Text { text: "输出尺寸"; color: Theme.text; Layout.preferredWidth: 76 }
            ComboBox {
                Layout.fillWidth: true; model: ["原始裁切尺寸", "长边 3840 像素", "长边 2560 像素", "长边 1920 像素", "长边 1080 像素"]
                readonly property var sizes: [0, 3840, 2560, 1920, 1080]
                currentIndex: Math.max(0, sizes.indexOf(exportPopup.editor.exportLongEdge))
                onActivated: exportPopup.editor.exportLongEdge = sizes[currentIndex]
            }
        }
        Note { text: "保持长宽比例，不放大图像。PNG 无损保存，JPEG 为有损压缩。" }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.line; opacity: 0.5 }
        ActionButton { Layout.fillWidth: true; accented: true; text: "导出当前已显示画面…"; enabled: preview.hasFrame && !preview.busy; onClicked: { exportPopup.exportCurrentRequested(); exportPopup.close() } }
        ActionButton { Layout.fillWidth: true; text: "导出所选 " + preview.selectedCount + " 张到文件夹…"; enabled: preview.selectedCount > 0 && !preview.busy; onClicked: { exportPopup.exportBatchRequested(); exportPopup.close() } }
        Note { text: "当前画面导出不覆盖已有文件。批量导出逐张处理，自动跳过同名文件；未访问的照片也按各自设置渲染。" }
        ActionButton { Layout.alignment: Qt.AlignRight; text: "取消"; onClicked: exportPopup.close() }
    }
}
