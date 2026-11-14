//  PieceComposer.swift — a piece of film the host lays out: a half-frame pair's two pictures.
//
//  The engine develops one frame. A half-frame pair is two pictures on 37 mm
//  of film, so the host makes the frame: each picture under its 18 × 24 hole,
//  and the film between them black — no light reached it, and the engine
//  develops it to the stock's own base (the desktop's `Import/PairComposer`).
//  On a strip (`overscan_pair`) the engine takes that frame as the gate and
//  one advance, and draws the film round both.
//
//  **Each picture is the frame as its owner left it** — its own decode, and
//  its own crop, turn and flips, cut as a film edge's framing is cut
//  (`HostCut`) — and is then moved under its hole: turned by the placement's
//  quarter turns, and the placement's window of it scaled into the hole
//  (`PiecePlacer.place`, the desktop's `PairComposer.place`). The window is
//  the model's own (`HalfFramePair.sourceRect`), handed over as a fraction of
//  the picture, so nothing here knows what a pair is.
//
//  **Each picture is exposed by itself** (`PieceAsk.Exposure`). One enlarger
//  prints both holes and one meter would read the piece as one scene — the
//  gap included — so the strip is developed with the meter off, and each
//  picture carries its own exposure as a plain gain in its pixels: 2^stops,
//  which is exactly what the engine's meter does to a frame it is handed (the
//  desktop measured the two renders equal to the last code). The stops are
//  what the engine's meter chose for that picture alone, read once and kept
//  in the pair, plus the hole's own.
//
//  What is asked is plain values, made on the main actor
//  (`HalfFramePair.piece`): the composing itself is `FrameDecoder`'s, on the
//  engine's queue, one picture at a time.
//
//  The placing itself is `PiecePlacer`, in a file of its own that
//  `tools/selftest.sh` holds against the pair's own arithmetic on a Mac.
//
//  **A double exposure is the same piece with one difference** (RFC-048 §1,
//  §2): its pictures are **added** into the whole buffer (`Lay.add`) instead
//  of each being **placed** into its own hole (`Lay.place`, the pair's). Both
//  of a double's pictures cover the whole frame, so each one's "hole" is the
//  whole piece, and the light of the two is summed in scene-linear ProPhoto —
//  the decoder's own space, where the sum is physically a double exposure —
//  before the engine sees one frame. The adding itself is `PieceAdder`
//  (Mac-checked, `tools/piece_selftest.swift`); the double's ask is made in
//  `DoubleDevelop.swift`. **Nothing of a pair's ask moves**: the new fields
//  default to the pair's way, and `key` gains a word only where one of them is
//  not the default, so every pair's key, stamp and kept develop is byte for
//  byte what it was.

import CoreGraphics
import Foundation

/// A piece of film for the host to lay out, and how each picture on it is exposed.
struct PieceAsk: Equatable, Sendable {
    /// How a picture is laid on the piece (RFC-048 §2).
    enum Lay: Equatable, Sendable {
        /// The pair's: the picture's pixels are written into its hole, and the
        /// rest of the piece stays as it is (black between the holes).
        case place
        /// A double exposure's: the picture is rendered band by band into a
        /// scratch band and its light **added** into the piece, its gain on
        /// the three colour channels only (`PieceAdder`). The order of laying
        /// does not change the sum, byte for byte.
        case add
    }

    /// How a picture is exposed on the film.
    enum Exposure: Equatable, Sendable {
        /// Its meter off: a plain gain of the hole's own stops, and nothing else.
        case own(Double)
        /// The engine's meter reads this picture alone, and the hole's own
        /// stops are added. `reading` is what the meter chose before, kept in
        /// the pair for `key` (`HalfFramePair.meterKey`: the frame, its decode,
        /// its own crop and the intent — not where it sits under its hole, so
        /// a picture does not pump while it is moved); nil reads it now.
        case metered(reading: Double?, plus: Double, key: String)

        /// What of this changes the picture's pixels, as a word. Not the
        /// reading: it is the same number before and after it is known.
        var word: String {
            switch self {
            case .own(let stops): "own \(stops)"
            case .metered(_, let plus, let key): "meter[\(key)]+\(plus)"
            }
        }
    }

