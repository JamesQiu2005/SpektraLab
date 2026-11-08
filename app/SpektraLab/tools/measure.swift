// measure: where the ink is in a strip of a PNG, in points.
// usage: measure <png> <x0> <x1> <y0> <y1> [rows|cols] [scale]      (the strip, in points)
//
// Prints the runs of rows (or columns) in the strip that hold anything other than the strip's own
// ground, so a line of type or a rule can be read off a snapshot and off its drawing as numbers:
//   tools/measure.swift build/snapshots/B5.png 20 200 100 400
// A run's edges are where the ink starts and stops; a line of type's baseline is the bottom of a
// run with no descenders. `scale` is the image's pixels per point (2).
import AppKit
let a = CommandLine.arguments
guard a.count >= 6, let img = NSImage(contentsOfFile: a[1]),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let px0 = Double(a[2]), let px1 = Double(a[3]), let py0 = Double(a[4]), let py1 = Double(a[5]) else {
    print("usage: measure <png> <x0> <x1> <y0> <y1> [rows|cols] [scale]"); exit(2)
}
let byCols = a.count > 6 && a[6] == "cols"
let scale = a.count > 7 ? Double(a[7]) ?? 2 : 2
let w = cg.width, h = cg.height
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
let x0 = max(0, Int(px0 * scale)), x1 = min(w, Int(px1 * scale)), y0 = max(0, Int(py0 * scale)), y1 = min(h, Int(py1 * scale))
func lum(_ x: Int, _ y: Int) -> Int { let i = (y * w + x) * 4; return (Int(p[i]) * 3 + Int(p[i + 1]) * 6 + Int(p[i + 2])) / 10 }
// The ground: the most common luminance in the strip.
var hist = [Int](repeating: 0, count: 256)
for y in y0..<y1 { for x in x0..<x1 { hist[lum(x, y)] += 1 } }
let ground = hist.enumerated().max { $0.element < $1.element }!.offset
func inked(_ x: Int, _ y: Int) -> Bool { abs(lum(x, y) - ground) > 28 }
var marks: [Bool] = []
if byCols { for x in x0..<x1 { marks.append((y0..<y1).contains { inked(x, $0) }) } }
else { for y in y0..<y1 { marks.append((x0..<x1).contains { inked($0, y) }) } }
let origin = Double(byCols ? x0 : y0)
var start: Int? = nil
var out: [String] = []
for (i, on) in (marks + [false]).enumerated() {
    if on, start == nil { start = i }
    if !on, let s = start {
        let lo = (origin + Double(s)) / scale, hi = (origin + Double(i)) / scale
        out.append(String(format: "%.1f–%.1f (%.1f)", lo, hi, hi - lo))
        start = nil
    }
}
print((byCols ? "cols " : "rows ") + (out.isEmpty ? "nothing" : out.joined(separator: "  ")))
