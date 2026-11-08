//  FilmLayout.swift — the engine's overscan layout, ported statement for statement.
//
//  `Pipeline::overscan_layout`, `gate_shape` and `imprint_groups`
//  (`engine/src/pipeline/overscan.cpp` in this repository: the desktop's at
//  `unpublished-revision`, its 1.3.1, and the black-and-white films' edges synced on
//  2026-10-09). Read beside that file: the order of every random
//  draw is the engine's, because a draw moved is a hole, a gate or a number
//  moved. Comments name the engine's own measurements only where a number
//  would otherwise look arbitrary.
//
//  See `FilmGeometry.swift` for what this is a stand-in for and how it is kept
//  honest. It never runs on the picture's pixels.

import CoreGraphics
import Foundation

/// Where a film's geometry comes from. Today the port below; with the engine
/// linked, its own geometry call — and then nothing above this line changes.
protocol FilmGeometrySource: Sendable {
    /// Nil when the engine would refuse the frame: it is not the gate's shape.
    func geometry(_ request: FilmEdgeRequest) -> FilmGeometry?
    /// A date on the bare frame, with no film edge: its marks in the picture's
    /// own millimetres (x right, y down), and the millimetres per pixel.
    func dateAlone(_ date: DateRequest, camera: FilmEdgeFormat, frame: PixelSize, longEdgeMM: Double) -> (marks: [FilmMark], px: Double)
}

struct PortedFilmGeometry: FilmGeometrySource {
    func geometry(_ request: FilmEdgeRequest) -> FilmGeometry? { FilmLayout.layout(request) }
    func dateAlone(_ date: DateRequest, camera: FilmEdgeFormat, frame: PixelSize, longEdgeMM: Double) -> (marks: [FilmMark], px: Double) {
        FilmLayout.dateAlone(date, camera: camera, frame: frame, longEdgeMM: longEdgeMM)
    }
}

enum FilmLayout {
    private typealias Rng = SplitMix64

    // MARK: the layout

    static func layout(_ r: FilmEdgeRequest) -> FilmGeometry? {
        let fmt = r.format
        let frameW = max(1, r.frame.width), frameH = max(1, r.frame.height)

        // The frame is the gate: its long edge is the format's, and its shape
        // has to be the gate's, either way up.
        let gateLong = max(fmt.alongMM, fmt.acrossMM), gateShort = min(fmt.alongMM, fmt.acrossMM)
        let frameLong = Double(max(frameW, frameH)), frameShort = Double(max(1, min(frameW, frameH)))
        guard abs((frameLong / frameShort) / (gateLong / gateShort) - 1.0) <= 0.05 else { return nil }

        var L = FilmGeometry(request: r)
        // By the engine's own two steps — micrometres a pixel, then millimetres
        // (`pixel_size_um_ = long_mm * 1000 / long_edge`, `L.px = pixel_size_um_ / 1000`)
        // — not by one division: the two differ in the last bit, and the canvas
        // is a rounding of a length over this. A half frame 1,404 px tall puts
        // the film's 35 mm at 2,047.5 px, which the engine rounds to 2,048 and a
        // single division rounded to 2,047 (seen in an export, 2026-10-08).
        L.px = gateLong * 1000.0 / frameLong / 1000.0
        let imgW = Double(frameW) * L.px, imgH = Double(frameH) * L.px
        // The film runs along the image axis whose size is *not* the format's
        // across-the-film size. Square frames run horizontally.
        L.vertical = abs(imgW - fmt.acrossMM) < abs(imgH - fmt.acrossMM) && abs(imgW - imgH) > 1e-6
        L.gateAlong = L.vertical ? imgH : imgW
        L.gateAcross = L.vertical ? imgW : imgH

        let cam = UInt64(UInt32(truncatingIfNeeded: r.cameraSeed)), frm = UInt64(UInt32(truncatingIfNeeded: r.frameSeed))
        var rc = Rng(Rng.stream(cam, .camera, 1)), rf = Rng(Rng.stream(frm ^ (cam << 32), .frame, 1))

        // --- film and gate
        L.perforated = fmt.isPerforated
        L.filmW = fmt.filmWidthMM + (fmt.isPerforated ? 0.0 : rc.uni(-0.15, 0.15))
        let tOff = (fmt.isPerforated ? rc.uni(-0.10, 0.10) : rc.uni(-0.45, 0.45)) + rf.normal() * 0.025
        L.gateT0 = 0.5 * (L.filmW - L.gateAcross) + tOff
        L.gateS0 = 0.0
        for _ in 0..<4 {
            for _ in 0..<3 {
                _ = rc.normal()                     // the gate's wobble: drawn, not kept
                _ = rc.uni(0.0, 2.0 * .pi)
            }
        }
        let gateGap = rc.uni(0.18, 0.40)
        let n = r.fNumber > 0.5 ? r.fNumber : 5.6
        L.penumbra = gateGap / (2.0 * n)

        // --- the gate's shape: its own stream
        var rg = Rng(Rng.stream(cam, .camera, 2))
        var family = r.gate
        if family == .auto {
            let fams = fmt.families
            family = fams[Int(rg.uni(0.0, Double(fams.count))) % fams.count]
        }
        gateShape(&L, family, &rg)

        // --- perforations: the frame's place on the grid is the camera's
        if L.perforated {
            L.perfPhase = min(max(-3.3 + rc.uni(-0.7, 0.7) + rf.normal() * 0.08, -4.1), -2.6)
        }

        // --- canvas
        let marginAlong: Double
        if r.mode == .strip {
            if fmt.isPerforated {
                marginAlong = fmt.alongMM < 20.0 ? rc.uni(0.40, 0.50) : rc.uni(0.75, 0.95)
            } else {
                let a = rc.uni(1.3, 2.1)
                marginAlong = a + rf.uni(-0.25, 0.25)
            }
            // A strip scan ends at the film's long edges: the engine's `reach`
            // under `overscan_carrier` = `none`, its default and the only
            // carrier the host has (it does not send the field). The canvas
            // is the film's width, and where the scan's tilt carries a corner
            // past the film's edge the film is drawn on.
            L.tLo = 0.0
            L.tHi = L.filmW
        } else {
            marginAlong = 0.9 + rf.uni(-0.1, 0.1)
            L.tLo = L.gateT0 - 1.1
            L.tHi = L.gateT0 + L.gateAcross + 1.1
        }
        let mPx = Int((marginAlong / L.px).rounded())
        let alongPx = (L.vertical ? frameH : frameW) + 2 * mPx
        let acrossPx = Int(((L.tHi - L.tLo) / L.px).rounded())
        L.canvas = L.vertical ? PixelSize(width: acrossPx, height: alongPx) : PixelSize(width: alongPx, height: acrossPx)
        // Snap the across origin so the gate lands on pixel boundaries.
        let tOrigin = L.gateT0 - ((L.gateT0 - L.tLo) / L.px).rounded() * L.px
        let sOrigin = -Double(mPx) * L.px

        // --- scan registration: capped by how far it moves the film's ends
        let halfAlong = 0.5 * Double(alongPx) * L.px
        let tiltLim = min(0.35, asin(min(1.0, 0.27 / halfAlong)) * 180.0 / .pi)
        L.scanRot = min(max(rf.normal() * 0.14, -tiltLim), tiltLim) * .pi / 180.0
        let ds = rf.normal() * 0.08
        let dt = rf.normal() * 0.06
        L.cu = 0.5 * Double(L.canvas.width) * L.px
        L.cv = 0.5 * Double(L.canvas.height) * L.px
        let c = cos(L.scanRot), sn = sin(L.scanRot)
        // A rotation, never a reflection: a swap of axes would mirror the edge print.
        L.A = L.vertical ? [sn, c, -c, sn] : [c, -sn, sn, c]
        L.cs = sOrigin + 0.5 * Double(alongPx) * L.px + ds
        L.ct = tOrigin + 0.5 * Double(acrossPx) * L.px + dt
        L.sLo = sOrigin
        L.sHi = sOrigin + Double(alongPx) * L.px

        // --- the host's turn: the engine's own map, then whole quarter turns
        let base = L.vertical ? 1 : 0
        L.extraTurns = (((r.turn - base) % 4) + 4) % 4
        L.out = L.extraTurns % 2 == 0 ? L.canvas : PixelSize(width: L.canvas.height, height: L.canvas.width)

        imprints(&L)
        return L
    }

