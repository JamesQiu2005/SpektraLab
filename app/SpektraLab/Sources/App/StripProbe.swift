//  StripProbe.swift — Develop's two strips, made by `StockPreviews`, on a page of their own.
//
//  For the builder of the V5 Develop page (design/v4 §2, §6), who draws the
//  strips next: the service at work, without the develop page.
//
//  - `V5-strip-probe` in the snapshot harness: the drawings' library, whose
//    frames no engine develops, so every card is its swatch (`failed`); the
//    third row is the card's three looks — the ring over the swatch while it
//    is made, the picture (here the drawing's own, standing in for a render),
//    the swatch alone.
//  - `--strip-probe [file name]` with `--library real` in a simulator: the same
//    page over the engine, as the first launch screen. What it shows is the
//    service's: the cards on screen are made, one at a time, the rest when
//    they are scrolled to.
//
//  `StripProbeCard` is the card as design/v4 §6 draws it: 100 × 84 pt, the
//  picture filling it, the name on a 26 pt band where the same picture is
//  blurred (σ 3.5) under a 28 % scrim, CINE and SLIDE as pills, the white
//  frame for the chosen one. The develop page's own part is the builder's.

import SwiftUI

enum StripProbe {
    /// The frame the probe is of: the library's chosen one, or its first that has something to
    /// develop from.
    @MainActor static func frame(in model: AppServices) -> LibraryFrame? {
        return model.library.selected ?? model.library.frames.first { $0.developSource != nil } ?? model.library.frames.first
    }
}

/// A card of a strip (design/v4 §6).
struct StripProbeCard: View {
    let stock: Stock
    let state: StockPreviewState
    var progress: Double? = nil
    var selected = false

    static let size = CGSize(width: 100, height: 84)
    static let band: CGFloat = 26

    var body: some View {
        let w = Self.size.width, h = Self.size.height
        ZStack(alignment: .topLeading) {
            stock.color.frame(width: w, height: h)
            if let image = state.image {
                picture(image)
                // The band: the same picture, blurred, under the name — and nowhere else.
                picture(image)
                    .blur(radius: 3.5, opaque: true)
                    .mask(alignment: .bottom) { Rectangle().frame(width: w, height: Self.band) }
            }
            Rectangle().fill(Color.black.opacity(0.28)).frame(width: w, height: Self.band).offset(y: h - Self.band)
            Text(stock.shortName)
                .font(Theme.Font.ui(12, .semibold)).foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.75)
                .frame(width: w - 15, alignment: .leading)
                .offset(x: 9, y: h - 22)
            pill.frame(width: w - 8, alignment: .trailing).offset(y: 6)
            if state.isRendering {
                ProgressRing(progress: progress, diameter: 20, lineWidth: 2)
                    .frame(width: w, height: h - Self.band)
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.cardRadius, style: .continuous))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: Theme.Metric.cardRadius + 1.5, style: .continuous)
                    .stroke(Theme.selectionFrame, lineWidth: 2).padding(-1.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stock.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func picture(_ image: UIImage) -> some View {
        Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            .frame(width: Self.size.width, height: Self.size.height).clipped()
    }

    @ViewBuilder private var pill: some View {
        if stock.isCine {
            CinePill().background(Capsule().fill(Color.black.opacity(0.45)))
        } else if stock.isPositive {
            Text(L("SLIDE")).font(Theme.Font.ui(7.5, .bold)).foregroundStyle(Theme.secondaryText)
                .frame(width: 30, height: 12).background(Capsule().fill(Color.black.opacity(0.45)))
        }
    }
}

/// The page: the frame's film strip and the paper strip under its film.
struct StripProbeScreen: View {
    @Environment(AppServices.self) private var model
    /// The card's three looks under the strips (the snapshot's).
    var looks = false

    var body: some View {
        if let frame = StripProbe.frame(in: model) {
            StripProbeBody(frame: frame, strip: model.stockPreviews.strip(for: frame.id), looks: looks)
        } else {
            Theme.background.ignoresSafeArea()
        }
    }
}

