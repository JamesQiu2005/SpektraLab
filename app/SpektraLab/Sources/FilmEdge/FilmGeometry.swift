//  FilmGeometry.swift — the film around a picture, laid out as the engine lays it out.
//
//  **What this is.** The answer to "where is everything on this film": the
//  canvas, the gate with its family's cuts, the perforations, every mark of
//  the edge print (the name, the frame numbers, the DX bars), and the date.
//  The Frame step's GUIDE, the format cards and the Frame tab draw from it, so
//  what a page shows of a film edge before it develops is what the develop
//  then shows: the same silhouette, the same view, the same words, the same
//  DX code where the film has one.
//
//  **Where it comes from.** `FilmLayout` is a port of the engine's own layout
//  — `Pipeline::overscan_layout`, `gate_shape` and `imprint_groups` in this
//  repository's `engine/src/pipeline/overscan.cpp`, which is the desktop's at
//  `unpublished-revision` (its 1.3.1: a strip scan that ends at the film's long edges,
//  Fujifilm's print as a dot matrix, Kodak 120's lettering; the maintainer's
//  code) with the black-and-white films' edges on top (synced 2026-10-09:
//  Ilford's 135 layout, a one-cell `II`) — statement for statement: the same splitmix streams, the same draws
//  in the same order, the same millimetres, the same dot tables, and CoreText
//  for the same glyphs. `design/src/overscan_geom.py` is a port of an earlier
//  engine in Python, for the drawings.
//
//  It is a **stand-in for the engine's geometry call** (`spk_overscan_geometry`,
//  RFC-032 §29.6, which today returns the gates only), and it is reached through
//  `FilmGeometrySource` so the engine can take its place. Until then two things
//  keep it honest: `tools/film_edge_parity.py` holds it against the engine's
//  own render, case by case, and every page draws the film from this one
//  value, never from a second copy of the arithmetic.
//
//  Left out: the gate's wobble (~12 µm), its roughness, the penumbra's
//  softness, per-hole punch tolerances and the softness of a hole's edge, each
//  mark's own density, fog and leaks' own shapes. They are below a guide's
//  scale and do not move a mark. Left out whole, because the host does not
//  ask for them: the half-frame pair (`FeatureFlags.halfFramePair`); a carrier
//  past the film's edges (`overscan_carrier` = `black` | `open`); and a date
//  face in 120's margin (1.3.1). The date and the shooting data together
//  (`date_imprint_data_text`, 1.3.1) is laid out since 2026-10-20, when the
//  host first asked for it (`FilmLayout.dateMarks`).

import CoreGraphics
import CoreText
import Foundation
import SwiftUI

// MARK: - the engine's random streams

/// splitmix64, one stream per (level, purpose), so adding a draw to one level
/// never shifts another level's values.
struct SplitMix64 {
    private var s: UInt64
    init(_ seed: UInt64) { s = seed }

    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uni() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
    mutating func uni(_ a: Double, _ b: Double) -> Double { a + (b - a) * uni() }
    mutating func normal() -> Double {
        let u1 = max(uni(), 1e-12)
        let u2 = uni()
        return (-2.0 * log(u1)).squareRoot() * cos(2.0 * .pi * u2)
    }

    enum Level: UInt64 { case film = 1, camera = 2, frame = 3 }
    static func stream(_ seed: UInt64, _ level: Level, _ purpose: UInt64) -> UInt64 {
        (seed &* 0x9E37_79B9_7F4A_7C15) ^ (level.rawValue << 40) ^ (purpose << 20) ^ 0xD1B5_4A32_D192_ED03
    }
}

// MARK: - what is asked, and what comes back

/// The date a layout is asked to place: `date_imprint_*`, already resolved.
struct DateRequest: Equatable, Sendable {
    var text: String
    var style = DateBackFace.lcd
    var placement = DateBackPlacement.frame
    var corner = DateBackCorner.br
    var insetXMM = 3.0
    var insetYMM = 2.4
    var size = 1.0
    /// `date_imprint_data_text`: the data line printed as well as a date face; empty: none.
    var dataText = ""
}

/// What the engine is told about one film edge: `overscan_*`, resolved.
struct FilmEdgeRequest: Equatable, Sendable {
    var format = FilmEdgeFormat.f135
    var mode = FilmEdgeView.strip
    var gate = FilmEdgeGate.auto
    var holes = FilmEdgeHoles.white
    var cameraSeed = 1
    var frameSeed = 1
    var frameNumber = 0
    /// Quarter turns of the film around the picture, clockwise.
    var turn = 0
    /// The picture handed to the engine, as it is seen at `turn`: already cut
    /// to the gate's shape.
    var frame = PixelSize(width: 3600, height: 2400)
    var stockID = ""
    /// `overscan_edge_text`: the host's words.
    var edgeText = ""
    var fNumber = 0.0
    var date: DateRequest? = nil
}

/// One mark exposed onto the film, in film millimetres: `s` along the film,
/// `t` across it from the edge the name is printed on.
enum FilmMark: Equatable, Sendable {
    case text(FilmText)
    /// `s0, t0, s1, t1, …`, closed.
    case poly([Double])
    case circle(s: Double, t: Double, r: Double)
}

struct FilmText: Equatable, Sendable {
    var text = ""
    var font = "HelveticaNeue-Bold"
    /// The font's size (its em), in millimetres.
    var sizeMM = 1.0
    /// The baseline's start.
    var s = 0.0
    var t = 0.0
    var trackingMM = 0.0
    /// Glyphs widened along the baseline (Kodak's wide numerals).
    var hscale = 1.0
    /// `hscale` alone widens the glyphs' shapes: CoreText places them at their
    /// own advances, so widened letters close up on each other. With this set
    /// the whole line is scaled, advances and tracking with it, and the string
    /// is `hscale` times as long (Kodak 120's extended face).
    var scaleAdvances = false
}

