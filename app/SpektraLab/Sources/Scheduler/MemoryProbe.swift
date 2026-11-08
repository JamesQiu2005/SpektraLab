//  MemoryProbe.swift — how much memory there is, read from the system.
//
//  Two different questions (RFC-036 §2.1):
//
//  - **the app's allowance**: on the Mac there is none, so the physical memory
//    stands in (`appAvailable`);
//  - **the machine's headroom**: free + inactive + purgeable pages
//    (`host_statistics64`).
//
//  The app's own footprint is `phys_footprint`, never RSS, which cannot see the
//  Metal pool (AGENTS.md). It lags a release by up to ~2 s; the engine's own
//  `spk_memory_report` is the truth about what the engine holds.

import Foundation

struct MemoryReading: Codable, Equatable, Sendable {
    /// The app's remaining allowance, in bytes.
    var appAvailable: UInt64
    /// The host's page counts, in bytes.
    var free: UInt64
    var inactive: UInt64
    var purgeable: UInt64
    var wired: UInt64
    var compressed: UInt64
    /// This process's `phys_footprint`.
    var footprint: UInt64

    /// Reclaimable host pages used as the budget's conservative starting point.
    /// This excludes compressed memory and any additional reclamation by the OS.
    var phoneHeadroom: UInt64 { free + inactive + purgeable }
}

enum MemoryProbe {
    static func read() -> MemoryReading {
        let (free, inactive, purgeable, wired, compressed) = hostPages()
        return MemoryReading(appAvailable: appAvailable(), free: free, inactive: inactive,
                             purgeable: purgeable, wired: wired, compressed: compressed,
                             footprint: footprint())
    }

    /// The Mac has no per-app allowance, so the physical memory stands in and only
    /// the machine's headroom binds.
    static func appAvailable() -> UInt64 {
        return ProcessInfo.processInfo.physicalMemory
    }

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    private static func hostPages() -> (UInt64, UInt64, UInt64, UInt64, UInt64) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0, 0, 0, 0) }
        let page = UInt64(vm_kernel_page_size)
        return (UInt64(stats.free_count) * page, UInt64(stats.inactive_count) * page,
                UInt64(stats.purgeable_count) * page, UInt64(stats.wire_count) * page,
                UInt64(stats.compressor_page_count) * page)
    }
}
