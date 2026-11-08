//  DevelopPanels.swift — controls in the Film, Frame, Print, Scene and Effects panels.
//
//  The row geometry is shared through DevelopLayout and checked by tools/develop_selftest.swift.
//  Pro controls expose more parameters of the same stages. Each control names its parameter layer:
//  film changes develop the negative again; paper, enlarger and glare changes reprint the cached one.
//  A half-frame pair has its own Frame controls for placing each picture in the piece.

import SwiftUI

/// A v2 ruler row (`rrow`): the label at 13.5 pt, the ruler 23 pt under it.
func rulerRow(_ label: String, _ valueText: String, sub: String? = nil, value: Binding<Double>,
                      range: ClosedRange<Double>, step: Double, majorEvery: Int = 3, spacing: CGFloat = 10.5,
                      snap: Double? = nil, tint: ((Double) -> Color)? = nil, home: Double? = nil,
                      onEditingChanged: @escaping (Bool) -> Void) -> some View {
    RulerRow(label: label, valueText: valueText, sub: sub, value: value, range: range, step: step,
             majorEvery: majorEvery, spacing: spacing, snap: snap, tint: tint, rulerDrop: PanelY.Part.rulerDrop,
             labelSize: DevelopType.label, home: home, onEditingChanged: onEditingChanged)
        .padding(.horizontal, Theme.Metric.margin)
}

/// The page's type: a row's title and its value (`gen_edit_v2.LABEL`).
enum DevelopType {
    static let label: CGFloat = 13.5
}

/// A panel's quiet lines (`notes`): 11.5 pt, from the margin, its first
/// baseline at `y`. Each line is a line, as the drawing sets them: one too
/// long for a narrow host, or for a long stock's name, is set smaller and
/// never onto another line — so what is drawn under a note keeps its place
/// (`PanelState`, where each note is as many lines as it is given here).
@MainActor private func panelNote(_ lines: [String], color: Color = Theme.dim) -> some View {
    VStack(alignment: .leading, spacing: LinePitch.spacing(for: PanelY.Part.noteLead, size: PanelNotes.size)) {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            Text(line).font(Theme.Font.ui(PanelNotes.size)).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(PanelNotes.leastScale)
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Theme.Metric.margin)
}

/// A line whose words are not the drawing's — the Fit's reason on Scene
/// Placement. It is the last thing in its panel, and may take the lines the
/// panel has left under it.
@MainActor private func panelNote(wrapping text: String, color: Color) -> some View {
    Note(text, color: color).lineLimit(PanelNotes.placementReasonLines).minimumScaleFactor(0.85)
        .padding(.horizontal, Theme.Metric.margin)
}

// MARK: - Film (B1, P1)

struct FilmPanel: View {
    let session: OpenFrameSession
    let pro: Bool
    /// V5 combines the material choices in one step; retain the existing controls.
    var includesPaper = false
    /// A snapshot's own: the card the row opens on.
    var cardsOpenOn: String? = nil
    @Environment(AppRouter.self) private var router
    @Environment(AppServices.self) private var model

    /// A half-frame pair's darkroom (design/pair v2, H3 and H4): the one film
    /// is both frames' whichever layer is picked, and **the dial is the picked
    /// layer's** — the film's moves both frames by the same stops, a frame's
    /// is that frame's own exposure on the film (`HalfFramePair.Hole.exposureEV`),
    /// with where it lands and its own meter beside it.
    private var pair: HalfFramePair? { FeatureFlags.halfFramePair ? session.pair : nil }
    /// The frame of the pair that is picked, when one that is there is.
    private var side: HalfFramePair.Side? { pair?.pickedSide(session.layer) }

    var body: some View {
        let p = session.edit.params
        let hole = side.flatMap { pair?[$0] }
        let ev = hole?.exposureEV ?? p.exposureCompensationEV
        DrawnBand(height: includesPaper && !StockCatalog.shared.isSlide(p.filmStock) ? 310 : PanelY.height) {
            CardRow(items: StockCatalog.shared.films, selectedID: p.filmStock, height: FilmCard.height, onPick: pick,
                    opensOn: cardsOpenOn) {
                FilmCard(stock: $0)
            }
            .top(PanelY.Film.cards - CardRowMetric.framePadding)
            if includesPaper && !StockCatalog.shared.isSlide(p.filmStock) {
                let catalog = StockCatalog.shared
                CardRow(items: catalog.papers.filter { catalog.canPrint(film: p.filmStock, on: $0.id) },
                        selectedID: p.printStock, height: PaperCard.height,
                        onPick: { paper in session.change { $0.params.print(on: paper.id) } }) { paper in
                    PaperCard(stock: paper, ownDot: catalog.isRecommendedPairing(film: p.filmStock, paper: paper.id)
                              ? catalog.stock(p.filmStock)?.color : nil)
                }
                .top(126)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                DrawnText(L("Film Exposure"), DevelopType.label, .semibold)
                if let side, let hole {
                    // Where this frame's exposure lands (`pill_menu`, as the meter's).
                    PairScopePill(scope: hole.exposureScope, of: L("exposure")) { scope in
                        model.changePair(session.frameID) { piece, _ in piece[side]?.exposureScope = scope }
                    }
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                    .padding(.trailing, -2)
                    if pro {
                        // This frame's own meter: an intent of its own, or Custom.
                        meterMenu(hole.meter(film: p), compact: true) { method in
                            model.changePair(session.frameID) { piece, look in piece.take(meter: method, on: side, look: &look.params) }
                        }
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                    } else if let read = hole.meterText(film: p) {
                        // What the meter chose for this picture alone, as the pair's own page said it.
                        DrawnText(read, PanelNotes.size, .medium, Theme.dim).padding(.leading, -2)
                    }
                } else if pro {
                    // The meter's intent, beside the exposure it sets (`pill_menu`):
                    // its middle 4.5 pt above the label's baseline.
                    meterMenu(AEMethod.of(p)) { method in session.change { method.apply(to: &$0.params) } }
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                } else if pair != nil {
                    DrawnText(L("both frames"), PanelNotes.size, .medium, Theme.dim).padding(.leading, -3)
                }
                Spacer(minLength: 8)
                SliderField(shown: Fmt.signed(ev) + " EV",
                            parse: SliderField.number(from:),
                            commit: { new in
                                let r = side == nil ? -8...8 : HalfFramePair.exposureRange
                                session.editing(.shoot)(true)
                                exposure.wrappedValue = new.clamped(to: r)
                                session.editing(.shoot)(false)
                            })
            }
            .padding(.horizontal, Theme.Metric.margin)
            .baseline(PanelY.Film.exposureLabel + paperOffset)
            // The fixed track, as everywhere else (2026-10-26): the knob moves,
            // the scale does not. Thirds of a stop are its ticks.
            SliderTrack(value: exposure, range: side == nil ? -8...8 : HalfFramePair.exposureRange,
                        rest: 0, step: 0.1, detentAtRest: false,
                        onEditingChanged: session.editing(.shoot))
                .padding(.horizontal, Theme.Metric.margin)
                .top(PanelY.Film.dial + paperOffset)
                .accessibilityLabel(side.flatMap { pair?.title(.init($0)) }.map { L("Film Exposure, \($0)") } ?? L("Film Exposure"))
        }
    }

