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

/// **A double exposure's composed open, as measured on the Mac** (2026-11-11, Apple M3 Max, macOS 27;
/// `tools/double_check.sh`: each job from rest, this process's `phys_footprint` — `footprint -p`'s number, never
/// RSS — sampled every 20 ms, and the queue's own record of the same jobs; the envelope of the two is fitted).
/// The earlier figures (150 MB + 16 B a pixel of the piece + 5 B a pixel of the decode at Full; 240 MB + 7.6 or
/// 9 B a pixel below it) were arithmetic, never measured, and priced a RAW double's preview open at
/// 483 MB where it took 2,005–2,150 (PRD-D §3.6). Measured, two photographs each:
///
/// | photographs | tier | the job | measured over rest | this fit |
/// |---|---|---|---|---|
/// | 2 × 24 MP ARW (A7 III) | preview, 1,920 px | the double's develop | 1,788–1,880 sampled, 2,005–2,150 recorded | 2,156 |
/// | 2 × 45 MP NEF (Z7 II) | preview, 1,920 px | the double's develop | 3,466–3,473 sampled, 3,391–3,398 recorded | 3,424 |
/// | 2 × 45 MP HEIC (of the NEFs) | preview, 1,920 px | the double's develop | 108–248 sampled, 377–378 recorded | 389 |
/// | 2 × 24 MP ARW | Full, 6,000 × 4,000 piece | an export | 3,572–3,613 | 3,625 |
/// | 2 × 45 MP NEF | Full, 3,669 × 5,504 piece | an export | 3,390 | 3,434 |
/// | 2 × 45 MP HEIC | Full, 3,669 × 5,504 piece | an export | 1,484–1,507 | 1,594 |
///
/// The preview rows carry the router's 37 MB scratch band (1,920 × 1,280 × 16 B) and are the harness's own seeds;
/// the Full rows are this arithmetic with a 64 MB band, the export's not being recorded by the harness.
/// For scale, each photograph alone on the same Mac: a 24 MP ARW's preview develop +1,730 MB, a 45 MP NEF's
/// +3,417, a 45 MP HEIC's +83–121; a 45 MP NEF's full export +3,181–3,353, a 45 MP HEIC's +2,196–2,220. **Two
/// RAW decodes do not stack**: the double's open is its larger photograph's and little more. A RAW decoded whole
/// at Full is nearly flat between 24 and 45 MP (~2 GB): a 12 MP RAW is not measured and is probably over-priced
/// here, which the model's online correction (`|double|raw`) takes back. Times: preview 0.6–1.3 s, Full 1.0–1.8 s.
enum ComposedOpen {
    static let mb = 1_048_576.0
    // At the full tier: the piece and the engine's render of it, and the largest decode.
    static let fullPieceBytesPerPixel = 64.0
    static let fullRAWBase = 2050 * mb, fullRAWBytesPerPixel = 2.0
    static let fullOtherBase = 220 * mb, fullOtherBytesPerPixel = 4.0
    static let fullRAWSecondsPerMP = 0.012, fullOtherSecondsPerMP = 0.006
    // Below it: the decode of the largest original.
    static let belowRAWBase = 700 * mb, belowRAWBytesPerPixel = 62.0
    static let belowOtherBase = 200 * mb, belowOtherBytesPerPixel = 3.5
    static let belowRAWSecondsPerMP = 0.022, belowOtherSecondsPerMP = 0.007
}

