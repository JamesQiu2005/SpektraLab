import QtQuick

// Enlarger (EnlargerSection.swift): print brightness in stops, -3..3 (brighter
// positive -- the engine's print exposure inverts, and nobody should have to
// hold that in their head), the dichroic head's two axes, and pre-flash. A
// negative prints the other way, so each filter's track is coloured by where
// it takes the picture: more yellow filtration is a bluer print, more magenta
// a greener one (the Mac's "→ blue" / "→ green" since d22f6cb). Zero is the
// solved pack.
//
// Pre-flash is the paper's uniform exposure through the film's clear base;
// its wire value is 0..0.03, so the row shows it x100 as the Mac does, and it
// greys while Print Effects is off (the wire sends no pre-flash then).
//
// None of it applies to a slide film, which is scanned without a print (the
// controller refuses brightness for one); the rows grey with the reason.
MacSection {
    id: section
    sectionId: "enlarger"
    title: L10n.tr("enlarger.title")
    readonly property bool printing: preview.settingsEditable && !preview.filmIsPositive
    readonly property string slideReason: preview.filmIsPositive ? L10n.tr("enlarger.reason.slide") : ""
    readonly property bool printEffects: preview.parameters.print_effects === undefined ? true : preview.parameters.print_effects === true
    function number(key, fallback) {
        var v = preview.parameters[key]
        return v === undefined ? fallback : Number(v)
    }
    resetVisible: true
    resetAvailable: printing
    resetToolTip: L10n.tr("enlarger.reset")
    resetReason: slideReason
    onResetRequested: preview.resetEnlarger()
    menuItems: [
        RailMenuItem { text: L10n.tr("enlarger.reset"); enabled: section.printing; onTriggered: preview.resetEnlarger() }
    ]

    ScrubSlider {
        label: L10n.tr("enlarger.brightness")
        sublabel: L10n.tr("enlarger.stops")
        bodyObjectName: "exposureSlider"
        from: -3; to: 3; defaultValue: 0
        step: 0.05; snap: 0.25; decimals: 2; signed: true
        value: preview.exposureEv
        gestureKey: "exposureEv"
        available: section.printing
        reason: section.slideReason
        onMoved: function(v) { preview.exposureEv = v }
    }
    ScrubSlider {
        label: L10n.tr("enlarger.yellow")
        sublabel: L10n.tr("enlarger.towardBlue")
        from: -1; to: 1; defaultValue: 0
        step: 0.01; snap: 0.05; decimals: 2; signed: true
        gradient: ["#b8a860", "#8a8a8a", "#6f7fb0"]
        value: section.number("y_filter_shift", 0)
        gestureKey: "y_filter_shift"
        available: section.printing
        reason: section.slideReason
        onMoved: function(v) { preview.setParameter("y_filter_shift", v) }
    }
    ScrubSlider {
        label: L10n.tr("enlarger.magenta")
        sublabel: L10n.tr("enlarger.towardGreen")
        from: -1; to: 1; defaultValue: 0
        step: 0.01; snap: 0.05; decimals: 2; signed: true
        gradient: ["#b07cae", "#8a8a8a", "#7ca87c"]
        value: section.number("m_filter_shift", 0)
        gestureKey: "m_filter_shift"
        available: section.printing
        reason: section.slideReason
        onMoved: function(v) { preview.setParameter("m_filter_shift", v) }
    }
    ScrubSlider {
        objectName: "preflashRow"
        label: L10n.tr("enlarger.preflash")
        sublabel: "×100"
        from: 0; to: 3; defaultValue: 0
        step: 0.05; snap: 0.25; decimals: 2
        value: section.number("preflash_exposure", 0) * 100
        gestureKey: "preflash_exposure"
        available: section.printing && section.printEffects
        reason: section.slideReason.length > 0 ? section.slideReason : L10n.tr("effect.reasonPrintEffectsOff")
        onMoved: function(v) { preview.setParameter("preflash_exposure", Math.max(0, Math.min(0.03, v / 100))) }
    }
}
