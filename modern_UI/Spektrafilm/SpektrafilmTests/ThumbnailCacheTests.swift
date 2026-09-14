import ImageIO
import XCTest

private final class DecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func record(_ maxPixel: Int) {
        lock.withLock { values.append(maxPixel) }
    }

    var count: Int { lock.withLock { values.count } }
}

private struct ImageBox: @unchecked Sendable {
    let image: CGImage
}

private actor DecodeGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var result: CheckedContinuation<ImageBox?, Never>?

    func decode() async -> CGImage? {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return await withCheckedContinuation { result = $0 }?.image
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish(_ image: CGImage) {
        result?.resume(returning: ImageBox(image: image))
        result = nil
    }
}

private func makeImage(width: Int, height: Int,
                       red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

private func firstPixel(_ image: CGImage) -> (Int, Int, Int) {
    var bytes = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &bytes, width: 1, height: 1,
                        bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
}

final class ThumbnailCacheTests: XCTestCase {
    func testCacheAndInFlightKeysIncludeMaxPixel() async throws {
        let counter = DecodeCounter()
        let cache = ThumbnailCache(decoder: { _, maxPixel in
            counter.record(maxPixel)
            return makeImage(width: maxPixel, height: 2, red: 1, green: 0, blue: 0)
        })
        let url = URL(fileURLWithPath: "/tmp/thumbnail-sizes.nef")

        let smallValue = await cache.thumbnail(for: url, maxPixel: 32)
        let largeValue = await cache.thumbnail(for: url, maxPixel: 64)
        let small = try XCTUnwrap(smallValue)
        let large = try XCTUnwrap(largeValue)
        XCTAssertEqual(small.width, 32)
        XCTAssertEqual(large.width, 64)
        XCTAssertEqual(counter.count, 2)

        _ = await cache.thumbnail(for: url, maxPixel: 32)
        _ = await cache.thumbnail(for: url, maxPixel: 64)
        XCTAssertEqual(counter.count, 2)
    }

    func testByteCapEvictsAndAllowsRecomputation() async throws {
        let counter = DecodeCounter()
        let cache = ThumbnailCache(byteLimit: 700, decoder: { _, maxPixel in
            counter.record(maxPixel)
            return makeImage(width: 10, height: 10, red: 1, green: 0, blue: 0)
        })
        let first = URL(fileURLWithPath: "/tmp/thumbnail-first.nef")
        let second = URL(fileURLWithPath: "/tmp/thumbnail-second.nef")

        _ = await cache.thumbnail(for: first, maxPixel: 10)
        _ = await cache.thumbnail(for: second, maxPixel: 10)
        XCTAssertEqual(cache.cachedCount, 1)
        XCTAssertLessThanOrEqual(cache.cachedBytes, 700)

        let before = counter.count
        _ = await cache.thumbnail(for: first, maxPixel: 10)
        _ = await cache.thumbnail(for: second, maxPixel: 10)
        XCTAssertGreaterThan(counter.count, before)
    }

    func testProcessedThumbnailReplacesEmbeddedSizes() async throws {
        let embedded = makeImage(width: 8, height: 8, red: 1, green: 0, blue: 0)
        let processed = makeImage(width: 8, height: 8, red: 0, green: 1, blue: 0)
        let cache = ThumbnailCache(decoder: { _, _ in embedded })
        let url = URL(fileURLWithPath: "/tmp/thumbnail-processed.nef")

        let beforeValue = await cache.thumbnail(for: url, maxPixel: 8)
        let before = try XCTUnwrap(beforeValue)
        XCTAssertEqual(firstPixel(before).0, 255)
        cache.store(processed, for: url)
        let afterValue = await cache.thumbnail(for: url, maxPixel: 64)
        let after = try XCTUnwrap(afterValue)
        XCTAssertGreaterThan(firstPixel(after).1, 240)
        XCTAssertLessThan(firstPixel(after).0, 15)
    }

    func testClearRejectsLateDetachedResult() async throws {
        let gate = DecodeGate()
        let delayed = makeImage(width: 8, height: 8, red: 1, green: 0, blue: 0)
        let cache = ThumbnailCache(decoder: { _, _ in await gate.decode() })
        let url = URL(fileURLWithPath: "/tmp/thumbnail-late.nef")

        let task = Task { await cache.thumbnail(for: url, maxPixel: 32) }
        await gate.waitUntilStarted()
        cache.clear()
        await gate.finish(delayed)

        let late = await task.value
        XCTAssertNil(late)
        XCTAssertEqual(cache.cachedCount, 0)
    }

    func testArenaPressureEvictsThumbnailHolding() async throws {
        let arena = MemoryArena()
        arena.observe(sample: MemorySample(seq: 1, at: Date(), footprintBytes: 1,
                                           peakBytes: 1, freeBytes: 1_000_000_000),
                      reserve: 0, cap: .max)
        let cache = ThumbnailCache(arena: arena, decoder: { _, _ in
            makeImage(width: 10, height: 10, red: 1, green: 0, blue: 0)
        })
        _ = await cache.thumbnail(for: URL(fileURLWithPath: "/tmp/thumbnail-arena.nef"),
                                   maxPixel: 10)
        XCTAssertEqual(arena.breakdown().first { $0.kind == "thumbnails" }?.count, 1)

        let sample = MemorySample(seq: 2, at: Date(), footprintBytes: 1,
                                  peakBytes: 1, freeBytes: 1_000_000_000)
        _ = arena.enforce(sample: sample, reserve: 0, cap: 0)
        XCTAssertEqual(cache.cachedCount, 0)
        XCTAssertNil(arena.breakdown().first { $0.kind == "thumbnails" })
    }
}

@MainActor
final class ThumbnailSessionResetTests: XCTestCase {
    func testSessionOpenStartsANewThumbnailGeneration() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "filmify-thumbnail-reset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            ThumbnailCache.shared.clear()
            try? FileManager.default.removeItem(at: dir)
        }

        let urls = try (0..<2).map { i -> URL in
            let url = dir.appending(path: "frame-\(i).png")
            let image = makeImage(width: 8, height: 8, red: 1, green: 0, blue: 0)
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
                url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return url
        }

        ThumbnailCache.shared.clear()
        ThumbnailCache.shared.store(makeImage(width: 8, height: 8,
                                              red: 0, green: 1, blue: 0),
                                    for: urls[0])
        XCTAssertEqual(ThumbnailCache.shared.cachedCount, 1)

        Session().open(urls: urls)
        XCTAssertEqual(ThumbnailCache.shared.cachedCount, 0)
    }
}
