//  Tools/measure-layout.swift — read a capture and print the geometry the
//  2026-09-17 drawing asserts, in points.
//
//      swift Tools/measure-layout.swift ../design/snapshots/window-16x9.png 2
//
//  Companion to `compare-layout.py`, which measured the *previous* drawing's
//  four floating cards by finding card-coloured rectangles. That drawing is
//  gone — there are no cards to find — and the Python script needs Pillow,
//  which is not something this repository is allowed to depend on (`No
//  Python`, CLAUDE.md). This is the same idea in the toolchain the app is
//  already built with: scan the pixels, find the edges, print the numbers.
//
//  What it reads, and the drawing coordinate each one is checked against:
//
//      left rail   0 … 254        rect x -2.6 w 509.9
//      right rail  1632 … 1920    rect x 3263.9 w 576.1
//      filmstrip   948 … 1080     rect y 1895.3 h 264.7
//      bar         y 5 … 36       rect y 9.4 h 61.8, inset 9 either side
//      hairlines   the section boundaries in each rail, and their pitch
//
//  The probe rows are chosen, not arbitrary: a rail is measured just under
//  its header, because at mid-height it contains a *list well*, which is
//  ground-coloured on purpose and would be read as the canvas. The filmstrip
//  is measured off-centre for the same kind of reason — the empty strip has a
//  caption across its middle.

import Foundation
import CoreGraphics
import ImageIO


let a = CommandLine.arguments
let url = URL(fileURLWithPath: a[1])
let scale = a.count > 2 ? Int(a[2])! : 2
guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { exit(1) }
let w = img.width, h = img.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    let i = (y * w + x) * 4
    return (Int(px[i]), Int(px[i+1]), Int(px[i+2]))
}
func near(_ c: (Int, Int, Int), _ hex: UInt32, _ tol: Int = 6) -> Bool {
    let r = Int((hex >> 16) & 0xFF), g = Int((hex >> 8) & 0xFF), b = Int(hex & 0xFF)
    return abs(c.0 - r) <= tol && abs(c.1 - g) <= tol && abs(c.2 - b) <= tol
}
func pt(_ v: Int) -> String { String(format: "%.1f", Double(v) / Double(scale)) }

let card: UInt32 = 0x2C2D2B, ground: UInt32 = 0x5F5F5F, rule: UInt32 = 0xB5B5B6

print("capture \(w)×\(h) px  =  \(pt(w))×\(pt(h)) pt")

// Rail edges: scan a row just under the header, where a rail is plain card
// and the centre column is plain ground. (Mid-height would land in a list
// well, which is ground-coloured on purpose and would be read as the canvas.)
let probeY = 44 * scale
var leftEdge = 0
while leftEdge < w, near(rgb(leftEdge, probeY), card) { leftEdge += 1 }
var rightEdge = w - 1
while rightEdge > 0, near(rgb(rightEdge, probeY), card) { rightEdge -= 1 }
print("left rail   0 … \(pt(leftEdge))")
print("right rail  \(pt(rightEdge + 1)) … \(pt(w))   width \(pt(w - rightEdge - 1))")

// Filmstrip: down the middle of the centre column, the last ground→card edge.
let midX = leftEdge + (rightEdge - leftEdge) / 5   // off-centre: the empty strip has a caption in the middle
var stripTop = h - 1
while stripTop > 0, near(rgb(midX, stripTop), card) { stripTop -= 1 }
print("filmstrip   \(pt(stripTop + 1)) … \(pt(h))   height \(pt(h - stripTop - 1))")

// The floating bar, down the same column.
var barTop = 0
while barTop < h, !near(rgb(midX, barTop), card) { barTop += 1 }
var barBot = barTop
while barBot < h, near(rgb(midX, barBot), card) { barBot += 1 }
print("bar         y \(pt(barTop)) … \(pt(barBot))   height \(pt(barBot - barTop))")
// …and its two ends, on its own centreline.
let barMidY = (barTop + barBot) / 2
var barL = leftEdge
while barL < w, !near(rgb(barL, barMidY), card) { barL += 1 }
var barR = rightEdge
while barR > 0, !near(rgb(barR, barMidY), card) { barR -= 1 }
print("            x \(pt(barL)) … \(pt(barR + 1))   inset \(pt(barL - leftEdge)) / \(pt(rightEdge + 1 - barR - 1))")

// Hairlines in a rail: scan a column inside it for the rule colour.
func hairlines(label: String, x: Int) {
    var ys: [Int] = []
    var y = 0
    while y < h {
        if near(rgb(x, y), rule, 14) {
            let start = y
            while y < h, near(rgb(x, y), rule, 14) { y += 1 }
            if y - start <= scale * 2 { ys.append(start) }
        } else { y += 1 }
    }
    print("\(label) hairlines at " + ys.map { pt($0) }.joined(separator: ", "))
    if ys.count > 1 {
        let gaps = zip(ys.dropFirst(), ys).map { Double($0 - $1) / Double(scale) }
        print("\(label) gaps       " + gaps.map { String(format: "%.1f", $0) }.joined(separator: ", "))
    }
}
hairlines(label: "left ", x: max(2, leftEdge - 6))
hairlines(label: "right", x: min(w - 3, rightEdge + 8))
