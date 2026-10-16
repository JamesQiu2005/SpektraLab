import QtQuick

// Print: the papers. A slide film is scanned directly, so the list stays where
// it was -- the paper is remembered for the next negative -- but draws no
// selection and takes no clicks.
Section {
    id: section
    title: "相纸"

    function papers() {
        var rows = []
        for (var i = 0; i < preview.papers.length; ++i)
            rows.push({ "name": preview.papers[i].name, "key": i })
        return rows
    }

    Note { visible: preview.filmIsPositive; text: "反转片直接扫描，不使用相纸。"; color: Theme.accent }
    StockList {
        listObjectName: "paperList"; listHeight: 174
        rows: section.papers(); currentKey: preview.paperIndex
        highlighted: !preview.filmIsPositive
        editable: preview.settingsEditable && !preview.filmIsPositive
        onPicked: function(key) { preview.paperIndex = key }
    }
}
