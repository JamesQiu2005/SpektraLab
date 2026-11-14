//  MaskFrame.swift — the one mapping of a surface's pixels to the photograph's source space S (RFC-052 §3).
//
//  Every mask is defined in S and nowhere else. To sample one, a surface supplies **one matrix**: its own pixels'
//  normalised coordinates → S, a 3 × 3 acting on the column (x, y, 1), divided by the third row where that is not 1
//  (affine today but for Develop's Vertical and Horizontal, the perspective `Geometry` already names). One function a
//  side, so there is no fourth silent copy of the crop's arithmetic (RFC-052 §3: "three kernels and the guide each
//  transliterate the crop mapping already"):
//
//  | surface | `MaskFrame` | made of |
//  |---|---|---|
//  | the engine's 场景 node | `engineNode` | the handed frame → S: the host's own cut (`HostCut`, a film edge's framing with its half turn carried back, a perspective) — the engine composes its own cut on top, from its own geometry function (`spk_geometry_source_px`) |
//  | Edit's pass on the finished picture | `finished` | the finished canvas → S: the host's turns after the engine, the gate's place on the film's canvas (`FilmGeometry.pictureBox`, what the guide draws the picture in), the cut (`Geometry.sourcePoint(forOutput:)`, the engine's and the guide's map), the perspective |
//  | the overlay, the tools | `view` | view → Edit's crop → finished → S |
//
//  Each is built from the model's own maps (`Geometry.sourcePoint(forOutput:)`, `HostCut.map`, `Keystone`), never
//  re-derived: a matrix is three points of the map (it is affine) or the keystone's own homography. Pure; no UIKit,
//  no Metal. `tools/mask_frame_selftest.swift` holds each against the map it is made of, breaks each term and expects
//  red; `tools/scene_layers_drive.swift` holds `engineNode` against the engine's own render (RFC-052 §10.4).
//
//  Coordinates: normalised with (0, 0)–(1, 1) the surface's corners (pixel edges, not centres): a pixel j of N has its
//  centre at (j + 0.5) / N, as the engine's kernel and the plane's texels have.

import CoreGraphics
import Foundation
import simd

/// A 3 × 3, row-major, on the column (x, y, 1).
struct MaskMatrix: Equatable, Sendable, CustomStringConvertible {
    var m: [Double]

    init(_ m: [Double]) { precondition(m.count == 9); self.m = m }

    static let identity = MaskMatrix([1, 0, 0, 0, 1, 0, 0, 0, 1])

    static func scale(_ sx: Double, _ sy: Double) -> MaskMatrix { MaskMatrix([sx, 0, 0, 0, sy, 0, 0, 0, 1]) }

    /// Core Graphics' affine (x' = a x + c y + tx, y' = b x + d y + ty).
    static func affine(_ t: CGAffineTransform) -> MaskMatrix {
        MaskMatrix([Double(t.a), Double(t.c), Double(t.tx), Double(t.b), Double(t.d), Double(t.ty), 0, 0, 1])
    }

    /// simd's matrix, which is stored by columns: entry (row r, column c) is `s[c][r]`.
    static func simd(_ s: simd_double3x3) -> MaskMatrix {
        MaskMatrix([s[0][0], s[1][0], s[2][0], s[0][1], s[1][1], s[2][1], s[0][2], s[1][2], s[2][2]])
    }

    /// The affine map that takes (0, 0), (1, 0) and (0, 1) where `f` takes them: exact for an affine `f`.
    static func through(_ f: (CGPoint) -> CGPoint) -> MaskMatrix {
        let o = f(.zero), ex = f(CGPoint(x: 1, y: 0)), ey = f(CGPoint(x: 0, y: 1))
        return MaskMatrix([Double(ex.x - o.x), Double(ey.x - o.x), Double(o.x), Double(ex.y - o.y), Double(ey.y - o.y), Double(o.y), 0, 0, 1])
    }

    /// `self` after `other`: (self ∘ other)(p) = self(other(p)).
    func after(_ other: MaskMatrix) -> MaskMatrix {
        var out = [Double](repeating: 0, count: 9)
        for r in 0..<3 { for c in 0..<3 { out[3 * r + c] = (0..<3).reduce(0) { $0 + m[3 * r + $1] * other.m[3 * $1 + c] } } }
        return MaskMatrix(out)
    }

    func apply(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        var s = m[0] * x + m[1] * y + m[2], t = m[3] * x + m[4] * y + m[5]
        let w = m[6] * x + m[7] * y + m[8]
        if w != 1 { s /= w; t /= w }
        return CGPoint(x: s, y: t)
    }

    var inverted: MaskMatrix {
        let s = simd_double3x3(rows: [SIMD3(m[0], m[1], m[2]), SIMD3(m[3], m[4], m[5]), SIMD3(m[6], m[7], m[8])])
        return .simd(s.inverse)
    }

    var isIdentity: Bool { self == .identity }
    /// As the engine and the kernels take it: nine floats, row-major.
    var floats: [Float] { m.map { Float($0) } }
    /// For a stamp: each entry to 1e-9, so a matrix the same to float is the same word.
    var key: String { m.map { String(format: "%.9g", $0) }.joined(separator: ",") }
    var description: String { "[" + m.map { String(format: "%.6g", $0) }.joined(separator: ", ") + "]" }
}

enum MaskFrame {
    // MARK: the engine's node

