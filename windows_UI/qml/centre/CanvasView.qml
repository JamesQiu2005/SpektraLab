import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import SpektraLab.Native 1.0

// The canvas and what is drawn over it: the crop editor, the empty-state
// title, the drop target for RAW files, the FULL badge and the busy spinner.
// The canvas keeps the objectName "frameCanvas" the --self-test looks up.
Item {
    id: view
    required property EditorState editor
    readonly property FrameCanvas canvas: frameCanvas
    Layout.fillWidth: true; Layout.fillHeight: true
    FrameCanvas { id: frameCanvas; objectName: "frameCanvas"; anchors.fill: parent; anchors.margins: 18; image: view.editor.cropMode ? preview.uncroppedImage : preview.previewImage; enabled: !view.editor.cropMode }
    CropOverlay { canvas: frameCanvas; editor: view.editor }
    Column {
        anchors.centerIn: parent; spacing: 16; visible: !preview.hasFrame
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "SpektraLab"; color: "#e5e2dc"; font.pixelSize: 32; font.letterSpacing: 1 }
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "导入 RAW，逐张选择胶片与相纸"; color: "#d0cdc6"; font.pixelSize: 13 }
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "支持一次拖入多张照片"; color: "#c0bdb7"; font.pixelSize: 11 }
    }
    DropArea { anchors.fill: parent; enabled: view.editor.canBrowse; onDropped: function(drop) { if (drop.hasUrls) preview.openFiles(drop.urls) } }
    Rectangle {
        anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 26
        width: view.editor.cropMode ? 78 : 48; height: 20; radius: 2; color: "#b32d2d2c"; visible: preview.hasFrame
        Text { anchors.centerIn: parent; text: view.editor.cropMode ? "裁切原图" : "FULL"; color: Theme.text; font.pixelSize: 9; font.letterSpacing: 1 }
    }
    BusyIndicator { anchors.centerIn: parent; running: preview.busy; visible: running; width: 44; height: 44 }
}
