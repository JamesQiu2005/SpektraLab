//  ExportPlan.swift — one frame's export geometry, worked out before decoding.
//
//  A recipe names the output size. This plan computes the decode size, the host's crop and rotation,
//  and the engine's canvas so the size shown in the export sheet agrees with the file.
//
//  A host crop also reduces filmFormatMM by the same ratio: film millimetres per pixel must stay
//  constant, or the exported grain and halation would differ from the developed picture. An edge
//  keeps its framing through `HostCut`; a pair uses the same arithmetic for each picture's hole.
//  The current engine renders whole frames. The host crop does not imply a banded render.

import CoreGraphics
import Foundation

struct ExportPlan: Equatable, Sendable {
    /// What an export is asked of.
    struct Ask: Equatable, Sendable {
        /// A film edge on the frame: the film's framing of the picture, and
        /// the host's side of its turn (`FrameEdit.hostCut`, `hostTurns`).
        struct Film: Equatable, Sendable {
            /// The framing as the page shows it (`FrameEdit.pictureGeometry`).
            var framing: Geometry
            /// The same, turned back by what the host turns the canvas afterwards.
            var hostCut: Geometry
            /// Quarter turns, clockwise, the host gives the engine's canvas.
            var hostTurns: Int
        }

        /// The picture that can be decoded, whole and upright: the original,
        /// or the preview copy while the original is away.
        var source: PixelSize
        /// The photo's own crop, turn and flips. Not used under a film edge.
        var photo = Geometry.default
        var film: Film? = nil
        /// The edit's `film_format_mm`: the uncut frame's long edge on the film.
        var filmFormatMM = 36.0
        var size: ExportRecipe.Size
        /// The largest frame this device develops (`DevicePolicy`).
        var capMegapixels: Double
        /// Edit's crop: a cut of the finished picture (`FrameEdit.printCrop`),
        /// made of the file after everything else (`FinishedCut`).
        var printCrop = Geometry.default
    }

    /// The long edge the source is decoded at. Nil is the file's own size.
    var decodeLongEdge: Int?
    /// The decode: the whole picture, at that long edge.
    var decoded: PixelSize
    /// The host's cut of the decode; nil hands the engine the decode whole.
    var cut: Geometry?
    /// The frame the engine is handed.
    var frame: PixelSize
    /// What the engine renders: the frame, or the film's canvas round it.
    var engineCanvas: PixelSize
    /// The file's pixels: the engine's canvas, after the host's turn.
    var output: PixelSize
    /// Quarter turns, clockwise, the host gives the engine's canvas.
    var turnsAfter = 0
    /// `film_format_mm` for this job, where the host's cut makes it other
    /// than the edit's; nil sends the edit's own.
    var filmFormatMM: Double?
    /// The photo's crop stays on the engine's wire: the format could not
    /// follow the cut. Such a job renders whole, and is planned as that.
    var engineCuts = false
    /// The device's cap, not the recipe, set the size.
    var isCapped = false
    /// Edit's crop, cut from the finished picture after the engine and the
    /// host's turn (`EngineHost.deliver`, `FinishedCut`); nil for none. `output`
    /// is the file after it, and the decode is sized for that.
    var printCrop: Geometry?

    /// The engine's range for `film_format_mm` (`engine/src/core/params.cpp`).
    static let filmFormatRange = 4.0...200.0