/// A piece added to the gate's opening or cut from it (`OverscanLayout::Quad`):
/// four points, a rounding, and a sign — above zero adds, below cuts, and −2
/// is an ellipse `(cs, ct, rs, rt)` cut.
struct GateQuad: Equatable, Sendable {
    var pts: [Double]
    var round: Double
    var sign: Double
}

/// One DX code on the film: where it lies — its end nearer the film's start,
/// which is where a code on the bottom band begins and a turned one (Ilford's)
/// ends — and what it says.
struct DXCode: Equatable, Sendable {
    var s: Double
    var frame: Int
    var half: Bool
    var bits: [Int]
}

struct FilmGeometry: Equatable, Sendable {
    var request: FilmEdgeRequest
    /// The family the gate was made in: never `.auto`.
    var gateFamily = FilmEdgeGate.square
    /// Millimetres per pixel: the gate's long edge over the picture's.
    var px = 0.01
    /// The engine's canvas, and the canvas as it is shown (turned with the film).
    var canvas = PixelSize(width: 1, height: 1)
    var out = PixelSize(width: 1, height: 1)
    /// The film runs down the canvas (the engine's own quarter turn).
    var vertical = false
    /// Quarter turns of the engine's canvas the host makes for `turn`.
    var extraTurns = 0

    var filmW = 35.0
    var gateS0 = 0.0, gateT0 = 0.0, gateAlong = 36.0, gateAcross = 24.0
    /// Corner radii: (s0, t0), (s1, t0), (s1, t1), (s0, t1).
    var gateR = [0.0, 0.0, 0.0, 0.0]
    var quads: [GateQuad] = []
    var topRecess = 0.0
    var penumbra = 0.0

    var perforated = false
    var perfPhase = 0.0
    static let perfPitch = 4.75, perfW = 1.98, perfH = 2.80, perfEdge = 2.00, perfR = 0.50

    /// canvas (u, v) → film (s, t): `(s, t) = A (u − cu, v − cv) + (cs, ct)`.
    var A = [1.0, 0.0, 0.0, 1.0]
    var cs = 0.0, ct = 0.0, cu = 0.0, cv = 0.0
    var scanRot = 0.0
    /// The canvas's extent on the film, along it.
    var sLo = 0.0, sHi = 0.0
    var tLo = 0.0, tHi = 0.0

    /// The edge print: the top band's marks, then the bottom band's.
    var edge: [FilmMark] = []
    /// The date back's marks; empty when no date is drawn.
    var date: [FilmMark] = []
    /// The DX codes on this piece of film; empty when the stock prints none.
    var dxCodes: [DXCode] = []
    /// The DX number the bars carry, or nil: no bars.
    var dxNumber: Int? = nil
    /// A code's length along the film, millimetres; 0 with no bars.
    var dxLength = 0.0
    /// The bars lie along the top band and read with the film turned half a
    /// turn (Ilford's layout).
    var dxTurned = false
    /// The name as the edge prints it, after it was fitted to its slot.
    var printedName = ""
    /// The frame numbers the edge print carries, in film order.
    var printedNumbers: [String] = []

    // MARK: sizes

    /// The canvas as shown, in millimetres.
    var canvasMM: CGSize { CGSize(width: Double(out.width) * px, height: Double(out.height) * px) }
    /// Film pixels per picture pixel: what the border costs.
    var cost: Double {
        Double(canvas.width) * Double(canvas.height) / max(1, Double(request.frame.width) * Double(request.frame.height))
    }

    // MARK: film → canvas

    /// Film millimetres → the shown canvas's millimetres (origin top-left),
    /// the host's extra turns included. A rotation, never a reflection.
    var filmToCanvas: CGAffineTransform {
        let a = A[0], b = A[1], c = A[2], d = A[3]
        let det = a * d - b * c
        // (u, v) = A⁻¹ ((s, t) − (cs, ct)) + (cu, cv)
        var m = CGAffineTransform(a: d / det, b: -c / det, c: -b / det, d: a / det,
                                  tx: cu - (d * cs - b * ct) / det, ty: cv - (-c * cs + a * ct) / det)
        var h = Double(canvas.height) * px
        var w = Double(canvas.width) * px
        for _ in 0..<extraTurns {
            // one clockwise quarter turn: (x, y) → (H − y, x)
            m = CGAffineTransform(a: -m.b, b: m.a, c: -m.d, d: m.c, tx: h - m.ty, ty: m.tx)
            swap(&w, &h)
        }
        return m
    }

    /// The picture's upright box on the shown canvas (mm), the scan's residual
    /// tilt in degrees, and the gate's centre it turns about.
    var pictureBox: (box: CGRect, tilt: Double, centre: CGPoint) {
        let m = filmToCanvas
        let angle = atan2(Double(m.b), Double(m.a)) * 180 / .pi
        let q = (angle / 90).rounded()
        let tilt = angle - 90 * q
        let turned = Int(q) % 2 != 0
        let w = turned ? gateAcross : gateAlong, h = turned ? gateAlong : gateAcross
        let centre = CGPoint(x: gateS0 + gateAlong / 2, y: gateT0 + gateAcross / 2).applying(m)
        return (CGRect(x: centre.x - w / 2, y: centre.y - h / 2, width: w, height: h), tilt, centre)
    }

    // MARK: shapes, in film millimetres

    /// The gate's opening: the rounded rectangle, then the family's quads in order.
    var gateOpening: Path {
        var opening = gateOutline.cgPath
        for q in quads {
            let piece = Self.path(of: q)
            opening = q.sign > 0 ? opening.union(piece) : opening.subtracting(piece)
        }
        return Path(opening)
    }

