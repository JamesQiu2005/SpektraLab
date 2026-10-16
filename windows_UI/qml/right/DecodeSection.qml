import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// RAW Decode: the validated compatible decode, or the experimental one that
// keeps highlight headroom. A change re-opens the photo.
Section {
    title: "RAW 解码"
    ComboBox {
        id: decode; Layout.fillWidth: true
        model: ["兼容模式（默认）", "高光扩展（实验）"]
        currentIndex: preview.decodeMode
        enabled: preview.settingsEditable; onActivated: preview.decodeMode = currentIndex
    }
    Note { text: preview.decodeMode ? "保留去马赛克后的部分高光及负值；仍使用整数去马赛克。" : "与已验证的原生 RAW 流程保持一致。" }
}
