import XCTest
import CoreGraphics
import ImageIO
import Metal

@MainActor
final class PerformanceRegressionTests: XCTestCase {
    func testPendingWhiteBalanceDoesNotReopenTheNextPhoto() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wb-switch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Sidecar.useStore(at: dir.appending(path: "sidecars"))
        defer { Sidecar.useStore(at: nil); try? FileManager.default.removeItem(at: dir) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.3, alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: 32,height: 32))
        let image = try XCTUnwrap(context.makeImage())
        let a = dir.appending(path: "a.png"), b = dir.appending(path: "b.png")
        try Exporter.write(image, to: a, format: .png); try Exporter.write(image, to: b, format: .png)
        let session = Session()
        func waitForDecode(_ url: URL) async throws {
            let end = Date().addingTimeInterval(20)
            while session.decoded?.sourceURL != url {
                if Date() > end { throw NSError(domain: "decode timeout", code: 1) }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        session.open(urls: [a,b]); session.select(a)
        try await waitForDecode(a)
        let before = session.decodeCount
        session.setTemperature(6000)
        session.select(b)
        try await waitForDecode(b)
        // Observe beyond the old pending reopen's 350 ms boundary.
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(session.selection,b)
        XCTAssertEqual(session.decodeCount,before + 1,"An old WB debounce must not decode the next photo twice")
        session.flushSave(); await session.client.stop()
    }
    func testTIFFCompressionRecipeMigrationAndRoundTrip() throws {
        let legacy = try JSONDecoder().decode(ExportRecipe.self, from: Data("{}".utf8))
        // 1.3.6 keeps an old recipe writing what it always wrote.
        XCTAssertEqual(legacy.tiffCompression, .lzw)
        var recipe = ExportRecipe()
        recipe.tiffCompression = .lzw
        XCTAssertEqual(try JSONDecoder().decode(ExportRecipe.self,
            from: JSONEncoder().encode(recipe)).tiffCompression, .lzw)
    }

    func testFastTIFFPreserves16BitPixelsProfileAndEXIF() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        // Every channel has nonzero low bits, so an accidental 8-bit conversion fails.
        var words: [UInt16] = []
        for i in 0..<(17 * 9 * 4) {
            words.append(i % 4 == 3 ? UInt16.max : UInt16((i * 197) % 65536))
        }
        let data = words.withUnsafeBytes { Data($0) }
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(CGImage(width: 17, height: 9, bitsPerComponent: 16,
            bitsPerPixel: 64, bytesPerRow: 17 * 8, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
                .union(.byteOrder16Little), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var decoded: [Data] = []
        for codec in TIFFCompression.allCases {
            let url = dir.appending(path: "\(codec.rawValue).tif")
            try Exporter.write(image, to: url, format: .tiff, tiffCompression: codec,
                preview: image, sourceEXIF: [kCGImagePropertyExifExposureTime: 0.125])
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let loaded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(CGImageSourceGetCount(source), 2)
            XCTAssertEqual(loaded.bitsPerComponent, 16)
            XCTAssertEqual(loaded.width, 17); XCTAssertEqual(loaded.height, 9)
            XCTAssertEqual(loaded.colorSpace?.name, space.name)
            XCTAssertEqual((props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFCompression] as? Int, codec.rawValue)
            XCTAssertEqual((props[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifExposureTime] as? Double, 0.125)
            decoded.append(try XCTUnwrap(loaded.dataProvider?.data) as Data)
        }
        XCTAssertEqual(decoded[0], decoded[1], "Storage choice must not change any decoded pixel")
    }
    func testUnrelatedPhotosNeverProbeHistoricalPaths() {
        let wanted = Sidecar.Source(path: "/new", volumeID: 1, inode: 5001, size: 100)
        var probes = 0
        for n in 0..<5000 {
            let old = Sidecar.Source(path: "/old/\(n)", volumeID: 1, inode: n, size: 100)
            XCTAssertFalse(Sidecar.isRelocationCandidate(old, for: wanted) { _ in probes += 1; return true })
        }
        XCTAssertEqual(probes, 0, "Unrelated identities must not touch 5,000 historical paths")
    }
    func testMovedPhotoStillRequiresOldPathToBeGone() {
        let source = Sidecar.Source(path: "/old", volumeID: 1, inode: 5, size: 100)
        let moved = Sidecar.Source(path: "/new", volumeID: 1, inode: 5, size: 100)
        XCTAssertTrue(Sidecar.isRelocationCandidate(source, for: moved) { _ in false })
        XCTAssertFalse(Sidecar.isRelocationCandidate(source, for: moved) { _ in true })
    }
    func testBackgroundDetailYieldsToEditsAndBatchExport() {
        XCTAssertFalse(Session.allowsBackgroundFullRender(batchExporting: true, editPending: false))
        XCTAssertFalse(Session.allowsBackgroundFullRender(batchExporting: false, editPending: true))
        XCTAssertTrue(Session.allowsBackgroundFullRender(batchExporting: false, editPending: false))
    }
    func testCancelledRenderDoesNotStartTheEngine() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let client = EngineClient(device: device, resources: URL(fileURLWithPath: "/nonexistent-spk-resources"))
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await client.render(.reprint, RenderRequest(sessionID: "cancelled", tier: "full"))
                XCTFail("Cancelled render should not run")
            } catch is CancellationError {
            } catch { XCTFail("Cancelled work reached the engine: \(error)") }
        }
        await task.value
    }

    func testWriterRunsOffMainThreadAndPreservesPixels() async throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8,
            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        let image = try XCTUnwrap(ctx.makeImage())
        let url = FileManager.default.temporaryDirectory.appending(path: "spk-worker-\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at: url) }
        try await Exporter.writeInBackground(image, to: url, format: .tiff) {
            XCTAssertFalse(Thread.isMainThread, "ImageIO encoding must not block the UI")
        }
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let loaded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(loaded.width, 32); XCTAssertEqual(loaded.height, 16)
        let original = try XCTUnwrap(image.dataProvider?.data)
        let actual = try XCTUnwrap(loaded.dataProvider?.data)
        // ImageIO may change the unused alpha byte; compare the colour channels.
        let a = CFDataGetBytePtr(original)!, b = CFDataGetBytePtr(actual)!
        for y in 0..<16 { for x in 0..<32 { for c in 0..<3 {
            XCTAssertEqual(a[y * image.bytesPerRow + x * 4 + c], b[y * loaded.bytesPerRow + x * 4 + c])
        } } }
    }
}
