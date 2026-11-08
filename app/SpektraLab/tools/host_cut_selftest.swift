//  host_cut_selftest.swift — the host's cut of a decode, checked on this Mac.
//
//      tools/selftest.sh                # with the scheduler's checks
//      tools/selftest.sh --self-test    # the checks' own check: each broken rule must be caught
//
//  With a film edge the picture is cut by the app, in the decode, before the
//  engine sees it (`Sources/Engine/HostCut.swift`): the engine takes the frame
//  it is handed as the gate. A cut that came out mirrored, turned the other
//  way or a pixel to one side would develop into a film that is not the one
//  the guide showed, and nothing would say so. So here a picture whose every
//  pixel says where it came from — red its column, green its row, blue a
//  chequerboard that any resampling greys — is put through `HostCut.image`,
//  as `FrameDecoder` puts a decode through it, and every pixel of the cut is
//  held against the model's own answer for it: `Geometry.sourcePoint(forOutput:)`,
//  which the page's guide draws through and the engine's own cut transliterates.
//
//  Compiled with `Geometry.swift` and `HostCut.swift` alone: no engine, no
//  Metal, Core Image's software renderer with colour management off.
//
//  AGENTS.md: a check that cannot fire is not a check. `--self-test` runs the
//  same checks against a rule broken on purpose, one at a time, and requires
//  each run to fail.

import CoreGraphics
import CoreImage
import Foundation

/// The rules under test, so a broken one can be put in their place.
struct Rules {
    var name = "the app's"
    var cut: (CIImage, Geometry) -> CIImage = { HostCut.image($0, by: $1) }
    var size: (Geometry, CGSize) -> CGSize = { HostCut.map($0, imageSize: $1).size }

