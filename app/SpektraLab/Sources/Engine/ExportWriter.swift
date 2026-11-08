//  ExportWriter.swift — a developed picture, as the file a recipe names.
//
//  The last step of an export, and the only one that touches a container:
//  ImageIO's encoder for JPEG, HEIF, PNG and TIFF. **It converts nothing.**
//  The picture it is handed is already in the file's colour space and at the
//  file's depth (`OutputTransformer`: the engine's own transform, 8 or 16 bits
//  written by its kernel), so the numbers that reach the file are the ones the
//  transform made, and the profile travels with them — the desktop's rule
//  (`Exporter.write` there, the maintainer's: "`write` does not convert
//  colour").
//
//  - **A format is never swapped for another.** Where this system has no
//    encoder for one, the export fails and says so; a JPEG under a `.heic`
//    name would be a file nobody asked for.
//  - **The original's metadata travels**: what the camera wrote of the
//    exposure, the lens, the date and the place. The picture is upright, so
//    the orientation is 1, and the software is named. A host's own maker
//    note does not travel: it describes the camera's processing of a picture
//    this one no longer is.
//  - **Written under another name and moved into place**, so a write that is
//    cut short leaves no half file under the name the user was told.
//  - **Read back before it is called written**: its container, its pixels and
//    its depth. A file that is not what was asked is a failure, said as one.
//
//  No engine and no Metal: `tools/selftest.sh` writes every format in every
//  colour space on the Mac and holds each file to what was asked.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What an export job makes of its develop, and where: captured when the job
/// is submitted, and acted on by the engine's host when the render lands
/// (`EngineHost.deliver`).
struct ExportOrder: Equatable, Sendable {
    var format: ExportRecipe.Format
    var colour: ExportRecipe.Colour
    var quality: Int
    /// The file to write, in a folder of the export's own.
    var url: URL
    /// The file whose camera metadata travels with it: the frame's original.
    var metadataFrom: URL?
    /// Edit's Light, Curve and Colour (Layer 2), baked into the file by the
    /// same pass the page draws with (`Layer2Export`). Nil, or a neutral
    /// layer: the file is the develop, exactly as before.
    var adjustments: Adjustments? = nil
    /// Edit's crop, cut from the finished picture after everything else
    /// (`FinishedCut`, `ExportPlan.printCrop`). Nil: the file is the whole picture.
    var printCrop: Geometry? = nil
}

/// What became of an export job's file.
enum ExportOutcome: Equatable, Sendable {
    case written(ExportWriter.Written)
    /// Why not, in the page's words. The details are in the log.
    case failed(String)
}

enum ExportWriter {
    enum Failure: Error, Equatable {
        /// This system cannot write the container.
        case noEncoder(String)
        /// The picture handed over is not at the container's depth.
        case depth(asked: Int, given: Int)
        /// The encoder or the disk refused.
        case write(String)
        /// The file is there and is not what was asked.
        case notAsWritten(String)

        /// In the page's words.
        var text: String {
            switch self {
            case .noEncoder(let format): "This Mac cannot write \(format)"
            case .depth: "The picture was not made at the file's depth"
            case .write: "The file could not be written"
            case .notAsWritten: "The file did not come out as asked"
            }
        }
    }

    /// What was written: for the job's record, and for the page.
    struct Written: Equatable, Sendable {
        var url: URL
        var size: PixelSize
        var bytes: Int64
        var seconds: Double
    }

    static func type(_ format: ExportRecipe.Format) -> UTType {
        switch format {
        case .jpeg: .jpeg
        case .heif: .heic
        case .png: .png
        case .tiff: .tiff
        }
    }

