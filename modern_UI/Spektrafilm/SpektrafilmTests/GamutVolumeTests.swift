//  GamutVolumeTests.swift — RFC-018 §7.2: does a ProPhoto export carry
//  ProPhoto gamut?
//
//  This is the measurement §4.3 was argued from: "a wide-gamut export cannot
//  be wide — the `TIFF 16-bit — ProPhoto` recipe converts P3-limited pixels
//  into a ProPhoto container. The picker reads as a choice of gamut; it is a
//  choice of box."
//
//  **The two arms differ in exactly one thing: which space the engine's CAM16
//  compression aimed at.** Both use the same decode, the same renderer, the
//  same Layer 2, the same geometry and the same output transform, with the
//  same target — the recipe's space, ProPhoto. The "before" is the engine
//  pinned to `output_color_space: "Display P3"`, which was literally
//  `spk_open`'s convention until this RFC and is how §7.5's control rebuilt the
//  old tier numbers. Nothing here re-renders through a stale code path.
//
//  **Two grades, because the box only shows when something pushes against it.**
//  With Layer 2 neutral the answer is a property of the scan, not of the RFC:
//  film colour that already fits in Display P3 cannot demonstrate that ProPhoto
//  buys anything. The second configuration is §7.4's — saturation at the top —
//  and that is the case §4.3 is about.
//
//  **What is measured is the pixels, not the profile.** Each file is read back
//  off disk, its 16-bit values decoded to linear light, and carried into
//  Display P3 by the *engine's own* matrix (over `spk_output_transform`, the
//  same one the product uses). Two mechanisms run and are compared: that direct
//  linear-cube test, and the transform kernel's own `outsideFraction`
//  (`d > 1`, CAM16 chroma against the target's cube). They measure the same
//  fact by different means, and agreement is the point of reporting both.
//
//  Grain and glare are off, for §7.6's reason.
//
//  **Cost: about three minutes** — two arms × two grades, each a full-tier
//  render and a full-tier transform, then four 24-megapixel occupancy scans.
//  It skips entirely without the A7 III RAW.

import CoreGraphics
import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest

@MainActor
final class GamutVolumeTests: XCTestCase {

    private func frame() throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/Test_image/A7m3/DSC03710.ARW")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "A7m3/DSC03710.ARW is not in this checkout")
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-gamut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    // MARK: - the files

    private struct Written {
        let url: URL
    }

    /// One arm: the engine in one output space, written out at one grade.
    ///
    /// The tail is `Exporter.exportPrint`'s chain, written out because it is
    /// private and because writing it once here is what makes the arms provably
    /// the same code with one variable between them.
    private func arm(_ decoded: DecodedImage, pinnedTo: String?, uniforms: Layer2Uniforms,
                     target: CGColorSpace, into dir: URL, label: String,
                     gpu: MTLDevice, renderer: Renderer, client: EngineClient) async throws -> Written {
        var delta: [String: ParamValue] = ["grain_active": .bool(false), "glare_active": .bool(false)]
        if let pinnedTo { delta["output_color_space"] = .string(pinnedTo) }
        let frame = try ImageDecoder.engineFrame(from: decoded, device: gpu)
        let open = try await client.open(frame, paramsDelta: delta)
        let workingSpace = open.params["output_color_space"]?.stringValue ?? "?"
        XCTAssertEqual(workingSpace, pinnedTo ?? "ProPhoto RGB", "\(label): the engine resolved another space")

        let rendered = try await client.render(.export,
                                               RenderRequest(sessionID: open.sessionID, tier: "full"))
        let full = try XCTUnwrap(rendered.texture)
        let adjusted = try XCTUnwrap(renderer.applyLayer2(to: full, uniforms: uniforms))
        let framed = renderer.applyGeometry(.default, to: adjusted) ?? adjusted
        let (setup, problem) = await ColourManagement.setup(client: client, source: workingSpace,
                                                            target: target, device: gpu)
        let transform = try XCTUnwrap(setup, "\(label): \(problem ?? "no setup")")
        let converted = try XCTUnwrap(renderer.applyOutputTransform(to: framed, setup: transform))
        let cg = try XCTUnwrap(converted.texture.makeCGImage(space: target))

        let url = dir.appending(path: "\(label).tif")
        try write(cg, to: url)
        return Written(url: url)
    }

