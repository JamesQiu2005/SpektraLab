//  LayerPage.swift — what the column shows under the 图层 panel with a picture's row picked
//  (design/layers/LAYERS-SPEC.md §5, PRD-D §3.6, §3.7).
//
//  胶片 picked, the column is the column: Film & Paper and Format, as for any photograph. A picture's row —
//  a pair's frame, a double's exposure — shows that picture's own page and nothing of the film's: where it
//  lies (摆放), its own stops, its white balance (written to its photograph, R3), a pair's frame's print and
//  date, and the photograph itself (replace, remove). An empty layer shows the way a photograph gets in. In
//  编辑 a picture has nothing of its own: one line says so and gives the way back to 胶片, the pick kept.
//  Which sections, in which order, is `LayerRules.page`; this file draws them.

import SwiftUI

/// The picked picture's page in 冲洗.
struct LayerPictureColumn: View {
    let session: OpenFrameSession
    let frame: LibraryFrame
    let pick: LayerPick
    @Environment(AppServices.self) private var model
    @Environment(FrameCatalog.self) private var library
    @AppStorage("develop.wide.layers.advanced.open") private var advancedOpen = false
    /// The sections folded away, by name: each folds as the column's do, and stays as it was left.
    @AppStorage("develop.wide.layers.page.folded") private var foldedRaw = ""

    private func folded(_ section: LayerSection) -> Bool { foldedRaw.split(separator: ",").contains(Substring(section.rawValue)) }
    private func toggle(_ section: LayerSection) {
        var names = Set(foldedRaw.split(separator: ",").map(String.init))
        if !names.insert(section.rawValue).inserted { names.remove(section.rawValue) }
        foldedRaw = names.sorted().joined(separator: ",")
    }
    /// A section's folding header, as the column's (`ColumnSectionHeader`), with what trails it.
    private func header<A: View>(_ section: LayerSection, _ title: String, rule: Bool = true, @ViewBuilder accessory: @escaping () -> A) -> some View {
        ColumnSectionHeader(title: title, folded: folded(section), id: "layers." + section.rawValue, rule: rule,
                            toggleFold: { toggle(section) }, accessory: accessory)
    }
    private func header(_ section: LayerSection, _ title: String, rule: Bool = true) -> some View {
        header(section, title, rule: rule) { EmptyView() }
    }
    private func summary(_ text: String) -> some View {
        Text(text).font(Theme.Font.ui(12, .medium)).foregroundStyle(Theme.secondaryText).lineLimit(1).padding(.trailing, 16)
    }
    private var stage: LayersStage { .shared }
    private var has: (UUID) -> Bool { { library.frame($0) != nil } }

