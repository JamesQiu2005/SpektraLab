//  CameraCrop.swift — the crop a camera wrote into its DNG or Hasselblad 3FR, as a new frame's first crop.
//
//  The owner, of four Leica Q3 DNGs: "these are test images carrying crop information; it appears that
//  Core Image also ignores the crop information. If this can be easily patched, we patch it." It can.
//  The Q3's digital zoom (35, 50, 75 mm frame lines on its 28 mm lens) and its aspect setting record the
//  frame the photographer saw as DNG 1.6's **DefaultUserCrop** and keep every pixel of the sensor.
//  `CIRAWFilter` hands over the whole default crop area (9520 × 6336 for all four files) and ImageIO's
//  own thumbnail decodes it too: the frame is the photographer's choice, left for the raw developer to
//  apply. (That Lightroom and Capture One open such a file cropped is what is said of them; it was not
//  checked here.) **Decision:** a new frame of such a file starts with that rectangle as its Develop
//  crop (`FrameEdit.geometry`), as though the person had drawn it — editable — and Reset goes back to
//  the whole picture: the camera's crop is a starting point, not a second default (`CropScreen.reset`,
//  `FrameEdit.resetDevelop` are unchanged). What another developer's Reset does was not checked; this
//  is the app's own choice, not a copy of one.
//
//  ## Which frames take it
//
//  - Every new frame (`ImportService.frame`), through `newFrameGeometry`: the one helper the probe and
//    the frame both go through, so tools/crop_selftest.swift checks the hook, not only the reading.
//  - A frame made before 2026-11-05 (2.1.3 and earlier made every Q3 frame uncropped) is caught up once,
//    at launch (`AppServices.holdCameraCrops`), **only while its crops are as they were made**: Develop's
//    crop `.default`, no Edit crop, no film edge (`owing`). The library keeps no history of edits, so
//    "never edited" cannot be known; "its crops are the defaults" can, and is what is asked. A frame
//    whose crop was edited keeps it. Once read, a frame is marked (`LibraryFrame.cameraCropRead`) and
//    never read again, so a later Reset to the whole picture sticks. A file that cannot be read now (a
//    disk away) stays owed and is read at a later launch, never kept as having no crop.
//  - Only this repository's app (the Mac's, and its window build). The reference device and window apps built from
//    the reference app are not changed.
//
//  ## What the tag says (DNG 1.6.0.0, tag 0xC7B5), and how it is read
//
//  - Four rationals, **top, left, bottom, right**, relative to the default crop (DefaultCropOrigin /
//    DefaultCropSize), 0 ≤ top < bottom ≤ 1, 0 ≤ left < right ≤ 1; (0, 0, 1, 1) is "no crop". ImageIO
//    reads it into the `{DNG}` dictionary as `kCGImagePropertyDNGDefaultUserCrop`.
//  - It is in the **stored** frame, before the file's Orientation turns it — as every DNG crop is. The
//    app's crop is in the **oriented** picture (`Geometry.crop`: normalised to the source, which is
//    the decode `CIRAWFilter` hands over, turned as the file says — `ImportService.rawSize`). So the
//    rectangle is put through the EXIF orientation (`oriented`): for the Q3 held upright (Orientation 6)
//    the stored top edge becomes the right-hand side.
//  - The default crop area is what the decoder hands over, so no offset is needed: the Q3's
//    DefaultCropOrigin (4, 4) is already outside `CIRAWFilter`'s extent.
//
//  ## What is not read
//
//  Leica's `xmpDSA` block (its "Digital Shift Assistant", the Q3's perspective control) carries a
//  `NormalizedCropCorners` quad — eight numbers, a slightly non-rectangular quadrilateral — with the
//  pitch and roll the camera measured. It is the crop *after* a keystone correction, and on all four
//  files `ApplyAutomatically` is False and `CorrectionAlreadyApplied` False: the camera's perspective
//  control was off, so the quad is a suggestion for a correction nobody asked for. Taking it would make
//  a perspective edit (the host's Vertical/Horizontal) out of a setting the photographer left off.
//  DefaultUserCrop is the DNG standard's, the one other raw developers honour; it is the one read.
//
//  ## The aspect
//
//  A camera crop is one of the camera's aspect settings (the Q3: 3:2, 4:3, 16:9, 1:1) cut on its own
//  pixel grid, so it is a hair off the exact ratio (L1026319's 35 mm frame is 7,616 × 5,088, 1.4969).
//  Where the crop is within 1 % of one of the picker's ratios, the frame starts with that ratio locked
//  (`CropAspect`, its portrait twin for an upright crop) and the rectangle made exactly that ratio about
//  its own centre with its area kept (`Geometry.constrained`) — so dragging a corner keeps the camera's
//  3:2, as it would after the person chose 3:2. Otherwise it is a free crop of exactly the camera's
//  rectangle. Either way its size is remembered (`intendedSize`), so a straighten does not grow it back
//  to the largest fit as it would a crop nobody sized.

