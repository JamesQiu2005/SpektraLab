//  CurvePanel.swift — Adjust's 曲线.
//
//  Litti's flow (the owner, 2026-10-19): touch the curve and a point is there,
//  on the curve where the finger is, and the same touch drags it; a touch on a
//  point takes that point; 🗑 deletes every point (all of the curve, every
//  channel). Under the plot the channels are rings — RGB, Luma, R, G, B — and
//  the bar's menu turns the plot from points to Lightroom's parametric curve,
//  whose four regions are sliders. A point dragged well out of the plot is
//  taken off (`Curve.drag`); while a finger holds one, its input and output
//  are written in the plot's corner. The histogram behind is the picture's as
//  shown (`session.layer2.wantsHistogram`, only while the curve is open).
//
//  **The same tool is Decode's curve** (`CurveTarget.decode`, 2026-10-24): the
//  points, the channels and the gestures are these, and what they edit is the
//  scene before the film (`FilmParams.sceneCurve`) — so a finger is a shoot-layer
//  edit, developed when it rests or lifts, as a ruler's is. Its axis is stops
//  about the metered mid-grey on the film; behind it is the scene **after** the
//  curve, drawn as the Latitude card draws a placed scene, against the window
//  the film and paper hold (RFC-051, `drawPlaced`).
//
//  "I want it
//  to behave more like Capture One in terms of the curve behavior". The tool is drawn as Capture
//  One draws its curve
//  (`wideBody`): the channels are words over the plot (RGB · 亮度 · 红色 · 绿色 · 蓝色, the chosen
//  one in the accent with its underline, a dot on a moved one); behind Edit's plot RGB shows the three
//  channels as lines over the luminance, 亮度 the luminance, a colour its own; Decode's is one shape
//  on every tab, with the film/paper window, never on Edit; square points, the chosen one filled and the rest outlined, which
//  ⌫ deletes; both ends move in x too (`Curve.move`); a crosshair through the point only while it is
//  dragged; a 1 pt curve, the other channels' moved curves faint, the diagonal only when moved; the
//  input and output of the chosen point in a row under the plot; and a plot near square, at most
//  300 pt tall.

import SwiftUI

/// The curve's two views, under its bar's menu.
enum CurveMode: String, CaseIterable, Identifiable, Sendable {
    case points, parametric
    var id: String { rawValue }
    var title: String { self == .points ? L("Point") : L("Parametric") }
}

extension CurveChannel {
    /// Its ring and its line.
    var swatch: Color {
        switch self {
        case .rgb: Theme.selection
        case .luma: Theme.dim
        case .red: Color(hex: 0xD9584B)
        case .green: Color(hex: 0x5DBB6A)
        case .blue: Color(hex: 0x4A73D8)
        }
    }
}

extension CurveChannel {
    /// Its tab's word over a wide window's plot, Capture One's: RGB · 亮度 · 红色 · 绿色 · 蓝色. Words of
    /// their own (`as: "curve tab"`), so the host's rings and tabs keep 明度 and R, G, B.
    var wideTab: String {
        switch self {
        case .rgb: "RGB"
        case .luma: L("Luma", as: "curve tab")
        case .red: L("Red", as: "curve tab")
        case .green: L("Green", as: "curve tab")
        case .blue: L("Blue", as: "curve tab")
        }
    }
}

/// What a curve tool edits.
enum CurveTarget: Sendable {
    /// Edit's Curve: Layer 2, on the picture as printed (`Adjustments.curves`).
    case adjust
    /// Develop's Decode curve: the scene before the film (`FilmParams.sceneCurve`).
    case decode
}

struct CurveTool: View {
    let session: OpenFrameSession
    let height: CGFloat
    @Binding var channel: CurveChannel
    var mode: CurveMode = .points
    var target: CurveTarget = .adjust
    @State private var grabbed: Int?
    @State private var dragging = false
    @State private var grabOffset = CGPoint.zero
    /// Decode's: a shoot-layer gesture is open (`OpenFrameSession.began`), to be ended once.
    @State private var holding = false
    /// The point under the pointer (a mouse or a trackpad; a finger has no hover): the one a
    /// secondary click's menu deletes (the owner, 2026-10-24: points "right click and delete-able").
    @State private var hovered: Int?
    @Environment(\.accessibilityReduceMotion) private var calm
    /// A wide window's chosen point (RFC-035 §3.4): filled, shown in the readout, deleted by ⌫. Kept
    /// after the drag ends; a press on empty plot or another tab lets it go. Not `grabbed`, which is
    /// the point under a drag.
    @State private var selected: Int?
    /// A wide window's press is open: what it took, if anything, is in `grabbed`.
    @State private var pressed = false

