// layer2_local_selftest.swift -- Edit's pass with 成片 layers (PRD-E, RFC-052 §7, §10 gates 2, 4, 6): the local kernels.
//
//     tools/selftest.sh                       # the checks
//     tools/selftest.sh --self-test           # each broken rule below must be caught
//     build/tools/layer2_local_selftest --cost   # RFC-052 gate 6: the pass with 0, 1, 4, 8 layers (interleaved)
//
// Compiled by tools/selftest.sh with the pass (Layer2Kernel, Layer2Renderer, Layer2Local), the masks' model and baker
// (LocalLayers, MaskFrame, MaskBaker, MaskStore, SceneLayerWire for its baker registry) and Adjustments; run on this
// Mac's GPU. Nothing here measures a host.
//
//   - **identity, per control**: a layer whose mask covers the frame (k ≡ 1) with Δ on one of the eleven controls is
//     Edit's own control moved by Δ -- each control, Δ at both ends of its range and between, with the whole's own
//     value non-zero and with it zero; the bar is what float gives (measured below, printed);
//   - **half coverage is half the control**: k ≡ 0.5 (opacity ½ over a full plane) with Δ is the control moved by Δ/2
//     -- the sliders' units; red with the kernel's numbers interpolated;
//   - **neutral**: no layer that acts gives no `FinishedLayers` (today's kernels run), and inside the local variant a
//     pixel whose every k is 0 -- a zero plane, outside S, the unmasked half of a plane -- is today's to the bit, in
//     16 bits and in float;
//   - **the mask is the engine's sampling**: at texel centres k is the texel, exactly;
//   - **a preview's size against an export's**: the same layered edit at both sizes within layer2_selftest's bar, and a
//     hard edge where the photograph has it, to a pixel of the smaller, through a film edge, a quarter turn of the
//     host's, a flip and Edit's crop -- the export's surface being the engine's result before the host's turn (each
//     term broken: red).

import CoreGraphics
import Darwin
import Foundation
import Metal
import simd

/// One broken rule at a time: a change to the local kernels' source, or a flag the checks read.
struct Mutation: Equatable {
    var name: String
    var kernel: ((String) -> String)? = nil
    var flag: String? = nil
    static func == (a: Mutation, b: Mutation) -> Bool { a.name == b.name }
    static let none = Mutation(name: "none")
    static let all: [Mutation] = [
        Mutation(name: "the kernel's numbers interpolated, not the sliders'") {
            $0.replacingOccurrences(of: "if (d[0] != 0.0f) v.exposureGain = exp2(L.base[0] + d[0]);",
                                    with: "if (d[0] != 0.0f) v.exposureGain = u.exposureGain + (exp2(L.base[0] + L.layers[0].delta[0]) - u.exposureGain) * (d[0] / L.layers[0].delta[0]);")
        },
        Mutation(name: "a control no layer moves made again from c0") {
            $0.replacingOccurrences(of: "if (d[0] != 0.0f) v.exposureGain", with: "if (true) v.exposureGain")
        },
        Mutation(name: "contrast read from brightness's place") {
            $0.replacingOccurrences(of: "v.contrast = (L.base[1] + d[1])", with: "v.contrast = (L.base[2] + d[1])")
        },
        Mutation(name: "the mask sampled at the texel's corner") {
            $0.replacingOccurrences(of: "float x = clamp(s * pw - 0.5f, 0.0f, pw - 1.0f);", with: "float x = clamp(s * pw, 0.0f, pw - 1.0f);")
        },
        Mutation(name: "outside S is the plane's edge") {
            $0.replacingOccurrences(of: "if (!(s >= 0.0f && s <= 1.0f && t >= 0.0f && t <= 1.0f)) return 0.0f;", with: "")
        },
        Mutation(name: "a full plane is not 1") {
            $0.replacingOccurrences(of: "return (top + (bot - top) * ty) * (1.0f / 65535.0f);", with: "return (top + (bot - top) * ty) * (1.0f / 65536.0f);")
        },
        Mutation(name: "Edit switched off leaves the layers on") {
            // Both guards: the local pass's own and the one l2ApplyLocal is made with from l2Apply.
            $0.replacingOccurrences(of: "if (u.enabled == 0u) return c;\n    const Layer2Uniforms v", with: "const Layer2Uniforms v")
              .replacingOccurrences(of: "if (u.enabled == 0u) return c;\n    c = l2ToneLocal(c, v);", with: "c = l2ToneLocal(c, v);")
        },
        Mutation(name: "the export's matrix without the host's turn", flag: "noTurn"),
        Mutation(name: "the host's turn the other way", flag: "turnBack"),
        Mutation(name: "the film edge's box left out of the matrix", flag: "noFilm"),
        Mutation(name: "Edit's crop put into the matrix", flag: "cropInMatrix"),
    ]
}