    /// The gate's plain rectangle with its four corner radii.
    var gateOutline: Path {
        let s0 = gateS0, t0 = gateT0, w = gateAlong, h = gateAcross
        let r = gateR
        var p = Path()
        p.move(to: CGPoint(x: s0 + r[0], y: t0))
        p.addLine(to: CGPoint(x: s0 + w - r[1], y: t0))
        p.addArc(tangent1End: CGPoint(x: s0 + w, y: t0), tangent2End: CGPoint(x: s0 + w, y: t0 + r[1]), radius: r[1])
        p.addLine(to: CGPoint(x: s0 + w, y: t0 + h - r[2]))
        p.addArc(tangent1End: CGPoint(x: s0 + w, y: t0 + h), tangent2End: CGPoint(x: s0 + w - r[2], y: t0 + h), radius: r[2])
        p.addLine(to: CGPoint(x: s0 + r[3], y: t0 + h))
        p.addArc(tangent1End: CGPoint(x: s0, y: t0 + h), tangent2End: CGPoint(x: s0, y: t0 + h - r[3]), radius: r[3])
        p.addLine(to: CGPoint(x: s0, y: t0 + r[0]))
        p.addArc(tangent1End: CGPoint(x: s0, y: t0), tangent2End: CGPoint(x: s0 + r[0], y: t0), radius: r[0])
        p.closeSubpath()
        return p
    }

    private static func path(of q: GateQuad) -> CGPath {
        if q.sign < -1.5 {
            return CGPath(ellipseIn: CGRect(x: q.pts[0] - q.pts[2], y: q.pts[1] - q.pts[3],
                                            width: 2 * q.pts[2], height: 2 * q.pts[3]), transform: nil)
        }
        let p = CGMutablePath()
        p.move(to: CGPoint(x: q.pts[0], y: q.pts[1]))
        for i in stride(from: 2, to: 8, by: 2) { p.addLine(to: CGPoint(x: q.pts[i], y: q.pts[i + 1])) }
        p.closeSubpath()
        guard q.round > 0 else { return p }
        // The engine rounds a quad by growing it `round` all the way about.
        let grown = p.copy(strokingWithWidth: 2 * q.round, lineCap: .round, lineJoin: .round, miterLimit: 1)
        return p.union(grown)
    }

    /// The perforations on this piece of film, both rows.
    var holes: [CGRect] {
        guard perforated else { return [] }
        var out: [CGRect] = []
        var k = Int(floor((sLo - 6 - perfPhase) / Self.perfPitch))
        while perfPhase + Double(k) * Self.perfPitch < sHi + 6 {
            let s = perfPhase + Double(k) * Self.perfPitch
            for t in [Self.perfEdge, filmW - Self.perfEdge - Self.perfH] {
                out.append(CGRect(x: s, y: t, width: Self.perfW, height: Self.perfH))
            }
            k += 1
        }
        return out
    }

    var holesPath: Path {
        var p = Path()
        for r in holes { p.addRoundedRect(in: r, cornerSize: CGSize(width: Self.perfR, height: Self.perfR)) }
        return p
    }

    /// Marks as one outline, in film millimetres: text through CoreText, as
    /// the engine rasterises it. Its text matrix is `scale(hscale, −1)`, and
    /// CoreText puts each glyph at its own position in *user* space: the
    /// outlines are widened, the advances between them are not. (Held against
    /// the engine's render by `tools/film_edge_parity.py`: with the advances
    /// widened too, the `A` of `5A` sat 0.23 mm late.) A mark that scales its
    /// advances is drawn by the engine under `scale(hscale, 1)` with a plain
    /// text matrix, so there the positions are widened with the outlines.
    static func outline(_ marks: [FilmMark]) -> Path {
        let out = CGMutablePath()
        for mark in marks {
            switch mark {
            case .poly(let pts):
                guard pts.count >= 6 else { continue }
                out.move(to: CGPoint(x: pts[0], y: pts[1]))
                for i in stride(from: 2, to: pts.count - 1, by: 2) { out.addLine(to: CGPoint(x: pts[i], y: pts[i + 1])) }
                out.closeSubpath()
            case .circle(let s, let t, let r):
                out.addEllipse(in: CGRect(x: s - r, y: t - r, width: 2 * r, height: 2 * r))
            case .text(let tx):
                let glyphs = EdgeType.glyphs(tx.text, font: tx.font, sizeMM: tx.sizeMM, trackingMM: tx.trackingMM,
                                             hscale: tx.hscale, scaleAdvances: tx.scaleAdvances)
                out.addPath(glyphs, transform: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: tx.s, ty: tx.t))
            }
        }
        return Path(out)
    }

    var edgeOutline: Path { Self.outline(edge) }
    var dateOutline: Path { Self.outline(date) }
}

// MARK: - type, as the engine sets it

/// Helvetica through CoreText: the same C API on macOS and the operating system, so the host
/// gets the glyphs the engine rasterises.
enum EdgeType {
    private static func line(_ text: String, font: String, sizeMM: Double, trackingMM: Double) -> CTLine {
        let ct = CTFontCreateWithName(font as CFString, sizeMM, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): ct,
            NSAttributedString.Key(kCTKernAttributeName as String): trackingMM,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    /// A string's advance in film millimetres, as CoreText lays it out.
    static func width(_ text: String, font: String, sizeMM: Double, trackingMM: Double, hscale: Double) -> Double {
        CTLineGetTypographicBounds(line(text, font: font, sizeMM: sizeMM, trackingMM: trackingMM), nil, nil, nil) * hscale
    }

    /// The string's outlines, baseline at y = 0, y up, in millimetres: each
    /// glyph widened by `hscale` about its own origin, at its own advance —
    /// or, with `scaleAdvances`, the whole line widened, advances and all.
    static func glyphs(_ text: String, font: String, sizeMM: Double, trackingMM: Double, hscale: Double = 1,
                       scaleAdvances: Bool = false) -> CGPath {
        let out = CGMutablePath()
        let runs = CTLineGetGlyphRuns(line(text, font: font, sizeMM: sizeMM, trackingMM: trackingMM)) as? [CTRun] ?? []
        for run in runs {
            let n = CTRunGetGlyphCount(run)
            guard n > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var positions = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &positions)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName as String] else { continue }
            let runFont = value as! CTFont
            for i in 0..<n {
                if let g = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) {
                    out.addPath(g, transform: CGAffineTransform(a: hscale, b: 0, c: 0, d: 1,
                                                                tx: (scaleAdvances ? hscale : 1) * positions[i].x,
                                                                ty: positions[i].y))
                }
            }
        }
        return out
    }
}