    /// The plan for one frame. `canvas` is the film's canvas round a framing
    /// of a given size — the engine's own layout, as the page's film is drawn
    /// from (`FilmGeometrySource`); it is asked only under a film edge.
    static func make(_ ask: Ask, canvas: (PixelSize) -> PixelSize? = { _ in nil }) -> ExportPlan {
        let source = ask.source
        /// The file Edit's crop leaves of a finished picture this large.
        func printed(_ finished: PixelSize) -> PixelSize {
            guard !ask.printCrop.isIdentity else { return finished }
            let size = CGSize(width: finished.width, height: finished.height)
            return pixels(ask.printCrop.onFinished(size).outputSize(for: size))
        }
        /// The frame the engine is handed, and the file, for a decode of this size.
        func laid(_ decoded: PixelSize) -> (frame: PixelSize, engine: PixelSize, output: PixelSize) {
            let whole = CGSize(width: decoded.width, height: decoded.height)
            guard let film = ask.film else {
                let frame = ask.photo.isIdentity ? decoded : pixels(HostCut.map(ask.photo, imageSize: whole).size)
                return (frame, frame, printed(frame))
            }
            let frame = pixels(HostCut.map(film.hostCut, imageSize: whole).size)
            // The film is laid round the framing as the page shows it; the
            // engine makes it turned back, and the host turns it forward.
            let framing = pixels(HostCut.map(film.framing, imageSize: whole).size)
            let output = canvas(framing) ?? framing
            let engine = film.hostTurns % 2 == 0 ? output : PixelSize(width: output.height, height: output.width)
            return (frame, engine, printed(output))
        }

        // The scale of the decode: 1 is the source's own pixels, and nothing is ever larger.
        let full = laid(source)
        let largest = max(source.megapixels, full.engine.megapixels)
        let cap = exceeds(largest, ask.capMegapixels) ? (ask.capMegapixels / largest).squareRoot() : 1
        var scale = cap
        switch ask.size {
        case .full, .preview:
            break
        case .megapixels(let mp):
            if exceeds(full.output.megapixels, mp) { scale = min(scale, (mp / full.output.megapixels).squareRoot()) }
        case .longEdge(let edge):
            if full.output.longEdge > edge, edge > 0 { scale = min(scale, Double(edge) / Double(full.output.longEdge)) }
        case .shortEdge(let edge):
            let short = min(full.output.width, full.output.height)
            if short > edge, edge > 0 { scale = min(scale, Double(edge) / Double(short)) }
        }
        var edge = scale < 1 ? max(1, Int((Double(source.longEdge) * scale).rounded())) : source.longEdge
        if case .megapixels(let mp) = ask.size, scale < 1, scale < cap || cap == 1 {
            // A size named in megapixels has no one long edge, so the decode takes the best
            // one near it. A whole division where that still is the size named: a host's
            // 48 MP photo at "12 MP" is every second pixel of it, 4,032 x 3,024 — its camera's
            // own 12 MP — and not 4,000 x 3,000 by a scale of 0.496.
            let whole = (2...8).first { k in
                let made = full.output.megapixels / Double(k * k)
                return made <= mp * nominalSlack && made >= mp / nominalSlack && source.width % k == 0 && source.height % k == 0
            }
            if let whole {
                edge = source.longEdge / whole
            } else {
                edge = even(edge, of: source)
            }
        } else if scale < 1, scale == cap {
            edge = even(edge, of: source)
        }
        var decoded = edge < source.longEdge ? source.scaled(toLongEdge: edge) : source
        var made = laid(decoded)
        // An edge named in pixels comes out at that number where a decode a pixel or two
        // larger gives it: a film's border round the framing is rounded on its own, and
        // 3,000 asked of a film came out 2,999 (2026-10-20).
        func side(_ s: PixelSize) -> Int? {
            switch ask.size {
            case .longEdge: s.longEdge
            case .shortEdge: min(s.width, s.height)
            default: nil
            }
        }
        if let target = { () -> Int? in
            switch ask.size { case .longEdge(let e), .shortEdge(let e): e; default: nil }
        }(), scale < 1, scale > cap || cap == 1, var got = side(made.output), got < target {
            for _ in 0..<4 where got < target && edge < source.longEdge {
                let next = source.scaled(toLongEdge: edge + 1)
                let tried = laid(next)
                guard let s = side(tried.output), s <= target else { break }
                edge += 1; decoded = next; made = tried; got = s
            }
        }

        var plan = ExportPlan(decodeLongEdge: edge < source.longEdge || ask.size == .preview ? edge : nil, decoded: decoded,
                              cut: nil, frame: made.frame, engineCanvas: made.engine, output: made.output)
        // The cap set the size when it is what held the decode under the size asked.
        plan.isCapped = cap < 1 && scale == cap
        plan.printCrop = ask.printCrop.isIdentity ? nil : ask.printCrop
        if let film = ask.film {
            plan.cut = film.hostCut
            plan.turnsAfter = ((film.hostTurns % 4) + 4) % 4
        } else if !ask.photo.isIdentity {
            // The same micrometres a pixel as the uncut frame: the format follows the cut.
            let format = ask.filmFormatMM * Double(made.frame.longEdge) / Double(max(decoded.longEdge, 1))
            if filmFormatRange.contains(format) {
                plan.cut = ask.photo
                if made.frame.longEdge != decoded.longEdge { plan.filmFormatMM = format }
            } else {
                // The engine is handed the decode whole and cuts it itself —
                // re-projected first where Vertical or Horizontal is turned,
                // which the engine cannot do (`FrameEdit.hostCut`).
                plan.engineCuts = true
                plan.frame = decoded
                plan.cut = ask.photo.hasPerspective ? ask.photo.perspectiveOnly : nil
                let out = pixels(ask.photo.outputSize(for: CGSize(width: decoded.width, height: decoded.height)))
                plan.engineCanvas = out
                plan.output = printed(out)
            }
        }
        return plan
    }

    /// A size named in megapixels is a camera's: "12 MP" is 4,032 × 3,024,
    /// which is 12.19 million pixels, and "48 MP" 48.77. So a picture is over
    /// a named size only when it is over it by more than that slack — a
    /// host's own photo is not resampled by a hundredth to fit its own name.
    static let nominalSlack = 1.02

    static func exceeds(_ megapixels: Double, _ named: Double) -> Bool {
        named > 0 && megapixels > named * nominalSlack
    }

    /// The long edge at or under `edge` at which both sides of the picture
    /// are whole, even numbers of pixels, where the picture's shape has one
    /// near: 8 px apart for a 4:3 picture, 6 for a 3:2. A reduced decode
    /// comes out at exactly such a size from every decoder; at others
    /// ImageIO's is a pixel off the arithmetic on one side or the other
    /// (measured on this Mac, 2026-10-08: 109 of 442 long edges of a 4:3 HEIF),
    /// and the file would be a pixel off the size the sheet showed. A shape
    /// with no such edge within 64 px is left as it is, and may be a pixel off.
    private static func even(_ edge: Int, of source: PixelSize) -> Int {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let unit = 2 * source.longEdge / max(gcd(source.width, source.height), 1)
        guard unit > 1, unit <= 64, edge >= unit else { return edge }
        return edge / unit * unit
    }

    private static func pixels(_ size: CGSize) -> PixelSize {
        PixelSize(width: max(1, Int(size.width.rounded())), height: max(1, Int(size.height.rounded())))
    }
}
