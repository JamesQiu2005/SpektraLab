//  PrintLayers.swift — a frame of a half-frame pair that prints as its own.
//
//  One enlarger prints a pair's piece: the pair's look, which is the wire
//  (`FrameEdit.pairWire`). A frame may print differently — its own brightness,
//  its own two filters, its own pre-flash (`HalfFramePair.Hole.print`) — and
//  nothing on the wire says so: the engine has one enlarger a session.
//
//  **The picture of a pair is printed once for the film, and once more for
//  each frame whose print is its own, and the prints are cut together along
//  the holes.** A print-only change leaves the developed negative as it is,
//  so a frame's print is `spk_set_params` with that frame's rows and
//  `spk_reprint` of the same negative, and the film's rows are put back
//  (`SpkEngine`; the desktop's `Session.pairLayered`,
//  `EngineClient.renderLayers`, `Renderer.compositePair`). It is the engine's
//  own print of the same negative, never a gain the host paints on.
//
//  Three things are here, and none of them touches the engine or a page, so
//  `tools/selftest.sh` holds each on a Mac:
//
//  - **what is asked** (`PrintLayer`, `HalfFramePair.printLayers`): which
//    frames print again, with which rows, and where each is on the piece;
//  - **the cut** (`PrintCut`): a frame's print taken into the film's inside
//    its rectangle, with the desktop's feather at the edge;
//  - **where the frames are on a strip** (`FilmGates`): with a film edge the
//    canvas is the film and not the piece, and only the engine knows where it
//    put the two gates (`spk_overscan_geometry`).
//
//  **A film that is scanned has no print of a frame's own.** A slide, a
//  negative scanned, a digital intermediate: the engine leaves the enlarger
//  out, so its rows move nothing, and nothing is asked for them. Neither is a
//  print that comes out the film's own on the wire — a pre-flash while Print
//  Effects is off. `HalfFramePair.isLayered` says a frame's print is its own;
//  `printLayers` says what the engine is asked for it.

import CoreGraphics
import Foundation

/// One frame of a half-frame pair that prints as its own, as the engine's host
/// is asked for it: plain values, made on the main actor when a job is
/// submitted (`EngineRouter.prepare`).
struct PrintLayer: Equatable, Sendable {
    /// The frame: 0 the first (the left one, or the upper), 1 the second.
    var index: Int
    /// This frame's print in wire names: the enlarger's four rows, as the
    /// film's own print has them on the wire.
    var rows: [String: ParamValue]
    /// Where the frame is on the piece, normalised with a top-left origin
    /// (`HalfFramePair.holeRects`). On a strip the canvas is the film, and the
    /// frame is where the engine put its gate (`FilmGates`).
    var rect: CGRect

    /// The enlarger's four values a frame may have for itself
    /// (`HalfFramePair.PrintTrim`), by their wire names. All four are the
    /// engine's live rows (`FilmParams.liveMutable`): set on an open session
    /// they rebuild nothing and leave its negative.
    static let names = ["print_exposure", "y_filter_shift", "m_filter_shift", "preflash_exposure"]

    /// These settings' own four rows, as `FilmParams.wire` sends them — so
    /// the clamps and the gates are the model's: brightness as the enlarger's
    /// exposure, no pre-flash while Print Effects is off.
    static func rows(of params: FilmParams) -> [String: ParamValue] {
        params.wire.reduce(into: [:]) { rows, field in
            if names.contains(field.name) { rows[field.name] = field.value }
        }
    }

    /// What of this layer changes the picture, as a word, for a develop's
    /// stamp: the frame and its rows, written as the stamp writes the wire's.
    /// Not where the frame is — the piece says that (`PieceAsk.key`).
    var key: String {
        "print \(index): " + rows.keys.sorted().map { "\($0)=\(rows[$0]?.description ?? "")" }.joined(separator: ";")
    }
}

extension HalfFramePair {
    /// The prints this piece's picture is cut together from, beside the
    /// film's own: one for each frame whose print is its own (`Hole.print`,
    /// and not what the film prints with: `isLayered`) **and comes out
    /// another print on the wire**. In the film's order, the first frame's
    /// first.
    ///
    /// None where the film is scanned and not printed, or read as a digital
    /// intermediate: the engine leaves the enlarger out of both, so a frame's
    /// rows would print the same picture again.
    func printLayers(look: FilmParams, catalog: StockCatalog = .shared) -> [PrintLayer] {
        guard !catalog.isScanned(look), !look.digitalIntermediate else { return [] }
        let film = PrintLayer.rows(of: look)
        let rects = holeRects
        return Side.allCases.compactMap { side in
            guard let own = self[side]?.print, own != PrintTrim(look), let rect = rects[side] else { return nil }
            let rows = PrintLayer.rows(of: own.applied(to: look))
            return rows == film ? nil : PrintLayer(index: side.rawValue, rows: rows, rect: rect)
        }
    }
}

/// A frame's own print, cut into the film's.
enum PrintCut {
    /// The feather at a frame's edge, in pixels: the desktop's
    /// (`Renderer.compositePair`).
    static let feather = 1.5

    /// How much of the frame's print a pixel takes, 0…1, for a centre `d`
    /// pixels inside the frame's nearest edge (negative outside it): the
    /// desktop's `pairCoverage` (`Shaders.metal`). Half at the edge itself,
    /// whole from half the feather inside it, none from half the feather out.
    static func coverage(inside d: Double, feather: Double = feather) -> Double {
        (d / max(feather, 1e-3) + 0.5).clamped(to: 0...1)
    }

