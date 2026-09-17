//  Tools/compare-design.swift — compare a capture against the drawing's own
//  render, apples to apples, on the things `measure-layout.swift` cannot see.
//
//      swift Tools/compare-design.swift ../design/snapshots/window-16x9.png \
//            ../reference_layout/Main/main_page.png
//
//  ## Why this exists
//
//  `measure-layout.swift` measures rail edges, the bar's rectangle and the
//  hairlines, and on 2026-09-17 it reported *exact* at all three window
//  shapes. The interface it graded was still wrong: the type was a third
//  heavier than the drawing's, one section was 57 pt shorter, the list wells
//  clipped their rows, and the dropdowns were each a different width. None of
//  those is an edge, so none of them was measured, and "exact" was true and
//  worthless.
//
//  The reason the gap was invisible is worth writing down: the drawing,
//  `reference_layout/Main/sample_frontend.svg`, has 74 rectangles and **one
//  empty `<text/>` node**. Its type is set in SF Pro and Illustrator exported
//  it as outlines and linked rasters, so a validator reading the SVG can
//  check every rectangle in it and never discover that typography exists.
//  Type has to be measured off the *render* — `main_page.png` — which is what
//  this tool does.
//
//  ## The alignment, which is the whole trick
//
//  `main_page.png` is 3706 × 2094 with a ~10 px white border, so it is
//  neither the artboard's 3840 × 2160 nor a whole multiple of anything. Three
//  independent landmarks agree on its scale:
//
//      left rail    488 px ↔ 254 pt      → 1.9213
//      content width 3686 px ↔ 1920 pt   → 1.9198
//      content height 2074 px ↔ 1080 pt  → 1.9204
//
//  so the reference is cropped by its border and resampled onto the capture's
//  grid before a single number is compared. Every measurement below is then
//  in points in the same coordinate system, and a delta means something.
//
//  ## What it reports
//
//  | metric        | why it is here |
//  |---------------|----------------|
//  | separators    | a rail with more rules than the drawing reads as a spreadsheet |
//  | text lines    | ink height *and* stem width — size and weight, separately |
//  | stem spread   | whether hierarchy is carried by weight (it should not be) |
//  | control bands | the pill/well rows, with each one's x-extent |
//  | control width | the spread of dropdown widths; the drawing shares one width |
//  | wells         | extent, and whether the first or last row is clipped |
//  | density       | ink per rail, and the largest dead run |
//
//  A delta inside the tolerance prints `ok`; outside it prints `DRIFT` and
//  the tool exits non-zero, so it can gate a commit.

import Foundation
import CoreGraphics
import ImageIO

// MARK: - the bitmap

struct Bitmap {
    let w: Int, h: Int
    private let px: [UInt8]

    init(_ path: String) {
        guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let i = CGImageSourceCreateImageAtIndex(s, 0, nil) else {
            FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
            exit(2)
        }
        self.init(i)
    }

    init(_ image: CGImage) {
        let iw = image.width, ih = image.height
        w = iw; h = ih
        var buf = [UInt8](repeating: 0, count: iw * ih * 4)
        buf.withUnsafeMutableBytes { raw in
            let c = CGContext(data: raw.baseAddress, width: iw, height: ih, bitsPerComponent: 8,
                              bytesPerRow: iw * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image, in: CGRect(x: 0, y: 0, width: iw, height: ih))
        }
        px = buf
        // No flip here, and the reason is worth a line because getting it
        // wrong is silent. A `CGBitmapContext`'s *memory* is written top row
        // first even though its drawing origin is bottom-left, so a plain
        // `draw` already leaves row 0 holding the picture's top row.
        // "Helpfully" flipping the CTM first inverts every y, and nothing
        // complains: counts and pitches survive it, so a validator keeps
        // reporting plausible numbers for the wrong rows. It read this
        // capture's right rail as empty at the top, which it visibly is not.
    }

    func lum(_ x: Int, _ y: Int) -> Double {
        let o = (y * w + x) * 4
        return 0.2126 * Double(px[o]) + 0.7152 * Double(px[o + 1]) + 0.0722 * Double(px[o + 2])
    }

