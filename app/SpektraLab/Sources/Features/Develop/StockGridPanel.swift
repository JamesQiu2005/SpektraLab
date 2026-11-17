//  StockGridPanel.swift — the desktop's Film and Paper strips as grids (the owner, 2026-11-16, 2.4.1).
//
//  The request is quoted in `Services/StockPreviewGrid.swift`, which holds everything here that is a rule: the
//  order, the makers' groups, which cards wear the CINE pill, how many cards go across a width, and how the
//  column's room is divided. This file draws it, in the column's Film & Paper (`StockPreviewPanel(room:)`):
//
//  - **A strip is a grid that scrolls up and down** (`StockGrid`), its cards under their makers' names. A name
//    is held at the top of the strip while its cards scroll under it, so a strip one row tall still says whose
//    films it is showing. The column scrolls the whole panel as before; a wheel over a strip is the strip's.
//  - **A card is its picture and, under it, its name** (`StockGridCard`), as the library's tiles keep what is set
//    on a picture under it. The chosen card's ring is round the picture; a favourite's star is at the picture's top
//    right and a failed card's arrow on its left, as on the old card; **a cine stock wears the CINE pill at the
//    picture's top left**, in the accent; a paper the film recommends wears the film's dot before its name. A
//    greyed card (a paper that cannot print the film) is still and grey and keeps its menu.
//  - **Only the cards on screen are asked for**: the rows in the strip's window where it is scrolled to
//    (`StockGridLayout.shown`), so a strip scrolled past is not rendered.
//  - **A strip never rests looking broken** (the review of 2026-11-16; `StockGridLayout`): a card chosen where it
//    could not be seen is brought to its row's rest, straight under its maker's name, never to the middle; the
//    strip's foot is a rest too; and a row whose pictures are wholly under the held name is not drawn, so a card
//    goes under the name as one thing, its name with its picture. A card that is wholly seen is never moved
//    (`StockPreviewRules.reveal`'s rule: a tapped card never moves under the pointer).
//  - **A strip's grip is the line under its cards** (`StripSplitGrip`): dragged, it sizes the strip above it.
//  - **A column made wider or narrower re-lays the cards**: the chosen card is brought back into the strip's
//    window where the new rows took it out.

import SwiftUI
import UIKit

/// One strip as the desktop's grid: Develop's film cards, or its paper cards.
struct StockGrid: View {
    let session: OpenFrameSession
    let strip: StockStrip
    /// The strip's cards, its shelf's, in the strip's order (by maker, then by name).
    let cards: [StockPreviewCard]
    /// The stock chosen on this strip: the frame's film, or its paper.
    let selected: String
    /// The column's width, in the page's points: the cards across are its (`StockGridRule.columns`).
    let width: CGFloat
    /// "film" or "paper": the grid's accessibility identifier's tail.
    let name: String
    /// The slots of the cards on screen; the page that holds the grid asks for those.
    @Binding var visible: Set<String>
    /// Whether a card is offered beyond what the strip can render (the film strip's shelf, for the papers).
    var serves: (StockPreviewCard) -> Bool = { _ in true }
    /// False with Apply Film Emulation off: every card is still and grey.
    var active = true

    /// Where the strip is scrolled to and how tall its window is, as they are now. Not view state: they change
    /// with every step of a scroll and draw nothing (what they draw is `shown`, which changes row by row).
    /// And the card last tapped in this strip: its choice is revealed as a tap's, any other as one made elsewhere.
    private final class Scrolled { var offset = 0.0; var window = 0.0; var tapped = "" }
    @State private var scrolled = Scrolled()
    /// What the strip shows where it is: the maker's name held at its top, the rows not drawn, the rows asked for
    /// (`StockGridLayout.Shown`). Nil until the strip has told where it is: its top.
    @State private var shown: StockGridLayout.Shown?
    @State private var position = ScrollPosition(y: 0)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A line of the grid: a maker's name, or a row of its cards (the row's place among the layout's rows).
    private enum Line: Identifiable {
        case brand(String)
        case row(Int)
        var id: String {
            switch self {
            case .brand(let name): "brand:" + name
            case .row(let at): "row:\(at)"
            }
        }
    }

