pragma Singleton
import QtQuick

// The film and paper lists as the rails draw them: group captions and rows,
// built from the controller's macOS-ordered catalogues (`preview.filmCatalog`
// / `preview.paperCatalog`, PreviewController.hpp). One place, so the Film and
// Print sections and anything later that lists stocks agree on groups,
// captions and badges.
//
// Rows are `{ name, key, cine, header, enabled, reason, help }`; `key` is the
// stock's id (the controller's selectFilm / selectPaper argument), "" for a
// caption. The CINE badge is the catalogue's own `cine` flag (the Mac's
// `info.use == "cine"`), not a guess from the id.
QtObject {
    // The film list's three groups, as StockCatalog.filmGroups names them;
    // a group with nothing in it gets no caption (FilmSection.swift stockRows).
    function filmCaption(group) {
        if (group === "positive") return L10n.tr("film.group.positive")
        if (group === "negative") return L10n.tr("film.group.negative")
        if (group === "blackAndWhite") return L10n.tr("film.group.blackAndWhite")
        return group
    }
    function paperCaption(group) {
        if (group === "still") return L10n.tr("print.group.still")
        if (group === "cine") return L10n.tr("print.group.cine")
        if (group === "positive") return L10n.tr("print.group.positive")
        return group
    }
    function caption(name) {
        return { name: name, key: "", cine: false, header: true, enabled: false, reason: "", help: "" }
    }

    // Positive, Negative, Black & White, in the catalogue's order.
    function filmRows(films) {
        var rows = []
        var group = null
        for (var i = 0; i < films.length; ++i) {
            var f = films[i]
            if (f.group !== group) { group = f.group; rows.push(caption(filmCaption(group))) }
            rows.push({ name: f.name, key: String(f.id), cine: f.cine === true, header: false,
                        enabled: true, reason: "", help: "" })
        }
        return rows
    }

    // Why a paper row is greyed, from the controller's `reason`
    // (PrintProfileSection.swift:71-79).
    function paperReason(reason) {
        if (reason === "positiveFilm") return L10n.tr("print.reason.positiveFilm")
        if (reason === "silverPaper") return L10n.tr("print.reason.silverPaper")
        if (reason === "colourPaper") return L10n.tr("print.reason.colourPaper")
        return ""
    }

    // Still, Cine, then Digital (the Digital Intermediate, greyed: it needs a
    // Cineon canvas view Windows does not have yet), then Positive with its
    // one row, "No Print Profile" -- scanning the developed film instead of
    // printing it, offered for any film (PrintProfileSection.swift:81-113).
    function paperRows(papers) {
        var rows = []
        var group = null
        var tail = []
        for (var i = 0; i < papers.length; ++i) {
            var p = papers[i]
            if (p.noPrintProfile === true) {
                tail.push({ name: L10n.tr("print.none"), key: String(p.id), cine: false, header: false,
                            enabled: true, reason: "", help: L10n.tr("print.noneHelp") })
                continue
            }
            if (p.group === "positive") {
                tail.unshift({ name: p.name, key: String(p.id), cine: p.cine === true, header: false,
                               enabled: p.enabled === true, reason: paperReason(String(p.reason || "")), help: "" })
                continue
            }
            if (p.group !== group) { group = p.group; rows.push(caption(paperCaption(group))) }
            rows.push({ name: p.name, key: String(p.id), cine: p.cine === true, header: false,
                        enabled: p.enabled === true, reason: paperReason(String(p.reason || "")), help: "" })
        }
        rows.push(caption(L10n.tr("print.group.digital")))
        rows.push({ name: L10n.tr("print.digitalIntermediate"), key: digitalKey, cine: false, header: false,
                    enabled: false, reason: L10n.tr("placeholder.digitalIntermediate"), help: "" })
        if (tail.length > 0) {
            rows.push(caption(paperCaption("positive")))
            rows = rows.concat(tail)
        }
        return rows
    }
    // The Digital Intermediate's row: a switch beside the paper on the Mac,
    // not a paper id (PrintProfileSection.swift:59).
    readonly property string digitalKey: "__digital_intermediate__"
    // "No Print Profile" (PreviewController's printSelection while scanning).
    readonly property string noPrintKey: "__scan_film__"
}
