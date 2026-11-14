// capture_windows.swift -- every on-screen window of one process, each captured by the window server
// (`screencapture -l`), for a check that has a menu open: a context menu is a window of its own, which a capture of the
// app's main window does not hold (`tools/variant_check.sh --context-menu`).
//
//   capture_windows <pid> <out prefix>
//
// Writes <out prefix>-<layer>-<n>.png per window, the main window as layer 0. Only the process's own windows: nothing
// else on the screen is captured.
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 3, let pid = Int(args[1]) else { print("usage: capture_windows <pid> <out prefix>"); exit(2) }
let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
var n = 0
for w in list where (w[kCGWindowOwnerPID as String] as? Int) == pid {
    guard let number = w[kCGWindowNumber as String] as? Int else { continue }
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let bounds = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    guard (bounds["Width"] ?? 0) > 20, (bounds["Height"] ?? 0) > 20 else { continue }
    let file = "\(args[2])-\(layer)-\(n).png"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l\(number)", file]
    try? p.run(); p.waitUntilExit()
    print("captured window \(number) layer \(layer) \(Int(bounds["Width"] ?? 0))x\(Int(bounds["Height"] ?? 0)) -> \(file)")
    n += 1
}
