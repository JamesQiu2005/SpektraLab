//  CostModel.swift — predicted render memory and time, corrected by observed jobs.
//
//  The starting coefficients come from earlier reference-device experiments; they are not Mac
//  performance claims. They price an open, source storage and render planes separately. The online
//  correction keeps an exponentially weighted ratio of measured to predicted peak and duration.
//  A peak is learned only from a job that started from rest (`RenderResult.peakBytes`).
//
//  The band arithmetic below remains part of scheduler planning. The current desktop engine renders
//  whole frames: no band-setting call reaches it. See ENGINE-WIRING.md for the actual render boundary.

import Foundation

struct CostEstimate: Equatable, Sendable {
    /// The job's peak over the app's resting footprint: what the allowance pays.
    var peakBytes: UInt64
    /// What the host pays, which is more: the footprint's peak and the
    /// engine's source plane. The plane (12 B a pixel of the frame the job
    /// opens: 558 MiB at 48 MP) is file-backed, so `phys_footprint` counts
    /// about a tenth of it — and the host holds all of it. Measured on the
    /// reference device over 46 full-size jobs (EngineBench, 2026-10-03): at 48 MP
    /// the host's headroom fell 300-790 MB further than the footprint rose
    /// (median 490), at 12 MP 0-360 MB (the plane is 140).
    var phoneBytes: UInt64
    var seconds: Double
}

/// Historical band-cost arithmetic retained by the planner and its synthetic checks.
/// It estimates six float RGB planes plus the spatial halo. The desktop engine does not
/// accept this budget and renders the job whole; see ENGINE-WIRING.md.
struct BandGeometry: Equatable, Sendable {
    var canvas: PixelSize
    /// 6 planes × 12 bytes × the canvas's width.
    var bytesPerRow: UInt64
    /// `above + halo`: the rows a band holds outside its interior. Measured at
    /// 36 mm: 722 for a frame 8,064 px on its long edge (66 above, 656 below —
    /// most of it the DIR couplers' 4-sigma tail, which stays exact) and 426
    /// at 4,032 (74 + 352); a line through the two elsewhere. **By the long
    /// edge, not the width**: the reach is in micrometres of film and the
    /// pixel pitch is the format over the long edge, so an upright frame has
    /// the reach of the same frame on its side. (By the width, a 6,048 × 8,064
    /// photo was asked for 2,688-row bands and cut 2,536: four bands for three.)
    var overheadRows: Int
    /// Below this the band is shorter than its own halo: time explodes and
    /// memory hardly moves (~280 rows at 48 MP).
    var floorRows: Int

    init(canvas: PixelSize) {
        self.canvas = canvas
        bytesPerRow = 6 * 12 * UInt64(max(canvas.width, 1))
        let edge = Double(canvas.longEdge)
        overheadRows = max(1, Int((426 + (722 - 426) * (edge - 4032) / 4032).rounded()))
        floorRows = max(64, Int((280 * edge / 8064).rounded()))
    }

    func bandCount(rows: Int) -> Int { Int((Double(canvas.height) / Double(max(rows, 1))).rounded(.up)) }

    /// A height the engine can cut: it rounds every band down to a multiple of
    /// 8 rows (the coarse halation grid), so a height that is not one comes
    /// back shorter, and one band more than was planned — 756 rows asked at
    /// 48 MP is 752 cut, and 9 bands where 8 were predicted.
    static func cuttable(_ rows: Int) -> Int { max(8, (rows + 7) / 8 * 8) }

    /// The estimated plane budget for bands of
    /// `rows` (the arithmetic above, solved for the budget).
    func engineBudgetBytes(rows: Int) -> UInt64 { UInt64(rows + overheadRows) * bytesPerRow }
}

struct CostModel: Sendable {
    /// measured ÷ predicted, smoothed.
    struct Correction: Codable, Equatable, Sendable {
        var peak = 1.0
        var time = 1.0
        var samples = 0
    }

    var policy: DevicePolicy
    private(set) var corrections: [String: Correction] = [:]
    /// The weight of the newest sample.
    var alpha = 0.3

    init(policy: DevicePolicy = .current, corrections: [String: Correction] = [:]) {
        self.policy = policy
        self.corrections = corrections
    }

    // MARK: the seeds

    private static let mb = 1_048_576.0
    private static let lowMP = 12.19, highMP = 48.77   // 4032 × 3024 and 8064 × 6048

    private static func lerp(_ a: Double, _ b: Double, megapixels: Double) -> Double {
        a + (b - a) * (megapixels - lowMP) / (highMP - lowMP)
    }

    /// The bench's canvas: 2,560 × 1,920.
    private static let canvasPixels = 2560.0 * 1920.0

