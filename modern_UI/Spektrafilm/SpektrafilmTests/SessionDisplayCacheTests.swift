import XCTest

@MainActor
final class SessionDisplayCacheTests: XCTestCase {
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
            .appending(path: "spk-display-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    private func freshDiagnostics() throws -> Diagnostics {
        let name = "spk-display-defaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return Diagnostics(defaults: defaults)
    }

    private func cacheRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "spk-display-store-\(UUID().uuidString)")
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

    func testDisplayHitRestoresRGBAWithoutBecomingLinearDecodeData() async throws {
        let url = try smokeFrame()
        let diagnostics = try freshDiagnostics()
        let store = try DiskCacheStore(root: cacheRoot())
        let session = Session(diagnostics: diagnostics, diskCache: store)
        // Every disk-cache key carries the engine version, and warm-up
        // publishes it from a detached task. Wait for the real one rather than
        // planting a stub and racing it: a stub only survived while the lookup
        // beat warm-up, so this test passed on a cold process and failed once
        // enough earlier tests had warmed the engine. See `Session.awaitBoot`.
        try await waitUntil("warm-up to publish the engine version") {
            diagnostics.engineVersion != nil
        }
        let engineVersion = try XCTUnwrap(diagnostics.engineVersion)

        let pixels = Data([
            0x00, 0x00, 0x80, 0xff, 0x00, 0x00, 0xff, 0xff,
            0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x80, 0x80,
        ])
        let key = Session.displayCacheKey(
            url: url,
            settings: DecodeSettings(),
            previewLongEdge: session.previewLongEdge,
            engineVersion: engineVersion
        )
        try await store.store(
            key: key,
            data: pixels,
            width: 2,
            height: 1,
            sourceWidth: 5_504,
            sourceHeight: 8_256,
            format: "rgba16Unorm",
            costMs: 485
        )

        session.open(urls: [url])
        try await waitUntil("the display cache to land") {
            session.displayCacheHitCount == 1
        }
        XCTAssertNil(session.lastDisplayCacheMiss,
                     "the open did not use the planted entry; the lookup stopped at this step")

        let texture = try XCTUnwrap(session.renderer.store.source(for: url))
        XCTAssertEqual(texture.width, 2)
        XCTAssertEqual(texture.height, 1)
        XCTAssertEqual(texture.rgba16Bytes(), pixels)
        XCTAssertEqual(session.sourceLongEdge, 8_256)
        XCTAssertNil(session.decoded,
                     "an RGBA display entry must not satisfy the linear decode contract")
        XCTAssertEqual(session.decodeCount, 0,
                       "a display-cache hit constructed a CIRAWFilter and decoded the frame")

        session.requestPrint()
        try await waitUntil("the linear decode on demand", timeout: 30) {
            session.decodeCount == 1 && session.decoded != nil
        }
    }
}