/// The 5 × 7 dot-matrix face (rows top to bottom, bit 4 = the left column):
/// the data backs, the dot-matrix date backs and Eastman's edge printer use
/// one, and it is the skeleton of Fujifilm's 120 print (`DotFaces.matrix57`).
enum Face5x7 {
    static let glyphs: [UInt8: [UInt8]] = {
        let table: [(Character, [UInt8])] = [
            ("0", [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E]), ("1", [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E]),
            ("2", [0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F]), ("3", [0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E]),
            ("4", [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02]), ("5", [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E]),
            ("6", [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E]), ("7", [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08]),
            ("8", [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E]), ("9", [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C]),
            ("A", [0x0E, 0x11, 0x11, 0x11, 0x1F, 0x11, 0x11]), ("B", [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E]),
            ("C", [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E]), ("D", [0x1C, 0x12, 0x11, 0x11, 0x11, 0x12, 0x1C]),
            ("E", [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F]), ("F", [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10]),
            ("G", [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F]), ("H", [0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11]),
            ("I", [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E]), ("J", [0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C]),
            ("K", [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11]), ("L", [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F]),
            ("M", [0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11]), ("N", [0x11, 0x11, 0x19, 0x15, 0x13, 0x11, 0x11]),
            ("O", [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E]), ("P", [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10]),
            ("Q", [0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D]), ("R", [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11]),
            ("S", [0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E]), ("T", [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04]),
            ("U", [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E]), ("V", [0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04]),
            ("W", [0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A]), ("X", [0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11]),
            ("Y", [0x11, 0x11, 0x11, 0x0A, 0x04, 0x04, 0x04]), ("Z", [0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F]),
            ("m", [0x00, 0x00, 0x1A, 0x15, 0x15, 0x11, 0x11]), ("v", [0x00, 0x00, 0x11, 0x11, 0x11, 0x0A, 0x04]),
            ("s", [0x00, 0x00, 0x0E, 0x10, 0x0E, 0x01, 0x1E]), (".", [0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C]),
            ("/", [0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x00]), ("-", [0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00]),
            ("+", [0x00, 0x04, 0x04, 0x1F, 0x04, 0x04, 0x00]), (":", [0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x0C, 0x00]),
            ("'", [0x0C, 0x04, 0x08, 0x00, 0x00, 0x00, 0x00]), ("(", [0x02, 0x04, 0x08, 0x08, 0x08, 0x04, 0x02]),
            (")", [0x08, 0x04, 0x02, 0x02, 0x02, 0x04, 0x08]),
        ]
        var out: [UInt8: [UInt8]] = [:]
        for (c, rows) in table { out[c.asciiValue!] = rows }
        return out
    }()

    static func glyph(_ ch: UInt8) -> [UInt8]? {
        if let g = glyphs[ch] { return g }
        if ch >= 97 && ch <= 122 { return glyphs[ch - 32] }       // a…z → A…Z
        return nil
    }

    /// An edge printer's 0 has no slash (the date backs' does).
    static let plainZero: [UInt8] = [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E]

    /// Lay `text` out, character height `h` (7 rows), the baseline's left at
    /// (0, 0), y up; each lit cell is handed to `emit(x, y, pitch)` at its
    /// centre. Returns the width.
    @discardableResult
    static func dots(_ text: String, h: Double, emit: (Double, Double, Double) -> Void) -> Double {
        let pitch = h / 7.0
        var x = 0.0
        for ch in text.utf8 {
            if ch == 32 { x += 4.0 * pitch; continue }
            guard let g = glyph(ch) else { x += 4.0 * pitch; continue }
            for row in 0..<7 {
                for col in 0..<5 where g[row] & (0x10 >> UInt8(col)) != 0 {
                    emit(x + (Double(col) + 0.5) * pitch, (Double(6 - row) + 0.5) * pitch, pitch)
                }
            }
            x += 6.0 * pitch
        }
        return max(0.0, x - pitch)
    }

    /// The face as an edge printer's (the Eastman line; Fujifilm's print has
    /// faces of its own, `DotFaces`): each lit run of cells along a row is one
    /// rectangle, cells `xscale` times as wide as tall; `bold` widens every
    /// stroke by one cell to the right. Left at `s0`, baseline at `baseT`,
    /// glyphs up (toward smaller t). Returns the width; `out` nil only measures.
    @discardableResult
    static func matrix(_ text: String, cap: Double, xscale: Double, bold: Bool, s0: Double, baseT: Double,
                       out: UnsafeMutablePointer<[FilmMark]>?) -> Double {
        let p = cap / 7.0, cw = p * xscale, ov = 0.02 * p
        let ncol = bold ? 6 : 5
        var x = 0.0
        for ch in text.utf8 {
            let g = ch == 48 ? plainZero : glyph(ch)
            guard ch != 32, let g else { x += 4.0 * cw; continue }
            if let out {
                for row in 0..<7 {
                    let bits: UInt = bold ? ((UInt(g[row]) << 1) | UInt(g[row])) : UInt(g[row])
                    let top: UInt = bold ? 0x20 : 0x10
                    var c = 0
                    while c < ncol {
                        if bits & (top >> UInt(c)) == 0 { c += 1; continue }
                        var e = c
                        while e < ncol && bits & (top >> UInt(e)) != 0 { e += 1 }
                        let sa = s0 + x + Double(c) * cw - ov, sb = s0 + x + Double(e) * cw + ov
                        let ta = baseT - Double(7 - row) * p - ov, tb = baseT - Double(6 - row) * p + ov
                        out.pointee.append(.poly([sa, ta, sb, ta, sb, tb, sa, tb]))
                        c = e
                    }
                }
            }
            x += Double(ncol + 1) * cw
        }
        return max(0.0, x - cw)
    }
}

