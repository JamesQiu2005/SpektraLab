import SwiftUI

struct StockPreviewPanel: View {
    let session: OpenFrameSession
    let strip: StockStrip
    var compact = false
    /// Opens Crop from here (the owner, 2026-10-19: crop has a place in Develop
    /// too, and the develop is cut before the meter, so every card and the
    /// page's own develop are of the cropped picture); nil shows no button.
    var crop: (() -> Void)? = nil
    /// The rows each strip is laid in. One is the host's: the two pills on one line over the film
    /// row and the paper row. More is a wide window's column (the owner, 2026-10-21): the film's pill,
    /// its cards in that many rows, then the paper's pill and its cards, so more of each is seen
    /// at once and still scrolls sideways (`height(rows:compact:)` says what the column can hold).
    var rows = 1
    /// Decode, under the two strips (`DecodeSection`, 2026-10-24): Film Exposure, the white balance
    /// and the curve on the scene, in the place the Film Exposure slider had. Nil draws the slider
    /// alone, as before (a page with no frame to decode).
    var decode: DecodeSection? = nil
    /// The page's status line under the Apply Film Emulation switch: a wide window's, and only with
    /// the film applied (`DevelopWorkspace.developStatusFoot`); nil on the host's page.
    var status: DevelopStatus? = nil
    /// each strip under its own
    /// folding header — since 2026-11-11 Edit › Adjust's (`ColumnSectionHeader`: the chevron at the left, "Film" or
    /// "Paper", its shelf's small pill at the right) — kept across launches (`DevelopPanelPrefs`). A wide window's;
    /// the host's two pills share a line. The column's rows are tight: no gap between them, the cards' row with 8 pt
    /// under it, Apply Film Emulation a 32 pt row with a small switch.
    var foldable = false
    private var prefs: DevelopPanelPrefs { .shared }
    private var filmFolded: Bool { foldable && prefs.filmRowCollapsed }
    private var paperFolded: Bool { foldable && prefs.paperRowCollapsed }
    @State private var visible: Set<String> = []
    /// The shelf each strip is narrowed to (`StockShelf`); All when the page opens.
    @State private var filmShelf = StockShelf.all
    @State private var paperShelf = StockShelf.all
    /// This page's claim on what the strip shows (`StripClients`).
    @State private var client = UUID()

    private var filmCards: [StockPreviewCard] { filmShelf.cards(strip.filmCards) }
    /// Every paper, those that cannot print the film greyed (`StockPreviewRules.paperShelf`);
    /// live are `strip.paperCards` that also print a film on the film row's shelf.
    private var paperCards: [StockPreviewCard] {
        paperShelf.cards(StockPreviewRules.paperShelf(under: session.edit.params.filmStock))
    }
    private func serves(_ card: StockPreviewCard) -> Bool {
        card.strip == .film || StockPreviewRules.paperServes(card.stock, filmShelf: filmShelf)
    }
    private var cards: [StockPreviewCard] { (filmCards + paperCards).filter { strip.isLive($0) && serves($0) } }
    /// No paper is chosen under a slide: it is scanned.
    private var chosenPaper: String { StockPreviewRules.chosenPaper(session.edit.params) }
    /// The panel's height with `rows` rows to each strip, laid as the column lays them, Decode
    /// showing its shortest part (Exposure): a taller part scrolls, rather than the strips losing a
    /// row under the pointer each time a chip is chosen.
    /// A folded strip (`foldable`) is its pill's line alone.
    /// `decodeFolded`: a wide window's Decode folded to its title line (`DecodeSection.foldedHeight`) gives its
    /// rows to the strips, as a folded strip gives its to the other. The 2026-11-06 review: the 126 pt of an
    /// unfolded Decode were held for it folded too, so at 1427 × 977 the HDR row's 54 pt took both strips from two
    /// rows to one, with ~280 pt left empty under it.
    /// The foldable column's (the only one that asks): two headers, the open strips' rows with their 8 pt, Decode
    /// (`DecodeSection.stackedHeight` open) and Apply Film Emulation's row, no gaps between them.
    static func height(rows: Int, compact: Bool, filmFolded: Bool = false, paperFolded: Bool = false,
                       decodeFolded: Bool = false) -> CGFloat {
        let header = ColumnSectionHeader<EmptyView>.height
        let row = StockPreviewRow.height(compact: compact, rows: rows) + Self.stripGap
        let decode = decodeFolded ? DecodeSection.foldedHeight : DecodeSection.stackedHeight
        return 2 * header + (filmFolded ? 0 : row) + (paperFolded ? 0 : row) + decode + Self.switchHeight
    }

