//  StockPairPicker.swift — the film and paper new frames develop with.
//
//  Not drawn: the drawings have a row for it in three places (Settings' *New
//  frames*, the Import sheet's *Develops with*, First run's pill) and the
//  import banner's *Change*, but no page behind them. This is the smallest
//  page that answers them, in the drawings' own language: grouped rows, a
//  stock's dot beside its name, the chosen one ticked in white —
//  selection is never accent — and *Last used* first, which is what a new
//  frame takes until a pair is chosen.
//
//  The films and papers are the catalogue's, in its order, by name.
//
//  **The pair is always one a frame could have** (`StockPair`, 2026-10-09). A
//  paper that cannot print the
//  chosen film — a colour paper under a black-and-white film, the silver paper
//  under a colour one — is dimmed, that row alone, and is not chosen; a film
//  chosen over such a paper brings its own. The gate is the model's, the
//  dimming only shows it.

import SwiftUI

struct StockPairPicker: View {
    enum Mode {
        /// What new frames develop with: `AppSettings.newFrameFilm` / `newFramePaper`.
        case newFrames
        /// The import banner's `Change`: the pair is handed back to develop
        /// that import's frames again.
        case importBanner
    }
    enum Presentation { case sheet, pushed }

    let mode: Mode
    var presentation: Presentation = .sheet
    /// `.importBanner`: called with the pair chosen.
    var onChoose: ((String, String) -> Void)? = nil

    @Environment(AppSettings.self) private var settings
    @Environment(FrameCatalog.self) private var library
    @Environment(\.dismiss) private var dismiss

    /// `.importBanner`: the pair being chosen, applied by the button.
    @State private var film: String?
    @State private var paper: String?

    init(mode: Mode, presentation: Presentation = .sheet, onChoose: ((String, String) -> Void)? = nil) {
        self.mode = mode
        self.presentation = presentation
        self.onChoose = onChoose
    }

    var body: some View {
        VStack(spacing: 0) {
            if presentation == .sheet {
                SheetHeader(title: mode == .newFrames ? L("New frames develop with") : L("Develop the import with"),
                            subtitle: mode == .newFrames ? L("Shots and imports, from now on") : L("Its frames develop again")) {
                    dismiss()
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if presentation == .pushed { SettingsPageHeader(title: L("New frames")) }
                    if mode == .newFrames {
                        GroupBox {
                            pickRow(title: L("Last used"), detail: lastUsedText, dot: nil, on: settings.newFrameFilm == nil) {
                                settings.newFrameFilm = nil
                                settings.newFramePaper = nil
                            }
                        }
                        .padding(.horizontal, Theme.Metric.margin)
                        .padding(.top, 20)
                    }
                    SectionLabel(L("Film")).padding(.horizontal, 20).padding(.top, 22)
                    GroupBox {
                        let films = StockCatalog.shared.films
                        ForEach(Array(films.enumerated()), id: \.element.id) { i, stock in
                            pickRow(title: stock.shortName, detail: detail(stock), dot: stock.color,
                                    on: chosenFilm == stock.id) { chooseFilm(stock) }
                            if i < films.count - 1 { RowSeparator(leading: 40).padding(.top, -1) }
                        }
                    }
                    .padding(.horizontal, Theme.Metric.margin)
                    .padding(.top, 5.5)
                    // A slide film is scanned, not printed: the papers wait,
                    // dimmed, with the one last chosen kept for the next negative.
                    let slide = StockCatalog.shared.isSlide(chosenFilm)
                    SectionLabel(L("Paper")).padding(.horizontal, 20).padding(.top, 22)
                    GroupBox {
                        let papers = StockCatalog.shared.papers
                        ForEach(Array(papers.enumerated()), id: \.element.id) { i, stock in
                            // A paper of the other kind waits, that row alone.
                            let waits = slide ? nil : StockCatalog.shared.whyNotPrinted(film: chosenFilm, on: stock.id)
                            pickRow(title: stock.shortName, detail: L(shown: stock.kind), dot: stock.color,
                                    on: !slide && chosenPaper == stock.id, waits: waits) { choosePaper(stock.id) }
                            if i < papers.count - 1 { RowSeparator(leading: 40).padding(.top, -1) }
                        }
                    }
                    .rowEnabled(!slide)
                    .padding(.horizontal, Theme.Metric.margin)
                    .padding(.top, 5.5)
                    if slide {
                        Note(L("\(StockCatalog.shared.stock(chosenFilm)?.shortName ?? L("This film")) is a slide: it is scanned, not printed. "
                             + "The paper waits for a negative."))
                            .padding(.horizontal, 20).padding(.top, 10)
                    } else if let why = Self.papersNote(film: chosenFilm) {
                        Note(why).padding(.horizontal, 20).padding(.top, 10)
                    }
                    if mode == .newFrames {
                        Note(L("A frame keeps the pair it arrived with; change it on the develop page."))
                            .padding(.horizontal, 20).padding(.top, 10)
                    }
                }
                .padding(.bottom, mode == .importBanner ? 100 : 40)
            }
            .scrollIndicators(.hidden)
        }
        .overlay(alignment: .bottom) {
            if mode == .importBanner {
                CapsuleButton(title: L("Develop Again")) {
                    onChoose?(chosenFilm, chosenPaper)
                    dismiss()
                }
                .padding(.horizontal, Theme.Metric.margin)
                .padding(.bottom, 8)
            }
        }
        .background((presentation == .sheet ? Theme.sheet : Theme.background).ignoresSafeArea())
        .onAppear {
            if mode == .importBanner, film == nil {
                let first = library.importBanner?.frameIDs.lazy.compactMap { library.frame($0) }.first
                // The pair the import's first frame has, as a new frame would take it:
                // on a paper that prints its film.
                let pair = StockCatalog.shared.newFramePair(film: first?.edit.params.filmStock ?? settings.newFrameStocks.film,
                                                            paper: first?.edit.params.printStock ?? settings.newFrameStocks.paper)
                (film, paper) = (pair.film, pair.paper)
            }
        }
    }