    /// The cost before any correction.
    func seed(_ job: RenderJob, mode: RenderMode) -> CostEstimate {
        let pixels = Double(job.canvas.width) * Double(job.canvas.height)
        // The frame the engine opens: the canvas, or larger on purpose (`RenderJob.opens`).
        let opened = max(pixels, Double(job.pricedOpen.width) * Double(job.pricedOpen.height))
        let mp = pixels / 1_000_000
        if job.kind == .thumbnail {
            return CostEstimate(peakBytes: 24 << 20, phoneBytes: 24 << 20, seconds: 0.02)
        }
        var peak: Double, seconds: Double
        if job.tier != .full {
            // A canvas session, measured on the host at 2,560 px and scaled by pixels.
            let s = pixels / Self.canvasPixels
            peak = max(80, 560 * s) * Self.mb
            if job.isReprint { seconds = 0.055 * s }
            else if job.layers.isEmpty { seconds = 0.56 * s }   // the first develop of a session
            else { seconds = 0.21 * s }
        } else {
            // The render on the reference device: t0 + c_band × bands, and a whole one is one band.
            let t0 = Self.lerp(0.69, 2.28, megapixels: mp), c = Self.lerp(0.060, 0.137, megapixels: mp)
            switch mode {
            case .whole, .wait:
                peak = Self.lerp(1004, 3239, megapixels: mp) * Self.mb
                seconds = (t0 + c) * policy.timeRatio
            case .bands(let rows):
                let g = BandGeometry(canvas: job.canvas)
                let floor = Self.lerp(310, 870, megapixels: mp) * Self.mb
                // A band row costs the engine's six planes at 48 MP, and 17 % more than that at
                // 12 MP, where what does not scale with the band weighs more.
                let perRow = Double(g.bytesPerRow) * Self.lerp(1.17, 1.0, megapixels: mp).clamped(to: 1.0...1.3)
                peak = floor + perRow * Double(rows)
                seconds = (t0 + c * Double(g.bandCount(rows: rows))) * policy.timeRatio
            }
            seconds = max(seconds, 0.05)
        }
        if job.printLayers > 0 {
            // A half-frame pair whose frames print as their own (`RenderJob.printLayers`): after
            // its own print the job prints the same negative again for each, and cuts that print
            // into the first. **Arithmetic, not a measurement**: no host has run one.
            //
            // - One more result is alive while a layer is made and cut in — the engine's rgba16,
            //   8 B a pixel of the canvas — beside whatever that print holds. Priced as if a
            //   layer's print peaked as the job's own render does, which is true of a banded one
            //   (the engine keeps no negative of a banded render, so a layer develops again in
            //   bands, RFC-035 §9) and over what a reprint of a cached negative takes.
            // - Each layer is a print pass: a reprint's own time below the full tier (55 ms at
            //   2,560 px) and that by the pixels at it; in bands, the whole develop again.
            peak += 8 * pixels
            let pass: Double
            if job.tier != .full {
                pass = 0.055 * pixels / Self.canvasPixels
            } else if case .bands(let rows) = mode {
                let t0 = Self.lerp(0.69, 2.28, megapixels: mp), c = Self.lerp(0.060, 0.137, megapixels: mp)
                pass = (t0 + c * Double(BandGeometry(canvas: job.canvas).bandCount(rows: rows))) * policy.timeRatio
            } else {
                pass = 0.055 * pixels / Self.canvasPixels * policy.timeRatio
            }
            seconds += Double(job.printLayers) * pass
        }
        if job.decodesOriginal, job.tier == .full {
            // Two moments, and the job's peak is the larger. Both measured on the
            // reference device with HEIF through Core Image (EngineBench, 2026-10-03):
            //
            // - the open, Core Image's decode beside the engine's source plane (which
            //   is file-backed and hardly counts): 355-406 MB at 12 MP, 1,109-1,129 MB
            //   at 48 MP — 150 MB + 21 B a pixel;
            // - the render, with what Core Image leaves resident through it: ~160 MB
            //   over the same render of a buffer handed over, at 48 MP — 3.3 B a pixel.
            //
            // Of the 21 B, 16 are the frame handed to the engine (float32, four channels) and
            // the rest the decoder's own, which follows what it decodes. An export whose
            // picture the host cuts decodes the whole original for a frame that is part of it
            // (`ExportPlan`; `RenderJob.original` is then the decode's size): the 5 B are of
            // the decode. Arithmetic from the uncut figure, not a measurement of a cut one.
            let decoded = max(job.original.map { Double($0.width) * Double($0.height) } ?? pixels, pixels)
            peak = max(peak + 3.3 * pixels, 150 * Self.mb + 16 * pixels + 5 * decoded)
            // HEIF: 0.11 s at 12 MP, 0.40 s at 48 MP. A Bayer RAW is slower: 0.36-0.55 s
            // at 12 MP (RFC-035 §11).
            seconds += 0.009 * mp
        } else if job.decodesOriginal {
            // Below the full tier the frame is decoded no larger than the canvas
            // (`FrameSource.decode`), and what that takes depends on the decoder and on the
            // original. By the end of the open, on the reference device (EngineBench `shoot`,
            // 2026-10-03, a 2,400 px frame):
            //
            // - ImageIO's reduced decode: 140-194 MB, from a 12 MP photo and from a 48 MP one;
            // - Core Image, scaled before it renders: 290-308 MB from 12 MP, 438-588 MB from
            //   48 MP — it holds the original while it works.
            //
            // Priced at the dearer, by the original's pixels: 240 MB + 7.6 B a pixel (328 MB
            // at 12 MP, 594 at 48). The whole job measured 360-456 MB by ImageIO and up to
            // 588 by Core Image; the correction below learns which decoder the app has.
            let from = Double((job.original ?? job.canvas).width) * Double((job.original ?? job.canvas).height)
            peak = max(peak + 3.3 * opened, 240 * Self.mb + 7.6 * from)
            // The decode: 0.05-0.19 s from 12 MP, 0.13-0.36 s from 48 MP.
            seconds += 0.003 * from / 1_000_000
        } else if job.opens != nil {
            // A frame handed over already decoded (a strip's cards after its first: `StockPreviews`)
            // is opened again, which copies it into the engine's own source (AGENTS.md trap 9).
            // The buffer handed over is the host's and already in the footprint.
            peak += 3.3 * opened
        }
        // The source plane of the frame the job opens, which the footprint does not show.
        let source = 12 * opened
        return CostEstimate(peakBytes: UInt64(max(peak, 0)), phoneBytes: UInt64(max(peak, 0) + source), seconds: seconds)
    }