    /// Under a foldable strip's cards, before the next header.
    static let stripGap: CGFloat = 8
    /// Apply Film Emulation's row in the foldable column: its hairline and its 32 pt line.
    static var switchHeight: CGFloat { FoldRule.height + FoldHeader<EmptyView, EmptyView>.height }

    /// Apply Film Emulation (`FrameEdit.appliesFilm`): off, the film and the paper are greyed and the
    /// frame is Apple's own decode. A half-frame pair is a piece of film: it has no switch.
    private var appliesFilm: Bool { session.edit.appliesFilm }

    var body: some View {
        VStack(spacing: foldable ? 0 : (compact ? 6 : 10)) {
            // A foldable strip greys its pill and cards itself: its fold still works with the film off.
            Group { strips }.rowEnabled(appliesFilm || foldable)
            if let decode {
                decode
            } else {
                EditSlider(title: L("Film Exposure"), value: session.binding(\.params.exposureCompensationEV),
                           range: -8...8, text: { Fmt.signed($0) + " EV" }, detentAtRest: true, editing: session.editing(.shoot))
                    .padding(.horizontal, 16)
                    .rowEnabled(appliesFilm)
            }
            if session.pair == nil { filmSwitch }
            if let status { StatusFoot(status: status) }
        }
        .padding(.top, foldable ? 0 : 8)
        .onChange(of: session.edit, initial: true) { _, edit in strip.edit = edit }
        .onChange(of: visible) { _, _ in show() }
        .onChange(of: strip.paperCards) { _, _ in show() }
        .onChange(of: filmShelf) { _, _ in show() }
        .onChange(of: session.edit.params.filmStock) { _, _ in show() }
        .onChange(of: appliesFilm) { _, _ in show() }
        .onChange(of: paperShelf) { _, _ in show() }
        // A folded strip's cards are not on screen: they are not asked for.
        .onChange(of: filmFolded) { _, folded in if folded { visible.subtract(filmCards.map(\.slot)) } }
        .onChange(of: paperFolded) { _, folded in if folded { visible.subtract(paperCards.map(\.slot)) } }
        // SwiftUI may retain this panel and its unchanged geometry when a
        // different step covers it. Keep the viewport, but release the card
        // references/jobs; on return no preference change is guaranteed.
        .onAppear { show() }
        .onDisappear { StripClients.release(strip, by: client) }
        // Another frame on the kept page (2.4.0 A2b): its strip, given the edit and asked for the cards on screen; the
        // last frame's strip was let go with its session (`StockStrip.leave`). The shelves back to All, as a page made
        // for the frame opened; the rows' sideways places are kept (the same cards, in the same order).
        .onChange(of: ObjectIdentifier(strip)) { _, _ in
            filmShelf = .all; paperShelf = .all
            strip.edit = session.edit
            show()
        }
    }