    /// The grid's lines as `StockGridLayout` lays them: each maker's name (where it has one), then its rows.
    private func lines(_ groups: [StockBrandGroup], across: Int) -> [Line] {
        var row = 0
        return groups.flatMap { group -> [Line] in
            let rows = (group.cards.count + across - 1) / across
            defer { row += rows }
            return (group.brand.isEmpty ? [] : [.brand(group.brand)]) + (row..<(row + rows)).map(Line.row)
        }
    }

    var body: some View {
        let groups = StockPreviewRules.groups(cards)
        // The strip's papers once a grid, not once a card's question (`StockPreviewRow`: `paperCards` filters the
        // catalogue each time it is read).
        let papers = strip.paperCards
        let live: (StockPreviewCard) -> Bool = { [active, serves] card in
            active && (card.strip == .film || papers.contains(card)) && serves(card)
        }
        let across = StockGridRule.columns(width: Double(width))
        let cell = CGFloat(StockGridRule.cell(width: Double(width)))
        let layout = StockGridLayout(groups: groups.map { (headed: !$0.brand.isEmpty, count: $0.cards.count) }, width: Double(width))
        let named = groups.filter { !$0.brand.isEmpty }
        return GeometryReader { viewport in
            let window = Double(viewport.size.height)
            let now = shown ?? layout.shown(at: 0, window: window)
            ScrollView(.vertical) {
                // Every card is laid, not only those on screen: forty at the most, so the strip is exactly as tall
                // inside as the rule says (what a grip's drag is held to), and only the pictures are lazy.
                VStack(alignment: .leading, spacing: CGFloat(StockGridRule.gap)) {
                    ForEach(lines(groups, across: across)) { line in
                        switch line {
                        case .brand(let brand): StockBrandHeader(name: brand)
                        case .row(let at):
                            // A card goes under the held name as one thing: a row whose pictures are wholly under
                            // it is not drawn, so its names never show without them (`StockGridLayout.Shown.gone`).
                            rowLine(layout.rows[at], cell: cell, live: live)
                                .opacity(at < now.gone ? 0 : 1)
                                .allowsHitTesting(at >= now.gone)
                        }
                    }
                }
                .padding(.horizontal, CGFloat(StockGridRule.margin))
                .padding(.top, CGFloat(StockGridRule.padTop)).padding(.bottom, CGFloat(StockGridRule.padBottom))
                // The room under the last card that lets the strip reach its foot: a row straight under the name.
                .padding(.bottom, CGFloat(layout.trailing(window: window)))
                .frame(maxWidth: .infinity, alignment: .leading)
                // A scroll over the strip is decided and moved by the app, the strip's or the column's, and left at a
                // row's rest (`MacWheelRow.swift`, round 4); its indicator is drawn at the panel's left edge there.
                .macScrollPassesToColumn(rests: { tall in
                    layout.rows.indices.map { min(layout.rest($0), layout.foot(window: tall)) } + [layout.foot(window: tall)]
                })
            }
            // The strip's indicator is at the panel's left (the owner, round 4): UIKit's on the right is not shown. On the
            // Mac this hides only UIKit's own indicator, not AppKit's scroller Catalyst draws: `StripIndicator` hides that.
            .scrollIndicators(.hidden)
            .scrollPosition($position)
            // Where the strip is, at every step of a scroll: kept, not drawn.
            .onScrollGeometryChange(for: CGPoint.self) { CGPoint(x: $0.containerSize.height, y: $0.contentOffset.y) } action: { _, at in
                scrolled.window = Double(at.x)
                scrolled.offset = Double(at.y)
            }
            // What it shows there, as that changes: a name held or pushed, a row gone under it, a row come in.
            .onScrollGeometryChange(for: StockGridLayout.Shown.self) { layout.shown(at: Double($0.contentOffset.y), window: Double($0.containerSize.height)) } action: { _, next in
                show(next, layout: layout)
            }
            .onAppear {
                scrolled.window = window
                rest(on: selected, layout: layout, window: window)
            }
            // The cards are others (another shelf's, another film's papers), or laid in other rows.
            .onChange(of: layout) { _, next in
                show(next.shown(at: scrolled.offset, window: scrolled.window > 0 ? scrolled.window : window), layout: next)
            }
            .onChange(of: viewport.size.height) { _, tall in
                show(layout.shown(at: scrolled.offset, window: Double(tall)), layout: layout)
            }
            // Decided after the update's layout, so a paper grid just laid out for a new film is where it now is
            // (`StripScroller`).
            .onChange(of: selected) { _, id in
                DispatchQueue.main.async { reveal(id, layout: layout, window: window) }
            }
            // More or fewer cards across: the rows are others, and the chosen card may have left the window.
            .onChange(of: across) { _, _ in
                DispatchQueue.main.async { reveal(selected, layout: layout, window: window) }
            }
            // The maker's name held at the top while its cards scroll under it, pushed out by the next one. Its
            // ground covers the strip from its top to the name's foot: what scrolls under it is cut there. **It takes
            // the click there** (round 4, the owner's "the status bar overlap … is creating some overlap issues"): a
            // card under the name is not chosen through it, and a card's visible part under the name is the card's. A
            // scroll over it is still the strip's (`MacNestedScrolls` decides by the strip's place, not the hit view).
            .overlay(alignment: .top) {
                if let held = now.held, held < named.count {
                    StockBrandHeader(name: named[held].brand).padding(.horizontal, CGFloat(StockGridRule.margin))
                        .background(Theme.background)
                        .contentShape(Rectangle())
                        .onTapGesture {}
                        .offset(y: CGFloat(now.push)).accessibilityHidden(true)
                }
            }
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v5.develop.grid." + name)
    }

    /// What the strip shows where it now is: drawn (the held name, the rows gone under it), and its cards asked for.
    private func show(_ next: StockGridLayout.Shown, layout: StockGridLayout) {
        if shown != next { shown = next }
        let asked = Set(next.rows.flatMap { layout.rows[$0].cards }.filter { $0 < cards.count }.map { cards[$0].slot })
        let mine = Set(cards.map(\.slot))
        let kept = visible.subtracting(mine).union(asked)
        if kept != visible { visible = kept }
    }

    private func row(of id: String, in layout: StockGridLayout) -> Int? {
        cards.firstIndex { $0.stock == id }.flatMap(layout.row(ofCard:))
    }

    /// The strip as it opens: the chosen card's row at rest, straight under its maker's name.
    private func rest(on id: String, layout: StockGridLayout, window: Double) {
        let to = row(of: id, in: layout).map { min(layout.rest($0), layout.foot(window: window)) } ?? 0
        scrolled.offset = to
        position.scrollTo(y: CGFloat(to))
        show(layout.shown(at: to, window: window), layout: layout)
    }

    /// A newly chosen card (`StockGridLayout.reveal`): left where it is when it is wholly seen; brought the least
    /// way up when it was tapped and only the strip's foot cuts it; otherwise to its rest — straight under its
    /// maker's name, no row cut above it.
    private func reveal(_ id: String, layout: StockGridLayout, window: Double) {
        guard let row = row(of: id, in: layout) else { return }
        let tapped = scrolled.tapped == id
        scrolled.tapped = ""
        let to = layout.reveal(row: row, from: scrolled.offset, window: scrolled.window > 0 ? scrolled.window : window, tapped: tapped)
        guard abs(to - scrolled.offset) > 0.5 else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { position.scrollTo(y: CGFloat(to)) }
    }

    /// A row of cards, each as wide as the rule's card.
    private func rowLine(_ row: StockGridLayout.Row, cell: CGFloat, live: @escaping (StockPreviewCard) -> Bool) -> some View {
        HStack(alignment: .top, spacing: CGFloat(StockGridRule.gap)) {
            ForEach(cards[row.cards.clamped(to: 0..<cards.count)], id: \.stock) { card in
                self.cell(card, live: live(card)).frame(width: cell)
            }
        }
    }

    /// One card's button. Its own function, as `StockPreviewRow`'s is (Xcode 26's type checker, 2026-11-08).
    private func cell(_ card: StockPreviewCard, live: Bool) -> some View {
        let chosen = card.stock == selected
        return StockCardButton(session: session, strip: strip, card: card, selected: chosen, live: live,
                               tapped: { scrolled.tapped = card.stock }) { state, starred in
            StockGridCard(card: card, state: state, starred: starred, selected: chosen, live: live,
                          imageHeight: CGFloat(StockGridRule.imageHeight(width: Double(width))))
        }
    }
}

/// A maker's name over its cards: small capitals and a hairline to the strip's edge. It stays at the strip's top
/// while its cards scroll under it, so it is drawn on the column's ground.
struct StockBrandHeader: View {
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            Text(name.uppercased()).font(Theme.Font.ui(10, .semibold)).tracking(0.8)
                .foregroundStyle(Theme.secondaryText).lineLimit(1).fixedSize()
            Rectangle().fill(Theme.rule).frame(height: 0.5)
        }
        .frame(height: CGFloat(StockGridRule.brandHeader))
        // Past the cards' edges by the ring's width, so a chosen card's ring is covered with its card.
        .padding(.horizontal, 3)
        .background(Theme.background)
        .padding(.horizontal, -3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A card of the desktop's grid: the picture, and its name under it.
struct StockGridCard: View {
    let card: StockPreviewCard
    /// What the card shows; nil while it is greyed.
    let state: StockPreviewState?
    let starred: Bool
    let selected: Bool
    let live: Bool
    let imageHeight: CGFloat

    private static let radius: CGFloat = 6

    var body: some View {
        VStack(spacing: CGFloat(StockGridRule.captionGap)) {
            picture
            caption
        }
        .contentShape(Rectangle())
    }

    private var catalog: StockCatalog { .shared }

    private var picture: some View {
        Rectangle().fill(catalog.stock(card.stock)?.color ?? Theme.card)
            .frame(maxWidth: .infinity).frame(height: imageHeight)
            .overlay { if let image = state?.image { Image(uiImage: image).resizable().scaledToFill() } }
            .overlay { if state?.isRendering == true { ProgressView().tint(.white).scaleEffect(0.6) } }
            .overlay(alignment: .topLeading) {
                if StockPreviewRules.wearsCinePill(card) {
                    CinePill().background(Capsule().fill(Color.black.opacity(0.5))).padding(4)
                }
            }
            // The picture's top right holds a failed card's arrow and a favourite's star, the arrow on the star's left.
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 3) {
                    if state == .failed { Image(systemName: "arrow.clockwise").font(.system(size: 9)).foregroundStyle(.white) }
                    if starred { StockStar() }
                }
                .padding(4)
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.radius))
            .overlay { RoundedRectangle(cornerRadius: Self.radius).stroke(selected ? Theme.selectionFrame : .clear, lineWidth: 2) }
            .saturation(live ? 1 : 0)
            .opacity(live ? 1 : Theme.disabledOpacity)
    }

    /// The name, two lines at the most, and before it the film's dot on the paper the film recommends.
    private var caption: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if card.strip == .paper, catalog.isRecommendedPairing(film: card.film, paper: card.stock) {
                Circle().fill(catalog.stock(card.film)?.color ?? .white).frame(width: 5, height: 5)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2 }
            }
            Text(card.shownName)
                .font(Theme.Font.ui(10, selected ? .semibold : .medium))
                .foregroundStyle(selected ? Theme.text : Theme.secondaryText)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: CGFloat(StockGridRule.caption), alignment: .top)
        .opacity(live ? 1 : Theme.disabledOpacity)
    }
}

