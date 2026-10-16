import QtQuick
import QtQuick.Controls

// The boxed number at the end of a slider row (the Mac's value pill, a
// ground-coloured rounded rectangle at r 4.25). It is a control of its own:
//
//   drag sideways     scrubs: the full range across ~300 px; Shift is coarse
//                     (x4), Ctrl or Alt fine (x0.25)
//   wheel             one `step` per notch; Shift x10, Ctrl x0.1. A burst of
//                     notches is one edit (finished 500 ms after the last)
//   click             types a value: Enter or leaving the box commits a
//                     number in range, Esc cancels; text that is not a number
//                     turns the box's edge red and is not committed
//   double-click      asks for the default (resetRequested)
//
//   value, from, to, step   the number and its range
//   text               what to show (the caller's formatter); typing starts
//                      from it
//   parse(text)        the caller's parser, returning NaN for nonsense; by
//                      default the first number in the text, "," as decimal
//   editStarted(), edited(value), editFinished()   a scrub or wheel burst:
//                      the caller opens and closes one undo gesture around it
//   typed(value)       a committed typed number (already clamped)
//   resetRequested()
Item {
    id: box
    property real value: 0
    property real from: 0
    property real to: 1
    property real step: 0.01
    property string text: value.toFixed(2)
    property var parse: null
    readonly property bool editing: editor.active
    signal editStarted()
    signal edited(real value)
    signal editFinished()
    signal typed(real value)
    signal resetRequested()

    implicitWidth: Theme.valueWidth; implicitHeight: Theme.controlHeight

    function clamp(v) { return Math.max(Math.min(from, to), Math.min(Math.max(from, to), v)) }
    function parseText(t) {
        if (typeof box.parse === "function") return box.parse(t)
        var m = String(t).replace(",", ".").match(/[-+]?\d*\.?\d+(e[-+]?\d+)?/i)
        return m ? parseFloat(m[0]) : NaN
    }
    function beginTyping() { editor.active = true }
    function endTyping(commit) {
        if (!editor.active || !editor.item || editor.closing) return
        var v = box.parseText(editor.item.text)
        // Unloaded after the key or focus handler that asked for it returns.
        editor.closing = true
        Qt.callLater(function() { editor.active = false; editor.closing = false })
        if (commit && isFinite(v)) box.typed(clamp(v))
    }

    Rectangle {
        anchors.fill: parent
        radius: Theme.fieldRadius
        color: Theme.pill
        border.width: editor.item ? 1 : 0
        border.color: editor.item && !isFinite(box.parseText(editor.item.text)) ? Theme.warning : Theme.accent
    }
    Text {
        anchors.fill: parent; anchors.leftMargin: 2; anchors.rightMargin: 2
        visible: !editor.active
        text: box.text
        color: Theme.text
        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall; font.weight: Theme.weightText
    }
    // The text field exists only while typing: a rail holds two dozen value
    // boxes, and none of them needs an editor until it is clicked.
    Loader {
        id: editor
        property bool closing: false
        anchors.fill: parent; anchors.leftMargin: 3; anchors.rightMargin: 3
        active: false
        onLoaded: { item.text = box.text; item.forceActiveFocus(); item.selectAll() }
        sourceComponent: TextInput {
            color: Theme.text
            selectionColor: Theme.accent
            selectedTextColor: Theme.selectionInk
            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
            clip: true
            selectByMouse: true
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall; font.weight: Theme.weightText
            Keys.onReturnPressed: box.endTyping(isFinite(box.parseText(text)))
            Keys.onEnterPressed: box.endTyping(isFinite(box.parseText(text)))
            Keys.onEscapePressed: box.endTyping(false)
            onActiveFocusChanged: if (!activeFocus) box.endTyping(true)
        }
    }
    MouseArea {
        anchors.fill: parent
        enabled: !editor.active
        cursorShape: Qt.SizeHorCursor
        property real pressX: 0
        property real startValue: 0
        property bool scrubbing: false
        onPressed: function(mouse) { pressX = mouse.x; startValue = box.value; scrubbing = false }
        onPositionChanged: function(mouse) {
            var dx = mouse.x - pressX
            if (!scrubbing) {
                if (Math.abs(dx) < 3) return
                scrubbing = true
                typingTimer.stop()
                box.editStarted()
            }
            var gain = (mouse.modifiers & Qt.ShiftModifier) ? 4 : (mouse.modifiers & (Qt.ControlModifier | Qt.AltModifier)) ? 0.25 : 1
            var v = startValue + dx / 300 * (box.to - box.from) * gain
            if (box.step > 0) v = Math.round(v / box.step) * box.step
            box.edited(box.clamp(v))
        }
        onReleased: {
            if (scrubbing) { scrubbing = false; box.editFinished() }
            else typingTimer.restart()
        }
        onCanceled: if (scrubbing) { scrubbing = false; box.editFinished() }
        onDoubleClicked: { typingTimer.stop(); box.resetRequested() }
        onWheel: function(wheel) {
            var notches = wheel.angleDelta.y / 120
            if (notches === 0) return
            var gain = (wheel.modifiers & Qt.ShiftModifier) ? 10 : (wheel.modifiers & Qt.ControlModifier) ? 0.1 : 1
            if (!wheelIdle.running) box.editStarted()
            wheelIdle.restart()
            box.edited(box.clamp(box.value + notches * box.step * gain))
        }
    }
    // A click becomes typing only once it is clearly not the first half of a
    // double-click, which resets instead.
    Timer { id: typingTimer; interval: Qt.styleHints.mouseDoubleClickInterval; onTriggered: box.beginTyping() }
    Timer { id: wheelIdle; interval: 500; onTriggered: box.editFinished() }
}
