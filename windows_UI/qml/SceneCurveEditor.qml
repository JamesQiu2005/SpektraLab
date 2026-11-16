import QtQuick

Item {
    id: editor

    property string curveText: ""
    property int channelIndex: 0
    property var rows: identityRows()
    property int activePoint: -1
    signal editStarted()
    signal curveEdited(string value)

    implicitHeight: 230

    function identityPoints() {
        return [
            { x: 0, y: 0 }, { x: 0.125, y: 0.125 }, { x: 0.25, y: 0.25 },
            { x: 0.375, y: 0.375 }, { x: 0.5, y: 0.5 }, { x: 0.625, y: 0.625 },
            { x: 0.75, y: 0.75 }, { x: 0.875, y: 0.875 }, { x: 1, y: 1 }
        ]
    }
    function identityRows() { return [identityPoints(), identityPoints(), identityPoints(), identityPoints(), identityPoints()] }
    function cloneRows(source) {
        var copy = []
        for (var row = 0; row < 5; ++row) {
            var points = []
            for (var i = 0; i < source[row].length; ++i)
                points.push({ x: Number(source[row][i].x), y: Number(source[row][i].y) })
            copy.push(points)
        }
        return copy
    }
    function sample(points, x) {
        for (var i = 1; i < points.length; ++i) {
            if (x <= points[i].x) {
                var a = points[i - 1], b = points[i]
                var span = Math.max(1e-9, b.x - a.x)
                return a.y + (b.y - a.y) * (x - a.x) / span
            }
        }
        return points[points.length - 1].y
    }
    function serialise() {
        var result = []
        for (var row = 0; row < 5; ++row) {
            var values = []
            for (var i = 0; i < 129; ++i)
                values.push(Math.max(0, Math.min(1, sample(rows[row], i / 128))).toFixed(6))
            result.push(values.join(","))
        }
        return result.join(",")
    }
    function loadWire(text) {
        if (!text) {
            rows = identityRows()
            return
        }
        var values = text.split(",").map(Number)
        if (values.length % 5 !== 0 || values.length / 5 < 2)
            return
        var count = values.length / 5
        var loaded = []
        for (var row = 0; row < 5; ++row) {
            var points = []
            for (var slot = 0; slot < 9; ++slot) {
                var x = slot / 8, position = x * (count - 1)
                var low = Math.min(count - 2, Math.floor(position))
                var fraction = position - low
                var y = values[row * count + low] * (1 - fraction) + values[row * count + low + 1] * fraction
                points.push({ x: x, y: y })
            }
            loaded.push(points)
        }
        rows = loaded
    }
    function pointAt(px, py) {
        var points = rows[channelIndex], nearest = -1, distance = 14
        for (var i = 0; i < points.length; ++i) {
            var x = plot.left + points[i].x * plot.width
            var y = plot.top + (1 - points[i].y) * plot.height
            var d = Math.hypot(px - x, py - y)
            if (d < distance) { distance = d; nearest = i }
        }
        return nearest
    }
    function updateActive(mouseX, mouseY) {
        if (activePoint < 0) return
        var copy = cloneRows(rows)
        var points = copy[channelIndex]
        var y = Math.max(0, Math.min(1, 1 - (mouseY - plot.top) / plot.height))
        var x = Math.max(0, Math.min(1, (mouseX - plot.left) / plot.width))
        if (activePoint > 0 && activePoint < points.length - 1) {
            points[activePoint].x = Math.max(points[activePoint - 1].x + 0.001,
                                             Math.min(points[activePoint + 1].x - 0.001, x))
        }
        points[activePoint].y = y
        rows = copy
    }
    function commit() {
        if (activePoint < 0) return
        activePoint = -1
        editor.curveEdited(serialise())
    }

    onCurveTextChanged: {
        if (curveText !== serialise()) loadWire(curveText)
    }
    onChannelIndexChanged: activePoint = -1

    Canvas {
        id: plot
        anchors.fill: parent
        anchors.margins: 8
        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            ctx.fillStyle = Theme.well
            ctx.fillRect(0, 0, width, height)
            ctx.strokeStyle = Theme.line
            ctx.lineWidth = 1
            for (var grid = 0; grid <= 8; ++grid) {
                var gx = grid * width / 8, gy = grid * height / 8
                ctx.beginPath(); ctx.moveTo(gx, 0); ctx.lineTo(gx, height); ctx.stroke()
                ctx.beginPath(); ctx.moveTo(0, gy); ctx.lineTo(width, gy); ctx.stroke()
            }
            var colors = ["#e6c768", "#d9d9d9", "#d9584b", "#5dbb6a", "#4a73d8"]
            var points = editor.rows[editor.channelIndex]
            ctx.strokeStyle = colors[editor.channelIndex]
            ctx.lineWidth = 2
            ctx.beginPath()
            for (var i = 0; i < points.length; ++i) {
                var x = points[i].x * width, y = (1 - points[i].y) * height
                if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
            }
            ctx.stroke()
            for (var j = 0; j < points.length; ++j) {
                var px = points[j].x * width, py = (1 - points[j].y) * height
                ctx.fillStyle = j === editor.activePoint ? colors[editor.channelIndex] : Theme.well
                ctx.strokeStyle = colors[editor.channelIndex]
                ctx.lineWidth = 2
                ctx.fillRect(px - 4, py - 4, 8, 8)
                ctx.strokeRect(px - 4, py - 4, 8, 8)
            }
        }
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onPressed: function(mouse) {
                var hit = editor.pointAt(mouse.x, mouse.y)
                if (mouse.button === Qt.RightButton) {
                    if (hit > 0 && hit < editor.rows[editor.channelIndex].length - 1) {
                        editor.editStarted()
                        var copy = editor.cloneRows(editor.rows)
                        copy[editor.channelIndex].splice(hit, 1)
                        editor.rows = copy
                        editor.curveEdited(editor.serialise())
                    }
                    return
                }
                editor.editStarted()
                editor.activePoint = hit
                if (hit < 0) {
                    var next = editor.cloneRows(editor.rows)
                    var points = next[editor.channelIndex]
                    var added = { x: Math.max(0.001, Math.min(0.999, mouse.x / width)),
                                  y: Math.max(0, Math.min(1, 1 - mouse.y / height)) }
                    points.push(added)
                    points.sort(function(a, b) { return a.x - b.x })
                    editor.rows = next
                    editor.activePoint = points.indexOf(added)
                }
                editor.updateActive(mouse.x, mouse.y)
            }
            onPositionChanged: function(mouse) {
                if (pressed && mouse.buttons & Qt.LeftButton) editor.updateActive(mouse.x, mouse.y)
            }
            onReleased: editor.commit()
        }
    }
    Connections {
        target: editor
        function onRowsChanged() { plot.requestPaint() }
        function onActivePointChanged() { plot.requestPaint() }
    }
}
