// lens_resolution_selftest.swift — 镜头校正 as a frame's edit (DecodeSettings' lens fields) and who corrects it
// (LensResolver, LensResolution, CoreImageVerdicts). Part of tools/lens_profile_selftest.sh's binary.
//
// Always: the fields at rest are the JSON 2.3 wrote, byte for byte, and every key made from them is what it was; each
// field written alone, read back; each one moves the key exactly where it is live; the geometry's word leaves the
// light falloff out; the meters' keys at rest are what they were; the synthetic "Core Image supports the lens and
// changes nothing" (a Canon EOS R6 Mark II with the RF 45mm F1.2 STM, the user's report — no such file is here: the
// verdict is injected) resolves past Core Image to the database's exact EXIF match.
//
// With the samples: automatic's answer for every file (a table: file, camera, lens, who corrects, why, Core Image's
// measured difference and the verdict's cost); a ProRAW gets nothing and no recommendation; 畸变 at 0 is the
// uncorrected decode bit for bit, at 100 the whole correction, at 50 between them (half the displacement); a chosen
// database lens on a Core Image camera turns Core Image's off and is the app's step; the engine's and Apple's decodes
// of a Nikon and a Canon frame, resolved, are bit-identical to 2.3's; and 光衰减 on the wide-open samples.

import CoreImage
import Foundation
import ImageIO

extension LensProfileSelftest {
    // MARK: - the fields

    /// 2.3's decode, as its synthesised encoding wrote it.
    struct Decode23: Codable {
        var whiteBalance: DecodeSettings.WhiteBalance
        var temperature: Double
        var tint: Double
        var lensCorrection: Bool
        var rawExposureTreatment: DecodeSettings.RawExposureTreatment
    }

