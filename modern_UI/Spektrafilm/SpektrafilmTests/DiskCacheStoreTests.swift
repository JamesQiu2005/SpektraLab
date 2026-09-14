import XCTest

final class DiskCacheStoreTests: XCTestCase {
    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "filmify-disk-cache-\(UUID().uuidString)")
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
