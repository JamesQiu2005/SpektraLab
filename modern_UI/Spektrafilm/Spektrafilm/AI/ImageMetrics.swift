//  ImageMetrics.swift — the numbers a proof is judged by before anyone looks
//  at it (AI assistant, ARCHITECTURE §7.14).
//
//  Read from the 8-bit sRGB proof, the same pixels the model is shown, so a
//  number and the picture it describes cannot disagree. They are deliberately
//  plain: clipping, brightness, contrast, colourfulness and cast. Whether the
//  film *holds the scene* is not here — that is the engine's latitude
//  measurement (`ProofSheet.Proof.latitude`), which knows the medium.

import CoreGraphics
import Foundation

struct ImageMetrics: Equatable, Sendable {
    /// Fraction of pixels with any channel at or above 0.98: highlights the
    /// print has run out of.
    var highlightClip: Double
    /// Fraction of pixels with every channel at or below 0.02.
    var shadowClip: Double
    /// Mean Rec. 709 luma of the encoded values, 0…1.
    var meanLuma: Double
    /// Standard deviation of luma: global contrast, 0…0.5.
    var contrast: Double
    /// Hasler & Süsstrunk (2003) colourfulness on 0…255 values: ~15 is muted,
    /// ~45 moderately colourful, above ~80 very colourful.
    var colorfulness: Double
    /// Mean of R − G and of (R + G)/2 − B, −1…1: a magenta (+) / green (−)
    /// and a warm (+) / cool (−) lean of the whole frame.
    var castRG: Double
    var castYB: Double

    /// Nil for an image with no pixels.
    init?(_ image: CGImage) {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = { ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return ctx.data }()
        else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        self.init(rgba: UnsafeBufferPointer(start: px, count: w * h * 4))
    }

    /// From packed 8-bit RGBA (alpha ignored). Separate so a test can hand in
    /// exact pixels.
    init(rgba: UnsafeBufferPointer<UInt8>) {
        let n = rgba.count / 4
        var high = 0, low = 0
        var sumY = 0.0, sumY2 = 0.0
        var sumRG = 0.0, sumRG2 = 0.0, sumYB = 0.0, sumYB2 = 0.0
        for i in 0..<n {
            let r = Double(rgba[i * 4]), g = Double(rgba[i * 4 + 1]), b = Double(rgba[i * 4 + 2])
            // Every channel at or below the floor is the brightest one being so.
            let mx = max(r, g, b)
            if mx >= 0.98 * 255 { high += 1 }
            if mx <= 0.02 * 255 { low += 1 }
            let y = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
            sumY += y; sumY2 += y * y
            let rg = r - g, yb = 0.5 * (r + g) - b
            sumRG += rg; sumRG2 += rg * rg
            sumYB += yb; sumYB2 += yb * yb
        }
        let count = Double(max(n, 1))
        let meanY = sumY / count
        let meanRG = sumRG / count, meanYB = sumYB / count
        func sd(_ s2: Double, _ m: Double) -> Double { (max(0, s2 / count - m * m)).squareRoot() }
        highlightClip = Double(high) / count
        shadowClip = Double(low) / count
        meanLuma = meanY
        contrast = sd(sumY2, meanY)
        let sdRG = sd(sumRG2, meanRG), sdYB = sd(sumYB2, meanYB)
        colorfulness = (sdRG * sdRG + sdYB * sdYB).squareRoot() + 0.3 * (meanRG * meanRG + meanYB * meanYB).squareRoot()
        castRG = meanRG / 255
        castYB = meanYB / 255
    }

    var json: JSONValue {
        func r(_ v: Double, _ places: Double = 1000) -> JSONValue { .number((v * places).rounded() / places) }
        return ["highlightClip": r(highlightClip, 10000), "shadowClip": r(shadowClip, 10000),
                "meanLuma": r(meanLuma), "contrast": r(contrast), "colorfulness": r(colorfulness, 10),
                "castRG": r(castRG), "castYB": r(castYB)]
    }
}
