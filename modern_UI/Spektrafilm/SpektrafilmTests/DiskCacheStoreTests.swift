import XCTest

final class DiskCacheStoreTests: XCTestCase {
    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "spektralab-disk-cache-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func key(_ suffix: String, version: Int = CacheKey.formatVersion) -> CacheKey {
        CacheKey(kind: .source, sourceIdentity: "source-a",
                 configuration: suffix, engineVersion: "engine-a",
                 version: version)
    }

    func testStoreAndLoadRestoresTheExactBytes() async throws {
        let store = try DiskCacheStore(root: root())
        let bytes = Data((0..<8).map(UInt8.init))
        let key = key("roundtrip")
        try await store.store(key: key, data: bytes, width: 1, height: 1,
                              format: "rgba16Unorm", costMs: 25)

        let loaded = try await store.load(key)
        let payload = try XCTUnwrap(loaded)
        XCTAssertEqual(payload.data, bytes)
        XCTAssertEqual(payload.width, 1)
        XCTAssertEqual(payload.height, 1)
        XCTAssertEqual(payload.sourceWidth, 1)
        XCTAssertEqual(payload.sourceHeight, 1)
        XCTAssertEqual(payload.format, "rgba16Unorm")
        XCTAssertEqual(payload.kind, .source)
        XCTAssertEqual(payload.hits, 1)
    }

    func testVersionAndConfigurationPerturbationsMiss() async throws {
        let store = try DiskCacheStore(root: root())
        let original = key("one")
        try await store.store(key: original, data: Data(repeating: 1, count: 8),
                              width: 1, height: 1, format: "rgba16Unorm", costMs: 1)

        let differentConfiguration = try await store.load(key("two"))
        let differentVersion = try await store.load(
            key("one", version: CacheKey.formatVersion + 1)
        )
        XCTAssertNil(differentConfiguration)
        XCTAssertNil(differentVersion)
    }

    func testSourceDimensionsSurviveARoundTrip() async throws {
        let store = try DiskCacheStore(root: root())
        let key = key("source-size")
        try await store.store(key: key, data: Data(repeating: 1, count: 8),
                              width: 1, height: 1,
                              sourceWidth: 5_504, sourceHeight: 8_256,
                              format: "rgba16Unorm", costMs: 1)

        let loaded = try await store.load(key)
        let payload = try XCTUnwrap(loaded)
        XCTAssertEqual(payload.width, 1)
        XCTAssertEqual(payload.height, 1)
        XCTAssertEqual(payload.sourceWidth, 5_504)
        XCTAssertEqual(payload.sourceHeight, 8_256)
    }

    func testCorruptEntryIsRemovedAndReportedAsAMiss() async throws {
        let root = root()
        let store = try DiskCacheStore(root: root)
        let key = key("corrupt")
        try await store.store(key: key, data: Data(repeating: 7, count: 8),
                              width: 1, height: 1, format: "rgba16Unorm", costMs: 1)
        let file = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .first { $0.pathExtension == "bin" })
        try Data([0]).write(to: file)

        let loaded = try await store.load(key)
        let total = try await store.totalBytes()
        XCTAssertNil(loaded)
        XCTAssertEqual(total, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testGDSFEvictionShedsTheLowerValueEntry() async throws {
        let store = try DiskCacheStore(root: root(), capBytes: 8)
        let expensive = key("expensive")
        let cheap = key("cheap")
        try await store.store(key: expensive, data: Data(repeating: 1, count: 8),
                              width: 1, height: 1, format: "rgba16Unorm", costMs: 100)
        try await store.store(key: cheap, data: Data(repeating: 2, count: 8),
                              width: 1, height: 1, format: "rgba16Unorm", costMs: 1)

        let expensivePayload = try await store.load(expensive)
        let cheapPayload = try await store.load(cheap)
        let total = try await store.totalBytes()
        XCTAssertNotNil(expensivePayload)
        XCTAssertNil(cheapPayload)
        XCTAssertEqual(total, 8)
    }

    /// The Settings row's whole point: lowering the cap has to take effect now,
    /// not at the next `store`. Three 8-byte entries, then a cap of 8.
    func testLoweringTheCapEvictsImmediately() async throws {
        let store = try DiskCacheStore(root: root())
        for (i, name) in ["a", "b", "c"].enumerated() {
            try await store.store(key: key(name), data: Data(repeating: UInt8(i), count: 8),
                                  width: 1, height: 1, format: "rgba16Unorm",
                                  costMs: Double(100 - i))
        }
        let before = try await store.totalBytes()
        XCTAssertEqual(before, 24)

        try await store.setCapBytes(8)
        let after = try await store.totalBytes()
        XCTAssertEqual(after, 8)
        let cap = await store.capBytes
        XCTAssertEqual(cap, 8)
    }

    /// The launch case: a store reopened against a lower cap than the one its
    /// contents were written under. Nothing writes at launch, so without the
    /// explicit trim the cache stays over its limit until the next cached
    /// render — which on a machine that is only ever opened and closed is
    /// never. Written over a *reopened* root rather than a fresh one so it is
    /// the real sequence and not a rearrangement of it.
    func testTrimToCapEvictsAStoreReopenedUnderALowerCap() async throws {
        let root = root()
        do {
            let generous = try DiskCacheStore(root: root, capBytes: 1_000)
            for (i, name) in ["a", "b", "c"].enumerated() {
                try await generous.store(key: key(name), data: Data(repeating: UInt8(i), count: 8),
                                         width: 1, height: 1, format: "rgba16Unorm",
                                         costMs: Double(100 - i))
            }
            let held = try await generous.totalBytes()
            XCTAssertEqual(held, 24)
        }

        let reopened = try DiskCacheStore(root: root, capBytes: 8)
        // The gap this test pins: construction alone evicts nothing.
        let beforeTrim = try await reopened.totalBytes()
        XCTAssertEqual(beforeTrim, 24,
                       "if construction already evicted, the assertion below cannot fail and proves nothing")
        try await reopened.trimToCap()
        let afterTrim = try await reopened.totalBytes()
        XCTAssertEqual(afterTrim, 8)
    }

    /// Raising it evicts nothing — the other direction has to be free, since
    /// the Settings stepper sends one call per press.
    func testRaisingTheCapKeepsEverything() async throws {
        let store = try DiskCacheStore(root: root(), capBytes: 16)
        try await store.store(key: key("a"), data: Data(repeating: 1, count: 8),
                              width: 1, height: 1, format: "rgba16Unorm", costMs: 10)
        try await store.setCapBytes(32)
        let total = try await store.totalBytes()
        XCTAssertEqual(total, 8)
    }

    /// "Empty cache now" takes the index rows and the files both, and leaves a
    /// store that still works afterwards.
    func testClearAllRemovesEveryEntryAndItsFile() async throws {
        let root = root()
        let store = try DiskCacheStore(root: root)
        try await store.store(key: key("a"), data: Data(repeating: 1, count: 8),
                              width: 1, height: 1, format: "rgba16Unorm", costMs: 10)
        try await store.store(key: key("b"), data: Data(repeating: 2, count: 8),
                              width: 1, height: 1, format: "rgba16Unorm", costMs: 10)

        try await store.clearAll()
        let total = try await store.totalBytes()
        XCTAssertEqual(total, 0)
        let gone = try await store.load(key("a"))
        XCTAssertNil(gone)

        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var binaries = 0
        while let file = files?.nextObject() as? URL {
            if file.pathExtension == "bin" { binaries += 1 }
        }
        XCTAssertEqual(binaries, 0)

        // Still usable: the directory and the index survived.
        try await store.store(key: key("c"), data: Data(repeating: 3, count: 8),
                              width: 1, height: 1, format: "rgba16Unorm", costMs: 10)
        let again = try await store.load(key("c"))
        XCTAssertNotNil(again)
    }

    func testGarbageCollectionDropsAFileWithoutAnIndexRow() async throws {
        let root = root()
        let store = try DiskCacheStore(root: root)
        let orphanDir = root.appending(path: "aa")
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        let orphan = orphanDir.appending(path: "orphan.bin")
        try Data([1, 2, 3]).write(to: orphan)
        let temporary = orphanDir.appending(path: "unfinished.tmp")
        try Data([4, 5, 6]).write(to: temporary)

        try await store.garbageCollect()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    }
}