    /// **The handed frame → S**: what `spk_set_scene_layers` is handed as `frame_to_source`. `hostCut` is the host's
    /// own cut of the decode (`FrameEdit.hostCut(source:)`: a film edge's framing, its half turn carried back, a
    /// perspective; nil where the engine cuts for itself — the identity). `decode` is the decode's size before the
    /// cut, in pixels: `HostCut.map` holds a cut without a straighten to whole pixels of it, and the matrix holds the
    /// same pixels. The engine composes its own cut (the wire's geometry) on top.
    static func engineNode(hostCut: Geometry?, decode: CGSize) -> MaskMatrix {
        guard let g = hostCut, !g.isIdentity else { return .identity }
        let d = CGSize(width: max(decode.width, 1), height: max(decode.height, 1))
        let toS = MaskMatrix.scale(1 / Double(d.width), 1 / Double(d.height))
        // The corrected picture's pixels → the source's (the keystone's inverse; HostCut.corrected).
        let unkeystone = g.hasPerspective ? MaskMatrix.simd(g.keystone(in: d).inverse) : .identity
        // The perspective alone: the handed frame is the corrected picture, whole (HostCut.image).
        if g.hasPerspective, g.perspectiveOnly == g {
            return toS.after(unkeystone).after(.scale(Double(d.width), Double(d.height)))
        }
        let (out, toSource) = HostCut.map(g, imageSize: d)
        return toS.after(unkeystone).after(.affine(toSource)).after(.scale(Double(out.width), Double(out.height)))
    }

    // MARK: the finished picture

    /// A film edge's picture box on the finished canvas, as the guide draws the picture in it
    /// (`FilmGeometry.pictureBox`, `FilmCanvasView`): the canvas as shown in millimetres (`canvasMM`, the host's turns
    /// after the engine included), the picture's upright box on it, and the scan's residual tilt about `centre`.
    struct FilmBox: Equatable, Sendable {
        var canvasMM: CGSize
        var box: CGRect
        /// Degrees, clockwise (y down), about `centre`.
        var tilt: Double
        var centre: CGPoint
    }

    /// **The finished canvas → S** (RFC-052 §3's second row): the picture after the engine and the host's turns,
    /// before Edit's crop. `picture` is the cut that is the picture (`FrameEdit.pictureGeometry(source:)`: the
    /// photo's crop, or a film edge's framing; its straighten, turns and flips, its perspective); `source` the
    /// photograph's size (the cut's map is rigid in pixels, so its shape matters); `film` the gate's place on the
    /// film's canvas where a film edge is on, nil where the finished picture is the cut itself.
    static func finished(picture: Geometry, source: CGSize, film: FilmBox? = nil) -> MaskMatrix {
        let s = CGSize(width: max(source.width, 1), height: max(source.height, 1))
        // The cut's output (normalised) → the corrected frame (normalised): affine, so three of its points.
        let cut = MaskMatrix.through { picture.sourcePoint(forOutput: $0, imageSize: s) }
        let unkeystone: MaskMatrix = picture.hasPerspective
            ? MaskMatrix.scale(1 / Double(s.width), 1 / Double(s.height))
                .after(.simd(picture.keystone(in: s).inverse)).after(.scale(Double(s.width), Double(s.height)))
            : .identity
        let pictureToS = unkeystone.after(cut)
        guard let film else { return pictureToS }
        return pictureToS.after(gate(film))
    }

    /// The finished canvas (normalised) → the picture under the gate (normalised): the canvas's millimetres, the
    /// residual tilt undone about the box's centre, the box's own share.
    static func gate(_ f: FilmBox) -> MaskMatrix {
        let toMM = MaskMatrix.scale(Double(f.canvasMM.width), Double(f.canvasMM.height))
        let a = -f.tilt * .pi / 180
        let c = Double(f.centre.x), d = Double(f.centre.y)
        let untilt = MaskMatrix([cos(a), -sin(a), c - c * cos(a) + d * sin(a), sin(a), cos(a), d - c * sin(a) - d * cos(a), 0, 0, 1])
        let inBox = MaskMatrix([1 / Double(f.box.width), 0, -Double(f.box.minX) / Double(f.box.width),
                                0, 1 / Double(f.box.height), -Double(f.box.minY) / Double(f.box.height), 0, 0, 1])
        return inBox.after(untilt).after(toMM)
    }

    /// **A picture before the host's turns → the finished canvas** (both normalised): `turns` clockwise quarter turns,
    /// each (x, y) → (1 − y, x) — `FilmGeometry.filmToCanvas`'s turn and the inverse of `FullDetail`'s `fdOnRender`.
    /// What Edit's pass on the engine's own result (the export's kernel, the zoom) composes `finished` with, so its
    /// mask lands where the page's does after `EngineHost.turned` (RFC-052 §7).
    static func hostTurns(_ turns: Int) -> MaskMatrix {
        let one = MaskMatrix([0, -1, 1, 1, 0, 0, 0, 0, 1])
        var m = MaskMatrix.identity
        for _ in 0..<(((turns % 4) + 4) % 4) { m = one.after(m) }
        return m
    }

    // MARK: a view

    /// **A view → S** (RFC-052 §3's third row): the view's own normalised coordinates → the picture it shows of the
    /// finished canvas cut by Edit's crop (`zoom`, the page's: identity when the whole cut is shown), Edit's crop
    /// (`printCrop.onFinished(finishedSize)`, as the pages draw it), then `finished`.
    static func view(finished: MaskMatrix, printCrop: Geometry, finishedSize: CGSize, zoom: MaskMatrix = .identity) -> MaskMatrix {
        let crop = printCrop.onFinished(finishedSize)
        let cut = crop.isIdentity ? MaskMatrix.identity
            : MaskMatrix.through { crop.sourcePoint(forOutput: $0, imageSize: finishedSize) }
        return finished.after(cut).after(zoom)
    }
}
