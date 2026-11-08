//  MemoryBudget.swift — how much a render may take before it starts.
//
//      budget = min(app headroom − app reserve, reclaimable pages − reserves) × (1 − margin)
//
//  On the Mac, physical memory stands in for a per-process allowance; the host's free, inactive and
//  purgeable pages supply the other bound (`MemoryProbe`). A foreground job may use a larger share,
//  with a watch that cancels under pressure. Each job reads a fresh budget.
//
//  The tuning values began as reference-device calibration, not Mac pressure thresholds. Capture
//  reserves remain scheduler inputs for the synthetic checks; the Mac app has no capture session.

import Foundation

/// The budget's constants. The camera's and the floor are **measured on one
/// host**, the reference device (8 GB), with EngineBench's scheduler runs of
/// 2026-10-03 (`bench/EngineBench/results`); the app's reserve is still a guess.
struct BudgetTuning: Equatable, Sendable {
    /// `r_app`. A guess: the library's thumbnails, the canvas's textures.
    var appReserve: UInt64 = 150 << 20
    /// `r_floor`: the host's headroom the budget never plans below.
    /// **Measured**, the camera live at 48 MP and incompressible GPU memory
    /// taken 100 MB at a time: the operating system declared *critical* memory pressure when
    /// free + inactive + purgeable had fallen to 623 MB — and was by then
    /// ending the apps in the background — and ended this one at 308 MB (326
    /// in its own report, the app at 3,229 MB: the place the two kills of
    /// 2026-10-02 were, at 2,822 and 3,033). So the floor is the critical
    /// level, not the kill: RFC-036's starting value of 300 MB was the kill.
    var floorReserve: UInt64 = 600 << 20
    /// `m`. From rest, every measured peak was within 8 % of its prediction.
    var margin = 0.15
    /// What one capture takes from the host while it is in flight, with the
    /// camera set to 48 MP photos. **Measured** on the reference device (EngineBench,
    /// 2026-10-03; 8-bit HEIF, the host's totals every 50 ms): a true 48 MP
    /// photo took 713-725 MB at its highest, and ~500 MB of that stayed for as
    /// long as the session ran — which the next reading already shows. (In a
    /// dark scene the camera delivers 12 MP whatever was asked, and takes 425.)
    var cameraGrowthAt48MP: UInt64 = 750 << 20
    /// The same with 12 MP photos: 407-420 MB at its highest, 214-400 MB
    /// staying. (RFC-036 guessed 150 MB before it was measured.)
    var cameraGrowthAt12MP: UInt64 = 420 << 20
    /// What one more photo takes **once the session has delivered one**. The
    /// figures above are a session's first photo: it grows the camera's own
    /// memory, and most of that stays for as long as the session runs. Every
    /// photo after it took far less — **measured** on the reference device
    /// (EngineBench `shoot`, 2026-10-03, two runs, the host's totals every
    /// 50 ms): at 48 MP the first took 538-725 MB and the 28 after it at most
    /// 245; at 12 MP the first 425-443 and the 8 after it at most 176.
    ///
    /// Held at 420 MB, not at the 245 measured, for what happens if that is
    /// ever wrong: the tightest host the budget then admits a 48 MP shot's
    /// preview on has 1,776 MB of headroom, and a later photo as large as a
    /// first (725) would still leave it at 408 — under where the operating system calls it
    /// critical, over where it ended the app (300). With the first photo's
    /// 750 reserved for every photo, such a preview needs 2,106 MB of
    /// headroom (2,003 priced by its canvas, as it then was), and the host
    /// had 1,850 (a run in which every preview waited for the camera to stop)
    /// to 2,180 (one in which a third of them waited).
    var cameraGrowthOnceWarm: UInt64 = 420 << 20
    /// How long after its last photo a session still counts as having
    /// delivered one. The longest gap between photos in those runs was ~10 s;
    /// past it the first photo's growth is reserved again.
    var cameraWarmSeconds = 10.0

    // **A job someone is waiting on** — an edit on the develop page, a full-size zoom, an export (the
    // owner, 2026-10-21: "it can't always wait on RAM and I can't even edit … How the app asks for
    // memory must be really really aggressive"). With no camera live, such a job is planned against
    // more of the host than the floor above leaves: the line the operating system calls critical is where it starts
    // ending the apps in the background, and a foreground app the person is using is the last it
    // ends (the bench: 3,100 MB taken from 1,730 MB of headroom before this app went, 279 other
    // processes first). So it spends the other apps' memory — the owner's call — and is watched
    // while it runs (`askedWatchFloor`); the app's own allowance is never loosened.

