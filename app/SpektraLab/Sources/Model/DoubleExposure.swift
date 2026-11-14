//  DoubleExposure.swift — two exposures on one frame of film (多重曝光).
//
//  The model of RFC-047 §2 (`rfc/RFC-047-double-exposure-model-and-keeping.md`), approved by the owner
//  with PRD 2 on 2026-11-07. **A sibling of the half-frame pair, not a generalised piece** (RFC-047 §1):
//  `HalfFramePair` is read at 237 places and is a file format users already hold, so nothing of it moves.
//  What the two share is taken from it as it is — the placement (`HalfFramePair.Placement`, scale 1…4,
//  x/y across the slack, quarter turns), its arithmetic (`HalfFramePair.sourceRect`, `turned`, the drag
//  and the pinch), the per-picture meter key, the file helpers — and the pair's own code is not changed.
//
//  What this file holds is the *piece*: which photograph is each exposure, how each is cut and laid
//  over the frame, and each exposure's own light. The look — film, paper, print, effects, Film Edge,
//  Date Back, Edit's layer — is the item's `FrameEdit`, the whole's, as a pair's item keeps the pair's
//  (`DoubleExposure.look(from:)` is how it starts: the bottom exposure's look).
//
//  **Two exposures, bottom first** (`exposures[0]` is the bottom, `[1]` the top). Light adds, so the
//  order does not decide what covers what (PRD 2 §3.1): the **bottom sets the frame** — its shape
//  (`frameAspect`), its date, the frame the piece began with — and the **top is laid over it**. How
//  strongly the top shows is **Balance**, the top's share of the frame's light (`balance`, RFC-047 §4).
//  A layer whose photograph was removed from the library is `nil` (the pair's "hole left empty").
//  The list holds two in version 1 (`maxExposures`); it is a list so that three can come later.
//
//  **A double exposure is a file** (`….spektradouble`, JSON, pretty and sorted as the pair writes its
//  own), so the item can be written and read on its own. It references its photographs and does not
//  own them: removing a double exposure leaves both photographs (PRD 2 §5).
//
//  **What is not here, and where it is** (the build order of RFC-050 §9):
//
//  - the composition for the engine — `PieceAsk.Lay.add`, the flip in `PiecePlacer`, the metering
//    render, the cost model's `double` key, `FrameEdit.doubleWire` — RFC-048, lane B;
//  - the removal cascade, the guide before develop, the decode mirror written to the photograph, the
//    older-build guard — `Services/DoubleKeeping.swift`, `Services/LibraryShelf.swift` (lane A, built:
//    what is of the piece alone — which layers a removal empties, what the guide is drawn from and with
//    which gains — is at the end of this file, so the selftest holds it on a Mac); the stamps and keys —
//    RFC-047 §5.2, lane B;
//  - the darkroom's band, panels and Place cover — RFC-050, lane D.
//
//  Pure Foundation and CoreGraphics, with the app's own `Geometry`, `DecodeSettings`, `FilmParams`,
//  `StockCatalog` and `HalfFramePair`: `tools/double_selftest.swift` compiles it on a Mac.

import CoreGraphics
import Foundation

struct DoubleExposure: Codable, Equatable, Sendable {
    static let fileExtension = "spektradouble"
    /// Exposures on one frame in this version (PRD 2 §9: three or more is out of scope).
    static let maxExposures = 2
    /// An exposure's own stops, on top of its meter: the pair's `Hole.exposureEV` range (RFC-047 §4).
    static let exposureRange = HalfFramePair.exposureRange
    /// What Balance may be set to (PRD 2 §3.1, D3): "outside that, one exposure fades into grain".
    static let balanceRange = 0.10...0.90
    /// Each exposure's stops when a double exposure is made: `log2(1/N)` for N = 2, the film shooter's
    /// rule — each half a normal exposure, so the frame as a whole is one (RFC-047 §4, "Made").
    static let madeEV = -1.0

    var schemaVersion = 1
    /// As the pair's: where its file and guide live. Empty when there is one library.
    var folder: String
    /// Bottom first. Nil is a layer whose photograph was removed. Always `maxExposures` long once made
    /// or read (`init`, `init(from:)`); the subscript pads a shorter list read from elsewhere.
    var exposures: [Exposure?]
    /// **The frame the piece began with** (the pair's `origin`, the owner, 2026-10-09: "you should not be
    /// granted the ability to swap out the original image, only to exchange places"). It stays in the
    /// double exposure (`mayChange`); a swap may move it to the top. Nil for one made from two picked
    /// together in Select (RFC-049 §3: `beginsWithFirst: false`).
    var origin: UUID?