    static func modelCases() {
        let enc = JSONEncoder()
        func json<T: Encodable>(_ v: T, sorted: Bool = false) -> String {
            enc.outputFormatting = sorted ? [.sortedKeys] : []
            return (try? enc.encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
        }
        var on = DecodeSettings(); on.lensCorrection = true; on.whiteBalance = .custom; on.temperature = 4321; on.tint = 7
        for d in [DecodeSettings(), on] {
            let old = Decode23(whiteBalance: d.whiteBalance, temperature: d.temperature, tint: d.tint, lensCorrection: d.lensCorrection,
                               rawExposureTreatment: d.rawExposureTreatment)
            // Key order is the encoder's (unsorted, it is a hash's): byte for byte where it is sorted, as the library writes.
            expect(json(d, sorted: true) == json(old, sorted: true), "a decode at rest is 2.3's JSON byte for byte (\(json(d, sorted: true)))")
        }
        var edit = FrameEdit(); edit.decode = on
        let e1 = json(edit)
        expect(!e1.contains("lensProfile") && !e1.contains("lensDistortion") && !e1.contains("lensLightFalloff") && !e1.contains("lensHide"),
               "an edit at rest names none of the lens's new fields")
        // Each written alone, read back.
        let pick = DecodeSettings.LensPick(key: "Canon/Canon RF 45mm F1.2 STM", name: "Canon RF 45mm F1.2 STM")
        let moves: [(String, (inout DecodeSettings) -> Void)] = [
            ("lensProfile", { $0.lensProfile = pick }), ("lensDistortion", { $0.lensDistortion = 50 }),
            ("lensLightFalloff", { $0.lensLightFalloff = 40 }), ("lensHideDistortedAreas", { $0.lensHideDistortedAreas = false }),
        ]
        for (name, move) in moves {
            var d = on; move(&d)
            let s = json(d, sorted: true)
            let back = try? JSONDecoder().decode(DecodeSettings.self, from: Data(s.utf8))
            let keys = (try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]).map { Set($0.keys) } ?? []
            let five: Set<String> = ["whiteBalance", "temperature", "tint", "lensCorrection", "rawExposureTreatment"]
            expect(keys == five.union([name]) && back == d, "\(name) is written alone, beside 2.3's five, and reads back (\(s))")
        }
        let old = try? JSONDecoder().decode(DecodeSettings.self, from: Data(json(Decode23(whiteBalance: .asShot, temperature: 5500, tint: 0,
                                                                                               lensCorrection: true, rawExposureTreatment: .sourceReference)).utf8))
        expect(old?.lensProfile == nil && old?.lensDistortion == 100 && old?.lensLightFalloff == 0 && old?.lensHideDistortedAreas == true,
               "a 2.3 decode reads with the lens's defaults")

        // The keys at rest: what they were.
        let nef = URL(fileURLWithPath: "/nowhere/DSC0001.NEF"), arw = URL(fileURLWithPath: "/nowhere/DSC0001.ARW")
        LensResolver.forgetAll()
        expect(on.pixelsKey(source: nef) == on.pixelsKey && on.pixelsKey(source: arw) == on.pixelsKey + "|lens=sony-embedded.1",
               "the keys at rest are 2.4.0's first stage's")
        // Each field moves the key where it is live, and nowhere else.
        func key(_ url: URL, _ move: (inout DecodeSettings) -> Void) -> String { var d = on; move(&d); return d.pixelsKey(source: url) }
        let sonyD = key(arw) { $0.lensDistortion = 50 }, sonyH = key(arw) { $0.lensHideDistortedAreas = false }
        let sonyV = key(arw) { $0.lensLightFalloff = 40 }
        expect(sonyD == on.pixelsKey(source: arw) + ",d=50" && sonyH == on.pixelsKey(source: arw) + ",hide=0",
               "where the app corrects (a Sony's own), 畸变 and 隐藏畸变区域 move the key (\(sonyD), \(sonyH))")
        expect(sonyV == on.pixelsKey(source: arw), "the file's own profile has no light falloff to move: its key does not")
        expect(key(nef) { $0.lensDistortion = 50; $0.lensLightFalloff = 40; $0.lensHideDistortedAreas = false } == on.pixelsKey(source: nef),
               "where Core Image corrects, no amount moves the key (it is all or nothing)")
        // A database lens: kept as its query would make it, a vignette with it.
        let profile = LensProfile(source: .file, distortion: .init(radii: [0, 1], values: [1, 1.02]), vignetting: .init(radii: [0, 1], values: [1, 2]))
        LensResolver.keep(.init(corrector: .database, why: .chosen, profile: profile, lens: .init(key: pick.key, maker: "Canon", name: pick.name, rectilinear: true),
                                source: "file.1:X@0123456789abcdef", lightFalloffAvailable: true, settled: true), for: nef, pick: pick)
        var db = on; db.lensProfile = pick
        let dbKey = db.pixelsKey(source: nef)
        db.lensLightFalloff = 40
        let r = LensResolver.current(nef, decode: db)
        expect(dbKey == on.pixelsKey + "|lens=file.1:X@0123456789abcdef" && db.pixelsKey(source: nef) == dbKey + ",v=40",
               "a database lens is its word, its light falloff added (\(db.pixelsKey(source: nef)))")
        expect(r.geometryWord == "|lens=file.1:X@0123456789abcdef" && r.adjustsLightFalloff && r.adjustsDistortion,
               "the geometry's word leaves the light falloff out; both are live for a database lens with a vignette")
        expect(MaskMadeOn(lensCorrection: true, lensWord: r.geometryWord).matches(lensCorrection: true, lensWord: LensResolver.current(nef, decode: { var x = db; x.lensLightFalloff = 80; return x }()).geometryWord),
               "a mask is not marked by a light falloff's move")
        expect(!MaskMadeOn(lensCorrection: true, lensWord: r.geometryWord).matches(lensCorrection: true, lensWord: LensResolver.current(nef, decode: { var x = db; x.lensDistortion = 30; return x }()).geometryWord),
               "a mask is marked by a distortion's")
        let amounts = { (d: DecodeSettings) in LensResolver.current(nef, decode: d).amounts }
        expect(amounts(db).vignetting == 0.4 && amounts({ var x = db; x.lensLightFalloff = 0; return x }()).vignetting == 0
               && LensResolution.step(profile, amounts({ var x = db; x.lensLightFalloff = 0; x.lensDistortion = 0; return x }())) == nil,
               "光衰减 0 (the default) applies no gain; 畸变 0 with it leaves no step to install")
        LensResolver.forgetAll()

        // The meters' keys: at rest what they were; a field moved, another key.
        var hole = HalfFramePair.Hole(path: "DSC0001.NEF", frame: nil); hole.decode = on
        let k0 = HalfFramePair.meterKey(hole: hole, method: "m")
        expect(k0.contains("|true|m|"), "a pair's meter key at rest is 2.3's (\(k0))")
        hole.decode.lensDistortion = 50
        expect(HalfFramePair.meterKey(hole: hole, method: "m") != k0, "a lens field moved re-meters a hole")
        hole.path = "DSC0001.ARW"; hole.decode.lensDistortion = 100
        expect(HalfFramePair.meterKey(hole: hole, method: "m").contains("|lens=sony-embedded.1"), "a Sony hole's reading is of the corrected picture")

        // History: the fields are named (the history label selftest walks every field; here, the label's key).
        expect(FrameEdit().resetting(.decode, asShot: DecodeSettings()).decode.lensFields == FrameEdit().decode.lensFields,
               "a reset of the white balance keeps the lens's fields")
        var lensEdit = FrameEdit(); lensEdit.decode = db
        expect(lensEdit.resetting(.decode, asShot: DecodeSettings()).decode.lensFields == db.lensFields, "… whatever they are")
    }