    /// The floor for a job someone is waiting on: three quarters of `floorReserve`, where the
    /// scheduler's watch used to trip.
    var askedFloorReserve: UInt64 = 450 << 20
    /// Its margin: the measured peaks were within 8 % of their prediction.
    var askedMargin = 0.08
    /// How much of the host's compressed memory (other apps' pages, which the operating system frees by ending
    /// them) such a job may count on.
    var askedCompressedShare = 0.5
    /// Where the watch stops such a job while it runs: above the 308 MB at which the operating system ended this
    /// app in the bench, and 50 ms at a time.
    var askedWatchFloor: UInt64 = 360 << 20

    /// This device's: the measured figures above.
    static var forThisDevice: BudgetTuning { BudgetTuning() }

    /// `warm`: the session, as it is set now, has delivered a photo lately.
    func cameraGrowth(photoMegapixels mp: Double, warm: Bool = false) -> UInt64 {
        guard mp > 0 else { return 0 }
        let u = ((mp - 12) / 36).clamped(to: 0...1)
        let first = cameraGrowthAt12MP + UInt64(Double(cameraGrowthAt48MP - cameraGrowthAt12MP) * u)
        return warm ? min(first, cameraGrowthOnceWarm) : first
    }
}

struct MemoryBudget: Equatable, Sendable {
    enum Binding: String, Sendable {
        /// The app's own allowance is the tighter side.
        case allowance
        /// The host is: the camera daemon and wired memory hold the rest.
        case phone
    }

    /// What a job may take at its peak: the tighter of the two sides, after the margin.
    var bytes: UInt64
    /// `A − r_app` and `P − r_cam − r_floor`, before the margin.
    var appSide: UInt64
    var phoneSide: UInt64
    /// The same two after it. A job is held to both, each in its own measure
    /// (`fits`): its footprint against the allowance, and what it takes from
    /// the host — which is more — against the host.
    var appBytes: UInt64
    var phoneBytes: UInt64
    var cameraReserve: UInt64
    var binding: Binding

    /// `cameraWarm`: the camera session, as it is set now, has delivered a
    /// photo lately (`BudgetTuning.cameraGrowthOnceWarm`). The scheduler knows
    /// from the captures it is told of; false reserves the first photo's growth.
    ///
    /// `asked`: for a job someone is waiting on (`JobKind.isAsked`), with no camera live — the host
    /// side counts on more of the host (`BudgetTuning.askedFloorReserve`).
    static func compute(_ reading: MemoryReading, frontend: FrontendState,
                        tuning: BudgetTuning = BudgetTuning(), cameraWarm: Bool = false,
                        asked: Bool = false) -> MemoryBudget {
        let asked = asked && !frontend.cameraLive
        let appSide = reading.appAvailable.subtractingOrZero(tuning.appReserve)
        var cameraReserve: UInt64 = 0
        if frontend.cameraLive {
            // Captures in flight, plus one more the shutter could take at any moment.
            let captures = UInt64(max(0, frontend.capturesInFlight) + 1)
            cameraReserve = tuning.cameraGrowth(photoMegapixels: frontend.cameraPhotoMegapixels, warm: cameraWarm) * captures
        }
        let headroom = reading.phoneHeadroom + (asked ? UInt64(Double(reading.compressed) * tuning.askedCompressedShare) : 0)
        let phoneSide = headroom.subtractingOrZero(cameraReserve)
            .subtractingOrZero(asked ? tuning.askedFloorReserve : tuning.floorReserve)
        let tighter = min(appSide, phoneSide)
        let keep = 1 - (asked ? tuning.askedMargin : tuning.margin)
        return MemoryBudget(bytes: UInt64(Double(tighter) * keep), appSide: appSide, phoneSide: phoneSide,
                            appBytes: UInt64(Double(appSide) * keep), phoneBytes: UInt64(Double(phoneSide) * keep),
                            cameraReserve: cameraReserve, binding: appSide <= phoneSide ? .allowance : .phone)
    }

    /// Whether a job of this cost may run. `derate` is how much of the budget
    /// the job is trusted with after a pressure event (1 otherwise).
    func fits(_ cost: CostEstimate, derate: Double = 1) -> Bool {
        let d = derate.clamped(to: 0.1...1)
        return Double(cost.peakBytes) <= Double(appBytes) * d && Double(cost.phoneBytes) <= Double(phoneBytes) * d
    }
}

extension UInt64 {
    func subtractingOrZero(_ other: UInt64) -> UInt64 { self > other ? self - other : 0 }
    /// Megabytes (2^20), as every figure in RFC-035 and RFC-036.
    var megabytes: Double { Double(self) / 1_048_576 }
}
