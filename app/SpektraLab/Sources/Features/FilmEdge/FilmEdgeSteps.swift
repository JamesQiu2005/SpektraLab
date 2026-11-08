//  FilmEdgeSteps.swift — the four steps' controls, under the steps' rule.
//
//  `gen_overscan.reference(step)`. Every y below is the generator's minus 522,
//  the rule under the steps. What the generator does not draw is said in each
//  panel's own comment.

import SwiftUI

// MARK: - 1 · Film

/// Format cards, each the format's own film around this picture, then the
/// view: the whole film width, or a filed carrier's sliver of rebate.
struct FilmStepPanel: View {
    let frame: LibraryFrame
    @Binding var draft: FrameEdit
    let width: CGFloat
    let pick: (FilmEdgeFormat) -> Void
    /// On Half: this frame becomes the first of two on one piece of film
    /// (the page layout the desktop's *Enter Half-Frame
    /// Pair*). Nil where a pair cannot be entered from — the frame is one.
    var enterPair: (() -> Void)? = nil

    @Environment(AppServices.self) private var model

    private var stock: Stock? { StockCatalog.shared.stock(draft.params.filmStock) }

    /// Mac (the owner, 2026-10-23: "lay every choice out on the page; no horizontal scroll at all"):
    /// the cards wrap into rows across the panel, each as drawn (72 × 92, 9 apart), and everything
    /// under them moves down by the rows added.
    private static let cardGap: CGFloat = 9
    private var cardRows: Int {
        let perRow = max(1, Int((width - 32 + Self.cardGap) / (72 + Self.cardGap)))
        return (FilmEdgeFormat.allCases.count + perRow - 1) / perRow
    }
    /// How much taller the cards are than the host's one row (92 + its 3 pt above and below).
    private var extra: CGFloat { CGFloat(cardRows) * 92 + CGFloat(cardRows - 1) * Self.cardGap + 6 - 98 }

    var body: some View {
        DrawnBand(height: 226 + extra) {
            DrawnText(L("Format", as: "of film"), 14, .semibold).leading(16).baseline(30)
            if FeatureFlags.halfFramePair, draft.filmEdge.format == .half, let enterPair {
                PairFormatLink(enter: enterPair).trailingInset(16).centreY(25.5)
            } else {
                DrawnText(stock?.madeInText ?? "", 12, .medium, Theme.dim).trailingInset(16).baseline(30)
            }
            ChipFlow(spacing: Self.cardGap, lineSpacing: Self.cardGap) {
                ForEach(FilmEdgeFormat.allCases) { format in card(format) }
            }
            .frame(width: width - 32, alignment: .leading)
            .padding(.vertical, 3)
            .leading(16).top(41)
            DrawnText(L("View"), 14, .semibold).leading(16).baseline(168 + extra)
            SegmentedSwitch(options: FilmEdgeView.allCases, selection: $draft.filmEdge.mode, title: \.label,
                            segmentWidth: 92, track: Theme.card)
                .trailingInset(16).top(152 + extra)
            DrawnText(L("Strip shows the full film width: ×\(cost(.strip)) pixels."), 11.5, .medium, Theme.dim)
                .leading(16).baseline(200 + extra)
            DrawnText(L("Filed shows a sliver of rebate: ×\(cost(.filed))."), 11.5, .medium, Theme.dim)
                .leading(16).baseline(216 + extra)
        }
    }

    /// The draft as one format's card shows it: that format, lying the way
    /// the picture does, its largest cut, no date.
    private func variant(_ format: FilmEdgeFormat) -> FrameEdit {
        var e = draft
        if format != draft.filmEdge.format {
            let a = frame.originalSize.aspect
            e.filmEdge.format = format
            e.filmEdge.turn = format.defaultTurn(pictureAspect: e.geometry.quarterTurns % 2 == 0 ? a : 1 / max(a, 0.0001))
            e.filmEdge.framing = nil
        }
        e.dateBack.active = false
        return e
    }

    private func cost(_ mode: FilmEdgeView) -> String {
        var e = variant(draft.filmEdge.format)
        e.filmEdge.mode = mode
        guard let film = model.filmEdge(for: frame, edit: e, forcing: true) else { return "—" }
        return String(format: "%.2f", film.geometry.cost)
    }

