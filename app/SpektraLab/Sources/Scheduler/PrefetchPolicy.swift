//  PrefetchPolicy.swift — how many of the develop page's neighbours a full-size inspection makes ahead.
//
//  `MacRenderCache` makes the filmstrip's neighbours of a frame inspected at full size ahead of the person,
//  one at a time and below every job someone waits on. Each is a full-size decode and render: on this Mac
//  (36 GB, 2026-11-13, `MacMemoryCheck`) 75 MB for an 8 MP ORF, 1.7 GB for a 24 MP RW2, 1.7 GB for a 45 MP
//  NEF and 6.3 GB for a 102 MP RAF over the footprint before it, and the four of them back to back took the
//  app 8.7 GB over its rest. On a 16 GB Mac, with the system and a browser beside it, that is the compressor
//  and then swap: the reporter's "degrades over use" (DIAG-2026-11-13 Part 2 item 2).
//
//  - **The owner's decision (2026-11-13): on a Mac with 16 GB or less, +1 only** — the next frame the way the
//    person is going. Above 16 GB, today's +1, −1, +2, −2.
//  - **None below a floor of headroom, whatever the Mac** (`allows`): a prefetch is speculative work, so it
//    starts only where the host's free + inactive + purgeable pages, once the prefetch's own price is paid
//    (the cost model's host bytes for its job), keep `floorBytes`. No share of the compressor is counted: that
//    is memory the host makes by compressing more, which a prefetch must never cause.
//  - The memory is **injectable** (`physicalMemory`, and a debug build's `SPK_SIMULATE_RAM_GB`), so the 16 GB
//    rule is checked on a Mac with more (`tools/scheduler_selftest.swift`, `MacMemoryCheck`).
//
//  Foundation only: the scheduler's self-test compiles it.

import Foundation

struct PrefetchPolicy: Equatable, Sendable {
    /// The Mac's physical memory, as `ProcessInfo` reports it (a 16 GB Mac: 17,179,869,184 B).
    var physicalMemory: UInt64

    /// 16 GB and less: +1 only.
    static let smallMacMemory: UInt64 = 16 << 30

    /// **What the host keeps once a prefetch is paid for**: 3 GB, two measured things added.
    ///
    /// - **600 MB**: where the operating system declared critical memory pressure on the reference device
    ///   (`BudgetTuning.floorReserve`, measured), the scheduler's own floor for a job nobody waits on.
    /// - **2,400 MB**: the dearest thing the person's next step asks — the stepped-to frame's page develop,
    ///   which is a RAW's first open where its proxy is not made yet (a prefetch makes the full render, not the
    ///   proxy). Measured on this Mac after this round's banding (`RawOpen`): 2,385 MB for a 102 MP RAF and
    ///   2,317 for a 60 MP DNG at most, 0.3–1.0 GB for 8–45 MP. Rounded up.
    ///
    /// So a prefetch never leaves the host less than the page's own next develop and the critical level.
    var floorBytes: UInt64 = (600 + 2_400) << 20

    /// This Mac's: its physical memory, or — in a debug build — `SPK_SIMULATE_RAM_GB`, for a check of the
    /// 16 GB rule on a Mac with more.
    static func current() -> PrefetchPolicy {
        #if DEBUG
        if let text = ProcessInfo.processInfo.environment["SPK_SIMULATE_RAM_GB"], let gb = Double(text), gb > 0 {
            return PrefetchPolicy(physicalMemory: UInt64(gb * 1_073_741_824))
        }
        #endif
        return PrefetchPolicy(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    /// Whether this is a Mac of 16 GB or less.
    var isSmallMac: Bool { physicalMemory <= Self.smallMacMemory }

    /// The neighbours made ahead, as steps from the frame shown, in the order they are made: the way the person
    /// is going first (`direction` +1 after a step forward, −1 after a step back), `reach` each side — or the
    /// next one alone on a small Mac.
    func offsets(direction: Int, reach: Int) -> [Int] {
        let d = direction >= 0 ? 1 : -1
        if isSmallMac { return [d] }
        var out: [Int] = []
        for k in 1...max(reach, 1) { out += [d * k, -d * k] }
        return out
    }

    /// Whether a prefetch priced at `cost` bytes of the host may start with `headroom` (free + inactive +
    /// purgeable): only where `floorBytes` is left once it is paid.
    func allows(cost: UInt64, headroom: UInt64) -> Bool {
        headroom >= cost.addingReportingOverflow(floorBytes).partialValue
    }
}