    /// The HDR line on Edit's wide plot (header): where SDR white falls for this frame's Enable HDR at the canvas's
    /// weight, and the share of the picture past it. Nil on Decode's, with Enable HDR off, or nothing reaching white.
    private var hdrLine: (x: Double, share: Double?)? {
        guard target == .adjust, let look = HDRLook.of(session.edit, session.hdr),
              let x = look.sdrWhiteCrossing(weight: HDRZoneFeed.weight(look)) else { return nil }
        return (x, session.hdrZone.zone?.share)
    }

    /// The curves this tool edits, as they stand.
    private var curves: CurveSet {
        target == .adjust ? session.adjustments.curves : session.edit.params.sceneCurve
    }

    /// An edit of them: Layer 2's at once, never a develop; Decode's a change of the develop.
    private func changeCurves(_ mutate: (inout CurveSet) -> Void) {
        switch target {
        case .adjust: session.changeEdit { mutate(&$0.curves) }
        case .decode: session.change { mutate(&$0.params.sceneCurve) }
        }
    }

    private func beginEditing() {
        switch target {
        case .adjust: session.beganEdit()
        case .decode:
            guard !holding else { return }
            holding = true
            session.began(.shoot)
        }
    }

    private func endEditing() {
        switch target {
        case .adjust: session.endedEdit()
        case .decode:
            guard holding else { return }
            holding = false
            session.ended()
        }
    }

    var body: some View {
        Group {
            if target == .adjust { wideBody.modifier(HDRZoneFeed(session: session)) } else { wideBody }
        }
        .onChange(of: channel) { _, _ in letGo() }
        .onChange(of: mode) { _, _ in letGo() }
        .onAppear { if target == .adjust { session.layer2.holdHistogram("curve") } }
        .onDisappear {
            if target == .adjust { session.layer2.releaseHistogram("curve") }
            endEditing()
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: MacDriver.curveStep)) { note in
            if let step = note.object as? String { drive(step) }
        }
        #endif
    }

    /// A change of channel or view: nothing is held or chosen any more.
    private func letGo() {
        grabbed = nil; dragging = false; pressed = false; selected = nil
        endEditing()
    }

    /// The parametric view's four amounts and three splits.
    private var parametricSliders: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(ParametricCurve.Region.allCases) { region in
                    EditSlider(title: region.title, value: Binding(get: { curves.parametric[channel][region] },
                        set: { v in changeCurves { $0.parametric[channel][region] = v } }),
                        range: ParametricCurve.amountRange, detentAtRest: true, editing: editing)
                }
                ForEach(ParametricCurve.Split.allCases, id: \.self) { split in
                    EditSlider(title: L("Split") + " · " + [L("Shadows"), L("Midtones"), L("Highlights")][split.rawValue],
                        value: Binding(get: { curves.parametric[channel][split] * 100 },
                                       set: { v in changeCurves { $0.parametric[channel].setSplit(split, to: v / 100) } }),
                        range: 0...100, rest: Double(split.rawValue + 1) * 25, detentAtRest: true, editing: editing)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func editing(_ active: Bool) { active ? beginEditing() : endEditing() }

    /// A place on the plot's axis as the person reads it: Edit's in code values (0…255),
    /// Decode's in stops about mid-grey on the film ("−2.3 EV"; RFC-035 §5.3).
    private func reading(_ unit: CGFloat) -> String {
        guard target == .decode else { return String(format: "%.0f", unit * 255) }
        let ev = (Double(unit) * 2 - 1) * FilmParams.sceneCurveStops
        return LatitudeReadout.stopText(ev) + " EV"
    }

    static let inset: CGFloat = 8
    private func inner(_ size: CGSize) -> CGSize { CGSize(width: size.width - 2 * Self.inset, height: size.height - 2 * Self.inset) }
    private func unit(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        let s = inner(size)
        return CGPoint(x: (p.x - Self.inset) / max(s.width, 1), y: 1 - (p.y - Self.inset) / max(s.height, 1))
    }
}

