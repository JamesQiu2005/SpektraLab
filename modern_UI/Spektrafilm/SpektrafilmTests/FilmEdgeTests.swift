//  FilmEdgeTests.swift — what the host owes the engine for the film edge and
//  the date back, without a session: the wire, the text it prints, the
//  per-stock formats, the gate's crop, and the frame the engine is cut.
//
//  The engine-backed cases at the bottom assert sizes, not that something
//  changed: "wired is not visible" (an inequality proves only the wiring).

import CoreImage
import Metal
import XCTest

final class FilmEdgeTests: XCTestCase {

    // MARK: - the wire

    /// The two seeds are `int` in the engine's schema and `ParamValue` has no
    /// int case; they go as whole doubles, like `preview_long_edge`, and the
    /// largest one survives exactly.
    func testSeedsGoAsWholeNumbers() {
        var p = FilmParams.default
        p.filmEdge.active = true
        p.filmEdge.cameraSeed = Int(Int32.max)
        p.filmEdge.frameSeed = 7
        let wire = Dictionary(uniqueKeysWithValues: p.wire.map { ($0.name, $0.value) })
        XCTAssertEqual(wire["overscan_camera_seed"], .double(2_147_483_647))
        XCTAssertEqual(wire["overscan_frame_seed"], .double(7))
    }

    /// A frame without a film edge renders byte for byte as before: its stamp
    /// carries no framing, and the wire only the two switches, both off.
    func testAFrameWithoutAFilmEdgeKeepsItsStamp() throws {
        var p = FilmParams.default
        p.filmEdge.framing = "anything"
        let stamp = Session.printStamp(p)
        XCTAssertFalse(stamp.contains("overscan_framing"))
        XCTAssertEqual(p.wire.filter { $0.name.hasPrefix("overscan_") || $0.name.hasPrefix("date_") }.map(\.name),
                       ["overscan_active", "date_imprint_active"])
        p.filmEdge.active = true
        XCTAssertTrue(Session.printStamp(p).hasSuffix(";overscan_framing=anything"))
    }

