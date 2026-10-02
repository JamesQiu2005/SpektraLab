//  FilmEdgeSection.swift — RFC-032's film edge: the rebate, the holes and the
//  edge print around the picture, as that camera and that scan made them.
//
//  The 2026-10-01 drawings (`design-proposals/film-edge-2026-10-01/`) put it
//  in *Film and Print* directly under Film, because it belongs to the film and
//  depends on neither the paper nor the DI. **No wizard and no top-bar tool:**
//  the rows' order is the order of the decisions — format, view, then the
//  gate and the scan, then the light — and every control develops on release,
//  as everywhere on this rail.
//
//  **The framing is the crop, held at the gate's aspect** (`Session+FilmEdge`):
//  the crop tool frames the picture in the gate, so the Framing row enters it
//  and turns the gate between upright and across, and Straighten is the held
//  crop's. **Not drawn, on purpose:** the drawing's *Turn* row needs
//  `overscan_turn`, which is not in the engine, and its Scale slider has no
//  number to bind — dragging the crop in the gate is the scale. A row that
//  looks live and does nothing is worse than no row.

import SwiftUI

struct FilmEdgeSection: View {
    @Bindable var session: Session
    @State private var formatMenu = false

    static let key = "filmEdge"
    private var edge: FilmEdgeSettings { session.params.filmEdge }