/// One of Fujifilm's dot faces: a glyph's cells, the dots from one character
/// to the next, and the glyph at `text[i]` as rows of `#` and `.` — nil where
/// the face has none — moving `i` past what it read (`DotFace`).
struct DotFace: Sendable {
    let ncol: Int, nrow: Int, advance: Int
    let glyph: @Sendable (_ text: [UInt8], _ i: inout Int) -> [String]?
}

/// Fujifilm's edge print is a dot matrix: one printer, one grid of dots, and
/// every mark on the film — names, numbers, the arrow, 120's marker — is a
/// pattern of those dots, each drawn as a disc. The faces are the engine's
/// (`overscan.cpp`, `names_glyph` to `dot_text`), read off the owner's strips
/// dot by dot on the desktop (2026-10-04): the dots are 0.1155 mm apart along
/// the film and 0.0984 mm across it.
///
/// The tables are the engine's by copy, not by hand, and
/// `tools/film_edge_parity.py` holds every row of them against the engine's
/// source as well as the marks against its render.
enum DotFaces {
    /// The dots' spacing along the film and across it, mm (`kDotS`, `kDotT`).
    static let dotS = 0.1155, dotT = 0.0984

    static let names = DotFace(ncol: 7, nrow: 9, advance: 9) { text, i in
        if closesWithIII(text, i) { i += 3; return namesRoman3 }
        if standsAsII(text, i) { i += 2; return namesRoman2 }
        let ch = text[i]
        i += 1
        return namesGlyphs[ch >= 97 && ch <= 122 ? ch - 32 : ch]
    }
    static let numbers = DotFace(ncol: 12, nrow: 16, advance: 14) { text, i in
        let ch = text[i]
        i += 1
        return numbersGlyphs[ch == 97 ? 65 : ch]              // the digits, and A
    }
    static let small = DotFace(ncol: 8, nrow: 12, advance: 10) { text, i in
        let ch = text[i]
        i += 1
        return smallGlyphs[ch == 97 ? 65 : ch]
    }
    static let tiny = DotFace(ncol: 3, nrow: 5, advance: 4) { text, i in
        let ch = text[i]
        i += 1
        return ch >= 48 && ch <= 57 ? tinyTable[Int(ch - 48)] : nil
    }
    /// Fujifilm's 120 print is the plain 5 × 7 matrix — the date back's
    /// skeleton, zero slashed — with a square D and `III` as three plain
    /// strokes in one cell (`matrix57_glyph`). A `II` is two letters here:
    /// the engine's one-cell `II` is the names' face only.
    static let matrix57 = DotFace(ncol: 5, nrow: 7, advance: 6) { text, i in
        if closesWithIII(text, i) { i += 3; return matrixRoman3 }
        let ch = text[i]
        i += 1
        if ch == 68 || ch == 100 { return matrixSquareD }
        return matrixGlyphs[ch] ?? (ch >= 97 && ch <= 122 ? matrixGlyphs[ch - 32] : nil)
    }

    /// `III` closing a word is the film's one-cell numeral: `FUJI RDPIII`
    /// prints `RDP` and one glyph.
    static func closesWithIII(_ t: [UInt8], _ i: Int) -> Bool {
        i + 3 <= t.count && t[i] == 73 && t[i + 1] == 73 && t[i + 2] == 73
            && (i + 3 == t.count || t[i + 3] == 32) && i > 0 && t[i - 1] != 32 && t[i - 1] != 73
    }

    /// `II` standing as a word is one cell too: `FUJI 100 ACROS II` prints
    /// its last word as one glyph (the names' face; the Acros II strip).
    static func standsAsII(_ t: [UInt8], _ i: Int) -> Bool {
        i + 2 <= t.count && t[i] == 73 && t[i + 1] == 73
            && (i + 2 == t.count || t[i + 2] == 32) && i > 0 && t[i - 1] == 32
    }

    /// A pattern of dots: rows of `#`, its top-left dot's centre at (s0, t0),
    /// the dots `ps` mm apart along the film and `pt` across it, each a disc
    /// `d` mm across (`dot_rows`).
    static func rows(_ rows: [String], nrow: Int, ncol: Int, s0: Double, t0: Double, ps: Double, pt: Double,
                     d: Double, out: inout [FilmMark]) {
        for (r, row) in rows.prefix(nrow).enumerated() {
            for (c, cell) in row.utf8.prefix(ncol).enumerated() where cell == 35 {
                out.append(.circle(s: s0 + Double(c) * ps, t: t0 + Double(r) * pt, r: 0.5 * d))
            }
        }
    }

    /// `text` in a dot face: the ink's left edge at `s0`, its foot on `baseT`,
    /// glyphs toward smaller t; a word space is `space` dots. A character the
    /// face lacks takes its place and prints nothing. Returns the ink's
    /// length; `out` nil only measures (`dot_text`).
    @discardableResult
    static func text(_ text: [UInt8], _ f: DotFace, ps: Double, pt: Double, d: Double, space: Double,
                     s0: Double, baseT: Double, out: UnsafeMutablePointer<[FilmMark]>?) -> Double {
        var x = 0.0
        var i = 0
        while i < text.count {
            if text[i] == 32 { x += space * ps; i += 1; continue }
            let g = f.glyph(text, &i)
            if let g, let out {
                rows(g, nrow: f.nrow, ncol: f.ncol, s0: s0 + x + 0.5 * d, t0: baseT - 0.5 * d - Double(f.nrow - 1) * pt,
                     ps: ps, pt: pt, d: d, out: &out.pointee)
            }
            x += Double(f.advance) * ps
        }
        return max(0.0, x - Double(f.advance - f.ncol + 1) * ps + d)
    }

