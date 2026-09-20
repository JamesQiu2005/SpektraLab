// footprint-probe.swift — sample another process's phys_footprint at a fixed
// interval and print `epoch_ms bytes` per line.
//
// Why this and not Activity Monitor: Activity Monitor refreshes every 1-5 s and
// the events we are attributing (a Core Image decode, a full render) last one to
// three seconds each, so it can miss a peak entirely or catch a random point on
// the curve. Why this and not the app's own log: the app samples at *boundaries*
// -- after the decode, after the render -- so it reports the footprint once the
// transient has already been given back, which is a lower bound on the peak and
// not the peak.
//
// `ri_phys_footprint` from `proc_pid_rusage` is the same quantity as
// `task_vm_info`'s `phys_footprint`, which is what `MemorySampler` reads and what
// Activity Monitor's Memory column shows -- so the numbers are comparable to the
// app's own and to the user's.
import Foundation

guard CommandLine.arguments.count > 2, let pid = Int32(CommandLine.arguments[1]),
      let intervalMs = Double(CommandLine.arguments[2]) else {
    FileHandle.standardError.write("usage: probe <pid> <interval_ms>\n".data(using: .utf8)!)
    exit(2)
}

var info = rusage_info_v4()
let interval = intervalMs / 1000.0

while true {
    let rc = withUnsafeMutablePointer(to: &info) { p -> Int32 in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    if rc != 0 { break }                       // process gone
    let ms = Date().timeIntervalSince1970 * 1000.0
    print("\(Int(ms)) \(info.ri_phys_footprint)")
    fflush(stdout)
    Thread.sleep(forTimeInterval: interval)
}
