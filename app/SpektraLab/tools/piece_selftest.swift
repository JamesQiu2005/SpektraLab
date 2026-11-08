//  piece_selftest.swift — a half-frame pair's picture under its hole, checked on this Mac.
//
//      tools/selftest.sh                # with the scheduler's checks
//      tools/selftest.sh --self-test    # the checks' own check: each broken rule must be caught
//
//  A pair's frame is made by the app, in the decode, before the engine sees it
//  (`Sources/Engine/PiecePlacer.swift`, `FrameDecoder.decode(_:meter:)`): each
//  picture cut as its frame cuts it, turned by its placement's quarter turns,
//  and the placement's window of that scaled into its hole. A picture that
//  came out mirrored, turned the other way, or showing another part of itself
//  than the pair's page showed would develop into a piece nobody laid out,
//  and nothing would say so.
//
//  So here a picture whose every pixel says where it came from — red its
//  column, green its row, blue a chequerboard that any resampling greys — is
//  put under a hole by `PiecePlacer.place`, as `FrameDecoder` puts a decode
//  under one, and every pixel of the hole is held against **the pair's own
//  answer for it**: the window is `HalfFramePair.sourceRect` (what the pair's
//  page draws the guide through and a drag and a pinch move), the turn is the
//  placement's, and the frame's own cut is `Geometry.sourcePoint(forOutput:)`.
//
//  **And a frame's own print, cut into the film's** (`Sources/Engine/PrintLayers.swift`,
//  `PrintCut.cut`, since 2026-10-10). A frame of a pair that prints as its own
//  is another print of the same negative, taken into the first inside the
//  frame's rectangle by the engine's host, on the engine's own 16-bit pixels.
//  Two prints that cannot be mistaken for each other are cut together here,
//  and every channel of every pixel — and every word of each row's padding —
//  is held against **the desktop's kernel as it is written**
//  (`Canvas/Shaders.metal`, `pairCoverage` and `pairComposite`; the rectangle
//  in pixels and the 1.5 px feather as `Renderer.compositePair` hands them).
//
//  Compiled with the pair's model, `Geometry`, `HostCut`, `PiecePlacer` and
//  `PrintLayers`: no engine, no Metal, Core Image's software renderer with
//  colour management off.
//
//  AGENTS.md: a check that cannot fire is not a check. `--self-test` runs the
//  same checks against a rule broken on purpose, one at a time, and requires
//  each run to fail.

import CoreGraphics
import CoreImage
import Foundation
import SwiftUI

// `Stock.color` is the app's (`Theme.swift`, which is not compiled here). Nothing below looks at a colour.
extension Color {
    init(hexString: String) { self = .gray }
}

/// The rules under test, so a broken one can be put in their place.
struct Rules {
    var name = "the app's"
    /// A decode, the frame's own cut, the placement's quarter turns, the window, the hole's size.
    var place: (CIImage, Geometry, Int, CGRect, CGSize) -> CIImage = {
        PiecePlacer.place($0, cut: $1, quarterTurns: $2, window: $3, size: $4)
    }
    /// A frame's own print cut into the film's: the print and its row pitch, the film's print and
    /// its own, the picture's size, and the frame's rectangle on it. What comes back is the part
    /// of the picture the cut says it may have written.
    var cut: Cut = { layer, layerStride, base, baseStride, width, height, rect in
        PrintCut.cut(layer, stride: layerStride, into: base, stride: baseStride, width: width, height: height, rect: rect)
    }
    typealias Cut = (UnsafePointer<UInt16>, Int, UnsafeMutablePointer<UInt16>, Int, Int, Int, CGRect) -> PrintCut.Written?

    static let broken: [Rules] = placing + cutting

