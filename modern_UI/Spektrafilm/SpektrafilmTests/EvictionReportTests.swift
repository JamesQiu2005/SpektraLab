import XCTest

final class EvictionReportTests: XCTestCase {
    func testBetweenSampleEvictionsDrainExactlyOnceAndThenReset() {
        let arena = MemoryArena()
        arena.observe(
            sample: MemorySample(seq: 1, at: Date(), footprintBytes: 1,
                                 peakBytes: 1, freeBytes: 1_000),
            reserve: 0,
            cap: 100
        )

        _ = arena.admitCache(bytes: 60, kind: "print_live", costMs: 1, evict: {})
        _ = arena.admitCache(bytes: 60, kind: "print_live", costMs: 1, evict: {})
        _ = arena.admitCache(bytes: 60, kind: "print_live", costMs: 1, evict: {})

        let first = arena.takeEvictionReport()
        XCTAssertEqual(first.bytes, 120)
        XCTAssertEqual(first.kinds["print_live"], 120)
        let second = arena.takeEvictionReport()
        XCTAssertEqual(second, .init())
    }

    func testMultipleEnforcementBatchesAccumulateIntoOneReport() {
        let arena = MemoryArena()
        arena.observe(
            sample: MemorySample(seq: 1, at: Date(), footprintBytes: 1,
                                 peakBytes: 1, freeBytes: 1_000),
            reserve: 0,
            cap: 1_000
        )
        _ = arena.admitCache(bytes: 60, kind: "full", costMs: 1, evict: {})
        _ = arena.admitCache(bytes: 60, kind: "full", costMs: 1, evict: {})
        arena.observe(
            sample: MemorySample(seq: 2, at: Date(), footprintBytes: 1,
                                 peakBytes: 1, freeBytes: 1_000),
            reserve: 0,
            cap: 70
        )

        XCTAssertEqual(
            arena.enforce(
                sample: MemorySample(seq: 4, at: Date(), footprintBytes: 1,
                                     peakBytes: 1, freeBytes: 1_000),
                reserve: 0,
                cap: 70
            ),
            60
        )
        XCTAssertEqual(
            arena.enforce(
                sample: MemorySample(seq: 3, at: Date(), footprintBytes: 1,
                                     peakBytes: 1, freeBytes: 0),
                reserve: 70,
                cap: 70
            ),
            60
        )

        let report = arena.takeEvictionReport()
        XCTAssertEqual(report.bytes, 120)
        XCTAssertEqual(report.kinds["full"], 120)
        XCTAssertEqual(arena.takeEvictionReport(), .init())
    }
}
