import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Film Format and Effects: the physical frame size, which scales grain and
// halation, and the three film effects.
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