    /// `HostCut.image` with its map got another way.
    static func cutting(_ name: String, _ map: @escaping (Geometry, CGSize) -> (size: CGSize, toSource: CGAffineTransform),
                        turnedOver: Bool = true) -> Rules {
        Rules(name: name, cut: { image, g in
            let whole = image.extent.integral
            let size = CGSize(width: whole.width, height: whole.height)
            let (out, toSource) = map(g, size)
            let flipSource = turnedOver ? CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height) : .identity
            let flipOut = turnedOver ? CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: out.height) : .identity
            let toCut = flipSource.concatenating(toSource.inverted()).concatenating(flipOut)
            return image.clampedToExtent().transformed(by: toCut).cropped(to: CGRect(origin: .zero, size: out))
        })
    }

    /// `HostCut.image` of another cut than the one asked.
    static func cuttingAs(_ name: String, _ other: @escaping (Geometry) -> Geometry) -> Rules {
        Rules(name: name, cut: { HostCut.image($0, by: other($1)) })
    }

    static let broken: [Rules] = [
        cutting("the map not turned over for Core Image, whose y runs upward", { HostCut.map($0, imageSize: $1) }, turnedOver: false),
        cutting("a cut placed between the picture's pixels", { g, size in
            (g.gateSize(for: size), g.outputToSourceTransform(imageSize: size))
        }),
        cuttingAs("the photo's flips left out", { g in var o = g; o.flipH = false; o.flipV = false; return o }),
        cuttingAs("one flip for the other", { g in var o = g; (o.flipH, o.flipV) = (g.flipV, g.flipH); return o }),
        cuttingAs("the quarter turns the other way round", { g in var o = g; o.quarterTurns = (4 - g.quarterTurns) % 4; return o }),
        cuttingAs("the film's half turn left out", { g in var o = g; o.quarterTurns = g.quarterTurns % 2; return o }),
        cuttingAs("the cut about the middle of the picture, wherever it was placed", { g in
            var o = g; o.crop.x = (1 - g.crop.width) / 2; o.crop.y = (1 - g.crop.height) / 2; return o
        }),
        cuttingAs("the straighten left out", { g in var o = g; o.angle = 0; return o }),
        cuttingAs("the straighten the other way", { g in var o = g; o.angle = -g.angle; return o }),
        Rules(name: "a square gate's two sides rounded apart", cut: { image, g in
            HostCut.image(image, by: g).cropped(to: CGRect(origin: .zero, size: g.outputSize(for: image.extent.size)))
        }, size: { $0.outputSize(for: $1) }),
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

/// The image's pixels, top row first (as `FrameDecoder` reads a decode out).
func pixels(_ image: CIImage) -> (bytes: [UInt8], w: Int, h: Int) {
    let e = image.extent.integral
    let w = Int(e.width), h = Int(e.height)
    var bytes = [UInt8](repeating: 0, count: max(w * h * 4, 4))
    guard w > 0, h > 0 else { return (bytes, 0, 0) }
    context.render(image, toBitmap: &bytes, rowBytes: w * 4, bounds: e, format: .RGBA8, colorSpace: nil)
    return (bytes, w, h)
}

func geometry(x: Double, y: Double, w: Double, h: Double, angle: Double = 0, turns: Int = 0,
              flipH: Bool = false, flipV: Bool = false) -> Geometry {
    var g = Geometry()
    g.crop = CropRect(x: x, y: y, width: w, height: h)
    g.angle = angle
    g.quarterTurns = turns
    g.flipH = flipH
    g.flipV = flipV
    return g
}

func run(_ rules: Rules, quiet: Bool) -> (passed: Int, failed: [String]) {
    var passed = 0
    var failed: [String] = []
    func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
        if ok { passed += 1 } else { failed.append(what()); if !quiet { print("  FAIL  \(what())") } }
    }

    let W = 240, H = 180
    let size = CGSize(width: W, height: H)
    let picture = coordinatePicture(W, H)

    // The picture read straight back: the harness itself, before anything is cut.
    let whole = pixels(picture)
    expect(whole.w == W && whole.h == H && whole.bytes[0] == 0 && whole.bytes[1] == 0
           && whole.bytes[(5 * W + 7) * 4] == 7 && whole.bytes[(5 * W + 7) * 4 + 1] == 5,
           "the picture reads back top row first, a pixel for a pixel")

    /// One cut, every pixel of it. With no straighten each pixel is one of the
    /// picture's own, within a pixel of where the model puts it; with one it
    /// is the model's place to within a pixel and a half.
    func check(_ g: Geometry, _ label: String) {
        let want = HostCut.map(g, imageSize: size).size
        let got = pixels(rules.cut(picture, g))
        guard got.w == Int(want.width), got.h == Int(want.height), got.w > 0, got.h > 0 else {
            expect(false, "\(label): the cut is \(got.w) x \(got.h), not \(Int(want.width)) x \(Int(want.height))")
            return
        }
        let straight = g.angle == 0
        // A pixel's worth of the edge is left out of a straightened cut: its last samples may reach the repeat.
        let inset = straight ? 0 : 2
        var worst = 0.0, greyed = 0, outside = 0, wrongSquare = 0
        for j in inset..<(got.h - inset) {
            for i in inset..<(got.w - inset) {
                let o = (j * got.w + i) * 4
                let r = Double(got.bytes[o]), gr = Double(got.bytes[o + 1]), b = Int(got.bytes[o + 2])
                let p = g.sourcePoint(forOutput: CGPoint(x: (Double(i) + 0.5) / Double(got.w), y: (Double(j) + 0.5) / Double(got.h)),
                                      imageSize: size)
                // The model's place for this pixel, as a pixel's index (its centre is at index + 0.5).
                let sx = Double(p.x) * Double(W) - 0.5, sy = Double(p.y) * Double(H) - 0.5
                worst = max(worst, abs(r - sx), abs(gr - sy))
                if straight {
                    if b != 0 && b != 255 { greyed += 1 }
                    else if (b == 255) != ((Int(r) + Int(gr)) % 2 == 0) { wrongSquare += 1 }
                    if sx < -1.01 || sy < -1.01 || sx > Double(W) + 0.01 || sy > Double(H) + 0.01 { outside += 1 }
                }
            }
        }
        expect(worst <= (straight ? 1.01 : 1.5), "\(label): every pixel is where the model puts it (the furthest is \(String(format: "%.2f", worst)) px off)")
        if straight {
            expect(greyed == 0, "\(label): no pixel is resampled (\(greyed) are a mix of two)")
            expect(wrongSquare == 0, "\(label): every pixel is one whole pixel of the picture (\(wrongSquare) are not)")
            expect(outside == 0, "\(label): no pixel is from past the picture's edge (\(outside) are)")
        }
    }

    // Moves, quarter turns and flips, over three cuts: the whole picture, a
    // square out of its middle (6×6 from a 4:3 photo), and one placed between pixels.
    let cuts: [(String, Double, Double, Double, Double)] = [
        ("whole", 0, 0, 1, 1),
        ("square", 0.125, 0, 0.75, 1),
        ("placed", 0.1037, 0.0519, 0.6021, 0.4517),
    ]
    for (name, x, y, w, h) in cuts {
        for turns in 0..<4 {
            for (fh, fv) in [(false, false), (true, false), (false, true), (true, true)] {
                check(geometry(x: x, y: y, w: w, h: h, turns: turns, flipH: fh, flipV: fv),
                      "\(name), \(turns * 90)°\(fh ? ", flipped across" : "")\(fv ? ", flipped down" : "")")
            }
        }
    }
    // A cut that reaches the picture's far edges exactly, turned: its rounding may not carry it past them.
    for turns in 0..<4 {
        check(geometry(x: 0.3979, y: 0.5483, w: 0.6021, h: 0.4517, turns: turns), "to the far corner, \(turns * 90)°")
    }
    // Straightened: resampled once, and still where the model puts it.
    for angle in [3.8, -3.8, 12.0, -12.0] {
        for (turns, fh) in [(0, false), (1, false), (2, true), (3, false)] {
            check(geometry(x: 0.3, y: 0.3, w: 0.4, h: 0.4, angle: angle, turns: turns, flipH: fh),
                  "straightened \(angle)°, \(turns * 90)°\(fh ? ", flipped across" : "")")
        }
    }

    // A square gate: its two sides are rounded apart at some sizes (100.4 and
    // 100.6 px here), and the engine would then run a 6×6 film down the frame.
    let nearly = geometry(x: 0.2, y: 0.2, w: 100.4 / Double(W), h: 100.6 / Double(H))
    let plain = nearly.outputSize(for: size)
    expect(plain.width != plain.height, "the square case is one the rounding splits (\(Int(plain.width)) x \(Int(plain.height)))")
    let gate = rules.size(nearly, size)
    expect(gate.width == gate.height, "a cut within a pixel of square is handed over square (\(Int(gate.width)) x \(Int(gate.height)))")
    let made = pixels(rules.cut(picture, nearly))
    expect(made.w == made.h, "and its pixels are (\(made.w) x \(made.h))")
    // A gate that is not square is left as it is.
    let wide = geometry(x: 0.1, y: 0.1, w: 0.8, h: 0.6)
    expect(rules.size(wide, size) == wide.outputSize(for: size), "a 3:2 cut keeps its own size")

    return (passed, failed)
}

@main
enum HostCutSelfTest {
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
            print("host cut checks' own check: \(caught) of \(Rules.broken.count) broken rules caught")
            exit(caught == Rules.broken.count ? 0 : 1)
        }
        let r = run(Rules(), quiet: false)
        print("host cut checks: \(r.passed) passed, \(r.failed.count) failed")
        exit(r.failed.isEmpty ? 0 : 1)
    }
}
