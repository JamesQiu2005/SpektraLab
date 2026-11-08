//  StockCards.swift — the cards of the Film, Frame and Print tabs.
//
//  design/edit_v2 (`gen_edit_v2.film_cards`, `paper_cards`, `size_cards`). Three
//  cards 86 pt wide, each as tall as its page lets it be:
//
//  - **a film** (96): a 38 pt swatch with two rows of perforations (a canister,
//    abstracted), the name, the ISO, the CINE pill. The film is its page's
//    subject, so it keeps nearly all of v1's card;
//  - **a paper** (70): its base with a six-step wedge printed on it, ending in
//    the paper's own black — or, for a cine print film, a perforated positive
//    with four patches on clear base — and its name on two lines. The line every
//    card repeated ("Colour paper") is gone. **The film's own paper carries the
//    film's dot**, as a library tile carries its stock's;
//  - **a film's size** (80): the piece of film to one scale, 0.65 pt to the
//    millimetre, with the frame this picture makes on it, so 110, APS, 135 and
//    120 are seen beside each other as they are. The short side is the film's;
//    the long one follows the picture, as the engine derives it.
//
//  The chosen card wears the white selection frame — never the accent.
//
//  A row shows four whole cards and the edge of a fifth, and scrolls. A card
//  that is not wholly on screen shows its swatch and no words: the drawings'
//  rule is that a word is never cut by the edge of the page.

import SwiftUI

enum CardMetric {
    static let width: CGFloat = 86
    /// The selection frame sits 1.5 pt outside the card, 2 pt wide.
    static let frameOutset = PanelY.Part.cardFrame
}

/// A film's card: swatch with perforations, short name, ISO, the CINE pill.
struct FilmCard: View {
    let stock: Stock

    static let height = PanelY.Film.cardHeight
    private static let swatch: CGFloat = 38

    var body: some View {
        StockCardBody(height: Self.height, swatchHeight: Self.swatch, swatch: stock.color, swatchOpacity: 0.85) {
            Perforations(ink: .black, opacity: 0.28, rows: (4, Self.swatch - 8), height: 4)
        } words: {
            // The drawing's own rule: a long name is set smaller, so it fits.
            DrawnText(stock.shortName, stock.shortName.count > 10 ? 10.5 : 12.5, .semibold, fit: true)
                .spanning(leading: 8, trailing: 6)
                .baseline(59)
            if let iso = stock.isoText {
                DrawnText(iso, 10, .medium, Theme.dim).leading(8).baseline(74)
            }
            if stock.isCine {
                CinePill().leading(8).top(80)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stock.name + (stock.isoText.map { ", " + $0 } ?? ""))
    }
}

/// A paper's card: its base with a step wedge, or a print film's positive.
struct PaperCard: View {
    let stock: Stock
    /// The film this frame is on was made for this paper: the film's colour,
    /// as a dot at the card's foot.
    var ownDot: Color? = nil
    /// Why the paper cannot print the frame's film, where it cannot
    /// (`StockCatalog.whyNotPrinted`): the card is dimmed by its row, and says
    /// this in place of its kind.
    var waits: String? = nil

    static let height = PanelY.Print.cardHeight
    private static let swatch: CGFloat = 28
    /// The wedge printed on a paper's base, its own black at the end (`paper_cards`).
    private static let wedge: [UInt32] = [0xF7F3EC, 0xCFC9BF, 0x9D978D, 0x6B665E, 0x3D3A35, 0x141210]
    /// A cine print film's positive patches on its clear base.
    private static let positive: [UInt32] = [0x2B2722, 0x5D544A, 0x9A8F80, 0xD9CFBF]

    /// "Supera Enduro" set on two lines as the drawing sets it: the first word,
    /// then the rest.
    private var lines: (String, String) {
        let name = stock.shortName
        guard let space = name.firstIndex(of: " ") else { return (name, "") }
        return (String(name[..<space]), String(name[name.index(after: space)...]))
    }