    private var piece: LayerPiece { session.layerPiece }
    /// The photograph in the picked row, from the library; nil for an empty row and one that has left it.
    private var photograph: LibraryFrame? {
        switch (piece, pick) {
        case (.pair(let pair), .frame(let side)): pair[side].flatMap { $0.frame }.flatMap { library.frame($0) }
        case (.double(let double), .exposure(let position)): double[position].flatMap { library.frame($0.frame) }
        default: nil
        }
    }
    private var name: String { LayerRules.rows(piece, has: has).first { $0.pick == pick }?.name ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            switch LayerRules.page(pick, piece: piece, mode: .develop, has: has) {
            case .film, .standsDown, .mask: EmptyView()
            case .empty: empty
            case .picture(let sections):
                ForEach(sections, id: \.self) { section in self.section(section) }
                LayerFilmLink(session: session)
            }
        }
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("layers.page." + pick.key)
    }

    // MARK: an empty layer

    private var empty: some View {
        let double = { if case .double = piece { true } else { false } }()
        return VStack(alignment: .leading, spacing: 12) {
            Note(double ? L("An empty layer is unexposed film: the frame develops with the other exposure’s light alone.")
                 : L("An empty hole is unexposed film."))
            Note(double ? L("Fill both exposures to export the double exposure.") : L("Fill both frames to export the pair."))
            CapsuleButton(title: double ? L("Add Exposure") + "…" : L("Add Frame") + "…", height: 32) {
                stage.asking = .init(frame: frame.id, pick: pick)
            }
            .accessibilityIdentifier("layers.add." + pick.key)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.top, 14)
    }

    // MARK: the sections

    @ViewBuilder private func section(_ section: LayerSection) -> some View {
        switch section {
        case .arrange: arrange
        case .exposure: pairExposure
        case .advanced: advanced
        case .whiteBalance: whiteBalance
        case .enlarger: EnlargerGroup(session: session)
        case .dateBack: dateBack
        case .photograph: photographSection
        }
    }

    /// 摆放: where the picture lies, and the way in.
    @ViewBuilder private var arrange: some View {
        header(.arrange, L("Arrange"), rule: false) { summary(placedText) }
        if !folded(.arrange) {
            HStack(spacing: 8) {
                Chip(title: L("Arrange") + "…", height: 26, size: 12.5, padding: 12) {
                    stage.arranging = .init(frame: frame.id, pick: pick)
                }
                .accessibilityIdentifier("layers.page.arrange")
                if case .double(let double) = piece, case .exposure(let position) = pick {
                    Chip(title: L("Flip Horizontally"), on: double[position]?.placement.flipped ?? false,
                         height: 26, size: 12.5, padding: 12) { model.flipDouble(frame.id, position) }
                        .accessibilityIdentifier("layers.page.flip")
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, FoldHeader<EmptyView, EmptyView>.titleInset).padding(.trailing, 16)
            .frame(height: 36).padding(.bottom, 6)
        }
    }

    private var placedText: String {
        switch (piece, pick) {
        case (.pair(let pair), .frame(let side)): pair[side].map { PairWords.placed($0.placement) } ?? ""
        case (.double(let double), .exposure(let position)): double[position].map { DoubleExposure.placedText($0.placement) } ?? ""
        default: ""
        }
    }

    /// A pair's frame's own stops, where they land, and its meter (G5: the wide column had the whole's alone).
    @ViewBuilder private var pairExposure: some View {
        if case .pair(let pair) = piece, case .frame(let side) = pick, let hole = pair[side] {
            header(.exposure, L("Exposure")) {
                HStack(spacing: 6) {
                    PairScopePill(scope: hole.exposureScope, of: L("exposure")) { scope in
                        model.changePair(frame.id) { piece, _ in piece[side]?.exposureScope = scope }
                    }
                    meter(hole.meter(film: session.edit.params)) { method in
                        model.changePair(frame.id) { piece, look in piece.take(meter: method, on: side, look: &look.params) }
                    }
                }
                .padding(.trailing, 16)
            }
            if !folded(.exposure) {
            ValueSlider(title: L("Exposure"),
                        value: Binding(get: { hole.exposureEV },
                                       set: { ev in model.changePair(frame.id) { piece, look in piece.exposure(ev, of: side, look: &look.params) } }),
                        range: HalfFramePair.exposureRange, step: 0.05, text: { Fmt.signed($0, decimals: 2) + " EV" },
                        detentAtRest: true, onEditingChanged: session.editing(.shoot))
                .padding(.horizontal, 16).frame(height: 40).padding(.bottom, 4)
            }
        }
    }

    /// A double's exposure's own stops and meter, folded away: Balance is the control, these are the numbers
    /// under it (R4). Moving one moves Balance, and the line says where to.
    @ViewBuilder private var advanced: some View {
        if case .double(let double) = piece, case .exposure(let position) = pick, let exposure = double[position] {
            ColumnSectionHeader(title: L("Advanced"), folded: !advancedOpen, id: "layers.advanced",
                                toggleFold: { advancedOpen.toggle() }) {
                // Folded, the line still says what is under it: this exposure's own stops.
                summary(L("Exposure") + " " + Fmt.signed(exposure.exposureEV, decimals: 2))
            }
            .accessibilityIdentifier("layers.page.advanced")
            if advancedOpen {
                ValueSlider(title: L("Exposure"),
                            value: Binding(get: { exposure.exposureEV }, set: { model.setDoubleExposure(frame.id, position, ev: $0) }),
                            range: DoubleExposure.exposureRange, rest: DoubleExposure.madeEV, step: 0.05,
                            text: { Fmt.signed($0, decimals: 2) + " EV" }, detentAtRest: true,
                            onEditingChanged: session.editing(.shoot))
                    .padding(.horizontal, 16).frame(height: 40)
                LayerLine(L("Meter")) {
                    meter(exposure.meter(film: session.edit.params)) { model.setDoubleMeter(frame.id, position, $0) }
                }
                if let balance = double.balance {
                    Note(L("Balance →") + " " + BalanceTrack.valueText(balance))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 6)
                }
            }
        }
    }

    private func meter(_ now: AEMethod, take: @escaping (AEMethod) -> Void) -> some View {
        PillMenu(label: now == .custom ? L("Source") : now.title,
                 rows: AEMethod.offered.map { PillMenu<AEMethod>.Row(option: $0, title: $0.title) },
                 selected: now, accessibilityName: L("Meter"), pick: take)
    }

    /// The picture's white balance: its photograph's own decode, written there (R3).
    @ViewBuilder private var whiteBalance: some View {
        switch (piece, pick) {
        case (.pair, .frame(let side)):
            LayerWhiteBalance(session: session, subject: photograph, inPair: true, folded: folded(.whiteBalance), toggleFold: { toggle(.whiteBalance) },
                              change: { model.changeDecode(of: side, in: frame.id, $0) },
                              lifted: { model.keepDecode(of: side, in: frame.id) })
        case (.double, .exposure(let position)):
            LayerWhiteBalance(session: session, subject: photograph, inPair: false, folded: folded(.whiteBalance), toggleFold: { toggle(.whiteBalance) },
                              change: { model.changeDecode(on: DoubleExposure.Layer(position), inDouble: frame.id, $0) },
                              lifted: { model.keepDecode(of: position, inDouble: frame.id) })
        default: EmptyView()
        }
    }

    /// A pair's frame's own date.
    @ViewBuilder private var dateBack: some View {
        if case .pair(let pair) = piece, case .frame(let side) = pick {
            let back = session.edit.dateBack
            let dated = pair.prints(side, back: back)
            header(.dateBack, L("Date Back")) {
                SpkToggle(isOn: Binding(get: { dated }, set: { on in
                    model.changePair(frame.id) { piece, look in piece.setDated(on, side, back: &look.dateBack) }
                }), size: .compact)
                .padding(.trailing, 16)
                .accessibilityLabel(L("Date Back on this frame"))
                .accessibilityIdentifier("layers.page.date")
            }
            if !folded(.dateBack) {
            Note(dated && back.style == .data && !pair.wearsFilmEdge ? L("Data needs Film Edge")
                 : PairWords.dateNote(back, strip: pair.wearsFilmEdge))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, FoldHeader<EmptyView, EmptyView>.titleInset).padding(.trailing, 16).padding(.bottom, 8)
            }
        }
    }

    /// The photograph itself: which it is, and replacing or removing it.
    @ViewBuilder private var photographSection: some View {
        let free = mayChange || photograph == nil
        let removable = free && otherHeld
        header(.photograph, L("Photograph"))
        if !folded(.photograph) {
        HStack(spacing: 10) {
            Group {
                if let photograph { FramePicture(picture: photograph.picture, pointSize: 44) } else { Theme.card }
            }
            .frame(width: 44, height: 30).clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            Text(photograph?.fileName ?? L("Not in the library"))
                .font(Theme.Font.ui(12.5, .medium)).foregroundStyle(photograph == nil ? Theme.dim : Theme.text)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, FoldHeader<EmptyView, EmptyView>.titleInset).padding(.trailing, 16).frame(height: 40)
        HStack(spacing: 8) {
            Chip(title: L("Replace") + "…", height: 26, size: 12.5, padding: 12, dim: !free) {
                if free { stage.asking = .init(frame: frame.id, pick: pick) }
            }
            .accessibilityIdentifier("layers.page.replace")
            Chip(title: L("Remove"), height: 26, size: 12.5, padding: 12, dim: !removable) {
                if removable { remove() }
            }
            .accessibilityIdentifier("layers.page.remove")
            Spacer(minLength: 0)
        }
        .padding(.leading, FoldHeader<EmptyView, EmptyView>.titleInset).padding(.trailing, 16).frame(height: 34)
        Note(photographNote(free: free))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, FoldHeader<EmptyView, EmptyView>.titleInset).padding(.trailing, 16).padding(.top, 2).padding(.bottom, 8)
            .accessibilityIdentifier("layers.page.photo")
        }
    }

    private var mayChange: Bool {
        switch (piece, pick) {
        case (.pair(let pair), .frame(let side)): pair.mayChange(side)
        case (.double(let double), .exposure(let position)): double.mayChange(position)
        default: false
        }
    }

    private var otherHeld: Bool {
        switch (piece, pick) {
        case (.pair(let pair), .frame(let side)): pair[side.other] != nil
        case (.double(let double), .exposure(let position)): double[position.other] != nil
        default: false
        }
    }

    private func photographNote(free: Bool) -> String {
        let double = { if case .double = piece { true } else { false } }()
        if photograph == nil {
            return double ? L("This photograph is no longer in the library. Replace or remove it.")
                : L("This frame is no longer in the library. Replace or remove it.")
        }
        if !free {
            return double ? L("The double exposure began with this photograph: it stays. Swap Top and Bottom moves it.") : PairWords.begunWith
        }
        return L("It is in the library by itself as well.")
    }

    private func remove() {
        withAnimation(.easeOut(duration: 0.18)) {
            switch (piece, pick) {
            case (.pair, .frame(let side)):
                model.changePair(frame.id) { piece, look in piece.fill(side, with: nil, look: &look.params) }
            case (.double, .exposure(let position)):
                model.removeDouble(frame.id, position)
            default: break
            }
        }
    }
}

