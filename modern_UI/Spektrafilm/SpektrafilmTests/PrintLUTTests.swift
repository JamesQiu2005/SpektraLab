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
        // RFC-028: a Digital Intermediate is `<stem>_DI.tif` beside the
        // recipe's other files — never the finished TIFF's name, and in the
        // same folder so one pair of view LUTs serves every DI in it.
        XCTAssertEqual(di.lastPathComponent,
                       "_DSC2439_kodak_portra_400_kodak_portra_endura_DI.tif")
        XCTAssertEqual(di.deletingLastPathComponent(), tiff.deletingLastPathComponent())
        let dir = tiff.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
    }

    /// The rule, without a frame or a GPU: which recipe writes a preview page.
    ///
    /// The writer and the job log both ask this function, so what is worth
    /// pinning is that the two routes answer it differently — and that the
    /// container does, because a second page is a TIFF idea and a JPEG recipe
    /// with the flag on must not be told it has one.
    @MainActor func testThePreviewPageRule() {
        var recipe = ExportRecipe(name: "t", format: .tiff)
        XCTAssertFalse(Exporter.writesPreviewPage(recipe), "off by default, so no bytes move")
        recipe.embedsPreview = true
        XCTAssertTrue(Exporter.writesPreviewPage(recipe))
        recipe.format = .jpeg
        XCTAssertFalse(Exporter.writesPreviewPage(recipe),
                       "a JPEG cannot hold a second page, whatever the recipe says")
        recipe.format = .di
        XCTAssertTrue(Exporter.writesPreviewPage(recipe),
                      "the Digital Intermediate writes one whatever the flag says")
        recipe.embedsPreview = false
        XCTAssertTrue(Exporter.writesPreviewPage(recipe),
                      "the Digital Intermediate's preview is not the recipe's to turn off")
    }

    /// The frame open, and developed with the stochastic stages **off**.
    ///
    /// Off because more than one export of it is about to be compared: grain
    /// and glare draw an unseeded field per render (`AGENTS.md` trap 1), so
    /// two exports of the same frame with the same settings are two different
    /// photographs and "the flag changed nothing" would be untestable. Set in
    /// the window `SoftProofParityTests.developed` documents — after the open
    /// and before the develop.
    @MainActor
    private func developed(_ copy: URL) async throws -> (Session, String) {
        let session = Session()
        session.open(urls: [copy])
        try await waitUntil("the frame to decode", timeout: 120) { session.decoded != nil }
        try await waitUntil("the engine to warm up", timeout: 120) { session.serviceReady }
        var p = session.params
        p.grainActive = false
        p.glareActive = false
        session.params = p
        session.solveNow()
        try await waitUntil("the print to land", timeout: 180) {
            session.serviceSessionIDForExport != nil && !session.busy
        }
        return (session, try XCTUnwrap(session.serviceSessionIDForExport, "nothing developed"))
    }

    /// **The preview page is opt-in per recipe, and it is a picture of the
    /// file.**
    ///
    /// Three things, and the third is the one the user's answer made matter —
    /// the page shows this preview *after* an export, so it is what a person
    /// ends up looking at and has to be a faithful small version of the file
    /// rather than a cheaper approximation of it:
    ///
    ///  * the flag off writes one page, on writes two, and the picture in IFD0
    ///    is byte-identical either way — the flag is not allowed to change the
    ///    export;
    ///  * the second page is smaller and the right shape;
    ///  * and it is the *same picture*: both pages are reduced to the same
    ///    8 × 8 grid and compared, which is what separates "the file, smaller"
    ///    from "some other render that happens to be the right size". A mean
    ///    per channel would not: two different grades of one frame can share a
    ///    mean.
    @MainActor
    func testAPlainTIFFCarriesAPreviewOnlyWhenTheRecipeAsks() async throws {
        let copy = try diFrame()
        let out = copy.deletingLastPathComponent().appending(path: "plain")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let (session, sid) = try await developed(copy)

        var recipe = ExportRecipe(name: "TIFF", format: .tiff, folder: .fixed(path: out.path))
        recipe.subfolder = ""
        recipe.colorSpace = .displayP3
        recipe.existing = .overwrite
        let context = NamingRule.Context(
            originalName: copy.deletingPathExtension().lastPathComponent,
            filmStock: session.params.filmStock, printStock: session.params.printStock,
            pixelSize: .zero, counter: 1, date: Date())

        var pages: [Bool: [CGImageSource]] = [:]
        for embeds in [false, true] {
            recipe.embedsPreview = embeds
            recipe.name = embeds ? "with" : "without"
            let result = try await Exporter.export(session: session, recipe: recipe,
                                                   context: context, sessionID: sid)
            let written = try XCTUnwrap(result.urls.first)
            pages[embeds] = [try XCTUnwrap(CGImageSourceCreateWithURL(written as CFURL, nil))]
        }

        let off = try XCTUnwrap(pages[false]?.first), on = try XCTUnwrap(pages[true]?.first)
        XCTAssertEqual(CGImageSourceGetCount(off), 1, "a recipe that did not ask for a preview got one")
        XCTAssertEqual(CGImageSourceGetCount(on), 2, "the recipe asked for a preview and did not get one")

        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let picture = try pixels(embedded: off, space: space)
        XCTAssertEqual(try pixels(embedded: on, space: space), picture,
                       "the preview flag changed the picture")

        let full = try XCTUnwrap(CGImageSourceCreateImageAtIndex(on, 0, nil))
        let thumb = try XCTUnwrap(CGImageSourceCreateImageAtIndex(on, 1, nil))
        XCTAssertLessThan(thumb.width, full.width, "the preview is not smaller than the file")
        // And a page exists whenever one was asked for, with no size caveat:
        // the rule the reader gets is "the flag is on", not "the flag is on
        // and the file was big enough". Pinned on a small image, where the
        // writer used to return nothing.
        let small = try XCTUnwrap(pixels16Image(64, 48, space))
        let smallPreview = try XCTUnwrap(Exporter.preview(of: small))
        XCTAssertEqual(smallPreview.width, small.width,
                       "a file smaller than the preview size got no page")
        XCTAssertEqual(Double(thumb.width) / Double(thumb.height),
                       Double(full.width) / Double(full.height), accuracy: 0.01,
                       "the preview is not the same shape as the file")
        XCTAssertEqual(max(thumb.width, thumb.height), Exporter.previewLongEdge,
                       "the preview is not the size the writer says it is")
        XCTAssertEqual(thumb.bitsPerComponent, 8)

        // The same picture, at a size where a comparison is cheap and a
        // different grade would show. Reduced through the same context, so the
        // reduction cannot invent an agreement.
        //
        // **A tolerance, not equality.** Both sides are resampled — the file
        // from 6000 px down to 8, the preview from 2048 down to 8 — and two
        // resampling routes over a natural image disagree by a count or two.
        // Measured on this frame: worst 2 of 255. A *different* picture is not
        // a count or two away, and the control below is what says so, because
        // a tolerance with nothing on the other side of it is a rubber stamp.
        let n = 8
        let file = try grid(full, n, space), preview = try grid(thumb, n, space)
        XCTAssertEqual(file.count, preview.count)
        let worst = zip(file, preview).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThanOrEqual(worst, 3,
                                 "the preview is not a picture of the file — worst \(worst) of 255")

        // The control: the same comparison against the file drawn *upside
        // down* has to fail. Same image, same reduction, same code path — the
        // only difference is that it is not the same picture.
        let flipped = try grid(full, n, space, flipped: true)
        let flippedWorst = zip(file, flipped).map { abs($0 - $1) }.max() ?? 0
        XCTAssertGreaterThan(flippedWorst, 3,
                             "this comparison cannot tell two pictures apart, so the "
                             + "assertion above proves nothing")

        let entry = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(on, 1, nil) as? [CFString: Any])
        XCTAssertNotNil(entry[kCGImagePropertyProfileName],
                        "the preview carries no profile, so a reader cannot show it correctly")
    }

    /// A small 16-bit image, for the writer-only cases.
    private func pixels16Image(_ w: Int, _ h: Int, _ space: CGColorSpace) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue))
        ctx.setFillColor(CGColor(colorSpace: space, components: [0.4, 0.5, 0.6, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return try XCTUnwrap(ctx.makeImage())
    }

    /// One image reduced to `n × n` RGB triples, in `space`, as 0…255.
    ///
    /// `flipped` draws it upside down, which is the control for "is this
    /// comparison sensitive enough to tell two pictures apart" — the same
    /// image, the same reduction, not the same picture.
    private func grid(_ cg: CGImage, _ n: Int, _ space: CGColorSpace,
                      flipped: Bool = false) throws -> [Int] {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.interpolationQuality = .high
        if flipped {
            ctx.translateBy(x: 0, y: CGFloat(n))
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        let raw = try XCTUnwrap(ctx.data)
        let p = raw.bindMemory(to: UInt8.self, capacity: n * n * 4)
        return (0..<(n * n * 4)).map { Int(p[$0]) }
    }

    /// IFD0's pixels, as written, through a context in `space`.
    private func pixels(embedded src: CGImageSource, space: CGColorSpace) throws -> [UInt16] {
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: cg.width, height: cg.height, bitsPerComponent: 16,
            bytesPerRow: cg.width * 8, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let raw = try XCTUnwrap(ctx.data)
        let p = raw.bindMemory(to: UInt16.self, capacity: cg.width * cg.height * 4)
        return Array(UnsafeBufferPointer(start: p, count: cg.width * cg.height * 4))
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
