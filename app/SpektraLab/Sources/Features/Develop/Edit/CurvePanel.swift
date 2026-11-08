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
//  about the metered mid-grey; the histogram behind it is the scene's on that
//  axis (the Latitude card's), with the window the film and paper hold marked.
//
//  "I want it
//  to behave more like Capture One in terms of the curve behavior". The tool is drawn as Capture
//  One draws its curve
//  (`wideBody`): the channels are words over the plot (RGB · 亮度 · 红色 · 绿色 · 蓝色, the chosen
//  one in the accent with its underline, a dot on a moved one); behind the plot RGB shows the three
//  channels as lines over the luminance, 亮度 the luminance, a colour its own; the film/paper window
//  on Decode only, never on Edit; square points, the chosen one filled and the rest outlined, which
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
    /// Set only by a debug build's `MacDriver` (`curve.norows`): draws the plot as a reply without
    /// per-channel rows draws it, so the no-hills state can be seen and captured. Nothing in the app
    /// sets it; an old engine, or the demo before a measurement, reaches that state by itself.
    @State private var ignoreChannelRows = false

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
        wideBody
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

    /// Decode's ground: the scene's histogram on the curve's stop axis — the Latitude card's
    /// reading, measured before the curve, which is what the curve's input is — and the window
    /// the film and paper hold, dashed, so a point is put where the medium will keep it.
    private func drawScene(in context: inout GraphicsContext, size: CGSize) {
        guard let r = session.latitude.readout else { return }
        let stops = FilmParams.sceneCurveStops
        // The curve's axis is stops on the film since RFC-035 §5.3: the reading's stop + Film Exposure.
        // At 0 EV, the host's drawing is exactly as it was.
        func x(_ ev: Double) -> CGFloat { CGFloat((ev + r.exposureEV + stops) / (2 * stops)) * size.width }
        if r.bins.count > 1 {
            var p = Path(); p.move(to: CGPoint(x: x(r.binEV(0)), y: size.height))
            for i in r.bins.indices { p.addLine(to: CGPoint(x: x(r.binEV(i)), y: (1 - r.bins[i]) * size.height)) }
            p.addLine(to: CGPoint(x: x(r.binEV(r.bins.count - 1)), y: size.height)); p.closeSubpath()
            context.fill(p, with: .color(Theme.text.opacity(0.12)))
        }
        var window = Path()
        for ev in [r.shadowEV, r.highlightEV] where abs(ev + r.exposureEV) < stops {
            window.move(to: CGPoint(x: x(ev), y: 0)); window.addLine(to: CGPoint(x: x(ev), y: size.height))
        }
        context.stroke(window, with: .color(Theme.dim), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
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
            let hills: SceneHills = sceneHills
            let note: String? = noHillsNote
            let value: String = curve.points.map { reading($0.x) + "→" + reading($0.y) }.joined(separator: ", ")
                + (note.map { "; " + $0 } ?? "")
            Canvas { context, full in
                drawWidePlot(&context, full: full, curve: curve, hills: hills, note: note)
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

    /// Everything `widePlot` draws, in one function: the plot's ground (the hills, Decode's only), the
    /// grid, the film/paper window, the curves, the points and the no-hills note. Held out of the
    /// `Canvas` closure because the whole of it inline is more than the type checker will take.
    private func drawWidePlot(_ context: inout GraphicsContext, full: CGSize, curve: Curve,
                              hills: SceneHills, note: String?) {
        // Drawn over the whole view, the plot inset by `inset`: a Canvas clips at its bounds, so
        // the ends' squares need the margin inside it to be drawn whole.
        context.translateBy(x: Self.inset, y: Self.inset)
        let size = CGSize(width: full.width - 2 * Self.inset, height: full.height - 2 * Self.inset)
        let whole = CGRect(origin: .zero, size: size)
        context.fill(Path(whole), with: .color(Theme.plot))
        if target == .decode { drawSceneRows(hills, in: &context, size: size) } else { drawPictureRows(in: &context, size: size) }
        var grid = Path()
        for n in 0...4 {
            let f = CGFloat(n) / 4
            grid.move(to: CGPoint(x: f * size.width, y: 0)); grid.addLine(to: CGPoint(x: f * size.width, y: size.height))
            grid.move(to: CGPoint(x: 0, y: f * size.height)); grid.addLine(to: CGPoint(x: size.width, y: f * size.height))
        }
        context.stroke(grid, with: .color(Theme.rule), lineWidth: 0.5)
        // The film/paper window: Decode's only, never Edit's (RFC-035 §3.3).
        if target == .decode { drawWindow(in: &context, size: size) }
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
        // A tab with no hill of its own says so, in the plot's corner, over everything else: nothing is
        // drawn behind the curve and the reason is not left to be guessed (trap 16).
        if let note {
            context.draw(Text(note).font(Theme.Font.ui(10.5, .medium)).foregroundStyle(Theme.secondaryText),
                         at: CGPoint(x: 8, y: 8), anchor: .topLeading)
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

    /// Decode's ground (RFC-035 §3.2, §5.3): the scene's histogram on the curve's axis, which is stops
    /// **on the film** — the Latitude card's stop plus Film Exposure (`LatitudeReadout.exposureEV`, the
    /// owner's Q1: "the Decode curve's axis follows Film Exposure"), so +1 EV moves the histogram one
    /// stop right, as Capture One's moves with its Exposure.
    ///
    /// **What is drawn is `SceneHills`, and only that**: the model decides which rows the tab has
    /// (`LatitudeReadout.hills(for:)`), and a tab whose channel the reading does not carry gets `.none` —
    /// no hills, plus `noHillsNote` in the plot. The luminance is never drawn in a channel's place
    /// (trap 16); the old fallback was exactly that, and it looked identical to the real thing.
    ///
    /// The hills are the **input** — the scene before the curve (`scene_latitude_sample` runs neither
    /// `scene_latitude` nor `scene_curve`), as Capture One's are — so they do not move while a point is
    /// dragged. The film/paper window is drawn over them (`drawWindow`), also fixed.
    private func drawSceneRows(_ hills: SceneHills, in context: inout GraphicsContext, size: CGSize) {
        guard let r = session.latitude.readout else { return }
        let stops = FilmParams.sceneCurveStops
        // A film stop is the reading's stop + c (the engine reads `scene_curve` at E + c since RFC-035 §5.3).
        let shift = r.exposureEV
        func x(_ ev: Double) -> CGFloat { CGFloat((ev + shift + stops) / (2 * stops)) * size.width }
        func shape(_ bins: [Double], closed: Bool) -> Path {
            var p = Path()
            guard bins.count > 1 else { return p }
            func point(_ i: Int) -> CGPoint { CGPoint(x: x(r.binEV(i)), y: (1 - bins[i]) * size.height) }
            if closed { p.move(to: CGPoint(x: x(r.binEV(0)), y: size.height)); p.addLine(to: point(0)) } else { p.move(to: point(0)) }
            for i in 1..<bins.count { p.addLine(to: point(i)) }
            if closed { p.addLine(to: CGPoint(x: x(r.binEV(bins.count - 1)), y: size.height)); p.closeSubpath() }
            return p
        }
        // Faint, so the curve and the window read over it: the distribution is the ground, not the
        // subject (the owner, 2026-10-26: the hills "make the user guess").
        let grey = Theme.dim.opacity(0.22)
        let line = StrokeStyle(lineWidth: 1.25, lineJoin: .round)
        switch hills {
        case .none:
            return
        case .luma(let bins):
            context.fill(shape(bins, closed: true), with: .color(grey))
        case .rgb(let luma, let red, let green, let blue):
            context.fill(shape(luma, closed: true), with: .color(grey))
            for (bins, ch) in [(red, CurveChannel.red), (green, .green), (blue, .blue)] {
                context.stroke(shape(bins, closed: false), with: .color(ch.swatch.opacity(0.9)), style: line)
            }
        case .channel(let bins):
            context.fill(shape(bins, closed: true), with: .color(channel.swatch.opacity(0.22)))
            context.stroke(shape(bins, closed: false), with: .color(channel.swatch.opacity(0.9)), style: line)
        }
    }

    /// The reading's hills for the tab in front, with this build's capture override applied.
    private var sceneHills: SceneHills {
        guard let r = session.latitude.readout else { return .none }
        guard ignoreChannelRows else { return r.hills(for: channel) }
        var bare = r
        (bare.binsR, bare.binsG, bare.binsB) = (nil, nil, nil)
        return bare.hills(for: channel)
    }

    /// Where a colour tab has no hill of its own, the plot says so rather than showing the luminance in
    /// its place (trap 16). Nil on the luminance tab, which claims nothing about a channel.
    private var noHillsNote: String? {
        guard target == .decode, channel != .luma, case .none = sceneHills else { return nil }
        return L("No channel histogram for this picture")
    }

    /// The window the film and paper hold, solid 1 pt dim lines under the curve, each with its stop at
    /// its foot where the label fits inside the window (RFC-035 §3.3). Decode's only. On the film's own
    /// axis (the reading's stop + Film Exposure), and the engine measures the medium with no exposure
    /// and no curve (RFC-035 §5.3): the two lines are the pair's, and stay put while a point is dragged
    /// or Film Exposure moves — the histogram moves under them.
    private func drawWindow(in context: inout GraphicsContext, size: CGSize) {
        guard let raw = session.latitude.readout else { return }
        var r = raw
        r.shadowEV += raw.exposureEV; r.highlightEV += raw.exposureEV
        let stops = FilmParams.sceneCurveStops
        func x(_ ev: Double) -> CGFloat { CGFloat((ev + stops) / (2 * stops)) * size.width }
        var window = Path()
        for ev in [r.shadowEV, r.highlightEV] where abs(ev) < stops {
            window.move(to: CGPoint(x: x(ev), y: 0)); window.addLine(to: CGPoint(x: x(ev), y: size.height))
        }
        // The window is the medium's own, measured with the curve and the placement cleared, so it
        // never moves while a point is dragged (RFC-035 §5.3) — one more thing that is not a control.
        context.stroke(window, with: .color(Theme.dim), lineWidth: 1)
        guard abs(r.shadowEV) < stops, abs(r.highlightEV) < stops, x(r.highlightEV) - x(r.shadowEV) > 72 else { return }
        let font = Theme.Font.ui(10, .medium)
        context.draw(Text(LatitudeReadout.stopText(r.shadowEV)).font(font).foregroundStyle(Theme.secondaryText),
                     at: CGPoint(x: x(r.shadowEV) + 4, y: size.height - 4), anchor: .bottomLeading)
        context.draw(Text(LatitudeReadout.stopText(r.highlightEV)).font(font).foregroundStyle(Theme.secondaryText),
                     at: CGPoint(x: x(r.highlightEV) - 4, y: size.height - 4), anchor: .bottomTrailing)
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
        // The plot as a reply without per-channel rows draws it (trap 16's no-hills state).
        case "norows": ignoreChannelRows = true
        case "rows": ignoreChannelRows = false
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