    private func card(_ format: FilmEdgeFormat) -> some View {
        let on = format == draft.filmEdge.format
        let made = stock?.isMade(in: format) ?? true
        let edit = variant(format)
        return Button { pick(format) } label: {
            DrawnBand(width: 72, height: 92) {
                RoundedRectangle(cornerRadius: Theme.Metric.cardRadius).fill(Theme.card)
                    .frame(width: 72, height: 92).top(0)
                Group {
                    if let film = model.filmEdge(for: frame, edit: edit, forcing: true) {
                        FilmCanvasView(geometry: film.geometry, style: .developed, picture: frame.picture,
                                       sourceSize: CGSize(width: frame.originalSize.width, height: frame.originalSize.height),
                                       framing: film.framing, pointSize: 62,
                                       ink: EdgeLook.of(edit.params.filmStock).ink(on: format))
                    }
                }
                .frame(width: 62, height: 50).leading(5).top(5)
                DrawnBand(width: 72, height: 92) {
                    DrawnText(format.label, 13, .semibold).leading(8).baseline(68)
                    DrawnText(format.aspectText, 10, .medium, Theme.dim).leading(8).baseline(83)
                }
                .top(0)
            }
            .overlay {
                if on {
                    RoundedRectangle(cornerRadius: 11.5).stroke(Theme.selectionFrame, lineWidth: 2).padding(-1.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        // A format this stock was never made in is shown, and cannot be chosen:
        // the line beside *Format* says which gauges it was made in.
        .rowEnabled(made)
        .accessibilityLabel(format.label + ", " + format.aspectText + (made ? "" : L(", not made in this film")))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - 2 · Frame

/// Straighten, and the ledger: what develops, said plainly when the budget
/// scales it. Dragging and pinching happen on the preview.
struct FrameStepPanel: View {
    let film: ResolvedFilmEdge?
    @Binding var draft: FrameEdit
    let source: CGSize
    let photo: Geometry

    var body: some View {
        DrawnBand(height: 226) {
            RulerRow(label: L("Straighten"), valueText: Fmt.signed(angle) + "°",
                     value: Binding(get: { angle }, set: { straighten($0) }),
                     range: -Geometry.maxAngle...Geometry.maxAngle, step: 1, majorEvery: 3, snap: 0.1, rulerDrop: 28)
                .padding(.horizontal, Theme.Metric.margin)
                .baseline(34)
            DrawnText(L("Drag and pinch to place the picture. ↻ turns the film."), 11.5, .medium, Theme.dim)
                .leading(16).baseline(96)
            if let film { FilmLedger(film: film).padding(.horizontal, 12).top(114) }
        }
    }

    private var framing: Geometry {
        film?.framing ?? FilmFraming.resolved(draft.filmEdge, source: source, photo: photo)
    }
    private var angle: Double { framing.angle }

    /// The photo's straighten, the crop page's one (2026-10-25): the framing
    /// takes it from the photo (`FilmFraming.corrected`), so a straighten kept
    /// on the framing alone would be undone. The flow writes it on the frame
    /// (`FilmEdgeFlow.commit`).
    private func straighten(_ degrees: Double) {
        draft.geometry = draft.geometry.straightened(to: degrees, in: source)
        draft.filmEdge.framing = framing.straightened(to: degrees, in: source)
    }
}

/// The Frame step's ledger: the picture in the film, in pixels, against the
/// device's film budget.
struct FilmLedger: View {
    let film: ResolvedFilmEdge

    var body: some View {
        DrawnBand(height: 104) {
            RoundedRectangle(cornerRadius: 12).fill(Theme.plot).frame(height: 104).top(0)
            DrawnText(L("Picture"), 13, .medium, Theme.secondaryText).leading(14).baseline(24)
            DrawnText(sizeText(film.picture), 13, .semibold).trailingInset(14).baseline(24)
            DrawnText(L("Film"), 13, .medium, Theme.secondaryText).leading(14).baseline(46)
            DrawnText(sizeText(film.film), 13, .semibold).trailingInset(14).baseline(46)
            GeometryReader { geo in
                let w = geo.size.width
                let picture = w * CGFloat((film.picture.megapixels / film.budgetMP).clamped(to: 0...1))
                let whole = w * CGFloat((film.film.megapixels / film.budgetMP).clamped(to: 0...1))
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.rule)
                    // the film's share, then the picture's over it
                    UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3,
                                           bottomTrailingRadius: whole >= w - 0.5 ? 0 : 3, topTrailingRadius: whole >= w - 0.5 ? 0 : 3)
                        .fill(Theme.dim).frame(width: max(whole, picture))
                    Capsule().fill(Theme.secondaryText).frame(width: picture)
                }
            }
            .frame(height: 6)
            .padding(.horizontal, 14)
            .top(64)
            DrawnText(note, 11.5, .medium, Theme.dim, fit: true).spanning(leading: 14, trailing: 14).baseline(92)
        }
        .accessibilityElement(children: .combine)
    }

    private func sizeText(_ s: PixelSize) -> String { s.text + Fmt.dot + Fmt.megapixels(s.megapixels) }

    /// A reduced picture is never left to pass for the whole one.
    private var note: String {
        if film.isScaled {
            return L("Scaled from \(Fmt.megapixels(film.cut.megapixels)) to fit this Mac’s \(Int(film.budgetMP)) MP film.")
        }
        return L("The border is added outside the picture: it takes none of its pixels.")
    }
}

// MARK: - 3 · Edge

/// What that camera and that scan did, one tool at a time: Gate · Holes ·
/// Light · Edge Print · Body. The design draws the Gate panel; the others are
/// built here in the same panel, from the desktop section's rows. Edge Print
/// (2026-10-20): the edge print's brightness, shown greyed (the engine has no edge gain).
struct EdgeStepPanel: View {
    let film: ResolvedFilmEdge?
    @Binding var draft: FrameEdit
    @Binding var tool: EdgeTool
    let width: CGFloat
    /// A ruler's finger landed (true) or lifted (false).
    let editing: (Bool) -> Void
    /// The draft changed and should reach the frame.
    let changed: () -> Void
    /// a wide window's column
    /// (`FilmEdgeColumn`) lays the five tools' panels one after another, a rule between, with no
    /// chooser of tools and no card behind them — "no second layer". `tool` is not read there.
    var flat = false

    /// What the rulers fade into: the panel's card, or in the column the page itself.
    private var ground: Color { flat ? Theme.background : Theme.panel }

    @ViewBuilder var body: some View {
        if flat {
            VStack(spacing: 0) {
                ForEach(EdgeTool.allCases) { t in
                    Rectangle().fill(Theme.rule).frame(height: Theme.Metric.rule).padding(.horizontal, Theme.Metric.margin)
                    toolPanel(t, width)
                }
            }
        } else {
            chooser
        }
    }

    private var chooser: some View {
        DrawnBand(height: 240) {
            ForEach(Array(EdgeTool.allCases.enumerated()), id: \.element) { i, t in
                // The drawing's 84 pt between four discs; five share the same span less a little.
                let middle = CGFloat(EdgeTool.allCases.count - 1) / 2
                let x = width / 2 + (CGFloat(i) - middle) * 70
                let on = t == tool
                Button { withAnimation(.easeOut(duration: 0.15)) { tool = t } } label: {
                    Group {
                        // Apple's own symbol where the drawing has no glyph.
                        if t == .print { Image(systemName: "textformat").font(.system(size: 16, weight: .medium)) }
                        else { EdgeToolGlyph(tool: t, color: on ? Theme.onSelection : Theme.text) }
                    }
                    .foregroundStyle(on ? Theme.onSelection : Theme.text)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(on ? Theme.selection : Theme.card))
                        .contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(L(shown: t.rawValue))
                .accessibilityIdentifier("film-edge.tool." + String(describing: t))
                .accessibilityAddTraits(on ? .isSelected : [])
                .centreX(x).centreY(40)
                DrawnText(L(shown: t.rawValue), 11.5, on ? .semibold : .medium, on ? Theme.text : Theme.secondaryText)
                    .centreX(x).baseline(78)
            }
            panel.padding(.horizontal, 12).top(100)
        }
    }

    private var edge: FilmEdgeSettings { draft.filmEdge }

    private func set<T: Equatable>(_ path: WritableKeyPath<FilmEdgeSettings, T>, _ value: T) {
        guard draft.filmEdge[keyPath: path] != value else { return }
        draft.filmEdge[keyPath: path] = value
        changed()
    }

    @ViewBuilder private var panel: some View {
        let w = width - 24
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14).fill(Theme.panel).frame(height: 132)
            toolPanel(tool, w)
        }
        .frame(height: 132)
    }

    @ViewBuilder private func toolPanel(_ t: EdgeTool, _ w: CGFloat) -> some View {
        switch t {
        case .gate: gatePanel(w)
        case .holes: holesPanel(w)
        case .light: lightPanel
        case .print: printPanel
        case .body: bodyPanel
        }
    }

    // Gate, as drawn: the family as chips, wrapped at the panel's margin.
    private func gatePanel(_ w: CGFloat) -> some View {
        let made = film?.geometry.gateFamily ?? .square
        return DrawnBand(height: 132) {
            DrawnText(L("Gate"), 14, .semibold).leading(16).baseline(26)
            DrawnText(edge.gate == .auto ? L("Auto · \(made.label)") : edge.gate.label, 13, .medium, Theme.secondaryText)
                .trailingInset(16).baseline(26)
            ChipFlow(spacing: 8, lineSpacing: 8) {
                ForEach(FilmEdgeGate.chips) { g in
                    Chip(title: g.label, on: g == edge.gate, height: 28, size: 12.5, padding: 15) { set(\.gate, g) }
                }
            }
            .frame(width: w - 32, alignment: .leading)
            .leading(16).top(42)
            DrawnText(gateNote(made), 11.5, .medium, Theme.dim, fit: true).spanning(leading: 16, trailing: 16).baseline(122)
        }
    }

    private func gateNote(_ made: FilmEdgeGate) -> String {
        switch edge.gate {
        case .auto: L("Auto: the corners \(edge.format.label) cameras have.")
        case .square: L("Square: plain corners, a hair to a third of a millimetre round.")
        case .rounded: L("Rounded: true radii, as a 645 rangefinder’s gate.")
        case .eared: L("Eared: thin ears at the corners, as a 645 SLR’s gate.")
        case .kicked: L("Kicked: two corners kick out, as a 6×6 insert’s.")
        case .shouldered: L("Shouldered: a recess between two ears, as a 6×8 back’s.")
        }
    }

    // Holes: what the scan sees through the perforations.
    private func holesPanel(_ w: CGFloat) -> some View {
        let has = FilmEdgeOptions.holes(edge)
        return DrawnBand(height: 132) {
            DrawnText(L("Holes"), 14, .semibold).leading(16).baseline(26)
            DrawnText(has ? edge.holes.label : L("None"), 13, .medium, Theme.secondaryText).trailingInset(16).baseline(26)
            SegmentedSwitch(options: FilmEdgeHoles.allCases,
                            selection: Binding(get: { edge.holes }, set: { set(\.holes, $0) }),
                            title: \.label, segmentWidth: 92, track: Theme.card)
                .rowEnabled(has)
                .accessibilityHint(has ? "" : holesNote(has))
                .leading(16).top(42)
            DrawnText(holesNote(has), 11.5, .medium, Theme.dim, fit: true).spanning(leading: 16, trailing: 16).baseline(122)
        }
    }

    private func holesNote(_ has: Bool) -> String {
        guard has else { return L("120 film has no perforations.") }
        return edge.holes == .white ? L("White: the scan’s light through the holes.")
                                    : L("Black: a black backing, or a darkroom print of the strip.")
    }

    // Light: the spool's light at the film's long edges.
    private var lightPanel: some View {
        DrawnBand(height: 132) {
            RulerRow(label: L("Edge fog"), valueText: String(format: "%.1f", edge.fog),
                     value: Binding(get: { edge.fog }, set: { set(\.fog, $0) }),
                     range: FilmEdgeSettings.fogRange, step: 0.1, majorEvery: 5, snap: 0.1, ground: ground,
                     onEditingChanged: editing)
                .padding(.horizontal, 16).top(8)
            RulerRow(label: L("Spool leaks"), valueText: String(format: "%.1f", edge.leaks),
                     value: Binding(get: { edge.leaks }, set: { set(\.leaks, $0) }),
                     range: FilmEdgeSettings.leaksRange, step: 0.1, majorEvery: 5, snap: 0.1, ground: ground,
                     onEditingChanged: editing)
                .padding(.horizontal, 16).top(69)
        }
    }

    // Edge Print: the light the film's own words were printed with. The engine has no edge
    // gain, so the ruler is shown at the edit's value and does not move: every film edge is
    // printed at 1×, as the film was measured.
    private var printPanel: some View {
        DrawnBand(height: 132) {
            // In the column there is no disc above to say whose brightness it is: the ruler says it.
            RulerRow(label: flat ? L(shown: EdgeTool.print.rawValue) : L("Brightness"),
                     valueText: String(format: "%.1f×", edge.edgeBrightness),
                     value: .constant(edge.edgeBrightness),
                     range: FilmEdgeSettings.brightnessRange, step: 0.1, majorEvery: 5, snap: 0.1, ground: ground,
                     home: 1, onEditingChanged: editing)
                .padding(.horizontal, 16).top(8)
                .disabled(true)
                .opacity(0.4)
            DrawnText(L("The light the film’s name, numbers and barcode were printed with."), 11.5, .medium, Theme.dim, fit: true)
                .spanning(leading: 16, trailing: 16).baseline(106)
            DrawnText(L("Printed at 1× on the Mac: as the film was measured."), 11.5, .medium, Theme.dim, fit: true)
                .spanning(leading: 16, trailing: 16).baseline(122)
        }
    }

    // Body: the camera, the frame's number, and the advance. The number is
    // the edge print's, so it is greyed where the print is not in the scan,
    // and the note says why in place of what the body does.
    private var bodyPanel: some View {
        let numberReason = FilmEdgeOptions.frameNumberReason(edge, stockID: draft.params.filmStock)
        let numbered = numberReason == nil
        return DrawnBand(height: 132) {
            DrawnText(L("Body"), 14, .semibold).leading(16).baseline(26)
            DrawnText(L("No. \(edge.cameraSeed)"), 13, .medium, Theme.secondaryText).trailingInset(124).baseline(26)
            DicePill(title: L("Another")) {
                var next = edge.cameraSeed
                while next == edge.cameraSeed { next = Int.random(in: FilmEdgeSettings.bodyRange) }
                set(\.cameraSeed, next)
            }
            .trailingInset(16).centreY(22)

            Group {
                DrawnText(L("Frame no."), 14, .semibold).leading(16).baseline(62)
                DrawnText(edge.frameNumber == 0 ? L("Auto") : "\(edge.frameNumber)", 13, .medium, Theme.secondaryText)
                    .trailingInset(124).baseline(62)
            }
            .rowEnabled(numbered)
            HStack(spacing: 8) {
                StepButton(symbol: "−") { set(\.frameNumber, max(edge.frameNumber - 1, 0)) }
                    .rowEnabled(numbered && edge.frameNumber > 0)
                    .disabled(!numbered)
                StepButton(symbol: "+") { set(\.frameNumber, min(edge.frameNumber + 1, 99)) }
                    .rowEnabled(numbered && edge.frameNumber < 99)
                    .disabled(!numbered)
            }
            .accessibilityHint(numberReason ?? "")
            .trailingInset(16).centreY(58)

            DrawnText(L("Advance"), 14, .semibold).leading(16).baseline(98)
            DicePill(title: L("Another frame")) {
                draft.frameSeed = Int.random(in: 1...Int(Int32.max))
                changed()
            }
            .trailingInset(16).centreY(94)
            DrawnText(numberReason ?? L("The body sets the gate, the margins and where the holes fall."),
                      11.5, .medium, Theme.dim, fit: true)
                .spanning(leading: 16, trailing: 16).baseline(122)
        }
    }
}

/// *Another* and *Another frame*: a new draw of a seed, in a pill with the dice.
private struct DicePill: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                EdgeToolGlyph(tool: .body, color: Theme.secondaryText).frame(width: 16, height: 16)
                Text(title).font(Theme.Font.ui(12.5)).foregroundStyle(Theme.secondaryText).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(Theme.card))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
    }
}