    /// One exposure: a photograph of the library, as it lies on the frame, and its own light.
    struct Exposure: Codable, Equatable, Sendable {
        /// The library photograph, referenced, not owned.
        var frame: UUID
        /// Its decode — white balance, lens correction — read from the photograph, which stays its own:
        /// a change in the darkroom is written to the photograph and read back (the pair's `mirror`).
        var decode = DecodeSettings()
        /// The photograph's own cut — crop, straighten, turns, flips, or Film Edge's framing while it wore
        /// one (`LibraryFrame.pictureGeometry`) — read from it, as a pair's hole reads `geometry`.
        var cut = Geometry.default
        /// Where it lies on the frame (RFC-047 §3).
        var placement = Placement()
        /// This exposure's own stops, on top of its meter (RFC-047 §4). `madeEV` when made.
        var exposureEV = DoubleExposure.madeEV
        /// Metered alone, as if it were the only picture (PRD 2 §4.2), or not: then `exposureEV` alone.
        var autoExposure = true
        /// The meter's intent (`FilmParams.autoExposureMethod`'s names). **"legacy" stands for none** — the
        /// engine's own centre-weighted, no `auto_exposure_method` on the wire — as the pair's `meterKey`
        /// writes a nil method (`wireMethod` gives it back as nil).
        var meterMethod = "legacy"
        /// What the engine's meter read for this picture alone, by what it was read for
        /// (`DoubleExposure.meterKey`) — so a reading is used only while the picture is still what was
        /// read, and moving it never re-meters it (the pair's rule against pumping).
        var meterReadings: [String: Double] = [:]

        init(frame: UUID) { self.frame = frame }

        /// A newly made exposure of a library photograph: its decode and its cut read from its own edit,
        /// laid in the middle, at `madeEV`, **metered alone** with the photograph's own intent.
        ///
        /// Metered whatever the photograph's own switch said: PRD 2 §4.2, "each exposure is metered alone,
        /// as if it were the only picture, so a dark scene and a bright scene start equal". (A pair's new
        /// hole inherits its frame's switch instead: `HalfFramePair.Hole.init(path:frame:sourceEdit:…)`.)
        init(frame: UUID, sourceEdit: FrameEdit, sourceGeometry: Geometry) {
            self.frame = frame
            decode = sourceEdit.decode
            cut = sourceGeometry
            meterMethod = sourceEdit.params.autoExposureMethod ?? "legacy"
        }

        /// The intent as the wire takes it: nil for "legacy".
        var wireMethod: String? { meterMethod == "legacy" ? nil : meterMethod }

        enum CodingKeys: String, CodingKey {
            case frame, decode, cut, placement, exposureEV, autoExposure, meterMethod, meterReadings
        }

