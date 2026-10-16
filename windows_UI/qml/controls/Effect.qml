import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A film effect: an on/off box over its strength slider. An absent switch reads
// as on, matching the controller's defaults; the slider greys out while off.
ColumnLayout {
    id: effect
    property string label
    property string activeKey
    property string amountKey
    property real maximum: 2
    Layout.fillWidth: true; spacing: 1
    CheckBox {
        text: effect.label; font.pixelSize: 11
        palette.windowText: Theme.text
        checked: preview.adjustments[effect.activeKey] === undefined ? true : preview.adjustments[effect.activeKey]
        enabled: preview.settingsEditable
        onToggled: preview.setAdjustment(effect.activeKey, checked)
    }
    Adjustment { label: "强度"; setting: effect.amountKey; fallback: 1; from: 0; to: effect.maximum; available: preview.adjustments[effect.activeKey] !== false }
}
