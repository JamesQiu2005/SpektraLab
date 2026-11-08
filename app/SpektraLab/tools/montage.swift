// montage: tile PNGs left to right at one height, with each one's name under it.
// usage: montage <out.png> <cellHeight> <png>...
import AppKit
let a = CommandLine.arguments
guard a.count >= 4, let cellH = Double(a[2]) else { print("usage: montage <out.png> <cellHeight> <png>..."); exit(2) }
let imgs: [(String, NSImage)] = a[3...].compactMap { p in
    guard let i = NSImage(contentsOf: URL(fileURLWithPath: p)) else { return nil }
    return (URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent, i)
}
guard !imgs.isEmpty else { print("no images"); exit(1) }
let gap = 16.0, labelH = 30.0
var widths: [Double] = []
for (_, i) in imgs {
    let rep = i.representations.first!
    widths.append(Double(rep.pixelsWide) * cellH / Double(rep.pixelsHigh))
}
let W = Int(widths.reduce(0, +) + gap * Double(imgs.count + 1)), H = Int(cellH + labelH + gap * 2)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(white: 0.22, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
var x = gap
for (k, (name, i)) in imgs.enumerated() {
    i.draw(in: NSRect(x: x, y: gap + labelH, width: widths[k], height: cellH), from: .zero, operation: .sourceOver, fraction: 1)
    (name as NSString).draw(at: NSPoint(x: x, y: gap * 0.5),
        withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.white])
    x += widths[k] + gap
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[1]))
print("\(a[1]) \(W)x\(H)")