    static let cutting: [Rules] = [
        Rules(name: "a hard cut: no feather at the frame's edge", cut: { layer, ls, base, bs, w, h, rect in
            PrintCut.cut(layer, stride: ls, into: base, stride: bs, width: w, height: h, rect: rect, feather: 0)
        }),
        Rules(name: "a feather twice the desktop's", cut: { layer, ls, base, bs, w, h, rect in
            PrintCut.cut(layer, stride: ls, into: base, stride: bs, width: w, height: h, rect: rect, feather: 3)
        }),
        Rules(name: "the frame's rectangle counted from the picture's foot", cut: { layer, ls, base, bs, w, h, rect in
            PrintCut.cut(layer, stride: ls, into: base, stride: bs, width: w, height: h,
                         rect: CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height))
        }),
        Rules(name: "the frame's rectangle mirrored", cut: { layer, ls, base, bs, w, h, rect in
            PrintCut.cut(layer, stride: ls, into: base, stride: bs, width: w, height: h,
                         rect: CGRect(x: 1 - rect.maxX, y: rect.minY, width: rect.width, height: rect.height))
        }),
        Rules(name: "a pixel taken by its corner, not its centre: the cut half a pixel off", cut: { layer, ls, base, bs, w, h, rect in
            PrintCut.cut(layer, stride: ls, into: base, stride: bs, width: w, height: h,
                         rect: rect.offsetBy(dx: 0.5 / CGFloat(w), dy: 0.5 / CGFloat(h)))
        }),
        Rules(name: "the frame's print laid over the whole picture", cut: { layer, ls, base, bs, w, h, _ in
            PrintCut.cut(layer, stride: ls, into: base, stride: bs, width: w, height: h, rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        }),
        Rules(name: "the film's row pitch taken for the print's too", cut: { layer, _, base, bs, w, h, rect in
            PrintCut.cut(layer, stride: bs, into: base, stride: bs, width: w, height: h, rect: rect)
        }),
        Rules(name: "the picture's width taken for a row's pitch: every row after the first sheared", cut: { layer, _, base, _, w, h, rect in
            PrintCut.cut(layer, stride: w, into: base, stride: w, width: w, height: h, rect: rect)
        }),
        Rules(name: "the edge's pixels given whole to the frame", cut: { layer, ls, base, bs, w, h, rect in
            // The feather's reach, and no mix inside it.
            let grown = rect.insetBy(dx: -0.75 / CGFloat(w), dy: -0.75 / CGFloat(h))
            return PrintCut.cut(layer, stride: ls, into: base, stride: bs, width: w, height: h, rect: grown, feather: 0)
        }),
        Rules(name: "three channels cut in and the fourth left the film's", cut: { layer, ls, base, bs, w, h, rect in
            var kept = [UInt16](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w { kept[y * w + x] = base[(y * bs + x) * 4 + 2] } }
            let wrote = PrintCut.cut(layer, stride: ls, into: base, stride: bs, width: w, height: h, rect: rect)
            for y in 0..<h { for x in 0..<w { base[(y * bs + x) * 4 + 2] = kept[y * w + x] } }
            return wrote
        }),
        // What a cut says it wrote is what a picture made from a copy of the result is given (the simulator's).
        Rules(name: "a cut that says it wrote less than it did: a copy keeps the film's print round the frame's edge", cut: { layer, ls, base, bs, w, h, rect in
            guard let wrote = PrintCut.cut(layer, stride: ls, into: base, stride: bs, width: w, height: h, rect: rect),
                  wrote.columns.count > 4, wrote.rows.count > 4 else { return nil }
            return PrintCut.Written(columns: (wrote.columns.lowerBound + 2)...(wrote.columns.upperBound - 2),
                                    rows: (wrote.rows.lowerBound + 2)...(wrote.rows.upperBound - 2))
        }),
        Rules(name: "a cut that says nothing of what it wrote: a copy never has the frame's print", cut: { layer, ls, base, bs, w, h, rect in
            PrintCut.cut(layer, stride: ls, into: base, stride: bs, width: w, height: h, rect: rect)
            return nil
        }),
        Rules(name: "a cut that says it wrote the whole picture: all of it copied again for a frame's print", cut: { layer, ls, base, bs, w, h, rect in
            PrintCut.cut(layer, stride: ls, into: base, stride: bs, width: w, height: h, rect: rect).map { _ in
                PrintCut.Written(columns: 0...(w - 1), rows: 0...(h - 1))
            }
        }),
    ]

