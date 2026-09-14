import XCTest

@MainActor
final class PrintCacheTests: XCTestCase {
    private func smokeFrame() throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "tests/Test_image/_smoke_1mp.tif")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "the 1 MP smoke frame is not in this checkout")
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "spk-print-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    private func diagnostics() throws -> Diagnostics {
        let name = "spk-print-defaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return Diagnostics(defaults: defaults)
    }

    private func waitUntil(_ what: String, timeout: Double = 10,
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("timed out waiting for \(what)")
    }

    func testStoredPrintRestoresExactBytesWithoutDecoding() async throws {
        let url = try smokeFrame()
        let diagnostics = try diagnostics()
        diagnostics.noteCapabilities(json: nil, version: "print-test-engine")
        let store = try DiskCacheStore(
            root: FileManager.default.temporaryDirectory
                .appending(path: "spk-print-store-\(UUID().uuidString)")
        )
        let session = Session(diagnostics: diagnostics, diskCache: store)
        let pixels = Data([
            0x00, 0x00, 0x80, 0xff, 0x00, 0x00, 0xff, 0xff,
            0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x80, 0x80,
        ])
        let key = Session.printCacheKey(
            url: url,
            params: FilmParams.default,
            tier: .live,
            previewLongEdge: session.previewLongEdge,
            engineVersion: "print-test-engine"
        )
        try await store.store(
            key: key,
            data: pixels,
            width: 2,
            height: 1,
            sourceWidth: 5_504,
            sourceHeight: 8_256,
            format: "rgba16Unorm",
            costMs: 1_188
        )

        session.open(urls: [url])
        try await waitUntil("the print cache to land") {
            session.renderer.store.print(for: url) != nil
        }

        let texture = try XCTUnwrap(session.renderer.store.print(for: url))
        XCTAssertEqual(texture.rgba16Bytes(), pixels)
        XCTAssertFalse(session.previewSoft, "a restored print was marked as a soft decode")
        XCTAssertEqual(session.sourceLongEdge, 8_256)
        XCTAssertNil(session.decoded,
                     "the print cache synthesized scene-linear data")
        XCTAssertEqual(session.decodeCount, 0,
                       "restoring a print decoded the RAW again")
    }

    func testEngineVersionPerturbationMissesThePrint() async throws {
        let url = try smokeFrame()
        let diagnostics = try diagnostics()
        diagnostics.noteCapabilities(json: nil, version: "new-engine")
        let store = try DiskCacheStore(
            root: FileManager.default.temporaryDirectory
                .appending(path: "spk-print-version-store-\(UUID().uuidString)")
        )
        let session = Session(diagnostics: diagnostics, diskCache: store)
        let key = Session.printCacheKey(
            url: url,
            params: FilmParams.default,
            tier: .live,
            previewLongEdge: session.previewLongEdge,
            engineVersion: "old-engine"
        )
        try await store.store(
            key: key,
            data: Data(repeating: 0x7f, count: 16),
            width: 2,
            height: 1,
            sourceWidth: 5_504,
            sourceHeight: 8_256,
            format: "rgba16Unorm",
            costMs: 1_188
        )

        session.open(urls: [url])
        try await waitUntil("the engine-version miss to decode") {
            session.decodeCount == 1
        }
        XCTAssertNil(session.renderer.store.print(for: url),
                     "a print made by a different engine version was restored")
    }
}
