import QtQuick
import QtQuick.Layouts

// Photo Info: camera, size, decode and the last render's cost, and the reset
// for this photo's settings.
Section {
    title: "照片信息"
    Note { text: preview.hasFrame ? preview.metadata.camera : "尚未打开照片"; color: Theme.text }
    Note { text: preview.hasFrame ? preview.metadata.width + " × " + preview.metadata.height + " 像素\n" +(preview.metadata.mode === "headroom" ? "高光扩展解码" : "兼容解码") : "" }
    Note { text: preview.hasFrame ? "本次渲染 " + (preview.metadata.renderMs / 1000).toFixed(2) + " 秒 · " +(preview.metadata.cached ? "复用负片" : "完整渲染") : "" }
    ActionButton { Layout.fillWidth: true; text: "重置当前照片设置"; enabled: preview.settingsEditable; onClicked: preview.resetSettings() }
}
