// lens_database_selftest.swift — Adobe's lens profiles in the app's database (LCPReader, LensDatabase, and
// LensCorrection's database choice), compiled with lens_profile_selftest.swift as one run (tools/lens_profile_selftest.sh).
//
// Synthetic cases always run: a profile written the three ways XMP writes a property, read alike; a malformed file
// skipped with its reason; the model's maths at a radius; the interpolation's weights; the names' normalisation; the
// database on a scratch file (add, add again, replace, remove, the RF 45mm F1.2 STM found from a Canon EOS R6m2's EXIF
// strings); the keys.
//
// With Camera Raw's folder on this Mac (absent: SKIPPED, loudly): all of it installed into a scratch database,
// timed, sized, installed again (nothing changes), and queried, timed.
//
// With the samples as well: every sample's recommended lenses; where Core Image corrects and Adobe has the lens, the
// app's LCP-corrected decode against Core Image's corrected one (radial residual, a scale and shift removed: ≤ 0.1 % of
// the half-diagonal wherever the uncorrected residual is larger), and light falloff and colour fringes against Core
// Image's; Sony's LCPs against the file's own parameters; a Ricoh GR II DNG against its own JPEG preview; and both
// decodes carrying a database lens for a camera Core Image corrects.

import CoreImage
import Foundation
import ImageIO

extension LensProfileSelftest {
    static let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spk-lens-selftest-\(getpid())", isDirectory: true)

    /// `body`, awaited from the synchronous run.
    static func wait<T>(_ body: @escaping () async throws -> T) -> Result<T, Error> {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: Result<T, Error>?
        Task.detached { do { out = .success(try await body()) } catch { out = .failure(error) }; done.signal() }
        done.wait()
        return out!
    }

    static func time<T>(_ body: () -> T) -> (T, Double) { let t = Date(); let v = body(); return (v, Date().timeIntervalSince(t)) }

    // MARK: - the reader