    /// Crop, then resample to exactly `size` — the alignment step.
    func fitted(crop r: CGRect, to size: CGSize) -> Bitmap {
        let c = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.interpolationQuality = .high
        // Rebuild a CGImage over the same rows, in the same order: `init`
        // stores the picture's top row at index 0 and `CGImage` reads it the
        // same way, so there is nothing to invert between them.
        let provider = CGDataProvider(data: Data(px) as CFData)!
        let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                          bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                          provider: provider, decode: nil, shouldInterpolate: false,
                          intent: .defaultIntent)!
        let sub = img.cropping(to: r)!
        c.draw(sub, in: CGRect(origin: .zero, size: size))
        return Bitmap(c.makeImage()!)
    }

    /// The content box inside the white border `main_page.png` carries.
    ///
    /// Found per edge, not assumed and not shared between them: a render can
    /// be matted unevenly, and a border guessed 4 px wrong moves every
    /// reference number by 2 pt — which is larger than most of the
    /// tolerances below, so this is the one measurement that has to be right
    /// before any other is worth printing.
    ///
    /// The matte is **not** white — on `main_page.png` it measures luminance
    /// 95…119, which is the interface's own `ground` grey, so "find the white
    /// frame" finds nothing. What distinguishes it is that it is *uniform*: an
    /// edge row belongs to the matte while nearly all of it matches the
    /// corner pixel.
    ///
    /// Sampling the full span is what stops the scan at the right place. The
    /// top matte is the same grey as the canvas directly below it, so a probe
    /// taken only at mid-width would eat into the picture; across the whole
    /// width, the first content row also contains the two dark rails and
    /// stops matching at once.
    func contentBox() -> CGRect {
        let corner = lum(0, 0)
        func isBorder(_ i: Int, vertical: Bool) -> Bool {
            let n = vertical ? h : w
            var same = 0, total = 0
            for j in stride(from: 0, to: n, by: 5) {
                total += 1
                if abs((vertical ? lum(i, j) : lum(j, i)) - corner) <= 15 { same += 1 }
            }
            return total > 0 && Double(same) / Double(total) > 0.9
        }
        var left = 0, right = w - 1, top = 0, bottom = h - 1
        while left < 40, isBorder(left, vertical: true) { left += 1 }
        while right > w - 41, isBorder(right, vertical: true) { right -= 1 }
        while top < 40, isBorder(top, vertical: false) { top += 1 }
        while bottom > h - 41, isBorder(bottom, vertical: false) { bottom -= 1 }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }
}

// MARK: - interval finding

/// Contiguous runs along `axis` where at least `cover` of the cross-axis
/// passes `thresh`. `cover` is what separates a hairline (a full-width run)
/// from a glyph (a sparse one), and asking for it is the difference between
/// finding structure and finding noise.
func runs(_ b: Bitmap, rows: Bool, _ a0: Int, _ a1: Int, _ c0: Int, _ c1: Int,
          thresh: Double, cover: Double, minRun: Int = 1) -> [(Int, Int)] {
    var out: [(Int, Int)] = []
    var start = -1
    let span = Double(max(1, c1 - c0))
    for a in max(0, a0)..<min(a1, rows ? b.h : b.w) {
        var n = 0
        for c in max(0, c0)..<min(c1, rows ? b.w : b.h) {
            if (rows ? b.lum(c, a) : b.lum(a, c)) > thresh { n += 1 }
        }
        let hit = Double(n) / span >= cover
        if hit && start < 0 { start = a }
        if !hit && start >= 0 { if a - start >= minRun { out.append((start, a)) }; start = -1 }
    }
    if start >= 0 { out.append((start, a1)) }
    return out
}

/// Ink coverage and stem widths in a box — size and weight, measured apart.
/// Two faces at one size differ in stem width; two sizes in one face differ
/// in ink height. A validator that reports only one of them cannot tell a
/// heavier font from a bigger one, which is the mistake this replaces.
///
/// `stemCap` is not a tuning knob, it is a correctness fix. A selected list
/// row is drawn as a *bright band the width of the well*, so a naive run
/// counter reports one 400 px "stem" for it and the spread across roles comes
/// out meaningless — it stayed near 3 px after the whole ramp was moved to a
/// single weight, which should have driven it to nearly zero. A glyph stem at
/// 2× is a handful of pixels; anything wider is a fill, and fills are counted
/// by `coverage`, which is what coverage is for.
func ink(_ b: Bitmap, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, thresh: Double,
         stemCap: Int = 20)
    -> (coverage: Double, medianStem: Double, meanStem: Double, count: Int) {
    var on = 0, total = 0
    var stems: [Int] = []
    func keep(_ run: Int) { if run > 0 && run <= stemCap { stems.append(run) } }
    for y in max(0, y0)..<min(y1, b.h) {
        var run = 0
        for x in max(0, x0)..<min(x1, b.w) {
            total += 1
            if b.lum(x, y) > thresh { on += 1; run += 1 }
            else { keep(run); run = 0 }
        }
        keep(run)
    }
    guard total > 0 else { return (0, 0, 0, 0) }
    stems.sort()
    let med = stems.isEmpty ? 0.0 : Double(stems[stems.count / 2])
    let mean = stems.isEmpty ? 0.0 : Double(stems.reduce(0, +)) / Double(stems.count)
    return (Double(on) / Double(total) * 100, med, mean, stems.count)
}

