// exactdiff: are two PNGs of the same size the same picture, to the last level of the last pixel?
// usage: exactdiff <a.png> <b.png>
//
// `imgdiff` answers how far two drawings of the same strokes are apart, and counts a pixel only past
// 24 of 255. This counts every pixel that differs at all: how many, by how much at most, and the box
// that holds them, in pixels. For a change that must not move a pixel (`tools/same_snapshots.sh`), and
// for saying how much two runs of the same build differ on their own (a page with something that
// turns — a busy mark, a ring — is not drawn at the same instant twice).
//
// Exits 0 when no pixel differs, 1 when any does, 2 when the two cannot be compared.
import AppKit
let a = CommandLine.arguments
guard a.count >= 3 else { print("usage: exactdiff <a.png> <b.png>"); exit(2) }
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
guard let (ca, w, h) = load(a[1]), let (cb, wb, hb) = load(a[2]) else { print("cannot read the images"); exit(2) }
guard w == wb, h == hb else { print("sizes differ: \(w)x\(h) against \(wb)x\(hb)"); exit(2) }
let pa = ca.data!.assumingMemoryBound(to: UInt8.self), pb = cb.data!.assumingMemoryBound(to: UInt8.self)
var count = 0, worst = 0
var x0 = w, y0 = h, x1 = -1, y1 = -1
for y in 0..<h {
    for x in 0..<w {
        let i = (y * w + x) * 4
        var d = 0
        for c in 0..<3 { d = max(d, abs(Int(pa[i + c]) - Int(pb[i + c]))) }
        guard d > 0 else { continue }
        count += 1; worst = max(worst, d)
        // A bitmap context's first row is the picture's top one: the box reads top-down, as `imgdiff`'s does.
        x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
    }
}
if count == 0 {
    print("no pixel differs (\(w)x\(h))")
    exit(0)
}
print("\(count) of \(w * h) px differ, by \(worst) of 255 at most; box x \(x0)…\(x1), y \(y0)…\(y1)")
exit(1)
