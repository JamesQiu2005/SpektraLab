//  SimulatedEngine.swift — a stand-in engine that keeps time and makes no picture.
//
//  This build is the interface and the scheduler. The engine is not linked, so
//  something has to answer the scheduler's calls for the pages to be exercised:
//  this does, by taking as long as the measured engine takes (the cost model's
//  own seeds, with a little spread) and walking the same stages.
//
//  **It renders nothing.** A frame's picture does not change when it
//  "develops", and the app says so where it names the engine (Settings). It
//  holds no memory either, so a job's measured peak comes back 0 and the cost
//  model's peak correction is left alone. What it does exercise is real: the
//  queue, the budget read from the host, the mode chosen, cancellation,
//  coalescing, waits and their reasons.

import Foundation

final class SimulatedEngine: DevelopEngine, @unchecked Sendable {
    let name = "simulated"
    let effectVersions = "simulated"
    let makesPictures = false

    private let model: CostModel
    private let lock = NSLock()
    private var cancelled = Set<UUID>()
    /// 1 runs at the measured pace; the snapshot harness and the tests run faster.
    var speed: Double
    /// It holds no pool of its own; a test gives it one by saying what a trim frees.
    var onTrim: (@Sendable () -> UInt64)?
    /// It renders the size it is asked for; a test makes it render another, as the engine does
    /// when it is handed a frame larger than the job's canvas.
    var renders: (@Sendable (RenderJob) -> PixelSize)?

    init(policy: DevicePolicy = .current, speed: Double = 1) {
        model = CostModel(policy: policy)
        self.speed = speed
    }

    func run(_ job: RenderJob, mode: RenderMode,
             progress: @escaping @Sendable (RenderProgress) -> Void) async throws -> RenderResult {
        let started = Date()
        let total = model.seed(job, mode: mode).seconds * Double.random(in: 0.92...1.08) / max(speed, 0.01)
        let bands: Int
        if case .bands(let rows) = mode { bands = BandGeometry(canvas: job.canvas).bandCount(rows: rows) } else { bands = 1 }

        // The stages a job walks, and each one's share of its time.
        var stages: [(RenderStage, Double)]
        if job.isReprint {
            stages = [(.print, 0.7), (.scan, 0.3)]
        } else {
            stages = [(.film, 0.62), (.print, 0.24), (.scan, 0.14)]
        }
        if job.decodesOriginal { stages = [(.decode, 0.18)] + stages.map { ($0.0, $0.1 * 0.72) } + [(.save, 0.10)] }

        var done = 0.0
        for (stage, share) in stages {
            // A node boundary every ~40 ms: where a cancel is noticed.
            let slices = max(1, Int((total * share / 0.04).rounded(.up)))
            for i in 1...slices {
                if isCancelled(job.id) || Task.isCancelled { clear(job.id); throw EngineError.cancelled }
                try? await Task.sleep(nanoseconds: UInt64(total * share / Double(slices) * 1_000_000_000))
                let fraction = done + share * Double(i) / Double(slices)
                progress(RenderProgress(stage: stage, fraction: min(fraction, 1),
                                        band: min(bands - 1, Int(fraction * Double(bands))), bandCount: bands))
            }
            done += share
        }
        if isCancelled(job.id) { clear(job.id); throw EngineError.cancelled }
        return RenderResult(seconds: Date().timeIntervalSince(started) * max(speed, 0.01), peakBytes: 0,
                            reprint: job.isReprint, size: renders?(job) ?? job.canvas)
    }

    func cancel(_ jobID: UUID) { lock.withLock { _ = cancelled.insert(jobID) } }
    private func isCancelled(_ id: UUID) -> Bool { lock.withLock { cancelled.contains(id) } }
    private func clear(_ id: UUID) { lock.withLock { _ = cancelled.remove(id) } }

    func trim() async -> UInt64 { onTrim?() ?? 0 }
    func heldBytes() async -> UInt64 { 0 }
}
