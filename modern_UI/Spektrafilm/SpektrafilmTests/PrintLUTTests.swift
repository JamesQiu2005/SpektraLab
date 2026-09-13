//  PrintLUTTests.swift — the three methods that used to be refused by name.
//
//  `export`, `preview_stock_lut` and `export_di` were listed in
//  ARCHITECTURE §8.8 as not ported; the engine now implements all three and
//  `EngineClient` reaches them. `engine/tests/parity_lut.py` holds the
//  *numbers* against the Python reference (tables bit-exact, the apply and
//  the DI normalisation inside 8e-6). What these check is the part parity
//  cannot see: that Swift's view of the new ABI is right, that the `.cube`
//  this side writes has the ordering the cube format specifies, and that the
//  DI file is not tagged as a colour.

import ImageIO
import Metal
import XCTest

final class PrintLUTTests: XCTestCase {
    private func device() throws -> MTLDevice {
        try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
    }

    /// A frame exactly as the app hands one over: a linear ProPhoto image,
    /// rendered by `ImageDecoder.engineFrame` into a buffer on `device`.
    private func makeFrame(_ size: Int = 96, device: MTLDevice) throws -> EngineFrame {
        let width = size * 4 / 3
        var rgba = [Float](repeating: 0, count: width * size * 4)
        for y in 0..<size {
            for x in 0..<width {
                let i = (y * width + x) * 4
                rgba[i] = 0.05 + 0.5 * Float(x) / Float(width)
                rgba[i + 1] = 0.3
                rgba[i + 2] = 0.1 + 0.4 * Float(y) / Float(size)
                rgba[i + 3] = 1
            }
        }
        let space = try XCTUnwrap(ImageDecoder.linearProPhoto)
        let image = try XCTUnwrap(rgba.withUnsafeBufferPointer { buffer in
            CIImage(bitmapData: Data(buffer: buffer), bytesPerRow: width * 16,
                    size: CGSize(width: width, height: size), format: .RGBAf, colorSpace: space)
        })
        return try ImageDecoder.engineFrame(from: image, device: device)
    }

    // MARK: - the catalog and the table

    /// The eight baked LUTs are in the bundle and the app can see them.
    ///
    /// This is the assertion HANDOFF-DISTRIBUTION §1 asked for: the
    /// print-preview LUTs were deliberately *not* bundled while the three
    /// methods were unported, and porting them made bundling a requirement.
    /// An empty catalog means `engine/build.sh bundle` was not re-run, which
    /// is a build mistake this should name rather than a feature quietly
    /// disappearing.
    func testTheBakedLUTsAreBundled() async throws {
        let client = EngineClient(device: try device())
        let catalog = try await client.printLUTCatalog()
        let resources = await client.resources.path
        XCTAssertFalse(catalog.isEmpty,
                       "no print LUTs in the resources at \(resources); "
                       + "run engine/tools/bake_resources.py and engine/build.sh bundle")
        // The default paper the app opens on must be one of them, or the fast
        // flip is a feature nobody can reach from a fresh session.
        let entry = try XCTUnwrap(catalog["kodak_portra_endura"])
        XCTAssertEqual(entry.pairedFilm, "kodak_portra_400")
        XCTAssertEqual(entry.lutSize, 33)
        for (stock, e) in catalog {
            XCTAssertGreaterThan(e.lutSize, 1, "\(stock) has a degenerate LUT size")
            XCTAssertFalse(e.pairedFilm.isEmpty, "\(stock) names no paired film")
        }
        await client.stop()
    }