final class Checks {
    let mutation: Mutation
    private(set) var passed = 0
    private(set) var failed: [String] = []
    init(_ m: Mutation) { mutation = m }
    var quiet: Bool { mutation != .none }
    func expect(_ ok: Bool, _ what: String) {
        if ok { passed += 1; if !quiet, Checks.verbose { print("  ok    \(what)") } } else { failed.append(what); if !quiet { print("  FAIL  \(what)") } }
    }
    static let verbose = CommandLine.arguments.contains("--verbose")
    func say(_ s: String) { if !quiet { print("  " + s) } }
    func has(_ flag: String) -> Bool { mutation.flag == flag }
}

// MARK: - pictures and planes

/// Colours that reach every branch: eleven levels a channel's corners and between, 24 x 24 (576 pixels), with greys,
/// black and white.
func card() -> (pixels: [UInt16], width: Int, height: Int) {
    let w = 24, h = 24
    var px = [UInt16](repeating: 65535, count: w * h * 4)
    for y in 0..<h { for x in 0..<w {
        let i = (y * w + x) * 4
        let r = Double((x * 7 + y * 3) % 11) / 10, g = Double((x * 5 + y * 11) % 11) / 10, b = Double((x * 3 + y * 7 + 2) % 11) / 10
        let grey = (x + y) % 9 == 0
        px[i] = UInt16(((grey ? b : r) * 65535).rounded()); px[i + 1] = UInt16(((grey ? b : g) * 65535).rounded())
        px[i + 2] = UInt16((b * 65535).rounded())
    } }
    return (px, w, h)
}

func smooth(width: Int, height: Int) -> [UInt16] {
    var px = [UInt16](repeating: 65535, count: width * height * 4)
    for y in 0..<height { for x in 0..<width {
        let u = (Double(x) + 0.5) / Double(width), v = (Double(y) + 0.5) / Double(height)
        let r = 0.5 + 0.45 * sin(u * 3.1 + v * 1.3), g = 0.45 + 0.4 * cos(u * 2.2 - v * 2.7), b = 0.15 + 0.8 * u * v
        let i = (y * width + x) * 4
        px[i] = UInt16((r * 65535).rounded()); px[i + 1] = UInt16((g * 65535).rounded()); px[i + 2] = UInt16((b * 65535).rounded())
    } }
    return px
}

func flat(width: Int, height: Int, _ v: Double) -> [UInt16] {
    var px = [UInt16](repeating: 65535, count: width * height * 4)
    let q = UInt16((v * 65535).rounded())
    for i in 0..<(width * height) { px[4 * i] = q; px[4 * i + 1] = q; px[4 * i + 2] = q }
    return px
}

/// The whole picture moving everything, every scalar control non-zero: the tables and matrices on too.
func whole() -> Adjustments {
    var a = Adjustments()
    a.exposure = 0.37; a.contrast = 11; a.brightness = -7; a.highlights = 23; a.shadows = -17
    a.blackPoint = 3; a.whitePoint = 4; a.saturation = 13; a.vibrance = -9; a.temperature = 21; a.tint = -13
    a.colorBalance.shadows = ColorZone(hue: 200, saturation: 0.3, luminance: 0.1)
    a.curves.rgb.insert(CGPoint(x: 0.25, y: 0.2)); a.curves.rgb.insert(CGPoint(x: 0.75, y: 0.82))
    a.vignette = Vignette(amount: -35, midpoint: 40)
    a.hsl.blue = HSLBand(hue: -20, saturation: 30, luminance: -40)
    a.channelMixer.red = MixerRow(red: -10, green: 8, blue: 0)
    return a
}

/// The eleven controls: name, Adjustments' key path, and the deltas tried (both ends of the range and two between).
let controls: [(String, WritableKeyPath<Adjustments, Double>, [Double])] = [
    ("exposure", \.exposure, [-3, -0.75, 0.5, 3]),
    ("contrast", \.contrast, [-50, -12, 20, 50]),
    ("brightness", \.brightness, [-50, -12, 20, 50]),
    ("highlights", \.highlights, [-100, -30, 45, 100]),
    ("shadows", \.shadows, [-100, -30, 45, 100]),
    ("blackPoint", \.blackPoint, [-50, -10, 15, 50]),
    ("whitePoint", \.whitePoint, [-50, -10, 15, 40]),
    ("saturation", \.saturation, [-100, -30, 45, 100]),
    ("vibrance", \.vibrance, [-100, -30, 45, 100]),
    ("temperature", \.temperature, [-100, -30, 45, 100]),
    ("tint", \.tint, [-100, -30, 45, 100]),
]

