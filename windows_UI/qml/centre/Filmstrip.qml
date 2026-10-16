import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import SpektraLab.Native 1.0

// The filmstrip: the imported photos with their selection boxes, and the
// selection actions over them. Clicking a photo opens it (and leaves the crop
// editor); the boxes choose what Sync Settings and batch export act on.
Rectangle {
    id: strip
    required property EditorState editor
    Layout.fillWidth: true; implicitHeight: Theme.stripHeight; color: Theme.card
    Rectangle { width: parent.width; height: 1; color: Theme.line; opacity: 0.5 }
    ColumnLayout {
        anchors.fill: parent; anchors.margins: 8; spacing: 6
        RowLayout {
            Layout.fillWidth: true; spacing: 6
            Text { text: preview.libraryItems.length + " 张照片 · 已选 " + preview.selectedCount; color: Theme.muted; font.pixelSize: 10 }
            Item { Layout.fillWidth: true }
            ActionButton { text: "全选"; implicitHeight: 23; font.pixelSize: 10; enabled: strip.editor.canBrowse && preview.libraryItems.length > 0; onClicked: preview.selectAllPhotos(true) }
            ActionButton { text: "清除选择"; implicitHeight: 23; font.pixelSize: 10; enabled: strip.editor.canBrowse && preview.selectedCount > 0; onClicked: preview.selectAllPhotos(false) }
            ActionButton { text: "同步设置"; implicitHeight: 23; font.pixelSize: 10; enabled: strip.editor.canBrowse && preview.hasFrame && preview.selectedCount > 0; onClicked: preview.syncSelectedSettings(false); ToolTip.visible: hovered; ToolTip.text: "将当前照片的胶片、相纸、解码和效果同步到所选照片，不同步裁切。" }
        }
        ListView {
            id: filmstrip; objectName: "photoStrip"
            Layout.fillWidth: true; Layout.fillHeight: true
            orientation: ListView.Horizontal; spacing: 8; clip: true
            model: preview.libraryItems; currentIndex: preview.activeIndex
            onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
            ScrollBar.horizontal: ScrollBar {}
            delegate: Rectangle {
                id: thumb
                required property var modelData
                required property int index
                width: 132; height: filmstrip.height - 3
                color: Theme.wellDark; border.color: modelData.active ? Theme.accent : Theme.line; border.width: modelData.active ? 2 : 0
                Text { anchors.centerIn: parent; anchors.verticalCenterOffset: -8; text: thumb.modelData.error ? "无法读取" : "点击预览"; color: thumb.modelData.error ? "#ffb39f" : Theme.muted; font.pixelSize: 10 }
                FrameCanvas { anchors.fill: parent; anchors.margins: 5; anchors.bottomMargin: 22; image: thumb.modelData.thumbnail; enabled: false }
                Text { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 6; text: thumb.modelData.name; color: Theme.text; font.pixelSize: 10; elide: Text.ElideMiddle }
                MouseArea {
                    anchors.fill: parent; enabled: strip.editor.canBrowse; hoverEnabled: true
                    onClicked: { strip.editor.cropMode = false; preview.selectImage(thumb.index) }
                    ToolTip.visible: containsMouse && thumb.modelData.error.length > 0; ToolTip.text: thumb.modelData.error
                }
                CheckBox { anchors.top: parent.top; anchors.right: parent.right; padding: 0; scale: 0.8; checked: thumb.modelData.selected; enabled: strip.editor.canBrowse; onToggled: preview.setItemSelected(thumb.index, checked) }
            }
        }
    }
}