        /// Every key but the frame optional, so a file from before a field existed still opens.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            frame = try c.decode(UUID.self, forKey: .frame)
            // An exposure written without its decode is read as the old decode, as a pair's hole is.
            if let saved = try? c.decodeIfPresent(DecodeSettings.self, forKey: .decode) { decode = saved }
            else { decode.rawExposureTreatment = .legacy }
            cut = (try? c.decodeIfPresent(Geometry.self, forKey: .cut)) ?? .default
            placement = (try? c.decodeIfPresent(Placement.self, forKey: .placement)) ?? Placement()
            exposureEV = try c.decodeIfPresent(Double.self, forKey: .exposureEV) ?? DoubleExposure.madeEV
            autoExposure = try c.decodeIfPresent(Bool.self, forKey: .autoExposure) ?? true
            meterMethod = try c.decodeIfPresent(String.self, forKey: .meterMethod) ?? "legacy"
            meterReadings = try c.decodeIfPresent([String: Double].self, forKey: .meterReadings) ?? [:]
        }
    }

    /// **The pair's `Placement` plus a horizontal flip** (RFC-047 §2, §3). `base` is the pair's own, with
    /// its own arithmetic: scale 1 fills the frame and never goes below it — "an exposure always covers
    /// the whole frame, as a real second exposure exposes the whole gate" (PRD 2 §4.1) — x and y move it
    /// across the slack the fit leaves, quarter turns clockwise.
    ///
    /// **A flip mirrors the window's content, not the window**: it is applied after the quarter turns and
    /// before the window is cut (RFC-048 §2, `PiecePlacer.place`, lane B), so the window's fractions mean
    /// the same with or without it, and a drag moves the picture the same way either way.
    struct Placement: Codable, Equatable, Sendable {
        var base = HalfFramePair.Placement()
        var flipped = false

        init(base: HalfFramePair.Placement = HalfFramePair.Placement(), flipped: Bool = false) {
            self.base = base
            self.flipped = flipped
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            base = try c.decodeIfPresent(HalfFramePair.Placement.self, forKey: .base) ?? HalfFramePair.Placement()
            flipped = try c.decodeIfPresent(Bool.self, forKey: .flipped) ?? false
        }

        /// Held to what the frame can show: the pair's `held`.
        var held: Placement { Placement(base: base.held, flipped: flipped) }
    }

    /// Which exposure: the bottom sets the frame, the top is laid over it.
    enum Position: Int, CaseIterable, Codable, Sendable {
        case bottom = 0, top = 1
        var other: Position { self == .bottom ? .top : .bottom }
    }

    init(folder: String = "") {
        self.folder = folder
        exposures = Array(repeating: nil, count: Self.maxExposures)
    }

    init(folder: String = "", bottom: Exposure?, top: Exposure?, origin: UUID? = nil) {
        self.init(folder: folder)
        exposures = [bottom, top]
        self.origin = origin
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, folder, exposures, origin
    }

    /// Every key optional, as the pair's: a file from before a field existed still opens.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        var read = try c.decodeIfPresent([Exposure?].self, forKey: .exposures) ?? []
        if read.count < Self.maxExposures { read += Array(repeating: nil, count: Self.maxExposures - read.count) }
        exposures = read
        origin = try? c.decodeIfPresent(UUID.self, forKey: .origin)
    }

    subscript(position: Position) -> Exposure? {
        get { exposures.indices.contains(position.rawValue) ? exposures[position.rawValue] : nil }
        set {
            while exposures.count <= position.rawValue { exposures.append(nil) }
            exposures[position.rawValue] = newValue
        }
    }

    /// Both layers hold a photograph. Whether each is still in the library is the library's to say.
    var isFilled: Bool { Position.allCases.allSatisfy { self[$0] != nil } }
    /// No layer holds one: a double exposure with no exposure left is removed (RFC-047 §5, lane A).
    var isEmpty: Bool { Position.allCases.allSatisfy { self[$0] == nil } }
    /// The photographs it holds, bottom first, each once.
    var frameIDs: [UUID] {
        var seen: [UUID] = []
        for position in Position.allCases { if let id = self[position]?.frame, !seen.contains(id) { seen.append(id) } }
        return seen
    }
    /// Where `frame` lies, bottom first; nil when it is in neither.
    func position(of frame: UUID) -> Position? { Position.allCases.first { self[$0]?.frame == frame } }

    // MARK: - the layers (PRD 2 §2: 下层 · 底片 · 上层)

    /// What an edit is about, one at a time: the whole (Film) or one exposure. The pair's `Layer`, with
    /// the double's own names. `film` is 0, as on the pair, so a page that starts on the whole starts on 0.
    enum Layer: Int, CaseIterable, Identifiable, Sendable {
        case film, bottom, top
        var id: Int { rawValue }
        /// The band's order, left to right: 下层 · 底片 · 上层 (PRD 2 §2).
        static let band: [Layer] = [.bottom, .film, .top]
        var position: Position? {
            switch self {
            case .film: nil
            case .bottom: .bottom
            case .top: .top
            }
        }
        init(_ position: Position) { self = position == .bottom ? .bottom : .top }

        /// "Bottom", "Film", "Top" (下层 · 底片 · 上层 in the PRD; the catalog's "Film" is the pair's).
        var title: String {
            switch self {
            case .film: L("Film")
            case .bottom: L("Bottom", as: "an exposure")
            case .top: L("Top", as: "an exposure")
            }
        }
    }

    /// The pair's spelling of the same, for a page that asks the piece.
    func title(_ layer: Layer) -> String { layer.title }

    /// The exposure `layer` is, when it is one that is there.
    func pickedPosition(_ layer: Layer) -> Position? { layer.position.flatMap { self[$0] == nil ? nil : $0 } }

    // MARK: - the frame the piece began with (the pair's rule)

    /// Whether the exposure at `position` may be **replaced or removed** on a page entered with `origin`.
    /// The pair's `mayChange(_:enteredWith:)` word for word: the frame the piece began with keeps a layer;
    /// a swap moves it, Replace and Remove stand down on it. The same photograph in both layers: either
    /// may go, the other still holds it.
    func mayChange(_ position: Position, enteredWith origin: UUID?) -> Bool {
        guard let origin, self[position]?.frame == origin else { return true }
        return self[position.other]?.frame == origin
    }

    /// The same, for the frame this double exposure began with: the rule holds for as long as it is one.
    func mayChange(_ position: Position) -> Bool { mayChange(position, enteredWith: origin) }

    /// Another photograph in a layer, or none (Replace, Remove). **Refused** where `mayChange` says no,
    /// and the answer says whether it was done. A photograph removed from the library is not this: the
    /// removal cascade empties the layer whatever it held (RFC-047 §5, lane A), through the subscript.
    ///
    /// `before` and `after` are each exposure's picture as its own cut frames it (`Framed`), before and
    /// after the change: when the bottom is replaced by one of another shape, both are laid again as on a
    /// swap (`refit`). The new exposure comes as it is given — `Exposure(frame:sourceEdit:sourceGeometry:)`
    /// lays it in the middle at `madeEV`.
    @discardableResult
    mutating func fill(_ position: Position, with exposure: Exposure?, before: Framed = [:], after: Framed = [:]) -> Bool {
        guard mayChange(position) else { return false }
        let was = frameAspect(before)
        self[position] = exposure
        refit(from: was, framed: after)
        return true
    }

    // MARK: - exposure and balance: one truth (RFC-047 §4, PRD 2 §4)
    //
    // Each exposure keeps one number, its own `exposureEV`. Its light on the frame is 2^(reading + EV)
    // metered, 2^EV with its meter off (`stops`). **Balance** is the top's share of the frame's light with
    // the readings left out, s = g_top / (g_top + g_bottom), g = 2^exposureEV — so 50 % means "each as
    // metered, halved". Nothing is stored twice: Balance is read from the two numbers and writes both.

    /// 2^EV: the gain of `stops` on a picture, the pair's `gain(stops:)`.
    static func gain(_ ev: Double) -> Double { pow(2.0, ev) }

    /// s = 2^top / (2^top + 2^bottom).
    static func share(top: Double, bottom: Double) -> Double {
        let t = gain(top), b = gain(bottom)
        return t / (t + b)
    }

    /// **Balance**: the top's share of the frame's light, 0…1 (shown as 0–100 %). Nil until both layers
    /// hold a photograph: with one there is nothing to balance.
    var balance: Double? {
        guard let top = self[.top], let bottom = self[.bottom] else { return nil }
        return Self.share(top: top.exposureEV, bottom: bottom.exposureEV)
    }

    /// The frame's light with the readings left out, T = g_top + g_bottom: what Balance holds.
    var totalGain: Double? {
        guard let top = self[.top], let bottom = self[.bottom] else { return nil }
        return Self.gain(top.exposureEV) + Self.gain(bottom.exposureEV)
    }

    /// **Moving Balance to `s`**: T is kept, g_top = s·T and g_bottom = (1 − s)·T, and both `exposureEV`
    /// are written. `s` is held to `balanceRange` first.
    ///
    /// Each EV is then held to `exposureRange`, the pair's −5…5. Inside it the arithmetic is exact; at
    /// its ends (a total already near ±5 EV and a share near 10 % or 90 %) the held EV no longer keeps
    /// T, and the exposure stops at the end of its own range rather than going past it. Arithmetic, not
    /// measured: no tester has reached it.
    mutating func setBalance(_ s: Double) {
        guard let total = totalGain, total > 0, self[.top] != nil, self[.bottom] != nil else { return }
        let share = s.clamped(to: Self.balanceRange)
        self[.top]?.exposureEV = log2(share * total).clamped(to: Self.exposureRange)
        self[.bottom]?.exposureEV = log2((1 - share) * total).clamped(to: Self.exposureRange)
    }

    /// **An exposure's own slider** moves its `exposureEV` alone, held to `exposureRange`: the frame's
    /// light and Balance both move, and the Balance slider is redrawn from them.
    mutating func exposure(_ ev: Double, of position: Position) {
        guard self[position] != nil else { return }
        self[position]?.exposureEV = ev.clamped(to: Self.exposureRange)
    }

    /// Back to how it was made (↺ on the whole, PRD 2 §4.2): each exposure at `madeEV` — Balance 50 % —
    /// and metered alone. Not the placements or the order: the pair's rule.
    mutating func resetExposures() {
        for position in Position.allCases where self[position] != nil {
            self[position]?.exposureEV = Self.madeEV
            self[position]?.autoExposure = true
        }
    }

    /// Each exposure's stops on the frame: what the meter read for it alone plus its own and the whole's
    /// Film Exposure — or, with its meter off (its own, or the whole's Custom), its own and the whole's
    /// alone. Nil for a layer with no photograph, or whose meter has not read yet.
    ///
    /// **Film Exposure on the whole is `look.exposureCompensationEV`** and adds the same stops to both
    /// (RFC-048 §4: `plus = exposureEV + filmExposureEV`), so Balance — read from `exposureEV` alone — is
    /// unchanged by it, and so is the ratio of the two exposures' light. It is never on the wire
    /// (RFC-048 §3: `exposure_compensation_ev` 0), as on the pair.
    func stops(_ position: Position, look: FilmParams) -> Double? {
        guard let e = self[position] else { return nil }
        let plus = e.exposureEV + look.exposureCompensationEV
        guard e.autoExposure, look.autoExposure else { return plus }
        return reading(position).map { $0 + plus }
    }

    // MARK: - the meter, one picture at a time (as the pair keeps it)

    /// What a reading was taken for: the photograph, its decode, its own cut and the intent — the pair's
    /// `meterKey`, field for field, with the exposure's own intent. **Not its placement**, so placing a
    /// picture never re-meters it (RFC-048 §4).
    static func meterKey(_ e: Exposure) -> String {
        let d = e.decode, g = e.cut
        // The lens's fields where they are not at rest ("" otherwise: the key is what it was).
        return [e.frame.uuidString, d.whiteBalance.rawValue + d.exposureKey, String(d.temperature), String(d.tint),
                String(d.lensCorrection) + d.meterLensWord(fileName: nil), e.meterMethod,
                "\(g.crop.x),\(g.crop.y),\(g.crop.width),\(g.crop.height),\(g.quarterTurns)"].joined(separator: "|")
    }

    /// The reading kept for the exposure as it is now, if one is.
    func reading(_ position: Position) -> Double? {
        guard let e = self[position] else { return nil }
        return e.meterReadings[Self.meterKey(e)]
    }

    /// Readings an exposure keeps, by key: the last few decodes and cuts it was read for, so going back
    /// to one does not read again. Past this the old ones go. A bound on the file, not a measurement.
    static let readingsKept = 8

    /// A reading of the engine's meter, kept: for the exposure it was read for, and only while it is still
    /// what was read (`meterKey`). False when the exposure has moved on and the reading is dropped.
    @discardableResult
    mutating func keep(reading ev: Double, of position: Position, for key: String) -> Bool {
        guard var e = self[position], Self.meterKey(e) == key else { return false }
        if e.meterReadings[key] == nil, e.meterReadings.count >= Self.readingsKept { e.meterReadings = [:] }
        e.meterReadings[key] = ev
        self[position] = e
        return true
    }

    /// The shot stays the photograph's: its decode and its cut are read again from it whenever the piece
    /// is written (the pair's `mirror`). True when either had moved — the picture's pixels are then other
    /// pixels, and its meter reads again under its new key.
    @discardableResult
    mutating func mirror(_ position: Position, decode: DecodeSettings, cut: Geometry) -> Bool {
        guard var e = self[position], e.decode != decode || e.cut != cut else { return false }
        e.decode = decode
        e.cut = cut
        self[position] = e
        return true
    }

    // MARK: - the frame's shape, each exposure's window, the frame's size (RFC-047 §3, RFC-048 §5)

    /// Each exposure's picture as its own cut frames it — `cut.outputSize(for:)` of the size of the file
    /// it is developed from (`LibraryFrame.developSize`) — **before** its placement's quarter turns.
    typealias Framed = [Position: CGSize]

    /// **The frame's shape**, width over height: the bottom exposure's framed aspect — its photograph cut
    /// by its own edit — or the gate's when the whole wears a film edge (`gateAspect`, as a photograph's
    /// film-edge cut, `Engine/HostCut.swift`). With the bottom's layer empty, the top's: the one picture
    /// left sets the frame until another is added. Nil with neither.
    func frameAspect(_ framed: Framed, gateAspect: Double? = nil) -> Double? {
        if let gateAspect, gateAspect > 0, gateAspect.isFinite { return gateAspect }
        for position in [Position.bottom, .top] {
            guard self[position] != nil, let size = framed[position], size.width > 0, size.height > 0 else { continue }
            return Double(size.width / size.height)
        }
        return nil
    }

    /// The part of an exposure's picture the frame shows, as fractions of the picture **after its quarter
    /// turns** (and its flip, which does not move the fractions), top-left origin. Zoom ≥ 1, so never
    /// smaller than the frame. The pair's `sourceRect(for:source:aspect:)` with the frame's aspect in
    /// place of the hole's (RFC-047 §3). `framed` is the picture as its cut frames it, unturned.
    static func window(_ placement: Placement, framed: CGSize, aspect: Double) -> CGRect {
        let turned = HalfFramePair.turned(framed, by: placement.base)
        guard turned.width > 0, turned.height > 0, aspect > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let cut = HalfFramePair.sourceRect(for: placement.base, source: turned, aspect: aspect)
        return CGRect(x: cut.minX / turned.width, y: cut.minY / turned.height,
                      width: cut.width / turned.width, height: cut.height / turned.height)
    }

    /// The window of the exposure at `position` on this frame. Nil for an empty layer or one whose
    /// picture's size is not known.
    func window(_ position: Position, framed: Framed, gateAspect: Double? = nil) -> CGRect? {
        guard let e = self[position], let size = framed[position], let aspect = frameAspect(framed, gateAspect: gateAspect) else { return nil }
        return Self.window(e.placement, framed: size, aspect: aspect)
    }

    /// **The frame's size at the full tier** (RFC-048 §5): the bottom's framed size, **but no larger than
    /// the top can fill at scale 1 without being enlarged** — the pair's rule that "neither is enlarged"
    /// (`PAIR-WIRING.md` §2). Each picture's fit at the frame's aspect, at scale 1 whatever it is zoomed to
    /// (a zoom must not resize the frame, `HalfFramePair.pieceLayout`), after its quarter turns; the frame
    /// is the smallest of them, rounded down. A 48 MP bottom and a 12 MP top make a ~12 MP frame.
    ///
    /// `pictures` are each exposure's picture as it is turned on the frame (`HalfFramePair.turned`). Nil
    /// with no picture, or no shape.
    static func frameSize(aspect: Double, pictures: [CGSize]) -> PixelSize? {
        guard aspect > 0, aspect.isFinite else { return nil }
        var smallest: CGRect?
        for picture in pictures where picture.width > 0 && picture.height > 0 {
            let fit = HalfFramePair.sourceRect(for: HalfFramePair.Placement(), source: picture, aspect: aspect)
            if smallest.map({ fit.width < $0.width }) ?? true { smallest = fit }
        }
        guard let fit = smallest else { return nil }
        return PixelSize(width: max(Int(fit.width.rounded(.down)), 1), height: max(Int(fit.height.rounded(.down)), 1))
    }

    /// The same for this double exposure, from each exposure's framed picture; `longEdge` caps it for a
    /// job below the full tier, as a pair's `pieceSize(_:longEdge:)` does (the same shape, smaller).
    func frameSize(_ framed: Framed, gateAspect: Double? = nil, longEdge: Int? = nil) -> PixelSize? {
        guard let aspect = frameAspect(framed, gateAspect: gateAspect) else { return nil }
        let pictures = Position.allCases.compactMap { position -> CGSize? in
            guard let e = self[position], let size = framed[position] else { return nil }
            return HalfFramePair.turned(size, by: e.placement.base)
        }
        guard let own = Self.frameSize(aspect: aspect, pictures: pictures) else { return nil }
        guard let longEdge, longEdge > 0 else { return own }
        return own.scaled(toLongEdge: longEdge)
    }

    /// A drag of `d` — a fraction of the frame, x right and y down — on an exposure: the pair's
    /// `placement(_:draggedBy:source:aspect:)` on the base, the flip kept. `framed` unturned.
    static func placement(_ origin: Placement, draggedBy d: CGSize, framed: CGSize, aspect: Double) -> Placement {
        Placement(base: HalfFramePair.placement(origin.base, draggedBy: d, source: framed, aspect: aspect), flipped: origin.flipped)
    }

    /// A pinch by `factor` about `anchor` (a point of the frame, 0…1, y down): the pair's
    /// `placement(_:zoomedBy:about:source:aspect:)` on the base, the flip kept.
    static func placement(_ origin: Placement, zoomedBy factor: Double, about anchor: CGPoint, framed: CGSize,
                          aspect: Double) -> Placement {
        Placement(base: HalfFramePair.placement(origin.base, zoomedBy: factor, about: anchor, source: framed, aspect: aspect),
                  flipped: origin.flipped)
    }

    // MARK: - who is on top (RFC-047 §3, PRD 2 §3.2)

    /// Two shapes the same, to a thousandth: a rounding of the same picture is not another shape.
    static func sameShape(_ a: Double?, _ b: Double?) -> Bool {
        guard let a, let b, a > 0, b > 0 else { return a == nil && b == nil }
        return abs(a / b - 1) < 1e-3
    }

    /// **Swap top and bottom** (交換上下), in one mutation so that one undo step undoes all of it:
    ///
    /// 1. the order is reversed — each exposure takes its photograph, decode, cut, meter and placement
    ///    with it;
    /// 2. **Balance stays with the position** (PRD 2 §8.2, decided): the new top gets the old top's share.
    ///    The two `exposureEV` stay where they were (the position's number moves to the photograph now
    ///    there), which keeps s and T exactly, with no clamp — at 50 % a swap of two same-shaped exposures
    ///    develops the same, at 70 % it visibly changes, as swapping two layers in an editor does;
    /// 3. **if the new bottom's shape differs, both are laid again** (`refit`): the frame's shape follows
    ///    the new bottom.
    ///
    /// `framed` is each exposure's picture by its position **before** the swap; nothing else is read.
    mutating func swap(framed: Framed = [:]) {
        let was = frameAspect(framed)
        let bottomEV = self[.bottom]?.exposureEV, topEV = self[.top]?.exposureEV
        let b = self[.bottom]
        self[.bottom] = self[.top]
        self[.top] = b
        if let bottomEV, let topEV {
            self[.bottom]?.exposureEV = bottomEV
            self[.top]?.exposureEV = topEV
        }
        var after: Framed = [:]
        if let size = framed[.top] { after[.bottom] = size }
        if let size = framed[.bottom] { after[.top] = size }
        refit(from: was, framed: after)
    }

    /// The frame's shape may have moved from `was` (another bottom): **the bottom gets its default** — it
    /// now sets the frame: centred, scale 1, no turn, no flip — and **the top keeps its centre and turn
    /// and has its zoom held** (`Placement.held`). The same shape: nothing moves (RFC-047 §3). `framed` is
    /// by position, after the change.
    mutating func refit(from was: Double?, framed: Framed) {
        let now = frameAspect(framed)
        guard !Self.sameShape(was, now) else { return }
        if self[.bottom] != nil { self[.bottom]?.placement = Placement() }
        if let top = self[.top] { self[.top]?.placement = top.placement.held }
    }

    // MARK: - the whole's look

    /// The look a new double exposure develops with: **its bottom exposure's** (PRD 2 §4.2, "the bottom
    /// exposure's look becomes the double exposure's look, as a pair takes its first frame's look"), with
    /// what `HalfFramePair.look(from:)` does to a first frame's, minus what is the pair's alone:
    ///
    /// - **the film is loaded, not copied**: a slide is scanned and never printed, whatever the bottom's
    ///   edit said, and the one paper its film prints on (the pair's answer B6);
    /// - **the meter off and no Film Exposure of its own**: each exposure carries its light in its pixels
    ///   (RFC-048 §3, §4); `startingLook` gives the look's switch back when it is kept, as on the pair;
    /// - **no cut** (`asDoubleLook`): each exposure was cut by its own photograph and laid by the host;
    ///   the piece is the frame;
    /// - **no solved exposure**: a report of the bottom's own develop, not of this one;
    /// - **one frame of film** — unlike the pair, no half-frame size: the bottom's own Film Format stays
    ///   (RFC-048 §3, `film_format_mm` "the look's own (one frame)");
    /// - **the film edge kept** (RFC-047 §5): the frame wears the film like any frame. Its framing goes —
    ///   the bottom's framing is already its exposure's cut (`LibraryFrame.pictureGeometry`), and the
    ///   piece is composed at the gate's shape, whose largest cut about the middle is the whole of it;
    /// - the Date Back, Effects, the print and Edit's layer as the bottom had them (PRD 2 §4.2, "Date
    ///   Back: the bottom's, if it had one"), as the pair keeps its first frame's.
    static func look(from bottom: FrameEdit, catalog: StockCatalog = .shared) -> FrameEdit {
        var e = bottom
        e.params.load(film: bottom.params.filmStock, catalog: catalog, recommendingPaper: false)
        e.params.autoExposure = false
        e.params.exposureCompensationEV = 0
        e.solvedEV = nil
        return e.asDoubleLook
    }

    /// The host's meter gate for a newly kept double exposure, as `HalfFramePair.startingLook`: the look's
    /// switch on when either exposure is metered (it stands for both on the Film tab; the wire stays
    /// metered-off, RFC-048 §3), no Film Exposure of its own. A double exposure kept before keeps its look.
    func startingLook(_ look: FrameEdit) -> FrameEdit {
        var fresh = look
        fresh.params.autoExposure = Position.allCases.contains { self[$0]?.autoExposure == true }
        fresh.params.exposureCompensationEV = 0
        return fresh
    }

    // MARK: - the file

    static func isDouble(_ url: URL) -> Bool { url.pathExtension == fileExtension }

    static func load(_ url: URL) -> DoubleExposure? {
        guard isDouble(url), let data = try? Data(contentsOf: url) else { return nil }
        return decoded(data)
    }

    static func decoded(_ data: Data) -> DoubleExposure? {
        try? JSONDecoder().decode(DoubleExposure.self, from: data)
    }

    /// The file's bytes, as the pair writes its own: pretty, keys sorted.
    func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url, options: .atomic)
    }

    /// The double exposures kept in `directory`, with their files, in name order.
    static func doubles(in directory: URL) -> [(url: URL, double: DoubleExposure)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter(isDouble)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { url in load(url).map { (url, $0) } }
    }

    /// The library item's name for the `n`th: "Double Exposure 3". Not a translated word: a pair's is
    /// "Half-Frame Pair 3" in every language, and the file is named by it.
    static func name(_ n: Int) -> String { "Double Exposure \(n)" }

    /// A file for a new double exposure in `directory`: "Double Exposure 3.spektradouble", the first
    /// number none there has.
    static func newURL(in directory: URL) -> URL {
        var n = 1
        while true {
            let url = directory.appendingPathComponent("\(name(n)).\(fileExtension)")
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }
}