/// The line under a strip's cards, dragged up and down: 9 pt tall, a short bar in its middle that lights under the
/// pointer (with the Mac's resize cursor) and while it is dragged. VoiceOver adjusts it in steps of 24 pt.
///
/// **Round 4 (the owner's third hand test, 2026-11-16: "the split line … is not really draggable")**: round 3's grip was
/// SwiftUI's `dragBesideScroll` recogniser in the column's scroll view, read in the grip's own points while the grip
/// moved with the height it dragged. Under a mouse's press and drag posted into the app (`MacStockGridHandCheck`) it
/// never moved the strip, at 100 %, 150 % and 80 % alike, while its hover and cursor worked. So the pointer is UIKit's
/// own here (`GripPointerView`, `MaskPress`: recognised at the press, never prevented by the column's recognisers):
/// **the drag is read in the window's points from where it was pressed**, and the travel turned into the grip's own
/// points by how large the window draws it (the interface scale), so the strip's foot follows the pointer 1:1 whatever
/// the scale and however the grip has moved since. `moved(start, travel)`: the height when the press began and the
/// travel since, in the page's points. Its reach is 6 pt past the line on each side, over the strip's foot and the
/// next header (`reach`), so a press near the line takes it.
struct StripSplitGrip: View {
    let label: String
    let value: Double
    let began: () -> Void
    let moved: (Double, Double) -> Void
    let ended: () -> Void

