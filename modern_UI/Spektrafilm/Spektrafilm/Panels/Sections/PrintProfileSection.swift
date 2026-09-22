//  PrintProfileSection.swift — the paper list, grouped Still / Cine /
//  Positive, and the two actions that belong to the print.
//
//  The list is `StockList`, the same view the film list is, because the
//  drawing draws them the same: one well, one-line rows, a **band** on the
//  chosen one and the accent `CINE` pill on a cinema stock.
//
//  The Positive group holds one row, "No Print Profile": scan the developed
//  film instead of printing it. It is where a slide film belongs — printing
//  Provia onto Endura is a thing the engine will happily do and a thing
//  nobody wants — and it is also the only way to look at what the film stage
//  actually produced, orange mask and all.
//
//  It is `scan_film`, not a paper. Selecting it therefore does not clear the
//  paper: turn it off again and the print comes back on whatever was chosen
//  before, which is what makes it usable as a comparison rather than a
//  destination.
//
//  ## The two capsules, and why `Process` left them (v3, handoff §8.1)
//
//  v3 draws **Developed** and **Original** where `Process` and `Original`
//  were, and the handoff is explicit about the trap in that: "Do not rename
//  the solve button to Developed and leave its solve action behind that
//  label." A button reading *Developed* that auto-exposes the frame and
//  re-solves the filter pack is the worst available outcome — the word names
//  a state and the click performs an edit, so the one control in the section
//  that changes the picture is the one that looks like it changes the view.
//
//  So the pair is now **one two-state view selector**: Developed leaves the
//  original view, Original enters it, both through `showingOriginal`, which
//  is the state Space has always toggled on the canvas. Neither renders
//  anything.
//
//  **Solve did not disappear** — it is `Process this frame` in this section's
//  "•••", where it already was, with its own words and its own enabling. The
//  handoff's §8.1 recommendation is what this implements, and the decision it
//  asked the implementation session to make is the one recorded here.

import SwiftUI

struct PrintProfileSection: View {
    /// Rows of the print well on screen before it scrolls. **Odd** — see
    /// `StockList.visibleRows`, and `testStockListShowsAnOddNumberOfRows`.
    static let wellRows = 5

    @Bindable var session: Session

    /// The sentinel `StockList` row id for "No Print Profile". It is not a
    /// paper, so it cannot be a `print_stock` value — see `FilmParams.scanFilm`
    /// for why that separation is load-bearing — and this is the id the list
    /// uses to spell it without either side inventing a stock name.
    private static let positiveID = "__scan_film__"

    /// Whether the chosen film is a slide film, in which case no paper on the
    /// list may be chosen.
    ///
    /// The section's own header has said since it was written that "printing
    /// Provia onto Endura is a thing the engine will happily do and a thing
    /// nobody wants". It was a comment; this is the rule. A positive is
    /// already a viewable image — the paper stage has nothing to interpret —
    /// so every paper greys out and "No Print Profile" is the only row left.
    private var filmIsPositive: Bool { session.filmIsPositive }

    private static var positiveOnlyReason: String { L(.reasonPositiveFilmDisablesPaper) }

    private var rows: [StockList.Row] {
        var out: [StockList.Row] = []
        for group in session.catalog.paperGroups where !group.papers.isEmpty {
            // Id keeps the catalogue's English title; only the label is
            // translated. Paper names themselves are profile names and stay.
            out.append(StockList.Row(id: "__group_" + group.title,
                                     name: L(paperGroup: group.title), isHeader: true))
            out += group.papers.map {
                StockList.Row(id: $0.id, name: $0.name, isCine: $0.isCine,
                              help: filmIsPositive ? "" : helpFor($0.id),
                              enabled: !filmIsPositive,
                              disabledReason: filmIsPositive ? Self.positiveOnlyReason : "")
            }
        }
        // A third "Positive" header, and a different string from the film
        // list's Positive: this one heads the paper list when the film is a
        // slide. The spec lists Positive as a *film* category (胶片分类) and
        // gives this one no row, so it is left as it is rather than collapsed
        // onto `filmGroupPositive`.
        out.append(StockList.Row(id: "__group_Positive", name: "Positive", isHeader: true))
        out.append(StockList.Row(id: Self.positiveID, name: L(.printNone),
                                 help: "Scan the developed film instead of printing it — a slide film reads as a positive, a negative film as the negative it is."))
        return out
    }

