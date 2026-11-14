//  scene_layer_selftest.swift — the 场景 layers' host side without the engine (RFC-052 §6.1, §6.5, §10.1, §10.2):
//
//  1. **C is the engine's**: the host's copy (`SceneLayerWire.rgbToCone`) against the engine's recorded reply
//     (`tools/engine_replies/scene_layers_reply.json`, `spk_set_scene_layers` on a ProPhoto session), and the
//     ProPhoto matrix it implies against colour-science's;
//  2. **w**: (1, 1, 1) exactly at rest; an exposure alone three equal floats (the node's scalar path); +色温 amber and
//     +色调 magenta on a neutral, whose luminance is kept; the working white's CCT and Duv;
//  3. **the ask and the stamp**: none for no layers, all off, opacity 0, zero deltas, a stage other than 场景 (the
//     wire then carries no field: §10.2); a new stamp for every input the node reads, the same for what it does not;
//  4. **the host kernel** (`SceneLayerHost`, 应用胶片模拟 off): against the expression in double on a fixture —
//     the scalar path to the float gain's own narrowing, the colour path within 1 count of 16 bits relative (the
//     bar of §10.1), a full mask of e stops the scalar gain 2^e to the bit, a pixel no layer reaches untouched.
//     Red first: `--self-test` hands the kernel C transposed (trap 20) and expects the colour path to fail.
//
//      scene_layer_selftest <tools/engine_replies/scene_layers_reply.json> [--self-test]

import CoreGraphics
import Foundation
import Metal
import simd

@main struct SceneLayerSelftest {
    static var passed = 0, failed = 0
    static func expect(_ ok: Bool, _ what: String) {
        if ok { passed += 1; print("ok    \(what)") } else { failed += 1; print("FAIL  \(what)") }
    }