import CoreGraphics
import Foundation
import ImageIO

enum CameraCrop {
    /// How near a camera crop's pixel ratio must be to a preset's to be locked to it: 1 %.
    static let ratioTolerance = 0.01
    /// 1: DNG DefaultUserCrop. 2: Hasselblad 3FR MakerNote 0x0059 too. An old frame's
    /// `cameraCropRead` alone means 1; the optional persisted version tells 2 apart from it.
    static let currentReadVersion = 2

    static func supports(_ url: URL) -> Bool {
        ["dng", "3fr"].contains(url.pathExtension.lowercased())
    }

    /// The camera's crop of a file, from its first image's properties
    /// (`CGImageSourceCopyPropertiesAtIndex`), in the oriented picture's normalised coordinates; nil
    /// for a file with none, a crop of the whole picture, or numbers no camera could mean.
    static func read(_ properties: [CFString: Any]) -> CropRect? {
        guard let dng = properties[kCGImagePropertyDNGDictionary] as? [CFString: Any],
              let values = dng[kCGImagePropertyDNGDefaultUserCrop] as? [Any] else { return nil }
        let numbers = values.compactMap { ($0 as? NSNumber)?.doubleValue ?? ($0 as? String).flatMap(Double.init) }
        guard numbers.count == 4 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return oriented(top: numbers[0], left: numbers[1], bottom: numbers[2], right: numbers[3], orientation: orientation)
    }

    /// The camera's crop of the file at `url` (its header only: no pixel is decoded); nil for a file
    /// with none and for one that cannot be read — `reading` tells the two apart.
    static func read(_ url: URL) -> CropRect? { reading(url)?.crop }

    /// What a file's header says about the camera's crop: the crop, or none, and the whole picture's
    /// shape, which tells a preview cut to the crop from one of the whole picture (`MacCameraCrops.cut`).
    struct Reading: Equatable, Sendable {
        var crop: CropRect?
        /// The whole picture's width over its height, turned as the file says: the default crop's size
        /// (DefaultCropSize), or else the first image's. Nil where the header gives neither.
        var aspect: Double?

        static let uncropped = Reading(crop: nil, aspect: nil)
    }

