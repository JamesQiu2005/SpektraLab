import QtQuick

// Tone Mask (ParameterSections.swift, RFC-024): the engine's global virtual
// contrast mask -- one blurred base of the paper exposure and one curve from
// it to a change in exposure, drawn under the sliders. Folded by default; the
// Mac ships it behind a feature flag and the Windows boundary does not carry
// it yet, so every row is greyed with the reason.
MacSection {
    sectionId: "toneMask"
    title: L10n.tr("mask.title")
    defaultExpanded: false
    resetVisible: true
    resetAvailable: false
    resetToolTip: L10n.tr("mask.reset")
    resetReason: L10n.tr("placeholder.toneMask")

    CheckRow {
        label: L10n.tr("mask.enable")
        available: false
        reason: L10n.tr("placeholder.toneMask")
    }
    ScrubSlider { label: L10n.tr("mask.highlights"); from: 0; to: 3; value: 0; available: false; reason: L10n.tr("placeholder.toneMask") }
    ScrubSlider { label: L10n.tr("mask.shadows"); from: 0; to: 3; value: 0; available: false; reason: L10n.tr("placeholder.toneMask") }
    ScrubSlider { label: L10n.tr("mask.core"); from: 0; to: 3; defaultValue: 1; value: 1; available: false; reason: L10n.tr("placeholder.toneMask") }
    ScrubSlider {
        label: L10n.tr("mask.radius")
        from: 0.5; to: 10; defaultValue: 3; value: 3; decimals: 1; suffix: " %"
        available: false
        reason: L10n.tr("placeholder.toneMask")
    }
    PlotPlaceholder { implicitHeight: Theme.maskPlotHeight; opacity: Theme.disabledOpacity }
    Note { text: L10n.tr("mask.caption"); opacity: Theme.disabledOpacity }
}
