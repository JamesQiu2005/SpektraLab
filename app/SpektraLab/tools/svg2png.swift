// svg2png: draw SVG files to PNGs at a scale, as macOS draws them (NSImage, CoreSVG).
// usage: svg2png <scale> <outdir> <svg>...
//
// The drawings in design/ name `SF Pro Text`; where that family is not installed CoreSVG falls back
// for the heavier weights, so a drawing's bold titles may render in a rounder face than the app's.
// Hold sizes, positions and colours against the drawing, not the letterforms of a bold title.
import AppKit
let a = CommandLine.arguments
guard a.count >= 4, let scale = Double(a[1]) else { print("usage: svg2png <scale> <outdir> <svg>..."); exit(2) }
let outDir = URL(fileURLWithPath: a[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for p in a[3...] {
    let u = URL(fileURLWithPath: p)
    guard let img = NSImage(contentsOf: u) else { print("FAIL load \(p)"); continue }
    let w = Int((img.size.width * scale).rounded()), h = Int((img.size.height * scale).rounded())
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
    rep.size = img.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.black.setFill(); NSRect(origin: .zero, size: img.size).fill()
    img.draw(in: NSRect(origin: .zero, size: img.size), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let out = outDir.appendingPathComponent(u.deletingPathExtension().lastPathComponent + ".png")
    try? rep.representation(using: .png, properties: [:])?.write(to: out)
    print("\(u.lastPathComponent) -> \(w)x\(h)")
}
