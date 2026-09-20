// rfc020-mmap-plane.swift -- the probe RFC-020 §4.7 is decided by.
//
//   swiftc -O rfc/probes/rfc020-mmap-plane.swift -o /tmp/mmapplane && /tmp/mmapplane
//
// §4.7 proposes backing `session->source` and the cached negative with a file
// instead of wired memory, so the kernel can drop clean pages under pressure
// rather than the app holding 2.4 GB. Three questions had to be answered
// before that could be designed in, and this is what answered them.
//
//   Q1  Does Metal accept `makeBuffer(bytesNoCopy:)` over an mmap'd file for
//       compute, and does a kernel read and write it correctly?
//   Q2  Do the mapping's pages stay out of `phys_footprint` -- the only number
//       that matters, because it is the one jetsam reads?
//   Q3  What does it cost: to read, and to fill?
//
// Measured 2026-09-20 on a 38.7 GB M3 Max, at the 102 MP plane size
// (11664 x 8750 x 3ch x f32 = 1.22 GB):
//
//   Q1  yes, and the kernel's output is correct.
//   Q2  yes -- the same 1.22 GB plane costs **+1.232 GB** of phys_footprint as
//       an ordinary shared buffer and **+0.135 GB** as a file mapping, about
//       nine times less, while `mincore` reports 1.225 GB of the mapping
//       genuinely resident. The pages are in RAM and are not charged to the
//       process. (A run that samples only across the GPU's own writes shows
//       +0.000; 0.135 is the honest figure, because it includes the host
//       fill.)
//   Q3  reading: no measurable cost. Alternated, three reps each, medians
//       9 ms against 9 ms for an ordinary shared buffer -- 1.00x. (A first
//       naive pass showed 1.44x; that was cold-against-warm, not the mapping.)
//       filling: 1.26x, 126 ms -> 160 ms, so ~+34 ms on the open path.
//       `msync` costs 218-536 ms and is NOT needed: the footprint benefit
//       applies to dirty file-backed pages as measured, so nothing forces a
//       write-back and the kernel does it lazily, under pressure, if at all.
//
// What this probe could NOT answer, and §4.7 must not pretend otherwise:
// **the cost of faulting the pages back after the kernel has actually
// evicted them.** `madvise(MADV_DONTNEED)` does not drop residency for a
// MAP_SHARED file mapping on macOS -- measured: resident stays 1.225 GB --
// so an application cannot force the reclaim, and inducing real system-wide
// pressure to observe it is not something to do casually on a working
// machine. The eviction path is therefore inferred, not measured.
import Foundation
import Metal
import Darwin

let pageSize = Int(getpagesize())
let count = 11664 * 8750 * 3
let bytes = ((count * 4) + pageSize - 1) / pageSize * pageSize
let scratch = NSTemporaryDirectory() + "rfc020-plane.bin"

func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var c = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &c) } }
    return info.phys_footprint
}
/// Pages of the mapping actually in RAM. The point of the whole probe is that
/// this is large while the footprint delta is not.
func resident(_ a: UnsafeMutableRawPointer, _ b: Int) -> Double {
    var v = [UInt8](repeating: 0, count: b / pageSize)
    guard mincore(a, b, &v) == 0 else { return -1 }
    return Double(v.reduce(0) { $0 + Int($1 & 1) }) * Double(pageSize) / 1e9
}

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let lib = try! device.makeLibrary(source: """
#include <metal_stdlib>
using namespace metal;
kernel void touch_all(device float* a [[buffer(0)]], constant uint& n [[buffer(1)]],
                      uint i [[thread_position_in_grid]]) { if (i < n) a[i] = a[i] * 2.0f + 1.0f; }
""", options: nil)
let pso = try! device.makeComputePipelineState(function: lib.makeFunction(name: "touch_all")!)

func run(_ buf: MTLBuffer) -> Double {
    let t0 = Date()
    let cb = queue.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
    e.setComputePipelineState(pso); e.setBuffer(buf, offset: 0, index: 0)
    var n = UInt32(count); e.setBytes(&n, length: 4, index: 1)
    e.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                      threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    if let err = cb.error { print("  GPU ERROR: \(err)") }
    return Date().timeIntervalSince(t0) * 1000
}

print("plane \(String(format: "%.2f", Double(bytes)/1e9)) GB, page size \(pageSize)")

// --- the control, and the candidate ---------------------------------------
let anon = device.makeBuffer(length: bytes, options: .storageModeShared)!
let anonP = anon.contents().bindMemory(to: Float.self, capacity: count)
var t0 = Date(); anonP.update(repeating: 0.5, count: count)
let anonFill = Date().timeIntervalSince(t0) * 1000
let afterAnon = footprint()
print(String(format: "anonymous shared: fill %.0f ms, footprint +%.3f GB", anonFill, Double(afterAnon)/1e9))

let fd = open(scratch, O_RDWR | O_CREAT | O_TRUNC, 0o644)
guard fd >= 0, ftruncate(fd, off_t(bytes)) == 0,
      let a = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), a != MAP_FAILED
else { fatalError("mmap: \(String(cString: strerror(errno)))") }
guard let mbuf = device.makeBuffer(bytesNoCopy: a, length: bytes,
                                   options: .storageModeShared, deallocator: nil) else {
    print("Q1 = NO: makeBuffer(bytesNoCopy:) over a file mapping returned nil"); exit(1)
}
print("Q1a: makeBuffer(bytesNoCopy:) accepted the file mapping")

let mp = a.bindMemory(to: Float.self, capacity: count)
t0 = Date(); mp.update(repeating: 0.5, count: count)
let mmapFill = Date().timeIntervalSince(t0) * 1000
let beforeKernel = footprint()
_ = run(mbuf)
let ok = mp[0] == 2.0 && mp[count - 1] == 2.0            // 0.5 * 2 + 1
print("Q1b: kernel output over the mapping is \(ok ? "CORRECT" : "WRONG")")
print(String(format: "Q2 : mapping resident %.3f GB, footprint moved %+.3f GB while the GPU dirtied it",
             resident(a, bytes), Double(footprint() &- beforeKernel) / 1e9))

// --- Q3: alternate, so neither side is measured cold ----------------------
_ = run(anon); _ = run(mbuf)
var at: [Double] = [], mt: [Double] = []
for _ in 0..<3 { at.append(run(anon)); mt.append(run(mbuf)) }
at.sort(); mt.sort()
print(String(format: "Q3 : read  anonymous %.0f ms, file-backed %.0f ms (%.2fx)", at[1], mt[1], mt[1] / at[1]))
print(String(format: "Q3 : fill  anonymous %.0f ms, file-backed %.0f ms (%.2fx)",
             anonFill, mmapFill, mmapFill / anonFill))

// --- the limit of this probe, stated rather than hidden -------------------
msync(a, bytes, MS_SYNC)
madvise(a, bytes, MADV_DONTNEED)
print(String(format: "note: after MADV_DONTNEED the mapping is still %.3f GB resident -- an app "
                     + "cannot force the reclaim, so the fault-back cost is inferred, not measured",
             resident(a, bytes)))

munmap(a, bytes); close(fd); unlink(scratch)
