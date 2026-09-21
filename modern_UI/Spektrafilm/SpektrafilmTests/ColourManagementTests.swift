//  ColourManagementTests.swift — the working space, and the one conversion
//  out of it.
//
//  RFC-018. Two things are worth testing here and the rest of the RFC's
//  verification is measurement, not assertion:
//
//  1. **The uniform block is the one the shader reads.** A mismatch between
//     `OutputTransformUniforms` in Swift and in MSL is not a crash and not a
//     `nil`; it is a picture converted with somebody else's numbers, and the
//     numbers are plausible enough to read as a grade. So the layout is
//     pinned, and the transform is driven end to end on a colour whose answer
//     can be derived by hand.
//  2. **Colour arrives where it should.** The transform's whole job is that a
//     working-space grey stays grey and a saturated colour is rolled into the
//     destination rather than cut at its face. Both are checked against
//     numbers derived outside this code, not against the code's own output.

import CoreGraphics
import Metal
import XCTest

@MainActor
final class ColourManagementTests: XCTestCase {
    private func device() throws -> MTLDevice {
        try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
    }

    // MARK: - the uniform block

    /// The block `outputTransform` reads.
    ///
    /// 9 + 9 + 9 + 22 floats = 196 bytes, then 8 `uint`s = 32, so 228. The
    /// parts are pinned separately because when this does go wrong the useful
    /// question is *which* field moved.
    func testTheUniformBlockIsTheSizeTheShaderReads() {
        XCTAssertEqual(MemoryLayout<Float>.stride, 4)
        XCTAssertEqual(MemoryLayout<Mat9f>.stride, 36, "a 3×3 of Float32")
        XCTAssertEqual(MemoryLayout<K22f>.stride, 88, "the 22 CAM16 scalars")
        XCTAssertEqual(MemoryLayout<OutputTransformUniforms>.stride, 228)
    }

    // MARK: - naming

    /// The five catalogue built-ins the engine has a baked colour space for,
    /// and nothing else.
    ///
    /// This is the *whole* of what the app may convert to, and it is
    /// deliberately short: an installed ICC profile is a file, and no baked
    /// colour space answers to it even when the two describe the same
    /// primaries. Returning a name for one of those would be a conversion
    /// built from different numbers than the profile the user picked.
    func testTheEngineNamesFiveBuiltInsAndNoOthers() throws {
        XCTAssertEqual(ColourManagement.engineName(for: CGColorSpace(name: CGColorSpace.displayP3)!), "Display P3")
        XCTAssertEqual(ColourManagement.engineName(for: CGColorSpace(name: CGColorSpace.sRGB)!), "sRGB")
        XCTAssertEqual(ColourManagement.engineName(for: CGColorSpace(name: CGColorSpace.adobeRGB1998)!), "Adobe RGB (1998)")
        XCTAssertEqual(ColourManagement.engineName(for: CGColorSpace(name: CGColorSpace.rommrgb)!), "ProPhoto RGB")
        XCTAssertEqual(ColourManagement.engineName(for: CGColorSpace(name: CGColorSpace.itur_2020)!), "ITU-R BT.2020")
        // Deliberately not in the list: the catalogue offers these two, and
        // the engine has no baked space for either.
        XCTAssertNil(ColourManagement.engineName(for: CGColorSpace(name: CGColorSpace.linearSRGB)!))
        XCTAssertNil(ColourManagement.engineName(for: CGColorSpaceCreateDeviceRGB()))
    }

    // MARK: - the conversion, end to end

    /// A working-space grey is still grey in the destination.
    ///
    /// The derivation, which is what makes this a test rather than a
    /// transcript: ROMM mid-grey is linear 0.18 at its own whitepoint (D50);
    /// a neutral has no chroma for CAM16 to move, so the only things acting
    /// are the ROMM → linear decode, the D50 → D65 adaptation (which maps the
    /// neutral to the neutral), and Display P3's sRGB-like encode:
    ///
    ///     0.18 through the sRGB OETF = 1.055·0.18^(1/2.4) − 0.055 = 0.4614
    ///
    /// — which is `Layer2Uniforms.srgbMidGrey`, the same number Decision D1
    /// turns on. If the matrix were transposed (AGENTS.md trap 20) or the
    /// modes swapped, this is the assertion that would say so, because a
    /// transposed matrix does not send a neutral to a neutral.
    func testAWorkingSpaceGreyArrivesAsADisplayGrey() async throws {
        let gpu = try device()
        let client = EngineClient(device: gpu)
        defer { Task { await client.stop() } }
        let renderer = try XCTUnwrap(Renderer(device: gpu))
        let (setup, problem) = await ColourManagement.setup(client: client, source: "ProPhoto RGB",
                                                            target: ImageDecoder.displayP3, device: gpu,
                                                            gamutCompress: nil)
        let transform = try XCTUnwrap(setup, "no setup: \(problem ?? "-")")

        // A 2×2 of ROMM-encoded mid-grey, read straight back off the GPU.
        let grey = Float(Layer2Uniforms.proPhotoMidGrey)
        let src = try XCTUnwrap(renderer.store.makeWritable(width: 2, height: 2))
        var px = [UInt16](repeating: 0, count: 4 * 4)
        for i in 0..<4 {
            px[i * 4] = UInt16(grey * 65535); px[i * 4 + 1] = px[i * 4]
            px[i * 4 + 2] = px[i * 4]; px[i * 4 + 3] = 65535
        }
        px.withUnsafeBytes {
            src.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0,
                        withBytes: $0.baseAddress!, bytesPerRow: 16)
        }