    private var paperOffset: CGFloat {
        includesPaper && !StockCatalog.shared.isSlide(session.edit.params.filmStock) ? 100 : 0
    }

    /// The dial's value: a photograph's own exposure, the film's on a pair, or
    /// the picked frame's — which is in the piece's pixels, so it goes through
    /// the piece (`HalfFramePair.exposure`: with *+ Film* the film round the
    /// frame follows it).
    private var exposure: Binding<Double> {
        guard let side, pair != nil else { return session.binding(\.params.exposureCompensationEV) }
        let id = session.frameID
        return Binding(get: { session.pair?[side]?.exposureEV ?? 0 },
                       set: { ev in model.changePair(id) { piece, look in piece.exposure(ev, of: side, look: &look.params) } })
    }

    /// A film card was tapped. A slide is scanned and a negative printed on
    /// the paper the frame kept (`FilmParams.load`).
    private func pick(_ stock: Stock) {
        session.change { $0.params.load(film: stock.id) }
    }

    /// The meter's intent (`autoExposureMethod`), and Custom, which is the
    /// meter off: Film Exposure is then measured from the frame as decoded.
    /// A photograph's, a pair's film's (both frames follow it unless one has
    /// its own), or one frame's own.
    private func meterMenu(_ now: AEMethod, compact: Bool = false, take: @escaping (AEMethod) -> Void) -> some View {
        Menu {
            ForEach(AEMethod.offered) { method in
                Button {
                    take(method)
                } label: {
                    if method == now { Label(method.title, systemImage: "checkmark") } else { Text(method.title) }
                }
            }
        } label: {
            // `pill_menu`: the chevron 7 wide and 1.4 pt, its middle 9 pt past
            // the word and 13 from the pill's end.
            HStack(spacing: 5.5) {
                // The per-hole row also carries Frame / + Film. Keep the
                // value short there; the opened menu retains its full name.
                Text(compact && now == .custom ? L("Source") : now.title)
                    .font(Theme.Font.ui(12)).foregroundStyle(Theme.secondaryText).lineLimit(1).fixedSize()
                Icon(.chevronDown, size: 19.25, color: Theme.secondaryText).frame(width: 7, height: 7)
            }
            .padding(.leading, 12)
            .padding(.trailing, 9.5)
            .frame(height: PanelY.Film.meterPillHeight)
            .background(Capsule().fill(Theme.card))
            .contentShape(Capsule())
        }
        // The drawing's pill, not the system's pop-up button.
        .menuStyle(.button)
        .buttonStyle(PressStyle())
        .menuIndicator(.hidden)
        .accessibilityLabel(L("Meter, \(now.title)"))
    }

    /// "−4", "0", "+5": the dial's numbers, with a true minus.
    static func stops(_ v: Double) -> String {
        let n = Int(v.rounded())
        return n == 0 ? "0" : (n > 0 ? "+\(n)" : "−\(-n)")
    }
}

// MARK: - Frame (B2)

struct FramePanel: View {
    let session: OpenFrameSession
    let frame: LibraryFrame
    /// V5 leaves Crop on Edit and removes the old explanatory line.
    var v5 = false
    /// a wide window's Format has
    /// no Film Edge and Date Back rows — they are sections on Film & Paper (`FilmEdgeColumn`), and the
    /// flow the rows opened is the host's — so it is the film's sizes alone: greyed under a film edge,
    /// the line under them saying whose the size is, as the drawn panel's note does.
    var wide = false
    @Environment(AppRouter.self) private var router
    @Environment(AppServices.self) private var model

    private var edge: FilmEdgeSettings { session.edit.filmEdge }
    private var back: DateBackSettings { session.edit.dateBack }
    /// On a pair: the Film Edge row, and the Date Back row, tapped.
    @State private var asksAboutStrip = false
    @State private var asksAboutDates = false

    /// The film's sizes the page offers: 110, APS, 135, 120. Custom needs a
    /// typed length, which is not drawn.
    static let sizes = FilmFrame.still.filter { $0.id != FilmFrame.custom.id }

    var body: some View {
        if let pair = frame.pair { pairBody(pair) } else { photoBody }
    }

