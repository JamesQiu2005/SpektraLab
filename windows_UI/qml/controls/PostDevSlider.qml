import QtQuick

// A Post-Dev slider (RightSections.swift's ScrubSliders): one scalar of the
// controller's postDev map by its path, its range, default and Shift-snap
// from preview.postDevFields, one undo step per drag ("postDev.<path>"). The
// canvas re-grades on the GPU while it moves, so it streams.
//
//   path        "temperature", "vignette.amount", ...
//   + ScrubSlider's label, decimals, signed, gradient, toolTip
ScrubSlider {
    id: control
    required property string path
    readonly property var row: {
        var fields = preview.postDevFields
        for (var i = 0; i < fields.length; ++i) if (fields[i].path === path) return fields[i]
        return { from: 0, to: 1, initial: 0, snap: 0 }
    }
    function valueAt(map) {
        var parts = path.split(".")
        var v = map
        for (var i = 0; i < parts.length && v !== undefined; ++i) v = v[parts[i]]
        return v === undefined ? row.initial : Number(v)
    }
    from: row.from; to: row.to; defaultValue: row.initial
    snap: row.snap
    step: row.snap > 0 && row.snap < 1 ? 0.05 : 1
    decimals: 0; signed: true
    value: valueAt(preview.postDev)
    gestureKey: "postDev." + path
    available: preview.settingsEditable && preview.hasFrame
    reason: preview.hasFrame ? "" : L10n.tr("postDev.noPhoto")
    onMoved: function(v) { preview.setPostDev(control.path, v) }
}