    // MARK: the gate's shape (RFC-032 §29)

    private static func gateShape(_ L: inout FilmGeometry, _ family: FilmEdgeGate, _ rc: inout SplitMix64) {
        // A 6×8 back's gate is seated against the edge the name is printed on.
        if family == .shouldered { L.gateT0 = rc.uni(1.10, 1.35) + (L.gateT0 - 0.5 * (L.filmW - L.gateAcross)) }
        let s0 = L.gateS0, t0 = L.gateT0, gw = L.gateAlong, gh = L.gateAcross
        var quads: [GateQuad] = []
        func quad(_ pts: [Double], _ round: Double, _ sign: Double) {
            guard quads.count < 8 else { return }
            var p = pts
            if p.count == 6 { p += [p[4], p[5]] }           // a triangle
            while p.count < 8 { p.append(0) }               // an ellipse: cs, ct, rs, rt
            quads.append(GateQuad(pts: p, round: round, sign: sign))
        }
        func sideCut(_ top: Bool, _ earA: Double, _ earB: Double, _ depth: Double, _ slope: Double, _ round: Double) {
            let te = top ? t0 : t0 + gh, out = top ? -1.0 : 1.0
            let dIn = depth - round, ext = 1.0
            let k = slope / max(depth, 1e-3)
            let saIn = s0 + earA + slope - round, sbIn = s0 + gw - earB - slope + round
            let saOut = s0 + earA - k * ext + round, sbOut = s0 + gw - earB + k * ext - round
            quad([saOut, te + out * ext, sbOut, te + out * ext, sbIn, te - out * dIn, saIn, te - out * dIn], round, -1.0)
        }
        func bandCut(_ top: Bool, _ earA: Double, _ earB: Double, _ d0: Double, _ d1: Double, _ a0: Double, _ a1: Double) {
            let te = top ? t0 : t0 + gh, out = top ? -1.0 : 1.0
            quad([s0 + earA + a0, te - out * d0, s0 + gw - earB - a0, te - out * d0,
                  s0 + gw - earB - a1, te - out * d1, s0 + earA + a1, te - out * d1], 0.02, -1.0)
        }
        func radii(_ lo: Double, _ hi: Double) { for i in 0..<4 { L.gateR[i] = rc.uni(lo, hi) } }

        L.gateFamily = family
        switch family {
        case .rounded:
            let r = rc.uni(0.42, 0.62)
            for i in 0..<4 { L.gateR[i] = max(0.2, r + rc.uni(-0.08, 0.08)) }
        case .eared:
            radii(0.02, 0.08)
            for top in [true, false] {
                let te = top ? t0 : t0 + gh, out = top ? -1.0 : 1.0
                let depth = rc.uni(0.48, 0.65)
                let ea = rc.uni(0.0, 0.05)
                let eb = rc.uni(0.0, 0.05)
                let la = rc.uni(1.5, 2.2)
                let lb = rc.uni(1.5, 2.2)
                quad([s0 + ea + la, te + out * 1.0, s0 + gw - eb - lb, te + out * 1.0,
                      s0 + gw - eb - lb, te - out * depth, s0 + ea + la, te - out * depth], 0.0, -1.0)
                let ra = (la * la + depth * depth) / (2.0 * depth), rb = (lb * lb + depth * depth) / (2.0 * depth)
                quad([s0 + ea + la, te + out * (ra - depth), ra, ra], 0.0, -2.0)
                quad([s0 + gw - eb - lb, te + out * (rb - depth), rb, rb], 0.0, -2.0)
            }
        case .shouldered:
            radii(0.04, 0.12)
            L.gateR[0] = rc.uni(0.28, 0.5)
            L.gateR[1] = rc.uni(0.28, 0.5)
            let ea = rc.uni(3.1, 3.8)
            let eb = rc.uni(3.1, 3.8)
            let depth = rc.uni(1.35, 1.6)
            let steep = rc.uni(0.35, 0.45)
            let knee = rc.uni(0.3, 0.4)
            let leg = rc.uni(2.0, 2.6)
            sideCut(true, ea, eb, knee * depth, steep, 0.03)
            bandCut(true, ea, eb, knee * depth - 0.05, depth, steep - 0.03, steep + leg)
            L.topRecess = depth
        case .kicked:
            radii(0.02, 0.10)
            let first = Int(rc.uni(0.0, 4.0)) % 4
            for j in 0..<2 {
                let c = (first + 2 * j + (rc.uni() < 0.3 ? 1 : 0)) % 4
                let right = c == 1 || c == 2, bottom = c == 2 || c == 3
                let sc = right ? s0 + gw : s0, tc = bottom ? t0 + gh : t0
                let len = rc.uni(0.6, 1.0)
                let kick = rc.uni(0.14, 0.26)
                let dir = right ? -1.0 : 1.0, out = bottom ? 1.0 : -1.0
                quad([sc + dir * len, tc - out * 0.05, sc, tc - out * 0.05, sc, tc + out * kick], 0.01, 1.0)
            }
        case .square, .auto:
            if L.perforated { radii(0.10, 0.38) } else { radii(0.06, 0.32) }
        }
        // Burrs and nicks: most gates have one or two, a tenth of a millimetre.
        let nicks = Int(rc.uni(0.0, 2.6))
        for _ in 0..<nicks {
            let side = Int(rc.uni(0.0, 4.0)) % 4
            let sz = rc.uni(0.04, 0.12)
            let pos = rc.uni(0.08, 0.92)
            let sign = rc.uni() < 0.5 ? 1.0 : -1.0
            if side == 0 || side == 2 {
                let te = side == 0 ? t0 : t0 + gh, out = (side == 0 ? -1.0 : 1.0) * sign
                let sc = s0 + pos * gw
                let ax = sc + rc.uni(-0.5, 0.5) * sz
                quad([sc - sz, te, sc + sz, te, ax, te + out * sz], 0.005, sign)
            } else {
                let se = side == 3 ? s0 : s0 + gw, out = (side == 3 ? -1.0 : 1.0) * sign
                let tc = t0 + pos * gh
                let bx = tc + rc.uni(-0.5, 0.5) * sz
                quad([se, tc - sz, se, tc + sz, se + out * sz, bx], 0.005, sign)
            }
        }
        L.quads = quads
    }