// MARK: - a photograph removed, and the guide before develop (RFC-047 §5, §5.1)

extension DoubleExposure {
    /// **A photograph has left the library** (RFC-047 §5, the removal cascade): every layer that held one
    /// of `removed` is left empty — the pair's "hole left empty" — **whatever `mayChange` says**: the frame
    /// the piece began with is no longer there to be kept, so it is no longer the origin either. The other
    /// layer stays where it is (a top left alone is still the top: the bottom's layer waits for a
    /// photograph). With the bottom's layer emptied the frame's shape is the top's now, so the top is laid
    /// again as on a swap (`refit`; `before`/`after` by position, before and after). True when a layer
    /// was emptied.
    @discardableResult
    mutating func empty(holding removed: Set<UUID>, before: Framed = [:], after: Framed = [:]) -> Bool {
        let was = frameAspect(before)
        var any = false
        for position in Position.allCases where self[position].map({ removed.contains($0.frame) }) == true {
            self[position] = nil
            any = true
        }
        if let origin, removed.contains(origin) { self.origin = nil }
        guard any else { return false }
        refit(from: was, framed: after)
        return true
    }

    /// Whether no layer is left holding a photograph once `removed` have gone: every layer empty, holding
    /// one of `removed`, or holding a photograph the library no longer has (`has`; one removed by an older
    /// build, `LibraryShelf`). **A double exposure left so is removed** with its last photograph (RFC-047
    /// §5); one with one exposure left stays, and waits for a second.
    func isLeftEmpty(removing removed: Set<UUID>, has: (UUID) -> Bool) -> Bool {
        Position.allCases.allSatisfy { position in
            guard let id = self[position]?.frame else { return true }
            return removed.contains(id) || !has(id)
        }
    }

