import QtQuick

// HistogramView.swift `HistogramPlot`, as the canvas draws it (no grid, no
// ground): 4 x 256 normalised bins -- R, G, B, luma -- as closed curves, the
// luma filled grey under the three channels, each channel a faint fill with a
// near-opaque line. y = h - v * 0.96 h, x = w * i / 255. The bins come from
// the controller (FrameImage.hpp histogram); this only draws them.
Canvas {
    id: plot
    property var bins: []
    property real lineWidth: 1
    onBinsChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    function curve(ctx, row) {
        var w = width, h = height
        ctx.beginPath()
        ctx.moveTo(0, h)
        for (var i = 0; i < 256; ++i)
            ctx.lineTo(w * i / 255, h - bins[row * 256 + i] * h * 0.96)
        ctx.lineTo(w, h)
        ctx.closePath()
    }
    onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        if (!bins || bins.length < 1024) return
        ctx.lineWidth = lineWidth
        ctx.lineJoin = "round"
        // Theme.histY / histR / histG / histB at the Mac's opacities.
        curve(ctx, 3)
        ctx.fillStyle = Qt.rgba(0.741, 0.741, 0.741, 0.30); ctx.fill()
        ctx.strokeStyle = Qt.rgba(0.741, 0.741, 0.741, 0.70); ctx.stroke()
        var inks = [[0.910, 0.322, 0.306], [0.384, 0.769, 0.384], [0.365, 0.490, 0.910]]
        for (var row = 0; row < 3; ++row) {
            var c = inks[row]
            curve(ctx, row)
            ctx.fillStyle = Qt.rgba(c[0], c[1], c[2], 0.12); ctx.fill()
            ctx.strokeStyle = Qt.rgba(c[0], c[1], c[2], 0.95); ctx.stroke()
        }
    }
}