// MARK: a wide window's curve: Capture One's (RFC-035 §3)

extension CurveTool {
    /// The tabs' row, the plot's most and the readout's row (RFC-035 §3.9): a plot about square, at most
    /// 300 pt tall, so a 393 pt column draws it 361 × 300 rather than 361 × 176.
    static let tabsHeight: CGFloat = 36
    static let widePlotSide: CGFloat = 300
    static let readoutHeight: CGFloat = 28
    /// The tool's whole height in a wide window, the plot at its most: Decode's part is this tall.
    static var wideHeight: CGFloat { tabsHeight + widePlotSide + 2 * inset + readoutHeight }
    /// A point's square, Capture One's (RFC-035 §3.4).
    static let pointSide: CGFloat = 9

    /// The plot's height in `height`: as square as the room lets it be, never over 300 pt inside.
    private var widePlotHeight: CGFloat {
        max(80, min(Self.widePlotSide + 2 * Self.inset, height - Self.tabsHeight - Self.readoutHeight))
    }

    var wideBody: some View {
        VStack(spacing: 0) {
            CurveTabs(selection: $channel, moved: { !curves.isIdentity($0) })
                .frame(height: Self.tabsHeight)
                .accessibilityIdentifier(target == .adjust ? "adjust.curve.channels" : "decode.curve.channels")
            if mode == .points {
                widePlot.frame(height: widePlotHeight)
                readout.frame(height: Self.readoutHeight)
            } else {
                widePlot.frame(height: max(64, (height - Self.tabsHeight) * 0.3)).allowsHitTesting(false).padding(.top, 8)
                parametricSliders
            }
        }
        .frame(height: mode == .points ? Self.tabsHeight + widePlotHeight + Self.readoutHeight : nil, alignment: .top)
        // ⌫ (and ⌦) deletes the chosen point, unless it is an end (RFC-035 §3.4); right-click Delete Point stays.
        .background {
            if mode == .points, let i = selected, curves[channel].isDeletable(i) {
                HiddenKeyEquivalent(title: L("Delete Point"), key: .delete) { deleteSelected() }
                HiddenKeyEquivalent(title: L("Delete Point"), key: .deleteForward) { deleteSelected() }
            }
        }
    }

    private func deleteSelected() {
        guard let i = selected, curves[channel].isDeletable(i) else { return }
        beginEditing()
        changeCurves { $0[channel].remove(i) }
        endEditing()
        selected = nil; hovered = nil
    }

    /// The chosen point, while the curve still has it (an Undo may have taken it).
    private var chosenPoint: CGPoint? {
        let pts = curves[channel].points
        guard let i = grabbed ?? selected, pts.indices.contains(i) else { return nil }
        return pts[i]
    }

    /// "输入： 146   输出： 136" under the plot, "--" with nothing chosen (RFC-035 §3.8): Edit's in code
    /// values, Decode's in stops. It keeps the last chosen point's values after the drag.
    private var readout: some View {
        let p = chosenPoint
        return HStack(spacing: 18) {
            readoutPair(L("Input:"), p.map { reading($0.x) } ?? "--")
            readoutPair(L("Output:"), p.map { reading($0.y) } ?? "--")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.inset)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(target == .adjust ? "adjust.curve.readout" : "decode.curve.readout")
    }