    /// One exposure as its guide lays it (`DoubleGuide`, RFC-047 §5.1).
    struct GuideLayer: Equatable, Sendable {
        var position: Position
        /// The part of the picture, cut and turned, that is shown, in fractions with a top-left origin — **of
        /// the picture before its flip**: a flipped exposure's window is the frame's window mirrored, and the
        /// picture cut by it is mirrored after (`flipped`). The same pixels as cutting the flipped picture.
        var window: CGRect
        var quarterTurns: Int
        var flipped: Bool
        /// The exposure's light on the frame, 2^`exposureEV`: the gain its picture is multiplied by in
        /// linear light before the two are added.
        var gain: Double
    }

    /// What the guide is drawn from: each exposure with a picture of known size, bottom first, laid as the
    /// frame lays it (`window`), with **its own stops alone** for its gain — Balance as it is set, 2^EV —
    /// so a double exposure just made is the two pictures at half their light each, added (RFC-047 §4:
    /// "50 % means each as metered, halved").
    ///
    /// **The meter's reading is left out**, and so is the whole's Film Exposure: a guide is drawn from the
    /// files' own previews, which their cameras have already exposed, not from a decode the engine's meter
    /// read. It shows where each picture lies and how strongly each shows against the other; the develop
    /// shows the light.
    func guideLayers(_ framed: Framed) -> [GuideLayer] {
        Position.allCases.compactMap { position in
            guard let e = self[position], let window = window(position, framed: framed) else { return nil }
            let shown = e.placement.flipped ? Self.mirrored(window) : window
            return GuideLayer(position: position, window: shown, quarterTurns: e.placement.base.quarterTurns,
                              flipped: e.placement.flipped, gain: Self.gain(e.exposureEV))
        }
    }