    // MARK: - the synthetic report: supported, and nothing changes

    static func reportCase(_ adobe: LensDatabase?) {
        guard let adobe else { return print("SKIPPED: no Adobe lens database — the R6 Mark II case did not run") }
        LensResolver.configure(database: adobe, verdicts: scratch.appendingPathComponent("verdicts.json"))
        let r6 = LensDatabase.Frame(make: "Canon", model: "Canon EOS R6m2", lens: "RF45mm F1.2 STM", focal: 45, focal35: 45, fNumber: 1.2,
                                    width: 6000, height: 4000)
        let fake = URL(fileURLWithPath: "/nowhere/R6m2_0001.CR3")
        // The verdict as the user's report has it: Core Image says it supports the lens, and its picture does not move.
        CoreImageVerdicts.record(.init(supported: true, corrects: false, difference: 0), for: r6)
        let base = waitFor { await LensResolver.automatic(fake, frame: r6, measure: false) }
        print("\nthe user's report, injected — \(r6.model) + \(r6.lens): \(base.corrector.rawValue), \(base.lens?.name ?? "no lens") (\(base.why.text))")
        expect(base.corrector == .database && base.lens?.key == "Canon/Canon RF 45mm F1.2 STM" && base.why == .exif,
               "Core Image supports the R6 Mark II's RF 45mm F1.2 STM and changes nothing: resolved to the database's exact EXIF match")
        CoreImageVerdicts.record(.init(supported: true, corrects: true, difference: 0.3), for: r6)
        let ci = waitFor { await LensResolver.automatic(fake, frame: r6, measure: false) }
        expect(ci.corrector == .coreImage, "the same lens, where Core Image's picture moves: Core Image")
        // Kept by camera, lens and focal: written to the file and read back.
        CoreImageVerdicts.load(from: scratch.appendingPathComponent("verdicts.json"))
        expect(CoreImageVerdicts.lookup(r6)?.corrects == true, "a verdict is kept in its file, for this system")
    }