        let out = try XCTUnwrap(renderer.applyOutputTransform(to: src, setup: transform))
        var read = [UInt16](repeating: 0, count: 4)
        out.texture.getBytes(&read, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        let got = read.prefix(3).map { Double($0) / 65535 }

        for c in got {
            XCTAssertEqual(c, Double(Layer2Uniforms.srgbMidGrey), accuracy: 0.004,
                           "mid-grey did not survive the conversion: \(got)")
        }
        XCTAssertEqual(got[0], got[1], accuracy: 0.004, "the neutral picked up a cast")
        XCTAssertEqual(got[1], got[2], accuracy: 0.004)

        // A neutral is inside every one of these containers, so nothing was
        // outside the destination and nothing is sitting on a limit.
        XCTAssertEqual(out.stats.outsideFraction, 0, accuracy: 1e-6)
        XCTAssertEqual(out.stats.clippedFraction, 0, accuracy: 1e-6)
        // And the counter RFC-018 §5.3 names reads **1.0**, on a frame of pure
        // grey. Not a bug in the count: the session's default knee is
        // `(0.0, 1.0, 6.0)` — the reference calls it "a gentle, always-on
        // roll-off" — so `d > threshold` is true for every pixel with any
        // chroma whatsoever. Pinned here so that the number the export page
        // must *not* use for its warning is the number somebody finds when
        // they go looking for it.
        XCTAssertEqual(out.stats.movedFraction, 1.0, accuracy: 1e-6,
                       "the always-on knee stopped being always-on")
    }

