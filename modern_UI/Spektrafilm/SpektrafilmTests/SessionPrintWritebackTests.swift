import XCTest

@MainActor
final class SessionPrintWritebackTests: XCTestCase {
    private func frames() throws -> (URL, URL) {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "tests/Test_image/_smoke_1mp.tif")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "the 1 MP smoke frame is not in this checkout")
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "spk-print-writeback-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let first = dir.appending(path: "first.tif")
        let second = dir.appending(path: "second.tif")
        try FileManager.default.copyItem(at: source, to: first)
        try FileManager.default.copyItem(at: source, to: second)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (first, second)
    }

    private func diagnostics() throws -> Diagnostics {
        let name = "spk-print-writeback-defaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return Diagnostics(defaults: defaults)
    }

    private func waitUntil(_ what: String, timeout: Double = 90,
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out waiting for \(what)")
    }

    func testFrameSwitchPersistsTheLivePrintForFreshSessionRestore() async throws {
        let (firstURL, secondURL) = try frames()
        let store = try DiskCacheStore(
            root: FileManager.default.temporaryDirectory
                .appending(path: "spk-print-writeback-store-\(UUID().uuidString)")
        )
        let firstDiagnostics = try diagnostics()
        let first = Session(diagnostics: firstDiagnostics, diskCache: store)
        first.open(urls: [firstURL])
        try await waitUntil("the frame to decode") { first.decoded != nil }
        try await waitUntil("the engine to warm up") { first.serviceReady }
        first.solveNow()
        try await waitUntil("the print to land") {
            first.frameStates[firstURL] == .processed && !first.busy
        }

        let original = try XCTUnwrap(first.renderer.store.print(for: firstURL))
        let bytes = original.rgba16Bytes()
        let version = firstDiagnostics.engineVersion ?? "unknown"
        let key = Session.printCacheKey(
            url: firstURL,
            params: first.scheduler.sent,
            tier: .live,
            previewLongEdge: first.previewLongEdge,
            engineVersion: version
        )

        first.select(secondURL)
        let deadline = Date().addingTimeInterval(15)
        var payload = try await store.load(key)
        while payload == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            payload = try await store.load(key)
        }
        let stored = try XCTUnwrap(payload)
        XCTAssertEqual(stored.data, bytes, "the writeback changed the print bytes")

        let secondDiagnostics = try diagnostics()
        secondDiagnostics.noteCapabilities(json: nil, version: version)
        let second = Session(diagnostics: secondDiagnostics, diskCache: store)
        second.open(urls: [firstURL])
        try await waitUntil("the print to restore") {
            second.renderer.store.print(for: firstURL) != nil
        }
        let restored = try XCTUnwrap(second.renderer.store.print(for: firstURL))
        XCTAssertEqual(restored.rgba16Bytes(), bytes)
        XCTAssertEqual(second.decodeCount, 0,
                       "the restored print decoded a frame before it was needed")
    }
}