    var body: some View {
        PanelSection(L(.sectionPrint), key: "print", menu: { AnyView(menu) }) {
            VStack(alignment: .leading, spacing: 0) {
                StockList(rows: rows,
                          selected: session.params.scanFilm || filmIsPositive
                                    ? Self.positiveID : session.params.printStock,
                          visibleRows: Self.wellRows) { id in
                    if id == Self.positiveID {
                        var p = session.params; p.scanFilm = true; session.params = p
                    } else {
                        // `rowEnabled` already withholds the click; this is the
                        // second door, because the row's own gesture is not the
                        // only way an id reaches here.
                        guard !filmIsPositive else { return }
                        session.selectPrintStock(id)
                    }
                }
                // **Scope, on the row.** EDR is a *print* parameter: it
                // changes the paper's shoulder and toe in the engine, which
                // means the canvas, the export proof and the written file all
                // change together and none of them can disagree.
                //
                // That is why it is here, under the paper it belongs to, and
                // not on the export page. But sitting under a stock list it
                // read as a fourth kind of thing — the user's note was that
                // "its current position under Print leaves that scope
                // unclear" — because the controls near it are a viewing
                // choice (Original), a solve (Process) and a selection, and a
                // checkbox among those could be any of the three. The
                // sublabel settles it without moving it.
                RailRows {
                    ToggleRow(label: L(.printEDR),
                              isOn: param(\.extendedDynamicRange),
                              labelFont: Theme.Font.edrLabel,
                              enabled: !session.params.scanFilm,
                              reason: L(.reasonEDRDisabledInScanFilm),
                              sublabel: L(.statusEDRScope),
                              help: "A calibrated per-paper profile with more room in the "
                              + "highlight shoulder and the toe. It is part of the print "
                              + "stage, not a way of looking at it: what you see on the "
                              + "canvas is what the exported file carries.")
                }
                .padding(.top, Theme.Metric.rowSpacing + 5)
                actions.padding(.top, Theme.Metric.rowSpacing + 5)
            }
        }
    }

    private func param(_ keyPath: WritableKeyPath<FilmParams, Bool>) -> Binding<Bool> {
        Binding(get: { session.params[keyPath: keyPath] },
                set: { var p = session.params; p[keyPath: keyPath] = $0; session.params = p })
    }

    /// Only says something when there is something to say: which film the
    /// paper's baked LUT was paired with, and only while the fast flip is on.
    private func helpFor(_ stock: String) -> String {
        guard session.fastStockPreview, let entry = session.printLUTStocks[stock] else { return "" }
        return "Fast flip available — baked against \(entry.pairedFilm)."
    }

    /// Solve / Original, in v3's two-capsule row: 82.86 × 18.52 each,
    /// `rx 9.26`, 12.18 apart, the pair inset 13.33 from the rail's leading
    /// edge. Two capsules at their own width, not two halves of the rail.
    ///
    /// This row used to be Developed / Original, a two-state view selector —
    /// which left Solve, the one action that prints the frame, in the "…"
    /// menu where nobody found it. So the left capsule is Solve and the
    /// right one is Original as a **toggle**: pressed, it shows the RAW;
    /// pressed again, the developed print. Space still does the same while
    /// held on the canvas.
    ///
    /// **No plate.** v3 fills neither capsule. Solve is an accent outline
    /// whenever it can run; Original is accent while it is showing and muted
    /// otherwise. A muted Original is *not* a disabled one — `rowEnabled`
    /// carries disablement separately, so with no frame open both grey.
    private var actions: some View {
        HStack(spacing: Theme.Metric.actionGap) {
            action(L(.actionSolve),
                   help: "Auto-exposure and the enlarger filter pack for this paper — print this frame.",
                   active: session.canSolve, enabled: session.canSolve) {
                session.solveNow()
            }
            action(L(.actionOriginal),
                   help: session.showingOriginal
                       ? "Showing the original — press to go back to the developed print."
                       : "Show the RAW as Apple's decoder renders it, before any film simulation (⎵ does the same, while held).",
                   active: session.showingOriginal, enabled: session.selection != nil) {
                session.toggledOriginal(!session.showingOriginal)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, Theme.Metric.actionLeading)
    }

    private func action(_ title: String, help: String, active: Bool, enabled: Bool,
                        _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title)
                .font(Theme.Font.action)
                .foregroundStyle(active ? Theme.accent : Theme.Ink.tertiary)
                .lineLimit(1)
                .frame(width: Theme.Metric.actionSize.width,
                       height: Theme.Metric.actionSize.height)
                .overlay(RoundedRectangle(cornerRadius: Theme.Metric.actionRadius, style: .continuous)
                    .stroke(active ? Theme.accent : Theme.Ink.tertiary, lineWidth: 1))
                .frame(height: Theme.Metric.actionHitHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowEnabled(enabled)
        .help(help)
    }

    private var menu: some View {
        Group {
            Button(L(.helpUseFilmPaper)) {
                if let t = session.catalog.stock(session.params.filmStock)?.targetPrint {
                    var p = session.params; p.printStock = t; p.scanFilm = false; session.params = p
                }
            }
            // A positive declares none, so this would do nothing; saying so is
            // better than a live-looking item that silently does not fire.
            .disabled(filmIsPositive
                      || session.catalog.stock(session.params.filmStock)?.targetPrint == nil)
            // Also the Solve capsule above; kept here under its longer name.
            Button(L(.actionProcess)) { session.solveNow() }
                .disabled(!session.canSolve)
            Divider()
            // The caveat is in the label because it is the whole decision.
            // A toggle called "Fast preview" with the explanation somewhere
            // else is a toggle whose behaviour is a surprise.
            Toggle(L(.helpFastFlip),
                   isOn: Binding(get: { session.fastStockPreview },
                                 set: { session.fastStockPreview = $0 }))
                .disabled(session.printLUTStocks.isEmpty)
        }
    }
}