    private func write(_ cg: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         UTType.tiff.identifier as CFString, 1, nil)
        else { throw XCTSkip("no TIFF writer") }
        CGImageDestinationAddImage(dest, cg, [kCGImagePropertyTIFFDictionary:
                                                [kCGImagePropertyTIFFCompression: 5]] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("write failed") }
    }

    // MARK: - what the file's pixels occupy

    private struct Occupancy {
        var pixels = 0
        var outside = 0
        var cells = 0
        var cellsOutside = 0
        var lowest = Double.greatestFiniteMagnitude
        var highest = -Double.greatestFiniteMagnitude
        var outsideFraction: Double { pixels == 0 ? 0 : Double(outside) / Double(pixels) }
    }

    /// The file's own 16-bit values → linear light → the target's linear RGB by
    /// the engine's matrix, and what that lands on.
    ///
    /// The decode is ROMM's, three lines, **ported from
    /// `engine/src/shaders/nodes.metal`'s `cctf_decode_mode` case 1** rather
    /// than re-derived. This is measurement code, and it is cross-checked
    /// against the engine's own answer for the same file below, so a wrong
    /// curve here shows up as a disagreement rather than as a number nobody
    /// questions.
    ///
    /// The grid is 64³ over the destination cube with a quarter either side.
    /// **A cell counts as outside only when the whole cell is outside** — its
    /// near edge beyond 1, or its far edge below 0 — because a pixel sitting
    /// exactly on the cube face legitimately occupies a cell that straddles it,
    /// and calling that "volume outside" is the metric being wrong rather than
    /// the file.
    private func occupy(_ cg: CGImage, matrix: Mat9f, n: Int = 64) throws -> Occupancy {
        let w = cg.width, h = cg.height
        var px = [UInt16](repeating: 0, count: w * h * 4)
        let info = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        let ctx = try XCTUnwrap(CGContext(data: &px, width: w, height: h, bitsPerComponent: 16,
                                          bytesPerRow: w * 8,
                                          space: cg.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: info))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var o = Occupancy()
        o.pixels = w * h
        let lo = -0.25, span = 1.5, step = span / Double(n)
        var seen = [Bool](repeating: false, count: n * n * n)

        for i in stride(from: 0, to: px.count, by: 4) {
            var v = [0.0, 0.0, 0.0]
            for c in 0..<3 {
                let e = Double(px[i + c]) / 65535.0
                v[c] = e < 16.0 * (1.0 / 512.0) ? e / 16.0 : pow(e, 1.8)   // ROMM, verbatim
            }
            let rgb = [Double(matrix.0) * v[0] + Double(matrix.1) * v[1] + Double(matrix.2) * v[2],
                       Double(matrix.3) * v[0] + Double(matrix.4) * v[1] + Double(matrix.5) * v[2],
                       Double(matrix.6) * v[0] + Double(matrix.7) * v[1] + Double(matrix.8) * v[2]]

            // `slack` is not a fudge: a pixel the old chain clipped to exactly
            // the P3 face comes back through P3 → ProPhoto → P3 as ±1e-7, and
            // counting that would make the before arm fail on its own
            // round-trip rounding rather than on its gamut. The pushed arm's
            // excursions are percent, so the slack cannot hide them.
            var outside = false
            for c in rgb {
                o.lowest = min(o.lowest, c)
                o.highest = max(o.highest, c)
                if c < -1e-4 || c > 1 + 1e-4 { outside = true }
            }
            if outside { o.outside += 1 }

            let idx = rgb.map { Int(($0 - lo) / span * Double(n)) }
            if idx.allSatisfy({ (0..<n).contains($0) }) {
                let cell = (idx[0] * n + idx[1]) * n + idx[2]
                if !seen[cell] {
                    seen[cell] = true
                    o.cells += 1
                    let edges = idx.map { (Double($0) * step + lo, Double($0 + 1) * step + lo) }
                    if edges.contains(where: { $0.0 > 1.0 || $0.1 < 0.0 }) { o.cellsOutside += 1 }
                }
            }
        }
        return o
    }

    private func readBack(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    // MARK: - §7.2

    func testTheProPhotoExportCarriesProPhotoGamut() async throws {
        let url = try frame()
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-gamut-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let proPhoto = try XCTUnwrap(CGColorSpace(name: CGColorSpace.rommrgb))
        let p3 = ImageDecoder.displayP3
        let gpu = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(Renderer(device: gpu))
        let client = EngineClient(device: gpu)
        defer { Task { await client.stop() } }
        let decoded = try ImageDecoder.decode(url, settings: DecodeSettings())

        var pushed = Adjustments()
        pushed.saturation = 100                      // the slider's top — §7.4's grade
        let grades = [("neutral", Adjustments().uniforms), ("pushed", pushed.uniforms)]

        // Two arms × two grades. The neutral ones share a render and the pushed
        // ones share a render, because the grade is applied after the engine
        // and the only thing that moves between arms is the pin.
        var files: [String: Written] = [:]
        for (gradeName, uniforms) in grades {
            let before = try await arm(decoded, pinnedTo: "Display P3", uniforms: uniforms, target: proPhoto,
                                       into: dir, label: "before-\(gradeName)",
                                       gpu: gpu, renderer: renderer, client: client)
            let after = try await arm(decoded, pinnedTo: nil, uniforms: uniforms, target: proPhoto,
                                      into: dir, label: "after-\(gradeName)",
                                      gpu: gpu, renderer: renderer, client: client)
            files["before-\(gradeName)"] = before
            files["after-\(gradeName)"] = after
        }

        // The engine's own ProPhoto → Display P3 matrix: the product's numbers,
        // not a second colour library's.
        let (p3Setup, p3Problem) = await ColourManagement.setup(client: client, source: "ProPhoto RGB",
                                                                target: p3, device: gpu)
        let toP3 = try XCTUnwrap(p3Setup, "\(p3Problem ?? "no setup")")

        var lines: [String] = []
        var occ: [String: Occupancy] = [:]
        for key in ["before-neutral", "after-neutral", "before-pushed", "after-pushed"] {
            let written = try XCTUnwrap(files[key])
            let o = try occupy(try readBack(written.url), matrix: toP3.uniforms.matrix)
            occ[key] = o
            lines.append("  " + key.padding(toLength: 16, withPad: " ", startingAt: 0)
                         + " outside P3 \(o.outside) of \(o.pixels)"
                         + " (\(String(format: "%.5f", o.outsideFraction * 100)) %)"
                         + ", linear \(String(format: "%+.4f", o.lowest))…\(String(format: "%.4f", o.highest))"
                         + ", cells \(o.cells) (outside \(o.cellsOutside))")
        }
        print("§7.2 — a 16-bit ProPhoto export of a 24 MP frame, read back off disk"
              + " (grain and glare off):\n" + lines.joined(separator: "\n"))

        let beforeNeutral = try XCTUnwrap(occ["before-neutral"])
        let afterNeutral = try XCTUnwrap(occ["after-neutral"])
        let beforePushed = try XCTUnwrap(occ["before-pushed"])
        let afterPushed = try XCTUnwrap(occ["after-pushed"])

        // §4.3's claim, on the grade that can show it: the old chain wrote a
        // P3 box whatever the container; the new one does not.
        XCTAssertEqual(beforePushed.outside, 0,
                       "the pushed before-file carries colour outside P3 — the pin did not reconstruct it")
        XCTAssertEqual(beforePushed.cellsOutside, 0, "the pushed before-file occupies volume outside P3")
        XCTAssertGreaterThan(afterPushed.outsideFraction, 0.0005,
                             "a saturation-pushed ProPhoto export does not exceed P3 by 0.05 % — "
                             + "see this test's header for what that would mean")

        // And the neutral grade is a fact about the scan rather than about the
        // RFC, so it is asserted as measured: a print of this frame with no
        // push is essentially inside Display P3.
        XCTAssertEqual(beforeNeutral.outside, 0, "the neutral before-file exceeds P3")
        XCTAssertLessThan(afterNeutral.outsideFraction, 0.001,
                          "the neutral after-file exceeds P3 by more than a tenth of a percent")

        // The second mechanism, asked the **same question of the same pixels**:
        // the file read back, through the transform, with Display P3 as the
        // target — so its `outsideFraction` is "outside P3" and not "outside
        // the recipe's space", which is a different set and a different input.
        //
        // `outsideFraction` is `d > 1`, and `d = Mp / Cmax` is read after the
        // **lightness compression** has already moved the pixel
        // (`gamut.metal`: the `lc` block runs before the table lookup, so
        // `Cmax` is the cube's capacity at the lightness the pixel is about to
        // be moved *to*). In principle that makes the kernel's count a superset
        // of "outside the cube"; measured here it makes no difference, because
        // the lightness compression only fires above `Jp / white > 0.7` and
        // this frame is a dim indoor scene. Both configurations are run so the
        // next reader gets the check rather than the argument.
        let (lcOffSetup, lcProblem) = await ColourManagement.setup(
            client: client, source: "ProPhoto RGB", target: p3, device: gpu,
            gamutCompress: #"{"lightness_compression_active": false}"#)
        let lcOff = try XCTUnwrap(lcOffSetup, "\(lcProblem ?? "-")")
        XCTAssertEqual(lcOff.uniforms.cam16Lightness, 0, "the lightness compression is still on")
        XCTAssertEqual(lcOff.uniforms.cam16Active, 1, "the compression itself was switched off too")

        for key in ["after-neutral", "after-pushed"] {
            let written = try XCTUnwrap(files[key])
            let linear = try XCTUnwrap(occ[key]).outsideFraction
            let noLC = try kernelOutside(written.url, setup: lcOff, gpu: gpu, renderer: renderer)
            let withLC = try kernelOutside(written.url, setup: toP3, gpu: gpu, renderer: renderer)
            print(String(format: "  %@ — outside P3: linear-cube test %.5f %%, kernel %.5f %% "
                         + "(lightness compression off), %.5f %% (on)",
                         key, linear * 100, noLC * 100, withLC * 100))
            XCTAssertEqual(noLC, linear, accuracy: max(linear * 0.5, 1e-5),
                           "\(key): the CAM16 chroma test and the linear-cube test disagree — "
                           + "they are the same question asked two ways")
        }
    }

    /// The same file's pixels through one more transform, reporting the
    /// kernel's own `outsideFraction` — the second mechanism, over the same
    /// pixels, so the only thing that differs is how the question is asked.
    private func kernelOutside(_ file: URL, setup: OutputTransformSetup,
                               gpu: MTLDevice, renderer: Renderer) throws -> Double {
        let cg = try readBack(file)
        let w = cg.width, h = cg.height
        var px = [UInt16](repeating: 0, count: w * h * 4)
        let info = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        let ctx = try XCTUnwrap(CGContext(data: &px, width: w, height: h, bitsPerComponent: 16,
                                          bytesPerRow: w * 8,
                                          space: cg.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: info))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        let tex = try XCTUnwrap(renderer.store.makeWritable(width: w, height: h))
        px.withUnsafeBytes {
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                        withBytes: $0.baseAddress!, bytesPerRow: w * 8)
        }
        let converted = try XCTUnwrap(renderer.applyOutputTransform(to: tex, setup: setup))
        return converted.stats.outsideFraction
    }
}