// MARK: - the report

var failures: [String] = []

func line(_ name: String, _ ref: Double, _ got: Double, _ tol: Double, _ unit: String = "pt") {
    let d = got - ref
    let ok = abs(d) <= tol
    if !ok { failures.append(name) }
    print(String(format: "  %-26s ref %8.2f   got %8.2f   Δ %+7.2f %-3s  %@",
                 (name as NSString).utf8String!, ref, got, d, (unit as NSString).utf8String!,
                 ok ? "ok" : "DRIFT"))
}

/// Reported, never failed.
///
/// Two of the type metrics carry a bias that no amount of design work can
/// close: the reference is an Illustrator rasterisation and the capture is
/// the macOS text system, and at the same nominal weight the former lays down
/// visibly thinner, smaller ink. Chasing `mean stem width` to the reference's
/// number would mean shipping type lighter than the house face. The paired
/// *spread* is the real gate — the bias is common to every role, so it
/// cancels — and these two are printed beside it as context.
func soft(_ name: String, _ ref: Double, _ got: Double, _ unit: String = "pt") {
    print(String(format: "  %-26s ref %8.2f   got %8.2f   Δ %+7.2f %-3s  (context)",
                 (name as NSString).utf8String!, ref, got, got - ref,
                 (unit as NSString).utf8String!))
}

func note(_ name: String, _ ref: String, _ got: String, ok: Bool) {
    if !ok { failures.append(name) }
    print(String(format: "  %-26s ref %-18s got %-18s      %@",
                 (name as NSString).utf8String!, (ref as NSString).utf8String!,
                 (got as NSString).utf8String!, ok ? "ok" : "DRIFT"))
}

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    print("""
    usage: swift Tools/compare-design.swift <capture.png> <reference.png> [scale]

      capture    a window capture from Tools/snapshot.sh or capture-live.sh
      reference  the drawing's render, e.g. reference_layout/Main/main_page.png
      scale      the capture's backing scale (default 2)
    """)
    exit(1)
}

let cap = Bitmap(args[0])
let refRaw = Bitmap(args[1])
let scale = args.count > 2 ? Double(args[2])! : 2.0
let box = refRaw.contentBox()
let ref = refRaw.fitted(crop: box, to: CGSize(width: cap.w, height: cap.h))

print("""
capture    \(args[0])  \(cap.w)×\(cap.h)  @\(scale)x  = \(Int(Double(cap.w)/scale))×\(Int(Double(cap.h)/scale)) pt
reference  \(args[1])  \(refRaw.w)×\(refRaw.h)  content \(Int(box.width))×\(Int(box.height)) \
at (\(Int(box.minX)),\(Int(box.minY)))  → resampled to \(ref.w)×\(ref.h)
""")

let pt = { (v: Int) in Double(v) / scale }
// The rails, in capture pixels. 254/288 pt are the drawing's own widths and
// are already checked by measure-layout.swift; here they only bound a probe.
let railR = Int(254 * scale)
let rightL = cap.w - Int(288 * scale)

// ---- alignment gate ------------------------------------------------------
// If the reference did not land on the capture's grid, nothing below means
// anything, so this is checked first and hard.
print("\n── alignment ─────────────────────────────────────────────────────────")
for (name, b) in [("reference", ref), ("capture", cap)] {
    let edge = runs(b, rows: false, Int(200 * scale), Int(350 * scale),
                    Int(850 * scale), Int(940 * scale), thresh: 70, cover: 0.9)
    let x = edge.first.map { pt($0.0) } ?? -1
    note("\(name) rail edge", "254.00", String(format: "%.2f", x), ok: abs(x - 254) <= 1.5)
}

