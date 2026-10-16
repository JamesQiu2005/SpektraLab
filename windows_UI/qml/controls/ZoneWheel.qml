import QtQuick
import QtQuick.Layouts

// One colour-balance zone (ColorWheel.swift ZoneWheel): a hue disc with a
// draggable point -- angle the hue, distance the saturation -- and two arc
// sliders concentric with it outside the rim, saturation on the left
// (bottom 245 deg to top 115 deg) and luminance on the right (-65 to 65), the
// top of each arc the top of its range. The ring's gap, weight, thumb and hit
// band are proportions of the wheel (ColorBalanceLayout); the arithmetic is
// the model's, through the controller (postdev::wheel).
//
// The disc is drawn so a colour's place on it is the hue the point there
// adds (0 = red to the right, 120 = green up-left, 240 = blue down-left),
// the arithmetic's own orientation.
//
// A drag on the disc is one undo step ("postDev.colorBalance.<zone>"), a drag
// on an arc another; a double-click returns the disc's zone, or the arc's
// value, to neutral.
ColumnLayout {
    id: zoneWheel
    required property string zone      // "master", "shadows", "midtones", "highlights"
    property real wheel: 100
    property string label
    property bool labelFirst: false
    readonly property bool available: preview.settingsEditable && preview.hasFrame
    readonly property var value: {
        var cb = preview.postDev.colorBalance
        return cb && cb[zone] ? cb[zone] : { hue: 0, saturation: 0, luminance: 0 }
    }
    // ColorBalanceLayout's ring.
    readonly property real gap: Math.max(4.5, Math.min(10, wheel * 0.09))
    readonly property real thumb: Math.max(3, Math.min(5, wheel * 0.05))
    readonly property real arcWeight: 3
    readonly property real hitWidth: Math.min(16, 2 * gap - 1.5)
    readonly property real band: wheel + 2 * (gap + thumb + 1)
    spacing: 4
    Layout.fillWidth: true

    Text {
        visible: zoneWheel.labelFirst && zoneWheel.label.length > 0
        Layout.alignment: Qt.AlignHCenter
        text: zoneWheel.label
        color: Theme.dim
        font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
    }
    Item {
        id: square
        objectName: "zoneWheel_" + zoneWheel.zone
        Layout.alignment: Qt.AlignHCenter
        implicitWidth: zoneWheel.band; implicitHeight: zoneWheel.band
        opacity: zoneWheel.available ? 1 : Theme.disabledOpacity
        readonly property real cx: width / 2
        readonly property real cy: height / 2
        readonly property real radius: zoneWheel.wheel / 2 + zoneWheel.gap

        Canvas {
            id: art
            anchors.fill: parent
            property var value: zoneWheel.value
            property real wheel: zoneWheel.wheel
            onValueChanged: requestPaint()
            onWheelChanged: requestPaint()
            onWidthChanged: requestPaint()
            function mix(a, b, t) {
                return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
            }
            function trackColour(stops, t) {
                var x = Math.max(0, Math.min(1, t)) * (stops.length - 1)
                var i = Math.min(Math.floor(x), stops.length - 2)
                return mix(stops[i], stops[i + 1], x - i)
            }
            function point(theta, r) {
                var a = theta * Math.PI / 180
                return [square.cx + r * Math.cos(a), square.cy - r * Math.sin(a)]
            }
            function drawArc(ctx, left, fraction, stops) {
                var r = square.radius
                ctx.lineWidth = zoneWheel.arcWeight
                ctx.lineCap = "round"
                var segments = 24
                for (var i = 0; i < segments; ++i) {
                    var a = point(preview.arcTheta(i / segments, left), r)
                    var b = point(preview.arcTheta((i + 1) / segments, left), r)
                    ctx.strokeStyle = trackColour(stops, (i + 1) / segments)
                    ctx.beginPath(); ctx.moveTo(a[0], a[1]); ctx.lineTo(b[0], b[1]); ctx.stroke()
                }
                // The thumb: a tick across the track, dark under light.
                var theta = preview.arcTheta(fraction, left)
                var p = point(theta, r - zoneWheel.thumb), q = point(theta, r + zoneWheel.thumb)
                ctx.strokeStyle = Theme.card; ctx.lineWidth = zoneWheel.arcWeight + 1.6
                ctx.beginPath(); ctx.moveTo(p[0], p[1]); ctx.lineTo(q[0], q[1]); ctx.stroke()
                ctx.strokeStyle = Theme.knob; ctx.lineWidth = zoneWheel.arcWeight - 0.4
                ctx.beginPath(); ctx.moveTo(p[0], p[1]); ctx.lineTo(q[0], q[1]); ctx.stroke()
            }
            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var v = value, cx = square.cx, cy = square.cy, R = wheel / 2
                // The disc: 72 wedges, the hue at each wedge's middle angle.
                for (var k = 0; k < 72; ++k) {
                    var a0 = k * 5, a1 = (k + 1) * 5
                    ctx.beginPath()
                    ctx.moveTo(cx, cy)
                    // Canvas angles run clockwise on screen; hue runs anticlockwise.
                    ctx.arc(cx, cy, R, -a1 * Math.PI / 180 - 0.012, -a0 * Math.PI / 180 + 0.012, false)
                    ctx.closePath()
                    var hue = (k * 5 + 2.5) / 360
                    ctx.fillStyle = Qt.hsva(hue, 0.6, hue > 0.25 && hue < 0.42 ? 0.85 : hue > 0.58 && hue < 0.75 ? 0.95 : 0.9, 1)
                    ctx.fill()
                }
                // Fading to the rail at the centre, as the Mac's radial overlay.
                var fade = ctx.createRadialGradient(cx, cy, 0, cx, cy, R)
                fade.addColorStop(0, Theme.card)
                fade.addColorStop(1, Qt.rgba(Theme.card.r, Theme.card.g, Theme.card.b, 0))
                ctx.fillStyle = fade
                ctx.beginPath(); ctx.arc(cx, cy, R, 0, 2 * Math.PI, false); ctx.fill()
                ctx.strokeStyle = Qt.rgba(0.537, 0.537, 0.537, 0.6); ctx.lineWidth = 0.5
                ctx.beginPath(); ctx.arc(cx, cy, R, 0, 2 * Math.PI, false); ctx.stroke()
                // The point.
                var p = preview.wheelPoint(v.hue, v.saturation, wheel)
                var px = cx - R + p.x, py = cy - R + p.y
                ctx.fillStyle = Theme.text
                ctx.beginPath(); ctx.arc(px, py, 3.5, 0, 2 * Math.PI, false); ctx.fill()
                ctx.strokeStyle = Theme.card; ctx.lineWidth = 1; ctx.stroke()
                // The two arcs.
                drawArc(ctx, true, preview.arcFraction(v.saturation, 0, 1),
                        [Theme.dim, Qt.hsva(v.hue / 360, 0.85, 0.95, 1)])
                drawArc(ctx, false, preview.arcFraction(v.luminance, -1, 1),
                        [Qt.rgba(0, 0, 0, 0.6), Theme.dim, Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.9)])
            }
        }
        MouseArea {
            anchors.fill: parent
            enabled: zoneWheel.available
            preventStealing: true
            // "disc", "saturation", "luminance", or "" for a press on nothing.
            property string target: ""
            function hit(x, y) {
                var dx = x - square.cx, dy = square.cy - y
                var r = Math.sqrt(dx * dx + dy * dy)
                if (r <= zoneWheel.wheel / 2) return "disc"
                // The arc itself is the hit region (ColorWheel.swift ArcHit):
                // its stroke, not the square, so it never takes the disc's drag.
                if (Math.abs(r - square.radius) > zoneWheel.hitWidth / 2) return ""
                var theta = Math.atan2(dy, dx) * 180 / Math.PI
                if (theta >= -65 && theta <= 65) return "luminance"
                var t = theta < 0 ? theta + 360 : theta
                if (t >= 115 && t <= 245) return "saturation"
                return ""
            }
            function apply(x, y) {
                if (target === "disc") {
                    var z = preview.wheelZoneAt(x - (square.width - zoneWheel.wheel) / 2, y - (square.height - zoneWheel.wheel) / 2, zoneWheel.wheel)
                    preview.setColorZone(zoneWheel.zone, z.hue, z.saturation)
                } else if (target === "saturation") {
                    preview.setPostDev("colorBalance." + zoneWheel.zone + ".saturation", preview.arcValue(x, y, square.cx, square.cy, true, 0, 1))
                } else if (target === "luminance") {
                    preview.setPostDev("colorBalance." + zoneWheel.zone + ".luminance", preview.arcValue(x, y, square.cx, square.cy, false, -1, 1))
                }
            }
            function key() {
                return "postDev.colorBalance." + zoneWheel.zone + (target === "disc" ? "" : "." + target)
            }
            onPressed: function(mouse) {
                target = hit(mouse.x, mouse.y)
                if (target === "") { mouse.accepted = false; return }
                preview.beginEditGesture(key())
                apply(mouse.x, mouse.y)
            }
            onPositionChanged: function(mouse) { if (pressed && target !== "") apply(mouse.x, mouse.y) }
            onReleased: { if (target !== "") preview.endEditGesture(); target = "" }
            onCanceled: { if (target !== "") preview.endEditGesture(); target = "" }
            onDoubleClicked: function(mouse) {
                var t = hit(mouse.x, mouse.y)
                if (t === "disc") preview.resetColorZone(zoneWheel.zone)
                else if (t === "saturation") preview.setPostDev("colorBalance." + zoneWheel.zone + ".saturation", 0)
                else if (t === "luminance") preview.setPostDev("colorBalance." + zoneWheel.zone + ".luminance", 0)
            }
        }
    }
    Text {
        visible: !zoneWheel.labelFirst && zoneWheel.label.length > 0
        Layout.alignment: Qt.AlignHCenter
        text: zoneWheel.label
        color: Theme.dim
        font.family: Theme.fontFamily; font.pixelSize: Theme.fontMeta; font.weight: Theme.weightText
    }
}
