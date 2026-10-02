//  DigitalIntermediateTests.swift — RFC-028's Digital Intermediate (数字中间片).
//
//  The promises, each checked where it can fail:
//
//  * a grey is exactly neutral at every exposure, and mid grey lands on the
//    Cineon code for 0.184 — through the real engine, from Swift;
//  * the switch is a switch beside the paper, not a paper: choosing it keeps
//    the paper, choosing a paper or No Print Profile turns it off, and a slide
//    film refuses it;
//  * the blue compensation reaches the wire only while the DI is on, so the
//    Settings switch cannot move any other frame's print-cache stamp;
//  * a sidecar written before the DI existed reads with it off.

import Metal
import XCTest

@MainActor
final class DigitalIntermediateTests: XCTestCase {

    // MARK: - the model

    func testTheWireCarriesTheSwitchAndTheCompensationOnlyWithIt() {
        let saved = UserDefaults.standard.object(forKey: FilmParams.diBlueCompensationKey)
        defer { UserDefaults.standard.set(saved, forKey: FilmParams.diBlueCompensationKey) }
        UserDefaults.standard.set(true, forKey: FilmParams.diBlueCompensationKey)

        var p = FilmParams.default
        func wire(_ name: String) -> ParamValue? { p.fullDelta[name] }
        XCTAssertEqual(wire("digital_intermediate"), .bool(false))
        XCTAssertEqual(wire("digital_intermediate_blue_compensation"), .bool(false),
                       "the setting is on, but a paper frame must not carry it")
        p.digitalIntermediate = true
        XCTAssertEqual(wire("digital_intermediate"), .bool(true))
        XCTAssertEqual(wire("digital_intermediate_blue_compensation"), .bool(true))

        UserDefaults.standard.set(false, forKey: FilmParams.diBlueCompensationKey)
        XCTAssertEqual(wire("digital_intermediate_blue_compensation"), .bool(false))
    }

    func testTheSwitchIsAPrintLayerChange() {
        var p = FilmParams.default
        p.digitalIntermediate = true
        let (delta, layers) = p.delta(from: .default)
        XCTAssertEqual(delta["digital_intermediate"], .bool(true))
        XCTAssertEqual(layers, [.print], "the DI reads the cached negative; it must not re-develop it")
    }

