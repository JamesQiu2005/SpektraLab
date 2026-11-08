//  PairPanels.swift — the pair's darkroom: what the Frame tab holds for the picked layer, and the pills a frame's own settings wear.
//
//  design/pair v2 (`design/src/gen_pair_v2.py`): `panel_piece`, `panel_picture`
//  and `panel_empty`. The develop page on a half-frame pair has one layer
//  picked at a time (`OpenFrameSession.layer`) and every tab is about it. Film,
//  Print and Effects are the develop page's own panels, which read the layer
//  (`FilmPanel`, `PrintPanel`, `EffectsPanel`); Frame is these three:
//
//  - **the film picked** (`PairPiecePanel`, H5): the piece itself — how the
//    camera was held, how far apart the frames are, the film's edge, its date
//    back, and the two frames changed over. What the pair's own page held
//    under *Film* until 2026-10-10, with the two things that page could only
//    switch in a system sheet.
//  - **a frame picked** (`PairPicturePanel`, H6): its picture under the hole —
//    a row to the page it is placed on, where Crop is for a photograph —
//    whether the back printed on this exposure, and the frame itself changed
//    for another or taken out.
//  - **an empty hole picked** (`PairEmptyPanel`, H9): the way a frame gets in.
//
//  Every edit of the piece goes through `AppServices.changePair`, the one place a
//  kept pair's piece is written; the develop is this page's session's, asked
//  for as for any control.
//
//  Every y is the generator's own number minus 550, the rule under the tabs
//  (`PairPanelY`), as `PanelY` has the develop page's.

import SwiftUI

/// Where the pair's panels' parts sit, from the rule under the tabs
/// (`gen_pair_v2.panel_piece`, `panel_picture`, `panel_empty`).
enum PairPanelY {
    /// The film: the piece.
    enum Piece {
        static let camera: CGFloat = 27
        static let seg: CGFloat = 9
        static let segment: CGFloat = 76
        static let spacing: CGFloat = 62
        static let rule1: CGFloat = 111.5
        /// Film Edge, Date Back, Swap: one line each, as the Frame tab's rows are.
        static let rows: [CGFloat] = [136, 168, 200]
        static let separator: CGFloat = 12.5
        /// A row's pill: 22 tall, its top 15.5 above the row's baseline.
        static let pillRise: CGFloat = 15.5
        static let pillHeight: CGFloat = 22
    }

    /// A frame: its picture, its date, itself.
    enum Picture {
        static let picture: CGFloat = 28
        static let rule1: CGFloat = 40.5
        static let date: CGFloat = 64
        static let toggle: CGFloat = 44
        static let dateNote: CGFloat = 87
        static let rule2: CGFloat = 100.5
        static let chips: CGFloat = 114
        static let note: CGFloat = 165
    }

    /// An empty hole.
    enum Empty {
        static let button: CGFloat = 20
        static let note: CGFloat = 88
    }
}

// MARK: - a pill with a menu

/// `pill_menu`: a value and the chevron that opens its choices — the meter's
/// own pill on Film (`FilmPanel.meterMenu`), for the pair's rows. An option
/// that cannot be chosen is listed dimmed, with why.
struct PillMenu<Option: Hashable>: View {
    struct Row {
        var option: Option
        var title: String
        /// A second line under the title, in the menu.
        var detail: String? = nil
        /// Why it cannot be chosen now; nil when it can.
        var refused: String? = nil
    }

    let label: String
    let rows: [Row]
    let selected: Option?
    var accessibilityName: String
    let pick: (Option) -> Void

    var body: some View {
        Menu {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Button { pick(row.option) } label: {
                    if row.option == selected {
                        Label(row.title, systemImage: "checkmark")
                    } else {
                        Text(row.title)
                    }
                    if let line = row.refused ?? row.detail { Text(line) }
                }
                .disabled(row.refused != nil)
            }
        } label: {
            HStack(spacing: 5.5) {
                Text(label).font(Theme.Font.ui(12)).foregroundStyle(Theme.secondaryText).lineLimit(1).fixedSize()
                Icon(.chevronDown, size: 19.25, color: Theme.secondaryText).frame(width: 7, height: 7)
            }
            .padding(.leading, 12)
            .padding(.trailing, 9.5)
            .frame(height: PairPanelY.Piece.pillHeight)
            .background(Capsule().fill(Theme.card))
            // The pill is 22 tall; a finger gets the row's height.
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        // The drawing's pill, not the system's pop-up button.
        .menuStyle(.button)
        .buttonStyle(PressStyle())
        .menuIndicator(.hidden)
        .accessibilityLabel(accessibilityName + ", " + label)
    }
}