    // MARK: the imprints: the edge print and the date

    private static func fitEdgeText(_ text: String, slotMM: Double, sizeMM: Double, trackingMM: Double) -> String {
        let perChar = 0.68 * sizeMM + trackingMM
        let maxChars = Int(max(1.0, floor(slotMM / perChar)))
        let chars = Array(text.utf8)
        if chars.count <= maxChars { return text }
        // the last space at or before `maxChars`
        var cut: Int? = nil
        var i = min(maxChars, chars.count - 1)
        while i >= 0 { if chars[i] == 32 { cut = i; break }; i -= 1 }
        if let cut, cut > 0 { return String(decoding: chars[0..<cut], as: UTF8.self) }
        return String(decoding: chars[0..<maxChars], as: UTF8.self)
    }

    private static func fitMatrixText(_ text: String, slotMM: Double, cap: Double, xscale: Double, bold: Bool) -> String {
        var chars = Array(text.utf8)
        while !chars.isEmpty,
              Face5x7.matrix(String(decoding: chars, as: UTF8.self), cap: cap, xscale: xscale, bold: bold,
                             s0: 0, baseT: 0, out: nil) > slotMM {
            if let cut = chars.lastIndex(of: 32), cut > 0 { chars = Array(chars[0..<cut]) } else { chars.removeLast() }
        }
        return String(decoding: chars, as: UTF8.self)
    }

    /// The same for a dot face: whole words dropped from the end until the
    /// text fits its slot, the last word cut if it alone does not.
    private static func fitDots(_ text: String, slotMM: Double, face: DotFace, ps: Double, d: Double, space: Double) -> [UInt8] {
        var chars = Array(text.utf8)
        while !chars.isEmpty,
              DotFaces.text(chars, face, ps: ps, pt: 1.0, d: d, space: space, s0: 0, baseT: 0, out: nil) > slotMM {
            if let cut = chars.lastIndex(of: 32), cut > 0 { chars = Array(chars[0..<cut]) } else { chars.removeLast() }
        }
        return chars
    }

    private static func rect(_ s0: Double, _ t0: Double, _ s1: Double, _ t1: Double) -> FilmMark {
        .poly([s0, t0, s1, t0, s1, t1, s0, t1])
    }

    private static func helv(_ font: String, cap: Double, capPerEm: Double, hscale: Double, tracking: Double) -> FilmText {
        FilmText(font: font, sizeMM: cap / capPerEm, trackingMM: tracking, hscale: hscale)
    }

    /// Ilford's 135 print: where its DX code starts, mm past `perfPhase`
    /// (`kIlfordCode`).
    private static let ilfordCode = 2.85