    func testALegacySidecarReadsWithTheDIOff() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(FilmParams.default))
            as! [String: Any]
        json.removeValue(forKey: "digitalIntermediate")
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertFalse(try JSONDecoder().decode(FilmParams.self, from: data).digitalIntermediate)
    }

    func testTheDIHasNoEDR() {
        var p = FilmParams.default
        p.extendedDynamicRange = true
        XCTAssertTrue(p.effectiveExtendedDynamicRange)
        p.digitalIntermediate = true
        XCTAssertFalse(p.effectiveExtendedDynamicRange, "the DI has no paper, so no calibrated EDR")
        XCTAssertTrue(p.extendedDynamicRange, "the preference is kept for when the paper comes back")
    }

    func testTheActiveRuleFollowsTheFilmAndTheScan() {
        var p = FilmParams.default
        p.digitalIntermediate = true
        XCTAssertTrue(p.digitalIntermediateActive(filmIsPositive: false))
        XCTAssertFalse(p.digitalIntermediateActive(filmIsPositive: true), "a slide has no mask and no paper")
        p.scanFilm = true
        XCTAssertFalse(p.digitalIntermediateActive(filmIsPositive: false), "scan_film wins, as in the engine")
    }

    // MARK: - choosing it

    func testChoosingTheDIKeepsThePaperAndChoosingAPaperLeavesIt() {
        let session = Session()
        var p = session.params
        p.filmStock = "kodak_portra_400"; p.printStock = "kodak_portra_endura"; p.scanFilm = true
        session.params = p

        session.selectDigitalIntermediate()
        XCTAssertTrue(session.params.digitalIntermediate)
        XCTAssertFalse(session.params.scanFilm, "the DI and No Print Profile are one choice in one list")
        XCTAssertEqual(session.params.printStock, "kodak_portra_endura", "the paper survives the switch")
        XCTAssertTrue(session.digitalIntermediateActive)

        session.selectPrintStock("kodak_supra_endura")
        XCTAssertFalse(session.params.digitalIntermediate)
        XCTAssertEqual(session.params.printStock, "kodak_supra_endura")
    }

    func testASlideFilmRefusesTheDI() {
        let session = Session()
        session.selectFilmStock("fujifilm_provia_100f")
        guard session.filmIsPositive else { return XCTFail("the catalogue should call Provia a positive") }
        session.selectDigitalIntermediate()
        XCTAssertFalse(session.params.digitalIntermediate)
        XCTAssertFalse(session.digitalIntermediateActive)
    }

    func testTheClipboardCarriesTheDIWithFilmAndPaper() {
        XCTAssertTrue(ClipboardGroup.filmAndPaper.paths.contains("params.digitalIntermediate"))
        var source = Sidecar()
        source.params.digitalIntermediate = true
        let clip = SettingsClip(groups: [.filmAndPaper], settings: source, sourceName: "a")
        XCTAssertTrue(clip.applied(to: Sidecar()).params.digitalIntermediate)
        let exposureOnly = SettingsClip(groups: [.exposure], settings: source, sourceName: "a")
        XCTAssertFalse(exposureOnly.applied(to: Sidecar()).params.digitalIntermediate)
    }

    // MARK: - the Cineon transform

    /// Kodak's reference points.
    func testTheCineonDecodeIsKodaks() {
        XCTAssertEqual(CineonLUT.decode(95 / 1023), 0, accuracy: 1e-12, "reference black is the film base")
        XCTAssertEqual(CineonLUT.decode(685 / 1023), 1, accuracy: 1e-12, "reference white is 1.0")
        // colour-science 0.4.7: log_encoding_Cineon(0.18) = 0.4573196...
        XCTAssertEqual(CineonLUT.decode(0.4573196), 0.18, accuracy: 1e-6)
    }

    /// The DI view's promises: mid grey and everything under the knee are
    /// untouched, a grey stays grey, the top code lands 1/16 stop under
    /// white, and it rises all the way (no clip hiding what the file holds).
    func testTheViewKeepsGreyAndShowsEveryHighlight() {
        func code(_ linear: Double) -> Double {
            (685 + 300 * log10(linear * (1 - CineonLUT.blackOffset) + CineonLUT.blackOffset)) / 1023
        }
        let greyOut = CineonLUT.view(SIMD3(repeating: code(0.18)), to: .proPhoto)
        XCTAssertEqual(greyOut.x, CineonLUT.rommEncode(0.18), accuracy: 1e-9, "mid grey moved")
        XCTAssertEqual(greyOut.x, greyOut.y, accuracy: 1e-12); XCTAssertEqual(greyOut.y, greyOut.z, accuracy: 1e-12)
        XCTAssertGreaterThanOrEqual(CineonLUT.knee, 0, "the knee must not sit below grey")
        let top = CineonLUT.tone(CineonLUT.decode(1))
        XCTAssertEqual(log2(1 / top), CineonLUT.ceilingMargin, accuracy: 1e-6)
        var last = -1.0
        for k in 95...1023 {
            let v = CineonLUT.view(SIMD3(repeating: Double(k) / 1023), to: .proPhoto).x
            XCTAssertGreaterThan(v, last, "the grey axis flattens at code \(k)"); last = v
        }
        // A colour under the knee keeps its linear ratios exactly: hue kept.
        let c = SIMD3(code(0.10), code(0.18), code(0.05))
        let o = CineonLUT.view(c, to: .proPhoto)
        let lin = SIMD3(pow(o.x, 1.8), pow(o.y, 1.8), pow(o.z, 1.8))
        XCTAssertEqual(lin.x / lin.y, CineonLUT.decode(c.x) / CineonLUT.decode(c.y), accuracy: 1e-9)
        // A bright colour past white comes back inside with its hue, not
        // clipped per channel; one at the file's very top goes to white.
        let hot = CineonLUT.view(SIMD3(0.85, 0.75, 0.65), to: .proPhoto)
        XCTAssertLessThanOrEqual(hot.max(), 1); XCTAssertGreaterThan(hot.x, hot.y); XCTAssertGreaterThan(hot.y, hot.z)
        XCTAssertEqual(CineonLUT.view(SIMD3(1, 0.7, 0.5), to: .proPhoto), SIMD3(repeating: 1))
    }

    /// The shipped files are what this code generates. They are checked on a
    /// sparse sample (every 97th entry) so the check is quick; set
    /// `TEST_RUNNER_SPK_REGEN_DI_LUTS=1` on `xcodebuild test` to rewrite them.
    func testTheShippedViewLUTsAreCurrent() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Spektrafilm/Resources/DI")
        if ProcessInfo.processInfo.environment["SPK_REGEN_DI_LUTS"] == "1" {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for t in CineonLUT.Target.allCases {
                try CineonLUT.cube(t).write(to: dir.appending(path: t.fileName), atomically: true, encoding: .utf8)
            }
        }
        let n = CineonLUT.size
        for t in CineonLUT.Target.allCases {
            let text = try String(contentsOf: dir.appending(path: t.fileName), encoding: .utf8)
            let (size, rgba) = try XCTUnwrap(CineonLUT.parse(text), "\(t.fileName) does not parse")
            XCTAssertEqual(size, n)
            for i in stride(from: 0, to: n * n * n, by: 97) {
                let r = i % n, g = (i / n) % n, b = i / (n * n)
                let want = CineonLUT.view(SIMD3(Double(r), Double(g), Double(b)) / Double(n - 1), to: t)
                for c in 0..<3 {
                    XCTAssertEqual(Double(rgba[4 * i + c]), want[c], accuracy: 2e-6,
                                   "\(t.fileName) entry \(i) is stale: regenerate the view LUTs")
                }
            }
        }
    }

    func testTheCanvasLoadsTheShippedView() throws {
        let gpu = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let t = try XCTUnwrap(CineonLUT.makeTexture(device: gpu), "the canvas has no DI view")
        XCTAssertEqual(t.textureType, .type3D)
        XCTAssertEqual(t.width, CineonLUT.size)
    }

    // MARK: - through the engine

    /// A black patch then grey at -6…+6 stops over 0.184, through `film` as a
    /// DI with grain and metering off; the Cineon codes (0…1) of each patch.
    /// The canvas reads a print through the DI view when **that print** is a
    /// Digital Intermediate — not when the settings say the next one will be.
    /// The settings move first: until the new print lands (and for good, if
    /// it fails) the paper print on the canvas was decoded as Cineon codes,
    /// and a DI still on the canvas after choosing a paper was shown as the
    /// codes themselves.
    @MainActor
    func testTheCanvasDecodesThePrintItShowsNotTheOneAskedFor() async throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/Test_image/_smoke_1mp.tif")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path), "the smoke frame is not in this checkout")
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-di-canvas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)

        func wait(_ what: String, _ condition: @MainActor () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
            XCTFail("timed out waiting for \(what)")
        }
        let session = Session()
        session.open(urls: [url])
        try await wait("the decode") { session.decoded != nil }
        session.requestPrint()
        try await wait("the print") { session.frameStates[url] == .processed && !session.busy }
        func decodes() throws -> Bool {
            let shown = try XCTUnwrap(session.renderer.base)
            return try XCTUnwrap(session.renderer.layer2DecodesCineon)(shown)
        }
        XCTAssertFalse(try decodes(), "a paper print")

        let paper = session.renderer.live
        var p = session.params
        p.digitalIntermediate = true
        session.params = p
        XCTAssertTrue(session.renderer.live === paper, "the DI has not landed yet, so this case proves something")
        XCTAssertFalse(try decodes(), "the paper print is still on the canvas")
        try await wait("the DI") { session.renderer.live !== paper && !session.busy }
        XCTAssertTrue(try decodes(), "the DI is on the canvas")

        let di = session.renderer.live
        p.digitalIntermediate = false
        session.params = p
        XCTAssertTrue(session.renderer.live === di)
        XCTAssertTrue(try decodes(), "the DI is still on the canvas")
        try await wait("the paper print") { session.renderer.live !== di && !session.busy }
        XCTAssertFalse(try decodes(), "a paper print again")
    }

    private func diWedge(film: String) async throws -> (stops: [Int], codes: [[Double]]) {
        let gpu = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let stops = Array(-6...6)          // plus a black patch in front
        let patch = 16
        let width = patch * (stops.count + 1), height = patch
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = x < patch ? 0 : Float(0.184 * pow(2.0, Double(stops[x / patch - 1])))
                let i = (y * width + x) * 4
                rgba[i] = v; rgba[i + 1] = v; rgba[i + 2] = v
            }
        }
        let space = try XCTUnwrap(ImageDecoder.linearProPhoto)
        let image = try XCTUnwrap(rgba.withUnsafeBufferPointer { buffer in
            CIImage(bitmapData: Data(buffer: buffer), bytesPerRow: width * 16,
                    size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: space)
        })
        let frame = try ImageDecoder.engineFrame(from: image, device: gpu)

        var p = FilmParams.default
        p.filmStock = film
        p.digitalIntermediate = true
        p.grainActive = false
        p.autoExposure = false
        let client = EngineClient(device: gpu)
        let open = try await client.open(frame, paramsDelta: p.fullDelta)
        let outcome = try await client.render(.reprint, RenderRequest(sessionID: open.sessionID))
        let texture = try XCTUnwrap(outcome.texture)
        var px = [UInt16](repeating: 0, count: texture.width * texture.height * 4)
        px.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 8,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        await client.stop()

        let row = texture.height / 2
        let perPatch = texture.width / (stops.count + 1)
        var codes: [[Double]] = []
        for k in 0...stops.count {
            let x = k * perPatch + perPatch / 2
            let i = (row * texture.width + x) * 4
            codes.append((0..<3).map { Double(px[i + $0]) / 65535 })
        }
        return (stops, codes)
    }

    /// A black patch and a grey wedge, −6 … +6 stops, through the engine the
    /// app links, with the DI on. Every patch must be neutral — the reversal is
    /// built on this film's own neutral curve; black (clear film base) must be
    /// Cineon's reference black, code 95; and mid grey must decode, through the
    /// standard Cineon decode, to 0.184 less the base's own positive (a few
    /// thousandths). Grain is off because it is a realisation, not a colour;
    /// auto exposure off so stop 0 is 0.184.
    func testAGreyIsNeutralAndMidGreyLandsOnItsCode() async throws {
        let (stops, wedge) = try await diWedge(film: "kodak_portra_400")
        var codes = wedge
        // 1/300 of a stop: invisible, and far below the per-channel gamma
        // error (0.08–0.43 stop inside ±4) the reversal exists to remove.
        let black = codes.removeFirst()
        for c in black { XCTAssertEqual(c * 1023, 95, accuracy: 0.05, "clear base is Cineon black") }
        for (k, c) in codes.enumerated() {
            let lin = c.map(CineonLUT.decode)
            let stopsOff = log2(lin.max()! / lin.min()!)
            XCTAssertLessThan(stopsOff, 0.01, "patch \(stops[k]) stops is not neutral: \(c)")
        }
        let mid = CineonLUT.decode(codes[stops.firstIndex(of: 0)!][1])
        XCTAssertLessThanOrEqual(mid, 0.184)
        XCTAssertGreaterThan(mid, 0.17, "mid grey less the base's positive, a few thousandths")
        // and it is a positive: brighter scene, higher code
        for k in 1..<codes.count { XCTAssertGreaterThan(codes[k][1], codes[k - 1][1]) }
    }

    /// RFC-030 §2: the reversal's slope is Cineon's 0.6, not each film's own
    /// gamma, so the film's contrast survives. Vision3 50D (printing-density
    /// gamma ≈ 0.54) must decode flatter than the scene and X-Tra 400 (≈ 0.67)
    /// punchier. Reversing on each film's own gamma put both near 1.0.
    func testTheDIKeepsEachFilmsContrast() async throws {
        func slope(_ film: String) async throws -> Double {
            let (stops, codes) = try await diWedge(film: film)
            let window = stops.indices.filter { abs(stops[$0]) <= 2 }
            let xs = window.map { Double(stops[$0]) }
            let ys = window.map { log2(CineonLUT.decode(codes[$0 + 1][1])) }   // codes[0] is black
            let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
            let num = zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0, +)
            return num / xs.map { ($0 - mx) * ($0 - mx) }.reduce(0, +)
        }
        let vision = try await slope("kodak_vision3_50d")
        let xtra = try await slope("fujifilm_xtra_400")
        XCTAssertLessThan(vision, 0.98, "Vision3 50D keeps its low contrast")
        XCTAssertGreaterThan(xtra, 1.1, "X-Tra 400 keeps its high contrast")
        XCTAssertGreaterThan(xtra - vision, 0.15, "the two films' DIs differ in contrast")
    }
}