    /// The table crosses whole, and a stock with no LUT is refused by name
    /// rather than answered with zeros.
    ///
    /// **The values are not confined to [0, 1]**, and that surprised this
    /// test before it surprised anyone else: `kodak_portra_endura` bottoms
    /// out at -1.115 across 1056 of its 107,811 entries. The bake stores the
    /// print+scan chain's Display P3 output *unclamped*, so a print colour
    /// outside P3's gamut is a negative coordinate rather than a clipped one.
    /// Both consumers clamp — `Exporter.writeCube` on the way to the file and
    /// `spk_to_rgba16` on the way to a texture — which is what the Python
    /// reference did too. So the bar here is that nothing is NaN and the
    /// range matches the asset, not that the table is displayable.
    func testTheTableCrossesWholeAndAnUnknownStockIsRefused() async throws {
        let client = EngineClient(device: try device())
        let (size, table) = try await client.printLUTTable("kodak_portra_endura")
        XCTAssertEqual(size, 33)
        XCTAssertEqual(table.count, 33 * 33 * 33 * 3)
        XCTAssertFalse(table.contains { $0.isNaN }, "the table carries NaN")
        XCTAssertFalse(table.contains { $0.isInfinite }, "the table carries an infinity")
        // The shipped asset's own extremes, so a table read transposed, half
        // short, or widened through the wrong dtype fails here.
        XCTAssertEqual(try XCTUnwrap(table.min()), -1.115051, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(table.max()), 0.956, accuracy: 1e-5)
        do {
            _ = try await client.printLUTTable("not_a_paper")
            XCTFail("the engine invented a LUT for an unknown stock")
        } catch {
            XCTAssertTrue("\(error)".contains("not_a_paper"), "unhelpful error: \(error)")
        }
        await client.stop()
    }

    // MARK: - the `.cube` writer

