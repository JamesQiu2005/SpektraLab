import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// One named slider over a numeric entry of `preview.adjustments`: a label and
// its value on one line, the slider under it. A drag is one undo step
// (begin/endEditGesture); `fallback` is shown while the entry is absent.
ColumnLayout {
    id: adjustment
    property string label
    property string setting
    property real from: 0
    property real to: 2
    property real step: 0.05
    property int decimals: 2
    property string suffix: ""
    property real fallback: 0
    property bool available: true
    readonly property real current: preview.adjustments[setting] === undefined ? fallback : Number(preview.adjustments[setting])
    Layout.fillWidth: true; spacing: 2
    RowLayout {
        Layout.fillWidth: true
        Text { text: adjustment.label; color: adjustment.available ? Theme.text : Theme.muted; font.pixelSize: 11 }
        Item { Layout.fillWidth: true }
        Text { text: adjustment.current.toFixed(adjustment.decimals) + adjustment.suffix; color: Theme.muted; font.pixelSize: 10 }
    }
    Slider {
        Layout.fillWidth: true; implicitHeight: 24
        from: adjustment.from; to: adjustment.to; stepSize: adjustment.step
        value: adjustment.current
        enabled: preview.settingsEditable && adjustment.available
        onPressedChanged: {
            if (pressed) preview.beginEditGesture(adjustment.setting)
            else preview.endEditGesture()
        }
        onMoved: preview.setAdjustment(adjustment.setting, value)
    }
}