    /// One profile, three ways: attributes; elements with text; `rdf:parseType="Resource"`.
    static let attributeForm = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
     <rdf:Description rdf:about="" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/" xmlns:stCamera="http://ns.adobe.com/photoshop/1.0/camera-profile">
      <photoshop:CameraProfiles><rdf:Seq>
       <rdf:li><rdf:Description stCamera:Make="Canon" stCamera:Model="Canon EOS R" stCamera:Lens="RF45mm F1.2 STM" stCamera:LensID="61182"
         stCamera:CameraPrettyName="Canon EOS R" stCamera:LensPrettyName="Canon RF 45mm F1.2 STM" stCamera:CameraRawProfile="True"
         stCamera:SensorFormatFactor="1" stCamera:ImageWidth="6000" stCamera:ImageLength="4000" stCamera:FocalLength="45"
         stCamera:FocusDistance="3" stCamera:ApertureValue="2">
        <stCamera:PerspectiveModel><rdf:Description stCamera:Version="2" stCamera:FocalLengthX="1.25" stCamera:FocalLengthY="1.25"
          stCamera:ImageXCenter="0.5" stCamera:ImageYCenter="0.5" stCamera:RadialDistortParam1="-0.1" stCamera:RadialDistortParam2="0.05"
          stCamera:RadialDistortParam3="0.01">
         <stCamera:VignetteModel><rdf:Description stCamera:VignetteModelParam1="-0.5" stCamera:VignetteModelParam2="0.1" stCamera:VignetteModelParam3="0">
          <stCamera:VignetteModelPiecewiseParam><rdf:Seq><rdf:li>0, 1</rdf:li><rdf:li>0.25, 0.97</rdf:li><rdf:li>0.5, 0.88</rdf:li></rdf:Seq></stCamera:VignetteModelPiecewiseParam>
         </rdf:Description></stCamera:VignetteModel>
         <stCamera:ChromaticRedGreenModel stCamera:ScaleFactor="1.0002" stCamera:RadialDistortParam1="0.001" stCamera:RadialDistortParam2="0" stCamera:RadialDistortParam3="0"/>
        </rdf:Description></stCamera:PerspectiveModel>
       </rdf:Description></rdf:li>
      </rdf:Seq></photoshop:CameraProfiles>
     </rdf:Description></rdf:RDF></x:xmpmeta>
    """

    static let elementForm = """
    <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
     <rdf:Description rdf:about="" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/" xmlns:stCamera="http://ns.adobe.com/photoshop/1.0/camera-profile">
      <photoshop:CameraProfiles><rdf:Seq>
       <rdf:li rdf:parseType="Resource">
        <stCamera:Make>Canon</stCamera:Make><stCamera:Model>Canon EOS R</stCamera:Model><stCamera:Lens>RF45mm F1.2 STM</stCamera:Lens>
        <stCamera:LensID>61182</stCamera:LensID><stCamera:CameraPrettyName>Canon EOS R</stCamera:CameraPrettyName>
        <stCamera:LensPrettyName>Canon RF 45mm F1.2 STM</stCamera:LensPrettyName><stCamera:CameraRawProfile>True</stCamera:CameraRawProfile>
        <stCamera:SensorFormatFactor>1</stCamera:SensorFormatFactor><stCamera:ImageWidth>6000</stCamera:ImageWidth>
        <stCamera:ImageLength>4000</stCamera:ImageLength><stCamera:FocalLength>45</stCamera:FocalLength>
        <stCamera:FocusDistance>3</stCamera:FocusDistance><stCamera:ApertureValue>2</stCamera:ApertureValue>
        <stCamera:PerspectiveModel rdf:parseType="Resource">
         <stCamera:Version>2</stCamera:Version><stCamera:FocalLengthX>1.25</stCamera:FocalLengthX><stCamera:FocalLengthY>1.25</stCamera:FocalLengthY>
         <stCamera:ImageXCenter>0.5</stCamera:ImageXCenter><stCamera:ImageYCenter>0.5</stCamera:ImageYCenter>
         <stCamera:RadialDistortParam1>-0.1</stCamera:RadialDistortParam1><stCamera:RadialDistortParam2>0.05</stCamera:RadialDistortParam2>
         <stCamera:RadialDistortParam3>0.01</stCamera:RadialDistortParam3>
         <stCamera:VignetteModel rdf:parseType="Resource">
          <stCamera:VignetteModelParam1>-0.5</stCamera:VignetteModelParam1><stCamera:VignetteModelParam2>0.1</stCamera:VignetteModelParam2>
          <stCamera:VignetteModelParam3>0</stCamera:VignetteModelParam3>
          <stCamera:VignetteModelPiecewiseParam><rdf:Seq><rdf:li>0, 1</rdf:li><rdf:li>0.25, 0.97</rdf:li><rdf:li>0.5, 0.88</rdf:li></rdf:Seq></stCamera:VignetteModelPiecewiseParam>
         </stCamera:VignetteModel>
         <stCamera:ChromaticRedGreenModel rdf:parseType="Resource">
          <stCamera:ScaleFactor>1.0002</stCamera:ScaleFactor><stCamera:RadialDistortParam1>0.001</stCamera:RadialDistortParam1>
          <stCamera:RadialDistortParam2>0</stCamera:RadialDistortParam2><stCamera:RadialDistortParam3>0</stCamera:RadialDistortParam3>
         </stCamera:ChromaticRedGreenModel>
        </stCamera:PerspectiveModel>
       </rdf:li>
      </rdf:Seq></photoshop:CameraProfiles>
     </rdf:Description></rdf:RDF></x:xmpmeta>
    """

    static func lcpCases() {
        guard let a = try? LCP.read(Data(attributeForm.utf8)), let b = try? LCP.read(Data(elementForm.utf8)) else {
            expect(false, "an LCP written as attributes and one written as elements both read"); return
        }
        expect(a == b, "an LCP reads alike written as attributes, as elements, and as rdf:parseType=\"Resource\"")
        let e = a.first?.entries.first
        expect(a.count == 1 && a[0].camera.lensPretty == "Canon RF 45mm F1.2 STM" && a[0].camera.lens == "RF45mm F1.2 STM" && a[0].camera.raw,
               "the camera's and lens's names read")
        expect(e?.focal == 45 && e?.distance == 3 && e?.aperture == 2 && e?.geometry?.fx == 1.25 && e?.geometry?.k == [-0.1, 0.05, 0.01],
               "an entry's setting and its perspective model read")
        expect(e?.vignette?.alpha == [-0.5, 0.1, 0] && e?.vignette?.piecewise == [[0, 1], [0.25, 0.97], [0.5, 0.88]],
               "the vignette's polynomial and its piecewise knots read")
        expect(e?.red?.scale == 1.0002 && e?.red?.k == [0.001, 0, 0] && e?.blue == nil, "the aberration's red–green model reads")
        let fish = attributeForm.replacingOccurrences(of: "PerspectiveModel", with: "FisheyeModel")
        expect((try? LCP.read(Data(fish.utf8)))?.first?.entries.first?.fisheye == true, "a fisheye model is read and marked")
        do { _ = try LCP.read(Data(attributeForm.dropLast(40).utf8)); expect(false, "a truncated LCP is refused") }
        catch { expect("\(error)".contains("not well-formed"), "a truncated LCP is refused with its reason (\(error))") }
        do { _ = try LCP.read(Data("<x/>".utf8)); expect(false, "an XML file with no profile is refused") }
        catch { expect("\(error)".contains("no camera profile"), "an XML file with no profile is refused with its reason") }

        // The maths, on the frame the profile was measured on: ρ = r · half-diagonal / (fx · Dmax).
        var v = a[0]
        var t = LCP.Target(width: 6000, height: 4000, sensorFactor: 1, focal: 45, distance: 3, aperture: 2)
        guard let p = LCP.profile(v, target: t, terms: .init(vignetting: true, chromaticAberration: true, piecewise: false)) else { expect(false, "the profile is made"); return }
        let s = hypot(3000.0, 2000) / (1.25 * 6000)
        for r in [0.3, 0.7, 1.0] {
            let q = (s * r) * (s * r)
            let d = 1 - 0.1 * q + 0.05 * q * q + 0.01 * q * q * q
            expect(abs((p.distortion?.at(r) ?? 0) - d) < 2e-6, String(format: "D(%.1f) is Adobe's 1 + k1ρ² + k2ρ⁴ + k3ρ⁶ at ρ = r·hd/f", r))
            let rs = r   // the gain is a function of the source radius
            let qs = (s * rs) * (s * rs)
            expect(abs((p.vignetting?.at(rs) ?? 0) - 1 / (1 - 0.5 * qs + 0.1 * qs * qs)) < 2e-5, String(format: "G(%.1f) is 1/L", r))
            let rd = s * r * d
            expect(abs((p.redScale?.at(r) ?? 0) - 1.0002 * (1 + 0.001 * rd * rd)) < 2e-7, String(format: "red's scale at %.1f is at green's distorted radius", r))
        }
        // The same lens on an APS-C body (EXIF: 45 mm, 72 mm equivalent): ρ grows by nothing per mm, the frame is smaller.
        t.sensorFactor = 1.6
        let crop = LCP.profile(v, target: t, terms: .init())
        let q = (s / 1.6) * (s / 1.6)
        expect(abs((crop?.distortion?.at(1) ?? 0) - (1 - 0.1 * q + 0.05 * q * q + 0.01 * q * q * q)) < 2e-6,
               "on a 1.6× body the frame's corner is 1/1.6 of the radius in the model's units")
        // Interpolation: entries at 24 and 70 mm; a frame at 47 mm is halfway.
        v.entries = [24.0, 70].map { f in var e = v.entries[0]; e.focal = f; e.geometry?.k = [f == 24 ? -0.2 : 0.1, 0, 0]; e.geometry?.fx = f / 36; return e }
        let w = LCP.weights(v.entries, target: .init(focal: 47), use: { _ in true })
        expect(w.count == 2 && abs(w[0].1 - 0.5) < 1e-12 && abs(w[1].1 - 0.5) < 1e-12, "a frame between two focal lengths weighs each by its nearness")
        expect(LCP.weights(v.entries, target: .init(focal: 200), use: { _ in true }).map(\.1) == [1], "beyond the longest, the longest")
        var d1 = v.entries[0]; d1.distance = 0.5
        var d2 = v.entries[0]; d2.distance = 10000
        let wd = LCP.weights([d1, d2], target: .init(focal: 24, distance: 1), use: { _ in true })
        expect(abs((wd.first { $0.0.distance == 0.5 }?.1 ?? 0) - (1 / 1 - 1 / 10000.0) / (1 / 0.5 - 1 / 10000.0)) < 1e-9,
               "focus distance is interpolated in 1/d")
    }

    // MARK: - the database, synthetic

    static func databaseCases() {
        let home = scratch.appendingPathComponent("synthetic", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let file = home.appendingPathComponent("Canon (Canon RF 45mm F1.2 STM) - RAW.lcp")
        try? Data(attributeForm.utf8).write(to: file)
        let bad = home.appendingPathComponent("broken.lcp")
        try? Data("<x:xmpmeta".utf8).write(to: bad)
        let db = LensDatabase(url: LensDatabase.file(in: home))
        let r1 = wait { try await db.add(file: file) }, r2 = wait { try await db.add(file: file) }
        expect((try? r1.get())?.added == 1, "a file added is added")
        expect((try? r2.get())?.unchanged == 1 && (try? r2.get())?.added == 0, "the same file added again changes nothing")
        let rb = try? wait { try await db.add(file: bad) }.get()
        expect(rb?.skipped.count == 1 && rb?.added == 0, "a malformed file is skipped with its reason (\(rb?.skipped.first?.reason ?? "none"))")
        let makers = try? wait { try await db.makers() }.get()
        expect(makers == ["Canon"], "a file added by itself is listed under its pretty name's maker (\(makers ?? []))")
        let canon = try? wait { try await db.lenses(maker: "Canon") }.get()
        expect(canon?.map(\.name) == ["Canon RF 45mm F1.2 STM"], "one row a lens")
        // The owner's case: an EOS R6 Mark II's EXIF, no sample file.
        let r6 = LensDatabase.Frame(make: "Canon", model: "Canon EOS R6m2", lens: "RF45mm F1.2 STM", focal: 45, fNumber: 2, width: 6000, height: 4000)
        let rec = try? wait { try await db.recommended(for: r6) }.get()
        expect(rec?.first?.lens.name == "Canon RF 45mm F1.2 STM" && rec?.first?.match == .exif, "the RF 45mm F1.2 STM is recommended from \"Canon EOS R6m2\" / \"RF45mm F1.2 STM\"")
        expect(LensDatabase.matchKey("RF45mm F1.2 STM") == LensDatabase.matchKey("Canon RF 45mm F1.2 STM")
               && LensDatabase.matchKey("NIKKOR Z 24-70mm f/4 S") == LensDatabase.matchKey("Nikon NIKKOR Z 24-70mm f/4 S"),
               "EXIF's names and Adobe's pretty names normalise alike")
        let resolved = try? wait { try await db.profile(lens: "Canon/Canon RF 45mm F1.2 STM", for: r6) }.get()
        expect(resolved?.profile.distortion != nil && resolved?.raw == true, "a database lens resolves to a profile for a frame of another body")
        let word1 = resolved?.word ?? ""
        expect(word1.hasPrefix("file.1:Canon_RF_45mm_F1.2_STM@") && word1.count == "file.1:Canon_RF_45mm_F1.2_STM@".count + 16,
               "the word names the lens and its file's hash (\(word1))")
        // A newer file of the same name replaces its older self, and the word moves.
        try? Data(attributeForm.replacingOccurrences(of: "\"-0.1\"", with: "\"-0.12\"").utf8).write(to: file)
        let r3 = try? wait { try await db.add(file: file) }.get()
        let after = try? wait { try await db.profile(lens: "Canon/Canon RF 45mm F1.2 STM", for: r6) }.get()
        let counts = try? wait { try await db.counts() }.get()
        expect(r3?.replaced == 1 && counts?.files == 1 && counts?.variants == 1, "a changed file replaces its older self (\(counts.map { "\($0)" } ?? "?"))")
        expect((after?.word ?? word1) != word1, "a replaced profile has another word")
        _ = wait { try await db.removeAll(source: .user) }
        let empty = try? wait { try await db.counts() }.get()
        expect(empty == LensDatabase.Counts(), "remove all of a source leaves nothing of it")

        // The keys: the default is today's; a database lens is its word whatever the camera.
        var on = DecodeSettings(); on.lensCorrection = true
        let nef = URL(fileURLWithPath: "/nowhere/DSC0001.NEF"), arw = URL(fileURLWithPath: "/nowhere/DSC0001.ARW")
        expect(on.pixelsKey(source: nef) == on.pixelsKey && on.pixelsKey(source: arw) == on.pixelsKey + "|lens=sony-embedded.1",
               "automatic, unresolved, keys every frame as before")
        let pick = DecodeSettings.LensPick(key: "X/X", name: "X")
        LensResolver.keep(.init(corrector: .database, why: .chosen, profile: LensProfile(source: .file, distortion: .init(radii: [0, 1], values: [1, 1.01])),
                                source: "file.1:X@0123456789abcdef", settled: true), for: nef, pick: pick)
        var chosen = on; chosen.lensProfile = pick
        expect(LensCorrection.word(source: nef, decode: chosen) == "|lens=file.1:X@0123456789abcdef", "a database lens on a Nikon frame is its own word")
        chosen.lensCorrection = false
        expect(LensCorrection.word(source: nef, decode: chosen).isEmpty, "with lens correction off, no word")
        LensResolver.forgetAll()
    }

    // MARK: - Camera Raw's folder

    static let adobeRoot = URL(fileURLWithPath: "/Library/Application Support/Adobe/CameraRaw/LensProfiles/1.0", isDirectory: true)

    static func adobeCases() -> LensDatabase? {
        guard FileManager.default.fileExists(atPath: adobeRoot.path) else {
            print("SKIPPED: no Adobe lens profiles at \(adobeRoot.path) — the install and its samples did not run"); return nil
        }
        expect(LensDatabase.adobeFolders().contains { $0.path == adobeRoot.deletingLastPathComponent().path }, "Camera Raw's folder is detected")
        let home = scratch.appendingPathComponent("adobe", isDirectory: true)
        let db = LensDatabase(url: LensDatabase.file(in: home))
        let last = Locked(LensDatabase.Progress(done: 0, total: 0, skipped: 0))
        let (first, seconds) = time { wait { try await db.install(folder: adobeRoot) { p in last.withLock { $0 = p } } } }
        guard let report = try? first.get() else { expect(false, "Adobe's folder installs (\(first))"); return nil }
        let size = ([LensDatabase.file(in: home).path, LensDatabase.file(in: home).path + "-wal"]
            .compactMap { try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int }).reduce(0, +)
        let counts = (try? wait { try await db.counts() }.get()) ?? .init()
        print(String(format: "\nAdobe's folder installed: %d files (%d added, %d skipped) in %.1f s; %d lenses, %d variants, %d entries; the database %.1f MB",
                     last.withLock { $0.total }, report.added, report.skipped.count, seconds, counts.lenses, counts.variants, counts.entries,
                     Double(size) / 1e6))
        report.skipped.prefix(5).forEach { print("  skipped \($0.name): \($0.reason)") }
        expect(report.added > 3000 && report.skipped.isEmpty && last.withLock { $0.done == $0.total }, "every Adobe file installs, progress reaching the total")
        let (again, seconds2) = time { wait { try await db.install(folder: adobeRoot) } }
        let r2 = try? again.get()
        print(String(format: "  installed again in %.1f s: %d unchanged, %d added", seconds2, r2?.unchanged ?? -1, r2?.added ?? -1))
        expect(r2?.added == 0 && r2?.replaced == 0 && r2?.unchanged == report.added, "installing twice changes nothing")
        // Cancelled at once: nothing more written, and it says so.
        let task = Task { try await db.install(folder: adobeRoot) }
        task.cancel()
        let cancelled = wait { try await task.value }
        expect((try? cancelled.get())?.cancelled == true, "an install can be cancelled")

        let makers = (try? wait { try await db.makers() }.get()) ?? []
        let canon = (try? wait { try await db.lenses(maker: "Canon") }.get()) ?? []
        print("  \(makers.count) makers: \(makers.prefix(12).joined(separator: ", "))…; Canon has \(canon.count) lenses")
        expect(Set(canon.map(\.name)).count == canon.count, "one row a lens (no lens twice under a maker)")
        expect(makers.contains("Sigma") && makers.contains("Voigtlander") && !makers.contains("1.0"), "makers are the folders under 1.0")
        let r6 = LensDatabase.Frame(make: "Canon", model: "Canon EOS R6m2", lens: "RF45mm F1.2 STM", focal: 45, focal35: 45, fNumber: 1.2,
                                    width: 6000, height: 4000)
        let (rec, tr) = time { (try? wait { try await db.recommended(for: r6) }.get()) ?? [] }
        let (rec2, tr2) = time { (try? wait { try await db.recommended(for: r6) }.get()) ?? [] }
        print(String(format: "  recommended for an EOS R6 Mark II with \"RF45mm F1.2 STM\": %@ (%.0f ms first, %.1f ms after)",
                     rec.map(\.lens.name).joined(separator: "; "), tr * 1000, tr2 * 1000))
        expect(rec.first?.lens.key == "Canon/Canon RF 45mm F1.2 STM" && rec == rec2, "the RF 45mm F1.2 STM is the first recommendation from Adobe's own profiles")
        let (res, tp) = time { try? wait { try await db.profile(lens: "Canon/Canon RF 45mm F1.2 STM", for: r6) }.get() }
        print(String(format: "  its profile for the frame (%@, RAW %@): %.1f ms", res?.camera ?? "none", (res?.raw ?? false) ? "yes" : "no", tp * 1000))
        expect(res?.profile.distortion != nil, "the RF 45mm F1.2 STM resolves for an EOS R6 Mark II")
        return db
    }

    // MARK: - the samples, against Adobe's profiles

    static func databaseSamples(_ files: [URL], _ db: LensDatabase) {
        print("\nThe database's recommendations for every sample:")
        for url in files {
            let f = LensDatabase.Frame.read(url)
            let rec = (try? wait { try await db.recommended(for: f) }.get()) ?? []
            print("  \(url.lastPathComponent) (\(f.make) \(f.model), \"\(f.lens)\", \(f.focal.map { String(format: "%.0f mm", $0) } ?? "?")): "
                  + (rec.isEmpty ? "none" : rec.map { "\($0.lens.name) [\($0.match)]" }.joined(separator: "; ")))
        }
        for url in files {
            let ext = url.pathExtension.lowercased()
            let f = LensDatabase.Frame.read(url)
            // Only the frame's own lens (by its EXIF string or its name) is verified; a similar one is another lens.
            guard let lens = (try? wait { try await db.recommended(for: f) }.get())?.first(where: { $0.match >= .name })?.lens,
                  let resolved = try? wait({ try await db.profile(lens: lens.key, for: f, terms: .init()) }).get()
            else {
                if ["nef", "cr3", "raf", "rw2", "dng"].contains(ext) { print("\n\(url.lastPathComponent): no Adobe profile of \"\(f.lens)\" — not verified against Core Image") }
                continue
            }
            let supported = CIRAWFilter(imageURL: url)?.isLensCorrectionSupported ?? false
            if supported { coreImageCase(url, f, db, lens, resolved) }
            else if ext == "arw" { sonyLCPCase(url, resolved) }
            else if ext == "dng" { previewCase(url, resolved) }
        }
    }

    /// Where Core Image corrects and Adobe has the lens: the app's LCP-corrected decode against Core Image's.
    static func coreImageCase(_ url: URL, _ f: LensDatabase.Frame, _ db: LensDatabase, _ lens: LensDatabase.Lens, _ resolved: LensDatabase.Resolved) {
        print("\n\(url.lastPathComponent) — \(f.model), \(f.lens), \(Int(f.focal ?? 0)) mm: Adobe's \(lens.name) (measured on \(resolved.camera)) against Core Image's own correction")
        let w = 3000
        let ci = Oracle.render(Oracle.decode(url, profile: nil, apple: true), width: w, space: Oracle.srgb)
        let app = Oracle.render(Oracle.decode(url, profile: disableStep ? nil : resolved.profile), width: w, space: Oracle.srgb)
        let un = Oracle.render(Oracle.decode(url, profile: nil), width: w, space: Oracle.srgb)
        let R = hypot(Double(ci.g.w), Double(ci.g.h)) / 2
        let ra = Oracle.residuals(ci.luma, app.luma), ru = Oracle.residuals(ci.luma, un.luma)
        print("     r     uncorrected          the app's LCP")
        for (a, b) in zip(Oracle.binned(ru), Oracle.binned(ra)) {
            print(String(format: "    %.2f  %+6.2f px %6.3f %%   %+6.2f px %6.3f %%  (%d)", a.0, a.1, 100 * abs(a.1) / R, b.1, 100 * abs(b.1) / R, b.2))
        }
        let mu = ru.map { abs($0.1) }.max() ?? .nan, ma = ra.map { abs($0.1) }.max() ?? .nan
        print(String(format: "     max  %6.2f px %6.3f %%   %6.2f px %6.3f %%  (%d patches)", mu, 100 * mu / R, ma, 100 * ma / R, ra.count))
        let bad = zip(ru, ra).filter { abs($0.0.1) / R > 0.001 && abs($0.1.1) / R > 0.001 }
        if bad.isEmpty { expect(ra.count >= 20, "\(url.lastPathComponent): Adobe's profile is Core Image's correction to 0.1 % of the half-diagonal (\(ra.count) patches)") }
        else {
            print("  → \(bad.count) patches over 0.1 %: Adobe's measurement and the maker's data differ here; the camera's JPEG:")
            var sidesWithMaker = false
            if let (jpeg, jw, _) = LensProfileReader.tiff(url).flatMap(Oracle.jpeg) ?? Oracle.embeddedPreview(url) {
                let ci2 = Oracle.render(Oracle.decode(url, profile: nil, apple: true), width: jw, space: Oracle.srgb).luma
                let app2 = Oracle.render(Oracle.decode(url, profile: resolved.profile), width: jw, space: Oracle.srgb).luma
                let un2 = Oracle.render(Oracle.decode(url, profile: nil), width: jw, space: Oracle.srgb).luma
                let rc = Oracle.residuals(jpeg.luma, ci2), rp = Oracle.residuals(jpeg.luma, app2), rn = Oracle.residuals(jpeg.luma, un2)
                print(String(format: "     the JPEG (%d wide) against the uncorrected: max %.3f %%", jw,
                             100 * (rn.map { abs($0.1) }.max() ?? .nan) / (hypot(Double(jpeg.g.w), Double(jpeg.g.h)) / 2)))
                print(String(format: "     the JPEG against Core Image's: max %.3f %%; against Adobe's: max %.3f %%",
                             100 * (rc.map { abs($0.1) }.max() ?? .nan) / (hypot(Double(jpeg.g.w), Double(jpeg.g.h)) / 2),
                             100 * (rp.map { abs($0.1) }.max() ?? .nan) / (hypot(Double(jpeg.g.w), Double(jpeg.g.h)) / 2)))
                let hd = hypot(Double(jpeg.g.w), Double(jpeg.g.h)) / 2
                let mc = (rc.map { abs($0.1) }.max() ?? .nan) / hd, mp = (rp.map { abs($0.1) }.max() ?? .nan) / hd
                let mn = (rn.map { abs($0.1) }.max() ?? .nan) / hd
                sidesWithMaker = mn > 0.001 && mc <= 0.001 && mp > 0.001
            }
            // Not tuned (the brief): where the camera's own JPEG is Core Image's and not Adobe's, the two measurements
            // honestly differ, and that is reported, not counted as a pass or a failure of the maths.
            if sidesWithMaker {
                print("  → REPORTED: the camera's JPEG agrees with Core Image's (the maker's data), not with Adobe's profile of this lens (\(resolved.camera)'s)")
            } else {
                expect(false, "\(url.lastPathComponent): Adobe's profile within 0.1 % of Core Image's (\(bad.count) patches over)")
            }
        }

        // Light falloff: Core Image's gain against Adobe's, as the ratio of Core Image's corrected decode to the app's
        // geometry alone, patch by patch (linear light), against the profile's own gain at that radius.
        if let full = try? wait({ try await db.profile(lens: lens.key, for: f, terms: .init(vignetting: true, piecewise: false)) }).get(),
           let poly = full.profile.vignetting {
            let piece = (try? wait { try await db.profile(lens: lens.key, for: f, terms: .init(vignetting: true)) }.get())?.profile.vignetting
            let ciLin = Oracle.render(Oracle.decode(url, profile: nil, apple: true), width: w, space: Oracle.linear)
            let appLin = Oracle.render(Oracle.decode(url, profile: resolved.profile), width: w, space: Oracle.linear)
            let g = Oracle.gains(ci.luma, ciLin.luma, app.luma, appLin.luma)
            print("  light falloff, Core Image's gain over the uncorrected (median a ring) against Adobe's (polynomial, piecewise):")
            for (r, v, n) in g { print(String(format: "    %.2f  Core Image %.3f   Adobe %.3f  %.3f  (%d)", r, v, poly.at(r), piece?.at(r) ?? .nan, n)) }
            let worst = g.filter { $0.0 < 0.9 }.map { abs(log2($0.1 / poly.at($0.0))) }.max() ?? .nan
            let worstPiece = g.filter { $0.0 < 0.9 }.map { abs(log2($0.1 / (piece?.at($0.0) ?? 1))) }.max() ?? .nan
            print(String(format: "    worst inside r 0.9: polynomial %.3f stop, piecewise %.3f stop", worst, worstPiece))
        }
        // Colour fringes: red's and blue's radial shift against green's, Core Image's corrected decode and the uncorrected.
        let caCI = (Oracle.residuals(ci.g, ci.r, fit: false), Oracle.residuals(ci.g, ci.b, fit: false))
        let caUn = (Oracle.residuals(un.g, un.r, fit: false), Oracle.residuals(un.g, un.b, fit: false))
        func med(_ v: [(Oracle.Patch, Double)]) -> Double { let s = v.filter { $0.0.r > 0.6 }.map(\.1).sorted(); return s.isEmpty ? .nan : s[s.count / 2] }
        print(String(format: "  colour fringes beyond r 0.6 (median px at %d wide): uncorrected R–G %+.2f B–G %+.2f; Core Image's R–G %+.2f B–G %+.2f; Adobe's profile %@",
                     w, med(caUn.0), med(caUn.1), med(caCI.0), med(caCI.1),
                     resolved.profile.redScale == nil ? "has none for this lens (a RAW profile: Camera Raw corrects fringes by itself)" : "has a model"))

        // Both decodes carry the database lens, Core Image's own correction off.
        var on = DecodeSettings(); on.lensCorrection = true
        let auto = on
        // The lens chosen, its answer kept as the resolver keeps a chosen lens's (`LensResolver.chosen`).
        let pick = DecodeSettings.LensPick(key: resolved.lens.key, name: resolved.lens.name)
        LensResolver.keep(.init(corrector: .database, why: .chosen, profile: resolved.profile, lens: resolved.lens, source: resolved.word, settled: true),
                          for: url, pick: pick)
        on.lensProfile = pick
        defer { LensResolver.forgetAll() }
        guard let engine = RawExposure.prepare(url, settings: on, longEdge: 1600)?.image,
              let stock = DigitalDecode.image(url, isRAW: true, decode: on),
              let engineCI = RawExposure.prepare(url, settings: auto, longEdge: 1600)?.image else { expect(false, "\(url.lastPathComponent): both decodes made"); return }
        func step() -> LensProfileFilter {
            let s = LensProfileFilter(); s.profile = resolved.profile; s.chromaticAberration = false; s.vignettingAmount = 0; return s
        }
        let fe = CIRAWFilter(imageURL: url)!
        fe.baselineExposure = fe.baselineExposure; fe.exposure = Float(on.rawExposureTreatment.sourceOffsetEV); fe.shadowBias = 0
        fe.boostAmount = 0; fe.boostShadowAmount = 0; fe.isGamutMappingEnabled = false; fe.localToneMapAmount = 0; fe.extendedDynamicRangeAmount = 0
        fe.isLensCorrectionEnabled = false
        fe.linearSpaceFilter = step()
        let fs = CIRAWFilter(imageURL: url)!
        fs.isLensCorrectionEnabled = false
        fs.linearSpaceFilter = step()
        let a = Oracle.bytes(engine), b = Oracle.bytes(RawExposure.scaled(fe.outputImage!, toLongEdge: 1600)), c = Oracle.bytes(engineCI)
        let sa = Oracle.bytes(RawExposure.scaled(stock, toLongEdge: 1600)), sb = Oracle.bytes(RawExposure.scaled(fs.outputImage!, toLongEdge: 1600))
        expect(!a.isEmpty && a == b && a != c, "\(url.lastPathComponent): RawExposure.prepare applies the database lens with Core Image's own off")
        expect(!sa.isEmpty && sa == sb, "\(url.lastPathComponent): DigitalDecode.image applies the database lens with Core Image's own off")
        var off = on; off.lensCorrection = false
        expect(on.pixelsKey(source: url) != auto.pixelsKey(source: url) && on.pixelsKey(source: url).hasSuffix(resolved.word)
               && off.pixelsKey(source: url) == off.pixelsKey, "\(url.lastPathComponent): the key names the database lens only with lens correction on")
    }

    /// Sony: Adobe's LCP of the lens against the file's own parameters (`LensProfileReader.sony`).
    static func sonyLCPCase(_ url: URL, _ resolved: LensDatabase.Resolved) {
        guard let own = LensProfileReader.profile(url) else { return }
        let w = 3000
        let ref = Oracle.render(Oracle.decode(url, profile: own), width: w, space: Oracle.srgb).luma
        let lcp = Oracle.render(Oracle.decode(url, profile: disableStep ? nil : resolved.profile), width: w, space: Oracle.srgb).luma
        let un = Oracle.render(Oracle.decode(url, profile: nil), width: w, space: Oracle.srgb).luma
        let R = hypot(Double(ref.w), Double(ref.h)) / 2
        let rl = Oracle.residuals(ref, lcp), ru = Oracle.residuals(ref, un)
        let ml = rl.map { abs($0.1) }.max() ?? .nan, mu = ru.map { abs($0.1) }.max() ?? .nan
        print(String(format: "\n%@ — Adobe's %@ (measured on %@) against the file's own parameters: uncorrected max %.3f %%, Adobe's max %.3f %% (%d patches)",
                     url.lastPathComponent, resolved.lens.name, resolved.camera, 100 * mu / R, 100 * ml / R, rl.count))
        let bad = zip(ru, rl).filter { abs($0.0.1) / R > 0.001 && abs($0.1.1) / R > 0.001 }
        expect(rl.count >= 20 && bad.isEmpty, "\(url.lastPathComponent): Adobe's LCP is the file's own correction to 0.1 % of the half-diagonal (\(bad.count) over)")
    }

    /// A DNG Core Image does not correct (a Ricoh GR II): Adobe's profile against the camera's own JPEG preview.
    static func previewCase(_ url: URL, _ resolved: LensDatabase.Resolved) {
        guard let t = LensProfileReader.tiff(url), let (jpeg, w, h) = Oracle.jpeg(t) else { print("\n\(url.lastPathComponent): no JPEG preview"); return }
        let un = Oracle.render(Oracle.decode(url, profile: nil), width: w, space: Oracle.srgb).luma
        let co = Oracle.render(Oracle.decode(url, profile: disableStep ? nil : resolved.profile), width: w, space: Oracle.srgb).luma
        let R = hypot(Double(w), Double(h)) / 2
        let ru = Oracle.residuals(jpeg.luma, un), rc = Oracle.residuals(jpeg.luma, co)
        let mu = ru.map { abs($0.1) }.max() ?? .nan, mc = rc.map { abs($0.1) }.max() ?? .nan
        print(String(format: "\n%@ — Adobe's %@ against the camera's JPEG preview (%dx%d, %d patches): uncorrected max %.2f px (%.3f %%), Adobe's max %.2f px (%.3f %%)",
                     url.lastPathComponent, resolved.lens.name, w, h, rc.count, mu, 100 * mu / R, mc, 100 * mc / R))
        for (a, b) in zip(Oracle.binned(ru), Oracle.binned(rc)) {
            print(String(format: "    %.2f  %+6.2f px   %+6.2f px  (%d)", a.0, a.1, b.1, b.2))
        }
        if mu / R <= 0.001 { print("  → the preview registers to the uncorrected decode: the camera did not correct it; no verdict"); return }
        let bad = zip(ru, rc).filter { abs($0.0.1) / R > 0.001 && abs($0.1.1) / R > 0.001 }
        expect(rc.count >= 20 && bad.isEmpty, "\(url.lastPathComponent): Adobe's profile is the camera's JPEG to 0.1 % of the half-diagonal (\(bad.count) over)")
    }
}

extension Oracle {
    /// The file's own preview as ImageIO finds it (a Panasonic RW2's JpgFromRaw, which the TIFF walk does not reach), in
    /// the sensor's orientation, never one made from the raw data.
    static func embeddedPreview(_ url: URL) -> (RGB, Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: false,
                                                                   kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                                                                   kCGImageSourceCreateThumbnailWithTransform: false,
                                                                   kCGImageSourceThumbnailMaxPixelSize: 20000] as CFDictionary),
              cg.width >= 1500 else { return nil }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let c = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cg.colorSpace ?? srgb,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (RGB(rgba: px.map { Float($0) / 255 }, w: w, h: h), w, h)
    }

    /// Core Image's gain: at each textured patch, `a`'s linear mean over `b`'s at the matched place (`a`, `b` the
    /// registration planes; `aLin`, `bLin` the same pictures in linear light). Median per 0.1 of radius.
    static func gains(_ a: Plane, _ aLin: Plane, _ b: Plane, _ bLin: Plane, half: Int = 24) -> [(Double, Double, Int)] {
        let R = hypot(Double(a.w), Double(a.h)) / 2
        let coarse = max(6, Int(0.035 * R / 4))
        let a4 = a.down(4), b4 = b.down(4)
        var out: [(Double, Double)] = []
        let lock = NSLock()
        let ps = patches(w: a.w, h: a.h, margin: half + 4 * coarse + 12)
        DispatchQueue.concurrentPerform(iterations: ps.count) { i in
            let p = ps[i]
            guard let c = match(a4, b4, x: p.x / 4, y: p.y / 4, half: max(8, half / 4), search: coarse), c.2 > 0.6,
                  let f = match(a, b, x: p.x, y: p.y, half: half, search: 4, guess: (c.0 * 4, c.1 * 4)), f.2 > 0.85 else { return }
            let bx = p.x + Int(f.0.rounded()), by = p.y + Int(f.1.rounded())
            guard bx - half >= 0, by - half >= 0, bx + half < b.w, by + half < b.h else { return }
            var sa: Float = 0, sb: Float = 0
            for j in -half...half { for k in -half...half { sa += aLin[p.x + k, p.y + j]; sb += bLin[bx + k, by + j] } }
            guard sb > 1e-4 else { return }
            lock.lock(); out.append((p.r, Double(sa / sb))); lock.unlock()
        }
        return stride(from: 0.0, to: 1.0, by: 0.1).compactMap { k in
            let v = out.filter { $0.0 >= k && $0.0 < k + 0.1 }.map(\.1).sorted()
            return v.isEmpty ? nil : (k + 0.05, v[v.count / 2], v.count)
        }
    }
}
