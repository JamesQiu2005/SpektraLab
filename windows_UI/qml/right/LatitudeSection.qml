import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Latitude (LatitudeSection.swift): how much of the frame this film and paper
// hold. Read it like a depth-of-field bar that measures the medium:
//
// - the histogram is the frame on the stop axis, relative to the metered
//   mid-grey, after Scene Placement, with a square-root height so one bright
//   area cannot flatten the rest;
// - the band under it is the chain's lightness change per stop over its peak
//   -- the model's own toe and shoulder;
// - the dashed lines are the ISO 6846 boundaries the Fit targets, labelled
//   at the top; beyond them the fill dims and its edge turns accent: those
//   pixels print, but flattened. A triangle in a top corner says pixels fall
//   past that end of the fixed -8..8 axis.
//
// Every number is the engine's spk_scene_latitude (preview.latitude). The
// last measurement of the photograph stays up while a newer render is being
// measured, dimmed (`current` false), so the graph does not blink on every
// edit. The header names the pair it was measured on, makers dropped.
MacSection {
    id: section
    sectionId: "latitude"
    title: L10n.tr("latitude.title")
    readonly property var lat: preview.latitude
    readonly property bool shown: preview.hasFrame && lat.available === true
    caption: {
        function short(name) {
            var makers = ["Kodak Professional ", "Kodak ", "Fujifilm ", "Fuji "]
            for (var i = 0; i < makers.length; ++i)
                if (name.indexOf(makers[i]) === 0) return name.substring(makers[i].length)
            return name
        }
        var film = preview.films.length > preview.filmIndex && preview.filmIndex >= 0 ? short(preview.films[preview.filmIndex].name) : ""
        if (preview.filmIsPositive || preview.noPrintProfile) return film
        var paper = preview.papers.length > preview.paperIndex && preview.paperIndex >= 0 ? short(preview.papers[preview.paperIndex].name) : ""
        return film + (paper.length > 0 ? " · " + paper : "")
    }

    function stops(v) {
        var s = Math.abs(v).toFixed(2)
        return (Number(s) === 0 ? "" : v > 0 ? "+" : "−") + s
    }
    // Each part unbreakable (no-break spaces), so a narrow rail wraps only
    // at the " · " between them (LatitudeSection.swift:112-124).
    function summary() {
        function keep(s) { return s.replace(/ /g, " ") }
        var parts = [keep(Number(lat.highlightEv - lat.shadowEv).toFixed(2) + " " + L10n.tr("latitude.held")),
                     keep(stops(lat.shadowEv) + " – " + stops(lat.highlightEv))]
        if (lat.hasCore === true)
            parts.push(keep(L10n.tr("latitude.fullSeparation") + " " + stops(lat.coreFrom) + " – " + stops(lat.coreTo)))
        return parts.join(" · ")
    }
    function emptyText() {
        if (!preview.hasFrame) return L10n.tr("latitude.empty")
        if (lat.failureKind === "unmeasurable") return L10n.tr("latitude.unmeasurable")
        if (lat.failureKind === "noLight") return L10n.tr("latitude.noLight")
        if (lat.failure !== undefined && String(lat.failure).length > 0) return String(lat.failure)
        return preview.busy ? L10n.tr("latitude.measuring") : L10n.tr("latitude.empty")
    }

    Canvas {
        id: plot
        objectName: "latitudePlot"
        visible: section.shown
        Layout.fillWidth: true
        // LatitudePlot's plot, band gap, band and axis (Theme.swift:502-505).
        readonly property real plotH: 60
        readonly property real bandGap: 5
        readonly property real bandH: 6
        readonly property real axisH: 14
        implicitHeight: plotH + bandGap + bandH + axisH
        opacity: section.lat.current === false ? 0.55 : 1
        readonly property var reading: section.lat
        onReadingChanged: requestPaint()
        onWidthChanged: requestPaint()
        onVisibleChanged: if (visible) requestPaint()
        HoverHandler { id: plotHover }
        ToolTip.visible: plotHover.hovered
        ToolTip.text: L10n.tr("latitude.plotHelp")
        ToolTip.delay: 800

        function ink(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
        function strength(ev, s) {
            if (!s || s.length === 0) return 0
            if (ev <= s[0].ev) return s[0].strength
            if (ev >= s[s.length - 1].ev) return s[s.length - 1].strength
            for (var i = 0; i < s.length - 1; ++i)
                if (s[i].ev <= ev && ev <= s[i + 1].ev) {
                    var t = (ev - s[i].ev) / Math.max(s[i + 1].ev - s[i].ev, 1e-9)
                    return s[i].strength + t * (s[i + 1].strength - s[i].strength)
                }
            return 0
        }
        function dashedLine(ctx, x, y0, y1) {
            ctx.beginPath()
            for (var y = y0; y < y1; y += 3.5) {
                ctx.moveTo(x, y)
                ctx.lineTo(x, Math.min(y + 2, y1))
            }
            ctx.stroke()
        }

        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var r = reading
            if (!r || r.available !== true || width <= 0) return
            var w = width, plotH = plot.plotH
            var lo = r.axisFrom === undefined ? -8 : r.axisFrom, hi = r.axisTo === undefined ? 8 : r.axisTo
            function x(ev) { return (ev - lo) / (hi - lo) * w }
            var font = "600 " + Theme.fontMeta + "px \"" + Theme.fontFamily + "\""
            ctx.font = font
            ctx.textBaseline = "top"

            // The ground and the 2-stop grid; mid-grey brighter.
            ctx.fillStyle = Theme.plot
            ctx.beginPath(); ctx.roundedRect(0, 0, w, plotH, 2, 2); ctx.fill()
            ctx.lineWidth = 0.5
            for (var e = lo + 2; e < hi; e += 2) {
                ctx.strokeStyle = e === 0 ? Theme.plotMidGrey : Theme.plotGrid
                ctx.beginPath(); ctx.moveTo(x(e), 0); ctx.lineTo(x(e), plotH); ctx.stroke()
            }

            // The histogram: a step outline over the bins on the axis.
            var centres = r.centres || [], fractions = r.fractions || []
            var half = (r.binWidth || 0) / 2
            var top = 0
            for (var i = 0; i < centres.length; ++i)
                if (centres[i] >= lo && centres[i] <= hi) top = Math.max(top, Math.sqrt(fractions[i]))
            function fillPath() {
                ctx.beginPath()
                ctx.moveTo(x(lo), plotH)
                for (var k = 0; k < centres.length; ++k) {
                    var c = centres[k]
                    if (c < lo || c > hi) continue
                    var h = top > 0 ? (plotH - 4) * Math.sqrt(fractions[k]) / top : 0
                    ctx.lineTo(x(c - half), plotH - h)
                    ctx.lineTo(x(c + half), plotH - h)
                }
                ctx.lineTo(x(hi), plotH)
                ctx.closePath()
            }
            // The edge only where there are pixels, so an empty floor carries
            // no line -- and no accent.
            function edgePath() {
                ctx.beginPath()
                var open = false
                for (var k = 0; k < centres.length; ++k) {
                    var c = centres[k]
                    if (c < lo || c > hi) continue
                    var f = fractions[k]
                    var h = top > 0 ? (plotH - 4) * Math.sqrt(f) / top : 0
                    if (f > 1e-5) {
                        if (!open) { ctx.moveTo(x(c - half), plotH); open = true }
                        ctx.lineTo(x(c - half), plotH - h)
                        ctx.lineTo(x(c + half), plotH - h)
                    } else if (open) {
                        ctx.lineTo(x(c - half), plotH); open = false
                    }
                }
            }
            var sx = x(r.shadowEv), hx = x(r.highlightEv)
            var regions = [[0, Math.max(sx, 0), false], [sx, Math.max(hx - sx, 0), true], [hx, Math.max(w - hx, 0), false]]
            ctx.lineJoin = "round"
            for (var g = 0; g < regions.length; ++g) {
                var inside = regions[g][2]
                ctx.save()
                ctx.beginPath(); ctx.rect(regions[g][0], 0, regions[g][1], plotH); ctx.clip()
                fillPath()
                ctx.fillStyle = inside ? ink(Theme.latitudeInside, 0.8) : Theme.latitudeBeyond
                ctx.fill()
                edgePath()
                ctx.lineWidth = 1
                ctx.strokeStyle = inside ? Theme.latitudeInsideEdge : Theme.accent
                ctx.stroke()
                ctx.restore()
            }
            // Pixels past the axis's ends: a small triangle at that end.
            ctx.fillStyle = Theme.accent
            if ((r.under || 0) > 0.0005) {
                ctx.beginPath(); ctx.moveTo(2, 3); ctx.lineTo(7, 3); ctx.lineTo(2, 8); ctx.closePath(); ctx.fill()
            }
            if ((r.over || 0) > 0.0005) {
                ctx.beginPath(); ctx.moveTo(w - 2, 3); ctx.lineTo(w - 7, 3); ctx.lineTo(w - 2, 8); ctx.closePath(); ctx.fill()
            }

            // The separation band: its opacity at each stop is the measured
            // lightness change there, over its peak.
            var bandY = plotH + plot.bandGap, bandH = plot.bandH
            ctx.fillStyle = Theme.plot
            ctx.beginPath(); ctx.roundedRect(0, bandY, w, bandH, bandH / 2, bandH / 2); ctx.fill()
            var grad = ctx.createLinearGradient(0, bandY, w, bandY)
            for (var ev = lo; ev <= hi + 1e-9; ev += 0.25)
                grad.addColorStop((ev - lo) / (hi - lo), ink(Theme.text, 0.9 * strength(ev, r.separation)))
            ctx.fillStyle = grad
            ctx.beginPath(); ctx.roundedRect(0, bandY, w, bandH, bandH / 2, bandH / 2); ctx.fill()

            // The ISO 6846 boundaries, through plot and band, labelled at the
            // top: outside the line unless that would run past the plot's
            // edge, then inside it.
            ctx.lineWidth = 0.75
            ctx.strokeStyle = ink(Theme.secondaryText, 0.8)
            var bounds = [[r.shadowEv, true], [r.highlightEv, false]]
            for (var b = 0; b < bounds.length; ++b) {
                var bx = x(bounds[b][0]), leading = bounds[b][1]
                dashedLine(ctx, bx, 1, bandY + bandH)
                var label = section.stops(bounds[b][0])
                var lw = ctx.measureText(label).width
                var outside = leading ? bx - 3 - lw >= 2 : bx + 3 + lw <= w - 2
                var before = leading === outside
                ctx.fillStyle = Theme.secondaryText
                ctx.fillText(label, before ? bx - 3 - lw : bx + 3, 2)
            }

            // The axis: stops from the metered mid-grey.
            ctx.fillStyle = Theme.dim
            for (var a = lo; a <= hi + 1e-9; a += 2) {
                var t = a === 0 ? "0" : (a > 0 ? "+" : "−") + Math.abs(a)
                var tw = ctx.measureText(t).width
                var tx = a === lo ? x(a) : a === hi ? x(a) - tw : x(a) - tw / 2
                ctx.fillText(t, tx, bandY + bandH + 3)
            }
        }
    }
    // Below / Within / Above, each label and value as one run; a share
    // outside the window in the accent once it is half a percent.
    RowLayout {
        visible: section.shown
        Layout.fillWidth: true
        Layout.topMargin: Theme.rowSpacing - 5
        opacity: plot.opacity
        spacing: 4
        Repeater {
            model: [[L10n.tr("latitude.below"), "below", true], [L10n.tr("latitude.within"), "within", false],
                    [L10n.tr("latitude.above"), "above", true]]
            RowLayout {
                Layout.fillWidth: true
                spacing: 3
                Item { Layout.fillWidth: index > 0; implicitWidth: 0 }
                Text {
                    text: modelData[0]
                    color: Theme.dim
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
                }
                Text {
                    objectName: "latitude_" + modelData[1]
                    readonly property real share: Number(section.lat[modelData[1]] || 0)
                    text: (share * 100).toFixed(1) + " %"
                    color: modelData[2] && share >= 0.005 ? Theme.accent : Theme.text
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall; font.weight: Theme.weightTitle
                }
                Item { Layout.fillWidth: index < 2; implicitWidth: 0 }
            }
        }
    }
    Text {
        objectName: "latitudeSummary"
        visible: section.shown
        Layout.fillWidth: true
        opacity: plot.opacity
        text: section.shown ? section.summary() : ""
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        color: Theme.dim
        font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
    }
    // Nothing measured: why, in the engine's words when it refused.
    Text {
        objectName: "latitudeEmpty"
        visible: !section.shown
        Layout.fillWidth: true
        Layout.minimumHeight: 60
        text: section.emptyText()
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        wrapMode: Text.WordWrap
        color: Theme.dim
        font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
    }
}