    /// The cube's ordering, against the format's own rule.
    ///
    /// `.cube` is red-fastest and blue-slowest, and the table is
    /// `[r][g][b]` — so line `n` must be the entry the format says it is.
    /// Getting this wrong produces a file every host loads happily and every
    /// host grades wrongly, which is why it is checked against a table whose
    /// values *encode their own index* rather than against a shipped one.
    @MainActor func testTheCubeIsWrittenRedFastest() throws {
        let n = 4
        var table = [Float](repeating: 0, count: n * n * n * 3)
        for r in 0..<n {
            for g in 0..<n {
                for b in 0..<n {
                    let i = ((r * n + g) * n + b) * 3
                    table[i] = Float(r) / 100
                    table[i + 1] = Float(g) / 100
                    table[i + 2] = Float(b) / 100
                }
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "spk-cube-\(UUID().uuidString).cube")
        defer { try? FileManager.default.removeItem(at: url) }
        try Exporter.writeCube(table, size: n, to: url, title: "test")

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        XCTAssertEqual(lines[0], "TITLE \"test\"")
        XCTAssertEqual(lines[1], "LUT_3D_SIZE 4")
        XCTAssertTrue(lines.contains("DOMAIN_MIN 0.0 0.0 0.0"))
        XCTAssertTrue(lines.contains("DOMAIN_MAX 1.0 1.0 1.0"))
        let values = lines.dropFirst(4)
        XCTAssertEqual(values.count, n * n * n)
        for (index, line) in values.enumerated() {
            // The format's own indexing: red is the fastest axis.
            let r = index % n, g = (index / n) % n, b = index / (n * n)
            let want = String(format: "%.6f %.6f %.6f",
                              Float(r) / 100, Float(g) / 100, Float(b) / 100)
            XCTAssertEqual(line, want, "line \(index) should be (r \(r), g \(g), b \(b))")
        }
    }

    /// A malformed call fails rather than writing a truncated cube that a
    /// host would load and grade with.
    @MainActor func testACubeOfTheWrongLengthIsRefused() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "spk-cube-bad-\(UUID().uuidString).cube")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try Exporter.writeCube([0, 0, 0], size: 33, to: url, title: "x"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - the two render paths

    func testAStockPreviewComesBackAsATextureAndReportsItsPairing() async throws {
        let frameSize = 96
        let gpu = try device()
        let client = EngineClient(device: gpu)
        let open = try await client.open(try makeFrame(frameSize, device: gpu), paramsDelta: nil)
        // Warm the negative first, which is what the interactive path does.
        _ = try await client.render(.reprint, RenderRequest(sessionID: open.sessionID))

        let paired = try await client.previewStockLUT("kodak_portra_endura")
        let texture = try XCTUnwrap(paired.texture, "the preview returned no texture")
        XCTAssertEqual(texture.pixelFormat, .rgba16Unorm)
        XCTAssertEqual(texture.width, paired.width)
        XCTAssertEqual(paired.meta.lutSource, "shipped")
        XCTAssertEqual(paired.meta.applyBackend, "native-metal")
        XCTAssertEqual(paired.meta.pairedFilm, "kodak_portra_400")
        // The session's film *is* the paired one, so there is nothing to warn
        // about — and a warning that fires anyway would train the user to
        // ignore the one that matters.
        XCTAssertNil(paired.meta.warning)

        let mismatched = try await client.previewStockLUT("kodak_2383")
        XCTAssertEqual(mismatched.meta.pairedFilm, "kodak_vision3_250d")
        let warning = try XCTUnwrap(mismatched.meta.warning,
                                    "a mismatched film must warn (PRD §7.3)")
        XCTAssertTrue(warning.contains("kodak_vision3_250d"))
        await client.stop()
    }

    func testAnUnknownStockPreviewNamesWhatIsAvailable() async throws {
        let frameSize = 96
        let gpu = try device()
        let client = EngineClient(device: gpu)
        let open = try await client.open(try makeFrame(frameSize, device: gpu), paramsDelta: nil)
        _ = try await client.render(.reprint, RenderRequest(sessionID: open.sessionID))
        do {
            _ = try await client.previewStockLUT("not_a_paper")
            XCTFail("the engine previewed a stock it has no table for")
        } catch {
            let message = "\(error)"
            XCTAssertTrue(message.contains("not_a_paper"), "unhelpful error: \(message)")
            XCTAssertTrue(message.contains("kodak_portra_endura"),
                          "the refusal should say what is available: \(message)")
        }
        await client.stop()
    }

    /// The DI image is the full tier, in [0, 1], and it is *not* the print.
    func testTheDIImageIsFullResolutionAndNormalised() async throws {
        let frameSize = 96
        let gpu = try device()
        let client = EngineClient(device: gpu)
        let open = try await client.open(try makeFrame(frameSize, device: gpu), paramsDelta: nil)
        let di = try await client.exportDI()
        let texture = try XCTUnwrap(di.texture, "export_di returned no texture")
        XCTAssertEqual(di.width, open.meta.width, "the DI file must be full resolution")
        XCTAssertEqual(di.height, open.meta.height)
        XCTAssertEqual(di.meta.lutSize, 33)
        XCTAssertEqual(di.meta.printStock, "kodak_portra_endura")

        // The normalisation is what makes the cube's domain 0..1. rgba16Unorm
        // cannot hold anything outside it, so what is checked is that the
        // frame is not degenerate — a normalisation with the wrong axes
        // clamps to a flat 0 or a flat 1.
        let print = try await client.render(.reprint, RenderRequest(sessionID: open.sessionID))
        let printTexture = try XCTUnwrap(print.texture)
        let diMean = try mean(texture), printMean = try mean(printTexture)
        XCTAssertGreaterThan(diMean, 0.01, "the DI image is black")
        XCTAssertLessThan(diMean, 0.99, "the DI image is white")
        // A negative in density is not a print in Display P3. If these agree
        // the wrong tap was read.
        XCTAssertGreaterThan(abs(diMean - printMean), 0.01,
                             "the DI image looks like the print")
        await client.stop()
    }

    /// The DI TIFF is written without a rendering profile.
    ///
    /// Its channels are film densities, and a host that treats them as
    /// Display P3 and converts on open moves every value — which silently
    /// invalidates the `.cube` shipped beside it, because the cube's domain
    /// is those exact numbers.
    @MainActor func testTheDIFileIsNotTaggedAsAColour() throws {
        var bytes = [UInt16](repeating: 0, count: 8 * 8 * 4)
        for i in 0..<(8 * 8) {
            bytes[i * 4] = 20000; bytes[i * 4 + 1] = 30000
            bytes[i * 4 + 2] = 40000; bytes[i * 4 + 3] = 65535
        }
        let data = bytes.withUnsafeBufferPointer { Data(buffer: $0) }
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let cg = try XCTUnwrap(CGImage(
            width: 8, height: 8, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: 8 * 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                     | CGBitmapInfo.byteOrder16Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let url = FileManager.default.temporaryDirectory
            .appending(path: "spk-di-\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at: url) }
        try Exporter.write(cg, to: url, format: .tiff)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNil(props[kCGImagePropertyProfileName],
                     "the DI TIFF carries a colour profile: \(props[kCGImagePropertyProfileName]!)")
        let reread = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(reread.bitsPerComponent, 16, "the DI TIFF is not 16-bit")
    }

    /// The print preview rides **inside** the DI TIFF, and the densities stay
    /// untagged while it does.
    ///
    /// Two things are pinned here and both are the reason `write(preview:)`
    /// is a second page rather than `kCGImageDestinationEmbedThumbnail`:
    ///
    ///  * that key does **nothing** for TIFF. Measured, by writing the same
    ///    image with and without it: the files came out byte-identical, and
    ///    `CGImageSourceGetCount` was 1 either way. A second IFD is the
    ///    mechanism TIFF actually has;
    ///  * the preview carries a profile and IFD0 must not. That is the DI
    ///    package's whole contract — the `.cube` beside the file indexes the
    ///    density TIFF's exact numbers, and a profile on those numbers invites
    ///    whatever opens the file to convert them and move the cube's domain
    ///    out from under it.
    @MainActor func testTheDIPreviewIsEmbeddedWithoutTaggingTheDensities() throws {
        func image(_ w: Int, _ h: Int, _ space: CGColorSpace, _ v: CGFloat) throws -> CGImage {
            let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 16,
                                              bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                                                  | CGBitmapInfo.byteOrder16Little.rawValue))
            ctx.setFillColor(CGColor(colorSpace: space, components: [v, 0.4, 0.2, 1])!)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            return try XCTUnwrap(ctx.makeImage())
        }
        let density = try image(32, 32, CGColorSpaceCreateDeviceRGB(), 0.7)
        let preview = try image(16, 16, XCTUnwrap(CGColorSpace(name: CGColorSpace.rommrgb)), 0.6)

        let dir = FileManager.default.temporaryDirectory
            .appending(path: "spk-di-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appending(path: "plain.tif")
        let embedded = dir.appending(path: "embedded.tif")
        try Exporter.write(density, to: plain, format: .tiff)
        try Exporter.write(density, to: embedded, format: .tiff, preview: preview)

        let src = try XCTUnwrap(CGImageSourceCreateWithURL(embedded as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(src), 2, "the preview is not a second page")
        let first = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        let second = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 1, nil) as? [CFString: Any])
        XCTAssertNil(first[kCGImagePropertyProfileName],
                     "embedding a preview tagged the density channels")
        XCTAssertNotNil(second[kCGImagePropertyProfileName],
                        "the preview lost its own profile")
        XCTAssertEqual(second[kCGImagePropertyDepth] as? Int, 8,
                       "the preview is not 8-bit — a preview is not worth 16")
        XCTAssertEqual(first[kCGImagePropertyDepth] as? Int, 16)
        // The densities are still the densities: same pixels, same depth.
        let plainSrc = try XCTUnwrap(CGImageSourceCreateWithURL(plain as CFURL, nil))
        let a = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let b = try XCTUnwrap(CGImageSourceCreateImageAtIndex(plainSrc, 0, nil))
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.bitsPerComponent, b.bitsPerComponent)
    }


    // MARK: - the finished-export path

    /// `export` end to end, minus `Session`'s plumbing.
    ///
    /// This is the path that was **entirely broken** before this session and
    /// had no test: `Exporter` called `.export` over the wire, `EngineClient`
    /// threw `unsupported`, and every finished export failed at the first
    /// step. Nothing caught it because the export path had no coverage at
    /// all — the render tests stop at the texture, and the layout tests never
    /// press the button.
    ///
    /// So the assertion is deliberately end-to-end: a full-tier render,
    /// through Layer 2 and the geometry in Metal, into a file, read back off
    /// disk. What it does not cover is `Session.selection` and the filename,
    /// which is why `Exporter.destination` is checked separately below.
    @MainActor
    func testTheFinishedExportPathProducesAFileOnDisk() async throws {
        let frameSize = 200
        let renderer = try XCTUnwrap(Renderer(), "no renderer")
        let gpu = renderer.device
        let client = EngineClient(device: gpu)
        let open = try await client.open(try makeFrame(frameSize, device: gpu), paramsDelta: nil)

        // `.export` is the full tier, and it must be the *source's*
        // resolution: an export that quietly wrote the 1600 px live tier
        // would be a soft file nobody would question.
        let outcome = try await client.render(
            .export, RenderRequest(sessionID: open.sessionID, tier: "full"))
        let full = try XCTUnwrap(outcome.texture, "the export render returned no texture")
        XCTAssertEqual(full.width, open.meta.width)
        XCTAssertEqual(full.height, open.meta.height)

        var adjustments = Adjustments.default
        adjustments.exposure = 0.5
        let adjusted = try XCTUnwrap(renderer.applyLayer2(to: full, uniforms: adjustments.uniforms),
                                     "Layer 2 produced nothing")
        // A crop and a straighten, so the geometry stage is not a no-op —
        // the bug this replaced could not rotate at all, and a straightened
        // frame exported unstraightened with nothing saying so.
        var geometry = Geometry.default
        geometry.crop = CropRect(x: 0.1, y: 0.05, width: 0.6, height: 0.7)
        geometry.angle = 5
        let framed = try XCTUnwrap(renderer.applyGeometry(geometry, to: adjusted),
                                   "the geometry stage produced nothing")
        XCTAssertLessThan(framed.width, full.width, "the crop did not apply")

        let cg = try XCTUnwrap(framed.makeCGImage())
        let out = FileManager.default.temporaryDirectory
            .appending(path: "spk-export-\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at: out) }
        try Exporter.write(cg, to: out, format: .tiff)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        let reread = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(reread.width, framed.width)
        XCTAssertEqual(reread.height, framed.height)
        XCTAssertEqual(reread.bitsPerComponent, 16, "a TIFF export must be 16-bit")
        // A print is a colour, so unlike the DI file this one *is* tagged.
        XCTAssertNotNil(reread.colorSpace, "the print export carries no colour profile")
        await client.stop()
    }

    /// The filenames the two routes write to, and that the DI package lands in
    /// a folder of its own rather than sharing one with the finished TIFF of
    /// the same name.
    @MainActor
    func testTheExportFilenames() throws {
        var params = FilmParams.default
        params.filmStock = "kodak_portra_400"
        params.printStock = "kodak_portra_endura"
        let source = URL(fileURLWithPath: "/tmp/spk-names/_DSC2439.NEF")
        let tiff = Exporter.destination(for: source, params: params, format: .tiff)
        XCTAssertEqual(tiff.lastPathComponent,
                       "_DSC2439_kodak_portra_400_kodak_portra_endura.tif")
        XCTAssertEqual(tiff.deletingLastPathComponent().lastPathComponent, "_prints")
        let di = Exporter.destination(for: source, params: params, format: .di)
        // The DI TIFF and the finished TIFF are the **same filename** — same
        // stem, same `.tif` — and used to be written into the same folder,
        // where they collided. The package's own folder is what makes that
        // impossible: the file keeps its name, and the directory is the
        // export's.
        XCTAssertEqual(di.lastPathComponent, tiff.lastPathComponent)
        XCTAssertNotEqual(di, tiff)
        XCTAssertEqual(di.deletingLastPathComponent().lastPathComponent,
                       tiff.deletingPathExtension().lastPathComponent,
                       "the DI package is not in a folder named for the export")
        XCTAssertEqual(di.deletingLastPathComponent().deletingLastPathComponent(),
                       tiff.deletingLastPathComponent(),
                       "the package folder is not inside the recipe's own subfolder")
        // And `-1` moves the folder with the file, so a second export of the
        // same frame is one move and not two. Through a *recipe*, not through
        // `Exporter.destination`: that helper pins `.overwrite` so it stays a
        // pure function of its arguments, which is exactly the policy that
        // never consults the disk.
        let dir = tiff.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: di.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data().write(to: di)
        let context = NamingRule.Context(
            originalName: source.deletingPathExtension().lastPathComponent,
            filmStock: params.filmStock, printStock: params.printStock,
            pixelSize: .zero, counter: 1, date: Date())
        var recipe = ExportRecipe(name: "DI", format: .di)
        recipe.existing = .addSuffix
        let second = try XCTUnwrap(recipe.destination(for: source, context: context))
        XCTAssertEqual(second.deletingLastPathComponent().lastPathComponent,
                       "\(tiff.deletingPathExtension().lastPathComponent)-1")
        XCTAssertEqual(second.lastPathComponent,
                       "\(tiff.deletingPathExtension().lastPathComponent)-1.tif")
        try? FileManager.default.removeItem(at: dir)
    }

    /// The package on disk: **one folder, two files**, and the picture that
    /// used to be a third file is inside the TIFF.
    ///
    /// Everything above checks a piece — the folder rule, the writer's second
    /// IFD, the cube's ordering. This is the one that runs the route: a real
    /// frame, a real develop, `Exporter.export` with a DI recipe, and then the
    /// directory as a person would see it. It is deliberately counted rather
    /// than named: "two files and no more" is the property, and `_print.tif`
    /// coming back would be a third.
    ///
    /// Skips without the A7 III RAW, like the rest of the real-frame tests.
    @MainActor
    func testTheDIPackageIsOneFolderWithTwoFiles() async throws {
        let copy = try diFrame()
        let out = copy.deletingLastPathComponent().appending(path: "out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let session = Session()
        session.open(urls: [copy])
        try await waitUntil("the frame to decode", timeout: 120) { session.decoded != nil }
        try await waitUntil("the engine to warm up", timeout: 120) { session.serviceReady }
        session.solveNow()
        try await waitUntil("the print to land", timeout: 180) {
            session.serviceSessionIDForExport != nil && !session.busy
        }
        let sid = try XCTUnwrap(session.serviceSessionIDForExport, "nothing developed")

        var recipe = ExportRecipe(name: "DI", format: .di, folder: .fixed(path: out.path))
        recipe.subfolder = "packages"
        let context = NamingRule.Context(
            originalName: copy.deletingPathExtension().lastPathComponent,
            filmStock: session.params.filmStock, printStock: session.params.printStock,
            pixelSize: .zero, counter: 1, date: Date())
        let result = try await Exporter.export(session: session, recipe: recipe,
                                               context: context, sessionID: sid)

        // The names are `testTheExportFilenames`' business; what this checks is
        // the shape around them, so it reads the stem off the result rather
        // than re-deriving the naming rule here.
        XCTAssertEqual(result.urls.count, 2, "the package is not two files")
        let tiff = try XCTUnwrap(result.urls.first { $0.pathExtension == "tif" })
        let cube = try XCTUnwrap(result.urls.first { $0.pathExtension == "cube" })
        let package = tiff.deletingLastPathComponent()
        let listing = try FileManager.default.contentsOfDirectory(atPath: package.path).sorted()
        XCTAssertEqual(listing.count, 2, "the package folder holds \(listing)")
        XCTAssertEqual(Set(result.urls.map(\.lastPathComponent)), Set(listing),
                       "a file was written outside the package folder")
        XCTAssertEqual(package.deletingLastPathComponent().lastPathComponent, "packages",
                       "the package is not inside the recipe's own subfolder")
        let stem = tiff.deletingPathExtension().lastPathComponent
        XCTAssertEqual(package.lastPathComponent, stem,
                       "the package folder is not named for the export")
        XCTAssertEqual(cube.deletingPathExtension().lastPathComponent,
                       "\(stem)_\(session.params.printStock)",
                       "the cube is not named for the same export")

        // The preview is in the TIFF, not beside it.
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(tiff as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(src), 2,
                       "the density TIFF carries no preview page")
        let first = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        let second = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 1, nil) as? [CFString: Any])
        XCTAssertNil(first[kCGImagePropertyProfileName], "the density IFD is tagged")
        XCTAssertNotNil(second[kCGImagePropertyProfileName])
        // And it is a *preview*: a fraction of the density image's pixels, so
        // the embedded picture does not double the file.
        let dense = (first[kCGImagePropertyPixelWidth] as? Int ?? 0)
        let preview = (second[kCGImagePropertyPixelWidth] as? Int ?? 0)
        XCTAssertGreaterThan(dense, preview, "the preview is not smaller than the densities")
        session.open(urls: [])
    }

    private func diFrame() throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/Test_image/A7m3/DSC03710.ARW")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "A7m3/DSC03710.ARW is not in this checkout")
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "spk-di-package-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    @MainActor
    private func waitUntil(_ what: String, timeout: Double = 30,
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out waiting for \(what)")
        throw CancellationError()
    }

    private func mean(_ texture: MTLTexture) throws -> Double {
        let bpr = texture.width * 8
        var data = Data(count: bpr * texture.height)
        data.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: bpr,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                             mipmapLevel: 0)
        }
        var sum = 0.0
        var count = 0
        data.withUnsafeBytes { raw in
            let words = raw.bindMemory(to: UInt16.self)
            for i in stride(from: 0, to: words.count, by: 4) {
                sum += Double(words[i]) + Double(words[i + 1]) + Double(words[i + 2])
                count += 3
            }
        }
        return sum / Double(count) / 65535.0
    }
}
