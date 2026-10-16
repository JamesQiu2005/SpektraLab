import QtQuick
import QtQuick.Controls

// Film Format (ParameterSections.swift `FilmFormatSection`): the physical
// frame, which sets the scale of grain and halation (cropping does not change
// it), and the film effects, each switch followed by its strength -- the
// Mac's "decoupled" layout, which Windows always shows. A strength greys,
// rather than hides, while its effect is off: the value is still the photo's.
//
// The engine takes one number, the frame's long edge; the Mac derives it
// from a film type, a side and a side length and the photo's aspect, which
// needs per-photo fields the Windows settings table does not have yet. Until
// then Long Edge chooses the number directly -- the same wire value, so a
// later lane can put Size / Side / Side Length in front of it. The film's
// anti-halation layer is the Mac's row with nothing behind it yet.
MacSection {
    id: section
    sectionId: "filmFormat"
    title: L10n.tr("format.title")
    readonly property bool grainOn: preview.adjustments.grainActive === undefined ? true : preview.adjustments.grainActive === true
    readonly property bool halationOn: preview.adjustments.halationActive === undefined ? true : preview.adjustments.halationActive === true
    readonly property bool glareOn: preview.adjustments.glareActive === undefined ? true : preview.adjustments.glareActive === true
    function amount(key) { return preview.adjustments[key] === undefined ? 1 : Number(preview.adjustments[key]) }
    function setEffects(on) {
        preview.setAdjustment("grainActive", on)
        preview.setAdjustment("halationActive", on)
        preview.setAdjustment("glareActive", on)
    }
    function resetStrengths() {
        preview.setAdjustment("grainAmount", 1)
        preview.setAdjustment("halationAmount", 1)
        preview.setAdjustment("glareAmount", 1)
    }
    resetVisible: true
    resetAvailable: preview.settingsEditable
    resetToolTip: L10n.tr("format.reset")
    onResetRequested: { preview.setAdjustment("filmFormatMm", 35); setEffects(true); resetStrengths() }
    menuItems: [
        RailMenuItem { text: L10n.tr("format.allEffectsOn"); enabled: preview.settingsEditable; onTriggered: section.setEffects(true) },
        RailMenuItem { text: L10n.tr("format.allEffectsOff"); enabled: preview.settingsEditable; onTriggered: section.setEffects(false) },
        RailMenuItem { text: L10n.tr("format.resetStrengths"); enabled: preview.settingsEditable; onTriggered: section.resetStrengths() }
    ]

    ParamRow {
        label: L10n.tr("format.longEdge")
        available: preview.settingsEditable
        toolTip: L10n.tr("format.note")
        PillDropdown {
            id: longEdge
            model: ["18 mm", "24 mm", L10n.tr("format.default35"), L10n.tr("format.size36"), "56 mm", "70 mm", "90 mm"]
            readonly property var lengths: [18, 24, 35, 36, 56, 70, 90]
            readonly property real actualLength: Number(preview.adjustments.filmFormatMm === undefined ? 35 : preview.adjustments.filmFormatMm)
            // Reads `model` so a language switch (a new model, index reset to
            // 0) re-runs the binding.
            currentIndex: { model; return lengths.indexOf(actualLength) }
            displayText: currentIndex < 0 ? L10n.tr("format.custom", [actualLength.toFixed(1)]) : currentText
            onActivated: function(index) { preview.setAdjustment("filmFormatMm", lengths[index]) }
        }
    }
    CheckRow {
        label: L10n.tr("effect.grain")
        checked: section.grainOn
        available: preview.settingsEditable
        onToggledTo: function(on) { preview.setAdjustment("grainActive", on) }
    }
    ScrubSlider {
        label: L10n.tr("effect.grainStrength")
        from: 0; to: 2; defaultValue: 1; step: 0.05; snap: 0.25
        value: section.amount("grainAmount")
        gestureKey: "grainAmount"
        available: preview.settingsEditable && section.grainOn
        reason: section.grainOn ? "" : L10n.tr("effect.reasonOff")
        onMoved: function(v) { preview.setAdjustment("grainAmount", v) }
    }
    CheckRow {
        label: L10n.tr("effect.halation")
        checked: section.halationOn
        available: preview.settingsEditable
        onToggledTo: function(on) { preview.setAdjustment("halationActive", on) }
    }
    CheckRow {
        label: L10n.tr("effect.antihalation")
        checked: true
        available: false
        reason: L10n.tr("placeholder.antihalation")
    }
    ScrubSlider {
        label: L10n.tr("effect.halationStrength")
        from: 0; to: 4; defaultValue: 1; step: 0.05; snap: 0.25
        value: section.amount("halationAmount")
        gestureKey: "halationAmount"
        available: preview.settingsEditable && section.halationOn
        reason: section.halationOn ? "" : L10n.tr("effect.reasonOff")
        onMoved: function(v) { preview.setAdjustment("halationAmount", v) }
    }
    CheckRow {
        label: L10n.tr("effect.glare")
        checked: section.glareOn
        available: preview.settingsEditable
        onToggledTo: function(on) { preview.setAdjustment("glareActive", on) }
    }
    ScrubSlider {
        label: L10n.tr("effect.glareStrength")
        from: 0; to: 30; defaultValue: 1; step: 0.1; snap: 1
        value: section.amount("glareAmount")
        gestureKey: "glareAmount"
        available: preview.settingsEditable && section.glareOn
        reason: section.glareOn ? "" : L10n.tr("effect.reasonOff")
        onMoved: function(v) { preview.setAdjustment("glareAmount", v) }
    }
}
