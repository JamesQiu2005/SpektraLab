// sf_symbols: Apple's own SF Symbols as AppKit draws them, as PNGs for the drawings (gen_layers.py, kit.py).
//
// stdin, one request a line: <name> \t <point size> \t <weight> \t <rrggbb> \t <scale> \t <out.png>
// stdout, one line each:     "<name> <w> <h>" in points; "MISSING <name>" and exit 1 for a name this Mac does not
//                            know: a drawing never shows a blank where a symbol should be.
import AppKit

setvbuf(stdout, nil, _IOLBF, 0)      // one answer a line, at once: the generator waits for each
let weights: [String: NSFont.Weight] = ["regular": .regular, "medium": .medium, "semibold": .semibold, "bold": .bold]
while let line = readLine() {
    let p = line.components(separatedBy: "\t")
    guard p.count == 6, let pt = Double(p[1]), let w = weights[p[2]], let hex = UInt32(p[3], radix: 16), let scale = Double(p[4]) else { fatalError("bad request: \(line)") }
    guard let base = NSImage(systemSymbolName: p[0], accessibilityDescription: nil) else { print("MISSING \(p[0])"); exit(1) }
    let ink = NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: w).applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
    guard let img = base.withSymbolConfiguration(cfg) else { exit(1) }
    let s = img.size
    let pw = Int((s.width * scale).rounded(.up)), ph = Int((s.height * scale).rounded(.up))
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
    rep.size = s
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(origin: .zero, size: s))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: p[5]))
    print("\(p[0]) \(s.width) \(s.height)")
}