/// A section's name on a picture's page: the column's hairline and a 32-unit line, with what trails it.
struct LayerSectionTitle<Accessory: View>: View {
    let title: String
    var rule = true
    @ViewBuilder var accessory: () -> Accessory

    init(_ title: String, rule: Bool = true, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title; self.rule = rule; self.accessory = accessory
    }

    var body: some View {
        VStack(spacing: 0) {
            if rule { FoldRule() }
            HStack(spacing: 8) {
                Text(title).font(Theme.Font.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                accessory()
            }
            .padding(.horizontal, 16)
            .frame(height: FoldHeader<EmptyView, EmptyView>.height)
        }
    }
}

extension LayerSectionTitle where Accessory == EmptyView {
    init(_ title: String, rule: Bool = true) { self.init(title, rule: rule) { EmptyView() } }
}

/// One line of a picture's page: its name, and what trails it.
struct LayerLine<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing) { self.title = title; self.trailing = trailing }

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.Font.ui(12.5, .medium)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 32)
    }
}

/// A picture's white balance: its photograph's Temperature and Tint, and back to the camera's own.
struct LayerWhiteBalance: View {
    let session: OpenFrameSession
    /// The photograph whose decode this is; nil when it has left the library.
    let subject: LibraryFrame?
    let inPair: Bool
    let folded: Bool
    let toggleFold: () -> Void
    let change: ((inout DecodeSettings) -> Void) -> Void
    let lifted: () -> Void
    /// The camera's own numbers, kept from when the page first showed the photograph under As Shot.
    @State private var camera: [LibraryFrame.ID: (temperature: Double, tint: Double)] = [:]