    static func reading(_ properties: [CFString: Any]) -> Reading {
        func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }
        let dng = properties[kCGImagePropertyDNGDictionary] as? [CFString: Any]
        let cropSize = (dng?[kCGImagePropertyDNGDefaultCropSize] as? [Any])?.compactMap { number($0) } ?? []
        var w = cropSize.count == 2 ? cropSize[0] : number(properties[kCGImagePropertyPixelWidth]) ?? 0
        var h = cropSize.count == 2 ? cropSize[1] : number(properties[kCGImagePropertyPixelHeight]) ?? 0
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (5...8).contains(orientation) { swap(&w, &h) }
        return Reading(crop: read(properties), aspect: w > 0 && h > 0 ? w / h : nil)
    }

    /// The header of the file at `url`; nil where it cannot be read at all (no file there, a disk away,
    /// no access) — which is not a file with no crop, and is never kept as one.
    static func reading(_ url: URL) -> Reading? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        if url.pathExtension.lowercased() == "3fr" {
            return reading(props, hasselblad: HasselbladCrop.read(url))
        }
        return reading(props)
    }

    /// A 3FR's visible frame is a few pixels larger than DefaultCrop on each side (the X2D: four).
    /// Its MakerNote crop is in the full sensor's coordinates, so subtract DefaultCropOrigin, then add
    /// that visible-frame inset before normalising. Mode 1 is the uncropped setting, not a four-pixel crop.
    static func reading(_ properties: [CFString: Any], hasselblad record: HasselbladCrop.Record?) -> Reading {
        func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }
        let storedW = number(properties[kCGImagePropertyPixelWidth]) ?? 0
        let storedH = number(properties[kCGImagePropertyPixelHeight]) ?? 0
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        var w = storedW, h = storedH
        if (5...8).contains(orientation) { swap(&w, &h) }
        let aspect = w > 0 && h > 0 ? w / h : nil
        guard let record, record.mode != 1, storedW >= record.defaultWidth, storedH >= record.defaultHeight,
              storedW > 0, storedH > 0 else { return Reading(crop: nil, aspect: aspect) }
        let left = (record.x - record.defaultX + (storedW - record.defaultWidth) / 2) / storedW
        let top = (record.y - record.defaultY + (storedH - record.defaultHeight) / 2) / storedH
        let crop = oriented(top: top, left: left, bottom: top + record.height / storedH,
                            right: left + record.width / storedW, orientation: orientation)
        return Reading(crop: crop, aspect: aspect)
    }

    /// **The hook**: a new frame's Develop crop, from its file's first image's properties and the
    /// picture's size as the frame has it (`ImportService.Probe.size`: oriented, the decoder's) — the
    /// camera's crop where there is one (`geometry`), no crop otherwise. Every new frame's crop is this
    /// (`ImportService.probe`, then `ImportService.frame`). `url` lets a 3FR's MakerNotes be read; the
    /// two-argument form remains the DNG header probe used by the checks.
    static func newFrameGeometry(properties: [CFString: Any], size: PixelSize, url: URL? = nil) -> Geometry {
        let crop: CropRect?
        if let url, url.pathExtension.lowercased() == "3fr" {
            crop = reading(properties, hasselblad: HasselbladCrop.read(url)).crop
        } else {
            crop = read(properties)
        }
        guard let crop, size.width > 0, size.height > 0 else { return .default }
        return geometry(crop, in: CGSize(width: size.width, height: size.height))
    }

    /// Whether a file's preview of `width` × `height` (turned as the file says) is already cut to the
    /// camera's crop: its shape is the crop's (within `ratioTolerance`) and not the whole picture's. A
    /// camera may write its embedded preview cut so; ThumbnailStore takes a RAW's embedded preview, and
    /// cutting that again would crop it twice and stretch it. Where the crop has the whole picture's
    /// shape (a 3:2 crop of a 3:2 sensor) the preview cannot say which it is, and is taken as whole —
    /// the Q3's, which has none embedded, is ImageIO's decode of the whole picture.
    static func previewIsCut(width: Int, height: Int, _ reading: Reading) -> Bool {
        guard let crop = reading.crop, let whole = reading.aspect, width > 0, height > 0, crop.height > 0 else { return false }
        let shown = Double(width) / Double(height), cut = whole * crop.width / crop.height
        func same(_ a: Double, _ b: Double) -> Bool { abs(log(a / b)) <= ratioTolerance }
        return same(shown, cut) && !same(shown, whole)
    }

    // MARK: a frame made before the camera's crop was read

    /// What a frame of the library is owed (`AppServices.holdCameraCrops`).
    enum Owing: Equatable, Sendable {
        /// Nothing: not a supported RAW, a pair, the demo's, or read already.
        case nothing
        /// Its crops were edited before the camera's was read: they stay, and it is marked read
        /// without its file being opened.
        case settled
        /// Its file is to be read, and the camera's crop, if there is one, taken as its crop.
        case read
    }

    /// Whether a frame is owed the camera's crop of its file. Only a frame whose crops are all as they
    /// were made — Develop's `.default`, Edit's `.default`, no film edge (whose framing is placed over
    /// the photo's crop) — takes it; any other keeps what was drawn. The original Boolean marker means
    /// reader 1. A 3FR needs reader 2 because 2.4.2 set that Boolean without reading its MakerNotes.
    static func owing(fileName: String, isPair: Bool, isDemo: Bool, read: Bool?, version: Int? = nil, edit: FrameEdit) -> Owing {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !isPair, !isDemo, ["dng", "3fr"].contains(ext) else { return .nothing }
        let readVersion = version ?? (read == true ? 1 : 0)
        let requiredVersion = ext == "3fr" ? currentReadVersion : 1
        guard readVersion < requiredVersion else { return .nothing }
        let asMade = edit.geometry == .default && edit.printCrop == .default && !edit.filmEdge.active
        return asMade ? .read : .settled
    }

    /// An owed frame once its file has been read (`reading`; nil for a file that could not be): the
    /// crop it has now, and whether it is read — false only for a file not read, which stays owed.
    /// `size` is the frame's `originalSize`.
    static func caughtUp(_ edit: FrameEdit, reading: Reading?, size: PixelSize) -> (geometry: Geometry, read: Bool) {
        guard let reading else { return (edit.geometry, false) }
        guard let crop = reading.crop, edit.geometry == .default, size.width > 0, size.height > 0 else { return (edit.geometry, true) }
        return (geometry(crop, in: CGSize(width: size.width, height: size.height)), true)
    }

    /// DefaultUserCrop's rectangle, given in the stored frame, as a crop of the picture `orientation`
    /// (EXIF, 1…8) turns it into. Nil for a rectangle outside 0…1 or empty, and for the whole picture.
    static func oriented(top: Double, left: Double, bottom: Double, right: Double, orientation: Int) -> CropRect? {
        let all = [top, left, bottom, right]
        guard all.allSatisfy({ $0.isFinite && $0 >= -1e-6 && $0 <= 1 + 1e-6 }),
              bottom - top > 1e-4, right - left > 1e-4 else { return nil }
        let t = max(top, 0), l = max(left, 0), b = min(bottom, 1), r = min(right, 1)
        // A crop of the whole picture is the default crop already: no crop at all.
        guard t > 1e-4 || l > 1e-4 || b < 1 - 1e-4 || r < 1 - 1e-4 else { return nil }
        let a = turned(CGPoint(x: l, y: t), orientation), z = turned(CGPoint(x: r, y: b), orientation)
        return CropRect(x: min(a.x, z.x), y: min(a.y, z.y), width: abs(z.x - a.x), height: abs(z.y - a.y))
    }

    /// A point of the stored picture (normalised, top-left origin) where the picture `orientation`
    /// shows it. EXIF's words for each, of the stored 0th row and 0th column: 6 is "the 0th row is the
    /// visual right-hand side, the 0th column the visual top" — stored y = 0 is shown at x = 1.
    static func turned(_ p: CGPoint, _ orientation: Int) -> CGPoint {
        let x = p.x, y = p.y
        switch orientation {
        case 2: return CGPoint(x: 1 - x, y: y)        // mirrored left to right
        case 3: return CGPoint(x: 1 - x, y: 1 - y)    // half a turn
        case 4: return CGPoint(x: x, y: 1 - y)        // mirrored top to bottom
        case 5: return CGPoint(x: y, y: x)            // transposed
        case 6: return CGPoint(x: 1 - y, y: x)        // a quarter turn clockwise
        case 7: return CGPoint(x: 1 - y, y: 1 - x)    // transversed
        case 8: return CGPoint(x: y, y: 1 - x)        // a quarter turn anticlockwise
        default: return p
        }
    }

    /// The picker's ratio the crop is (within `ratioTolerance`), in the crop's own orientation; nil for
    /// none. `original` is not offered: a camera's crop is one of its named ratios, not its sensor's.
    static func aspect(of crop: CropRect, in imageSize: CGSize) -> CropAspect? {
        let w = crop.width * imageSize.width, h = crop.height * imageSize.height
        guard w > 0, h > 0 else { return nil }
        let ratio = w / h
        let candidates = CropAspect.allCases.filter { $0.fixedRatio != nil }
        let best = candidates.min { abs(log(ratio / $0.fixedRatio!)) < abs(log(ratio / $1.fixedRatio!)) }
        guard let best, let r = best.fixedRatio, abs(ratio / r - 1) <= ratioTolerance else { return nil }
        return best
    }

    /// A new frame's Develop crop for a camera's crop of a picture of `imageSize` pixels (oriented): the
    /// rectangle, its ratio locked where it is one of the picker's, and its size remembered.
    static func geometry(_ crop: CropRect, in imageSize: CGSize) -> Geometry {
        var g = Geometry()
        g.crop = crop
        if let aspect = aspect(of: crop, in: imageSize) { g.aspect = aspect }
        // `redrawn`: as a rectangle the person drew — `constrained` to the locked ratio (area and
        // centre kept; free leaves it as it is, `fitted`) — and its size remembered.
        return g.redrawn(as: crop, in: imageSize)
    }
}

