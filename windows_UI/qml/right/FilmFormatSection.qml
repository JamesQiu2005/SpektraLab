import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Film Format and Effects: the physical frame size, which scales grain and
// halation, and the three film effects.
Section {
    title: L10n.tr("format.title")
    RowLayout {
        Text { text: L10n.tr("format.longEdge"); color: Theme.text; font.pixelSize: 11 }
        ComboBox {
            Layout.fillWidth: true
            model: ["18 mm", "24 mm", L10n.tr("format.default35"), L10n.tr("format.size36"), "56 mm", "70 mm", "90 mm"]
            readonly property var lengths: [18, 24, 35, 36, 56, 70, 90]
            readonly property real actualLength: Number(preview.adjustments.filmFormatMm === undefined ? 35 : preview.adjustments.filmFormatMm)
            // Reads `model` so a language switch (a new model, index reset to
            // 0) re-runs the binding.
            currentIndex: { model; return lengths.indexOf(actualLength) }
            displayText: currentIndex < 0 ? L10n.tr("format.custom", [actualLength.toFixed(1)]) : currentText
            enabled: preview.settingsEditable
            onActivated: preview.setAdjustment("filmFormatMm", lengths[currentIndex])
        }
    }
    Note { text: L10n.tr("format.note") }
    Effect { label: L10n.tr("effect.grain"); activeKey: "grainActive"; amountKey: "grainAmount" }
    Effect { label: L10n.tr("effect.halation"); activeKey: "halationActive"; amountKey: "halationAmount"; maximum: 4 }
    Effect { label: L10n.tr("effect.glare"); activeKey: "glareActive"; amountKey: "glareAmount"; maximum: 30 }
}
