import QtQuick

// Print: the papers. A slide film is scanned directly, so the list stays where
// it was -- the paper is remembered for the next negative -- but draws no
// selection and takes no clicks.
Section {
    id: section
    title: L10n.tr("print.title")

    function papers() {
        var rows = []
        for (var i = 0; i < preview.papers.length; ++i)
            rows.push({ "name": preview.papers[i].name, "key": i })
        return rows
    }

    Note { visible: preview.filmIsPositive; text: L10n.tr("print.slideScannedDirectly"); color: Theme.accent }
    StockList {
        listObjectName: "paperList"; listHeight: 174
        rows: section.papers(); currentKey: preview.paperIndex
        highlighted: !preview.filmIsPositive
        editable: preview.settingsEditable && !preview.filmIsPositive
        onPicked: function(key) { preview.paperIndex = key }
    }
}
