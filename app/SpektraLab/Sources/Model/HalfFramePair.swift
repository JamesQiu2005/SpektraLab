//  HalfFramePair.swift — two neighbouring half frames on one piece of 135 film.
//
//  The desktop's `Model/HalfFramePair.swift`, field for field (SpektraLab
//  `main`, 1.3.1; the maintainer's, so it may cross: UPSTREAM.md), with the
//  piece's arithmetic that the desktop keeps in `Import/PairComposer.swift`
//  (`layout(for:sizes:)`) and `Model/Session.swift` (a drag, a pinch, a crop
//  as a placement, the film's size, where the second frame begins). The design
//  is the desktop's `design-proposals/half-frame-pair-2026-10-02` with the
//  owner's answers (`PRD/QUESTIONS-2026-10-02-…` part B) and what was built
//  after them (`PRD/HANDOFF-2026-10-03-…` §9–§15); on the host, `design/pair`.
//
//  What this file holds is the *piece*: which frame sits in which hole, where
//  each picture sits under its hole, how far apart the holes are, and each
//  frame's exposure on the film. The look — film, paper, enlarger, effects,
//  Film Edge, Date Back — is the pair's own `FrameEdit`, kept for the pair as
//  a frame's is (`HalfFramePair.look(from:)` is how it starts).
//
//  **A pair is a file** (`….spektrapair`, JSON, the desktop's own keys), so
//  one can travel between the two apps. A pair references frames and does not
//  consume them: a frame may be in several pairs (answer B7).
//
//  **Fields the host carries and does not use yet**, and why:
//
//  - `folder`: the desktop's filmstrip is a folder's; the host has one
//    library. Written empty, kept as read.
//  - `path`: on the desktop the frame's file, which is its identity. A host's
//    files move with every install, so a hole is found by `frame` (the
//    library's own id, a key the desktop ignores) and `path` holds the
//    original's own name, for a reader.
//  - `Hole.print`, `printScope`: a frame's own enlarger and whether an edit
//    of it moves the film's print too (answers B1–B3). **Used since
//    2026-10-10** (`trim(_:of:…)`, the desktop's `Session.setEnlarger`): the
//    negative is printed once for the film and once more for each frame whose
//    print is its own, and the prints are cut together along the holes
//    (`Engine/PrintLayers.swift`; the desktop's `Session.pairLayered`,
//    `Renderer.compositePair`). `exposureScope` likewise: + Film moves the
//    film's print brightness by the same stops (`exposure(_:of:…)`).
//  - `Hole.adjustments`: the desktop's Post-Dev grade of one frame. The host
//    has no grade after the print (PAGES.md §4, rule 2), so it is kept as the
//    JSON it was read as (`PairJSON`) and never applied.
//  - `Hole.autoExposure`, `meterMethod`: a frame's own meter, off or with an
//    intent of its own. Read by `stops(_:)`; the pair's darkroom offers them
//    where the develop page offers a photograph's, under pro-control.
//  - `Hole.decode`, `geometry`: the frame's own white balance, lens correction
//    and crop, mirrored from the frame every time the pair is opened
//    (`mirror(_:decode:geometry:)`), as on the desktop. Its `Geometry` is the host's,
//    which has no `lockedRatio`: a desktop pair saved by the host loses that
//    key of a mirror the desktop reads again from the frame itself.
//  - `turned`: a pair with the camera turned (the holes one above the other).
//    Carried, laid out and drawn; the engine's strip for it is the desktop's
//    of 2026-10-03 night and has not been seen on a host.
//
//  Pure Foundation and CoreGraphics, with the host's own `Geometry`,
//  `DecodeSettings`, `FilmParams` and `StockCatalog`: `tools/pair_selftest.swift`
//  compiles it on a Mac and holds it against the desktop's own tests' numbers.

import CoreGraphics
import Foundation

