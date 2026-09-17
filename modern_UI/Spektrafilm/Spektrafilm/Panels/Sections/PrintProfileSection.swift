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
//  **`Solve` is called `Process` now**, which is the drawing's word for it.
//  The button is unchanged — auto-expose this frame and solve the enlarger
//  filter pack for the chosen paper — and the rename is the whole of the
//  change: the handoff's complaint about the old label was that "不知道
//  solve 了什么", and `Process` at least names the thing that happens to the
//  photograph rather than the thing that happens to the arithmetic.

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

    private var rows: [StockList.Row] {
        var out: [StockList.Row] = []
        for group in session.catalog.paperGroups where !group.papers.isEmpty {
            out.append(StockList.Row(id: "__group_" + group.title, name: group.title, isHeader: true))
            out += group.papers.map {
                StockList.Row(id: $0.id, name: $0.name, isCine: $0.isCine, help: helpFor($0.id))
            }
        }
        out.append(StockList.Row(id: "__group_Positive", name: "Positive", isHeader: true))
        out.append(StockList.Row(id: Self.positiveID, name: "No Print Profile",
                                 help: "Scan the developed film instead of printing it — a slide film reads as a positive, a negative film as the negative it is."))
        return out
    }

    var body: some View {
        PanelSection("Print", key: "print", menu: { AnyView(menu) }) {
            VStack(alignment: .leading, spacing: 0) {
                StockList(rows: rows,
                          selected: session.params.scanFilm ? Self.positiveID : session.params.printStock,
                          visibleRows: Self.wellRows) { id in
                    if id == Self.positiveID {
                        var p = session.params; p.scanFilm = true; session.params = p
                    } else {
                        session.selectPrintStock(id)
                    }
                }
                actions.padding(.top, Theme.Metric.rowSpacing + 5)
            }
        }
    }

    /// Only says something when there is something to say: which film the
    /// paper's baked LUT was paired with, and only while the fast flip is on.
    private func helpFor(_ stock: String) -> String {
        guard session.fastStockPreview, let entry = session.printLUTStocks[stock] else { return "" }
        return "Fast flip available — baked against \(entry.pairedFilm)."
    }

    /// Process and Original, in the drawing's two-button row: 26 pt tall,
    /// `rx 8.25` — a rounded rectangle and deliberately not a capsule — 2.5
    /// apart, and inset by the same 4 the well above them is.
    ///
    /// They sit here rather than on the bar because both are questions about
    /// the *print*: "what would the engine choose for this paper" and "what
    /// did I start from". Original is a toggle, not a press-and-hold — Space
    /// already does press-and-hold on the canvas, and a button that only works
    /// while the mouse is down is a button nobody finds.
    private var actions: some View {
        HStack(spacing: Theme.Metric.actionGap) {
            action("Process", help: "Auto-expose this frame and solve the enlarger filter pack for the selected paper.",
                   active: false, enabled: session.canSolve) {
                session.solveNow()
            }
            action("Original", help: "Show the RAW as Apple's decoder renders it, before any film simulation (Space does the same, while held).",
                   active: session.showingOriginal, enabled: session.selection != nil) {
                session.toggledOriginal(!session.showingOriginal)
            }
        }
        .padding(.horizontal, Theme.Metric.wellInset)
    }

    private func action(_ title: String, help: String, active: Bool, enabled: Bool,
                        _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title)
                .font(Theme.Font.action)
                .foregroundStyle(active ? Theme.accent : Theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Metric.actionHeight)
                .background(Theme.well,
                            in: RoundedRectangle(cornerRadius: Theme.Metric.actionRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Metric.actionRadius, style: .continuous)
                    .stroke(Theme.accent, lineWidth: active ? 1 : 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowEnabled(enabled)
        .help(help)
    }

    private var menu: some View {
        Group {
            Button("Use the film's declared paper") {
                if let t = session.catalog.stock(session.params.filmStock)?.targetPrint {
                    var p = session.params; p.printStock = t; p.scanFilm = false; session.params = p
                }
            }
            Button("Process this frame") { session.solveNow() }
                .disabled(!session.canSolve)
            Divider()
            // The caveat is in the label because it is the whole decision.
            // A toggle called "Fast preview" with the explanation somewhere
            // else is a toggle whose behaviour is a surprise.
            Toggle("Fast flip (baked LUT, no glare, ignores your print grade)",
                   isOn: Binding(get: { session.fastStockPreview },
                                 set: { session.fastStockPreview = $0 }))
                .disabled(session.printLUTStocks.isEmpty)
        }
    }
}
