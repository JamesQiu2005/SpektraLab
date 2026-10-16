import QtQuick

// Label at the left, the orange square at the right (ScrubSlider.swift
// `ToggleRow`): Grain, Halation, Glare, Lens Correction, Print Effects, EDR.
//
//   label, sublabel    the label and an optional dim line under it, for a
//                      switch whose scope is not guessable from where it sits
//                      (EDR: "Changes the render -- canvas, proof and file
//                      alike")
//   checked            the model's state (bind it)
//   toggledTo(on)      the user's request; write the model
//   available, reason, toolTip   as ParamRow
//
// The whole row toggles, not only the square: on Windows a check box's label
// is part of its target.
ParamRow {
    id: row
    property bool checked: false
    signal toggledTo(bool on)
    implicitHeight: Math.max(Theme.toggleRowHeight, Theme.rowHeight + (hasSecondLine ? Theme.subRowHeight : 0))

    MouseArea {
        // The slot starts after the label column; reach back over the label.
        x: -row.controlX; width: row.width; height: row.height
        cursorShape: Qt.PointingHandCursor
        onClicked: row.toggledTo(!row.checked)
    }
    SquareCheck {
        anchors.right: parent.right
        anchors.rightMargin: -(Theme.hitTarget - Theme.checkSize) / 2
        anchors.verticalCenter: parent.verticalCenter
        checked: row.checked
        onToggledTo: function(on) { row.toggledTo(on) }
    }
}