/// **A photograph's RAW opened below the full tier with no proxy to read: its first open** (`RenderJob.rawDecode`),
/// as measured on the Mac (2026-11-13, Apple M3 Max, macOS 27; DIAG-2026-11-13 Part 2). Core Image decodes the RAW
/// whole and makes it the page's size, now in bands of 2 MP of the original (`FrameDecoder.rawBandSourcePixels`), and
/// the proxy is written of it. The figure is the job's own record, `openPeakFootprint − footprintBefore`
/// (`MacMemoryCheck`, a 2,560 px canvas, lens correction on as a new RAW frame has it), or the decode alone in a
/// process of its own (`tools/raw_open_probe.swift`) where that was higher:
///
/// | original | measured | this fit |
/// |---|---|---|
/// | 8 MP Olympus ORF (decoder 7) | 187–320 MB | 829 |
/// | 24 MP Sony A7 III ARW | 489–573 | 1,287 |
/// | 24 MP Panasonic S1M2 RW2 | 912–977 | 1,287 |
/// | 45 MP Nikon Z7 II NEF | 737–922 | 1,900 |
/// | 60 MP Sony A7R V ARW | 568–706 | 2,323 |
/// | 60 MP Leica Q3 DNG | 2,114–2,317 | 2,326 |
/// | 102 MP Fujifilm GFX100RF RAF | 2,116–2,385 | 3,511 |
///
/// The same files before the banding, in one band: 1,274–1,665 (A7 III), 1,180–1,286 (S1M2), 2,355–2,910 (Z7 II),
/// 2,818–4,303 (A7R V), 3,768–7,121 (GFX), and the job log's 2.6–2.9 GB median (DIAG). The cameras differ by 3x at one
/// size (the Q3's lens opcodes against the A7R V's), so the fit is their envelope — never under, at most 3.3x over —
/// and the correction, learned apart (`CostModel.key`, "|raw"), brings it down to the camera the person has
/// (0.5x a job at most). The old price was the HEIF's (240 MB + 7.6 B a pixel: 414 MB for 24 MP).
enum RawOpen {
    static let mb = 1_048_576.0
    static let base = 600 * mb, bytesPerPixel = 30.0
    /// 0.11 s (8 MP) to 1.7 s (102 MP) measured: ~0.017 s a megapixel of the original.
    static let secondsPerMP = 0.017
}

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
        if job.scenePlanes > 0 {
            // PRD-E's 场景 layers (RFC-052 §8.5): their planes, the host's beside the render, and the node. Measured
            // (API-SPEC §23, M3 Max, 2026-11-13): the develop's own peak the same with 0 and with 8 layers, the planes
            // on top (21 MB each at 4,096 px); the node 4.7–5.2 / 5.3 / 8.0–8.5 ms at 45 MP for 1 / 4 / 8 layers —
            // about 0.096 ms a megapixel of the canvas and 0.011 ms more a layer.
            peak += Double(job.scenePlaneBytes)
            seconds += (0.096 + 0.011 * Double(job.scenePlanes)) * mp / 1000
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
            if let composed = job.composition, !composed.decodes.isEmpty {
                // A double exposure's open at the full tier (RFC-048 §5), **re-fitted on the Mac**
                // (`ComposedOpen`: the 150 MB + 16 B + 5 B below were never measured): the piece and the
                // engine's render of it, the largest decode — a RAW's whole, by Core Image, a nearly flat
                // ~2 GB; ImageIO's reduced one small — and the scratch band; the decodes' times summed.
                let largest = composed.decodes.map { Double($0.width) * Double($0.height) }.max() ?? pixels
                let decode = composed.raw ? ComposedOpen.fullRAWBase + ComposedOpen.fullRAWBytesPerPixel * largest
                                          : ComposedOpen.fullOtherBase + ComposedOpen.fullOtherBytesPerPixel * largest
                peak = max(peak + 3.3 * pixels, ComposedOpen.fullPieceBytesPerPixel * pixels + decode + Double(composed.scratchBytes))
                let perMP = composed.raw ? ComposedOpen.fullRAWSecondsPerMP : ComposedOpen.fullOtherSecondsPerMP
                seconds += composed.decodes.reduce(0) { $0 + perMP * Double($1.width) * Double($1.height) / 1_000_000 }
            } else {
                let decoded = max(job.original.map { Double($0.width) * Double($0.height) } ?? pixels, pixels)
                peak = max(peak + 3.3 * pixels, 150 * Self.mb + 16 * pixels + 5 * decoded)
                // HEIF: 0.11 s at 12 MP, 0.40 s at 48 MP. A Bayer RAW is slower: 0.36-0.55 s
                // at 12 MP (RFC-035 §11).
                seconds += 0.009 * mp
            }
        } else if job.decodesOriginal, let composed = job.composition, !composed.decodes.isEmpty {
            // A double exposure's open below the full tier: each picture decoded no larger than the
            // canvas, one at a time, with the scratch band beside the piece; the decodes' times summed.
            // **Measured on the Mac** (`ComposedOpen`): a RAW decoded by Core Image holds ~62 B a pixel of its
            // original while it works, and two do not stack -- the double's peak is its larger photograph's
            // alone and little more;
            // ImageIO's reduced decode of a HEIF a few B a pixel (`RenderJob.Composition.raw`).
            let largest = composed.decodes.map { Double($0.width) * Double($0.height) }.max() ?? opened
            let decode = composed.raw ? ComposedOpen.belowRAWBase + ComposedOpen.belowRAWBytesPerPixel * largest
                                      : ComposedOpen.belowOtherBase + ComposedOpen.belowOtherBytesPerPixel * largest
            peak = max(peak + 3.3 * opened, decode + Double(composed.scratchBytes))
            let perMP = composed.raw ? ComposedOpen.belowRAWSecondsPerMP : ComposedOpen.belowOtherSecondsPerMP
            seconds += composed.decodes.reduce(0) { $0 + perMP * Double($1.width) * Double($1.height) / 1_000_000 }
        } else if job.decodesOriginal, job.rawDecode {
            // A photograph's RAW with no proxy here (`RawOpen`): Core Image decodes it whole and makes it smaller,
            // banded by the original, and the proxy is written of it. Priced by the original's pixels.
            let from = Double((job.original ?? job.canvas).width) * Double((job.original ?? job.canvas).height)
            peak = max(peak + 3.3 * opened, RawOpen.base + RawOpen.bytesPerPixel * from)
            // `RawOpen` was fitted at a 2,560 px canvas: a larger one (Settings' 3,200 and 3,840 px, 2.4.0) adds its
            // session's growth over the bench's, which the decode does not hide. Measured on this Mac (M3 Max,
            // 2026-11-13, `tools/memory_check.sh --preview-edge`, interleaved, load 6-8): the whole job's peak over the
            // footprint before it, 2,560 → 3,840 px, 1,116-1,318 → 1,630-1,838 MB (24 MP ARW) and 1,494-1,495 →
            // 2,024-2,230 MB (45 MP NEF) — +0.5-0.7 GB, the session's ~114 B a canvas pixel — where the max alone
            // priced both sizes alike (1,287 and 1,900 MB). Nothing changes at 2,560 px and below.
            peak += max(0, max(80, 560 * pixels / Self.canvasPixels) - 560) * Self.mb
            seconds += RawOpen.secondsPerMP * from / 1_000_000
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
        if job.hdrRendition {
            // A slide's HDR rendition (`HDRGain`): after its own render the job renders the
            // frame again (`scan_hdr`, the film side: a develop, in bands as the first was) while the first
            // result is held -- 8 B a pixel -- and then holds both results and the map, 1 B a pixel, while
            // the map is made. Arithmetic over the render's own seed, not a measurement.
            peak += 9 * pixels
            seconds *= 2
        }
        if job.gainMap {
            // A frame's Enable HDR: its delivery, after the render has let the engine's memory go, holds the
            // result, the picture, the map and ImageIO's whole picture at once — the job's peak where its
            // render's own was less (a small band plan, a 12 MP frame).
            peak = max(peak, Self.gainMapDelivery(pixels: pixels, maps: job.gainMaps))
        }
        // The source plane of the frame the job opens, which the footprint does not show.
        let source = 12 * opened
        return CostEstimate(peakBytes: UInt64(max(peak, 0)), phoneBytes: UInt64(max(peak, 0) + source), seconds: seconds)
    }

    /// What ImageIO holds a pixel while a file with a gain map is written, the map in it, over the picture
    /// handed to it (measured on an Apple M3 Max, 2026-11-03: 48 MP at full size 9.0 (JPEG) and
    /// 9.2 (HEIC) B; without a map JPEG streams and HEIC holds 6.9–7.7 B). Measured again on this Mac for
    /// the desktop's own writer, Adobe's hdrgm pass included (`tools/hdr_gainmap_selftest.sh --measure 8256 5504`, this
    /// Mac, 2026-11-06, interleaved twice each, the camera's layout): over the held 45.4 MP picture the map's making
    /// and the write peak at +581 MB (JPEG) and +595 MB (HEIF) — 12.8 and 13.1 B a pixel, the kernel's library and
    /// strips (~210 MB) included — against +1 MB (JPEG streams) and +291 MB (HEIF) without a map. The delivery's
    /// price below (64 MB + 14.85 B a pixel over the result: 738 MB at 45 MP) holds it.
    static let gainMapWriteBytesPerPixel = 9.6

    /// A gain-map export's delivery: the engine's result (rgba16, 8 B a pixel), the picture it is made into
    /// (4 B at 8 bits — JPEG and HEIF, the only containers that carry a map), ImageIO's hold with the map
    /// (`gainMapWriteBytesPerPixel`), each copy of the map past the first, and 64 MB for the kernel's strips
    /// and library. 1.1 GB at 48 MP.
    static func gainMapDelivery(pixels: Double, maps: Int = 1) -> Double {
        64 * mb + pixels * (8 + 4 + gainMapWriteBytesPerPixel + Double(max(maps - 1, 0)) * extraMapBytesPerPixel)
    }

    /// Each copy of the map past the first (RFC-046: the camera's layout codes the map again in Apple's
    /// coding, 1 B a pixel, beside the first while the file is written; ImageIO stores one map either way).
    /// Measured on the M3 Max (2026-11-05): +58 MB at 48.8 MP, 1.2 B a pixel.
    static let extraMapBytesPerPixel: Double = 1.25

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
        // A slide's two renditions are learned apart: their peak and time are not one render's. So is a
        // double exposure's open of two decodes (RFC-048 §5): what it teaches is not a photograph's.
        return "\(job.tier.rawValue)|\(size)|\(how)" + (job.hdrRendition ? "|hdr" : "")
            + (job.decodesOriginal && job.composition != nil ? "|double" : "")
            // A RAW's decode is not a HEIF's: learned apart, so a HEIF's lower peaks never teach the
            // model to price a RAW's under.
            + (job.decodesOriginal && job.composition?.raw == true ? "|raw" : "")
            // So is a photograph's first open of a RAW (`RenderJob.rawDecode`): its proxy's later opens, and a
            // HEIF's of the same size, cost a tenth of it, and with one correction for all of them the model
            // priced the first at 0.4–1.1 GB where it took 2.6–2.9 (DIAG-2026-11-13).
            + (job.decodesOriginal && job.rawDecode && job.composition == nil && job.tier != .full ? "|raw" : "")
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