    static let placing: [Rules] = [
        Rules(name: "the placement's quarter turns the other way round") { image, cut, turns, window, size in
            PiecePlacer.place(image, cut: cut, quarterTurns: 4 - turns, window: window, size: size)
        },
        Rules(name: "the placement's turn left out") { image, cut, _, window, size in
            PiecePlacer.place(image, cut: cut, quarterTurns: 0, window: window, size: size)
        },
        Rules(name: "the frame's own cut left out") { image, _, turns, window, size in
            PiecePlacer.place(image, cut: .default, quarterTurns: turns, window: window, size: size)
        },
        Rules(name: "the window upside down: taken from the picture's foot, as Core Image counts") { image, cut, turns, window, size in
            PiecePlacer.place(image, cut: cut, quarterTurns: turns,
                              window: CGRect(x: window.minX, y: 1 - window.maxY, width: window.width, height: window.height), size: size)
        },
        Rules(name: "the window mirrored") { image, cut, turns, window, size in
            PiecePlacer.place(image, cut: cut, quarterTurns: turns,
                              window: CGRect(x: 1 - window.maxX, y: window.minY, width: window.width, height: window.height), size: size)
        },
        Rules(name: "the whole picture squeezed into the hole, whatever the window") { image, cut, turns, _, size in
            PiecePlacer.place(image, cut: cut, quarterTurns: turns, window: CGRect(x: 0, y: 0, width: 1, height: 1), size: size)
        },
        Rules(name: "the window cut out before it is scaled, its edge mixed with nothing") { image, cut, turns, window, size in
            // `PiecePlacer.place` with its last crop made first, and no edge repeated.
            var picture = HostCut.image(image, by: cut)
            let framed = picture.extent.size
            switch ((turns % 4) + 4) % 4 {
            case 1: picture = picture.transformed(by: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: framed.width))
            case 2: picture = picture.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: framed.width, ty: framed.height))
            case 3: picture = picture.transformed(by: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: framed.height, ty: 0))
            default: break
            }
            let turned = picture.extent.size
            let shown = PiecePlacer.shown(window, of: turned)
            let part = CGRect(x: shown.minX, y: turned.height - shown.maxY, width: shown.width, height: shown.height)
            return picture.cropped(to: part)
                .transformed(by: .init(translationX: -part.minX, y: -part.minY))
                .transformed(by: .init(scaleX: size.width / shown.width, y: size.height / shown.height))
        },
    ]
}

/// A picture `w` by `h` whose pixels say where they are: red the column,
/// green the row, blue a chequerboard. Top row first.
func coordinatePicture(_ w: Int, _ h: Int) -> CIImage {
    var bytes = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            bytes[i] = UInt8(x); bytes[i + 1] = UInt8(y); bytes[i + 2] = (x + y) % 2 == 0 ? 255 : 0
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    return CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
}

let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .useSoftwareRenderer: true])

/// A hole's pixels, top row first (as `FrameDecoder` renders a picture into its hole of the piece).
func pixels(_ image: CIImage, _ w: Int, _ h: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: max(w * h * 4, 4))
    context.render(image, toBitmap: &bytes, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: nil)
    return bytes
}

func geometry(x: Double = 0, y: Double = 0, w: Double = 1, h: Double = 1, turns: Int = 0, flipH: Bool = false, flipV: Bool = false) -> Geometry {
    var g = Geometry()
    g.crop = CropRect(x: x, y: y, width: w, height: h)
    g.quarterTurns = turns
    g.flipH = flipH
    g.flipV = flipV
    return g
}

func placement(scale: Double = 1, x: Double = 0, y: Double = 0, turns: Int = 0) -> HalfFramePair.Placement {
    var p = HalfFramePair.Placement()
    p.scale = scale; p.x = x; p.y = y; p.quarterTurns = turns
    return p
}