    static let height: CGFloat = 9
    /// How far past the line, up and down, a press still takes the grip.
    static let reach: CGFloat = 6

    @State private var dragging = false
    @State private var hot = false

    var body: some View {
        Color.clear
            .frame(height: Self.height)
            .overlay {
                Capsule().fill(hot || dragging ? Theme.dim : Theme.rule)
                    .frame(width: 36, height: 3)
                    .allowsHitTesting(false)
            }
            .overlay {
                GripPointer(value: value,
                            hovered: { hot = $0 },
                            began: { dragging = true; began() },
                            moved: moved,
                            ended: { dragging = false; ended() })
                    .padding(.vertical, -Self.reach)
            }
            .help(L("Drag to resize"))
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(String(Int(value)))
            .accessibilityAdjustableAction { direction in
                began()
                switch direction {
                case .increment: moved(value, 24)
                case .decrement: moved(value, -24)
                @unknown default: break
                }
                ended()
            }
    }
}

/// The grip's pointer in UIKit: the hover (the resize cursor, set again at every move since UIKit sets its own), and
/// the press and its drag in the window's points (`StripSplitGrip`).
private struct GripPointer: UIViewRepresentable {
    var value: Double
    var hovered: (Bool) -> Void
    var began: () -> Void
    var moved: (Double, Double) -> Void
    var ended: () -> Void