    private static func lookup(_ table: [(Character, [String])]) -> [UInt8: [String]] {
        var out: [UInt8: [String]] = [:]
        for (c, rows) in table { out[c.asciiValue!] = rows }
        return out
    }
    private static func rows(of bits: [UInt8]) -> [String] {
        bits.map { b in String((0..<5).map { b & (0x10 >> UInt8($0)) != 0 ? "#" : "." }) }
    }
    private static let namesGlyphs = lookup(namesTable)
    private static let numbersGlyphs = lookup(numbersTable)
    private static let smallGlyphs = lookup(smallTable)
    private static let matrixGlyphs = Face5x7.glyphs.mapValues(rows(of:))
    static let matrixRoman3 = rows(of: [0x15, 0x15, 0x15, 0x15, 0x15, 0x15, 0x15])
    static let matrixSquareD = rows(of: [0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E])

    /// The names' face, 7 × 9, strokes one dot wide (`names_glyph`).
    static let namesTable: [(Character, [String])] = [
        ("A", ["...#...", "..#.#..", ".#...#.", "#.....#", "#.....#", "#######", "#.....#", "#.....#", "#.....#"]),
        ("B", ["######.", "#.....#", "#.....#", "#.....#", "######.", "#.....#", "#.....#", "#.....#", "######."]),
        ("C", [".#####.", "#.....#", "#......", "#......", "#......", "#......", "#......", "#.....#", ".#####."]),
        ("D", ["#####..", ".#...#.", ".#....#", ".#....#", ".#....#", ".#....#", ".#....#", ".#...#.", "#####.."]),
        ("E", ["#######", "#......", "#......", "#......", "#####..", "#......", "#......", "#......", "#######"]),
        ("F", ["#######", "#......", "#......", "#......", "#####..", "#......", "#......", "#......", "#......"]),
        ("G", [".#####.", "#.....#", "#......", "#......", "#..####", "#.....#", "#.....#", "#.....#", ".#####."]),
        ("H", ["#.....#", "#.....#", "#.....#", "#.....#", "#######", "#.....#", "#.....#", "#.....#", "#.....#"]),
        ("I", [".###...", "..#....", "..#....", "..#....", "..#....", "..#....", "..#....", "..#....", ".###..."]),
        ("J", ["....###", ".....#.", ".....#.", ".....#.", ".....#.", ".....#.", "#....#.", ".#..#..", "..##..."]),
        ("K", ["#.....#", "#....#.", "#...#..", "#..#...", "###....", "#..#...", "#...#..", "#....#.", "#.....#"]),
        ("L", ["#......", "#......", "#......", "#......", "#......", "#......", "#......", "#......", "#######"]),
        ("M", ["#.....#", "##...##", "#.#.#.#", "#..#..#", "#..#..#", "#.....#", "#.....#", "#.....#", "#.....#"]),
        ("N", ["#.....#", "##....#", "#.#...#", "#.#...#", "#..#..#", "#...#.#", "#...#.#", "#....##", "#.....#"]),
        ("O", [".#####.", "#.....#", "#.....#", "#.....#", "#.....#", "#.....#", "#.....#", "#.....#", ".#####."]),
        ("P", ["######.", "#.....#", "#.....#", "#.....#", "######.", "#......", "#......", "#......", "#......"]),
        ("Q", [".#####.", "#.....#", "#.....#", "#.....#", "#.....#", "#.....#", "#...#.#", "#....#.", ".####.#"]),
        ("R", ["######.", "#.....#", "#.....#", "#.....#", "######.", "#..#...", "#...#..", "#....#.", "#.....#"]),
        ("S", [".#####.", "#.....#", "#......", "#......", ".#####.", "......#", "......#", "#.....#", ".#####."]),
        ("T", ["#######", "...#...", "...#...", "...#...", "...#...", "...#...", "...#...", "...#...", "...#..."]),
        ("U", ["#.....#", "#.....#", "#.....#", "#.....#", "#.....#", "#.....#", "#.....#", ".#...#.", "..###.."]),
        ("V", ["#.....#", "#.....#", "#.....#", ".#...#.", ".#...#.", "..#.#..", "..#.#..", "...#...", "...#..."]),
        ("W", ["#.....#", "#.....#", "#.....#", "#.....#", "#..#..#", "#..#..#", "#.#.#.#", "##...##", "#.....#"]),
        ("X", ["#.....#", "#.....#", ".#...#.", "..#.#..", "...#...", "..#.#..", ".#...#.", "#.....#", "#.....#"]),
        ("Y", ["#.....#", "#.....#", ".#...#.", "..#.#..", "...#...", "...#...", "...#...", "...#...", "...#..."]),
        ("Z", ["#######", "......#", ".....#.", "....#..", "...#...", "..#....", ".#.....", "#......", "#######"]),
        ("0", [".#####.", "#.....#", "#.....#", "#.....#", "#.....#", "#.....#", "#.....#", "#.....#", ".#####."]),
        ("1", ["...#...", "..##...", ".#.#...", "...#...", "...#...", "...#...", "...#...", "...#...", ".#####."]),
        ("2", [".#####.", "#.....#", "......#", ".....#.", "....#..", "...#...", "..#....", ".#.....", "#######"]),
        ("3", [".#####.", "#.....#", "......#", "......#", "..####.", "......#", "......#", "#.....#", ".#####."]),
        ("4", [".....#.", "....##.", "...#.#.", "..#..#.", ".#...#.", "#....#.", "#######", ".....#.", ".....#."]),
        ("5", ["#######", "#......", "#......", "#......", "######.", "......#", "......#", "#.....#", ".#####."]),
        ("6", [".#####.", "#.....#", "#......", "#......", "######.", "#.....#", "#.....#", "#.....#", ".#####."]),
        ("7", ["#######", "......#", ".....#.", "....#..", "...#...", "...#...", "..#....", "..#....", "..#...."]),
        ("8", [".#####.", "#.....#", "#.....#", "#.....#", ".#####.", "#.....#", "#.....#", "#.....#", ".#####."]),
        ("9", [".#####.", "#.....#", "#.....#", "#.....#", ".######", "......#", "......#", "#.....#", ".#####."]),
        ("-", [".......", ".......", ".......", ".......", ".#####.", ".......", ".......", ".......", "......."]),
        ("+", [".......", "...#...", "...#...", "...#...", "#######", "...#...", "...#...", "...#...", "......."]),
        (".", [".......", ".......", ".......", ".......", ".......", ".......", ".......", "..##...", "..##..."]),
        ("/", ["......#", ".....#.", ".....#.", "....#..", "...#...", "..#....", ".#.....", ".#.....", "#......"]),
    ]
    static let namesRoman3 = ["#######", ".#.#.#.", ".#.#.#.", ".#.#.#.", ".#.#.#.", ".#.#.#.", ".#.#.#.", ".#.#.#.", "#######"]
    static let namesRoman2 = ["#######", ".#...#.", ".#...#.", ".#...#.", ".#...#.", ".#...#.", ".#...#.", ".#...#.", "#######"]