    var body: some View {
        PanelSection(L(.sectionFilmEdge), key: Self.key, initiallyExpanded: false,
                     note: edge.active ? nil : L(.edgeOff),
                     foldedNote: summary,
                     toggle: Binding(get: { edge.active }, set: { setActive($0) }),
                     toggleHelp: L("Print the film around the picture: rebate, holes and edge print",
                                   zh: "在画面四周印出胶片：片基、齿孔与边码")) {
            RailRows {
                formatRow
                PillSwitchRow(label: L(.edgeView), options: FilmEdgeView.allCases,
                              selection: bind(\.view), title: { L($0.key) })
                framingRow
                // The held crop's straighten, scrubbed the way Crop's is: the
                // refit happens once, on release.
                ScrubSlider(label: L(.cropStraighten), sublabel: L(.cropStraightenUnit),
                            value: Binding(get: { session.geometry.angle },
                                           set: { session.scrubStraighten(to: $0) }),
                            range: -Geometry.maxAngle...Geometry.maxAngle, snap: 1,
                            format: { String(format: "%+.1f°", $0) },
                            onCommit: { session.straightenScrubEnded() })
                Text(sizeCaption)
                    .font(Theme.Font.caption).foregroundStyle(Theme.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                RailSubhead(L(.edgeGateAndScan))
                PillMenu(label: L(.edgeGate), options: FilmEdgeGate.allCases, title: { L($0.key) },
                         selection: bind(\.gate))
                PillSwitchRow(label: L(.edgeHoles), options: FilmEdgeHoles.allCases,
                              selection: bind(\.holes), title: { L($0.key) })
                bodyRow
                advanceRow

                RailSubhead(L(.edgeLight))
                ScrubSlider(label: L(.edgeFog), value: bind(\.fog), range: FilmEdgeSettings.fogRange,
                            zero: FilmEdgeSettings.default.fog, snap: 0.25,
                            format: { String(format: "%.1f", $0) })
                ScrubSlider(label: L(.edgeLeaks), value: bind(\.leaks), range: FilmEdgeSettings.leaksRange,
                            zero: 0, snap: 0.25, format: { String(format: "%.1f", $0) })
                VStack(alignment: .leading, spacing: 2) {
                    note(lensNote)
                    if !edge.edgeText.isEmpty { note(edgePrintNote) }
                }
            }
            // Off, the rows keep what they hold and say why they are grey: the
            // switch is in the header, which a greyed row cannot point at.
            .rowEnabled(edge.active, because: L("Switch Film Edge on in its header.",
                                                zh: "先在标题栏开启片边。"))
        }
    }

    // MARK: rows

    /// A pill that opens the formats as a list of films (`FilmEdgeFormatMenu`),
    /// and the gate's size at the row's end, as Crop's Aspect is drawn.
    private var formatRow: some View {
        HStack(spacing: 0) {
            Text(L(.edgeFormat)).font(Theme.Font.label).foregroundStyle(Theme.Ink.secondary)
                .fixedSize()
                .padding(.trailing, 6)
                .frame(minWidth: Theme.Metric.sliderLabelWidth, alignment: .leading)
            Button { formatMenu.toggle() } label: {
                HStack(spacing: 0) {
                    Text(edge.format.title).font(Theme.Font.label).foregroundStyle(Theme.text)
                        .lineLimit(1).fixedSize()
                        .padding(.leading, 10)
                    Spacer(minLength: 4)
                    Triangle()
                        .stroke(Theme.text, style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                        .frame(width: 8, height: 5)
                        .padding(.trailing, 9)
                }
                .frame(width: Theme.Metric.edgeFormatPillWidth, height: Theme.Metric.controlHeight)
                .background(Theme.pill, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $formatMenu, arrowEdge: .trailing) {
                FilmEdgeFormatMenu(selection: edge.format, view: edge.view,
                                   stockName: shortStockName,
                                   isMade: { session.filmStockIsMade(in: $0) }) { format in
                    formatMenu = false
                    set(\.format, format)
                }
            }
            Spacer(minLength: 6)
            Text(edge.format.gateLabel)
                .font(Theme.Font.caption).foregroundStyle(Theme.Ink.tertiary)
                .lineLimit(1).fixedSize()
        }
        .frame(height: Theme.Metric.rowHeight)
    }

    /// **Framing in the gate**: the crop tool, re-aimed — the picture moves
    /// under a gate fixed at the format's aspect, and Return develops it. The
    /// glyph turns the gate between upright and across without turning the
    /// picture.
    private var framingRow: some View {
        let upright = (session.geometry.lockedRatio ?? 1) < 1
        return HStack(spacing: 6) {
            RowLabel(L("Framing", zh: "取景"))
                .padding(.trailing, -6)
            Button { session.tool = session.tool == .crop ? .select : .crop } label: {
                HStack(spacing: 5) {
                    Image(systemName: "crop").font(.system(size: 10, weight: .regular))
                    Text(session.tool == .crop ? L("Framing", zh: "取景中")
                                               : L("In the gate", zh: "在片门中"))
                        .font(Theme.Font.label).lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                }
                .foregroundStyle(session.tool == .crop ? Theme.accent : Theme.Ink.secondary)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Theme.Metric.controlHeight)
                .background(Theme.pill, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(L("Move the picture under the gate with the crop tool. Return develops; Esc puts it back.",
                    zh: "用裁剪工具在片门下移动画面。回车显影，Esc 还原。"))
            Button { session.flipFilmEdgeGate() } label: {
                Image(systemName: upright ? "rectangle.portrait" : "rectangle")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.text)
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(upright ? L("The gate is upright — click for across", zh: "片门为竖向，点按改为横向")
                          : L("The gate is across — click for upright", zh: "片门为横向，点按改为竖向"))
        }
        .frame(height: Theme.Metric.rowHeight)
    }

    /// **The body**: which camera shot the roll. Its number is the seed, so the
    /// same number is the same gate, the same margins and the same holes.
    private var bodyRow: some View {
        HStack(spacing: 0) {
            RowLabel(L(.edgeBody))
            Text(L("No. \(edge.cameraSeed)", zh: "\(edge.cameraSeed) 号"))
                .font(Theme.Font.value).foregroundStyle(Theme.text)
                .lineLimit(1).fixedSize()
            Spacer(minLength: 6)
            DiceButton(title: L(.edgeAnother),
                       help: L("Another camera body: a new gate, new margins and new holes",
                               zh: "换一台机身：新的片门、边距与齿孔")) {
                set(\.cameraSeed, Self.another(than: edge.cameraSeed, in: Self.bodyNumbers))
            }
            .frame(width: Theme.Metric.edgeAnotherWidth)
        }
        .frame(height: Theme.Metric.rowHeight)
    }

    /// **The advance and the scan**: where this frame landed on the roll, and
    /// how the scanner held it. Per photo; it has no number worth showing.
    private var advanceRow: some View {
        HStack(spacing: 0) {
            RowLabel(L(.edgeAdvance))
            DiceButton(title: L(.edgeAnotherFrame),
                       help: L("Another frame of the same roll: a new advance and a new scan",
                               zh: "同一卷里的另一格：新的过片位置与扫描"), fill: true) {
                set(\.frameSeed, Self.another(than: edge.frameSeed, in: 1...Int(Int32.max)))
            }
        }
        .frame(height: Theme.Metric.rowHeight)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.caption).foregroundStyle(Theme.Ink.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: words

    /// What the header folds to: `135 · Strip`. The drawing's `90°` is the
    /// turn, which is not a control yet.
    private var summary: String? {
        guard edge.active else { return nil }
        return "\(edge.format.title) · \(L(edge.view.key))"
    }

    /// The picture's own pixels, and the film built around them. The border
    /// is outside the picture and takes none of its pixels (RFC-032 §10). The
    /// film's size is the session's estimate (`FilmCanvasEstimate`, which errs
    /// large) until the engine reports its layout, hence "about".
    private var sizeCaption: String {
        guard let px = session.edgePicturePixels else { return "—" }
        // No-break spaces: a size wraps as a whole, never as "8,692 / × 8,027".
        let picture = "\(Self.grouped(px.w))\u{00A0}×\u{00A0}\(Self.grouped(px.h))"
        let film = FilmCanvasEstimate.size(picture: CGSize(width: px.w, height: px.h),
                                           format: edge.format, view: edge.view)
        guard film.width > 0 else { return picture }
        let canvas = "\(Self.grouped(Int(film.width)))\u{00A0}×\u{00A0}\(Self.grouped(Int(film.height)))"
        let mp = String(format: "%.1f", film.width * film.height / 1_000_000)
        return L("\(picture) in a film of about \(canvas)\n\(mp) MP · the border takes no picture pixels",
                 zh: "\(picture)，胶片约 \(canvas)\n\(mp) MP · 片边不占用画面像素")
    }

    private var lensNote: String {
        if edge.fNumber > 0 {
            let f = String(format: "%g", edge.fNumber)
            return L("Lens f/\(f), from EXIF: the gate's softness.",
                     zh: "镜头 f/\(f)，来自 EXIF：决定片门边缘的柔和程度。")
        }
        return L("Lens f/5.6, assumed: EXIF has no aperture. It sets the gate's softness.",
                 zh: "镜头按 f/5.6 计：EXIF 中没有光圈。它决定片门边缘的柔和程度。")
    }

    private var edgePrintNote: String {
        L("Edge print \(edge.edgeText), from the stock.", zh: "边码 \(edge.edgeText)，来自所选胶片。")
    }

    private var shortStockName: String { Self.shortName(session.catalog.stock(session.params.filmStock)?.name
                                                        ?? session.params.filmStock) }

    // MARK: writes

    /// Switching on opens the section, since everything it asks for is under
    /// the header; switching off leaves it as it was.
    private func setActive(_ on: Bool) {
        set(\.active, on)
        if on { UserDefaults.standard.set(true, forKey: Session.uiKey + "section.\(Self.key)") }
    }

    private func bind<V>(_ kp: WritableKeyPath<FilmEdgeSettings, V>) -> Binding<V> {
        Binding(get: { session.params.filmEdge[keyPath: kp] }, set: { set(kp, $0) })
    }

    private func set<V>(_ kp: WritableKeyPath<FilmEdgeSettings, V>, _ value: V) {
        var p = session.params; p.filmEdge[keyPath: kp] = value; session.params = p
    }

    // MARK: helpers

    /// Body numbers stay short enough to read as a serial plate.
    static let bodyNumbers = 1...999

    static func another(than current: Int, in range: ClosedRange<Int>) -> Int {
        var next = Int.random(in: range)
        while next == current && range.count > 1 { next = Int.random(in: range) }
        return next
    }

    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// "Kodak Gold 200" → "Gold 200", as Latitude's header shortens it.
    static func shortName(_ name: String) -> String {
        for maker in ["Kodak Professional ", "Kodak ", "Fujifilm ", "Fuji "] where name.hasPrefix(maker) {
            return String(name.dropFirst(maker.count))
        }
        return name
    }
}

// MARK: - the format menu

/// The formats, each as its own film: grouped 135 / 120 / Panoramic, with
/// the gate's size, a drawing of the frame and the film's cost in pixels.
/// Formats the engine does not have yet, and formats this stock was never
/// made in, are listed and greyed with the reason, rather than left out.
struct FilmEdgeFormatMenu: View {
    let selection: FilmEdgeFormat
    let view: FilmEdgeView
    let stockName: String
    let isMade: (FilmEdgeFormat) -> Bool
    let pick: (FilmEdgeFormat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(FilmEdgeFormat.Group.allCases, id: \.self) { group in
                Text(group.title)
                    .font(Theme.Font.caption).foregroundStyle(Theme.Ink.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, group == FilmEdgeFormat.Group.allCases.first ? 10 : 8)
                    .padding(.bottom, 4)
                ForEach(FilmEdgeFormat.allCases.filter { $0.group == group }) { format in
                    row(format)
                }
            }
            Hairline().padding(.horizontal, 8).padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                if let made = madeNote {
                    Text(made)
                }
                Text(L("Right column: film pixels per picture pixel.", zh: "右栏：每个画面像素对应的胶片像素。"))
            }
            .font(Theme.Font.caption).foregroundStyle(Theme.Ink.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 10)
        }
        .frame(width: Theme.Metric.edgeFormatMenuWidth)
        .background(Theme.card)
    }

    private func row(_ format: FilmEdgeFormat) -> some View {
        let available = format.isAvailable && isMade(format)
        let on = format == selection
        return HStack(spacing: 8) {
            FormatGlyph(format: format)
                .frame(width: 40, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(format.title).font(Theme.Font.label).foregroundStyle(Theme.text)
                Text(format.menuSize).font(Theme.Font.meta).foregroundStyle(Theme.Ink.tertiary)
            }
            .fixedSize()
            Spacer(minLength: 0)
        }
        // The cost and the check are pinned to the row's end, so they make
        // one column down the menu whatever the name before them.
        .overlay(alignment: .trailing) {
            HStack(spacing: 6) {
                Text(format.filmCost(view).map { String(format: "×%.2f", $0) } ?? "")
                    .font(Theme.Font.value).foregroundStyle(Theme.Ink.tertiary)
                    .lineLimit(1).fixedSize()
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .opacity(on ? 1 : 0)
                    .frame(width: 10)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 32)
        .background {
            if on { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.text.opacity(0.1)) }
        }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { if available && !on { pick(format) } }
        .rowEnabled(available, because: reason(format))
    }

    private func reason(_ format: FilmEdgeFormat) -> String {
        if !format.isAvailable {
            return L("Not in the engine yet.", zh: "引擎尚未支持。")
        }
        return madeNote ?? ""
    }

    /// "Gold 200 was made in 135 and 120." Only while the stock rules some
    /// format out; otherwise there is nothing to explain.
    private var madeNote: String? {
        let groups = FilmEdgeFormat.Group.allCases.filter { g in
            FilmEdgeFormat.allCases.contains { $0.group == g && $0.isAvailable && isMade($0) }
        }
        let ruledOut = FilmEdgeFormat.allCases.contains { $0.isAvailable && !isMade($0) }
        guard ruledOut, !groups.isEmpty else { return nil }
        let names = groups.map(\.title)
        let list = names.count == 1 ? names[0]
            : names.dropLast().joined(separator: ", ") + L(" and ", zh: "和") + names[names.count - 1]
        return L("\(stockName) was made in \(list).", zh: "\(stockName) 只生产过 \(list)。")
    }
}

/// A frame of the format, to scale against its neighbours in the menu: the
/// gate in the film's rebate, and the holes where the film has them.
private struct FormatGlyph: View {
    let format: FilmEdgeFormat

    var body: some View {
        Canvas { ctx, size in
            let gate = format.gateMM
            // One scale for every row, set by the longest gate that has to
            // fit: 6×17's 168 mm would make 135 a speck, so the long side is
            // compressed — a glyph, not a measurement.
            let along = min(1, 0.35 + gate.long / 120)
            let filmH = size.height * (format.group == .film135 ? 0.62 : 0.86)
            let w = size.width * along
            let filmRect = CGRect(x: (size.width - w) / 2, y: (size.height - filmH) / 2, width: w, height: filmH)
            ctx.fill(Path(roundedRect: filmRect, cornerRadius: 1.5), with: .color(Theme.Ink.tertiary.opacity(0.35)))
            let inset = format.isPerforated ? filmH * 0.2 : filmH * 0.08
            let gateRect = filmRect.insetBy(dx: filmH * 0.06, dy: inset)
            ctx.fill(Path(roundedRect: gateRect, cornerRadius: 0.8), with: .color(Theme.Ink.secondary.opacity(0.85)))
            guard format.isPerforated else { return }
            let holes = max(3, Int(w / 4))
            for i in 0..<holes {
                let x = filmRect.minX + (CGFloat(i) + 0.5) * w / CGFloat(holes) - 0.8
                for y in [filmRect.minY + inset * 0.3, filmRect.maxY - inset * 0.7] {
                    ctx.fill(Path(CGRect(x: x, y: y, width: 1.6, height: inset * 0.4)), with: .color(Theme.Ink.secondary))
                }
            }
        }
    }
}

// MARK: - rows this section and Date Back share

/// A label in the rail's column, at the rows' ink.
struct RowLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Theme.Font.label).foregroundStyle(Theme.Ink.secondary)
            .fixedSize()
            .padding(.trailing, 6)
            .frame(minWidth: Theme.Metric.sliderLabelWidth, alignment: .leading)
    }
}

