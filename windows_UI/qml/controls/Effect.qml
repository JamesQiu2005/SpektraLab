import QtQuick
import QtQuick.Layouts

// The first Qt pane's film effect (an on/off switch over its strength),
// kept as an adapter onto CheckRow + ScrubSlider. New code uses those two
// directly, as FilmFormatSection does. An absent switch reads as on, as the
// controller's defaults do; the strength greys while the effect is off.
ColumnLayout {
    id: effect
    property string label
    property string activeKey
    property string amountKey
    property real maximum: 2
    readonly property bool on: preview.adjustments[activeKey] === undefined ? true : preview.adjustments[activeKey] === true
    Layout.fillWidth: true
    spacing: Theme.rowSpacing
    CheckRow {
        label: effect.label
        checked: effect.on
        available: preview.settingsEditable
        onToggledTo: function(v) { preview.setAdjustment(effect.activeKey, v) }
    }
    ScrubSlider {
        label: L10n.tr("effect.strength")
        value: preview.adjustments[effect.amountKey] === undefined ? 1 : Number(preview.adjustments[effect.amountKey])
        from: 0; to: effect.maximum; defaultValue: 1; step: 0.05
        gestureKey: effect.amountKey
        available: preview.settingsEditable && effect.on
        onMoved: function(v) { preview.setAdjustment(effect.amountKey, v) }
    }
}