func plane(_ device: MTLDevice, _ w: Int, _ h: Int, _ value: (Int, Int) -> UInt16) -> MaskPlane {
    var v = [UInt16](repeating: 0, count: w * h)
    for y in 0..<h { for x in 0..<w { v[y * w + x] = value(x, y) } }
    let b = device.makeBuffer(bytes: v, length: v.count * 2, options: .storageModeShared)!
    return MaskPlane(buffer: b, width: w, height: h, key: "test-\(w)x\(h)-\(v.hashValue)")
}

/// A surface's layers from planes made here: each (plane, deltas in FinishedDeltas.values' order, coverage).
func local(_ layers: [(MaskPlane, [Double], Double)], _ a: Adjustments, matrix: MaskMatrix = .identity) -> Layer2LocalPass {
    let made = layers.map { p, d, c in
        FinishedLayers.Layer(layer: LocalLayer(stage: .finished), planeKey: p.key, deltas: d.map { Float($0) }, coverage: Float(c))
    }
    let fl = FinishedLayers(layers: made, source: PixelSize(width: 100, height: 100), toSource: matrix)
    return Layer2LocalPass(fl, planes: layers.map(\.0), adjustments: a, matrix: matrix)
}

func deltas(_ i: Int, _ v: Double) -> [Double] { var d = [Double](repeating: 0, count: 11); d[i] = v; return d }

func codes(_ f: [Float]) -> [Int] { f.map { $0 == $0 ? Int((min(max($0, 0), 1) * 65535 + 0.5).rounded(.down)) : 0 } }

func sixteen(_ r: Layer2Renderer, _ s: Layer2Source, _ a: Adjustments, _ l: Layer2LocalPass?) -> [UInt16] {
    let out = r.device.makeBuffer(length: s.bytes, options: .storageModeShared)!
    _ = try? r.apply(s, a, local: l, into: out)
    return Array(UnsafeBufferPointer(start: out.contents().bindMemory(to: UInt16.self, capacity: s.width * s.height * 4), count: s.width * s.height * 4))
}

// MARK: - the checks