    /// The frame numbers' face, 12 × 16, stems three dots wide (`numbers_glyph`).
    static let numbersTable: [(Character, [String])] = [
        ("0", ["..########..", ".##########.", "############", "####....####", "###......###", "###......###", "###......###", "###......###",
                  "###......###", "###......###", "###......###", "###......###", "####....####", "############", ".##########.", "..########.."]),
        ("1", [".....###....", "....####....", "...#####....", "..######....", "..######....", ".....###....", ".....###....", ".....###....",
                  ".....###....", ".....###....", ".....###....", ".....###....", ".....###....", "..#########.", "..#########.", "..#########."]),
        ("2", ["..########..", ".##########.", "############", "####....####", "###......###", ".........###", "........####", ".......####.",
                  ".....#####..", "...#####....", "..#####.....", ".####.......", "####........", "############", "############", "############"]),
        ("3", ["..########..", ".##########.", "############", "####....####", "###......###", ".........###", "........####", "....#######.",
                  "....#######.", "........####", ".........###", "###......###", "####....####", "############", ".##########.", "..########.."]),
        ("4", [".......###..", "......####..", ".....#####..", "....######..", "...#######..", "..####.###..", ".####..###..", "####...###..",
                  "###....###..", "###....###..", "###....###..", "############", "############", "############", ".......###..", ".......###.."]),
        ("5", ["############", "############", "############", "###.........", "###.........", "###.........", "##########..", "###########.",
                  "############", "........####", ".........###", "###......###", "####....####", "############", ".##########.", "..########.."]),
        ("6", ["..########..", ".##########.", "############", "####....####", "###......###", "###.........", "##########..", "###########.",
                  "############", "####....####", "###......###", "###......###", "####....####", "############", ".##########.", "..########.."]),
        ("7", ["############", "############", "############", ".........###", ".........###", "........####", ".......####.", "......####..",
                  "......####..", ".....####...", ".....####...", "....####....", "....####....", "....####....", "....####....", "....####...."]),
        ("8", ["..########..", ".##########.", "############", "####....####", "###......###", "####....####", ".##########.", ".##########.",
                  "############", "####....####", "###......###", "###......###", "####....####", "############", ".##########.", "..########.."]),
        ("9", ["..########..", ".##########.", "############", "####....####", "###......###", "###......###", "####....####", "############",
                  ".###########", "..##########", ".........###", "###......###", "####....####", "############", ".##########.", "..########.."]),
        ("A", ["....####....", "...######...", "..########..", ".####..####.", "####....####", "###......###", "###......###", "###......###",
                  "###......###", "############", "############", "############", "###......###", "###......###", "###......###", "###......###"]),
    ]

    /// The half frame's `36A` and X-Tra 400's numbers: 8 × 12, strokes two dots wide (`small_numbers_glyph`).
    static let smallTable: [(Character, [String])] = [
        ("0", [".######.", "########", "##....##", "##....##", "##....##", "##....##", "##....##", "##....##", "##....##", "##....##", "########", ".######."]),
        ("1", ["...##...", "..###...", ".####...", "...##...", "...##...", "...##...", "...##...", "...##...", "...##...", "...##...", ".######.", ".######."]),
        ("2", [".######.", "########", "##....##", "......##", ".....###", "....###.", "...###..", "..###...", ".###....", "###.....", "########", "########"]),
        ("3", [".######.", "########", "##....##", "......##", "......##", "..######", "..######", "......##", "......##", "##....##", "########", ".######."]),
        ("4", [".....###", "....####", "...#####", "..######", ".###.###", "###..###", "###..###", "###..###", "########", "########", ".....###", ".....###"]),
        ("5", ["########", "########", "##......", "##......", "#######.", "########", "......##", "......##", "......##", "##....##", "########", ".######."]),
        ("6", [".######.", "########", "##....##", "##......", "##......", "#######.", "########", "##....##", "##....##", "##....##", "########", ".######."]),
        ("7", ["########", "########", "......##", "......##", ".....###", "....###.", "....##..", "...###..", "...##...", "...##...", "...##...", "...##..."]),
        ("8", [".######.", "########", "##....##", "##....##", "##....##", ".######.", ".######.", "##....##", "##....##", "##....##", "########", ".######."]),
        ("9", [".######.", "########", "##....##", "##....##", "##....##", "########", ".#######", "......##", "......##", "##....##", "########", ".######."]),
        ("A", ["...##...", "..####..", ".######.", "###..###", "##....##", "##....##", "########", "########", "##....##", "##....##", "##....##", "##....##"]),
    ]