func run(_ rules: Rules, quiet: Bool) -> (passed: Int, failed: [String]) {
    var passed = 0
    var failed: [String] = []
    func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
        if ok { passed += 1 } else { failed.append(what()); if !quiet { print("  FAIL  \(what())") } }
    }

    /// One picture under one hole, every pixel of the hole.
    /// `enlarge` is how many of the hole's pixels a pixel of the window is given: 1 is a pixel for a pixel.
    func check(_ W: Int, _ H: Int, _ g: Geometry, _ p: HalfFramePair.Placement, aspect: Double, enlarge: Double, _ label: String) {
        let size = CGSize(width: W, height: H)
        let picture = coordinatePicture(W, H)
        // The pair's own arithmetic: the frame as its owner cut it, turned by the placement, and the window of that.
        let framed = HostCut.map(g, imageSize: size).size
        let turned = HalfFramePair.turned(framed, by: p)
        let rect = HalfFramePair.sourceRect(for: p, source: turned, aspect: aspect)
        guard rect.width >= 2, rect.height >= 2 else { expect(false, "\(label): the pair shows no part of the picture"); return }
        let window = CGRect(x: rect.minX / turned.width, y: rect.minY / turned.height,
                            width: rect.width / turned.width, height: rect.height / turned.height)
        let hw = max(Int((rect.width * enlarge).rounded()), 1), hh = max(Int((rect.height * enlarge).rounded()), 1)
        let placed = rules.place(picture, g, p.quarterTurns, window, CGSize(width: hw, height: hh))
        let extent = placed.extent
        expect(abs(extent.minX) < 0.01 && abs(extent.minY) < 0.01 && abs(extent.width - CGFloat(hw)) < 0.01 && abs(extent.height - CGFloat(hh)) < 0.01,
               "\(label): the picture is the hole's size, at the origin (\(extent))")
        let got = pixels(placed, hw, hh)
        // A pixel for a pixel only where the window lies on whole pixels and is not enlarged.
        let whole = enlarge == 1 && rect.minX == rect.minX.rounded() && rect.minY == rect.minY.rounded()
            && rect.width == CGFloat(hw) && rect.height == CGFloat(hh)
        var worst = 0.0, greyed = 0, wrongSquare = 0
        let k = ((p.quarterTurns % 4) + 4) % 4
        for j in 0..<hh {
            for i in 0..<hw {
                let o = (j * hw + i) * 4
                let r = Double(got[o]), gr = Double(got[o + 1]), b = Int(got[o + 2])
                // This pixel's place in the turned picture, with a top-left origin.
                let xt = rect.minX + (CGFloat(i) + 0.5) / CGFloat(hw) * rect.width
                let yt = rect.minY + (CGFloat(j) + 0.5) / CGFloat(hh) * rect.height
                // Turned back: clockwise by a quarter, the picture's top-left corner is the turned one's top-right.
                let xf: CGFloat, yf: CGFloat
                switch k {
                case 1: (xf, yf) = (yt, framed.height - xt)
                case 2: (xf, yf) = (framed.width - xt, framed.height - yt)
                case 3: (xf, yf) = (framed.width - yt, xt)
                default: (xf, yf) = (xt, yt)
                }
                // And through the frame's own cut, to the picture as the file has it.
                let s = g.sourcePoint(forOutput: CGPoint(x: xf / framed.width, y: yf / framed.height), imageSize: size)
                let sx = Double(s.x) * Double(W) - 0.5, sy = Double(s.y) * Double(H) - 0.5
                worst = max(worst, abs(r - sx), abs(gr - sy))
                if whole {
                    if b != 0 && b != 255 { greyed += 1 }
                    else if (b == 255) != ((Int(r) + Int(gr)) % 2 == 0) { wrongSquare += 1 }
                }
            }
        }
        // A resampled pixel is a byte's rounding from its place; one moved as it is, exactly there.
        expect(worst <= (whole ? 0.01 : 0.75), "\(label): every pixel is where the pair puts it (the furthest is \(String(format: "%.2f", worst)) px off)")
        if whole {
            expect(greyed == 0, "\(label): no pixel is resampled (\(greyed) are a mix of two)")
            expect(wrongSquare == 0, "\(label): every pixel is one whole pixel of the picture (\(wrongSquare) are not)")
        }
    }

    let level = HalfFramePair.holeMM.along / HalfFramePair.holeMM.across        // 18 × 24, upright
    let stacked = HalfFramePair.holeMM.across / HalfFramePair.holeMM.along      // the camera turned: 24 × 18

    // The picture read straight back under a hole of its own shape: the harness itself.
    check(180, 240, geometry(), placement(), aspect: level, enlarge: 1, "a 3:4 picture under an upright hole")
    check(240, 180, geometry(), placement(), aspect: stacked, enlarge: 1, "a 4:3 picture under a hole of a camera turned")

    // The fit: the middle of a picture wider, or taller, than its hole.
    check(200, 120, geometry(), placement(), aspect: level, enlarge: 1, "a wide picture, the middle of it")
    check(120, 220, geometry(), placement(), aspect: stacked, enlarge: 1, "a tall picture under a wide hole, the middle of it")

    // Moved under the hole, to each side and each corner, at its fit and enlarged.
    for (x, y) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0), (1.0, 1.0), (-1.0, -1.0), (0.37, -0.61)] {
        check(200, 120, geometry(), placement(x: x, y: y), aspect: level, enlarge: 1, "moved to \(x), \(y)")
        check(200, 120, geometry(), placement(scale: 2, x: x, y: y), aspect: level, enlarge: 1, "enlarged 2×, moved to \(x), \(y)")
        check(200, 120, geometry(), placement(scale: 3.5, x: x, y: y), aspect: stacked, enlarge: 2, "enlarged 3.5× under a wide hole, moved to \(x), \(y)")
    }

    // The placement's quarter turns, with the picture off its middle so a turn the wrong way shows.
    for turns in 0..<4 {
        check(200, 120, geometry(), placement(turns: turns), aspect: level, enlarge: 1, "turned \(turns * 90)° under its hole")
        check(200, 120, geometry(), placement(scale: 2, x: 1, y: -1, turns: turns), aspect: level, enlarge: 1,
              "turned \(turns * 90)°, enlarged 2×, in a corner")
        check(200, 120, geometry(), placement(scale: 1.6, x: -0.4, y: 0.8, turns: turns), aspect: stacked, enlarge: 1.5,
              "turned \(turns * 90)°, enlarged 1.6× under a wide hole")
    }

    // The frame's own cut first: a frame cropped, turned or flipped by itself is that in the pair.
    let cuts: [(String, Geometry)] = [
        ("cropped", geometry(x: 0.1, y: 0.2, w: 0.6, h: 0.5)),
        ("turned by itself", geometry(turns: 1)),
        ("turned and cropped", geometry(x: 0.25, y: 0.1, w: 0.5, h: 0.8, turns: 3)),
        ("flipped across", geometry(flipH: true)),
        ("flipped down, cropped", geometry(x: 0.05, y: 0.3, w: 0.7, h: 0.6, flipV: true)),
        ("turned half round and flipped", geometry(turns: 2, flipH: true)),
    ]
    for (name, g) in cuts {
        for turns in [0, 1, 3] {
            check(200, 120, g, placement(scale: 1.5, x: 0.6, y: -0.3, turns: turns), aspect: level, enlarge: 1,
                  "a frame \(name), then turned \(turns * 90)° under its hole")
        }
        check(200, 120, g, placement(scale: 2.2, x: -1, y: 1), aspect: stacked, enlarge: 0.8, "a frame \(name), under a wide hole, made smaller")
    }

    // A hole smaller than its window (a job at preview size), and larger (a picture enlarged into its hole).
    for enlarge in [0.6, 0.85, 1.3, 2.5] {
        check(200, 120, geometry(), placement(scale: 1.4, x: 0.2, y: 0.5), aspect: level, enlarge: enlarge, "the hole \(enlarge)× its window")
    }

    // A window a rounding outside the picture stays inside it.
    let held = PiecePlacer.shown(CGRect(x: -0.001, y: 0.7, width: 0.5, height: 0.3004), of: CGSize(width: 200, height: 120))
    expect(held.minX >= 0 && held.maxX <= 200.0001 && held.minY >= 0 && held.maxY <= 120.0001,
           "a window a rounding past the picture's edge is held inside it (\(held))")

    // MARK: a frame's own print, cut into the film's

    // Two prints that cannot be taken for each other: every channel of every pixel its own
    // number, the film's below 20,000 and the frame's from 40,000, so a pixel says which print it
    // is of, where in it, and how much of each a mixed one holds.
    func film(_ x: Int, _ y: Int, _ ch: Int) -> UInt16 { UInt16((x * 7 + y * 13 + ch * 101) % 20_000) }
    func own(_ x: Int, _ y: Int, _ ch: Int) -> UInt16 { UInt16(40_000 + (x * 11 + y * 5 + ch * 211) % 20_000) }
    let padding: UInt16 = 0xBEEF

    /// The frame's own print cut into the film's inside each of `rects`, one after another, on a
    /// picture `w` by `h` whose rows are `baseStride` and `layerStride` pixels apart — and every
    /// channel of every pixel held against the desktop's kernel. Returns the picture, for a check
    /// that names a pixel.
    @discardableResult
    func cutCheck(_ w: Int, _ h: Int, _ rects: [CGRect], baseStride: Int, layerStride: Int, _ label: String) -> [UInt16] {
        var base = [UInt16](repeating: padding, count: baseStride * h * 4)
        var layer = [UInt16](repeating: padding, count: layerStride * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                for ch in 0..<4 {
                    base[(y * baseStride + x) * 4 + ch] = film(x, y, ch)
                    layer[(y * layerStride + x) * 4 + ch] = own(x, y, ch)
                }
            }
        }
        let read = layer
        var said: [PrintCut.Written?] = []
        base.withUnsafeMutableBufferPointer { to in
            layer.withUnsafeBufferPointer { from in
                for rect in rects { said.append(rules.cut(from.baseAddress!, layerStride, to.baseAddress!, baseStride, w, h, rect)) }
            }
        }
        var wrong = 0, furthest = 0, past = 0, inside = 0, outside = 0, mixed = 0, unsaid = 0
        for y in 0..<h {
            for x in 0..<baseStride {
                // The desktop's `pairComposite`: the film's print, then each frame's mixed in by its coverage.
                let shares = rects.map { desktopCoverage(x, y, $0, w, h) }
                if x < w {
                    if shares.contains(where: { $0 >= 1 }) { inside += 1 } else if shares.allSatisfy({ $0 <= 0 }) { outside += 1 } else { mixed += 1 }
                    // A pixel with any of a frame's print in it is one the cut says it wrote.
                    if shares.contains(where: { $0 > 0 }), !said.contains(where: { $0.map { $0.columns.contains(x) && $0.rows.contains(y) } ?? false }) { unsaid += 1 }
                }
                for ch in 0..<4 {
                    let got = base[(y * baseStride + x) * 4 + ch]
                    guard x < w else { if got != padding { past += 1 }; continue }
                    var want = Double(film(x, y, ch))
                    for share in shares { want += (Double(own(x, y, ch)) - want) * share }
                    let off = abs(Int(got) - Int(want.rounded()))
                    if off != 0 { wrong += 1; furthest = max(furthest, off) }
                }
            }
        }
        expect(wrong == 0, "\(label): every pixel is the desktop's mix of the two prints (\(wrong) channels are not; the furthest is \(furthest) codes off)")
        expect(past == 0, "\(label): nothing is written past a row's end (\(past) words of the pitch's padding were)")
        expect(layer == read, "\(label): the frame's own print is read, and never written")
        // What a cut says it wrote: all of it — a picture made from a copy of the result is given
        // exactly that (`EngineHost.carry`, the simulator's) — and no more than the frame and its edge.
        expect(unsaid == 0, "\(label): every pixel with any of the frame's print in it is in what the cut says it wrote (\(unsaid) are not)")
        for (rect, wrote) in zip(rects, said) {
            guard let wrote else { expect(false, "\(label): a cut that wrote says what"); continue }
            let x0 = Double(rect.minX) * Double(w), x1 = Double(rect.maxX) * Double(w), y0 = Double(rect.minY) * Double(h), y1 = Double(rect.maxY) * Double(h)
            expect(wrote.columns.lowerBound >= 0 && wrote.columns.upperBound < w && wrote.rows.lowerBound >= 0 && wrote.rows.upperBound < h,
                   "\(label): what the cut says it wrote is on the picture (\(wrote))")
            // A pixel is in it while its centre is within half the feather of the frame: no column or row further out.
            let reach = 0.75 + 1e-9
            expect(Double(wrote.columns.lowerBound) + 0.5 >= max(x0 - reach, 0) && Double(wrote.columns.upperBound) + 0.5 <= min(x1 + reach, Double(w))
                   && Double(wrote.rows.lowerBound) + 0.5 >= max(y0 - reach, 0) && Double(wrote.rows.upperBound) + 0.5 <= min(y1 + reach, Double(h)),
                   "\(label): and is no more than the frame and its feather (\(wrote) for a frame \(x0)…\(x1) by \(y0)…\(y1))")
        }
        // Without all three the check holds nothing: a frame's own pixels, the film's, and an edge between them.
        expect(inside > 0 && outside > 0 && mixed > 0, "\(label): the picture has the frame's pixels (\(inside)), the film's (\(outside)) and an edge (\(mixed))")
        return base
    }

    // A frame on whole pixels, where the numbers can be said: columns 10 to 29 and rows 8 to 19 of a 40 × 30 picture.
    do {
        let w = 40, h = 30, pitch = 48
        let frame = CGRect(x: 10.0 / 40, y: 8.0 / 30, width: 20.0 / 40, height: 12.0 / 30)
        let cut = cutCheck(w, h, [frame], baseStride: pitch, layerStride: pitch, "a frame on whole pixels")
        func got(_ x: Int, _ y: Int, _ ch: Int = 0) -> Int { Int(cut[(y * pitch + x) * 4 + ch]) }
        func mix(_ x: Int, _ y: Int, _ share: Double, _ ch: Int = 0) -> Int {
            Int((Double(film(x, y, ch)) + (Double(own(x, y, ch)) - Double(film(x, y, ch))) * share).rounded())
        }
        expect(got(11, 14) == Int(own(11, 14, 0)) && got(20, 14) == Int(own(20, 14, 0)), "inside the frame a pixel is the frame's own print, as it is")
        expect(got(8, 14) == Int(film(8, 14, 0)) && got(31, 14) == Int(film(31, 14, 0)) && got(20, 2) == Int(film(20, 2, 0)),
               "outside it a pixel is the film's print, as it is")
        expect(got(10, 14) == mix(10, 14, 5.0 / 6), "the frame's first column, half a pixel inside its edge, is five sixths the frame's print")
        expect(got(9, 14) == mix(9, 14, 1.0 / 6), "the column before it, half a pixel outside, is one sixth")
        expect(got(29, 14) == mix(29, 14, 5.0 / 6) && got(30, 14) == mix(30, 14, 1.0 / 6), "the same at the frame's far edge")
        expect(got(20, 8) == mix(20, 8, 5.0 / 6) && got(20, 7) == mix(20, 7, 1.0 / 6) && got(20, 19) == mix(20, 19, 5.0 / 6) && got(20, 20) == mix(20, 20, 1.0 / 6),
               "and at its top and its foot")
        expect(got(10, 8) == mix(10, 8, 5.0 / 6) && got(9, 7) == mix(9, 7, 1.0 / 6) && got(9, 8) == mix(9, 8, 1.0 / 6),
               "at a corner the nearer edge decides")
        for ch in 1..<4 {
            expect(got(10, 14, ch) == mix(10, 14, 5.0 / 6, ch) && got(20, 14, ch) == Int(own(20, 14, ch)), "channel \(ch) is cut as the first is")
        }
        // The feather is a pixel either side of the edge: two rings of them, and no more.
        var edge = 0
        for y in 0..<h { for x in 0..<w where got(x, y) != Int(film(x, y, 0)) && got(x, y) != Int(own(x, y, 0)) { edge += 1 } }
        // The ring just inside a frame 20 by 12 is 60 pixels, and the ring just outside it 68.
        expect(edge == 60 + 68, "the feather is one pixel either side of the edge: \(edge) mixed pixels, 128 for a frame 20 by 12")
    }

    // A pair's two frames, where the piece puts them (`HalfFramePair.holeRects`): held level and
    // turned, at the camera's gap and at a wider one, at sizes a host renders a piece's shape at.
    for (turned, spacing) in [(false, 1.0), (true, 1.0), (false, 2.0), (true, 0.5)] {
        var pair = HalfFramePair()
        pair.turned = turned
        pair.spacingMM = spacing
        let holes = pair.holeRects
        guard let first = holes[.left], let second = holes[.right] else { expect(false, "a pair has two holes"); continue }
        let lies = "\(turned ? "turned" : "level"), \(spacing) mm apart"
        for long in [185, 370, 411] {
            let short = Int((Double(long) * 24 / (36 + spacing)).rounded())
            let (w, h) = turned ? (short, long) : (long, short)
            // A result's rows are its width rounded up to the device's alignment; the two prints are the same device's.
            let pitch = (w + 15) / 16 * 16
            cutCheck(w, h, [second], baseStride: pitch, layerStride: pitch, "\(lies), \(w) × \(h): the second frame's own print")
            cutCheck(w, h, [first], baseStride: pitch, layerStride: pitch, "\(lies), \(w) × \(h): the first frame's")
            let both = cutCheck(w, h, [first, second], baseStride: pitch, layerStride: pitch, "\(lies), \(w) × \(h): both frames'")
            // The film between the frames is the film's print, to the last code.
            let middle = turned ? (x: w / 2, y: Int((first.maxY + second.minY) / 2 * CGFloat(h))) : (x: Int((first.maxX + second.minX) / 2 * CGFloat(w)), y: h / 2)
            expect((0..<4).allSatisfy { both[(middle.y * pitch + middle.x) * 4 + $0] == film(middle.x, middle.y, $0) },
                   "\(lies), \(w) × \(h): the film between the frames is the film's print")
        }
    }
    // A strip's gates: rectangles that touch no edge of the canvas, and lie between its pixels.
    cutCheck(246, 227, [CGRect(x: 0.0312, y: 0.2291, width: 0.4487, height: 0.5417), CGRect(x: 0.5201, y: 0.2291, width: 0.4487, height: 0.5417)],
             baseStride: 256, layerStride: 256, "a level strip's two gates")
    cutCheck(227, 246, [CGRect(x: 0.2291, y: 0.5201, width: 0.5417, height: 0.4487)], baseStride: 240, layerStride: 240, "a turned strip's second gate")
    // Each print's rows at its own pitch.
    cutCheck(100, 60, [CGRect(x: 0.2, y: 0.25, width: 0.5, height: 0.5)], baseStride: 112, layerStride: 128, "the two prints' rows at different pitches")
    cutCheck(100, 60, [CGRect(x: 0.2, y: 0.25, width: 0.5, height: 0.5)], baseStride: 100, layerStride: 100, "rows with no padding at all")
    // A frame at the picture's edge, and past it: what lies outside the picture is not there to cut.
    cutCheck(96, 64, [CGRect(x: 0, y: 0, width: 0.4865, height: 0.75)], baseStride: 96, layerStride: 96, "a frame in the picture's corner")
    cutCheck(96, 64, [CGRect(x: 0.6, y: 0.5, width: 0.7, height: 0.9)], baseStride: 112, layerStride: 112, "a frame that runs past the picture's far corner")
    cutCheck(96, 64, [CGRect(x: -0.2, y: -0.3, width: 0.6, height: 0.7)], baseStride: 112, layerStride: 112, "a frame that begins before the picture does")
    // No frame, no cut: a rectangle of no size, or wholly off the picture, leaves the film's print as it is.
    for (name, rect) in [("a rectangle of no width", CGRect(x: 0.5, y: 0.2, width: 0, height: 0.5)),
                         ("a rectangle of no height", CGRect(x: 0.2, y: 0.5, width: 0.5, height: 0)),
                         ("a rectangle off the picture", CGRect(x: 1.2, y: 0.1, width: 0.3, height: 0.5)),
                         ("a rectangle above the picture", CGRect(x: 0.1, y: -0.9, width: 0.3, height: 0.5))] {
        let (w, h, pitch) = (64, 48, 80)
        var base = [UInt16](repeating: padding, count: pitch * h * 4), layer = base
        for y in 0..<h { for x in 0..<w { for ch in 0..<4 {
            base[(y * pitch + x) * 4 + ch] = film(x, y, ch)
            layer[(y * pitch + x) * 4 + ch] = own(x, y, ch)
        } } }
        let before = base
        let said = base.withUnsafeMutableBufferPointer { to in
            layer.withUnsafeBufferPointer { from in rules.cut(from.baseAddress!, pitch, to.baseAddress!, pitch, w, h, rect) }
        }
        expect(base == before, "\(name) cuts nothing into the film's print")
        expect(said == nil, "\(name): and the cut says it wrote nothing (\(String(describing: said)))")
    }
    // The whole picture a frame's: every pixel its print.
    do {
        let (w, h, pitch) = (48, 32, 48)
        var base = [UInt16](repeating: 0, count: pitch * h * 4), layer = base
        for y in 0..<h { for x in 0..<w { for ch in 0..<4 {
            base[(y * pitch + x) * 4 + ch] = film(x, y, ch)
            layer[(y * pitch + x) * 4 + ch] = own(x, y, ch)
        } } }
        let said = base.withUnsafeMutableBufferPointer { to in
            layer.withUnsafeBufferPointer { from in rules.cut(from.baseAddress!, pitch, to.baseAddress!, pitch, w, h, CGRect(x: -0.1, y: -0.1, width: 1.2, height: 1.2)) }
        }
        expect(base == layer, "a frame larger than the picture makes every pixel its own print")
        expect(said == PrintCut.Written(columns: 0...(w - 1), rows: 0...(h - 1)), "and the cut says it wrote the whole picture, and nothing off it (\(String(describing: said)))")
    }

    return (passed, failed)
}

