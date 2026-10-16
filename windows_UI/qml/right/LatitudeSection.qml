import QtQuick

// Latitude (LatitudeSection.swift): the scene's histogram in stops against
// the film and paper's window, with how much of the frame falls below,
// within and above it. The header names the pair it was measured on.
//
// The measurement needs the engine's latitude fit reported to QML, which the
// Windows controller does not do yet; the section keeps the Mac's place and
// plot height, names the pair, and says what will be drawn.
MacSection {
    sectionId: "latitude"
    title: L10n.tr("latitude.title")
    caption: {
        var film = preview.films.length > preview.filmIndex && preview.filmIndex >= 0 ? preview.films[preview.filmIndex].name : ""
        if (preview.filmIsPositive) return film
        var paper = preview.papers.length > preview.paperIndex && preview.paperIndex >= 0 ? preview.papers[preview.paperIndex].name : ""
        return film + (paper.length > 0 ? "  ·  " + paper : "")
    }

    PlotPlaceholder { text: L10n.tr("placeholder.latitude") }
    Note { text: L10n.tr("latitude.stats") }
}
