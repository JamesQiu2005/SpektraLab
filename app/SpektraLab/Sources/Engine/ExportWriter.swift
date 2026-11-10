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
//    its depth — and, with a gain map, every declaration of it. A file that is
//    not what was asked is a failure, said as one.
//  - **A gain map** (Enable HDR, HDR port 2026-11-06):
//    beside the unchanged picture, JPEG and HEIF only, as the layout stores and
//    declares it (`HDRProfile`: one map in Apple's coding, declared as ISO
//    21496-1's and Apple's), and in a JPEG as Adobe's `hdrgm` too (`HDRUltraHDR`,
//    D8), inserted into the file ImageIO finished. That step also gives the
//    primary the picture as it is encoded without a map (D3: ImageIO encodes a
//    JPEG that has one with another encoder, which moved a third of a picture's
//    samples; `HDRUltraHDR.write(base:)`), so the coded picture is the HDR-off
//    file's to the byte. It can only lose itself: where it cannot be made, or its
//    file does not read back as it should, ImageIO's own file is kept (its map,
//    the other encoder's base) and `Written.hdr` says why.
//
//  No engine and no Metal: `tools/selftest.sh` writes every format in every
//  colour space on the Mac and holds each file to what was asked; the map is
//  `tools/hdr_gainmap_selftest.sh`'s.

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
    /// The frame's Enable HDR, for a format that holds a map (`HDRGain.export`): the file's map is made from the
    /// curve of the session that renders it (`EngineHost.Request.hdrCurve`, asked with the render). False: no map.
    var gainMap: Bool = false
    /// A slide's Enable HDR (`HDRGain`): its map is the ratio of a second rendition of the
    /// frame at this headroom over its own; the session's curve when that rendition cannot be made. Nil: none.
    var slideHeadroom: Double? = nil
    /// How the file carries its map (RFC-046): the recipe's `hdrLayoutInEffect`. Nothing without a map.
    var hdrLayout: ExportRecipe.HDRLayout = .iso
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
        /// How its gain map is declared, for the log ("appleCamera + hdrgm"); or why hdrgm is not in it. Nil: no map.
        var hdr: String? = nil
        /// Where its seconds went, for the log: the encode, the read-back(s), hdrgm.
        var phases: [String: Double] = [:]
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
    /// camera metadata the export carries; nil carries none. `gainMap` (a frame's
    /// Enable HDR: `HDRGainMap.exportAttachment`, or a slide's `HDRGain.ratioMap`)
    /// attaches a gain map beside the unchanged picture, JPEG and HEIF only, as
    /// `layout` stores and declares it (`HDRProfile`), a JPEG's also as hdrgm; nil
    /// writes exactly what was written before it existed.
    @discardableResult
    static func write(_ image: CGImage, format: ExportRecipe.Format, quality: Int, to url: URL,
                      metadataFrom source: URL? = nil, gainMap: HDRGainMap.Attachment? = nil,
                      layout: ExportRecipe.HDRLayout = .appleCamera) throws -> Written {
        let started = DispatchTime.now().uptimeNanoseconds
        guard image.bitsPerComponent == format.bitDepth else {
            throw Failure.depth(asked: format.bitDepth, given: image.bitsPerComponent)
        }
        let profile = HDRProfile.of(layout)
        if gainMap != nil, !profile.formats.contains(format) {
            throw Failure.write(layout == .iso ? HDRGainMap.Failure.format(format.rawValue).description
                                               : "the \(layout.rawValue) layout is not written in \(format.rawValue)")
        }
        if gainMap != nil, let depth = profile.depth, depth != format.bitDepth {
            throw Failure.write("the \(layout.rawValue) layout is \(depth)-bit, not \(format.bitDepth)")
        }
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw Failure.write(error.localizedDescription)
        }
        let partial = folder.appendingPathComponent("." + url.lastPathComponent + ".partial-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: partial) }
        // A JPEG's hdrgm is written beside ImageIO's file, and takes its place only once it reads back; so is the
        // picture without its map, whose scan the hdrgm file's primary takes (D3, `HDRUltraHDR.write(base:)`).
        let adobe = folder.appendingPathComponent(partial.lastPathComponent + "-hdrgm")
        defer { try? FileManager.default.removeItem(at: adobe) }
        let unmapped = folder.appendingPathComponent(partial.lastPathComponent + "-base")
        defer { try? FileManager.default.removeItem(at: unmapped) }
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
        // The file without a map is encoded with exactly these (a JPEG's base, below).
        let plainProperties = properties
        // What an encoding says in the picture's own properties (Apple's map: MakerApple's headroom). The source's
        // maker note never travels (`metadata(from:)`), so this is the file's only one.
        let stored = gainMap.map(profile.stored)
        if let stored {
            for declaration in profile.declarations { properties.merge(declaration.imageProperties(for: stored)) { _, new in new } }
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        if let stored {
            for declaration in profile.declarations {
                do { try declaration.attach(stored, to: destination) } catch { throw Failure.write("\(error)") }
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw Failure.write("the encoder did not finish") }
        var phases: [String: Double] = [:]
        var mark = DispatchTime.now().uptimeNanoseconds
        func phase(_ name: String) {
            let now = DispatchTime.now().uptimeNanoseconds
            phases[name, default: 0] += Double(now - mark) / 1e9
            mark = now
        }
        phases["encode"] = Double(mark - started) / 1e9

        // What is on disk, before it is given its name: the container, the size, the depth, every declaration.
        func readBack(_ file: URL) throws -> (width: Int, height: Int) {
            guard let written = CGImageSourceCreateWithURL(file as CFURL, nil),
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
            if let stored {
                if let missing = profile.declarations.first(where: { !$0.isPresent(in: written) }) {
                    throw Failure.notAsWritten("its \(missing.name) is not in it")
                }
                guard let size = HDRGainMap.size(in: written), size.width == stored.width, size.height == stored.height else {
                    throw Failure.notAsWritten("its gain map is not \(stored.width) x \(stored.height)")
                }
            }
            return (w, h)
        }
        var file = partial, said: String? = stored.map { _ in layout.rawValue }
        var made: (width: Int, height: Int)?
        if let stored, profile.ultraHDR(format) {
            // Adobe's hdrgm, of the same stored map (D8): taken only when it, and ImageIO's reading of it, check;
            // else ImageIO's own file is read back and kept (one read-back either way: each reads the map twice).
            let d = HDRUltraHDR.Declaration.of(stored)
            do {
                // The picture as it is written with Enable HDR off (D3): ImageIO's other encoder for a JPEG with a
                // map moved 34 % of a grained picture's samples (the 2026-11-06 review). Its scan is the primary's.
                guard let plain = CGImageDestinationCreateWithURL(unmapped as CFURL, type(format).identifier as CFString, 1, nil) else {
                    throw HDRUltraHDR.Failure.write("no encoder for the picture without its map")
                }
                CGImageDestinationAddImage(plain, image, plainProperties as CFDictionary)
                guard CGImageDestinationFinalize(plain) else { throw HDRUltraHDR.Failure.write("the picture without its map was not encoded") }
                phase("base")
                try HDRUltraHDR.write(from: partial, to: adobe, declaration: d, base: unmapped)
                guard try HDRUltraHDR.says(adobe, d) else { throw HDRUltraHDR.Failure.write("its file does not read back as written") }
                phase("hdrgm")
                made = try readBack(adobe)
                phase("read back")
                file = adobe
                said = layout.rawValue + " + hdrgm"
            } catch {
                phase("hdrgm")
                said = layout.rawValue + "; no hdrgm: " + ((error as? HDRUltraHDR.Failure)?.description ?? "\(error)")
            }
        }
        if made == nil {
            made = try readBack(partial)
            phase("read back")
        }
        guard let made else { throw Failure.notAsWritten("it cannot be read back") }

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: file)
            } else {
                try FileManager.default.moveItem(at: file, to: url)
            }
        } catch {
            throw Failure.write(error.localizedDescription)
        }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        return Written(url: url, size: PixelSize(width: made.width, height: made.height), bytes: bytes,
                       seconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9, hdr: said,
                       phases: phases.mapValues { ($0 * 1000).rounded() / 1000 })
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
