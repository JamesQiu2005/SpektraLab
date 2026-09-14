//  MemorySampler.swift — the one source of memory numbers in the app.
//
//  RFC-016 §3 (`memory`) and §6: `phys_footprint` at boundaries — after the
//  decode, after `engine.open`, after the first print, after an export, on a
//  frame switch — plus the session peak, and the *same* numbers feeding the
//  Settings page's live readout.
//
//  It is one type on purpose. §8's fifth check is "the memory numbers are the
//  same numbers": if the page and the log can each take their own reading,
//  they will eventually disagree and the page will be the one people believe.
//  So a sample is a value with a sequence number, the record cites that
//  sequence number, the readout cites it too, and reading the readout takes no
//  sample at all — there is exactly one place in the app that asks the kernel
//  how much memory this process is using.
//
//  Measured points this exists to make visible (RFC-016 §1.5): 7.6 GB at
//  45 MP, 9.7 at 60 MP, 11.4 at 151 MP.

import Foundation

/// One reading, and its identity. `seq` is what makes "the readout and the
/// record agree" a checkable claim rather than a hopeful one.
struct MemorySample: Sendable, Equatable {
    let seq: Int
    let at: Date
    /// `phys_footprint`: what the system counts against this process, and the
    /// number the jetsam killer uses — not `resident_size`, which excludes
    /// compressed and swapped pages and under-reports a render in progress.
    let footprintBytes: UInt64
    /// The largest footprint seen this session, at this sample.
    let peakBytes: UInt64
    /// Free + inactive + speculative pages. "How much room is there" rather
    /// than "how much is unallocated": free memory alone reads as zero on a
    /// healthy Mac that has been up for a week.
    let freeBytes: UInt64

    var footprintMB: Double { Double(footprintBytes) / 1_000_000 }
    var peakMB: Double { Double(peakBytes) / 1_000_000 }
    var freeMB: Double { Double(freeBytes) / 1_000_000 }

    /// Signed accounting gap: arena bytes minus this process footprint.
    /// Negative means the process holds more than the arena accounts for.
    func arenaFootprintGapMB(arenaBytes: Int) -> Double {
        Double(arenaBytes) / 1_000_000 - footprintMB
    }
}

final class MemorySampler: @unchecked Sendable {
    private struct Limits: Sendable {
        var reserveBytes: UInt64 = 0
        var capBytes: UInt64 = .max
    }
    private struct State {
        var current: MemorySample?
        var peakBytes: UInt64 = 0
        var count = 0
    }

    private let state = Guarded(State())
    private let limits = Guarded(Limits())
    private let log: Log
    let arena: MemoryArena
    private let readFootprint: @Sendable () -> UInt64
    private let readFree: @Sendable () -> UInt64
    private let clock: @Sendable () -> Date

    init(log: Log = .shared, arena: MemoryArena = MemoryArena(),
         readFootprint: @escaping @Sendable () -> UInt64 = MemorySampler.footprintBytes,
         readFree: @escaping @Sendable () -> UInt64 = MemorySampler.freeBytes,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.log = log
        self.arena = arena
        self.readFootprint = readFootprint
        self.readFree = readFree
        self.clock = clock
    }

    /// The last sample taken. The Settings readout reads *this* — it never
    /// takes one of its own (§8.5).
    var current: MemorySample? { state.value.current }
    var peak: UInt64 { state.value.peakBytes }
    /// How many samples this session has taken. A readout that quietly took
    /// its own would move this, which is the thing the check watches.
    var sampleCount: Int { state.value.count }

    /// The policy numbers for the next enforcement pass. `Diagnostics` updates
    /// these when the Settings rows change; the arena still receives only
    /// samples, never a kernel call.
    func setLimits(reserveBytes: UInt64, capBytes: UInt64) {
        limits.withLock {
            $0.reserveBytes = reserveBytes
            $0.capBytes = capBytes
        }
    }

    /// Take a sample and record it.
    ///
    /// `level` is `info` for the boundaries §3 names — those are the ones a
    /// log is read for afterwards — and `debug` for the live readout's tick,
    /// which at Normal reaches the ring and not the file. Both write a record:
    /// a number the page shows and the log does not has no provenance.
    @discardableResult
    func sample(_ reason: String, level: LogLevel = .info,
                frame: String? = nil) -> MemorySample {
        // Admission can evict between boundary samples, so drain that first;
        // the record then covers every eviction since the previous record.
        var evicted = arena.takeEvictionReport()
        var sample = readSample()
        let limits = limits.value

        while true {
            let bytes = arena.enforce(sample: sample, reserve: limits.reserveBytes,
                                      cap: limits.capBytes)
            evicted.add(arena.takeEvictionReport())
            guard bytes > 0 else { break }
            // `enforce` acts on the sample it was handed. Re-read before it is
            // asked again; this is the rule that keeps a stale free reading
            // from causing a second eviction batch.
            sample = readSample()
        }

        let kinds = evicted.kinds
            .sorted { $0.key == $1.key ? $0.value < $1.value : $0.key < $1.key }
            .map { "\($0.key):\($0.value / 1_000_000)" }
            .joined(separator: ",")
        var fields: [LogField] = [
            .init("reason", reason),
            .init("seq", sample.seq),
            .init("mb", sample.footprintMB),
            .init("peak_mb", sample.peakMB),
            .init("free_mb", sample.freeMB),
            .init("bytes", Double(sample.footprintBytes)),
            .init("arena_mb", Double(arena.totalBytes) / 1_000_000),
            .init("arena_evictable_mb", Double(arena.evictableBytes) / 1_000_000),
            .init("arena_kinds", arena.breakdown().map { "\($0.kind):\($0.bytes / 1_000_000)" }.joined(separator: ",")),
            .init("arena_footprint_gap_mb",
                  sample.arenaFootprintGapMB(arenaBytes: arena.totalBytes)),
            .init("evicted_mb", Double(evicted.bytes) / 1_000_000),
            .init("evicted_kinds", kinds),
        ]
        if let frame { fields.append(.init("frame", frame)) }
        log.log(level, .memory, "footprint", fields)
        return sample
    }

    /// Read the kernel-backed numbers and advance the sample identity. This is
    /// split from `sample` so one boundary can re-read after eviction without
    /// writing a second log record.
    private func readSample() -> MemorySample {
        let footprint = readFootprint()
        let free = readFree()
        return state.withLock { s -> MemorySample in
            s.count += 1
            s.peakBytes = max(s.peakBytes, footprint)
            let sample = MemorySample(seq: s.count, at: clock(), footprintBytes: footprint,
                                      peakBytes: s.peakBytes, freeBytes: free)
            s.current = sample
            return sample
        }
    }

    /// What a screen of memory the app can plan on: the free pool the OS is
    /// willing to hand out without paging, in the same units as the readout.
    var freeBytes: UInt64 { readFree() }

    // MARK: - the kernel

    /// This process's `phys_footprint`.
    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Free + inactive + speculative, in bytes: memory the system can hand out
    /// without pushing anything to swap.
    static func freeBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        // `host_page_size` rather than the `vm_page_size` global: the bare
        // variable is shared mutable state, which Swift 6 will not let a
        // `Sendable` type read, and the call is the honest way to ask anyway.
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return 0 }
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.speculative_count)
        return pages * UInt64(pageSize)
    }
}
