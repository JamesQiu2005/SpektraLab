//  Planner.swift — the fastest way to render that fits, or not yet.
//
//  RFC-036 §6.4 and §6.7. Two questions, in this order:
//
//  1. **May this job run at all, given what the frontend is doing?** The
//     policy table: nothing runs in the background (GPU work is refused
//     there); nothing starts while a photo is in flight (`CaptureRule`); with
//     the camera live an export waits, and so does a 48 MP shot **at full
//     size**, because that is the case that ended the bench app twice. A
//     shot at preview size — the one the app submits — does not wait. All of
//     that is with the darkroom open beside a camera; a host may close it
//     (`besideCamera`), and then nothing but a thumbnail runs while a camera
//     session does.
//  2. **Which mode?** The one with the least predicted time whose predicted
//     cost fits the budget — its footprint within the app's allowance, and
//     what it takes from the host within the host's headroom
//     (`MemoryBudget.fits`). Ties go to the larger band: fewer bands, fewer
//     seams to verify. If none fits, the job waits — it does not gamble (G1).
//
//  **A job never drops below full quality.** The ladder has no reduced-effect
//  rung, no smaller-than-asked export and no LUT stand-in (§3.2). What gives is
//  time.

import Foundation

struct RenderPlan: Equatable, Sendable {
    var mode: RenderMode
    var estimate: CostEstimate
    var budget: MemoryBudget

    var waits: Bool { if case .wait = mode { true } else { false } }
}

enum Planner {
    /// The modes a job could run in, fastest first.
    static func ladder(for job: RenderJob) -> [RenderMode] {
        // Only a full-tier render bands (RFC-035 §9); a canvas is one piece. And
        // so is a frame with a crop or a turn: the engine renders it whole.
        guard job.tier == .full, job.kind != .thumbnail, job.bandable else { return [.whole] }
        let g = BandGeometry(canvas: job.canvas)
        var modes: [RenderMode] = [.whole]
        var last = Int.max
        // 2 bands down to the floor: each step fewer rows, less memory, more time.
        // Every height is one the engine can cut (a multiple of 8), so the
        // band count it predicts is the count the engine runs.
        for count in [2, 3, 4, 6, 8, 11, 16, 22, 32, 45, 64, 96] {
            let rows = BandGeometry.cuttable(Int((Double(job.canvas.height) / Double(count)).rounded(.up)))
            if rows < g.floorRows { break }
            if rows < last { modes.append(.bands(rows: rows)); last = rows }
        }
        return modes
    }

    /// The policy table's verdict, before memory is even asked about: may this
    /// job start now? `captures` is what a photo in flight does to a develop
    /// below the full tier (`CaptureRule`); a full-size job holds for a photo
    /// whatever it says.
    ///
    /// `besideCamera` false closes the darkroom to a live camera
    /// (`RenderQueue.developsBesideCamera`): every develop waits for the
    /// session to stop, whatever its size and whatever the capture rule.
    static func gate(_ job: RenderJob, frontend: FrontendState, policy: DevicePolicy,
                     captures: CaptureRule = .holds, besideCamera: Bool = true) -> WaitReason? {
        if frontend.scene != .active { return .background }
        guard frontend.cameraLive else { return nil }
        if !besideCamera, job.kind != .thumbnail { return .camera }
        if frontend.capturesInFlight > 0, job.kind != .thumbnail, job.tier == .full || captures != .shares {
            return .capture
        }
        switch job.kind {
        case .export, .importDevelop, .fullView:
            // "camera live, idle: export waits."
            return .camera
        case .stockPreview:
            // Develop's strips are the darkroom's, and never beside a camera,
            // whoever has opened it (the owner, 2026-10-08).
            return .camera
        case .shot:
            // At preview size, which is what the app asks for behind the
            // viewfinder, a shot develops at once whatever the photo's size:
            // its frame is decoded no larger than its canvas, and on the
            // reference device it peaked at 375-457 MB beside a camera live at 12 or
            // at 48 MP. At full size a 12 MP shot goes at once too. Above the
            // band threshold (48 MP at full size) the only mode that gets
            // under the whole-frame floor beside the camera's ~2 GB is the
            // streamed one (M*, phase 3), which does not exist yet: wait for
            // the camera to go idle or stop.
            return UInt64(job.canvas.width) * UInt64(job.canvas.height) > policy.bandAbovePixels ? .camera : nil
        case .canvasReprint, .canvasDevelop, .thumbnail:
            return nil
        }
    }

    static func plan(_ job: RenderJob, budget: MemoryBudget, frontend: FrontendState,
                     model: CostModel, derate: Double = 1, captures: CaptureRule = .holds,
                     besideCamera: Bool = true) -> RenderPlan {
        if let why = gate(job, frontend: frontend, policy: model.policy, captures: captures, besideCamera: besideCamera) {
            return RenderPlan(mode: .wait(why), estimate: model.estimate(job, mode: .whole), budget: budget)
        }
        // Held to both sides of the budget, each in its own measure; and after a
        // pressure event the same reading is trusted less.
        for mode in ladder(for: job) {
            let cost = model.estimate(job, mode: mode)
            if budget.fits(cost, derate: derate) {
                return RenderPlan(mode: mode, estimate: cost, budget: budget)
            }
        }
        let smallest = ladder(for: job).last ?? .whole
        return RenderPlan(mode: .wait(frontend.cameraLive ? .camera : .memory),
                          estimate: model.estimate(job, mode: smallest), budget: budget)
    }
}