/// Hasselblad's in-camera crop in a 3FR, as verified on X2D 100C files from firmware 4.2.0.
/// The camera leaves DNG DefaultCrop at the full visible frame and writes `mode, x, y, width, height`
/// as five uint16s in MakerNote tag 0x0059. The owner's 2,138 X2D files carry only mode 1 (full 4:3)
/// and mode 12 (65:24); the rectangle, not the mode number, is what a crop is made from, so another
/// in-camera aspect needs no new mode constant here. No public specification for this tag was found;
/// validation comes from the measured files and the synthetic checks.
enum HasselbladCrop {
    struct Record: Equatable {
        var mode: Int
        var x: Double, y: Double, width: Double, height: Double
        var defaultX: Double, defaultY: Double, defaultWidth: Double, defaultHeight: Double
    }

    /// Memory mapping keeps this a header read even though a 3FR is hundreds of megabytes: only the
    /// pages the TIFF directories point at are touched, never the pixel payload as an image decode.
    static func read(_ url: URL) -> Record? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return read(data)
    }

    static func read(_ data: Data) -> Record? {
        let tiff = TIFF(data)
        guard tiff.headerIsValid, let first = tiff.firstDirectory(),
              let makeEntry = first.first(where: { $0.tag == 0x010f }),
              tiff.text(makeEntry)?.lowercased().contains("hasselblad") == true else { return nil }

        var defaultCrop: (x: Double, y: Double, w: Double, h: Double)?
        if let subIDs = first.first(where: { $0.tag == 0x014a }), let offsets = tiff.numbers(subIDs) {
            for offset in offsets {
                guard let directory = tiff.directory(at: Int(offset)),
                      let origin = directory.first(where: { $0.tag == 0xc61f }).flatMap({ tiff.numbers($0) }),
                      let size = directory.first(where: { $0.tag == 0xc620 }).flatMap({ tiff.numbers($0) }),
                      origin.count == 2, size.count == 2 else { continue }
                defaultCrop = (origin[0], origin[1], size[0], size[1])
                break
            }
        }
        guard let defaultCrop,
              let exifOffset = first.first(where: { $0.tag == 0x8769 }).flatMap({ tiff.numbers($0)?.first }),
              let exif = tiff.directory(at: Int(exifOffset)),
              let makerEntry = exif.first(where: { $0.tag == 0x927c }),
              let maker = tiff.payload(makerEntry, unitSize: 1),
              let notes = tiff.directory(at: maker.offset),
              let cropEntry = notes.first(where: { $0.tag == 0x0059 }),
              let values = tiff.numbers(cropEntry), values.count == 5 else { return nil }

        let record = Record(mode: Int(values[0]), x: values[1], y: values[2], width: values[3], height: values[4],
                            defaultX: defaultCrop.x, defaultY: defaultCrop.y,
                            defaultWidth: defaultCrop.w, defaultHeight: defaultCrop.h)
        guard record.mode > 0, record.width > 0, record.height > 0,
              record.defaultWidth > 0, record.defaultHeight > 0,
              record.x >= record.defaultX, record.y >= record.defaultY,
              record.x + record.width <= record.defaultX + record.defaultWidth,
              record.y + record.height <= record.defaultY + record.defaultHeight else { return nil }
        return record
    }

    /// The small, bounds-checked subset of classic TIFF that a 3FR's three directories need.
    private struct TIFF {
        let data: Data
        let littleEndian: Bool

        init(_ data: Data) {
            self.data = data
            littleEndian = data.count >= 2 && data[data.startIndex] == 0x49 && data[data.startIndex + 1] == 0x49
        }

        var headerIsValid: Bool {
            guard data.count >= 8 else { return false }
            let big = data[data.startIndex] == 0x4d && data[data.startIndex + 1] == 0x4d
            return (littleEndian || big) && u16(2) == 42
        }

        struct Entry {
            var tag: UInt16, type: UInt16, count: UInt32, valueField: Int
        }

        func valid(_ offset: Int, _ count: Int) -> Bool {
            offset >= 0 && count >= 0 && count <= data.count && offset <= data.count - count
        }

        func u16(_ offset: Int) -> UInt16? {
            guard valid(offset, 2) else { return nil }
            let a = UInt16(data[data.startIndex + offset]), b = UInt16(data[data.startIndex + offset + 1])
            return littleEndian ? a | b << 8 : a << 8 | b
        }

        func u32(_ offset: Int) -> UInt32? {
            guard valid(offset, 4) else { return nil }
            let a = UInt32(data[data.startIndex + offset]), b = UInt32(data[data.startIndex + offset + 1])
            let c = UInt32(data[data.startIndex + offset + 2]), d = UInt32(data[data.startIndex + offset + 3])
            return littleEndian ? a | b << 8 | c << 16 | d << 24 : a << 24 | b << 16 | c << 8 | d
        }

        func firstDirectory() -> [Entry]? {
            guard let offset = u32(4) else { return nil }
            return directory(at: Int(offset))
        }

        func directory(at offset: Int) -> [Entry]? {
            guard let count = u16(offset), count <= 512 else { return nil }
            let bytes = Int(count) * 12 + 4
            guard valid(offset + 2, bytes) else { return nil }
            return (0..<Int(count)).compactMap { index in
                let at = offset + 2 + index * 12
                guard let tag = u16(at), let type = u16(at + 2), let count = u32(at + 4) else { return nil }
                return Entry(tag: tag, type: type, count: count, valueField: at + 8)
            }
        }

        func payload(_ entry: Entry, unitSize: Int) -> (offset: Int, count: Int)? {
            guard unitSize > 0, entry.count <= 1 << 24 else { return nil }
            let (count, overflow) = Int(entry.count).multipliedReportingOverflow(by: unitSize)
            guard !overflow else { return nil }
            let offset: Int
            if count <= 4 {
                offset = entry.valueField
            } else {
                guard let pointed = u32(entry.valueField) else { return nil }
                offset = Int(pointed)
            }
            return valid(offset, count) ? (offset, count) : nil
        }

        func numbers(_ entry: Entry) -> [Double]? {
            guard [3, 4].contains(entry.type), entry.count <= 32,
                  let payload = payload(entry, unitSize: entry.type == 3 ? 2 : 4) else { return nil }
            var out: [Double] = []
            for index in 0..<Int(entry.count) {
                let at = payload.offset + index * (entry.type == 3 ? 2 : 4)
                guard let value = entry.type == 3 ? u16(at).map(Double.init) : u32(at).map(Double.init) else { return nil }
                out.append(value)
            }
            return out
        }

        func text(_ entry: Entry) -> String? {
            guard entry.type == 2, let payload = payload(entry, unitSize: 1) else { return nil }
            let bytes = (0..<payload.count).map { data[data.startIndex + payload.offset + $0] }
            return String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
        }
    }
}