    private func readoutPair(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(Theme.secondaryText)
            Text(value).monospacedDigit().foregroundStyle(Theme.text)
        }
        .font(Theme.Font.ui(12, .medium))
        .lineLimit(1)
    }

    private var widePlot: some View {
        GeometryReader { geo in
            let curve: Curve = curves[channel]
            let value: String = curve.points.map { reading($0.x) + "→" + reading($0.y) }.joined(separator: ", ")
            let hdr = hdrLine
            Canvas { context, full in
                drawWidePlot(&context, full: full, curve: curve, hdr: hdr)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard mode == .points, case .active(let at) = phase else { hovered = nil; return }
                hovered = curve.fingerIndex(near: unit(at, geo.size), in: inner(geo.size), radius: 10)
            }
            .contextMenu {
                if mode == .points, let i = hovered, curve.isDeletable(i) {
                    Button(role: .destructive) {
                        beginEditing()
                        changeCurves { $0[channel].remove(i) }
                        endEditing()
                        if let s = selected { selected = s == i ? nil : (s > i ? s - 1 : s) }
                        hovered = nil
                    } label: { Label(L("Delete Point"), systemImage: "trash") }
                }
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard mode == .points else { return }
                var curve = curves[channel]
                if !pressed {
                    pressed = true
                    // A point, the curve, or nothing: a press on empty plot lets the chosen point go.
                    guard let taken = curve.press(at: unit(v.startLocation, geo.size), in: inner(geo.size)) else {
                        selected = nil; grabbed = nil
                        return
                    }
                    dragging = true; beginEditing()
                    grabbed = taken.index; selected = taken.index; grabOffset = taken.offset
                }
                guard let i = grabbed else { return }
                let moved = unit(v.location, geo.size)
                grabbed = curve.drag(i, to: CGPoint(x: moved.x + grabOffset.x, y: moved.y + grabOffset.y))
                selected = grabbed
                if curve != curves[channel] { changeCurves { $0[channel] = curve } }
            }.onEnded { _ in
                pressed = false; dragging = false; grabbed = nil
                endEditing()
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Curve") + " " + channel.wideTab)
            .accessibilityValue(value)
            .accessibilityAction(named: L("Add point")) {
                changeCurves { c in
                    let pts = c[channel].points
                    guard let gap = zip(pts, pts.dropFirst()).max(by: { $0.1.x - $0.0.x < $1.1.x - $1.0.x }) else { return }
                    let x = (gap.0.x + gap.1.x) / 2
                    c[channel].insert(CGPoint(x: x, y: c[channel].evaluate(x)))
                }
            }
            .accessibilityAction(named: L("Reset Channel")) { changeCurves { $0.reset(channel) } }
            .accessibilityIdentifier(target == .adjust ? "adjust.curve.plot" : "decode.curve.plot")
        }
    }

    /// Everything `widePlot` draws, in one function: the plot's ground (Edit's picture histogram, or
    /// Decode's scene after the curve against the film/paper window), the grid, the curves and the
    /// points. Held out of the
    /// `Canvas` closure because the whole of it inline is more than the type checker will take.
    private func drawWidePlot(_ context: inout GraphicsContext, full: CGSize, curve: Curve,
                              hdr: (x: Double, share: Double?)?) {
        // Drawn over the whole view, the plot inset by `inset`: a Canvas clips at its bounds, so
        // the ends' squares need the margin inside it to be drawn whole.
        context.translateBy(x: Self.inset, y: Self.inset)
        let size = CGSize(width: full.width - 2 * Self.inset, height: full.height - 2 * Self.inset)
        let whole = CGRect(origin: .zero, size: size)
        context.fill(Path(whole), with: .color(Theme.plot))
        if target == .decode { drawPlaced(in: &context, size: size) } else { drawPictureRows(in: &context, size: size) }
        if let hdr { Self.drawHDRLine(hdr.x, share: hdr.share, in: &context, size: size) }
        var grid = Path()
        for n in 0...4 {
            let f = CGFloat(n) / 4
            grid.move(to: CGPoint(x: f * size.width, y: 0)); grid.addLine(to: CGPoint(x: f * size.width, y: size.height))
            grid.move(to: CGPoint(x: 0, y: f * size.height)); grid.addLine(to: CGPoint(x: size.width, y: f * size.height))
        }
        context.stroke(grid, with: .color(Theme.rule), lineWidth: 0.5)
        // The film/paper window's two edges and their stops: Decode's only, never Edit's (RFC-035 §3.3).
        if target == .decode { drawWindowEdges(in: &context, size: size) }
        if !curves.isIdentity(channel) {
            var diagonal = Path()
            diagonal.move(to: CGPoint(x: 0, y: size.height)); diagonal.addLine(to: CGPoint(x: size.width, y: 0))
            context.stroke(diagonal, with: .color(Theme.rule), lineWidth: 0.5)
        }
        // The other channels' moved curves, faint, so a move on red still shows from RGB (C1's).
        for other in CurveChannel.allCases where other != channel && !curves.isIdentity(other) {
            context.stroke(curvePath(other, size), with: .color(other.lineColour.opacity(0.35)), lineWidth: 0.75)
        }
        context.stroke(curvePath(channel, size), with: .color(channel.lineColour.opacity(channel.isColour ? 1 : 0.85)), lineWidth: 1)
        if mode == .points {
            // The crosshair through the point while it is dragged, and only then (RFC-035 §3.6).
            if dragging, let i = grabbed, curve.points.indices.contains(i) {
                let c = place(curve.points[i], size)
                var cross = Path()
                cross.move(to: CGPoint(x: 0, y: c.y)); cross.addLine(to: CGPoint(x: size.width, y: c.y))
                cross.move(to: CGPoint(x: c.x, y: 0)); cross.addLine(to: CGPoint(x: c.x, y: size.height))
                context.stroke(cross, with: .color(Theme.accent.opacity(0.6)), lineWidth: 1)
            }
            for (i, p) in curve.points.enumerated() {
                let c = place(p, size)
                let half = Self.pointSide / 2
                let square = CGRect(x: c.x - half, y: c.y - half, width: Self.pointSide, height: Self.pointSide)
                if i == selected || i == grabbed {
                    context.fill(Path(square), with: .color(Theme.accent))
                } else {
                    let line: CGFloat = hovered == i && !dragging ? 2 : 1.25
                    context.stroke(Path(square.insetBy(dx: line / 2, dy: line / 2)), with: .color(Theme.accent), lineWidth: line)
                }
            }
        }
    }

    /// A point of the unit square on the plot, on whole points so a square's edges are sharp.
    private func place(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: (p.x * size.width).rounded(), y: ((1 - p.y) * size.height).rounded())
    }

    private func curvePath(_ ch: CurveChannel, _ size: CGSize) -> Path {
        var line = Path()
        for n in 0...256 {
            let x = CGFloat(n) / 256
            let p = CGPoint(x: x * size.width, y: (1 - curves.evaluate(ch, x)) * size.height)
            if n == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        return line
    }

    /// The HDR line: a rule where SDR white falls, the part past it a shade lighter, and "HDR" with
    /// its share at the top, on the side with room. What lies right of the line is what the histogram panel draws
    /// past white.
    static func drawHDRLine(_ x: Double, share: Double?, in context: inout GraphicsContext, size: CGSize) {
        let at = (x * size.width).rounded() + 0.5
        context.fill(Path(CGRect(x: at, y: 0, width: max(0, size.width - at), height: size.height)), with: .color(Theme.text.opacity(0.05)))
        var rule = Path()
        rule.move(to: CGPoint(x: at, y: 0)); rule.addLine(to: CGPoint(x: at, y: size.height))
        context.stroke(rule, with: .color(Theme.text.opacity(0.7)), lineWidth: 1)
        let label = context.resolve(Text(hdrWords(share)).font(Theme.Font.ui(10, .medium)).monospacedDigit().foregroundStyle(Theme.secondaryText))
        let room = size.width - at
        let fits = room >= label.measure(in: size).width + 8
        context.draw(label, at: CGPoint(x: fits ? at + 4 : at - 4, y: 4), anchor: fits ? .topLeading : .topTrailing)
    }

    /// "HDR 12%", "HDR 0.4%", "HDR <0.1%"; "HDR" alone until the share is counted.
    static func hdrWords(_ share: Double?) -> String {
        var words = L("HDR")
        if let share { words += " " + (share > 0 && share < 0.001 ? "<0.1%" : String(format: share < 0.1 ? "%.1f%%" : "%.0f%%", share * 100)) }
        return words
    }

    /// Edit's ground (RFC-035 §3.2): the picture as shown (`Layer2Histogram`), drawn as the histogram
    /// panel's Capture One style draws it — RGB the three channels as lines over the luminance's grey,
    /// 亮度 the luminance alone, a colour its own fill and line.
    private func drawPictureRows(in context: inout GraphicsContext, size: CGSize) {
        guard let h = session.layer2.histogram else { return }
        let shown = HistogramDisplay(h)
        switch channel {
        case .rgb:
            context.fill(HistogramPanel.shape(shown[.luma], size, closed: true), with: .color(Theme.dim.opacity(0.4)))
            for (row, ch) in [(Layer2Histogram.Channel.red, CurveChannel.red), (.green, .green), (.blue, .blue)] {
                context.stroke(HistogramPanel.shape(shown[row], size, closed: false), with: .color(ch.swatch.opacity(0.8)),
                               style: StrokeStyle(lineWidth: 1, lineJoin: .round))
            }
        case .luma:
            context.fill(HistogramPanel.shape(shown[.luma], size, closed: true), with: .color(Theme.dim.opacity(0.4)))
        case .red, .green, .blue:
            let row: Layer2Histogram.Channel = channel == .red ? .red : (channel == .green ? .green : .blue)
            context.fill(HistogramPanel.shape(shown[row], size, closed: true), with: .color(channel.swatch.opacity(0.22)))
            context.stroke(HistogramPanel.shape(shown[row], size, closed: false), with: .color(channel.swatch.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 1, lineJoin: .round))
        }
    }

    /// The window on the film's own axis (the reading's stop + Film Exposure): the medium's, measured
    /// with no exposure and no curve (RFC-035 §5.3), so it never moves while a point is dragged.
    private var filmWindow: (shadow: Double, highlight: Double)? {
        guard let r = session.latitude.readout else { return nil }
        return (r.shadowEV + r.exposureEV, r.highlightEV + r.exposureEV)
    }

    /// A film stop across the plot: ±`sceneCurveStops`, the curve's own axis.
    private func axisX(_ ev: Double, _ size: CGSize) -> CGFloat {
        CGFloat((ev + FilmParams.sceneCurveStops) / (2 * FilmParams.sceneCurveStops)) * size.width
    }

    /// Decode's ground (RFC-051, as the owner settled it 2026-11-09): **the scene after the curve, drawn
    /// as the Latitude card draws a placed scene** — one grey shape on the film's stop axis, light inside
    /// the window the film and paper hold, dim beyond it — so the curve is read as Scene Placement was:
    /// bend it, and watch the scene come into the window.
    ///
    /// Nothing of the scene before the curve is drawn. The owner: "the original apple decode histogram
    /// is abandoned completely, as on desktop people can look at the top histogram directly". The first
    /// build of RFC-051 drew the input's hills with R, G, B lines, a veil, horizontal window lines and an
    /// after-curve strip on the trailing edge; the owner, on the running app: "the worst kind of UX".
    ///
    /// RGB and 亮度 draw the scene's norm, as the card does, in the card's greys; 红 / 绿 / 蓝 draw that
    /// channel's own scene after the curve (`curved_fractions_r/g/b`), in its colour, light inside the
    /// window and faint beyond (the owner, 2026-11-09: "show Red, Green, and Blue's respective
    /// histograms when we're in Red, Green and Blue"). A reading without a channel's row draws nothing
    /// on that tab, never the norm in its place (trap 16). Where the engine has measured this
    /// very curve it is its reading (`curved_fractions`, through the render's own nodes); while a point
    /// moves, and until the develop where it rests has been measured, it is the input carried through
    /// this tab's curve (`DecodeTransfer.carried`), exact for a neutral pixel, and it settles to the
    /// engine's when that lands.
    private func drawPlaced(in context: inout GraphicsContext, size: CGSize) {
        guard let r = session.latitude.readout, let shares = r.shares, let w = filmWindow,
              let out = r.output(for: channel, curve: curves, exposureEV: session.edit.params.exposureCompensationEV,
                                 transfer: DecodeTransfer(curves, channel: channel)) else { return }
        let stops = FilmParams.sceneCurveStops
        let row = out.row
        let on = row.indices.filter { abs(shares.centre($0) + r.exposureEV) < stops }
        guard let lowest = on.first, let highest = on.last else { return }
        let tallest = on.map { max(row[$0], 0).squareRoot() }.max() ?? 0
        guard tallest > 0 else { return }
        // One bin past each end of the axis, so the fill runs to the plot's edges (the card's rule).
        let first = max(0, lowest - 1), last = min(row.count - 1, highest + 1)
        let top = size.height * 0.08, base = size.height
        func x(_ i: Int) -> CGFloat { axisX(shares.centre(i) + r.exposureEV, size) }
        var shape = Path()
        shape.move(to: CGPoint(x: x(first), y: base))
        for i in first...last {
            shape.addLine(to: CGPoint(x: x(i), y: base - CGFloat(min(1, max(row[i], 0).squareRoot() / tallest)) * (base - top)))
        }
        shape.addLine(to: CGPoint(x: x(last), y: base))
        shape.closeSubpath()
        var plot = context
        plot.clip(to: Path(CGRect(origin: .zero, size: size)))
        let (beyond, held): (Color, Color) = channel.isColour
            ? (channel.swatch.opacity(0.22), channel.swatch.opacity(0.6))
            : (Theme.latitudeBeyond, Theme.latitudeInside)
        plot.fill(shape, with: .color(beyond))
        let w0 = axisX(w.shadow, size), w1 = axisX(w.highlight, size)
        var inside = plot
        inside.clip(to: Path(CGRect(x: w0, y: 0, width: max(w1 - w0, 0), height: size.height)))
        inside.fill(shape, with: .color(held))
    }

    /// The window's two edges, as the Latitude card draws them: thin lines at the film and paper's two
    /// stops (on the film's axis), each named at its top — outside the window, or inside where there is
    /// no room outside (`LatitudeReadout.labelX`). Fixed: a point dragged moves the scene, not these.
    private func drawWindowEdges(in context: inout GraphicsContext, size: CGSize) {
        guard let w = filmWindow else { return }
        let stops = FilmParams.sceneCurveStops
        var edges = Path()
        for ev in [w.shadow, w.highlight] where abs(ev) < stops {
            edges.move(to: CGPoint(x: axisX(ev, size), y: 0)); edges.addLine(to: CGPoint(x: axisX(ev, size), y: size.height))
        }
        context.stroke(edges, with: .color(Theme.latitudeInsideEdge), lineWidth: 0.8)
        let font = Theme.Font.ui(10, .semibold)
        if abs(w.shadow) < stops {
            context.draw(Text(LatitudeReadout.stopText(w.shadow)).font(font).foregroundStyle(Theme.secondaryText),
                         at: CGPoint(x: LatitudeReadout.labelX(shadowEdge: axisX(w.shadow, size)), y: 8), anchor: .center)
        }
        if abs(w.highlight) < stops {
            context.draw(Text(LatitudeReadout.stopText(w.highlight)).font(font).foregroundStyle(Theme.secondaryText),
                         at: CGPoint(x: LatitudeReadout.labelX(highlightEdge: axisX(w.highlight, size), width: size.width), y: 8),
                         anchor: .center)
        }
    }

    #if DEBUG
    /// MacDriver's `curve.*` steps (a debug build's): a tab, a chosen point, a drag held, an end moved.
    private func drive(_ step: String) {
        let parts = step.split(separator: ".").map(String.init)
        switch parts.first {
        case "tab": if let c = parts.dropFirst().first.flatMap(CurveChannel.init(rawValue:)) { channel = c }
        case "select": selected = parts.dropFirst().first.flatMap { Int($0) }; dragging = false; grabbed = nil
        case "hold": if let i = parts.dropFirst().first.flatMap({ Int($0) }) { grabbed = i; selected = i; dragging = true }
        case "release": dragging = false; grabbed = nil
        case "end" where parts.count > 1 && parts[1] == "right":
            changeCurves { c in let y = c[channel].points[0].y; c[channel].move(0, to: CGPoint(x: 0.2, y: y)) }
            selected = 0
        default: print("drive curve: no step \(step)")
        }
    }
    #endif
}

