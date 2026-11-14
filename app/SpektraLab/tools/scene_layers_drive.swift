//  scene_layers_drive.swift — RFC-052 M0's gates through the app's own path: `SceneLayerWire` (the ask, the stamp,
//  the gains), `MaskBaker` (the planes), `MaskFrame` (the matrix) and the real engine client (`SpkEngine`, the
//  app's `FrameSource` contract) on this Mac's engine (`engine/build`). Not the page: a driver, as engine_smoke is.
//
//      tools/scene_layers_drive.sh gate1|gate2|gate4|refusal|cost|stroke|gate10|edge|tint-fit|chart [args]
//
//  Each prints its numbers; the commit that records a gate copies them.

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd

// MARK: the host: the app's FrameSource contract, for jobs this driver makes

final class DriveSource: FrameSource, @unchecked Sendable {
    struct Job { var frame: DecodedFrame; var wire: [String: ParamValue]; var ask: SceneLayerWire.Ask? }
    private let lock = NSLock()
    private var jobs: [UUID: Job] = [:]
    private var results: [UUID: Picture] = [:]
    func add(_ id: UUID, _ j: Job) { lock.lock(); jobs[id] = j; lock.unlock() }
    func result(_ id: UUID) -> Picture? { lock.lock(); defer { lock.unlock() }; return results[id] }
    private func job(_ id: UUID) -> Job { lock.lock(); defer { lock.unlock() }; return jobs[id]! }

    func decode(_ job: RenderJob, device: MTLDevice) throws -> DecodedFrame { self.job(job.id).frame }
    func params(_ job: RenderJob) -> [String: ParamValue] { self.job(job.id).wire }
    func sceneLayers(_ job: RenderJob) -> SceneLayerWire.Ask? { self.job(job.id).ask }
    func deliver(_ job: RenderJob, _ pixels: RenderedPixels) {
        let w = pixels.size.width, h = pixels.size.height
        var px = [UInt16](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w { for c in 0..<3 { px[3 * (y * w + x) + c] = pixels.rgba16[4 * (y * pixels.rowStridePixels + x) + c] } } }
        lock.lock(); results[job.id] = Picture(w: w, h: h, px: px); lock.unlock()
    }
}

struct Picture {
    var w: Int, h: Int, px: [UInt16]
    func at(_ x: Int, _ y: Int, _ c: Int) -> Double { Double(px[3 * (y * w + x) + c]) }
    var sha: String {
        var a: UInt64 = 0xcbf29ce484222325
        for v in px { a = (a ^ UInt64(v)) &* 0x100000001b3 }
        return String(format: "%016llx", a)
    }
}

func apart(_ a: Picture, _ b: Picture) -> (max: Double, mean: Double) {
    guard a.w == b.w, a.h == b.h else { return (.infinity, .infinity) }
    var m = 0.0, s = 0.0
    for i in 0..<a.px.count { let d = abs(Double(a.px[i]) - Double(b.px[i])); m = max(m, d); s += d }
    return (m, s / Double(a.px.count))
}

@main struct Drive {
    nonisolated(unsafe) static var engine: SpkEngine!
    static let source = DriveSource()
    static let device = MTLCreateSystemDefaultDevice()!

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func ms(_ t: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6 }

    // MARK: the wire, as the app sends a new frame's

    /// The app's own wire for a new frame (`FilmParams.default`), with the photograph's crop (`Geometry.wire`'s
    /// eight fields, written again here: `EngineWire.swift` brings the whole page with it), product defaults, grain
    /// and glare off (RFC-052 §10.1), the meter off.
    static func wire(_ p: FilmParams = .default, geometry g: Geometry = .default, extra: [String: ParamValue] = [:]) -> [String: ParamValue] {
        var w = p.fullDelta
        w["product_defaults"] = .bool(true)
        w["grain_active"] = .bool(false)
        w["grain_sublayers_active"] = .bool(false)
        w["glare_active"] = .bool(false)
        w["auto_exposure"] = .bool(false)
        w["overscan_active"] = .bool(false)
        w["date_imprint_active"] = .bool(false)
        w["geometry_crop_x"] = .double(g.crop.x); w["geometry_crop_y"] = .double(g.crop.y)
        w["geometry_crop_w"] = .double(g.crop.width); w["geometry_crop_h"] = .double(g.crop.height)
        w["geometry_rotation_deg"] = .double(g.angle)
        w["geometry_quarter_turns"] = .double(Double(((g.quarterTurns % 4) + 4) % 4))
        w["geometry_flip_h"] = .bool(g.flipH); w["geometry_flip_v"] = .bool(g.flipV)
        for (k, v) in extra { w[k] = v }
        return w
    }