/// A small caption over a group of rows inside one section — *Gate and
/// scan*, *Light*: the second tier of the two-tier separation, which is type
/// and air rather than another hairline.
struct RailSubhead: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(Theme.Font.meta).foregroundStyle(Theme.Ink.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Theme.Metric.subheadTop)
    }
}

/// Label and a `SegmentedSwitch` after it: View, Holes, Face, Where.
struct PillSwitchRow<Option: Hashable & Identifiable>: View {
    let label: String
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    var enabled: (Option) -> Bool = { _ in true }
    var reason: (Option) -> String = { _ in "" }

    var body: some View {
        HStack(spacing: 0) {
            RowLabel(label)
            SegmentedSwitch(options: options, selection: $selection, title: title,
                            enabled: enabled, reason: reason)
        }
        .frame(minHeight: Theme.Metric.rowHeight)
    }
}

/// *Another* and *Another frame*: a new draw of a seed, in a pill with the
/// die that says it is a draw and not a choice.
struct DiceButton: View {
    let title: String
    let help: String
    var fill = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "die.face.5")
                    .font(.system(size: 10, weight: .regular))
                Text(title).font(Theme.Font.label).lineLimit(1).fixedSize()
                if fill { Spacer(minLength: 0) }
            }
            .foregroundStyle(Theme.Ink.secondary)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: fill ? .leading : .center)
            .frame(height: Theme.Metric.controlHeight)
            .background(Theme.pill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - format words

extension FilmEdgeFormat.Group {
    @MainActor var title: String {
        switch self {
        case .film135: "135"
        case .film120: "120"
        case .panoramic: L(.edgeGroupPanoramic)
        }
    }
}

extension FilmEdgeFormat {
    /// The menu's and the pill's name.
    @MainActor var title: String {
        if let key { return L(key) }
        switch self {
        case .f135: return "135"
        case .f135Half: return "Half"
        case .f645: return "645"
        case .f6x6: return "6×6"
        case .f6x7: return "6×7"
        case .f6x8: return "6×8"
        case .f6x9: return "6×9"
        case .xpan: return "XPan"
        case .f6x12: return "6×12"
        case .f6x17: return "6×17"
        }
    }

    /// The gate as the drawing writes it after the pill: `36 × 24`.
    var gateLabel: String {
        switch self {
        case .f135: "36 × 24"
        case .f135Half: "18 × 24"
        case .f645: "56 × 41.5"
        case .f6x6: "56 × 56"
        case .f6x7: "56 × 69.5"
        case .f6x8: "56 × 76"
        case .f6x9: "56 × 84"
        case .xpan: "24 × 65"
        case .f6x12: "56 × 112"
        case .f6x17: "56 × 168"
        }
    }

    /// The menu's second line: the gate and its ratio.
    var menuSize: String {
        let ratio = switch self {
        case .f135, .f6x9: "3:2"
        case .f135Half: "3:4"
        case .f645: "1.35"
        case .f6x6: "1:1"
        case .f6x7: "1.24"
        case .f6x8: "1.36"
        case .xpan: "2.7"
        case .f6x12: "2:1"
        case .f6x17: "3:1"
        }
        return "\(gateLabel) mm · \(ratio)"
    }

    /// Film pixels per picture pixel: camera 19's canvases, from the port
    /// (`SpektraLab_mobile/design/overscan/README.md` §2, and the drawing's
    /// menu for the panoramic three). Another body differs by a percent or
    /// two, since the margins along the film are drawn per camera. Nil where
    /// nothing was measured.
    func filmCost(_ view: FilmEdgeView) -> Double? {
        switch (self, view) {
        case (.f135, .strip): 1.52
        case (.f135Half, .strip): 1.53
        case (.f645, .strip): 1.19
        case (.f6x6, .strip): 1.16
        case (.f6x7, .strip), (.f6x8, .strip): 1.14
        case (.f6x9, .strip): 1.13
        case (.xpan, .strip): 1.48
        case (.f6x12, .strip): 1.13
        case (.f6x17, .strip): 1.10
        case (.f135, .filed): 1.15
        case (.f135Half, .filed): 1.20
        case (.f645, .filed): 1.08
        case (.f6x6, .filed), (.f6x7, .filed): 1.07
        case (.f6x8, .filed), (.f6x9, .filed): 1.06
        case (.xpan, .filed), (.f6x12, .filed), (.f6x17, .filed): nil
        }
    }
}

// MARK: - what this rail needs from the session

extension Session {
    /// The picture's pixels: the crop's output at the source's own size, as
    /// the Crop section's caption computes it. Nil before a frame is open.
    var edgePicturePixels: (w: Int, h: Int)? {
        let size = sourceImageSize
        guard sourceLongEdge > 0, size.width > 1 else { return nil }
        let scale = sourceLongEdge / max(size.width, size.height)
        let out = geometry.outputSize(for: size)
        return (Int((out.width * scale).rounded()), Int((out.height * scale).rounded()))
    }

    /// True while the engine draws a film edge: the Crop section is then held
    /// and Film Format is set by it.
    var filmEdgeHoldsFrame: Bool { params.filmEdge.effective }
}