    private var decode: DecodeSettings { subject?.edit.decode ?? DecodeSettings() }
    private var reach: PanelNotes.SceneReach {
        guard let subject else { return .gone }
        if subject.isDemo || subject.developsFromRAW { return inPair ? .rawInPair : .raw }
        return subject.isRAW ? .previewCopy : .notRAW
    }

    var body: some View {
        let d = decode
        let reaches = reach.reaches
        VStack(spacing: 0) {
            ColumnSectionHeader(title: L("White Balance"), folded: folded, id: "layers.whiteBalance", toggleFold: toggleFold) {
                RoundButton(diameter: 22, label: L("As Shot"), action: {
                    change { d in
                        d.whiteBalance = .asShot
                        if let subject, let cam = camera[subject.id] { (d.temperature, d.tint) = cam }
                    }
                    lifted()
                }) { Icon(.reset, size: 13) }
                .rowEnabled(reaches && d.whiteBalance != .asShot)
                .padding(.trailing, 16)
            }
            if !folded {
                Group {
                    // The scales' tints are Decode's own (`ScenePanel`): where each slider takes the picture.
                    ValueSlider(title: L("Temperature"), value: binding(\.temperature), range: 2000...10000, rest: 5500, step: 50,
                                text: { "\(Int($0.rounded())) K" }, sub: d.whiteBalance == .asShot ? L("As Shot") : nil,
                                tint: { Color.lerp(0x5F86C9, 0xE0B25E, $0) }, showsRest: false, onEditingChanged: editing)
                        .frame(height: 40)
                    ValueSlider(title: L("Tint"), value: binding(\.tint), range: -150...150, step: 1,
                                text: { Fmt.signed($0, decimals: 0) }, tint: { Color.lerp(0x6FBF73, 0xB77BD0, $0) },
                                onEditingChanged: editing)
                        .frame(height: 40)
                }
                .padding(.horizontal, 16)
                .rowEnabled(reaches)
                Note(reaches ? L("White balance is written to this photograph in the library.") : PanelNotes.whiteBalance(reach).first ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, FoldHeader<EmptyView, EmptyView>.titleInset).padding(.trailing, 16).padding(.top, 2).padding(.bottom, 8)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("layers.page.wb")
        .task(id: subject?.id) {
            guard let subject, subject.edit.decode.whiteBalance == .asShot, camera[subject.id] == nil else { return }
            camera[subject.id] = (subject.edit.decode.temperature, subject.edit.decode.tint)
        }
    }

    private var editing: (Bool) -> Void {
        let page = session.editing(.shoot)
        return { down in
            page(down)
            if !down { lifted() }
        }
    }

    private func binding(_ path: WritableKeyPath<DecodeSettings, Double>) -> Binding<Double> {
        Binding(get: { decode[keyPath: path] },
                set: { v in change { d in d[keyPath: path] = v; d.whiteBalance = .custom } })
    }
}

/// Under a picture's page: what is not here, and the way to it.
struct LayerFilmLink: View {
    let session: OpenFrameSession

    var body: some View {
        VStack(spacing: 0) {
            FoldRule()
            Button { session.pick(row: .film) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "film").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondaryText).frame(width: 12)
                    Text(L("Film, paper and effects belong to Film")).font(Theme.Font.ui(12, .medium))
                        .foregroundStyle(Theme.secondaryText).multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.dim)
                }
                .padding(.horizontal, 16).frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(scale: 1))
            .accessibilityIdentifier("layers.page.film-link")
        }
    }
}