    // MARK: the correction

    static func key(_ job: RenderJob, mode: RenderMode) -> String {
        func sizeClass(_ mp: Double) -> String { mp < 8 ? "canvas" : mp < 18 ? "12" : mp < 36 ? "24" : "48" }
        // A small decode's cost is the original's, so what is learned from a 12 MP photo's
        // preview is not applied to a 48 MP one's.
        let from = job.decodesOriginal && job.tier != .full ? job.original.map { "<" + sizeClass($0.megapixels) } ?? "" : ""
        // A strip's card is learned apart: its open is larger than its canvas, and what it teaches
        // is not what the page's develop at a small canvas costs.
        let size = (job.kind == .stockPreview ? "card" : sizeClass(job.canvas.megapixels)) + from
        let how: String
        switch mode {
        case .whole, .wait: how = job.isReprint ? "reprint" : "whole"
        case .bands: how = "bands"
        }
        return "\(job.tier.rawValue)|\(size)|\(how)"
    }

    func estimate(_ job: RenderJob, mode: RenderMode) -> CostEstimate {
        let s = seed(job, mode: mode)
        guard let c = corrections[Self.key(job, mode: mode)] else { return s }
        // The correction is the footprint's: the source plane is arithmetic, not a measurement to learn.
        let peak = UInt64(Double(s.peakBytes) * c.peak)
        return CostEstimate(peakBytes: peak, phoneBytes: peak + (s.phoneBytes - s.peakBytes), seconds: s.seconds * c.time)
    }

    /// Take a finished job's measurements. A measured peak of 0 (the simulated
    /// engine has none of its own) leaves the peak's correction alone.
    mutating func learn(_ job: RenderJob, mode: RenderMode, measuredPeakBytes: UInt64, measuredSeconds: Double) {
        let s = seed(job, mode: mode)
        let k = Self.key(job, mode: mode)
        var c = corrections[k] ?? Correction()
        func blend(_ old: Double, _ ratio: Double) -> Double {
            // Keep one wild sample from moving the model far: 0.5…2.
            let r = ratio.clamped(to: 0.5...2)
            return c.samples == 0 ? r : old + alpha * (r - old)
        }
        if measuredPeakBytes > 0, s.peakBytes > 0 {
            c.peak = blend(c.peak, Double(measuredPeakBytes) / Double(s.peakBytes))
        }
        if measuredSeconds > 0, s.seconds > 0 {
            c.time = blend(c.time, measuredSeconds / s.seconds)
        }
        c.samples += 1
        corrections[k] = c
    }

    // MARK: kept across launches

    static let defaultsKey = "scheduler.costCorrections.v1"

    static func load(from defaults: UserDefaults = .standard, policy: DevicePolicy = .current) -> CostModel {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode([String: Correction].self, from: data)
        else { return CostModel(policy: policy) }
        return CostModel(policy: policy, corrections: saved)
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(corrections) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