    static func waitFor<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        let box = Locked<T?>(nil)
        Task.detached { let v = await body(); box.withLock { $0 = v }; done.signal() }
        done.wait()
        return box.withLock { $0! }
    }

    // MARK: - the samples

    static func resolutionSamples(_ root: URL, adobe: LensDatabase?) {
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { rawExtensions.contains($0.pathExtension.lowercased()) && !$0.path.contains("/_") }
            .sorted { $0.path < $1.path }
        LensResolver.configure(database: adobe, verdicts: scratch.appendingPathComponent("sample-verdicts.json"))
        let on = { var d = DecodeSettings(); d.lensCorrection = true; return d }()
        func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count) }
        print("\nautomatic, resolved (Core Image measured once a camera, lens and focal length; the database \(adobe == nil ? "absent" : "Adobe's"))")
        print(pad("file", 16) + pad("camera", 22) + pad("lens", 30) + pad("who corrects", 13) + pad("Core Image", 18) + "why")
        var costs: [Double] = []
        var nikon: URL?, canon: URL?
        for url in files {
            let f = LensResolver.facts(url)
            let t = Date()
            let r = waitFor { await LensResolver.resolve(url, decode: on) }
            let ms = Date().timeIntervalSince(t) * 1000
            let v = CoreImageVerdicts.lookup(f)
            if v?.supported == true { costs.append(ms) }
            let ci = v.map { $0.supported ? String(format: "%.3f, %.0f ms", $0.difference, ms) : "unsupported" } ?? "—"
            print(pad(url.lastPathComponent, 16) + pad(f.model, 22) + pad(f.lens.isEmpty ? "(none)" : f.lens, 30)
                  + pad(r.corrector.rawValue + (r.lens.map { " " + $0.name } ?? ""), 13) + pad(ci, 18) + r.why.text + (r.lens.map { ": " + $0.name } ?? ""))
            expect(r.settled, "\(url.lastPathComponent): resolved")
            let ext = url.pathExtension.lowercased()
            if ["nef", "cr3", "raf", "rw2"].contains(ext) { expect(r.corrector == .coreImage, "\(url.lastPathComponent): Core Image really corrects it") }
            if ext == "arw" { expect(r.corrector == .embedded, "\(url.lastPathComponent): the file's own parameters") }
            if ext == "nef", nikon == nil { nikon = url }
            if ext == "cr3", canon == nil { canon = url }
            if f.make.lowercased().hasPrefix("apple") {
                let recs = waitFor { await LensResolver.recommended(for: url) }
                expect(r.corrector == .nobody && r.why == .alreadyCorrected && recs.isEmpty, "\(url.lastPathComponent): a ProRAW gets nothing and no recommendation")
            }
            if f.model.contains("Q3") { expect(r.corrector == .coreImage, "\(url.lastPathComponent): Core Image corrects the Q3's DNG") }
        }
        costs = costs.filter { $0 > 5 }
        if !costs.isEmpty {
            print(String(format: "  a verdict (two draft decodes, 1/8 scale) cost %.0f–%.0f ms here, once a camera, lens and focal length; the answers kept after",
                         costs.min()!, costs.max()!))
        }
        // Asked again: kept, no decode.
        if let first = files.first {
            let t = Date()
            _ = waitFor { await LensResolver.resolve(first, decode: on) }
            let ms = Date().timeIntervalSince(t) * 1000
            print(String(format: "  resolved again: %.2f ms", ms))
            expect(ms < 50, "a resolved frame is kept")
        }
        // The engine's and Apple's decodes of a Nikon and a Canon, resolved: bit-identical to 2.3's.
        for url in [nikon, canon].compactMap({ $0 }) { identityCase(url) }
        distortionCase(files.first { $0.lastPathComponent == "9218571104.arw" } ?? files.first { $0.pathExtension.lowercased() == "arw" })
        if let adobe, let canon { chosenCase(canon, adobe) }
        if let adobe { falloffCases(files, adobe) }
        LensResolver.configure(database: nil)
    }

    /// 畸变 0, 50, 100 on a Sony frame (the app corrects it from its own parameters).
    static func distortionCase(_ url: URL?) {
        guard let url else { return print("SKIPPED: no Sony sample for the distortion amounts") }
        var on = DecodeSettings(); on.lensCorrection = true
        func decode(_ d: Double, hide: Bool = true) -> CIImage? { var s = on; s.lensDistortion = d; s.lensHideDistortedAreas = hide; return RawExposure.prepare(url, settings: s, longEdge: 3000)?.image }
        guard let d0 = decode(0), let d50 = decode(50, hide: false), let d100 = decode(100, hide: false),
              let off = RawExposure.prepare(url, settings: DecodeSettings(), longEdge: 3000)?.image, let full = decode(100) else {
            return expect(false, "\(url.lastPathComponent): the amounts decode")
        }
        expect(Oracle.bytes(d0) == Oracle.bytes(off), "\(url.lastPathComponent): 畸变 0 is the uncorrected decode, bit for bit")
        var whole = on; whole.lensDistortion = 100
        expect(Oracle.bytes(full) == Oracle.bytes(RawExposure.prepare(url, settings: on, longEdge: 3000)!.image), "… 畸变 100 is the whole correction")
        // The displacement against the uncorrected decode, a similarity removed, ring by ring (median): at 50 about half
        // of 100's in every ring that moves.
        let w = 3000
        let u = Oracle.render(off, width: w, space: Oracle.srgb).luma
        let a = Oracle.binned(Oracle.residuals(u, Oracle.render(d50, width: w, space: Oracle.srgb).luma))
        let b = Oracle.binned(Oracle.residuals(u, Oracle.render(d100, width: w, space: Oracle.srgb).luma))
        print("\n\(url.lastPathComponent) — 畸变 (hide off, a scale and shift removed): 0 is the uncorrected decode bit for bit; 50 and 100, px a ring:")
        var ratios: [Double] = []
        for (ra, rb) in zip(a, b) where ra.0 == rb.0 {
            print(String(format: "    %.2f   50: %+6.2f px   100: %+6.2f px", ra.0, ra.1, rb.1))
            if abs(rb.1) > 1 { ratios.append(ra.1 / rb.1) }
        }
        print("  ratio 50/100 where 100 moves over 1 px: " + ratios.map { String(format: "%.2f", $0) }.joined(separator: " "))
        expect(ratios.count >= 2 && ratios.allSatisfy { $0 > 0.35 && $0 < 0.65 }, "\(url.lastPathComponent): 畸变 50 is between 0 and 100, about half, and in the same direction")
    }

    /// A chosen database lens on a Core Image camera: Core Image's own off, the app's step on, in both decodes.
    static func chosenCase(_ url: URL, _ adobe: LensDatabase) {
        let f = LensResolver.facts(url)
        guard let rec = waitFor({ (try? await adobe.recommended(for: f)) ?? [] }).first else {
            return print("SKIPPED: \(url.lastPathComponent): the database recommends no lens for \(f.lens)")
        }
        var d = DecodeSettings(); d.lensCorrection = true; d.lensProfile = .init(key: rec.lens.key, name: rec.lens.name)
        let r = LensResolver.current(url, decode: d)
        guard r.corrector == .database, let profile = r.base.profile, let step = LensResolution.step(profile, r.amounts),
              let now = RawExposure.prepare(url, settings: d, longEdge: 1600)?.image,
              let auto = RawExposure.prepare(url, settings: { var x = d; x.lensProfile = nil; return x }(), longEdge: 1600)?.image else {
            return expect(false, "\(url.lastPathComponent): a chosen \(rec.lens.name) resolves (\(r.corrector.rawValue))")
        }
        let filter = CIRAWFilter(imageURL: url)!
        let b0 = filter.baselineExposure
        filter.baselineExposure = b0; filter.exposure = Float(d.rawExposureTreatment.sourceOffsetEV); filter.shadowBias = 0
        filter.boostAmount = 0; filter.boostShadowAmount = 0; filter.isGamutMappingEnabled = false; filter.localToneMapAmount = 0
        filter.extendedDynamicRangeAmount = 0
        filter.isLensCorrectionEnabled = false
        let s = LensProfileFilter(); s.profile = step; s.distortionAmount = 1; s.vignettingAmount = 0; s.chromaticAberration = false
        filter.linearSpaceFilter = s
        let byHand = RawExposure.scaled(filter.outputImage!, toLongEdge: 1600)
        let same = Oracle.bytes(now) == Oracle.bytes(byHand), moved = Oracle.bytes(now) != Oracle.bytes(auto)
        print("\n\(url.lastPathComponent) with \(rec.lens.name) chosen (\(rec.match)): the decode \(same ? "is" : "is NOT") Core Image's off + the app's step; \(moved ? "another picture than" : "the SAME as") Core Image's own")
        expect(same && moved, "\(url.lastPathComponent): a chosen database lens switches Core Image's off and applies the app's")
        expect(d.pixelsKey(source: url) != { var x = d; x.lensProfile = nil; return x }().pixelsKey(source: url), "… and keys another picture")
        let falloff = { var x = d; x.lensLightFalloff = 60; return x }()
        expect(!r.adjustsLightFalloff && falloff.pixelsKey(source: url) == d.pixelsKey(source: url),
               "… its 光衰减 is not live in this build (Adobe's gain unverified): the amount moves nothing")
    }

    // MARK: - 光衰减

    /// Adobe's vignette model on the wide-open samples (a database lens chosen for each): the gain at least 1, rising
    /// with the radius, and the radial luminance of the frame's plain (untextured) patches flatter with it than without.
    static func falloffCases(_ files: [URL], _ adobe: LensDatabase) {
        print("\n光衰减 — Adobe's vignette model on the wide-open samples (plain patches: 32 px at 1500 wide, local contrast under 4 %)")
        var verdicts: [Bool] = []
        for url in files {
            let f = LensResolver.facts(url)
            guard let fn = f.fNumber, let lensMax = LensDatabase.optics(f.lens)?.f, abs(fn - lensMax) < 0.15 else { continue }
            guard let rec = waitFor({ (try? await adobe.recommended(for: f)) ?? [] }).first(where: { $0.match == .exif || $0.match == .name }),
                  let made = waitFor({ try? await adobe.profile(lens: rec.lens.key, for: f, terms: LCP.Terms(vignetting: true)) }),
                  let vig = made.profile.vignetting else { continue }
            let radii = stride(from: 0.0, through: 1.0, by: 0.05).map { $0 }
            let gains = radii.map { made.profile.evaluate($0, distortion: 0, vignetting: 1, chromaticAberration: false).gain }
            let atLeastOne = gains.allSatisfy { $0 >= 0.999 }, rising = zip(gains, gains.dropFirst()).allSatisfy { $1 >= $0 - 1e-6 }
            let lowest = gains.min() ?? .nan
            _ = vig
            // The frame decoded without and with the gain (no distortion), luminance at 1500 wide.
            var d = DecodeSettings(); d.lensCorrection = true; d.lensProfile = .init(key: rec.lens.key, name: rec.lens.name)
            d.lensDistortion = 0; d.lensLightFalloff = 100
            // Adobe's gain as the app's step would apply it, whatever the build's gate (`LensResolver.lightFalloffVerified`).
            let measured = LensResolution(base: .init(corrector: .database, why: .chosen, profile: made.profile, lens: made.lens, source: made.word,
                                                      lightFalloffAvailable: true, settled: true), decode: d)
            guard let a = RawExposure.prepare(url, settings: DecodeSettings(), longEdge: 1500)?.image,
                  let b = RawExposure.prepare(url, settings: d, longEdge: 1500, lens: measured)?.image else { continue }
            let un = Oracle.render(a, width: 1500, space: Oracle.linear).luma, co = Oracle.render(b, width: 1500, space: Oracle.linear).luma
            let (rings, slopeU, slopeC) = plainRings(un, co)
            print(String(format: "  %@ — %@ at f/%.1f, %@: gain %.3f at r 0, %.2f at 0.5, %.2f at 0.9, lowest %.4f (≥ 1 %@, rising %@); plain patches %d; their log2 luminance against r², slope: without %+.2f, with %+.2f stop",
                         url.lastPathComponent, f.lens, fn, made.lens.name, gains[0], gains[10], gains[18], lowest, atLeastOne ? "yes" : "NO",
                         rising ? "yes" : "NO", rings, slopeU, slopeC))
            // Flattened: at least 12 plain patches, a falloff to correct, and at most half of it left, of the same sign.
            let flatter = rings >= 12 && slopeU < -0.1 && slopeC <= 0.5 * abs(slopeU) && slopeC >= -0.5 * abs(slopeU)
            verdicts.append(atLeastOne && rising && flatter)
        }
        LensResolver.forgetAll()
        let shown = verdicts.filter { $0 }.count
        print("  → \(shown) of \(verdicts.count) wide-open samples show it (bar: two). 光衰减 is \(LensResolver.lightFalloffVerified ? "AVAILABLE" : "unavailable") in this build.")
        expect(LensResolver.lightFalloffVerified == (shown >= 2), "光衰减 is available exactly where two wide-open samples verify Adobe's gain")
    }

    /// The plain patches (32 × 32, local contrast under 4 % in the uncorrected) of a frame, their luminance's log2 fitted
    /// against r² (a vignette's leading term): the patch count and the slope, without and with the correction.
    static func plainRings(_ u: Oracle.Plane, _ c: Oracle.Plane) -> (Int, Double, Double) {
        let p = 32, cx = Double(u.w) / 2, cy = Double(u.h) / 2, R = hypot(cx, cy)
        var xs: [Double] = [], yu: [Double] = [], yc: [Double] = []
        var y = 0
        while y + p <= u.h {
            var x = 0
            while x + p <= u.w {
                var s = 0.0, s2 = 0.0, t = 0.0
                for j in y..<(y + p) { for i in x..<(x + p) { let v = Double(u[i, j]); s += v; s2 += v * v; t += Double(c[i, j]) } }
                let n = Double(p * p), m = s / n, sd = (max(s2 / n - m * m, 0)).squareRoot()
                if m > 0.01, m < 0.8, sd / m < 0.04 {
                    let r = hypot(Double(x + p / 2) - cx, Double(y + p / 2) - cy) / R
                    xs.append(r * r); yu.append(log2(m)); yc.append(log2(t / n))
                }
                x += p
            }
            y += p
        }
        func slope(_ ys: [Double]) -> Double {
            guard xs.count >= 2 else { return .nan }
            let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
            let sxy = zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0, +), sxx = xs.map { ($0 - mx) * ($0 - mx) }.reduce(0, +)
            return sxx > 0 ? sxy / sxx : .nan
        }
        return (xs.count, slope(yu), slope(yc))
    }
}
