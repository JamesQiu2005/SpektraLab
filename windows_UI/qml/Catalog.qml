pragma Singleton
import QtQuick

// The film and paper lists as the rails draw them: group captions and rows,
// built from the controller's catalogue (`preview.films` / `preview.papers`,
// each `{ id, name, positive }`). One place, so the Film and Print sections
// and anything later that lists stocks agree on groups and badges.
//
// Rows are `{ name, key, cine, header, enabled, reason }`; `key` is the
// stock's index in the controller's catalogue, -1 for captions and for the
// "No Print Profile" row.
QtObject {
    // Whether a stock is cinema stock, for the CINE badge and the Cine paper
    // group. The macOS catalogue says so in each profile's `info.use`, which
    // the Windows controller does not pass to QML yet; until it does (a
    // `cine` field on each catalogue entry is honoured when present), the
    // stock id decides: Kodak's Vision3 and Verita camera films and the 2383 /
    // 2393 print films -- exactly the "use": "cine" entries of the Mac's
    // StockCatalog.json.
    function isCine(stock) {
        if (stock.cine !== undefined) return !!stock.cine
        var id = String(stock.id === undefined ? "" : stock.id)
        return id.indexOf("kodak_vision3_") === 0 || id.indexOf("kodak_verita_") === 0
            || id === "kodak_2383" || id === "kodak_2393"
    }

    // Positive, then Negative -- the Mac's two visible groups, taken from the
    // catalogue's type rather than from any order in a drawing. An empty
    // group gets no caption.
    function filmRows(films) {
        var rows = []
        var groups = [{ positive: true, caption: L10n.tr("film.group.positive") },
                      { positive: false, caption: L10n.tr("film.group.negative") }]
        for (var g = 0; g < groups.length; ++g) {
            var members = []
            for (var i = 0; i < films.length; ++i)
                if (films[i].positive === groups[g].positive)
                    members.push({ name: films[i].name, key: i, cine: isCine(films[i]), header: false, enabled: true, reason: "" })
            if (members.length === 0) continue
            rows.push({ name: groups[g].caption, key: -1, cine: false, header: true, enabled: false, reason: "" })
            rows = rows.concat(members)
        }
        return rows
    }

    // Still, Cine, then Positive with its one row, "No Print Profile" --
    // scanning the developed film instead of printing it. A slide film is
    // scanned directly (the controller's rule), so while one is chosen every
    // paper greys with the reason and "No Print Profile" is the answer; for a
    // negative the Windows controller has no scan-only switch yet, so that
    // row is the one that greys.
    function paperRows(papers, positiveFilm) {
        var still = [], cine = []
        for (var i = 0; i < papers.length; ++i) {
            var row = { name: papers[i].name, key: i, cine: isCine(papers[i]), header: false,
                        enabled: !positiveFilm, reason: positiveFilm ? L10n.tr("print.reason.slideFilm") : "" }
            if (row.cine) cine.push(row); else still.push(row)
        }
        var rows = []
        if (still.length > 0) {
            rows.push({ name: L10n.tr("print.group.still"), key: -1, cine: false, header: true, enabled: false, reason: "" })
            rows = rows.concat(still)
        }
        if (cine.length > 0) {
            rows.push({ name: L10n.tr("print.group.cine"), key: -1, cine: false, header: true, enabled: false, reason: "" })
            rows = rows.concat(cine)
        }
        rows.push({ name: L10n.tr("print.group.positive"), key: -1, cine: false, header: true, enabled: false, reason: "" })
        rows.push({ name: L10n.tr("print.none"), key: noPrintKey, cine: false, header: false,
                    enabled: positiveFilm, reason: positiveFilm ? "" : L10n.tr("print.reason.noScanNegative") })
        return rows
    }
    // The "No Print Profile" row's key: not a catalogue index.
    readonly property int noPrintKey: -2
}
