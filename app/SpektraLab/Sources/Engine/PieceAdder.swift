//  PieceAdder.swift — a double exposure's light, added into one piece of film.
//
//  RFC-048 §2: the pictures of a double exposure are **added** into the whole
//  buffer, not placed into holes. `FrameDecoder.decode(_:meter:)` renders each
//  picture, placed over the frame (`PiecePlacer.place`), **band by band into
//  one scratch band** and hands each band here, which adds its light into the
//  piece with the picture's gain:
//
//      piece[rgb] += gain · band[rgb]          alpha stays 1
//
//  **In scene-linear ProPhoto float**, the decoder's own space (`FrameDecoder`:
//  "scene-linear float32, ProPhoto RGB primaries at D50"): the only place
//  where the sum is physically a double exposure. The film's response to the
//  sum is the engine's, so highlights shoulder and shadows fill as they do on
//  a negative.
//
//  **The bands are `FrameDecoder.render`'s own** — about four megapixels each
//  (`bandPixels`), rows split evenly — so the scratch is one band, at most
//  `scratchBytes` (64 MB and a row at 16 B a pixel), reused for every band of
//  both pictures. The piece's buffer, the scratch and one picture's decode in
//  Core Image are what an open of a double holds (RFC-048 §5).
//
//  **Two multiplies and an add, not `vDSP_vsma`** (the RFC names `vsma`): a
//  fused multiply-add rounds once, so `fma(g₂, B, g₁·A)` and `fma(g₁, A, g₂·B)`
//  can differ in their last bit, and the order of laying would change the
//  frame. Scaling the band first (`vDSP_vsmul`, one rounding of g·band) and
//  then adding (`vDSP_vadd`, one rounding of the sum) gives round(round(g₁A) +
//  round(g₂B)) whichever comes first: **the order of laying does not change one
//  byte** (RFC-048 §7, "commutes"; `tools/piece_selftest.swift`).
//
//  **Alpha.** The engine reads the first three channels of what it is handed
//  and nothing else: `spk_open_device` copies every frame through the kernel
//  `spk_take_rgb` (`engine/src/shaders/util.metal`: `out[3i + c] = img[channels·i
//  + c]` for c < 3), into the session's three-channel source, whether it is
//  handed three channels or four (`engine/src/pipeline/engine.cpp`,
//  `open_frame`). So alpha reaches nothing the engine does. It is set to 1 for
//  the whole piece anyway (`expose`), so that what the host hands over is an
//  honest opaque frame; the add never touches it. (The pair's `.place` path
//  scales a hole's alpha with its gain, and leaves the gap's at 0: harmless for
//  the same reason, and not changed here.)
//
//  No engine, no Metal, no Core Image in here: plain buffers and Accelerate,
//  so a Mac holds the arithmetic and the band walk to the RFC's numbers
//  (`tools/piece_selftest.swift`: g₁·A + g₂·B within 1e-6, alpha 1, an empty
//  layer zero light, either order byte for byte).

import Accelerate
import Foundation

enum PieceAdder {
    /// About this many pixels a band: `FrameDecoder.render`'s figure, which is
    /// what kept Core Image's own peak down (751 MB against 1,334 for a 48 MP
    /// ProRAW at 2,400 px, on the Mac).
    static let bandPixels = 4_000_000.0

    /// How many bands a picture `width` × `height` is rendered in: the count
    /// `FrameDecoder.render` makes, so a picture is drawn by Core Image in the
    /// same pieces whether it is placed or added.
    static func bands(width: Int, height: Int) -> Int {
        max(1, Int((Double(width) * Double(height) / bandPixels).rounded(.up)))
    }

    /// Band `b`'s rows: `r0 ..< r1`, the picture's rows top first.
    static func rows(_ b: Int, of bands: Int, height: Int) -> Range<Int> {
        (height * b / bands) ..< (height * (b + 1) / bands)
    }

    /// The most rows any band has.
    static func bandRows(width: Int, height: Int) -> Int {
        let n = bands(width: width, height: height)
        return (0..<n).map { rows($0, of: n, height: height).count }.max() ?? 0
    }

    /// The scratch band's bytes for a piece this large: one band of RGBA float.
    /// What the cost model is told an open of a double holds beside the piece
    /// (`RenderJob.Composition.scratchBytes`). 64 MB and a row's at most.
    static func scratchBytes(width: Int, height: Int) -> Int {
        width * bandRows(width: width, height: height) * 16
    }

    /// The piece as unexposed film: every colour channel 0 and alpha 1. A new
    /// Metal buffer is zeros already; this sets the alpha (see the header), and
    /// zeros the colour so a reused buffer is film nobody exposed too.
    static func expose(_ piece: UnsafeMutableRawPointer, pixels: Int) {
        guard pixels > 0 else { return }
        let p = piece.assumingMemoryBound(to: Float.self)
        var zero: Float = 0, one: Float = 1
        for c in 0..<3 { vDSP_vfill(&zero, p + c, 4, vDSP_Length(pixels)) }
        vDSP_vfill(&one, p + 3, 4, vDSP_Length(pixels))
    }

    /// One band's light added into the piece: `count` pixels of RGBA float at
    /// `band`, scaled by `gain` in place (the scratch is this picture's, and
    /// spent), then summed into the same pixels of `piece` on R, G and B. The
    /// piece's alpha is not touched.
    static func add(_ band: UnsafeMutableRawPointer, gain: Float, into piece: UnsafeMutableRawPointer, pixels count: Int) {
        guard count > 0 else { return }
        let b = band.assumingMemoryBound(to: Float.self), p = piece.assumingMemoryBound(to: Float.self)
        if gain != 1 {
            var g = gain
            vDSP_vsmul(b, 1, &g, b, 1, vDSP_Length(count * 4))
        }
        for c in 0..<3 { vDSP_vadd(b + c, 4, p + c, 4, p + c, 4, vDSP_Length(count)) }
    }

    /// **One picture laid over the whole piece by adding**, band by band:
    /// `render(scratch, rows)` draws the picture's rows `rows` into the scratch
    /// (rows `width × 16` bytes apart, its first row the band's top), and each
    /// band is added into the same rows of the piece with `gain`. `scratch`
    /// holds `scratchBytes(width:height:)` at least. A cancel is the render's
    /// to throw, between bands, as `FrameDecoder.render` asks it.
    static func lay(width w: Int, height h: Int, gain: Float, into piece: UnsafeMutableRawPointer, scratch: UnsafeMutableRawPointer,
                    render: (UnsafeMutableRawPointer, Range<Int>) throws -> Void) throws {
        let n = bands(width: w, height: h)
        for b in 0..<n {
            let r = rows(b, of: n, height: h)
            guard !r.isEmpty else { continue }
            try autoreleasepool {
                try render(scratch, r)
            }
            add(scratch, gain: gain, into: piece + r.lowerBound * w * 16, pixels: r.count * w)
        }
    }
}
