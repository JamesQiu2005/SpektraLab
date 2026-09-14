import Metal
import XCTest

final class PrintWritebackTests: XCTestCase {
    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "filmify-print-writeback-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func key(_ suffix: String, kind: CacheKind = .printLive) -> CacheKey {
        CacheKey(kind: kind, sourceIdentity: "source-a", configuration: suffix,
                 tier: kind == .printFull ? .full : .live,
                 previewLongEdge: kind == .printLive ? 1600 : nil,
                 engineVersion: "engine-a")
    }

    private func texture(device: MTLDevice, bytes: [UInt8]) throws -> MTLTexture {
        let store = TextureStore(device: device)
        let texture = try XCTUnwrap(store.makeWritable(width: 2, height: 1))
        texture.replace(region: MTLRegionMake2D(0, 0, 2, 1), mipmapLevel: 0,
                        withBytes: bytes, bytesPerRow: 16)
        return texture
    }

    func testOverflowDropsOldestAndDrainRestoresEveryRemainingByte() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let store = try DiskCacheStore(root: root())
        let writeback = PrintWriteback(store: store, maxStagedBytes: 32)

        let firstBytes = [UInt8](repeating: 0x11, count: 16)
        let secondBytes = [UInt8](repeating: 0x22, count: 16)
        let thirdBytes = [UInt8](repeating: 0x33, count: 16)
        let first = try texture(device: device, bytes: firstBytes)
        let second = try texture(device: device, bytes: secondBytes)
        let third = try texture(device: device, bytes: thirdBytes)
        await writeback.enqueue(StagedPrint(
            key: key("one"), texture: first,
            sourceWidth: 5_504, sourceHeight: 8_256, costMs: 10
        ))
        await writeback.enqueue(StagedPrint(
            key: key("two"), texture: second,
            sourceWidth: 5_504, sourceHeight: 8_256, costMs: 20
        ))
        await writeback.enqueue(StagedPrint(
            key: key("three"), texture: third,
            sourceWidth: 5_504, sourceHeight: 8_256, costMs: 30
        ))

        let dropped = await writeback.droppedCount
        let queued = await writeback.queuedCount
        XCTAssertEqual(dropped, 1)
        XCTAssertEqual(queued, 2)

        await writeback.drain()
        let restoredOne = try await store.load(key("one"))
        let restoredTwo = try await store.load(key("two"))
        let restoredThree = try await store.load(key("three"))
        XCTAssertNil(restoredOne, "the oldest staged entry was not dropped")
        XCTAssertEqual(restoredTwo?.data, Data(secondBytes))
        XCTAssertEqual(restoredThree?.data, Data(thirdBytes))

        await writeback.drain()
        let total = try await store.totalBytes()
        XCTAssertEqual(total, 32, "a second drain rewrote the same entries")
    }
}