    var body: some View {
        StockCardBody(height: Self.height, swatchHeight: Self.swatch, swatch: stock.color, swatchOpacity: 1) {
            if stock.isCine {
                Perforations(ink: .white, opacity: 0.5, rows: (3, Self.swatch - 6.5), height: 3.5)
                ForEach(0..<Self.positive.count, id: \.self) { k in
                    Rectangle().fill(Color(hex: Self.positive[k]))
                        .frame(width: 11, height: 11)
                        .leading(14 + CGFloat(k) * 14).top(8.5)
                }
            } else {
                ForEach(0..<Self.wedge.count, id: \.self) { k in
                    Rectangle().fill(Color(hex: Self.wedge[k]))
                        .frame(width: 11.7, height: 9)
                        .leading(8 + CGFloat(k) * 11.7).top(13)
                }
            }
        } words: {
            ForEach(Array([lines.0, lines.1].enumerated()), id: \.offset) { i, line in
                DrawnText(line, 12, .semibold, fit: true)
                    // The second line stops short of the dot.
                    .spanning(leading: 8, trailing: i == 1 && ownDot != nil ? 20 : 6)
                    .baseline(i == 0 ? 45 : 59)
            }
            if let ownDot {
                StockDot(color: ownDot, diameter: 6.8).centreX(CardMetric.width - 12).centreY(Self.height - 14.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stock.name + ", " + (waits ?? L(shown: stock.kind)) + (ownDot != nil ? L(", the film's own paper") : ""))
    }
}

/// A film's size: the piece of film to scale, with this picture's frame on it.
struct SizeCard: View {
    let frame: FilmFrame
    /// The photograph, whole: its own shape is what decides the frame's long
    /// side, as the number the engine is sent is derived
    /// (`FilmParams.longEdgeMM`, the desktop's `Session.filmFormatMM`). A crop
    /// is a cut of that frame, not another frame.
    let photo: LibraryFrame

    private var pictureAspect: Double { photo.originalSize.aspect }

    static let height = PanelY.Frame.cardHeight
    /// Points to the millimetre: 120's 61.5 mm of film fills the card's 40 pt.
    static let scale: CGFloat = 40 / 61.5
    /// The film's own width, by type, in millimetres: what the piece is drawn at.
    static func filmWidthMM(_ id: String) -> Double {
        switch id {
        case "110": 16.0
        case "APS": 24.0
        case "135": 35.0
        case "120": 61.5
        default: FilmFrame.named(id).short + 8
        }
    }

    /// The frame's long side on this film, for this picture.
    var longMM: Double { Self.longMM(frame, aspect: pictureAspect) }
    static func longMM(_ frame: FilmFrame, aspect: Double) -> Double {
        frame.short * max(aspect, 1 / max(aspect, 0.0001))
    }
    /// "13 × 17 mm", "56 × 75 mm".
    var sizeText: String {
        let short = frame.short == frame.short.rounded() ? String(format: "%.0f", frame.short) : String(format: "%.1f", frame.short)
        return "\(short) × \(String(format: "%.0f", longMM)) mm"
    }

    var body: some View {
        let k = Self.scale
        let piece = CGSize(width: CGFloat(longMM + 6) * k, height: CGFloat(Self.filmWidthMM(frame.id)) * k)
        let gate = CGSize(width: CGFloat(longMM) * k, height: CGFloat(frame.short) * k)
        let pieceTop = 6 + (40 - piece.height) / 2
        StockCardBody(height: Self.height, swatchHeight: 0, swatch: .clear, swatchOpacity: 0) {
            // The film, its frame, and — on 135 — its perforations: 1.98 × 2.80 mm,
            // 2.00 mm in, 4.75 mm apart (KS).
            RoundedRectangle(cornerRadius: 1).fill(Color(hex: 0x120D09))
                .frame(width: piece.width, height: piece.height)
                .centreX(CardMetric.width / 2).top(pieceTop)
            FramePicture(picture: photo.picture, pointSize: max(gate.width, gate.height), contentMode: .fill)
                // An upright picture lies along the film, as its negative does.
                .frame(width: pictureAspect >= 1 ? gate.width : gate.height, height: pictureAspect >= 1 ? gate.height : gate.width)
                .rotationEffect(.degrees(pictureAspect >= 1 ? 0 : -90))
                .frame(width: gate.width, height: gate.height)
                .clipped()
                .centreX(CardMetric.width / 2).top(pieceTop + (piece.height - gate.height) / 2)
            if frame.id == "135" {
                let pitch = 4.75 * k, hole = CGSize(width: 1.98 * k, height: 2.8 * k)
                let count = Int(piece.width / pitch)
                let first = (CardMetric.width - piece.width) / 2 + (piece.width - CGFloat(count - 1) * pitch - hole.width) / 2
                ForEach(0..<max(count * 2, 0), id: \.self) { i in
                    RoundedRectangle(cornerRadius: 0.35).fill(Theme.card)
                        .frame(width: hole.width, height: hole.height)
                        .leading(first + CGFloat(i % max(count, 1)) * pitch)
                        .top(i < count ? pieceTop + 2.0 * k : pieceTop + piece.height - 4.8 * k)
                }
            }
        } words: {
            DrawnText(L(shown: frame.id), 13, .semibold).leading(8).baseline(61)
            DrawnText(sizeText, 10, .medium, Theme.dim, fit: true).spanning(leading: 8, trailing: 6).baseline(73)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("\(L(shown: frame.id)) film, the frame \(sizeText)"))
    }
}

/// The card's shape: the card colour, the swatch band with its marks, and the
/// words, which are hidden while the card is cut by the edge of the screen.
private struct StockCardBody<Marks: View, Words: View>: View {
    let height: CGFloat
    let swatchHeight: CGFloat
    let swatch: Color
    var swatchOpacity: Double
    @ViewBuilder var marks: () -> Marks
    @ViewBuilder var words: () -> Words
    @Environment(\.cardIsWhole) private var whole

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.card
            // A card with no swatch (a size's) draws its marks over the whole card.
            DrawnBand(width: CardMetric.width, height: swatchHeight > 0 ? swatchHeight : height) {
                if swatchHeight > 0 {
                    swatch.opacity(swatchOpacity).frame(width: CardMetric.width, height: swatchHeight)
                }
                marks()
            }
            DrawnBand(width: CardMetric.width, height: height) { words() }
                .opacity(whole ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: whole)
        }
        .frame(width: CardMetric.width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.cardRadius, style: .continuous))
    }
}