private struct StepButton: View {
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(symbol).font(Theme.Font.ui(16, .semibold)).foregroundStyle(Theme.text)
                .frame(width: 46, height: 28)
                .background(Capsule().fill(Theme.card))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(symbol == "+" ? L("One more") : L("One fewer"))
    }
}

/// The Edge step's four glyphs, as `gen_overscan.reference(2)` draws them about
/// a tool's centre.
struct EdgeToolGlyph: View {
    let tool: EdgeTool
    var color: Color = Theme.text

    var body: some View {
        Canvas { ctx, size in
            // Drawn about a 44 pt disc's centre, 22 pt across; a smaller frame scales them.
            let s = min(size.width, size.height) >= 40 ? 1 : min(size.width, size.height) / 22
            var c = ctx
            c.translateBy(x: size.width / 2, y: size.height / 2)
            c.scaleBy(x: s, y: s)
            switch tool {
            case .gate:
                var p = Path()
                p.move(to: CGPoint(x: -8, y: -3)); p.addLine(to: CGPoint(x: -8, y: -8)); p.addLine(to: CGPoint(x: -3, y: -8))
                p.move(to: CGPoint(x: 3, y: -8)); p.addLine(to: CGPoint(x: 8, y: -8)); p.addLine(to: CGPoint(x: 8, y: -3))
                p.move(to: CGPoint(x: 8, y: 3)); p.addLine(to: CGPoint(x: 8, y: 8)); p.addLine(to: CGPoint(x: 3, y: 8))
                p.move(to: CGPoint(x: -3, y: 8)); p.addLine(to: CGPoint(x: -8, y: 8)); p.addLine(to: CGPoint(x: -8, y: 3))
                c.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
            case .holes:
                var p = Path()
                for j in 0..<3 {
                    p.addRoundedRect(in: CGRect(x: -9 + CGFloat(j) * 7, y: -4, width: 4.5, height: 8),
                                     cornerSize: CGSize(width: 1.4, height: 1.4))
                }
                c.fill(p, with: .color(color))
            case .light:
                var p = Path(ellipseIn: CGRect(x: -4, y: -4, width: 8, height: 8))
                for j in 0..<8 {
                    let a = CGFloat(j) * .pi / 4
                    p.move(to: CGPoint(x: 6.5 * cos(a), y: 6.5 * sin(a)))
                    p.addLine(to: CGPoint(x: 9 * cos(a), y: 9 * sin(a)))
                }
                c.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            case .body:
                c.stroke(Path(roundedRect: CGRect(x: -7, y: -7, width: 14, height: 14), cornerRadius: 3),
                         with: .color(color), lineWidth: 1.4)
                var dots = Path()
                for (dx, dy) in [(-3.0, -3.0), (3.0, 3.0), (0.0, 0.0), (3.0, -3.0), (-3.0, 3.0)] {
                    dots.addEllipse(in: CGRect(x: dx - 1.1, y: dy - 1.1, width: 2.2, height: 2.2))
                }
                c.fill(dots, with: .color(color))
            case .print:
                // Not drawn: its disc wears Apple's `textformat` (`EdgeStepPanel`).
                break
            }
        }
        .accessibilityHidden(true)
    }
}