    struct Picture: Equatable, Sendable {
        /// 0 for the first hole (the left one, or the upper), 1 for the second.
        var index: Int
        var url: URL
        var isRAW: Bool
        var settings: DecodeSettings
        /// The decode's long edge at most; nil is the file's own size. Made
        /// so the window comes out at the hole's size or a little over
        /// (`longEdge(original:framed:window:hole:)`): a picture is never
        /// decoded larger than its hole shows.
        var longEdge: Int?
        /// The frame's own cut: its crop, straighten, turns and flips.
        var cut: Geometry
        /// The placement's quarter turns of the cut picture, clockwise.
        var quarterTurns: Int
        /// The part of the cut, turned picture the hole shows: fractions of
        /// it, with a top-left origin.
        var window: CGRect
        /// The hole on the piece, in the piece's pixels, with a top-left origin.
        var hole: CGRect
        var exposure: Exposure
        /// The wire the engine's meter is opened with for this picture alone:
        /// the piece's look with the meter on and its intent, no exposure of
        /// its own, no film edge and no date, on one half frame of film.
        var meterWire: [String: ParamValue]
        /// Placed (the pair's) or added (a double exposure's).
        var lay: Lay = .place
        /// A horizontal mirror of the cut, turned picture, **after the quarter
        /// turns and before the window** (`PiecePlacer.place`), so the window's
        /// fractions mean the same with or without it (RFC-048 §2). A double
        /// exposure's `Placement.flipped`; never a pair's.
        var flipped = false
        /// Quarter turns, clockwise, of the placed picture **after** the window
        /// is scaled to its hole: a double exposure's frame turned back for a
        /// film edge turned half round, whose canvas the host turns forward
        /// again (`EngineHost.Request.turnsAfter`), as a photograph's is
        /// (`FrameEdit.hostCut`, `hostTurns`). The hole is then the turned
        /// frame's. Never a pair's, whose film is not turned (`PairDevelop.swift`).
        var turnedAfter = 0
        /// 镜头校正 as this picture's key names it, taken once (`resolvingLens`): its decode is made with it. Nil asks the
        /// resolver wherever the key or the decode is made.
        var lens: LensResolution? = nil
    }

    /// The piece, in pixels.
    var size: PixelSize
    var pictures: [Picture]

    /// The piece with each RAW picture's lens correction taken now (`LensResolver.current`): what a develop's request
    /// carries, so its key and its decodes name the same corrector whatever settles between them.
    func resolvingLens() -> PieceAsk {
        var p = self
        for i in p.pictures.indices where p.pictures[i].isRAW && p.pictures[i].lens == nil {
            p.pictures[i].lens = LensResolver.current(p.pictures[i].url, decode: p.pictures[i].settings)
        }
        return p
    }

    /// What the piece's pixels are made of, as a word: for telling one source
    /// from another (`EngineHost.Request.sourceKey`) and for a develop's stamp.
    var key: String {
        var words = ["piece \(size.width)x\(size.height)"]
        for p in pictures {
            let decode: String = p.isRAW ? "raw " + p.settings.pixelsKey(source: p.url, lens: p.lens) : ""
            let edge: String = p.longEdge.map { "\($0)" } ?? "whole"
            let turns: String = "turned \(((p.quarterTurns % 4) + 4) % 4)"
            let window: String = "\(p.window.minX),\(p.window.minY),\(p.window.width),\(p.window.height)"
            let hole: String = "\(Int(p.hole.minX)),\(Int(p.hole.minY)),\(Int(p.hole.width)),\(Int(p.hole.height))"
            // The file by its place under the app's own folder, not by the whole path: that folder moves
            // with an install of the app, and a stamp that moved with it had every pair developed again.
            var parts: [String] = [String(p.index), ImportService.stampWord(p.url), decode, edge, p.cut.cutKey, turns, window, hole,
                                   p.exposure.word]
            // A word only where a picture is not laid the pair's way: a pair's key is what it always was.
            parts += Self.layWords(p)
            words.append(parts.joined(separator: "|"))
        }
        return words.joined(separator: " / ")
    }

    /// What of a picture's laying is not the pair's, as words for `key`: none
    /// for a picture placed in its hole unflipped and unturned (every pair's),
    /// so a pair's key is byte for byte what it was before a double existed.
    static func layWords(_ p: Picture) -> [String] {
        var words: [String] = []
        if p.lay == .add { words.append("added") }
        if p.flipped { words.append("flipped") }
        let after = ((p.turnedAfter % 4) + 4) % 4
        if after != 0 { words.append("then turned \(after)") }
        return words
    }

    /// Whether any picture is added rather than placed: a double exposure's piece.
    var adds: Bool { pictures.contains { $0.lay == .add } }

    /// The long edge to decode a picture at so that its window fills its hole
    /// without being made larger: nil when that is the file's own size or
    /// more (the picture is then enlarged into its hole, as a zoom asks).
    /// `framed` is the picture cut and turned at the file's own size.
    static func longEdge(original: PixelSize, framed: CGSize, window: CGRect, hole: CGSize) -> Int? {
        let shown = max(window.height * framed.height, 1), across = max(window.width * framed.width, 1)
        let k = max(hole.height / shown, hole.width / across)
        guard k < 1, original.longEdge > 0 else { return nil }
        let edge = Int((Double(original.longEdge) * Double(k)).rounded(.up))
        return edge >= original.longEdge ? nil : max(edge, 16)
    }
}

/// What composing a piece found out.
struct PieceReport: Sendable {
    /// How each picture's pixels were made, in the order they were laid.
    var how: [String] = []
    /// What the engine's meter chose for a picture read in this decode.
    var readings: [(index: Int, ev: Double, key: String)] = []
    /// The stops each picture was exposed by, by its index.
    var stops: [Int: Double] = [:]
}