    /// The owner, 2026-10-21: "a on / off switch under film exposure called 'apply film emulation'".
    /// In the foldable column a 32 pt row under the hairline, its switch small (2026-11-11, Edit's size).
    @ViewBuilder private var filmSwitch: some View {
        let toggle = SpkToggle(isOn: Binding(get: { session.edit.appliesFilm },
                                             set: { on in session.change { $0.setAppliesFilm(on) } }),
                               size: foldable ? .compact : .regular)
            .accessibilityLabel(L("Apply Film Emulation"))
            .accessibilityIdentifier("v5.develop.apply-film")
        if foldable {
            VStack(spacing: 0) {
                FoldRule()
                HStack {
                    Text(L("Apply Film Emulation")).font(Theme.Font.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    toggle
                }
                .padding(.horizontal, 16)
                .frame(height: FoldHeader<EmptyView, EmptyView>.height)
            }
        } else {
            HStack {
                Text(L("Apply Film Emulation")).font(Theme.Font.ui(13, .semibold)).foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                toggle
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
        }
    }

    @ViewBuilder private var strips: some View {
            if foldable {
                // Edit › Adjust's folding headers (2026-11-11): the chevron at the left, the strip's name, its
                // shelf's small pill at the right. The pill greys with the film off; the fold still works.
                ColumnSectionHeader(title: L("Film"), folded: filmFolded, id: "film",
                                    toggleFold: { prefs.filmRowCollapsed.toggle() }) {
                    filmPill(small: true).rowEnabled(appliesFilm)
                    if let crop { cropButton(crop).rowEnabled(appliesFilm) }
                }
                if !filmFolded { filmRow.rowEnabled(appliesFilm).padding(.bottom, Self.stripGap) }
                ColumnSectionHeader(title: L("Paper"), folded: paperFolded, id: "paper",
                                    toggleFold: { prefs.paperRowCollapsed.toggle() }) {
                    paperPill(small: true).rowEnabled(appliesFilm)
                }
                if !paperFolded { paperRow.rowEnabled(appliesFilm).padding(.bottom, Self.stripGap) }
            } else if rows > 1 {
                HStack(spacing: 8) {
                    filmPill
                    Spacer(minLength: 0)
                    if let crop { cropButton(crop) }
                }.padding(.horizontal, 16)
                filmRow
                HStack {
                    paperPill
                    Spacer(minLength: 0)
                }.padding(.horizontal, 16)
                paperRow
            } else {
                // Both pills whole, and Crop in words where they fit beside it; where they do not
                // (Japanese at an reference device's width: フィルム · すべて, 印画紙 · すべて), Crop is its glyph
                // alone, never a pill cut to "…". English and Chinese always take the first.
                ViewThatFits(in: .horizontal) {
                    pillsRow(cropInWords: true)
                    pillsRow(cropInWords: false)
                }.padding(.horizontal, 16)
                filmRow
                paperRow
            }
    }

    private var filmPill: some View { filmPill(small: false) }
    private var paperPill: some View { paperPill(small: false) }
    private func filmPill(small: Bool) -> some View {
        StockShelfPill(title: L("Film"), shelves: StockShelf.film, shelf: $filmShelf, all: strip.filmCards, small: small)
    }
    private func paperPill(small: Bool) -> some View {
        StockShelfPill(title: L("Paper"), shelves: StockShelf.paper, shelf: $paperShelf, all: paperCards, small: small)
    }
    // A new shelf is a new row: it starts at its chosen card, or at its first.
    private var filmRow: some View {
        StockPreviewRow(session: session, strip: strip, cards: filmCards, selected: session.edit.params.filmStock,
                        compact: compact, rows: rows, visible: $visible, active: appliesFilm).id(filmShelf)
    }
    // Always there: under a slide, or a film shelf no paper serves, every card greyed.
    private var paperRow: some View {
        StockPreviewRow(session: session, strip: strip, cards: paperCards, selected: chosenPaper,
                        compact: compact, rows: rows, visible: $visible, serves: serves, active: appliesFilm).id(paperShelf)
    }

    /// The cards on screen are asked for; none while the film is off — they would be pictures of a film not applied.
    private func show() {
        guard appliesFilm else { StripClients.release(strip, by: client); return }
        StripClients.show(cards.filter { visible.contains($0.slot) }, on: strip, by: client)
    }

    private func pillsRow(cropInWords: Bool) -> some View {
        HStack(spacing: 8) {
            filmPill
            paperPill
            Spacer(minLength: 0)
            if let crop { cropButton(crop, inWords: cropInWords) }
        }
    }

    private func cropButton(_ action: @escaping () -> Void, inWords: Bool = true) -> some View {
        Button(action: action) {
            Group {
                if inWords { Label(L("Crop"), systemImage: "crop") }
                else { Label(L("Crop"), systemImage: "crop").labelStyle(.iconOnly) }
            }
                .font(Theme.Font.ui(13, .semibold)).lineLimit(1)
                .foregroundStyle(Theme.text).padding(.horizontal, 12).frame(height: 30)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(L("Crop"))
        .accessibilityIdentifier("v5.develop.crop")
    }
}

/// The Enlarger page's papers (the owner, 2026-10-20: "the paper display fix
/// that acts like the paper selection in develop, instead of the current,
/// not-uniformed way"): Develop's paper row itself — each card the frame
/// through the chosen film on that paper, the film's own paper wearing its
/// dot, the shelf its pill chose — asking the strip for the cards it shows.
/// Under a slide every paper is there greyed, as in Develop.
struct EnlargerPaperRow: View {
    let session: OpenFrameSession
    let strip: StockStrip
    let shelf: StockShelf
    var compact = false
    @State private var visible: Set<String> = []
    @State private var client = UUID()

    private var cards: [StockPreviewCard] {
        shelf.cards(StockPreviewRules.paperShelf(under: session.edit.params.filmStock))
    }

    var body: some View {
        StockPreviewRow(session: session, strip: strip, cards: cards, selected: StockPreviewRules.chosenPaper(session.edit.params),
                        compact: compact, visible: $visible, active: session.edit.appliesFilm)
            .id(shelf)
            .onChange(of: session.edit, initial: true) { _, edit in strip.edit = edit }
            .onChange(of: visible) { _, _ in show() }
            .onChange(of: strip.paperCards) { _, _ in show() }
            .onChange(of: shelf) { _, _ in show() }
            .onAppear { show() }
            .onDisappear { StripClients.release(strip, by: client) }
            // Another frame on the kept page (2.4.0 A2b): its strip, given the edit and asked for the cards on screen.
            .onChange(of: ObjectIdentifier(strip)) { _, _ in strip.edit = session.edit; show() }
    }

    private func show() {
        // None while the film is off (Apply Film Emulation): pictures of a film not applied.
        guard session.edit.appliesFilm else { StripClients.release(strip, by: client); return }
        StripClients.show(cards.filter { strip.isLive($0) && visible.contains($0.slot) }, on: strip, by: client)
    }
}

/// Which page last asked a strip for its cards. Two pages show the strip's
/// cards — Develop's Film & Paper and the Enlarger — and SwiftUI may bring the
/// next one on before it lets the last one go: a page that leaves takes its
/// cards off the strip only while they are still its own, so it never empties
/// what the page after it has just asked for.
@MainActor
enum StripClients {
    private static var owners: [ObjectIdentifier: UUID] = [:]

    static func show(_ cards: [StockPreviewCard], on strip: StockStrip, by client: UUID) {
        #if DEBUG && SPK_ENGINE
        TransitionMarks.mark("strip.show>")
        defer { TransitionMarks.mark("strip.show<") }
        #endif
        owners[ObjectIdentifier(strip)] = client
        strip.show(cards)
    }

    static func release(_ strip: StockStrip, by client: UUID) {
        let key = ObjectIdentifier(strip)
        guard owners[key] == client else { return }
        owners[key] = nil
        strip.show([])
    }
}

extension StockStrip {
    /// Whether a card can be chosen and is rendered: every film card, and a
    /// paper card that can print the chosen film (a colour paper under a
    /// black-and-white film is shown greyed, never asked for).
    func isLive(_ card: StockPreviewCard) -> Bool { card.strip == .film || paperCards.contains(card) }
}

/// A strip's pill, as the Library's collection pill: what it holds and the
/// shelf it is on, a chevron, and the shelves in a menu. A shelf with no
/// card under this film is there and dimmed (a black-and-white film's
/// papers are silver alone). Develop's two strips and the Enlarger's papers wear it.
struct StockShelfPill: View {
    let title: String
    let shelves: [StockShelf]
    @Binding var shelf: StockShelf
    /// Every card of the strip: a shelf with none of them is dimmed.
    let all: [StockPreviewCard]
    /// The Mac column's (2026-11-11): on its strip's folding header, which already names the strip, the shelf alone in
    /// Edit's pill size — 22 pt tall, 11.5 pt type.
    var small = false

    var body: some View {
        Menu {
            ForEach(shelves) { s in
                Button { shelf = s } label: {
                    if s == shelf { Label(s.title, systemImage: "checkmark") } else { Text(s.title) }
                }
                .disabled(s.cards(all).isEmpty)
            }
        } label: {
            if small {
                HStack(spacing: 4) {
                    Text(shelf.title).font(Theme.Font.ui(11.5, .medium)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(Theme.text).padding(.horizontal, 9).frame(height: 22)
                .background(Theme.card, in: Capsule())
                .contentShape(Capsule())
                .fixedSize()
            } else {
                HStack(spacing: 6) {
                    Text(title + " · " + shelf.title).font(Theme.Font.ui(13, .semibold)).lineLimit(1)
                    Icon(.chevronDown, size: 11)
                }
                .foregroundStyle(Theme.text).padding(.horizontal, 12).frame(height: 30)
                .background(Theme.card, in: Capsule())
                .frame(minHeight: 44).contentShape(Rectangle())
            }
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(title)
        .accessibilityValue(shelf.title)
    }
}

/// One strip of cards, each the frame through its film and paper: Develop's
/// film and paper rows, and the Enlarger page's papers. Its scrolling is
/// `StripScroller`'s and its card's frame `StripCard`'s, which Format's 尺寸
/// Size strip wears too (`FilmSizeSection`, 2026-11-11).
struct StockPreviewRow: View {
    let session: OpenFrameSession
    let strip: StockStrip
    /// The row's cards, its shelf's, in the strip's order.
    let cards: [StockPreviewCard]
    /// The stock chosen on this row: the frame's film, or its paper.
    let selected: String
    var compact = false
    /// The rows the cards are laid in, top to bottom and then along, as one strip that scrolls sideways.
    var rows = 1
    /// The slots of the cards on screen; the page that holds the row asks for those.
    @Binding var visible: Set<String>
    /// Whether a card is offered beyond what the strip can render (the film row's shelf, for
    /// the papers): one it does not serve is greyed, as a paper that cannot print the film.
    var serves: (StockPreviewCard) -> Bool = { _ in true }
    /// False with Apply Film Emulation off: every card is still and grey — no picture asked for, no
    /// spinner (the owner, 2026-10-21: "It still says it's rotating and that's causing a lot of confusion").
    var active = true
    @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 11

    /// The row's height: its cards', 8 pt between them, and the 3 pt either side the selection frame needs.
    static func height(compact: Bool, rows: Int = 1) -> CGFloat {
        StripScroller<String, EmptyView>.height(cardHeight: StripCard<EmptyView>.size(compact: compact).height, rows: rows)
    }

    var body: some View {
        // The scroll target is the stock, not the rendered pair.
        // Changing film keeps paper targets laid out, so scrollTo
        // can reveal its new recommendation in the same update.
        let byStock = Dictionary(cards.map { ($0.stock, $0) }, uniquingKeysWith: { a, _ in a })
        // The strip's papers once a row, not once a card's question: `paperCards` filters the catalog each time it is
        // read, and each card asked it four times (~40 ms of a switch to another photograph's row, Debug, `sample`).
        let papers = strip.paperCards
        let live: (StockPreviewCard) -> Bool = { [active, serves] card in
            active && (card.strip == .film || papers.contains(card)) && serves(card)
        }
        return StripScroller(ids: cards.map(\.stock), selected: selected,
                             cardHeight: StripCard<EmptyView>.size(compact: compact).height, rows: rows,
                             onPlace: { stock, place in
                                 guard let card = byStock[stock] else { return }
                                 // A greyed card is never asked for: nothing is rendered on a paper that cannot print the film.
                                 if place != .off, live(card) { visible.insert(card.slot) } else { visible.remove(card.slot) }
                             }) { stock in
            if let card = byStock[stock] { cell(card, live: live(card)) }
        }
    }

    /// One card's button. Its own function, not the `ForEach` closure: as one expression the
    /// chain below is past what Xcode 26's type checker finishes in time (GitHub's macos-26
    /// image, 2026-11-08); Xcode 27 managed it.
    private func cell(_ card: StockPreviewCard, live: Bool) -> some View {
        Button {
            // The chosen card again changes nothing (`StockPreviewRules.pick`).
            let p = session.edit.params
            switch StockPreviewRules.pick(card, film: p.filmStock, paper: StockPreviewRules.chosenPaper(p)) {
            case .film(let film): session.change { $0.params.load(film: film) }
            case .paper(let paper): session.change { $0.params.print(on: paper) }
            case .digitalIntermediate: session.change { $0.params.scanFilm = false; $0.params.digitalIntermediate = true }
            case nil: break
            }
        } label: {
            cardView(card, selected: card.stock == selected, live: live)
        }
        .buttonStyle(.plain)
            .disabled(!live)
            .accessibilityLabel(accessibilityName(card))
            .accessibilityIdentifier("stock-preview." + card.slot)
            .accessibilityValue(live && strip.state(card).isRendering ? L("Developing") : "")
            .accessibilityAddTraits(card.stock == selected ? .isSelected : [])
            .accessibilityAction(named: L("Retry")) { strip.refresh() }
            .contextMenu { if live { Button(L("Retry")) { strip.refresh() } } }
    }

    /// The card's name, and on a paper card the film's recommended paper says so.
    private func accessibilityName(_ card: StockPreviewCard) -> String {
        let name: String = StockCatalog.shared.stock(card.stock)?.name ?? (card.isDigitalIntermediate ? L("Digital Intermediate") : card.stock)
        let recommended = card.strip == .paper && StockCatalog.shared.isRecommendedPairing(film: card.film, paper: card.stock)
        return recommended ? name + L(", the film's own paper") : name
    }

    private func cardView(_ card: StockPreviewCard, selected: Bool, live: Bool) -> some View {
        let state: StockPreviewState? = live ? strip.state(card) : nil
        let stock = StockCatalog.shared.stock(card.stock)
        let size = StripCard<EmptyView>.size(compact: compact)
        return StripCard(compact: compact, selected: selected, live: live) {
            Rectangle().fill(stock?.color ?? Theme.card)
            if let image = state?.image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: size.width, height: size.height).clipped()
            }
            StripCardCaption(title: stock?.shortName ?? (card.isDigitalIntermediate ? L("Digital Intermediate") : card.stock),
                             size: labelSize) {
                if card.strip == .paper, StockCatalog.shared.isRecommendedPairing(film: card.film, paper: card.stock) {
                    Circle().fill(StockCatalog.shared.stock(card.film)?.color ?? .white).frame(width: 5, height: 5).padding(.bottom, 3)
                }
            }
            if state?.isRendering == true {
                ProgressView().tint(.white).scaleEffect(0.65).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state == .failed {
                Image(systemName: "arrow.clockwise").font(.system(size: 10)).padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }
}

/// A strip's sideways row of cards (out of `StockPreviewRow`, 2026-11-11, so Format's 尺寸 Size strip is
/// the film and paper rows' own): laid in `rows` rows, scrolled by the wheel and the trackpad, opened on its
/// chosen card, and moved only when a newly chosen card cannot be seen (`StockPreviewRules.reveal`).
struct StripScroller<ID: Hashable, Cell: View>: View {
    let ids: [ID]
    /// The chosen card's id; nil when no card is (a size the strip has no card for).
    let selected: ID?
    let cardHeight: CGFloat
    var rows = 1
    /// Each laid-out card's place in the row's viewport, as it changes: a stock row asks for the cards on screen.
    var onPlace: (ID, StripPlacement) -> Void = { _, _ in }
    @ViewBuilder let cell: (ID) -> Cell
    /// Each laid-out card's place in its row's viewport, by id: whether a
    /// change of the chosen card moves the row (`StockPreviewRules.reveal`).
    @State private var placement: [ID: StripPlacement] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The row's height: its cards', 8 pt between them, and the 3 pt either side the selection frame needs.
    static func height(cardHeight: CGFloat, rows: Int = 1) -> CGFloat {
        CGFloat(rows) * cardHeight + CGFloat(max(rows - 1, 0)) * 8 + 6
    }

    var body: some View {
        GeometryReader { viewport in
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                Group {
                    if rows > 1 {
                        LazyHGrid(rows: Array(repeating: GridItem(.fixed(cardHeight), spacing: 8), count: rows),
                                  spacing: 8) { cells(width: viewport.size.width) }
                    } else {
                        LazyHStack(spacing: 8) { cells(width: viewport.size.width) }
                    }
                }.padding(.horizontal, 16).padding(.vertical, 3)
                // the wheel and the trackpad move the
                // row, wheel down to the right (`MacWheelRow.swift`).
                .macWheelScrollsRow()
            }
            .scrollIndicators(.hidden)
            .onAppear { if let selected { proxy.scrollTo(selected, anchor: .center) } }
            // Only a chosen card the finger cannot see moves (`StockPreviewRules.reveal`):
            // re-centring a tapped card slid its neighbour under the finger. Decided
            // after the update's layout, so a paper row just laid out for a new film
            // reads its cards' places as they now are.
            .onChange(of: selected) { _, id in
                guard let id else { return }
                DispatchQueue.main.async {
                    switch StockPreviewRules.reveal(placement[id]) {
                    case .stay: break
                    case .nearest: withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(id) }
                    case .centre: proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        }.frame(height: Self.height(cardHeight: cardHeight, rows: rows))
    }

    /// The cards, laid by the row or the grid that holds them.
    @ViewBuilder private func cells(width: CGFloat) -> some View {
        ForEach(ids, id: \.self) { id in
            cell(id).id(id)
                .onGeometryChange(for: StripPlacement.self) { geo in
                    let rect = geo.frame(in: .scrollView(axis: .horizontal))
                    return .of(minX: rect.minX, maxX: rect.maxX, width: width)
                } action: { place in
                    placement[id] = place
                    onPlace(id, place)
                }
                // A card the lazy row lets go of has no place: a choice of it is brought to the middle.
                .onDisappear { placement[id] = nil }
        }
    }
}

/// A strip's card: its picture under the content, cut to the card's rounded corners, the chosen one
/// ringed, a greyed one still and grey. Develop's film and paper cards, and Format's size cards.
struct StripCard<Content: View>: View {
    var compact = false
    let selected: Bool
    let live: Bool
    @ViewBuilder let content: () -> Content

    static func size(compact: Bool) -> CGSize { compact ? CGSize(width: 96, height: 64) : CGSize(width: 100, height: 84) }

    var body: some View {
        let size = Self.size(compact: compact)
        ZStack(alignment: .bottomLeading) { content() }
            .frame(width: size.width, height: size.height)
            .clipped().clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).stroke(selected ? Theme.selectionFrame : .clear, lineWidth: 2) }
            .saturation(live ? 1 : 0)
            .opacity(live ? 1 : Theme.disabledOpacity)
    }
}

/// A strip card's name: white on the shade at its foot, after whatever leads it (a paper's film dot).
struct StripCardCaption<Leading: View>: View {
    let title: String
    let size: CGFloat
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: 3) {
                leading()
                Text(title).font(Theme.Font.ui(size, .semibold))
                    .foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }.padding(6)
        }
    }
}

extension StripCardCaption where Leading == EmptyView {
    init(title: String, size: CGFloat) { self.init(title: title, size: size) { EmptyView() } }
}
