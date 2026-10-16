import QtQuick
import QtQuick.Layouts

// The status line under the canvas: the frame's size, what the canvas shows,
// and whether a preview update is pending.
Rectangle {
    Layout.fillWidth: true; implicitHeight: 28; color: Theme.card
    Text {
        anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; verticalAlignment: Text.AlignVCenter
        text: preview.hasFrame ? preview.metadata.width + " × " + preview.metadata.height + "   ·   SDR sRGB / 8 位预览   ·   " +(preview.dirty ? "更新预览中…" : "选择与调整自动应用") : "完整分辨率预览"
        color: preview.dirty ? Theme.accent : Theme.muted; font.pixelSize: 10; elide: Text.ElideRight
    }
}