struct HalfFramePair: Codable, Equatable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schemaVersion", folder = "folder", left = "left", right = "right",
            spacingMM = "spacingMM", onStrip = "onStrip", turned = "turned", origin = "origin"
    }
    static let fileExtension = "spektrapair"

    /// One hole of the gate, 18 × 24 mm, and the frame in it.
    struct Hole: Codable, Equatable, Sendable {
        /// The frame's file (the desktop), or its own name (the host).
        var path: String
        /// **The host's key**: the frame in the library. Nil in a pair the
        /// desktop wrote, until the library finds the frame by its name.
        var frame: UUID?
        var placement = Placement()
        /// Exposure of this hole's picture on the film, in stops, on top of
        /// the meter. A plain gain on the picture: unlike a frame's own Film
        /// Exposure it is not re-timed by the enlarger, because one enlarger
        /// prints both holes.
        var exposureEV = 0.0
        /// What the engine's meter chose for this picture alone, and what it
        /// was measured for (`meterKey`). The strip is developed with the
        /// meter off, so each hole is exposed as it would be by itself.
        var meteredEV: Double?
        var meteredFor: String?
        /// The frame's own decode, mirrored: the shot stays the frame's.
        var decode = DecodeSettings()
        /// The frame's own crop, turn and flips, mirrored: a frame turned by
        /// itself is turned in the pair. The placement then moves *that*
        /// picture under the hole.
        var geometry = Geometry.default
        /// This frame's meter: on or off, and the intent it follows (nil: the pair's).
        var autoExposure = true
        var meterMethod: String?
        /// This frame's own print; nil prints as the film does.
        var print: PrintTrim?
        /// The desktop's Post-Dev grade of this frame, carried as read.
        var adjustments: PairJSON?
        /// Where an edit of this frame lands (answers B1–B3): on the frame
        /// only, or on the frame and the film around it by the same amount.
        /// The enlarger starts on the film as well, exposure on the frame.
        var printScope = Scope.film
        var exposureScope = Scope.frame
        /// **The host's key** (the owner, 2026-10-10: "each sub image should
        /// be able to decide if they want date back or information printed"):
        /// whether the back printed on this exposure, while the pair's back is
        /// on. One back, so one face for both frames; what each frame decides
        /// is whether it was switched on for its exposure. A key the desktop
        /// ignores, where the back prints on both or on neither.
        var dated = true

        init(path: String, frame: UUID? = nil) {
            self.path = path
            self.frame = frame
        }

        /// A newly filled hole inherits its source's exposure choice. Saved
        /// holes keep their own switch; reopening a pair never calls this.
        init(path: String, frame: UUID, sourceEdit: FrameEdit, sourceGeometry: Geometry) {
            self.init(path: path, frame: frame)
            decode = sourceEdit.decode
            geometry = sourceGeometry
            autoExposure = sourceEdit.params.autoExposure
            meterMethod = sourceEdit.params.autoExposureMethod
        }

        /// The desktop's own keys, and the host's two (`frame`, `dated`).
        enum CodingKeys: String, CodingKey {
            case path = "path", frame = "frame", placement = "placement", exposureEV = "exposureEV",
                meteredEV = "meteredEV", meteredFor = "meteredFor", decode = "decode", geometry = "geometry",
                autoExposure = "autoExposure", meterMethod = "meterMethod"
            case print = "print", adjustments = "adjustments", printScope = "printScope",
                exposureScope = "exposureScope", dated = "dated"
        }

        /// Every key but the path optional, so a file from before a field
        /// existed still opens.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            frame = try? c.decodeIfPresent(UUID.self, forKey: .frame)
            placement = try c.decodeIfPresent(Placement.self, forKey: .placement) ?? Placement()
            exposureEV = try c.decodeIfPresent(Double.self, forKey: .exposureEV) ?? 0
            meteredEV = try c.decodeIfPresent(Double.self, forKey: .meteredEV)
            meteredFor = try c.decodeIfPresent(String.self, forKey: .meteredFor)
            if let saved = try? c.decodeIfPresent(DecodeSettings.self, forKey: .decode) { decode = saved }
            else { decode.rawExposureTreatment = .legacy }
            geometry = (try? c.decodeIfPresent(Geometry.self, forKey: .geometry)) ?? .default
            autoExposure = try c.decodeIfPresent(Bool.self, forKey: .autoExposure) ?? true
            meterMethod = try c.decodeIfPresent(String.self, forKey: .meterMethod)
            print = try c.decodeIfPresent(PrintTrim.self, forKey: .print)
            adjustments = try c.decodeIfPresent(PairJSON.self, forKey: .adjustments)
            printScope = (try? c.decodeIfPresent(Scope.self, forKey: .printScope)) ?? .film
            exposureScope = (try? c.decodeIfPresent(Scope.self, forKey: .exposureScope)) ?? .frame
            dated = (try? c.decodeIfPresent(Bool.self, forKey: .dated)) ?? true
        }

        /// As the desktop writes a hole, key for key — and the host's own
        /// `dated` only where a frame was switched off, so a pair the desktop
        /// wrote is written back saying what it said.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(path, forKey: .path)
            try c.encodeIfPresent(frame, forKey: .frame)
            try c.encode(placement, forKey: .placement)
            try c.encode(exposureEV, forKey: .exposureEV)
            try c.encodeIfPresent(meteredEV, forKey: .meteredEV)
            try c.encodeIfPresent(meteredFor, forKey: .meteredFor)
            try c.encode(decode, forKey: .decode)
            try c.encode(geometry, forKey: .geometry)
            try c.encode(autoExposure, forKey: .autoExposure)
            try c.encodeIfPresent(meterMethod, forKey: .meterMethod)
            try c.encodeIfPresent(print, forKey: .print)
            try c.encodeIfPresent(adjustments, forKey: .adjustments)
            try c.encode(printScope, forKey: .printScope)
            try c.encode(exposureScope, forKey: .exposureScope)
            if !dated { try c.encode(dated, forKey: .dated) }
        }
    }

    /// Frame, or + Film: whether an edit of one frame also moves the film
    /// around it — the gap, the rebate, the edge print.
    enum Scope: String, Codable, CaseIterable, Identifiable, Sendable {
        case frame = "frame", film = "film"
        var id: String { rawValue }
        /// The switch's words: the desktop's *Applies to: Frame / + Film*.
        var label: String { self == .frame ? L("Frame", as: "one of a pair") : L("+ Film") }
    }

    /// The enlarger's four values that a frame may have for itself.
    struct PrintTrim: Codable, Equatable, Sendable {
        /// The keys as they are written: renaming a property must not move its key.
        enum CodingKeys: String, CodingKey {
            case brightnessStops = "brightnessStops", yFilterShift = "yFilterShift", mFilterShift = "mFilterShift",
                preflashExposure = "preflashExposure"
        }
        var brightnessStops = 0.0
        var yFilterShift = 0.0
        var mFilterShift = 0.0
        var preflashExposure = 0.0

        init() {}
        init(_ p: FilmParams) {
            brightnessStops = p.printBrightnessStops
            yFilterShift = p.yFilterShift
            mFilterShift = p.mFilterShift
            preflashExposure = p.preflashExposure
        }
        /// `p` printed with these values.
        func applied(to p: FilmParams) -> FilmParams {
            var p = p
            p.printBrightnessStops = brightnessStops
            p.yFilterShift = yFilterShift
            p.mFilterShift = mFilterShift
            p.preflashExposure = preflashExposure
            return p
        }
    }

    /// Where the picture sits under its hole. The hole never moves; the
    /// picture does. `scale` 1 fills the hole, and it never goes below that,
    /// so no base shows inside a filled hole.
    struct Placement: Codable, Equatable, Sendable {
        /// The keys as they are written: renaming a property must not move its key.
        enum CodingKeys: String, CodingKey { case scale = "scale", x = "x", y = "y", quarterTurns = "quarterTurns" }
        var scale = 1.0                 // 1…4
        var x = 0.0                     // −1…1 across the slack left by the fit
        var y = 0.0
        var quarterTurns = 0            // clockwise

        static let scaleRange = 1.0...4.0

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
            x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
            y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
            quarterTurns = try c.decodeIfPresent(Int.self, forKey: .quarterTurns) ?? 0
        }

        /// Held to what a hole can show: the desktop's `Session.setPlacement`.
        var held: Placement {
            var p = self
            p.scale = scale.clamped(to: Self.scaleRange)
            p.x = x.clamped(to: -1...1)
            p.y = y.clamped(to: -1...1)
            p.quarterTurns = ((quarterTurns % 4) + 4) % 4
            return p
        }
    }

    var schemaVersion = 1
    /// The folder whose filmstrip this pair belongs to (the desktop). Empty on the host.
    var folder: String
    var left: Hole?
    var right: Hole?
    /// The unexposed film between the holes, mm. The camera decides it on a
    /// real strip (one advance of 4 perforations leaves 1.00), so it is the
    /// user's only without Film Edge.
    var spacingMM = 1.0
    /// Whether the pair is laid out for the engine's strip (Film Edge on),
    /// mirrored from the pair's look so the layout needs only this file.
    var onStrip = false
    /// The camera turned for a landscape: the two frames are 24 × 18 and sit
    /// one above the other, the film running down the piece. Held level they
    /// are 18 × 24, side by side.
    var turned = false
    /// **The host's key**: the frame this pair began with, when it began with
    /// one — the Library's frame on top, the one frame picked in Select, a
    /// half frame from its Film Edge. That frame is what the pair is of, and
    /// stays in it (`mayChange`; the owner, 2026-10-09). Nil for a pair made
    /// of two picked frames, and in a pair the desktop wrote.
    var origin: UUID?

    static let spacingRange = 0.5...2.0
    static let holeMM = (along: 18.0, across: 24.0)
    /// The engine's own advance between a pair's two gates (`kPairAdvanceMM`,
    /// `overscan.cpp`): 4 perforations, which leaves the strip's 1.00 mm.
    static let stripAdvanceMM = 19.0
    /// A hole's exposure, in stops: the desktop's `Session.setHoleExposure`.
    static let exposureRange = -5.0...5.0

    init(folder: String = "") { self.folder = folder }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        left = try c.decodeIfPresent(Hole.self, forKey: .left)
        right = try c.decodeIfPresent(Hole.self, forKey: .right)
        spacingMM = try c.decodeIfPresent(Double.self, forKey: .spacingMM) ?? 1
        onStrip = try c.decodeIfPresent(Bool.self, forKey: .onStrip) ?? false
        turned = try c.decodeIfPresent(Bool.self, forKey: .turned) ?? false
        origin = try? c.decodeIfPresent(UUID.self, forKey: .origin)
    }

    enum Side: Int, CaseIterable, Codable, Sendable {
        case left = 0, right = 1
        var other: Side { self == .left ? .right : .left }
        /// The side as the `.spektrapair` file's `spektralab.frames` object names it
        /// (`MacPairRows.writeRecipe`): written out, so a renamed case cannot move the key.
        var key: String {
            switch self {
            case .left: "left"
            case .right: "right"
            }
        }
    }

    /// **The camera held the other way** (the Frame tab's *Level | Turned*),
    /// and each picture turned a quarter with it where it would otherwise lie
    /// across its hole. A tester, taken up by the owner on 2026-10-20: "两个横屏
    /// 照片拼半格的话，默认是上下放的。但如果手动切换到左右放，它只会强行裁切画面。
    /// 后续调整应该改为：切换横屏时，自动调转照片方向变成竖屏" — two landscape
    /// pictures switched to side by side were cut into upright strips; now each
    /// stands up in its upright hole, and the other way round the same.
    ///
    /// `pictures` are the frames as framed (`Hole.geometry` on the original),
    /// by side. A picture that already lies the way its new hole does, or is
    /// square, is left as it is. One that does not is turned a quarter
    /// **clockwise** — the way the placement's own turns count — or, if it
    /// stands a quarter turn off already, turned back, so Level → Turned →
    /// Level gives every picture back its own turn. Its place under the hole
    /// is centred again (the old one was across the other axis); its zoom is kept.
    mutating func holdCamera(turned: Bool, pictures: [Side: CGSize]) {
        guard turned != self.turned else { return }
        self.turned = turned
        for side in Side.allCases {
            guard var hole = self[side], let size = pictures[side], size.width != size.height else { continue }
            let seen = Self.turned(size, by: hole.placement)
            // Turned, a hole is 24 × 18: wide. Held level it is 18 × 24.
            guard (seen.width > seen.height) != turned else { continue }
            let q = ((hole.placement.quarterTurns % 4) + 4) % 4
            hole.placement.quarterTurns = q % 2 == 1 ? q - 1 : q + 1
            hole.placement.x = 0
            hole.placement.y = 0
            self[side] = hole
        }
    }

    subscript(side: Side) -> Hole? {
        get { side == .left ? left : right }
        set { if side == .left { left = newValue } else { right = newValue } }
    }

    /// Both holes hold a frame (answer B9: a pair with an empty hole is not
    /// exported). Whether each frame is still there is the library's to say.
    var isFilled: Bool { left != nil && right != nil }
    func isComplete(_ exists: (Hole) -> Bool) -> Bool {
        Side.allCases.allSatisfy { side in self[side].map(exists) ?? false }
    }

    /// The gap the layout uses: the camera's on a strip, the user's otherwise.
    var effectiveSpacingMM: Double { onStrip ? 1.0 : spacingMM.clamped(to: Self.spacingRange) }

    // MARK: - a pair entered with one frame (the host's own rule)

    /// The one frame a piece holds, when it holds exactly one: what a pair's
    /// page is **entered with** when it opens from a half frame's Film Edge,
    /// from Select with one frame picked, or on a pair kept with a hole still
    /// empty. Nil for a piece with both holes filled, or with neither — and
    /// for a hole whose frame is not the library's (a desktop pair's path).
    var soleFrame: UUID? {
        switch (left, right) {
        case (let hole?, nil): return hole.frame
        case (nil, let hole?): return hole.frame
        default: return nil
        }
    }

    /// Whether the frame in `side` may be **replaced or removed** on a page
    /// that was entered with `origin`.
    ///
    /// The owner, 2026-10-09: "the pair mode where you entered with one image,
    /// instead of pairing right from the frame, you should not be granted the
    /// ability to swap out the original image, only to exchange places." That
    /// frame is what the pair is of — its look, how the camera was held, its
    /// film edge are all read from it — so it keeps a hole for as long as the
    /// page is open: `swap` moves it, and Replace and Remove stand down on it.
    /// The rule follows the frame, not the hole it started in. A page entered
    /// with two frames, or with none, holds nothing (`origin` nil).
    func mayChange(_ side: Side, enteredWith origin: UUID?) -> Bool {
        guard let origin, self[side]?.frame == origin else { return true }
        // The same frame under both holes: either may go, the other still holds it.
        return self[side.other]?.frame == origin
    }

    /// The same, for the frame this pair began with (`origin`): since
    /// 2026-10-10 the pair is kept the moment it is made and worked on in its
    /// own darkroom, so the rule is the pair's for as long as it is a pair,
    /// not one page's.
    func mayChange(_ side: Side) -> Bool { mayChange(side, enteredWith: origin) }

    // MARK: - the layers

    /// What an edit is about, one at a time: the film, or one of its frames.
    /// The desktop's `PairLayer`.
    enum Layer: Int, CaseIterable, Identifiable, Sendable {
        case film, left, right
        var id: Int { rawValue }
        var side: Side? { self == .film ? nil : (self == .left ? .left : .right) }
        init(_ side: Side) { self = side == .left ? .left : .right }
    }

    /// "Film", "Left frame", "Right frame"; turned, "Top frame" and "Bottom
    /// frame": the desktop's own names (`PairSection.title`).
    func title(_ layer: Layer) -> String {
        switch layer {
        case .film: L("Film")
        case .left: turned ? L("Top frame") : L("Left frame")
        case .right: turned ? L("Bottom frame") : L("Right frame")
        }
    }

    // MARK: - layout

    /// The piece in pixels: two holes `hole` each, the second `advance` along
    /// the film — across the piece held level, down it when turned.
    struct Layout: Equatable, Sendable {
        let hole: CGSize
        let advance: Int
        var turned = false
        var size: CGSize {
            turned ? CGSize(width: hole.width, height: CGFloat(advance) + hole.height)
                   : CGSize(width: CGFloat(advance) + hole.width, height: hole.height)
        }
        /// Top-left origin. The first hole (`.left`) is the left one, or the
        /// upper one when turned.
        func rect(_ side: Side) -> CGRect {
            let d = side == .left ? 0 : CGFloat(advance)
            return CGRect(x: turned ? 0 : d, y: turned ? d : 0, width: hole.width, height: hole.height)
        }
        /// The hole's rectangle normalised to the piece, y down.
        func normalisedRect(_ side: Side) -> CGRect {
            let r = rect(side), s = size
            return CGRect(x: r.minX / s.width, y: r.minY / s.height, width: r.width / s.width, height: r.height / s.height)
        }
        /// A point on the piece, normalised 0…1 with y down: which hole, or
        /// nil in the gap.
        func side(atNormalised p: CGPoint) -> Side? {
            Side.allCases.first { normalisedRect($0).contains(p) }
        }
    }

    /// The layout for holes `across` pixels across the film (their height
    /// held level, their width when turned).
    static func layout(holeHeight across: Int, spacingMM: Double, turned: Bool = false) -> Layout {
        let a = max(across, 8)
        let along = max(Int((Double(a) * holeMM.along / holeMM.across).rounded()), 6)
        let advance = Int((Double(along) * (holeMM.along + spacingMM) / holeMM.along).rounded())
        return Layout(hole: turned ? CGSize(width: a, height: along) : CGSize(width: along, height: a),
                      advance: advance, turned: turned)
    }

    /// The hole's shape, width over height.
    var holeAspect: Double { turned ? Self.holeMM.across / Self.holeMM.along : Self.holeMM.along / Self.holeMM.across }

    /// The rectangle of `source` (already turned) that fills the hole at this
    /// placement, in source pixels, y down.
    static func sourceRect(for placement: Placement, source: CGSize,
                           aspect: Double = holeMM.along / holeMM.across) -> CGRect {
        guard source.width > 0, source.height > 0 else { return .zero }
        var w = source.width, h = source.height
        if w / h > aspect { w = h * aspect } else { h = w / aspect }
        let s = placement.scale.clamped(to: Placement.scaleRange)
        w /= s; h /= s
        let cx = source.width / 2 + placement.x.clamped(to: -1...1) * (source.width - w) / 2
        let cy = source.height / 2 + placement.y.clamped(to: -1...1) * (source.height - h) / 2
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// `source` after the placement's quarter turns.
    static func turned(_ source: CGSize, by placement: Placement) -> CGSize {
        placement.quarterTurns % 2 == 0 ? source : CGSize(width: source.height, height: source.width)
    }

    /// The piece's pixel layout (the desktop's `PairComposer.layout(for:sizes:)`).
    /// The holes are as large as the smaller of the two pictures is across
    /// its hole, so neither is enlarged — and the piece is never longer than
    /// the longer picture: two half frames are one frame's worth of film, and
    /// a pair of 45 MP frames laid out at their own size was an 83 MP piece.
    /// An empty pair takes a nominal size. `sizes` are the frames as framed
    /// (after their own crop and turn: `Hole.geometry.outputSize`).
    func pieceLayout(sizes: [Side: CGSize]) -> Layout {
        var across: [CGFloat] = [], longest: CGFloat = 0
        for side in Side.allCases {
            guard let hole = self[side], let size = sizes[side] else { continue }
            // At the picture's own fit, whatever it is zoomed to: a zoom must
            // not resize the piece.
            let turned = Self.turned(size, by: hole.placement)
            var fit = hole.placement
            fit.scale = 1
            let cut = Self.sourceRect(for: fit, source: turned, aspect: holeAspect)
            across.append(self.turned ? cut.width : cut.height)
            longest = max(longest, size.width, size.height)
        }
        var a = across.min() ?? 2400
        if longest > 0 {
            // At the camera's own 1 mm, whatever the spacing: a hole's size
            // must not move with the gap.
            let pieceLong = (Self.holeMM.along * 2 + 1) / Self.holeMM.across
            a = min(a, longest / pieceLong)
        }
        return Self.layout(holeHeight: Int(a.rounded(.down)), spacingMM: effectiveSpacingMM, turned: turned)
    }

    /// The layout for a decode of the piece (the desktop's `Session.pairLayout`).
    func layout(forPiece decoded: CGSize) -> Layout {
        Self.layout(holeHeight: Int(turned ? decoded.width : decoded.height), spacingMM: effectiveSpacingMM, turned: turned)
    }

    /// Where the holes are on the piece, normalised with y down, when the
    /// piece is the canvas (no film edge; on a strip they are the engine's
    /// gates). The desktop's `Session.pairHoleRects`.
    var holeRects: [Side: CGRect] {
        let l = Self.layout(holeHeight: 2400, spacingMM: effectiveSpacingMM, turned: turned)
        return Dictionary(uniqueKeysWithValues: Side.allCases.map { ($0, l.normalisedRect($0)) })
    }

    // MARK: - what the engine is told of the piece

    /// The piece along the film, in millimetres: two holes and the gap. 37 on
    /// a strip — the gate and one advance (`overscan_gate_long_mm`).
    var pieceLongMM: Double { Self.holeMM.along * 2 + effectiveSpacingMM }

    /// The piece as it lies, in millimetres: 37 × 24 held level, 24 × 37 turned.
    var pieceSizeMM: CGSize {
        turned ? CGSize(width: Self.holeMM.across, height: pieceLongMM) : CGSize(width: pieceLongMM, height: Self.holeMM.across)
    }

    /// `film_format_mm` for the piece when Film Format describes one frame
    /// `frameLongMM` long (a half frame's own 24): the desktop's
    /// `Session.derivedFilmFormatMM`. The engine is handed the whole piece,
    /// so its long edge is that many of the frame's.
    func filmFormatMM(frameLongMM: Double = 24) -> Double {
        (pieceLongMM * frameLongMM / Self.holeMM.across).clamped(to: 4...200)
    }

    /// `scene_latitude_split`: the middle of the gap along the piece's long
    /// edge, as a fraction of it — where the second frame's Scene Placement
    /// takes over (the desktop's `Session.resolved`).
    var split: Double {
        let l = Self.layout(holeHeight: 2400, spacingMM: effectiveSpacingMM, turned: turned)
        let a = l.normalisedRect(.left), b = l.normalisedRect(.right)
        return turned ? Double((a.maxY + b.minY) / 2) : Double((a.maxX + b.minX) / 2)
    }

    /// One frame of the piece as a Scene Latitude region: x0, y0, x1, y1,
    /// normalised to the piece (the desktop's `Session.pairFitRegion`).
    func fitRegion(_ side: Side) -> [Double] {
        let r = holeRects[side] ?? .zero
        return [Double(r.minX), Double(r.minY), Double(r.maxX), Double(r.maxY)]
    }

    /// Each filled hole's exposure on the strip, in stops: what the meter
    /// chose for that picture alone, plus the hole's own; with its meter off,
    /// the hole's own and nothing else. Nil for a side whose meter has not
    /// read yet. The gain on the picture is `gain(stops:)`.
    func stops(_ side: Side) -> Double? {
        guard let hole = self[side] else { return nil }
        guard hole.autoExposure else { return hole.exposureEV }
        return hole.meteredEV.map { $0 + hole.exposureEV }
    }

    /// 2^EV: the engine's own meter is exactly this gain on the frame it is
    /// handed (the desktop measured the two renders equal to the last code).
    static func gain(stops: Double) -> Double { pow(2.0, stops) }

    /// What the meter's reading was taken for: the frame, its decode, its own
    /// crop and the intent. A placement does not re-meter, so the picture
    /// does not pump while it is moved.
    static func meterKey(hole: Hole, method: String) -> String {
        let d = hole.decode
        let g = hole.geometry
        return [hole.frame?.uuidString ?? hole.path, d.whiteBalance.rawValue + d.exposureKey, String(d.temperature), String(d.tint),
                String(d.lensCorrection), method,
                "\(g.crop.x),\(g.crop.y),\(g.crop.width),\(g.crop.height),\(g.quarterTurns)"].joined(separator: "|")
    }

    // MARK: - edits of the piece (the desktop's `Session`, as pure functions)

    /// A hole's exposure set to `ev`. With its scope on + Film the film's
    /// print brightness moves by the same stops (answer B3), so the rebate
    /// follows the frame: `look` is the pair's own settings.
    ///
    /// Both frames are given a print of their own first, at what the film
    /// prints with now, so that neither rides along with the film: what moves
    /// is the film round them (the desktop's `Session.setHoleExposure`).
    mutating func exposure(_ ev: Double, of side: Side, look: inout FilmParams) {
        guard let hole = self[side] else { return }
        let now = ev.clamped(to: Self.exposureRange)
        if hole.exposureScope == .film, now != hole.exposureEV {
            pinPrints(to: PrintTrim(look))
            look.printBrightnessStops = (look.printBrightnessStops + (now - hole.exposureEV)).clamped(to: PrintTrim.range(.brightness))
        }
        self[side]?.exposureEV = now
    }

    /// The two frames change holes; each placement and exposure goes with its frame.
    mutating func swap() { let l = left; left = right; right = l }

    /// A frame put into a hole starts from the middle, on the frame's own
    /// decode and crop.
    mutating func fill(_ side: Side, with hole: Hole?) { self[side] = hole }

    // MARK: - a frame's own Scene Placement (the desktop's `Session`, as pure functions)
    //
    // The pair's look holds two placements (`FilmParams.sceneLatitude`, the one
    // the page shows, and `sceneLatitudeOther`) and a flag for which frame the
    // shown one is of. These keep the three in step with the piece.

    /// The frame the look's shown placement is of: the one Scene Placement and
    /// the Latitude card are about.
    static func placementSide(_ look: FilmParams) -> Side { look.placementIsRight ? .right : .left }

    /// Show `side`'s placement: the two trade places with the flag. Nothing on
    /// the wire moves (the desktop's `Session.pairLayerChanged`).
    static func show(placementOf side: Side, in look: inout FilmParams) {
        guard placementSide(look) != side else { return }
        let shown = look.sceneLatitude
        look.sceneLatitude = look.sceneLatitudeOther
        look.sceneLatitudeOther = shown
        look.placementIsRight = side == .right
    }

    /// The two frames change holes, and each placement goes with its frame
    /// (the desktop's `Session.swapHoles`): the shown one is still shown, of
    /// the frame that is now in the other hole.
    mutating func swap(look: inout FilmParams) {
        swap()
        look.placementIsRight.toggle()
        hold(&look)
    }

    /// A frame put into a hole, or taken out of it: that hole starts with no
    /// placement — the curve was fitted to the scene that was there (the
    /// desktop's `Session.resetPlacement`).
    mutating func fill(_ side: Side, with hole: Hole?, look: inout FilmParams) {
        self[side] = hole
        if Self.placementSide(look) == side { look.sceneLatitude = SceneLatitudeSettings() }
        else { look.sceneLatitudeOther = SceneLatitudeSettings() }
        hold(&look)
    }

    /// The look held to the piece: where the second frame begins, and the
    /// shown placement on a frame that is there while one is — an empty hole
    /// has no scene to place.
    func hold(_ look: inout FilmParams) {
        look.pairSplit = split
        let shown = Self.placementSide(look)
        if self[shown] == nil, self[shown.other] != nil { Self.show(placementOf: shown.other, in: &look) }
    }

    /// The frame Scene Placement is about, or nil on a piece with no frame.
    func placementSide(_ look: FilmParams) -> Side? {
        let shown = Self.placementSide(look)
        if self[shown] != nil { return shown }
        return self[shown.other] != nil ? shown.other : nil
    }

    /// The shot stays the frame's: its decode and its own crop are read again
    /// from the frame every time the pair is opened (the desktop's
    /// `Session.adoptPair`). True when either had moved — the hole's pixels
    /// are then other pixels, and its meter reads again (`meterKey`).
    @discardableResult
    mutating func mirror(_ side: Side, decode: DecodeSettings, geometry: Geometry) -> Bool {
        guard var hole = self[side], hole.decode != decode || hole.geometry != geometry else { return false }
        hole.decode = decode
        hole.geometry = geometry
        self[side] = hole
        return true
    }

    /// `origin` after the picture is dragged by `d` — a fraction of the hole,
    /// x right and y down. The picture follows the finger, so the rectangle
    /// cut from the source moves the other way.
    static func placement(_ origin: Placement, draggedBy d: CGSize, source: CGSize, aspect: Double = 0.75) -> Placement {
        let turned = turned(source, by: origin)
        let cut = sourceRect(for: origin, source: turned, aspect: aspect)
        var p = origin
        let slackX = (turned.width - cut.width) / 2, slackY = (turned.height - cut.height) / 2
        if slackX > 0.5 { p.x = (origin.x - Double(d.width * cut.width / slackX)).clamped(to: -1...1) }
        if slackY > 0.5 { p.y = (origin.y - Double(d.height * cut.height / slackY)).clamped(to: -1...1) }
        return p
    }

    /// `origin` zoomed by `factor` about `anchor` — a point of the hole, 0…1
    /// each way, y down. What is under the anchor stays under it for as long
    /// as the picture still covers the hole; at the picture's edge the edge wins.
    static func placement(_ origin: Placement, zoomedBy factor: Double, about anchor: CGPoint, source: CGSize,
                          aspect: Double = 0.75) -> Placement {
        let turned = turned(source, by: origin)
        let was = sourceRect(for: origin, source: turned, aspect: aspect)
        var p = origin
        let from = origin.scale.clamped(to: Placement.scaleRange)
        p.scale = (from * factor).clamped(to: Placement.scaleRange)
        guard p.scale != from, was.width > 0, was.height > 0 else { return origin }
        let w = was.width * from / p.scale, h = was.height * from / p.scale
        // The source point under the anchor, and the cut that keeps it there.
        let cx = was.minX + anchor.x * was.width - anchor.x * w + w / 2
        let cy = was.minY + anchor.y * was.height - anchor.y * h + h / 2
        let slackX = (turned.width - w) / 2, slackY = (turned.height - h) / 2
        p.x = slackX > 0.5 ? Double((cx - turned.width / 2) / slackX).clamped(to: -1...1) : 0
        p.y = slackY > 0.5 ? Double((cy - turned.height / 2) / slackY).clamped(to: -1...1) : 0
        return p
    }

    /// A frame's crop as a placement under a hole of `aspect`: the same
    /// rectangle where the crop is level and unflipped, the middle otherwise.
    /// How a half frame enters a pair from its Film Edge framing.
    static func placement(from g: Geometry, source: CGSize, aspect: Double) -> Placement {
        var p = Placement()
        guard source.width > 0, source.height > 0, g.quarterTurns % 4 == 0, !g.flipH, !g.flipV,
              abs(g.angle) < 0.01, !g.crop.isFull else {
            p.quarterTurns = ((g.quarterTurns % 4) + 4) % 4
            return p
        }
        let fit = sourceRect(for: p, source: source, aspect: aspect)
        let ch = g.crop.height * source.height
        p.scale = (fit.height / max(ch, 1)).clamped(to: Placement.scaleRange)
        let cut = sourceRect(for: p, source: source, aspect: aspect)
        let cx = (g.crop.x + g.crop.width / 2) * source.width, cy = (g.crop.y + g.crop.height / 2) * source.height
        let slackX = (source.width - cut.width) / 2, slackY = (source.height - cut.height) / 2
        if slackX > 0.5 { p.x = Double((cx - source.width / 2) / slackX).clamped(to: -1...1) }
        if slackY > 0.5 { p.y = Double((cy - source.height / 2) / slackY).clamped(to: -1...1) }
        return p
    }

    // MARK: - the pair's look

    /// The settings a new pair develops with: its first frame's, with the
    /// meter off (each hole is metered alone and the strip develops with the
    /// gains in its pixels), no exposure of the piece's own, Film Format one
    /// half frame (24 on its long side), and no second date yet. The desktop's
    /// `Session.makePair`. **The film is loaded, not copied**: a slide is
    /// scanned and never printed, whatever the first frame's edit said, and
    /// the pair has the one paper its film prints on (answer B6).
    static func look(from first: FrameEdit, keepFilmEdge: Bool = false, catalog: StockCatalog = .shared) -> FrameEdit {
        var e = first
        e.params.load(film: first.params.filmStock, catalog: catalog, recommendingPaper: false)
        e.params.autoExposure = false
        e.params.exposureCompensationEV = 0
        e.params.filmFrame = FilmFrame.custom.id
        e.params.filmSide = FilmSide.long.rawValue
        e.params.sideLengthMM = holeMM.across
        e.params.filmFormatMM = HalfFramePair().filmFormatMM()
        e.geometry = .default
        e.solvedEV = nil
        if keepFilmEdge {
            e.filmEdge.format = .half
            e.filmEdge.framing = nil
        } else {
            e.filmEdge = FilmEdgeSettings()
        }
        return e
    }

    /// The host's meter gate for a newly kept pair. Each hole decides whether
    /// it needs normalization; the composed engine source is still AE-off.
    /// Existing pairs bypass this initialization and keep their saved look.
    func startingLook(_ look: FrameEdit) -> FrameEdit {
        var fresh = look
        fresh.params.autoExposure = Side.allCases.contains { self[$0]?.autoExposure == true }
        fresh.params.exposureCompensationEV = 0
        return fresh
    }

    /// The piece's own size in a look's fields, as `look(from:)` gives a new
    /// pair's: one half frame, 24 on its long side, and the piece's long edge
    /// for the wire. Not a develop setting: a pair's ↺ puts it back.
    func size(_ params: inout FilmParams) {
        params.filmFrame = FilmFrame.custom.id
        params.filmSide = FilmSide.long.rawValue
        params.sideLengthMM = Self.holeMM.across
        params.filmFormatMM = filmFormatMM()
    }

    /// A film loaded on the pair: both holes develop on it. A slide is scanned.
    static func load(film id: String, into look: inout FrameEdit, catalog: StockCatalog = .shared) {
        look.params.load(film: id, catalog: catalog)
    }

    // MARK: - the file

    static func isPair(_ url: URL) -> Bool { url.pathExtension == fileExtension }

    static func load(_ url: URL) -> HalfFramePair? {
        guard isPair(url), let data = try? Data(contentsOf: url) else { return nil }
        return decoded(data)
    }

    static func decoded(_ data: Data) -> HalfFramePair? {
        try? JSONDecoder().decode(HalfFramePair.self, from: data)
    }

    /// The file's bytes, as the desktop writes them: pretty, keys sorted.
    func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url, options: .atomic)
    }

    /// The pairs kept in `directory`, with their files, in name order.
    static func pairs(in directory: URL) -> [(url: URL, pair: HalfFramePair)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter(isPair)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { url in load(url).map { (url, $0) } }
    }

    /// A file for a new pair in `directory`: "Half-Frame Pair 3.spektrapair",
    /// the first number no pair there has.
    static func newURL(in directory: URL) -> URL {
        var n = 1
        while true {
            let url = directory.appendingPathComponent("Half-Frame Pair \(n).\(fileExtension)")
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }
}

