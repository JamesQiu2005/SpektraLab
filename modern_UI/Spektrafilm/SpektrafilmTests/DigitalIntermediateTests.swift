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

    // MARK: - through the engine

    /// A grey wedge, −6 … +6 stops, through the engine the app links, with the
    /// DI on. Every patch must be neutral — the reversal is built on this
    /// film's own neutral curve — and mid grey must land on the Cineon code of
    /// 0.184 (`(685 + 300·log10 0.184) / 1023`). Grain is off because it is a
    /// realisation, not a colour; auto exposure off so stop 0 is 0.184.
    func testAGreyIsNeutralAndMidGreyLandsOnItsCode() async throws {
        let gpu = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let stops = Array(-6...6)
        let patch = 16
        let width = patch * stops.count, height = patch
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = Float(0.184 * pow(2.0, Double(stops[x / patch])))
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
        p.filmStock = "kodak_portra_400"
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
        let perPatch = texture.width / stops.count
        var codes: [[Double]] = []
        for k in stops.indices {
            let x = k * perPatch + perPatch / 2
            let i = (row * texture.width + x) * 4
            codes.append((0..<3).map { Double(px[i + $0]) / 65535 })
        }
        // 1/300 of a stop: invisible, and far below the per-channel gamma
        // error (0.08–0.43 stop inside ±4) the reversal exists to remove.
        for (k, c) in codes.enumerated() {
            let stopsOff = (c.max()! - c.min()!) * 1023 / 300 / log10(2)
            XCTAssertLessThan(stopsOff, 1.0 / 300, "patch \(stops[k]) stops is not neutral: \(c)")
        }
        let mid = codes[stops.firstIndex(of: 0)!][1]
        XCTAssertEqual(mid, (685 + 300 * log10(0.184)) / 1023, accuracy: 2e-4)
        // and it is a positive: brighter scene, higher code
        for k in 1..<codes.count { XCTAssertGreaterThan(codes[k][1], codes[k - 1][1]) }
    }
}
