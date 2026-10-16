import QtQuick
import QtQuick.Controls

// Input / Camera (CameraSection.swift): how the photograph enters the film.
//
// Metering is the controller's aeMethod (Params.swift AEMethod): Custom is
// the meter off (auto_exposure false -- Film Exposure is then the whole of the
// film exposure, from the linearized frame), and the four intents meter with
// auto_exposure_method: overall correctness, a subject in the middle, the
// brightest part kept, the darkest kept. Custom leaves the intent alone, so
// switching the meter back on returns to it. A photo saved before the field
// existed meters with the engine's own method ("legacy") and shows it by name;
// it is not offered.
//
// Film Exposure sits under it because the two are one decision read in two
// lines: the method chooses a baseline and the slider offsets it. It moves
// where the scene sits on the film's curve, not the print's brightness (the
// enlarger re-times the print; Brightness in the Enlarger is that).
//
// Temperature, Tint (decode white balance, each with its "As Shot" box),
// Vignetting and Lens Correction are the Mac's rows; the Windows RAW decode
// does not take them yet, so they are greyed with the reason.
MacSection {
    id: section
    sectionId: "camera"
    title: L10n.tr("camera.title")
    readonly property var methods: preview.aeMethodChoices
    readonly property string method: preview.aeMethod
    readonly property string legacyName: preview.parameters.auto_exposure_method === undefined ? "" : String(preview.parameters.auto_exposure_method)
    function methodTitle(m) {
        if (m === "custom") return L10n.tr("camera.metering.custom")
        if (m === "balanced") return L10n.tr("camera.metering.balanced")
        if (m === "center") return L10n.tr("camera.metering.center")
        if (m === "protect_highlights") return L10n.tr("camera.metering.protectHighlights")
        if (m === "protect_shadows") return L10n.tr("camera.metering.protectShadows")
        return m
    }
    resetVisible: true
    resetAvailable: preview.settingsEditable
    resetToolTip: L10n.tr("camera.resetFilmExposure")
    onResetRequested: preview.setAdjustment("filmExposureEv", 0)
    menuItems: [
        RailMenuItem { text: L10n.tr("camera.resetFilmExposure"); enabled: preview.settingsEditable; onTriggered: preview.setAdjustment("filmExposureEv", 0) },
        MenuSeparator {},
        RailMenuItem { text: L10n.tr("camera.pickNeutral"); enabled: false },
        RailMenuItem { text: L10n.tr("camera.whiteBalancePreset"); enabled: false }
    ]

    ParamRow {
        label: L10n.tr("camera.metering")
        available: preview.settingsEditable
        PillDropdown {
            objectName: "meteringPill"
            readonly property bool legacy: section.method === "legacy"
            model: {
                var titles = []
                for (var i = 0; i < section.methods.length; ++i) titles.push(section.methodTitle(section.methods[i]))
                if (legacy) titles.push(L10n.tr("camera.metering.legacy", [section.legacyName.replace(/_/g, "-")]))
                return titles
            }
            // Reads `model` so a language switch re-runs the binding.
            currentIndex: { model; return legacy ? section.methods.length : section.methods.indexOf(section.method) }
            onActivated: function(index) { if (index < section.methods.length) preview.aeMethod = section.methods[index] }
        }
    }
    ScrubSlider {
        label: L10n.tr("camera.filmExposure")
        from: -4; to: 4; defaultValue: 0
        step: 0.1; snap: 1 / 3; decimals: 1; signed: true
        value: preview.adjustments.filmExposureEv === undefined ? 0 : Number(preview.adjustments.filmExposureEv)
        gestureKey: "filmExposureEv"
        available: preview.settingsEditable
        toolTip: L10n.tr("camera.filmExposureNote")
        onMoved: function(v) { preview.setAdjustment("filmExposureEv", v) }
        secondLine: AsShotLine { available: false; reason: L10n.tr("placeholder.asShot") }
    }
    ScrubSlider {
        label: L10n.tr("camera.temperature")
        from: 2000; to: 12000; defaultValue: 5500; step: 50; decimals: 0
        gradient: ["#005982", "#8fa83c", "#fff100"]
        value: 5500
        available: false
        reason: L10n.tr("placeholder.whiteBalance")
        secondLine: AsShotLine { checked: true }
    }
    ScrubSlider {
        label: L10n.tr("camera.tint")
        from: -150; to: 150; defaultValue: 0; step: 1; decimals: 1; signed: true
        gradient: ["#00a93a", "#8aa45e", "#e4007f"]
        value: 0
        available: false
        reason: L10n.tr("placeholder.whiteBalance")
        secondLine: AsShotLine { checked: true }
    }
    ScrubSlider {
        label: L10n.tr("camera.vignetting")
        from: -100; to: 100; defaultValue: 0; step: 1; decimals: 0; signed: true
        value: 0
        available: false
        reason: L10n.tr("placeholder.vignetting")
    }
    CheckRow {
        label: L10n.tr("camera.lensCorrection")
        checked: false
        available: false
        reason: L10n.tr("placeholder.lensCorrection")
    }
}
