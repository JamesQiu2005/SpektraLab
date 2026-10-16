import QtQuick
import QtQuick.Controls

// Film (FilmSection.swift): the stock list in the Mac's groups -- Positive,
// Negative, Black & White -- from the controller's catalogue, with the CINE
// badge on cinema stocks. A click is Session.selectFilmStock's rule
// (preview.selectFilm): the film takes its own paper, and a black-and-white
// film its silver paper, in the same undo step. The reset arrow and the
// "..." menu's one item return the film to Portra 400 (resetFilmStock, which
// also leaves a silver paper behind) and say so in words.
MacSection {
    id: section
    sectionId: "film"
    title: L10n.tr("film.title")
    inset: false
    resetVisible: true
    resetAvailable: preview.settingsEditable && preview.filmCatalog.length > 0
    resetToolTip: L10n.tr("film.reset")
    onResetRequested: preview.resetFilmStock()
    menuItems: [
        RailMenuItem { text: L10n.tr("film.reset"); enabled: section.resetAvailable; onTriggered: preview.resetFilmStock() }
    ]

    StockList {
        listObjectName: "filmList"
        visibleRows: 14
        rows: Catalog.filmRows(preview.filmCatalog)
        currentKey: preview.parameters.film_stock === undefined ? "" : String(preview.parameters.film_stock)
        editable: preview.settingsEditable
        onPicked: function(key) { preview.selectFilm(key) }
    }
}