    /// A window mirrored left to right: what a window of a flipped picture is of the picture unflipped.
    static func mirrored(_ window: CGRect) -> CGRect {
        CGRect(x: 1 - window.maxX, y: window.minY, width: window.width, height: window.height)
    }

    /// **What a guide is drawn from**, as one key (the pair's `guideKey`): which photographs, how each is
    /// cut, where it lies and whether it is flipped, and each exposure's own stops — the guide's gains. The
    /// guide is drawn again when this moves (`AppModel.changeDouble`).
    ///
    /// **Not an exposure's decode** (its white balance, its lens correction), nor its meter, its reading or
    /// its intent: the guide is the files' own previews, and is drawn on the main thread. The pair's v0.1
    /// had the decode in its key, and every tick of a Temperature ruler read both files again until the system's
    /// watchdog ended the app (2026-10-15, 0x8BADF00D, `HalfFramePair.guideKey`).
    var guideKey: String {
        Position.allCases.map { position in
            guard let e = self[position] else { return "-" }
            let p = e.placement.held, g = e.cut
            return [e.frame.uuidString, "\(p.base.scale)", "\(p.base.x)", "\(p.base.y)", "\(p.base.quarterTurns)", "\(p.flipped)",
                    "\(g.crop.x),\(g.crop.y),\(g.crop.width),\(g.crop.height),\(g.angle),\(g.quarterTurns),\(g.flipH),\(g.flipV)",
                    "\(e.exposureEV)"]
                .joined(separator: "|")
        }.joined(separator: ";")
    }