    private static func imprints(_ L: inout FilmGeometry) {
        let o = L.request
        let look = EdgeLook.of(o.stockID)
        let cam = UInt64(UInt32(truncatingIfNeeded: o.cameraSeed)), frm = UInt64(UInt32(truncatingIfNeeded: o.frameSeed))
        var rf = SplitMix64(SplitMix64.stream(frm ^ (cam << 32), .frame, 7))

        let span = 0.75 * Double(L.vertical ? L.canvas.height : L.canvas.width) * L.px
        let sMin = L.cs - span, sMax = L.cs + span
        var top: [FilmMark] = [], bot: [FilmMark] = []
        var numbers: [(Double, String)] = []
        var name = ""

        if L.perforated {
            // Film data on a half-frame grid (4 perforations = 19.00 mm)
            // anchored to the perforations; `n0` is which frame this is.
            let n0 = o.frameNumber > 0 ? o.frameNumber : 1 + Int(frm % 34)
            let grid0 = L.perfPhase + 0.62
            let W = L.filmW, kCap = 0.714                  // Helvetica Neue's cap height per em
            // A dot of Fujifilm's print, mm across: a hair under the dots'
            // spacing, so the develop spreads it to the strips' 0.145 mm and
            // the strokes stay beaded.
            let kDot = 0.114
            let dotS = DotFaces.dotS, dotT = DotFaces.dotT
            let fujiNeg = look.k135 == .fujiNeg
            let ilford = look.k135 == .ilford
            let dx = (look.k135 == .kodak || fujiNeg || ilford) ? (look.dx ?? -1) : -1
            L.dxNumber = dx >= 0 ? dx : nil
            L.dxLength = dx >= 0 ? look.dxLengthMM : 0.0
            L.dxTurned = dx >= 0 && look.dxTurned
            // 12.64–12.78 mm long on Kodak-made film, 14.1 mm on X-Tra 400,
            // 13.06 mm on Ilford's HP5 Plus.
            let mod = look.dxLengthMM / 31.0
            let clockT0 = W - 2.17, dataT0 = W - 0.87, dataT1 = W + 0.10
            let mLo = Int(floor((sMin - grid0) / 19.0)) - 1, mHi = Int(ceil((sMax - grid0) / 19.0)) + 1

            // `lies`: where the code is on the film when it is drawn somewhere
            // else first and turned into place (Ilford's).
            func dxCode(_ s: Double, _ num: Int, _ aHalf: Bool, _ dst: inout [FilmMark], lies: Double? = nil) {
                guard dx >= 0 else { return }
                let bits = DXBars.bits(dx: dx, frame: max(0, num), half: aHalf)
                let (clock, data) = DXBars.tracks(bits)
                L.dxCodes.append(DXCode(s: lies ?? s, frame: max(0, num), half: aHalf, bits: bits))
                for track in 0..<2 {
                    let row = track == 0 ? clock : data
                    let ta = track == 0 ? clockT0 : dataT0, tb = track == 0 ? dataT0 : dataT1
                    var i = 0
                    while i < 31 {
                        if row[i] == 0 { i += 1; continue }
                        var j = i
                        while j < 31 && row[j] != 0 { j += 1 }
                        dst.append(rect(s + Double(i) * mod, ta, s + Double(j) * mod, tb + (track == 0 ? 0.01 : 0.0)))
                        i = j
                    }
                }
            }
            // an arrow along the film, pointing the way it winds on
            func windArrow(_ a0: Double, _ a1: Double, _ tc: Double, _ head: Double, _ halfH: Double) {
                bot.append(rect(a0, tc - 0.09, a1 - 0.75 * head, tc + 0.09))
                bot.append(.poly([a1 - head, tc - halfH, a1, tc, a1 - head, tc + halfH]))
            }

            for m in mLo...mHi {
                let s = grid0 + 19.0 * Double(m) + ((look.k135 == .kodak || fujiNeg) ? 19.0 : 0.0)
                let half = 2 * n0 + m
                let num = Int(floor(Double(half) / 2.0))
                let aHalf = half % 2 != 0
                switch look.k135 {
                case .kodak:
                    let light = look.lightNumbers
                    let capT = light ? 1.07 : 1.22, baseT = light ? 1.69 : 1.53
                    var op = helv(light ? "HelveticaNeue" : "HelveticaNeue-Bold", cap: capT, capPerEm: kCap,
                                  hscale: light ? 1.0 : 1.25, tracking: light ? 0.04 : 0.25)
                    if !aHalf {
                        op.text = String(num); op.s = s + 16.9; op.t = baseT
                        top.append(.text(op))
                        numbers.append((op.s, op.text))
                    } else if !o.edgeText.isEmpty {
                        // From the name to the next number at s + 19 + 16.9, less a space.
                        let s0 = s + (light ? 5.1 : 6.4)
                        var tx = helv("HelveticaNeue-Bold", cap: capT, capPerEm: kCap, hscale: 1.0, tracking: 0.06)
                        tx.text = fitEdgeText(o.edgeText, slotMM: 19.0 + 16.9 - (s0 - s) - 2.0, sizeMM: tx.sizeMM, trackingMM: 0.06)
                        tx.s = s0; tx.t = baseT
                        name = tx.text
                        if light, let sp = tx.text.firstIndex(of: " ") {
                            // the maker bold, the rest regular, 1.3 mm apart
                            var rest = tx
                            rest.font = "HelveticaNeue"
                            rest.text = String(tx.text[tx.text.index(after: sp)...])
                            tx.text = String(tx.text[..<sp])
                            rest.s = s0 + EdgeType.width(tx.text, font: tx.font, sizeMM: tx.sizeMM, trackingMM: tx.trackingMM, hscale: 1.0) + 1.3
                            top.append(.text(rest))
                        }
                        top.append(.text(tx))
                    }
                    dxCode(s, num, aHalf, &bot)
                    var nb = helv(light ? "HelveticaNeue" : "HelveticaNeue-Bold", cap: 1.40, capPerEm: kCap,
                                  hscale: light ? 1.0 : 1.25, tracking: light ? 0.03 : 0.25)
                    if aHalf {
                        nb.text = "\(num)A"
                        nb.sizeMM = 0.90 / kCap; nb.s = s + 15.3; nb.t = W - 0.84
                        bot.append(.text(nb))
                        windArrow(s + 14.47, s + 18.07, W - 0.28, 0.6, 0.26)
                    } else {
                        nb.text = String(num)
                        nb.s = s + 16.0; nb.t = W - 0.14
                        bot.append(.text(nb))
                    }
                case .fujiNeg:
                    // Numbers on both bands in Fujifilm's two-dot face, closer
                    // set than the slides' (a dot every 0.090 mm along); the
                    // stock's words in the names' face 5.5 mm into every other
                    // half frame. The bars and the arrow are still solid.
                    let n = Array("\(num)\(aHalf ? "A" : "")".utf8)
                    let ps = 0.090
                    let sTop = s + (aHalf ? 16.38 : 15.75)
                    DotFaces.text(n, DotFaces.small, ps: ps, pt: dotT, d: kDot, space: 4.0, s0: sTop, baseT: 1.60, out: &top)
                    numbers.append((sTop, String(decoding: n, as: UTF8.self)))
                    if aHalf && !o.edgeText.isEmpty {
                        let tx = fitDots(o.edgeText, slotMM: 9.8, face: DotFaces.names, ps: dotS, d: kDot, space: 4.0)
                        DotFaces.text(tx, DotFaces.names, ps: dotS, pt: dotT, d: kDot, space: 4.0, s0: s + 5.5, baseT: 1.50, out: &top)
                        name = String(decoding: tx, as: UTF8.self)
                    }
                    dxCode(s, num, aHalf, &bot)
                    DotFaces.text(n, DotFaces.small, ps: ps, pt: dotT, d: kDot, space: 4.0, s0: s + (aHalf ? 16.1 : 15.25),
                                  baseT: aHalf ? W - 0.41 : W - 0.31, out: &bot)
                    if aHalf { windArrow(s + 14.6, s + 15.85, W - 1.0, 0.55, 0.3) }
                case .fujiSlide:
                    // No DX bars, everything in dots. The frame number in the
                    // numbers' face on both bands; the name in the names' face
                    // 16.0 mm after it, its words ten dots apart; at the half
                    // frame, on the bottom band only, "36" (the roll's length,
                    // 3 × 5 dots), the arrow and "12A" in the two-dot face,
                    // standing on one line.
                    let sn = L.perfPhase + 0.56 + 3.5 + 19.0 * Double(m)
                    if !aHalf {
                        let n = Array(String(num).utf8)
                        DotFaces.text(n, DotFaces.numbers, ps: dotS, pt: dotT, d: kDot, space: 4.0, s0: sn, baseT: 1.80, out: &top)
                        DotFaces.text(n, DotFaces.numbers, ps: dotS, pt: dotT, d: kDot, space: 4.0, s0: sn + 0.1, baseT: W - 0.27, out: &bot)
                        numbers.append((sn, String(num)))
                        if !o.edgeText.isEmpty {
                            let tx = fitDots(o.edgeText, slotMM: 21.0, face: DotFaces.names, ps: dotS, d: kDot, space: 10.0)
                            DotFaces.text(tx, DotFaces.names, ps: dotS, pt: dotT, d: kDot, space: 10.0, s0: sn + 16.0, baseT: 1.77, out: &top)
                            name = String(decoding: tx, as: UTF8.self)
                        }
                    } else {
                        let sa = sn - 19.0                           // the full frame this half belongs to
                        DotFaces.text(Array("36".utf8), DotFaces.tiny, ps: 0.135, pt: dotT, d: kDot, space: 4.0, s0: sa + 14.75,
                                      baseT: W - 0.40, out: &bot)
                        let foot = W - 0.40
                        DotFaces.rows(DotFaces.arrow, nrow: 12, ncol: 22, s0: sa + 16.05 + 0.5 * kDot,
                                      t0: foot - 0.5 * kDot - 11 * dotT, ps: dotS, pt: dotT, d: kDot, out: &bot)
                        DotFaces.text(Array("\(num)A".utf8), DotFaces.small, ps: dotS, pt: dotT, d: kDot, space: 4.0, s0: sa + 18.88,
                                      baseT: foot, out: &bot)
                    }
                case .ilford:
                    // What Kodak prints, turned half a turn: with the picture
                    // upright the bars run along the top band and the name
                    // reads upside down along the bottom one. So it is laid
                    // out as it reads (`u` from the code's start, `v` from the
                    // name's edge) and turned at the end. The code 13.06 mm
                    // long, one every 19 mm; the name in a square 5 × 7 face,
                    // caps 1.50 mm on a baseline 1.85 mm from its edge, 8.7 mm
                    // after the start of the code beyond the frame's end. The
                    // frame numbers are the engine's assumption (the strip is
                    // cropped through them) and are drawn as it draws them; the
                    // batch number beside the name is not drawn there or here.
                    let c = L.perfPhase + ilfordCode + 19.0 * Double(m + 1)   // where the code starts, in s
                    let t0 = top.count, b0 = bot.count
                    dxCode(0.0, num, aHalf, &top, lies: c - look.dxLengthMM)
                    if aHalf {
                        Face5x7.matrix("\(num)A", cap: 1.20, xscale: 1.0, bold: false, s0: 14.9, baseT: W - 0.35, out: &top)
                        if !o.edgeText.isEmpty {
                            let tx = fitMatrixText(o.edgeText, slotMM: 26.0, cap: 1.50, xscale: 1.0, bold: false)
                            Face5x7.matrix(tx, cap: 1.50, xscale: 1.0, bold: false, s0: 8.7, baseT: 1.85, out: &bot)
                            name = tx
                        }
                    } else {
                        Face5x7.matrix(String(num), cap: 1.60, xscale: 1.0, bold: true, s0: 14.6, baseT: W - 0.35, out: &top)
                        numbers.append((c - 14.6, String(num)))
                    }
                    func turn(_ marks: inout [FilmMark], from: Int) {
                        for i in from..<marks.count {
                            guard case .poly(var pts) = marks[i] else { continue }
                            for k in stride(from: 0, to: pts.count - 1, by: 2) {
                                pts[k] = c - pts[k]
                                pts[k + 1] = W - pts[k + 1]
                            }
                            marks[i] = .poly(pts)
                        }
                    }
                    turn(&top, from: t0)
                    turn(&bot, from: b0)
                case .cine:
                    // One line beside the bottom perforations and a dash every
                    // 38 mm. No frame numbers, no bars, nothing on the top band.
                    if half % 2 == 0 {
                        let sd = s + 2.06
                        bot.append(rect(sd, W - 0.91, sd + 1.16, W - 0.69))
                        if (((half / 2) % 2) + 2) % 2 == 0 && !o.edgeText.isEmpty {
                            let tx = fitMatrixText(o.edgeText, slotMM: 27.4, cap: 0.88, xscale: 0.93, bold: false)
                            Face5x7.matrix(tx, cap: 0.88, xscale: 0.93, bold: false, s0: sd + 10.1, baseT: W - 0.47, out: &bot)
                            name = tx
                        }
                    }
                }
            }
        } else {
            // 120. Not sprocket-locked, so where the marks land relative to
            // the frame is the frame's draw.
            if look.k120 == .fuji {
                // One edge only, in a 5 × 7 dot matrix, zeros slashed: every
                // 41.1 mm a frame number, a tack pointing back at it, the
                // stock's words, and on Pro 400H a code. Ending 3.7 mm before
                // each number: the maker's mark before the even ones, a
                // three-digit roll number before the odd ones.
                // The maker's mark is the host's, like the name: the first
                // word of the edge's text when it has more than one, and none
                // for a single word. The engine prints no maker's name of its
                // own: the edge's words put `FUJI` there (`EdgeWords`).
                var maker: [UInt8] = [], words = Array(o.edgeText.utf8)
                if let sp = words.firstIndex(of: 32) {
                    maker = Array(words[..<sp])
                    words = words[sp...].firstIndex(where: { $0 != 32 }).map { Array(words[$0...]) } ?? []
                }
                // 120's dots are larger and further apart than 135's: a
                // character every 0.967 mm, seven rows 1.05 mm tall. The code
                // after the name is on the 135 grid.
                let P = 41.1, ps = 0.161, pt = 0.148, d120 = 0.15, dcode = 0.114
                @discardableResult
                func big(_ tx: [UInt8], _ s0: Double, _ base: Double, _ out: UnsafeMutablePointer<[FilmMark]>?) -> Double {
                    DotFaces.text(tx, DotFaces.matrix57, ps: ps, pt: pt, d: d120, space: 4.0, s0: s0, baseT: base, out: out)
                }
                let roll = rf.uni(0.0, 2.0 * P)
                var n0 = 1 + Int(rf.uni(0.0, 14.0))
                let lot = Int(rf.uni(0.0, 1000.0)) % 1000
                if o.frameNumber > 0 { n0 = o.frameNumber - Int(ceil(roll / P)) }
                let tb = L.topRecess > 0 ? max(0.9, L.gateT0 + L.topRecess - 0.85) : 1.60
                let jLo = Int(floor((sMin + roll) / P)) - 1, jHi = Int(ceil((sMax + roll) / P)) + 1
                for j in jLo...jHi {
                    let sn = -roll + Double(j) * P
                    let num = n0 + j
                    let before = num % 2 == 0 ? maker : Array(String(format: "%03d", lot).utf8)
                    let wb = before.isEmpty ? 0.0 : big(before, 0, 0, nil)
                    if !before.isEmpty { big(before, sn - 3.7 - wb, tb, &top) }
                    if num < 1 { continue }
                    let ns = String(num)
                    let wn = big(Array(ns.utf8), sn, tb, &top)
                    numbers.append((sn, ns))
                    // The marker is a tack in the same dots, 13 across and 7 down.
                    let a = sn + wn + 1.45
                    DotFaces.rows(DotFaces.tack, nrow: 7, ncol: 13, s0: a + 0.5 * d120, t0: tb - 0.5 * d120 - 6 * pt,
                                  ps: ps, pt: pt, d: d120, out: &top)
                    if !words.isEmpty {
                        let hasCode = !look.code.isEmpty
                        let s0 = a + 4.95
                        var tx = words
                        let slot = hasCode ? 12.0 : P - 3.7 - 4.5 - (s0 - sn) - 1.0
                        while !tx.isEmpty, big(tx, 0, 0, nil) > slot { tx.removeLast() }
                        big(tx, s0, tb, &top)
                        name = String(decoding: tx, as: UTF8.self)
                        if hasCode {
                            DotFaces.text(Array(look.code.utf8), DotFaces.matrix57, ps: DotFaces.dotS, pt: DotFaces.dotT, d: dcode,
                                          space: 4.0, s0: s0 + 13.2, baseT: tb, out: &top)
                        }
                    }
                }
            } else {
                // Kodak: numbers counting along the roll every ~49.5 mm with
                // the name centred between them; on the other edge triangles
                // every ~29 mm, every other one followed by a digit.
                // The lettering as the desktop read it off a Gold 200 strip
                // (2026-10-04): the maker's word and the numbers in an
                // extended black face — Helvetica Neue Bold scaled ×1.3 along
                // the line, advances and all — and the stock's own words a
                // gap of 2.5 mm on, not a word space, in an ordinary bold
                // (a medium where the profile's id has `portra` in it: that
                // print is lighter).
                let kNumTrack = 0.04, kWide = 1.3, kHeadTrack = 0.0, kNameGap = 2.5
                let period = 49.5, cap = 1.13, size = cap / 0.714
                let lightTail = o.stockID.contains("portra")
                let roll = rf.uni(0.0, period)
                let n0 = 12 + Int(rf.uni(0.0, 40.0))
                let tTop = L.topRecess > 0 ? max(0.9, L.gateT0 + L.topRecess - 0.85) : 1.60
                let tBot = L.filmW - 0.54
                let jLo = Int(floor((sMin + roll) / period)) - 1, jHi = Int(ceil((sMax + roll) / period)) + 1
                for j in jLo...jHi {
                    let s = -roll + Double(j) * period
                    var num = FilmText(sizeMM: size, trackingMM: kNumTrack, hscale: kWide, scaleAdvances: true)
                    num.text = String(n0 + j); num.s = s; num.t = tTop
                    top.append(.text(num))
                    if !o.edgeText.isEmpty {
                        // Centred between one number and the next, not at a
                        // fixed offset.
                        let all = Array(fitEdgeText(o.edgeText, slotMM: period - 10.8 - 3.0, sizeMM: size, trackingMM: 0.30).utf8)
                        let sp = all.firstIndex(of: 32)
                        var head = num                              // the maker's word, in the numbers' face
                        head.trackingMM = kHeadTrack
                        head.text = String(decoding: all[..<(sp ?? all.count)], as: UTF8.self)
                        var tail = FilmText(font: lightTail ? "HelveticaNeue-Medium" : "HelveticaNeue-Bold", sizeMM: size,
                                            trackingMM: lightTail ? 0.08 : 0.03, hscale: 1.05, scaleAdvances: true)
                        tail.t = tTop
                        if let sp, let rest = all[sp...].firstIndex(where: { $0 != 32 }) {
                            tail.text = String(decoding: all[rest...], as: UTF8.self)
                        }
                        let gap = tail.text.isEmpty ? 0.0 : kNameGap
                        let wnum = EdgeType.width(num.text, font: num.font, sizeMM: size, trackingMM: num.trackingMM, hscale: num.hscale)
                        let whead = EdgeType.width(head.text, font: head.font, sizeMM: size, trackingMM: head.trackingMM, hscale: head.hscale)
                        let wtail = tail.text.isEmpty ? 0.0
                            : EdgeType.width(tail.text, font: tail.font, sizeMM: size, trackingMM: tail.trackingMM, hscale: tail.hscale)
                        head.s = s + wnum + 0.5 * (period - wnum - whead - gap - wtail)
                        top.append(.text(head))
                        if !tail.text.isEmpty {
                            tail.s = head.s + whead + gap
                            top.append(.text(tail))
                        }
                        name = String(decoding: all, as: UTF8.self)
                    }
                }
                let markPeriod = 29.0, mroll = rf.uni(0.0, markPeriod)
                let kLo = Int(floor((sMin + mroll) / markPeriod)) - 1, kHi = Int(ceil((sMax + mroll) / markPeriod)) + 1
                var kFirst = Int(ceil(mroll / markPeriod))
                if ((kFirst % 2) + 2) % 2 != 0 { kFirst += 1 }
                let mh = 1.12
                for k in kLo...kHi {
                    let s = -mroll + Double(k) * markPeriod
                    bot.append(.poly([s, tBot - mh, s + 1.83 * mh, tBot - 0.5 * mh, s, tBot]))
                    if ((k % 2) + 2) % 2 == 0 {
                        let digit = o.frameNumber > 0 ? o.frameNumber + (k - kFirst) / 2 : 1 + ((k / 2) % 9 + 9) % 9
                        if digit < 1 { continue }
                        var dg = FilmText(sizeMM: 1.15 / 0.714, trackingMM: kNumTrack, hscale: kWide, scaleAdvances: true)
                        dg.text = String(digit); dg.s = s + 2.8; dg.t = tBot
                        bot.append(.text(dg))
                        numbers.append((s, dg.text))
                    }
                }
            }
        }
        L.edge = top + bot
        L.printedName = name
        L.printedNumbers = numbers.filter { $0.0 >= L.sLo - 2 && $0.0 <= L.sHi }.sorted { $0.0 < $1.0 }.map(\.1)

        if let d = o.date { L.date = dateMarks(d, format: o.format, L: L) }
    }