func run(_ c: Checks) {
    guard let device = MTLCreateSystemDefaultDevice() else { c.expect(false, "this Mac has a Metal device"); return }
    let localSource = c.mutation.kernel.map { $0(Layer2Local.source) } ?? Layer2Local.source
    let renderer: Layer2Renderer
    do { renderer = try Layer2Renderer(device: device, localSource: localSource) } catch {
        c.expect(false, "the kernels compile: \(error)"); return
    }
    let (px, w, h) = card()
    guard let src = try? renderer.source(rgba16: px, width: w, height: h) else { c.expect(false, "a card"); return }
    let full = plane(device, 16, 16) { _, _ in 65535 }
    let zero = plane(device, 16, 16) { _, _ in 0 }

    // The local source is made from today's functions (derived), not a copy.
    c.expect(!Layer2Local.functions.contains("#error"), "the local tone is made from Layer2Kernel.functions")
    c.expect(Layer2Local.derived("nothing") .contains("#error"), "and a source without its lines makes an #error, not a pass")

    // MARK: neutral
    let id = UUID()
    func edit(_ f: (inout LocalLayer) -> Void) -> LocalLayers {
        var l = LocalLayer(id: id, stage: .finished, parts: [.linear(MaskLinear(a: MaskPoint(0, 0), b: MaskPoint(1, 1)))])
        l.finished?.exposure = 1
        f(&l)
        return LocalLayers(items: [l])
    }
    let src100 = PixelSize(width: 300, height: 200)
    var off = Adjustments(); off.enabled = false
    let nones: [(String, LocalLayers?, Adjustments)] = [
        ("no layers", nil, Adjustments()), ("an empty list", LocalLayers(), Adjustments()),
        ("the eye off", edit { $0.on = false }, Adjustments()), ("opacity 0", edit { $0.opacity = 0 }, Adjustments()),
        ("every delta zero", edit { $0.finished = FinishedDeltas() }, Adjustments()),
        ("every part off", edit { $0.parts[0].on = false }, Adjustments()),
        ("a 场景 layer only", edit { $0 = $0.moved(to: .scene); $0.scene?.exposure = 1 }, Adjustments()),
        ("Edit switched off", edit { _ in }, off),
    ]
    for (name, layers, a) in nones {
        c.expect(FinishedLayers.of(layers, adjustments: a, source: src100, toSource: .identity) == nil,
                 "neutral: \(name) -- no 成片 layer is handed, today's kernels run")
    }
    let acting = FinishedLayers.of(edit { _ in }, adjustments: Adjustments(), source: src100, toSource: .identity)
    c.expect(acting?.layers.count == 1 && Layer2Local.acts(Adjustments(), acting) && !Layer2Local.acts(Adjustments(), nil)
             && !Layer2Local.acts(off, acting), "a layer that acts runs the pass over a neutral whole; Edit switched off runs nothing")

    // Inside the local variant, every k = 0: today's to the bit, in 16 bits and in float.
    let everyDelta = (0..<11).map { controls[$0].2.last! }
    for (name, a) in [("a neutral whole", Adjustments()), ("the whole moving everything", whole())] {
        let today16 = sixteen(renderer, src, a, nil), todayF = (try? renderer.floats(src, a)) ?? []
        let eight = local((0..<8).map { _ in (zero, everyDelta, 1.0) }, a)
        let got16 = sixteen(renderer, src, a, eight), gotF = (try? renderer.floats(src, a, local: eight)) ?? []
        c.expect(got16 == today16, "neutral: \(name), eight layers whose planes are 0 -- 16 bits to the bit (\(zip(got16, today16).filter { $0 != $1 }.count) values moved)")
        c.expect(gotF.map(\.bitPattern) == todayF.map(\.bitPattern) && !gotF.isEmpty,
                 "neutral: \(name), the same in float, to the bit (\(zip(gotF, todayF).filter { $0.bitPattern != $1.bitPattern }.count) moved)")
    }
    do {
        let a = whole()
        let todayF = (try? renderer.floats(src, a)) ?? []
        // The left half of the plane full, the right half 0: the right half is today's to the bit.
        let half = plane(device, w, h) { x, _ in x < w / 2 ? 65535 : 0 }
        let gotF = (try? renderer.floats(src, a, local: local([(half, everyDelta, 1)], a))) ?? []
        var rightSame = true, leftMoved = 0
        for y in 0..<h { for x in 0..<w { for ch in 0..<3 {
            let i = (y * w + x) * 4 + ch
            guard i < gotF.count, i < todayF.count else { rightSame = false; continue }
            if x >= w / 2 + 1 { if gotF[i].bitPattern != todayF[i].bitPattern { rightSame = false } } else if x < w / 2 - 1, gotF[i] != todayF[i] { leftMoved += 1 }
        } } }
        c.expect(rightSame && leftMoved > w * h, "neutral: where the mask is 0 the pixel is today's to the bit, and where it is 1 it moved (\(leftMoved) values)")
        // Outside S: a full plane, the picture's right half mapped past S's edge.
        let shifted = MaskMatrix([1, 0, 0.5, 0, 1, 0, 0, 0, 1])
        let gotO = (try? renderer.floats(src, a, local: local([(full, everyDelta, 1)], a, matrix: shifted))) ?? []
        var outsideSame = true
        for y in 0..<h { for x in (w / 2 + 1)..<w { for ch in 0..<3 {
            let i = (y * w + x) * 4 + ch
            if i >= gotO.count || gotO[i].bitPattern != todayF[i].bitPattern { outsideSame = false }
        } } }
        c.expect(outsideSame, "neutral: outside S a mask is 0, whatever its plane's edge holds")
        // Edit switched off: the layers go with it.
        var offA = a; offA.enabled = false
        let gotOff = (try? renderer.floats(src, offA, local: local([(full, everyDelta, 1)], offA))) ?? []
        var exact = gotOff.count == px.count
        for i in 0..<min(gotOff.count, px.count) where i % 4 != 3 { if gotOff[i] != Float(px[i]) / 65535 { exact = false } }
        c.expect(exact, "Edit switched off is the whole pass off, its layers with it: the picture to the bit")
    }

    // MARK: the mask's sampling: at texel centres k is the texel
    do {
        let pw = 24, ph = 24
        var rng = SystemRandomNumberGenerator()
        let values = (0..<(pw * ph)).map { _ in UInt16.random(in: 0...65535, using: &rng) }
        let ramp = plane(device, pw, ph) { x, y in values[y * pw + x] }
        // White point by Δ = 50 · k on a flat 0.5: c' = c / (1 − k/2) → k = 2 (1 − c / c').
        let grey = try! renderer.source(rgba16: flat(width: pw, height: ph, 0.5), width: pw, height: ph)
        let got = (try? renderer.floats(grey, Adjustments(), local: local([(ramp, deltas(6, 50), 1)], Adjustments()))) ?? []
        var worst = 0.0
        for i in 0..<(pw * ph) where 4 * i < got.count {
            let k = 2 * (1 - (Double(Float(32768) / 65535)) / Double(got[4 * i]))
            worst = max(worst, abs(k - Double(values[i]) / 65535))
        }
        c.expect(got.count == pw * ph * 4 && worst < 2e-6, String(format: "the mask at texel centres is the texel (worst %.1e of full coverage)", worst))
    }

    // MARK: identity, per control
    var identityWorstCodes = 0, identityWorstFloat: Float = 0, halfWorstCodes = 0
    for (index, (name, path, ds)) in controls.enumerated() {
        for nonZero in [true, false] {
            var a = whole()
            if !nonZero { a[keyPath: path] = 0 }
            var worstF: Float = 0, worstC = 0, halfC = 0
            for d in ds {
                var want = a; want[keyPath: path] += d
                let ref = (try? renderer.floats(src, want)) ?? []
                let got = (try? renderer.floats(src, a, local: local([(full, deltas(index, d), 1)], a))) ?? []
                guard ref.count == got.count, !got.isEmpty else { c.expect(false, "\(name): the passes ran"); continue }
                for i in 0..<got.count where i % 4 != 3 { worstF = max(worstF, abs(got[i] - ref[i])) }
                worstC = max(worstC, zip(codes(got), codes(ref)).map { abs($0 - $1) }.max() ?? 0)
                // Half coverage: opacity ½ over the full plane is the control moved by Δ/2.
                var halfWant = a; halfWant[keyPath: path] += d / 2
                let refH = (try? renderer.floats(src, halfWant)) ?? []
                let gotH = (try? renderer.floats(src, a, local: local([(full, deltas(index, d), 0.5)], a))) ?? []
                if refH.count == gotH.count { halfC = max(halfC, zip(codes(gotH), codes(refH)).map { abs($0 - $1) }.max() ?? 0) }
            }
            c.expect(worstC <= 1, "identity: a full mask of \(name) is \(name) moved by Δ, the whole at \(nonZero ? "\(a[keyPath: path])" : "0") (worst \(worstC) of 65,535; \(String(format: "%.1e", worstF)) in float)")
            c.expect(halfC <= 1, "half coverage: k = ½ of \(name) is \(name) moved by Δ/2, the whole at \(nonZero ? "\(a[keyPath: path])" : "0") (worst \(halfC) of 65,535)")
            identityWorstCodes = max(identityWorstCodes, worstC); identityWorstFloat = max(identityWorstFloat, worstF)
            halfWorstCodes = max(halfWorstCodes, halfC)
        }
    }
    c.say(String(format: "identity over 11 controls x 4 deltas x 2 wholes: worst %d of 65,535 (16 bits), %.2e in float; half coverage worst %d",
                 identityWorstCodes, identityWorstFloat, halfWorstCodes))
    // Two layers over each other add in the sliders' units.
    do {
        let a = whole()
        var want = a; want.exposure += 0.5 + 0.25 * 0.5; want.contrast += -20
        let two = local([(full, deltas(0, 0.5), 1), (full, { var d = deltas(0, 0.25); d[1] = -40; return d }(), 0.5)], a)
        let got = (try? renderer.floats(src, a, local: two)) ?? [], ref = (try? renderer.floats(src, want)) ?? []
        let worst = zip(codes(got), codes(ref)).map { abs($0 - $1) }.max() ?? 99
        c.expect(!got.isEmpty && worst <= 1, "two layers add their offsets: Σ k Δ in the sliders' units (worst \(worst))")
    }
    // The histogram counts the layered picture.
    do {
        let hs = try! renderer.source(rgba16: smooth(width: 320, height: 240), width: 320, height: 240)
        var want = Adjustments(); want.exposure = -2
        let ref = try? renderer.histogram(hs, want)
        let got = try? renderer.histogram(hs, Adjustments(), local: local([(full, deltas(0, -2), 1)], Adjustments()))
        c.expect(ref != nil && got?.0.counts == ref?.0.counts, "the histogram of a full mask's layer is the histogram of the control moved")
    }

    geometry(c, renderer)
}