private struct StripProbeBody: View {
    let frame: LibraryFrame
    let strip: StockStrip
    let looks: Bool
    @State private var onScreen: [StockPreviewCard.Strip: Set<String>] = [:]

    var body: some View {
        let films = strip.filmCards, papers = strip.paperCards
        VStack(alignment: .leading, spacing: 0) {
            FramePicture(picture: frame.developed?.picture ?? frame.picture, pointSize: 393, contentMode: .fit)
                .frame(height: 262).frame(maxWidth: .infinity)
            label(L("Film"), films).padding(.top, 22)
            row(films, strip: .film, chosen: frame.edit.params.filmStock)
            label(L("Paper"), papers).padding(.top, 18)
            if papers.isEmpty {
                Text(L("Scanned")).font(Theme.Font.ui(14, .semibold)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.Metric.cardRadius).fill(Theme.card))
                    .padding(.horizontal, Theme.Metric.margin).padding(.top, 8)
            } else {
                row(papers, strip: .paper, chosen: frame.edit.params.printStock)
            }
            if looks, let stock = StockCatalog.shared.stock(frame.edit.params.filmStock) {
                HStack(spacing: 8) {
                    StripProbeCard(stock: stock, state: .rendering(previous: nil), progress: 0.4)
                    StripProbeCard(stock: stock, state: ThumbnailStore.shared.load(frame.picture, maxPixel: 336).map { .ready($0) } ?? .failed)
                    StripProbeCard(stock: stock, state: .failed)
                }
                .padding(.horizontal, Theme.Metric.margin).padding(.top, 26)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background.ignoresSafeArea())
        .onChange(of: onScreen) { show(films, papers) }
        .onDisappear { strip.leave() }
    }

    /// "Film  4/24": the label, and how many of its cards are made.
    private func label(_ text: String, _ cards: [StockPreviewCard]) -> some View {
        let made = cards.filter { if case .ready = strip.state($0) { true } else { false } }.count
        return HStack(alignment: .firstTextBaseline) {
            Text(text).font(Theme.Font.ui(13, .semibold)).foregroundStyle(Theme.dim)
            Spacer()
            if !cards.isEmpty {
                Text(verbatim: "\(made)/\(cards.count)").font(Theme.Font.ui(12, .medium)).monospacedDigit().foregroundStyle(Theme.dim)
            }
        }
        .padding(.horizontal, Theme.Metric.margin)
    }

    private func row(_ cards: [StockPreviewCard], strip which: StockPreviewCard.Strip, chosen: String) -> some View {
        GeometryReader { outer in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(cards) { card in
                        if let stock = StockCatalog.shared.stock(card.stock) {
                            StripProbeCard(stock: stock, state: strip.state(card), progress: strip.progress(card),
                                           selected: card.stock == chosen)
                                .onGeometryChange(for: Bool.self) { proxy in
                                    let f = proxy.frame(in: .scrollView(axis: .horizontal))
                                    return f.maxX > 0 && f.minX < outer.size.width
                                } action: { visible in
                                    var set = onScreen[which] ?? []
                                    if visible { set.insert(card.id) } else { set.remove(card.id) }
                                    onScreen[which] = set
                                }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .contentMargins(.horizontal, Theme.Metric.margin, for: .scrollContent)
        }
        .frame(height: StripProbeCard.size.height + 8)
        .padding(.top, 6)
    }

    /// The cards on screen, the film strip's first, each in its strip's order.
    private func show(_ films: [StockPreviewCard], _ papers: [StockPreviewCard]) {
        let f = onScreen[.film] ?? [], p = onScreen[.paper] ?? []
        strip.show(films.filter { f.contains($0.id) } + papers.filter { p.contains($0.id) })
    }
}

@MainActor
enum StripProbeSnapshots {
    static var pages: [SnapshotPage] {
        [SnapshotPage("V5-strip-probe", "Develop's strips, from the service") { _ in
            StripProbeScreen(looks: true)
        }]
    }
}