/// Eight small holes along the top and the bottom of a swatch.
private struct Perforations: View {
    let ink: Color
    let opacity: Double
    /// The two rows' tops, and a hole's height.
    let rows: (CGFloat, CGFloat)
    let height: CGFloat
    var body: some View {
        ForEach(0..<16, id: \.self) { i in
            RoundedRectangle(cornerRadius: 1).fill(ink.opacity(opacity))
                .frame(width: 5, height: height)
                .leading(5 + CGFloat(i % 8) * 10).top(i < 8 ? rows.0 : rows.1)
        }
    }
}

private struct CardIsWholeKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// False while a card is partly off the screen: it shows its swatch, not
    /// its words.
    fileprivate var cardIsWhole: Bool {
        get { self[CardIsWholeKey.self] }
        set { self[CardIsWholeKey.self] = newValue }
    }
}

/// A card that waits is dimmed as one layer, so that its parts do not show
/// through one another, and takes no tap. A card that does not is left
/// exactly as it was.
private struct CardWaits: ViewModifier {
    let waits: Bool
    func body(content: Content) -> some View {
        if waits { content.compositingGroup().rowEnabled(false) } else { content }
    }
}

/// The scrolling row of cards: four whole and the edge of a fifth, the chosen
/// one in the white frame. A tap chooses; the caller decides what that does.
struct CardRow<Item: Identifiable, Card: View>: View where Item.ID: Hashable {
    let items: [Item]
    /// Nil: none is chosen (the papers under a slide film).
    let selectedID: Item.ID?
    let height: CGFloat
    let onPick: (Item) -> Void
    /// A card that waits: shown, dimmed — that card alone, as one layer — and
    /// not to be chosen (a paper that cannot print the frame's film). Not
    /// drawn: the drawings dim a whole row (`.rowEnabled`), never one card.
    var waits: (Item) -> Bool = { _ in false }
    /// The card the row opens on, where that is not the chosen one's place:
    /// a snapshot's own, to draw the cards a row keeps past its fourth.
    var opensOn: Item.ID? = nil
    @ViewBuilder var card: (Item) -> Card

    @State private var leadingID: Item.ID?
    private let space = "card-row"

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.gap(for: width)) {
                    ForEach(items) { item in
                        let on = item.id == selectedID
                        let waiting = waits(item)
                        Button { if !waiting { onPick(item) } } label: {
                            // Where the card is now decides whether its words show.
                            GeometryReader { g in
                                let f = g.frame(in: .named(space))
                                card(item).environment(\.cardIsWhole, f.minX >= -0.5 && f.maxX <= width + 0.5)
                            }
                            .frame(width: CardMetric.width, height: height)
                            .overlay {
                                if on {
                                    RoundedRectangle(cornerRadius: Theme.Metric.cardRadius + CardMetric.frameOutset,
                                                     style: .continuous)
                                        .stroke(Theme.selectionFrame, lineWidth: 2)
                                        .padding(-CardMetric.frameOutset)
                                }
                            }
                        }
                        .buttonStyle(PressStyle())
                        .modifier(CardWaits(waits: waiting))
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .id(item.id)
                    }
                }
                .padding(.vertical, CardRowMetric.framePadding)       // room for the selection frame
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, Theme.Metric.margin, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $leadingID, anchor: .leading)
            .coordinateSpace(.named(space))
        }
        .frame(height: height + 2 * CardRowMetric.framePadding)
        .onAppear {
            // The chosen card in view: the fourth whole card when it is past the first four.
            if let opensOn {
                leadingID = opensOn
            } else if let i = items.firstIndex(where: { $0.id == selectedID }), i >= 4 {
                leadingID = items[i - 3].id
            }
        }
    }

    /// The drawing's gap: four whole cards between the margins, so the fifth
    /// only peeks. On a wider host the gap stops at 9 pt and the fifth peeks
    /// further, rather than leaving the page.
    static func gap(for width: CGFloat) -> CGFloat {
        let fit = (width - 2 * Theme.Metric.margin - 4 * CardMetric.width) / 3
        return min(max(fit, 4), 9)
    }
}