// MARK: - the date back on a pair

extension DateBackSettings {
    /// The date rows for a half-frame pair's piece: **each frame its own date,
    /// and only a frame that is there.**
    ///
    /// `first` and `second` are the two frames' texts as the back prints them
    /// (`FilmEdgeResolver.dateText`: the date, the data line, or words typed
    /// by hand), and "" for an empty hole — an empty hole was never exposed,
    /// so nothing is printed in it, typed words included. The back is on when
    /// either frame has a text. `filmEdge` is the pair's, as the piece wears
    /// it (`HalfFramePair.onStrip`).
    ///
    /// `wire(text:filmEdge:)` takes one text and is off without it. Written
    /// through it with the first frame's text alone, a pair whose first hole
    /// was empty had no date at all — its second frame's went with it
    /// (`tools/pair_check.sh`, 2026-10-09: taken out of the first hole, or
    /// swapped into the second, a frame lost its date).
    func pairRows(first: String, second: String, filmEdge: FilmEdgeSettings) -> [(name: String, value: ParamValue, layer: ParamLayer)] {
        let off: [(name: String, value: ParamValue, layer: ParamLayer)] = [("date_imprint_active", .bool(false), .shoot)]
        guard !first.isEmpty || !second.isEmpty else { return off }
        var rows = wire(text: first.isEmpty ? second : first, filmEdge: filmEdge)
        guard rows.contains(where: { $0.name == "date_imprint_active" && $0.value == .bool(true) }) else { return off }
        rows.removeAll { ["overscan_format", "date_imprint_size", "date_imprint_text"].contains($0.name) }
        rows += [
            // Without a film edge the engine is told here that the frame is a pair.
            ("overscan_format", .string(FilmEdgeFormat.half.rawValue), .shoot),
            ("overscan_pair", .bool(true), .shoot),
            ("date_imprint_size", .double(wireSize(on: .half)), .shoot),
            ("date_imprint_text", .string(first), .shoot),
            ("date_imprint_text_b", .string(second), .shoot),
        ]
        return rows
    }
}