// MARK: - a frame's own exposure: where it lands, and its meter

/// *Applies to*, as a pill beside what it applies to (the desktop's *Frame* /
/// *+ Film*, answers B1–B3): an edit of one frame lands on that frame only,
/// or on the frame and the film round it by the same amount.
struct PairScopePill: View {
    let scope: HalfFramePair.Scope
    /// "exposure", "print": what the edit is, for VoiceOver.
    let of: String
    let pick: (HalfFramePair.Scope) -> Void

    var body: some View {
        PillMenu(label: scope.label,
                 rows: [.init(option: HalfFramePair.Scope.frame, title: L("Frame", as: "one of a pair"), detail: L("This frame only")),
                        .init(option: HalfFramePair.Scope.film, title: L("+ Film"), detail: L("The film round it moves with it"))],
                 selected: scope, accessibilityName: L("This frame's \(of) applies to"), pick: pick)
    }
}

extension HalfFramePair.Hole {
    /// This frame's meter as the Film tab's pill says it: its own intent, the
    /// film's where it has none, or Custom — the meter off, the frame exposed
    /// as it was shot. **A frame is metered when its own switch and the film's
    /// are both on** (`HalfFramePair.piece`), so the film's switch off reads
    /// Custom on both frames, which is what it is.
    func meter(film: FilmParams) -> AEMethod {
        guard autoExposure, film.autoExposure else { return .custom }
        guard let wire = meterMethod ?? film.autoExposureMethod else { return .legacy }
        return ExposureMethod(rawValue: wire).map(AEMethod.metered) ?? .legacy
    }

    /// Take a meter from the pill. Custom leaves the intent alone, as it does
    /// for a photograph (`AEMethod.apply`).
    mutating func take(meter: AEMethod) {
        switch meter {
        case .custom: autoExposure = false
        case .metered(let m):
            autoExposure = true
            meterMethod = m.rawValue
        case .legacy: autoExposure = true
        }
    }

    /// "meter +0.4": what the meter chose for this picture alone, once it has
    /// read; "meter off" for a frame exposed as it was shot.
    func meterText(film: FilmParams) -> String? {
        guard autoExposure, film.autoExposure else { return L("meter off") }
        return meteredEV.map { L("meter ") + Fmt.signed($0) }
    }
}

extension HalfFramePair {
    /// A frame's own meter, from its pill. Where the film's switch is off —
    /// both frames exposed as shot — metering one frame turns the film's on
    /// and leaves the other as it was, unmetered: the choice is that frame's,
    /// and has to do something.
    mutating func take(meter: AEMethod, on side: Side, look: inout FilmParams) {
        if case .custom = meter {} else if !look.autoExposure {
            look.autoExposure = true
            self[side.other]?.autoExposure = false
        }
        self[side]?.take(meter: meter)
    }
}

// MARK: - Frame, on a pair

struct PairFramePanel: View {
    let session: OpenFrameSession
    let frame: LibraryFrame
    let pair: HalfFramePair

    var body: some View {
        if let side = session.layer.side {
            if let hole = pair[side] {
                PairPicturePanel(session: session, frame: frame, pair: pair, side: side, hole: hole)
            } else {
                PairEmptyPanel(session: session, frame: frame, pair: pair, side: side)
            }
        } else {
            PairPiecePanel(session: session, frame: frame, pair: pair)
        }
    }
}

/// The hole a frame is being chosen for.
private struct PairPick: Identifiable {
    let side: HalfFramePair.Side
    var id: Int { side.rawValue }
}

private extension View {
    /// Add Frame and Replace: the library's frames in a sheet over the darkroom
    /// (`PairFramePicker`, design/pair G4). The chosen frame fills the hole,
    /// from the middle, with nothing of the frame that was there.
    func pairPicker(_ picking: Binding<PairPick?>, pair: HalfFramePair, pairID: LibraryFrame.ID, model: AppServices) -> some View {
        spkSheet(item: picking, detents: [.fraction((Theme.Metric.designHeight - PairLayout.pickerTop) / Theme.Metric.designHeight)]) { pick in
            PairFramePicker(title: pair[pick.side] == nil ? L("Add Frame") : L("Replace Frame"), subtitle: pair.title(.init(pick.side)),
                            used: Set(HalfFramePair.Side.allCases.compactMap { pair[$0]?.frame }),
                            close: { picking.wrappedValue = nil }) { chosen in
                if let chosenFrame = model.library.frame(chosen), !chosenFrame.isPair {
                    model.changePair(pairID) { piece, look in
                        piece.fill(pick.side, with: PairStart.hole(for: chosenFrame), look: &look.params)
                    }
                }
                picking.wrappedValue = nil
            }
            // A sheet is its own hosting controller: it is handed the app's objects.
            .appEnvironment(model)
        }
    }
}