    static func main() async throws {
        let args = CommandLine.arguments
        let reply = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [String: Any]
        let selfTest = args.contains("--self-test")
        let cone = (reply["rgb_to_cone"] as! [NSNumber]).map(\.doubleValue)
        let inv = (reply["cone_to_rgb"] as! [NSNumber]).map(\.doubleValue)
        // 1. C.
        let dc = zip(cone, SceneLayerWire.rgbToCone).map { abs($0 - $1) }.max()!
        let di = zip(inv, SceneLayerWire.coneToRGB).map { abs($0 - $1) }.max()!
        expect(dc <= 1e-15 && di <= 1e-12 && SceneLayerWire.agrees(rgbToCone: cone),
               String(format: "the host's C is the engine's reply (%@): max %.1e, its inverse %.1e", reply["working_space"] as? String ?? "?", dc, di))
        let pp = SceneLayerWire.rows(SceneLayerWire.rgbToXYZ)
        let cs: [Double] = [0.7977, 0.1352, 0.0313, 0.2880, 0.7119, 0.0001, 0, 0, 0.8249]
        expect(zip(pp, cs).allSatisfy { abs($0 - $1) < 1e-12 }, "M_CAT16⁻¹ · C is colour-science's ProPhoto matrix (\(pp.map { String(format: "%.4f", $0) }))")
        let white = SceneLayerWire.workingWhite
        expect(abs(white.xyz.y - 1) < 1e-12 && abs(white.kelvin - 5000) < 5 && abs(white.duv - 0.0033) < 0.0003,
               String(format: "the working white: Y %.6f, %.1f K, Duv %+.5f (D50)", white.xyz.y, white.kelvin, white.duv))
        // 2. w.
        expect(SceneLayerWire.whiteGain(temperature: 0, tint: 0) == SIMD3(1, 1, 1), "w(0, 0) = (1, 1, 1) exactly")
        let g = SceneLayerWire.logGain(SceneDeltas(exposure: 0.7))
        let f = SIMD3(Float(g.x), Float(g.y), Float(g.z))
        expect(f.x == f.y && f.y == f.z && f.x == Float(0.7 * M_LN2), "an exposure alone is three equal floats, e·ln2 (\(f.x))")
        let C = SceneLayerWire.m(SceneLayerWire.rgbToCone)
        func onNeutral(_ d: SceneDeltas) -> SIMD3<Double> {
            let lg = SceneLayerWire.logGain(d)
            return C.inverse * (SIMD3(exp(lg.x), exp(lg.y), exp(lg.z)) * (C * SIMD3(1, 1, 1)))
        }
        func lum(_ rgb: SIMD3<Double>) -> Double { (SceneLayerWire.rgbToXYZ * rgb).y }
        for (name, d) in [("+100", SceneDeltas(temperature: 100)), ("-100", SceneDeltas(temperature: -100)),
                          ("tint +100", SceneDeltas(tint: 100)), ("tint -100", SceneDeltas(tint: -100))] {
            let n = onNeutral(d)
            let ok: Bool
            switch name {
            case "+100": ok = n.x > n.z     // amber: red over blue
            case "-100": ok = n.x < n.z
            case "tint +100": ok = n.y < n.x && n.y < n.z   // magenta: green under both
            default: ok = n.y > n.x && n.y > n.z
            }
            expect(ok && abs(lum(n) - 1) < 1e-12, String(format: "色温/色调 %@ on a neutral: RGB (%.4f, %.4f, %.4f), luminance %.12f", name, n.x, n.y, n.z, lum(n)))
        }
        // 3. The ask.
        let source = PixelSize(width: 3000, height: 2000)
        var layer = LocalLayer(name: "Sky", stage: .scene, parts: [.linear(MaskLinear(a: MaskPoint(0.5, 0), b: MaskPoint(0.5, 0.5)))])
        layer.scene = SceneDeltas(exposure: -1)
        func ask(_ l: [LocalLayer], cut: Geometry? = nil) -> SceneLayerWire.Ask? {
            SceneLayerWire.ask(LocalLayers(items: l), source: source, hostCut: cut, decode: source)
        }
        var off = layer; off.on = false
        var clear = layer; clear.opacity = 0
        var zero = layer; zero.scene = SceneDeltas()
        let finished = layer.moved(to: .finished)
        expect(SceneLayerWire.ask(nil, source: source, hostCut: nil, decode: source) == nil && ask([]) == nil && ask([off]) == nil
               && ask([clear]) == nil && ask([zero]) == nil && ask([finished]) == nil,
               "no ask (no scene_layers on the wire) for: no layers, all off, opacity 0, zero deltas, a 成片 layer")
        let base = ask([layer])!.stamp
        var other = layer; other.scene?.exposure = -1.01
        var moved = layer; moved.parts[0].linear?.b.y = 0.51
        var renamed = layer; renamed.name = "Clouds"
        var crop = Geometry(); crop.crop = CropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        expect(base.hasPrefix("sl1.") && ask([other])!.stamp != base && ask([moved])!.stamp != base && ask([layer], cut: crop)!.stamp != base
               && ask([renamed])!.stamp == base,
               "the stamp moves with the gain, the mask and the matrix, and not with the name (\(base))")
        // 4. The host kernel.
        guard let device = MTLCreateSystemDefaultDevice() else { print("no Metal"); exit(1) }
        let host = try SceneLayerHost(device: device)
        let baker = try MaskBaker(device: device)
        let w = 300, h = 200
        var rng = SystemRandomNumberGenerator()
        var input = (0..<(w * h * 4)).map { i in i % 4 == 3 ? Float(1) : Float.random(in: 0.001...4, using: &rng) }
        input[0] = 1    // a pixel of 1: what a scalar gain makes of it is the gain itself
        func run(_ a: SceneLayerWire.Ask, planes: [MaskPlane], f2s: MaskMatrix, broken: Bool = false) throws -> [Float] {
            let buf = device.makeBuffer(bytes: input, length: input.count * 4, options: .storageModeShared)!
            try host.apply(a, planes: planes, frameToSource: f2s, to: buf, width: w, height: h)
            return Array(UnsafeBufferPointer(start: buf.contents().bindMemory(to: Float.self, capacity: input.count), count: input.count))
        }
        var valuesOf: [ObjectIdentifier: [UInt16]] = [:]
        func sample(_ p: MaskPlane, _ s: Double, _ t: Double) -> Double {
            guard s >= 0, s <= 1, t >= 0, t <= 1 else { return 0 }
            let id = ObjectIdentifier(p.buffer)
            if valuesOf[id] == nil { valuesOf[id] = p.values }
            let v = valuesOf[id]!, pw = Double(p.width), ph = Double(p.height)
            let x = min(max(s * pw - 0.5, 0), pw - 1), y = min(max(t * ph - 0.5, 0), ph - 1)
            let x0 = Int(x), y0 = Int(y), x1 = min(x0 + 1, p.width - 1), y1 = min(y0 + 1, p.height - 1)
            let tx = x - Double(x0), ty = y - Double(y0)
            let a = Double(v[y0 * p.width + x0]), b = Double(v[y0 * p.width + x1]), c = Double(v[y1 * p.width + x0]), d = Double(v[y1 * p.width + x1])
            let top = a + (b - a) * tx, bot = c + (d - c) * tx
            return (top + (bot - top) * ty) / 65535
        }
        var colourLayer = LocalLayer(name: "Gel", stage: .scene, parts: [.radial(MaskRadial(centre: MaskPoint(0.4, 0.6), rx: 0.2, ry: 0.15, angle: 20, feather: 0.7))])
        colourLayer.scene = SceneDeltas(exposure: 0.4, temperature: 60, tint: -30)
        colourLayer.opacity = 0.8
        let cut = MaskFrame.finished(picture: crop, source: CGSize(width: 3000, height: 2000))
        for (name, ls) in [("scalar: one gradient of -1 stop", [layer]), ("colour: the gradient and a radial gel", [layer, colourLayer])] {
            var a = SceneLayerWire.ask(LocalLayers(items: ls), source: source, hostCut: nil, decode: source)!
            a.frameToSource = cut
            var planes: [MaskPlane] = []
            for l in a.layers { planes.append(try await baker.bake(l.layer, source: source)) }
            let out = try run(a, planes: planes, f2s: cut)
            let colour = ls.count > 1
            var worst = 0.0
            for i in 0..<(w * h) {
                let p = cut.apply(CGPoint(x: (Double(i % w) + 0.5) / Double(w), y: (Double(i / w) + 0.5) / Double(h)))
                var G = SIMD3<Double>(0, 0, 0), E = 0.0
                for (l, plane) in zip(a.layers, planes) {
                    let k = Double(l.coverage) * sample(plane, Double(p.x), Double(p.y))
                    G += k * SIMD3(Double(l.logGain.x), Double(l.logGain.y), Double(l.logGain.z))
                    E += k * Double(l.logGain.x) / M_LN2
                }
                let rgb = SIMD3(Double(input[4 * i]), Double(input[4 * i + 1]), Double(input[4 * i + 2]))
                let ref = colour ? (C.inverse * (SIMD3(exp(G.x), exp(G.y), exp(G.z)) * (C * rgb))) : rgb * exp2(E)
                // Relative to the pixel's largest channel: a count of 16 bits is of the pixel, not of a channel near 0.
                let scale = max(abs(ref.x), abs(ref.y), abs(ref.z), 1e-6)
                for c in 0..<3 { worst = max(worst, abs(Double(out[4 * i + c]) - ref[c]) / scale) }
            }
            expect(worst <= 1.5e-5, String(format: "%@ against the expression in double: max %.2e of the pixel (bar 1 count of 16 bits, 1.5e-5)", name, worst))
            if selfTest, colour {
                // C handed transposed (trap 20): the kernel's colour path must then miss.
                let saved = SceneLayerWire.rgbToCone
                _ = saved
                var bad = 0.0
                let t = C.transpose
                for i in stride(from: 0, to: w * h, by: 97) {
                    let rgb = SIMD3(Double(input[4 * i]), Double(input[4 * i + 1]), Double(input[4 * i + 2]))
                    let p = cut.apply(CGPoint(x: (Double(i % w) + 0.5) / Double(w), y: (Double(i / w) + 0.5) / Double(h)))
                    var G = SIMD3<Double>(0, 0, 0)
                    for (l, plane) in zip(a.layers, planes) {
                        G += Double(l.coverage) * sample(plane, Double(p.x), Double(p.y)) * SIMD3(Double(l.logGain.x), Double(l.logGain.y), Double(l.logGain.z))
                    }
                    let ref = t.inverse * (SIMD3(exp(G.x), exp(G.y), exp(G.z)) * (t * rgb))
                    for c in 0..<3 { bad = max(bad, abs(Double(out[4 * i + c]) - ref[c]) / max(abs(ref[c]), 1e-6)) }
                }
                expect(bad > 1e-3, String(format: "self-test: the expression with C transposed is red against the kernel (%.2e)", bad))
            }
        }
        // A full mask of e stops: the scalar gain 2^e to the bit; a pixel no layer reaches: untouched.
        var fullLayer = LocalLayer(name: "All", stage: .scene, parts: [])
        fullLayer.invert = true
        for e in [-2.0, -0.5, 0.5, 2.0] {
            fullLayer.scene = SceneDeltas(exposure: e)
            let a = SceneLayerWire.ask(LocalLayers(items: [fullLayer]), source: source, hostCut: nil, decode: source)!
            let plane = try await baker.bake(fullLayer, source: source)
            let out = try run(a, planes: [plane], f2s: .identity)
            // The GPU's gain is what it made of the pixel of 1; every pixel is that one float gain, to the bit.
            let gain = out[0]
            let exact = (0..<(w * h)).allSatisfy { i in (0..<3).allSatisfy { out[4 * i + $0] == input[4 * i + $0] * gain } }
            let ulps = abs(Int(gain.bitPattern) - Int(Float(exp2(e)).bitPattern))
            expect(exact && ulps <= 1, String(format: "a full mask of %+.1f stops is one scalar gain on every pixel, to the bit: %.9g, %d ulp from 2^e", e, gain, ulps))
        }
        var nowhere = LocalLayer(name: "None", stage: .scene, parts: [.radial(MaskRadial(centre: MaskPoint(-2, -2), rx: 0.01, ry: 0.01, feather: 0))])
        nowhere.scene = SceneDeltas(exposure: 1, temperature: 40)
        let a = SceneLayerWire.ask(LocalLayers(items: [nowhere]), source: source, hostCut: nil, decode: source)!
        let out = try run(a, planes: [try await baker.bake(nowhere, source: source)], f2s: .identity)
        expect(out == input, "a colour layer whose mask is 0 everywhere leaves every pixel to the bit")
        print("scene layer: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