    /// Under a black-and-white film: why the colour papers wait, as the line
    /// under a slide says why all of them do.
    static func papersNote(film: String, catalog: StockCatalog = .shared) -> String? {
        guard let stock = catalog.stock(film), stock.isMonochrome, !stock.isPositive else { return nil }
        return L("\(stock.shortName) is a black-and-white film: it prints on a black-and-white paper. "
            + "The colour papers wait for a colour film.")
    }

    // MARK: the choice

    private var chosenFilm: String {
        mode == .importBanner ? (film ?? settings.newFrameStocks.film) : settings.newFrameStocks.film
    }
    private var chosenPaper: String {
        mode == .importBanner ? (paper ?? settings.newFrameStocks.paper) : settings.newFrameStocks.paper
    }

    /// Choosing a film or a paper fixes the pair: *Last used* is left. A paper
    /// that cannot print the chosen film is refused (`StockPair`), whatever the
    /// row looked like.
    private func chooseFilm(_ stock: Stock) {
        var pair = StockPair(film: chosenFilm, paper: chosenPaper)
        pair.load(film: stock.id)
        take(pair)
    }

    private func choosePaper(_ id: String) {
        var pair = StockPair(film: chosenFilm, paper: chosenPaper)
        guard pair.print(on: id) else { return }
        take(pair)
    }

    private func take(_ pair: StockPair) {
        switch mode {
        case .importBanner: (film, paper) = (pair.film, pair.paper)
        case .newFrames:
            settings.newFramePaper = pair.paper
            settings.newFrameFilm = pair.film
        }
    }

    private var lastUsedText: String {
        StockCatalog.shared.pairText(film: settings.lastFilm, paper: settings.lastPaper)
    }

    /// "colour negative · ISO 400".
    private func detail(_ stock: Stock) -> String {
        [L(shown: stock.kind), stock.isoText].compactMap { $0 }.joined(separator: " · ")
    }

    /// `waits`: why a paper cannot be chosen — the row is dimmed and takes no tap.
    private func pickRow(title: String, detail: String, dot: Color?, on: Bool, waits: String? = nil,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                if let dot {
                    StockDot(color: dot, diameter: 10).frame(width: 26, alignment: .leading)
                }
                Text(title).font(Theme.Font.listLabel).foregroundStyle(Theme.text)
                Text(detail).font(Theme.Font.ui(12)).foregroundStyle(Theme.dim).padding(.leading, 8)
                Spacer(minLength: 8)
                if on { Icon(.menuCheck) }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 1))
        .rowEnabled(waits == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, waits ?? detail].joined(separator: ", "))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}