/// Chips set left to right, wrapped at the width they are given.
struct ChipFlow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        return CGSize(width: width.isFinite ? width : rows.map(\.width).max() ?? 0,
                      height: rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * lineSpacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var current: [Int] = [], x: CGFloat = 0, h: CGFloat = 0
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !current.isEmpty, x + size.width > width + 0.5 {
                rows.append((current, x - spacing, h))
                current = []; x = 0; h = 0
            }
            current.append(i)
            x += size.width + spacing
            h = max(h, size.height)
        }
        if !current.isEmpty { rows.append((current, x - spacing, h)) }
        return rows
    }
}

// MARK: - 4 · Date

/// What the Date step shows under its faces, one at a time.
enum DateControl: String, CaseIterable, Identifiable, Sendable {
    case corner, size, brightness
    var id: String { rawValue }
    var title: String {
        switch self {
        case .corner: L("Corner")
        case .size: L("Size")
        case .brightness: L("Brightness")
        }
    }
}

/// On or off, the three faces, the corner, the size. The faces are drawn with
/// the engine's own glyphs and this frame's own words, so a card shows what
/// its face prints.
///
/// Built here and not drawn by the design: the Size ruler (the drawn row
/// discloses it), and what the page says when a face or the whole date cannot
/// be printed on this camera, or waits for the switch (`FilmEdgeOptions`).
///
/// **2026-10-20, the owner:** "the date back should be able to have its print
/// brightness adjusted … ranging from the current 1x to 3x. Also, data and two
/// date back dates should be able to be printed together." So Data is a card
/// of its own beside the two date faces (`DateBackSettings.tap`: date only,
/// data only, or both), and the row under the rule, which disclosed Size in
/// place of Corner, is a switch of the three: Corner · Size · Brightness.
struct DateStepPanel: View {
    let frame: LibraryFrame
    @Binding var draft: FrameEdit
    @Binding var control: DateControl
    let width: CGFloat
    let editing: (Bool) -> Void
    let changed: () -> Void
    let pick: (DateBackFace) -> Void
    /// a wide window's column
    /// (`FilmEdgeColumn`): the faces, then Corner, Size and Brightness one after another — no switch of
    /// the three, and no title or switch of its own, which are the column's section header's.
    /// `control` is not read there.
    var flat = false