    // MARK: the date back (RFC-031 §8)

    /// One mechanism — a light behind the film through a mask — in three
    /// faces. Everything is placed and turned in the *film's* frame: turn a
    /// full-frame camera for a portrait and the date turns with it.
    private static func dateMarks(_ d: DateRequest, format: FilmEdgeFormat, L: FilmGeometry?) -> [FilmMark] {
        dateMarks(d, format: format, L: L, frameWMM: 0, frameHMM: 0)
    }

    private static func dateMarks(_ d: DateRequest, format: FilmEdgeFormat, L: FilmGeometry?,
                                  frameWMM: Double, frameHMM: Double) -> [FilmMark] {
        // Two things, each where a camera put it, and both at once when both
        // are asked for (the engine's 1.3.1; the host asks since 2026-10-20):
        // the date (`text` under LCD or Dots) and the shooting data
        // (`dataText`, or `text` under Data).
        let data = d.style == .data
        let dateText = data ? "" : d.text
        let dataText = data ? d.text : d.dataText
        guard !dateText.isEmpty || !dataText.isEmpty else { return [] }
        let is135 = format == .f135 || format == .half
        if !is135 && format != .f645 { return [] }
        var marks: [FilmMark] = []
        let k = min(max(d.size, 0.4), 3.0)

        // A face's glyphs, laid out in glyph space (x right, y up from the
        // baseline) and mapped to film mm by `place`.
        func draw(_ text: String, _ style: DateBackFace, _ h: Double, _ place: (Double, Double) -> (Double, Double)) {
            if style == .lcd {
                for poly in SevenSegmentFace.polys(text, h: h, skew: tan(8.0 * .pi / 180.0)) {
                    var pts: [Double] = []
                    for p in poly { let q = place(p.x, p.y); pts += [q.0, q.1] }
                    marks.append(.poly(pts))
                }
                return
            }
            let dots = style == .dots
            Face5x7.dots(text, h: h) { x, y, pitch in
                if dots {
                    let q = place(x, y)
                    marks.append(.circle(s: q.0, t: q.1, r: 0.36 * pitch))
                } else {
                    let hp = 0.5 * pitch * 1.02
                    var pts: [Double] = []
                    for (px, py) in [(x - hp, y - hp), (x + hp, y - hp), (x + hp, y + hp), (x - hp, y + hp)] {
                        let q = place(px, py); pts += [q.0, q.1]
                    }
                    marks.append(.poly(pts))
                }
            }
        }
        func textWidth(_ text: String, _ style: DateBackFace, _ h: Double) -> Double {
            style == .lcd ? SevenSegmentFace.width(text, h: h) : Face5x7.dots(text, h: h) { _, _, _ in }
        }

        let gw = L?.gateAlong ?? frameWMM, gh = L?.gateAcross ?? frameHMM
        let gs = L?.gateS0 ?? 0.0, gt = L?.gateT0 ?? 0.0
        let gap = L.map { max(0.6, Double($0.vertical ? $0.canvas.height : $0.canvas.width) * $0.px - $0.gateAlong) * 0.5 } ?? 0.0
        if format == .f645 {
            guard L != nil else { return [] }
            // 645N: one line in the margin beside the frame, reading along the
            // film, ~0.3 mm off the gate, on the side away from the stock name:
            // the data from the frame's leading end, a date ending at its far end.
            let h = 0.55 * k
            let tBase = gt + gh + 0.30 + h
            if !dataText.isEmpty {
                let s0 = gs + 0.08 * gw
                draw(dataText, .data, h) { x, y in (s0 + x, tBase - y) }
            }
            if !dateText.isEmpty {
                let s0 = gs + 0.92 * gw - textWidth(dateText, d.style, h)
                draw(dateText, d.style, h) { x, y in (s0 + x, tBase - y) }
            }
            return marks
        }
        // Between frames, rotated, reading up the film's width: in the gap
        // before the frame, or — a date that shares the film with a data line —
        // the gap after it.
        func between(_ text: String, _ style: DateBackFace, _ h: Double, after: Bool) {
            let w = textWidth(text, style, h)
            let sC = after ? gs + gw + 0.5 * gap : gs - 0.5 * gap
            let tC = gt + 0.5 * gh + 0.5 * w
            draw(text, style, h) { x, y in (sC + 0.5 * h - y, tC - x) }
        }
        let dataDrawn = !dataText.isEmpty && L != nil
        if dataDrawn { between(dataText, .data, 0.50 * k, after: false) }
        if !dateText.isEmpty && d.placement == .between && L != nil {
            between(dateText, d.style, 0.55 * k, after: dataDrawn)
        } else if !dateText.isEmpty {
            // In the frame, at the chosen corner of the *film's* frame.
            let h = (d.style == .dots ? 0.95 : 1.3) * k
            let w = textWidth(dateText, d.style, h)
            let right = d.corner.isRight, bottom = d.corner.isBottom
            // The date alone draws on the bare frame, so the film's direction
            // comes from its shape: a full frame taller than wide, or a half
            // frame wider than tall, was shot with the camera turned.
            var turned = false
            var fs = gs, ft = gt, fw = gw, fh = gh
            if L == nil {
                turned = format == .half ? frameWMM > frameHMM : frameHMM > frameWMM
                fs = 0.0; ft = 0.0
                fw = turned ? frameHMM : frameWMM
                fh = turned ? frameWMM : frameHMM
            }
            // Kept inside the frame: the slant, and the blur.
            let over = (d.style == .lcd ? h * tan(8.0 * .pi / 180.0) : 0.0) + 0.1
            let s0 = min(max(right ? fs + fw - d.insetXMM - w : fs + d.insetXMM, fs + 0.1), max(fs + 0.1, fs + fw - w - over))
            let base = min(max(bottom ? ft + fh - d.insetYMM : ft + d.insetYMM + h, min(ft + h + 0.1, ft + fh - 0.1)), ft + fh - 0.1)
            draw(dateText, d.style, h) { x, y in
                let sf = s0 + x, tf = base - y
                return turned ? (fh - tf, sf) : (sf, tf)       // picture x = across − t, y = s
            }
        }
        return marks
    }

    /// A date with no film edge: the bare frame is the gate, `longEdgeMM` long.
    static func dateAlone(_ d: DateRequest, camera: FilmEdgeFormat, frame: PixelSize, longEdgeMM: Double) -> (marks: [FilmMark], px: Double) {
        let px = longEdgeMM / Double(max(1, frame.longEdge))
        // The engine reads only whether the camera is a half-frame one.
        let format: FilmEdgeFormat = camera == .half ? .half : .f135
        guard camera == .f135 || camera == .half else { return ([], px) }
        let marks = dateMarks(d, format: format, L: nil, frameWMM: Double(frame.width) * px, frameHMM: Double(frame.height) * px)
        return (marks, px)
    }
}