    func makeUIView(context: Context) -> GripPointerView { GripPointerView() }
    func updateUIView(_ v: GripPointerView, context: Context) {
        v.value = value; v.hovered = hovered; v.began = began; v.moved = moved; v.ended = ended
    }
}

final class GripPointerView: UIView {
    var value = 0.0
    var hovered: (Bool) -> Void = { _ in }
    var began: () -> Void = {}
    var moved: (Double, Double) -> Void = { _, _ in }
    var ended: () -> Void = {}
    /// The press: the height then, and the pointer's place in the window then.
    private var press: (height: Double, y: CGFloat)?
    private var draggedYet = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        accessibilityIdentifier = "v5.develop.grip.pointer"
        isAccessibilityElement = false
        addGestureRecognizer(MaskPress(target: self, action: #selector(pressed(_:))))
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovering(_:)))
        addGestureRecognizer(hover)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The press decided at its own point (`PressPoint`): the pointer's area hit-test would otherwise give a press on
    /// this thin line to the cards and the header round it.
    private var pressPoint = PressPoint()
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard bounds.insetBy(dx: -pressPoint.reach, dy: -pressPoint.reach).contains(point) else { return false }
        return pressPoint.inside(point, with: event) { [unowned self] p in bounds.contains(p) }
    }

    /// How many of the window's points one of this view's is drawn at: the interface scale's.
    private var drawn: CGFloat {
        guard let window else { return 1 }
        return convert(bounds, to: window).height / max(bounds.height, 1)
    }

    #if DEBUG
    /// The last hover a grip saw (`MacStockGridHandCheck`): true while the pointer is over it.
    nonisolated(unsafe) static var lastHover: Bool?
    #endif

    @objc private func hovering(_ g: UIHoverGestureRecognizer) {
        #if DEBUG
        Self.lastHover = g.state == .began || g.state == .changed
        #endif
        switch g.state {
        case .began, .changed: hovered(true); MacCursor.resize(sideways: false)
        default: hovered(false); if press == nil { MacCursor.arrow() }
        }
    }

    @objc private func pressed(_ g: MaskPress) {
        guard let window else { return }
        let y = g.location(in: window).y
        switch g.state {
        case .began:
            press = (value, y)
            draggedYet = false
            MacCursor.resize(sideways: false)
        case .changed:
            _ = g.take()
            guard let press else { return }
            let travel = (y - press.y) / max(drawn, 0.01)
            // A press that does not move is not a drag: nothing is sized, nothing kept at its lift.
            guard draggedYet || abs(travel) >= 1 else { return }
            if !draggedYet { draggedYet = true; began() }
            moved(press.height, Double(travel))
            MacCursor.resize(sideways: false)
        default:
            _ = g.take()
            if let press, draggedYet {
                moved(press.height, Double((y - press.y) / max(drawn, 0.01)))
                ended()
            }
            press = nil
            draggedYet = false
        }
    }
}