    /// Scene Latitude on and a Decode curve on, as the app's model makes them.
    static func placedAndCurved(_ p: inout FilmParams) {
        p.sceneLatitude.active = true
        p.sceneLatitude.highlightKnee = 1.0; p.sceneLatitude.highlightRoom = 1.5
        p.sceneLatitude.shadowKnee = -2.0; p.sceneLatitude.shadowRoom = 1.0
        p.sceneCurve.rgb.points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.3, y: 0.36), CGPoint(x: 0.7, y: 0.74), CGPoint(x: 1, y: 1)]
    }

    static func frame(_ rgb: [Float], _ w: Int, _ h: Int) -> DecodedFrame {
        DecodedFrame(buffer: device.makeBuffer(bytes: rgb, length: rgb.count * 4, options: .storageModeShared)!,
                     size: PixelSize(width: w, height: h), channels: rgb.count / (w * h))
    }

    /// One job through the engine client: `kind` and `tier` as the app would name them; returns the picture.
    static func develop(_ f: DecodedFrame, wire: [String: ParamValue], ask: SceneLayerWire.Ask?, frameID: UUID = UUID(),
                        kind: JobKind = .export, tier: RenderTier = .full) async throws -> Picture {
        let job = RenderJob(frameID: frameID, kind: kind, tier: tier, canvas: f.size, decodesOriginal: tier == .full, original: f.size)
        source.add(job.id, .init(frame: f, wire: wire, ask: ask))
        _ = try await engine.run(job, mode: .whole) { _ in }
        return source.result(job.id)!
    }

    // MARK: fixtures

    /// A scene of smooth gradients and colour, 0.005…2.4 linear: every part of the film's curve is crossed.
    static func scene(_ w: Int, _ h: Int) -> [Float] {
        var f = [Float](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w {
            let s = (Double(x) + 0.5) / Double(w), t = (Double(y) + 0.5) / Double(h)
            let l = 0.005 * pow(480, s)
            let i = 3 * (y * w + x)
            f[i] = Float(l * (1 + 0.6 * sin(6.3 * t))); f[i + 1] = Float(l * (1 + 0.3 * cos(4.1 * t + 1))); f[i + 2] = Float(l * (1 + 0.5 * sin(5.2 * t + 2)))
        } }
        return f
    }

    static func fullLayer(exposure e: Double = 0, temperature: Double = 0, tint: Double = 0) -> LocalLayer {
        var l = LocalLayer(name: "All", stage: .scene, parts: [])
        l.invert = true          // no part, inverted: the whole picture, 65535 everywhere
        l.scene = SceneDeltas(exposure: e, temperature: temperature, tint: tint)
        return l
    }

    static func ask(_ layers: [LocalLayer], source: PixelSize, cut: Geometry? = nil, decode: PixelSize? = nil,
                    family: JoinFamily = .products, found: [String: FoundPicture] = [:]) -> SceneLayerWire.Ask? {
        SceneLayerWire.ask(LocalLayers(items: layers), source: source, hostCut: cut, decode: decode ?? source, family: family, found: found)
    }

    static func wired(_ w: [String: ParamValue], _ a: SceneLayerWire.Ask?) -> [String: ParamValue] {
        var w = w
        if let a { w["scene_layers"] = .string(a.stamp) }
        return w
    }

    // MARK: gate 1: a full mask is Film Exposure, through the app's path

    static func gate1() async throws {
        let W = 1500, H = 1000
        let f = frame(scene(W, H), W, H)
        let c = 0.3
        print("== gate 1: a full-mask layer of e stops (SceneLayerWire + MaskBaker + SpkEngine) against Film Exposure c + e ==")
        print("   Portra 400 -> Portra Endura (the app's default pair), product defaults, grain and glare off, \(W) x \(H), full tier")
        var worst = 0.0
        for placed in [false, true] {
            var p = FilmParams.default
            if placed { placedAndCurved(&p) }
            for e in [-2.0, -0.5, 0.5, 2.0] {
                var pa = p; pa.exposureCompensationEV = c + e
                var pb = p; pb.exposureCompensationEV = c
                let a = try await develop(f, wire: wire(pa), ask: nil)
                let layered = ask([fullLayer(exposure: e)], source: PixelSize(width: W, height: H))!
                let b = try await develop(f, wire: wired(wire(pb), layered), ask: layered)
                let d = apart(a, b)
                worst = max(worst, d.max)
                print(String(format: "   %@ e = %+.1f: max %.0f counts (%.1e), mean %.4f counts; stamp %@", placed ? "Scene Latitude + Decode curve," : "plain,", e,
                             d.max, d.max / 65535, d.mean, layered.stamp))
            }
        }
        // Red first: the same comparison with the gain handed in stops rather than natural log (a convention slip
        // between the host and the node), and with the plane one count short of full.
        var p = FilmParams.default
        placedAndCurved(&p)
        var pa = p; pa.exposureCompensationEV = c + 0.5
        var pb = p; pb.exposureCompensationEV = c
        let a = try await develop(f, wire: wire(pa), ask: nil)
        var slip = ask([fullLayer(exposure: 0.5)], source: PixelSize(width: W, height: H))!
        slip.layers[0].logGain = SIMD3(repeating: 0.5)
        slip.stamp = SceneLayerWire.stamp(slip.layers, frameToSource: slip.frameToSource)
        let b = try await develop(f, wire: wired(wire(pb), slip), ask: slip)
        let d = apart(a, b)
        print(String(format: "   red: the gain handed as stops, not ln: max %.0f counts, mean %.1f -> %@", d.max, d.mean, d.max > 2 ? "red" : "STAYED GREEN"))
        var short = fullLayer(exposure: 0.5); short.opacity = 65534.0 / 65535
        let sa = ask([short], source: PixelSize(width: W, height: H))!
        let sb = try await develop(f, wire: wired(wire(pb), sa), ask: sa)
        let ds = apart(a, sb)
        print(String(format: "   (a coverage one count short of full, 65534/65535: max %.0f counts, mean %.3f — the identity is exact in k, not near it)", ds.max, ds.mean))
        print(String(format: "gate 1: worst %.0f counts (bar: the parity suite's 3e-5 = %.1f counts) -> %@", worst, 3e-5 * 65535, worst <= 3e-5 * 65535 && d.max > 2 ? "PASS" : "FAIL"))
    }

    // MARK: gate 2: neutral is today's, to the bit

    static func gate2() async throws {
        let W = 1200, H = 800
        let f = frame(scene(W, H), W, H)
        let src = PixelSize(width: W, height: H)
        var p = FilmParams.default
        placedAndCurved(&p)
        print("== gate 2: neutral edits send no scene_layers and develop to today's bytes ==")
        let today = try await develop(f, wire: wire(p), ask: nil)
        var base = LocalLayer(name: "Sky", stage: .scene, parts: [.linear(MaskLinear(a: MaskPoint(0.5, 0), b: MaskPoint(0.5, 0.6)))])
        base.scene = SceneDeltas(exposure: 1, temperature: 30)
        var off = base; off.on = false
        var clear = base; clear.opacity = 0
        var zero = base; zero.scene = SceneDeltas()
        var allOffParts = base; allOffParts.parts[0].on = false
        let cases: [(String, [LocalLayer])] = [("no layers", []), ("all off", [off]), ("opacity 0", [clear]), ("zero deltas", [zero]),
                                               ("a 成片 layer only", [base.moved(to: .finished)]), ("every part off", [allOffParts])]
        var ok = true
        for (name, ls) in cases {
            let a = ask(ls, source: src)
            let w = wired(wire(p), a)
            let pic = try await develop(f, wire: w, ask: a)
            let same = pic.px == today.px && w["scene_layers"] == nil
            ok = ok && same
            print("   \(name): ask \(a == nil ? "none" : a!.stamp), wire field \(w["scene_layers"].map { "\($0)" } ?? "absent"), sha \(pic.sha) \(same ? "= today's" : "DIFFERS")")
        }
        // The engine's own rest: a wire that names "" (an older session's leaving) is today's too.
        let rest = try await develop(f, wire: wire(p, extra: ["scene_layers": .string("")]), ask: nil)
        ok = ok && rest.px == today.px
        print("   scene_layers = \"\" on the wire: sha \(rest.sha) \(rest.px == today.px ? "= today's" : "DIFFERS")")
        // And a layer that does act is not today's (the check can fail).
        let acting = ask([base], source: src)!
        let moved = try await develop(f, wire: wired(wire(p), acting), ask: acting)
        let d = apart(today, moved)
        print(String(format: "   red: a +1 stop, +30 色温 gradient layer: max %.0f counts from today's (the check can fail)", d.max))
        print("gate 2: today's sha \(today.sha) -> \(ok && d.max > 0 ? "PASS" : "FAIL")")
    }

    // MARK: the refusal, reached from the app's side

    static func refusal() async throws {
        let W = 600, H = 400
        let f = frame(scene(W, H), W, H)
        let src = PixelSize(width: W, height: H)
        let id = UUID()
        var one = LocalLayer(name: "A", stage: .scene, parts: [.radial(MaskRadial(centre: MaskPoint(0.5, 0.5), rx: 0.2, ry: 0.2, feather: 0.5))])
        one.scene = SceneDeltas(exposure: 1)
        var two = one; two.scene = SceneDeltas(exposure: 1.5)
        let a1 = ask([one], source: src)!, a2 = ask([two], source: src)!
        print("== the stamp's refusal, reached through SpkEngine ==")
        _ = try await develop(f, wire: wired(wire(), a1), ask: a1, frameID: id, kind: .canvasDevelop, tier: .preview)
        print("   stroke 1 developed on the page's session: \(a1.stamp)")
        // A host that put stroke 2's stamp on the wire and handed stroke 1's set (what capturing at submit prevents).
        do {
            var stale = a1
            stale.stamp = a1.stamp
            _ = try await develop(f, wire: wired(wire(), a2), ask: stale, frameID: id, kind: .canvasDevelop, tier: .preview)
            print("FAIL: the engine developed stroke 2's wire on stroke 1's planes")
        } catch {
            let text = "\(error)"
            let named = text.contains(a1.stamp) && text.contains(a2.stamp)
            print("   refused: \(text)")
            print("refusal: \(named ? "PASS (both stamps named)" : "FAIL")")
        }
        // The same session goes on with the right set.
        let after = try await develop(f, wire: wired(wire(), a2), ask: a2, frameID: id, kind: .canvasDevelop, tier: .preview)
        print("   stroke 2 with its own set: developed, \(after.w) x \(after.h)")
    }

    // MARK: gate 4, the host's part: the app's HostCut and MaskFrame against the engine's own cut

    static let SW = 1500, SH = 1000
    static let R = (0.30, 0.28, 0.62, 0.66)
    static func inR(_ s: Double, _ t: Double) -> Bool { s >= R.0 && s < R.2 && t >= R.1 && t < R.3 }

    static func target() -> [Float] {
        var f = [Float](repeating: 0, count: SW * SH * 4)
        for y in 0..<SH { for x in 0..<SW {
            let i = inR((Double(x) + 0.5) / Double(SW), (Double(y) + 0.5) / Double(SH))
            let p = 4 * (y * SW + x)
            f[p] = Float(0.184 * (i ? 1.5 : 1)); f[p + 1] = 0.184; f[p + 2] = Float(0.184 * (i ? 0.6 : 1)); f[p + 3] = 1
        } }
        return f
    }

    static let ci = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])

    /// The decode cut by the app's own `HostCut.image`, as `FrameDecoder` cuts it.
    static func hostCut(_ rgba: [Float], _ w: Int, _ h: Int, by g: Geometry) -> DecodedFrame {
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil)
        let cut = HostCut.image(image, by: g)
        let box = cut.extent.integral
        let cw = Int(box.width), ch = Int(box.height)
        let buf = device.makeBuffer(length: cw * ch * 16, options: .storageModeShared)!
        ci.render(cut, toBitmap: buf.contents(), rowBytes: cw * 16, bounds: box, format: .RGBAf, colorSpace: nil)
        return DecodedFrame(buffer: buf, size: PixelSize(width: cw, height: ch), channels: 4)
    }

    struct EdgeError { var max = 0.0, mean = 0.0, points = 0 }
    static func edgeError(_ a: [Bool], _ b: [Bool], _ w: Int, _ h: Int) -> EdgeError {
        func boundary(_ m: [Bool]) -> [(Double, Double)] {
            var p: [(Double, Double)] = []
            for y in 0..<h { for x in 0..<w {
                let i = y * w + x
                if x + 1 < w, m[i] != m[i + 1] { p.append((Double(x) + 1, Double(y) + 0.5)) }
                if y + 1 < h, m[i] != m[i + w] { p.append((Double(x) + 0.5, Double(y) + 1)) }
            } }
            return p
        }
        let pa = boundary(a), pb = boundary(b)
        var e = EdgeError(); e.points = pa.count
        guard !pa.isEmpty, !pb.isEmpty else { e.max = 1e9; return e }
        var sum = 0.0
        // A grid of the second set's points, so the nearest is found near (Hausdorff, normal to the edge).
        func directed(_ from: [(Double, Double)], _ to: [(Double, Double)]) {
            var grid: [Int: [(Double, Double)]] = [:]
            for q in to { grid[Int(q.1 / 8) * 4096 + Int(q.0 / 8), default: []].append(q) }
            for p in from {
                var best = Double.infinity
                let gx = Int(p.0 / 8), gy = Int(p.1 / 8)
                var r = 0
                while r < 512 {
                    for yy in (gy - r)...(gy + r) { for xx in (gx - r)...(gx + r) where abs(yy - gy) == r || abs(xx - gx) == r {
                        for q in grid[yy * 4096 + xx] ?? [] { best = min(best, (p.0 - q.0) * (p.0 - q.0) + (p.1 - q.1) * (p.1 - q.1)) }
                    } }
                    if best.squareRoot() < Double(r) * 8 { break }
                    r += 1
                }
                let d = best.squareRoot()
                e.max = max(e.max, d); sum += d
            }
        }
        directed(pa, pb); directed(pb, pa)
        e.mean = sum / Double(pa.count + pb.count)
        return e
    }

    /// One case's edge error, in output pixels: the target's edge on a render without the layer, against the mask's
    /// on a render with it, each found on its own signal at its own half weight (the engine's gate 4, here through the
    /// app's ask, baker, matrix and client). `f2s` overrides the matrix (the self-test).
    static func geoCase(engineCut: Geometry, hostCut cut: Geometry?, plane found: FoundPicture, f2s: MaskMatrix? = nil) async throws -> EdgeError {
        let src = target()
        let decoded = cut.map { hostCut(src, SW, SH, by: $0) }
            ?? DecodedFrame(buffer: device.makeBuffer(bytes: src, length: src.count * 4, options: .storageModeShared)!,
                            size: PixelSize(width: SW, height: SH), channels: 4)
        let size = PixelSize(width: SW, height: SH)
        var mix = [Float](repeating: 0, count: decoded.size.width * decoded.size.height * 4)
        for i in stride(from: 0, to: mix.count, by: 4) { mix[i] = Float(0.184 * 1.25); mix[i + 1] = 0.184; mix[i + 2] = Float(0.184 * 0.8); mix[i + 3] = 1 }
        let mixFrame = frame(mix, decoded.size.width, decoded.size.height)
        var layer = LocalLayer(name: "R", stage: .scene, parts: [.found(FoundMask(what: .subject, width: found.width, height: found.height), asset: "R")])
        layer.scene = SceneDeltas(exposure: 1.5)
        var half = fullLayer(exposure: 1.5); half.opacity = 0.5
        var aMask = ask([layer], source: size, cut: cut, found: ["R": found])!
        if let f2s { aMask.frameToSource = f2s; aMask.stamp = SceneLayerWire.stamp(aMask.layers, frameToSource: f2s) }
        let aHalf = ask([half], source: size, cut: cut)!
        let w0 = wire(geometry: engineCut, extra: ["halation_active": .bool(false)])
        let a = try await develop(decoded, wire: w0, ask: nil)
        let b = try await develop(decoded, wire: wired(w0, aMask), ask: aMask)
        let hh = try await develop(decoded, wire: wired(w0, aHalf), ask: aHalf)
        let m = try await develop(mixFrame, wire: w0, ask: nil)
        let ow = a.w, oh = a.h
        let cm = (m.at(ow / 2, oh / 2, 0) + 1) / (m.at(ow / 2, oh / 2, 2) + 1)
        var T = [Bool](repeating: false, count: ow * oh), M = T
        for i in 0..<(ow * oh) {
            T[i] = (Double(a.px[3 * i]) + 1) / (Double(a.px[3 * i + 2]) + 1) > cm
            M[i] = b.px[3 * i + 1] > hh.px[3 * i + 1] && b.px[3 * i + 1] > a.px[3 * i + 1]
        }
        return edgeError(T, M, ow, oh)
    }

    static func gate4() async throws {
        // The mask is R as a found picture at the source's own size (the baker samples it at the same centres, so the
        // plane is R exactly), and at 1024 x 683 (the plane's texels then move its edge by up to half a texel).
        func pic(_ w: Int, _ h: Int) -> FoundPicture {
            FoundPicture(width: w, height: h, bytes: (0..<(w * h)).map { i in inR((Double(i % w) + 0.5) / Double(w), (Double(i / w) + 0.5) / Double(h)) ? 255 : 0 })
        }
        func g(_ crop: CropRect = .full, angle: Double = 0, turns: Int = 0, flipH: Bool = false, flipV: Bool = false) -> Geometry {
            var x = Geometry(); x.crop = crop; x.angle = angle; x.quarterTurns = turns; x.flipH = flipH; x.flipV = flipV; return x
        }
        let crop = CropRect(x: 0.1, y: 0.05, width: 0.8, height: 0.85)
        let host = CropRect(x: 0.15, y: 0.1, width: 0.75, height: 0.7)
        let cases: [(String, Geometry, Geometry?)] = [
            ("identity", g(), nil),
            ("engine crop", g(crop), nil),
            ("crop + straighten 7", g(crop, angle: 7), nil),
            ("quarter turn 1", g(turns: 1), nil), ("quarter turns 2", g(turns: 2), nil), ("quarter turns 3", g(turns: 3), nil),
            ("flip h + flip v", g(flipH: true, flipV: true), nil),
            ("crop + straighten -5 + turn 1 + flip h", g(crop, angle: -5, turns: 1, flipH: true), nil),
            ("host cut (HostCut.image + MaskFrame.engineNode)", g(), g(host)),
            ("host cut + engine straighten 4 + turn 3", g(angle: 4, turns: 3), g(host)),
            ("host cut, mirrored + engine flip v", g(flipV: true), g(host, flipH: true)),
            ("host cut with its own turn 1 + straighten 3 (a film edge's framing)", g(), g(host, angle: 3, turns: 1)),
            ("host perspective (Vertical 6) + engine crop", g(crop), { var x = Geometry(); x.vertical = 6; return x }()),
        ]
        print("== gate 4 (host part): the mask's edge against the picture's, through the app's HostCut/MaskFrame and the engine's cut ==")
        var ok = true
        for (planeName, p) in [("1500 x 1000 (the source's)", pic(SW, SH)), ("1024 x 683", pic(1024, 683))] {
            for (name, engineCut, cut) in cases {
                let e = try await geoCase(engineCut: engineCut, hostCut: cut, plane: p)
                ok = ok && e.max <= 1 && e.points > 0
                print(String(format: "   plane %@, %@: max %.2f px, mean %.3f px, %d points %@", planeName, name, e.max, e.mean, e.points, e.max <= 1 ? "" : "FAIL"))
            }
        }
        print("== gate 4's self-test: the host's matrix broken goes red ==")
        let (_, eng, cut) = cases[11]
        let truth = MaskFrame.engineNode(hostCut: cut, decode: CGSize(width: SW, height: SH))
        var red = true
        for k in [0, 2, 4, 5] {
            var m = truth; m.m[k] += 0.01
            let e = try await geoCase(engineCut: eng, hostCut: cut, plane: pic(SW, SH), f2s: m)
            red = red && e.max > 1
            print(String(format: "   frame_to_source[%d] + 0.01: max %.1f px %@", k, e.max, e.max > 1 ? "red" : "STAYED GREEN"))
        }
        let e = try await geoCase(engineCut: eng, hostCut: cut, plane: pic(SW, SH), f2s: .identity)
        red = red && e.max > 1
        print(String(format: "   the host cut handed as the identity: max %.1f px %@", e.max, e.max > 1 ? "red" : "STAYED GREEN"))
        print("gate 4 (host): \(ok && red ? "PASS" : "FAIL")")
    }

    // MARK: gate 6: cost

    /// The process's footprint, sampled every millisecond while `body` runs: the peak above the start.
    static func peak(_ body: () async throws -> Void) async rethrows -> UInt64 {
        let start = MemoryProbe.footprint()
        let box = PeakBox(start)
        let t = Thread { while !box.stopped { box.see(MemoryProbe.footprint()); usleep(1000) } }
        t.start()
        try await body()
        box.see(MemoryProbe.footprint())
        box.stopped = true
        return box.peak > start ? box.peak - start : 0
    }
    final class PeakBox: @unchecked Sendable {
        var peak: UInt64; var stopped = false
        init(_ v: UInt64) { peak = v }
        func see(_ v: UInt64) { if v > peak { peak = v } }
    }

    static func strokes(_ n: Int, radius: Double = 0.02) -> [BrushStroke] {
        (0..<n).map { i in
            let y = 0.05 + 0.9 * Double(i) / Double(max(n, 1))
            let pts = (0..<24).map { k in MaskPoint(0.05 + 0.9 * Double(k) / 23, y + 0.03 * sin(Double(k) * 0.7 + Double(i))) }
            return BrushStroke(radius: radius, hardness: 0.6, flow: 0.5, erase: i % 9 == 8, points: pts)
        }
    }

    static func costCase(_ name: String) -> (LocalLayer, [String: FoundPicture]) {
        var l = LocalLayer(name: name, stage: .scene, parts: [])
        l.scene = SceneDeltas(exposure: 1)
        var found: [String: FoundPicture] = [:]
        switch name {
        case "gradient": l.parts = [.linear(MaskLinear(a: MaskPoint(0.5, 0), b: MaskPoint(0.5, 0.6)))]
        case "brush200": l.parts = [.brush(BrushStrokes(strokes: strokes(200)))]
        case "found":
            let w = 1024, h = 683
            found["F"] = FoundPicture(width: w, height: h, bytes: (0..<(w * h)).map { i in
                let x = Double(i % w) / Double(w) - 0.5, y = Double(i / w) / Double(h) - 0.5
                return x * x + y * y < 0.08 ? 255 : 0 })
            l.parts = [.found(FoundMask(what: .subject, width: w, height: h), asset: "F")]
        default:   // fold3: a gradient, less a soft radial, intersected with a second gradient, feathered
            l.parts = [.linear(MaskLinear(a: MaskPoint(0, 0), b: MaskPoint(1, 1))),
                       .radial(MaskRadial(centre: MaskPoint(0.5, 0.5), rx: 0.2, ry: 0.15, angle: 20, feather: 0.7), join: .subtract),
                       .linear(MaskLinear(a: MaskPoint(1, 0.5), b: MaskPoint(0.3, 0.5)), join: .intersect)]
            l.feather = 0.005
        }
        return (l, found)
    }

    /// `cost <case>`: one bake case in this process, at L_c = 4096 for a 45 MP source: cold (the kernels compiled,
    /// nothing cached), then five warm bakes of new planes (the cache cleared each time) — times and peak footprint.
    static func cost(_ name: String) async throws {
        let src = PixelSize(width: 8256, height: 5504)
        let (layer, found) = costCase(name)
        var compile = 0.0
        let t0 = now()
        let baker = try MaskBaker(device: device)
        compile = ms(t0)
        var cold = 0.0
        let coldPeak = try await peak {
            let t = now()
            let p = try await baker.bake(layer, source: src, found: found)
            cold = ms(t)
            precondition(p.width == 4096 && p.height == 2731)
        }
        var warm: [Double] = []
        var warmPeak: UInt64 = 0
        for _ in 0..<5 {
            await baker.store.clear()
            let pk = try await peak {
                let t = now()
                _ = try await baker.bake(layer, source: src, found: found)
                warm.append(ms(t))
            }
            warmPeak = max(warmPeak, pk)
        }
        warm.sort()
        print(String(format: "cost %@: kernels compiled %.0f ms; cold bake %.1f ms (peak +%.0f MB); warm bakes median %.1f ms (%.1f…%.1f), peak +%.0f MB; plane 4096 x 2731, %.1f MB",
                     name, compile, cold, Double(coldPeak) / 1048576, warm[2], warm[0], warm[4], Double(warmPeak) / 1048576, Double(4096 * 2731 * 2) / 1048576))
    }

    /// `stroke`: a stroke's whole turnaround on a 45 MP session, excluding the develop: the 201st stroke baked onto the
    /// plane of 200 (`MaskStore`), the ask and its stamp, the wire's delta (`spk_set_params`, a SHOOT field: the
    /// pipeline is rebuilt) and `spk_set_scene_layers` with the planes — interleaved over five strokes.
    static func stroke() async throws {
        let W = 8256, H = 5504
        let src = PixelSize(width: W, height: H)
        let f = frame([Float](repeating: 0.184, count: W * H * 3), W, H)
        var all = strokes(205)
        var layer = LocalLayer(name: "Brush", stage: .scene, parts: [.brush(BrushStrokes(strokes: Array(all.prefix(200))))])
        layer.scene = SceneDeltas(exposure: 1)
        let id = UUID()
        let first = ask([layer], source: src)!
        // The page's session, opened by a develop at the live tier (as the page's canvas would be).
        _ = try await develop(f, wire: wired(wire(extra: ["preview_long_edge": .double(2400)]), first), ask: first, frameID: id,
                              kind: .canvasDevelop, tier: .live)
        let baker = try SceneLayerWire.baker(for: device)
        var rows: [(bake: Double, ask: Double, call: Double, total: Double)] = []
        for n in 201...205 {
            let t0 = now()
            layer.parts[0].brush = BrushStrokes(strokes: Array(all[0..<n]))
            let tb = now()
            _ = try await baker.bake(layer, source: src)
            let bake = ms(tb)
            let ta = now()
            let a = ask([layer], source: src)!
            let askMs = ms(ta)
            // The call: the engine client's own hand-off (`SpkEngine.handSceneLayers`) and the wire's delta, on the
            // session the page holds, timed by a reprint-free job: the job's render is excluded by timing the hand-off.
            let tc = now()
            try await engine.prepareSceneLayers(a, frameID: id, wire: wired(wire(extra: ["preview_long_edge": .double(2400)]), a))
            let call = ms(tc)
            rows.append((bake, askMs, call, ms(t0)))
        }
        _ = all.removeLast()
        for (i, r) in rows.enumerated() {
            print(String(format: "stroke %d: bake (incremental) %.1f ms, ask + stamp %.2f ms, set_params + set_scene_layers %.1f ms, whole %.1f ms", 201 + i, r.bake, r.ask, r.call, r.total))
        }
        let totals = rows.map(\.total).sorted()
        print(String(format: "stroke turnaround at 45 MP (bake -> buffers -> call -> wire), median %.1f ms of 5", totals[2]))
    }

    // MARK: gate 10: the joining family, for the owner to look at

    static func linearProPhoto() -> CGColorSpace {
        let d50: [CGFloat] = [0.9642, 1.0, 0.8249], black: [CGFloat] = [0, 0, 0], gamma: [CGFloat] = [1, 1, 1]
        let m: [CGFloat] = [0.7976749, 0.2880402, 0.0, 0.1351917, 0.7118741, 0.0, 0.0313534, 0.0000857, 0.8252100]
        return CGColorSpace(calibratedRGBWhitePoint: d50, blackPoint: black, gamma: gamma, matrix: m)!
    }

    /// A photograph decoded as the engine takes it: linear ProPhoto, RGBA float, top row first, at `longEdge`.
    static func decode(_ url: URL, longEdge: Int, raw: ((CIRAWFilter) -> Void)? = nil) -> DecodedFrame {
        var image: CIImage
        if let raw, let filter = CIRAWFilter(imageURL: url) {
            filter.boostAmount = 0; filter.boostShadowAmount = 0; filter.isGamutMappingEnabled = false
            filter.localToneMapAmount = 0; filter.extendedDynamicRangeAmount = 0; filter.isLensCorrectionEnabled = false
            raw(filter)
            image = filter.outputImage!
        } else {
            image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])!
        }
        let whole = image.extent.integral
        image = image.transformed(by: .init(translationX: -whole.origin.x, y: -whole.origin.y))
        let k = min(1, Double(longEdge) / Double(max(whole.width, whole.height)))
        if k < 1 {
            let s = CIFilter(name: "CILanczosScaleTransform")!
            s.setValue(image.clampedToExtent(), forKey: kCIInputImageKey); s.setValue(k, forKey: kCIInputScaleKey); s.setValue(1.0, forKey: kCIInputAspectRatioKey)
            image = s.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: (whole.width * k).rounded(), height: (whole.height * k).rounded()))
        }
        let w = Int(image.extent.width), h = Int(image.extent.height)
        let buf = device.makeBuffer(length: w * h * 16, options: .storageModeShared)!
        let ctx = CIContext(mtlDevice: device, options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                                         .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
        ctx.render(image, toBitmap: buf.contents(), rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf,
                   colorSpace: linearProPhoto())
        return DecodedFrame(buffer: buf, size: PixelSize(width: w, height: h), channels: 4)
    }

    /// The engine's picture as a 16-bit PNG. The engine's result is in its output space (sRGB, the engine's default:
    /// `output_color_space`), so the file is tagged sRGB; side by side is what matters here.
    static func png(_ p: Picture, _ url: URL, crop: CGRect? = nil) {
        let r = crop.map { CGRect(x: Int($0.minX), y: Int($0.minY), width: Int($0.width), height: Int($0.height)) } ?? CGRect(x: 0, y: 0, width: p.w, height: p.h)
        let w = Int(r.width), h = Int(r.height)
        var px = [UInt16](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w { for c in 0..<3 { px[3 * (y * w + x) + c] = p.px[3 * ((y + Int(r.minY)) * p.w + x + Int(r.minX)) + c].bigEndian } } }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) } as CFData
        let img = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: w * 6, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: CGDataProvider(data: data)!, decode: nil,
                          shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    static func maskPNG(_ p: MaskPlane, _ url: URL) {
        let v = p.values
        let data = v.map { $0.bigEndian }.withUnsafeBufferPointer { Data(buffer: $0) } as CFData
        let img = CGImage(width: p.width, height: p.height, bitsPerComponent: 16, bitsPerPixel: 16, bytesPerRow: p.width * 2,
                          space: CGColorSpace(name: CGColorSpace.linearGray)!, bitmapInfo: CGBitmapInfo(rawValue: 0),
                          provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    /// Pictures side by side, with a gap: one PNG.
    static func sideBySide(_ ps: [Picture], _ url: URL) {
        let gap = 16, h = ps.map(\.h).max()!, w = ps.map(\.w).reduce(0, +) + gap * (ps.count - 1)
        var out = Picture(w: w, h: h, px: [UInt16](repeating: 65535, count: w * h * 3))
        var x0 = 0
        for p in ps {
            for y in 0..<p.h { for x in 0..<p.w { for c in 0..<3 { out.px[3 * (y * w + x0 + x) + c] = p.px[3 * (y * p.w + x) + c] } } }
            x0 += p.w + gap
        }
        png(out, url)
    }

    static func gate10(_ photo: URL, _ outDir: URL) async throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        // "flat": an even grey field (0.18, linear), where a crease in a mask has nothing to hide behind.
        let flat = photo.lastPathComponent == "flat"
        let f = flat ? frame([Float](repeating: 0.18, count: 1600 * 1067 * 3), 1600, 1067) : decode(photo, longEdge: 1600)
        let tag = flat ? "flat-" : ""
        let src = f.size
        let crossed = [MaskPart.linear(MaskLinear(a: MaskPoint(0.0, 0.5), b: MaskPoint(0.75, 0.5))),
                       .linear(MaskLinear(a: MaskPoint(0.5, 0.0), b: MaskPoint(0.5, 0.8)))]
        let less = [MaskPart.linear(MaskLinear(a: MaskPoint(0.5, 0.0), b: MaskPoint(0.5, 0.85))),
                    .radial(MaskRadial(centre: MaskPoint(0.5, 0.42), rx: 0.22, ry: 0.16, feather: 0.9), join: .subtract)]
        let base = try await develop(f, wire: wire(), ask: nil)
        png(base, outDir.appendingPathComponent(tag + "photo.png"))
        print("== gate 10: the joining family, products beside max/min, at ±3 stops in the 场景 stage (\(photo.lastPathComponent), \(src.width) x \(src.height)) ==")
        let baker = try SceneLayerWire.baker(for: device)
        for (name, parts) in [("crossed-gradients", crossed), ("gradient-less-soft-radial", less)] {
            for e in [3.0, -3.0] {
                var pics: [Picture] = []
                for family in [JoinFamily.products, .maxMin] {
                    var l = LocalLayer(name: name, stage: .scene, parts: parts)
                    l.scene = SceneDeltas(exposure: e)
                    let a = ask([l], source: src, family: family)!
                    let pic = try await develop(f, wire: wired(wire(), a), ask: a)
                    pics.append(pic)
                    let plane = try await baker.bake(l, source: src, family: family)
                    maskPNG(plane, outDir.appendingPathComponent("\(tag)\(name)-\(family.rawValue)-mask.png"))
                }
                let url = outDir.appendingPathComponent(String(format: "%@%@-%@%.0fEV-products-left-maxmin-right.png", tag, name, e > 0 ? "+" : "", e))
                sideBySide(pics, url)
                let d = apart(pics[0], pics[1])
                print(String(format: "   %@ %+.0f EV: %@ (products and max/min differ by up to %.0f counts, mean %.1f)", name, e, url.path, d.max, d.mean))
            }
        }
    }

    // MARK: the hard brush edge at Full

    /// The plane's value at S as the engine's kernel samples it (manual bilinear between texel centres, clamped).
    static func sample(_ v: [UInt16], _ pw: Int, _ ph: Int, _ s: Double, _ t: Double) -> Double {
        let x = min(max(s * Double(pw) - 0.5, 0), Double(pw - 1)), y = min(max(t * Double(ph) - 0.5, 0), Double(ph - 1))
        let x0 = Int(x), y0 = Int(y), x1 = min(x0 + 1, pw - 1), y1 = min(y0 + 1, ph - 1)
        let tx = x - Double(x0), ty = y - Double(y0)
        let a = Double(v[y0 * pw + x0]), b = Double(v[y0 * pw + x1]), c = Double(v[y1 * pw + x0]), d = Double(v[y1 * pw + x1])
        let top = a + (b - a) * tx, bot = c + (d - c) * tx
        return (top + (bot - top) * ty) / 65535
    }

    static func edge(_ outDir: URL) async throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let baker = try SceneLayerWire.baker(for: device)
        print("== the hard brush edge at Full: a hardness-1 stroke baked at L_c = 4096, sampled at the export's pixels ==")
        for (name, W, H) in [("45 MP (8256 x 5504, the Z7 II)", 8256, 5504), ("100 MP (11648 x 8736, a GFX100's)", 11648, 8736)] {
            let src = PixelSize(width: W, height: H)
            // A vertical stroke: its left edge crosses rows; radius 0.05 of the long edge.
            var l = LocalLayer(name: "Hard", stage: .scene, parts: [.brush(BrushStrokes(strokes: [
                BrushStroke(radius: 0.05, hardness: 1, flow: 1, points: [MaskPoint(0.5, 0.1), MaskPoint(0.5, 0.9)])]))])
            l.scene = SceneDeltas(exposure: 2)
            let plane = try await baker.bake(l, source: src)
            let v = plane.values
            // Along the middle row of the export, across the stroke's left edge: the 10–90 % width in export pixels.
            let row = (Double(H) / 2 + 0.5) / Double(H)
            let centre = 0.5 - 0.05 * Double(max(W, H)) / Double(W)
            var xs: [(Double, Double)] = []
            for x in Int(centre * Double(W)) - 12...Int(centre * Double(W)) + 12 {
                xs.append((Double(x), sample(v, plane.width, plane.height, (Double(x) + 0.5) / Double(W), row)))
            }
            func cross(_ level: Double) -> Double {
                for (a, b) in zip(xs, xs.dropFirst()) where (a.1 - level) * (b.1 - level) <= 0 && a.1 != b.1 {
                    return a.0 + (level - a.1) / (b.1 - a.1) * (b.0 - a.0)
                }
                return .nan
            }
            let width = cross(0.9) - cross(0.1)
            let ratio = Double(max(W, H)) / Double(max(plane.width, plane.height))
            print(String(format: "   %@: plane %d x %d (%.2f export px a texel); 10–90%% edge width %.2f export px; profile %@",
                         name, plane.width, plane.height, ratio, width, xs.map { String(format: "%.2f", $0.1) }.joined(separator: " ")))
        }
        // The 45 MP one rendered through the engine at Full, flat grey, +2 stops under the stroke: a crop of the edge.
        let W = 8256, H = 5504, src = PixelSize(width: W, height: H)
        let f = frame([Float](repeating: 0.09, count: W * H * 3), W, H)
        var l = LocalLayer(name: "Hard", stage: .scene, parts: [.brush(BrushStrokes(strokes: [
            BrushStroke(radius: 0.05, hardness: 1, flow: 1, points: [MaskPoint(0.5, 0.1), MaskPoint(0.5, 0.9)])]))])
        l.scene = SceneDeltas(exposure: 2)
        let a = ask([l], source: src)!
        let pic = try await develop(f, wire: wired(wire(), a), ask: a)
        let cx = Int((0.5 - 0.05 * Double(W) / Double(W)) * Double(W))
        let url = outDir.appendingPathComponent("hard-edge-45MP-crop-256.png")
        png(pic, url, crop: CGRect(x: cx - 128, y: H / 2 - 128, width: 256, height: 256))
        // The rendered edge's width, in the picture's own green counts, along the middle row.
        let yy = H / 2
        let lo = pic.at(cx - 40, yy, 1), hi = pic.at(cx + 40, yy, 1)
        var c10 = Double.nan, c90 = Double.nan
        for x in (cx - 20)..<(cx + 20) {
            let a = (pic.at(x, yy, 1) - lo) / (hi - lo), b = (pic.at(x + 1, yy, 1) - lo) / (hi - lo)
            if c10.isNaN, (a - 0.1) * (b - 0.1) <= 0, a != b { c10 = Double(x) + (0.1 - a) / (b - a) }
            if c90.isNaN, (a - 0.9) * (b - 0.9) <= 0, a != b { c90 = Double(x) + (0.9 - a) / (b - a) }
        }
        print(String(format: "   rendered at 45 MP (full tier, flat grey 0.09, +2 stops): 10–90%% edge width %.2f px in the print's green; crop %@", c90 - c10, url.path))
    }

    // MARK: gate 1b: 色温 and 色调 against the decoder's, on a RAW

    /// CIE L*a*b* (D50) of linear ProPhoto.
    static func lab(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let xyz = SceneLayerWire.rgbToXYZ * rgb
        let wn = SIMD3(0.9642, 1.0, 0.8249)
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        let fx = f(xyz.x / wn.x), fy = f(xyz.y / wn.y), fz = f(xyz.z / wn.z)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// CIEDE2000.
    static func de2000(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let (L1, a1, b1, L2, a2, b2) = (a.x, a.y, a.z, b.x, b.y, b.z)
        let C1 = (a1 * a1 + b1 * b1).squareRoot(), C2 = (a2 * a2 + b2 * b2).squareRoot()
        let Cb = (C1 + C2) / 2, G = 0.5 * (1 - (pow(Cb, 7) / (pow(Cb, 7) + pow(25, 7))).squareRoot())
        let a1p = (1 + G) * a1, a2p = (1 + G) * a2
        let C1p = (a1p * a1p + b1 * b1).squareRoot(), C2p = (a2p * a2p + b2 * b2).squareRoot()
        func hp(_ x: Double, _ y: Double) -> Double { x == 0 && y == 0 ? 0 : { let h = atan2(y, x) * 180 / .pi; return h < 0 ? h + 360 : h }() }
        let h1 = hp(a1p, b1), h2 = hp(a2p, b2)
        let dL = L2 - L1, dC = C2p - C1p
        var dh = 0.0
        if C1p * C2p != 0 { dh = h2 - h1; if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 } }
        let dH = 2 * (C1p * C2p).squareRoot() * sin(dh * .pi / 360)
        let Lb = (L1 + L2) / 2, Cbp = (C1p + C2p) / 2
        var hb = h1 + h2
        if C1p * C2p != 0 { if abs(h1 - h2) > 180 { hb += h1 + h2 < 360 ? 360 : -360 }; hb /= 2 }
        let T = 1 - 0.17 * cos((hb - 30) * .pi / 180) + 0.24 * cos(2 * hb * .pi / 180) + 0.32 * cos((3 * hb + 6) * .pi / 180) - 0.20 * cos((4 * hb - 63) * .pi / 180)
        let dTheta = 30 * exp(-pow((hb - 275) / 25, 2))
        let Rc = 2 * (pow(Cbp, 7) / (pow(Cbp, 7) + pow(25, 7))).squareRoot()
        let Sl = 1 + 0.015 * pow(Lb - 50, 2) / (20 + pow(Lb - 50, 2)).squareRoot()
        let Sc = 1 + 0.045 * Cbp, Sh = 1 + 0.015 * Cbp * T
        let Rt = -sin(2 * dTheta * .pi / 180) * Rc
        return ((dL / Sl) * (dL / Sl) + (dC / Sc) * (dC / Sc) + (dH / Sh) * (dH / Sh) + Rt * (dC / Sc) * (dH / Sh)).squareRoot()
    }

    /// A frame's patches: the mean of each cell of a 8 x 6 grid, the cell's middle half, linear ProPhoto.
    static func patches(_ f: DecodedFrame) -> [SIMD3<Double>] {
        let w = f.size.width, h = f.size.height
        let p = f.buffer.contents().bindMemory(to: Float.self, capacity: w * h * 4)
        var out: [SIMD3<Double>] = []
        for gy in 0..<6 { for gx in 0..<8 {
            var s = SIMD3<Double>(0, 0, 0), n = 0.0
            for y in (h * (4 * gy + 1) / 24)..<(h * (4 * gy + 3) / 24) { for x in (w * (4 * gx + 1) / 32)..<(w * (4 * gx + 3) / 32) {
                let i = 4 * (y * w + x); s += SIMD3(Double(p[i]), Double(p[i + 1]), Double(p[i + 2])); n += 1
            } }
            out.append(s / n)
        } }
        return out
    }

    /// The layer's arithmetic on a patch at full coverage, in double (the host kernel's, `scene_layer_selftest`).
    static func filtered(_ rgb: SIMD3<Double>, _ d: SceneDeltas, a: Double, b: Double) -> SIMD3<Double> {
        let g = SceneLayerWire.logGain(d, a: a, b: b)
        let C = SceneLayerWire.m(SceneLayerWire.rgbToCone)
        return C.inverse * (SIMD3(exp(g.x), exp(g.y), exp(g.z)) * (C * rgb))
    }

    /// `tint-fit <raw>`: the decoder's Tint moved ±100 units and its Temperature ±100 mired from the file's own
    /// balance, against a full-mask layer of ν, τ = ±100 on the as-shot decode; `a` and `b` fitted to the least mean
    /// ΔE2000 over the grid's 48 patches; and the table at the values the app ships.
    static func tintFit(_ raw: URL) {
        let probe = CIRAWFilter(imageURL: raw)!
        let t0 = Double(probe.neutralTemperature), n0 = Double(probe.neutralTint)
        print(String(format: "== gate 1b: %@ as shot %.0f K, tint %+.1f; a 8 x 6 grid of the photograph's own patches, linear ProPhoto ==", raw.lastPathComponent, t0, n0))
        let asShot = patches(decode(raw, longEdge: 1200) { _ in })
        func decoder(dMired: Double = 0, dTint: Double = 0) -> [SIMD3<Double>] {
            patches(decode(raw, longEdge: 1200) { f in
                f.neutralTemperature = Float(1e6 / (1e6 / t0 - dMired))
                f.neutralTint = Float(n0 + dTint)
            })
        }
        var moved: [String: [SIMD3<Double>]] = [:]
        for v in [-100.0, -50, 50, 100] { moved["t\(v)"] = decoder(dMired: v) }
        for v in [-100.0, -50, 50, 100] { moved["n\(v)"] = decoder(dTint: v) }
        func meanDE(_ target: [SIMD3<Double>], _ d: SceneDeltas, a: Double, b: Double) -> (mean: Double, max: Double) {
            let des = zip(asShot, target).map { de2000(lab(filtered($0, d, a: a, b: b)), lab($1)) }
            return (des.reduce(0, +) / Double(des.count), des.max()!)
        }
        // Fit a over τ = ±50, ±100; b over ν = ±50, ±100 (each by a scan, then a finer scan).
        func fit(_ name: String, _ range: [Double], _ score: (Double) -> Double) -> Double {
            var best = range[0], bestScore = Double.infinity
            for v in range { let s = score(v); if s < bestScore { bestScore = s; best = v } }
            return best
        }
        let aFit = fit("a", stride(from: 0.3, through: 2.0, by: 0.02).map { $0 }) { a in
            [-100.0, -50, 50, 100].map { meanDE(moved["t\($0)"]!, SceneDeltas(temperature: $0), a: a, b: 0).mean }.reduce(0, +)
        }
        let bFit = fit("b", stride(from: 0.00002, through: 0.0015, by: 0.00001).map { $0 }) { b in
            [-100.0, -50, 50, 100].map { meanDE(moved["n\($0)"]!, SceneDeltas(tint: $0), a: aFit, b: b).mean }.reduce(0, +)
        }
        print(String(format: "   fitted: a = %.2f mired a unit, b = %.5f Duv a unit", aFit, bFit))
        print("   ΔE2000 (mean / max over 48 patches) of a full-mask layer against the decoder moved the same way:")
        for (label, a, b) in [("the fit", aFit, bFit), ("as shipped", SceneLayerWire.miredPerUnit, SceneLayerWire.duvPerUnit)] {
            var row = "     \(label) (a \(String(format: "%.2f", a)), b \(String(format: "%.5f", b))):"
            for v in [-100.0, -50, 50, 100] { let r = meanDE(moved["t\(v)"]!, SceneDeltas(temperature: v), a: a, b: b); row += String(format: "  色温 %+.0f %.2f / %.2f", v, r.mean, r.max) }
            for v in [-100.0, -50, 50, 100] { let r = meanDE(moved["n\(v)"]!, SceneDeltas(tint: v), a: a, b: b); row += String(format: "  色调 %+.0f %.2f / %.2f", v, r.mean, r.max) }
            print(row)
        }
        // For scale: how far the decoder's own move is from the as-shot decode.
        var scale = "     the decoder's own move from as shot:"
        for v in [-100.0, 100] { let des = zip(asShot, moved["t\(v)"]!).map { de2000(lab($0), lab($1)) }; scale += String(format: "  色温 %+.0f %.2f", v, des.reduce(0, +) / 48) }
        for v in [-100.0, 100] { let des = zip(asShot, moved["n\(v)"]!).map { de2000(lab($0), lab($1)) }; scale += String(format: "  色调 %+.0f %.2f", v, des.reduce(0, +) / 48) }
        print(scale)
    }

    // MARK: the purple weak region (trap 13): ±100 on a saturated chart, through the film

    /// The ColorChecker's 24 (sRGB, D65 encoded, as published by X-Rite 2005) and six saturated purples and blues,
    /// made linear ProPhoto (Bradford to D50), each a block of a 6 x 5 chart.
    static func chart() -> (frame: DecodedFrame, patches: [SIMD3<Double>], names: [String]) {
        let srgb: [(String, Double, Double, Double)] = [
            ("dark skin", 115, 82, 68), ("light skin", 194, 150, 130), ("blue sky", 98, 122, 157), ("foliage", 87, 108, 67),
            ("blue flower", 133, 128, 177), ("bluish green", 103, 189, 170), ("orange", 214, 126, 44), ("purplish blue", 80, 91, 166),
            ("moderate red", 193, 90, 99), ("purple", 94, 60, 108), ("yellow green", 157, 188, 64), ("orange yellow", 224, 163, 46),
            ("blue", 56, 61, 150), ("green", 70, 148, 73), ("red", 175, 54, 60), ("yellow", 231, 199, 31), ("magenta", 187, 86, 149),
            ("cyan", 8, 133, 161), ("white", 243, 243, 242), ("neutral 8", 200, 200, 200), ("neutral 6.5", 160, 160, 160),
            ("neutral 5", 122, 122, 121), ("neutral 3.5", 85, 85, 85), ("black", 52, 52, 52),
            ("violet", 120, 40, 200), ("deep purple", 90, 20, 140), ("ultramarine", 40, 30, 200), ("fuchsia", 200, 30, 180),
            ("indigo", 60, 20, 120), ("lavender", 150, 110, 220)]
        func lin(_ v: Double) -> Double { let c = v / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let toXYZ65 = SceneLayerWire.m([0.4124564, 0.3575761, 0.1804375, 0.2126729, 0.7151522, 0.0721750, 0.0193339, 0.1191920, 0.9503041])
        let brad = SceneLayerWire.m([1.0478112, 0.0228866, -0.0501270, 0.0295424, 0.9904844, -0.0170491, -0.0092345, 0.0150436, 0.7521316])
        let toPro = SceneLayerWire.rgbToXYZ.inverse * brad * toXYZ65
        let pts = srgb.map { toPro * SIMD3(lin($0.1), lin($0.2), lin($0.3)) }
        let cell = 100, W = 6 * cell, H = 5 * cell
        var f = [Float](repeating: 0, count: W * H * 3)
        for y in 0..<H { for x in 0..<W {
            let p = pts[(y / cell) * 6 + x / cell]
            for c in 0..<3 { f[3 * (y * W + x) + c] = Float(p[c]) }
        } }
        return (frame(f, W, H), pts, srgb.map(\.0))
    }

    static func chartRun() async throws {
        let (f, pts, names) = chart()
        let src = f.size
        print("== the purple weak region (trap 13): a full-mask layer's 色温 and 色调 on a saturated chart, through the film ==")
        // The chart's linear ProPhoto under the gain: does a colour leave the working gamut?
        for (label, d) in [("色温 +100", SceneDeltas(temperature: 100)), ("色温 -100", SceneDeltas(temperature: -100)),
                           ("色调 +100", SceneDeltas(tint: 100)), ("色调 -100", SceneDeltas(tint: -100))] {
            let out = pts.map { filtered($0, d, a: SceneLayerWire.miredPerUnit, b: SceneLayerWire.duvPerUnit) }
            let neg = zip(names, out).filter { $0.1.min() < 0 }.map { "\($0.0) (\(String(format: "%.4f", $0.1.min())))" }
            print("   \(label): patches with a negative ProPhoto component after the gain: \(neg.isEmpty ? "none" : neg.joined(separator: ", "))")
        }
        // Through the film: each patch's output at τ (or ν) = 0, 25, 50, 75, 100, as CIELAB of the print (sRGB out).
        func centre(_ p: Picture, _ k: Int) -> SIMD3<Double> {
            let cx = (k % 6) * p.w / 6 + p.w / 12, cy = (k / 6) * p.h / 5 + p.h / 10
            var s = SIMD3<Double>(0, 0, 0)
            for y in (cy - 10)..<(cy + 10) { for x in (cx - 10)..<(cx + 10) { s += SIMD3(p.at(x, y, 0), p.at(x, y, 1), p.at(x, y, 2)) } }
            return s / 400 / 65535
        }
        func printLab(_ s: SIMD3<Double>) -> SIMD3<Double> {
            func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            let l = SIMD3(lin(s.x), lin(s.y), lin(s.z))
            let toXYZ65 = SceneLayerWire.m([0.4124564, 0.3575761, 0.1804375, 0.2126729, 0.7151522, 0.0721750, 0.0193339, 0.1191920, 0.9503041])
            let brad = SceneLayerWire.m([1.0478112, 0.0228866, -0.0501270, 0.0295424, 0.9904844, -0.0170491, -0.0092345, 0.0150436, 0.7521316])
            return lab(SceneLayerWire.rgbToXYZ.inverse * brad * toXYZ65 * l)
        }
        for (label, make) in [("色温", { (v: Double) in SceneDeltas(temperature: v) }), ("色调", { (v: Double) in SceneDeltas(tint: v) })] {
            for sign in [1.0, -1.0] {
                var steps: [[SIMD3<Double>]] = []
                for v in [0.0, 25, 50, 75, 100] {
                    let a = v == 0 ? nil : ask([fullLayer().with { $0.scene = make(sign * v) }], source: src)
                    let pic = try await develop(f, wire: wired(wire(), a), ask: a)
                    steps.append((0..<pts.count).map { printLab(centre(pic, $0)) })
                }
                // Per patch: ΔE2000 of each 25-unit step; the last step over the first is the question (a blow-up).
                var worst: [(String, Double, Double, Double)] = []
                for k in 0..<pts.count {
                    let d = (0..<4).map { de2000(steps[$0][k], steps[$0 + 1][k]) }
                    worst.append((names[k], d[0], d[3], d[3] / max(d[0], 1e-6)))
                }
                worst.sort { $0.3 > $1.3 }
                let total = (0..<pts.count).map { de2000(steps[0][$0], steps[4][$0]) }
                print(String(format: "   %@ %+.0f through the film: ΔE2000 0→100 mean %.2f, max %.2f (%@); the steps 0→25 against 75→100, most uneven: %@",
                             label, sign * 100, total.reduce(0, +) / Double(total.count), total.max()!, names[total.firstIndex(of: total.max()!)!],
                             worst.prefix(4).map { String(format: "%@ %.2f→%.2f (×%.1f)", $0.0, $0.1, $0.2, $0.3) }.joined(separator: ", ")))
            }
        }
    }

    // MARK: main

    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else { print("usage: scene_layers_drive <resources> gate1|gate2|gate4|refusal|cost <case>|stroke|gate10 <photo> <dir>|edge <dir>|tint-fit <raw>|chart"); exit(2) }
        engine = try SpkEngine(resources: args[0], device: device, source: source)
        let t = now()
        switch args[1] {
        case "gate1": try await gate1()
        case "gate2": try await gate2()
        case "gate4": try await gate4()
        case "refusal": try await refusal()
        case "cost": try await cost(args[2])
        case "stroke": try await stroke()
        case "gate10": try await gate10(URL(fileURLWithPath: args[2]), URL(fileURLWithPath: args[3]))
        case "edge": try await edge(URL(fileURLWithPath: args[2]))
        case "tint-fit": tintFit(URL(fileURLWithPath: args[2]))
        case "chart": try await chartRun()
        default: print("unknown \(args[1])"); exit(2)
        }
        print(String(format: "(%@: %.1f s)", args[1], ms(t) / 1000))
    }
}

extension LocalLayer {
    func with(_ f: (inout LocalLayer) -> Void) -> LocalLayer { var l = self; f(&l); return l }
}