// MARK: - a frame's own print

/// The enlarger's four values, by name: what a frame of a pair may have for
/// itself (the desktop's `EnlargerField`).
enum PrintField: String, CaseIterable, Sendable {
    case brightness, yellow, magenta, preflash
}

extension HalfFramePair.PrintTrim {
    subscript(field: PrintField) -> Double {
        get {
            switch field {
            case .brightness: brightnessStops
            case .yellow: yFilterShift
            case .magenta: mFilterShift
            case .preflash: preflashExposure
            }
        }
        set {
            switch field {
            case .brightness: brightnessStops = newValue
            case .yellow: yFilterShift = newValue
            case .magenta: mFilterShift = newValue
            case .preflash: preflashExposure = newValue
            }
        }
    }

    /// What the enlarger takes of each: the desktop's `Session.clamped`.
    static func range(_ field: PrintField) -> ClosedRange<Double> {
        switch field {
        case .brightness: -3...3
        case .yellow, .magenta: -1...1
        case .preflash: 0...0.03
        }
    }
}

extension HalfFramePair {
    /// Every frame that prints as the film does is given `film` as a print of
    /// its own, so an edit of the film's print — or of the other frame's —
    /// does not carry it along.
    mutating func pinPrints(to film: PrintTrim) {
        for side in Side.allCases where self[side] != nil && self[side]?.print == nil { self[side]?.print = film }
    }

