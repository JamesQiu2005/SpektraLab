import QtQuick
import QtQuick.Controls

// Film (FilmSection.swift): the stock list, Positive then Negative, with the
// CINE badge on cinema stocks (Catalog.qml). The reset arrow and its menu
// item return the film to Portra 400, the stock a new photograph starts on,
// and say so in words (the Mac's rule for a reset whose scope is not obvious).
MacSection {
    id: section
    sectionId: "film"
    title: L10n.tr("film.title")
    inset: false
    resetVisible: true
    resetAvailable: preview.settingsEditable && preview.films.length > 0
    resetToolTip: L10n.tr("film.reset")
    onResetRequested: section.resetFilm()
    menuItems: [
        RailMenuItem { text: L10n.tr("film.reset"); enabled: section.resetAvailable; onTriggered: section.resetFilm() }
    ]

    // By id through the settings table, so the controller's own rules (a
    // slide film is scanned without a paper) apply as for a click.
    function resetFilm() { preview.setParameter("film_stock", "kodak_portra_400") }

    StockList {
        listObjectName: "filmList"
        visibleRows: 14
        rows: Catalog.filmRows(preview.films)
        currentKey: preview.filmIndex
        editable: preview.settingsEditable
        onPicked: function(key) { preview.filmIndex = key }
    }
}
