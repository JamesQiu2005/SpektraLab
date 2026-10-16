import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Enlarger: print brightness and the yellow/magenta filtration. None of it
// applies to a slide film, which is scanned without a print.
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
