//  HalfFramePair.swift — two neighbouring half frames on one piece of film.
//
//  The design is `modern_UI/design-proposals/half-frame-pair-2026-10-02`, with
//  the owner's answers in `PRD/QUESTIONS-2026-10-02-…` part B. What this file
//  holds is the *piece*: which frame sits in which hole, where each picture
//  sits under its hole, and how far apart the holes are. The look — stock,
//  paper, enlarger, effects, Film Edge — is the pair's own `Sidecar`, stored
//  for the pair's file exactly as a frame's is.
//
//  A pair is a file (`….spektrapair`, JSON) and that file's URL is the pair's
//  identity everywhere a frame's URL is one: the filmstrip, the selection, the
//  texture store, the caches. Its "decode" is the two pictures laid on 37 mm
//  of film (`PairComposer`), so the engine, the canvas and the export take it
//  as they take any frame. Every write to the file moves its modification
//  date, which is what the disk caches key on.

import CoreGraphics
import Foundation

struct HalfFramePair: Codable, Equatable, Sendable {
    nonisolated static let fileExtension = "spektrapair"

    /// One hole of the gate, 18 × 24 mm, and the frame in it.
    struct Hole: Codable, Equatable, Sendable {
        /// The frame's file. A pair references frames; it does not consume
        /// them (answer B7: a frame may be in several pairs).
        var path: String
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
        /// The frame's own decode (white balance, lens correction), read from
        /// its sidecar when the pair is opened: the shot stays the frame's.
        var decode = DecodeSettings()
        /// This frame's own print: the enlarger's brightness, filters and
        /// pre-flash. Nil until a frame is given one; it then prints as the
        /// film does (the pair's own settings).
        var print: PrintTrim?
        /// This frame's own Post-Dev grade; nil follows the film's.
        var adjustments: Adjustments?
        /// Where an edit of this frame lands (answers B1–B3): on the frame
        /// only, or on the frame and the film around it by the same amount.
        /// The enlarger starts on the film as well, exposure on the frame.
        var printScope = Scope.film
        var exposureScope = Scope.frame

        var url: URL { URL(fileURLWithPath: path) }
        var exists: Bool { FileManager.default.fileExists(atPath: path) }

        init(url: URL) { path = url.standardizedFileURL.path }