/// 编辑 with a picture picked: Edit works on the finished picture, so the tools stand down under this line,
/// and the pick is kept (the owner's decision 4).
struct LayerStandsDown: View {
    let session: OpenFrameSession
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Note(L("\(name) has no edits of its own. Edit works on the whole film."))
            Chip(title: L("Select Film"), height: 26, size: 12.5, padding: 12) { session.pick(row: .film) }
                .accessibilityIdentifier("layers.page.select-film")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("layers.page.stands-down")
    }
}

/// Decode's White Balance with 胶片 picked on a pair or a double (R3): it is each picture's, so the whole has
/// none — one line, and one way into each picture's own.
struct LayerWhiteBalanceLinks: View {
    let session: OpenFrameSession
    @Environment(FrameCatalog.self) private var library

    var body: some View {
        let piece = session.layerPiece
        let rows = LayerRules.whiteBalanceRows(LayerRules.rows(piece, has: { library.frame($0) != nil }))
        let double = { if case .double = piece { true } else { false } }()
        VStack(alignment: .leading, spacing: 6) {
            Note(double ? L("White balance belongs to each exposure.") : L("White balance belongs to each frame."))
            HStack(spacing: 8) {
                ForEach(rows) { row in
                    Chip(title: row.name, height: 26, size: 12.5, padding: 12) { session.pick(row: row.pick) }
                        .accessibilityIdentifier("layers.wb." + row.pick.key)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, FoldHeader<EmptyView, EmptyView>.titleInset).padding(.trailing, 16).padding(.bottom, 10)
    }
}

/// 格式's 多重曝光 section with 胶片 picked: whose the frame is, and the swap.
struct DoublePieceSection: View {
    let session: OpenFrameSession
    let frame: LibraryFrame
    let double: DoubleExposure
    @Environment(AppServices.self) private var model
    @Environment(FrameCatalog.self) private var library
    private var stage: LayersStage { .shared }

    var body: some View {
        let has: (UUID) -> Bool = { library.frame($0) != nil }
        let target = LayerRules.arranges(.film, piece: .double(double), last: stage.lastExposure[frame.id], has: has)
        VStack(spacing: 0) {
            LayerSectionTitle(L("Double Exposure"), rule: false)
            Note(DoubleWords.frameIsBottoms)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 6)
            HStack(spacing: 8) {
                Chip(title: L("Swap Top and Bottom"), height: 26, size: 12.5, padding: 12, dim: !double.isFilled) {
                    if double.isFilled { model.swapDouble(frame.id) }
                }
                .accessibilityIdentifier("layers.double.swap")
                Chip(title: L("Arrange") + "…", height: 26, size: 12.5, padding: 12, dim: target == nil) {
                    guard let target else { return }
                    session.pick(row: target)
                    stage.arranging = .init(frame: frame.id, pick: target)
                }
                .accessibilityIdentifier("layers.double.arrange")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).frame(height: 34)
            Note(L("The bottom sets the frame and the date"))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("layers.double.section")
    }
}
