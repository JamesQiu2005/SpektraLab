import QtQuick

// Enlarger (EnlargerSection.swift): print brightness in stops (brighter
// positive -- the engine's print exposure inverts, and nobody should have to
// hold that in their head) and the dichroic head's two axes. A negative
// prints the other way, so each filter's track is coloured by where it takes
// the picture: more yellow filtration is a bluer print, more magenta a
// greener one. Zero is the solved pack.
//
// None of it applies to a slide film, which is scanned without a print; the
// rows grey with the reason. Pre-flash -- the paper's uniform exposure
// through the film base -- is a print parameter the Windows settings table
// does not carry yet.
MacSection {
    id: section
    sectionId: "enlarger"
    title: L10n.tr("enlarger.title")
    readonly property bool printing: preview.settingsEditable && !preview.filmIsPositive
    readonly property string slideReason: preview.filmIsPositive ? L10n.tr("enlarger.reason.slide") : ""
    resetVisible: true
    resetAvailable: printing
    resetToolTip: L10n.tr("enlarger.reset")
    resetReason: slideReason
    onResetRequested: resetEnlarger()
    menuItems: [
        RailMenuItem { text: L10n.tr("enlarger.reset"); enabled: section.printing; onTriggered: section.resetEnlarger() }
    ]

    function resetEnlarger() {
        preview.exposureEv = 0
        preview.setAdjustment("yFilterShift", 0)
        preview.setAdjustment("mFilterShift", 0)
    }

    ScrubSlider {
        label: L10n.tr("enlarger.brightness")
        sublabel: L10n.tr("enlarger.stops")
        bodyObjectName: "exposureSlider"
        from: -2; to: 2; defaultValue: 0
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
        value: preview.adjustments.yFilterShift === undefined ? 0 : Number(preview.adjustments.yFilterShift)
        gestureKey: "yFilterShift"
        available: section.printing
        reason: section.slideReason
        onMoved: function(v) { preview.setAdjustment("yFilterShift", v) }
    }
    ScrubSlider {
        label: L10n.tr("enlarger.magenta")
        sublabel: L10n.tr("enlarger.towardGreen")
        from: -1; to: 1; defaultValue: 0
        step: 0.01; snap: 0.05; decimals: 2; signed: true
        gradient: ["#b07cae", "#8a8a8a", "#7ca87c"]
        value: preview.adjustments.mFilterShift === undefined ? 0 : Number(preview.adjustments.mFilterShift)
        gestureKey: "mFilterShift"
        available: section.printing
        reason: section.slideReason
        onMoved: function(v) { preview.setAdjustment("mFilterShift", v) }
    }
    ScrubSlider {
        label: L10n.tr("enlarger.preflash")
        sublabel: "×100"
        from: 0; to: 3; defaultValue: 0
        step: 0.05; decimals: 2
        value: 0
        available: false
        reason: L10n.tr("placeholder.preflash")
    }
}