    private var back: DateBackSettings { draft.dateBack }
    private var edge: FilmEdgeSettings { draft.filmEdge }
    /// No back on this camera printed anything: the whole step stands down.
    private var printsNothing: Bool { FilmEdgeOptions.printsNothing(back, edge) }

    @ViewBuilder var body: some View {
        if flat { flatBody } else { steppedBody }
    }

    private var faceWidth: CGFloat { (width - 32 - 16) / 3 }

    private var flatBody: some View {
        VStack(spacing: 0) {
            DrawnBand(height: 74) {
                ForEach(Array(DateBackFace.allCases.enumerated()), id: \.element) { i, face in
                    faceCard(face, width: faceWidth).leading(16 + CGFloat(i) * (faceWidth + 8)).top(4)
                }
            }
            DrawnBand(height: 66) {
                cornerParts(top: 0)
            }
            Rectangle().fill(Theme.rule).frame(height: Theme.Metric.rule).padding(.horizontal, Theme.Metric.margin)
            DrawnBand(height: 66) { sizeRuler.top(6) }
            DrawnBand(height: 66) { brightnessRuler.top(2) }
        }
    }

    /// *Corner*, its pad and the note under it, `top` from the band's top (the step's at 126 − 22).
    @ViewBuilder private func cornerParts(top: CGFloat) -> some View {
        DrawnText(L("Corner"), 14, .semibold)
            .rowEnabled(FilmEdgeOptions.corner(back, edge))
            .leading(16).baseline(top + 22)
        CornerPad(corner: Binding(get: { back.corner }, set: { c in
            guard c != back.corner else { return }
            draft.dateBack.corner = c
            changed()
        }))
        .rowEnabled(FilmEdgeOptions.corner(back, edge))
        .accessibilityHint(back.active ? "" : L("Turn on Date Back first."))
        .trailingInset(16).top(top)
        DrawnText(note, 11.5, .medium, Theme.dim, fit: true).spanning(leading: 16, trailing: 110).baseline(top + 40)
    }