    /// **The double exposure as a develop of it sees it**: everything but the meter's kept readings. A
    /// reading is kept after the develop that read it (`keep(reading:of:for:)`, `EngineRouter.onDoubleMetered`),
    /// and the next develop lays the same light from it that the engine's own meter laid (RFC-048 §4) — so
    /// a reading arriving is not an edit, and must not make the develop page think its picture is behind
    /// (`OpenFrameSession.owed`, the pair's `HalfFramePair.changes` leaving its readings out the same way).
    /// Everything else — which photographs, their decodes and cuts, where each lies, its flip, its own
    /// stops, its meter on or off — is the picture's.
    var developed: DoubleExposure {
        var copy = self
        for position in Position.allCases {
            guard var e = copy[position] else { continue }
            e.meterReadings = [:]
            copy[position] = e
        }
        return copy
    }
}

extension FrameEdit {
    /// This edit as a double exposure's look is kept: **no cut of its own** — the piece is the frame, each
    /// exposure cut by its photograph and laid by the host (RFC-048 §3, "the cut: none") — and no Film
    /// Edge framing, for the same reason (`DoubleExposure.look(from:)`). Unlike a pair's look the film
    /// edge stays as it is, on or off, with its turn: the frame wears the film as a photograph does.
    /// Held wherever an edit enters a double exposure, as `asPairLook` is for a pair.
    var asDoubleLook: FrameEdit {
        var look = self
        look.geometry = .default
        look.filmEdge.framing = nil
        return look
    }
}