        /// Every key but the path optional, so a file from before a field
        /// existed still opens.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            placement = try c.decodeIfPresent(Placement.self, forKey: .placement) ?? Placement()
            exposureEV = try c.decodeIfPresent(Double.self, forKey: .exposureEV) ?? 0
            meteredEV = try c.decodeIfPresent(Double.self, forKey: .meteredEV)
            meteredFor = try c.decodeIfPresent(String.self, forKey: .meteredFor)
            decode = try c.decodeIfPresent(DecodeSettings.self, forKey: .decode) ?? DecodeSettings()
            print = try c.decodeIfPresent(PrintTrim.self, forKey: .print)
            adjustments = try c.decodeIfPresent(Adjustments.self, forKey: .adjustments)
            printScope = (try? c.decodeIfPresent(Scope.self, forKey: .printScope)) ?? .film
            exposureScope = (try? c.decodeIfPresent(Scope.self, forKey: .exposureScope)) ?? .frame
        }
    }

    /// Frame, or + Film: whether an edit of one frame also moves the film
    /// around it — the gap, the rebate, the edge print.
    enum Scope: String, Codable, CaseIterable, Identifiable, Sendable {
        case frame, film
        var id: String { rawValue }
    }

    /// The enlarger's four values that a frame may have for itself.
    struct PrintTrim: Codable, Equatable, Sendable {
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
    }

    var schemaVersion = 1
    /// The folder whose filmstrip this pair belongs to.
    var folder: String
    var left: Hole?
    var right: Hole?
    /// The unexposed film between the holes, mm. The camera decides it on a
    /// real strip (one advance of 4 perforations leaves 1.00), so it is the
    /// user's only without Film Edge.
    var spacingMM = 1.0
    /// Whether the pair is laid out for the engine's strip (Film Edge on),
    /// mirrored from the pair's sidecar so the composer needs only this file.
    var onStrip = false
    /// The camera turned for a landscape: the two frames are 24 × 18 and sit
    /// one above the other, the film running down the piece. Held level they
    /// are 18 × 24, side by side.
    var turned = false

    static let spacingRange = 0.5...2.0
    nonisolated static let holeMM = (along: 18.0, across: 24.0)

    init(folder: String) { self.folder = folder }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        folder = try c.decode(String.self, forKey: .folder)
        left = try c.decodeIfPresent(Hole.self, forKey: .left)
        right = try c.decodeIfPresent(Hole.self, forKey: .right)
        spacingMM = try c.decodeIfPresent(Double.self, forKey: .spacingMM) ?? 1
        onStrip = try c.decodeIfPresent(Bool.self, forKey: .onStrip) ?? false
        turned = try c.decodeIfPresent(Bool.self, forKey: .turned) ?? false
    }

    enum Side: Int, CaseIterable, Sendable { case left, right }

    subscript(side: Side) -> Hole? {
        get { side == .left ? left : right }
        set { if side == .left { left = newValue } else { right = newValue } }
    }

    /// Both holes hold a frame that is still on disk (answer B9: a pair with
    /// an empty hole is not exported).
    var isComplete: Bool { Side.allCases.allSatisfy { self[$0]?.exists == true } }

    /// The gap the layout uses: the camera's on a strip, the user's otherwise.
    var effectiveSpacingMM: Double { onStrip ? 1.0 : spacingMM.clamped(to: Self.spacingRange) }

    // MARK: - layout

    /// The piece in pixels: two holes `hole` each, the second `advance` along
    /// the film -- across the piece held level, down it when turned.
    struct Layout: Equatable, Sendable {
        let hole: CGSize
        let advance: Int
        var turned = false
        var size: CGSize {
            turned ? CGSize(width: hole.width, height: CGFloat(advance) + hole.height)
                   : CGSize(width: CGFloat(advance) + hole.width, height: hole.height)
        }
        /// Top-left origin, as the canvas and the rails count. The first hole
        /// (`.left`) is the left one, or the upper one when turned.
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
    nonisolated static func layout(holeHeight across: Int, spacingMM: Double, turned: Bool = false) -> Layout {
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
    nonisolated static func sourceRect(for placement: Placement, source: CGSize,
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
    nonisolated static func turned(_ source: CGSize, by placement: Placement) -> CGSize {
        placement.quarterTurns % 2 == 0 ? source : CGSize(width: source.height, height: source.width)
    }

    // MARK: - the store

    /// Next to the sidecars, so a test's redirected store carries it along.
    nonisolated static var storeDirectory: URL { Sidecar.storeDirectory.appending(path: "Pairs") }

    nonisolated static func isPair(_ url: URL) -> Bool { url.pathExtension == fileExtension }

    nonisolated static func load(_ url: URL) -> HalfFramePair? {
        guard isPair(url), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HalfFramePair.self, from: data)
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    /// The pairs that belong to `folder`, with their files, in name order.
    nonisolated static func pairs(in folder: URL) -> [(url: URL, pair: HalfFramePair)] {
        let wanted = folder.standardizedFileURL.path
        let files = (try? FileManager.default.contentsOfDirectory(at: storeDirectory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        return files.filter(isPair)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { url in load(url).flatMap { $0.folder == wanted ? (url, $0) : nil } }
    }

    /// A file for a new pair in `folder`: "Half-Frame Pair 3.spektrapair",
    /// the first number no pair of that folder has.
    nonisolated static func newURL(in folder: URL) -> URL {
        let tag = String(format: "%06x", abs(folder.standardizedFileURL.path.hashValueStable) % 0xFFFFFF)
        var n = 1
        while true {
            let url = storeDirectory.appending(path: "Half-Frame Pair \(n) \(tag).\(fileExtension)")
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    /// What the meter's reading was taken for: the frame, its decode and the
    /// metering intent. A placement does not re-meter, so the picture does
    /// not pump while it is moved.
    nonisolated static func meterKey(hole: Hole, method: String) -> String {
        let d = hole.decode
        return [hole.path, d.whiteBalance.rawValue, String(d.temperature), String(d.tint),
                String(d.lensCorrection), method].joined(separator: "|")
    }
}

private extension String {
    /// A hash that is the same in every process (`hashValue` is seeded).
    var hashValueStable: Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int(truncatingIfNeeded: h & 0x7FFF_FFFF)
    }
}