    /// A half-frame pair's Frame tab (the page layout). The
    /// film's size is the pair's own — two half frames — so the cards stand
    /// down, as they do under a film edge; and the third row is the pair's,
    /// where Crop is for a frame: it opens the pair's own page.
    ///
    /// **Not drawn: what Film Edge and the Date Back open on a pair.** The
    /// Film Edge flow lays one frame in one gate and draws its film from a
    /// layout that has no pair (`FilmLayout`), so on a pair each of the two is
    /// on or off, asked in the system's own sheet: the strip as this host's
    /// body draws it, a date as a new one starts.
    private func pairBody(_ pair: HalfFramePair) -> some View {
        DrawnBand(height: PanelY.height) {
            CardRow(items: Self.sizes, selectedID: nil, height: SizeCard.height, onPick: { _ in }) {
                SizeCard(frame: $0, photo: frame)
            }
            .compositingGroup()
            .rowEnabled(false)
            .top(PanelY.Frame.cards - CardRowMetric.framePadding)
            panelNote([PairWords.filmSize]).baseline(PanelY.Frame.note)

            if FeatureFlags.filmEdge {
                row(0, L("Film Edge"), value: pair.wearsFilmEdge ? L("Half-Frame Pair") + Fmt.dot + L("Strip") : L("Off")) { asksAboutStrip = true }
            }
            if FeatureFlags.dateBack {
                row(1, L("Date Back"), value: dateValue) { asksAboutDates = true }
            }
            row(2, L("Half-Frame Pair"), value: PairWords.rowValue(pair), last: true) { router.show(.pairPlace(frame.id, .left)) }
        }
        .confirmationDialog(L("Film Edge"), isPresented: $asksAboutStrip, titleVisibility: .visible) {
            if pair.onStrip {
                Button(L("Take the Film Edge Off"), role: .destructive) { model.setPairFilmEdge(false, of: frame.id) }
            } else {
                Button(L("Put the Pair on Its Strip")) { model.setPairFilmEdge(true, of: frame.id) }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Both frames on one strip of 135 film, a millimetre apart, as a half-frame camera leaves them."))
        }
        .confirmationDialog(L("Date Back"), isPresented: $asksAboutDates, titleVisibility: .visible) {
            if back.active {
                Button(L("Remove the Dates"), role: .destructive) { session.change { $0.dateBack.active = false } }
            } else {
                Button(L("Print Each Frame's Date")) {
                    session.change { e in
                        e.dateBack.active = true
                        // In the frame: the data face and a date between frames are the
                        // Film Edge flow's to place, which a pair does not open.
                        if e.dateBack.style == .data { e.dateBack.style = .lcd }
                        e.dateBack.placement = .frame
                    }
                }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Each frame carries its own date, as each was its own exposure."))
        }
    }

    @ViewBuilder private var photoBody: some View {
        if wide { sizesBody } else { rowsBody }
    }

    private var sizesBody: some View {
        let held = edge.effective
        return DrawnBand(height: PanelY.Frame.note + 17) {
            CardRow(items: Self.sizes, selectedID: held ? nil : session.edit.params.filmFrame, height: SizeCard.height,
                    onPick: setSize) {
                SizeCard(frame: $0, photo: frame)
            }
            .compositingGroup()
            .rowEnabled(!held)
            .top(PanelY.Frame.cards - CardRowMetric.framePadding)
            panelNote(PanelNotes.filmSize(edge: held ? edge.format.label : nil)).baseline(PanelY.Frame.note)
        }
    }

    @ViewBuilder private var rowsBody: some View {
        let p = session.edit.params
        let held = edge.effective
        DrawnBand(height: v5 ? (held ? 144 : 180) : PanelY.height) {
            // With a film edge on, the film's size is the film edge's own
            // format — the engine takes the gate's millimetres, not these
            // (`pipeline.cpp`, `overscan_gate_long_mm`) — so the cards stand
            // down and the line under them says whose the size is.
            if !v5 || !held {
            CardRow(items: Self.sizes, selectedID: held ? nil : p.filmFrame, height: SizeCard.height, onPick: setSize) {
                SizeCard(frame: $0, photo: frame)
            }
            // Dimmed as one layer, as the drawing dims a group: a card's
            // parts do not show through one another.
            .compositingGroup()
            .rowEnabled(!held)
            .top(PanelY.Frame.cards - CardRowMetric.framePadding)
            }
            if !v5 {
                panelNote(PanelNotes.filmSize(edge: held ? edge.format.label : nil))
                    .baseline(PanelY.Frame.note)
            }

            if FeatureFlags.filmEdge {
                row(0, L("Film Edge"), value: edgeValue) { open(.film) }
            }
            if FeatureFlags.dateBack {
                row(1, L("Date Back"), value: dateValue) { open(.date) }
            }
            if held {
                // The photo's crop is kept and returns when the film edge goes.
                Button { session.change { $0.filmEdge.active = false } } label: {
                    Text(L("Remove film edge")).font(Theme.Font.ui(DevelopType.label)).foregroundStyle(Theme.danger)
                        .frame(height: v5 ? 44 : PanelY.Frame.rowPitch).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .leading(16).baseline(v5 ? 128 : PanelY.Frame.rows[2])
                if !v5 { DrawnText(L("Crop held by Film Edge"), 12.5, .medium, Theme.dim).trailingInset(16).baseline(PanelY.Frame.rows[2]) }
            } else if !v5 {
                row(2, L("Crop"), value: Self.cropText(session.edit.geometry, source: frame.originalSize), last: true) {
                    router.show(.crop(frame.id))
                }
            }
        }
    }

    /// One line (`row`): a title, its value and a chevron; the rule under it.
    private func row(_ index: Int, _ title: String, value: String, last: Bool = false,
                     action: @escaping () -> Void) -> some View {
        // The band is the row's pitch, its title's baseline 20 pt down.
        let base: CGFloat = 20
        return Button(action: action) {
            DrawnBand(height: v5 ? 44 : PanelY.Frame.rowPitch) {
                DrawnText(title, DevelopType.label, .semibold)
                .leading(16).baseline(base)
                DrawnText(value, 12.5, .medium, Theme.secondaryText, fit: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.leading, 110).padding(.trailing, 30)
                    .baseline(base)
                Chevron().trailingInset(16).centreY(base - 4.5)
                if !last {
                    Rectangle().fill(Theme.rule).frame(height: Theme.Metric.rule)
                        .padding(.horizontal, Theme.Metric.margin).top(base + PanelY.Frame.separator - 0.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 1))
        .accessibilityLabel(title + ", " + value)
        .top((v5 ? (edge.effective ? 28 : 112) + CGFloat(index) * 44 : PanelY.Frame.rows[index]) - base)
    }

    /// Into the Film Edge flow at a step.
    private func open(_ step: FilmEdgeStep) {
        router.show(.filmEdge(frame.id, step))
    }

    /// The desktop's way: the frame type, its length on the side the user
    /// measures, and the wire's long edge derived from the photograph's own
    /// aspect (FilmParams' `FilmFrame`).
    private func setSize(_ f: FilmFrame) {
        let photo = frame.originalSize
        session.change { $0.params.take(size: f, photo: photo) }
    }

    /// "135 · Strip · Square": the film, the view, and the gate as it was made.
    private var edgeValue: String {
        guard edge.effective else { return L("Off") }
        let made = model.filmEdge(for: frame, edit: session.edit)?.geometry.gateFamily ?? .square
        return edge.rowValue(resolvedGate: made)
    }

    private var dateValue: String {
        guard back.active else { return L("Off") }
        guard back.effective(filmEdge: edge) else { return L("Not printed") }
        return back.rowValue(text: FilmEdgeResolver.dateText(back, frame: frame))
    }

    /// "Original  ·  3:2", "Free  ·  1.43:1", "4:5": what the crop is, as the
    /// output is shaped (after any quarter turn).
    static func cropText(_ g: Geometry, source: PixelSize) -> String {
        let out = g.outputSize(for: CGSize(width: source.width, height: source.height))
        let ratio = ratioText(width: out.width, height: out.height)
        let untouched = g.crop.isFull && g.angle == 0
        switch g.aspect {
        case .original, .originalPortrait: return L("Original") + Fmt.dot + ratio
        case .free: return (untouched ? L("Original") : L("Free")) + Fmt.dot + ratio
        default: return ratio
        }
    }

    /// "3:2" when the shape is one of the presets' ratios, else "1.43:1".
    static func ratioText(width: CGFloat, height: CGFloat) -> String {
        let r = Double(width / max(height, 1))
        let pairs = [(1, 1), (3, 2), (2, 3), (4, 3), (3, 4), (16, 9), (9, 16), (5, 4), (4, 5), (7, 5), (5, 7)]
        if let (a, b) = pairs.first(where: { abs(r - Double($0.0) / Double($0.1)) < 0.005 }) { return "\(a):\(b)" }
        return r >= 1 ? String(format: "%.2f:1", r) : String(format: "1:%.2f", 1 / r)
    }
}

// MARK: - Print (B3, B6, P2)

struct PrintPanel: View {
    let session: OpenFrameSession
    let pro: Bool
    @Binding var tool: EnlargerTool
    /// A snapshot's own: the card the row opens on.
    var cardsOpenOn: String? = nil
    /// V5's Enlarger page (Edit › EngineRouter › Enlarger): its papers are
    /// Develop's paper row, from this strip, and the parts stack under it
    /// (`stacked`); nil: edit_v2's drawn Print tab.
    var papers: StockStrip? = nil
    /// The shelf the papers are narrowed to: the page's pill, in its header.
    var paperShelf: StockShelf = .all
    @Environment(AppServices.self) private var model

    /// A half-frame pair's darkroom (design/pair v2, H7): the one paper is the
    /// piece's whichever layer is picked, and **the enlarger is the picked
    /// layer's**. A frame's is that frame's own print — a reprint of the same
    /// negative under its hole alone (`HalfFramePair.Hole.print`), with where
    /// the edit lands beside its name; the film's is the whole piece, and a
    /// frame with a print of its own keeps its distance from it
    /// (`HalfFramePair.print`, the desktop's `setEnlarger`).
    private var pair: HalfFramePair? { FeatureFlags.halfFramePair ? session.pair : nil }
    /// The frame of the pair that is picked, when one that is there is.
    private var side: HalfFramePair.Side? { pair?.pickedSide(session.layer) }

    /// The filtration scales' tints (`gen_edit_v2.yellow`, `magenta`).
    ///
    /// **A scale shows where its ruler takes the picture, and that is the other
    /// way round from the filter's name.** The filters are the enlarger head's
    /// and a negative prints the other way: more yellow filtration is a bluer
    /// print, more magenta a greener one. Measured through the engine — by the
    /// desktop on 2026-10-04, which turned its sliders' tracks round for it,
    /// and here in the simulator on 2026-10-05, on a ProRAW, from the page's
    /// own picture (Yellow +0.15 → +1.00: the picture's mean red −26, green −14
    /// and blue +26 of 255; then Magenta 0 → +1.00: green +25, red −18,
    /// blue −12). So Yellow's scale runs from yellow to blue and Magenta's
    /// from magenta to green, and the word after each name says where: `→ blue`.
    ///
    /// **On the silver paper the two are its grade, and there is no colour to
    /// show** (`EnlargerScales`): the words are `→ softer` and `→ harder`, and
    /// the scales are plain.
    private static let yellowScale = (0xE3C25A as UInt32, 0x5F86C9 as UInt32)
    private static let magentaScale = (0xC86FB5 as UInt32, 0x6FBF73 as UInt32)

    var body: some View {
        if let papers { stacked(papers) } else { drawn }
    }

    /// edit_v2's Print tab, every part at its drawn place.
    @ViewBuilder private var drawn: some View {
        let catalog = StockCatalog.shared
        let p = session.edit.params
        let film = catalog.stock(p.filmStock)
        let slide = catalog.isSlide(p.filmStock)
        // A slide, or a negative a desktop edit scans: nothing is printed.
        let scanned = catalog.isScanned(p)
        let scales = EnlargerScales.of(p, catalog: catalog)
        // What the enlarger shows: a photograph's print, a pair's film's, or the picked frame's own.
        let trim = pair?.trim(on: session.layer, look: p) ?? HalfFramePair.PrintTrim(p)
        // On a pair the two rows sit 3 and 2 pt lower, clear of the pill (`gen_pair_v2.panel_print`).
        let rows = pair == nil ? (PanelY.Print.yellow, PanelY.Print.magenta) : (PanelY.Print.pairYellow, PanelY.Print.pairMagenta)
        DrawnBand(height: PanelY.height) {
            // A paper of the other kind waits, that card alone: a colour paper
            // under a black-and-white film, the silver paper under a colour
            // one. The gate is the model's (`FilmParams.print(on:)`); the card
            // shows it. Under a slide every paper waits, and the row says so.
            CardRow(items: catalog.papers, selectedID: scanned ? nil : p.printStock, height: PaperCard.height,
                    onPick: { paper in session.change { $0.params.print(on: paper.id) } },
                    waits: { !slide && !catalog.canPrint(film: p.filmStock, on: $0.id) }, opensOn: cardsOpenOn) { paper in
                PaperCard(stock: paper, ownDot: !scanned && film?.targetPrint == paper.id ? film?.color : nil,
                          waits: slide ? nil : catalog.whyNotPrinted(film: p.filmStock, on: paper.id))
            }
            // Under a slide the papers wait: shown, dimmed (as one layer, the
            // drawing's `<g opacity>`), and not to be chosen.
            .compositingGroup()
            .rowEnabled(!slide)
            .top(PanelY.Print.cards - CardRowMetric.framePadding)

            if slide {
                DrawnText(PanelNotes.slideTitle(film?.shortName ?? L("This film")), DevelopType.label, .semibold, fit: true)
                    .spanning(leading: 16, trailing: 16).baseline(PanelY.Print.slideTitle)
                panelNote(PanelNotes.slide).baseline(PanelY.Print.slideNote)
            } else if scanned {
                DrawnText(PanelNotes.scannedTitle, DevelopType.label, .semibold).leading(16).baseline(PanelY.Print.slideTitle)
                panelNote(PanelNotes.scanned).baseline(PanelY.Print.slideNote)
            } else if pro {
                if let side, let hole = pair?[side] {
                    // Under pro-control the line is the three tools': the pill stands where the
                    // label does, and the layers' switch above says whose print it is.
                    scopePill(hole, side).leading(16).centreY(PanelY.Print.chips + PanelY.Print.chipHeight / 2)
                } else {
                    SectionLabel(L("Enlarger")).padding(.leading, 16).baseline(PanelY.Print.proLabel)
                }
                ChipRow(options: EnlargerTool.allCases, selection: $tool, title: { $0.title(on: scales) }, spacing: 6,
                        height: PanelY.Print.chipHeight, size: 12.5, padding: 11)
                    .trailingInset(16).top(PanelY.Print.chips)
                switch tool {
                case .colour:
                    yellow(trim, scales).baseline(PanelY.Print.proFirst)
                    magenta(trim, scales).baseline(PanelY.Print.proSecond)
                case .brightness:
                    rulerRow(L("Brightness"), Fmt.signed(trim.brightnessStops), sub: L("stops"),
                             value: enlarger(.brightness, \.params.printBrightnessStops), range: -3...3, step: 0.1, majorEvery: 5,
                             snap: 0.1, home: 0, onEditingChanged: session.editing(.print))
                        .baseline(PanelY.Print.proFirst)
                    panelNote(PanelNotes.brightness).baseline(PanelY.Print.proNote)
                case .preflash:
                    // 0…0.03 of the wire's 0…1: the useful range, measured
                    // (FilmParams.preflashExposure).
                    rulerRow(L("Pre-flash"), String(format: "%.3f", trim.preflashExposure),
                             value: enlarger(.preflash, \.params.preflashExposure), range: 0...0.03, step: 0.001, majorEvery: 5,
                             snap: 0.001, onEditingChanged: session.editing(.print))
                        .baseline(PanelY.Print.proFirst)
                    panelNote(PanelNotes.preflash).baseline(PanelY.Print.proNote)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // The label takes the row's width by itself: here it is as wide as its word.
                    SectionLabel(L("Enlarger")).fixedSize()
                    // Whose print the two filters are: the picked frame's own.
                    if let side, let pair { DrawnText(pair.title(.init(side)), 11.5, .medium, Theme.secondaryText) }
                }
                .padding(.leading, 16).baseline(PanelY.Print.label)
                if let side, let hole = pair?[side] {
                    scopePill(hole, side).trailingInset(16).centreY(PanelY.Print.pairPill + PairPanelY.Piece.pillHeight / 2)
                }
                yellow(trim, scales).baseline(rows.0)
                magenta(trim, scales).baseline(rows.1)
            }
        }
    }

    /// V5's Enlarger page, stacked rather than drawn (the owner, 2026-10-20, of
    /// the page as it was: "we need to move the pills down a little bit and the
    /// two metrics as well, together with the paper display fix that acts like
    /// the paper selection in develop"). Develop's paper row; a section's gap;
    /// the enlarger's line — its label, or a frame's scope pill, and the three
    /// tools as Develop's pills are sized; then the tool's rulers. Every gap is
    /// one of `EnlargerStack`'s, which are the design system's own measures.
    @ViewBuilder private func stacked(_ strip: StockStrip) -> some View {
        let catalog = StockCatalog.shared
        let p = session.edit.params
        let film = catalog.stock(p.filmStock)
        let scales = EnlargerScales.of(p, catalog: catalog)
        let trim = pair?.trim(on: session.layer, look: p) ?? HalfFramePair.PrintTrim(p)
        VStack(alignment: .leading, spacing: 0) {
            if catalog.isSlide(p.filmStock) {
                // As in Develop: a slide has no paper strip. What is printed is said instead.
                DrawnText(PanelNotes.slideTitle(film?.shortName ?? L("This film")), DevelopType.label, .semibold, fit: true)
                    .padding(.horizontal, Theme.Metric.margin).padding(.top, EnlargerStack.section)
                panelNote(PanelNotes.slide).padding(.top, EnlargerStack.noteGap)
            } else {
                EnlargerPaperRow(session: session, strip: strip, shelf: paperShelf)
                    .padding(.top, EnlargerStack.top)
                if catalog.isScanned(p) {
                    DrawnText(PanelNotes.scannedTitle, DevelopType.label, .semibold)
                        .padding(.horizontal, Theme.Metric.margin).padding(.top, EnlargerStack.section)
                    panelNote(PanelNotes.scanned).padding(.top, EnlargerStack.noteGap)
                } else {
                    HStack(spacing: 8) {
                        if let side, let hole = pair?[side] { scopePill(hole, side) }
                        else { SectionLabel(L("Enlarger")).lineLimit(1).minimumScaleFactor(0.75) }
                        Spacer(minLength: 0)
                        ChipRow(options: EnlargerTool.allCases, selection: $tool, title: { $0.title(on: scales) },
                                spacing: EnlargerStack.chipSpacing, padding: EnlargerStack.chipPadding)
                            .fixedSize()
                    }
                    .padding(.horizontal, Theme.Metric.margin)
                    .frame(minHeight: Theme.Metric.roundButton)
                    // The line is a 44 pt target round 30 pt pills: the gap is counted to the pills.
                    .padding(.top, EnlargerStack.section - (Theme.Metric.roundButton - EnlargerStack.chipHeight) / 2)
                    Group {
                        switch tool {
                        case .colour:
                            yellow(trim, scales)
                            magenta(trim, scales).padding(.top, EnlargerStack.rulerGap)
                        case .brightness:
                            rulerRow(L("Brightness"), Fmt.signed(trim.brightnessStops), sub: L("stops"),
                                     value: enlarger(.brightness, \.params.printBrightnessStops), range: -3...3, step: 0.1, majorEvery: 5,
                                     snap: 0.1, home: 0, onEditingChanged: session.editing(.print))
                            panelNote(PanelNotes.brightness).padding(.top, EnlargerStack.noteGap)
                        case .preflash:
                            // 0…0.03 of the wire's 0…1: the useful range, measured
                            // (FilmParams.preflashExposure).
                            rulerRow(L("Pre-flash"), String(format: "%.3f", trim.preflashExposure),
                                     value: enlarger(.preflash, \.params.preflashExposure), range: 0...0.03, step: 0.001, majorEvery: 5,
                                     snap: 0.001, onEditingChanged: session.editing(.print))
                            panelNote(PanelNotes.preflash).padding(.top, EnlargerStack.noteGap)
                        }
                    }
                    .padding(.top, EnlargerStack.afterTools - (Theme.Metric.roundButton - EnlargerStack.chipHeight) / 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Where an edit of this frame's print lands: on the frame, or on the frame
    /// and the film round it by the same amount (`PairScopePill`).
    private func scopePill(_ hole: HalfFramePair.Hole, _ side: HalfFramePair.Side) -> some View {
        PairScopePill(scope: hole.printScope, of: L("print")) { scope in
            model.changePair(session.frameID) { piece, _ in piece[side]?.printScope = scope }
        }
    }

    /// One of the enlarger's four values under a ruler: a photograph's own, or
    /// on a pair the picked layer's — through the piece, which knows whose
    /// print moves with whose (`HalfFramePair.print`).
    private func enlarger(_ field: PrintField, _ path: WritableKeyPath<FrameEdit, Double>) -> Binding<Double> {
        guard pair != nil else { return session.binding(path) }
        let id = session.frameID
        return Binding(get: { session.pair?.trim(on: session.layer, look: session.edit.params)[field] ?? session.edit[keyPath: path] },
                       set: { v in model.changePair(id) { piece, look in piece.print(field, v, on: session.layer, look: &look.params) } })
    }

    // 0.0125 a tick, 0.05 major: +0.10 and +0.05 both sit on a major tick,
    // where the drawing has them.
    private func yellow(_ trim: HalfFramePair.PrintTrim, _ scales: EnlargerScales) -> some View {
        rulerRow(L("Yellow"), Fmt.signed(trim.yFilterShift, decimals: 2), sub: scales.yellow,
                 value: enlarger(.yellow, \.params.yFilterShift), range: -1...1, step: 0.0125, majorEvery: 4,
                 spacing: 7.5, snap: 0.01,
                 tint: scales.tinted ? { Color.lerp(Self.yellowScale.0, Self.yellowScale.1, $0) } : nil,
                 onEditingChanged: session.editing(.print))
    }

    private func magenta(_ trim: HalfFramePair.PrintTrim, _ scales: EnlargerScales) -> some View {
        rulerRow(L("Magenta"), Fmt.signed(trim.mFilterShift, decimals: 2), sub: scales.magenta,
                 value: enlarger(.magenta, \.params.mFilterShift), range: -1...1, step: 0.0125, majorEvery: 4,
                 spacing: 7.5, snap: 0.01,
                 tint: scales.tinted ? { Color.lerp(Self.magentaScale.0, Self.magentaScale.1, $0) } : nil,
                 onEditingChanged: session.editing(.print))
    }
}

// MARK: - Scene (P3), pro-control's own

struct ScenePanel: View {
    let session: OpenFrameSession
    let frame: LibraryFrame
    @Binding var tool: SceneTool
    /// The camera's own numbers, kept from when the page opened under As Shot.
    let cameraWhiteBalance: (temperature: Double, tint: Double)?
    /// The tools its pills offer: the Scene tab's (`SceneTool.shown`), or Edit ›
    /// EngineRouter › Decode's, with Scene Placement beside White Balance (`SceneTool.decode`).
    var tools: [SceneTool] = SceneTool.shown
    /// Develop's Decode (`DecodeSection`, 2026-10-24): the white balance's rows alone, from the top
    /// of the band — its chips and its ↺ are the section's.
    var embedded = false
    @Environment(AppServices.self) private var model
    @Environment(FrameCatalog.self) private var library
    /// On a pair: each frame's camera's own numbers, as they were when this
    /// panel first showed the frame under As Shot.
    @State private var pairCamera: [LibraryFrame.ID: (temperature: Double, tint: Double)] = [:]

    /// **On a half-frame pair the two controls are one frame's**: each picture
    /// is its own file with its own decode. The frame is the one the page is
    /// about where a control is not the film's — the picked one, or with the
    /// film picked the one picked last (`OpenFrameSession.placementSide`, the
    /// desktop's `focusSide`) — and the panel names it. An edit is written to
    /// the frame itself (`AppServices.changeDecode`), so the photograph by itself
    /// changes with it, and the line under the controls says so.
    private var pair: HalfFramePair? { FeatureFlags.halfFramePair ? session.pair : nil }
    private var side: HalfFramePair.Side? { pair == nil ? nil : session.placementSide }
    /// The frame whose decode this is: the page's own; on a pair the focus
    /// frame, from the library — nil when it has left it.
    private var subject: LibraryFrame? {
        guard let pair else { return frame }
        return side.flatMap { pair[$0] }.flatMap { library.frame($0.frame) }
    }
    private var decode: DecodeSettings { pair == nil ? session.edit.decode : subject?.edit.decode ?? DecodeSettings() }
    private var camera: (temperature: Double, tint: Double)? {
        pair == nil ? cameraWhiteBalance : subject.flatMap { pairCamera[$0.id] }
    }

    /// The Pro panel's temperature and tint tints (`gen.pro_panel`).
    private static let temperatureScale = (0x5F86C9 as UInt32, 0xE0B25E as UInt32)
    private static let tintScale = (0x6FBF73 as UInt32, 0xB77BD0 as UInt32)

    /// Both controls reach a RAW file's decode and nothing else
    /// (`FrameDecoder`): on any other frame they would move nothing, so they
    /// stand down and the line says why — a HEIF or a JPEG, or a RAW the app
    /// has only a preview copy of (`LibraryFrame.developsFromRAW`; a RAW read
    /// in place from Photos is developed from its original, and is reached).
    /// The drawings' own frames are RAW.
    private var reach: PanelNotes.SceneReach {
        guard let subject else { return .gone }
        if subject.isDemo || subject.developsFromRAW { return pair == nil ? .raw : .rawInPair }
        return subject.isRAW ? .previewCopy : .notRAW
    }
    private var reaches: Bool { reach.reaches }

    /// Embedded, the rows move up by what the chips took.
    private var lift: CGFloat { embedded ? PanelY.Scene.first - DecodeSection.firstBaseline : 0 }
    /// Embedded, the band ends under the note's two lines.
    static let embeddedHeight = PanelY.Scene.note - (PanelY.Scene.first - DecodeSection.firstBaseline)
        + PanelY.Part.noteLead + 8

    var body: some View {
        let d = decode
        DrawnBand(height: embedded ? Self.embeddedHeight : PanelY.height) {
            if !embedded {
                HStack(spacing: 12) {
                    ChipRow(options: tools, selection: $tool, title: \.title, height: PanelY.Scene.chipHeight,
                            size: 12.5, padding: 12)
                    // Whose white balance and lens, and Scene Placement: the pair's focus frame.
                    if let pair, let side { DrawnText(pair.title(.init(side)), 11.5, .medium, Theme.dim) }
                }
                .leading(16).top(PanelY.Scene.chips)
            }
            switch tool {
            case .whiteBalance:
                // Back to As Shot: the camera's own. Embedded, the section's ↺ is it.
                if !embedded {
                    RoundButton(diameter: 2 * PanelY.Scene.resetRadius, label: L("As Shot"), action: {
                        change { d in
                            d.whiteBalance = .asShot
                            if let cam = camera { (d.temperature, d.tint) = cam }
                        }
                        lifted()
                    }) { Icon(.reset, size: 18) }
                    .rowEnabled(reaches && d.whiteBalance != .asShot)
                    .trailingInset(33 - PanelY.Scene.resetRadius)
                    .centreY(PanelY.Scene.reset)
                }
                rulerRow(L("Temperature"), "\(Int(d.temperature.rounded())) K",
                         sub: d.whiteBalance == .asShot ? L("As Shot") : nil,
                         value: whiteBalance(\.temperature), range: 2000...10000, step: 125, majorEvery: 4,
                         spacing: 7.5, snap: 50, tint: { Color.lerp(Self.temperatureScale.0, Self.temperatureScale.1, $0) },
                         onEditingChanged: editing)
                    .rowEnabled(reaches)
                    .baseline(PanelY.Scene.first - lift)
                rulerRow(L("Tint"), Fmt.signed(d.tint, decimals: 0),
                         value: whiteBalance(\.tint), range: -150...150, step: 5, majorEvery: 4, spacing: 7.5,
                         snap: 1, tint: { Color.lerp(Self.tintScale.0, Self.tintScale.1, $0) },
                         onEditingChanged: editing)
                    .rowEnabled(reaches)
                    .baseline(PanelY.Scene.second - lift)
                panelNote(PanelNotes.whiteBalance(reach)).baseline(PanelY.Scene.note - lift)
            case .lens:
                DrawnText(L("Lens correction"), DevelopType.label, .semibold).leading(16).baseline(PanelY.Scene.first)
                SpkToggle(isOn: Binding(get: { d.lensCorrection },
                                        set: { on in change { $0.lensCorrection = on }; lifted() }))
                    .rowEnabled(reaches)
                    .trailingInset(16)
                    .top(PanelY.Scene.lensSwitch)
                    .accessibilityLabel(L("Lens correction"))
                panelNote(PanelNotes.lens(reach)).baseline(PanelY.Scene.lensNote)
            case .placement:
                // pro-control's Scene Placement page, as it was, at this page's rows. It is the
                // film's latitude, not the file's decode: it reaches every frame the film is applied
                // to, RAW or not, and stands down with the film off (Apply Film Emulation).
                let placement = session.placement
                let film = StockCatalog.shared.stock(session.edit.params.filmStock)?.shortName ?? L("the film")
                Group {
                    scenePlacementRuler(session, .highlight, placement[.highlight]).baseline(PanelY.Scene.first)
                    scenePlacementRuler(session, .shadow, placement[.shadow]).baseline(PanelY.Scene.second)
                    scenePlacementNote(placement, plain: PanelNotes.placement(film: film, pro: true)).baseline(PanelY.Scene.note)
                }
                .rowEnabled(session.edit.appliesFilm)
            }
        }
        // The camera's own numbers for a pair's frame, kept from when the panel first shows it under As Shot.
        .task(id: subject?.id) {
            guard pair != nil, let subject, subject.edit.decode.whiteBalance == .asShot, pairCamera[subject.id] == nil else { return }
            pairCamera[subject.id] = (subject.edit.decode.temperature, subject.edit.decode.tint)
        }
    }

    /// An edit of the decode: the page's own frame's, through its session; on
    /// a pair the focus frame's own, through the model, which writes the frame
    /// and has the piece composed again.
    private func change(_ mutate: (inout DecodeSettings) -> Void) {
        guard pair != nil else { session.change { mutate(&$0.decode) }; return }
        if let side { model.changeDecode(of: side, in: session.frameID, mutate) }
    }

    /// A ruler's finger, down and up. On a pair its lifting is also when the
    /// photograph's own kept picture is made again.
    private var editing: (Bool) -> Void {
        let page = session.editing(.shoot)
        return { down in
            page(down)
            if !down { lifted() }
        }
    }

    /// A control of a pair's frame was let go: its own kept develop follows.
    private func lifted() {
        if pair != nil, let side { model.keepDecode(of: side, in: session.frameID) }
    }

    /// Moving temperature or tint leaves As Shot for the numbers on the scale.
    private func whiteBalance(_ path: WritableKeyPath<DecodeSettings, Double>) -> Binding<Double> {
        Binding(get: { decode[keyPath: path] },
                set: { v in change { d in d[keyPath: path] = v; d.whiteBalance = .custom } })
    }
}

// MARK: - Effects (B4, B5, P4–P6)

struct EffectsPanel: View {
    let session: OpenFrameSession
    let frame: LibraryFrame
    let pro: Bool
    /// Pro: the page an effect has.
    @Binding var page: EffectsPage
    /// Basic: Scene Placement's own page is open, over the three strengths.
    @Binding var placementOpen: Bool
    /// Pro: the pages its chips offer — every one on edit_v2's Effects tab; Edit ›
    /// EngineRouter's Effects tile leaves Scene Placement to Decode (`EffectsPage.darkroom`).
    var pages: [EffectsPage] = EffectsPage.allCases
    /// Develop › Film & Paper's
    /// effects in a wide window, "平铺" — Grain, Halation, Scatter, Glare and Couplers, every ruler shown,
    /// no chips (`flatHeight`). Grain's Sub-layers switch is not among them: its value keeps rendering.
    var flat = false

    /// The flat panel's height: its title line, and five rulers 56 pt apart, as the basic page's three.
    static let flatHeader: CGFloat = 30
    static let flatPitch: CGFloat = 56
    static var flatHeight: CGFloat {
        flatHeader + PanelY.Effects.strengths[0] + 4 * flatPitch + PanelY.Part.rulerDrop + PanelY.Part.rulerHalf + 8
    }

    private var params: FilmParams { session.edit.params }
    private var film: String { StockCatalog.shared.stock(params.filmStock)?.shortName ?? L("the film") }
    private var paper: String { StockCatalog.shared.stock(params.printStock)?.shortName ?? L("the paper") }
    /// Nothing is printed: the paper's veil has no paper.
    private var scanned: Bool { StockCatalog.shared.isScanned(params) }
    /// The size grain is seen at: the film's, or the film edge's own format.
    /// A half-frame pair is two half frames whatever its look calls the piece
    /// (`HalfFramePair.look`: Custom, 24 on its long side).
    private var sizeName: String {
        if FeatureFlags.halfFramePair, session.pair != nil { return FilmEdgeFormat.half.label }
        return session.edit.filmEdge.effective ? session.edit.filmEdge.format.label : params.filmFrame
    }
    /// On a half-frame pair the film's effects are the piece's — one film —
    /// and **Scene Placement is one frame's**: each was its own exposure of
    /// its own scene (`FilmParams.sceneLatitudeOther`). The frame it is: the
    /// picked one, or with the film picked the one picked last.
    private var placementOf: String? {
        guard FeatureFlags.halfFramePair, let pair = session.pair, let side = session.placementSide else { return nil }
        return pair.title(.init(side))
    }

    var body: some View {
        if flat { flatPage } else { pagedBody }
    }

    private var pagedBody: some View {
        DrawnBand(height: PanelY.height) {
            if pro {
                proPage
            } else if placementOpen {
                placementPage
            } else {
                strengths
            }
        }
    }

    // MARK: flat (a wide window's Develop)

    private var flatPage: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Effects")).font(Theme.Font.ui(13, .semibold)).foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: Self.flatHeader, alignment: .bottom)
            DrawnBand(height: Self.flatHeight - Self.flatHeader) {
                let first = PanelY.Effects.strengths[0]
                grain.baseline(first)
                halation.baseline(first + Self.flatPitch)
                scatter.baseline(first + 2 * Self.flatPitch)
                glare.baseline(first + 3 * Self.flatPitch)
                couplers.baseline(first + 4 * Self.flatPitch)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v5.develop.effects")
    }

    // MARK: basic

    /// The three strengths on one page, each named for what leaves it: the
    /// film on its size, the film, the paper. Under them, Scene Placement.
    @ViewBuilder private var strengths: some View {
        grain.baseline(PanelY.Effects.strengths[0])
        halation.baseline(PanelY.Effects.strengths[1])
        glare.baseline(PanelY.Effects.strengths[2])
        Rectangle().fill(Theme.rule).frame(height: Theme.Metric.rule)
            .padding(.horizontal, Theme.Metric.margin).top(PanelY.Effects.rule - 0.5)
        Button { withAnimation(.easeOut(duration: 0.18)) { placementOpen = true } } label: {
            DrawnBand(height: 36) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    DrawnText(L("Scene Placement"), DevelopType.label, .semibold)
                    if let placementOf { DrawnText(placementOf, 11.5, .medium, Theme.dim) }
                }
                .leading(16).baseline(21)
                DrawnText(Self.placementText(params.sceneLatitude, short: placementOf != nil), 12.5, .medium, Theme.secondaryText)
                    .trailingInset(30).baseline(21)
                Chevron().trailingInset(16).centreY(21 - 4.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 1))
        .top(PanelY.Effects.placementRow - 21)
    }

    /// Scene Placement's own page, from its row: the way back, and Highlight
    /// alone — the side the engine's Fit takes something of on every frame
    /// measured (README, "Scene Placement": Highlight on ten of ten, Shadow on four).
    @ViewBuilder private var placementPage: some View {
        let placement = session.placement
        Button { withAnimation(.easeOut(duration: 0.18)) { placementOpen = false } } label: {
            DrawnBand(width: 110, height: 44) {
                Icon(.back).centreX(22).centreY(22)
                DrawnText(L("Effects"), DevelopType.label, .medium, Theme.secondaryText).leading(36).baseline(PanelY.Effects.back)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(L("Back to Effects"))
        .top(0)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let placementOf { DrawnText(placementOf, 11.5, .medium, Theme.dim) }
            DrawnText(L("Scene Placement"), DevelopType.label, .semibold)
        }
        .trailingInset(16).baseline(PanelY.Effects.back)
        Rectangle().fill(Theme.rule).frame(height: Theme.Metric.rule)
            .padding(.horizontal, Theme.Metric.margin).top(PanelY.Effects.backRule - 0.5)
        placementRuler(.highlight, placement[.highlight]).baseline(PanelY.Effects.highlight)
        placementNote(placement, plain: PanelNotes.placement(film: film, pro: false)).baseline(PanelY.Effects.placementNote)
    }

    // MARK: pro-control

    /// A page an effect, each with more than its strength to hold.
    @ViewBuilder private var proPage: some View {
        EffectsChips(pages: pages, page: $page).top(PanelY.Effects.chips)
        switch page {
        case .grain:
            grain.baseline(PanelY.Effects.first)
            panelNote(PanelNotes.grain(film: film, size: sizeName)).baseline(PanelY.Effects.noteAfterOne)
            // A black-and-white film's grain is one layer whatever the frame
            // says (`StockCatalog.silver`): the switch would move nothing
            // there, so it stands down and shows what is sent.
            let layered = StockCatalog.shared.grainIsLayered(on: params.filmStock)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                DrawnText(L("Sub-layers"), DevelopType.label, .semibold)
                DrawnText(PanelNotes.subLayers(layered: params.effects.grainLayered, filmIsLayered: layered), 11.5, .medium, Theme.dim)
            }
            .leading(16).baseline(PanelY.Effects.subLayers)
            SpkToggle(isOn: Binding(get: { params.effects.grainLayered && layered },
                                    set: { on in session.change { $0.params.effects.grainLayered = on } }))
                .rowEnabled(layered)
                .trailingInset(16).top(PanelY.Effects.subLayersSwitch)
                .accessibilityLabel(L("Grain sub-layers"))
        case .halation:
            halation.baseline(PanelY.Effects.first)
            scatter.baseline(PanelY.Effects.second)
            panelNote(PanelNotes.halation).baseline(PanelY.Effects.noteAfterTwo)
        case .glare:
            glare.baseline(PanelY.Effects.first)
            panelNote(PanelNotes.glare(paper: scanned ? nil : paper)).baseline(PanelY.Effects.noteAfterOne)
        case .couplers:
            couplers.baseline(PanelY.Effects.first)
            panelNote(PanelNotes.couplers(film: film)).baseline(PanelY.Effects.noteAfterOne)
        case .placement:
            let placement = session.placement
            placementRuler(.highlight, placement[.highlight]).baseline(PanelY.Effects.first)
            placementRuler(.shadow, placement[.shadow]).baseline(PanelY.Effects.second)
            placementNote(placement, plain: PanelNotes.placement(film: film, pro: true)).baseline(PanelY.Effects.noteAfterTwo)
        }
    }

    // MARK: the rulers

    // A thirtieth a tick, a tenth major: 1.00× sits on a major tick, as drawn.
    // The dot on a scale is the film's own strength.
    private var grain: some View {
        rulerRow(L("Grain"), Fmt.times(params.effects.grain), sub: film + Fmt.dot + sizeName,
                 value: session.binding(\.params.effects.grain), range: EffectStrengths.grainRange, step: 1.0 / 30,
                 majorEvery: 3, snap: 0.01, home: 1, onEditingChanged: session.editing(.shoot))
    }

    private var halation: some View {
        rulerRow(L("Halation"), Fmt.times(params.effects.halation), sub: film,
                 value: session.binding(\.params.effects.halation), range: EffectStrengths.halationRange, step: 1.0 / 30,
                 majorEvery: 3, snap: 0.01, home: 1, onEditingChanged: session.editing(.shoot))
    }

    private var scatter: some View {
        rulerRow(L("Scatter"), String(format: "%.2f", params.effects.scatter), sub: L("inside the emulsion"),
                 value: session.binding(\.params.effects.scatter), range: EffectStrengths.scatterRange, step: 1.0 / 30,
                 majorEvery: 3, snap: 0.01, onEditingChanged: session.editing(.shoot))
    }

    private var couplers: some View {
        rulerRow(L("Couplers"), Fmt.times(params.effects.couplers), sub: film,
                 value: session.binding(\.params.effects.couplers), range: EffectStrengths.couplersRange, step: 1.0 / 30,
                 majorEvery: 3, snap: 0.01, home: 1, onEditingChanged: session.editing(.shoot))
    }

    /// The paper's veil: a quarter a tick, a whole one major, over 0…30
    /// (`EffectStrengths.glareRange`: the paper's own is a whisper). Under a
    /// scan there is no paper, and the row stands down.
    private var glare: some View {
        rulerRow(L("Glare"), String(format: "%.1f×", params.effects.glare), sub: scanned ? L("no print") : paper,
                 value: session.binding(\.params.effects.glare), range: EffectStrengths.glareRange, step: 0.25,
                 majorEvery: 4, snap: 0.1, home: 1, onEditingChanged: session.editing(.print))
            .rowEnabled(!scanned)
    }

    private func placementRuler(_ side: PlacementSide, _ row: PlacementPanel.Row) -> some View {
        scenePlacementRuler(session, side, row)
    }

    private func placementNote(_ placement: PlacementPanel, plain: [String]) -> some View {
        scenePlacementNote(placement, plain: plain)
    }

    /// "Highlight 1.50", "Highlight 1.50 · Shadow 0.30", "Off": the row's value.
    /// `short`, where a frame's name shares the row: "H 1.50 · S 0.30" for both.
    static func placementText(_ s: SceneLatitudeSettings, short: Bool = false) -> String {
        let both = short && s.highlightPullBack > 0 && s.shadowPullBack > 0
        let parts = [s.highlightPullBack > 0 ? String(format: both ? L("H %.2f") : L("Highlight %.2f"), s.highlightPullBack) : nil,
                     s.shadowPullBack > 0 ? String(format: both ? L("S %.2f") : L("Shadow %.2f"), s.shadowPullBack) : nil].compactMap { $0 }
        return parts.isEmpty ? L("Off") : parts.joined(separator: " · ")
    }
}

/// One of Scene Placement's two rulers: Effects' page under pro-control, and Edit ›
/// EngineRouter › Decode's second pill (2026-10-22). The number beside it is the side's
/// pull-back; the ruler's own is a position along a scale that holds only
/// what the Fit takes (`PlacementRuler`), a twelfth of a stop a tick and
/// quarter stops major. A step is solved and committed as it is made
/// (`OpenFrameSession.placeScene`); the picture develops when the finger
/// rests. A side the Fit takes nothing of has an empty scale, dimmed, and
/// the line below says why.
@MainActor private func scenePlacementRuler(_ session: OpenFrameSession, _ side: PlacementSide, _ row: PlacementPanel.Row) -> some View {
    rulerRow(L(shown: side.name), String(format: "%.2f", session.edit.params.sceneLatitude[side]), sub: L("stops"),
             value: Binding(get: { row.ruler.position(of: session.edit.params.sceneLatitude[side]) },
                            set: { session.placeScene(row.ruler.pullBack(at: $0), moving: side) }),
             range: row.ruler.range, step: 1.0 / 12, majorEvery: 3, snap: PlacementRuler.step,
             onEditingChanged: session.placing(side))
        .rowEnabled(row.enabled)
}

/// The line under Scene Placement's rulers: what is news first (why a ruler starts or
/// ends where it does, in the accent when the Fit refused), else the
/// drawing's words.
@MainActor @ViewBuilder private func scenePlacementNote(_ placement: PlacementPanel, plain: [String]) -> some View {
    if let note = placement.note {
        panelNote(wrapping: note.text, color: note.refused ? Theme.accent : Theme.dim)
    } else {
        panelNote(plain)
    }
}

/// Pro's five pages of Effects, as chips (`panel_effects`): the drawing's row,
/// 356 pt of its 393. A narrower host has not the width for it, so there the
/// row moves under a finger, and keeps the chosen chip in view. Edit › EngineRouter's
/// Effects tile shows four of them (`EffectsPage.darkroom`).
private struct EffectsChips: View {
    let pages: [EffectsPage]
    @Binding var page: EffectsPage

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                ChipRow(options: pages, selection: $page, title: \.title, spacing: 6,
                        height: PanelY.Effects.chipHeight, size: 12.5, padding: 9)
                    .padding(.horizontal, 16)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onAppear { proxy.scrollTo(page, anchor: .center) }
            .onChange(of: page) { _, now in
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(now, anchor: .center) }
            }
        }
    }
}

/// The card rows' own padding for the selection frame: a page places a row
/// this far above where the drawing has its cards' top.
enum CardRowMetric {
    static let framePadding: CGFloat = 3
}
