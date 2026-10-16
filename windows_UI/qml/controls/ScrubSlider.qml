import QtQuick
import QtQuick.Layouts

// The one slider (ScrubSlider.swift): label | thin track with a dot knob |
// boxed value, on a ParamRow, so it takes the row's label column, second
// line and disabled rule.
//
// The track: press anywhere -- far from the knob it jumps there, near it the
// drag is relative -- and drag; Ctrl or Alt for x0.25, Shift snaps to
// `snap`. Double-click returns to `defaultValue`. A tick marks the default
// when it is not at an end. The value box scrubs, types, takes the wheel and
// resets too (ValueBox.qml).
//
//   value, from, to       the model's number (bind it; this never writes it)
//   defaultValue          double-click target and the tick
//   step                  the box's wheel and scrub quantum
//   snap                  Shift-drag quantum (0: none)
//   decimals, signed, suffix   the default format: "+0.25", "4.0 EV", "3 %"
//   format(v), parse(t)   override the display and the typed-text parser
//   gradient              track colours left to right (the Mac's white
//                         balance and filter tracks); empty: plain ground
//   gestureKey            when set, every drag, scrub or wheel burst is one
//                         undo step: preview.beginEditGesture(key) ...
//                         preview.endEditGesture()
//   live                  true: moved() streams while dragging. false: the
//                         drag shows the number only and moved() fires once on
//                         release (straightening re-samples the source, so it
//                         commits on release)
//   moved(value)          the user's new value -- write it to the model
//   committed(value)      the end of an interaction (release, typed, reset)
//   + ParamRow's label, sublabel, secondLine, labelWidth, available, reason,
//     toolTip, bodyObjectName
ParamRow {
    id: slider
    property real value: 0
    property real from: 0
    property real to: 1
    property real defaultValue: 0
    property real step: (to - from) / 100
    property real snap: 0
    property int decimals: 2
    property bool signed: false
    property string suffix: ""
    property var format: function(v) {
        // "+0.00" for a signed zero, as the Mac's "%+.2f" prints it, and
        // never "-0.00" for a value that rounds to zero.
        var s = v.toFixed(slider.decimals)
        if (Number(s) === 0) s = (0).toFixed(slider.decimals)
        if (slider.signed && Number(s) >= 0) s = "+" + s
        return s + slider.suffix
    }
    property var parse: null
    property var gradient: []
    property string gestureKey
    property bool live: true
    // A track drag, or a scrub / wheel burst on the value box.
    readonly property bool dragging: trackArea.pressed || boxEditing
    property bool boxEditing: false
    // What the row shows: the model, or the number under the pointer while a
    // non-live drag is in progress.
    readonly property real shownValue: dragging && !live ? pendingValue : value
    property real pendingValue: value
    signal moved(real value)
    signal committed(real value)

    function clamp(v) { return Math.max(Math.min(from, to), Math.min(Math.max(from, to), v)) }
    function fraction(v) { return to === from ? 0 : Math.max(0, Math.min(1, (v - from) / (to - from))) }
    function beginGesture() { if (gestureKey.length > 0) preview.beginEditGesture(gestureKey) }
    function endGesture() { if (gestureKey.length > 0) preview.endEditGesture() }
    function apply(v) {
        v = clamp(v)
        pendingValue = v
        if (live) moved(v)
    }
    function resetToDefault() {
        beginGesture()
        moved(clamp(defaultValue))
        committed(clamp(defaultValue))
        endGesture()
    }

    RowLayout {
        anchors.fill: parent
        spacing: Theme.valueGap
        Item {
            id: track
            Layout.fillWidth: true
            Layout.fillHeight: true
            readonly property real usable: width - Theme.knobWidth
            Rectangle {
                id: groove
                x: Theme.knobWidth / 2; width: track.usable
                anchors.verticalCenter: parent.verticalCenter
                height: Theme.trackHeight; radius: height / 2
                color: slider.gradient.length > 0 ? "transparent" : Theme.ground
                gradient: slider.gradient.length > 0 ? trackGradient : null
                Gradient {
                    id: trackGradient
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: slider.gradient.length > 0 ? slider.gradient[0] : Theme.ground }
                    GradientStop { position: 0.5; color: slider.gradient.length > 2 ? slider.gradient[1] : slider.gradient.length > 0 ? slider.gradient[0] : Theme.ground }
                    GradientStop { position: 1; color: slider.gradient.length > 0 ? slider.gradient[slider.gradient.length - 1] : Theme.ground }
                }
            }
            // The default's tick, unless it is at an end or under the knob.
            Rectangle {
                readonly property real f: slider.fraction(slider.defaultValue)
                visible: f > 0.001 && f < 0.999 && Math.abs(f - slider.fraction(slider.shownValue)) > 0.02
                x: Theme.knobWidth / 2 + f * track.usable - 0.5
                anchors.verticalCenter: parent.verticalCenter
                width: 1; height: 6
                color: Theme.text; opacity: 0.55
            }
            Rectangle {
                id: knob
                x: slider.fraction(slider.shownValue) * track.usable
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.knobWidth; height: Theme.knobHeight
                radius: Theme.knobHeight / 2
                color: Theme.knob
            }
            MouseArea {
                id: trackArea
                anchors.fill: parent
                property real dragStart: 0
                property real pressX: 0
                // Set by the second press of a double-click: the value has
                // gone to the default and the rest of that press is ignored.
                property bool resetting: false
                onPressed: function(mouse) {
                    slider.beginGesture()
                    resetting = false
                    pressX = mouse.x
                    var target = slider.from + Math.max(0, Math.min(1, (mouse.x - Theme.knobWidth / 2) / Math.max(1, track.usable))) * (slider.to - slider.from)
                    dragStart = Math.abs(target - slider.value) > Math.abs(slider.to - slider.from) * 0.03 ? target : slider.value
                    slider.pendingValue = slider.value
                    if (dragStart !== slider.value) slider.apply(dragStart)
                }
                onPositionChanged: function(mouse) {
                    if (resetting) return
                    var gain = (mouse.modifiers & (Qt.ControlModifier | Qt.AltModifier)) ? 0.25 : 1
                    var v = dragStart + (mouse.x - pressX) / Math.max(1, track.usable) * (slider.to - slider.from) * gain
                    if ((mouse.modifiers & Qt.ShiftModifier) && slider.snap > 0) v = Math.round(v / slider.snap) * slider.snap
                    slider.apply(v)
                }
                onReleased: {
                    if (!slider.live) slider.moved(slider.pendingValue)
                    slider.committed(slider.live ? slider.value : slider.pendingValue)
                    slider.endGesture()
                }
                onCanceled: slider.endGesture()
                // Inside the second press's gesture, so the reset is the same
                // undo step and the release commits it like any drag.
                onDoubleClicked: { resetting = true; slider.apply(slider.defaultValue) }
            }
        }
        ValueBox {
            Layout.preferredWidth: Theme.valueWidth
            Layout.alignment: Qt.AlignVCenter
            value: slider.shownValue
            from: slider.from; to: slider.to
            step: slider.step
            text: slider.format(slider.shownValue)
            parse: slider.parse
            onEditStarted: { slider.pendingValue = slider.value; slider.boxEditing = true; slider.beginGesture() }
            onEdited: function(v) { slider.apply(v) }
            onEditFinished: {
                slider.boxEditing = false
                if (!slider.live) slider.moved(slider.pendingValue)
                slider.committed(slider.live ? slider.value : slider.pendingValue)
                slider.endGesture()
            }
            onTyped: function(v) { slider.moved(v); slider.committed(v) }
            onResetRequested: slider.resetToDefault()
        }
    }
}
