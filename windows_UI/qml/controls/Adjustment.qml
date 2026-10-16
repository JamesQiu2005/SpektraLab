import QtQuick

// The first Qt pane's slider over a numeric entry of `preview.adjustments`,
// kept as a thin adapter onto ScrubSlider so a pane written against it draws
// in the rail's style. New code uses ScrubSlider directly.
//
// `setting` is the adjustment name (camelCase or wire key); a drag is one
// undo step; `fallback` shows while the entry is absent.
ScrubSlider {
    id: adjustment
    property string setting
    property real fallback: 0
    readonly property real current: preview.adjustments[setting] === undefined ? fallback : Number(preview.adjustments[setting])
    to: 2
    step: 0.05
    value: current
    defaultValue: fallback
    gestureKey: setting
    available: preview.settingsEditable
    onMoved: function(v) { preview.setAdjustment(adjustment.setting, v) }
}