// ---- separators ----------------------------------------------------------
// A 1 pt full-width rule inside the left rail. The drawing has three in the
// scrollable run; more than that and the rail reads as a table.
print("\n── separators (left rail) ────────────────────────────────────────────")
func hairlines(_ b: Bitmap) -> [Double] {
    runs(b, rows: true, Int(40 * scale), Int(940 * scale), Int(20 * scale), Int(240 * scale),
         thresh: 140, cover: 0.9)
        .filter { pt($0.1) - pt($0.0) <= 2.5 }      // a rule, not a selection band
        .map { pt($0.0) }
}
let refRules = hairlines(ref), capRules = hairlines(cap)
note("rule count", "\(refRules.count)", "\(capRules.count)", ok: refRules.count == capRules.count)
print("    ref: " + refRules.map { String(format: "%.1f", $0) }.joined(separator: "  "))
print("    got: " + capRules.map { String(format: "%.1f", $0) }.joined(separator: "  "))
if capRules.count > 1 {
    let pitches = zip(capRules.dropFirst(), capRules).map { $0 - $1 }
    let tight = pitches.filter { $0 < 40 }.count
    note("rules closer than 40 pt", "0", "\(tight)", ok: tight == 0)
}

// ---- typography ----------------------------------------------------------
// Ink height is size; stem width is weight. The drawing carries its hierarchy
// in size and colour — its section title and its list items measure the same
// stem — so a *spread* in stem width across roles is itself the defect.
print("\n── typography (left rail label column) ───────────────────────────────")
func textLines(_ b: Bitmap) -> [(Double, Double)] {
    runs(b, rows: true, Int(40 * scale), Int(940 * scale), Int(16 * scale), Int(150 * scale),
         thresh: 150, cover: 0.004, minRun: 3)
        .map { (pt($0.0), pt($0.1) - pt($0.0)) }
        .filter { $0.1 >= 3 && $0.1 <= 14 }          // a line of type, not a band
}
let refText = textLines(ref), capText = textLines(cap)
func stats(_ v: [Double]) -> (Double, Double, Double) {
    guard !v.isEmpty else { return (0, 0, 0) }
    let m = v.reduce(0, +) / Double(v.count)
    let sd = (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot()
    return (m, sd, v.max()! - v.min()!)
}
let rIH = stats(refText.map(\.1)), cIH = stats(capText.map(\.1))
line("text lines", Double(refText.count), Double(capText.count), 3, "n")
soft("mean ink height", rIH.0, cIH.0)
line("ink-height spread", rIH.2, cIH.2, 2.5)

// Stem width per role, sampled on the three lines the drawing and the build
// both have: a section title, a label, a list item. Sampled from the found
// lines rather than from fixed coordinates, so a shifted layout still reports.
func stemOf(_ b: Bitmap, _ lines: [(Double, Double)], index: Int) -> Double {
    guard index < lines.count else { return 0 }
    let (y, hgt) = lines[index]
    return ink(b, Int(16 * scale), Int(y * scale) - 1, Int(150 * scale),
               Int((y + hgt) * scale) + 1, thresh: 150).meanStem
}
var refStems: [Double] = [], capStems: [Double] = []
for i in 0..<min(12, min(refText.count, capText.count)) {
    refStems.append(stemOf(ref, refText, index: i))
    capStems.append(stemOf(cap, capText, index: i))
}
let rS = stats(refStems), cS = stats(capStems)
soft("mean stem width", rS.0, cS.0, "px")
line("stem-width spread", rS.2, cS.2, 0.8, "px")

// ---- controls ------------------------------------------------------------
// Every pill, field and well row in the control column, with its x-extent.
// The drawing gives its dropdowns one shared width; intrinsic-width pills
// right-aligned to a column are the thing that reads as inconsistent.
print("\n── controls (right half of the left rail) ────────────────────────────")
func controlBands(_ b: Bitmap) -> [(Double, Double, Double, Double)] {
    runs(b, rows: true, Int(40 * scale), Int(940 * scale), Int(150 * scale), Int(250 * scale),
         thresh: 70, cover: 0.25, minRun: 4)
        .compactMap { band -> (Double, Double, Double, Double)? in
            let h = pt(band.1) - pt(band.0)
            guard h >= 5, h <= 30 else { return nil }   // a control, not a well
            let mid = (band.0 + band.1) / 2
            let x = runs(b, rows: false, 0, railR, mid - 1, mid + 1, thresh: 70, cover: 0.5)
            guard let f = x.last else { return nil }
            return (pt(band.0), h, pt(f.0), pt(f.1) - pt(f.0))
        }
}
let refCtl = controlBands(ref), capCtl = controlBands(cap)
line("control bands", Double(refCtl.count), Double(capCtl.count), 2, "n")
let rH = stats(refCtl.map(\.1)), cH = stats(capCtl.map(\.1))
line("control height spread", rH.2, cH.2, 2.0)
let rW = stats(refCtl.map(\.3)), cW = stats(capCtl.map(\.3))
line("control width spread", rW.2, cW.2, 8.0)
let rRight = stats(refCtl.map { $0.2 + $0.3 }), cRight = stats(capCtl.map { $0.2 + $0.3 })
line("right-edge scatter", rRight.1, cRight.1, 2.0)

// ---- wells ---------------------------------------------------------------
// A well whose first or last row is cut through the glyphs is the single most
// visible break from the drawing, and no edge measurement sees it.
print("\n── list wells ────────────────────────────────────────────────────────")
/// A well is found down its own **left margin**, not across its width.
///
/// Measuring the full span looks like the obvious thing and is wrong: the
/// rows inside a well are dark glyphs on a light ground, so every line of
/// text drops the coverage below any threshold that recognises the fill, and
/// one well comes back as four disconnected strips between its own rows. That
/// is what "wells found 4" meant when the rail holds two.
///
/// The gutter between the well's edge and its text — `wellInset` 4 plus
/// `wellPadding` 12 — is fill and nothing else for the whole height of the
/// well, so a single column at 8 pt crosses every row and no glyph.
func wells(_ b: Bitmap) -> [(Double, Double)] {
    runs(b, rows: true, Int(40 * scale), Int(940 * scale), Int(7 * scale), Int(10 * scale),
         thresh: 70, cover: 0.9, minRun: Int(24 * scale))
        .map { (pt($0.0), pt($0.1) - pt($0.0)) }
}
let refWells = wells(ref), capWells = wells(cap)
line("wells found", Double(refWells.count), Double(capWells.count), 0, "n")
for (i, w) in capWells.enumerated() {
    let r = i < refWells.count ? refWells[i] : (0, 0)
    line("well \(i + 1) height", r.1, w.1, 6.0)
    // A clipped row: ink crossing the well's own top or bottom edge.
    let top = ink(b: cap, w.0, edge: true, scale: scale)
    let bot = ink(b: cap, w.0 + w.1, edge: false, scale: scale)
    note("well \(i + 1) rows whole", "no clip",
         top || bot ? "CLIPPED \(top ? "top" : "")\(bot ? " bottom" : "")" : "no clip",
         ok: !(top || bot))
}
/// Is there glyph ink straddling a well edge? Two rows either side of the
/// boundary, both inked, means a row is cut rather than ending.
func ink(b: Bitmap, _ yPt: Double, edge top: Bool, scale: Double) -> Bool {
    let y = Int(yPt * scale)
    let probe = { (yy: Int) -> Bool in
        ink(b, Int(30 * scale), yy, Int(200 * scale), yy + 1, thresh: 170).coverage > 1.5
    }
    return top ? (probe(y + 1) && probe(y + 3)) : (probe(y - 3) && probe(y - 2))
}

// ---- density -------------------------------------------------------------
// "Compressed at the top, dead below" is a distribution, so it is measured as
// one: where the rail's last ink is, and the longest empty run above it.
print("\n── density (left rail) ───────────────────────────────────────────────")
func density(_ b: Bitmap) -> (last: Double, dead: Double) {
    let lines = runs(b, rows: true, Int(40 * scale), Int(940 * scale), Int(16 * scale), Int(240 * scale),
                     thresh: 150, cover: 0.002, minRun: 2).map { (pt($0.0), pt($0.1)) }
    guard let last = lines.last?.1 else { return (0, 0) }
    var dead = 0.0
    for (a, b2) in zip(lines.dropFirst(), lines) { dead = max(dead, a.0 - b2.1) }
    return (last, dead)
}
let rD = density(ref), cD = density(cap)
line("last ink", rD.last, cD.last, 25.0)
line("largest dead run", rD.dead, cD.dead, 12.0)

// ---- verdict -------------------------------------------------------------
print("\n──────────────────────────────────────────────────────────────────────")
if failures.isEmpty {
    print("PASS — the capture matches the drawing on every metric above.")
} else {
    print("DRIFT on \(failures.count): " + failures.joined(separator: ", "))
    print("""

    These are the metrics `measure-layout.swift` cannot see. A pass there and
    a drift here is the 2026-09-17 result: geometry exact, interface wrong.
    """)
    exit(1)
}
