import QtQuick

// Film: the catalogue's films in two groups, slides first, then negatives.
Section {
    id: section
    title: L10n.tr("film.title")

    // One group's rows, each keyed by its index in the whole catalogue.
    function group(positive) {
        var rows = []
        for (var i = 0; i < preview.films.length; ++i)
            if (preview.films[i].positive === positive)
                rows.push({ "name": preview.films[i].name, "key": i })
        return rows
    }

    StockList {
        title: L10n.tr("film.group.positive"); listObjectName: "positiveFilmList"; listHeight: 112
        rows: section.group(true); currentKey: preview.filmIndex; editable: preview.settingsEditable
        onPicked: function(key) { preview.filmIndex = key }
    }
    StockList {
        title: L10n.tr("film.group.negative"); listObjectName: "filmList"; listHeight: 174
        rows: section.group(false); currentKey: preview.filmIndex; editable: preview.settingsEditable
        onPicked: function(key) { preview.filmIndex = key }
    }
}
