//  ExportEstimate.swift — about how large the file a recipe makes of a picture will be (the owner,
//  2026-11-11: the Export page says the estimated size; for a batch, the picture shown's).
//
//  **Measured on the picture, not a table.** A file's size is mostly the picture's detail — grain, above
//  all — so a bytes-a-pixel table per format would be wrong by a factor between a foggy frame and a
//  grainy one. The frame's kept develop (its picture as the library draws it) is encoded here with the
//  recipe's own encoder and quality, at a sample size, and the bytes a pixel it comes to are scaled to the
//  file's pixels. Nothing is developed for it: a frame with no develop yet is measured on its camera's
//  preview, and says so by being a little less right.
//
//  **The sample is smaller than the file**, and each encoder meets the extra pixels differently: `detail`
//  scales the sample's bytes to the file's by a power of the pixel ratio, fitted per format (measured, below). A 16-bit TIFF's low bits
//  are its develop's own and no 8-bit sample has them, so its size is worked out from the sample's high
//  bits and six bytes a pixel of LZW on the rest (`tiffBytes`).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExportEstimate {
    /// The sample's long edge: large enough that grain is still grain, small enough to encode in a moment
    /// (a 2,048 px HEIF encodes in about 0.1 s on an M-series Mac).
    static let sampleEdge = 2048

    /// What the sample's bytes are multiplied by for a file of `filePixels` pixels from a sample of
    /// `samplePixels`: the pixel ratio to a power of the format's (`detailExponent`). 1 at the sample's size.
    static func detail(_ format: ExportRecipe.Format, quality: Int, filePixels: Double, samplePixels: Double) -> Double {
        guard samplePixels > 0, filePixels > samplePixels else { return 1 }
        return pow(filePixels / samplePixels, detailExponent(format, quality: quality))
    }

    /// How a file's bytes a pixel move as it grows past the sample, as a power of the pixel ratio. Fitted on
    /// `--export-check`'s section D (2026-11-11: three RAWs, 45.4 and 24 MP, every format at full size, JPEG at
    /// 60/80/95, HEIF at 60/80/95), where the raw sample's guess was 0.45–0.60× a JPEG, 1.1–1.45× a HEIF,
    /// 1.7–1.85× a PNG and 1.03–1.14× a TIFF; with these, every one of the 24 files is 0.86–1.08×.
    /// - **JPEG grows** (+0.26 at every quality): the full-size file keeps the grain a 2,048 px sample averages away.
    /// - **HEIF shrinks**, the more the lower its quality (−0.07 at 95, −0.15 at 60): HEVC drops the finer grain.
    /// - **PNG shrinks** (−0.25): its filter predicts a pixel from its neighbours, which are closer alike when there
    ///   are more of them. **A TIFF** is nearly the sample's (−0.04): its low bytes do not compress at any size.
    static func detailExponent(_ format: ExportRecipe.Format, quality: Int) -> Double {
        switch format {
        case .jpeg: 0.26
        case .heif: -0.07 - 0.0023 * Double(95 - quality.clamped(to: 1...100))
        case .png: -0.25
        case .tiff: -0.04
        }
    }

    /// About how many bytes the recipe makes at its planned output dimensions.
    /// Nil where the picture cannot be read or encoded.
    static func bytes(source: URL, metadataFrom original: URL?, recipe: ExportRecipe, output: PixelSize) async -> Int64? {
        guard output.width > 0, output.height > 0 else { return nil }
        let format = recipe.format
        let quality = recipe.quality
        // The full-size model was fitted on the kept preview. Its colour conversion must not
        // amplify that model's scale error. For a reduction, sample the requested colour directly.
        let reduced = format == .jpeg && output.longEdge < sampleEdge
        let edge = reduced ? output.longEdge : sampleEdge
        let colour = reduced ? recipe.colour : nil
        let metadata = reduced ? original : nil
        let key = Cache.Key(path: source.path, format: format, quality: format.takesQuality ? quality : 0,
                            colour: colour, edge: edge, original: metadata?.path)
        let sample: Cache.Sample
        if let kept = await Cache.shared.sample(key) {
            sample = kept
        } else {
            guard let made = await Task.detached(priority: .utility, operation: {
                measure(source, format: format, quality: quality, colour: colour, edge: edge, metadata: metadata)
            }).value
            else { return nil }
            await Cache.shared.keep(made, for: key)
            sample = made
        }
        let p = Double(output.width) * Double(output.height)
        let flat = format == .tiff ? tiffBytes(eightBitPerPixel: sample.bytesPerPixel, pixels: p) : sample.bytesPerPixel * p
        let body = flat * detail(format, quality: quality, filePixels: p, samplePixels: Double(sample.pixels))
        // The file's own: its header, its colour profile, the camera's metadata.
        return Int64(body) + (reduced ? 0 : overhead)
    }

    /// A file's bytes beside its picture's: header, ICC profile, EXIF (measured 20–60 KB on the check's exports).
    static let overhead: Int64 = 40_000

    /// A 16-bit TIFF, LZW, from an 8-bit sample's LZW bytes a pixel: the high byte of each channel compresses as
    /// the 8-bit picture does, the low byte is the develop's noise and does not compress at all.
    static func tiffBytes(eightBitPerPixel: Double, pixels: Double) -> Double {
        (eightBitPerPixel + 3) * pixels
    }

    /// The sample encoded: its pixels and the bytes a pixel they came to.
    private static func measure(_ source: URL, format: ExportRecipe.Format, quality: Int,
                                colour: ExportRecipe.Colour?, edge: Int, metadata: URL?) -> Cache.Sample? {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: edge,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let image: CGImage
        if let colour {
            guard let converted = converted(thumbnail, to: colour) else { return nil }
            image = converted
        } else {
            image = thumbnail
        }
        let data = NSMutableData()
        // A TIFF is measured as an 8-bit TIFF (its high bytes, `tiffBytes`).
        guard let dest = CGImageDestinationCreateWithData(data, ExportWriter.type(format).identifier as CFString, 1, nil)
        else { return nil }
        var properties = metadata.map(ExportWriter.metadata(from:)) ?? [:]
        if metadata != nil { properties[kCGImagePropertyOrientation] = 1 }
        if format.takesQuality { properties[kCGImageDestinationLossyCompressionQuality] = Double(quality.clamped(to: 1...100)) / 100 }
        if format == .tiff {
            var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = 5
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let pixels = image.width * image.height
        guard pixels > 0 else { return nil }
        return Cache.Sample(pixels: pixels, bytesPerPixel: Double(data.length) / Double(pixels))
    }

    /// Convert only the small estimate sample. The export itself uses the engine's gamut transform.
    private static func converted(_ image: CGImage, to colour: ExportRecipe.Colour) -> CGImage? {
        let name: CFString = switch colour {
        case .displayP3: CGColorSpace.displayP3
        case .sRGB: CGColorSpace.sRGB
        case .adobeRGB: CGColorSpace.adobeRGB1998
        case .proPhoto: CGColorSpace.rommrgb
        }
        guard let space = CGColorSpace(name: name) else { return nil }
        if image.colorSpace == space { return image }
        let alpha: CGImageAlphaInfo = switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: .noneSkipLast
        default: .premultipliedLast
        }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: alpha.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// The samples measured, by picture, format and quality: a slider dragged through the same values does not
    /// encode them again.
    actor Cache {
        static let shared = Cache()
        struct Key: Hashable {
            let path: String
            let format: ExportRecipe.Format
            let quality: Int
            let colour: ExportRecipe.Colour?
            let edge: Int
            let original: String?
        }
        struct Sample: Sendable { let pixels: Int; let bytesPerPixel: Double }
        private var samples: [Key: Sample] = [:]
        func sample(_ key: Key) -> Sample? { samples[key] }
        func keep(_ sample: Sample, for key: Key) {
            if samples.count > 400 { samples.removeAll() }
            samples[key] = sample
        }
    }
}