    private var sizeRuler: some View {
        RulerRow(label: L("Size"), valueText: sizeText,
                 value: Binding(get: { back.size }, set: { v in
                     guard v != back.size else { return }
                     draft.dateBack.size = v
                     changed()
                 }),
                 range: DateBackSettings.sizeRange, step: 0.1, majorEvery: 5, snap: 0.1, onEditingChanged: editing)
            .padding(.horizontal, Theme.Metric.margin)
            .rowEnabled(FilmEdgeOptions.size(back, edge))
            .accessibilityHint(back.active ? "" : L("Turn on Date Back first."))
    }

    private var brightnessRuler: some View {
        // 1× is the date's own 3.5 EV, as every edit before it; the data line shares the lamp.
        RulerRow(label: L("Brightness"), valueText: String(format: "%.1f×", back.brightness),
                 value: Binding(get: { back.brightness }, set: { v in
                     guard v != back.brightness else { return }
                     draft.dateBack.brightness = v
                     changed()
                 }),
                 range: FilmEdgeSettings.brightnessRange, step: 0.1, majorEvery: 5, snap: 0.1, home: 1,
                 onEditingChanged: editing)
            .padding(.horizontal, Theme.Metric.margin)
            .rowEnabled(FilmEdgeOptions.size(back, edge))
            .accessibilityHint(back.active ? "" : L("Turn on Date Back first."))
            .accessibilityIdentifier("date-back.brightness")
    }

