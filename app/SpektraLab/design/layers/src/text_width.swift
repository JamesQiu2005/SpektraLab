// text_width: how wide a line is in the system's own font, as CoreText lays it out, for the drawings' pills
// and their fit checks (gen_layers.py).
//
// stdin, one request a line:  <size> \t <weight: regular|medium|semibold|bold> \t <text>
// stdout, one line each:      <width in points>
//
// The font is NSFont.systemFont(ofSize:weight:), the face `Theme.Font.ui` asks for; a character SF Pro does not
// have falls back as the system's cascade says (PingFang SC for Chinese). A line within a point of its room
// should be read as not fitting.
import AppKit
import CoreText

setvbuf(stdout, nil, _IOLBF, 0)
let weights: [String: NSFont.Weight] = ["regular": .regular, "medium": .medium, "semibold": .semibold, "bold": .bold]
while let line = readLine() {
    let p = line.components(separatedBy: "\t")
    guard p.count == 3, let size = Double(p[0]), let weight = weights[p[1]] else { fatalError("bad request: \(line)") }
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
    let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: p[2], attributes: attrs))
    print(String(format: "%.2f", CTLineGetTypographicBounds(ctLine, nil, nil, nil)))
}