    /// The frame `layer` is, when it is one that is there.
    func pickedSide(_ layer: Layer) -> Side? { layer.side.flatMap { self[$0] == nil ? nil : $0 } }

    /// What the Print tab shows on `layer`: the picked frame's own print, or
    /// the film's — with the film picked, on an empty hole, and for a frame
    /// that prints as the film does (the desktop's `Session.enlargerValue`).
    func trim(on layer: Layer, look: FilmParams) -> PrintTrim {
        pickedSide(layer).flatMap { self[$0]?.print } ?? PrintTrim(look)
    }

    /// An edit of the enlarger on `layer` (the desktop's `Session.setEnlarger`).
    ///
    /// **On a frame** it is that frame's print. With its scope on *+ Film* the
    /// film's print moves by the same amount (answer B3), so the frame and the
    /// film round it stay as far apart as they were; on *Frame* the film stays.
    /// Either way the other frame is given a print of its own first and does
    /// not move.
    ///
    /// **On the film** it is the whole piece: the film's print moves, and a
    /// frame with a print of its own moves with it by the same amount and
    /// keeps its distance — with the film picked the enlarger otherwise moved
    /// only the film between the frames, and looked as if it did nothing.
    mutating func print(_ field: PrintField, _ value: Double, on layer: Layer, look: inout FilmParams) {
        let range = PrintTrim.range(field)
        let v = value.clamped(to: range)
        var film = PrintTrim(look)
        guard let side = pickedSide(layer) else {
            let moved = v - film[field]
            guard moved != 0 else { return }
            for s in Side.allCases {
                guard var own = self[s]?.print else { continue }
                own[field] = (own[field] + moved).clamped(to: range)
                self[s]?.print = own
            }
            film[field] = v
            look = film.applied(to: look)
            return
        }
        let was = trim(on: layer, look: look)[field]
        guard v != was else { return }
        pinPrints(to: film)
        self[side]?.print?[field] = v
        if self[side]?.printScope == .film {
            film[field] = (film[field] + (v - was)).clamped(to: range)
            look = film.applied(to: look)
        }
    }

