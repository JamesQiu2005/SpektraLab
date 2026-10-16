import QtQml
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
// enlarger re-times the print; Brightness in the Enlarger is that). Its "As
// Shot" box is derived (Session.filmExposureIsAsShot): ticked on the
// linearized baseline -- meter off, no compensation -- and ticking it sets
// both; unticking does nothing, as on the Mac. Beside it, while a meter is
// on, the meter's reading for this frame ("auto +0.9 EV", Session
// .solvedEVLabel): what the slider's zero means.
//
// Temperature and Tint are the decode's white balance (WhiteBalanceRows
// .swift, preview.whiteBalance): each with its As Shot box ("this axis is the
// camera's"), the Mac's gradient tracks, ranges and zero ticks at the
// camera's pair. Editing either re-decodes the RAW. The presets and the
// neutral picker are in the section's "..." as the Mac has them; the picker
// arms the canvas (EditorState.pickingNeutral, CanvasView.qml).
//
// Vignetting is the Mac's Layer 2 lens fall-off: the Post-Dev grade's
// vignette (PostDevSlider, `vignette.amount`), which the Mac shows here and
// only here. Lens Correction is greyed because LibRaw has no lens profiles.
MacSection {
    id: section
    sectionId: "camera"
    title: L10n.tr("camera.title")
    // The window's EditorState, from the rail that holds this section (as
    // ParamRow finds `railLabelWidth`), for the neutral picker.
    readonly property var editor: {
        for (var p = parent; p; p = p.parent)
            if (p.editor !== undefined) return p.editor
        return null
    }
    readonly property var methods: preview.aeMethodChoices
    readonly property string method: preview.aeMethod
    readonly property string legacyName: preview.parameters.auto_exposure_method === undefined ? "" : String(preview.parameters.auto_exposure_method)
    readonly property real filmExposure: preview.adjustments.filmExposureEv === undefined ? 0 : Number(preview.adjustments.filmExposureEv)
    readonly property var wb: preview.whiteBalance
    readonly property var meter: preview.metering
    // The white balance rows: settings unlocked, and a camera LibRaw can
    // re-balance (`enabled` is false only for one with no colour matrix).
    readonly property bool wbAvailable: preview.settingsEditable && wb.enabled !== false
    readonly property string wbReason: wb.raw === false ? L10n.tr("camera.reasonDecodeWB")
        : wb.enabled === false ? L10n.tr("camera.reasonNoMatrix") : ""
    readonly property bool boxesAvailable: wbAvailable && wb.boxesEnabled === true
    readonly property bool pickArmed: editor !== null && editor.pickingNeutral
    function methodTitle(m) {
        if (m === "custom") return L10n.tr("camera.metering.custom")
        if (m === "balanced") return L10n.tr("camera.metering.balanced")
        if (m === "center") return L10n.tr("camera.metering.center")
        if (m === "protect_highlights") return L10n.tr("camera.metering.protectHighlights")
        if (m === "protect_shadows") return L10n.tr("camera.metering.protectShadows")
        return m
    }
    function signedFixed(v, d) {
        var s = Number(v).toFixed(d)
        if (Number(s) === 0) s = (0).toFixed(d)
        return (Number(s) >= 0 ? "+" : "") + s
    }
    resetVisible: true
    resetAvailable: preview.settingsEditable
    resetToolTip: L10n.tr("camera.resetFilmExposure")
    onResetRequested: preview.setAdjustment("filmExposureEv", 0)
    menuItems: [
        RailMenuItem { text: L10n.tr("camera.resetFilmExposure"); enabled: preview.settingsEditable; onTriggered: preview.setAdjustment("filmExposureEv", 0) },
        MenuSeparator {},
        RailMenuItem {
            objectName: "pickNeutralItem"
            text: section.pickArmed ? L10n.tr("camera.pickNeutralCancel") : L10n.tr("camera.pickNeutral")
            marked: section.pickArmed
            enabled: section.editor !== null && (section.pickArmed || section.editor.canPickNeutral)
            onTriggered: section.editor.togglePickNeutral()
        },
        // The presets keep their engine names, as the Mac leaves them in
        // English (CameraSection.swift:125-127); every mode but Custom.
        RailMenu {
            id: presetMenu
            title: L10n.tr("camera.whiteBalancePreset")
            enabled: section.wbAvailable
            Instantiator {
                model: preview.whiteBalancePresets
                delegate: RailMenuItem {
                    text: modelData.label
                    marked: section.wb.mode === modelData.id
                    onTriggered: preview.setWhiteBalancePreset(modelData.id)
                }
                onObjectAdded: function(index, object) { presetMenu.insertItem(index, object) }
                onObjectRemoved: function(index, object) { presetMenu.removeItem(object) }
            }
        }
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
        value: section.filmExposure
        gestureKey: "filmExposureEv"
        available: preview.settingsEditable
        toolTip: L10n.tr("camera.filmExposureNote")
        onMoved: function(v) { preview.setAdjustment("filmExposureEv", v) }
        secondLine: Row {
            spacing: 10
            AsShotLine {
                id: exposureAsShot
                anchors.verticalCenter: parent.verticalCenter
                checked: section.method === "custom" && Math.abs(section.filmExposure) < 1e-9
                available: preview.settingsEditable
                // Session.setFilmExposureAsShot: both halves as one edit (one
                // undo step), and unticking is not a request.
                onToggledTo: function(on) {
                    if (!on || checked) return
                    preview.setParameters({ auto_exposure: false, exposure_compensation_ev: 0 })
                }
                HoverHandler { id: asShotHover }
                ToolTip.visible: asShotHover.hovered
                ToolTip.text: L10n.tr("camera.asShotFilmExposureHelp")
                ToolTip.delay: 600
            }
            Text {
                objectName: "meteredLabel"
                anchors.verticalCenter: parent.verticalCenter
                visible: section.meter.available === true && section.method !== "custom"
                text: visible ? L10n.tr("camera.meteredLabel", [section.signedFixed(section.meter.exposureEv, 1)]) : ""
                color: Theme.dim
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
                HoverHandler { id: meterHover }
                ToolTip.visible: meterHover.hovered
                ToolTip.text: L10n.tr("camera.meteredHelp", [section.methodTitle(section.method)])
                ToolTip.delay: 600
            }
        }
    }
    ScrubSlider {
        objectName: "temperatureSlider"
        label: L10n.tr("camera.temperature")
        from: section.wb.temperatureFrom === undefined ? 2000 : section.wb.temperatureFrom
        to: section.wb.temperatureTo === undefined ? 12000 : section.wb.temperatureTo
        defaultValue: section.wb.temperatureZero === undefined ? 5500 : section.wb.temperatureZero
        step: 50; snap: 100; decimals: 0
        format: function(v) { return String(Math.round(v)) }
        gradient: ["#005982", "#8fa83c", "#fff100"]
        value: section.wb.temperature === undefined ? 5500 : Number(section.wb.temperature)
        gestureKey: "white_balance_temperature"
        available: section.wbAvailable
        reason: section.wbReason
        toolTip: L10n.tr("camera.temperatureHelp")
        onMoved: function(v) { preview.setTemperature(Math.round(v)) }
        secondLine: AsShotLine {
            checked: section.wb.temperatureAsShot === true
            available: section.boxesAvailable
            reason: section.wbAvailable ? L10n.tr("camera.reasonNoAsShot") : section.wbReason
            onToggledTo: function(on) { preview.setTemperatureAsShot(on) }
        }
    }
    ScrubSlider {
        objectName: "tintSlider"
        label: L10n.tr("camera.tint")
        from: section.wb.tintFrom === undefined ? -150 : section.wb.tintFrom
        to: section.wb.tintTo === undefined ? 150 : section.wb.tintTo
        defaultValue: section.wb.tintZero === undefined ? 0 : section.wb.tintZero
        step: 1; snap: 5; decimals: 1; signed: true
        gradient: ["#00a93a", "#8aa45e", "#e4007f"]
        value: section.wb.tint === undefined ? 0 : Number(section.wb.tint)
        gestureKey: "white_balance_tint"
        available: section.wbAvailable
        reason: section.wbReason
        toolTip: L10n.tr("camera.tintHelp")
        onMoved: function(v) { preview.setTint(v) }
        secondLine: AsShotLine {
            checked: section.wb.tintAsShot === true
            available: section.boxesAvailable
            reason: section.wbAvailable ? L10n.tr("camera.reasonNoAsShot") : section.wbReason
            onToggledTo: function(on) { preview.setTintAsShot(on) }
        }
    }
    // The Post-Dev grade's vignette (CameraSection.swift:82-85: Layer 2's
    // lens fall-off, here "because that is where a photographer looks for
    // it"); its range and snap from postdev::fields, one undo step a drag.
    PostDevSlider {
        objectName: "cameraVignetting"
        path: "vignette.amount"
        label: L10n.tr("camera.vignetting")
        toolTip: L10n.tr("postDev.vignettingNote")
    }
    CheckRow {
        label: L10n.tr("camera.lensCorrection")
        checked: false
        available: false
        reason: L10n.tr("camera.lensCorrectionReason")
    }
}
