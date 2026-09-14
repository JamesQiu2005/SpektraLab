import XCTest

final class CachePolicyTests: XCTestCase {
    /// **Seen red** by removing `costMs` from the formula: full and live
    /// collapsed to the same value and the ordering assertion failed.
    func testGDSFRanksTheMeasuredCostNotTheAge() {
        let live = gdsfPriority(hits: 1, costMs: 1188, bytes: 38_000_000, clock: 0)
        let decode = gdsfPriority(hits: 1, costMs: 485, bytes: 38_000_000, clock: 0)
        let full = gdsfPriority(hits: 1, costMs: 1860, bytes: 364_000_000, clock: 0)

        XCTAssertLessThan(full, decode)
        XCTAssertLessThan(decode, live)
    }

    func testCacheValueHitRaisesPriority() {
        var value = CacheValue(costMs: 100, bytes: 10_000_000, lastUsed: 0)
        let cold = value.priority(clock: 0)
        value.hit(at: 5)
        value.hit(at: 6)
        XCTAssertGreaterThan(value.priority(clock: 0), cold)
        XCTAssertEqual(value.lastUsed, 6)
    }

    func testCacheKeyPerturbationsMiss() {
        let base = CacheKey(kind: .printLive, sourceIdentity: "file-a",
                            configuration: "params-a", tier: .live,
                            previewLongEdge: 2678, engineVersion: "engine-a")
        XCTAssertNotEqual(base, CacheKey(kind: .printFull, sourceIdentity: "file-a",
                                         configuration: "params-a", tier: .full,
                                         previewLongEdge: 2678, engineVersion: "engine-a"))
        XCTAssertNotEqual(base, CacheKey(kind: .printLive, sourceIdentity: "file-a",
                                         configuration: "params-b", tier: .live,
                                         previewLongEdge: 2678, engineVersion: "engine-a"))
        XCTAssertNotEqual(base, CacheKey(kind: .printLive, sourceIdentity: "file-a",
                                         configuration: "params-a", tier: .live,
                                         previewLongEdge: 2678, engineVersion: "engine-b"))
        XCTAssertNotEqual(base, CacheKey(kind: .printLive, sourceIdentity: "file-a",
                                         configuration: "params-a", tier: .live,
                                         previewLongEdge: 2678, engineVersion: "engine-a",
                                         version: CacheKey.formatVersion + 1))
    }

    func testArenaEvictsTheLowerGDSFValue() {
        let arena = MemoryArena()
        arena.observe(sample: MemorySample(seq: 1, at: Date(), footprintBytes: 1,
                                           peakBytes: 1, freeBytes: 1_000_000_000),
                      reserve: 0, cap: .max)
        _ = arena.admitCache(bytes: 60_000_000, kind: "print_full",
                             costMs: 600, evict: {})
        _ = arena.admitCache(bytes: 40_000_000, kind: "print_live",
                             costMs: 4, evict: {})

        let sample = MemorySample(seq: 2, at: Date(), footprintBytes: 1,
                                  peakBytes: 1, freeBytes: 1_000_000_000)
        XCTAssertEqual(arena.enforce(sample: sample, reserve: 0, cap: 70_000_000),
                       40_000_000)
        XCTAssertEqual(arena.totalBytes, 60_000_000)
        XCTAssertNil(arena.breakdown().first { $0.kind == "print_live" })
        XCTAssertEqual(arena.breakdown().first { $0.kind == "print_full" }?.bytes,
                       60_000_000)
    }
}