    private var steppedBody: some View {
        let cwid = faceWidth
        return DrawnBand(height: 240) {
            DrawnText(L("Date Back"), 14, .semibold).leading(16).baseline(34)
            SpkToggle(isOn: Binding(get: { back.active && !printsNothing }, set: { on in
                guard on != back.active else { return }
                draft.dateBack.active = on
                // Switched on with a face this camera cannot print: take one it can.
                if on, !back.prints(back.style, filmEdge: edge),
                   let face = DateBackFace.allCases.first(where: { back.prints($0, filmEdge: edge) }) {
                    draft.dateBack.style = face
                }
                changed()
            }))
            .rowEnabled(!printsNothing)
            .trailingInset(16).top(18.5)

            ForEach(Array(DateBackFace.allCases.enumerated()), id: \.element) { i, face in
                faceCard(face, width: cwid).leading(16 + CGFloat(i) * (cwid + 8)).top(58)
            }

            switch control {
            case .size:
                sizeRuler.baseline(138)   // the ruler ends 2.5 pt over the rule (148 laid it across)
            case .brightness:
                brightnessRuler.baseline(138)
            case .corner:
                cornerParts(top: 126)
            }
            Rectangle().fill(Theme.rule).frame(height: Theme.Metric.rule)
                .padding(.horizontal, Theme.Metric.margin).top(183.5)
            // Under the rule, the three controls the faces have: one shown above at a time.
            SegmentedSwitch(options: DateControl.allCases, selection: $control, title: \.title, height: 30,
                            track: Theme.card)
                .frame(width: width - 2 * Theme.Metric.margin)
                .rowEnabled(!printsNothing)
                .accessibilityIdentifier("date-back.control")
                .leading(Theme.Metric.margin).top(197)
        }
    }

    private var sizeText: String { String(format: "%.1f×", back.size) }