    /// Back to a plain print (the desktop's `Session.resetEnlarger`): a frame's
    /// own to neutral, the other keeping what it had; the film's to neutral
    /// with every frame printing as the film again — one print.
    mutating func resetPrint(on layer: Layer, look: inout FilmParams) {
        if let side = pickedSide(layer) {
            pinPrints(to: PrintTrim(look))
            self[side]?.print = PrintTrim()
        } else {
            for s in Side.allCases { self[s]?.print = nil }
            look = PrintTrim().applied(to: look)
        }
    }

    /// Whether any frame prints differently from the film. When none does the
    /// piece is one print, made as a frame's is (the desktop's `pairIsLayered`).
    func isLayered(look: FilmParams) -> Bool {
        let film = PrintTrim(look)
        return Side.allCases.contains { self[$0]?.print.map { $0 != film } ?? false }
    }
}

// MARK: - what a change of the piece asks of the engine

extension HalfFramePair {
    /// What an edit of the piece changes of its develop, apart from the look:
    /// its pixels (another frame, a picture moved, an exposure, the layout —
    /// the piece is composed again), what the film is told of it (a frame's
    /// date), or a frame's own print alone (a reprint of the same negative).
    enum Change: Sendable { case pixels, film, print }

    /// What a guide of the piece is drawn from (`PairGuide`): which frames,
    /// how each is cut and where it sits under its hole, and how the piece
    /// lies. Not a frame's exposure, its print or its date: a guide shows none.
    ///
    /// **Nor a frame's decode** — its white balance, its lens correction. A
    /// guide is the files' own previews, before any decode (`PairGuide.preview`,
    /// `PairOriginalPreview`), and `AppServices.changePair` writes it again on the
    /// main thread, from each frame's file, whenever this key moves. v0.1 had
    /// the decode here: every tick of a pair's Temperature or Tint ruler read
    /// both files again — a RAW through ImageIO's decoder — and the page held
    /// until the operating system's watchdog ended the app (a tester's reference device, a pair of
    /// two RAWs, 2026-10-15: 0x8BADF00D, the main thread in `PairGuide.preview`
    /// under `ScenePanel.change`). The decode still moves the piece's pixels
    /// (`changes(from:)`): the engine composes it again when the finger rests.
    var guideKey: String {
        var parts = ["\(turned)", "\(effectiveSpacingMM)"]
        for side in Side.allCases {
            guard let h = self[side] else { parts.append("-"); continue }
            let p = h.placement.held, g = h.geometry
            parts.append([h.frame?.uuidString ?? h.path, "\(p.scale)", "\(p.x)", "\(p.y)", "\(p.quarterTurns)",
                          "\(g.crop.x),\(g.crop.y),\(g.crop.width),\(g.crop.height),\(g.angle),\(g.quarterTurns),\(g.flipH),\(g.flipV)"].joined(separator: "|"))
        }
        return parts.joined(separator: ";")
    }