    /// `layer` cut into `base` inside `rect`: both are pictures `width` by
    /// `height`, four 16-bit channels a pixel, top row first, each with its
    /// own row pitch in pixels (a result's is its width rounded up to the
    /// device's alignment: `RenderedPixels.rowStridePixels`). `rect` is
    /// normalised to the picture with a top-left origin.
    ///
    /// Inside the frame the pixels are `layer`'s, copied as they are; at its
    /// edge the two are mixed by `coverage`; everywhere else `base` is not
    /// written at all — the film's print between the frames stays the
    /// engine's to the last code, and so does the pitch's padding.
    ///
    /// Returns the pixels it may have written — every pixel with any share of
    /// the layer is among them — for a host whose picture is made from a copy
    /// of `base` and not from this memory (`EngineHost.carry`). Nil when it
    /// wrote none: no frame on the picture.
    @discardableResult
    static func cut(_ layer: UnsafePointer<UInt16>, stride layerStride: Int,
                    into base: UnsafeMutablePointer<UInt16>, stride baseStride: Int,
                    width: Int, height: Int, rect: CGRect, feather: Double = feather) -> Written? {
        guard width > 0, height > 0, layerStride >= width, baseStride >= width, rect.width > 0, rect.height > 0 else { return nil }
        // The frame in pixels, as the desktop makes it: the normalised rectangle times the canvas.
        let x0 = Double(rect.minX) * Double(width), x1 = Double(rect.maxX) * Double(width)
        let y0 = Double(rect.minY) * Double(height), y1 = Double(rect.maxY) * Double(height)
        // A pixel takes part while its centre is within half the feather of the frame, on either side.
        let reach = max(feather, 1e-3) / 2
        func touched(_ lo: Double, _ hi: Double, _ count: Int) -> ClosedRange<Int>? {
            let first = max(Int((lo - reach - 0.5).rounded(.up)), 0), last = min(Int((hi + reach - 0.5).rounded(.down)), count - 1)
            return first <= last ? first...last : nil
        }
        guard let columns = touched(x0, x1, width), let rows = touched(y0, y1, height) else { return nil }
        // A pixel is its centre. The nearest edge decides, so its share is the lesser of its column's and its row's.
        func share(_ pixel: Int, _ lo: Double, _ hi: Double) -> Double {
            let centre = Double(pixel) + 0.5
            return coverage(inside: min(centre - lo, hi - centre), feather: feather)
        }
        let across = columns.map { share($0, x0, x1) }
        // The columns wholly inside are one run: a row wholly inside copies it in one piece.
        let whole = across.firstIndex(of: 1).flatMap { first in across.lastIndex(of: 1).map { first...$0 } }
        for y in rows {
            let down = share(y, y0, y1)
            guard down > 0 else { continue }
            let from = layer + (y * layerStride + columns.lowerBound) * 4
            let to = base + (y * baseStride + columns.lowerBound) * 4
            var i = 0
            while i < across.count {
                if down >= 1, let whole, i == whole.lowerBound {
                    (to + i * 4).update(from: from + i * 4, count: whole.count * 4)
                    i += whole.count
                    continue
                }
                let part = min(across[i], down)
                if part > 0 {
                    for k in (i * 4)..<(i * 4 + 4) {
                        let film = Double(to[k])
                        to[k] = UInt16((film + (Double(from[k]) - film) * part).rounded())
                    }
                }
                i += 1
            }
        }
        return Written(columns: columns, rows: rows)
    }

    /// The part of a picture a cut may have written: its columns and its
    /// rows, in pixels with a top-left origin.
    struct Written: Equatable, Sendable {
        var columns: ClosedRange<Int>
        var rows: ClosedRange<Int>
    }
}

/// Where a strip's frames are: the engine's own answer, read.
enum FilmGates {
    /// The gates in `spk_overscan_geometry`'s reply, as rectangles normalised
    /// to the canvas with a top-left origin. The reply gives each gate's four
    /// corners (`{"valid":true,…,"gates":[[x0,y0, x1,y1, x2,y2, x3,y3],…]}`),
    /// a little out of true where the scan lies a little turned; a gate's
    /// rectangle is what bounds them, as the desktop takes it
    /// (`EngineClient.overscanGates`).
    ///
    /// **A pair's two are in the film's order, the first frame's first**: the
    /// left one held level, the upper one turned — whichever way they lie
    /// apart (the desktop's `Session.pairHoleRects`). Empty when the reply is
    /// not valid (no film edge, or nothing rendered yet) or does not parse.
    static func rects(_ json: String) -> [CGRect] {
        guard let reply = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              reply["valid"] as? Bool == true, let gates = reply["gates"] as? [[NSNumber]] else { return [] }
        var rects: [CGRect] = []
        for corners in gates {
            guard corners.count == 8 else { return [] }
            let xs = stride(from: 0, to: 8, by: 2).map { corners[$0].doubleValue }
            let ys = stride(from: 1, to: 8, by: 2).map { corners[$0].doubleValue }
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max(), x1 > x0, y1 > y0 else { return [] }
            rects.append(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        }
        guard rects.count == 2 else { return rects }
        let across = abs(rects[1].midX - rects[0].midX) >= abs(rects[1].midY - rects[0].midY)
        return rects.sorted { across ? $0.minX < $1.minX : $0.minY < $1.minY }
    }
}
