import QtQuick
import QtQuick.Controls

// Film Format (ParameterSections.swift `FilmFormatSection`): the physical
// frame, which sets the scale of grain and halation (cropping does not change
// it), and the film effects, each switch followed by what it governs -- the
// Mac's "decoupled" layout (RFC-025), which Windows always shows:
//
//   Grain, Grain Strength
//   Halation, Anti-Halation Layer, Halation Strength, Scatter Strength,
//     Highlight Boost (stops, off at 0)
//   DIR Couplers, Couplers Strength
//   Glare, Glare Strength -- the print's veil, so it greys with Print Effects
//
// A dependant greys, rather than hides, while its switch is off: the value is
// still the photo's. The sub-layer grain model is a model choice rather than
// a strength, so it is a check in the "..." menu, as on the Mac.
//
// The engine takes one number, the frame's long edge; the Mac derives it
// from a film type, a side and a side length and the photo's aspect, which
// needs per-photo fields the Windows settings table does not have yet. Until
// then Long Edge chooses the number directly -- the same wire value, so a
// later lane can put Size / Side / Side Length in front of it.
MacSection {
    id: section
    sectionId: "filmFormat"
    title: L10n.tr("format.title")
    readonly property var p: preview.parameters
    function flag(key, fallback) { return p[key] === undefined ? fallback : p[key] === true }
    function number(key, fallback) { return p[key] === undefined ? fallback : Number(p[key]) }
    readonly property bool editable: preview.settingsEditable
    readonly property bool grainOn: flag("grain_active", true)
    readonly property bool halationOn: flag("halation_active", true)
    readonly property bool couplersOn: flag("dir_couplers_active", true)
    readonly property bool glareOn: flag("glare_active", true)
    readonly property bool printEffects: flag("print_effects", true)
    // EffectStrengths.default (Params.swift:383-413), by wire name.
    readonly property var strengthDefaults: ({
        grain_amount: 1, grain_sublayers_active: true, halation_amount: 1, antihalation_removed: false,
        halation_boost_ev: 0, halation_scatter_amount: 1, dir_couplers_active: true, dir_couplers_amount: 1,
        glare_amount: 1 })
    readonly property bool strengthsAreDefault: {
        for (var key in strengthDefaults) {
            var v = p[key]
            if (v !== undefined && v !== strengthDefaults[key]) return false
        }
        return true
    }
    // Each of these is one edit -- one undo step, one render -- through
    // setParameters, as the Mac's menu commands write the sidecar once.
    function effects(on) { return { grain_active: on, halation_active: on, glare_active: on } }
    function setEffects(on) { preview.setParameters(effects(on)) }
    function resetStrengths() { preview.setParameters(strengthDefaults) }
    resetVisible: true
    resetAvailable: editable
    resetToolTip: L10n.tr("format.reset")
    onResetRequested: {
        var all = effects(true)
        for (var key in strengthDefaults) all[key] = strengthDefaults[key]
        all.film_format_mm = 35
        preview.setParameters(all)
    }
    menuItems: [
        RailMenuItem { text: L10n.tr("format.allEffectsOn"); enabled: section.editable; onTriggered: section.setEffects(true) },
        RailMenuItem { text: L10n.tr("format.allEffectsOff"); enabled: section.editable; onTriggered: section.setEffects(false) },
        RailMenuItem { text: L10n.tr("format.resetStrengths"); enabled: section.editable && !section.strengthsAreDefault; onTriggered: section.resetStrengths() },
        MenuSeparator {},
        RailMenuItem {
            objectName: "subLayerGrainItem"
            text: L10n.tr("format.subLayerGrain")
            marked: section.flag("grain_sublayers_active", true)
            enabled: section.editable && section.grainOn
            onTriggered: preview.setParameter("grain_sublayers_active", !section.flag("grain_sublayers_active", true))
        }
    ]

    ParamRow {
        label: L10n.tr("format.longEdge")
        available: section.editable
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
        available: section.editable
        onToggledTo: function(on) { preview.setParameter("grain_active", on) }
    }
    ScrubSlider {
        label: L10n.tr("effect.grainStrength")
        from: 0; to: 2; defaultValue: 1; step: 0.05; snap: 0.25
        value: section.number("grain_amount", 1)
        gestureKey: "grain_amount"
        available: section.editable && section.grainOn
        reason: section.grainOn ? "" : L10n.tr("effect.reasonOff")
        onMoved: function(v) { preview.setParameter("grain_amount", v) }
    }

    CheckRow {
        label: L10n.tr("effect.halation")
        checked: section.halationOn
        available: section.editable
        onToggledTo: function(on) { preview.setParameter("halation_active", on) }
    }
    // A property of the film rather than a strength: on is the film as its
    // profile tags it, off the same film with the layer removed (a cine
    // negative without its remjet).
    CheckRow {
        objectName: "antihalationRow"
        label: L10n.tr("effect.antihalation")
        checked: !section.flag("antihalation_removed", false)
        available: section.editable && section.halationOn
        reason: section.halationOn ? "" : L10n.tr("effect.reasonHalationOff")
        onToggledTo: function(on) { preview.setParameter("antihalation_removed", !on) }
    }
    ScrubSlider {
        label: L10n.tr("effect.halationStrength")
        from: 0; to: 4; defaultValue: 1; step: 0.05; snap: 0.25
        value: section.number("halation_amount", 1)
        gestureKey: "halation_amount"
        available: section.editable && section.halationOn
        reason: section.halationOn ? "" : L10n.tr("effect.reasonOff")
        onMoved: function(v) { preview.setParameter("halation_amount", v) }
    }
    ScrubSlider {
        label: L10n.tr("effect.scatterStrength")
        from: 0; to: 1; defaultValue: 1; step: 0.01; snap: 0.25
        value: section.number("halation_scatter_amount", 1)
        gestureKey: "halation_scatter_amount"
        available: section.editable && section.halationOn
        reason: section.halationOn ? "" : L10n.tr("effect.reasonHalationOff")
        onMoved: function(v) { preview.setParameter("halation_scatter_amount", v) }
    }
    // Stops, not a multiple: its neutral is 0 and it is off there.
    ScrubSlider {
        label: L10n.tr("effect.highlightBoost")
        from: 0; to: 8; defaultValue: 0; step: 0.1; snap: 0.5; decimals: 1
        value: section.number("halation_boost_ev", 0)
        gestureKey: "halation_boost_ev"
        available: section.editable && section.halationOn
        reason: section.halationOn ? "" : L10n.tr("effect.reasonHalationOff")
        toolTip: L10n.tr("effect.highlightBoostNote")
        onMoved: function(v) { preview.setParameter("halation_boost_ev", v) }
    }

    CheckRow {
        label: L10n.tr("effect.couplers")
        checked: section.couplersOn
        available: section.editable
        onToggledTo: function(on) { preview.setParameter("dir_couplers_active", on) }
    }
    ScrubSlider {
        objectName: "couplersAmountRow"
        label: L10n.tr("effect.couplersStrength")
        from: 0; to: 1.5; defaultValue: 1; step: 0.05; snap: 0.25
        value: section.number("dir_couplers_amount", 1)
        gestureKey: "dir_couplers_amount"
        available: section.editable && section.couplersOn
        reason: section.couplersOn ? "" : L10n.tr("effect.reasonOff")
        onMoved: function(v) { preview.setParameter("dir_couplers_amount", v) }
    }

    CheckRow {
        objectName: "glareRow"
        label: L10n.tr("effect.glare")
        checked: section.glareOn
        available: section.editable && section.printEffects
        reason: section.printEffects ? "" : L10n.tr("effect.reasonPrintEffectsOff")
        onToggledTo: function(on) { preview.setParameter("glare_active", on) }
    }
    ScrubSlider {
        label: L10n.tr("effect.glareStrength")
        from: 0; to: 30; defaultValue: 1; step: 0.1; snap: 0.25
        value: section.number("glare_amount", 1)
        gestureKey: "glare_amount"
        available: section.editable && section.glareOn && section.printEffects
        reason: !section.printEffects ? L10n.tr("effect.reasonPrintEffectsOff") : section.glareOn ? "" : L10n.tr("effect.reasonOff")
        onMoved: function(v) { preview.setParameter("glare_amount", v) }
    }
}
