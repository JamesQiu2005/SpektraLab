//  hdr_histogram_preview.swift — renders the histogram plot (HistogramPlot.swift, the app's own view) from a
//  synthetic picture to a PNG: `tools/hdr_histogram_preview.sh [out.png]`. Three plots, as the panel shows them:
//  Capture One style with Enable HDR on, SpektraLab style with it on, and Capture One style without a look.
//
//  HDR port, 2026-11-06, D7. It is built for Mac Catalyst
//  (the app's `Theme` is UIKit's), so the PNG is written with ImageIO, not AppKit; the look's tables are made
//  from the synthetic curve as tools/hdr_histogram_selftest.swift makes them; the plots are the Mac panel's
//  (its plot height and its label size, `HistogramPanel.plot` / `.hdrLabel`), with no plate.

import CoreGraphics
import Foundation
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// The curve tool's channel colours (Edit/CurvePanel.swift, which needs the whole app).
extension CurveChannel {
    var swatch: Color {
        switch self {
        case .red: Color(red: 0xD9 / 255, green: 0x58 / 255, blue: 0x4B / 255)
        case .green: Color(red: 0x5D / 255, green: 0xBB / 255, blue: 0x6A / 255)
        case .blue: Color(red: 0x4A / 255, green: 0x73 / 255, blue: 0xD8 / 255)
        default: Theme.dim
        }
    }
}

/// `FeatureFlags.camera` reads the window's layout under UIKit, which this tool is built with; its file needs the
/// whole app (App/WindowLayout.swift). The camera is no part of a histogram.
enum WindowLayout { static let isPad = true }

/// Layer2Histogram's data shape (the engine's own file needs Metal); the plot reads only this.
struct Layer2Histogram: Equatable, Sendable {
    enum Channel: Int, CaseIterable, Sendable { case red = 0, green, blue, luma }
    var counts: [UInt32]
}

struct Rng {
    var s: UInt64 = 0x9E3779B97F4A7C15
    mutating func next() -> Double {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17
        return Double(s % 1_000_000) / 1_000_000
    }
    mutating func gauss() -> Double { (0..<6).reduce(0) { a, _ in a + next() } - 3 }
}

@main
struct Preview {
    @MainActor static func main() {
        var rng = Rng()
        let w = 160, h = 120
        var px = [UInt8]()
        for y in 0..<h {
            for x in 0..<w {
                // Sky up top (bright blue-white), a mid-tone ground, a few bright lamps.
                let sky = Double(y) / Double(h) < 0.45
                var base = sky ? 0.78 - 0.2 * Double(y) / Double(h) : 0.30 + 0.12 * Double(x) / Double(w)
                if rng.next() < 0.015 { base = 0.97 }
                let g = base + 0.05 * rng.gauss()
                let r = g * (sky ? 0.92 : 1.05), b = g * (sky ? 1.08 : 0.85)
                func code(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
                px += [code(r), code(g), code(b), 255]
            }
        }
        let ramp = (0..<256).map { i -> Double in
            let l2y = -12 + 12 * Double(i) / 255
            return min(2, max(0, (l2y + 3) / 3 * 2))
        }
        let step = 12.0 / 255
        let slope = ramp.indices.map { i -> Float in
            let a = ramp[max(0, i - 1)], b = ramp[min(255, i + 1)]
            return Float(max(0, (b - a) / (Double(min(255, i + 1) - max(0, i - 1)) * step)))
        }
        let look = HDRLook(curve: HDRGainCurve(name: "synthetic", headroom: 4, log2Gain: ramp),
                           tables: HDRGrainGain.Tables(ks: ramp.map { Float($0) }, slope: slope, lo: -12, hi: 0, top: 2, kappa: 1, rhoMax: 2, tau: 0.1))
        let zone = px.withUnsafeBufferPointer { HDRHistogram.zone(rgba: $0.baseAddress!, width: w, height: h, look: look, weight: 1) }
        // The same picture's SDR histogram, bins as the engine's kernel makes them.
        var sdr = [UInt32](repeating: 0, count: 1024)
        for i in 0..<(w * h) {
            let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
            let y = Int((0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)).rounded())
            sdr[r] += 1; sdr[256 + g] += 1; sdr[512 + b] += 1; sdr[768 + y] += 1
        }
        let plain = Layer2Histogram(counts: sdr)
        print("pixels past white: \(zone.inZone) of \(zone.samples)")

        func card(_ title: String, _ style: HistogramStyle, _ zone: HDRZone?, size: CGSize, label: CGFloat) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                HistogramPlot(h: plain, zone: zone, style: style, labelSize: label)
                    .frame(width: size.width, height: size.height)
            }
        }
        let sheet = VStack(alignment: .leading, spacing: 18) {
            // The Mac column's panel: 393 Catalyst points less the card's margins (12 + 14 a side), 84 tall, words at 10.
            card("Panel, Capture One style, Enable HDR on", .captureOne, zone, size: CGSize(width: 341, height: 84), label: 10)
            card("Panel, SpektraLab style, Enable HDR on", .spektraLab, zone, size: CGSize(width: 341, height: 84), label: 10)
            card("Panel, Capture One style, no look (as before)", .captureOne, nil, size: CGSize(width: 341, height: 84), label: 10)
            card("Panel, SpektraLab style, no look (as before)", .spektraLab, nil, size: CGSize(width: 341, height: 84), label: 10)
        }
        .padding(18)
        .background(Theme.plot)
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 3
        guard let cg = renderer.cgImage else { print("no image"); exit(1) }
        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "hdr_histogram_preview.png"
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { print("cannot write \(out)"); exit(1) }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { print("cannot write \(out)"); exit(1) }
        print("wrote \(out)")
    }
}