    /// A sidecar from before the film edge existed decodes, with both off and
    /// no seeds given yet.
    func testALegacySidecarDecodes() throws {
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Sidecar())) as! [String: Any]
        var params = legacy["params"] as! [String: Any]
        params.removeValue(forKey: "filmEdge"); params.removeValue(forKey: "dateBack")
        legacy["params"] = params
        let s = try JSONDecoder().decode(Sidecar.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertFalse(s.params.filmEdge.active)
        XCTAssertFalse(s.params.filmEdge.seeded)
        XCTAssertNil(s.heldCrop)
        // …and a round trip keeps everything this file adds.
        var edited = Sidecar()
        edited.params.filmEdge.active = true
        edited.params.filmEdge.seeded = true
        edited.params.filmEdge.frameSeed = 1234
        edited.heldCrop = Geometry(crop: CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        edited.geometry.lockedRatio = 1.5
        let back = try JSONDecoder().decode(Sidecar.self, from: JSONEncoder().encode(edited))
        XCTAssertEqual(back.params, edited.params)
        XCTAssertEqual(back.heldCrop, edited.heldCrop)
        XCTAssertEqual(back.geometry.lockedRatio, 1.5)
    }

    // MARK: - what the host resolves

    func testEdgeTextIsTheRealNameWithoutThePush() {
        let catalog = StockCatalog.shared
        XCTAssertEqual(Session.edgeText(for: catalog.stock("kodak_portra_400")), "KODAK PORTRA 400")
        XCTAssertEqual(Session.edgeText(for: catalog.stock("kodak_portra_800_push1")), "KODAK PORTRA 800")
        XCTAssertEqual(Session.edgeText(for: nil), "")
    }

    func testTheDateIsTheCaptureDayInTheChosenOrder() {
        let s = ShootingData(exif: [kCGImagePropertyExifDateTimeOriginal: "2026:10:01 14:03:22"])
        XCTAssertEqual(s.dateText(order: .japan), "'26 10 1")
        XCTAssertEqual(s.dateText(order: .us), "10 1 '26")
        XCTAssertEqual(ShootingData(exif: nil).dateText(order: .japan), "", "no EXIF date prints nothing")
        XCTAssertNil(ShootingData.day("not a date"))
    }

    func testTheDataLineIsTheCamerasOwnExposure() {
        let exif: [CFString: Any] = [
            kCGImagePropertyExifExposureTime: 1.0 / 250, kCGImagePropertyExifFNumber: 5.6,
            kCGImagePropertyExifExposureProgram: 3, kCGImagePropertyExifExposureBiasValue: 0.333,
            kCGImagePropertyExifFocalLenIn35mmFilm: 24,
            kCGImagePropertyExifISOSpeedRatings: [800],
        ]
        XCTAssertEqual(ShootingData(exif: exif).dataText, "1/250 F5.6 A +0.3 24mm",
                       "no ISO (E7), the real f-number (E8), the camera's compensation (E9)")
        // Zero compensation, missing fields, whole f-numbers, long exposures.
        let sparse: [CFString: Any] = [kCGImagePropertyExifExposureTime: 2.0,
                                       kCGImagePropertyExifFNumber: 2.0,
                                       kCGImagePropertyExifExposureBiasValue: 0.0]
        XCTAssertEqual(ShootingData(exif: sparse).dataText, "2s F2")
        XCTAssertEqual(ShootingData(exif: nil).dataText, "")
        // Every character is one the 5×7 face draws.
        let drawable = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZmvs./-+:'() ")
        XCTAssertTrue(ShootingData(exif: exif).dataText.allSatisfy(drawable.contains))
    }

    func testTheDataLineDropsFieldsFromTheRightToFit() {
        var s = ShootingData()
        s.exposureTime = 1.0 / 8000; s.fNumber = 22; s.program = 1; s.bias = -2.7; s.focal35 = 1200
        let line = s.dataText
        XCTAssertLessThanOrEqual(line.count, ShootingData.dataLineMax)
        XCTAssertEqual(line, "1/8000 F22 M -2.7", "the focal length is the one that went")
    }

    /// Film Format names the date back's camera only where that is a camera
    /// with one; elsewhere nothing is drawn rather than a 135 date guessed.
    func testTheDatesCameraComesFromFilmFormat() {
        XCTAssertEqual(Session.dateBackCamera(longMM: 36, shortMM: 24), .f135)
        XCTAssertEqual(Session.dateBackCamera(longMM: 24, shortMM: 18), .f135Half)
        XCTAssertEqual(Session.dateBackCamera(longMM: 56, shortMM: 41.5), .f645)
        XCTAssertNil(Session.dateBackCamera(longMM: 56, shortMM: 56))
        var p = FilmParams.default
        p.dateBack.active = true
        p.dateBack.camera = .f135Half
        p.filmEdge.format = .f6x7             // the film edge's format, off, is not the camera
        let wire = Dictionary(uniqueKeysWithValues: p.wire.map { ($0.name, $0.value) })
        XCTAssertEqual(wire["overscan_format"], .string("135_half"))
        p.dateBack.camera = nil
        XCTAssertFalse(p.dateBack.effective(filmEdge: p.filmEdge))
    }

    func testANewFramesSeedIsStableAndItsOwn() {
        let a = URL(fileURLWithPath: "/tmp/a/one.NEF"), b = URL(fileURLWithPath: "/tmp/a/two.NEF")
        XCTAssertEqual(Session.frameSeed(for: a), Session.frameSeed(for: a))
        XCTAssertNotEqual(Session.frameSeed(for: a), Session.frameSeed(for: b))
        XCTAssertTrue(FilmEdgeSettings.seedRange.contains(Session.frameSeed(for: a)))
        let defaults = UserDefaults(suiteName: "filmedge-\(UUID().uuidString)")!
        let body = FilmEdgeSettings.bodySeed(in: defaults)
        XCTAssertTrue(FilmEdgeSettings.bodySeedRange.contains(body))
        XCTAssertEqual(FilmEdgeSettings.bodySeed(in: defaults), body, "drawn once, then kept")
        FilmEdgeSettings.setBodySeed(42, in: defaults)
        XCTAssertEqual(FilmEdgeSettings.bodySeed(in: defaults), 42)
    }

    // MARK: - formats a stock was made in

    func testTheFormatMenuGreysFormatsAStockWasNeverMadeIn() {
        let catalog = StockCatalog.shared
        XCTAssertTrue(catalog.isMade("kodak_gold_200", in: .f135))
        XCTAssertTrue(catalog.isMade("kodak_gold_200", in: .f6x7), "Gold 200 was made in 135 and 120")
        XCTAssertTrue(catalog.isMade("kodak_ultramax_400", in: .f135Half), "a half-frame camera takes 135")
        XCTAssertFalse(catalog.isMade("kodak_ultramax_400", in: .f645))
        XCTAssertFalse(catalog.isMade("fujifilm_c200", in: .f6x6))
        XCTAssertTrue(catalog.isMade("kodak_vision3_250d", in: .f135), "35 mm motion stock loads into a 135 cassette")
        XCTAssertFalse(catalog.isMade("kodak_vision3_250d", in: .f645), "and was never made in 120")
        XCTAssertTrue(catalog.isMade("no_such_stock", in: .f6x9), "an unknown is not a no")
        XCTAssertTrue(catalog.films.allSatisfy { $0.formats != nil }, "every film has its record")
    }

    // MARK: - the crop the gate holds

    func testTheGateHoldsTheCropAtItsOwnAspect() {
        let size = CGSize(width: 6000, height: 4000)
        let held = Session.gateFramed(.default, format: .f645, imageSize: size)
        let out = held.outputSize(for: size)
        XCTAssertEqual(out.width / out.height, 56 / 41.5, accuracy: 1 / out.height)
        XCTAssertLessThanOrEqual(out.width, size.width); XCTAssertLessThanOrEqual(out.height, size.height)
        // A drag keeps it there.
        let dragged = held.resized(handle: .right, to: CGPoint(x: 0.95, y: 0.5), in: size)
        let d = dragged.outputSize(for: size)
        XCTAssertEqual(d.width / d.height, 56 / 41.5, accuracy: 2 / d.height)
        // A portrait crop gets the gate upright.
        var portrait = Geometry.default
        portrait.crop = CropRect(x: 0.3, y: 0, width: 0.4, height: 1)
        let up = Session.gateFramed(portrait, format: .f135, imageSize: size).outputSize(for: size)
        XCTAssertEqual(up.height / up.width, 1.5, accuracy: 1 / up.width)
    }

    /// The frame the engine is handed with a film edge is the crop, at the
    /// crop's own size, and the right part of the picture.
    func testTheEngineIsHandedTheCrop() throws {
        let size = CGSize(width: 400, height: 300)
        // Left half red, right half blue.
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 300))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 200, y: 0, width: 200, height: 300))
        let image = red.composited(over: blue)
        var g = Geometry.default
        g.crop = CropRect(x: 0, y: 0, width: 0.5, height: 0.5)    // top-left quarter: red
        let cut = Session.engineImage(image, size: size, cut: g)
        XCTAssertEqual(cut.extent, CGRect(x: 0, y: 0, width: 200, height: 150))
        var px = [Float](repeating: 0, count: 4)
        CIContext().render(cut, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 100, y: 75, width: 1, height: 1),
                           format: .RGBAf, colorSpace: nil)
        XCTAssertGreaterThan(px[0], 0.9); XCTAssertLessThan(px[2], 0.1)
        XCTAssertTrue(Session.engineImage(image, size: size, cut: nil) === image, "no film edge, no cut")
    }

    func testTheFilmCanvasEstimateCoversTheEngine() {
        // The engine's own figure (API-SPEC §13): a 2400×1600 135 frame renders at 2514×2333.
        let est = FilmCanvasEstimate.size(picture: CGSize(width: 2400, height: 1600), format: .f135, view: .strip)
        XCTAssertGreaterThanOrEqual(est.width, 2514); XCTAssertGreaterThanOrEqual(est.height, 2333)
        XCTAssertLessThan(est.width * est.height, 2514 * 2333 * 1.03, "an estimate, not a guess")
    }

    // MARK: - through the engine

    private func device() throws -> MTLDevice { try XCTUnwrap(MTLCreateSystemDefaultDevice()) }

    private func frame(_ w: Int, _ h: Int, device: MTLDevice) throws -> EngineFrame {
        var rgba = [Float](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) { rgba[i * 4] = 0.18; rgba[i * 4 + 1] = 0.18; rgba[i * 4 + 2] = 0.18; rgba[i * 4 + 3] = 1 }
        let space = try XCTUnwrap(ImageDecoder.linearProPhoto)
        let image = try XCTUnwrap(rgba.withUnsafeBufferPointer {
            CIImage(bitmapData: Data(buffer: $0), bytesPerRow: w * 16, size: CGSize(width: w, height: h),
                    format: .RGBAf, colorSpace: space)
        })
        return try ImageDecoder.engineFrame(from: image, device: device)
    }

    private func render(_ p: FilmParams, _ w: Int, _ h: Int) async throws -> (w: Int, h: Int, bytes: [UInt16]) {
        let gpu = try device()
        let client = EngineClient(device: gpu)
        var delta = p.fullDelta
        delta["preview_long_edge"] = .double(8192)
        let open = try await client.open(try frame(w, h, device: gpu), paramsDelta: delta)
        let out = try await client.render(.reprint, RenderRequest(sessionID: open.sessionID))
        let tex = try XCTUnwrap(out.texture)
        var bytes = [UInt16](repeating: 0, count: tex.width * tex.height * 4)
        if tex.storageMode == .shared {
            tex.getBytes(&bytes, bytesPerRow: tex.width * 8, from: MTLRegionMake2D(0, 0, tex.width, tex.height),
                         mipmapLevel: 0)
        }
        await client.stop()
        return (tex.width, tex.height, bytes)
    }

    func testFilmEdgeGrowsTheCanvasAndOffGivesTheFrameBack() async throws {
        var p = FilmParams.default
        p.grainActive = false; p.glareActive = false
        p.filmEdge.active = true
        p.filmEdge.edgeText = "KODAK PORTRA 400"
        p.filmEdge.cameraSeed = 19; p.filmEdge.frameSeed = 5
        let on = try await render(p, 600, 400)
        XCTAssertGreaterThan(on.w, 600); XCTAssertGreaterThan(on.h, 400 * 13 / 10,
                                                               "35 mm of film across a 24 mm gate")
        let est = FilmCanvasEstimate.size(picture: CGSize(width: 600, height: 400), format: .f135, view: .strip)
        XCTAssertGreaterThanOrEqual(Int(est.width), on.w); XCTAssertGreaterThanOrEqual(Int(est.height), on.h)
        p.filmEdge.active = false
        let off = try await render(p, 600, 400)
        XCTAssertEqual(off.w, 600); XCTAssertEqual(off.h, 400)
    }

    func testTheDateAloneKeepsTheSizeAndPrintsInTheCorner() async throws {
        var p = FilmParams.default
        p.grainActive = false; p.glareActive = false
        let bare = try await render(p, 600, 400)
        p.dateBack.active = true
        p.dateBack.text = "'26 10 1"
        let dated = try await render(p, 600, 400)
        XCTAssertEqual(dated.w, 600); XCTAssertEqual(dated.h, 400)
        guard !bare.bytes.allSatisfy({ $0 == 0 }) else { throw XCTSkip("the texture is not CPU-readable") }
        // Where the pixels moved: the lower right (`br`), and only there.
        var moved = 0, movedOutside = 0
        for y in 0..<400 { for x in 0..<600 {
            let i = (y * 600 + x) * 4
            if abs(Int(bare.bytes[i]) - Int(dated.bytes[i])) > 512 {
                moved += 1
                if x < 300 || y < 200 { movedOutside += 1 }
            }
        } }
        XCTAssertGreaterThan(moved, 200, "the date is a visible mark, not a rounding")
        XCTAssertEqual(movedOutside, 0, "the date is in the lower-right corner only")
    }
}