// MARK: the film picked: the piece (H5)

struct PairPiecePanel: View {
    let session: OpenFrameSession
    let frame: LibraryFrame
    let pair: HalfFramePair
    @Environment(AppServices.self) private var model

    /// The film's edge as its pill offers it: off, or one of its two views.
    private enum Edge: Hashable { case off, view(FilmEdgeView) }
    /// The back as its pill offers it: off, or a face.
    private enum Back: Hashable { case off, face(DateBackFace) }

    private var back: DateBackSettings { session.edit.dateBack }

    private typealias Y = PairPanelY.Piece

    var body: some View {
        DrawnBand(height: PanelY.height) {
            DrawnText(L("Camera"), DevelopType.label, .semibold).leading(16).baseline(Y.camera)
            SegmentedSwitch(options: [false, true],
                            // Each picture stands up, or lies down, with its hole (`HalfFramePair.holdCamera`).
                            selection: Binding(get: { pair.turned }, set: { turned in
                                let pictures = pictures
                                change { piece, _ in piece.holdCamera(turned: turned, pictures: pictures) }
                            }),
                            title: { $0 ? L("Turned", as: "a pair") : L("Level", as: "a pair") }, segmentWidth: Y.segment, track: Theme.card)
                .trailingInset(16).top(Y.seg)

            // On a strip the camera's advance decides the gap: the row stands down and says so.
            RulerRow(label: L("Spacing"), valueText: String(format: "%.1f mm", pair.effectiveSpacingMM),
                     sub: pair.wearsFilmEdge ? L("the camera's advance, on a film edge") : L("between the frames"),
                     value: Binding(get: { pair.effectiveSpacingMM },
                                    set: { mm in change { piece, _ in piece.spacingMM = mm.clamped(to: HalfFramePair.spacingRange) } }),
                     range: HalfFramePair.spacingRange, step: 0.1, majorEvery: 5, snap: 0.1, rulerDrop: PanelY.Part.rulerDrop,
                     labelSize: DevelopType.label, onEditingChanged: session.editing(.shoot))
                .padding(.horizontal, Theme.Metric.margin)
                .rowEnabled(!pair.wearsFilmEdge)
                .baseline(Y.spacing)
            rule.top(Y.rule1 - 0.5)

            if FeatureFlags.filmEdge {
                title(L("Film Edge")).baseline(Y.rows[0])
                PillMenu(label: pair.wearsFilmEdge ? session.edit.filmEdge.mode.label : L("Off"),
                         rows: [.init(option: Edge.off, title: L("Off"))]
                            + FilmEdgeView.allCases.map { .init(option: .view($0), title: $0.label, detail: Self.detail($0)) },
                         selected: pair.wearsFilmEdge ? .view(session.edit.filmEdge.mode) : .off,
                         accessibilityName: L("Film Edge"), pick: take)
                    .trailingInset(16).centreY(Y.rows[0] - Y.pillRise + Y.pillHeight / 2)
                rule.top(Y.rows[0] + Y.separator - 0.5)
            }
            if FeatureFlags.dateBack {
                title(L("Date Back")).baseline(Y.rows[1])
                PillMenu(label: PairWords.backSummary(pair, back),
                         rows: [.init(option: Back.off, title: L("Off"))]
                            + DateBackFace.allCases.map { face in
                                .init(option: .face(face), title: face.label, detail: Self.detail(face),
                                      refused: face == .data && !pair.wearsFilmEdge ? L("Prints between frames: it needs Film Edge") : nil)
                            },
                         selected: pair.printsAnywhere(back) ? .face(back.style) : .off,
                         accessibilityName: L("Date Back"), pick: take)
                    .trailingInset(16).centreY(Y.rows[1] - Y.pillRise + Y.pillHeight / 2)
                rule.top(Y.rows[1] + Y.separator - 0.5)
            }
            Button {
                withAnimation(.easeOut(duration: 0.18)) { change { piece, look in piece.swap(look: &look.params) } }
            } label: {
                DrawnBand(height: PanelY.Frame.rowPitch) {
                    DrawnText(L("Swap the Two Frames"), DevelopType.label, .semibold).leading(16).baseline(20)
                    Chevron().trailingInset(16).centreY(20 - 4.5)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(scale: 1))
            .rowEnabled(pair.left != nil || pair.right != nil)
            .top(Y.rows[2] - 20)
        }
    }

    private func change(_ mutate: (inout HalfFramePair, inout FrameEdit) -> Void) {
        model.changePair(frame.id, mutate)
    }

    /// Each hole's picture as framed (its own crop and turn on the original), by side.
    private var pictures: [HalfFramePair.Side: CGSize] {
        var out: [HalfFramePair.Side: CGSize] = [:]
        for side in HalfFramePair.Side.allCases {
            guard let hole = pair[side], let source = model.library.frame(hole.frame) else { continue }
            let shown = source.displaySizeUnder(hole.geometry)
            out[side] = CGSize(width: shown.width, height: shown.height)
        }
        return out
    }

    /// The film's edge on, in a view, or off.
    private func take(_ edge: Edge) {
        switch edge {
        case .off:
            change { piece, _ in piece.onStrip = false }
        case .view(let view):
            change { piece, look in
                piece.onStrip = true
                look.filmEdge.mode = view
            }
        }
    }

    /// The back, with a face, or off.
    private func take(_ choice: Back) {
        switch choice {
        case .off:
            change { piece, look in piece.setBack(nil, back: &look.dateBack) }
        case .face(let face):
            change { piece, look in piece.setBack(face, back: &look.dateBack) }
        }
    }

    private static func detail(_ view: FilmEdgeView) -> String {
        view == .strip ? L("The film's full width, both frames on it") : L("A sliver of the film round the frames")
    }

    private static func detail(_ face: DateBackFace) -> String {
        switch face {
        case .lcd: L("Each frame's date, seven segments")
        case .dots: L("Each frame's date, in dots")
        case .data: L("Each frame's shutter and aperture, between frames")
        }
    }

    /// A row's title (`row`).
    private func title(_ text: String) -> some View {
        DrawnText(text, DevelopType.label, .semibold)
            .leading(16)
    }

    private var rule: some View {
        Rectangle().fill(Theme.rule).frame(height: Theme.Metric.rule).padding(.horizontal, Theme.Metric.margin)
    }
}

// MARK: a frame picked: its picture, its date, itself (H6)

struct PairPicturePanel: View {
    let session: OpenFrameSession
    let frame: LibraryFrame
    let pair: HalfFramePair
    let side: HalfFramePair.Side
    let hole: HalfFramePair.Hole
    @Environment(AppServices.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(FrameCatalog.self) private var library
    @State private var picking: PairPick?

    private var back: DateBackSettings { session.edit.dateBack }
    /// The frame in the hole, from the library; nil when it has left it.
    private var held: LibraryFrame? { library.frame(hole.frame) }

    private typealias Y = PairPanelY.Picture

    var body: some View {
        let dated = pair.prints(side, back: back)
        // The frame the pair began with keeps a hole: Replace and Remove stand down on it, and the
        // line under them says why. A frame that has left the library is nobody's to keep.
        let free = pair.mayChange(side) || held == nil
        // The last frame is not taken out: a piece with no frame is not a pair.
        let removable = free && pair[side.other] != nil
        DrawnBand(height: PanelY.height) {
            Button { router.show(.pairPlace(frame.id, side)) } label: {
                DrawnBand(height: PanelY.Frame.rowPitch) {
                    DrawnText(L("Picture"), DevelopType.label, .semibold).leading(16).baseline(20)
                    DrawnText(PairWords.placed(hole.placement), 12.5, .medium, Theme.secondaryText).trailingInset(30).baseline(20)
                    Chevron().trailingInset(16).centreY(20 - 4.5)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(scale: 1))
            .rowEnabled(held != nil)
            .top(Y.picture - 20)
            rule.top(Y.rule1 - 0.5)

            if FeatureFlags.dateBack {
                DrawnText(L("Date Back"), DevelopType.label, .semibold)
                    .leading(16).baseline(Y.date)
                DrawnText(dateText(dated), 12.5, .medium, dated ? Theme.secondaryText : Theme.dim, fit: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.leading, 150).padding(.trailing, 16 + 51 + 10)
                    .baseline(Y.date)
                SpkToggle(isOn: Binding(get: { dated }, set: { on in date(on) }))
                    .trailingInset(16).top(Y.toggle)
                    .rowEnabled(held != nil)
                    .accessibilityLabel(L("Date Back on this frame"))
                if back.style != .data || !back.active {
                    note(PairWords.dateNote(back, strip: pair.wearsFilmEdge)).baseline(Y.dateNote)
                }
                rule.top(Y.rule2 - 0.5)
            }

            HStack(spacing: 8) {
                Chip(title: L("Replace"), dim: !free) { if free { picking = PairPick(side: side) } }
                Chip(title: L("Remove"), dim: !removable) {
                    guard removable else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        model.changePair(frame.id) { piece, look in piece.fill(side, with: nil, look: &look.params) }
                    }
                }
            }
            .leading(16).top(Y.chips)
            note(held == nil ? L("This frame is no longer in the library. Replace or remove it.")
                 : !free ? PairWords.begunWith
                 : (held?.fileName ?? "") + Fmt.dot + L("in the library by itself as well.")).baseline(Y.note)
        }
        .pairPicker($picking, pair: pair, pairID: frame.id, model: model)
    }

    /// What the back wrote on this frame, as it wrote it; or that it did not.
    private func dateText(_ dated: Bool) -> String {
        guard dated, let held else { return L("Not printed") }
        // The data face prints between frames: without a strip it has nowhere to.
        if back.style == .data, !pair.wearsFilmEdge { return L("Data needs Film Edge") }
        return FilmEdgeResolver.dateText(back, frame: held).replacingOccurrences(of: "'", with: "’")
    }

    /// This frame's own switch. Switching it on where the back is off puts the back on.
    private func date(_ on: Bool) {
        model.changePair(frame.id) { piece, look in piece.setDated(on, side, back: &look.dateBack) }
    }

    private func note(_ text: String) -> some View {
        DrawnText(text, PanelNotes.size, .regular, Theme.dim, fit: true).spanning(leading: 16, trailing: 16)
    }

    private var rule: some View {
        Rectangle().fill(Theme.rule).frame(height: Theme.Metric.rule).padding(.horizontal, Theme.Metric.margin)
    }
}

// MARK: an empty hole picked (H9)

struct PairEmptyPanel: View {
    let session: OpenFrameSession
    let frame: LibraryFrame
    let pair: HalfFramePair
    let side: HalfFramePair.Side
    @Environment(AppServices.self) private var model
    @State private var picking: PairPick?