// MARK: - a preview's size against an export's, and the photograph point

func geometry(_ c: Checks, _ renderer: Layer2Renderer) {
    let device = renderer.device
    // The photograph and its mask: a hard disc (radial, feather 0) and a soft gradient, in S.
    let S = PixelSize(width: 3000, height: 2000)
    let L = 3000.0
    let centre = MaskPoint(0.55, 0.47), r = 0.11
    var disc = LocalLayer(stage: .finished, parts: [.radial(MaskRadial(centre: centre, rx: r, ry: r, angle: 0, feather: 0))])
    disc.finished?.exposure = -2
    var ramp = LocalLayer(stage: .finished, parts: [.linear(MaskLinear(a: MaskPoint(0.1, 0.2), b: MaskPoint(0.9, 0.7)))])
    ramp.finished?.exposure = 1; ramp.finished?.saturation = 30

    // A plain frame: the soft layer at a preview's size and an export's, block means (layer2_selftest's bar).
    do {
        guard let fl = FinishedLayers.of(LocalLayers(items: [ramp]), adjustments: whole(), source: S, toSource: .identity),
              let planes = try? fl.planesBlocking(device: device) else { c.expect(false, "the soft layer's plane is baked"); return }
        let small = (600, 400), large = (2400, 1600)
        let s = try! renderer.source(rgba16: smooth(width: small.0, height: small.1), width: small.0, height: small.1)
        let b = try! renderer.source(rgba16: smooth(width: large.0, height: large.1), width: large.0, height: large.1)
        let pass = Layer2LocalPass(fl, planes: planes, adjustments: whole(), matrix: fl.toSource)
        let fs = (try? renderer.floats(s, whole(), local: pass)) ?? [], fb = (try? renderer.floats(b, whole(), local: pass)) ?? []
        var worst: Float = 0, sum = 0.0
        if fs.count == small.0 * small.1 * 4, fb.count == large.0 * large.1 * 4 {
            for y in 0..<small.1 { for x in 0..<small.0 { for ch in 0..<3 {
                var m: Float = 0
                for dy in 0..<4 { for dx in 0..<4 { m += fb[((y * 4 + dy) * large.0 + x * 4 + dx) * 4 + ch] } }
                let d = abs(m / 16 - fs[(y * small.0 + x) * 4 + ch]); worst = max(worst, d); sum += Double(d)
            } } }
        }
        let mean = sum / Double(small.0 * small.1 * 3)
        c.expect(!fs.isEmpty && worst < 2e-3 && mean < 2e-4,
                 "a preview's layered pass and an export's agree: at most \(worst), on average \(String(format: "%.2g", mean)) of full scale")
    }

    // Through a film edge, a quarter turn of the host's, a flip, a cut and Edit's crop: the disc's edge where the
    // photograph has it, on the page (the finished canvas) and on the export (the engine's result before the turn).
    var g = Geometry()
    g.crop = CropRect(x: 0.1, y: 0.05, width: 0.8, height: 0.85)
    g.quarterTurns = 1
    g.flipH = true
    let box = MaskFrame.FilmBox(canvasMM: CGSize(width: 44, height: 30), box: CGRect(x: 13.5, y: 3, width: 17, height: 24),
                                tilt: 0.8, centre: CGPoint(x: 22, y: 15))
    let sourceSize = CGSize(width: S.width, height: S.height)
    let truth = MaskFrame.finished(picture: g, source: sourceSize, film: box)
    let handed = c.has("noFilm") ? MaskFrame.finished(picture: g, source: sourceSize) : truth
    guard let fl = FinishedLayers.of(LocalLayers(items: [disc]), adjustments: Adjustments(), source: S, toSource: handed),
          let planes = try? fl.planesBlocking(device: device) else { c.expect(false, "the disc's plane is baked"); return }
    let turns = 1
    let page = (440, 300), canvas = (1760, 1200)
    let crop = CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.6)
    var printCrop = Geometry(); printCrop.crop = CropRect(x: crop.minX, y: crop.minY, width: crop.width, height: crop.height)

    // The page: the finished canvas at its size; the matrix is the canvas's (Edit's crop is the view's, after).
    let pageMatrix = c.has("cropInMatrix")
        ? MaskFrame.view(finished: fl.toSource, printCrop: printCrop, finishedSize: CGSize(width: page.0, height: page.1)) : fl.toSource
    let pageSrc = try! renderer.source(rgba16: flat(width: page.0, height: page.1, 0.5), width: page.0, height: page.1)
    let pageOut = (try? renderer.floats(pageSrc, Adjustments(), local: Layer2LocalPass(fl, planes: planes, adjustments: Adjustments(), matrix: pageMatrix))) ?? []
    // The export: the engine's result before the host's clockwise turn, then turned (as EngineHost.turned does).
    let rw = canvas.1, rh = canvas.0
    let exportMatrix = c.has("noTurn") ? fl.toSource : c.has("turnBack") ? fl.toSource.after(MaskFrame.hostTurns(4 - turns)) : fl.matrix(turnsAfter: turns)
    let renderSrc = try! renderer.source(rgba16: flat(width: rw, height: rh, 0.5), width: rw, height: rh)
    let renderOut = (try? renderer.floats(renderSrc, Adjustments(), local: Layer2LocalPass(fl, planes: planes, adjustments: Adjustments(), matrix: exportMatrix))) ?? []
    guard pageOut.count == page.0 * page.1 * 4, renderOut.count == rw * rh * 4 else { c.expect(false, "both surfaces ran"); return }
    var exportOut = [Float](repeating: 0, count: canvas.0 * canvas.1)
    for Y in 0..<canvas.1 { for X in 0..<canvas.0 {
        let rx = Y, ry = rh - 1 - X                 // one clockwise turn: finished (X, Y) is the render's (Y, H − 1 − X)
        exportOut[Y * canvas.0 + X] = renderOut[(ry * rw + rx) * 4]
    } }
    let lit = Float(32768) / 65535, dark = Float(pow(pow(Double(lit), 2.2) / 4, 1 / 2.2))
    let threshold = (lit + dark) / 2
    // Each surface, through Edit's crop, against the disc mapped from S (double): wrong only within a page pixel of
    // the edge.
    func check(_ name: String, _ out: [Float], _ W: Int, _ H: Int, stride: Int) -> (wrong: Int, inside: Int) {
        let x0 = Int((crop.minX * Double(W)).rounded()), y0 = Int((crop.minY * Double(H)).rounded())
        let cw = Int((crop.width * Double(W)).rounded()), ch = Int((crop.height * Double(H)).rounded())
        var wrong = 0, inside = 0
        for y in 0..<ch { for x in 0..<cw {
            let fx = Double(x0 + x) + 0.5, fy = Double(y0 + y) + 0.5
            let f = CGPoint(x: fx / Double(W), y: fy / Double(H))
            func metric(_ p: CGPoint) -> SIMD2<Double> { let s = truth.apply(p); return SIMD2(Double(s.x) * Double(S.width) / L, Double(s.y) * Double(S.height) / L) }
            let m = metric(f)
            let d = ((m - SIMD2(centre.x * Double(S.width) / L, centre.y * Double(S.height) / L)) * (m - SIMD2(centre.x * Double(S.width) / L, centre.y * Double(S.height) / L))).sum().squareRoot()
            // One pixel of the smaller picture (the page's), in metric units here.
            let step = Double(W) / Double(page.0)
            let ex = metric(CGPoint(x: (fx + step) / Double(W), y: fy / Double(H))) - m, ey = metric(CGPoint(x: fx / Double(W), y: (fy + step) / Double(H))) - m
            let px = max((ex * ex).sum().squareRoot(), (ey * ey).sum().squareRoot())
            let want = d < r, got = out[(y0 + y) * W + x0 + x] * 1 < threshold
            if want { inside += 1 }
            if want != got && abs(d - r) > px { wrong += 1 }
        } }
        return (wrong, inside)
    }
    var pagePlane = [Float](repeating: 0, count: page.0 * page.1)
    for i in 0..<(page.0 * page.1) { pagePlane[i] = pageOut[4 * i] }
    let p = check("page", pagePlane, page.0, page.1, stride: 1)
    let e = check("export", exportOut, canvas.0, canvas.1, stride: 4)
    c.expect(p.inside > 500 && p.wrong == 0, "through a film edge, a quarter turn, a flip, a cut and Edit's crop: the page's mask edge is the photograph's to a page pixel (\(p.wrong) wrong of \(p.inside) inside)")
    c.expect(e.inside > 8000 && e.wrong == 0, "and the export's -- the engine's result before the host's turn -- to a page pixel (\(e.wrong) wrong of \(e.inside) inside)")
    // The two against each other, on the page's pixels: the export's 4 x 4 majority.
    var apart = 0
    let x0 = Int(crop.minX * Double(page.0)), y0 = Int(crop.minY * Double(page.1))
    for y in y0..<(y0 + Int(crop.height * Double(page.1))) { for x in x0..<(x0 + Int(crop.width * Double(page.0))) {
        var n = 0
        for dy in 0..<4 { for dx in 0..<4 { if exportOut[(y * 4 + dy) * canvas.0 + x * 4 + dx] < threshold { n += 1 } } }
        if (pagePlane[y * page.0 + x] < threshold) != (n >= 8) {
            // Allowed only on the edge itself: a neighbour of the page's own picture differs.
            let here = pagePlane[y * page.0 + x] < threshold
            let edge = [(-1, 0), (1, 0), (0, -1), (0, 1)].contains { (pagePlane[(y + $0.1) * page.0 + x + $0.0] < threshold) != here }
            if !edge { apart += 1 }
        }
    } }
    c.expect(apart == 0, "the page's mask and the export's, on the page's pixels: the same but on the edge's own pixels (\(apart) apart)")
}

