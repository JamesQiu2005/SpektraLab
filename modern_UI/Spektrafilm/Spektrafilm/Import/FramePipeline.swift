//  FramePipeline.swift — one serial executor for the open path, and the
//  reason a frame switch can actually stop the work it started.
//
//  `Session.select` used to cancel `loadTask` and get nothing for it: the
//  decode and the preview ran inside `Task.detached { ... }` blocks, which
//  inherit no cancellation, and the decoder functions had no cancellation
//  checks anyway. Every click committed three to five uncancellable
//  full-resolution jobs, and the blocking `cb.waitUntilCompleted()` at the
//  end of `makePreviewTexture` parked a cooperative-pool thread on each of
//  them (IMP §3.1).
//
//  This class replaces the detached tasks, and it fixes the mechanism rather
//  than the symptom:
//
//  - A **serial queue** owns every heavy stage of a load — the RAW decode,
//    the preview render, the native original. At most one runs at once, and
//    the blocking Metal wait happens on this queue, off the Swift
//    cooperative thread pool everything else in the app shares.
//  - A **generation** stamps every job. `supersede()` bumps it and makes
//    every older job stale; a stale job's first `checkpoint()` throws
//    `CancellationError` before its body runs, so a job that was queued and
//    then superseded costs nothing.
//  - The checkpoint is also wired to the awaiting task's actual cancellation
//    (`Task.cancel()` on the `loadTask` awaiting `run`): the cancellation
//    handler sets a lock-protected flag the checkpoint reads, so a running
//    job stops at its next stage boundary instead of running to completion.
//
//  A DispatchQueue rather than an actor or a plain `Task`, deliberately: the
//  decode and the preview render are blocking Metal operations, and one of
//  them must never pin a cooperative-pool thread.

import Foundation

/// Thread-safe Boolean set by `withTaskCancellationHandler`'s `onCancel` and
/// read by the job's checkpoint. One per `run`, so a cancellation delivered
/// to one job can never poison a newer one — an instance-wide flag would
/// either bleed across jobs or need a reset that races the cancellation.
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

final class FramePipeline: @unchecked Sendable {
    /// Serial on purpose: `makePreviewTexture` ends in a blocking
    /// `waitUntilCompleted`, and a decode holds a Metal context for its whole
    /// run — two of those concurrently would contend for Metal and for
    /// memory, not parallelise.
    private let queue = DispatchQueue(label: "filmify.frame-pipeline", qos: .userInitiated)
    private let lock = NSLock()
    private var _generation = 0
    private var _jobsRun = 0
    private var _jobsSkipped = 0

    /// How many jobs actually ran their body (counted from the serial queue,
    /// so for tests and the diagnostics log, not for the hot path).
    var jobsRun: Int { lock.withLock { _jobsRun } }
    /// How many jobs were superseded before their body started.
    var jobsSkipped: Int { lock.withLock { _jobsSkipped } }

    /// Bump the generation, making every job of an older generation stale.
    /// A frame switch, a reopen and a service restart all call this; the next
    /// `checkpoint()` of any older job then throws `CancellationError`.
    @discardableResult
    func supersede() -> Int {
        lock.withLock {
            _generation += 1
            return _generation
        }
    }

    /// Whether `g` is the current generation — a job's checkpoint asks this
    /// on every stage boundary.
    func isCurrent(_ g: Int) -> Bool {
        lock.withLock { g == _generation }
    }

    /// Run `work` on the serial queue, stoppable at its `checkpoint`s.
    ///
    /// The function returns when `work` finishes; it throws the error `work`
    /// throws, or `CancellationError` when a `checkpoint()` finds the job
    /// stale — superseded by a newer generation, or the awaiting task (the
    /// `loadTask`, in practice) has been cancelled.
    ///
    /// `work` receives the `checkpoint` to call between its stages. One
    /// checkpoint also runs before `work` itself, so a stale job that was
    /// queued never touches its decoder. The checkpoint is cheap: a lock read
    /// on the generation plus a lock read on the cancellation flag.
    ///
    /// The continuation is resumed exactly once, from the queue thread, and
    /// nothing else resumes it — the cancellation handler only sets the flag
    /// the checkpoint reads, because `withCheckedThrowingContinuation` will
    /// not resume itself on cancellation.
    ///
    /// Cancellation suppresses the body, but the dispatch queue still owns the
    /// queued closure and every object it captures. Large decoded payloads
    /// must therefore cross this seam in a lease whose cancellation path can
    /// release them independently.
    func run<T>(generation g: Int,
                _ work: @escaping @Sendable (_ checkpoint: () throws -> Void) throws -> T)
        async throws -> T {
        let cancelled = CancellationFlag()
        let checkpoint: @Sendable () throws -> Void = {
            if cancelled.isSet || !self.isCurrent(g) { throw CancellationError() }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    var started = false
                    do {
                        // One checkpoint before the body, so a job superseded
                        // while queued costs nothing.
                        try checkpoint()
                        started = true
                        self.recordRun()
                        let value = try work(checkpoint)
                        continuation.resume(returning: value)
                    } catch {
                        if !started { self.recordSkipped() }
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    private func recordRun() { lock.withLock { _jobsRun += 1 } }
    private func recordSkipped() { lock.withLock { _jobsSkipped += 1 } }
}