    var body: some View {
        DrawnBand(height: PanelY.height) {
            CapsuleButton(title: L("Add Frame"), primary: false) { picking = PairPick(side: side) }
                .padding(.horizontal, Theme.Metric.margin).top(PairPanelY.Empty.button)
            Note(L("An empty hole is unexposed film.\nFill both to export the pair."))
                .padding(.horizontal, Theme.Metric.margin).baseline(PairPanelY.Empty.note)
        }
        .pairPicker($picking, pair: pair, pairID: frame.id, model: model)
    }
}

// MARK: - the pair's words on these panels

extension PairWords {
    /// "LCD · both frames", "Dots · left frame", "Off": the film's row for its
    /// back — and, under the data face with no strip to print it on, why
    /// nothing is printed.
    static func backSummary(_ pair: HalfFramePair, _ back: DateBackSettings) -> String {
        guard pair.printsAnywhere(back) else { return L("Off") }
        if back.style == .data, !pair.wearsFilmEdge { return L("Data") + Fmt.dot + L("needs Film Edge") }
        return pair.backSummary(back, separator: Fmt.dot)
    }

    /// "Placed · 1.35×" for a picture that was moved, enlarged or turned under
    /// its hole; "Centred · 1.00×" for one as it came.
    static func placed(_ placement: HalfFramePair.Placement) -> String {
        let p = placement.held
        return (p == HalfFramePair.Placement() ? L("Centred") : L("Placed")) + Fmt.dot + Fmt.times(p.scale)
    }

    /// Under a frame's own Date Back switch: whose the date is, and whose the face.
    static func dateNote(_ back: DateBackSettings, strip: Bool) -> String {
        L("Each frame was its own exposure, and carries its own date.")
    }
}

extension HalfFramePair {
    /// Whether the back prints on any frame of the piece.
    func printsAnywhere(_ back: DateBackSettings) -> Bool {
        Side.allCases.contains { prints($0, back: back) }
    }
}