/// The desktop's `pairCoverage` (`Canvas/Shaders.metal`), as it is written there — the pixel's
/// centre, its distance inside the rectangle's nearest edge, over the feather and a half — on the
/// rectangle in pixels as `Renderer.compositePair` makes it, with its feather of 1.5.
func desktopCoverage(_ x: Int, _ y: Int, _ rect: CGRect, _ w: Int, _ h: Int, feather: Double = 1.5) -> Double {
    let r = (x: Double(rect.minX) * Double(w), y: Double(rect.minY) * Double(h), z: Double(rect.maxX) * Double(w), w: Double(rect.maxY) * Double(h))
    let p = (x: Double(x) + 0.5, y: Double(y) + 0.5)
    let d = min(min(p.x - r.x, r.z - p.x), min(p.y - r.y, r.w - p.y))
    return min(max(d / max(feather, 1e-3) + 0.5, 0), 1)
}

@main
enum PieceSelfTest {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            var caught = 0
            for broken in Rules.broken {
                let r = run(broken, quiet: true)
                if r.failed.isEmpty {
                    print("  NOT CAUGHT  \(broken.name)")
                } else {
                    caught += 1
                    print("  caught  \(broken.name) (\(r.failed.count) checks failed)")
                }
            }
            print("piece checks' own check: \(caught) of \(Rules.broken.count) broken rules caught")
            exit(caught == Rules.broken.count ? 0 : 1)
        }
        let r = run(Rules(), quiet: false)
        print("piece checks: \(r.passed) passed, \(r.failed.count) failed")
        exit(r.failed.isEmpty ? 0 : 1)
    }
}