    /// The line under *Corner*: why a face is dim when one is, else what the
    /// corner means.
    private var note: String {
        if printsNothing { return back.reason(.lcd, filmEdge: edge) ?? "" }
        // Off: the faces, the corner and the size wait for the switch.
        if !back.active { return L("Turn on Date Back to choose a face and a corner.") }
        if let face = DateBackFace.allCases.first(where: { back.reason($0, filmEdge: edge) != nil }),
           let reason = back.reason(face, filmEdge: edge) { return reason }
        if back.style == .data { return L("Data prints beside the frame, not in it.") }
        return L("The camera’s corner. Turned, it turns too.")
    }

    private func faceCard(_ face: DateBackFace, width cwid: CGFloat) -> some View {
        let can = back.prints(face, filmEdge: edge)
        let on = back.shows(face) && back.active && can
        let open = FilmEdgeOptions.face(face, back, edge)
        let ink = on ? Color(hex: 0xFFAB4A) : Theme.dim
        var sample = back
        sample.style = face
        let text = FilmEdgeResolver.dateText(sample, frame: frame)
        return Button { pick(face) } label: {
            DrawnBand(width: cwid, height: 62) {
                RoundedRectangle(cornerRadius: 10).fill(Theme.plot)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(on ? Theme.selectionFrame : Theme.rule, lineWidth: on ? 1.6 : 1))
                    .frame(width: cwid, height: 62).top(0)
                DateFaceGlyphs(face: face, text: text.isEmpty ? (face == .data ? "1/125 F8" : "'26 10 1") : text, ink: ink)
                    .frame(width: cwid - 16, height: 20).leading(8).top(face == .data ? 14 : 13)
                DrawnText(face.label, 12, .semibold, on ? Theme.text : Theme.secondaryText).centreX(cwid / 2).baseline(52)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        // Greyed when this camera never printed the face, and while the date is off.
        .rowEnabled(open)
        .disabled(!open)
        .accessibilityLabel(face.label + (can ? "" : ", " + (back.reason(face, filmEdge: edge) ?? "")))
        .accessibilityHint(can && !back.active ? L("Turn on Date Back first.") : "")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A face's own glyphs — the engine's seven segments, its dots, its squares —
/// centred, at the drawing's heights (14, 11.5 and 8), smaller when the words
/// are long.
struct DateFaceGlyphs: View {
    let face: DateBackFace
    let text: String
    let ink: Color

    var body: some View {
        Canvas { ctx, size in
            var h: Double = face == .lcd ? 14 : (face == .dots ? 11.5 : 8)
            func measure(_ h: Double) -> Double {
                face == .lcd ? SevenSegmentFace.width(text, h: h) + h * tan(8 * .pi / 180)
                             : Face5x7.dots(text, h: h) { _, _, _ in }
            }
            let w = measure(h)
            if w > size.width { h *= size.width / w }
            let x0 = (size.width - measure(h)) / 2
            // the baseline, as drawn: 17 under the card's top for the dates, 14 for data
            let base = Double(size.height) - (face == .data ? 6 : 3)
            var p = Path()
            if face == .lcd {
                for poly in SevenSegmentFace.polys(text, h: h, skew: tan(8 * .pi / 180)) {
                    p.addLines(poly.map { CGPoint(x: x0 + $0.x, y: base - $0.y) })
                    p.closeSubpath()
                }
            } else {
                Face5x7.dots(text, h: h) { x, y, pitch in
                    if face == .dots {
                        let r = 0.36 * pitch
                        p.addEllipse(in: CGRect(x: x0 + x - r, y: base - y - r, width: 2 * r, height: 2 * r))
                    } else {
                        let hp = 0.5 * pitch * 1.02
                        p.addRect(CGRect(x: x0 + x - hp, y: base - y - hp, width: 2 * hp, height: 2 * hp))
                    }
                }
            }
            ctx.fill(p, with: .color(ink))
        }
        .accessibilityHidden(true)
    }
}

/// The corner pad: the camera's four corners, held level.
struct CornerPad: View {
    @Binding var corner: DateBackCorner

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7).fill(Theme.plot)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.rule, lineWidth: 1))
            ForEach([DateBackCorner.tl, .tr, .bl, .br]) { c in
                let on = c == corner
                Circle()
                    .fill(on ? Theme.selection : Color.clear)
                    .overlay(Circle().stroke(on ? Theme.selection : Theme.dim, lineWidth: 1.2))
                    .frame(width: on ? 10 : 8, height: on ? 10 : 8)
                    .frame(width: 42, height: 22)
                    .contentShape(Rectangle())
                    .onTapGesture { corner = c }
                    .accessibilityLabel(c.says)
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                    .offset(x: c.isRight ? 42 + 9 : -9, y: c.isBottom ? 22 : 0)
            }
        }
        .frame(width: 84, height: 44)
    }
}