extension CurveChannel {
    /// The curve's own line: the text colour on RGB and 亮度, the channel's swatch on a colour (C1's).
    var lineColour: Color {
        switch self {
        case .rgb, .luma: Theme.text
        default: swatch
        }
    }
    var isColour: Bool { self == .red || self == .green || self == .blue }
}

/// The channels as Capture One's words over the plot (RFC-035 §3.1): the chosen one in the accent with
/// a 2 pt accent underline, the rest in the second text colour, a dot after a moved one, a rule under
/// the row.
private struct CurveTabs: View {
    @Binding var selection: CurveChannel
    let moved: (CurveChannel) -> Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CurveChannel.allCases) { ch in
                let on = ch == selection
                Button { selection = ch } label: {
                    HStack(spacing: 3) {
                        Text(ch.wideTab)
                            .font(Theme.Font.ui(13, on ? .semibold : .medium))
                            .foregroundStyle(on ? Theme.accent : Theme.secondaryText)
                            .lineLimit(1)
                        if moved(ch) {
                            Circle().fill(on ? Theme.accent : Theme.dim).frame(width: 4, height: 4)
                        }
                    }
                    .padding(.horizontal, 2)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        if on { Rectangle().fill(Theme.accent).frame(height: 2) }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ch.title)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("curve.tab." + ch.rawValue)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 0.5) }
    }
}
