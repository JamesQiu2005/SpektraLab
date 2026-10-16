import QtQuick
import QtQuick.Layouts

// Tone Mask (ParameterSections.swift:260-353, RFC-024): the engine's global
// virtual contrast mask -- one Gaussian base over the whole frame's paper
// exposure (Radius, a percentage of the long edge), then one curve from that
// base to a change in exposure: Highlights lifts the regions the paper would
// print light, Shadows holds back the dark ones, and Core is the span about
// mid-grey left alone. The plot under the sliders is that curve
// (preview.toneMask.curve, ToneMaskPlot), so what it shows is the mask
// itself; the picture only decides where each region sits on it.
//
// A print edit through the contrast_mask_* rows, each drag one undo step.
// Greyed with the reason while Print Effects is off, because the wire does
// not carry it then; the rows under Enable wait for it. The Mac ships the
// section behind a feature flag; Windows shows it, folded by default.
MacSection {
    id: section
    sectionId: "toneMask"
    title: L10n.tr("mask.title")
    defaultExpanded: false
    readonly property var mask: preview.toneMask
    readonly property bool allowed: mask.allowed === true
    readonly property bool rowsAvailable: preview.settingsEditable && mask.rowsEnabled === true
    readonly property string rowsReason: !allowed ? L10n.tr("mask.reasonPrintEffectsOff") : L10n.tr("mask.reasonInactive")
    function initial(key, fallback) {
        var fields = preview.parameterFields
        for (var i = 0; i < fields.length; ++i)
            if (fields[i].key === key) return Number(fields[i].initial)
        return fallback
    }
    resetVisible: true
    resetAvailable: preview.settingsEditable && mask.isDefault === false
    resetToolTip: L10n.tr("mask.reset")
    onResetRequested: preview.resetToneMask()

    CheckRow {
        objectName: "toneMaskEnable"
        label: L10n.tr("mask.enable")
        checked: section.mask.active === true
        available: preview.settingsEditable && section.allowed
        reason: section.allowed ? "" : L10n.tr("mask.reasonPrintEffectsOff")
        onToggledTo: function(on) { preview.setParameter("contrast_mask_active", on) }
    }
    ScrubSlider {
        label: L10n.tr("mask.highlights")
        from: 0; to: 3; defaultValue: section.initial("contrast_mask_highlights", 0)
        step: 0.05; snap: 0.25; decimals: 2
        value: Number(section.mask.highlights || 0)
        gestureKey: "contrast_mask_highlights"
        available: section.rowsAvailable
        reason: section.rowsReason
        onMoved: function(v) { preview.setParameter("contrast_mask_highlights", v) }
    }
    ScrubSlider {
        label: L10n.tr("mask.shadows")
        from: 0; to: 3; defaultValue: section.initial("contrast_mask_shadows", 0)
        step: 0.05; snap: 0.25; decimals: 2
        value: Number(section.mask.shadows || 0)
        gestureKey: "contrast_mask_shadows"
        available: section.rowsAvailable
        reason: section.rowsReason
        onMoved: function(v) { preview.setParameter("contrast_mask_shadows", v) }
    }
    ScrubSlider {
        label: L10n.tr("mask.core")
        from: 0; to: 3; defaultValue: section.initial("contrast_mask_core", 1)
        step: 0.05; snap: 0.25; decimals: 2
        value: section.mask.core === undefined ? 1 : Number(section.mask.core)
        gestureKey: "contrast_mask_core"
        available: section.rowsAvailable
        reason: section.rowsReason
        onMoved: function(v) { preview.setParameter("contrast_mask_core", v) }
    }
    // The wire's scale is a fraction of the long edge; a percentage of it is
    // the same number a person can picture.
    ScrubSlider {
        label: L10n.tr("mask.radius")
        from: section.mask.radiusFrom === undefined ? 0.2 : section.mask.radiusFrom
        to: section.mask.radiusTo === undefined ? 12 : section.mask.radiusTo
        defaultValue: section.initial("contrast_mask_scale", 0.03) * 100
        step: 0.1; snap: 0.5; decimals: 1; suffix: " %"
        value: section.mask.radiusPercent === undefined ? 3 : Number(section.mask.radiusPercent)
        gestureKey: "contrast_mask_scale"
        available: section.rowsAvailable
        reason: section.rowsReason
        onMoved: function(v) { preview.setParameter("contrast_mask_scale", Math.max(from, Math.min(to, v)) / 100) }
    }
    // ToneMaskPlot: x the blurred negative's exposure on the paper, -6..6
    // stops from mid-grey; y the change the mask makes there, -3..3. The core
    // is shaded.
    Canvas {
        id: plot
        objectName: "toneMaskPlot"
        Layout.fillWidth: true
        Layout.topMargin: 2
        implicitHeight: Theme.maskPlotHeight
        opacity: section.rowsAvailable ? 1 : Theme.disabledOpacity
        readonly property var reading: section.mask
        onReadingChanged: requestPaint()
        onWidthChanged: requestPaint()
        onVisibleChanged: if (visible) requestPaint()
        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var w = width, h = height
            if (w <= 0 || h <= 0) return
            function px(v) { return (v + 6) / 12 * w }
            function py(v) { return (3 - v) / 6 * h }
            ctx.fillStyle = Theme.plot
            ctx.beginPath(); ctx.roundedRect(0, 0, w, h, 2, 2); ctx.fill()
            var core = Number(reading.core || 0)
            var g = Theme.plotGrid
            ctx.fillStyle = Qt.rgba(g.r, g.g, g.b, 0.6)
            ctx.fillRect(px(-core), 0, px(core) - px(-core), h)
            ctx.lineWidth = 0.5
            ctx.strokeStyle = Theme.plotMidGrey
            ctx.beginPath(); ctx.moveTo(0, py(0)); ctx.lineTo(w, py(0)); ctx.stroke()
            ctx.beginPath(); ctx.moveTo(px(0), 0); ctx.lineTo(px(0), h); ctx.stroke()
            var curve = reading.curve || []
            if (curve.length < 2) return
            ctx.lineWidth = 1.2
            ctx.lineJoin = "round"
            ctx.strokeStyle = Theme.text
            ctx.beginPath()
            for (var i = 0; i < curve.length; ++i) {
                var x = px(Number(curve[i].x)), y = py(Number(curve[i].y))
                if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
            }
            ctx.stroke()
        }
    }
    Note { text: L10n.tr("mask.caption"); opacity: plot.opacity }
}
