import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Capture One's curve tool (CurveEditor.swift): the five channel tabs, the
// histogram behind the curve, draggable points, the input/output readout.
// The arithmetic is the model's (postdev::Curve through the controller):
// hit-testing in the unit square with the Mac's 10 px tolerance, insert,
// move (the ends keep x, interior points keep 0.01 from their neighbours),
// remove; the curve drawn is Curve.evaluate at 129 places.
//
// Interaction, the Mac's: a press on the curve away from a point adds one; a
// drag moves it; a drag well outside the plot (0.2 beyond an edge) removes an
// interior point; a right-click on a point opens a menu that deletes it
// (greyed for the two ends); a double-click resets the channel. A press to
// release is one undo step ("postDev.curves.<channel>").
ColumnLayout {
    id: editor
    property string channel: "rgb"
    readonly property var channels: ["rgb", "luma", "red", "green", "blue"]
    readonly property bool available: preview.settingsEditable && preview.hasFrame
    // The points, for the plot (preview.postDev's own lists).
    readonly property var points: {
        var c = preview.postDev.curves
        return c && c[channel] ? c[channel].points : [[0, 0], [1, 1]]
    }
    readonly property var samples: { preview.postDev; return preview.curveSamples(channel, 129) }
    property int dragging: -1
    property real hoverX: -1
    spacing: 6
    Layout.fillWidth: true

    function title(ch) {
        return ch === "rgb" ? L10n.tr("postDev.curve.rgb") : ch === "luma" ? L10n.tr("postDev.curve.luma")
            : ch === "red" ? L10n.tr("postDev.curve.red") : ch === "green" ? L10n.tr("postDev.curve.green") : L10n.tr("postDev.curve.blue")
    }
    function ink(ch) {
        return ch === "red" ? Theme.histR : ch === "green" ? Theme.histG : ch === "blue" ? Theme.histB : Theme.text
    }

    // Tabs: only the active one underlined, in the accent.
    RowLayout {
        Layout.fillWidth: true
        spacing: 0
        Repeater {
            model: editor.channels
            delegate: Item {
                required property string modelData
                readonly property bool on: modelData === editor.channel
                Layout.fillWidth: true
                implicitHeight: 20
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 1
                    text: editor.title(parent.modelData)
                    color: parent.on ? Theme.accent : Theme.secondaryText
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall; font.weight: Theme.weightText
                }
                Rectangle {
                    anchors.bottom: parent.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: parent.width - 6; height: 1.5
                    color: parent.on ? Theme.accent : "transparent"
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: editor.channel = parent.modelData
                }
            }
        }
    }

    Item {
        id: plotArea
        objectName: "curvePlot"
        Layout.fillWidth: true
        // CurveEditor.swift: aspectRatio(1.05, .fit).
        Layout.preferredHeight: Math.round(width / 1.05)
        opacity: editor.available ? 1 : Theme.disabledOpacity
        Rectangle { anchors.fill: parent; color: Theme.plot; radius: 2 }
        // The grid behind the histogram (HistogramPlot showGrid: quarters).
        Repeater {
            model: 3
            delegate: Item {
                required property int index
                anchors.fill: parent
                Rectangle { x: Math.round(plotArea.width * (parent.index + 1) / 4); width: 1; height: plotArea.height; color: Theme.plotGrid }
                Rectangle { y: Math.round(plotArea.height * (parent.index + 1) / 4); height: 1; width: plotArea.width; color: Theme.plotGrid }
            }
        }
        HistogramPlot {
            anchors.fill: parent
            bins: preview.histogram
            opacity: 0.55
        }
        Canvas {
            id: curveCanvas
            anchors.fill: parent
            property var points: editor.points
            property var samples: editor.samples
            property int dragging: editor.dragging
            property real hoverX: editor.hoverX
            property color ink: editor.ink(editor.channel)
            onPointsChanged: requestPaint()
            onSamplesChanged: requestPaint()
            onDraggingChanged: requestPaint()
            onHoverXChanged: requestPaint()
            onInkChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var w = width, h = height
                // The diagonal reference.
                ctx.strokeStyle = Qt.rgba(0.537, 0.537, 0.537, 0.6)
                ctx.lineWidth = 0.5
                ctx.beginPath(); ctx.moveTo(0, h); ctx.lineTo(w, 0); ctx.stroke()
                // The curve.
                if (samples && samples.length > 1) {
                    ctx.strokeStyle = ink
                    ctx.lineWidth = 1.5
                    ctx.beginPath()
                    for (var i = 0; i < samples.length; ++i) {
                        var x = i / (samples.length - 1) * w, y = (1 - samples[i]) * h
                        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
                    }
                    ctx.stroke()
                }
                // The points: plot-filled squares ringed in the accent.
                for (var k = 0; k < points.length; ++k) {
                    var r = k === dragging ? 4.5 : 3.5
                    var px = points[k][0] * w, py = (1 - points[k][1]) * h
                    ctx.fillStyle = Theme.plot
                    ctx.fillRect(px - r, py - r, 2 * r, 2 * r)
                    ctx.strokeStyle = Theme.accent
                    ctx.lineWidth = 1.2
                    ctx.strokeRect(px - r, py - r, 2 * r, 2 * r)
                }
                // The hover's input guide.
                if (hoverX >= 0) {
                    ctx.strokeStyle = Qt.rgba(0.976, 0.969, 0.953, 0.25)
                    ctx.lineWidth = 0.5
                    ctx.setLineDash([2, 2])
                    ctx.beginPath(); ctx.moveTo(hoverX * w, 0); ctx.lineTo(hoverX * w, h); ctx.stroke()
                }
            }
        }
        MouseArea {
            id: plotMouse
            anchors.fill: parent
            enabled: editor.available
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            preventStealing: true
            property var menuIndex: -1
            function unitX(x) { return x / Math.max(1, width) }
            function unitY(y) { return 1 - y / Math.max(1, height) }
            function clamp01(v) { return Math.max(0, Math.min(1, v)) }
            onPressed: function(mouse) {
                var ux = clamp01(unitX(mouse.x)), uy = clamp01(unitY(mouse.y))
                var near = preview.curvePointNear(editor.channel, ux, uy, width, height)
                if (mouse.button === Qt.RightButton) {
                    // No menu for empty plot: a right-click on nothing is not
                    // asking about a point.
                    if (near < 0) return
                    menuIndex = near
                    deleteItem.enabled = preview.curvePointDeletable(editor.channel, near)
                    pointMenu.popup()
                    return
                }
                preview.beginEditGesture("postDev.curves." + editor.channel)
                editor.dragging = near >= 0 ? near : preview.insertCurvePoint(editor.channel, ux, uy)
            }
            onPositionChanged: function(mouse) {
                editor.hoverX = clamp01(unitX(mouse.x))
                if (!pressed || editor.dragging < 0 || !(mouse.buttons & Qt.LeftButton)) return
                var ux = unitX(mouse.x), uy = unitY(mouse.y)
                var outside = ux < -0.2 || ux > 1.2 || uy < -0.2 || uy > 1.2
                if (outside && preview.curvePointDeletable(editor.channel, editor.dragging)) {
                    preview.removeCurvePoint(editor.channel, editor.dragging)
                    editor.dragging = -1
                } else preview.moveCurvePoint(editor.channel, editor.dragging, ux, uy)
            }
            onReleased: function(mouse) {
                if (mouse.button !== Qt.LeftButton) return
                editor.dragging = -1
                preview.endEditGesture()
            }
            onCanceled: { editor.dragging = -1; preview.endEditGesture() }
            onExited: editor.hoverX = -1
            onDoubleClicked: function(mouse) {
                if (mouse.button !== Qt.LeftButton) return
                preview.beginEditGesture("postDev.curves." + editor.channel)
                preview.resetCurve(editor.channel)
                preview.endEditGesture()
                editor.dragging = -1
            }
        }
        RailMenu {
            id: pointMenu
            RailMenuItem {
                id: deleteItem
                text: L10n.tr("postDev.curve.deletePoint")
                onTriggered: preview.removeCurvePoint(editor.channel, plotMouse.menuIndex)
            }
        }
    }

    // Input / output under the pointer, 0..255 as the Mac prints them.
    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: 6; Layout.rightMargin: 6
        spacing: 16
        readonly property string input: editor.hoverX >= 0 ? Math.round(editor.hoverX * 255).toString() : "--"
        readonly property string output: { preview.postDev; return editor.hoverX >= 0 ? Math.round(preview.curveValue(editor.channel, editor.hoverX) * 255).toString() : "--" }
        Text {
            text: L10n.tr("postDev.curve.input", [parent.input])
            color: Theme.secondaryText
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall; font.weight: Theme.weightText
        }
        Text {
            text: L10n.tr("postDev.curve.output", [parent.output])
            color: Theme.secondaryText
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall; font.weight: Theme.weightText
        }
        Item { Layout.fillWidth: true }
    }
}