    /// Write `image` to `url` as `format`. `metadataFrom` is the file whose
    /// camera metadata the export carries; nil carries none.
    @discardableResult
    static func write(_ image: CGImage, format: ExportRecipe.Format, quality: Int, to url: URL,
                      metadataFrom source: URL? = nil) throws -> Written {
        let started = DispatchTime.now().uptimeNanoseconds
        guard image.bitsPerComponent == format.bitDepth else {
            throw Failure.depth(asked: format.bitDepth, given: image.bitsPerComponent)
        }
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw Failure.write(error.localizedDescription)
        }
        let partial = folder.appendingPathComponent("." + url.lastPathComponent + ".partial-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: partial) }
        guard let destination = CGImageDestinationCreateWithURL(partial as CFURL, type(format).identifier as CFString, 1, nil) else {
            throw Failure.noEncoder(format.rawValue)
        }
        var properties = source.map(metadata(from:)) ?? [:]
        properties[kCGImagePropertyOrientation] = 1
        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFSoftware] = "SpektraLab"
        tiff[kCGImagePropertyTIFFOrientation] = 1
        // LZW: lossless, and a 16-bit film scan is otherwise 6 bytes a pixel on disk.
        if format == .tiff { tiff[kCGImagePropertyTIFFCompression] = 5 }
        properties[kCGImagePropertyTIFFDictionary] = tiff
        if format.takesQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = Double(quality.clamped(to: 1...100)) / 100
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.write("the encoder did not finish") }

        // What is on disk, before it is given its name.
        guard let written = CGImageSourceCreateWithURL(partial as CFURL, nil),
              let found = CGImageSourceCopyPropertiesAtIndex(written, 0, nil) as? [CFString: Any] else {
            throw Failure.notAsWritten("it cannot be read back")
        }
        let kind = CGImageSourceGetType(written).flatMap { UTType($0 as String) }
        guard kind?.conforms(to: type(format)) == true || (format == .heif && kind?.conforms(to: .heif) == true) else {
            throw Failure.notAsWritten("it is \(kind?.identifier ?? "of no known kind"), not \(type(format).identifier)")
        }
        let w = (found[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (found[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let depth = (found[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 0
        guard w == image.width, h == image.height else {
            throw Failure.notAsWritten("it is \(w) x \(h), not \(image.width) x \(image.height)")
        }
        guard depth == format.bitDepth else { throw Failure.notAsWritten("it holds \(depth) bits a channel, not \(format.bitDepth)") }

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: url)
            }
        } catch {
            throw Failure.write(error.localizedDescription)
        }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        return Written(url: url, size: PixelSize(width: w, height: h), bytes: bytes,
                       seconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9)
    }

    /// What of a file's metadata an export of it carries: the exposure and the
    /// lens (Exif, and the documented half of its auxiliary block), the camera
    /// and the date (TIFF), the place (GPS) and any caption (IPTC). Not the
    /// pixel size, the orientation or the colour space, which are the new
    /// file's own; not a maker's note; **not how the source stored its pixels**
    /// (a HEIC's tiles are true of that file and of no JPEG); and not a
    /// private key in the auxiliary block — an reference device's face `Regions` had
    /// ImageIO write a 4 KB XMP packet into the export (the owner's host,
    /// 2026-10-15: the one export ChatGPT would not read).
    static func metadata(from source: URL) -> [CFString: Any] {
        guard let file = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let all = CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [CFString: Any] else { return [:] }
        var out: [CFString: Any] = [:]
        if var exif = all[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            for key in [kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension, kCGImagePropertyExifColorSpace,
                        kCGImagePropertyExifMakerNote, kCGImagePropertyExifUserComment] { exif[key] = nil }
            out[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = all[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            for key in [kCGImagePropertyTIFFOrientation, kCGImagePropertyTIFFXResolution, kCGImagePropertyTIFFYResolution,
                        kCGImagePropertyTIFFResolutionUnit, kCGImagePropertyTIFFCompression, kCGImagePropertyTIFFPhotometricInterpretation,
                        kCGImagePropertyTIFFSoftware, kCGImagePropertyTIFFTileWidth, kCGImagePropertyTIFFTileLength] { tiff[key] = nil }
            out[kCGImagePropertyTIFFDictionary] = tiff
        }
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let block = all[key] { out[key] = block }
        }
        // The auxiliary block by the keys ImageIO documents, which is the lens's own. Copied
        // whole, whatever a camera app put there rides along: the keys with no constant have
        // no contract, and ImageIO serializes at least one of them beyond EXIF (`Regions`).
        if let aux = all[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] {
            let carried: [CFString] = [kCGImagePropertyExifAuxLensInfo, kCGImagePropertyExifAuxLensModel,
                                       kCGImagePropertyExifAuxLensID, kCGImagePropertyExifAuxLensSerialNumber,
                                       kCGImagePropertyExifAuxFirmware, kCGImagePropertyExifAuxFlashCompensation,
                                       kCGImagePropertyExifAuxImageNumber, kCGImagePropertyExifAuxOwnerName,
                                       kCGImagePropertyExifAuxSerialNumber]
            var kept: [CFString: Any] = [:]
            for key in carried { if let value = aux[key] { kept[key] = value } }
            if !kept.isEmpty { out[kCGImagePropertyExifAuxDictionary] = kept }
        }
        return out
    }
}
