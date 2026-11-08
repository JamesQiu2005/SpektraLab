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
    /// pill with a bare chevron at the right of that line that folds its cards away — "no pill outside" —
    /// kept across launches (`DevelopPanelPrefs`). A wide window's; the host's two pills share a line.
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
    static func height(rows: Int, compact: Bool, filmFolded: Bool = false, paperFolded: Bool = false) -> CGFloat {
        let spacing: CGFloat = compact ? 6 : 10, pill: CGFloat = 44, toggle: CGFloat = 44
        let row = StockPreviewRow.height(compact: compact, rows: rows) + spacing
        return 8 + 2 * pill + (filmFolded ? 0 : row) + (paperFolded ? 0 : row) + DecodeSection.height(.exposure)
            + toggle + 3 * spacing
    }

    /// Apply Film Emulation (`FrameEdit.appliesFilm`): off, the film and the paper are greyed and the
    /// frame is Apple's own decode. A half-frame pair is a piece of film: it has no switch.
    private var appliesFilm: Bool { session.edit.appliesFilm }

    var body: some View {
        VStack(spacing: compact ? 6 : 10) {
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
        .padding(.top, 8)
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
    }

    /// The owner, 2026-10-21: "a on / off switch under film exposure called 'apply film emulation'".
    private var filmSwitch: some View {
        HStack {
            Text(L("Apply Film Emulation")).font(Theme.Font.ui(13, .semibold)).foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            SpkToggle(isOn: Binding(get: { session.edit.appliesFilm },
                                    set: { on in session.change { $0.setAppliesFilm(on) } }))
                .accessibilityLabel(L("Apply Film Emulation"))
                .accessibilityIdentifier("v5.develop.apply-film")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    @ViewBuilder private var strips: some View {
            if rows > 1 || foldable {
                HStack(spacing: 8) {
                    filmPill.rowEnabled(appliesFilm || !foldable)
                    Spacer(minLength: 0)
                    if let crop { cropButton(crop).rowEnabled(appliesFilm || !foldable) }
                    if foldable { foldButton(L("Film"), folded: filmFolded) { prefs.filmRowCollapsed.toggle() } }
                }.padding(.horizontal, 16)
                if !filmFolded { filmRow.rowEnabled(appliesFilm || !foldable) }
                HStack {
                    paperPill.rowEnabled(appliesFilm || !foldable)
                    Spacer(minLength: 0)
                    if foldable { foldButton(L("Paper"), folded: paperFolded) { prefs.paperRowCollapsed.toggle() } }
                }.padding(.horizontal, 16)
                if !paperFolded { paperRow.rowEnabled(appliesFilm || !foldable) }
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

    private var filmPill: some View {
        StockShelfPill(title: L("Film"), shelves: StockShelf.film, shelf: $filmShelf, all: strip.filmCards)
    }
    private var paperPill: some View {
        StockShelfPill(title: L("Paper"), shelves: StockShelf.paper, shelf: $paperShelf, all: paperCards)
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

    /// A strip's fold: the chevron alone, no pill round it — down while its cards show, right when folded.
    private func foldButton(_ title: String, folded: Bool, toggle: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { toggle() }
        } label: {
            Icon(.chevronDown, size: 13, color: Theme.secondaryText)
                .rotationEffect(.degrees(folded ? -90 : 0))
                .frame(width: 32, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(folded ? L("Show the cards") : L("Fold the cards away"))
        .accessibilityValue(title)
        .accessibilityIdentifier("v5.develop.fold." + (title == L("Film") ? "film" : "paper"))
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

    var body: some View {
        Menu {
            ForEach(shelves) { s in
                Button { shelf = s } label: {
                    if s == shelf { Label(s.title, systemImage: "checkmark") } else { Text(s.title) }
                }
                .disabled(s.cards(all).isEmpty)
            }
        } label: {
            HStack(spacing: 6) {
                Text(title + " · " + shelf.title).font(Theme.Font.ui(13, .semibold)).lineLimit(1)
                Icon(.chevronDown, size: 11)
            }
            .foregroundStyle(Theme.text).padding(.horizontal, 12).frame(height: 30)
            .background(Theme.card, in: Capsule())
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(title)
        .accessibilityValue(shelf.title)
    }
}

/// One strip of cards, each the frame through its film and paper: Develop's
/// film and paper rows, and the Enlarger page's papers.
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
    /// Each laid-out card's place in its row's viewport, by slot: whether a
    /// change of the chosen card moves the row (`StockPreviewRules.reveal`).
    @State private var placement: [String: StripPlacement] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 11

    private func live(_ card: StockPreviewCard) -> Bool { active && strip.isLive(card) && serves(card) }

    /// The row's height: its cards', 8 pt between them, and the 3 pt either side the selection frame needs.
    static func height(compact: Bool, rows: Int = 1) -> CGFloat {
        CGFloat(rows) * cardHeight(compact) + CGFloat(max(rows - 1, 0)) * 8 + 6
    }
    private static func cardHeight(_ compact: Bool) -> CGFloat { compact ? 64 : 84 }

    var body: some View {
        GeometryReader { viewport in
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                Group {
                    if rows > 1 {
                        LazyHGrid(rows: Array(repeating: GridItem(.fixed(Self.cardHeight(compact)), spacing: 8),
                                              count: rows),
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
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
            // Only a chosen card the finger cannot see moves (`StockPreviewRules.reveal`):
            // re-centring a tapped card slid its neighbour under the finger. Decided
            // after the update's layout, so a paper row just laid out for a new film
            // reads its cards' places as they now are.
            .onChange(of: selected) { _, id in
                DispatchQueue.main.async {
                    let slot = cards.first { $0.stock == id }?.slot
                    switch StockPreviewRules.reveal(slot.flatMap { placement[$0] }) {
                    case .stay: break
                    case .nearest: withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(id) }
                    case .centre: proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        }.frame(height: Self.height(compact: compact, rows: rows))
    }

    /// The cards, laid by the row or the grid that holds them.
    @ViewBuilder private func cells(width: CGFloat) -> some View {
        // The scroll target is the stock, not the rendered pair.
        // Changing film keeps paper targets laid out, so scrollTo
        // can reveal its new recommendation in the same update.
        ForEach(cards, id: \.stock) { card in
            cell(card, width: width)
        }
    }

    /// One card's button. Its own function, not the `ForEach` closure: as one expression the
    /// chain below is past what Xcode 26's type checker finishes in time (GitHub's macos-26
    /// image, 2026-11-08); Xcode 27 managed it.
    private func cell(_ card: StockPreviewCard, width: CGFloat) -> some View {
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
            cardView(card, selected: card.stock == selected, live: live(card))
        }
        .buttonStyle(.plain).id(card.stock)
            .disabled(!live(card))
            .onGeometryChange(for: StripPlacement.self) { geo in
                let rect = geo.frame(in: .scrollView(axis: .horizontal))
                return .of(minX: rect.minX, maxX: rect.maxX, width: width)
            } action: { place in
                placement[card.slot] = place
                // A greyed card is never asked for: nothing is rendered on a paper that cannot print the film.
                if place != .off, live(card) { visible.insert(card.slot) } else { visible.remove(card.slot) }
            }
            // A card the lazy row lets go of has no place: a choice of it is brought to the middle.
            .onDisappear { placement[card.slot] = nil }
            .accessibilityLabel(accessibilityName(card))
            .accessibilityIdentifier("stock-preview." + card.slot)
            .accessibilityValue(live(card) && strip.state(card).isRendering ? L("Developing") : "")
            .accessibilityAddTraits(card.stock == selected ? .isSelected : [])
            .accessibilityAction(named: L("Retry")) { strip.refresh() }
            .contextMenu { if live(card) { Button(L("Retry")) { strip.refresh() } } }
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
        let width: CGFloat = compact ? 96 : 100
        let height: CGFloat = compact ? 64 : 84
        return ZStack(alignment: .bottomLeading) {
            Rectangle().fill(stock?.color ?? Theme.card)
            if let image = state?.image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: width, height: height).clipped()
            }
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: 3) {
                if card.strip == .paper, StockCatalog.shared.isRecommendedPairing(film: card.film, paper: card.stock) {
                    Circle().fill(StockCatalog.shared.stock(card.film)?.color ?? .white).frame(width: 5, height: 5).padding(.bottom, 3)
                }
                Text(stock?.shortName ?? (card.isDigitalIntermediate ? L("Digital Intermediate") : card.stock)).font(Theme.Font.ui(labelSize, .semibold))
                    .foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }.padding(6)
            if state?.isRendering == true {
                ProgressView().tint(.white).scaleEffect(0.65).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state == .failed {
                Image(systemName: "arrow.clockwise").font(.system(size: 10)).padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(width: width, height: height)
        .clipped().clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(selected ? Theme.selectionFrame : .clear, lineWidth: 2) }
        .saturation(live ? 1 : 0)
        .opacity(live ? 1 : Theme.disabledOpacity)
    }
}