// MARK: - gate 6: what the pass costs

func cost() {
    guard let device = MTLCreateSystemDefaultDevice(), let renderer = try? Layer2Renderer(device: device) else { print("no GPU"); return }
    func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }
    var load = [Double](repeating: 0, count: 3)
    getloadavg(&load, 3)
    print(String(format: "gate 6 (RFC-052 §10.6): Edit's pass, 0/1/4/8 成片 layers, interleaved; load %.2f %.2f %.2f", load[0], load[1], load[2]))
    // The page's picture is a 45 MP photograph's develop: its planes are the photograph's (L_c 4096), not the page's.
    let sizes: [(String, Int, Int, PixelSize)] = [("page 2400 x 1600 (45 MP source)", 2400, 1600, PixelSize(width: 8256, height: 5504)),
                                                  ("24 MP 6000 x 4000", 6000, 4000, PixelSize(width: 6000, height: 4000)),
                                                  ("45 MP 8256 x 5504", 8256, 5504, PixelSize(width: 8256, height: 5504))]
    for (name, w, h, S) in sizes {
        var layers: [LocalLayer] = []
        for i in 0..<8 {
            var l = LocalLayer(stage: .finished, parts: [.radial(MaskRadial(centre: MaskPoint(0.2 + 0.08 * Double(i), 0.5), rx: 0.2, ry: 0.15, angle: 10, feather: 0.4))])
            l.finished?.exposure = 0.5; l.finished?.contrast = 10; l.finished?.temperature = 20
            layers.append(l)
        }
        let a = whole()
        let pic = try! renderer.source(rgba16: smooth(width: w, height: h), width: w, height: h)
        let out = device.makeBuffer(length: pic.bytes, options: .storageModeShared)!
        var passes: [Int: Layer2LocalPass] = [:]
        var planeBytes: [Int: Int] = [:]
        // The planes held (the baker's store keeps them: 1 of 4 of 8), as the process's footprint sees them.
        let bare = footprint()
        var held: [Int: UInt64] = [:]
        for n in [1, 4, 8] {
            let fl = FinishedLayers.of(LocalLayers(items: Array(layers.prefix(n))), adjustments: a, source: S, toSource: .identity)!
            let planes = try! fl.planesBlocking(device: device)
            passes[n] = Layer2LocalPass(fl, planes: planes, adjustments: a, matrix: .identity)
            planeBytes[n] = planes.reduce(0) { $0 + $1.bytes }
            held[n] = footprint() > bare ? footprint() - bare : 0
        }
        var times: [Int: [Double]] = [0: [], 1: [], 4: [], 8: []]
        var peaks: [Int: UInt64] = [:]
        _ = try? renderer.apply(pic, a, into: out)
        for n in [1, 4, 8] { _ = try? renderer.apply(pic, a, local: passes[n], into: out) }
        for round in 0..<6 {
            let order = [0, 1, 4, 8]
            for j in 0..<4 {
                let n = order[(j + round) % 4]
                let before = footprint()
                let ms = (try? renderer.apply(pic, a, local: n == 0 ? nil : passes[n], into: out)) ?? -1
                times[n]!.append(ms)
                peaks[n] = max(peaks[n] ?? 0, footprint() > before ? footprint() - before : 0)
            }
        }
        for n in [0, 1, 4, 8] {
            let t = times[n]!.sorted()
            print(String(format: "  %@, %d layers: median %.2f ms GPU (min %.2f, max %.2f); planes %.1f MB, footprint with them baked +%.1f MB; growth over a pass %.1f MB",
                         name, n, t[t.count / 2], t.first!, t.last!, Double(planeBytes[n] ?? 0) / 1_048_576, Double(held[n] ?? 0) / 1_048_576,
                         Double(peaks[n] ?? 0) / 1_048_576))
        }
        print(String(format: "  %@: process footprint %.0f MB (the picture in and out: %.0f MB)", name, Double(footprint()) / 1_048_576, Double(pic.bytes * 2) / 1_048_576))
    }
}

@main
struct Layer2LocalSelfTest {
    static func main() {
        if CommandLine.arguments.contains("--cost") { cost(); exit(0) }
        let started = Date()
        let c = Checks(.none)
        run(c)
        print("layer 2 local checks: \(c.passed) passed, \(c.failed.count) failed (\(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
        var code: Int32 = c.failed.isEmpty ? 0 : 1
        if CommandLine.arguments.contains("--self-test") {
            var caught = 0
            for m in Mutation.all {
                if let k = m.kernel, k(Layer2Local.source) == Layer2Local.source { print("  NOT APPLIED  \(m.name)"); continue }
                let r = Checks(m)
                run(r)
                if r.failed.isEmpty { print("  NOT CAUGHT  \(m.name)") } else {
                    caught += 1
                    print("  caught  \(m.name): \(r.failed.count) check(s) failed, e.g. \(r.failed[0])")
                }
            }
            print("layer 2 local self-test: \(caught) of \(Mutation.all.count) broken rules caught")
            if caught != Mutation.all.count { code = 1 }
        }
        exit(code)
    }
}