    /// The roll's length before the arrow (`36`): 3 × 5 dots (`tiny_glyph`).
    static let tinyTable: [[String]] = [
        ["###", "#.#", "#.#", "#.#", "###"],
        [".#.", "##.", ".#.", ".#.", "###"],
        ["###", "..#", "###", "#..", "###"],
        ["###", "..#", ".##", "..#", "###"],
        ["#.#", "#.#", "###", "..#", "..#"],
        ["###", "#..", "###", "..#", "###"],
        [".##", "#..", "###", "#.#", "###"],
        ["###", "..#", ".#.", ".#.", ".#."],
        ["###", "#.#", "###", "#.#", "###"],
        ["###", "#.#", "###", "..#", "##."],
    ]

    /// The slides' arrow: 22 dots across, 12 down (`kArrow`).
    static let arrow = [
        "#############.........", "###############.......", "##.........######.....", "##...........######...",
        "##.............######.", "##...............#####", "##...............#####", "##.............######.",
        "##...........######...", "##.........######.....", "###############.......", "#############.........",
    ]

    /// Fujifilm 120's marker, a tack: 13 dots across, 7 down (`kTack`).
    static let tack = ["..........###", "......#######", "...##########", "#############", "...##########", "......#######", "..........###"]
}

/// The DX film-edge bar code (ISO 1007, frame-number version): 31 modules.
/// Bits: [0] 0, [1…7] DX part 1, [8] 0, [9…12] DX part 2, [13…18] the frame
/// number, [19] half frame, [20] 0, [21] parity, [22] 0.
enum DXBars {
    static func bits(dx: Int, frame: Int, half: Bool) -> [Int] {
        var bits = [Int](repeating: 0, count: 23)
        let p1 = (dx >> 4) & 0x7F, p2 = dx & 0xF
        for i in 0..<7 { bits[1 + i] = (p1 >> (6 - i)) & 1 }
        for i in 0..<4 { bits[9 + i] = (p2 >> (3 - i)) & 1 }
        let f = min(max(frame, 0), 63)
        for i in 0..<6 { bits[13 + i] = (f >> (5 - i)) & 1 }
        bits[19] = half ? 1 : 0
        bits[21] = bits[0..<21].reduce(0, +) % 2
        return bits
    }

    /// The clock track (nearer the perforations) and the data track, as 31
    /// modules each.
    static func tracks(_ bits: [Int]) -> (clock: [Int], data: [Int]) {
        var clock = [Int](repeating: 0, count: 31), data = [Int](repeating: 0, count: 31)
        for i in 0..<31 {
            clock[i] = (i < 5 || i >= 28) ? 1 : ((i - 5) % 2)
            data[i] = i < 5 ? (i % 2 == 0 ? 1 : 0) : (i >= 28 ? ((i - 28) % 2 == 0 ? 1 : 0) : bits[i - 5])
        }
        return (clock, data)
    }

    /// "96-12": the code as film people write it, part 1 and part 2.
    static func text(_ dx: Int) -> String { "\((dx >> 4) & 0x7F)-\(dx & 0xF)" }
}

/// The seven-segment face of the quartz date back: glyph units, digit height
/// `h`, baseline at 0, y up; `skew` is the slant.
enum SevenSegmentFace {
    private static let segments = ["abcdef", "bc", "abged", "abgcd", "fgbc", "afgcd", "afgedc", "abc", "abcdefg", "abcdfg"]

    /// Each lit segment as four (x, y) corners.
    static func polys(_ text: String, h: Double, skew: Double) -> [[CGPoint]] {
        let w = 0.52 * h, th = 0.14 * h
        var x = 0.0
        var out: [[CGPoint]] = []
        func rect(_ x0: Double, _ y0: Double, _ ww: Double, _ hh: Double) {
            let xs = [x0, x0 + ww, x0 + ww, x0], ys = [y0, y0, y0 + hh, y0 + hh]
            out.append((0..<4).map { CGPoint(x: xs[$0] + skew * ys[$0], y: ys[$0]) })
        }
        for ch in text.utf8 {
            if ch == 32 { x += 0.45 * h; continue }
            if ch == 39 { rect(x, 0.72 * h, th, 0.28 * h); x += 0.35 * h; continue }
            if ch < 48 || ch > 57 { x += 0.45 * h; continue }
            let gap = 0.6 * th
            for seg in segments[Int(ch - 48)] {
                switch seg {
                case "a": rect(x + gap, h - th, w - 2 * gap, th)
                case "g": rect(x + gap, 0.5 * h - 0.5 * th, w - 2 * gap, th)
                case "d": rect(x + gap, 0.0, w - 2 * gap, th)
                case "f": rect(x, 0.5 * h + 0.3 * th, th, 0.5 * h - 0.9 * th)
                case "b": rect(x + w - th, 0.5 * h + 0.3 * th, th, 0.5 * h - 0.9 * th)
                case "e": rect(x, 0.6 * th, th, 0.5 * h - 0.9 * th)
                case "c": rect(x + w - th, 0.6 * th, th, 0.5 * h - 0.9 * th)
                default: break
                }
            }
            x += w + 0.28 * h
        }
        return out
    }

    static func width(_ text: String, h: Double) -> Double {
        var x = 0.0
        for ch in text.utf8 {
            if ch == 32 { x += 0.45 * h } else if ch == 39 { x += 0.35 * h } else { x += 0.52 * h + 0.28 * h }
        }
        return max(0.0, x - 0.28 * h)
    }
}