    /// A meter's reading kept in the pair is not a change: the develop that
    /// read it is already of it.
    func changes(from old: HalfFramePair) -> Set<Change> {
        var out: Set<Change> = []
        if turned != old.turned || onStrip != old.onStrip || effectiveSpacingMM != old.effectiveSpacingMM { out.insert(.pixels) }
        for side in Side.allCases {
            switch (old[side], self[side]) {
            case (nil, nil): break
            case (let a?, let b?):
                if a.frame != b.frame || a.path != b.path || a.placement != b.placement || a.exposureEV != b.exposureEV
                    || a.autoExposure != b.autoExposure || a.meterMethod != b.meterMethod || a.decode != b.decode
                    || a.geometry != b.geometry { out.insert(.pixels) }
                if a.dated != b.dated { out.insert(.film) }
                if a.print != b.print { out.insert(.print) }
            default: out.insert(.pixels)
            }
        }
        return out
    }
}

// MARK: - the back, a frame at a time

extension HalfFramePair {
    /// Whether the back prints on `side`: the pair's back on, a frame there,
    /// and that frame's own switch.
    func prints(_ side: Side, back: DateBackSettings) -> Bool {
        back.active && self[side]?.dated == true
    }

    /// A frame's own switch (the owner, 2026-10-10). Switched on while the
    /// back is off, the back comes on **for this frame alone**: the other was
    /// not asked. Switched off on the last frame that printed, the back is off.
    mutating func setDated(_ on: Bool, _ side: Side, back: inout DateBackSettings) {
        guard self[side] != nil else { return }
        if on {
            if !back.active {
                back.active = true
                back.placement = .frame
                // The data face prints between frames: without a strip there is nowhere for it.
                if back.style == .data, !onStrip { back.style = .lcd }
                self[side.other]?.dated = false
            }
            self[side]?.dated = true
        } else {
            self[side]?.dated = false
            if !Side.allCases.contains(where: { self[$0]?.dated == true }) { back.active = false }
        }
    }

    /// The back itself, from the film: a face, or off (nil). One back prints
    /// both frames with one face. Coming on, it prints on the frames that were
    /// left switched on — and on both where neither was, since a back that is
    /// on and prints nowhere is off. A date is printed in the frame; the data
    /// face prints between frames whatever that says.
    mutating func setBack(_ face: DateBackFace?, back: inout DateBackSettings) {
        guard let face else { back.active = false; return }
        if !Side.allCases.contains(where: { self[$0]?.dated == true }) {
            for side in Side.allCases { self[side]?.dated = true }
        }
        back.active = true
        back.style = face
        back.placement = .frame
    }

    /// "LCD · both frames", "Dots · left frame", "Off": the film's row for its back.
    func backSummary(_ back: DateBackSettings, separator: String = " · ") -> String {
        let on = Side.allCases.filter { prints($0, back: back) }
        guard let first = on.first else { return L("Off") }
        let where_ = on.count == 2 ? L("both frames") : title(.init(first)).lowercased()
        return back.style.label + separator + where_
    }
}

/// A JSON value kept as it was read: what the host carries of a pair's file
/// and has no type for (`Hole.adjustments`).
enum PairJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PairJSON])
    case object([String: PairJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([PairJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: PairJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