    /// The engine already has the render's one lightness compression.
    ///
    /// `Pipeline::print_linear` runs CAM16 into the **working space** before the
    /// output CCTF, so the ProPhoto pixels the app receives have already been
    /// through the lightness shoulder. The export transform converts those
    /// pixels into the recipe's space; asking for the engine's transform default
    /// here applies that shoulder a second time, which is invisible in the
    /// canvas but compresses highlights in every app export.
    ///
    /// The simulated engine pass is explicit rather than assumed: it calls the
    /// same transform with `nil`, which is the engine's default. The app-facing
    /// setup must then match the same transform with lightness compression
    /// explicitly off, while still doing CAM16's chroma mapping.
    func testTheExportTransformDoesNotRepeatTheEnginesLightnessCompression() async throws {
        let gpu = try device()
        let client = EngineClient(device: gpu)
        defer { Task { await client.stop() } }
        let renderer = try XCTUnwrap(Renderer(device: gpu))
        ColourManagement.forgetCached()

        let encoded: [Float] = [0.35, 0.50, 0.65, 0.75, 0.85, 0.92, 0.97, 1.0]
        let src = try XCTUnwrap(renderer.store.makeWritable(width: encoded.count, height: 1))
        var px = [UInt16](repeating: 0, count: encoded.count * 4)
        for (i, value) in encoded.enumerated() {
            let v = UInt16((value * 65535).rounded())
            px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v; px[i * 4 + 3] = 65535
        }
        px.withUnsafeBytes {
            src.replace(region: MTLRegionMake2D(0, 0, encoded.count, 1), mipmapLevel: 0,
                        withBytes: $0.baseAddress!, bytesPerRow: encoded.count * 8)
        }

        let proPhoto = try XCTUnwrap(CGColorSpace(name: CGColorSpace.rommrgb))
        let (engineSetup, engineProblem) = await ColourManagement.setup(
            client: client, source: "ProPhoto RGB", target: proPhoto, device: gpu,
            gamutCompress: nil)
        let engineTransform = try XCTUnwrap(engineSetup, "\(engineProblem ?? "-")")
        let engineOut = try XCTUnwrap(renderer.applyOutputTransform(to: src, setup: engineTransform))
            .texture

        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let (exportSetup, exportProblem) = await ColourManagement.setup(
            client: client, source: "ProPhoto RGB", target: p3, device: gpu)
        let export = try XCTUnwrap(exportSetup, "\(exportProblem ?? "-")")
        let (controlSetup, controlProblem) = await ColourManagement.setup(
            client: client, source: "ProPhoto RGB", target: p3, device: gpu,
            gamutCompress: #"{"lightness_compression_active": false}"#)
        let control = try XCTUnwrap(controlSetup, "\(controlProblem ?? "-")")

        XCTAssertEqual(export.uniforms.cam16Lightness, 0,
                       "the export transform has the lightness shoulder on again")
        XCTAssertEqual(export.uniforms.cam16Active, 1,
                       "the gamut mapping itself was switched off, not just its lightness stage")

        let exported = try XCTUnwrap(renderer.applyOutputTransform(to: engineOut, setup: export))
            .texture
        let controlled = try XCTUnwrap(renderer.applyOutputTransform(to: engineOut, setup: control))
            .texture
        var a = [UInt16](repeating: 0, count: encoded.count * 4)
        var b = [UInt16](repeating: 0, count: encoded.count * 4)
        exported.getBytes(&a, bytesPerRow: encoded.count * 8,
                          from: MTLRegionMake2D(0, 0, encoded.count, 1), mipmapLevel: 0)
        controlled.getBytes(&b, bytesPerRow: encoded.count * 8,
                            from: MTLRegionMake2D(0, 0, encoded.count, 1), mipmapLevel: 0)
        XCTAssertEqual(a, b, "the export compressed highlights after the engine already did")
    }

    /// A colour ProPhoto can hold and sRGB cannot comes out of sRGB
    /// **compressed**, not pinned to the cube face — which is RFC-018 §4.4's
    /// whole claim, and the one thing the old Core Graphics path could not do.
    ///
    /// The frame is far outside sRGB on purpose: ROMM primaries are the widest
    /// space this app has, so ROMM red is the largest target a gamut map can
    /// be asked to roll in. Both counters move — pixels the map moved, and
    /// pixels still on a limit — and the assertion is that the first is large
    /// and the second is **zero**, because a roll-off that leaves a population
    /// pinned at 0 or 1 is a clip with extra steps.
    func testAWideGamutColourIsRolledIntoSRGBRatherThanCut() async throws {
        let gpu = try device()
        let client = EngineClient(device: gpu)
        defer { Task { await client.stop() } }
        let renderer = try XCTUnwrap(Renderer(device: gpu))
        let sRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let (setup, problem) = await ColourManagement.setup(client: client, source: "ProPhoto RGB",
                                                            target: sRGB, device: gpu)
        let transform = try XCTUnwrap(setup, "no setup: \(problem ?? "-")")

        // Pure ROMM red (1, 0, 0 in *linear* terms, encoded), which is well
        // outside sRGB's red primary.
        let src = try XCTUnwrap(renderer.store.makeWritable(width: 4, height: 4))
        var px = [UInt16](repeating: 0, count: 4 * 4 * 4)
        for i in 0..<16 {
            px[i * 4] = 65535; px[i * 4 + 3] = 65535
        }
        px.withUnsafeBytes {
            src.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0,
                        withBytes: $0.baseAddress!, bytesPerRow: 32)
        }

        let out = try XCTUnwrap(renderer.applyOutputTransform(to: src, setup: transform))
        var read = [UInt16](repeating: 0, count: 4)
        out.texture.getBytes(&read, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)

        XCTAssertEqual(out.stats.outsideFraction, 1.0, accuracy: 1e-6,
                       "a colour outside sRGB was not reported as outside it")
        XCTAssertEqual(out.stats.clippedFraction, 0, "a rolled-off colour left pixels on the cube face")
        // Rolled in means *not* the corner: sRGB red is (1, 0, 0), and the
        // green and blue channels should have picked up some of it.
        XCTAssertLessThan(Double(read[0]) / 65535, 1.0)
        XCTAssertGreaterThan(Double(read[1]) / 65535, 0.0)
    }

    /// A destination the engine does not know is **refused by name**, not
    /// substituted (RFC-018 §5.2).
    func testAnUnknownDestinationIsRefusedRatherThanReplaced() async throws {
        let gpu = try device()
        let client = EngineClient(device: gpu)
        defer { Task { await client.stop() } }
        do {
            _ = try await client.outputTransform(src: "ProPhoto RGB", dst: "Nonexistent RGB")
            XCTFail("the engine converted to a colour space it does not have")
        } catch {
            let message = EngineMessage.technical(error)
            XCTAssertTrue(message.contains("Nonexistent RGB"), "the failure does not name the space: \(message)")
        }
    }
}
