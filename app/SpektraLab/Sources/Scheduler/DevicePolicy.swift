//  DevicePolicy.swift — the numbers that belong to the device, not to a picture.
//
//  ARCHITECTURE §6.1: an execution plan changes *how* a picture is made (memory
//  reserve, band rows, preview size, cadence) and never *which* picture. These
//  are that plan's device-side numbers. Each says whether it was measured and
//  where; the ones that were not are marked as targets or placeholders.

import Foundation

struct DevicePolicy: Sendable {
    /// The largest frame this device develops. A file larger than this is not
    /// refused: it is decoded smaller and labelled with the size it was
    /// developed at (ARCHITECTURE §7.9).
    ///
    /// (2026-10-20: the owner asked for the 48/12 MP cap to go and every export
    /// size to be offered.) A full-size job's memory grows with the frame however
    /// it is banded — the decode and the engine's source plane are whole — so a
    /// ceiling stays: a 6,144 MB allowance, less 1.5 GB for the app and its page,
    /// at 40 bytes a pixel (`ceiling(allowanceMB:)`), which is 120 MP. Banded 48 MP
    /// exports peaked at 26-54 bytes a pixel (1.27-2.6 GB, 2026-10-17/19); a whole
    /// render is 84-100, and the scheduler bands one that would not fit.
    var developCapMegapixels: Double
    /// New-frame default: 1,920 px covers the fitted reference device canvas with zoom
    /// headroom. A product size target, not a latency/device qualification.
    /// Cards use their separate 800 px live rendition; export remains native.
    var previewLongEdge: Int = 1920
    /// Settings › Develop › *Preview size*'s choices (`MacSettingsDevelop`). 3,200 and 3,840 px (4K's long edge) since
    /// 2.4.0 (the owner, 2026-11-13: "we're supporting preview of up to 3840px long edge"). Nothing on the way caps a
    /// preview below them: the wire takes 800…8192 (`EngineWire`), a RAW's proxy is the whole decode made smaller by
    /// Lanczos at the frame's own preview size (`RawExposure.scaled`, never `scaleFactor`), and the canvas's cost is
    /// priced by its pixels (`CostModel.seed`), so a 3,840 px develop is forecast at 2.25x a 2,560 px one of the same
    /// shape (a RAW's first open: its decode's price and that growth over 2,560 px, `CostModel`).
    ///
    /// Measured on this Mac (M3 Max, 36 GB, 2026-11-13, `tools/memory_check.sh --preview-edge`, two runs a size,
    /// interleaved, load 6-8 with another build beside it), a fresh RAW's develop, the page's job with its strip,
    /// 2,560 → 3,840 px: a 24 MP ARW shown in 1.7-1.9 → 2.0-2.1 s, its peak over the footprint before it 1.46 → 2.05 GB;
    /// a 45 MP NEF 1.9 → 2.1 s, 1.85 → 2.48 GB — about 0.6 GB more, not 2.25x (the decode of the original does not
    /// grow), and the app ~150 MB larger at rest after it. Safe on a 16 GB Mac (the app peaks at ~2.9 GB browsing), so
    /// nothing is hidden there; the row's caption says what it costs. A 3,840 px develop of the NEF is not an enlarged
    /// one: grain and glare off, its detail above a 2,560 px picture's Nyquist correlates 0.95 with the full render made
    /// 3,840 px (a 2,560 px develop enlarged: 0.34). `tools/scheduler_selftest.swift` fails if 3,840 leaves the list.
    static let previewEdges = [1600, 1920, 2400, 2560, 3200, 3840]
    /// Exposure is metered once per session at this size and applied to every
    /// tier. A preview size must not change the meter (AGENTS.md).
    let meterLongEdge = 1600
    /// A banded engine bands a full render above this many pixels…
    var bandAbovePixels: UInt64 = 20_000_000
    /// …with planes of at most this many bytes, unless the scheduler says
    /// otherwise per job (RFC-035 §9: 1 GiB).
    var defaultBandBudgetBytes: UInt64 = 1 << 30
    /// This device's time against the reference device's, which is where the cost
    /// model's times were measured (EngineBench, 2026-10-03). 1 until another
    /// device is measured; the M3 Max is about a third (0.29-0.36 across the
    /// band ladder at 48 MP).
    var timeRatio = 1.0

    /// The Mac's: the 6,144 MB allowance of a machine with 7 GB or more of memory, which every Mac
    /// this app runs on has (8 GB at the least).
    static let current = DevicePolicy(developCapMegapixels: ceiling(allowanceMB: 6_144))

    /// The largest frame an allowance develops: less 1.5 GB for the app, at 40 bytes a pixel.
    static func ceiling(allowanceMB: Double) -> Double {
        let mp = (allowanceMB - 1_536) * 1_048_576 / 40 / 1_000_000
        return max(12, (mp / 4).rounded(.down) * 4)
    }
}
