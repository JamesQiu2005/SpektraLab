//  CameraCrop.swift — the crop a camera wrote into its DNG, as a new frame's first crop (2026-11-05).
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
        return reading(props)
    }

    /// **The hook**: a new frame's Develop crop, from its file's first image's properties and the
    /// picture's size as the frame has it (`ImportService.Probe.size`: oriented, the decoder's) — the
    /// camera's crop where there is one (`geometry`), no crop otherwise. Every new frame's crop is this
    /// (`ImportService.probe`, then `ImportService.frame`).
    static func newFrameGeometry(properties: [CFString: Any], size: PixelSize) -> Geometry {
        guard let crop = read(properties), size.width > 0, size.height > 0 else { return .default }
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
        /// Nothing: not a DNG, a pair, the demo's, or read already.
        case nothing
        /// Its crops were edited before the camera's was read: they stay, and it is marked read
        /// without its file being opened.
        case settled
        /// Its file is to be read, and the camera's crop, if there is one, taken as its crop.
        case read
    }

    /// Whether a frame is owed the camera's crop of its file. Only a frame whose crops are all as they
    /// were made — Develop's `.default`, Edit's `.default`, no film edge (whose framing is placed over
    /// the photo's crop) — takes it; any other keeps what was drawn.
    static func owing(fileName: String, isPair: Bool, isDemo: Bool, read: Bool?, edit: FrameEdit) -> Owing {
        guard read != true, !isPair, !isDemo, (fileName as NSString).pathExtension.lowercased() == "dng" else { return .nothing }
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
