// imgdiff: how far two PNGs of the same size differ, and where.
// usage: imgdiff <a.png> <b.png> <out.png> [x0 y0 x1 y1]     (the region, in pixels)
//
// Writes |a - b|, brightened four times, and prints the share of pixels that differ by more than
// 24 of 255 in any channel and the box that holds them. Two renderings of the same strokes differ
// along their edges only; a part that has moved shows as a doubled outline.
import AppKit
let a = CommandLine.arguments
guard a.count >= 4 else { print("usage: imgdiff <a.png> <b.png> <out.png> [x0 y0 x1 y1]"); exit(2) }
func load(_ p: String) -> (CGContext, Int, Int)? {
    guard let img = NSImage(contentsOfFile: p), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let w = cg.width, h = cg.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (ctx, w, h)
}
guard let (ca, w, h) = load(a[1]), let (cb, wb, hb) = load(a[2]) else { print("cannot read the images"); exit(1) }
guard w == wb, h == hb else { print("sizes differ: \(w)x\(h) against \(wb)x\(hb)"); exit(1) }
var x0 = 0, y0 = 0, x1 = w, y1 = h
if a.count >= 8, let v0 = Int(a[4]), let v1 = Int(a[5]), let v2 = Int(a[6]), let v3 = Int(a[7]) { x0 = v0; y0 = v1; x1 = min(v2, w); y1 = min(v3, h) }
let pa = ca.data!.assumingMemoryBound(to: UInt8.self), pb = cb.data!.assumingMemoryBound(to: UInt8.self)
var out = [UInt8](repeating: 255, count: w * h * 4)
var over = 0, total = 0, sum = 0.0
var bx0 = w, by0 = h, bx1 = -1, by1 = -1
for y in 0..<h {
    for x in 0..<w {
        let i = (y * w + x) * 4
        var worst = 0
        for c in 0..<3 {
            let d = abs(Int(pa[i + c]) - Int(pb[i + c]))
            worst = max(worst, d)
            out[i + c] = UInt8(min(255, d * 4))
        }
        guard x >= x0, x < x1, y >= y0, y < y1 else { continue }
        total += 1; sum += Double(worst)
        if worst > 24 { over += 1; bx0 = min(bx0, x); by0 = min(by0, y); bx1 = max(bx1, x); by1 = max(by1, y) }
    }
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
out.withUnsafeBufferPointer { rep.bitmapData!.update(from: $0.baseAddress!, count: w * h * 4) }
try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: a[3]))
let share = total > 0 ? Double(over) / Double(total) * 100 : 0
let box = bx1 >= 0 ? "x \(bx0)…\(bx1), y \(by0)…\(by1)" : "none"
print(String(format: "differs in %.2f%% of %d px (mean %.2f of 255); box %@", share, total, total > 0 ? sum / Double(total) : 0, box))
