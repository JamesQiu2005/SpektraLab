//  FramePipelineTests.swift — the single-flight, cancellable frame pipeline
//  (IMP §3, step 1).
//
//  This pins the mechanisms that make a frame switch able to stop the work
//  it started, which a pixel test cannot see:
//
//  - a job superseded before its body runs never runs it — the first
//    checkpoint throws, and `jobsSkipped` counts it;
//  - a running job whose generation is superseded stops at its next
//    checkpoint instead of running to completion;
//  - the awaiting task's own cancellation reaches a running job the same
//    way, through the cancellation handler;
//  - the serial queue means two submitted jobs never overlap.
//
//  The PRD's repeat defect is a guard that cannot fire (IMPL §3.7, AGENTS
//  trap 16), so these tests exercise the guards, not just the happy path.

import XCTest

final class FramePipelineTests: XCTestCase {

    /// A lock-protected Bool the test thread reads while the work runs on the
    /// pipeline's own queue.
    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func setTrue() { lock.withLock { value = true } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
    }

    private final class ConcurrentTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private var maxActive = 0
        var maxConcurrent: Int { lock.withLock { maxActive } }
        func enter() { lock.withLock { active += 1; maxActive = max(maxActive, active) } }
        func exit() { lock.withLock { active -= 1 } }
    }

    /// A job whose generation was superseded before it started never runs its
    /// body: the first checkpoint throws, `jobsSkipped` counts it, and the
    /// caller sees `CancellationError` rather than a result.
    func testASupersededJobNeverRunsItsBody() async throws {
        let pipeline = FramePipeline()
        let stale = pipeline.supersede()          // generation 1
        _ = pipeline.supersede()                  // generation 2 — 1 is stale
        let ran = LockedFlag()
        do {
            _ = try await pipeline.run(generation: stale) { _ in ran.setTrue() }
            XCTFail("a superseded job must throw, not run its body")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(ran.isSet, "the superseded job's body ran")
        XCTAssertEqual(pipeline.jobsSkipped, 1)
        XCTAssertEqual(pipeline.jobsRun, 0)
    }

    /// A running job whose generation is superseded mid-work stops at its next
    /// checkpoint: the loop below only exits through the checkpoint throwing,
    /// so once superseded it must return `CancellationError` and the counter
    /// must stop advancing.
    func testSupersedingMidWorkStopsTheJobAtItsNextCheckpoint() async throws {
        let pipeline = FramePipeline()
        let gen = pipeline.supersede()
        let counter = Counter()
        let work = Task {
            try await pipeline.run(generation: gen) { checkpoint in
                while true {
                    counter.increment()
                    try checkpoint()
                    usleep(1000)
                }
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while counter.count < 2 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertGreaterThan(counter.count, 0, "the work never started")
        _ = pipeline.supersede()                  // supersede while it is running
        do {
            _ = try await work.value
            XCTFail("a superseded job must throw CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let stoppedAt = counter.count
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(counter.count, stoppedAt, "the work kept running after supersede")
    }

    /// Cancelling the awaiting task reaches the running job the same way the
    /// generation does: the cancellation handler sets the flag the checkpoint
    /// reads, and the job stops at its next checkpoint.
    func testCancellingTheAwaitingTaskStopsTheWork() async throws {
        let pipeline = FramePipeline()
        let gen = pipeline.supersede()
        let counter = Counter()
        let work = Task {
            try await pipeline.run(generation: gen) { checkpoint in
                while true {
                    counter.increment()
                    try checkpoint()
                    usleep(1000)
                }
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while counter.count < 2 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertGreaterThan(counter.count, 0, "the work never started")
        work.cancel()
        do {
            _ = try await work.value
            XCTFail("a cancelled job must throw CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let stoppedAt = counter.count
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(counter.count, stoppedAt, "the work kept running after cancellation")
    }

    /// The serial queue means two submitted jobs never run concurrently — the
    /// second waits for the first, however many are submitted. This is the
    /// property that replaced "up to five decodes per click".
    func testTwoSubmittedJobsNeverRunConcurrently() async throws {
        let pipeline = FramePipeline()
        let gen = pipeline.supersede()
        let tracker = ConcurrentTracker()
        let first = Task {
            try await pipeline.run(generation: gen) { checkpoint in
                tracker.enter()
                try checkpoint()
                usleep(30_000)
                try checkpoint()
                tracker.exit()
            }
        }
        let second = Task {
            try await pipeline.run(generation: gen) { checkpoint in
                tracker.enter()
                try checkpoint()
                usleep(30_000)
                try checkpoint()
                tracker.exit()
            }
        }
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(tracker.maxConcurrent, 1, "two pipeline jobs overlapped")
    }
}